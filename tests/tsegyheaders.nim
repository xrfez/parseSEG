## Tests for SEG-Y textual, binary and trace headers (task 3.1).

import std/[assertions, os, strutils]
import parseSEG/common/[endians, fieldlayout, diagnostics]
import parseSEG/segy/[textheader, binheader, traceheader]
import ./utils/testutils


proc checkTiling(fields: openArray[FieldSpec], first, last: int) =
  ## Every byte in first..last belongs to exactly one field.
  var owner = newSeq[string](last - first + 1)
  for f in fields:
    for p in f.specByte..<f.specByte + f.size:
      doAssert p in first..last, f.name & " lies outside the block"
      doAssert owner[p - first] == "", f.name & " overlaps " & owner[p - first]
      owner[p - first] = f.name
  for i, o in owner:
    doAssert o != "", "byte " & $(first + i) & " is not covered"

block byte_orders:
  doAssert getNum[uint32]([1'u8, 2, 3, 4], 0, boBig) == 0x0102_0304'u32
  doAssert getNum[uint32]([4'u8, 3, 2, 1], 0, boLittle) == 0x0102_0304'u32
  doAssert getNum[uint32]([2'u8, 1, 4, 3], 0, boPairSwapped) == 0x0102_0304'u32
  doAssert getNum[uint64]([2'u8, 1, 4, 3, 6, 5, 8, 7], 0, boPairSwapped) ==
    0x0102_0304_0506_0708'u64
  doAssert getNum[uint64]([8'u8, 7, 6, 5, 4, 3, 2, 1], 0, boLittle) ==
    0x0102_0304_0506_0708'u64
  doAssert getNum[uint8]([0xAB'u8], 0, boLittle) == 0xAB
  for order in ByteOrder:
    var b = newSeq[byte](8)
    putNum(b, 0, -12345'i16, order)
    doAssert getNum[int16](b, 0, order) == -12345
    putNum(b, 0, -123456789'i32, order)
    doAssert getNum[int32](b, 0, order) == -123456789
    putNum(b, 0, 2000.5'f64, order)
    doAssert getNum[float64](b, 0, order) == 2000.5
    putNum(b, 0, -1.25'f32, order)
    doAssert getNum[float32](b, 0, order) == -1.25'f32
  var b = newSeq[byte](4)
  putNum(b, 0, 0x0102_0304'u32, boPairSwapped)
  doAssert b == @[2'u8, 1, 4, 3]

block layouts_tile_their_blocks:
  var bin = @binaryHeaderFields
  bin.add FieldSpec(name: "maxAddlTraceHeaders", specByte: 3507, size: 2, kind: fkUInt)
  bin.add FieldSpec(name: "surveyType", specByte: 3509, size: 2, kind: fkUInt)
  checkTiling(bin, 3201, 3600)
  checkTiling(traceHeaderFields, 1, 240)
  checkTiling(traceHeaderExt1Fields, 1, 240)
  doAssert traceHeaderFields[^1].kind == fkText

block text_header_basics:
  var h = initTextHeader(teEbcdic)
  doAssert h.data[0] == 0xC3 # EBCDIC 'C'
  doAssert h.card(1) == "C 1 " & spaces(76)
  doAssert h.card(40).startsWith("C40 ")
  h.setCard(39, cardPrefix(39) & "SEG-Y_REV2.1")
  doAssert h.card(39).startsWith("C39 SEG-Y_REV2.1  ")
  doAssert detectTextEncoding(h.data) == teEbcdic
  let back = decodeTextHeader(h.data)
  doAssert back.encoding == teEbcdic and back.text == h.text
  var a = initTextHeader(teAscii)
  doAssert a.data[0] == byte('C')
  a.text = "hello"
  doAssert a.text.len == TextHeaderSize and a.text.startsWith("hello ")
  # Without a leading 'C' the printable-character count decides.
  doAssert detectTextEncoding(encodeText("  some text here", teEbcdic)) == teEbcdic
  doAssert detectTextEncoding(encodeText("  some text here", teAscii)) == teAscii

sampleBlock sweep0_rev0_little_endian:
  let f = readBytes(exampleDir / "Sweep0.sgy")
  let t = decodeTextHeader(f)
  doAssert t.encoding == teAscii
  doAssert t.card(1).startsWith("C 1 INSTRUMENT:")
  let bh = decodeBinaryHeader(f.toOpenArray(3200, 3599), boLittle)
  doAssert bh.revision == SegyRevision(major: 0, minor: 0)
  doAssert bh.sampleInterval == 1000 and bh.samplesPerTrace == 12001
  doAssert bh.formatCode == 5 and bh.auxTracesPerEnsemble == 1
  doAssert bh.measurementSystem == 2
  doAssert bh.effectiveSamplesPerTrace == 12001 and bh.effectiveSampleInterval == 1000.0
  var log: DiagLog
  bh.validate(log)
  doAssert log.len == 0, $log.len
  let th = decodeTraceHeader(f.toOpenArray(3600, 3839), boLittle)
  doAssert th.traceSeqLine == 1 and th.traceSeqFile == 1 and th.fieldRecord == 1
  doAssert th.traceNumberInField == 1 and th.traceIdCode == 6
  doAssert th.numSamples == 12001 and th.sampleInterval == 1000
  doAssert 3600 + 240 + int(th.numSamples) * 4 == f.len
  # Lossless round trip of every header block.
  var tb = newSeq[byte](TextHeaderSize)
  t.encode(tb)
  doAssert tb == f[0..<3200]
  var bb = newSeq[byte](BinaryHeaderSize)
  bh.encode(bb, boLittle)
  doAssert bb == f[3200..<3600]
  var hb = newSeq[byte](TraceHeaderSize)
  th.encode(hb, boLittle)
  doAssert hb == f[3600..<3840]

sampleBlock inglewood_rev21_big_endian:
  let f = readBytes(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let t = decodeTextHeader(f)
  doAssert t.encoding == teEbcdic
  doAssert t.card(1).startsWith("C01 AREA    : Taranaki_Basin")
  let bh = decodeBinaryHeader(f.toOpenArray(3200, 3599), boBig)
  doAssert bh.revision == SegyRevision(major: 2, minor: 1)
  doAssert SegyRevision(major: 1, minor: 0) < bh.revision
  doAssert bh.byteOrderMarker == ByteOrderMarker
  doAssert bh.lineNumber == 360 and bh.reelNumber == 7
  doAssert bh.dataTracesPerEnsemble == 227 and bh.formatCode == 1
  doAssert bh.extSamplesPerTrace == 2001 and bh.extSampleInterval == 2000.0
  doAssert bh.effectiveSamplesPerTrace == 2001 and bh.effectiveDataTracesPerEnsemble == 227
  doAssert bh.fixedLengthTraces == 1 and bh.numExtTextHeaders == -1
  doAssert bh.maxAddlTraceHeaders == 0 and bh.surveyType == 0
  doAssert bh.numTraces == 0 and bh.firstTraceOffset == 0 and bh.numTrailerRecords == 0
  var log: DiagLog
  bh.validate(log)
  doAssert log.len == 0, $log.len
  var bb = newSeq[byte](BinaryHeaderSize)
  bh.encode(bb, boBig)
  doAssert bb == f[3200..<3600]
  # Reading the binary header in another order breaks the marker.
  bh.validate(log)
  decodeBinaryHeader(f.toOpenArray(3200, 3599), boLittle).validate(log)
  doAssert log.len > 0
  # 200 traces of 240 + 2001*4 bytes start at 333200.
  const first = 333200
  const recLen = 240 + 2001 * 4
  doAssert first + 200 * recLen == f.len
  let th0 = decodeTraceHeader(f.toOpenArray(first, first + 239), boBig)
  doAssert th0.traceSeqLine == 1 and th0.traceSeqFile == 1
  doAssert th0.traceNumberInField == 1001 and th0.energySourcePoint == 1
  doAssert th0.ensembleNumber == 1001001 and th0.traceIdCode == 1
  doAssert th0.sourceX == 1704047 and th0.sourceY == 5669430 and th0.groupY == 6231174
  doAssert th0.numSamples == 2001 and th0.sampleInterval == 2000
  doAssert th0.headerNameText == ""
  for k in 0..<200:
    let pos = first + k * recLen
    let raw = f[pos..<pos + 240]
    let th = decodeTraceHeader(raw, boBig)
    doAssert th.traceSeqFile == int32(k + 1)
    var enc = newSeq[byte](240)
    th.encode(enc, boBig)
    doAssert enc == raw, "trace " & $k
    for order in [boLittle, boPairSwapped]:
      th.encode(enc, order)
      doAssert decodeTraceHeader(enc, order) == th

block rev20_vs_rev21_bytes_3507_3510:
  var h = SegyBinaryHeader(segyMajor: 2, segyMinor: 0, maxAddlTraceHeaders: 70000,
    byteOrderMarker: ByteOrderMarker, formatCode: 5, sampleInterval: 1000,
    samplesPerTrace: 10)
  var b = newSeq[byte](BinaryHeaderSize)
  h.encode(b, boBig)
  doAssert beU32(b, 3507 - 3201) == 70000
  doAssert decodeBinaryHeader(b, boBig) == h
  h.encode(b, boLittle)
  doAssert decodeBinaryHeader(b, boLittle) == h
  h.revision = SegyRevision(major: 2, minor: 1)
  h.maxAddlTraceHeaders = 3
  h.surveyType = 1 + 8 + 128
  h.encode(b, boBig)
  doAssert beU16(b, 3507 - 3201) == 3 and beU16(b, 3509 - 3201) == 137
  doAssert decodeBinaryHeader(b, boBig) == h
  # A Rev 2.0 file read as 2.1 would split the u32; the branch prevents it.
  b[3501 - 3201] = 2
  b[3502 - 3201] = 0
  doAssert decodeBinaryHeader(b, boBig).maxAddlTraceHeaders == 0x0003_0089'u32

block effective_values_respect_revision:
  var h = SegyBinaryHeader(samplesPerTrace: 1000, extSamplesPerTrace: 70000,
    sampleInterval: 500, extSampleInterval: 0.25)
  doAssert h.effectiveSamplesPerTrace == 1000 # Rev 1: ext fields are unassigned.
  doAssert h.effectiveSampleInterval == 500.0
  h.segyMajor = 2
  doAssert h.effectiveSamplesPerTrace == 70000
  doAssert h.effectiveSampleInterval == 0.25
  h.extSamplesPerTrace = 0
  doAssert h.effectiveSamplesPerTrace == 1000

block binary_validation:
  var h = SegyBinaryHeader(segyMajor: 1, formatCode: 7, sampleInterval: 0,
    samplesPerTrace: 100, extSamplesPerTrace: 0, numExtTextHeaders: -5)
  var log: DiagLog
  h.validate(log, sevError, Location(file: "x.sgy"))
  # An extended count below -1 makes "Rev 1" in 3501-3502 vendor data: Rev 0
  # rules, so the Rev 1 fields are not checked (segy_rev0.md §9.2).
  doAssert h.rulesRevision == SegyRevision(major: 0)
  doAssert log.len == 3 and log[0].code == dcUnsupportedRevision and log[0].offset == 3500
  log = DiagLog()
  h.numExtTextHeaders = 0
  h.fixedLengthTraces = 1
  h.validate(log, sevError, Location(file: "x.sgy"))
  doAssert log.len == 2
  doAssert log[0].code == dcBadValue and log[0].offset == 3224
  doAssert log[0].loc.field == "binary.formatCode" and log[0].loc.file == "x.sgy"
  doAssert log[0].severity == sevError
  var log2: DiagLog
  SegyBinaryHeader(segyMajor: 2, segyMinor: 1, formatCode: 5, sampleInterval: 1,
    samplesPerTrace: 1, byteOrderMarker: ByteOrderMarker,
    maxAddlTraceHeaders: 70000).validate(log2)
  doAssert log2.len == 1 and log2[0].loc.field == "binary.maxAddlTraceHeaders"
  doAssert bytesPerSample(7, SegyRevision(major: 2, minor: 1)) == 3
  doAssert bytesPerSample(7, SegyRevision(major: 1)) == 0

block revision_bytes_task_3_5:
  # 2.0 written as a swapped u16 (00 02) is Rev 2.0, like 01 02 for 2.1.
  var h = SegyBinaryHeader(segyMajor: 0, segyMinor: 2, byteOrderMarker: ByteOrderMarker)
  doAssert h.rulesRevision == SegyRevision(major: 2, minor: 0)
  # A 2.x claim without the byte-order marker (vendor bytes) is Rev 0.
  h = SegyBinaryHeader(segyMajor: 2, segyMinor: 1, byteOrderMarker: 0x55AA55AA'u32)
  doAssert h.rulesRevision == SegyRevision(major: 0)
  h.byteOrderMarker = 0 # not written by some 2.x writers
  doAssert h.rulesRevision == SegyRevision(major: 2, minor: 1)
  # 2.0's u32 at 3507-3510 also for 00 02.
  var b = newSeq[byte](400)
  SegyBinaryHeader(segyMajor: 0, segyMinor: 2, byteOrderMarker: ByteOrderMarker,
    maxAddlTraceHeaders: 70000, formatCode: 5).encode(b, boBig)
  doAssert decodeBinaryHeader(b, boBig).maxAddlTraceHeaders == 70000

block scalars:
  doAssert applyScalar(1234, -100) == 12.34
  doAssert applyScalar(12, 10) == 120.0
  doAssert applyScalar(7, 0) == 7.0
  let th = SegyTraceHeader(coordinateScalar: -10, sourceX: 12345, shotpointNumber: 155,
    shotpointScalar: -10, timeScalar: 0, delayRecordingTime: -40)
  doAssert th.scaleCoordinate(th.sourceX) == 1234.5
  doAssert th.shotpoint == 15.5
  doAssert th.scaleTime(th.delayRecordingTime) == -40.0

block header_name_text:
  var th: SegyTraceHeader
  for i, c in "SEG00000": th.headerName[i] = c
  doAssert th.headerNameText == "SEG00000"
  let e = encodeText("SEG00001", teEbcdic)
  for i in 0..7: th.headerName[i] = char(e[i])
  doAssert th.headerNameText == "SEG00001"

block ext1_round_trips_in_every_order:
  var e = initTraceHeaderExt1()
  e.extTraceSeqLine = 12_345_678_901'u64
  e.extFieldRecord = -7
  e.receiverDepth = 12.5
  e.extSourceX = 512_345.678
  e.extNumSamples = 100_000
  e.nanoseconds = -250
  e.extSampleInterval = 0.125
  e.numAddlTraceHeaders = 2
  e.lastTraceFlag = LastInFile or LastInLine
  e.extCdpY = -1.0e-3
  for order in ByteOrder:
    var b = newSeq[byte](240)
    e.encode(b, order)
    doAssert decodeTraceHeaderExt1(b, order) == e
    doAssert b[232..239] == @[byte('S'), byte('E'), byte('G'), byte('0'), byte('0'),
      byte('0'), byte('0'), byte('1')] # names are never reordered
  doAssert e.headerNameText == "SEG00001"
  var raw = newSeq[byte](240)
  for i, c in "ACME0001": raw[232 + i] = byte(c)
  doAssert headerBlockName(raw) == "ACME0001"
