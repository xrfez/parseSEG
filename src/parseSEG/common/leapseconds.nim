## GPS−UTC leap seconds as a NIF document a caller can replace.
##
## The form is
## `(leapSeconds (version 1) (checkedTo 2016 12 31) (leap (date 2017 1 1) (gpsMinusUtc 18)) ...)`.
## A `;` comment may name the source of the dates. A leading `(.nif27)`
## directive is ignored. `checkedTo` is the last UTC date the table is known
## complete. Each `leap` is the UTC date a new offset starts (00:00:00 that
## day) and the total GPS−UTC in whole seconds from then. Dates are in order,
## each step is +1 or −1 (a negative leap second is allowed), and every date
## is a real proleptic Gregorian date. The first entry is at or before
## 1980-01-06, with offset 0 or `LeapStartOffset` (−9: GPS−UTC from 1972-01-01
## until the leap of 1972-06-30, which is (TAI−UTC) − 19).
##
## The shipped table is `data/leapseconds.nif` (IERS Bulletin C, through the
## leap of 2016-12-31), embedded with `staticRead`, so the library works with
## no file present. `useLeapTable` replaces the table every converter and
## every reader uses from then on. Keys already read keep the instants they
## were given: a caller that changes the table re-reads keys.
##
## The swap is one release store of a pointer to an immutable copy
## (`allocShared`, never freed). A reader acquire-loads that pointer and uses
## the copy, so it cannot see a torn table and no `seq` is shared across
## threads. Copies are not reclaimed: swapping in a loop leaks.

import std/atomics
import ./[niftext, years]

const
  LeapStartOffset* = -9
    ## GPS−UTC in whole seconds before the leap of 1972-06-30.
  MaxLeapBytes = 1 shl 20
  YearMin = -9999
  YearMax = 9999
  GpsEpoch = (year: 1980, month: 1, day: 6)

type
  LeapDate* = object
    ## A UTC calendar date (proleptic Gregorian).
    year*, month*, day*: int

  LeapSecond* = object
    ## The UTC date a GPS−UTC offset starts, and that offset in whole seconds.
    year*, month*, day*: int
    gpsMinusUtc*: int ## GPS − UTC from 00:00:00 UTC of `year`-`month`-`day`.

  LeapTable* = object
    ## Leap seconds in date order, and the last date the list is known complete.
    entries*: seq[LeapSecond]
    checkedTo*: LeapDate ## Through the end of this UTC date the list is complete.

  Published = object
    year, month, day, count: int

static: doAssert sizeof(Published) mod alignof(LeapSecond) == 0

func isLeapYear(y: int): bool =
  (y mod 4 == 0 and y mod 100 != 0) or (y mod 400 == 0)

func isRealDate(y, m, d: int): bool =
  if y notin YearMin .. YearMax or m notin 1 .. 12 or d notin 1 ..
      31: return false
  let dim = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let last = if m == 2 and isLeapYear(y): 29 else: dim[m]
  d <= last

func isRealDate(d: LeapDate): bool {.inline.} = isRealDate(d.year, d.month, d.day)

func dateAfter(y, m, d, oy, om, od: int): bool =
  (y, m, d) > (oy, om, od)

func dateText(y, m, d: int): string = $y & "-" & $m & "-" & $d

func dateStart(y, m, d: int): int64 =
  daysFromCivil(y, m, d) * 86400

proc validate(t: LeapTable, problems: var seq[string]) =
  if not isRealDate(t.checkedTo):
    problems.add "checkedTo " & dateText(t.checkedTo.year, t.checkedTo.month,
      t.checkedTo.day) & " is not a real date"
  if t.entries.len == 0:
    problems.add "leap table has no entries"
    return
  let first = t.entries[0]
  if not isRealDate(first.year, first.month, first.day):
    problems.add "not a real date: " & dateText(first.year, first.month, first.day)
  elif dateAfter(first.year, first.month, first.day, GpsEpoch.year,
      GpsEpoch.month, GpsEpoch.day):
    problems.add "first entry " & dateText(first.year, first.month, first.day) &
      " is after 1980-01-06"
  if first.gpsMinusUtc != 0 and first.gpsMinusUtc != LeapStartOffset:
    problems.add "first entry offset is " & $first.gpsMinusUtc & ", not 0 or " &
      $LeapStartOffset
  for i in 1 ..< t.entries.len:
    let prev = t.entries[i - 1]
    let e = t.entries[i]
    if not isRealDate(e.year, e.month, e.day):
      problems.add "not a real date: " & dateText(e.year, e.month, e.day)
    if not dateAfter(e.year, e.month, e.day, prev.year, prev.month, prev.day):
      problems.add "dates are not in order: " & dateText(e.year, e.month,
          e.day) &
        " is not after " & dateText(prev.year, prev.month, prev.day)
    let step = e.gpsMinusUtc - prev.gpsMinusUtc
    if step notin [-1, 1]:
      problems.add "leap step is " & $step & ", not +1 or -1"

proc readLeap(n: var NifIn, problems: var seq[string]): LeapSecond =
  var gotDate = false
  var gotOff = false
  while true:
    let t = n.next
    case t.kind
    of ntClose: break
    of ntEof: n.docError("unexpected end of the document")
    of ntOpen:
      case t.s
      of "date":
        if gotDate: problems.add "leap has two dates"
        result.year = int(n.expectInt("year"))
        result.month = int(n.expectInt("month"))
        result.day = int(n.expectInt("day"))
        n.expectClose("date")
        gotDate = true
      of "gpsMinusUtc":
        if gotOff: problems.add "leap has two offsets"
        result.gpsMinusUtc = int(n.expectInt("gpsMinusUtc"))
        n.expectClose("gpsMinusUtc")
        gotOff = true
      else:
        problems.add "unknown tag (" & t.s & ")"
        n.skipTree(1)
    else:
      problems.add "unexpected token in leap"
  if not gotDate: problems.add "leap is missing a date"
  if not gotOff: problems.add "leap is missing gpsMinusUtc"

proc readBody(n: var NifIn, problems: var seq[string]): LeapTable =
  var sawVersion = false
  var sawChecked = false
  while true:
    let t = n.next
    case t.kind
    of ntClose: break
    of ntEof: n.docError("unexpected end of the document")
    of ntOpen:
      case t.s
      of "version":
        if sawVersion: problems.add "version is repeated"
        let v = n.expectInt("version")
        if v != 1: problems.add "version is " & $v & ", not 1"
        n.expectClose("version")
        sawVersion = true
      of "checkedTo":
        if sawChecked: problems.add "checkedTo is repeated"
        result.checkedTo.year = int(n.expectInt("year"))
        result.checkedTo.month = int(n.expectInt("month"))
        result.checkedTo.day = int(n.expectInt("day"))
        n.expectClose("checkedTo")
        sawChecked = true
      of "leap":
        result.entries.add n.readLeap(problems)
      else:
        problems.add "unknown tag (" & t.s & ")"
        n.skipTree(1)
    else:
      problems.add "unexpected token in leapSeconds"
  if not sawVersion: problems.add "version is missing"
  if not sawChecked: problems.add "checkedTo is missing"

proc readDoc(n: var NifIn, problems: var seq[string]): LeapTable =
  var t = n.next
  if t.kind == ntOpen and t.s.len > 0 and t.s[0] == '.':
    n.skipTree(1)
    t = n.next
  if t.kind != ntOpen or t.s != "leapSeconds":
    n.docError("expected (leapSeconds ...)")
  result = readBody(n, problems)
  if n.next.kind != ntEof:
    problems.add "unexpected token after leapSeconds"

proc parseLeapTable*(nifText: string): tuple[table: LeapTable, problems: seq[string]]
    {.raises: [].} =
  ## Parses a leap-second document. Validation failures and malformed NIF are
  ## `problems`, never exceptions. A document longer than 1 MB is refused.
  ## `table` may be partial when `problems` is not empty.
  var problems: seq[string] = @[]
  var table = LeapTable()
  if nifText.len > MaxLeapBytes:
    problems.add "leap table longer than 1 MB"
    return (table, problems)
  var n = initNifIn(nifText, "leapseconds")
  try:
    table = readDoc(n, problems)
    validate(table, problems)
  except CatchableError as e:
    problems.add e.msg
  (table, problems)

func leapTableNif*(t: LeapTable): string =
  ## `t` as a version-1 leap-second document. `parseLeapTable` of the result
  ## is `t` when `t` is valid.
  result = "(leapSeconds\n  (version 1)\n  (checkedTo " &
    $t.checkedTo.year & " " & $t.checkedTo.month & " " & $t.checkedTo.day & ")\n"
  for e in t.entries:
    result.add "  (leap (date " & $e.year & " " & $e.month & " " & $e.day &
      ") (gpsMinusUtc " & $e.gpsMinusUtc & "))\n"
  result.add ")\n"

proc withLeap*(t: LeapTable, date: LeapDate, step = 1): LeapTable =
  ## A copy of `t` with one leap that takes effect at 00:00:00 UTC of `date`.
  ## By convention that is the day after 30 June or 31 December; the first of
  ## any month is accepted (the day after that month's previous end). `step`
  ## is +1 or −1, added to the last offset. `checkedTo` is unchanged.
  ## Raises `ValueError` when `t` has no entries, `date` is not a real first
  ## of a month after the last entry, or `step` is not ±1.
  if t.entries.len == 0:
    raise newException(ValueError, "leap table has no entries")
  if step notin [-1, 1]:
    raise newException(ValueError, "leap step must be +1 or -1, not " & $step)
  if not isRealDate(date) or date.day != 1:
    raise newException(ValueError, "a leap second takes effect at 00:00:00 UTC" &
      " on the first of a month, not " & dateText(date.year, date.month, date.day))
  let last = t.entries[^1]
  if not dateAfter(date.year, date.month, date.day, last.year, last.month, last.day):
    raise newException(ValueError, "leap date must be after " &
      dateText(last.year, last.month, last.day))
  result = t
  result.entries.add LeapSecond(year: date.year, month: date.month,
    day: date.day,
    gpsMinusUtc: last.gpsMinusUtc + step)

proc allocPublished(t: LeapTable): pointer =
  let n = t.entries.len
  let raw = allocShared0(sizeof(Published) + n * sizeof(LeapSecond))
  let p = cast[ptr Published](raw)
  p.year = t.checkedTo.year
  p.month = t.checkedTo.month
  p.day = t.checkedTo.day
  p.count = n
  if n > 0:
    let ents = cast[ptr UncheckedArray[LeapSecond]](
      cast[uint](raw) + uint(sizeof(Published)))
    for i in 0 ..< n: ents[i] = t.entries[i]
  raw

proc entriesOf(p: ptr Published): ptr UncheckedArray[LeapSecond] {.inline.} =
  cast[ptr UncheckedArray[LeapSecond]](cast[uint](p) + uint(sizeof(Published)))

proc copyPublished(p: ptr Published): LeapTable =
  result.checkedTo = LeapDate(year: p.year, month: p.month, day: p.day)
  let n = p.count
  result.entries = newSeq[LeapSecond](n)
  if n > 0:
    let ents = entriesOf(p)
    for i in 0 ..< n: result.entries[i] = ents[i]

var defaultSlot: Atomic[pointer]
var currentSlot: Atomic[pointer]

proc loadSlot(slot: var Atomic[pointer]): ptr Published {.gcsafe.} =
  {.cast(gcsafe).}:
    result = cast[ptr Published](slot.load(moAcquire))
  doAssert not result.isNil

proc defaultLeapTable*(): LeapTable {.gcsafe, raises: [].} =
  ## The shipped table, parsed from the embedded `data/leapseconds.nif`.
  ## Not the table `useLeapTable` installed.
  copyPublished(loadSlot(defaultSlot))

proc currentLeapTable*(): LeapTable {.gcsafe, raises: [].} =
  ## The table converters and readers use. The shipped table until
  ## `useLeapTable`.
  copyPublished(loadSlot(currentSlot))

proc useLeapTable*(t: LeapTable) =
  ## Makes `t` the table every converter and every reader uses from then on.
  ## Raises `ValueError` when `t` would not parse cleanly (no entries, a bad
  ## date, a step other than ±1, a first entry after 1980-01-06 or with an
  ## offset other than 0 or `LeapStartOffset`). Keys already read keep the
  ## instants they were given.
  var problems: seq[string] = @[]
  validate(t, problems)
  if problems.len > 0:
    raise newException(ValueError, problems[0])
  currentSlot.store(allocPublished(t), moRelease)

proc leapOffsetAt*(unixSec: int64): int {.gcsafe, raises: [].} =
  # GPS − UTC at POSIX second `unixSec`. Before the first entry, that
  # entry's offset (the documented start covers every earlier instant).
  # Not on the umbrella: converters call it; callers use `gpsMinusUtc`.
  let p = loadSlot(currentSlot)
  doAssert p.count > 0
  result = entriesOf(p)[0].gpsMinusUtc
  let ents = entriesOf(p)
  for i in 0 ..< p.count:
    if dateStart(ents[i].year, ents[i].month, ents[i].day) <= unixSec:
      result = ents[i].gpsMinusUtc
    else: break

const embeddedLeapNif = staticRead("../../../data/leapseconds.nif")

proc installDefault() =
  let parsed = parseLeapTable(embeddedLeapNif)
  doAssert parsed.problems.len == 0, (
    if parsed.problems.len > 0: parsed.problems[0] else: "")
  let p = allocPublished(parsed.table)
  defaultSlot.store(p, moRelease)
  currentSlot.store(p, moRelease)

installDefault()
