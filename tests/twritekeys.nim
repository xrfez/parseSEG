## Writing SEG-Y traces built from `TraceKeys`, with no template trace
## (processSEG F3): SEG-D and SEG-2 traces, and stacked traces, round-trip
## through `openSeismic` with their keys and samples.

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_twritekeys")

proc same(a, b: float64): bool = (a.isNaN and b.isNaN) or a == b

proc sameOrZero(a, b: float64): bool = same(a, b) or (b.isNaN and a == 0)
  # Elevations, the record, the ensemble and the offset read back 0 when not written.

proc sameXY(ax, ay, kx, ky: float64): bool =
  # SEG-Y readers take a point at exactly (0, 0) as unset (NaN).
  (same(ax, kx) and same(ay, ky)) or (kx == 0 and ky == 0 and ax.isNaN and ay.isNaN)

proc checkKeys(a, k: TraceKeys, major: int) =
  # What a SEG-Y file of revision `major` holds of `k`.
  doAssert sameOrZero(a.record, k.record) and same(a.channel, k.channel)
  doAssert same(a.srcPoint, k.srcPoint)
  doAssert sameXY(a.srcX, a.srcY, k.srcX, k.srcY)
  doAssert sameXY(a.rcvX, a.rcvY, k.rcvX, k.rcvY)
  doAssert sameXY(a.cmpX, a.cmpY, k.cmpX, k.cmpY)
  doAssert sameOrZero(a.srcZ, k.srcZ) and sameOrZero(a.rcvZ, k.rcvZ)
  doAssert sameOrZero(a.ensemble, k.ensemble)
  # Before Rev 2 the offset is a whole number (Rev 2: also f64 in Ext1).
  doAssert k.offset.isNaN or a.offset == (if major >= 2: k.offset else: round(k.offset))
  doAssert a.t0Ms == k.t0Ms and a.intervalUs == k.intervalUs
  doAssert same(a.time, k.time) or abs(a.time - k.time) < 1e-6
  # Auxiliary has no general SEG-Y code; a component code reads back live.
  let comp = int(k.component) in 11..17 or int(k.component) in 27..41
  doAssert a.status == (if k.status == tsAuxiliary: tsUnknown
                        elif k.status == tsUnknown and comp: tsLive
                        else: k.status)
  if comp and k.status != tsAuxiliary: doAssert a.component == k.component
  if major >= 1:
    doAssert same(a.inline, k.inline) and same(a.crossline, k.crossline)

proc roundTrip(src: string, opts: SegyOutputOptions, dst: string) =
  var f = openSeismic(src, keys = true)
  let x = f.readTraces(0 ..< f.len)
  var w = openSeismicWriter(dst, opts)
  for t in 0 ..< f.len:
    var row = newSeq[float32](int(f.traceEntry(t).numSamples))
    for j in 0 ..< row.len: row[j] = x[t, j]
    w.writeTrace(f.traceKeys(t), row)
  discard w.close()
  var g = openSeismic(dst, keys = true)
  doAssert g.kind == skSegy and g.len == f.len
  for t in 0 ..< f.len:
    checkKeys(g.traceKeys(t), f.traceKeys(t), int(opts.revision.major))
    let n = int(f.traceEntry(t).numSamples)
    let y = g.readTraces(t..t)
    for j in 0 ..< n: doAssert y[0, j] == x[t, j]
  g.close()
  f.close()

block segd_and_seg2_to_segy:
  for name in ["record.sgd", "shot.sgd", "line.sg2"]:
    roundTrip(demoDir() / name, SegyOutputOptions(), tmp / (name & ".sgy"))
    roundTrip(demoDir() / name, SegyOutputOptions(revision: SegyRevision(major: 1),
      byteOrder: boBig), tmp / (name & ".rev1.sgy"))
    roundTrip(demoDir() / name, SegyOutputOptions(byteOrder: boLittle,
      format: st6), tmp / (name & ".le.sgy"))

block stacked_traces:
  # A stack line: CDP numbers, midpoints, inline/crossline, a fractional
  # start time and interval, the fold through an override; one dead bin.
  let dst = tmp / "stack.sgy"
  var w = openSeismicWriter(dst, SegyOutputOptions(text: @["A STACK", "LINE 7"],
    traceSorting: 4, measurementSystem: 1))
  var keys: seq[TraceKeys]
  var data: seq[seq[float32]]
  for b in 0 ..< 4:
    var k = initTraceKeys()
    k.ensemble = float64(100 + b)
    k.cmpX = 500_000.25 + 12.5 * float64(b)
    k.cmpY = 6_100_000.5
    k.inline = 7
    k.crossline = float64(1 + b)
    k.offset = 0
    k.t0Ms = -12.5
    k.intervalUs = 1500.5
    k.time = 1_700_000_000.25
    k.status = if b == 2: tsDead else: tsLive
    var s = newSeq[float32](70_000)
    for j in 0 ..< s.len: s[j] = float32(b) + float32(j mod 97) * 0.5
    w.writeTrace(k, s, overrides = [headerOverride("trace.numHorzStacked", 10 + b)])
    keys.add k
    data.add s
  doAssert w.len == 4
  discard w.close()
  var g = openSeismic(dst, keys = true)
  doAssert g.len == 4
  doAssert g.index.segy.binary.traceSorting == 4
  doAssert g.index.segy.binary.measurementSystem == 1
  doAssert g.index.segy.binary.effectiveSamplesPerTrace == 70_000
  doAssert g.index.segy.binary.effectiveSampleInterval == 1500.5
  for b in 0 ..< 4:
    checkKeys(g.traceKeys(b), keys[b], 2)
    doAssert g.traceField(b, "trace.numHorzStacked").toFloat == float64(10 + b)
    doAssert int(g.traceEntry(b).numSamples) == 70_000
    let y = g.readTraces(b..b)
    for j in 0 ..< 70_000: doAssert y[0, j] == data[b][j]
  doAssert g.index.segy.text.card(1).contains("A STACK")
  g.close()

block time_scalars:
  # t0 values the int16 delay holds only with a scalar, in Rev 1.
  let dst = tmp / "t0.sgy"
  var w = openSeismicWriter(dst, SegyOutputOptions(revision: SegyRevision(major: 1)))
  let t0s = [0.0, 4.0, -0.25, 1.125, 32767.0, 40000.0, -100_000.0]
  for t0 in t0s:
    var k = initTraceKeys()
    k.t0Ms = t0
    k.intervalUs = 2000
    w.writeTrace(k, [1'f32, 2, 3])
  discard w.close()
  var g = openSeismic(dst, keys = true)
  for i, t0 in t0s: doAssert g.traceKeys(i).t0Ms == t0
  doAssert g.traceKeys(0).status == tsUnknown
  g.close()

block refused:
  var k = initTraceKeys()
  k.intervalUs = 2000
  doAssertRaises(ValueError):
    discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 1),
      format: st6))
  doAssertRaises(ValueError):
    discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 1),
      byteOrder: boLittle))
  doAssertRaises(ValueError):
    discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 3)))
  doAssertRaises(ValueError):
    discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(byteOrder: boPairSwapped,
      format: st7))
  var w = openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 1)))
  var bad = k
  bad.intervalUs = NaN
  doAssertRaises(ValueError): w.writeTrace(bad, [1'f32])
  bad.intervalUs = 0.5
  doAssertRaises(ValueError): w.writeTrace(bad, [1'f32]) # fractional before Rev 2
  doAssertRaises(ValueError): w.writeTrace(k, newSeq[float32](70_000)) # needs Ext1
  doAssertRaises(ValueError): w.writeTrace(k, [1'f32], [headerOverride("trace.nope", 1)])
  doAssert w.len == 0
  w.writeTrace(k, [1'f32])
  discard w.close()
  doAssertRaises(ValueError): w.writeTrace(k, [1'f32])
  # Keys into a SEG-D output are refused.
  var f = openSeismic(demoDir() / "record.sgd", keys = true)
  var v = openSeismicWriter(tmp / "r.sgd", like = f)
  doAssertRaises(ValueError): v.writeTrace(k, [1'f32])
  f.close()
  # A writer dropped without close leaves no file.
  block:
    var d = openSeismicWriter(tmp / "dropped.sgy", SegyOutputOptions())
    d.writeTrace(k, [1'f32])
  doAssert not fileExists(tmp / "dropped.sgy")

block like_segy_input:
  # Keys traces into a writer `like` a SEG-Y file (no Layout stanza).
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  let dst = tmp / "like.sgy"
  var w = openSeismicWriter(dst, like = f)
  var k = initTraceKeys()
  k.ensemble = 42
  k.t0Ms = 0
  k.intervalUs = f.traceKeys(0).intervalUs
  let n = int(f.traceEntry(0).numSamples)
  w.writeTrace(k, newSeq[float32](n))
  discard w.close()
  var g = openSeismic(dst, keys = true)
  doAssert g.len == 1 and int(g.traceEntry(0).numSamples) == n
  g.close()
  f.close()
