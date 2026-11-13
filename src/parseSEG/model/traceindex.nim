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

import std/[math, os, times, locks]
import ../common/[errors, diagnostics, seismickind, progress, tensors]
import ../io/[records, memsource]
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader, demux]
import ../seg2/[reader as seg2reader]
import ./[keys, indextypes, indexwalk]
import ../segy/samples as segysamples, ../segd/samples as segdsamples,
  ../seg2/samples as seg2samples
import ../private/[checks, decodeentry, progressticker, tensorrows, segykeys, indexcache]

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

type
  MapPin* = object
    ## **Internal** (the prefetcher). Keeps a file's map alive, and the
    ## file's index tables if the file is destroyed first. Not copyable.
    m: MapRef

proc `=destroy`*(p: MapPin) =
  # Exported: `Prefetcher`'s destructor (another module) destroys its pin
  # explicitly, and only a visible hook binds to a non-`var` field there.
  if p.m != nil:
    acquire(mapLock)
    dec p.m.pins
    `=destroy`(p.m)
    release(mapLock)

proc `=copy`(dst: var MapPin, src: MapPin) {.error.}
proc `=dup`(src: MapPin): MapPin {.error.}

type
  SeismicFile* = object
    ## A memory-mapped disk file with its trace index.
    index*: TraceIndex
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
    walkLog: int      ## Entries of `index.log` the walk (or the cache) made.
    twos: bool        ## Opened with `twosComplement8015`.
    cached: bool      ## See `fromCache`.

proc `=destroy`(f: SeismicFile) =
  # `f` is passed by reference and this is its last use, so its fields may
  # be moved out (and `TraceIndex` has only the generic `var` destructor).
  let pf = addr f
  if f.map != nil:
    acquire(mapLock)
    if f.map.pins > 0:
      # A prefetcher still reads `entries` and `codecs` through raw pointers:
      # hand them to the map it keeps alive. A seq move keeps the payload's
      # address, so nothing is copied and the pointers stay valid.
      f.map.parkedEntries = move pf[].index.entries
      f.map.parkedCodecs = move pf[].index.codecs
      f.map.parkedKeys = move pf[].index.keys
    `=destroy`(f.map)
    release(mapLock)
  `=destroy`(pf[].index)
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

proc loadIndex(f: var SeismicFile, cache: string, keys: bool, verify: VerifyMode): string
  {.raises: [].}

proc resolveLayout(f: var SeismicFile) =
  # The SEG-Y layout plan of the index just made (see `gr`).
  if f.index.kind == skSegy and f.index.detected: f.gr = initGeometryReader(f.index.segy)

proc openMapped(path: string, twosComplement8015, keys, writable: bool,
    demuxDir: string, progress: Progress = nil, cache = "", verify = vfSampled,
    forced = skUnknown): SeismicFile =
  # `openSeismic` / `openSeismicRw`. Built in a local, so a raise (a
  # cancelled walk) unmaps the file.
  var f = SeismicFile(path: path, map: MapRef(src: openMemFileSource(path, writable)),
    twos: twosComplement8015)
  f.stamp = stampOf(path)
  var why = ""
  if cache.len > 0:
    why = f.loadIndex(cache, keys, verify)
    if why.len == 0 and forced != skUnknown and f.index.kind != forced:
      # The cache was saved from another reading of the file than the one
      # the caller names (`OpenOptions.kind`).
      why = "it holds the index of another standard than the one asked for"
      f.index = TraceIndex()
    if why.len == 0:
      f.cached = true
      f.walkLog = f.index.log.len
      f.resolveLayout()
      var tk = initProgressTicker(progress, f.map.src.size)
      if not tk.finish(): raiseCancelled()
      return f
  let n = int(min(f.map.src.size, 8192))
  let kind =
    if forced != skUnknown: forced # `OpenOptions.kind`: the caller knows the standard
    elif n > 0: detectKind(f.map.src.memory.toOpenArray(0, n - 1))
    else: skUnknown
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
  f.resolveLayout()
  if cache.len > 0:
    f.index.log.report(sevInfo, dcIndexCache, "the index cache " & cache & " was not used (" &
      why & "); the file was indexed", 0, Location(file: path))
  f

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
    opts.verify, opts.kind)

proc openSeismicRw*(path: string): SeismicFile =
  ## **Internal** (`openEditor`; not exported by `parseSEG`). `openSeismic`
  ## mapped read-write. Raises `ValueError` for multiplexed SEG-D: edits
  ## would change only the demultiplexed copy.
  openMapped(path, false, false, true, "")

proc parkAndDrop(f: var SeismicFile, next: sink MapRef) =
  # Replaces the file's map by `next` (nil: none). When prefetchers pin the
  # old map, they (and their chunks' `TraceRows`) read the index tables
  # through raw pointers: the payloads of `entries`, `codecs` and `keys` move
  # to the map the pins keep alive, and the file gets copies, so that
  # nothing it frees or changes later is read by them. `next` has no pins
  # yet, so this is the only moment to park them.
  var old: MapRef
  acquire(mapLock)
  if f.map.pins > 0:
    f.map.parkedEntries = move f.index.entries
    f.map.parkedCodecs = move f.index.codecs
    f.map.parkedKeys = move f.index.keys
    old = f.map
  f.map = next
  release(mapLock)
  if old != nil:
    # Copied outside the lock (10 ms per 500 000 traces with keys); `old`
    # keeps the parked tables alive meanwhile, whatever the pins do.
    f.index.entries = old.parkedEntries
    f.index.codecs = old.parkedCodecs
    f.index.keys = old.parkedKeys
    acquire(mapLock)
    old = nil
    release(mapLock)

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
  if f.demuxPath.len > 0:
    raise newException(ValueError, f.path & " holds multiplexed SEG-D, which cannot be " &
      "edited in place; convert it to a demultiplexed file first (`parseseg convert " &
      "--to=segd`, `convertSegdRevision`) and edit that")
  let m = MapRef(src: openMemFileSource(f.path, writable = true)) # unmapped on a raise
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
    own: GeometryReader ## SEG-Y: a plan made for this call (`useOwn`).
    useOwn: bool
      ## The file's plan (`gr`) does not fit its SEG-Y description any more
      ## (code replaced `index.segy` or the whole index): resolve it again.
    timeBasis: int16 ## SEG-Y: the binary header's values now (an editor may change them).
    fixedUs: float64
    segd: array[SegdLayout, SegdTrace]

proc initKeyReader(f: SeismicFile): KeyReader =
  case f.index.kind
  of skSegy:
    result.useOwn = not f.gr.planFits(f.index.segy)
    if result.useOwn: result.own = initGeometryReader(f.index.segy)
    result.timeBasis = timeBasisOf(f.index.segy)
    result.fixedUs = fixedIntervalUs(f.index.segy)
  of skSegd: result.segd = [SegdTrace(layout: slRev2), SegdTrace(layout: slRev3)]
  else: discard

template segyPlan(f: SeismicFile, r: KeyReader): ptr GeometryReader =
  # The layout plan the call reads SEG-Y keys with; a pointer, as choosing
  # between the two by value would copy the plan (30 allocations).
  (if r.useOwn: addr r.own else: addr f.gr)

func segyPlanFits(f: SeismicFile): bool {.inline.} =
  # A SEG-Y file whose layout plan (`gr`) is still that of `index.segy`.
  f.index.kind == skSegy and f.gr.planFits(f.index.segy)

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
  let fixed = fixedIntervalUs(f.index.segy)
  if not fixed.isNaN: return fixed
  var h: RawHeaders
  if not mappedSegyHeaders(f.unsafeMemory, f.mappedSize, f.index.entries[trace], h): NaN
  else: segyIntervalUs(h, f.index.segy.byteOrder, NaN)

proc keysOf(f: SeismicFile, r: var KeyReader, mem: ptr UncheckedArray[byte], size: int64,
    trace: int): TraceKeys =
  # The keys of `trace` from its mapped headers, as the index walk makes them.
  template ix: untyped = f.index
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
    for k in 0 ..< count: dst[k] = f.index.keys[traceAt(k)]
  elif count > 0:
    f.requireOpen()
    let mem = f.unsafeMemory
    let size = f.mappedSize
    if f.segyPlanFits:
      # SEG-Y with the file's own plan: no per-call reader to set up (100 ns
      # of a 400 ns call for one trace).
      let timeBasis = timeBasisOf(f.index.segy)
      let fixedUs = fixedIntervalUs(f.index.segy)
      for k in 0 ..< count:
        let trace = traceAt(k)
        var h: RawHeaders
        if not mappedSegyHeaders(mem, size, f.index.entries[trace], h): raiseOutside(trace)
        dst[k] = segyKeys(f.gr, h, timeBasis, fixedUs)
    else:
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

proc ensureKeys*(f: var SeismicFile, progress: Progress = nil) =
  ## Builds the stored keys of a file opened without them, exactly as
  ## `openSeismic(keys = true)` would (from the mapped headers, also for an
  ## index loaded from a cache), and bumps `keysRevision`; does nothing when
  ## the file has them. A viewer can open a large file fast and build keys
  ## when geometry is first needed. `progress` reports the trace header
  ## bytes read; when it cancels, `SegCancelledError` is raised and the file
  ## stays without keys. Raises `ValueError` for a closed file or headers
  ## that lie outside it.
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
  let n = f.len
  let mem = f.unsafeMemory
  let size = f.mappedSize
  var r = initKeyReader(f)
  var tick = initProgressTicker(progress, size)
  var keys = newSeq[TraceKeys](n)
  for i in 0 ..< n:
    keys[i] = f.keysOf(r, mem, size, i)
    if not tick.tick(f.index.entries[i].offset): raiseCancelled()
  if not tick.finish(): raiseCancelled()
  f.index.keys = move keys
  inc f.index.keysRevision

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
  let mem = f.unsafeMemory
  let size = f.mappedSize
  var r = initKeyReader(f)
  for t in traces:
    if t < 0 or t >= f.len: continue
    var k: TraceKeys
    try: k = f.keysOf(r, mem, size, t)
    except ValueError: continue
    k.keepJoined(f.index.keys[t], f.index.joinedGroups(t))
    if not sameKeys(k, f.index.keys[t]):
      f.index.keys[t] = k
      result = true
  if result: inc f.index.keysRevision

proc refreshSegyInterval*(f: var SeismicFile) =
  ## **Internal** (`HeaderEditor`). `index.segyIntervalUs` after an edit of
  ## an interval field: the binary header's for a fixed-length file, else the
  ## one every stored key agrees on (NaN when they differ); kept as it was
  ## for a file without stored keys whose traces give their own.
  if f.index.kind != skSegy: return
  let fixed = fixedIntervalUs(f.index.segy)
  if not fixed.isNaN:
    f.index.segyIntervalUs = fixed
  elif f.hasKeys and f.len > 0:
    let dt = f.index.keys[0].intervalUs
    var same = true
    for k in f.index.keys:
      if k.intervalUs != dt: same = false
    f.index.segyIntervalUs = if same: dt else: NaN

func keysRevision*(f: SeismicFile): int {.inline.} =
  ## 0 as opened; goes up whenever the stored keys change (`ensureKeys`,
  ## `applyGeometry`, `applySurvey`, `HeaderEditor` writes). Tag data
  ## derived from keys (moveout overlays, binning) with it and rebuild it
  ## when the revision changes. Views and prefetchers made while the file
  ## had stored keys read them in place and so see every later change; those
  ## made before `ensureKeys` have no keys and must be made again (see
  ## `ensureKeys`).
  f.index.keysRevision

template t0Loop(f: SeismicFile, dst: var openArray[float64], count: int, traceAt: untyped) =
  if dst.len != count:
    raise newException(ValueError, "need " & $count & " values, got " & $dst.len)
  if f.hasKeys:
    for k in 0 ..< count: dst[k] = f.index.keys[traceAt(k)].t0Ms
  elif count > 0:
    f.requireOpen()
    let mem = f.unsafeMemory
    let size = f.mappedSize
    if f.segyPlanFits:
      # SEG-Y: only the delay is read, not the whole key.
      for k in 0 ..< count:
        let trace = traceAt(k)
        var h: RawHeaders
        if not mappedSegyHeaders(mem, size, f.index.entries[trace], h): raiseOutside(trace)
        dst[k] = segyStartTimeMs(f.gr, h)
    else:
      var r = initKeyReader(f)
      for k in 0 ..< count: dst[k] = f.keysOf(r, mem, size, traceAt(k)).t0Ms

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
    log: var DiagLog, T: typedesc, failedRows: untyped = nil): int =
  # Decodes `count` traces: samples `first ..< first + cols` of trace
  # `traceAt(k)` into row pointer `rowAt(k)`. With `failedRows` (a `ptr
  # seq[int]`), the list is cleared (its capacity kept) and gets the `k` of
  # each trace left zero, instead of a report in `log`.
  var failed = 0
  when failedRows isnot typeof(nil): failedRows[].setLen 0
  let mem = f.unsafeMemory
  let size = f.mappedSize
  for k in 0..<count:
    let i = traceAt(k)
    let e = f.index.entries[i]
    let p = rowAt(k)
    let st = tryDecodeEntry(mem, size, e, f.index.codecs[e.record], p, cols, first)
    if st != dsOk:
      for c in 0..<cols: p[c] = T(0)
      when failedRows isnot typeof(nil):
        failedRows[].add k
      else:
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
  # `row <= shape[0] - count`, not `row + count <= shape[0]`: the sum can overflow.
  if not (dst.rank == 2 and dst.is_C_contiguous and row >= 0 and row <= dst.shape[0] - count):
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
    log: var DiagLog, row = 0): int =
  ## Decodes `traces` into rows `row ..< row + traces.len` of `dst` (a
  ## row-major `[rows, samples]` tensor), each truncated or zero-padded to
  ## `dst.shape[1]`. A trace that cannot be decoded is left zero, logged in
  ## `log`, and counted in the result. Raises `ValueError` for traces outside
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
  decodeLoop(f, count, trace, rowOf, dst.shape[1], 0, log, T)

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
  decodeLoop(f, traces.len, trace, rowOf, dst.shape[1], 0, log, T)

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
  decodeLoop(f, count, trace, rowOf, dst.shape[1], samples.a, log, T)

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
  decodeLoop(f, traces.len, trace, rowOf, dst.shape[1], samples.a, log, T)

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
  decodeLoop(f, count, trace, rowOf, dst.shape[1], 0, log, T, addr failedRows)

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
  decodeLoop(f, traces.len, trace, rowOf, dst.shape[1], 0, log, T, addr failedRows)

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
  decodeLoop(f, count, trace, rowOf, dst.shape[1], samples.a, log, T, addr failedRows)

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
  decodeLoop(f, traces.len, trace, rowOf, dst.shape[1], samples.a, log, T, addr failedRows)

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

# ------------------------------------------------------------ index cache --
# The file format is `private/indexcache`.

proc cacheKey(f: SeismicFile): CacheKey =
  CacheKey(path: f.path, stamp: f.stamp, mem: f.unsafeMemory, size: f.mappedSize,
    twos: f.twos)

proc loadIndex(f: var SeismicFile, cache: string, keys: bool, verify: VerifyMode): string
    {.raises: [].} =
  # Reads `f.index` from the cache `cache`: "" when done, else why not
  # (then `f.index` is unchanged).
  readIndexCache(cache, f.cacheKey, keys, verify, f.index)

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
  writeIndexCache(path, f.cacheKey, f.index, f.walkLog, f.hasKeys)
