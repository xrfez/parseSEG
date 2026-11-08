## Header listing for a viewer's headers tab (task 6.10): every header of a
## trace, a SEG-D record or the file as ordered rows of (block, field, value,
## byte offset, size).
##
## ```nim
## let f = openSeismic("shot.sgd")
## for row in f.traceHeaders(0):
##   echo row.blockName, ".", row.field, " = ", row.value, " @", row.offset
## let hex = f.copyBytes(row.blockOffset, row.blockSize) # for a hex pane
## ```
##
## The listing is **read-only**: it reads the mapped bytes and never writes.
## A viewer collects its edits as a `HeaderPatch` (or `HeaderChange`s) and
## saves them with `writeHeaderPatch`; applying one is a separate, explicit
## `importHeaders` (a `dryRun` first, preferably with `outPath`).
##
## Block names, in file order:
##
## - trace (`traceHeaders`): `trace`, `ext1`, then `ext2`, `ext3`, ... for the
##   further extensions (SEG-Y: 240-byte proprietary headers; SEG-D Rev 1/2:
##   untyped 32-byte blocks; SEG-D Rev 3: blocks typed by byte 32, a 96-byte
##   Position block counting as three);
## - SEG-D record (`recordHeaders`): `gh1`, `gh2`, ... (every general header
##   block; Rev 3 blocks after GH#3 typed by byte 32), `st<s>cs<c>` (the
##   channel set descriptors, both numbered from 1), `st<s>skew`,
##   `extended`, `external`, `trailer`;
## - file (`fileHeaders`): SEG-Y `label`, `text`, `binary`, `extended`,
##   `trailer`; SEG-D `label` (storage unit label); SEG-2 `file` (the File
##   Descriptor Block, up to the first Trace Descriptor Block);
## - SEG-2 trace: `trace` (its Trace Descriptor Block).
##
## A SEG-2 block (`file` or `trace`) gives one row per fixed-part field
## (`Seg2FileFixed`, `Seg2TraceFixed`), then one row per keyword string in
## file order: `field` is the keyword as written, `value` the string's value
## (`fvText`), `offset`/`size` the string entry (its offset word and
## terminator included). `blockOffset`/`blockSize` span the whole descriptor
## block, strings included. Nothing of SEG-2 can be patched: string edits
## change block sizes, so the editor refuses them (rewrite the file).
##
## Field names are those of `HeaderEditor` and the NIF export
## (`<block>.<field>`), so a row's `blockName & "." & field` is what an edit
## or a patch names. The blocks the editor knows (`trace`, `ext1`, `gh1`,
## `gh3`... of Rev 1/2, `binary`) can be patched; the others are listed for
## reading (an import refuses patches to them, with the reason in its log).
##
## A block without named fields (raw: text headers, user-defined or
## undefined SEG-D blocks, untyped extensions) gives one row with an empty
## `field`, kind `hbRaw` and a text value naming what it is.

import std/options
import ../common/[endians, fieldlayout]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ../seg2/[reader as seg2reader]
import ./[traceindex, headerfields]
import ../abi/pragmas

type
  HeaderRow* = object
    ## One field of a header listing.
    blockName*: string ## The block's name in field names: `trace`, `ext1`, `gh1`, `binary`, ...
    kind*: HeaderBlock ## The block's type (`fieldNames(kind)` lists its fields); `hbRaw` if none.
    field*: string     ## The field name; empty for a block without named fields.
    value*: FieldValue ## The value as decoded (a raw block: text naming what it is).
    offset*: int64     ## File offset of the field's first byte.
    size*: int
      ## Bytes holding the field (a BCD or nibble field: the bytes its
      ## nibbles touch).
    blockOffset*: int64 ## File offset of the block (`copyBytes(blockOffset, blockSize)`).
    blockSize*: int    ## Bytes in the block.

  HeaderListing* {.segHandle.} = object
    ## The ordered header rows of one trace, record or file.
    rows: seq[HeaderRow]

func len*(l: HeaderListing): int {.inline, segApi.} =
  ## The number of rows.
  l.rows.len

func `[]`*(l: HeaderListing; i: int): lent HeaderRow {.inline, segApi.} =
  ## Row `i`, in file order. As for a `seq`, an `i` outside `0 ..< len` is a
  ## bug (`IndexDefect`).
  l.rows[i]

iterator items*(l: HeaderListing): lent HeaderRow =
  ## Yields the rows in file order.
  for r in l.rows: yield r

iterator pairs*(l: HeaderListing): (int, lent HeaderRow) =
  ## Yields `(index, row)` pairs in file order.
  for i, r in l.rows: yield (i, r)

# ---------------------------------------------------------------- builder --

type Lister = object
  mem: ptr UncheckedArray[byte]
  size: int64
  rows: seq[HeaderRow]

proc addFields[T](L: var Lister, name: string, kind: HeaderBlock, pos: int64, size: int,
    firstByte: static int, order: ByteOrder) =
  # One row per named field of the block of type `T` at `pos`.
  var h: T
  let a = int(pos)
  decodeFields(h, L.mem.toOpenArray(a, a + size - 1), firstByte, order)
  const specs = fieldTable(T)
  var k = 0
  for n, v in fieldPairs(h):
    when isLayoutField(v):
      when isNamedField(v):
        let first = specs[k].firstNibble div 2 - (firstByte - 1)
        let last = (specs[k].firstNibble + specs[k].nibbles - 1) div 2 - (firstByte - 1)
        L.rows.add HeaderRow(blockName: name, kind: kind, field: n, value: fieldValueOf(v).get,
          offset: pos + first, size: last - first + 1, blockOffset: pos, blockSize: size)
      inc k

proc addRaw(L: var Lister, name, what: string, at: int64, size: int) =
  # One row for a block without named fields; nothing when it lies outside
  # the map.
  if size > 0 and at >= 0 and at + size <= L.size:
    L.rows.add HeaderRow(blockName: name, kind: hbRaw, value: toFieldValue(what), offset: at,
      size: size, blockOffset: at, blockSize: size)

proc addBlock(L: var Lister, name: string, kind: HeaderBlock, at: int64, size: int,
    order = boBig) =
  # A typed block; nothing when it lies outside the map.
  if at < 0 or at + size > L.size: return
  withBlockType(kind):
    L.addFields[:BlockT](name, kind, at, size, firstByte, order)

func rev3Kind(t: uint8): HeaderBlock =
  ## The typed kind of a Rev 3 32-byte block (by byte 32); `hbRaw` if none.
  case t
  of 0x15'u8..0x19'u8, 0x1F'u8: hbSegdSourceDescription
  of 0x1A'u8, 0x20'u8: hbSegdAdditionalSourceInfo
  of 0x41'u8: hbSegdSensorInfo
  of 0x42'u8: hbSegdTimestamp
  of 0x43'u8: hbSegdSensorCalibration
  of 0x44'u8: hbSegdTimeDrift
  of 0x50'u8: hbSegdPosition
  of 0x60'u8: hbSegdOrientation
  of 0x70'u8: hbSegdTrailerDescription
  else: hbRaw

proc addRev3Blocks(L: var Lister, prefix: string, first: int, at: int64, n: int) =
  # `n` 32-byte Rev 3 blocks at `at`, named `<prefix><first>`, ...; a
  # Position block (0x50, 0x51, 0x52) is one 96-byte block.
  var k = 0
  while k < n:
    let b = at + int64(k) * SegdBlockSize
    if b + SegdBlockSize > L.size: return
    let t = L.mem[b + SegdBlockSize - 1]
    let kind = rev3Kind(t)
    let name = prefix & $(first + k)
    if kind == hbSegdPosition and k + 2 < n and b + 96 <= L.size and
        L.mem[b + 63] == 0x51 and L.mem[b + 95] == 0x52:
      L.addBlock(name, kind, b, 96)
      k += 3
    elif kind != hbRaw and kind != hbSegdPosition:
      L.addBlock(name, kind, b, SegdBlockSize)
      inc k
    else:
      L.addRaw(name, blockTypeName(t), b, SegdBlockSize)
      inc k

proc initLister(f: SeismicFile): Lister =
  if not f.isOpen: raise newException(ValueError, "the file is closed")
  Lister(mem: f.unsafeMemory, size: f.mappedSize)

proc located(L: var Lister, f: SeismicFile, scope: HeaderScope, index: int,
    name: string): bool =
  # A block `HeaderEditor` names, listed as located there.
  let r = f.index.locateBlock(scope, index, name)
  result = r.error.len == 0
  if result: L.addBlock(name, r.blk.kind, r.blk.offset, r.blk.size, r.blk.order)

proc addSeg2Block(L: var Lister, f: SeismicFile, name: string, kind: HeaderBlock,
    at: int64, size: int) =
  # A SEG-2 descriptor block: its fixed fields, then a row per string.
  if at < 0 or size < Seg2FixedSize or at + size > L.size: return
  L.addBlock(name, kind, at, size, f.index.seg2.order)
  let first = if kind == hbSeg2File: Seg2FixedSize + int(f.index.seg2.pointerBytes)
              else: int(at) + Seg2FixedSize
  var spans: seq[Slice[int]]
  let strs = blockStrings(L.mem.toOpenArray(0, int(L.size) - 1), first, int(at) + size,
    f.index.seg2, spans)
  for i, x in strs:
    L.rows.add HeaderRow(blockName: name, kind: kind, field: x.key, value: toFieldValue(x.value),
      offset: spans[i].a, size: spans[i].len, blockOffset: at, blockSize: size)

func traceEnd(f: SeismicFile, i: int): int64 =
  # The offset after trace `i`'s samples.
  let e = f.index.entries[i]
  e.sampleOffset + int64(f.index.dataBytes(i))

proc traceHeaders*(f: SeismicFile, trace: int): HeaderListing {.segApi.} =
  ## Every header block of trace `trace`, as rows in file order: `trace`,
  ## `ext1` and any further extensions (see the module documentation).
  ## Raises `ValueError` for a trace out of range or a closed file.
  if trace notin 0 ..< f.len:
    raise newException(ValueError, "no trace " & $trace & " (the file has " & $f.len & ")")
  var L = initLister(f)
  let e = f.index.entries[trace]
  if f.kind == skSeg2:
    L.addSeg2Block(f, "trace", hbSeg2Trace, e.offset, int(e.headerBytes))
    return HeaderListing(rows: move L.rows)
  discard L.located(f, hsTrace, trace, "trace")
  let hasExt1 = L.located(f, hsTrace, trace, "ext1")
  if f.kind == skSegy:
    let first = e.offset + 2 * TraceHeaderSize
    let n = (int(e.headerBytes) - 2 * TraceHeaderSize) div TraceHeaderSize
    if hasExt1:
      for k in 0 ..< n:
        L.addRaw("ext" & $(k + 2), "proprietary", first + int64(k) * TraceHeaderSize,
          TraceHeaderSize)
  else:
    let first = e.offset + SegdTraceHeaderSize + SegdBlockSize
    let n = (int(e.headerBytes) - SegdTraceHeaderSize - SegdBlockSize) div SegdBlockSize
    if hasExt1 and n > 0:
      if f.index.segdRecords[e.record].isRev3:
        L.addRev3Blocks("ext", 2, first, n)
      else:
        for k in 0 ..< n:
          L.addRaw("ext" & $(k + 2), "traceHeaderExtension", first + int64(k) * SegdBlockSize,
            SegdBlockSize)
  HeaderListing(rows: move L.rows)

proc recordHeaders*(f: SeismicFile, record: int): HeaderListing {.segApi.} =
  ## Every header block of SEG-D record `record`, as rows in file order:
  ## general headers, channel set descriptors, skew, extended and external
  ## headers, and the trailer (see the module documentation). Empty for
  ## record 0 of a SEG-Y file, which has no record headers. Raises
  ## `ValueError` for a record out of range or a closed file.
  if record notin 0 ..< f.recordCount:
    raise newException(ValueError, "no record " & $record & " (the file has " &
      $f.recordCount & ")")
  var L = initLister(f)
  if f.kind != skSegd: return
  template rec: untyped = f.index.segdRecords[record]
  var at = rec.offset
  discard L.located(f, hsRecord, record, "gh1")
  at += SegdBlockSize
  case rec.layout
  of slRev2:
    if rec.gh2.isSome:
      L.addBlock("gh2", hbSegdGh2, at, SegdBlockSize)
      at += SegdBlockSize
    for k in 0 ..< rec.sourceHeaders.len:
      discard L.located(f, hsRecord, record, "gh" & $(k + 3))
      at += SegdBlockSize
  of slRev3:
    L.addBlock("gh2", hbSegdGh2Rev3, at, SegdBlockSize)
    L.addBlock("gh3", hbSegdGh3Rev3, at + SegdBlockSize, SegdBlockSize)
    at += 2 * SegdBlockSize
    let n = rec.generalBlocks.len div SegdBlockSize
    L.addRev3Blocks("gh", 4, at, n)
    at += int64(rec.generalBlocks.len)
  for st, s in rec.scanTypes:
    let csd = if s.layout == slRev3: 3 * SegdBlockSize else: SegdBlockSize
    let kind = if s.layout == slRev3: hbSegdChannelSetRev3 else: hbSegdChannelSet
    for cs in 0 ..< s.channelSetCount:
      L.addBlock("st" & $(st + 1) & "cs" & $(cs + 1), kind, at, csd)
      at += csd
    if s.skew.len > 0:
      L.addRaw("st" & $(st + 1) & "skew", "skew", at, s.skew.len)
      at += int64(s.skew.len)
  if rec.extended.len > 0:
    L.addRaw("extended", "extended header", at, rec.extended.len)
    at += int64(rec.extended.len)
  if rec.external.len > 0:
    L.addRaw("external", "external header", at, rec.external.len)
  let trailer = case rec.layout
    of slRev2: rec.trailer.len * SegdBlockSize
    of slRev3: rec.trailerRev3.len
  if trailer > 0:
    var last = -1
    for i, e in f.index.entries:
      if int(e.record) == record: last = i
    if last >= 0: L.addRaw("trailer", "general trailer", f.traceEnd(last), trailer)
  HeaderListing(rows: move L.rows)

proc fileHeaders*(f: SeismicFile): HeaderListing {.segApi.} =
  ## The file-level header blocks, as rows in file order: SEG-Y tape label,
  ## textual, binary, extended textual headers and data trailer; SEG-D the
  ## storage unit label; SEG-2 the File Descriptor Block (fixed fields and
  ## strings). Raises `ValueError` for a closed file.
  var L = initLister(f)
  case f.kind
  of skSegy:
    template s: untyped = f.index.segy
    var at = int64(s.tapeLabel.len)
    if at > 0: L.addRaw("label", "tape label", 0, s.tapeLabel.len)
    L.addRaw("text", "textual header", at, TextHeaderSize)
    discard L.located(f, hsFile, 0, "binary")
    at += TextHeaderSize + BinaryHeaderSize
    let ext = s.extended.recordCount * TextHeaderSize
    if ext > 0: L.addRaw("extended", "extended textual header", at, ext)
    let trailer = s.trailer.recordCount * TextHeaderSize
    if trailer > 0 and f.len > 0:
      L.addRaw("trailer", "data trailer", f.traceEnd(f.len - 1), trailer)
  of skSegd:
    if f.index.segdLabel.isSome: L.addRaw("label", "storage unit label", 0, 128)
  of skSeg2:
    L.addSeg2Block(f, "file", hbSeg2File, 0,
      fileBlockSize(L.mem.toOpenArray(0, int(L.size) - 1), f.index.seg2))
  of skUnknown: discard
  HeaderListing(rows: move L.rows)
