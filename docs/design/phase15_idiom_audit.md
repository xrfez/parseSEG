# Phase 15.3 audit: idiomatic Nim

Audit of `src/parseSEG` (branch `seg-library`, at 73b61f6) against the `nim-*` skills
(api-design, style-guide, error-handling, ownership-hooks, code-organization, doc-comments,
testing). Read-only; nothing here is applied. Items already settled in
`docs/design/phase14_audit.md` are not repeated. Performance is a separate audit.

Tags: **[do]** recommended, **[optional]** low value or taste, **[keep]** looks off but is right.
Size: S (< 1 h, a few lines), M (one module or a mechanical sweep), L (several modules / API
change). Risk: what can break.

Scratch checks were compiled against Nim 2.4.0 with `--path:src` (files in the session
scratchpad, not committed).

## A. Module organization and the public boundary

### A1. The `export ... except` lists in `src/parseSEG.nim` do not hide what they name  [do] M, low
- **Where:** `src/parseSEG.nim:16-48`; re-exports in `segy/reader.nim:39`
  (`export ... samples ...`), `segd/reader.nim:47` (`export blocks, samples, ...`),
  `seg2/headers.nim:23` and `seg2/writer.nim:41` (`export ... samples`).
- **Evidence:** a scratch file with only `import parseSEG` compiles and runs
  `decodeSamplesRaw(sfIbm32, [0x3f'u8, 0x80, 0, 0], d)` (prints `@[0.03125]`). `when declared`
  is also true for `decodeSegdSamplesRaw` and `decodeSeg2SamplesRaw`. 73b61f6 ("hide Raw
  decoders from the umbrella") therefore did not take effect: `export samples except
  decodeSamplesRaw` is undone by `export reader`, which re-exports `samples` whole. The other
  names tried (`unsafeMemory`, `decodeEntry`, `MapPin`, `ProgressTicker`, `tick`, `readFields`,
  `chooseScalar`, `flushPending`, `GeometryJoin`, `locate`, `rowPtr`, `HeaderEditor.writeBytes`)
  are hidden today, but only because no other exported module happens to re-export their
  module. Any new `export x` in a leaf module silently reopens them. No test checks this.
- **Why:** an `except` list is a per-path filter, not a property of the symbol; with a
  re-export graph as dense as this one (`traceindex` re-exports `memsource, diagnostics, keys,
  seismickind, progress, tensors`; `reader`s re-export their codecs) it cannot be kept right by
  hand. Internals should be unreachable by construction (A2).
- **Quick fix (S, now):** add `except decodeSamplesRaw` etc. to the re-exports in the three
  reader/writer modules, or drop `samples` from their `export` lists (callers that need the
  sample types already get them from the umbrella). Add a `tumbrella.nim` block asserting
  `not declared(decodeSamplesRaw)` etc. for every name in the `except` lists, so a regression
  fails the suite.

### A2. Make internals unreachable by construction: a `private/` layer  [do] L, medium
- **Where:** 45 `**Internal.**` doc comments on exported symbols (`grep -rn '\*\*Internal'
  src`), and the umbrella's denylist of 40 names (`src/parseSEG.nim:16-48`). They fall in two
  groups:
  1. **Pure helpers that touch no private field** (about 25 names):
     `common/progress.nim:26-72` (`ProgressTicker`, `initProgressTicker`, `tick`, `finish`,
     `progressPhase`, `reportCancelled`), `traceindex.nim:829-844` (`requireKeys`,
     `checkSpan`, `spanLen`), `traceindex.nim:359-440` (`DecodeStatus`, `decodeMessages`,
     `tryDecodeEntry`, `decodeEntry`: they take `ptr UncheckedArray[byte]`, not a file), the
     three `decode*SamplesRaw`, `model/tensors.nim:22` (`rowPtr`),
     `headerfields.nim:96-460` (`FieldRef`, `FieldRead`, `locate`, `locateBlock`, `readField`,
     `readFields`, `withBlockType`, `isLayoutField`, `isNamedField`, `fieldValueOf`),
     `convert.nim:151,738,1119` (`GeometryJoin`, `convertSegdToSegyJoined`, `convertJoined`),
     `writeback.nim:295` (`chooseScalar`).
  2. **Helpers that need a type's private fields**: `traceindex.nim` `unsafeMemory`,
     `mappedSize`, `flush`, `MapPin`, `pinMap`, `openSeismicRw`, `remapWritable`;
     `edit.nim` `writeBytes`, `flushPending`, `batching`, `logVar`.
- **Proposal:**
  - Group 1 moves to `src/parseSEG/private/` (the stdlib's `std/private/` convention):
    `private/progressticker.nim`, `private/spans.nim`, `private/decodeentry.nim`,
    `private/rawsamples.nim` (the three `*Raw` decoders; `segy/samples` etc. import it),
    `private/fieldaccess.nim` (the `headerfields` locate/read layer). Public modules import
    them and **never** `export` them; one test (`tumbrella.nim`) greps `src/` for
    `export .*private` and asserts `not declared(...)` for a few names. The `**Internal.**`
    doc notes go (non-exported-by-umbrella is now structural, and `nim doc` of a public module
    no longer lists them).
  - Group 2: two choices, the owner picks.
    (a) **Allowlist** (recommended, M): keep the procs where the fields are, but stop
    re-exporting the *module* from the umbrella with `except`; export the public surface by
    name instead, in one place: `export traceindex.SeismicFile, traceindex.openSeismic, ...`.
    An allowlist cannot leak through a new re-export. Its cost is a list of ~60 names for
    `traceindex`, `headerfields`, `edit`; `docs/api.md` already is that list, so `tdocs.nim`
    can check one against the other.
    (b) **`{.all.}` + `privateAccess`** (std/importutils): the internals become non-exported
    procs, and the four modules that need them (`prefetch`, `edit`, `writeback`, the
    converters) `import ../model/traceindex {.all.}` and `privateAccess(SeismicFile)`.
    Checked in a scratch build on 2.4.0: it works, but needs `privateAccess` for every type
    whose fields are read (here also `MapOwner`, reached through `f.map.src`), and `{.all.}`
    imports every private helper too (name clashes). Intended for tests; not recommended for
    library code.
  - Do not use `include` to share privates: it erases the module boundary the split is
    for, and the included file cannot be compiled or documented alone.
- **Callers:** tests that use internals import the `private/` module directly (they do so
  today for `parseSEG/model/traceindex` etc.).

### A3. Module splits along real responsibilities  [optional] M each, low
Per nim-code-organization ("split at an independent responsibility, dependency set,
lifecycle, or reuse boundary"; not by size alone):
- `model/traceindex.nim` (1369 lines) has three separable parts with their own dependencies:
  the **index cache** (`:1196-1369`, `saveIndex`/`loadIndex`, binstore, checksums; its own
  file format and versioning) → `model/indexcache.nim`; the **range decode** (`:359-440`,
  raw-pointer, thread-safe, no `SeismicFile`) → `private/decodeentry.nim` (A2); and
  **detection + walk** (`:161-358`, `detectKind`, `buildIndex` over a `RecordSource`, no
  map) → `model/indexwalk.nim`. The `SeismicFile` lifetime, accessors and reads stay
  (~800 lines). The cache needs `f.stamp`, `f.cached`, `f.index`: it is called from
  `openMapped` and `saveIndex`, so either it takes those as parameters or it stays (then
  only the walk and decode move).
- `convert.nim` (1212) + `seg2convert.nim` (822) + `segd/revconvert.nim` (850): conversion is
  split by an accident of history (to SEG-Y in `convert`, except SEG-2 → SEG-D and → SEG-2
  in `seg2convert`; SEG-D → SEG-D under `segd/`). A `convert/` directory by target —
  `convert/tosegy.nim`, `convert/tosegd.nim`, `convert/toseg2.nim`, with `convert.nim`
  keeping `ConvertOptions` and `convertFile`'s dispatch — makes "where is X → Y" obvious and
  drops `convert.nim:81` (`export seg2convert.Seg2ConvertOptions, ...`). Move
  `convertWithGeometry` (`writeback.nim:861`) next to `convertJoined` at the same time, so
  `GeometryJoin`/`convertJoined` become private and `survey/writeback` stops importing
  `../convert` (today `survey -> convert -> survey/join`).
- `model/tensors.nim` is imported by `segd/reader.nim:45` (and re-exported at `:48`): a
  format layer depends on `model/`, while `model/` depends on all formats. It is a utility
  (Arraymancer glue, no model types): move it to `common/tensors.nim`. S.

## B. Error handling

### B1. "Never raises" procs without `{.raises: [].}`  [do] S, low
- **Where:** documented "Never raises" but unannotated: `model/headernif.nim:460`
  (`importHeaders`), `survey/writeback.nim:819` (`copyWithGeometry`), `:861`
  (`convertWithGeometry`), `segd/revconvert.nim:819` (`convertSegdRevision`). Their siblings
  are annotated: `convert.nim:1194` (`convertFile`), `seg2convert.nim:432,758`.
- **Why:** nim-error-handling / nim-api-design: "Use `{.raises: [].}` when a proc must not
  raise." The doc promise is then checked; today a later edit can add a raising call
  silently. These are the batch boundaries the CLI and a viewer call.
- **Change:** add the pragma; where it fails to compile, the compiler names the leak (likely a
  `KeyError` from a `Table[]` or a `ValueError` from `parseInt`), which is a real bug against
  the doc. Do not annotate procs that raise by contract (`openSeismic`, `readTraces`).

### B2. One raise helper per repeated failure  [do] S, none
- **Where:** `raise newException(ValueError, "the file is closed")` appears 18 times
  (`traceindex.nim:654,741,777,807,920,982,1319`, `headerfields.nim:539`, `edit.nim:658,707`,
  `summary.nim:205,244`, `headernif.nim:167`, `prefetch.nim:199`, `headerlist.nim:145`,
  `writeback.nim:666`, plus two string-returning forms), and `"no trace " & $trace & " (the
  file has ..."` is rebuilt in `headerfields.nim:538`, `headerlist.nim:179`,
  `sorting.nim:105` although `traceindex.nim:714` already has `raiseNoTrace {.noinline,
  noreturn.}`. `requireSegy` (`:753`) and three inline `if f.kind != skSeg2: raise ...` are the
  same pattern.
- **Why:** nim-api-design "If several accessors fail the same way, route the failure through
  one private `{.noinline, noreturn.}` helper": one message, and the string building leaves
  the hot accessors (`traceField`, `traceKeys`, `readTracesInto` are called per trace).
- **Change:** in `traceindex.nim` (or `private/spans.nim` with A2):
  `proc requireOpen*(f: SeismicFile) {.inline.} = (if not f.mapped: raiseClosed())`,
  `proc requireTrace*(f: SeismicFile, trace: int) {.inline.}` (range check + `raiseNoTrace`),
  `requireKind(f, skSeg2)`; the raise procs `{.noinline, noreturn.}`. Exported to the model
  modules only (A2).

### B3. Exception taxonomy  [keep]
- `ValueError` for caller misuse (closed file, bad index, wrong kind), `SegFormatError` /
  `SegTruncatedError` for bad bytes with an `offset`, `SegCancelledError` outside `SegError`
  so format boundaries never swallow a cancel, `IOError`/`OSError` from the OS; readers and
  converters turn everything into `DiagLog` at the batch boundary (`convert.nim:1186-1191`,
  child `SegCancelledError` before `CatchableError`). This matches nim-error-handling
  ("convert per-item failures into structured outcomes at the batch boundary") and item 17 of
  the Phase 14 audit. The 40 `except CatchableError` sites checked are all such boundaries
  or destructor-safe `close` wrappers; none catches `Exception`.
- Hot paths raise nothing: `tryDecodeEntry` (`traceindex.nim:389`), the `*Raw` decoders and
  `prefetch.decodeChunk` (`:144`) are `{.raises: [].}`, and `raiseFormat`/`raiseTruncated`
  (`errors.nim:28-34`) are `{.noinline, noreturn.}`. Good as is.

## C. Ownership hooks

All custom hooks (`grep -rn 'proc \`=' src`): `JournalFile` (`edit.nim:94-99`),
`Prefetcher[T]` (`prefetch.nim:126-136`), `SeismicWriter` (`writefile.nim:110-115`),
`MapOwner`, `MapPin`, `SeismicFile` (`traceindex.nim:459-517`). All are move-only owners;
each has `=destroy` + `=copy {.error.}`; only `MapPin` adds `=dup {.error.}`; none has
`=wasMoved` or `=sink` (correct: the synthesized `=sink` is right for all of them). Each
custom `=destroy` destroys its managed fields explicitly, which Nim 2.4 requires (checked: a
custom `=destroy` does not run its fields' destructors). Declaration order is right
(hooks right after the type).

### C1. Missing `=dup {.error.}` on five move-only types  [optional] S, none
- **Where:** `JournalFile`, `Prefetcher[T]`, `SeismicWriter`, `MapOwner`, `SeismicFile`.
- **Evidence:** the nim-ownership-hooks rule ("Without it the compiler synthesizes one that
  produces nil") does not hold on 2.4.0: a scratch type with only `=copy {.error.}` gets
  "`'=dup' is not available for type <R>, which is inferred from unavailable '=copy'`". So
  nothing is broken; adding `=dup {.error.}` (as `MapPin` has) makes the move-only contract
  explicit and survives a compiler change. Bare `{.error.}` (no message) per the skill.

### C2. `=destroy` that mutates through `addr`  [optional] S, low
- **Where:** `writefile.nim:110-113` (`let p = addr w; if not p[].s.closed:
  p[].s.discardOutput()`), `traceindex.nim:502-515` (`SeismicFile`, moves `index.entries` /
  `codecs` into the map; settled in Phase 14 item 1).
- **Why:** the `=destroy(x: T)` signature exists to stop field mutation; `addr` defeats it.
  For `SeismicWriter` the mutation is not needed: `discardOutput` sets `closed`, `sink`, `tmp`
  only to be idempotent for `close`. Also, a zeroed (moved-from) `WriterState` has
  `closed = false`, so the destructor of every moved-from writer runs `discardOutput` on an
  empty state (harmless, but the moved-from sentinel is inverted).
- **Change:** split a non-mutating `releaseOutput(s: WriterState)` (close `sink`, close
  `seg2`, remove `tmp`) used by `=destroy` with no `addr`, and keep `discardOutput(var)` for
  `close`; rename `closed` to `open` (set by `openSeismicWriter`) so the zero state means
  "nothing to release". Keep `SeismicFile`'s as is (documented, the move is the point).

### C3. Exported hooks  [optional] S, none
- `=destroy*`/`=copy*` on `Prefetcher[T]` (`prefetch.nim:126,136`), `=destroy*` on `MapPin`
  (`traceindex.nim:478`) and `=copy*` on `SeismicFile` (`:517`) carry `*`; the others do
  not. Hooks bind to the type, so the `*` is not needed, also for generic types (scratch
  check: a private generic `=destroy`/`=copy {.error.}` is used and enforced from another
  module). Drop the `*` so `nim doc` does not list hooks as API.

## D. API surface

### D1. Streaming SEG-Y reader/writer expose their state as fields  [optional] M, low
- **Where:** `segy/reader.nim:93-97` (`SegyReader.file*`, `log*`), `segy/writer.nim:44`
  (`SegyWriter.log*`). The SEG-D and SEG-2 counterparts already use private fields with
  `lent` accessors: `segd/reader.nim:187-199` (`record`, `label`, `log`, `toc`),
  `segd/writer.nim:52`, `seg2/writer.nim:61`.
- **Why:** nim-api-design "keep accessor-backed fields private"; a caller can replace
  `r.file` mid-stream (the reader's layout and byte order come from it) or clear `w.log`.
  The result types (`SegyData.log`, `ImportResult.log`, `SurveyText.log`, `PrefetchChunk.log`)
  are plain data and rightly keep public fields.
- **Change:** `file`, `log` private + `func file*(r: SegyReader): lent SegyFile {.inline.}`,
  `func log*(...): lent DiagLog {.inline.}`. Callers read only (`convert.nim:276-348`, `cli.nim:766`
  read `r.log`/`r.file`); internal writers use the field. **Perf:** none.

### D2. `openSeismic`'s five defaulted parameters  [optional] M, medium (API)
- **Where:** `traceindex.nim:611` `openSeismic(path, twosComplement8015 = false, keys = false,
  demuxDir = "", progress = nil, cache = "")`; `twosComplement8015 = false` is threaded through
  15 signatures (`grep -rn 'twosComplement8015 = false' src`).
- **Why:** every other entry point with several settings takes an options object
  (`ConvertOptions`, `SegyWriteOptions`, `SegdConvertOptions`, `ImportOptions`, `SpsOptions`,
  `P1Options`, ...); nim-api-design references/parameter_and_result_shapes "related options"
  form one object. Of 316 `openSeismic(` calls, 20 pass one of the rare settings and none
  passes them positionally, so an `OpenOptions` (`twosComplement8015`, `demuxDir`, `cache`)
  with `keys` and `progress` left as parameters touches ~20 call sites.
- **Recommendation:** only if a sixth setting comes; today named arguments read fine.

### D3. Per-format sample codec names instead of overloads  [optional] M, medium (API)
- **Where:** `decodeSamples`/`encodeSamples` (`segy/samples.nim:159,199`, on `SampleFormat`),
  `decodeSegdSamples`/`encodeSegdSamples` (`segd/samples.nim:168,202`, on
  `SegdSampleFormat`), `decodeSeg2Samples`/`encodeSeg2Samples` (`seg2/samples.nim:107,144`,
  on `Seg2Format`).
- **Why:** the first parameter's enum type already selects the codec; nim-api-design prefers
  overloads on the input type over a name per type (as `toX` does). One name
  `decodeSamples(fmt, src, dst, ...)` per direction reads the same at every call site. Also
  `Seg2Format` vs `SegdSampleFormat`/`SampleFormat`: one naming scheme
  (`Seg2SampleFormat`).
- **Recommendation:** worth it only together with A2 (the `*Raw` variants move anyway) or
  not at all; the current names are explicit and listed in `docs/api.md`.

### D4. `MemoryTape.items` is a func, not an iterator  [optional] S, low
- **Where:** `io/tapedevice.nim:148` `func items*(t: MemoryTape): lent seq[TapeItem]`.
- **Why:** `items` is the stdlib iterator name; here it is an accessor to a field also named
  `items`. `for x in tape` happens to compile (it iterates the returned seq), but `toSeq`,
  `mitems` or a second overload would not behave as for a collection. Either make it
  `iterator items*(t: MemoryTape): lent TapeItem` or rename the accessor (`tapeItems`).

### D5. Sentinels and raw header codes  [keep]
- `-1` / `NaN` "unknown" values (`Location`, `TraceKeys`, `SegdTrace.scanType`,
  vendor map indices, `FileSummary`): defaults are declared on the fields
  (`record*: int = -1`), the per-trace tables stay dense (`TraceKeys` is 144 B per trace;
  `Option[float64]` doubles each field), and NaN propagates through arithmetic as wanted. Phase
  14 item 23 already declined `Option` for `FileSummary`.
- Header code fields stay integers (`channelType`, `traceIdCode`, `formatCode`,
  `manufacturer`): the specs and vendors leave code spaces open and the library must round-trip
  unknown values; an enum with holes would reject them (nim-api-design: strings/ints for
  externally extensible namespaces). The closed sets already are enums (`SampleFormat`,
  `SegdSampleFormat`, `SeismicKind`, `Severity`, `ByteOrder`, `BlockKind`).
- `func` vs `proc` (341 exported funcs, 329 procs), `lent` accessors (24), `sink` on
  ownership-taking parameters (`openEditor`, `release`, `newPrefetcher(traces)`, `recycle`,
  `addMap`) and `openArray` parameters are used as the skills say. `method` is used only for
  the open `RecordSource`/`RecordSink`/`TapeDevice` hierarchies (disk, map, tape image, OS tape
  drivers): real runtime dispatch, keep.

## E. Doc comments

### E1. 27 of 70 modules cannot be checked by `nim doc`  [do] M, low (in PLAN 15.3 "Docs build")
- **Evidence:** `nim doc` per module (scratch outdir): the 43 modules that do not import
  `model/tensors` (directly or through `segd/reader`) build with no RST error or warning.
  All 27 that do fail on `deps/arraymancer/.../cuda_global_state.nim(15, 15) Error: cannot
  open file: nimcuda/nimcuda`, before their own doc comments are rendered, so their RST is
  unverified. `-u:nimdoc` does not help (the OpenCL backend then fails).
- **Change:** import the narrower Arraymancer modules in `model/tensors.nim` (the tensor
  type, init and accessors are all it uses) so `nim doc` works; then add a `nim docs` run to
  CI. Re-run per module and fix what it finds.

### E2. Placement and coverage  [keep]
- No proc doc above its signature, no stand-alone `##` above a field (scripted check over
  `src/`). Of 756 exported routines, 70 have no doc comment: 24 one-line `endians.nim`
  loads (`beU16` etc., self-describing), about 39 `method` overrides in `io/` (the base
  documents them), the exported hooks (C3) and two field-layout pragmas. That is what nim-doc-comments asks ("skip comments that
  only restate the symbol name").
- No `runnableExamples`; the guides' examples are compiled and run by `tests/tdocs.nim`
  instead. Keep (the skill says not to add them by default).
- The `**Internal.**` markers go with A2.

## F. Tests

### F1. The suite runs only in debug mode  [do] S, low
- **Where:** `.github/workflows/ci.yml:32-35` runs `nim test` and `nim asan`;
  `config.nims:70-72` builds `tests/tester.nim` in the default mode. `tester.nim` already
  forwards `-d:release` / `-d:danger` to each test, but nothing runs them.
- **Why:** nim-testing "run all configurations": the hot decoders run with
  `{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}` (`segy/samples.nim:97`,
  `endians.nim:152`), `assert` is compiled out under danger, and the shipped CLI and the
  benchmarks are release builds, so the code users run is not the code tested.
- **Change:** CI steps `nim c -d:release -r tests/tester.nim` and
  `nim c -d:danger -r tests/tester.nim` (or a `testRelease` task); tests that rely on a
  `Defect` guard it with `when not defined(danger)`.

### F2. `nim asan` without `-d:noSignalHandler`  [do] S, none
- **Where:** `config.nims:79-81`. nim-testing: without it Nim's SIGSEGV handler reports
  before ASan does, losing the ASan report for exactly the bugs the task is for. Add it (and
  `-g`, which `--debugger:native` already implies).

### F3. Copied helpers across test files  [do] S, none
- **Evidence:** `proc readBytes` is defined in 12 test files, `writeBytes` in 6, `has(log,
  text, sev)` in 6, `fresh`/`convert`/`toDisk`/`toBytes`/`rewrite` 3-4 times each, and 31
  files declare `const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" /
  "exampleFiles"`.
- **Change:** `tests/testutils.nim` (no `t` prefix, so `tester.nim` does not run it) with
  `exampleDir`, a `scratchDir(name)` that removes and creates the temp dir (several files
  create theirs without clearing a previous run's first; check each when moving it),
  `readBytes`, `writeBytes`, `has`. nim-testing "extract domain helpers when setup is
  repeated". Leave single-use helpers in their files.

### F4. History-named test files  [optional] S each, none
- `tphase6review.nim`, `tphase8review.nim`, `tsegyreview2.nim`, `treview13.nim` group
  regressions by the review that found them; a reader looking for the edit or prefetch tests
  must know the history. Move blocks into the subject files (`tedit`, `tprefetch`,
  `tsegyreader`, ...) when those files are next touched; keep the finding id in the block
  name (`block r2_5_close_before_drain`).
- Otherwise the layout is what the skill describes: `tests/config.nims` path switch,
  auto-discovering `tester.nim`, `block` + `doAssert`/`doAssertRaises` (206 uses), no
  `std/unittest`, no bare `assert`.

## G. Style (recurring patterns only)

### G1. Hand-aligned trailing comments  [optional] M (sweep), low
- 567 trailing `##`/`#` comments are padded into columns (`grep -rnE '\S {2,}## ' src`),
  against 246 with one space; e.g. `diagnostics.nim:34-39`, `writefile.nim:62-82`,
  `prefetch.nim:60-95`. nim-style-guide: "Use ordinary spacing instead of aligning columns by
  hand"; each new longer field name re-pads the block and blurs the diff.
- **Recommendation:** no sweep (blame churn across ~70 files for no behaviour); write new
  code with one space, and re-flow a block only when it is edited anyway.

### G2. `move` where the source is a local's last use  [optional] S, none
- `convert.nim:749,787,1015,1082` (`result = move c.log`), `headerlist.nim:184,204,258,285`
  (`move L.rows`), `segy/reader.nim:563-564`, `edit.nim:524`: `c`, `L`, `r` are locals and
  these are their last uses, which auto-sink moves already. nim-ownership-hooks: prefer
  `ensureMove` where it compiles, so a later read becomes a compile error instead of a silent
  empty value; keep `move` only where the compiler cannot prove last use (fields of `var`
  parameters: `traceindex.nim:510-511,666-667`, `prefetch.nim:315`).

### G3. Already consistent  [keep]
- `std/` imports everywhere, grouped `[a, b]` imports, no `type(x)`, no `continue` in code,
  `let` by default, object constructors, `{.inline.}` on one-line accessors, lines over 100
  columns only in Markdown tables inside `##` docs (27 of 31) and four code lines
  (`writefile.nim:289`, `cli.nim:742`, two in doc text of `traceindex.nim`).

## Ordered plan (commit-sized; `nim test` green after each)

1. **15.3a Umbrella leak (A1 quick fix).** Exclude the `*Raw` decoders from the
   `samples` re-exports in `segy/reader`, `segd/reader`, `seg2/headers`, `seg2/writer`; add a
   `tumbrella.nim` block asserting `not declared(x)` for every name the umbrella's `except`
   lists name. S.
2. **15.3b Non-raising contracts (B1).** `{.raises: [].}` on `importHeaders`,
   `copyWithGeometry`, `convertWithGeometry`, `convertSegdRevision`; fix what the compiler
   reports. S.
3. **15.3c Raise helpers (B2).** `requireOpen`, `requireTrace`, `requireKind` with
   `{.noinline, noreturn.}` raisers; replace the 18 + 3 + 4 copies. S.
4. **15.3d Test configs and ASan (F1, F2).** Release and danger runs of `tester.nim` in CI
   (guard any `Defect`-reliant test); `-d:noSignalHandler` in `nim asan`. S.
5. **15.3e Test helpers (F3).** `tests/testutils.nim`; replace the copies. S.
6. **15.3f Private layer, group 1 (A2).** Create `src/parseSEG/private/` and move the pure
   internals (progress ticker, span checks, `decodeEntry` family, `*Raw` decoders,
   `headerfields` locate/read layer); drop their `except` entries and `**Internal.**` notes;
   test that no `export` names a `private/` module. M.
7. **15.3g Private layer, group 2 (A2a).** Owner choice: the allowlist export in
   `parseSEG.nim` for `traceindex`/`headerfields`/`edit`, checked against `docs/api.md` by
   `tdocs.nim`. M.
8. **15.3h Hooks (C1-C3).** `=dup {.error.}` on the five move-only types, drop `*` on hooks,
   the non-mutating `SeismicWriter` destructor with an `open` flag. S.
9. **15.3i Docs build (E1).** Narrow Arraymancer imports in `model/tensors.nim` (and move it
   to `common/`, A3) so `nim doc` runs on every module; fix the RST it reports; `nim docs` in
   CI. M.
10. **Optional, owner's call:** D1 (`SegyReader`/`SegyWriter` accessors), D4
    (`MemoryTape.items`), G2 (`ensureMove`), then the larger A3 splits (`model/indexcache`,
    `convert/` by target with `convertWithGeometry` moved in), D2 (`OpenOptions`), D3
    (codec overloads), F4 (fold review test files).
