## SEG-Y User Data (D-9) in extended headers and trailers (task 3.4b).

import std/[assertions, os, strutils]
import parseSEG/common/[errors, diagnostics, endians]
import parseSEG/io/[records, diskio, tapeimage]
import parseSEG/common/tensors
import parseSEG/segy/[reader, writer]
import ./utils/testutils

let tmp = scratchDir("parseseg_tsegyuserdata")

proc nastyBlob(n: int): seq[byte] =
  ## Binary data full of things a careless walker would trip on.
  result = newSeq[byte](n)
  for i in 0..<n: result[i] = byte((i * 7919) mod 256)
  let traps = ["((SEG:EndText))", "<segydescblock>", "((SEG:UserData))"]
  var p = 0
  for t in traps:
    if p + t.len <= n:
      for i, c in t: result[p + i] = byte(c)
    p += 3200 - 16
  for i in 1000..<min(1400, n): result[i] = 0 # a NUL run

proc desc(label, format: string): UserDataBlock =
  UserDataBlock(version: "1", dataFormat: format, dataLabel: label,
    description: "test attachment " & label, creationTime: "2026-11-07 12:00:00Z",
    creator: "parseSEG tests")

proc makeFile(ext, trailer: ExtendedTextHeader, nExt: int16, nTrailer: int32): SegyData =
  ## A Rev 2.1 file with 3 fixed-length traces of 4 int16 samples.
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
    t.header.traceSeqFile = int32(k + 1)
    t.header.numSamples = 4
    t.samples = newSeq[byte](8)
    for i in 0..<4: putNum(t.samples, 2 * i, int16(10 * k + i), boBig)
    result.traces.add t

proc write(d: SegyData, sink: RecordSink) =
  var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()

let items = @[
  UserDataItem(desc: desc("SurvPars", "text-xml"),
    data: toBytes("<survey><area>Test</area></survey>")),
  UserDataItem(desc: desc("Blob", "bin-le-other"), data: nastyBlob(10_000)),
  UserDataItem(desc: desc("Empty", "text-us-ascii"), data: newSeq[byte]()),
  UserDataItem(desc: desc("ObsLog", "text-iso-8859-1"),
    data: toBytes("11:38 Start of line\r\n12:03 Missed shots\r\n"))]

block user_data_in_extended_header_with_variable_count:
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "Catalog", "{}", "application/json")
  ext.addUserData(items)
  ext.addEndText()
  let d = makeFile(ext, initExtendedTextHeader(), -1, 0)
  let path = tmp / "ext_userdata.sgy"
  d.write(openDiskSink(path))
  let e = readSegy(path)
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.traces.len == 3 and e.samples[2, 3] == 23'f32
  let x = e.file.extended
  doAssert x.recordCount == ext.recordCount and x.hasEndText
  doAssert x.stanzas.len == 3 and x.stanzas[1].isUserData
  doAssert x.userData.len == 4
  for i, it in items:
    let (dsc, data) = (it.desc, it.data)
    let b = x.userData[i]
    doAssert b.dataLabel == dsc.dataLabel and b.dataFormat == dsc.dataFormat
    doAssert b.blockSize == data.len and b.creator == "parseSEG tests"
    doAssert b.dataVersion == "1" and b.stanza == 1
    doAssert x.userDataBytes(b) == data
    extractUserData(path, b, tmp / "extracted.bin")
    doAssert readBytes(tmp / "extracted.bin") == data
  # Byte-identical rewrite.
  e.write(openDiskSink(tmp / "ext_userdata2.sgy"))
  doAssert readBytes(tmp / "ext_userdata2.sgy") == readBytes(path)

block user_data_in_trailer:
  for nTrailer in [-1'i32, 0]:
    var tr = initExtendedTextHeader()
    tr.addUserData(items, "UserHeader")
    let n = if nTrailer == 0: int32(tr.recordCount) else: nTrailer
    var ext = initExtendedTextHeader()
    ext.addEndText()
    let d = makeFile(ext, tr, 1, n)
    let path = tmp / "trailer_userdata.sgy"
    d.write(openDiskSink(path))
    let e = readSegy(path)
    doAssert e.log.len == 0, $e.log[0]
    doAssert e.traces.len == 3
    doAssert e.file.trailer.recordCount == tr.recordCount
    doAssert e.file.trailer.userData.len == 4
    let blob = e.file.trailer.userData[1]
    doAssert e.file.trailer.userDataBytes(blob) == items[1].data
    doAssert blob.mediumOffset == int64(3600 + 3200 + 3 * (240 + 8) + blob.dataStart)

block description_block_split_across_records:
  # Size the first attachment so the second description block straddles
  # the record boundary at 3200.
  let header = "((SEG:UserData))"
  var first = desc("A", "bin-x")
  first.blockSize = 0
  let firstXmlLen = toDescXml(first).len + 2 # blocksize grows from "0" to 3 digits
  let n1 = 3200 - 40 - header.len - firstXmlLen
  let two = @[UserDataItem(desc: desc("A", "bin-x"), data: nastyBlob(n1)),
    UserDataItem(desc: desc("B", "text-x"), data: toBytes("hello"))]
  var tr = initExtendedTextHeader()
  tr.addUserData(two)
  doAssert tr.userData.len == 2
  doAssert tr.userData[1].descStart < 3200 and tr.userData[1].dataStart > 3200
  doAssert tr.userDataBytes(tr.userData[1]) == toBytes("hello")
  doAssert tr.issues.len == 0

block spec_style_stanza_with_line_break:
  # The spec examples put a line break after the stanza name and use the
  # Rev 1 style name.
  var text = "((SEG:User Data ver 1.0))\r\n<segydescblock>\r\n  <version>1</version>\r\n" &
    "  <blocksize>5</blocksize>\r\n  <dataformat>text-us-ascii</dataformat>\r\n" &
    "  <datalabel>Tiny</datalabel>\r\n  <creationtime>2015-10-03 00:00:00Z</creationtime>\r\n" &
    "  <creator>DataProc</creator>\r\n</segydescblock>HELLO"
  var rec = toBytes(text)
  rec.setLen 3200
  var h = initExtendedTextHeader()
  h.add rec
  doAssert h.userData.len == 1 and h.issues.len == 0
  doAssert h.userData[0].dataLabel == "Tiny" and h.userDataBytes(h.userData[0]) == toBytes("HELLO")

block malformed_description_is_reported:
  var rec = toBytes("((SEG:UserData))<segydescblock><version>1</version></segydescblock>xx")
  rec.setLen 3200
  var h = initExtendedTextHeader()
  h.add rec
  doAssert h.userData.len == 0 and h.issues.len == 1
  doAssert "blocksize" in h.issues[0].msg

block retention_limit_indexes_without_holding:
  let big = nastyBlob(100_000)
  var tr = initExtendedTextHeader()
  tr.addUserData(@[UserDataItem(desc: desc("Big", "bin-tar"), data: big),
    UserDataItem(desc: desc("After", "text-x"), data: toBytes("tail"))])
  var ext = initExtendedTextHeader()
  ext.addEndText()
  let d = makeFile(ext, tr, 1, int32(tr.recordCount))
  let path = tmp / "big_trailer.sgy"
  d.write(openDiskSink(path))
  let e = readSegy(path, maxRetained = 16 * 1024)
  doAssert e.traces.len == 3 and not e.log.hasErrors
  let t = e.file.trailer
  doAssert not t.isComplete and t.recordCount == tr.recordCount
  doAssert t.userData.len == 2 and t.userData[0].blockSize == 100_000
  doAssert not t.isRetained(t.userData[0])
  doAssertRaises ValueError: discard t.userDataBytes(t.userData[0])
  extractUserData(path, t.userData[0], tmp / "big.bin")
  doAssert readBytes(tmp / "big.bin") == big
  extractUserData(path, t.userData[1], tmp / "after.bin")
  doAssert readBytes(tmp / "after.bin") == toBytes("tail")
  var sawInfo = false
  for x in e.log:
    if x.severity == sevInfo and x.loc.field == "trailer": sawInfo = true
  doAssert sawInfo
  # A partly held file cannot be rewritten from memory.
  doAssertRaises SegFormatError:
    discard openSegyWriter(openDiskSink(tmp / "nope.sgy"), e.file,
      initSegyWriteOptions(e.file, lenient = true))

block huge_declared_attachment_is_bounded:
  # A 5 GB attachment declared in a 30 KB file: the read stops at the end of
  # the file without allocating gigabytes.
  var tr = initExtendedTextHeader()
  tr.addUserData(@[UserDataItem(desc: desc("Huge", "bin-tar"), data: nastyBlob(20_000))])
  var ext = initExtendedTextHeader()
  ext.addEndText()
  let d = makeFile(ext, tr, 1, -1)
  let path = tmp / "huge.sgy"
  d.write(openDiskSink(path))
  var b = readBytes(path)
  let s = cast[string](b)
  let at = s.find("<blocksize>20000</blocksize>")
  doAssert at > 0
  let patchedText = "<blocksize>5000000000</blocksize>"
  var s2 = s[0 ..< at] & patchedText & s[at + "<blocksize>20000</blocksize>".len .. ^1]
  # Keep the record layout: drop as many bytes from the end as were added.
  s2.setLen s.len
  writeFile(path, s2)
  let e = readSegy(path, maxRetained = 8 * 1024)
  doAssert e.traces.len == 3 and not e.log.isFatal
  # On disk the declared size is checked against the file: not indexed, warned.
  doAssert e.file.trailer.userData.len == 0
  var warned = false
  for x in e.log:
    if x.severity == sevWarning and "beyond the end of the file" in x.msg: warned = true
  doAssert warned

block tape_image_round_trip:
  var tr = initExtendedTextHeader()
  tr.addUserData(items)
  var ext = initExtendedTextHeader()
  ext.addUserData(items[0..1])
  ext.addEndText()
  let d = makeFile(ext, tr, -1, -1)
  let tap = tmp / "userdata.tap"
  d.write(openTapeImageSink(tap))
  var src: RecordSource = openTapeImageSource(tap)
  let e = readSegy(src)
  src.close()
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.traces.len == 3
  doAssert e.file.extended.userData.len == 2 and e.file.trailer.userData.len == 4
  doAssert e.file.trailer.userData[1].mediumOffset == -1 # tape: no file offsets
  doAssert e.file.trailer.userDataBytes(e.file.trailer.userData[1]) == items[1].data
