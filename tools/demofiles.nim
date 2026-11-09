## Small generated demo files, written by the library's own writers, for the
## usage guides' examples (`tests/tdocs.nim`), the CLI smoke tests (CI) and
## anyone who wants a file to try the library on. The values are synthetic
## and fixed, so every run writes the same bytes.
##
## | File | What it is |
## |---|---|
## | `survey.sgy` | SEG-Y Rev 2.1, big-endian, IBM float: a post-stack line of 200 traces of 2001 samples at 2 ms, inline 1001, crosslines 1-200, kept in trace bytes 13 and 17 and described by a Layout stanza |
## | `shot.sgd` | SEG-D Rev 3.0, format 8058, one shot record: 3 auxiliary traces and 2 seismic ones of 4001 samples at 1 ms, with source and receiver positions and a Location Data stanza |
## | `record.sgd` | SEG-D Rev 2.0, format 8058, record 63: one seismic trace of 1000 samples at 2 ms, station numbers but no coordinates |
## | `line.sg2` | SEG-2, little-endian, float32: 24 traces of 1000 samples at 0.5 ms along a line |
##
## As a program: `nim c -r --path:src tools/demofiles.nim [dir]` writes them
## into `dir` (default: the current directory).

import std/[os, math, options, strutils]
import parseSEG/common/endians
import parseSEG/io/diskio
import parseSEG/segy/[samples as segysamples, textheader, exttext, binheader, traceheader,
  reader as segyreader, writer as segywriter]
import parseSEG/segd/[samples as segdsamples, headers as segdheaders, rev3, blocks,
  reader as segdreader, writer as segdwriter]
import parseSEG/seg2/[headers as seg2headers, writer as seg2writer]

const demoFileNames* = ["survey.sgy", "shot.sgd", "record.sgd", "line.sg2"]
  ## The files `writeDemoFiles` writes.

func ricker(t, f: float64): float64 =
  ## A Ricker wavelet of peak frequency `f` Hz at time `t` s.
  let a = (PI * f * t) ^ 2
  (1 - 2 * a) * exp(-a)

proc trace(n: int, dtS: float64, events: openArray[(float64, float64)], amp: float64,
    seed: uint32): seq[float64] =
  ## `n` samples at `dtS` s: Ricker wavelets at the (time s, weight) `events`,
  ## plus a little deterministic noise. Rounded to 1/64, so every format
  ## the demo files use holds the values exactly.
  result = newSeq[float64](n)
  var s = seed * 2654435761'u32 + 1
  for i in 0..<n:
    s = s * 1664525'u32 + 1013904223'u32
    var x = (float64(s shr 8) / float64(1 shl 24) - 0.5) * 0.01
    let t = float64(i) * dtS
    for (t0, w) in events: x += w * ricker(t - t0, 25)
    result[i] = round(x * amp * 64) / 64

# ------------------------------------------------------------------ SEG-Y --

const surveyLayout = """<segy-layout name="parseSEG demo">
  <desc>Inline and crossline numbers in bytes 13 and 17, CDP coordinates in 73 and 77.</desc>
  <entry name="iline" byte="13" type="int4"/>
  <entry name="xline" byte="17" type="int4"/>
  <entry name="cdp_x" byte="73" type="coor4"/>
  <entry name="cdp_y" byte="77" type="coor4"/>
</segy-layout>"""

proc writeSurveySegy*(path: string) =
  ## `survey.sgy`: SEG-Y Rev 2.1, big-endian, IBM float, fixed-length; 200
  ## post-stack traces of 2001 samples at 2 ms (inline 1001, crosslines
  ## 1-200), three dipping reflectors.
  const traces = 200
  const ns = 2001
  var f = SegyFile(byteOrder: boBig, format: some(sfIbm32))
  f.text = initTextHeader(teEbcdic)
  f.text.setCard(1, "C01 parseSEG demo survey: a synthetic post-stack line (tools/demofiles.nim)")
  f.text.setCard(2, "C02 inline 1001, crosslines 1-200, 2001 samples at 2 ms, IBM float")
  f.text.setCard(3, "C03 inline in trace bytes 13-16, crossline in 17-20 (Layout stanza)")
  f.text.setCard(4, "C04 CDP x and y in trace bytes 73-80, metres")
  for n in 5..38: f.text.setCard(n, "C" & align($n, 2, '0'))
  f.text.setCard(39, "C39 SEG-Y_REV2.1")
  f.text.setCard(40, "C40 END TEXTUAL HEADER")
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "Layout", surveyLayout, "text/xml")
  ext.addEndText()
  f.extended = ext
  f.trailer = initExtendedTextHeader()
  f.binary = SegyBinaryHeader(jobId: 1, lineNumber: 1001, reelNumber: 1,
    dataTracesPerEnsemble: 1, sampleInterval: 2000, samplesPerTrace: ns, formatCode: 1,
    ensembleFold: 1, traceSorting: 2, measurementSystem: 1, segyMajor: 2, segyMinor: 1,
    fixedLengthTraces: 1, numExtTextHeaders: int16(ext.recordCount),
    byteOrderMarker: ByteOrderMarker)
  let sink = openDiskSink(path)
  try:
    var w = openSegyWriter(sink, f, initSegyWriteOptions(f))
    var x = newSeq[float32](ns)
    for k in 0..<traces:
      let xl = k + 1
      let cx = int32(500_000 + 25 * k)
      let cy = int32(6_000_000 + 10 * k)
      var t = SegyTrace(index: k, numSamples: ns, sampleInterval: 2000)
      t.header = SegyTraceHeader(traceSeqLine: int32(xl), traceSeqFile: int32(xl),
        traceNumberInField: 1001, energySourcePoint: int32(xl),
        ensembleNumber: int32(1001 * 1000 + xl), traceIdCode: 1, elevationScalar: 1,
        coordinateScalar: 1, sourceX: cx, sourceY: cy, coordinateUnits: 1,
        numSamples: ns, sampleInterval: 2000, cdpX: cx, cdpY: cy)
      let events = [(0.6 + 0.001 * float64(k), 1.0), (1.4 - 0.0015 * float64(k), -0.7),
        (2.8, 0.5)]
      let v = trace(ns, 0.002, events, 5000, uint32(k))
      for i in 0..<ns: x[i] = float32(v[i])
      t.samples = newSeq[byte](ns * sampleSize(sfIbm32))
      encodeSamples(sfIbm32, x, t.samples, boBig)
      w.writeTrace(t)
    w.close()
    doAssert w.log.len == 0, $w.log[0]
  finally:
    sink.close()

# ------------------------------------------------------------------ SEG-D --

proc blk(t: uint8, text = ""): seq[byte] =
  ## A raw 32-byte Rev 3 block of type `t`, `text` in bytes 1-31.
  result = newSeq[byte](32)
  for i, c in text: result[i] = byte(c)
  result[31] = t

proc crsBlocks(text: string): seq[byte] =
  ## `text` in 0x55 (CRS) blocks of 31 characters, the last padded with blanks.
  var i = 0
  while i < text.len:
    let chunk = text[i ..< min(i + 31, text.len)]
    result.add blk(BlockTypeCrs, chunk & repeat(' ', 31 - chunk.len))
    i += 31

proc position(x, y, z: float64): SegdPositionBlock =
  SegdPositionBlock(timeOfPosition: 1_478_000_000_000_000, tuple1Coord1: x,
    tuple1Coord2: y, tuple1Coord3: z, stanzaId1: 1, position1Valid: 1, position1Quality: 1,
    tuple2Coord1: Inf, tuple2Coord2: Inf, tuple2Coord3: Inf, blockType1: 0x50,
    blockType2: 0x51, blockType3: 0x52)

const shotCrs = "((SEG: Location Data ver 3.0))\r\nLocation Data Stanza ID = 1\r\n" &
  "CRS name = WGS 84 / UTM zone 32N\r\nCRS code = 32632\r\nCRS type = projected\r\n"

proc writeShotSegd*(path: string) =
  ## `shot.sgd`: SEG-D Rev 3.0, format 8058, one record (file number 12):
  ## channel sets 1-3 are auxiliary (time break, up hole, pilot; one trace
  ## each), set 4 is seismic (two traces, receiver line 100, points 201 and
  ## 202). 4001 samples at 1 ms. The traces are in the order CS1, CS3, CS2,
  ## CS4, CS4, as some recorders write them. The source (line 1, point 1001)
  ## is at (500000, 6000000); the receivers at (506000, 6008000) and 50 m
  ## east of it, so trace 3's offset is 10000 m.
  const ns = 4001
  const fileNo = 12
  let fmt = sd8058
  var r = SegdRecord(layout: slRev3, format: some(fmt),
    revision: SegdRevision(major: 3, minor: 0))
  r.generalBlocks.add blk(0x11, "parseSEG demo shot")
  r.generalBlocks.add crsBlocks(shotCrs)
  let src = SegdSourceDescription(extFileNumber: fileNo, sourceLineNumber: 1,
    sourcePointNumber: 1001, sourcePointIndex: 1, sourceSetNumber: 1, blockType: 0x16)
  r.generalBlocks.add @(src.encoded)
  r.generalBlocks.add @(position(500_000, 6_000_000, 12.5).encoded)
  let nOpt = r.generalBlocks.len div 32
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: uint8(2 + nOpt), julianDay: 313, hour: 9, minute: 41, second: 7,
    manufacturerCode: 20, baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 4, skewBlocks: 0,
    extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: fileNo, revisionMajor: 3,
    extRecordLength: uint32(1000 * (ns - 1)), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1_478_000_000_000_000, blockType: 3)
  var descs: seq[SegdChannelSetDescriptorRev3]
  for (n, ctype, count, exts) in [(1, 0x20'u8, 1, 1'u8), (2, 0x30'u8, 1, 1'u8),
      (3, 0x98'u8, 1, 1'u8), (4, 0x10'u8, 2, 4'u8)]:
    descs.add SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(n),
      channelType: ctype, endTime: int32(1000 * (ns - 1)), numSamples: ns,
      descaleMultiplier: 1.0, channelsInSet: uint32(count), samplingInterval: 1000,
      traceHeaderExtensions: exts, verticalStack: 1, blockType1: 0x30, blockType2: 0x31,
      blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  var traces: seq[SegdTrace]
  # (channel set, trace number in the set) in physical order.
  for k, (cs, tn) in [(1, 1), (3, 1), (2, 1), (4, 1), (4, 2)]:
    let seismic = cs == 4
    var t = SegdTrace(layout: slRev3, index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: fileNo, scanTypeNumber: 1, channelSetNumber: cs,
      traceNumber: tn, traceHeaderExtensions: (if seismic: 4'u8 else: 1'u8))
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: (if seismic: 100 else: 0),
      receiverPointNumber: (if seismic: int32(200 + tn) else: 0), receiverPointIndex: 1,
      numSamples: ns, sensorType: (if seismic: 2'u8 else: 0'u8), blockType: 0x40)
    var v: seq[float64]
    if seismic:
      t.extensions = @(position(506_000 + 50 * float64(tn - 1), 6_008_000, 10).encoded)
      v = trace(ns, 0.001, [(1.2, 1.0), (2.5, 0.6)], 1000, uint32(10 + tn))
    else:
      v = newSeq[float64](ns)
      case cs
      of 1: v[0] = 1                                  # time break at time zero
      of 2: v[120] = 0.5                              # up hole at 120 ms
      else:                                           # the pilot: a short sweep
        for i in 0 ..< 1000:
          let ts = float64(i) * 0.001
          v[i] = round(sin(2 * PI * (10 * ts + 20 * ts * ts)) * 64) / 64
    t.samples = newSeq[byte](dataBytes(fmt, ns))
    encodeSamples(fmt, v, t.samples)
    traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = traces.len
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: @[SegdRecordData(record: r, traces: traces)]))
    doAssert log.len == 0, $log[0]
  finally:
    sink.close()

proc writeRecordSegd*(path: string) =
  ## `record.sgd`: SEG-D Rev 2.0, format 8058, record 63 with one seismic
  ## trace (channel 1, receiver line 10, point 104) of 1000 samples at 2 ms.
  ## The source is line 20, point 99.5; there are no coordinates. Its source
  ## set and array forming are 0 (out of range: two info diagnostics).
  const ns = 1000
  const fileNo = 63
  let fmt = sd8058
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 2, julianDay: 313, hour: 10, minute: 2, second: 30,
    manufacturerCode: 20, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1, skewBlocks: 0,
    extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: fileNo, revisionMajor: 2,
    extRecordLength: uint32(2 * ns), blockNumber: 2)
  r.sourceHeaders = @[SegdGeneralHeaderN(sourceLineNumber: 20, sourcePointNumber: 99.5,
    sourcePointIndex: 1, blockNumber: 3, sourceSetNumber: 0)]
  # Source set 0 and array forming 0 are out of range, as in many real files:
  # two info diagnostics at open.
  let cs = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 0,
    endTime: uint16(ns), channelCount: 1, channelType: 1, gainControl: 3,
    traceHeaderExtensions: 1, verticalStack: 1, arrayForming: 0)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[cs])]
  r.traceCount = 1
  var t = SegdTrace(index: 0, numSamples: ns)
  t.header = SegdTraceHeader(fileNumber: fileNo, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: 1)
  t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 10, receiverPointNumber: 104,
    receiverPointIndex: 1, samplesPerTrace: ns, sensorType: 2)
  t.samples = newSeq[byte](dataBytes(fmt, ns))
  encodeSamples(fmt, trace(ns, 0.002, [(0.4, 1.0), (1.1, -0.5)], 1000, 63), t.samples)
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, SegdData(records: @[SegdRecordData(record: r, traces: @[t])]))
    doAssert log.len == 0, $log[0]
  finally:
    sink.close()

# ------------------------------------------------------------------ SEG-2 --

proc writeLineSeg2*(path: string) =
  ## `line.sg2`: SEG-2, little-endian, float32 (format 4); 24 traces of 1000
  ## samples at 0.5 ms, receivers every 2 m from 0 m, the source at -2 m.
  const traces = 24
  const ns = 1000
  var fdb = initSeg2File(boLittle)
  fdb.traceCount = traces
  fdb["ACQUISITION_DATE"] = "09/NOV/2026"
  fdb["ACQUISITION_TIME"] = "10:15:00"
  fdb["LINE_ID"] = "7"
  fdb["UNITS"] = "METERS"
  var w = openSeg2Writer(path, fdb)
  var x = newSeq[float32](ns)
  for i in 0..<traces:
    let rx = 2.0 * float64(i)
    var t = Seg2Trace(formatCode: 4)
    # In keyword order, as the standard asks.
    t["CHANNEL_NUMBER"] = $(i + 1)
    t["RECEIVER"] = "VERTICAL_GEOPHONE"
    t["RECEIVER_LOCATION"] = formatFloat(rx, ffDecimal, 1)
    t["SAMPLE_INTERVAL"] = "0.0005"
    t["SHOT_SEQUENCE_NUMBER"] = "1"
    t["SOURCE_LOCATION"] = "-2.0"
    let v = trace(ns, 0.0005, [(0.02 + (rx + 2) / 600, 1.0), (0.2, 0.3)], 100, uint32(i))
    for k in 0..<ns: x[k] = float32(v[k])
    w.writeTrace(t, x)
  w.close()
  doAssert w.log.len == 0, $w.log[0]

proc writeDemoFiles*(dir: string) =
  ## Writes every demo file (`demoFileNames`) into `dir`, created if needed.
  createDir(dir)
  writeSurveySegy(dir / "survey.sgy")
  writeShotSegd(dir / "shot.sgd")
  writeRecordSegd(dir / "record.sgd")
  writeLineSeg2(dir / "line.sg2")

when isMainModule:
  let dir = if paramCount() >= 1: paramStr(1) else: getCurrentDir()
  writeDemoFiles(dir)
  for n in demoFileNames: echo dir / n, ": ", getFileSize(dir / n), " bytes"
