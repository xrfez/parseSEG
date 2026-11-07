## SEG-D revision conversion (task 8.7): Rev 2 ↔ Rev 3 on the real samples
## and on synthetic records (every Rev 2 format, trailers, labels, tape),
## the logged losses, and records that cannot be represented.

import std/[assertions, os, strutils, math]
import parseSEG/common/diagnostics
import parseSEG/io/[records, diskio, tapeimage]
import parseSEG/segd/[reader, writer, headers, samples, rev3, revconvert]
import parseSEG/model/traceindex

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_tsegdrevconvert"
createDir(tmp)

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc writeBytes(path: string, b: openArray[byte]) =
  var s = newString(b.len)
  for i, x in b: s[i] = char(x)
  writeFile(path, s)

proc rev(major, minor: int): SegdConvertOptions =
  SegdConvertOptions(revision: SegdRevision(major: uint8(major), minor: uint8(minor)))

proc has(log: DiagLog, text: string, sev = sevInfo): bool =
  for d in log:
    if d.severity == sev and text in d.msg: return true

proc clean(log: DiagLog): bool =
  ## No warning, error or fatal.
  log.count(sevWarning) + log.count(sevError) + log.count(sevFatal) == 0

proc toDisk(d: SegdData, path: string) =
  let sink = openDiskSink(path)
  try: doAssert writeSegd(sink, d).clean
  finally: sink.close()

func decodeF64(f: SegdSampleFormat, b: openArray[byte], n: int): seq[float64] =
  result = newSeq[float64](n)
  decodeSegdSamples(f, b, result)

# ------------------------------------------------------ 63.sgd: Rev 2.0 → 3.0 --

block rev20_sample_to_rev3_and_back:
  let src = exampleDir / "63.sgd"
  let orig = readSegd(src)
  let o = orig.records[0]
  let log = convertSegdRevision(src, tmp / "63_r3.sgd", rev(3, 0))
  doAssert log.clean, $log
  doAssert log.has("time zero comes from General Header #1")
  doAssert log.has("trace header extensions after #1 are dropped")
  let d = readSegd(tmp / "63_r3.sgd")
  doAssert d.diagnostics.clean, $d.diagnostics
  let r = d.records[0].record
  doAssert r.isRev3 and r.revision == SegdRevision(major: 3, minor: 0)
  doAssert r.format == sd8058 and d.records[0].traces.len == 1
  doAssert int64(r.gh3.recordSize) == getFileSize(tmp / "63_r3.sgd")
  doAssert r.gh3.timeZero == unixToTimestamp(generalHeaderUtc(o.record.gh1))
  # GH#1 keeps its bytes but for the block count (GH#2, GH#3, one source).
  doAssert r.gh1.additionalGhBlocks == 3 and r.gh1.fileNumber == o.record.gh1.fileNumber
  doAssert r.gh1.julianDay == o.record.gh1.julianDay and r.gh1.second == o.record.gh1.second
  # The GH#3 source header became a Source Description block.
  doAssert r.generalBlocks.len == 32
  let s = decodeRev3[SegdSourceDescription](r.generalBlocks)
  let g = o.record.sourceHeaders[0]
  doAssert s.sourcePointNumber == 99.5 and s.sourceLineNumber == g.sourceLineNumber
  doAssert s.sourcePointIndex == g.sourcePointIndex and s.blockType in {0x15'u8, 0x1F}
  let c2 = o.record.scanTypes[0].descriptors[0]
  let c3 = r.scanTypes[0].descriptors3[0]
  doAssert c3.channelType == c2.channelType shl 4
  doAssert float64(c3.samplingInterval) == c2.sampleIntervalMs(o.record.gh1) * 1000
  doAssert c3.numSamples == uint32(o.traces[0].numSamples)
  doAssert float64(c3.descaleMultiplier) == pow(2.0, c2.mpFactor)
  doAssert c3.channelsInSet == uint32(c2.channelCount) and c3.traceHeaderExtensions == 1
  doAssert c3.endTime == int32(c2.endTimeMs * 1000)
  doAssert r.extended == o.record.extended and r.external == o.record.external
  let t2 = o.traces[0]
  let t3 = d.records[0].traces[0]
  doAssert t3.samples == t2.samples and t3.numSamples == t2.numSamples
  doAssert t3.ext1r3.receiverLineNumber == t2.ext1.receiverLineNumber
  doAssert t3.ext1r3.receiverPointNumber == t2.ext1.receiverPointNumber
  doAssert t3.ext1r3.extReceiverLineNumber == t2.ext1.extReceiverLineNumber
  doAssert t3.ext1r3.sensorType == t2.ext1.sensorType and t3.extensions.len == 0
  # And back to 2.0: everything but the dropped extensions comes back.
  let back = convertSegdRevision(tmp / "63_r3.sgd", tmp / "63_back.sgd", rev(2, 0))
  doAssert back.clean, $back
  let b = readSegd(tmp / "63_back.sgd")
  doAssert b.diagnostics.clean, $b.diagnostics
  let rb = b.records[0].record
  doAssert rb.revision == SegdRevision(major: 2, minor: 0) and not rb.isRev3
  doAssert rb.gh1.encoded == o.record.gh1.encoded
  doAssert rb.sourceHeaders.len == 1
  doAssert rb.sourceHeaders[0].sourcePointNumber == g.sourcePointNumber
  doAssert rb.sourceHeaders[0].sourceLineNumber == g.sourceLineNumber
  doAssert rb.sourceHeaders[0].sourceSetNumber == g.sourceSetNumber
  doAssert rb.gh2.extRecordLength == o.record.gh2.extRecordLength
  let cb = rb.scanTypes[0].descriptors[0]
  doAssert cb.startTime == c2.startTime and cb.endTime == c2.endTime
  doAssert cb.mpRaw == c2.mpRaw and cb.channelCount == c2.channelCount
  doAssert cb.channelType == c2.channelType and cb.subscanExponent == c2.subscanExponent
  doAssert cb.aliasFilterFreq == c2.aliasFilterFreq and cb.lowCutSlope == c2.lowCutSlope
  doAssert cb.notch1Freq == c2.notch1Freq and cb.arrayForming == c2.arrayForming
  doAssert rb.extended == o.record.extended
  let tb = b.records[0].traces[0]
  doAssert tb.samples == t2.samples and tb.ext1.samplesPerTrace == t2.ext1.samplesPerTrace
  doAssert tb.ext1.receiverPointNumber == t2.ext1.receiverPointNumber
  doAssert tb.header.traceNumber == t2.header.traceNumber

block rev20_to_rev21_changes_only_the_revision:
  let log = convertSegdRevision(exampleDir / "63.sgd", tmp / "63_21.sgd", rev(2, 1))
  doAssert log.clean, $log
  var want = readBytes(exampleDir / "63.sgd")
  want[32 + 11] = 1 # GH#2 byte 12: revision minor
  doAssert readBytes(tmp / "63_21.sgd") == want

# ----------------------------------------------- INOVA: Rev 3.0 → 2.1 → 3.0 --

block rev30_sample_to_rev21_and_back:
  let src = exampleDir / "inova_rev30_5traces.sgd"
  let orig = readSegd(src)
  let o = orig.records[0]
  let log = convertSegdRevision(src, tmp / "inova_r2.sgd", rev(2, 1))
  doAssert log.clean, $log
  for text in ["type 0x55 (crs)", "type 0x50 (position)", "General Header #3",
      "kept as raw Rev 2 extensions", "descale multipliers are approximated"]:
    doAssert log.has(text), text
  let d = readSegd(tmp / "inova_r2.sgd")
  doAssert d.diagnostics.count(sevWarning) + d.diagnostics.count(sevError) == 0, $d.diagnostics
  let r = d.records[0].record
  doAssert not r.isRev3 and r.revision == SegdRevision(major: 2, minor: 1)
  doAssert r.gh2.lineSequenceNumber == o.record.gh2r3.recordSetNumber
  doAssert r.extended == o.record.extended and r.external == o.record.external
  # The explosive Source Description became GH#3.
  doAssert r.sourceHeaders.len == 1
  var srcOff = -1
  for off, t in blocks(o.record.generalBlocks):
    if t == 0x16: srcOff = off
  let s = decodeRev3[SegdSourceDescription](o.record.generalBlocks.toOpenArray(srcOff,
    srcOff + 31))
  doAssert r.sourceHeaders[0].sourcePointNumber == s.sourcePointNumber
  doAssert r.sourceHeaders[0].sourceLineNumber == s.sourceLineNumber
  for i, st in r.scanTypes:
    for k, c in st.descriptors:
      let c3 = o.record.scanTypes[i].descriptors3[k]
      doAssert c.channelCount == int(c3.channelsInSet)
      doAssert c.channelType == c3.channelType shr 4
      doAssert c.startTime == uint16(c3.startTime div 2000)
      doAssert c.endTime == uint16(c3.endTime div 2000)
      doAssert abs(pow(2.0, c.mpFactor) / float64(c3.descaleMultiplier) - 1) < 1e-3
      doAssert c.sampleIntervalMs(r.gh1) * 1000 == float64(c3.samplingInterval)
  doAssert d.records[0].traces.len == 5
  for k, t in d.records[0].traces:
    let t3 = o.traces[k]
    doAssert t.samples == t3.samples and t.numSamples == t3.numSamples
    doAssert t.ext1.samplesPerTrace == uint32(t3.numSamples)
    doAssert t.ext1.receiverPointNumber == t3.ext1r3.receiverPointNumber
    doAssert t.ext1.extReceiverLineNumber == t3.ext1r3.extReceiverLineNumber
    doAssert t.ext1.sensorType == t3.ext1r3.sensorType
    # Blocks after THE#1 (vendor 0xB0-0xB8 and others) are kept raw.
    doAssert t3.extensions.len div 32 <= 14
    doAssert t.extensions == t3.extensions
  # Back to Rev 3: readable, sizes right, samples intact.
  let back = convertSegdRevision(tmp / "inova_r2.sgd", tmp / "inova_back.sgd", rev(3, 0))
  doAssert back.clean, $back
  let b = readSegd(tmp / "inova_back.sgd")
  doAssert b.diagnostics.count(sevWarning) + b.diagnostics.count(sevError) == 0
  doAssert int64(b.records[0].record.gh3.recordSize) == getFileSize(tmp / "inova_back.sgd")
  for k, t in b.records[0].traces:
    doAssert t.samples == o.traces[k].samples and t.numSamples == o.traces[k].numSamples
  # Rev 2.0 has no record set number.
  let to20 = convertSegdRevision(src, tmp / "inova_r20.sgd", rev(2, 0))
  if o.record.gh2r3.recordSetNumber != 0:
    doAssert to20.has("Rev 2.0 has no record set")

# ------------------------------------------------- synthetic Rev 2 records --

proc makeRev2(fileNo: int, format: SegdSampleFormat, ns = 52): SegdRecordData =
  ## One Rev 2.1 record: an aux set (2 traces, no extensions) and a seismic set
  ## (3 traces with THE#1 and one more extension), skew, extended and trailer.
  var r = SegdRecord(format: format, formatKnown: true, hasGh2: true,
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(format), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, minute: 30, second: 5,
    manufacturerCode: 9, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 2, skewBlocks: 1, extendedHeaderBlocks: 1,
    externalHeaderBlocks: 0)
  r.gh2 = SegdGeneralHeader2(extFileNumber: uint32(fileNo), revisionMajor: 2, revisionMinor: 1,
    generalTrailerBlocks: 2, extRecordLength: uint32(2 * ns), blockNumber: 2,
    lineSequenceNumber: 77)
  r.sourceHeaders = @[SegdGeneralHeaderN(sourceLineNumber: 1001.5, sourcePointNumber: -12.25,
    sourcePointIndex: 1, phaseControl: 1, vibratorType: 2, phaseAngle: -90, blockNumber: 3,
    sourceSetNumber: 1)]
  var aux = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
    endTime: uint16(ns), channelCount: 2, channelType: 9, gainControl: 3, verticalStack: 1,
    arrayForming: 1)
  aux.mpFactor = -2.5
  let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 2,
    endTime: uint16(ns), channelCount: 3, channelType: 1, gainControl: 3,
    aliasFilterFreq: 200, aliasFilterSlope: 370, lowCutFreq: 3, lowCutSlope: 18,
    notch1Freq: 500, traceHeaderExtensions: 2, verticalStack: 1, arrayForming: 1)
  var skew = newSeq[byte](32)
  for i in 0..<skew.len: skew[i] = byte(i)
  r.scanTypes = @[SegdScanType(descriptors: @[aux, seis], skew: skew)]
  r.extended = newSeq[byte](32)
  for i in 0..<32: r.extended[i] = byte(200 + i mod 50)
  r.trailer = @[SegdTrailerBlock(trailerNumber: 1, channelType: 0xC),
    SegdTrailerBlock(trailerNumber: 2, channelType: 0xC)]
  r.trailer[1].undef12[0] = 0x5A
  r.traceCount = 5
  result.record = r
  for k in 0..<5:
    let isAux = k < 2
    var t = SegdTrace(index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: fileNo, scanTypeNumber: 1,
      channelSetNumber: (if isAux: 1 else: 2), traceNumber: (if isAux: k + 1 else: k - 1),
      traceHeaderExtensions: (if isAux: 0'u8 else: 2'u8))
    if not isAux:
      t.hasExt1 = true
      t.ext1 = SegdTraceHeaderExt1(receiverLineNumber: 2000, receiverPointNumber: int32(100 + k),
        receiverPointIndex: 1, samplesPerTrace: uint32(ns), sensorType: 2)
      t.extensions = newSeq[byte](32)
      t.extensions[0] = byte(k)
    var vals = newSeq[float64](ns)
    for i in 0..<ns:
      vals[i] = float64((i mod 9) - 4) * (if format in {sd8036, sd8038, sd9036, sd9038}: 1000.0 else: 0.125)
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSegdSamples(format, vals, t.samples)
    result.traces.add t

block synthetic_rev2_every_format_to_rev3_and_back:
  var d: SegdData
  for i, f in segdSampleFormats:
    if f != sd8080 and not f.isLittleEndian: d.records.add makeRev2(100 + i, f)
  toDisk(d, tmp / "multi_r2.sgd")
  let log = convertSegdRevision(tmp / "multi_r2.sgd", tmp / "multi_r3.sgd", rev(3, 0))
  doAssert log.clean, $log
  doAssert log.has("user trailer group")
  let r3 = readSegd(tmp / "multi_r3.sgd")
  doAssert r3.diagnostics.clean, $r3.diagnostics
  doAssert r3.records.len == d.records.len
  for i, rd in r3.records:
    let o = d.records[i]
    let r = rd.record
    doAssert r.isRev3 and r.format == o.record.format
    doAssert r.gh2r3.recordSetNumber == 77
    # The vibrator GH#N became a Vibrator Source Description.
    let s = decodeRev3[SegdSourceDescription](r.generalBlocks)
    doAssert s.blockType == 0x15 and s.phaseAngle == -90 and s.vibratorType == 2
    doAssert s.phaseControl == 1 and s.sourcePointNumber == -12.25
    let aux3 = r.scanTypes[0].descriptors3[0]
    doAssert aux3.channelType == 0x90 and aux3.descaleMultiplier == float32(pow(2.0, -2.5))
    let seis3 = r.scanTypes[0].descriptors3[1]
    doAssert seis3.aliasFilterFreq == 200 and seis3.aliasFilterSlope == 370
    doAssert seis3.notch1Freq == 50 and seis3.samplingInterval == 2000
    doAssert r.scanTypes[0].skew == o.record.scanTypes[0].skew
    # The trailer travels in one user group.
    let td = decodeRev3[SegdTrailerDescription](r.trailerBytes)
    doAssert td.trailerBlockType == 0xA0 and td.blockSize == 2
    doAssert r.trailerBytes.len == 96
    for k, t in rd.traces:
      doAssert t.samples == o.traces[k].samples, $r.format
      doAssert t.ext1r3.numSamples == 52 and t.extensions.len == 0
  # Back to 2.1: trailers unwrap, every sample and header value returns.
  let back = convertSegdRevision(tmp / "multi_r3.sgd", tmp / "multi_back.sgd", rev(2, 1))
  doAssert back.clean, $back
  let b = readSegd(tmp / "multi_back.sgd")
  doAssert b.diagnostics.clean
  for i, rd in b.records:
    let o = d.records[i]
    doAssert rd.record.gh1.encoded == o.record.gh1.encoded
    doAssert rd.record.gh2.lineSequenceNumber == 77
    doAssert rd.record.trailer.len == 2
    for k in 0..1: doAssert rd.record.trailer[k].encoded == o.record.trailer[k].encoded
    doAssert rd.record.sourceHeaders[0].encoded == o.record.sourceHeaders[0].encoded
    for k, c in rd.record.scanTypes[0].descriptors:
      var want = o.record.scanTypes[0].descriptors[k]
      want.traceHeaderExtensions = 1 # Rev 3 gave every trace THE#1 (aux sets too)
      doAssert c.encoded == want.encoded, $k
    for k, t in rd.traces:
      doAssert t.samples == o.traces[k].samples
      if o.traces[k].hasExt1:
        doAssert t.ext1.encoded == o.traces[k].ext1.encoded

block rev2_on_tape_without_a_header_scan:
  # The stream API has no header scan: sample counts come from the descriptors.
  var d: SegdData
  d.records.add makeRev2(1, sd8058)
  d.hasLabel = true
  d.label = SegdStorageUnitLabel(storageUnitSeqNum: "1", revision: "SD2.1",
    structure: "RECORD", bindingEdition: "B2", creationDate: "07-NOV-2026",
    serialNumber: "T2", recordingEntityName: "CREW")
  let tape = openTapeImageSink(tmp / "r2.tap")
  try: doAssert writeSegd(tape, d).clean
  finally: tape.close()
  var src: RecordSource = openTapeImageSource(tmp / "r2.tap")
  let sink = openTapeImageSink(tmp / "r3.tap")
  let log = try: convertSegdRevision(src, sink, rev(3, 0))
            finally:
              src.close()
              sink.close()
  doAssert log.clean, $log
  doAssert log.has("sample counts come from the descriptors")
  var back: RecordSource = openTapeImageSource(tmp / "r3.tap")
  let r3 = try: readSegd(back) finally: back.close()
  doAssert r3.diagnostics.clean and r3.hasLabel and r3.label.revision == "SD3.0"
  doAssert r3.records[0].traces[4].samples == d.records[0].traces[4].samples

# ------------------------------------------------- synthetic Rev 3 records --

proc makeRev3(format: SegdSampleFormat, vals: openArray[float64]): SegdData =
  ## One Rev 3 record, one seismic set of 2 traces holding `vals`.
  let ns = vals.len
  var r = SegdRecord(isRev3: true, hasGh2: true, format: format, formatKnown: true,
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 5, formatCode: ord(format), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, manufacturerCode: 50,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1)
  r.gh2r3 = SegdGeneralHeader2Rev3(extFileNumber: 5, revisionMajor: 3,
    extRecordLength: uint32(1000 * ns), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
  let seis = SegdChannelSetDescriptor3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, endTime: int32(1000 * (ns - 1)), numSamples: uint32(ns),
    descaleMultiplier: 0.25, channelsInSet: 2, samplingInterval: 1000,
    traceHeaderExtensions: 1, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(descriptors3: @[seis])]
  var traces: seq[SegdTrace]
  for k in 0..1:
    var t = SegdTrace(index: k, numSamples: ns, hasExt1: true)
    t.header = SegdTraceHeader(fileNumber: 5, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: k + 1, traceHeaderExtensions: 1)
    t.ext1r3 = SegdTraceHeaderExt1Rev3(receiverLineNumber: 7, receiverPointNumber: int32(k),
      numSamples: uint32(ns), sensorType: 2, groupIndex: 1, blockType: 0x40)
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSegdSamples(format, vals, t.samples)
    traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = 2
  result.records = @[SegdRecordData(record: r, traces: traces)]

block rev3_8080_to_rev2_and_format_changes:
  # 8080 has no Rev 2 code: 8058 by default, exact for these values.
  toDisk(makeRev3(sd8080, [0.25, -1.5, 3.0, 0.0]), tmp / "f64.sgd")
  var log = convertSegdRevision(tmp / "f64.sgd", tmp / "f64_r2.sgd", rev(2, 1))
  doAssert log.clean, $log
  doAssert log.has("Trace Header Extension #1 fields Rev 2 lacks") # groupIndex
  let d = readSegd(tmp / "f64_r2.sgd")
  doAssert d.diagnostics.clean and d.records[0].record.format == sd8058
  doAssert d.records[0].record.gh1.formatCode == 8058
  doAssert decodeF64(sd8058, d.records[0].traces[1].samples, 4) == @[0.25, -1.5, 3.0, 0.0]
  doAssert d.records[0].record.scanTypes[0].descriptors[0].mpFactor == -2.0 # DSM 0.25
  # A value float32 cannot hold exactly is counted.
  toDisk(makeRev3(sd8080, [0.1, 1.0]), tmp / "f64b.sgd")
  log = convertSegdRevision(tmp / "f64b.sgd", tmp / "f64b_r2.sgd", rev(2, 1))
  doAssert log.has("2 traces could not be re-encoded exactly", sevWarning), $log
  # An explicit format: Rev 3 8058 → 3.0 8038, sizes recomputed.
  toDisk(makeRev3(sd8058, [1.0, -2.0, 300.0, 4.0, 5.0]), tmp / "f32.sgd")
  var o = rev(3, 0)
  o.format = 8038
  log = convertSegdRevision(tmp / "f32.sgd", tmp / "i32.sgd", o)
  doAssert log.clean, $log
  let i32 = readSegd(tmp / "i32.sgd")
  doAssert i32.diagnostics.clean, $i32.diagnostics
  doAssert i32.records[0].record.format == sd8038
  doAssert int64(i32.records[0].record.gh3.recordSize) == getFileSize(tmp / "i32.sgd")
  doAssert decodeF64(sd8038, i32.records[0].traces[0].samples, 5) ==
    @[1.0, -2.0, 300.0, 4.0, 5.0]

block rev31_target_and_little_endian_formats:
  # INOVA 3.0 -> 3.1 in 9058 (little-endian) -> 3.0 (back to 8058).
  let src = exampleDir / "inova_rev30_5traces.sgd"
  var o = rev(3, 1)
  o.format = 9058
  var log = convertSegdRevision(src, tmp / "inova31.sgd", o)
  doAssert not log.isFatal and log.count(sevError) == 0, $log
  let d = readSegd(tmp / "inova31.sgd")
  doAssert d.diagnostics.count(sevWarning) == 0, $d.diagnostics
  let r = d.records[0].record
  doAssert r.revision.major == 3 and r.revision.minor == 1 and r.format == sd9058
  let orig = readSegd(src)
  for i, t in d.records[0].traces:
    let n = t.samples.len div 4
    doAssert decodeF64(sd9058, t.samples, n) ==
      decodeF64(sd8058, orig.records[0].traces[i].samples, n)
  log = convertSegdRevision(tmp / "inova31.sgd", tmp / "inova30.sgd", rev(3, 0))
  doAssert not log.isFatal and log.count(sevError) == 0, $log
  doAssert readFile(tmp / "inova30.sgd") == readFile(src), "3.0 -> 3.1/9058 -> 3.0 is exact"
  block indexed:
    var f = openSeismic(tmp / "inova31.sgd")
    var g = openSeismic(src)
    doAssert f.index.detected and f.len == 5 and f.index.log.len == 0, $f.index.log
    doAssert f.readTraces(0..4) == g.readTraces(0..4)
    f.close()
    g.close()
  # 90xx has no code before 3.1: refused as an explicit target format.
  o = rev(3, 0)
  o.format = 9058
  doAssert convertSegdRevision(src, tmp / "x.sgd", o).isFatal
  # 9058 to Rev 2.1 becomes 8058.
  log = convertSegdRevision(tmp / "inova31.sgd", tmp / "inova21.sgd", rev(2, 1))
  doAssert not log.isFatal and readSegd(tmp / "inova21.sgd").records[0].record.format == sd8058

block records_rev2_cannot_hold_are_skipped:
  # A negative start time (legal in Rev 3) has no Rev 2 encoding.
  var d = makeRev3(sd8058, [1.0, 2.0])
  d.records.add makeRev3(sd8058, [3.0, 4.0]).records[0]
  d.records[0].record.scanTypes[0].descriptors3[0].startTime = -2000
  d.records[0].record.scanTypes[0].descriptors3[0].endTime = -1000 + 1000
  toDisk(d, tmp / "neg.sgd")
  let log = convertSegdRevision(tmp / "neg.sgd", tmp / "neg_r2.sgd", rev(2, 1))
  doAssert log.has("record 0 cannot be written as Rev 2.1", sevError), $log
  doAssert log.count(sevFatal) == 0
  let b = readSegd(tmp / "neg_r2.sgd")
  doAssert b.records.len == 1 and b.diagnostics.clean
  doAssert decodeF64(sd8058, b.records[0].traces[0].samples, 2) == @[3.0, 4.0]
  # More than 9999 channels in a set.
  var many = makeRev3(sd8058, [1.0])
  many.records[0].record.scanTypes[0].descriptors3[0].channelsInSet = 10_000
  let r = many.records[0].record
  var w = SegdConvertOptions(revision: SegdRevision(major: 2, minor: 1))
  let sink = openDiskSink(tmp / "many.sgd")
  try:
    var wr = openSegdWriter(sink, SegdWriteOptions(lenient: true))
    wr.writeRecordHeaders(r)
    wr.endRecord()
    wr.close()
  finally: sink.close()
  let log2 = convertSegdRevision(tmp / "many.sgd", tmp / "many_r2.sgd", w)
  doAssert log2.has("10000 channels; Rev 2 holds 9999", sevError), $log2

block invalid_requests:
  for (ma, mi) in [(1, 0), (3, 2), (2, 5), (4, 0)]:
    let log = convertSegdRevision(exampleDir / "63.sgd", tmp / "x.sgd", rev(ma, mi))
    doAssert log.isFatal and log.has("is not 2.0, 2.1, 3.0 or 3.1", sevFatal)
  var o = rev(2, 1)
  o.format = 8080
  doAssert convertSegdRevision(exampleDir / "63.sgd", tmp / "x.sgd", o).has(
    "8080 is not defined in Rev 2.1", sevFatal)
  o.format = 1234
  doAssert convertSegdRevision(exampleDir / "63.sgd", tmp / "x.sgd", o).isFatal
  copyFile(exampleDir / "63.sgd", tmp / "same.sgd")
  doAssert convertSegdRevision(tmp / "same.sgd", tmp / "same.sgd", rev(3, 0)).has(
    "the output is the input file", sevFatal)
  doAssert readBytes(tmp / "same.sgd") == readBytes(exampleDir / "63.sgd")
  doAssert convertSegdRevision(tmp / "missing.sgd", tmp / "x.sgd", rev(3, 0)).isFatal

block record_length_in_bcd:
  # GH#1 RR.R × 1.024 s, the same in Rev 2 and Rev 3 (was 5× too long for Rev 3).
  let g1 = SegdGeneralHeader1(recordLength: 5)
  doAssert recordLengthUs(g1, SegdGeneralHeader2Rev3()) == 512_000.0
  doAssert recordLengthMs(g1, SegdGeneralHeader2()) == 512.0

# ------------------------------------------- Phase 8 review regressions --

proc decodeAll(path: string): SegdData = readSegd(path)

block review_trailers_within_a_layout:
  # (1) 2.x → 2.y and 3.x → 3.0 kept no trailer (the reader fills it after the traces).
  var d: SegdData
  d.records.add makeRev2(1, sd8058)
  toDisk(d, tmp / "tr21.sgd")
  var log = convertSegdRevision(tmp / "tr21.sgd", tmp / "tr20.sgd", rev(2, 0))
  doAssert log.clean, $log
  let b = decodeAll(tmp / "tr20.sgd")
  doAssert b.diagnostics.clean and b.records[0].record.trailer.len == 2
  doAssert b.records[0].record.trailer[1].encoded == d.records[0].record.trailer[1].encoded
  var r3 = makeRev3(sd8058, [1.0, 2.0, 3.0])
  var td = SegdTrailerDescription(trailerBlockType: 0x10, asciiOrBinary: 2, blockSize: 2,
    blockType: 0x70)
  r3.records[0].record.trailerBytes = @(td.encoded) & newSeq[byte](64)
  r3.records[0].record.trailerBytes[40] = byte('x')
  computeRev3Sizes(r3.records[0].record, r3.records[0].traces)
  toDisk(r3, tmp / "tr3.sgd")
  for fmt in [0, 8038]:
    var o = rev(3, 0)
    o.format = fmt
    log = convertSegdRevision(tmp / "tr3.sgd", tmp / "tr3b.sgd", o)
    doAssert log.clean, $log
    let x = decodeAll(tmp / "tr3b.sgd")
    doAssert x.diagnostics.clean, $x.diagnostics
    doAssert x.records[0].record.trailerBytes == r3.records[0].record.trailerBytes
    doAssert int64(x.records[0].record.gh3.recordSize) == getFileSize(tmp / "tr3b.sgd")

block review_extended_channel_set_numbers:
  # (2) A Rev 2 channel set number > 99 (FF + extended) was written as 0.
  var d: SegdData
  d.records.add makeRev2(1, sd8058)
  d.records[0].record.scanTypes[0].descriptors[1].channelSetNumber = BcdAllF
  d.records[0].record.scanTypes[0].descriptors[1].extChannelSetNumber = 200
  for t in d.records[0].traces.mitems:
    if t.header.channelSetNumber == 2:
      t.header.channelSetNumber = BcdAllF
      t.header.extChannelSetNumber = 200
  toDisk(d, tmp / "cs200.sgd")
  let log = convertSegdRevision(tmp / "cs200.sgd", tmp / "cs200_r3.sgd", rev(3, 0))
  doAssert log.clean, $log
  let x = decodeAll(tmp / "cs200_r3.sgd")
  doAssert x.diagnostics.clean and x.records[0].record.scanTypes[0].descriptors3[1].channelSetNumber == 200
  doAssert convertSegdRevision(tmp / "cs200_r3.sgd", tmp / "cs200_r2.sgd", rev(2, 1)).clean
  doAssert convertSegdRevision(tmp / "cs200_r2.sgd", tmp / "cs200_r3b.sgd", rev(3, 0)).clean

block review_streams_and_odd_descriptors:
  # (3) End before start: the stream API (no scan) raised a RangeDefect.
  var d: SegdData
  d.records.add makeRev2(1, sd8058)
  d.records[0].record.scanTypes[0].descriptors[1].startTime = 60
  d.records[0].record.scanTypes[0].descriptors[1].endTime = 10
  toDisk(d, tmp / "neg2.sgd")
  var src: RecordSource = openDiskSource(tmp / "neg2.sgd")
  let sink = openDiskSink(tmp / "neg2_r3.sgd")
  let log = try: convertSegdRevision(src, sink, rev(3, 0))
            finally:
              src.close()
              sink.close()
  doAssert not log.isFatal, $log
  doAssert log.has("cut or zero-padded", sevWarning)

block review_orphan_traces_skip_their_record:
  # (4) A trace naming no descriptor stopped the whole conversion.
  var d: SegdData
  d.records.add makeRev2(1, sd8058)
  d.records.add makeRev2(2, sd8058)
  d.records[0].traces[4].header.channelSetNumber = 7
  let sink = openDiskSink(tmp / "orph.sgd")
  try: discard writeSegd(sink, d, SegdWriteOptions(lenient: true))
  finally: sink.close()
  let log = convertSegdRevision(tmp / "orph.sgd", tmp / "orph_r3.sgd", rev(3, 0))
  doAssert log.has("record 0 cannot be written", sevError) and not log.isFatal, $log
  let x = decodeAll(tmp / "orph_r3.sgd")
  doAssert x.records.len == 1 and x.records[0].record.gh1.fileNumber == 2

block review_value_edges:
  # (5) Long record lengths wrapped; (8) undefined channel types were silent;
  # (9) 8015 padding copied stale samples; 2.0 → 2.1 kept undefined bytes.
  var d: SegdData
  d.records.add makeRev2(1, sd8015, ns = 49)
  d.records[0].record.gh2.extRecordLength = 5_000_000
  d.records[0].record.scanTypes[0].descriptors[0].channelType = 0xE
  d.records[0].record.scanTypes[0].descriptors[1].endTime = 52 # 52 samples per set
  toDisk(d, tmp / "edge.sgd")
  var src: RecordSource = openDiskSource(tmp / "edge.sgd")
  let sink = openDiskSink(tmp / "edge_r3.sgd")
  let log = try: convertSegdRevision(src, sink, rev(3, 0))
            finally:
              src.close()
              sink.close()
  doAssert log.has("over 4294 s") and log.has("undefined Rev 2 channel types"), $log
  let x = decodeAll(tmp / "edge_r3.sgd")
  doAssert x.records[0].record.gh2r3.extRecordLength == high(uint32)
  let v = decodeF64(sd8015, x.records[0].traces[4].samples, 52)
  doAssert v[49] == 0 and v[50] == 0 and v[51] == 0, $v[48..51]
  var r20 = readBytes(exampleDir / "63.sgd")
  r20[32 + 20] = 0x12 # GH#2 bytes 21-22, undefined in 2.0
  writeBytes(tmp / "u20.sgd", r20)
  doAssert convertSegdRevision(tmp / "u20.sgd", tmp / "u21.sgd", rev(2, 1)).clean
  doAssert decodeAll(tmp / "u21.sgd").records[0].record.gh2.lineSequenceNumber == 0

block review_nan_filters_and_zeroed_traces:
  # (6) A NaN filter aborted Rev 3 → 2; (7) zeroed traces were reported as inexact.
  var r3 = makeRev3(sd8058, [1.0, 2.0])
  r3.records[0].record.scanTypes[0].descriptors3[0].aliasFilterFreq = NaN
  toDisk(r3, tmp / "nanf.sgd")
  var log = convertSegdRevision(tmp / "nanf.sgd", tmp / "nanf_r2.sgd", rev(2, 1))
  doAssert not log.isFatal and log.has("filter frequencies"), $log
  toDisk(makeRev3(sd8058, [1.0, 1e12, 3.0]), tmp / "big.sgd")
  var o = rev(3, 0)
  o.format = 8036
  log = convertSegdRevision(tmp / "big.sgd", tmp / "big36.sgd", o)
  doAssert log.has("written as zeros", sevError), $log

echo "tsegdrevconvert: ok"
