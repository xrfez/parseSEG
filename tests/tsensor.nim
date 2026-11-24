## SEG-D Rev 3 Sensor Info serial: `unitSerial` (trace header extensions) and
## `recordSensorSerial` (general header blocks).
##
## Seen to fail first, by breaking the change and restoring it:
## - trace_round_trip: `unitSerial` returned none without scanning (`s.isSome`)
## - trim_and_none: the NUL/blank trim removed (the padded serial came back
##   with its blanks); the blank field returned some("")
## - not_text: the printable check removed (the serial with byte 0x80 came back)
## - other_formats: the Rev 3 check removed (the Rev 2 file's 0x41 block was
##   returned)
## - general_header_is_separate: `unitSerial` also scanned the general header
##   (`s.isNone` failed); `recordSensorSerial` returned none (`r.isSome`)
## - manufacturer_serial_only: a fallback to `gh1.manufacturerSerial` returned
##   some for both
## - out_of_range: the range check removed (an index error, not a ValueError)

import std/[assertions, options, os, strutils]

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

proc sensorBlock(serial: openArray[byte]): seq[byte] =
  # A Sensor Info block: the serial in bytes 14-31 (18 bytes), type 0x41.
  result = newSeq[byte](32)
  for i in 0 ..< min(serial.len, 18): result[13 + i] = serial[i]
  result[31] = 0x41

proc text(s: string): seq[byte] =
  for c in s: result.add byte(c)

proc padded(s: string): seq[byte] =
  text(s & ' '.repeat(18 - s.len))

proc sensorFile(path: string, general, trace: seq[byte], manufacturerSerial = 0) =
  # One Rev 3 trace; `general` is appended to the general header blocks and
  # `trace` to the trace header extensions (either may be empty).
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add general
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: uint8(2 + general.len div 32), julianDay: 61, hour: 6, minute: 7,
    second: 8, manufacturerSerial: manufacturerSerial, baseScanInterval16: 16,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3, revisionMinor: 0,
    extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: unixToTimestamp(ShotTime),
    blockType: BlockTypeGeneralHeader3)
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(numSamples: 1, sensorType: 1, depthIndex: 1,
    blockType: BlockTypeTraceHeaderExt1))
  t.extensions = trace
  let the = uint8(1 + trace.len div 32)
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

proc rev2File(path: string, trace: seq[byte]) =
  # A Rev 2 file whose trace extensions carry a 0x41 block: not a serial there.
  var r = SegdRecord(layout: slRev2, format: some(sd8058),
    revision: SegdRevision(major: 2, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 1, julianDay: 1, manufacturerCode: 9, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 1, revisionMajor: 2, revisionMinor: 0,
    extRecordLength: 1000, blockNumber: 2)
  let the = uint8(1 + trace.len div 32)
  let c = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 1,
    endTime: 2, channelCount: 1, channelType: 1, gainControl: 1, traceHeaderExtensions: the,
    verticalStack: 1, arrayForming: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[c])]
  r.traceCount = 1
  var t = SegdTrace(layout: slRev2, index: 0, numSamples: 1)
  t.ext1 = some(SegdTraceHeaderExt1())
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: the)
  t.extensions = trace
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  var d = SegdData()
  d.records.add SegdRecordData(record: r, traces: @[t])
  let sink = openDiskSink(path)
  doAssert writeSegd(sink, d).count(sevError) == 0
  sink.close()

proc traceSerial(f: SeismicFile, i: int): Option[string] =
  f.unitSerial(i)

proc recordSerial(f: SeismicFile, i: int): Option[string] =
  f.recordSensorSerial(i)

proc main*() =
  let tmp = scratchDir("parseseg_tsensor")
  let none32: seq[byte] = @[]

  block trace_round_trip:
    # The serial is trimmed of its blank padding; the block sits after another.
    let path = tmp / "unit.sgd"
    var other = newSeq[byte](32)
    other[31] = 0x42
    sensorFile(path, none32, other & sensorBlock(padded("N1234567")))
    var f = openSeismic(path)
    let s = f.traceSerial(0)
    doAssert s.isSome and s.get == "N1234567", $s
    doAssert f.recordSerial(0).isNone
    f.close()
    var u = openSeismic(path, opts = OpenOptions(access: faUnmapped))
    doAssert u.traceSerial(0).get == "N1234567"
    u.close()

  block trim_and_none:
    # Leading blanks and NULs go too; a blank or NUL-only field is none; a
    # full 18-character field is whole; the first block wins.
    var s = sensorFile
    let cases = [
      (text("  AB 12") & newSeq[byte](11), "AB 12"),
      (text("0123456789ABCDEFGH"), "0123456789ABCDEFGH"),
      (text("X") & newSeq[byte](17), "X"),
      (padded(""), ""),
      (newSeq[byte](18), "")]
    for i, c in cases:
      let path = tmp / ("trim" & $i & ".sgd")
      s(path, none32, sensorBlock(c[0]))
      var f = openSeismic(path)
      let got = f.traceSerial(0)
      if c[1].len == 0: doAssert got.isNone, $got
      else: doAssert got.isSome and got.get == c[1], $got
      f.close()
    let path = tmp / "two.sgd"
    s(path, none32, sensorBlock(padded("FIRST")) & sensorBlock(padded("SECOND")))
    var f = openSeismic(path)
    doAssert f.traceSerial(0).get == "FIRST"
    f.close()
    let nothing = tmp / "absent.sgd"
    s(nothing, none32, none32)
    var g = openSeismic(nothing)
    doAssert g.traceSerial(0).isNone and g.recordSerial(0).isNone
    g.close()

  block not_text:
    for bad in [0x80'u8, 0x1F, 0x7F, 0xFF]:
      let path = tmp / ("bin" & $bad & ".sgd")
      sensorFile(path, none32, sensorBlock(text("AB") & @[bad] & text("CD")))
      var f = openSeismic(path)
      doAssert f.traceSerial(0).isNone
      f.close()
      let gpath = tmp / ("gbin" & $bad & ".sgd")
      sensorFile(gpath, sensorBlock(text("AB") & @[bad] & text("CD")), none32)
      var g = openSeismic(gpath)
      doAssert g.recordSerial(0).isNone
      g.close()

  block general_header_is_separate:
    let path = tmp / "gh41.sgd"
    sensorFile(path, sensorBlock(padded("GEN-9")), none32)
    var f = openSeismic(path)
    doAssert f.traceSerial(0).isNone
    let r = f.recordSerial(0)
    doAssert r.isSome and r.get == "GEN-9", $r
    f.close()
    let both = tmp / "both41.sgd"
    sensorFile(both, sensorBlock(padded("GEN-9")), sensorBlock(padded("T-1")))
    var g = openSeismic(both)
    doAssert g.traceSerial(0).get == "T-1" and g.recordSerial(0).get == "GEN-9"
    g.close()

  block manufacturer_serial_only:
    let path = tmp / "maker.sgd"
    sensorFile(path, none32, none32, manufacturerSerial = 4321)
    var f = openSeismic(path)
    doAssert f.traceSerial(0).isNone
    doAssert f.recordSerial(0).isNone
    f.close()

  block other_formats:
    let r2 = tmp / "rev2.sgd"
    rev2File(r2, sensorBlock(padded("REV2-1")))
    var a = openSeismic(r2)
    doAssert a.traceSerial(0).isNone and a.recordSerial(0).isNone
    a.close()
    let sgy = tmp / "one.sgy"
    var y = openSeismicWriter(sgy, SegyOutputOptions())
    var k = initTraceKeys()
    k.record = 1
    k.channel = 1
    k.intervalUs = 1000
    y.writeTrace(k, @[1'f32, 2, 3, 4])
    discard y.close()
    var b = openSeismic(sgy)
    doAssert b.traceSerial(0).isNone and b.recordSerial(0).isNone
    b.close()
    let sg2 = tmp / "one.sg2"
    doAssert not convertFile(sgy, sg2, ConvertOptions(target: skSeg2)).isFatal
    var c = openSeismic(sg2)
    doAssert c.kind == skSeg2
    doAssert c.traceSerial(0).isNone and c.recordSerial(0).isNone
    c.close()

  block out_of_range:
    let path = tmp / "range.sgd"
    sensorFile(path, sensorBlock(padded("A")), sensorBlock(padded("B")))
    var f = openSeismic(path)
    expect("no trace"):
      discard f.traceSerial(5)
    expect("no trace"):
      discard f.traceSerial(-1)
    expect("no record"):
      discard f.recordSerial(3)
    f.close()
    expect("closed"):
      discard f.traceSerial(0)
    expect("closed"):
      discard f.recordSerial(0)

  echo "tsensor ok"

when isMainModule: main()
