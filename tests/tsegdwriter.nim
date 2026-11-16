## SEG-D Rev 3 written from `TraceKeys` (`SegdOutputOptions`).
##
## Seen to fail first, by breaking the writer and restoring it:
## - round_trip_records: channel type forced to 0x10 (status assert, line 110)
## - dead_feet_and_caller_crs: trace edit forced to 0 (same status assert)
## - metres/feet: CRS text not written (coordinateUnits assert, line 96)
## - without_coordinates: a 0,0 position block written for a missing source
##   (srcX assert, line 104)
## - refusals: the record-order check and the sample-count check removed
##   (expected ValueError, line 22)
## - depth_index_unset_is_one: depth index left 0 (reads back 0, not 1)

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tsegdwriter")

proc same(a, b: float64): bool {.inline.} =
  (a.isNaN and b.isNaN) or a == b

template expect(part: string, body: untyped) =
  try:
    body
    doAssert false, "expected ValueError containing: " & part
  except ValueError as e:
    doAssert e.msg.find(part) >= 0, e.msg

proc opts(n: int, dt = 1000.0, units = cuMeters, crs = ""): SegdOutputOptions =
  SegdOutputOptions(sampleIntervalUs: dt, numSamples: n, units: units, crsText: crs)

proc shot(record, channel: float64, seismic: bool): TraceKeys =
  result = initTraceKeys()
  result.record = record
  result.channel = channel
  result.intervalUs = 1000
  result.srcLine = 1
  result.srcPoint = 99.5
  result.srcIndex = 1
  result.srcX = 500_000
  result.srcY = 6_000_000
  result.srcZ = 12.5
  if seismic:
    result.rcvLine = 100
    result.rcvPoint = 200 + channel
    result.rcvIndex = 1
    result.rcvX = 506_000 + 50 * channel
    result.rcvY = 6_008_000
    result.rcvZ = 10
    result.status = tsLive
    result.component = 2
    result.sensorType = 2
  else:
    result.status = tsAuxiliary

proc samples(n: int, seed: float32): seq[float32] =
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = seed + float32(i) * 0.25'f32 - 1.5'f32

proc openOut(path: string, o: SegdOutputOptions): SeismicWriter =
  openSeismicWriter(path, o)

block round_trip_records:
  # Two records: seismic, a dead seismic trace, time break and a reference
  # sweep, with coordinates; then a record with stations and no coordinates.
  let path = tmp / "shots.sgd"
  var w = openOut(path, opts(4))
  var rows: seq[seq[float32]]
  var keys: seq[TraceKeys]
  var types: seq[SegdChannelType]
  var dead = shot(2, 2, true)
  dead.status = tsDead
  let plan = [
    (shot(2, 1, true), sctSeismic),
    (dead, sctSeismic),
    (shot(2, 1, false), sctTimeBreak),
    (shot(2, 1, false), sctSourceRefSweep),
    (shot(7, 1, true), sctSeismic)]
  # Record 7: stations only, no coordinates.
  var bare = plan[4][0]
  bare.srcX = NaN
  bare.srcY = NaN
  bare.srcZ = NaN
  bare.rcvX = NaN
  bare.rcvY = NaN
  bare.rcvZ = NaN
  for i, item in plan:
    var k = item[0]
    if i == 4: k = bare
    let row = samples(4, float32(i + 1))
    w.writeTrace(k, row, channelType = item[1])
    keys.add k
    rows.add row
    types.add item[1]
  doAssert w.len == 5
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.kind == skSegd and f.len == 5 and f.recordCount == 2
  doAssert f.summary.coordinateUnits == cuMeters and f.summary.crsFormat == ctP1_11
  doAssert f.crsText.find("HC,1,6,1,metre") >= 0
  doAssert f.summary.formatCode == 8058 and f.summary.sampleIntervalUs == 1000
  for i, k in keys:
    let g = f.traceKeys(i)
    doAssert same(g.record, k.record) and same(g.channel, k.channel)
    doAssert same(g.srcLine, k.srcLine) and same(g.srcPoint, k.srcPoint)
    doAssert g.srcIndex == k.srcIndex
    doAssert same(g.srcX, k.srcX) and same(g.srcY, k.srcY) and same(g.srcZ, k.srcZ)
    doAssert same(g.rcvLine, k.rcvLine) and same(g.rcvPoint, k.rcvPoint)
    doAssert same(g.rcvX, k.rcvX) and same(g.rcvY, k.rcvY) and same(g.rcvZ, k.rcvZ)
    let want = if types[i] == sctSeismic and k.status == tsDead: tsDead
      elif types[i] == sctSeismic: tsLive
      else: tsAuxiliary
    doAssert g.status == want
    doAssert int(f.traceEntry(i).channelType) == ord(types[i])
    if k.component != 0: doAssert g.component == k.component
    let y = f.readTraces(i .. i)
    for j in 0 ..< 4: doAssert y[0, j] == rows[i][j]
  # Channel sets: seismic, time break, reference sweep in record 0; seismic in record 1.
  var got: seq[int]
  for c in f.channelSets: got.add c.channelType
  doAssert got == @[0x10, 0x20, 0x96, 0x10]
  f.close()

block dead_feet_and_caller_crs:
  let path = tmp / "feet.sgd"
  let crs = "((SEG: Location Data ver 3.0))\nLocation Data Stanza ID = 1\nCRS name = local\n"
  var w = openOut(path, opts(2, units = cuFeet, crs = crs))
  var k = shot(1, 1, true)
  k.status = tsDead
  w.writeTrace(k, @[1'f32, -2])
  discard w.close()
  var f = openSeismic(path, keys = true)
  # A Location Data stanza is not P1/11: the reader does not take units from it.
  doAssert f.summary.coordinateUnits == cuUnknown and f.summary.crsFormat == ctStanza
  doAssert f.crsText.startsWith("((SEG: Location Data ver 3.0))")
  doAssert f.traceKeys(0).status == tsDead
  doAssert f.traceField(0, "trace.traceEdit").toFloat == 1
  f.close()
  let metres = tmp / "metres.sgd"
  var m = openOut(metres, opts(2))
  var live = shot(3, 1, true)
  m.writeTrace(live, @[4'f32, 5])
  discard m.close()
  var g = openSeismic(metres)
  doAssert g.summary.coordinateUnits == cuMeters and g.crsText.find("metre") >= 0
  g.close()

block without_coordinates:
  let path = tmp / "nostation.sgd"
  var w = openOut(path, opts(3))
  var k = initTraceKeys()
  k.record = 9
  k.channel = 1
  k.intervalUs = 1000
  k.status = tsLive
  w.writeTrace(k, @[0'f32, 1, -1])
  discard w.close()
  var f = openSeismic(path, keys = true)
  let t = f.traceKeys(0)
  doAssert t.srcX.isNaN and t.srcY.isNaN and t.rcvX.isNaN and t.rcvY.isNaN
  doAssert t.srcZ.isNaN and t.rcvZ.isNaN and t.srcLine.isNaN and t.rcvLine.isNaN
  doAssert t.offset.isNaN and t.status == tsLive
  f.close()

block same_keys_both_formats:
  # One shot, the same keys and samples, as SEG-Y and as SEG-D.
  var f = openSeismic(demoDir() / "shot.sgd", keys = true)
  let n = int(f.traceEntry(0).numSamples)
  let x = f.readTraces(0 ..< f.len)
  let types = [sctTimeBreak, sctSourceRefPilot, sctUpHole, sctSeismic, sctSeismic]
  var row = newSeq[float32](n)
  var y = openSeismicWriter(tmp / "shot.sgy", SegyOutputOptions())
  var d = openOut(tmp / "shot.sgd", opts(n))
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    for j in 0 ..< n: row[j] = x[i, j]
    y.writeTrace(k, row)
    d.writeTrace(k, row, channelType = types[i])
  discard y.close()
  discard d.close()
  var g = openSeismic(tmp / "shot.sgd", keys = true)
  doAssert g.len == f.len and g.recordCount == 1
  for i in 0 ..< f.len:
    let a = f.traceKeys(i)
    let b = g.traceKeys(i)
    doAssert same(a.record, b.record) and same(a.channel, b.channel)
    doAssert same(a.srcLine, b.srcLine) and same(a.srcPoint, b.srcPoint)
    doAssert same(a.srcX, b.srcX) and same(a.srcY, b.srcY) and same(a.srcZ, b.srcZ)
    doAssert same(a.rcvLine, b.rcvLine) and same(a.rcvPoint, b.rcvPoint)
    doAssert same(a.rcvX, b.rcvX) and same(a.rcvY, b.rcvY) and same(a.rcvZ, b.rcvZ)
    doAssert b.status == a.status
    doAssert int(g.traceEntry(i).channelType) == ord(types[i])
    let z = g.readTraces(i .. i)
    for j in 0 ..< n: doAssert z[0, j] == x[i, j]
  var sy = openSeismic(tmp / "shot.sgy", keys = true)
  doAssert sy.kind == skSegy and sy.len == f.len
  doAssert sy.traceKeys(3).rcvX == f.traceKeys(3).rcvX
  sy.close()
  g.close()
  f.close()

block auto_channel_and_gap:
  let path = tmp / "auto.sgd"
  var w = openOut(path, opts(1, dt = 500))
  var a = initTraceKeys()
  a.record = 1
  a.intervalUs = 500
  a.status = tsLive
  var b = a
  b.record = 4 # a gap is allowed
  w.writeTrace(a, @[1'f32])
  w.writeTrace(a, @[2'f32])
  w.writeTrace(b, @[3'f32])
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.traceKeys(0).channel == 1 and f.traceKeys(1).channel == 2
  doAssert f.traceKeys(2).record == 4 and f.traceKeys(2).channel == 1
  doAssert f.summary.sampleIntervalUs == 500
  f.close()

block refusals:
  let path = tmp / "bad.sgd"
  expect("3.0 or 3.1"):
    discard openOut(path, SegdOutputOptions(revision: SegdRevision(major: 2, minor: 0),
      sampleIntervalUs: 1000, numSamples: 4))
  expect("not defined in Rev"):
    discard openOut(path, SegdOutputOptions(revision: SegdRevision(major: 3, minor: 0),
      format: sd9058, sampleIntervalUs: 1000, numSamples: 4))
  expect("whole number of microseconds"):
    discard openOut(path, SegdOutputOptions(sampleIntervalUs: 1000.5, numSamples: 4))
  expect("at least 1"):
    discard openOut(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 0))
  expect("groups of 4"):
    discard openOut(path, SegdOutputOptions(format: sd8015, sampleIntervalUs: 1000, numSamples: 2))
  expect("metres or feet"):
    discard openOut(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1,
      units: cuDegrees))
  var w = openOut(path, opts(4))
  let row = samples(4, 1)
  var k = shot(3, 1, true)
  w.writeTrace(k, row)
  var back = k
  back.record = 1
  expect("written in order"):
    w.writeTrace(back, row)
  doAssert w.len == 1 # the refused trace was not kept
  var other = samples(2, 1)
  expect("one sample count"):
    w.writeTrace(k, other)
  var aux = shot(3, 2, false)
  aux.status = tsLive
  expect("reads back as auxiliary"):
    w.writeTrace(aux, row, channelType = sctTimeBreak)
  var seis = shot(3, 3, true)
  seis.status = tsAuxiliary
  expect("auxiliary SEG-D channel type"):
    w.writeTrace(seis, row)
  var half = shot(3, 4, true)
  half.rcvPoint = NaN
  expect("both a line and a point"):
    w.writeTrace(half, row)
  var otherSrc = shot(3, 5, true)
  otherSrc.srcPoint = 10
  expect("one source"):
    w.writeTrace(otherSrc, row)
  var late = shot(3, 6, true)
  late.t0Ms = 12
  expect("one start time"):
    w.writeTrace(late, row)
  var drift = shot(3, 7, true)
  drift.intervalUs = 2000
  expect("sample interval"):
    w.writeTrace(drift, row)
  # Still usable after the refusals.
  w.writeTrace(shot(3, 8, true), row)
  w.writeTrace(shot(8, 1, true), row) # a later record
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.len == 3 and f.traceKeys(0).record == 3 and f.traceKeys(2).record == 8
  f.close()
  var empty = openOut(tmp / "empty.sgd", opts(1))
  expect("no traces"):
    discard empty.close()
  doAssert not fileExists(tmp / "empty.sgd")
  block:
    var dropped = openOut(tmp / "dropped.sgd", opts(1))
    dropped.writeTrace(shot(1, 1, true), @[1'f32])
  doAssert not fileExists(tmp / "dropped.sgd")
  var closed = openOut(tmp / "closed.sgd", opts(1))
  closed.writeTrace(shot(1, 1, true), @[1'f32])
  discard closed.close()
  expect("closed"):
    closed.writeTrace(shot(1, 1, true), @[1'f32])

block channel_numbers_unique:
  # A trace number is unique in its channel set. Without the refusal, two
  # traces numbered 1 both read back as 1. And the automatic number advanced
  # even for an explicit one, so channel 2 then NaN read back as 2 and 2.
  let path = tmp / "channels.sgd"
  var w = openOut(path, opts(1))
  let row = samples(1, 1)
  w.writeTrace(shot(4, 1, true), row)
  expect("already used"):
    w.writeTrace(shot(4, 1, true), row)
  discard w.close()
  let auto = tmp / "auto_channels.sgd"
  var a = openOut(auto, opts(1))
  a.writeTrace(shot(1, 2, true), row)
  var nan = shot(1, 2, true)
  nan.channel = NaN
  a.writeTrace(nan, row) # the lowest number not yet used in the set: 1
  var explicit = shot(1, 1, true)
  expect("already used"):
    a.writeTrace(explicit, row) # 1 was given to the NaN trace
  discard a.close()
  var f = openSeismic(auto, keys = true)
  doAssert f.len == 2 and f.traceKeys(0).channel == 2 and f.traceKeys(1).channel == 1
  f.close()

block window_fits_channel_set:
  # A channel set's end time is int32 microseconds: start + (samples - 1) *
  # interval. Without the refusal, 2.2 million samples at 1000 µs (a window
  # of 2 200 s) wrote an end time of 0 while the samples were written.
  let path = tmp / "window.sgd"
  var w = openOut(path, opts(2_200_000))
  expect("does not fit"):
    w.writeTrace(shot(1, 1, true), samples(2_200_000, 1))
  expect("no traces"):
    discard w.close() # nothing was written: the output is discarded
  doAssert not fileExists(path)
  # The start time may be negative, and the end time must still fit.
  var late = shot(2, 1, true)
  late.t0Ms = 2_147_483 # 2 147 483 000 µs: the start fits, the end does not
  var v = openOut(tmp / "late.sgd", opts(3))
  expect("does not fit"):
    v.writeTrace(late, samples(3, 1))
  expect("no traces"):
    discard v.close()
  late.t0Ms = 2_147_482 # ends at 2 147 483 000 µs
  var u = openOut(tmp / "end.sgd", opts(2))
  u.writeTrace(late, samples(2, 1))
  discard u.close()
  var f = openSeismic(tmp / "end.sgd", keys = true)
  doAssert f.channelSets[0].endTimeMs == 2_147_483.0
  f.close()
  # A window longer than the field's 2^32 - 1 µs is refused when the writer opens.
  expect("longer than"):
    discard openOut(tmp / "huge.sgd", SegdOutputOptions(sampleIntervalUs: 1000,
      numSamples: 5_000_000))
  doAssert not fileExists(tmp / "huge.sgd")

block infinite_coordinates:
  # NaN is an unknown coordinate; an infinite one is refused. Without the
  # refusal, srcX = Inf was written as a position, and the reader then
  # dropped the whole tuple, reading every coordinate of it back as NaN.
  let path = tmp / "inf.sgd"
  var w = openOut(path, opts(1))
  var k = shot(1, 1, true)
  k.srcX = Inf
  expect("infinite"):
    w.writeTrace(k, samples(1, 1))
  var z = shot(1, 2, true)
  z.rcvZ = -Inf
  expect("infinite"):
    w.writeTrace(z, samples(1, 1))
  w.writeTrace(shot(1, 3, true), samples(1, 1))
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.len == 1 and f.traceKeys(0).channel == 3
  doAssert f.traceKeys(0).srcX == 500_000 and f.traceKeys(0).srcY == 6_000_000
  f.close()

block descriptor_description_is_spaces:
  # The channel set descriptor's 27-byte description is text, and the
  # standard requires spaces. Without the fill it was 0x00 bytes, which a
  # strict reader rejects. This reader drops NULs and logs nothing.
  let path = tmp / "descr.sgd"
  var w = openOut(path, opts(2))
  w.writeTrace(shot(1, 1, true), samples(2, 1))
  w.writeTrace(shot(1, 2, false), samples(2, 2), channelType = sctTimeBreak)
  discard w.close()
  var f = openSeismic(path, keys = true)
  let descs = f.index.segdRecords[0].scanTypes[0].descriptorsRev3
  doAssert descs.len == 2
  for d in descs:
    for ch in d.description: doAssert ch == ' ', "description holds " & $ord(ch)
  f.close()

block base_scan_interval_short_field:
  # General Header #1's base scan interval is a short field only for 1, 2, 4
  # ... 128 sixteenths of a millisecond (125 µs to 8 ms in steps that double,
  # 62.5 µs for 1). Other intervals are 0xFF, with the µs value in General
  # Header #2. Without that, 2500 µs wrote 40 in the short field; the reader
  # read the interval from the channel set, so it did not notice.
  for (dt, short) in [(2500.0, 0xFF'u8), (3000.0, 0xFF'u8), (10000.0, 0xFF'u8),
      (2000.0, 32'u8), (4000.0, 64'u8)]:
    let path = tmp / ("scan" & $int(dt) & ".sgd")
    var w = openOut(path, opts(2, dt = dt))
    var k = shot(1, 1, true)
    k.intervalUs = dt
    w.writeTrace(k, samples(2, 1))
    discard w.close()
    var f = openSeismic(path, keys = true)
    doAssert f.index.segdRecords[0].gh1.baseScanInterval16 == short, "interval " & $dt
    doAssert f.summary.sampleIntervalUs == dt, "interval " & $dt
    f.close()

block elevation_without_xy_warns_once:
  # An elevation is written in a position block, which needs its X and Y, so
  # an elevation with none is not written (the reader gives NaN). Without the
  # warning, nothing said so; the SEG-2 writer warns for the same case, once
  # per file. Here three traces each lose their receiver elevation.
  let path = tmp / "elev.sgd"
  var w = openOut(path, opts(1))
  for ch in 1 .. 3:
    var k = shot(1, float64(ch), true)
    k.rcvX = NaN
    k.rcvY = NaN
    k.rcvZ = 15
    w.writeTrace(k, samples(1, 1))
  let log = w.close()
  var warnings = 0
  for d in log:
    if d.msg.find("elevation") >= 0:
      doAssert d.severity == sevWarning
      inc warnings
  doAssert warnings == 1, "warnings about elevations: " & $warnings
  var f = openSeismic(path, keys = true)
  doAssert f.traceKeys(0).rcvZ.isNaN
  f.close()

block coordinates_need_a_crs:
  # A position in the file needs a CRS (the checklist: position present, CRS
  # present). With units unknown and no crsText, no 0x55 block was written,
  # and the coordinates were. Now refused, and the caller is told to set
  # units or crsText. Unknown coordinates, or a caller's crsText, are fine.
  let path = tmp / "nocrs.sgd"
  var w = openOut(path, opts(2, units = cuUnknown))
  expect("units"):
    w.writeTrace(shot(1, 1, true), samples(2, 1))
  var bare = shot(1, 2, true)
  bare.srcX = NaN
  bare.srcY = NaN
  bare.srcZ = NaN
  bare.rcvX = NaN
  bare.rcvY = NaN
  bare.rcvZ = NaN
  w.writeTrace(bare, samples(2, 1))
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.len == 1 and f.summary.coordinateUnits == cuUnknown
  f.close()
  let crs = "((SEG: Location Data ver 3.0))\nLocation Data Stanza ID = 1\nCRS name = local\n"
  var c = openOut(tmp / "crs_unknown.sgd", opts(2, units = cuUnknown, crs = crs))
  c.writeTrace(shot(1, 1, true), samples(2, 1))
  discard c.close()
  var g = openSeismic(tmp / "crs_unknown.sgd", keys = true)
  doAssert g.crsText.startsWith("((SEG: Location Data ver 3.0))")
  g.close()

block depth_index_unset_is_one:
  # A source or receiver depth index is never 0 (1 = shallowest). Without
  # the substitution, the keys' default 0 was written on Trace Header
  # Extension #1 and on the source description, and read back as 0.
  let path = tmp / "depth.sgd"
  var w = openOut(path, opts(1))
  var unset = shot(1, 1, true)
  doAssert unset.depthIndex == 0
  w.writeTrace(unset, samples(1, 1))
  var deep = shot(1, 2, true)
  deep.depthIndex = 4
  w.writeTrace(deep, samples(1, 2))
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.traceKeys(0).depthIndex == 1
  doAssert f.traceKeys(1).depthIndex == 4
  var found = false
  let area = f.index.segdRecords[0].generalBlocks
  for at, bt in blocks(area):
    if bt == 0x1F:
      let s = decodeBlock[SegdSourceDescription](area.toOpenArray(at, at + 31))
      doAssert s.depthIndex == 1
      found = true
  doAssert found, "the record has no source description"
  f.close()
