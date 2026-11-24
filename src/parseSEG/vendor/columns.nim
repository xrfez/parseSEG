## Vendor fields by name: the fields the loaded vendor maps can decode for a file
## (`vendorFieldNames`) and one field's value for every trace (`vendorColumn`,
## `vendorColumnInt`), for a display line, a sort key or a file-name token.
##
## ```nim
## let ctx = vendorContext(f.index.segdRecords[0])
## for info in reg.vendorFieldNames(ctx): echo info.name, " ", info.kind, " ", info.unit
## let col = f.vendorColumn(reg, "batteryV")
## echo col.numbers[0], " (", col.absent, " traces without it)"
## ```
##
## A field is addressed by its bare name when only one field of the maps that
## apply has it, else as `<block>.<name>`, where `<block>` is the `(name ...)` of
## the map's `(target ...)` (the target kind's name, such as `traceExt`, when it has
## none). A repeat's field is listed once under its bare name (`isRepeat`) and asked
## for as `name[i]`.
##
## A column decodes only the target that holds the field, from the mapped header
## bytes of each trace (SEG-D Rev 2 extension blocks by number, Rev 3 blocks by
## type, SEG-Y trace headers and proprietary headers by name), with the same map
## choice, `(match)`, `(when)`, sentinel, scale and offset as `decodeAll`. A numeric
## field of a trace block allocates nothing per trace. A text, bytes or repeat field
## allocates its strings (a repeat decodes its whole target). Code decoders
## (`registerVendorDecoder`) have no field plans and are not consulted.

import std/[algorithm, math, options, strutils, tables]
import ../common/[diagnostics, endians]
import ../segd/[headers as segdheaders, reader as segdreader]
import ../segy/[reader as segyreader, traceheader]
import ../model/[indextypes, traceindex]
import ../private/readcache
import ./[maps, apply]

type
  VendorLevel* = enum
    ## Where a field lives.
    vlRecord ## A file or record block (SEG-D general, extended, external headers and
             ## trailer; SEG-Y binary header and stanzas): one value per record.
    vlTrace  ## A trace block: SEG-D trace header extensions, SEG-Y trace headers.

  VendorFieldInfo* = object
    ## One field a map can decode.
    name*: string        ## How a caller addresses it (see the module documentation).
    blockName*: string   ## The target's name.
    fieldName*: string   ## The field's own name (without `[i]`).
    map*: string         ## The first loaded map that defines it.
    kind*: VendorValueKind ## `vvInt`, `vvFloat`, `vvText` or `vvBytes`.
    unit*: string
    hasLabels*: bool     ## The field has `(enum ...)` labels.
    level*: VendorLevel
    isRepeat*: bool      ## A field of a `(repeat)`: address an element as `name[i]`.

  VendorColumn* = object
    ## One field's value for every trace.
    name*: string
    kind*: VendorValueKind
    unit*: string
    level*: VendorLevel
    numbers*: seq[float64] ## `vvInt` and `vvFloat`: a value per trace, NaN where absent.
    texts*: seq[string]  ## `vvText` and `vvBytes` (as lowercase hex): "" where absent.
    absent*: int         ## Traces with no value: the field's `(when)` is off, it holds its
                         ## sentinel, the block is missing or short, or no map applies.
    stopped*: bool       ## `stop` returned true: the column is empty.

  VendorColumnInt* = object
    ## An integer field's value for every trace, exact.
    name*: string
    unit*: string
    level*: VendorLevel
    values*: seq[int64]  ## 0 where absent (see `present`).
    present*: seq[bool]
    absent*: int
    stopped*: bool

  Cand = object
    # One place that defines an address: a field of a target, or of a target's repeat.
    map, target, field, rep: int
      ## `rep` -1: `t.fields[field]`, else `t.repeats[rep].fields[field]`.
    matched: bool        ## The target has `(match)`: decoded after those without.

  Entry = object
    info: VendorFieldInfo
    cands: seq[Cand]

  SinkMode = enum smFloat, smInt, smText

  Sink = object
    mode: SinkMode
    floats: seq[float64]
    ints: seq[int64]
    present: seq[bool]
    texts: seq[string]
    absent: int

  RecState = object
    # What one record needs to read its traces.
    ctx: VendorContext
    specs: seq[int]
    cands: seq[Cand]     ## Of maps that apply, in decode order.
    contenders: int      ## Applying maps with a target of a trace kind.

func level(t: VendorTarget): VendorLevel =
  # A `block` target with no `where` counts as record level.
  case t.kind
  of vtTraceExt, vtTraceHeaderBytes, vtTraceHeaderBlock: vlTrace
  of vtBlock: (if cmpIgnoreCase(t.where, "traceHeader") == 0: vlTrace else: vlRecord)
  else: vlRecord

func isTraceKind(k: VendorTargetKind): bool =
  k in {vtTraceExt, vtTraceHeaderBytes, vtTraceHeaderBlock, vtBlock}

template plan(reg: VendorRegistry, c: Cand): untyped =
  (if c.rep < 0: reg.maps[c.map].targets[c.target].fields[c.field]
   else: reg.maps[c.map].targets[c.target].repeats[c.rep].fields[c.field])

func hasLabels(f: VendorFieldPlan): bool = f.enums.len > 0

func cmpCand(a, b: Cand): int =
  result = cmp(a.map, b.map)
  if result == 0: result = cmp(ord(a.matched), ord(b.matched))
  if result == 0: result = cmp(a.target, b.target)

proc collect(reg: VendorRegistry, ctx: VendorContext, applicableOnly: bool): seq[Entry] =
  # Every field of the maps (those that apply to `ctx`, or all), once per (block, field),
  # in map, target, field order; the places that define it in decode order.
  var at = initTable[string, int]()
  for mi, m in reg.maps:
    if not applicableOnly or m.applies(ctx):
      for ti, t in m.targets:
        template addField(f: VendorFieldPlan, fi, ri: int, repeated: bool) =
          let key = t.name & '\0' & f.name
          if key notin at:
            at[key] = result.len
            result.add Entry(info: VendorFieldInfo(name: f.name, blockName: t.name,
              fieldName: f.name, map: m.name, kind: f.valueKind, unit: f.unit,
              hasLabels: f.hasLabels, level: t.level, isRepeat: repeated))
          result[at[key]].cands.add Cand(map: mi, target: ti, field: fi, rep: ri,
            matched: t.matches.len > 0)
        for fi, f in t.fields: addField(f, fi, -1, false)
        for ri, r in t.repeats:
          for fi, f in r.fields: addField(f, fi, ri, true)
  var count = initTable[string, int]()
  for e in result: count.mgetOrPut(e.info.fieldName, 0) += 1
  for e in result.mitems:
    e.cands.sort(cmpCand)
    if count[e.info.fieldName] > 1: e.info.name = e.info.blockName & "." & e.info.fieldName

proc vendorFieldNames*(reg: VendorRegistry, ctx: VendorContext): seq[VendorFieldInfo] =
  ## The fields the maps that apply to `ctx` can decode, in map order, then target
  ## order, then field order (a repeat's fields after the target's own). A field named
  ## by several targets (the same block name and field name) is listed once, with the
  ## kind and unit of the first. `name` is the bare field name when no other listed
  ## field has it, else `<block>.<name>` with the target's `(name ...)` as block. A
  ## repeat's fields are listed once (`isRepeat`), not expanded. Code decoders are
  ## not listed.
  for e in reg.collect(ctx, true): result.add e.info

proc fileContext(f: SeismicFile): VendorContext =
  # The matching facts of the file's first record (SEG-D) or of the file (SEG-Y).
  case f.kind
  of skSegd:
    if f.index.segdRecords.len > 0:
      vendorContext(f.index.segdRecords[0], blocks = true)
    else:
      VendorContext(format: skSegd, manufacturer: -1, serial: -1, byteOrder: boBig)
  of skSegy: vendorContext(f.index.segy)
  else:
    raise newException(ValueError, "vendor maps do not apply to " & $f.kind & " files")

proc vendorFieldNames*(reg: VendorRegistry, f: SeismicFile): seq[VendorFieldInfo] =
  ## `vendorFieldNames` for an open file's first record (SEG-D) or the file (SEG-Y).
  ## Raises `ValueError` for a closed file and for SEG-2.
  f.requireOpen()
  reg.vendorFieldNames(f.fileContext)

# ----------------------------------------------------------------- reading --

const hexDigits = "0123456789abcdef"

func hex(b: openArray[byte]): string =
  result = newStringOfCap(2 * b.len)
  for x in b:
    result.add hexDigits[int(x shr 4)]
    result.add hexDigits[int(x and 15)]

proc newSink(mode: SinkMode, n: int): Sink =
  result.mode = mode
  case mode
  of smFloat: result.floats = newSeq[float64](n)
  of smInt:
    result.ints = newSeq[int64](n)
    result.present = newSeq[bool](n)
  of smText: result.texts = newSeq[string](n)

func putAbsent(s: var Sink, i: int) =
  inc s.absent
  if s.mode == smFloat: s.floats[i] = NaN

func putFloat(s: var Sink, i: int, v: float64) {.inline.} =
  s.floats[i] = v

func putInt(s: var Sink, i: int, v: int64) {.inline.} =
  s.ints[i] = v
  s.present[i] = true

proc putValue(s: var Sink, i: int, v: VendorValue) =
  # A decoded value, if its kind fits the column.
  case s.mode
  of smFloat:
    case v.kind
    of vvInt: s.putFloat(i, float64(v.intVal))
    of vvFloat: s.putFloat(i, v.floatVal)
    else: s.putAbsent(i)
  of smInt:
    if v.kind == vvInt: s.putInt(i, v.intVal) else: s.putAbsent(i)
  of smText:
    case v.kind
    of vvText: s.texts[i] = v.text
    of vvBytes: s.texts[i] = hex(v.bytes)
    else: s.putAbsent(i)

proc readCand(reg: VendorRegistry, c: Cand, b: openArray[byte], rc: RecState, elem: int,
    s: var Sink, i: int) =
  # Field `c` of the block `b` into slot `i`.
  template t: untyped = reg.maps[c.map].targets[c.target]
  let order = rc.ctx.byteOrder
  if c.rep >= 0:
    # A repeat's element: the whole target is decoded, as its count may be a field.
    var blk: VendorBlock
    var problems: seq[string]
    t.decodeTarget(b, order, blk, problems, rc.ctx)
    let want = reg.plan(c).name & "[" & $elem & "]"
    var found = false
    for fld in blk.fields:
      if fld.name == want:
        s.putValue(i, fld.value)
        found = true
    if not found: s.putAbsent(i)
  elif not t.fieldIsOn(c.field, b, order, rc.ctx): s.putAbsent(i)
  else:
    template fp: untyped = t.fields[c.field]
    case s.mode
    of smFloat, smInt:
      var iv: int64
      var fv: float64
      case fp.readNumber(b, 0, order, iv, fv)
      of nrInt:
        if s.mode == smInt:
          if fp.scaled: s.putAbsent(i) else: s.putInt(i, iv)
        else: s.putFloat(i, fv)
      of nrFloat:
        if s.mode == smFloat: s.putFloat(i, fv) else: s.putAbsent(i)
      else: s.putAbsent(i)
    of smText:
      let v = decodeField(fp, b, 0, order)
      if v.isSome: s.putValue(i, v.get) else: s.putAbsent(i)

# ----------------------------------------------------------------- resolve --

type Address = object
  entry: Entry
  elem: int            ## The element of a repeat field; -1 otherwise.

proc resolve(reg: VendorRegistry, ctx: VendorContext, name: string): Address =
  # The field `name` names among the maps that apply to `ctx`; its places among all maps.
  let listed = reg.collect(ctx, true)
  var base = name
  let elem = elementIndex(name, base)
  let key = if elem >= 0: base else: name
  var found = -1
  var clash: seq[string]
  for i, e in listed:
    if e.info.name == key or e.info.blockName & "." & e.info.fieldName == key: found = i
    elif e.info.fieldName == key: clash.add e.info.blockName
  if found < 0:
    let why = if clash.len > 0:
        " is in several blocks (" & clash.join(", ") & "): address it as <block>.<name>"
      else: " is not a field of the vendor maps that apply to this file"
    raise newException(ValueError, "vendor field " & name & why)
  let info = listed[found].info
  if info.isRepeat and elem < 0:
    raise newException(ValueError, "vendor field " & name &
      " is in a repeat: address an element as " & name & "[i]")
  if not info.isRepeat and elem >= 0:
    raise newException(ValueError, "vendor field " & key & " is not in a repeat")
  result.elem = elem
  result.entry = listed[found]
  for e in reg.collect(ctx, false):
    if e.info.blockName == info.blockName and e.info.fieldName == info.fieldName:
      result.entry.cands = e.cands

proc recState(reg: VendorRegistry, ctx: VendorContext, a: Address): RecState =
  result.ctx = ctx
  result.specs = reg.applicableSpecs(result.ctx)
  for c in a.entry.cands:
    if result.specs[c.map] >= 0: result.cands.add c
  for i, m in reg.maps:
    if result.specs[i] >= 0:
      for t in m.targets:
        if t.kind.isTraceKind:
          inc result.contenders
          break

# ------------------------------------------------------------- the traces --

proc raiseOutside(trace: int) {.noinline, noreturn.} =
  raise newException(ValueError, "the headers of trace " & $trace & " lie outside the file")

proc recordValues(f: SeismicFile, reg: VendorRegistry, a: Address, s: var Sink, n: int) =
  # A record-level field: one value per record, repeated for its traces.
  let records = max(1, f.recordCount)
  var maps: seq[string]
  for c in a.entry.cands: maps.add reg.maps[c.map].name
  var want = a.entry.info.fieldName
  if a.elem >= 0: want.add "[" & $a.elem & "]"
  var vals = newSeq[Option[VendorValue]](records)
  var log: DiagLog
  for r in 0 ..< records:
    let blocks = if f.kind == skSegd: reg.decodeVendorAreas(f.index.segdRecords[r], log)
      else: reg.decodeVendorAreas(f.index.segy, log)
    for blk in blocks:
      if vals[r].isNone and blk.name == a.entry.info.blockName and blk.mapName in maps:
        for fld in blk.fields:
          if vals[r].isNone and fld.name == want: vals[r] = some(fld.value)
  for i in 0 ..< n:
    let r = min(int(f.index.entries[i].record), records - 1)
    if vals[r].isSome: s.putValue(i, vals[r].get) else: s.putAbsent(i)

proc scanTraces(f: SeismicFile, reg: VendorRegistry, a: Address, stop: proc(): bool,
    s: var Sink): bool =
  # Reads the field of every trace into `s`; false when `stop` ended it.
  let n = f.len
  var rc: RecState
  var haveRec = -1
  let mem = f.unsafeMemory
  let size = f.mappedSize
  let unmapped = f.unsafeCache != nil
  var cur: Cursor
  var area = VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1, extIndex: -1)
  var nameBytes: array[8, byte]
  var haveName = false
  var tie = false
  # Reads the first candidate whose target is for the block `b` of `area`.
  template tryBlock(b: untyped, i: int, hit: var bool) =
    let chosen = if rc.contenders > 1: reg.selectMapWith(rc.specs, area, b, tie) else: -1
    for c in rc.cands:
      if (chosen < 0 or c.map == chosen) and
          reg.maps[c.map].targets[c.target].targetMatches(area, b):
        reg.readCand(c, b, rc, a.elem, s, i)
        hit = true
        break
  for i in 0 ..< n:
    if stop != nil and (i and 4095) == 0 and stop(): return false
    let e = f.index.entries[i]
    if int(e.record) != haveRec:
      haveRec = int(e.record)
      let ctx = if f.kind == skSegd: vendorContext(f.index.segdRecords[haveRec],
          reg.usesRecordBlocks)
        else: vendorContext(f.index.segy)
      rc = reg.recState(ctx, a)
    if unmapped: f.coverHeaders(cur, i)
    var hit = false
    if rc.cands.len > 0:
      let at = int(e.offset)
      let hb = int(e.headerBytes)
      if f.kind == skSegd:
        if e.offset < 0 or e.offset + hb > size or hb < SegdTraceHeaderSize: raiseOutside(i)
        let first = at + SegdTraceHeaderSize + SegdBlockSize
        let extra = hb - SegdTraceHeaderSize - SegdBlockSize
        if f.index.segdRecords[haveRec].layout == slRev2:
          area.kind = vtTraceExt
          var k = 0
          while not hit and (k + 1) * SegdBlockSize <= extra:
            area.extIndex = k + 2
            tryBlock(mem.toOpenArray(first + k * SegdBlockSize,
              first + (k + 1) * SegdBlockSize - 1), i, hit)
            inc k
        else:
          area.kind = vtBlock
          area.where = "traceHeader"
          var k = 0
          while not hit and k + SegdBlockSize <= extra:
            let span = mem.toOpenArray(first + k, first + extra - 1).typedBlockSpan(0)
            area.blockType = int(mem[first + k + SegdBlockSize - 1])
            tryBlock(mem.toOpenArray(first + k, first + k + span - 1), i, hit)
            k += span
      else:
        if e.offset < 0 or e.offset + max(hb, TraceHeaderSize) > size: raiseOutside(i)
        area.kind = vtTraceHeaderBytes
        tryBlock(mem.toOpenArray(at, at + TraceHeaderSize - 1), i, hit)
        var k = 2
        while not hit and (k + 1) * TraceHeaderSize <= hb:
          let first = at + k * TraceHeaderSize
          # The block's name is a string: made again only when its bytes change.
          var same = haveName
          for j in 0 .. 7:
            if mem[first + 232 + j] != nameBytes[j]: same = false
          if not same:
            for j in 0 .. 7: nameBytes[j] = mem[first + 232 + j]
            area.headerName = headerBlockName(mem.toOpenArray(first, first + TraceHeaderSize - 1))
            haveName = true
          area.kind = vtTraceHeaderBlock
          tryBlock(mem.toOpenArray(first, first + TraceHeaderSize - 1), i, hit)
          inc k
    if not hit: s.putAbsent(i)
  true

proc fill(f: SeismicFile, reg: VendorRegistry, a: Address, stop: proc(): bool,
    s: var Sink): bool =
  # Fills `s` with the field of every trace; false when `stop` ended it.
  f.requireUncutFirst()
  if a.entry.info.level == vlRecord:
    f.recordValues(reg, a, s, f.len)
    result = true
  else:
    result = f.scanTraces(reg, a, stop, s)
  f.requireUncut()

proc vendorColumn*(f: SeismicFile, reg: VendorRegistry, name: string,
    stop: proc(): bool = nil): VendorColumn =
  ## The value of the vendor field `name` (see the module documentation) for every
  ## trace of `f`: `numbers` for an integer or float field (NaN where absent), `texts` for
  ## a text field or bytes (as lowercase hex; "" where absent), with the field's `kind`,
  ## `unit`, `level` and the count of traces with no value (`absent`).
  ##
  ## Only the target that holds the field is decoded, from that trace's mapped header
  ## bytes; the map is chosen per block as `decodeAll` chooses it. The name is resolved
  ## among the maps that apply to the file's first record (SEG-D) or the file (SEG-Y);
  ## other records use the maps that apply to them, so a record no map applies to gives
  ## absent values. A record-level field gives its record's value for each of the
  ## record's traces. An integer beyond 2^53 loses its low bits as a float64: use
  ## `vendorColumnInt`. `stop` is asked every 4096 traces; when it returns true the
  ## column is empty and `stopped` is set. Raises `ValueError` for an unknown or
  ## ambiguous name, a repeat field named without `[i]`, a closed file, SEG-2, and
  ## headers that lie outside the file, and `SegTruncatedError` for a file cut short.
  f.requireOpen()
  let a = reg.resolve(f.fileContext, name)
  let info = a.entry.info
  var s = newSink(if info.kind in {vvInt, vvFloat}: smFloat else: smText, f.len)
  result = VendorColumn(name: name, kind: info.kind, unit: info.unit, level: info.level)
  if f.fill(reg, a, stop, s):
    result.absent = s.absent
    result.numbers = move s.floats
    result.texts = move s.texts
  else: result.stopped = true

proc vendorColumnInt*(f: SeismicFile, reg: VendorRegistry, name: string,
    stop: proc(): bool = nil): VendorColumnInt =
  ## `vendorColumn` for an unscaled integer field, exactly: `values` holds the raw
  ## integer (an unsigned 64-bit field as the int64 `decode` gives) and `present` says
  ## which traces have one (`values` is 0 elsewhere), so a microsecond time keeps every
  ## digit. Raises `ValueError` as `vendorColumn` does, and for a field that is not an
  ## integer or has a `scale` or `offset` (its shown value is a float).
  f.requireOpen()
  let a = reg.resolve(f.fileContext, name)
  let info = a.entry.info
  if info.kind != vvInt:
    raise newException(ValueError, "vendor field " & name & " is not an unscaled integer " &
      "field (it is " & $info.kind & "): use vendorColumn")
  var s = newSink(smInt, f.len)
  result = VendorColumnInt(name: name, unit: info.unit, level: info.level)
  if f.fill(reg, a, stop, s):
    result.absent = s.absent
    result.values = move s.ints
    result.present = move s.present
  else: result.stopped = true
