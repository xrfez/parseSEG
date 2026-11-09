## The two-digit year pivot shared by every reader and converter (SEG-D
## general headers, SEG-Y Rev 0 trace headers, SEG-2 dates, SEG P1 records),
## and the civil-date arithmetic of their timestamps. Not re-exported.

func fullYear*(year: int): int {.inline.} =
  ## A two-digit year (0-99) as 1950-2049; any other year unchanged.
  if year in 0..49: 2000 + year elif year in 50..99: 1900 + year else: year

func daysFromCivil*(y, m, d: int): int64 {.inline.} =
  ## Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's
  ## algorithm), integer only: what `std/times` gives, without building a
  ## `DateTime` (the SEG-Y keys make one date per trace).
  let yy = if m <= 2: y - 1 else: y
  let era = (if yy >= 0: yy else: yy - 399) div 400
  let yoe = yy - era * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era) * 146097 + int64(doe) - 719468
