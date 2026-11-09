## Format-independent file summary (task 6.8): `summary`, `channelSets` and
## `crsText` on the sample files and on synthetic variants of them.

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tsummary")

const
  s63 = exampleDir / "63.sgd"
  inova = exampleDir / "inova_rev30_5traces.sgd"
  inglewood = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  sweep = exampleDir / "Sweep0.sgy"

proc copyOf(src, name: string): string =
  result = tmp / name
  copyFile(src, result)
  if fileExists(result & ".edits.nif"): removeFile(result & ".edits.nif")

proc edited(src, name: string, edits: openArray[(HeaderScope, int, string, FieldValue)]):
    string =
  ## A copy of `src` with header edits applied (journal removed).
  result = copyOf(src, name)
  var ed = openEditor(result)
  for (scope, i, field, v) in edits:
    let ok = case scope
      of hsFile: ed.setFileField(field, v)
      of hsRecord: ed.setRecordField(i, field, v)
      of hsTrace: ed.setTraceField(i, field, v)
    doAssert ok, field
  ed.close()
  removeFile(result & ".edits.nif")

block segd_rev2_sample:
  # Values as tools/walks/segd2_walk.py prints them for 63.sgd: file 63,
  # format 8058, 1 trace of 1000 samples at 2 ms, record length 2.048 s
  # (GH#1 RR.R 2.0 x 1.024), one channel set 0-2000 ms.
  let f = openSeismic(s63)
  let s = f.summary
  doAssert s.standard == skSegd and $s.revision == "2.0" and not s.mixedRevisions
  doAssert s.byteOrder == boBig and s.formatCode == 8058 and s.decodable
  doAssert s.traceCount == 1 and s.recordCount == 1
  doAssert s.firstFieldRecord == 63 and s.lastFieldRecord == 63
  doAssert s.sampleIntervalUs == 2000 and s.samplesPerTrace == 1000
  doAssert s.recordLengthMs > 0
  doAssert s.coordinateUnits == cuUnknown and s.crsFormat == ctNone and f.crsText == ""
  let cs = f.channelSets
  doAssert cs.len == 1
  doAssert cs[0].number == 1 and cs[0].channelType == 1 and cs[0].traceCount == 1
  doAssert cs[0].samplesPerTrace == 1000 and cs[0].sampleIntervalUs == 2000
  doAssert cs[0].startTimeMs == 0 and cs[0].endTimeMs == 2000

block segd_rev3_sample:
  # tools/walks/segd3_walk.py: file 151, 4 channel sets (aux 0x20, 0x30,
  # 0x70, seismic 0x10), ns 4001 at 1000 µs, extended record length 4 s, a
  # Location Data stanza (EPSG 32050) in 0x55 blocks.
  let f = openSeismic(inova)
  let s = f.summary
  doAssert s.standard == skSegd and s.revision == StandardRevision(major: 3, minor: 0)
  doAssert s.formatCode == 8058 and s.traceCount == 5 and s.recordCount == 1
  doAssert s.firstFieldRecord == 151 and s.lastFieldRecord == 151
  doAssert s.sampleIntervalUs == 1000 and s.samplesPerTrace == 4001 and s.recordLengthMs == 4000
  doAssert s.crsFormat == ctStanza and s.coordinateUnits == cuUnknown
  let crs = f.crsText
  doAssert crs.startsWith("((SEG: Location Data") and "CRS code=32050" in crs
  doAssert crsFormat(crs) == s.crsFormat
  let cs = f.channelSets
  doAssert cs.len == 4
  var types: seq[int]
  var traces = 0
  for c in cs:
    types.add c.channelType
    traces += c.traceCount
    doAssert c.sampleIntervalUs == 1000 and c.endTimeMs == 4000 and c.samplesPerTrace == 4001
  doAssert types == @[0x20, 0x30, 0x70, 0x10] and traces == 5
  doAssert cs[3].traceCount == 2 and cs[3].number == 4

block segy_rev21_sample:
  # tools/walks/segy21_walk.py: big-endian, format 1, dt 2000, ns 2001,
  # measurement system 1 (m), trace bytes 89-90 zero, an OGP P1/11 stanza.
  let f = openSeismic(inglewood)
  let s = f.summary
  doAssert s.standard == skSegy and $s.revision == "2.1" and s.byteOrder == boBig
  doAssert s.formatCode == 1 and s.decodable and s.traceCount == 200 and s.recordCount == 1
  doAssert s.sampleIntervalUs == 2000 and s.samplesPerTrace == 2001 and s.recordLengthMs == 4000
  doAssert s.firstFieldRecord == 0 and s.lastFieldRecord == 0
  doAssert s.coordinateUnits == cuMeters and s.crsFormat == ctP1_11
  doAssert f.crsText.startsWith("IOGP,IOGP P1") and "HC,1,6,1" in f.crsText
  doAssert f.channelSets.len == 0

block segy_rev0_little_endian:
  let f = openSeismic(sweep)
  let s = f.summary
  doAssert $s.revision == "0.0" and s.byteOrder == boLittle and s.formatCode == 5
  doAssert s.sampleIntervalUs == 1000 and s.samplesPerTrace == 12001
  doAssert s.recordLengthMs == 12000 and s.firstFieldRecord == 1
  doAssert s.coordinateUnits == cuFeet # binary 3255 = 2
  doAssert s.crsFormat == ctNone and f.crsText == ""

block segy_coordinate_units:
  template units(path: string): CoordinateUnits = openSeismic(path).summary.coordinateUnits
  let deg = edited(sweep, "deg.sgy", [(hsTrace, 0, "trace.coordinateUnits", toFieldValue(3))])
  doAssert units(deg) == cuDegrees
  let arc = edited(sweep, "arc.sgy", [(hsTrace, 0, "trace.coordinateUnits", toFieldValue(2))])
  doAssert units(arc) == cuArcSeconds
  let dms = edited(sweep, "dms.sgy", [(hsTrace, 0, "trace.coordinateUnits", toFieldValue(4))])
  doAssert units(dms) == cuDms
  let ft = edited(sweep, "ft.sgy", [(hsTrace, 0, "trace.coordinateUnits", toFieldValue(1))])
  doAssert units(ft) == cuFeet
  let length = edited(sweep, "len.sgy", [(hsTrace, 0, "trace.coordinateUnits", toFieldValue(1)),
    (hsFile, 0, "binary.measurementSystem", toFieldValue(0))])
  doAssert units(length) == cuLength
  let none = edited(sweep, "none.sgy", [(hsFile, 0, "binary.measurementSystem", toFieldValue(0))])
  doAssert units(none) == cuUnknown
  # No measurement system: the P1/11 CRS's first axis unit (metre).
  let crs = edited(inglewood, "crs.sgy", [(hsFile, 0, "binary.measurementSystem",
    toFieldValue(0))])
  doAssert units(crs) == cuMeters
  # Field records of the first and last trace.
  let fr = edited(inglewood, "fr.sgy", [(hsTrace, 0, "trace.fieldRecord", toFieldValue(7)),
    (hsTrace, 199, "trace.fieldRecord", toFieldValue(9))])
  let s = openSeismic(fr).summary
  doAssert s.firstFieldRecord == 7 and s.lastFieldRecord == 9

block segy_non_uniform_traces:
  # Variable-length traces: one trace with another interval, one with fewer
  # samples (the fixed-length flag cleared).
  var d = readSegy(inglewood)
  var file = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boBig,
    format: d.file.format, extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  file.binary.numExtTextHeaders = 0
  file.binary.fixedLengthTraces = 0
  let path = tmp / "variable.sgy"
  block write:
    let sink = openDiskSink(path)
    var w = openSegyWriter(sink, file, initSegyWriteOptions(file, lenient = true))
    for k in 0..<3:
      var t = d.traces[k]
      if k == 1:
        t.header.sampleInterval = 4000
        t.sampleInterval = 4000
      w.writeTrace(t)
    w.close()
    sink.close()
  var f = openSeismic(path)
  doAssert f.len == 3 and f.log.len == 0
  var s = f.summary
  doAssert s.sampleIntervalUs.isNaN and s.samplesPerTrace == 2001 and s.recordLengthMs.isNaN
  doAssert s.crsFormat == ctNone and s.coordinateUnits == cuMeters
  f.close()
  doAssertRaises(ValueError): discard f.summary

block segd_mixed_records:
  # 63.sgd followed by its Rev 2.1 conversion (file number 64): two records
  # of two revisions.
  let r21 = tmp / "63_r21.sgd"
  doAssert not convertSegdRevision(s63, r21,
    SegdConvertOptions(revision: SegdRevision(major: 2, minor: 1))).hasErrors
  let second = edited(r21, "63_r21_64.sgd", [(hsRecord, 0, "gh1.fileNumber", toFieldValue(64))])
  let both = tmp / "two.sgd"
  writeFile(both, readFile(s63) & readFile(second))
  let f = openSeismic(both)
  doAssert f.recordCount == 2 and f.len == 2
  let s = f.summary
  doAssert $s.revision == "2.0" and s.mixedRevisions and s.formatCode == 8058
  doAssert s.firstFieldRecord == 63 and s.lastFieldRecord == 64
  doAssert s.sampleIntervalUs == 2000 and s.recordCount == 2
  let cs = f.channelSets
  doAssert cs.len == 2 and cs[1].record == 1 and cs[1].traceCount == 1

block unknown_file:
  let junk = tmp / "junk.bin"
  writeFile(junk, repeat('\0', 5000))
  let f = openSeismic(junk)
  let s = f.summary
  doAssert s.standard == skUnknown and s.traceCount == 0 and s.recordCount == 0
  doAssert not s.decodable and s.formatCode == -1 and s.firstFieldRecord == -1
  doAssert s.sampleIntervalUs.isNaN and f.crsText == "" and f.channelSets.len == 0

block large_sample_local_only:
  let big = exampleDir / "00000151_12900_11300.sgd"
  if fileExists(big):
    let s = openSeismic(big).summary
    doAssert s.traceCount == 3957 and s.sampleIntervalUs == 1000 and s.samplesPerTrace == 4001
    doAssert s.crsFormat == ctStanza

echo "tsummary: ok"
