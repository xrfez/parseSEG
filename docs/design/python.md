# Python module `parseseg` (tasks 8.8, 12.2)

A pure-Python package generated from the library's boundary declaration. It loads the same
shared library as C programs through `ctypes`: `import parseseg`. The docstrings carry the
per-function documentation (`help(parseseg)`), taken from the Nim procs' doc comments.

```python
import numpy as np, parseseg

with parseseg.open("line.sgy") as f:            # keys=True: geometry per trace
    print(f.kind(), f.trace_count(), f.max_samples(), f.sample_interval())
    a = f.read(0, 500).numpy()                  # float32 [500, ns], no copy
    b = np.asarray(f.read_traces([9, 3, 4], dtype="float64"))
    out = np.empty((100, 2000), np.float32)
    failed = f.read_into(out, first=1000)       # decode into the caller's array
    print(f.trace_keys(0)["rcv_x"], f.trace_field(0, "trace.sourceX"), f.gathers()[:1])
    with f.prefetch(chunk_traces=256, depth=4) as p:
        while (c := p.next()) is not None:      # decoded ahead on a worker thread
            show(c["first"], c["samples"].numpy())
```

## Build

`nim pylib` builds `bin/python/parseseg/`: the generated `__init__.py` (committed as
`python/parseseg/__init__.py`) next to the C ABI library (`libparseseg.so`,
`libparseseg.dylib`, `parseseg.dll`). Put `bin/python` on `sys.path` or copy the package into
site-packages. `PARSESEG_LIBRARY` overrides the library path (for tests).

- One binary serves C and Python. Nothing links libpython, so one build serves every
  Python 3 on the platform, and there is no nimpy (and no nimpy patch) any more.
- On import the module calls `seg_init()` and refuses a library with another ABI version.

## One declaration

Every function is an ordinary Nim proc in `src/parseSEG/abi/api.nim` with `{.segApi.}`. The
pragma (`src/parseSEG/abi/segapi.nim`) generates the C export, the header declaration and the
Python function from the proc's signature (see `c_abi.md`). The Python side follows these
rules:

- A proc whose first parameter is a handle becomes a method of that handle's class
  (`SeismicFile`, `Samples`, `Prefetch`, `Editor`, `Geometry`); the others are module
  functions. `{.segApi(ctor).}` makes a proc the class constructor (`parseseg.Geometry()`).
- Names and keywords are the Nim names in snake_case, with the Nim defaults.
- Enums are strings (`dtype="float64"`, `byte_order="little"`); structs come back as dicts
  with snake_case keys, their enum fields as strings; lists as lists; a `DiagLog` as a list
  of diagnostic dicts; header values as `int`, `float` or `str`.
- Integers are range-checked before they reach C (ctypes would wrap them silently).
- Python-only protocol code is hand-written in `src/parseSEG/abi/gen/extras.py` and spliced
  into the module: the `Samples` numpy/DLPack/list/bytes protocols, `__repr__`s, and the
  buffer-protocol conversion of `read_into`'s array. The runtime helpers (loading, argument
  checks, exceptions, handle lifetime) are in `src/parseSEG/abi/gen/runtime.py`.

| Nim raises | C status | Python exception |
|---|---|---|
| `ValueError` | `SEG_ERR_ARGUMENT` | `parseseg.ArgumentError` (also `ValueError`) |
| `SegFormatError` | `SEG_ERR_FORMAT` | `parseseg.FormatError` (also `ValueError`) |
| `IOError` / `OSError` | `SEG_ERR_IO` | `parseseg.IOError` (also `OSError`) |
| `AbiStateError` | `SEG_ERR_STATE` | `parseseg.StateError` (also `RuntimeError`) |
| `AbiRefusedError` | `SEG_ERR_REFUSED` | `parseseg.RefusedError` |
| `AbiMemoryError` | `SEG_ERR_MEMORY` | `MemoryError` |
| `LoggedError` | its status | its class, with `e.diagnostics` |
| `AbiEnd`, `AbiNotReady` | `SEG_END`, `SEG_NOT_READY` | the call returns `None` |
| anything else | `SEG_ERR_INTERNAL` | `parseseg.InternalError` (also `RuntimeError`) |

All derive from `parseseg.Error`. Wrong Python types (a path that is not a `str`, a
non-`Geometry` for `apply_geometry`, a non-buffer for `read_into`) raise `TypeError`.

## API

| Python | C ABI |
|---|---|
| `parseseg.open(path, keys=True, twos8015=False)` → `SeismicFile` | `seg_file_open` |
| `f.kind()`, `trace_count()`, `record_count()`, `max_samples()`, `sample_interval(trace=0)` | `seg_file_kind`, … |
| `f.trace_entry(i)`, `f.trace_keys(i)` → dict | `seg_file_trace_entry`, `seg_file_trace_keys` |
| `f.trace_field(i, name)`, `record_field(r, name)`, `file_field(name)` → int/float/str | `seg_file_*_field` |
| `f.read(first=0, count=-1, dtype="float32", cols=-1)` → `Samples` | `seg_file_read` |
| `f.read_traces(list, dtype, cols)` → `Samples` | `seg_file_read_traces` |
| `f.read_into(out, first=0)`, `f.read_traces_into(out, list)` → failed count | `seg_file_read_into`, `seg_file_read_traces_into` |
| `f.gathers()` → list of dicts, `f.component_groups(first=0, count=-1)` → list | `seg_file_gathers`, `seg_file_component_groups` |
| `parseseg.Geometry()`, `add_source`, `add_receiver`, `load_sps`, `load_p1`, `map_line`, `set_options`, `counts()`; `f.apply_geometry(g, overwrite=False)` | `seg_geometry_*`, `seg_file_apply_geometry` |
| `f.prefetch(first, last, chunk_traces, depth, cols, dtype)`, `f.prefetch_traces(list, …)` → `Prefetch` | `seg_file_prefetch*` |
| `p.next()` / `p.try_next()` → `{"first", "count", "failed", "samples"}` or None; `at_end()`, `seek`, `positions`, `trace_at` | `seg_prefetch_*` |
| `parseseg.open_editor(path, journal="")` → `Editor`: `set_trace/set_record/set_file(…, value)`, `edits()`, `diagnostics()` | `seg_editor_*` |
| `parseseg.journal_apply(path, journal)`, `journal_rollback` → diagnostics | `seg_journal_*` |
| `parseseg.convert(src, dst, revision="2.1", byte_order="big", format=0, text_encoding="ebcdic", apply_descale=False, station_header=True)` → diagnostics | `seg_convert` |
| `parseseg.convert_segd(src, dst, revision="3.0", format=0)` → diagnostics | `seg_convert_segd` |
| `f.diagnostics()` → list of dicts; `f.log_nif()` → NIF text | `seg_file_diagnostics`, `seg_file_log_nif` |
| `version()`, `abi_version()` | `seg_version`, `seg_abi_version` |

- Handles have `close()` and are context managers. After `close()` any call raises
  `StateError`. A `Prefetch` keeps its file's map open, as in C.
- `convert`, `convert_segd`, `journal_apply` and `journal_rollback` return the log. On
  failure they raise with the log attached as `e.diagnostics`.
- A diagnostic dict holds `severity` ("info", "warning", "error", "fatal"), `code`, `message`,
  `offset`, `record`, `channel_set`, `trace`, `block_index`, `file` and `field`.
- Edit values may be `int`, `float`, `str`, or anything with `__index__` / `__float__` (such
  as numpy scalars).

## Samples and numpy

- `Samples` is the library's tensor, `[traces, samples]`, float32 or float64.
  - `__dlpack__` / `__dlpack_device__` hand it to numpy (`np.from_dlpack`) or PyTorch
    without copying (`seg_tensor_to_dlpack` in a `dltensor` capsule).
  - `__array__` makes `np.asarray(s)` a zero-copy view (it copies only when a different
    `dtype` is asked for). `s.numpy()` is `np.from_dlpack(s)`.
  - The DLPack tensor holds a reference to the samples, so a numpy array outlives its
    `Samples`, the file and the prefetcher. A capsule nobody consumed calls the deleter in its
    destructor.
  - Without numpy, `tolist()` and `tobytes()` (native-endian, row-major) still work, and
    `numpy()` raises `ImportError`.
- `read_into(out)` decodes into a caller's writable 2-D array through the buffer protocol
  (`PyObject_GetBuffer`), with no intermediate buffer. Rows must be contiguous (C order); the
  row stride may be larger, as for `big[::2, 10:2011]`. `out.shape[1]` sets how many samples
  are written: longer traces are cut, shorter ones are zero-padded. The dtype must be native
  float32 or float64. A read-only array raises `BufferError`.

## Threads and the GIL

- ctypes releases the GIL during every call, so all decoding (and waiting in
  `Prefetch.next`) runs without it, and Python threads read one file in parallel.
- The library serializes calls on one handle, except the reads (see `c_abi.md`).
- Each method counts its call in flight. `close()` from another thread marks the object
  closed at once (new calls raise `StateError`), and the last call to return releases the
  handle, so nothing is freed under a running call. `close()` (or leaving `with`) releases
  the file's mapping immediately when no call is running.

## Tests

`tests/tpython.nim` builds the library, puts it next to the committed generated package and
runs `tests/python/test_pyapi.py` under `python3 -I`: once with numpy and once with numpy
hidden (`PARSESEG_NUMPY_PATH` adds a numpy directory when numpy is not installed). The script
covers every function, every exception class, zero-copy and lifetime checks, `read_into`
layouts, threads, prefetch, edits with a journal round trip, and conversion. `tests/tcapi.nim`
checks that the committed module equals a fresh build's.
