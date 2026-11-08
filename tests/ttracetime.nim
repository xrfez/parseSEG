## Trace time in `TraceKeys` (task 6.9): SEG-Y trace bytes 157-168 with the
## time basis, SEG-D GH#1 date and time, SEG-D Rev 3 GH#3 time zero and the
## per-trace Timestamp block (0x42). Expected values were computed
## independently (Python `calendar.timegm`, and the GPS epoch minus 18 leap
## seconds for the SEG-D Rev 3 time stamp, as tools/walks/segd3_walk.py
## prints it).

import std/[assertions, math, os]
import parseSEG

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_ttracetime"
createDir(tmp)

const
  s63 = exampleDir / "63.sgd"
  inova = exampleDir / "inova_rev30_5traces.sgd"
  inglewood = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  sweep = exampleDir / "Sweep0.sgy"
  june11 = 1718127602.0  ## 2024-06-11 (day 163) 17:40:02 UTC
  inovaUtc = 1790959547.504 ## GH#3 time zero 1474994765504000 µs GPS
  gpsLeaps = 18.0          ## GPS - UTC since 2017

proc timeOf(path: string, trace: int): float64 =
  openSeismic(path, keys = true).traceKeys(trace).time

proc edited(src, name: string, edits: openArray[(HeaderScope, int, string, int)]): string =
  result = tmp / name
  copyFile(src, result)
  if fileExists(result & ".edits.nif"): removeFile(result & ".edits.nif")
  var ed = openEditor(result)
  for (scope, i, field, v) in edits:
    let ok = case scope
      of hsFile: ed.setFileField(field, v)
      of hsRecord: ed.setRecordField(i, field, v)
      of hsTrace: ed.setTraceField(i, field, v)
    doAssert ok, field & " " & $ed.log
  ed.close()
  removeFile(result & ".edits.nif")

proc patched(src, name: string, at: int, bytes: openArray[byte]): string =
  result = tmp / name
  var s = readFile(src)
  for k, b in bytes: s[at + k] = char(b)
  writeFile(result, s)

proc dateEdits(trace, year, basis: int): seq[(HeaderScope, int, string, int)] =
  @[(hsTrace, trace, "trace.year", year), (hsTrace, trace, "trace.dayOfYear", 163),
    (hsTrace, trace, "trace.hour", 17), (hsTrace, trace, "trace.minute", 40),
    (hsTrace, trace, "trace.second", 2), (hsTrace, trace, "trace.timeBasisCode", basis)]

block initial_keys_unknown:
  doAssert initTraceKeys().time.isNaN

block segd_rev2_gh1:
  doAssert timeOf(s63, 0) == june11 # GH#1: year 24, day 163, 17:40:02

block segd_rev3_time_zero:
  let f = openSeismic(inova, keys = true)
  for i in 0 ..< f.len:
    doAssert abs(f.traceKeys(i).time - inovaUtc) < 1e-6
  # Without GH#3 time zero (bytes 65-72 of the record): GH#1 (16:45:47 UTC).
  let gh3 = int(f.index.segdRecords[0].offset) + 64
  let noTz = patched(inova, "notz.sgd", gh3, newSeq[byte](8))
  doAssert timeOf(noTz, 0) == 1790959547.0
  # A trace with a Timestamp block (0x42): its own time. The first
  # extension after THE#1 of trace 3 becomes one, 1.25 s after time zero.
  let e = f.traceEntry(3)
  let ts = 1474994765504000'i64 + 1_250_000
  var blk = newSeq[byte](32)
  for k in 0..7: blk[k] = byte((ts shr (8 * (7 - k))) and 0xFF)
  blk[31] = 0x42
  let stamped = patched(inova, "stamped.sgd", int(e.offset) + 20 + 32, blk)
  let g = openSeismic(stamped, keys = true)
  doAssert abs(g.traceKeys(3).time - (inovaUtc + 1.25)) < 1e-6
  doAssert abs(g.traceKeys(4).time - inovaUtc) < 1e-6

block segy_time_basis:
  var edits: seq[(HeaderScope, int, string, int)]
  edits.add dateEdits(0, 2024, 4)  # UTC
  edits.add dateEdits(1, 2024, 5)  # GPS
  edits.add dateEdits(2, 2024, 1)  # local: unknown
  edits.add dateEdits(4, 24, 2)    # GMT, two-digit year
  edits.add dateEdits(5, 2024, 0)  # unset: the binary basis (GPS, below)
  edits.add dateEdits(6, 2024, 3)  # other: unknown
  edits.add dateEdits(7, 2024, 9)  # undefined code
  edits.add (hsFile, 0, "binary.timeBasisCode", 5)
  let p = edited(inglewood, "basis.sgy", edits)
  let f = openSeismic(p, keys = true)
  doAssert f.traceKeys(0).time == june11
  doAssert f.traceKeys(1).time == june11 - gpsLeaps
  doAssert f.traceKeys(2).time.isNaN
  doAssert f.traceKeys(3).time.isNaN # year 0: unknown
  doAssert f.traceKeys(4).time == june11
  doAssert f.traceKeys(5).time == june11 - gpsLeaps
  doAssert f.traceKeys(6).time.isNaN and f.traceKeys(7).time.isNaN
  # An unset basis with no binary basis is read as UTC.
  let q = edited(inglewood, "unset.sgy", dateEdits(0, 2024, 0))
  doAssert timeOf(q, 0) == june11
  # Out-of-range day: unknown.
  let r = edited(inglewood, "badday.sgy", dateEdits(0, 2024, 4) &
    @[(hsTrace, 0, "trace.dayOfYear", 400)])
  doAssert timeOf(r, 0).isNaN

block segy_rev0_ignores_binary_basis:
  # Rev 0 has no binary time basis: bytes 3511-3512 are unassigned.
  let p = edited(sweep, "rev0.sgy", dateEdits(0, 99, 0) &
    @[(hsFile, 0, "binary.timeBasisCode", 1)])
  doAssert timeOf(p, 0) == 929209202.0 # 1999-06-12 (day 163) 17:40:02 UTC

block segy_ext1_nanoseconds:
  var d = readSegy(inglewood)
  var file = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boBig,
    format: d.file.format, extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  file.binary.numExtTextHeaders = 0
  file.binary.maxAddlTraceHeaders = 1
  let path = tmp / "ext1.sgy"
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, file, initSegyWriteOptions(file, lenient = true))
  var t = d.traces[0]
  (t.header.year, t.header.dayOfYear, t.header.hour, t.header.minute, t.header.second,
    t.header.timeBasisCode) = (2024'i16, 163'i16, 17'i16, 40'i16, 2'i16, 4'i16)
  t.hasExt1 = true
  t.ext1 = initTraceHeaderExt1()
  t.ext1.numAddlTraceHeaders = 1
  t.ext1.nanoseconds = 250_000_000
  w.writeTrace(t)
  w.close()
  sink.close()
  doAssert timeOf(path, 0) == june11 + 0.25

echo "ttracetime: ok"
