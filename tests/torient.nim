## SEG-D Rev 3 orientation: written from `writeTrace`'s `orientation`, read
## back with `traceOrientation`.
##
## Seen to fail first, by breaking the change and restoring it:
## - round_trip: the writer skipped the Orientation block (close raised
##   SegFormatError: the header announced 6 extensions, the trace carried 5)
## - round_trip: `traceOrientation` returned none without scanning (`o0.isSome`)
## - byte_identical: the sum is the 0.14.0 writer's file (972 bytes) but for
##   the record and window lengths (3 ms became 4 ms); a trace given none that
##   gained a block would miss it
## - general_header_orientation_is_separate: `recordOrientation` returned none
##   (`o.isSome`)
## - second_orientation_is_not_reported: a second block added a warning
##   (`f.log.len` grew); a query takes a plain SeismicFile, not `var`

import std/[assertions, math, options, os, strutils]

import parseSEG

import parseSEG/io/diskio

import parseSEG/segd/writer

import ./utils/testutils

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

proc att(x, y, z: float32, typ: uint8, time = NaN, north = false): TraceOrientation =
  initTraceOrientation(x, y, z, referenceOrientation = 0.25'f32, orientationType = typ,
    refOrientationValid = true, rotationApplied = true, rotationNorthApplied = north,
    time = time)

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

proc queryTrace(f: SeismicFile, trace: int): Option[SegdOrientation] =
  # A non-var file: a query does not write the log.
  f.traceOrientation(trace)

proc queryRecord(f: SeismicFile, record: int): Option[SegdOrientation] =
  f.recordOrientation(record)

proc orientFile(path: string, general: bool, second: bool, differ: bool) =
  # One trace. `general`: the Orientation block is in the general header.
  # `second`: another block after the first; `differ` makes it disagree.
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  let orient = SegdOrientation(rotationX: 0.3'f32, rotationY: 0, rotationZ: 0,
    orientationType: 2, refOrientationValid: 1, rotationApplied: 1,
    timestamp: unixToTimestamp(ShotTime), blockType: BlockTypeOrientation)
  if general:
    r.generalBlocks.add @(orient.encoded)
    if second:
      var other = orient
      if differ:
        other.rotationX = 9.0'f32
        other.orientationType = 1
      r.generalBlocks.add @(other.encoded)
  let nOpt = r.generalBlocks.len div 32
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: uint8(2 + nOpt), julianDay: 61, hour: 6, minute: 7, second: 8,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3, revisionMinor: 0,
    extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: unixToTimestamp(ShotTime),
    blockType: BlockTypeGeneralHeader3)
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(numSamples: 1, sensorType: 1, depthIndex: 1,
    blockType: BlockTypeTraceHeaderExt1))
  if not general:
    t.extensions.add orient.encoded
    if second:
      var other = orient
      if differ:
        other.rotationX = 9.0'f32
        other.orientationType = 1
      t.extensions.add other.encoded
  let the = uint8(1 + t.extensions.len div 32)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: the)
  var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, endTime: 1000, numSamples: 1, descaleMultiplier: 1.0,
    channelsInSet: 1, samplingInterval: 1000, arrayForming: 1, traceHeaderExtensions: the,
    verticalStack: 1, blockType1: BlockTypeChannelSet1, blockType2: BlockTypeChannelSet2,
    blockType3: BlockTypeChannelSet3)
  for i in 0 ..< d.description.len: d.description[i] = ' '
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[d])]
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  let sink = openDiskSink(path)
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(r)
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.close()

proc main*() =
  let tmp = scratchDir("parseseg_torient")

  block byte_identical:
    # The 0.14.0 writer, before orientation existed, produced this file, but for
    # two length fields: the record length and the channel set end (N x dt).
    let path = tmp / "bare.sgd"
    writeBare(path)
    doAssert getFileSize(path) == 972
    doAssert fileSum(path) == 2804808630'u32
    let again = tmp / "bare_none.sgd"
    var w = openSeismicWriter(again, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 4,
      time: ShotTime))
    w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4], orientation = none(TraceOrientation))
    w.writeTrace(shot(2, 2, true), @[5'f32, 6, 7, 8], orientation = none(TraceOrientation))
    w.writeTrace(shot(2, 3, false), @[9'f32, 10, 11, 12], channelType = sctTimeBreak,
      orientation = none(TraceOrientation))
    discard w.close()
    doAssert readFile(path) == readFile(again)

  block round_trip:
    let path = tmp / "nodes.sgd"
    var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 2,
      time: ShotTime))
    let a = att(0.1'f32, -0.2'f32, 1.5'f32, 1)
    let b = att(-1.25'f32, 0.0'f32, 3.141592'f32, 4, time = ShotTime + 12.5, north = true)
    let c = att(0.5'f32, 0.25'f32, -0.125'f32, 9)
    w.writeTrace(shot(3, 1, true), @[1'f32, 2], orientation = some(a))
    w.writeTrace(shot(3, 2, true), @[3'f32, 4], orientation = some(b))
    w.writeTrace(shot(3, 3, true), @[5'f32, 6], orientation = some(a))
    var own = shot(3, 1, false)
    own.time = ShotTime + 3
    w.writeTrace(own, @[7'f32, 8], channelType = sctTimeBreak, orientation = some(c))
    w.writeTrace(shot(4, 1, true), @[9'f32, 10]) # a set with no orientation
    discard w.close()
    var f = openSeismic(path)
    doAssert f.len == 5
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
    doAssert f.traceOrientation(2).get.rotationX == 0.1'f32
    let o3 = f.traceOrientation(3).get
    doAssert o3.rotationX == 0.5'f32 and o3.rotationZ == -0.125'f32
    doAssert o3.orientationType == 9
    doAssert o3.timestamp == unixToTimestamp(ShotTime + 3)
    doAssert f.traceOrientation(4).isNone
    # One skeleton: every trace of the seismic set has the same extension count.
    doAssert f.traceField(0, "trace.traceHeaderExtensions").intVal ==
      f.traceField(2, "trace.traceHeaderExtensions").intVal
    f.close()
    var u = openSeismic(path, opts = OpenOptions(access: faUnmapped))
    doAssert u.traceOrientation(1).get.rotationZ == 3.141592'f32
    doAssert u.traceOrientation(4).isNone
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
    w.writeTrace(shot(2, 1, true), @[4'f32], orientation = some(att(0.5'f32, 0, 0, 1)))
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

  block general_header_orientation_is_separate:
    # The spec does not say a general-header 0x60 applies to traces without
    # their own. Seen to fail first: recordOrientation missing (does not compile
    # / returned none when the trace scan was wrongly extended).
    let path = tmp / "gh60.sgd"
    orientFile(path, general = true, second = false, differ = false)
    var f = openSeismic(path)
    doAssert f.traceOrientation(0).isNone
    let o = f.recordOrientation(0)
    doAssert o.isSome
    doAssert o.get.rotationX == 0.3'f32 and o.get.orientationType == 2
    doAssert f.log.len == 0
    expect("no record"):
      discard f.recordOrientation(3)
    f.close()

  block second_orientation_is_not_reported:
    # The first block wins. A second, different one is not reported: indexing
    # does not walk a trace's header extensions, and a query does not write
    # the log. Seen to fail first: the query took `var` (this file did not
    # compile) and a second block added a warning (`f.log.len` grew).
    let path = tmp / "two60.sgd"
    orientFile(path, general = false, second = true, differ = true)
    var f = openSeismic(path)
    let before = f.log.len
    let o = queryTrace(f, 0)
    doAssert o.isSome and o.get.rotationX == 0.3'f32 and o.get.orientationType == 2
    doAssert f.log.len == before
    discard queryTrace(f, 0)
    doAssert f.log.len == before
    f.close()
    # An identical second block is the same: the first is used, no warning.
    orientFile(tmp / "same60.sgd", general = false, second = true, differ = false)
    var g = openSeismic(tmp / "same60.sgd")
    doAssert queryTrace(g, 0).get.rotationX == 0.3'f32
    doAssert g.log.len == 0
    g.close()
    # A second general-header block is not reported either.
    orientFile(tmp / "two_gh60.sgd", general = true, second = true, differ = true)
    var h = openSeismic(tmp / "two_gh60.sgd")
    let rec = queryRecord(h, 0)
    doAssert rec.isSome and rec.get.rotationX == 0.3'f32 and rec.get.orientationType == 2
    doAssert h.log.len == 0
    doAssert queryTrace(h, 0).isNone
    h.close()

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

when isMainModule: main()
