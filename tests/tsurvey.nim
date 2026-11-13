## Survey files (Phase 10): SPS 1.0/2.1, SEG P1-P4 (1983), and joining them
## to traces. Records are built at exact columns from the spec examples
## (`docs/spec/sps.md` §5.3, `docs/spec/p1_p2_p3.md` §3.4); the extracted
## spec text collapses blanks, so its lines cannot be used verbatim.

import std/[assertions, options, streams, strutils, math, os, tables, algorithm]
import parseSEG
import parseSEG/common/ebcdic
import parseSEG/survey/cards # column helpers (internal)
import ../tools/demofiles
from ./utils/testutils import has

proc rec(first: char, fields: openArray[(int, string)]): string =
  ## An 80-column record with `fields` placed at their 1-based columns.
  result = repeat(' ', 80)
  result[0] = first
  for (c, t) in fields: result.putCol(c, t)

proc r21(kind: char, line, point: string, index: char, code: string, e, n, z: string,
    daytime = " 18213250"): string =
  rec(kind, [(2, line.align(10)), (12, point.align(10)), (24, $index & code), (47, e.align(9)),
    (56, n.align(10)), (66, z.align(6)), (72, daytime)])

proc x21(tape: string, record: int, srcLine, srcPoint: string, srcIndex: char,
    fromCh, toCh: int, inc: char, rcvLine, fromR, toR: string, rcvIndex: char): string =
  rec('X', [(2, tape), (8, align($record, 8)), (16, "1"), (17, "1"), (18, srcLine.align(10)),
    (28, srcPoint.align(10)), (38, $srcIndex), (39, align($fromCh, 5)), (44, align($toCh, 5)),
    (49, $inc), (50, rcvLine.align(10)), (60, fromR.align(10)), (70, toR.align(10)),
    (80, $rcvIndex)])

const H00 = "H00 SPS format version number   SPS 2.1;"

let rcv1 = r21('R', "5646.00", "534550.00", '1', "G1", "238570.0", "3058380.0", "83.2")
let rcv2 = r21('R', "5646.00", "534600.00", '1', "G1", "238600.0", "3058380.0", "82.4")
let src1 = r21('S', "5713.00", "542525.00", '2', "V6", "238500.0", "3058300.0", "60.6",
  " 19001150")
# The spec's 2.1 X example (sps.md §5.3), exactly.
let x1 = "XB79480       111   5713.00 542525.002    1  3201   5646.00 534550.00 550500.001"

block textrec_layouts:
  doAssert detectLayout("H00 x\r\nR") == tlLines
  doAssert detectLayout(repeat('H', 1) & repeat(' ', 159)) == tlFixed80
  let e = encodeEbcdic("H00 SPS" & repeat(' ', 73))
  var es = newString(e.len)
  for i, b in e: es[i] = char(b)
  doAssert detectLayout(es) == tlEbcdic80
  doAssert parseFortranFloat("  3354", 2) == some(33.54)
  doAssert parseFortranFloat(" 33.5", 2) == some(33.5), "an explicit point wins"
  doAssert parseFortranFloat("    ", 2).get.isNaN
  doAssert parseFortranFloat("1 2").isNone
  doAssert parseFortranInt(" -12") == some(-12'i64) and parseFortranInt("  ") == some(MissingInt)
  doAssert parseFortranInt("1x").isNone
  doAssert "abc".col(2, 5) == "bc  "

block sps21_read_and_roundtrip:
  for nl in ["\r\n", "\n"]:
    let text = [H00, rcv1, rcv2, src1, x1].join(nl) & nl
    let f = parseSps(text, "t.sps")
    doAssert f.revision == sps21 and f.revisionDeclared
    doAssert f.crlf == (nl == "\r\n")
    doAssert f.log.len == 0, $f.log.len
    doAssert f.points.len == 3 and f.relations.len == 1 and f.headers.len == 1
    let p = f.points[0]
    doAssert p.kind == pkReceiver and p.line == 5646 and p.point == 534550 and p.index == 1
    doAssert p.code == "G1" and p.easting == 238570.0 and p.northing == 3058380.0
    doAssert p.elevation == 83.2 and p.dayOfYear == 18 and p.hour == 21 and p.second == 50
    doAssert p.staticCorrection.isNaN and p.waterDepth.isNaN, "blank is missing, not 0"
    let r = f.relations[0]
    doAssert r.fieldTape == "B79480" and r.fieldRecord == 1 and r.srcIndex == 2
    doAssert r.fromChannel == 1 and r.toChannel == 320 and r.fromReceiver == 534550
    doAssert r.toReceiver == 550500 and r.rcvLine == 5646
    let back = spsText(f)
    doAssert back.log.len == 0 and back.text == text, "unedited records are written byte for byte"

block sps_edit_reencodes:
  var f = parseSps([H00, rcv1].join("\n") & "\n")
  f.points[0].easting = 1.5
  f.points[0].staticCorrection = -12
  let line = spsText(f).text.splitLines[1]
  doAssert line.len == 80
  doAssert line.col(47, 55) == "      1.5" and line.col(27, 30) == " -12"
  doAssert line.col(1, 26) == rcv1.col(1, 26)

block sps_revision_from_columns:
  let f = parseSps([rcv1, x1].join("\n"))
  doAssert f.revision == sps21 and not f.revisionDeclared
  doAssert f.log.count(sevWarning) == 1 and f.log.len == 1 # a guess: the caller should know
  # A 1.0 record: 16-column line name, point right-adjusted in 18-25.
  let r10 = rec('R', [(2, "91LW1124"), (18, "225".align(8)), (26, "1G1"),
    (47, "238570.0".align(9)), (56, "3058380.0".align(10)), (66, "106.8".align(6)),
    (72, "113071245")])
  let g = parseSps(r10 & "\n")
  doAssert g.revision == sps10
  doAssert g.points[0].lineName == "91LW1124" and g.points[0].line.isNaN
  doAssert g.points[0].point == 225 and g.points[0].index == 1 and g.points[0].code == "G1"
  doAssert g.points[0].elevation == 106.8 and g.points[0].dayOfYear == 113
  doAssert spsText(g).text == r10 & "\n"

block sps_convert_revisions:
  let f = parseSps([H00, rcv1, src1, x1].join("\n") & "\n")
  let w10 = spsText(f, SpsWriteOptions(revision: sps10))
  let t10 = w10.text
  doAssert w10.log.count(sevError) == 0
  let g = parseSps(t10)
  doAssert g.revision == sps10 and g.revisionDeclared
  doAssert g.points[0].line == 5646 and g.points[0].point == 534550
  doAssert g.relations[0].toReceiver == 550500 and g.relations[0].toChannel == 320
  let t21 = spsText(g, SpsWriteOptions(revision: sps21)).text
  doAssert t21 == [H00, rcv1, src1, x1].join("\n") & "\n", "2.1 -> 1.0 -> 2.1 is lossless"

block sps_writer_refuses_overflow:
  var f = parseSps([H00, rcv1].join("\n") & "\n")
  f.points[0].easting = 1e12
  let s = newStringStream()
  let log = writeSps(f, s)
  doAssert log.count(sevError) == 1 and s.data.len == 0, "nothing is written"
  let s2 = newStringStream()
  let log2 = writeSps(f, s2, SpsWriteOptions(lenient: true))
  doAssert log2.count(sevError) == 0 and log2.count(sevWarning) == 1
  doAssert rcv1 in s2.data, "lenient writes the record as read"
  # 1.0 names that are not numbers cannot become Rev 2.1 F10.2.
  let g = parseSps(rec('S', [(2, "91LW1124"), (18, "SA".alignLeft(8)), (26, "1E1")]) & "\n",
    opts = SpsOptions(revision: sps10))
  doAssert writeSps(g, newStringStream(), SpsWriteOptions(revision: sps21)).count(sevError) == 1

block sps_files_on_disk:
  let dir = getTempDir() / "tsurvey"
  createDir(dir)
  let path = dir / "a.s01"
  writeFile(path, [H00, src1].join("\r\n") & "\r\n")
  let f = readSps(path)
  doAssert f.points.len == 1 and f.crlf
  let outp = dir / "b.s01"
  doAssert writeSps(f, outp).len == 0
  doAssert readFile(outp) == readFile(path) and not fileExists(outp & ".tmp")
  doAssert readSps(dir / "missing").log.isFatal
  # Fixed 80-byte EBCDIC records (a tape copy).
  let eb = encodeEbcdic(H00.alignLeft(80) & src1)
  var ebs = newString(eb.len)
  for i, b in eb: ebs[i] = char(b)
  let g = parseSps(ebs)
  doAssert g.layout == tlEbcdic80 and g.points.len == 1 and g.points[0].point == 542525
  removeDir(dir)

block sps_bad_records_are_diagnostics:
  let bad = rcv1[0 .. 45] & "   abc.x" & rcv1[54 .. ^1]
  let f = parseSps([H00, bad, "Q what", "", "EOF"].join("\n"))
  doAssert f.points.len == 1 and f.points[0].easting.isNaN
  doAssert f.log.count(sevWarning) >= 2 # easting, unknown 'Q' record
  doAssert f.others.len == 3
  doAssert spsText(f).text.splitLines[2] == "Q what", "unknown lines are kept"

block sps_strict_implied_decimals:
  let line = rec('S', [(2, "5646".align(10)), (12, "534550".align(10)), (24, "1V6")])
  doAssert parseSps(line, opts = SpsOptions(revision: sps21)).points[0].line == 5646
  let strict = parseSps(line, opts = SpsOptions(revision: sps21, strictImpliedDecimals: true))
  doAssert strict.points[0].line == 56.46

# ------------------------------------------------------------------- P1 ---

# P1 worked example (p1_p2_p3.md §3.4), rebuilt to 80 columns.
let p1a = " CLT4960            12340B17543354N110445881E  155590  161670  85779197065028   "
let p1b = " CLT4960            12350 17543300S110445000W  155500  161600  86005197065228   "

block p1_decode:
  let f = parseP1(["H SEG P1 EXAMPLE", " UNITS: METERS", p1a, p1b].join("\n") & "\n",
    opts = P1Options(depthDecimals: 1))
  doAssert f.files.len == 1 and f.files[0].format == pfP1 and f.files[0].header.len == 2
  doAssert f.log.len == 0
  let r = f.files[0].records[0]
  doAssert r.lineName == "CLT4960" and r.point == 12340 and r.reshoot == 'B'
  doAssert abs(r.latitude - (17 + 54 / 60 + 33.54 / 3600)) < 1e-9
  doAssert abs(r.longitude - (110 + 44 / 60 + 58.81 / 3600)) < 1e-9
  doAssert r.easting == 155590 and r.northing == 161670 and r.depthOrElevation == 85.7
  doAssert r.year == 1979 and r.dayOfYear == 197 and r.hour == 6 and r.second == 28
  let s = f.files[0].records[1]
  doAssert s.latitude < 0 and s.longitude < 0 and s.year == 2005

block p1_roundtrip_and_edit:
  let text = ["H SEG P1 EXAMPLE", p1a, p1b].join("\n") & "\n"
  let f = parseP1(text)
  doAssert p1Text(f, P1WriteOptions(padHeaders: false)).text == text
  doAssert p1Text(f).text == text, "headers are not padded by default"
  let padded = p1Text(f, P1WriteOptions(padHeaders: true)).text.splitLines
  doAssert padded.len == 20 + 2 + 1 and padded[20] == p1a, "header padded to a block of 20"
  var g = f
  g.files[0].records[0].easting = 155591
  g.files[0].records[0].latitude = 17 + 59 / 60 + 59.999 / 3600 # rounds to 18 00 00.00
  let line = p1Text(g, P1WriteOptions(padHeaders: false)).text.splitLines[1]
  doAssert line.col(46, 53) == "  155591" and line.col(27, 35) == "18000000N"
  doAssert line.col(1, 26) == p1a.col(1, 26) and line.col(36, 80) == p1a.col(36, 45) &
    "  155591" & p1a.col(54, 80)

block p1_grads_and_logical_files:
  let grads = rec(' ', [(2, "L1"), (18, "10".align(8)), (27, "01989999N"), (36, "019999999W")])
  let f = parseP1(["H FIRST", p1a, "H SECOND", grads].join("\n"),
    opts = P1Options(angleUnit: auGrads))
  doAssert f.files.len == 2
  let r = f.files[1].records[0]
  doAssert abs(r.latitude - 19.89999 * 0.9) < 1e-9 and r.angleUnit == auGrads
  doAssert abs(r.longitude + 199.99999 * 0.9) < 1e-9

block p1_other_formats_kept_raw:
  let p4 = @["S00001 001 some doppler data", "S00001 002 more"]
  let f = parseP1((@["H P4 FILE"] & p4).join("\n") & "\n")
  doAssert f.files[0].format == pfP4 and f.files[0].records.len == 2
  doAssert f.files[0].records[1].raw == p4[1]
  doAssert p1Text(f, P1WriteOptions(padHeaders: false)).text ==
    (@["H P4 FILE"] & p4).join("\n") & "\n"

# ----------------------------------------------------------------- join ---

block join_relations:
  let f = parseSps([H00, rcv1, rcv2, src1, x1].join("\n"))
  var g: SurveyGeometry
  g.addSps(f)
  doAssert g.relationCount == 1 and g.table.receivers.len == 2 and g.table.sources.len == 1
  let rel = g.relation(1, 2).get
  doAssert rel.receiver.point == 534600, "receivers are interpolated: step 50"
  doAssert rel.source.line == 5713 and rel.source.point == 542525 and rel.source.index == 2
  doAssert g.relation(1, 320).get.receiver.point == 550500
  doAssert g.relation(1, 321).isNone and g.relation(2, 1).isNone
  var k = initTraceKeys()
  k.record = 1
  k.channel = 2
  doAssert k.applySurvey(g)
  doAssert k.rcvX == 238600 and k.srcX == 238500 and k.srcZ == 60.6
  doAssert abs(k.offset - hypot(100.0, 80.0)) < 1e-9

block join_descending_and_multicomponent:
  let x = x21("T1", 7, "5713.00", "542525.00", '2', 1, 7, '3', "5646.00", "534600.00",
    "534550.00", '1')
  let f = parseSps([H00, x].join("\n"))
  var g: SurveyGeometry
  g.addSps(f)
  var rel = g.relation(7, 4).get
  doAssert rel.receiver.point == 534575 and rel.component == 0
  doAssert g.relation(7, 2).isNone, "without multiComponent only every 3rd channel"
  g.multiComponent = true
  rel = g.relation(7, 2).get
  doAssert rel.receiver.point == 534600 and rel.component == 2
  rel = g.relation(7, 9).get
  doAssert rel.receiver.point == 534550 and rel.component == 3

block join_index_fallback_and_rounding:
  var t: GeometryTable
  t.addReceiver(10, 101, 1, 5, 6)
  var k = initTraceKeys()
  (k.rcvLine, k.rcvPoint) = (10.0, 101.0 + 1e-9) # e.g. a SEG-D binary fraction
  doAssert k.applyGeometry(t) and k.rcvX == 5, "index 0 falls back to 1; keys are rounded"
  var k2 = initTraceKeys()
  (k2.rcvLine, k2.rcvPoint, k2.rcvIndex) = (10.0, 101.0, 2'i16)
  doAssert not k2.applyGeometry(t), "a moved receiver (index 2) does not take index 1"

block join_line_names:
  let r10 = rec('R', [(2, "91LW1124"), (18, "225".align(8)), (26, "1G1"),
    (47, "238570.0".align(9)), (56, "3058380.0".align(10))])
  let f = parseSps(r10)
  var g: SurveyGeometry
  g.addSps(f)
  doAssert g.table.receivers.len == 0 and g.log.count(sevWarning) == 1
  var g2 = initSurveyGeometry()
  g2.mapLine("91LW1124", 1124.0)
  g2.addSps(f)
  doAssert stationKey(1124, 225, 1) in g2.table.receivers
  var g3 = SurveyGeometry(trailingDigits: true)
  g3.addSps(f)
  doAssert stationKey(1124, 225, 1) in g3.table.receivers
  # P1: reshoot codes become point indices.
  var g4 = SurveyGeometry(trailingDigits: true)
  g4.addP1(parseP1(["H X", p1a].join("\n")), elevation = true)
  doAssert stationKey(4960, 12340, 3) in g4.table.sources
  doAssert g4.table.sources[stationKey(4960, 12340, 3)].z == 857

block join_to_a_real_file:
  # The demo record.sgd (SEG-D 2.0): file 63, one trace (channel 1), stations
  # in THE#1: source 20/99.5, receiver 10/104. The X record of file 63 names
  # other stations (as when field record numbers differ from the relation
  # file's): it is never used, since the header has both stations.
  let dir = getTempDir() / "tsurvey2"
  createDir(dir)
  writeRecordSegd(dir / "record.sgd")
  let x = x21("T1", 63, "30.00", "205.00", '1', 1, 1, '1', "40.00", "101.00", "101.00", '1')
  let r = r21('R', "10.00", "104.00", '1', "G1", "500100.0", "6000000.0", "12.5")
  let r2 = r21('R', "40.00", "101.00", '1', "G1", "700100.0", "6000000.0", "12.5")
  let s = r21('S', "20.00", "99.50", '1', "V6", "500000.0", "6000400.0", "10.0", " 19001150")
  let s2 = r21('S', "30.00", "205.00", '1', "V6", "700000.0", "6000400.0", "10.0", " 19001150")
  writeFile(dir / "t.sps", [H00, r, r2, s, s2, x].join("\n"))
  var g: SurveyGeometry
  g.addSps(readSps(dir / "t.sps"))
  for overwrite in [false, true]:
    var f = openSeismic(dir / "record.sgd", keys = true)
    doAssert f.index.keys[0].record == 63 and f.index.keys[0].channel == 1
    var stats: JoinStats
    doAssert f.applySurvey(g, stats, overwrite) == 1
    let k = f.index.keys[0]
    doAssert k.srcLine == 20 and k.srcPoint == 99.5 and k.rcvLine == 10 and k.rcvPoint == 104,
      "header stations are never replaced"
    doAssert k.rcvX == 500100 and k.srcX == 500000
    doAssert abs(k.offset - hypot(100.0, 400.0)) < 1e-9
    doAssert stats.traces == 1 and stats.changed == 1 and stats.matches[jmStations] == 1
    doAssert stats.noSourceXy == 0 and stats.noReceiverXy == 0
    doAssert $stats == "1 traces, 1 changed; by stations 1", $stats
    f.close()
  removeDir(dir)

# ------------------------------------------------------ station-first join ---

# Two shots on one receiver line 100 (101..104). Shot 129/113 is record 77
# (channels 1-4 → 101..104) and repeated as record 78; shot 511/117 is
# record 151 (channels 1-4 → 104..101). A field file numbered 151 that holds
# shot 129/113 must still join to record 77's stations.
let joinSurvey = [H00,
  r21('S', "129.00", "113.00", '1', "E1", "1000.0", "5000.0", "10.0", " 19001150"),
  r21('S', "511.00", "117.00", '1', "V1", "2000.0", "5000.0", "10.0", " 19001150"),
  r21('R', "100.00", "101.00", '1', "G1", "1100.0", "6000.0", "1.0"),
  r21('R', "100.00", "102.00", '1', "G1", "1200.0", "6000.0", "2.0"),
  r21('R', "100.00", "103.00", '1', "G1", "1300.0", "6000.0", "3.0"),
  r21('R', "100.00", "104.00", '1', "G1", "1400.0", "6000.0", "4.0"),
  x21("T1", 77, "129.00", "113.00", '1', 1, 4, '1', "100.00", "101.00", "104.00", '1'),
  x21("T1", 78, "129.00", "113.00", '1', 1, 4, '1', "100.00", "101.00", "104.00", '1'),
  x21("T1", 151, "511.00", "117.00", '1', 1, 4, '1', "100.00", "104.00", "101.00", '1')]

proc traceAt(record, channel: float64, src, rcv: (float64, float64), srcIndex = 0'i16):
    TraceKeys =
  result = initTraceKeys()
  result.status = tsLive
  (result.record, result.channel) = (record, channel)
  (result.srcLine, result.srcPoint, result.srcIndex) = (src[0], src[1], srcIndex)
  (result.rcvLine, result.rcvPoint) = rcv

block join_station_first:
  var g: SurveyGeometry
  g.addSps(parseSps(joinSurvey.join("\n")))
  const none = (NaN, NaN)
  # Both stations in the header: the record number (151 = another shot) is
  # not used, with or without overwrite; coordinates come by station.
  for overwrite in [false, true]:
    var k = traceAt(151, 2, (129.0, 113.0), (100.0, 102.0))
    doAssert k.applySurvey(g, overwrite)
    doAssert k.srcPoint == 113 and k.rcvPoint == 102 and k.srcX == 1000 and k.rcvX == 1200
    doAssert k.srcIndex == 0, "the header's index stays; 0 matches the survey's 1"
  var k = traceAt(151, 2, (129.0, 113.0), (100.0, 102.0))
  doAssert k.joinStations(g) == jmStations
  # Source only: the receiver comes from the source's records (77 and 78
  # agree), not from record 151 (which would give 103).
  k = traceAt(151, 2, (129.0, 113.0), none)
  doAssert k.joinStations(g) == jmSource and k.rcvLine == 100 and k.rcvPoint == 102
  k = traceAt(151, 2, (129.0, 113.0), none)
  doAssert k.applySurvey(g) and k.rcvX == 1200
  # Receiver only: no O records, so record and channel, checked by the receiver.
  k = traceAt(151, 2, none, (100.0, 103.0))
  doAssert k.joinStations(g) == jmRecord and k.srcLine == 511 and k.srcPoint == 117
  k = traceAt(151, 2, none, (100.0, 102.0))
  doAssert k.joinStations(g) == jmConflict and k.srcLine.isNaN, "record 151 ch 2 is 100/103"
  # No station: the record number is the only key.
  k = traceAt(151, 2, none, none)
  doAssert k.joinStations(g) == jmRecord and k.srcPoint == 117 and k.rcvPoint == 103
  k = traceAt(152, 2, none, none)
  doAssert k.joinStations(g) == jmUnmatched and k.srcLine.isNaN
  k = traceAt(77, NaN, none, none)
  doAssert k.joinStations(g) == jmUnmatched
  # A source not in the relations, or a channel its records lack.
  k = traceAt(77, 2, (130.0, 113.0), none)
  doAssert k.joinStations(g) == jmUnmatched and k.rcvLine.isNaN
  k = traceAt(77, 9, (129.0, 113.0), none)
  doAssert k.joinStations(g) == jmUnmatched
  # Auxiliary traces are left alone.
  k = traceAt(151, 2, none, none)
  k.status = tsAuxiliary
  doAssert k.joinStations(g) == jmAuxiliary and not k.applySurvey(g) and k.srcLine.isNaN
  # Repeats that disagree: ambiguous, unless the record number picks one.
  var g2: SurveyGeometry
  g2.addSps(parseSps((joinSurvey[0 .. ^4] & @[
    x21("T1", 77, "129.00", "113.00", '1', 1, 4, '1', "100.00", "101.00", "104.00", '1'),
    x21("T1", 78, "129.00", "113.00", '1', 1, 4, '1', "100.00", "104.00", "101.00", '1')]).join("\n")))
  k = traceAt(151, 2, (129.0, 113.0), none)
  doAssert k.joinStations(g2) == jmAmbiguous and k.rcvLine.isNaN
  k = traceAt(78, 2, (129.0, 113.0), none)
  doAssert k.joinStations(g2) == jmSource and k.rcvPoint == 103
  # A point index that does not match is another station.
  k = traceAt(151, 2, (129.0, 113.0), none, srcIndex = 2)
  doAssert k.joinStations(g) == jmUnmatched
  doAssert sameStation(stationKey(1, 2, 0), stationKey(1, 2.000001, 1))
  doAssert not sameStation(stationKey(1, 2, 2), stationKey(1, 2, 1))

block join_enumeration_and_lookups:
  var g: SurveyGeometry
  g.addSps(parseSps(joinSurvey.join("\n")))
  var recs: seq[int64]
  for r in g.records: recs.add r
  doAssert recs == @[77'i64, 78, 151]
  var n = 0
  for (c, rel) in g.relations(151):
    inc n
    doAssert g.relation(151, c).get == rel
    doAssert rel.receiver.point == 105 - float64(c) and rel.source.point == 117
  doAssert n == 4 and g.expectedChannels(151) == 4 and g.expectedChannels(5) == 0
  doAssert g.recordsAt(stationKey(129, 113, 0)) == @[77'i64, 78]
  doAssert g.recordsAt(stationKey(129, 113, 1)) == @[77'i64, 78]
  doAssert g.recordsAt(stationKey(129, 113, 2)).len == 0
  doAssert g.recordsAt(stationKey(100, 101, 1), rdReceiver).len == 0
  doAssert g.channelOf(77, stationKey(100, 103, 0)) == some(3'i64)
  doAssert g.channelOf(151, stationKey(100, 103, 1)) == some(2'i64)
  doAssert g.channelOf(151, stationKey(100, 105, 1)).isNone
  doAssert g.channelOf(151, stationKey(101, 103, 1)).isNone
  # Overlapping runs: a channel is yielded once, for the earlier run.
  var g3: SurveyGeometry
  g3.addSps(parseSps([H00,
    x21("T1", 5, "1.00", "1.00", '1', 1, 4, '1', "100.00", "101.00", "104.00", '1'),
    x21("T1", 5, "1.00", "1.00", '1', 3, 6, '1', "200.00", "101.00", "104.00", '1')].join("\n")))
  var lines: seq[float64]
  for (c, rel) in g3.relations(5): lines.add rel.receiver.line
  doAssert lines == @[100.0, 100, 100, 100, 200, 200] and g3.log.count(sevWarning) == 1
  doAssert g3.channelOf(5, stationKey(200, 101, 1)).isNone, "channel 3 belongs to line 100"
  # Multi-component: k channels per station.
  var g4 = SurveyGeometry(multiComponent: true)
  g4.addSps(parseSps([H00, x21("T1", 7, "1.00", "1.00", '1', 1, 7, '3', "100.00", "101.00",
    "103.00", '1')].join("\n")))
  var comps: seq[int]
  for (c, rel) in g4.relations(7): comps.add rel.component
  doAssert comps == @[1, 2, 3, 1, 2, 3, 1, 2, 3]
  doAssert g4.channelOf(7, stationKey(100, 102, 1)) == some(4'i64)

# --------------------------------------------------------- receiver domain ---

proc pairs(g: SurveyGeometry, domain: RelationDomain): seq[(float64, float64, float64, float64)] =
  for r in g.records(domain):
    for (_, rel) in g.relations(r, domain):
      result.add (rel.source.line, rel.source.point, rel.receiver.line, rel.receiver.point)
  result.sort

block receiver_domain_o_records:
  # Read: an O record is a receiver's gather; the X layout with the roles swapped.
  let o = rec('O', [(2, "T1"), (8, align("12", 8)), (16, "1"), (17, "1"),
    (18, "100.00".align(10)), (28, "102.00".align(10)), (38, "1"), (39, align("1", 5)),
    (44, align("3", 5)), (49, "1"), (50, "129.00".align(10)), (60, "113.00".align(10)),
    (70, "115.00".align(10)), (80, "1")])
  let f = parseSps([H00, o].join("\n") & "\n")
  doAssert f.log.len == 0 and f.relations.len == 1 and f.relations[0].recordType == 'O'
  doAssert spsText(f).text == [H00, o].join("\n") & "\n"
  var edited = f
  edited.relations[0].raw = ""
  doAssert spsText(edited).text == [H00, o].join("\n") & "\n", "encoded with its letter"
  var g: SurveyGeometry
  g.addSps(f)
  doAssert g.relationCount(rdReceiver) == 1 and g.relationCount == 0
  let rel = g.relation(12, 2, rdReceiver).get
  doAssert rel.receiver == stationKey(100, 102, 1) and rel.source == stationKey(129, 114, 1)
  doAssert g.recordsAt(stationKey(100, 102, 0), rdReceiver) == @[12'i64]
  # A receiver gather trace with only its receiver station joins via the O gathers,
  # whatever its record number.
  var k = traceAt(NaN, 3, (NaN, NaN), (100.0, 102.0))
  doAssert k.joinStations(g) == jmReceiver and k.srcLine == 129 and k.srcPoint == 115
  k = traceAt(NaN, 4, (NaN, NaN), (100.0, 102.0))
  doAssert k.joinStations(g) == jmUnmatched
  # `.ops` files may hold O relations as X records.
  doAssert relationDomainOf("a/b.OPS") == rdReceiver and relationDomainOf("b.xps") == rdSource
  var g2: SurveyGeometry
  g2.addSps(parseSps([H00, "X" & o[1 .. ^1]].join("\n")), xDomain = rdReceiver)
  doAssert g2.relation(12, 2, rdReceiver) == some(rel)
  var bad = f.relations[0]
  bad.recordType = 'Y'
  doAssertRaises(SegFormatError): discard encodeSps(bad, sps21)

block receiver_domain_from_x:
  # Sources 20/201..203 record receivers 10/101..105; 21/201 records 10/103..107
  # (descending); a repeat of 20/202 (record 4) records 10/101..102; line 11 too.
  let x = [H00,
    x21("T1", 1, "20.00", "201.00", '1', 1, 5, '1', "10.00", "101.00", "105.00", '1'),
    x21("T1", 2, "20.00", "202.00", '1', 1, 5, '1', "10.00", "101.00", "105.00", '1'),
    x21("T1", 3, "20.00", "203.00", '1', 1, 5, '1', "10.00", "101.00", "105.00", '1'),
    x21("T1", 3, "20.00", "203.00", '1', 6, 7, '1', "11.00", "101.00", "102.00", '1'),
    x21("T1", 4, "20.00", "202.00", '1', 1, 2, '1', "10.00", "101.00", "102.00", '1'),
    x21("T1", 5, "21.00", "201.00", '1', 1, 5, '1', "10.00", "107.00", "103.00", '1')]
  var g: SurveyGeometry
  g.addSps(parseSps(x.join("\n")))
  let rels = g.receiverRelations()
  doAssert rels.len > 0 and rels[0].fieldRecord == 1 and rels[0].recordType == 'O'
  # Gather 1 is receiver 10/101: sources 20/201..203 as one run, then the
  # repeat of 20/202 as a run of its own.
  doAssert rels[0].srcLine == 10 and rels[0].srcPoint == 101
  doAssert rels[0].rcvLine == 20 and rels[0].fromReceiver == 201 and rels[0].toReceiver == 203
  doAssert rels[0].fromChannel == 1 and rels[0].toChannel == 3
  let o = SpsFile(revision: sps21, headers: parseSps(H00).headers, relations: rels)
  let text = spsText(o)
  doAssert not text.log.hasErrors
  let back = parseSps(text.text)
  doAssert back.log.len == 0 and spsText(back).text == text.text, "reads back byte-identical"
  var go: SurveyGeometry
  go.addSps(back)                         # O records: receiver domain
  doAssert go.pairs(rdReceiver) == g.pairs(rdSource), "X → O → pairs equals X's pairs"
  var gathers: seq[int64]
  for r in go.records(rdReceiver): gathers.add r
  doAssert gathers == @[1'i64, 2, 3, 4, 5, 6, 7, 8, 9], $gathers # 10/101..107, 11/101..102
  doAssert go.recordsAt(stationKey(11, 102, 1), rdReceiver) == @[9'i64]
  let oo = g.receiverRelations(firstGather = 100, recordType = 'X')
  doAssert oo[0].recordType == 'X' and oo[0].fieldRecord == 100
  var gx: SurveyGeometry
  gx.addSps(SpsFile(revision: sps21, relations: oo), xDomain = rdReceiver)
  doAssert gx.pairs(rdReceiver) == g.pairs(rdSource), "X-lettered O records, read as O"

  doAssertRaises(ValueError): discard g.receiverRelations(recordType = 'Z')

# --------------------------------------------------------- review (10.4) ---

block review_p1_non_p1_lines_stay_raw:
  let text = ["HAREA", p1a, " BAD RECORD here", p1b].join("\n") & "\n"
  let f = parseP1(text)
  doAssert f.files[0].records[1].raw == " BAD RECORD here"
  doAssert f.files[0].records[1].latitude.isNaN
  doAssert p1Text(f).text == text

block review_sps_h00_date_is_not_rev21:
  let f = parseSps("H00 SPS format version num.      SPS001,12.10.90;\n")
  doAssert f.revision == sps10 and f.revisionDeclared
  doAssert parseSps("H00 SPS format version number   SPS 2.1;").revision == sps21
  doAssert parseSps("H00 x                           sps2.1").revision == sps21

block review_line_splitter:
  # NUL is data; CR-only endings; exact CR LF detection; no final newline.
  let f = parseSps(H00 & "\n\0\n" & rcv1 & "\n")
  doAssert f.points.len == 1 and f.others == @["\0"]
  let cr = parseSps([H00, rcv1, rcv2].join("\r"))
  doAssert cr.points.len == 2 and not cr.crlf and not cr.finalNewline
  doAssert spsText(cr, SpsWriteOptions(lineEnding: "\r")).text == [H00, rcv1, rcv2].join("\r")
  let mixed = parseSps(H00 & "\r\n" & rcv1 & "\n")
  doAssert mixed.crlf and mixed.points.len == 1
  var recs: seq[TextRecord]
  for r in textRecords(newStringStream("ab\r\ncd\ref"), tlLines): recs.add r
  doAssert recs.len == 3 and recs[0].text == "ab" and recs[0].crlf and recs[1].text == "cd"
  doAssert not recs[1].crlf and recs[1].terminated and recs[2].text == "ef"
  doAssert not recs[2].terminated and recs[2].offset == 7
  let long = parseSps(repeat('R', MaxLineBytes + 10))
  doAssert long.log.count(sevWarning) >= 1

block review_detect_sps_or_p1:
  doAssert looksLikeSps(newStringStream([H00, src1, x1].join("\n")))
  doAssert not looksLikeSps(newStringStream(["H AREA", "CLIENT: SHELL", p1a].join("\n")))
  let eb = encodeEbcdic(H00.alignLeft(80) & src1)
  var ebs = newString(eb.len)
  for i, b in eb: ebs[i] = char(b)
  doAssert looksLikeSps(newStringStream(ebs))

block review_p1_digit_in_header:
  let f = parseP1(["HAREA", "1979 SURVEY", " NOTE", p1a].join("\n"))
  doAssert f.files[0].format == pfP1 and f.files[0].header.len == 3
  doAssert f.files[0].records.len == 1 and f.files[0].records[0].point == 12340

block review_p1_point_edit:
  var f = parseP1(["H X", p1a].join("\n"))
  f.files[0].records[0].point = 99999
  doAssert p1Text(f).text.splitLines[1].col(18, 25) == "   99999"

block review_round_trips:
  # Decimals used to read are used to write.
  let text = ["H X", p1a].join("\n") & "\n"
  let f = parseP1(text, opts = P1Options(gridDecimals: 2))
  doAssert f.files[0].records[0].easting == 1555.90
  doAssert p1Text(f).text == text
  var g = f
  g.files[0].records[0].easting = 1555.91
  doAssert p1Text(g).text.splitLines[1].col(46, 53) == "  155591"
  # SPS strict mode round-trips.
  let line = rec('S', [(2, "5646".align(10)), (12, "534550".align(10)), (24, "1V6"),
    (47, "2385700".align(9)), (56, "30583800".align(10))])
  let st = parseSps(line & "\n", opts = SpsOptions(revision: sps21, strictImpliedDecimals: true))
  doAssert st.points[0].easting == 238570.0
  doAssert spsText(st).text == line & "\n"
  # No final newline stays so; an H record without a code is written back.
  let nofinal = [H00, "H", rcv1].join("\n")
  doAssert spsText(parseSps(nofinal)).text == nofinal

block review_overflow_is_an_error:
  var f = parseSps([H00, rcv1].join("\n") & "\n")
  f.points[0].staticCorrection = 1e300
  doAssert writeSps(f, newStringStream()).count(sevError) == 1
  f.points[0].staticCorrection = NaN
  f.points[0].easting = Inf
  doAssert writeSps(f, newStringStream()).count(sevError) == 1
  var p = parseP1(["H X", p1a].join("\n"))
  p.files[0].records[0].northing = 1e300
  doAssert writeP1(p, newStringStream()).count(sevError) == 1

block review_stale_order_and_wide_index:
  var f = parseSps([H00, rcv1, rcv2].join("\n") & "\n")
  f.points.setLen(1)
  doAssert writeSps(f, newStringStream()).count(sevError) == 1
  var g: SurveyGeometry
  var built = parseSps([H00, rcv1].join("\n"))
  built.points[0].index = 100_000
  g.addSps(built) # clamps instead of a RangeDefect
  doAssert g.table.receivers.len == 1

block encode_needs_a_revision:
  # `spsAuto` is not a target: bad caller input is a ValueError, not an assert.
  doAssertRaises(ValueError): discard encodeSps(initSpsPoint(), spsAuto)
  doAssertRaises(ValueError): discard encodeSps(initSpsRelation(), spsAuto)
  var g: SurveyGeometry
  doAssert g.resolveLine("CLT4960", NaN).isNone
  g.trailingDigits = true
  doAssert g.resolveLine("CLT4960", NaN) == some(4960.0) and g.resolveLine("x", 7) == some(7.0)

# Phase 8 review.
block p8_geometry_overwrite_semantics:
  # Filling one end keeps a signed SEG-Y header offset and a known elevation.
  var k = initTraceKeys()
  (k.srcX, k.srcY, k.offset, k.rcvZ) = (0.0, 0.0, -250.0, 12.0)
  (k.rcvLine, k.rcvPoint) = (1.0, 2.0)
  var g: GeometryTable
  g.addReceiver(1, 2, 0, 300, 400) # no z
  doAssert k.applyGeometry(g)
  doAssert k.offset == -250 and k.rcvZ == 12 and k.cmpX == 150
  doAssert k.applyGeometry(g, overwrite = true) and k.offset == 500

block a_join_that_changes_nothing_is_no_change:
  # With `overwrite` a trace that already holds the survey's values is not
  # changed: no count, no new `keysRevision`, and the index is not "joined"
  # (so `saveIndex` still takes it).
  var t: GeometryTable
  t.addReceiver(10, 101, 1, 5, 6, 7)
  var k = initTraceKeys()
  (k.rcvLine, k.rcvPoint) = (10.0, 101.0)
  doAssert k.applyGeometry(t, overwrite = true) and k.rcvX == 5 and k.rcvZ == 7
  doAssert not k.applyGeometry(t, overwrite = true) and not k.applyGeometry(t)
  k.rcvZ = 8
  doAssert k.applyGeometry(t, overwrite = true) and k.rcvZ == 7, "only the elevation differed"
  let dir = getTempDir() / "tsurvey_nochange"
  createDir(dir)
  writeRecordSegd(dir / "record.sgd") # file 63, channel 1: source 20/99.5, receiver 10/104
  var g: SurveyGeometry
  g.addSps(parseSps([H00,
    r21('R', "10.00", "104.00", '1', "G1", "500100.0", "6000000.0", "12.5"),
    r21('S', "20.00", "99.50", '1', "V6", "500000.0", "6000400.0", "10.0", " 19001150")].join("\n")))
  var f = openSeismic(dir / "record.sgd", keys = true)
  var stats: JoinStats
  doAssert f.applySurvey(initSurveyGeometry(), stats) == 0 and stats.changed == 0
  doAssert f.index.applyGeometry(GeometryTable()) == 0
  doAssert f.keysRevision == 0 and not f.index.joined
  f.saveIndex(dir / "record.idx") # an index no join changed is the file's own
  doAssert f.applySurvey(g, stats, overwrite = true) == 1 and stats.changed == 1
  doAssert f.keysRevision == 1 and f.index.joined
  let joined = f.index.joinedGroups(0)
  for _ in 1 .. 2:
    doAssert f.applySurvey(g, stats, overwrite = true) == 0 and stats.changed == 0, $stats
    doAssert stats.matches[jmStations] == 1 and f.index.applyGeometry(g.table, true) == 0
    doAssert f.keysRevision == 1 and f.index.joinedGroups(0) == joined
  doAssertRaises(ValueError): f.saveIndex(dir / "record.idx")
  f.close()
  removeDir(dir)

block a_station_part_in_the_header_checks_the_relation:
  # A header with only one part of a station (a SEG-Y shotpoint without a
  # line) has it filled whole only when the relation agrees with that part.
  var g: SurveyGeometry
  g.addSps(parseSps((@joinSurvey & @[
    x21("T1", 63, "13.00", "99.50", '1', 1, 1, '1', "13.00", "104.00", "104.00", '1')]).join("\n")))
  const none = (NaN, NaN)
  # Record 151, channel 2 is source 511/117, receiver 100/103.
  var k = traceAt(151, 2, (NaN, 117.0), none)
  doAssert k.joinStations(g) == jmRecord and k.srcLine == 511 and k.rcvPoint == 103
  k = traceAt(151, 2, (NaN, 2345.0), none)
  doAssert k.joinStations(g) == jmConflict, "the record's source point is 117"
  doAssert k.srcLine.isNaN and k.srcPoint == 2345 and k.rcvLine.isNaN and k.rcvPoint.isNaN
  doAssert not k.applySurvey(g) and k.srcX.isNaN
  k = traceAt(151, 2, (511.0, NaN), (100.0, NaN))
  doAssert k.joinStations(g) == jmRecord and k.srcPoint == 117 and k.rcvPoint == 103
  k = traceAt(151, 2, (129.0, NaN), none)
  doAssert k.joinStations(g) == jmConflict and k.srcPoint.isNaN, "the record's source line is 511"
  k = traceAt(151, 2, none, (NaN, 102.0))
  doAssert k.joinStations(g) == jmConflict and k.srcLine.isNaN, "channel 2 is receiver 103"
  # The part of the station the header lacks beside a whole one.
  k = traceAt(151, 2, (129.0, 113.0), (NaN, 102.0))
  doAssert k.joinStations(g) == jmSource and k.rcvLine == 100 and k.rcvPoint == 102
  k = traceAt(151, 2, (129.0, 113.0), (NaN, 103.0))
  doAssert k.joinStations(g) == jmConflict and k.rcvLine.isNaN, "source 129/113 ch 2 is 102"
  # An integer header field holds 99.5 as 100: that is the same point, and
  # the survey's value replaces it. 99 is another point.
  k = traceAt(63, 1, (NaN, 100.0), none)
  doAssert k.joinStations(g) == jmRecord and k.srcLine == 13 and k.srcPoint == 99.5
  k = traceAt(63, 1, (NaN, 99.0), none)
  doAssert k.joinStations(g) == jmConflict and k.srcPoint == 99
  # A point index the header has is a part too.
  k = traceAt(63, 1, (NaN, 100.0), none, srcIndex = 2)
  doAssert k.joinStations(g) == jmConflict and k.srcIndex == 2

block sps10_without_h00_is_read_as_10:
  # Records the library's own 1.0 encoder writes, read back without an H00
  # record: the columns decide, also for numeric line names, five-digit
  # points and relation records (they used to be read with the 2.1 columns).
  proc point10(line, point: string): string =
    var p = initSpsPoint(pkReceiver)
    (p.lineName, p.line) = (line, parseFortranFloat(line).get(NaN))
    (p.pointName, p.point) = (point, parseFortranFloat(point).get(NaN))
    (p.code, p.easting, p.northing, p.elevation) = ("G1", 500000.0, 6000000.0, 100.0)
    encodeSps(p, sps10)
  proc relation10(record: int, srcLine, srcPoint, rcvLine, fromR, toR: string,
      toCh: int): string =
    var r = initSpsRelation()
    (r.fieldTape, r.fieldRecord, r.fromChannel, r.toChannel) = ("T1", int64(record), 1'i64,
      int64(toCh))
    (r.srcLineName, r.srcLine) = (srcLine, parseFortranFloat(srcLine).get(NaN))
    (r.srcPointName, r.srcPoint) = (srcPoint, parseFortranFloat(srcPoint).get(NaN))
    (r.rcvLineName, r.rcvLine) = (rcvLine, parseFortranFloat(rcvLine).get(NaN))
    (r.fromReceiverName, r.fromReceiver) = (fromR, parseFortranFloat(fromR).get(NaN))
    (r.toReceiverName, r.toReceiver) = (toR, parseFortranFloat(toR).get(NaN))
    encodeSps(r, sps10)
  var text = ""
  for i in 0 ..< 60: text.add point10("1001", $(10001 + i)) & "\r\n"
  var f = parseSps(text)
  doAssert f.revision == sps10 and not f.revisionDeclared
  doAssert f.log.count(sevWarning) == 1 and f.log.has("no SPS revision in H00", sevWarning)
  doAssert f.points[0].line == 1001 and f.points[0].point == 10001 and f.points[0].index == 1
  doAssert f.points[0].code == "G1" and f.points[59].point == 10060
  for (lineName, point, last) in [("91LW1124", "225", 261), ("1228.339", "7", 99)]:
    f = parseSps(point10(lineName, point) & "\n")
    doAssert f.revision == sps10 and f.points[0].lineName == lineName, lineName
    doAssert f.points[0].point == parseFloat(point) and f.points[0].code == "G1"
  # The spec's own 1.0 X example shape (alphanumeric lines), and numeric lines.
  f = parseSps(relation10(1, "91LW1117", "225", "91LW1124", "225", "261", 37) & "\n")
  doAssert f.revision == sps10 and f.log.count(sevWarning) == 1, $f.log
  var r = f.relations[0]
  doAssert r.fieldRecord == 1 and r.srcLineName == "91LW1117" and r.srcPoint == 225
  doAssert r.fromChannel == 1 and r.toChannel == 37 and r.channelIncrement == 1
  doAssert r.rcvLineName == "91LW1124" and r.fromReceiver == 225 and r.toReceiver == 261
  f = parseSps(relation10(7, "1001", "10225", "2001", "10101", "10220", 120) & "\n")
  doAssert f.revision == sps10
  r = f.relations[0]
  doAssert r.fieldRecord == 7 and r.srcLine == 1001 and r.srcPoint == 10225 and r.toChannel == 120
  doAssert r.rcvLine == 2001 and r.fromReceiver == 10101 and r.toReceiver == 10220
  # The 2.1 records of the same values still read as 2.1.
  f = parseSps([rcv1, rcv2, src1, x1].join("\n"))
  doAssert f.revision == sps21 and f.points[0].point == 534550 and f.relations[0].toChannel == 320
  # A caller's revision is no guess: nothing to warn about.
  doAssert parseSps(rcv1, opts = SpsOptions(revision: sps21)).log.len == 0

block sps_h00_spellings_of_the_revision:
  for (data, rev) in [("SPS001,01.10.90;", sps10), ("SPS V1.0", sps10), ("SPS REV 1.0", sps10),
      ("SPS 1.0;", sps10), ("sps rev. 1.0", sps10), ("SPS 2.1;", sps21), ("SPS V2.1", sps21),
      ("SPS REV 2.1", sps21), ("SPS Revision 2.1", sps21), ("SPS Version 1.0", sps10)]:
    let f = parseSps("H00 SPS format version num.     " & data & "\n")
    doAssert f.revisionDeclared and f.revision == rev, data
  # Not a revision: the columns decide (no data records: 2.1), with a warning.
  for data in ["SEG-P1", "SPS", "SPS 12.10.90", "SPS 3.0", "12.10.90 SPS 2.1"]:
    let f = parseSps("H00 SPS format version num.     " & data & "\n")
    doAssert not f.revisionDeclared and f.log.count(sevWarning) == 1, data

# ------------------------------------------------------- text readers ---

block reader_diagnostics_are_capped_per_code_and_field:
  # A file of bad records logs a few diagnostics of each kind and a count,
  # not three per record (1e6 lines of "R" took 1.4 GB of log).
  var text = H00 & "\n"
  for _ in 0 ..< 1000: text.add "R\n"
  let f = parseSps(text)
  doAssert f.points.len == 1000
  doAssert f.log.count(sevWarning) == 15, $f.log.count(sevWarning) # no line, point, coordinates
  doAssert f.log.count(sevInfo) == 3 and f.log.has("995 more", sevInfo), $f.log
  # P1: a bad easting in every record.
  var p = "H X\n"
  for _ in 0 ..< 300: p.add p1a[0 .. 44] & "  15x590" & p1a[53 .. ^1] & "\n"
  let g = parseP1(p)
  doAssert g.files[0].records.len == 300 and g.files[0].records[299].easting.isNaN
  doAssert g.log.count(sevWarning) == 5 and g.log.has("295 more", sevInfo), $g.log
  # The join's own notes too.
  var s = initSurveyGeometry()
  var bad = SpsFile(name: "bad")
  for _ in 0 ..< 100: bad.relations.add initSpsRelation() # no record, no channels
  s.addSps(bad)
  doAssert s.log.count(sevWarning) == 5 and s.log.has("95 more", sevInfo), $s.log

block blank_columns_past_80_are_not_reported:
  let f = parseSps([H00, rcv1 & "    ", rcv2 & "  x"].join("\n"))
  doAssert f.points.len == 2 and f.log.len == 1, $f.log
  doAssert f.log.has("record longer than 80 columns (83)", sevInfo)

block a_built_sps_file_is_written:
  # `SpsFile()` used to hold `spsAuto`, which is no layout: writing it was
  # an IndexDefect.
  let src = parseSps([H00, rcv1, rcv2].join("\n") & "\n")
  var sel = SpsFile(name: "selection")
  doAssert sel.revision == sps21
  sel.points.add src.points[1]
  var t = spsText(sel)
  doAssert t.log.len == 0 and t.text == rcv2 & "\n", t.text
  sel.points[0].raw = ""
  sel.revision = spsAuto # set by hand: still the 2.1 layout
  t = spsText(sel)
  doAssert t.log.len == 0 and parseSps(t.text, opts = SpsOptions(revision: sps21)).points[0].point ==
    534600
  var x = SpsFile()
  var r = initSpsRelation()
  (r.fieldRecord, r.fromChannel, r.toChannel) = (7'i64, 1'i64, 4'i64)
  (r.srcLine, r.srcPoint, r.rcvLine, r.fromReceiver, r.toReceiver) = (1.0, 2.0, 3.0, 4.0, 7.0)
  x.relations.add r
  let xt = spsText(x)
  doAssert xt.log.len == 0, $xt.log
  doAssert parseSps(xt.text, opts = SpsOptions(revision: sps21)).relations[0].toReceiver == 7

block survey_numbers_are_finite:
  for t in ["inf", "-inf", "nan", "1e999", "-1E999", "Infinity"]:
    doAssert parseFortranFloat(t).isNone and parseFortranFloat(t, 2).isNone, t
  doAssert parseFortranFloat("1e3") == some(1000.0)
  let f = parseSps([H00, rcv1[0 .. 45] & "      inf" & rcv1[55 .. ^1],
    rcv2[0 .. 45] & "    1e999" & rcv2[55 .. ^1]].join("\n"))
  doAssert f.points[0].easting.isNaN and f.points[1].easting.isNaN
  doAssert f.log.has("not a number: 'inf'", sevWarning) and f.log.has("'1e999'", sevWarning)

block a_station_given_twice_is_logged:
  let moved = r21('R', "5646.00", "534550.00", '1', "G1", "999999.0", "3058380.0", "83.2")
  var g: SurveyGeometry
  g.addSps(parseSps([H00, rcv1, rcv2, moved, rcv2].join("\n")))
  doAssert g.receiverCount == 2
  doAssert g.table.receivers[stationKey(5646, 534550, 1)].x == 999999, "the later one is used"
  doAssert g.log.count(sevWarning) == 1 and g.log.has("other coordinates", sevWarning), $g.log
  doAssert g.log.count(sevInfo) == 1 and g.log.has("same coordinates", sevInfo), $g.log

block a_byte_order_mark_is_not_a_record:
  const bom = "\xEF\xBB\xBF"
  var f = parseSps(bom & [H00, rcv1, x1].join("\n") & "\n")
  doAssert f.revisionDeclared and f.headers.len == 1 and f.points.len == 1 and f.log.len == 0
  doAssert f.others.len == 0
  f = parseSps(bom & [rcv1, rcv2].join("\r\n") & "\r\n", opts = SpsOptions(revision: sps21))
  doAssert f.points.len == 2 and f.points[0].line == 5646 and f.crlf and f.log.len == 0
  doAssert looksLikeSps(newStringStream(bom & [H00, src1, x1].join("\n")))
  let p = parseP1(bom & ["H X", p1a].join("\n") & "\n")
  doAssert p.files.len == 1 and p.files[0].header == @["H X"] and p.files[0].records.len == 1
  doAssert p.log.len == 0, $p.log

block a_time_with_a_blank_for_a_leading_zero:
  let f = parseSps([H00, rcv1[0 .. 73] & " 91530", rcv2[0 .. 73] & "9 1530"].join("\n"))
  let p = f.points[0]
  doAssert p.hour == 9 and p.minute == 15 and p.second == 30
  doAssert f.log.len == 1 and f.log.has("not hhmmss: '9 1530'", sevWarning), $f.log
  doAssert spsText(f).text.splitLines[1] == rcv1[0 .. 73] & " 91530" # unchanged: as read

block p1_says_why_it_decoded_nothing:
  proc p1rec(point: int, lat, lon: float64, unit = auDms): string =
    var r = initP1Record()
    (r.lineName, r.pointName, r.point) = ("CLT4960", $point, float64(point))
    (r.latitude, r.longitude, r.angleUnit) = (lat, lon, unit)
    (r.easting, r.northing, r.depthOrElevation) = (155590.0, 161670.0, 857.0)
    encodeP1(r)
  # Grid coordinates only: the records are not recognised, and the log says so.
  var t = "H SEG P1 POSTPLOT\n UNITS: METERS\n"
  for i in 0 ..< 50: t.add p1rec(1000 + i, NaN, NaN) & "\n"
  var f = parseP1(t)
  doAssert f.files.len == 1 and f.files[0].records.len == 0
  doAssert f.log.count(sevWarning) == 1 and f.log.has("no data records", sevWarning), $f.log
  doAssert f.log.has("50 of them", sevWarning) and f.log.has("latitude", sevWarning), $f.log
  doAssert p1Text(f).text == t # still written back as read
  # A header line that passes for P3 data (a 1 in column 36) no longer
  # makes the logical file P3: the P1 records after it are decoded.
  t = "H SEG P1 POSTPLOT\n" & " NUMBER OF SOURCES:".alignLeft(35) & "1 2\n"
  for i in 0 ..< 50: t.add p1rec(1000 + i, 17.9 + float64(i) * 1e-4, 110.7) & "\n"
  f = parseP1(t)
  doAssert f.files[0].format == pfP1 and f.files[0].records.len == 51
  doAssert f.files[0].records[0].point.isNaN and f.files[0].records[50].point == 1049
  doAssert f.log.len == 1 and f.log.has("not a P1 data record", sevWarning), $f.log
  # A logical file taken as another format says so when it holds P1 records.
  f = parseP1(["H P4 FILE", "S00001 001 doppler", "S00002 001 doppler", "S00003 001 doppler",
    p1a, p1b].join("\n"))
  doAssert f.files[0].format == pfP4 and f.files[0].records.len == 5
  doAssert f.log.len == 2 and f.log.has("look like P1 data", sevWarning), $f.log

block p1_angle_unit_is_decided_once_per_file:
  # In a grads file four angles in ten also read as valid DMS: deciding per
  # angle decoded those as DMS without a word.
  proc p1rec(point: int, lat, lon: float64, unit: AngleUnit): string =
    var r = initP1Record()
    (r.lineName, r.pointName, r.point) = ("L1", $point, float64(point))
    (r.latitude, r.longitude, r.angleUnit) = (lat, lon, unit)
    (r.easting, r.northing) = (155590.0, 161670.0)
    encodeP1(r)
  var t = "H ANGLES IN GRADS\n"
  var truth: seq[(float64, float64)]
  for i in 0 ..< 400:
    # A deterministic spread of the minute and second digits.
    let lat = 40.0 + float64((i * 7919) mod 100_000) / 10_000
    let lon = 1.0 + float64((i * 104_729) mod 80_000) / 10_000
    truth.add (lat, lon)
    t.add p1rec(i, lat, lon, auGrads) & "\n"
  for unit in [auAuto, auGrads]:
    let f = parseP1(t, opts = P1Options(angleUnit: unit))
    doAssert f.options.angleUnit == auGrads
    for i, r in f.files[0].records:
      doAssert abs(r.latitude - truth[i][0]) < 1e-4 and abs(r.longitude - truth[i][1]) < 1e-4, $i
      doAssert r.angleUnit == auGrads
    doAssert f.log.len == (if unit == auAuto: 1 else: 0), $f.log
    doAssert p1Text(f).text == t
  doAssert parseP1(t).log.has("read as grads", sevInfo)
  # DMS files stay DMS and silent; one bad angle is a warning, not grads.
  var d = "H X\n"
  for i in 0 ..< 30: d.add p1rec(i, 17.5 + float64(i) / 100, 110.25, auDms) & "\n"
  var f = parseP1(d)
  doAssert f.options.angleUnit == auDms and f.log.len == 0
  doAssert abs(f.files[0].records[7].latitude - 17.57) < 1e-6
  d.add p1a[0 .. 25] & "17613354N" & p1a[35 .. ^1] & "\n" # 61 minutes
  f = parseP1(d)
  doAssert f.options.angleUnit == auDms and f.files[0].records[30].latitude.isNaN
  doAssert f.log.len == 1 and f.log.has("bad latitude", sevWarning), $f.log

# ------------------------------------------------------- relation runs ---

block relation_lookups_agree_with_a_scan_in_file_order:
  # A record whose runs ascend without sharing a channel is searched; any
  # other is scanned in file order (a channel two runs cover belongs to the
  # earlier one). Both must give what a plain scan of the X rows gives.
  type Row = tuple[fromCh, toCh, step: int, line, first, last: float64]
  proc model(rows: seq[Row], multi: bool, channel: int): (bool, float64, float64, int) =
    # The first row in file order that covers `channel`: found, line, point, component.
    for r in rows:
      let last = if multi: r.toCh + r.step - 1 else: r.toCh
      if channel >= r.fromCh and channel <= last and
          (multi or (channel - r.fromCh) mod r.step == 0):
        let n = (r.toCh - r.fromCh) div r.step
        let i = (channel - r.fromCh) div r.step
        let p = if n == 0: r.first
                else: r.first + float64(i) * (r.last - r.first) / float64(n)
        return (true, r.line, round(p * 100) / 100,
          if multi and r.step > 1: (channel - r.fromCh) mod r.step + 1 else: 0)
  var seed = 12345'u32
  proc next(n: int): int =
    seed = seed * 1664525'u32 + 1013904223'u32
    int(seed shr 8) mod n
  for trial in 0 ..< 60:
    var rows: seq[Row]
    var ch = 1
    let kind = trial mod 4 # 0, 1: ascending and disjoint; 2: shuffled; 3: overlapping
    for j in 0 ..< 2 + next(12):
      let step = if next(3) == 0: 1 + next(3) else: 1
      let stations = 1 + next(9)
      let first = 100.0 + float64(next(50))
      let last = if next(4) == 0: first - float64(stations - 1) * 0.5
                 else: first + float64(stations - 1)
      let start = if kind == 3 and j > 0 and next(2) == 0: max(1, ch - 1 - next(4)) else: ch
      rows.add (start, start + (stations - 1) * step, step, float64(10 + j), first, last)
      ch = max(ch, start + stations * step) + next(3)
    if kind == 2:
      for j in countdown(rows.high, 1): swap rows[j], rows[next(j + 1)]
    var f = SpsFile()
    for r in rows:
      var x = initSpsRelation()
      (x.fieldRecord, x.fromChannel, x.toChannel, x.channelIncrement) =
        (9'i64, int64(r.fromCh), int64(r.toCh), r.step)
      (x.srcLine, x.srcPoint, x.srcIndex) = (1.0, 2.0, 1)
      (x.rcvLine, x.fromReceiver, x.toReceiver, x.rcvIndex) = (r.line, r.first, r.last, 1)
      f.relations.add x
    for multi in [false, true]:
      var g = SurveyGeometry(multiComponent: multi)
      g.addSps(f)
      var expected = 0
      var listed: seq[int64]
      for (c, rel) in g.relations(9): listed.add c
      var want: seq[int64]
      for j, r in rows: # the iterator goes run by run, in file order
        for c in r.fromCh .. (if multi: r.toCh + r.step - 1 else: r.toCh):
          if model(@[r], multi, c)[0]:
            var earlier = false
            for o in 0 ..< j:
              if model(@[rows[o]], multi, c)[0]: earlier = true
            if not earlier: want.add int64(c)
      for c in 0 .. ch + 4:
        let m = model(rows, multi, c)
        let rel = g.relation(9, int64(c))
        doAssert rel.isSome == m[0], $trial & " channel " & $c
        if m[0]:
          inc expected
          doAssert rel.get.receiver == stationKey(m[1], m[2], 1) and rel.get.component == m[3],
            $trial & " channel " & $c
      doAssert g.expectedChannels(9) == expected, $trial & ": " & $g.expectedChannels(9)
      doAssert listed == want, $trial
      doAssert kind >= 2 or g.relationsDisjoint(9), $trial
      for (c, rel) in g.relations(9): doAssert g.relation(9, c).get == rel

block relation_runs_walk_a_record_station_by_station:
  var g: SurveyGeometry
  g.addSps(parseSps(joinSurvey.join("\n")))
  # Record 151: channels 1-4 are receivers 100/104 down to 101, source 511/117.
  var n = 0
  for run in g.relationRuns(151):
    inc n
    doAssert run.fromChannel == 1 and run.toChannel == 4 and run.channelStep == 1
    doAssert run.stations == 4 and run.components == 1
    doAssert run.fixed == stationKey(511, 117, 1) and run.line == 100 and run.index == 1
    doAssert run.firstPoint == 104 and run.lastPoint == 101 and run.pointStep == -1
    doAssert run.station(0) == stationKey(100, 104, 1) and run.station(3) ==
      stationKey(100, 101, 1)
  doAssert n == 1 and g.relationsDisjoint(151) and g.relationsDisjoint(5)
  for _ in g.relationRuns(5): doAssert false, "no such record"
  # The runs give what the per-channel iterator gives, for every record of
  # both domains, also multi-component and with fractional point steps.
  var m = SurveyGeometry(multiComponent: true)
  m.addSps(parseSps([H00,
    x21("T1", 7, "1.00", "1.00", '1', 1, 7, '3', "100.00", "101.00", "102.00", '1'),
    x21("T1", 7, "1.00", "1.00", '1', 10, 13, '1', "200.00", "50.50", "49.00", '2'),
    x21("T1", 8, "1.00", "2.00", '1', 5, 5, '1', "200.00", "77.00", "77.00", '1')].join("\n")))
  var o = initSurveyGeometry()
  var ops = SpsFile()
  ops.relations = g.receiverRelations()
  o.addSps(ops)
  for (s, domain) in [(g, rdSource), (m, rdSource), (o, rdReceiver)]:
    for rec in s.records(domain):
      doAssert s.relationsDisjoint(rec, domain)
      var fromRuns, fromChannels: seq[(int64, StationRelation)]
      for run in s.relationRuns(rec, domain):
        for i in 0 ..< run.stations:
          for c in 0 ..< run.components:
            var rel = StationRelation(component: if run.components > 1: c + 1 else: 0)
            if domain == rdSource: (rel.source, rel.receiver) = (run.fixed, run.station(i))
            else: (rel.source, rel.receiver) = (run.station(i), run.fixed)
            fromRuns.add (run.fromChannel + int64(i) * run.channelStep + int64(c), rel)
      for (c, rel) in s.relations(rec, domain): fromChannels.add (c, rel)
      doAssert fromRuns == fromChannels, $rec
  var runs = 0
  for run in m.relationRuns(7):
    inc runs
    if run.fromChannel == 1:
      doAssert run.stations == 3 and run.components == 3 and run.toChannel == 9
      doAssert run.pointStep == 0.5 and run.station(1) == stationKey(100, 101.5, 1)
    else:
      doAssert run.stations == 4 and run.pointStep == -0.5 and run.index == 2
  doAssert runs == 2
  # Overlapping runs are yielded as the file gives them, and the record says so.
  var g3: SurveyGeometry
  g3.addSps(parseSps([H00,
    x21("T1", 5, "1.00", "1.00", '1', 1, 4, '1', "100.00", "101.00", "104.00", '1'),
    x21("T1", 5, "1.00", "1.00", '1', 3, 6, '1', "200.00", "101.00", "104.00", '1')].join("\n")))
  doAssert not g3.relationsDisjoint(5) and g3.expectedChannels(5) == 6
  var covered = 0
  for run in g3.relationRuns(5): covered += run.stations
  doAssert covered == 8

block a_record_of_thousands_of_rows:
  # One X row per channel (some recorders write them so): lookups must not
  # scan the record's earlier rows per channel.
  var f = SpsFile()
  for c in 1 .. 20_000:
    var x = initSpsRelation()
    (x.fieldRecord, x.fromChannel, x.toChannel) = (1'i64, int64(c), int64(c))
    (x.srcLine, x.srcPoint, x.rcvLine) = (1.0, 2.0, 3.0)
    (x.fromReceiver, x.toReceiver) = (float64(c), float64(c))
    f.relations.add x
  var g: SurveyGeometry
  g.addSps(f)
  doAssert g.log.len == 0 and g.relationCount == 20_000 and g.expectedChannels(1) == 20_000
  var n = 0
  for (c, rel) in g.relations(1):
    inc n
    doAssert rel.receiver.point == float64(c) and g.relation(1, c).get == rel
  doAssert n == 20_000 and g.channelOf(1, stationKey(3, 777, 1)) == some(777'i64)
  doAssert g.receiverRelations().len == 20_000
