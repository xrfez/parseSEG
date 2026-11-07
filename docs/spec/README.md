# Spec notes index

Implementation sessions read **these notes, never the PDFs**. Raw text for targeted greps is in
`SEG Spec/text/`. Format rules for the notes are in `CONVENTIONS.md`. Each note ends with a
**Resolutions** section that overrides the AMBIGUITY items above it. `*_verified.md` and
the verification sections (facts checked against real files) override everything.

| Note | Standard | Status |
|---|---|---|
| `segy_rev1.md` | SEG-Y Rev 1.0 (also covers Rev 0) | verified on `Sweep0.sgy` (Rev 0, LE) |
| `segy_rev2_1.md` | SEG-Y Rev 2.1, delta on Rev 1 | verified: the Inglewood walk tiles all 1,982,000 bytes |
| `segd_rev2_1.md` | SEG-D Rev 2.1 | layout verified via 2.0 sample |
| `segd_rev2_0.md` | **SEG-D Rev 2.0** (owner's primary format), with the full diff vs 2.1 in §8 | from the 2.0 PDF; word-diffed against 2.1; checked against `63.sgd` |
| `segd_rev2_0_delta.md` | superseded; keep for its `63.sgd` walk (§4) | verified byte-for-byte |
| `segd_rev3_0_a.md` | SEG-D 3.0: structure, label, TOC, layouts, sample formats, 3.0-vs-2.1 changes | sizes verified |
| `segd_rev3_0_b.md` | SEG-D 3.0: field semantics, code tables, appendices | partly verified |
| `segd_rev3_0_verified.md` | SEG-D 3.0 facts from the real 65 MB sample | ground truth |

## Cross-format summary
| | SEG-Y | SEG-D 2.x | SEG-D 3.x |
|---|---|---|---|
| Byte order | big-endian (LE seen in the wild) | big-endian | big-endian |
| Numbers in headers | binary ints | mostly **BCD** plus binary | mostly binary, some BCD |
| Revision field | bin 3501-3502 (u8 major, u8 minor) | GH2 bytes 11-12 | GH2 bytes 11-12 |
| File header | 3200 text + 400 binary (+ ext. text) | GH1, GH2, GH3..N (32 B each) | GH1-3 + optional typed 32 B blocks (byte 32 = type) |
| Per-channel-set info | n/a | 32 B CSD per channel set | 96 B CSD |
| Trace header | 240 B (+ Rev 2 extra 240 B blocks) | 20 B + 0-15 × 32 B extensions | 20 B + 1-255 × 32 B typed extensions |
| Vendor/user areas | text, unassigned bytes | extended (EC) and external (EX) headers, THE #2+, trailer | EC, EX, user block types 0xB0-0xFF, trailer |
| Sample formats | 1 IBM, 2 i32, 3 i16, 5 f32, 8 i8 (+ Rev 2 more) | 8015, 8022, 8024, 8036, 8038, 8042, 8044, 8048, 8058 | + 8080 (f64) |
| Disk label | none | optional 128 B (absent in practice) | optional 128 B (absent in practice) |
| Timestamp | trace bytes 157-168 (Y/D/H/M/S) | GH1 BCD UTC | GH3 i64 µs since GPS epoch |
