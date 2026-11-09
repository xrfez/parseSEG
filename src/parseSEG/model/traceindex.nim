## Trace index: a header-only walk over a SEG-Y, SEG-D or SEG-2 file that records
## where every trace lives, so a viewer or a processing job can read any
## trace range without loading the file.
##
## ```nim
## var f = openSeismic("line.sgd")       # memory-mapped, index built
## echo f.len, " traces"
## let gather = f.readTraces(1000..1999)  # Tensor[float32], [1000, maxSamples]
## f.close()
## ```
##
## `buildIndex` walks any `RecordSource` (disk, tape image, tape device) with
## the readers' `headersOnly` mode: sample bytes are skipped, by seeking where
## the source can. Each trace costs one 24-byte `TraceEntry`, so 10 million
## traces take 240 MB (room for the entries is reserved from the file size
## after the first trace), and 144 bytes of `TraceKeys` with `keys`. Header objects are kept per file (SEG-Y, SEG-2) or per
## record (SEG-D), never per trace.
##
## SEG-2 is a random-access disk format (a pointer per trace), so it is
## indexed from a memory-mapped file only (`openSeismic`, or `buildIndex` on
## a `MemFileSource`): `offset` is the Trace Descriptor Block, `headerBytes`
## its size, and `record` indexes one codec per sample format met.
##
## `openSeismic` maps a disk file with `std/memfiles` and keeps the map, so
## range reads decode straight from the mapped bytes into the tensor's
## buffer (`decodeEntry`), with no intermediate copy. The OS pages the file
## in on demand, and all offsets are 64-bit, so files larger than RAM work.
##
## A SEG-D file with multiplexed records (Rev 0/1 formats 0015 ... 0058) has
## no contiguous bytes per trace, so `openSeismic` demultiplexes it once into
## a temporary demultiplexed copy (`segd/demux`) and maps and indexes that
## instead (`demuxPath`); the copy is deleted on `close`.

import std/[os, times]
import ../common/[endians, errors, diagnostics, bcd, seismickind]
import ../io/[records, memsource]
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader, mux, demux]
import ../seg2/[reader as seg2reader]
import ./[tensors, keys]

export memsource, diagnostics, keys, seismickind
export tensors except rowPtr

type
  TraceEntry* = object
    ## Where one trace lives (24 bytes).
    offset*: int64       ## Medium offset of the trace header.
    headerBytes*: uint32 ## Header bytes before the samples (incl. extensions).
    numSamples*: uint32
    record*: uint32
      ## Indexes `codecs`: the SEG-D record index, 0 for SEG-Y, the codec of
      ## the trace's sample format for SEG-2 (a SEG-2 file is one record).
    channelSet*: uint16
      ## 0-based SEG-D channel set index, `NoChannelSet` if unknown (and for
      ## SEG-Y); see `channelSetIndex`.
    scanType*: int8      ## 0-based SEG-D scan type index (BCD, < 100), -1 if unknown (SEG-Y).
    channelType*: uint8
      ## SEG-D channel type of the trace's channel set (Rev 1/2 nibble, 1 =
      ## seismic; Rev 3 byte, 0x10 = seismic); 0 for SEG-Y and unknown sets.
      ## SEG-2: 1 + the `Seg2TraceType` ordinal of TRACE_TYPE, 0 if none.

  TraceCodec* = object
    ## How the samples of one SEG-Y file, SEG-D record or SEG-2 sample
    ## format are encoded.
    kind*: SeismicKind
    segyFormat*: Option[SampleFormat]
      ## SEG-Y format, when `kind == skSegy`; none if not decodable.
    order*: ByteOrder             ## SEG-Y and SEG-2 byte order.
    segdFormat*: Option[SegdSampleFormat]
      ## SEG-D format, when `kind == skSegd`; none if not decodable.
    seg2Format*: Option[Seg2Format]
      ## SEG-2 format, when `kind == skSeg2`; none if not decodable.
    twosComplement8015*: bool
      ## SEG-D 8015 (and SEG-2 format 3) mantissas read as two's complement.

  TraceIndex* = object
    ## Every trace's location plus the file-level headers.
    kind*: SeismicKind
    entries*: seq[TraceEntry]
    codecs*: seq[TraceCodec]
      ## One per SEG-D record; one for SEG-Y; one per sample format for SEG-2.
    contiguous*: bool
      ## Offsets are byte offsets in a plain file, so each trace's headers and
      ## samples are contiguous there (false for tape images and devices, and
      ## for multiplexed SEG-D).
    maxSamples*: int          ## Largest `numSamples`.
    segy*: SegyFile           ## SEG-Y file headers, when `kind == skSegy`.
    segdLabel*: Option[SegdStorageUnitLabel] ## The SEG-D storage unit label, if any.
    segdRecords*: seq[SegdRecord] ## SEG-D record headers and trailers, by record index.
    segdToc*: seq[SegdToc]    ## SEG-D Rev 3 Table of Contents files met.
    seg2*: Seg2File
      ## The SEG-2 File Descriptor Block, when `kind == skSeg2` (trace
      ## descriptors are re-read from the map: `SeismicFile.seg2Trace`).
    log*: DiagLog             ## Diagnostics of the walk.
    detected*: bool           ## The stream was identified as `kind` and walked.
    keys*: seq[TraceKeys]
      ## Per-trace geometry, parallel to `entries`; empty unless the index was
      ## built with `keys = true` (144 bytes per trace).
    segyIntervalUs*: float64
      ## SEG-Y: the effective sample interval every trace shares (µs for time
      ## data), NaN when traces differ or there are none; 0 for SEG-D (see
      ## `summary`).

const NoChannelSet* = 0xFFFF'u16
  ## `TraceEntry.channelSet` of a trace without a known channel set. The
  ## reader allows at most 65535 sets per scan type, so index 65535 is free.

static: doAssert sizeof(TraceEntry) == 24

func channelSetIndex*(e: TraceEntry): int {.inline.} =
  ## The 0-based channel set index, -1 if unknown.
  if e.channelSet == NoChannelSet: -1 else: int(e.channelSet)

func len*(ix: TraceIndex): int {.inline.} =
  ## The number of traces indexed.
  ix.entries.len

func sampleOffset*(e: TraceEntry): int64 {.inline.} =
  ## Medium offset of the trace's first sample byte.
  e.offset + int64(e.headerBytes)

func known*(c: TraceCodec): bool {.inline.} =
  ## True when the samples are decodable (the format is known).
  case c.kind
  of skSegy: c.segyFormat.isSome
  of skSegd: c.segdFormat.isSome
  of skSeg2: c.seg2Format.isSome
  of skUnknown: false

func dataBytes*(c: TraceCodec, samples: int): int =
  ## Bytes holding `samples` samples (0 for an undecodable format).
  if not c.known: 0
  else:
    case c.kind
    of skSegy: samples * sampleSize(c.segyFormat.get)
    of skSegd: dataBytes(c.segdFormat.get, samples)
    of skSeg2: dataBytes(c.seg2Format.get, samples)
    of skUnknown: 0

func dataBytes*(ix: TraceIndex, i: int): int {.inline.} =
  ## Sample bytes of trace `i`.
  ix.codecs[ix.entries[i].record].dataBytes(int(ix.entries[i].numSamples))

func prefersFloat64*(ix: TraceIndex): bool =
  ## True when some trace's format would lose precision in float32.
  for c in ix.codecs:
    if c.known:
      let wide = case c.kind
        of skSegy: prefersFloat64(c.segyFormat.get)
        of skSegd: prefersFloat64(c.segdFormat.get)
        of skSeg2: prefersFloat64(c.seg2Format.get)
        of skUnknown: false
      if wide: return true

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

func detectKind*(head: openArray[byte]): SeismicKind =
  ## Guesses the standard from the first bytes of a stream (pass at least
  ## 3728). SEG-2: the File Descriptor Block ID (`55 3A` or `3A 55`) and the
  ## first trace's block ID or a plausible fixed part (`isSeg2`); neither
  ## SEG-Y text nor a SEG-D BCD file number can start that way. SEG-D: a
  ## storage unit label or a Table of Contents file. SEG-Y: a
  ## textual header starting with `C` that is mostly printable EBCDIC or
  ## ASCII, possibly after a 128-byte tape label. Otherwise SEG-D if the bytes
  ## are a plausible General Header #1 (a SEG-D file number 43xx starts with
  ## ASCII `C`, but its next 3200 bytes are not text). `skUnknown` if nothing
  ## fits.
  if isSeg2(head): skSeg2
  elif isStorageUnitLabel(head) or isTocFile(head): skSegd
  elif looksLikeSegy(head, 0) or (head.len >= 6 and head[4] == 0x53 and head[5] == 0x59 and
      looksLikeSegy(head, 128)):
    skSegy
  elif looksLikeSegdGh1(head): skSegd
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

proc indexSegy(src: RecordSource, keys: bool): TraceIndex =
  var r = openSegy(src, headersOnly = true)
  result = TraceIndex(kind: skSegy, contiguous: not src.hasRecordBoundaries)
  result.codecs.add TraceCodec(kind: skSegy, segyFormat: r.file.format,
    order: r.file.byteOrder)
  let gr = if keys: initGeometryReader(r.file) else: GeometryReader()
  result.segyIntervalUs = NaN
  var t: SegyTrace
  while r.readTrace(t):
    if result.entries.len == 0: result.segyIntervalUs = t.sampleInterval
    elif t.sampleInterval != result.segyIntervalUs: result.segyIntervalUs = NaN
    let hb = TraceHeaderSize + (if t.hasExt1: TraceHeaderSize + t.proprietary.len else: 0)
    result.entries.add TraceEntry(offset: t.offset, headerBytes: uint32(hb),
      numSamples: uint32(t.numSamples), channelSet: NoChannelSet, scanType: -1)
    result.maxSamples = max(result.maxSamples, t.numSamples)
    if keys: result.keys.add gr.traceKeys(t)
    if result.entries.len == 1:
      result.reserveFor(src, result.entries[0], result.codecs[0].dataBytes(t.numSamples), keys)
  result.segy = r.file
  result.log = r.log

proc indexSegd(src: RecordSource, twosComplement8015, keys: bool): TraceIndex =
  var r = openSegd(src, twosComplement8015, headersOnly = true)
  result = TraceIndex(kind: skSegd, contiguous: not src.hasRecordBoundaries)
  while r.nextRecord():
    let ri = uint32(result.segdRecords.len)
    var t: SegdTrace
    while r.readTrace(t):
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

proc indexSeg2(src: MemFileSource, twosComplement8015, keys: bool): TraceIndex =
  # The whole file, from the map: pointers may come in any order.
  result = TraceIndex(kind: skSeg2, contiguous: true)
  let size = src.size
  let empty: seq[byte] = @[]
  template data: untyped =
    (if size > 0: src.memory.toOpenArray(0, int(size) - 1) else: empty.toOpenArray(0, -1))
  var log: DiagLog
  result.seg2 = readSeg2(data, log, src.name)
  template f: untyped = result.seg2
  for t in traces(data, f, log, src.name):
    let fmt = if t.valid: t.format else: none(Seg2Format)
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
    keys = false): TraceIndex =
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
  result = case kind
    of skSegy: indexSegy(src, keys)
    of skSegd: indexSegd(src, twosComplement8015, keys)
    of skSeg2:
      if not (src of MemFileSource):
        raise newException(ValueError, "SEG-2 is indexed from a memory-mapped file " &
          "(openSeismic or a MemFileSource), not from a stream")
      indexSeg2(MemFileSource(src), twosComplement8015, keys)
    of skUnknown: raise newException(ValueError, "buildIndex needs SEG-Y, SEG-D or SEG-2")
  result.detected = true

# ---------------------------------------------------------- range decode --

proc decodeRun[T: SampleType](c: TraceCodec, src: openArray[byte], dst: var openArray[T]) =
  # `dst.len` samples of codec `c` from the start of `src` (a known format).
  case c.kind
  of skSegy: decodeSamples(c.segyFormat.get, src, dst, c.order)
  of skSegd: decodeSegdSamples(c.segdFormat.get, src, dst, c.twosComplement8015)
  of skSeg2: decodeSeg2Samples(c.seg2Format.get, src, dst, c.order, c.twosComplement8015)
  of skUnknown: discard

func packedInFours(c: TraceCodec): bool {.inline.} =
  # 4 samples in 10 bytes (SEG-D 8015, SEG-2 format 3): a window must start
  # on a group.
  (c.kind == skSegd and c.segdFormat.get == sd8015) or
    (c.kind == skSeg2 and c.seg2Format.get == s2Float20)

proc decodeEntry*[T: SampleType](mem: ptr UncheckedArray[byte], size: int64, e: TraceEntry,
    c: TraceCodec, dst: ptr UncheckedArray[T], cols: int, first = 0) =
  ## Decodes samples `first ..< first + cols` of trace `e` from the mapped
  ## bytes `mem[0 ..< size]` into `dst[0 ..< cols]`, zero past the trace's
  ## end. Only the window's bytes are read; a window of SEG-D 8015 or SEG-2
  ## format 3 (4 samples in 10 bytes) that starts inside a group decodes that
  ## whole group first. Touches no managed memory, so a worker thread may
  ## call it. Raises `SegFormatError` for an undecodable format and
  ## `SegTruncatedError` when the trace lies past `size` (the whole trace is
  ## checked, whatever the window).
  let n = clamp(int(e.numSamples) - first, 0, cols)
  if not c.known:
    raiseFormat("the sample format is not decodable", e.offset)
  let nbytes = c.dataBytes(int(e.numSamples))
  let start = e.sampleOffset
  if start < 0 or start + nbytes > size:
    raiseTruncated("trace samples lie past the end of the file", start)
  if n > 0:
    let a = int(start)
    let last = a + nbytes - 1
    if first == 0:
      c.decodeRun(mem.toOpenArray(a, last), dst.toOpenArray(0, n - 1))
    elif not c.packedInFours:
      let skip = c.dataBytes(first)
      c.decodeRun(mem.toOpenArray(a + skip, last), dst.toOpenArray(0, n - 1))
    else:
      # The group holding `first`, then whole groups straight into `dst`.
      let g = a + first div 4 * 10
      let lead = first mod 4
      var head = 0
      if lead > 0:
        var grp: array[4, T]
        head = min(4 - lead, n)
        c.decodeRun(mem.toOpenArray(g, last), grp.toOpenArray(0, lead + head - 1))
        for k in 0..<head: dst[k] = grp[lead + k]
      if head < n:
        let b = if lead > 0: g + 10 else: g
        c.decodeRun(mem.toOpenArray(b, last), dst.toOpenArray(head, n - 1))
  for k in n..<cols: dst[k] = T(0)

# ---------------------------------------------------------- seismic file --

type
  MapOwner {.acyclic.} = object
    ## Owns a file's mapping: unmaps when the last reference goes. The
    ## `SeismicFile` holds one until `close`; each running `Prefetcher` holds
    ## one too (a `MapPin`), so closing the file while a prefetcher still
    ## decodes defers the unmap to the prefetcher's `close`.
    src: MemFileSource
    tempPath: string ## A demultiplexed copy to delete with the map ("" if none).
    pins: int        ## Live `MapPin`s (prefetchers); consumer thread only.
    parkedEntries: seq[TraceEntry]
      ## The index tables of a file destroyed while pinned: the prefetchers
      ## read them through raw pointers, so they live as long as the map.
    parkedCodecs: seq[TraceCodec]

  MapRef = ref MapOwner

proc `=destroy`(m: MapOwner) =
  if m.src != nil:
    # A destructor must not raise; the base methods raise [CatchableError].
    try: m.src.close()
    except CatchableError: discard
  if m.tempPath.len > 0: discard tryRemoveFile(m.tempPath)
  `=destroy`(m.src)
  `=destroy`(m.tempPath)
  `=destroy`(m.parkedEntries)
  `=destroy`(m.parkedCodecs)

proc `=copy`(dst: var MapOwner, src: MapOwner) {.error.}

type
  MapPin* = object
    ## **Internal** (the prefetcher). Keeps a file's map alive, and the
    ## file's index tables if the file is destroyed first. Not copyable.
    m: MapRef

proc `=destroy`*(p: MapPin) =
  if p.m != nil: dec p.m.pins
  `=destroy`(p.m)

proc `=copy`(dst: var MapPin, src: MapPin) {.error.}
proc `=dup`(src: MapPin): MapPin {.error.}

type
  SeismicFile* = object
    ## A memory-mapped disk file with its trace index.
    index*: TraceIndex
    path: string      ## See `path`.
    demuxPath: string ## See `demuxPath`.
    map: MapRef       ## nil once closed.

proc `=destroy`(f: SeismicFile) =
  # `f` is passed by reference and this is its last use, so its fields may
  # be moved out (and `TraceIndex` has only the generic `var` destructor).
  let pf = addr f
  if f.map != nil and f.map.pins > 0:
    # A prefetcher still reads `entries` and `codecs` through raw pointers:
    # hand them to the map it keeps alive. A seq move keeps the payload's
    # address, so nothing is copied and the pointers stay valid.
    f.map.parkedEntries = move pf[].index.entries
    f.map.parkedCodecs = move pf[].index.codecs
  `=destroy`(pf[].index)
  `=destroy`(f.path)
  `=destroy`(f.demuxPath)
  `=destroy`(f.map)

proc `=copy`*(dst: var SeismicFile, src: SeismicFile) {.error.}
  # A copy would share the map, and outlive `close` with a dangling view.

func mapped(f: SeismicFile): bool {.inline.} =
  # Read the map's fields through `f.map.src` in place, never through a
  # local copy of the ref: threads share one file for `readTracesInto`, and
  # ORC's reference counts are not atomic.
  f.map != nil and f.map.src != nil

proc pinMap*(f: SeismicFile): MapPin =
  ## **Internal.** A pin on `f`'s map (an empty pin for a closed file).
  if f.map != nil:
    inc f.map.pins
    result = MapPin(m: f.map)

func multiplexed(ix: TraceIndex): bool =
  for r in ix.segdRecords:
    if r.multiplexed: return true

var demuxCopies {.threadvar.}: int ## Copies made by this thread, for unique names.

proc newDemuxPath(dir: string): string =
  # A file name no other copy uses: process id, time and a counter (not
  # `std/tempfiles`, whose random source needs a framework the macOS
  # cross-build lacks). The file is created empty.
  let d = if dir.len > 0: dir else: getTempDir()
  while result.len == 0 or fileExists(result):
    inc demuxCopies
    result = d / ("parseseg_demux_" & $getCurrentProcessId() & "_" &
      $(epochTime() * 1e6).int64 & "_" & $demuxCopies & ".sgd")
  writeFile(result, "")

proc openDemultiplexed(f: var SeismicFile, twosComplement8015, keys: bool, dir: string) =
  # Replaces the map and index of a multiplexed SEG-D file by those of a
  # demultiplexed copy in `dir`. The original's walk is dropped: the copy's
  # log repeats its reader diagnostics.
  let tmp = newDemuxPath(dir)
  f.map.src.close()
  f.map.src = nil
  f.map.tempPath = tmp # deleted with the map from here on
  var log = demultiplexSegd(f.path, tmp, twosComplement8015)
  log.report(sevWarning, dcMultiplexed, "the file holds multiplexed SEG-D, demultiplexed into " &
    "the temporary copy " & tmp & " (deleted on close); the index, range reads and keys " &
    "use the copy", 0, Location(file: f.path))
  f.map.src = openMemFileSource(tmp)
  f.demuxPath = tmp
  f.index = buildIndex(f.map.src, skSegd, twosComplement8015, keys)
  log.add f.index.log
  f.index.log = log

proc openMapped(path: string, twosComplement8015, keys, writable: bool,
    demuxDir: string): SeismicFile =
  # `openSeismic` / `openSeismicRw`.
  result = SeismicFile(path: path, map: MapRef(src: openMemFileSource(path, writable)))
  let n = int(min(result.map.src.size, 8192))
  let kind = if n > 0: detectKind(result.map.src.memory.toOpenArray(0, n - 1)) else: skUnknown
  if kind != skUnknown:
    result.index = buildIndex(result.map.src, kind, twosComplement8015, keys)
    if kind == skSegd and result.index.multiplexed:
      if writable:
        raise newException(ValueError, path & " holds multiplexed SEG-D, which cannot be " &
          "edited in place; convert it to a demultiplexed file first (`parseseg convert " &
          "--to=segd`, `convertSegdRevision`) and edit that")
      result.openDemultiplexed(twosComplement8015, keys, demuxDir)
  else:
    result.index.contiguous = true
    result.index.log.report(sevFatal, dcUnsupportedFormat,
      "not a SEG-Y, SEG-D or SEG-2 file", 0, Location(file: path))

proc openSeismic*(path: string, twosComplement8015 = false, keys = false,
    demuxDir = ""): SeismicFile =
  ## Maps the disk file `path` read-only, detects SEG-Y, SEG-D or SEG-2, and
  ## builds the trace index (with per-trace geometry when `keys`;
  ## `twosComplement8015` also reads SEG-2 format-3 mantissas as two's
  ## complement). Format problems are in `index.log`; an undetectable file
  ## gives a fatal diagnostic and an empty index. Raises `IOError`/`OSError`
  ## if the file cannot be opened or mapped. To change headers in place, use
  ## `openEditor` (`model/edit`).
  ##
  ## A SEG-D file with multiplexed records is demultiplexed once into a
  ## temporary copy in `demuxDir` (default: the OS temp directory), which is
  ## mapped and indexed instead (`demuxPath`, a warning in `log`) and deleted
  ## on `close`; the file itself is never changed.
  openMapped(path, twosComplement8015, keys, false, demuxDir)

proc openSeismicRw*(path: string): SeismicFile =
  ## **Internal** (`openEditor`; not exported by `parseSEG`). `openSeismic`
  ## mapped read-write. Raises `ValueError` for multiplexed SEG-D: edits
  ## would change only the demultiplexed copy.
  openMapped(path, false, false, true, "")

proc close*(f: var SeismicFile) =
  ## Unmaps the file and deletes a demultiplexed copy (`demuxPath`). The
  ## index stays usable; range reads do not. A prefetcher still running on
  ## the file keeps the map until its own `close`. Idempotent.
  f.map = nil

func path*(f: SeismicFile): lent string {.inline.} =
  ## The file's path, as opened.
  f.path

func demuxPath*(f: SeismicFile): lent string {.inline.} =
  ## The temporary demultiplexed copy that is mapped and indexed instead of a
  ## multiplexed SEG-D file ("" for any other file); deleted on `close`.
  ## Index offsets and `copyBytes` refer to it.
  f.demuxPath

func len*(f: SeismicFile): int {.inline.} =
  ## The number of traces.
  f.index.entries.len

func kind*(f: SeismicFile): SeismicKind {.inline.} =
  ## SEG-Y, SEG-D or SEG-2; `skUnknown` when the file was not recognized.
  if f.index.detected: f.index.kind else: skUnknown

func log*(f: SeismicFile): lent DiagLog {.inline.} =
  ## Every problem found while indexing.
  f.index.log

func recordCount*(f: SeismicFile): int =
  ## SEG-D records; 1 for SEG-Y and SEG-2; 0 for an unrecognized file.
  if not f.index.detected: 0
  elif f.index.kind == skSegd: f.index.segdRecords.len
  else: 1

func maxSamples*(f: SeismicFile): int {.inline.} =
  ## Samples in the longest trace.
  f.index.maxSamples

proc raiseNoTrace(f: SeismicFile, trace: int) {.noinline, noreturn.} =
  raise newException(ValueError, "no trace " & $trace & " (the file has " & $f.len & ")")

func traceEntry*(f: SeismicFile, trace: int): TraceEntry =
  ## Where trace `trace` lives: header offset, header bytes, samples, record,
  ## channel set, scan type and channel type. Raises `ValueError` for a trace
  ## out of range.
  if trace notin 0 ..< f.len: f.raiseNoTrace(trace)
  f.index.entries[trace]

func hasKeys*(f: SeismicFile): bool {.inline.} =
  ## The index holds per-trace geometry (`openSeismic(keys = true)`).
  f.index.keys.len == f.index.entries.len

func traceKeys*(f: SeismicFile, trace: int): TraceKeys =
  ## A trace's geometry (NaN or 0 where unknown). Raises `ValueError` for a
  ## trace out of range or a file opened without `keys`.
  if trace notin 0 ..< f.len: f.raiseNoTrace(trace)
  if not f.hasKeys: raise newException(ValueError, "open the file with keys = true")
  f.index.keys[trace]

proc seg2Trace*(f: SeismicFile, trace: int): Seg2Trace =
  ## The SEG-2 Trace Descriptor Block of trace `trace` (fixed part and
  ## keyword strings), re-read from the map. Raises `ValueError` for a file
  ## that is not SEG-2 or is closed, or a trace out of range.
  if f.kind != skSeg2: raise newException(ValueError, "not a SEG-2 file")
  if trace notin 0 ..< f.len: f.raiseNoTrace(trace)
  if not f.mapped: raise newException(ValueError, "the file is closed")
  var log: DiagLog # already reported by the index walk
  readSeg2Trace(f.map.src.memory.toOpenArray(0, int(f.map.src.size) - 1), f.index.seg2, trace,
    log, f.path)

func cardLines(text: string): string =
  # A text block as lines of `CardWidth` characters joined by '\n'.
  result = newStringOfCap(text.len + text.len div CardWidth)
  for i, c in text:
    if i > 0 and i mod CardWidth == 0: result.add '\n'
    result.add c

proc requireSegy(f: SeismicFile) =
  if f.kind != skSegy: raise newException(ValueError, "not a SEG-Y file")

func textHeader*(f: SeismicFile): string =
  ## SEG-Y: the 3200-byte textual file header decoded (EBCDIC or ASCII, as
  ## detected) to 40 lines of 80 Latin-1 characters joined by '\n', with no
  ## trailing newline. Works on a closed file. Raises `ValueError` for a file
  ## that is not SEG-Y.
  f.requireSegy()
  cardLines(f.index.segy.text.text)

proc extendedTextHeaders*(f: SeismicFile): seq[string] =
  ## SEG-Y Rev 1+: each extended textual header record after the binary
  ## header, decoded in its own detected character set, as 40 lines of 80
  ## characters joined by '\n' (the stanzas parsed from them are in
  ## `f.index.segy.extended`). Empty when there are none. Records of binary
  ## stanzas come out as their bytes in Latin-1. Raises `ValueError` for a
  ## file that is not SEG-Y, or a closed one when the records were too large
  ## to keep in memory.
  f.requireSegy()
  template ext: untyped = f.index.segy.extended
  let n = ext.recordCount
  let start = int64(f.index.segy.tapeLabel.len + TextHeaderSize + BinaryHeaderSize)
  if not ext.isComplete and n > 0:
    if not f.mapped: raise newException(ValueError, "the file is closed")
    if start + int64(n * TextHeaderSize) > f.map.src.size:
      raise newException(ValueError, "the extended textual header lies past the end of the file")
  template record(rec: openArray[byte]): string =
    cardLines(decodeText(rec, detectTextEncoding(rec)))
  for r in 0..<n:
    let a = r * TextHeaderSize
    if ext.isComplete:
      result.add record(ext.data.toOpenArray(a, a + TextHeaderSize - 1))
    else:
      let b = int(start) + a
      result.add record(f.map.src.memory.toOpenArray(b, b + TextHeaderSize - 1))

proc unsafeMemory*(f: SeismicFile): ptr UncheckedArray[byte] {.inline.} =
  ## **Internal.** The mapped bytes (nil after `close`), for the library's own
  ## zero-copy decoders and the journaled `HeaderEditor`. Not part of the
  ## public API, and not exported by the `parseSEG` module: a write through it
  ## would bypass the editor's validation and undo journal (owner rule: files
  ## change only on an explicit write). Callers use `copyBytes`, the readers,
  ## or `traceField`/`fileField` instead.
  if f.mapped: f.map.src.memory else: nil

func isOpen*(f: SeismicFile): bool {.inline.} =
  ## The file is still mapped (range reads work).
  f.mapped

proc copyBytes*(f: SeismicFile, offset: int64, n: Natural): seq[byte] =
  ## A copy of `n` raw bytes at `offset` in the file (e.g. a header for a
  ## hex view). Raises `ValueError` if the file is closed or the range lies
  ## outside it. Changing the copy never changes the file.
  if not f.mapped: raise newException(ValueError, "the file is closed")
  let size = f.map.src.size
  # `n > size - offset`, not `offset + n > size`: the sum can overflow.
  if offset < 0 or offset > size or int64(n) > size - offset:
    raise newException(ValueError, "bytes " & $offset & "+" & $n & " lie outside the file (" &
      $size & " bytes)")
  result = newSeq[byte](n)
  if n > 0: copyMem(addr result[0], addr f.map.src.memory[offset], n)

proc mappedSize*(f: SeismicFile): int64 {.inline.} =
  ## **Internal.** Bytes mapped (0 after `close`). Not exported by `parseSEG`.
  if f.mapped: f.map.src.size else: 0

proc flush*(f: SeismicFile) =
  ## **Internal.** Writes modified pages of a writable map back to the file
  ## (`HeaderEditor.close`). Not exported by `parseSEG`.
  if f.mapped: f.map.src.flush()

# ------------------------------------------------- checks shared by model --
# Exported for the sibling model modules (gathers, prefetch, survey/join);
# the `parseSEG` umbrella does not re-export them.

proc requireKeys*(ix: TraceIndex) =
  ## **Internal.** Raises `ValueError` unless the index holds per-trace keys.
  if ix.keys.len != ix.entries.len:
    raise newException(ValueError, "open the file with keys = true")

proc checkSpan*(span: Slice[int], len: int, what = "traces") =
  ## **Internal.** Raises `ValueError` unless `span` lies in `0 ..< len`; an
  ## empty span must start in `0 .. len` (so `len .. len - 1` is allowed,
  ## `len + 2 .. len + 1` is not).
  if span.a < 0 or span.a > len or span.b >= len:
    raise newException(ValueError, what & " " & $span & " lie outside 0.." & $(len - 1))

func spanLen*(span: Slice[int]): int {.inline.} =
  ## **Internal.** The number of elements of `span`; 0 when empty.
  if span.b < span.a: 0 else: span.len

# ------------------------------------------------------- keys on demand --

type
  KeyReader = object
    # Per-call state of `traceKeysInto`: buffers reused across traces.
    gr: GeometryReader
    segy: SegyTrace
    segd: array[SegdLayout, SegdTrace]

proc initKeyReader(f: SeismicFile): KeyReader =
  if f.index.kind == skSegy: result.gr = initGeometryReader(f.index.segy)
  result.segd = [SegdTrace(layout: slRev2), SegdTrace(layout: slRev3)]

proc raiseOutside(trace: int) {.noinline, noreturn.} =
  raise newException(ValueError, "the headers of trace " & $trace & " lie outside the file")

proc keysOf(f: SeismicFile, r: var KeyReader, mem: ptr UncheckedArray[byte], size: int64,
    trace: int): TraceKeys =
  # The keys of `trace` from its mapped headers, as the index walk makes them.
  template ix: untyped = f.index
  let e = ix.entries[trace]
  let a = int(e.offset)
  let hb = int(e.headerBytes)
  case ix.kind
  of skSegy:
    let order = ix.segy.byteOrder
    if e.offset < 0 or e.offset + max(hb, TraceHeaderSize) > size: raiseOutside(trace)
    template t: untyped = r.segy
    t.header = decodeTraceHeader(mem.toOpenArray(a, a + TraceHeaderSize - 1), order)
    t.hasExt1 = hb >= 2 * TraceHeaderSize
    let extra = hb - 2 * TraceHeaderSize
    if t.hasExt1:
      t.ext1 = decodeTraceHeaderExt1(
        mem.toOpenArray(a + TraceHeaderSize, a + 2 * TraceHeaderSize - 1), order)
    t.proprietary.setLen max(extra, 0)
    if extra > 0: copyMem(addr t.proprietary[0], addr mem[a + 2 * TraceHeaderSize], extra)
    t.index = trace
    t.offset = e.offset
    r.gr.traceKeys(t)
  of skSegd:
    if e.offset < 0 or e.offset + hb > size or hb < SegdTraceHeaderSize: raiseOutside(trace)
    template rec: untyped = ix.segdRecords[e.record]
    template t: untyped = r.segd[rec.layout]
    t.header = decodeBlock[SegdTraceHeader](mem.toOpenArray(a, a + SegdTraceHeaderSize - 1))
    let b1 = a + SegdTraceHeaderSize
    let extra = hb - SegdTraceHeaderSize - SegdBlockSize
    case t.layout
    of slRev2:
      t.ext1 = if extra >= 0:
          some(decodeBlock[SegdTraceHeaderExt1](mem.toOpenArray(b1, b1 + SegdBlockSize - 1)))
        else: none(SegdTraceHeaderExt1)
    of slRev3:
      t.ext1Rev3 = if extra >= 0:
          some(decodeBlock[SegdTraceHeaderExt1Rev3](mem.toOpenArray(b1, b1 + SegdBlockSize - 1)))
        else: none(SegdTraceHeaderExt1Rev3)
    t.extensions.setLen max(extra, 0)
    if extra > 0: copyMem(addr t.extensions[0], addr mem[b1 + SegdBlockSize], extra)
    t.offset = e.offset
    t.scanType = int(e.scanType)
    t.channelSet = e.channelSetIndex
    t.numSamples = int(e.numSamples)
    traceKeys(rec, t)
  of skSeg2:
    var log: DiagLog # already reported by the index walk
    let t = readSeg2Trace(mem.toOpenArray(0, int(size) - 1), ix.seg2, trace, log, f.path)
    traceKeys(ix.seg2, t)
  of skUnknown: initTraceKeys() # no traces

template keysLoop(f: SeismicFile, dst: var openArray[TraceKeys], count: int,
    traceAt: untyped) =
  if dst.len != count:
    raise newException(ValueError, "need " & $count & " keys, got " & $dst.len)
  if f.hasKeys:
    for k in 0 ..< count: dst[k] = f.index.keys[traceAt(k)]
  elif count > 0:
    if not f.isOpen: raise newException(ValueError, "the file is closed")
    let mem = f.unsafeMemory
    let size = f.mappedSize
    var r = initKeyReader(f)
    for k in 0 ..< count: dst[k] = f.keysOf(r, mem, size, traceAt(k))

proc traceKeysInto*(f: SeismicFile, traces: openArray[int], dst: var openArray[TraceKeys]) =
  ## The keys of each trace of `traces` into `dst` (`dst.len == traces.len`).
  ## A file opened with `keys = true` copies its stored keys (with any
  ## `applyGeometry` or `applySurvey` changes); otherwise the keys are made
  ## on demand from the mapped headers, exactly as `openSeismic(keys = true)`
  ## makes them (the file's own geometry: survey changes are not applied).
  ## On demand costs about what the index walk spends per trace, but only for
  ## the traces asked for. Raises `ValueError` for a trace out of range, a
  ## closed file or a `dst` of the wrong length.
  for i in traces:
    if i notin 0 ..< f.len: f.raiseNoTrace(i)
  template at(k: int): int = traces[k]
  keysLoop(f, dst, traces.len, at)

proc traceKeysInto*(f: SeismicFile, traces: Slice[int], dst: var openArray[TraceKeys]) =
  ## `traceKeysInto` for a range of traces (an empty range must start in
  ## `0 .. f.len`).
  checkSpan(traces, f.len)
  template at(k: int): int = traces.a + k
  keysLoop(f, dst, spanLen(traces), at)

proc traceKeys*(f: SeismicFile, traces: openArray[int]): seq[TraceKeys] =
  ## The keys of each trace of `traces` (see `traceKeysInto`); works on a file
  ## opened without `keys = true`.
  result = newSeq[TraceKeys](traces.len)
  f.traceKeysInto(traces, result)

proc traceKeys*(f: SeismicFile, traces: Slice[int]): seq[TraceKeys] =
  ## The keys of a range of traces (see `traceKeysInto`).
  checkSpan(traces, f.len)
  result = newSeq[TraceKeys](spanLen(traces))
  f.traceKeysInto(traces, result)

# ---------------------------------------------------------------- reading --

template decodeLoop(f: SeismicFile, count: int, traceAt, rowAt: untyped, cols, first: int,
    log: var DiagLog, T: typedesc): int =
  # Decodes `count` traces: samples `first ..< first + cols` of trace
  # `traceAt(k)` into row pointer `rowAt(k)`.
  var failed = 0
  let mem = f.unsafeMemory
  let size = f.mappedSize
  for k in 0..<count:
    let i = traceAt(k)
    let e = f.index.entries[i]
    let p = rowAt(k)
    try:
      decodeEntry(mem, size, e, f.index.codecs[e.record], p, cols, first)
    except SegError as err:
      for c in 0..<cols: p[c] = T(0)
      log.report(sevError, if err of SegTruncatedError: dcTruncated else: dcUnsupportedFormat,
        err.msg, e.offset, Location(file: f.path,
          record: if f.index.kind == skSeg2: 0 else: int(e.record), trace: i))
      inc failed
  failed

proc checkReadable(f: SeismicFile, count: int) =
  if not f.isOpen and count > 0: raise newException(ValueError, "the file is closed")
  if not f.index.contiguous:
    raise newException(ValueError, "range reads need a plain disk file")

proc checkSelection(f: SeismicFile, traces: Slice[int]) {.inline.} =
  checkSpan(traces, f.len)

proc checkSelection(f: SeismicFile, traces: openArray[int]) =
  for i in traces:
    if i notin 0 ..< f.len: f.raiseNoTrace(i)

proc checkRows[T](dst: Tensor[T], row, count: int) =
  if not (dst.rank == 2 and dst.is_C_contiguous and row >= 0 and row + count <= dst.shape[0]):
    raise newException(ValueError,
      "need a row-major [traces, samples] tensor with room for the traces")

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], dst: var Tensor[T],
    row = 0, log: var DiagLog): int =
  ## Decodes `traces` into rows `row ..< row + traces.len` of `dst` (a
  ## row-major `[rows, samples]` tensor), each truncated or zero-padded to
  ## `dst.shape[1]`. A trace that cannot be decoded is left zero, logged in
  ## `log`, and counted in the result. Raises `ValueError` for traces outside
  ## the file (an empty range must still start in `0 .. f.len`), a closed
  ## file or a tensor without room.
  let count = traces.spanLen
  f.checkReadable(count)
  f.checkSelection(traces)
  dst.checkRows(row, count)
  template trace(k: int): int = traces.a + k
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, count, trace, rowOf, dst.shape[1], 0, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    dst: var Tensor[T], row = 0, log: var DiagLog): int =
  ## Decodes the selected traces, in list order, into rows `row ..< row +
  ## traces.len` of `dst`: a gather, a component group, or a sort order (a
  ## sort is a list of trace indices; no data is moved). Otherwise as the
  ## `Slice` form.
  f.checkReadable(traces.len)
  f.checkSelection(traces)
  dst.checkRows(row, traces.len)
  template trace(k: int): int = traces[k]
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, traces.len, trace, rowOf, dst.shape[1], 0, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], dst: var Tensor[T],
    row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero); pass a log to learn which and why.
  var log: DiagLog
  f.readTracesInto(traces, dst, row, log)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    dst: var Tensor[T], row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero).
  var log: DiagLog
  f.readTracesInto(traces, dst, row, log)

proc checkWindow[T](dst: Tensor[T], samples: Slice[int]) =
  if samples.a < 0 or samples.b < samples.a:
    raise newException(ValueError, "the sample window " & $samples &
      " must be a..b with 0 <= a <= b")
  if dst.rank == 2 and dst.shape[1] != samples.len:
    raise newException(ValueError, "the sample window " & $samples & " needs " &
      $samples.len & " columns, the tensor has " & $dst.shape[1])

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], samples: Slice[int],
    dst: var Tensor[T], row = 0, log: var DiagLog): int =
  ## Decodes samples `samples` (0-based, `a..b`) of each trace of `traces`
  ## into rows `row ..< row + traces.len` of `dst`, whose `shape[1]` must be
  ## `samples.len`: a viewer's visible time window. Only the window's bytes
  ## are read (SEG-D 8015 and SEG-2 format 3 pack 4 samples in 10 bytes: a
  ## window starting inside a group also decodes the rest of that group).
  ## Past a trace's end the row is zero, so a window starting past it gives a
  ## zero row. A trace that cannot be decoded (the whole trace is checked)
  ## is left zero, logged in `log`, and counted in the result. Raises
  ## `ValueError` for a window that is empty or starts below 0, a tensor of
  ## another width or without room, traces outside the file or a closed file.
  let count = traces.spanLen
  dst.checkWindow(samples)
  f.checkReadable(count)
  f.checkSelection(traces)
  dst.checkRows(row, count)
  template trace(k: int): int = traces.a + k
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, count, trace, rowOf, dst.shape[1], samples.a, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    samples: Slice[int], dst: var Tensor[T], row = 0, log: var DiagLog): int =
  ## The sample window of the selected traces, in list order (a gather, a
  ## sort order); otherwise as the `Slice` form.
  dst.checkWindow(samples)
  f.checkReadable(traces.len)
  f.checkSelection(traces)
  dst.checkRows(row, traces.len)
  template trace(k: int): int = traces[k]
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, traces.len, trace, rowOf, dst.shape[1], samples.a, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], samples: Slice[int],
    dst: var Tensor[T], row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero).
  var log: DiagLog
  f.readTracesInto(traces, samples, dst, row, log)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    samples: Slice[int], dst: var Tensor[T], row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero).
  var log: DiagLog
  f.readTracesInto(traces, samples, dst, row, log)

func maxSamples*(f: SeismicFile, traces: Slice[int]): int =
  ## Largest sample count in the trace range (0 when empty). Raises
  ## `ValueError` for traces outside the file (an empty range must still
  ## start in `0 .. f.len`).
  f.checkSelection(traces)
  for i in traces: result = max(result, int(f.index.entries[i].numSamples))

func maxSamples*(f: SeismicFile, traces: openArray[int]): int =
  ## Largest sample count of the selected traces. Raises `ValueError` for a
  ## trace outside the file.
  f.checkSelection(traces)
  for i in traces: result = max(result, int(f.index.entries[i].numSamples))

proc readTraces*(f: SeismicFile, traces: Slice[int], log: var DiagLog,
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## `traces` as a new `[traces.len, maxSamples]` tensor (shorter traces are
  ## zero-padded). A trace that cannot be decoded stays zero and is logged in
  ## `log`. Raises `ValueError` for traces outside the file (an empty range
  ## must still start in `0 .. f.len`) or a closed file.
  # Uninitialized: the decode writes every element (samples, zero padding,
  # or a zero row for a trace that cannot be decoded).
  result = newTensorUninit[T](traces.spanLen, f.maxSamples(traces))
  discard f.readTracesInto(traces, result, 0, log)

proc readTraces*(f: SeismicFile, traces: openArray[int], log: var DiagLog,
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## The selected traces, in list order, as a new `[traces.len, maxSamples]`
  ## tensor; otherwise as the `Slice` form.
  result = newTensorUninit[T](traces.len, f.maxSamples(traces)) # every element is written
  discard f.readTracesInto(traces, result, 0, log)

proc readTraces*(f: SeismicFile, traces: Slice[int], samples: Slice[int], log: var DiagLog,
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## Samples `samples` of `traces` as a new `[traces.len, samples.len]`
  ## tensor (zero past a trace's end); see the windowed `readTracesInto`. A
  ## trace that cannot be decoded stays zero and is logged in `log`.
  result = newTensorUninit[T](traces.spanLen, max(samples.len, 0)) # every element is written
  discard f.readTracesInto(traces, samples, result, 0, log)

proc readTraces*(f: SeismicFile, traces: openArray[int], samples: Slice[int],
    log: var DiagLog, T: typedesc[SampleType] = float32): Tensor[T] =
  ## The sample window of the selected traces, in list order; otherwise as
  ## the `Slice` form.
  result = newTensorUninit[T](traces.len, max(samples.len, 0)) # every element is written
  discard f.readTracesInto(traces, samples, result, 0, log)

proc raiseUndecodable(log: DiagLog) {.noinline, noreturn.} =
  # The first decode error of `log`, with the count, as the exception.
  let first = log[0]
  let msg = $log.len & " trace(s) could not be decoded; trace " & $first.loc.trace & ": " &
    first.msg & " (pass a log to read past them)"
  if first.code == dcTruncated: raiseTruncated(msg, first.offset)
  else: raiseFormat(msg, first.offset)

proc readTraces*(f: SeismicFile, traces: Slice[int],
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## `traces` as a new `[traces.len, maxSamples]` tensor (shorter traces are
  ## zero-padded). Raises `ValueError` for traces outside the file (an empty
  ## range must still start in `0 .. f.len`) or a closed file, and `SegFormatError` (`SegTruncatedError` for samples past
  ## the end of the file) when a trace cannot be decoded: pass a `log` to
  ## get zero rows and diagnostics instead.
  var log: DiagLog
  result = f.readTraces(traces, log, T)
  if log.len > 0: raiseUndecodable(log)

proc readTraces*(f: SeismicFile, traces: openArray[int],
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## The selected traces, in list order, as a new `[traces.len, maxSamples]`
  ## tensor; otherwise as the `Slice` form.
  var log: DiagLog
  result = f.readTraces(traces, log, T)
  if log.len > 0: raiseUndecodable(log)

proc readTraces*(f: SeismicFile, traces: Slice[int], samples: Slice[int],
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## Samples `samples` of `traces` as a new `[traces.len, samples.len]`
  ## tensor. Raises like the full `readTraces` when a trace cannot be
  ## decoded, and `ValueError` for an empty window or one starting below 0.
  var log: DiagLog
  result = f.readTraces(traces, samples, log, T)
  if log.len > 0: raiseUndecodable(log)

proc readTraces*(f: SeismicFile, traces: openArray[int], samples: Slice[int],
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## The sample window of the selected traces, in list order; otherwise as
  ## the `Slice` form.
  var log: DiagLog
  result = f.readTraces(traces, samples, log, T)
  if log.len > 0: raiseUndecodable(log)

proc applyGeometry*(ix: var TraceIndex, g: GeometryTable, overwrite = false): int =
  ## Joins external geometry (survey files, a host's database) to every
  ## trace's keys on (line, point, index); see `keys.applyGeometry`. Returns
  ## the number of traces changed. Raises `ValueError` for an index built
  ## without `keys = true`.
  ix.requireKeys()
  for k in ix.keys.mitems:
    if k.applyGeometry(g, overwrite): inc result
