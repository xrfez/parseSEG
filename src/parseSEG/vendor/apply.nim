## Applies vendor maps and decoders to SEG-D and SEG-Y data read by the
## format readers: builds the matching context and hands each vendor area to
## `maps.decode`. Raw bytes stay in the records; the decoded blocks are
## returned beside them.

import ../common/[endians, diagnostics]
import ../segd/reader as segdreader
import ../segy/reader as segyreader
import ./maps
export maps

func vendorContext*(rec: SegdRecord): VendorContext =
  ## Matching facts of a SEG-D record: revision, manufacturer code and serial.
  VendorContext(format: skSegd,
    revision: VendorRevision(major: int(rec.revision.major), minor: int(rec.revision.minor)),
    manufacturer: rec.gh1.manufacturerCode, serial: rec.gh1.manufacturerSerial,
    byteOrder: boBig)

func vendorContext*(f: SegyFile): VendorContext =
  ## Matching facts of a SEG-Y file: revision, textual header, byte order.
  VendorContext(format: skSegy,
    revision: VendorRevision(major: int(f.revision.major), minor: int(f.revision.minor)),
    manufacturer: -1, serial: -1, text: f.text.text, byteOrder: f.byteOrder)

proc addDecoded(blocks: var seq[VendorBlock], reg: VendorRegistry, ctx: VendorContext,
    area: VendorArea, bytes: openArray[byte], log: var DiagLog, loc: Location) =
  # Decodes one area and keeps the block, if anything applies.
  let b = reg.decode(ctx, area, bytes, log, loc)
  if b.isSome: blocks.add b.get

proc decodeArea(blocks: var seq[VendorBlock], reg: VendorRegistry, ctx: VendorContext,
    kind: VendorTargetKind, bytes: openArray[byte], log: var DiagLog, loc: Location) =
  # The whole area, then each 32-byte block.
  if bytes.len > 0:
    blocks.addDecoded(reg, ctx, VendorArea(kind: kind, blockIndex: -1, blockType: -1,
      extIndex: -1), bytes, log, loc)
  for i in 0 ..< bytes.len div SegdBlockSize:
    blocks.addDecoded(reg, ctx, VendorArea(kind: kind, blockIndex: i + 1, blockType: -1,
      extIndex: -1), bytes.toOpenArray(i * SegdBlockSize, (i + 1) * SegdBlockSize - 1), log, loc)

proc decodeTypedBlocks(blocks: var seq[VendorBlock], reg: VendorRegistry, ctx: VendorContext,
    area: openArray[byte], where: string, log: var DiagLog, loc: Location) =
  # Rev 3 typed blocks by type byte. A Position block (0x50 0x51 0x52) is
  # offered as its 96 bytes, under type 0x50.
  var i = 0
  while i + SegdBlockSize <= area.len:
    let t = area[i + 31]
    let span = if t == BlockTypePosition1 and i + 96 <= area.len and
                  area[i + 63] == BlockTypePosition2 and area[i + 95] == BlockTypePosition3:
                 3 * SegdBlockSize
               else: SegdBlockSize
    blocks.addDecoded(reg, ctx, VendorArea(kind: vtBlock, blockIndex: -1, blockType: int(t),
      where: where, extIndex: -1), area.toOpenArray(i, i + span - 1), log, loc)
    i += span

proc decodeRev3Trailer(blocks: var seq[VendorBlock], reg: VendorRegistry, ctx: VendorContext,
    tb: openArray[byte], log: var DiagLog, loc: Location) =
  # Each description block's data, by trailer block type.
  var i = 0
  while i + SegdBlockSize <= tb.len and tb[i + 31] == BlockTypeTrailerDescription:
    let n = SegdBlockSize * int(beU32(tb, i + 4))
    if i + SegdBlockSize + n > tb.len: return
    blocks.addDecoded(reg, ctx, VendorArea(kind: vtTrailer, blockIndex: -1,
      blockType: int(tb[i]), where: blockText(tb.toOpenArray(i, i + 31), 9, 24), extIndex: -1),
      tb.toOpenArray(i + SegdBlockSize, i + SegdBlockSize + n - 1), log, loc)
    i += SegdBlockSize + n

proc decodeVendorAreas*(reg: VendorRegistry, rec: SegdRecord, log: var DiagLog,
    file = ""): seq[VendorBlock] =
  ## Decodes a SEG-D record's extended and external headers (whole area and
  ## each 32-byte block), its other general header blocks (Rev 1/2: GH#3 and
  ## later as `generalHeader`, by number; Rev 3: `block`, by type, where
  ## `generalHeader`) and its general trailer, wherever a map or decoder
  ## applies. `file` names the file in the diagnostics.
  let ctx = vendorContext(rec)
  let loc = Location(file: file, record: rec.index)
  case rec.layout
  of slRev2:
    result.decodeArea(reg, ctx, vtExtendedHeader, rec.extended, log, loc)
    result.decodeArea(reg, ctx, vtExternalHeader, rec.external, log, loc)
    for i, g in rec.sourceHeaders:
      result.addDecoded(reg, ctx, VendorArea(kind: vtGeneralHeader, blockIndex: i + 3,
        blockType: -1, extIndex: -1), g.raw, log, loc)
    var trailer: seq[byte]
    for t in rec.trailer: trailer.add t.raw
    result.decodeArea(reg, ctx, vtTrailer, trailer, log, loc)
  of slRev3:
    result.decodeTypedBlocks(reg, ctx, rec.generalBlocks, "generalHeader", log, loc)
    result.decodeRev3Trailer(reg, ctx, rec.trailerRev3, log, loc)
    result.decodeArea(reg, ctx, vtExtendedHeader, rec.extended, log, loc)
    result.decodeArea(reg, ctx, vtExternalHeader, rec.external, log, loc)

proc decodeVendorAreas*(reg: VendorRegistry, rec: SegdRecord, t: SegdTrace,
    log: var DiagLog, file = ""): seq[VendorBlock] =
  ## Decodes a SEG-D trace's header extensions #2 and later: Rev 1/2 by
  ## position (`traceExt`, `(extension k)`), Rev 3 by block type (`block`,
  ## `(type 0xB0) (where traceHeader)`). `file` names the file in the
  ## diagnostics.
  let ctx = vendorContext(rec)
  let loc = Location(file: file, record: rec.index, trace: t.index)
  case t.layout
  of slRev2:
    for i in 0 ..< t.extensions.len div SegdBlockSize:
      result.addDecoded(reg, ctx, VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1,
        extIndex: i + 2), t.extensions.toOpenArray(SegdBlockSize * i, SegdBlockSize * i + 31),
        log, loc)
  of slRev3:
    result.decodeTypedBlocks(reg, ctx, t.extensions, "traceHeader", log, loc)

proc decodeVendorAreas*(reg: VendorRegistry, f: SegyFile, log: var DiagLog,
    file = ""): seq[VendorBlock] =
  ## Decodes the SEG-Y binary header (`binaryHeaderBytes`, the whole 400
  ## bytes; fields are addressed 1-400) and stanzas (`stanza`, by
  ## `COMPANY:NAME`) of the extended header and trailer. `file` names the
  ## file in the diagnostics.
  let ctx = vendorContext(f)
  var bin = newSeq[byte](BinaryHeaderSize)
  f.binary.encode(bin, f.byteOrder)
  result.addDecoded(reg, ctx, VendorArea(kind: vtBinaryHeaderBytes, blockIndex: -1,
    blockType: -1, extIndex: -1), bin, log, Location(file: file, field: "binary"))
  for h in [f.extended, f.trailer]:
    for s in h.stanzas:
      result.addDecoded(reg, ctx, VendorArea(kind: vtStanza, blockIndex: -1, blockType: -1,
        extIndex: -1, stanza: s.company & ":" & s.name), h.stanzaBytes(s), log,
        Location(file: file, field: s.key))

proc decodeVendorAreas*(reg: VendorRegistry, f: SegyFile, t: SegyTrace,
    log: var DiagLog, file = ""): seq[VendorBlock] =
  ## Decodes a SEG-Y trace's standard header bytes (`traceHeaderBytes`,
  ## addressed 1-240) and proprietary trace headers (`traceHeaderBlock`, by
  ## name). `file` names the file in the diagnostics.
  let ctx = vendorContext(f)
  let loc = Location(file: file, trace: t.index)
  var hb = newSeq[byte](TraceHeaderSize)
  t.header.encode(hb, f.byteOrder)
  result.addDecoded(reg, ctx, VendorArea(kind: vtTraceHeaderBytes, blockIndex: -1,
    blockType: -1, extIndex: -1), hb, log, loc)
  for i in 0 ..< t.proprietary.len div TraceHeaderSize:
    template blk: untyped =
      t.proprietary.toOpenArray(i * TraceHeaderSize, (i + 1) * TraceHeaderSize - 1)
    result.addDecoded(reg, ctx, VendorArea(kind: vtTraceHeaderBlock, blockIndex: -1,
      blockType: -1, extIndex: -1, headerName: headerBlockName(blk)), blk, log, loc)
