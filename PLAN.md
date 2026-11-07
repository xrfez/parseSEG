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
| `00000151_12900_11300.sgd` | 65 MB | SEG-D **Rev 3.0**, INOVA, format 8058, no label, 17 GH blocks, 3957 traces, 9 vendor THE blocks per trace | **no** (too big); tests skip it when absent |
| `inova_rev30_5traces.sgd` | 87 KB | The 65 MB record cut to its 3 aux + first 2 seismic traces (`tools/make_rev3_fixture.nim`); differs from the original's first 86,744 bytes only in GH#3 sizes and CS4's trace count | yes |
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
    diskio.nim      # plain file as a byte stream (seekForward for skips)
    memsource.nim   # std/memfiles source: O(1) skips, zero-copy `memory` for range reads
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
- [x] 3.3 Validate against `Sweep0.sgy` (Rev 0, LE) and Inglewood (Rev 2.1 subset), plus the
      streaming reader (`segy/reader`) and the validating writer (`segy/writer`) this needed
- [x] 3.4 Rev 2.1 extensions and robustness (owner-approved scope, 2026-11-07):
  - [x] 3.4a Write-as-read policy: unreadable output (count/size mismatches) is always refused
        unless `lenient`; spec-value violations are warnings when unchanged from what was read
        (snapshot of the binary header and extended records), errors when new or edited
  - [x] 3.4b User Data (`((SEG:UserData))`/`UserHeader`, D-9): walk desc-block chains by
        `blocksize` (fixes the early end of extended headers on binary User Data), index
        attachments (label, format, size, offset), lazy trailer (never load a 27 GB block),
        `userData`/`extract`, writer add/remove, tests from the spec examples
  - [x] 3.4c Trace Header Extension 1 (`SEG00001`) decoded, proprietary extensions as named raw
        blocks, byte-order conversion of extra headers in the writer
  - [x] 3.4d Layout XML (`((SEG:Layout:text/xml))`, D-8): parse into a field map; accessors
        (inline, crossline, CDP/source/receiver coordinates, ...) use it when present

### Phase 4: SEG-D Rev 2.0 / 2.1 (2.0 first)
- [x] 4.1 Headers (GH1/GH2/GH#N, CSD, skew, extended, external, demux trace header, THE)
- [x] 4.2 Sample formats (all 2.x demux codes) into Tensors; multiplexed codes → diagnostic + raw
- [x] 4.3 Writer and round-trip tests with synthetic records (disk and tape image)
- [x] 4.4 Validate against `63.sgd`: a byte-identical read→write round trip
- [x] 4.5 Vendor registry + **NIF vendor-map engine** (`docs/design/vendor_maps.md`): map loader
      and validator, matcher, compiled field tables, `VendorBlock` values, code-decoder
      precedence. Test with a hand-written example map against synthetic blocks.

### Phase 5: SEG-D Rev 3.0
- [x] 5.1 Storage unit label, TOC, general headers 1-3 and all optional/typed blocks
- [x] 5.2 Trace headers and typed extensions (incl. Orientation 0x60), trailer, reader
      (resolve each trace's channel set from its own header)
- [x] 5.3 Writer and round-trip tests
- [x] 5.4 Validate against `00000151_12900_11300.sgd` (local only), then write a few-trace copy
      with all headers to `SEG Spec/exampleFiles/` and commit it as a permanent fixture

### Phase 6: Data model for viewers and HPC
- [x] 6.1 Trace index (header-only walk) and range reads into Tensor slices, memfiles backend
- [ ] 6.2 Gather-type detection (shot/receiver/other) and multi-component grouping (`componentGroups`)
- [ ] 6.3 Prefetch thread with a bounded queue (non-blocking API for a viewer)
- [ ] 6.4 Benchmarks on the 65 MB sample (decode throughput, index build time)
- [x] 6.5 Headers-only API (`readHeaders`): every header, samples skipped, for disk and tape
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
- 2026-11-07: Task 3.2 done. `segy/samples`: codecs for **all** SEG-Y formats (1-12, 15, 16; format 4 is read-only and reads as i16 × 2^-G), decoding into any `openArray[float32|float64]` in any byte order with the order hoisted out of the loop. Encoders round to nearest and raise `SegFormatError` for values that don't fit, NaN in integer formats, and 3-byte formats in pair-swapped order. `definedSampleFormats` exists because the enum has holes (13, 14) and can't be iterated. `model/tensors`: `newTraceTensor`, `decodeTrace`/`encodeTrace` write straight into a C-contiguous `[traces, samples]` row (the only Arraymancer import). `binheader.detectByteOrder`: marker first, else a plausibility score (BE, then LE, wins ties). Without the marker, LE and pair-swapped agree on every 16-bit field, so the Rev 2 32-bit ns breaks the tie. `segy/exttext`: an incremental record walker (`add`/`needsMore`, so it also works on tape). Stanzas start at record starts (Rev 2.1) or, with `rev1Lines`, at any card line. Binary stanzas are skipped by BYTES, so their continuation records are never scanned. Records stay raw for lossless writes, and there are builders for writers (`addText`/`addStanza`/`addEndText`). Verified: Sweep0 f32 LE and Inglewood IBM samples match the Python oracle; both re-encode byte for byte; Inglewood's 103 extended records yield the 6 expected stanzas, with the 208104-byte PNG intact. `tests/tester.nim` now forwards `-d:release`/`-d:danger` to each test (before, it silently built them in debug). Text-encoding detection was already done in 3.1; the `byteOrder` write option is the `order` parameter of every encoder, and the writer's options object comes with the writer. **Next: task 3.3** (validate against the samples; this needs the reader: open → detect → ext headers → trace walk with diagnostics).
- 2026-11-07: Task 3.3 done. `segy/reader`: `openSegy(RecordSource)` + `readTrace` streams over `RecordCursor`, so it works on disk, tape images and devices. It handles the tape label (separate record or copied onto disk), byte-order detection, Rev 0 defaults, `firstTraceOffset` overriding the extended count, a missing EndText (warning), fixed-length vs per-trace ns, and Rev 2 additional headers (k from Ext1 157-158, else binary 3507, with Ext1 ns/dt overrides). Traces end at `numTraces`, the Ext1 last-in-file flag, a trailer record (`((` at a trace boundary), a tape mark or EOD; declared counts are checked. Nothing raises: fatal conditions (truncation, an undefined format code, so trace length unknown) stop the read but all headers stay available. Traces keep raw bytes; `decodeInto` fills a Tensor row; `readSegy(path)` is the small-file convenience (`SegyData`). `segy/writer`: `openSegyWriter` validates, refuses spec-invalid output unless `lenient`, then writes one record per SEG-Y record (unblocked tape layout). The `byteOrder` option reorders headers and samples; raw Rev 2 extra headers refuse reordering until 3.4. Verified: both samples round-trip **byte-identically** to disk and SIMH tape images (305 tape records for Inglewood); BE↔LE↔pair-swapped conversions read back equal and convert back byte for byte; a 128-byte label works on disk and tape; truncation gives one fatal entry at the exact offset, with 150 traces kept; synthetic Rev 2.1 files cover Ext1 ns overrides, numTraces, the last-trace flag, and trailers with count 1 / -1 / 0. Diagnostic offsets are real file offsets, including the 128-byte shift when a tape label is copied in front (`validate(headerOffset)`). **Next: task 3.4** (Ext1/proprietary header decode + reordering, User Data stanzas, Layout XML).
- 2026-11-07: Independent review of 3.1-3.3 (a subagent with the code and spec notes, no conclusions passed in) found 13 verified issues; all fixed, with one regression test each (`tests/tsegyreader.nim`, "review_*" blocks). Reader: a **push-back buffer** (`unread`) lets it look ahead one 3200-byte record and un-read it, which works on tape too. It is used to (a) end an extended header that lacks EndText at the first non-text record instead of swallowing the file, (b) detect trailers by a full stanza header plus a text check instead of the first two bytes (little-endian trace numbers 10280 looked like `((`), and (c) reject a tape-label match not followed by `C`. Reads now grow in 4 MB chunks (`readInto`), so corrupt counts cost memory only for bytes that exist. A u64 `firstTraceOffset` no longer raises a RangeDefect. Headers read before a fatal error are kept. Trace buffers are reused. `binheader.rulesRevision` picks the rules: `00 01` → 1.0 (LE u16), `01 02` → 2.1 (pair-swapped), 2.x → 2.1, anything else undefined → Rev 0 rules. `SegyFile.revision` holds it, and every gate uses it. The reader warns once if Ext1 is not named `SEG00001`. IBM → float64 is now exact (`ibmToFloat64`). Writer: checks the extended/trailer counts against the records, firstTraceOffset, per-trace ns vs header/Ext1/fixed flag, extra-header shape and name, and numTraces at `close`; pair-swapped Rev 0/1 output is refused and little-endian Rev 0/1 output warns (owner to decide); `encode` saturates `maxAddlTraceHeaders` instead of asserting. Raw trace walk: ~1.1 GB/s (`-d:danger`, warm cache). **Next: task 3.4** once the owner answers the two open questions above.
- 2026-11-07: Task 3.4a done. Owner decision: any file must be writable as it was read. The writer has two classes: (1) output a reader would misdecode (count/size mismatches, undefined format, pair-swapped Rev 0/1, u16 overflow) is refused unless `lenient`; (2) spec-invalid but readable values are judged **per field**: `validate` runs at error level, and each finding is downgraded to a warning when that field's bytes equal the bytes as read (`SegyFile.binaryAsRead`, kept by the reader). Little-endian Rev 0/1 output and a missing EndText are warnings when the file came that way (`wasRead`, `isExtendedAsRead` hash), errors for new content. So Sweep0 writes back byte-identically with one warning, while converting a clean BE Rev 0 file to LE needs `lenient`. **Next: 3.4b (User Data).**
- 2026-11-07: Task 3.4b done. `segy/exttext` is now a streaming state machine. Positions are stream offsets; record bytes are kept up to `maxRetained` (reader default 256 MB, `openSegy`/`readSegy(maxRetained)`), and beyond that everything is indexed only (`isComplete` false, info diagnostic). User Data stanzas (`SEG:USERDATA*`/`SEG:USERHEADER*`) are walked as `<segydescblock>` chains by `blocksize`: attachment bytes are never scanned, a description block split across records is carried over (max 64 KB), and the chain ends at zero padding, a new stanza, or the declared BYTES. Each attachment is a `UserDataBlock` (all D-9 tags, stream offset, and the file offset `mediumOffset` when read from disk). `userDataBytes` returns retained bytes; `reader.extractUserData(path, block, dest)` copies from disk in 4 MB chunks. Walker problems become `issues` and then warnings. `addUserData`/`toDescXml` build stanzas for writers; the writer refuses partially retained headers. Reader fixes this needed: with count -1, a record that continues a User Data chain is accepted even if binary; the trailer's first record is recognized by `startsStanzaRecord` (header + text, a parseable desc block, or declared BYTES). Fixture note: plain text in a `SEG:UserData` stanza is now (correctly) reported as malformed. Tests: `tests/tsegyuserdata.nim` (extended and trailer, count -1/N, trap-filled binary blobs, a split desc block, the spec's line-break style, malformed desc, retention + disk extraction, a 5 GB declared block in a 30 KB file, tape image). **Next: 3.4c (Ext1 decode).**
- 2026-11-07: Task 3.4c done. `SegyTraceHeaderExt1` (all 240 bytes via `{.at:}`, tiling-tested) with `LastIn*` flag constants and `initTraceHeaderExt1` (named `SEG00001`). `SegyTrace` now has `hasExt1`/`ext1` (decoded) and `proprietary` (raw blocks after Ext1, `headerBlockName` gives each name), replacing raw `extraHeaders`. The writer re-encodes Ext1 in the output byte order, so Rev 2 files with Ext1 convert BE→LE→pair→BE byte-identically. Proprietary blocks have no known layout, so changing their byte order is refused unless lenient (they are then copied unchanged); 3.4d can lift this when Layout XML describes them. Writer checks use the decoded Ext1 (name, numAddlTraceHeaders vs blocks carried). **Next: 3.4d (Layout XML).**
- 2026-11-07: Task 3.4d done, so **task 3.4 and Phase 3 (SEG-Y) are complete**. `segy/layout`: `TraceLayout`/`LayoutEntry` with all D-8 types, `parseLayout` (std/xmlparser; malformed input raises ValueError and the reader turns it into a warning plus the standard layout), `standardLayout(rev)` generated from the spec's Fig. 3 (112 entries; Rev 1 drops Ext1, Rev 0 keeps bytes 1-179 with times unscaled; ns/dt u16), and `merge`: file entries win by name, and standard entries whose bytes the file reuses for another name are dropped (Inglewood's CDP X at 73 removes `sht_x`). `inline` is accepted as `iline`. `SegyFile.layout` is set by the reader; `layoutOf` serves files built in memory. `segy/fields`: `fieldValue(file, trace, name)` and `geometry(file, trace)` (common values, NaN when absent). The last applicable entry wins, if-non-zero Ext1 entries override only when non-zero, scalars are applied (co/ed/tm/sp_scal, scale6), and proprietary extensions are found by header name. Verified on Inglewood: inline 1001, crossline 1..200, CDP X/Y and elevation from the stanza's bytes, source X/Y NaN. Not done: byte-order conversion of proprietary blocks that a Layout stanza fully describes (still refused unless lenient). **Next: Phase 4, task 4.1 (SEG-D Rev 2.0 headers).** Consider an independent review of 3.4 first.
- 2026-11-07: Task 4.1 done. `common/fieldlayout` gained SEG-D field kinds: `bcdAt`/`bcdAtL` (BCD from the high/low nibble; `BcdAllF` = -1 for the all-F sentinel, `BcdInvalid` = -2 for non-decimal nibbles), `nibAt`/`nibAtL` (binary nibbles), `at24` (3-byte ints), `fix40` (`i24.u16`) and `fix24` (`u16.u8`) as float64, which is exact. `fieldTable` reports nibble positions, and `encodeChanged` writes only the fields that differ from the bytes already in the buffer. `segd/headers`: GH1, GH2 (with the 2.1 line sequence number, raw in 2.0), GH#N, CSD (MP via `mpFactor`/`mpFactor=`), Demux Trace Header, THE#1, General Trailer, plus Storage Unit Label (`isStorageUnitLabel` = `SD\d.\d` at 5-9). Every block keeps `raw`, so unedited blocks re-encode byte for byte, including invalid BCD and X bytes. Resolved accessors cover file number, channel sets, EC/EX counts, record length ms, sample interval, receiver line/point. Tests (`tests/tsegdheaders.nim`): nibble-level tiling of all 7 blocks, every 63.sgd value from the verified walk, an edit touching only its nibbles (julianDay shares byte 12 with a binary nibble), invalid BCD preserved, fixed point (-1.5 = `FF FF FE 80 00`), MP sign-magnitude. Gotcha: a pragma named `bcd` clashes with `common/bcd.bcd`, hence the `*At` names. The 3.4 review subagent is running concurrently. **Next: 4.2 (sample formats).**
- 2026-11-07: Task 4.2 done. `segd/samples`: decode/encode for 8015, 8022, 8024, 8036, 8038, 8042, 8044, 8048, 8058, plus 8080 (Rev 3), into float32/float64 buffers. One's-complement fractions follow the spec (8015/8022/8024; negative zero reads 0), with an 8015 two's-complement option for field systems that write it that way. Encoders choose the smallest exponent (most precision), clamp at full scale, round integers and refuse out-of-range values or NaN (except IEEE); 8048 rounds the IBM 24-bit fraction to 23 bits. `toSegdFormat` rejects multiplexed and undefined codes (readers keep those traces raw). `model/tensors` overloads `decodeTrace`/`encodeTrace` on `SegdSampleFormat`. Tests: hand-built bit patterns for every format, exact round trips, quantization idempotence on random values with per-format worst-case error bounds, refusals, and 63.sgd's 1000 samples byte-identical. Removed probe files a review subagent left in 5263999. **Next: fix the 3.4 review findings, then 4.3.**
- 2026-11-07: Independent review of 3.4 found 12 issues; all fixed, with regression tests in `tests/tsegyreview2.nim` (one block per finding). (1) `parseXml` raised a **RangeDefect** on out-of-range character references (`&#99999999999;`), which no error boundary catches; `checkCharRefs` now rejects them first, and Layout stanzas over 1 MB are ignored with a warning. (2) The writer checks `binary.formatCode` against `format`. (3) It refuses a trace after one flagged last-in-file, and an EndText that is not the last extended record. (4) Count mismatches (extended, firstTraceOffset, trailer, numTraces) are as-read warnings when the relevant bytes are unchanged (trailer hash added: `isTrailerAsRead`). (5) Class-2 findings depend on **all** the bytes involved (revision always; ns/dt plus their Rev 2 extended fields; LE output checks the revision too) via `unchanged(ranges)`. (6) `ExtendedTextHeader.finish` sets `UserDataBlock.available` and reports blocks that overrun the records or run into a final EndText; `userDataBytes`/`extractUserData` refuse such blocks. (7) On disk the file size bounds binary lengths (`streamLimit`): longer BYTES/blocksize are reported and not skipped, and an unterminated description block no longer swallows binary records. (8) Scalars that do not fit int16 are ignored, not wrapped. (10) A trailer's first record no longer needs `<blocksize>`. (11) Extension names are matched case-insensitively. Residual risk: on tape (size unknown), a corrupt huge BYTES with count -1 still reads to the end of the tape file.
- 2026-11-07: Tasks 4.3 and 4.4 done. `io/pushback` (PushbackInput: look-ahead/unread, bounded chunked `readInto`, `skip`, `skipRecordRest`) is reusable; the SEG-Y reader keeps its own copy for now. `segd/reader`: `openSegd` (label auto-detected, its own tape block, FIXREC aware), `nextRecord` (tape marks between records skipped; GH1/GH2/GH#N, scan types with CSDs and skew, EC/EX raw; Rev 3 records and undefined/multiplexed formats stop the read), `readTrace` (sized from header byte 10 + THE#1, or the CSD's (TE−TF)/SI; the general trailer after the last trace; FIXREC padding skipped by block size on disk, rest of block on tape), `decodeInto`, `readSegd`. Known real-file quirks (source set 0, array forming 0) are **info**. `segd/writer`: RECORD (headers / each trace / trailer as blocks) or FIXREC (fixed blocks, zero-padded), optional tape mark per record, EOD; refuses count/size/extension/format mismatches unless lenient. New `SegUnlocatableError` + `raiseUnlocatable(code)`: "the rest cannot be located" is now **fatal** with a specific code (before, it was logged as error). SEG-D names that clashed with SEG-Y in the umbrella were prefixed (`SegdTraceHeaderSize`, `segd*Fields`). Verified: **63.sgd round-trips byte-identically** (disk) and through a tape image; synthetic streams in all 10 formats round-trip byte-identically; RECORD tape layout is exactly label + per record (headers, 5 traces, trailer, mark); FIXREC blocks are all 4096 bytes on tape and disk; damaged input (truncation in record 2, Rev 3, format 0058) stops with one fatal entry. **Next: 4.5 (vendor registry + NIF vendor maps).**
- 2026-11-07: Task 4.5 done, so **Phase 4 (SEG-D Rev 2) is complete**. `vendor/maps`: the NIF loader reads through the toolchain `nifreader` into a small tree (`;` comments stripped first; `0xB0` arrives as `0` + `xB0` and `4n` as `4` + `n`, both recombined; hex also works as a string or tag). It compiles to flat `FieldPlan`/`RepeatPlan` tables. Supported: encodings u8-u64, i8-i64, u24/i24, f32/f64, ibm32, bcd (nibble-addressed, `(nibble low)`), fixedpt i24.u16, ascii/ebcdic (`trim`), raw; attributes byteOrder, scale/offset, unit, enum, bits, sentinel; `repeat` with fixed or `(ref field)` count, bounded by the area. `(when ...)` is rejected as not supported yet. `checkVendorMap` reports overlaps. `VendorRegistry`: `loadVendorMaps(paths, log)` (bad maps → `dcVendorMap` warning and skipped), `vendorSearchPath` (repo `vendormaps/` + `PARSESEGD_VENDOR_PATH`), `registerVendorDecoder` (code decoders beat maps), `decode` (the most specific matching map; ties warn; fields beyond the area → warnings). A target without `(blockIndex)` means the whole area. `vendor/apply`: `segdContext`/`segyContext` and `decodeVendorAreas` for SEG-D records (EC/EX whole + per block, GH#3+, trailer) and traces (extensions #2+), and for SEG-Y files (binary header bytes, stanzas) and traces (header bytes, proprietary blocks by name). SEG-D 3.x `block` targets are matched by type byte once Phase 5 hands them over. Reference map: `tests/vendormaps/example.nif`. Tests (`tests/tvendormaps.nim`) also decode real 63.sgd Geo Space blocks and Inglewood trace bytes. **Next: independent review of Phase 4, then Phase 5 (SEG-D Rev 3.0).**
- 2026-11-07: Independent review of Phase 4 found 13 issues plus 1 spec ambiguity (now an open question). All fixed with regression tests in `tsegdreader`, `tsegdsamples` and `tvendormaps` (the "review"/"r<N>" blocks). (1) The toolchain `nifreader` can `quit` or assert on hostile tokens (`a@zzz…`, `~x`, `a.`, bad floats) and recursion overflowed on deep nesting. Vendor maps now use a dedicated **iterative tokenizer** (≤ 1 MB, depth ≤ 64, overflow-checked numbers, ValueError only) that also handles `0xB0`, `4n` and `;` natively. (2) `(at)`, `(len)`, counts, strides and indices are bounded to 1e6; hex overflow is an error. (3) SEG-D reader: scan types × channel sets ≤ 65535 (else fatal), and `note` logs at most 5 diagnostics per (field, severity) per stream, then one summary. (4, 5) The writer writes the label from its fields (`SegdStorageUnitLabel.encoded`: raw when unchanged), FIXREC block size must be 128 B..256 MB, and a non-`SDn.n` revision is refused. (6) The writer recomputes the trace count from the descriptors and checks `gh2.revisionMajor`. (7) The 8048 rounding carry at exponent 0x7F clamps to full scale. (8) 8042/8044 never emit the invalid all-ones code. (9) A negative sample count (TE < TF) is fatal. (10) Vendor sentinels compare raw bit patterns (an i24 sentinel 0xFFFFFF matches -1); a negative `(ref)` count is reported as such. (11) The writer refuses a GH1 that reads like a label. (12) fix40/fix24 round to the nearest representable value; BCD encode checks before writing (no partial writes). (13) Vendor revisions are (major, minor) pairs, so 2.10 ≠ 3.0. **Next: Phase 5 (SEG-D Rev 3.0).**
- 2026-11-07: Owner decision on FIXREC ("assume padding"): a trace that fits in a block never crosses a block boundary; the writer zero-pads the rest of the block, and the reader skips zero padding where a trace header should start (an all-zero header is impossible: scan type 0). Files cut at arbitrary points stay readable. Test: `fixrec_traces_do_not_cross_blocks`.
- 2026-11-07: Task 5.1 done. `segd/rev3`: typed blocks via the `{.at:}`/`at24`/`fix40`/`nibAt` pragmas, each keeping `raw` (`decodeRev3`/`encode`): GH#2 (Rev 3 layout), GH#3, the 96-byte CSD, THE#1 (Rev 3), Position (96 bytes), Source Description (common fields + type-specific accessors), Additional Source Info, Sensor Info, Timestamp, Sensor Calibration, Time Drift, Orientation, Trailer Description. All are nibble-tiling-tested. Other blocks stay raw 32-byte blocks: `blocks` iterator, `findBlock`, `blockTypeName` (0x1A accepted as Additional Source Info), `blockText`, `crsText`. GH#1 and the demux header are shared with Rev 2. Resolved accessors: counts with GH#2 alternatives, base scan interval µs, record length µs, extended trace number, receiver line/point. Timestamps: `timestampToUnix`/`unixToTimestamp`/`gpsMinusUtc` with a compile-time leap-second table (spec to 2014, plus 2015-06-30 and 2016-12-31; pure civil-date math, since `std/times` constructors are side-effecting), and `generalHeaderUtc`. TOC: `isTocFile`, `tocEntryCount`, `decodeToc`. Verified on the real 65 MB file (skipped when absent): GH1-3 values, sizes 4544/65,057,624, GH#1 UTC = floor(GH#3 GPS µs − 18 s), text/CRS/position/explosive blocks, CS4 = 3954 traces, 4001 samples, DSM 1000, THE 13. **Next: 5.2 (Rev 3 reader).**
- 2026-11-07: Task 5.2 done. The SEG-D reader handles Rev 3 in the same `SegdRecord`/`SegdTrace` (one model for every revision): `isRev3`, `gh2r3`, `gh3`, `generalBlocks` (raw optional GH blocks), `descriptors3`, `trailerBytes`, `ext1r3`; trace extensions after THE#1 stay raw (`extensions`, typed via `blocks`/`decodeRev3`). Rev 3 is detected from GH#2 bytes 11-12 and the GH#2 bytes are re-decoded with the Rev 3 layout. The first trace and the first trailer block are aligned to a device block (new tape block / FIXREC boundary). Each trace's channel set comes from its own header (u16 CS numbers); samples come from THE#1, with a CSD cross-check unless ERM. The trailer is read by GH#2 count, else GH#3 recordSize − dataSize, else description-block groups. GH#3 headerSize is checked against the blocks; undefined block types warn. TOC files between records are decoded into `reader.toc`. Verified on the real 65 MB file (local only; skipped in CI): 3957 traces in physical order CS1, CS3, CS2, CS4, FFFFFF receiver sentinels resolved via the extended fields (100.0/101.0 … 225.0), 9 user blocks per trace, samples equal the Python oracle, **0 diagnostics**, ~37 ms in danger builds. **Next: 5.3 (Rev 3 writer).**
- 2026-11-07: Task 5.3 done. The SEG-D writer handles Rev 3 records (`isRev3`). It writes GH1, the Rev 3 GH#2 and GH#3, the raw optional blocks, the 96-byte CSDs, skew, EC and EX, then traces with the Rev 3 THE#1 and the raw `trailerBytes`. The first trace and the first trailer block start a device block (RECORD: own tape block; FIXREC: zero padding). It refuses count/size mismatches, including GH#3 header/data/record sizes against what is written, unless lenient. `computeRev3Sizes` fills GH#3 sizes and the GT count for records built in memory; `rev3HeaderBytes`. Reader fix found by the tape test: GH#3 headerSize is now checked against the blocks read, not medium offsets (tape images interleave record markers). Tests (`tests/tsegdrev3io.nim`): synthetic Rev 3 records (text/CRS/position/explosive/user GH blocks, aux + seismic channel sets written in reverse descriptor order, position blocks in trace extensions, a trace-edit trailer) in all 10 formats round-trip byte-identically on disk; RECORD tape with SD3.0 label and tape marks; FIXREC 4096/1000 on tape and disk with block-aligned record and trace starts; unknown GT count resolved via GH#3 sizes and via the description walk; a TOC after the records; 6 writer refusals; and **the real 65 MB Rev 3.0 file rewrites byte-identically** (local only). **Next: 5.4 (commit a few-trace fixture of the real file).**
- 2026-11-07: Task 5.4 done, so **Phase 5 (SEG-D Rev 3.0) is complete**. Validation on the real file: read with 0 diagnostics, a byte-identical rewrite (5.3), and Python oracle agreement. The committed fixture `SEG Spec/exampleFiles/inova_rev30_5traces.sgd` (86,744 B) is generated by `tools/make_rev3_fixture.nim`; the oracle tiles it exactly, and it differs from the original prefix in exactly 10 bytes (GH#3 recordSize/dataSize, CS4 channelsInSet). Tests on it always run (`committed_rev3_fixture`). `vendor/apply` now hands Rev 3 blocks to the registry by type byte (`block` targets, `where generalHeader|traceHeader`); tested by decoding INOVA 0xB0 and the explosive source block from the fixture. **Next: independent review of Phase 5, then Phase 6.**
- 2026-11-07: Independent review of Phase 5 found 7 issues plus minor ones; all fixed, with regression tests (`tsegdrev3io` "r<N>" blocks, the Rev 2 gap sweep in `tsegdreader`, and `tvendormaps`). (1) FIXREC: a padding gap under 20 bytes was read as a trace header (a strict write was misread). Writers never start a trace header in a block's last 19 bytes; the reader peeks only up to the block boundary (`remainingInRecord` on tape; offset mod block size on disk) and takes zeros to the boundary, or 20 zeros, as padding. A sweep over every gap size 1..19 covers Rev 2 and Rev 3, disk and tape. (2) A trailer size from GH#3 overflowing int64 raised a RangeDefect; sizes now stay u64 with an explicit bound (writer too). (3) Trace channel sets now resolve the extended number (demux bytes 16-17 when byte 4 is FF), Rev 2 and Rev 3. (4) Trailer walk: a description block also needs byte 2 ∈ {1, 2} and bytes 3-4 zero (a following GH#1 with EX = 70 is no longer taken). The writer refuses an unknown GT count without a GH#3 record size unless the trailer is walkable. (5) Memory: header areas (EC/EX), trailers and TOC entries above `maxHeaderBytes` (256 MB) are skipped, with `record.incomplete` and an info diagnostic; the writer refuses incomplete records. A trace above `maxTraceBytes` (2 GB) is fatal. (6) Rev 3.1 now warns ("read as 3.0"). (7) Vendor maps: Position blocks are offered as 96 bytes; Rev 3 trailer groups are offered as `trailer` targets by trailer block type. Minor: `generalHeaderUtc` range-checks the fields; FIXREC padding is skipped after a TOC on disk. **Next: Phase 6 (data model for viewers and HPC).**
- 2026-11-07: Tasks 6.1 and 6.5 done. `RecordSource.seekForward` (a base method returning -1 = cannot seek; disk and memory-map sources seek) plus `RecordCursor.skip`/`PushbackInput.skip`/`skipExactly`: byte streams skip without reading; tape reads and discards and stops at tape marks. `io/memsource`: `MemFileSource` (std/memfiles, 64 KB chunks so a walk does not copy the samples it skips, `memory` for zero-copy access, empty files map nothing). Both readers take `headersOnly` (`openSegy`/`openSegd`, `readSegy`/`readSegd`, and `readSegyHeaders`/`readSegdHeaders`): samples are skipped, a trace cut short is still fatal, and `decodeInto` refuses a header-only trace. `model/traceindex`: `TraceEntry` (24 B: offset, headerBytes, numSamples, record, channel set, scan type, channel type), `TraceCodec` per SEG-Y file or SEG-D record, `buildIndex(src, kind)` on any source (`contiguous` is false for tape), `detectKind` (a SEG-Y `C` must also have a defined format code, so a SEG-D GH1 with file number 43xx stays SEG-D), `openSeismic(path)` (map + index), `readTraces`/`readTracesInto` (decode from the map into the tensor; an undecodable trace is zeroed and logged), and `decodeEntry` (touches no managed memory, for the prefetch thread). On all 5 sample files the index and range reads equal the full readers, with the same diagnostics (`tests/ttraceindex.nim`).
