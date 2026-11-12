## Read-ahead on worker threads (task 6.3; workers, ring cap and
## `quickFirst` 15.3-11).
##
## A `Prefetcher` decodes a trace range of a `SeismicFile` in chunks of
## `chunkTraces` traces, ahead of the consumer, into a bounded ring of
## `depth` chunks, on `workers` threads (1 by default; more for the slow
## formats: IBM float, SEG-D 8015/8024). Chunks still reach the consumer in
## order. The ring is capped at `maxRingBytes` (4 MiB by default), so the
## chunk just decoded is still in the CPU cache when it is taken. The
## consumer (e.g. a viewer's UI thread) polls with
## `tryNext` (never blocks) or waits with `next`; `seek` jumps elsewhere
## (chunks decoded for the old position are dropped). With `quickFirst`, the
## first chunk of the range and of every `seek` holds a quarter of
## `chunkTraces`, so it is decoded about 4 times sooner; the rest follow
## at full size.
##
## ```nim
## var f = openSeismic("survey.sgd")
## var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 512, depth = 4)
## for c in p.chunks:             # or `while p.next(c)`, or `tryNext` to poll
##   show(c.first, c.samples)      # [c.count, cols] tensor, owned by the caller
##   for d in c.log: echo d.msg    # one error per trace that could not be decoded
## p.close()
## ```
##
## Each chunk says which trace each row is (`rows`, a `TraceRows`: trace,
## keys, sample count, channel set) and which rows failed (`failedRows`).
## With `uniform`, chunks are cut short where the channel set or the sample
## interval changes, so each has one interval. A `transform` hook
## (`ChunkTransform`) processes each chunk on its worker thread right after
## it is decoded, while it is still in the CPU cache.
##
## A consumer that is done with each chunk before it takes the next can hand
## its buffer back, so a steady scroll allocates nothing: `nextInto` /
## `tryNextInto` swap the caller's previous `samples` into the slot, and
## `recycle` returns a tensor for a later `next` to reuse.
##
## ```nim
## var c: PrefetchChunk[float32]
## while p.nextInto(c):           # c's previous buffer becomes a decode target
##   show(c.first, c.samples)
## ```
##
## Ownership: the workers share no managed memory with the consumer, and
## make no managed objects at all (decode failures are statuses). They read
## the file's map and index through raw pointers, decode into slot buffers
## that the consumer thread allocated (`tryDecodeEntry`), one chunk per
## slot claimed under the lock, and note the rows that failed in a plain
## array of the slot; the consumer
## turns those into the chunk's diagnostics. When the consumer takes a chunk,
## it takes the slot's tensor and gives the slot another one, so a tensor
## returned by `next` is never written again. That one is fresh, or one the
## caller gave up: the previous chunk's with `nextInto`, a `recycle`d one.
## Only tensors of the slot shape whose storage they own alone (no copy,
## view or `fromBuffer` shares it) are reused; others are dropped.
##
## Lifetime: the prefetcher pins the file's map, so `f.close()`, the file
## going out of scope, or handing it to an editor (`openEditor(f)`) while it
## runs is safe: the map and the index tables the prefetcher reads (trace
## entries, codecs and stored keys) stay alive until the prefetcher's
## `close`. From then on the prefetcher reads its own copy of those tables:
## its chunks' `rows` show the keys as they were when the file was closed
## or handed over, not later edits. What remains a rule: do not change the
## file's index (`applySurvey`, `applyGeometry`, assigning to `f.index`)
## while a prefetcher runs.
##
## Threads: a prefetcher belongs to one thread: call its consumer procs,
## `close` included, from the thread that made it. Several threads may each
## make, use and close prefetchers of their own on one open file at the same
## time (a background job beside the UI's read-ahead), and read it with
## `readTracesInto` meanwhile. While another thread reads the file or has a
## prefetcher on it, no thread may change its index (`ensureKeys`,
## `applySurvey`, `applyGeometry`, a `HeaderEditor`), close it, hand it to
## an editor or let it go out of scope: closing a file before its
## prefetchers is for the thread that opened it and the prefetchers it made
## itself.

import std/locks
import ../common/diagnostics
import ../segy/samples
import ./[traceindex, tracerows]
import ../private/[checks, decodeentry]

type
  ChunkTransform*[T] = proc (worker: int, samples: ptr UncheckedArray[T], rows, cols: int,
      traces: TraceRows, failed: openArray[int], user: pointer) {.nimcall, gcsafe, raises: [].}
    ## A per-chunk hook (`newPrefetcher`'s `transform`), run on the worker
    ## thread right after the chunk is decoded, while it is still in the CPU
    ## cache: `worker` is the worker's index (`0 ..< workers`, e.g. for
    ## per-worker scratch), `samples` the `rows × cols` row-major chunk (it may
    ## change them in place), `traces` the chunk's rows, `failed` the rows
    ## that could not be decoded (left zero), `user` the pointer given to
    ## `newPrefetcher`. It must not raise, and may reach only memory that
    ## outlives the prefetcher through raw pointers (no closures: it may
    ## capture nothing ref-counted).

type
  SlotState = enum ssFree, ssBusy, ssReady

  FailedRow = object
    row: int       # row of the chunk
    code: DiagCode # dcTruncated or dcUnsupportedFormat

  Slot[T] = object
    state: SlotState
    gen: int     # generation (see `seek`) the chunk was decoded for
    chunk: int   # chunk number since the last seek
    first, count: int
    aheadLo, aheadHi: int # positions to advise read-ahead for (`adviseTraces`)
    failed: int  # rows that could not be decoded: `fails[0 ..< failed]`
    fails: ptr UncheckedArray[FailedRow] # `chunkTraces` entries
    failRows: ptr UncheckedArray[int] # the same rows, for `transform`
    data: ptr UncheckedArray[T]

  Shared[T] = object
    lock: Lock
    work: Cond   # the workers wait here for a free slot or a stop
    ready: Cond  # the consumer waits here for a ready chunk
    slots: ptr UncheckedArray[Slot[T]]
    depth: int
    gen: int
    start, stop: int # trace range [start, stop) of the current generation
    nextChunk: int   # next chunk a worker claims
    takeChunk: int   # next chunk the consumer takes
    quit: bool
    chunkTraces, cols: int
    firstSample: int # samples `firstSample ..< firstSample + cols` of each trace
    mem: ptr UncheckedArray[byte]
    size: int64
    entries: ptr UncheckedArray[TraceEntry]
    codecs: ptr UncheckedArray[TraceCodec]
    sel: ptr UncheckedArray[int] # selection mode: positions index this list; nil = ranges
    quick: bool      # `quickFirst`: chunk 0 of each range holds `head` rows
    head: int        # rows of chunk 0 of the current range
    advised: int     # positions before this one were advised read-ahead (this range)
    aheadTraces: int # advice is issued for at least this many positions at a time
    workers: int
    threads: ptr UncheckedArray[Thread[(ptr Shared[T], int)]]
    view: TraceRows  # every position: row `pos` is position `pos`
    uniform: bool    # chunk bounds come from `bounds`
    bounds: ptr UncheckedArray[int] # uniform: chunk n is positions bounds[n] ..< bounds[n + 1]
    nBounds: int
    transform: ChunkTransform[T]
    user: pointer

  Prefetcher*[T: SampleType] = object
    ## Read-ahead state; not copyable. Call `close` when done.
    sh: ptr Shared[T]
    pin: MapPin             # keeps the map (and a destroyed file's index) alive for the workers
    tensors: seq[Tensor[T]] # slot storage, consumer side
    spare: seq[Tensor[T]]   # recycled slot-shaped buffers, at most `depth`
    last: int               # end of the whole range (exclusive)
    selection: seq[int]     # selection mode: the trace list (fixed for the prefetcher's life)
    path: string            # the file's, for diagnostics
    untaken: int            # chunks of the range not yet taken: `sh.chunkCount - sh.takeChunk`,
                            # kept by the consumer so `atEnd` needs no lock
    bounds: seq[int]        # uniform: the current range's chunk bounds (`sh.bounds`)

  PrefetchChunk*[T: SampleType] = object
    first*: int
      ## Position of the chunk's first row: its trace index, or in selection
      ## mode its position in the selection (`traceAt` maps it).
    count*: int         ## Traces in the chunk.
    samples*: Tensor[T] ## `[count, cols]`; shorter traces are zero-padded.
    failed*: int        ## Traces that could not be decoded (left zero).
    failedRows*: seq[int] ## Those traces' rows (0-based in the chunk), ascending.
    firstSample*: int
      ## The trace sample in column 0: the prefetcher's `firstSample` (0
      ## unless it decodes a sample window).
    log*: DiagLog
      ## One error per trace that could not be decoded: its trace index
      ## (`loc.trace`), record, byte offset and the reason.
    rows*: TraceRows
      ## Which trace each row is, with its keys (when the file has stored
      ## keys), sample count and channel set, in place in the index: no
      ## `traceAt` needed. Valid until the prefetcher's `close`, also when
      ## the file is closed, destroyed or handed to an editor first (the
      ## keys are then those of that moment).

proc shutdown[T](sh: ptr Shared[T]) =
  # Stops and joins the workers, then frees the shared state.
  acquire(sh.lock)
  sh.quit = true
  broadcast(sh.work)
  release(sh.lock)
  for i in 0..<sh.workers: joinThread(sh.threads[i])
  freeShared(sh.threads)
  deinitCond(sh.work)
  deinitCond(sh.ready)
  deinitLock(sh.lock)
  for i in 0..<sh.depth:
    freeShared(sh.slots[i].fails)
    freeShared(sh.slots[i].failRows)
  freeShared(sh.slots)
  freeShared(sh)

proc `=destroy`[T](p: Prefetcher[T]) =
  # A forgotten `close` must not leave a worker writing into freed buffers:
  # join it before the slot tensors go.
  if p.sh != nil: shutdown(p.sh)
  `=destroy`(p.pin) # after the shutdown: the workers read the map
  `=destroy`(p.tensors)
  `=destroy`(p.spare)
  `=destroy`(p.selection) # after the shutdown: the workers read it
  `=destroy`(p.path)
  `=destroy`(p.bounds) # after the shutdown: the workers read it

proc `=copy`[T](dst: var Prefetcher[T], src: Prefetcher[T]) {.error.}
proc `=dup`[T](src: Prefetcher[T]): Prefetcher[T] {.error.}

func chunkCount[T](sh: ptr Shared[T]): int {.inline.} =
  # Chunk 0 holds `head` rows, the others `chunkTraces` (uniform: `bounds`).
  if sh.uniform: return max(sh.nBounds - 1, 0)
  let n = sh.stop - sh.start
  if n <= 0: 0
  elif n <= sh.head: 1
  else: 1 + (n - sh.head + sh.chunkTraces - 1) div sh.chunkTraces

func chunkFirst[T](sh: ptr Shared[T], n: int): int {.inline.} =
  if sh.uniform: sh.bounds[n]
  else: sh.start + (if n == 0: 0 else: sh.head + (n - 1) * sh.chunkTraces)

func chunkRows[T](sh: ptr Shared[T], n, first: int): int {.inline.} =
  if sh.uniform: sh.bounds[n + 1] - first
  else: min(if n == 0: sh.head else: sh.chunkTraces, sh.stop - first)

proc chunkView(v: TraceRows, first, count: int): TraceRows {.raises: [].} =
  # The rows of positions `first ..< first + count` (always inside `v`).
  try: v.sub(first ..< first + count)
  except ValueError: TraceRows()

func headRows[T](sh: ptr Shared[T]): int {.inline.} =
  if sh.quick: max(1, sh.chunkTraces div 4) else: sh.chunkTraces

proc traceOf[T](sh: ptr Shared[T], pos: int): int {.inline.} =
  if sh.sel != nil: sh.sel[pos] else: pos

proc decodeChunk[T](sh: ptr Shared[T], s: ptr Slot[T], worker: int) {.raises: [].} =
  # Runs without the lock: the slot is busy, so nobody else touches it.
  # `tryDecodeEntry` reports failures as a status: no exception is made on
  # this thread (one destroyed here would leak ORC's per-thread cycle buffer).
  adviseTraces(sh.mem, sh.size, sh.entries, sh.codecs, sh.sel, s.aheadLo, s.aheadHi, sh.cols,
    sh.firstSample)
  s.failed = 0
  for k in 0..<s.count:
    let row = cast[ptr UncheckedArray[T]](addr s.data[k * sh.cols])
    let e = sh.entries[sh.traceOf(s.first + k)]
    let st = tryDecodeEntry(sh.mem, sh.size, e, sh.codecs[e.record], row, sh.cols,
      sh.firstSample)
    if st != dsOk:
      for c in 0..<sh.cols: row[c] = T(0)
      s.fails[s.failed] = FailedRow(row: k,
        code: if st == dsTruncated: dcTruncated else: dcUnsupportedFormat)
      s.failRows[s.failed] = k
      inc s.failed
  if sh.transform != nil:
    sh.transform(worker, s.data, s.count, sh.cols, chunkView(sh.view, s.first, s.count),
      s.failRows.toOpenArray(0, s.failed - 1), sh.user)

proc worker[T](arg: (ptr Shared[T], int)) {.thread.} =
  let (sh, index) = arg
  acquire(sh.lock)
  while not sh.quit:
    let n = sh.nextChunk
    let s = addr sh.slots[n mod sh.depth]
    if n < sh.chunkCount and n < sh.takeChunk + sh.depth and s.state == ssFree:
      s.state = ssBusy
      s.gen = sh.gen
      s.chunk = n
      s.first = sh.chunkFirst(n)
      s.count = sh.chunkRows(n, s.first)
      # Ask the OS for the pages ahead while this chunk decodes, about
      # `AdviseAheadBytes` at a time (one residency probe per span, not per
      # chunk: two `mincore` calls per 64-trace chunk cost 16 % of a warm
      # run). A range is advised once after a start or `seek`, from this
      # chunk on; the kernel's sequential readahead then keeps up, and more
      # advice stalls it. A list is advised span by span.
      let ahead = s.first + s.count
      let wantLo = if n == 0: s.first else: ahead
      let wantHi = min(sh.stop, ahead + sh.chunkTraces)
      if wantHi > sh.advised and (n == 0 or sh.sel != nil):
        s.aheadLo = max(wantLo, sh.advised)
        s.aheadHi = min(sh.stop, max(wantHi, s.aheadLo + sh.aheadTraces))
        sh.advised = s.aheadHi
      else:
        s.aheadLo = 0
        s.aheadHi = 0
      inc sh.nextChunk
      release(sh.lock)
      {.cast(gcsafe).}:
        decodeChunk(sh, s, index)
      acquire(sh.lock)
      if s.gen == sh.gen:
        s.state = ssReady
        broadcast(sh.ready)
      else:
        s.state = ssFree # dropped by a seek: another worker may wait for the slot
        broadcast(sh.work)
    else:
      wait(sh.work, sh.lock)
  release(sh.lock)

proc rawData[T](t: Tensor[T]): ptr UncheckedArray[T] {.inline.} =
  cast[ptr UncheckedArray[T]](t.unsafe_raw_offset())

proc raiseArg(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

const AdviseAheadBytes = 4 shl 20
  ## The workers advise read-ahead (`adviseTraces`) for about this many
  ## bytes of samples at a time.

const DefaultRingBytes* = 4 shl 20
  ## `newPrefetcher`'s default cap on the ring's slot buffers: decoded
  ## chunks stay in the CPU cache until taken (16 MB rings fell to about 60 %
  ## of the throughput).

func sameClass(v: TraceRows, a, b: int): bool {.inline.} =
  # Positions `a` and `b` share a channel set and a sample interval.
  let x = v.traceKeys(a).intervalUs
  let y = v.traceKeys(b).intervalUs
  v.channelSetIndex(a) == v.channelSetIndex(b) and (x == y or (x.isNaN and y.isNaN))

func uniformBounds(v: TraceRows, start, stop, chunkTraces, head: int): seq[int] =
  # Chunk bounds over positions `start ..< stop`: at most `head` rows in the
  # first chunk and `chunkTraces` in the others, cut short where the channel
  # set or the sample interval changes.
  result = @[start]
  var cur = start
  while cur < stop:
    let limit = if result.len == 1: head else: chunkTraces
    var e = cur + 1
    while e < stop and e - cur < limit and sameClass(v, cur, e): inc e
    result.add e
    cur = e

proc setBounds[T](p: var Prefetcher[T], bounds: sink seq[int]) =
  # Under the lock (or before the workers start): the uniform chunk bounds
  # of the current range, computed outside it. The old ones go now: workers
  # read them only under the lock.
  let sh = p.sh
  p.bounds = bounds
  sh.bounds = cast[ptr UncheckedArray[int]](addr p.bounds[0])
  sh.nBounds = p.bounds.len

proc newPrefetcher*[T: SampleType](f: SeismicFile, traces: Slice[int], chunkTraces = 256,
    depth = 4, cols = -1, firstSample = 0, workers = 1, quickFirst = false,
    maxRingBytes = DefaultRingBytes, uniform = false, transform: ChunkTransform[T] = nil,
    user: pointer = nil): Prefetcher[T] =
  ## Starts decoding `traces` on `workers` threads, `chunkTraces` at a time,
  ## at most `depth` chunks ahead. The ring holds at most `maxRingBytes` of
  ## chunks (`chunkTraces * cols * sizeof(T)` each), but at least `workers +
  ## 1` and at most `depth`: `p.depth` is the depth used. With `quickFirst`,
  ## the first chunk of the range and after each `seek` has `chunkTraces div
  ## 4` traces (at least 1), so it arrives sooner; later chunks start right
  ## after it. Rows hold samples `firstSample ..< firstSample
  ## + cols` of each trace, zero past its end (`cols` -1: up to the end of
  ## the range's largest trace), as the windowed `readTracesInto`. `f` may
  ## be closed meanwhile (the prefetcher keeps the map until its `close`),
  ## but its index must not change. Raises `ValueError` for traces outside
  ## the file (an empty range must still start in `0 .. f.len`), a closed or
  ## tape file, a non-positive chunk size, depth or worker count, a
  ## negative `firstSample`, or a window or chunk size beyond the `int` range.
  ##
  ## Each chunk's `rows` says which trace each row is (Phase 16). With
  ## `uniform`, a chunk never spans two channel sets or sample intervals
  ## (`TraceKeys.intervalUs`): it is cut short at the boundary, so every
  ## chunk has one interval; it needs stored keys (`ValueError` otherwise).
  ## `transform` runs on the worker after each chunk is decoded (see
  ## `ChunkTransform`), with `user` passed through.
  if uniform and not f.hasKeys: raiseArg("uniform chunks need stored keys (keys = true)")
  if f.len > 0: f.requireOpen()
  if not f.index.contiguous: raiseArg("prefetch needs a plain disk file")
  if chunkTraces <= 0 or depth <= 0 or cols < -1 or firstSample < 0 or workers <= 0:
    raiseArg("need chunkTraces > 0, depth > 0, cols >= -1, firstSample >= 0 and workers > 0")
  if cols > high(int) - firstSample:
    raiseArg("the sample window " & $firstSample & " + " & $cols & " lies outside the int range")
  checkSpan(traces, f.len)
  let first = traces.a
  let stop = if traces.b >= first: traces.b + 1 else: first
  let width = if cols >= 0: cols
    elif first < stop: max(f.maxSamples(first..<stop) - firstSample, 0)
    else: 0
  # No range (even after a seek) holds more traces than the file.
  let rows = max(1, min(chunkTraces, f.len))
  if width > 0 and rows > high(int) div sizeof(T) div width:
    raiseArg("chunks of " & $rows & " traces of " & $width & " samples are too large")
  let chunkBytes = rows * width * sizeof(T)
  # min(depth, max(workers + 1, fit)), without a sum that could overflow.
  let fit = if chunkBytes == 0: depth else: maxRingBytes div chunkBytes
  let depth = if fit > workers: min(depth, fit)
              elif workers < depth: workers + 1
              else: depth
  let sh = createShared(Shared[T])
  sh.slots = cast[ptr UncheckedArray[Slot[T]]](createShared(Slot[T], depth))
  sh.depth = depth
  sh.start = first
  sh.stop = stop
  sh.chunkTraces = rows
  sh.quick = quickFirst
  sh.head = sh.headRows
  sh.advised = first
  sh.aheadTraces = max(rows, AdviseAheadBytes div max(1, width * 4))
  sh.cols = width
  sh.firstSample = firstSample
  sh.mem = f.unsafeMemory
  sh.size = f.mappedSize
  if f.len > 0:
    sh.entries = cast[ptr UncheckedArray[TraceEntry]](addr f.index.entries[0])
    sh.codecs = cast[ptr UncheckedArray[TraceCodec]](addr f.index.codecs[0])
  sh.view = f.rowsOf(0 ..< f.len)
  sh.uniform = uniform
  sh.transform = transform
  sh.user = user
  initLock(sh.lock)
  initCond(sh.work)
  initCond(sh.ready)
  result = Prefetcher[T](sh: sh, pin: f.pinMap, last: f.len, path: f.path)
  if uniform: result.setBounds(uniformBounds(sh.view, sh.start, sh.stop, rows, sh.head))
  result.untaken = sh.chunkCount
  for i in 0..<depth:
    result.tensors.add newTensorUninit[T](rows, width)
    sh.slots[i].data = rawData(result.tensors[i])
    sh.slots[i].fails = cast[ptr UncheckedArray[FailedRow]](createShared(FailedRow, rows))
    sh.slots[i].failRows = cast[ptr UncheckedArray[int]](createShared(int, rows))
  sh.workers = workers
  sh.threads = cast[ptr UncheckedArray[Thread[(ptr Shared[T], int)]]](
    createShared(Thread[(ptr Shared[T], int)], workers))
  for i in 0..<workers: createThread(sh.threads[i], worker[T], (sh, i))

proc newPrefetcher*[T: SampleType](f: SeismicFile, traces: sink seq[int], chunkTraces = 256,
    depth = 4, cols = -1, firstSample = 0, workers = 1, quickFirst = false,
    maxRingBytes = DefaultRingBytes, uniform = false, transform: ChunkTransform[T] = nil,
    user: pointer = nil): Prefetcher[T] =
  ## Read-ahead over a list of trace indices (a gather, a component group, a
  ## sort order), decoded in list order. Positions (`seek`) index the list;
  ## `traceAt` maps them to traces. The list is fixed for the prefetcher's
  ## life (for another list, make another prefetcher).
  for i in traces:
    if i notin 0 ..< f.len: raiseArg("trace " & $i & " lies outside the file")
  let width = if cols >= 0: cols else: max(f.maxSamples(traces) - firstSample, 0)
  # Build in range mode over positions, then switch the workers to the list
  # before they can run: the lock orders the hand-over.
  result = newPrefetcher[T](f, 0 .. -1, chunkTraces, depth, width, firstSample, workers,
    quickFirst, maxRingBytes, uniform, transform, user)
  result.selection = traces
  result.last = result.selection.len
  let sh = result.sh
  acquire(sh.lock)
  if result.selection.len > 0:
    sh.sel = cast[ptr UncheckedArray[int]](addr result.selection[0])
  sh.view = f.rowsOf(result.selection)
  sh.stop = result.selection.len
  if uniform:
    result.setBounds(uniformBounds(sh.view, 0, sh.stop, sh.chunkTraces, sh.head))
  result.untaken = sh.chunkCount
  broadcast(sh.work)
  release(sh.lock)

func depth*[T](p: Prefetcher[T]): int {.inline.} =
  ## The ring's depth: `newPrefetcher`'s `depth`, or less under its
  ## `maxRingBytes` cap (0 after `close`).
  if p.sh == nil: 0 else: p.sh.depth

func len*[T](p: Prefetcher[T]): int {.inline.} =
  ## The number of positions `seek` accepts: the file's trace count, or the
  ## selection's length.
  p.last

proc traceAt*[T](p: Prefetcher[T], pos: int): int =
  ## The trace index at position `pos` (the position itself in range mode).
  ## Raises `ValueError` for a position outside `0 ..< p.len`.
  if pos notin 0 ..< p.last: raiseArg("position " & $pos & " is outside 0.." & $(p.last - 1))
  if p.selection.len > 0: p.selection[pos] else: pos

proc reusable[T](p: Prefetcher[T], t: Tensor[T]): bool =
  # `t` can be a slot buffer: the slot's shape, row-major from its storage's
  # start, and that storage is its own and held by nobody else (a copy or a
  # view of the tensor shares it).
  let sh = p.sh
  sh.cols > 0 and t.rank == 2 and t.shape[0] == sh.chunkTraces and t.shape[1] == sh.cols and
    t.offset == 0 and t.is_C_contiguous and not t.storage.isNil and
    t.storage.isMemOwner and isUniqueRef(t.storage)

proc recycle*[T](p: var Prefetcher[T], t: sink Tensor[T]) =
  ## Gives a chunk's tensor back: a later chunk is decoded into it instead of
  ## a fresh allocation. The caller gives the buffer up (pass it with `move`;
  ## its raw data must not be used again). Dropped, as if destroyed, unless it
  ## has the chunk shape `[chunkTraces, cols]` and nothing else shares its
  ## storage (a copy, a view), or when `depth` buffers are already spare.
  if p.sh != nil and p.spare.len < p.sh.depth and p.reusable(t): p.spare.add t

proc recycle*[T](p: var Prefetcher[T], c: sink PrefetchChunk[T]) {.inline.} =
  ## `recycle(p, c.samples)`.
  p.recycle(move c.samples)

proc take[T](p: var Prefetcher[T], c: var PrefetchChunk[T], into: bool) =
  # Called with the head slot ready; hands its tensor over and gives the slot
  # another buffer: with `into`, the caller's previous one if reusable, else
  # a spare or a fresh one. The worker does not touch ready slots, so the
  # swap runs unlocked.
  let sh = p.sh
  let i = sh.takeChunk mod sh.depth
  let s = addr sh.slots[i]
  c.first = s.first
  c.count = s.count
  c.firstSample = sh.firstSample
  c.failed = s.failed
  c.failedRows.setLen s.failed
  for k in 0..<s.failed: c.failedRows[k] = s.failRows[k]
  c.rows = chunkView(sh.view, s.first, s.count)
  c.log = DiagLog()
  for k in 0..<s.failed:
    let fr = s.fails[k]
    let trace = sh.traceOf(s.first + fr.row)
    let e = sh.entries[trace]
    c.log.report(sevError, fr.code, if fr.code == dcTruncated:
      "trace samples lie past the end of the file" else: "the sample format is not decodable",
      e.offset, Location(file: p.path, trace: trace,
        # SEG-2: `record` indexes the codecs; the file is one record.
        record: if sh.codecs[e.record].kind == skSeg2: 0 else: int(e.record)))
  if s.count == sh.chunkTraces:
    if into and p.reusable(c.samples):
      swap(c.samples, p.tensors[i])
    else:
      c.samples = move(p.tensors[i])
      p.tensors[i] = if p.spare.len > 0: p.spare.pop
        else: newTensorUninit[T](sh.chunkTraces, sh.cols)
  else:
    if into: p.recycle(move c.samples)
    c.samples = if sh.cols == 0: newTensor[T](s.count, 0)
      else: p.tensors[i][0..<s.count, _].clone() # the slot keeps its buffer
  acquire(sh.lock)
  s.data = rawData(p.tensors[i])
  s.state = ssFree
  inc sh.takeChunk
  dec p.untaken
  broadcast(sh.work)
  release(sh.lock)

proc headReady[T](sh: ptr Shared[T]): bool {.inline.} =
  # Under the lock. Reads only the fields the lock guards: a busy slot's
  # other fields are being written by the worker.
  let s = addr sh.slots[sh.takeChunk mod sh.depth]
  s.state == ssReady and s.chunk == sh.takeChunk and s.gen == sh.gen

func atEnd*[T](p: Prefetcher[T]): bool {.inline.} =
  ## True when every chunk of the range has been taken (or after `close`).
  p.sh == nil or p.untaken <= 0

proc pollTake[T](p: var Prefetcher[T], c: var PrefetchChunk[T], into: bool): bool =
  if p.sh == nil: return false
  acquire(p.sh.lock)
  let ok = p.sh.takeChunk < p.sh.chunkCount and p.sh.headReady
  release(p.sh.lock)
  if ok: p.take(c, into)
  ok

proc waitTake[T](p: var Prefetcher[T], c: var PrefetchChunk[T], into: bool): bool =
  if p.sh == nil: return false
  acquire(p.sh.lock)
  let more = p.sh.takeChunk < p.sh.chunkCount
  while more and not p.sh.headReady:
    wait(p.sh.ready, p.sh.lock)
  release(p.sh.lock)
  if more: p.take(c, into)
  more

proc tryNext*[T](p: var Prefetcher[T], c: var PrefetchChunk[T]): bool =
  ## Takes the next chunk if it is decoded; never blocks. False if it is not
  ## ready yet, the range is done (see `atEnd`) or the prefetcher is closed.
  p.pollTake(c, into = false)

proc next*[T](p: var Prefetcher[T], c: var PrefetchChunk[T]): bool =
  ## Takes the next chunk, waiting until it is decoded. False when the range
  ## is done (or the prefetcher is closed).
  p.waitTake(c, into = false)

proc tryNextInto*[T](p: var Prefetcher[T], c: var PrefetchChunk[T]): bool =
  ## `tryNext`, but the caller gives up `c`'s previous `samples`: when the
  ## next chunk is taken, that buffer becomes a decode target (as `recycle`).
  ## On false, `c` is unchanged.
  p.pollTake(c, into = true)

proc nextInto*[T](p: var Prefetcher[T], c: var PrefetchChunk[T]): bool =
  ## `next`, but the caller gives up `c`'s previous `samples`: if it has the
  ## chunk shape and nothing else shares it, the slot decodes into it next
  ## (no allocation); otherwise it is recycled or dropped. A copy or view of
  ## it that the caller kept only prevents the reuse (they share its
  ## storage), but a raw pointer into it must not outlive the call.
  p.waitTake(c, into = true)

iterator chunks*[T](p: var Prefetcher[T]): PrefetchChunk[T] =
  ## Yields the chunks of the current range in order, waiting for each
  ## (`next` in a loop). Do not `seek` or `close` inside the loop.
  var c: PrefetchChunk[T]
  while p.next(c): yield move(c)

proc seek*[T](p: var Prefetcher[T], span: Slice[int]) =
  ## Restarts read-ahead over the positions `span` (traces in range mode).
  ## Chunks decoded for the old positions are dropped; one being decoded
  ## finishes in the background and is discarded. A no-op after `close`.
  ## Raises `ValueError` for positions out of range (an empty span must
  ## still start in `0 .. len`).
  if p.sh == nil: return
  checkSpan(span, p.last, "positions")
  let first = span.a
  let stop = if span.b >= first: span.b + 1 else: first
  let sh = p.sh
  # The view and the chunk sizes never change: the bounds are cut before the
  # workers are stopped.
  var bounds: seq[int]
  if sh.uniform: bounds = uniformBounds(sh.view, first, stop, sh.chunkTraces, sh.headRows)
  acquire(sh.lock)
  inc sh.gen
  sh.start = first
  sh.stop = stop
  sh.nextChunk = 0
  sh.takeChunk = 0
  sh.head = sh.headRows
  sh.advised = first
  if sh.uniform: p.setBounds(move bounds)
  p.untaken = sh.chunkCount
  for i in 0..<sh.depth:
    if sh.slots[i].state == ssReady: sh.slots[i].state = ssFree
  broadcast(sh.work)
  release(sh.lock)

proc close*[T](p: var Prefetcher[T]) =
  ## Stops and joins the workers and frees the ring. Idempotent.
  if p.sh != nil:
    shutdown(p.sh)
    p.sh = nil
    p.pin = MapPin() # the last pin unmaps a file closed meanwhile
    p.tensors.setLen 0
    p.spare.setLen 0
    p.selection.setLen 0
    p.bounds.setLen 0
