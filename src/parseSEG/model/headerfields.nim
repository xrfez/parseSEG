## Header fields by name (task 8.2): read any header field of a mapped file
## as `<block>.<field>`, with the field names of the header types. The same
## names (and this module's block lookup) serve the in-place editor
## (`model/edit`) and the C ABI.
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
## `fieldNames` lists the fixed fields; `seg2StringCount`, `seg2Keyword` and
## `seg2Value` list the strings of a block. SEG-2 fields are read-only: a
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
import ./traceindex

type
  FieldValueKind* = enum
    ## The kind of value a header field holds.
    fvInt   ## Integers, BCD included.
    fvFloat ## Floats and fixed point.
    fvText  ## Character fields.

  FieldValue* = object
    ## A header field's value.
    case kind*: FieldValueKind
    of fvInt: intVal*: int64
    of fvFloat: floatVal*: float64
    of fvText: text*: string

  HeaderBlock* = enum
    ## The header block types that have named fields. Fields and edits by
    ## name reach the first eight; header listings (`model/headerlist`) show
    ## them all.
    hbSegyBinary = "SEG-Y binary"
    hbSegyTrace = "SEG-Y trace"
    hbSegyExt1 = "SEG-Y ext1"
    hbSegdTrace = "SEG-D trace"
    hbSegdExt1 = "SEG-D ext1"
    hbSegdExt1Rev3 = "SEG-D Rev 3 ext1"
    hbSegdGh1 = "SEG-D gh1"
    hbSegdGhN = "SEG-D ghN"
    hbSegdGh2 = "SEG-D gh2"
    hbSegdGh2Rev3 = "SEG-D Rev 3 gh2"
    hbSegdGh3Rev3 = "SEG-D Rev 3 gh3"
    hbSegdChannelSet = "SEG-D channel set"
    hbSegdChannelSetRev3 = "SEG-D Rev 3 channel set"
    hbSegdPosition = "SEG-D position"
    hbSegdSourceDescription = "SEG-D source description"
    hbSegdAdditionalSourceInfo = "SEG-D additional source info"
    hbSegdSensorInfo = "SEG-D sensor info"
    hbSegdTimestamp = "SEG-D timestamp"
    hbSegdSensorCalibration = "SEG-D sensor calibration"
    hbSegdTimeDrift = "SEG-D time drift"
    hbSegdOrientation = "SEG-D orientation"
    hbSegdTrailerDescription = "SEG-D trailer description"
    hbRaw = "raw" ## A block without named fields (listings only).
    hbSeg2File = "SEG-2 file"   ## The File Descriptor Block (fixed part and strings).
    hbSeg2Trace = "SEG-2 trace" ## A Trace Descriptor Block (fixed part and strings).

  HeaderScope* = enum
    ## Where a named field lives: the file (`fileField`), a SEG-D record
    ## (`recordField`) or a trace (`traceField`).
    hsFile = "file", hsRecord = "record", hsTrace = "trace"

  BlockRef* = object
    ## Where one header block of a file lies.
    kind*: HeaderBlock
    offset*: int64     ## Medium offset of the block's first byte.
    size*: int
    order*: ByteOrder
    name*: string      ## The block name as written (`trace`, `gh3`, ...).
    sourceIndex*: int  ## For `hbSegdGhN`: index into `SegdRecord.sourceHeaders`.

  FieldRef* = object
    ## **Internal.** A located field (`locate`): its block and field name, or
    ## why there is none.
    blk*: BlockRef
    field*: string
    error*: string ## Empty when the block was found.

  FieldRead* = object
    ## **Internal.** A field read from the map (`readField`), or why not.
    value*: FieldValue
    error*: string ## Empty when the value was read.

  RawBlock = object
    ## The (fieldless) header type of `hbRaw`.

func toFieldValue*(v: SomeInteger): FieldValue =
  ## An integer value (`fvInt`).
  FieldValue(kind: fvInt, intVal: int64(v))

func toFieldValue*(v: SomeFloat): FieldValue =
  ## A float value (`fvFloat`).
  FieldValue(kind: fvFloat, floatVal: float64(v))

func toFieldValue*(v: string): FieldValue =
  ## A text value (`fvText`).
  FieldValue(kind: fvText, text: v)

func `==`*(a, b: FieldValue): bool =
  ## Same kind and value (floats compare as floats: NaN differs from NaN).
  a.kind == b.kind and (case a.kind
    of fvInt: a.intVal == b.intVal
    of fvFloat: a.floatVal == b.floatVal
    of fvText: a.text == b.text)

func `$`*(v: FieldValue): string =
  ## The value as written in edits and listings: text quoted and escaped.
  case v.kind
  of fvInt: $v.intVal
  of fvFloat: $v.floatVal
  of fvText: v.text.escape

func toFloat*(v: FieldValue): float64 =
  ## The value as a number (NaN for text).
  case v.kind
  of fvInt: float64(v.intVal)
  of fvFloat: v.floatVal
  of fvText: NaN

template withBlockType*(k: HeaderBlock, body: untyped) =
  ## **Internal.** Runs `body` with `BlockT` (the header type) and
  ## `firstByte` (its first spec byte number) bound for block kind `k`.
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
  of hbSegdGh2:
    type BlockT {.inject.} = SegdGeneralHeader2
    const firstByte {.inject.} = 1
    body
  of hbSegdGh2Rev3:
    type BlockT {.inject.} = SegdGeneralHeader2Rev3
    const firstByte {.inject.} = 1
    body
  of hbSegdGh3Rev3:
    type BlockT {.inject.} = SegdGeneralHeader3
    const firstByte {.inject.} = 1
    body
  of hbSegdChannelSet:
    type BlockT {.inject.} = SegdChannelSetDescriptor
    const firstByte {.inject.} = 1
    body
  of hbSegdChannelSetRev3:
    type BlockT {.inject.} = SegdChannelSetDescriptorRev3
    const firstByte {.inject.} = 1
    body
  of hbSegdPosition:
    type BlockT {.inject.} = SegdPositionBlock
    const firstByte {.inject.} = 1
    body
  of hbSegdSourceDescription:
    type BlockT {.inject.} = SegdSourceDescription
    const firstByte {.inject.} = 1
    body
  of hbSegdAdditionalSourceInfo:
    type BlockT {.inject.} = SegdAdditionalSourceInfo
    const firstByte {.inject.} = 1
    body
  of hbSegdSensorInfo:
    type BlockT {.inject.} = SegdSensorInfo
    const firstByte {.inject.} = 1
    body
  of hbSegdTimestamp:
    type BlockT {.inject.} = SegdTimestampHeader
    const firstByte {.inject.} = 1
    body
  of hbSegdSensorCalibration:
    type BlockT {.inject.} = SegdSensorCalibration
    const firstByte {.inject.} = 1
    body
  of hbSegdTimeDrift:
    type BlockT {.inject.} = SegdTimeDrift
    const firstByte {.inject.} = 1
    body
  of hbSegdOrientation:
    type BlockT {.inject.} = SegdOrientation
    const firstByte {.inject.} = 1
    body
  of hbSegdTrailerDescription:
    type BlockT {.inject.} = SegdTrailerDescription
    const firstByte {.inject.} = 1
    body
  of hbRaw:
    type BlockT {.inject.} = RawBlock
    const firstByte {.inject.} = 1
    body
  of hbSeg2File:
    type BlockT {.inject.} = Seg2FileFixed
    const firstByte {.inject.} = 0 # SEG-2 numbers bytes from 0
    body
  of hbSeg2Trace:
    type BlockT {.inject.} = Seg2TraceFixed
    const firstByte {.inject.} = 0
    body

template isLayoutField*(f: untyped): bool =
  ## **Internal.** True for fields with a layout pragma (raw copies like
  ## `raw` are not).
  f.hasCustomPragma(fieldlayout.at) or f.hasCustomPragma(bcdAt) or
    f.hasCustomPragma(bcdAtL) or f.hasCustomPragma(nibAt) or f.hasCustomPragma(nibAtL) or
    f.hasCustomPragma(at24) or f.hasCustomPragma(fix40) or f.hasCustomPragma(fix24)

template isNamedField*(f: untyped): bool =
  ## **Internal.** A layout field `fieldNames` lists: raw byte arrays are
  ## not.
  isLayoutField(f) and (when f is array: typeof(f[0]) is char else: true)

proc fieldNames*(kind: HeaderBlock): seq[string] =
  ## The named fields of block kind `kind`, in layout order (raw byte fields
  ## excluded; none for `hbRaw`).
  withBlockType(kind):
    var h: BlockT
    for n, f in fieldPairs(h):
      when isNamedField(f): result.add n

# ----------------------------------------------------------------- lookup --

proc traceBlock(ix: TraceIndex, trace: int, blockName: string, b: var FieldRef) =
  # Block `trace` or `ext1` of trace `trace`.
  if trace notin 0 ..< ix.len:
    b.error = "no trace " & $trace
    return
  let e = ix.entries[trace]
  if ix.kind == skSeg2:
    if blockName != "trace":
      b.error = "the SEG-2 trace block is trace (trace.<field or KEYWORD>)"
    elif e.headerBytes == 0:
      b.error = "the trace has no valid Trace Descriptor Block"
    else:
      b.blk = BlockRef(kind: hbSeg2Trace, offset: e.offset, size: int(e.headerBytes),
        order: ix.seg2.order, name: blockName)
    return
  case blockName
  of "trace":
    b.blk = if ix.kind == skSegy:
        BlockRef(kind: hbSegyTrace, offset: e.offset, size: TraceHeaderSize,
          order: ix.segy.byteOrder, name: blockName)
      else:
        BlockRef(kind: hbSegdTrace, offset: e.offset, size: SegdTraceHeaderSize, order: boBig,
          name: blockName)
  of "ext1":
    if ix.kind == skSegy:
      if int(e.headerBytes) < 2 * TraceHeaderSize:
        b.error = "the trace has no Trace Header Extension 1"
      else:
        b.blk = BlockRef(kind: hbSegyExt1, offset: e.offset + TraceHeaderSize,
          size: TraceHeaderSize, order: ix.segy.byteOrder, name: blockName)
    elif int(e.headerBytes) < SegdTraceHeaderSize + SegdBlockSize:
      b.error = "the trace has no Trace Header Extension #1"
    else:
      b.blk = BlockRef(kind: if ix.segdRecords[e.record].isRev3: hbSegdExt1Rev3 else: hbSegdExt1,
        offset: e.offset + SegdTraceHeaderSize, size: SegdBlockSize, order: boBig,
        name: blockName)
  else:
    b.error = "trace blocks are trace and ext1"

proc fileBlock(ix: TraceIndex, blockName: string, b: var FieldRef) =
  # The SEG-Y `binary` header.
  if ix.kind == skSeg2:
    if blockName != "file":
      b.error = "the SEG-2 file-level block is file (file.<field or KEYWORD>)"
    else:
      # The fixed part and the pointers; the strings follow (see `seg2Strings`).
      b.blk = BlockRef(kind: hbSeg2File, offset: 0,
        size: Seg2FixedSize + int(ix.seg2.pointerBytes), order: ix.seg2.order, name: blockName)
  elif ix.kind != skSegy or blockName != "binary":
    b.error = "the file-level block is the SEG-Y binary header (binary.<field>)"
  else:
    b.blk = BlockRef(kind: hbSegyBinary, offset: int64(ix.segy.tapeLabel.len + TextHeaderSize),
      size: BinaryHeaderSize, order: ix.segy.byteOrder, name: blockName)

proc recordBlock(ix: TraceIndex, record: int, blockName: string, b: var FieldRef) =
  # Block `gh1`, or for Rev 1/2 `gh<N>` (N >= 3, a source header), of a SEG-D
  # record.
  if ix.kind != skSegd or record notin 0 ..< ix.segdRecords.len:
    b.error = "no SEG-D record " & $record
    return
  template rec: untyped = ix.segdRecords[record]
  if blockName == "gh1":
    b.blk = BlockRef(kind: hbSegdGh1, offset: rec.offset, size: SegdBlockSize, order: boBig,
      name: blockName)
  elif blockName.len in 3..6 and blockName.startsWith("gh") and
      blockName[2..^1].allCharsInSet(Digits) and blockName[2] != '0':
    let n = parseInt(blockName[2..^1])
    if rec.isRev3 or rec.gh2.isNone:
      b.error = "only Rev 1/2 records have source blocks gh3, gh4, ... (Rev 3 general " &
        "header blocks after GH#1 are not supported by name yet)"
    elif n < 3 or n - 3 >= rec.sourceHeaders.len:
      b.error = "the record has no general header #" & $n & " source block"
    else:
      b.blk = BlockRef(kind: hbSegdGhN, offset: rec.offset + int64(SegdBlockSize) * int64(n - 1),
        size: SegdBlockSize, order: boBig, name: blockName, sourceIndex: n - 3)
  else:
    b.error = "SEG-D record blocks are gh1 and gh3, gh4, ..."

proc locateBlock*(ix: TraceIndex, scope: HeaderScope, index: int,
    blockName: string): FieldRef =
  ## **Internal.** Block `blockName` of the file, of record `index` or of
  ## trace `index`; `error` says why there is none.
  case scope
  of hsFile: ix.fileBlock(blockName, result)
  of hsRecord: ix.recordBlock(index, blockName, result)
  of hsTrace: ix.traceBlock(index, blockName, result)

proc locate*(ix: TraceIndex, scope: HeaderScope, index: int, name: string): FieldRef =
  ## **Internal.** The block and field of `<block>.<field>` in `scope`
  ## (`index` is the record or trace; ignored for the file); `error` says why
  ## there is none. The field itself is checked when it is read or set.
  let dot = name.find('.')
  if dot <= 0 or dot == name.len - 1:
    return FieldRef(error: "expected <block>.<field>")
  result = ix.locateBlock(scope, index, name[0 ..< dot])
  result.field = name[dot + 1 .. ^1]

# ---------------------------------------------------------------- reading --

proc fieldValueOf*[F](f: F): Option[FieldValue] =
  ## **Internal.** A decoded layout field's value; none for raw byte arrays.
  when f is SomeInteger:
    when f is uint64:
      some(if f > uint64(high(int64)): toFieldValue(float64(f)) else: toFieldValue(int64(f)))
    else:
      some(toFieldValue(int64(f)))
  elif f is SomeFloat:
    some(toFieldValue(float64(f)))
  elif f is array and typeof(f[0]) is char:
    var s = newString(f.len)
    for k, c in f: s[k] = c
    some(toFieldValue(s))
  else:
    none(FieldValue)

proc fieldByName*[T](h: T, name: string): Option[FieldValue] =
  ## The value of layout field `name` of the decoded header `h`; none if `h`
  ## has no such field (raw byte fields included).
  for n, f in fieldPairs(h):
    when isLayoutField(f):
      if n == name: return fieldValueOf(f)
  none(FieldValue)

proc checkBlock(f: SeismicFile, b: BlockRef): string =
  # Why the located block cannot be read; empty when it can.
  if f.unsafeMemory == nil: "the file is closed"
  elif b.offset < 0 or b.offset + b.size > f.mappedSize: "the header lies outside the file"
  else: ""

proc blockStrings(f: SeismicFile, b: BlockRef): seq[Seg2String] =
  # The keyword strings of a located SEG-2 block (checked by `checkBlock`).
  if b.kind == hbSeg2File: f.index.seg2.strings
  else:
    let a = int(b.offset)
    blockStrings(f.unsafeMemory.toOpenArray(0, int(f.mappedSize) - 1), a + Seg2FixedSize,
      a + b.size, f.index.seg2)

proc readField(f: SeismicFile, b: BlockRef, field: string, bytes: openArray[byte],
    fromMap: bool): FieldRead =
  let err = f.checkBlock(b)
  if err.len > 0: return FieldRead(error: err)
  let a = int(b.offset)
  var v = none(FieldValue)
  withBlockType(b.kind):
    var h: BlockT
    if fromMap: decodeFields(h, f.unsafeMemory.toOpenArray(a, a + b.size - 1), firstByte, b.order)
    else: decodeFields(h, bytes, firstByte, b.order)
    v = fieldByName(h, field)
  if v.isNone and b.kind in {hbSeg2File, hbSeg2Trace}:
    let strs = f.blockStrings(b)
    let i = strs.find(field)
    if i >= 0: v = some(toFieldValue(strs[i].value))
    else:
      return FieldRead(error: "is neither a fixed field of the " & $b.kind &
        " block nor a keyword string it holds")
  if v.isSome: FieldRead(value: v.get)
  else: FieldRead(error: "is not a field of " & $b.kind)

proc readField*(f: SeismicFile, b: BlockRef, field: string): FieldRead =
  ## **Internal.** Reads `field` of the located block from the mapped bytes;
  ## `error` says why it cannot. A SEG-2 block also has its keyword strings
  ## as fields.
  f.readField(b, field, [], fromMap = true)

proc readField*(f: SeismicFile, b: BlockRef, field: string, bytes: openArray[byte]): FieldRead =
  ## **Internal.** As above, decoding the block from `bytes` (its `b.size`
  ## bytes as edited so far, `HeaderEditor`) instead of the map; SEG-2 keyword
  ## strings still come from the map.
  f.readField(b, field, bytes, fromMap = false)

proc readFields*(f: SeismicFile, b: BlockRef, values: var seq[Option[FieldValue]]): string =
  ## **Internal.** Decodes the located block once: `values` gets the value of
  ## each of `fieldNames(b.kind)`, in that order (none where `readField` would
  ## fail). Returns why the block cannot be read (`values` is then empty), or "".
  values.setLen 0
  result = f.checkBlock(b)
  if result.len == 0:
    let mem = f.unsafeMemory
    let a = int(b.offset)
    withBlockType(b.kind):
      var h: BlockT
      decodeFields(h, mem.toOpenArray(a, a + b.size - 1), firstByte, b.order)
      for x in fields(h):
        when isNamedField(x): values.add fieldValueOf(x)

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
  if f.kind != skSeg2: raise newException(ValueError, "not a SEG-2 file")
  if trace == -1: f.index.seg2.strings
  else: f.seg2Trace(trace).strings

proc seg2StringCount*(f: SeismicFile, trace: int): int =
  ## How many keyword strings SEG-2 trace `trace` has (-1: the File
  ## Descriptor Block); read them with `seg2Keyword` and `seg2Value`. Raises
  ## `ValueError` like `seg2Strings`.
  f.seg2Strings(trace).len

proc seg2String(f: SeismicFile, trace, n: int): Seg2String =
  let s = f.seg2Strings(trace)
  if n notin 0 ..< s.len:
    raise newException(ValueError, "no string " & $n & " (the block has " & $s.len & ")")
  s[n]

proc seg2Keyword*(f: SeismicFile, trace, n: int): string =
  ## The keyword of string `n` of SEG-2 trace `trace` (-1: the File
  ## Descriptor Block), as written. Raises `ValueError` like `seg2Strings`,
  ## and for `n` out of range.
  f.seg2String(trace, n).key

proc seg2Value*(f: SeismicFile, trace, n: int): string =
  ## The value of string `n` of SEG-2 trace `trace` (-1: the File
  ## Descriptor Block), terminators stripped (NOTE lines are separated by
  ## the file's Line Terminator). Raises `ValueError` like `seg2Keyword`.
  f.seg2String(trace, n).value

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
  if trace notin 0 ..< ix.len:
    raise newException(ValueError, "no trace " & $trace & " (the file has " & $ix.len & ")")
  if not f.isOpen: raise newException(ValueError, "the file is closed")
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
