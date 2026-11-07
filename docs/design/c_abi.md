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
   `-d:useMalloc -d:release -d:segCapi src/parseSEG/capi.nim`.
   - `useMalloc` lets any host thread call in with no per-thread setup, and lets ASan and
     valgrind see every allocation.
   - `atomicArc` makes reference counts atomic, so a handle (for example a tensor shared
     with a DLPack consumer) may be released from any thread. The library builds no
     reference cycles, so it needs no cycle collector.
   - Both test suites (prefetch, edit) pass under these flags.

2. **Initialization.** The host calls `seg_init()` once before anything else. It runs `NimMain`,
   is idempotent and thread-safe, and returns `SEG_ABI_VERSION`. No teardown call is needed.

3. **Naming.** Functions use `seg_<object>_<verb>` and types use `Seg<Name>`. The C prefix is
   `seg`, not `parseSEG`, so the Phase 9 rename (to parseSEG) does not touch the C API.
   Constants use `SEG_`.

4. **The header is curated, not generated.** `include/parseseg.h` is hand-written,
   self-contained (C99 `<stdint.h>`, `<stddef.h>`, no `nimbase.h`) and fully commented, and it
   compiles as C and C++. It is kept honest by tests:
   - a C program checks `sizeof`/`offsetof` of every struct against values that Nim reports
     for its own types (`seg_sizeof`, `seg_offsetof`);
   - a script checks that every `seg_*` symbol in the shared library is declared in the
     header, and the other way round;
   - a C test program and a Python `ctypes` smoke test exercise every function.
   Nim's `--header` output is used only to cross-check the signatures.

5. **Objects cross as opaque handles.** `SegFile*` (a mapped file with its index and
   keys), `SegTensor*`, `SegPrefetch*`, `SegEditor*`, `SegLog*` and `SegGeometry*`.
   - Each handle is a Nim `ref` kept alive with `GC_ref` and released by its
     `seg_<object>_release` (or `close`). Releasing NULL is a no-op.
   - Using a handle after releasing it is undefined, as with `free`.

6. **Plain data crosses as `bycopy` structs with `exportc` names:**
   - `SegTraceEntry` is `TraceEntry` itself (24 bytes).
   - `SegTraceKeys` is `TraceKeys` itself.
   - `SegGather`, `SegChunk`, `SegDiagnostic` and `SegTensorView` are structs made for the
     boundary.

   The caller allocates these, and the library fills them through `out` pointers.

7. **Tensors stay tensors.** Two zero-copy ways out, plus one way in:
   - `seg_tensor_view(t, &view)` fills `SegTensorView`: data pointer, dtype (`SEG_F32` or
     `SEG_F64`), rank, shape and strides in elements. The view is valid until
     `seg_tensor_release(t)`. A numpy user wraps it with `np.ctypeslib.as_array`.
   - `seg_tensor_to_dlpack(t)` returns a `DLManagedTensor*` (DLPack v0.8 layout, declared in
     the header) that owns a reference. The consumer calls its `deleter`. This is how
     PyTorch, JAX, CuPy and numpy (`from_dlpack`) take the data without a copy.
   - For no allocation at all, `seg_read_*_into` decodes into a buffer the caller owns (for
     example a numpy array's data pointer), given its row stride.

8. **Errors never cross as exceptions.**
   - Every export that can fail runs inside `try`/`except Exception`, so no Nim exception or
     Defect unwinds into C. The trivial accessors are marked `{.raises: [].}` instead, so the
     compiler enforces that they cannot raise.
   - Nim's allocator terminates the process when the system refuses memory. An
     out-of-memory hook cannot raise through the C backend's goto-based exceptions: the
     hook is declared not to raise, so no caller checks the error, and the allocator quits.
     So large buffers (64 MiB and up) are first probed with `malloc`/`free`, and a refusal
     is `SEG_ERR_IO`. The system can still run out later; overcommit cannot be predicted.
     Sizes from C are bounded first:
     tensors and prefetch rings are at most 1 TiB, and selections at most 2^34 entries. Every
     selection is checked before anything is allocated.
   - Functions return a `SegStatus` (`int32_t`): `SEG_OK` = 0, `SEG_END`, `SEG_NOT_READY`,
     `SEG_ERR_ARGUMENT`, `SEG_ERR_IO`, `SEG_ERR_FORMAT`, `SEG_ERR_STATE`,
     `SEG_ERR_REFUSED`, `SEG_ERR_INTERNAL`.
   - Arguments are checked explicitly before any Nim call that would assert.
   - `seg_last_error()` returns the message of the calling thread's last failed call. It is
     kept in a fixed 1 KiB thread-local buffer, valid until that thread's next call. A Nim
     `string` threadvar would leak, because host threads never run Nim threadvar
     destructors.
   - `seg_init` is a lock-free once guard (compare-and-swap; the others spin). It must not
     touch a Nim lock, because module initialization runs inside `NimMain`. A review found
     that re-initializing a lock which waiters were already blocked on deadlocked every
     concurrent `seg_init`.

9. **Diagnostics are data, not errors.** Opening a damaged file succeeds. Problems go into
   the handle's log, which is the library's "never silent, never interrupting" contract.
   - `seg_file_log(f)` and `seg_editor_log(e)` borrow a `SegLog*`. `seg_journal_rollback`
     and `seg_journal_apply` return an owned one.
   - Read entries with `seg_log_count` / `seg_log_get` (into a `SegDiagnostic`) or
     `seg_log_nif` (the whole log as NIF text).
   - Strings returned by the library are UTF-8 and owned by the handle that returned them.
     They stay valid until the handle is released or the same accessor is called again.

10. **Threads.**
    - Any thread may call in.
    - One handle must not be used by two threads at the same time. The exception is
      `SegFile` range reads (`seg_read_*`), which only read the map and may run in parallel.
      Their per-call logs are separate.
    - `SegPrefetch` runs its own worker thread. Its consumer calls must come from one
      thread at a time.
    - A `SegPrefetch` holds a reference to its `SegFile`. Releasing the file first is safe:
      the map stays open until the prefetcher is released too.

11. **Inputs.** Paths and field names are NUL-terminated UTF-8. Counts and indices are
    `int64_t`. Index lists (trace selections) are `const int64_t*` plus a count.

12. **Versioning.** `SEG_ABI_VERSION` (an integer in the header) and `seg_abi_version()` must
    match. Bump the ABI version on any incompatible change. `seg_version()` returns the
    package version string.

13. **One source with the Python module.** The exports are thin wrappers over
    `src/parseSEG/abi/core.nim`, marked with `{.segExport: "seg_name".}`, which becomes
    `exportc, dynlib, cdecl` under `-d:segCapi`. The Python module wraps the same procs (see
    `python.md`). Put new behavior in the core, then add a wrapper for each target.

## Out of scope for now

Writing SEG-Y/SEG-D files from C (other than in-place edits and `seg_convert`), vendor-map
registration from C, and tape devices from C. The Nim API covers all of these.
