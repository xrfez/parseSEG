## Card-image field helpers shared by the survey readers and writers (SPS,
## SEG P1). Internal: the `parseSEG` umbrella does not export this module.
##
## Fields are addressed by 1-based inclusive columns, as the specs number
## them. Numbers follow FORTRAN formatted input: `Iw` is a right-justified
## integer; `Fw.d` has an implicit decimal point before the last `d` digits
## unless the field holds a `.`.

import std/[options, strutils, math, streams, tables, parseutils]
import ../common/[errors, diagnostics]
import ./textrec

const MaxRepeats* = 5
  ## Diagnostics of one code and field logged by one read; the rest are counted.

type RepeatCap* = object
  ## Counts a reader's diagnostics per code and field, so a file of a
  ## million bad records logs a few of each kind and how many more there
  ## were, not millions of entries (1e6 lines of `R` were 3e6 diagnostics,
  ## 1.4 GB).
  counts: OrderedTable[(DiagCode, string), int]
  quiet*: bool ## Admit nothing (a re-parse whose diagnostics are not wanted).

proc admit*(cap: var RepeatCap, code: DiagCode, field: string): bool =
  ## Counts a diagnostic of `code` for `field`; true while it is one of the
  ## first `MaxRepeats`, which the caller logs.
  if cap.quiet: return false
  let n = cap.counts.mgetOrPut((code, field), 0) + 1
  cap.counts[(code, field)] = n
  n <= MaxRepeats

proc summarize*(cap: RepeatCap, log: var DiagLog, file: string) =
  ## One info per code and field that had more diagnostics than were logged.
  for key, n in cap.counts:
    if n > MaxRepeats:
      log.report(sevInfo, key[0], $(n - MaxRepeats) & " more diagnostics of this kind" &
        (if key[1].len > 0: " for " & key[1] else: "") & " were not logged",
        loc = Location(file: file, field: key[1]))

proc skipBom*(s: Stream) =
  ## Leaves `s` after a UTF-8 byte order mark when it is at one (an editor's
  ## addition: it is not part of the first record), else where it was.
  let start = s.getPosition
  var head: array[3, char]
  if s.readData(addr head[0], 3) != 3 or head != ['\xEF', '\xBB', '\xBF']:
    s.setPosition(start)

func col*(line: string, first, last: int): string =
  ## Columns `first..last` (1-based, inclusive) of `line`, blank-padded where
  ## the line is shorter.
  result = newString(last - first + 1)
  for i in first..last:
    result[i - first] = if i - 1 < line.len: line[i - 1] else: ' '

func colChar*(line: string, c: int): char {.inline.} =
  ## Column `c` (1-based), a blank past the end of the line.
  if c - 1 < line.len: line[c - 1] else: ' '

func colChar*(line: openArray[char], c: int): char {.inline.} =
  ## Column `c` (1-based) of a line given as a view, a blank past its end.
  if c - 1 < line.len: line[c - 1] else: ' '

func trimmed*(line: openArray[char], first, last: int): Slice[int] {.inline.} =
  ## Columns `first..last` (1-based, inclusive) of `line` without the
  ## whitespace around them (as `strip` takes it off), as 0-based indices:
  ## `a > b` for a blank field or one past the end of the line. Nothing is
  ## copied: the readers parse a field where it stands.
  var a = first - 1
  var b = min(last, line.len) - 1
  while a <= b and line[a] in Whitespace: inc a
  while b >= a and line[b] in Whitespace: dec b
  a .. b

func fieldText*(line: openArray[char], f: Slice[int]): string =
  ## The characters of a `trimmed` field as a string ("" when blank).
  result = newString(max(f.b - f.a + 1, 0))
  if result.len > 0: copyMem(addr result[0], addr line[f.a], result.len)

func fortranFloat*(line: openArray[char], f: Slice[int], decimals: int, v: var float64): bool =
  ## `parseFortranFloat` for a `trimmed` field of `line`: false when it is
  ## not a finite number; a blank field is NaN and true.
  if f.a > f.b:
    v = NaN
    return true
  if parseFloat(line.toOpenArray(f.a, f.b), v) != f.b - f.a + 1 or
      v.classify in {fcNan, fcInf, fcNegInf}:
    return false
  if decimals > 0:
    var written = false # an explicit point or exponent: taken as written
    for i in f.a .. f.b:
      if line[i] in {'.', 'e', 'E'}: written = true
    if not written: v = v / pow(10.0, float64(decimals))
  true

func fortranInt*(line: openArray[char], f: Slice[int], v: var int64): bool =
  ## `parseFortranInt` for a `trimmed` field of `line`: false when it is not
  ## an integer; a blank field is `MissingInt` and true.
  if f.a > f.b:
    v = MissingInt
    return true
  try:
    var n: BiggestInt
    result = parseBiggestInt(line.toOpenArray(f.a, f.b), n) == f.b - f.a + 1
    v = n
  except ValueError: # out of range
    result = false

func isBlank*(s: string): bool =
  ## Only blanks (or empty).
  s.allCharsInSet({' '})

func allBlank*(s: openArray[char]): bool =
  ## Only blanks (or empty), for a view of a line (`toOpenArray`).
  for c in s:
    if c != ' ': return false
  true

func parseFortranFloat*(field: string, decimals = 0): Option[float64] =
  ## Parses a FORTRAN `Fw.d` field: a value with an explicit `.` (or an
  ## exponent) is taken as written; digits only get an implicit decimal point
  ## before the last `decimals` digits. Embedded blanks are not zeros here:
  ## they make the field invalid. A blank field is valid and NaN; none when
  ## the text is not a finite number (`inf`, `nan` and `1e999` are not
  ## numbers on a survey card).
  var v: float64
  if fortranFloat(field, field.trimmed(1, field.len), decimals, v): some(v)
  else: none(float64)

func parseFortranInt*(field: string): Option[int64] =
  ## Parses a FORTRAN `Iw` field (sign allowed). A blank field is valid and
  ## `MissingInt`; none when the text is not an integer.
  var v: int64
  if fortranInt(field, field.trimmed(1, field.len), v): some(v)
  else: none(int64)

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
