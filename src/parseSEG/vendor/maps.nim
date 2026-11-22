## Vendor maps: declarative NIF descriptions of vendor-specific header areas,
## loaded at runtime (design: `docs/design/vendor_maps.md`).
##
## ```
## (.nif27)
## (vendormap "acme-extended" (version 1)
##   (match (format segd) (rev 2.0 2.1) (manufacturer 13))
##   (doc "ACME record info in the SEG-D extended header")
##   (target (kind extendedHeader) (blockIndex 1) (name acmeRecordInfo)
##     (field crewName (at 1) (len 16) (enc ascii) (trim right))
##     (field status (at 17) (enc u8) (bits (0 clipped) (1 dead)))
##     (field unitSn (at 18) (len 4 n) (enc bcd))
##     (field tilt (at 20) (enc i16) (scale 0.01) (unit "deg"))
##     (repeat (count (ref nChannels)) (stride 8) (at 33)
##       (field chanId (at 1) (enc u32)) (field gain (at 5) (enc f32)))))
## ```
##
## - Offsets are 1-based within the target, like the spec tables. `(len 4 n)`
##   is a length in nibbles; `(nibble low)` starts a field at the low nibble.
##   Hex numbers may be written `0xB0` or `"0xB0"`; `(len 4n)` = `(len 4 n)`.
##   `;` starts a comment. Maps are limited to 1 MB, nesting depth 64 and
##   offsets/lengths/counts of 1,000,000.
## - Encodings: `u8 u16 u24 u32 u64 i8 i16 i24 i32 i64 f32 f64 ibm32 bcd
##   fixedpt ascii ebcdic raw unibble inibble` (`fixedpt` = `i24.u16`, 5 bytes;
##   `unibble`/`inibble` = unsigned/signed binary of `(len N n)` nibbles, 1..16,
##   from the high or the `(nibble low)` nibble: 4-bit and 12-bit fields).
## - Per field: `byteOrder` (big/little; default: the file's), `scale`,
##   `offset`, `unit`, `enum`, `bits`, `sentinel` (a raw value meaning "absent"),
##   `trim` (left/right/both, text).
## - `repeat` decodes a group `count` times (a number or `(ref field)`), at
##   `at + i * stride`; its fields are named `name[i]`.
##
## - `(match (at N) (bytes b...))` in a target: the block must hold those
##   bytes. Without `blockIndex` the target applies to every block of its area
##   (32-byte blocks of the SEG-D extended and external header, each general
##   header block and trace header extension) that holds them, wherever it
##   sits; each such target gives a `VendorBlock` of its own (`decodeAll`).
## - `(when <source> <test>)` on a field, and `(group (when ...) (field ...)...)`
##   for several: the field is decoded only if the source has the value;
##   otherwise it is absent, without a diagnostic. Source: `(field earlier)`,
##   `(byte N)`, `(highNibble N)`, `(lowNibble N)`, or the same byte in a block
##   of the record's extended/external/general headers,
##   `(record <area> (match ...) (byte N))`. Test: `(is v)`, `(in v...)`,
##   `(range lo hi)`. A field whose own conditions failed is absent for the
##   conditions that name it.
## - `(layout (entry name (at N) (type int4) (divisor D)) ...)`: SEG-Y trace
##   header entries that go over the file's layout when the map applies
##   (`vendorLayout`, `OpenOptions.vendors`); `divisor`: the stored number is D
##   times the value. A map with a layout needs no target.
## - In the map's `(match ...)`: `(hasBlock <area> (match ...))` requires such a
##   block in `extendedHeader`, `externalHeader` or `generalHeader`; each counts
##   one in the specificity.
##
## Loading compiles each map into flat field plans, so decoding is a loop
## over precomputed offsets. Nothing here is fatal: malformed maps and fields
## that do not fit the data become diagnostics, and raw bytes are always kept
## by the format readers.

import std/[strutils, os, math, options]
import ../common/[endians, ibmfloat, ebcdic, bcd, diagnostics, seismickind]
import ../segy/layout
import ../private/sharedfile
export diagnostics, endians, options, seismickind

type
  VendorTargetKind* = enum
    ## Where vendor data lives (design table "What a map can target").
    vtExtendedHeader = "extendedHeader"   ## SEG-D extended header (whole area or a block).
    vtExternalHeader = "externalHeader"   ## SEG-D external header.
    vtGeneralHeader = "generalHeader"     ## SEG-D GH#N, N ≥ 3, non-standard.
    vtBlock = "block"                     ## SEG-D 3.x 32-byte block by type byte.
    vtTraceExt = "traceExt"               ## SEG-D trace header extension #k, k ≥ 2.
    vtTrailer = "trailer"                 ## SEG-D general trailer blocks.
    vtBinaryHeaderBytes = "binaryHeaderBytes" ## SEG-Y unassigned binary header bytes.
    vtTraceHeaderBytes = "traceHeaderBytes"   ## SEG-Y unassigned trace header bytes.
    vtTraceHeaderBlock = "traceHeaderBlock"   ## SEG-Y proprietary 240-byte trace header.
    vtStanza = "stanza"                   ## SEG-Y extended text / trailer stanza.

  VendorEncoding* = enum
    ## How a field's bytes are encoded (`(enc ...)`).
    veU8 = "u8", veU16 = "u16", veU24 = "u24", veU32 = "u32", veU64 = "u64",
    veI8 = "i8", veI16 = "i16", veI24 = "i24", veI32 = "i32", veI64 = "i64",
    veF32 = "f32", veF64 = "f64", veIbm32 = "ibm32", veBcd = "bcd", veFixedPt = "fixedpt",
    veAscii = "ascii", veEbcdic = "ebcdic", veRaw = "raw",
    veUNib = "unibble", veINib = "inibble"
      ## `unibble` / `inibble`: an unsigned / signed binary number of `(len N n)`
      ## nibbles (1..16), from the high or `(nibble low)` nibble of the byte.

  VendorTrim* = enum
    ## Which blanks a text field drops (`(trim ...)`).
    trimNone = "none", trimLeft = "left", trimRight = "right", trimBoth = "both"

  VendorEnumLabel* = object
    ## One `(enum ...)` entry: the label of a raw value.
    value*: int64
    label*: string

  VendorBitFlag* = object
    ## One `(bits ...)` entry: the name of a bit (0 = least significant).
    bit*: int
    name*: string

  VendorBytesMatch* = object
    ## A compiled `(match (at N) (bytes b...))`: the block must hold `bytes` from
    ## `byteOff`. A block too short for it does not match.
    byteOff*: int ## 0-based offset within the block.
    bytes*: seq[byte]

  VendorCondSource* = enum
    ## What a `(when ...)` condition reads.
    csField ## The raw value of an earlier field of the same target.
    csByte ## A raw byte of the block.
    csHighNibble ## The high nibble of a raw byte.
    csLowNibble ## The low nibble of a raw byte.

  VendorCondition* = object
    ## A compiled `(when <source> <test>)`. Several conditions on a field all
    ## have to hold; a field whose condition fails is absent, without a diagnostic.
    source*: VendorCondSource
    fieldName*: string ## `csField`: the field read.
    fieldIndex*: int ## `csField`: its index in the target's `fields`.
    byteOff*: int ## Other sources: 0-based byte offset.
    recordArea*: Option[VendorTargetKind] ## Some: read the byte in the first block of
                             ## this record-level area (see `VendorContext`) holding `recordMatch`.
    recordMatch*: seq[VendorBytesMatch]
    isRange*: bool ## `(range lo hi)`; otherwise `(is v)` or `(in v...)` in `values`.
    values*: seq[int64]
    lo*, hi*: int64
    line*: int ## Line in the map, for messages.

  VendorFieldPlan* = object
    ## A compiled field.
    name*: string
    byteOff*: int       ## 0-based byte offset within the target (or repeat element).
    lowNibble*: bool    ## Starts at the low nibble of `byteOff`.
    len*: int           ## Bytes (nibbles for `bcd` given in nibbles; see `nibbles`).
    nibbles*: int       ## Length in nibbles (2 per byte for byte-sized fields).
    enc*: VendorEncoding
    order*: Option[ByteOrder] ## The field's own byte order; none: the file's.
    scale*, offset*: float64 ## Value = raw × scale + offset, when `scaled`.
    scaled*: bool
    unit*: string
    enums*: seq[VendorEnumLabel]
    bits*: seq[VendorBitFlag]
    sentinel*: Option[int64] ## A raw value meaning "absent".
    trim*: VendorTrim   ## Text fields only.
    conds*: seq[VendorCondition] ## `(when ...)` (own and of enclosing `(group)`s); all must hold.

  VendorRepeatPlan* = object
    ## A compiled `(repeat ...)` group.
    count*: int          ## Fixed count, or -1 when `countRef` names a field.
    countRef*: string    ## The field holding the count, or "".
    stride*: int         ## Bytes per element.
    byteOff*: int        ## 0-based offset of element 0.
    fields*: seq[VendorFieldPlan] ## Offsets within an element.

  VendorTarget* = object
    ## A compiled `(target ...)`: where the data is and its fields.
    kind*: VendorTargetKind
    name*: string        ## Name of the decoded block.
    blockIndex*: int     ## 1-based block within the area; -1 (omitted) = the whole area.
    blockType*: int      ## SEG-D 3.x block type byte; -1 = any.
    where*: string       ## e.g. `traceHeader`, `generalHeader`; "" = any.
    headerName*: string  ## SEG-Y proprietary trace header name; "" = any.
    stanza*: string      ## SEG-Y stanza `COMPANY:NAME`; "" = any.
    extIndex*: int       ## SEG-D trace header extension number k; -1 = any.
    fields*: seq[VendorFieldPlan]
    repeats*: seq[VendorRepeatPlan]
    matches*: seq[VendorBytesMatch] ## `(match ...)`: with no `blockIndex`, every block of the
                         ## area whose bytes hold all of these; with one, that block if it does.

  VendorRevision* = object
    ## A revision as major.minor (minor 10 is not 1.0 more than 9).
    major*, minor*: int

  VendorRevisionRange* = object
    ## Revisions `first .. last`, both included.
    first*, last*: VendorRevision

  VendorBlockMatch* = object
    ## A map-level `(hasBlock <area> (match ...)...)`: some block of a record-level
    ## area holds all the byte runs.
    area*: VendorTargetKind ## `vtExtendedHeader`, `vtExternalHeader` or `vtGeneralHeader`.
    matches*: seq[VendorBytesMatch]

  VendorMatch* = object
    ## A map's `(match ...)`: the files it applies to.
    format*: Option[SeismicKind] ## `skSegd` or `skSegy`; none = any.
    revisions*: Option[VendorRevisionRange] ## The `(rev min [max])` clause; none = any.
    manufacturers*: seq[int] ## SEG-D manufacturer codes; empty = any.
    serialMin*, serialMax*: int64 ## -1 = unbounded.
    textContains*: seq[string] ## Texts the SEG-Y textual header must hold.
    blocks*: seq[VendorBlockMatch] ## `hasBlock` clauses; each counts one in the specificity.

  VendorMap* = object
    ## A loaded vendor map.
    name*: string
    version*: int
    doc*: string
    source*: string      ## File the map was loaded from.
    match*: VendorMatch
    targets*: seq[VendorTarget]
    layout*: seq[LayoutEntry]
      ## The map's `(layout ...)`: SEG-Y trace header entries that go over the file's own
      ## layout (`vendorLayout`), so the keys and `fieldValue` read them.

  VendorContext* = object
    ## Facts about a file that maps are matched against.
    format*: SeismicKind ## `skSegd` or `skSegy`.
    revision*: VendorRevision ## e.g. 2.1.
    manufacturer*: int   ## SEG-D GH#1 manufacturer code; -1 if unknown.
    serial*: int64       ## Manufacturer serial number; -1 if unknown.
    text*: string        ## SEG-Y textual header (for `textContains`).
    byteOrder*: ByteOrder ## The file's byte order (default for fields).
    extended*: seq[byte] ## SEG-D extended header, whole 32-byte blocks (for `hasBlock`).
    external*: seq[byte] ## SEG-D external header, whole 32-byte blocks.
    general*: seq[byte]  ## SEG-D general header blocks after GH#2, 32 bytes each.

  VendorArea* = object
    ## A vendor area handed to `decode`.
    kind*: VendorTargetKind
    blockIndex*: int     ## 1-based block within the area, -1 for the whole area.
    blockType*: int      ## SEG-D 3.x block type byte, -1 if none.
    where*: string       ## SEG-D 3.x: `generalHeader` or `traceHeader`.
    headerName*: string  ## SEG-Y proprietary trace header name.
    stanza*: string      ## SEG-Y stanza `COMPANY:NAME`.
    extIndex*: int       ## SEG-D trace header extension number k, -1 if none.

  VendorValueKind* = enum
    ## The kind of a decoded value.
    vvInt, vvFloat, vvText, vvBytes

  VendorValue* = object
    ## A decoded field value.
    case kind*: VendorValueKind
    of vvInt: intVal*: int64
    of vvFloat: floatVal*: float64
    of vvText: text*: string
    of vvBytes: bytes*: seq[byte]
    unit*: string
    label*: string        ## Enum label, if the value has one.
    flags*: seq[string]   ## Names of set bits, for `bits` fields.

  VendorField* = object
    ## One decoded field of a `VendorBlock`.
    name*: string        ## The field's name (`name[i]` inside a repeat).
    value*: VendorValue

  VendorBlock* = object
    ## Decoded vendor data, beside the raw bytes the readers keep.
    mapName*: string     ## The map (or code decoder) that decoded it.
    name*: string        ## The target's name.
    blockNumber*: int = -1 ## The block it was decoded from: its 1-based number in the area
                         ## (general header: GH#N), or the trace header extension number;
                         ## -1 for a whole area or a block with no number.
    fields*: seq[VendorField]

  VendorDecoder* = proc (bytes: openArray[byte], area: VendorArea,
    ctx: VendorContext): Option[VendorBlock] {.nimcall, raises: [CatchableError].}
    ## A code decoder: the decoded block (its `mapName` is set to the name
    ## the decoder was registered under), or none if it does not handle these
    ## bytes.

  CodeDecoder = object
    manufacturer: int    ## -1 = any.
    kind: VendorTargetKind
    name: string
    decoder: VendorDecoder

  VendorRegistry* = object
    ## Loaded maps and registered code decoders.
    maps*: seq[VendorMap]
    decoders: seq[CodeDecoder]

# ------------------------------------------------------------- NIF trees --
# Vendor maps are untrusted input, so they are read by a small dedicated
# tokenizer for the NIF subset they use, not by the toolchain's NIF reader
# (which can quit or assert on some tokens). It is iterative (no recursion),
# bounds nesting, size and numbers, and only ever raises ValueError.

const
  VendorBlockSize* = 32  ## Bytes of a block that a content `match` is tried on (SEG-D).
  MaxMatchBytes = 64     ## Longest `(bytes ...)` list.
  MaxMatchesPerTarget = 16
  MaxCondValues = 256    ## Longest `(in ...)` list.
  MaxCondsPerField = 16  ## `(when)` clauses on a field, its own and those of its groups.
  MaxCondsPerMap = 65_536 ## `(when)` clauses stored in a map, over all fields.
  MaxMapBytes = 1 shl 20 ## Larger map files are refused.
  MaxDepth = 64          ## Deeper nesting is refused.
  MaxOffset = 1_000_000  ## Bound for offsets, lengths, counts and strides.

type
  NKind = enum nkTree, nkInt, nkFloat, nkIdent, nkStr
  NNode = object
    kind: NKind
    tag: string
    kids: seq[NNode]
    i: int64
    f: float64
    s: string  ## Identifier or string value; for numbers, the token as written.
    line: int

proc mapError(msg: string, line = 0) {.noinline, noreturn.} =
  raise newException(ValueError, (if line > 0: "line " & $line & ": " else: "") & msg)

proc parseNumber(tok: string, line: int, n: var NNode): bool =
  # Integer (decimal, optional sign, optional NIF `u` suffix), hex `0x...`, or
  # float. False if `tok` is not a number.
  var t = tok
  if t.len > 1 and t[^1] == 'u' and t[0 ..< ^1].allCharsInSet(Digits): t.setLen t.len - 1
  let body = if t.len > 0 and t[0] in {'-', '+'}: t[1..^1] else: t
  if body.len == 0 or body[0] notin Digits:
    return false
  if body.len > 2 and body[0] == '0' and body[1] in {'x', 'X'}:
    let h = body[2..^1]
    if h.len == 0 or h.len > 16 or not h.allCharsInSet(HexDigits):
      mapError("bad hex number " & tok, line)
    let u = fromHex[uint64](h)
    if u > uint64(high(int64)): mapError("number " & tok & " is out of range", line)
    n = NNode(kind: nkInt, i: (if t[0] == '-': -int64(u) else: int64(u)), s: tok, line: line)
    return true
  if body.allCharsInSet(Digits):
    try:
      n = NNode(kind: nkInt, i: parseBiggestInt(t), s: tok, line: line)
    except ValueError:
      mapError("number " & tok & " is out of range", line)
    return true
  try:
    n = NNode(kind: nkFloat, f: parseFloat(t), s: tok, line: line)
  except ValueError:
    return false
  result = true

proc parseNif(src: string): seq[NNode] =
  if src.len > MaxMapBytes: mapError("map file exceeds " & $MaxMapBytes & " bytes")
  var stack: seq[NNode]
  var i = 0
  var line = 1
  const Delims = {' ', '\t', '\r', '\n', '(', ')', '"', ';'}
  proc addNode(stack: var seq[NNode], roots: var seq[NNode], n: sink NNode) =
    if stack.len > 0: stack[^1].kids.add n
    elif n.kind == nkTree: roots.add n
  while i < src.len:
    let c = src[i]
    case c
    of '\n':
      inc line
      inc i
    of ' ', '\t', '\r':
      inc i
    of ';':
      while i < src.len and src[i] != '\n': inc i
    of '(':
      inc i
      var tag = ""
      while i < src.len and src[i] notin Delims:
        tag.add src[i]
        inc i
      if tag.len == 0: mapError("'(' without a tag", line)
      if stack.len >= MaxDepth: mapError("nesting deeper than " & $MaxDepth, line)
      stack.add NNode(kind: nkTree, tag: tag, line: line)
    of ')':
      inc i
      if stack.len == 0: mapError("unbalanced ')'", line)
      let n = stack.pop
      addNode(stack, result, n)
    of '"':
      inc i
      var str = ""
      var closed = false
      while i < src.len and not closed:
        let d = src[i]
        if d == '"':
          closed = true
        elif d == '\\' and i + 1 < src.len:
          let e = src[i + 1]
          if e in {'"', '\\'}:
            str.add e
            inc i
          elif i + 2 < src.len and e in HexDigits and src[i + 2] in HexDigits:
            str.add char(fromHex[int](src[i + 1 .. i + 2]))
            i += 2
          else:
            str.add d
        else:
          if d == '\n': inc line
          str.add d
        inc i
      if not closed: mapError("unterminated string", line)
      addNode(stack, result, NNode(kind: nkStr, s: str, line: line))
    else:
      var tok = ""
      while i < src.len and src[i] notin Delims:
        tok.add src[i]
        inc i
      var n: NNode
      if parseNumber(tok, line, n):
        addNode(stack, result, n)
      elif tok.len > 1 and tok[^1] == 'n' and tok[0 ..< ^1].allCharsInSet(Digits) and
          parseNumber(tok[0 ..< ^1], line, n):
        # `4n`: a length in nibbles.
        addNode(stack, result, n)
        addNode(stack, result, NNode(kind: nkIdent, s: "n", line: line))
      else:
        addNode(stack, result, NNode(kind: nkIdent, s: tok, line: line))
  if stack.len > 0: mapError("unbalanced parentheses: " & $stack.len & " not closed", line)

func atoms(n: NNode): seq[NNode] =
  for k in n.kids:
    if k.kind != nkTree: result.add k

iterator trees(n: NNode): lent NNode =
  # The tree children of `n` (its clauses).
  for k in n.kids:
    if k.kind == nkTree: yield k

func child(n: NNode, tag: string): int =
  result = -1
  for i, k in n.kids:
    if k.kind == nkTree and k.tag == tag: return i

proc intAtoms(n: NNode): seq[int64] =
  ## The integers among a tree's atoms (a string "0xB0" counts too).
  for a in n.atoms:
    var x = a
    if a.kind in {nkStr, nkIdent}:
      var p: NNode
      if parseNumber(a.s, a.line, p) and p.kind == nkInt: x = p
    if x.kind == nkInt: result.add x.i

proc intAtom(n: NNode, i = 0): int64 =
  ## The i-th integer of a tree's atoms.
  let ints = n.intAtoms
  if i >= ints.len: mapError("(" & n.tag & ") needs an integer", n.line)
  ints[i]

proc boundedAtom(n: NNode, lo: int64, i = 0): int =
  let v = n.intAtom(i)
  if v < lo or v > MaxOffset:
    mapError("(" & n.tag & ") must be " & $lo & ".." & $MaxOffset, n.line)
  int(v)

proc tagInt(n: NNode): int64 =
  # A number written as a tag, e.g. the `0xB0` of `(0xB0 "status")`.
  var p: NNode
  if parseNumber(n.tag, n.line, p) and p.kind == nkInt: p.i
  else: mapError("expected a number, not (" & n.tag, n.line)

proc floatAtom(n: NNode, i = 0): float64 =
  var k = 0
  for a in n.atoms:
    if a.kind in {nkInt, nkFloat}:
      if k == i: return (if a.kind == nkInt: float64(a.i) else: a.f)
      inc k
  mapError("(" & n.tag & ") needs a number", n.line)

proc revAtom(n: NNode, i: int, rev: var VendorRevision): bool =
  # The i-th revision `major.minor` as written (so 2.10 is minor 10).
  var k = 0
  for a in n.atoms:
    if a.kind in {nkInt, nkFloat, nkStr, nkIdent}:
      if k == i:
        let parts = a.s.split('.')
        try:
          rev = VendorRevision(major: parseInt(parts[0]),
            minor: (if parts.len > 1: parseInt(parts[1]) else: 0))
        except ValueError:
          mapError("bad revision " & a.s, n.line)
        return true
      inc k
  false

proc textAtom(n: NNode): string =
  for a in n.atoms:
    if a.kind in {nkIdent, nkStr}: return a.s
  mapError("(" & n.tag & ") needs a name or string", n.line)

# ---------------------------------------------------------------- compile --

func encWidth(e: VendorEncoding): int =
  case e
  of veU8, veI8: 1
  of veU16, veI16: 2
  of veU24, veI24: 3
  of veU32, veI32, veF32, veIbm32: 4
  of veU64, veI64, veF64: 8
  of veFixedPt: 5
  of veBcd, veAscii, veEbcdic, veRaw, veUNib, veINib: 0

proc seismicKindAtom(n: NNode): SeismicKind =
  # `(format segd)` or `(format segy)`.
  case n.textAtom.toLowerAscii
  of "segd": skSegd
  of "segy": skSegy
  else: mapError("(format) is segd or segy, not " & n.textAtom, n.line)

proc compileBytesMatch(n: NNode): VendorBytesMatch =
  # `(match (at N) (bytes b...))`.
  var atSeen, bytesSeen = false
  for k in n.trees:
    case k.tag
    of "at":
      if atSeen: mapError("(match) has two (at)", k.line)
      result.byteOff = k.boundedAtom(1) - 1
      atSeen = true
    of "bytes":
      if bytesSeen: mapError("(match) has two (bytes)", k.line)
      let vals = k.intAtoms
      if vals.len != k.atoms.len or vals.len == 0:
        mapError("(bytes) needs byte values 0..255", k.line)
      if vals.len > MaxMatchBytes:
        mapError("(bytes) holds at most " & $MaxMatchBytes & " values", k.line)
      for v in vals:
        if v < 0 or v > 255: mapError("(bytes) values are 0..255, not " & $v, k.line)
        result.bytes.add byte(v)
      bytesSeen = true
    else: mapError("unknown (match) attribute (" & k.tag & ")", k.line)
  if not atSeen: mapError("(match) has no (at)", n.line)
  if not bytesSeen: mapError("(match) has no (bytes)", n.line)

proc blockAreaAtom(n: NNode): VendorTargetKind =
  # The record-level area named by `hasBlock` and `record`.
  try: result = parseEnum[VendorTargetKind](n.textAtom)
  except ValueError: mapError("unknown area " & n.textAtom, n.line)
  if result notin {vtExtendedHeader, vtExternalHeader, vtGeneralHeader}:
    mapError("(" & n.tag & ") names extendedHeader, externalHeader or generalHeader", n.line)

proc compileCond(n: NNode): VendorCondition =
  # `(when <source> <test>)`, source: (field name), (byte N), (highNibble N),
  # (lowNibble N) or (record <area> (match ...) (byte N)); test: (is v),
  # (in v...) or (range lo hi).
  result = VendorCondition(fieldIndex: -1, line: n.line)
  var sourceSeen, testSeen = false
  proc setSource(k: NNode, c: var VendorCondition) =
    case k.tag
    of "byte": c.source = csByte
    of "highNibble": c.source = csHighNibble
    else: c.source = csLowNibble
    c.byteOff = k.boundedAtom(1) - 1
  for k in n.trees:
    case k.tag
    of "field", "byte", "highNibble", "lowNibble", "record":
      if sourceSeen: mapError("(when) has two sources", k.line)
      sourceSeen = true
      case k.tag
      of "field":
        result.source = csField
        result.fieldName = k.textAtom
      of "record":
        result.recordArea = some(k.blockAreaAtom)
        var readSeen = false
        for r in k.trees:
          case r.tag
          of "match":
            if result.recordMatch.len >= MaxMatchesPerTarget: mapError("too many (match)", r.line)
            result.recordMatch.add compileBytesMatch(r)
          of "byte", "highNibble", "lowNibble":
            if readSeen: mapError("(record) reads one byte", r.line)
            readSeen = true
            setSource(r, result)
          else: mapError("unknown (record) attribute (" & r.tag & ")", r.line)
        if result.recordMatch.len == 0: mapError("(record) needs a (match)", k.line)
        if not readSeen: mapError("(record) needs (byte N), (highNibble N) or (lowNibble N)", k.line)
      else: setSource(k, result)
    of "is", "in", "range":
      if testSeen: mapError("(when) has two tests", k.line)
      testSeen = true
      let vals = k.intAtoms
      if vals.len != k.atoms.len: mapError("(" & k.tag & ") takes integers", k.line)
      case k.tag
      of "is":
        if vals.len != 1: mapError("(is) takes one value", k.line)
        result.values = vals
      of "in":
        if vals.len == 0 or vals.len > MaxCondValues:
          mapError("(in) takes 1.." & $MaxCondValues & " values", k.line)
        result.values = vals
      else:
        if vals.len != 2 or vals[0] > vals[1]: mapError("(range) takes lo hi, lo <= hi", k.line)
        result.isRange = true
        result.lo = vals[0]
        result.hi = vals[1]
    else: mapError("unknown (when) attribute (" & k.tag & ")", k.line)
  if not sourceSeen: mapError("(when) needs (field name), (byte N), (highNibble N), " &
    "(lowNibble N) or (record ...)", n.line)
  if not testSeen: mapError("(when) needs (is v), (in v...) or (range lo hi)", n.line)

proc compileField(n: NNode, inRepeat = false): VendorFieldPlan =
  result = VendorFieldPlan(name: n.textAtom, scale: 1.0)
  var atSeen, encSeen = false
  var lenBytes, lenNibbles = 0
  for k in n.trees:
    case k.tag
    of "at":
      result.byteOff = k.boundedAtom(1) - 1
      atSeen = true
    of "nibble":
      let s = k.textAtom.toLowerAscii
      if s notin ["low", "high"]: mapError("(nibble) is high or low", k.line)
      result.lowNibble = s == "low"
    of "len":
      let v = k.boundedAtom(1)
      var nib = false
      for a in k.atoms:
        if a.kind == nkIdent and a.s == "n": nib = true
      if nib: lenNibbles = v else: lenBytes = v
    of "enc":
      try: result.enc = parseEnum[VendorEncoding](k.textAtom)
      except ValueError:
        mapError("field " & result.name & ": unknown encoding " & k.textAtom, k.line)
      encSeen = true
    of "byteOrder":
      case k.textAtom.toLowerAscii
      of "big": result.order = some(boBig)
      of "little": result.order = some(boLittle)
      else: mapError("(byteOrder) is big or little", k.line)
    of "scale":
      result.scale = k.floatAtom
      result.scaled = true
    of "offset":
      result.offset = k.floatAtom
      result.scaled = true
    of "unit": result.unit = k.textAtom
    of "trim":
      try: result.trim = parseEnum[VendorTrim](k.textAtom.toLowerAscii)
      except ValueError: mapError("(trim) is left, right, both or none", k.line)
    of "sentinel": result.sentinel = some(k.intAtom)
    of "enum":
      for e in k.trees: result.enums.add VendorEnumLabel(value: e.tagInt, label: e.textAtom)
    of "bits":
      for e in k.trees:
        let b = e.tagInt
        if b < 0 or b > 63: mapError("bit numbers are 0..63", e.line)
        result.bits.add VendorBitFlag(bit: int(b), name: e.textAtom)
    of "when":
      if inRepeat: mapError("field " & result.name & ": (when) is not supported in (repeat)", k.line)
      result.conds.add compileCond(k)
    else:
      mapError("field " & result.name & ": unknown attribute (" & k.tag & ")", k.line)
  if not atSeen: mapError("field " & result.name & " has no (at)", n.line)
  if not encSeen: mapError("field " & result.name & " has no (enc)", n.line)
  let w = encWidth(result.enc)
  if result.enc in {veBcd, veUNib, veINib}:
    result.nibbles = if lenNibbles > 0: lenNibbles elif lenBytes > 0: 2 * lenBytes
                     else: mapError("field " & result.name & " (" & $result.enc & ") needs (len)",
                       n.line)
    if result.enc == veBcd and result.nibbles > 18:
      mapError("bcd field " & result.name & " exceeds 18 digits", n.line)
    if result.enc != veBcd and result.nibbles > 16:
      mapError("field " & result.name & " exceeds 16 nibbles", n.line)
  elif w > 0:
    if lenNibbles > 0 or (lenBytes > 0 and lenBytes != w):
      mapError("field " & result.name & ": (len) disagrees with " & $result.enc, n.line)
    if result.lowNibble: mapError("only bcd fields may start at a low nibble", n.line)
    result.len = w
  else:
    if lenBytes == 0:
      mapError("field " & result.name & " (" & $result.enc & ") needs (len)", n.line)
    if result.lowNibble: mapError("only bcd fields may start at a low nibble", n.line)
    result.len = lenBytes
  if result.nibbles == 0: result.nibbles = 2 * result.len

proc compileRepeat(n: NNode): VendorRepeatPlan =
  result = VendorRepeatPlan(count: -1)
  for k in n.trees:
    case k.tag
    of "count":
      let r = k.child("ref")
      if r >= 0: result.countRef = k.kids[r].textAtom
      else: result.count = k.boundedAtom(0)
    of "stride": result.stride = k.boundedAtom(1)
    of "at": result.byteOff = k.boundedAtom(1) - 1
    of "field": result.fields.add compileField(k, inRepeat = true)
    else: mapError("unknown (repeat) attribute (" & k.tag & ")", k.line)
  if result.count < 0 and result.countRef.len == 0: mapError("(repeat) needs (count)", n.line)
  if result.stride == 0: mapError("(repeat) needs (stride)", n.line)
  # Fields inside a repeat use 1-based offsets within the element.
  for f in result.fields:
    if (2 * f.byteOff + ord(f.lowNibble) + f.nibbles + 1) div 2 > result.stride:
      mapError("repeat field " & f.name & " exceeds the stride", n.line)

func isIntEncoding(e: VendorEncoding): bool =
  e in {veU8, veU16, veU24, veU32, veU64, veI8, veI16, veI24, veI32, veI64, veBcd, veUNib,
    veINib}

proc addField(t: var VendorTarget, f: sink VendorFieldPlan, inherited: seq[VendorCondition],
    total: var int, line: int) =
  # Adds a field with the conditions of its enclosing groups, resolving each
  # `(when (field x))` to an earlier integer field of the target.
  var f = f
  if f.conds.len + inherited.len > MaxCondsPerField:
    mapError("field " & f.name & " has more than " & $MaxCondsPerField & " (when) conditions" &
      " (its own and its groups')", line)
  total += f.conds.len + inherited.len
  if total > MaxCondsPerMap:
    mapError("the map holds more than " & $MaxCondsPerMap & " (when) conditions over all its fields",
      line)
  f.conds.add inherited
  for c in f.conds.mitems:
    if c.source == csField:
      c.fieldIndex = -1
      for i, g in t.fields:
        if g.name == c.fieldName: c.fieldIndex = i
      if c.fieldIndex < 0:
        mapError("field " & f.name & ": (when (field " & c.fieldName &
          ")) names no field defined earlier in the target", c.line)
      if not t.fields[c.fieldIndex].enc.isIntEncoding:
        mapError("field " & f.name & ": (when (field " & c.fieldName &
          ")) needs an integer or bcd field", c.line)
  t.fields.add f

proc compileLayoutEntry(n: NNode): LayoutEntry =
  # (entry name (at 189) (type int4) (divisor 100)): one SEG-Y trace header
  # entry, as a Layout stanza's <entry>. Rev 0 and 1 files have no stanza.
  result = LayoutEntry(name: normalizeEntryName(n.textAtom), divisor: 1)
  var atSeen, typeSeen = false
  for k in n.trees:
    case k.tag
    of "at":
      result.bytePos = k.boundedAtom(1)
      atSeen = true
    of "type":
      try: result.kind = parseEnum[LayoutType](k.textAtom.toLowerAscii)
      except ValueError: mapError("unknown layout type " & k.textAtom, k.line)
      typeSeen = true
    of "divisor":
      let v = k.intAtom
      if v < 1 or v > 9_999_999: mapError("(divisor) must be 1..9999999", k.line)
      result.divisor = int(v)
    of "extension": result.extension = k.textAtom.toUpperAscii
    of "ifNonZero": result.ifNonZero = true
    else: mapError("unknown layout entry attribute (" & k.tag & ")", k.line)
  if not (atSeen and typeSeen):
    mapError("layout entry " & result.name & " needs (at) and (type)", n.line)
  if result.bytePos + result.kind.size - 1 > 240:
    mapError("layout entry " & result.name & " does not fit a 240-byte header", n.line)

proc compileGroup(t: var VendorTarget, n: NNode, inherited: seq[VendorCondition],
    total: var int) =
  # `(group (when ...)... (field ...)... (group ...))`: the conditions apply to every field.
  var conds = inherited
  for k in n.trees:
    if k.tag == "when":
      if conds.len >= MaxCondsPerField:
        mapError("a group has more than " & $MaxCondsPerField & " (when) conditions", k.line)
      conds.add compileCond(k)
  for k in n.trees:
    case k.tag
    of "when": discard
    of "field": t.addField(compileField(k), conds, total, k.line)
    of "group": t.compileGroup(k, conds, total)
    else: mapError("unknown (group) attribute (" & k.tag & ")", k.line)

proc compileTarget(n: NNode, condTotal: var int): VendorTarget =
  result = VendorTarget(blockIndex: -1, blockType: -1, extIndex: -1)
  var kindSeen = false
  for k in n.trees:
    case k.tag
    of "kind":
      try: result.kind = parseEnum[VendorTargetKind](k.textAtom)
      except ValueError: mapError("unknown target kind " & k.textAtom, k.line)
      kindSeen = true
    of "name": result.name = k.textAtom
    of "blockIndex": result.blockIndex = k.boundedAtom(1)
    of "type": result.blockType = k.boundedAtom(0)
    of "where": result.where = k.textAtom
    of "headerName": result.headerName = k.textAtom
    of "stanza": result.stanza = k.textAtom
    of "extension": result.extIndex = k.boundedAtom(1)
    of "field": result.addField(compileField(k), @[], condTotal, k.line)
    of "group": result.compileGroup(k, @[], condTotal)
    of "match":
      if result.matches.len >= MaxMatchesPerTarget:
        mapError("a target holds at most " & $MaxMatchesPerTarget & " (match) clauses", k.line)
      result.matches.add compileBytesMatch(k)
    of "repeat": result.repeats.add compileRepeat(k)
    else: mapError("unknown target attribute (" & k.tag & ")", k.line)
  if not kindSeen: mapError("target has no (kind)", n.line)
  if result.name.len == 0: result.name = $result.kind
  var names: seq[string]
  for f in result.fields:
    if f.name in names:
      mapError("duplicate field " & f.name & " in target " & result.name, n.line)
    names.add f.name
  for r in result.repeats:
    if r.countRef.len > 0 and r.countRef notin names:
      mapError("(ref " & r.countRef & ") names no field of target " & result.name, n.line)

func usesRecordBlocks*(m: VendorMap): bool =
  ## True when the map reads the record-level blocks of `VendorContext`
  ## (`hasBlock`, `(when (record ...))`).
  if m.match.blocks.len > 0: return true
  for t in m.targets:
    for f in t.fields:
      for c in f.conds:
        if c.recordArea.isSome: return true

proc loadVendorMap*(nif: string, source = ""): VendorMap =
  ## Parses and compiles one vendor map. Raises `ValueError` (with a line
  ## number) for a malformed map.
  let roots = parseNif(nif)
  var found = -1
  for i, n in roots:
    if n.tag == "vendormap":
      if found >= 0: mapError("a map file holds one (vendormap ...); found a second", n.line)
      found = i
  if found < 0: mapError("no (vendormap ...) in the file")
  let m = roots[found]
  var condTotal = 0
  result = VendorMap(name: m.textAtom, source: source,
    match: VendorMatch(serialMin: -1, serialMax: -1))
  for k in m.trees:
    case k.tag
    of "version": result.version = k.boundedAtom(0)
    of "doc": result.doc = k.textAtom
    of "match":
      for c in k.trees:
        case c.tag
        of "format": result.match.format = some(c.seismicKindAtom)
        of "rev":
          var r: VendorRevisionRange
          if not c.revAtom(0, r.first): mapError("(rev) needs a revision", c.line)
          if not c.revAtom(1, r.last): r.last = r.first
          result.match.revisions = some(r)
        of "manufacturer":
          for a in c.atoms:
            if a.kind == nkInt: result.match.manufacturers.add int(a.i)
        of "serial":
          let bounds = c.intAtoms
          if bounds.len == 0: mapError("(serial) needs a number", c.line)
          result.match.serialMin = bounds[0]
          result.match.serialMax = if bounds.len > 1: bounds[1] else: bounds[0]
        of "textContains": result.match.textContains.add c.textAtom
        of "hasBlock":
          var bm = VendorBlockMatch(area: c.blockAreaAtom)
          for r in c.trees:
            if r.tag != "match": mapError("unknown (hasBlock) attribute (" & r.tag & ")", r.line)
            if bm.matches.len >= MaxMatchesPerTarget: mapError("too many (match)", r.line)
            bm.matches.add compileBytesMatch(r)
          if bm.matches.len == 0: mapError("(hasBlock) needs a (match)", c.line)
          result.match.blocks.add bm
        else: mapError("unknown match clause (" & c.tag & ")", c.line)
    of "target": result.targets.add compileTarget(k, condTotal)
    of "layout":
      for e in k.trees:
        if e.tag != "entry": mapError("unknown (layout) attribute (" & e.tag & ")", e.line)
        result.layout.add compileLayoutEntry(e)
    else: mapError("unknown vendormap attribute (" & k.tag & ")", k.line)
  if result.targets.len == 0 and result.layout.len == 0:
    mapError("vendor map " & result.name & " has no target or layout")

func contradicts(a, b: seq[VendorBytesMatch]): bool =
  # True when some byte is required to have two values.
  for x in a:
    for y in b:
      for i, u in x.bytes:
        let j = x.byteOff + i - y.byteOff
        if j >= 0 and j < y.bytes.len and y.bytes[j] != u: return true

func mayShareBlock(a, b: VendorTarget): bool =
  # Could one block be decoded by both targets?
  if a.kind != b.kind: return false
  if a.blockIndex >= 0 and b.blockIndex >= 0 and a.blockIndex != b.blockIndex: return false
  if a.kind in {vtExtendedHeader, vtExternalHeader, vtTrailer}:
    # A whole area and a block of it are different offers.
    let wa = a.blockIndex < 0 and a.matches.len == 0
    let wb = b.blockIndex < 0 and b.matches.len == 0
    if wa != wb: return false
  if a.blockType >= 0 and b.blockType >= 0 and a.blockType != b.blockType: return false
  if a.where.len > 0 and b.where.len > 0 and cmpIgnoreCase(a.where, b.where) != 0: return false
  if a.extIndex >= 0 and b.extIndex >= 0 and a.extIndex != b.extIndex: return false
  if a.headerName.len > 0 and b.headerName.len > 0 and a.headerName != b.headerName: return false
  if a.stanza.len > 0 and b.stanza.len > 0 and a.stanza != b.stanza: return false
  not contradicts(a.matches, b.matches)

func blockKind(k: VendorTargetKind): bool =
  # Areas handed over in 32-byte blocks.
  k in {vtExtendedHeader, vtExternalHeader, vtGeneralHeader, vtTraceExt}

proc checkVendorMap*(m: VendorMap): seq[string] =
  ## Problems that do not stop a map from loading: overlapping fields within
  ## a target (bit-level reuse is sometimes intended; fields under `(when)`
  ## are not compared, as they may exclude each other), and content
  ## `match` clauses and conditions that read beyond the 32-byte blocks of
  ## SEG-D (they can never hold, or the field is never decoded), and two
  ## targets that can decode one block and give the same field name.
  for t in m.targets:
    for i, a in t.fields:
      for b in t.fields[i + 1 .. ^1]:
        if a.conds.len > 0 and b.conds.len > 0: continue
        let a0 = 2 * a.byteOff + ord(a.lowNibble)
        let b0 = 2 * b.byteOff + ord(b.lowNibble)
        if a0 < b0 + b.nibbles and b0 < a0 + a.nibbles:
          result.add "target " & t.name & ": fields " & a.name & " and " & b.name & " overlap"
    if t.kind.blockKind:
      for x in t.matches:
        if x.byteOff + x.bytes.len > VendorBlockSize:
          result.add "target " & t.name & ": (match) lies beyond the " & $VendorBlockSize &
            "-byte block and never holds"
      for f in t.fields:
        for c in f.conds:
          if c.recordArea.isNone and c.source != csField and c.byteOff >= VendorBlockSize:
            result.add "target " & t.name & ": field " & f.name & " is conditioned on byte " &
              $(c.byteOff + 1) & ", beyond the " & $VendorBlockSize & "-byte block"
  for t in m.targets:
    for f in t.fields:
      for c in f.conds:
        if c.recordArea.isSome:
          if c.byteOff >= VendorBlockSize:
            result.add "target " & t.name & ": field " & f.name & " reads byte " & $(c.byteOff + 1) &
              " of a record block, beyond the " & $VendorBlockSize & "-byte block"
          for x in c.recordMatch:
            if x.byteOff + x.bytes.len > VendorBlockSize:
              result.add "target " & t.name & ": field " & f.name &
                " has a (record) (match) beyond the " & $VendorBlockSize & "-byte block;" &
                " it never holds"
  for i, a in m.targets:
    for b in m.targets[i + 1 .. ^1]:
      if a.mayShareBlock(b):
        for fa in a.fields:
          for fb in b.fields:
            if fa.name == fb.name:
              result.add "targets " & a.name & " and " & b.name & " can decode the same block " &
                "and both give field " & fa.name
  for hb in m.match.blocks:
    for x in hb.matches:
      if x.byteOff + x.bytes.len > VendorBlockSize:
        result.add "(hasBlock " & $hb.area & ") lies beyond the " & $VendorBlockSize &
          "-byte block and never holds"

# --------------------------------------------------------------- registry --

proc vendorSearchPath*(): seq[string] =
  ## The built-in `vendormaps/` directory of the repository, then the
  ## directories in `PARSESEG_VENDOR_PATH` (separated by the platform's path
  ## separator).
  result.add currentSourcePath().parentDir.parentDir.parentDir.parentDir / "vendormaps"
  for d in getEnv("PARSESEG_VENDOR_PATH").split(PathSep):
    if d.len > 0: result.add d

proc addMap*(reg: var VendorRegistry, m: sink VendorMap) =
  ## Adds a loaded map to the registry.
  reg.maps.add m

proc loadVendorMaps*(reg: var VendorRegistry, paths: openArray[string], log: var DiagLog) =
  ## Loads every `*.nif` file in `paths` (directories or files). A map that
  ## does not load is reported (`dcVendorMap`) and skipped.
  for p in paths:
    var files: seq[string]
    if dirExists(p):
      for f in walkFiles(p / "*.nif"): files.add f
    elif fileExists(p):
      files.add p
    for f in files:
      try:
        let m = loadVendorMap(readFileShared(f), f)
        for problem in m.checkVendorMap:
          log.report(sevInfo, dcVendorMap, m.name & ": " & problem, loc = Location(file: f))
        reg.addMap m
      except CatchableError as e:
        log.report(sevWarning, dcVendorMap, "vendor map not loaded: " & e.msg,
          loc = Location(file: f))

proc registerVendorDecoder*(reg: var VendorRegistry, manufacturer: int,
    kind: VendorTargetKind, name: string, decoder: VendorDecoder) =
  ## Registers a code decoder for (manufacturer, kind); -1 = any manufacturer.
  ## Code decoders are tried before maps.
  reg.decoders.add CodeDecoder(manufacturer: manufacturer, kind: kind, name: name,
    decoder: decoder)

func holds(b: openArray[byte], ms: openArray[VendorBytesMatch]): bool =
  # True when `b` holds every byte run (a run past the end does not hold).
  for m in ms:
    if m.byteOff < 0 or m.byteOff + m.bytes.len > b.len: return false
    for i, x in m.bytes:
      if b[m.byteOff + i] != x: return false
  true

func findBlock(area: openArray[byte], ms: openArray[VendorBytesMatch]): int =
  ## The byte offset of the first 32-byte block of `area` holding every run, or -1.
  var i = 0
  while i + VendorBlockSize <= area.len:
    if area.toOpenArray(i, i + VendorBlockSize - 1).holds(ms): return i
    i += VendorBlockSize
  -1

func contextArea(ctx: VendorContext, k: VendorTargetKind): lent seq[byte] =
  # Each branch assigns `result`: a `case` expression returned through `lent` is
  # compiled (Nim 2.4.2) as a temporary copy that is destroyed before the caller
  # reads it.
  case k
  of vtExtendedHeader: result = ctx.extended
  of vtExternalHeader: result = ctx.external
  else: result = ctx.general

func specificity(m: VendorMatch, ctx: VendorContext): int =
  # -1 if the map does not apply, else the number of clauses that hold.
  result = 0
  if m.format.isSome:
    if m.format.get != ctx.format: return -1
    inc result
  if m.revisions.isSome:
    let r = (ctx.revision.major, ctx.revision.minor)
    let (a, b) = (m.revisions.get.first, m.revisions.get.last)
    if r < (a.major, a.minor) or r > (b.major, b.minor): return -1
    inc result
  if m.manufacturers.len > 0:
    if ctx.manufacturer notin m.manufacturers: return -1
    inc result
  if m.serialMin >= 0:
    if ctx.serial < m.serialMin or ctx.serial > m.serialMax: return -1
    inc result
  for s in m.textContains:
    if s notin ctx.text: return -1
    inc result
  for hb in m.blocks:
    if ctx.contextArea(hb.area).findBlock(hb.matches) < 0: return -1
    inc result

func headerKey(name: string): string =
  # A proprietary header name without its space/NUL padding.
  name.strip(chars = {' ', '\0'})

func targetMatches(t: VendorTarget, a: VendorArea, b: openArray[byte]): bool =
  # With `match` clauses and no `blockIndex`, the target is for every block of
  # the area (never for the whole area of a 32-byte block kind; a Rev 3 trailer
  # description block's data has a block type and counts as one block).
  let indexOk =
    if t.blockIndex >= 0 or t.matches.len == 0: t.blockIndex == a.blockIndex
    else: a.blockIndex >= 0 or t.kind notin {vtExtendedHeader, vtExternalHeader, vtTrailer} or
      (t.kind == vtTrailer and a.blockType >= 0) # a Rev 3 trailer block's data
  t.kind == a.kind and
    indexOk and
    b.holds(t.matches) and
    (t.blockType < 0 or t.blockType == a.blockType) and
    (t.where.len == 0 or cmpIgnoreCase(t.where, a.where) == 0) and
    (t.headerName.len == 0 or
      cmpIgnoreCase(headerKey(t.headerName), headerKey(a.headerName)) == 0) and
    (t.stanza.len == 0 or
      cmpIgnoreCase(t.stanza.replace(" ", ""), a.stanza.replace(" ", "")) == 0) and
    (t.extIndex < 0 or t.extIndex == a.extIndex)

# ----------------------------------------------------------------- decode --

func trimText(s: string, how: VendorTrim): string =
  case how
  of trimNone: s
  of trimLeft: s.strip(trailing = false)
  of trimRight: s.strip(leading = false)
  of trimBoth: s.strip

func fits(f: VendorFieldPlan, b: openArray[byte], pos: int): bool =
  pos >= 0 and pos * 2 + ord(f.lowNibble) + f.nibbles <= 2 * b.len

func readInt(f: VendorFieldPlan, b: openArray[byte], pos: int, o: ByteOrder): int64 =
  # The raw value of a binary integer or nibble field that fits `b` (0 for others).
  case f.enc
  of veU8: int64(b[pos])
  of veI8: int64(cast[int8](b[pos]))
  of veU16: int64(getNum[uint16](b, pos, o))
  of veI16: int64(getNum[int16](b, pos, o))
  of veU24, veI24:
    let u = if o == boLittle:
              (uint32(b[pos + 2]) shl 16) or (uint32(b[pos + 1]) shl 8) or uint32(b[pos])
            else: beU24(b, pos)
    if f.enc == veI24: int64(cast[int32](u shl 8) shr 8) else: int64(u)
  of veU32: int64(getNum[uint32](b, pos, o))
  of veI32: int64(getNum[int32](b, pos, o))
  of veU64: cast[int64](getNum[uint64](b, pos, o))
  of veI64: getNum[int64](b, pos, o)
  of veUNib, veINib:
    let first = 2 * pos + ord(f.lowNibble)
    var u = 0'u64
    for n in first ..< first + f.nibbles: u = (u shl 4) or uint64(nibble(b, n))
    if f.enc == veINib and f.nibbles < 16 and ((u shr (4 * f.nibbles - 1)) and 1) != 0:
      u = u or (not 0'u64 shl (4 * f.nibbles))
    cast[int64](u)
  else: 0

func readRaw(f: VendorFieldPlan, b: openArray[byte], order: ByteOrder, iv: var int64): bool =
  # The raw integer of field `f` of block `b`; false if it does not fit or is no integer.
  if not f.fits(b, f.byteOff): return false
  case f.enc
  of veBcd:
    let first = 2 * f.byteOff + ord(f.lowNibble)
    iv = 0
    for n in first ..< first + f.nibbles:
      let d = nibble(b, n)
      if d > 9: return false
      iv = iv * 10 + int64(d)
    true
  of veU8, veI8, veU16, veI16, veU24, veI24, veU32, veI32, veU64, veI64, veUNib, veINib:
    iv = f.readInt(b, f.byteOff, f.order.get(order))
    true
  else: false

proc decodeField(f: VendorFieldPlan, b: openArray[byte], base: int,
    order: ByteOrder): Option[VendorValue] =
  # None when the field does not fit `b` or holds its sentinel.
  let pos = base + f.byteOff
  if not f.fits(b, pos):
    return none(VendorValue)
  let o = f.order.get(order)
  var iv: int64
  var isInt = true
  var fv: float64
  case f.enc
  of veU8, veI8, veU16, veI16, veU24, veI24, veU32, veI32, veU64, veI64, veUNib, veINib:
    iv = f.readInt(b, pos, o)
  of veF32:
    isInt = false
    fv = float64(getNum[float32](b, pos, o))
  of veF64:
    isInt = false
    fv = getNum[float64](b, pos, o)
  of veIbm32:
    isInt = false
    fv = ibmToFloat64(getNum[uint32](b, pos, o))
  of veFixedPt:
    isInt = false
    var u = 0'u64
    for i in 0..4: u = (u shl 8) or uint64(b[pos + i])
    fv = float64(cast[int64](u shl 24) shr 24) / 65536.0
  of veBcd:
    let first = 2 * pos + ord(f.lowNibble)
    iv = 0
    for n in first ..< first + f.nibbles:
      let d = nibble(b, n)
      if d > 9:
        let last = pos + (f.nibbles + ord(f.lowNibble) + 1) div 2
        return some VendorValue(kind: vvBytes, bytes: b[pos ..< last], unit: f.unit,
          label: "invalid BCD")
      iv = iv * 10 + int64(d)
  of veAscii, veEbcdic:
    var s = newString(f.len)
    for i in 0..<f.len:
      s[i] = if f.enc == veAscii: char(b[pos + i]) else: char(ebcdicToLatin1[b[pos + i]])
    return some VendorValue(kind: vvText, text: trimText(s, f.trim), unit: f.unit)
  of veRaw:
    return some VendorValue(kind: vvBytes, bytes: b[pos ..< pos + f.len], unit: f.unit)
  if not isInt:
    return some VendorValue(kind: vvFloat,
      floatVal: (if f.scaled: fv * f.scale + f.offset else: fv), unit: f.unit)
  if f.sentinel.isSome:
    # Compare the raw bit pattern: (sentinel 0xFFFFFF) matches an i24 of -1.
    let w = encWidth(f.enc)
    let mask =
      if f.enc in {veUNib, veINib}:
        (if f.nibbles >= 16: not 0'u64 else: (1'u64 shl (4 * f.nibbles)) - 1)
      elif f.enc == veBcd or w >= 8: not 0'u64
      else: (1'u64 shl (8 * w)) - 1
    if (cast[uint64](iv) and mask) == (cast[uint64](f.sentinel.get) and mask):
      return none(VendorValue)
  var v = if f.scaled:
            VendorValue(kind: vvFloat, floatVal: float64(iv) * f.scale + f.offset, unit: f.unit)
          else: VendorValue(kind: vvInt, intVal: iv, unit: f.unit)
  for e in f.enums:
    if e.value == iv: v.label = e.label
  for flag in f.bits:
    if ((cast[uint64](iv) shr flag.bit) and 1) != 0: v.flags.add flag.name
  some(v)

func testHolds(c: VendorCondition, v: int64): bool =
  if c.isRange: v >= c.lo and v <= c.hi else: v in c.values

func condHolds(c: VendorCondition, t: VendorTarget, b: openArray[byte], order: ByteOrder,
    ctx: VendorContext, off: openArray[bool]): bool =
  # False when the source is missing (no such field or block, byte past the end,
  # or a field `off` by its own conditions).
  var v: int64
  if c.source == csField:
    if c.fieldIndex < off.len and off[c.fieldIndex]: return false
    if not t.fields[c.fieldIndex].readRaw(b, order, v): return false
    return c.testHolds(v)
  var x = -1
  if c.recordArea.isSome:
    let area = ctx.contextArea(c.recordArea.get)
    let at = area.findBlock(c.recordMatch)
    if at >= 0 and c.byteOff < VendorBlockSize: x = int(area[at + c.byteOff])
  elif c.byteOff < b.len:
    x = int(b[c.byteOff])
  if x < 0: return false
  v = case c.source
      of csByte: int64(x)
      of csHighNibble: int64(x shr 4)
      else: int64(x and 15)
  c.testHolds(v)

proc decodeTarget*(t: VendorTarget, b: openArray[byte], order: ByteOrder,
    blk: var VendorBlock, problems: var seq[string], ctx: VendorContext = VendorContext()) =
  ## Decodes `t`'s fields from `b` into `blk`; fields that do not fit are
  ## listed in `problems` (sentinel values and fields whose `(when)` fails
  ## are simply absent; a condition on a field that is absent for its own
  ## conditions fails). `ctx` supplies the record-level blocks of
  ## `(when (record ...))` conditions.
  blk.name = t.name
  var off: seq[bool] # fields whose own conditions failed (allocated at the first)
  for i, f in t.fields:
    var on = true
    for c in f.conds:
      if not c.condHolds(t, b, order, ctx, off):
        on = false
        break
    if not on:
      if off.len == 0: off = newSeq[bool](t.fields.len)
      off[i] = true
      continue
    let v = decodeField(f, b, 0, order)
    if v.isSome:
      blk.fields.add VendorField(name: f.name, value: v.get)
    elif (2 * f.byteOff + ord(f.lowNibble) + f.nibbles + 1) div 2 > b.len:
      problems.add "field " & f.name & " lies beyond the " & $b.len & "-byte area"
  for r in t.repeats:
    var count = r.count
    if r.countRef.len > 0:
      count = -1
      for f in blk.fields:
        if f.name == r.countRef and f.value.kind == vvInt:
          count = int(max(min(f.value.intVal, 1_000_000), -2))
      if count == -1:
        problems.add "repeat count field " & r.countRef & " is missing"
        count = 0
      elif count < 0:
        problems.add "repeat count field " & r.countRef & " is negative"
        count = 0
    let fit = if r.stride > 0: max(0, (b.len - r.byteOff) div r.stride) else: 0
    if count > fit:
      problems.add "repeat of " & $count & " elements exceeds the area (" & $fit & " fit)"
      count = fit
    for i in 0..<count:
      for f in r.fields:
        let v = decodeField(f, b, r.byteOff + i * r.stride, order)
        if v.isSome: blk.fields.add VendorField(name: f.name & "[" & $i & "]", value: v.get)

func vendorLayout*(reg: VendorRegistry, ctx: VendorContext): seq[LayoutEntry] =
  ## The `(layout)` entries of the most specific map with a layout that
  ## applies to `ctx` (the one loaded first when equally specific); empty
  ## when none does. `openSeismic` merges them over a SEG-Y file's layout
  ## (`OpenOptions.vendors`).
  var best = -1
  for m in reg.maps:
    if m.layout.len > 0:
      let sp = specificity(m.match, ctx)
      if sp > best:
        best = sp
        result = m.layout

func applies*(m: VendorMap, ctx: VendorContext): bool =
  ## True when every clause of the map's `match` holds for `ctx`.
  specificity(m.match, ctx) >= 0

proc decodeAll*(reg: VendorRegistry, ctx: VendorContext, area: VendorArea,
    bytes: openArray[byte], log: var DiagLog, loc = Location()): seq[VendorBlock] =
  ## Decodes a vendor area: a registered code decoder for (manufacturer,
  ## kind) first, then the most specific matching map with a target for the
  ## area. Empty when nothing applies (the caller keeps the raw bytes and may
  ## report `dcVendorBlock`). The targets without `match` give one block
  ## together (first); each target with `match` that holds gives a block of
  ## its own, so two targets never merge their fields. Problems become
  ## diagnostics.
  let blockNumber = if area.blockIndex >= 0: area.blockIndex else: area.extIndex
  for d in reg.decoders:
    if d.kind == area.kind and (d.manufacturer < 0 or d.manufacturer == ctx.manufacturer):
      try:
        var b = d.decoder(bytes, area, ctx)
        if b.isSome:
          b.get.mapName = d.name
          b.get.blockNumber = blockNumber
          return @[b.get]
      except CatchableError as e:
        log.report(sevWarning, dcVendorMap, "vendor decoder " & d.name & " failed: " & e.msg,
          loc = loc)
  var best = -1
  var bestSpec = -1
  var tie = false
  for i, m in reg.maps:
    let s = specificity(m.match, ctx)
    if s >= 0:
      var has = false
      for t in m.targets:
        if targetMatches(t, area, bytes): has = true
      if has:
        if s > bestSpec:
          best = i
          bestSpec = s
          tie = false
        elif s == bestSpec:
          tie = true
  if best < 0:
    return @[]
  template m: untyped = reg.maps[best]
  if tie:
    log.report(sevWarning, dcVendorMap, "several vendor maps match this " & $area.kind &
      " equally; using " & m.name, loc = loc)
  var problems: seq[string]
  var positional = VendorBlock(mapName: m.name, blockNumber: blockNumber)
  var havePositional = false
  var matched: seq[VendorBlock]
  for t in m.targets:
    if targetMatches(t, area, bytes):
      if t.matches.len == 0:
        havePositional = true
        t.decodeTarget(bytes, ctx.byteOrder, positional, problems, ctx)
      else:
        matched.add VendorBlock(mapName: m.name, blockNumber: blockNumber)
        t.decodeTarget(bytes, ctx.byteOrder, matched[^1], problems, ctx)
  if havePositional: result.add positional
  result.add matched
  for p in problems:
    log.report(sevWarning, dcVendorMap, m.name & ": " & p, loc = loc)

proc decode*(reg: VendorRegistry, ctx: VendorContext, area: VendorArea, bytes: openArray[byte],
    log: var DiagLog, loc = Location()): Option[VendorBlock] =
  ## `decodeAll`'s first block, or none when nothing applies. Use
  ## `decodeAll` when a map has several targets with `match`.
  let all = reg.decodeAll(ctx, area, bytes, log, loc)
  if all.len > 0: some(all[0]) else: none(VendorBlock)

func `[]`*(blk: VendorBlock, name: string): lent VendorValue =
  ## The value of field `name`. Raises `KeyError` if it was not decoded.
  for f in blk.fields:
    if f.name == name: return f.value
  raise newException(KeyError, "vendor field '" & name & "' not decoded")

func contains*(blk: VendorBlock, name: string): bool =
  ## True when field `name` was decoded (`name in blk`).
  for f in blk.fields:
    if f.name == name: return true

func toFloat*(v: VendorValue): float64 =
  ## A numeric value as float64; NaN for text and bytes.
  case v.kind
  of vvInt: float64(v.intVal)
  of vvFloat: v.floatVal
  else: NaN
