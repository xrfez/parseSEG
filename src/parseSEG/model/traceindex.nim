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
## `buildIndex` (`indexwalk`, re-exported here) walks any `RecordSource`
## (disk, tape image, tape device) with the readers' `headersOnly` mode. Each
## trace costs one 24-byte `TraceEntry`, so 10 million traces take 240 MB, and
## 184 bytes of `TraceKeys` with `keys`. The index cache format (`saveIndex`)
## is in `private/indexcache`.
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

import std/[algorithm, math, os, times, locks]
import ../common/[errors, diagnostics, endians, seismickind, progress, tensors]
import ../io/[records, memsource]
import ../segy/[reader as segyreader, fields]
import ../vendor/[maps, apply]
import ../segd/[reader as segdreader, demux]
import ../seg2/[reader as seg2reader]
import ./[keys, indextypes, indexwalk]
import ../segy/samples as segysamples, ../segd/samples as segdsamples,
  ../seg2/samples as seg2samples
import ../private/[checks, decodeentry, progressticker, tensorrows, segykeys, indexcache,
  mapguard, readcache]

export memsource, diagnostics, keys, seismickind, progress, tensors, indextypes, indexwalk

# ---------------------------------------------------------- seismic file --

type
  MapOwner {.acyclic.} = object
    ## Owns a file's mapping: unmaps when the last reference goes. The
    ## `SeismicFile` holds one until `close`; each running `Prefetcher` holds
    ## one too (a `MapPin`), so closing the file while a prefetcher still
    ## decodes defers the unmap to the prefetcher's `close`.
    src: MemFileSource
    tempPath: string ## A demultiplexed copy to delete with the map ("" if none).
    pins: int        ## Live `MapPin`s (prefetchers); read and changed under `mapLock`.
    parkedEntries: seq[TraceEntry]
      ## The index tables of a file destroyed while pinned: the prefetchers
      ## read them through raw pointers, so they live as long as the map.
    parkedCodecs: seq[TraceCodec]
    parkedKeys: seq[TraceKeys] ## As `parkedEntries`: prefetch chunks' `TraceRows` read them.

  MapRef = ref MapOwner

var deferredClose {.threadvar.}: tuple[active: bool, src: MemFileSource, temp: string]
  # The map of the last `MapRef` this thread dropped under `mapLock`, closed
  # (unmapped, its descriptor closed, a demultiplexed copy deleted) once the
  # lock is released (`unlockMaps`): close(2) can block on a network share
  # (NFS writes back an edited file's pages, SMB waits for the server), and
  # every other file's pins and drops wait for the lock meanwhile.

proc closeMap(src: MemFileSource, temp: string) {.raises: [].} =
  # A destructor must not raise; the base methods raise [CatchableError].
  if src != nil:
    try: src.close()
    except CatchableError: discard
  if temp.len > 0: discard tryRemoveFile(temp)

proc `=destroy`(m: MapOwner) =
  if deferredClose.active and deferredClose.src == nil and m.src != nil:
    deferredClose.src = m.src # under `mapLock`: closed after it
    deferredClose.temp = m.tempPath
  else:
    closeMap(m.src, m.tempPath)
  `=destroy`(m.src)
  `=destroy`(m.tempPath)
  `=destroy`(m.parkedEntries)
  `=destroy`(m.parkedCodecs)
  `=destroy`(m.parkedKeys)

proc `=copy`(dst: var MapOwner, src: MapOwner) {.error.}
proc `=dup`(src: MapOwner): MapOwner {.error.}

var mapLock: Lock
  # Guards every map's pin count and every copy or drop of a `MapRef` that
  # another thread may also hold: prefetchers of one file are made and
  # closed on different threads (a background job beside the UI's
  # read-ahead), and neither `pins` nor ORC's reference counts are atomic.
  # One lock for all files: it is held for a few instructions, except by
  # the last holder of a map, which unmaps the file under it.
initLock(mapLock)

template lockMaps() =
  # `mapLock`, around a drop that may be a map's last: its close waits for `unlockMaps`.
  acquire(mapLock)
  deferredClose.active = true

template unlockMaps() =
  deferredClose.active = false
  release(mapLock)
  if deferredClose.src != nil or deferredClose.temp.len > 0:
    closeMap(move deferredClose.src, move deferredClose.temp)

type
  MapPin* = object
    ## **Internal** (the prefetcher). Keeps a file's map alive, and the
    ## file's index tables if the file is destroyed first. Not copyable.
    m: MapRef

proc `=destroy`*(p: MapPin) =
  # Exported: `Prefetcher`'s destructor (another module) destroys its pin
  # explicitly, and only a visible hook binds to a non-`var` field there.
  if p.m != nil:
    lockMaps()
    dec p.m.pins
    `=destroy`(p.m)
    unlockMaps()

proc `=copy`(dst: var MapPin, src: MapPin) {.error.}
proc `=dup`(src: MapPin): MapPin {.error.}

type
  SeismicFile* = object
    ## An open file with its trace index: a disk file (mapped or unmapped) or
    ## bytes in memory (`openSeismicBytes`).
    idx: TraceIndex ## See `index`.
    gr: GeometryReader
      ## SEG-Y: the file's layout resolved for the keys, once, when the index
      ## is made (resolving it took 9 µs and 100 allocations per
      ## `traceKeysInto` or `startTimeMs` call). Read-only after that, so any
      ## number of threads may read keys. A call checks that it still fits
      ## `index.segy` (`planFits`) and resolves its own otherwise.
    path: string      ## See `path`.
    demuxPath: string ## See `demuxPath`.
    map: MapRef       ## nil once closed.
    stamp: FileStamp  ## The file as opened, for `saveIndex`.
    memId: int        ## See `inMemory`: 0 for a disk file, else unique to the open.
    walkLog: int      ## Entries of `index.log` the walk (or the cache) made.
    twos: bool        ## Opened with `twosComplement8015`.
    cached: bool      ## See `fromCache`.

func index*(f: SeismicFile): lent TraceIndex {.inline.} =
  ## The file's trace index, read-only: the entries, keys, the standard's
  ## own headers (`f.index.segy`, `f.index.segdRecords`, `f.index.seg2`)
  ## and the log. Change it through the procs that take the file
  ## (`applySurvey`, `applyGeometry`, `ensureKeys`, the header editor), which
  ## keep the keys, the revision and the layout plan in step.
  f.idx

proc mindex*(f: var SeismicFile): var TraceIndex {.inline.} =
  ## The index, mutable, for parseSEG's own modules; `import parseSEG` does
  ## not export it. A change through it bypasses the file's bookkeeping.
  f.idx

proc `=destroy`(f: SeismicFile) =
  # `f` is passed by reference and this is its last use, so its fields may
  # be moved out (and `TraceIndex` has only the generic `var` destructor).
  let pf = addr f
  if f.map != nil:
    lockMaps()
    if f.map.pins > 0:
      # A prefetcher still reads `entries` and `codecs` through raw pointers:
      # hand them to the map it keeps alive. A seq move keeps the payload's
      # address, so nothing is copied and the pointers stay valid.
      f.map.parkedEntries = move pf[].idx.entries
      f.map.parkedCodecs = move pf[].idx.codecs
      f.map.parkedKeys = move pf[].idx.keys
    `=destroy`(f.map)
    unlockMaps()
  `=destroy`(pf[].idx)
  `=destroy`(pf[].gr)
  `=destroy`(f.path)
  `=destroy`(f.demuxPath)

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

proc raiseCut(f: SeismicFile) {.noinline, noreturn.} =
  let left = f.map.src.readable
  let what = if f.map.src.readFailed:
      " could not be read past byte " & $left & " (an I/O error: a network share or " &
        "disk that failed; " & $f.map.src.size & " bytes mapped)"
    else:
      " was cut short while it was open (" & $f.map.src.size & " bytes mapped, " & $left &
        " left)"
  raise (ref SegTruncatedError)(msg: f.path & what & "; open it again", offset: left)

func cutSeen*(f: SeismicFile): bool {.inline.} =
  ## **Internal.** The file was found cut short while mapped (a read reached
  ## a page past its new end, or `cutShort` saw it). No system call; not
  ## exported by `parseSEG`.
  f.mapped and f.map.src.readable < f.map.src.size

proc requireUncut*(f: SeismicFile) {.inline.} =
  ## **Internal.** Raises `SegTruncatedError` when the file was found cut
  ## short while mapped (`cutSeen`). Calls that read headers, keys or raw
  ## bytes from the map call it after the read (a cut known before is known
  ## then too; long calls also call it before). Not exported by `parseSEG`.
  if f.cutSeen: f.raiseCut()

template requireUncutFirst*(f: SeismicFile) =
  ## **Internal.** `requireUncut` before a call reads the map, where a read
  ## past a cut would fault: built without the guard (`-d:parseSegNoMapGuard`),
  ## a call that reads headers, keys or bytes once a cut is known raises
  ## before it reads. With the guard nothing: the check after the read finds
  ## it (a check before as well cost 20 instructions a call, 18.1). Not
  ## exported by `parseSEG`.
  when not mapsGuarded: requireUncut(f)

proc unsafeCache*(f: SeismicFile): ptr ReadCache {.inline.} =
  ## **Internal.** An unmapped file's read cache (nil when mapped or closed):
  ## raw readers hold what they read in it. Not exported by `parseSEG`.
  if f.mapped: f.map.src.readCache else: nil

proc access*(f: SeismicFile): FileAccess {.inline.} =
  ## How the file's bytes are reached: `faMapped` or `faUnmapped`
  ## (`OpenOptions.access`, with `faAuto` resolved when it was opened);
  ## `faMapped` also for a file opened from bytes (`openSeismicBytes`: its
  ## bytes are reached in place; `inMemory` tells them apart). `faAuto` for
  ## a closed file.
  if f.mapped: f.map.src.access else: faAuto

proc raiseReadFailed(f: SeismicFile, a: int64) {.noinline, noreturn.} =
  raise newException(IOError, f.path & " could not be read at byte " & $a & " (" &
    f.unsafeCache.errorText & "); try again")

proc holdBytes*(f: SeismicFile, h: var Hold, a, b: int64) {.inline.} =
  ## **Internal.** Unmapped: holds bytes `a ..< b` of the file in `h` before
  ## a call reads them (what `h` held before is released); raises `IOError`
  ## when they cannot be read (an I/O error: a network share that failed;
  ## a later call tries again). A cut it finds is the file's cut, as a read
  ## of a map finds it (`requireUncut` after the read). Mapped: nothing. Not
  ## exported by `parseSEG`.
  let c = f.unsafeCache
  if c != nil and c.hold(a, b, h) == rsFailed and not c.holds(a, b): f.raiseReadFailed(a)

template withHeld*(f: SeismicFile, a, b: int64, body: untyped) =
  ## **Internal.** Runs `body` with bytes `a ..< b` held (unmapped, see
  ## `holdBytes`); on a mapped file `body` alone, with no hold to make or
  ## drop (a hold on every call cost 40 instructions a `traceField`). Not
  ## exported by `parseSEG`.
  if f.unsafeCache == nil:
    body
  else:
    var held: Hold
    f.holdBytes(held, a, b)
    body

proc coverBytes*(f: SeismicFile, cur: var Cursor, a, b: int64) {.inline.} =
  ## **Internal.** `holdBytes` for a call that reads forward through the
  ## file (header loops): `cur` keeps a window held from one read to the
  ## next. Not exported by `parseSEG`.
  let c = f.unsafeCache
  if c != nil and c.cover(cur, a, b) == rsFailed and not c.holds(a, b): f.raiseReadFailed(a)

proc coverSeg2Block*(f: SeismicFile, cur: var Cursor, p: int64) =
  ## **Internal.** Unmapped: holds the SEG-2 descriptor block at `p` in
  ## `cur`: its fixed part, then the size that gives. Mapped: nothing. Not
  ## exported by `parseSEG`.
  if f.unsafeCache == nil or p < 0 or p >= f.map.src.size: return
  f.coverBytes(cur, p, p + Seg2FixedSize)
  if p + 4 <= f.map.src.size:
    let a = int(p)
    let bs = getNum[uint16](f.map.src.memory.toOpenArray(a, a + 3), 2, f.idx.seg2.order)
    f.coverBytes(cur, p, p + max(int64(bs), int64(Seg2FixedSize)))

proc seg2FileBlockEnd*(f: SeismicFile): int64 =
  ## **Internal.** SEG-2: where the File Descriptor Block ends at the latest
  ## (its strings run up to the first trace block, or to the end of the
  ## file): what `fileBlockSize` reads. Not exported by `parseSEG`.
  let first = Seg2FixedSize + int64(f.idx.seg2.pointerBytes)
  result = if f.mapped: f.map.src.size else: 0
  for p in f.idx.seg2.pointers:
    if int64(p) >= first and int64(p) < result: result = int64(p)

proc coverHeaders*(f: SeismicFile, cur: var Cursor, trace: int) {.inline.} =
  ## **Internal.** Unmapped: holds trace `trace`'s header bytes in `cur`
  ## before a call reads them (SEG-2: its descriptor block). Mapped: nothing.
  ## Not exported by `parseSEG`.
  if f.unsafeCache == nil: return
  let e = f.idx.entries[trace]
  case f.idx.kind
  of skSeg2: f.coverSeg2Block(cur, e.offset)
  of skSegy: f.coverBytes(cur, e.offset, e.offset + max(int64(e.headerBytes), TraceHeaderSize))
  of skSegd:
    f.coverBytes(cur, e.offset, e.offset + max(int64(e.headerBytes), SegdTraceHeaderSize))
  of skUnknown: discard

proc cutShort*(f: SeismicFile): bool =
  ## The file was cut short by another program since it was opened: an
  ## earlier read found it so, or this call does (it asks the OS for the
  ## file's size, about 0.5 µs). From then on, sample reads fail the traces
  ## past the cut (zero rows, `dcTruncated`) and calls that read headers,
  ## keys or raw bytes from the file raise `SegTruncatedError`: close it and
  ## open it again. False for a closed file, and on Windows, where a mapped
  ## file cannot be cut. Also true when a read of the file failed with an
  ## I/O error, its size unchanged (a network share that went away):
  ## `readFailed` tells the two apart.
  f.mapped and f.map.src.cutShort

proc readFailed*(f: SeismicFile): bool =
  ## The file stopped being readable at `cutShort` because a read of it
  ## failed (an I/O error: a network share or disk that failed), not because
  ## another program cut it: its size was unchanged then. Reads past that
  ## point fail as for a cut (rows with `dcIo`, `SegTruncatedError` from
  ## header calls) until the file is opened again. No system call.
  f.mapped and f.map.src.readFailed

proc pinMap*(f: SeismicFile): MapPin =
  ## **Internal.** A pin on `f`'s map (an empty pin for a closed file). Any
  ## thread may pin a file and drop its pin while others do the same.
  if f.map != nil:
    acquire(mapLock)
    inc f.map.pins
    result = MapPin(m: f.map)
    release(mapLock)

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
    progress: Progress, access: FileAccess) =
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
  f.map.src = openMemFileSource(tmp, access = access) # where `dir` lies, for `faAuto`
  f.demuxPath = tmp
  f.idx = buildIndex(f.map.src, skSegd, twosComplement8015, keys, progress)
  f.map.src.endWalk()
  log.add f.idx.log
  f.idx.log = log

proc loadIndex(f: var SeismicFile, cache: string, keys: bool, verify: VerifyMode): string
  {.raises: [].}

proc resolveLayout(f: var SeismicFile) =
  # The SEG-Y layout plan of the index just made (see `gr`).
  if f.idx.kind == skSegy and f.idx.detected: f.gr = initGeometryReader(f.idx.segy)

proc requireWholeOpen(f: SeismicFile) =
  # The end of an open: a file cut short while it was walked (the walk read
  # zeros past the cut, or stopped there) gives no index. Asks the OS once.
  # Unmapped, a read of the walk that failed (logged fatal by its reader)
  # raises: the next open tries again.
  if f.mapped and f.map.src.walkError.len > 0:
    raise newException(IOError, f.map.src.walkError & " (while it was opened)")
  if f.mapped and f.map.src.cutShort:
    if f.map.src.readFailed:
      raise newException(IOError, f.path & " could not be read past byte " &
        $f.map.src.readable & " while it was opened (an I/O error: a network share or " &
        "disk that failed); open it again")
    raise newException(IOError, f.path & " was cut short while it was opened (" &
      $f.map.src.size & " bytes mapped, " & $f.map.src.readable & " left); open it again " &
      "once it stops changing")

var memoryOpens: int # opens of files in memory, for `SeismicFile.memId`; under `mapLock`

proc openSource(src: MemFileSource, path: string, twosComplement8015, keys, writable: bool,
    demuxDir: string, progress: Progress, cache: string, verify: VerifyMode,
    forced: SeismicKind, access: FileAccess, vendors: VendorRegistry): SeismicFile =
  # What `openSeismic`, `openSeismicRw` and `openSeismicBytes` share, once
  # `src` is open. Built in a local, so a raise (a cancelled walk) unmaps
  # the file. The source is opened before the map ref is made: a `MapRef`
  # under construction is not freed when an argument of its constructor
  # raises (96 bytes per failed open).
  let memory = src.isMemory
  var f = SeismicFile(path: path, map: MapRef(src: src), twos: twosComplement8015)
  if memory:
    acquire(mapLock)
    inc memoryOpens
    f.memId = memoryOpens
    release(mapLock)
  else:
    f.stamp = stampOf(path)
  var why = ""
  if memory and cache.len > 0:
    why = "a file in memory has no index cache"
  elif cache.len > 0:
    why = f.loadIndex(cache, keys, verify)
    if why.len == 0 and vendors.maps.len > 0 and f.idx.kind == skSegy and
        vendors.vendorLayout(vendorContext(f.idx.segy)).len > 0:
      # A map's layout applies: the cached keys were read without it.
      why = "a vendor map has a layout for this file, which the cached keys were read without"
      f.idx = TraceIndex()
    if why.len == 0 and forced != skUnknown and f.idx.kind != forced:
      # The cache was saved from another reading of the file than the one
      # the caller names (`OpenOptions.kind`).
      why = "it holds the index of another standard than the one asked for"
      f.idx = TraceIndex()
    if why.len == 0:
      f.cached = true
      f.walkLog = f.idx.log.len
      f.resolveLayout()
      var tk = initProgressTicker(progress, f.map.src.size)
      if not tk.finish(): raiseCancelled()
      f.requireWholeOpen()
      return f
  let n = int(min(f.map.src.size, 8192))
  var kind = forced # `OpenOptions.kind`: the caller knows the standard
  if kind == skUnknown and n > 0:
    var h: Hold
    f.holdBytes(h, 0, n)
    kind = detectKind(f.map.src.memory.toOpenArray(0, n - 1))
  if kind != skUnknown:
    f.idx = buildIndex(f.map.src, kind, twosComplement8015, keys, progress, verify, vendors)
    f.map.src.endWalk()
    if kind == skSegd and f.idx.multiplexed:
      if memory:
        raise newException(ValueError, path & " holds multiplexed SEG-D, which a file in " &
          "memory cannot demultiplex (that needs a temporary file); convert it to a " &
          "demultiplexed file first (`parseseg convert --to=segd`, `convertSegdRevision`)")
      if writable:
        raise newException(ValueError, path & " holds multiplexed SEG-D, which cannot be " &
          "edited in place; convert it to a demultiplexed file first (`parseseg convert " &
          "--to=segd`, `convertSegdRevision`) and edit that")
      f.openDemultiplexed(twosComplement8015, keys, demuxDir, progress, access)
  else:
    f.idx.contiguous = true
    f.idx.log.report(sevFatal, dcUnsupportedFormat,
      "not a SEG-Y, SEG-D or SEG-2 file", 0, Location(file: path))
  f.walkLog = f.idx.log.len
  f.resolveLayout()
  if cache.len > 0:
    f.idx.log.report(sevInfo, dcIndexCache, "the index cache " & cache & " was not used (" &
      why & "); the file was indexed", 0, Location(file: path))
  f.requireWholeOpen()
  f

proc openMapped(path: string, twosComplement8015, keys, writable: bool,
    demuxDir: string, progress: Progress = nil, cache = "", verify = vfSampled,
    forced = skUnknown, access = DefaultAccess, vendors = VendorRegistry()): SeismicFile =
  # `openSeismic` / `openSeismicRw`.
  let src = openMemFileSource(path, writable, access = access)
  openSource(src, path, twosComplement8015, keys, writable, demuxDir, progress, cache, verify,
    forced, access, vendors)

proc openSeismic*(path: string, keys = false, progress: Progress = nil,
    opts = OpenOptions()): SeismicFile =
  ## Maps the disk file `path` read-only, detects SEG-Y, SEG-D or SEG-2, and
  ## builds the trace index (with per-trace geometry when `keys`). Format
  ## problems are in `index.log`; an undetectable file gives a fatal
  ## diagnostic and an empty index. Raises `IOError`/`OSError` if the file
  ## cannot be opened or mapped. To change headers in place, use
  ## `openEditor` (`model/edit`).
  ##
  ## `progress` is called about every MiB of the index walk with the bytes
  ## walked and the file's size, and once at the end (a multiplexed file:
  ## of the demultiplexed copy's walk). When it returns false the walk stops
  ## and `SegCancelledError` is raised; the file is unmapped.
  ##
  ## `opts` holds the rarely changed settings (`OpenOptions`):
  ##
  ## `verify` (`vfSampled` by default): a fixed-length SEG-Y file (Rev 1 or
  ## later, binary bytes 3503-3504 = 1) is indexed from its size, without
  ## walking the trace headers: 10 M traces in milliseconds, and only the
  ## pages of the sampled headers are read. Up to 64 headers, the first, the
  ## last and the rest spread between, must have the binary header's sample
  ## count and interval; the log then has an info
  ## diagnostic (`dcIndexSampled`) with the number checked. The entries are
  ## the walk's, but the per-trace warnings of headers not sampled (a
  ## fixed-length mismatch) are not made. With `keys`, the keys are then
  ## read from every trace header in one pass over the map: the same keys as
  ## the walk makes (the same header bytes), again without the walk's
  ## per-trace warnings, and `progress` reports that pass. When any sampled
  ## header disagrees, and for Rev 2 additional headers or trailer records,
  ## a trace count or file size that does not fit, and every other file, the
  ## headers are walked. `vfFull` always walks them.
  ##
  ## `cache` names an index cache that `saveIndex` wrote: when it was saved
  ## for this file as it is now (path, size, modification time, its first
  ## and last 64 KiB, the same `twosComplement8015`, keys when asked for)
  ## by this version of parseSEG, and is intact, the index is read from it
  ## instead of walking the file (`fromCache`). Otherwise the file is
  ## indexed as without `cache`, with an info diagnostic (`dcIndexCache`)
  ## saying why; the cache is never written here. A cache saved from a
  ## sampled open is not used with `verify = vfFull`.
  ##
  ## A SEG-D file with multiplexed records is demultiplexed once into a
  ## temporary copy in `demuxDir` (default: the OS temp directory), which is
  ## mapped and indexed instead (`demuxPath`, a warning in `log`) and deleted
  ## on `close`; the file itself is never changed.
  ##
  ## `twosComplement8015` also reads SEG-2 format-3 mantissas as two's
  ## complement.
  openMapped(path, opts.twosComplement8015, keys, false, opts.demuxDir, progress, opts.cache,
    opts.verify, opts.kind, opts.access, opts.vendors)

proc openSeismicBytes*(bytes: sink seq[byte], name: string, keys = false,
    progress: Progress = nil, opts = OpenOptions()): SeismicFile =
  ## Opens a SEG-Y, SEG-D or SEG-2 file that lives in memory: `bytes`, the
  ## whole file, which the result takes over: moved in, with no copy, when this
  ## call is the argument's last use or it is passed with `move` (the caller's
  ## `seq` is then empty); a `seq` used again later is copied, as Nim does for any
  ## `sink` parameter. Everything after the open is as for
  ## `openSeismic`, from `bytes`: detection, the index, headers, keys, sample
  ## reads, gathers, summaries, and reads from any number of threads. `name`
  ## is a display name, or a virtual path, for messages and diagnostics and
  ## for `path`: it need not exist and is never looked at on disk. Give
  ## files that are written side by side different names, for the messages'
  ## sake.
  ##
  ## `opts` is as for `openSeismic`, except that `access` has no effect (the
  ## file is reached in place, `faMapped`) and `cache` is not used: the index is always walked,
  ## with an info diagnostic (`dcIndexCache`) saying so, and nothing is read
  ## from disk. What needs a disk file is refused in plain words, with
  ## `ValueError`: `saveIndex`, `openEditor(f)` (edits go to a disk file) and
  ## a multiplexed SEG-D file, which `openSeismic` demultiplexes through a
  ## temporary file (convert it to a demultiplexed file first). Bytes that
  ## are no seismic file, or a truncated one, give the library's usual
  ## diagnostics and errors, never a crash. Empty `bytes` give an
  ## unrecognized file with a fatal diagnostic.
  ##
  ## The bytes live until `close` (a running prefetcher keeps them until its
  ## own `close`); no other copy of them is made. A borrowed view of the
  ## caller's memory is not offered: a prefetcher outlives `close`, so the
  ## caller could not know when the memory may go.
  let src = openMemorySource(bytes, name)
  openSource(src, name, opts.twosComplement8015, keys, false, "", progress, opts.cache,
    opts.verify, opts.kind, faMapped, opts.vendors)

func inMemory*(f: SeismicFile): bool {.inline.} =
  ## The file was opened from bytes (`openSeismicBytes`), not from a disk
  ## file: `path` is only a display name.
  f.memId != 0

func memoryId*(f: SeismicFile): int {.inline.} =
  ## **Internal.** 0 for a disk file, else a number unique to each open of a
  ## file in memory, so that two such files with one name are told apart. Not
  ## exported by `parseSEG`.
  f.memId

proc openSeismicRw*(path: string, access = DefaultAccess): SeismicFile =
  ## **Internal** (`openEditor`; not exported by `parseSEG`). `openSeismic`
  ## read-write (mapped or unmapped, as `access` says). Raises `ValueError`
  ## for multiplexed SEG-D: edits would change only the demultiplexed copy.
  openMapped(path, false, false, true, "", access = access)

proc parkAndDrop(f: var SeismicFile, next: sink MapRef) =
  # Replaces the file's map by `next` (nil: none). When prefetchers pin the
  # old map, they (and their chunks' `TraceRows`) read the index tables
  # through raw pointers: the payloads of `entries`, `codecs` and `keys` move
  # to the map the pins keep alive, and the file gets copies, so that
  # nothing it frees or changes later is read by them. `next` has no pins
  # yet, so this is the only moment to park them.
  var old: MapRef
  lockMaps()
  if f.map.pins > 0:
    f.map.parkedEntries = move f.idx.entries
    f.map.parkedCodecs = move f.idx.codecs
    f.map.parkedKeys = move f.idx.keys
    old = f.map
  f.map = next
  unlockMaps()
  if old != nil:
    # Copied outside the lock (10 ms per 500 000 traces with keys); `old`
    # keeps the parked tables alive meanwhile, whatever the pins do.
    f.idx.entries = old.parkedEntries
    f.idx.codecs = old.parkedCodecs
    f.idx.keys = old.parkedKeys
    lockMaps()
    old = nil
    unlockMaps()

proc remapWritable*(f: var SeismicFile) =
  ## **Internal** (`openEditor(f)`; not exported by `parseSEG`). Maps `f.path`
  ## read-write in place of the file's read-only map and keeps its index.
  ## Raises `ValueError` for a closed file, a demultiplexed copy, or a file
  ## whose size changed since it was opened (its index would be stale);
  ## `f` is unchanged then. A prefetcher on `f` keeps the old map through its
  ## pin, and the index tables it reads (entries, codecs and keys) stay
  ## parked there: the file gets copies of them, so that prefetcher's chunks
  ## show the keys as they were at this call.
  f.requireOpen()
  if f.inMemory:
    raise newException(ValueError, f.path & " lives in memory, which cannot be edited " &
      "in place (edits go to a disk file with a journal); write it to a file and edit that")
  if f.demuxPath.len > 0:
    raise newException(ValueError, f.path & " holds multiplexed SEG-D, which cannot be " &
      "edited in place; convert it to a demultiplexed file first (`parseseg convert " &
      "--to=segd`, `convertSegdRevision`) and edit that")
  let src = openMemFileSource(f.path, writable = true, access = f.access) # before the ref
    # (as in `openMapped`), the way the file was opened
  let m = MapRef(src: src) # unmapped on a raise
  if m.src.size != f.map.src.size:
    raise newException(ValueError, f.path & " changed size since it was opened (" &
      $f.map.src.size & " bytes, now " & $m.src.size & "); open it again")
  f.parkAndDrop(m)

proc close*(f: var SeismicFile) =
  ## Unmaps the file and deletes a demultiplexed copy (`demuxPath`). The
  ## index stays usable; range reads do not. A prefetcher still running on
  ## the file keeps the map until its own `close`. Idempotent.
  if f.map != nil: f.parkAndDrop(nil)

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
  f.idx.entries.len

func kind*(f: SeismicFile): SeismicKind {.inline.} =
  ## SEG-Y, SEG-D or SEG-2; `skUnknown` when the file was not recognized.
  if f.idx.detected: f.idx.kind else: skUnknown

func log*(f: SeismicFile): lent DiagLog {.inline.} =
  ## Every problem found while indexing.
  f.idx.log

func recordCount*(f: SeismicFile): int =
  ## SEG-D records; 1 for SEG-Y and SEG-2; 0 for an unrecognized file.
  if not f.idx.detected: 0
  elif f.idx.kind == skSegd: f.idx.segdRecords.len
  else: 1

func maxSamples*(f: SeismicFile): int {.inline.} =
  ## Samples in the longest trace.
  f.idx.maxSamples

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
  f.idx.entries[trace]

func hasKeys*(f: SeismicFile): bool {.inline.} =
  ## The index holds per-trace geometry (`openSeismic(keys = true)`).
  f.idx.keys.len == f.idx.entries.len

func traceKeys*(f: SeismicFile, trace: int): TraceKeys =
  ## A trace's geometry (NaN or 0 where unknown). Raises `ValueError` for a
  ## trace out of range or a file opened without `keys`.
  f.requireTrace(trace)
  if not f.hasKeys: raise newException(ValueError, "open the file with keys = true")
  f.idx.keys[trace]

proc seg2Trace*(f: SeismicFile, trace: int): Seg2Trace =
  ## The SEG-2 Trace Descriptor Block of trace `trace` (fixed part and
  ## keyword strings), re-read from the map. Raises `ValueError` for a file
  ## that is not SEG-2 or is closed, or a trace out of range, and
  ## `SegTruncatedError` for a file found cut short (`cutShort`).
  f.requireKind(skSeg2)
  f.requireTrace(trace)
  f.requireOpen()
  f.requireUncutFirst()
  var cur: Cursor
  f.coverHeaders(cur, trace)
  var log: DiagLog # already reported by the index walk
  result = readSeg2Trace(f.map.src.memory.toOpenArray(0, int(f.map.src.size) - 1), f.idx.seg2,
    trace, log, f.path)
  f.requireUncut()

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
  cardLines(f.idx.segy.text.text)

proc extendedTextHeaders*(f: SeismicFile): seq[string] =
  ## SEG-Y Rev 1+: each extended textual header record after the binary
  ## header, decoded in its own detected character set, as 40 lines of 80
  ## characters joined by '\n' (the stanzas parsed from them are in
  ## `f.index.segy.extended`). Empty when there are none. Records of binary
  ## stanzas come out as their bytes in Latin-1. Raises `ValueError` for a
  ## file that is not SEG-Y, or a closed one when the records were too large
  ## to keep in memory (and `SegTruncatedError` when such a file was found
  ## cut short, `cutShort`).
  f.requireKind(skSegy)
  template ext: untyped = f.idx.segy.extended
  let n = ext.recordCount
  let start = int64(f.idx.segy.tapeLabel.len + TextHeaderSize + BinaryHeaderSize)
  if not ext.isComplete and n > 0:
    f.requireOpen()
    f.requireUncutFirst()
    if start + int64(n * TextHeaderSize) > f.map.src.size:
      raise newException(ValueError, "the extended textual header lies past the end of the file")
  template record(rec: openArray[byte]): string =
    cardLines(decodeText(rec, detectTextEncoding(rec)))
  var h: Hold
  if not ext.isComplete and n > 0: f.holdBytes(h, start, start + int64(n * TextHeaderSize))
  for r in 0..<n:
    let a = r * TextHeaderSize
    if ext.isComplete:
      result.add record(ext.data.toOpenArray(a, a + TextHeaderSize - 1))
    else:
      let b = int(start) + a
      result.add record(f.map.src.memory.toOpenArray(b, b + TextHeaderSize - 1))
  if not ext.isComplete and n > 0: f.requireUncut()

proc unsafeMemory*(f: SeismicFile): ptr UncheckedArray[byte] {.inline.} =
  ## **Internal.** The mapped bytes (nil after `close`), for the library's own
  ## zero-copy decoders and the journaled `HeaderEditor`. Not part of the
  ## public API, and not exported by the `parseSEG` module: a write through it
  ## would bypass the editor's validation and undo journal (owner rule: files
  ## change only on an explicit write). Callers use `copyBytes`, the readers,
  ## or `traceField`/`fileField` instead.
  if f.mapped: f.map.src.memory else: nil

proc unsafeGuard*(f: SeismicFile): MapGuard {.inline.} =
  ## **Internal.** The map's registration (nil after `close`), which raw
  ## readers check what they read against (`tryDecodeEntry`). Not exported by
  ## `parseSEG`.
  if f.mapped: f.map.src.mapGuard else: nil

func isOpen*(f: SeismicFile): bool {.inline.} =
  ## The file is still mapped (range reads work).
  f.mapped

proc copyBytes*(f: SeismicFile, offset: int64, n: Natural): seq[byte] =
  ## A copy of `n` raw bytes at `offset` in the file (e.g. a header for a
  ## hex view). Raises `ValueError` if the file is closed or the range lies
  ## outside it, and `SegTruncatedError` for a file found cut short
  ## (`cutShort`). Changing the copy never changes the file.
  f.requireOpen()
  let size = f.map.src.size
  # `n > size - offset`, not `offset + n > size`: the sum can overflow.
  if offset < 0 or offset > size or int64(n) > size - offset:
    raise newException(ValueError, "bytes " & $offset & "+" & $n & " lie outside the file (" &
      $size & " bytes)")
  f.requireUncutFirst()
  var h: Hold
  f.holdBytes(h, offset, offset + int64(n))
  result = newSeq[byte](n)
  if n > 0: copyMem(addr result[0], addr f.map.src.memory[offset], n)
  f.requireUncut()

proc writeFileBytes*(f: var SeismicFile, at: int64, src: pointer, n: int): string =
  ## **Internal** (the editor, geometry write-back; not exported by
  ## `parseSEG`). Writes `n` bytes from `src` at `at` of a file opened
  ## read-write: mapped, into the map; unmapped, to the file (`pwrite`) and
  ## to the cache, so later reads see them. "" when done, else why not (an
  ## I/O error: a network share that failed).
  if n <= 0 or not f.mapped: return ""
  if f.inMemory: return "a file in memory is read-only"
  let c = f.unsafeCache
  if c == nil:
    copyMem(addr f.map.src.memory[at], src, n)
    return ""
  var err = 0'i32
  if not c.writeAt(at, src, n, err):
    return "the bytes could not be written to the file (" &
      (if err == 0: "nothing was written" else: osErrorMsg(OSErrorCode(err))) & ")"
  ""

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
    own: GeometryReader ## SEG-Y: a plan made for this call (`useOwn`).
    useOwn: bool
      ## The file's plan (`gr`) does not fit its SEG-Y description any more
      ## (code replaced `index.segy` or the whole index): resolve it again.
    timeBasis: int16 ## SEG-Y: the binary header's values now (an editor may change them).
    fixedUs: float64
    segd: array[SegdLayout, SegdTrace]

proc initKeyReader(f: SeismicFile): KeyReader =
  case f.idx.kind
  of skSegy:
    result.useOwn = not f.gr.planFits(f.idx.segy)
    if result.useOwn: result.own = initGeometryReader(f.idx.segy)
    result.timeBasis = timeBasisOf(f.idx.segy)
    result.fixedUs = fixedIntervalUs(f.idx.segy)
  of skSegd: result.segd = [SegdTrace(layout: slRev2), SegdTrace(layout: slRev3)]
  else: discard

template segyPlan(f: SeismicFile, r: KeyReader): ptr GeometryReader =
  # The layout plan the call reads SEG-Y keys with; a pointer, as choosing
  # between the two by value would copy the plan (30 allocations).
  (if r.useOwn: addr r.own else: addr f.gr)

func segyPlanFits(f: SeismicFile): bool {.inline.} =
  # A SEG-Y file whose layout plan (`gr`) is still that of `index.segy`.
  f.idx.kind == skSegy and f.gr.planFits(f.idx.segy)

proc raiseOutside(trace: int) {.noinline, noreturn.} =
  raise newException(ValueError, "the headers of trace " & $trace & " lie outside the file")

func mappedSegyHeaders(mem: ptr UncheckedArray[byte], size: int64, e: TraceEntry,
    h: var RawHeaders): bool =
  # The mapped header bytes of a SEG-Y trace; false when they lie outside the map.
  let a = int(e.offset)
  let hb = int(e.headerBytes)
  if e.offset < 0 or e.offset + max(hb, TraceHeaderSize) > size: return false
  let extra = hb - 2 * TraceHeaderSize
  h = RawHeaders(std: cast[ByteBuf](addr mem[a]),
    ext1: if hb >= 2 * TraceHeaderSize: cast[ByteBuf](addr mem[a + TraceHeaderSize]) else: nil,
    prop: if extra > 0: cast[ByteBuf](addr mem[a + 2 * TraceHeaderSize]) else: nil,
    propLen: max(extra, 0))
  true

proc segyIntervalOf*(f: SeismicFile, trace: int): float64 =
  ## **Internal** (`headerfields.sampleIntervalUs`). The interval of SEG-Y
  ## trace `trace` from its mapped headers (as `TraceKeys.intervalUs`); NaN
  ## when they lie outside the file. The caller checks the trace and the map.
  let fixed = fixedIntervalUs(f.idx.segy)
  if not fixed.isNaN: return fixed
  f.requireUncutFirst()
  var cur: Cursor
  f.coverHeaders(cur, trace)
  var h: RawHeaders
  result = if not mappedSegyHeaders(f.unsafeMemory, f.mappedSize, f.idx.entries[trace], h): NaN
    else: segyIntervalUs(h, f.idx.segy.byteOrder, NaN)
  f.requireUncut()

proc keysOf(f: SeismicFile, r: var KeyReader, mem: ptr UncheckedArray[byte], size: int64,
    trace: int): TraceKeys =
  # The keys of `trace` from its mapped headers, as the index walk makes them.
  template ix: untyped = f.idx
  let e = ix.entries[trace]
  let a = int(e.offset)
  let hb = int(e.headerBytes)
  case ix.kind
  of skSegy:
    var h: RawHeaders
    if not mappedSegyHeaders(mem, size, e, h): raiseOutside(trace)
    # Straight from the mapped bytes: nothing decoded or copied.
    segyKeys(segyPlan(f, r)[], h, r.timeBasis, r.fixedUs)
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
    for k in 0 ..< count: dst[k] = f.idx.keys[traceAt(k)]
  elif count > 0:
    f.requireOpen()
    f.requireUncutFirst()
    let mem = f.unsafeMemory
    let size = f.mappedSize
    if f.segyPlanFits:
      # SEG-Y with the file's own plan: no per-call reader to set up (100 ns
      # of a 400 ns call for one trace).
      let timeBasis = timeBasisOf(f.idx.segy)
      let fixedUs = fixedIntervalUs(f.idx.segy)
      let unmapped = f.unsafeCache != nil # asked once: the loop tests a register
      var cur: Cursor
      for k in 0 ..< count:
        let trace = traceAt(k)
        if unmapped: f.coverHeaders(cur, trace)
        var h: RawHeaders
        if not mappedSegyHeaders(mem, size, f.idx.entries[trace], h): raiseOutside(trace)
        dst[k] = segyKeys(f.gr, h, timeBasis, fixedUs)
    else:
      var r = initKeyReader(f)
      let unmapped = f.unsafeCache != nil
      var cur: Cursor
      for k in 0 ..< count:
        if unmapped: f.coverHeaders(cur, traceAt(k))
        dst[k] = f.keysOf(r, mem, size, traceAt(k))
    f.requireUncut()

proc traceKeysInto*(f: SeismicFile, traces: openArray[int], dst: var openArray[TraceKeys]) =
  ## The keys of each trace of `traces` into `dst` (`dst.len == traces.len`).
  ## A file opened with `keys = true` copies its stored keys (with any
  ## `applyGeometry` or `applySurvey` changes); otherwise the keys are made
  ## on demand from the mapped headers, exactly as `openSeismic(keys = true)`
  ## makes them (the file's own geometry: survey changes are not applied).
  ## On demand costs about what the index walk spends per trace, but only for
  ## the traces asked for. Raises `ValueError` for a trace out of range, a
  ## closed file or a `dst` of the wrong length, and on demand
  ## `SegTruncatedError` for a file found cut short (`cutShort`).
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

proc ensureKeys*(f: var SeismicFile, progress: Progress = nil) =
  ## Builds the stored keys of a file opened without them, exactly as
  ## `openSeismic(keys = true)` would (from the mapped headers, also for an
  ## index loaded from a cache), and bumps `keysRevision`; does nothing when
  ## the file has them. A viewer can open a large file fast and build keys
  ## when geometry is first needed. `progress` reports the trace header
  ## bytes read; when it cancels, `SegCancelledError` is raised and the file
  ## stays without keys. Raises `ValueError` for a closed file or headers
  ## that lie outside it, and `SegTruncatedError` (the file stays without
  ## keys) for a file found cut short (`cutShort`).
  ##
  ## Whatever was made from the file before this call still has no keys: a
  ## `TraceRows` view (`rowsOf`; its `hasKeys` stays false and `traceKeys`
  ## raises) and a `Prefetcher` (its chunks' `rows` likewise). They hold
  ## pointers taken when they were made, so make them again: `rowsOf` once
  ## more, and `close` the prefetcher and call `newPrefetcher`. A
  ## prefetcher of this thread may keep running during the call; no other
  ## thread may use the file meanwhile.
  if f.hasKeys: return
  f.requireOpen()
  f.requireUncut()
  let n = f.len
  let mem = f.unsafeMemory
  let size = f.mappedSize
  var r = initKeyReader(f)
  var tick = initProgressTicker(progress, size)
  var keys = newSeq[TraceKeys](n)
  var cur: Cursor
  for i in 0 ..< n:
    f.coverHeaders(cur, i)
    keys[i] = f.keysOf(r, mem, size, i)
    if not tick.tick(f.idx.entries[i].offset): raiseCancelled()
  if not tick.finish(): raiseCancelled()
  f.requireUncut()
  f.idx.keys = move keys
  inc f.idx.keysRevision

func keepJoined(k: var TraceKeys, old: TraceKeys, groups: set[JoinGroup]) =
  # The values a join wrote win over the headers (Phase 16, D2), group by
  # group: what the join did not change follows the headers (`k`, as just
  # read from them), so an edit of it shows and `writeGeometry` does not
  # write the old value back.
  func same(x, y: float64): bool {.inline.} = x == y or (x.isNaN and y.isNaN)
  if groups == {}: return
  if jgSourceXy in groups: (k.srcX, k.srcY) = (old.srcX, old.srcY)
  if jgReceiverXy in groups: (k.rcvX, k.rcvY) = (old.rcvX, old.rcvY)
  if jgSourceZ in groups: k.srcZ = old.srcZ
  if jgReceiverZ in groups: k.rcvZ = old.rcvZ
  if jgSourceStation in groups:
    (k.srcLine, k.srcPoint, k.srcIndex) = (old.srcLine, old.srcPoint, old.srcIndex)
  if jgReceiverStation in groups:
    (k.rcvLine, k.rcvPoint, k.rcvIndex) = (old.rcvLine, old.rcvPoint, old.rcvIndex)
  if jgComponent in groups: k.component = old.component
  if jgDerived in groups:
    let endsMoved = not (same(k.srcX, old.srcX) and same(k.srcY, old.srcY) and
      same(k.rcvX, old.rcvX) and same(k.rcvY, old.rcvY))
    if not endsMoved:
      (k.offset, k.cmpX, k.cmpY) = (old.offset, old.cmpX, old.cmpY)
    else:
      # An end the join left to the headers was edited, so the offset and
      # midpoint the join derived are stale: derive them again from the ends
      # as they are now (the join's stay where an end is unknown now). A
      # header value the join had kept (the stored one still equals it) stays.
      var d = k
      (d.offset, d.cmpX, d.cmpY) = (old.offset, old.cmpX, old.cmpY)
      d.deriveGeometry(overwrite = true)
      if not same(k.offset, old.offset): k.offset = d.offset
      if not (same(k.cmpX, old.cmpX) and same(k.cmpY, old.cmpY)):
        (k.cmpX, k.cmpY) = (d.cmpX, d.cmpY)

func sameKeys(a, b: TraceKeys): bool =
  result = true
  for x, y in fields(a, b):
    when x is SomeFloat:
      if not (x == y or (x.isNaN and y.isNaN)): return false
    else:
      if x != y: return false

proc refreshKeys*(f: var SeismicFile, traces: openArray[int]): bool =
  ## **Internal** (`HeaderEditor`). Re-reads the stored keys of `traces`
  ## from their mapped headers after an edit, keeping the values a join
  ## wrote (`joinedTraces`), and bumps `keysRevision` once when any changed.
  ## True if any changed; nothing to do for a file without stored keys.
  ## Traces whose headers lie outside the map keep their keys.
  result = false
  if not f.hasKeys or traces.len == 0 or not f.isOpen: return
  when not mapsGuarded:
    if f.cutSeen: return # a read past the cut would fault; the editor refuses edits now
  let mem = f.unsafeMemory
  let size = f.mappedSize
  var r = initKeyReader(f)
  var cur: Cursor
  for t in traces:
    if t < 0 or t >= f.len: continue
    var k: TraceKeys
    try:
      f.coverHeaders(cur, t)
      k = f.keysOf(r, mem, size, t)
    except ValueError, IOError: continue # outside the file, or unmapped and not read
    k.keepJoined(f.idx.keys[t], f.idx.joinedGroups(t))
    if not sameKeys(k, f.idx.keys[t]):
      f.idx.keys[t] = k
      result = true
  if result: inc f.idx.keysRevision

proc refreshSegyInterval*(f: var SeismicFile) =
  ## **Internal** (`HeaderEditor`). `index.segyIntervalUs` after an edit of
  ## an interval field: the binary header's for a fixed-length file, else the
  ## one every stored key agrees on (NaN when they differ); kept as it was
  ## for a file without stored keys whose traces give their own.
  if f.idx.kind != skSegy: return
  let fixed = fixedIntervalUs(f.idx.segy)
  if not fixed.isNaN:
    f.idx.segyIntervalUs = fixed
  elif f.hasKeys and f.len > 0:
    let dt = f.idx.keys[0].intervalUs
    var same = true
    for k in f.idx.keys:
      if k.intervalUs != dt: same = false
    f.idx.segyIntervalUs = if same: dt else: NaN

func keysRevision*(f: SeismicFile): int {.inline.} =
  ## 0 as opened; goes up whenever the stored keys change (`ensureKeys`,
  ## `applyGeometry`, `applySurvey`, `HeaderEditor` writes). Tag data
  ## derived from keys (moveout overlays, binning) with it and rebuild it
  ## when the revision changes. Views and prefetchers made while the file
  ## had stored keys read them in place and so see every later change; those
  ## made before `ensureKeys` have no keys and must be made again (see
  ## `ensureKeys`).
  f.idx.keysRevision

template t0Loop(f: SeismicFile, dst: var openArray[float64], count: int, traceAt: untyped) =
  if dst.len != count:
    raise newException(ValueError, "need " & $count & " values, got " & $dst.len)
  if f.hasKeys:
    for k in 0 ..< count: dst[k] = f.idx.keys[traceAt(k)].t0Ms
  elif count > 0:
    f.requireOpen()
    f.requireUncutFirst()
    let mem = f.unsafeMemory
    let size = f.mappedSize
    if f.segyPlanFits:
      # SEG-Y: only the delay is read, not the whole key.
      let unmapped = f.unsafeCache != nil
      var cur: Cursor
      for k in 0 ..< count:
        let trace = traceAt(k)
        if unmapped: f.coverHeaders(cur, trace)
        var h: RawHeaders
        if not mappedSegyHeaders(mem, size, f.idx.entries[trace], h): raiseOutside(trace)
        dst[k] = segyStartTimeMs(f.gr, h)
    else:
      var r = initKeyReader(f)
      let unmapped = f.unsafeCache != nil
      var cur: Cursor
      for k in 0 ..< count:
        if unmapped: f.coverHeaders(cur, traceAt(k))
        dst[k] = f.keysOf(r, mem, size, traceAt(k)).t0Ms
    f.requireUncut()

proc startTimeMsInto*(f: SeismicFile, traces: openArray[int], dst: var openArray[float64]) =
  ## The time of sample 0 (`TraceKeys.t0Ms`, ms) of each trace of `traces`
  ## into `dst` (`dst.len == traces.len`); for a file opened without keys,
  ## read from the headers as `traceKeysInto` does. Raises like
  ## `traceKeysInto`.
  for t in traces: f.requireTrace(t)
  template at(k: int): int = traces[k]
  t0Loop(f, dst, traces.len, at)

proc startTimeMsInto*(f: SeismicFile, traces: Slice[int], dst: var openArray[float64]) =
  ## `startTimeMsInto` for a range of traces (an empty range must start in
  ## `0 .. len`).
  checkSpan(traces, f.len)
  template at(k: int): int = traces.a + k
  t0Loop(f, dst, spanLen(traces), at)

proc startTimeMs*(f: SeismicFile, trace: int): float64 =
  ## The time of sample 0 of trace `trace` in ms (`TraceKeys.t0Ms`), also for
  ## a file opened without keys. Raises `ValueError` for a trace out of range
  ## or a closed file.
  var v: array[1, float64]
  f.startTimeMsInto([trace], v)
  v[0]

proc firstOrientation(area: openArray[byte]): Option[SegdOrientation] =
  # The first Orientation block. Indexing reads extension bytes but does not
  # walk their block types, so a later block is not compared or reported.
  let at = findBlock(area, BlockTypeOrientation)
  if at < 0 or at + SegdBlockSize > area.len: return
  some(decodeBlock[SegdOrientation](area.toOpenArray(at, at + SegdBlockSize - 1)))

proc traceOrientation*(f: SeismicFile, trace: int): Option[SegdOrientation] =
  ## The SEG-D Rev 3 Orientation header (0x60) of trace `trace`; none when
  ## the trace has no such block, including SEG-Y, SEG-2 and SEG-D before
  ## Rev 3. Taken from the trace header extensions, wherever in them another
  ## writer placed it: a scan of those 32-byte blocks, cheap enough to call
  ## for every trace of a record. The first block wins. A second block is
  ## not reported: indexing does not walk a trace's header extensions, and
  ## a query does not write the log. A 0x60 in the general header is not
  ## used here: the spec does not say that block applies to traces without
  ## their own ("A block (e.g. Position 50-52, Additional Source Info 20,
  ## Aux Channel Ref 21) applies to the preceding Source Description
  ## block"), so it is `recordOrientation`. Raises `ValueError` for a trace
  ## out of range, a closed file, or headers that lie outside the file, and
  ## `SegTruncatedError` for a file cut short while open (`cutShort`).
  f.requireTrace(trace)
  f.requireOpen()
  if f.idx.kind != skSegd: return
  let e = f.idx.entries[trace]
  if not f.idx.segdRecords[e.record].isRev3: return
  let hb = int64(e.headerBytes)
  if e.offset < 0 or hb < SegdTraceHeaderSize or e.offset + hb > f.mappedSize:
    raiseOutside(trace)
  let ext = hb - SegdTraceHeaderSize
  if ext < SegdBlockSize: return
  f.requireUncutFirst()
  let start = e.offset + SegdTraceHeaderSize
  f.withHeld(start, e.offset + hb):
    let mem = f.unsafeMemory
    let a = int(start)
    result = firstOrientation(mem.toOpenArray(a, a + int(ext) - 1))
  f.requireUncut()

proc recordOrientation*(f: SeismicFile, record: int): Option[SegdOrientation] =
  ## The first Orientation header (0x60) in SEG-D record `record`'s general
  ## header blocks; none when that record has none, or the file is not SEG-D
  ## Rev 3. Table 2 allows the block in the general header, but the text does
  ## not say it applies to every trace without its own, so `traceOrientation`
  ## does not return it. The first block wins. A second block is not
  ## reported: a query does not write the log. Raises `ValueError` for a
  ## record out of range or a closed file.
  f.requireOpen()
  if record notin 0 ..< f.recordCount:
    raise newException(ValueError, "no record " & $record & " (the file has " &
      $f.recordCount & ")")
  if f.idx.kind != skSegd: return
  let rec = f.idx.segdRecords[record]
  if not rec.isRev3: return
  firstOrientation(rec.generalBlocks)

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

func selOf(traces: openArray[int]): ptr UncheckedArray[int] {.inline.} =
  # A selection's positions as a raw list (nil when empty), for `holdSpan`.
  if traces.len > 0: cast[ptr UncheckedArray[int]](unsafeAddr traces[0]) else: nil

template decodeLoop(f: SeismicFile, count: int, sel: ptr UncheckedArray[int], posBase: int,
    traceAt, rowAt: untyped, cols, first: int, log: var DiagLog, T: typedesc,
    failedRows: untyped = nil): int =
  # Decodes `count` traces: samples `first ..< first + cols` of trace
  # `traceAt(k)` into row pointer `rowAt(k)`. With `failedRows` (a `ptr
  # seq[int]`), the list is cleared (its capacity kept) and gets the `k` of
  # each trace left zero, in order, instead of a report in `log`. Position
  # `posBase + k` is trace `traceAt(k)`, an index into `sel` when it is not
  # nil (`holdSpan`, for an unmapped file).
  var failed = 0
  when failedRows isnot typeof(nil): failedRows[].setLen 0
  let mem = f.unsafeMemory
  let size = f.mappedSize
  template fail(p: ptr UncheckedArray[T], k, i: int, e: TraceEntry, st: DecodeStatus) =
    for c in 0..<cols: p[c] = T(0)
    when failedRows isnot typeof(nil):
      failedRows[].add k
    else:
      log.report(sevError, diagCodeOf(st), decodeMessages[st], e.offset,
        Location(file: f.path, record: if f.idx.kind == skSeg2: 0 else: int(e.record),
          trace: i))
    inc failed
  let guard = f.unsafeGuard
  let known = guard.guardCut
  let cache = f.unsafeCache
  var notRead: seq[int] # unmapped: the `k` of the traces failed unread (ascending)
  if cache != nil and count > 0:
    # Unmapped: the windows of consecutive traces are held as spans, one
    # request each (`holdSpan`); a trace whose bytes did not arrive fails.
    let entries = cast[ptr UncheckedArray[TraceEntry]](addr f.idx.entries[0])
    let codecs = cast[ptr UncheckedArray[TraceCodec]](addr f.idx.codecs[0])
    let why = guard.cutStatus
    # Scattered or large reads: the OS is asked for all their windows at once.
    cache.adviseSpans(entries, codecs, sel, posBase, posBase + count, cols, first)
    var sp: SpanHold
    for k in 0..<count:
      let i = traceAt(k)
      let e = f.idx.entries[i]
      let c = f.idx.codecs[e.record]
      let p = rowAt(k)
      var st = dsOk
      if known < size and not undecodable(e, c, size) and pastCut(e, c, known): st = why
      else:
        let (x, y) = readSpan(e, c, cols, first)
        if y > x and (x < sp.lo or y > sp.hi):
          cache.holdSpan(sp, entries, codecs, sel, posBase + k, posBase + count, cols, first)
        st = if y > x and sp.failed and not cache.holds(x, y): dsNotRead
             else: tryDecodeEntry(mem, size, e, c, p, cols, first)
      if st != dsOk:
        if st == dsNotRead: notRead.add k
        fail(p, k, i, e, st)
    sp.drop()
  elif known >= size:
    for k in 0..<count:
      let i = traceAt(k)
      let e = f.idx.entries[i]
      let p = rowAt(k)
      let st = tryDecodeEntry(mem, size, e, f.idx.codecs[e.record], p, cols, first)
      if st != dsOk: fail(p, k, i, e, st)
  else:
    # A cut known before the read: the traces past it fail unread (without
    # the guard a read there faults; with it, it would read zeros).
    let why = guard.cutStatus
    for k in 0..<count:
      let i = traceAt(k)
      let e = f.idx.entries[i]
      let c = f.idx.codecs[e.record]
      let p = rowAt(k)
      let st = if not undecodable(e, c, size) and pastCut(e, c, known): why
               else: tryDecodeEntry(mem, size, e, c, p, cols, first)
      if st != dsOk: fail(p, k, i, e, st)
  if count > 0 and guard.guardCut < size:
    # A cut was found during the read (or before): every trace decoded whose
    # bytes reach past it read zeros there, and fails too. One check per
    # read, none per trace (`guardCut` comes after the decodes: a fence).
    # Those past a cut known before failed already, and so did those whose
    # read failed (unmapped: `notRead`, a failed read and a cut in one call).
    let cut = guard.guardCut
    let why = guard.cutStatus
    var j = 0
    for k in 0..<count:
      if j < notRead.len and notRead[j] == k:
        inc j
        continue
      let i = traceAt(k)
      let e = f.idx.entries[i]
      let c = f.idx.codecs[e.record]
      if not undecodable(e, c, size) and pastCut(e, c, cut) and not pastCut(e, c, known):
        fail(rowAt(k), k, i, e, why)
    when failedRows isnot typeof(nil):
      var rows = move failedRows[] # sorted through a local: `failedRows[].sort()`
      rows.sort()                  # makes C that does not compile (Nim 2.4.2)
      failedRows[] = move rows
  failed

proc checkReadable(f: SeismicFile, count: int) =
  if count > 0: f.requireOpen()
  if not f.idx.contiguous:
    raise newException(ValueError, "range reads need a plain disk file")

proc checkSelection(f: SeismicFile, traces: Slice[int]) {.inline.} =
  checkSpan(traces, f.len)

proc checkSelection(f: SeismicFile, traces: openArray[int]) =
  for i in traces:
    f.requireTrace(i)

proc checkRows[T](dst: Tensor[T], row, count: int) =
  # `row <= shape[0] - count`, not `row + count <= shape[0]`: the sum can overflow.
  if not (dst.rank == 2 and dst.is_C_contiguous and row >= 0 and row <= dst.shape[0] - count):
    raise newException(ValueError,
      "need a row-major [traces, samples] tensor with room for the traces")

proc advise(f: SeismicFile, traces: Slice[int], cols, first: int) {.inline.} =
  # Read-ahead advice for a checked range (see `adviseTraces`); none
  # unmapped (the reads are made in spans instead).
  if traces.b - traces.a >= 0 and f.unsafeCache == nil:
    adviseTraces(f.unsafeMemory, f.mappedSize,
      cast[ptr UncheckedArray[TraceEntry]](addr f.idx.entries[0]),
      cast[ptr UncheckedArray[TraceCodec]](addr f.idx.codecs[0]),
      nil, traces.a, traces.b + 1, cols, first)

proc advise(f: SeismicFile, traces: openArray[int], cols, first: int) {.inline.} =
  # Read-ahead advice for a checked selection (see `adviseTraces`); none
  # unmapped.
  if traces.len > 0 and f.unsafeCache == nil:
    adviseTraces(f.unsafeMemory, f.mappedSize,
      cast[ptr UncheckedArray[TraceEntry]](addr f.idx.entries[0]),
      cast[ptr UncheckedArray[TraceCodec]](addr f.idx.codecs[0]),
      cast[ptr UncheckedArray[int]](addr traces[0]), 0, traces.len, cols, first)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], dst: var Tensor[T],
    log: var DiagLog, row = 0): int =
  ## Decodes `traces` into rows `row ..< row + traces.len` of `dst` (a
  ## row-major `[rows, samples]` tensor), each truncated or zero-padded to
  ## `dst.shape[1]`. A trace that cannot be decoded is left zero, logged in
  ## `log`, and counted in the result; so is a trace past the end of a file
  ## that another program cut short while it was open (`dcTruncated`, see
  ## `cutShort`): POSIX gives zeros there instead of ending the program
  ## with `SIGBUS`, and each trace is checked against the cut after it is
  ## decoded. Raises `ValueError` for traces outside
  ## the file (an empty range must still start in `0 .. f.len`), a closed
  ## file or a tensor without room. A large or scattered read whose pages
  ## are not in memory first asks the OS to read them all ahead (POSIX
  ## `madvise(MADV_WILLNEED)`), so a cold gather waits for the disk once
  ## rather than once per trace.
  f.checkSelection(traces) # before its length is taken: that can overflow
  let count = traces.spanLen
  f.checkReadable(count)
  dst.checkRows(row, count)
  f.advise(traces, dst.shape[1], 0)
  template trace(k: int): int = traces.a + k
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, count, nil, traces.a, trace, rowOf, dst.shape[1], 0, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    dst: var Tensor[T], log: var DiagLog, row = 0): int =
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
  decodeLoop(f, traces.len, selOf(traces), 0, trace, rowOf, dst.shape[1], 0, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], dst: var Tensor[T],
    row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero); pass a log to learn which and why.
  var log: DiagLog
  f.readTracesInto(traces, dst, log, row)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    dst: var Tensor[T], row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero).
  var log: DiagLog
  f.readTracesInto(traces, dst, log, row)

proc windowCols(samples: Slice[int]): int =
  # The column count of the sample window `samples`. `samples.len` is never
  # taken before the bounds are known to be ordered: `0 .. high(int)` has no
  # length that fits an `int`.
  if samples.a < 0 or samples.b < samples.a:
    raise newException(ValueError, "the sample window " & $samples &
      " must be a..b with 0 <= a <= b")
  if samples.b - samples.a == high(int):
    raise newException(ValueError, "the sample window " & $samples & " is too long")
  samples.b - samples.a + 1

proc checkWindow[T](dst: Tensor[T], samples: Slice[int]) =
  let cols = windowCols(samples)
  if dst.rank == 2 and dst.shape[1] != cols:
    raise newException(ValueError, "the sample window " & $samples & " needs " & $cols &
      " columns, the tensor has " & $dst.shape[1])

proc checkTensorSize(rows, cols: int, T: typedesc) =
  # A new `[rows, cols]` tensor of `T` must have a byte size that fits an `int`.
  if cols > 0 and rows > high(int) div sizeof(T) div cols:
    raise newException(ValueError, "a tensor of " & $rows & " traces of " & $cols &
      " samples is too large")

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], samples: Slice[int],
    dst: var Tensor[T], log: var DiagLog, row = 0): int =
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
  dst.checkWindow(samples)
  f.checkSelection(traces) # before its length is taken: that can overflow
  let count = traces.spanLen
  f.checkReadable(count)
  dst.checkRows(row, count)
  f.advise(traces, dst.shape[1], samples.a)
  template trace(k: int): int = traces.a + k
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, count, nil, traces.a, trace, rowOf, dst.shape[1], samples.a, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    samples: Slice[int], dst: var Tensor[T], log: var DiagLog, row = 0): int =
  ## The sample window of the selected traces, in list order (a gather, a
  ## sort order); otherwise as the `Slice` form.
  dst.checkWindow(samples)
  f.checkReadable(traces.len)
  f.checkSelection(traces)
  dst.checkRows(row, traces.len)
  f.advise(traces, dst.shape[1], samples.a)
  template trace(k: int): int = traces[k]
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, traces.len, selOf(traces), 0, trace, rowOf, dst.shape[1], samples.a, log, T)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], samples: Slice[int],
    dst: var Tensor[T], row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero).
  var log: DiagLog
  f.readTracesInto(traces, samples, dst, log, row)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    samples: Slice[int], dst: var Tensor[T], row = 0): int =
  ## As above, without a log: returns the number of traces that could not be
  ## decoded (left zero).
  var log: DiagLog
  f.readTracesInto(traces, samples, dst, log, row)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], dst: var Tensor[T],
    failedRows: var seq[int], row = 0): int =
  ## As the form with a log, but reports which traces could not be decoded
  ## in `failedRows` instead: it is cleared first (also when the arguments
  ## are rejected), then gets each such trace's
  ## position in `traces` (0-based, so row `row + k` of `dst`), ascending, as
  ## `PrefetchChunk.failedRows` does. Nothing is logged and the list keeps
  ## its capacity, so a caller that reuses it does not allocate, even when
  ## traces fail. Returns `failedRows.len`.
  failedRows.setLen 0 # cleared even when the arguments are rejected
  var log: DiagLog
  f.checkSelection(traces) # before its length is taken: that can overflow
  let count = traces.spanLen
  f.checkReadable(count)
  dst.checkRows(row, count)
  f.advise(traces, dst.shape[1], 0)
  template trace(k: int): int = traces.a + k
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, count, nil, traces.a, trace, rowOf, dst.shape[1], 0, log, T, addr failedRows)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    dst: var Tensor[T], failedRows: var seq[int], row = 0): int =
  ## The selected traces, in list order, with their failed positions in
  ## `failedRows`; see the `Slice` form.
  failedRows.setLen 0 # cleared even when the arguments are rejected
  var log: DiagLog
  f.checkReadable(traces.len)
  f.checkSelection(traces)
  dst.checkRows(row, traces.len)
  f.advise(traces, dst.shape[1], 0)
  template trace(k: int): int = traces[k]
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, traces.len, selOf(traces), 0, trace, rowOf, dst.shape[1], 0, log, T, addr failedRows)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: Slice[int], samples: Slice[int],
    dst: var Tensor[T], failedRows: var seq[int], row = 0): int =
  ## The sample window `samples` of `traces` (see the windowed form with a
  ## log), with the failed positions in `failedRows` (see the `failedRows`
  ## form without a window).
  failedRows.setLen 0 # cleared even when the arguments are rejected
  var log: DiagLog
  dst.checkWindow(samples)
  f.checkSelection(traces) # before its length is taken: that can overflow
  let count = traces.spanLen
  f.checkReadable(count)
  dst.checkRows(row, count)
  f.advise(traces, dst.shape[1], samples.a)
  template trace(k: int): int = traces.a + k
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, count, nil, traces.a, trace, rowOf, dst.shape[1], samples.a, log, T, addr failedRows)

proc readTracesInto*[T: SampleType](f: SeismicFile, traces: openArray[int],
    samples: Slice[int], dst: var Tensor[T], failedRows: var seq[int], row = 0): int =
  ## The sample window of the selected traces, in list order, with the failed
  ## positions in `failedRows`; see the `Slice` form.
  failedRows.setLen 0 # cleared even when the arguments are rejected
  var log: DiagLog
  dst.checkWindow(samples)
  f.checkReadable(traces.len)
  f.checkSelection(traces)
  dst.checkRows(row, traces.len)
  f.advise(traces, dst.shape[1], samples.a)
  template trace(k: int): int = traces[k]
  template rowOf(k: int): ptr UncheckedArray[T] = rowPtr(dst, row + k)
  decodeLoop(f, traces.len, selOf(traces), 0, trace, rowOf, dst.shape[1], samples.a, log, T, addr failedRows)

func maxSamples*(f: SeismicFile, traces: Slice[int]): int =
  ## Largest sample count in the trace range (0 when empty). Raises
  ## `ValueError` for traces outside the file (an empty range must still
  ## start in `0 .. f.len`).
  f.checkSelection(traces)
  for i in traces: result = max(result, int(f.idx.entries[i].numSamples))

func maxSamples*(f: SeismicFile, traces: openArray[int]): int =
  ## Largest sample count of the selected traces. Raises `ValueError` for a
  ## trace outside the file.
  f.checkSelection(traces)
  for i in traces: result = max(result, int(f.idx.entries[i].numSamples))

proc readTraces*(f: SeismicFile, traces: Slice[int], log: var DiagLog,
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## `traces` as a new `[traces.len, maxSamples]` tensor (shorter traces are
  ## zero-padded). A trace that cannot be decoded stays zero and is logged in
  ## `log`. Raises `ValueError` for traces outside the file (an empty range
  ## must still start in `0 .. f.len`) or a closed file.
  # Uninitialized: the decode writes every element (samples, zero padding,
  # or a zero row for a trace that cannot be decoded).
  let cols = f.maxSamples(traces) # checks the range, before its length is taken
  result = newTensorUninit[T](traces.spanLen, cols)
  discard f.readTracesInto(traces, result, log)

proc readTraces*(f: SeismicFile, traces: openArray[int], log: var DiagLog,
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## The selected traces, in list order, as a new `[traces.len, maxSamples]`
  ## tensor; otherwise as the `Slice` form.
  result = newTensorUninit[T](traces.len, f.maxSamples(traces)) # every element is written
  discard f.readTracesInto(traces, result, log)

proc readTraces*(f: SeismicFile, traces: Slice[int], samples: Slice[int], log: var DiagLog,
    T: typedesc[SampleType] = float32): Tensor[T] =
  ## Samples `samples` of `traces` as a new `[traces.len, samples.len]`
  ## tensor (zero past a trace's end); see the windowed `readTracesInto`. A
  ## trace that cannot be decoded stays zero and is logged in `log`. Raises
  ## `ValueError` also for a window whose tensor would not fit an `int` of
  ## bytes (`1000 .. high(int)`).
  let cols = windowCols(samples)
  f.checkSelection(traces)
  checkTensorSize(traces.spanLen, cols, T)
  result = newTensorUninit[T](traces.spanLen, cols) # every element is written
  discard f.readTracesInto(traces, samples, result, log)

proc readTraces*(f: SeismicFile, traces: openArray[int], samples: Slice[int],
    log: var DiagLog, T: typedesc[SampleType] = float32): Tensor[T] =
  ## The sample window of the selected traces, in list order; otherwise as
  ## the `Slice` form.
  let cols = windowCols(samples)
  checkTensorSize(traces.len, cols, T)
  result = newTensorUninit[T](traces.len, cols) # every element is written
  discard f.readTracesInto(traces, samples, result, log)

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
  for i, k in ix.keys.mpairs:
    let before = k
    if k.applyGeometry(g, overwrite):
      inc result
      ix.markJoined(i, changedGroups(before, k))
  if result > 0:
    ix.joined = true # only now: an index no join changed is still the file's own
    inc ix.keysRevision

proc applyGeometry*(f: var SeismicFile, g: GeometryTable, overwrite = false): int =
  ## `applyGeometry` on the file's index (its stored keys): the number of
  ## traces changed. Raises `ValueError` for a file opened without keys.
  f.idx.applyGeometry(g, overwrite)

# ------------------------------------------------------------ index cache --
# The file format is `private/indexcache`.

proc cacheKey(f: SeismicFile): CacheKey =
  CacheKey(path: f.path, stamp: f.stamp, mem: f.unsafeMemory, size: f.mappedSize,
    twos: f.twos)

proc holdEnds(f: SeismicFile, head, tail: var Hold) =
  # Unmapped: the file's first and last `StampSpan` bytes, which the cache's
  # key hashes. `IOError` when they cannot be read.
  let size = f.mappedSize
  f.holdBytes(head, 0, min(size, StampSpan))
  f.holdBytes(tail, max(0'i64, size - StampSpan), size)

proc loadIndex(f: var SeismicFile, cache: string, keys: bool, verify: VerifyMode): string
    {.raises: [].} =
  # Reads `f.index` from the cache `cache`: "" when done, else why not
  # (then `f.index` is unchanged).
  var head, tail: Hold
  try: f.holdEnds(head, tail)
  except IOError as e: return "the file could not be read: " & e.msg
  readIndexCache(cache, f.cacheKey, keys, verify, f.idx)

proc saveIndex*(f: SeismicFile, path: string) =
  ## Writes `f`'s index to the index cache `path`, for `openSeismic(path,
  ## opts = OpenOptions(cache: path))` to read back instead of walking the file again: a
  ## viewer's second open of a large file is then about as fast as reading
  ## the cache. The cache holds everything the walk found (entries, codecs,
  ## file and record headers, the walk's diagnostics, keys when the file
  ## was opened with them), about 24 bytes per trace (plus 184 with keys),
  ## and stamps of the file (see `openSeismic`). Written through a new
  ## temporary file next to `path`, synced to disk (POSIX) and renamed when
  ## complete, so a crash leaves the previous cache or a whole new one.
  ##
  ## Raises `ValueError` for a closed or unrecognized file, a demultiplexed
  ## copy (`demuxPath`), a file whose keys were read through a vendor map's
  ## layout (`OpenOptions.vendors`: a cache is read without the map), keys changed by `applyGeometry`/`applySurvey` (the
  ## cache holds the file's own index), a file that changed since it was
  ## opened, a file in memory (`openSeismicBytes`), or `path` naming the file
  ## itself; `IOError`/`OSError` if the cache cannot be written.
  f.requireOpen()
  if f.inMemory:
    raise newException(ValueError, f.path & " lives in memory, which has no index cache " &
      "(the cache belongs to a disk file's path and time stamps)")
  if not f.idx.detected:
    raise newException(ValueError, f.path & " is not a SEG-Y, SEG-D or SEG-2 file")
  if f.demuxPath.len > 0:
    raise newException(ValueError, f.path & " was indexed through a demultiplexed copy, " &
      "which is not cached")
  if f.idx.vendorLayout:
    raise newException(ValueError, "the keys were read through a vendor map's layout " &
      "(OpenOptions.vendors), which a cache read without the map would not know")
  if f.idx.joined:
    raise newException(ValueError, "the trace keys were changed by applyGeometry or " &
      "applySurvey; save the index before joining geometry")
  if path == f.path or (fileExists(path) and sameFile(path, f.path)):
    raise newException(ValueError, "the index cache " & path & " is the seismic file itself")
  if stampOf(f.path) != f.stamp:
    raise newException(ValueError, f.path & " changed since it was opened; open it again")
  var head, tail: Hold
  f.holdEnds(head, tail)
  writeIndexCache(path, f.cacheKey, f.idx, f.walkLog, f.hasKeys)
