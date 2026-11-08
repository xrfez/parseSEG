## Card-image field helpers shared by the survey readers and writers (SPS,
## SEG P1). Internal: the `parseSEG` umbrella does not export this module.
##
## Fields are addressed by 1-based inclusive columns, as the specs number
## them. Numbers follow FORTRAN formatted input: `Iw` is a right-justified
## integer; `Fw.d` has an implicit decimal point before the last `d` digits
## unless the field holds a `.`.

import std/[options, strutils, math]
import ../common/errors
import ./textrec

func col*(line: string, first, last: int): string =
  ## Columns `first..last` (1-based, inclusive) of `line`, blank-padded where
  ## the line is shorter.
  result = newString(last - first + 1)
  for i in first..last:
    result[i - first] = if i - 1 < line.len: line[i - 1] else: ' '

func colChar*(line: string, c: int): char {.inline.} =
  ## Column `c` (1-based), a blank past the end of the line.
  if c - 1 < line.len: line[c - 1] else: ' '

func isBlank*(s: string): bool =
  ## Only blanks (or empty).
  s.allCharsInSet({' '})

func parseFortranFloat*(field: string, decimals = 0): Option[float64] =
  ## Parses a FORTRAN `Fw.d` field: a value with an explicit `.` (or an
  ## exponent) is taken as written; digits only get an implicit decimal point
  ## before the last `decimals` digits. Embedded blanks are not zeros here:
  ## they make the field invalid. A blank field is valid and NaN; none when
  ## the text is not a number.
  let t = field.strip
  if t.len == 0: return some(NaN)
  try:
    let v = parseFloat(t)
    some(if decimals > 0 and '.' notin t and 'e' notin t and 'E' notin t:
           v / pow(10.0, float64(decimals))
         else: v)
  except ValueError:
    none(float64)

func parseFortranInt*(field: string): Option[int64] =
  ## Parses a FORTRAN `Iw` field (sign allowed). A blank field is valid and
  ## `MissingInt`; none when the text is not an integer.
  let t = field.strip
  if t.len == 0: return some(MissingInt)
  try: some(parseBiggestInt(t))
  except ValueError: none(int64)

func formatFixed*(v: float64, width, decimals: int, implicit = false): string =
  ## `v` as an `Fw.d` field: `decimals` digits after an explicit point, or
  ## with `implicit`, the scaled integer without a point. NaN is blank.
  ## Returns "" when the value does not fit in `width` (or is infinite).
  if v.isNaN: return repeat(' ', width)
  if abs(v) > 1e15: return "" # wider than any card field; also Inf
  let s = if implicit: $int64(round(v * pow(10.0, float64(decimals))))
          else: formatFloat(v, ffDecimal, decimals)
  if s.len > width: "" else: align(s, width)

func formatInt*(v: int64, width: int): string =
  ## `v` as an `Iw` field; `MissingInt` is blank. "" when it does not fit.
  if v == MissingInt: return repeat(' ', width)
  let s = $v
  if s.len > width: "" else: align(s, width)

proc fit*(text: string, width: int, field: string): string =
  ## `text` when it fills 1..`width` columns; else raises `SegFormatError`
  ## naming `field`.
  if text.len == 0 or text.len > width:
    raiseFormat(field & ": value does not fit in " & $width & " columns")
  text

proc putCol*(line: var string, first: int, text: string) =
  ## Writes `text` into `line` starting at column `first` (1-based),
  ## extending the line with blanks as needed.
  let last = first + text.len - 1
  if line.len < last: line.add repeat(' ', last - line.len)
  for i, c in text: line[first - 1 + i] = c

func sameValues*[T: object](a, b: T): bool =
  ## Field-by-field equality where NaN equals NaN (a missing value is the
  ## same missing value). Writers use it to tell an unchanged record, whose
  ## raw text is written back, from an edited one.
  for x, y in fields(a, b):
    when x is SomeFloat:
      if not (x == y or (x.isNaN and y.isNaN)): return false
    else:
      if x != y: return false
  true
