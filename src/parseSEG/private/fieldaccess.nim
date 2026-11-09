## The header-field access layer under `model/headerfields` and the
## editor (`model/edit`): locating a named block of a trace, record or file
## (`locateBlock`, `locate`), binding a block kind to its header type
## (`withBlockType`), and reading fields from the mapped bytes (`readField`,
## `readFields`). Library modules import it; nothing re-exports it.

import std/[macros, options, strutils]
import ../common/[endians, fieldlayout]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ../seg2/[headers as seg2headers, reader as seg2reader]
import ../model/[traceindex, fieldvalues]

type
  FieldRef* = object
    ## A located field (`locate`): its block and field name, or
    ## why there is none.
    blk*: BlockRef
    field*: string
    error*: string ## Empty when the block was found.

  FieldRead* = object
    ## A field read from the map (`readField`), or why not.
    value*: FieldValue
    error*: string ## Empty when the value was read.

  RawBlock = object
    ## The (fieldless) header type of `hbRaw`.

template withBlockType*(k: HeaderBlock, body: untyped) =
  ## Runs `body` with `BlockT` (the header type) and
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
  ## True for fields with a layout pragma (raw copies like
  ## `raw` are not).
  f.hasCustomPragma(fieldlayout.at) or f.hasCustomPragma(bcdAt) or
    f.hasCustomPragma(bcdAtL) or f.hasCustomPragma(nibAt) or f.hasCustomPragma(nibAtL) or
    f.hasCustomPragma(at24) or f.hasCustomPragma(fix40) or f.hasCustomPragma(fix24)

template isNamedField*(f: untyped): bool =
  ## A layout field `fieldNames` lists: raw byte arrays are
  ## not.
  isLayoutField(f) and (when f is array: typeof(f[0]) is char else: true)

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
  ## Block `blockName` of the file, of record `index` or of
  ## trace `index`; `error` says why there is none.
  case scope
  of hsFile: ix.fileBlock(blockName, result)
  of hsRecord: ix.recordBlock(index, blockName, result)
  of hsTrace: ix.traceBlock(index, blockName, result)

proc locate*(ix: TraceIndex, scope: HeaderScope, index: int, name: string): FieldRef =
  ## The block and field of `<block>.<field>` in `scope`
  ## (`index` is the record or trace; ignored for the file); `error` says why
  ## there is none. The field itself is checked when it is read or set.
  let dot = name.find('.')
  if dot <= 0 or dot == name.len - 1:
    return FieldRef(error: "expected <block>.<field>")
  result = ix.locateBlock(scope, index, name[0 ..< dot])
  result.field = name[dot + 1 .. ^1]

# ---------------------------------------------------------------- reading --

proc fieldValueOf*[F](f: F): Option[FieldValue] =
  ## A decoded layout field's value; none for raw byte arrays.
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

proc layoutField*[T](h: T, name: string): Option[FieldValue] =
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

proc blockStrings*(f: SeismicFile, b: BlockRef): seq[Seg2String] =
  ## The keyword strings of a located SEG-2 block (checked by `checkBlock`).
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
    v = layoutField(h, field)
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
  ## Reads `field` of the located block from the mapped bytes;
  ## `error` says why it cannot. A SEG-2 block also has its keyword strings
  ## as fields.
  f.readField(b, field, [], fromMap = true)

proc readField*(f: SeismicFile, b: BlockRef, field: string, bytes: openArray[byte]): FieldRead =
  ## As above, decoding the block from `bytes` (its `b.size`
  ## bytes as edited so far, `HeaderEditor`) instead of the map; SEG-2 keyword
  ## strings still come from the map.
  f.readField(b, field, bytes, fromMap = false)

proc readFields*(f: SeismicFile, b: BlockRef, values: var seq[Option[FieldValue]]): string =
  ## Decodes the located block once: `values` gets the value of
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
