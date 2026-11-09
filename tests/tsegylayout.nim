## SEG-Y trace header layouts and named values (task 3.4d).

import std/[assertions, os, math, sequtils, strutils]
import parseSEG/common/[diagnostics, endians]
import parseSEG/io/diskio
import parseSEG/segy/[reader, writer, fields]
import ./utils/testutils

let tmp = scratchDir("parseseg_tsegylayout")

proc write(d: SegyData, path: string) =
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()

proc named(lay: TraceLayout, name: string): seq[LayoutEntry] = toSeq(lay.entriesFor(name))

block standard_layouts:
  let r0 = standardLayout(SegyRevision(major: 0))
  let r1 = standardLayout(SegyRevision(major: 1))
  let r2 = standardLayout(SegyRevision(major: 2, minor: 1))
  doAssert r2.entries.len == 112 and r1.entries.len == 88
  for e in r0.entries: doAssert e.bytePos < 181 and e.kind != ltTime2 and e.extension == ""
  for e in r1.entries: doAssert e.extension == ""
  # Within each header, standard entries never overlap.
  for lay in [r1, r2]:
    for i, a in lay.entries:
      for b in lay.entries[i + 1 .. ^1]:
        if a.extension == b.extension:
          doAssert a.bytePos + a.kind.size <= b.bytePos or b.bytePos + b.kind.size <= a.bytePos,
            a.name & " overlaps " & b.name
  doAssert r2.named("inline").len == 1 and r2.named("iline")[0].bytePos == 189
  doAssert r2.named("sht_x").len == 2 and r2.named("sht_x")[1].ifNonZero

block inglewood_layout_stanza:
  let d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  doAssert d.log.len == 0
  let lay = d.file.layout
  doAssert lay.named("iline")[^1].bytePos == 13 and lay.named("cdp_x")[^1].bytePos == 73
  doAssert lay.named("sht_x").len == 1 # the standard byte 73 entry is dropped
  for k in 0..<200:
    let g = d.file.geometry(d.traces[k])
    doAssert g.inline == 1001.0 and g.crossline == float64(k + 1)
    doAssert g.cdpX == float64(d.traces[k].header.sourceX) # stored at byte 73
    doAssert g.receiverElevation == float64(d.traces[k].header.groupY) # byte 85
    doAssert g.sourceX.isNaN and g.channel.isNaN
  doAssert d.file.fieldValue(d.traces[5], "INLINE") == some(1001.0)
  doAssert d.file.fieldValue(d.traces[5], "no_such_entry").isNone

block standard_values_with_scalars_and_ext1:
  # A Rev 2.1 file without a Layout stanza: standard bytes, scalars, Ext1.
  var d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var f = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boBig,
    format: d.file.format, extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  f.binary.numExtTextHeaders = 0
  f.binary.maxAddlTraceHeaders = 1
  var t = d.traces[0]
  t.header.coordinateScalar = -100
  t.header.sourceX = 123456
  t.header.elevationScalar = 10
  t.header.receiverElevation = 25
  t.header.timeScalar = -10
  t.header.delayRecordingTime = 125
  t.header.shotpointNumber = 1015
  t.header.shotpointScalar = -10
  t.hasExt1 = true
  t.ext1 = initTraceHeaderExt1()
  t.ext1.numAddlTraceHeaders = 1
  t.ext1.extSourceY = 98765.4321 # overrides; std sourceY is unscaled otherwise
  let g = f.geometry(t)
  doAssert g.sourceX == 1234.56 and g.sourceY == 98765.4321
  doAssert g.receiverElevation == 250.0 and g.shotpoint == 101.5
  doAssert f.fieldValue(t, "delay") == some(12.5)
  # Rev 0: time fields are unscaled and bytes 181-240 undefined.
  f.binary.segyMajor = 0
  f.binary.segyMinor = 0
  doAssert f.fieldValue(t, "delay") == some(125.0)
  doAssert f.geometry(t).inline.isNaN

block layout_stanza_with_proprietary_extension:
  var d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let xml = """<?xml version="1.0"?>
<segy-layout name="acme">
  <entry name="inline" byte="9" type="int4"/>
  <extension name="ACME0001">
    <entry name="gun_depth" byte="1" type="ieee32"/>
    <entry name="gun_pressure" byte="5" type="scale6"/>
  </extension>
</segy-layout>"""
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "Layout", xml, "text/xml")
  ext.addEndText()
  d.file.extended = ext
  d.file.binary.numExtTextHeaders = int16(ext.recordCount)
  d.file.binary.maxAddlTraceHeaders = 2
  for k in 0..<d.traces.len:
    d.traces[k].header.fieldRecord = int32(500 + k)
    d.traces[k].hasExt1 = true
    d.traces[k].ext1 = initTraceHeaderExt1()
    d.traces[k].ext1.numAddlTraceHeaders = 2
    var p = newSeq[byte](240)
    putNum(p, 0, 7.5'f32, boBig)
    putNum(p, 4, 2000'i32, boBig)
    putNum(p, 8, -1'i16, boBig)
    for i, c in "ACME0001": p[232 + i] = byte(c)
    d.traces[k].proprietary = p
  let path = tmp / "acme.sgy"
  d.write(path)
  let e = readSegy(path)
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.file.fieldValue(e.traces[3], "gun_depth") == some(7.5)
  doAssert abs(e.file.fieldValue(e.traces[3], "gun_pressure").get - 200.0) < 1e-9
  doAssert e.file.geometry(e.traces[3]).inline == 503.0

block malformed_layout_falls_back:
  for bad in ["<segy-layout><entry name=\"x\" byte=\"239\" type=\"int4\"/></segy-layout>",
      "<segy-layout><entry name=\"x\" byte=\"1\" type=\"float\"/></segy-layout>",
      "<other/>", "not xml at all <"]:
    doAssertRaises ValueError: discard parseLayout(bad)
  var d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var ext = initExtendedTextHeader()
  ext.addText("SEG", "Layout", "<segy-layout><entry name=\"x\" byte=\"0\" type=\"int4\"/></segy-layout>",
    "text/xml")
  ext.addEndText()
  d.file.extended = ext
  d.file.binary.numExtTextHeaders = int16(ext.recordCount)
  let path = tmp / "badlayout.sgy"
  d.write(path)
  let e = readSegy(path)
  doAssert e.log.len == 1 and e.log[0].loc.field == "extended.layout"
  doAssert e.file.layout.named("iline")[^1].bytePos == 189 # standard layout

# ------------------------------- review of task 3.4 (one block per finding) --

const ingle = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"

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

proc warned(log: DiagLog, text: string): bool =
  for e in log:
    if e.severity == sevWarning and text in e.msg: return true

block segyreview2_f1_hostile_layout_entities:
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
  doAssert d.traces.len == 3 and d.log.warned("invalid character reference")

block segyreview2_f8_wide_scalar_is_not_wrapped:
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
  # scalar ignored, not wrapped
  doAssert e.file.fieldValue(e.traces[0], "sht_x") == some(float64(e.traces[0].header.sourceX))

block segyreview2_f11_extension_names_ignore_case:
  let lay = parseLayout("""<segy-layout><extension name="acme0001">
<entry name="x" byte="1" type="int4"/></extension></segy-layout>""")
  doAssert lay.entries[0].extension == "ACME0001"
