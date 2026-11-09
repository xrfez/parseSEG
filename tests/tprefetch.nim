## Read-ahead on worker threads (task 6.3; workers, ring cap, quickFirst 15.3-11).

import std/[assertions, os, random, strutils]
import parseSEG/model/[traceindex, prefetch]
import ./utils/testutils

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

proc mapped(path: string): bool =
  ## The file is mapped into this process (Linux; true elsewhere).
  when defined(linux): expandFilename(path) in readFile("/proc/self/maps")
  else: true

block close_while_prefetching:
  # R2-5: the prefetcher pins the map; the unmap waits for its close.
  let path = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  var f = openSeismic(path)
  let all = f.readTraces(0..<f.len)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 7, depth = 2)
  f.close()
  doAssert not f.isOpen
  doAssertRaises(ValueError): discard f.readTraces(0..0)
  var c: PrefetchChunk[float32]
  var n = 0
  while p.next(c):
    doAssert c.failed == 0 and c.samples == all.rows(c.first, c.count)
    n += c.count
  doAssert n == all.shape[0]
  p.seek(10 ..< 20) # still reads after a seek
  doAssert p.next(c) and c.samples == all.rows(10, c.count)
  doAssert mapped(path)
  p.close()
  doAssert not mapped(path)
  f.close() # idempotent

block file_destroyed_before_its_prefetcher:
  # The file's entries and codecs are parked with the map, not freed.
  let path = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  var p: Prefetcher[float32]
  var all: Tensor[float32]
  block:
    var f = openSeismic(path)
    all = f.readTraces(0..<f.len)
    p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 5, depth = 3)
  var c: PrefetchChunk[float32]
  var n = 0
  while p.next(c):
    doAssert c.failed == 0 and c.samples == all.rows(c.first, c.count)
    n += c.count
  doAssert n == all.shape[0]
  p.seek(0 ..< p.len)
  doAssert p.next(c) and c.samples == all.rows(0, c.count)
  p.close()
  doAssert not mapped(path)

block two_prefetchers_one_map:
  let path = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  var f = openSeismic(path)
  var a = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 50)
  var b = newPrefetcher[float32](f, @[3, 1, 4, 1, 5])
  f.close()
  a.close()
  doAssert mapped(path) # `b` still holds it
  var c: PrefetchChunk[float32]
  doAssert b.next(c) and c.count == 5
  b.close()
  doAssert not mapped(path)

block chunks_iterator:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64)
  var n = 0
  for c in p.chunks:
    doAssert c.first == n and c.samples == all.rows(c.first, c.count)
    n += c.count
  doAssert n == f.len and p.atEnd
  p.close()
  f.close()

proc buf(t: Tensor[float32]): uint = cast[uint](t.unsafe_raw_offset())

block next_into_matches_and_reuses_buffers:
  # R3-9: `nextInto` swaps the caller's previous buffer into the slot, so the
  # chunks cycle through `depth + 1` buffers and nothing else is allocated.
  for n in files:
    if fileExists(exampleDir / n):
      var f = openSeismic(exampleDir / n)
      let all = f.readTraces(0..<f.len)
      for (chunk, depth) in [(1, 1), (3, 2), (7, 3), (100_000, 4)]:
        var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = chunk, depth = depth)
        var c: PrefetchChunk[float32]
        var bufs: seq[uint]
        for round in 0..<3: # seeks keep the buffers
          p.seek(0 ..< p.len)
          var expect = 0
          while p.nextInto(c):
            doAssert c.first == expect and c.failed == 0
            doAssert c.samples == all.rows(c.first, c.count), n
            if c.count == chunk and buf(c.samples) notin bufs: bufs.add buf(c.samples)
            expect += c.count
          doAssert expect == f.len and p.atEnd and not p.nextInto(c)
        doAssert bufs.len <= depth + 1, n & ": " & $bufs.len
        p.close()
      f.close()

block next_into_random_seeks_selections_and_partial_chunks:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var sel: seq[int]
  for i in countdown(199, 0, 2): sel.add i
  var rng = initRand(7)
  for useSel in [false, true]:
    let depth = 3
    var p = if useSel: newPrefetcher[float32](f, sel, chunkTraces = 9, depth = depth)
      else: newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 9, depth = depth)
    let want = if useSel: f.readTraces(sel) else: all
    var c: PrefetchChunk[float32]
    var bufs: seq[uint]
    var expect = 0
    for step in 0..<3000:
      case rng.rand(9)
      of 0:
        let a = rng.rand(p.len)
        let b = if rng.rand(1) == 0: p.len else: a + rng.rand(p.len - a)
        expect = a
        p.seek(a ..< b) # often short: partial chunks
      of 1..4:
        if p.tryNextInto(c):
          doAssert c.first == expect and c.samples == want.rows(c.first, c.count)
          expect += c.count
      else:
        if p.nextInto(c):
          doAssert c.first == expect and c.samples == want.rows(c.first, c.count)
          expect += c.count
      if c.count == 9 and buf(c.samples) notin bufs: bufs.add buf(c.samples)
    doAssert bufs.len <= depth + 1, $bufs.len
    p.close()
  f.close()

block next_into_never_overwrites_shared_buffers:
  # A copy or a view the caller kept shares the storage: not reused.
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, depth = 2)
  var kept: seq[PrefetchChunk[float32]]
  var views: seq[(int, Tensor[float32])]
  var c: PrefetchChunk[float32]
  while p.nextInto(c):
    if c.first mod 16 == 0: kept.add c
    else: views.add (c.first, c.samples[1..2, _])
  p.close()
  for k in kept: doAssert k.samples == all.rows(k.first, k.count)
  for (first, v) in views: doAssert v == all.rows(first + 1, 2)
  f.close()

block recycle_feeds_next:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  let cols = all.shape[1]
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 10, depth = 2)
  # Recycled before the first take: dropped (wrong shape, shared, a view) or
  # kept (own, unshared) for a later chunk.
  var shared = newTensor[float32](10, cols)
  shared.apply_inline(7'f32)
  let alias = shared
  p.recycle(move shared)
  var big = newTensor[float32](20, cols)
  p.recycle(big[0..<10, _])
  p.recycle(newTensor[float32](10, cols + 1))
  var own = newTensorUninit[float32](10, cols)
  let ownBuf = buf(own)
  p.recycle(move own)
  var c: PrefetchChunk[float32]
  var bufs: seq[uint]
  var expect = 0
  for round in 0..<3:
    p.seek(0 ..< p.len)
    expect = 0
    while p.next(c):
      doAssert c.first == expect and c.samples == all.rows(c.first, c.count)
      if buf(c.samples) notin bufs: bufs.add buf(c.samples)
      expect += c.count
      p.recycle(move c)
  doAssert ownBuf in bufs and bufs.len <= 2 + 1 + 1, $bufs.len # depth + 1 + `own`
  for x in alias: doAssert x == 7 # never decoded into
  for x in big: doAssert x == 0
  p.close()
  p.recycle(newTensor[float32](10, cols)) # after close: dropped
  f.close()

block next_into_zero_columns:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var p = newPrefetcher[float32](f, 0 ..< 25, chunkTraces = 10, cols = 0)
  var c: PrefetchChunk[float32]
  var n = 0
  while p.nextInto(c):
    doAssert c.samples.shape == [c.count, 0]
    n += c.count
  doAssert n == 25
  p.close()
  f.close()

proc allocs(): int =
  ## Allocations so far (`tprefetch.nims` turns the counter on).
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

block steady_next_into_allocates_nothing:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  for into in [false, true]:
    var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 10, depth = 3)
    var c: PrefetchChunk[float32]
    doAssert p.nextInto(c) and p.nextInto(c) # warm up
    var a = 0
    var chunks = 0
    for round in 0..<20:
      let a0 = allocs()
      p.seek(0 ..< p.len) # 20 full chunks a round
      while (if into: p.nextInto(c) else: p.next(c)):
        inc chunks
      a += allocs() - a0
      doAssert c.samples == all.rows(c.first, c.count)
    when defined(nimAllocStats):
      if into: doAssert a == 0, $a
      else: doAssert a >= chunks, $a # a fresh slot buffer per chunk
    p.close()
  f.close()

# ------------------------------------- workers, ring cap, quickFirst (15.3-11) --

proc drain(p: var Prefetcher[float32]): seq[PrefetchChunk[float32]] =
  var c: PrefetchChunk[float32]
  while p.next(c): result.add c

proc sameChunks(a, b: seq[PrefetchChunk[float32]], what: string) =
  doAssert a.len == b.len, what
  for i in 0..<a.len:
    doAssert a[i].first == b[i].first and a[i].count == b[i].count, what
    doAssert a[i].samples == b[i].samples and a[i].failed == b[i].failed, what
    doAssert $a[i].log == $b[i].log, what

block workers_match_one_worker:
  # In order and identical, whatever the worker count, ranges and lists.
  for n in files:
    if fileExists(exampleDir / n):
      var f = openSeismic(exampleDir / n)
      var sel: seq[int]
      for i in countdown(f.len - 1, 0, 3): sel.add i
      # The large local file: chunks of 64 only (one per trace is slow).
      let shapes = if f.len > 1000: @[(64, 2)] else: @[(1, 1), (7, 3), (16, 8), (64, 2)]
      for (chunk, depth) in shapes:
        var one = newPrefetcher[float32](f, 0 ..< f.len, chunk, depth)
        let a = one.drain
        one.close()
        var oneSel = newPrefetcher[float32](f, sel, chunk, depth)
        let aSel = oneSel.drain
        oneSel.close()
        for w in [2, 3, 8]:
          let what = n & " " & $chunk & "x" & $depth & " workers " & $w
          var many = newPrefetcher[float32](f, 0 ..< f.len, chunk, depth, workers = w)
          sameChunks(a, many.drain, what)
          many.close()
          var manySel = newPrefetcher[float32](f, sel, chunk, depth, workers = w)
          sameChunks(aSel, manySel.drain, what & " list")
          manySel.close()
      f.close()

block workers_with_failed_rows:
  # Undecodable rows are zero and logged alike on every worker.
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  for t in [3, 50, 51, 199]: f.index.entries[t].numSamples = 1_000_000_000
  var one = newPrefetcher[float32](f, 0 ..< f.len, 7, 3, cols = 16)
  let a = one.drain
  one.close()
  var failed = 0
  for c in a: failed += c.failed
  doAssert failed == 4
  var many = newPrefetcher[float32](f, 0 ..< f.len, 7, 3, cols = 16, workers = 4)
  sameChunks(a, many.drain, "failed rows")
  many.close()
  f.close()

block random_seeks_with_workers_and_quick_first:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  var rng = initRand(7)
  for quick in [false, true]:
    var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 9, depth = 5, workers = 4,
      quickFirst = quick)
    var c: PrefetchChunk[float32]
    var expect = 0
    for step in 0..<3000:
      case rng.rand(9)
      of 0:
        expect = rng.rand(f.len)
        p.seek(expect ..< p.len)
      of 1..4:
        if p.tryNextInto(c):
          doAssert c.first == expect and c.samples == all.rows(c.first, c.count)
          expect += c.count
      else:
        if p.nextInto(c):
          doAssert c.first == expect and c.samples == all.rows(c.first, c.count)
          expect += c.count
        else:
          doAssert expect == f.len
    p.close()
  f.close()

block ring_cap:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  let chunkBytes = 64 * f.maxSamples * sizeof(float32) # 512 KB
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, depth = 16)
  doAssert p.depth == DefaultRingBytes div chunkBytes and p.depth in 2..15, $p.depth
  for c in p.chunks: doAssert c.samples == all.rows(c.first, c.count)
  p.close()
  doAssert p.depth == 0
  # At least a slot per worker and one ready; never more than `depth`.
  var q = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, depth = 16, workers = 3,
    maxRingBytes = 1)
  doAssert q.depth == 4
  doAssert q.drain.len == 4
  q.close()
  var r = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, depth = 16,
    maxRingBytes = 64 shl 20)
  doAssert r.depth == 16
  r.close()
  var s = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 2, depth = 5)
  doAssert s.depth == 5
  s.close()
  var z = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, depth = 16, cols = 0)
  doAssert z.depth == 16 # empty rows: nothing to cap
  z.close()
  f.close()

block quick_first_after_seek:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let all = f.readTraces(0..<f.len)
  proc spans(p: var Prefetcher[float32]): seq[(int, int)] =
    var c: PrefetchChunk[float32]
    while p.nextInto(c):
      doAssert c.samples == all.rows(c.first, c.count)
      result.add (c.first, c.count)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 40, depth = 3, quickFirst = true)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and (c.first, c.count) == (0, 10) # the start is a range too
  doAssert p.next(c) and (c.first, c.count) == (10, 40)
  p.seek(105 ..< p.len)
  doAssert p.spans == @[(105, 10), (115, 40), (155, 40), (195, 5)]
  p.seek(195 ..< p.len)
  doAssert p.spans == @[(195, 5)]
  p.seek(10 ..< 50)
  doAssert p.spans == @[(10, 10), (20, 30)]
  p.seek(20 ..< 20)
  doAssert p.atEnd and p.spans.len == 0
  p.close()
  # Off by default: full chunks from the seek.
  var q = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 40, depth = 3)
  q.seek(105 ..< q.len)
  doAssert q.spans == @[(105, 40), (145, 40), (185, 15)]
  q.close()
  # Lists, chunks of 1-3 traces (a first chunk of 1), and several workers.
  var sel = @[5, 3, 9, 1, 0, 7]
  for chunk in 1..3:
    var s = newPrefetcher[float32](f, sel, chunkTraces = chunk, depth = 2, quickFirst = true,
      workers = 2)
    doAssert s.next(c) and (c.first, c.count) == (0, 1)
    doAssert c.samples == all.rows(5, 1)
    s.seek(2 ..< 6)
    doAssert s.next(c) and (c.first, c.count) == (2, 1)
    doAssert c.samples == all.rows(9, 1)
    s.close()
  f.close()

# Phase 6 and Phase 8 reviews.

block p6_b6_prefetch_of_zero_width_chunks:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  for i in 0..<10: f.index.entries[i].numSamples = 0
  var p = newPrefetcher[float32](f, 0 ..< 10, chunkTraces = 7, depth = 2)
  var c: PrefetchChunk[float32]
  var n = 0
  while p.next(c):
    doAssert c.samples.shape == [c.count, 0]
    n += c.count
  doAssert n == 10
  p.close()
  f.close()

block p6_b7_prefetch_after_close:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 100_000) # slots capped at the file's 200
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.count == 200
  p.close()
  doAssert p.atEnd and not p.tryNext(c) and not p.next(c)
  p.seek(0 ..< p.len)
  var q: Prefetcher[float32] # never started
  doAssert q.atEnd and not q.tryNext(c)
  f.close()

block p8_b4_selection_prefetchers_do_not_leak:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let before = getOccupiedMem()
  for _ in 0..<20:
    var p = newPrefetcher[float32](f, newSeq[int](1_000_000), chunkTraces = 4, depth = 1, cols = 4)
    p.close()
  for _ in 0..<5:
    block:
      var q = newPrefetcher[float32](f, newSeq[int](1_000_000), chunkTraces = 4, depth = 1,
        cols = 4)
      discard q.len # destroyed without close
  doAssert getOccupiedMem() - before < 16 shl 20, $(getOccupiedMem() - before)
  f.close()
