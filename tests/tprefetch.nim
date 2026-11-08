## Read-ahead on a worker thread (task 6.3).

import std/[assertions, os, random]
import parseSEG/model/[traceindex, prefetch]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
const files = ["BO_3D-Inglewood_rev21_v7.sgy", "inova_rev30_5traces.sgd", "63.sgd",
  "00000151_12900_11300.sgd"] # the last is local only

proc rows(t: Tensor[float32], first, count: int): Tensor[float32] =
  t[first ..< first + count, _]

block sequential_reads_match_range_reads:
  for n in files:
    if fileExists(exampleDir / n):
      var f = openSeismic(exampleDir / n)
      let all = f.readTraces(0..<f.len)
      for (chunk, depth) in [(1, 1), (7, 3), (64, 2), (100_000, 4)]:
        var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = chunk, depth = depth)
        var c: PrefetchChunk[float32]
        var expect = 0
        while p.next(c):
          doAssert c.first == expect and c.failed == 0
          doAssert c.samples == all.rows(c.first, c.count), n
          expect += c.count
        doAssert expect == f.len and p.atEnd
        doAssert not p.next(c) # stays at the end
        p.close()
      f.close()

block polling_never_blocks:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 10, depth = 3)
  var c: PrefetchChunk[float32]
  var got, polls = 0
  while not p.atEnd:
    inc polls
    if p.tryNext(c):
      doAssert c.first == got and c.samples == all.rows(c.first, c.count)
      got += c.count
  doAssert got == f.len and not p.tryNext(c)
  p.close()
  f.close()

block taken_chunks_are_never_overwritten:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, depth = 2)
  var kept: seq[PrefetchChunk[float32]]
  var c: PrefetchChunk[float32]
  while p.next(c): kept.add c
  p.close()
  for k in kept: doAssert k.samples == all.rows(k.first, k.count)
  f.close()

block subrange_seek_and_float64:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len, float64)
  var p = newPrefetcher[float64](f, 20 ..< 45, chunkTraces = 10, depth = 2,
    cols = 50)
  var c: PrefetchChunk[float64]
  doAssert p.next(c) and c.first == 20 and c.count == 10 and c.samples.shape[1] == 50
  doAssert c.samples == all[20..29, 0..<50]
  p.seek(150 ..< p.len) # to the end of the file
  doAssert p.next(c) and c.first == 150
  doAssert c.samples == all[150..159, 0..<50]
  p.seek(195 ..< 197)
  doAssert not p.atEnd # atEnd follows seeks and takes without the lock
  doAssert p.next(c) and c.first == 195 and c.count == 2 and p.atEnd and not p.next(c)
  p.seek(200 ..< p.len) # an empty range
  doAssert p.atEnd and not p.next(c)
  p.seek(0 ..< 3)
  doAssert not p.atEnd
  doAssert p.next(c) and c.count == 3 and p.atEnd
  p.close()
  doAssert p.atEnd
  p.close() # idempotent
  f.close()

block undecodable_traces_are_counted:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  f.index.entries[3].numSamples = 1_000_000_000 # points past the end of the file
  var p = newPrefetcher[float32](f, 0 ..< 5, chunkTraces = 5, cols = 10)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.failed == 1
  for j in 0..<10: doAssert c.samples[3, j] == 0
  p.close()
  f.close()

block destroyed_without_close:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  for _ in 0..<20:
    var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 3, depth = 4)
    var c: PrefetchChunk[float32]
    discard p.tryNext(c) # leaves the worker busy; `=destroy` must join it
  f.close()

block random_seeks_and_polls:
  # Races between seeks and the worker would show as wrong data.
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var rng = initRand(42)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 9, depth = 3)
  var c: PrefetchChunk[float32]
  var start = 0
  var expect = 0
  for step in 0..<3000:
    case rng.rand(9)
    of 0:
      start = rng.rand(f.len)
      expect = start
      p.seek(start ..< p.len)
    of 1..4:
      if p.tryNext(c):
        doAssert c.first == expect and c.samples == all.rows(c.first, c.count)
        expect += c.count
    else:
      if p.next(c):
        doAssert c.first == expect and c.samples == all.rows(c.first, c.count)
        expect += c.count
      else:
        doAssert expect == f.len
  p.close()
  f.close()

block selections:
  # A trace list (e.g. a sort order) is read ahead in list order.
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var sel: seq[int]
  for i in countdown(199, 0, 3): sel.add i
  sel.add [5, 5, 0]                               # repeats are fine
  let want = f.readTraces(sel)
  doAssert want.shape[0] == sel.len
  let all = f.readTraces(0..<f.len)
  for k, i in sel: doAssert want[k, _] == all[i, _]
  var p = newPrefetcher[float32](f, sel, chunkTraces = 7, depth = 2)
  var c: PrefetchChunk[float32]
  var pos = 0
  doAssert not p.atEnd
  while p.next(c):
    doAssert c.first == pos and c.samples == want[pos ..< pos + c.count, _]
    doAssert p.traceAt(pos) == sel[pos]
    pos += c.count
  doAssert pos == sel.len and p.atEnd
  p.seek(60 ..< p.len)
  doAssert p.next(c) and c.first == 60 and c.samples[0, _] == all[sel[60], _]
  p.close()
  # Raw decode into a caller buffer with a row stride (the C ABI path).
  var buf = newSeq[float32](3 * 2100)
  var log: DiagLog
  doAssert f.readTracesRaw([7, 3, 7], cast[ptr UncheckedArray[float32]](addr buf[0]), 2001,
    2100, log) == 0
  for j in 0..<2001:
    doAssert buf[j] == all[7, j] and buf[2100 + j] == all[3, j] and buf[4200 + j] == all[7, j]
  f.close()

block failed_rows_are_logged:
  # A trace that cannot be decoded is a zero row, counted and logged in its
  # chunk with its trace index, record and offset.
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  f.index.entries[6].numSamples = 1_000_000 # its samples now lie past the end
  var p = newPrefetcher[float32](f, @[9, 6, 2], chunkTraces = 2, depth = 2, cols = 8)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.failed == 1 and c.log.len == 1
  doAssert c.log[0].loc.trace == 6 and c.log[0].code == dcTruncated and
    c.log[0].offset == f.index.entries[6].offset and c.log[0].loc.file == f.path
  for j in 0..<8: doAssert c.samples[1, j] == 0
  doAssert p.next(c) and c.failed == 0 and c.log.len == 0
  doAssertRaises(ValueError): discard p.traceAt(3)
  p.close()
  f.close()
