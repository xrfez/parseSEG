## Read-ahead on a worker thread (task 6.3).
##
## A `Prefetcher` decodes a trace range of a `SeismicFile` in chunks of
## `chunkTraces` traces, ahead of the consumer, into a bounded ring of
## `depth` chunks. The consumer (e.g. a viewer's UI thread) polls with
## `tryNext` (never blocks) or waits with `next`; `seek` jumps elsewhere
## (chunks decoded for the old position are dropped).
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
## Ownership: the worker shares no managed memory with the consumer (the
## only managed objects it makes are exceptions it raises and catches
## itself). It reads the file's map and index through raw pointers, decodes
## into slot buffers that the consumer thread allocated (`decodeEntry`), and
## notes the rows that failed in a plain array of the slot; the consumer
## turns those into the chunk's diagnostics. When the consumer takes a chunk,
## it takes the slot's tensor and gives the slot another one, so a tensor
## returned by `next` is never written again. That one is fresh, or one the
## caller gave up: the previous chunk's with `nextInto`, a `recycle`d one.
## Only tensors of the slot shape whose storage they own alone (no copy,
## view or `fromBuffer` shares it) are reused; others are dropped.
##
## Lifetime: the prefetcher pins the file's map, so `f.close()` (or the file
## going out of scope) while it runs is safe: the map, and if the file is
## destroyed its trace entries and codecs, stay alive until the prefetcher's
## `close`. What remains a rule: do not change the file's index
## (`applySurvey`, `applyGeometry`, assigning to `f.index`) while a
## prefetcher runs, and call the consumer procs from one thread.

import std/locks
import ../common/[diagnostics, errors]
import ../segy/samples
import ./traceindex

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
    failed: int  # rows that could not be decoded: `fails[0 ..< failed]`
    fails: ptr UncheckedArray[FailedRow] # `chunkTraces` entries
    data: ptr UncheckedArray[T]

  Shared[T] = object
    lock: Lock
    work: Cond   # the worker waits here for a free slot or a stop
    ready: Cond  # the consumer waits here for a ready chunk
    slots: ptr UncheckedArray[Slot[T]]
    depth: int
    gen: int
    start, stop: int # trace range [start, stop) of the current generation
    nextChunk: int   # next chunk the worker decodes
    takeChunk: int   # next chunk the consumer takes
    quit: bool
    chunkTraces, cols: int
    firstSample: int # samples `firstSample ..< firstSample + cols` of each trace
    mem: ptr UncheckedArray[byte]
    size: int64
    entries: ptr UncheckedArray[TraceEntry]
    codecs: ptr UncheckedArray[TraceCodec]
    sel: ptr UncheckedArray[int] # selection mode: positions index this list; nil = ranges
    thread: Thread[ptr Shared[T]]

  Prefetcher*[T: SampleType] = object
    ## Read-ahead state; not copyable. Call `close` when done.
    sh: ptr Shared[T]
    pin: MapPin             # keeps the map (and a destroyed file's index) alive for the worker
    tensors: seq[Tensor[T]] # slot storage, consumer side
    spare: seq[Tensor[T]]   # recycled slot-shaped buffers, at most `depth`
    last: int               # end of the whole range (exclusive)
    selection: seq[int]     # selection mode: the trace list (fixed for the prefetcher's life)
    path: string            # the file's, for diagnostics
    untaken: int            # chunks of the range not yet taken: `sh.chunkCount - sh.takeChunk`,
                            # kept by the consumer so `atEnd` needs no lock

  PrefetchChunk*[T: SampleType] = object
    first*: int
      ## Position of the chunk's first row: its trace index, or in selection
      ## mode its position in the selection (`traceAt` maps it).
    count*: int         ## Traces in the chunk.
    samples*: Tensor[T] ## `[count, cols]`; shorter traces are zero-padded.
    failed*: int        ## Traces that could not be decoded (left zero).
    log*: DiagLog
      ## One error per trace that could not be decoded: its trace index
      ## (`loc.trace`), record, byte offset and the reason.

proc shutdown[T](sh: ptr Shared[T]) =
  # Stops and joins the worker, then frees the shared state.
  acquire(sh.lock)
  sh.quit = true
  signal(sh.work)
  release(sh.lock)
  joinThread(sh.thread)
  deinitCond(sh.work)
  deinitCond(sh.ready)
  deinitLock(sh.lock)
  for i in 0..<sh.depth: freeShared(sh.slots[i].fails)
  freeShared(sh.slots)
  freeShared(sh)

proc `=destroy`*[T](p: Prefetcher[T]) =
  # A forgotten `close` must not leave a worker writing into freed buffers:
  # join it before the slot tensors go.
  if p.sh != nil: shutdown(p.sh)
  `=destroy`(p.pin) # after the shutdown: the worker reads the map
  `=destroy`(p.tensors)
  `=destroy`(p.spare)
  `=destroy`(p.selection) # after the shutdown: the worker reads it
  `=destroy`(p.path)

proc `=copy`*[T](dst: var Prefetcher[T], src: Prefetcher[T]) {.error.}

func chunkCount[T](sh: ptr Shared[T]): int {.inline.} =
  (sh.stop - sh.start + sh.chunkTraces - 1) div sh.chunkTraces

proc traceOf[T](sh: ptr Shared[T], pos: int): int {.inline.} =
  if sh.sel != nil: sh.sel[pos] else: pos

proc decodeChunk[T](sh: ptr Shared[T], s: ptr Slot[T]) {.raises: [].} =
  # Runs without the lock: the slot is busy, so nobody else touches it.
  # `decodeEntry` raises only `SegError`s (an undecodable format, samples
  # past the end of the map).
  s.failed = 0
  for k in 0..<s.count:
    let row = cast[ptr UncheckedArray[T]](addr s.data[k * sh.cols])
    let e = sh.entries[sh.traceOf(s.first + k)]
    try:
      decodeEntry(sh.mem, sh.size, e, sh.codecs[e.record], row, sh.cols, sh.firstSample)
    except SegError as err:
      for c in 0..<sh.cols: row[c] = T(0)
      s.fails[s.failed] = FailedRow(row: k,
        code: if err of SegTruncatedError: dcTruncated else: dcUnsupportedFormat)
      inc s.failed

proc worker[T](sh: ptr Shared[T]) {.thread.} =
  acquire(sh.lock)
  while not sh.quit:
    let n = sh.nextChunk
    let s = addr sh.slots[n mod sh.depth]
    if n < sh.chunkCount and n < sh.takeChunk + sh.depth and s.state == ssFree:
      s.state = ssBusy
      s.gen = sh.gen
      s.chunk = n
      s.first = sh.start + n * sh.chunkTraces
      s.count = min(sh.chunkTraces, sh.stop - s.first)
      inc sh.nextChunk
      release(sh.lock)
      {.cast(gcsafe).}:
        decodeChunk(sh, s)
      acquire(sh.lock)
      s.state = if s.gen == sh.gen: ssReady else: ssFree # dropped by a seek
      broadcast(sh.ready)
    else:
      wait(sh.work, sh.lock)
  release(sh.lock)

proc rawData[T](t: Tensor[T]): ptr UncheckedArray[T] {.inline.} =
  cast[ptr UncheckedArray[T]](t.unsafe_raw_offset())

proc raiseArg(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

proc newPrefetcher*[T: SampleType](f: SeismicFile, traces: Slice[int], chunkTraces = 256,
    depth = 4, cols = -1, firstSample = 0): Prefetcher[T] =
  ## Starts decoding `traces` on a worker thread, `chunkTraces` at a time, at
  ## most `depth` chunks ahead. Rows hold samples `firstSample ..< firstSample
  ## + cols` of each trace, zero past its end (`cols` -1: up to the end of
  ## the range's largest trace), as the windowed `readTracesInto`. `f` may
  ## be closed meanwhile (the prefetcher keeps the map until its `close`),
  ## but its index must not change. Raises `ValueError` for traces outside
  ## the file (an empty range must still start in `0 .. f.len`), a closed or
  ## tape file, a non-positive chunk size or depth, or a negative
  ## `firstSample`.
  if not f.isOpen and f.len > 0: raiseArg("the file is closed")
  if not f.index.contiguous: raiseArg("prefetch needs a plain disk file")
  if chunkTraces <= 0 or depth <= 0 or cols < -1 or firstSample < 0:
    raiseArg("need chunkTraces > 0, depth > 0, cols >= -1 and firstSample >= 0")
  checkSpan(traces, f.len)
  let first = traces.a
  let stop = if traces.b >= first: traces.b + 1 else: first
  let width = if cols >= 0: cols
    elif first < stop: max(f.maxSamples(first..<stop) - firstSample, 0)
    else: 0
  # No range (even after a seek) holds more traces than the file.
  let rows = max(1, min(chunkTraces, f.len))
  let sh = createShared(Shared[T])
  sh.slots = cast[ptr UncheckedArray[Slot[T]]](createShared(Slot[T], depth))
  sh.depth = depth
  sh.start = first
  sh.stop = stop
  sh.chunkTraces = rows
  sh.cols = width
  sh.firstSample = firstSample
  sh.mem = f.unsafeMemory
  sh.size = f.mappedSize
  if f.len > 0:
    sh.entries = cast[ptr UncheckedArray[TraceEntry]](addr f.index.entries[0])
    sh.codecs = cast[ptr UncheckedArray[TraceCodec]](addr f.index.codecs[0])
  initLock(sh.lock)
  initCond(sh.work)
  initCond(sh.ready)
  result = Prefetcher[T](sh: sh, pin: f.pinMap, last: f.len, untaken: sh.chunkCount,
    path: f.path)
  for i in 0..<depth:
    result.tensors.add newTensorUninit[T](rows, width)
    sh.slots[i].data = rawData(result.tensors[i])
    sh.slots[i].fails = cast[ptr UncheckedArray[FailedRow]](createShared(FailedRow, rows))
  createThread(sh.thread, worker[T], sh)

proc newPrefetcher*[T: SampleType](f: SeismicFile, traces: sink seq[int], chunkTraces = 256,
    depth = 4, cols = -1, firstSample = 0): Prefetcher[T] =
  ## Read-ahead over a list of trace indices (a gather, a component group, a
  ## sort order), decoded in list order. Positions (`seek`) index the list;
  ## `traceAt` maps them to traces. The list is fixed for the prefetcher's
  ## life (for another list, make another prefetcher).
  for i in traces:
    if i notin 0 ..< f.len: raiseArg("trace " & $i & " lies outside the file")
  let width = if cols >= 0: cols else: max(f.maxSamples(traces) - firstSample, 0)
  # Build in range mode over positions, then switch the worker to the list
  # before it can run: the lock orders the hand-over.
  result = newPrefetcher[T](f, 0 .. -1, chunkTraces, depth, width, firstSample)
  result.selection = traces
  result.last = result.selection.len
  let sh = result.sh
  acquire(sh.lock)
  if result.selection.len > 0:
    sh.sel = cast[ptr UncheckedArray[int]](addr result.selection[0])
  sh.stop = result.selection.len
  result.untaken = sh.chunkCount
  signal(sh.work)
  release(sh.lock)

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
  c.failed = s.failed
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
  signal(sh.work)
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
  acquire(sh.lock)
  inc sh.gen
  sh.start = first
  sh.stop = stop
  sh.nextChunk = 0
  sh.takeChunk = 0
  p.untaken = sh.chunkCount
  for i in 0..<sh.depth:
    if sh.slots[i].state == ssReady: sh.slots[i].state = ssFree
  signal(sh.work)
  release(sh.lock)

proc close*[T](p: var Prefetcher[T]) =
  ## Stops and joins the worker and frees the ring. Idempotent.
  if p.sh != nil:
    shutdown(p.sh)
    p.sh = nil
    p.pin = MapPin() # the last pin unmaps a file closed meanwhile
    p.tensors.setLen 0
    p.spare.setLen 0
    p.selection.setLen 0
