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
##   Hex numbers may be written `0xB0` or `"0xB0"`. `;` starts a comment.
## - Encodings: `u8 u16 u24 u32 u64 i8 i16 i24 i32 i64 f32 f64 ibm32 bcd
##   fixedpt ascii ebcdic raw` (`fixedpt` = `i24.u16`, 5 bytes).
## - Per field: `byteOrder` (big/little; default: the file's), `scale`,
##   `offset`, `unit`, `enum`, `bits`, `sentinel` (a raw value meaning "absent"),
##   `trim` (left/right/both, text).
## - `repeat` decodes a group `count` times (a number or `(ref field)`), at
##   `at + i * stride`; its fields are named `name[i]`.
##
## Loading compiles each map into flat field plans, so decoding is a loop
## over precomputed offsets. Nothing here is fatal: malformed maps and fields
## that do not fit the data become diagnostics, and raw bytes are always kept
## by the format readers.

import std/[strutils, os, math]
import nifreader, nifcore
import ../common/[endians, ibmfloat, ebcdic, bcd, diagnostics]
export diagnostics, endians

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

  VendorEnc* = enum
    veU8 = "u8", veU16 = "u16", veU24 = "u24", veU32 = "u32", veU64 = "u64",
    veI8 = "i8", veI16 = "i16", veI24 = "i24", veI32 = "i32", veI64 = "i64",
    veF32 = "f32", veF64 = "f64", veIbm32 = "ibm32", veBcd = "bcd", veFixedPt = "fixedpt",
    veAscii = "ascii", veEbcdic = "ebcdic", veRaw = "raw"

  FieldPlan* = object
    ## A compiled field.
    name*: string
    byteOff*: int       ## 0-based byte offset within the target (or repeat element).
    lowNibble*: bool    ## Starts at the low nibble of `byteOff`.
    len*: int           ## Bytes (nibbles for `bcd` given in nibbles; see `nibbles`).
    nibbles*: int       ## Length in nibbles for nibble-addressed fields, else 0.
    enc*: VendorEnc
    hasOrder*: bool
    order*: ByteOrder
    scale*, offset*: float64
    scaled*: bool
    unit*: string
    enums*: seq[(int64, string)]
    bits*: seq[(int, string)]
    hasSentinel*: bool
    sentinel*: int64
    trim*: string

  RepeatPlan* = object
    count*: int          ## Fixed count, or -1 when `countRef` names a field.
    countRef*: string
    stride*: int
    byteOff*: int        ## 0-based offset of element 0.
    fields*: seq[FieldPlan]

  VendorTarget* = object
    kind*: VendorTargetKind
    name*: string        ## Name of the decoded block.
    blockIndex*: int     ## 1-based block within the area; -1 (omitted) = the whole area.
    blockType*: int      ## SEG-D 3.x block type byte; -1 = any.
    where*: string       ## e.g. `traceHeader`, `generalHeader`; "" = any.
    headerName*: string  ## SEG-Y proprietary trace header name; "" = any.
    stanza*: string      ## SEG-Y stanza `COMPANY:NAME`; "" = any.
    extIndex*: int       ## SEG-D trace header extension number k; -1 = any.
    fields*: seq[FieldPlan]
    repeats*: seq[RepeatPlan]

  VendorMatch* = object
    format*: string      ## `segd`, `segy`, "" = any.
    revMin*, revMax*: float64 ## Inclusive; NaN = unbounded.
    manufacturers*: seq[int]
    serialMin*, serialMax*: int64 ## -1 = unbounded.
    textContains*: seq[string]

  VendorMap* = object
    name*: string
    version*: int
    doc*: string
    source*: string      ## File the map was loaded from.
    match*: VendorMatch
    targets*: seq[VendorTarget]

  VendorContext* = object
    ## Facts about a file that maps are matched against.
    format*: string      ## `segd` or `segy`.
    revision*: float64   ## e.g. 2.1.
    manufacturer*: int   ## SEG-D GH#1 manufacturer code; -1 if unknown.
    serial*: int64       ## Manufacturer serial number; -1 if unknown.
    text*: string        ## SEG-Y textual header (for `textContains`).
    byteOrder*: ByteOrder ## The file's byte order (default for fields).

  VendorArea* = object
    ## A vendor area handed to `decode`.
    kind*: VendorTargetKind
    blockIndex*: int     ## 1-based block within the area, -1 for the whole area.
    blockType*: int
    where*: string
    headerName*: string
    stanza*: string
    extIndex*: int

  VendorValueKind* = enum vvInt, vvFloat, vvText, vvBytes

  VendorValue* = object
    case kind*: VendorValueKind
    of vvInt: intVal*: int64
    of vvFloat: floatVal*: float64
    of vvText: text*: string
    of vvBytes: bytes*: seq[byte]
    unit*: string
    label*: string        ## Enum label, if the value has one.
    flags*: seq[string]   ## Names of set bits, for `bits` fields.

  VendorBlock* = object
    ## Decoded vendor data, beside the raw bytes the readers keep.
    mapName*: string
    name*: string
    fields*: seq[(string, VendorValue)]

  VendorDecoder* = proc (bytes: openArray[byte], area: VendorArea, ctx: VendorContext,
    blk: var VendorBlock): bool {.nimcall, raises: [CatchableError].}
    ## A code decoder; returns false if it does not handle these bytes.

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

type
  NKind = enum nkTree, nkInt, nkFloat, nkIdent, nkStr
  NNode = object
    kind: NKind
    tag: string
    kids: seq[NNode]
    i: int64
    f: float64
    s: string
    line: int

proc mapError(msg: string, line = 0) {.noinline, noreturn.} =
  raise newException(ValueError, (if line > 0: "line " & $line & ": " else: "") & msg)

func stripComments(src: string): string =
  # Removes `;` comments outside string literals.
  var inStr = false
  var inComment = false
  for c in src:
    if inComment:
      if c == '\n':
        inComment = false
        result.add c
    elif inStr:
      result.add c
      if c == '"': inStr = false
    elif c == '"':
      inStr = true
      result.add c
    elif c == ';':
      inComment = true
    else:
      result.add c

proc parseTree(r: var Reader, t: var ExpandedToken): NNode =
  # `t` is a ParLe; reads up to the matching ParRi.
  result = NNode(kind: nkTree, tag: r.decodeStr(t), line: int(r.line))
  var done = false
  while not done:
    next(r, t)
    case t.tk
    of ParRi: done = true
    of ParLe: result.kids.add parseTree(r, t)
    of IntLit: result.kids.add NNode(kind: nkInt, i: decodeInt(t), line: int(r.line))
    of UIntLit: result.kids.add NNode(kind: nkInt, i: int64(decodeUInt(t)), line: int(r.line))
    of FloatLit: result.kids.add NNode(kind: nkFloat, f: decodeFloat(t), line: int(r.line))
    of Ident, Symbol, SymbolDef:
      result.kids.add NNode(kind: nkIdent, s: r.decodeStr(t), line: int(r.line))
    of StrLit: result.kids.add NNode(kind: nkStr, s: r.decodeStr(t), line: int(r.line))
    of EofToken: mapError("unexpected end of the map (unbalanced parentheses)", int(r.line))
    else: discard

proc parseNif(src: string): seq[NNode] =
  var r = openFromBuffer(stripComments(src), "")
  var t = default(ExpandedToken)
  try:
    while true:
      next(r, t)
      case t.tk
      of EofToken: break
      of ParLe: result.add parseTree(r, t)
      else: discard
  finally:
    r.close()

func atoms(n: NNode): seq[NNode] =
  for k in n.kids:
    if k.kind != nkTree: result.add k

func child(n: NNode, tag: string): int =
  result = -1
  for i, k in n.kids:
    if k.kind == nkTree and k.tag == tag: return i

proc intAtom(n: NNode, i = 0): int64 =
  # The i-th number of a tree's atoms: an integer, `0xB0` (read as 0 + xB0)
  # or a string "0xB0".
  let a = n.atoms
  var k = 0
  var idx = 0
  while idx < a.len:
    var v: int64
    var ok = true
    if a[idx].kind == nkInt and idx + 1 < a.len and a[idx].i == 0 and a[idx + 1].kind == nkIdent and
        a[idx + 1].s.len > 1 and a[idx + 1].s[0] in {'x', 'X'}:
      try: v = int64(parseHexInt(a[idx + 1].s[1..^1]))
      except ValueError: mapError("bad hex number 0" & a[idx + 1].s, n.line)
      idx += 2
    elif a[idx].kind == nkInt:
      v = a[idx].i
      inc idx
    elif a[idx].kind in {nkStr, nkIdent} and a[idx].s.toLowerAscii.startsWith("0x"):
      try: v = int64(parseHexInt(a[idx].s[2..^1]))
      except ValueError: mapError("bad hex number " & a[idx].s, n.line)
      inc idx
    else:
      ok = false
      inc idx
    if ok:
      if k == i: return v
      inc k
  mapError("(" & n.tag & ") needs a number", n.line)

proc tagInt(n: NNode): int64 =
  # A number written as a tag, e.g. the `0xB0` of `(0xB0 "status")`.
  try:
    result = if n.tag.toLowerAscii.startsWith("0x"): int64(parseHexInt(n.tag[2..^1]))
             else: int64(parseBiggestInt(n.tag))
  except ValueError:
    mapError("expected a number, not (" & n.tag, n.line)

proc floatAtom(n: NNode, i = 0): float64 =
  var k = 0
  for a in n.atoms:
    if a.kind in {nkInt, nkFloat}:
      if k == i: return (if a.kind == nkInt: float64(a.i) else: a.f)
      inc k
  mapError("(" & n.tag & ") needs a number", n.line)

proc textAtom(n: NNode): string =
  for a in n.atoms:
    if a.kind in {nkIdent, nkStr}: return a.s
  mapError("(" & n.tag & ") needs a name or string", n.line)

# ---------------------------------------------------------------- compile --

func encWidth(e: VendorEnc): int =
  case e
  of veU8, veI8: 1
  of veU16, veI16: 2
  of veU24, veI24: 3
  of veU32, veI32, veF32, veIbm32: 4
  of veU64, veI64, veF64: 8
  of veFixedPt: 5
  of veBcd, veAscii, veEbcdic, veRaw: 0

proc compileField(n: NNode): FieldPlan =
  result = FieldPlan(name: n.textAtom, scale: 1.0)
  var atSeen, encSeen = false
  var lenBytes, lenNibbles = 0
  for k in n.kids:
    if k.kind != nkTree: continue
    case k.tag
    of "at":
      let a = k.intAtom
      if a < 1: mapError("field " & result.name & ": (at) is 1-based", k.line)
      result.byteOff = int(a - 1)
      atSeen = true
    of "nibble":
      let s = k.textAtom.toLowerAscii
      if s notin ["low", "high"]: mapError("(nibble) is high or low", k.line)
      result.lowNibble = s == "low"
    of "len":
      let v = k.intAtom
      var nib = false
      for a in k.atoms:
        if a.kind == nkIdent and a.s == "n": nib = true
      if v < 1 or v > 1_000_000: mapError("field " & result.name & ": bad (len)", k.line)
      if nib: lenNibbles = int(v) else: lenBytes = int(v)
    of "enc":
      try: result.enc = parseEnum[VendorEnc](k.textAtom)
      except ValueError: mapError("field " & result.name & ": unknown encoding " & k.textAtom, k.line)
      encSeen = true
    of "byteOrder":
      result.hasOrder = true
      case k.textAtom.toLowerAscii
      of "big": result.order = boBig
      of "little": result.order = boLittle
      else: mapError("(byteOrder) is big or little", k.line)
    of "scale":
      result.scale = k.floatAtom
      result.scaled = true
    of "offset":
      result.offset = k.floatAtom
      result.scaled = true
    of "unit": result.unit = k.textAtom
    of "trim": result.trim = k.textAtom.toLowerAscii
    of "sentinel":
      result.hasSentinel = true
      result.sentinel = k.intAtom
    of "enum":
      for e in k.kids:
        if e.kind == nkTree:
          result.enums.add (e.tagInt, e.textAtom)
    of "bits":
      for e in k.kids:
        if e.kind == nkTree:
          let b = e.tagInt
          if b < 0 or b > 63: mapError("bit numbers are 0..63", e.line)
          result.bits.add (int(b), e.textAtom)
    of "when":
      mapError("field " & result.name & ": (when) conditions are not supported yet", k.line)
    else:
      mapError("field " & result.name & ": unknown attribute (" & k.tag & ")", k.line)
  if not atSeen: mapError("field " & result.name & " has no (at)", n.line)
  if not encSeen: mapError("field " & result.name & " has no (enc)", n.line)
  let w = encWidth(result.enc)
  if result.enc == veBcd:
    result.nibbles = if lenNibbles > 0: lenNibbles elif lenBytes > 0: 2 * lenBytes
                     else: mapError("bcd field " & result.name & " needs (len)", n.line)
    if result.nibbles > 18: mapError("bcd field " & result.name & " exceeds 18 digits", n.line)
  elif w > 0:
    if lenNibbles > 0 or (lenBytes > 0 and lenBytes != w):
      mapError("field " & result.name & ": (len) disagrees with " & $result.enc, n.line)
    if result.lowNibble: mapError("only bcd fields may start at a low nibble", n.line)
    result.len = w
  else:
    if lenBytes == 0: mapError("field " & result.name & " (" & $result.enc & ") needs (len)", n.line)
    if result.lowNibble: mapError("only bcd fields may start at a low nibble", n.line)
    result.len = lenBytes
  if result.nibbles == 0: result.nibbles = 2 * result.len

proc compileRepeat(n: NNode): RepeatPlan =
  result = RepeatPlan(count: -1)
  for k in n.kids:
    if k.kind != nkTree: continue
    case k.tag
    of "count":
      let r = k.child("ref")
      if r >= 0: result.countRef = k.kids[r].textAtom
      else:
        let c = k.intAtom
        if c < 0 or c > 1_000_000: mapError("(count) out of range", k.line)
        result.count = int(c)
    of "stride":
      let s = k.intAtom
      if s < 1 or s > 1_000_000: mapError("(stride) out of range", k.line)
      result.stride = int(s)
    of "at":
      let a = k.intAtom
      if a < 1: mapError("(at) is 1-based", k.line)
      result.byteOff = int(a - 1)
    of "field": result.fields.add compileField(k)
    else: mapError("unknown (repeat) attribute (" & k.tag & ")", k.line)
  if result.count < 0 and result.countRef.len == 0: mapError("(repeat) needs (count)", n.line)
  if result.stride == 0: mapError("(repeat) needs (stride)", n.line)
  # Fields inside a repeat use 1-based offsets within the element.
  for f in result.fields:
    if f.byteOff + (f.nibbles + 1) div 2 > result.stride:
      mapError("repeat field " & f.name & " exceeds the stride", n.line)

proc compileTarget(n: NNode): VendorTarget =
  result = VendorTarget(blockIndex: -1, blockType: -1, extIndex: -1)
  var kindSeen = false
  for k in n.kids:
    if k.kind != nkTree: continue
    case k.tag
    of "kind":
      try: result.kind = parseEnum[VendorTargetKind](k.textAtom)
      except ValueError: mapError("unknown target kind " & k.textAtom, k.line)
      kindSeen = true
    of "name": result.name = k.textAtom
    of "blockIndex": result.blockIndex = int(k.intAtom)
    of "type": result.blockType = int(k.intAtom)
    of "where": result.where = k.textAtom
    of "headerName": result.headerName = k.textAtom
    of "stanza": result.stanza = k.textAtom
    of "extension": result.extIndex = int(k.intAtom)
    of "field": result.fields.add compileField(k)
    of "repeat": result.repeats.add compileRepeat(k)
    else: mapError("unknown target attribute (" & k.tag & ")", k.line)
  if not kindSeen: mapError("target has no (kind)", n.line)
  if result.name.len == 0: result.name = $result.kind
  var names: seq[string]
  for f in result.fields:
    if f.name in names: mapError("duplicate field " & f.name & " in target " & result.name, n.line)
    names.add f.name
  for r in result.repeats:
    if r.countRef.len > 0 and r.countRef notin names:
      mapError("(ref " & r.countRef & ") names no field of target " & result.name, n.line)

proc loadVendorMap*(nif: string, source = ""): VendorMap =
  ## Parses and compiles one vendor map. Raises `ValueError` (with a line
  ## number) for a malformed map.
  var roots: seq[NNode]
  try:
    roots = parseNif(nif)
  except ValueError as e:
    raise e
  except CatchableError as e:
    mapError("not readable as NIF: " & e.msg)
  var found = -1
  for i, n in roots:
    if n.tag == "vendormap": found = i
  if found < 0: mapError("no (vendormap ...) in the file")
  let m = roots[found]
  result = VendorMap(name: m.textAtom, source: source,
    match: VendorMatch(revMin: NaN, revMax: NaN, serialMin: -1, serialMax: -1))
  for k in m.kids:
    if k.kind != nkTree: continue
    case k.tag
    of "version": result.version = int(k.intAtom)
    of "doc": result.doc = k.textAtom
    of "match":
      for c in k.kids:
        if c.kind != nkTree: continue
        case c.tag
        of "format": result.match.format = c.textAtom.toLowerAscii
        of "rev":
          result.match.revMin = c.floatAtom(0)
          result.match.revMax = try: c.floatAtom(1) except ValueError: result.match.revMin
        of "manufacturer":
          for a in c.atoms:
            if a.kind == nkInt: result.match.manufacturers.add int(a.i)
        of "serial":
          result.match.serialMin = c.intAtom(0)
          result.match.serialMax = try: c.intAtom(1) except ValueError: result.match.serialMin
        of "textContains": result.match.textContains.add c.textAtom
        else: mapError("unknown match clause (" & c.tag & ")", c.line)
    of "target": result.targets.add compileTarget(k)
    else: mapError("unknown vendormap attribute (" & k.tag & ")", k.line)
  if result.targets.len == 0: mapError("vendor map " & result.name & " has no target")

proc checkVendorMap*(m: VendorMap): seq[string] =
  ## Problems that do not stop a map from loading: overlapping fields within
  ## a target (bit-level reuse is sometimes intended).
  for t in m.targets:
    for i, a in t.fields:
      for b in t.fields[i + 1 .. ^1]:
        let a0 = 2 * a.byteOff + ord(a.lowNibble)
        let b0 = 2 * b.byteOff + ord(b.lowNibble)
        if a0 < b0 + b.nibbles and b0 < a0 + a.nibbles:
          result.add "target " & t.name & ": fields " & a.name & " and " & b.name & " overlap"

# --------------------------------------------------------------- registry --

proc vendorSearchPath*(): seq[string] =
  ## The built-in `vendormaps/` directory of the repository, then the
  ## directories in `PARSESEGD_VENDOR_PATH` (separated by the platform's path
  ## separator).
  result.add currentSourcePath().parentDir.parentDir.parentDir.parentDir / "vendormaps"
  for d in getEnv("PARSESEGD_VENDOR_PATH").split(PathSep):
    if d.len > 0: result.add d

proc addMap*(reg: var VendorRegistry, m: sink VendorMap) =
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
        let m = loadVendorMap(readFile(f), f)
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

func specificity(m: VendorMatch, ctx: VendorContext): int =
  # -1 if the map does not apply, else the number of clauses that hold.
  result = 0
  if m.format.len > 0:
    if m.format != ctx.format: return -1
    inc result
  if not m.revMin.isNaN:
    if ctx.revision < m.revMin - 1e-9 or ctx.revision > m.revMax + 1e-9: return -1
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

func targetMatches(t: VendorTarget, a: VendorArea): bool =
  t.kind == a.kind and
    t.blockIndex == a.blockIndex and
    (t.blockType < 0 or t.blockType == a.blockType) and
    (t.where.len == 0 or cmpIgnoreCase(t.where, a.where) == 0) and
    (t.headerName.len == 0 or cmpIgnoreCase(t.headerName, a.headerName) == 0) and
    (t.stanza.len == 0 or cmpIgnoreCase(t.stanza.replace(" ", ""), a.stanza.replace(" ", "")) == 0) and
    (t.extIndex < 0 or t.extIndex == a.extIndex)

# ----------------------------------------------------------------- decode --

func trimText(s, how: string): string =
  case how
  of "left": s.strip(trailing = false)
  of "right": s.strip(leading = false)
  of "both": s.strip
  else: s

proc decodeField(f: FieldPlan, b: openArray[byte], base: int, order: ByteOrder,
    v: var VendorValue): bool =
  # False when the field does not fit `b` or holds its sentinel.
  let pos = base + f.byteOff
  if pos < 0 or pos * 2 + ord(f.lowNibble) + f.nibbles > 2 * b.len:
    return false
  let o = if f.hasOrder: f.order else: order
  var iv: int64
  var isInt = true
  var fv: float64
  case f.enc
  of veU8: iv = int64(b[pos])
  of veI8: iv = int64(cast[int8](b[pos]))
  of veU16: iv = int64(getNum[uint16](b, pos, o))
  of veI16: iv = int64(getNum[int16](b, pos, o))
  of veU24, veI24:
    let u = if o == boLittle: (uint32(b[pos+2]) shl 16) or (uint32(b[pos+1]) shl 8) or uint32(b[pos])
            else: beU24(b, pos)
    iv = if f.enc == veI24: int64(cast[int32](u shl 8) shr 8) else: int64(u)
  of veU32: iv = int64(getNum[uint32](b, pos, o))
  of veI32: iv = int64(getNum[int32](b, pos, o))
  of veU64: iv = cast[int64](getNum[uint64](b, pos, o))
  of veI64: iv = getNum[int64](b, pos, o)
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
        v = VendorValue(kind: vvBytes, bytes: b[pos ..< pos + (f.nibbles + ord(f.lowNibble) + 1) div 2],
          unit: f.unit, label: "invalid BCD")
        return true
      iv = iv * 10 + int64(d)
  of veAscii, veEbcdic:
    var s = newString(f.len)
    for i in 0..<f.len:
      s[i] = if f.enc == veAscii: char(b[pos + i]) else: char(ebcdicToLatin1[b[pos + i]])
    v = VendorValue(kind: vvText, text: trimText(s, f.trim), unit: f.unit)
    return true
  of veRaw:
    v = VendorValue(kind: vvBytes, bytes: b[pos ..< pos + f.len], unit: f.unit)
    return true
  if isInt:
    if f.hasSentinel and iv == f.sentinel: return false
    if f.scaled:
      v = VendorValue(kind: vvFloat, floatVal: float64(iv) * f.scale + f.offset, unit: f.unit)
    else:
      v = VendorValue(kind: vvInt, intVal: iv, unit: f.unit)
    for (code, label) in f.enums:
      if code == iv: v.label = label
    for (bit, name) in f.bits:
      if ((cast[uint64](iv) shr bit) and 1) != 0: v.flags.add name
  else:
    v = VendorValue(kind: vvFloat, floatVal: (if f.scaled: fv * f.scale + f.offset else: fv),
      unit: f.unit)
  result = true

proc decodeTarget*(t: VendorTarget, b: openArray[byte], order: ByteOrder,
    blk: var VendorBlock, problems: var seq[string]) =
  ## Decodes `t`'s fields from `b` into `blk`; fields that do not fit are
  ## listed in `problems` (sentinel values are simply absent).
  blk.name = t.name
  for f in t.fields:
    var v: VendorValue
    if decodeField(f, b, 0, order, v):
      blk.fields.add (f.name, v)
    elif f.byteOff + (f.nibbles + 1) div 2 > b.len:
      problems.add "field " & f.name & " lies beyond the " & $b.len & "-byte area"
  for r in t.repeats:
    var count = r.count
    if r.countRef.len > 0:
      count = -1
      for (n, v) in blk.fields:
        if n == r.countRef and v.kind == vvInt: count = int(min(v.intVal, 1_000_000))
      if count < 0:
        problems.add "repeat count field " & r.countRef & " is missing"
        count = 0
    let fit = if r.stride > 0: max(0, (b.len - r.byteOff) div r.stride) else: 0
    if count > fit:
      problems.add "repeat of " & $count & " elements exceeds the area (" & $fit & " fit)"
      count = fit
    for i in 0..<count:
      for f in r.fields:
        var v: VendorValue
        if decodeField(f, b, r.byteOff + i * r.stride, order, v):
          blk.fields.add (f.name & "[" & $i & "]", v)

proc decode*(reg: VendorRegistry, ctx: VendorContext, area: VendorArea, bytes: openArray[byte],
    blk: var VendorBlock, log: var DiagLog, loc = Location()): bool =
  ## Decodes a vendor area: a registered code decoder for (manufacturer,
  ## kind) first, then the most specific matching map with a target for the
  ## area. Returns false when nothing applies (the caller keeps the raw bytes
  ## and may report `dcVendorBlock`). Problems become diagnostics.
  for d in reg.decoders:
    if d.kind == area.kind and (d.manufacturer < 0 or d.manufacturer == ctx.manufacturer):
      try:
        var b = VendorBlock(mapName: d.name)
        if d.decoder(bytes, area, ctx, b):
          blk = b
          return true
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
        if targetMatches(t, area): has = true
      if has:
        if s > bestSpec:
          best = i
          bestSpec = s
          tie = false
        elif s == bestSpec:
          tie = true
  if best < 0:
    return false
  let m = reg.maps[best]
  if tie:
    log.report(sevWarning, dcVendorMap, "several vendor maps match this " & $area.kind &
      " equally; using " & m.name, loc = loc)
  blk = VendorBlock(mapName: m.name)
  var problems: seq[string]
  for t in m.targets:
    if targetMatches(t, area):
      t.decodeTarget(bytes, ctx.byteOrder, blk, problems)
  for p in problems:
    log.report(sevWarning, dcVendorMap, m.name & ": " & p, loc = loc)
  result = true

func get*(blk: VendorBlock, name: string): VendorValue =
  ## The value of field `name`. Raises `KeyError` if absent.
  for (n, v) in blk.fields:
    if n == name: return v
  raise newException(KeyError, "vendor field '" & name & "' not decoded")

func contains*(blk: VendorBlock, name: string): bool =
  for (n, _) in blk.fields:
    if n == name: return true

func toFloat*(v: VendorValue): float64 =
  ## A numeric value as float64; NaN for text and bytes.
  case v.kind
  of vvInt: float64(v.intVal)
  of vvFloat: v.floatVal
  else: NaN
