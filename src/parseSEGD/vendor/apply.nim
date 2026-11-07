## Applies vendor maps and decoders to SEG-D and SEG-Y data read by the
## format readers: builds the matching context and hands each vendor area to
## `maps.decode`. Raw bytes stay in the records; the decoded blocks are
## returned beside them.

import ../common/[endians, diagnostics]
import ../segd/reader as segdreader
import ../segy/reader as segyreader
import ./maps
export maps

func segdContext*(rec: SegdRecord): VendorContext =
  ## Matching facts of a SEG-D record: revision, manufacturer code and serial.
  VendorContext(format: "segd",
    revision: VendorRevision(major: int(rec.revision.major), minor: int(rec.revision.minor)),
    manufacturer: rec.gh1.manufacturerCode, serial: rec.gh1.manufacturerSerial,
    byteOrder: boBig)

proc decodeArea(reg: VendorRegistry, ctx: VendorContext, kind: VendorTargetKind,
    bytes: openArray[byte], blockSize: int, log: var DiagLog, loc: Location,
    result: var seq[VendorBlock]) =
  # The whole area, then each block of `blockSize` bytes.
  var blk: VendorBlock
  if bytes.len > 0 and reg.decode(ctx, VendorArea(kind: kind, blockIndex: -1, blockType: -1,
      extIndex: -1), bytes, blk, log, loc):
    result.add blk
  if blockSize > 0:
    for i in 0 ..< bytes.len div blockSize:
      var b: VendorBlock
      if reg.decode(ctx, VendorArea(kind: kind, blockIndex: i + 1, blockType: -1, extIndex: -1),
          bytes.toOpenArray(i * blockSize, (i + 1) * blockSize - 1), b, log, loc):
        result.add b

proc decodeVendorAreas*(reg: VendorRegistry, rec: SegdRecord, log: var DiagLog,
    file = ""): seq[VendorBlock] =
  ## Decodes a SEG-D record's extended and external headers (whole area and
  ## each 32-byte block), general headers #3+ (`generalHeader`, by number)
  ## and general trailer blocks, wherever a map or decoder applies.
  let ctx = segdContext(rec)
  let loc = Location(file: file, record: rec.index)
  decodeArea(reg, ctx, vtExtendedHeader, rec.extended, 32, log, loc, result)
  decodeArea(reg, ctx, vtExternalHeader, rec.external, 32, log, loc, result)
  for i, g in rec.sourceHeaders:
    var b: VendorBlock
    if reg.decode(ctx, VendorArea(kind: vtGeneralHeader, blockIndex: i + 3, blockType: -1,
        extIndex: -1), g.raw, b, log, loc):
      result.add b
  var trailer: seq[byte]
  for t in rec.trailer: trailer.add t.raw
  decodeArea(reg, ctx, vtTrailer, trailer, 32, log, loc, result)

proc decodeVendorAreas*(reg: VendorRegistry, rec: SegdRecord, t: SegdTrace,
    log: var DiagLog, file = ""): seq[VendorBlock] =
  ## Decodes a SEG-D trace's header extensions #2 and later (`traceExt`,
  ## `(extension k)`).
  let ctx = segdContext(rec)
  let loc = Location(file: file, record: rec.index, trace: t.index)
  for i in 0 ..< t.extensions.len div 32:
    var b: VendorBlock
    if reg.decode(ctx, VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1,
        extIndex: i + 2), t.extensions.toOpenArray(32 * i, 32 * i + 31), b, log, loc):
      result.add b

func segyContext*(f: SegyFile): VendorContext =
  ## Matching facts of a SEG-Y file: revision, textual header, byte order.
  VendorContext(format: "segy",
    revision: VendorRevision(major: int(f.revision.major), minor: int(f.revision.minor)),
    manufacturer: -1, serial: -1, text: f.text.text, byteOrder: f.byteOrder)

proc decodeVendorAreas*(reg: VendorRegistry, f: SegyFile, log: var DiagLog): seq[VendorBlock] =
  ## Decodes the SEG-Y binary header (`binaryHeaderBytes`, the whole 400
  ## bytes; fields are addressed 1-400) and stanzas (`stanza`, by
  ## `COMPANY:NAME`) of the extended header and trailer.
  let ctx = segyContext(f)
  var bin = newSeq[byte](BinaryHeaderSize)
  f.binary.encode(bin, f.byteOrder)
  var b: VendorBlock
  if reg.decode(ctx, VendorArea(kind: vtBinaryHeaderBytes, blockIndex: -1, blockType: -1,
      extIndex: -1), bin, b, log, Location(file: "", field: "binary")):
    result.add b
  for h in [f.extended, f.trailer]:
    for s in h.stanzas:
      var sb: VendorBlock
      if reg.decode(ctx, VendorArea(kind: vtStanza, blockIndex: -1, blockType: -1, extIndex: -1,
          stanza: s.company & ":" & s.name), h.stanzaBytes(s), sb, log, Location(field: s.key)):
        result.add sb

proc decodeVendorAreas*(reg: VendorRegistry, f: SegyFile, t: SegyTrace,
    log: var DiagLog): seq[VendorBlock] =
  ## Decodes a SEG-Y trace's standard header bytes (`traceHeaderBytes`,
  ## addressed 1-240) and proprietary trace headers (`traceHeaderBlock`, by
  ## name).
  let ctx = segyContext(f)
  let loc = Location(trace: t.index)
  var hb = newSeq[byte](TraceHeaderSize)
  t.header.encode(hb, f.byteOrder)
  var b: VendorBlock
  if reg.decode(ctx, VendorArea(kind: vtTraceHeaderBytes, blockIndex: -1, blockType: -1,
      extIndex: -1), hb, b, log, loc):
    result.add b
  for i in 0 ..< t.proprietary.len div TraceHeaderSize:
    template blk: untyped =
      t.proprietary.toOpenArray(i * TraceHeaderSize, (i + 1) * TraceHeaderSize - 1)
    var pb: VendorBlock
    if reg.decode(ctx, VendorArea(kind: vtTraceHeaderBlock, blockIndex: -1, blockType: -1,
        extIndex: -1, headerName: headerBlockName(blk)), blk, pb, log, loc):
      result.add pb
