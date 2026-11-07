## Shared implementation of the library's foreign boundaries (task 8.8): the C
## ABI (`capi.nim`) and the Python module (`pyapi.nim`) are thin wrappers over
## these procs, so both check arguments, bound allocations and report
## problems the same way.
##
## Every proc here raises on failure; the wrappers translate:
##
## ==================  ====================  ==========================
## Raised              C status              Python exception
## ==================  ====================  ==========================
## `ValueError`        `SEG_ERR_ARGUMENT`    `parseseg.ArgumentError`
## `SegFormatError`    `SEG_ERR_FORMAT`      `parseseg.FormatError`
## `IOError/OSError`   `SEG_ERR_IO`          `parseseg.IOError`
## `AbiStateError`     `SEG_ERR_STATE`       `parseseg.StateError`
## `AbiRefusedError`   `SEG_ERR_REFUSED`     `parseseg.RefusedError`
## `AbiMemoryError`    `SEG_ERR_IO`          `MemoryError`
## ==================  ====================  ==========================
##
## Not part of the public Nim API: Nim code uses the umbrella module directly.

import ../common/[errors, diagnostics]
import ../model/[traceindex, keys, gathers, prefetch, headerfields, edit]
import ../convert
import ../segd/[revconvert, reader as segdreader]
import ../common/endians
import ../segy/[textheader, binheader]
import ../survey/[sps, p1, join]
import std/[tables, math]

export errors, diagnostics, traceindex, keys, gathers, prefetch, headerfields, edit, convert,
  endians, textheader, binheader, revconvert, segdreader, join

const
  AbiVersion* = 1'i32 ## `SEG_ABI_VERSION`; bump on any incompatible C change.
  PackageVersion* = "0.2.0"
  MaxSelection* = 1'i64 shl 34 ## Longest trace list accepted.
  MaxBufferBytes* = 1'i64 shl 40 ## Largest tensor or prefetch ring the library allocates.
  MaxChunkTraces* = 1'i64 shl 24 ## Largest prefetch chunk.
  MaxDepth* = 1024'i64 ## Most prefetch ring slots.

type
  AbiStateError* = object of CatchableError
    ## The handle is not in a state that allows the call (e.g. no keys).
  AbiRefusedError* = object of CatchableError
    ## An edit was refused; the editor's log says why.
  AbiMemoryError* = object of CatchableError
    ## The system refused a buffer.

  Dtype* = enum ## Sample type of a tensor, with the C ABI's codes.
    dtF32 = 1, dtF64 = 2

  ChunkStatus* = enum csChunk, csEnd, csNotReady

  LogObj* = ref object
    log*: DiagLog
    owned*: bool  ## false: borrowed from a file or editor (C release is a no-op)
    nif*: string

  FileObj* = ref object
    f*: SeismicFile
    log*: LogObj
    gathers*: seq[Gather]
    gathersDone*: bool
    text*: string ## backing store for the last C `SegValue` text

  TensorObj* = ref object
    dtype*: Dtype
    t32*: Tensor[float32]
    t64*: Tensor[float64]
    shape*, strides*: array[2, int64] ## stable storage for DLPack pointers

  ChunkObj* = object
    first*, count*, failed*: int64
    samples*: TensorObj

  PrefetchObj* = ref object
    file*: FileObj ## keeps the map alive
    dtype*: Dtype
    p32*: Prefetcher[float32]
    p64*: Prefetcher[float64]

  EditorObj* = ref object
    ed*: HeaderEditor
    log*: LogObj

  GeometryObj* = ref object
    s*: SurveyGeometry ## Station coordinates and SPS relations.
    names*: LineNames  ## How text line names become numbers.

  # DLPack v0.8 (dlpack.h), unversioned `DLManagedTensor`.
  DLDevice* {.bycopy.} = object
    deviceType*, deviceId*: int32
  DLDataType* {.bycopy.} = object
    code*, bits*: uint8
    lanes*: uint16
  DLTensor* {.bycopy.} = object
    data*: pointer
    device*: DLDevice
    ndim*: int32
    dtype*: DLDataType
    shape*, strides*: ptr int64
    byteOffset*: uint64
  DLManagedTensor* {.bycopy.} = object
    dlTensor*: DLTensor
    managerCtx*: pointer
    deleter*: proc (self: ptr DLManagedTensor) {.cdecl.}

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

proc canAllocate*(bytes: int64): bool =
  ## Nim's allocator terminates the process when the system refuses memory
  ## (an out-of-memory hook cannot raise through goto-based exceptions), so a
  ## large buffer is first probed with malloc/free. The system may still run
  ## out later; this catches requests it refuses outright.
  if bytes < 64 shl 20: return true
  let p = mallocProbe(csize_t(bytes))
  result = p != nil
  if result: cFree(p)

func fitsBuffer*(rows, cols, elem: int64): bool =
  ## rows × cols × elem ≤ MaxBufferBytes, without overflowing.
  rows >= 0 and cols >= 0 and (rows == 0 or cols == 0 or
    cols <= MaxBufferBytes div elem div rows)

func elemSize*(d: Dtype): int64 = (if d == dtF32: 4 else: 8)

func rangeOk*(first, count, n: int64): bool =
  first >= 0 and count >= 0 and first <= n and count <= n - first

proc toDtype*(code: int32): Dtype =
  ## The dtype with C code `code`; raises `ValueError` for any other value.
  if code == ord(dtF32): dtF32
  elif code == ord(dtF64): dtF64
  else: raiseArg("dtype must be SEG_F32 or SEG_F64")

proc newTensorObj*[T](t: sink Tensor[T]): TensorObj =
  when T is float32: result = TensorObj(dtype: dtF32, t32: t)
  else: result = TensorObj(dtype: dtF64, t64: t)

proc syncLog*(l: LogObj, log: DiagLog) =
  l.log = log
  l.nif.setLen 0

# ------------------------------------------------------------------ files --

proc openFile*(path: string, keys, twos8015: bool): FileObj =
  ## Opens and indexes `path` (see `openSeismic`).
  var sf = openSeismic(path, twos8015, keys = keys)
  FileObj(f: move sf, log: LogObj())

func kindCode*(fo: FileObj): int32 =
  ## 0 unknown, 1 SEG-Y, 2 SEG-D.
  if not fo.f.index.detected: 0'i32 elif fo.f.kind == skSegy: 1'i32 else: 2'i32

func traceCount*(fo: FileObj): int64 = int64(fo.f.len)

func recordCount*(fo: FileObj): int64 =
  if fo.f.kind == skSegd: int64(fo.f.index.segdRecords.len)
  elif fo.f.index.detected: 1 else: 0

func maxSamples*(fo: FileObj): int64 = int64(fo.f.index.maxSamples)

func hasKeys*(fo: FileObj): bool = fo.f.index.keys.len == fo.f.len

proc requireKeys*(fo: FileObj, how: string) =
  ## Raises `AbiStateError` unless the file was opened with keys; `how` says
  ## how to open it that way in the caller's language.
  if not fo.hasKeys: raiseState("open the file with " & how)

proc checkTrace*(fo: FileObj, i: int64) =
  if i < 0 or i >= fo.traceCount: raiseArg("no trace " & $i)

proc traceEntry*(fo: FileObj, i: int64): TraceEntry =
  fo.checkTrace(i)
  fo.f.index.entries[i]

proc traceKeys*(fo: FileObj, i: int64, how: string): TraceKeys =
  fo.checkTrace(i)
  fo.requireKeys(how)
  fo.f.index.keys[i]

proc sampleInterval*(fo: FileObj, i: int64): float64 =
  ## Microseconds; NaN for a trace out of range.
  if i < 0 or i > int64(high(int32)) * 1024: NaN
  else: fo.f.sampleIntervalUs(int(i))

proc fileLog*(fo: FileObj): LogObj =
  ## The file's log, refreshed (borrowed: the file holds it).
  fo.log.syncLog(fo.f.index.log)
  fo.log

# ---------------------------------------------------------- header fields --

template fieldCall(name: string, call: untyped): FieldValue =
  var v {.inject.}: FieldValue
  var err {.inject.}: string
  if not call: raiseArg(name & ": " & err)
  v

proc traceField*(fo: FileObj, trace: int64, name: string): FieldValue =
  fo.checkTrace(trace) # else the reason would be empty
  fieldCall(name, fo.f.traceField(int(trace), name, v, err))

proc recordField*(fo: FileObj, record: int64, name: string): FieldValue =
  fieldCall(name, record >= 0 and record <= int64(high(int32)) and
    fo.f.recordField(int(record), name, v, err))

proc fileField*(fo: FileObj, name: string): FieldValue =
  fieldCall(name, fo.f.fileField(name, v, err))

# ---------------------------------------------------------------- tensors --

template withTensor(to: TensorObj, t, body: untyped) =
  if to.dtype == dtF32:
    template t: untyped = to.t32
    body
  else:
    template t: untyped = to.t64
    body

proc dataPointer*(to: TensorObj): pointer =
  ## The first element, or nil for an empty tensor.
  withTensor(to, t):
    result = if t.size > 0: cast[pointer](t.unsafe_raw_offset()) else: nil

proc refreshShape*(to: TensorObj) =
  ## Copies shape and strides (in elements) into `to.shape`/`to.strides`.
  withTensor(to, t):
    for d in 0..1:
      to.shape[d] = int64(t.shape[d])
      to.strides[d] = int64(t.strides[d])

proc dlpackDeleter(self: ptr DLManagedTensor) {.cdecl.} =
  try:
    if self != nil:
      if self.managerCtx != nil: GC_unref(cast[TensorObj](self.managerCtx))
      dealloc(self)
  except Exception: discard

proc toDlpack*(to: TensorObj): ptr DLManagedTensor =
  ## A DLPack tensor sharing `to`'s samples; it keeps `to` alive until its
  ## deleter runs. Not freed by the GC: the consumer must call the deleter.
  to.refreshShape()
  result = create(DLManagedTensor)
  result.dlTensor = DLTensor(data: to.dataPointer, device: DLDevice(deviceType: 1, deviceId: 0),
    ndim: 2, dtype: DLDataType(code: 2, bits: uint8(8 * elemSize(to.dtype)), lanes: 1),
    shape: addr to.shape[0], strides: addr to.strides[0], byteOffset: 0)
  GC_ref(to)
  result.managerCtx = cast[pointer](to)
  result.deleter = dlpackDeleter

# ------------------------------------------------------------------ reads --

proc checkRead*(fo: FileObj) =
  ## Raises `ValueError` unless samples can be read from `fo`'s map.
  if fo.f.memory == nil and fo.f.len > 0: raiseArg("the file is not mapped")
  if not fo.f.index.contiguous: raiseArg("range reads need a plain disk file")

proc rangeSelection*(fo: FileObj, first, count: int64): seq[int] =
  if not rangeOk(first, count, fo.traceCount): raiseArg("trace range out of bounds")
  result = newSeq[int](count)
  for k in 0..<int(count): result[k] = int(first) + k

proc listSelection*(fo: FileObj, traces: ptr UncheckedArray[int64], n: int64): seq[int] =
  ## Every entry is checked before anything is allocated.
  const bad = "the selection holds a trace out of bounds"
  if n < 0 or n > MaxSelection or (n > 0 and traces == nil): raiseArg(bad)
  for k in 0..<int(n):
    if traces[k] < 0 or traces[k] >= fo.traceCount: raiseArg(bad)
  result = newSeq[int](n)
  for k in 0..<int(n): result[k] = int(traces[k])

proc listSelection*(fo: FileObj, traces: openArray[int64]): seq[int] =
  if traces.len == 0: @[]
  else: fo.listSelection(cast[ptr UncheckedArray[int64]](unsafeAddr traces[0]), traces.len)

proc readNew*(fo: FileObj, sel: seq[int], dtype: Dtype, cols: int64): TensorObj =
  ## Decodes `sel` into a new `[sel.len, width]` tensor, width = `cols` or
  ## (cols = -1) the longest selected trace.
  if cols < -1: raiseArg("cols must be >= -1")
  let width = if cols >= 0: int(cols) else: fo.f.maxSamples(sel)
  if not fitsBuffer(int64(sel.len), int64(width), elemSize(dtype)):
    raiseArg("rows x cols exceeds the library's buffer limit (1 TiB)")
  if not canAllocate(int64(sel.len) * int64(width) * elemSize(dtype)):
    raise newException(AbiMemoryError, "out of memory")
  template go(T: typedesc) =
    var t = newTraceTensor[T](sel.len, width)
    if sel.len > 0: discard fo.f.readTracesInto(sel, t)
    result = newTensorObj(t)
  if dtype == dtF32: go(float32) else: go(float64)

proc checkInto*(rows, cols, rowStride: int64, dtype: Dtype, buffer: pointer) =
  if cols < 0 or rowStride < cols or (rows > 0 and buffer == nil) or
      not fitsBuffer(rows, rowStride, elemSize(dtype)):
    raiseArg("need cols >= 0, row_stride >= cols and a buffer")

proc readInto*(fo: FileObj, sel: seq[int], dtype: Dtype, buffer: pointer,
    cols, rowStride: int64, firstProblem: var string): int64 =
  ## Decodes `sel` into the caller's buffer (row k at `k * rowStride`
  ## elements); returns how many traces failed (left zero), with the first
  ## failure's message.
  checkInto(int64(sel.len), cols, rowStride, dtype, buffer)
  var log: DiagLog
  let n = if dtype == dtF32:
            fo.f.readTracesRaw(sel, cast[ptr UncheckedArray[float32]](buffer), int(cols),
              int(rowStride), log)
          else:
            fo.f.readTracesRaw(sel, cast[ptr UncheckedArray[float64]](buffer), int(cols),
              int(rowStride), log)
  firstProblem = if n > 0: log[0].msg & " (" & $n & " traces left zero)" else: ""
  int64(n)

# ---------------------------------------------------------------- gathers --

proc fileGathers*(fo: FileObj, how: string): lent seq[Gather] =
  ## The file's gathers, computed once (needs keys).
  fo.requireKeys(how)
  if not fo.gathersDone:
    fo.gathers = fo.f.index.gathers
    fo.gathersDone = true
  fo.gathers

proc componentGroups*(fo: FileObj, first, count: int64, how: string,
    groupOf: var openArray[int64]): int64 =
  ## Fills `groupOf[k]` with the component group of trace `first + k` (-1 for
  ## none) and returns the number of groups. `groupOf.len` must be `count`.
  fo.requireKeys(how)
  if not rangeOk(first, count, fo.traceCount): raiseArg("trace range out of bounds")
  assert groupOf.len == count
  for k in 0..<int(count): groupOf[k] = -1
  let cg = fo.f.index.componentGroups(int(first) ..< int(first + count))
  for g, grp in cg:
    for i in grp.traces: groupOf[i - int(first)] = int64(g)
  int64(cg.len)

# --------------------------------------------------------------- geometry --

proc checkIndex(index: int32): int16 =
  if index < int32(low(int16)) or index > int32(high(int16)):
    raiseArg("point index out of range")
  int16(index)

proc addSource*(go: GeometryObj, line, point: float64, index: int32, x, y, z: float64) =
  go.s.table.addSource(line, point, checkIndex(index), x, y, z)

proc addReceiver*(go: GeometryObj, line, point: float64, index: int32, x, y, z: float64) =
  go.s.table.addReceiver(line, point, checkIndex(index), x, y, z)

proc mapLine*(go: GeometryObj, name: string, line: float64) =
  ## Maps a text line name (SPS 1.0, P1) to a line number, for later loads.
  if name.len == 0: raiseArg("empty line name")
  if line.isNaN: raiseArg("line number is NaN")
  go.names.names[name] = line

proc setSurveyOptions*(go: GeometryObj, trailingDigits, multiComponent: bool) =
  go.names.trailingDigits = trailingDigits
  go.s.multiComponent = multiComponent

proc checkSurveyLog(log: DiagLog) =
  if log.isFatal: raise newException(IOError, log[log.len - 1].msg)

proc loadSps*(go: GeometryObj, path: string): DiagLog =
  ## Adds an SPS file's stations and relations; returns the reader's and the
  ## join's diagnostics. Raises `IOError` when the file cannot be read.
  let f = readSps(path)
  checkSurveyLog(f.log)
  result = f.log
  go.s.addSps(f, go.names)
  result.add go.s.log
  go.s.log = DiagLog() # returned, not kept

proc loadP1*(go: GeometryObj, path: string, gridDecimals, depthDecimals: int,
    elevation: bool): DiagLog =
  ## Adds a P1 file's shotpoints as sources; see `loadSps`.
  if gridDecimals notin 0..8 or depthDecimals notin 0..8: raiseArg("decimals must be 0-8")
  let f = readP1(path, P1Options(gridDecimals: gridDecimals, depthDecimals: depthDecimals))
  checkSurveyLog(f.log)
  result = f.log
  go.s.addP1(f, go.names, elevation)
  result.add go.s.log
  go.s.log = DiagLog() # returned, not kept

proc surveyCounts*(go: GeometryObj): (int64, int64, int64) =
  ## Sources, receivers and relation runs held.
  (int64(go.s.table.sources.len), int64(go.s.table.receivers.len), int64(go.s.relationCount))

proc applyGeometry*(fo: FileObj, go: GeometryObj, overwrite: bool, how: string): int64 =
  ## Fills the keys from `go` (stations from relations, then coordinates);
  ## returns the traces updated.
  fo.requireKeys(how)
  result = int64(fo.f.index.applySurvey(go.s, overwrite))
  fo.gathersDone = false # sources and receivers may now be told apart

# --------------------------------------------------------------- prefetch --

proc checkRing(fo: FileObj, chunkTraces, depth, cols: int64) =
  if chunkTraces <= 0 or depth <= 0 or chunkTraces > MaxChunkTraces or depth > MaxDepth or
      cols < -1:
    raiseArg("need 0 < chunk_traces <= 2^24, 0 < depth <= 1024, cols >= -1")

proc checkRingSize(fo: FileObj, depth, chunkTraces, width: int64, dtype: Dtype) =
  # The prefetch ring (depth slots of min(chunk, traces) rows) fits the limit.
  let rows = max(1'i64, min(chunkTraces, fo.traceCount))
  if not (width >= 0 and depth > 0 and depth <= MaxBufferBytes div max(1'i64, rows) and
      fitsBuffer(depth * rows, width, elemSize(dtype)) and
      canAllocate(depth * rows * width * elemSize(dtype))):
    raiseArg("depth x chunk x cols exceeds the library's buffer limit (1 TiB)")

proc openPrefetch*(fo: FileObj, first, last, chunkTraces, depth, cols: int64,
    dtype: Dtype): PrefetchObj =
  ## Read-ahead over traces `first ..< last` (last = -1: to the end).
  fo.checkRead()
  let stop = if last < 0: fo.traceCount else: last
  if first < 0 or first > stop or stop > fo.traceCount: raiseArg("trace range out of bounds")
  fo.checkRing(chunkTraces, depth, cols)
  let w = if cols >= 0: cols
          elif first < stop: int64(fo.f.maxSamples(int(first) ..< int(stop)))
          else: 0
  fo.checkRingSize(depth, chunkTraces, w, dtype)
  result = PrefetchObj(file: fo, dtype: dtype)
  if dtype == dtF32:
    result.p32 = newPrefetcher[float32](fo.f, int(first), int(stop), int(chunkTraces),
      int(depth), int(cols))
  else:
    result.p64 = newPrefetcher[float64](fo.f, int(first), int(stop), int(chunkTraces),
      int(depth), int(cols))

proc openPrefetch*(fo: FileObj, sel: sink seq[int], chunkTraces, depth, cols: int64,
    dtype: Dtype): PrefetchObj =
  ## Read-ahead over a trace selection (already checked by `listSelection`).
  fo.checkRead()
  fo.checkRing(chunkTraces, depth, cols)
  fo.checkRingSize(depth, chunkTraces,
    (if cols >= 0: cols else: int64(fo.f.maxSamples(sel))), dtype)
  result = PrefetchObj(file: fo, dtype: dtype)
  if dtype == dtF32:
    result.p32 = newPrefetcher[float32](fo.f, sel, int(chunkTraces), int(depth), int(cols))
  else:
    result.p64 = newPrefetcher[float64](fo.f, sel, int(chunkTraces), int(depth), int(cols))

proc take*(po: PrefetchObj, wait: bool, chunk: var ChunkObj): ChunkStatus =
  ## The next chunk: waits for it (`wait`) or returns `csNotReady`.
  template body(pf: untyped, T: typedesc) =
    var c: PrefetchChunk[T]
    if (if wait: pf.next(c) else: pf.tryNext(c)):
      chunk = ChunkObj(first: int64(c.first), count: int64(c.count),
        failed: int64(c.failed), samples: newTensorObj(move c.samples))
      result = csChunk
    elif pf.atEnd: result = csEnd
    else: result = csNotReady
  if po.dtype == dtF32: body(po.p32, float32) else: body(po.p64, float64)

func positions*(po: PrefetchObj): int64 =
  int64(if po.dtype == dtF32: po.p32.positions else: po.p64.positions)

proc seek*(po: PrefetchObj, first, last: int64) =
  let n = po.positions
  let stop = if last < 0: n else: last
  if first < 0 or first > stop or stop > n: raiseArg("position range out of bounds")
  if po.dtype == dtF32: po.p32.seek(int(first), int(stop))
  else: po.p64.seek(int(first), int(stop))

proc traceAt*(po: PrefetchObj, pos: int64): int64 =
  ## The trace at position `pos`, or -1.
  if pos < 0 or pos >= po.positions: -1
  elif po.dtype == dtF32: int64(po.p32.traceAt(int(pos)))
  else: int64(po.p64.traceAt(int(pos)))

proc close*(po: PrefetchObj) =
  ## Joins the worker; the file can go after this.
  po.p32.close()
  po.p64.close()

# ---------------------------------------------------------------- editing --

proc openEditorObj*(path, journal: string): EditorObj =
  var ed = openEditor(path, journal) # opened first, as in `openFile`
  EditorObj(ed: move ed, log: LogObj())

template editCall(eo: EditorObj, name: string, call: untyped) =
  let before = eo.ed.log.len
  if not call:
    raise newException(AbiRefusedError,
      if eo.ed.log.len > before: eo.ed.log[eo.ed.log.len - 1].msg else: name & ": refused")

proc setTraceField*(eo: EditorObj, trace: int64, name: string, v: EditValue) =
  if trace < 0 or trace >= int64(eo.ed.file.len): raiseArg("no trace " & $trace)
  editCall(eo, name, eo.ed.setField(int(trace), name, v))

proc setRecordField*(eo: EditorObj, record: int64, name: string, v: EditValue) =
  if record < 0 or record >= int64(eo.ed.file.index.segdRecords.len):
    raiseArg("no SEG-D record " & $record)
  editCall(eo, name, eo.ed.setRecordField(int(record), name, v))

proc setFileField*(eo: EditorObj, name: string, v: EditValue) =
  editCall(eo, name, eo.ed.setField(name, v))

proc editorLog*(eo: EditorObj): LogObj =
  eo.log.syncLog(eo.ed.log)
  eo.log

proc replayJournal*(path, journalPath: string, apply: bool): DiagLog =
  ## Replays (`apply`) or rolls back a journal; see `checkJournal`.
  if apply: applyJournal(path, journalPath) else: rollbackJournal(path, journalPath)

proc checkJournal*(log: DiagLog) =
  ## Raises `IOError` for a fatal journal log, `AbiStateError` when entries
  ## could not be applied.
  if log.isFatal: raise newException(IOError, log[log.len - 1].msg)
  if log.count(sevError) > 0:
    raiseState($log.count(sevError) & " journal entries could not be applied (see the log)")

# ------------------------------------------------------------------- logs --

const codeNames* = block:
  var a: array[DiagCode, string]
  for c in DiagCode: a[c] = $c
  a

proc nifText*(lo: LogObj): lent string =
  if lo.nif.len == 0: lo.nif = lo.log.toNif
  lo.nif

# ------------------------------------------------------------- conversion --

proc convertOptions*(revMajor, revMinor, byteOrder, format, textEncoding: int64,
    applyDescale, stationHeader: bool): ConvertOptions =
  ## Checked options; raises `ValueError` for out-of-range codes.
  if revMajor notin 0..2 or revMinor notin 0..1 or byteOrder notin 0..2 or
      textEncoding notin 0..1 or format notin 0..255:
    raiseArg("SegConvertOptions out of range")
  ConvertOptions(revision: SegyRevision(major: uint8(revMajor), minor: uint8(revMinor)),
    byteOrder: ByteOrder(byteOrder), format: int(format),
    textEncoding: TextEncoding(textEncoding), applyDescale: applyDescale,
    stationHeader: stationHeader)

proc checkConvert*(log: DiagLog) =
  ## Raises `SegFormatError` for a fatal conversion log.
  if log.isFatal: raiseFormat(log[log.len - 1].msg)

proc segdConvertOptions*(revMajor, revMinor, format: int64): SegdConvertOptions =
  ## Checked SEG-D target options; raises `ValueError` for out-of-range codes
  ## (the conversion itself refuses revisions and formats it cannot write).
  if revMajor notin 0..255 or revMinor notin 0..255 or format notin 0..9999:
    raiseArg("SEG-D target revision or format out of range")
  SegdConvertOptions(revision: SegdRevision(major: uint8(revMajor), minor: uint8(revMinor)),
    format: int(format))

