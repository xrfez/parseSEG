## Survey files (Phase 10): SPS 1.0/2.1, SEG P1-P4 (1983), and joining them
## to traces. Records are built at exact columns from the spec examples
## (`docs/spec/sps.md` §5.3, `docs/spec/p1_p2_p3.md` §3.4); the extracted
## spec text collapses blanks, so its lines cannot be used verbatim.

import std/[assertions, streams, strutils, math, os, tables]
import parseSEG
import parseSEG/common/ebcdic

proc rec(first: char, fields: openArray[(int, string)]): string =
  ## An 80-column record with `fields` placed at their 1-based columns.
  result = repeat(' ', 80)
  result[0] = first
  for (c, t) in fields: result.putCol(c, t)

proc r21(kind: char, line, point: string, index: char, code: string, e, n, z: string,
    daytime = " 18213250"): string =
  rec(kind, [(2, line.rjust(10)), (12, point.rjust(10)), (24, $index & code), (47, e.rjust(9)),
    (56, n.rjust(10)), (66, z.rjust(6)), (72, daytime)])

proc x21(tape: string, record: int, srcLine, srcPoint: string, srcIndex: char,
    fromCh, toCh: int, inc: char, rcvLine, fromR, toR: string, rcvIndex: char): string =
  rec('X', [(2, tape), (8, align($record, 8)), (16, "1"), (17, "1"), (18, srcLine.rjust(10)),
    (28, srcPoint.rjust(10)), (38, $srcIndex), (39, align($fromCh, 5)), (44, align($toCh, 5)),
    (49, $inc), (50, rcvLine.rjust(10)), (60, fromR.rjust(10)), (70, toR.rjust(10)),
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
  var v: float64
  doAssert parseFortranFloat("  3354", 2, v) and v == 33.54
  doAssert parseFortranFloat(" 33.5", 2, v) and v == 33.5, "an explicit point wins"
  doAssert parseFortranFloat("    ", 2, v) and v.isNaN
  doAssert not parseFortranFloat("1 2", 0, v)
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
    doAssert p.kind == 'R' and p.line == 5646 and p.point == 534550 and p.index == 1
    doAssert p.code == "G1" and p.easting == 238570.0 and p.northing == 3058380.0
    doAssert p.elevation == 83.2 and p.dayOfYear == 18 and p.hour == 21 and p.second == 50
    doAssert p.staticCorrection.isNaN and p.waterDepth.isNaN, "blank is missing, not 0"
    let r = f.relations[0]
    doAssert r.fieldTape == "B79480" and r.fieldRecord == 1 and r.srcIndex == 2
    doAssert r.fromChannel == 1 and r.toChannel == 320 and r.fromReceiver == 534550
    doAssert r.toReceiver == 550500 and r.rcvLine == 5646
    let (back, log) = spsText(f)
    doAssert log.len == 0 and back == text, "unedited records are written byte for byte"

block sps_edit_reencodes:
  var f = parseSps([H00, rcv1].join("\n") & "\n")
  f.points[0].easting = 1.5
  f.points[0].staticCorrection = -12
  let line = spsText(f)[0].splitLines[1]
  doAssert line.len == 80
  doAssert line.col(47, 55) == "      1.5" and line.col(27, 30) == " -12"
  doAssert line.col(1, 26) == rcv1.col(1, 26)

block sps_revision_from_columns:
  let f = parseSps([rcv1, x1].join("\n"))
  doAssert f.revision == sps21 and not f.revisionDeclared
  doAssert f.log.count(sevInfo) == 1
  # A 1.0 record: 16-column line name, point right-adjusted in 18-25.
  let r10 = rec('R', [(2, "91LW1124"), (18, "225".rjust(8)), (26, "1G1"),
    (47, "238570.0".rjust(9)), (56, "3058380.0".rjust(10)), (66, "106.8".rjust(6)),
    (72, "113071245")])
  let g = parseSps(r10 & "\n")
  doAssert g.revision == sps10
  doAssert g.points[0].lineName == "91LW1124" and g.points[0].line.isNaN
  doAssert g.points[0].point == 225 and g.points[0].index == 1 and g.points[0].code == "G1"
  doAssert g.points[0].elevation == 106.8 and g.points[0].dayOfYear == 113
  let (same, _) = spsText(g)
  doAssert same == r10 & "\n"

block sps_convert_revisions:
  let f = parseSps([H00, rcv1, src1, x1].join("\n") & "\n")
  let (t10, l10) = spsText(f, SpsWriteOptions(revision: sps10))
  doAssert l10.count(sevError) == 0
  let g = parseSps(t10)
  doAssert g.revision == sps10 and g.revisionDeclared
  doAssert g.points[0].line == 5646 and g.points[0].point == 534550
  doAssert g.relations[0].toReceiver == 550500 and g.relations[0].toChannel == 320
  let (t21, _) = spsText(g, SpsWriteOptions(revision: sps21))
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
  doAssert spsText(f)[0].splitLines[2] == "Q what", "unknown lines are kept"

block sps_strict_implied_decimals:
  let line = rec('S', [(2, "5646".rjust(10)), (12, "534550".rjust(10)), (24, "1V6")])
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
  doAssert p1Text(f, P1WriteOptions(padHeaders: false))[0] == text
  doAssert p1Text(f)[0] == text, "headers are not padded by default"
  let padded = p1Text(f, P1WriteOptions(padHeaders: true))[0].splitLines
  doAssert padded.len == 20 + 2 + 1 and padded[20] == p1a, "header padded to a block of 20"
  var g = f
  g.files[0].records[0].easting = 155591
  g.files[0].records[0].latitude = 17 + 59 / 60 + 59.999 / 3600 # rounds to 18 00 00.00
  let line = p1Text(g, P1WriteOptions(padHeaders: false))[0].splitLines[1]
  doAssert line.col(46, 53) == "  155591" and line.col(27, 35) == "18000000N"
  doAssert line.col(1, 26) == p1a.col(1, 26) and line.col(36, 80) == p1a.col(36, 45) &
    "  155591" & p1a.col(54, 80)

block p1_grads_and_logical_files:
  let grads = rec(' ', [(2, "L1"), (18, "10".rjust(8)), (27, "01989999N"), (36, "019999999W")])
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
  doAssert p1Text(f, P1WriteOptions(padHeaders: false))[0] ==
    (@["H P4 FILE"] & p4).join("\n") & "\n"

# ----------------------------------------------------------------- join ---

block join_relations:
  let f = parseSps([H00, rcv1, rcv2, src1, x1].join("\n"))
  var g: SurveyGeometry
  g.addSps(f)
  doAssert g.relationCount == 1 and g.table.receivers.len == 2 and g.table.sources.len == 1
  var rel: StationRelation
  doAssert g.relation(1, 2, rel)
  doAssert rel.receiver.point == 534600, "receivers are interpolated: step 50"
  doAssert rel.source.line == 5713 and rel.source.point == 542525 and rel.source.index == 2
  doAssert g.relation(1, 320, rel) and rel.receiver.point == 550500
  doAssert not g.relation(1, 321, rel) and not g.relation(2, 1, rel)
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
  var rel: StationRelation
  doAssert g.relation(7, 4, rel) and rel.receiver.point == 534575 and rel.component == 0
  doAssert not g.relation(7, 2, rel), "without multiComponent only every 3rd channel"
  g.multiComponent = true
  doAssert g.relation(7, 2, rel) and rel.receiver.point == 534600 and rel.component == 2
  doAssert g.relation(7, 9, rel) and rel.receiver.point == 534550 and rel.component == 3

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
  let r10 = rec('R', [(2, "91LW1124"), (18, "225".rjust(8)), (26, "1G1"),
    (47, "238570.0".rjust(9)), (56, "3058380.0".rjust(10))])
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
  # 63.sgd (SEG-D 2.0): file 63, one trace (channel 1), stations in THE#1.
  let dir = getTempDir() / "tsurvey2"
  createDir(dir)
  let x = x21("T1", 63, "20.00", "205.00", '1', 1, 1, '1', "10.00", "101.00", "101.00", '1')
  let r = r21('R', "10.00", "101.00", '1', "G1", "500100.0", "6000000.0", "12.5")
  let s = r21('S', "20.00", "205.00", '1', "V6", "500000.0", "6000400.0", "10.0", " 19001150")
  writeFile(dir / "t.sps", [H00, r, s, x].join("\n"))
  var f = openSeismic("SEG Spec/exampleFiles/63.sgd", keys = true)
  doAssert f.index.keys[0].record == 63 and f.index.keys[0].channel == 1
  var g: SurveyGeometry
  g.addSps(readSps(dir / "t.sps"))
  doAssert f.index.applySurvey(g) == 0, "the headers' own stations are kept"
  doAssert f.index.applySurvey(g, overwrite = true) == 1
  let k = f.index.keys[0]
  doAssert k.srcPoint == 205 and k.rcvPoint == 101 and k.rcvX == 500100
  doAssert abs(k.offset - hypot(100.0, 400.0)) < 1e-9
  f.close()
  removeDir(dir)

# --------------------------------------------------------- review (10.4) ---

block review_p1_non_p1_lines_stay_raw:
  let text = ["HAREA", p1a, " BAD RECORD here", p1b].join("\n") & "\n"
  let f = parseP1(text)
  doAssert f.files[0].records[1].raw == " BAD RECORD here"
  doAssert f.files[0].records[1].latitude.isNaN
  doAssert p1Text(f)[0] == text

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
  doAssert spsText(cr, SpsWriteOptions(lineEnding: "\r"))[0] == [H00, rcv1, rcv2].join("\r")
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
  doAssert p1Text(f)[0].splitLines[1].col(18, 25) == "   99999"

block review_round_trips:
  # Decimals used to read are used to write.
  let text = ["H X", p1a].join("\n") & "\n"
  let f = parseP1(text, opts = P1Options(gridDecimals: 2))
  doAssert f.files[0].records[0].easting == 1555.90
  doAssert p1Text(f)[0] == text
  var g = f
  g.files[0].records[0].easting = 1555.91
  doAssert p1Text(g)[0].splitLines[1].col(46, 53) == "  155591"
  # SPS strict mode round-trips.
  let line = rec('S', [(2, "5646".rjust(10)), (12, "534550".rjust(10)), (24, "1V6"),
    (47, "2385700".rjust(9)), (56, "30583800".rjust(10))])
  let st = parseSps(line & "\n", opts = SpsOptions(revision: sps21, strictImpliedDecimals: true))
  doAssert st.points[0].easting == 238570.0
  doAssert spsText(st)[0] == line & "\n"
  # No final newline stays so; an H record without a code is written back.
  let nofinal = [H00, "H", rcv1].join("\n")
  doAssert spsText(parseSps(nofinal))[0] == nofinal

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
