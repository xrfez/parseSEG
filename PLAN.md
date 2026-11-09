# parseSEG: master plan and checkpoint log

> **Resuming in a new session? Read this file first, then follow "Resume protocol".**

## Handoff (2026-11-09, end of Phase 14) — start here
- **Branch state:** Phase 14 is complete, and `main` was fast-forwarded to `seg-library` (13.5).
  Both point at the same commit. Nothing is pushed: push only if the owner asks.
- **What parseSEG is now:** a Nim-only library (0.5.0), plus the `parseSEG` CLI.
  - 14.1 removed the C ABI and Python module.
  - 14.2 removed the API shapes the FFI forced (see `docs/design/phase14_audit.md`).
  - 14.3 added bulk header columns and keys on demand, sample windows, `textHeader`,
    `sortTraces`, `openEditor(f)`/`release`, `SeismicWriter`, a progress/cancel hook, the
    index cache (`saveIndex`, `openSeismic(cache = ...)`) and prefetch recycling.
  - `docs/benchmarks.md` has a Phase 14 re-run section.
- **Suite:** `TMPDIR=/tmp/pl nim test` (47 test files). Check both the exit code and the
  line "All test files completed".
- **Gotchas:**
  - **Short TMPDIR:** `theadernif` `failed_journal_syncs` fails under a long TMPDIR.
  - **Map refs on shared read paths:** never copy `f.map`/`f.map.src` into a local. ORC
    counts are not atomic, and threads share files (`tests/tsharedreads.nim`).
  - **Commits:** commit as a separate command after checking the suite. A commit on the
    line after a heredoc runs even when the check before it failed.
  - **Known leak:** ASan reports a 32 KB leak in 2 allocations in the prefetcher tests. It
    predates Phase 14 (Nim thread runtime) and has not been investigated.
  - **Parallel agents:** they need their own worktree, `XDG_CACHE_HOME` and a short
    `TMPDIR`. Phase 14.3 ran one agent at a time on the main checkout instead.
- **Open (from the 14.3 logs):**
  - the SEG-D writer cannot change sample counts and refuses multiplexed input;
  - the full-scale bench (`PARSESEG_BENCH_SCALE=full`) was not re-run;
  - "Open questions for the owner" below still stand.
- **Next:** nothing is scheduled after Phase 14. Ask the owner (candidates: Phase 11.3 needs
  a real SEG-2 file; "Future").

## Goal
An idiomatic, high-performance Nim library to **read and write** SEG seismic data on **disk and
tape**, designed to back a future high-performance viewer and HPC processing. Priority formats:
1. **SEG-D Rev 2.0** (the owner's most important format; see `63.sgd`)
2. SEG-Y Rev 1.0 (plus Rev 0, which it is a superset of)
3. SEG-D Rev 2.1 and 3.0
4. SEG-Y Rev 2.1

**Long-term goal: spec out and support every revision of both standards** (SEG-Y 0/1/2.0/2.1,
SEG-D 0/1/2.0/2.1/3.0/3.1), plus **SEG-2** and the survey (positioning) formats.
Standalone spec PDFs exist for SEG-Y **0** (1975)/1.0/2.0/2.1, SEG-D **0** (the original
standard)/**2.0**/2.1/3.0/3.1, SEG-2 (1990), SPS (1993 original and Rev 2.1) and SEG P1/P2/P3
(1983); all added by the owner on 2026-11-07 except where earlier. SEG-D Rev 1 is known only
from the history sections of the later documents.
- **SEG-2** (owner, 2026-11-07): seen internally on Geospace systems; PC-oriented, usually
  little-endian, keyword strings in the headers.

## Owner decisions (2026-11-07, revised)
- **Nim library only (owner, 2026-11-09).** No C ABI, no Python module, no FFI-driven design.
  This supersedes the Phase 8 / 12.5 boundary decisions below. API shape, naming and types follow
  idiomatic Nim and performance alone. Stay lean: add a feature only when the viewer or the
  processing library needs it.
- **One data model, many revisions.** The revision is always identified from the headers
  (SEG-Y bytes 3501-3502; SEG-D GH2 bytes 11-12), so readers dispatch on it.
  - SEG-Y uses **one** `SegyFile` type for Rev 0-2.1, where revision-specific fields are optional.
  - SEG-D uses **one** `SegdRecord` type for Rev 1-3.1, whose optional blocks are variant
    objects keyed by block type.
  - An auto-detecting `openSeismic(path)` covers both standards.
- **Files change only on an explicit write (owner, 2026-11-07).** Opening, indexing,
  joining survey geometry (`applySurvey`/`applyGeometry`) and every other read-side call work
  on in-memory state only, and files are mapped read-only. Bytes on disk change only through
  a call whose purpose is writing: the writers (`writeSegy`, `writeSegd`, `writeSps`,
  `writeP1`, `convertFile`) or the journaled `HeaderEditor` (`openSeismic(writable = true)`).
  New APIs follow this rule; persisting derived data is always a separate, named call.
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
src/parseSEG.nim                # umbrella module, re-exports public API
src/parseSEG/
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
  model/  tensors.nim (Arraymancer views), traceindex.nim, keys.nim (per-trace geometry), gathers.nim (gather type,
          component groups), prefetch.nim (threaded read-ahead), edit.nim (in-place edits + NIF journal)
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
- [x] 1.7 `segd_rev3_1_delta.md` (also check 3.1 for new sensor types, e.g. rotational)
- [x] 1.8 The remaining revisions: `segy_rev2_0_delta.md` (SEG-Y 2.0 vs 2.1), `segy_rev0.md` and
      `segd_rev0.md` from the original 1975 standards (owner PDFs, 2026-11-07), each with a gap
      analysis against the current readers. SEG-D Rev 1 stays known only from history sections.
- [x] 1.9 `seg2.md` (SEG-2, 1990), `sps.md` (SPS 1993 + Rev 2.1), `p1_p2_p3.md` (SEG 1983
      positional exchange formats). New PDFs extracted to `SEG Spec/text/` (`SEG-Y Rev 0` had no
      extension; renamed to `SEG-Y Rev 0.pdf`).

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

- [x] 3.5 Older and in-between revisions from the 1.8 gap analyses: SEG-Y Rev 0 (1975) and Rev 2.0
      files read (and write) correctly; tests with synthetic files

### Phase 4: SEG-D Rev 2.0 / 2.1 (2.0 first)
- [x] 4.1 Headers (GH1/GH2/GH#N, CSD, skew, extended, external, demux trace header, THE)
- [x] 4.2 Sample formats (all 2.x demux codes) into Tensors; multiplexed codes → diagnostic + raw
- [x] 4.3 Writer and round-trip tests with synthetic records (disk and tape image)
- [x] 4.4 Validate against `63.sgd`: a byte-identical read→write round trip
- [x] 4.5 Vendor registry + **NIF vendor-map engine** (`docs/design/vendor_maps.md`): map loader
      and validator, matcher, compiled field tables, `VendorBlock` values, code-decoder
      precedence. Test with a hand-written example map against synthetic blocks.

- [x] 4.6 SEG-D Rev 0 (the original standard) from the 1.8 gap analysis: revision detection
      without a GH#2 revision, Rev 0 header fields and sample formats; synthetic tests

- [x] 4.7 Multiplexed SEG-D (Rev 0/1/2 codes 0015-0058): scan walker (start-of-scan and timing
      words, GH1 bytes per scan and scans per block), the 0015 decoder, demultiplexing into
      traces. Large; from `segd_rev0.md` §5 and §9.

      **Default chosen by the agent (2026-11-07):** the owner had no preference, so revisit it
      if a real multiplexed file shows a problem. The choice is option (a): demultiplex once on
      open.
      - `openSeismic` detects multiplexed records and demultiplexes them into a temporary
        demux SEG-D file. The headers are kept, and the format becomes the demux equivalent
        (0015→8015, 0022→8022, ...).
      - The temp file goes in a configurable directory (default: the OS temp dir). It is
        deleted on `close`.
      - The original file is never modified; the read-only rule holds.
      - Every existing feature (index, range reads, keys, gathers, survey join, conversion)
        then works unchanged.
      - A warning diagnostic says the data was demultiplexed, and where the copy lives.

      Why this option:
      - Multiplexed data is legacy, tape-era data, so files are small and the copy is cheap.
      - Option (b), a scan-strided codec, would add a second read path for every feature.
      - Option (c), streaming only, would leave viewers without random access.

      Known costs: one extra copy on disk, and in-place header edits apply to the copy, not
      the original. The editor refuses multiplexed files and points to `convert` instead.

### Phase 5: SEG-D Rev 3.0
- [x] 5.1 Storage unit label, TOC, general headers 1-3 and all optional/typed blocks
- [x] 5.2 Trace headers and typed extensions (incl. Orientation 0x60), trailer, reader
      (resolve each trace's channel set from its own header)
- [x] 5.3 Writer and round-trip tests
- [x] 5.4 Validate against `00000151_12900_11300.sgd` (local only), then write a few-trace copy
      with all headers to `SEG Spec/exampleFiles/` and commit it as a permanent fixture

- [x] 5.5 SEG-D Rev 3.1 from the 1.7 delta: revision handling and any new or changed blocks

### Phase 6: Data model for viewers and HPC
- [x] 6.1 Trace index (header-only walk) and range reads into Tensor slices, memfiles backend
- [x] 6.2 Gather-type detection (shot/receiver/other) and multi-component grouping (`componentGroups`)
- [x] 6.3 Prefetch thread with a bounded queue (non-blocking API for a viewer)
- [x] 6.4 Benchmarks on the 65 MB sample (decode throughput, index build time)
- [x] 6.5 Headers-only API (`readHeaders`): every header, samples skipped, for disk and tape
- [x] 6.6 In-place header edits: memmap read-write, field-level encode with validation, NIF
      undo journal (apply/rollback), refuse size-changing edits; tests on synthetic SEG-Y/SEG-D
- [x] 6.7 Large-file test: a sparse synthetic file larger than 4 GB (index build, a range read
      near the end, an in-place edit near the end) to prove 64-bit offsets work
- [x] 6.8 Format-independent file summary (owner, 2026-11-07), so that a viewer or processing
      job never branches on `f.kind` or the revision for common metadata. `FileSummary`
      (`f.summary`):
      - standard and revision;
      - sample interval and record length (when uniform, else per channel set / NaN);
      - trace count, record count, and first/last field record;
      - coordinate units (SEG-Y binary 3255-3256 / trace bytes 89-90; SEG-D Rev 3 CRS) and
        CRS text when present (`crsFormat`);
      - byte order and sample format(s).

      Exposed through the C ABI (`seg_file_summary`), Python (`summary()`) and `info`.
- [x] 6.9 Trace time in `TraceKeys` (`time`: UTC seconds as float64, NaN if unknown):
      - SEG-Y: trace bytes 157-170 (year/day/h/m/s, time basis code);
      - SEG-D Rev 1/2: GH1 date/time;
      - SEG-D Rev 3: the GH UTC time stamp and per-trace THE time when present.

      Update `SegTraceKeys` in the C ABI (append the field, keeping the ABI version rules) and
      `trace_keys` in Python.
- [x] 6.10 Header listing for a viewer's headers tab (owner, 2026-11-07). One call per scope
      returns every header of trace `i` / record `r` / the file as ordered rows:
      - API: `traceHeaders(f, i)`, `recordHeaders(f, r)`, `fileHeaders(f)`.
      - Row contents: (block, field, value, byte offset, size), with a block's raw bytes
        available for a hex pane via `copyBytes`.
      - Covers whatever blocks that trace actually has in its format and revision: SEG-Y
        `trace`/`ext1`; SEG-D `trace`/`ext1`/Rev 3 extension blocks; `gh1`/`gh3`/... per record.
      - Exposure: Python (list of dicts, plus `field_names(block)`), C ABI (an iterator), and
        CLI `dump`.

      Owner rule: **the listing is read-only.** A viewer never edits the file. Edits made in a
      viewer are collected in memory as a pending change set and saved as a NIF patch (the
      `exportHeaders` format). Applying one is a separate explicit action: `importHeaders`
      with `dryRun` first, preferably with `outPath` (a copy). Add a helper that writes a
      change set as a NIF patch (`writeHeaderPatch(changes, path)`), so viewers do not build NIF
      by hand. Values in the rows use the same field names as `HeaderEditor` and NIF.

### Phase 8: Embeddable library (Nim import, C ABI `.so`/`.dll`), done BEFORE Phase 7
(Owner decision, 2026-11-07: Phase 8 first, then Phase 7, whose CLI is built on Phase 8's API.
Direction: we *export* a C ABI for hosts to call. The nim-c-bindings/nim-c-wrappers skills cover
the opposite direction, Nim calling C libraries; consult them only for the C-side conventions.)
Goal: the internal model (Tensors, index, keys, gathers, prefetch, edits) is used by a future GUI
library and a processing library (filters, FFT, gains, geometry QC by linear moveout, brute
stacks), from Nim directly or through a shared library with a shipped, well-commented C header.
Tensors stay the internal representation; only the boundary changes.
Findings of a probe (2026-11-07, `--app:lib --noMain --header`, Nim 2.4):
- It builds as-is: Nim generates the header with `NimMain` declared, and the library must be
  initialized by calling it once.
- Plain objects (only scalars/arrays, e.g. `TraceEntry`) become real C structs with their fields;
  names are mangled unless the type has `{.exportc: "SegTraceEntry".}`.
- Objects holding `seq`/`ref`/`string` (`Tensor`, `SeismicFile`, `TraceIndex`) are emitted only as
  forward declarations; returned by value they cannot even be called from C. They cross as
  pointers/opaque handles with accessor procs.
- `Tensor[T]` is a 128-byte struct (shape and strides `array[6, int]`, offset, a `ref` to storage
  holding `raw_buffer`). The data crosses zero-copy like a numpy array: export a view struct
  (data pointer, dtype, rank, shape, strides) plus a handle that keeps the tensor alive until
  released. DLPack (`DLManagedTensor`) is that exact contract and is imported by numpy and PyTorch
  without copying.
- The header includes `nimbase.h` from the compiler: ship it, or make the header self-contained.
Tasks:
- [x] 8.1 Research and decide the ABI: naming (`seg_*`), handles versus structs, a DLPack versus
      our own tensor view, how errors and diagnostics are reported (codes plus a NIF/struct log),
      ownership and release functions for every allocation, thread-safety rules (prefetch, one
      editor per file), NimMain/init and teardown, and ORC across the boundary
      (`--mm:orc`, `-d:useMalloc` when the host frees memory). Write `docs/design/c_abi.md`.
- [x] 8.2 Define the stable public Nim API (the umbrella exports too much); keep internals private.
      Include **trace selections**: `readTraces`/`readTracesInto` and the prefetcher also take a
      list of trace indices (`openArray[int32]`), not only a range, decoding rows in list order
      straight from the map. Gathers and component groups need this already, and it is the hook
      for sorting (see Future): a sort only produces such a list.
- [x] 8.3 Export layer (`src/parseSEG/capi.nim`): exportc procs over the public API, readable
      struct names, a documented header (generated, then commented or wrapped), version symbol.
- [x] 8.4 C test program (and a Python ctypes/numpy smoke test) against the shipped header and
      `.so`; CI builds the `.so`/`.dll`.
- [x] 8.5 Geometry for processing: coordinates for SEG-D (Rev 3 position blocks), offsets and
      midpoints from coordinates, and a hook to attach external geometry (filled by Phase 10).
- [x] 8.6 Cross-standard and cross-revision conversion as library procs (used by `convert`).
      Samples go through Tensors (decode, then encode in the target format). Headers go through
      documented mapping tables: SEG-D → SEG-Y (file number → field record, trace number →
      channel, ns/dt, receiver/source line, point and coordinates where SEG-Y has a field or a
      Layout entry), SEG-D Rev 2 ↔ Rev 3, and SEG-Y revision changes (the writer already does
      these). It is lossy by nature, so every dropped or approximated value is logged as a
      diagnostic, and raw blocks are kept where the target has room (SEG-Y extended text or
      User Data, SEG-D extended headers).
- [x] 8.7 (split from 8.6) SEG-D Rev 2 ↔ Rev 3 conversion. Build Rev 3 records (GH#2/GH#3
      sizes via `computeRev3Sizes`, 96-byte CSDs, Rev 3 THE#1, GH#N → Source Description
      blocks) and re-encode formats Rev 3 no longer defines. Rev 3 → Rev 2 drops typed blocks,
      and that is logged.
- [x] 8.8 Python bindings with **nimpy** (owner request, 2026-11-07): a native extension module
      (`parseseg.so` / `parseseg.pyd`, `import parseseg`), with nimpy added through Atlas.
  - One custom export pragma (e.g. `{.segExport.}`) marks every boundary proc. A define chooses
    what it expands to: `-d:segCapi` gives `exportc, dynlib, cdecl` (the `.so`/`.dll`/`.dylib`
    C ABI of 8.3), `-d:segPython` gives nimpy's `exportpy`. Without either it adds nothing, so
    plain Nim builds are unchanged. The C ABI and the Python module come from one source of
    truth.
  - Where the two need different shapes, keep thin per-target wrappers over shared
    implementation procs. C uses status codes, out-pointers and handles; Python uses
    exceptions, return values and objects with `close`/context managers.
  - Samples must reach numpy zero-copy, through nimpy's raw buffers, the buffer protocol or
    `__dlpack__`, since the tensors stay internal.
  - Test it with a pytest-free `python3 -I` script in `nim test`, mirroring
    `tests/python/smoke.py`, and with numpy whenever it is available.
- [x] 8.9 **Ongoing:** build tasks for every target, kept current whenever a target or flag
      changes. Tasks in `config.nims`:
  - `lib` (the C ABI for the host OS);
  - `libLinux` / `libWindows` / `libMacos` (cross-builds through the existing zig tasks,
    e.g. `zig cc -target x86_64-windows-gnu`);
  - `pylib` (the nimpy module);
  - `staticlib`: `--app:staticlib` gives `libparseseg.a` / `parseseg.lib` for static
    linking. Hosts link it with `-lpthread -lm -ldl` (Linux). Verified 2026-11-07: abi_test
    linked statically passes everything, with no runtime dependency on the `.so`;
  - `csources`: a C source bundle per target triple, for users who build without Nim (their own
    compiler, flags or build system). It uses `--compileOnly --genScript`; the generated `.c`
    files (82 files, 7.4 MB for linux-x64) plus `nimbase.h`, a small Makefile and CMakeLists.txt
    (compile every `.c`, archive) and `include/parseseg.h`. Verified 2026-11-07: built with gcc
    alone, abi_test passes. The generated C is target-specific (word size; OS code such as
    memfiles and tape), so ship one bundle per triple (linux-x64/arm64, windows-x64,
    macos-arm64), never one for all;
  - the CLI binary (Phase 7).

  Each task documents its flags (atomicArc, useMalloc, threads), and CI builds the matrix and
  uploads the artifacts with `include/parseseg.h`.
- Phase 7's CLI should be written against the 8.2 public API, so it doubles as an end-to-end test.
- Processing itself (filters, FFT, gains, LMO/NMO, stacks) is a separate library consuming this one.

### Phase 7: Tooling
- [x] 7.1 CLI: `parseSEG info|dump|convert|diag` (diag prints the NIF log)
- [x] 7.1b CLI: `parseSEG vendormap check|scaffold|apply|list`. `scaffold` emits a skeleton
      `.nif` map for every unmapped vendor area (e.g. the 9 INOVA blocks 0xB0-0xB8 in the 3.0
      sample, and the 3 Geo Space extended blocks in `63.sgd`)
- [x] 7.3 NIF header export/import: streamed export (fields + raw, or fields only); import as
      a patch (diff → in-place journaled edits, or rewrite with the original samples). CLI:
      `parseSEG headers|edit|export|import`
- [x] 7.2 Docs and CI updates

### Phase 9: Rename the project to parseSEG
- [x] 9.1 Renamed `parseSEGD` to `parseSEG` everywhere: package (`parseSEG.nimble`, `atlas.lock`),
      `src/parseSEG.nim` + `src/parseSEG/`, imports, docs, tests, tools, CI, the CLI binary
      (`bin/parseSEG`) and the vendor-map env var (`PARSESEG_VENDOR_PATH`). The C prefix (`seg_`),
      `include/parseseg.h`, `libparseseg.*` and the Python module `parseseg` already had the new
      name. Owner actions left: rename the working directory and the GitHub repository.

### Phase 10: Survey (positioning) files
Text formats, so no sample files are needed (owner, 2026-11-07; real samples will follow later).
- [x] 10.1 Specs ingested: SPS 1993 + Rev 2.1 and SEG P1/P2/P3 (1983) extracted and distilled
      (task 1.9). P1/90, P1/11 and SPS 3.0 are not available; add them if the owner finds them.
- [x] 10.2 Readers and writers into a survey model (`src/parseSEG/survey/`): SPS S/R/X + H
      records (both revisions, revision detected from the content), P1 (and P2/P3 records
      kept as typed or raw records), with diagnostics like the seismic readers; column-exact
      writers that round-trip; synthetic tests built from the spec examples.
- [x] 10.3 Join survey geometry to traces (the 8.5 hook): build a `GeometryTable` from SPS/P1;
      apply SPS X (relation) records to traces that lack receiver stations (field record +
      channel → receiver and source station), then fill `TraceKeys` coordinates, offsets and
      midpoints, especially for SEG-D 2.x, which has no coordinates in its headers. Exposed in
      the public API, C ABI, Python and the CLI (`info --sps`/`--p1`).
- [x] 10.4 Review by an agent; fix its findings.
- [x] 10.5 Explicit write-back of joined geometry (owner rule: files change only on an explicit
      write). `applySurvey` stays in memory. A separate, named call persists it:
      - `writeGeometry(editor, ix, fields)` through the journaled `HeaderEditor` (in place,
        same-size fields only, undoable);
      - or as part of `convertFile` into a new file.

      Targets:
      - SEG-Y: source/group X/Y with the coordinate scalar, elevations, line/point via the
        layout;
      - SEG-D Rev 1/2: THE#1 receiver line/point/index;
      - SEG-D Rev 3: THE#1, plus Position blocks only where they already exist.

      Fields with no slot in the target are reported, not dropped silently. Exposed in the C
      ABI, Python and the CLI (`survey-apply <file> --sps ... [-o out | --in-place]`); without
      `-o` or `--in-place` the CLI only reports what would change.

### Phase 11: SEG-2 (queued after Phase 10)
- [x] 11.1 `Seg2File` reader (descriptor blocks, keyword strings, formats 1-5, byte order),
      trace index and keys, `openSeismic` detection.
- [x] 11.2 Writer, conversion to and from SEG-Y / SEG-D, C ABI and Python, CLI.
- [ ] 11.3 Validate against a Geospace SEG-2 sample *(owner: please provide one)*.

### Phase 12: Idiomatic Nim pass (owner, 2026-11-07)
Go through the project and make it read like idiomatic Nim, guided by the nim-* skills
(style guide, API design, code organization, error handling, doc comments).
- [x] 12.1 Audit by an agent, module by module, against those skills. Output: a findings list
      in this file, ranked. Each finding is marked either:
      - internal: no API change;
      - public API change: needs owner approval, since it breaks callers.

      **Findings (2026-11-08).** Four read-only agents (common/io/abi, segy/convert,
      segd/vendor, model/survey/cli) did the audit. The high-impact claims were re-checked
      against the code. Ranked within each group. "C/Py" means the change also reaches the C ABI
      and the Python module (through the `segApi` names).

      **A. Bugs found by the audit (internal; fix first in 12.3)**
      - A1 (high) Accidental deep copy of the whole `TraceIndex`:
        - `headerfields.nim:329` `let ix = f.index` in `sampleIntervalUs` (`expandArc` shows
          `=copy`); the CLI (`cli.nim:269`) calls it once per trace.
        - The same copy at `headerfields.nim:188` (a `segdRecords[...]` copy on every
          record-field read) and `cli.nim:249,252`.
        - Fix: read through `f.index` directly, or bind with a `template`.
      - A2 `SegdSourceDescription` accessors (`rev3.nim:415-425`: `phaseAngle`, `vibratorType`,
        `phaseControl`, `depth`, `size`) read `s.raw`, not the decoded `typeSpecific15/28`
        fields, so they go stale after an edit. Use `beI16`, not `cast[int16](beU16 ...)`.
      - A3 Three version strings: `cli.nim:12` and `convert.nim:56` say 0.2.0, while
        `api.nim:27` and the nimble file say 0.3.0. Keep one const and derive the rest
        (`-d:NimblePkgVersion` with a fallback).
      - A4 `maps.nim:499`: the loader takes the *last* `(vendormap)` root, not the first.
      - A5 File handles leak on exceptions: `convert.nim:692` and `scaffold.nim:170`. Use
        `try/finally` or `defer`.
      - A6 `segy/writer.nim:169`: a `doAssert` on the user-settable `tapeLabel` length. Move it
        to `checkFile` as a `problem` (validate first; no Defect for user input).
      - A7 `tapeimage.nim:65`: prints decimal after "0x". Use `toHex`.
      - A8 The C boundary relies on catching Defects:
        - `DiagLog.[]` raises `IndexDefect` itself (`diagnostics.nim:122`);
        - the generated wrappers catch `IndexDefect` and bare `Exception` (`segapi.nim:196-198`),
          so `--panics:on` would abort the host;
        - check `0 ..< len` in the wrapper and catch `CatchableError` only.
        - Same rule for the bare `Exception` catches in `dlpackDeleter` (`api.nim:144`),
          `segRelease_*` (`segapi.nim:501`) and `=destroy(MapOwner)` (`traceindex.nim:267`).

      **B. Internal improvements (no API change), ranked**
      - B1 Hot-path copies:
        - `join.addSps`: a nested `line` captures `f`, so the whole `SpsFile` is copied, and
          `mgetOrPut` copies the runs (O(n²) per record).
        - `segy/writer.writeTrace` allocates per trace; `segy/reader.trailerStartsHere` does
          `newSeq(3200)` per trace; `exttext.nim:259` copies `@rec`.
        - `fieldValue` copies the layout through `layoutOf`.
        - `scaffold.nim:56` re-hashes and builds string keys per byte.
        - `revconvert.nim:664` `var o = t`; `segd/writer.nim:73` reslices `pending`.
        - `pushback.unread/readAvail` copy; `MemoryTape.usedBytes` is O(n) per block
          (O(n²) writes).
      - B2 Make the Rev 2/3 and SEG-Y/SEG-D duplication one code path:
        - `convert.finishOutput` vs `revconvert.nim:703-733` vs the tmp-then-rename writers in
          sps/p1 → one `common/outputfile.nim`;
        - the segd reader's trace read, format resolution and count checks (rev 2 vs 3);
        - the segd writer's `checkRecord` vs `checkRev3Record`;
        - three trimmed-text helpers; NIF escaping four times (edit, headernif, cli, scaffold);
        - the keys-required check four times, the slice check three times, `rowPtr` twice,
          `fit` twice;
        - nine copies of the `splitName` + `locate*` boilerplate (`headerfields`, `edit`).
      - B3 Split the long procs: `convertSegdToSegy` (~200 lines; repeated `isRev3` dispatch;
        `clampI32`) and `convertSegdRevision` (~145 lines → `convertRecord`). Use `std/times`
        in `fillTime`.
      - B4 Closed sets as enums: the magic note ids in `convert.nim:86` and `revconvert.nim:86`
        (`set[0..63]`); `gathers` `by: int`; the `scaffold` kind string; the CLI scope `char`
        (`HeaderScope` exists). Rename `Losses.count` to `add`.
      - B5 `segapi.nim` (1397 lines):
        - split the runtime C helpers (`abi/runtime.nim`) from the generator;
        - pass one `Bindings` state object instead of 17 compile-time globals;
        - make `pyMode` an enum, not `\x02` strings, and the record info a `nnkPar`, not `\x1F`
          strings;
        - drop the dead branch (`:1136`) and unused params (`checkRing.cols`,
          `stringArg.name`).
      - B6 Purity lies: `{.cast(noSideEffect).}` in the `func`s `api.view` and `atEnd`. Keep
        `shape` current at creation and add a pure prefetcher query; they stay `func` (Python
        properties).
      - B7 Error handling:
        - give `convertFile` `{.raises: [].}`, since it is documented as "never raises";
        - merge the identical `XmlError`/`CatchableError` branches (`layout.nim:233`);
        - stop using exceptions as control flow (`maps.nim:524`);
        - rename `SkipRecord` to `SkipRecordError`;
        - `prefetch.decodeChunk` should catch `SegError`, not `CatchableError`.
      - B8 `ptr` and `addr` used to dodge `var`: `Ctx.f: ptr SpsFile/P1File` (sps/p1) and
        `headernif.nim:465`.
      - B9 CLI:
        - `quit` from helpers → raise, and let `run` map it to an exit status;
        - dead forward declarations (291-292); unused `std/tables`; use `CountTable`;
        - the no-op `contextOf`; the vendor search path built twice.
      - B10 Make the `api.nim` adapter fields private (`dt`, `t32`, ..., `file`). Not
        re-exported.
      - B11 Doc comments:
        - add `##` to the undocumented exported symbols the reports list (diagnostics, io,
          segapi runtime, segy binheader/exttext/reader/writer, segd headers/rev3/reader,
          maps, keys, traceindex, gathers, headerfields, edit, sps/p1);
        - fix the stale docs: `segd/reader.nim:24`, `segd/writer.nim:1`, `p1.nim:16`
          (`auAuto`), and the broken wrap at `traceindex.nim:285`.
      - B12 Local polish:
        - `unsafeAddr` → `addr` (7 places);
        - `var` → `let`; `x != x` → `isNaN`;
        - `3200`/`32` → `TextHeaderSize`/`SegdBlockSize`;
        - flag loops → early return; `continue`;
        - lines over 100 characters;
        - `{.inline.}` on multi-statement generics (`fieldlayout`);
        - cryptic private names (`Ak`, `TInfo`, ...);
        - validate the `segApi` options outside `-d:segCapi`;
        - SEG-Y `decodeVendorAreas` takes no file name (`apply.nim:105,123`).

      **C. Public API changes (owner approved all of C1-C12, 2026-11-08).** Nim only
      unless marked C/Py.
      - C1 Behaviour: make bad caller input consistent with 12.5 (`ValueError`):
        - `sampleIntervalUs` returns NaN (C/Py);
        - `Prefetcher.traceAt` returns -1 (C/Py);
        - `maxSamples(traces)` raises an `IndexDefect`;
        - `IOError` is raised for caller mistakes (`headernif.nim:139`, `edit.nim:377`, C/Py
          via `openEditor`);
        - `doAssert` in `sps.encode(spsAuto)`.
      - C2 Behaviour: `HeaderEditor` is documented as "never raises", but `syncJournal`'s
        fsync raises `IOError` through the `segApi` setters (C/Py). Recommended: turn it into a
        refusal plus an error diagnostic, which makes the doc true.
      - C3 Silent diagnostics:
        - the log-less `readTracesInto` overloads are `{.discardable.}` and discard their log;
        - `readTraces` uses them, so an undecodable trace becomes a zero row with no record;
        - `PrefetchChunk` only counts failures.
        - Proposal: no `discardable`; a `readTraces(..., log: var DiagLog)` overload; failed
          rows with their messages in `PrefetchChunk`.
      - C4 Out-parameter lookups → `Option[T]` or a returned value. Keep the raising forms as
        the "required" path:
        - `toSampleFormat`, `toSegdFormat`, `fieldValue`, `maps.decode`, `findChannelSet`
          (→ object);
        - the `bool`+`var` `traceField`/`recordField`/`fileField` and `current*Field`;
        - `resolveLine`, `relation`, `parseFortranFloat/Int`;
        - `detectKind` → returns `SeismicKind` (`skUnknown` exists).
      - C5 Trim the umbrella surface (move to non-re-exported modules, or `export ... except`):
        - textrec card helpers (`col`, `rjust`/`ljust` → `strutils.align`, ...);
        - headerfields `splitName`/`getByName`/`locate*` and the templates `withBlockType`/
          `isLayoutField`;
        - traceindex `decodeEntry` (raw `ptr`), `readTracesRaw`, `mappedSize`, `flush`;
        - `convert.finishOutput`;
        - the bare `encode` in sps/p1 → `encodeSps`/`encodeP1`;
        - the redundant re-exports in `rev3.nim:16` and `segy/reader.nim:39`.
      - C6 Data model: `SegdRecord`/`SegdTrace` hold Rev 2 and Rev 3 fields side by side
        (`gh2`/`gh2r3`, `descriptors`/`descriptors3`, `trailer`/`trailerBytes`, `ext1`/`ext1r3`),
        switched by `isRev3`. The `hasX`/`formatKnown` flag pairs (both readers,
        `openSegdWriter`) have the same shape.
        - Proposal: a `case` variant on the layout, and `Option[T]` for the optional values.
        - Largest change in the list; it touches the reader, writer, revconvert, convert and
          the index.
      - C7 Closed sets typed as strings, ints or chars:
        - the vendor `format: "segd"/"segy"` → `SeismicKind`;
        - `FieldPlan.trim` string → enum;
        - `SpsPoint.kind: char` → enum;
        - `SegdConvertOptions.format: int` with 0 = keep → an enum or `Option` (C/Py).
      - C8 Renames:
        - `ebcdicToAscii`/`asciiToEbcdic` (they are Latin-1) → `decodeEbcdic`/`encodeEbcdic`;
        - `layout.find` (returns a seq) → `entriesFor`;
        - `LayoutEntry.byte` (shadows the type) → `bytePos`;
        - `setText` → `text=`;
        - `VendorBlock.get` → `[]`;
        - merge `decodeRev3` into `decodeBlock`;
        - `SegdChannelSetDescriptor3` → `...Rev3`, and `gh2r3`/`ext1r3`/`descriptors3` with C6;
        - `RecordScan`/`scanRecords` → `SegdRecordScan`/`scanSegdRecords`;
        - `VendorEnc` → `VendorEncoding`; `scaffold` → `scaffoldVendorMap`;
        - `segdContext`/`segyContext` → `vendorContext`;
        - `getByName` → `fieldByName`;
        - `SegyData.diagnostics` vs `.log` elsewhere → `log`;
        - drop `EditValue`/`toEditValue` (aliases of `FieldValue`);
        - `FieldValue.i/f/s` → descriptive names (C/Py; see `segapi.nim:547`);
        - `Prefetcher.positions` → `len` (C/Py);
        - drop the redundant `SegyRevision.==`.
      - C9 Public tuples → named objects: `addUserData` items, `VendorBlock.fields`,
        `FieldPlan.enums`/`bits`, and the `spsText`/`p1Text` results. `spsText` also becomes
        a `proc` (it uses a `cast(noSideEffect)`).
      - C10 Mutable bookkeeping fields → private with read accessors:
        - `RecordSource/Sink.recordIndex`/`fileIndex`;
        - `SegdReader.record`/`label`/`hasLabel`/`log` (→ `lent` accessors).
      - C11 Backend contract: `TapeDevice.readBlock` returns a sentinel int (>0 / 0 = mark /
        -1 = end) → `RecordKind` + `var` length. This affects custom tape backends.
      - C12 `SegUnlocatableError.diagCode: int` → `DiagCode`. Move `Severity`/`DiagCode` into a
        small `diagcodes.nim` to break the cycle.

      Agent summary: the codecs, headers and I/O layers are clean and idiomatic, and the
      architecture follows the owner decisions. The debt is in hot-path copies, Rev 2/3
      duplication, `bool`+`var` lookups, an over-wide umbrella surface, `convert.nim` and
      `segapi.nim`.
- [x] 12.2 Bindings from one declaration (owner, 2026-11-07: do this first, before 12.1).
      Every boundary function is written **once**: an ordinary exported Nim proc in
      `src/parseSEG/abi/api.nim` carrying `{.segApi.}`. The macro (`abi/segapi.nim`) generates
      everything else at compile time.

      Owner decisions:
      - Python becomes a generated **ctypes** module over the same shared library; nimpy,
        `pyapi.nim` and the nimpy patch are dropped. One binary serves C and Python.
      - **C ABI version 2** is allowed: one uniform convention from the Nim signature,
        `abi_test.c` updated, Python keeps its names and keywords (`test_pyapi.py` is the
        oracle).
      - genny was evaluated (it lists exports in a separate DSL, has a single `LibError`, and
        does not handle tensors, buffers or prefetch), so it is not used. Its architecture is
        kept: one library, with a generated header and a generated ctypes module.

      Design:
      - **Pragma:** `{.segApi.}`, `{.segApi(c = "seg_x", py = "x").}`, `concurrent`,
        `pyOnly` / `cOnly` for protocol hooks. Defaults: C = `seg_` & snake_case, Python =
        snake_case. The first parameter of a handle type makes it a method of that class.
      - **Handles:** `segHandle(FileObj, c = "SegFile", py = "SeismicFile")`, a `ref` kept
        with `GC_ref`. It generates `seg_<x>_release` and the Python class (`close`, `with`,
        `__del__`). Each handle has a lock: wrappers serialize calls on one handle unless the
        proc is `concurrent` (reads). With ctypes there is no GIL during calls, so this
        replaces the GIL's protection.
      - **C convention:** every function returns `SegStatus`; results go through trailing
        out-pointers.

        | Nim | Parameter | Result |
        |---|---|---|
        | scalars | int64/int32/double/bool | `T*` |
        | `string` | `const char*` (NULL = default if any) | caller buffer `char*, cap, int64_t* len` (Python retries when too small) |
        | handle | `SegX*` | `SegX**` (owned) |
        | enum | int32 checked against the enum | int32 |
        | `openArray[int64]` | ptr + len | |
        | `seq[T]` | | caller buffer `T*, cap, int64_t* len` |
        | value object | | struct `T*` (header struct generated from the Nim type) |
        | `DiagLog` | | owned `SegLog**` |
        | `FieldValue` | `SegValue*` | `SegValue*` |
        | `SampleBuffer` | `SegSampleBuffer*` (data, dtype, rows, cols, row_stride) | |

        Errors use the same status table plus `SEG_ERR_MEMORY`. A `LoggedError` carries its
        log out through the log out-pointer, and Python attaches it as `e.diagnostics`.
      - **Generated files** (written at compile time by the lib build, committed, and checked
        by a test that rebuilds them into a temp dir and compares):
        - `include/parseseg.h`: doc comments come from the procs' `##` comments;
        - `python/parseseg/__init__.py`: ctypes declarations, exception classes,
          handle classes and dict/enum conversions. Python-only protocol code (DLPack capsule,
          `__array__`, `tolist`, buffer-protocol `read_into`) is hand-written in
          `python/extras.py` and spliced in.
      - **Build:** a single entry `src/parseSEG/bindings.nim`. `nim lib` and the cross/static/
        csources builds use it; `nim pylib` copies the library next to the generated package.
        `capi.nim`, `pyapi.nim`, `abi/core.nim` and `abi/exporting.nim` are removed once
        `api.nim` covers them.
      - **Build tasks:** release builds use `--ic:off` and a fresh per-task nimcache (wiped
        first). Dev builds (`test`, `nimDebug`, `zigDebug`) use `--ic:on` when `PARSESEG_IC=1`
        is set. IC fails in this container even on a one-line program (the bundled `nifler`
        is musl-linked, and a source build reports "modules stopped for imports discovered
        during sem"), so it stays opt-in.
- [x] 12.5 Boundary names from the core (owner, 2026-11-08; do this before 12.1). "The names
      should be derived from the core, and if necessary rename the core. This is a Nim library
      first, everything else second, but it should not appear completely foreign outside of
      Nim, and the maintenance should be negligible with Nim's metaprogramming." 12.2's
      `api.nim` re-listed the library under its own names (`openFile`, `read`, `traceCount`),
      so the C, Python and Nim names drifted apart.

      Design:
      - **Annotate the core itself.** `{.segApi.}` goes on the public core procs
        (`traceindex`, `headerfields`, `gathers`, `edit`, `join`, `diagnostics`, `convert`,
        `revconvert`); `{.segHandle.}` on the core types that cross as handles (`SeismicFile`,
        `HeaderEditor`, `SurveyGeometry`, `DiagLog`); `{.segField.}` /
        `{.segField(readonly).}` on public fields to expose. The pragmas live in
        `abi/pragmas.nim` (std only, no cycles). Without `-d:segCapi` they do nothing. With
        it, they record the resolved signature in a `macrocache` table, and `segFinish` in
        `abi/api.nim` generates every wrapper, the header and the Python module. The doc
        comments come from the core procs, so they are written once.
      - **`api.nim` keeps only what the core cannot say:** the dtype-erased handles for the
        generic `Tensor[T]` and `Prefetcher[T]`, the reads that build them, DLPack, and
        `abiVersion`/`version`/`statusName`. Each of these adapters must overload a core
        routine with the same name and parameter names, checked at compile time. A
        `typedesc`/generic `T` becomes `dtype`; core `var` out-parameters and trailing
        defaulted ones may be dropped. When the adapter has no doc, it inherits the core
        routine's. `abiOnly` marks the few with no core counterpart.
      - **Names, all mechanical:**
        - Python: the type name, or snake_case of the proc name.
        - C: `seg_<snake type>_<snake proc>` for methods (first parameter a handle),
          `seg_<snake proc>` for free procs.
        - Constructors: `initX`/`newX` → Python `X(...)`, C `seg_<x>_new`.
        - Protocols: `len` → `__len__`; `[]` → `__getitem__` (IndexError, negative indices)
          plus `__iter__`; `next` → the iterator protocol too.
        - A `func` with only the receiver, or a `segField`, becomes a Python property;
          procs are methods.
        - Enums: `SEG_<SNAKE TYPE>_<SNAKE $value>`. Structs: `Seg<Type>`.
        - No `c=`/`py=` overrides. The one exception is the C/Python name of the two
          dtype-erased handles (`Tensor`, `Prefetcher`).
      - **Overloads.** C cannot overload. Only a `Slice[int]` / `openArray[int]` pair at the
        same parameter is allowed: C gets `<name>` (list) and `<name>_range`
        (`<p>_first, <p>_last`, inclusive like Nim); Python gets one function that takes a
        `range` or a sequence. Any other overload of an exported name is a compile error.
      - **Structs** get a generated C mirror type and conversions. `int` → `int64_t`,
        enum → `int32_t` (checked on input), `Slice[int]` → `SegSlice {a, b}`, nested
        objects nest, and `string` → `const char*`, which is allowed only in `lent`
        results, borrowed from the receiver. So core types keep any Nim layout.
        - Object parameters: C passes a pointer (NULL = `T()`), with
          `seg_init_<snake T>(T*)` for its defaults. Python passes a dict of the fields to
          change (nested: a dict or a tuple).
      - **Errors:**
        - Public core entry points raise `ValueError` on bad caller input (indices,
          ranges, missing keys) instead of asserting. The C boundary must not crash, and
          `-d:danger` release builds drop bound checks.
        - A `DiagLog` result that `isFatal` fails with the log attached (`SEG_ERR_IO` for
          `dcIo`, else `SEG_ERR_FORMAT`).
        - A `bool` result stays a bool (e.g. a refused edit).
      - **Core renames and additions** (public API change, approved by this request):
        - Trace ranges are `Slice[int]` everywhere, and lists are `openArray[int]`, both
          named `traces`: `readTraces`, `readTracesInto`, `newPrefetcher`, `maxSamples`,
          `componentGroups`. `Prefetcher.seek(span)`.
        - `SeismicFile` gains `maxSamples()`, `recordCount`, `traceEntry`, `traceKeys`,
          `gathers`, `componentGroupIds`, `applySurvey`, and raising
          `traceField`/`recordField`/`fileField` overloads (the `bool` + `var` forms stay).
          `SeismicKind` gains `skUnknown`.
        - `HeaderEditor`: `setField` → `setTraceField` / `setFileField` (with
          `setRecordField`), and `currentField` → `currentTraceField`.
        - `SurveyGeometry` absorbs `LineNames` (`lineNames`, `trailingDigits`) and gains
          `initSurveyGeometry`, `addSource`/`addReceiver`, `mapLine`,
          `addSps(path)`/`addP1(path)`, `sourceCount`/`receiverCount`.
        - `DiagLog` gains `[]`.
      - ABI version 3. `abi_test.c`, `test_pyapi.py`, the `ttargets` host and the docs
        follow the new names.
- [x] 12.3 Apply the approved 12.1 findings, one module per commit, tests green after each.
- [x] 12.4 Review by an agent; fix its findings.

### Phase 13: Release readiness: usage docs, benchmarks, review, merge to main (owner, 2026-11-08)
Goal: the library is ready to carry a high-performance signal-processing library and a
high-performance viewer. Then `seg-library` is merged into `main`.
- [x] 13.1 Usage docs for the public API: task-oriented guides in `docs/guide/` (getting
      started; viewer recipes: open, index, gathers, random access, prefetch, header tab,
      patches; processing recipes: streaming whole files into tensors, threads, writing results,
      conversion, geometry; C and Python quick starts). Every code example is compiled or run
      by a test so the docs cannot go stale. `docs/api.md` stays the reference and links to them.
- [x] 13.2 Benchmark suite (`bench/`), on synthetic files up to tens of GB plus the samples:
      - cold and warm cache;
      - index build and keys at 10 M traces;
      - sequential decode throughput per format, against a memcpy / memory-bandwidth baseline;
      - viewer latency for random trace, gather and window fetches (p50/p99);
      - multi-thread scaling;
      - prefetch;
      - C ABI and Python/numpy overhead;
      - conversion, header edits and geometry write-back.

      Results go in `docs/benchmarks.md`, with the machine described. Bottlenecks get fixed
      (each with a test), or listed with a proposed fix.
- [x] 13.3 Multi-agent review of `seg-library` (read-only, fresh reviewers), along these
      dimensions:
      - correctness of the Phase 4.7/6.8-6.10/10.5/11 code;
      - performance and concurrency for HPC and the viewer;
      - public API, and C/Python boundary safety (lifetimes, ownership, zero-copy);
      - robustness against malformed or hostile input in release (`-d:danger`) builds.

      Output: a ranked findings list in this file. Public API changes need owner approval.

      **Findings (2026-11-08).** Four read-only reviewers: R1 correctness, R2 performance and
      concurrency, R3 API and boundary, R4 fuzzing (about 750k cases under checked, danger and
      ASan builds). Their full condensed reports are in the session scratchpad.
      - Holds up:
        - readers and index under hostile bytes: no out-of-bounds reads, hangs or Defects;
        - multiplexed temp-copy lifetime and journal safety;
        - parallel reads from one file scale: 2.3 → 11.2 G samples/s at 1 → 8 threads in danger
          builds. The GIL is released and DLPack/numpy lifetimes are right.

      Group I (internal, no public API change). These must be fixed before the merge:
      - Critical and high:
        - R3-1/R4-5: a Defect at the C boundary poisons the thread, and later calls return
          SEG_OK and do nothing. Trigger: the `copyBytes` overflow at `traceindex.nim:530`. Fix
          the arithmetic, and map `Defect` in `segGuard` to SEG_ERR_INTERNAL.
        - R4-1: the SEG-2 sample count is not bounded by the file size. A 4 KB file makes
          `readTraces`/`convertFile` allocate 4-134 GB and abort.
        - R4-2: Rev 3 → Rev 3 conversion pre-allocates 32 × the GH#2 trailer block count (up to
          137 GB), at `revconvert.nim:591`.
        - R4-3: a heap use-after-free at `segd/reader.nim:680` (`starts.add ... starts[^1]`), on
          ordinary multiplexed data.
        - R2-1: the decode loops keep bounds checks in the shipped `-d:release` builds, which
          decode 6-10x slower than danger.
        - R2-2: two fields of one trace in a batch cause one fsync per trace.
        - R2-3: `componentGroupIds` at 10M traces takes 6.9 s and +2.4 GB.
      - Medium:
        - R4-4: converting `X.tmp` to `X` destroys the input. The fixed `.tmp` name is shared and
          follows symlinks.
        - R1-1: the SEG-2 summary format code is off by one.
        - R1-2: SEG-Y → SEG-2 DELAY and statics ignore the time scalar.
        - R1-3: SEG-D → SEG-2 dates get the wrong century. The century pivots are inconsistent
          (50/70/80), so unify them on `fullYear`.
        - R2-6: IBM float uses `ldexp`.
        - R2-7: little-endian loads double-swap.
        - R2-8: no reserve in the index. The keys are 144 B, not the documented ~100 B.
        - R3-7: `copyBytes` allocates even with cap 0, and Python's `_bytes`/`_seq` call twice.
        - R3-8: the generated wrappers lock only the first handle, and the prefetcher's `next`
          holds the handle lock while it waits.
      - Low:
        - R1-4: SEG-2 → SEG-D Rev 2 can produce an empty output reported as a success.
        - R1-5: the `GeometryChanges` counts are overstated when a sync fails.
        - R1-6: doc and labeling details.
        - R2-9: `pow` per sample for 8022/8024/8042/8044.
        - R2-10: tensors zero-filled before an overwrite.
        - R3-10: Python's 4 KB value buffer; NUL bytes in strings accepted; numpy `copy=`
          ignored.
        - R3-11: `*out` not zeroed on SEG_NOT_READY/SEG_END.

      Group II (public API, additive; needs owner approval):
      - R3-2: progress and cancellation for open, index, convert and export. A callback and
        SEG_ERR_CANCELLED; optionally an index sidecar cache.
      - R3-3: a trace write path for processing: `openSeismicWriter(path, like = f)` and
        `writeTrace(src, trace, samples)`, which carries the headers over and encodes. In C,
        `seg_writer_*`.
      - R3-4: editing from C/Python:
        - export batch begin/end;
        - `importHeaders` and applying a patch;
        - `openEditor(f: SeismicFile)` reusing the viewer's index.
      - R3-5: viewer reads:
        - the SEG-Y textual header as text;
        - sample windows in `readTracesInto`;
        - `sortTraces(f, keys)`;
        - a DiagLog out from `read_traces_into`.
      - R3-6/R2-4: bulk keys and header columns (`traceKeysInto`, `traceFieldColumn`), and numpy
        int64 trace lists. Today it is 4 µs per trace from Python, so 40 s for 10M traces.
      - R3-9: prefetcher chunk recycling (`recycle` / `nextInto`).
      - R2-5: the Nim `Prefetcher` uses freed memory after `f.close()` (SIGSEGV, proved). Fix it
        by sharing the map owner (close defers the unmap), or by having close raise.
      - R3-11b: `struct_size` first in the option structs, for ABI growth.
- [x] 13.4 Apply the 13.3 findings (and 13.2 fixes not yet applied); full suite green.
- [x] 13.5 Merge `seg-library` into `main` (owner asked, 2026-11-08), after Phase 14. Do not
      push unless the owner asks.

### Phase 14: Nim library only (owner, 2026-11-09)
Remove the FFI and simplify what was bent around it. Keep behaviour and performance. Run
`nim test` green after each task, then commit.
- [x] 14.1 Remove the C ABI and Python. Delete or replace each of these:
      - the `src/parseSEG/abi/` modules: `api`, `pragmas`, `runtime`, `segapi` and `gen/`;
      - `src/parseSEG/bindings.nim`, `include/`, `python/`;
      - `tests/c/`, `tests/python/`, `tests/tcapi.nim`, `tests/tpython.nim`, and the library
        parts of `tests/ttargets.nim` (keep the CLI build checks);
      - in `config.nims`: the `lib`, `libLinux`, `libWindows`, `libMacos`, `staticlib`, `pylib`
        and `csources` tasks with their helpers, plus `abiFlags`;
      - `tools/macos-stubs` and the zig library wrappers, if nothing else uses them;
      - `bench/capi_bench.c` and `bench/py_bench.py`, with their parts of `bench/suite.nim` and
        `docs/benchmarks.md`;
      - `docs/design/c_abi.md`, `docs/design/python.md`, `docs/guide/c.md` and
        `docs/guide/python.md`, plus the README rows and links that point to them;
      - every `{.segApi.}`, `{.segHandle.}` and `{.segField.}` pragma and its `hide=` arguments,
        in 18 src files (`grep -rln "segApi\|segHandle\|segField" src`);
      - `AbiVersion`.

      Keep the CLI (`bin/parseSEG`) and the zig CLI builds. The `PackageVersion` stays. The
      nimble version becomes 0.5.0, a breaking change.
- [x] 14.2 Simplify what the FFI shaped (an audit agent first, then the owner approves).
      **Owner decisions (2026-11-09)** on `docs/design/phase14_audit.md`: every [do] item; R2-5
      as the pinned map owner (item 1); delete `readTracesRaw` and `writeGeometry(ed, f)`
      (items 3, 9); of the optionals, items 21 (`chunks`), 22 (umbrella) and 11 (a
      `copyWithGeometry` result object) are in; items 20 and 23 go to "Future". Steps:
      - [x] 14.2a prefetcher lifetime (items 1, 2)
      - [x] 14.2b boundary-only procs (items 3, 8, 9, 10)
      - [x] 14.2c handles to seqs (items 4, 5)
      - [x] 14.2d encapsulation and hidden parameters (items 11, 12, 13, 14, 16)
      - [x] 14.2e comments, umbrella, `chunks` (items 19, 21, 22) Known
      candidates:
      - **Handles:** handle-style types (`HeaderListing`, `HeaderPatch` and others), where a
        `seq`/iterator or plain proc would do.
      - **Generated-API leftovers:** procs and overloads that exist only for the generated API,
        such as the `SeismicFile` overloads of `writeGeometry` and `geometryChanges`, `seg2*`
        string accessors by index, and `previewGeometry`.
      - **Boundary-only code:**
        - per-handle locks, `concurrent` markers and the in-flight counters;
        - NUL-separated `seq[string]`;
        - `FieldValue`/`SegValueRef` borrowing;
        - `requireBuffer` / out-parameter shapes.
      - **Hidden parameters:** parameters hidden only at the boundary (`demuxDir`, `writable`,
        `join`).
      - **Doc cleanup:** "C/Python" mentions in the docs and `##` comments.
      - **R2-5:** the Nim `Prefetcher` uses freed memory after `f.close()`, which was only safe
        through the ABI. Fix it with a shared map owner (close defers the unmap) or a destructor
        rule.
- [x] 14.3 Nim-only API additions from the 13.3 review (Group II, now without the C/Python
      forms). The owner picks which; the rest go to "Future". In order of need.
      **Owner decision (2026-11-09): all of them.** Steps, each committed with `nim test` green:
      - [x] 14.3a bulk keys and header columns
      - [x] 14.3b viewer reads: sample windows, SEG-Y text header as text, `sortTraces`
      - [x] 14.3c `openEditor(f: SeismicFile)` reusing the index
      - [x] 14.3d write path: `openSeismicWriter(path, like = f)`, `writeTrace`
      - [x] 14.3e progress/cancel callback; index sidecar cache
      - [x] 14.3f prefetch chunk recycling (`recycle` / `nextInto`)
      The candidates:
      - **Bulk keys and header columns:** `traceKeysInto` and `traceFieldColumn(f, name,
        traces)`. These resolve the field offset once, then read only those bytes per trace.
      - **Viewer reads (R3-5):** sample windows in `readTracesInto`, the SEG-Y textual header as
        text, and `sortTraces(f, keys)`.
      - **Write path (R3-3):** `openSeismicWriter(path, like = f)` and `writeTrace(src, trace,
        samples)`, which carry the headers over and encode to the target format.
      - **Progress and cancel (R3-2):** a callback for open/index/convert/export, and an
        optional index sidecar cache.
      - **Editing (R3-4):** `openEditor(f: SeismicFile)` reusing the viewer's index.
      - **Prefetch (R3-9):** chunk recycling, `recycle` / `nextInto`.
- [x] 14.4 Re-run `nim bench` (Nim only) and update `docs/benchmarks.md`, then do 13.5.

### Future (noted, not scheduled)
- From the 14.2 audit, declined for now: a bounds-checked `mapped(f)` view for internal map
  reads (item 20); `Option` fields instead of -1/NaN sentinels in `FileSummary` (item 23).
- Sorting traces by header fields (offset, receiver, CMP, ...), decided 2026-11-07: a sort
  returns a **permutation** (a trace index list, 4 B/trace) over the index and never moves data.
  Neither the file nor a whole-file tensor is reordered; that would not scale to 40 GB.
  Samples are decoded in sorted order on demand (8.2 selections): a viewer's visible window, a
  processing job's gather. Decoding produces a new buffer anyway, so sorted reads cost nothing
  extra. An optional `permuteRows(var Tensor, perm)` helper reorders a tensor the caller
  already holds, in place, with one row of scratch memory. Today `gathers`/`componentGroups`
  only return index lists; nothing is reordered.

## Open questions for the owner
- A sample file with **rotational data**, and one with **receiver-gather** SEG-D, would let us verify these paths.
- Integer-format SEG-D samples (8015/8022/8024/8036/8038/8042/8044/8048).
- Real SPS / P1 files (Phase 10 is tested with synthetic files built from the spec examples) and a
  Geospace SEG-2 file (Phase 11).

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
- 2026-11-07: Task 6.2 done. `model/keys`: `TraceKeys` (record, ensemble, offset, source/receiver line, point, index and coordinates, depth/reshoot index, sensor type, component; NaN/0 = unknown). SEG-Y keys come through the layout-aware `geometry`, with zero coordinate pairs and source points treated as unset (Inglewood and Sweep0 have zeros). The component is a trace ID code of 11-17 or 27-41. SEG-D Rev 2: GH#N source, THE#1 receiver, component = sensor type. Rev 3: a per-trace Source Description block (0x15-0x19, 0x1F) in the extensions, else the record's; component = group index, else sensor type. `buildIndex`/`openSeismic(keys = true)` fill `index.keys` (~100 B/trace, opt-in). `model/gathers`: `gathers(index)` splits SEG-D by record, and SEG-Y on the key chosen by its sorting code (ensemble for 2-4/6/8/9, offset for 7, else field record; a constant key falls back to the receiver station for sort 6, else the field record). `classify` counts distinct known sources and receivers over seismic traces only (SEG-D aux channel sets are excluded): shot, receiver, other, or unknown. One station with at most one source is a shot only if it is a single trace or one trace per component. Declared CMP/offset sorts always win; declared sort 6 wins unless the geometry is plainly a shot. `componentGroups(index, range)` groups by (source, receiver station, depth, reshoot), and `isMultiComponent` tells whether a group holds several components. Tests (`tests/tgathers.nim`): the sample files, every split rule on synthetic indexes, and end-to-end files: a SEG-Y sort-6 receiver gather, a SEG-D 2.0 two-station × 3-component record, and a Rev 3 receiver gather with per-trace source blocks. The 65 MB file is one shot gather with 1 source, 3954 receivers and no multi-component stations.
- 2026-11-07: Task 6.3 done. `model/prefetch`: `newPrefetcher[T](file, first, last, chunkTraces, depth, cols)` starts a worker thread that decodes chunks ahead into a ring of `depth` slots. The consumer uses `tryNext` (never blocks), `next` (waits), `atEnd`, `seek(first, last)` (bumps a generation, so stale chunks are dropped and one still decoding is discarded) and `close`. Ownership: the worker touches no managed memory. It reads the map, entries and codecs through raw pointers and decodes (`decodeEntry`) into slot buffers the consumer allocated; taking a chunk moves the slot's tensor out and allocates a fresh one, so returned tensors are never rewritten. `=copy` is an error; `=destroy` joins the worker if `close` was forgotten. Undecodable traces are zeroed and counted (`failed`). Tests (`tests/tprefetch.nim`): equality with `readTraces` for several chunk/depth pairs on all sample files, polling, ownership, sub-ranges/seeks/float64, damaged entries, destroy without close, and 3000 random seek/poll steps. **ThreadSanitizer is clean**: run it with `nim c -r -d:useMalloc -d:noSignalHandler --debugger:native --passC:-fsanitize=thread --passL:-fsanitize=thread tests/tprefetch.nim`. It found one race, now fixed: `headReady` copied a whole slot whose `failed` field the worker was writing.
- 2026-11-07: Task 6.4 done. `tools/bench.nim` (`nim c -r -d:danger --path:src tools/bench.nim [files]`) takes the best of 5 warm runs. On the 65 MB Rev 3.0 file (3957 traces, 15.8 M samples, 8058): index 7.4 ms (1.9 µs/trace, 95 KB of entries); with keys 7.7 ms; headers-only read 7.6 ms; full read (raw + decoded) 55 ms (1.2 GB/s); `readTraces` of everything 10 ms (6.4 GB/s, 1.55 G samples/s); prefetch thread (256 × 4) 7.1 ms. Inglewood (IBM float): range decode 450 M samples/s. Two fixes came out of it. (1) SEG-Y keys took 8.5 µs/trace, because `geometry` copied the layout and did 19 allocating name lookups per trace; `segy/fields.GeometryReader` (`initGeometryReader(file)`) resolves the lookups once per file, bringing it to 0.45 µs/trace, and `geometry(file, trace)` now wraps it. (2) `DiskSource` zeroed a 1 MB buffer per open, so reading a 4 KB file took 0.8 ms. Reads are now capped at the bytes left (13 µs), and the cached size is re-read at its end, so a file still being written keeps reading (test `disk_source_sees_a_growing_file`).
- 2026-11-07: Task 6.6 done. `model/edit`: `openEditor(path, journalPath)` maps the file read-write (`openSeismic(writable = true)`) and appends a `(session ...)` line to the journal (default `<path>.edits.nif`). `setField(trace, "trace.<f>" | "ext1.<f>", v)`, `setField("binary.<f>", v)` (SEG-Y) and `setRecordField(record, "gh1.<f>" | "gh<N>.<f>", v)` (SEG-D Rev 1/2 source blocks) take an int, float or text. Each edit decodes the block from the map, sets the field by name (`fieldPairs`, layout fields only, checked conversion), re-encodes with `encodeChanged` (so width, BCD digits, nibbles, 24-bit and fixed-point ranges come from the existing codecs), diffs, journals the changed span (`(edit <offset> "<old hex>" "<new hex>" "<label>")`, flushed) and only then writes the map. Refused edits return false plus an error diagnostic and never raise: structural fields (counts, sizes, formats, revision/byte order, channel set references, Ext1 last-trace flag/name), unknown or raw fields, out-of-range values, missing Ext1, and Rev 3 general blocks after GH#1 (not editable yet). Cached binary/GH1/GH#N copies in the index are refreshed. `rollbackJournal` (newest first) and `applyJournal` (oldest first) skip locations already at the target, log conflicts and leave them alone, and skip malformed or cut-short lines with an error; a missing journal is fatal, not an exception. Tests (`tests/tedit.nim`): SEG-Y BE/LE/Ext1 (u64 values beyond 2^53 pass as int64), SEG-D 2.0 BCD/24-bit/fixed-point, Rev 3 THE#1, 13 kinds of refusal leaving the file and journal untouched, rollback → original bytes, repeat rollback, redo → edited bytes, a conflict plus a damaged journal, and an entry journaled but never written.
- 2026-11-07: Task 6.7 done, so **Phase 6 (data model for viewers and HPC) is complete** (an agent review follows). `tests/tlargefile.nim` builds two sparse files: a SEG-Y Rev 1 (17,900 fixed-length traces of 240 KB, 4.30 GB) and a SEG-D 2.0 (63.sgd's headers with 70 traces of 16 M samples, 4.48 GB). Only the headers and the first and last traces are written. For each file it runs the index, range reads, read-ahead and header-only disk reads (`DiskSource` seeks) past 2^32, then an in-place edit of the last trace and its rollback. It checks the file is still sparse (st_blocks < 256 MB) and skips otherwise; it takes about 3.5 s and removes its files. Found by it: a Rev 0/1 fixed-length SEG-Y whose trace headers disagree with the binary header logged a warning on **every** trace (unbounded on a 40 GB file). The SEG-Y reader now logs 5 and then one info summary, like the SEG-D reader's `note` (test `segy_repeated_trace_warnings_are_capped`).
- 2026-11-07: Independent review of Phase 6, by two parallel agents (one on I/O, index and gathers; one on prefetch and edits), found 14 verified issues. All are fixed, with regression tests in `tests/tphase6review.nim` (a*/b* blocks) and `tests/ttraceindex.nim`.
  - (a1) A RangeDefect from `int16(channelSet)` on records with ≥ 32768 channel sets. `TraceEntry.channelSet` is now `uint16` with `NoChannelSet` and `channelSetIndex`, and the entry is still 24 B.
  - (a2) **Headers-only walks copied about 99.7% of the file**: each refill after a seek fetched a whole chunk. `RecordCursor` now refills header-sized (`max(512, want)`) after a seek, and from the start for `headersOnly` readers (`preferSmallReads`). The 65 MB index now takes 2.7 ms (was 7.4), and the Inglewood walk seeks over 90% of its trace bytes.
  - (a3, a4) `detectKind` now decides by how printable the textual header is, in EBCDIC or ASCII (≥ 60% of 3200 bytes). A SEG-D file numbered 43xx stays SEG-D, and a SEG-Y with an undefined format code is still SEG-Y, so it gets the reader's own fatal diagnostic.
  - (a5) SEG-D gathers are no longer forced to `gkShot` when the keys cannot tell.
  - (a6) A closed map: `MemFileSource.close` zeroes `size`, the size comes from the map itself, `readTracesInto` uses the nil-safe accessors, and `SeismicFile` has `=copy {.error.}`.
  - (a7) Character devices read as empty: the size is now trusted only for `S_ISREG` files.
  - Minor fixes: the 64 KB scratch buffer in `skip` is `{.noinit.}` and allocated only on the read-and-discard path; negative skips return 0; `DiskSource.seekForward` no longer overflows.
  - (b1) Edits were allowed on files that are neither SEG-Y nor SEG-D (`TraceIndex.detected`).
  - (b2, b3) Repeated rollback/apply corrupted the file or reported false conflicts when one location was edited twice. `replay` now merges the journal per byte (the first old byte, the last new byte) and moves each contiguous run as a whole.
  - (b4) Hostile journals: a bounded chunked line reader (lines over 64 KB are malformed and never held whole), and journal diagnostics capped at 5 plus a count.
  - (b5) `gh<huge>` raised from `parseInt`; block numbers are now 1-4 digits.
  - (b6) A prefetch chunk of zero width hit an IndexDefect.
  - (b7) Prefetch consumer procs segfaulted after `close`.
  - From the plausible list: journal lines are fsync'd before the map is written; after a failed journal write the next line starts on a fresh line; prefetch slots are capped at the file's trace count; a short chunk is cloned without reallocating its slot.
  - Not done, and noted as limits: `HeaderEditor` has no destructor (call `close`); the journal's `(session ...)` identity line is not checked on replay; a BCD -1 (all F) is accepted for every BCD field.
- 2026-11-07: Owner decisions: Phase 8 (embeddable library and C ABI) comes before Phase 7 (CLI); Phase 9 renames the project to parseSEG; Phase 10 adds SEG P1 and SPS survey files. A probe confirmed that `--app:lib --noMain --header` works: plain structs export as-is, objects with seq/ref become opaque, and tensors cross as a data pointer plus shape and strides (DLPack-style) with a release handle. Sorting is to be done by permutation views (see Future). Cross-format conversion is task 8.6. **Next: task 8.1.**
- 2026-11-07: Task 8.1 done: `docs/design/c_abi.md`. Probes showed host threads **segfault** under the default thread-local allocator unless each thread calls `setupForeignThreadGc`; with `-d:useMalloc` 4 pthreads × 2000 alloc/release cycles work, so the library is built `--app:lib --noMain --mm:orc --threads:on -d:useMalloc`. Defects inside an export are caught by `except Exception` (panics off). `GC_ref`'d refs work as handles. Decisions: `seg_` prefix (survives the Phase 9 rename); a curated, self-contained, commented `include/parseseg.h`, checked by a C layout test (sizeof/offsetof against Nim), a symbol cross-check against the `.so`, and C and Python ctypes tests; opaque handles (File, Tensor, Prefetch, Editor, Log, Gathers) plus bycopy structs (`SegTraceEntry` = `TraceEntry`, `SegTraceKeys`, ...); tensors leave zero-copy as a `SegTensorView`, as DLPack, or by decoding into a caller buffer; `SegStatus` codes plus a thread-local `seg_last_error`; diagnostics through `SegLog`; `seg_init` runs NimMain.
- 2026-11-07: Task 8.2 done. `docs/api.md` lists the stable surface of `import parseSEGD`. The low-level codecs and the field-layout pragmas moved to `parseSEGD/codecs`: the umbrella no longer exports them, and `segd/headers`/`rev3` export only `FieldSpec`/`FieldKind`/`fieldTable`/`Bcd*`, so Arraymancer's `at` no longer clashes. **Trace selections**: `readTraces`/`readTracesInto(f, traces: openArray[int], ...)`, `readTracesRaw` (a caller-owned buffer plus a row stride, for C and numpy), `maxSamples(f, traces)`, and `newPrefetcher(f, selection, ...)` with `traceAt` (the list is fixed for the prefetcher's life, because the worker reads it). All share one decode loop. `model/headerfields`: `FieldValue`, `HeaderBlock`, `BlockRef`, `locateTraceBlock`/`locateRecordBlock`/`locateFileBlock`, `withBlockType`, `fieldNames`, and `traceField`/`recordField`/`fileField`, which read any named field from the map. The editor now uses the same lookup (`EditValue` = `FieldValue`). `tests/theaderfields.nim` checks every layout field of every trace of the 4 committed samples against the readers' decoded headers.
- 2026-11-07: Task 8.3 done. `src/parseSEGD/capi.nim` has 51 `seg_*` exports covering: init, versions, last error and status names; files (open, kind, counts, entry, keys, sample interval, log); header fields by name (trace, record, file); reads (range, selection, and `_into` a caller buffer with a row stride); tensors (view, DLPack v0.8 `DLManagedTensor`, release); gathers and component groups; prefetch (range or selection, try_next/next/seek/trace_at/release; it holds its file alive); edits (open, set trace/record/file, edits, log, close) and journal rollback/apply; logs (count, by severity, get, NIF, release, where borrowed logs ignore release); and `seg_sizeof`/`seg_offsetof` for layout tests. Every export runs inside `guarded` (`except Exception` → status + thread-local `seg_last_error`), and arguments are checked before any Nim `doAssert`. The `.so` exports exactly those 51 symbols plus `NimMain`/`NimDestroyGlobals`. `include/parseseg.h` is curated, self-contained and commented, and it compiles under `gcc -std=c99 -Wall -Wextra -pedantic` and as C++. `nim lib` builds `bin/libparseseg.so` with `--mm:atomicArc -d:useMalloc` (atomic refcounts, so DLPack deleters and releases may run on any thread). New Nim API: `sampleIntervalUs(f, trace)`, `Prefetcher.positions`. Package version 0.2.0.
- 2026-11-07: Task 8.4 done. `tests/tcapi.nim` (run by `nim test`) builds the library with the `nim lib` flags. It compiles `tests/c/abi_test.c` with `-std=c99 -Wall -Wextra -Werror -pedantic` and runs it, checks that the header compiles as C++, checks that the `.so`'s exported `seg_*` symbols are exactly the header's declarations, and runs `tests/python/smoke.py` (ctypes; numpy checks only when numpy is installed, which it is not here).
  - `abi_test.c` checks every struct's sizeof and every field's offsetof against `seg_sizeof`/`seg_offsetof`, and exercises every function: SEG-Y/SEG-D/junk files, fields, logs, reads into tensors and caller buffers, selections, DLPack (released after the source tensor), gathers, component groups, prefetch (with its file released first), seek and try_next, edits with refusals, rollback (byte-identical) and apply, plus 4 pthreads reading one `SegFile` concurrently.
  - `-d:capiSanitize` reruns it under ASan and TSan; both are clean. ASan found a leak, now fixed: `FileObj(f: openSeismic(...))` leaked the half-built handle when `openSeismic` raised (a missing file), so the open now happens into a local first (also in `seg_editor_open`).
  - CI fetches Atlas deps, runs `nim test`, builds `nim lib` and uploads the `.so` and header.
- 2026-11-07: Task 8.5 done.
  - `TraceKeys` gains `srcZ`, `rcvZ`, `cmpX` and `cmpY`. `deriveGeometry` fills the offset (the source-receiver distance) and the midpoint once both ends have coordinates; SEG-Y's signed header offset is kept unless 0.
  - SEG-D Rev 3 Position blocks (0x50-0x52): the first valid, not-bad tuple with finite coordinates 1-2 is used, in the CRS's own axis order. In trace extensions a block after a source description is the source's, after a measurement block (0x61) it is ignored, else it is the receiver's. In the general headers it is the source's, because INOVA writes it *before* the 0x16 Source Description. On the INOVA fixture the receivers are at (1826232.4, 446233.8, z 1061.8) and the source at (1834704.4, 445679.5), giving an offset of about 8490 m; the aux traces' blocks are flagged invalid.
  - SEG-Y: elevations, and the CDP X/Y as the midpoint, come through the Layout.
  - External geometry hook: `GeometryTable` (`addSource`/`addReceiver` by (line, point, index); index 0 matches any index, an exact index wins), and `applyGeometry(keys | index, table, overwrite)`. Phase 10 fills it from SPS/P1.
  - C ABI: `SegTraceKeys` gains the 4 fields (layout test updated), plus `SegGeometry` (`seg_geometry_new`/`add_source`/`add_receiver`/`release`) and `seg_file_apply_geometry`, which also invalidates the cached gathers.
- 2026-11-07: Task 8.6 done, except SEG-D Rev 2 ↔ Rev 3, which is split out as **8.7** (it needs whole Rev 3 records built, and both SEG-D revisions already rewrite byte-identically).
  - `src/parseSEGD/convert.nim`, exported by the umbrella module:
    - `convertFile` (detects the input; never raises);
    - `convertSegy`: revision 0/1/2.0/2.1, byte order and format. It drops extended text for Rev 0, and Ext1, proprietary headers and trailers below Rev 2, logging each kind once. Below Rev 2 it skips traces with more than 65535 samples (an error). Going to Rev 2 it adds the byte-order marker and EndText;
    - `convertSegdToSegy`: the mapping table is in the module doc. Samples go through float64 with a lossless default format (8048 → IBM, 8036 → int24/int32, 8038 → int32, 8080 → float64/float32, else float32), and `applyDescale` (MP factor / DSM) is optional. Channel type and sensor give the trace ID. Coordinates use the finest scalar that fits int32, and Rev 3 times come from the GH#3 time zero.
  - Rev 2 output also carries float64 coordinates, offset, midpoint, elevations, sample interval and count in Ext1, plus a `PSEGD001` proprietary header with line/point/index/sensor/component/record/channel set/type, described by a `((SEG:Layout))` stanza. `fieldValue(file, trace, "rec_line")` reads it back. Unmappable SEG-D content (extended/external headers, extra general blocks, trailers, 8080 into float32) gets one info note per kind; a value that does not fit a forced format zeroes its trace, with an error.
  - C ABI: `SegConvertOptions`, `seg_convert_options_default`, `seg_convert` (layout test and abi_test updated).
  - Tests (`tests/tconvert.nim`): 63.sgd → Rev 2.1 (samples, header and station values) and → Rev 1; INOVA Rev 3 → Rev 2.1 (Ext1 coordinates, scalar -1000, offset, aux trace ID, UTC time); descaling; an 8038 record → format 2 exactly; a forced int8 overflow; Inglewood IBM Rev 2.1 → Rev 1 IEEE (equal samples and headers) and → Rev 0; Sweep0 LE Rev 0 → Rev 2.1 LE → Rev 1 BE; invalid targets and inputs.
- 2026-11-07: Owner additions to Phase 8: **8.8** nimpy Python bindings, with a define-switched export pragma (`-d:segCapi` / `-d:segPython`) so the C ABI and the Python module share one source, and **8.9** an ongoing task to keep build tasks for every target (`lib`, cross-builds per OS, `pylib`, `staticlib`, the CLI) plus a CI matrix. Order: fix the Phase 8 review findings, then 8.8 and 8.9, then 8.7.
- 2026-11-07: Independent review of Phase 8 (8.1-8.6), by two parallel agents (C ABI; Nim API and conversion), found 13 verified issues. All are fixed, with regression tests in `tests/tphase8review.nim` (b1-b9 plus geometry) and `tests/c/abi_test.c` (`test_concurrent_init`, `test_limits`).
  - C ABI:
    - (1) **Concurrent `seg_init` deadlocked every time**: a Nim lock created by module init, i.e. inside the very `NimMain` call it guarded. It is now a lock-free compare-and-swap once guard.
    - (2) Hostile `cols` sizes **terminated the host** ("out of memory"). Buffers and prefetch rings are now bounded (≤ 1 TiB, overflow-safe checks; `cols < -1` refused), and buffers of 64 MiB and up are probed with `malloc`/`free` (a refusal is `SEG_ERR_IO`). Found on the way: an out-of-memory hook cannot raise through goto-based exceptions, so the allocator still quits. A forked, RLIMIT_AS-capped child tests the refusal.
    - (3) A huge selection `n` segfaulted: entries are checked before anything is allocated, with n ≤ 2^34.
    - (4) `lastError` (a string threadvar) leaked on every host-thread exit; it is now a fixed 1 KiB thread-local char buffer.
    - Minor: out-of-range editor indices are `SEG_ERR_ARGUMENT`; handle out-parameters are NULL on failure; `seg_tensor_to_dlpack` clears the last error; the trivial accessors are `{.raises: [].}`; `HeaderEditor.close` closes the journal even when the flush fails; header and c_abi.md corrections (SegGeometry, borrowed logs are snapshots, SegValue.text lifetime, record count 0).
  - Nim:
    - (b1) **Multi-record SEG-D with mixed formats was silently corrupted.** `convertFile` now scans the record formats first and picks a common lossless one (float64 in Rev 2). Every encoded trace is decoded back and compared, and inexact traces are counted in a warning, which also covers tape input, explicit formats, descaling and SEG-Y → SEG-Y.
    - (b2) An out-of-range Rev 3 time zero raised a RangeDefect out of `convertFile`; the time fields are now left 0, with a note.
    - (b3) A Position block after Source Description + Additional Source Info (0x20/0x21, §6.5) was taken as the receiver's.
    - (b4) Selection prefetchers leaked their list on destroy.
    - (b5) 8036 → pair-swapped zeroed every trace; it now goes to int32, and 3-byte formats with pair-swapped order are refused.
    - (b6) Descaled values now use float64 on Rev 2, and 8048 → IBM copies words exactly.
    - (b7) A fractional sample interval in a Rev 1 binary header became 0; it is now rounded.
    - (b8) SEG-Y → SEG-Y byte-order changes now reorder proprietary headers described by the file's Layout (PSEGD001 survives).
    - (b9) `convertFile(p, p)` truncated the input; it is now refused.
    - Also: `applyGeometry` keeps a signed SEG-Y offset and known elevations unless `overwrite`; accelerometer/time-counter/reference-sweep trace IDs; `convertSegy` no longer duplicates the reader's diagnostics (found while fixing); `gh0N` names are refused; `positions` documented.
  - Not done (noted): coordinate units for geographic CRS (needs the 0x55 stanza parsed); EM channel types → SEG-Y 27-38 codes.
- 2026-11-07: **Session hand-off.** Phase 8 tasks 8.1-8.6 and the review are done. **Next: 8.8 (nimpy), then 8.9 (build targets), then 8.7 (SEG-D Rev 2 ↔ 3)**, then Phase 7 (the CLI, on the public API). Facts a new session needs:
  - **C ABI:** `src/parseSEGD/capi.nim` (exports use `{.exportc: "seg_x", capi.}`; `capi` = `dynlib, cdecl`, and `exportc` must come first). The header `include/parseseg.h` is curated by hand: add every new export there **and** to `seg_sizeof`/`seg_offsetof` plus `tests/c/abi_test.c` for each struct. `tests/tcapi.nim` fails if the header and the `.so` symbols differ.
  - **Build flags** (`nim lib`): `--app:lib --noMain --mm:atomicArc --threads:on -d:useMalloc`. Without useMalloc, host threads crash; without atomicArc, releases from several threads race.
  - **Exports must never raise:** wrap them in `guarded`, or mark them `{.raises: [].}`. Out-of-memory cannot be caught: the C backend's goto exceptions keep an OOM hook from raising, so bound sizes and probe with `canAllocate`. Don't use Nim locks or other module-init state in `seg_init` (it runs NimMain).
  - **8.8 plan:** replace `capi` with a define-switched pragma (`-d:segCapi` → exportc/dynlib/cdecl, `-d:segPython` → nimpy `exportpy`). Keep the shared implementation procs and thin per-target wrappers. Add nimpy with `atlas use nimpy` (or add it to the nimble file, then `atlas install` and `atlas pin`). numpy is not installed here (no pip), so test with `python3 -I` and skip the numpy checks.
  - **8.9 plan:** `staticlib` and `csources` were verified by hand (`--app:staticlib`; `--compileOnly --genScript` plus `nimbase.h`, built with gcc alone). There is no `make` in this container, so test a Makefile only through CI, or with a shell fallback.
  - **Test probes:** put them in `tests/probe_*.nim` (ignored by the runner) and delete them. Reviews put scratch files under `/tmp/claude-1000/`.
- 2026-11-07: Task 8.8 done: the Python module `parseseg` (nimpy 0.2.1 via Atlas). Design note: `docs/design/python.md`.
  - **One source:** `src/parseSEGD/abi/core.nim` holds the shared boundary implementation (handles, checks, limits, reads, prefetch, edits, journals, conversion options, DLPack); its procs raise. `abi/exporting.nim` defines `{.segExport.}` / `{.segExport: "name".}`: `-d:segCapi` → `exportc, dynlib, cdecl`; `-d:segPython` → `exportpy`; neither → nothing. `capi.nim` was rewritten as thin C wrappers (same symbols, statuses and messages; abi_test, the symbol check and the ctypes smoke pass unchanged, and so do ASan/TSan after a fix: `cast[pointer](fo.fileLog)` leaked the borrowed log's reference, because under ARC a cast of a call's `ref` result skips its destructor; bind to a local first) and now needs `-d:segCapi` (added to `nim lib` and tcapi).
  - **Python** (`src/parseSEGD/pyapi.nim`, `nim pylib` → `bin/parseseg.so`): objects `SeismicFile`, `Samples`, `Prefetch`, `Editor`, `Geometry` with `close()`/`with`; real exception classes (`parseseg.Error` > `ArgumentError`/`FormatError` (ValueError), `IOError` (OSError), `StateError`/`InternalError` (RuntimeError), `RefusedError`), made on first access through module `__getattr__`. The wrappers return raw `PPyObject` and set the exception themselves, because nimpy's own mapping makes a new uncatchable class per raise. `convert`/journal calls attach `e.diagnostics`.
  - Samples reach numpy zero-copy: `Samples.__dlpack__`/`__dlpack_device__` (a PyCapsule over the DLPack struct shared with C), `__array__`, `.numpy()`. `read_into`/`read_traces_into` decode into a caller's writable 2-D array (buffer protocol; strided rows allowed). Reads, open, convert, journals and `Prefetch.next` release the GIL, and a read holds a counted file reference so a concurrent `close()` cannot unmap it.
  - **nimpy bug** (unfixed upstream): a method's keyword arguments index past its argument-name list (`argsLen` counts `self`), so `f.read(0, 1, dtype="float64")` raised SystemError (and would read out of bounds under danger). `tools/patches/nimpy-method-kwargs.patch` (one line) is applied idempotently to `deps/nimpy` by `nim pylib` and `tests/tpython.nim`. Delete it when upstream fixes it.
  - Tests: `tests/tpython.nim` builds the module (checks on) and runs `tests/python/test_pyapi.py` with numpy and with numpy hidden; valgrind on the whole script reports no errors.
- 2026-11-07: Task 8.9 done (and ongoing: keep `config.nims`, `tests/ttargets.nim` and CI current when a target or flag changes).
  - `config.nims`: one target table (linux-x64/arm64 at glibc 2.28, windows-x64, macos-arm64/x64) and shared flags (`abiFlags`; `--tlsEmulation:off` on Windows, because emulated thread-locals break on host threads). Tasks: `lib`, `staticlib`, `pylib`, `libLinux`, `libWindows` (DLL plus import library), `libMacos`, `csources` (one bundle per triple: generated C, `nimbase.h`, header, a per-target Makefile and CMakeLists.txt with Nim's own C flags, README).
  - Cross-building found two bugs:
    - **`canAllocate` was optimized away by clang** (an unused malloc/free pair may be elided and assumed to succeed), so under zig cc, and natively on macOS, an over-large request killed the host. The probe now calls malloc through a volatile function pointer. The zig-built library now passes abi_test, including the RLIMIT_AS child.
    - On Windows, capi's `NimMain` import clashed with Nim's dllexport definition. It now uses a matching `codegenDecl`.
  - macOS without an SDK: Nim's `std/sysrand` (through Arraymancer → `std/random`) links `-framework Security`. `tools/macos-stubs/Security.framework/Security.tbd` (only `SecRandomCopyBytes`) satisfies the linker, and the dylib loads the real framework (install name `@rpath/libparseseg.dylib`). Built and checked here (exports, load commands), but **not run on a Mac**; the CI macOS job builds natively.
  - `tests/ttargets.nim` runs the tasks themselves:
    - abi_test passes against `lib`, `staticlib`, both libraries the linux-x64 bundle builds with `make` alone, and the zig linux-x64 build;
    - the release `pylib` imports and reads;
    - every cross build exports exactly the header's 58 functions (llvm-nm/llvm-objdump).
  - CI (`.github/workflows/ci.yml`, **not run yet**):
    - Linux: nim test with numpy and zig, then ASan/TSan, then every target, uploading host, cross and csources artifacts.
    - Native Windows and macOS: `lib`, `staticlib`, `pylib` and a Python smoke test, with uploads.
- 2026-11-07: Task 8.7 done: `src/parseSEGD/segd/revconvert.nim` (umbrella: `segdrevconvert`). The mapping tables are in its module doc.
  - `convertSegdRevision(src, sink, opts, scan)` / `(srcPath, dstPath, opts)` converts Rev 1/2.x → 3.0, Rev 3.x → 2.0/2.1, and within a layout (2.x → 2.y, 3.x → 3.0, format changes). It streams record by record.
  - **No format is "no longer defined":** every Rev 2 demux format exists in Rev 3 with the same encoding, so samples are copied byte for byte. Only 8080 (Rev 3 only) is re-encoded for Rev 2 (8058 by default), or a format the caller forces; re-encoded traces are compared and inexact ones counted in a warning.
  - **A header pre-scan** (`scanRecords`, headers only) is needed because a record's headers are written before its traces and trailer are read:
    - Rev 2 descriptors don't give sample counts exactly. The INOVA data has 0..4000 ms at 1 ms = 4001 samples, while (end − start)/interval = 4000. Rev 3 needs one count per set, and the scan takes it from the traces.
    - Rev 3 → Rev 2 needs the unwrapped trailer's block count in GH#2.
    - The file API always scans. The stream API (tape) falls back to the descriptors and notes it.
  - Rev 2 → 3:
    - GH#N becomes a Source Description (Vibrator 0x15 when the vibrator fields are set, else Other 0x1F).
    - GH#3 time zero comes from GH#1 (whole seconds).
    - The 96-byte CSD is filled from the 32-byte one: µs times, DSM = 2^MP, channel type n → n·0x10.
    - THE#1 carries the receiver fields and sample count.
    - The Rev 2 trailer travels in a user trailer group (0xA0 "SEG-D REV2 TRLR"), which unwraps losslessly on the way back.
    - Rev 2 extensions after #1 are dropped (they have no type byte).
  - Rev 3 → 2:
    - Source Descriptions become GH#N. Other general blocks are dropped, listed once by type, and GH#3 is dropped.
    - Blocks after THE#1 (INOVA's vendor 0xB0-0xB8 included) are kept as raw Rev 2 extensions, up to 14.
    - MP = log2(DSM), times are in 2 ms units, filters in BCD.
    - Unrepresentable records are skipped with an error: more than 9999 channels per set, a negative start time, an interval that is not BSI/2^k, more than 99 skew blocks, more than 65535 extended or external blocks.
  - Writer: `setRev3Trailer` (for a Rev 3 trailer known only after its traces).
  - **Fixed on the way:** `rev3.recordLengthUs` read GH#1's BCD record length as units of 0.5 × 1.024 s (5× too long); both revisions use RR.R × 1.024 s (regression test included).
  - C ABI: `seg_convert_segd(src, dst, rev_major, rev_minor, format, log)` (additive, so the ABI version stays 1). Python: `parseseg.convert_segd(src, dst, revision="3.0", format=0)`.
  - Tests:
    - `tests/tsegdrevconvert.nim`:
      - 63.sgd → 3.0 → 2.0, field by field;
      - 2.0 → 2.1 differs from the original in exactly one byte;
      - INOVA → 2.1 → 3.0 keeps samples and vendor blocks;
      - every Rev 2 format → 3.0 → 2.1, with GH#1, GH#N, CSDs, THE#1 and trailers byte-identical except THE counts;
      - tape with a label and no scan;
      - 8080 → 8058 (exact and inexact);
      - a forced 8038;
      - skipped records;
      - invalid requests.
    - The C test and the Python test cover the new export.
  - Gap noticed (not fixed): `recordField` has no names for GH#2 (`gh2.*`) in either revision, nor for Rev 3 general blocks.
- 2026-11-07: **Phase 8 review (8.7-8.9)**, by three parallel agents: SEG-D revision conversion; the Python module and shared core; build targets and CI. Everything they verified is fixed, with regression tests.
  - SEG-D conversion (`tests/tsegdrevconvert.nim`, "review" blocks):
    - **Within-layout conversions (2.x→2.y, 3.x→3.0) lost the general trailer.** The reader fills it only after the traces, so the output was fatal and truncated, or the trailer was silently dropped when the format changed.
    - **Rev 2 channel set numbers > 99 (FF + extended) became 0**, aborting the conversion. It now uses the resolving `channelSetNumber(d)`.
    - End-before-start descriptors raised a RangeDefect in the stream API.
    - **A trace naming no descriptor aborted the whole file.** The scan now counts such traces and the record is skipped with an error.
    - Extended record lengths over 71 minutes wrapped (now 64-bit, clamped and noted).
    - A NaN filter value aborted Rev 3→2.
    - Traces zeroed by an out-of-range value now get their own error.
    - Undefined Rev 2 channel types are noted.
    - 8015 padding copied stale samples.
    - 2.0→2.1 carried 2.0's undefined GH#2 bytes 21-22 into the line sequence number.
  - Python and C:
    - **A wrong object passed to `apply_geometry`** made nimpy raise an uncaught Defect that broke every later call in the process. The argument is now a PPyObject checked against the Geometry type.
    - **`component_groups(0, 2**40)` killed the process** (it allocated before checking the range).
    - **File maps were never unmapped**, in Python and in C: 100 opens left 100 mappings. This predates Phase 8. `SeismicFile` now owns its map through `MapOwner`, whose destructor unmaps, and `HeaderEditor`'s journal closes through `JournalFile`.
    - `read_into` leaked the fetched Python exception and traceback through nimpy's `getBuffer`. It now calls `PyObject_GetBuffer` directly, and a set Python error passes through as `PyErrorSet`.
    - Counts below −1 are refused.
    - `trace_field` out of range says "no trace".
    - `first + count` overflow in the C range checks now uses `rangeOk`.
    - Tests: `test_pyapi.py` covers all of these plus /proc maps and fd counts; abi_test has `test_release_unmaps`.
  - Builds (`tests/ttargets.nim`):
    - **macOS cross builds required macOS 15.** The targets are now `aarch64-macos.11.0` and `x86_64-macos.10.15`, checked through `minos`.
    - zig builds carried DWARF, a .pdb and local paths. They now use `-g0 -s`, target directories are cleared first, and a "no local paths" check runs.
    - **seg_init could call another Nim library's NimMain** through ELF interposition. Linux libraries now link with `-Bsymbolic` (zig lacks `-Bsymbolic-functions`) and an SONAME. A host test links a fake `libother.so` exporting NimMain; without the fix it prints OTHER.
    - The C bundles had this machine's compiler command in every .c file; it is now blanked in place (string slicing is too slow in the NimScript VM).
    - CMake defaults to Release and refuses MSVC.
    - Makefile: LDFLAGS hook, SONAME, a Windows import library, and `libparseseg.a` on Windows too.
    - CI: the no-op `nimpretty --check` is dropped, setup-python is used on Linux (PEP 668), Nim is pinned to 2.4.0, and the Windows build step runs under bash -e. README notes glibc and macOS minimums.
  - Not done (noted): Rev 3 general blocks have no `recordField` names. `__dlpack__` ignores numpy 2's `copy`/`max_version`, which can't be tested with numpy 1.24. The native Windows and macOS CI jobs don't run abi_test. TSan on ubuntu-24.04 may need `vm.mmap_rnd_bits=28`.
- 2026-11-07: Tasks 7.1, 7.1b and 7.3 done together: one CLI module, so one commit. The CLI is `src/parseSEGD/cli.nim`, built with `nim cli` → `bin/parseSEGD`. The template build modes (nimRelease, zigRelease, ...) now build it; before, they compiled the umbrella library as a program. It uses only the public API (umbrella).
  - **7.1:**
    - `info` (`--keys` adds gathers);
    - `dump` (`--traces` = 5 | 0..9 | 1,4,7; `--fields`; `--all`);
    - `diag` (`--nif`, `--min`);
    - `convert`: to SEG-Y, or to SEG-D with `--to=segd`, which is also the default when both names end in .sgd/.segd. Options: `--rev`, `--format`, `--byte-order`, `--text`, `--descale`, `--no-station-header`.
    - Exit codes: 0 ok, 1 errors in the log, 2 usage.
    - The CLI has its own small argument parser: `--k=v`, `--k:v`, `--k v`, `-o v`, flags. std/parseopt reads the process's own command line when given an empty list, and doesn't take `-o path`.
  - **7.3:** `src/parseSEGD/model/headernif.nim` (umbrella).
    - `exportHeaders(f, path, raw)` streams every named field as NIF through `nifbuilder.open(path)`: file `binary`, record `gh1`/`gh3+`, trace `trace`/`ext1`, plus raw hex per block and per trace header.
    - `diffHeaders` and `importHeaders(path, nif, outPath, journal, dryRun)` apply a document as a patch: only changed fields, through the journaled editor, in place or into a copy (`outPath`).
    - Floats are written shortest round-trip, so an unedited export re-imports as 0 changes.
    - `nifreader.open` calls `quit` on an unreadable file, so the file is opened first.
    - CLI: `edit <file> <scope>:<block>.<field>=<value>...` (scope t5 | t0..9 | r0 | file; values int, then float, else text, `"..."` forces text); `headers export|import`; `journal apply|rollback`.
  - **7.1b:** `src/parseSEGD/vendor/scaffold.nim` (umbrella).
    - `scaffold(path, reg)` finds the vendor areas that no loaded map decodes:
      - SEG-D extended and external blocks;
      - Rev 3 user or undefined blocks in the general and trace headers;
      - Rev 2 trace extensions #2 and later;
      - SEG-Y unassigned binary and trace bytes when not all zero, and proprietary trace headers.
    - For each area it compares every occurrence and `toNif` writes a skeleton map that loads: runs of bytes that are constant (value in a comment), vary, or look like text.
    - Comments go on lines of their own, because a `;` comment runs to the end of the line.
    - `maps.applies(m, ctx)` is now public.
    - CLI: `vendormap check|list|apply|scaffold` (with `--map`).
    - The INOVA sample scaffolds 122 areas, including the 9 trace blocks 0xB0-0xB8. The skeleton checks ok and `apply` decodes them; scaffolding again with it finds nothing unmapped.
  - Tests: `tests/tcli.nim` builds the CLI and runs every command on the samples, covering outputs, written files, journals, bad input and exit codes.
- 2026-11-07: Task 7.2 done.
  - README: rewritten introduction (Nim, CLI, C and Python entry points), CLI examples, the real directory layout, and the build modes now building the CLI.
  - `docs/api.md`: SEG-D revision conversion, header NIF documents, vendor scaffolding, files that unmap themselves.
  - CI: builds `nim cli` on every OS, smoke-tests it on Windows and macOS (`info`, `convert`), and uploads it with the libraries.
- 2026-11-07: **Phase 7 review**, by two parallel agents (the CLI; header NIF and scaffold). Everything they verified is fixed, with regression tests: "review" blocks in `tests/tcli.nim` and the new `tests/theadernif.nim`.
  - Data safety:
    - **`headers export -o <input>` and `vendormap scaffold -o <input>` overwrote the seismic file**, and `import -o <document>` overwrote the patch. All are refused (CLI `refuseSame`, `exportHeaders`, `importHeaders`).
    - **`-o` with no value silently edited in place.** Value options now need a value, and flags take none.
    - **`edit` wrote the assignments before a bad one.** Every assignment (syntax, scope, selection, field) is checked against a read-only open first.
    - A journal that is the data file is refused (`openEditor`).
    - **A failed convert emptied an existing destination**, or left a partial file. `convertFile` and `convertSegdRevision(path)` now write `<dst>.tmp` and rename only on success (`convert.finishOutput`).
    - An import into a copy appended to a stale journal; it now starts a fresh one, and a copy is made even when nothing changes.
  - Header NIF, rewritten I/O:
    - **A malformed document could kill the process.** nifreader `quit`s on an empty or unmappable file and on out-of-range line info, and asserts on `1E`. Import now uses its own strict streaming tokenizer, which bounds depth, strings and numbers and only raises SegFormatError.
    - **Export held the whole document in memory** (nifbuilder writes only at close). It now streams through a 1 MB buffer into `.tmp`, then renames.
    - Import applies each entry as it is read, through a batched editor, so the last entry wins.
    - Floats compare by bit pattern (-0.0 ≠ 0.0, NaN = NaN). An integral float on an integer field is no change.
    - **A document for another file** (standard, trace or record count) is refused unless `force` (`--force`).
    - Entry errors are capped at 50 plus a count. Applied and refused edits are counted separately. Messages carry the document path and a 1-based line.
    - The API is `importHeaders(path, nif, ImportOptions(outPath, journal, dryRun, force, onChange)): ImportResult`.
  - Editor: `beginBatch`/`endBatch` gives one journal fsync per up to 4096 edits; a pending write that overlaps flushes first, and index copies refresh after a flush. Before, it was about 5 ms per edit, over an hour for a million. `currentField`/`currentRecordField`/`currentFileField` read edits made so far.
  - Scaffold:
    - Proprietary header names are now written exactly (NIF `\HH` escaping). Names are matched without their space/NUL padding on both sides (`maps.headerKey`). Target names are reduced to identifier characters.
    - Comments are sanitized.
    - An empty scaffold writes nothing.
    - Every unassigned binary range is covered: 3261-3500 and 3507-3600 for Rev 0/1; 3301-3500 and 3533-3600 for Rev 2. Trace bytes are 181-232 for Rev 2.
    - Areas are looked up in a table, so the scan is no longer quadratic.
  - CLI:
    - `--rev` is strict (0..255 parts, the right number of them).
    - Selections are checked before they are expanded (`0..99999999999` exhausted memory), and `5..2` is an error.
    - The output kind follows the input's content, and `--to=segd` on SEG-Y is refused.
    - A text field takes number-like values as text.
    - `dump` exits 1 on index errors or unknown fields, `info` prints fatal messages, and directory and unreadable-file messages are clearer.
    - `vendormap list` names the `--map` paths, `scaffold` returns its status, and `apply` prints valid NIF strings.
    - Options may come before the command.
  - Not done (noted): a scaffold for files with thousands of extended blocks can exceed the map loader's 1 MB limit. `vendormap apply --traces` counts readTrace calls (fine unless the file is damaged).
- 2026-11-07: **Session hand-off.** Phases 8 and 7 are done, and both reviews' fixes are committed. **Next: Phase 9** (rename the project to parseSEG; the repository rename is an owner action), then Phase 10 (survey files; the owner needs to supply the P1/SPS specs). Open items: tasks 1.7/1.8 (Rev 3.1 and older-revision spec notes); `recordField` names for GH#2 and Rev 3 general blocks; the CI workflow has never run on GitHub; the macOS builds have not run on a Mac. Notes for the next session:
  - Python module: `nim pylib`; the nimpy patch in `tools/patches/` is applied automatically.
  - CLI: `nim cli`.
  - Every build target: `tests/ttargets.nim`.
  - `nim test` takes about 3.5 minutes.
- 2026-11-07: Phase 9 done (task 9.1): project renamed to parseSEG; `nim test` passes. Historical log entries keep the old name. Owner actions: rename the working directory and the GitHub repository (then update the git remote URL). **Next: Phase 10** (needs the P1/SPS specs from the owner).
- 2026-11-07: Tasks 1.7-1.9 and 10.1 done. The owner added the original SEG-D and SEG-Y (Rev 0), SEG-2, SPS (1993, 2.1) and SEG P1-P4 (1983) PDFs. They were extracted, and five parallel agents wrote `segd_rev0.md`, `segy_rev0.md`, `segd_rev3_1_delta.md`, `segy_rev2_0_delta.md`, `seg2.md`, `sps.md` and `p1_p2_p3.md`.
  - The revision notes end with gap analyses (file:line), which drive tasks 3.5, 4.6, 4.7 and 5.5.
  - Findings:
    - SEG-D 3.1 adds only the little-endian formats 9036/9038/9058/9080 and P1/11 CRS text. There are no rotational sensor types.
    - SEG-Y 2.0 differs from 2.1 only in bytes 3507-3510. Our reader treats revision bytes `00 02` as Rev 0.
    - The SEG-D Rev 0 text mis-cites itself as 1975; it is c. 1980.
    - The 1983 positional document defines P1-P4, where P3 is land survey observations and P4 is Transit Doppler. Only P1 carries joinable positions.
- 2026-11-07: Tasks 10.2 and 10.3 done: survey files, in `src/parseSEG/survey/` (umbrella).
  - `textrec`: card-image records from LF/CRLF lines, fixed 80-byte ASCII, or EBCDIC, streamed. FORTRAN `Iw`/`Fw.d` fields (implicit decimals unless a `.` is written).
  - `sps`: `readSps`/`writeSps` for Rev 1.0 and 2.1 (H/R/S/X/C).
    - The revision comes from H00, else a column-layout vote.
    - Every record keeps its raw text, so unchanged records are written back byte for byte (CR LF kept). Edited records are re-encoded.
    - 1.0 ↔ 2.1 conversion is lossless where values fit. A value that doesn't fit is an error and nothing is written, unless `lenient`.
    - Decisions (sps.md §11): F10.2 without a `.` is an integer, with `strictImpliedDecimals` as an option; 1.0 names stay text plus a numeric value when they are numbers.
  - `p1`: `readP1`/`writeP1` for 1983 P1 (decoded: DMS or grads, hemispheres, implicit-decimal grid and depth, 2-digit years pivoted at 50). P2-P4 are detected and kept raw. Header blocks are padded to 20 on write.
  - `join`: `SurveyGeometry` with `addSps`/`addP1`, `relation(record, channel)` and `applySurvey(keys or index)`.
    - X records are kept as runs and receivers are interpolated, ascending or descending. `multiComponent` makes an increment k mean k components per station. An optional `tape` filter selects X records; overlapping runs get a warning.
    - Text line names go through `LineNames` (a map, then optional trailing digits).
    - P1 reshoot codes become point indices (blank 0, A 2, B 3, ...).
  - `TraceKeys.channel` (SEG-Y bytes 13-16, SEG-D trace number) carries the join.
  - Station keys are rounded to 1/100, and a trace without a point index also matches index 1.
  - C: `seg_geometry_load_sps|load_p1|map_line|set_options|counts`. `seg_file_apply_geometry` applies relations too.
  - Python: `Geometry.load_sps|load_p1|map_line|set_options|counts`.
  - CLI: `survey <file> [-o] [--rev]`, `keys <file> [--traces]`, and SURVEY options on `info`/`keys` (`--sps`, `--p1`, `--decimals`, `--elevation`, `--line-map`, `--trailing-digits`, `--multi-component`, `--overwrite`).
  - Tests: `tests/tsurvey.nim` (records rebuilt at exact columns from the spec examples), plus survey blocks in abi_test, test_pyapi and tcli.
- 2026-11-07: Task 5.5 done: SEG-D Rev 3.1.
  - Formats 9036/9038/9058/9080 (little-endian twins of 80xx) are decoded and encoded (`isLittleEndian`, `bigEndianOf`), so 3.1 files are detected, indexed and read.
  - Revision 3.1 is read without the "read as 3.0" warning.
  - A 90xx code in a record that says 3.0 is decoded with a warning (also in Rev 2). Writers refuse it unless lenient.
  - `convertSegdRevision` targets 3.1. Before 3.1, 90xx maps to 80xx (and 8080 to 8058 for 2.x). An explicit format must exist in the target. The INOVA file converts 3.0 → 3.1/9058 → 3.0 byte-exactly.
  - `crsFormat(crsText)` tells P1/11 CRS text from SEG stanzas. A P1/11 parser is not written (noted).
- 2026-11-07: Task 3.5 done: SEG-Y Rev 0 and 2.0, from the gap analyses.
  - Revision bytes `00 02` (2.0 as a swapped u16) are Rev 2.0, including the u32 at 3507-3510.
  - A claimed Rev 1/2 whose fixed-length flag is not 0/1, whose extended count is below -1, or (Rev 2) whose byte-order marker is neither the marker nor 0 is taken as vendor data in a Rev 0 header. That is a warning, and the file is read with Rev 0 rules.
  - `((SEG:EndText))` is required (reader warning, writer problem) only from 2.1.
  - Converting to 2.0 notes a dropped survey type and a Layout stanza 2.0 does not define.
  - Rev 0 traces whose bytes 115-116 are 0 take the binary header's sample count, with a warning.
  - Format 4 (fixed point with gain) can be encoded: the largest gain that fits, value = mantissa × 2^-G. Conversions may target it.
  - Not done (noted):
    - parsing the 2.0 `Trace Header Mapping` stanza;
    - a reader option for the format 4 gain sign (the raw bytes are kept);
    - Rev 0 trace lengths from tape record lengths;
    - limiting byte-order scoring to bytes 3201-3260 for Rev 0.
- 2026-11-07: **Phase 10 review** (task 10.4) by an agent: 9 confirmed findings plus suspicions. The fixes follow in the next commit.
- 2026-11-07: Task 10.4 done: the Phase 10 review's findings are fixed, with regression tests in the "review" blocks of `tests/tsurvey.nim` and `tests/tcli.nim`.
  - **A non-P1 line inside a P1 file was rewritten as a record at 0N 0E** with a NUL. It is now kept raw.
  - **A 1.0 H00 date such as `SPS001,12.10.90` was read as Rev 2.1.** The marker is now matched with its `SPS` prefix.
  - **`std/streams.readLine` lost data:** a NUL at a line start ended the file, and CR-only files lost a character per line. `textRecords` now has its own splitter:
    - LF, CR LF or a lone CR end a line, and NUL is data;
    - CR LF detection is exact;
    - `terminated` tracks the final newline;
    - lines over 64 KB are cut and reported.
  - `survey` picked the reader by column 1 of the first line, which failed on EBCDIC/fixed SPS and on P1 headers starting with R/S/X/C. It now uses `looksLikeSps`, which judges by data-record shape.
  - P1: a header line starting with a digit stopped all decoding. Detection now uses the first record matching any format. Editing `point` was ignored.
  - Round trips:
    - P1 headers are no longer padded by default.
    - The read options (P1 decimals, SPS strict mode) are kept on the file and used by the writers.
    - A missing final newline is kept.
    - Unchanged records are found with `sameValues` (NaN = NaN) rather than by re-encoding, so an unchanged record that would not encode (e.g. `H` with no code) is written back as read.
  - Overflow (1e300, Inf) is an error, where before it was written as a blank.
  - Stale `order` entries are an error, where before they raised an IndexDefect.
  - Point indices clamp to int16.
  - The ABI's geometry log no longer grows across loads.
  - CLI: `keys` on a file with 0 traces; `--rev` without `-o`, `--decimals` on SPS, and a non-finite `--line-map` are usage errors.
  - Not done (noted):
    - Python `load_sps`/`load_p1` hold the GIL while reading.
    - Join diagnostics name the record's list index, not its line.
    - A 1.0 file without H00 whose votes tie is read as 2.1.
- 2026-11-07: Task 4.6 done: demultiplexed SEG-D Rev 0.
  - Revision detection already worked: one general header (GH1 byte 12H = 0), no GH#2, revision 0.0. A test now covers it.
  - The "array forming 0" note is gone for Rev 0, whose CSD bytes 27-32 are unused.
  - GH1 `bytesPerScan` (bytes 20-22) and `scansPerBlock` (bytes 24L-25) decode the multiplexed fields that task 4.7 will need.
  - Converting Rev 0 to 2.x or 3.0 writes vertical stack 1 and array forming 1 instead of copying 0s, which mean "zeroed data" and "undefined" from Rev 1 on, and zeroes the GH1 multiplexed fields for 2.x.
  - Not done (noted): writer checks for Rev 0-only formats; trace lengths from tape block lengths.
  - Multiplexed data is task 4.7.
- 2026-11-07: **Session hand-off.**
  - Done: Phase 10 (survey files, reviewed), tasks 1.7-1.9 (spec notes for every new PDF), 3.5 (SEG-Y Rev 0/2.0), 4.6 (SEG-D Rev 0 demux) and 5.5 (SEG-D 3.1).
  - Open:
    - **4.7, multiplexed SEG-D.** It needs a design decision: multiplexed samples are interleaved across scans, so a trace has no contiguous byte range for `TraceEntry`. Options: (a) demultiplex once into a temporary demux file and index that; (b) a scan-strided `TraceCodec` that reads one sample per scan; (c) reader-only (streaming `readSegd`) without the index.
    - Phase 11 (SEG-2).
  - Owner: real SPS/P1 and SEG-2 files, and a multiplexed SEG-D file, would let these be verified.

- 2026-11-07: Owner rule added to "Owner decisions": files change only on an explicit write. Confirmed that `applySurvey`/`applyGeometry` only change in-memory `TraceKeys`, and `openSeismic` maps read-only unless `writable = true` (`HeaderEditor`). New tasks: 6.8 `FileSummary` (format-independent metadata) and 6.9 trace time in `TraceKeys` (so viewers need no per-format branches); 10.5 explicit, journaled write-back of joined geometry. Still open: 4.7 (needs a decision), Phase 11.
- 2026-11-07: 4.7 decided by the agent as a default (the owner had no preference): demultiplex into a temporary demux file on open, original never touched; rationale and costs in the 4.7 entry. Revisit if a real multiplexed file shows a problem. Also confirmed for the owner: `readTraces` decodes into a new tensor (a copy), so processing never touches the mapped file.
- 2026-11-07: Closed the raw-memory hole (owner rule: files change only on an explicit write). `SeismicFile.memory` is now `unsafeMemory`, internal and not exported by `parseSEG` (`export traceindex except unsafeMemory`); a write through it on a `writable` map would have bypassed the `HeaderEditor` journal. Public replacements: `isOpen` and `copyBytes(offset, n)` (a bounds-checked copy). `tumbrella` checks that the pointer is not reachable. C ABI and Python never exposed it. `nim test` passes; lib/pylib/cli build.
- 2026-11-07: Task 6.10 added: read-only header listing per trace/record/file for a viewer's headers tab. Owner rule recorded: viewers never edit files; viewer edits become a NIF patch (`writeHeaderPatch`), applied only by an explicit `importHeaders` (dry run first, preferably to a copy).
- 2026-11-07: Phase 12 added (owner): idiomatic Nim pass. 12.2 generates the C shims, the nimpy exports and `parseseg.h` from one annotation on the `abi/core.nim` procs (evaluate genny first), replacing the hand-written adapter files (64 C / 71 Python exports) and the hand-written header. Suggested order: 12.2 before 6.8-6.10 and 10.5.
- 2026-11-07: Owner chose to start Phase 12 with 12.2 (bindings from one `{.segApi.}` proc). Decisions: generated ctypes Python over the one shared library (nimpy dropped), C ABI v2 with a uniform convention, genny evaluated and not used. The design is in the 12.2 entry. Nim 2.4 `--ic:on` is broken in this container (musl `nifler`; a source build still fails), so it is opt-in.
- 2026-11-07: **12.2 done (bindings from one declaration).**
  - `src/parseSEG/abi/api.nim` holds every C/Python function once, as an ordinary Nim proc with `{.segApi.}`. `abi/segapi.nim` is the generator:
    - an untyped pragma passes the signature to a typed macro, which sees resolved types and defaults;
    - it emits the C export (argument checks, enum checks including struct fields, handle lock unless `concurrent`, exception → status, out-pointers);
    - it emits the header declaration (doc from `##`) and the Python function;
    - `static:` blocks let Nim itself render enums, struct layouts and Python default literals;
    - struct and field docs are read from the declaring source via line info, because `repr` merges a type's doc into its first field.
  - Generated and committed: `include/parseseg.h` and `python/parseseg/__init__.py`. Hand-written parts are in `abi/gen/`: header prose, the Python runtime, and the Python extras (DLPack capsule, `__array__`, buffer protocol via `PyObject_GetBuffer`).
  - ABI v2 follows the table in `docs/design/c_abi.md`. New in it: `SEG_ERR_MEMORY`; `SegSampleBuffer`; text into caller buffers (no borrowed strings except log entries); owned logs (`seg_file_diagnostics`); `close` separate from `release`.
  - Python is now ctypes over the one library. The GIL is released on every call. Calls in flight are counted, so `close()` from another thread never frees under a call. `test_pyapi.py` passes unchanged except the ABI version, with and without numpy (numpy via `PARSESEG_NUMPY_PATH`).
  - Removed: `capi.nim`, `pyapi.nim`, `abi/core.nim`, `abi/exporting.nim`, `tests/python/smoke.py`, the nimpy requirement and its patch.
  - Tests: `tcapi` checks the committed generated files against a fresh build, and `abi_test.c` was rewritten for v2 (adds serialized same-handle calls from 4 threads). CI runs `git diff --exit-code` on the generated files after building every target.
  - Build: entry `src/parseSEG/bindings.nim`; `nim pylib` makes `bin/python/parseseg/`; release tasks use a fresh `nimcache/release-<task>` with `--ic:off`; `PARSESEG_IC=1` gives dev builds `--ic:on`. IC is not usable in this container.
  - Found while porting: an invalid enum in a C struct argument (`SegSampleBuffer.dtype = 9`) was read as float64. Struct enum fields are now checked.
- 2026-11-08 — Task 12.5 done (ABI v3, package 0.3.0): the C and Python names derive from the Nim core.
  - Owner: names come from the core, renaming the core where needed; Nim first. Asked whether nimpy/genny duplicate this: genny lists exports in its own DSL, catches one exception type, makes duplicate names for overloads, and has no locking or zero-copy; nimpy is Python-only and keeps the GIL. The owner chose to keep the generator (option 1).
  - `{.segApi.}` / `{.segHandle.}` / `{.segField.}` (`abi/pragmas.nim`, std-only) now sit on the core. They record typed signatures in a `macrocache` table (`varargs[typed]` yields the overload set), and `segFinish` in `api.nim` generates everything. `api.nim` keeps only the dtype-erased `Tensor`/`Prefetcher` adapters, the reads, DLPack and the version and status calls. A compile-time check ties every adapter to a core routine with the same parameter names, and the adapter takes that routine's doc.
  - Structs are generated C mirrors with `toC`/`fromC`, so core layouts are free. `seg_init_<struct>` and Python default dicts are generated only for structs that are parameters.
  - Core changes:
    - `Slice[int]` ranges named `traces` everywhere;
    - `setTraceField`/`setFileField`/`currentTraceField`;
    - `SurveyGeometry` absorbs `LineNames` (`lineNames`, `trailingDigits`, `mapLine`, `addSps(path)`, `addP1(path)`, counts);
    - `SeismicFile` accessors (`recordCount`, `maxSamples()`, `traceEntry`, `traceKeys`, `hasKeys`, `gathers`, `componentGroupIds`, `applySurvey`), raising `traceField`/`recordField`/`fileField`, and `skUnknown`;
    - `ValueError` instead of `doAssert` for bad input at public entry points, with Slice checks safe against overflow;
    - `DiagLog[]` checks its index.
  - Departures from the design:
    - `SeismicFile.close` is not exported: a prefetcher shares the map, and exporting it crashed the Python test (release unmaps).
    - Refused edits are `false` results, as in Nim, so `SEG_ERR_REFUSED`/`RefusedError` are gone.
    - Missing keys is `SEG_ERR_ARGUMENT`, and `SEG_ERR_STATE` stays reserved for Python's closed objects.
  - Found by the new tests: `componentGroupIds` allocated before checking its range, and hostile C ranges (`INT64_MAX`) overflowed `Slice.len`. Both are fixed.
  - Tests: new `tcoreapi`; `abi_test.c`, `test_pyapi.py` and the `ttargets` host were rewritten for v3. Docs `c_abi.md`, `python.md` and `api.md` were updated.
- 2026-11-08: Task 12.1 done: an idiomatic-Nim audit by 4 read-only agents. The findings are in the 12.1 entry: A, 8 bugs to fix first (an index deep copy per `sampleIntervalUs` call, stale Source Description accessors, stale version strings, a vendormap last-root bug, handle leaks, a writer `doAssert`, a hex message, Defect catching at the C boundary); B, 12 internal groups; C, 12 public API groups awaiting owner approval. Next: the owner approves or rejects C1-C12, then 12.3 (A, then B, then the approved C, one module per commit).
- 2026-11-08: **Task 12.3 done.** All A, B and C findings applied in 20 commits, with the full suite green before each. Four agents worked sequentially, by module group. **ABI v4, package 0.4.0.**
  - Bugs (A): the per-call `TraceIndex` copy; stale Source Description accessors; one `PackageVersion` (`version.nim`, read from the nimble file); a second `(vendormap)` root is an error; handle leaks; the tape-label `doAssert`. Override methods declare `raises: [CatchableError]`, so the C boundary no longer catches Defects or bare `Exception`.
  - Data model: `SegdRecord`/`SegdScanType`/`SegdTrace` are case objects on `SegdLayout` (`slRev2` covers Rev 0-2, `slRev3`). Optional parts are `Option` (`gh2`, `ext1`, `format`, `label`; `SegyFile.format` too).
  - Lookups: raising forms plus `find*`/`Option` (`findTraceField`, `findChannelSet`, `fieldByName`, `toSampleFormat`, `toSegdFormat`, `maps.decode`, `resolveLine`, `relation`); `detectKind` returns `SeismicKind`.
  - New internal modules:
    - `common/outputfile.nim`, `common/niftext.nim`, `common/diagcodes.nim`, `common/seismickind.nim`;
    - `segd/blocks.nim` (one `decodeBlock`);
    - `survey/cards.nim` (the card helpers, no longer re-exported);
    - `abi/runtime.nim` (split from the generator, which now keeps one `Bindings` state).
  - Behaviour:
    - bad caller input raises `ValueError` everywhere;
    - a journal sync failure refuses the edit, and the map is not written;
    - a log-less `readTraces` raises on an undecodable trace, and `readTraces(..., log)` records it;
    - `PrefetchChunk.log` holds one error per failed row.
  - C/Python (v4):
    - `seg_prefetcher_positions` → `seg_prefetcher_len` (Python `len(p)`);
    - `trace_at` and `sample_interval_us` give `SEG_ERR_ARGUMENT` for bad input;
    - `read_traces` gives `SEG_ERR_FORMAT` on an undecodable trace;
    - `open_editor` with the journal equal to the file gives `SEG_ERR_ARGUMENT`;
    - `SegConvertOptions.format` / `SegSegdConvertOptions.format` are enums (`SEG_SEGY_TARGET_FORMAT_*`, `SEG_SEGD_TARGET_FORMAT_*`; Python `"keep"`, `"5"`, ...).
  - Renames: the full old → new list is in the commit messages and `docs/api.md`, e.g. `decodeEbcdic`, `entriesFor`, `bytePos`, `text=`, `gh2Rev3`/`descriptorsRev3`/`ext1Rev3`, `scaffoldVendorMap`, `vendorContext`, `encodeSps`/`encodeP1`, `FieldValue.intVal/floatVal/text`, `SegyData.log`/`SegdData.log`.
  - Left (minor): a few `31`/`95` byte offsets in vendor apply/scaffold; markdown table rows over 100 columns in two module docs; the lowercase and uppercase hex helpers in edit/headernif; nested capturing procs in `writeSps`. Next: 12.4 (review by an agent).
- 2026-11-08: **Task 12.4 done; Phase 12 complete.** Three read-only reviewers (segd/vendor/convert; model/survey/cli; common/io/abi/segy plus the C/Python surface) found no high-severity regression in 12.3. Their 21 confirmed findings were fixed in 4 commits (8c385b1, a8ef4cb, 5b94379, 482ce24), with the full suite green.
  - Journal safety:
    - the journal is unbuffered;
    - a refused batch's entries are cut back with `ftruncate` (`_chsize_s` on Windows, compiled but not run);
    - if the cut fails, the editor refuses every later edit.
  - `HeaderEditor.close` raises `IOError` for a lost final batch. `current*Field` raises `IOError` for a sync failure.
  - `importHeaders` moves dropped edits from `applied` to `refused`.
  - Linux-only tests use `/dev/full` and `RLIMIT_FSIZE`.
  - SEG-D:
    - a lenient write of a record without a format, or with a mixed layout, no longer raises a Defect;
    - the reader resets its record before GH#1;
    - `computeRev3Sizes` refuses Rev 0-2 records.
  - SEG-Y:
    - a lenient write zeroes a partial last sample;
    - `SegyReader` uses `PushbackInput`.
  - Export/`dump` decode each block once.
  - C/Python (still v4, unreleased):
    - `SEG_SEGY_TARGET_FORMAT_*` values are the format codes (15 and 16; 13 and 14 are refused), and the generator handles enums with holes;
    - Python's `SegTensorView` no longer gets an invalid dtype default.
  - Decisions:
    - `DiagLog[]` keeps Nim's `IndexDefect` convention, and the generated C wrapper checks the index (`c_abi.md` says so);
    - an empty trace span must start in `0..len`;
    - CLI `convert --format=0` keeps the SEG-Y format, as it does for SEG-D.
  - Open from Phase 12: the minor items listed in the 12.3 log entry.
  - Still open from earlier phases: 4.7 (multiplexed SEG-D), Phase 11 (SEG-2), 6.8-6.10 and 10.5.
- 2026-11-08: Tasks 4.7 and 11.1 done, by parallel agents in worktrees, merged into `seg-library`.
  - 4.7 (multiplexed SEG-D, option (a)):
    - The reader walks scans for 0015, 0022, 0024, 0036, 0038, 0042, 0044, 0048 and 0058 and returns demux traces in the twin format.
    - 0015 is transcoded exactly to 8015.
    - `demultiplexSegd` writes a demux copy.
    - `openSeismic` indexes a temporary copy in `demuxDir` (`demuxPath`, a `dcMultiplexed` warning) and deletes it on close.
    - `writable` and the editor refuse multiplexed files.
    - C `seg_seismic_file_demux_path`, Python `demux_path`.
  - 4.7 decisions:
    - When the channel-set window disagrees with the scan count, the copy gives the traces a THE#1 with the sample count.
    - Temp names avoid `std/tempfiles`, whose random source breaks the macOS zig build.
    - The copy's log replaces the original walk's log.
    - Rev 2 multiplexed records get a warning; Rev 3 multiplexed records are fatal.
  - 4.7 not done: multiplexed output, resync after a corrupt scan, real tape and Rev 1 GH2/trailer cases. Synthetic tests only (`tsegdmux`).
  - 11.1 (SEG-2 reader, `src/parseSEG/seg2/`):
    - Memmapped and detected by `openSeismic`.
    - Index, `readTraces`, keys, gathers and prefetch work.
    - The index holds one codec per sample format; trace strings are re-read on demand (`seg2Trace`).
    - Bad pointers keep the trace number with `valid` false and a zero row.
    - Keys map SHOT_SEQUENCE_NUMBER, CDP, CHANNEL_NUMBER, the locations (+DATUM) and the geophone components.
  - 11.1 risks:
    - No real file, so the string-offset base and the format-3 bit layout are inferred (`seg2.md` §8).
    - Mixed sample intervals are not resampled.
  - Refused for SEG-2 until 11.2: named header fields and edits, header export, convert, vendor maps, CLI convert and vendormap.
- 2026-11-08: Tasks 6.8-6.10 done (agent, worktree), merged with 4.7 and 11.1. SEG-2 was then added to the merged summary, time and listing by the lead.
  - 6.8 `f.summary` (`FileSummary`), plus `channelSets` and `crsText`:
    - C names follow the 12.5 derivation: `seg_seismic_file_summary`, not `seg_file_summary`. CRS text is a separate call.
    - NaN or -1 mean not uniform.
    - Units come from SEG-Y trace 89-90, then binary 3255, then the CRS. The CRS units rule is a heuristic (the P1/11 HC,1,6,1 axis unit).
    - SEG-2 summary: UNITS, SAMPLE_INTERVAL and SHOT_SEQUENCE_NUMBER.
  - 6.9 `TraceKeys.time` (UTC POSIX seconds):
    - SEG-Y time basis 0 is read as UTC, GPS is converted with leap seconds, and local/other are NaN.
    - SEG-D Rev 3 uses the 0x42 Timestamp, then GH#3, then GH#1.
    - SEG-2 uses ACQUISITION_DATE/TIME.
  - 6.10 listing and patches:
    - `traceHeaders`/`recordHeaders`/`fileHeaders` return a `HeaderListing` of `HeaderRow`; C `seg_header_listing_len`/`_get`; `fieldNames` on the boundary.
    - `HeaderPatch` and `writeHeaderPatch`; CLI `dump --all` and `--records`/`--file`.
    - 14 new `HeaderBlock` kinds (listing only: import refuses patches to them) and `hbRaw`.
    - The generator gained borrowed `SegValueRef` fields and NUL-separated `seq[string]`. The `upperSnake` fix changes no existing constant.
    - SEG-2 blocks are listed raw for now (11.2 adds the keyword rows).
  - Follow-ups:
    - `importHeaders` is not on the C/Python boundary (its closure parameter), so hosts apply patches with the CLI.
    - `theadernif` `failed_journal_syncs` fails when TMPDIR is long (the session line exceeds its 100-byte RLIMIT).
- 2026-11-08: Task 10.5 done (agent, worktree `wt-geom`, merged).
  - API (`survey/writeback.nim`):
    - `GeometryFields`: sourceXy, receiverXy, elevations, midpoints, offsets, stations.
    - `writeGeometry(editor, ix|f, fields)`, journaled.
    - `geometryChanges` and `previewGeometry`: dry runs.
    - `copyWithGeometry` and `convertWithGeometry`, into a new file.
    - C `seg_header_editor_write_geometry` and the others, Python `write_geometry`.
    - CLI `survey-apply <file> SURVEY [-o out | --in-place] [--values=...]`. It reports only, unless given `-o` or `--in-place`.
  - Rules:
    - Only values that differ from the headers are written; NaN never is. A second run writes nothing.
    - SEG-Y slots come through the layout (coor4 share `co_scal`, elevations `ed_scal`). Station names are written only where a Layout stanza defines them.
    - The scalar: the file's own if exact, else the coarsest exact, else the finest that fits (warning). Overflow is refused.
    - SEG-D Rev 1/2: THE#1 receiver line, point and index.
    - SEG-D Rev 3: THE#1, plus existing Position and Source Description blocks only.
    - Values with no slot (record-level sources) are reported once per kind.
    - SEG-2 is refused. `--in-place` refuses multiplexed SEG-D; `-o` writes a demux copy.
  - Untested:
    - Windows: the file is mapped twice in `writeInPlace`.
    - A Rev 1 target that skips traces with more than 65535 samples.
- 2026-11-08: Task 11.2 done (agent, worktree `wt-seg2w`, merged). Full suite green on `seg-library` (40 test files).
  - Writer and header access:
    - `openSeg2Writer` / `writeTrace` / `close`. `close` patches N and the pointers. Non-standard output raises `SegFormatError` unless `lenient`.
    - Named fields `file.<field|KEYWORD>` / `trace.<...>` (`hbSeg2File`/`hbSeg2Trace`).
    - Listing rows per fixed field and per keyword string (with byte spans).
    - `exportHeaders`. In-place edits are refused, because strings are variable length.
  - Conversion: `ConvertOptions.target` (`skSegy`/`skSegd`/`skSeg2`) plus `segd`/`seg2` options.
    - Any input → SEG-Y; SEG-2 → SEG-D (one Rev 3 record, Rev 2.x via `convertSegdRevision`); any input → SEG-2.
    - SEG-Y → SEG-D stays refused.
    - CLI `convert --to=seg2`; `info` shows SEG-2 strings.
  - C `seg_seismic_file_seg2_string_count`/`_keyword`/`_value`, Python `seg2_*`.
  - SEG-2 → SEG-D mapping: a channel set per distinct trace setup, with an info when traces are reordered; receivers in Position blocks; file strings in the external header; DESCALING_FACTOR becomes the DSM.
  - `writeback.nim` now refuses SEG-2 input and non-SEG-Y targets explicitly.
  - Open:
    - survey write-back to SEG-2;
    - patch import of SEG-2 strings (refused by design);
    - the 11.1 inference risks also apply to the writer, so 11.3 (a real file) is needed.
- 2026-11-09: Phase 13 work merged into `seg-library`, then a handoff. The editor window crashed, so the agents' final reports were lost; the work below is read from their commits and files. Full suite green (44 test files, short TMPDIR).
  - 13.1 (`wt-docs`, 8d848d2): usage guides in `docs/guide/`:
    - getting-started, viewer, processing, editing, conversion, diagnostics, c, python;
    - the examples are compiled or run by tests.
  - 13.2 (`wt-bench`): the `nim bench` suite in `bench/` (generators, harness, specs), plus `docs/benchmarks.md` (machine, method, before/after tables). Fixes:
    - R2-1/6/7/9: unchecked pointer loads, native-order `copyMem`, IBM float and SEG-D exponent tables (c198c50).
      - Release decode went from 0.5-2.3 to 2-17 GB/s, e.g. SEG-Y IEEE BE from 2.06 to 11.1 GB/s and IBM from 0.54 to 5.5 GB/s.
      - The memcpy baseline is 18.2 GB/s.
    - R2-2: batched edits overlay pending bytes instead of flushing (dda108d). 2 fields × 2000 traces went from 10.6 s to 13 ms.
    - R2-3: `componentGroupIds` from one table (c864106). 10M groups went from 6.5 s to 4.0 s; the table of 82-byte keys remains.
    - R2-8/R2-10: index reserve and uninitialized `readTraces` (2db702d). Per trace, from 35 to 24 B, and with keys from 242 to 168 B.
    - Read and conversion buffers are no longer zeroed (501a718, ec09d0a). SEG-Y → SEG-Y CPU went from 0.54 to 0.18 s per GB.
  - 13.4 Group I (`wt-fix`):
    - R3-1/R4-5: `segGuard` maps Defects; `copyBytes` overflow fixed (7c97c40).
    - R4-1..R4-4 (c875b8e):
      - SEG-2 sample counts and Rev 3 trailers are bounded by the file;
      - the mux use-after-free is fixed;
      - temp outputs are exclusive.
    - R1-1..R1-6 (69f6ffb):
      - the SEG-2 summary code;
      - the SEG-Y time scalar;
      - one century pivot;
      - STACK descaling;
      - empty outputs fatal;
      - geometry counts.
    - R3-7/8/10/11, at the boundary (da7136f). These become moot in 14.1.
  - Group II (API additions) was not decided before the crash. It is re-scoped to Nim only as 14.3.
  - Owner decision: the C ABI and Python are removed (Phase 14). 13.5 (merge to `main`) waits for Phase 14.
- 2026-11-09: 14.1 done. The C ABI and Python are removed:
  - deleted `src/parseSEG/abi/`, `bindings.nim`, `include/`, `python/`, `tests/c/`, `tests/python/`,
    `tcapi`, `tpython`, `ttargets` (it held only library checks, no CLI checks), `tools/macos-stubs`,
    `bench/capi_bench.c`, `bench/py_bench.py`, and the C/Python design docs and guides;
  - every `segApi`/`segHandle`/`segField` pragma is stripped (12 src files); `tcommon` and `tdocs`
    no longer test them, and `tdocs` runs only `nim` blocks;
  - `config.nims` keeps the CLI tasks (gcc and zig), `test`, `fmt`, `docs` and `bench`; the
    library tasks are gone, and so is the bench `abi` section;
  - CI runs the tests and the CLI builds only; README, `docs/api.md`, guides and benchmarks no
    longer mention C or Python (benchmarks.md notes that 14.4 re-runs it);
  - `AbiVersion` was already gone with `abi/`; nimble version 0.5.0.
  - Left for 14.2: `##` comments that still say "C ABI" (prefetch.nim:310, traceindex.nim:473/664,
    headerfields.nim:4, and some test headers) and the procs they describe.
- 2026-11-09: 14.2 audit written (`docs/design/phase14_audit.md`, 23 items, commit plan 14.2a-e). Waiting for the owner to approve items before any code change.
- 2026-11-09: 14.2a done (R2-5 fixed). The map sits behind a ref (`MapRef`, with a count of pins). A `Prefetcher` holds a `MapPin`, so `f.close()` only drops the file's reference and the unmap waits for the last prefetcher. A `SeismicFile` destroyed while pinned moves (does not copy) its entries and codecs into the map, so the worker's raw pointers stay valid. `waitReady` and `waiters` are deleted. New tprefetch blocks (close while prefetching, file destroyed first, two prefetchers on one map) check the mapping with `/proc/self/maps`. Under ASan: no memory errors. A 32 KB leak in 2 allocations was already there before this change (Nim thread runtime, not investigated). The decode path is unchanged.
- 2026-11-09: 14.2b done. Deleted `readTracesRaw`, `seg2StringCount`/`seg2Keyword`/`seg2Value` (use `seg2Strings`), `previewGeometry`, and `writeGeometry(ed, f: SeismicFile)` (pass `f.index`). `GeometryChanges` gains `$`, the former private `describe`. Tests, the bench, `api.md` and `guide/conversion.md` are updated.
- 2026-11-09: 14.2c done (3ba46f0). `traceHeaders`/`recordHeaders`/`fileHeaders` return `seq[HeaderRow]`, and `HeaderListing` is gone. `HeaderPatch` gives way to `initHeaderChange(scope, index, name, value)`, which checks the name, plus `writeHeaderPatch(changes, path)`. The guides, `api.md` and theaderlist are updated.
- 2026-11-09: fix of a 14.2a regression. The map accessors (`unsafeMemory`, `mappedSize`, `isOpen`, `copyBytes`) copied the `MemFileSource` ref into a local. ORC counts are not atomic, so threads sharing a file in `readTracesInto` crashed intermittently (tdocs processing example). They now read through `f.map.src` in place. New `tests/tsharedreads.nim` (8 threads, 20 k reads each) crashed 4 of 5 runs before the fix and 0 after. Rule: never copy `f.map` or `f.map.src` into a local on a path threads share.
- 2026-11-09: 14.2d done.
  - `SeismicFile.path`/`demuxPath`, `HeaderEditor.file`/`log`/`journalPath` and `SurveyGeometry.log` are private behind `lent` accessors. `writeGeometry` reports through the internal `logVar`.
  - `convertFile(src, dst, opts)` and `convertSegdToSegy(src, sink, opts, recordFormats)` lose `join`; the internal `convertJoined`/`convertSegdToSegyJoined`/`GeometryJoin` are out of the umbrella.
  - `openSeismic` loses `writable`; `openEditor` uses the internal `openSeismicRw`.
  - `addP1(g, path, opts = P1Options(), elevation)`.
  - `copyWithGeometry` is one proc returning `GeometryCopy` (`changes`, `log`).
- 2026-11-09: 14.2e done, so 14.2 is complete.
  - The C-ABI mentions are gone from `##` comments and test headers.
  - `readFields` and `chooseScalar` are out of the umbrella.
  - `iterator chunks` added to `Prefetcher`; the processing guide and `api.md` use it.
  - Next: 14.3, where the owner picks the API additions.
- 2026-11-09: 14.3a done.
  - `traceFieldColumn(f, name, traces): seq[float64]` and `traceFieldColumnInto(f, name, traces, dst)` (openArray and Slice forms; `model/headerfields`). The field is resolved once per block kind (a compile-time `fieldTable` plus the new internal `NumberReader`/`readNumber` in `fieldlayout`), and only its bytes are read per trace. NaN when a trace lacks the block. `ValueError` for an unknown, text or raw field, a closed file or a trace out of range. SEG-2 keyword strings take the slow path (parsed as float, NaN otherwise).
  - `traceKeys(f, traces): seq[TraceKeys]` and `traceKeysInto(f, traces, dst)` (openArray and Slice; `model/traceindex`). Without `keys = true` they rebuild the reader's `SegyTrace`/`SegdTrace`/`Seg2Trace` from the mapped headers and call the same `traceKeys` the walk uses; with keys they copy the stored ones (so `applySurvey` changes show only there).
  - Tests: new `tests/tcolumns.nim`, run on the 5 samples and 8 converted fixtures (SEG-Y 2.1 with Ext1+PSEGD001, little-endian, Rev 1; SEG-D 2.1/3.0; 3 SEG-2). It checks keys equal to a keys=true open for every trace, every numeric trace/ext1 field equal to `findTraceField`, NaN, errors and 6 threads. tsegdmux checks on-demand keys of a demultiplexed copy. Docs: `api.md` rows, a `viewer.md` example, a note in benchmarks item 4.
  - Measured (`-d:danger`, warm). BO_3D-Inglewood (200 tr): column 6.5 ns/trace vs `traceField` loop 205 ns; `traceKeysInto` on demand 629 ns/trace vs keys=true open +567 ns/trace. 63.sgd (1 tr, per-call overhead): column 253 ns vs 143; keys 234 ns. 00000151 SEG-D (3957 tr): column 14 ns vs 159; keys 259 ns vs open +195 ns.
- 2026-11-09: 14.3b done. Sample windows: `readTraces(f, traces, samples)` / `readTracesInto(f, traces, samples, dst, row[, log])` (Slice and list forms; width must be `samples.len`; zero past a trace's end; `ValueError` for an empty or negative window) and `newPrefetcher(..., firstSample)`. `decodeEntry` gained `first = 0`: it offsets into the trace's bytes; 8015 / SEG-2 format 3 decode the group the window starts in into a 4-sample scratch, then whole groups straight into the row. The whole trace is still bounds-checked, so a window fails exactly as the full read does. Full-trace decode unchanged (`-d:danger`, 00000151 8058 7.7 GB/s, IEEE 9.4, IBM 5.2, int16 15, before and after). `f.textHeader` (40 lines of 80 joined by '\n') and `f.extendedTextHeaders` (per record, own encoding; from the retained records or the map). New `model/sorting`: `sortTraces(f, by[, traces])` and `sortOrder(columns)`: order-preserving uint64 keys (NaN last, -0 = 0) and a stable LSD radix sort (11-bit digits, constant digits skipped), last key first; 10 M rows 0.19 s for 1 key, 0.6 s for 2 (plus the column reads). Tests: new `tests/tviewerreads.nim` (46 fixtures: every SEG-Y, SEG-D and SEG-2 format, LE and pair-swapped SEG-Y; every 4-group phase, past-end windows, list form at a row offset, prefetch, errors; text headers; sort against a stable merge sort). Docs: `api.md`, `viewer.md`, benchmarks item 5.
- 2026-11-09: 14.3c done. `openEditor(f: sink SeismicFile, journalPath = "")` takes over an open file: new internal `remapWritable` maps the path read-write in place of the read-only map and keeps the index (entries, codecs, joined keys; no second walk); `ValueError` for a closed file, a demultiplexed copy, a size change since opening, or journal == file. A prefetcher pinning the old map keeps it and the parked entries/codecs (the file gets copies; the test catches the use-after-free under ASan without the parking). `release(ed: sink HeaderEditor): SeismicFile` ends the session like `close` and returns the file still mapped. `writeGeometry(ed, fields)` uses the editor's own keys. Callers: CLI `survey-apply --in-place` and `edit`, `writeInPlace` (copy/convertWithGeometry) no longer open twice. Note: at module top level (globals) callers must write `openEditor(move f)`. Tests in tedit, tgeomwrite, tsegdmux; docs editing/conversion/viewer, api.md.
- 2026-11-09: 14.3d done. New `model/writefile`: `openSeismicWriter(path, like, segyFormat = stKeep, segdFormat = tfKeep, seg2Format = s2tKeep): SeismicWriter`, `writeTrace(w, src, trace, samples: openArray[T])` and `writeTrace(w, src, trace, x: Tensor[T], row, samples = -1)`, `close(w): DiagLog`, `len`, `path`. File headers come from `like`; trace headers are re-read from `src`'s map and only what the samples change is changed (format code; SEG-Y/SEG-2 sample counts in the trace header, SEG-Y binary count when uniform, fixed-length files need one count, the declared Rev 2 trace count patched at close; SEG-D Rev 3 GH#3 data/record sizes on a format change). SEG-Y headers are validated at open on a null sink, the real writer opens at the first trace. SEG-D rule: records whole, traces in input order, a record ends when another record's trace arrives or at close (`ValueError` if incomplete); records may be skipped/reordered. Output via `createTempFor`/`finishOutput`; a `=destroy` removes the temp file of a writer dropped without close (or whose close raised). Tests: new `tests/twritefile.nim` (identity rewrite byte-identical on 14 fixtures; scaled SEG-Y Rev 0/1/2.1 BE/LE in formats 1/2/3/5/6/9, SEG-D 2.0/2.1/3.0 with 8048/8058/8080, SEG-2 formats 4/5; count changes; record rule; refusals; dropped writer). Docs: processing.md "Write like the input" (2 tested examples; replaces "SEG-D or SEG-2 in"), api.md section. Open (refused with `ValueError`): SEG-D sample-count changes (would need descriptor edits before the record headers are written), multiplexed SEG-D input. Note: 8015 output is always one's complement (the encoder has no two's-complement mode).
- 2026-11-09: 14.3e done. Progress/cancel: new `common/progress` with `Progress = proc (done, total: int64): bool {.closure, gcsafe, raises: [].}` (input bytes, total -1 if unknown; about every MiB via a one-compare ticker, plus once at the end), passed as `progress = nil` to `openSeismic`, `buildIndex`, `exportHeaders`, `convertFile` and every converter it dispatches to (`convertSegy`, `convertSegdToSegy`, `convertSeg2ToSegy`, `convertToSeg2`, `convertSeg2ToSegd`, `convertSegdRevision` path and stream, `scanSegdRecords`), `convertWithGeometry`, `copyWithGeometry` (chunked copy when hooked); multi-pass operations spread their passes over one 0..total run. Cancel: `openSeismic`/`buildIndex`/`exportHeaders` raise the new `SegCancelledError` (errors.nim; the file is built in a local, so it is unmapped; no export output), conversions return fatal `dcCancelled` and leave nothing (temp-and-rename). Index cache: `saveIndex(f, path)` + `openSeismic(..., cache = path)` + `f.fromCache`; chosen over `openSeismic(cache)` writing the file because of the owner rule "persisting derived data is a separate, named call" (and `saveIndex` can refuse indexes whose keys were joined: new `TraceIndex.joined`). The cache is a NIF header (version, library version, schema hash, endianness, absolute path, size, mtime s+ns, checksums of the first/last 64 KiB, twosComplement8015, keys), then the whole `TraceIndex` as a native snapshot (new `common/binstore`: generic `fieldPairs` put/get incl. variants and private fields; POD seqs as one block; `schemaOf` macro describes every stored type so any layout change invalidates), then length + checksum. Valid only if the header is exactly the one the file would get now (a keys cache serves keys = false); otherwise walked, with an info `dcIndexCache` saying why; the saved log excludes that note. Demultiplexed copies are refused. Measured (-d:danger, warm, 10 M SEG-Y traces, 12.4 GB): walk 2.58 s before / 2.48 s after / 2.48 s with a hook (11 822 calls); from the cache 43 ms (240 MB, saved in 95 ms); keys 7.0 s vs 0.47 s cached. Tests: new `tprogress` (counts, monotonic, cancel in open/convert/export/geometry writers, unmapped after cancel, unchanged output without a hook), `tindexcache` (snapshot-equal round trip on every sample and SEG-Y LE / Rev 1, SEG-D 2.0/2.1/3.0/3.1/8015, SEG-2 fixtures with and without keys; size/mtime/head/tail/path/option/keys/version/schema/library staleness; truncated, flipped, empty, foreign and directory caches; refusals), tsegdmux (mux not cached). Docs: api.md, diagnostics.md codes, viewer.md section, benchmarks item 2.
- 2026-11-09: 14.3f done. Prefetch buffer recycling: `nextInto(p, c)` / `tryNextInto(p, c)` (the caller gives up `c.samples`: if it has the chunk shape `[chunkTraces, cols]`, owns its storage from offset 0 and nothing else shares it (`isUniqueRef` on the Arraymancer storage, so a kept copy or view is never overwritten, only not reused), it is swapped into the slot as its next decode target), `recycle(p, t: sink Tensor[T])` / `recycle(p, c: sink PrefetchChunk[T])` (a spare list of at most `depth` reusable buffers that `next` takes before allocating; others are dropped). Partial chunks still clone (with `into` the old buffer goes to the spare list). `next`/`tryNext`/`chunks` unchanged. Tests in tprefetch: data across files/chunk sizes/seeks, random seeks with short spans and selections, kept copies and views intact, recycle of shared/view/wrong-shape/own tensors, cols = 0; allocation counter (new `tests/tprefetch.nims` sets `-d:nimAllocStats`): 0 allocations over 400 steady `nextInto` chunks vs >= 1 per chunk with `next`. ASan clean (only the known 32 KB thread-runtime leak). Measured (`-d:danger`, warm, y-ieee-1m first 300 k traces = 300 MB float32, depth 4): chunk 4096 (4 MB) `next` 1 930 chunks/s 7.8 GB/s vs `nextInto` 1 910 chunks/s 7.7 GB/s; chunk 256: 31 300 vs 31 300 chunks/s, 8.0 GB/s both: throughput is bound by the one decoding worker, so recycling saves the 4 MB allocation (and its page faults) per chunk, not wall time. Docs: api.md prefetcher row, viewer.md (tested example), module doc.
- 2026-11-09: 14.4 done. Ran `nim bench` at small scale; it passed. `docs/benchmarks.md` has a "Phase 14 re-run" section: the same per-trace index cost (218 vs 244 ns/trace), keys (648 vs 682), heap, IBM/8015 decode and single-trace latency as before, plus the 14.3 rows (sample window, header column) and the agents' cache/hook/recycling numbers. Full scale was not re-run.
- 2026-11-09: 13.5 done. `main` was fast-forwarded to `seg-library` at the end of Phase 14; nothing is pushed. Handoff rewritten.
