## SEG-D Rev 3 receiver gathers written from `TraceKeys`
## (`SegdOutputOptions.receiverGather`).
##
## Seen to fail first, by breaking the writer and restoring it:
## - round_trip: source blocks left out of the trace extensions (gather kind
##   was not receiver: the sources were unknown)
## - receiver_must_agree: the receiver check removed (a second receiver was
##   accepted; expected ValueError containing "trace channel 2")

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_treceivergather")

proc same(a, b: float64): bool {.inline.} =
  (a.isNaN and b.isNaN) or a == b

template expect(part: string, body: untyped) =
  try:
    body
    doAssert false, "expected ValueError containing: " & part
  except ValueError as e:
    doAssert e.msg.find(part) >= 0, e.msg

const ShotTime = 1_709_273_228.0

proc rgOpts(n: int): SegdOutputOptions =
  SegdOutputOptions(sampleIntervalUs: 1000, numSamples: n, time: ShotTime,
    receiverGather: true)

proc fileSum(path: string): uint32 =
  for c in readFile(path):
    result = result * 16777619'u32 xor uint32(ord(c))

proc shotBare(record, channel: float64, receiver: bool): TraceKeys =
  # The 0.14.0 shot file (tests/torient.nim): one source, receivers differ.
  result = initTraceKeys()
  result.record = record
  result.channel = channel
  result.intervalUs = 1000
  result.time = ShotTime
  result.srcLine = 1
  result.srcPoint = 99.5
  result.srcIndex = 1
  result.srcX = 500_000
  result.srcY = 6_000_000
  result.srcZ = 12.5
  if receiver:
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

proc writeBare(path: string, receiverGather = false) =
  var o = SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 4, time: ShotTime,
    receiverGather: receiverGather)
  var w = openSeismicWriter(path, o)
  w.writeTrace(shotBare(2, 1, true), @[1'f32, 2, 3, 4])
  w.writeTrace(shotBare(2, 2, true), @[5'f32, 6, 7, 8])
  w.writeTrace(shotBare(2, 3, false), @[9'f32, 10, 11, 12], channelType = sctTimeBreak)
  discard w.close()

proc node(record, channel, srcPoint: float64, seismic: bool): TraceKeys =
  # One receiver (line 500 / point 12). Each trace is a different shot.
  result = initTraceKeys()
  result.record = record
  result.channel = channel
  result.intervalUs = 1000
  result.time = ShotTime + channel * 60
  result.rcvLine = 500
  result.rcvPoint = 12
  result.rcvIndex = 1
  result.rcvX = 1000
  result.rcvY = 2000
  result.rcvZ = 15
  result.srcLine = 10 + float64(int(channel) div 10)
  result.srcPoint = srcPoint
  result.srcIndex = int16(channel)
  result.srcX = 5000 + srcPoint
  result.srcY = 6000
  result.srcZ = 20 + channel
  if seismic:
    result.status = tsLive
    result.component = uint8(1 + int(channel) mod 3)
    result.sensorType = uint8(1 + int(channel) mod 3)
  else:
    result.status = tsAuxiliary
    result.component = 1
    result.sensorType = 1

block shot_stays:
  # A shot gather written today is the 0.14.0 file, and the one-source rule
  # still refuses a second source. Explicit receiverGather = false matches.
  let path = tmp / "bare.sgd"
  writeBare(path)
  doAssert getFileSize(path) == 972
  doAssert fileSum(path) == 1797920802'u32
  let again = tmp / "bare_false.sgd"
  writeBare(again, receiverGather = false)
  doAssert readFile(path) == readFile(again)
  var w = openSeismicWriter(tmp / "one_source.sgd",
    SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1, time: ShotTime))
  w.writeTrace(shotBare(3, 1, true), @[1'f32])
  var other = shotBare(3, 2, true)
  other.srcPoint = 10
  expect("one source"):
    w.writeTrace(other, @[2'f32])
  doAssert w.len == 1
  discard w.close()

block round_trip:
  # Written out of source-point order, so a sort in the writer would show.
  # Record 4: seismic shots, one with no source of its own, one dead, every
  # trace of the set oriented. Record 8: auxiliary only (pilots, a sweep,
  # time break, uphole).
  let path = tmp / "nodes.sgd"
  var w = openSeismicWriter(path, rgOpts(4))
  var keys: seq[TraceKeys]
  var rows: seq[seq[float32]]
  var types: seq[SegdChannelType]
  var orients: seq[Option[TraceOrientation]]
  proc keep(k: TraceKeys, row: seq[float32], ct: SegdChannelType,
      att: Option[TraceOrientation]) =
    w.writeTrace(k, row, channelType = ct, orientation = att)
    keys.add k
    rows.add row
    types.add ct
    orients.add att
  let att = some(initTraceOrientation(0.1'f32, -0.2'f32, 1.5'f32, referenceOrientation = 0.25,
    orientationType = 1, refOrientationValid = true, rotationApplied = true))
  var shots = [node(4, 1, 30, true), node(4, 2, 10, true), node(4, 3, 20.5, true)]
  shots[1].status = tsDead
  shots[2].srcIndex = 2
  var noneSrc = node(4, 4, 40, true)
  noneSrc.srcLine = NaN
  noneSrc.srcPoint = NaN
  noneSrc.srcIndex = 0
  noneSrc.srcX = NaN
  noneSrc.srcY = NaN
  noneSrc.srcZ = NaN
  let seis = [sctSeismic, sctSeismic, sctSeismic, sctSeismic]
  for i, k in [shots[0], shots[1], shots[2], noneSrc]:
    var row = newSeq[float32](4)
    for j in 0 ..< 4: row[j] = float32(i + 1) + float32(j) * 0.25'f32
    keep(k, row, seis[i], att)
  # Six vibrator pilots, plus a sweep, a time break and an uphole: one
  # receiver, each trace its own shot, no seismic trace in the record.
  let auxTypes = [sctSourceRefPilot, sctSourceRefPilot, sctSourceRefPilot,
    sctSourceRefPilot, sctSourceRefPilot, sctSourceRefPilot, sctSourceRefSweep,
    sctTimeBreak, sctUpHole]
  for i, ct in auxTypes:
    var k = node(8, float64(i + 1), 100 + float64(i) * 2, false)
    k.time = ShotTime + 10_000 + float64(i) * 30
    var row = newSeq[float32](4)
    for j in 0 ..< 4: row[j] = float32(10 + i) - float32(j)
    keep(k, row, ct, none(TraceOrientation))
  doAssert w.len == keys.len
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.len == keys.len and f.recordCount == 2
  let gathers = f.gathers
  doAssert gathers.len == 2
  for g in gathers:
    doAssert g.kind == gkReceiver
  doAssert gathers[0].traces == 0 .. 3
  doAssert gathers[1].traces == 4 .. 12
  # File order is write order, not source line then point.
  doAssert f.traceKeys(0).srcPoint == 30
  doAssert f.traceKeys(1).srcPoint == 10
  doAssert f.traceKeys(2).srcPoint == 20.5
  for i, k in keys:
    let g = f.traceKeys(i)
    doAssert same(g.record, k.record) and same(g.channel, k.channel)
    doAssert same(g.srcLine, k.srcLine) and same(g.srcPoint, k.srcPoint)
    doAssert g.srcIndex == k.srcIndex
    doAssert same(g.srcX, k.srcX) and same(g.srcY, k.srcY) and same(g.srcZ, k.srcZ)
    doAssert same(g.rcvLine, k.rcvLine) and same(g.rcvPoint, k.rcvPoint)
    doAssert g.rcvIndex == k.rcvIndex
    doAssert same(g.rcvX, k.rcvX) and same(g.rcvY, k.rcvY) and same(g.rcvZ, k.rcvZ)
    doAssert same(g.time, k.time)
    doAssert g.sensorType == k.sensorType
    doAssert g.component == k.component
    let want = if types[i] == sctSeismic and k.status == tsDead: tsDead
      elif types[i] == sctSeismic: tsLive
      else: tsAuxiliary
    doAssert g.status == want
    doAssert int(f.traceEntry(i).channelType) == ord(types[i])
    let o = f.traceOrientation(i)
    if orients[i].isSome:
      let wantO = orients[i].get
      doAssert o.isSome
      doAssert o.get.rotationX == wantO.rotationX and o.get.rotationY == wantO.rotationY
      doAssert o.get.rotationZ == wantO.rotationZ
      doAssert o.get.referenceOrientation == wantO.referenceOrientation
      doAssert o.get.orientationType == wantO.orientationType
      doAssert o.get.refOrientationValid == 1 and o.get.rotationApplied == 1
    else:
      doAssert o.isNone
    let y = f.readTraces(i .. i)
    for j in 0 ..< 4: doAssert y[0, j] == rows[i][j]
  f.close()

block receiver_must_agree:
  let path = tmp / "disagree.sgd"
  var w = openSeismicWriter(path, rgOpts(2))
  let row = @[1'f32, 2'f32]
  w.writeTrace(node(1, 1, 10, true), row)
  var other = node(1, 2, 20, true)
  other.rcvLine = 9
  expect("trace channel 2"):
    w.writeTrace(other, row)
  other = node(1, 3, 20, true)
  other.rcvIndex = 4
  expect("trace channel 3"):
    w.writeTrace(other, row)
  other = node(1, 4, 20, true)
  other.rcvX = 1
  expect("trace channel 4"):
    w.writeTrace(other, row)
  other = node(1, 5, 20, true)
  other.rcvZ = 99
  expect("trace channel 5"):
    w.writeTrace(other, row)
  other = node(1, 6, 20, true)
  other.rcvLine = NaN
  other.rcvPoint = NaN
  other.rcvX = NaN
  other.rcvY = NaN
  other.rcvZ = NaN
  expect("trace channel 6"):
    w.writeTrace(other, row)
  other = node(1, 7, 20, true)
  other.rcvX = NaN
  other.rcvY = NaN
  other.rcvZ = NaN
  expect("trace channel 7"):
    w.writeTrace(other, row)
  doAssert w.len == 1 # refused traces were not kept
  w.writeTrace(node(1, 8, 30, true), row)
  w.writeTrace(node(2, 1, 40, true), row) # a later record
  discard w.close()
  var f = openSeismic(path, keys = true)
  doAssert f.len == 3
  doAssert f.traceKeys(0).channel == 1 and f.traceKeys(1).channel == 8
  doAssert f.traceKeys(2).record == 2
  doAssert f.gathers[0].kind == gkReceiver and f.gathers[1].kind == gkShot
  f.close()
