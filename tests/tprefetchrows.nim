## Prefetch chunks carry their rows (Phase 16.5): `rows` agrees with
## `traceAt` in range and selection mode, failed rows are public, uniform
## chunks never mix channel sets or intervals, and a transform runs once per
## chunk on a worker and reads keys there with `keysAt`.
## `readTracesInto` fills a failed-row list as the prefetcher does, and a
## chunk records its window origin, `firstSample`.

import std/[assertions, math, os, atomics]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tprefetchrows")

func sameKeys(a, b: TraceKeys): bool =
  result = true
  for x, y in fields(a, b):
    when x is SomeFloat:
      if not (x == y or (x.isNaN and y.isNaN)): return false
    else:
      if x != y: return false

proc checkRows(f: SeismicFile, p: var Prefetcher[float32]) =
  var seen = 0
  for c in p.chunks:
    doAssert c.rows.len == c.count
    for row in 0 ..< c.count:
      let t = p.traceAt(c.first + row)
      doAssert c.rows.traceOf(row) == t
      doAssert c.rows.numSamples(row) == int(f.traceEntry(t).numSamples)
      if f.hasKeys: doAssert sameKeys(c.rows.traceKeys(row), f.traceKeys(t))
    seen += c.count
  doAssert seen == p.len

block rows_agree_with_trace_at:
  for keys in [true, false]:
    var f = openSeismic(demoDir() / "survey.sgy", keys = keys)
    var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 30, cols = 8)
    checkRows(f, p)
    p.close()
    var sel: seq[int]
    for t in countdown(f.len - 1, 0, 3): sel.add t
    var q = newPrefetcher[float32](f, sel, chunkTraces = 7, cols = 8, workers = 2)
    checkRows(f, q)
    # After a seek too.
    q.seek(10 ..< 20)
    var c: PrefetchChunk[float32]
    doAssert q.next(c) and c.rows.traceOf(0) == sel[10]
    doAssert c.rows.hasKeys == keys
    q.close()
    f.close()

block failed_rows_are_public:
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  for t in [3, 4, 9]: f.index.entries[t].numSamples = 1_000_000_000 # past the end
  var p = newPrefetcher[float32](f, 0 ..< 12, chunkTraces = 6, cols = 8)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.failed == 2 and c.failedRows == @[3, 4]
  doAssert p.next(c) and c.failed == 1 and c.failedRows == @[3] and c.rows.traceOf(3) == 9
  p.close()
  var q = newPrefetcher[float32](f, @[9, 0, 4], chunkTraces = 3, cols = 8)
  doAssert q.next(c) and c.failedRows == @[0, 2]
  q.close()
  f.close()

block read_into_fills_failed_rows:
  # `readTracesInto` reports the failed rows as the
  # prefetcher does, into a caller's list that is cleared and reused.
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  for t in [3, 4, 9]: f.index.entries[t].numSamples = 1_000_000_000 # past the end
  var dst = newTensor[float32](12, 8)
  var failed = @[99, 98, 97, 96, 95, 94, 93, 92]
  doAssert f.readTracesInto(0 ..< 12, dst, failed) == 3 and failed == @[3, 4, 9]
  var c: PrefetchChunk[float32]
  var p = newPrefetcher[float32](f, 0 ..< 12, chunkTraces = 12, cols = 8)
  doAssert p.next(c) and c.failedRows == failed, "the same rows as the prefetcher"
  p.close()
  let selection = @[9, 0, 4]
  doAssert f.readTracesInto(selection, dst, failed, row = 2) == 2 and failed == @[0, 2],
    "positions in the selection, not rows of dst"
  var narrow = newTensor[float32](3, 4)
  doAssert f.readTracesInto(selection, 2 .. 5, narrow, failed) == 2
  doAssert failed == @[0, 2]
  var window = newTensor[float32](4, 4)
  doAssert f.readTracesInto(2 .. 5, 2 .. 5, window, failed) == 2 and failed == @[1, 2]
  doAssertRaises ValueError:
    discard f.readTracesInto(0 ..< f.len + 1, dst, failed)
  doAssert failed.len == 0, "a rejected read leaves no stale rows"
  doAssert f.readTracesInto(2 .. 5, 2 .. 5, window, failed) == 2
  let cap = failed.capacity
  doAssert f.readTracesInto(5 .. 8, dst, failed) == 0 and failed.len == 0
  doAssert failed.capacity == cap, "the list keeps its capacity"
  f.close()

block chunks_carry_their_window_origin:
  # A chunk records the prefetcher's `firstSample`.
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  var c: PrefetchChunk[float32]
  var p = newPrefetcher[float32](f, 0 ..< 6, chunkTraces = 3, cols = 4, firstSample = 5)
  doAssert p.next(c) and c.firstSample == 5
  doAssert c.samples[1, 0] == f.readTraces(1 .. 1, 5 .. 5)[0, 0]
  p.close()
  var q = newPrefetcher[float32](f, 0 ..< 6, chunkTraces = 3, cols = 4)
  doAssert q.next(c) and c.firstSample == 0
  q.close()
  f.close()

proc twoIntervals(path: string) =
  ## shot.sgd with its auxiliary channel sets 2 and 3 at 2 ms (the rest at
  ## 1 ms). Trace order: CS1, CS3, CS2, CS4, CS4.
  var d = readSegd(demoDir() / "shot.sgd")
  for c in d.records[0].record.scanTypes[0].descriptorsRev3.mitems:
    if c.channelSetNumber in [2'u16, 3]:
      c.samplingInterval = 2000
      c.endTime = int32(2000 * (int(c.numSamples) - 1))
  let sink = openDiskSink(path)
  try: doAssert not writeSegd(sink, d).isFatal
  finally: sink.close()

block uniform_chunks:
  let p = tmp / "two.sgd"
  twoIntervals(p)
  var f = openSeismic(p, keys = true)
  doAssert f.traceKeys(1).intervalUs == 2000 and f.traceKeys(0).intervalUs == 1000
  # Without `uniform`, one chunk mixes them.
  var mixed = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, cols = 4)
  var c: PrefetchChunk[float32]
  doAssert mixed.next(c) and c.count == 5 and mixed.atEnd
  mixed.close()
  for quick in [false, true]:
    var u = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, cols = 4, uniform = true,
      quickFirst = quick)
    var starts: seq[int]
    for c in u.chunks:
      starts.add c.first
      for row in 1 ..< c.count:
        doAssert c.rows.traceKeys(row).intervalUs == c.rows.traceKeys(0).intervalUs
        doAssert c.rows.channelSetIndex(row) == c.rows.channelSetIndex(0)
    doAssert starts == @[0, 1, 2, 3], $starts
    u.seek(2 ..< 5)
    starts.setLen 0
    for c in u.chunks: starts.add c.first
    doAssert starts == @[2, 3]
    u.close()
  # A selection: positions 0, 1 are CS4, CS4; then CS1.
  var s = newPrefetcher[float32](f, @[3, 4, 0], chunkTraces = 8, cols = 4, uniform = true)
  doAssert s.next(c) and c.count == 2 and s.next(c) and c.count == 1 and c.rows.traceOf(0) == 0
  s.close()
  f.close()
  var n = openSeismic(p)
  doAssertRaises(ValueError):
    var bad = newPrefetcher[float32](n, 0 ..< n.len, uniform = true)
    bad.close()
  n.close()

type Tally = object
  calls: Atomic[int]
  rows: Atomic[int]
  failed: Atomic[int]
  byWorker: array[4, Atomic[int]]

proc negate(worker: int, samples: ptr UncheckedArray[float32], rows, cols: int,
    traces: TraceRows, failed: openArray[int], user: pointer) {.nimcall, gcsafe, raises: [].} =
  let t = cast[ptr Tally](user)
  discard t.calls.fetchAdd(1)
  discard t.rows.fetchAdd(traces.len)
  discard t.failed.fetchAdd(failed.len)
  discard t.byWorker[worker].fetchAdd(1)
  for i in 0 ..< rows * cols: samples[i] = -samples[i]

type KeySum = object
  sum: Atomic[float64]
  rows: Atomic[int]

proc sumCmpX(worker: int, samples: ptr UncheckedArray[float32], rows, cols: int,
    traces: TraceRows, failed: openArray[int], user: pointer) {.nimcall, gcsafe, raises: [].} =
  # A transform reads keys on the worker: `keysAt` is the non-raising form.
  let t = cast[ptr KeySum](user)
  var s = 0.0
  for row in 0 ..< traces.len: s += abs(traces.keysAt(row).cmpX)
  var old = t.sum.load
  while not t.sum.compareExchange(old, old + s): discard
  discard t.rows.fetchAdd(traces.len)

block transform_runs_once_per_chunk_on_a_worker:
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  f.index.entries[50].numSamples = 1_000_000_000
  let plain = f.readTraces(0 ..< 49, 0 ..< 16)
  var tally: Tally
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16, cols = 16, workers = 4,
    transform = negate, user = addr tally)
  var chunks = 0
  for c in p.chunks:
    inc chunks
    if c.first == 0:
      for i in 0 ..< 16:
        for j in 0 ..< 16: doAssert c.samples[i, j] == -plain[i, j]
  p.close()
  doAssert tally.calls.load == chunks and chunks == 13
  doAssert tally.rows.load == f.len and tally.failed.load == 1
  var sum = 0
  for w in 0..3: sum += tally.byWorker[w].load
  doAssert sum == chunks
  f.close()

block transform_reads_keys_with_keys_at:
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  var want = 0.0
  for t in 0 ..< f.len: want += abs(f.traceKeys(t).cmpX)
  doAssert want > 0
  var acc: KeySum
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16, cols = 8, workers = 4,
    transform = sumCmpX, user = addr acc)
  for c in p.chunks: discard c.count
  p.close()
  doAssert acc.rows.load == f.len
  doAssert abs(acc.sum.load - want) <= 1e-9 * want
  f.close()

echo "tprefetchrows: ok"

# ------------------------------------------------- uniformRuns (16.6) --

block uniform_runs:
  let p = tmp / "runs.sgd"
  twoIntervals(p)
  for keys in [true, false]:
    var f = openSeismic(p, keys = keys)
    var runs: seq[Slice[int]]
    for r in f.uniformRuns(0 ..< f.len): runs.add r
    doAssert runs == @[0..0, 1..1, 2..2, 3..4], $runs
    runs.setLen 0
    for r in f.uniformRuns(2 ..< 5): runs.add r
    doAssert runs == @[2..2, 3..4]
    runs.setLen 0
    for r in f.uniformRuns(5 ..< 5): runs.add r
    doAssert runs.len == 0
    runs.setLen 0
    for r in f.uniformRuns([3, 4, 0, 3]): runs.add r
    doAssert runs == @[0..1, 2..2, 3..3], $runs
    doAssertRaises(ValueError):
      for r in f.uniformRuns(0 .. 5): discard
    f.close()
  var y = openSeismic(demoDir() / "survey.sgy")
  var one: seq[Slice[int]]
  for r in y.uniformRuns(0 ..< y.len): one.add r
  doAssert one == @[0..199]
  y.close()

echo "uniform runs: ok"

# Review: a file closed, then destroyed, while its prefetcher still runs.
proc startOnTemporary(): Prefetcher[float32] =
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  result = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16, cols = 8, workers = 2)
  f.close() # then destroyed on return

block close_then_destroy_while_prefetching:
  var p = startOnTemporary()
  var n = 0
  for c in p.chunks:
    doAssert c.rows.traceKeys(c.count - 1).inline == 1001
    n += c.count
  doAssert n == 200
  p.close()

echo "close then destroy: ok"

# Views and prefetchers take their pointers to the keys when they are made:
# those made before `ensureKeys` stay without keys (and keep working), those
# made after it have them.
block made_before_ensure_keys_stays_without_keys:
  var f = openSeismic(demoDir() / "survey.sgy")
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16, cols = 8)
  let view = f.rowsOf(0 ..< f.len)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and not c.rows.hasKeys
  f.ensureKeys() # the prefetcher of this thread keeps running
  doAssert f.hasKeys and f.keysRevision == 1 and not view.hasKeys
  doAssertRaises(ValueError): discard view.traceKeys(0)
  p.seek(0 ..< f.len)
  doAssert p.next(c) and c.count == 16 and not c.rows.hasKeys
  p.close()
  var q = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16, cols = 8)
  doAssert q.next(c) and c.rows.hasKeys
  doAssert sameKeys(c.rows.traceKeys(3), f.traceKeys(3))
  doAssert sameKeys(f.rowsOf(0 ..< f.len).traceKeys(3), f.traceKeys(3))
  q.close()
  f.close()

# A prefetcher made before `openEditor(f)`: the keys its chunks' rows and its
# transform read are parked with the old map, as the entries and codecs are
# (they were freed with the file; `nim asan` runs this file under ASan).
proc stampCmpX(worker: int, samples: ptr UncheckedArray[float32], rows, cols: int,
    traces: TraceRows, failed: openArray[int], user: pointer) {.nimcall, gcsafe, raises: [].} =
  # Column 0 of each row gets the midpoint the worker read for it.
  for row in 0 ..< rows: samples[row * cols] = float32(traces.keysAt(row).cmpX)

proc startThenEdit(path: string, expect: var seq[TraceKeys]): Prefetcher[float32] =
  var f = openSeismic(path, keys = true)
  expect = f.traceKeys(0 ..< f.len)
  result = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16, depth = 2, cols = 8,
    transform = stampCmpX)
  var c: PrefetchChunk[float32]
  doAssert result.next(c)
  var ed = openEditor(move f, journalPath = path & ".journal.nif")
  var g = release(ed) # the viewer goes on reading
  doAssert g.hasKeys
  # `g` is destroyed here; the prefetcher lives on.

block keys_outlive_a_file_handed_to_an_editor:
  let path = tmp / "edited.sgy"
  copyFile(demoDir() / "survey.sgy", path)
  var expect: seq[TraceKeys]
  var p = startThenEdit(path, expect)
  # Without ASan: whatever now takes the freed keys' place is not the keys.
  var filler = newSeq[TraceKeys](expect.len)
  doAssert filler[0].record == 0
  p.seek(0 ..< p.len)
  var c: PrefetchChunk[float32]
  var n = 0
  while p.next(c):
    for row in 0 ..< c.count:
      let k = expect[c.first + row]
      doAssert sameKeys(c.rows.traceKeys(row), k), $(c.first + row)
      doAssert k.cmpX != 0 and c.samples[row, 0] == float32(k.cmpX), $(c.first + row)
    n += c.count
  p.close()
  doAssert n == expect.len

echo "editor hand-over: ok"
