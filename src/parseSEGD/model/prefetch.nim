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
## var p = newPrefetcher[float32](f, chunkTraces = 512, depth = 4)
## var c: PrefetchChunk[float32]
## while p.next(c):
##   show(c.first, c.samples)      # [c.count, cols] tensor, owned by the caller
## p.close()
## ```
##
## Ownership: the worker shares no managed memory with the consumer (the
## only managed objects it makes are exceptions it raises and catches
## itself). It reads the file's map
## and index through raw pointers and decodes into slot buffers that the
## consumer thread allocated (`decodeEntry`). When the consumer takes a chunk,
## it takes the slot's tensor and allocates a fresh one for the slot, so a
## returned tensor is never written again. Hence the contract: the
## `SeismicFile` must stay open and its index unchanged until `close`, and
## only one thread may call the consumer procs.

import std/locks
import ../segy/samples
import ./traceindex

type
  SlotState = enum ssFree, ssBusy, ssReady

  Slot[T] = object
    state: SlotState
    gen: int     # generation (see `seek`) the chunk was decoded for
    chunk: int   # chunk number since the last seek
    first, count: int
    failed: int  # traces that could not be decoded
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
    mem: ptr UncheckedArray[byte]
    size: int64
    entries: ptr UncheckedArray[TraceEntry]
    codecs: ptr UncheckedArray[TraceCodec]
    sel: ptr UncheckedArray[int] # selection mode: positions index this list; nil = ranges
    thread: Thread[ptr Shared[T]]

  Prefetcher*[T: SampleType] = object
    ## Read-ahead state; not copyable. Call `close` when done.
    sh: ptr Shared[T]
    tensors: seq[Tensor[T]] # slot storage, consumer side
    last: int               # end of the whole range (exclusive)
    selection: seq[int]     # selection mode: the trace list (fixed for the prefetcher's life)

  PrefetchChunk*[T: SampleType] = object
    first*: int
      ## Position of the chunk's first row: its trace index, or in selection
      ## mode its position in the selection (`traceAt` maps it).
    count*: int         ## Traces in the chunk.
    samples*: Tensor[T] ## `[count, cols]`; shorter traces are zero-padded.
    failed*: int        ## Traces that could not be decoded (left zero).

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
  freeShared(sh.slots)
  freeShared(sh)

proc `=destroy`*[T](p: Prefetcher[T]) =
  # A forgotten `close` must not leave a worker writing into freed buffers:
  # join it before the slot tensors go.
  if p.sh != nil: shutdown(p.sh)
  `=destroy`(p.tensors)

proc `=copy`*[T](dst: var Prefetcher[T], src: Prefetcher[T]) {.error.}

func chunkCount[T](sh: ptr Shared[T]): int {.inline.} =
  (sh.stop - sh.start + sh.chunkTraces - 1) div sh.chunkTraces

proc decodeChunk[T](sh: ptr Shared[T], s: ptr Slot[T]) =
  # Runs without the lock: the slot is busy, so nobody else touches it.
  s.failed = 0
  for k in 0..<s.count:
    let row = cast[ptr UncheckedArray[T]](addr s.data[k * sh.cols])
    let pos = s.first + k
    let e = sh.entries[if sh.sel != nil: sh.sel[pos] else: pos]
    try:
      decodeEntry(sh.mem, sh.size, e, sh.codecs[e.record], row, sh.cols)
    except CatchableError:
      for c in 0..<sh.cols: row[c] = T(0)
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

proc newPrefetcher*[T: SampleType](f: SeismicFile, first = 0, last = -1, chunkTraces = 256,
    depth = 4, cols = -1): Prefetcher[T] =
  ## Starts decoding traces `first ..< last` (`last = -1`: to the end) on a
  ## worker thread, `chunkTraces` at a time, at most `depth` chunks ahead.
  ## Rows have `cols` samples (default: the range's largest trace). `f` must
  ## stay open, its index unchanged, until `close`.
  doAssert f.memory != nil or f.len == 0, "the file is closed"
  doAssert f.index.contiguous, "prefetch needs a plain disk file"
  doAssert chunkTraces > 0 and depth > 0
  let stop = if last < 0: f.len else: last
  doAssert first >= 0 and first <= stop and stop <= f.len, "trace range out of bounds"
  let width = if cols >= 0: cols elif first < stop: f.maxSamples(first..<stop) else: 0
  # No range (even after a seek) holds more traces than the file.
  let rows = max(1, min(chunkTraces, f.len))
  let sh = createShared(Shared[T])
  sh.slots = cast[ptr UncheckedArray[Slot[T]]](createShared(Slot[T], depth))
  sh.depth = depth
  sh.start = first
  sh.stop = stop
  sh.chunkTraces = rows
  sh.cols = width
  sh.mem = f.memory
  sh.size = f.mappedSize
  if f.len > 0:
    sh.entries = cast[ptr UncheckedArray[TraceEntry]](unsafeAddr f.index.entries[0])
    sh.codecs = cast[ptr UncheckedArray[TraceCodec]](unsafeAddr f.index.codecs[0])
  initLock(sh.lock)
  initCond(sh.work)
  initCond(sh.ready)
  result = Prefetcher[T](sh: sh, last: f.len)
  for i in 0..<depth:
    result.tensors.add newTensorUninit[T](rows, width)
    sh.slots[i].data = rawData(result.tensors[i])
  createThread(sh.thread, worker[T], sh)

proc newPrefetcher*[T: SampleType](f: SeismicFile, selection: sink seq[int], chunkTraces = 256,
    depth = 4, cols = -1): Prefetcher[T] =
  ## Read-ahead over a list of trace indices (a gather, a component group, a
  ## sort order), decoded in list order. Positions (`first`, `seek`) index
  ## the list; `traceAt` maps them to traces. The list is fixed for the
  ## prefetcher's life (for another list, make another prefetcher).
  for i in selection:
    doAssert i >= 0 and i < f.len, "trace " & $i & " is out of bounds"
  let width = if cols >= 0: cols else: f.maxSamples(selection)
  # Build in range mode over positions, then switch the worker to the list
  # before it can run: the lock orders the hand-over.
  result = newPrefetcher[T](f, 0, 0, chunkTraces, depth, width)
  result.selection = selection
  result.last = result.selection.len
  let sh = result.sh
  acquire(sh.lock)
  if result.selection.len > 0:
    sh.sel = cast[ptr UncheckedArray[int]](addr result.selection[0])
  sh.stop = result.selection.len
  signal(sh.work)
  release(sh.lock)

proc traceAt*[T](p: Prefetcher[T], pos: int): int =
  ## The trace index at position `pos` (the position itself in range mode).
  if p.selection.len > 0: p.selection[pos] else: pos

proc take[T](p: var Prefetcher[T], c: var PrefetchChunk[T]) =
  # Called with the head slot ready; hands its tensor over and gives the slot
  # a fresh buffer. The worker does not touch ready slots, so the swap runs
  # unlocked.
  let sh = p.sh
  let i = sh.takeChunk mod sh.depth
  let s = addr sh.slots[i]
  c.first = s.first
  c.count = s.count
  c.failed = s.failed
  if s.count == sh.chunkTraces:
    c.samples = move(p.tensors[i])
    p.tensors[i] = newTensorUninit[T](sh.chunkTraces, sh.cols)
  elif sh.cols == 0:
    c.samples = newTensor[T](s.count, 0)
  else:
    c.samples = p.tensors[i][0..<s.count, _].clone() # the slot keeps its buffer
  acquire(sh.lock)
  s.data = rawData(p.tensors[i])
  s.state = ssFree
  inc sh.takeChunk
  signal(sh.work)
  release(sh.lock)

proc headReady[T](sh: ptr Shared[T]): bool {.inline.} =
  # Under the lock. Reads only the fields the lock guards: a busy slot's
  # other fields are being written by the worker.
  let s = addr sh.slots[sh.takeChunk mod sh.depth]
  s.state == ssReady and s.chunk == sh.takeChunk and s.gen == sh.gen

proc atEnd*[T](p: Prefetcher[T]): bool =
  ## True when every chunk of the range has been taken (or after `close`).
  if p.sh == nil: return true
  acquire(p.sh.lock)
  result = p.sh.takeChunk >= p.sh.chunkCount
  release(p.sh.lock)

proc tryNext*[T](p: var Prefetcher[T], c: var PrefetchChunk[T]): bool =
  ## Takes the next chunk if it is decoded; never blocks. False if it is not
  ## ready yet, the range is done (see `atEnd`) or the prefetcher is closed.
  if p.sh == nil: return false
  acquire(p.sh.lock)
  let ok = p.sh.takeChunk < p.sh.chunkCount and p.sh.headReady
  release(p.sh.lock)
  if ok: p.take(c)
  ok

proc next*[T](p: var Prefetcher[T], c: var PrefetchChunk[T]): bool =
  ## Takes the next chunk, waiting until it is decoded. False when the range
  ## is done (or the prefetcher is closed).
  if p.sh == nil: return false
  acquire(p.sh.lock)
  var more = p.sh.takeChunk < p.sh.chunkCount
  while more and not p.sh.headReady:
    wait(p.sh.ready, p.sh.lock)
  release(p.sh.lock)
  if more: p.take(c)
  more

proc seek*[T](p: var Prefetcher[T], first: int, last = -1) =
  ## Restarts read-ahead at trace `first` (to `last`, exclusive; -1 = the end
  ## of the file; any negative value means the end). Chunks decoded for the old position are dropped; one being
  ## decoded finishes in the background and is discarded. A no-op after
  ## `close`.
  if p.sh == nil: return
  let stop = if last < 0: p.last else: last
  doAssert first >= 0 and first <= stop and stop <= p.last, "trace range out of bounds"
  let sh = p.sh
  acquire(sh.lock)
  inc sh.gen
  sh.start = first
  sh.stop = stop
  sh.nextChunk = 0
  sh.takeChunk = 0
  for i in 0..<sh.depth:
    if sh.slots[i].state == ssReady: sh.slots[i].state = ssFree
  signal(sh.work)
  release(sh.lock)

proc close*[T](p: var Prefetcher[T]) =
  ## Stops and joins the worker and frees the ring. Idempotent.
  if p.sh != nil:
    shutdown(p.sh)
    p.sh = nil
    p.tensors.setLen 0
