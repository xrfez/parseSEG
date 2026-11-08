## Vendor map scaffolding (task 7.1b): finds the vendor areas of a file that
## no loaded map or decoder handles, and writes a skeleton map for them, the
## starting point for describing a new vendor's layout.
##
## Areas looked at:
## - SEG-D: extended and external header blocks (by block index), Rev 3
##   general header and trace header blocks of user (0xB0-0xFF) or undefined
##   types (by type), Rev 1/2 trace header extensions #2 and later (by
##   position).
## - SEG-Y: the binary header's unassigned bytes and the trace header's
##   (181-240) when they are not all zero, and proprietary trace header
##   blocks (by name).
##
## Each area's bytes are compared over every occurrence (every record or
## trace), and its skeleton target lists runs of bytes that never change
## (with their value), runs that vary, and text-looking runs, as `raw` and
## `ascii` fields. The result loads as a map (`loadVendorMap`), so it can be
## checked and applied at once, then refined by hand.

import std/[strutils, os, tables, hashes]
import ../common/diagnostics
import ../io/[records, diskio]
import ../segd/reader as segdreader
import ../segy/[reader as segyreader, binheader, traceheader]
import ../model/traceindex
import ./[maps, apply]

type
  AreaKey = object
    kind: VendorTargetKind
    blockIndex, blockType, extIndex: int
    where, headerName: string

  AreaStats = object
    key: AreaKey
    count: int
    first: seq[byte]
    varies, printable: seq[bool]
    ranges: seq[(int, int)] ## 0-based inclusive byte ranges of interest within the area

  VendorScaffold* = object
    ## Unmapped vendor areas of a file, ready to write as a skeleton map.
    format*: SeismicKind ## `skSegd` or `skSegy`.
    revision*: VendorRevision
    manufacturer*: int  ## SEG-D manufacturer code, -1 for SEG-Y.
    source*: string     ## The file scanned.
    areas: seq[AreaStats]
    byKey: Table[AreaKey, int]

  RunKind = enum
    ## How a skeleton field's bytes behave over every occurrence.
    rkText = "ascii"     ## At least 4 printable bytes.
    rkConstant = "constant"
    rkVaries = "varies"

func hash(k: AreaKey): Hash =
  hash((k.kind, k.blockIndex, k.blockType, k.extIndex, k.where, k.headerName))

func isText(c: byte): bool {.inline.} = c in 0x20'u8..0x7E'u8

proc see(s: var VendorScaffold, key: AreaKey, bytes: openArray[byte],
    ranges: seq[(int, int)] = @[]) =
  let at = s.byKey.getOrDefault(key, -1)
  if at >= 0:
    template a: untyped = s.areas[at]
    inc a.count
    for (lo, hi) in a.ranges:
      for i in lo..min(hi, min(bytes.len, a.first.len) - 1):
        if bytes[i] != a.first[i]: a.varies[i] = true
        if not isText(bytes[i]): a.printable[i] = false
  else:
    var a = AreaStats(key: key, count: 1, first: @bytes, varies: newSeq[bool](bytes.len),
      printable: newSeq[bool](bytes.len),
      ranges: if ranges.len > 0: ranges else: @[(0, bytes.len - 1)])
    for i in 0..<bytes.len: a.printable[i] = isText(bytes[i])
    s.byKey[key] = s.areas.len
    s.areas.add a

func area(k: AreaKey): VendorArea =
  VendorArea(kind: k.kind, blockIndex: k.blockIndex, blockType: k.blockType, where: k.where,
    headerName: k.headerName, extIndex: k.extIndex)

proc dropMapped(s: var VendorScaffold, reg: VendorRegistry, ctx: VendorContext) =
  var kept: seq[AreaStats]
  for a in s.areas:
    var log: DiagLog
    if reg.decode(ctx, a.key.area, a.first, log).isNone: kept.add a
  s.areas = kept
  s.byKey.clear()

func isVendorType(t: uint8): bool = isUserBlock(t) or not isDefinedBlock(t)

proc scanSegd(s: var VendorScaffold, path: string, reg: VendorRegistry) =
  var src: RecordSource = openDiskSource(path)
  defer: src.close()
  var r = openSegd(src, headersOnly = true)
  var ctx: VendorContext
  var first = true
  while r.nextRecord():
    template rec: untyped = r.record
    if first:
      ctx = vendorContext(rec)
      s.revision = ctx.revision
      s.manufacturer = rec.gh1.manufacturerCode
      first = false
    template seeBlocks(k: VendorTargetKind, bytes: seq[byte]) =
      for i in 0 ..< bytes.len div SegdBlockSize:
        s.see(AreaKey(kind: k, blockIndex: i + 1, blockType: -1, extIndex: -1),
          bytes.toOpenArray(SegdBlockSize * i, SegdBlockSize * i + 31))
    seeBlocks(vtExtendedHeader, rec.extended)
    seeBlocks(vtExternalHeader, rec.external)
    if rec.isRev3:
      for off, t in blocks(rec.generalBlocks):
        if t.isVendorType:
          s.see(AreaKey(kind: vtBlock, blockIndex: -1, blockType: int(t), extIndex: -1,
            where: "generalHeader"), rec.generalBlocks.toOpenArray(off, off + 31), @[(0, 30)])
    var t: SegdTrace
    while r.readTrace(t):
      case t.layout
      of slRev3:
        for off, bt in blocks(t.extensions):
          if bt.isVendorType:
            s.see(AreaKey(kind: vtBlock, blockIndex: -1, blockType: int(bt), extIndex: -1,
              where: "traceHeader"), t.extensions.toOpenArray(off, off + 31), @[(0, 30)])
      of slRev2:
        for i in 0 ..< t.extensions.len div SegdBlockSize:
          s.see(AreaKey(kind: vtTraceExt, blockIndex: -1, blockType: -1, extIndex: i + 2),
            t.extensions.toOpenArray(SegdBlockSize * i, SegdBlockSize * i + 31))
  if not first: s.dropMapped(reg, ctx)

proc scanSegy(s: var VendorScaffold, path: string, reg: VendorRegistry) =
  var src: RecordSource = openDiskSource(path)
  defer: src.close()
  var r = openSegy(src)
  let f = r.file
  let ctx = vendorContext(f)
  s.revision = ctx.revision
  s.manufacturer = -1
  var bin = newSeq[byte](BinaryHeaderSize)
  f.binary.encode(bin, f.byteOrder)
  # Unassigned binary header bytes: 3261-3500 and 3507-3600 (Rev 0/1);
  # 3301-3500 and 3533-3600 (Rev 2).
  let binRanges = if f.revision.major >= 2: @[(100, 299), (332, 399)]
                  else: @[(60, 299), (306, 399)]
  var any = false
  for (lo, hi) in binRanges:
    for i in lo..hi: any = any or bin[i] != 0
  if any:
    s.see(AreaKey(kind: vtBinaryHeaderBytes, blockIndex: -1, blockType: -1, extIndex: -1),
      bin, binRanges)
  # Unassigned trace header bytes: 181-240 (Rev 0/1), 181-232 (Rev 2: 233-240
  # hold the header name).
  let traceHi = if f.revision.major >= 2: 231 else: 239
  var traceAny = false
  var t: SegyTrace
  var hb = newSeq[byte](TraceHeaderSize)
  while r.readTrace(t):
    t.header.encode(hb, f.byteOrder)
    for i in 180..traceHi: traceAny = traceAny or hb[i] != 0
    s.see(AreaKey(kind: vtTraceHeaderBytes, blockIndex: -1, blockType: -1, extIndex: -1),
      hb, @[(180, traceHi)])
    for i in 0 ..< t.proprietary.len div TraceHeaderSize:
      let blk = t.proprietary[i * TraceHeaderSize ..< (i + 1) * TraceHeaderSize]
      s.see(AreaKey(kind: vtTraceHeaderBlock, blockIndex: -1, blockType: -1, extIndex: -1,
        headerName: headerBlockName(blk)), blk, @[(0, 231)])
  if not traceAny:
    var kept: seq[AreaStats]
    for a in s.areas:
      if a.key.kind != vtTraceHeaderBytes: kept.add a
    s.areas = kept
  s.dropMapped(reg, ctx)

proc scaffoldVendorMap*(path: string, reg: VendorRegistry): VendorScaffold =
  ## The unmapped vendor areas of the SEG-D or SEG-Y file `path` (areas that
  ## `reg` already decodes are left out). Raises `IOError` if `path` cannot
  ## be read and `ValueError` if it is neither standard.
  var head = newString(8192)
  let fh = open(path, fmRead)
  try: head.setLen fh.readBuffer(addr head[0], head.len)
  finally: fh.close()
  let kind = detectKind(head.toOpenArrayByte(0, head.len - 1))
  if kind == skUnknown:
    raise newException(ValueError, path & " is neither SEG-Y nor SEG-D")
  result = VendorScaffold(source: path, format: kind)
  if kind == skSegd: result.scanSegd(path, reg) else: result.scanSegy(path, reg)

func len*(s: VendorScaffold): int =
  ## Unmapped areas found.
  s.areas.len

func hexOf(b: openArray[byte]): string =
  for x in b: result.add toHex(x, 2)

func nifString(s: string): string =
  ## A NIF string literal: `"`, `\`, control and non-ASCII bytes as `\HH`.
  result = "\""
  for c in s:
    if c in {'"', '\\'} or ord(c) < 0x20 or ord(c) >= 0x7F: result.add "\\" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

func commentText(s: string): string =
  ## `s` safe inside a `;` comment (no line breaks or control bytes).
  for c in s: result.add(if ord(c) < 0x20 or ord(c) == 0x7F: '?' else: c)

func identPart(s: string): string =
  ## `s` reduced to identifier characters.
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: result.add c

func targetName(k: AreaKey, i: int): string =
  result = case k.kind
    of vtBlock: "block" & toHex(k.blockType, 2) & (if k.where == "traceHeader": "Trace" else: "Gh")
    of vtTraceExt: "traceExt" & $k.extIndex
    of vtExtendedHeader: "extended" & $k.blockIndex
    of vtExternalHeader: "external" & $k.blockIndex
    of vtTraceHeaderBlock: "proprietary" & identPart(k.headerName) & "_" & $i
    else: $k.kind

func targetClauses(k: AreaKey): string =
  result = "(kind " & $k.kind & ")"
  if k.blockIndex >= 0: result.add " (blockIndex " & $k.blockIndex & ")"
  if k.blockType >= 0: result.add " (type 0x" & toHex(k.blockType, 2) & ")"
  if k.where.len > 0: result.add " (where " & k.where & ")"
  if k.extIndex >= 0: result.add " (extension " & $k.extIndex & ")"
  if k.headerName.len > 0: result.add " (headerName " & nifString(k.headerName) & ")"

func textOf(b: openArray[byte]): string =
  ## The bytes as Latin-1 text.
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc toNif*(s: VendorScaffold, name = ""): string =
  ## The skeleton map as NIF text (it loads with `loadVendorMap`); "" when
  ## there is no unmapped area (a map needs at least one target).
  if s.areas.len == 0: return ""
  let mapName = if name.len > 0: name
                elif s.manufacturer >= 0: "manufacturer-" & $s.manufacturer & "-scaffold"
                else: "segy-scaffold"
  let src = s.source.extractFilename
  result = "(.nif27)\n; Skeleton vendor map scaffolded by `parseSEG vendormap scaffold`\n" &
    "; from " & commentText(src) & ". Each field is a run of bytes that is constant\n" &
    "; over every occurrence (value shown), varies, or looks like text. Rename the\n" &
    "; fields and give them real encodings; see docs/design/vendor_maps.md.\n"
  result.add "(vendormap " & nifString(mapName) & " (version 1)\n"
  let rev = $s.revision.major & "." & $s.revision.minor
  result.add "  (match (format " & (if s.format == skSegd: "segd" else: "segy") & ") (rev " &
    rev & " " & rev & ")" &
    (if s.manufacturer >= 0: " (manufacturer " & $s.manufacturer & ")" else: "") & ")\n"
  result.add "  (doc " & nifString("scaffolded from " & src) & ")"
  for n, a in s.areas:
    let tn = a.key.targetName(n)
    var size = 0
    for (lo, hi) in a.ranges: size += hi - lo + 1
    result.add "\n  (target " & a.key.targetClauses & " (name " & tn & ")\n"
    result.add "    ; " & $size & " bytes, seen " & $a.count &
      (if a.count == 1: " time" else: " times")
    for (lo, hi) in a.ranges:
      var i = lo
      while i <= hi:
        # A run: text (>= 4 printable bytes, constant or not), else bytes with
        # the same constness.
        var j = i
        while j <= hi and a.printable[j]: inc j
        var kind = rkText
        if j - i < 4:
          j = i + 1
          while j <= hi and a.varies[j] == a.varies[i] and
              not (j + 3 <= hi and a.printable[j] and a.printable[j + 1] and
                   a.printable[j + 2] and a.printable[j + 3]):
            inc j
          kind = if a.varies[i]: rkVaries else: rkConstant
        let note = case kind
          of rkText: "text: " & commentText(textOf(a.first.toOpenArray(i, j - 1)))
          of rkConstant: "constant " & hexOf(a.first.toOpenArray(i, j - 1))
          of rkVaries: "varies"
        # The note is a comment line of its own: a `;` comment runs to the end
        # of the line, so nothing may follow it there.
        result.add "\n    ; " & note & "\n    (field " & tn & "_" & $(i + 1) & " (at " &
          $(i + 1) & ") (len " & $(j - i) & ") (enc " &
          (if kind == rkText: "ascii" else: "raw") & "))"
        i = j
    result.add ")"
  result.add ")\n"
