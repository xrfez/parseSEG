## SEG-Y coordinate scalars for the geometry write-back
## (`survey/writeback`): whether a scalar holds a group of values, and which
## one to write.

import std/math

func rawOf*(v: float64, s: int16): float64 {.inline.} =
  ## The stored integer of value `v` under SEG-Y scalar `s` (unrounded).
  if s > 0: v / float64(s) elif s < 0: v * float64(-int32(s)) else: v

func fitsScalar*(vals: openArray[float64], s: int16): bool =
  ## Every value of `vals` fits a 4-byte field under scalar `s`.
  for v in vals:
    if abs(round(rawOf(v, s))) > 2147483647.0: return false
  true

func exactScalar*(vals: openArray[float64], s: int16): bool =
  ## Scalar `s` holds every value of `vals` exactly (to 1e-4 of a unit).
  for v in vals:
    let r = rawOf(v, s)
    if abs(r - round(r)) > 1e-4: return false
  true

func chooseScalar*(vals: openArray[float64], current: int16, exact: var bool): int16 =
  ## The SEG-Y scalar for `vals` (see `survey/writeback`): `current` when it
  ## holds them exactly, else the coarsest exact one of 1, -10, ..., -10000,
  ## else the finest that fits (`exact` tells whether it holds them
  ## exactly). 0 when none fits.
  exact = true
  let cur = if current == 0: 1'i16 else: current
  if exactScalar(vals, cur) and fitsScalar(vals, cur): return cur
  for s in [1'i16, -10, -100, -1000, -10000]:
    if exactScalar(vals, s) and fitsScalar(vals, s): return s
  for s in [-10000'i16, -1000, -100, -10, 1, 10, 100, 1000, 10000]:
    if fitsScalar(vals, s):
      exact = exactScalar(vals, s)
      return s
  exact = false
  0
