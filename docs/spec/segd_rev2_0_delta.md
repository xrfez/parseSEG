# SEG-D Rev 2.0: delta on `segd_rev2_1.md`, verified against a real file

## 1. Scope
- No standalone Rev 2.0 PDF is available. Rev 2.0 is reconstructed as **Rev 2.1 minus the
  changes listed in "Changes introduced in Rev 2.1"** (2.1 text p.5; 3.0 text §2.1, p.10).
- It is **verified byte-for-byte** against `SEG Spec/exampleFiles/63.sgd` (Geo Space, 2024), see §4.
- All layouts, code tables and sample formats are the same as in `segd_rev2_1.md` unless
  listed below.

## 2. Differences: Rev 2.0 vs Rev 2.1

| Item | Rev 2.0 | Rev 2.1 | Implementation |
|---|---|---|---|
| GH2 bytes 11-12 (revision) | `02 00` | `02 01` | `revision = (2, 0)` |
| Storage unit label bytes 5-9 | `SD2.0` | `SD2.1` | accept both |
| Label field 6, producer org code (bytes 30-39) | **required** | optional (may be blank) | the 2.0 writer must fill it; the reader accepts blanks for both |
| GH2 bytes 21-22 | undefined (X) | line sequence number (u16, 0 = not valid) | Rev 2.0: preserve raw and don't interpret; the writer emits whatever is stored (default 0) |
| Multiple production lines per tape | not addressed | allowed if (file no., seq no.) are unique | n/a for 2.0 |
| Media list (App. F) | without 9940B/3592/TS1120 | adds them | informational |
| Appendix A/C code lists | older lists | updated (Energistics) | use the 2.1 lists for both; unknown codes pass through |

Everything else is identical, including all of the following:
- GH1, GH#N, CSD, demux trace header, trace header extension #1 and general trailer layouts;
- the extended (EC) and external (EX) header semantics;
- sample formats 8015/8022/8024/8036/8038/8042/8044/8048/8058;
- "demultiplexed only".

## 3. Reading rules shared by 2.0 and 2.1 (resolved from real data)
- **Disk files carry no storage unit label.** Both real SEG-D samples (2.0 and 3.0) start
  directly at GH1. Auto-detect: if bytes 5-9 match `SD\d.\d`, a 128-byte label is present;
  otherwise the file starts at GH1. (This resolves 2.1 note open question 1 for disk.)
- **The block order is confirmed** (2.1 AMBIGUITY "Figure 1 missing"): GH1, GH2, GH3..GH(1+n),
  then per scan type its CSDs and SK skew blocks, then EC extended blocks, then EX external
  blocks, then traces, then GT trailer blocks. In `63.sgd` the bytes tile exactly with this order.
- `recordLength` nibbles `FFF` → GH2 bytes 15-17 is in **milliseconds** (2000 in `63.sgd`,
  which matches 1000 samples × 2 ms).

## 4. Verification walk of `63.sgd` (4340 bytes)

| Offset | Block | Decoded values |
|---|---|---|
| 0 | GH1 | file 63, format 8058, year 24, day 163, 17:40:02, mfr 09 (Geo Space), serial 0, BSI byte 32 (= 2 ms), polarity 0, record type 8 (normal), record length `FFF`, ST 1, CS 1, SK 0, EC 3, EX 0, additional GH 2 |
| 32 | GH2 | extFile 63, extCS 1, extEC 3, extEX 0, rev 2.0, GT 0, extRecordLength 2000 ms, block# 2, seq 0 |
| 64 | GH3 | block# 3, source line 13.0, source point 99.5 (`63 80 00` → 99 + 0x8000/65536), point index 1, source set 0 |
| 96 | CSD 1/1 | 0-2000 ms, MP 0, 1 channel, type 1 (seis), S/C 0, gain 3 (fixed), alias 207 Hz / 461 dB/oct, low-cut 1 Hz / 6 dB/oct, THE 3, stack 1 |
| 128 | Extended header | 3 × 32 B (Geo Space-specific, kept raw) |
| 224 | Trace 1 | file 63, ST 1, CS 1, trace 1, TW 0, THE 3, edit 0, extCS 1, extFile 63 |
| 244 | THE #1 | receiver line 13, point 104, index 1, **samples 1000**, sensor type 2 (geophone vertical) |
| 276 | THE #2-3 | 2 × 32 B manufacturer-defined (kept raw) |
| 340 | Samples | 1000 × IEEE f32 (first: 0.1001, 0.0452, 0.0439) |
| 4340 | EOF | exactly the end of the file, with 0 trailer blocks |

Notes from the walk:
- The GH1 bytes 20-22, 24L and 25 are 0, as the spec requires.
- The demux trace header's extended fields (CS bytes 16-17, file bytes 18-20) are filled
  even though the BCD fields are not `FF`. This answers 2.1 open question 7: the
  extended copies may be present and should agree with the BCD fields.
- An alias slope of 461 dB/oct is unusual but valid BCD. Don't reject it.

## 5. Open questions
- None specific to 2.0. Format 8015 polarity of negatives is still untested (no real 8015 file).
