## SEG-Y extended textual file header: 3200-byte records after the binary
## header, holding stanzas (spec notes `segy_rev1.md` §3.3,
## `segy_rev2_1.md` §3.3, §6.3). The same layout serves Rev 2 data trailers.
##
## The records are kept raw, so writing them back is byte-identical. Stanzas
## are located as offsets into the concatenated records:
## - a stanza header `((COMPANY:NAME[:CONTENTTYPE][:BYTES]))` starts a record
##   (Rev 2.1) or, in Rev 0/1, any line (an 80-column card or the start after
##   a line feed);
## - a binary stanza (BYTES given) covers exactly that many bytes after its
##   header, and its continuation records are never scanned for `((`;
## - a text stanza runs to the next stanza header.
##
## Records arrive one at a time (`add`), so the same code serves disk files
## and tape, where each record is one tape block. With a count of -1 the
## header ends with the `((SEG:EndText))` record.

import std/strutils
import ./textheader

type
  Stanza* = object
    ## One stanza. Offsets index `ExtendedTextHeader.data`.
    company*: string     ## Organization, e.g. `SEG`, as written (trimmed).
    name*: string        ## Data name, e.g. `Layout` or `Location Data ver 1.0`.
    contentType*: string ## IANA media type, "" if absent.
    byteCount*: int      ## Declared data size of a binary stanza; -1 for text.
    encoding*: TextEncoding ## Character set of the stanza header.
    headerStart*: int    ## Offset of `((`.
    dataStart*: int      ## Offset just after `))`.
    dataEnd*: int        ## Offset after the last data byte (padding included for text).

  ExtendedTextHeader* = object
    ## Extended textual header records and the stanzas found in them.
    data*: seq[byte]       ## All records concatenated; a multiple of 3200 bytes.
    stanzas*: seq[Stanza]
    rev1Lines: bool        ## Look for stanza headers at line starts, not only record starts.
    skipUntil: int         ## Binary stanza data runs to this offset; do not scan before it.
    endText: bool          ## The last record added is an EndText record.

func initExtendedTextHeader*(rev1Lines = false): ExtendedTextHeader =
  ## An empty extended header. `rev1Lines` enables the Rev 0/1 rule that a
  ## stanza may start on any line inside a record.
  ExtendedTextHeader(rev1Lines: rev1Lines)

func recordCount*(h: ExtendedTextHeader): int {.inline.} = h.data.len div TextHeaderSize

func hasEndText*(h: ExtendedTextHeader): bool {.inline.} =
  ## True when the last record added is `((SEG:EndText))`.
  h.endText

func normalizeStanzaName*(s: string): string =
  ## Upper case with spaces removed: the spec's matching rule.
  for c in s:
    if c != ' ': result.add toUpperAscii(c)

func key*(s: Stanza): string =
  ## Normalized `COMPANY:NAME`, e.g. `SEG:ENDTEXT` or `SEG:LOCATIONDATAVER1.0`.
  normalizeStanzaName(s.company & ":" & s.name)

func isEndText*(s: Stanza): bool {.inline.} = s.key == "SEG:ENDTEXT"

func isBinary*(s: Stanza): bool {.inline.} = s.byteCount >= 0

func openParens(b: openArray[byte], pos: int): bool {.inline.} =
  pos + 1 < b.len and ((b[pos] == 0x28 and b[pos+1] == 0x28) or
    (b[pos] == 0x4D and b[pos+1] == 0x4D))

func parseStanzaHeader(b: openArray[byte], pos, limit: int, s: var Stanza): bool =
  # Parses `((...))` at `pos`, searching for `))` before `limit`.
  let enc = if b[pos] == 0x28: teAscii else: teEbcdic
  let close: byte = if enc == teAscii: 0x29 else: 0x5D
  var q = pos + 2
  while q + 1 < limit and not (b[q] == close and b[q+1] == close):
    inc q
  if q + 1 >= limit:
    result = false
  else:
    let inner = decodeText(b.toOpenArray(pos + 2, q - 1), enc)
    let parts = inner.split(':')
    s = Stanza(company: parts[0].strip, encoding: enc, headerStart: pos, dataStart: q + 2,
      byteCount: -1)
    if parts.len > 1: s.name = parts[1].strip
    if parts.len > 2: s.contentType = parts[2].strip
    if parts.len > 3:
      let n = parts[3].strip
      if n.len > 0 and n.allCharsInSet(Digits) and n.len <= 15:
        s.byteCount = parseInt(n)
    result = true

func lineStarts(h: ExtendedTextHeader, recStart: int): seq[int] =
  # Positions in the record at `recStart` where a stanza header may begin.
  result = @[recStart]
  if h.rev1Lines:
    let recEnd = recStart + TextHeaderSize
    for p in recStart + 1..<recEnd:
      let prev = h.data[p-1]
      if (p - recStart) mod CardWidth == 0 or prev == 0x0A or prev == 0x25:
        if result[^1] != p: result.add p

proc add*(h: var ExtendedTextHeader, rec: openArray[byte]) =
  ## Appends one 3200-byte record and finds the stanzas that start in it.
  doAssert rec.len == TextHeaderSize, "extended textual records are 3200 bytes"
  let recStart = h.data.len
  h.data.add rec
  let recEnd = h.data.len
  h.endText = false
  for p in h.lineStarts(recStart):
    var s: Stanza
    if p >= h.skipUntil and openParens(h.data, p) and parseStanzaHeader(h.data, p, recEnd, s):
      if h.stanzas.len > 0 and not h.stanzas[^1].isBinary:
        h.stanzas[^1].dataEnd = p
      if s.isBinary:
        s.dataEnd = s.dataStart + s.byteCount
        h.skipUntil = s.dataEnd
      else:
        s.dataEnd = recEnd
      h.endText = p == recStart and s.isEndText
      h.stanzas.add s
  if h.stanzas.len > 0 and not h.stanzas[^1].isBinary and h.stanzas[^1].headerStart < recStart:
    h.stanzas[^1].dataEnd = recEnd # a text stanza continues through this record

func needsMore*(h: ExtendedTextHeader, count: int): bool =
  ## Whether more records belong to a header whose declared count is `count`
  ## (binary header bytes 3505-3506): exactly `count` records when positive,
  ## up to the EndText record when -1, none when 0 or below -1. Records
  ## inside a binary stanza are never taken for EndText.
  if count > 0: h.recordCount < count
  elif count == -1: not h.hasEndText
  else: false

func stanzaBytes*(h: ExtendedTextHeader, s: Stanza): seq[byte] =
  ## The stanza's data bytes. A binary stanza cut short by the end of the
  ## records yields what is there.
  h.data[s.dataStart..<min(s.dataEnd, h.data.len)]

func stanzaText*(h: ExtendedTextHeader, s: Stanza): string =
  ## The stanza's data decoded with its header's character set, trailing
  ## blanks and NULs removed.
  result = decodeText(h.stanzaBytes(s), s.encoding)
  var n = result.len
  while n > 0 and result[n-1] in {' ', '\0'}: dec n
  result.setLen n

func find*(h: ExtendedTextHeader, key: string): int =
  ## Index of the last stanza whose `key` matches `key` after normalization
  ## (the spec says the last one wins), or -1.
  result = -1
  let k = normalizeStanzaName(key)
  for i, s in h.stanzas:
    if s.key == k: result = i

# ---------------------------------------------------------------------------
# Building (writers).

proc addStanza*(h: var ExtendedTextHeader, company, name: string, data: openArray[byte],
    contentType = "", binary = false, encoding = teAscii) =
  ## Appends a stanza starting on a new record, padded to whole records with
  ## blanks (text) or NULs (binary), per Rev 2.1. A binary stanza declares its
  ## byte count in the header.
  var header = "((" & company & ":" & name
  if contentType.len > 0 or binary: header.add ":" & contentType
  if binary: header.add ":" & $data.len
  header.add "))"
  var rec = encodeText(header, encoding)
  rec.add data
  let pad: byte = if binary: 0 else: encodeText(" ", encoding)[0]
  while rec.len mod TextHeaderSize != 0: rec.add pad
  for i in countup(0, rec.len - 1, TextHeaderSize):
    h.add rec.toOpenArray(i, i + TextHeaderSize - 1)

proc addText*(h: var ExtendedTextHeader, company, name, text: string,
    contentType = "", encoding = teAscii) =
  ## Appends a text stanza.
  h.addStanza(company, name, encodeText(text, encoding), contentType, false, encoding)

proc addEndText*(h: var ExtendedTextHeader, encoding = teAscii) =
  ## Appends the `((SEG:EndText))` record.
  h.addStanza("SEG", "EndText", [], "", false, encoding)
