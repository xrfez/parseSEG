## Viewer reads (task 14.3b): sample windows in `readTracesInto` /
## `readTraces` / `newPrefetcher` against the full read sliced, on every
## sample file and on conversions to every SEG-Y, SEG-D and SEG-2 sample
## format (8015 and SEG-2 format 3 pack 4 samples in 10 bytes); the SEG-Y
## textual header as text; `sortTraces` / `sortOrder` order and stability.

import std/[algorithm, assertions, math, os, sequtils, strutils]
import parseSEG
import ./utils/testutils
from parseSEG/model/traceindex import unsafeMemory, mappedSize
from parseSEG/private/pagehints import adviseWillNeed, isResident
when defined(posix): import std/posix

let tmp = scratchDir("parseseg_tviewerreads")

let
  d63 = sampleOr("63.sgd")
  inova = sampleOr("inova_rev30_5traces.sgd")
  bo = sampleOr("BO_3D-Inglewood_rev21_v7.sgy")

proc convert(src, name: string, o: ConvertOptions): string =
  result = tmp / name
  let log = convertFile(src, result, o)
  doAssert not log.isFatal, name & ": " & $log

proc fixtures(): seq[string] =
  for n in inputFiles(): result.add n
  for fmt in [st1, st2, st3, st4, st5, st6, st7, st8, st9, st10, st11, st12, st15, st16]:
    result.add convert(d63, "d63_" & $fmt & ".sgy", ConvertOptions(format: fmt))
  result.add convert(bo, "bo_le.sgy", ConvertOptions(byteOrder: boLittle, format: st2))
  result.add convert(bo, "bo_ps.sgy", ConvertOptions(byteOrder: boPairSwapped, format: st1))
  for fmt in [tf8015, tf8022, tf8024, tf8036, tf8038, tf8042, tf8044, tf8048, tf8058, tf8080,
      tf9036, tf9038, tf9058, tf9080]:
    var o = ConvertOptions(target: skSegd)
    o.segd.revision = SegdRevision(major: 3, minor: 1)
    o.segd.format = fmt
    result.add convert(inova, "inova_" & $fmt & ".sgd", o)
  var o8015 = ConvertOptions(target: skSegd)
  o8015.segd.revision = SegdRevision(major: 2, minor: 1)
  o8015.segd.format = tf8015
  result.add convert(d63, "d63_8015.sgd", o8015)
  for fmt in [s2t1, s2t2, s2t3, s2t4, s2t5]:
    var o = ConvertOptions(target: skSeg2)
    o.seg2.format = fmt
    result.add convert(bo, "bo_" & $fmt & ".sg2", o)
    result.add convert(d63, "d63_" & $fmt & ".sg2", o)

proc same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)

proc windows(maxS: int): seq[Slice[int]] =
  # Starts at every phase of a 4-sample group, single samples, the whole
  # trace, windows running past the end and windows wholly past it.
  for a in 0..9:
    for w in [1, 2, 3, 4, 5, 7, 13]: result.add a .. a + w - 1
  result.add 0 .. maxS - 1
  result.add 1 .. maxS - 1
  result.add 3 .. maxS + 6
  result.add max(maxS - 3, 0) .. maxS + 2
  result.add maxS .. maxS + 3
  result.add maxS + 10 .. maxS + 10
  result.add maxS div 2 + 1 .. maxS div 2 + 10

proc checkWindows[T: SampleType](f: SeismicFile, p: string) =
  let n = min(f.len, 64)
  var log: DiagLog
  let full = f.readTraces(0 ..< n, log, T)
  let maxS = full.shape[1]
  var sel = toSeq(countdown(n - 1, 0, max(1, n div 5)))
  sel.add 0
  for win in windows(maxS):
    var wlog: DiagLog
    let w = f.readTraces(0 ..< n, win, wlog, T)
    doAssert w.shape == [n, win.len], p
    doAssert wlog.len == log.len, p
    for r in 0 ..< n:
      for c in 0 ..< win.len:
        let s = win.a + c
        let want = if s < maxS: full[r, s] else: T(0)
        doAssert same(float64(w[r, c]), float64(want)),
          p & " " & $T & " trace " & $r & " window " & $win & " col " & $c & ": " &
          $w[r, c] & " != " & $want
    # the list form, at a row offset of a bigger tensor
    var dst = newTensor[T](sel.len + 2, win.len)
    discard f.readTracesInto(sel, win, dst, 2)
    for k, i in sel:
      for c in 0 ..< win.len:
        doAssert same(float64(dst[k + 2, c]), float64(w[i, c])), p & " list " & $win

block windows_equal_the_full_read_sliced:
  let files = fixtures()
  doAssert files.len >= 45
  var formats: seq[string]
  for p in files:
    var f = openSeismic(p)
    let s = f.summary
    formats.add $f.kind & " " & $s.formatCode
    checkWindows[float32](f, p)
    if f.kind != skSegd or p.endsWith("8080.sgd") or p.endsWith("8015.sgd"):
      checkWindows[float64](f, p)
    f.close()
  doAssert "SEG-D 8015" in formats and "SEG-2 3" in formats, $formats

block window_errors:
  var f = openSeismic(bo)
  var t = newTensor[float32](4, 10)
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, 5..4, t)
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, -1..8, t)
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, 0..10, t) # 11 columns
  doAssertRaises(ValueError): discard f.readTracesInto([0, 1, 2, 3], 0..8, t)
  doAssertRaises(ValueError): discard f.readTracesInto(0..4, 0..9, t)  # no room
  doAssertRaises(ValueError): discard f.readTracesInto([0, f.len], 0..9, t)
  doAssertRaises(ValueError): discard f.readTraces(0..3, 3..2)
  doAssert f.readTracesInto(0..3, 0..9, t) == 0
  doAssert f.readTraces(f.len ..< f.len, 0..9).shape == [0, 10]
  f.close()
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, 0..9, t)

block arguments_near_the_ends_of_int_raise_value_error:
  # Lengths and sums of the arguments are never computed before the
  # arguments are checked: no overflow, no hang.
  var f = openSeismic(bo)
  var t = newTensor[float32](4, 16)
  var failed: seq[int]
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, 0 .. high(int), t)
  doAssertRaises(ValueError): discard f.readTracesInto([0, 1, 2, 3], 0 .. high(int), t)
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, 0 .. high(int), t, failed)
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, 1 .. high(int), t)
  doAssertRaises(ValueError): discard f.readTraces(0..3, 1000 .. high(int))
  doAssertRaises(ValueError): discard f.readTraces(0..3, 0 .. high(int))
  doAssertRaises(ValueError): discard f.readTraces([0, 1], 0 .. high(int) - 1)
  doAssertRaises(ValueError): discard f.readTracesInto(low(int) + 1 .. 3, t)
  doAssertRaises(ValueError): discard f.readTracesInto(low(int) + 1 .. 3, t, failed)
  doAssertRaises(ValueError): discard f.readTracesInto(low(int) + 1 .. 3, 0..15, t)
  doAssertRaises(ValueError): discard f.readTracesInto(low(int) + 1 .. 3, 0..15, t, failed)
  doAssertRaises(ValueError): discard f.readTraces(low(int) + 1 .. 3)
  doAssertRaises(ValueError): discard f.readTraces(low(int) + 1 .. 3, 0..15)
  doAssertRaises(ValueError): discard f.readTracesInto(0..3, t, row = high(int))
  doAssertRaises(ValueError): discard f.readTracesInto([0, 1], t, row = high(int))
  doAssertRaises(ValueError): discard f.traceStatics(low(int) + 1 .. 3)
  # A window of the tensor's width that ends at `high(int)` is a window past
  # every trace's end: zero rows.
  t[0, 0] = 1
  doAssert f.readTracesInto(0..3, high(int) - 15 .. high(int), t) == 0 and t[0, 0] == 0
  var wide = newTensor[float32](64, 16) # enough traces to be advised read-ahead
  doAssert f.readTracesInto(0..63, high(int) - 15 .. high(int), wide) == 0
  # A prefetcher's window `firstSample ..< firstSample + cols` must exist.
  doAssertRaises(ValueError):
    discard newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, cols = 64,
      firstSample = high(int) - 10)
  doAssertRaises(ValueError):
    discard newPrefetcher[float32](f, 0 ..< f.len, cols = high(int)) # chunk bytes
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, cols = 10,
    firstSample = high(int) - 10)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.count == 64 and c.failed == 0 and c.samples[63, 9] == 0
  p.close()
  var q = newPrefetcher[float32](f, 0 ..< f.len, firstSample = high(int)) # cols = -1: none
  doAssert q.next(c) and c.samples.shape[1] == 0
  q.close()
  f.close()

sampleBlock damaged_trace_in_a_window:
  # The whole trace is checked, so a window of a trace past the end of the
  # file fails as the full read does.
  var f = openSeismic(exampleDir / "Sweep0.sgy")
  f.index.entries[0].numSamples = 1_000_000
  var log: DiagLog
  let w = f.readTraces(0..0, 0..1, log)
  doAssert log.len == 1 and log[0].code == dcTruncated and w[0, 0] == 0 and w[0, 1] == 0
  doAssertRaises(SegTruncatedError): discard f.readTraces([0], 0..1)
  f.close()

block prefetch_window:
  var f = openSeismic(bo)
  let want = f.readTraces(0 ..< f.len, 7..106, float64)
  var p = newPrefetcher[float64](f, 0 ..< f.len, chunkTraces = 30, depth = 2, cols = 100,
    firstSample = 7)
  var rows = 0
  for c in p.chunks:
    doAssert c.samples.shape[1] == 100
    for k in 0 ..< c.count:
      for s in 0 ..< 100: doAssert c.samples[k, s] == want[c.first + k, s]
    rows += c.count
  p.close()
  doAssert rows == f.len
  # cols = -1: up to the end of the longest trace
  var q = newPrefetcher[float32](f, @[3, 1], firstSample = f.maxSamples - 5)
  var c: PrefetchChunk[float32]
  doAssert q.next(c) and c.samples.shape == [2, 5]
  let tail = f.readTraces([3, 1], f.maxSamples - 5 .. f.maxSamples - 1)
  for k in 0..1:
    for s in 0..4: doAssert c.samples[k, s] == tail[k, s]
  q.close()
  doAssertRaises(ValueError):
    discard newPrefetcher[float32](f, 0..3, firstSample = -1)
  f.close()

sampleBlock text_header_as_text:
  var f = openSeismic(bo)
  let t = f.textHeader
  let lines = t.split('\n')
  doAssert lines.len == 40 and lines.allIt(it.len == 80)
  doAssert lines[0].startsWith("C01 AREA    : Taranaki_Basin - INGLEWOOD-3D Migration")
  doAssert lines[39].startsWith("C40 EXCEL GEOPHYSICAL SERVICES")
  doAssert t.replace("\n", "") == f.index.segy.text.text
  let ext = f.extendedTextHeaders
  doAssert ext.len == f.index.segy.extended.recordCount and ext.len > 0
  for e in ext:
    doAssert e.len == 3200 + 39
  doAssert ext.join("\n").contains("((")
  f.close()
  doAssert f.textHeader == t # from the index: no map needed
  doAssert f.extendedTextHeaders == ext
  # ASCII text, a Layout stanza in an extended record
  var g = openSeismic(convert(inova, "inova_ascii.sgy", ConvertOptions(textEncoding: teAscii)))
  doAssert g.index.segy.text.encoding == teAscii and g.textHeader.startsWith("C")
  doAssert g.extendedTextHeaders.anyIt("((SEG:Layout" in it)
  g.close()
  var s = openSeismic(exampleDir / "Sweep0.sgy")
  doAssert s.textHeader.split('\n').len == 40
  doAssert s.extendedTextHeaders.len == s.index.segy.extended.recordCount
  s.close()
  var d = openSeismic(d63)
  doAssertRaises(ValueError): discard d.textHeader
  doAssertRaises(ValueError): discard d.extendedTextHeaders
  d.close()

proc cmpNanLast(a, b: float64): int =
  if a.isNaN or b.isNaN: cmp(a.isNaN, b.isNaN) else: cmp(a, b)

proc referenceOrder(columns: openArray[seq[float64]]): seq[int] =
  # std/algorithm's `sort` is a stable merge sort.
  let cols = @columns
  result = toSeq(0 ..< cols[0].len)
  result.sort(proc (x, y: int): int =
    for c in cols:
      let r = cmpNanLast(c[x], c[y])
      if r != 0: return r
    0)

block sort_order_rules:
  let a = @[3.0, NaN, -1.0, 0.0, -0.0, Inf, -Inf, 3.0, NaN, 1e-300, -1e-300, 2.5, 0.0]
  let b = @[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 0.0, 9.0, 10.0, 11.0, 12.0, -1.0]
  doAssert sortOrder([a]) == referenceOrder([a])
  doAssert sortOrder([a]) == @[6, 2, 10, 3, 4, 12, 9, 11, 0, 7, 5, 1, 8] # stable, NaN last
  doAssert sortOrder([a, b]) == @[6, 2, 10, 12, 3, 4, 9, 11, 7, 0, 5, 1, 8]
  doAssert sortOrder([a, b]) == referenceOrder([a, b])
  doAssert sortOrder(newSeq[seq[float64]]()).len == 0
  doAssert sortOrder([newSeq[float64]()]).len == 0
  doAssertRaises(ValueError): discard sortOrder([a, b[0..3]])
  # a large random case: many ties, several keys, every digit pass
  var x = newSeq[float64](50_000)
  var y = newSeq[float64](x.len)
  var z = newSeq[float64](x.len)
  var s = 12345'u64
  proc next(s: var uint64): uint64 =
    s = s * 6364136223846793005'u64 + 1442695040888963407'u64
    s shr 11
  for i in 0 ..< x.len:
    x[i] = float64(next(s) mod 7) - 3
    y[i] = if next(s) mod 50 == 0: NaN else: (float64(next(s)) - 4e15) * 1e-7
    z[i] = cast[float64](next(s) or 1) # random bit patterns, NaNs included
  doAssert sortOrder([x, y]) == referenceOrder([x, y])
  doAssert sortOrder([z]) == referenceOrder([z])
  doAssert sortOrder([x, z]) == referenceOrder([x, z])

block sort_traces:
  var f = openSeismic(bo)
  let keys = ["trace.crosslineNumber", "trace.inlineNumber"]
  let order = f.sortTraces(keys)
  let cols = keys.mapIt(f.traceFieldColumn(it, 0 ..< f.len))
  doAssert order == referenceOrder(cols)
  doAssert order.sorted == toSeq(0 ..< f.len)
  for k in 1 ..< order.len: # ascending crossline, inline within it
    let (p, q) = (order[k - 1], order[k])
    doAssert cols[0][p] < cols[0][q] or (cols[0][p] == cols[0][q] and cols[1][p] <= cols[1][q])
  # a selection keeps its own order among ties and returns trace indices
  let sel = @[10, 3, 150, 3, 77, 0]
  let one = f.sortTraces(["trace.traceSeqFile"], sel)
  doAssert one == sel.sortedByIt(f.traceFieldColumn("trace.traceSeqFile", [it])[0])
  let byConst = f.sortTraces(["trace.numSamples"], sel) # one value: stable = unchanged
  doAssert byConst == sel
  doAssert f.sortTraces(newSeq[string](), sel) == sel
  doAssert f.sortTraces(keys, 5..9) == referenceOrder(keys.mapIt(
    f.traceFieldColumn(it, 5..9))).mapIt(it + 5)
  doAssert f.sortTraces(keys, f.len ..< f.len).len == 0
  # the sorted view decodes through the list form
  let view = f.readTraces(order[0 ..< 8])
  let direct = f.readTraces(order[3]..order[3])
  for s in 0 ..< view.shape[1]: doAssert view[3, s] == direct[0, s]
  # NaN last: ext1 is missing on a Rev 1 copy
  doAssertRaises(ValueError): discard f.sortTraces(["trace.noSuchField"])
  doAssertRaises(ValueError): discard f.sortTraces(["trace.noSuchField"], [0])
  doAssertRaises(ValueError): discard f.sortTraces(keys, [0, f.len])
  doAssertRaises(ValueError): discard f.sortTraces(keys, 0 .. f.len)
  f.close()
  # SEG-D: by receiver point, then channel (the local-only file)
  let big = exampleDir / "00000151_12900_11300.sgd"
  if fileExists(big):
    var d = openSeismic(big)
    let dk = ["ext1.receiverPointNumber", "trace.traceNumber"]
    doAssert d.sortTraces(dk) == referenceOrder(dk.mapIt(d.traceFieldColumn(it, 0 ..< d.len)))
    d.close()

block cold_reads_with_readahead_advice:
  # 15.3-4: large and scattered reads advise the kernel (madvise WILLNEED)
  # when their pages are not resident; the result must not change.
  let path = tmp / "bo_cold.sgy"
  copyFile(bo, path)
  var warmFile = openSeismic(path)
  let n = warmFile.len
  doAssert n >= 64 and getFileSize(path) > 1 shl 20 # above the advice thresholds
  let scattered = toSeq(0 ..< n).filterIt(it mod 7 == 3).reversed
  let wantAll = warmFile.readTraces(0 ..< n)
  let wantSel = warmFile.readTraces(scattered)
  let wantWin = warmFile.readTraces(scattered, 5..44)
  warmFile.close()
  proc evict(path: string) =
    when defined(posix):
      let fd = posix.open(path.cstring, O_RDONLY)
      doAssert fd >= 0
      discard posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)
      discard posix.close(fd)
  for round in 0..1:
    evict(path)
    var f = openSeismic(path)
    doAssert f.readTraces(scattered) == wantSel
    evict(path)
    doAssert f.readTraces(scattered, 5..44) == wantWin
    evict(path)
    doAssert f.readTraces(0 ..< n) == wantAll
    evict(path)
    var p = newPrefetcher[float32](f, scattered, chunkTraces = 40, depth = 2)
    for c in p.chunks:
      for k in 0 ..< c.count:
        for s in 0 ..< c.samples.shape[1]: doAssert c.samples[k, s] == wantSel[c.first + k, s]
    p.close()
    f.close()
  # The advice itself: degenerate spans and a closed map are no-ops.
  var f = openSeismic(path)
  let mem = unsafeMemory(f)
  let size = mappedSize(f)
  adviseWillNeed(mem, size, size - 10, size + 4096)
  adviseWillNeed(mem, size, -4096, 100)
  adviseWillNeed(mem, size, 50, 10)
  adviseWillNeed(nil, size, 0, size)
  doAssert isResident(mem, size, size) and isResident(nil, 0, 0)
  f.close()

echo "tviewerreads: ok"
