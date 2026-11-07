## The C ABI (task 8.3): `seg_*` functions for hosts in any language, as thin
## wrappers over the shared boundary implementation in `abi/core.nim` (the
## Python module `pyapi.nim` wraps the same procs). The header is
## `include/parseseg.h`; the rules (handles, ownership, threads, errors) are
## in `docs/design/c_abi.md`. Build with the nimble task `lib`:
##
##   nim c --app:lib --noMain --mm:atomicArc --threads:on -d:useMalloc -d:release
##     -d:segCapi --out:libparseseg.so src/parseSEGD/capi.nim
##
## Every export catches everything (`except Exception`), so no Nim exception
## or Defect unwinds into C; arguments are checked before any call that
## would assert. Handles are `ref` objects kept alive with `GC_ref` until
## their release function.

import ./abi/[core, exporting]

when appType == "lib" and not defined(segCapi):
  {.error: "build the C ABI with -d:segCapi (see `nim lib`)".}

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

  SEG_OPEN_KEYS = 1'u32
  SEG_OPEN_8015_TWOS = 2'u32

  SEG_VALUE_INT = 1'i32
  SEG_VALUE_FLOAT = 2'i32
  SEG_VALUE_TEXT = 3'i32

  NeedKeys = "SEG_OPEN_KEYS"

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

  SegConvertOptions {.bycopy.} = object
    revMajor, revMinor: int32
    byteOrder: int32     # 0 big, 1 little, 2 pair-swapped
    format: int32        # SEG-Y format code; 0 = keep / lossless
    textEncoding: int32  # 0 EBCDIC, 1 ASCII
    applyDescale: int32
    stationHeader: int32

  SegChunk {.bycopy.} = object
    first, count, failed: int64
    samples: pointer # SegTensor*, owned by the caller

const LastErrorCap = 1024

var lastErrorBuf {.threadvar.}: array[LastErrorCap, char]
  # A plain thread-local array: threads the host created never run Nim
  # threadvar destructors, so a `string` here would leak on every thread exit.
var initState: int # 0 not started, 1 running NimMain, 2 done (atomic)

proc setLastError(msg: string) =
  let n = min(msg.len, LastErrorCap - 1)
  if n > 0: copyMem(addr lastErrorBuf[0], unsafeAddr msg[0], n)
  lastErrorBuf[n] = '\0'

proc NimMain() {.importc, cdecl.}

# ---------------------------------------------------------------- helpers --

proc fail(code: SegStatus, msg: string): SegStatus =
  setLastError(msg)
  code

template guarded(body: untyped): SegStatus =
  ## Runs `body` (which returns a SegStatus) with every exception mapped to a
  ## status and `lastError` (the table in `abi/core.nim`).
  var st: SegStatus
  try:
    lastErrorBuf[0] = '\0'
    st = body
  except SegTruncatedError as e: st = fail(SEG_ERR_FORMAT, "truncated: " & e.msg)
  except SegFormatError as e: st = fail(SEG_ERR_FORMAT, e.msg)
  except IOError as e: st = fail(SEG_ERR_IO, e.msg)
  except OSError as e: st = fail(SEG_ERR_IO, e.msg)
  except ValueError as e: st = fail(SEG_ERR_ARGUMENT, e.msg)
  except AbiStateError as e: st = fail(SEG_ERR_STATE, e.msg)
  except AbiRefusedError as e: st = fail(SEG_ERR_REFUSED, e.msg)
  except AbiMemoryError as e: st = fail(SEG_ERR_IO, e.msg)
  except Exception as e: st = fail(SEG_ERR_INTERNAL, $e.name & ": " & e.msg)
  st

template handle[T](p: pointer): T = cast[T](p)

proc keep[T: ref](x: T): pointer =
  GC_ref(x)
  cast[pointer](x)

proc fileOf(f: pointer): FileObj {.inline.} = handle[FileObj](f)

proc readDtype(f: pointer, dtype: int32): Dtype =
  # The checks every read starts with, in the order the ABI documents.
  if f == nil: raise newException(ValueError, "NULL file")
  result = toDtype(dtype)
  fileOf(f).checkRead()

# ------------------------------------------------------------ the library --

proc segInit(): int32 {.segExport: "seg_init".} =
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

proc segAbiVersion(): int32 {.segExport: "seg_abi_version", raises: [].} = AbiVersion

proc segVersion(): cstring {.segExport: "seg_version", raises: [].} = cstring(PackageVersion)

proc segLastError(): cstring {.segExport: "seg_last_error", raises: [].} =
  cast[cstring](addr lastErrorBuf[0])

proc segStatusName(s: SegStatus): cstring {.segExport: "seg_status_name", raises: [].} =
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

proc segFileOpen(path: cstring, flags: uint32, outFile: ptr pointer): SegStatus {.
    segExport: "seg_file_open".} =
  guarded:
    if path == nil or outFile == nil: fail(SEG_ERR_ARGUMENT, "path and out must not be NULL")
    else:
      outFile[] = nil
      outFile[] = keep(openFile($path, keys = (flags and SEG_OPEN_KEYS) != 0,
        twos8015 = (flags and SEG_OPEN_8015_TWOS) != 0))
      SEG_OK

proc segFileRelease(f: pointer) {.segExport: "seg_file_release".} =
  try:
    if f != nil: GC_unref(fileOf(f)) # the map closes when the last holder (a prefetcher) lets go
  except Exception:
    discard

proc segFileKind(f: pointer): int32 {.segExport: "seg_file_kind", raises: [].} =
  if f == nil: 0 else: fileOf(f).kindCode

proc segFileTraceCount(f: pointer): int64 {.segExport: "seg_file_trace_count", raises: [].} =
  if f == nil: -1 else: fileOf(f).traceCount

proc segFileRecordCount(f: pointer): int64 {.segExport: "seg_file_record_count", raises: [].} =
  if f == nil: -1 else: fileOf(f).recordCount

proc segFileMaxSamples(f: pointer): int64 {.segExport: "seg_file_max_samples", raises: [].} =
  if f == nil: -1 else: fileOf(f).maxSamples

proc segFileTraceEntry(f: pointer, i: int64, outEntry: ptr TraceEntry): SegStatus {.
    segExport: "seg_file_trace_entry".} =
  guarded:
    if f == nil or outEntry == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      outEntry[] = fileOf(f).traceEntry(i)
      SEG_OK

proc segFileTraceKeys(f: pointer, i: int64, outKeys: ptr TraceKeys): SegStatus {.
    segExport: "seg_file_trace_keys".} =
  guarded:
    if f == nil or outKeys == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      outKeys[] = fileOf(f).traceKeys(i, NeedKeys)
      SEG_OK

proc segFileSampleInterval(f: pointer, i: int64): float64 {.
    segExport: "seg_file_sample_interval".} =
  try:
    if f == nil: NaN else: fileOf(f).sampleInterval(i)
  except Exception: NaN

proc segFileLog(f: pointer): pointer {.segExport: "seg_file_log".} =
  try:
    if f == nil: return nil
    # Bound to a local first: under ARC, a cast of a call's `ref` result skips
    # its destructor and leaks the reference.
    let l = fileOf(f).fileLog
    cast[pointer](l) # borrowed: the file holds it
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
      toSegValue(fo, call, outValue)
      SEG_OK

proc segTraceField(f: pointer, trace: int64, name: cstring, outValue: ptr SegValue): SegStatus {.
    segExport: "seg_trace_field".} =
  fieldRead(f, name, outValue, fo.traceField(trace, $name))

proc segRecordField(f: pointer, record: int64, name: cstring,
    outValue: ptr SegValue): SegStatus {.segExport: "seg_record_field".} =
  fieldRead(f, name, outValue, fo.recordField(record, $name))

proc segFileField(f: pointer, name: cstring, outValue: ptr SegValue): SegStatus {.
    segExport: "seg_file_field".} =
  fieldRead(f, name, outValue, fo.fileField($name))

# ---------------------------------------------------------------- tensors --

proc segTensorRelease(t: pointer) {.segExport: "seg_tensor_release".} =
  try:
    if t != nil: GC_unref(handle[TensorObj](t))
  except Exception: discard

proc segTensorView(t: pointer, outView: ptr SegTensorView): SegStatus {.
    segExport: "seg_tensor_view".} =
  guarded:
    if t == nil or outView == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let to = handle[TensorObj](t)
      to.refreshShape()
      outView[] = SegTensorView(data: to.dataPointer, dtype: int32(ord(to.dtype)), rank: 2,
        shape: to.shape, strides: to.strides)
      SEG_OK

proc segTensorToDlpack(t: pointer): ptr DLManagedTensor {.segExport: "seg_tensor_to_dlpack".} =
  lastErrorBuf[0] = '\0'
  try:
    if t == nil: nil else: toDlpack(handle[TensorObj](t))
  except Exception:
    setLastError(getCurrentExceptionMsg())
    nil

# ------------------------------------------------------------------ reads --

proc readNewInto(f: pointer, dtype: Dtype, sel: seq[int], cols: int64,
    outTensor: ptr pointer): SegStatus =
  outTensor[] = keep(fileOf(f).readNew(sel, dtype, cols))
  SEG_OK

proc segReadRange(f: pointer, first, count: int64, dtype: int32, cols: int64,
    outTensor: ptr pointer): SegStatus {.segExport: "seg_read_range".} =
  guarded:
    if outTensor != nil: outTensor[] = nil
    let d = readDtype(f, dtype)
    if outTensor == nil: fail(SEG_ERR_ARGUMENT, "NULL out")
    else: readNewInto(f, d, fileOf(f).rangeSelection(first, count), cols, outTensor)

proc segReadSelection(f: pointer, traces: ptr UncheckedArray[int64], n: int64, dtype: int32,
    cols: int64, outTensor: ptr pointer): SegStatus {.segExport: "seg_read_selection".} =
  guarded:
    if outTensor != nil: outTensor[] = nil
    let d = readDtype(f, dtype)
    if outTensor == nil: fail(SEG_ERR_ARGUMENT, "NULL out")
    else: readNewInto(f, d, fileOf(f).listSelection(traces, n), cols, outTensor)

proc readIntoStatus(f: pointer, sel: seq[int], dtype: Dtype, buffer: pointer,
    cols, rowStride: int64, failed: ptr int64): SegStatus =
  var problem: string
  let n = fileOf(f).readInto(sel, dtype, buffer, cols, rowStride, problem)
  if failed != nil: failed[] = n
  if n > 0: setLastError(problem)
  SEG_OK

proc segReadRangeInto(f: pointer, first, count: int64, dtype: int32, buffer: pointer,
    cols, rowStride: int64, failed: ptr int64): SegStatus {.segExport: "seg_read_range_into".} =
  guarded:
    let d = readDtype(f, dtype)
    if not rangeOk(first, count, fileOf(f).traceCount):
      fail(SEG_ERR_ARGUMENT, "trace range out of bounds")
    else:
      checkInto(count, cols, rowStride, d, buffer) # before the selection is allocated
      readIntoStatus(f, fileOf(f).rangeSelection(first, count), d, buffer, cols, rowStride,
        failed)

proc segReadSelectionInto(f: pointer, traces: ptr UncheckedArray[int64], n: int64,
    dtype: int32, buffer: pointer, cols, rowStride: int64, failed: ptr int64): SegStatus {.
    segExport: "seg_read_selection_into".} =
  guarded:
    let d = readDtype(f, dtype)
    let sel = fileOf(f).listSelection(traces, n)
    readIntoStatus(f, sel, d, buffer, cols, rowStride, failed)

# ---------------------------------------------------------------- gathers --

proc segFileGatherCount(f: pointer, count: ptr int64): SegStatus {.
    segExport: "seg_file_gather_count".} =
  guarded:
    if f == nil or count == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      count[] = int64(fileOf(f).fileGathers(NeedKeys).len)
      SEG_OK

proc segFileGather(f: pointer, i: int64, outGather: ptr SegGather): SegStatus {.
    segExport: "seg_file_gather".} =
  guarded:
    if f == nil or outGather == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let gs = fileOf(f).fileGathers(NeedKeys)
      if i < 0 or i >= int64(gs.len): fail(SEG_ERR_ARGUMENT, "no gather " & $i)
      else:
        let g = gs[i]
        outGather[] = SegGather(kind: int32(ord(g.kind)), first: int64(g.traces.a),
          count: int64(g.traces.len), sources: int64(g.sources), receivers: int64(g.receivers))
        SEG_OK

proc segComponentGroups(f: pointer, first, count: int64, groupOf: ptr UncheckedArray[int64],
    groups: ptr int64): SegStatus {.segExport: "seg_component_groups".} =
  guarded:
    if f == nil or (count > 0 and groupOf == nil): fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let fo = fileOf(f)
      fo.requireKeys(NeedKeys)
      if first < 0 or count < 0 or first + count > fo.traceCount:
        fail(SEG_ERR_ARGUMENT, "trace range out of bounds")
      else:
        let n = fo.componentGroups(first, count, NeedKeys, toOpenArray(groupOf, 0, int(count) - 1))
        if groups != nil: groups[] = n
        SEG_OK

# --------------------------------------------------------------- geometry --

proc segGeometryNew(outGeometry: ptr pointer): SegStatus {.segExport: "seg_geometry_new".} =
  guarded:
    if outGeometry != nil: outGeometry[] = nil
    if outGeometry == nil: fail(SEG_ERR_ARGUMENT, "NULL out")
    else:
      outGeometry[] = keep(GeometryObj())
      SEG_OK

proc segGeometryAddSource(g: pointer, line, point: float64, index: int32,
    x, y, z: float64): SegStatus {.segExport: "seg_geometry_add_source".} =
  guarded:
    if g == nil: fail(SEG_ERR_ARGUMENT, "NULL geometry")
    else:
      handle[GeometryObj](g).addSource(line, point, index, x, y, z)
      SEG_OK

proc segGeometryAddReceiver(g: pointer, line, point: float64, index: int32,
    x, y, z: float64): SegStatus {.segExport: "seg_geometry_add_receiver".} =
  guarded:
    if g == nil: fail(SEG_ERR_ARGUMENT, "NULL geometry")
    else:
      handle[GeometryObj](g).addReceiver(line, point, index, x, y, z)
      SEG_OK

proc segGeometryRelease(g: pointer) {.segExport: "seg_geometry_release".} =
  try:
    if g != nil: GC_unref(handle[GeometryObj](g))
  except Exception: discard

proc segFileApplyGeometry(f, g: pointer, overwrite: int32, updated: ptr int64): SegStatus {.
    segExport: "seg_file_apply_geometry".} =
  guarded:
    if f == nil or g == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let n = fileOf(f).applyGeometry(handle[GeometryObj](g), overwrite != 0, NeedKeys)
      if updated != nil: updated[] = n
      SEG_OK

# --------------------------------------------------------------- prefetch --

proc segPrefetchOpen(f: pointer, first, last, chunkTraces, depth, cols: int64, dtype: int32,
    outPrefetch: ptr pointer): SegStatus {.segExport: "seg_prefetch_open".} =
  guarded:
    if outPrefetch != nil: outPrefetch[] = nil
    let d = readDtype(f, dtype)
    if outPrefetch == nil: fail(SEG_ERR_ARGUMENT, "NULL out")
    else:
      outPrefetch[] = keep(fileOf(f).openPrefetch(first, last, chunkTraces, depth, cols, d))
      SEG_OK

proc segPrefetchOpenSelection(f: pointer, traces: ptr UncheckedArray[int64], n: int64,
    chunkTraces, depth, cols: int64, dtype: int32, outPrefetch: ptr pointer): SegStatus {.
    segExport: "seg_prefetch_open_selection".} =
  guarded:
    if outPrefetch != nil: outPrefetch[] = nil
    let d = readDtype(f, dtype)
    if outPrefetch == nil: fail(SEG_ERR_ARGUMENT, "NULL out")
    else:
      let fo = fileOf(f)
      outPrefetch[] = keep(fo.openPrefetch(fo.listSelection(traces, n), chunkTraces, depth,
        cols, d))
      SEG_OK

proc takeChunk(p: pointer, outChunk: ptr SegChunk, wait: bool): SegStatus =
  guarded:
    if p == nil or outChunk == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      outChunk[] = SegChunk()
      var c: ChunkObj
      case handle[PrefetchObj](p).take(wait, c)
      of csChunk:
        outChunk[] = SegChunk(first: c.first, count: c.count, failed: c.failed,
          samples: keep(c.samples))
        SEG_OK
      of csEnd: SEG_END
      of csNotReady: SEG_NOT_READY

proc segPrefetchTryNext(p: pointer, outChunk: ptr SegChunk): SegStatus {.
    segExport: "seg_prefetch_try_next".} =
  takeChunk(p, outChunk, wait = false)

proc segPrefetchNext(p: pointer, outChunk: ptr SegChunk): SegStatus {.
    segExport: "seg_prefetch_next".} =
  takeChunk(p, outChunk, wait = true)

proc segPrefetchSeek(p: pointer, first, last: int64): SegStatus {.
    segExport: "seg_prefetch_seek".} =
  guarded:
    if p == nil: fail(SEG_ERR_ARGUMENT, "NULL prefetcher")
    else:
      handle[PrefetchObj](p).seek(first, last)
      SEG_OK

proc segPrefetchTraceAt(p: pointer, pos: int64): int64 {.segExport: "seg_prefetch_trace_at".} =
  try:
    if p == nil: -1 else: handle[PrefetchObj](p).traceAt(pos)
  except Exception: -1

proc segPrefetchRelease(p: pointer) {.segExport: "seg_prefetch_release".} =
  try:
    if p != nil:
      let po = handle[PrefetchObj](p)
      po.close() # join the worker before the file can go
      GC_unref(po)
  except Exception: discard

# ---------------------------------------------------------------- editing --

proc toEdit(v: ptr SegValue): EditValue =
  case v.kind
  of SEG_VALUE_INT: toEditValue(v.i)
  of SEG_VALUE_FLOAT: toEditValue(v.f)
  of SEG_VALUE_TEXT:
    if v.text == nil: raise newException(ValueError, "bad SegValue kind or NULL text")
    toEditValue($v.text)
  else: raise newException(ValueError, "bad SegValue kind or NULL text")

proc segEditorOpen(path, journal: cstring, outEditor: ptr pointer): SegStatus {.
    segExport: "seg_editor_open".} =
  guarded:
    if path == nil or outEditor == nil: fail(SEG_ERR_ARGUMENT, "path and out must not be NULL")
    else:
      outEditor[] = nil
      outEditor[] = keep(openEditorObj($path, if journal == nil: "" else: $journal))
      SEG_OK

template editCall(e: pointer, name: cstring, value: ptr SegValue, call: untyped): SegStatus =
  guarded:
    if e == nil or name == nil or value == nil: fail(SEG_ERR_ARGUMENT, "NULL argument")
    else:
      let v {.inject.} = toEdit(value)
      let eo {.inject.} = handle[EditorObj](e)
      call
      SEG_OK

proc segEditorSetTrace(e: pointer, trace: int64, name: cstring,
    value: ptr SegValue): SegStatus {.segExport: "seg_editor_set_trace".} =
  editCall(e, name, value, eo.setTraceField(trace, $name, v))

proc segEditorSetRecord(e: pointer, record: int64, name: cstring,
    value: ptr SegValue): SegStatus {.segExport: "seg_editor_set_record".} =
  editCall(e, name, value, eo.setRecordField(record, $name, v))

proc segEditorSetFile(e: pointer, name: cstring, value: ptr SegValue): SegStatus {.
    segExport: "seg_editor_set_file".} =
  editCall(e, name, value, eo.setFileField($name, v))

proc segEditorEdits(e: pointer): int64 {.segExport: "seg_editor_edits", raises: [].} =
  if e == nil: -1 else: int64(handle[EditorObj](e).ed.edits)

proc segEditorLog(e: pointer): pointer {.segExport: "seg_editor_log".} =
  try:
    if e == nil: return nil
    let l = handle[EditorObj](e).editorLog # a local: see seg_file_log
    cast[pointer](l)
  except Exception: nil

proc segEditorClose(e: pointer): SegStatus {.segExport: "seg_editor_close".} =
  guarded:
    if e == nil: SEG_OK
    else:
      let eo = handle[EditorObj](e)
      try:
        eo.ed.close()
      finally:
        GC_unref(eo)
      SEG_OK

proc journalCall(path, journal: cstring, outLog: ptr pointer, apply: bool): SegStatus =
  guarded:
    if outLog != nil: outLog[] = nil
    if path == nil or journal == nil: fail(SEG_ERR_ARGUMENT, "path and journal must not be NULL")
    else:
      let log = replayJournal($path, $journal, apply)
      if outLog != nil: outLog[] = keep(LogObj(log: log, owned: true))
      checkJournal(log)
      SEG_OK

proc segJournalRollback(path, journal: cstring, outLog: ptr pointer): SegStatus {.
    segExport: "seg_journal_rollback".} =
  journalCall(path, journal, outLog, apply = false)

proc segJournalApply(path, journal: cstring, outLog: ptr pointer): SegStatus {.
    segExport: "seg_journal_apply".} =
  journalCall(path, journal, outLog, apply = true)

# ------------------------------------------------------------------- logs --

proc logOf(l: pointer): LogObj {.inline.} = cast[LogObj](l)

proc segLogCount(l: pointer): int64 {.segExport: "seg_log_count", raises: [].} =
  if l == nil: -1 else: int64(logOf(l).log.len)

proc segLogCountSeverity(l: pointer, severity: int32): int64 {.
    segExport: "seg_log_count_severity", raises: [].} =
  if l == nil or severity < 0 or severity > ord(high(Severity)): -1
  else: int64(logOf(l).log.count(Severity(severity)))

proc segLogGet(l: pointer, i: int64, outDiag: ptr SegDiagnostic): SegStatus {.
    segExport: "seg_log_get".} =
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

proc segLogNif(l: pointer): cstring {.segExport: "seg_log_nif".} =
  try:
    if l == nil: nil else: cstring(logOf(l).nifText)
  except Exception: nil

proc segLogRelease(l: pointer) {.segExport: "seg_log_release".} =
  try:
    if l != nil and logOf(l).owned: GC_unref(logOf(l))
  except Exception: discard

# ------------------------------------------------------------- conversion --

proc segConvertOptionsDefault(o: ptr SegConvertOptions) {.
    segExport: "seg_convert_options_default".} =
  if o != nil:
    let d = ConvertOptions()
    o[] = SegConvertOptions(revMajor: int32(d.revision.major), revMinor: int32(d.revision.minor),
      byteOrder: int32(ord(d.byteOrder)), format: int32(d.format),
      textEncoding: int32(ord(d.textEncoding)), applyDescale: int32(ord(d.applyDescale)),
      stationHeader: int32(ord(d.stationHeader)))

proc segConvert(src, dst: cstring, opts: ptr SegConvertOptions,
    outLog: ptr pointer): SegStatus {.segExport: "seg_convert".} =
  guarded:
    if outLog != nil: outLog[] = nil
    if src == nil or dst == nil: fail(SEG_ERR_ARGUMENT, "src and dst must not be NULL")
    else:
      let o = if opts == nil: ConvertOptions()
              else: convertOptions(opts.revMajor, opts.revMinor, opts.byteOrder, opts.format,
                      opts.textEncoding, opts.applyDescale != 0, opts.stationHeader != 0)
      let log = convertFile($src, $dst, o)
      if outLog != nil: outLog[] = keep(LogObj(log: log, owned: true))
      checkConvert(log)
      SEG_OK

# ------------------------------------------------------------ layout check --

proc segSizeof(name: cstring): int64 {.segExport: "seg_sizeof".} =
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
  of "SegConvertOptions": sizeof(SegConvertOptions)
  else: -1

proc segOffsetof(name, field: cstring): int64 {.segExport: "seg_offsetof".} =
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
  of "SegTraceKeys.src_z": o(TraceKeys, srcZ)
  of "SegTraceKeys.rcv_z": o(TraceKeys, rcvZ)
  of "SegTraceKeys.cmp_x": o(TraceKeys, cmpX)
  of "SegTraceKeys.cmp_y": o(TraceKeys, cmpY)
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
  of "SegConvertOptions.rev_major": o(SegConvertOptions, revMajor)
  of "SegConvertOptions.rev_minor": o(SegConvertOptions, revMinor)
  of "SegConvertOptions.byte_order": o(SegConvertOptions, byteOrder)
  of "SegConvertOptions.format": o(SegConvertOptions, format)
  of "SegConvertOptions.text_encoding": o(SegConvertOptions, textEncoding)
  of "SegConvertOptions.apply_descale": o(SegConvertOptions, applyDescale)
  of "SegConvertOptions.station_header": o(SegConvertOptions, stationHeader)
  of "DLManagedTensor.manager_ctx": o(DLManagedTensor, managerCtx)
  of "DLManagedTensor.deleter": o(DLManagedTensor, deleter)
  else: -1
