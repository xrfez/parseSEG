# Python module `parseseg` (tasks 8.8, 12.2, 12.5)

A pure-Python package generated from the library's Nim API. It loads the same shared library
as C programs, through `ctypes`: `import parseseg`. Its names are the Nim names in
snake_case, and its docstrings are the Nim doc comments (`help(parseseg)`), so the Nim API
docs (`docs/api.md`) describe the Python module too.

```python
import numpy as np, parseseg

with parseseg.open_seismic("line.sgy", keys=True) as f:   # Nim: openSeismic(path, keys = true)
    print(f.kind, len(f), f.max_samples, f.sample_interval_us(0))
    a = f.read_traces(range(500)).numpy()             # float32 [500, ns], no copy
    b = np.asarray(f.read_traces([9, 3, 4], dtype="float64"))
    out = np.empty((100, 2000), np.float32)
    failed = f.read_traces_into(range(1000, 1100), out)   # decode into the caller's array
    print(f.trace_keys(0)["rcv_x"], f.trace_field(0, "trace.sourceX"), f.gathers()[:1])
    with parseseg.Prefetcher(f, range(len(f)), chunk_traces=256, depth=4) as p:
        for c in p:                                   # decoded ahead on a worker thread
            show(c["first"], c["samples"].numpy())
```

## Build

`nim pylib` builds `bin/python/parseseg/`: the generated `__init__.py` (committed as
`python/parseseg/__init__.py`) next to the C ABI library (`libparseseg.so`,
`libparseseg.dylib`, `parseseg.dll`). Put `bin/python` on `sys.path` or copy the package into
site-packages. `PARSESEG_LIBRARY` overrides the library path (for tests).

- One binary serves C and Python. Nothing links libpython, so one build serves every
  Python 3 on the platform.
- On import the module calls `seg_init()` and refuses a library with another ABI version.

## Names, derived from Nim

Every function comes from a `{.segApi.}` proc of the Nim core (see `c_abi.md`):

| Nim | Python |
|---|---|
| `{.segHandle.}` type `SeismicFile` | class `SeismicFile` (`close()`, `with`) |
| `proc traceKeys(f: SeismicFile, trace: int)` | method `f.trace_keys(trace)` |
| `func kind(f: SeismicFile)` (only the receiver) | property `f.kind` |
| `{.segField.}` field `tape` | property `g.tape` (settable unless read-only) |
| `proc openSeismic(path, ...)` | function `parseseg.open_seismic(path, ...)` |
| `newPrefetcher(f, ...)`, `initSurveyGeometry()` | constructors `Prefetcher(f, ...)`, `SurveyGeometry()` |
| `len`, `[]` | `len(x)`, `x[i]` (negative indices, `IndexError`), iteration |
| `next` | also the iterator protocol (`for c in p`) |
| `Slice[int]` / `openArray[int]` overloads | one function taking a `range` (step 1) or a sequence |
| `typedesc` / generic `T` | `dtype="float32"` / `"float64"` |
| enum value | its string (`"SEG-Y"`, `"shot"`, `"big"`) |
| object result | a dict with snake_case keys (nested objects nest; a `Slice` is a `range`) |
| object parameter | a dict of the fields to change, or a tuple of all of them (`None`: the defaults) |
| `DiagLog` | a `DiagLog` object: a sequence of diagnostic dicts, `count`, `has_errors`, `is_fatal`, `to_nif()` |
| `FieldValue` | `int`, `float` or `str` |

Parameter names and defaults are the Nim ones (`open_seismic(path, twos_complement8015=False,
keys=False)`). Integers are range-checked before they reach C (ctypes would wrap them
silently).

Python-only protocol code is hand-written in `src/parseSEG/abi/gen/extras.py` and spliced
into the module: the `Tensor` numpy/DLPack/list/bytes protocols, `__repr__`s, and the
buffer-protocol conversion of `read_traces_into`'s array. The runtime helpers (loading,
argument checks, exceptions, handle lifetime) are in `src/parseSEG/abi/gen/runtime.py`.

| Nim raises | C status | Python exception |
|---|---|---|
| `ValueError` | `SEG_ERR_ARGUMENT` | `parseseg.ArgumentError` (also `ValueError`) |
| `SegFormatError` | `SEG_ERR_FORMAT` | `parseseg.FormatError` (also `ValueError`) |
| `IOError` / `OSError` | `SEG_ERR_IO` | `parseseg.IOError` (also `OSError`) |
| `AbiMemoryError` | `SEG_ERR_MEMORY` | `MemoryError` |
| a returned `DiagLog` with a fatal entry | `SEG_ERR_IO` / `SEG_ERR_FORMAT` | `IOError` / `FormatError`, with `e.diagnostics` |
| `AbiEnd`, `AbiNotReady` | `SEG_END`, `SEG_NOT_READY` | the call returns `None` |
| anything else | `SEG_ERR_INTERNAL` | `parseseg.InternalError` (also `RuntimeError`) |

All derive from `parseseg.Error`; a call on a closed object raises `parseseg.StateError`.
Wrong Python types (a path that is not a `str`, a non-`SurveyGeometry` for `apply_survey`, a
non-buffer for `read_traces_into`, a `range` with a step) raise `TypeError`.

## API

| Python | Nim |
|---|---|
| `open_seismic(path, twos_complement8015=False, keys=False)` → `SeismicFile` | `openSeismic` |
| `len(f)`, `f.kind`, `f.record_count`, `f.max_samples`, `f.has_keys`, `f.is_open`, `f.path`, `f.demux_path`, `f.log` | `len`, `kind`, ... |
| `f.trace_entry(i)`, `f.trace_keys(i)` → dict (`time`: UTC POSIX seconds, NaN if unknown); `f.copy_bytes(offset, n)` → bytes; `f.sample_interval_us(trace=0)` | `traceEntry`, `traceKeys`, `copyBytes`, `sampleIntervalUs` |
| `f.trace_field(i, name)`, `record_field(r, name)`, `file_field(name)` → int/float/str | `traceField`, ... |
| `f.trace_headers(i)`, `f.record_headers(r)`, `f.file_headers()` → `HeaderListing`, a sequence of row dicts (`block_name`, `kind`, `field`, `value`, `offset`, `size`, `block_offset`, `block_size`; `list(...)` gives a list); `field_names(kind)` → list of str (`kind` a `HeaderBlock` string such as `"SEG-Y trace"`) | `traceHeaders`, ..., `fieldNames` |
| `HeaderPatch()`: `add(scope, index, name, value)` (`scope` `"file"`, `"record"` or `"trace"`), `len(p)`, `write(path)` (a NIF patch; apply it with `parseSEG headers import`, dry run first, or Nim `importHeaders`) | `HeaderPatch`, `writeHeaderPatch` |
| `f.summary()` → dict (standard, revision, byte order, format code, counts, field records, sample interval, record length, coordinate units, CRS format); `f.channel_sets()` → list of dicts; `f.crs_text()` → str | `summary`, `channelSets`, `crsText` |
| `f.read_traces(traces, dtype="float32")` → `Tensor` (ArgumentError for traces out of range; FormatError when a trace cannot be decoded) | `readTraces` |
| `f.read_traces_into(traces, dst, row=0)` → failed count | `readTracesInto` |
| `f.gathers()` → list of dicts, `f.component_group_ids(traces)` → list | `gathers`, `componentGroupIds` |
| `SurveyGeometry()`, `add_source`, `add_receiver`, `add_sps(path, opts=None)`, `add_p1(path, grid_decimals=0, depth_decimals=0, elevation=False)`, `map_line`, `trailing_digits`, `multi_component`, `tape`, `source_count`, `receiver_count`, `relation_count`, `log`; `f.apply_survey(g, overwrite=False)` | `SurveyGeometry` procs, `applySurvey` |
| `Prefetcher(f, traces, chunk_traces=256, depth=4, cols=-1, dtype="float32")`: `next()` / `try_next()` → `{"first", "count", "failed", "samples"}` or None, iteration, `at_end`, `len(p)` (positions), `seek(span)`, `trace_at(pos)` | `newPrefetcher` and its procs |
| `open_editor(path, journal_path="")` → `HeaderEditor`: `set_trace_field` / `set_record_field` / `set_file_field(..., value)` → bool, `edits`, `log`, `journal_path` | `openEditor`, ... |
| `f.geometry_changes(fields=None)` → dict, `f.preview_geometry(fields=None)` → `DiagLog`, `editor.write_geometry(f, fields=None)` → dict, `copy_with_geometry(src, dst, g, fields=None, overwrite=False)`, `convert_with_geometry(src, dst, g, opts=None, fields=None, overwrite=False)` → `DiagLog` (`fields`: a dict of `source_xy`, `receiver_xy`, `elevations`, `midpoints`, `offsets`, `stations`) | `geometryChanges`, `previewGeometry`, `writeGeometry`, `copyWithGeometry`, `convertWithGeometry` |
| `apply_journal(path, journal_path)`, `rollback_journal` → `DiagLog` | `applyJournal`, `rollbackJournal` |
| `convert_file(src_path, dst_path, opts=None)`, `convert_segd_revision(src_path, dst_path, opts=None)` → `DiagLog` | `convertFile`, `convertSegdRevision` |
| `version()`, `abi_version()`, `status_name(status)` | |

- Handles have `close()` and are context managers. After `close()` any call raises
  `StateError`. A `Prefetcher` keeps its file's map open, as in C.
- Options are dicts of `ConvertOptions` / `SegdConvertOptions` / `SpsOptions` fields:
  `convert_file(src, dst, {"revision": (1, 0), "byte_order": "little"})`. Enum fields take
  the value's name: `convert_segd_revision(src, dst, {"revision": (2, 1), "format": "8058"})`,
  `convert_file(src, dst, {"format": "5"})` (`"keep"` is the default for both).
- A diagnostic dict holds `severity` ("info", "warning", "error", "fatal"), `code`, `offset`,
  `loc` (`file`, `record`, `channel_set`, `trace`, `block_index`, `field`) and `msg`, as the
  Nim `Diagnostic`.
- Edit values may be `int`, `float`, `str`, or anything with `__index__` / `__float__` (such
  as numpy scalars). A refused edit returns `False`; the editor's `log` says why.

## Tensors and numpy

- `Tensor` is the library's tensor, `[traces, samples]`, float32 or float64 (`shape`,
  `dtype`, `view`).
  - `__dlpack__` / `__dlpack_device__` hand it to numpy (`np.from_dlpack`) or PyTorch
    without copying (`seg_tensor_to_dlpack` in a `dltensor` capsule).
  - `__array__` makes `np.asarray(t)` a zero-copy view (it copies only when a different
    `dtype` is asked for). `t.numpy()` is `np.from_dlpack(t)`.
  - The DLPack tensor holds a reference to the samples, so a numpy array outlives its
    `Tensor`, the file and the prefetcher. A capsule nobody consumed calls the deleter in its
    destructor.
  - Without numpy, `tolist()` and `tobytes()` (native-endian, row-major) still work, and
    `numpy()` raises `ImportError`.
- `read_traces_into(traces, dst, row=0)` decodes into a caller's writable 2-D array through
  the buffer protocol (`PyObject_GetBuffer`), with no intermediate buffer. Rows must be
  contiguous (C order); the row stride may be larger, as for `big[::2, 10:2011]`.
  `dst.shape[1]` sets how many samples are written: longer traces are cut, shorter ones are
  zero-padded. The dtype must be native float32 or float64. A read-only array raises
  `BufferError`.

## Threads and the GIL

- ctypes releases the GIL during every call, so all decoding (and waiting in
  `Prefetcher.next`) runs without it, and Python threads read one file in parallel.
- The library serializes calls on one handle, except the reads (see `c_abi.md`).
- Each method counts its call in flight. `close()` from another thread marks the object
  closed at once (new calls raise `StateError`), and the last call to return releases the
  handle, so nothing is freed under a running call. `close()` (or leaving `with`) releases
  the file's mapping immediately when no call is running and no prefetcher holds it.

## Tests

`tests/tpython.nim` builds the library, puts it next to the committed generated package and
runs `tests/python/test_pyapi.py` under `python3 -I`: once with numpy and once with numpy
hidden (`PARSESEG_NUMPY_PATH` adds a numpy directory when numpy is not installed). The script
covers every function, every exception class, zero-copy and lifetime checks,
`read_traces_into` layouts, threads, prefetch, edits with a journal round trip, and
conversion. `tests/tcapi.nim` checks that the committed module equals a fresh build's.
