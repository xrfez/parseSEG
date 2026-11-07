## SEG-Y textual file header: 3200 bytes, 40 card images of 80 columns,
## EBCDIC or ASCII (spec note `segy_rev1.md` §3.1, `segy_rev2_1.md` §3.1).
##
## The raw bytes are kept as read, so a round trip is byte-identical whatever
## the content. Text is exposed as Latin-1 strings. Text blocks are never
## byte-swapped.

import ../common/ebcdic

const
  TextHeaderSize* = 3200 ## Bytes in a textual header or extended textual record.
  CardWidth* = 80        ## Columns per card image.
  CardCount* = 40        ## Card images in the textual file header.

type
  TextEncoding* = enum
    ## Character set of a text block.
    teEbcdic = "ebcdic" ## IBM code page 037 (the traditional encoding).
    teAscii = "ascii"   ## ASCII / Latin-1 (allowed since Rev 1).

  CardNumber* = range[1..CardCount]

  SegyTextHeader* = object
    ## A 3200-byte textual file header.
    data*: array[TextHeaderSize, byte] ## Raw bytes as stored in the file.
    encoding*: TextEncoding            ## Character set of `data`.

func isAsciiText(c: byte): bool {.inline.} =
  c in {0x20'u8..0x7E'u8, 0x0A, 0x0D}

func isEbcdicText(c: byte): bool {.inline.} =
  # Space, punctuation, letters and digits of cp037 (spec App. F).
  c in {0x40'u8, 0x4A..0x50, 0x5A..0x61, 0x6A..0x6F, 0x79..0x7F, 0x81..0x89, 0x91..0x99,
    0xA1..0xA9, 0xC0..0xC9, 0xD0..0xD9, 0xE0, 0xE2..0xE9, 0xF0..0xF9, 0x0D, 0x25}

func detectTextEncoding*(b: openArray[byte]): TextEncoding =
  ## Detects the character set of a text block. A leading `C` decides it
  ## (EBCDIC 0xC3, ASCII 0x43); otherwise the set under which more bytes are
  ## printable wins, with ties going to EBCDIC.
  if b.len > 0 and b[0] == 0xC3:
    result = teEbcdic
  elif b.len > 0 and b[0] == 0x43:
    result = teAscii
  else:
    var ascii, ebcdic = 0
    for c in b:
      if isAsciiText(c): inc ascii
      if isEbcdicText(c): inc ebcdic
    result = if ascii > ebcdic: teAscii else: teEbcdic

func decodeText*(b: openArray[byte], encoding: TextEncoding): string =
  ## Decodes text bytes to a Latin-1 string.
  case encoding
  of teEbcdic:
    result = ebcdicToAscii(b)
  of teAscii:
    result = newString(b.len)
    for i, c in b: result[i] = char(c)

func encodeText*(s: openArray[char], encoding: TextEncoding): seq[byte] =
  ## Encodes a Latin-1 string to text bytes.
  case encoding
  of teEbcdic:
    result = asciiToEbcdic(s)
  of teAscii:
    result = newSeq[byte](s.len)
    for i, c in s: result[i] = byte(c)

func cardPrefix*(n: CardNumber): string =
  ## The standard columns 1-4 of card `n`: `C`, the right-justified card
  ## number and a blank, e.g. `"C 1 "` or `"C40 "`.
  result = (if n < 10: "C " else: "C") & $n & " "

func decodeTextHeader*(b: openArray[byte]): SegyTextHeader =
  ## Decodes a textual header from the first 3200 bytes of `b` and detects its
  ## character set.
  doAssert b.len >= TextHeaderSize, "textual header needs 3200 bytes"
  result = SegyTextHeader(encoding: detectTextEncoding(b.toOpenArray(0, TextHeaderSize - 1)))
  for i in 0..<TextHeaderSize:
    result.data[i] = b[i]

func encode*(h: SegyTextHeader, b: var openArray[byte]) =
  ## Writes the 3200 raw bytes of `h` to the start of `b`.
  doAssert b.len >= TextHeaderSize, "textual header needs 3200 bytes"
  for i in 0..<TextHeaderSize:
    b[i] = h.data[i]

proc setText*(h: var SegyTextHeader, text: openArray[char]) =
  ## Replaces the whole header with `text` in `h.encoding`, truncated or padded
  ## with blanks to 3200 characters. No card prefixes are added.
  let blank = encodeText([' '], h.encoding)[0]
  let bytes = encodeText(text.toOpenArray(0, min(text.len, TextHeaderSize) - 1), h.encoding)
  for i in 0..<TextHeaderSize:
    h.data[i] = if i < bytes.len: bytes[i] else: blank

func initTextHeader*(encoding = teEbcdic): SegyTextHeader =
  ## A blank header whose cards carry only the standard prefixes `C 1 ` ..
  ## `C40 `.
  result = SegyTextHeader(encoding: encoding)
  var text = newStringOfCap(TextHeaderSize)
  for n in CardNumber.low..CardNumber.high:
    let prefix = cardPrefix(n)
    text.add prefix
    for _ in prefix.len..<CardWidth: text.add ' '
  result.setText(text)

func text*(h: SegyTextHeader): string =
  ## The whole header decoded to a 3200-character Latin-1 string.
  decodeText(h.data, h.encoding)

func card*(h: SegyTextHeader, n: CardNumber): string =
  ## Card image `n` (1-based), decoded to 80 Latin-1 characters.
  let start = (n - 1) * CardWidth
  decodeText(h.data.toOpenArray(start, start + CardWidth - 1), h.encoding)

proc setCard*(h: var SegyTextHeader, n: CardNumber, text: openArray[char]) =
  ## Replaces card `n` with `text`, truncated or padded with blanks to 80
  ## columns. The caller supplies columns 1-4 (see `cardPrefix`).
  let start = (n - 1) * CardWidth
  let blank = encodeText([' '], h.encoding)[0]
  let bytes = encodeText(text.toOpenArray(0, min(text.len, CardWidth) - 1), h.encoding)
  for i in 0..<CardWidth:
    h.data[start + i] = if i < bytes.len: bytes[i] else: blank
