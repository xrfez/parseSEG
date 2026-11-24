## Leap-second table as a .nif file a caller can replace (PLEAP1).
##
## Seen to fail first: validation accepted a step of +2 and a first entry
## after 1980-01-06 (problems stayed empty). Converters ignored
## `useLeapTable`, so an instant after the added date stayed at offset 18.
## `leapKnownAt` was missing, so the checked-to cases did not compile.
## Truncating division made `leapKnownAt(-1)` false on 1969-12-31.

import std/[assertions, atomics, options, os, strutils, typedthreads]

import parseSEG
import parseSEG/common/years

const oldDays = [
  (1972, 6, 30), (1972, 12, 31), (1973, 12, 31), (1974, 12, 31), (1975, 12, 31),
  (1976, 12, 31), (1977, 12, 31), (1978, 12, 31), (1979, 12, 31), (1981, 6, 30),
  (1982, 6, 30), (1983, 6, 30), (1985, 6, 30), (1987, 12, 31), (1989, 12, 31),
  (1990, 12, 31), (1992, 6, 30), (1993, 6, 30), (1994, 6, 30), (1995, 12, 31),
  (1997, 6, 30), (1998, 12, 31), (2005, 12, 31), (2008, 12, 31), (2012, 6, 30),
  (2015, 6, 30), (2016, 12, 31)]

proc startOf(y, m, d: int): tuple[y, m, d: int] =
  if (m, d) == (6, 30): (y, 7, 1) else: (y + 1, 1, 1)

proc nif(entries: openArray[(int, int, int, int)],
    checked = (2016, 12, 31)): string =
  result = "(leapSeconds (version 1) (checkedTo " & $checked[0] & " " &
    $checked[1] & " " & $checked[2] & ")"
  for (y, m, d, off) in entries:
    result.add " (leap (date " & $y & " " & $m & " " & $d &
      ") (gpsMinusUtc " & $off & "))"
  result.add ")"

proc mentions(problems: seq[string], needle: string): bool =
  for p in problems:
    if p.find(needle) >= 0: return true

const MaxProbe = (1 shl 20) + 1

var sawLong, sawShort, readerStarted: Atomic[int]
var readerStop: Atomic[bool]

proc reader() {.thread.} =
  readerStarted.store(1, moRelease)
  while not readerStop.load(moAcquire):
    let t = currentLeapTable()
    if t.entries.len == 28 and t.entries[^1].gpsMinusUtc == 18:
      sawShort.store(1, moRelease)
    elif t.entries.len == 29 and t.entries[^1].gpsMinusUtc == 19 and
        t.entries[^1].year == 2018:
      sawLong.store(1, moRelease)
    else:
      doAssert false, "torn leap table: " & $t.entries.len
    doAssert t.checkedTo == LeapDate(year: 2016, month: 12, day: 31)

proc main*() =
  defer: useLeapTable(defaultLeapTable())
  doAssert not declared(leapOffsetAt)

  block default_equals_the_old_table:
    let root = currentSourcePath().parentDir.parentDir
    let fromFile = parseLeapTable(readFile(root / "data" / "leapseconds.nif"))
    doAssert fromFile.problems.len == 0, $fromFile.problems
    let t = defaultLeapTable()
    doAssert t == fromFile.table
    doAssert t.checkedTo == LeapDate(year: 2016, month: 12, day: 31)
    doAssert t.entries.len == oldDays.len + 1
    doAssert t.entries[0] == LeapSecond(year: 1972, month: 1, day: 1,
      gpsMinusUtc: LeapStartOffset)
    for i, (y, m, d) in oldDays:
      let s = startOf(y, m, d)
      let e = t.entries[i + 1]
      doAssert e.year == s.y and e.month == s.m and e.day == s.d
      doAssert e.gpsMinusUtc == (i + 1) - 9

  block nif_round_trip:
    let t = defaultLeapTable()
    let back = parseLeapTable(leapTableNif(t))
    doAssert back.problems.len == 0, $back.problems
    doAssert back.table == t
    let compact = nif([(1980, 1, 6, 0), (1981, 7, 1, 1)])
    let parsed = parseLeapTable(compact)
    doAssert parsed.problems.len == 0, $parsed.problems
    doAssert parseLeapTable(leapTableNif(parsed.table)).table == parsed.table
    let directed = "(.nif27)\n" & compact
    doAssert parseLeapTable(directed).problems.len == 0

  block each_validation_problem:
    doAssert mentions(parseLeapTable(nif([(1980, 1, 6, 0), (1979, 1, 1,
        1)])).problems,
      "not in order")
    doAssert mentions(parseLeapTable(nif([(1980, 1, 6, 0), (1981, 7, 1,
        2)])).problems,
      "not +1 or -1")
    doAssert mentions(parseLeapTable(nif([(1980, 2, 30, 0)])).problems, "not a real date")
    doAssert mentions(parseLeapTable(nif([(1980, 13, 1, 0)])).problems, "not a real date")
    doAssert mentions(parseLeapTable(nif([(1981, 7, 1, 0)])).problems, "after 1980-01-06")
    doAssert mentions(parseLeapTable(nif([(1980, 1, 6, 5)])).problems, "not 0 or -9")
    doAssert mentions(parseLeapTable("(leapSeconds)").problems, "version is missing")
    doAssert mentions(parseLeapTable("not a document").problems, "expected (leapSeconds")
    doAssert mentions(parseLeapTable(newString(MaxProbe)).problems, "1 MB")
    let neg = parseLeapTable(nif([(1980, 1, 6, 0), (1981, 7, 1, -1)]))
    doAssert neg.problems.len == 0, $neg.problems
    doAssert neg.table.entries[1].gpsMinusUtc == -1
    let anchor = parseLeapTable(nif([(1972, 1, 1, LeapStartOffset)]))
    doAssert anchor.problems.len == 0, $anchor.problems

  block with_leap_refuses_a_bad_date:
    let base = defaultLeapTable()
    let added = base.withLeap(LeapDate(year: 2018, month: 1, day: 1))
    doAssert added.entries.len == base.entries.len + 1
    doAssert added.entries[^1] == LeapSecond(year: 2018, month: 1, day: 1,
      gpsMinusUtc: 19)
    doAssert added.checkedTo == base.checkedTo
    doAssert base.entries[^1].gpsMinusUtc == 18
    let march = base.withLeap(LeapDate(year: 2018, month: 3, day: 1))
    doAssert march.entries[^1].month == 3 and march.entries[^1].gpsMinusUtc == 19
    let down = base.withLeap(LeapDate(year: 2018, month: 1, day: 1), step = -1)
    doAssert down.entries[^1].gpsMinusUtc == 17
    doAssertRaises(ValueError):
      discard base.withLeap(LeapDate(year: 2017, month: 1, day: 1))
    doAssertRaises(ValueError):
      discard base.withLeap(LeapDate(year: 2018, month: 6, day: 30))
    doAssertRaises(ValueError):
      discard base.withLeap(LeapDate(year: 2018, month: 1, day: 1), step = 2)
    doAssertRaises(ValueError):
      discard LeapTable().withLeap(LeapDate(year: 2018, month: 1, day: 1))

  block swap_is_one_consistent_table:
    let added = defaultLeapTable().withLeap(LeapDate(year: 2018, month: 1, day: 1))
    useLeapTable(added)
    doAssert currentLeapTable() == added
    doAssert defaultLeapTable().entries[^1].gpsMinusUtc == 18
    useLeapTable(defaultLeapTable())
    doAssert currentLeapTable() == defaultLeapTable()
    doAssertRaises(ValueError):
      useLeapTable(LeapTable())
    var th: Thread[void]
    createThread(th, reader)
    while readerStarted.load(moAcquire) == 0: discard
    var i = 0
    while sawShort.load(moAcquire) == 0 or sawLong.load(moAcquire) == 0:
      useLeapTable(if i mod 2 == 0: added else: defaultLeapTable())
      inc i
      doAssert i < 1_000_000, "swap was not observed"
    readerStop.store(true, moRelease)
    joinThread(th)
    useLeapTable(defaultLeapTable())

  block conversion_follows_the_table:
    let added = defaultLeapTable().withLeap(LeapDate(year: 2018, month: 1, day: 1))
    let down = defaultLeapTable().withLeap(LeapDate(year: 2018, month: 1,
        day: 1),
      step = -1)
    let boundary = daysFromCivil(2018, 1, 1) * 86400 * 1_000_000
    let before = daysFromCivil(2017, 6, 1) * 86400 * 1_000_000
    let after = daysFromCivil(2018, 6, 1) * 86400 * 1_000_000
    proc keyAt(stamp: int64): TraceKeys =
      var rec = SegdRecord(layout: slRev3)
      var t = SegdTrace(layout: slRev3, channelSet: -1, scanType: -1)
      var ts = SegdTimestampHeader(timeZeroOfData: stamp, blockType: 0x42)
      let raw = ts.encoded
      t.extensions = @raw
      traceKeys(rec, t)
    let stampBefore = utcUsToGpsUs(before)
    let stampAfter = utcUsToGpsUs(after)
    let keyBefore0 = keyAt(stampBefore)
    let keyAfter0 = keyAt(stampAfter)
    let unixAfter0 = timestampToUnix(stampAfter)
    useLeapTable(added)
    doAssert utcMinusGps(boundary - 1) == -18
    doAssert utcMinusGps(boundary) == -19
    doAssert utcMinusGps(boundary + 1) == -19
    doAssert gpsMinusUtc(utcUsToGpsUs(boundary)) == 19
    doAssert gpsUsToUtcUs(utcUsToGpsUs(before)) == before
    doAssert timestampToUnix(utcUsToGpsUs(before)) == float64(
        before div 1_000_000)
    doAssert gpsUsToUtcUs(stampAfter) == after - 1_000_000
    doAssert timestampToUnix(stampAfter) == unixAfter0 - 1.0
    let keyBefore1 = keyAt(stampBefore)
    let keyAfter1 = keyAt(stampAfter)
    doAssert keyBefore1.time == keyBefore0.time
    doAssert keyBefore1.firstSampleUs.get == keyBefore0.firstSampleUs.get
    doAssert keyAfter1.firstSampleUs.get == keyAfter0.firstSampleUs.get - 1_000_000
    doAssert keyAfter1.time == keyAfter0.time - 1.0
    useLeapTable(down)
    doAssert utcMinusGps(boundary - 1) == -18
    doAssert utcMinusGps(boundary) == -17
    doAssert gpsMinusUtc(utcUsToGpsUs(boundary)) == 17
    doAssert gpsUsToUtcUs(utcUsToGpsUs(before)) == before

  block known_through_checked_to:
    let endDay = daysFromCivil(2016, 12, 31) * 86400 * 1_000_000
    doAssert leapKnownAt(endDay)
    doAssert leapKnownAt(endDay + 86400 * 1_000_000 - 1)
    doAssert not leapKnownAt(endDay + 86400 * 1_000_000)
    doAssert gpsMinusUtc(utcUsToGpsUs(endDay + 86400 * 1_000_000)) == 18
    let added = defaultLeapTable().withLeap(LeapDate(year: 2018, month: 1, day: 1))
    useLeapTable(added)
    doAssert not leapKnownAt(daysFromCivil(2017, 6, 1) * 86400 * 1_000_000)
    var later = added
    later.checkedTo = LeapDate(year: 1969, month: 12, day: 31)
    useLeapTable(later)
    doAssert leapKnownAt(-1)
    doAssert not leapKnownAt(0)
    later.checkedTo = LeapDate(year: 2018, month: 6, day: 30)
    useLeapTable(later)
    doAssert leapKnownAt(daysFromCivil(2018, 6, 30) * 86400 * 1_000_000)
    doAssert not leapKnownAt(daysFromCivil(2018, 7, 1) * 86400 * 1_000_000)

when isMainModule: main()
