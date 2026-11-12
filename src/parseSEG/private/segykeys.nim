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

  KeyField = enum
    ## Layout names that only the keys read. The six station names are the
    ## ones the library's own writers store (the `PSEGD001` header of a
    ## converted SEG-D file, `writeGeometry`); no standard layout has them.
    ## The others name fields the keys read at their standard bytes unless
    ## a Layout stanza moved them or put something else there.
    kfShtLine = "sht_line", kfShtPoint = "sht_point", kfShtIndex = "sht_index",
    kfRecLine = "rec_line", kfRecPoint = "rec_point", kfRecIndex = "rec_index",
    kfTrctype = "trctype", kfDelay = "delay", kfYear = "year", kfDay = "day", kfHour = "hour",
    kfMinute = "minute", kfSecond = "second", kfTimebase = "timebase", kfNanosecs = "nanosecs"

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
    fixedUs: float64 ## The binary header's interval of a fixed-length file (Rev 1+), else NaN.
    major: int ## The revision whose rules apply.
    keyPlans: array[KeyField, seq[Resolved]]
    stations: bool ## The layout names a station field (`kfShtLine .. kfRecIndex`).
    stdCode: bool ## `trctype` is where the standard puts it: bytes 29-30 are read.
    stdDelay: bool ## So are `delay` and its scalar: bytes 109-110 and 215-216 are read.
    stdTime: bool ## So are the date and time fields: bytes 157-168 are read.
    nanos: bool ## The layout has Extension 1's `nanosecs` (bytes 141-144).

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

func fixedIntervalUs*(f: SegyFile): float64 =
  ## The sample interval every trace of a fixed-length file (Rev 1 and
  ## later, binary bytes 3503-3504 = 1) has: the binary header's. NaN for
  ## other files, whose traces give their own.
  if f.revision.major >= 1 and f.binary.fixedLengthTraces == 1: f.binary.effectiveSampleInterval
  else: NaN

func isAt(e: RawEntry, pos: int, kind: LayoutType, sel = hsStd): bool =
  e.sel == sel and e.pos == pos and e.kind == kind and not e.ifNonZero

func isAt(rs: openArray[Resolved], pos: int, kind: LayoutType, sel = hsStd): bool =
  # The name has one entry, the plain one at 0-based `pos`.
  rs.len == 1 and rs[0].entry.isAt(pos, kind, sel)

func initGeometryPlan*(f: SegyFile): GeometryPlan =
  ## Resolves the file's layout (`initGeometryReader`).
  let lay = f.layoutOf
  result.order = f.byteOrder
  for g in GeometryField:
    result.plans[g] = resolveEntries(lay, $g)
  result.scalars = resolveScalars(lay)
  if f.revision.major >= 2: result.timeBasis = f.binary.timeBasisCode
  result.fixedUs = fixedIntervalUs(f)
  result.major = int(f.revision.major)
  for k in KeyField:
    result.keyPlans[k] = resolveEntries(lay, $k)
  template plan(k: KeyField): untyped = result.keyPlans[k]
  for k in kfShtLine..kfRecIndex:
    if plan(k).len > 0: result.stations = true
  # Where the layout says what the standard says, the keys load the bytes
  # themselves (one load instead of an entry walk per field); a Layout
  # stanza that moves a field, or uses its bytes for something else, sends
  # that field through the layout.
  result.stdCode = plan(kfTrctype).isAt(28, ltInt2)
  result.stdDelay =
    if result.major >= 1:
      plan(kfDelay).isAt(108, ltTime2) and result.scalars[skTime].len == 1 and
        result.scalars[skTime][0].isAt(214, ltInt2)
    else: plan(kfDelay).isAt(108, ltInt2) # Rev 0: no time scalar
  result.nanos = plan(kfNanosecs).isAt(140, ltInt4, hsExt1)
  result.stdTime = plan(kfYear).isAt(156, ltInt2) and plan(kfDay).isAt(158, ltInt2) and
    plan(kfHour).isAt(160, ltInt2) and plan(kfMinute).isAt(162, ltInt2) and
    plan(kfSecond).isAt(164, ltInt2) and plan(kfTimebase).isAt(166, ltInt2) and
    (result.nanos or plan(kfNanosecs).len == 0)

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

proc valuesIn(p: GeometryPlan, h: RawHeaders, o: static ByteOrder,
    cache: var ScalarCache): array[GeometryField, float64] =
  for g in GeometryField:
    var x: float64
    result[g] = if evalResolved(p.plans[g], p.scalars, h, o, cache, x): x else: NaN

proc geometryValues*(p: GeometryPlan, h: RawHeaders): array[GeometryField, float64] =
  ## The values of `GeometryField` for the trace with headers `h` (NaN where
  ## no entry applies), scaled.
  var cache: ScalarCache
  eachOrder(p.order, o):
    result = valuesIn(p, h, o, cache)

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

proc keyValue(p: GeometryPlan, k: KeyField, h: RawHeaders, o: static ByteOrder,
    cache: var ScalarCache): float64 =
  # The layout's value of `k` for the trace; NaN when no entry applies.
  var x: float64
  if evalResolved(p.keyPlans[k], p.scalars, h, o, cache, x): x else: NaN

func int16Of(x: float64, default: int): int {.inline.} =
  # A layout value as the 16-bit field it stands for; `default` when it is
  # none (NaN, a fraction, out of range: a stanza may type it as anything).
  if x == trunc(x) and x >= -32768.0 and x <= 32767.0: int(x) else: default

proc segyTime(p: GeometryPlan, h: RawHeaders, o: static ByteOrder,
    cache: var ScalarCache): float64 =
  # The date and time fields (standard: trace bytes 157-168 and Ext1
  # 141-144) in their time basis.
  var year, day, hour, minute, second, code: int
  var ns = 0.0
  if p.stdTime:
    template i16(at: int): int = int(loadNum[int16](h.std, at, o))
    year = i16(156)
    if year == 0: return NaN
    (day, hour, minute, second, code) = (i16(158), i16(160), i16(162), i16(164), i16(166))
    if p.nanos and h.ext1 != nil: ns = float64(loadNum[int32](h.ext1, 140, o)) * 1e-9
  else:
    # A Layout stanza moved a field or reuses its bytes: a field the layout
    # no longer has makes the time unknown (-1 is no day, hour, ...).
    template part(k: KeyField, default: int): int = int16Of(keyValue(p, k, h, o, cache), default)
    year = part(kfYear, 0)
    if year == 0: return NaN
    (day, hour, minute, second) = (part(kfDay, -1), part(kfHour, -1), part(kfMinute, -1),
      part(kfSecond, -1))
    code = part(kfTimebase, 0)
    let x = keyValue(p, kfNanosecs, h, o, cache)
    if not x.isNaN: ns = x * 1e-9
  let basis = if code != 0: code else: int(p.timeBasis)
  let s = civilSeconds(fullYear(year), day, hour, minute, second)
  case basis
  of 0, 2, 4: s + ns
  of 5: # GPS time of day: as a SEG-D timestamp, which converts with the leap seconds
    if s.isNaN: NaN
    else: timestampToUnix(int64(round((s - float64(GpsEpochUnix)) * 1e6))) + ns
  else: NaN

proc intervalIn(h: RawHeaders, o: static ByteOrder, fixedUs: float64): float64 {.inline.} =
  if not fixedUs.isNaN: return fixedUs
  if h.ext1 != nil:
    let x = loadNum[float64](h.ext1, 144, o) # Ext1 bytes 145-152
    if x != 0 and not x.isNaN: return x
  float64(loadNum[uint16](h.std, 116, o)) # bytes 117-118

proc segyIntervalUs*(h: RawHeaders, order: ByteOrder, fixedUs: float64): float64 =
  ## The sample interval of the SEG-Y trace with headers `h`, in µs:
  ## `fixedUs` when it is not NaN (`fixedIntervalUs`), else Ext1 bytes
  ## 145-152 when non-zero, else trace bytes 117-118. `sampleIntervalUs`
  ## and `TraceKeys.intervalUs` both use it.
  eachOrder(order, o):
    result = intervalIn(h, o, fixedUs)

proc t0In(h: RawHeaders, o: static ByteOrder, major: int): float64 {.inline.} =
  # Delay recording time (bytes 109-110) in ms; the time scalar (215-216)
  # applies from Rev 1 on, Rev 0 left those bytes unassigned.
  let delay = loadNum[int16](h.std, 108, o)
  if major >= 1: applyScalar(delay, loadNum[int16](h.std, 214, o)) else: float64(delay)

proc segyStartTimeMs*(h: RawHeaders, order: ByteOrder, major: int): float64 =
  ## The time of sample 0 of the SEG-Y trace with headers `h`, in ms
  ## (`TraceKeys.t0Ms`), for a file of revision `major`.
  eachOrder(order, o):
    result = t0In(h, o, major)

func segyStatus*(code: int16, major: int): TraceStatus =
  ## The status a SEG-Y trace identification code gives (`TraceStatus`).
  ## Rev 0 defines codes 1-8, Rev 1 codes 1-22 (23 and up are optional
  ## use), Rev 2 codes 1-41 and adds 16384 to interpolated traces.
  let base = if code >= 0 and major >= 2: int(code) and 0x3FFF else: int(code)
  let last = if major == 0: 8 elif major == 1: 22 else: 41
  if base < 1 or base > last: return tsUnknown
  case base
  of 1, 11..17, 25, 27..41: tsLive # seismic, sensors, depth-domain seismic, EM, rotational
  of 2, 3: tsDead
  else: tsAuxiliary # time break ... water break, gun signatures, vibrator, pairs, gravity

func sourcePoint(espnum, sp: float64): float64 {.inline.} =
  # The energy source point (bytes 17-20, an integer) or the scaled
  # shotpoint (197-202): the shotpoint when there is no energy source
  # point, and when it is that point with its fraction (99.5 beside 100, as
  # the library's converters write a fractional source point). Any other
  # shotpoint is a number of its own (a 2-D line's shotpoint), and the energy
  # source point stands.
  if unset(espnum): sp
  elif not unset(sp) and round(sp) == espnum: sp
  else: espnum

proc stationsIn(p: GeometryPlan, h: RawHeaders, o: static ByteOrder, cache: var ScalarCache,
    k: var TraceKeys) {.noinline.} =
  # The stations a layout names (`sht_line` ... `rec_index`): a converted
  # SEG-D file keeps its source and receiver stations there. A line and a
  # point that are both 0 or missing are no station; otherwise each replaces
  # the key when the header gives it (not NaN), an index when it is not 0.
  template station(lineF, pointF, indexF: KeyField, line, point, index: untyped) =
    let l = keyValue(p, lineF, h, o, cache)
    let pt = keyValue(p, pointF, h, o, cache)
    if not (unset(l) and unset(pt)):
      if not l.isNaN: line = l
      if not pt.isNaN: point = pt
    let i = int16Of(keyValue(p, indexF, h, o, cache), 0)
    if i != 0: index = int16(i)
  station(kfShtLine, kfShtPoint, kfShtIndex, k.srcLine, k.srcPoint, k.srcIndex)
  station(kfRecLine, kfRecPoint, kfRecIndex, k.rcvLine, k.rcvPoint, k.rcvIndex)

proc keysIn(p: GeometryPlan, h: RawHeaders, o: static ByteOrder): TraceKeys =
  var cache: ScalarCache
  let g = valuesIn(p, h, o, cache)
  result = initTraceKeys()
  result.record = g[gfFfid]
  result.ensemble = g[gfCdp]
  result.offset = g[gfOffset]
  # Zero means "not set" in practice: a station at exactly (0, 0) or energy
  # source point 0 does not identify anything.
  let sp = sourcePoint(g[gfEspnum], g[gfSp])
  if sp != 0: result.srcPoint = sp
  if p.stations: stationsIn(p, h, o, cache, result)
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
  # The channel through the layout, as `geometry` reads it: a Layout stanza
  # may keep something else in bytes 13-16 (the Inglewood sample: the inline
  # number), and then the trace has no channel number.
  let channel = g[gfChan]
  if channel > 0: result.channel = channel
  # The trace identification code (standard: bytes 29-30).
  let code = if p.stdCode: loadNum[int16](h.std, 28, o)
             else: int16(int16Of(keyValue(p, kfTrctype, h, o, cache), 0))
  let base = if code >= 0: int(code) and 0x3FFF else: int(code)
  if isComponentCode(base): result.component = uint8(base)
  result.traceCode = code
  result.status = segyStatus(code, p.major)
  result.time = segyTime(p, h, o, cache)
  # The delay recording time (standard: bytes 109-110 and the time scalar).
  result.t0Ms = if p.stdDelay: t0In(h, o, p.major) else: keyValue(p, kfDelay, h, o, cache)
  # The sample interval is not a layout value: with the sample count it is
  # what the reader walks the file by, at bytes 115-118 (and Extension 1's),
  # whatever a stanza calls them (Inglewood retypes them as signed). The
  # sampled index, `sampleIntervalUs` and the writers read the same bytes,
  # and the key equals `sampleIntervalUs`.
  result.intervalUs = intervalIn(h, o, p.fixedUs)
  if not unset(g[gfIline]): result.inline = g[gfIline]
  if not unset(g[gfXline]): result.crossline = g[gfXline]

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
