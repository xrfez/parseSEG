# C ABI (tasks 8.1, 12.2, 12.5)

parseSEG is built to be embedded. Nim programs `import parseSEG`. Programs in any other
language load `libparseseg.so` / `parseseg.dll` / `libparseseg.dylib` and include
`include/parseseg.h`. This note fixes the rules of that C boundary. The header carries the
per-function documentation.

## Facts the design rests on (probed 2026-11-07, Nim 2.4, Linux, gcc 12)

| Probe | Result |
|---|---|
| `--app:lib --noMain --header` | Builds the shared library. The generated header declares `NimMain` and every `exportc` proc. |
| Plain objects (scalars and fixed arrays only) | Emitted as real C structs, but with mangled names (`tyObject_TraceEntry__Nox…`) unless the type has `exportc`. |
| Objects holding `seq` / `ref` / `string` (`Tensor`, `SeismicFile`, `TraceIndex`) | Forward declarations only. Returning one by value cannot be called from C. |
| Generated header | Includes `nimbase.h` from the compiler, and has no comments. |
| `Tensor[T]` layout | 128 bytes: `shape`, `strides` (`array[6, int]` plus a length each), `offset`, then a `ref` to the storage holding `raw_buffer`. The data is a plain C-contiguous buffer, like numpy's. |
| Host threads calling in, default allocator | **Segfault**: the thread-local allocator is not set up on threads Nim did not create. |
| Host threads calling in, `-d:useMalloc` | Works: 4 pthreads × 2000 allocate/release cycles. |
| Defects inside an export (`--panics:off`, the default) | Catchable. One that escapes an export leaves the thread's pending-error flag set (goto exceptions), and every later call on that thread returns early, as if successful, doing nothing (13.3 review). So `segGuard` catches Defects too (see decision 8). |
| `GC_ref`/`GC_unref` on a `ref` cast to `pointer` | Keeps the object alive across the boundary; releases it correctly. |

## Decisions

1. **Build.** `nim lib` runs `nim c --app:lib --noMain --mm:atomicArc --threads:on`
   `-d:useMalloc -d:release -d:segCapi src/parseSEG/bindings.nim`.
   - `useMalloc` lets any host thread call in with no per-thread setup, and lets ASan and
     valgrind see every allocation.
   - `atomicArc` makes reference counts atomic, so a handle (for example a tensor shared
     with a DLPack consumer) may be released from any thread. The library builds no
     reference cycles, so it needs no cycle collector.
   - Release builds use a fresh nimcache and no incremental compilation (`config.nims`).
2. **Initialization.** The host calls `seg_init()` once before anything else. It runs `NimMain`,
   is idempotent and thread-safe, and returns `SEG_ABI_VERSION`. No teardown call is needed.
3. **Names come from the Nim core (task 12.5).** There is no separate C vocabulary: the C
   name of everything is derived from its Nim name, so the C, Python and Nim names agree.

   | Nim | C |
   |---|---|
   | `{.segHandle.}` type `SeismicFile` | opaque `SegSeismicFile`, released by `seg_seismic_file_release` |
   | `proc traceKeys(f: SeismicFile, trace: int)` | `seg_seismic_file_trace_keys(SegSeismicFile *, int64_t trace, SegTraceKeys *out)` |
   | `proc openSeismic(path, ...)` (no handle first) | `seg_open_seismic(...)` |
   | `newX` / `initX` returning handle `X` | `seg_x_new` |
   | `len`, `[]` | `seg_x_len`, `seg_x_get` |
   | `{.segField.}` field `tape` of a handle | `seg_x_tape`, `seg_x_set_tape` (unless read-only) |
   | enum `GatherKind`, value `gkShot = "shot"` | `SEG_GATHER_KIND_SHOT` |
   | object `ConvertOptions` | struct `SegConvertOptions`, `seg_init_convert_options` (for parameters) |
   | boundary type `XObj` | `SegX` (`TensorObj` → `SegTensor`) |

   C cannot overload. A `Slice[int]` / `openArray[int]` pair of one name becomes `<name>_range`
   (`x_first, x_last`, both included, as Nim's `a..b`) and `<name>` (`const int64_t *x,
   int64_t x_len`); any other overload of an exported name fails the build. The prefix is
   `seg`, so the project name never reaches the C API.
4. **The core declares its own boundary.** `{.segApi.}` sits on the public core procs
   (`traceindex`, `headerfields`, `summary`, `headerlist`, `headernif`, `gathers`, `edit`,
   `join`, `diagnostics`, `convert`, `revconvert`), `{.segHandle.}` on the types that cross as handles (`SeismicFile`,
   `HeaderEditor`, `SurveyGeometry`, `DiagLog`, `HeaderListing`, `HeaderPatch`) and
   `{.segField.}` on fields exported as
   properties. The pragmas (`src/parseSEG/abi/pragmas.nim`) need only `std/macros`, and
   without `-d:segCapi` they change nothing.
   - Under `-d:segCapi` each pragma records the routine's resolved signature in a
     `macrocache` table. `segFinish`, at the end of `src/parseSEG/abi/api.nim`, generates from
     all of them: the C exports, `include/parseseg.h` (with the core's doc comments) and the
     Python module (`python.md`).
   - `api.nim` holds only what the core cannot say: the dtype-erased `Tensor` and
     `Prefetcher` handles over the generic `Tensor[T]` and `Prefetcher[T]`, the reads that
     make them, DLPack, and the version and status names. Each adapter must overload a core
     routine with the same name and parameter names; `segFinish` checks this at compile time
     (a generic `T` becomes `dtype`) and gives the adapter the core routine's doc. Those
     with no core counterpart are marked `abiOnly`.
   - The hand-written prose and the DLPack and `SegValue` declarations are in
     `src/parseSEG/abi/gen/header_preamble.h`. The header stays self-contained (C99
     `<stdbool.h>`, `<stdint.h>`, `<stddef.h>`, no `nimbase.h`) and compiles as C and C++.
   - Tests keep it honest: the generated header and Python module must equal the committed
     ones (`tcapi`, and CI after building every target); a C program checks
     `sizeof`/`offsetof` of every struct against Nim's (`seg_sizeof`, `seg_offsetof`); every
     `seg_*` symbol in the library is declared in the header and the other way round; a C
     test program exercises every function.
5. **One calling convention.** Every function returns a `SegStatus`; results come back
   through trailing out-pointers, which may be NULL:

   | Nim | Parameter | Result |
   |---|---|---|
   | integers, floats | the same width (`int` → `int64_t`; a `range` is checked) | `T *out` |
   | `bool` | `bool` | `bool *out` |
   | enum | `int32_t`, checked | `int32_t *out` |
   | `string` | `const char *` (NULL: the Nim default, if any) | `char *out, int64_t out_cap, int64_t *out_len` |
   | handle | `SegX *`, not NULL | `SegX **out`, owned (NULL after a failure) |
   | `Slice[int]` | `int64_t x_first, int64_t x_last` | |
   | `openArray[int]` | `const int64_t *x, int64_t x_len` (at most 2^34) | |
   | object | `const SegX *` (NULL: `T()`), enum fields checked | `SegX *out` |
   | `seq[T]` | | `T *out, int64_t out_cap, int64_t *out_len` |
   | `FieldValue` | `const SegValue *` | `SegValue *out` (text into the caller's buffer) |
   | `seq[string]` | | `char *out, int64_t out_cap, int64_t *out_len`: each string NUL-ended |

   - Text and lists are copied into the caller's buffer: at most `out_cap` bytes (with a
     NUL) or elements, and `*out_len` is the full length, so a short buffer is detected and
     the call repeated (`out_cap` 0 asks for the length).
   - Structs are generated C mirrors of the Nim objects, with conversions, so a core type
     keeps any Nim layout: `int` becomes `int64_t`, an enum `int32_t`, a `Slice[int]` a
     `SegSlice {a, b}`, and nested objects nest. A `string` field becomes a `const char *`
     borrowed from the receiver, so it is allowed only in a `lent` result (a
     `SegDiagnostic`'s strings belong to its `SegDiagLog`). A `FieldValue` field is a
     `SegValueRef` (kind, `i`, `f`, borrowed `text` and `text_len`), under the same rule
     (`SegHeaderRow.value`).
   - A list of borrowed structs crosses as a handle with `len` and `[]`, which is the C
     iterator: `seg_diag_log_len`/`_get`, `seg_header_listing_len`/`_get`.
6. **Objects cross as opaque handles.** `SegSeismicFile` (a mapped file with its index and
   keys), `SegTensor`, `SegPrefetcher`, `SegHeaderEditor`, `SegSurveyGeometry`, `SegDiagLog`.
   - Each is a Nim `ref` (`Handle[T]` around a core value, or the adapter's own `ref`) kept
     alive with `GC_ref` and released by its `seg_<x>_release`. Releasing NULL is a no-op.
     `seg_prefetcher_close` and `seg_header_editor_close` end the work (join the worker,
     flush the journal); the handle is still released.
   - A file has no `close` on the boundary: a prefetcher may share its map, and releasing
     the last reference unmaps it.
   - Using a handle after releasing it is undefined, as with `free`.
7. **Tensors stay tensors.** Two zero-copy ways out, plus one way in:
   - `seg_tensor_view(t, &view)` fills `SegTensorView`: data pointer, dtype
     (`SEG_DTYPE_FLOAT32` or `SEG_DTYPE_FLOAT64`), rank, shape and strides in elements. The
     view is valid until `seg_tensor_release(t)`.
   - `seg_tensor_to_dlpack(t, &m)` gives a `DLManagedTensor*` (DLPack v0.8 layout, declared
     in the header) that owns a reference. The consumer calls its `deleter`. This is how
     PyTorch, JAX, CuPy and numpy (`from_dlpack`) take the data without a copy.
   - For no allocation at all, `seg_seismic_file_read_traces_into[_range]` decode into a
     buffer the caller owns, described by a `SegTensorView` (`strides[1]` = 1, any row
     stride), from row `row` on.
8. **Errors never cross as exceptions.**
   - Every export runs inside `segGuard`, which maps each `CatchableError` to a status and
     the thread's last error. A Defect (a library bug) is `SEG_ERR_INTERNAL`, with its name
     and message as the last error. Catching it also clears the thread's pending-exception
     state: a Defect let through would poison the thread, and every later call on it would
     return `SEG_OK` without doing anything (`tests/c/guard_test.c` proves the opposite).
     Builds with `--panics:on` would abort instead. Still, no export may be able to hit a
     Defect on caller input: the core's public procs raise `ValueError` for bad
     arguments (out-of-range traces and ranges, missing keys) rather than asserting, so
     `-d:danger` builds, which drop bound checks, still refuse them. The exception is `[]`
     indexing (`DiagLog[i]`), which keeps Nim's convention (`IndexDefect`, unchecked under
     `-d:danger`, like a `seq`): the generated `_get` wrapper checks the index itself.
   - Nim's allocator terminates the process when the system refuses memory. An
     out-of-memory hook cannot raise through the C backend's goto-based exceptions, so the
     adapters probe large buffers (64 MiB and up) with `malloc`/`free`, and a refusal is
     `SEG_ERR_MEMORY`. Tensors and prefetch rings are at most 1 TiB.
   - Statuses: `SEG_OK` = 0, `SEG_END`, `SEG_NOT_READY` (positive: not errors),
     `SEG_ERR_ARGUMENT` (`ValueError`, and the explicit index check of `[]`), `SEG_ERR_IO`
     (`IOError`, `OSError`), `SEG_ERR_FORMAT` (`SegFormatError`), `SEG_ERR_STATE`
     (reserved), `SEG_ERR_INTERNAL`, `SEG_ERR_MEMORY`.
   - A `proc` returning a `DiagLog` (conversions, journals) fails when the log has a fatal
     entry: `SEG_ERR_IO` for an I/O failure, else `SEG_ERR_FORMAT`, and the log still
     reaches the `SegDiagLog **` result. A `bool` result stays a result (an edit the
     editor refused is `false`, its reason in the editor's log).
   - Enum values from C are checked against the Nim enum (parameters and struct fields).
   - `seg_last_error()` returns the message of the calling thread's last failed call. It is
     kept in a fixed 1 KiB thread-local buffer, valid until that thread's next call. A Nim
     `string` threadvar would leak, because host threads never run Nim threadvar
     destructors.
   - `seg_init` is a lock-free once guard (compare-and-swap; the others spin). It must not
     touch a Nim lock, because module initialization runs inside `NimMain`.
9. **Diagnostics are data, not errors.** Opening a damaged file succeeds. Problems go into
   the handle's log, which is the library's "never silent, never interrupting" contract.
   - `seg_seismic_file_log`, `seg_header_editor_log` and `seg_survey_geometry_log` return
     an owned copy (`SegDiagLog **`); the conversions and journal calls return their own.
   - Read entries with `seg_diag_log_len` / `seg_diag_log_get` (into a `SegDiagnostic`;
     `code` is a `SEG_DIAG_CODE_*` constant, `loc` a `SegLocation`), `seg_diag_log_count`,
     or `seg_diag_log_to_nif` (the whole log as NIF text).
10. **Threads.**
    - Any thread may call in.
    - Calls on one handle are serialized by a lock in the handle (the generated wrappers take
      it), except the reads (`seg_seismic_file_read_traces*`, `{.segApi(concurrent).}`),
      which only read the map and run in parallel.
    - `SegPrefetcher` runs its own worker thread; `seg_prefetcher_next` waits holding the
      prefetcher's lock.
    - A `SegPrefetcher` holds a reference to its `SegSeismicFile`. Releasing the file first
      is safe: the map stays open until the prefetcher is released too.
11. **Inputs.** Paths and field names are NUL-terminated UTF-8. Counts and indices are
    `int64_t`.
12. **Versioning.** `SEG_ABI_VERSION` (an integer in the header) and `seg_init()` /
    `seg_abi_version()` must match. Bump `AbiVersion` in `api.nim` on any incompatible
    change. Version 3 (task 12.5) derives every name from the core; version 2 (task 12.2) was
    the first generated one; version 1 was hand-written. `seg_version()` returns the package
    version string.
13. **Adding a function.** Add `{.segApi.}` to the public core proc (it raises on failure and
    uses the types of the table in 5), run `nim lib`, commit the regenerated
    `include/parseseg.h` and `python/parseseg/__init__.py`, and add C and Python tests. A new
    handle type needs `{.segHandle.}` on its declaration; structs and enums need nothing.
    Only a generic routine needs an adapter in `api.nim`.
14. **SEG-2.** A SEG-2 file opens like the others (`SEG_SEISMIC_KIND_SEG_2`). Its keyword
    strings are read with `seg_seismic_file_seg2_string_count(f, trace)`,
    `seg_seismic_file_seg2_keyword(f, trace, n, ...)` and `..._seg2_value(...)` (trace -1:
    the File Descriptor Block), or by name through `seg_seismic_file_trace_field` /
    `..._file_field` (`"trace.SAMPLE_INTERVAL"`, `"file.UNITS"`: text values; fixed fields
    such as `"trace.numSamples"`: integers). Edits of SEG-2 headers are refused (`false`).
    `SegConvertOptions.target` (`SEG_SEISMIC_KIND_*`) picks the output standard of
    `seg_convert_file`, with the nested `segd` and `seg2` options.

## Out of scope for now

Writing SEG-Y/SEG-D files from C (other than in-place edits and `seg_convert`), vendor-map
registration from C, and tape devices from C. The Nim API covers all of these.
