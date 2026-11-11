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
##   with the geometry, `convertWithGeometry` a converted SEG-Y file;
## - `geometryChanges` only reports what would change.
##
## A value is written when the joined key differs from what the trace's
## headers hold (as `traceKeys` reads them); unknown (NaN) values are never
## written. Midpoints and offsets follow the coordinates: they are written
## only for traces whose source or receiver X/Y change. Values with no slot
## in the file, or too large for theirs, are counted (`unwritable`) and
## reported in the log, one warning per kind, never dropped silently.
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
import ../private/[checks, coordscalar, progressticker]

export join

type
  GeometryChanges* = object
    ## What `writeGeometry` changed (or `geometryChanges` would change), in
    ## traces per kind of value.
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

  Planner = object
    ## One pass over a file's traces: what changes, and the reports.
    fields: GeometryFields
    path: string
    order: ByteOrder
    lay: TraceLayout   ## SEG-Y: the file's effective layout.
    gr: GeometryReader ## SEG-Y: for the current keys.
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
    name: string
    value: float64
    what: Value
    part: char     ## Values of one kind and part need only one field: 'p' point, ...
    written: bool  ## Handled: written, or refused (`refused`, reported).
    refused: bool

const
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

proc initPlanner(ix: TraceIndex, path: string, fields: GeometryFields): Planner =
  result = Planner(fields: fields, path: path)
  if ix.kind == skSegy:
    result.order = ix.segy.byteOrder
    result.lay = ix.segy.layoutOf
    result.gr = initGeometryReader(ix.segy)

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

func scalarNameOf(k: LayoutType): string =
  case k
  of ltCoor4: "co_scal"
  of ltElev4: "ed_scal"
  of ltSpNum4: "sp_scal"
  else: ""

proc blockBase(buf: openArray[byte], ext: string): int =
  # Where the 240-byte header an entry lives in starts in the trace's
  # header bytes; -1 when the trace has no such header.
  if ext.len == 0 or cmpIgnoreCase(ext, "SEG00000") == 0: return 0
  if buf.len < 2 * TraceHeaderSize: return -1
  if cmpIgnoreCase(ext, "SEG00001") == 0: return TraceHeaderSize
  var i = 2 * TraceHeaderSize
  while i + TraceHeaderSize <= buf.len:
    if cmpIgnoreCase(headerBlockName(buf.toOpenArray(i, i + TraceHeaderSize - 1)), ext) == 0:
      return i
    i += TraceHeaderSize
  -1

func protectedEntry(base: int, e: LayoutEntry): bool =
  # An entry over bytes that size the trace or name a header.
  let a = e.bytePos - 1
  let z = a + e.kind.size
  template check(list: untyped) =
    for (p, n) in list:
      if a < p + n and p < z: return true
  if base == 0: check(StdProtected)
  elif base == TraceHeaderSize: check(Ext1Protected)
  else: check(PropProtected)
  false

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

proc scalarOf(p: Planner, buf: openArray[byte], name: string, present: var bool): int16 =
  # The trace's scalar `name` (the last applicable entry), 1 for 0 or none.
  result = 1
  present = false
  for e in p.lay.entriesFor(name):
    let b = blockBase(buf, e.extension)
    if b >= 0:
      let x = readRaw(buf, b + e.bytePos - 1, e.kind, p.order)
      if (not e.ifNonZero or x != 0) and x == trunc(x) and x >= -32768 and x <= 32767:
        present = true
        result = if x == 0: 1'i16 else: int16(x)

proc slotValue(p: Planner, buf: openArray[byte], name: string): float64 =
  # The value of layout name `name` as `fieldValue` reads it; NaN if none.
  result = NaN
  for e in p.lay.entriesFor(name):
    let b = blockBase(buf, e.extension)
    if b >= 0:
      var x = readRaw(buf, b + e.bytePos - 1, e.kind, p.order)
      if not e.ifNonZero or x != 0:
        let sn = scalarNameOf(e.kind)
        if sn.len > 0:
          var present: bool
          x = applyScalar(x, p.scalarOf(buf, sn, present))
        result = x

proc writeScaledGroup(p: var Planner, buf: var seq[byte], trace: int, kind: LayoutType,
    ups: var seq[Update]) =
  # Rewrites every `kind` field of the trace with one scalar chosen for the
  # new values and the unchanged ones.
  type Slot = object
    at: int
    value: float64
    up: int # index into `ups`, -1 for an unchanged field
  var slots: seq[Slot]
  var any = false
  let sn = scalarNameOf(kind)
  var present: bool
  let s0 = p.scalarOf(buf, sn, present)
  for e in p.lay.entries:
    if e.kind == kind:
      let b = blockBase(buf, e.extension)
      if b >= 0 and not protectedEntry(b, e):
        let at = b + e.bytePos - 1
        var up = -1
        for i, u in ups:
          if u.name == e.name: up = i
        if up >= 0: any = true
        let value = if up >= 0: ups[up].value
                    else: applyScalar(readRaw(buf, at, kind, p.order), s0)
        slots.add Slot(at: at, up: up, value: value)
  if not any: return
  var vals: seq[float64]
  for s in slots: vals.add s.value
  var exact: bool
  var s = s0
  if present:
    s = chooseScalar(vals, s0, exact)
  else:
    exact = exactScalar(vals, s0)
    if not fitsScalar(vals, s0): s = 0
  if s == 0:
    for sl in slots:
      if sl.up >= 0:
        p.refuse(ups[sl.up].what, trace, $ups[sl.up].value & " is too large for a 4-byte " &
          "SEG-Y field with any coordinate scalar (" & ups[sl.up].name & ")")
        ups[sl.up].written = true
        ups[sl.up].refused = true # reported
    return
  for sl in slots:
    putNum(buf, sl.at, int32(round(rawOf(sl.value, s))), p.order)
    if sl.up >= 0:
      ups[sl.up].written = true
      if not exact: p.noteRounded(ups[sl.up].what, trace)
  if present and s != s0:
    for e in p.lay.entriesFor(sn):
      let b = blockBase(buf, e.extension)
      if b >= 0 and not protectedEntry(b, e):
        var r: bool
        discard writeRaw(buf, b + e.bytePos - 1, e.kind, float64(s), p.order, r)

proc writeUnscaled(p: var Planner, buf: var seq[byte], trace: int, u: var Update) =
  # The entries of `u.name` that are not scaled 4-byte fields; an `ifNonZero`
  # entry only while it is in use.
  for e in p.lay.entriesFor(u.name):
    if e.kind notin {ltCoor4, ltElev4, ltSpNum4}:
      let b = blockBase(buf, e.extension)
      if b >= 0 and not protectedEntry(b, e):
        let at = b + e.bytePos - 1
        if not e.ifNonZero or readRaw(buf, at, e.kind, p.order) != 0:
          var r = false
          let err = writeRaw(buf, at, e.kind, u.value, p.order, r)
          if err.len > 0:
            p.refuse(u.what, trace, err & " (" & u.name & ")")
            u.refused = true
          elif r:
            p.noteRounded(u.what, trace)
          u.written = true

proc currentSegyKeys(p: Planner, buf: openArray[byte]): TraceKeys =
  var t = SegyTrace(header: decodeTraceHeader(buf.toOpenArray(0, TraceHeaderSize - 1), p.order))
  if buf.len >= 2 * TraceHeaderSize:
    t.hasExt1 = true
    t.ext1 = decodeTraceHeaderExt1(buf.toOpenArray(TraceHeaderSize, 2 * TraceHeaderSize - 1),
      p.order)
    t.proprietary = @(buf.toOpenArray(2 * TraceHeaderSize, buf.len - 1))
  p.gr.traceKeys(t)

proc planSegy(p: var Planner, trace: int, k: TraceKeys, buf: var seq[byte]): set[Value] =
  if buf.len < TraceHeaderSize: return
  let cur = p.currentSegyKeys(buf)
  var ups: seq[Update]
  template up(n: string, x: float64, w: Value, pt = 'v') =
    ups.add Update(name: n, value: x, what: w, part: pt)
  let f = p.fields
  let srcXY = f.sourceXy and k.hasSourceXY and
    (differs(k.srcX, cur.srcX) or differs(k.srcY, cur.srcY))
  let rcvXY = f.receiverXy and k.hasReceiverXY and
    (differs(k.rcvX, cur.rcvX) or differs(k.rcvY, cur.rcvY))
  if srcXY:
    up("sht_x", k.srcX, vSrcXY)
    up("sht_y", k.srcY, vSrcXY)
  if rcvXY:
    up("rec_x", k.rcvX, vRcvXY)
    up("rec_y", k.rcvY, vRcvXY)
  if srcXY or rcvXY:
    if p.slotValue(buf, "coorunit") == 0: # unset: the coordinates are lengths
      up("coorunit", 1, if srcXY: vSrcXY else: vRcvXY, 'u')
    if f.midpoints and k.cmpX.known and k.cmpY.known and
        (differs(k.cmpX, cur.cmpX) or differs(k.cmpY, cur.cmpY)):
      up("cdp_x", k.cmpX, vCmp)
      up("cdp_y", k.cmpY, vCmp)
    if f.offsets and differs(k.offset, cur.offset): up("offset", k.offset, vOffset)
  if f.elevations:
    if differs(k.srcZ, cur.srcZ): up("selev", k.srcZ, vSrcZ)
    if differs(k.rcvZ, cur.rcvZ): up("relev", k.rcvZ, vRcvZ)
  if f.stations:
    if stationDiffers(k.srcPoint, cur.srcPoint):
      up("espnum", k.srcPoint, vSrcStation, 'p')
      up("sp", k.srcPoint, vSrcStation, 'p')
    template station(n: string, x: float64, w: Value, pt: char) =
      if stationDiffers(x, p.slotValue(buf, n)): up(n, x, w, pt)
    station("sht_line", k.srcLine, vSrcStation, 'l')
    station("sht_point", k.srcPoint, vSrcStation, 'p')
    station("rec_line", k.rcvLine, vRcvStation, 'l')
    station("rec_point", k.rcvPoint, vRcvStation, 'p')
    if k.srcIndex != 0: station("sht_index", float64(k.srcIndex), vSrcStation, 'i')
    if k.rcvIndex != 0: station("rec_index", float64(k.rcvIndex), vRcvStation, 'i')
  if ups.len == 0: return
  for kind in [ltCoor4, ltElev4, ltSpNum4]: p.writeScaledGroup(buf, trace, kind, ups)
  for u in ups.mitems: p.writeUnscaled(buf, trace, u)
  # Values with no slot: one report per kind and trace. A part (the point,
  # the line, ...) needs only one of its fields (espnum, sp, sht_point).
  var missing: set[Value]
  for u in ups:
    if u.part == 'u': discard # the units follow the coordinates
    elif u.written:
      if not u.refused: result.incl u.what
    else:
      var done = false
      for o in ups:
        if o.written and o.what == u.what and o.part == u.part: done = true
      if not done: missing.incl u.what
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

proc planSegd(p: var Planner, rec: SegdRecord, trace: int, k: TraceKeys,
    buf: var seq[byte]): set[Value] =
  if buf.len < SegdTraceHeaderSize: return
  let cur = currentSegdKeys(rec, buf)
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

# ------------------------------------------------------------------- pass --

proc planTrace(p: var Planner, ix: TraceIndex, trace: int, k: TraceKeys,
    buf: var seq[byte]): set[Value] =
  # The trace's header bytes in `buf` (the current ones on entry) get the
  # joined values; the values that changed.
  case ix.kind
  of skSegy: p.planSegy(trace, k, buf)
  of skSegd: p.planSegd(ix.segdRecords[ix.entries[trace].record], trace, k, buf)
  of skSeg2, skUnknown: {}

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
      var changed = p.planTrace(f.index, i, keys[i], buf)
      if changed.card > 0 and equalMem(addr buf[0], addr mem[e.offset], n):
        changed = {} # the values round to the bytes already there (e.g. 99.5 → 100)
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
  # Joins `g` to the file at `path` and writes it in place, journaled into a
  # temporary journal that is removed afterwards (the file is new output).
  var j = openSeismic(path, keys = true, progress = progress)
  discard j.applySurvey(g, overwrite)
  let journal = path & ".geometry.nif"
  var ed = openEditor(j, journal)
  try:
    result = ed.writeGeometry(fields)
  finally:
    ed.close()
    log.add ed.log
    discard tryRemoveFile(journal)

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
