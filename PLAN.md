# parseSEGD: master plan and checkpoint log

> **Resuming in a new session? Read this file first, then follow "Resume protocol".**

## Goal
An idiomatic, high-performance Nim library to **read and write** SEG seismic data on **disk and
tape**, designed to back a future high-performance viewer and HPC processing. Priority formats:
1. **SEG-D Rev 2.0** (the owner's most important format; see `63.sgd`)
2. SEG-Y Rev 1.0 (plus Rev 0, which it is a superset of)
3. SEG-D Rev 2.1 and 3.0
4. SEG-Y Rev 2.1

**Long-term goal: spec out and support every revision of both standards** (SEG-Y 0/1/2.0/2.1,
SEG-D 1/2.0/2.1/3.0/3.1). Standalone spec PDFs exist for SEG-Y 1.0/2.0/2.1 and SEG-D
**2.0**/2.1/3.0/3.1. SEG-D Rev 1 and SEG-Y Rev 0 are known only from the history sections of
the later documents.

## Owner decisions (2026-11-07, revised)
- **One data model, many revisions.** The revision is always identified from the headers
  (SEG-Y bytes 3501-3502; SEG-D GH2 bytes 11-12), so readers dispatch on it.
  - SEG-Y uses **one** `SegyFile` type for Rev 0-2.1, where revision-specific fields are optional.
  - SEG-D uses **one** `SegdRecord` type for Rev 1-3.1, whose optional blocks are variant
    objects keyed by block type.
  - An auto-detecting `openSeismic(path)` covers both standards.
- **Sample storage: Arraymancer `Tensor`.** Trace samples live in `Tensor[float32]` (or
  `float64` for 8080 / SEG-Y format 6), shaped `[traces, samples]` per channel set or gather.
  This sets the library up for HPC processing.
  - Headers stay plain Nim objects.
  - Decoders write straight into the tensor's buffer, with no intermediate `seq`.
  - Keep the byte-level codecs (`common/`, sample decoders on `openArray[byte]`) free of
    Arraymancer, so they stay testable and reusable.
  - Isolate the Tensor dependency in the model/reader layer.
  - Task 2.0 confirms that Arraymancer builds on Nim 2.4.
- **Errors: never silent, never interrupting.** Reading a file always runs to completion when
  that is physically possible. Every problem becomes a **diagnostic** entry, never an exception
  that aborts processing:
  - an entry holds severity (info/warning/error/fatal), a code, the file name, the byte offset, the
    record/trace/block location, and a message;
  - for each problem the reader keeps going: raw bytes are preserved, unsupported or
    unparsable blocks are kept raw and flagged, and an unsupported sample format becomes a
    trace flagged "undecoded" with its raw bytes kept;
  - only truly unrecoverable conditions (I/O failure, truncated file) end the read early, and
    those are logged as `fatal` too;
  - the whole log is returned with the result (`ReadResult = (data, diagnostics)`) and is
    serialized as **NIF** (confirmed by the owner: "NIF is the future for Nim"). Use the
    toolchain's `nifbuilder`/`nifreader` (`$nim/dist/nimony/src/lib`, verified to build on
    Nim 2.4, no extra dependency). JSON export is optional.
  - Exceptions are used internally only and are converted to diagnostics at the
    record/trace boundary (nim-error-handling "batch boundary" pattern).
  - Writers validate first and refuse to emit spec-invalid output, unless a "lenient"
    option is set.
- **Disk AND tape, read AND write, are both first-class.**
  - The format layer reads and writes a stream of *records* and *tape marks*.
  - Backends: plain disk file; tape-image file (preserves record lengths and tape marks);
    memory; **Linux `st` device** (`read()`/`write()` per block, `MTIOCTOP`: WEOF, FSF, BSF,
    REW, and `MTIOCGET` status); **Windows tape** (`CreateFile("\\.\TAPE0")`, `ReadFile`/
    `WriteFile`, `WriteTapemark`, `SetTapePosition`, `GetTapeStatus`).
  - Follow the spec for tape layout: storage unit label, block sizes per App. F, FIXREC
    padding, tape marks between files, and EOD = 2 marks.
  - The owner's own data is on disk, so tape is tested with tape-image files and a mock
    device.
- **Byte order.** Decoded values are native values. Readers detect the byte order (the SEG-Y
  Rev 2 marker, else plausibility of format code and sizes) and keep it as metadata. Writers
  default to the spec (big-endian), with an explicit `byteOrder` option for little-endian.
- **Extended / external / user-defined blocks are first-class:**
  - every byte is preserved losslessly (raw `seq[byte]`) even when parsed;
  - spec-defined blocks are typed, and unknown SEG-D 3.x block types are kept raw (with an
    info diagnostic);
  - **vendor-decoder registry**: register decoders at runtime by (manufacturer code, block
    kind), so they plug in without forking;
  - writers re-emit raw blocks unchanged.
  - **Vendor maps are true plugins:** declarative `.nif` files describe vendor block layouts
    and are loaded at runtime from a search path, with no recompilation. CLI tooling
    validates maps, scaffolds a skeleton map from an unknown file, and applies maps. Design:
    **`docs/design/vendor_maps.md`**. The owner has no vendor maps yet and will add them later.
  - Real data uses these heavily: the 3.0 sample has 9 vendor blocks (0xB0-0xB8) on every trace.
- **Gather-agnostic.** Never assume shot gathers. Files may hold **receiver gathers** (e.g.
  node data) packed into standard SEG-D/SEG-Y with minimal header changes.
  - Expose full per-trace geometry (source and receiver line/point/position) and derive the
    gather type rather than assuming it.
  - SEG-Y: binary 3229-3230 trace sorting code (6 = common receiver point).
  - SEG-D has no sorting code. Detect a receiver gather when the receiver position is
    constant and the per-trace source info varies. SEG-D 3.x allows source description /
    Additional Source Info blocks inside **trace headers**, which is how per-trace sources are
    carried. In 2.x, look at GH#N source blocks plus vendor extensions.
- **Multi-component data** (several components per station on consecutive traces):
  - SEG-D 3.x: each component in its own channel set. THE#1 byte 9 = group index (component
    number), byte 21 = sensor type. The Orientation block (0x60) gives the rotation matrix and
    the "rotation applied" flags. Group traces by (receiver line, point, point index, depth
    index, reshoot index).
  - SEG-D 2.x: there is **no** grouping field, only THE#1 byte 21 sensor type (1 hydrophone,
    2-5 geophone V/inline/crossline/other, 6-9 accelerometer). Group heuristically by the same
    receiver line/point plus differing sensor type, and expose this as a `componentGroups`
    query.
  - SEG-Y: no standard field. Group by receiver coordinates and trace ID, or vendor bytes.
- **Rotational data:** neither SEG-D 3.0 nor 3.1 defines a rotational-sensor type. 3.x only has
  the Orientation block (sensor *attitude* RX/RY/RZ and its rotation matrix) and channel types
  0xC8 tilt / 0xC9 angle. Rotational-rate data from specific equipment is therefore
  **vendor-specific** (undefined sensor type codes and/or user blocks). Handle it via the
  vendor-decoder registry once a real sample is available. *(Owner: please provide a file.)*
- **Viewer-ready I/O.** A future high-performance viewer needs chunked, non-blocking access:
  - On open, build a **trace index** by walking headers only (offset, size, channel set,
    key geometry). It's cheap: the 65 MB 3.0 file has 3957 traces.
  - Random access to trace ranges, e.g. `readTraces(file, 1000..1999)`, into a Tensor slice.
  - Disk files use memory-mapped I/O (`std/memfiles`); tape and streams use a sequential
    reader.
  - An optional **prefetch thread** decodes ahead into a bounded queue (the API must not
    block the UI thread), so nothing in the API may assume whole-file loading.

- **Dispatch policy (2026-11-07).** Runtime dispatch (`ref object` + `method`) is used **only**
  at the I/O backend boundary (disk / tape image / memory / Linux st / Windows tape / user
  backends), where the backend is chosen at runtime and users may add their own. That costs one
  indirect call per block or chunk. Everything else (headers, records, trace index, codecs,
  Tensors) is plain `object` + `proc`/`func`. Hot paths (field and sample decoding on
  `openArray[byte]`) never touch methods. Base methods declare `raises: [CatchableError]` (see
  Log, 2.2). An object variant could replace the methods later if the backend set is closed.
- **Very large files (40 GB+, larger than RAM) are a hard requirement.** Never load a whole file.
  - Disk random access uses `std/memfiles` (the OS pages on demand), with 64-bit offsets everywhere.
  - Keep the trace index compact (~24 B/trace: offset i64, size i32, channel set/flags, key
    geometry kept elsewhere or lazy). 10 M traces ≈ 240 MB.
  - Tensors hold only the requested range or gather. Writers stream record by record.
  - Test with a sparse file larger than 4 GB (task 6.7).
- **In-place header edits on disk** (e.g. updating positions, coordinates or statics, much faster
  than re-exporting the file):
  - write through a read-write memmap at offsets from the trace index;
  - only size-preserving field edits, each encoder validating that the value fits (width, BCD
    digits, range); anything else is refused with a diagnostic;
  - every edit is journaled first (offset + original bytes + new bytes) to a NIF journal, so it
    can be undone;
  - not available on tape; edits that change sizes need a full rewrite.
- **Headers-only mode:** read all headers and skip sample bytes (seek on disk, read-and-discard
  on tape). This is the same walk that builds the trace index.
- **NIF header export/import:** export all headers as NIF (decoded fields plus raw bytes for
  lossless output, or fields only), streamed to the file. Import works as a **patch**: compare
  with the file and apply only the changed fields, either in place (journaled) or by writing a
  new file that reuses the original sample data.

## Sample files (`SEG Spec/exampleFiles/`)
| File | Size | What the headers say | In git? |
|---|---|---|---|
| `63.sgd` | 4.3 KB | SEG-D **Rev 2.0**, Geo Space, format 8058, no label, GH1 + 2 extra GH blocks, 1 trace | yes |
| `00000151_12900_11300.sgd` | 65 MB | SEG-D **Rev 3.0**, INOVA, format 8058, no label, 17 GH blocks, 3957 traces, 9 vendor THE blocks per trace | **no** (too big). Write a 1-trace subset as a committed fixture once it reads (task 5.4) |
| `Sweep0.sgy` | 51 KB | SEG-Y **Rev 0**, **little-endian**, ASCII text, format 5, 1 sweep trace × 12001 @ 1000 µs | yes |
| `BO_3D-Inglewood_rev21_v7.sgy` | 2 MB | SEG-Y **Rev 2.1**, EBCDIC, format 1, 103 ext. text records (incl. binary PNG), 200 traces | yes |
Both SEG-D samples use format 8058. Formats 8015/8022/8024/8036/8038/8042/8044/8048 are tested
with synthetic data only. *(Owner: integer-format SEG-D samples would help.)*

## Resume protocol (token budget rules)
1. **Never open the PDFs** in `SEG Spec/*.pdf`. Their full text is already in
   `SEG Spec/text/*.txt` (page-marked with `=== PAGE N ===`). New PDFs: run
   `tools/extract_specs.sh` (needs `poppler-utils`; `sudo apt-get install poppler-utils`).
2. Prefer the distilled notes (`docs/spec/README.md` is the index). Read the text files only to
   resolve an `AMBIGUITY` or a gap, with `grep -n` plus a targeted `sed -n 'a,bp'`.
3. Find the first unchecked task below, do it, tick it, add a line to the **Log**, and
   **commit**. A commit after each task is the checkpoint.
4. Before writing any Nim, load the matching `nim-*` skill (see `AGENTS.md`). The
   `.agents/skills/*` symlinks are broken in this container. Read the skills from
   `/opt/nim-agent-template/skills/<name>/SKILL.md` instead.
5. Run the tests with `nim test` (this runs `tests/tester.nim`, which discovers `tests/t*.nim`).
   The Python oracles in `tools/walks/` decode the sample files independently. Compare the
   Nim output against them.
6. Work branch: `seg-library`.
7. Dependencies are managed by **Atlas**: sources are in `deps/` (gitignored, so read and debug
   them there), and the paths are in the Atlas section of `nim.cfg` (`--noNimblePath`). On a
   fresh clone, run `atlas rep atlas.lock`. To add a dependency, add it to the nimble file and
   run `atlas install`, then `atlas pin`. `.vscode/settings.json` sets `nim.nimbleAutoSetup: false` so the editor extension does not re-run `nimble setup`.

## Architecture (target)
```
src/parseSEGD.nim                # umbrella module, re-exports public API
src/parseSEGD/
  common/
    endians.nim     # big-endian get/put (u8..u64, i8..i64, 24-bit); ByteOrder + getNum/putNum (BE/LE/pair-swapped)
    fieldlayout.nim # `{.at: specByte.}` pragma -> decodeFields/encodeFields/fieldTable for fixed-layout headers
    bcd.nim  ibmfloat.nim  ebcdic.nim  errors.nim
    diagnostics.nim # Diagnostic, DiagLog, severity, codes; NIF/JSON serialization
  io/
    records.nim     # RecordSource/RecordSink: readRecord/writeRecord/writeTapeMark/eof
    diskio.nim      # plain file (memfiles for random access) + byte-stream record emulation
    tapeimage.nim   # tape-image file (record lengths + tape marks preserved)
    tape_linux.nim  # st(4): MTIOCTOP/MTIOCGET
    tape_windows.nim# Win32 tape API
  segy/   types textheader binheader traceheader samples reader writer
  segd/   types samples rev2 (2.0/2.1) rev3 reader writer vendors (decoder registry)
  model/  tensors.nim (Arraymancer views), traceindex.nim, gathers.nim (gather type,
          component groups), prefetch.nim (threaded read-ahead)
tests/   t*.nim, fixtures generated by tests, real samples in SEG Spec/exampleFiles
tools/walks/  Python oracles for the sample files
```
Design principles: zero-copy decoding from `openArray[byte]`; lossless round-trip; streaming /
indexed access, never whole-file loading; diagnostics instead of aborts; writers validate.

## Phases and tasks

### Phase 0: Spec ingestion (one-time)
- [x] 0.1 Install poppler and convert all PDFs to page-marked text (`tools/extract_specs.sh`)
- [x] 0.2 Write conventions for the spec notes (`docs/spec/CONVENTIONS.md`)

### Phase 1: Spec distillation
- [x] 1.1 `segy_rev1.md` · [x] 1.2 `segd_rev2_1.md` · [x] 1.3/1.4 `segd_rev3_0_a.md`, `segd_rev3_0_b.md`
- [x] 1.5 Review and verification against the real files (`segd_rev3_0_verified.md`, README index)
- [x] 1.6 `segy_rev2_1.md` (delta on rev 1, verified on Inglewood)
- [x] 1.6b `segd_rev2_0.md` from the standalone 2.0 PDF (word-diffed against 2.1, checked against `63.sgd`)
- [ ] 1.7 (later) `segd_rev3_1_delta.md` (also check 3.1 for new sensor types, e.g. rotational)
- [ ] 1.8 (later) The remaining revisions: SEG-Y 2.0 vs 2.1 differences, SEG-D Rev 1 (from history sections)

### Phase 2: Core infrastructure
- [x] 2.1 endians, bcd, ibmfloat, ebcdic, errors (`tests/tcommon.nim`)
- [x] 2.0 Add Arraymancer: `requires "arraymancer"` in the nimble file, check that it builds on
      Nim 2.4 with `--noNimblePath` (update `nimble.paths`), and do a smoke test of
      allocating a `Tensor[float32]` and writing into its raw buffer. If it fails, record why
      and pick a fallback (pinned version or our own thin tensor type with the same shape API).
- [x] 2.3 Diagnostics: `Diagnostic`/`DiagLog`, the severity and code catalog, **NIF** serialization
      (+ a NIF reader for round-trip tests), the exception→diagnostic boundary helper. Add
      `--path:"$nim/dist/nimony/src/lib"` to `config.nims` and `tests/config.nims`.
- [x] 2.2 I/O layer: the record source/sink interface (records + tape marks); disk-file,
      tape-image and memory backends; Linux `st` and Windows tape backends (build-gated with
      `when defined(linux/windows)`; test with a mock device and tape images)

### Phase 3: SEG-Y (Rev 0/1 first, then 2.1)
- [x] 3.1 Textual, binary, and trace headers (decode/encode, round-trip tests)
- [x] 3.2 Sample formats 1,2,3,5,8 into Tensors; byte-order and ASCII/EBCDIC detection;
      extended textual headers; the `byteOrder` write option
- [ ] 3.3 Validate against `Sweep0.sgy` (Rev 0, LE) and Inglewood (Rev 2.1 subset)
- [ ] 3.4 Rev 2.1 extensions (extra trace headers: Ext1 `SEG00001` + proprietary, trailer, User Data
      stanzas, Layout XML). Already done in 3.1/3.2: byte-order marker, binary ext. fields, all formats

### Phase 4: SEG-D Rev 2.0 / 2.1 (2.0 first)
- [ ] 4.1 Headers (GH1/GH2/GH#N, CSD, skew, extended, external, demux trace header, THE)
- [ ] 4.2 Sample formats (all 2.x demux codes) into Tensors; multiplexed codes → diagnostic + raw
- [ ] 4.3 Writer and round-trip tests with synthetic records (disk and tape image)
- [ ] 4.4 Validate against `63.sgd`: a byte-identical read→write round trip
- [ ] 4.5 Vendor registry + **NIF vendor-map engine** (`docs/design/vendor_maps.md`): map loader
      and validator, matcher, compiled field tables, `VendorBlock` values, code-decoder
      precedence. Test with a hand-written example map against synthetic blocks.

### Phase 5: SEG-D Rev 3.0
- [ ] 5.1 Storage unit label, TOC, general headers 1-3 and all optional/typed blocks
- [ ] 5.2 Trace headers and typed extensions (incl. Orientation 0x60), trailer, reader
      (resolve each trace's channel set from its own header)
- [ ] 5.3 Writer and round-trip tests
- [ ] 5.4 Validate against `00000151_12900_11300.sgd` (local only), then write a few-trace copy
      with all headers to `SEG Spec/exampleFiles/` and commit it as a permanent fixture

### Phase 6: Data model for viewers and HPC
- [ ] 6.1 Trace index (header-only walk) and range reads into Tensor slices, memfiles backend
- [ ] 6.2 Gather-type detection (shot/receiver/other) and multi-component grouping (`componentGroups`)
- [ ] 6.3 Prefetch thread with a bounded queue (non-blocking API for a viewer)
- [ ] 6.4 Benchmarks on the 65 MB sample (decode throughput, index build time)
- [ ] 6.5 Headers-only API (`readHeaders`): every header, samples skipped, for disk and tape
- [ ] 6.6 In-place header edits: memmap read-write, field-level encode with validation, NIF
      undo journal (apply/rollback), refuse size-changing edits; tests on synthetic SEG-Y/SEG-D
- [ ] 6.7 Large-file test: a sparse synthetic file larger than 4 GB (index build, a range read
      near the end, an in-place edit near the end) to prove 64-bit offsets work

### Phase 7: Tooling
- [ ] 7.1 CLI: `parseSEGD info|dump|convert|diag` (diag prints the NIF log)
- [ ] 7.1b CLI: `parseSEGD vendormap check|scaffold|apply|list`. `scaffold` emits a skeleton
      `.nif` map for every unmapped vendor area (e.g. the 9 INOVA blocks 0xB0-0xB8 in the 3.0
      sample, and the 3 Geo Space extended blocks in `63.sgd`)
- [ ] 7.3 NIF header export/import: streamed export (fields + raw, or fields only); import as
      a patch (diff → in-place journaled edits, or rewrite with the original samples). CLI:
      `parseSEGD headers|edit|export|import`
- [ ] 7.2 Docs and CI updates

## Open questions for the owner
- A sample file with **rotational data**, and one with **receiver-gather** SEG-D, would let us verify these paths.
- Integer-format SEG-D samples (8015/8022/8024/8036/8038/8042/8044/8048).

## Log
- 2026-11-06: Phase 0 done. The spec text is extracted and committed. Branch `seg-library` created.
- 2026-11-06: Task 2.1 done: common primitives and tests pass (debug and release). Phase 1 distillation was started with 4 parallel subagents.
- 2026-11-06: Task 1.2 done: segd_rev2_1.md (731 lines, 18 AMBIGUITY items, 10 open questions).
- 2026-11-06: Task 1.1 done: segy_rev1.md (866 lines, 24 resolved AMBIGUITY items, open questions Q1-Q12).
- 2026-11-06: Task 1.4 done: segd_rev3_0_b.md (902 lines).
- 2026-11-06: Task 1.3 done: segd_rev3_0_a.md (893 lines, 16 AMBIGUITY items).
- 2026-11-06: Task 1.5 started: the 3.0 Additional Source Info ID is resolved as 0x20 (via the 3.1 text). Record each later resolution in a `## Resolutions` section at the end of the note concerned.
- 2026-11-07: The owner added sample files and answered the questions. The sample headers were inspected and the plan updated. The 65 MB Rev 3.0 sample is git-ignored.
- 2026-11-07: The SEG-D Rev 2 PDF (Dec 1996, manufacturer list rev. Jan 2006) was added, extracted and committed.
- 2026-11-07: Task 1.6 done: segy_rev2_1.md (904 lines). The Inglewood walk tiles exactly. Gotcha: rev 2.0 uses 3507-3510 as one u32, so branch on the revision. The walk scripts are in tools/walks/.
- 2026-11-07: Tasks 1.5 and 1.6b done. segd_rev2_0.md (858 lines) is word-identical to 2.1 except for 11 listed items. 8015 = one's complement per spec. Samples without THE = (TE-TF)/SI. Real files contain spec-invalid zeros: warn, never reject. **Phase 1 complete.**
- 2026-11-07: Owner corrections: tape read/write is first-class (Linux and Windows); Tensor (Arraymancer) storage; diagnostics log instead of exceptions (NIF?); gather-agnostic (receiver gathers); multi-component grouping; rotational data is vendor-specific; viewer-ready chunked/prefetch I/O. Phases were reordered: **next is task 2.0 (Arraymancer check)**, then 2.3, then 2.2.
- 2026-11-07: NIF confirmed for the error log. Vendor maps were designed as declarative NIF plugins (`docs/design/vendor_maps.md`). The toolchain nifbuilder/nifreader were smoke-tested OK on Nim 2.4. **The next session starts at task 2.0.**
- 2026-11-07: Task 2.0 done. Arraymancer 0.7.33 builds and runs on Nim 2.4 (debug and `-d:danger`) under `--noNimblePath`. `import arraymancer/tensor` needs only `nimblas` at compile time, and no system BLAS is linked or installed (BLAS loads only if matmul is called). Writing raw buffers via `unsafe_raw_offset` works (`tests/ttensor.nim`). `nimble setup` generates `nimble.paths` (machine-specific, now gitignored and untracked) and `config.nims` includes it; tests pick it up through the root config. **Next: task 2.3.**
- 2026-11-07: Switched dependency management from `nimble setup` to **Atlas** (owner request: agents can read library sources in `deps/`). `nim.cfg` holds the Atlas paths, `atlas.lock` is committed, and `deps/atlas.config` is tracked. Tests pass, and nimsuggest resolves into `deps/`. **Next: task 2.3.**
- 2026-11-07: Task 2.3 done: `common/diagnostics.nim` (`Severity`, a `DiagCode` catalog with stable NIF spellings, `Location` (incl. `file`, so merged logs from several files stay attributable), `Diagnostic`, `DiagLog`, `toNif`/`writeNif`/`parseDiagnostics`/`readDiagnostics`, and `tryRecord`, a boundary template that maps truncation and I/O to fatal, format violations to error, and anything else to internal). `SegError` now carries `offset`, and `SegTruncatedError`/`raiseTruncated` were added. The nimony lib path is in `config.nims`; import `nifcore` and `stringviews` alongside `nifreader`. Tests: `tests/tdiagnostics.nim`. **Next: task 2.2 (I/O layer).**
- 2026-11-07: Task 2.2 done: `io/records` (`RecordSource`/`RecordSink` base types with `*Impl` methods; a double tape mark is reported as `rkEndOfData`; `RecordCursor` gives exact-length reads that span blocks, stop at tape marks and track offsets), `io/diskio` (chunked byte stream; tape marks are not stored), `io/tapeimage` (SIMH `.tap`, odd records padded to even unless `padOdd = false` for E11, erase gaps skipped, class bits and trailer mismatches raise), `io/tapedevice` (`TapeDevice` interface, `DeviceSource`/`DeviceSink`, and `MemoryTape` as both the memory backend and the mock drive), `io/tape_linux` (st(4), importc from `<sys/mtio.h>`, compiled against the real header), `io/tape_windows` (Win32 tape API; cross-compiles and links with `zig cc -target x86_64-windows-gnu`, not run on hardware). Neither real-drive backend has been tested on a drive. **Gotcha:** base methods need `raises: [CatchableError]`. Call sites take their exception handling from the base method, so a non-raising base makes callers skip cleanup when an override raises (ASan found the leaks). Tests: `tests/tio.nim`, ASan clean. **Next: task 3.1 (SEG-Y headers).**
- 2026-11-07: Owner questions answered and decisions recorded: dispatch policy (methods only at the I/O backend boundary), 40 GB+ files, in-place header edits with a NIF undo journal, headers-only mode, NIF header export/import as patches. New tasks 6.5-6.7 and 7.3. **Next: task 3.1 (SEG-Y headers).**
- 2026-11-07: Task 3.1 done. `common/fieldlayout` adds the `{.at: specByte.}` pragma: each header field is declared once with its spec byte number, and `decodeFields`/`encodeFields` (unrolled through `fieldPairs`) plus a compile-time `fieldTable` (for future NIF export and in-place edits) are derived from it. A test checks that each table tiles its block exactly. `endians` gained `ByteOrder` (big/little/pairSwapped) and generic `getNum`/`putNum`. `segy/textheader` (raw 3200 bytes, EBCDIC/ASCII detection, cards), `segy/binheader` (all 400 bytes mapped on the 2.1 layout so round trips are lossless for any revision; the 3507-3510 Rev 2.0 u32 vs 2.1 u16+u16 split branches on 3501-3502; revision-aware `effective*` accessors; `bytesPerSample`; `validate` → diagnostics), and `segy/traceheader` (all 240 bytes mapped; scalar helpers). Verified on Sweep0 (LE, Rev 0) and on all 200 Inglewood trace headers (BE, Rev 2.1): every block round-trips byte for byte. **Gotcha:** `fieldPairs` substitutes the loop variable name everywhere in the body, object-constructor keys included, so never name it like a field (`name`). Also fixed: `src/parseSEGD.nim` had not compiled since 2.2 (`tape_linux` called the `status` method from `readBlock`, which inferred `raises: Exception`); `tests/tumbrella.nim` now guards it. Byte-order *detection* is still task 3.2, and Ext1 (`SEG00001`) is task 3.4. **Next: task 3.2.**
- 2026-11-07: Task 3.2 done. `segy/samples`: codecs for **all** SEG-Y formats (1-12, 15, 16; format 4 is read-only and reads as i16 × 2^-G), decoding into any `openArray[float32|float64]` in any byte order with the order hoisted out of the loop. Encoders round to nearest and raise `SegFormatError` for values that don't fit, NaN in integer formats, and 3-byte formats in pair-swapped order. `definedSampleFormats` exists because the enum has holes (13, 14) and can't be iterated. `model/tensors`: `newTraceTensor`, `decodeTrace`/`encodeTrace` write straight into a C-contiguous `[traces, samples]` row (the only Arraymancer import). `binheader.detectByteOrder`: marker first, else a plausibility score (BE, then LE, wins ties). Without the marker, LE and pair-swapped agree on every 16-bit field, so the Rev 2 32-bit ns breaks the tie. `segy/exttext`: an incremental record walker (`add`/`needsMore`, so it also works on tape). Stanzas start at record starts (Rev 2.1) or, with `rev1Lines`, at any card line. Binary stanzas are skipped by BYTES, so their continuation records are never scanned. Records stay raw for lossless writes, and there are builders for writers (`addText`/`addStanza`/`addEndText`). Verified: Sweep0 f32 LE and Inglewood IBM samples match the Python oracle; both re-encode byte for byte; Inglewood's 103 extended records yield the 6 expected stanzas, with the 208104-byte PNG intact. `tests/tester.nim` now forwards `-d:release`/`-d:danger` to each test (before, it silently built them in debug). Text-encoding detection was already done in 3.1; the `byteOrder` write option is the `order` parameter of every encoder, and the writer's options object comes with the writer. **Next: task 3.3** (validate against the samples; this needs the reader: open → detect → ext headers → trace walk with diagnostics). Note: no SEG-Y writer task exists yet; fold it into 3.3 or add one.
