## The Python module `parseseg` (task 8.8): a native extension built with
## nimpy, wrapping the same boundary implementation as the C ABI
## (`abi/core.nim`). Build with the nimble task `pylib`:
##
##   nim c --app:lib --mm:atomicArc --threads:on -d:useMalloc -d:release -d:segPython
##     --out:parseseg.so src/parseSEGD/pyapi.nim      # parseseg.pyd on Windows
##
## Python view of the C ABI:
##
## - Handles are objects with `close()` and `with` support: `SeismicFile`,
##   `Prefetch`, `Editor`, `Geometry`, and `Samples` (a tensor).
## - Failures raise exceptions instead of returning statuses: `parseseg.Error`,
##   and below it `ArgumentError` and `FormatError` (both also `ValueError`),
##   `IOError` (also `OSError`), `StateError` and `InternalError` (both also
##   `RuntimeError`), and `RefusedError`. A refused buffer raises `MemoryError`.
##   `convert`, `journal_apply` and `journal_rollback` attach the log as
##   `e.diagnostics`.
## - Samples reach numpy (and any DLPack consumer, e.g. PyTorch) without a
##   copy: `Samples` implements `__dlpack__`, so `numpy.from_dlpack(s)`,
##   `numpy.asarray(s)` and `s.numpy()` share the library's buffer. numpy is
##   optional; `tolist()` and `tobytes()` work without it. `read_into` decodes
##   straight into a caller's writable 2-D float32/float64 array.
## - Reads, conversions and blocking prefetch calls release the GIL.
## - Diagnostics are lists of dicts; `trace_entry`/`trace_keys` are dicts with
##   snake_case keys; field values are `int`, `float` or `str`.
##
## Nim procs here are camelCase; their Python names are given to `segExport`.

when not defined(segPython):
  {.error: "build the Python module with -d:segPython (see `nim pylib`)".}

import std/[dynlib, strutils]
import nimpy/[py_lib, py_types, py_utils, raw_buffers]
import ./abi/core except SeismicFile, Prefetcher
import ./abi/exporting

pyExportModule("parseseg", doc = """
Read, index, edit and convert SEG-Y and SEG-D seismic data.

    import parseseg
    with parseseg.open("line.sgy") as f:
        samples = f.read(0, 100).numpy()   # zero-copy, float32 [100, ns]
""")

template lib(): PyLib = py_lib.pyLib

# ------------------------------------------------ CPython API not in nimpy --

type ExtraApi = object
  setObject: proc (typ, value: PPyObject) {.cdecl, gcsafe.}
  saveThread: proc (): pointer {.cdecl, gcsafe.}
  restoreThread: proc (state: pointer) {.cdecl, gcsafe.}
  capsuleIsValid: proc (c: PPyObject, name: cstring): cint {.cdecl, gcsafe.}
  numberIndex: proc (o: PPyObject): PPyObject {.cdecl, gcsafe.}
  numberFloat: proc (o: PPyObject): PPyObject {.cdecl, gcsafe.}
  isInstance: proc (o, cls: PPyObject): cint {.cdecl, gcsafe.}
  attributeError, runtimeError: PPyObject

var extra: ExtraApi
var extraLoaded: bool # only touched with the GIL held

proc api(): ptr ExtraApi =
  if not extraLoaded:
    let m = lib().module
    template fn(field, sym: untyped) =
      extra.field = cast[typeof(extra.field)](m.symAddr(sym))
      doAssert extra.field != nil, "parseseg: CPython lacks " & sym
    fn(setObject, "PyErr_SetObject")
    fn(saveThread, "PyEval_SaveThread")
    fn(restoreThread, "PyEval_RestoreThread")
    fn(capsuleIsValid, "PyCapsule_IsValid")
    fn(numberIndex, "PyNumber_Index")
    fn(numberFloat, "PyNumber_Float")
    fn(isInstance, "PyObject_IsInstance")
    extra.attributeError = cast[ptr PPyObject](m.symAddr("PyExc_AttributeError"))[]
    extra.runtimeError = cast[ptr PPyObject](m.symAddr("PyExc_RuntimeError"))[]
    extraLoaded = true
  addr extra

template withoutGil(body: untyped) =
  ## Runs `body`, which must not touch Python objects, with the GIL released.
  let ts = api().saveThread()
  try:
    body
  finally:
    api().restoreThread(ts)

proc newRef(o: PPyObject): PPyObject {.inline.} =
  incRef o
  o

# ------------------------------------------------------------- exceptions --

type PyErrKind = enum
  peError = "Error", peArgument = "ArgumentError", peFormat = "FormatError",
  peIO = "IOError", peState = "StateError", peRefused = "RefusedError",
  peInternal = "InternalError"

var errClasses: array[PyErrKind, PPyObject] # created on first use, kept forever

proc errClass(k: PyErrKind): PPyObject =
  if errClasses[k] == nil:
    let name = cstring("parseseg." & $k)
    if k == peError:
      errClasses[k] = lib().PyErr_NewException(name, lib().PyExc_Exception, nil)
    else:
      let builtin = case k
        of peArgument, peFormat: lib().PyExc_ValueError
        of peIO: lib().PyExc_OSError
        of peState, peInternal: api().runtimeError
        else: nil
      let bases = lib().PyTuple_New(if builtin == nil: 1 else: 2)
      discard lib().PyTuple_SetItem(bases, 0, newRef(errClass(peError))) # steals
      if builtin != nil: discard lib().PyTuple_SetItem(bases, 1, newRef(builtin))
      errClasses[k] = lib().PyErr_NewException(name, bases, nil)
      decRef bases
  errClasses[k]

proc raisePy(k: PyErrKind, msg: string, diagnostics: PPyObject = nil): PPyObject =
  ## Sets the Python error and returns nil, which nimpy passes on as "raised".
  ## `diagnostics` (stolen) becomes the exception's `diagnostics` attribute.
  if diagnostics == nil:
    lib().PyErr_SetString(errClass(k), cstring(msg))
  else:
    let args = lib().PyTuple_New(1)
    discard lib().PyTuple_SetItem(args, 0, nimValueToPy(msg))
    let inst = lib().PyObject_Call(errClass(k), args, nil)
    decRef args
    if inst != nil:
      discard lib().PyObject_SetAttrString(inst, "diagnostics", diagnostics)
      api().setObject(errClass(k), inst)
      decRef inst
    decRef diagnostics
  nil

template mapErrors(res: var PPyObject, body: untyped) =
  ## Runs `body` (which sets `res`), mapping every Nim exception to the
  ## matching Python one (the table in `abi/core.nim`).
  try:
    body
  except SegTruncatedError as e: res = raisePy(peFormat, "truncated: " & e.msg)
  except SegFormatError as e: res = raisePy(peFormat, e.msg)
  except IOError as e: res = raisePy(peIO, e.msg)
  except OSError as e: res = raisePy(peIO, e.msg)
  except ValueError as e: res = raisePy(peArgument, e.msg)
  except AbiStateError as e: res = raisePy(peState, e.msg)
  except AbiRefusedError as e: res = raisePy(peRefused, e.msg)
  except AbiMemoryError as e:
    lib().PyErr_SetString(lib().PyExc_MemoryError, cstring(e.msg))
    res = nil
  except Exception as e: res = raisePy(peInternal, $e.name & ": " & e.msg)

template pyGuard(body: untyped): PPyObject =
  ## The value of `body` converted by nimpy, or nil with a Python exception set.
  var res: PPyObject
  mapErrors(res):
    res = nimValueToPy((block: body))
  res

template pyDo(body: untyped): PPyObject =
  ## None after `body`, or nil with a Python exception set.
  var res: PPyObject
  mapErrors(res):
    body
    res = newPyNone()
  res

proc moduleGetattr(name: string): PPyObject {.segExport: "__getattr__".} =
  ## Module attributes made on demand: the exception classes.
  for k in PyErrKind:
    if name == $k: return newRef(errClass(k))
  lib().PyErr_SetString(api().attributeError,
    cstring("module 'parseseg' has no attribute '" & name & "'"))
  nil

proc moduleDir(): seq[string] {.segExport: "__dir__".} =
  ## `dir(parseseg)`, including the on-demand exception classes.
  result = @["SeismicFile", "Samples", "Prefetch", "Editor", "Geometry", "open", "convert",
    "open_editor", "journal_apply", "journal_rollback", "version", "abi_version",
    "__doc__", "__name__"]
  for k in PyErrKind: result.add $k

# ------------------------------------------------------------ conversions --

const KeysHint = "keys=True"

type PyDiagnostic = object
  ## One diagnostic as a Python dict (the field names are its keys).
  severity, code, message: string
  offset: int64
  record, channel_set, trace, block_index: int
  file, field: string

func toPy(log: DiagLog): seq[PyDiagnostic] =
  for d in log:
    result.add PyDiagnostic(severity: $d.severity, code: codeNames[d.code], message: d.msg,
      offset: d.offset, record: d.loc.record, channel_set: d.loc.channelSet,
      trace: d.loc.trace, block_index: d.loc.blockIndex, file: d.loc.file,
      field: d.loc.field)

func snakeCase(s: string): string =
  for c in s:
    if c.isUpperAscii: result.add '_' & c.toLowerAscii
    else: result.add c

proc snakeDict[T: object](o: T): PPyObject =
  ## `o` as a dict whose keys are its field names in snake_case.
  result = lib().PyDict_New()
  for name, v in fieldPairs(o):
    const key = snakeCase(name)
    let pv = nimValueToPy(v)
    discard lib().PyDict_SetItemString(result, key, pv)
    decRef pv

proc toPy(v: FieldValue): PPyObject =
  case v.kind
  of fvInt: nimValueToPy(v.i)
  of fvFloat: nimValueToPy(v.f)
  of fvText: nimValueToPy(v.s)

proc toEdit(o: PPyObject): EditValue =
  # str, float (incl. numpy.float64), anything with __index__ (int, bool,
  # numpy integers), then anything with __float__.
  if api().isInstance(o, cast[PPyObject](lib().PyUnicode_Type)) == 1:
    var s: string
    pyValueToNim(o, s)
    return toEditValue(s)
  if api().isInstance(o, cast[PPyObject](lib().PyFloat_Type)) == 1:
    return toEditValue(lib().PyFloat_AsDouble(o))
  let i = api().numberIndex(o)
  if i != nil:
    let v = lib().PyLong_AsLongLong(i)
    decRef i
    if lib().PyErr_Occurred() != nil:
      lib().PyErr_Clear()
      raise newException(ValueError, "integer value out of range")
    return toEditValue(int64(v))
  lib().PyErr_Clear()
  let f = api().numberFloat(o)
  if f == nil:
    lib().PyErr_Clear()
    raise newException(ValueError, "value must be an int, float or str")
  result = toEditValue(lib().PyFloat_AsDouble(f))
  decRef f

proc parseDtype(s: string): Dtype =
  case s
  of "float32", "f4", "f": dtF32
  of "float64", "f8", "d": dtF64
  else: raise newException(ValueError, "dtype must be 'float32' or 'float64', not '" & s & "'")

# ---------------------------------------------------------------- Samples --

type
  Samples = ref object of PyNimObjectExperimental
    ## A `[traces, samples]` float32/float64 tensor owned by the library.
    to: TensorObj

proc samplesOf(self: Samples): TensorObj =
  if self.to == nil: raise newException(AbiStateError, "empty Samples object")
  self.to

proc wrap(to: TensorObj): Samples = Samples(to: to)

proc shape(self: Samples): PPyObject {.segExport.} =
  ## `(traces, samples)`.
  pyGuard:
    let to = self.samplesOf
    to.refreshShape()
    (int(to.shape[0]), int(to.shape[1]))

proc dtype(self: Samples): PPyObject {.segExport.} =
  ## `"float32"` or `"float64"`.
  pyGuard: (if self.samplesOf.dtype == dtF32: "float32" else: "float64")

proc `$`(self: Samples): string {.segExport.} =
  if self.to == nil: return "<parseseg.Samples empty>"
  self.to.refreshShape()
  "<parseseg.Samples " & $self.to.shape[0] & "x" & $self.to.shape[1] & " " &
    (if self.to.dtype == dtF32: "float32" else: "float64") & ">"

proc capsuleDestructor(c: PPyObject) {.cdecl, gcsafe.} =
  # A capsule nobody consumed still owns its tensor (consumers rename it to
  # "used_dltensor" and call the deleter themselves).
  {.cast(gcsafe).}:
    if api().capsuleIsValid(c, "dltensor") == 1:
      let m = cast[ptr DLManagedTensor](lib().PyCapsule_GetPointer(c, "dltensor"))
      if m != nil and m.deleter != nil: m.deleter(m)

proc dlpack(self: Samples, stream: PPyObject = nil, max_version: PPyObject = nil,
    dl_device: PPyObject = nil, copy: PPyObject = nil): PPyObject {.segExport: "__dlpack__".} =
  ## A DLPack capsule sharing the samples (CPU, no copy).
  pyGuard:
    let m = toDlpack(self.samplesOf)
    let c = lib().PyCapsule_New(m, "dltensor", capsuleDestructor)
    if c == nil: m.deleter(m)
    c

proc dlpackDevice(self: Samples): (int, int) {.segExport: "__dlpack_device__".} =
  ## `(1, 0)`: CPU memory.
  (1, 0)

proc toNumpy(self: Samples): PPyObject {.segExport: "numpy".} =
  ## A numpy array sharing the samples (`numpy.from_dlpack(self)`).
  let np = lib().PyImport_ImportModule("numpy")
  if np == nil: return nil # ImportError
  let fromDlpack = lib().PyObject_GetAttrString(np, "from_dlpack")
  decRef np
  if fromDlpack == nil: return nil
  let args = lib().PyTuple_New(1)
  discard lib().PyTuple_SetItem(args, 0, nimValueToPy(self))
  result = lib().PyObject_Call(fromDlpack, args, nil)
  decRef args
  decRef fromDlpack

proc arrayProtocol(self: Samples, dtype: PPyObject = nil, copy: PPyObject = nil): PPyObject {.
    segExport: "__array__".} =
  ## `numpy.asarray(samples)`: zero-copy unless `dtype` differs.
  result = self.toNumpy()
  if result != nil and dtype != nil and dtype != lib().Py_None:
    let astype = lib().PyObject_GetAttrString(result, "astype")
    decRef result
    if astype == nil: return nil
    let args = lib().PyTuple_New(1)
    discard lib().PyTuple_SetItem(args, 0, newRef(dtype))
    result = lib().PyObject_Call(astype, args, nil)
    decRef args
    decRef astype

proc tolist(self: Samples): PPyObject {.segExport.} =
  ## The samples as a list of rows of floats (a copy).
  pyGuard:
    let to = self.samplesOf
    var rows: seq[seq[float64]]
    template go(t: untyped) =
      for i in 0..<t.shape[0]:
        var r = newSeq[float64](t.shape[1])
        for j in 0..<t.shape[1]: r[j] = float64(t[i, j])
        rows.add r
    if to.dtype == dtF32: go(to.t32) else: go(to.t64)
    rows

proc tobytes(self: Samples): PPyObject {.segExport.} =
  ## The samples as native-endian bytes in row-major order (a copy).
  pyGuard:
    let to = self.samplesOf
    to.refreshShape()
    let rows = int(to.shape[0])
    let cols = int(to.shape[1])
    let es = int(elemSize(to.dtype))
    var bytes = newString(rows * cols * es)
    let base = cast[ptr UncheckedArray[byte]](to.dataPointer)
    for i in 0..<rows:
      for j in 0..<cols:
        let at = (i * int(to.strides[0]) + j * int(to.strides[1])) * es
        copyMem(addr bytes[(i * cols + j) * es], addr base[at], es)
    let o = lib().PyBytes_FromStringAndSize(cast[ptr char](cstring(bytes)), Py_ssize_t(bytes.len))
    o

# ---------------------------------------------------------------- Geometry --

type
  Geometry = ref object of PyNimObjectExperimental
    ## External source/receiver coordinates by (line, point, index).
    go: GeometryObj

proc initGeometry(self: Geometry) {.segExport.} =
  self.go = GeometryObj()

proc geometryOf(self: Geometry): GeometryObj =
  if self.go == nil: self.go = GeometryObj()
  self.go

proc addSource(self: Geometry, line, point: float64, index: int, x, y: float64,
    z: float64 = NaN): PPyObject {.segExport: "add_source".} =
  ## Adds or replaces a source station; index 0 matches any point index.
  pyDo:
    if index < int(low(int32)) or index > int(high(int32)):
      raise newException(ValueError, "point index out of range")
    self.geometryOf.addSource(line, point, int32(index), x, y, z)

proc addReceiver(self: Geometry, line, point: float64, index: int, x, y: float64,
    z: float64 = NaN): PPyObject {.segExport: "add_receiver".} =
  ## Adds or replaces a receiver station; index 0 matches any point index.
  pyDo:
    if index < int(low(int32)) or index > int(high(int32)):
      raise newException(ValueError, "point index out of range")
    self.geometryOf.addReceiver(line, point, int32(index), x, y, z)

# ----------------------------------------------------------- SeismicFile --

type
  SeismicFile = ref object of PyNimObjectExperimental
    ## An open, indexed SEG-Y or SEG-D file (`parseseg.open`).
    fo: FileObj

  PyGather = object
    kind: string
    first, count, sources, receivers: int

template holding(fo: FileObj, body: untyped) =
  # A counted reference for the duration of `body`, so `close()` from another
  # thread (while the GIL is released) cannot unmap the file under a read.
  GC_ref(fo)
  try:
    body
  finally:
    GC_unref(fo)

proc fileOf(self: SeismicFile): FileObj =
  if self.fo == nil: raise newException(AbiStateError, "the file is closed")
  self.fo

proc openPy(path: string, keys: bool = true, twos8015: bool = false): PPyObject {.segExport: "open".} =
  ## Opens and indexes a SEG-Y or SEG-D disk file. `keys` also decodes the
  ## per-trace geometry (needed by `trace_keys`, `gathers`,
  ## `component_groups` and `apply_geometry`); `twos8015` reads format 8015
  ## as two's complement. Problems are in `diagnostics()`, not raised.
  pyGuard:
    var fo: FileObj
    withoutGil:
      fo = openFile(path, keys, twos8015)
    SeismicFile(fo: fo)

proc close(self: SeismicFile) {.segExport.} =
  ## Releases the file (the map stays open while a `Prefetch` uses it).
  self.fo = nil

proc closed(self: SeismicFile): bool {.segExport.} = self.fo == nil

proc enter(self: SeismicFile): SeismicFile {.segExport: "__enter__".} = self

proc exit(self: SeismicFile, excType, exc, tb: PPyObject): bool {.segExport: "__exit__".} =
  self.fo = nil
  false

proc `$`(self: SeismicFile): string {.segExport.} =
  if self.fo == nil: "<parseseg.SeismicFile closed>"
  else:
    "<parseseg.SeismicFile " & (case self.fo.kindCode
      of 1: "SEG-Y"
      of 2: "SEG-D"
      else: "unknown") & ", " & $self.fo.traceCount & " traces>"

proc kind(self: SeismicFile): PPyObject {.segExport.} =
  ## `"segy"`, `"segd"` or `"unknown"`.
  pyGuard:
    case self.fileOf.kindCode
    of 1: "segy"
    of 2: "segd"
    else: "unknown"

proc traceCount(self: SeismicFile): PPyObject {.segExport: "trace_count".} =
  pyGuard: int(self.fileOf.traceCount)

proc recordCount(self: SeismicFile): PPyObject {.segExport: "record_count".} =
  ## SEG-D records; 1 for SEG-Y.
  pyGuard: int(self.fileOf.recordCount)

proc maxSamples(self: SeismicFile): PPyObject {.segExport: "max_samples".} =
  ## Samples in the longest trace.
  pyGuard: int(self.fileOf.maxSamples)

proc traceEntry(self: SeismicFile, trace: int): PPyObject {.segExport: "trace_entry".} =
  ## Where trace `trace` lives: offset, header_bytes, num_samples, record,
  ## channel_set, scan_type, channel_type.
  pyGuard: snakeDict(self.fileOf.traceEntry(trace))

proc traceKeys(self: SeismicFile, trace: int): PPyObject {.segExport: "trace_keys".} =
  ## The geometry keys of trace `trace` (NaN where unknown); needs keys=True.
  pyGuard: snakeDict(self.fileOf.traceKeys(trace, KeysHint))

proc sampleInterval(self: SeismicFile, trace: int = 0): PPyObject {.
    segExport: "sample_interval".} =
  ## Microseconds between samples of trace `trace`.
  pyGuard: self.fileOf.sampleInterval(trace)

proc diagnostics(self: SeismicFile): PPyObject {.segExport.} =
  ## Every problem found while indexing, as dicts.
  pyGuard: self.fileOf.fileLog.log.toPy

proc logNif(self: SeismicFile): PPyObject {.segExport: "log_nif".} =
  ## The diagnostics as NIF text.
  pyGuard: self.fileOf.fileLog.nifText

proc traceField(self: SeismicFile, trace: int, name: string): PPyObject {.
    segExport: "trace_field".} =
  ## A trace header field by name (e.g. `"sourceX"`, `"THE1.receiverLine"`).
  pyGuard: self.fileOf.traceField(trace, name).toPy

proc recordField(self: SeismicFile, record: int, name: string): PPyObject {.
    segExport: "record_field".} =
  ## A SEG-D record (general header) field by name.
  pyGuard: self.fileOf.recordField(record, name).toPy

proc fileField(self: SeismicFile, name: string): PPyObject {.segExport: "file_field".} =
  ## A file-level field (SEG-Y binary header, ...) by name.
  pyGuard: self.fileOf.fileField(name).toPy

proc resolveCount(fo: FileObj, first, count: int): int64 =
  if count < 0 and first >= 0: max(0'i64, fo.traceCount - first) else: int64(count)

proc read(self: SeismicFile, first: int = 0, count: int = -1, dtype: string = "float32",
    cols: int = -1): PPyObject {.segExport.} =
  ## Decodes traces `first ..< first+count` (count -1: to the end) into new
  ## `Samples` of `[count, cols]` (cols -1: the longest trace; shorter traces
  ## are zero-padded).
  pyGuard:
    let fo = self.fileOf
    let d = parseDtype(dtype)
    fo.checkRead()
    let sel = fo.rangeSelection(first, fo.resolveCount(first, count))
    var to: TensorObj
    holding(fo):
      withoutGil:
        to = fo.readNew(sel, d, cols)
    wrap(to)

proc readTraces(self: SeismicFile, traces: seq[int64], dtype: string = "float32",
    cols: int = -1): PPyObject {.segExport: "read_traces".} =
  ## Decodes the listed traces, in list order, into new `Samples`.
  pyGuard:
    let fo = self.fileOf
    let d = parseDtype(dtype)
    fo.checkRead()
    let sel = fo.listSelection(traces)
    var to: TensorObj
    holding(fo):
      withoutGil:
        to = fo.readNew(sel, d, cols)
    wrap(to)

proc bufferDtype(buf: RawPyBuffer): Dtype =
  var f = if buf.format == nil: "B" else: $buf.format
  if f.len == 2 and f[0] in {'@', '='} or (f.len == 2 and f[0] == '<' and
      cpuEndian == littleEndian):
    f = f[1..^1]
  if f == "f" and buf.itemsize == 4: dtF32
  elif f == "d" and buf.itemsize == 8: dtF64
  else: raise newException(ValueError, "out must hold native float32 or float64, not '" &
    f & "'")

proc readIntoBuffer(fo: FileObj, outArray: PyObject, sel: proc (rows: int): seq[int]): int =
  var buf: RawPyBuffer
  outArray.getBuffer(buf, PyBUF_RECORDS)
  try:
    if buf.ndim != 2: raise newException(ValueError, "out must be 2-D [traces, samples]")
    let d = bufferDtype(buf)
    let shape = cast[ptr UncheckedArray[Py_ssize_t]](buf.shape)
    let strides = cast[ptr UncheckedArray[Py_ssize_t]](buf.strides)
    let es = int(buf.itemsize)
    if strides[1] != es or strides[0] mod es != 0 or strides[0] < shape[1] * es:
      raise newException(ValueError, "out rows must be contiguous (C order)")
    let s = sel(int(shape[0]))
    var problem: string
    var failed: int64
    holding(fo):
      withoutGil:
        failed = fo.readInto(s, d, buf.buf, int64(shape[1]), int64(strides[0] div es), problem)
    int(failed)
  finally:
    buf.release()

proc readInto(self: SeismicFile, `out`: PyObject, first: int = 0): PPyObject {.
    segExport: "read_into".} =
  ## Decodes traces `first ..< first + out.shape[0]` straight into `out`, a
  ## writable 2-D float32/float64 array with contiguous rows (e.g. a numpy
  ## array); each row gets `out.shape[1]` samples. Returns how many traces
  ## failed (left zero; see `diagnostics`).
  pyGuard:
    let fo = self.fileOf
    fo.checkRead()
    fo.readIntoBuffer(`out`, proc (rows: int): seq[int] = fo.rangeSelection(first, rows))

proc readTracesInto(self: SeismicFile, `out`: PyObject, traces: seq[int64]): PPyObject {.
    segExport: "read_traces_into".} =
  ## Decodes the listed traces into the rows of `out` (see `read_into`);
  ## `len(traces)` must equal `out.shape[0]`.
  pyGuard:
    let fo = self.fileOf
    fo.checkRead()
    let sel = fo.listSelection(traces)
    fo.readIntoBuffer(`out`, proc (rows: int): seq[int] =
      if rows != sel.len: raise newException(ValueError, "out.shape[0] != len(traces)")
      sel)

proc gathersPy(self: SeismicFile): PPyObject {.segExport: "gathers".} =
  ## Consecutive gathers as dicts: kind ("shot", "receiver", "cmp",
  ## "offset", "other", "unknown"), first, count, sources, receivers.
  pyGuard:
    var r: seq[PyGather]
    for g in self.fileOf.fileGathers(KeysHint):
      r.add PyGather(kind: $g.kind, first: g.traces.a, count: g.traces.len,
        sources: g.sources, receivers: g.receivers)
    r

proc componentGroupsPy(self: SeismicFile, first: int = 0, count: int = -1): PPyObject {.
    segExport: "component_groups".} =
  ## The multi-component group of each trace in `first ..< first+count`
  ## (-1: in none), numbered from 0.
  pyGuard:
    let fo = self.fileOf
    var g = newSeq[int64](max(0, fo.resolveCount(first, count)))
    if count >= -1: discard fo.componentGroups(first, fo.resolveCount(first, count), KeysHint, g)
    else: raise newException(ValueError, "count must be >= -1")
    g

proc applyGeometryPy(self: SeismicFile, geometry: Geometry, overwrite: bool = false): PPyObject {.
    segExport: "apply_geometry".} =
  ## Fills the trace keys from `geometry`; returns how many traces changed.
  pyGuard:
    if geometry == nil: raise newException(ValueError, "geometry must be a parseseg.Geometry")
    int(self.fileOf.applyGeometry(geometry.geometryOf, overwrite, KeysHint))

# --------------------------------------------------------------- Prefetch --

type
  Prefetch = ref object of PyNimObjectExperimental
    ## Read-ahead on a worker thread (`SeismicFile.prefetch`).
    po: PrefetchObj
    busy: bool # a call is waiting with the GIL released

  PyChunk = object
    first, count, failed: int
    samples: Samples

proc prefetchOf(self: Prefetch): PrefetchObj =
  if self.po == nil: raise newException(AbiStateError, "the prefetcher is closed")
  if self.busy: raise newException(AbiStateError, "the prefetcher is in use by another thread")
  self.po

proc prefetchPy(self: SeismicFile, first: int = 0, last: int = -1, chunk_traces: int = 256, depth: int = 4,
    cols: int = -1, dtype: string = "float32"): PPyObject {.segExport: "prefetch".} =
  ## Decodes traces `first ..< last` (last -1: to the end) ahead, in chunks
  ## of `chunk_traces`, on a worker thread with `depth` chunks buffered.
  pyGuard:
    let fo = self.fileOf
    Prefetch(po: fo.openPrefetch(first, last, chunk_traces, depth, cols, parseDtype(dtype)))

proc prefetchTraces(self: SeismicFile, traces: seq[int64], chunk_traces: int = 256, depth: int = 4,
    cols: int = -1, dtype: string = "float32"): PPyObject {.segExport: "prefetch_traces".} =
  ## Like `prefetch`, over a trace list (positions index the list).
  pyGuard:
    let fo = self.fileOf
    let d = parseDtype(dtype)
    Prefetch(po: fo.openPrefetch(fo.listSelection(traces), chunk_traces, depth, cols, d))

proc takePy(self: Prefetch, wait: bool): PPyObject =
  pyGuard:
    let po = self.prefetchOf
    var c: ChunkObj
    var st: ChunkStatus
    if wait:
      self.busy = true
      try:
        withoutGil:
          st = po.take(true, c)
      finally:
        self.busy = false
    else:
      st = po.take(false, c)
    if st == csChunk:
      nimValueToPy(PyChunk(first: int(c.first), count: int(c.count), failed: int(c.failed),
        samples: wrap(c.samples)))
    else: newPyNone()

proc next(self: Prefetch): PPyObject {.segExport.} =
  ## The next chunk, waiting for it: a dict with first (position), count,
  ## failed and samples; None at the end.
  takePy(self, wait = true)

proc tryNext(self: Prefetch): PPyObject {.segExport: "try_next".} =
  ## The next chunk if it is ready, else None (see `at_end`).
  takePy(self, wait = false)

proc atEnd(self: Prefetch): PPyObject {.segExport: "at_end".} =
  ## True once every chunk has been taken.
  pyGuard:
    let po = self.prefetchOf
    if po.dtype == dtF32: po.p32.atEnd else: po.p64.atEnd

proc seek(self: Prefetch, first: int, last: int = -1): PPyObject {.segExport.} =
  ## Restarts at positions `first ..< last` (last -1: to the end).
  pyDo: self.prefetchOf.seek(first, last)

proc positions(self: Prefetch): PPyObject {.segExport.} =
  ## Positions in the prefetcher: traces, or the trace list's length.
  pyGuard: int(self.prefetchOf.positions)

proc traceAt(self: Prefetch, pos: int): PPyObject {.segExport: "trace_at".} =
  ## The trace at position `pos`, or -1.
  pyGuard: int(self.prefetchOf.traceAt(pos))

proc close(self: Prefetch): PPyObject {.segExport.} =
  ## Stops and joins the worker.
  pyDo:
    if self.po != nil:
      if self.busy:
        raise newException(AbiStateError, "the prefetcher is in use by another thread")
      let po = self.po
      self.po = nil
      po.close()

proc enter(self: Prefetch): Prefetch {.segExport: "__enter__".} = self

proc exit(self: Prefetch, excType, exc, tb: PPyObject): PPyObject {.segExport: "__exit__".} =
  result = self.close()
  if result != nil:
    decRef result
    result = nimValueToPy(false)

# ----------------------------------------------------------------- Editor --

type
  Editor = ref object of PyNimObjectExperimental
    ## In-place header edits with an undo journal (`parseseg.open_editor`).
    eo: EditorObj

proc editorOf(self: Editor): EditorObj =
  if self.eo == nil: raise newException(AbiStateError, "the editor is closed")
  self.eo

proc openEditorPy(path: string, journal: string = ""): PPyObject {.segExport: "open_editor".} =
  ## Opens `path` for in-place, size-preserving header edits, journaled to
  ## `journal` (default: `path` & ".edits.nif").
  pyGuard: Editor(eo: openEditorObj(path, journal))

proc setTrace(self: Editor, trace: int, name: string, value: PPyObject): PPyObject {.
    segExport: "set_trace".} =
  ## Sets a trace header field; raises RefusedError when it cannot be written
  ## in place.
  pyDo: self.editorOf.setTraceField(trace, name, toEdit(value))

proc setRecord(self: Editor, record: int, name: string, value: PPyObject): PPyObject {.
    segExport: "set_record".} =
  ## Sets a SEG-D record (general header) field.
  pyDo: self.editorOf.setRecordField(record, name, toEdit(value))

proc setFile(self: Editor, name: string, value: PPyObject): PPyObject {.
    segExport: "set_file".} =
  ## Sets a file-level field (SEG-Y binary header, ...).
  pyDo: self.editorOf.setFileField(name, toEdit(value))

proc edits(self: Editor): PPyObject {.segExport.} =
  ## Edits applied so far.
  pyGuard: self.editorOf.ed.edits

proc diagnostics(self: Editor): PPyObject {.segExport.} =
  ## The editor's log, as dicts.
  pyGuard: self.editorOf.editorLog.log.toPy

proc close(self: Editor): PPyObject {.segExport.} =
  ## Flushes the journal and closes the file.
  pyDo:
    if self.eo != nil:
      let eo = self.eo
      self.eo = nil
      eo.ed.close()

proc enter(self: Editor): Editor {.segExport: "__enter__".} = self

proc exit(self: Editor, excType, exc, tb: PPyObject): PPyObject {.segExport: "__exit__".} =
  result = self.close()
  if result != nil:
    decRef result
    result = nimValueToPy(false)

# ------------------------------------------------------- module functions --

proc version(): string {.segExport.} =
  ## The package version.
  PackageVersion

proc abiVersion(): int {.segExport: "abi_version".} =
  ## The C ABI version this module matches.
  int(AbiVersion)

template withLog(log: DiagLog, check: untyped): PPyObject =
  ## The log as a list of dicts, or the exception `check` raises, with the
  ## list as its `diagnostics`.
  var res: PPyObject
  try:
    check
    res = nimValueToPy(log.toPy)
  except SegFormatError as e: res = raisePy(peFormat, e.msg, nimValueToPy(log.toPy))
  except IOError as e: res = raisePy(peIO, e.msg, nimValueToPy(log.toPy))
  except AbiStateError as e: res = raisePy(peState, e.msg, nimValueToPy(log.toPy))
  res

proc convertPy(src, dst: string, revision: string = "2.1", byte_order: string = "big", format: int = 0,
    text_encoding: string = "ebcdic", apply_descale: bool = false, station_header: bool = true): PPyObject {.
    segExport: "convert".} =
  ## Converts `src` (SEG-Y or SEG-D) to SEG-Y `dst`: revision "0", "1",
  ## "2.0" or "2.1"; byte_order "big", "little" or "pairSwapped"; format a
  ## SEG-Y format code (0: keep or choose losslessly); text_encoding "ebcdic"
  ## or "ascii". Returns the diagnostics; a failure raises with them attached.
  var log: DiagLog
  let r = pyDo:
    let parts = revision.split('.')
    if parts.len notin 1..2: raise newException(ValueError, "revision must look like '2.1'")
    let major = parseInt(parts[0])
    let minor = if parts.len == 2: parseInt(parts[1]) else: 0
    let o = convertOptions(major, minor, ord(parseEnum[ByteOrder](byte_order)), format,
      ord(parseEnum[TextEncoding](text_encoding)), apply_descale, station_header)
    withoutGil:
      log = convertFile(src, dst, o)
  if r == nil: return nil
  decRef r
  withLog(log, checkConvert(log))

proc journalPy(path, journal: string, apply: bool): PPyObject =
  var log: DiagLog
  let r = pyDo:
    withoutGil:
      log = replayJournal(path, journal, apply)
  if r == nil: return nil
  decRef r
  withLog(log, checkJournal(log))

proc journalApply(path, journal: string): PPyObject {.segExport: "journal_apply".} =
  ## Re-applies a journal's edits to `path`; returns the diagnostics.
  journalPy(path, journal, apply = true)

proc journalRollback(path, journal: string): PPyObject {.segExport: "journal_rollback".} =
  ## Undoes a journal's edits on `path`, newest first; returns the diagnostics.
  journalPy(path, journal, apply = false)

setDocStringForType(SeismicFile, "An open, indexed SEG-Y or SEG-D file; see parseseg.open.")
setDocStringForType(Samples,
  "Samples [traces, samples] owned by the library; numpy.asarray / from_dlpack share them.")
setDocStringForType(Prefetch, "Read-ahead on a worker thread; see SeismicFile.prefetch.")
setDocStringForType(Editor, "In-place header edits with an undo journal; see open_editor.")
setDocStringForType(Geometry, "External source/receiver coordinates for apply_geometry.")
