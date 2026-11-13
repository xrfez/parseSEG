## Format detection and the index walk: `detectKind` tells SEG-Y, SEG-D
## and SEG-2 apart from a file's first bytes, and `buildIndex` walks any
## `RecordSource` (disk, tape image, tape device) with the readers'
## `headersOnly` mode to index every trace: sample bytes are skipped, by
## seeking where the source can. Each trace costs one 24-byte `TraceEntry`
## (room for the entries is reserved from the file size after the first
## trace), and 184 bytes of `TraceKeys` with `keys`. Header objects are kept
## per file (SEG-Y, SEG-2) or per record (SEG-D), never per trace.
## `openSeismic` (`traceindex`) runs it on the file it maps.

import ../common/[errors, diagnostics, bcd, seismickind, progress]
import ../io/[records, memsource]
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader, mux]
import ../seg2/[reader as seg2reader]
import ./[keys, indextypes]
import ../private/[progressticker, segykeys, segywalk, segyfixed]

# ------------------------------------------------------------- detection --

func looksLikeSegdGh1(b: openArray[byte]): bool =
  # General Header #1: BCD file number (or FFFF) in bytes 1-2, a BCD format
  # code 0xxx/8xxx/9xxx in bytes 3-4.
  if b.len < 32: return false
  let fileOk = isAllF(b, 0, 4) or (block:
    var ok = true
    for n in 0..3:
      if nibble(b, n) > 9: ok = false
    ok)
  var code = 0
  for n in 4..7:
    let d = int(nibble(b, n))
    if d > 9: return false
    code = code * 10 + d
  fileOk and (toSegdFormat(code).isSome or code.isMultiplexedCode or code in [1015, 1022])

func printable(b: byte, ebcdic: bool): bool {.inline.} =
  if ebcdic:
    b == 0x40 or b in 0x4A'u8..0x50'u8 or b in 0x5A'u8..0x61'u8 or b in 0x6A'u8..0x6F'u8 or
      b in 0x79'u8..0x7F'u8 or b in 0x81'u8..0x89'u8 or b in 0x91'u8..0x99'u8 or
      b in 0xA1'u8..0xA9'u8 or b in 0xC0'u8..0xC9'u8 or b in 0xD0'u8..0xD9'u8 or
      b in 0xE0'u8..0xE9'u8 or b in 0xF0'u8..0xF9'u8
  else:
    b in 0x20'u8..0x7E'u8

func looksLikeSegy(head: openArray[byte], at: int): bool =
  # A 3200-byte textual header at `at` that starts with `C` and is mostly
  # printable text in its character set (EBCDIC for 0xC3, ASCII for 0x43).
  # The binary header is left to the reader, so a file with an undefined
  # format code is still read as SEG-Y and gets the reader's diagnostics.
  if head.len < at + 3600 or head[at] notin {0xC3'u8, 0x43'u8}: return false
  let ebcdic = head[at] == 0xC3
  var n = 0
  for i in at ..< at + 3200:
    if printable(head[i], ebcdic): inc n
  n >= 3200 * 6 div 10

func segyBinaryAt(head: openArray[byte], at: int): bool =
  # A plausible binary header behind a 3200-byte textual header at `at`,
  # whatever that header holds (blanks, zeros, free text). The last resort
  # of `detectKind`: it takes 0.04 % of random heads (76 of 200000, the odds
  # of a defined format code), and none of the SEG-D and SEG-2 files tried.
  head.len >= at + TextHeaderSize + BinaryHeaderSize and looksLikeBinaryHeader(
    head.toOpenArray(at + TextHeaderSize, at + TextHeaderSize + BinaryHeaderSize - 1))

func hasSegyTapeLabel(head: openArray[byte]): bool =
  # As the SEG-Y reader takes a tape label: a storage unit sequence number
  # (digits or blanks) and "SY" in bytes 5-6.
  head.len >= 6 and head[0] in {0x20'u8, 0x30'u8..0x39'u8} and head[4] == 0x53 and
    head[5] == 0x59

func detectKind*(head: openArray[byte]): SeismicKind =
  ## Guesses the standard from the first bytes of a stream (pass at least
  ## 3728). SEG-2: the File Descriptor Block ID (`55 3A` or `3A 55`) and the
  ## first trace's block ID or a plausible fixed part (`isSeg2`); neither
  ## SEG-Y text nor a SEG-D BCD file number can start that way. SEG-D: a
  ## storage unit label or a Table of Contents file. SEG-Y: a
  ## textual header starting with `C` that is mostly printable EBCDIC or
  ## ASCII, possibly after a 128-byte tape label. Otherwise SEG-D if the bytes
  ## are a plausible General Header #1 (a SEG-D file number 43xx starts with
  ## ASCII `C`, but its next 3200 bytes are not text). Last, SEG-Y whose
  ## textual header is not card text (blank, zero-filled, free text, a
  ## lower-case `c`): when the 400 bytes behind it, at 3200 or behind a tape
  ## label at 3328, are a plausible binary header (`looksLikeBinaryHeader`).
  ## `skUnknown` if nothing fits; `OpenOptions.kind` opens such a file as
  ## the standard the caller knows it to be.
  if isSeg2(head): skSeg2
  elif isStorageUnitLabel(head) or isTocFile(head): skSegd
  elif looksLikeSegy(head, 0) or (head.len >= 6 and head[4] == 0x53 and head[5] == 0x59 and
      looksLikeSegy(head, 128)):
    skSegy
  elif looksLikeSegdGh1(head): skSegd
  elif segyBinaryAt(head, 0) or (hasSegyTapeLabel(head) and segyBinaryAt(head, TapeLabelSize)):
    skSegy
  else: skUnknown

# ------------------------------------------------------------------ walk --

proc reserveFor(ix: var TraceIndex, src: RecordSource, first: TraceEntry, dataBytes: int,
    keys: bool) =
  # After the first trace: room for as many entries (and keys) as the rest of
  # a memory-mapped file holds at this trace's size, so 10 M traces take
  # 24 B each and not the up to 1.5x of a growing seq. Capped at one entry per
  # 64 bytes of file, in case the first trace is unusually short.
  if src of MemFileSource:
    let size = MemFileSource(src).size
    let stride = max(int64(first.headerBytes) + int64(dataBytes), 64)
    let n = int(min((size - first.offset) div stride + 1, size div 64))
    if n > ix.entries.len + 1:
      var e = newSeqOfCap[TraceEntry](n)
      for x in ix.entries: e.add x
      ix.entries = move e
      if keys:
        var k = newSeqOfCap[TraceKeys](n)
        for x in ix.keys: k.add x
        ix.keys = move k

proc indexFixed(ix: var TraceIndex, r: var SegyReader, src: RecordSource): bool =
  # `vfSampled`: the index of a fixed-length file from its size
  # (`private/segyfixed`), with an info diagnostic; false to walk instead.
  let checked = if src of MemFileSource: fixedEntries(r, MemFileSource(src), ix.entries)
                else: 0
  if checked > 0:
    template b: untyped = r.file.binary
    ix.maxSamples = int(b.effectiveSamplesPerTrace)
    ix.segyIntervalUs = b.effectiveSampleInterval
    ix.segy = r.file
    ix.log = r.takeLog()
    ix.log.report(sevInfo, dcIndexSampled, "fixed-length traces: the " & $ix.entries.len &
      " traces were indexed from the file size, and " & $checked & " of their headers " &
      "checked against the binary header's sample count and interval (verify = vfFull " &
      "reads every header)", ix.segy.firstTraceOffset, Location(file: src.name))
  checked > 0

proc indexSegy(src: RecordSource, keys: bool, verify: VerifyMode,
    tk: var ProgressTicker): TraceIndex =
  var r = openSegyWalk(src)
  result = TraceIndex(kind: skSegy, contiguous: not src.hasRecordBoundaries)
  result.codecs.add TraceCodec(kind: skSegy, segyFormat: r.file.format,
    order: r.file.byteOrder)
  if verify == vfSampled and not keys and result.indexFixed(r, src): return
  let gr = if keys: initGeometryReader(r.file) else: GeometryReader()
  result.segyIntervalUs = NaN
  var t: SegyTrace
  while r.readTrace(t):
    if not tk.tick(t.offset): raiseCancelled()
    if result.entries.len == 0: result.segyIntervalUs = t.sampleInterval
    elif t.sampleInterval != result.segyIntervalUs: result.segyIntervalUs = NaN
    let hb = TraceHeaderSize + (if t.hasExt1: TraceHeaderSize + t.proprietary.len else: 0)
    result.entries.add TraceEntry(offset: t.offset, headerBytes: uint32(hb),
      numSamples: uint32(t.numSamples), channelSet: NoChannelSet, scanType: -1)
    result.maxSamples = max(result.maxSamples, t.numSamples)
    if keys: result.keys.add segyKeys(gr, r.walkHeaders(t))
    if result.entries.len == 1:
      result.reserveFor(src, result.entries[0], result.codecs[0].dataBytes(t.numSamples), keys)
  result.segy = r.file
  result.log = r.takeLog()

proc indexSegd(src: RecordSource, twosComplement8015, keys: bool,
    tk: var ProgressTicker): TraceIndex =
  var r = openSegd(src, twosComplement8015, headersOnly = true)
  result = TraceIndex(kind: skSegd, contiguous: not src.hasRecordBoundaries)
  while r.nextRecord():
    let ri = uint32(result.segdRecords.len)
    var t: SegdTrace
    while r.readTrace(t):
      if not tk.tick(t.offset): raiseCancelled()
      let the = int(t.header.traceHeaderExtensions)
      result.entries.add TraceEntry(offset: t.offset,
        headerBytes: uint32(SegdTraceHeaderSize + SegdBlockSize * the),
        numSamples: uint32(t.numSamples), record: ri,
        channelSet: if t.channelSet < 0: NoChannelSet else: uint16(t.channelSet),
        scanType: int8(t.scanType), channelType: uint8(r.record.channelType(t)))
      result.maxSamples = max(result.maxSamples, t.numSamples)
      if keys: result.keys.add traceKeys(r.record, t)
      if result.entries.len == 1:
        let fmt = r.record.format
        result.reserveFor(src, result.entries[0],
          if fmt.isSome: dataBytes(fmt.get, t.numSamples) else: 0, keys)
    result.codecs.add TraceCodec(kind: skSegd, segdFormat: r.record.format,
      twosComplement8015: twosComplement8015)
    # A multiplexed record's traces have no bytes of their own to read.
    if r.record.multiplexed: result.contiguous = false
    result.segdRecords.add r.record
  result.segdLabel = r.label
  result.segdToc = r.toc
  result.log = r.log

func traceTypeCode(t: Seg2Trace): uint8 =
  # `TraceEntry.channelType` of a SEG-2 trace.
  let tt = t.traceType
  if tt.isSome: uint8(ord(tt.get) + 1) else: 0

proc indexSeg2(src: MemFileSource, twosComplement8015, keys: bool,
    tk: var ProgressTicker): TraceIndex =
  # The whole file, from the map: pointers may come in any order.
  result = TraceIndex(kind: skSeg2, contiguous: true)
  let size = src.size
  let empty: seq[byte] = @[]
  template data: untyped =
    (if size > 0: src.memory.toOpenArray(0, int(size) - 1) else: empty.toOpenArray(0, -1))
  var log: DiagLog
  result.seg2 = readSeg2(data, log, src.name)
  template f: untyped = result.seg2
  let count = max(int64(f.traceCount), 1)
  for t in traces(data, f, log, src.name):
    # Pointers come in any order: the share of traces done, in bytes.
    if not tk.tick(min(int64(result.entries.len) * size div count, size)): raiseCancelled()
    let fmt = if t.valid: t.format else: none(Seg2SampleFormat)
    var c = 0
    while c < result.codecs.len and result.codecs[c].seg2Format != fmt: inc c
    if c == result.codecs.len:
      result.codecs.add TraceCodec(kind: skSeg2, seg2Format: fmt, order: f.order,
        twosComplement8015: twosComplement8015)
    let n = t.sampleCount(size) # bounded by the file (13.3 R4-1)
    result.entries.add TraceEntry(offset: t.offset,
      headerBytes: if t.valid: uint32(t.blockSize) else: 0, numSamples: uint32(n),
      record: uint32(c), channelSet: NoChannelSet, scanType: -1,
      channelType: traceTypeCode(t))
    result.maxSamples = max(result.maxSamples, n)
    if keys: result.keys.add traceKeys(f, t)
  result.log = log

proc buildIndex*(src: RecordSource, kind: SeismicKind, twosComplement8015 = false,
    keys = false, progress: Progress = nil, verify = vfFull): TraceIndex =
  ## Walks the stream at the current position of `src` with headers only and
  ## indexes every trace; with `keys`, also collects each trace's geometry
  ## (for `gathers` and `componentGroups`). Problems go to `log`, as with the
  ## readers. SEG-2 is read from the start of a `MemFileSource` (its
  ## pointers are file offsets); `twosComplement8015` then applies to its
  ## format 3. Raises `ValueError` for `skUnknown` and for SEG-2 on another
  ## source.
  ##
  ## The entries of a multiplexed SEG-D record point at its scans (its
  ## traces have no bytes of their own), so such an index is not
  ## `contiguous` and refuses range reads; `openSeismic` indexes a
  ## demultiplexed copy instead.
  ##
  ## `progress` is called about every MiB of the walk with the medium
  ## offset reached and the source's size (-1 unless it is a
  ## `MemFileSource`), and once at the end; when it returns false the walk
  ## stops with `SegCancelledError`.
  ##
  ## `verify = vfSampled` indexes a fixed-length SEG-Y file on a
  ## `MemFileSource` from its size, as `openSeismic` does by default (see
  ## there); the default walks every trace.
  var tk = initProgressTicker(progress, if src of MemFileSource: MemFileSource(src).size else: -1)
  result = case kind
    of skSegy: indexSegy(src, keys, verify, tk)
    of skSegd: indexSegd(src, twosComplement8015, keys, tk)
    of skSeg2:
      if not (src of MemFileSource):
        raise newException(ValueError, "SEG-2 is indexed from a memory-mapped file " &
          "(openSeismic or a MemFileSource), not from a stream")
      indexSeg2(MemFileSource(src), twosComplement8015, keys, tk)
    of skUnknown: raise newException(ValueError, "buildIndex needs SEG-Y, SEG-D or SEG-2")
  result.detected = true
  if not tk.finish(): raiseCancelled()
