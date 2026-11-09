## Explicit write-back of joined survey geometry (task 10.5): `writeGeometry`
## through the journaled editor (and its rollback), `geometryChanges` /
## `geometryChanges` (nothing written), `copyWithGeometry` and
## `convertWithGeometry`. Synthetic SPS files and SEG-Y files built here,
## plus copies of the sample files (the originals are never written).

import std/[assertions, options, os, strutils, math]
import parseSEG
import parseSEG/survey/cards # column helpers (internal)
from parseSEG/survey/writeback import chooseScalar # internal

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getEnv("XDG_CACHE_HOME", getTempDir()) / "parseseg_tgeomwrite"
removeDir(tmp)
createDir(tmp)

proc rec(first: char, fields: openArray[(int, string)]): string =
  result = repeat(' ', 80)
  result[0] = first
  for (c, t) in fields: result.putCol(c, t)

proc r21(kind: char, line, point: string, index: char, e, n, z: string): string =
  ## An SPS 2.1 R or S record.
  rec(kind, [(2, line.align(10)), (12, point.align(10)), (24, $index & "G1"), (47, e.align(9)),
    (56, n.align(10)), (66, z.align(6)), (72, " 18213250")])

proc x21(record: int, srcLine, srcPoint: string, fromCh, toCh: int, rcvLine, fromR,
    toR: string): string =
  ## An SPS 2.1 X record (source index 1, receiver index 1, increment 1).
  rec('X', [(2, "T1"), (8, align($record, 8)), (16, "1"), (17, "1"), (18, srcLine.align(10)),
    (28, srcPoint.align(10)), (38, "1"), (39, align($fromCh, 5)), (44, align($toCh, 5)),
    (49, "1"), (50, rcvLine.align(10)), (60, fromR.align(10)), (70, toR.align(10)),
    (80, "1")])

const H00 = "H00 SPS format version number   SPS 2.1;"

proc sps(name: string, lines: varargs[string]): SurveyGeometry =
  let path = tmp / name
  writeFile(path, (@[H00] & @lines).join("\n") & "\n")
  result.addSps(path)
  doAssert not result.log.hasErrors, $result.log.len

proc bytesOf(path: string): string = readFile(path)

proc has(log: DiagLog, text: string, sev = sevWarning): bool =
  for d in log:
    if d.severity == sev and text in d.msg: return true

proc copySample(name: string): string =
  result = tmp / name
  copyFile(exampleDir / name, result)

proc segyFile(path: string, rev = 1, traces = 4) =
  ## A small SEG-Y file: field record 10, channels 1..n, no coordinates.
  var f = SegyFile(text: initTextHeader(teEbcdic), byteOrder: boBig, format: some(sfFloat32),
    revision: SegyRevision(major: uint8(rev)), extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: uint8(rev), samplesPerTrace: 10,
    sampleInterval: 1000, measurementSystem: 1)
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, f, initSegyWriteOptions(f, lenient = true))
  for i in 0..<traces:
    var t = SegyTrace(numSamples: 10, sampleInterval: 1000, samples: newSeq[byte](40))
    t.header = SegyTraceHeader(fieldRecord: 10, traceNumberInField: int32(i + 1),
      numSamples: 10, sampleInterval: 1000)
    w.writeTrace(t)
  w.close()
  sink.close()

# A survey for record 10: one source, receivers 101..104 on line 10.
let segySurvey = [
  r21('S', "20", "205", '1', "500000.5", "6000400.0", "10.0"),
  r21('R', "10", "101", '1', "500100.0", "6000000.0", "12.5"),
  r21('R', "10", "102", '1', "500125.0", "6000000.0", "12.6"),
  r21('R', "10", "103", '1', "500150.0", "6000000.0", "12.7"),
  r21('R', "10", "104", '1', "500175.0", "6000000.0", "12.8"),
  x21(10, "20", "205", 1, 4, "10", "101", "104")]

block segy_in_place_scalar_journal_and_rollback:
  let path = tmp / "a.sgy"
  segyFile(path)
  let original = bytesOf(path)
  let g = sps("a.sps", segySurvey)
  var f = openSeismic(path, keys = true)
  doAssert f.applySurvey(g) == 4
  # A dry run writes nothing and reports what has no slot (Rev 1: no lines).
  var log: DiagLog
  let c = f.geometryChanges(GeometryFields(), log)
  doAssert c.traces == 4 and c.sourceXy == 4 and c.receiverXy == 4, $c
  doAssert c.sourceZ == 4 and c.receiverZ == 4 and c.midpoints == 4 and c.offsets == 4
  doAssert c.sourceStations == 4, "the source point goes to espnum and sp"
  doAssert c.receiverStations == 0 and c.unwritable == 8, $c # lines/points: no slot
  doAssert log.has("source station: the file's layout has no field")
  doAssert log.has("receiver station: the file's layout has no field")
  doAssert ($c).startsWith("4 traces"), $c
  doAssert bytesOf(path) == original
  # In place, journaled.
  var ed = openEditor(path)
  let w = ed.writeGeometry(f.index)
  doAssert w == c, $w
  ed.close()
  f.close()
  doAssert not ed.log.hasErrors
  let d = readSegy(path)
  let h = d.traces[2].header
  doAssert h.coordinateScalar == -100, "the midpoint 500075.25 needs two decimals"
  doAssert h.sourceX == 50000050 and h.groupX == 50015000 and h.cdpX == 50007525
  doAssert h.elevationScalar == -10 and h.coordinateUnits == 1
  doAssert h.receiverElevation == 127 and h.energySourcePoint == 205
  var k = openSeismic(path, keys = true)
  let k2 = k.traceKeys(2)
  doAssert k2.srcX == 500000.5 and k2.rcvX == 500150 and k2.rcvZ == 12.7
  doAssert abs(k2.offset - round(hypot(149.5, 400.0))) < 1e-9, $k2.offset # int4: rounded
  doAssert k2.cmpX == 500075.25 and k2.srcPoint == 205
  # Writing again changes nothing.
  doAssert k.applySurvey(g) == 4, "the lines and receiver points have no slot"
  let again = k.geometryChanges()
  doAssert again.traces == 0 and again.unwritable == 8, $again
  k.close()
  doAssert rollbackJournal(path, path & ".edits.nif").len == 0
  doAssert bytesOf(path) == original

block segy_scalar_choice_overflow_and_precision:
  var exact: bool
  doAssert chooseScalar([12.0, 3.0], 0, exact) == 1 and exact
  doAssert chooseScalar([12.5, 3.0], -100, exact) == -100 and exact, "the file's own"
  doAssert chooseScalar([12.25], 1, exact) == -100 and exact
  doAssert chooseScalar([5e8], -10, exact) == 1 and exact, "5e9 does not fit"
  doAssert chooseScalar([123456.123456], 1, exact) == -10000 and not exact
  doAssert chooseScalar([3e10], 1, exact) == 100 and exact
  doAssert chooseScalar([3e14], 1, exact) == 0
  let path = tmp / "b.sgy"
  segyFile(path, traces = 2)
  let g = sps("b.sps", r21('R', "10", "101", '1', "123.12345", "1.0", ""),
    r21('R', "10", "102", '1', "3E14", "1.0", ""),
    x21(10, "20", "205", 1, 2, "10", "101", "102"))
  var f = openSeismic(path, keys = true)
  discard f.applySurvey(g)
  var ed = openEditor(path)
  let w = ed.writeGeometry(f.index, GeometryFields(stations: false))
  ed.close()
  f.close()
  doAssert w.receiverXy == 1 and w.unwritable == 2, $w # x and y of trace 1
  doAssert ed.log.has("too large for a 4-byte SEG-Y field", sevError)
  doAssert ed.log.has("receiver X/Y: rounded")
  let d = readSegy(path)
  doAssert d.traces[0].header.coordinateScalar == -10000
  doAssert d.traces[1].header.groupX == 0, "refused: left alone"

block segy_rev2_station_header_via_layout:
  # SEG-D 63.sgd converted to SEG-Y Rev 2.1 carries line/point in the
  # PSEGD001 header its Layout stanza describes.
  let segy = tmp / "63.sgy"
  doAssert not convertFile(exampleDir / "63.sgd", segy).isFatal
  let g = sps("c.sps", r21('R', "13", "104", '1', "500100.0", "6000000.0", "12.5"),
    x21(63, "13", "99.5", 1, 1, "14", "105", "105"))
  var f = openSeismic(segy, keys = true)
  doAssert f.applySurvey(g, overwrite = true) == 1
  let dst = tmp / "63geo.sgy"
  let r = copyWithGeometry(segy, dst, g, overwrite = true)
  doAssert not r.log.hasErrors, $r.log.len
  doAssert r.changes.receiverStations == 1, $r.changes
  let d = readSegy(dst)
  doAssert d.file.fieldValue(d.traces[0], "rec_line") == some(14.0)
  doAssert d.file.fieldValue(d.traces[0], "rec_point") == some(105.0)
  f.close()

block segd_rev2_the1_in_place:
  let path = copySample("63.sgd")
  let original = bytesOf(path)
  let g = sps("d.sps", r21('R', "14", "105.5", '1', "500100.0", "6000000.0", "12.5"),
    x21(63, "13", "99.5", 1, 1, "14", "105.5", "105.5"))
  var f = openSeismic(path, keys = true)
  doAssert f.applySurvey(g, overwrite = true) == 1
  var ed = openEditor(path)
  let w = ed.writeGeometry(f.index)
  ed.close()
  f.close()
  doAssert w.receiverStations == 1 and w.receiverXy == 0, $w
  doAssert ed.log.has("receiver X/Y: SEG-D Rev 1/2 trace headers have no coordinate fields")
  var k = openSeismic(path, keys = true)
  doAssert k.traceKeys(0).rcvLine == 14 and k.traceKeys(0).rcvPoint == 105.5
  doAssert k.traceField(0, "ext1.receiverPointNumber").intVal == -1, "the extended field"
  k.close()
  doAssert rollbackJournal(path, path & ".edits.nif").len == 0
  doAssert bytesOf(path) == original

block segd_rev3_position_blocks:
  # The INOVA traces 3 and 4 carry receiver Position blocks (100/101, 100/102);
  # the source position is record-level (general headers).
  let path = copySample("inova_rev30_5traces.sgd")
  let original = bytesOf(path)
  var g = initSurveyGeometry()
  g.addReceiver(100, 101, 1, 1826000.5, 446000.25, 1000.0)
  g.addReceiver(100, 102, 1, 1826100.5, 446000.25, 1001.0)
  g.addSource(129, 113, 0, 1834000.0, 445000.0)
  var f = openSeismic(path, keys = true)
  doAssert f.applySurvey(g, overwrite = true) == 5
  let c = f.geometryChanges()
  doAssert c.receiverXy == 2 and c.receiverZ == 2, $c
  doAssert c.sourceXy == 0 and c.unwritable > 0
  var ed = openEditor(path)
  doAssert ed.writeGeometry(f.index) == c
  ed.close()
  f.close()
  doAssert ed.log.has("source X/Y: the trace has no source Position block")
  var k = openSeismic(path, keys = true)
  let k3 = k.traceKeys(3)
  doAssert k3.rcvX == 1826000.5 and k3.rcvY == 446000.25 and k3.rcvZ == 1000
  doAssert k.traceKeys(4).rcvX == 1826100.5
  doAssert not k.log.hasErrors
  k.close()
  doAssert rollbackJournal(path, path & ".edits.nif").len == 0
  doAssert bytesOf(path) == original

block convert_with_geometry_from_segd:
  let g = sps("e.sps", r21('R', "13", "104", '1', "500100.0", "6000000.0", "12.5"),
    r21('S', "13", "99.5", '1', "500000.0", "6000400.0", "10.0"))
  let dst = tmp / "63conv.sgy"
  let log = convertWithGeometry(exampleDir / "63.sgd", dst, g)
  doAssert not log.isFatal
  var k = openSeismic(dst, keys = true)
  doAssert k.traceKeys(0).rcvX == 500100 and k.traceKeys(0).srcY == 6000400
  doAssert abs(k.traceKeys(0).offset - hypot(100.0, 400.0)) < 1
  k.close()
  # Only the selected values: no receiver coordinates.
  let dst2 = tmp / "63conv2.sgy"
  doAssert not convertWithGeometry(exampleDir / "63.sgd", dst2, g,
    fields = GeometryFields(receiverXy: false)).isFatal
  var k2 = openSeismic(dst2, keys = true)
  doAssert k2.traceKeys(0).rcvX.isNaN and k2.traceKeys(0).srcX == 500000
  k2.close()

block convert_with_geometry_from_segy:
  let path = tmp / "f.sgy"
  segyFile(path, rev = 1)
  let g = sps("f.sps", segySurvey)
  let dst = tmp / "fconv.sgy"
  let log = convertWithGeometry(path, dst, g)
  doAssert not log.isFatal and log.has("geometry written: 4 traces", sevInfo)
  var k = openSeismic(dst, keys = true)
  doAssert k.traceKeys(3).rcvX == 500175 and k.traceKeys(3).srcX == 500000.5
  k.close()
  doAssert not fileExists(dst & ".tmp") and not fileExists(dst & ".tmp.geometry.nif")

block refusals:
  let path = tmp / "g.sgy"
  segyFile(path)
  var f = openSeismic(path)
  doAssertRaises ValueError: discard f.geometryChanges() # no keys
  var ed = openEditor(path)
  doAssertRaises ValueError: discard ed.writeGeometry(f.index) # no keys
  ed.close()
  f.close()
  doAssert copyWithGeometry(path, path, initSurveyGeometry()).log.isFatal
  doAssert copyWithGeometry(tmp / "missing.sgy", tmp / "x.sgy", initSurveyGeometry()).log.isFatal

block segy_in_place_from_the_open_file:
  # 14.3c: the editor takes over the joined file; its keys are the joined
  # ones (no second walk, which would read the file's empty coordinates).
  let path = tmp / "h.sgy"
  segyFile(path)
  let original = bytesOf(path)
  var f = openSeismic(path, keys = true)
  doAssert f.applySurvey(sps("h.sps", segySurvey)) == 4
  let plan = f.geometryChanges()
  var ed = openEditor(move f)
  doAssert ed.file.hasKeys and ed.file.index.keys[2].rcvX == 500150
  let w = ed.writeGeometry()
  doAssert w == plan and w.traces == 4, $w
  ed.close()
  doAssert not ed.log.hasErrors
  doAssert readSegy(path).traces[2].header.groupX == 50015000
  doAssert rollbackJournal(path, path & ".edits.nif").len == 0
  doAssert bytesOf(path) == original
  # An editor without keys refuses.
  var e = openEditor(openSeismic(path), tmp / "h.nif")
  doAssertRaises ValueError: discard e.writeGeometry()
  e.close()
  doAssert bytesOf(path) == original

when defined(linux):
  import std/posix

  var RLIMIT_FSIZE {.importc, header: "<sys/resource.h>".}: cint

  proc limitFileSize(bytes: int) =
    ## Writes past `bytes` into any file fail with EFBIG (SIGXFSZ ignored);
    ## a negative `bytes` lifts the limit.
    signal(SIGXFSZ, SIG_IGN)
    var lim: RLimit
    doAssert getrlimit(RLIMIT_FSIZE, lim) == 0
    lim.rlim_cur = if bytes < 0: lim.rlim_max else: bytes
    doAssert setrlimit(RLIMIT_FSIZE, lim) == 0

  block failed_journal_sync_is_not_counted:
    # 13.3 R1-5: when the batch's journal sync fails its edits are dropped,
    # and the changes must not count them (they did: "4 traces").
    let path = tmp / "sync.sgy"
    segyFile(path)
    let original = bytesOf(path)
    var f = openSeismic(path, keys = true)
    doAssert f.applySurvey(sps("sync.sps", segySurvey)) == 4
    var ed = openEditor(path)
    let session = getFileSize(path & ".edits.nif")
    limitFileSize(int(session) + 20)
    var w: GeometryChanges
    try:
      w = ed.writeGeometry(f.index)
    finally:
      limitFileSize(-1)
    doAssert w.traces == 0 and w.sourceXy == 0 and w.offsets == 0, $w
    doAssert ed.log.has("4 traces' geometry was not written", sevFatal), $ed.log
    ed.close()
    f.close()
    doAssert bytesOf(path) == original
