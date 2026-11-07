# C ABI (task 8.1)

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
| Defects inside an export (`--panics:off`, the default) | Caught by `except Exception` and turned into an error code. |
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
3. **Naming.** Functions use `seg_<object>_<verb>` and types use `Seg<Name>`. The C prefix is
   `seg`, not `parseSEG`, so the Phase 9 rename (to parseSEG) does not touch the C API.
   Constants use `SEG_`.
4. **One declaration, generated bindings (task 12.2, ABI version 2).** Every function is an
   ordinary Nim proc in `src/parseSEG/abi/api.nim` carrying `{.segApi.}`. Under
   `-d:segCapi` the macro in `src/parseSEG/abi/segapi.nim` generates, from the proc's
   resolved signature, the C export, its declaration and documentation (the proc's `##`
   comments) in `include/parseseg.h`, and the Python function (`python.md`). Structs and
   their field comments come from the Nim object types; enum constants from the Nim enums.
   The hand-written prose and the DLPack and `SegValue` declarations are in
   `src/parseSEG/abi/gen/header_preamble.h`. The header stays self-contained (C99
   `<stdbool.h>`, `<stdint.h>`, `<stddef.h>`, no `nimbase.h`) and compiles as C and C++.
   Tests keep it honest:
   - the generated header and Python module must equal the committed ones (`tcapi`, and CI
     after building every target);
   - a C program checks `sizeof`/`offsetof` of every struct against Nim's (`seg_sizeof`,
     `seg_offsetof`, generated for every struct);
   - every `seg_*` symbol in the library is declared in the header, and the other way round;
   - a C test program exercises every function.
5. **One calling convention.** Every function returns a `SegStatus`; results come back
   through trailing out-pointers, which may be NULL:

   | Nim | Parameter | Result |
   |---|---|---|
   | `int64` / `int32` / `float64` / `bool` | the C type | `T *out` |
   | enum | `int32_t`, checked | `int32_t *out` |
   | `string` | `const char *` (NULL: the Nim default, if any) | `char *out, int64_t out_cap, int64_t *out_len` |
   | handle | `SegX *`, not NULL | `SegX **out`, owned (NULL after a failure) |
   | `openArray[int64]` | `const int64_t *x, int64_t x_len` | |
   | object | `const SegX *` (NULL: the default), enum fields checked | `SegX *out` |
   | `seq[T]` | | `T *out, int64_t out_cap, int64_t *out_len` |
   | `DiagLog` | | `SegLog **out`, owned |
   | `FieldValue` | `const SegValue *` | `SegValue *out` (text into the caller's buffer) |

   Text and lists are copied into the caller's buffer: at most `out_cap` bytes (with a NUL)
   or elements, and `*out_len` is the full length, so a short buffer is detected and the call
   repeated (`out_cap` 0 asks for the length). Nothing the library returns points into memory
   that a later call could reuse, except a `SegDiagnostic`'s strings, which belong to their
   `SegLog`.
6. **Objects cross as opaque handles.** `SegFile*` (a mapped file with its index and keys),
   `SegTensor*`, `SegPrefetch*`, `SegEditor*`, `SegLog*` and `SegGeometry*`.
   - Each handle is a Nim `ref` kept alive with `GC_ref` and released by its
     `seg_<object>_release`. Releasing NULL is a no-op. `seg_prefetch_close` and
     `seg_editor_close` end the work (join the worker, flush the journal); the handle is
     still released with its release function.
   - Using a handle after releasing it is undefined, as with `free`.
7. **Tensors stay tensors.** Two zero-copy ways out, plus one way in:
   - `seg_tensor_view(t, &view)` fills `SegTensorView`: data pointer, dtype
     (`SEG_DTYPE_FLOAT32` or `SEG_DTYPE_FLOAT64`), rank, shape and strides in elements. The
     view is valid until `seg_tensor_release(t)`.
   - `seg_tensor_to_dlpack(t, &m)` gives a `DLManagedTensor*` (DLPack v0.8 layout, declared
     in the header) that owns a reference. The consumer calls its `deleter`. This is how
     PyTorch, JAX, CuPy and numpy (`from_dlpack`) take the data without a copy.
   - For no allocation at all, `seg_file_read_into` / `seg_file_read_traces_into` decode into
     a buffer the caller owns (`SegSampleBuffer`: pointer, dtype, rows, cols, row stride).
8. **Errors never cross as exceptions.**
   - Every export runs inside `try`/`except Exception` and is `raises: []`, so no Nim
     exception or Defect unwinds into C.
   - Nim's allocator terminates the process when the system refuses memory. An
     out-of-memory hook cannot raise through the C backend's goto-based exceptions, so large
     buffers (64 MiB and up) are first probed with `malloc`/`free`, and a refusal is
     `SEG_ERR_MEMORY`. Sizes from C are bounded first: tensors and prefetch rings are at most
     1 TiB, and selections at most 2^34 entries. Every selection is checked before anything
     is allocated.
   - Statuses: `SEG_OK` = 0, `SEG_END`, `SEG_NOT_READY` (positive: not errors),
     `SEG_ERR_ARGUMENT`, `SEG_ERR_IO`, `SEG_ERR_FORMAT`, `SEG_ERR_STATE`, `SEG_ERR_REFUSED`,
     `SEG_ERR_INTERNAL`, `SEG_ERR_MEMORY`. The Nim procs raise; the wrappers map
     (`ValueError` → argument, `SegFormatError` → format, `IOError`/`OSError` → I/O,
     `AbiStateError`, `AbiRefusedError`, `AbiMemoryError`, `AbiEnd`, `AbiNotReady`). A
     `LoggedError` carries its own status and its log, which still reaches a `SegLog **`
     result before the failure is returned.
   - Enum values from C are checked against the Nim enum (parameters and struct fields).
   - `seg_last_error()` returns the message of the calling thread's last failed call. It is
     kept in a fixed 1 KiB thread-local buffer, valid until that thread's next call. A Nim
     `string` threadvar would leak, because host threads never run Nim threadvar
     destructors.
   - `seg_init` is a lock-free once guard (compare-and-swap; the others spin). It must not
     touch a Nim lock, because module initialization runs inside `NimMain`.
9. **Diagnostics are data, not errors.** Opening a damaged file succeeds. Problems go into
   the handle's log, which is the library's "never silent, never interrupting" contract.
   - `seg_file_diagnostics` and `seg_editor_diagnostics` return an owned copy (`SegLog **`);
     the conversions, journal calls and survey loads return their own.
   - Read entries with `seg_log_count` / `seg_log_get` (into a `SegDiagnostic`; `code` is a
     `SEG_CODE_*` constant) or `seg_log_nif` (the whole log as NIF text).
10. **Threads.**
    - Any thread may call in.
    - Calls on one handle are serialized by a lock in the handle (the generated wrappers take
      it), except the reads (`seg_file_read*`, `{.segApi(concurrent).}`), which only read the
      map and run in parallel.
    - `SegPrefetch` runs its own worker thread; `seg_prefetch_next` waits holding the
      prefetcher's lock.
    - A `SegPrefetch` holds a reference to its `SegFile`. Releasing the file first is safe:
      the map stays open until the prefetcher is released too.
11. **Inputs.** Paths and field names are NUL-terminated UTF-8. Counts and indices are
    `int64_t`. Index lists (trace selections) are `const int64_t*` plus a count.
12. **Versioning.** `SEG_ABI_VERSION` (an integer in the header) and `seg_init()` /
    `seg_abi_version()` must match. Bump `AbiVersion` in `api.nim` on any incompatible
    change. Version 2 (task 12.2) is the generated, uniform convention; version 1 was the
    hand-written header. `seg_version()` returns the package version string.
13. **Adding a function.** Write the Nim proc in `api.nim` (it raises on failure, takes and
    returns Nim types from the table in 5), add `{.segApi.}`, run `nim lib`, commit the
    regenerated `include/parseseg.h` and `python/parseseg/__init__.py`, and add C and Python
    tests. A new handle type needs `segHandle(T, "SegX", "PyName")`; a new struct may be
    named with `segStruct` and its enums prefixed with `segEnum`.

## Out of scope for now

Writing SEG-Y/SEG-D files from C (other than in-place edits and `seg_convert`), vendor-map
registration from C, and tape devices from C. The Nim API covers all of these.
