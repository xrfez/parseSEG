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
  - an entry holds severity (info/warning/error/fatal), a code, the byte offset, the
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

## Architecture (target)
```
src/parseSEGD.nim                # umbrella module, re-exports public API
src/parseSEGD/
  common/
    endians.nim     # big-endian get/put (u8..u64, i8..i64, 24-bit), plus LE variants (task 3.2)
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
- [ ] 2.3 Diagnostics: `Diagnostic`/`DiagLog`, the severity and code catalog, **NIF** serialization
      (+ a NIF reader for round-trip tests), the exception→diagnostic boundary helper. Add
      `--path:"$nim/dist/nimony/src/lib"` to `config.nims` and `tests/config.nims`.
- [ ] 2.2 I/O layer: the record source/sink interface (records + tape marks); disk-file,
      tape-image and memory backends; Linux `st` and Windows tape backends (build-gated with
      `when defined(linux/windows)`; test with a mock device and tape images)

### Phase 3: SEG-Y (Rev 0/1 first, then 2.1)
- [ ] 3.1 Textual, binary, and trace headers (decode/encode, round-trip tests)
- [ ] 3.2 Sample formats 1,2,3,5,8 into Tensors; byte-order and ASCII/EBCDIC detection;
      extended textual headers; the `byteOrder` write option
- [ ] 3.3 Validate against `Sweep0.sgy` (Rev 0, LE) and Inglewood (Rev 2.1 subset)
- [ ] 3.4 Rev 2.1 extensions (byte-order marker, ext. fields, extra trace headers, trailer, formats)

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

### Phase 7: Tooling
- [ ] 7.1 CLI: `parseSEGD info|dump|convert|diag` (diag prints the NIF log)
- [ ] 7.1b CLI: `parseSEGD vendormap check|scaffold|apply|list`. `scaffold` emits a skeleton
      `.nif` map for every unmapped vendor area (e.g. the 9 INOVA blocks 0xB0-0xB8 in the 3.0
      sample, and the 3 Geo Space extended blocks in `63.sgd`)
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
- 2026-11-07: Task 2.0 done. Arraymancer 0.7.33 builds and runs on Nim 2.4 (debug and `-d:danger`) under `--noNimblePath`. `import arraymancer/tensor` needs only `nimblas` at compile time, and no system BLAS is linked or installed (BLAS loads only if matmul is called). Writing raw buffers via `unsafe_raw_offset` works (`tests/ttensor.nim`). `nimble setup` generates `nimble.paths` (machine-specific, now gitignored and untracked) and `config.nims` includes it; tests pick it up through the root config. A fresh clone needs `nimble install -d && nimble setup`. **Next: task 2.3.**
