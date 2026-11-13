## The timing and status fields of `TraceKeys` (Phase 16.1): `t0Ms`,
## `intervalUs`, `inline`, `crossline`, `traceCode` and `status`, for SEG-Y
## Rev 0/1/2 (hand-built files), SEG-D Rev 2 and 3 (the demo records,
## rewritten with a start time and a trace edit code) and SEG-2; stored keys,
## keys on demand, `startTimeMs` and `sampleIntervalUs` agree; an index cache
## of the old format is rebuilt.

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tkeyfields")

func same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)

proc checkAgree(path: string) =
  ## Stored keys, keys on demand, `startTimeMs` and `sampleIntervalUs` agree.
  var k = openSeismic(path, keys = true)
  var n = openSeismic(path)
  let demand = n.traceKeys(0 ..< n.len)
  var t0 = newSeq[float64](n.len)
  n.startTimeMsInto(0 ..< n.len, t0)
  for i in 0 ..< k.len:
    let a = k.traceKeys(i)
    let b = demand[i]
    doAssert same(a.t0Ms, b.t0Ms) and same(a.intervalUs, b.intervalUs) and
      same(a.inline, b.inline) and same(a.crossline, b.crossline) and
      a.traceCode == b.traceCode and a.status == b.status, path & " trace " & $i
    doAssert same(t0[i], a.t0Ms) and same(n.startTimeMs(i), a.t0Ms) and
      same(k.startTimeMs(i), a.t0Ms)
    doAssert same(n.sampleIntervalUs(i), a.intervalUs), path & " trace " & $i
    doAssert k.index.isSeismic(i) == a.isSeismic
  k.close()
  n.close()

# ------------------------------------------------------------------ SEG-Y --

type SegyCase = object
  code, delay, tmScal: int16
  dt: uint16
  iline, xline: int32
  chan, espnum, sp: int32 # bytes 13-16, 17-20, 197-200
  spScal: int16           # bytes 201-202

proc put16(b: var seq[byte], at: int, v: int) =
  b[at] = byte((v shr 8) and 0xFF)
  b[at + 1] = byte(v and 0xFF)

proc put32(b: var seq[byte], at: int, v: int) =
  for k in 0..3: b[at + k] = byte((v shr (8 * (3 - k))) and 0xFF)

proc writeSegy(path: string, major: int, fixed: bool, binDt: int,
    cases: openArray[SegyCase]) =
  ## Big-endian, IEEE float (format 5), one sample per trace.
  var b = newSeq[byte](3600 + cases.len * 244)
  b[0] = 0x43 # 'C': ASCII text
  for i in 1..<3200: b[i] = 0x20
  b.put16(3216, binDt)
  b.put16(3220, 1)
  b.put16(3224, 5)
  b[3500] = byte(major)
  if fixed: b.put16(3502, 1)
  for t, c in cases:
    let at = 3600 + t * 244
    b.put32(at, t + 1)
    b.put32(at + 12, c.chan)
    b.put32(at + 16, c.espnum)
    b.put32(at + 196, c.sp)
    b.put16(at + 200, c.spScal)
    b.put16(at + 28, c.code)
    b.put16(at + 108, c.delay)
    b.put16(at + 114, 1)
    b.put16(at + 116, int(c.dt))
    b.put32(at + 188, c.iline)
    b.put32(at + 192, c.xline)
    b.put16(at + 214, c.tmScal)
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(path, s)

const segyCases = [
  SegyCase(code: 1, delay: 100, tmScal: 0, dt: 2000, iline: 5, xline: 7),
  SegyCase(code: 2, delay: 25, tmScal: 10, dt: 2000),
  SegyCase(code: 4, delay: -5, tmScal: -10, dt: 4000),
  SegyCase(code: 3, delay: 0, tmScal: 0, dt: 2000),
  SegyCase(code: 0, delay: 0, tmScal: 0, dt: 2000),
  SegyCase(code: 16384 + 12, delay: 0, tmScal: 0, dt: 2000),
  SegyCase(code: 9, delay: 0, tmScal: 0, dt: 2000),
  SegyCase(code: 300, delay: 0, tmScal: 0, dt: 2000)]

block segy_rev1_fields:
  let p = tmp / "rev1.sgy"
  writeSegy(p, 1, fixed = false, binDt = 2000, segyCases)
  var f = openSeismic(p, keys = true)
  doAssert f.len == segyCases.len
  let k = f.traceKeys(0)
  doAssert k.t0Ms == 100 and k.intervalUs == 2000 and k.inline == 5 and k.crossline == 7
  doAssert k.traceCode == 1 and k.status == tsLive
  doAssert f.traceKeys(1).t0Ms == 250 and f.traceKeys(1).status == tsDead
  doAssert f.traceKeys(2).t0Ms == -0.5 and f.traceKeys(2).status == tsAuxiliary
  doAssert f.traceKeys(2).intervalUs == 4000
  doAssert f.traceKeys(3).status == tsDead
  doAssert f.traceKeys(4).status == tsUnknown and f.traceKeys(4).inline.isNaN
  # Rev 1: 16396 is optional use (the interpolated bit is Rev 2's).
  doAssert f.traceKeys(5).status == tsUnknown and f.traceKeys(5).traceCode == 16384 + 12
  doAssert f.traceKeys(6).status == tsAuxiliary # near-field gun signature
  doAssert f.traceKeys(7).status == tsUnknown # optional use
  doAssert not f.index.isSeismic(2) and f.index.isSeismic(1) and f.index.isSeismic(4)
  f.close()
  checkAgree(p)

block segy_rev0_ignores_the_time_scalar:
  let p = tmp / "rev0.sgy"
  writeSegy(p, 0, fixed = false, binDt = 2000, segyCases)
  var f = openSeismic(p, keys = true)
  doAssert f.traceKeys(1).t0Ms == 25 and f.traceKeys(2).t0Ms == -5
  doAssert f.traceKeys(6).status == tsUnknown # Rev 0 defines codes 1-8 only
  doAssert f.traceKeys(2).status == tsAuxiliary
  doAssert f.traceKeys(0).inline.isNaN # bytes 189-196 unassigned in Rev 0
  f.close()
  checkAgree(p)

block segy_fixed_length_uses_the_binary_interval:
  let p = tmp / "rev2fixed.sgy"
  writeSegy(p, 2, fixed = true, binDt = 4000, segyCases)
  var f = openSeismic(p, keys = true)
  for i in 0 ..< f.len: doAssert f.traceKeys(i).intervalUs == 4000
  doAssert f.traceKeys(5).status == tsLive # Rev 2: interpolated multicomponent vertical
  f.close()
  checkAgree(p)

block segy_inline_crossline_from_a_layout_stanza:
  # survey.sgy keeps the inline in bytes 13 and the crossline in 17.
  let p = demoDir() / "survey.sgy"
  var f = openSeismic(p, keys = true)
  for i in [0, 1, 199]:
    let k = f.traceKeys(i)
    doAssert k.inline == 1001 and k.crossline == float64(i + 1), $k
    doAssert k.intervalUs == 2000 and k.t0Ms == 0 and k.status == tsLive
  f.close()
  checkAgree(p)

block segy_channel_follows_the_layout:
  # survey.sgy's Layout stanza keeps the inline number in bytes 13-16 (as
  # the Inglewood sample does), so those bytes are no channel number.
  for keys in [true, false]:
    var f = openSeismic(demoDir() / "survey.sgy", keys = keys)
    for k in f.traceKeys([0, 5, 199]): doAssert k.channel.isNaN and k.inline == 1001, $k.channel
    f.close()
  # A standard header: bytes 13-16.
  let p = tmp / "chan.sgy"
  writeSegy(p, 1, fixed = false, binDt = 2000, [SegyCase(code: 1, dt: 2000, chan: 7),
    SegyCase(code: 1, dt: 2000)])
  for keys in [true, false]:
    var f = openSeismic(p, keys = keys)
    let k = f.traceKeys(0 ..< f.len)
    doAssert k[0].channel == 7 and k[1].channel.isNaN # 0 is "not set"
    f.close()

block segy_source_point_keeps_its_fraction:
  # The energy source point (17-20) is an integer; the scaled shotpoint
  # (197-202) carries the fraction when it is the same point (the library's
  # converters write 100 and 9950 / -100 for point 99.5).
  let p = tmp / "sp.sgy"
  writeSegy(p, 1, fixed = false, binDt = 2000, [
    SegyCase(code: 1, dt: 2000, espnum: 100, sp: 9950, spScal: -100),
    SegyCase(code: 1, dt: 2000, espnum: 100),                    # only the energy source point
    SegyCase(code: 1, dt: 2000, espnum: 100, sp: 250, spScal: 1), # a shotpoint of its own
    SegyCase(code: 1, dt: 2000, sp: 2505, spScal: -10),          # only the shotpoint
    SegyCase(code: 1, dt: 2000, espnum: 100, sp: 100),
    SegyCase(code: 1, dt: 2000, espnum: 99, sp: 9860, spScal: -100)]) # 98.6 rounds to 99
  for keys in [true, false]:
    var f = openSeismic(p, keys = keys)
    let k = f.traceKeys(0 ..< f.len)
    doAssert k[0].srcPoint == 99.5, $k[0].srcPoint
    doAssert k[1].srcPoint == 100 and k[2].srcPoint == 100 and k[3].srcPoint == 250.5
    doAssert k[4].srcPoint == 100 and k[5].srcPoint == 98.6
    f.close()

block converted_segd_keeps_its_stations:
  # `convertFile` stores a SEG-D trace's stations in the PSEGD001 header and
  # names them in a Layout stanza (sht_line, sht_point, sht_index, rec_line,
  # rec_point, rec_index): the SEG-Y keys read them back.
  for name in ["63.sgd", "inova_rev30_5traces.sgd"]:
    let src = sampleOr(name)
    let dst = tmp / (name & ".sgy")
    doAssert not convertFile(src, dst, ConvertOptions()).isFatal
    var a = openSeismic(src, keys = true)
    for keys in [true, false]:
      var b = openSeismic(dst, keys = keys)
      doAssert a.len == b.len
      let got = b.traceKeys(0 ..< b.len)
      var sources, receivers = 0
      for i in 0 ..< a.len:
        let x = a.traceKeys(i)
        let y = got[i]
        doAssert same(x.srcLine, y.srcLine) and same(x.srcPoint, y.srcPoint) and
          x.srcIndex == y.srcIndex, name & " source of trace " & $i
        doAssert same(x.rcvLine, y.rcvLine) and same(x.rcvPoint, y.rcvPoint) and
          x.rcvIndex == y.rcvIndex, name & " receiver of trace " & $i
        if not y.srcLine.isNaN: inc sources
        if not y.rcvLine.isNaN: inc receivers
      doAssert sources > 0 and receivers > 0, name
      b.close()
    a.close()
    checkAgree(dst)

sampleBlock converted_63_has_its_fractional_source_point:
  # 63.sgd: source line 13, point 99.5; receiver line 13.
  var b = openSeismic(tmp / "63.sgd.sgy", keys = true)
  let k = b.traceKeys(0)
  doAssert k.srcLine == 13 and k.srcPoint == 99.5 and k.rcvLine == 13, $k
  b.close()
  # Without the station header the scaled shotpoint still gives the fraction.
  let plain = tmp / "63plain.sgy"
  doAssert not convertFile(exampleDir / "63.sgd", plain,
    ConvertOptions(stationHeader: false)).isFatal
  var c = openSeismic(plain, keys = true)
  doAssert c.traceKeys(0).srcPoint == 99.5 and c.traceKeys(0).srcLine.isNaN
  c.close()

# ------------------------------------------------------------------ SEG-D --

proc rewriteSegd(src, dst: string, edit: proc (d: var SegdData)) =
  var d = readSegd(src)
  edit(d)
  let sink = openDiskSink(dst)
  try: doAssert not writeSegd(sink, d).isFatal
  finally: sink.close()

block segd_rev2_start_time_and_trace_edit:
  let p = tmp / "rev2.sgd"
  rewriteSegd(demoDir() / "record.sgd", p) do (d: var SegdData):
    d.records[0].record.scanTypes[0].descriptors[0].startTime = 50 # 2 ms units
    d.records[0].traces[0].header.traceEdit = 2
  var f = openSeismic(p, keys = true)
  let k = f.traceKeys(0)
  doAssert k.t0Ms == 100 and k.intervalUs == 2000, $k
  doAssert k.status == tsDead and k.traceCode == 0 and k.inline.isNaN
  doAssert f.index.isSeismic(0) # dead, not auxiliary
  f.close()
  checkAgree(p)
  var g = openSeismic(demoDir() / "record.sgd", keys = true)
  doAssert g.traceKeys(0).status == tsLive and g.traceKeys(0).t0Ms == 0
  g.close()

block segd_rev3_auxiliary_and_start_time:
  let p = tmp / "rev3.sgd"
  rewriteSegd(demoDir() / "shot.sgd", p) do (d: var SegdData):
    for c in d.records[0].record.scanTypes[0].descriptorsRev3.mitems:
      if c.channelSetNumber == 4:
        c.startTime = 5000 # µs
        c.endTime += 5000
    d.records[0].traces[0].header.traceEdit = 2 # a zeroed auxiliary trace stays auxiliary
  var f = openSeismic(p, keys = true)
  var aux, live = 0
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    doAssert k.intervalUs == 1000
    case k.status
    of tsAuxiliary:
      inc aux
      doAssert k.t0Ms == 0 and not f.index.isSeismic(i)
    of tsLive:
      inc live
      doAssert k.t0Ms == 5, $k
    else: doAssert false, $k
  doAssert aux == 3 and live == 2
  f.close()
  checkAgree(p)

block segd_zeroed_stations_are_unknown:
  # A source or receiver station whose line and point are both 0 is a header
  # left empty, not station 0/0 (the SEG-Y keys treat zeros the same way).
  # record.sgd (Rev 2): one trace, source 20/99.5/1, receiver 10/104/1.
  proc keysOf(name: string, edit: proc (d: var SegdData)): TraceKeys =
    let p = tmp / name
    rewriteSegd(demoDir() / "record.sgd", p, edit)
    for keys in [true, false]:
      var f = openSeismic(p, keys = keys)
      result = f.traceKeys([0])[0]
      f.close()
    var f = openSeismic(p, keys = true)
    doAssert f.traceKeys(0).srcIndex == result.srcIndex and
      same(f.traceKeys(0).rcvLine, result.rcvLine) # stored keys and keys on demand agree
    f.close()
  let plain = keysOf("zero0.sgd") do (d: var SegdData): discard
  doAssert plain.srcLine == 20 and plain.srcPoint == 99.5 and plain.srcIndex == 1
  doAssert plain.rcvLine == 10 and plain.rcvPoint == 104 and plain.rcvIndex == 1
  let noSource = keysOf("zero1.sgd") do (d: var SegdData):
    d.records[0].record.sourceHeaders[0].sourceLineNumber = 0
    d.records[0].record.sourceHeaders[0].sourcePointNumber = 0
  doAssert noSource.srcLine.isNaN and noSource.srcPoint.isNaN and noSource.srcIndex == 0
  doAssert noSource.rcvLine == 10 and noSource.rcvPoint == 104 and noSource.rcvIndex == 1
  let noReceiver = keysOf("zero2.sgd") do (d: var SegdData):
    var e = d.records[0].traces[0].ext1.get
    e.receiverLineNumber = 0
    e.receiverPointNumber = 0
    d.records[0].traces[0].ext1 = some(e)
  doAssert noReceiver.rcvLine.isNaN and noReceiver.rcvPoint.isNaN and noReceiver.rcvIndex == 0
  doAssert noReceiver.srcLine == 20 and noReceiver.srcPoint == 99.5 and noReceiver.srcIndex == 1
  let pointZero = keysOf("zero3.sgd") do (d: var SegdData): # a line with point 0 is a station
    var e = d.records[0].traces[0].ext1.get
    e.receiverPointNumber = 0
    d.records[0].traces[0].ext1 = some(e)
  doAssert pointZero.rcvLine == 10 and pointZero.rcvPoint == 0 and pointZero.rcvIndex == 1
  # shot.sgd (Rev 3): source 1/1001/1 from a general header block, receivers
  # 100/201 and 100/202 on traces 3 and 4.
  let p3 = tmp / "zero4.sgd"
  rewriteSegd(demoDir() / "shot.sgd", p3) do (d: var SegdData):
    var e = d.records[0].traces[3].ext1Rev3.get
    e.receiverLineNumber = 0
    e.receiverPointNumber = 0
    d.records[0].traces[3].ext1Rev3 = some(e)
  for keys in [true, false]:
    var g = openSeismic(p3, keys = keys)
    let k = g.traceKeys(0 ..< g.len)
    doAssert k[3].rcvLine.isNaN and k[3].rcvPoint.isNaN and k[3].rcvIndex == 0, $k[3]
    doAssert k[4].rcvLine == 100 and k[4].rcvPoint == 202 and k[4].rcvIndex == 1
    doAssert k[3].srcLine == 1 and k[3].srcPoint == 1001 and k[3].srcIndex == 1
    g.close()
  # Its Source Description block with line and point zeroed (bytes 4-13).
  let p4 = tmp / "zero5.sgd"
  rewriteSegd(demoDir() / "shot.sgd", p4) do (d: var SegdData):
    var zeroed = 0
    for at, bt in blocks(d.records[0].record.generalBlocks):
      if bt in {0x15'u8..0x19'u8, 0x1F'u8}:
        for i in at + 3 ..< at + 13: d.records[0].record.generalBlocks[i] = 0
        inc zeroed
    doAssert zeroed == 1
  var h = openSeismic(p4, keys = true)
  for i in 0 ..< h.len:
    let k = h.traceKeys(i)
    doAssert k.srcLine.isNaN and k.srcPoint.isNaN and k.srcIndex == 0, $k
  doAssert h.traceKeys(4).rcvPoint == 202
  h.close()

# ------------------------------------------------------------------ SEG-2 --

block seg2_delay_interval_and_trace_type:
  let p = tmp / "types.sg2"
  var fdb = initSeg2File(boLittle)
  fdb.traceCount = 5
  var w = openSeg2Writer(p, fdb)
  let x = [1'f32, 2, 3, 4]
  for i, tt in ["SEISMIC_DATA", "DEAD", "TEST_DATA", "UPHOLE", ""]:
    var t = Seg2Trace(formatCode: 4)
    t["CHANNEL_NUMBER"] = $(i + 1)
    if i == 0: t["DELAY"] = "0.025"
    t["SAMPLE_INTERVAL"] = "0.00025"
    if tt.len > 0: t["TRACE_TYPE"] = tt
    w.writeTrace(t, x)
  w.close()
  doAssert w.log.len == 0, $w.log[0]
  var f = openSeismic(p, keys = true)
  doAssert f.traceKeys(0).t0Ms == 25 and f.traceKeys(1).t0Ms == 0
  doAssert f.traceKeys(0).intervalUs == 250
  doAssert f.traceKeys(0).status == tsLive and f.traceKeys(1).status == tsDead
  doAssert f.traceKeys(2).status == tsAuxiliary and f.traceKeys(3).status == tsAuxiliary
  doAssert f.traceKeys(4).status == tsUnknown
  doAssert f.traceKeys(0).inline.isNaN and f.traceKeys(0).traceCode == 0
  f.close()
  checkAgree(p)
  checkAgree(demoDir() / "line.sg2")

# ------------------------------------------------------------ index cache --

block old_index_cache_is_rebuilt:
  let p = tmp / "cached.sgy"
  writeSegy(p, 1, fixed = false, binDt = 2000, segyCases)
  let cache = tmp / "cached.idx"
  var f = openSeismic(p, keys = true)
  f.saveIndex(cache)
  f.close()
  var g = openSeismic(p, keys = true, opts = OpenOptions(cache: cache))
  doAssert g.fromCache and g.traceKeys(1).t0Ms == 250
  g.close()
  # The same cache labelled with the previous format version.
  var s = readFile(cache)
  let v = s.find("(version 3)")
  doAssert v >= 0
  s[v + len("(version ")] = '2'
  writeFile(cache, s)
  var h = openSeismic(p, keys = true, opts = OpenOptions(cache: cache))
  doAssert not h.fromCache and h.len == segyCases.len and h.traceKeys(1).t0Ms == 250
  doAssert h.traceKeys(2).status == tsAuxiliary
  h.close()

echo "tkeyfields: ok"
