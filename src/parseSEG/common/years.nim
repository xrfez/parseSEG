## The two-digit year pivot shared by every reader and converter (SEG-D
## general headers, SEG-Y Rev 0 trace headers, SEG-2 dates, SEG P1 records).
## Not re-exported.

func fullYear*(year: int): int {.inline.} =
  ## A two-digit year (0-99) as 1950-2049; any other year unchanged.
  if year in 0..49: 2000 + year elif year in 50..99: 1900 + year else: year
