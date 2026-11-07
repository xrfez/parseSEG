import std/[os]
import parseSEGD/io/[diskio]
import parseSEGD/segy/[reader, writer]
let tmp = getTempDir() / "probe_d"
createDir(tmp)
var ext = initExtendedTextHeader()
ext.addText("SEG", "Layout", "<segy-layout>&#99999999999;</segy-layout>", "text/xml")
ext.addEndText()
var f = SegyFile(byteOrder: boBig, format: sfInt16, formatKnown: true)
f.text = initTextHeader(teAscii)
f.binary = SegyBinaryHeader(segyMajor: 2, segyMinor: 1, formatCode: 3, sampleInterval: 500,
  samplesPerTrace: 4, fixedLengthTraces: 1, numExtTextHeaders: 2, byteOrderMarker: ByteOrderMarker)
f.extended = ext
let sink = openDiskSink(tmp / "d.sgy")
var w = openSegyWriter(sink, f, initSegyWriteOptions(f))
w.close(); sink.close()
let e = readSegy(tmp / "d.sgy")
echo "read ok, diags: ", e.diagnostics.len
for d in e.diagnostics: echo d
