# parseSEGD: master plan and checkpoint log

> **Resuming in a new session? Read this file first, then follow "Resume protocol".**

## Goal
An idiomatic Nim library to **read and write** SEG seismic data files on **disk and
tape**. Priority formats:
1. **SEG-D Rev 2.0** (the owner's most important format; see `63.sgd`)
2. SEG-Y Rev 1.0 (plus Rev 0, which it is a superset of)
3. SEG-D Rev 2.1 and 3.0
4. SEG-Y Rev 2.1

**Long-term goal: spec out and support every revision of both standards** (SEG-Y 0/1/2.0/2.1,
SEG-D 1/2.0/2.1/3.0/3.1). We have no standalone PDF for SEG-D 2.0 or 1. The 2.0 rules
are reconstructed from the "changes introduced in Rev 2.1 / 2.0 / 1" history sections of
the 2.1 and 3.0 documents, and verified against `63.sgd`.

Also required by the sample files: reading SEG-D **Rev 2.0**, SEG-Y **Rev 0 little-endian**,
and the SEG-Y **Rev 2.1** features (needed to read the Inglewood sample).
Later: SEG-D 3.1 (a small delta on 3.0) and SEG-D Rev 1.

## Owner decisions (2026-11-07)
- **One data model, many revisions.** The revision is always identified from the
  headers (SEG-Y bytes 3501-3502; SEG-D GH2 bytes 11-12), so readers dispatch on it.
  - SEG-Y uses **one** `SegyFile` type for Rev 0-2.1, where revision-specific fields
    are simply optional or zero.
  - SEG-D uses **one** `SegdRecord` type for Rev 1-3.1, whose optional blocks are
    variant objects keyed by block type.
  - A shared `Trace` view (header essentials plus `seq[float32]`/`float64` samples)
    and an auto-detecting `openSeismic(path)` cover both standards.
- **Byte order.** Decoded values are native Nim values, so byte order is not stored in
  the data. Readers detect it: the SEG-Y Rev 2 byte-order marker if present, otherwise
  plausibility of the format code and sample counts (e.g. little-endian format 5 read
  big-endian is 1280). The detected order is kept as file metadata. Writers default to
  the spec (big-endian), with an explicit `byteOrder` option for little-endian output.
- **Extended / external / user-defined blocks** are first-class:
  - every byte is preserved losslessly (raw `seq[byte]`), even when also parsed;
  - spec-defined blocks are parsed into typed objects, and unknown SEG-D 3.x block
    types (byte 32) are kept as raw blocks rather than rejected;
  - manufacturer-specific decoders can be registered at runtime, keyed by
    manufacturer code (GH1) and block kind, so vendor layouts plug in without
    forking the library;
  - writers re-emit raw blocks unchanged.
- **Tape is low priority.** All the owner's real data is on disk. Follow the spec for tape
  layout and keep the device sink minimal.

- **Tape:** the goal is **tape-ready output**, not a full tape-drive stack. The format
  layer emits a stream of *records* and *tape marks*, and pluggable sinks write it:
  (a) a plain disk file (records concatenated; tape marks dropped or mapped to file
  boundaries), (b) a tape-image file that preserves record lengths and tape marks,
  (c) a minimal Linux `st` device sink (`write()` per record, `MTWEOF` ioctl). A Windows
  tape sink can be added behind the same interface later. Reading works the same way
  through a record source. The spec notes say how tape and disk layouts differ: block
  sizes, the storage unit label, padding, and tape marks between files.
- **Unsupported content must never fail silently.** Multiplexed SEG-D format codes (0015,
  0022, ...) and any other unimplemented feature raise `SegUnsupportedError` with the code
  and location. Headers stay readable, so callers can still inspect such files.

## Sample files (`SEG Spec/exampleFiles/`)
| File | Size | What the headers say | In git? |
|---|---|---|---|
| `63.sgd` | 4.3 KB | SEG-D **Rev 2.0** (GH2 bytes 11-12 = 02 00), format 8058, no storage unit label, GH1 has 2 extra GH blocks | yes |
| `00000151_12900_11300.sgd` | 65 MB | SEG-D **Rev 3.0** (03 00), format 8058, no label, 2026 day 275, GH count extended (nibble F) | **no** (too big for git). Once it reads correctly, write a 1-trace subset as a committed fixture (task 5.4) |
| `Sweep0.sgy` | 51 KB | SEG-Y **Rev 0** (bytes 3501-3502 = 0, text C4 says "Rev. 0"), **little-endian** (SeiSee agrees), ASCII text, format 5 (IEEE), 1 trace × 12001 samples @ 1000 µs | yes |
| `BO_3D-Inglewood_rev21_v7.sgy` | 2 MB | SEG-Y **Rev 2.1** (0x0201), EBCDIC, format 1 (IBM), 2001 samples @ 2000 µs, ext. text count −1 (Rev 2 "variable") | yes |
Both SEG-D samples use format 8058 (IEEE float), so the 8015 one's vs two's complement
question remains open. Implement per spec (one's complement) and test with synthetic data.

## Resume protocol (token budget rules)
1. **Never open the PDFs** in `SEG Spec/*.pdf`. Their full text is already in
   `SEG Spec/text/*.txt` (page-marked with `=== PAGE N ===`).
2. Prefer the distilled notes in `docs/spec/*.md`. Read the text files only to
   resolve an `AMBIGUITY` or a gap, and then use `grep -n` plus a targeted
   `sed -n 'a,bp'`, never the whole file.
3. Find the first unchecked task below, do it, tick it, add a line to the
   **Log**, and **commit**. A commit after each task is the checkpoint, so no
   work is ever lost.
4. Before writing any Nim, load the matching `nim-*` skill (see `AGENTS.md`). The
   `.agents/skills/*` symlinks are broken in this container. Read the skills from
   `/opt/nim-agent-template/skills/<name>/SKILL.md` instead.
5. Run the tests with `nim test` (this runs `tests/tester.nim`, which discovers `tests/t*.nim`).
6. Work branch: `seg-library`.

## Architecture (target)
```
src/parseSEGD.nim                # umbrella module, re-exports public API
src/parseSEGD/
  common/
    endians.nim     # big-endian get/put on openArray[byte] (u8..u64, i8..i64, 24-bit)
    bcd.nim         # packed-BCD nibble codec (arbitrary nibble offset)
    ibmfloat.nim    # IBM hex float <-> IEEE float32
    ebcdic.nim      # EBCDIC <-> ASCII (cp037)
    errors.nim      # SegError hierarchy
  io/
    blockio.nim     # record-oriented source/sink abstraction (readRecord/writeRecord/eof marks)
    diskio.nim      # plain-file byte streams + record emulation
    tapeio.nim      # Linux st(4) driver: variable-block reads, MTIOCTOP (WEOF/FSF/BSF/REW)
  segy/
    types.nim  textheader.nim  binheader.nim  traceheader.nim  samples.nim  reader.nim  writer.nim
  segd/
    types.nim  samples.nim (8015/8022/8024/8036/8038/8042/8044/8048/8058/...)
    rev21.nim  rev30.nim  reader.nim  writer.nim
tests/
  fixtures/        # small synthetic files generated by tests (plus real samples)
```
Design principles: zero-copy decoding from `openArray[byte]`; header objects are
plain Nim objects with typed fields, with lossless round-trip (keep the raw bytes for
unknown/vendor areas); streaming trace iterators, so whole files are never loaded;
writers validate before emitting.

## Phases and tasks

### Phase 0: Spec ingestion (one-time)
- [x] 0.1 Install poppler and convert all PDFs to page-marked text (`tools/extract_specs.sh`)
- [x] 0.2 Write conventions for the spec notes (`docs/spec/CONVENTIONS.md`)

### Phase 1: Spec distillation (one note per spec chunk, done by parallel subagents)
- [x] 1.1 `docs/spec/segy_rev1.md`: SEG-Y Rev 1.0 (text: `SEG Y rev 1Release 1.02.txt`)
- [x] 1.2 `docs/spec/segd_rev2_1.md`: SEG-D Rev 2.1 (text: `seg_d_rev2.1_.txt`)
- [x] 1.3 `docs/spec/segd_rev3_0_a.md`: SEG-D 3.0 pages 1-86 (structure, label, TOC, data body, header tables 7.x)
- [x] 1.4 `docs/spec/segd_rev3_0_b.md`: SEG-D 3.0 pages 87-188 (parameters 8.x, trailer, appendices)
- [ ] 1.5 Review the notes. Verify segd_rev2_1.md and derive the **Rev 2.0 differences**
      (`docs/spec/segd_rev2_0_delta.md`) by decoding `63.sgd` header by header. Check the
      3.0 header-size formula against the 3.0 sample. Add leap seconds 2015/2017. Resolve AMBIGUITY items (2.1: pages 14-17 and 61 are image-only figures;
      render them with `pdftoppm -f N -l N -r 80 -png` and view only those pages) and write `docs/spec/README.md` (index plus a cross-format summary)
- [ ] 1.6 `docs/spec/segy_rev2_1.md` (subagent): SEG-Y Rev 2.1 as a **delta on segy_rev1.md**
      (text: `seg_y_rev2_1-oct2023.txt` plus `seg-y_rev2-1_clarification_2025-05-01.txt`; skip
      the superseded Rev 2.0 doc). It must cover the byte-order marker (3297-3300), extended
      text count −1, additional trace headers, data trailers, and new formats.
- [ ] 1.6b **SEG-D Rev 2.0 full note**. The PDF was added and its text extracted (pages 13-16 are image-only figures; the block order is confirmed by `63.sgd`). Distiller running. Steps:
      (1) run `tools/extract_specs.sh` (local, no tokens; install `poppler-utils` first if missing);
      (2) one subagent distills `SEG Spec/text/<2.0 file>.txt` into `docs/spec/segd_rev2_0.md` per
      CONVENTIONS.md, and **cross-checks it against `segd_rev2_0_delta.md` and the `63.sgd` walk**
      (the delta note is reconstructed, so where they disagree the 2.0 PDF text wins, unless the
      real file says otherwise); (3) mark the delta note as superseded.
- [ ] 1.7 (later) `segd_rev3_1_delta.md`
- [ ] 1.8 (later) The remaining revisions (SEG-Y 2.0 vs 2.1 differences, SEG-D Rev 1), so all types are specced

### Phase 2: Core primitives (with unit tests)
- [x] 2.1 endians, bcd, ibmfloat, ebcdic, errors (`tests/tcommon.nim`)
- [ ] 2.2 I/O layer: record source/sink interface (records + tape marks); disk-file,
      tape-image-file and memory sinks/sources; minimal Linux `st` sink; `SegUnsupportedError`

### Phase 3: SEG-Y Rev 1
- [ ] 3.1 Textual, binary, and trace headers (decode/encode, round-trip tests)
- [ ] 3.2 Sample formats 1,2,3,5,8 and the reader/writer, including extended textual headers;
      **byte-order detection** (Rev 2 marker, else a plausibility heuristic on format code/sizes)
      and ASCII/EBCDIC text detection
- [ ] 3.3 Validate against `Sweep0.sgy` (Rev 0, LE) and `BO_3D-Inglewood_rev21_v7.sgy` (Rev 2.1)
- [ ] 3.4 Rev 2.1 extensions (from 1.6) needed to fully read the Inglewood file

### Phase 4: SEG-D Rev 2.0 / 2.1 (2.0 first)
- [ ] 4.1 Headers (general 1/2/N, scan type / channel set, extended, external, demux trace, trace extensions)
- [ ] 4.2 Sample formats and the demux reader
- [ ] 4.3 Writer and round-trip tests with synthetic records
- [ ] 4.4 Validate against `63.sgd` (Rev 2.0): byte-identical read->write round trip
- [ ] 4.5 Vendor-decoder registry for extended/external headers (with an example decoder in tests)

### Phase 5: SEG-D Rev 3.0
- [ ] 5.1 Storage unit label, TOC, general headers 1-3 and optional blocks
- [ ] 5.2 Trace headers and extensions, trailer, reader
- [ ] 5.3 Writer and round-trip tests
- [ ] 5.4 Validate against `00000151_12900_11300.sgd` (Rev 3.0, local only), then write a
      1-trace (or few-trace) copy with all headers to `SEG Spec/exampleFiles/` and commit it
      as a permanent fixture

### Phase 6: Tooling
- [ ] 6.1 CLI: `parseSEGD dump|info|convert`
- [ ] 6.2 Docs and CI updates

## Open questions for the owner
- None outstanding. (It would help to have a SEG-D file with 8015/8022/8024 integer formats.)

## Log
- 2026-11-06: Phase 0 done. The spec text is extracted and committed. Branch `seg-library` created.
- 2026-11-06: Task 2.1 done: common primitives and tests pass (debug and release). Phase 1 distillation was started with 4 parallel subagents.
- 2026-11-06: Task 1.2 done: segd_rev2_1.md (731 lines, 18 AMBIGUITY items, 10 open questions).
- 2026-11-06: Task 1.1 done: segy_rev1.md (866 lines, 24 resolved AMBIGUITY items, open questions Q1-Q12).
- 2026-11-06: Task 1.4 done: segd_rev3_0_b.md (902 lines). Follow-ups for 1.5: add the 2015/2017 leap seconds (the E.9 table stops at 2012); confirm the GH3 header-size formula against part A.
- 2026-11-06: Task 1.3 done: segd_rev3_0_a.md (893 lines, 16 AMBIGUITY items). Phase 1 notes are complete; next is 1.5 (review/index).
- 2026-11-06: Task 1.5 started: the 3.0 Additional Source Info ID is resolved as 0x20 (via the 3.1 text). Record each later resolution in a `## Resolutions` section at the end of the note concerned.
- 2026-11-07: The owner added sample files and answered the questions (tape = tape-ready output; never fail silently). The sample headers were inspected and the plan updated: Rev 2.0 SEG-D, Rev 0 LE SEG-Y and the Rev 2.1 SEG-Y note were added. The 65 MB Rev 3.0 sample is git-ignored.
- 2026-11-07: Owner priorities were recorded: SEG-D 2.0 is the most important; one data model for all revisions; byte-order option on write; extended/user blocks are first-class; tape low priority; 1-trace fixture from the 65 MB file.
- 2026-11-07: The owner asked for the SEG-D 2.0 PDF to be extracted, but the PDF is not in the workspace yet. Task 1.6b was added (blocked).
- 2026-11-07: The SEG-D Rev 2 PDF (Dec 1996, manufacturer list rev. Jan 2006) was added, extracted and committed. A subagent is writing segd_rev2_0.md.
