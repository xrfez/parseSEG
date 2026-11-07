## The library's foreign boundary (task 12.2): every function of the C ABI and
## of the Python module, each declared once as an ordinary Nim proc with
## `{.segApi.}` (see `abi/segapi.nim` for what it generates and the type
## mapping). Built by `nim lib` (`src/parseSEG/bindings.nim`) with
## `-d:segCapi`, which also writes `include/parseseg.h` and
## `python/parseseg/__init__.py`.
##
## Every proc raises on failure; the generated wrappers translate:
##
## ==================  ====================  ==========================
## Raised              C status              Python exception
## ==================  ====================  ==========================
## `ValueError`        `SEG_ERR_ARGUMENT`    `parseseg.ArgumentError`
## `SegFormatError`    `SEG_ERR_FORMAT`      `parseseg.FormatError`
## `IOError/OSError`   `SEG_ERR_IO`          `parseseg.IOError`
## `AbiStateError`     `SEG_ERR_STATE`       `parseseg.StateError`
## `AbiRefusedError`   `SEG_ERR_REFUSED`     `parseseg.RefusedError`
## `AbiMemoryError`    `SEG_ERR_MEMORY`      `MemoryError`
## `LoggedError`       its status            its class, with `.diagnostics`
## `AbiEnd`            `SEG_END`             returns `None`
## `AbiNotReady`       `SEG_NOT_READY`       returns `None`
## ==================  ====================  ==========================
##
## Not part of the public Nim API: Nim code uses the umbrella module directly.

import std/[math, strutils, tables]
import ../common/[endians]
import ../model/[traceindex, keys, gathers, prefetch, headerfields, edit]
import ../convert as segyconvert
import ../segd/[revconvert, reader as segdreader]
import ../segy/[textheader, binheader]
import ../survey/[sps, p1, join]
import ./segapi

export segapi

const
  AbiVersion* = 2'i32 ## `SEG_ABI_VERSION`; bump on any incompatible C change.
  PackageVersion* = "0.2.0"
  MaxSelection* = 1'i64 shl 34 ## Longest trace list accepted.
  MaxBufferBytes* = 1'i64 shl 40 ## Largest tensor or prefetch ring the library allocates.
  MaxChunkTraces* = 1'i64 shl 24 ## Largest prefetch chunk.
  MaxDepth* = 1024'i64 ## Most prefetch ring slots.
  ModuleDoc = """Read, index, edit and convert SEG-Y and SEG-D seismic data.

    import parseseg
    with parseseg.open("line.sgy") as f:
        samples = f.read(0, 100).numpy()   # zero-copy, float32 [100, ns]
"""

type
  Dtype* {.size: 4.} = enum ## Sample type of a tensor.
    dtF32 = (1, "float32"), dtF64 = (2, "float64")

  FileKind* {.size: 4.} = enum ## What `open` found.
    fkUnknown = (0, "unknown"), fkSegy = (1, "segy"), fkSegd = (2, "segd")

  FileObj* = ref object of AbiHandle
    f*: SeismicFile
    gathers: seq[Gather]
    gathersDone: bool

  TensorObj* = ref object of AbiHandle
    dt*: Dtype
    t32*: Tensor[float32]
    t64*: Tensor[float64]
    shape*, strides*: array[2, int64] ## stable storage for DLPack pointers

  PrefetchObj* = ref object of AbiHandle
    file*: FileObj ## keeps the map alive
    dt*: Dtype
    p32*: Prefetcher[float32]
    p64*: Prefetcher[float64]

  EditorObj* = ref object of AbiHandle
    ed*: HeaderEditor

  GeometryObj* = ref object of AbiHandle
    s*: SurveyGeometry ## Station coordinates and SPS relations.
    names*: LineNames  ## How text line names become numbers.

  GatherInfo* = object
    ## A gather: the traces `first ..< first + count`.
    kind*: GatherKind
    first*, count*: int64
    sources*: int64   ## distinct known sources among its seismic traces
    receivers*: int64 ## distinct known receiver stations among its seismic traces

  DiagEntry* = object
    ## One diagnostic; its strings belong to the log. -1 = not applicable.
    severity*: Severity
    code*: DiagCode
    offset*, record*, channelSet*, trace*, blockIndex*: int64
    file*, field*, message*: cstring

  SurveyCounts* = object
    sources*, receivers*, relations*: int64

  TensorView* = object
    ## `data[r * strides[0] + c * strides[1]]` is row r, sample c.
    data*: pointer
    dtype*: Dtype
    rank*: int32
    shape*, strides*: array[2, int64] ## in elements

  Chunk* = object
    ## One prefetched chunk; `samples` is owned by the caller.
    first*, count*, failed*: int64
    samples*: TensorObj

  SampleBuffer* = object
    ## The caller's 2-D buffer: row r starts at element `r * rowStride`.
    data*: pointer
    dtype*: Dtype
    rows*, cols*, rowStride*: int64

  # DLPack v0.8 (dlpack.h), unversioned `DLManagedTensor`.
  DLDevice {.bycopy.} = object
    deviceType, deviceId: int32
  DLDataType {.bycopy.} = object
    code, bits: uint8
    lanes: uint16
  DLTensor {.bycopy.} = object
    data: pointer
    device: DLDevice
    ndim: int32
    dtype: DLDataType
    shape, strides: ptr int64
    byteOffset: uint64
  DLManagedTensor {.bycopy.} = object
    dlTensor: DLTensor
    managerCtx: pointer
    deleter: proc (self: ptr DLManagedTensor) {.cdecl.}

segHandle(FileObj, "SegFile", "SeismicFile", "a memory-mapped file and its trace index")
segHandle(TensorObj, "SegTensor", "Samples", "a 2-D sample array owned by the library")
segHandle(PrefetchObj, "SegPrefetch", "Prefetch", "read-ahead on a worker thread")
segHandle(EditorObj, "SegEditor", "Editor", "in-place header edits with an undo journal")
segHandle(GeometryObj, "SegGeometry", "Geometry", "source/receiver coordinates by station")
segHandle(LogObj, "SegLog", "Log", "a list of diagnostics")

segStruct(GatherInfo, "SegGather")
segStruct(DiagEntry, "SegDiagnostic")
segStruct(Chunk, "SegChunk")

segLayout(DLManagedTensor, "DLManagedTensor", [("managerCtx", "manager_ctx"),
  ("deleter", "deleter")])

segEnum(Dtype, "SEG_DTYPE")
segEnum(FileKind, "SEG_KIND")
segEnum(GatherKind, "SEG_GATHER")
segEnum(Severity, "SEG_SEVERITY")
segEnum(DiagCode, "SEG_CODE")
segEnum(ByteOrder, "SEG_BYTE_ORDER")
segEnum(TextEncoding, "SEG_TEXT")

# ---------------------------------------------------------------- helpers --

proc raiseState(msg: string) {.noinline, noreturn.} =
  raise newException(AbiStateError, msg)

proc raiseArg(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>", cdecl, gcsafe,
    raises: [].}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}

var mallocProbe {.volatile.}: proc (size: csize_t): pointer {.cdecl, gcsafe, raises: [].} =
  cMalloc
  # Called through a volatile pointer: clang may otherwise drop an unused
  # malloc/free pair and assume the allocation succeeded.

proc canAllocate(bytes: int64): bool =
  # Nim's allocator terminates the process when the system refuses memory, so
  # a large buffer is first probed with malloc/free.
  if bytes < 64 shl 20: return true
  let p = mallocProbe(csize_t(bytes))
  result = p != nil
  if result: cFree(p)

func fitsBuffer(rows, cols, elem: int64): bool =
  ## rows × cols × elem ≤ MaxBufferBytes, without overflowing.
  rows >= 0 and cols >= 0 and (rows == 0 or cols == 0 or
    cols <= MaxBufferBytes div elem div rows)

func elemSize(d: Dtype): int64 = (if d == dtF32: 4 else: 8)

func rangeOk(first, count, n: int64): bool =
  first >= 0 and count >= 0 and first <= n and count <= n - first

proc newTensorObj[T](t: sink Tensor[T]): TensorObj =
  when T is float32: TensorObj(dt: dtF32, t32: t)
  else: TensorObj(dt: dtF64, t64: t)

func len(f: FileObj): int64 = int64(f.f.len)

proc checkTrace(f: FileObj, i: int64) =
  if i < 0 or i >= f.len: raiseArg("no trace " & $i)

proc requireKeys(f: FileObj) =
  if f.f.index.keys.len != f.f.len: raiseState("open the file with keys")

proc checkRead(f: FileObj) =
  if not f.f.isOpen and f.f.len > 0: raiseArg("the file is not mapped")
  if not f.f.index.contiguous: raiseArg("range reads need a plain disk file")

proc resolveCount(f: FileObj, first, count: int64): int64 =
  ## count -1: to the end; other negative counts are refused.
  if count < -1: raiseArg("count must be >= -1")
  if count == -1 and first >= 0: max(0'i64, f.len - first) else: count

proc rangeSelection(f: FileObj, first, count: int64): seq[int] =
  if not rangeOk(first, count, f.len): raiseArg("trace range out of bounds")
  result = newSeq[int](count)
  for k in 0..<int(count): result[k] = int(first) + k

proc listSelection(f: FileObj, traces: openArray[int64]): seq[int] =
  ## Every entry is checked before anything is allocated.
  const bad = "the selection holds a trace out of bounds"
  if traces.len > MaxSelection: raiseArg(bad)
  for t in traces:
    if t < 0 or t >= f.len: raiseArg(bad)
  result = newSeq[int](traces.len)
  for k, t in traces: result[k] = int(t)

proc readNew(f: FileObj, sel: seq[int], dtype: Dtype, cols: int64): TensorObj =
  if cols < -1: raiseArg("cols must be >= -1")
  let width = if cols >= 0: int(cols) else: f.f.maxSamples(sel)
  if not fitsBuffer(int64(sel.len), int64(width), elemSize(dtype)):
    raiseArg("rows x cols exceeds the library's buffer limit (1 TiB)")
  if not canAllocate(int64(sel.len) * int64(width) * elemSize(dtype)):
    raise newException(AbiMemoryError, "out of memory")
  template go(T: typedesc) =
    var t = newTraceTensor[T](sel.len, width)
    if sel.len > 0: discard f.f.readTracesInto(sel, t)
    result = newTensorObj(t)
  if dtype == dtF32: go(float32) else: go(float64)

proc readIntoBuffer(f: FileObj, sel: seq[int], b: SampleBuffer): int64 =
  if b.rows != int64(sel.len): raiseArg("the buffer has " & $b.rows & " rows, not " & $sel.len)
  if b.cols < 0 or b.rowStride < b.cols or (b.rows > 0 and b.data == nil) or
      not fitsBuffer(b.rows, b.rowStride, elemSize(b.dtype)):
    raiseArg("need cols >= 0, row_stride >= cols and a buffer")
  var log: DiagLog
  int64(if b.dtype == dtF32:
          f.f.readTracesRaw(sel, cast[ptr UncheckedArray[float32]](b.data), int(b.cols),
            int(b.rowStride), log)
        else:
          f.f.readTracesRaw(sel, cast[ptr UncheckedArray[float64]](b.data), int(b.cols),
            int(b.rowStride), log))

template withTensor(to: TensorObj, t, body: untyped) =
  if to.dt == dtF32:
    template t: untyped = to.t32
    body
  else:
    template t: untyped = to.t64
    body

proc refreshShape(to: TensorObj) =
  withTensor(to, t):
    for d in 0..1:
      to.shape[d] = int64(t.shape[d])
      to.strides[d] = int64(t.strides[d])

proc dataPointer(to: TensorObj): pointer =
  withTensor(to, t):
    result = if t.size > 0: cast[pointer](t.unsafe_raw_offset()) else: nil

proc dlpackDeleter(self: ptr DLManagedTensor) {.cdecl.} =
  try:
    if self != nil:
      if self.managerCtx != nil: GC_unref(cast[TensorObj](self.managerCtx))
      dealloc(self)
  except Exception: discard

proc checkLog(log: DiagLog, status: SegStatus) =
  ## Fails with `status` (and the log) when the operation stopped early.
  if log.isFatal: raiseLogged(status, log[log.len - 1].msg, log)

# ------------------------------------------------------------ the library --

proc abiVersion*(): int32 {.segApi.} =
  ## The library's ABI version (SEG_ABI_VERSION).
  AbiVersion

proc version*(): string {.segApi.} =
  ## The package version, e.g. "0.2.0".
  PackageVersion

proc statusName*(status: int32): string {.segApi.} =
  ## The name of a status code ("SEG_OK", "SEG_ERR_IO", ...).
  case status
  of SEG_OK: "SEG_OK"
  of SEG_END: "SEG_END"
  of SEG_NOT_READY: "SEG_NOT_READY"
  of SEG_ERR_ARGUMENT: "SEG_ERR_ARGUMENT"
  of SEG_ERR_IO: "SEG_ERR_IO"
  of SEG_ERR_FORMAT: "SEG_ERR_FORMAT"
  of SEG_ERR_STATE: "SEG_ERR_STATE"
  of SEG_ERR_REFUSED: "SEG_ERR_REFUSED"
  of SEG_ERR_INTERNAL: "SEG_ERR_INTERNAL"
  of SEG_ERR_MEMORY: "SEG_ERR_MEMORY"
  else: "unknown status"

# ------------------------------------------------------------------ files --

proc openFile*(path: string, keys = true, twos8015 = false): FileObj {.
    segApi(c = "seg_file_open", py = "open").} =
  ## Opens and indexes a SEG-Y or SEG-D disk file (memory-mapped, read-only).
  ## `keys` also decodes the per-trace geometry (about 100 bytes per trace),
  ## needed by trace_keys, gathers, component_groups and apply_geometry;
  ## `twos8015` reads SEG-D format 8015 as two's complement. Problems in the
  ## file are diagnostics, not failures.
  var sf = openSeismic(path, twos8015, keys = keys)
  FileObj(f: move sf)

proc kind*(f: FileObj): FileKind {.segApi.} =
  ## What the file is: "segy", "segd" or "unknown" (see the diagnostics).
  if not f.f.index.detected: fkUnknown elif f.f.kind == skSegy: fkSegy else: fkSegd

proc traceCount*(f: FileObj): int64 {.segApi.} =
  ## Traces in the file.
  f.len

proc recordCount*(f: FileObj): int64 {.segApi.} =
  ## SEG-D records; 1 for SEG-Y; 0 if neither.
  if f.f.kind == skSegd: int64(f.f.index.segdRecords.len)
  elif f.f.index.detected: 1 else: 0

proc maxSamples*(f: FileObj): int64 {.segApi.} =
  ## Samples in the longest trace.
  int64(f.f.index.maxSamples)

proc traceEntry*(f: FileObj, trace: int64): TraceEntry {.segApi.} =
  ## Where a trace lives: offset, header_bytes, num_samples, record,
  ## channel_set, scan_type, channel_type.
  f.checkTrace(trace)
  f.f.index.entries[trace]

proc traceKeys*(f: FileObj, trace: int64): TraceKeys {.segApi.} =
  ## A trace's geometry (NaN or 0 where unknown); needs keys.
  f.checkTrace(trace)
  f.requireKeys()
  f.f.index.keys[trace]

proc sampleInterval*(f: FileObj, trace = 0'i64): float64 {.segApi.} =
  ## Microseconds between samples of a trace (Hz or m/ft for SEG-Y non-time
  ## data); NaN when unknown or out of range.
  if trace < 0 or trace > int64(high(int32)) * 1024: NaN
  else: f.f.sampleIntervalUs(int(trace))

proc fileDiagnostics*(f: FileObj): DiagLog {.
    segApi(c = "seg_file_diagnostics", py = "diagnostics").} =
  ## Every problem found while indexing.
  f.f.index.log

proc logNif*(f: FileObj): string {.segApi.} =
  ## The diagnostics as NIF text.
  f.f.index.log.toNif

template fieldCall(name: string, call: untyped): FieldValue =
  var v {.inject.}: FieldValue
  var err {.inject.}: string
  if not call: raiseArg(name & ": " & err)
  v

proc traceField*(f: FileObj, trace: int64, name: string): FieldValue {.segApi.} =
  ## A trace header field by name, e.g. "trace.sourceX" or "ext1.receiverLine".
  f.checkTrace(trace)
  fieldCall(name, f.f.traceField(int(trace), name, v, err))

proc recordField*(f: FileObj, record: int64, name: string): FieldValue {.segApi.} =
  ## A SEG-D record (general header) field by name, e.g. "gh1.formatCode".
  fieldCall(name, record >= 0 and record <= int64(high(int32)) and
    f.f.recordField(int(record), name, v, err))

proc fileField*(f: FileObj, name: string): FieldValue {.segApi.} =
  ## A file-level field by name, e.g. "binary.formatCode".
  fieldCall(name, f.f.fileField(name, v, err))

# ------------------------------------------------------------------ reads --

proc read*(f: FileObj, first = 0'i64, count = -1'i64, dtype = dtF32, cols = -1'i64): TensorObj {.
    segApi(concurrent).} =
  ## Decodes traces first ..< first + count (count -1: to the end) into new
  ## samples [count, cols] (cols -1: the longest trace; shorter traces are
  ## zero-padded). Reads on one file may run in parallel.
  f.checkRead()
  f.readNew(f.rangeSelection(first, f.resolveCount(first, count)), dtype, cols)

proc readTraces*(f: FileObj, traces: openArray[int64], dtype = dtF32, cols = -1'i64): TensorObj {.
    segApi(concurrent).} =
  ## Decodes the listed traces, in list order, into new samples.
  f.checkRead()
  f.readNew(f.listSelection(traces), dtype, cols)

proc readInto*(f: FileObj, buffer: SampleBuffer, first = 0'i64): int64 {.segApi(concurrent).} =
  ## Decodes traces first ..< first + buffer rows straight into the caller's
  ## buffer (rows padded or cut to its width); returns how many traces could
  ## not be decoded (left zero).
  f.checkRead()
  f.readIntoBuffer(f.rangeSelection(first, buffer.rows), buffer)

proc readTracesInto*(f: FileObj, buffer: SampleBuffer, traces: openArray[int64]): int64 {.
    segApi(concurrent).} =
  ## Decodes the listed traces into the buffer's rows (one per trace).
  f.checkRead()
  f.readIntoBuffer(f.listSelection(traces), buffer)

# ---------------------------------------------------------------- tensors --

proc view*(t: TensorObj): TensorView {.segApi.} =
  ## The samples' memory: pointer, dtype, rank (2), shape and strides in
  ## elements. Valid while the tensor is held.
  t.refreshShape()
  TensorView(data: t.dataPointer, dtype: t.dt, rank: 2, shape: t.shape, strides: t.strides)

proc dtype*(t: TensorObj): Dtype {.segApi.} =
  ## "float32" or "float64".
  t.dt

proc toDlpack*(t: TensorObj): pointer {.segApi(py = "_to_dlpack").} =
  ## A DLManagedTensor sharing the samples; it holds the tensor until the
  ## consumer calls its deleter.
  t.refreshShape()
  let m = create(DLManagedTensor)
  m.dlTensor = DLTensor(data: t.dataPointer, device: DLDevice(deviceType: 1, deviceId: 0),
    ndim: 2, dtype: DLDataType(code: 2, bits: uint8(8 * elemSize(t.dt)), lanes: 1),
    shape: addr t.shape[0], strides: addr t.strides[0], byteOffset: 0)
  GC_ref(t)
  m.managerCtx = cast[pointer](t)
  m.deleter = dlpackDeleter
  m

# ---------------------------------------------------------------- gathers --

proc gathers*(f: FileObj): seq[GatherInfo] {.segApi.} =
  ## Consecutive gathers: kind ("shot", "receiver", "cmp", "offset", "other",
  ## "unknown"), first trace, count, sources and receivers. Needs keys.
  f.requireKeys()
  if not f.gathersDone:
    f.gathers = f.f.index.gathers
    f.gathersDone = true
  for g in f.gathers:
    result.add GatherInfo(kind: g.kind, first: int64(g.traces.a), count: int64(g.traces.len),
      sources: int64(g.sources), receivers: int64(g.receivers))

proc componentGroups*(f: FileObj, first = 0'i64, count = -1'i64): seq[int64] {.segApi.} =
  ## The multi-component group of each trace in first ..< first + count
  ## (count -1: to the end), numbered from 0; -1 for a trace in none. Needs
  ## keys.
  let n = f.resolveCount(first, count)
  f.requireKeys()
  if not rangeOk(first, n, f.len): raiseArg("trace range out of bounds")
  result = newSeq[int64](n)
  for k in 0..<int(n): result[k] = -1
  for g, grp in f.f.index.componentGroups(int(first) ..< int(first + n)):
    for i in grp.traces: result[i - int(first)] = int64(g)

# --------------------------------------------------------------- geometry --

proc newGeometry*(): GeometryObj {.segApi(c = "seg_geometry_new", ctor).} =
  ## An empty table of source/receiver coordinates by (line, point, index).
  GeometryObj()

proc checkIndex(index: int32): int16 =
  if index < int32(low(int16)) or index > int32(high(int16)):
    raiseArg("point index out of range")
  int16(index)

proc addSource*(g: GeometryObj, line, point: float64, index: int32, x, y: float64,
    z = NaN) {.segApi.} =
  ## Adds or replaces a source station; index 0 matches any point index.
  g.s.table.addSource(line, point, checkIndex(index), x, y, z)

proc addReceiver*(g: GeometryObj, line, point: float64, index: int32, x, y: float64,
    z = NaN) {.segApi.} =
  ## Adds or replaces a receiver station; index 0 matches any point index.
  g.s.table.addReceiver(line, point, checkIndex(index), x, y, z)

proc checkSurveyLog(log: DiagLog) =
  if log.isFatal: raise newException(IOError, log[log.len - 1].msg)

proc loadSps*(g: GeometryObj, path: string): DiagLog {.segApi.} =
  ## Adds an SPS file (Rev 1.0 or 2.1): R/S stations and X relations. Returns
  ## the diagnostics; an unreadable file fails with an I/O error.
  let f = readSps(path)
  checkSurveyLog(f.log)
  result = f.log
  g.s.addSps(f, g.names)
  result.add g.s.log
  g.s.log = DiagLog() # returned, not kept

proc loadP1*(g: GeometryObj, path: string, gridDecimals = 0'i64, depthDecimals = 0'i64,
    elevation = false): DiagLog {.segApi.} =
  ## Adds a SEG P1 (1983) file's shotpoints as sources. The decimals are the
  ## implicit decimals of the grid and depth/elevation fields (from the
  ## file's header); with `elevation`, columns 62-66 are z.
  if gridDecimals notin 0..8 or depthDecimals notin 0..8: raiseArg("decimals must be 0-8")
  let f = readP1(path, P1Options(gridDecimals: int(gridDecimals),
    depthDecimals: int(depthDecimals)))
  checkSurveyLog(f.log)
  result = f.log
  g.s.addP1(f, g.names, elevation)
  result.add g.s.log
  g.s.log = DiagLog()

proc mapLine*(g: GeometryObj, name: string, line: float64) {.segApi.} =
  ## Maps a text line name (SPS 1.0, P1) to a line number, for later loads.
  if name.len == 0: raiseArg("empty line name")
  if line.isNaN: raiseArg("line number is NaN")
  g.names.names[name] = line

proc setOptions*(g: GeometryObj, trailingDigits = false, multiComponent = false) {.segApi.} =
  ## `trailing_digits`: unmapped line names use their trailing digits
  ## ("CLT4960" -> 4960). `multi_component`: an SPS channel increment k > 1
  ## means k components per station. Applies to later loads and joins.
  g.names.trailingDigits = trailingDigits
  g.s.multiComponent = multiComponent

proc counts*(g: GeometryObj): SurveyCounts {.segApi.} =
  ## The sources, receivers and SPS relation runs held.
  SurveyCounts(sources: int64(g.s.table.sources.len), receivers: int64(g.s.table.receivers.len),
    relations: int64(g.s.relationCount))

proc applyGeometry*(f: FileObj, geometry: GeometryObj, overwrite = false): int64 {.segApi.} =
  ## Fills the trace keys (in memory only; the file is not changed) from the
  ## geometry: stations from SPS relations, then coordinates, offsets and
  ## midpoints. Returns how many traces changed. Needs keys.
  f.requireKeys()
  result = int64(f.f.index.applySurvey(geometry.s, overwrite))
  f.gathersDone = false # sources and receivers may now be told apart

# --------------------------------------------------------------- prefetch --

proc checkRing(f: FileObj, chunkTraces, depth, cols, width: int64, dtype: Dtype) =
  if chunkTraces <= 0 or depth <= 0 or chunkTraces > MaxChunkTraces or depth > MaxDepth or
      cols < -1:
    raiseArg("need 0 < chunk_traces <= 2^24, 0 < depth <= 1024, cols >= -1")
  let rows = max(1'i64, min(chunkTraces, f.len))
  if not (width >= 0 and depth <= MaxBufferBytes div max(1'i64, rows) and
      fitsBuffer(depth * rows, width, elemSize(dtype)) and
      canAllocate(depth * rows * width * elemSize(dtype))):
    raiseArg("depth x chunk x cols exceeds the library's buffer limit (1 TiB)")

proc prefetch*(f: FileObj, first = 0'i64, last = -1'i64, chunkTraces = 256'i64, depth = 4'i64,
    cols = -1'i64, dtype = dtF32): PrefetchObj {.segApi.} =
  ## Decodes traces first ..< last (last -1: to the end) ahead, in chunks of
  ## chunk_traces rows, on a worker thread with depth chunks buffered.
  f.checkRead()
  let stop = if last < 0: f.len else: last
  if first < 0 or first > stop or stop > f.len: raiseArg("trace range out of bounds")
  let w = if cols >= 0: cols
          elif first < stop: int64(f.f.maxSamples(int(first) ..< int(stop)))
          else: 0
  f.checkRing(chunkTraces, depth, cols, w, dtype)
  result = PrefetchObj(file: f, dt: dtype)
  if dtype == dtF32:
    result.p32 = newPrefetcher[float32](f.f, int(first), int(stop), int(chunkTraces),
      int(depth), int(cols))
  else:
    result.p64 = newPrefetcher[float64](f.f, int(first), int(stop), int(chunkTraces),
      int(depth), int(cols))

proc prefetchTraces*(f: FileObj, traces: openArray[int64], chunkTraces = 256'i64,
    depth = 4'i64, cols = -1'i64, dtype = dtF32): PrefetchObj {.segApi.} =
  ## Like prefetch, over a trace list (positions index the list).
  f.checkRead()
  var sel = f.listSelection(traces)
  f.checkRing(chunkTraces, depth, cols,
    (if cols >= 0: cols else: int64(f.f.maxSamples(sel))), dtype)
  result = PrefetchObj(file: f, dt: dtype)
  if dtype == dtF32:
    result.p32 = newPrefetcher[float32](f.f, move sel, int(chunkTraces), int(depth), int(cols))
  else:
    result.p64 = newPrefetcher[float64](f.f, move sel, int(chunkTraces), int(depth), int(cols))

proc take(p: PrefetchObj, wait: bool): Chunk =
  template body(pf: untyped, T: typedesc) =
    var c: PrefetchChunk[T]
    if (if wait: pf.next(c) else: pf.tryNext(c)):
      return Chunk(first: int64(c.first), count: int64(c.count), failed: int64(c.failed),
        samples: newTensorObj(move c.samples))
    elif pf.atEnd: raise newException(AbiEnd, "no more chunks")
    else: raise newException(AbiNotReady, "the next chunk is not ready")
  if p.dt == dtF32: body(p.p32, float32) else: body(p.p64, float64)

proc next*(p: PrefetchObj): Chunk {.segApi.} =
  ## The next chunk, waiting for it: first (position), count, failed rows
  ## (left zero) and the samples. SEG_END (Python: None) after the last.
  p.take(wait = true)

proc tryNext*(p: PrefetchObj): Chunk {.segApi.} =
  ## The next chunk if it is decoded already, else SEG_NOT_READY (Python:
  ## None); SEG_END after the last.
  p.take(wait = false)

proc atEnd*(p: PrefetchObj): bool {.segApi.} =
  ## True once every chunk has been taken.
  if p.dt == dtF32: p.p32.atEnd else: p.p64.atEnd

proc positions*(p: PrefetchObj): int64 {.segApi.} =
  ## Positions in the prefetcher: traces, or the trace list's length.
  int64(if p.dt == dtF32: p.p32.positions else: p.p64.positions)

proc seek*(p: PrefetchObj, first: int64, last = -1'i64) {.segApi.} =
  ## Restarts at positions first ..< last (last -1: to the end).
  let n = p.positions
  let stop = if last < 0: n else: last
  if first < 0 or first > stop or stop > n: raiseArg("position range out of bounds")
  if p.dt == dtF32: p.p32.seek(int(first), int(stop))
  else: p.p64.seek(int(first), int(stop))

proc traceAt*(p: PrefetchObj, position: int64): int64 {.segApi.} =
  ## The trace at a position, or -1.
  if position < 0 or position >= p.positions: -1
  elif p.dt == dtF32: int64(p.p32.traceAt(int(position)))
  else: int64(p.p64.traceAt(int(position)))

proc close*(p: PrefetchObj) {.segApi.} =
  ## Stops and joins the worker (releasing the handle does too).
  p.p32.close()
  p.p64.close()

# ---------------------------------------------------------------- editing --

proc editorOpen*(path: string, journal = ""): EditorObj {.
    segApi(c = "seg_editor_open", py = "open_editor").} =
  ## Opens a file for in-place, size-preserving header edits, journaled to
  ## `journal` (default: path + ".edits.nif") so they can be undone. This
  ## changes the file; reading never does.
  var ed = openEditor(path, journal)
  EditorObj(ed: move ed)

template editCall(e: EditorObj, name: string, call: untyped) =
  let before = e.ed.log.len
  if not call:
    raise newException(AbiRefusedError,
      if e.ed.log.len > before: e.ed.log[e.ed.log.len - 1].msg else: name & ": refused")

proc setTrace*(e: EditorObj, trace: int64, name: string, value: FieldValue) {.segApi.} =
  ## Sets a trace header field; refused (RefusedError) when it cannot be
  ## written in place.
  if trace < 0 or trace >= int64(e.ed.file.len): raiseArg("no trace " & $trace)
  editCall(e, name, e.ed.setField(int(trace), name, value))

proc setRecord*(e: EditorObj, record: int64, name: string, value: FieldValue) {.segApi.} =
  ## Sets a SEG-D record (general header) field.
  if record < 0 or record >= int64(e.ed.file.index.segdRecords.len):
    raiseArg("no SEG-D record " & $record)
  editCall(e, name, e.ed.setRecordField(int(record), name, value))

proc setFile*(e: EditorObj, name: string, value: FieldValue) {.segApi.} =
  ## Sets a file-level field (SEG-Y binary header, ...).
  editCall(e, name, e.ed.setField(name, value))

proc edits*(e: EditorObj): int64 {.segApi.} =
  ## Edits written so far.
  int64(e.ed.edits)

proc editorDiagnostics*(e: EditorObj): DiagLog {.
    segApi(c = "seg_editor_diagnostics", py = "diagnostics").} =
  ## The editor's log: refused edits and journal problems.
  e.ed.log

proc close*(e: EditorObj) {.segApi.} =
  ## Flushes the journal and closes the file.
  e.ed.close()

proc checkJournal(log: DiagLog) =
  checkLog(log, SEG_ERR_IO)
  if log.count(sevError) > 0:
    raiseLogged(SEG_ERR_STATE, $log.count(sevError) &
      " journal entries could not be applied (see the log)", log)

proc journalApply*(path, journal: string): DiagLog {.segApi.} =
  ## Re-applies a journal's edits to a file; returns the diagnostics.
  result = applyJournal(path, journal)
  checkJournal(result)

proc journalRollback*(path, journal: string): DiagLog {.segApi.} =
  ## Undoes a journal's edits on a file, newest first; returns the diagnostics.
  result = rollbackJournal(path, journal)
  checkJournal(result)

# ------------------------------------------------------------------- logs --

proc count*(l: LogObj): int64 {.segApi.} =
  ## Entries in the log.
  int64(l.log.len)

proc countSeverity*(l: LogObj, severity: Severity): int64 {.segApi.} =
  ## Entries of exactly this severity.
  int64(l.log.count(severity))

proc get*(l: LogObj, index: int64): DiagEntry {.segApi.} =
  ## One entry; its strings live as long as the log.
  if index < 0 or index >= int64(l.log.len): raiseArg("no entry " & $index)
  let d = unsafeAddr l.log[int(index)]
  DiagEntry(severity: d.severity, code: d.code, offset: d.offset, record: int64(d.loc.record),
    channelSet: int64(d.loc.channelSet), trace: int64(d.loc.trace),
    blockIndex: int64(d.loc.blockIndex), file: cstring(d.loc.file), field: cstring(d.loc.field),
    message: cstring(d.msg))

proc nif*(l: LogObj): string {.segApi.} =
  ## The whole log as NIF text.
  l.log.toNif

# ------------------------------------------------------------- conversion --

proc parseRevision(s: string, parts: Slice[int]): (int64, int64) =
  let p = s.split('.')
  if p.len notin parts: raiseArg("revision must look like '2.1', not '" & s & "'")
  try:
    (int64(parseInt(p[0])), (if p.len == 2: int64(parseInt(p[1])) else: 0'i64))
  except ValueError:
    raiseArg("revision must look like '2.1', not '" & s & "'")

proc segyConvert*(src, dst: string, revision = "2.1", byteOrder = boBig, format = 0'i64,
    textEncoding = teEbcdic, applyDescale = false, stationHeader = true): DiagLog {.
    segApi(c = "seg_convert", py = "convert").} =
  ## Converts src (SEG-Y or SEG-D) to the SEG-Y file dst: revision "0", "1",
  ## "2.0" or "2.1"; format a SEG-Y format code (0: keep or choose
  ## losslessly). Returns the diagnostics; a failure carries them.
  let (major, minor) = parseRevision(revision, 1..2)
  if major notin 0..2 or minor notin 0..1 or format notin 0..255:
    raiseArg("revision or format out of range")
  let o = ConvertOptions(revision: SegyRevision(major: uint8(major), minor: uint8(minor)),
    byteOrder: byteOrder, format: int(format), textEncoding: textEncoding,
    applyDescale: applyDescale, stationHeader: stationHeader)
  result = convertFile(src, dst, o)
  checkLog(result, SEG_ERR_FORMAT)

proc segdConvert*(src, dst: string, revision = "3.0", format = 0'i64): DiagLog {.
    segApi(c = "seg_convert_segd", py = "convert_segd").} =
  ## Converts the SEG-D file src to the SEG-D file dst in revision "2.0",
  ## "2.1", "3.0" or "3.1". `format` is a SEG-D format code (0: keep; 8080
  ## becomes 8058 for Rev 2, and the little-endian 90xx their 80xx twins
  ## before 3.1). Returns the diagnostics; a failure carries them.
  let (major, minor) = parseRevision(revision, 2..2)
  if major notin 0..255 or minor notin 0..255 or format notin 0..9999:
    raiseArg("SEG-D target revision or format out of range")
  result = convertSegdRevision(src, dst, SegdConvertOptions(
    revision: SegdRevision(major: uint8(major), minor: uint8(minor)), format: int(format)))
  checkLog(result, SEG_ERR_FORMAT)

# ---------------------------------------------- C-only: init, last error --

when defined(segCapi):
  var initState: int # 0 not started, 1 running NimMain, 2 done (atomic)

  proc NimMain() {.importc, cdecl, codegenDecl: "N_LIB_EXPORT N_CDECL($1, $2)$3".}
    # Declared as Nim defines it (exported): Windows refuses a redeclaration
    # that adds dllexport.

  proc segInit(): int32 {.exportc: "seg_init", dynlib, cdecl, raises: [].} =
    # Touches no Nim runtime before NimMain has run: one thread wins the
    # compare-and-swap and runs it, the others spin until it is done.
    var expected = 0
    if atomicCompareExchangeN(addr initState, addr expected, 1, false, ATOMIC_ACQ_REL,
        ATOMIC_ACQUIRE):
      NimMain()
      atomicStoreN(addr initState, 2, ATOMIC_RELEASE)
    else:
      while atomicLoadN(addr initState, ATOMIC_ACQUIRE) != 2: cpuRelax()
    AbiVersion

  proc segLastError(): cstring {.exportc: "seg_last_error", dynlib, cdecl, raises: [].} =
    lastErrorPtr()

segFinish(AbiVersion, ModuleDoc)
