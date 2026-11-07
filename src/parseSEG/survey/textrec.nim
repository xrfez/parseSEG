## Card-image text records shared by the survey formats (SPS, SEG P1).
##
## Survey files are 80-column card images (SPS and P1 data records may be
## longer). On disk they come as newline-terminated lines (LF or CRLF,
## trailing blanks often trimmed), or as fixed 80-byte records with no line
## terminators, in ASCII or EBCDIC. `textRecords` reads all of these from a
## stream, one record at a time, so a file is never loaded whole.
##
## Fields are addressed by 1-based inclusive columns, as the specs number
## them. Numbers follow FORTRAN formatted input: `Iw` is a right-justified
## integer; `Fw.d` has an implicit decimal point before the last `d` digits
## unless the field holds a `.`. An all-blank field is missing (NaN, or
## `none`).

import std/[streams, strutils, math]
import ../common/ebcdic

type
  TextLayout* = enum
    ## How the records of a survey file are stored.
    tlLines = "lines"        ## Newline-terminated (LF or CRLF).
    tlFixed80 = "fixed80"    ## Fixed 80-byte ASCII records, no terminators.
    tlEbcdic80 = "ebcdic80"  ## Fixed 80-byte EBCDIC records (tape copies).

  TextRecord* = object
    ## One record as read: its text (without the terminator, EBCDIC already
    ## translated) and where it starts.
    text*: string
    offset*: int64 ## Byte offset of the record in the stream.
    index*: int    ## 0-based record (line) number.
    crlf*: bool    ## The line ended in CR LF (`tlLines`).

const CardWidth* = 80

proc detectLayout*(head: openArray[char]): TextLayout =
  ## Guesses the storage from the first bytes of a file: any CR or LF means
  ## lines; else EBCDIC when the bytes look like EBCDIC text (blanks are
  ## 0x40, letters >= 0x81), else fixed 80-byte ASCII.
  result = tlFixed80
  var ebcdicBlanks, asciiBlanks, high = 0
  for c in head:
    case c
    of '\n', '\r': return tlLines
    of '\x40': inc ebcdicBlanks
    of ' ': inc asciiBlanks
    elif ord(c) >= 0x81: inc high
    else: discard
  if ebcdicBlanks > asciiBlanks and ebcdicBlanks + high > head.len div 4:
    result = tlEbcdic80

iterator textRecords*(s: Stream, layout: TextLayout): TextRecord =
  ## The records of `s`. With `tlLines`, a trailing CR is dropped (CRLF);
  ## a final line without a terminator is still a record, but an empty one
  ## at the very end is not.
  var rec = TextRecord()
  case layout
  of tlLines:
    var line = ""
    var offset = int64(s.getPosition)
    while s.readLine(line):
      let next = int64(s.getPosition)
      # `readLine` ends a line at LF, CR or CR LF and drops the terminator,
      # so a CR LF shows as two bytes beyond the text.
      let hadCr = next - offset - line.len == 2
      rec.text = line
      rec.crlf = hadCr
      rec.offset = offset
      yield rec
      inc rec.index
      offset = next
  of tlFixed80, tlEbcdic80:
    var buf = newString(CardWidth)
    while true:
      let offset = int64(s.getPosition)
      let n = s.readData(buf[0].addr, CardWidth)
      if n <= 0: break
      var text = buf[0..<n]
      if layout == tlEbcdic80: text = ebcdicToAscii(text.toOpenArrayByte(0, n - 1))
      rec.text = text
      rec.offset = offset
      yield rec
      inc rec.index

proc openLayout*(s: Stream): TextLayout =
  ## Detects the layout of `s` from its first 4 KB, then rewinds to where
  ## it was.
  let start = s.getPosition
  var head = newString(4096)
  let n = s.readData(head[0].addr, head.len)
  head.setLen(max(n, 0))
  s.setPosition(start)
  detectLayout(head)

# ------------------------------------------------------------ field access --

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
  for c in s:
    if c != ' ': return false
  true

proc parseFortranFloat*(field: string, decimals = 0, value: var float64): bool =
  ## Parses a FORTRAN `Fw.d` field: a value with an explicit `.` (or an
  ## exponent) is taken as written; digits only get an implicit decimal point
  ## before the last `decimals` digits. Embedded blanks are not zeros here:
  ## they make the field invalid. A blank field is valid and NaN. False if the
  ## text is not a number.
  let t = field.strip
  if t.len == 0:
    value = NaN
    return true
  try:
    let v = parseFloat(t)
    value = if decimals > 0 and '.' notin t and 'e' notin t and 'E' notin t:
              v / pow(10.0, float64(decimals))
            else: v
    result = true
  except ValueError:
    result = false

proc parseFortranInt*(field: string, value: var int64): bool =
  ## Parses a FORTRAN `Iw` field (sign allowed). A blank field is valid and
  ## leaves `value` at `low(int64)`, the "missing" marker. False if the text
  ## is not an integer.
  let t = field.strip
  if t.len == 0:
    value = low(int64)
    return true
  try:
    value = parseBiggestInt(t)
    result = true
  except ValueError:
    result = false

const MissingInt* = low(int64) ## An `Iw` field that was blank.

# ------------------------------------------------------------- formatting --

func rjust*(s: string, width: int): string =
  ## `s` right-justified in `width` columns; longer text is returned as is
  ## (the caller checks the width).
  if s.len >= width: s else: repeat(' ', width - s.len) & s

func ljust*(s: string, width: int): string =
  ## `s` left-justified in `width` columns.
  if s.len >= width: s else: s & repeat(' ', width - s.len)

func formatFixed*(v: float64, width, decimals: int, implicit = false): string =
  ## `v` as an `Fw.d` field: `decimals` digits after an explicit point, or
  ## with `implicit`, the scaled integer without a point. NaN is blank.
  ## Returns "" when the value does not fit in `width`.
  if v.isNaN: return repeat(' ', width)
  let s = if implicit: $int64(round(v * pow(10.0, float64(decimals))))
          else: formatFloat(v, ffDecimal, decimals)
  if s.len > width: "" else: rjust(s, width)

func formatInt*(v: int64, width: int): string =
  ## `v` as an `Iw` field; `MissingInt` is blank. "" when it does not fit.
  if v == MissingInt: return repeat(' ', width)
  let s = $v
  if s.len > width: "" else: rjust(s, width)

proc putCol*(line: var string, first: int, text: string) =
  ## Writes `text` into `line` starting at column `first` (1-based),
  ## extending the line with blanks as needed.
  let last = first + text.len - 1
  if line.len < last: line.add repeat(' ', last - line.len)
  for i, c in text: line[first - 1 + i] = c
