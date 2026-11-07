import std/[os]
import parseSEGD/common/errors
import parseSEGD/io/[diskio]
import parseSEGD/segy/[reader, writer]

let tmp = getTempDir() / "probe_b"
createDir(tmp)
proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc makeFile(ext: ExtendedTextHeader, nExt: int16, major = 2'u8, order = boBig): SegyData =
  var f = SegyFile(byteOrder: order, format: sfInt16, formatKnown: true)
  f.text = initTextHeader(teAscii)
  f.binary = SegyBinaryHeader(segyMajor: major, segyMinor: (if major == 2: 1 else: 0), formatCode: 3, sampleInterval: 500,
    samplesPerTrace: 4, fixedLengthTraces: 1, numExtTextHeaders: nExt,
    byteOrderMarker: (if major == 2: ByteOrderMarker else: 0))
  f.extended = ext
  result.file = f
  for k in 0..<3:
    var t = SegyTrace(index: k, numSamples: 4)
    t.header.traceSeqFile = int32(k + 1)
    t.header.numSamples = 4
    t.samples = newSeq[byte](8)
    for i in 0..<4: putNum(t.samples, 2 * i, int16(10 * k + i), order)
    result.traces.add t

proc write(d: SegyData, path: string, lenient = false, f: SegyFile) =
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, f, initSegyWriteOptions(f, lenient))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()
proc write(d: SegyData, path: string, lenient = false) = d.write(path, lenient, d.file)

proc tryWrite(name: string, d: SegyData, f: SegyFile) =
  try:
    d.write(tmp / (name & "_out.sgy"), false, f)
    echo name, ": strict write OK"
  except SegFormatError as e: echo name, ": strict write refused: ", e.msg

block b1_count_vs_offset:
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "A", "a")
  ext.addText("SEG", "B", "b")
  ext.addEndText()
  var d = makeFile(ext, 2)
  d.file.binary.firstTraceOffset = 3600 + 3 * 3200
  d.write(tmp / "b1.sgy", lenient = true)
  let e = readSegy(tmp / "b1.sgy")
  echo "B1 read traces=", e.traces.len, " ext=", e.file.extended.recordCount, " diags=", e.diagnostics.len
  tryWrite("B1", e, e.file)

block b2_format_edit:
  var d = makeFile(initExtendedTextHeader(), 0)
  d.write(tmp / "b2.sgy")
  var e = readSegy(tmp / "b2.sgy")
  var f = e.file
  f.binary.formatCode = 8 # 1-byte ints; f.format still int16
  tryWrite("B2", e, f)
  let g = readSegy(tmp / "B2_out.sgy")
  echo "B2 reread traces=", g.traces.len, " ns0=", (if g.traces.len > 0: g.traces[0].numSamples else: -1), " fatal=", g.diagnostics.isFatal, " firstSample=", (if g.traces.len>0: $g.samples[0,0] & "," & $g.samples[0,1] else: "")

block b3_revision_edit_marker:
  var d = makeFile(initExtendedTextHeader(), 0, major = 1, order = boLittle)
  d.write(tmp / "b3.sgy", lenient = true)
  var e = readSegy(tmp / "b3.sgy")
  echo "B3 order=", e.file.byteOrder
  var f = e.file
  f.binary.segyMajor = 2
  f.binary.segyMinor = 1
  tryWrite("B3", e, f)

block b3b_rev2le_to_rev1:
  var d = makeFile(initExtendedTextHeader(), 0, major = 2, order = boLittle)
  d.write(tmp / "b3b.sgy")
  var e = readSegy(tmp / "b3b.sgy")
  var f = e.file
  f.binary.segyMajor = 1
  f.binary.segyMinor = 0
  tryWrite("B3b", e, f)

block b4_last_trace_flag:
  var d = makeFile(initExtendedTextHeader(), 0)
  d.file.binary.maxAddlTraceHeaders = 1
  for t in d.traces.mitems:
    t.hasExt1 = true
    t.ext1 = initTraceHeaderExt1()
  d.traces[0].ext1.lastTraceFlag = LastInFile
  tryWrite("B4", d, d.file)
  let g = readSegy(tmp / "B4_out.sgy")
  echo "B4 reread traces=", g.traces.len, " of ", d.traces.len, " diags=", g.diagnostics.len

block b5_endtext_in_middle:
  var ext = initExtendedTextHeader()
  ext.addEndText()
  ext.addText("SEG", "After", "text after endtext")
  ext.addEndText()
  var d = makeFile(ext, -1)
  tryWrite("B5", d, d.file)
  let g = readSegy(tmp / "B5_out.sgy")
  echo "B5 reread ext=", g.file.extended.recordCount, " of ", ext.recordCount, " traces=", g.traces.len, " fatal=", g.diagnostics.isFatal

block b6_count_edit_to_minus1:
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "A", "a")
  var d = makeFile(ext, 1, major = 1)
  d.write(tmp / "b6.sgy")
  var e = readSegy(tmp / "b6.sgy")
  var f = e.file
  f.binary.numExtTextHeaders = -1
  tryWrite("B6", e, f)

block b7_declared_traces_short:
  var d = makeFile(initExtendedTextHeader(), 0)
  d.file.binary.numTraces = 5
  d.write(tmp / "b7.sgy", lenient = true)
  let e = readSegy(tmp / "b7.sgy")
  echo "B7 read traces=", e.traces.len, " diags=", e.diagnostics.len
  tryWrite("B7", e, e.file)

block b8_ext_sample_interval_zeroed:
  var d = makeFile(initExtendedTextHeader(), 0)
  d.file.binary.sampleInterval = 0
  d.file.binary.extSampleInterval = 500.0
  d.write(tmp / "b8.sgy")
  var e = readSegy(tmp / "b8.sgy")
  var f = e.file
  f.binary.extSampleInterval = 0
  tryWrite("B8", e, f)
