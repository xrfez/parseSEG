## SEG-Y layout values and trace keys read straight from the raw header
## bytes (15.3-9).
##
## The index walk and the keys on demand hand over the bytes they read (or
## the mapped ones); `fields.geometry`, `fieldValue` and `keys.traceKeys`
## encode a decoded trace back to bytes first, as they always did. Each
## layout entry is resolved once per file to its header (standard, Trace
## Header Extension 1 or a named proprietary header) and 0-based position;
## a trace then costs one byte-order dispatch, unchecked loads, and each
## scalar (`co_scal`, ...) read once.

import std/[math, strutils]
import ../common/[endians, ibmfloat, years]
import ../segy/[traceheader, layout, reader]
import ../segd/rev3
import ../model/keytypes

type
  GeometryField* = enum
    ## The layout names `geometry` and the SEG-Y keys read.
    gfFfid = "ffid", gfChan = "chan", gfEspnum = "espnum", gfCdp = "cdp", gfCdptrc = "cdptrc",
    gfIline = "iline", gfXline = "xline", gfOffset = "offset", gfShtX = "sht_x",
    gfShtY = "sht_y", gfRecX = "rec_x", gfRecY = "rec_y", gfCdpX = "cdp_x", gfCdpY = "cdp_y",
    gfRelev = "relev", gfSelev = "selev", gfSdepth = "sdepth", gfCoorunit = "coorunit",
    gfSp = "sp"

  HeaderSel = enum
    hsStd ## Extension "" or "SEG00000".
    hsExt1 ## "SEG00001" (any case).
    hsProprietary ## Any other name: the first proprietary header of that name.

  ScalarKind = enum
    skNone, skCoor = "co_scal", skElev = "ed_scal", skTime = "tm_scal", skSpNum = "sp_scal"

  RawEntry = object
    kind: LayoutType
    pos: int ## 0-based.
    sel: HeaderSel
    name: string ## The proprietary header's name (`hsProprietary`).
    ifNonZero: bool
    inRange: bool
      ## `pos + size <= 240`: Layout XML guarantees it; a layout built by hand
      ## may not, and then the load is checked (raising as it did).

  Resolved = object
    entry: RawEntry
    scalar: ScalarKind

  Scalars = array[ScalarKind, seq[RawEntry]] ## The entries of each scalar name.

  GeometryPlan* = object
    ## A file's layout resolved for `geometryValues` and `segyKeys`
    ## (`fields.GeometryReader` is this type).
    order: ByteOrder
    plans: array[GeometryField, seq[Resolved]]
    scalars: Scalars
    timeBasis: int16 ## Binary 3511-3512 (Rev 2 and later; else 0).

  FieldPlan* = object
    ## One name's entries (`fieldValue`).
    entries: seq[Resolved]
    scalars: Scalars

  RawHeaders* = object
    ## A trace's header bytes in the file's byte order: 240 standard bytes,
    ## 240 of Extension 1 (nil when the trace has none), and the
    ## proprietary headers (`propLen` bytes, a multiple of 240).
    std*, ext1*, prop*: ByteBuf
    propLen*: int

func scalarOf(k: LayoutType): ScalarKind =
  case k
  of ltCoor4: skCoor
  of ltElev4: skElev
  of ltTime2: skTime
  of ltSpNum4: skSpNum
  else: skNone

func rawEntry(e: LayoutEntry): RawEntry =
  let sel = if e.extension == "" or e.extension == "SEG00000": hsStd
            elif cmpIgnoreCase(e.extension, "SEG00001") == 0: hsExt1
            else: hsProprietary
  let pos = e.bytePos - 1
  RawEntry(kind: e.kind, pos: pos, sel: sel, ifNonZero: e.ifNonZero,
    name: if sel == hsProprietary: e.extension else: "",
    inRange: pos >= 0 and pos + e.kind.size <= TraceHeaderSize)

func resolveScalars(lay: TraceLayout): Scalars =
  for k in skCoor..skSpNum:
    for e in lay.entriesFor($k): result[k].add rawEntry(e)

func resolveEntries(lay: TraceLayout, name: string): seq[Resolved] =
  for e in lay.entriesFor(name):
    result.add Resolved(entry: rawEntry(e), scalar: scalarOf(e.kind))

func initGeometryPlan*(f: SegyFile): GeometryPlan =
  ## Resolves the file's layout (`initGeometryReader`).
  let lay = f.layoutOf
  result.order = f.byteOrder
  for g in GeometryField:
    result.plans[g] = resolveEntries(lay, $g)
  result.scalars = resolveScalars(lay)
  if f.revision.major >= 2: result.timeBasis = f.binary.timeBasisCode

func planTimeBasis*(p: GeometryPlan): int16 {.inline.} =
  ## The file's time basis code (`fields.timeBasis`).
  p.timeBasis

func planOrder*(p: GeometryPlan): ByteOrder {.inline.} =
  ## The file's byte order.
  p.order

func initFieldPlan*(lay: TraceLayout, name: string): FieldPlan =
  ## The entries of `name` with their scalars (`fieldValue`).
  FieldPlan(entries: resolveEntries(lay, name), scalars: resolveScalars(lay))

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

proc read(b: ByteBuf, e: RawEntry, o: static ByteOrder): float64 {.inline.} =
  # An entry's unscaled value from its 240-byte header at `b`.
  template num(T: typedesc, at: int): untyped =
    (if e.inRange: loadNum[T](b, at, o)
     else: getNum[T](b.toOpenArray(0, TraceHeaderSize - 1), at, o))
  let p = e.pos
  case e.kind
  of ltInt2, ltTime2: float64(num(int16, p))
  of ltInt4, ltCoor4, ltElev4, ltSpNum4: float64(num(int32, p))
  of ltInt8: float64(num(int64, p))
  of ltUInt2: float64(num(uint16, p))
  of ltUInt4, ltLineTrc, ltReelTrc: float64(num(uint32, p))
  of ltUInt8, ltLineTrc8, ltReelTrc8: float64(num(uint64, p))
  of ltIbmFp: ibmToFloat64(num(uint32, p))
  of ltIeee32: float64(num(float32, p))
  of ltIeee64: num(float64, p)
  of ltScale6: float64(num(int32, p)) * pow(10.0, float64(num(int16, p + 4)))

proc rawProprietary(h: RawHeaders, e: RawEntry, o: static ByteOrder,
    value: var float64): bool {.noinline.} =
  # `raw` for an entry of a proprietary header: the first of its name.
  var i = 0
  while i + TraceHeaderSize <= h.propLen:
    let b = cast[ByteBuf](addr h.prop[i])
    if cmpIgnoreCase(headerBlockName(b.toOpenArray(0, TraceHeaderSize - 1)), e.name) == 0:
      value = read(b, e, o)
      return true
    i += TraceHeaderSize
  false

proc raw(h: RawHeaders, e: RawEntry, o: static ByteOrder, value: var float64): bool {.inline.} =
  # Reads an entry's unscaled value; false if its header is absent.
  case e.sel
  of hsStd:
    value = read(h.std, e, o)
    true
  of hsExt1:
    if h.ext1 != nil:
      value = read(h.ext1, e, o)
      true
    else: false
  of hsProprietary: rawProprietary(h, e, o, value)

proc evalPlain(es: openArray[RawEntry], h: RawHeaders, o: static ByteOrder,
    value: var float64): bool =
  # The last applicable entry wins; if-non-zero entries apply only when non-zero.
  result = false
  for e in es:
    var x: float64
    if raw(h, e, o, x) and (not e.ifNonZero or x != 0):
      value = x
      result = true

type ScalarCache = array[ScalarKind, tuple[done, ok: bool, value: float64]]
  # Each scalar of one trace, read on first use.

proc evalResolved(rs: openArray[Resolved], sc: Scalars, h: RawHeaders, o: static ByteOrder,
    cache: var ScalarCache, value: var float64): bool =
  # As `evalPlain`, each value scaled by its scalar. A scalar typed wider
  # than int2 by a Layout stanza may not fit; an unusable one is ignored
  # rather than wrapped.
  result = false
  for r in rs:
    var x: float64
    if raw(h, r.entry, o, x) and (not r.entry.ifNonZero or x != 0):
      if r.scalar != skNone:
        template c: untyped = cache[r.scalar]
        if not c.done:
          c.ok = evalPlain(sc[r.scalar], h, o, c.value)
          c.done = true
        let s = c.value
        if c.ok and s == trunc(s) and s >= -32768.0 and s <= 32767.0:
          x = applyScalar(x, int16(s))
      value = x
      result = true

template eachOrder(order: ByteOrder, o, body: untyped) =
  case order
  of boBig:
    const o = boBig
    body
  of boLittle:
    const o = boLittle
    body
  of boPairSwapped:
    const o = boPairSwapped
    body

proc planValue*(p: FieldPlan, h: RawHeaders, order: ByteOrder, value: var float64): bool =
  ## The value of the plan's name for the trace with headers `h`, scaled;
  ## false if no entry applies.
  var cache: ScalarCache
  eachOrder(order, o):
    result = evalResolved(p.entries, p.scalars, h, o, cache, value)

proc valuesIn(p: GeometryPlan, h: RawHeaders, o: static ByteOrder): array[GeometryField, float64] =
  var cache: ScalarCache
  for g in GeometryField:
    var x: float64
    result[g] = if evalResolved(p.plans[g], p.scalars, h, o, cache, x): x else: NaN

proc geometryValues*(p: GeometryPlan, h: RawHeaders): array[GeometryField, float64] =
  ## The values of `GeometryField` for the trace with headers `h` (NaN where
  ## no entry applies), scaled.
  eachOrder(p.order, o):
    result = valuesIn(p, h, o)

# ----------------------------------------------------------- SEG-Y keys --

func isComponentCode(code: int): bool {.inline.} =
  # SEG-Y trace identification codes naming a sensor component: pressure,
  # multicomponent V/X/I, rotated V/T/R (11-17), electric and magnetic field
  # components (27-38), rotational pitch/roll/yaw (39-41).
  code in 11..17 or code in 27..41

func unset(x: float64): bool {.inline.} = x == 0 or x.isNaN

func civilSeconds(year, day, hour, minute, second: int): float64 =
  # POSIX seconds of a date given as year and day of year, as if it were UTC;
  # NaN when a field is out of range.
  if year notin 1..9999 or day notin 1..366 or hour notin 0..23 or minute notin 0..59 or
      second notin 0..60:
    return NaN
  let jan1 = daysFromCivil(year, 1, 1) * 86400
  float64(jan1 + int64(day - 1) * 86400 + int64(hour) * 3600 + int64(minute) * 60 + second)

proc segyTime(p: GeometryPlan, h: RawHeaders, o: static ByteOrder): float64 =
  # Trace bytes 157-168 (and Ext1 141-144) in their time basis.
  template i16(at: int): int = int(loadNum[int16](h.std, at, o))
  let year = i16(156)
  if year == 0: return NaN
  let code = i16(166)
  let basis = if code != 0: code else: int(p.timeBasis)
  let s = civilSeconds(fullYear(year), i16(158), i16(160), i16(162), i16(164))
  let ns = if h.ext1 != nil: float64(loadNum[int32](h.ext1, 140, o)) * 1e-9 else: 0.0
  case basis
  of 0, 2, 4: s + ns
  of 5: # GPS time of day: as a SEG-D timestamp, which converts with the leap seconds
    if s.isNaN: NaN
    else: timestampToUnix(int64(round((s - float64(GpsEpochUnix)) * 1e6))) + ns
  else: NaN

proc keysIn(p: GeometryPlan, h: RawHeaders, o: static ByteOrder): TraceKeys =
  let g = valuesIn(p, h, o)
  result = initTraceKeys()
  result.record = g[gfFfid]
  result.ensemble = g[gfCdp]
  result.offset = g[gfOffset]
  # Zero means "not set" in practice: a station at exactly (0, 0) or energy
  # source point 0 does not identify anything.
  let sp = if g[gfEspnum].isNaN or g[gfEspnum] == 0: g[gfSp] else: g[gfEspnum]
  if sp != 0: result.srcPoint = sp
  if not (unset(g[gfShtX]) and unset(g[gfShtY])):
    result.srcX = g[gfShtX]
    result.srcY = g[gfShtY]
  if not (unset(g[gfRecX]) and unset(g[gfRecY])):
    result.rcvX = g[gfRecX]
    result.rcvY = g[gfRecY]
  result.srcZ = g[gfSelev]
  result.rcvZ = g[gfRelev]
  if not (unset(g[gfCdpX]) and unset(g[gfCdpY])):
    result.cmpX = g[gfCdpX]
    result.cmpY = g[gfCdpY]
  result.deriveGeometry()
  let channel = loadNum[int32](h.std, 12, o) # traceNumberInField
  if channel > 0: result.channel = float64(channel)
  let code = int(loadNum[int16](h.std, 28, o)) # traceIdCode
  let base = if code >= 0: code and 0x3FFF else: code
  if isComponentCode(base): result.component = uint8(base)
  result.time = segyTime(p, h, o)

proc segyKeys*(p: GeometryPlan, h: RawHeaders): TraceKeys =
  ## The keys of the SEG-Y trace with headers `h` (`keys.traceKeys`).
  eachOrder(p.order, o):
    result = keysIn(p, h, o)

{.pop.}

template withRawHeaders*(order: ByteOrder, t: SegyTrace, h, body: untyped) =
  ## Runs `body` with `h` the `RawHeaders` of decoded trace `t`: its
  ## headers encoded in `order` (the bytes a reader decoded them from).
  var stdBytes, ext1Bytes: array[TraceHeaderSize, byte]
  t.header.encode(stdBytes, order)
  if t.hasExt1: t.ext1.encode(ext1Bytes, order)
  let h = RawHeaders(std: cast[ByteBuf](addr stdBytes[0]),
    ext1: if t.hasExt1: cast[ByteBuf](addr ext1Bytes[0]) else: nil,
    prop: byteBuf(t.proprietary), propLen: t.proprietary.len)
  body
