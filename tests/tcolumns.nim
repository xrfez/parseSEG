## Bulk keys and header columns (task 14.3a): `traceFieldColumn` against
## `traceField`, and on-demand `traceKeysInto` against the keys of an
## `openSeismic(keys = true)` walk, on every sample file and on files
## converted from them (SEG-Y Rev 2.1 with Ext1 and proprietary headers,
## little-endian SEG-Y, SEG-D Rev 2.1 and 3.0, SEG-2).

import std/[assertions, os, math, options, strutils, sequtils, typedthreads]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tcolumns")

proc sameFloat(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)

proc sameKeys(a, b: TraceKeys): bool =
  result = true
  for x, y in fields(a, b):
    when x is float64:
      if not sameFloat(x, y): return false
    else:
      if x != y: return false

proc convert(src, name: string, o: ConvertOptions): string =
  result = tmp / name
  let log = convertFile(src, result, o)
  doAssert not log.isFatal, name & ": " & $log

proc fixtures(): seq[string] =
  for n in inputFiles(): result.add n
  let inova = sampleOr("inova_rev30_5traces.sgd")
  let d63 = sampleOr("63.sgd")
  let bo = sampleOr("BO_3D-Inglewood_rev21_v7.sgy")
  result.add convert(inova, "inova.sgy", ConvertOptions()) # Ext1, PSEGD001, Layout stanza
  result.add convert(d63, "d63le.sgy", ConvertOptions(byteOrder: boLittle))
  result.add convert(bo, "bo_rev1.sgy", ConvertOptions(revision: SegyRevision(major: 1)))
  var r3 = ConvertOptions(target: skSegd)
  r3.segd.revision = SegdRevision(major: 3, minor: 0)
  result.add convert(d63, "d63_rev3.sgd", r3)
  var r2 = ConvertOptions(target: skSegd)
  r2.segd.revision = SegdRevision(major: 2, minor: 1)
  result.add convert(inova, "inova_rev21.sgd", r2)
  for (src, name) in [(bo, "bo.sg2"), (d63, "d63.sg2"), (inova, "inova.sg2")]:
    result.add convert(src, name, ConvertOptions(target: skSeg2))

let files = fixtures()

proc traceKinds(f: SeismicFile): seq[(string, HeaderBlock)] =
  # Every trace block kind met in the file, with its name.
  for i in 0 ..< f.len:
    for b in ["trace", "ext1"]:
      let k = f.blockKind(hsTrace, i, b)
      if k.isSome and (b, k.get) notin result: result.add (b, k.get)

block keys_on_demand_match_the_index_walk:
  for p in files:
    var a = openSeismic(p, keys = true)
    var b = openSeismic(p)
    doAssert a.hasKeys and not b.hasKeys
    let n = a.len
    let all = b.traceKeys(0 ..< n)
    doAssert all.len == n
    for i in 0 ..< n:
      doAssert sameKeys(all[i], a.traceKeys(i)), p & " trace " & $i & "\n" & $all[i] & "\n" &
        $a.traceKeys(i)
    # list order, repeats and the copy path of a keyed file
    var sel: seq[int]
    for i in countdown(n - 1, 0, max(1, n div 7)): sel.add i
    sel.add 0
    var dst = newSeq[TraceKeys](sel.len)
    b.traceKeysInto(sel, dst)
    let copied = a.traceKeys(sel)
    for k, i in sel:
      doAssert sameKeys(dst[k], a.traceKeys(i)) and sameKeys(copied[k], dst[k])
    doAssert b.traceKeys(n ..< n).len == 0
    a.close()
    b.close()

block columns_match_trace_field:
  for p in files:
    var f = openSeismic(p)
    let n = min(f.len, 300)
    var checked = 0
    for (b, kind) in f.traceKinds:
      for field in fieldNames(kind):
        let name = b & "." & field
        let v0 = f.findTraceField(0, name)
        if v0.isSome and v0.get.kind == fvText:
          doAssertRaises(ValueError): discard f.traceFieldColumn(name, 0 ..< n)
        else:
          let col = f.traceFieldColumn(name, 0 ..< n)
          for i in 0 ..< n:
            let v = f.findTraceField(i, name)
            let want = if v.isSome: v.get.toFloat else: NaN
            doAssert sameFloat(col[i], want), p & " " & name & " trace " & $i & ": " &
              $col[i] & " != " & $want
          inc checked
    doAssert checked >= 5, p
    # the list form, into a reused buffer
    let name = if f.kind == skSegd: "trace.traceNumber" else: "trace.numSamples"
    var buf = newSeq[float64](3)
    f.traceFieldColumnInto(name, [n - 1, 0, n - 1], buf)
    let want = f.traceField(n - 1, name).toFloat
    doAssert buf[0] == want and buf[2] == want
    doAssert buf[1] == f.traceField(0, name).toFloat
    f.close()

block seg2_keyword_columns:
  var f = openSeismic(tmp / "bo.sg2")
  let col = f.traceFieldColumn("trace.CHANNEL_NUMBER", 0 ..< f.len)
  for i in 0 ..< f.len:
    doAssert col[i] == parseFloat(f.traceField(i, "trace.CHANNEL_NUMBER").text.strip)
  # text values and missing keywords are NaN
  doAssert f.traceFieldColumn("trace.RECEIVER", [0])[0].isNaN
  doAssert f.traceFieldColumn("trace.NO_SUCH_KEYWORD", [0, 1]).allIt(it.isNaN)
  f.close()

block missing_blocks_are_nan:
  # BO_3D-Inglewood has no Trace Header Extension 1
  var f = openSeismic(sampleOr("BO_3D-Inglewood_rev21_v7.sgy"))
  doAssert f.traceEntry(0).headerBytes == 240
  doAssert f.traceFieldColumn("ext1.extFieldRecord", [0, 5]).allIt(it.isNaN)
  f.close()
  var g = openSeismic(tmp / "inova.sgy")
  doAssert not g.traceFieldColumn("ext1.nanoseconds", [0])[0].isNaN
  g.close()

block errors:
  var f = openSeismic(sampleOr("inova_rev30_5traces.sgd"))
  doAssertRaises(ValueError): discard f.traceFieldColumn("trace.noSuchField", [0])
  doAssertRaises(ValueError): discard f.traceFieldColumn("ext1.noSuchField", [0])
  doAssertRaises(ValueError): discard f.traceFieldColumn("gh1.formatCode", [0])
  doAssertRaises(ValueError): discard f.traceFieldColumn("traceNumber", [0])
  doAssertRaises(ValueError): discard f.traceFieldColumn("trace.raw", [0])
  doAssertRaises(ValueError): discard f.traceFieldColumn("trace.traceNumber", [0, 5])
  doAssertRaises(ValueError): discard f.traceFieldColumn("trace.traceNumber", [-1])
  doAssertRaises(ValueError): discard f.traceFieldColumn("trace.traceNumber", 0..5)
  var short = newSeq[float64](1)
  doAssertRaises(ValueError): f.traceFieldColumnInto("trace.traceNumber", [0, 1], short)
  doAssertRaises(ValueError): discard f.traceKeys([5])
  doAssertRaises(ValueError): discard f.traceKeys(3..5)
  var k1 = newSeq[TraceKeys](1)
  doAssertRaises(ValueError): f.traceKeysInto([0, 1], k1)
  doAssert f.traceFieldColumn("trace.traceNumber", 5 ..< 5).len == 0
  f.close()
  doAssertRaises(ValueError): discard f.traceFieldColumn("trace.traceNumber", [0])
  doAssertRaises(ValueError): discard f.traceKeys([0])
  var y = openSeismic(sampleOr("BO_3D-Inglewood_rev21_v7.sgy"))
  doAssertRaises(ValueError): discard y.traceFieldColumn("ext1.headerName", [0]) # text
  doAssertRaises(ValueError): discard y.traceFieldColumn("binary.formatCode", [0])
  y.close()

block shared_reads_from_threads:
  # Several threads on one open file (see tsharedreads): no ref is copied.
  var f = openSeismic(sampleOr("BO_3D-Inglewood_rev21_v7.sgy"))
  let want = f.traceFieldColumn("trace.sourceX", 0 ..< f.len)
  let wantKeys = f.traceKeys(0 ..< f.len)
  proc work(p: ptr SeismicFile) {.thread.} =
    var col = newSeq[float64](10)
    var ks = newSeq[TraceKeys](10)
    for i in 0 ..< 3000:
      let a = i mod 190
      p[].traceFieldColumnInto("trace.sourceX", a ..< a + 10, col)
      p[].traceKeysInto(a ..< a + 10, ks)
  var th: array[6, Thread[ptr SeismicFile]]
  for i in 0 ..< th.len: createThread(th[i], work, addr f)
  joinThreads(th)
  doAssert f.traceFieldColumn("trace.sourceX", 0 ..< f.len) == want
  let again = f.traceKeys(0 ..< f.len)
  for i in 0 ..< f.len: doAssert sameKeys(again[i], wantKeys[i])
  f.close()

echo "tcolumns: ok"
