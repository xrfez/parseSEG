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

import std/[os, times, strutils]
import ../common/[errors, diagnostics, bcd, seismickind, progress, binstore, niftext,
  outputfile]
import ../version
import ../io/[records, memsource]
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader, mux, demux]
import ../seg2/[reader as seg2reader]
import ./[keys, indextypes]
import ../common/tensors
import ../segy/samples as segysamples, ../segd/samples as segdsamples, ../seg2/samples as seg2samples
import ../private/[checks, decodeentry, progressticker, tensorrows, segykeys, segywalk, segyfixed]

export memsource, diagnostics, keys, seismickind, progress, tensors, indextypes

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
proc `=dup`(src: MapOwner): MapOwner {.error.}

type
  MapPin* = object
    ## **Internal** (the prefetcher). Keeps a file's map alive, and the
    ## file's index tables if the file is destroyed first. Not copyable.
    m: MapRef

proc `=destroy`*(p: MapPin) =
  # Exported: `Prefetcher`'s destructor (another module) destroys its pin
  # explicitly, and only a visible hook binds to a non-`var` field there.
  if p.m != nil: dec p.m.pins
  `=destroy`(p.m)

proc `=copy`(dst: var MapPin, src: MapPin) {.error.}
proc `=dup`(src: MapPin): MapPin {.error.}

type
  FileStamp = object
    # A file's size and modification time, taken when it is opened.
    size, mtime: int64 # mtime: Unix seconds
    mtimeNs: int

  SeismicFile* = object
    ## A memory-mapped disk file with its trace index.
    index*: TraceIndex
    path: string      ## See `path`.
    demuxPath: string ## See `demuxPath`.
    map: MapRef       ## nil once closed.
    stamp: FileStamp  ## The file as opened, for `saveIndex`.
    walkLog: int      ## Entries of `index.log` the walk (or the cache) made.
    twos: bool        ## Opened with `twosComplement8015`.
    cached: bool      ## See `fromCache`.

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

proc `=copy`(dst: var SeismicFile, src: SeismicFile) {.error.}
  # A copy would share the map, and outlive `close` with a dangling view.
proc `=dup`(src: SeismicFile): SeismicFile {.error.}

func mapped(f: SeismicFile): bool {.inline.} =
  # Read the map's fields through `f.map.src` in place, never through a
  # local copy of the ref: threads share one file for `readTracesInto`, and
  # ORC's reference counts are not atomic.
  f.map != nil and f.map.src != nil

proc requireOpen*(f: SeismicFile) {.inline.} =
  ## **Internal.** Raises `ValueError` when `f` is closed (`isOpen`). Not
  ## exported by `parseSEG`.
  if not f.mapped: raiseClosed()

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

proc openDemultiplexed(f: var SeismicFile, twosComplement8015, keys: bool, dir: string,
    progress: Progress) =
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
  f.index = buildIndex(f.map.src, skSegd, twosComplement8015, keys, progress)
  log.add f.index.log
  f.index.log = log

proc stampOf(path: string): FileStamp =
  let info = getFileInfo(path)
  FileStamp(size: info.size, mtime: info.lastWriteTime.toUnix,
    mtimeNs: info.lastWriteTime.nanosecond)

proc loadIndex(f: var SeismicFile, cache: string, keys: bool, verify: VerifyMode): string
  {.raises: [].}

proc openMapped(path: string, twosComplement8015, keys, writable: bool,
    demuxDir: string, progress: Progress = nil, cache = "", verify = vfSampled): SeismicFile =
  # `openSeismic` / `openSeismicRw`. Built in a local, so a raise (a
  # cancelled walk) unmaps the file.
  var f = SeismicFile(path: path, map: MapRef(src: openMemFileSource(path, writable)),
    twos: twosComplement8015)
  f.stamp = stampOf(path)
  var why = ""
  if cache.len > 0:
    why = f.loadIndex(cache, keys, verify)
    if why.len == 0:
      f.cached = true
      f.walkLog = f.index.log.len
      var tk = initProgressTicker(progress, f.map.src.size)
      if not tk.finish(): raiseCancelled()
      return f
  let n = int(min(f.map.src.size, 8192))
  let kind = if n > 0: detectKind(f.map.src.memory.toOpenArray(0, n - 1)) else: skUnknown
  if kind != skUnknown:
    f.index = buildIndex(f.map.src, kind, twosComplement8015, keys, progress, verify)
    if kind == skSegd and f.index.multiplexed:
      if writable:
        raise newException(ValueError, path & " holds multiplexed SEG-D, which cannot be " &
          "edited in place; convert it to a demultiplexed file first (`parseseg convert " &
          "--to=segd`, `convertSegdRevision`) and edit that")
      f.openDemultiplexed(twosComplement8015, keys, demuxDir, progress)
  else:
    f.index.contiguous = true
    f.index.log.report(sevFatal, dcUnsupportedFormat,
      "not a SEG-Y, SEG-D or SEG-2 file", 0, Location(file: path))
  f.walkLog = f.index.log.len
  if cache.len > 0:
    f.index.log.report(sevInfo, dcIndexCache, "the index cache " & cache & " was not used (" &
      why & "); the file was indexed", 0, Location(file: path))
  f

proc openSeismic*(path: string, twosComplement8015 = false, keys = false,
    demuxDir = "", progress: Progress = nil, cache = "", verify = vfSampled): SeismicFile =
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
  ##
  ## `progress` is called about every MiB of the index walk with the bytes
  ## walked and the file's size, and once at the end (a multiplexed file:
  ## of the demultiplexed copy's walk). When it returns false the walk stops
  ## and `SegCancelledError` is raised; the file is unmapped.
  ##
  ## `cache` names an index cache that `saveIndex` wrote: when it was saved
  ## for this file as it is now (path, size, modification time, its first
  ## and last 64 KiB, the same `twosComplement8015`, keys when asked for)
  ## by this version of parseSEG, and is intact, the index is read from it
  ## instead of walking the file (`fromCache`). Otherwise the file is
  ## indexed as without `cache`, with an info diagnostic (`dcIndexCache`)
  ## saying why; the cache is never written here. A cache saved from a
  ## sampled open (below) is not used with `verify = vfFull`.
  ##
  ## `verify` (`vfSampled` by default): a fixed-length SEG-Y file (Rev 1 or
  ## later, binary bytes 3503-3504 = 1) is indexed from its size, without
  ## walking the trace headers: 10 M traces in milliseconds, and only the
  ## pages of the sampled headers are read. Up to 64 headers, the first, the
  ## last and the rest spread between, must have the binary header's sample
  ## count and interval; the log then has an info
  ## diagnostic (`dcIndexSampled`) with the number checked. The entries are
  ## the walk's, but the per-trace warnings of headers not sampled (a
  ## fixed-length mismatch) are not made. When any sampled header disagrees,
  ## and for Rev 2 additional headers or trailer records, a trace count or
  ## file size that does not fit, `keys`, and every other file, the headers
  ## are walked. `vfFull` always walks them.
  openMapped(path, twosComplement8015, keys, false, demuxDir, progress, cache, verify)

proc openSeismicRw*(path: string): SeismicFile =
  ## **Internal** (`openEditor`; not exported by `parseSEG`). `openSeismic`
  ## mapped read-write. Raises `ValueError` for multiplexed SEG-D: edits
  ## would change only the demultiplexed copy.
  openMapped(path, false, false, true, "")

proc remapWritable*(f: var SeismicFile) =
  ## **Internal** (`openEditor(f)`; not exported by `parseSEG`). Maps `f.path`
  ## read-write in place of the file's read-only map and keeps its index.
  ## Raises `ValueError` for a closed file, a demultiplexed copy, or a file
  ## whose size changed since it was opened (its index would be stale);
  ## `f` is unchanged then. A prefetcher on `f` keeps the old map through its
  ## pin, and the index tables it reads stay parked there: the file gets
  ## copies of them.
  f.requireOpen()
  if f.demuxPath.len > 0:
    raise newException(ValueError, f.path & " holds multiplexed SEG-D, which cannot be " &
      "edited in place; convert it to a demultiplexed file first (`parseseg convert " &
      "--to=segd`, `convertSegdRevision`) and edit that")
  let m = MapRef(src: openMemFileSource(f.path, writable = true)) # unmapped on a raise
  if m.src.size != f.map.src.size:
    raise newException(ValueError, f.path & " changed size since it was opened (" &
      $f.map.src.size & " bytes, now " & $m.src.size & "); open it again")
  if f.map.pins > 0:
    # A prefetcher reads `entries` and `codecs` through raw pointers: the
    # payloads move to the map it keeps alive, the file keeps copies.
    f.map.parkedEntries = move f.index.entries
    f.map.parkedCodecs = move f.index.codecs
    f.index.entries = f.map.parkedEntries
    f.index.codecs = f.map.parkedCodecs
  f.map = m

proc close*(f: var SeismicFile) =
  ## Unmaps the file and deletes a demultiplexed copy (`demuxPath`). The
  ## index stays usable; range reads do not. A prefetcher still running on
  ## the file keeps the map until its own `close`. Idempotent.
  f.map = nil

func path*(f: SeismicFile): lent string {.inline.} =
  ## The file's path, as opened.
  f.path

func fromCache*(f: SeismicFile): bool {.inline.} =
  ## The index was read from the index cache given to `openSeismic`.
  f.cached

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

proc requireTrace*(f: SeismicFile, trace: int) {.inline.} =
  ## **Internal.** Raises `ValueError` for a trace out of range. Not
  ## exported by `parseSEG`.
  if trace notin 0 ..< f.len: raiseNoTrace(trace, f.len)

proc raiseNotKind(kind: SeismicKind) {.noinline, noreturn.} =
  raise newException(ValueError, "not a " & $kind & " file")

proc requireKind*(f: SeismicFile, kind: SeismicKind) {.inline.} =
  ## **Internal.** Raises `ValueError` "not a SEG-Y file" (etc.) when `f` is
  ## not of `kind`. Not exported by `parseSEG`.
  if f.kind != kind: raiseNotKind(kind)

func traceEntry*(f: SeismicFile, trace: int): TraceEntry =
  ## Where trace `trace` lives: header offset, header bytes, samples, record,
  ## channel set, scan type and channel type. Raises `ValueError` for a trace
  ## out of range.
  f.requireTrace(trace)
  f.index.entries[trace]

func hasKeys*(f: SeismicFile): bool {.inline.} =
  ## The index holds per-trace geometry (`openSeismic(keys = true)`).
  f.index.keys.len == f.index.entries.len

func traceKeys*(f: SeismicFile, trace: int): TraceKeys =
  ## A trace's geometry (NaN or 0 where unknown). Raises `ValueError` for a
  ## trace out of range or a file opened without `keys`.
  f.requireTrace(trace)
  if not f.hasKeys: raise newException(ValueError, "open the file with keys = true")
  f.index.keys[trace]

proc seg2Trace*(f: SeismicFile, trace: int): Seg2Trace =
  ## The SEG-2 Trace Descriptor Block of trace `trace` (fixed part and
  ## keyword strings), re-read from the map. Raises `ValueError` for a file
  ## that is not SEG-2 or is closed, or a trace out of range.
  f.requireKind(skSeg2)
  f.requireTrace(trace)
  f.requireOpen()
  var log: DiagLog # already reported by the index walk
  readSeg2Trace(f.map.src.memory.toOpenArray(0, int(f.map.src.size) - 1), f.index.seg2, trace,
    log, f.path)

func cardLines(text: string): string =
  # A text block as lines of `CardWidth` characters joined by '\n'.
  result = newStringOfCap(text.len + text.len div CardWidth)
  for i, c in text:
    if i > 0 and i mod CardWidth == 0: result.add '\n'
    result.add c


func textHeader*(f: SeismicFile): string =
  ## SEG-Y: the 3200-byte textual file header decoded (EBCDIC or ASCII, as
  ## detected) to 40 lines of 80 Latin-1 characters joined by '\n', with no
  ## trailing newline. Works on a closed file. Raises `ValueError` for a file
  ## that is not SEG-Y.
  f.requireKind(skSegy)
  cardLines(f.index.segy.text.text)

proc extendedTextHeaders*(f: SeismicFile): seq[string] =
  ## SEG-Y Rev 1+: each extended textual header record after the binary
  ## header, decoded in its own detected character set, as 40 lines of 80
  ## characters joined by '\n' (the stanzas parsed from them are in
  ## `f.index.segy.extended`). Empty when there are none. Records of binary
  ## stanzas come out as their bytes in Latin-1. Raises `ValueError` for a
  ## file that is not SEG-Y, or a closed one when the records were too large
  ## to keep in memory.
  f.requireKind(skSegy)
  template ext: untyped = f.index.segy.extended
  let n = ext.recordCount
  let start = int64(f.index.segy.tapeLabel.len + TextHeaderSize + BinaryHeaderSize)
  if not ext.isComplete and n > 0:
    f.requireOpen()
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
  f.requireOpen()
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

# ------------------------------------------------------- keys on demand --

type
  KeyReader = object
    # Per-call state of `traceKeysInto`: buffers reused across traces.
    gr: GeometryReader
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
    if e.offset < 0 or e.offset + max(hb, TraceHeaderSize) > size: raiseOutside(trace)
    # Straight from the mapped bytes: nothing decoded or copied.
    let extra = hb - 2 * TraceHeaderSize
    segyKeys(r.gr, RawHeaders(std: cast[ByteBuf](addr mem[a]),
      ext1: if hb >= 2 * TraceHeaderSize: cast[ByteBuf](addr mem[a + TraceHeaderSize]) else: nil,
      prop: if extra > 0: cast[ByteBuf](addr mem[a + 2 * TraceHeaderSize]) else: nil,
      propLen: max(extra, 0)))
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
    f.requireOpen()
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
    f.requireTrace(i)
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
    let st = tryDecodeEntry(mem, size, e, f.index.codecs[e.record], p, cols, first)
    if st != dsOk:
      for c in 0..<cols: p[c] = T(0)
      log.report(sevError, if st == dsTruncated: dcTruncated else: dcUnsupportedFormat,
        decodeMessages[st], e.offset, Location(file: f.path,
          record: if f.index.kind == skSeg2: 0 else: int(e.record), trace: i))
      inc failed
  failed

proc checkReadable(f: SeismicFile, count: int) =
  if count > 0: f.requireOpen()
  if not f.index.contiguous:
    raise newException(ValueError, "range reads need a plain disk file")

proc checkSelection(f: SeismicFile, traces: Slice[int]) {.inline.} =
  checkSpan(traces, f.len)

proc checkSelection(f: SeismicFile, traces: openArray[int]) =
  for i in traces:
    f.requireTrace(i)

proc checkRows[T](dst: Tensor[T], row, count: int) =
  if not (dst.rank == 2 and dst.is_C_contiguous and row >= 0 and row + count <= dst.shape[0]):
    raise newException(ValueError,
      "need a row-major [traces, samples] tensor with room for the traces")

proc advise(f: SeismicFile, traces: Slice[int], cols, first: int) {.inline.} =
  # Read-ahead advice for a checked range (see `adviseTraces`).
  if traces.b - traces.a >= 0:
    adviseTraces(f.unsafeMemory, f.mappedSize,
      cast[ptr UncheckedArray[TraceEntry]](addr f.index.entries[0]),
      cast[ptr UncheckedArray[TraceCodec]](addr f.index.codecs[0]),
      nil, traces.a, traces.b + 1, cols, first)

proc advise(f: SeismicFile, traces: openArray[int], cols, first: int) {.inline.} =
  # Read-ahead advice for a checked selection (see `adviseTraces`).
  if traces.len > 0:
    adviseTraces(f.unsafeMemory, f.mappedSize,
      cast[ptr UncheckedArray[TraceEntry]](addr f.index.entries[0]),
      cast[ptr UncheckedArray[TraceCodec]](addr f.index.codecs[0]),
      cast[ptr UncheckedArray[int]](addr traces[0]), 0, traces.len, cols, first)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], dst: var Tensor[T],
    row = 0, log: var DiagLog): int =
  ## Decodes `traces` into rows `row ..< row + traces.len` of `dst` (a
  ## row-major `[rows, samples]` tensor), each truncated or zero-padded to
  ## `dst.shape[1]`. A trace that cannot be decoded is left zero, logged in
  ## `log`, and counted in the result. Raises `ValueError` for traces outside
  ## the file (an empty range must still start in `0 .. f.len`), a closed
  ## file or a tensor without room. A large or scattered read whose pages
  ## are not in memory first asks the OS to read them all ahead (POSIX
  ## `madvise(MADV_WILLNEED)`), so a cold gather waits for the disk once
  ## rather than once per trace.
  let count = traces.spanLen
  f.checkReadable(count)
  f.checkSelection(traces)
  dst.checkRows(row, count)
  f.advise(traces, dst.shape[1], 0)
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
  f.advise(traces, dst.shape[1], 0)
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
  f.advise(traces, dst.shape[1], samples.a)
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
  f.advise(traces, dst.shape[1], samples.a)
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
  ix.joined = true
  for k in ix.keys.mitems:
    if k.applyGeometry(g, overwrite): inc result

# ------------------------------------------------------------ index cache --
# A file holding a `TraceIndex` exactly as the walk made it:
#
#   (.nif27)
#   (.vendor "parseSEG")
#   (indexcache
#    (version 1) (library "0.5.0") (schema "<hex>") (endian littleEndian)
#    (path "<absolute path>") (size <bytes>) (mtime <s> <ns>)
#    (head "<hex>") (tail "<hex>") (twosComplement8015 0) (keys 1))
#   NUL, zero bytes to an 8-byte boundary,
#   the index as a `binstore` snapshot (entries and keys as single blocks),
#   the snapshot's length and checksum (2 x uint64, native order).
#
# One field per header line; a cache is valid when its header is the one
# the file would get now. `schema` changes with any stored type, `library`
# with every release, `version` with this layout.

const
  IndexCacheVersion = 1
  StampSpan = 64 shl 10 ## Bytes hashed at each end of the file.
  HeaderLimit = 64 shl 10 ## Longest cache header read.

proc spanSums(f: SeismicFile): (uint64, uint64) =
  # Checksums of the first and the last `StampSpan` bytes of the map.
  let size = f.mappedSize
  let mem = f.unsafeMemory
  let n = int(min(size, StampSpan))
  if n == 0: return (checksum(nil, 0), checksum(nil, 0))
  (checksum(mem, n), checksum(cast[ptr UncheckedArray[byte]](addr mem[size - n]), n))

proc cacheHeader(f: SeismicFile, keys: bool): string =
  const schema = schemaOf(TraceIndex)
  let (head, tail) = f.spanSums
  "(.nif27)\n(.vendor \"parseSEG\")\n(indexcache\n" &
    " (version " & $IndexCacheVersion & ")\n" &
    " (library " & nifString(PackageVersion) & ")\n" &
    " (schema \"" & toHex(checksum(cast[ptr UncheckedArray[byte]](schema.cstring),
      schema.len)) & "\")\n" &
    " (endian " & $cpuEndian & ")\n" &
    " (path " & nifString(absolutePath(f.path)) & ")\n" &
    " (size " & $f.stamp.size & ")\n" &
    " (mtime " & $f.stamp.mtime & " " & $f.stamp.mtimeNs & ")\n" &
    " (head \"" & toHex(head) & "\")\n" &
    " (tail \"" & toHex(tail) & "\")\n" &
    " (twosComplement8015 " & $ord(f.twos) & ")\n" &
    " (keys " & $ord(keys) & "))\n"

proc headerMismatch(stored: string, f: SeismicFile, keys: bool): string =
  # "" when `stored` fits the file as opened; else why not.
  let want = f.cacheHeader(keys)
  if stored == want or (not keys and stored == f.cacheHeader(true)): return ""
  let a = stored.splitLines
  let b = want.splitLines
  var tag = ""
  for i in 0 ..< max(a.len, b.len):
    if tag.len == 0 and (i >= a.len or i >= b.len or a[i] != b[i]):
      let line = if i < b.len: b[i] else: a[i]
      tag = line.strip.strip(chars = {'('}).split(' ')[0]
  case tag
  of "version", "library", "schema", "endian": "it was saved by another version of parseSEG"
  of "path": "it was saved for another file"
  of "size", "mtime", "head", "tail": "the file changed since it was saved"
  of "twosComplement8015": "it was saved with another twosComplement8015"
  of "keys": "it was saved without trace keys"
  else: "its header is not an index cache header"

func sampled(ix: TraceIndex): bool =
  # The index was computed from the file size (`vfSampled`).
  for d in ix.log:
    if d.code == dcIndexSampled: return true

proc loadIndex(f: var SeismicFile, cache: string, keys: bool, verify: VerifyMode): string
    {.raises: [].} =
  # Reads `f.index` from the cache `cache`: "" when done, else why not
  # (then `f.index` is unchanged).
  if not fileExists(cache): return "there is no such file"
  var m: MemFileSource
  try:
    m = openMemFileSource(cache)
    let size = m.size
    let mem = m.memory
    var nul = -1
    for i in 0 ..< int(min(size, HeaderLimit)):
      if nul < 0 and mem[i] == 0: nul = i
    if nul < 0: return "it has no header"
    var stored = newString(nul)
    copyMem(addr stored[0], mem, nul)
    result = headerMismatch(stored, f, keys)
    if result.len == 0:
      let start = (nul + 8) and not 7
      var trailer: array[2, uint64]
      if size < start + 16: return "it is truncated"
      copyMem(addr trailer, addr mem[size - 16], 16)
      # Compared as uint64 first: a damaged trailer may not fit an int64.
      if trailer[0] > uint64(size): return "it is truncated"
      let n = int64(trailer[0])
      if start + n + 16 != size: return "it is truncated"
      let payload = cast[ptr UncheckedArray[byte]](addr mem[start])
      if checksum(payload, int(n)) != trailer[1]: return "it is corrupt (checksum)"
      var r = initBinReader(payload, int(n))
      var ix: TraceIndex
      for name, v in fieldPairs(ix):
        when name == "keys":
          if keys: r.get v
          else: r.skipSeq(TraceKeys)
        else:
          r.get v
      if not r.atEnd: return "its contents do not fit its layout"
      if verify == vfFull and ix.sampled:
        return "it was saved from a sampled open, and verify = vfFull reads every header"
      f.index = move ix
  except CatchableError as e:
    result = "it cannot be read: " & e.msg
  finally:
    if m != nil:
      try: m.close()
      except CatchableError: discard

proc saveIndex*(f: SeismicFile, path: string) =
  ## Writes `f`'s index to the index cache `path`, for `openSeismic(...,
  ## cache = path)` to read back instead of walking the file again: a
  ## viewer's second open of a large file is then about as fast as reading
  ## the cache. The cache holds everything the walk found (entries, codecs,
  ## file and record headers, the walk's diagnostics, keys when the file
  ## was opened with them), about 24 bytes per trace (plus 144 with keys),
  ## and stamps of the file (see `openSeismic`). Written through a new
  ## temporary file next to `path` and renamed when complete.
  ##
  ## Raises `ValueError` for a closed or unrecognized file, a demultiplexed
  ## copy (`demuxPath`), keys changed by `applyGeometry`/`applySurvey` (the
  ## cache holds the file's own index), a file that changed since it was
  ## opened, or `path` naming the file itself; `IOError`/`OSError` if the
  ## cache cannot be written.
  f.requireOpen()
  if not f.index.detected:
    raise newException(ValueError, f.path & " is not a SEG-Y, SEG-D or SEG-2 file")
  if f.demuxPath.len > 0:
    raise newException(ValueError, f.path & " was indexed through a demultiplexed copy, " &
      "which is not cached")
  if f.index.joined:
    raise newException(ValueError, "the trace keys were changed by applyGeometry or " &
      "applySurvey; save the index before joining geometry")
  if path == f.path or (fileExists(path) and sameFile(path, f.path)):
    raise newException(ValueError, "the index cache " & path & " is the seismic file itself")
  if stampOf(f.path) != f.stamp:
    raise newException(ValueError, f.path & " changed since it was opened; open it again")
  var log: DiagLog # the walk's diagnostics, not later ones (a cache miss)
  for i in 0 ..< min(f.walkLog, f.index.log.len): log.add f.index.log[i]
  let head = f.cacheHeader(f.hasKeys)
  let tmp = createTempFor(path)
  try:
    var o: File
    if not open(o, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
    var n: int64
    try:
      o.write head
      var pad = newString(((head.len + 8) and not 7) - head.len) # NUL, then zeros
      o.write pad
      var w = initBinWriter(o)
      for name, v in fieldPairs(f.index):
        when name == "log": w.put log
        else: w.put v
      w.flush()
      n = w.written
    finally:
      o.close()
    let m = openMemFileSource(tmp)
    var trailer = [uint64(n), 0'u64]
    try:
      let start = int64((head.len + 8) and not 7)
      if m.size != start + n: raise newException(IOError, "cannot write " & tmp)
      if n > 0: trailer[1] = checksum(cast[ptr UncheckedArray[byte]](addr m.memory[start]), int(n))
      else: trailer[1] = checksum(nil, 0)
    finally:
      m.close()
    if not open(o, tmp, fmAppend): raise newException(IOError, "cannot write " & tmp)
    try:
      if o.writeBuffer(addr trailer, 16) != 16: raise newException(IOError, "cannot write " & tmp)
    finally:
      o.close()
    moveFile(tmp, path)
  except CatchableError:
    discard tryRemoveFile(tmp)
    raise
