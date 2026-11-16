## Survey files at the scale of a real 3D survey (tens of millions of X
## records): the card fields read without `parseFloat` give exactly its
## values; `SpsOptions.keepNames = false` reads the same values with the
## names of numeric fields left out; the relations are kept in one list (56
## bytes a run and the list's room to grow; a record given again later is
## moved to the end, the list compacted) and every lookup gives what a
## geometry of the records in order gives; a join with the stations of one
## geometry and the relations of another is the join with both in one.
##
## Records in line order (a record's X rows among other records') cost
## amortised O(log n) a row: the run store's work is counted, against its bound.
## Records read without their names are written back byte for byte.
##
## Seen failing: with `plainDecimal` dividing by ten once per fraction digit
## (not by the power once), `card_numbers_are_parse_float_s` found values a
## bit off `parseFloat`'s; with a record moved to the end but its runs still
## looked for where they were (`first` not updated), `records_given_again_later`
## found other receivers. The old storage (a list per record, a tape string
## per run) took 154 bytes a run of records like those of `runs_take_little_memory`.
## Before records moved with room to grow, `records_in_line_order_cost_n_log_n`
## counted 26.7 million runs copied for 8 000 added (two records alternating),
## 44 million for one record given again after each new one;
## `names_left_out_written_back` found 102.5 written as 102.50 (the names
## compared with those of a read with names); `skipped_point_names_its_line`
## found "on line  is"; the index and file `applySurvey` of two geometries
## without `stats` did not compile.

import std/[algorithm, assertions, importutils, math, options, os, parseutils, random, strutils,
  tables]
import parseSEG
import ../tools/demofiles
import parseSEG/survey/cards # column helpers (internal)
from parseSEG/survey/join {.all.} as joinInternals import nil # the run store, to count its work

block card_numbers_are_parse_float_s:
  # Random fields of digits, points, signs and stray characters: the fast
  # path and `parseFloat` / `parseBiggestInt` agree on every one.
  var r = initRand(2026)
  const chars = "0123456789012345678901234567890123456789.+-e_ "
  for trial in 0 ..< 200_000:
    var s = newString(r.rand(1 .. 22))
    for c in s.mitems: c = chars[r.rand(chars.high)]
    let f = s.trimmed(1, s.len)
    for decimals in 0 .. 2:
      var fast: float64
      let ok = fortranFloat(s, f, decimals, fast)
      var slow: float64
      var want = true
      if f.a > f.b: slow = NaN
      elif parseFloat(s.toOpenArray(f.a, f.b), slow) != f.b - f.a + 1 or
          slow.classify in {fcNan, fcInf, fcNegInf}: want = false
      elif decimals > 0 and not s.toOpenArray(f.a, f.b).contains('.') and
          not s.toOpenArray(f.a, f.b).contains('e'):
        slow = slow / pow(10.0, float64(decimals))
      doAssert ok == want, "'" & s & "'"
      if ok:
        doAssert (fast.isNaN and slow.isNaN) or (fast == slow and
          signbit(fast) == signbit(slow)), "'" & s & "': " & $fast & " " & $slow
    var n: int64
    var m: BiggestInt
    var intOk = true
    if f.a <= f.b:
      try: intOk = parseBiggestInt(s.toOpenArray(f.a, f.b), m) == f.b - f.a + 1
      except ValueError: intOk = false
    doAssert fortranInt(s, f, n) == intOk, "'" & s & "'"
    if intOk and f.a <= f.b: doAssert n == m, "'" & s & "'"

proc xCard(rec, fromCh, toCh: int; srcLine, srcPoint, rcvLine, first, last: string): string =
  ## An SPS 2.1 X record.
  result = repeat(' ', 80)
  result[0] = 'X'
  result.putCol(8, align($rec, 8))
  result.putCol(16, "11")
  result.putCol(18, align(srcLine, 10))
  result.putCol(28, align(srcPoint, 10))
  result.putCol(38, "1")
  result.putCol(39, align($fromCh, 5))
  result.putCol(44, align($toCh, 5))
  result.putCol(49, "1")
  result.putCol(50, align(rcvLine, 10))
  result.putCol(60, align(first, 10))
  result.putCol(70, align(last, 10))
  result.putCol(80, "1")

const H00 = "H00 SPS format version number   SPS 2.1;"

block names_left_out:
  var text = H00 & "\n"
  text.add "R      1001     102.5  1G1                    600100.0 6100000.0  83.2\n"
  text.add "S      2001      1001  1E1                    600000.0 6100000.0  80.0\n"
  text.add xCard(7, 1, 10, "2001", "1001", "1001", "101", "110") & "\n"
  text.add xCard(8, 1, 10, "LN2001", "1002", "1001", "101", "110") & "\n"
  let all = parseSps(text)
  let lean = parseSps(text, opts = SpsOptions(keepNames: false))
  doAssert lean.log.len == all.log.len, $lean.log
  doAssert lean.points.len == 2 and lean.relations.len == 2
  for i in 0 ..< 2:
    let (a, b) = (all.points[i], lean.points[i])
    doAssert a.line == b.line and a.point == b.point and a.easting == b.easting
    doAssert b.lineName == "" and b.pointName == "" and a.lineName.len > 0
  doAssert lean.relations[0].srcLineName == "" and lean.relations[0].fromReceiverName == ""
  # Rev 2.1 reads a text line as no number: its text is kept, for a line name map.
  doAssert lean.relations[1].srcLine.isNaN and lean.relations[1].srcLineName == "LN2001"
  var g = initSurveyGeometry()
  g.mapLine("LN2001", 2001)
  g.addSps(lean)
  doAssert g.relationCount == 2 and g.recordCount == 2 and g.sourceCount == 1

block names_left_out_written_back:
  # Records read without their names are unedited records still: written
  # back byte for byte (they were encoded from their values: 102.5 became
  # 102.50), in 2.1 and in 1.0 (whose names keep leading zeros). An edited
  # one is encoded.
  var text = H00 & "\n"
  text.add "R      1001     102.5  1G1                    600100.0 6100000.0  83.2\n"
  text.add "R      1001       ABC  1G1                    600100.0 6100000.0  83.2\n"
  text.add "S      2001      1001  1E1                    600000.0 6100000.0  80.0\n"
  text.add xCard(7, 1, 10, "2001", "1001", "1001", "101", "110") & "\n"
  text.add xCard(8, 1, 10, "LN2001", "1002", "1001", "101.5", "110") & "\n"
  var lean = parseSps(text, opts = SpsOptions(keepNames: false))
  doAssert lean.points[0].lineName == "" and lean.relations[0].fromReceiverName == ""
  doAssert spsText(lean).text == text
  lean.points[0].point = 103
  lean.relations[0].fromReceiver = 102
  let edited = spsText(lean).text.splitLines
  doAssert edited[1][0 ..< 21] == "R   1001.00    103.00", edited[1]
  doAssert edited[4][59 ..< 69] == "    102.00" and edited[5] == text.splitLines[5]
  let t10 = "H00 SPS format version number   SPS 1.0;\n" &
    "R" & alignLeft("0225", 16) & align("0101", 8) & "  1G1" & spaces(20) &
    "600100.0 6100000.0  83.2\n"
  let l10 = parseSps(t10, opts = SpsOptions(keepNames: false))
  doAssert l10.points[0].lineName == "" and l10.points[0].line == 225
  doAssert spsText(l10).text == t10

block skipped_point_names_its_line:
  # `addSps(path)` reads without names: the note of a point that is not a
  # number names its line by number ("on line  is" before).
  let path = getTempDir() / "tsurveyscale_points.r"
  writeFile(path, H00 & "\n" &
    "R      1001       ABC  1G1                    600100.0 6100000.0  83.2\n")
  var g = initSurveyGeometry()
  g.addSps(path)
  removeFile(path)
  var found = false
  for d in g.log:
    if "point 'ABC'" in d.msg:
      found = true
      doAssert "point 'ABC' on line 1001 is not a number" in d.msg, d.msg
  doAssert found, $g.log

block records_given_again_later:
  # The X records of three field records interleaved, again and again (each
  # record's runs move to the end of the list, which is compacted now and
  # then): every lookup agrees with the same records given in order.
  var text, sorted = H00 & "\n"
  var byRecord: array[3, seq[string]]
  for k in 0 ..< 40:
    for rec in 0 ..< 3:
      let card = xCard(10 + rec, 1 + 5 * k, 5 + 5 * k, $(2000 + rec), "1001", $(1000 + k),
        "101", "105")
      text.add card & "\n"
      byRecord[rec].add card
  for rec in 0 ..< 3:
    for card in byRecord[rec]: sorted.add card & "\n"
  var a, b = initSurveyGeometry()
  a.addSps(parseSps(text))
  b.addSps(parseSps(sorted))
  doAssert a.relationCount == 120 and a.recordCount == 3
  for rec in 10'i64 .. 12:
    doAssert a.relationsDisjoint(rec) and a.expectedChannels(rec) == 200
    for c in 0'i64 .. 205:
      doAssert a.relation(rec, c) == b.relation(rec, c), $rec & " " & $c
    var ra, rb: seq[RelationRun]
    for run in a.relationRuns(rec): ra.add run
    for run in b.relationRuns(rec): rb.add run
    doAssert ra == rb
    doAssert a.recordsAt(stationKey(float64(2000 + rec - 10), 1001, 1)) == @[rec]
    doAssert a.channelOf(rec, stationKey(1039, 103, 1)) == some(198'i64)
  var sa, sb: seq[int64]
  for r in a.records: sa.add r
  for r in b.records: sb.add r
  doAssert sa == sb and sa == @[10'i64, 11, 12]
  doAssert a.receiverRelations() == b.receiverRelations()

proc spsWork(order: openArray[int64]): tuple[work: int, g: SurveyGeometry] =
  ## Adds one X record of each field record in `order` (the j-th of a record
  ## on channels 10 j + 1 .. 10 j + 10), one at a time, and counts the run
  ## store's work: the runs a record's move copies, and for a compaction the
  ## runs held plus r log2 r for sorting its r records.
  privateAccess(SurveyGeometry)
  privateAccess(joinInternals.RunStore)
  privateAccess(joinInternals.RecordRuns)
  var g = initSurveyGeometry()
  var given: Table[int64, int]
  for rec in order:
    let j = given.getOrDefault(rec)
    given[rec] = j + 1
    var f = SpsFile()
    var x = initSpsRelation()
    (x.fieldRecord, x.fromChannel, x.toChannel, x.channelIncrement) =
      (rec, int64(1 + 10 * j), int64(10 * (j + 1)), 1)
    (x.srcLine, x.srcPoint, x.srcIndex) = (float64(5000 + rec div 100), float64(rec mod 100), 1)
    (x.rcvLine, x.fromReceiver, x.toReceiver, x.rcvIndex) = (float64(1000 + j), 1.0, 10.0, 1)
    f.relations.add x
    template s: untyped = g.runs[rdSource]
    let known = rec in s.records
    let (first, count) = if known: (s.records[rec].first, s.records[rec].count) else: (0, 0)
    let gaps = s.gaps
    g.addSps(f)
    # (only a compaction lowers the gaps, after a move of the record added to)
    let compacted = s.gaps < gaps
    if known and (compacted or s.records[rec].first != first): result.work += count
    if compacted:
      let r = s.records.len
      result.work += s.held + r * int(ceil(log2(float64(r + 1))))
  doAssert g.relationCount == order.len
  result.g = g

block records_in_line_order_cost_n_log_n:
  # Files sorted by line, not by record, give a record's X rows among other
  # records' (an O file written source line first does too). The run store's
  # work over n runs added is at most 2 n (moves) + 2 n (1 + log2 n)
  # (compactions), whatever the order (see `RunStore`); records moved and
  # compacted as rows came were O(n^2): two records alternating, 4 000 rows
  # each, copied 16 million runs.
  var shapes: seq[(string, seq[int64])]
  var two, lines, one, rnd: seq[int64]
  for j in 0 ..< 4000:
    for rec in 0'i64 .. 1: two.add rec
  for j in 0 ..< 40:
    for rec in 0'i64 ..< 200: lines.add rec
  for k in 1'i64 .. 4000: one.add [0'i64, k] # one record given again after each new one
  var r = initRand(2026)
  for k in 0 ..< 8000: rnd.add int64(r.rand(49))
  shapes = @[("two records alternating", two), ("200 records, line order", lines),
    ("one record among new ones", one), ("50 records at random", rnd)]
  for (name, order) in shapes:
    let n = order.len
    let (work, g) = spsWork(order)
    let bound = 2 * n + 2 * n * (1 + int(ceil(log2(float64(n)))))
    doAssert work <= bound, name & ": " & $work & " for " & $n & " runs (bound " & $bound & ")"
    echo "  ", name, ": ", formatFloat(work / n, ffDecimal, 1), " runs copied a run added"
    # And every record's runs are as in a geometry of the records in order.
    var sorted = order
    sorted.sort
    let (_, h) = spsWork(sorted)
    for rec in g.records:
      var ra, rb: seq[RelationRun]
      for run in g.relationRuns(rec): ra.add run
      for run in h.relationRuns(rec): rb.add run
      doAssert ra.len > 0 and ra == rb, name & ": record " & $rec

block runs_take_little_memory:
  # 100 000 X records of 10 000 field records: 56 bytes each and the room
  # the lists have to grow, where a list per record and a tape string per
  # run took 154.
  var f = SpsFile()
  for rec in 0 ..< 10_000:
    for j in 0 ..< 10:
      var x = initSpsRelation()
      (x.fieldRecord, x.fromChannel, x.toChannel, x.channelIncrement) =
        (int64(rec), int64(1 + 160 * j), int64(160 * (j + 1)), 1)
      (x.srcLine, x.srcPoint, x.srcIndex) = (float64(5000 + rec div 100), float64(rec mod 100), 1)
      (x.rcvLine, x.fromReceiver, x.toReceiver, x.rcvIndex) = (float64(1000 + j), 1.0, 160.0, 1)
      f.relations.add x
  let before = getOccupiedMem()
  var g = initSurveyGeometry()
  g.addSps(f)
  let perRun = (getOccupiedMem() - before) div g.relationCount
  doAssert g.relationCount == 100_000 and g.recordCount == 10_000
  doAssert perRun <= 90, $perRun & " bytes a run"
  echo "  ", perRun, " bytes a run"

block stations_and_relations_apart:
  # The join with the stations of one geometry and the relations of
  # another: the same keys as with one geometry that holds both.
  var text = H00 & "\n"
  for k in 0 ..< 10:
    text.add "R      1001" & align($(101 + k), 10) & "  1G1" & spaces(20) &
      align(formatFloat(600000.0 + 10 * float64(k), ffDecimal, 1), 9) &
      align("6100000.0", 10) & "  83.2\n"
  text.add "S      2001      1001  1E1" & spaces(20) & "600050.0 6100010.0  80.0\n"
  let points = parseSps(text)
  let x = parseSps(H00 & "\n" & xCard(7, 1, 10, "2001", "1001", "1001", "101", "110") & "\n")
  var both, stations, relations = initSurveyGeometry()
  both.addSps(points)
  both.addSps(x)
  stations.addSps(points)
  relations.addSps(x)
  for ch in 0 .. 11:
    var k = initTraceKeys()
    (k.record, k.channel) = (7.0, float64(ch))
    var one, two = k
    doAssert one.applySurvey(both) == two.applySurvey(stations, relations)
    doAssert sameValues(one, two), $ch
    if ch in 1 .. 10: doAssert two.rcvX == 600000.0 + 10 * float64(ch - 1) and two.srcY == 6100010.0
  # A file and an index, with and without `stats`: the demo record.sgd (file
  # 63, channel 1, source 20/99.5 and receiver 10/104 in its header).
  let dir = getTempDir() / "tsurveyscale_apart"
  createDir(dir)
  writeRecordSegd(dir / "record.sgd")
  var st = initSurveyGeometry()
  st.addSps(parseSps(H00 & "\n" &
    "R     10.00    104.00  1G1                    500100.0 6000000.0  12.5\n" &
    "S     20.00     99.50  1V6                    500000.0 6000400.0  10.0\n"))
  for withStats in [false, true]:
    var f = openSeismic(dir / "record.sgd", keys = true)
    var ix = f.index
    var stats: JoinStats
    if withStats:
      doAssert f.applySurvey(st, relations, stats) == 1 and stats.changed == 1
      doAssert ix.applySurvey(st, relations, stats) == 1 and stats.changed == 1
    else:
      doAssert f.applySurvey(st, relations) == 1
      doAssert ix.applySurvey(st, relations) == 1
    doAssert f.index.keys[0].rcvX == 500100 and ix.keys[0].srcX == 500000
    doAssert f.applySurvey(st, relations) == 0 and f.keysRevision == 1
    doAssert ix.applySurvey(st, relations) == 0 and ix.keysRevision == 1
    f.close()
  removeDir(dir)
