## Regression tests for the independent review of task 3.4 (one block per
## finding, numbered as in the review).

import std/[assertions, os, strutils]
import parseSEG/common/errors
import parseSEG/io/diskio
import parseSEG/segy/[reader, writer, fields]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
const ingle = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
let tmp = getTempDir() / "parseseg_tsegyreview2"
createDir(tmp)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc readBytes(path: string): seq[byte] = toBytes(readFile(path))

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
  var f = SegyFile(byteOrder: boBig, format: sfInt16, formatKnown: true)
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

proc warned(log: DiagLog, text: string): bool =
  for e in log:
    if e.severity == sevWarning and text in e.msg: return true

block f1_hostile_layout_entities:
  for bad in ["<segy-layout>&#99999999999;</segy-layout>",
      "<segy-layout>&#xFFFFFFFFFF;</segy-layout>", "<segy-layout>&#12</segy-layout>"]:
    doAssertRaises ValueError: discard parseLayout(bad)
  doAssert parseLayout("<segy-layout><desc>&#65;&#x42;</desc></segy-layout>").desc == "AB"
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "Layout", "<segy-layout>&#99999999999;</segy-layout>", "text/xml")
  ext.addEndText()
  let path = tmp / "hostile.sgy"
  discard makeFile(ext, initExtendedTextHeader(), -1, 0).write(path, SegyWriteOptions())
  let d = readSegy(path)
  doAssert d.traces.len == 3 and d.diagnostics.warned("invalid character reference")

block f2_format_code_edit_is_refused:
  var d = readSegy(exampleDir / "Sweep0.sgy")
  d.file.binary.formatCode = 8
  doAssertRaises SegFormatError: discard d.write(tmp / "fmt.sgy", d.strict)

block f3_last_flag_and_endtext_position:
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

block f4_inconsistent_files_write_back_as_read:
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

block f5_cross_field_problems_are_not_downgraded:
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
  let i = readSegy(ingle)
  discard i.write(tmp / "ingle_le.sgy", SegyWriteOptions(byteOrder: boLittle))
  var le = readSegy(tmp / "ingle_le.sgy")
  le.file.binary.segyMajor = 1
  le.file.binary.segyMinor = 0
  le.file.binary.numExtTextHeaders = 0
  le.file.extended = initExtendedTextHeader()
  doAssertRaises SegFormatError: discard le.write(tmp / "le_rev1.sgy", le.strict)
  # A zero 16-bit interval is fine while the Rev 2 extended one is set;
  # zeroing the extended one is a new problem.
  var z = readSegy(ingle)
  z.file.binary.sampleInterval = 0
  discard z.write(tmp / "dt16zero.sgy", z.strict)
  var z2 = readSegy(tmp / "dt16zero.sgy")
  discard z2.write(tmp / "dt16zero_back.sgy", z2.strict)
  z2.file.binary.extSampleInterval = 0
  doAssertRaises SegFormatError: discard z2.write(tmp / "dtzero.sgy", z2.strict)

block f6_user_data_overrun_is_reported:
  # Count 2: record 1 declares a 4000-byte block, record 2 is EndText.
  var rec = toBytes("((SEG:UserData))<segydescblock><version>1</version>" &
    "<blocksize>4000</blocksize><datalabel>Big</datalabel></segydescblock>")
  rec.setLen 3200
  var ext = initExtendedTextHeader()
  ext.add rec
  ext.addEndText()
  let path = tmp / "overrun.sgy"
  discard makeFile(ext, initExtendedTextHeader(), 2, 0).write(path, SegyWriteOptions(lenient: true))
  let d = readSegy(path)
  doAssert d.traces.len == 3
  doAssert d.diagnostics.warned("runs into the final ((SEG:EndText))")
  let b = d.file.extended.userData[0]
  doAssert b.blockSize == 4000 and b.available < 4000
  doAssertRaises ValueError: discard d.file.extended.userDataBytes(b)
  doAssertRaises ValueError: extractUserData(path, b, tmp / "x.bin")

block f7_corrupt_lengths_do_not_swallow_traces:
  var ext = initExtendedTextHeader()
  var rec = toBytes("((ACME:Blob:application/octet-stream:999999999999))")
  rec.setLen 3200
  ext.add rec
  ext.addEndText()
  let path = tmp / "hugebytes.sgy"
  discard makeFile(ext, initExtendedTextHeader(), -1, 0).write(path, SegyWriteOptions(lenient: true))
  let d = readSegy(path)
  doAssert d.traces.len == 3 and d.diagnostics.warned("beyond the end of the file")
  # An unterminated description block followed by EndText and traces.
  var ext2 = initExtendedTextHeader()
  var r2 = toBytes("((SEG:UserData))")
  r2.setLen 3190
  r2.add toBytes("<segydescb")
  ext2.add r2
  ext2.addEndText()
  let path2 = tmp / "unclosed.sgy"
  discard makeFile(ext2, initExtendedTextHeader(), -1, 0).write(path2, SegyWriteOptions(lenient: true))
  let d2 = readSegy(path2)
  doAssert d2.traces.len == 3 and not d2.diagnostics.isFatal

block f8_wide_scalar_is_not_wrapped:
  var d = readSegy(ingle)
  let xml = """<segy-layout><entry name="co_scal" byte="181" type="int4"/>
<entry name="sht_x" byte="73" type="coor4"/></segy-layout>"""
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "Layout", xml, "text/xml")
  ext.addEndText()
  d.file.extended = ext
  d.file.binary.numExtTextHeaders = int16(ext.recordCount)
  d.traces[0].header.cdpX = 1_000_000 # read as an int4 scalar: out of int16 range
  let path = tmp / "widescalar.sgy"
  discard d.write(path, d.strict)
  let e = readSegy(path)
  var v: float64
  doAssert e.file.fieldValue(e.traces[0], "sht_x", v)
  doAssert v == float64(e.traces[0].header.sourceX) # scalar ignored, not wrapped

block f10_long_first_description_block:
  var desc = UserDataBlock(version: "1", dataFormat: "text-x", dataLabel: "Long",
    description: repeat("a", 5000), creator: "t")
  var tr = initExtendedTextHeader()
  tr.addUserData(@[(desc, toBytes("payload"))])
  var ext = initExtendedTextHeader()
  ext.addEndText()
  let path = tmp / "longdesc.sgy"
  discard makeFile(ext, tr, 1, -1).write(path, SegyWriteOptions())
  let d = readSegy(path)
  doAssert d.traces.len == 3 and d.file.trailer.userData.len == 1
  doAssert d.file.trailer.userDataBytes(d.file.trailer.userData[0]) == toBytes("payload")

block f11_extension_names_ignore_case:
  let lay = parseLayout("""<segy-layout><extension name="acme0001">
<entry name="x" byte="1" type="int4"/></extension></segy-layout>""")
  doAssert lay.entries[0].extension == "ACME0001"
