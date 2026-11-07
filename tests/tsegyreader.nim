## SEG-Y reader and writer: validation against the sample files, lossless
## round trips on disk and tape images, byte-order conversion, Rev 2
## structures and damaged input (task 3.3).

import std/[assertions, os, strutils, sequtils]
import parseSEGD/common/errors
import parseSEGD/io/[records, diskio, tapeimage]
import parseSEGD/segy/[reader, writer]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parsesegd_tsegyreader"
createDir(tmp)

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc writeBytes(path: string, b: openArray[byte]) =
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(path, s)

proc rewrite(d: SegyData, sink: RecordSink, opts: SegyWriteOptions) =
  var w = openSegyWriter(sink, d.file, opts)
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()

proc copyTo(d: SegyData, path: string, opts: SegyWriteOptions) =
  rewrite(d, openDiskSink(path), opts)

proc errorsAndWorse(log: DiagLog): int = log.count(sevError) + log.count(sevFatal)

block sweep0:
  let d = readSegy(exampleDir / "Sweep0.sgy")
  doAssert d.diagnostics.len == 1
  doAssert d.diagnostics[0].severity == sevInfo and d.diagnostics[0].code == dcByteOrder
  doAssert d.diagnostics[0].offset == 3296
  doAssert d.file.byteOrder == boLittle and not d.file.byteOrderDeclared
  doAssert d.file.format == sfFloat32 and d.file.firstTraceOffset == 3600
  doAssert d.traces.len == 1 and d.traces[0].numSamples == 12001
  doAssert d.traces[0].sampleInterval == 1000.0 and d.traces[0].header.traceIdCode == 6
  doAssert d.samples.shape == [1, 12001]
  doAssert d.samples[0, 6000] == -0.04068503528833389'f32

block inglewood:
  let d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  doAssert d.diagnostics.len == 0, $d.diagnostics[0]
  doAssert d.file.byteOrder == boBig and d.file.byteOrderDeclared
  doAssert d.file.extended.recordCount == 103 and d.file.extended.stanzas.len == 6
  doAssert d.file.firstTraceOffset == 333200
  doAssert d.traces.len == 200 and d.samples.shape == [200, 2001]
  doAssert d.traces[199].offset == 333200 + 199 * 8244
  doAssert d.samples[100, 1000] == 5572.83203125'f32
  doAssert d.file.trailer.recordCount == 0

block byte_identical_round_trips:
  for name in ["Sweep0.sgy", "BO_3D-Inglewood_rev21_v7.sgy"]:
    let d = readSegy(exampleDir / name)
    let outPath = tmp / name
    d.copyTo(outPath, initSegyWriteOptions(d.file))
    doAssert readBytes(outPath) == readBytes(exampleDir / name), name

block byte_order_conversion:
  for (name, target) in [("BO_3D-Inglewood_rev21_v7.sgy", boLittle),
      ("BO_3D-Inglewood_rev21_v7.sgy", boPairSwapped), ("Sweep0.sgy", boBig)]:
    let d = readSegy(exampleDir / name)
    let outPath = tmp / ("swapped_" & $target & "_" & name)
    d.copyTo(outPath, SegyWriteOptions(byteOrder: target))
    let e = readSegy(outPath)
    doAssert e.file.byteOrder == target, name & " " & $target
    doAssert e.diagnostics.errorsAndWorse == 0
    doAssert e.file.binary == d.file.binary
    doAssert e.traces.len == d.traces.len
    for i in 0..<d.traces.len:
      doAssert e.traces[i].header == d.traces[i].header
    doAssert e.samples == d.samples
    # And back again, byte for byte.
    let back = tmp / ("back_" & name)
    e.copyTo(back, SegyWriteOptions(byteOrder: d.file.byteOrder, lenient: true))
    doAssert readBytes(back) == readBytes(exampleDir / name)

block tape_image_round_trip:
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
  doAssert e.diagnostics.len == 0
  doAssert e.traces.len == 200 and e.samples == d.samples
  doAssert e.file.extended.data == d.file.extended.data

block tape_label:
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

block truncated_file:
  let full = readBytes(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let cut = tmp / "cut.sgy"
  writeBytes(cut, full[0 ..< 333200 + 150 * 8244 + 1000])
  let d = readSegy(cut)
  doAssert d.traces.len == 150
  doAssert d.diagnostics.count(sevFatal) == 1
  let fatal = d.diagnostics[d.diagnostics.len - 1]
  doAssert fatal.code == dcTruncated and fatal.loc.trace == 150
  doAssert fatal.offset == 333200 + 150 * 8244 + 1000

block undefined_format_code:
  var b = readBytes(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  b[3224] = 0
  b[3225] = 99
  let bad = tmp / "badformat.sgy"
  writeBytes(bad, b)
  let d = readSegy(bad)
  doAssert d.traces.len == 0 and d.diagnostics.isFatal
  doAssert d.file.binary.formatCode == 99 and d.file.extended.recordCount == 103 # headers still read
  var found = false
  for e in d.diagnostics:
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
  var f = SegyFile(byteOrder: boBig, format: sfInt16, formatKnown: true)
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
    t.extraHeaders = newSeq[byte](240)
    putNum(t.extraHeaders, 136, uint32(t.numSamples), boBig)
    putNum(t.extraHeaders, 156, 1'u16, boBig)
    for i, c in "SEG00001": t.extraHeaders[232 + i] = byte(c)
    if lastFlag and k == 2: putNum(t.extraHeaders, 158, 4'u16, boBig)
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
    doAssert e.diagnostics.len == 0, $numTraces & " " & $trailer & ": " & $e.diagnostics[0]
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
  doAssert e.diagnostics.len == 1 and e.diagnostics[0].code == dcInconsistent
  doAssert e.diagnostics[0].loc.field == "binary.numTraces"

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

block review_huge_first_trace_offset_is_logged_not_fatal:
  let d = readSegy(patched(ingle, [(3520, newSeq[byte](8).mapIt(0xFF'u8))]))
  doAssert d.traces.len == 200 and not d.diagnostics.isFatal
  doAssert d.diagnostics[0].loc.field == "binary.firstTraceOffset"

block review_huge_counts_do_not_allocate_unboundedly:
  # Rev 2.0 with 0x7FFFFFFF additional headers per trace: the read stops at
  # the end of the 2 MB file instead of allocating ~500 GB.
  let d = readSegy(patched(ingle, [(3500, @[2'u8, 0]), (3506, @[0x7F'u8, 0xFF, 0xFF, 0xFF])]))
  doAssert d.diagnostics.isFatal and d.traces.len == 0
  doAssert d.diagnostics[d.diagnostics.len - 1].code == dcTruncated

block review_missing_endtext_does_not_swallow_traces:
  var blank = newSeq[byte](15)
  for i in 0..<blank.len: blank[i] = 0x20
  let d = readSegy(patched(ingle, [(330000, blank)])) # EndText name blanked
  doAssert d.traces.len == 200 and not d.diagnostics.isFatal
  doAssert d.file.extended.recordCount == 103 and not d.file.extended.hasEndText
  doAssert d.file.firstTraceOffset == 333200
  var warned = false
  for e in d.diagnostics:
    if e.loc.field == "extended" and e.offset == 333200: warned = true
  doAssert warned

block review_headers_survive_a_fatal_error:
  let full = readBytes(exampleDir / ingle)
  let cut = tmp / "cut_in_ext.sgy"
  writeBytes(cut, full[0 ..< 50000])
  let d = readSegy(cut)
  doAssert d.diagnostics.isFatal
  doAssert d.file.revision == SegyRevision(major: 2, minor: 1)
  doAssert d.file.binary.lineNumber == 360 and d.file.extended.recordCount == 14

block review_le_trace_numbers_are_not_taken_for_a_trailer:
  var d = readSegy(exampleDir / ingle)
  d.file.binary.numTrailerRecords = -1
  d.traces[5].header.traceSeqLine = 10280 # 0x2828 = "((" in little-endian
  let path = tmp / "le_trailer.sgy"
  d.copyTo(path, SegyWriteOptions(byteOrder: boLittle))
  let e = readSegy(path)
  doAssert e.traces.len == 200 and e.diagnostics.len == 0
  doAssert e.traces[5].header.traceSeqLine == 10280

block review_undefined_revision_gets_rev0_rules:
  var blanks = newSeq[byte](340)
  for i in 0..<blanks.len: blanks[i] = 0x20
  let d = readSegy(patched("Sweep0.sgy", [(3260, blanks)]))
  doAssert d.traces.len == 1 and not d.diagnostics.isFatal
  doAssert d.file.revision == SegyRevision(major: 0, minor: 0)
  doAssert d.file.binary.revision == SegyRevision(major: 32, minor: 32)

block review_little_endian_rev1_revision:
  let d = readSegy(patched("Sweep0.sgy", [(3500, @[0'u8, 1])]))
  doAssert d.file.revision == SegyRevision(major: 1, minor: 0)
  doAssert d.traces.len == 1 and not d.diagnostics.isFatal

block review_label_needs_a_c_after_it:
  # A textual header that starts like a label but is not followed by 'C'.
  let d = readSegy(patched("Sweep0.sgy", [(0, @[byte(' '), byte('1'), byte(' '), byte(' '),
    byte('S'), byte('Y')])]))
  doAssert d.file.tapeLabel.len == 0 and d.traces.len == 1
  doAssert d.file.firstTraceOffset == 3600

block review_writer_checks:
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

block as_read_little_endian_rev0_is_written_back:
  let d = readSegy(exampleDir / "Sweep0.sgy")
  let log = writeLog(d, tmp / "asread_sweep.sgy", initSegyWriteOptions(d.file))
  doAssert log.len == 1 and log[0].severity == sevWarning
  doAssert log[0].loc.field == "binary.byteOrderMarker"
  doAssert readBytes(tmp / "asread_sweep.sgy") == readBytes(exampleDir / "Sweep0.sgy")
  # The same header built in memory is new content: little-endian Rev 0 is refused.
  let fresh = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boLittle,
    format: d.file.format, formatKnown: true, extended: initExtendedTextHeader(),
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

block as_read_invalid_values_are_judged_per_field:
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

block as_read_missing_endtext_is_written_back:
  var blank = newSeq[byte](15)
  for i in 0..<blank.len: blank[i] = 0x20
  let path = patched(ingle, [(330000, blank)])
  let d = readSegy(path)
  doAssert not d.file.extended.hasEndText
  discard writeLog(d, tmp / "noendtext.sgy", initSegyWriteOptions(d.file))
  doAssert readBytes(tmp / "noendtext.sgy") == readBytes(path)
