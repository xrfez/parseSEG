## SEG-D Rev 2 reader and writer (tasks 4.3 and 4.4): 63.sgd, synthetic
## multi-record streams in every format, disk and tape images, RECORD and
## FIXREC structures, damaged input.

import std/[assertions, os, strutils]
import parseSEGD/common/errors
import parseSEGD/io/[records, diskio, tapeimage]
import parseSEGD/segd/[reader, writer]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parsesegd_tsegdreader"
createDir(tmp)

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc writeBytes(path: string, b: openArray[byte]) =
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(path, s)

proc toDisk(d: SegdData, path: string, opts = SegdWriteOptions()): DiagLog =
  let sink = openDiskSink(path)
  try: result = writeSegd(sink, d, opts)
  finally: sink.close()

proc toTape(d: SegdData, path: string, opts = SegdWriteOptions()): DiagLog =
  let sink = openTapeImageSink(path)
  try: result = writeSegd(sink, d, opts)
  finally: sink.close()

proc fromTape(path: string): SegdData =
  var src: RecordSource = openTapeImageSource(path)
  try: result = readSegd(src)
  finally: src.close()

proc sameRecords(a, b: SegdData) =
  doAssert a.records.len == b.records.len
  for i in 0..<a.records.len:
    let x = a.records[i]
    let y = b.records[i]
    doAssert x.record.gh1.encoded == y.record.gh1.encoded
    doAssert x.record.gh2.encoded == y.record.gh2.encoded
    doAssert x.traces.len == y.traces.len
    for k in 0..<x.traces.len:
      doAssert x.traces[k].header.encoded == y.traces[k].header.encoded
      doAssert x.traces[k].samples == y.traces[k].samples
    if x.samples.size > 0 and y.samples.size > 0: # in-memory streams have raw bytes only
      doAssert x.samples == y.samples

# --------------------------------------------------------------- 63.sgd --

block sample_63:
  let path = exampleDir / "63.sgd"
  let d = readSegd(path)
  doAssert d.diagnostics.count(sevWarning) == 0 and d.diagnostics.count(sevError) == 0
  doAssert d.diagnostics.count(sevInfo) == 2 # source set 0, array forming 0
  doAssert not d.hasLabel and d.records.len == 1
  let r = d.records[0]
  doAssert r.record.revision == SegdRevision(major: 2, minor: 0)
  doAssert r.record.format == sd8058 and r.record.traceCount == 1
  doAssert r.record.sourceHeaders.len == 1 and r.record.sourceHeaders[0].sourcePointNumber == 99.5
  doAssert r.record.extended.len == 96 and r.record.external.len == 0
  doAssert r.traces.len == 1 and r.traces[0].numSamples == 1000
  doAssert r.traces[0].hasExt1 and r.traces[0].extensions.len == 64
  doAssert r.traces[0].ext1.sensorType == 2 and r.traces[0].offset == 224
  doAssert abs(r.samples[0, 0] - 0.1001'f32) < 1e-4
  # Task 4.4: a byte-identical read -> write round trip, on disk and tape.
  doAssert d.toDisk(tmp / "63.sgd").len == 0
  doAssert readBytes(tmp / "63.sgd") == readBytes(path)
  discard d.toTape(tmp / "63.tap")
  let e = fromTape(tmp / "63.tap")
  sameRecords(d, e)
  doAssert e.diagnostics.count(sevWarning) == 0

# ---------------------------------------------------- synthetic records --

proc makeRecord(fileNo: int, format: SegdSampleFormat, ns = 52): SegdRecordData =
  ## One record: GH1, GH2, GH3; one scan type with an aux channel set (2
  ## traces, no extensions: sized from the descriptor) and a seismic set (3
  ## traces, Ext1 plus one more extension); 1 skew block, 1 extended block,
  ## 1 general trailer block.
  var r = SegdRecord(format: format, formatKnown: true, hasGh2: true,
    revision: SegdRevision(major: 2, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(format), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, minute: 30, second: 5,
    manufacturerCode: 9, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 2, skewBlocks: 1, extendedHeaderBlocks: 1,
    externalHeaderBlocks: 0)
  r.gh2 = SegdGeneralHeader2(extFileNumber: uint32(fileNo), revisionMajor: 2,
    generalTrailerBlocks: 1, extRecordLength: uint32(2 * ns), blockNumber: 2)
  r.sourceHeaders = @[SegdGeneralHeaderN(sourceLineNumber: 1001.5, sourcePointNumber: -12.25,
    sourcePointIndex: 1, blockNumber: 3, sourceSetNumber: 1)]
  var aux = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 0,
    endTime: uint16(ns), channelCount: 2, channelType: 9, gainControl: 3,
    traceHeaderExtensions: 0, verticalStack: 1, arrayForming: 1)
  aux.mpFactor = -2.5
  let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 2, startTime: 0,
    endTime: uint16(ns), channelCount: 3, channelType: 1, gainControl: 3,
    aliasFilterFreq: 200, aliasFilterSlope: 370, lowCutFreq: 3, lowCutSlope: 18,
    traceHeaderExtensions: 2, verticalStack: 1, arrayForming: 1)
  var skew = newSeq[byte](32)
  for i in 0..<skew.len: skew[i] = byte(i)
  r.scanTypes = @[SegdScanType(descriptors: @[aux, seis], skew: skew)]
  r.extended = newSeq[byte](32)
  for i in 0..<32: r.extended[i] = byte(200 + i mod 50)
  r.trailer = @[SegdTrailerBlock(trailerNumber: 1, channelType: 0xC)]
  r.traceCount = 5
  result.record = r
  for k in 0..<5:
    let isAux = k < 2
    var t = SegdTrace(index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: fileNo, scanTypeNumber: 1,
      channelSetNumber: (if isAux: 1 else: 2), traceNumber: (if isAux: k + 1 else: k - 1),
      traceHeaderExtensions: (if isAux: 0'u8 else: 2'u8), firstTimingWord: 0.0)
    if not isAux:
      t.hasExt1 = true
      t.ext1 = SegdTraceHeaderExt1(receiverLineNumber: 2000, receiverPointNumber: int32(100 + k),
        receiverPointIndex: 1, samplesPerTrace: uint32(ns), sensorType: 2)
      t.extensions = newSeq[byte](32)
      t.extensions[0] = byte(k)
    var vals = newSeq[float64](ns)
    for i in 0..<ns: vals[i] = float64((i mod 9) - 4) * (if format in {sd8036, sd8038}: 1000.0 else: 0.125)
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSegdSamples(format, vals, t.samples)
    result.traces.add t

proc makeStream(formats: openArray[SegdSampleFormat]): SegdData =
  for i, f in formats: result.records.add makeRecord(100 + i, f)

block synthetic_records_every_format_on_disk:
  let d = makeStream(segdSampleFormats)
  let path = tmp / "multi.sgd"
  doAssert d.toDisk(path).len == 0
  let e = readSegd(path)
  doAssert e.diagnostics.len == 0, $e.diagnostics[0]
  doAssert e.records.len == segdSampleFormats.len
  for i, rd in e.records:
    doAssert rd.record.format == segdSampleFormats[i] and rd.traces.len == 5
    doAssert rd.record.trailer.len == 1 and rd.record.extended == d.records[i].record.extended
    doAssert rd.record.scanTypes[0].skew == d.records[i].record.scanTypes[0].skew
    doAssert rd.record.scanTypes[0].descriptors[0].mpFactor == -2.5
    doAssert rd.record.sourceHeaders[0].sourcePointNumber == -12.25
    doAssert rd.traces[0].numSamples == 52 and not rd.traces[0].hasExt1 # sized from the CSD
    doAssert rd.traces[4].ext1.receiverPointNumber == 104 and rd.traces[4].extensions[0] == 4
    doAssert rd.samples[3, 0] == float32(-4 * (if rd.record.format in {sd8036, sd8038}: 1000 else: 1)) /
      (if rd.record.format in {sd8036, sd8038}: 1'f32 else: 8'f32)

  # Rewriting what was read is byte-identical.
  doAssert e.toDisk(tmp / "multi2.sgd").len == 0
  doAssert readBytes(tmp / "multi2.sgd") == readBytes(path)

block tape_record_structure_with_label_and_marks:
  var d = makeStream([sd8058, sd8036, sd8015])
  let text = align("1", 4) & "SD2.0" & "RECORD" & alignLeft("B1", 4) & align("0", 10) &
    align("163", 10) & "07-NOV-2026" & align("TAPE01", 12) & spaces(6) & spaces(12) &
    alignLeft("CREW 7", 24) & spaces(14) & align("10", 10)
  var raw = newSeq[byte](128)
  for i, c in text: raw[i] = byte(c)
  d.label = decodeLabel(raw)
  d.hasLabel = true
  let tap = tmp / "record.tap"
  discard d.toTape(tap, SegdWriteOptions(tapeMarkPerRecord: true))
  # Label, then per record: headers, 5 traces, trailer, tape mark.
  var src: RecordSource = openTapeImageSource(tap)
  var buf: seq[byte]
  var kinds: seq[RecordKind]
  var k = src.readRecord(buf)
  while k != rkEndOfData:
    kinds.add k
    k = src.readRecord(buf)
  src.close()
  doAssert kinds.len == 1 + 3 * (1 + 5 + 1 + 1)
  let e = fromTape(tap)
  doAssert e.diagnostics.len == 0, $e.diagnostics[0]
  doAssert e.hasLabel and e.label.revision == "SD2.0" and e.records.len == 3
  sameRecords(d, e)
  # The same stream on disk (label first) reads the same.
  discard d.toDisk(tmp / "labelled.sgd")
  let f = readSegd(tmp / "labelled.sgd")
  doAssert f.hasLabel and f.records.len == 3 and f.diagnostics.len == 0
  sameRecords(d, f)

block fixrec_padding_on_tape_and_disk:
  var d = makeStream([sd8058, sd8024])
  let text = align("1", 4) & "SD2.0" & "FIXREC" & alignLeft("B1", 4) & align("4096", 10) &
    align("163", 10) & "07-NOV-2026" & align("TAPE02", 12) & spaces(6) & spaces(12) &
    alignLeft("CREW 7", 24) & spaces(14) & align("10", 10)
  var raw = newSeq[byte](128)
  for i, c in text: raw[i] = byte(c)
  d.label = decodeLabel(raw)
  d.hasLabel = true
  doAssert d.label.isFixedRecord and d.label.maxBlockSize == 4096
  let tap = tmp / "fixrec.tap"
  discard d.toTape(tap)
  var src: RecordSource = openTapeImageSource(tap)
  var buf: seq[byte]
  while src.readRecord(buf) == rkData: doAssert buf.len == 4096
  src.close()
  let e = fromTape(tap)
  doAssert e.diagnostics.len == 0 and e.records.len == 2
  sameRecords(d, e)
  let disk = tmp / "fixrec.sgd"
  discard d.toDisk(disk)
  doAssert readBytes(disk).len mod 4096 == 0
  let f = readSegd(disk)
  doAssert f.diagnostics.len == 0 and f.records.len == 2
  sameRecords(d, f)

block writer_refusals:
  var d = makeStream([sd8058])
  d.records[0].traces.setLen 4
  doAssertRaises SegFormatError: discard d.toDisk(tmp / "short.sgd")
  doAssert d.toDisk(tmp / "short.sgd", SegdWriteOptions(lenient: true)).count(sevWarning) == 1
  var e = makeStream([sd8058])
  e.records[0].traces[3].extensions.setLen 0 # header still says 2 extensions
  doAssertRaises SegFormatError: discard e.toDisk(tmp / "the.sgd")
  var f = makeStream([sd8058])
  f.records[0].traces[4].numSamples = 40
  doAssertRaises SegFormatError: discard f.toDisk(tmp / "ns.sgd")
  var g = makeStream([sd8058])
  g.records[0].record.gh1.formatCode = 8036
  doAssertRaises SegFormatError: discard g.toDisk(tmp / "fmt.sgd")
  var h = makeStream([sd8058])
  h.records[0].record.extended.setLen 40
  doAssertRaises SegFormatError: discard h.toDisk(tmp / "ec.sgd")

block damaged_input:
  let d = makeStream([sd8058, sd8058])
  let path = tmp / "two.sgd"
  discard d.toDisk(path)
  let full = readBytes(path)
  # Cut inside the second record's third trace.
  let recBytes = full.len div 2
  writeBytes(tmp / "cut.sgd", full[0 ..< recBytes + 640])
  let e = readSegd(tmp / "cut.sgd")
  doAssert e.diagnostics.isFatal and e.records.len == 2
  doAssert e.records[0].traces.len == 5 and e.records[1].traces.len < 5
  let fatal = e.diagnostics[e.diagnostics.len - 1]
  doAssert fatal.code == dcTruncated and fatal.loc.record == 1
  # A Rev 3 record and a multiplexed format stop the read with a fatal entry.
  var rev3 = readBytes(exampleDir / "63.sgd")
  rev3[42] = 3
  writeBytes(tmp / "rev3.sgd", rev3)
  let r3 = readSegd(tmp / "rev3.sgd") # a Rev 2 record that claims Rev 3
  doAssert r3.diagnostics.count(sevWarning) + r3.diagnostics.count(sevFatal) > 0
  var mux = readBytes(exampleDir / "63.sgd")
  mux[2] = 0x00 # format 0058
  writeBytes(tmp / "mux.sgd", mux)
  let m = readSegd(tmp / "mux.sgd")
  doAssert m.diagnostics.isFatal and "multiplexed" in m.diagnostics[m.diagnostics.len - 1].msg

# ------------------------------------------- Phase 4 review regressions --
# Numbered as in the review.

block r3_corrupt_counts_are_bounded:
  var b = readBytes(exampleDir / "63.sgd")
  b[27] = 0x99 # 99 scan types
  b[28] = 0xFF # channel sets in GH#2 ...
  b[35] = 0xFF; b[36] = 0xFF # ... = 65535
  writeBytes(tmp / "manycsd.sgd", b)
  let d = readSegd(tmp / "manycsd.sgd")
  doAssert d.diagnostics.isFatal and d.records.len == 0
  doAssert d.diagnostics.len <= 3

block r3_repeated_diagnostics_are_summarized:
  var d = makeStream([sd8058])
  # Every seismic trace disagrees with its descriptor's extension count.
  d.records[0].record.scanTypes[0].descriptors[1].traceHeaderExtensions = 3
  d.records[0].record.scanTypes[0].descriptors[1].channelCount = 40
  for k in 5..<42:
    var t = d.records[0].traces[4]
    t.index = k
    d.records[0].traces.add t
  discard d.toDisk(tmp / "noisy.sgd", SegdWriteOptions(lenient: true))
  let e = readSegd(tmp / "noisy.sgd")
  doAssert e.records[0].traces.len == 42
  var mismatch, summary = 0
  for x in e.diagnostics:
    if x.loc.field == "trace.traceHeaderExtensions" and x.severity == sevWarning: inc mismatch
    if "more warning diagnostics" in x.msg: inc summary
  doAssert mismatch == 5 and summary == 1

block r4_r5_labels_from_fields_and_fixrec_bounds:
  var d = makeStream([sd8058])
  d.hasLabel = true
  d.label = SegdStorageUnitLabel(storageUnitSeqNum: "1", revision: "SD2.0", structure: "RECORD",
    bindingEdition: "B1", producerOrgCode: "163", creationDate: "07-NOV-2026",
    serialNumber: "T1", recordingEntityName: "CREW")
  discard d.toDisk(tmp / "fieldlabel.sgd")
  let e = readSegd(tmp / "fieldlabel.sgd")
  doAssert e.hasLabel and e.label.recordingEntityName == "CREW" and e.records.len == 1
  # Edited to FIXREC: the label written says FIXREC too.
  var f = e
  f.label.structure = "FIXREC"
  f.label.maxBlockSize = 1024
  discard f.toDisk(tmp / "fieldfixrec.sgd")
  let g = readSegd(tmp / "fieldfixrec.sgd")
  doAssert g.label.isFixedRecord and g.records.len == 1 and g.diagnostics.len == 0
  doAssert readBytes(tmp / "fieldfixrec.sgd").len mod 1024 == 0
  for bad in [100'i64, 9_999_999_999]:
    var h = f
    h.label.maxBlockSize = bad
    doAssertRaises SegFormatError: discard h.toDisk(tmp / "badblock.sgd")
  var n = f
  n.label.revision = "XX2.0"
  doAssertRaises SegFormatError: discard n.toDisk(tmp / "badrev.sgd")

block r6_r11_writer_recomputes_from_headers:
  var d = makeStream([sd8058])
  d.records[0].record.scanTypes[0].descriptors[1].channelCount = 4 # 5 traces written, 6 announced
  doAssertRaises SegFormatError: discard d.toDisk(tmp / "count.sgd")
  var e = makeStream([sd8058])
  e.records[0].record.gh2.revisionMajor = 3
  doAssertRaises SegFormatError: discard e.toDisk(tmp / "rev3w.sgd")
  var f = makeStream([sd8058])
  for i, c in "SD2.0": f.records[0].record.gh1.generalConstants[i] = byte(c) # bytes 5-9
  doAssertRaises SegFormatError: discard f.toDisk(tmp / "lookslabel.sgd")

block r9_negative_sample_count_is_fatal:
  var d = makeStream([sd8058])
  d.records[0].record.scanTypes[0].descriptors[0].startTime = 100 # after endTime 52
  discard d.toDisk(tmp / "negns.sgd", SegdWriteOptions(lenient: true))
  let e = readSegd(tmp / "negns.sgd")
  doAssert e.diagnostics.isFatal and e.records[0].traces.len == 0

block r12_refused_bcd_leaves_the_buffer_untouched:
  var g1 = decodeBlock[SegdGeneralHeader1](readBytes(exampleDir / "63.sgd")[0..31])
  g1.fileNumber = 12345
  var b: array[32, byte]
  for i in 0..31: b[i] = 0xAA
  doAssertRaises SegFormatError: g1.encode(b)
  doAssert b[0] == g1.raw[0] and b[1] == g1.raw[1] # raw copied, field not partly written

block fixrec_traces_do_not_cross_blocks:
  # Owner decision: in FIXREC, a trace that fits in a block starts a new block
  # rather than crossing a boundary (zero padding in between).
  var d = makeStream([sd8058, sd8058])
  let text = align("1", 4) & "SD2.0" & "FIXREC" & alignLeft("B1", 4) & align("1000", 10) &
    align("163", 10) & "07-NOV-2026" & align("TAPE03", 12) & spaces(6) & spaces(12) &
    alignLeft("CREW 7", 24) & spaces(14) & align("10", 10)
  var raw = newSeq[byte](128)
  for i, c in text: raw[i] = byte(c)
  d.label = decodeLabel(raw)
  d.hasLabel = true
  let traceBytes = 20 + 64 + 52 * 4 # a seismic trace: 292 bytes
  for path in [tmp / "nocross.tap", tmp / "nocross.sgd"]:
    if path.endsWith(".tap"): discard d.toTape(path) else: discard d.toDisk(path)
    let e = if path.endsWith(".tap"): fromTape(path) else: readSegd(path)
    doAssert e.diagnostics.len == 0, $e.diagnostics[0]
    doAssert e.records.len == 2
    sameRecords(d, e)
    if path.endsWith(".sgd"):
      for rd in e.records:
        for t in rd.traces:
          let startInBlock = t.offset mod 1000
          doAssert startInBlock + (20 + 32 * int(t.header.traceHeaderExtensions) +
            4 * t.numSamples) <= 1000, "trace " & $t.index & " crosses a block"
  doAssert traceBytes < 1000

block rev2_fixrec_every_gap_size:
  # Phase 5 review: gaps of 1..19 bytes before a trace (block sizes 290..380).
  for bs in 290'i64 .. 380:
    var d = makeStream([sd8058])
    let text = align("1", 4) & "SD2.0" & "FIXREC" & alignLeft("B1", 4) & align($bs, 10) &
      align("163", 10) & "07-NOV-2026" & align("T", 12) & spaces(6) & spaces(12) &
      alignLeft("C", 24) & spaces(14) & align("1", 10)
    var raw = newSeq[byte](128)
    for i, c in text: raw[i] = byte(c)
    d.label = decodeLabel(raw)
    d.hasLabel = true
    for (path, tape) in [(tmp / "gap2.sgd", false), (tmp / "gap2.tap", true)]:
      if tape: discard d.toTape(path) else: discard d.toDisk(path)
      let e = if tape: fromTape(path) else: readSegd(path)
      doAssert e.diagnostics.len == 0, "block " & $bs & ": " & $e.diagnostics[0]
      sameRecords(d, e)
