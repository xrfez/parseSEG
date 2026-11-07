# Python module `parseseg` (task 8.8)

A native extension built with [nimpy](https://github.com/yglukhov/nimpy): `import parseseg`.
It wraps the same boundary implementation as the C ABI, so both report and bound everything
the same way. The docstrings carry the per-function documentation (`help(parseseg)`).

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

`nim pylib` builds `bin/parseseg.so` (`parseseg.pyd` on Windows):
`nim c --app:lib --mm:atomicArc --threads:on -d:useMalloc -d:release -d:segPython
src/parseSEG/pyapi.nim`.

- No `--noMain`: the module initializes the Nim runtime when Python loads it.
- The module links no libpython. nimpy looks the CPython API up in the importing process, so
  one build serves every Python 3 version on that platform.
- `atomicArc` and `useMalloc`, as for the C library: Python may free a `Samples` (or a numpy
  array viewing it) on any thread.
- Windows (MinGW) adds `--tlsEmulation:off --passL:-static`, as nimpy requires.
- **nimpy patch.** nimpy 0.2.1 counts `self` in a method's argument total but not in its
  name list. Any keyword argument passed to a *method* then indexes past the list: the call
  returns NULL without an exception (`SystemError`) in checked builds, and reads out of
  bounds in `-d:danger` builds. `tools/patches/nimpy-method-kwargs.patch` fixes the count (a
  one-line change). `nim pylib` and `tests/tpython.nim` apply it to `deps/nimpy` when it is
  not applied yet, so the Atlas checkout stays the source. Delete the patch once upstream
  fixes the bug (it is unfixed as of 2026-11-07).

## One source for two boundaries

- `src/parseSEG/abi/core.nim` holds the shared implementation: handle objects, argument
  checks, the 1 TiB buffer limit and the `malloc` probe, selections, reads, prefetch, edits,
  journals, conversion options and DLPack. Its procs raise.
- `src/parseSEG/abi/exporting.nim` defines the one export pragma, `{.segExport.}` /
  `{.segExport: "name".}`:
  - with `-d:segCapi` it becomes `exportc: "name", dynlib, cdecl`;
  - with `-d:segPython` it becomes nimpy's `exportpy` (named `name` when given);
  - with neither it adds nothing.
- `capi.nim` (C) and `pyapi.nim` (Python) are thin per-target wrappers. C gets status codes,
  out-pointers and handles; Python gets exceptions, return values and objects. Each refuses to
  build as a library without its define.

| Core raises | C status | Python exception |
|---|---|---|
| `ValueError` | `SEG_ERR_ARGUMENT` | `parseseg.ArgumentError` (also `ValueError`) |
| `SegFormatError` | `SEG_ERR_FORMAT` | `parseseg.FormatError` (also `ValueError`) |
| `IOError` / `OSError` | `SEG_ERR_IO` | `parseseg.IOError` (also `OSError`) |
| `AbiStateError` | `SEG_ERR_STATE` | `parseseg.StateError` (also `RuntimeError`) |
| `AbiRefusedError` | `SEG_ERR_REFUSED` | `parseseg.RefusedError` |
| `AbiMemoryError` | `SEG_ERR_IO` | `MemoryError` |
| anything else | `SEG_ERR_INTERNAL` | `parseseg.InternalError` (also `RuntimeError`) |

All derive from `parseseg.Error`. nimpy itself would raise a fresh `nimpy.<Name>` class per
error, which no caller can catch by name. So the wrappers return a raw `PPyObject` and set a
real exception class themselves; nimpy passes NULL through. The classes are module
attributes made on first access (module `__getattr__`, PEP 562), so
`except parseseg.FormatError` works before anything was raised. `__dir__` lists them.

## API

| Python | C ABI |
|---|---|
| `parseseg.open(path, keys=True, twos8015=False)` → `SeismicFile` | `seg_file_open` (keys default **on** in Python) |
| `f.kind()`, `trace_count()`, `record_count()`, `max_samples()`, `sample_interval(i)` | `seg_file_kind`, … |
| `f.trace_entry(i)`, `f.trace_keys(i)` → dict (snake_case keys) | `seg_file_trace_entry`, `seg_file_trace_keys` |
| `f.trace_field(i, name)`, `record_field(r, name)`, `file_field(name)` → int/float/str | `seg_*_field` |
| `f.read(first=0, count=-1, dtype="float32", cols=-1)` → `Samples` | `seg_read_range` |
| `f.read_traces(list, dtype, cols)` → `Samples` | `seg_read_selection` |
| `f.read_into(out, first=0)`, `f.read_traces_into(out, list)` → failed count | `seg_read_*_into` |
| `f.gathers()` → list of dicts, `f.component_groups(first, count)` → list | `seg_file_gather*`, `seg_component_groups` |
| `parseseg.Geometry()`, `add_source`, `add_receiver`; `f.apply_geometry(g, overwrite)` | `seg_geometry_*` |
| `f.prefetch(first, last, chunk_traces, depth, cols, dtype)`, `f.prefetch_traces(list, …)` → `Prefetch` | `seg_prefetch_open*` |
| `p.next()` / `p.try_next()` → `{"first", "count", "failed", "samples"}` or None; `at_end()`, `seek`, `positions`, `trace_at` | `seg_prefetch_*` |
| `parseseg.open_editor(path, journal="")` → `Editor`: `set_trace/set_record/set_file(…, value)`, `edits()`, `diagnostics()` | `seg_editor_*` |
| `parseseg.journal_apply(path, journal)`, `journal_rollback` → diagnostics | `seg_journal_*` |
| `parseseg.convert(src, dst, revision="2.1", byte_order="big", format=0, text_encoding="ebcdic", apply_descale=False, station_header=True)` → diagnostics | `seg_convert` |
| `parseseg.convert_segd(src, dst, revision="3.0", format=0)` → diagnostics | `seg_convert_segd` |
| `f.diagnostics()` → list of dicts; `f.log_nif()` → NIF text | `seg_file_log`, `seg_log_*` |
| `version()`, `abi_version()` | `seg_version`, `seg_abi_version` |

- Handles have `close()` and are context managers. After `close()` any call raises
  `StateError`. A `Prefetch` keeps its file's map open, as in C.
- `convert`, `convert_segd`, `journal_apply` and `journal_rollback` return the log. On
  failure they raise with the log attached as `e.diagnostics`.
- A diagnostic dict holds `severity` ("info", "warning", "error", "fatal"), `code`, `message`,
  `offset`, `record`, `channel_set`, `trace`, `block_index`, `file` and `field`.
- Edit values may be `int`, `float`, `str`, or anything with `__index__` / `__float__` (such
  as numpy scalars).
- nimpy exports methods only, so sizes are `trace_count()`, not `len(f)`. Properties and
  `len()` would need type slots that nimpy does not set.

## Samples and numpy

- `Samples` is the library's tensor, `[traces, samples]`, float32 or float64.
  - `__dlpack__` / `__dlpack_device__` hand it to numpy (`np.from_dlpack`) or PyTorch
    without copying.
  - `__array__` makes `np.asarray(s)` a zero-copy view (it copies only when a different
    `dtype` is asked for). `s.numpy()` is `np.from_dlpack(s)`.
  - The DLPack capsule holds a reference to the tensor. A numpy array therefore outlives its
    `Samples`, the file and the prefetcher. A capsule that is never consumed frees its
    reference in the capsule destructor.
  - Without numpy, `tolist()` and `tobytes()` (native-endian, row-major) still work, and
    `numpy()` raises `ImportError`.
- `read_into(out)` decodes into a caller's writable 2-D array through the buffer protocol, with
  no intermediate buffer. Rows must be contiguous (C order). The row stride may be larger, as
  for `big[::2, 10:2011]`. `out.shape[1]` sets how many samples are written: longer traces
  are cut, shorter ones are zero-padded. The dtype must be native float32 or float64.

## Threads and the GIL

- `open`, `read*`, `convert`, the journal calls and `Prefetch.next` release the GIL while
  they decode. Python threads therefore read one file in parallel, which the C rules allow
  (range reads only read the map).
- A read holds a counted reference to the file for its duration. A `close()` from another
  thread then cannot unmap the file under it.
- One `Prefetch` serves one consumer at a time. A call that arrives while another thread waits
  in `next()` raises `StateError`, and so does `close()`.
- `Editor` calls keep the GIL, so edits are serialized.

## Tests

`tests/tpython.nim` builds the module with runtime checks on and runs
`tests/python/test_pyapi.py` under `python3 -I`. It runs once with numpy and once with numpy
hidden. The script covers every function, every exception class, zero-copy and lifetime
checks, `read_into` layouts, threads, prefetch, edits with a journal round trip, and
conversion.
