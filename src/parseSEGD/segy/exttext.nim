## SEG-Y extended textual file header: 3200-byte records after the binary
## header, holding stanzas (spec notes `segy_rev1.md` §3.3,
## `segy_rev2_1.md` §3.3, §6.3, §7.4). The same layout serves Rev 2 data
## trailers.
##
## Records arrive one at a time (`add`), so the same code serves disk files
## and tape, where each record is one tape block. The walker is a streaming
## state machine: positions are offsets in the concatenated record stream,
## and record bytes are kept only up to `maxRetained`. Beyond that, stanzas
## and User Data attachments are still indexed, but their bytes must be read
## from the medium (see `reader.extractUserData`).
##
## Stanza rules:
## - a stanza header `((COMPANY:NAME[:CONTENTTYPE][:BYTES]))` starts a record
##   (Rev 2.1) or, in Rev 0/1, any line (an 80-column card or the start after
##   a line feed);
## - a binary stanza (BYTES given) covers exactly that many bytes after its
##   header, and its continuation records are never scanned for `((`;
## - a User Data stanza (`((SEG:UserData))`, `((SEG:User Data ver 1.0))`,
##   `((SEG:UserHeader))`) is a chain of XML description blocks, each followed
##   by `blocksize` bytes of data, ending with zero padding. The chain is
##   walked by `blocksize`, so attachment bytes are never scanned either;
## - a text stanza runs to the next stanza header.
##
## With a count of -1 the header ends with the `((SEG:EndText))` record.

import std/strutils
import ./textheader

const
  DescOpen = "<segydescblock>"
  DescClose = "</segydescblock>"
  MaxDescBytes = 65536 ## A description block longer than this is treated as corrupt.

type
  Stanza* = object
    ## One stanza. Offsets are positions in the record stream.
    company*: string     ## Organization, e.g. `SEG`, as written (trimmed).
    name*: string        ## Data name, e.g. `Layout` or `Location Data ver 1.0`.
    contentType*: string ## IANA media type, "" if absent.
    byteCount*: int      ## Declared data size of a binary stanza; -1 if not declared.
    encoding*: TextEncoding ## Character set of the stanza header.
    headerStart*: int    ## Offset of `((`.
    dataStart*: int      ## Offset just after `))`.
    dataEnd*: int        ## Offset after the last data byte (padding included for text).

  UserDataBlock* = object
    ## One User Data attachment (D-9): its description and where its bytes are.
    stanza*: int          ## Index of the containing stanza.
    version*: string      ## Description block format version ("1").
    blockSize*: int64     ## Data bytes.
    dataFormat*: string   ## e.g. `text-xml`, `bin-tar`, `bin-le-other`.
    dataLabel*: string    ## e.g. `ObsLog`; unique per creator.
    description*: string
    creationTime*: string ## UTC `YYYY-MM-DD hh:mm:ssZ`.
    creator*: string
    dataVersion*: string  ## Defaults to "1".
    compression*: string  ## e.g. `gzip`; "" or `none` for uncompressed.
    descStart*: int       ## Stream offset of `<segydescblock>`.
    dataStart*: int       ## Stream offset of the first data byte.
    mediumOffset*: int64
      ## File offset of the first data byte when the records were read from a
      ## byte stream (disk); -1 otherwise.

  ExtTextIssue* = object
    ## Something malformed found while walking the records.
    pos*: int    ## Stream offset.
    msg*: string

  ExtendedTextHeader* = object
    ## Extended textual header (or trailer) records, the stanzas and the User
    ## Data attachments found in them.
    data*: seq[byte]
      ## The records, concatenated, as far as retained (see `isComplete`).
    stanzas*: seq[Stanza]
    userData*: seq[UserDataBlock]
    issues*: seq[ExtTextIssue]
    records: int           ## Records added (retained or not).
    maxRetained: int       ## Keep record bytes while `data` stays within this size.
    rev1Lines: bool        ## Look for stanza headers at line starts, not only record starts.
    skipUntil: int         ## Binary data runs to this offset; do not scan before it.
    endText: bool          ## The last record added is an EndText record.
    udActive: bool         ## Inside a User Data chain.
    udLimit: int           ## End of the chain's stanza when BYTES was declared.
    carry: seq[byte]       ## Start of a description block split across records.
    carryStart: int

func initExtendedTextHeader*(rev1Lines = false, maxRetained = high(int)): ExtendedTextHeader =
  ## An empty extended header. `rev1Lines` enables the Rev 0/1 rule that a
  ## stanza may start on any line inside a record. Record bytes are kept while
  ## their total stays within `maxRetained`.
  ExtendedTextHeader(rev1Lines: rev1Lines, maxRetained: maxRetained, udLimit: high(int))

func recordCount*(h: ExtendedTextHeader): int {.inline.} = h.records

func isComplete*(h: ExtendedTextHeader): bool {.inline.} =
  ## True when `data` holds every record (nothing was dropped by `maxRetained`).
  h.data.len == h.records * TextHeaderSize

func hasEndText*(h: ExtendedTextHeader): bool {.inline.} =
  ## True when the last record added is `((SEG:EndText))`.
  h.endText

func streamLen(h: ExtendedTextHeader): int {.inline.} = h.records * TextHeaderSize

func inBinaryStanza*(h: ExtendedTextHeader): bool {.inline.} =
  ## True while binary data (a binary stanza or a User Data block, or a
  ## description block split across records) continues into the next record.
  h.skipUntil > h.streamLen or h.carry.len > 0

func normalizeStanzaName*(s: string): string =
  ## Upper case with spaces removed: the spec's matching rule.
  for c in s:
    if c != ' ': result.add toUpperAscii(c)

func key*(s: Stanza): string =
  ## Normalized `COMPANY:NAME`, e.g. `SEG:ENDTEXT` or `SEG:LOCATIONDATAVER1.0`.
  normalizeStanzaName(s.company & ":" & s.name)

func isEndText*(s: Stanza): bool {.inline.} = s.key == "SEG:ENDTEXT"

func isBinary*(s: Stanza): bool {.inline.} = s.byteCount >= 0

func isUserData*(s: Stanza): bool =
  ## A D-9 User Data stanza (any of the spellings the spec uses).
  let k = s.key
  k.startsWith("SEG:USERDATA") or k.startsWith("SEG:USERHEADER")

func openParens(b: openArray[byte], pos: int): bool {.inline.} =
  pos + 1 < b.len and ((b[pos] == 0x28 and b[pos+1] == 0x28) or
    (b[pos] == 0x4D and b[pos+1] == 0x4D))

func parseStanzaHeader(b: openArray[byte], pos: int, s: var Stanza): bool =
  # Parses `((...))` at index `pos` of `b`; offsets in `s` are indexes in `b`.
  let enc = if b[pos] == 0x28: teAscii else: teEbcdic
  let close: byte = if enc == teAscii: 0x29 else: 0x5D
  var q = pos + 2
  while q + 1 < b.len and not (b[q] == close and b[q+1] == close):
    inc q
  if q + 1 >= b.len:
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

func startsStanza*(rec: openArray[byte]): bool =
  ## True when `rec` begins with a well-formed stanza header `((...))`.
  var s: Stanza
  openParens(rec, 0) and parseStanzaHeader(rec, 0, s)

func skipBlanks(b: openArray[byte], i: int): int =
  result = i
  while result < b.len and b[result] in {0x20'u8, 0x0D, 0x0A, 0x09}: inc result

func matchesAt(b: openArray[byte], i: int, s: string): bool =
  # True if `s` is at index i; partial matches at the end of `b` count too.
  result = true
  for k, c in s:
    if i + k >= b.len: return true
    if b[i + k] != byte(c): return false

func find(b: openArray[byte], s: string, start: int): int =
  result = -1
  var i = start
  while i + s.len <= b.len and result < 0:
    if matchesAt(b, i, s) and i + s.len <= b.len: result = i
    inc i

func continuesUserData*(h: ExtendedTextHeader, rec: openArray[byte]): bool =
  ## True when `rec` would continue an open User Data chain (it starts with a
  ## description block).
  if not h.udActive:
    result = false
  else:
    let i = skipBlanks(rec, 0)
    result = i < rec.len and matchesAt(rec, i, DescOpen)

func startsStanzaRecord*(rec: openArray[byte]): bool =
  ## True when `rec` plausibly is the first record of a stanza: a well-formed
  ## stanza header followed by text, by a User Data description block, or
  ## declaring a binary byte count. Used to tell trailer records from trace
  ## data, whose first bytes may look like `((` by chance.
  var s: Stanza
  if not (openParens(rec, 0) and parseStanzaHeader(rec, 0, s)):
    result = false
  elif s.isUserData:
    let i = skipBlanks(rec, s.dataStart)
    result = i < rec.len and matchesAt(rec, i, DescOpen) and
      find(rec, "<blocksize>", i) > 0
  else:
    result = s.isBinary or looksLikeText(rec)

func tagValue(xml, tag: string): string =
  let a = xml.find("<" & tag & ">")
  let b = xml.find("</" & tag & ">")
  if a >= 0 and b > a: xml[a + tag.len + 2 ..< b].strip else: ""

func parseDesc(xml: string, b: var UserDataBlock): string =
  # Fills `b` from a description block; returns an error message or "".
  b.version = tagValue(xml, "version")
  b.dataFormat = tagValue(xml, "dataformat")
  b.dataLabel = tagValue(xml, "datalabel")
  b.description = tagValue(xml, "description")
  b.creationTime = tagValue(xml, "creationtime")
  b.creator = tagValue(xml, "creator")
  b.dataVersion = tagValue(xml, "dataversion")
  if b.dataVersion.len == 0: b.dataVersion = "1"
  b.compression = tagValue(xml, "compression")
  let size = tagValue(xml, "blocksize")
  if size.len == 0 or size.len > 18 or not size.allCharsInSet(Digits):
    result = "description block has no valid <blocksize> (" & size & ")"
  else:
    b.blockSize = parseBiggestInt(size)
    result = ""

proc endChain(h: var ExtendedTextHeader, pos: int) =
  h.udActive = false
  h.carry.setLen 0
  if h.stanzas.len > 0: h.stanzas[^1].dataEnd = max(h.stanzas[^1].dataEnd, pos)
  if h.udLimit != high(int):
    h.skipUntil = max(h.skipUntil, h.udLimit)
    h.udLimit = high(int)

proc walkChain(h: var ExtendedTextHeader, rec: openArray[byte], s0, p: int,
    recOffset: int64): int =
  # Continues a User Data chain at stream offset p inside the record starting
  # at stream offset s0. Returns where scanning stops: the end of the record,
  # or the start of a data block (which the caller skips).
  let e = s0 + rec.len
  # Work on carry & rec when a description block is split across records.
  var buf: seq[byte]
  var base = s0
  if h.carry.len > 0:
    buf = h.carry
    buf.add rec
    base = h.carryStart
  else:
    buf = @rec
  var q = if h.carry.len > 0: 0 else: skipBlanks(buf, p - base)
  if base + q >= e:
    return e
  if base + q >= h.udLimit or buf[q] == 0:
    h.endChain(base + q) # zero padding (or the declared stanza end): the chain is over
    return e
  if not matchesAt(buf, q, DescOpen):
    h.issues.add ExtTextIssue(pos: base + q,
      msg: "User Data: expected <segydescblock>; the rest of the stanza is not indexed")
    h.endChain(base + q)
    return e
  let close = find(buf, DescClose, q)
  if close < 0:
    if buf.len - q > MaxDescBytes:
      h.issues.add ExtTextIssue(pos: base + q, msg: "User Data: description block exceeds " &
        $MaxDescBytes & " bytes without </segydescblock>")
      h.endChain(base + q)
    else:
      h.carry = buf[q..^1]
      h.carryStart = base + q
    return e
  h.carry.setLen 0
  var xml = newString(close + DescClose.len - q)
  for i in 0..<xml.len: xml[i] = char(buf[q + i])
  var b = UserDataBlock(stanza: h.stanzas.len - 1, descStart: base + q,
    dataStart: base + close + DescClose.len, mediumOffset: -1)
  let err = parseDesc(xml, b)
  if err.len > 0:
    h.issues.add ExtTextIssue(pos: base + q, msg: "User Data: " & err &
      "; the rest of the stanza is not indexed")
    h.endChain(base + q)
    return e
  if recOffset >= 0: b.mediumOffset = recOffset + int64(b.dataStart - s0)
  h.skipUntil = b.dataStart + int(b.blockSize)
  h.stanzas[^1].dataEnd = h.skipUntil
  h.userData.add b
  result = b.dataStart

func lineStarts(h: ExtendedTextHeader, rec: openArray[byte]): seq[int] =
  # Indexes in `rec` where a stanza header may begin.
  result = @[0]
  if h.rev1Lines:
    for p in 1..<rec.len:
      let prev = rec[p-1]
      if p mod CardWidth == 0 or prev == 0x0A or prev == 0x25:
        if result[^1] != p: result.add p

proc add*(h: var ExtendedTextHeader, rec: openArray[byte], recOffset: int64 = -1) =
  ## Appends one 3200-byte record and indexes the stanzas and User Data
  ## blocks that start in it. `recOffset` is the record's file offset when
  ## reading a byte stream (disk), used for `UserDataBlock.mediumOffset`.
  doAssert rec.len == TextHeaderSize, "extended textual records are 3200 bytes"
  let s0 = h.streamLen
  let e = s0 + TextHeaderSize
  if h.isComplete and h.data.len + TextHeaderSize <= h.maxRetained:
    h.data.add rec
  inc h.records
  h.endText = false
  var p = s0
  var starts = h.lineStarts(rec)
  var si = 0
  while p < e:
    if h.skipUntil > p:
      p = min(h.skipUntil, e)
    elif h.udActive and not (p == s0 and h.carry.len == 0 and startsStanza(rec)):
      p = h.walkChain(rec, s0, p, recOffset)
    else:
      if h.udActive: h.endChain(p) # a new stanza starts this record
      # Find the next stanza header at a line start at or after p.
      while si < starts.len and s0 + starts[si] < p: inc si
      var s: Stanza
      var found = false
      while si < starts.len and not found:
        let q = starts[si]
        inc si
        if openParens(rec, q) and parseStanzaHeader(rec, q, s): found = true
      if not found:
        p = e
      else:
        s.headerStart += s0
        s.dataStart += s0
        if h.stanzas.len > 0 and not h.stanzas[^1].isBinary and not h.stanzas[^1].isUserData:
          h.stanzas[^1].dataEnd = s.headerStart
        h.endText = s.headerStart == s0 and s.isEndText
        if s.isUserData:
          s.dataEnd = s.dataStart
          h.udActive = true
          h.udLimit = if s.isBinary: s.dataStart + s.byteCount else: high(int)
        elif s.isBinary:
          s.dataEnd = s.dataStart + s.byteCount
          h.skipUntil = s.dataEnd
        else:
          s.dataEnd = e
        h.stanzas.add s
        p = s.dataStart
  # A text stanza that started earlier continues through this record.
  if h.stanzas.len > 0:
    if not h.stanzas[^1].isBinary and not h.stanzas[^1].isUserData and
        h.stanzas[^1].headerStart < s0:
      h.stanzas[^1].dataEnd = e

func needsMore*(h: ExtendedTextHeader, count: int): bool =
  ## Whether more records belong to a header whose declared count is `count`
  ## (binary header bytes 3505-3506): exactly `count` records when positive,
  ## up to the EndText record when -1, none when 0 or below -1. Records
  ## inside binary data are never taken for EndText.
  if count > 0: h.recordCount < count
  elif count == -1: not h.hasEndText
  else: false

func stanzaBytes*(h: ExtendedTextHeader, s: Stanza): seq[byte] =
  ## The stanza's data bytes, as far as retained.
  h.data[min(s.dataStart, h.data.len) ..< min(s.dataEnd, h.data.len)]

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

func isRetained*(h: ExtendedTextHeader, b: UserDataBlock): bool =
  ## True when the attachment's bytes are all in `data`.
  b.dataStart + int(b.blockSize) <= h.data.len

func userDataBytes*(h: ExtendedTextHeader, b: UserDataBlock): seq[byte] =
  ## The attachment's bytes from memory. Raises `ValueError` if they were
  ## not retained (use `reader.extractUserData` on the file instead).
  if not h.isRetained(b):
    raise newException(ValueError, "User Data block '" & b.dataLabel &
      "' is not held in memory; extract it from the file")
  h.data[b.dataStart ..< b.dataStart + int(b.blockSize)]

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

func toDescXml*(b: UserDataBlock): string =
  ## The description block for `b` (single-level XML, ASCII, lower-case tags).
  template tag(name, value: string) =
    if value.len > 0: result.add "  <" & name & ">" & value & "</" & name & ">\n"
  result = DescOpen & "\n"
  tag("version", if b.version.len > 0: b.version else: "1")
  tag("blocksize", $b.blockSize)
  tag("dataformat", b.dataFormat)
  tag("datalabel", b.dataLabel)
  tag("description", b.description)
  tag("creationtime", b.creationTime)
  tag("creator", b.creator)
  tag("dataversion", b.dataVersion)
  tag("compression", b.compression)
  result.add DescClose

proc addUserData*(h: var ExtendedTextHeader, items: openArray[(UserDataBlock, seq[byte])],
    stanzaName = "UserData") =
  ## Appends a User Data stanza holding `items` (description, data). Each
  ## `blockSize` is set from its data. The stanza starts on a new record and
  ## the last record is padded with zeros.
  var rec = encodeText("((SEG:" & stanzaName & "))", teAscii)
  for (desc, data) in items:
    var d = desc
    d.blockSize = data.len
    rec.add encodeText(toDescXml(d), teAscii)
    rec.add data
  while rec.len mod TextHeaderSize != 0: rec.add 0
  for i in countup(0, rec.len - 1, TextHeaderSize):
    h.add rec.toOpenArray(i, i + TextHeaderSize - 1)
