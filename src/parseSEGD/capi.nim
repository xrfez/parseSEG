## The C ABI (task 8.3): `seg_*` functions over the public Nim API, for hosts
## in any language. The header is `include/parseseg.h`; the rules (handles,
## ownership, threads, errors) are in `docs/design/c_abi.md`. Build with the
## nimble task `lib`:
##
##   nim c --app:lib --noMain --mm:atomicArc --threads:on -d:useMalloc -d:release
##     --out:libparseseg.so src/parseSEGD/capi.nim
##
## Every export catches everything (`except Exception`), so no Nim exception
## or Defect unwinds into C; arguments are checked before any call that
## would assert. Handles are `ref` objects kept alive with `GC_ref` until
## their release function.

import std/[strutils, locks]
import ./common/[errors, diagnostics]
import ./model/[traceindex, keys, gathers, prefetch, headerfields, edit]

const
  SegAbiVersion = 1'i32
  PackageVersion = "0.2.0"

{.pragma: capi, dynlib, cdecl.}

type
  SegStatus = int32

const
  SEG_OK = 0'i32
  SEG_END = 1'i32
  SEG_NOT_READY = 2'i32
  SEG_ERR_ARGUMENT = -1'i32
  SEG_ERR_IO = -2'i32
  SEG_ERR_FORMAT = -3'i32
  SEG_ERR_STATE = -4'i32
  SEG_ERR_REFUSED = -5'i32
  SEG_ERR_INTERNAL = -6'i32

  SEG_F32 = 1'i32
  SEG_F64 = 2'i32

  SEG_OPEN_KEYS = 1'u32
  SEG_OPEN_8015_TWOS = 2'u32

  SEG_VALUE_INT = 1'i32
  SEG_VALUE_FLOAT = 2'i32
  SEG_VALUE_TEXT = 3'i32

type
  # ------------------------------------------------ structs shared with C --
  SegTensorView {.bycopy.} = object
    data: pointer
    dtype: int32
    rank: int32
    shape: array[2, int64]
    strides: array[2, int64] # in elements

  SegValue {.bycopy.} = object
    kind: int32
    pad: int32
    i: int64
    f: float64
    text: cstring

  SegGather {.bycopy.} = object
    kind: int32
    pad: int32
    first, count, sources, receivers: int64

  SegDiagnostic {.bycopy.} = object
    severity, code: int32
    offset, record, channelSet, trace, blockIndex: int64
    file, field, message, codeName: cstring

  SegChunk {.bycopy.} = object
    first, count, failed: int64
    samples: pointer # SegTensor*, owned by the caller

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

  # --------------------------------------------------------------- handles --
  LogObj = ref object
    log: DiagLog
    owned: bool  # false: borrowed from a file or editor (release is a no-op)
    nif: string

  FileObj = ref object
    f: SeismicFile
    log: LogObj
    gathers: seq[Gather]
    gathersDone: bool
    text: string # backing store for the last SegValue text

  TensorObj = ref object
    dtype: int32
    t32: Tensor[float32]
    t64: Tensor[float64]
    shape, strides: array[2, int64] # stable storage for DLPack pointers

  PrefetchObj = ref object
    file: FileObj # keeps the map alive
    dtype: int32
    p32: Prefetcher[float32]
    p64: Prefetcher[float64]

  EditorObj = ref object
    ed: HeaderEditor
    log: LogObj

var lastError {.threadvar.}: string
var initLock: Lock
var initialized: bool
initLock.initLock()

proc NimMain() {.importc, cdecl.}

# ---------------------------------------------------------------- helpers --

proc fail(code: SegStatus, msg: string): SegStatus =
  lastError = msg
  code

template guarded(body: untyped): SegStatus =
  ## Runs `body` (which returns a SegStatus) with every exception mapped to a
  ## status and `lastError`.
  var st: SegStatus
  try:
    lastError.setLen 0
    st = body
  except SegTruncatedError as e: st = fail(SEG_ERR_FORMAT, "truncated: " & e.msg)
  except SegFormatError as e: st = fail(SEG_ERR_FORMAT, e.msg)
  except IOError as e: st = fail(SEG_ERR_IO, e.msg)
  except OSError as e: st = fail(SEG_ERR_IO, e.msg)
  except ValueError as e: st = fail(SEG_ERR_ARGUMENT, e.msg)
  except Exception as e: st = fail(SEG_ERR_INTERNAL, $e.name & ": " & e.msg)
  st

template handle[T](p: pointer): T = cast[T](p)

proc keep[T: ref](x: T): pointer =
  GC_ref(x)
  cast[pointer](x)

proc newTensorObj[T](t: sink Tensor[T]): TensorObj =
  when T is float32: result = TensorObj(dtype: SEG_F32, t32: t)
  else: result = TensorObj(dtype: SEG_F64, t64: t)

proc syncLog(l: LogObj, log: DiagLog) =
  l.log = log
  l.nif.setLen 0

func validDtype(d: int32): bool {.inline.} = d == SEG_F32 or d == SEG_F64

proc selection(traces: ptr UncheckedArray[int64], n: int64, f: SeismicFile,
    sel: var seq[int]): bool =
  if n < 0 or (n > 0 and traces == nil): return false
  sel = newSeq[int](n)
  for k in 0..<int(n):
    let i = traces[k]
    if i < 0 or i >= f.len: return false
    sel[k] = int(i)
  true

# ------------------------------------------------------------ the library --

proc segInit(): int32 {.exportc: "seg_init", capi.} =
  try:
    acquire(initLock)
    if not initialized:
      NimMain()
      initialized = true
    release(initLock)
  except Exception:
    discard
  SegAbiVersion

proc segAbiVersion(): int32 {.exportc: "seg_abi_version", capi.} = SegAbiVersion

proc segVersion(): cstring {.exportc: "seg_version", capi.} = cstring(PackageVersion)

proc segLastError(): cstring {.exportc: "seg_last_error", capi.} = cstring(lastError)

proc segStatusName(s: SegStatus): cstring {.exportc: "seg_status_name", capi.} =
  case s
  of SEG_OK: "SEG_OK"
  of SEG_END: "SEG_END"
  of SEG_NOT_READY: "SEG_NOT_READY"
  of SEG_ERR_ARGUMENT: "SEG_ERR_ARGUMENT"
  of SEG_ERR_IO: "SEG_ERR_IO"
  of SEG_ERR_FORMAT: "SEG_ERR_FORMAT"
  of SEG_ERR_STATE: "SEG_ERR_STATE"
  of SEG_ERR_REFUSED: "SEG_ERR_REFUSED"
  of SEG_ERR_INTERNAL: "SEG_ERR_INTERNAL"
  else: "unknown status"

# ------------------------------------------------------------------ files --

proc segFileOpen(path: cstring, flags: uint32, outFile: ptr pointer): SegStatus {.exportc: "seg_file_open",
    capi.} =
  guarded:
    if path == nil or outFile == nil: fail(SEG_ERR_ARGUMENT, "path and out must not be NULL")
    else:
      outFile[] = nil
      # Open first: an exception inside the object constructor would leak the
      # half-built handle.
      var sf = openSeismic($path, (flags and SEG_OPEN_8015_TWOS) != 0,
        keys = (flags and SEG_OPEN_KEYS) != 0)
      let fo = FileObj(f: move sf, log: LogObj())
      outFile[] = keep(fo)
      SEG_OK

proc segFileRelease(f: pointer) {.exportc: "seg_file_release", capi.} =
  try:
    if f != nil:
      let fo = handle[FileObj](f)
      GC_unref(fo) # the map closes when the last holder (a prefetcher) lets go
  except Exception:
    discard

proc fileOf(f: pointer): FileObj {.inline.} = handle[FileObj](f)

proc segFileKind(f: pointer): int32 {.exportc: "seg_file_kind", capi.} =
  if f == nil: return 0
  let fo = fileOf(f)
  if not fo.f.index.detected: 0'i32 elif fo.f.kind == skSegy: 1'i32 else: 2'i32

proc segFileTraceCount(f: pointer): int64 {.exportc: "seg_file_trace_count", capi.} =
  if f == nil: -1 else: int64(fileOf(f).f.len)

proc segFileRecordCount(f: pointer): int64 {.exportc: "seg_file_record_count", capi.} =
  if f == nil: return -1
  let fo = fileOf(f)
  if fo.f.kind == skSegd: int64(fo.f.index.segdRecords.len)
  elif fo.f.index.detected: 1 else: 0

proc segFileMaxSamples(f: pointer): int64 {.exportc: "seg_file_max_samples", capi.} =
  if f == nil: -1 else: int64(fileOf(f).f.index.maxSamples)

proc segFileTraceEntry(f: pointer, i: int64, outEntry: ptr TraceEntry): SegStatus {.exportc: "seg_file_trace_entry",
    capi.} =
  guarded:
    if f == nil or outEntry == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif i < 0 or i >= fileOf(f).f.len: fail(SEG_ERR_ARGUMENT, "no trace " & $i)
    else:
      outEntry[] = fileOf(f).f.index.entries[i]
      SEG_OK

proc segFileTraceKeys(f: pointer, i: int64, outKeys: ptr TraceKeys): SegStatus {.exportc: "seg_file_trace_keys",
    capi.} =
  guarded:
    if f == nil or outKeys == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif i < 0 or i >= fileOf(f).f.len: fail(SEG_ERR_ARGUMENT, "no trace " & $i)
    elif fileOf(f).f.index.keys.len != fileOf(f).f.len:
      fail(SEG_ERR_STATE, "open the file with SEG_OPEN_KEYS")
    else:
      outKeys[] = fileOf(f).f.index.keys[i]
      SEG_OK

proc segFileSampleInterval(f: pointer, i: int64): float64 {.exportc: "seg_file_sample_interval",
    capi.} =
  try:
    if f == nil or i < 0 or i > int64(high(int32)) * 1024: NaN
    else: fileOf(f).f.sampleIntervalUs(int(i))
  except Exception: NaN

proc segFileLog(f: pointer): pointer {.exportc: "seg_file_log", capi.} =
  try:
    if f == nil: return nil
    let fo = fileOf(f)
    fo.log.syncLog(fo.f.index.log)
    cast[pointer](fo.log) # borrowed: the file holds it
  except Exception: nil

# ---------------------------------------------------------- header fields --

proc toSegValue(fo: FileObj, v: FieldValue, outValue: ptr SegValue) =
  outValue[] = SegValue()
  case v.kind
  of fvInt:
    outValue.kind = SEG_VALUE_INT
    outValue.i = v.i
    outValue.f = float64(v.i)
  of fvFloat:
    outValue.kind = SEG_VALUE_FLOAT
    outValue.f = v.f
  of fvText:
    fo.text = v.s
    outValue.kind = SEG_VALUE_TEXT
    outValue.text = cstring(fo.text)

template fieldRead(f: pointer, name: cstring, outValue: ptr SegValue, call: untyped): SegStatus =
  guarded:
    if f == nil or name == nil or outValue == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let fo {.inject.} = fileOf(f)
      var v {.inject.}: FieldValue
      var err {.inject.}: string
      if call: (toSegValue(fo, v, outValue); SEG_OK)
      else: fail(SEG_ERR_ARGUMENT, $name & ": " & err)

proc segTraceField(f: pointer, trace: int64, name: cstring, outValue: ptr SegValue): SegStatus {.
    exportc: "seg_trace_field", capi.} =
  fieldRead(f, name, outValue,
    trace >= 0 and trace < int64(fo.f.len) and fo.f.traceField(int(trace), $name, v, err))

proc segRecordField(f: pointer, record: int64, name: cstring,
    outValue: ptr SegValue): SegStatus {.exportc: "seg_record_field", capi.} =
  fieldRead(f, name, outValue,
    record >= 0 and record <= int64(high(int32)) and fo.f.recordField(int(record), $name, v, err))

proc segFileField(f: pointer, name: cstring, outValue: ptr SegValue): SegStatus {.exportc: "seg_file_field",
    capi.} =
  fieldRead(f, name, outValue, fo.f.fileField($name, v, err))

# ---------------------------------------------------------------- tensors --

proc segTensorRelease(t: pointer) {.exportc: "seg_tensor_release", capi.} =
  try:
    if t != nil: GC_unref(handle[TensorObj](t))
  except Exception: discard

proc fillView(to: TensorObj, v: ptr SegTensorView) =
  v[] = SegTensorView(dtype: to.dtype, rank: 2)
  template fill(t: untyped) =
    v.data = if t.size > 0: cast[pointer](t.unsafe_raw_offset()) else: nil
    for d in 0..1:
      to.shape[d] = int64(t.shape[d])
      to.strides[d] = int64(t.strides[d])
  if to.dtype == SEG_F32: fill(to.t32) else: fill(to.t64)
  v.shape = to.shape
  v.strides = to.strides

proc segTensorView(t: pointer, outView: ptr SegTensorView): SegStatus {.exportc: "seg_tensor_view",
    capi.} =
  guarded:
    if t == nil or outView == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      fillView(handle[TensorObj](t), outView)
      SEG_OK

proc dlpackDeleter(self: ptr DLManagedTensor) {.cdecl.} =
  try:
    if self != nil:
      if self.managerCtx != nil: GC_unref(cast[TensorObj](self.managerCtx))
      dealloc(self)
  except Exception: discard

proc segTensorToDlpack(t: pointer): ptr DLManagedTensor {.exportc: "seg_tensor_to_dlpack",
    capi.} =
  try:
    if t == nil: return nil
    let to = handle[TensorObj](t)
    var v: SegTensorView
    fillView(to, addr v)
    result = create(DLManagedTensor)
    result.dlTensor = DLTensor(data: v.data, device: DLDevice(deviceType: 1, deviceId: 0),
      ndim: 2, dtype: DLDataType(code: 2, bits: (if to.dtype == SEG_F32: 32 else: 64), lanes: 1),
      shape: addr to.shape[0], strides: addr to.strides[0], byteOffset: 0)
    result.managerCtx = keep(to)
    result.deleter = dlpackDeleter
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = nil

# ------------------------------------------------------------------ reads --

proc readNew(fo: FileObj, sel: seq[int], dtype: int32, cols: int64,
    outTensor: ptr pointer): SegStatus =
  let width = if cols >= 0: int(cols) else: fo.f.maxSamples(sel)
  template go(T: typedesc) =
    var t = newTraceTensor[T](sel.len, width)
    if sel.len > 0: discard fo.f.readTracesInto(sel, t)
    outTensor[] = keep(newTensorObj(t))
  if dtype == SEG_F32: go(float32) else: go(float64)
  SEG_OK

proc checkRead(f: pointer, dtype: int32): string =
  if f == nil: "NULL file"
  elif not validDtype(dtype): "dtype must be SEG_F32 or SEG_F64"
  elif fileOf(f).f.memory == nil and fileOf(f).f.len > 0: "the file is not mapped"
  elif not fileOf(f).f.index.contiguous: "range reads need a plain disk file"
  else: ""

proc segReadRange(f: pointer, first, count: int64, dtype: int32, cols: int64,
    outTensor: ptr pointer): SegStatus {.exportc: "seg_read_range", capi.} =
  guarded:
    let bad = checkRead(f, dtype)
    if bad.len > 0 or outTensor == nil: fail(SEG_ERR_ARGUMENT, if bad.len > 0: bad else: "NULL out")
    elif first < 0 or count < 0 or first + count > int64(fileOf(f).f.len):
      fail(SEG_ERR_ARGUMENT, "trace range out of bounds")
    else:
      var sel = newSeq[int](count)
      for k in 0..<int(count): sel[k] = int(first) + k
      readNew(fileOf(f), sel, dtype, cols, outTensor)

proc segReadSelection(f: pointer, traces: ptr UncheckedArray[int64], n: int64, dtype: int32,
    cols: int64, outTensor: ptr pointer): SegStatus {.exportc: "seg_read_selection", capi.} =
  guarded:
    let bad = checkRead(f, dtype)
    var sel: seq[int]
    if bad.len > 0 or outTensor == nil: fail(SEG_ERR_ARGUMENT, if bad.len > 0: bad else: "NULL out")
    elif not selection(traces, n, fileOf(f).f, sel):
      fail(SEG_ERR_ARGUMENT, "the selection holds a trace out of bounds")
    else:
      readNew(fileOf(f), sel, dtype, cols, outTensor)

proc readInto(fo: FileObj, sel: seq[int], dtype: int32, buffer: pointer, cols,
    rowStride: int64, failed: ptr int64): SegStatus =
  var log: DiagLog
  let n = if dtype == SEG_F32:
            fo.f.readTracesRaw(sel, cast[ptr UncheckedArray[float32]](buffer), int(cols),
              int(rowStride), log)
          else:
            fo.f.readTracesRaw(sel, cast[ptr UncheckedArray[float64]](buffer), int(cols),
              int(rowStride), log)
  if failed != nil: failed[] = int64(n)
  if n > 0: lastError = log[0].msg & " (" & $n & " traces left zero)"
  SEG_OK

proc segReadRangeInto(f: pointer, first, count: int64, dtype: int32, buffer: pointer,
    cols, rowStride: int64, failed: ptr int64): SegStatus {.exportc: "seg_read_range_into",
    capi.} =
  guarded:
    let bad = checkRead(f, dtype)
    if bad.len > 0: fail(SEG_ERR_ARGUMENT, bad)
    elif first < 0 or count < 0 or first + count > int64(fileOf(f).f.len):
      fail(SEG_ERR_ARGUMENT, "trace range out of bounds")
    elif cols < 0 or rowStride < cols or (count > 0 and buffer == nil):
      fail(SEG_ERR_ARGUMENT, "need cols >= 0, row_stride >= cols and a buffer")
    else:
      var sel = newSeq[int](count)
      for k in 0..<int(count): sel[k] = int(first) + k
      readInto(fileOf(f), sel, dtype, buffer, cols, rowStride, failed)

proc segReadSelectionInto(f: pointer, traces: ptr UncheckedArray[int64], n: int64,
    dtype: int32, buffer: pointer, cols, rowStride: int64, failed: ptr int64): SegStatus {.
    exportc: "seg_read_selection_into", capi.} =
  guarded:
    let bad = checkRead(f, dtype)
    var sel: seq[int]
    if bad.len > 0: fail(SEG_ERR_ARGUMENT, bad)
    elif not selection(traces, n, fileOf(f).f, sel):
      fail(SEG_ERR_ARGUMENT, "the selection holds a trace out of bounds")
    elif cols < 0 or rowStride < cols or (n > 0 and buffer == nil):
      fail(SEG_ERR_ARGUMENT, "need cols >= 0, row_stride >= cols and a buffer")
    else:
      readInto(fileOf(f), sel, dtype, buffer, cols, rowStride, failed)

# ---------------------------------------------------------------- gathers --

proc ensureGathers(fo: FileObj): bool =
  if fo.f.index.keys.len != fo.f.len: return false
  if not fo.gathersDone:
    fo.gathers = fo.f.index.gathers
    fo.gathersDone = true
  true

proc segFileGatherCount(f: pointer, count: ptr int64): SegStatus {.exportc: "seg_file_gather_count",
    capi.} =
  guarded:
    if f == nil or count == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif not ensureGathers(fileOf(f)): fail(SEG_ERR_STATE, "open the file with SEG_OPEN_KEYS")
    else:
      count[] = int64(fileOf(f).gathers.len)
      SEG_OK

proc segFileGather(f: pointer, i: int64, outGather: ptr SegGather): SegStatus {.exportc: "seg_file_gather",
    capi.} =
  guarded:
    if f == nil or outGather == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif not ensureGathers(fileOf(f)): fail(SEG_ERR_STATE, "open the file with SEG_OPEN_KEYS")
    elif i < 0 or i >= int64(fileOf(f).gathers.len): fail(SEG_ERR_ARGUMENT, "no gather " & $i)
    else:
      let g = fileOf(f).gathers[i]
      outGather[] = SegGather(kind: int32(ord(g.kind)), first: int64(g.traces.a),
        count: int64(g.traces.len), sources: int64(g.sources), receivers: int64(g.receivers))
      SEG_OK

proc segComponentGroups(f: pointer, first, count: int64, groupOf: ptr UncheckedArray[int64],
    groups: ptr int64): SegStatus {.exportc: "seg_component_groups", capi.} =
  guarded:
    if f == nil or (count > 0 and groupOf == nil): fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif fileOf(f).f.index.keys.len != fileOf(f).f.len:
      fail(SEG_ERR_STATE, "open the file with SEG_OPEN_KEYS")
    elif first < 0 or count < 0 or first + count > int64(fileOf(f).f.len):
      fail(SEG_ERR_ARGUMENT, "trace range out of bounds")
    else:
      for k in 0..<int(count): groupOf[k] = -1
      let cg = fileOf(f).f.index.componentGroups(int(first) ..< int(first + count))
      for g, grp in cg:
        for i in grp.traces: groupOf[i - int(first)] = int64(g)
      if groups != nil: groups[] = int64(cg.len)
      SEG_OK

# --------------------------------------------------------------- prefetch --

proc segPrefetchOpen(f: pointer, first, last, chunkTraces, depth, cols: int64, dtype: int32,
    outPrefetch: ptr pointer): SegStatus {.exportc: "seg_prefetch_open", capi.} =
  guarded:
    let bad = checkRead(f, dtype)
    let n = if f != nil: int64(fileOf(f).f.len) else: 0
    let stop = if last < 0: n else: last
    if bad.len > 0 or outPrefetch == nil:
      fail(SEG_ERR_ARGUMENT, if bad.len > 0: bad else: "NULL out")
    elif first < 0 or first > stop or stop > n: fail(SEG_ERR_ARGUMENT, "trace range out of bounds")
    elif chunkTraces <= 0 or depth <= 0 or chunkTraces > 1 shl 24 or depth > 1024:
      fail(SEG_ERR_ARGUMENT, "need 0 < chunk_traces <= 2^24 and 0 < depth <= 1024")
    else:
      let po = PrefetchObj(file: fileOf(f), dtype: dtype)
      if dtype == SEG_F32:
        po.p32 = newPrefetcher[float32](po.file.f, int(first), int(stop), int(chunkTraces),
          int(depth), int(cols))
      else:
        po.p64 = newPrefetcher[float64](po.file.f, int(first), int(stop), int(chunkTraces),
          int(depth), int(cols))
      outPrefetch[] = keep(po)
      SEG_OK

proc segPrefetchOpenSelection(f: pointer, traces: ptr UncheckedArray[int64], n: int64,
    chunkTraces, depth, cols: int64, dtype: int32, outPrefetch: ptr pointer): SegStatus {.exportc: "seg_prefetch_open_selection",
    capi.} =
  guarded:
    let bad = checkRead(f, dtype)
    var sel: seq[int]
    if bad.len > 0 or outPrefetch == nil:
      fail(SEG_ERR_ARGUMENT, if bad.len > 0: bad else: "NULL out")
    elif not selection(traces, n, fileOf(f).f, sel):
      fail(SEG_ERR_ARGUMENT, "the selection holds a trace out of bounds")
    elif chunkTraces <= 0 or depth <= 0 or chunkTraces > 1 shl 24 or depth > 1024:
      fail(SEG_ERR_ARGUMENT, "need 0 < chunk_traces <= 2^24 and 0 < depth <= 1024")
    else:
      let po = PrefetchObj(file: fileOf(f), dtype: dtype)
      if dtype == SEG_F32:
        po.p32 = newPrefetcher[float32](po.file.f, sel, int(chunkTraces), int(depth), int(cols))
      else:
        po.p64 = newPrefetcher[float64](po.file.f, sel, int(chunkTraces), int(depth), int(cols))
      outPrefetch[] = keep(po)
      SEG_OK

template takeChunk(p: pointer, outChunk: ptr SegChunk, call: untyped): SegStatus =
  guarded:
    if p == nil or outChunk == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let po = handle[PrefetchObj](p)
      outChunk[] = SegChunk()
      template body(pf: untyped, T: typedesc): SegStatus =
        var c: PrefetchChunk[T]
        if call(pf, c):
          outChunk[] = SegChunk(first: int64(c.first), count: int64(c.count),
            failed: int64(c.failed), samples: keep(newTensorObj(move c.samples)))
          SEG_OK
        elif pf.atEnd: SEG_END
        else: SEG_NOT_READY
      if po.dtype == SEG_F32: body(po.p32, float32) else: body(po.p64, float64)

proc segPrefetchTryNext(p: pointer, outChunk: ptr SegChunk): SegStatus {.exportc: "seg_prefetch_try_next",
    capi.} =
  takeChunk(p, outChunk, tryNext)

proc segPrefetchNext(p: pointer, outChunk: ptr SegChunk): SegStatus {.exportc: "seg_prefetch_next",
    capi.} =
  takeChunk(p, outChunk, next)

proc segPrefetchSeek(p: pointer, first, last: int64): SegStatus {.exportc: "seg_prefetch_seek",
    capi.} =
  guarded:
    if p == nil: fail(SEG_ERR_ARGUMENT, "NULL prefetcher")
    else:
      let po = handle[PrefetchObj](p)
      let n = if po.dtype == SEG_F32: po.p32.positions else: po.p64.positions
      let stop = if last < 0: int64(n) else: last
      if first < 0 or first > stop or stop > int64(n):
        fail(SEG_ERR_ARGUMENT, "position range out of bounds")
      else:
        if po.dtype == SEG_F32: po.p32.seek(int(first), int(stop))
        else: po.p64.seek(int(first), int(stop))
        SEG_OK

proc segPrefetchTraceAt(p: pointer, pos: int64): int64 {.exportc: "seg_prefetch_trace_at",
    capi.} =
  try:
    if p == nil: return -1
    let po = handle[PrefetchObj](p)
    let n = if po.dtype == SEG_F32: po.p32.positions else: po.p64.positions
    if pos < 0 or pos >= int64(n): -1
    elif po.dtype == SEG_F32: int64(po.p32.traceAt(int(pos)))
    else: int64(po.p64.traceAt(int(pos)))
  except Exception: -1

proc segPrefetchRelease(p: pointer) {.exportc: "seg_prefetch_release", capi.} =
  try:
    if p != nil:
      let po = handle[PrefetchObj](p)
      po.p32.close() # join the worker before the file can go
      po.p64.close()
      GC_unref(po)
  except Exception: discard

# ---------------------------------------------------------------- editing --

proc toEdit(v: ptr SegValue, e: var EditValue): bool =
  case v.kind
  of SEG_VALUE_INT: e = toEditValue(v.i)
  of SEG_VALUE_FLOAT: e = toEditValue(v.f)
  of SEG_VALUE_TEXT:
    if v.text == nil: return false
    e = toEditValue($v.text)
  else: return false
  true

proc segEditorOpen(path, journal: cstring, outEditor: ptr pointer): SegStatus {.exportc: "seg_editor_open",
    capi.} =
  guarded:
    if path == nil or outEditor == nil: fail(SEG_ERR_ARGUMENT, "path and out must not be NULL")
    else:
      outEditor[] = nil
      var ed = openEditor($path, if journal == nil: "" else: $journal) # see seg_file_open
      let eo = EditorObj(ed: move ed, log: LogObj())
      outEditor[] = keep(eo)
      SEG_OK

template editCall(e: pointer, name: cstring, value: ptr SegValue, call: untyped): SegStatus =
  guarded:
    var v {.inject.}: EditValue
    if e == nil or name == nil or value == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif not toEdit(value, v): fail(SEG_ERR_ARGUMENT, "bad SegValue kind or NULL text")
    else:
      let eo {.inject.} = handle[EditorObj](e)
      let before = eo.ed.log.len
      if call: SEG_OK
      else:
        fail(SEG_ERR_REFUSED, if eo.ed.log.len > before: eo.ed.log[eo.ed.log.len - 1].msg
                              else: $name & ": refused")

proc segEditorSetTrace(e: pointer, trace: int64, name: cstring,
    value: ptr SegValue): SegStatus {.exportc: "seg_editor_set_trace", capi.} =
  editCall(e, name, value, trace >= 0 and trace <= int64(high(int32)) * 1024 and
    eo.ed.setField(int(trace), $name, v))

proc segEditorSetRecord(e: pointer, record: int64, name: cstring,
    value: ptr SegValue): SegStatus {.exportc: "seg_editor_set_record", capi.} =
  editCall(e, name, value, record >= 0 and record <= int64(high(int32)) and
    eo.ed.setRecordField(int(record), $name, v))

proc segEditorSetFile(e: pointer, name: cstring, value: ptr SegValue): SegStatus {.exportc: "seg_editor_set_file",
    capi.} =
  editCall(e, name, value, eo.ed.setField($name, v))

proc segEditorEdits(e: pointer): int64 {.exportc: "seg_editor_edits", capi.} =
  if e == nil: -1 else: int64(handle[EditorObj](e).ed.edits)

proc segEditorLog(e: pointer): pointer {.exportc: "seg_editor_log", capi.} =
  try:
    if e == nil: return nil
    let eo = handle[EditorObj](e)
    eo.log.syncLog(eo.ed.log)
    cast[pointer](eo.log)
  except Exception: nil

proc segEditorClose(e: pointer): SegStatus {.exportc: "seg_editor_close", capi.} =
  guarded:
    if e == nil: SEG_OK
    else:
      let eo = handle[EditorObj](e)
      try:
        eo.ed.close()
      finally:
        GC_unref(eo)
      SEG_OK

template journalCall(path, journal: cstring, outLog: ptr pointer, call: untyped): SegStatus =
  guarded:
    if path == nil or journal == nil: fail(SEG_ERR_ARGUMENT, "path and journal must not be NULL")
    else:
      let log = call($path, $journal)
      if outLog != nil: outLog[] = keep(LogObj(log: log, owned: true))
      if log.isFatal: fail(SEG_ERR_IO, log[log.len - 1].msg)
      elif log.count(sevError) > 0: fail(SEG_ERR_STATE, $log.count(sevError) &
        " journal entries could not be applied (see the log)")
      else: SEG_OK

proc segJournalRollback(path, journal: cstring, outLog: ptr pointer): SegStatus {.exportc: "seg_journal_rollback",
    capi.} =
  journalCall(path, journal, outLog, rollbackJournal)

proc segJournalApply(path, journal: cstring, outLog: ptr pointer): SegStatus {.exportc: "seg_journal_apply",
    capi.} =
  journalCall(path, journal, outLog, applyJournal)

# ------------------------------------------------------------------- logs --

const codeNames = block:
  var a: array[DiagCode, string]
  for c in DiagCode: a[c] = $c
  a

proc logOf(l: pointer): LogObj {.inline.} = cast[LogObj](l)

proc segLogCount(l: pointer): int64 {.exportc: "seg_log_count", capi.} =
  if l == nil: -1 else: int64(logOf(l).log.len)

proc segLogCountSeverity(l: pointer, severity: int32): int64 {.exportc: "seg_log_count_severity",
    capi.} =
  if l == nil or severity < 0 or severity > ord(high(Severity)): -1
  else: int64(logOf(l).log.count(Severity(severity)))

proc segLogGet(l: pointer, i: int64, outDiag: ptr SegDiagnostic): SegStatus {.exportc: "seg_log_get",
    capi.} =
  guarded:
    if l == nil or outDiag == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    elif i < 0 or i >= int64(logOf(l).log.len): fail(SEG_ERR_ARGUMENT, "no entry " & $i)
    else:
      let d = unsafeAddr logOf(l).log[int(i)]
      outDiag[] = SegDiagnostic(severity: int32(ord(d.severity)), code: int32(ord(d.code)),
        offset: d.offset, record: int64(d.loc.record), channelSet: int64(d.loc.channelSet),
        trace: int64(d.loc.trace), blockIndex: int64(d.loc.blockIndex),
        file: cstring(d.loc.file), field: cstring(d.loc.field), message: cstring(d.msg),
        codeName: cstring(codeNames[d.code]))
      SEG_OK

proc segLogNif(l: pointer): cstring {.exportc: "seg_log_nif", capi.} =
  try:
    if l == nil: return nil
    let lo = logOf(l)
    if lo.nif.len == 0: lo.nif = lo.log.toNif
    cstring(lo.nif)
  except Exception: nil

proc segLogRelease(l: pointer) {.exportc: "seg_log_release", capi.} =
  try:
    if l != nil and logOf(l).owned: GC_unref(logOf(l))
  except Exception: discard

# ------------------------------------------------------------ layout check --

proc segSizeof(name: cstring): int64 {.exportc: "seg_sizeof", capi.} =
  ## Nim's size of a struct shared with C, for the header's layout test.
  case $name
  of "SegTraceEntry": sizeof(TraceEntry)
  of "SegTraceKeys": sizeof(TraceKeys)
  of "SegTensorView": sizeof(SegTensorView)
  of "SegValue": sizeof(SegValue)
  of "SegGather": sizeof(SegGather)
  of "SegDiagnostic": sizeof(SegDiagnostic)
  of "SegChunk": sizeof(SegChunk)
  of "DLManagedTensor": sizeof(DLManagedTensor)
  else: -1

proc segOffsetof(name, field: cstring): int64 {.exportc: "seg_offsetof", capi.} =
  ## Nim's offset of a field of a struct shared with C (C field names), for
  ## the header's layout test; -1 if unknown.
  let key = $name & "." & $field
  template o(T: typedesc, f: untyped): int64 = int64(offsetOf(T, f))
  case key
  of "SegTraceEntry.offset": o(TraceEntry, offset)
  of "SegTraceEntry.header_bytes": o(TraceEntry, headerBytes)
  of "SegTraceEntry.num_samples": o(TraceEntry, numSamples)
  of "SegTraceEntry.record": o(TraceEntry, record)
  of "SegTraceEntry.channel_set": o(TraceEntry, channelSet)
  of "SegTraceEntry.scan_type": o(TraceEntry, scanType)
  of "SegTraceEntry.channel_type": o(TraceEntry, channelType)
  of "SegTraceKeys.record": o(TraceKeys, record)
  of "SegTraceKeys.ensemble": o(TraceKeys, ensemble)
  of "SegTraceKeys.offset": o(TraceKeys, offset)
  of "SegTraceKeys.src_line": o(TraceKeys, srcLine)
  of "SegTraceKeys.src_point": o(TraceKeys, srcPoint)
  of "SegTraceKeys.src_x": o(TraceKeys, srcX)
  of "SegTraceKeys.src_y": o(TraceKeys, srcY)
  of "SegTraceKeys.rcv_line": o(TraceKeys, rcvLine)
  of "SegTraceKeys.rcv_point": o(TraceKeys, rcvPoint)
  of "SegTraceKeys.rcv_x": o(TraceKeys, rcvX)
  of "SegTraceKeys.rcv_y": o(TraceKeys, rcvY)
  of "SegTraceKeys.src_index": o(TraceKeys, srcIndex)
  of "SegTraceKeys.rcv_index": o(TraceKeys, rcvIndex)
  of "SegTraceKeys.depth_index": o(TraceKeys, depthIndex)
  of "SegTraceKeys.reshoot_index": o(TraceKeys, reshootIndex)
  of "SegTraceKeys.sensor_type": o(TraceKeys, sensorType)
  of "SegTraceKeys.component": o(TraceKeys, component)
  of "SegTensorView.data": o(SegTensorView, data)
  of "SegTensorView.dtype": o(SegTensorView, dtype)
  of "SegTensorView.rank": o(SegTensorView, rank)
  of "SegTensorView.shape": o(SegTensorView, shape)
  of "SegTensorView.strides": o(SegTensorView, strides)
  of "SegValue.kind": o(SegValue, kind)
  of "SegValue.i": o(SegValue, i)
  of "SegValue.f": o(SegValue, f)
  of "SegValue.text": o(SegValue, text)
  of "SegGather.kind": o(SegGather, kind)
  of "SegGather.first": o(SegGather, first)
  of "SegGather.count": o(SegGather, count)
  of "SegGather.sources": o(SegGather, sources)
  of "SegGather.receivers": o(SegGather, receivers)
  of "SegDiagnostic.severity": o(SegDiagnostic, severity)
  of "SegDiagnostic.code": o(SegDiagnostic, code)
  of "SegDiagnostic.offset": o(SegDiagnostic, offset)
  of "SegDiagnostic.record": o(SegDiagnostic, record)
  of "SegDiagnostic.channel_set": o(SegDiagnostic, channelSet)
  of "SegDiagnostic.trace": o(SegDiagnostic, trace)
  of "SegDiagnostic.block_index": o(SegDiagnostic, blockIndex)
  of "SegDiagnostic.file": o(SegDiagnostic, file)
  of "SegDiagnostic.field": o(SegDiagnostic, field)
  of "SegDiagnostic.message": o(SegDiagnostic, message)
  of "SegDiagnostic.code_name": o(SegDiagnostic, codeName)
  of "SegChunk.first": o(SegChunk, first)
  of "SegChunk.count": o(SegChunk, count)
  of "SegChunk.failed": o(SegChunk, failed)
  of "SegChunk.samples": o(SegChunk, samples)
  of "DLManagedTensor.manager_ctx": o(DLManagedTensor, managerCtx)
  of "DLManagedTensor.deleter": o(DLManagedTensor, deleter)
  else: -1
