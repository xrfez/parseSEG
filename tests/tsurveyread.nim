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
when defined(posix):
  import std/posix
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
  # Exactly the records that start before the byte the log names: the hook
  # runs before a record is taken.
  var at = -1'i64
  for d in g.log:
    if d.code == dcCancelled: at = d.offset
  var before, off = 0'i64
  for line in spsFile(40_000).split("\r\n"):
    if line.len > 0 and line[0] == 'R' and off < at: inc before
    off += int64(line.len) + 2
  doAssert at > 0 and g.points.len == before and g.headers.len == 2,
    "cancelled at byte " & $at & ": " & $g.points.len & " points, " & $before & " start before it"
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

proc binary_lines_are_named() =
  # Each line passed by is named with its line number (the first few, as
  # every kind of problem is), and one warning counts them all.
  let text = [H00, point('R', 1, 1, 1.0, 2.0), "R\x01\x02 binary", "S\0\0\0",
    point('R', 1, 2, 1.0, 2.0)].join("\n")
  let f = parseSps(text, opts = SpsOptions(skipBinary: true))
  var named: seq[int]
  for d in f.log:
    if d.severity == sevWarning and "binary data" in d.msg and d.loc.record >= 0:
      named.add d.loc.record
  doAssert named == @[2, 3], $f.log
  doAssert f.log.has("2 lines hold binary data", sevWarning) and f.log.count(sevWarning) == 3,
    $f.log

binary_lines_are_named()

proc high_bytes_are_text() =
  # Bytes above 127 are text in some encoding (UTF-8, Latin-1, CP1251): they
  # never make a line binary, so header records written in them are kept.
  let names = ["H26 \xC3\x91and\xC3\xBA", # "Ñandú" in UTF-8: 4 of 11 bytes above 127
    "H02 Client                      \xD0\x93\xD0\xB0\xD0\xB7\xD0\xBF\xD1\x80\xD0\xBE\xD0\xBC" &
      "\xD0\xBD\xD0\xB5\xD1\x84\xD1\x82\xD1\x8C-\xD0\xA5\xD0\xB0\xD0\xBD\xD1\x82\xD0\xBE\xD1\x81",
    "H03 Area                        \xD1\xE5\xE2\xE5\xF0\xED\xFB\xE9 \xD1\xF3\xF0\xE3\xF3\xF2"]
    # Cyrillic in UTF-8; the same kind of name in CP1251 (one byte a letter)
  for n in names: doAssert not looksBinary(n), n
  let text = (@[H00] & @names & @[point('R', 1, 1, 1.0, 2.0)]).join("\n") & "\n"
  let f = parseSps(text, opts = SpsOptions(skipBinary: true, maxJunkBytes: 64))
  doAssert f.headers.len == 4 and f.points.len == 1, $f.headers.len & " " & $f.log
  doAssert not f.log.has("binary data", sevWarning) and f.log.count(sevError) == 0, $f.log
  doAssert f.headers[1].data.endsWith("\xC3\x91and\xC3\xBA"), f.headers[1].data
  # Control bytes still make a line binary; tab, form feed and CR do not.
  doAssert looksBinary("R\0") and looksBinary("R\x1A") and looksBinary("R\x7F")
  doAssert not looksBinary("R\t\f\r x")

high_bytes_are_text()

proc junk_stop_ends_progress() =
  # A read the junk bound stops still gets its final progress call.
  var lines = @[H00, point('S', 1, 1, 1.0, 2.0)]
  for i in 0 ..< 20_000: lines.add "#junk line " & $i & repeat('-', 70)
  var calls: seq[(int64, int64)]
  let f = readSps(newStringStream(lines.join("\n") & "\n"), "j.s",
    SpsOptions(maxJunkBytes: 64 shl 10), progress = proc (done, total: int64): bool =
      calls.add (done, total)
      true)
  doAssert f.log.has("turns into other data", sevError) and not f.log.isFatal, $f.log
  doAssert calls.len >= 2 and calls[^1] == (-1'i64, -1'i64), $calls

junk_stop_ends_progress()

type CountingStream = ref object of StreamObj
  ## A string stream that counts the bytes read from it.
  inner: StringStream
  read: int64

proc csReadData(s: Stream, buffer: pointer, bufLen: int): int =
  let c = CountingStream(s)
  result = c.inner.readData(buffer, bufLen)
  c.read += result

proc csSetPosition(s: Stream, pos: int) = CountingStream(s).inner.setPosition(pos)
proc csGetPosition(s: Stream): int = CountingStream(s).inner.getPosition
proc csAtEnd(s: Stream): bool = CountingStream(s).inner.atEnd

proc newCountingStream(text: string): CountingStream =
  CountingStream(inner: newStringStream(text), readDataImpl: csReadData,
    setPositionImpl: csSetPosition, getPositionImpl: csGetPosition, atEndImpl: csAtEnd)

proc revision_scan_is_bounded() =
  # Without an H00 the revision is judged from the first data records; a
  # file that has none must not be read through for them before the read
  # (and its progress, which can cancel) starts: 20 MB here.
  var lines = @["H01 Description of survey area  no H00"]
  for i in 0 ..< 250_000: lines.add "#junk line " & $i & repeat('-', 70)
  lines.add point('R', 1, 1, 1.0, 2.0)
  let s = newCountingStream(lines.join("\n") & "\n")
  var readAtFirst = -1'i64
  let f = readSps(s, "n.r", progress = proc (done, total: int64): bool =
    if readAtFirst < 0: readAtFirst = s.read
    false)
  doAssert f.log.has("cancelled", sevFatal), $f.log
  doAssert readAtFirst in 0'i64 .. 4 shl 20, "read before the first progress call: " &
    $readAtFirst & " bytes"
  # No line ends after the first line: 64 KiB pieces, few records for many
  # bytes (640 of them in 40 MiB), so the scan is bounded in bytes too.
  let t = newCountingStream("H01 Description of survey area  no H00\n" & repeat('Q', 40 shl 20))
  var tAtFirst = -1'i64
  let g = readSps(t, "q.r", progress = proc (done, total: int64): bool =
    if tAtFirst < 0: tAtFirst = t.read
    false)
  doAssert g.log.has("cancelled", sevFatal), $g.log
  doAssert tAtFirst in 0'i64 .. 8 shl 20, "read before the first progress call, no line " &
    "ends: " & $tAtFirst & " bytes"

revision_scan_is_bounded()

proc reserve_is_capped() =
  # A file of several GiB that starts with SPS records (sparse here: zeros
  # after them, which the junk bound stops at) reserves room for at most
  # 1 Mi records up front, not one per 82 bytes of its size (37 Mi records,
  # 7.5 GB of capacity, for 3 GiB).
  when defined(posix):
    let path = tmp / "sparse.r"
    writeFile(path, [H00, point('R', 1, 1, 1.0, 2.0), point('R', 1, 2, 1.0, 2.0)].join("\n") &
      "\n")
    var fh = open(path, fmReadWriteExisting)
    doAssert posix.ftruncate(fh.getOsFileHandle, 3 shl 30) == 0
    fh.close()
    let f = readSps(path, SpsOptions(keepRaw: false, skipBinary: true, maxJunkBytes: 1 shl 20))
    removeFile(path)
    doAssert f.points.len == 2 and f.log.has("turns into other data", sevError), $f.log
    doAssert f.order.capacity <= 1 shl 20 and f.points.capacity <= 1 shl 20,
      "reserved: " & $f.order.capacity & " entries, " & $f.points.capacity & " points"
  else:
    echo "tsurveyread: reserve_is_capped skipped (a sparse file needs POSIX ftruncate)"

reserve_is_capped()

proc h00_revision_columns() =
  # The revision is read from an H00's data, columns 33 on (as `data` holds
  # it), by `readSps` and `looksLikeSps` alike.
  let far = "H00 SPS format version number" & repeat(' ', 60) & "SPS001,12.10.90;"
  let f = parseSps(far & "\n" & "H26 x\n")
  doAssert f.revisionDeclared and f.revision == sps10, $f.revision & " " & $f.log
  doAssert looksLikeSps(newStringStream(far & "\nH26 x"))

h00_revision_columns()

echo "tsurveyread: ok"
