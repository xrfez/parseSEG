## Header fields by name (task 8.2): read any header field of a mapped file
## as `<block>.<field>`, with the field names of the header types. The same
## names (and this module's block lookup) serve the in-place editor
## (`model/edit`) and the C ABI.
##
## | Standard | Per trace (`traceField`) | Per record (`recordField`) | Per file (`fileField`) |
## |---|---|---|---|
## | SEG-Y | `trace`, `ext1` (Trace Header Extension 1) | | `binary` |
## | SEG-D | `trace` (demux header), `ext1` (THE#1, Rev 1/2 or Rev 3 layout by record) | `gh1`, and for Rev 1/2 `gh3`, `gh4`, ... (source headers) | |
##
## Values are read from the mapped bytes, so they reflect in-place edits at
## once. Integers (BCD included; -1 = all F, -2 = invalid BCD) come back as
## `fvInt`, floats and fixed point as `fvFloat`, character fields as
## `fvText`. Raw byte fields are not fields here.

import std/[macros, math, strutils]
import ../common/[endians, fieldlayout]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ./traceindex

type
  FieldValueKind* = enum fvInt, fvFloat, fvText

  FieldValue* = object
    ## A header field's value.
    case kind*: FieldValueKind
    of fvInt: i*: int64
    of fvFloat: f*: float64
    of fvText: s*: string

  HeaderBlock* = enum
    ## The header block types that have named fields.
    hbSegyBinary = "SEG-Y binary"
    hbSegyTrace = "SEG-Y trace"
    hbSegyExt1 = "SEG-Y ext1"
    hbSegdTrace = "SEG-D trace"
    hbSegdExt1 = "SEG-D ext1"
    hbSegdExt1Rev3 = "SEG-D Rev 3 ext1"
    hbSegdGh1 = "SEG-D gh1"
    hbSegdGhN = "SEG-D ghN"

  BlockRef* = object
    ## Where one header block of a file lies.
    kind*: HeaderBlock
    offset*: int64     ## Medium offset of the block's first byte.
    size*: int
    order*: ByteOrder
    name*: string      ## The block name as written (`trace`, `gh3`, ...).
    sourceIndex*: int  ## For `hbSegdGhN`: index into `SegdRecord.sourceHeaders`.

func toFieldValue*(v: SomeInteger): FieldValue = FieldValue(kind: fvInt, i: int64(v))
func toFieldValue*(v: SomeFloat): FieldValue = FieldValue(kind: fvFloat, f: float64(v))
func toFieldValue*(v: string): FieldValue = FieldValue(kind: fvText, s: v)

func `$`*(v: FieldValue): string =
  case v.kind
  of fvInt: $v.i
  of fvFloat: $v.f
  of fvText: v.s.escape

func toFloat*(v: FieldValue): float64 =
  ## The value as a number (NaN for text).
  case v.kind
  of fvInt: float64(v.i)
  of fvFloat: v.f
  of fvText: NaN

func splitName*(name: string, blockName, field: var string): bool =
  ## Splits `<block>.<field>`.
  let dot = name.find('.')
  if dot <= 0 or dot == name.len - 1: return false
  blockName = name[0 ..< dot]
  field = name[dot + 1 .. ^1]
  true

template withBlockType*(k: HeaderBlock, body: untyped) =
  ## Runs `body` with `BlockT` (the header type) and `firstByte` (its first
  ## spec byte number) bound for block kind `k`.
  case k
  of hbSegyBinary:
    type BlockT {.inject.} = SegyBinaryHeader
    const firstByte {.inject.} = 3201
    body
  of hbSegyTrace:
    type BlockT {.inject.} = SegyTraceHeader
    const firstByte {.inject.} = 1
    body
  of hbSegyExt1:
    type BlockT {.inject.} = SegyTraceHeaderExt1
    const firstByte {.inject.} = 1
    body
  of hbSegdTrace:
    type BlockT {.inject.} = SegdTraceHeader
    const firstByte {.inject.} = 1
    body
  of hbSegdExt1:
    type BlockT {.inject.} = SegdTraceHeaderExt1
    const firstByte {.inject.} = 1
    body
  of hbSegdExt1Rev3:
    type BlockT {.inject.} = SegdTraceHeaderExt1Rev3
    const firstByte {.inject.} = 1
    body
  of hbSegdGh1:
    type BlockT {.inject.} = SegdGeneralHeader1
    const firstByte {.inject.} = 1
    body
  of hbSegdGhN:
    type BlockT {.inject.} = SegdGeneralHeaderN
    const firstByte {.inject.} = 1
    body

template isLayoutField*(f: untyped): bool =
  ## True for fields with a layout pragma (raw copies like `raw` are not).
  f.hasCustomPragma(fieldlayout.at) or f.hasCustomPragma(bcdAt) or
    f.hasCustomPragma(bcdAtL) or f.hasCustomPragma(nibAt) or f.hasCustomPragma(nibAtL) or
    f.hasCustomPragma(at24) or f.hasCustomPragma(fix40) or f.hasCustomPragma(fix24)

proc fieldNames*(k: HeaderBlock): seq[string] =
  ## The named fields of block kind `k`, in layout order (raw byte fields
  ## excluded).
  withBlockType(k):
    var h: BlockT
    for n, f in fieldPairs(h):
      when isLayoutField(f):
        when f is array:
          when typeof(f[0]) is char: result.add n
        else:
          result.add n

# ----------------------------------------------------------------- lookup --

proc locateTraceBlock*(ix: TraceIndex, trace: int, blockName: string, b: var BlockRef,
    err: var string): bool =
  ## Finds block `trace` or `ext1` of trace `trace`. False with `err` set if
  ## there is no such block.
  if trace < 0 or trace >= ix.len:
    err = "no trace " & $trace
    return false
  let e = ix.entries[trace]
  b.name = blockName
  case blockName
  of "trace":
    if ix.kind == skSegy:
      b = BlockRef(kind: hbSegyTrace, offset: e.offset, size: TraceHeaderSize,
        order: ix.segy.byteOrder, name: blockName)
    else:
      b = BlockRef(kind: hbSegdTrace, offset: e.offset, size: SegdTraceHeaderSize, order: boBig,
        name: blockName)
    true
  of "ext1":
    if ix.kind == skSegy:
      if int(e.headerBytes) < 2 * TraceHeaderSize:
        err = "the trace has no Trace Header Extension 1"
        return false
      b = BlockRef(kind: hbSegyExt1, offset: e.offset + TraceHeaderSize, size: TraceHeaderSize,
        order: ix.segy.byteOrder, name: blockName)
    else:
      if int(e.headerBytes) < SegdTraceHeaderSize + SegdBlockSize:
        err = "the trace has no Trace Header Extension #1"
        return false
      b = BlockRef(kind: if ix.segdRecords[e.record].isRev3: hbSegdExt1Rev3 else: hbSegdExt1,
        offset: e.offset + SegdTraceHeaderSize, size: SegdBlockSize, order: boBig,
        name: blockName)
    true
  else:
    err = "trace blocks are trace and ext1"
    false

proc locateFileBlock*(ix: TraceIndex, blockName: string, b: var BlockRef,
    err: var string): bool =
  ## Finds the SEG-Y `binary` header.
  if ix.kind != skSegy or blockName != "binary":
    err = "the file-level block is the SEG-Y binary header (binary.<field>)"
    return false
  b = BlockRef(kind: hbSegyBinary, offset: int64(ix.segy.tapeLabel.len + TextHeaderSize),
    size: BinaryHeaderSize, order: ix.segy.byteOrder, name: blockName)
  true

proc locateRecordBlock*(ix: TraceIndex, record: int, blockName: string, b: var BlockRef,
    err: var string): bool =
  ## Finds block `gh1`, or for Rev 1/2 `gh<N>` (N ≥ 3, a source header), of
  ## SEG-D record `record`.
  if ix.kind != skSegd or record < 0 or record >= ix.segdRecords.len:
    err = "no SEG-D record " & $record
    return false
  let rec = ix.segdRecords[record]
  if blockName == "gh1":
    b = BlockRef(kind: hbSegdGh1, offset: rec.offset, size: SegdBlockSize, order: boBig,
      name: blockName)
    true
  elif blockName.len in 3..6 and blockName.startsWith("gh") and
      blockName[2..^1].allCharsInSet(Digits):
    let n = parseInt(blockName[2..^1])
    if rec.isRev3 or not rec.hasGh2:
      err = "only Rev 1/2 records have source blocks gh3, gh4, ... (Rev 3 general header " &
        "blocks after GH#1 are not supported by name yet)"
      false
    elif n < 3 or n - 3 >= rec.sourceHeaders.len:
      err = "the record has no general header #" & $n & " source block"
      false
    else:
      b = BlockRef(kind: hbSegdGhN, offset: rec.offset + int64(SegdBlockSize) * int64(n - 1),
        size: SegdBlockSize, order: boBig, name: blockName, sourceIndex: n - 3)
      true
  else:
    err = "SEG-D record blocks are gh1 and gh3, gh4, ..."
    false

# ---------------------------------------------------------------- reading --

proc getByName*[T](h: T, name: string, v: var FieldValue): bool =
  ## The value of layout field `name` of header `h`; false if there is none
  ## (raw byte fields included).
  result = false
  for n, f in fieldPairs(h):
    when isLayoutField(f):
      if n == name:
        when f is SomeInteger:
          when f is uint64:
            v = if f > uint64(high(int64)): toFieldValue(float64(f)) else: toFieldValue(int64(f))
          else:
            v = toFieldValue(int64(f))
          result = true
        elif f is SomeFloat:
          v = toFieldValue(float64(f))
          result = true
        elif f is array:
          when typeof(f[0]) is char:
            var s = newString(f.len)
            for k, c in f: s[k] = c
            v = toFieldValue(s)
            result = true

proc readBlockField*(f: SeismicFile, b: BlockRef, field: string, v: var FieldValue,
    err: var string): bool =
  ## Reads `field` of the located block from the mapped bytes.
  let mem = f.memory
  if mem == nil:
    err = "the file is closed"
    return false
  if b.offset < 0 or b.offset + b.size > f.mappedSize:
    err = "the header lies outside the file"
    return false
  let a = int(b.offset)
  withBlockType(b.kind):
    var h: BlockT
    decodeFields(h, mem.toOpenArray(a, a + b.size - 1), firstByte, b.order)
    result = getByName(h, field, v)
  if not result: err = "is not a field of " & $b.kind

proc traceField*(f: SeismicFile, trace: int, name: string, v: var FieldValue,
    err: var string): bool =
  ## Reads `trace.<field>` or `ext1.<field>` of trace `trace`.
  var blockName, field: string
  var b: BlockRef
  if not splitName(name, blockName, field):
    err = "expected <block>.<field>"
    false
  else:
    f.index.locateTraceBlock(trace, blockName, b, err) and f.readBlockField(b, field, v, err)

proc recordField*(f: SeismicFile, record: int, name: string, v: var FieldValue,
    err: var string): bool =
  ## Reads a SEG-D general header field (`gh1.<field>`, `gh3.<field>`, ...).
  var blockName, field: string
  var b: BlockRef
  if not splitName(name, blockName, field):
    err = "expected <block>.<field>"
    false
  else:
    f.index.locateRecordBlock(record, blockName, b, err) and f.readBlockField(b, field, v, err)

proc fileField*(f: SeismicFile, name: string, v: var FieldValue, err: var string): bool =
  ## Reads a SEG-Y binary header field (`binary.<field>`).
  var blockName, field: string
  var b: BlockRef
  if not splitName(name, blockName, field):
    err = "expected <block>.<field>"
    false
  else:
    f.index.locateFileBlock(blockName, b, err) and f.readBlockField(b, field, v, err)

proc traceField*(f: SeismicFile, trace: int, name: string, v: var FieldValue): bool =
  ## As above, without the reason.
  var err: string
  f.traceField(trace, name, v, err)

proc recordField*(f: SeismicFile, record: int, name: string, v: var FieldValue): bool =
  var err: string
  f.recordField(record, name, v, err)

proc fileField*(f: SeismicFile, name: string, v: var FieldValue): bool =
  var err: string
  f.fileField(name, v, err)

# ---------------------------------------------------------- sample timing --

proc sampleIntervalUs*(f: SeismicFile, trace: int): float64 =
  ## The trace's sample interval in µs (Hz or m/ft for SEG-Y non-time
  ## data), resolved as the readers do. SEG-Y: Ext1 bytes 145-152 when
  ## non-zero, else trace bytes 117-118; fixed-length Rev 1+ files use the
  ## binary header's. SEG-D: the trace's channel set (Rev 3 CSD sampling
  ## interval; Rev 1/2 base scan interval / 2^subscan), else the base scan
  ## interval. NaN when unknown (a closed file, an out-of-range trace).
  let ix = f.index
  if trace < 0 or trace >= ix.len or f.memory == nil: return NaN
  let e = ix.entries[trace]
  if ix.kind == skSegy:
    let b = ix.segy.binary
    if ix.segy.revision.major >= 1 and b.fixedLengthTraces == 1:
      return b.effectiveSampleInterval
    var v: FieldValue
    if int(e.headerBytes) >= 2 * TraceHeaderSize and
        f.traceField(trace, "ext1.extSampleInterval", v) and v.toFloat != 0:
      return v.toFloat
    if f.traceField(trace, "trace.sampleInterval", v): v.toFloat else: NaN
  else:
    let rec = ix.segdRecords[e.record]
    let cs = e.channelSetIndex
    if rec.isRev3:
      if cs >= 0 and int(e.scanType) >= 0:
        float64(rec.scanTypes[e.scanType].descriptors3[cs].samplingInterval)
      else:
        baseScanIntervalUs(rec.gh1, rec.gh2r3)
    elif cs >= 0 and int(e.scanType) >= 0:
      rec.scanTypes[e.scanType].descriptors[cs].sampleIntervalMs(rec.gh1) * 1000
    else:
      rec.gh1.baseScanIntervalMs * 1000
