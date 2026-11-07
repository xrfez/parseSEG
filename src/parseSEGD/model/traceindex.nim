## Trace index: a header-only walk over a SEG-Y or SEG-D stream that records
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
## traces take 240 MB. Header objects are kept per file (SEG-Y) or per record
## (SEG-D), never per trace.
##
## `openSeismic` maps a disk file with `std/memfiles` and keeps the map, so
## range reads decode straight from the mapped bytes into the tensor's
## buffer (`decodeEntry`), with no intermediate copy. The OS pages the file
## in on demand, and all offsets are 64-bit, so files larger than RAM work.

import ../common/[endians, errors, diagnostics, bcd]
import ../io/[records, memsource]
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader]
import ./[tensors, keys]

export memsource, tensors, diagnostics, keys

type
  SeismicKind* = enum
    skSegy = "SEG-Y"
    skSegd = "SEG-D"

  TraceEntry* = object
    ## Where one trace lives (24 bytes).
    offset*: int64       ## Medium offset of the trace header.
    headerBytes*: uint32 ## Header bytes before the samples (incl. extensions).
    numSamples*: uint32
    record*: uint32      ## SEG-D record index (0 for SEG-Y); indexes `codecs`.
    channelSet*: uint16
      ## 0-based SEG-D channel set index, `NoChannelSet` if unknown (and for
      ## SEG-Y); see `channelSetIndex`.
    scanType*: int8      ## 0-based SEG-D scan type index (BCD, < 100), -1 if unknown (SEG-Y).
    channelType*: uint8
      ## SEG-D channel type of the trace's channel set (Rev 1/2 nibble, 1 =
      ## seismic; Rev 3 byte, 0x10 = seismic); 0 for SEG-Y and unknown sets.

  TraceCodec* = object
    ## How the samples of one SEG-Y file or SEG-D record are encoded.
    kind*: SeismicKind
    known*: bool                  ## The format is decodable.
    segyFormat*: SampleFormat     ## SEG-Y format, when `kind == skSegy`.
    order*: ByteOrder             ## SEG-Y byte order.
    segdFormat*: SegdSampleFormat ## SEG-D format, when `kind == skSegd`.
    twosComplement8015*: bool     ## SEG-D 8015 read as two's complement.

  TraceIndex* = object
    ## Every trace's location plus the file-level headers.
    kind*: SeismicKind
    entries*: seq[TraceEntry]
    codecs*: seq[TraceCodec]  ## One per SEG-D record; one for SEG-Y.
    contiguous*: bool
      ## Offsets are byte offsets in a plain file, so each trace's headers and
      ## samples are contiguous there (false for tape images and devices).
    maxSamples*: int          ## Largest `numSamples`.
    segy*: SegyFile           ## SEG-Y file headers, when `kind == skSegy`.
    segdLabel*: SegdStorageUnitLabel
    hasSegdLabel*: bool
    segdRecords*: seq[SegdRecord] ## SEG-D record headers and trailers, by record index.
    segdToc*: seq[SegdToc]    ## SEG-D Rev 3 Table of Contents files met.
    log*: DiagLog             ## Diagnostics of the walk.
    detected*: bool           ## The stream was identified as `kind` and walked.
    keys*: seq[TraceKeys]
      ## Per-trace geometry, parallel to `entries`; empty unless the index was
      ## built with `keys = true` (about 100 bytes per trace).

const NoChannelSet* = 0xFFFF'u16
  ## `TraceEntry.channelSet` of a trace without a known channel set. The
  ## reader allows at most 65535 sets per scan type, so index 65535 is free.

static: doAssert sizeof(TraceEntry) == 24

func channelSetIndex*(e: TraceEntry): int {.inline.} =
  ## The 0-based channel set index, -1 if unknown.
  if e.channelSet == NoChannelSet: -1 else: int(e.channelSet)

func len*(ix: TraceIndex): int {.inline.} = ix.entries.len

func sampleOffset*(e: TraceEntry): int64 {.inline.} =
  ## Medium offset of the trace's first sample byte.
  e.offset + int64(e.headerBytes)

func dataBytes*(c: TraceCodec, samples: int): int =
  ## Bytes holding `samples` samples (0 for an undecodable format).
  if not c.known: 0
  elif c.kind == skSegy: samples * sampleSize(c.segyFormat)
  else: dataBytes(c.segdFormat, samples)

func dataBytes*(ix: TraceIndex, i: int): int {.inline.} =
  ## Sample bytes of trace `i`.
  ix.codecs[ix.entries[i].record].dataBytes(int(ix.entries[i].numSamples))

func prefersFloat64*(ix: TraceIndex): bool =
  ## True when some trace's format would lose precision in float32.
  for c in ix.codecs:
    if c.known and (if c.kind == skSegy: prefersFloat64(c.segyFormat)
                    else: prefersFloat64(c.segdFormat)):
      return true

# ------------------------------------------------------------- detection --

func looksLikeSegdGh1(b: openArray[byte]): bool =
  # General Header #1: BCD file number (or FFFF) in bytes 1-2, a BCD format
  # code 0xxx/8xxx/9xxx in bytes 3-4.
  if b.len < 32: return false
  var f: SegdSampleFormat
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
  fileOk and (toSegdFormat(code, f) or code in [15, 22, 24, 42, 44, 48, 58, 1015, 1022])

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

func detectKind*(head: openArray[byte], kind: var SeismicKind): bool =
  ## Guesses the standard from the first bytes of a stream (pass at least
  ## 3728). SEG-D: a storage unit label or a Table of Contents file. SEG-Y: a
  ## textual header starting with `C` that is mostly printable EBCDIC or
  ## ASCII, possibly after a 128-byte tape label. Otherwise SEG-D if the bytes
  ## are a plausible General Header #1 (a SEG-D file number 43xx starts with
  ## ASCII `C`, but its next 3200 bytes are not text). False if nothing fits.
  result = true
  if isStorageUnitLabel(head) or isTocFile(head):
    kind = skSegd
  elif looksLikeSegy(head, 0) or (head.len >= 6 and head[4] == 0x53 and head[5] == 0x59 and
      looksLikeSegy(head, 128)):
    kind = skSegy
  elif looksLikeSegdGh1(head):
    kind = skSegd
  else:
    result = false

# ------------------------------------------------------------------ walk --

proc indexSegy(src: RecordSource, keys: bool): TraceIndex =
  var r = openSegy(src, headersOnly = true)
  result = TraceIndex(kind: skSegy, contiguous: not src.hasRecordBoundaries)
  result.codecs.add TraceCodec(kind: skSegy, known: r.file.formatKnown,
    segyFormat: r.file.format, order: r.file.byteOrder)
  let gr = if keys: initGeometryReader(r.file) else: GeometryReader()
  var t: SegyTrace
  while r.readTrace(t):
    let hb = TraceHeaderSize + (if t.hasExt1: TraceHeaderSize + t.proprietary.len else: 0)
    result.entries.add TraceEntry(offset: t.offset, headerBytes: uint32(hb),
      numSamples: uint32(t.numSamples), channelSet: NoChannelSet, scanType: -1)
    result.maxSamples = max(result.maxSamples, t.numSamples)
    if keys: result.keys.add gr.traceKeys(t)
  result.segy = r.file
  result.log = r.log

proc channelTypeOf(rec: SegdRecord, t: SegdTrace): uint8 =
  if t.channelSet < 0: 0'u8
  elif rec.isRev3: rec.scanTypes[t.scanType].descriptors3[t.channelSet].channelType
  else: rec.scanTypes[t.scanType].descriptors[t.channelSet].channelType

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
        scanType: int8(t.scanType), channelType: channelTypeOf(r.record, t))
      result.maxSamples = max(result.maxSamples, t.numSamples)
      if keys: result.keys.add traceKeys(r.record, t)
    result.codecs.add TraceCodec(kind: skSegd, known: r.record.formatKnown,
      segdFormat: r.record.format, twosComplement8015: twosComplement8015)
    result.segdRecords.add r.record
  result.segdLabel = r.label
  result.hasSegdLabel = r.hasLabel
  result.segdToc = r.toc
  result.log = r.log

proc buildIndex*(src: RecordSource, kind: SeismicKind, twosComplement8015 = false,
    keys = false): TraceIndex =
  ## Walks the stream at the current position of `src` with headers only and
  ## indexes every trace; with `keys`, also collects each trace's geometry
  ## (for `gathers` and `componentGroups`). Problems go to `log`, as with the
  ## readers.
  result = case kind
    of skSegy: indexSegy(src, keys)
    of skSegd: indexSegd(src, twosComplement8015, keys)
  result.detected = true

# ---------------------------------------------------------- range decode --

proc decodeEntry*[T: SampleType](mem: ptr UncheckedArray[byte], size: int64, e: TraceEntry,
    c: TraceCodec, dst: ptr UncheckedArray[T], cols: int) =
  ## Decodes trace `e` from the mapped bytes `mem[0 ..< size]` into
  ## `dst[0 ..< cols]`: the first `min(numSamples, cols)` samples, then zeros.
  ## Touches no managed memory, so a worker thread may call it. Raises
  ## `SegFormatError` for an undecodable format and `SegTruncatedError` when
  ## the trace lies past `size`.
  let n = min(int(e.numSamples), cols)
  if not c.known:
    raiseFormat("the sample format is not decodable", e.offset)
  let nbytes = c.dataBytes(int(e.numSamples))
  let start = e.sampleOffset
  if start < 0 or start + nbytes > size:
    raiseTruncated("trace samples lie past the end of the file", start)
  if n > 0:
    let a = int(start)
    if c.kind == skSegy:
      decodeSamples(c.segyFormat, mem.toOpenArray(a, a + nbytes - 1), dst.toOpenArray(0, n - 1),
        c.order)
    else:
      decodeSegdSamples(c.segdFormat, mem.toOpenArray(a, a + nbytes - 1),
        dst.toOpenArray(0, n - 1), c.twosComplement8015)
  for k in n..<cols: dst[k] = T(0)

# ---------------------------------------------------------- seismic file --

type
  SeismicFile* = object
    ## A memory-mapped disk file with its trace index.
    index*: TraceIndex
    path*: string
    map: MemFileSource

proc `=copy`*(dst: var SeismicFile, src: SeismicFile) {.error.}
  # A copy would share the map, and outlive `close` with a dangling view.

proc openSeismic*(path: string, twosComplement8015 = false, keys = false,
    writable = false): SeismicFile =
  ## Maps the disk file `path`, detects SEG-Y or SEG-D, and builds the trace
  ## index (with per-trace geometry when `keys`). Format problems are in `index.log`; an undetectable file gives a
  ## fatal diagnostic and an empty index. Raises `IOError`/`OSError` if the
  ## file cannot be opened or mapped. `writable` maps it read-write, for
  ## in-place header edits (`model/edit`).
  result = SeismicFile(path: path, map: openMemFileSource(path, writable))
  let n = int(min(result.map.size, 8192))
  var kind: SeismicKind
  if n > 0 and detectKind(result.map.memory.toOpenArray(0, n - 1), kind):
    result.index = buildIndex(result.map, kind, twosComplement8015, keys)
  else:
    result.index.contiguous = true
    result.index.log.report(sevFatal, dcUnsupportedFormat,
      "neither a SEG-Y nor a SEG-D file", 0, Location(file: path))

proc close*(f: var SeismicFile) =
  ## Unmaps the file. The index stays usable; range reads do not.
  if f.map != nil:
    f.map.close()
    f.map = nil

func len*(f: SeismicFile): int {.inline.} = f.index.entries.len
func kind*(f: SeismicFile): SeismicKind {.inline.} = f.index.kind
func log*(f: SeismicFile): lent DiagLog {.inline.} = f.index.log

proc memory*(f: SeismicFile): ptr UncheckedArray[byte] {.inline.} =
  ## The mapped bytes (nil after `close`).
  if f.map != nil: f.map.memory else: nil

proc mappedSize*(f: SeismicFile): int64 {.inline.} =
  if f.map != nil: f.map.size else: 0

proc flush*(f: SeismicFile) =
  ## Writes modified pages of a writable map back to the file.
  if f.map != nil: f.map.flush()

proc rowPtr[T](t: Tensor[T], row: int): ptr UncheckedArray[T] {.inline.} =
  let base = cast[ptr UncheckedArray[T]](t.unsafe_raw_offset())
  cast[ptr UncheckedArray[T]](addr base[row * t.strides[0]])

proc readTracesInto*[T: SampleType](f: SeismicFile, first, count: int, dst: var Tensor[T],
    row = 0, log: var DiagLog): int =
  ## Decodes traces `first ..< first + count` into rows `row ..< row + count`
  ## of `dst` (a row-major `[rows, samples]` tensor), each truncated or
  ## zero-padded to `dst.shape[1]`. A trace that cannot be decoded is left
  ## zero, logged in `log`, and counted in the result.
  doAssert f.memory != nil or count == 0, "the file is closed"
  doAssert f.index.contiguous, "range reads need a plain disk file"
  doAssert first >= 0 and count >= 0 and first + count <= f.len, "trace range out of bounds"
  doAssert dst.rank == 2 and dst.is_C_contiguous and row >= 0 and row + count <= dst.shape[0],
    "need a row-major [traces, samples] tensor with room for the range"
  let cols = dst.shape[1]
  let mem = f.memory
  for k in 0..<count:
    let e = f.index.entries[first + k]
    let p = rowPtr(dst, row + k)
    try:
      decodeEntry(mem, f.mappedSize, e, f.index.codecs[e.record], p, cols)
    except SegError as err:
      for c in 0..<cols: p[c] = T(0)
      log.report(sevError, if err of SegTruncatedError: dcTruncated else: dcUnsupportedFormat,
        err.msg, e.offset, Location(file: f.path, record: int(e.record), trace: first + k))
      inc result

proc readTracesInto*[T: SampleType](f: SeismicFile, first, count: int, dst: var Tensor[T],
    row = 0): int {.discardable.} =
  ## As above, without a log; returns the number of undecodable traces.
  var log: DiagLog
  f.readTracesInto(first, count, dst, row, log)

func maxSamples*(f: SeismicFile, s: Slice[int]): int =
  ## Largest sample count in the trace range.
  for i in s: result = max(result, int(f.index.entries[i].numSamples))

proc readTraces*(f: SeismicFile, s: Slice[int], T: typedesc[SampleType] = float32): Tensor[T] =
  ## Traces `s` as a new `[s.len, maxSamples]` tensor (shorter traces are
  ## zero-padded; undecodable ones stay zero).
  result = newTraceTensor[T](s.len, f.maxSamples(s))
  if s.len > 0: f.readTracesInto(s.a, s.len, result)
