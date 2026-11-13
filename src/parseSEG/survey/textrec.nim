## Card-image text records shared by the survey formats (SPS, SEG P1).
##
## Survey files are 80-column card images (SPS and P1 data records may be
## longer). On disk they come as newline-terminated lines (LF or CRLF,
## trailing blanks often trimmed), or as fixed 80-byte records with no line
## terminators, in ASCII or EBCDIC. `textRecords` reads all of these from a
## stream, one record at a time, so a file is never loaded whole.
##
## An all-blank numeric field is missing: NaN for reals, `MissingInt` for
## integers.

import std/streams
import ../common/[ebcdic, diagnostics]
import ./linespans

type
  TextLayout* = enum
    ## How the records of a survey file are stored.
    tlLines = "lines"        ## Terminated by LF, CR LF or a lone CR.
    tlFixed80 = "fixed80"    ## Fixed 80-byte ASCII records, no terminators.
    tlEbcdic80 = "ebcdic80"  ## Fixed 80-byte EBCDIC records (tape copies).

  TextRecord* = object
    ## One record as read: its text (without the terminator, EBCDIC already
    ## translated) and where it starts.
    text*: string
    offset*: int64 ## Byte offset of the record in the stream.
    index*: int    ## 0-based record (line) number.
    crlf*: bool    ## The line ended in CR LF (`tlLines`).
    terminated*: bool ## A line terminator followed (always true for fixed records).
    cut*: bool
      ## The line was longer than `MaxLineBytes` and was cut there; the rest
      ## follows as the next record. A reader should report it.

const
  CardWidth* = 80 ## Columns of a card image.
  MaxLineBytes* = 65536 ## Longer "lines" are cut (a binary file, or fixed records with a stray LF).

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
  ## The records of `s`. With `tlLines`, a record ends at LF, CR LF or a lone
  ## CR (the terminator is not part of the text); NUL and other bytes are
  ## data. A final line without a terminator is still a record (with
  ## `terminated` false), but an empty one at the very end is not.
  var rec = TextRecord()
  case layout
  of tlLines:
    var buf: string
    for span in lineSpans(s, buf, MaxLineBytes):
      rec.text.setLen(span.hi - span.lo + 1)
      if rec.text.len > 0: copyMem(addr rec.text[0], addr buf[span.lo], rec.text.len)
      rec.offset = span.offset
      rec.index = span.index
      rec.crlf = span.crlf
      rec.terminated = span.terminated
      rec.cut = span.cut
      yield rec
  of tlFixed80, tlEbcdic80:
    var buf = newString(CardWidth)
    while true:
      let offset = int64(s.getPosition)
      let n = s.readData(buf[0].addr, CardWidth)
      if n <= 0: break
      var text = buf[0..<n]
      if layout == tlEbcdic80: text = decodeEbcdic(text.toOpenArrayByte(0, n - 1))
      rec.text = text
      rec.offset = offset
      rec.terminated = true
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

const MissingInt* = low(int64)
  ## An `Iw` integer field that was blank (e.g. `SpsRelation.fieldRecord`).

type
  SurveyText* = object
    ## A survey file written to a string (`spsText`, `p1Text`).
    text*: string ## The records, as the file would hold them.
    log*: DiagLog ## The writer's diagnostics.
