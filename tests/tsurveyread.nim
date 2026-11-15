## Survey files read by a viewer (18.4): `readSps` and `readP1` with a
## `Progress` that can cancel; `looksLikeSps` on a head of header records
## only; the line counter of an over-long line; a bound on a file that turns
## into junk (`SpsOptions.maxJunkBytes`) and passing by binary lines
## (`SpsOptions.skipBinary`); hostile inputs. Records are built at exact
## columns, as in `tsurvey`. Seen failing: with the hook not called
## (`progress_*`), with the H00 rule taken out of `looksLikeSps`, with
## `lineSpans` counting the pieces of a cut line, without the junk stop and
## without the binary test.

import std/[assertions, math, os, streams, strutils]
import parseSEG
import parseSEG/survey/cards # column helpers (internal)
import ./utils/testutils

proc rec(first: char, fields: openArray[(int, string)]): string =
  ## An 80-column record with `fields` placed at their 1-based columns.
  result = repeat(' ', 80)
  result[0] = first
  for (c, t) in fields: result.putCol(c, t)

proc point(kind: char, line, point: int, e, n: float): string =
  rec(kind, [(2, align($line & ".00", 10)), (12, align($point & ".00", 10)), (24, "1G1"),
    (47, align(formatFloat(e, ffDecimal, 1), 9)), (56, align(formatFloat(n, ffDecimal, 1), 10)),
    (66, align("83.2", 6)), (72, " 18213250")])

const
  H00 = "H00 SPS format version number   SPS 2.1;"
  H00v1 = "H00 SPS format version number   SPS001,12.10.90;"
  p1a = " CLT4960            12340B17543354N110445881E  155590  161670  85779197065028   "

let tmp = scratchDir("parseseg_tsurveyread")
createDir(tmp)

proc spsFile(points: int): string =
  ## An SPS 2.1 receiver file of `points` records, about 82 bytes each.
  var lines = @[H00, "H01 Description of survey area  test"]
  for i in 0 ..< points: lines.add point('R', 100, 1000 + i, 500000.0 + float(i), 6000000.0)
  lines.join("\r\n") & "\r\n"

proc progress_and_cancel_sps() =
  # A proc, not a block: the hooks are closures over its locals.
  let path = tmp / "big.r"
  writeFile(path, spsFile(40_000)) # 3.3 MB: the hook runs about every MiB
  let size = getFileSize(path)
  var calls: seq[(int64, int64)]
  let hook: Progress = proc (done, total: int64): bool =
    calls.add (done, total)
    true
  let f = readSps(path, progress = hook)
  doAssert f.points.len == 40_000 and not f.log.isFatal
  doAssert calls.len >= 3 and calls[^1] == (size, size), $calls
  for i in 1 ..< calls.len: doAssert calls[i][0] >= calls[i - 1][0] and calls[i][1] == size
  # Cancelled at the second call: the records read before it stay, a fatal says so.
  var n = 0
  let stop: Progress = proc (done, total: int64): bool =
    inc n
    n < 2
  let g = readSps(path, progress = stop)
  doAssert g.log.isFatal and g.log.has("cancelled", sevFatal), $g.log
  doAssert g.points.len > 0 and g.points.len < 40_000 and n == 2
  # A stream: the size is unknown (-1) unless the caller knows it.
  var totals: seq[int64]
  let s = readSps(newStringStream(spsFile(20_000)), "s.r", progress =
    proc (done, total: int64): bool =
      totals.add total
      true)
  doAssert s.points.len == 20_000 and totals.len >= 2 and totals[0] == -1

progress_and_cancel_sps()

proc progress_and_cancel_p1() =
  # A proc, not a block: the hooks are closures over its locals.
  var lines = @["H0100SURVEY AREA         test"]
  for i in 0 ..< 40_000: lines.add p1a
  let path = tmp / "big.p1"
  writeFile(path, lines.join("\n") & "\n")
  let size = getFileSize(path)
  var last = (0'i64, 0'i64)
  var calls = 0
  let hook: Progress = proc (done, total: int64): bool =
    inc calls
    last = (done, total)
    true
  let f = readP1(path, progress = hook)
  doAssert f.files.len == 1 and f.files[0].records.len == 40_000
  doAssert calls >= 3 and last == (size, size)
  let g = readP1(path, progress = proc (done, total: int64): bool = false)
  doAssert g.log.isFatal and g.log.has("cancelled", sevFatal)
  doAssert g.files.len == 0 or g.files[0].records.len < 40_000

progress_and_cancel_p1()

block looks_like_sps_from_headers_only:
  # A file list sniffs a head: SPS headers often fill more than 4 KiB, so
  # the head may hold header records only. An H00 that names SPS decides.
  var head = @[H00]
  for i in 1 .. 60: head.add "H26 " & repeat('x', 70)
  doAssert looksLikeSps(newStringStream(head.join("\n")))
  doAssert looksLikeSps(newStringStream(H00v1 & "\n" & "H01 area"))

  doAssert not looksLikeSps(newStringStream("H00 SPS format version number   unknown\nH01 x"))
  doAssert not looksLikeSps(newStringStream("H01 Description\nH02 x\nH26 y"))
  doAssert not looksLikeSps(newStringStream("H0100SURVEY AREA         test\nH0200x"))
  doAssert not looksLikeSps(newStringStream(""))
  # Data records still decide over the H00: P1 data under an SPS H00 is P1.
  doAssert not looksLikeSps(newStringStream([H00, p1a, p1a].join("\n")))

block over_long_lines_are_one_line:
  # A line of 3 x 64 KiB + 10 bytes is cut into 4 records, all of line 1;
  # the line after it is line 2, in the records and in diagnostics.
  let long = 'R' & repeat('7', 3 * MaxLineBytes + 9)
  let text = [H00, long, point('R', 1, 2, 3.0, 4.0)].join("\n") & "\n"
  var indices: seq[int]
  for r in textRecords(newStringStream(text), tlLines): indices.add r.index
  doAssert indices == @[0, 1, 1, 1, 1, 2], $indices
  let f = parseSps(text)
  # The first piece reads as an R record, the others as unknown records; all warned about.
  doAssert f.points.len == 2 and f.others.len == 3, $f.points.len & " " & $f.others.len
  for d in f.log:
    if d.loc.record >= 0: doAssert d.loc.record in [1, 2], $d
  doAssert f.log.has("cut into records", sevWarning)
  # A stream with no line end at all: pieces, each of line 0.
  var n = 0
  for r in textRecords(newStringStream(repeat('a', 5 * MaxLineBytes)), tlLines):
    doAssert r.index == 0
    inc n
  doAssert n == 5

block junk_is_bounded:
  # Records, then 8 MiB of lines that are no SPS records, then records: with
  # a bound of 1 MiB the read stops in the junk and says from where; `others`
  # holds about the bound. Without one, everything is read (and kept).
  var lines = @[H00, point('S', 1, 1, 1.0, 2.0)]
  let junkFrom = lines.join("\n").len + 1
  for i in 0 ..< 100_000: lines.add "#junk line " & $i & repeat('-', 70)
  lines.add point('S', 1, 2, 1.0, 2.0)
  let text = lines.join("\n") & "\n"
  let bounded = parseSps(text, "j.s", SpsOptions(maxJunkBytes: 1 shl 20))
  doAssert bounded.points.len == 1
  var kept = 0
  for o in bounded.others: kept += o.len
  doAssert kept <= (1 shl 20) + 1000, $kept
  doAssert bounded.log.has("turns into other data", sevError), $bounded.log
  var said = false
  for d in bounded.log:
    if "turns into other data" in d.msg:
      said = d.offset == int64(junkFrom)
  doAssert said
  let all = parseSps(text, "j.s")
  doAssert all.points.len == 2 and all.others.len == 100_000
  # Blank lines neither end a run of junk nor count in it; a record ends it.
  var mixed = @[H00]
  for i in 0 ..< 3:
    for k in 0 ..< 6000: mixed.add "?" & repeat('j', 99)
    mixed.add ""
    mixed.add point('R', 1, i, 1.0, 2.0)
  let m = parseSps(mixed.join("\n"), "m.r", SpsOptions(maxJunkBytes: 1 shl 20))
  doAssert m.points.len == 3 and not m.log.has("turns into other data", sevError)

block binary_lines_passed_by:
  # Lines with bytes no text holds: with `skipBinary` they are not read as
  # records, one warning counts them, and a run of them is junk.
  var bin = newString(200)
  for i in 0 ..< bin.len: bin[i] = char((i * 37 + 11) mod 256)
  bin = bin.replace("\n", "x").replace("\r", "y")
  let text = [H00, point('R', 1, 1, 1.0, 2.0), "R" & bin, "S\0\0\0", point('R', 1, 2, 1.0, 2.0)].join("\n")
  let plain = parseSps(text)
  doAssert plain.points.len == 4 # read as (bad) records, as before
  let skipped = parseSps(text, opts = SpsOptions(skipBinary: true))
  doAssert skipped.points.len == 2 and skipped.others.len == 2
  doAssert skipped.others[0] == "" and skipped.others[1] == ""
  doAssert skipped.log.has("2 lines hold binary data", sevWarning), $skipped.log
  doAssert skipped.log.count(sevWarning) == 1, $skipped.log
  # 20 MiB of binary bytes (some of them line ends): read up to the bound
  # only, nothing of them kept.
  var blob = newString(20 shl 20)
  for i in 0 ..< blob.len: blob[i] = char((i * 131 + 7) mod 251)
  let b = parseSps(H00 & "\n" & blob, "b.r", SpsOptions(skipBinary: true,
    maxJunkBytes: 2 shl 20))
  var keptBytes = 0
  for o in b.others: keptBytes += o.len
  doAssert b.points.len == 0 and keptBytes == 0 and b.log.has("turns into other data", sevError)
  var lines = 0
  for c in blob: (if c in {'\n', '\r'}: inc lines)
  doAssert b.order.len < lines div 8, $b.order.len & " of " & $lines # stopped after 2 of 20 MiB
  # The same bytes without line ends at all: 64 KiB pieces, the same stop.
  let noEnds = blob.replace("\n", "x").replace("\r", "y")
  let c = parseSps(H00 & "\n" & noEnds, "c.r", SpsOptions(skipBinary: true,
    maxJunkBytes: 2 shl 20))
  doAssert c.order.len <= 40 and c.log.has("turns into other data", sevError), $c.order.len

block hostile_inputs:
  for text in ["", "\n", "\r", "\r\n\r\n", "\0\0\0\0", repeat('\r', 100_000), "H00",
      repeat("R\n", 10_000), repeat('\xFF', 70_000), "EOF"]:
    let f = parseSps(text, "h.s", SpsOptions(skipBinary: true, maxJunkBytes: 4096))
    doAssert not f.log.isFatal, $f.log
    discard looksLikeSps(newStringStream(text))
    let p = parseP1(text, "h.p1")
    doAssert not p.log.isFatal

echo "tsurveyread: ok"
