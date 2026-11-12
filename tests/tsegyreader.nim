## SEG-Y reader and writer: validation against the sample files, lossless
## round trips on disk and tape images, byte-order conversion, Rev 2
## structures and damaged input (task 3.3).

import std/[assertions, os, strutils, sequtils]
import parseSEG/common/[errors, diagnostics, endians]
import parseSEG/io/[records, diskio, tapeimage]
import parseSEG/common/tensors
import parseSEG/segy/[reader, writer]
import parseSEG/convert
import ./utils/testutils

let tmp = scratchDir("parseseg_tsegyreader")

proc rewrite(d: SegyData, sink: RecordSink, opts: SegyWriteOptions) =
  var w = openSegyWriter(sink, d.file, opts)
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()

proc copyTo(d: SegyData, path: string, opts: SegyWriteOptions) =
  rewrite(d, openDiskSink(path), opts)

proc errorsAndWorse(log: DiagLog): int = log.count(sevError) + log.count(sevFatal)

sampleBlock sweep0:
  let d = readSegy(exampleDir / "Sweep0.sgy")
  doAssert d.log.len == 1
  doAssert d.log[0].severity == sevInfo and d.log[0].code == dcByteOrder
  doAssert d.log[0].offset == 3296
  doAssert d.file.byteOrder == boLittle and not d.file.byteOrderDeclared
  doAssert d.file.format == some(sfFloat32) and d.file.firstTraceOffset == 3600
  doAssert d.traces.len == 1 and d.traces[0].numSamples == 12001
  doAssert d.traces[0].sampleInterval == 1000.0 and d.traces[0].header.traceIdCode == 6
  doAssert d.samples.shape == [1, 12001]
  doAssert d.samples[0, 6000] == -0.04068503528833389'f32

sampleBlock inglewood:
  let d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  doAssert d.log.len == 0, $d.log[0]
  doAssert d.file.byteOrder == boBig and d.file.byteOrderDeclared
  doAssert d.file.extended.recordCount == 103 and d.file.extended.stanzas.len == 6
  doAssert d.file.firstTraceOffset == 333200
  doAssert d.traces.len == 200 and d.samples.shape == [200, 2001]
  doAssert d.traces[199].offset == 333200 + 199 * 8244
  doAssert d.samples[100, 1000] == 5572.83203125'f32
  doAssert d.file.trailer.recordCount == 0

sampleBlock byte_identical_round_trips:
  for name in ["Sweep0.sgy", "BO_3D-Inglewood_rev21_v7.sgy"]:
    let d = readSegy(exampleDir / name)
    let outPath = tmp / name
    d.copyTo(outPath, initSegyWriteOptions(d.file))
    doAssert readBytes(outPath) == readBytes(exampleDir / name), name

sampleBlock byte_order_conversion:
  for (name, target) in [("BO_3D-Inglewood_rev21_v7.sgy", boLittle),
      ("BO_3D-Inglewood_rev21_v7.sgy", boPairSwapped), ("Sweep0.sgy", boBig)]:
    let d = readSegy(exampleDir / name)
    let outPath = tmp / ("swapped_" & $target & "_" & name)
    d.copyTo(outPath, SegyWriteOptions(byteOrder: target))
    let e = readSegy(outPath)
    doAssert e.file.byteOrder == target, name & " " & $target
    doAssert e.log.errorsAndWorse == 0
    doAssert e.file.binary == d.file.binary
    doAssert e.traces.len == d.traces.len
    for i in 0..<d.traces.len:
      doAssert e.traces[i].header == d.traces[i].header
    doAssert e.samples == d.samples
    # And back again, byte for byte.
    let back = tmp / ("back_" & name)
    e.copyTo(back, SegyWriteOptions(byteOrder: d.file.byteOrder, lenient: true))
    doAssert readBytes(back) == readBytes(exampleDir / name)

sampleBlock tape_image_round_trip:
  let d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let tap = tmp / "inglewood.tap"
  rewrite(d, openTapeImageSink(tap), initSegyWriteOptions(d.file))
  # One tape record per SEG-Y record.
  var src: RecordSource = openTapeImageSource(tap)
  var buf: seq[byte]
  var sizes: seq[int]
  while src.readRecord(buf) == rkData: sizes.add buf.len
  src.close()
  doAssert sizes.len == 1 + 1 + 103 + 200
  doAssert sizes[0] == 3200 and sizes[1] == 400 and sizes[^1] == 8244
  src = openTapeImageSource(tap)
  let e = readSegy(src)
  src.close()
  doAssert e.log.len == 0
  doAssert e.traces.len == 200 and e.samples == d.samples
  doAssert e.file.extended.data == d.file.extended.data

sampleBlock tape_label:
  var d = readSegy(exampleDir / "Sweep0.sgy")
  var label = newSeq[byte](TapeLabelSize)
  let text = align("1", 4) & "SY1.0RECORDB1  " & align("0", 10) & align("0", 10) &
    "07-NOV-2026" & spaces(18) & alignLeft("TEST SET", 60)
  doAssert text.len == TapeLabelSize
  for i, c in text: label[i] = byte(c)
  d.file.tapeLabel = label
  let disk = tmp / "labelled.sgy"
  d.copyTo(disk, initSegyWriteOptions(d.file))
  let e = readSegy(disk)
  doAssert e.file.tapeLabel == label and e.traces.len == 1
  doAssert e.file.firstTraceOffset == 128 + 3600
  var bin = e.file.binary
  bin.formatCode = 99
  var log: DiagLog
  bin.validate(log, headerOffset = 3328)
  doAssert log.len == 1 and log[0].offset == 3328 + 24
  doAssert e.samples == d.samples
  let tap = tmp / "labelled.tap"
  rewrite(d, openTapeImageSink(tap), initSegyWriteOptions(d.file))
  var src: RecordSource = openTapeImageSource(tap)
  let f = readSegy(src)
  src.close()
  doAssert f.file.tapeLabel == label and f.samples == d.samples
  # A label of the wrong length is refused, even when lenient, not asserted.
  d.file.tapeLabel.setLen 100
  var opts = initSegyWriteOptions(d.file)
  opts.lenient = true
  try:
    d.copyTo(tmp / "badlabel.sgy", opts)
    doAssert false, "a 100-byte tape label was written"
  except SegFormatError as e:
    doAssert "100-byte tape label" in e.msg, e.msg

sampleBlock truncated_file:
  let full = readBytes(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let cut = tmp / "cut.sgy"
  writeBytes(cut, full[0 ..< 333200 + 150 * 8244 + 1000])
  let d = readSegy(cut)
  doAssert d.traces.len == 150
  doAssert d.log.count(sevFatal) == 1
  let fatal = d.log[d.log.len - 1]
  doAssert fatal.code == dcTruncated and fatal.loc.trace == 150
  doAssert fatal.offset == 333200 + 150 * 8244 + 1000

sampleBlock undefined_format_code:
  var b = readBytes(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  b[3224] = 0
  b[3225] = 99
  let bad = tmp / "badformat.sgy"
  writeBytes(bad, b)
  let d = readSegy(bad)
  doAssert d.traces.len == 0 and d.log.isFatal
  doAssert d.file.binary.formatCode == 99 and d.file.extended.recordCount == 103 # headers still read
  var found = false
  for e in d.log:
    if e.code == dcUnsupportedFormat and e.severity == sevFatal and e.offset == 3224:
      found = true
  doAssert found
  # The writer refuses the header unless lenient.
  doAssertRaises SegFormatError:
    discard openSegyWriter(openDiskSink(tmp / "refused.sgy"), d.file,
      initSegyWriteOptions(d.file))
  var w = openSegyWriter(openDiskSink(tmp / "lenient.sgy"), d.file,
    initSegyWriteOptions(d.file, lenient = true))
  doAssert w.log.count(sevWarning) > 0 and w.log.count(sevError) == 0

proc rev2File(numTraces: uint64, trailerRecords: int32, lastFlag: bool): SegyData =
  ## A synthetic Rev 2.1 file: one Ext1 header per trace (overriding the
  ## sample count), a text stanza, and one trailer record.
  var f = SegyFile(byteOrder: boBig, format: some(sfInt16))
  f.text = initTextHeader(teAscii)
  f.binary = SegyBinaryHeader(segyMajor: 2, segyMinor: 1, formatCode: 3, sampleInterval: 500,
    samplesPerTrace: 1, extSamplesPerTrace: 70000, fixedLengthTraces: 0, numExtTextHeaders: 2,
    maxAddlTraceHeaders: 1, numTraces: numTraces, numTrailerRecords: trailerRecords,
    byteOrderMarker: ByteOrderMarker)
  f.extended = initExtendedTextHeader()
  f.extended.addText("ACME", "Notes", "hello")
  f.extended.addEndText()
  f.trailer = initExtendedTextHeader()
  f.trailer.addText("ACME", "TrailerNotes", "trailer text")
  result.file = f
  for k in 0..<3:
    var t = SegyTrace(index: k, numSamples: 5 + k)
    t.header.traceSeqFile = int32(k + 1)
    t.header.numSamples = 1 # overridden by Ext1
    t.hasExt1 = true
    t.ext1 = initTraceHeaderExt1()
    t.ext1.extNumSamples = uint32(t.numSamples)
    t.ext1.numAddlTraceHeaders = 1
    if lastFlag and k == 2: t.ext1.lastTraceFlag = LastInFile
    t.samples = newSeq[byte](2 * t.numSamples)
    for i in 0..<t.numSamples: putNum(t.samples, 2 * i, int16(100 * k + i), boBig)
    result.traces.add t

block rev2_structures:
  for (numTraces, trailer, lastFlag) in [(3'u64, 1'i32, false), (0'u64, -1'i32, false),
      (0'u64, 1'i32, true), (0'u64, 0'i32, false)]:
    var d = rev2File(numTraces, trailer, lastFlag)
    if trailer == 0: d.file.trailer = initExtendedTextHeader()
    let path = tmp / "rev2.sgy"
    d.copyTo(path, initSegyWriteOptions(d.file))
    let e = readSegy(path)
    doAssert e.log.len == 0, $numTraces & " " & $trailer & ": " & $e.log[0]
    doAssert e.traces.len == 3
    doAssert e.file.extended.stanzas.len == 2
    for k in 0..<3:
      doAssert e.traces[k].numSamples == 5 + k
      doAssert e.samples[k, 4] == float32(100 * k + 4)
    doAssert e.samples.shape == [3, 7]
    doAssert e.file.trailer.recordCount == (if trailer == 0: 0 else: 1)
    if trailer != 0:
      doAssert e.file.trailer.stanzaText(e.file.trailer.stanzas[0]) == "trailer text"
    doAssert readBytes(path) == (block:
      let again = tmp / "rev2_again.sgy"
      e.copyTo(again, initSegyWriteOptions(e.file))
      readBytes(again))

block declared_counts_checked:
  var d = rev2File(5, 0, false)
  d.file.trailer = initExtendedTextHeader()
  let path = tmp / "rev2_short.sgy"
  doAssertRaises SegFormatError: d.copyTo(path, initSegyWriteOptions(d.file))
  d.copyTo(path, initSegyWriteOptions(d.file, lenient = true))
  let e = readSegy(path)
  doAssert e.traces.len == 3
  doAssert e.log.len == 1 and e.log[0].code == dcInconsistent
  doAssert e.log[0].loc.field == "binary.numTraces"

# ------------------------------------------------- review regressions --
# One block per finding of the independent review of tasks 3.1-3.3.

proc editKey(edits: openArray[(int, seq[byte])]): int =
  for (p, b) in edits: result = result * 31 + p + b.len

proc patched(name: string, edits: openArray[(int, seq[byte])]): string =
  ## Writes a copy of a sample file with byte edits (0-based offsets) applied.
  var b = readBytes(exampleDir / name)
  for (pos, bytes) in edits:
    for i, x in bytes: b[pos + i] = x
  result = tmp / ("patched_" & $editKey(edits) & "_" & name)
  writeBytes(result, b)

const ingle = "BO_3D-Inglewood_rev21_v7.sgy"

sampleBlock review_huge_first_trace_offset_is_logged_not_fatal:
  let d = readSegy(patched(ingle, [(3520, newSeq[byte](8).mapIt(0xFF'u8))]))
  doAssert d.traces.len == 200 and not d.log.isFatal
  doAssert d.log[0].loc.field == "binary.firstTraceOffset"

sampleBlock review_huge_counts_do_not_allocate_unboundedly:
  # Rev 2.0 with 0x7FFFFFFF additional headers per trace: the read stops at
  # the end of the 2 MB file instead of allocating ~500 GB.
  let d = readSegy(patched(ingle, [(3500, @[2'u8, 0]), (3506, @[0x7F'u8, 0xFF, 0xFF, 0xFF])]))
  doAssert d.log.isFatal and d.traces.len == 0
  doAssert d.log[d.log.len - 1].code == dcTruncated

sampleBlock review_missing_endtext_does_not_swallow_traces:
  var blank = newSeq[byte](15)
  for i in 0..<blank.len: blank[i] = 0x20
  let d = readSegy(patched(ingle, [(330000, blank)])) # EndText name blanked
  doAssert d.traces.len == 200 and not d.log.isFatal
  doAssert d.file.extended.recordCount == 103 and not d.file.extended.hasEndText
  doAssert d.file.firstTraceOffset == 333200
  var warned = false
  for e in d.log:
    if e.loc.field == "extended" and e.offset == 333200: warned = true
  doAssert warned

sampleBlock review_headers_survive_a_fatal_error:
  let full = readBytes(exampleDir / ingle)
  let cut = tmp / "cut_in_ext.sgy"
  writeBytes(cut, full[0 ..< 50000])
  let d = readSegy(cut)
  doAssert d.log.isFatal
  doAssert d.file.revision == SegyRevision(major: 2, minor: 1)
  doAssert d.file.binary.lineNumber == 360 and d.file.extended.recordCount == 14

sampleBlock review_le_trace_numbers_are_not_taken_for_a_trailer:
  var d = readSegy(exampleDir / ingle)
  d.file.binary.numTrailerRecords = -1
  d.traces[5].header.traceSeqLine = 10280 # 0x2828 = "((" in little-endian
  let path = tmp / "le_trailer.sgy"
  d.copyTo(path, SegyWriteOptions(byteOrder: boLittle))
  let e = readSegy(path)
  doAssert e.traces.len == 200 and e.log.len == 0
  doAssert e.traces[5].header.traceSeqLine == 10280

sampleBlock review_undefined_revision_gets_rev0_rules:
  var blanks = newSeq[byte](340)
  for i in 0..<blanks.len: blanks[i] = 0x20
  let d = readSegy(patched("Sweep0.sgy", [(3260, blanks)]))
  doAssert d.traces.len == 1 and not d.log.isFatal
  doAssert d.file.revision == SegyRevision(major: 0, minor: 0)
  doAssert d.file.binary.revision == SegyRevision(major: 32, minor: 32)

sampleBlock review_little_endian_rev1_revision:
  let d = readSegy(patched("Sweep0.sgy", [(3500, @[0'u8, 1])]))
  doAssert d.file.revision == SegyRevision(major: 1, minor: 0)
  doAssert d.traces.len == 1 and not d.log.isFatal

sampleBlock review_label_needs_a_c_after_it:
  # A textual header that starts like a label but is not followed by 'C'.
  let d = readSegy(patched("Sweep0.sgy", [(0, @[byte(' '), byte('1'), byte(' '), byte(' '),
    byte('S'), byte('Y')])]))
  doAssert d.file.tapeLabel.len == 0 and d.traces.len == 1
  doAssert d.file.firstTraceOffset == 3600

sampleBlock review_writer_checks:
  let d = readSegy(exampleDir / "Sweep0.sgy")
  doAssertRaises SegFormatError: # pair-swapped Rev 0 cannot be read back
    d.copyTo(tmp / "pair_rev0.sgy", SegyWriteOptions(byteOrder: boPairSwapped))
  var e = readSegy(exampleDir / ingle)
  e.file.binary.numExtTextHeaders = 5
  doAssertRaises SegFormatError: e.copyTo(tmp / "badcount.sgy", initSegyWriteOptions(e.file))
  var g = readSegy(exampleDir / ingle)
  g.file.binary.fixedLengthTraces = 0
  g.traces[3].header.numSamples = 2000
  doAssertRaises SegFormatError: g.copyTo(tmp / "badns.sgy", initSegyWriteOptions(g.file))
  var h = rev2File(3, 1, false)
  h.file.binary.maxAddlTraceHeaders = 70000 # lenient: logged, no crash
  var w = openSegyWriter(openDiskSink(tmp / "lenient_maxaddl.sgy"), h.file,
    initSegyWriteOptions(h.file, lenient = true))
  doAssert w.log.count(sevWarning) > 0

block review_ibm_into_float64_keeps_range:
  var one = [0.0]
  decodeSamples(sfIbm32, [0x7F'u8, 0xFF, 0xFF, 0xFF], one)
  doAssert one[0] > 7e75

# ------------------------------------------------- write-as-read (3.4a) --

proc writeLog(d: SegyData, path: string, opts: SegyWriteOptions): DiagLog =
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, d.file, opts)
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()
  result = w.log

sampleBlock as_read_little_endian_rev0_is_written_back:
  let d = readSegy(exampleDir / "Sweep0.sgy")
  let log = writeLog(d, tmp / "asread_sweep.sgy", initSegyWriteOptions(d.file))
  doAssert log.len == 1 and log[0].severity == sevWarning
  doAssert log[0].loc.field == "binary.byteOrderMarker"
  doAssert readBytes(tmp / "asread_sweep.sgy") == readBytes(exampleDir / "Sweep0.sgy")
  # The same header built in memory is new content: little-endian Rev 0 is refused.
  let fresh = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boLittle,
    format: d.file.format, extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  doAssertRaises SegFormatError:
    discard openSegyWriter(openDiskSink(tmp / "fresh_le.sgy"), fresh,
      SegyWriteOptions(byteOrder: boLittle))
  # Converting a clean big-endian file to little-endian Rev 1 is refused too.
  var e = readSegy(exampleDir / "Sweep0.sgy")
  e.copyTo(tmp / "sweep_be.sgy", SegyWriteOptions(byteOrder: boBig))
  let be = readSegy(tmp / "sweep_be.sgy")
  doAssert be.file.byteOrder == boBig
  doAssertRaises SegFormatError:
    be.copyTo(tmp / "sweep_back_le.sgy", SegyWriteOptions(byteOrder: boLittle))

sampleBlock as_read_invalid_values_are_judged_per_field:
  # Sweep0 (LE) with a zero sample interval: read with a warning ...
  let path = patched("Sweep0.sgy", [(3216, @[0'u8, 0])])
  var d = readSegy(path)
  doAssert d.file.binary.sampleInterval == 0
  # ... written back with warnings only, also after an unrelated edit ...
  d.file.binary.jobId = 42
  let log = writeLog(d, tmp / "dt0.sgy", initSegyWriteOptions(d.file))
  doAssert log.count(sevError) == 0
  var sawDt = false
  for e in log:
    if e.loc.field == "binary.sampleInterval": sawDt = true
  doAssert sawDt
  # ... but zeroing the interval of a clean file is a new problem.
  var g = readSegy(exampleDir / ingle)
  g.file.binary.sampleInterval = 0
  g.file.binary.extSampleInterval = 0
  doAssertRaises SegFormatError: g.copyTo(tmp / "dt0_new.sgy", initSegyWriteOptions(g.file))
  let lenientLog = writeLog(g, tmp / "dt0_lenient.sgy", initSegyWriteOptions(g.file, true))
  doAssert lenientLog.count(sevError) == 0 and lenientLog.count(sevWarning) > 0

sampleBlock as_read_missing_endtext_is_written_back:
  var blank = newSeq[byte](15)
  for i in 0..<blank.len: blank[i] = 0x20
  let path = patched(ingle, [(330000, blank)])
  let d = readSegy(path)
  doAssert not d.file.extended.hasEndText
  discard writeLog(d, tmp / "noendtext.sgy", initSegyWriteOptions(d.file))
  doAssert readBytes(tmp / "noendtext.sgy") == readBytes(path)

# ----------------------------------------------- Extension 1 (3.4c) --

block ext1_and_proprietary_headers:
  var d = rev2File(3, 0, false)
  d.file.trailer = initExtendedTextHeader()
  d.file.binary.maxAddlTraceHeaders = 2
  for k in 0..<3:
    d.traces[k].ext1.numAddlTraceHeaders = 2
    d.traces[k].ext1.extSourceX = 400_000.25 + float64(k)
    d.traces[k].ext1.nanoseconds = -int32(k)
    d.traces[k].proprietary = newSeq[byte](240)
    for i, c in "ACME0001": d.traces[k].proprietary[232 + i] = byte(c)
    putNum(d.traces[k].proprietary, 0, uint32(0xDEADBEEF'u32), boBig)
  let path = tmp / "ext1_prop.sgy"
  d.copyTo(path, initSegyWriteOptions(d.file))
  let e = readSegy(path)
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.traces.len == 3
  for k in 0..<3:
    let t = e.traces[k]
    doAssert t.hasExt1 and t.ext1.extSourceX == 400_000.25 + float64(k)
    doAssert t.ext1.nanoseconds == -int32(k) and t.ext1.headerNameText == "SEG00001"
    doAssert t.proprietary.len == 240 and headerBlockName(t.proprietary) == "ACME0001"
    doAssert t.numSamples == 5 + k
  # Proprietary blocks have no known layout: no silent byte-order change.
  doAssertRaises SegFormatError:
    e.copyTo(tmp / "ext1_prop_le.sgy", SegyWriteOptions(byteOrder: boLittle))
  e.copyTo(tmp / "ext1_prop_le.sgy", SegyWriteOptions(byteOrder: boLittle, lenient: true))
  let le = readSegy(tmp / "ext1_prop_le.sgy")
  doAssert le.traces[2].ext1.extSourceX == 400_002.25
  doAssert le.traces[2].proprietary == e.traces[2].proprietary # copied unchanged

block ext1_byte_order_conversion:
  var d = rev2File(3, 0, true)
  d.file.trailer = initExtendedTextHeader()
  let path = tmp / "ext1_be.sgy"
  d.copyTo(path, initSegyWriteOptions(d.file))
  var prev = readSegy(path)
  for order in [boLittle, boPairSwapped, boBig]:
    let next = tmp / ("ext1_" & $order & ".sgy")
    prev.copyTo(next, SegyWriteOptions(byteOrder: order))
    let e = readSegy(next)
    doAssert e.file.byteOrder == order and e.log.len == 0
    doAssert e.traces.len == 3 and e.samples == prev.samples
    for k in 0..<3: doAssert e.traces[k].ext1 == prev.traces[k].ext1
    prev = e
  doAssert readBytes(tmp / "ext1_big.sgy") == readBytes(path)

sampleBlock rev0_zero_sample_count_task_3_5:
  # Sweep0.sgy is Rev 0, little-endian, one trace of 12001 samples. Rev 0
  # writers sometimes left trace bytes 115-116 at 0: the binary count is used.
  var s = readFile(exampleDir / "Sweep0.sgy")
  s[3600 + 114] = '\0'
  s[3600 + 115] = '\0'
  writeFile(tmp / "sweep_ns0.sgy", s)
  let d = readSegy(tmp / "sweep_ns0.sgy")
  doAssert d.traces.len == 1 and d.traces[0].numSamples == 12001
  var warned = false
  for x in d.log:
    if x.loc.field == "trace.numSamples" and "binary header" in x.msg: warned = true
  doAssert warned
  let orig = readSegy(exampleDir / "Sweep0.sgy")
  doAssert d.traces[0].samples == orig.traces[0].samples

sampleBlock rev20_files_task_3_5:
  # 2.1 -> 2.0: Rev 2.0 does not require ((SEG:EndText)), and reads back as 2.0.
  let src = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  let log = convertFile(src, tmp / "ingle20.sgy",
    ConvertOptions(revision: SegyRevision(major: 2, minor: 0)))
  doAssert not log.isFatal and log.count(sevError) == 0, $log
  let d = readSegy(tmp / "ingle20.sgy", headersOnly = true)
  doAssert d.file.revision == SegyRevision(major: 2, minor: 0)
  for x in d.log: doAssert "EndText" notin x.msg

# ------------------------------- review of task 3.4 (one block per finding) --

proc write(d: SegyData, path: string, opts: SegyWriteOptions): DiagLog =
  let sink = openDiskSink(path)
  try:
    var w = openSegyWriter(sink, d.file, opts)
    for t in d.traces: w.writeTrace(t)
    w.close()
    result = w.log
  finally:
    sink.close()

proc strict(d: SegyData): SegyWriteOptions = initSegyWriteOptions(d.file)
proc lenient(d: SegyData): SegyWriteOptions = initSegyWriteOptions(d.file, lenient = true)

proc makeFile(ext, trailer: ExtendedTextHeader, nExt: int16, nTrailer: int32): SegyData =
  var f = SegyFile(byteOrder: boBig, format: some(sfInt16))
  f.text = initTextHeader(teAscii)
  f.binary = SegyBinaryHeader(segyMajor: 2, segyMinor: 1, formatCode: 3, sampleInterval: 500,
    samplesPerTrace: 4, fixedLengthTraces: 1, numExtTextHeaders: nExt,
    numTrailerRecords: nTrailer, byteOrderMarker: ByteOrderMarker)
  f.extended = ext
  f.trailer = trailer
  result.file = f
  for k in 0..<3:
    var t = SegyTrace(index: k, numSamples: 4)
    t.header.numSamples = 4
    t.samples = newSeq[byte](8)
    result.traces.add t

sampleBlock segyreview2_f2_format_code_edit_is_refused:
  var d = readSegy(exampleDir / "Sweep0.sgy")
  d.file.binary.formatCode = 8
  doAssertRaises SegFormatError: discard d.write(tmp / "fmt.sgy", d.strict)

block segyreview2_f3_last_flag_and_endtext_position:
  var d = makeFile(initExtendedTextHeader(), initExtendedTextHeader(), 0, 0)
  d.file.binary.maxAddlTraceHeaders = 1
  for k in 0..<3:
    d.traces[k].hasExt1 = true
    d.traces[k].ext1 = initTraceHeaderExt1()
    d.traces[k].ext1.numAddlTraceHeaders = 1
  d.traces[0].ext1.lastTraceFlag = LastInFile
  doAssertRaises SegFormatError: discard d.write(tmp / "lastflag.sgy", SegyWriteOptions())
  var ext = initExtendedTextHeader()
  ext.addEndText()
  ext.addText("ACME", "Notes", "x")
  ext.addEndText()
  let e = makeFile(ext, initExtendedTextHeader(), -1, 0)
  doAssertRaises SegFormatError: discard e.write(tmp / "endtext.sgy", SegyWriteOptions())

block segyreview2_f4_inconsistent_files_write_back_as_read:
  # numExtTextHeaders 2 while firstTraceOffset implies 3 records.
  var ext = initExtendedTextHeader()
  ext.addText("ACME", "A", "a")
  ext.addText("ACME", "B", "b")
  ext.addEndText()
  var d = makeFile(ext, initExtendedTextHeader(), 2, 0)
  d.file.binary.firstTraceOffset = 3600 + 3 * 3200
  d.file.binary.numTraces = 5 # only 3 present
  let path = tmp / "inconsistent.sgy"
  discard d.write(path, d.lenient)
  let e = readSegy(path)
  doAssert e.traces.len == 3 and e.file.extended.recordCount == 3
  let log = e.write(tmp / "inconsistent_back.sgy", e.strict)
  doAssert log.count(sevError) == 0 and log.count(sevWarning) >= 2
  doAssert readBytes(tmp / "inconsistent_back.sgy") == readBytes(path)
  # Editing the count makes it a new problem again.
  var g = e
  g.file.binary.numExtTextHeaders = 1
  doAssertRaises SegFormatError: discard g.write(tmp / "edited.sgy", g.strict)

sampleBlock segyreview2_f5_cross_field_problems_are_not_downgraded:
  # Rev 1 little-endian, revision edited to 2.1: the (unchanged) zero marker
  # is now a new problem.
  var b = readBytes(exampleDir / "Sweep0.sgy")
  b[3500] = 1
  writeFile(tmp / "rev1le.sgy", cast[string](b))
  var d = readSegy(tmp / "rev1le.sgy")
  doAssert d.file.revision == SegyRevision(major: 1, minor: 0)
  discard d.write(tmp / "rev1le_back.sgy", d.strict) # as read: fine
  d.file.binary.segyMajor = 2
  d.file.binary.segyMinor = 1
  doAssertRaises SegFormatError: discard d.write(tmp / "rev1le_21.sgy", d.strict)
  # Rev 2 little-endian edited to Rev 1.
  let i = readSegy(exampleDir / ingle)
  discard i.write(tmp / "ingle_le.sgy", SegyWriteOptions(byteOrder: boLittle))
  var le = readSegy(tmp / "ingle_le.sgy")
  le.file.binary.segyMajor = 1
  le.file.binary.segyMinor = 0
  le.file.binary.numExtTextHeaders = 0
  le.file.extended = initExtendedTextHeader()
  doAssertRaises SegFormatError: discard le.write(tmp / "le_rev1.sgy", le.strict)
  # A zero 16-bit interval is fine while the Rev 2 extended one is set;
  # zeroing the extended one is a new problem.
  var z = readSegy(exampleDir / ingle)
  z.file.binary.sampleInterval = 0
  discard z.write(tmp / "dt16zero.sgy", z.strict)
  var z2 = readSegy(tmp / "dt16zero.sgy")
  discard z2.write(tmp / "dt16zero_back.sgy", z2.strict)
  z2.file.binary.extSampleInterval = 0
  doAssertRaises SegFormatError: discard z2.write(tmp / "dtzero.sgy", z2.strict)

block segyreview2_undefined_format_needs_its_own_byte_order:
  # 12.3: a lenient writer copies samples of an undefined format, but cannot
  # reorder them (their width is unknown).
  var d = makeFile(initExtendedTextHeader(), initExtendedTextHeader(), 0, 0)
  d.file.format = none(SampleFormat)
  d.file.binary.formatCode = 13
  let same = d.write(tmp / "fmt13.sgy", d.lenient)
  doAssert same.len > 0 and not same.hasErrors
  var le = d.lenient
  le.byteOrder = boLittle
  doAssertRaises SegFormatError: discard d.write(tmp / "fmt13le.sgy", le)

block segyreview2_writer_reuses_its_record_buffer:
  # Traces of different sizes in a row: each record has exactly its own bytes.
  var d = makeFile(initExtendedTextHeader(), initExtendedTextHeader(), 0, 0)
  d.file.binary.fixedLengthTraces = 0
  for k, n in [6, 2, 4]:
    d.traces[k].numSamples = n
    d.traces[k].header.numSamples = uint16(n)
    d.traces[k].samples = newSeq[byte](2 * n)
    for i in 0..<2 * n: d.traces[k].samples[i] = byte(16 * k + i)
  for order in [boBig, boLittle]:
    var opts = d.strict
    opts.byteOrder = order
    let path = tmp / ("sizes_" & $order & ".sgy")
    discard d.write(path, opts)
    let e = readSegy(path)
    doAssert e.traces.len == 3 and not e.log.hasErrors
    for k in 0..2:
      doAssert e.traces[k].numSamples == d.traces[k].numSamples
      var want = d.traces[k].samples
      if order == boLittle:
        for i in countup(0, want.len - 2, 2): swap(want[i], want[i + 1])
      doAssert e.traces[k].samples == want

block segyreview2_partial_last_sample_is_zero:
  # 12.4: a lenient trace whose sample bytes end in a partial sample, written
  # in another byte order, gets zeros there, not the previous trace's bytes.
  var d = makeFile(initExtendedTextHeader(), initExtendedTextHeader(), 0, 0)
  d.file.binary.fixedLengthTraces = 0
  d.traces.setLen 2
  for i in 0..7: d.traces[0].samples[i] = 0xEE
  d.traces[1].samples = newSeq[byte](7)
  for i in 0..6: d.traces[1].samples[i] = 0x11
  var opts = d.lenient
  opts.byteOrder = boLittle
  let path = tmp / "partial.sgy"
  discard d.write(path, opts)
  let b = readFile(path)
  let at = 3600 + 240 + 8 + 240 # trace 1's samples
  doAssert b.len == at + 7
  doAssert b[at .. at + 5] == "\x11\x11\x11\x11\x11\x11" and b[at + 6] == '\0'

block zero_sample_count_in_any_revision:
  # Writers that rely on the binary header leave trace bytes 115-116 at 0.
  # In a variable-length file of Rev 1 or later such traces were read as
  # traces of 0 samples: their samples were taken for the next headers (3
  # garbage traces and a fatal truncation, of 50 traces of 1000 samples).
  # The binary header's count sizes them, as it always did for Rev 0.
  let base = readFile(demoDir() / "survey.sgy") # Rev 2.1, fixed-length, 200 x 2001 samples
  let whole = readSegy(demoDir() / "survey.sgy")
  let first = int(whole.file.firstTraceOffset)
  const traceBytes = 240 + 2001 * 4
  for (major, minor) in [(0, 0), (1, 0), (2, 0), (2, 1)]:
    var s = base
    s[3500] = char(major)
    s[3501] = char(minor)
    s[3502] = '\0'
    s[3503] = '\0' # fixed-length flag 0: each trace has its own count
    for t in 0 ..< 200:
      s[first + t * traceBytes + 114] = '\0'
      s[first + t * traceBytes + 115] = '\0'
    let path = tmp / ("ns0_rev" & $major & $minor & ".sgy")
    if major == 0: s = s[0 ..< 3600] & s[first .. ^1] # Rev 0 has no extended records
    writeFile(path, s)
    let d = readSegy(path)
    let what = $major & "." & $minor & " " & $d.log
    doAssert d.traces.len == 200 and not d.log.hasErrors, what
    var warned, counted = 0
    for x in d.log:
      if x.severity == sevWarning and x.loc.field == "trace.numSamples":
        doAssert "0 samples; using the binary header's 2001" in x.msg
        inc warned
      elif x.severity == sevInfo and "195 more traces with 0 samples" in x.msg: inc counted
    doAssert warned == 5 and counted == 1, what
    for i in [0, 1, 199]:
      doAssert d.traces[i].numSamples == 2001 and d.traces[i].sampleInterval == 2000, what
      doAssert d.traces[i].samples == whole.traces[i].samples, what
  # No count anywhere: the traces have no samples, as before.
  var s = base
  for at in [3220, 3221, 3268, 3269, 3270, 3271, 3502, 3503]: s[at] = '\0'
  s[first + 114] = '\0'
  s[first + 115] = '\0'
  writeFile(tmp / "ns0_nowhere.sgy", s[0 ..< first + 240])
  let d = readSegy(tmp / "ns0_nowhere.sgy")
  doAssert d.traces.len == 1 and d.traces[0].numSamples == 0 and not d.log.isFatal, $d.log

block nan_extended_interval_does_not_override:
  # A Rev 2 extended sample interval overrides its 16-bit field when it is
  # non-zero. A NaN there (damage) was taken as the interval by the binary
  # header and the reader, while the keys fell back to the 16-bit field: one
  # rule now (`usableExtInterval`), and it is the keys'.
  doAssert usableExtInterval(2000.0) and usableExtInterval(-1.0) and usableExtInterval(Inf)
  doAssert not usableExtInterval(0.0) and not usableExtInterval(-0.0) and
    not usableExtInterval(NaN)
  var b = SegyBinaryHeader(segyMajor: 2, segyMinor: 1, formatCode: 5, sampleInterval: 2000,
    sampleIntervalOrig: 1000, samplesPerTrace: 100, byteOrderMarker: ByteOrderMarker)
  doAssert b.effectiveSampleInterval == 2000 and b.effectiveSampleIntervalOrig == 1000
  b.extSampleInterval = NaN
  b.extSampleIntervalOrig = NaN
  doAssert b.effectiveSampleInterval == 2000 and b.effectiveSampleIntervalOrig == 1000
  b.extSampleInterval = 250.5
  b.extSampleIntervalOrig = 125.25
  doAssert b.effectiveSampleInterval == 250.5 and b.effectiveSampleIntervalOrig == 125.25
  b.segyMajor = 1 # before Rev 2 the bytes are not an interval
  doAssert b.effectiveSampleInterval == 2000 and b.effectiveSampleIntervalOrig == 1000
  # In a trace: Extension 1 bytes 145-152.
  var d = rev2File(3, 0, false)
  d.file.trailer = initExtendedTextHeader()
  for k in 0..<3:
    d.traces[k].header.sampleInterval = 4000
    d.traces[k].ext1.extSampleInterval = [NaN, 0.0, 333.25][k]
  let path = tmp / "ext_dt_nan.sgy"
  d.copyTo(path, initSegyWriteOptions(d.file, lenient = true))
  let e = readSegy(path)
  doAssert e.traces.len == 3 and not e.log.hasErrors, $e.log
  doAssert e.traces[0].ext1.extSampleInterval.isNaN # the header stays as read
  doAssert e.traces[0].sampleInterval == 4000 and e.traces[1].sampleInterval == 4000
  doAssert e.traces[2].sampleInterval == 333.25
