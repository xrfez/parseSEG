## The part of the foreign boundary the core cannot declare itself (task 12.5).
##
## Most of the C ABI and the Python module come from `{.segApi.}` on the core
## routines. This module adds what has no single core routine:
##
## - the dtype-erased handles `Tensor` and `Prefetcher` for the generic
##   `Tensor[T]` and `Prefetcher[T]`, and the reads that create them (the
##   generic `T` becomes a `dtype` parameter);
## - DLPack, and the library's version and status names.
##
## Each adapter overloads the core routine of the same name with the same
## parameter names (`segFinish` checks it, and takes the core's doc), except
## those marked `abiOnly`. Built by `nim lib` (`src/parseSEG/bindings.nim`)
## with `-d:segCapi`, which also writes `include/parseseg.h` and
## `python/parseseg/__init__.py`.
##
## Not part of the public Nim API: Nim code uses the umbrella module directly.

import ../../parseSEG # every core type the generated code names
import ../model/traceindex
import ./segapi

export segapi

const
  AbiVersion* = 3'i32 ## `SEG_ABI_VERSION`; bump on any incompatible C change.
  PackageVersion* = "0.3.0"
  MaxBufferBytes* = 1'i64 shl 40 ## Largest tensor or prefetch ring the library allocates.
  MaxChunkTraces* = 1 shl 24 ## Largest prefetch chunk.
  MaxDepth* = 1024 ## Most prefetch ring slots.
  ModuleDoc = """Read, index, edit and convert SEG-Y and SEG-D seismic data.

    import parseseg
    with parseseg.open_seismic("line.sgy", keys=True) as f:
        samples = f.read_traces(range(100)).numpy()   # zero-copy, float32 [100, ns]
"""

type
  Dtype* {.size: 4.} = enum ## Sample type of a tensor.
    dtF32 = (1, "float32"), dtF64 = (2, "float64")

  TensorObj* {.segHandle.} = ref object of AbiHandle
    ## A 2-D sample array `[traces, samples]` owned by the library.
    dt*: Dtype
    t32*: Tensor[float32]
    t64*: Tensor[float64]
    shape*, strides*: array[2, int64] ## stable storage for DLPack pointers

  PrefetcherObj* {.segHandle.} = ref object of AbiHandle
    ## Read-ahead on a worker thread.
    file*: Handle[SeismicFile] ## keeps the map alive
    dt*: Dtype
    p32*: Prefetcher[float32]
    p64*: Prefetcher[float64]

  PrefetchChunkObj* = object
    ## One prefetched chunk; `samples` is owned by the caller.
    first*: int  ## position of the first row (a trace, or an index into the list)
    count*: int  ## rows
    failed*: int ## rows that could not be decoded (left zero)
    samples*: TensorObj

  TensorView* = object
    ## Samples in memory: `data[r * strides[0] + c * strides[1]]` is row r,
    ## sample c. As a destination, rows must be contiguous (`strides[1] == 1`).
    data*: pointer
    dtype*: Dtype
    rank*: int32
    shape*, strides*: array[2, int64] ## in elements

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

# ---------------------------------------------------------------- helpers --

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>", cdecl, gcsafe,
    raises: [].}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>", cdecl.}

var mallocProbe {.volatile.}: proc (size: csize_t): pointer {.cdecl, gcsafe, raises: [].} =
  cMalloc
  # Called through a volatile pointer: clang may otherwise drop an unused
  # malloc/free pair and assume the allocation succeeded.

proc requireBuffer(rows, cols, elem: int) =
  ## Fails unless rows × cols × elem bytes fit the library's limit and the
  ## system can allocate them (Nim's allocator would end the process).
  if rows < 0 or cols < 0 or (rows > 0 and cols > 0 and
      cols > MaxBufferBytes div elem div rows):
    argError("rows x cols exceeds the library's buffer limit (1 TiB)")
  let bytes = int64(rows) * int64(cols) * int64(elem)
  if bytes >= 64 shl 20:
    let p = mallocProbe(csize_t(bytes))
    if p == nil: raise newException(AbiMemoryError, "out of memory")
    cFree(p)

func elemSize(d: Dtype): int = (if d == dtF32: 4 else: 8)

proc checkTraces(f: SeismicFile, traces: Slice[int]) =
  if traces.b >= traces.a and (traces.a < 0 or traces.b >= f.len):
    argError("traces " & $traces & " lie outside the file (" & $f.len & " traces)")

proc checkTraces(f: SeismicFile, traces: openArray[int]) =
  for t in traces:
    if t notin 0 ..< f.len: argError("trace " & $t & " lies outside the file")

proc newTensorObj[T](t: sink Tensor[T]): TensorObj =
  when T is float32: TensorObj(dt: dtF32, t32: t)
  else: TensorObj(dt: dtF64, t64: t)

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

# ------------------------------------------------------------ the library --

proc abiVersion*(): int32 {.segApi(abiOnly).} =
  ## The library's ABI version (SEG_ABI_VERSION).
  AbiVersion

proc version*(): string {.segApi(abiOnly).} =
  ## The package version, e.g. "0.3.0".
  PackageVersion

proc statusName*(status: int32): string {.segApi(abiOnly).} =
  ## The name of a status code ("SEG_OK", "SEG_ERR_IO", ...).
  case status
  of SEG_OK: "SEG_OK"
  of SEG_END: "SEG_END"
  of SEG_NOT_READY: "SEG_NOT_READY"
  of SEG_ERR_ARGUMENT: "SEG_ERR_ARGUMENT"
  of SEG_ERR_IO: "SEG_ERR_IO"
  of SEG_ERR_FORMAT: "SEG_ERR_FORMAT"
  of SEG_ERR_STATE: "SEG_ERR_STATE"
  of SEG_ERR_INTERNAL: "SEG_ERR_INTERNAL"
  of SEG_ERR_MEMORY: "SEG_ERR_MEMORY"
  else: "unknown status"

# ------------------------------------------------------------------ reads --

func rows(traces: Slice[int]): int = (if traces.b < traces.a: 0 else: traces.len)
func rows(traces: openArray[int]): int = traces.len

template readAs(f: SeismicFile, traces: untyped, dtype: Dtype): TensorObj =
  requireBuffer(rows(traces), f.maxSamples(traces), elemSize(dtype))
  if dtype == dtF32: newTensorObj(f.readTraces(traces, float32))
  else: newTensorObj(f.readTraces(traces, float64))

proc readTraces*(f: Handle[SeismicFile], traces: Slice[int], dtype = dtF32): TensorObj {.
    segApi(concurrent).} =
  ## Decodes `traces` into new samples `[traces, maxSamples]` (shorter traces
  ## are zero-padded, undecodable ones stay zero). Reads on one file may run
  ## in parallel.
  f.v.checkTraces(traces)
  readAs(f.v, traces, dtype)

proc readTraces*(f: Handle[SeismicFile], traces: openArray[int], dtype = dtF32): TensorObj {.
    segApi(concurrent).} =
  ## Decodes the listed traces, in list order, into new samples.
  f.v.checkTraces(traces)
  readAs(f.v, traces, dtype)

proc intoView(f: SeismicFile, traces: openArray[int], dst: TensorView, row: int): int =
  if dst.rank != 2 or dst.strides[1] != 1 or dst.shape[1] < 0 or dst.strides[0] < dst.shape[1]:
    argError("dst must be 2-D with contiguous rows (strides[1] = 1, strides[0] >= shape[1])")
  if dst.shape[0] < 0 or dst.shape[0] > 0 and
      dst.strides[0] > MaxBufferBytes div elemSize(dst.dtype) div dst.shape[0]:
    argError("dst is larger than the library's buffer limit (1 TiB)")
  if row < 0 or row > dst.shape[0] - traces.len:
    argError("dst has " & $dst.shape[0] & " rows; rows " & $row & "+" & $traces.len &
      " do not fit")
  if traces.len == 0: return 0
  if dst.data == nil: argError("dst.data is NULL")
  let (cols, stride) = (int(dst.shape[1]), int(dst.strides[0]))
  var log: DiagLog
  if dst.dtype == dtF32:
    let p = cast[ptr UncheckedArray[float32]](dst.data)
    f.readTracesRaw(traces, cast[ptr UncheckedArray[float32]](addr p[row * stride]), cols,
      stride, log)
  else:
    let p = cast[ptr UncheckedArray[float64]](dst.data)
    f.readTracesRaw(traces, cast[ptr UncheckedArray[float64]](addr p[row * stride]), cols,
      stride, log)

proc readTracesInto*(f: Handle[SeismicFile], traces: Slice[int], dst: TensorView,
    row = 0): int {.segApi(concurrent).} =
  ## Decodes `traces` straight into rows `row ..` of the caller's `dst`, each
  ## cut or zero-padded to its width. Returns how many traces could not be
  ## decoded (left zero).
  f.v.checkTraces(traces)
  var sel = newSeq[int](rows(traces))
  for k in 0 ..< sel.len: sel[k] = traces.a + k
  f.v.intoView(sel, dst, row)

proc readTracesInto*(f: Handle[SeismicFile], traces: openArray[int], dst: TensorView,
    row = 0): int {.segApi(concurrent).} =
  ## Decodes the listed traces into rows `row ..` of `dst`, one per trace.
  f.v.checkTraces(traces)
  f.v.intoView(traces, dst, row)

# ---------------------------------------------------------------- tensors --

func view*(t: TensorObj): TensorView {.segApi(abiOnly).} =
  ## The samples' memory: pointer, dtype, rank (2), shape and strides in
  ## elements. Valid while the tensor is held.
  {.cast(noSideEffect).}:
    t.refreshShape()
    TensorView(data: t.dataPointer, dtype: t.dt, rank: 2, shape: t.shape, strides: t.strides)

func dtype*(t: TensorObj): Dtype {.segApi(abiOnly).} =
  ## "float32" or "float64".
  t.dt

proc toDlpack*(t: TensorObj): pointer {.segApi(abiOnly, private).} =
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

# --------------------------------------------------------------- prefetch --

proc checkRing(f: SeismicFile, chunkTraces, depth, cols, width: int, dtype: Dtype) =
  if chunkTraces > MaxChunkTraces or depth > MaxDepth:
    argError("need chunkTraces <= 2^24 and depth <= 1024")
  let rows = max(1, min(chunkTraces, f.len))
  if depth > 0 and rows > 0 and width >= 0: requireBuffer(depth * rows, width, elemSize(dtype))

proc newPrefetcher*(f: Handle[SeismicFile], traces: Slice[int], chunkTraces = 256, depth = 4,
    cols = -1, dtype = dtF32): PrefetcherObj {.segApi.} =
  ## Decodes `traces` ahead on a worker thread, `chunkTraces` rows at a time,
  ## at most `depth` chunks buffered.
  f.v.checkTraces(traces)
  f.v.checkRing(chunkTraces, depth, cols,
    if cols >= 0: cols else: f.v.maxSamples(traces), dtype)
  result = PrefetcherObj(file: f, dt: dtype)
  if dtype == dtF32:
    result.p32 = newPrefetcher[float32](f.v, traces, chunkTraces, depth, cols)
  else:
    result.p64 = newPrefetcher[float64](f.v, traces, chunkTraces, depth, cols)

proc newPrefetcher*(f: Handle[SeismicFile], traces: openArray[int], chunkTraces = 256,
    depth = 4, cols = -1, dtype = dtF32): PrefetcherObj {.segApi.} =
  ## Read-ahead over a list of traces, in list order (positions index the
  ## list).
  f.v.checkTraces(traces)
  f.v.checkRing(chunkTraces, depth, cols,
    if cols >= 0: cols else: f.v.maxSamples(traces), dtype)
  result = PrefetcherObj(file: f, dt: dtype)
  if dtype == dtF32:
    result.p32 = newPrefetcher[float32](f.v, @traces, chunkTraces, depth, cols)
  else:
    result.p64 = newPrefetcher[float64](f.v, @traces, chunkTraces, depth, cols)

proc take(p: PrefetcherObj, wait: bool): PrefetchChunkObj =
  template body(pf: untyped, T: typedesc) =
    var c: PrefetchChunk[T]
    if (if wait: pf.next(c) else: pf.tryNext(c)):
      return PrefetchChunkObj(first: c.first, count: c.count, failed: c.failed,
        samples: newTensorObj(move c.samples))
    elif pf.atEnd: raise newException(AbiEnd, "no more chunks")
    else: raise newException(AbiNotReady, "the next chunk is not ready")
  if p.dt == dtF32: body(p.p32, float32) else: body(p.p64, float64)

proc next*(p: PrefetcherObj): PrefetchChunkObj {.segApi.} =
  ## The next chunk, waiting for it: first (position), count, failed rows
  ## (left zero) and the samples. SEG_END (Python: None) after the last.
  p.take(wait = true)

proc tryNext*(p: PrefetcherObj): PrefetchChunkObj {.segApi.} =
  ## The next chunk if it is decoded already, else SEG_NOT_READY (Python:
  ## None); SEG_END after the last.
  p.take(wait = false)

func atEnd*(p: PrefetcherObj): bool {.segApi.} =
  ## True once every chunk has been taken.
  {.cast(noSideEffect).}:
    if p.dt == dtF32: p.p32.atEnd else: p.p64.atEnd

func positions*(p: PrefetcherObj): int {.segApi.} =
  ## Positions `seek` accepts: the file's trace count, or the list's length.
  if p.dt == dtF32: p.p32.positions else: p.p64.positions

proc seek*(p: PrefetcherObj, span: Slice[int]) {.segApi.} =
  if p.dt == dtF32: p.p32.seek(span) else: p.p64.seek(span)

proc traceAt*(p: PrefetcherObj, pos: int): int {.segApi.} =
  if p.dt == dtF32: p.p32.traceAt(pos) else: p.p64.traceAt(pos)

proc close*(p: PrefetcherObj) {.segApi.} =
  ## Stops and joins the worker (releasing the handle does too).
  p.p32.close()
  p.p64.close()

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
