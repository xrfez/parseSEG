# Phase 14.2 audit: what the FFI shaped

Audit of `src/parseSEG` (branch `seg-library`, after d4d0687) for API shapes the removed C ABI /
Python module bent. Read-only; nothing here is applied yet. Caller counts are `grep -w` hits
outside the definition (src / tests / docs). Tags: **[do]** recommended, **[optional]** nice
but low value, **[drop-candidate]** remove unless the owner wants it, **[keep]** looked FFI-shaped
but is right for Nim.

Summary of what 14.1 already removed (verified, no action): per-handle locks (`AbiHandle.lock`),
`concurrent` markers, `segGuard`, `SegValue`/`SegValueRef` borrowing, NUL-separated
`seq[string]` and the `write*` out-buffer helpers all lived in `abi/runtime.nim` /
`abi/segapi.nim` and are gone (`grep -rnw "concurrent\|segGuard\|SegValueRef\|requireBuffer" src`
is empty; the remaining `Lock` is the prefetcher's own ring lock). `FieldValue`
(`model/headerfields.nim:48`) is a plain variant object and `HeaderRow.value` is a `FieldValue`,
so nothing borrows any more. What is left is listed below.

## A. Lifetime and threading

### 1. R2-5: the prefetcher outlives the map it reads  [do]
- **Where:** `model/prefetch.nim:19-28` (contract), `:64-68` (raw `mem`, `entries`, `codecs`,
  `sel`), `:193-197` (taken from `f`); `model/traceindex.nim:374-389` (`MapOwner`), `:471-481`
  (`close`, whose comment says the boundary's handle refcount made this safe).
- **Today:** `newPrefetcher[T](f: SeismicFile, ...)` copies `f.unsafeMemory`, `addr
  f.index.entries[0]` and `addr f.index.codecs[0]` into the worker's shared state.
  `f.close()` unmaps at once (`MemFileSource.close`), so the worker (or `take`, which reads
  `sh.entries`/`sh.codecs` for the diagnostics) touches unmapped pages: SIGSEGV. A
  `SeismicFile` destroyed before its prefetcher frees `entries`/`codecs` as well.
- **Why FFI-shaped:** the C/Python handle kept a counted reference to the file, so the map
  outlived every prefetcher. The Nim object has no such owner; only a doc rule protects it.
- **Proposal (pinned map owner):**
  ```nim
  type
    MapOwner = object              # unchanged fields, plus:
      pins: int                    # live prefetchers (consumer thread only)
      parked: (seq[TraceEntry], seq[TraceCodec]) # index kept alive for them
    MapRef = ref MapOwner          # =destroy of MapOwner unmaps and deletes tempPath, as today
  SeismicFile.map: MapRef
  Prefetcher[T].keep: MapRef       # newPrefetcher: keep = f.map; inc keep.pins
  ```
  - `close(f)`: `f.map = nil`. The unmap (and the demux copy's deletion) runs when the last
    reference goes, i.e. at once without a prefetcher, else at the prefetcher's `close` or
    `=destroy` (after `shutdown` joins the worker). `f.isOpen` is false immediately, so
    `readTraces` etc. still refuse a closed file.
  - `=destroy(SeismicFile)`: when `map != nil and map.pins > 0`, move `index.entries` and
    `index.codecs` into `map.parked` first. A seq move keeps its payload address, so the
    worker's raw pointers stay valid; no copy.
  - Implementation note: Nim 2's `=destroy(x: SeismicFile)` takes `x` by value, so the move
    needs `(addr x)[]` (the object is passed by reference); a `MapRef`-held `parked` slot keeps
    that cast in one place. If the owner finds it too clever, ship the deferred unmap alone and
    keep a documented rule for the rarer case: a file must not be destroyed before its
    prefetchers (locals already die in reverse order, so `var f ...; var p ...` is safe).
  - Keep the documented rule only for what cannot be checked cheaply: do not resize or
    replace `f.index.entries`/`codecs` while a prefetcher runs (the tests that poke
    `numSamples` do so before `newPrefetcher`).
  - `HeaderEditor.close` keeps its explicit `flush` before `close`, so a deferred unmap never
    loses edits.
- **Alternatives:** (a) `close` raises `ValueError` while `pins > 0`: about 10 lines, but a
  destroyed file still frees `entries`, and `=destroy` cannot raise, so it fixes half. (b) The
  prefetcher copies `entries`: 24 B per trace (240 MB at 10 M traces) for range mode, where
  `seek` may go anywhere. Rejected.
- **Callers affected:** none in the API. Internal: `traceindex.nim` only (26 `f.map` uses, all
  in that file, gain a `f.map != nil` guard), `prefetch.nim` (about 5 lines). New tests: open,
  prefetch, `f.close()`, drain, close (no crash; unmapped after the prefetcher closes), and a
  file destroyed in an inner scope while its prefetcher lives.
- **Perf:** the decode path is unchanged (the worker still reads raw pointers;
  `decodeEntry` is untouched). One allocation per `openSeismic`, and one more pointer hop per
  `unsafeMemory`/`isOpen` call, which happen per read call, not per trace. On Windows the
  deferred unmap also makes the demux copy's deletion succeed (a mapped file cannot be deleted).

### 2. `Prefetcher.waitReady` and the `waiters` counter  [do]
- **Where:** `model/prefetch.nim:309-325` (`waitReady*(p, outer: var Lock)`, marked "Internal
  (the C ABI)"), `:62` (`waiters`), `:98` (`shutdown` waits for them), `:323`, `:348`
  (`broadcast` for an old-range waiter).
- **Today:** a wait that releases a *caller's* lock: the ABI's per-handle lock. No Nim caller
  (3 hits, all in `prefetch.nim`; 0 tests, 0 docs).
- **Proposal:** delete `waitReady`, the `waiters` field and the loop at `:98`; `seek` keeps
  `signal(sh.work)` and drops `broadcast(sh.ready)` (only `next` waits on `ready`, and it is
  on the same thread as `seek`). `next` already is the blocking form.
- **Risk/perf:** none; removes a lock round trip from `shutdown`.

### 3. `readTracesRaw` (strided raw-pointer decode)  [drop-candidate]
- **Where:** `model/traceindex.nim:659-671`; excluded from the umbrella (`parseSEG.nim:36`).
- **Today:** `readTracesRaw[T](f, traces: openArray[int], dst: ptr UncheckedArray[T], cols,
  rowStride: int, log: var DiagLog): int`, "for hosts that decode straight into their own arrays
  (the C ABI, numpy)".
- **Why:** a raw out-buffer shape with an unchecked size, only for the boundary. Nim callers
  have `readTracesInto(f, traces, var Tensor[T], row, log)`, which checks the tensor.
- **Proposal:** delete it and the part of `tests/tprefetch.nim:149-155` that tests it, and its
  name in `parseSEG.nim:36` and `tests/tumbrella.nim`. If a strided/windowed target is wanted,
  it belongs to 14.3's sample windows, on a `Tensor` (a `[rows, cols]` view with a stride).
- **Callers:** src 0, tests 1, docs 0. **Perf:** none (`decodeLoop` stays).

## B. Handle-shaped types

### 4. `HeaderListing` wraps a `seq[HeaderRow]`  [do]
- **Where:** `model/headerlist.nim:71-91` (type, `len`, `[]`, `items`, `pairs`); producers
  `traceHeaders` `:195`, `recordHeaders` `:227`, `fileHeaders` `:281`.
- **Today:** `HeaderListing = object rows: seq[HeaderRow]` (private), re-exposing `len`/`[]`/
  `items`/`pairs`. It was a `{.segHandle.}`: the C side got an opaque handle with indexed access.
- **Why:** no invariant to protect; callers cannot sort, filter, slice or `add` rows, and the
  wrapper adds four procs.
- **Proposal:** `proc traceHeaders*(f: SeismicFile, trace: int): seq[HeaderRow]` (same for
  `recordHeaders`, `fileHeaders`); delete `HeaderListing` and its four accessors.
- **Callers:** src 1 (`cli.nim`, uses `for r in ...`, unchanged), tests 3 type mentions in
  `theaderlist.nim` (call sites unchanged: `len`, `[]`, `for` all work on a seq), docs 1
  (`api.md:65`). **Perf:** identical (the builder already ends with `move L.rows`).

### 5. `HeaderPatch` duplicates `writeHeaderPatch(openArray[HeaderChange])`  [do]
- **Where:** `model/headernif.nim:572-603` (type with exported `changes*`, `initHeaderPatch`,
  `add`, `len`), `:639-643` (`write`).
- **Today:** two ways to save a viewer's edits: the handle (`initHeaderPatch`, `add(scope, index,
  name, value)`, `write(path)`) and `writeHeaderPatch(changes, path)`. The handle's `changes*`
  is public anyway, and tests already mix them (`writeHeaderPatch(q.changes, ...)`).
- **Why:** a builder handle for C, which could not build a `seq` of structs. The generic name
  `write(p, path)` also collides in spirit with `std/streams`-style `write`.
- **Proposal:** keep `writeHeaderPatch(changes: openArray[HeaderChange], path)` as the one way.
  Replace `add`'s eager check with a constructor:
  ```nim
  proc initHeaderChange*(scope: HeaderScope, index: int, name: string,
      value: FieldValue): HeaderChange          # raises ValueError like `add` today
  var edits: seq[HeaderChange]
  edits.add initHeaderChange(hsTrace, 3, "trace.sourceX", toFieldValue(1200))
  writeHeaderPatch(edits, "viewer-edits.nif")
  ```
  Delete `HeaderPatch`, `initHeaderPatch`, `add`, `len`, `write`.
- **Callers:** src 0 (besides the module), tests 6 (`theaderlist.nim:189-237`), docs 3
  (`api.md:115-116`, `guide/editing.md:146-158`, `guide/viewer.md:237-246`; `tdocs.nim` compiles the
  guide snippets, so they must change in the same commit). **Perf:** none.

### 6. `DiagLog`  [keep]
- **Where:** `common/diagnostics.nim:50-121`. A `{.segHandle.}` before 14.1, but the private
  `entries` + `counts: array[Severity, int]` is a real invariant (O(1) `count`, `hasErrors`,
  `isFatal`), and it already has `len`, `[]` (`lent`), `items`, `pairs`, `add`. Idiomatic as is.

### 7. `SeismicFile`, `HeaderEditor`, `SurveyGeometry`  [keep] (shape), see 12 for fields
- Plain objects with `=copy` disabled where they own a map or journal: correct for Nim
  (`traceindex.nim:402`, `edit.nim:96`). `SurveyGeometry` is copyable plain data. No change of
  representation is needed.

## C. Generated-API leftovers

### 8. `seg2StringCount` / `seg2Keyword` / `seg2Value` index accessors  [do]
- **Where:** `model/headerfields.nim:523-546`.
- **Today:** `seg2StringCount(f, trace): int`, `seg2Keyword(f, trace, n): string`,
  `seg2Value(f, trace, n): string`: C could not take a `seq[Seg2String]`. Each call re-reads the
  Trace Descriptor Block (`seg2Strings` → `seg2Trace` → `readSeg2Trace`), so a loop over the
  strings is O(n²) parses.
- **Proposal:** delete the three; `seg2Strings(f, trace): seq[Seg2String]` already gives
  `key`/`value` per entry, and `Seg2String` has the case-insensitive `value(key)` lookups.
  Optional on top: replace the `trace = -1` sentinel with `seg2FileStrings(f)` (or let callers
  use `f.index.seg2.strings`), so `trace` is always a trace.
- **Callers:** src 0, tests 7 (`tseg2.nim`), docs 1 (`api.md:162`). **Perf:** a gain for callers.

### 9. `writeGeometry(ed, f: SeismicFile)` overload  [drop-candidate]
- **Where:** `survey/writeback.nim:766-770`; the real one is `writeGeometry(ed, ix: TraceIndex,
  fields)` at `:713`.
- **Today:** a one-line forward to `ed.writeGeometry(f.index, fields)`, added because the
  boundary had a `SeismicFile` handle but no `TraceIndex` one.
- **Proposal:** delete; Nim callers write `ed.writeGeometry(f.index)`. (A better fix is 14.3's
  `openEditor(f: sink SeismicFile)`: open once with keys, join, then edit the same map, so the
  separate index argument disappears; out of scope here.)
- **Callers:** src 0 (`cli.nim:937` already passes `f.index`), tests 6 (`tgeomwrite.nim`),
  bench 1 (`suite.nim:508`), docs 2 (`api.md:90`, `guide/conversion.md:156`). **Perf:** none.

### 10. `geometryChanges` without a log, and `previewGeometry`  [do]
- **Where:** `survey/writeback.nim:689` (`geometryChanges(f, fields, log: var DiagLog)`),
  `:701` (`geometryChanges(f, fields = GeometryFields())`, log discarded), `:709`
  (`previewGeometry(f, fields): DiagLog`).
- **Today:** three entry points for one dry run, because C could not take a `var DiagLog` and
  could not return two things.
- **Proposal:** keep the pair that matches `readTraces`: `geometryChanges(f, fields, log)` and
  the no-log form. Delete `previewGeometry`; export the summary it adds as
  `func `$`*(c: GeometryChanges): string` (today the private `describe` at `:165`), so
  `echo f.geometryChanges(fields, log)` gives the same text.
- **Callers:** previewGeometry: tests 2 (`tgeomwrite.nim:94`), docs 2 (`api.md:89`,
  `guide/conversion.md:154`). **Perf:** none.

### 11. `copyWithGeometry(..., changes: var GeometryChanges, ...)`  [optional]
- **Where:** `survey/writeback.nim:805` (with the out-parameter) and `:827` (without).
- **Today:** two overloads; the boundary took the second, the CLI the first.
- **Proposal:** one proc returning a named result, as `importHeaders` does with `ImportResult`:
  `proc copyWithGeometry*(src, dst: string, g: SurveyGeometry, fields = GeometryFields(),
  overwrite = false): GeometryCopy` with `changes*: GeometryChanges` and `log*: DiagLog`. This
  breaks the "file-to-file operations return a `DiagLog`" pattern of `convertFile`, which is why
  it is only optional; the minimal fix is to keep both overloads.
- **Callers:** src 1 (`cli.nim`), tests 6, docs 3. **Perf:** none.

### 12. Fields that were read-only at the boundary are now writable  [do]
- **Where:** `traceindex.nim:395-396` (`SeismicFile.path*`, `demuxPath*`), `edit.nim:73-76`
  (`HeaderEditor.file*`, `log*`, `journalPath*`), `join.nim:49` (`SurveyGeometry.log*`).
- **Today:** 14.1 removed `{.segField(readonly = true).}` and left plain exported fields, so
  `ed.file = ...`, `ed.file.close()`, `f.path = "x"` or `ed.log = DiagLog()` compile; replacing
  `ed.file` bypasses the journal (owner rule: files change only on an explicit write).
- **Proposal:** private fields with inline accessors (the pattern `HeaderEditor.edits` already
  uses, `edit.nim:484`):
  ```nim
  func path*(f: SeismicFile): lent string {.inline.}
  func demuxPath*(f: SeismicFile): lent string {.inline.}
  func file*(ed: HeaderEditor): lent SeismicFile {.inline.}
  func log*(ed: HeaderEditor): lent DiagLog {.inline.}     # also SurveyGeometry.log
  func journalPath*(ed: HeaderEditor): lent string {.inline.}
  ```
  `SeismicFile.index*` stays public (tests and `applySurvey(ix)` mutate it on purpose; making it
  private is a much larger change), as do `SurveyGeometry.table`, `lineNames`,
  `multiComponent`, `tape`, `trailingDigits` (real settings).
- **Callers:** reads only (24 `ed.file...` uses outside `edit.nim`/`writeback.nim`, all reads;
  `tedit.nim:59`, `cli.nim:609,942` read `journalPath`); no writes found outside the defining
  modules. `writeback.nim:741,763` writes `ed.log`, so `edit.nim` exports a
  `proc logVar*(ed: var HeaderEditor): var DiagLog` kept out of the umbrella (as `writeBytes`
  is, `parseSEG.nim:41`), or `writeGeometry` moves the reports through `report` on the editor. **Perf:** none (inline `lent`).

## D. Parameters hidden at the boundary

### 13. `convertFile`'s `join` and the public `GeometryJoin` with a raw pointer  [do]
- **Where:** `convert.nim:150-156` (`GeometryJoin*` with `survey*: ptr SurveyGeometry`, doc says
  "Internal"), `:1073` (`convertFile*(src, dst, opts = ConvertOptions(), join =
  GeometryJoin()): DiagLog`), `:720`; the one user is `survey/writeback.nim:860`.
- **Why:** the parameter was hidden from C (`hide = join`); in Nim it is a public parameter
  whose type carries a `ptr` and is documented as internal.
- **Proposal:** `convertFile*(srcPath, dstPath: string, opts = ConvertOptions()): DiagLog`
  forwards to `convertJoined*(srcPath, dstPath, opts, join: GeometryJoin)`. `writeback.nim`
  needs both from another module, so they stay exported from `convert.nim` but leave the
  umbrella (`export convert except convertJoined, GeometryJoin`, as `traceindex` does for
  `unsafeMemory`). The `ptr SurveyGeometry` then never reaches a library user.
- **Callers:** src 1, tests 0, docs 0 (`api.md` never listed `join`). **Perf:** none.

### 14. `openSeismic(writable = false)`  [do]
- **Where:** `traceindex.nim:440-469`.
- **Today:** a public flag that maps the file read-write; hidden from C. Its one real user is
  `openEditor` (`edit.nim:463`); a public caller gets a writable map but no public way to write
  through it (`unsafeMemory` is not exported), so the flag only invites mistakes.
- **Proposal:** `openSeismic*(path: string, twosComplement8015 = false, keys = false,
  demuxDir = ""): SeismicFile` plus an internal `openSeismicRw*(path, keys = false)` (excluded
  from the umbrella like `flush`) used by `openEditor`. The multiplexed-SEG-D refusal moves with
  it. **Callers:** src 1, tests 1 (`tsegdmux.nim:460`, test via `openEditor` instead), docs 1.

### 15. `openSeismic(demuxDir = "")`  [keep]
- A real Nim option (where the temporary demultiplexed copy goes; tests use it,
  `tsegdmux.nim:424,451`). Hidden from C only because C had no defaults. Keep as is. If
  `openSeismic` grows more options (14.3 sidecar cache, progress), fold `twosComplement8015`,
  `keys`, `demuxDir` into an `OpenOptions` object then, not now.

### 16. `addP1(g, path, gridDecimals, depthDecimals, elevation)` flattens `P1Options`  [do]
- **Where:** `survey/join.nim:212-222`; its sibling is `addSps(g, path, opts = SpsOptions())`
  (`:205`).
- **Why:** flattened because the boundary passed scalars more easily than a struct; it also
  re-checks `0..8` that `readP1` could own, and cannot pass `angleUnit`/`layout`.
- **Proposal:** `proc addP1*(g: var SurveyGeometry, path: string, opts = P1Options(),
  elevation = false)`. **Callers:** src 0 (`cli.nim:259` uses the `P1File` overload), tests 1
  (`tcoreapi.nim:80`), docs 1. **Perf:** none.

## E. Kept on purpose

### 17. `ValueError` for bad indices and ranges, distinct `trace/record/fileField` names  [keep]
- Both came from 12.5 for the boundary (no crash under `-d:danger`; C cannot overload on
  `int` meaning). In Nim an out-of-range index would normally be an `IndexDefect`, but the
  `ValueError` contract is documented (`api.md:16-18`), tested, and cheap: one range check per
  call, and `checkSelection` is one pass over the list per `readTracesInto`, against a decode of
  every sample. `traceField`/`recordField`/`fileField` and `setTraceField`/... cannot be one
  overload anyway (the index is an `int` either way). Keep both.

### 18. `relationCount`, `sourceCount`, `receiverCount`, `componentGroupIds`  [keep]
- Added in 12.5 so the boundary had something to call, but each is a fair Nim query:
  `relationCount` is the only view of the private `runs` (`join.nim:66`); the two counts are
  one-liners over the public `table`; `componentGroupIds(f, traces): seq[int]`
  (`gathers.nim:231`) is the cheap labelling for 10 M traces (one table, no per-group seqs) that
  a viewer colours by. Its `-1` "no group" is fine for a label array. Keep.

## F. Doc and comment cleanup

### 19. "C ABI" / "C/Python" mentions in `##` comments and test headers  [do]
| Where | Text | Change |
|---|---|---|
| `model/prefetch.nim:310` | "**Internal** (the C ABI)" | goes with item 2 |
| `model/traceindex.nim:473-475` | "(Not on the C/Python boundary: ... releasing the handle unmaps it once the last user is gone.)" | replace with the item 1 rule ("a running prefetcher keeps the map until it closes") |
| `model/traceindex.nim:663-664` | "(the C ABI, numpy)" | goes with item 3 |
| `model/headerfields.nim:4` | "... the in-place editor (`model/edit`) and the C ABI." | end at "editor" |
| `tests/tcoreapi.nim:1` | "(the C and Python names derive from them)" | drop the parenthesis |
| `tests/tphase8review.nim:1-2` | "the C ABI findings are in tests/c/abi_test.c ..." | drop (file deleted) |
| `tests/treview13.nim:2-3` | "The C-boundary findings are in tests/c/..." | drop (files deleted) |
| `tests/tprefetch.nim:149` | "(the C ABI path)" | goes with item 3 |
| `docs/guide/getting-started.md:140` | "A `Prefetcher` reads the map through raw pointers, so in Nim the file must stay open" | rewrite after item 1 |

Not FFI (leave): `ebcdic.nim:38` ("Python's `cp037` codec" is the table's source),
`ttracetime.nim:4` (Python `calendar.timegm` as an independent check), "record/trace boundary"
in `diagnostics.nim`/`errors.nim`, "host order" in the codecs, `docs/benchmarks.md:11`
(historical note; 14.4 rewrites it).

## G. Other idiom findings (lower priority)

### 20. `unsafeMemory` + `mappedSize` as a raw pair  [optional]
- **Where:** `traceindex.nim:537`, `:562`; about 18 internal call sites write
  `f.unsafeMemory.toOpenArray(a, b)` or check `offset + n <= f.mappedSize` by hand
  (`headerfields`, `headernif`, `edit`, `headerlist`, `convert`, `seg2convert`, `writeback`).
- **Proposal:** an internal `template mapped*(f: SeismicFile): openArray[byte]`
  (`f.map.src.memory.toOpenArray(0, int(f.map.src.size) - 1)`) for the read sites, so bounds are
  checked in debug builds; keep the raw pointer only where a worker thread needs it
  (`decodeEntry`, the prefetcher). **Perf:** no change in release (`toOpenArray` is a view);
  do not route `decodeLoop` through it (already raw, already bounds-checked once per trace).

### 21. Prefetcher surface  [optional]
- **Where:** `prefetch.nim:168-229`, `:287-307`.
- `next(p, var c): bool` / `tryNext(p, var c): bool` are right (the `var` chunk lets 14.3's
  `nextInto`/recycling reuse buffers). Add the idiomatic loop form on top:
  `iterator chunks*[T](p: var Prefetcher[T]): PrefetchChunk[T]` (`while p.next(c): yield c`).
- `chunkTraces`, `depth` are `int` with a manual `<= 0` check raising `ValueError`; `Positive`
  would state the contract, but turns the error into a `RangeDefect`, which breaks the item 17
  convention. Keep `int` unless the owner drops that convention.
- `cols = -1` ("the range's longest trace") is a sentinel; `cols = 0.Natural` cannot mean
  "auto" since 0 columns is valid. Keep.

### 22. Umbrella exports that leak internals  [optional]
- `readFields*` (`headerfields.nim:444`, a `var seq` out-parameter plus an error `string`
  result, used only by `headernif.nim:124`) and `chooseScalar*` (`writeback.nim:295`, `exact:
  var bool`; tests only) reach `import parseSEG`. Add `readFields` to the `except` list at
  `parseSEG.nim:38`, and `chooseScalar` to an `export writeback except chooseScalar`; then
  `tgeomwrite.nim` (which imports only `parseSEG`) adds `import parseSEG/survey/writeback`. No
  signature change needed.

### 23. `FileSummary` sentinels (-1 / NaN)  [optional]
- **Where:** `model/summary.nim:55-89`. `formatCode`, `samplesPerTrace`, `first/lastFieldRecord`
  use -1 and the floats NaN for "not uniform / none": a C-struct habit. `Option[int]` would be
  the Nim way for the integers, but NaN for floats is normal Nim and the struct is read once per
  file. Low value; do it only if a viewer trips over it.

## Implementation plan (commit-sized, `nim test` green after each)

1. **14.2a Prefetcher lifetime (items 1, 2):** `MapOwner` behind a ref with `pins` and
   `parked`; `close` detaches; `SeismicFile` `=destroy` parks the index when pinned; delete
   `waitReady`/`waiters`. Tests: close-before-drain and file-destroyed-first (run under
   `-d:useMalloc` + ASan or valgrind once). Update `traceindex.nim:473` and
   `getting-started.md:140`. Bench `prefetch` row before and after (expect no change).
2. **14.2b Boundary-only procs (items 3, 8, 9, 10):** delete `readTracesRaw`, the three
   `seg2*` index accessors, the `writeGeometry(ed, f)` overload and `previewGeometry`; export
   `$`(GeometryChanges). Fix tests, `api.md`, `guide/conversion.md`, `bench/suite.nim:508`.
3. **14.2c Handles to seqs (items 4, 5):** `traceHeaders`/`recordHeaders`/`fileHeaders` return
   `seq[HeaderRow]`; `HeaderPatch` gives way to `initHeaderChange` + `writeHeaderPatch`. Update
   `theaderlist.nim`, `api.md`, `guide/editing.md`, `guide/viewer.md` (doc snippets are compiled by
   `tdocs.nim`).
4. **14.2d Encapsulation and hidden parameters (items 12, 13, 14, 16):** private fields with
   `lent` accessors; `convertFile` without `join`; `openSeismic` without `writable`
   (`openSeismicRw` internal); `addP1(path, opts: P1Options)`.
5. **14.2e Comments and umbrella hygiene (items 19, 22; optionally 20, 21):** the comment table,
   `except` lists, and the `chunks` iterator if wanted.
6. Owner's call, later or never: items 11, 23 (result object, `Option` summary fields).

Each step is a breaking change only in names the 0.5.0 bump already covers; none touches
`decodeEntry`, `decodeLoop` or the index walk, so the decode, `readTracesInto` and index-build
benchmarks should not move. Re-measure in 14.4.
