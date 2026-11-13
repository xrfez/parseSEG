## Explicit write-back of joined survey geometry (task 10.5).
##
## `applySurvey` changes only the in-memory `TraceKeys`. The calls here
## persist them, and nothing else does (owner rule: files change only on an
## explicit write):
##
## - `writeGeometry(editor, ix, fields)` writes them in place through the
##   journaled `HeaderEditor`: same-size header fields only, every change
##   journaled first, so `rollbackJournal` undoes it;
## - `copyWithGeometry` writes a copy of the file (same standard and layout)
##   with the geometry, `convertWithGeometry` a converted SEG-Y file (new
##   files: written without a journal, and dropped whole on a failure);
## - `geometryChanges` only reports what would change.
##
## A value is written when the joined key differs from what the trace's
## headers hold (as `traceKeys` reads them); unknown (NaN) values are never
## written. Midpoints and offsets follow the coordinates: they are written
## only for traces whose source or receiver X/Y change. Values with no slot
## in the file, or too large for theirs, are counted (`unwritable`) and
## reported in the log, one warning per kind, never dropped silently.
##
## The counts (`GeometryChanges`) say what the headers hold differently
## afterwards, per kind of value: a source point 99.5 written into an
## integer field that already holds 100 is no change. A "rounded" warning
## is given per kind for the traces where a value was written and none of
## its fields holds it exactly (the point 99.5 in `espnum` is not reported
## while `sp`, with its scalar, holds 99.5).
##
## Where the values go:
##
## | File | Slots |
## |---|---|
## | SEG-Y | through the file's layout (`layoutOf`): `sht_x`/`sht_y`, `rec_x`/`rec_y`, `cdp_x`/`cdp_y` (`coor4`, with the coordinate scalar `co_scal`), `selev`/`relev` (`elev4`, `ed_scal`), `offset`; the source point in `espnum` and `sp` (`spnum4`, `sp_scal`); Rev 2 Trace Header Extension 1 `ieee64` copies where they are in use (non-zero); line, point and index in `sht_line`, `sht_point`, `sht_index`, `rec_line`, `rec_point`, `rec_index` where a Layout stanza defines them (e.g. the `PSEGD001` header `convertFile` writes) |
## | SEG-D Rev 1/2 | THE#1 receiver line, point and point index (the extended fixed-point fields when the integer ones are `FFFFFF` or cannot hold the value); no coordinate fields |
## | SEG-D Rev 3 | THE#1 as above; the receiver's and the source's Position blocks and the source's Source Description block, only where they already are in the trace header extensions |
##
## The SEG-Y coordinate scalar: the file's own when it holds every value of
## the trace's `coor4` fields exactly in 4 bytes, else the coarsest of 1,
## -10, ..., -10000 that does, else the finest that fits (a precision
## warning), else 10 ... 10000 (a warning); values too large even for that
## are refused (an error). Coordinates the survey does not change are
## rescaled with it, so they keep their values. Elevations and `ed_scal`,
## and the source point and `sp_scal`, work the same way.
##
## Record-level values are not written per trace: the source of a SEG-D
## Rev 1/2 record (General Header #N) and a Rev 3 source described only in
## the general header blocks. SEG-2 files are refused for now.

import std/[math, options, os, strutils]
import ../common/[endians, errors, diagnostics, ibmfloat, outputfile, progress]
import ../segy/[layout, traceheader, reader as segyreader, fields]
import ../segd/[reader as segdreader]
import ../model/[traceindex, keys, edit]
import ../convert
import ./join
import ../private/[checks, coordscalar, progressticker, segykeys]

export join

type
  GeometryChanges* = object
    ## What `writeGeometry` changed (or `geometryChanges` would change), in
    ## traces per kind of value: a kind counts for a trace when its headers
    ## hold another value afterwards.
    traces*: int ## Traces with at least one changed value.
    sourceXy*, receiverXy*: int ## Traces whose source / receiver X/Y change.
    sourceZ*, receiverZ*: int ## Traces whose source / receiver elevation changes.
    midpoints*, offsets*: int ## Traces whose midpoint / offset changes.
    sourceStations*, receiverStations*: int
      ## Traces whose source / receiver line, point or index change.
    unwritable*: int
      ## Values (one per kind and trace) the file has no slot for, or that
      ## do not fit theirs; the log says which.

  GeometryCopy* = object
    ## The outcome of `copyWithGeometry`.
    changes*: GeometryChanges ## What was written into the copy.
    log*: DiagLog
      ## Problems, with an info summary; fatal when nothing usable was
      ## written (`dstPath` is then untouched).

  Value = enum
    vSrcXY = "source X/Y", vRcvXY = "receiver X/Y", vSrcZ = "source elevation",
    vRcvZ = "receiver elevation", vCmp = "midpoint", vOffset = "offset",
    vSrcStation = "source station", vRcvStation = "receiver station"

  Name = enum
    ## The layout names the SEG-Y planner reads or writes.
    nShtX = "sht_x", nShtY = "sht_y", nRecX = "rec_x", nRecY = "rec_y", nCdpX = "cdp_x",
    nCdpY = "cdp_y", nSelev = "selev", nRelev = "relev", nOffset = "offset",
    nEspnum = "espnum", nSp = "sp", nShtLine = "sht_line", nShtPoint = "sht_point",
    nShtIndex = "sht_index", nRecLine = "rec_line", nRecPoint = "rec_point",
    nRecIndex = "rec_index", nCoorUnit = "coorunit", nCoScal = "co_scal",
    nEdScal = "ed_scal", nSpScal = "sp_scal"

  Slot = object
    ## A layout entry resolved for the planner, once per file: looking the
    ## names up in the layout per value and trace was 37 % of a write-back.
    at: int         ## 0-based byte within its 240-byte header.
    kind: LayoutType
    ifNonZero: bool
    header: int     ## Indexes `Planner.headers` and `Planner.bases`.
    protected: bool ## Over bytes that size the trace or name a header: never written.
    name: int       ## `ord` of its `Name`; -1 for a name the planner does not set.

  GroupSlot = object
    ## A scaled field of the trace being rewritten (`writeScaledGroup`).
    at: int
    up: int ## Index into `Planner.ups`, -1 for an unchanged field.

  Planner = object
    ## One pass over a file's traces: what changes, and the reports.
    fields: GeometryFields
    path: string
    order: ByteOrder
    lay: TraceLayout   ## SEG-Y: the file's effective layout.
    gr: GeometryReader ## SEG-Y: for the current keys.
    headers: seq[string]
      ## SEG-Y: the names of the 240-byte headers the layout's entries live
      ## in: the standard one, Extension 1, then proprietary ones.
    bases: seq[int]
      ## SEG-Y: where each of `headers` starts in the current trace's header
      ## bytes, -1 when the trace has none (`locate`).
    byName: array[Name, seq[Slot]]       ## SEG-Y: each name's entries, in layout order.
    byKind: array[LayoutType, seq[Slot]] ## SEG-Y: every entry of each scaled kind.
    kindNames: array[LayoutType, set[Name]] ## SEG-Y: the names with an entry of each scaled kind.
    ups: seq[Update]      ## The current trace's updates (kept between traces: no allocation).
    group: seq[GroupSlot] ## `writeScaledGroup`'s fields, with their values in `vals`.
    vals: seq[float64]
    changes: GeometryChanges
    noSlot: array[Value, int]
    noSlotFirst: array[Value, int]
    noSlotWhy: array[Value, string]
    refused: int     ## Values refused for their range (errors, capped).
    rounded: array[Value, int]
    roundedFirst: array[Value, int]
    log: DiagLog

  Update = object
    ## A SEG-Y layout name to set.
    name: Name
    value: float64
    before: float64 ## What the name's field held (`slotValue`), NaN without one.
    what: Value
    part: char     ## Values of one kind and part need only one field: 'p' point, ...
    written: bool  ## Handled: written, or refused (`refused`, reported).
    refused: bool
    exact: bool    ## A field written holds the value exactly.
    rounded: bool  ## A field written holds it rounded.

const
  ScaledKinds = {ltCoor4, ltElev4, ltSpNum4} ## The 4-byte kinds stored under a scalar.
  MaxRefusals = 5 ## Range errors logged one by one; the rest are counted.
  StdProtected = [(114, 2)] ## Std header bytes (0-based, length) never written: the sample count.
  Ext1Protected = [(136, 4), (156, 4), (232, 8)] ## Ext1 sample count, header count, flags, name.
  PropProtected = [(232, 8)] ## A proprietary header's name.

func known(x: float64): bool {.inline.} = not x.isNaN

func differs(new, cur: float64): bool =
  # A known value that the header does not hold already.
  if new.isNaN: false
  elif cur.isNaN: true
  else: abs(new - cur) > 1e-9 * max(1.0, abs(new))

func stationDiffers(new, cur: float64): bool =
  # Stations match at 1/100 (see `stationKey`).
  new.known and (cur.isNaN or round(new * 100) != round(cur * 100))

func same(a, b: float64): bool {.inline.} = a == b or (a.isNaN and b.isNaN)

proc unwritable(p: var Planner, v: Value, trace: int, why: string) =
  # A value with no slot in the trace: counted, reported once per kind.
  if p.noSlot[v] == 0:
    p.noSlotFirst[v] = trace
    p.noSlotWhy[v] = why
  inc p.noSlot[v]
  inc p.changes.unwritable

proc refuse(p: var Planner, v: Value, trace: int, msg: string) =
  # A value its slot cannot hold: an error (the first few logged).
  inc p.refused
  inc p.changes.unwritable
  if p.refused <= MaxRefusals:
    p.log.report(sevError, dcValidation, $v & ": " & msg & "; not written",
      loc = Location(file: p.path, trace: trace))

proc noteRounded(p: var Planner, v: Value, trace: int) =
  if p.rounded[v] == 0: p.roundedFirst[v] = trace
  inc p.rounded[v]

proc summarize(p: var Planner) =
  let loc = Location(file: p.path)
  for v in Value:
    if p.noSlot[v] > 0:
      p.log.report(sevWarning, dcValidation, $v & ": " & p.noSlotWhy[v] & "; not written in " &
        $p.noSlot[v] & " traces (the first is trace " & $p.noSlotFirst[v] & ")", loc = loc)
    if p.rounded[v] > 0:
      p.log.report(sevWarning, dcValidation, $v & ": rounded to what the field holds in " &
        $p.rounded[v] & " traces (the first is trace " & $p.roundedFirst[v] &
        "); the survey values are more precise", loc = loc)
  if p.refused > MaxRefusals:
    p.log.report(sevInfo, dcValidation, $(p.refused - MaxRefusals) &
      " more values that do not fit their fields were not logged", loc = loc)

proc count(p: var Planner, changed: set[Value]) =
  if changed.card > 0: inc p.changes.traces
  if vSrcXY in changed: inc p.changes.sourceXy
  if vRcvXY in changed: inc p.changes.receiverXy
  if vSrcZ in changed: inc p.changes.sourceZ
  if vRcvZ in changed: inc p.changes.receiverZ
  if vCmp in changed: inc p.changes.midpoints
  if vOffset in changed: inc p.changes.offsets
  if vSrcStation in changed: inc p.changes.sourceStations
  if vRcvStation in changed: inc p.changes.receiverStations

func `$`*(c: GeometryChanges): string =
  ## A one-line summary: traces changed per kind, and the values with no slot.
  $c.traces & " traces (source X/Y " & $c.sourceXy & ", receiver X/Y " & $c.receiverXy &
    ", elevations " & $c.sourceZ & "/" & $c.receiverZ & ", midpoints " & $c.midpoints &
    ", offsets " & $c.offsets & ", stations " & $c.sourceStations & "/" &
    $c.receiverStations & "); " & $c.unwritable & " values cannot be written"

# ------------------------------------------------------------------ SEG-Y --

func scalarNameOf(k: LayoutType): Name =
  # The scalar of a scaled 4-byte kind (`ScaledKinds`).
  case k
  of ltCoor4: nCoScal
  of ltElev4: nEdScal
  else: nSpScal

func protectedBytes(header, at, size: int): bool =
  # Bytes `at ..< at + size` of a header (0 the standard one, 1 Extension 1,
  # else a proprietary one) size the trace or name the header.
  template check(list: untyped) =
    for (p, n) in list:
      if at < p + n and p < at + size: return true
  case header
  of 0: check(StdProtected)
  of 1: check(Ext1Protected)
  else: check(PropProtected)
  false

proc resolveLayout(p: var Planner) =
  # The layout's entries under the names and scaled kinds the planner uses,
  # in layout order (for a repeated name the last applicable entry wins).
  p.headers = @["", "SEG00001"]
  for e in p.lay.entries:
    var name = -1
    for n in Name:
      if e.name == $n: name = ord(n)
    if name >= 0 or e.kind in ScaledKinds:
      var h = -1
      if e.extension.len == 0 or cmpIgnoreCase(e.extension, "SEG00000") == 0: h = 0
      else:
        for i in 1 ..< p.headers.len:
          if cmpIgnoreCase(p.headers[i], e.extension) == 0: h = i
        if h < 0:
          h = p.headers.len
          p.headers.add e.extension
      let s = Slot(at: e.bytePos - 1, kind: e.kind, ifNonZero: e.ifNonZero, header: h,
        protected: protectedBytes(h, e.bytePos - 1, e.kind.size), name: name)
      if name >= 0:
        p.byName[Name(name)].add s
        if e.kind in ScaledKinds: p.kindNames[e.kind].incl Name(name)
      if e.kind in ScaledKinds: p.byKind[e.kind].add s
  p.bases = newSeq[int](p.headers.len)

proc initPlanner(ix: TraceIndex, path: string, fields: GeometryFields): Planner =
  result = Planner(fields: fields, path: path)
  if ix.kind == skSegy:
    result.order = ix.segy.byteOrder
    result.lay = ix.segy.layoutOf
    result.gr = initGeometryReader(ix.segy)
    result.resolveLayout()

proc locate(p: var Planner, buf: openArray[byte]) =
  # Where each 240-byte header of `headers` starts in this trace's header
  # bytes; -1 when the trace has no such header.
  let extended = buf.len >= 2 * TraceHeaderSize
  p.bases[0] = 0
  p.bases[1] = if extended: TraceHeaderSize else: -1
  for h in 2 ..< p.headers.len:
    p.bases[h] = -1
    if extended:
      var i = 2 * TraceHeaderSize
      while p.bases[h] < 0 and i + TraceHeaderSize <= buf.len:
        if cmpIgnoreCase(headerBlockName(buf.toOpenArray(i, i + TraceHeaderSize - 1)),
            p.headers[h]) == 0:
          p.bases[h] = i
        i += TraceHeaderSize

proc readRaw(buf: openArray[byte], at: int, k: LayoutType, order: ByteOrder): float64 =
  case k
  of ltInt2, ltTime2: float64(getNum[int16](buf, at, order))
  of ltInt4, ltCoor4, ltElev4, ltSpNum4: float64(getNum[int32](buf, at, order))
  of ltInt8: float64(getNum[int64](buf, at, order))
  of ltUInt2: float64(getNum[uint16](buf, at, order))
  of ltUInt4, ltLineTrc, ltReelTrc: float64(getNum[uint32](buf, at, order))
  of ltUInt8, ltLineTrc8, ltReelTrc8: float64(getNum[uint64](buf, at, order))
  of ltIbmFp: ibmToFloat64(getNum[uint32](buf, at, order))
  of ltIeee32: float64(getNum[float32](buf, at, order))
  of ltIeee64: getNum[float64](buf, at, order)
  of ltScale6:
    float64(getNum[int32](buf, at, order)) * pow(10.0, float64(getNum[int16](buf, at + 4, order)))

proc writeRaw(buf: var openArray[byte], at: int, k: LayoutType, v: float64, order: ByteOrder,
    rounded: var bool): string =
  # Encodes `v` (unscaled) as `k`; "" when written, else why not. Integer
  # kinds round (`rounded` tells).
  template int(T: typedesc) =
    let r = round(v)
    if not (r >= float64(low(T)) and r <= float64(high(T))):
      return $v & " does not fit a " & $k & " field"
    if r != v: rounded = true
    putNum(buf, at, T(r), order)
  case k
  of ltInt2, ltTime2: int(int16)
  of ltInt4, ltCoor4, ltElev4, ltSpNum4: int(int32)
  of ltUInt2: int(uint16)
  of ltUInt4, ltLineTrc, ltReelTrc: int(uint32)
  of ltInt8:
    if not (abs(v) < 9.2e18): return $v & " does not fit an int8 field"
    if round(v) != v: rounded = true
    putNum(buf, at, int64(round(v)), order)
  of ltUInt8, ltLineTrc8, ltReelTrc8:
    if not (v >= 0 and v < 1.8e19): return $v & " does not fit a " & $k & " field"
    if round(v) != v: rounded = true
    putNum(buf, at, uint64(round(v)), order)
  of ltIbmFp:
    if not (abs(v) <= float64(high(float32))): return $v & " does not fit an IBM float field"
    if float64(float32(v)) != v: rounded = true
    putNum(buf, at, float32ToIbm(float32(v)), order)
  of ltIeee32:
    if not (abs(v) <= float64(high(float32))): return $v & " does not fit an ieee32 field"
    if float64(float32(v)) != v: rounded = true
    putNum(buf, at, float32(v), order)
  of ltIeee64: putNum(buf, at, v, order)
  of ltScale6: return "scale6 fields are not written"
  ""

proc scalarOf(p: Planner, buf: openArray[byte], name: Name, present: var bool): int16 =
  # The trace's scalar `name` (the last applicable entry), 1 for 0 or none.
  result = 1
  present = false
  for s in p.byName[name]:
    let b = p.bases[s.header]
    if b >= 0:
      let x = readRaw(buf, b + s.at, s.kind, p.order)
      if (not s.ifNonZero or x != 0) and x == trunc(x) and x >= -32768 and x <= 32767:
        present = true
        result = if x == 0: 1'i16 else: int16(x)

proc slotValue(p: Planner, buf: openArray[byte], name: Name): float64 =
  # The value of layout name `name` as `fieldValue` reads it; NaN if none.
  result = NaN
  for s in p.byName[name]:
    let b = p.bases[s.header]
    if b >= 0:
      var x = readRaw(buf, b + s.at, s.kind, p.order)
      if not s.ifNonZero or x != 0:
        if s.kind in ScaledKinds:
          var present: bool
          x = applyScalar(x, p.scalarOf(buf, scalarNameOf(s.kind), present))
        result = x

proc writeScaledGroup(p: var Planner, buf: var seq[byte], trace: int, kind: LayoutType) =
  # Rewrites every `kind` field of the trace with one scalar chosen for the
  # new values (`p.ups`) and the unchanged ones.
  var wanted = false
  for u in p.ups:
    if u.name in p.kindNames[kind]: wanted = true
  if not wanted: return
  let sn = scalarNameOf(kind)
  var present: bool
  let s0 = p.scalarOf(buf, sn, present)
  p.group.setLen 0
  p.vals.setLen 0
  var any = false
  for s in p.byKind[kind]:
    let b = p.bases[s.header]
    if b >= 0 and not s.protected:
      let at = b + s.at
      var up = -1
      if s.name >= 0:
        for i, u in p.ups:
          if ord(u.name) == s.name: up = i
      if up >= 0: any = true
      let value = if up >= 0: p.ups[up].value
                  else: applyScalar(readRaw(buf, at, kind, p.order), s0)
      p.group.add GroupSlot(at: at, up: up)
      p.vals.add value
  if not any: return
  var exact: bool
  var s = s0
  if present:
    s = chooseScalar(p.vals, s0, exact)
  else:
    exact = exactScalar(p.vals, s0)
    if not fitsScalar(p.vals, s0): s = 0
  if s == 0:
    for i in 0 ..< p.group.len:
      let up = p.group[i].up
      if up >= 0:
        p.refuse(p.ups[up].what, trace, $p.ups[up].value & " is too large for a 4-byte " &
          "SEG-Y field with any coordinate scalar (" & $p.ups[up].name & ")")
        p.ups[up].written = true
        p.ups[up].refused = true # reported
    return
  for i in 0 ..< p.group.len:
    let raw = rawOf(p.vals[i], s)
    putNum(buf, p.group[i].at, int32(round(raw)), p.order)
    let up = p.group[i].up
    if up >= 0:
      p.ups[up].written = true
      # As `exactScalar`: exact to 1e-4 of the stored unit.
      if exact or abs(raw - round(raw)) <= 1e-4: p.ups[up].exact = true
      else: p.ups[up].rounded = true
  if present and s != s0:
    for sl in p.byName[sn]:
      let b = p.bases[sl.header]
      if b >= 0 and not sl.protected:
        var r: bool
        discard writeRaw(buf, b + sl.at, sl.kind, float64(s), p.order, r)

proc writeUnscaled(p: var Planner, buf: var seq[byte], trace, up: int) =
  # The entries of update `up`'s name that are not scaled 4-byte fields; an
  # `ifNonZero` entry only while it is in use.
  let name = p.ups[up].name
  for i in 0 ..< p.byName[name].len:
    let s = p.byName[name][i]
    if s.kind notin ScaledKinds:
      let b = p.bases[s.header]
      if b >= 0 and not s.protected:
        let at = b + s.at
        if not s.ifNonZero or readRaw(buf, at, s.kind, p.order) != 0:
          var r = false
          let err = writeRaw(buf, at, s.kind, p.ups[up].value, p.order, r)
          if err.len > 0:
            p.refuse(p.ups[up].what, trace, err & " (" & $name & ")")
            p.ups[up].refused = true
          elif r:
            p.ups[up].rounded = true
          else:
            p.ups[up].exact = true
          p.ups[up].written = true

proc currentSegyKeys(p: Planner, buf: openArray[byte]): TraceKeys =
  # The keys of the trace with header bytes `buf`, straight from the bytes
  # as the index reads them.
  let extra = buf.len - 2 * TraceHeaderSize
  let h = RawHeaders(std: cast[ByteBuf](addr buf[0]),
    ext1: if extra >= 0: cast[ByteBuf](addr buf[TraceHeaderSize]) else: nil,
    prop: if extra > 0: cast[ByteBuf](addr buf[2 * TraceHeaderSize]) else: nil,
    propLen: max(extra, 0))
  segyKeys(p.gr, h)

proc planSegy(p: var Planner, trace: int, k: TraceKeys, buf: var seq[byte]): set[Value] =
  if buf.len < TraceHeaderSize: return
  p.locate(buf)
  let cur = p.currentSegyKeys(buf)
  p.ups.setLen 0
  template up(n: Name, x: float64, w: Value, pt = 'v') =
    p.ups.add Update(name: n, value: x, what: w, part: pt, before: p.slotValue(buf, n))
  let f = p.fields
  let srcXY = f.sourceXy and k.hasSourceXY and
    (differs(k.srcX, cur.srcX) or differs(k.srcY, cur.srcY))
  let rcvXY = f.receiverXy and k.hasReceiverXY and
    (differs(k.rcvX, cur.rcvX) or differs(k.rcvY, cur.rcvY))
  if srcXY:
    up(nShtX, k.srcX, vSrcXY, 'x')
    up(nShtY, k.srcY, vSrcXY, 'y')
  if rcvXY:
    up(nRecX, k.rcvX, vRcvXY, 'x')
    up(nRecY, k.rcvY, vRcvXY, 'y')
  if srcXY or rcvXY:
    if p.slotValue(buf, nCoorUnit) == 0: # unset: the coordinates are lengths
      up(nCoorUnit, 1, if srcXY: vSrcXY else: vRcvXY, 'u')
    if f.midpoints and k.cmpX.known and k.cmpY.known and
        (differs(k.cmpX, cur.cmpX) or differs(k.cmpY, cur.cmpY)):
      up(nCdpX, k.cmpX, vCmp, 'x')
      up(nCdpY, k.cmpY, vCmp, 'y')
    if f.offsets and differs(k.offset, cur.offset): up(nOffset, k.offset, vOffset)
  if f.elevations:
    if differs(k.srcZ, cur.srcZ): up(nSelev, k.srcZ, vSrcZ)
    if differs(k.rcvZ, cur.rcvZ): up(nRelev, k.rcvZ, vRcvZ)
  if f.stations:
    if stationDiffers(k.srcPoint, cur.srcPoint):
      up(nEspnum, k.srcPoint, vSrcStation, 'p')
      up(nSp, k.srcPoint, vSrcStation, 'p')
    # A part the headers already hold (as the keys read them, e.g. the
    # point in espnum) is no change, and needs no other field.
    template station(n: Name, x, held: float64, w: Value, pt: char) =
      let slot = p.slotValue(buf, n)
      if stationDiffers(x, held) and stationDiffers(x, slot):
        p.ups.add Update(name: n, value: x, what: w, part: pt, before: slot)
    station(nShtLine, k.srcLine, cur.srcLine, vSrcStation, 'l')
    station(nShtPoint, k.srcPoint, cur.srcPoint, vSrcStation, 'p')
    station(nRecLine, k.rcvLine, cur.rcvLine, vRcvStation, 'l')
    station(nRecPoint, k.rcvPoint, cur.rcvPoint, vRcvStation, 'p')
    if k.srcIndex != 0:
      station(nShtIndex, float64(k.srcIndex), float64(cur.srcIndex), vSrcStation, 'i')
    if k.rcvIndex != 0:
      station(nRecIndex, float64(k.rcvIndex), float64(cur.rcvIndex), vRcvStation, 'i')
  if p.ups.len == 0: return
  for kind in ScaledKinds: p.writeScaledGroup(buf, trace, kind)
  for i in 0 ..< p.ups.len: p.writeUnscaled(buf, trace, i)
  # What changed is what the fields hold differently now: a value that
  # rounds to the one already there (99.5 into an espnum of 100) is no
  # change. Values with no slot: one report per kind and trace. A part (the
  # point, the line, ...) needs only one of its fields (espnum, sp,
  # sht_point).
  var missing: set[Value]
  for u in p.ups:
    if u.part == 'u': discard # the units follow the coordinates
    elif u.written:
      if not u.refused and not same(u.before, p.slotValue(buf, u.name)): result.incl u.what
    else:
      var done = false
      for o in p.ups:
        if o.written and o.what == u.what and o.part == u.part: done = true
      if not done: missing.incl u.what
  # Rounded: a part written whose fields all hold it rounded (once per kind
  # and trace).
  var lossy: set[Value]
  for u in p.ups:
    if u.rounded and u.what in result:
      var held = false
      for o in p.ups:
        if o.exact and o.what == u.what and o.part == u.part: held = true
      if not held: lossy.incl u.what
  for v in lossy: p.noteRounded(v, trace)
  for v in missing:
    p.unwritable(v, trace, case v
      of vSrcStation, vRcvStation: "the file's layout has no field for the line, point or " &
        "index (a Layout stanza can add sht_line, rec_line, ...)"
      of vCmp: "the file's layout has no CDP X/Y (SEG-Y Rev 0)"
      else: "the file's layout has no field for it")

# ------------------------------------------------------------------ SEG-D --

func isSourceBlock(t: uint8): bool {.inline.} = t in {0x15'u8..0x19'u8, 0x1F'u8}

func finite(x: float64): bool {.inline.} = not x.isNaN and x != Inf and x != -Inf

proc setStation(num: var int32, ext: var float64, v: float64) =
  # A Rev 1/2/3 THE#1 line or point: the 3-byte integer while the file uses
  # it and the value fits, else `FFFFFF` and the extended fixed-point field.
  if num != -1 and v == round(v) and v >= -0x80_0000 and v <= 0x7F_FFFF and v != -1:
    num = int32(v)
  else:
    num = -1
    ext = v

proc writeExt1[T](p: var Planner, buf: var seq[byte], trace: int, k: TraceKeys): bool =
  # The receiver station into THE#1 (bytes 21-52 of the trace header area).
  var e = decodeBlock[T](buf.toOpenArray(SegdTraceHeaderSize, SegdTraceHeaderSize + 31))
  if k.rcvLine.known: setStation(e.receiverLineNumber, e.extReceiverLineNumber, k.rcvLine)
  if k.rcvPoint.known: setStation(e.receiverPointNumber, e.extReceiverPointNumber, k.rcvPoint)
  if k.rcvIndex != 0:
    if k.rcvIndex notin -128'i16..127'i16:
      p.refuse(vRcvStation, trace, "point index " & $k.rcvIndex & " does not fit THE#1 byte 7")
      return false
    e.receiverPointIndex = int8(k.rcvIndex)
  var blk: array[SegdBlockSize, byte]
  try:
    e.encode(blk) # all or nothing: a refused value leaves `buf` alone
  except SegFormatError as x:
    p.refuse(vRcvStation, trace, x.msg)
    return false
  for i in 0..<SegdBlockSize: buf[SegdTraceHeaderSize + i] = blk[i]
  true

proc positionBlocks(area: openArray[byte], rcv, src: var int) =
  # The receiver's and the source's Position block in a Rev 3 trace's
  # extension area (as `traceKeys` reads them: a Position block describes
  # the block it follows); the first usable one of each, else the first.
  rcv = -1
  src = -1
  var rcvUsable, srcUsable = false
  var after = 0'u8
  for at, bt in blocks(area):
    if bt == 0x50:
      if after != 0x61 and at + 96 <= area.len and area[at + 63] == 0x51 and
          area[at + 95] == 0x52:
        let pb = decodeBlock[SegdPositionBlock](area.toOpenArray(at, at + 95))
        let usable = (pb.position1Valid == 1 and pb.position1Quality != 3 and
          finite(pb.tuple1Coord1) and finite(pb.tuple1Coord2)) or
          (pb.position2Valid == 1 and pb.position2Quality != 3 and
          finite(pb.tuple2Coord1) and finite(pb.tuple2Coord2))
        if isSourceBlock(after):
          if src < 0 or (usable and not srcUsable): (src, srcUsable) = (at, usable)
        elif rcv < 0 or (usable and not rcvUsable): (rcv, rcvUsable) = (at, usable)
    elif bt notin {0x51'u8, 0x52'u8, 0x56'u8, 0x20'u8, 0x1A'u8, 0x21'u8}:
      after = bt

proc writePosition(p: var Planner, buf: var seq[byte], at: int, x, y, z: float64,
    trace: int, xy, zv: Value, changed: var set[Value]) =
  # Coordinates into the usable tuple of the Position block at `buf[at]`
  # (tuple 1, made valid, when neither is usable). z only into a tuple with
  # a third coordinate (a 3-D CRS).
  var pb = decodeBlock[SegdPositionBlock](buf.toOpenArray(at, at + 95))
  let use2 = not (pb.position1Valid == 1 and pb.position1Quality != 3 and
    finite(pb.tuple1Coord1) and finite(pb.tuple1Coord2)) and
    (pb.position2Valid == 1 and pb.position2Quality != 3 and
    finite(pb.tuple2Coord1) and finite(pb.tuple2Coord2))
  template apply(c1, c2, c3, valid, quality: untyped) =
    if x.known:
      (c1, c2) = (x, y)
      if valid != 1 or quality == 3:
        valid = 1
        if quality in {0'u8, 3'u8}: quality = 1
      changed.incl xy
    if z.known:
      if finite(c3):
        c3 = z
        changed.incl zv
      else:
        p.unwritable(zv, trace, "the Position block's tuple has no third coordinate (a 2-D CRS)")
  if use2: apply(pb.tuple2Coord1, pb.tuple2Coord2, pb.tuple2Coord3, pb.position2Valid,
             pb.position2Quality)
  else: apply(pb.tuple1Coord1, pb.tuple1Coord2, pb.tuple1Coord3, pb.position1Valid,
              pb.position1Quality)
  pb.encode(buf.toOpenArray(at, at + 95))

proc currentSegdKeys(rec: SegdRecord, buf: openArray[byte]): TraceKeys =
  var t = SegdTrace(layout: rec.layout)
  t.header = decodeBlock[SegdTraceHeader](buf.toOpenArray(0, SegdTraceHeaderSize - 1))
  let hasExt1 = buf.len >= SegdTraceHeaderSize + SegdBlockSize
  if hasExt1:
    template e1: untyped =
      buf.toOpenArray(SegdTraceHeaderSize, SegdTraceHeaderSize + SegdBlockSize - 1)
    if rec.isRev3:
      t.ext1Rev3 = some(decodeBlock[SegdTraceHeaderExt1Rev3](e1))
      t.extensions = @(buf.toOpenArray(SegdTraceHeaderSize + SegdBlockSize, buf.len - 1))
    else:
      t.ext1 = some(decodeBlock[SegdTraceHeaderExt1](e1))
  traceKeys(rec, t)

proc writeSegd(p: var Planner, rec: SegdRecord, trace: int, k, cur: TraceKeys,
    buf: var seq[byte]): set[Value] =
  # The joined values of `k` that differ from the header's (`cur`) into
  # `buf`; the kinds written.
  let f = p.fields
  let hasExt1 = buf.len >= SegdTraceHeaderSize + SegdBlockSize
  let srcXY = f.sourceXy and k.hasSourceXY and
    (differs(k.srcX, cur.srcX) or differs(k.srcY, cur.srcY))
  let rcvXY = f.receiverXy and k.hasReceiverXY and
    (differs(k.rcvX, cur.rcvX) or differs(k.rcvY, cur.rcvY))
  let srcZ = f.elevations and differs(k.srcZ, cur.srcZ)
  let rcvZ = f.elevations and differs(k.rcvZ, cur.rcvZ)
  if f.stations and (stationDiffers(k.rcvLine, cur.rcvLine) or
      stationDiffers(k.rcvPoint, cur.rcvPoint) or
      (k.rcvIndex != 0 and k.rcvIndex != cur.rcvIndex)):
    if not hasExt1:
      p.unwritable(vRcvStation, trace, "the trace has no Trace Header Extension #1")
    elif (if rec.isRev3: p.writeExt1[:SegdTraceHeaderExt1Rev3](buf, trace, k)
          else: p.writeExt1[:SegdTraceHeaderExt1](buf, trace, k)):
      result.incl vRcvStation
  let srcStation = f.stations and (stationDiffers(k.srcLine, cur.srcLine) or
    stationDiffers(k.srcPoint, cur.srcPoint) or (k.srcIndex != 0 and k.srcIndex != cur.srcIndex))
  if (srcXY or rcvXY) and f.midpoints and k.cmpX.known and
      (differs(k.cmpX, cur.cmpX) or differs(k.cmpY, cur.cmpY)):
    p.unwritable(vCmp, trace, "SEG-D has no midpoint field")
  if (srcXY or rcvXY) and f.offsets and differs(k.offset, cur.offset):
    p.unwritable(vOffset, trace, "SEG-D has no offset field")
  if not rec.isRev3:
    const why = "SEG-D Rev 1/2 trace headers have no coordinate fields"
    if srcXY: p.unwritable(vSrcXY, trace, why)
    if rcvXY: p.unwritable(vRcvXY, trace, why)
    if srcZ: p.unwritable(vSrcZ, trace, why)
    if rcvZ: p.unwritable(vRcvZ, trace, why)
    if srcStation:
      p.unwritable(vSrcStation, trace, "a SEG-D Rev 1/2 source is record-level (General " &
        "Header #N), not written per trace")
    return
  # Rev 3: the blocks in the trace header extensions.
  const areaStart = SegdTraceHeaderSize + SegdBlockSize
  if buf.len < areaStart:
    for (b, v) in [(srcXY, vSrcXY), (rcvXY, vRcvXY), (srcZ, vSrcZ), (rcvZ, vRcvZ),
        (srcStation, vSrcStation)]:
      if b: p.unwritable(v, trace, "the trace has no header extensions to hold it")
    return
  var rcvAt, srcAt: int
  positionBlocks(buf.toOpenArray(areaStart, buf.len - 1), rcvAt, srcAt)
  if rcvXY or rcvZ:
    if rcvAt >= 0:
      p.writePosition(buf, areaStart + rcvAt, (if rcvXY: k.rcvX else: NaN), k.rcvY,
        (if rcvZ: k.rcvZ else: NaN), trace, vRcvXY, vRcvZ, result)
    else:
      const why = "the trace has no receiver Position block (none is added)"
      if rcvXY: p.unwritable(vRcvXY, trace, why)
      if rcvZ: p.unwritable(vRcvZ, trace, why)
  if srcXY or srcZ:
    if srcAt >= 0:
      p.writePosition(buf, areaStart + srcAt, (if srcXY: k.srcX else: NaN), k.srcY,
        (if srcZ: k.srcZ else: NaN), trace, vSrcXY, vSrcZ, result)
    else:
      const why = "the trace has no source Position block (a record-level one in the " &
        "general headers is not written per trace)"
      if srcXY: p.unwritable(vSrcXY, trace, why)
      if srcZ: p.unwritable(vSrcZ, trace, why)
  if srcStation:
    var sd = -1
    for at, bt in blocks(buf.toOpenArray(areaStart, buf.len - 1)):
      if sd < 0 and isSourceBlock(bt): sd = areaStart + at
    if sd < 0:
      p.unwritable(vSrcStation, trace, "the trace has no Source Description block (a " &
        "record-level one in the general headers is not written per trace)")
    else:
      var s = decodeBlock[SegdSourceDescription](buf.toOpenArray(sd, sd + SegdBlockSize - 1))
      if k.srcLine.known: s.sourceLineNumber = k.srcLine
      if k.srcPoint.known: s.sourcePointNumber = k.srcPoint
      var ok = true
      if k.srcIndex != 0:
        if k.srcIndex notin 0'i16..255'i16:
          p.refuse(vSrcStation, trace, "point index " & $k.srcIndex & " does not fit byte 14")
          ok = false
        else:
          s.sourcePointIndex = uint8(k.srcIndex)
      if ok:
        var blk: array[SegdBlockSize, byte]
        try:
          s.encode(blk) # all or nothing: a refused value leaves `buf` alone
          for i in 0..<SegdBlockSize: buf[sd + i] = blk[i]
          result.incl vSrcStation
        except SegFormatError as x:
          p.refuse(vSrcStation, trace, x.msg)

func changedValues(a, b: TraceKeys): set[Value] =
  # The kinds of values that differ between two readings of a trace's keys.
  result = {}
  if not (same(a.srcX, b.srcX) and same(a.srcY, b.srcY)): result.incl vSrcXY
  if not (same(a.rcvX, b.rcvX) and same(a.rcvY, b.rcvY)): result.incl vRcvXY
  if not same(a.srcZ, b.srcZ): result.incl vSrcZ
  if not same(a.rcvZ, b.rcvZ): result.incl vRcvZ
  if not (same(a.cmpX, b.cmpX) and same(a.cmpY, b.cmpY)): result.incl vCmp
  if not same(a.offset, b.offset): result.incl vOffset
  if not (same(a.srcLine, b.srcLine) and same(a.srcPoint, b.srcPoint) and
      a.srcIndex == b.srcIndex):
    result.incl vSrcStation
  if not (same(a.rcvLine, b.rcvLine) and same(a.rcvPoint, b.rcvPoint) and
      a.rcvIndex == b.rcvIndex):
    result.incl vRcvStation

proc planSegd(p: var Planner, rec: SegdRecord, trace: int, k: TraceKeys,
    buf: var seq[byte]): set[Value] =
  if buf.len < SegdTraceHeaderSize: return
  let cur = currentSegdKeys(rec, buf)
  result = p.writeSegd(rec, trace, k, cur, buf)
  # What changed is what the keys read from the new bytes hold differently.
  if result != {}: result = result * changedValues(cur, currentSegdKeys(rec, buf))

# ------------------------------------------------------------------- pass --

proc planTrace(p: var Planner, ix: TraceIndex, trace: int, k: TraceKeys,
    buf: var seq[byte]): set[Value] =
  # The trace's header bytes in `buf` (the current ones on entry) get the
  # joined values; the values that changed.
  case ix.kind
  of skSegy: p.planSegy(trace, k, buf)
  of skSegd: p.planSegd(ix.segdRecords[ix.entries[trace].record], trace, k, buf)
  of skSeg2, skUnknown: {}

# --------------------------------------------- keys into written traces --
# **Internal**, for `model/writefile`'s `writeTrace(w, src, trace, samples,
# keys)`: the same rules, trace by trace, into a copy of a template trace's
# header bytes. The umbrella module does not export these.

type
  KeysPlan* = object
    ## **Internal.** A planner kept by a writer for one template file.
    p: Planner
    ready: bool
    path: string
    fields: GeometryFields

proc planKeys*(kp: var KeysPlan, src: SeismicFile, trace: int, k: TraceKeys,
    buf: var seq[byte], fields: GeometryFields) =
  ## **Internal.** Writes the geometry of `k` into `buf`, the header bytes of
  ## trace `trace` of `src` (SEG-Y or SEG-D), as write-back writes it;
  ## values without a slot or too large for theirs are counted for
  ## `finishKeys`.
  if not kp.ready or kp.path != src.path or kp.fields != fields:
    if kp.ready: kp.p.summarize()
    let log = move kp.p.log
    kp = KeysPlan(p: initPlanner(src.index, src.path, fields), ready: true, path: src.path,
      fields: fields)
    kp.p.log = log
  kp.p.count(kp.p.planTrace(src.index, trace, k, buf))

proc finishKeys*(kp: var KeysPlan): DiagLog =
  ## **Internal.** The reports of every `planKeys` call (values without a
  ## slot, values refused, rounding), summarized once.
  if kp.ready: kp.p.summarize()
  result = move kp.p.log
  kp.ready = false

proc checkGeometryInput(f: SeismicFile, keys: openArray[TraceKeys]) =
  f.requireOpen()
  case f.kind
  of skSeg2:
    raise newException(ValueError, "geometry cannot be written to SEG-2 files yet")
  of skUnknown:
    raise newException(ValueError, "the file is neither SEG-Y nor SEG-D")
  of skSegy, skSegd: discard
  if keys.len != f.len:
    raise newException(ValueError, "the keys are for " & $keys.len & " traces, the file has " &
      $f.len & " (open the file with keys = true, or pass the index of the same file)")

template eachChange(f: SeismicFile, keys: openArray[TraceKeys], fields: GeometryFields,
    p, i, e, buf, body: untyped) =
  # Runs `body` for every trace `i` whose header bytes `buf` (at entry `e`)
  # change; `p` is the planner.
  checkGeometryInput(f, keys)
  var p = initPlanner(f.index, f.path, fields)
  let mem = f.unsafeMemory
  var buf: seq[byte]
  for i in 0 ..< f.len:
    let e = f.index.entries[i]
    let n = int(e.headerBytes)
    if e.offset >= 0 and e.offset + n <= f.mappedSize and n > 0:
      buf.setLen n
      copyMem(addr buf[0], addr mem[e.offset], n)
      let changed = p.planTrace(f.index, i, keys[i], buf)
      p.count(changed)
      if changed.card > 0:
        body
  p.summarize()

proc geometryChanges*(f: SeismicFile, fields: GeometryFields, log: var DiagLog): GeometryChanges =
  ## What `writeGeometry` would change in `f`, a file opened with
  ## `keys = true` whose keys were joined (`applySurvey`); nothing is
  ## written. The reports (values without a slot, values that do not fit)
  ## go to `log`. Raises `ValueError` for a file without keys, a closed file,
  ## SEG-2 (not supported yet) or an unrecognized file.
  f.index.requireKeys()
  eachChange(f, f.index.keys, fields, p, i, e, buf):
    discard
  log.add p.log
  p.changes

proc geometryChanges*(f: SeismicFile, fields = GeometryFields()): GeometryChanges =
  ## What `writeGeometry` would change in `f` (opened with `keys = true`, its
  ## keys joined by `applySurvey`); nothing is written. Pass a log for the
  ## reports; `$` summarizes the result. Raises `ValueError` for a file without keys, a closed
  ## file, SEG-2 (not supported yet) or an unrecognized file.
  var log: DiagLog
  f.geometryChanges(fields, log)

proc writeGeometry*(ed: var HeaderEditor, ix: TraceIndex,
    fields = GeometryFields()): GeometryChanges =
  ## Writes the joined geometry of `ix` (the index of the same file, opened
  ## with `keys = true` and joined by `applySurvey`) into the editor's file,
  ## in place: only the header bytes that change, each span journaled first,
  ## so `rollbackJournal` undoes it. Values without a slot and values that
  ## do not fit are reported in `ed.log` (see the module doc); refused
  ## writes (a journal problem) too. Batched: one journal sync per few
  ## thousand traces. Raises `ValueError` for an index without keys or of
  ## another trace count, SEG-2 (not supported yet) or a closed file.
  ix.requireKeys()
  if ix.kind != ed.file.kind:
    raise newException(ValueError, "the index is not of the editor's file")
  let batched = ed.batching
  if batched: discard ed.flushPending() # the map holds every edit so far
  else: ed.beginBatch()
  let before = ed.edits
  var refused = 0
  try:
    eachChange(ed.file, ix.keys, fields, p, i, e, buf):
      let loc = Location(file: ed.file.path, trace: i,
        record: if ix.kind == skSegd: int(e.record) else: -1)
      if not ed.writeBytes(e.offset, buf, "trace " & $i & " geometry", loc):
        inc refused # logged by the editor
    ed.logVar.add p.log
    result = p.changes
  finally:
    # Synced here also inside the caller's batch, so the counts below are
    # what the file holds.
    if batched: discard ed.flushPending()
    else: discard ed.endBatch()
  if ed.edits - before < result.traces:
    # Refused writes, or batched edits a failed journal sync dropped (each
    # changed trace is one edit): count what the map holds now.
    eachChange(ed.file, ix.keys, fields, q, i, e, buf):
      discard
    let left = q.changes
    let dropped = result.traces - refused - (ed.edits - before)
    result = GeometryChanges(traces: result.traces - left.traces,
      sourceXy: result.sourceXy - left.sourceXy, receiverXy: result.receiverXy - left.receiverXy,
      sourceZ: result.sourceZ - left.sourceZ, receiverZ: result.receiverZ - left.receiverZ,
      midpoints: result.midpoints - left.midpoints, offsets: result.offsets - left.offsets,
      sourceStations: result.sourceStations - left.sourceStations,
      receiverStations: result.receiverStations - left.receiverStations,
      unwritable: result.unwritable)
    if dropped > 0:
      ed.logVar.report(sevFatal, dcIo, $dropped & " traces' geometry was not written: the " &
        "journal could not be synced", loc = Location(file: ed.file.path))

proc writeGeometry*(ed: var HeaderEditor, fields = GeometryFields()): GeometryChanges =
  ## Writes the joined geometry of the editor's own index into its file, in
  ## place: for an editor made from an open file (`openEditor(f)`) whose
  ## keys were joined by `applySurvey`. As `writeGeometry(ed, ix, fields)`
  ## otherwise. Raises `ValueError` when the editor's index holds no keys
  ## (open the file with `keys = true`), for SEG-2 or a closed file.
  ed.file.index.requireKeys()
  ed.writeGeometry(ed.file.index, fields)

# ------------------------------------------------------------------ files --

proc writeInPlace(path: string, g: SurveyGeometry, fields: GeometryFields, overwrite: bool,
    log: var DiagLog, progress: Progress = nil): GeometryChanges =
  # Joins `g` to the file at `path` and writes the geometry into its headers
  # through a writable map, without a journal: the file is new output that
  # its caller drops whole when anything fails, so there is nothing to undo
  # (journaling it and removing the journal afterwards was a third of the
  # time, and 770 bytes of journal per trace on disk meanwhile).
  var f = openSeismic(path, keys = true, progress = progress)
  try:
    discard f.applySurvey(g, overwrite)
    f.remapWritable()
    let map = f.unsafeMemory
    eachChange(f, f.index.keys, fields, p, i, e, buf):
      copyMem(addr map[e.offset], addr buf[0], buf.len)
    log.add p.log
    result = p.changes
    # SEG-Y: the binary header says what the joined coordinates are in.
    let system = g.gridUnit.measurementSystem
    if f.kind == skSegy and system != 0 and f.index.segy.binary.measurementSystem != system:
      const at = 3255 - 3201 # within the binary header
      let start = f.index.segy.tapeLabel.len + TextHeaderSize
      if start + 400 <= f.mappedSize:
        let old = f.index.segy.binary.measurementSystem
        putNum(map.toOpenArray(start, start + 399), at, system, f.index.segy.byteOrder)
        log.report(sevInfo, dcValidation, "binary measurement system " & $old & " -> " &
          $system & " (" & (if system == 1: "metres" else: "feet") & ", the survey's grid " &
          "unit '" & g.gridUnit.name & "')", loc = Location(file: path))
    f.flush()
  finally:
    f.close()

proc copyReporting(src, dst: string, progress: Progress) =
  # `copyFile`, in chunks through `progress` when there is one; raises
  # `SegCancelledError` when it cancels.
  if progress == nil:
    copyFile(src, dst)
    return
  const chunk = 8 shl 20
  var i, o: File
  if not open(i, src, fmRead): raise newException(IOError, "cannot open for reading: " & src)
  try:
    if not open(o, dst, fmWrite): raise newException(IOError, "cannot write " & dst)
    try:
      var tk = initProgressTicker(progress, getFileSize(i))
      var buf = newSeq[byte](chunk)
      var done = 0'i64
      while true:
        if not tk.tick(done): raiseCancelled()
        let n = i.readBuffer(addr buf[0], chunk)
        if n <= 0: break
        if o.writeBuffer(addr buf[0], n) != n: raise newException(IOError, "cannot write " & dst)
        done += n
      if not tk.finish(): raiseCancelled()
    finally:
      o.close()
  finally:
    i.close()

proc copyWithGeometry*(srcPath, dstPath: string, g: SurveyGeometry, fields = GeometryFields(),
    overwrite = false, progress: Progress = nil): GeometryCopy {.raises: [].} =
  ## Writes a copy of `srcPath` to `dstPath`, in the same standard and
  ## layout, with the survey geometry `g` joined (`applySurvey`, `overwrite`
  ## as there) and written (`writeGeometry`; `result.changes` says what changed).
  ## Multiplexed SEG-D is written demultiplexed. `srcPath` is never changed.
  ## SEG-2 is not supported yet (a fatal diagnostic). Never raises: problems
  ## are in `result.log`, with an info summary. The output goes through
  ## a new temporary file next to `dstPath` and is renamed when complete.
  ## `progress` spans the passes over the input (index, copy, index of the
  ## copy; see `convertFile`); when it cancels, `result.log` holds a fatal
  ## `dcCancelled` diagnostic and nothing is written.
  if sameAsInput(srcPath, dstPath, result.log): return
  let tmp = createTempFor(dstPath, result.log)
  if tmp.len == 0: return
  try:
    var f = openSeismic(srcPath, progress = progressPhase(progress, 0, 3))
    try:
      case f.kind
      of skUnknown:
        result.log.report(sevFatal, dcUnsupportedFormat, "neither a SEG-Y nor a SEG-D file",
          loc = Location(file: srcPath))
      of skSeg2:
        result.log.report(sevFatal, dcUnsupportedFormat, "geometry cannot be written to SEG-2 " &
          "files yet", loc = Location(file: srcPath))
      of skSegy, skSegd:
        # A multiplexed file: its demultiplexed copy.
        copyReporting(if f.demuxPath.len > 0: f.demuxPath else: srcPath, tmp,
          progressPhase(progress, 1, 3, f.mappedSize))
    finally:
      f.close()
    if not result.log.isFatal:
      result.changes = writeInPlace(tmp, g, fields, overwrite, result.log,
        progressPhase(progress, 2, 3))
      result.log.report(sevInfo, dcValidation, "geometry written: " & $result.changes,
        loc = Location(file: dstPath))
  except SegCancelledError:
    result.log.reportCancelled(dstPath)
  except CatchableError as e:
    result.log.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
  finishOutput(tmp, dstPath, keep = not result.log.isFatal, result.log)

proc convertWithGeometry*(srcPath, dstPath: string, g: SurveyGeometry, opts = ConvertOptions(),
    fields = GeometryFields(), overwrite = false, progress: Progress = nil): DiagLog {.
    raises: [].} =
  ## `convertFile` with the survey geometry `g` joined (`applySurvey`,
  ## `overwrite` as there) and written into the SEG-Y output: SEG-D keys are
  ## joined before they become SEG-Y headers; SEG-Y output is written with
  ## `writeGeometry` before it is moved into place. Never raises: problems
  ## are in the result. `progress` as for `convertFile` (SEG-Y input: the
  ## conversion, then the index of the output).
  var kind = skUnknown
  try:
    var head = newSeq[byte](8192)
    let fh = open(srcPath, fmRead)
    try: head.setLen fh.readBytes(head, 0, head.len)
    finally: fh.close()
    kind = detectKind(head)
  except IOError as e:
    result.report(sevFatal, dcIo, "cannot read: " & e.msg, loc = Location(file: srcPath))
    return
  if opts.target != skSegy and kind in {skSegy, skSegd}:
    result.report(sevFatal, dcValidation, "geometry is written into SEG-Y output only " &
      "(ConvertOptions.target)", loc = Location(file: dstPath))
    return
  case kind
  of skSegd:
    result.add convertJoined(srcPath, dstPath, opts,
      GeometryJoin(survey: addr g, fields: fields, overwrite: overwrite), progress)
  of skSegy:
    if sameAsInput(srcPath, dstPath, result): return
    let tmp = createTempFor(dstPath, result)
    if tmp.len == 0: return
    result.add convertFile(srcPath, tmp, opts, progressPhase(progress, 0, 2))
    if not result.isFatal:
      try:
        let c = writeInPlace(tmp, g, fields, overwrite, result, progressPhase(progress, 1, 2,
          getFileSize(srcPath)))
        result.report(sevInfo, dcValidation, "geometry written: " & $c,
          loc = Location(file: dstPath))
      except SegCancelledError:
        result.reportCancelled(dstPath)
      except CatchableError as e:
        result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
    finishOutput(tmp, dstPath, keep = not result.isFatal, result)
  of skSeg2:
    result.report(sevFatal, dcUnsupportedFormat, "geometry cannot be written to SEG-2 " &
      "files or their conversions yet", loc = Location(file: srcPath))
  of skUnknown:
    result.add convertFile(srcPath, dstPath, opts, progress) # reports why it cannot
