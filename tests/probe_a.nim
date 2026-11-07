import std/[os, strutils]
import parseSEGD/common/errors
import parseSEGD/io/[records, diskio]
import parseSEGD/segy/[reader, writer]

let tmp = getTempDir() / "probe_a"
createDir(tmp)
proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)
proc readBytes(path: string): seq[byte] = toBytes(readFile(path))

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
    t.header.traceSeqFile = int32(k + 1)
    t.header.numSamples = 4
    t.samples = newSeq[byte](8)
    for i in 0..<4: putNum(t.samples, 2 * i, int16(10 * k + i), boBig)
    result.traces.add t

proc write(d: SegyData, path: string, lenient = false) =
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file, lenient))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()

proc dump(e: SegyData) =
  for x in e.diagnostics: echo "   ", x

block a1_userdata_overrun_positive_count:
  var rec = toBytes("((SEG:UserData))<segydescblock><version>1</version><blocksize>4000</blocksize><datalabel>X</datalabel></segydescblock>HELLO")
  rec.setLen 3200
  var ext = initExtendedTextHeader()
  ext.add rec
  ext.addEndText()
  let d = makeFile(ext, initExtendedTextHeader(), 2, 0)
  let p = tmp / "a1.sgy"
  d.write(p, lenient = true)
  let e = readSegy(p)
  echo "A1 traces=", e.traces.len, " issues=", e.file.extended.issues.len, " ud=", e.file.extended.userData.len, " diags=", e.diagnostics.len
  e.dump
  try:
    extractUserData(p, e.file.extended.userData[0], tmp / "a1.bin")
    echo "A1 extracted ", readBytes(tmp / "a1.bin").len, " bytes silently (file len ", readBytes(p).len, ")"
  except CatchableError as x: echo "A1 extract raised ", x.msg

block a2_huge_binary_stanza_variable_count:
  var rec = toBytes("((ACME:Blob:application/octet-stream:999999999999))")
  rec.setLen 3200
  var ext = initExtendedTextHeader()
  ext.add rec
  ext.addEndText()
  let d = makeFile(ext, initExtendedTextHeader(), -1, 0)
  let p = tmp / "a2.sgy"
  d.write(p, lenient = true)
  let e = readSegy(p)
  echo "A2 traces=", e.traces.len, " extRecs=", e.file.extended.recordCount, " fatal=", e.diagnostics.isFatal
  e.dump

block a2b_unclosed_desc_before_endtext:
  var rec = toBytes("((SEG:UserData))")
  rec.setLen 3200
  for i in 16..<3200: rec[i] = 0x20
  for i in 0..<15: rec[3200-15+i] = byte("<segydescblock>"[i])
  var ext = initExtendedTextHeader()
  ext.add rec
  ext.addEndText()
  echo "A2b hasEndText=", ext.hasEndText, " issues=", ext.issues.len, " inBinary=", ext.inBinaryStanza
  let d = makeFile(ext, initExtendedTextHeader(), -1, 0)
  let p = tmp / "a2b.sgy"
  d.write(p, lenient = true)
  let e = readSegy(p)
  echo "A2b traces=", e.traces.len, " extRecs=", e.file.extended.recordCount
  e.dump

block a3_blocksize0_at_record_end_then_endtext:
  # chain whose last desc ends exactly at the record end, blocksize 0
  let head = "((SEG:UserData))"
  let dx = "<segydescblock><blocksize>0</blocksize><datalabel>Z</datalabel></segydescblock>"
  var s = head
  while s.len + dx.len <= 3200: s.add " "
  s = s[0 ..< 3200 - dx.len] & dx
  var rec = toBytes(s)
  doAssert rec.len == 3200
  var ext = initExtendedTextHeader()
  ext.add rec
  ext.addEndText()
  echo "A3 ud=", ext.userData.len, " endText=", ext.hasEndText, " issues=", ext.issues.len, " dataEnd=", ext.stanzas[0].dataEnd
  let d = makeFile(ext, initExtendedTextHeader(), -1, 0)
  let p = tmp / "a3.sgy"
  d.write(p)
  let e = readSegy(p)
  echo "A3 read traces=", e.traces.len, " diags=", e.diagnostics.len

block a4_partial_open_at_end_then_text:
  var rec = toBytes("((SEG:UserData))")
  rec.setLen 3200
  for i in 0..<5: rec[3195+i] = byte("<segy"[i])
  for i in 16..<3195: rec[i] = 0x20
  var ext = initExtendedTextHeader()
  ext.add rec
  var r2 = toBytes("hello world, not a desc block")
  r2.setLen 3200
  ext.add r2
  echo "A4 issues=", ext.issues, " carry inBinary=", ext.inBinaryStanza

block a5_userdata_with_bytes_and_new_stanza:
  var ext = initExtendedTextHeader()
  var rec = toBytes("((SEG:UserData::10000))<segydescblock><blocksize>3</blocksize></segydescblock>abc")
  rec.setLen 3200
  ext.add rec
  ext.addText("SEG", "Note", "after")
  ext.addEndText()
  echo "A5 stanzas=", ext.stanzas.len, " endText=", ext.hasEndText
