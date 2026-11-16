## SEG-D Rev 3 orientation: written from `writeTrace`'s `orientation`, read
## back with `traceOrientation`.
##
## Seen to fail first, by breaking the change and restoring it:
## - round_trip: the writer skipped the Orientation block (close raised
##   SegFormatError: the header announced 6 extensions, the trace carried 5)
## - round_trip: `traceOrientation` returned none without scanning (`o0.isSome`)
## - byte_identical: the sum is the 0.14.0 writer's file (972 bytes); a trace
##   given none that gained a block would miss it

import std/[assertions, math, options, os, strutils]
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/writer
import ./utils/testutils

let tmp = scratchDir("parseseg_torient")

const ShotTime = 1_709_273_228.0

template expect(part: string, body: untyped) =
  try:
    body
    doAssert false, "expected ValueError containing: " & part
  except ValueError as e:
    doAssert e.msg.find(part) >= 0, e.msg

proc shot(record, channel: float64, receiver: bool): TraceKeys =
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

proc fileSum(path: string): uint32 =
  for c in readFile(path):
    result = result * 16777619'u32 xor uint32(ord(c))

proc writeBare(path: string) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 4,
    time: ShotTime))
  w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
  w.writeTrace(shot(2, 2, true), @[5'f32, 6, 7, 8])
  w.writeTrace(shot(2, 3, false), @[9'f32, 10, 11, 12], channelType = sctTimeBreak)
  discard w.close()

block byte_identical:
  # The 0.14.0 writer, before orientation existed, produced this file.
  let path = tmp / "bare.sgd"
  writeBare(path)
  doAssert getFileSize(path) == 972
  doAssert fileSum(path) == 1797920802'u32
  let again = tmp / "bare_none.sgd"
  var w = openSeismicWriter(again, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 4,
    time: ShotTime))
  w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4], orientation = none(TraceOrientation))
  w.writeTrace(shot(2, 2, true), @[5'f32, 6, 7, 8], orientation = none(TraceOrientation))
  w.writeTrace(shot(2, 3, false), @[9'f32, 10, 11, 12], channelType = sctTimeBreak,
    orientation = none(TraceOrientation))
  discard w.close()
  doAssert readFile(path) == readFile(again)

proc att(x, y, z: float32, typ: uint8, time = NaN, north = false): TraceOrientation =
  initTraceOrientation(x, y, z, referenceOrientation = 0.25'f32, orientationType = typ,
    refOrientationValid = true, rotationApplied = true, rotationNorthApplied = north,
    time = time)

block round_trip:
  let path = tmp / "nodes.sgd"
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 2,
    time: ShotTime))
  let a = att(0.1'f32, -0.2'f32, 1.5'f32, 1)
  let b = att(-1.25'f32, 0.0'f32, 3.141592'f32, 4, time = ShotTime + 12.5, north = true)
  let c = att(0.5'f32, 0.25'f32, -0.125'f32, 9)
  w.writeTrace(shot(3, 1, true), @[1'f32, 2], orientation = some(a))
  w.writeTrace(shot(3, 2, true), @[3'f32, 4], orientation = some(b))
  w.writeTrace(shot(3, 3, true), @[5'f32, 6]) # no orientation
  var own = shot(3, 1, false)
  own.time = ShotTime + 3
  w.writeTrace(own, @[7'f32, 8], channelType = sctTimeBreak, orientation = some(c))
  discard w.close()
  var f = openSeismic(path)
  doAssert f.len == 4
  let o0 = f.traceOrientation(0)
  doAssert o0.isSome
  doAssert o0.get.rotationX == 0.1'f32 and o0.get.rotationY == -0.2'f32
  doAssert o0.get.rotationZ == 1.5'f32 and o0.get.referenceOrientation == 0.25'f32
  doAssert o0.get.orientationType == 1 and o0.get.refOrientationValid == 1
  doAssert o0.get.rotationApplied == 1 and o0.get.rotationNorthApplied == 0
  doAssert o0.get.timestamp == unixToTimestamp(ShotTime)
  doAssert o0.get.blockType == BlockTypeOrientation
  let o1 = f.traceOrientation(1).get
  doAssert o1.rotationX == -1.25'f32 and o1.rotationY == 0.0'f32
  doAssert o1.rotationZ == 3.141592'f32
  doAssert o1.orientationType == 4 and o1.rotationNorthApplied == 1
  doAssert o1.timestamp == unixToTimestamp(ShotTime + 12.5)
  doAssert f.traceOrientation(2).isNone
  let o3 = f.traceOrientation(3).get
  doAssert o3.rotationX == 0.5'f32 and o3.rotationZ == -0.125'f32
  doAssert o3.orientationType == 9
  doAssert o3.timestamp == unixToTimestamp(ShotTime + 3)
  # The trace header's extension count grew by the one block, and only there.
  doAssert f.traceField(0, "trace.traceHeaderExtensions").intVal ==
    f.traceField(2, "trace.traceHeaderExtensions").intVal + 1
  f.close()
  var u = openSeismic(path, opts = OpenOptions(access: faUnmapped))
  doAssert u.traceOrientation(1).get.rotationZ == 3.141592'f32
  doAssert u.traceOrientation(2).isNone
  expect("no trace"):
    discard u.traceOrientation(9)
  u.close()
  expect("closed"):
    discard u.traceOrientation(0)

block record_time_default:
  # A trace with no keys.time takes the record's time (the option).
  let path = tmp / "fallback.sgd"
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1,
    time: ShotTime))
  var k = shot(1, 1, true)
  k.time = NaN
  w.writeTrace(k, @[1'f32], orientation = some(att(0.0'f32, 1.0'f32, -1.0'f32, 2)))
  discard w.close()
  var f = openSeismic(path)
  doAssert f.traceOrientation(0).get.timestamp == unixToTimestamp(ShotTime)
  f.close()

block refusals:
  let path = tmp / "bad.sgd"
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1,
    time: ShotTime))
  w.writeTrace(shot(1, 1, true), @[1'f32])
  expect("rotationX"):
    w.writeTrace(shot(1, 2, true), @[2'f32],
      orientation = some(att(float32(NaN), 0, 0, 1)))
  expect("inf"):
    w.writeTrace(shot(1, 2, true), @[2'f32],
      orientation = some(att(0, float32(Inf), 0, 1)))
  expect("-inf"):
    w.writeTrace(shot(1, 2, true), @[2'f32],
      orientation = some(att(0, 0, float32(-Inf), 1)))
  expect("referenceOrientation"):
    var bad = att(0.1'f32, 0.2'f32, 0.3'f32, 1)
    bad.referenceOrientation = NaN
    w.writeTrace(shot(1, 2, true), @[2'f32], orientation = some(bad))
  expect("rotationNorthApplied"):
    var north = att(0.1'f32, 0.2'f32, 0.3'f32, 1, north = true)
    north.rotationApplied = false
    w.writeTrace(shot(1, 2, true), @[2'f32], orientation = some(north))
  expect("orientation time"):
    w.writeTrace(shot(1, 2, true), @[2'f32],
      orientation = some(att(0.1'f32, 0.2'f32, 0.3'f32, 1, time = Inf)))
  w.writeTrace(shot(1, 2, true), @[4'f32], orientation = some(att(0.5'f32, 0, 0, 1)))
  discard w.close()
  var f = openSeismic(path)
  doAssert f.len == 2
  doAssert f.traceOrientation(0).isNone
  doAssert f.traceOrientation(1).get.rotationX == 0.5'f32
  f.close()
  var y = openSeismicWriter(tmp / "segy.sgy", SegyOutputOptions())
  expect("orientation"):
    y.writeTrace(shot(1, 1, true), @[1'f32, 2, 3, 4],
      orientation = some(att(0.1'f32, 0, 0, 1)))
  y.writeTrace(shot(1, 1, true), @[1'f32, 2, 3, 4])
  discard y.close()

proc otherWriter(path: string) =
  # A file this library did not write: the Orientation block is the first
  # extension, ahead of the Timestamp block.
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 2, julianDay: 61, hour: 6, minute: 7, second: 8,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3, revisionMinor: 0,
    extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: unixToTimestamp(ShotTime),
    blockType: BlockTypeGeneralHeader3)
  var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, endTime: 1000, numSamples: 2, descaleMultiplier: 1.0,
    channelsInSet: 1, samplingInterval: 1000, arrayForming: 1, traceHeaderExtensions: 3,
    verticalStack: 1, blockType1: BlockTypeChannelSet1, blockType2: BlockTypeChannelSet2,
    blockType3: BlockTypeChannelSet3)
  for i in 0 ..< d.description.len: d.description[i] = ' '
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[d])]
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 2)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: 3)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(numSamples: 2, sensorType: 2, depthIndex: 1,
    blockType: BlockTypeTraceHeaderExt1))
  let orient = SegdOrientation(rotationX: 0.75'f32, rotationY: -0.5'f32, rotationZ: 0.25'f32,
    orientationType: 3, refOrientationValid: 1, rotationApplied: 1,
    timestamp: unixToTimestamp(ShotTime + 1), blockType: BlockTypeOrientation)
  let ts = SegdTimestampHeader(timeZeroOfData: unixToTimestamp(ShotTime),
    blockType: 0x42'u8)
  t.extensions = @(orient.encoded) & @(ts.encoded)
  t.samples = newSeq[byte](dataBytes(sd8058, 2))
  encodeSamples(sd8058, @[1.0'f32, -1.0'f32], t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  let sink = openDiskSink(path)
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(r)
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.close()

block trace_orientation_other_writer:
  let path = tmp / "other.sgd"
  otherWriter(path)
  var f = openSeismic(path)
  let o = f.traceOrientation(0)
  doAssert o.isSome
  doAssert o.get.rotationX == 0.75'f32 and o.get.rotationY == -0.5'f32
  doAssert o.get.rotationZ == 0.25'f32 and o.get.orientationType == 3
  doAssert o.get.timestamp == unixToTimestamp(ShotTime + 1)
  var y = openSeismic(tmp / "segy.sgy")
  doAssert y.traceOrientation(0).isNone
  y.close()
  f.close()

echo "torient ok"
