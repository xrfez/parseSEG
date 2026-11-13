## SEG-D Rev 2 reader and writer (tasks 4.3 and 4.4): 63.sgd, synthetic
## multi-record streams in every format, disk and tape images, RECORD and
## FIXREC structures, damaged input.

import std/[assertions, math, os, strutils, times]
import parseSEG/common/errors
import parseSEG/io/[records, diskio, tapeimage]
import parseSEG/segd/[reader, writer]
import ./utils/testutils

let tmp = scratchDir("parseseg_tsegdreader")

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
    doAssert x.record.gh2.get.encoded == y.record.gh2.get.encoded
    doAssert x.traces.len == y.traces.len
    for k in 0..<x.traces.len:
      doAssert x.traces[k].header.encoded == y.traces[k].header.encoded
      doAssert x.traces[k].samples == y.traces[k].samples
    if x.samples.size > 0 and y.samples.size > 0: # in-memory streams have raw bytes only
      doAssert x.samples == y.samples

# --------------------------------------------------------------- 63.sgd --

sampleBlock sample_63:
  let path = exampleDir / "63.sgd"
  let d = readSegd(path)
  doAssert d.log.count(sevWarning) == 0 and d.log.count(sevError) == 0
  doAssert d.log.count(sevInfo) == 2 # source set 0, array forming 0
  doAssert d.label.isNone and d.records.len == 1
  let r = d.records[0]
  doAssert r.record.revision == SegdRevision(major: 2, minor: 0)
  doAssert r.record.format == some(sd8058) and r.record.traceCount == 1
  doAssert r.record.sourceHeaders.len == 1 and r.record.sourceHeaders[0].sourcePointNumber == 99.5
  doAssert r.record.extended.len == 96 and r.record.external.len == 0
  doAssert r.traces.len == 1 and r.traces[0].numSamples == 1000
  doAssert r.traces[0].ext1.isSome and r.traces[0].extensions.len == 64
  doAssert r.traces[0].ext1.get.sensorType == 2 and r.traces[0].offset == 224
  doAssert abs(r.samples[0, 0] - 0.1001'f32) < 1e-4
  # Task 4.4: a byte-identical read -> write round trip, on disk and tape.
  doAssert d.toDisk(tmp / "63.sgd").len == 0
  doAssert readBytes(tmp / "63.sgd") == readBytes(path)
  discard d.toTape(tmp / "63.tap")
  let e = fromTape(tmp / "63.tap")
  sameRecords(d, e)
  doAssert e.log.count(sevWarning) == 0

# ---------------------------------------------------- synthetic records --

proc makeRecord(fileNo: int, format: SegdSampleFormat, ns = 52): SegdRecordData =
  ## One record: GH1, GH2, GH3; one scan type with an aux channel set (2
  ## traces, no extensions: sized from the descriptor) and a seismic set (3
  ## traces, Ext1 plus one more extension); 1 skew block, 1 extended block,
  ## 1 general trailer block.
  var r = SegdRecord(layout: slRev2, format: some(format),
    revision: SegdRevision(major: 2, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(format), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, minute: 30, second: 5,
    manufacturerCode: 9, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 2, skewBlocks: 1, extendedHeaderBlocks: 1,
    externalHeaderBlocks: 0)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: uint32(fileNo), revisionMajor: 2,
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
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[aux, seis], skew: skew)]
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
      t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000,
        receiverPointNumber: int32(100 + k),
        receiverPointIndex: 1, samplesPerTrace: uint32(ns), sensorType: 2)
      t.extensions = newSeq[byte](32)
      t.extensions[0] = byte(k)
    var vals = newSeq[float64](ns)
    for i in 0..<ns: vals[i] = float64((i mod 9) - 4) * (if format in {sd8036, sd8038, sd9036, sd9038}: 1000.0 else: 0.125)
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSamples(format, vals, t.samples)
    result.traces.add t

proc makeStream(formats: openArray[SegdSampleFormat]): SegdData =
  for i, f in formats: result.records.add makeRecord(100 + i, f)

block synthetic_records_every_format_on_disk:
  var rev2Formats: seq[SegdSampleFormat]
  for f in segdSampleFormats:
    if not f.isLittleEndian: rev2Formats.add f
  let d = makeStream(rev2Formats)
  let path = tmp / "multi.sgd"
  doAssert d.toDisk(path).len == 0
  let e = readSegd(path)
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.records.len == rev2Formats.len
  for i, rd in e.records:
    doAssert rd.record.format == some(rev2Formats[i]) and rd.traces.len == 5
    doAssert rd.record.trailer.len == 1 and rd.record.extended == d.records[i].record.extended
    doAssert rd.record.scanTypes[0].skew == d.records[i].record.scanTypes[0].skew
    doAssert rd.record.scanTypes[0].descriptors[0].mpFactor == -2.5
    doAssert rd.record.sourceHeaders[0].sourcePointNumber == -12.25
    doAssert rd.traces[0].numSamples == 52 and rd.traces[0].ext1.isNone # sized from the CSD
    doAssert rd.traces[4].ext1.get.receiverPointNumber == 104 and rd.traces[4].extensions[0] == 4
    doAssert rd.samples[3, 0] == float32(-4 * (if rd.record.format.get in {sd8036, sd8038, sd9036, sd9038}: 1000 else: 1)) /
      (if rd.record.format.get in {sd8036, sd8038, sd9036, sd9038}: 1'f32 else: 8'f32)

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
  d.label = some(decodeLabel(raw))
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
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.label.isSome and e.label.get.revision == "SD2.0" and e.records.len == 3
  sameRecords(d, e)
  # The same stream on disk (label first) reads the same.
  discard d.toDisk(tmp / "labelled.sgd")
  let f = readSegd(tmp / "labelled.sgd")
  doAssert f.label.isSome and f.records.len == 3 and f.log.len == 0
  sameRecords(d, f)

block fixrec_padding_on_tape_and_disk:
  var d = makeStream([sd8058, sd8024])
  let text = align("1", 4) & "SD2.0" & "FIXREC" & alignLeft("B1", 4) & align("4096", 10) &
    align("163", 10) & "07-NOV-2026" & align("TAPE02", 12) & spaces(6) & spaces(12) &
    alignLeft("CREW 7", 24) & spaces(14) & align("10", 10)
  var raw = newSeq[byte](128)
  for i, c in text: raw[i] = byte(c)
  d.label = some(decodeLabel(raw))
  doAssert d.label.get.isFixedRecord and d.label.get.maxBlockSize == 4096
  let tap = tmp / "fixrec.tap"
  discard d.toTape(tap)
  var src: RecordSource = openTapeImageSource(tap)
  var buf: seq[byte]
  while src.readRecord(buf) == rkData: doAssert buf.len == 4096
  src.close()
  let e = fromTape(tap)
  doAssert e.log.len == 0 and e.records.len == 2
  sameRecords(d, e)
  let disk = tmp / "fixrec.sgd"
  discard d.toDisk(disk)
  doAssert readBytes(disk).len mod 4096 == 0
  let f = readSegd(disk)
  doAssert f.log.len == 0 and f.records.len == 2
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

sampleBlock damaged_input:
  let d = makeStream([sd8058, sd8058])
  let path = tmp / "two.sgd"
  discard d.toDisk(path)
  let full = readBytes(path)
  # Cut inside the second record's third trace.
  let recBytes = full.len div 2
  writeBytes(tmp / "cut.sgd", full[0 ..< recBytes + 640])
  let e = readSegd(tmp / "cut.sgd")
  doAssert e.log.isFatal and e.records.len == 2
  doAssert e.records[0].traces.len == 5 and e.records[1].traces.len < 5
  let fatal = e.log[e.log.len - 1]
  doAssert fatal.code == dcTruncated and fatal.loc.record == 1
  # A Rev 3 record and a multiplexed format stop the read with a fatal entry.
  var rev3 = readBytes(exampleDir / "63.sgd")
  rev3[42] = 3
  writeBytes(tmp / "rev3.sgd", rev3)
  let r3 = readSegd(tmp / "rev3.sgd") # a Rev 2 record that claims Rev 3
  doAssert r3.log.count(sevWarning) + r3.log.count(sevFatal) > 0
  var mux = readBytes(exampleDir / "63.sgd")
  mux[2] = 0x00 # format 0058
  writeBytes(tmp / "mux.sgd", mux)
  let m = readSegd(tmp / "mux.sgd")
  doAssert m.log.isFatal and "multiplexed" in m.log[m.log.len - 1].msg

# ------------------------------------------- Phase 4 review regressions --
# Numbered as in the review.

sampleBlock r3_corrupt_counts_are_bounded:
  var b = readBytes(exampleDir / "63.sgd")
  b[27] = 0x99 # 99 scan types
  b[28] = 0xFF # channel sets in GH#2 ...
  b[35] = 0xFF; b[36] = 0xFF # ... = 65535
  writeBytes(tmp / "manycsd.sgd", b)
  let d = readSegd(tmp / "manycsd.sgd")
  doAssert d.log.isFatal and d.records.len == 0
  doAssert d.log.len <= 3

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
  for x in e.log:
    if x.loc.field == "trace.traceHeaderExtensions" and x.severity == sevWarning: inc mismatch
    if "more warning diagnostics" in x.msg: inc summary
  doAssert mismatch == 5 and summary == 1

block r4_r5_labels_from_fields_and_fixrec_bounds:
  var d = makeStream([sd8058])
  d.label = some SegdStorageUnitLabel(storageUnitSeqNum: "1", revision: "SD2.0",
    structure: "RECORD",
    bindingEdition: "B1", producerOrgCode: "163", creationDate: "07-NOV-2026",
    serialNumber: "T1", recordingEntityName: "CREW")
  discard d.toDisk(tmp / "fieldlabel.sgd")
  let e = readSegd(tmp / "fieldlabel.sgd")
  doAssert e.label.isSome and e.label.get.recordingEntityName == "CREW" and e.records.len == 1
  # Edited to FIXREC: the label written says FIXREC too.
  var f = e
  f.label.get.structure = "FIXREC"
  f.label.get.maxBlockSize = 1024
  discard f.toDisk(tmp / "fieldfixrec.sgd")
  let g = readSegd(tmp / "fieldfixrec.sgd")
  doAssert g.label.get.isFixedRecord and g.records.len == 1 and g.log.len == 0
  doAssert readBytes(tmp / "fieldfixrec.sgd").len mod 1024 == 0
  for bad in [100'i64, 9_999_999_999]:
    var h = f
    h.label.get.maxBlockSize = bad
    doAssertRaises SegFormatError: discard h.toDisk(tmp / "badblock.sgd")
  var n = f
  n.label.get.revision = "XX2.0"
  doAssertRaises SegFormatError: discard n.toDisk(tmp / "badrev.sgd")

block r6_r11_writer_recomputes_from_headers:
  var d = makeStream([sd8058])
  d.records[0].record.scanTypes[0].descriptors[1].channelCount = 4 # 5 traces written, 6 announced
  doAssertRaises SegFormatError: discard d.toDisk(tmp / "count.sgd")
  var e = makeStream([sd8058])
  e.records[0].record.gh2.get.revisionMajor = 3
  doAssertRaises SegFormatError: discard e.toDisk(tmp / "rev3w.sgd")
  var f = makeStream([sd8058])
  for i, c in "SD2.0": f.records[0].record.gh1.generalConstants[i] = byte(c) # bytes 5-9
  doAssertRaises SegFormatError: discard f.toDisk(tmp / "lookslabel.sgd")

block r9_negative_sample_count_is_fatal:
  var d = makeStream([sd8058])
  d.records[0].record.scanTypes[0].descriptors[0].startTime = 100 # after endTime 52
  discard d.toDisk(tmp / "negns.sgd", SegdWriteOptions(lenient: true))
  let e = readSegd(tmp / "negns.sgd")
  doAssert e.log.isFatal and e.records[0].traces.len == 0

sampleBlock r12_refused_bcd_leaves_the_buffer_untouched:
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
  d.label = some(decodeLabel(raw))
  let traceBytes = 20 + 64 + 52 * 4 # a seismic trace: 292 bytes
  for path in [tmp / "nocross.tap", tmp / "nocross.sgd"]:
    if path.endsWith(".tap"): discard d.toTape(path) else: discard d.toDisk(path)
    let e = if path.endsWith(".tap"): fromTape(path) else: readSegd(path)
    doAssert e.log.len == 0, $e.log[0]
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
    d.label = some(decodeLabel(raw))
    for (path, tape) in [(tmp / "gap2.sgd", false), (tmp / "gap2.tap", true)]:
      if tape: discard d.toTape(path) else: discard d.toDisk(path)
      let e = if tape: fromTape(path) else: readSegd(path)
      doAssert e.log.len == 0, "block " & $bs & ": " & $e.log[0]
      sameRecords(d, e)

sampleBlock layout_variants_12_3:
  # 12.3 C6: the record, its scan types and traces carry the Rev 0-2 layout,
  # `format` and `ext1` are Options, and the accessors resolve per layout.
  let d = readSegd(exampleDir / "63.sgd")
  template rec: untyped = d.records[0].record
  doAssert rec.layout == slRev2 and not rec.isRev3 and rec.gh2.isSome
  doAssert rec.scanTypes[0].layout == slRev2 and rec.scanTypes[0].channelSetCount == 1
  doAssert rec.fileNumber == rec.gh1.fileNumber and rec.headerBytes == 7 * 32 # GH#1-3, one CSD, 3 extended blocks
  let t = d.records[0].traces[0]
  doAssert t.layout == slRev2 and t.ext1.isSome
  let cs = rec.findChannelSet(t.header)
  doAssert cs == some(SegdChannelSetRef(scanType: 0, channelSet: 0))
  doAssert rec.sampleIntervalUs(t) == rec.sampleIntervalUs(0, 0)
  doAssert rec.channelType(t) == rec.channelType(0, 0)
  # A Rev 2 record's extended header obeys maxHeaderBytes too (it is skipped,
  # and the record cannot be rewritten).
  var src: RecordSource = openDiskSource(exampleDir / "63.sgd")
  try:
    var r = openSegd(src)
    r.maxHeaderBytes = 40
    doAssert r.nextRecord() and r.record.incomplete and r.record.extended.len == 0
    var tr: SegdTrace
    doAssert r.readTrace(tr) and tr.numSamples == t.numSamples
  finally: src.close()
  # The writer refuses a trace of the other layout.
  let sink = openDiskSink(tmp / "layout.sgd")
  try:
    var w = openSegdWriter(sink)
    w.writeRecordHeaders(rec)
    doAssertRaises SegFormatError:
      w.writeTrace(SegdTrace(layout: slRev3, header: t.header, numSamples: t.numSamples))
    doAssert w.log.len == 1 and "layout" in w.log[0].msg
  finally: sink.close()

sampleBlock review_12_4:
  let d = readSegd(exampleDir / "63.sgd")
  let t = d.records[0].traces[0]
  # A lenient write of a record without a known format logs the trace's
  # samples as unchecked instead of failing.
  block:
    var rec = d.records[0].record
    rec.format = none(SegdSampleFormat)
    let sink = openDiskSink(tmp / "nofmt.sgd")
    try:
      var w = openSegdWriter(sink, SegdWriteOptions(lenient: true))
      w.writeRecordHeaders(rec)
      w.writeTrace(t)
      var found = false
      for x in w.log:
        if "cannot be checked" in x.msg: found = true
      doAssert found, $w.log
    finally: sink.close()
  # A lenient record whose scan type has the other layout: the trace's
  # declared sample count is unknown (-1), not a FieldDefect.
  block:
    var rec = d.records[0].record
    rec.scanTypes[0] = SegdScanType(layout: slRev3, descriptorsRev3:
      @[SegdChannelSetDescriptorRev3(channelSetNumber: uint16(channelSetNumber(t.header)))])
    var t2 = t
    t2.ext1 = none(SegdTraceHeaderExt1)
    let sink = openDiskSink(tmp / "mixed.sgd")
    try:
      var w = openSegdWriter(sink, SegdWriteOptions(lenient: true))
      w.writeRecordHeaders(rec)
      w.writeTrace(t2)
      var found = false
      for x in w.log:
        if "give -1 samples" in x.msg: found = true
      doAssert found, $w.log
    finally: sink.close()
  # computeRev3Sizes needs a Rev 3 record.
  block:
    var rec = d.records[0].record
    doAssertRaises(ValueError): rec.computeRev3Sizes([t])
  # A failed GH#1 read leaves no stale record behind.
  block:
    var b = readBytes(exampleDir / "63.sgd")
    b.add [1'u8, 2, 3]
    writeBytes(tmp / "tail3.sgd", b)
    var src: RecordSource = openDiskSource(tmp / "tail3.sgd")
    try:
      var r = openSegd(src)
      doAssert r.nextRecord() and r.record.scanTypes.len == 1
      doAssert not r.nextRecord()
      doAssert r.record.index == 1 and r.record.scanTypes.len == 0
    finally: src.close()
  # A Rev 2 external header obeys maxHeaderBytes like the extended one.
  block:
    var e = d
    template rec: untyped = e.records[0].record
    rec.gh1.externalHeaderBlocks = 2
    rec.external = newSeq[byte](64)
    for i in 0 ..< 64: rec.external[i] = byte(i)
    let log = e.toDisk(tmp / "ext2.sgd")
    doAssert log.len == 0, $log
    doAssert readSegd(tmp / "ext2.sgd").records[0].record.external == rec.external
    var src: RecordSource = openDiskSource(tmp / "ext2.sgd")
    try:
      var r = openSegd(src)
      r.maxHeaderBytes = 63 # the extended header (96 bytes) and the external (64)
      doAssert r.nextRecord() and r.record.incomplete
      doAssert r.record.external.len == 0 and r.record.extended.len == 0
      var notes = 0
      for x in r.log:
        if "exceed the in-memory limit" in x.msg: inc notes
      doAssert notes == 2, $r.log
      r.maxHeaderBytes = 64
      var tr: SegdTrace
      doAssert r.readTrace(tr)
    finally: src.close()

sampleBlock channel_set_hint_matches_the_search:
  # The reader tries the previous trace's channel set first (15.3-8); every
  # trace must still get the descriptor the plain search finds.
  for name in ["63.sgd", "00000151_12900_11300.sgd", "inova_rev30_5traces.sgd"]:
    var src: RecordSource = openDiskSource(exampleDir / name)
    try:
      var r = openSegd(src, headersOnly = true)
      var traces = 0
      while r.nextRecord():
        var t: SegdTrace
        while r.readTrace(t):
          let want = r.record.findChannelSet(t.header)
          doAssert t.channelSet == (if want.isSome: want.get.channelSet else: -1), name
          if want.isSome: doAssert t.scanType == want.get.scanType, name
          inc traces
      doAssert traces > 0, name
    finally: src.close()

proc tocFile(entries = 0): string =
  ## A Table of Contents file: the 448-byte header and `entries` blank entries.
  result = alignLeft("SEGD TOC FILE", 13) & alignLeft("SD3.0", 6) & alignLeft("T1", 12)
  result = alignLeft(result, 438) & align($entries, 10) & spaces(128 * entries)

block table_of_contents_files_between_records:
  # One or several TOC files before, between and after the records.
  let recs = makeStream([sd8058, sd8024])
  discard recs.toDisk(tmp / "toc_recs.sgd")
  let whole = readFile(tmp / "toc_recs.sgd")
  discard makeStream([sd8058]).toDisk(tmp / "toc_first.sgd")
  let first = readFile(tmp / "toc_first.sgd")
  let second = whole[first.len .. ^1]
  doAssert whole[0 ..< first.len] == first
  let path = tmp / "toc_runs.sgd"
  writeFile(path, tocFile() & tocFile(2) & first & tocFile() & tocFile() & tocFile(1) & second &
    tocFile())
  let src = openDiskSource(path)
  var r = openSegd(src)
  var files: seq[int64]
  var traces = 0
  while r.nextRecord():
    files.add r.record.fileNumber
    var t: SegdTrace
    while r.readTrace(t): inc traces
  src.close()
  doAssert r.log.len == 0, $r.log
  doAssert files == @[100'i64, 101] and traces == 2 * recs.records[0].traces.len
  doAssert r.toc.len == 6 and r.toc[1].entries.len == 2 and r.toc[4].entries.len == 1
  sameRecords(readSegd(path), recs)

block a_long_run_of_table_of_contents_files:
  # `nextRecord` called itself once per TOC file: 50000 of them (22 MB)
  # overflowed the stack. They are read in a loop now.
  const n = 50_000
  let path = tmp / "toc_many.sgd"
  let one = tocFile()
  var s = newStringOfCap(one.len * n)
  for i in 0 ..< n: s.add one
  writeFile(path, s)
  let src = openDiskSource(path)
  var r = openSegd(src, headersOnly = true)
  doAssert not r.nextRecord() and r.isDone
  src.close()
  doAssert r.toc.len == n and r.log.len == 0
  removeFile(path)
  # A TOC file cut short ends the read with a fatal entry.
  writeFile(path, one & one[0 ..< 300])
  let d = readSegd(path)
  doAssert d.records.len == 0 and d.log.isFatal and d.log[d.log.len - 1].code == dcTruncated

block extension_sample_count_of_zero:
  # Trace Header Extension #1 bytes 8-10 left at 0 by the writer: read as a
  # trace without samples, the samples were taken for the next trace header
  # and the walk ended in garbage. The channel set's window sizes the trace,
  # as it does for a trace without extensions.
  let recs = makeStream([sd8058, sd8058])
  let path = tmp / "the_ns0.sgd"
  discard recs.toDisk(path)
  var b = readBytes(path)
  var zeroed = 0
  for rec in readSegd(path).records:
    for t in rec.traces:
      if t.ext1.isSome:
        for i in 7..9: b[int(t.offset) + 20 + i] = 0
        inc zeroed
  doAssert zeroed == 6
  writeBytes(path, b)
  for headersOnly in [false, true]:
    let d = readSegd(path, headersOnly = headersOnly)
    doAssert d.records.len == 2 and not d.log.hasErrors, $d.log
    var warned, counted = 0
    for x in d.log:
      if x.severity == sevWarning and x.loc.field == "ext1.samplesPerTrace":
        doAssert "gives 0 samples; using the 52 of the channel set's window" in x.msg
        inc warned
      elif x.severity == sevInfo and "1 more warning diagnostics for ext1.samplesPerTrace" in x.msg:
        inc counted
    doAssert warned == 5 and counted == 1, $d.log
    for r, rec in d.records:
      doAssert rec.traces.len == 5
      for k, t in rec.traces:
        doAssert t.numSamples == 52
        if not headersOnly: doAssert t.samples == recs.records[r].traces[k].samples
        if k >= 2: doAssert t.ext1.get.samplesPerTrace == 0 # the header stays as read
  # A window that gives no length leaves the trace without samples.
  var c = makeStream([sd8058])
  c.records[0].record.scanTypes[0].descriptors[1].endTime = 0
  for t in c.records[0].traces.mitems:
    if t.ext1.isSome:
      t.ext1.get.samplesPerTrace = 0
      t.numSamples = 0
      t.samples.setLen 0
  discard c.toDisk(tmp / "the_ns0_window0.sgd", SegdWriteOptions(lenient: true))
  let e = readSegd(tmp / "the_ns0_window0.sgd")
  doAssert e.records.len == 1 and e.records[0].traces.len == 5 and not e.log.isFatal, $e.log
  doAssert e.records[0].traces[4].numSamples == 0 and e.records[0].traces[0].numSamples == 52

block channel_set_values_without_a_trace:
  # `descaleFactor` and `startTimeMs` by scan type and channel set, as
  # `sampleIntervalUs` and `channelType` have them: what code holding only
  # an index entry (record, scan type, channel set) needs.
  var d = makeStream([sd8058])
  d.records[0].record.scanTypes[0].descriptors[1].startTime = 4 # 8 ms
  let rec = d.records[0].record
  doAssert rec.descaleFactor(0, 0) == pow(2.0, -2.5) and rec.descaleFactor(0, 1) == 1.0
  doAssert rec.startTimeMs(0, 0) == 0.0 and rec.startTimeMs(0, 1) == 8.0
  doAssert rec.descaleFactor(0, -1) == 1.0 and rec.startTimeMs(0, -1) == 0.0
  doAssert rec.descaleFactor(-1, -1) == 1.0 and rec.startTimeMs(-1, -1) == 0.0
  discard d.toDisk(tmp / "sets_rev2.sgd", SegdWriteOptions(lenient: true))
  for path in [tmp / "sets_rev2.sgd", demoDir() / "shot.sgd", demoDir() / "record.sgd"]:
    let e = readSegd(path)
    var traces = 0
    for r in e.records:
      for t in r.traces:
        doAssert r.record.descaleFactor(t) == r.record.descaleFactor(t.scanType, t.channelSet)
        doAssert r.record.startTimeMs(t) == r.record.startTimeMs(t.scanType, t.channelSet)
        inc traces
    doAssert traces > 0, path
  # Rev 3: the descale multiplier and the start time in µs.
  let shot = readSegd(demoDir() / "shot.sgd").records[0].record
  for cs in 0 ..< shot.scanTypes[0].channelSetCount:
    template c: untyped = shot.scanTypes[0].descriptorsRev3[cs]
    let m = float64(c.descaleMultiplier)
    doAssert shot.descaleFactor(0, cs) == (if m == 0 or m.isNaN: 1.0 else: m)
    doAssert shot.startTimeMs(0, cs) == float64(c.startTime) / 1000

block general_header_time_reads_the_two_digit_year_like_the_library:
  # GH#1 has a two-digit year. `generalHeaderUtc(g1)` put it in 2000-2099,
  # so a 1999 record was dated 2099, while the trace keys and the
  # converters read 50-99 as 19xx. The default is that pivot now.
  proc utc(year, day: int): float64 =
    float64(dateTime(year, mJan, 1, zone = utc()).toTime.toUnix + (day - 1) * 86400)
  var g1 = SegdGeneralHeader1(year: 99, julianDay: 1)
  doAssert generalHeaderUtc(g1) == 915_148_800.0 and utc(1999, 1) == 915_148_800.0
  g1 = SegdGeneralHeader1(year: 50, julianDay: 32, hour: 1, minute: 2, second: 3)
  doAssert generalHeaderUtc(g1) == utc(1950, 32) + 3723
  g1.year = 49
  doAssert generalHeaderUtc(g1) == utc(2049, 32) + 3723
  g1.year = 0
  doAssert generalHeaderUtc(g1) == utc(2000, 32) + 3723
  # The century can still be given.
  g1.year = 99
  doAssert generalHeaderUtc(g1, 2000) == utc(2099, 32) + 3723
  doAssert generalHeaderUtc(g1, century = 1900) == utc(1999, 32) + 3723
  doAssert generalHeaderUtc(g1) == generalHeaderUtc(g1, 1900)
  # Fields that are not valid BCD or out of range: no time.
  for bad in [SegdGeneralHeader1(year: BcdInvalid, julianDay: 1),
      SegdGeneralHeader1(year: BcdAllF, julianDay: 1), SegdGeneralHeader1(year: 26),
      SegdGeneralHeader1(year: 26, julianDay: 367), SegdGeneralHeader1(year: 26, julianDay: 1,
      hour: 24), SegdGeneralHeader1(year: 26, julianDay: 1, minute: 60)]:
    doAssert generalHeaderUtc(bad).isNaN and generalHeaderUtc(bad, 2000).isNaN
