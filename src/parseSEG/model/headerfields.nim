## Header fields by name (task 8.2): read any header field of a mapped file
## as `<block>.<field>`, with the field names of the header types. The same
## names (and this module's block lookup) serve the in-place editor
## (`model/edit`).
##
## - per trace (`traceField`): `trace` (the SEG-Y trace header or SEG-D demux
##   header) and `ext1` (SEG-Y Trace Header Extension 1; SEG-D THE#1, in the
##   Rev 1/2 or Rev 3 layout of its record);
## - per SEG-D record (`recordField`): `gh1`, and for Rev 1/2 `gh3`, `gh4`, ...
##   (source headers);
## - per file (`fileField`): the SEG-Y `binary` header.
##
## SEG-2 has one block per trace (`trace`, the Trace Descriptor Block) and
## one per file (`file`, the File Descriptor Block). Their names are the
## fixed-part fields (`Seg2TraceFixed`, `Seg2FileFixed`: `trace.numSamples`,
## `file.revision`, ...) and the block's keyword strings (`trace.
## SAMPLE_INTERVAL`, `file.UNITS`; matched case-insensitively, the first
## string with the keyword), whose values come back verbatim as `fvText`.
## `fieldNames` lists the fixed fields; `seg2Strings` lists the strings of a
## block. SEG-2 fields are read-only: a
## string edit changes the block's size, so the editor refuses SEG-2 edits
## and the file is rewritten instead (`seg2/writer`, `convertFile`).
##
## Values are read from the mapped bytes, so they reflect in-place edits at
## once. Integers (BCD included; -1 = all F, -2 = invalid BCD) come back as
## `fvInt`, floats and fixed point as `fvFloat`, character fields as
## `fvText`. Raw byte fields are not fields here.
##
## Lookups come in two forms: `traceField` (and `recordField`, `fileField`)
## raise `ValueError` when the field cannot be read, for fields the caller
## requires; `findTraceField` (...) return an `Option` for fields that may be
## absent.

import std/[macros, options, strutils]
import ../common/[endians, fieldlayout]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ../seg2/[headers as seg2headers, reader as seg2reader]
import ./[traceindex, fieldvalues]
import ../private/[checks, fieldaccess]

export fieldvalues

proc fieldNames*(kind: HeaderBlock): seq[string] =
  ## The named fields of block kind `kind`, in layout order (raw byte fields
  ## excluded; none for `hbRaw`).
  withBlockType(kind):
    var h: BlockT
    for n, f in fieldPairs(h):
      when isNamedField(f): result.add n

proc fieldByName*[T](h: T, name: string): Option[FieldValue] {.inline.} =
  ## The value of layout field `name` of the decoded header `h`; none if `h`
  ## has no such field (raw byte fields included).
  layoutField(h, name)

proc lookup(f: SeismicFile, scope: HeaderScope, index: int, name: string): FieldRead =
  let r = f.index.locate(scope, index, name)
  if r.error.len > 0: FieldRead(error: r.error) else: f.readField(r.blk, r.field)

proc raiseField(name, err: string) {.noinline, noreturn.} =
  raise newException(ValueError, name & ": " & err)

proc required(r: sink FieldRead, name: string): FieldValue {.inline.} =
  if r.error.len > 0: raiseField(name, r.error)
  r.value

func optional(r: sink FieldRead): Option[FieldValue] {.inline.} =
  if r.error.len > 0: none(FieldValue) else: some(r.value)

proc traceField*(f: SeismicFile, trace: int, name: string): FieldValue =
  ## A trace header field by name, e.g. "trace.sourceX" or
  ## "ext1.receiverLine" (SEG-2: "trace.numSamples", "trace.SAMPLE_INTERVAL").
  ## Raises `ValueError` for an unknown field, a trace
  ## out of range or a closed file; the message says which.
  f.lookup(hsTrace, trace, name).required(name)

proc recordField*(f: SeismicFile, record: int, name: string): FieldValue =
  ## A SEG-D record (general header) field by name, e.g. "gh1.formatCode" or
  ## "gh3.sourcePointNumber" (Rev 1/2 source headers). Raises `ValueError`
  ## for an unknown field or record, or a closed file.
  f.lookup(hsRecord, record, name).required(name)

proc fileField*(f: SeismicFile, name: string): FieldValue =
  ## A file-level field by name, e.g. "binary.formatCode" (SEG-Y) or
  ## "file.UNITS" (SEG-2). Raises
  ## `ValueError` for an unknown field or a closed file.
  f.lookup(hsFile, 0, name).required(name)

proc findTraceField*(f: SeismicFile, trace: int, name: string): Option[FieldValue] =
  ## `traceField` when the trace has the field; none otherwise (e.g. a trace
  ## without an `ext1` block).
  f.lookup(hsTrace, trace, name).optional

proc findRecordField*(f: SeismicFile, record: int, name: string): Option[FieldValue] =
  ## `recordField` when the record has the field; none otherwise.
  f.lookup(hsRecord, record, name).optional

proc findFileField*(f: SeismicFile, name: string): Option[FieldValue] =
  ## `fileField` when the file has the field; none otherwise.
  f.lookup(hsFile, 0, name).optional

proc blockKind*(f: SeismicFile, scope: HeaderScope, index: int,
    blockName: string): Option[HeaderBlock] =
  ## The kind of block `blockName` (`trace`, `ext1`, `gh1`, `binary`, ...) of
  ## trace or record `index` (or the file), none if there is no such block;
  ## `fieldNames` lists its fields.
  let r = f.index.locateBlock(scope, index, blockName)
  if r.error.len > 0: none(HeaderBlock) else: some(r.blk.kind)

# ------------------------------------------------------- SEG-2 strings --

proc seg2Strings*(f: SeismicFile, trace: int): seq[Seg2String] =
  ## The keyword strings of SEG-2 trace `trace`, or of the File Descriptor
  ## Block when `trace` is -1, in file order. Raises `ValueError` for a file
  ## that is not SEG-2 or is closed, or a trace out of range.
  f.requireKind(skSeg2)
  if trace == -1: f.index.seg2.strings
  else: f.seg2Trace(trace).strings

# ---------------------------------------------------------- sample timing --

proc sampleIntervalUs*(f: SeismicFile, trace = 0): float64 =
  ## The trace's sample interval in µs (Hz or m/ft for SEG-Y non-time
  ## data), resolved as the readers do. SEG-Y: Ext1 bytes 145-152 when
  ## non-zero, else trace bytes 117-118; fixed-length Rev 1+ files use the
  ## binary header's. SEG-D: the trace's channel set (Rev 3 CSD sampling
  ## interval; Rev 1/2 base scan interval / 2^subscan), else the base scan
  ## interval. SEG-2: the trace's SAMPLE_INTERVAL (seconds) in µs. NaN when
  ## the headers cannot give it (a SEG-Y trace header cut off by the end of
  ## the file, a SEG-2 trace without SAMPLE_INTERVAL): unknown data, not a
  ## caller error. Raises `ValueError` for a trace out of range or a closed
  ## file (the headers are read from the map, as `traceField` does).
  template ix: untyped = f.index
  f.requireTrace(trace)
  f.requireOpen()
  let e = ix.entries[trace]
  case ix.kind
  of skSeg2:
    let si = f.seg2Trace(trace).sampleInterval
    if si.isSome: si.get * 1e6 else: NaN
  of skSegy:
    template b: untyped = ix.segy.binary
    if ix.segy.revision.major >= 1 and b.fixedLengthTraces == 1:
      return b.effectiveSampleInterval
    if int(e.headerBytes) >= 2 * TraceHeaderSize:
      let x = f.findTraceField(trace, "ext1.extSampleInterval")
      if x.isSome and x.get.toFloat != 0: return x.get.toFloat
    let v = f.findTraceField(trace, "trace.sampleInterval")
    if v.isSome: v.get.toFloat else: NaN
  of skSegd, skUnknown: # an unknown file has no traces: checked above
    let cs = if int(e.scanType) >= 0: e.channelSetIndex else: -1
    ix.segdRecords[e.record].sampleIntervalUs(int(e.scanType), cs)

# --------------------------------------------------------- field columns --

type
  ColumnBlock = enum cbTrace, cbExt1

  ColumnPlan = object
    # One trace field resolved for every block kind it can be in.
    which: ColumnBlock
    field: string
    readers: array[HeaderBlock, NumberReader]
    keyword: bool # a SEG-2 keyword string, read the slow way

proc columnKinds(ix: TraceIndex, which: ColumnBlock): set[HeaderBlock] =
  # The block kinds a trace's `trace` or `ext1` block can have in this file.
  case ix.kind
  of skSegy: (if which == cbTrace: {hbSegyTrace} else: {hbSegyExt1})
  of skSegd:
    if which == cbTrace: {hbSegdTrace}
    else:
      var s: set[HeaderBlock]
      for r in ix.segdRecords: s.incl(if r.isRev3: hbSegdExt1Rev3 else: hbSegdExt1)
      s
  of skSeg2: {hbSeg2Trace}
  of skUnknown: {}

proc fieldSpecOf(kind: HeaderBlock, field: string, spec: var FieldSpec, first: var int): bool =
  # The layout of `field` in block kind `kind`; false if it has none.
  withBlockType(kind):
    const table = fieldTable(BlockT) # built at compile time: no allocation here
    for i in 0 ..< table.len:
      if table[i].name == field:
        spec = table[i]
        first = firstByte
        return true

proc planColumn(f: SeismicFile, name: string): ColumnPlan =
  # Resolves `<block>.<field>` once; raises `ValueError` as `traceField` would.
  if f.unsafeMemory == nil: raiseField(name, "the file is closed")
  let dot = name.find('.')
  if dot <= 0 or dot == name.len - 1: raiseField(name, "expected <block>.<field>")
  let blockName = name[0 ..< dot]
  result.field = name[dot + 1 .. ^1]
  if f.kind == skSeg2:
    if blockName != "trace":
      raiseField(name, "the SEG-2 trace block is trace (trace.<field or KEYWORD>)")
    result.which = cbTrace
  else:
    case blockName
    of "trace": result.which = cbTrace
    of "ext1": result.which = cbExt1
    else: raiseField(name, "trace blocks are trace and ext1")
  for k in f.index.columnKinds(result.which):
    var s: FieldSpec
    var first = 0
    if fieldSpecOf(k, result.field, s, first):
      if s.kind in {fkBytes, fkText}: raiseField(name, "is not a numeric field")
      result.readers[k] = numberReader(s, first)
    elif k == hbSeg2Trace: result.keyword = true
    else: raiseField(name, "is not a field of " & $k)

proc keywordNumber(f: SeismicFile, p: ColumnPlan, offset: int64, size: int): float64 =
  # A SEG-2 keyword string's value as a number; NaN when missing or not one.
  let strs = f.blockStrings(BlockRef(kind: hbSeg2Trace, offset: offset, size: size))
  let i = strs.find(p.field)
  result = NaN
  if i >= 0:
    try: result = parseFloat(strs[i].value.strip)
    except ValueError: discard

proc columnValue(f: SeismicFile, p: ColumnPlan, mem: ptr UncheckedArray[byte], size: int64,
    trace: int, name: string): float64 =
  # Field `p` of trace `trace`: only its bytes are read.
  template ix: untyped = f.index
  if trace notin 0 ..< ix.len: raiseField(name, "no trace " & $trace)
  let e = ix.entries[trace]
  var kind = hbRaw
  var at = e.offset
  var bytes = 0
  var order = boBig
  case ix.kind
  of skSegy:
    order = ix.segy.byteOrder
    bytes = TraceHeaderSize
    if p.which == cbTrace: kind = hbSegyTrace
    elif int(e.headerBytes) >= 2 * TraceHeaderSize:
      kind = hbSegyExt1
      at += TraceHeaderSize
  of skSegd:
    if p.which == cbTrace:
      kind = hbSegdTrace
      bytes = SegdTraceHeaderSize
    elif int(e.headerBytes) >= SegdTraceHeaderSize + SegdBlockSize:
      kind = if ix.segdRecords[e.record].isRev3: hbSegdExt1Rev3 else: hbSegdExt1
      at += SegdTraceHeaderSize
      bytes = SegdBlockSize
  of skSeg2:
    if e.headerBytes > 0:
      kind = hbSeg2Trace
      order = ix.seg2.order
      bytes = int(e.headerBytes)
  of skUnknown: discard
  if kind == hbRaw: NaN # the trace lacks the block
  elif at < 0 or at + bytes > size: raiseField(name, "the header lies outside the file")
  elif p.keyword: f.keywordNumber(p, at, bytes)
  else: p.readers[kind].readNumber(mem.toOpenArray(int(at), int(at) + bytes - 1), order)

proc traceFieldColumnInto*(f: SeismicFile, name: string, traces: openArray[int],
    dst: var openArray[float64]) =
  ## `traceFieldColumn` into `dst` (one value per trace of `traces`), reusing
  ## the caller's buffer. Raises `ValueError` as `traceFieldColumn` does, or
  ## when `dst.len != traces.len`.
  if dst.len != traces.len:
    raise newException(ValueError, "need " & $traces.len & " values, got " & $dst.len)
  let p = f.planColumn(name)
  let mem = f.unsafeMemory
  let size = f.mappedSize
  for k, t in traces: dst[k] = f.columnValue(p, mem, size, t, name)

proc traceFieldColumnInto*(f: SeismicFile, name: string, traces: Slice[int],
    dst: var openArray[float64]) =
  ## `traceFieldColumnInto` for a range of traces.
  checkSpan(traces, f.len)
  let n = spanLen(traces)
  if dst.len != n: raise newException(ValueError, "need " & $n & " values, got " & $dst.len)
  let p = f.planColumn(name)
  let mem = f.unsafeMemory
  let size = f.mappedSize
  for k in 0 ..< n: dst[k] = f.columnValue(p, mem, size, traces.a + k, name)

proc traceFieldColumn*(f: SeismicFile, name: string, traces: openArray[int]): seq[float64] =
  ## A numeric trace header field (`traceField` names, e.g. "trace.sourceX",
  ## "ext1.receiverLine") of each trace of `traces`, as float64. The field is
  ## resolved once and only its bytes are read per trace, so this is much
  ## cheaper than a `traceField` loop. A trace without the block (no `ext1`,
  ## a SEG-2 trace without a valid descriptor) gives NaN. SEG-2 keyword
  ## strings are parsed as numbers (NaN when missing or not a number).
  ## Raises `ValueError` for an unknown, text or raw field, a trace out of
  ## range or a closed file.
  result = newSeq[float64](traces.len)
  f.traceFieldColumnInto(name, traces, result)

proc traceFieldColumn*(f: SeismicFile, name: string, traces: Slice[int]): seq[float64] =
  ## `traceFieldColumn` for a range of traces (an empty range must start in
  ## `0 .. f.len`).
  checkSpan(traces, f.len)
  result = newSeq[float64](spanLen(traces))
  f.traceFieldColumnInto(name, traces, result)
