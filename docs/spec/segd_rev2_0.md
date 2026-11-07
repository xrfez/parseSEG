# SEG-D Rev 2.0 (December 1996, manufacturers' list revised Jan 2006) — implementation spec note

Source: `SEG Spec/text/SEG Field Tape Standards Committee Proposal for SEG-D, Rev 2_.txt`. All `[p.N]` are
`=== PAGE N ===` markers **of that file** (printed page = N − 2). They do **not** match the `[p.N]` of
`segd_rev2_1.md`.

Cross-check method: besides a full read, a word-level diff (whitespace-normalized, page markers removed) of
this text against `SEG Spec/text/seg_d_rev2.1_.txt` was run. Outside the passages listed in §8, the two
texts are **word-identical** (all header bit tables, parameter descriptions, sample formats, MP rules, code
tables). §8 is therefore exhaustive for textual differences.

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| p.1-3 | Title, revision status, TOC, introduction, committee | skipped (no format content) |
| p.4-6 | §2.0 Changes in Rev 2 (vs Rev 1) | yes (§7.3) |
| p.6-10 | §2.1 Changes in Rev 1 (vs Rev 0) | yes (§7.4); format/IEEE/MP rules used |
| p.11-12 | §3.0 Format overview, device structures, file marks, partitions | yes (§2) |
| p.13-16 | Figures (record structure) | **image-only** (only page numbers extracted); order confirmed from real data, see §2.1 |
| p.17-19 | §4.0 Storage unit (tape) label | yes (§2.3) |
| p.20-24 | §5.x Header block descriptions | yes (§2, §3) |
| p.25-32 | §6.x Data recording methods, MP factor | yes (§5, §7.5) |
| p.33-39 | §7.x Header bit tables | yes (§3) |
| p.40-52 | §8.x Header parameter descriptions | yes (§3, §4) |
| p.53-55 | App. A manufacturer codes | compact table (§4.10) |
| p.56-57 | App. B glossary | only tape-file/EOD terms (§2.1) |
| p.58-59 | App. C API producer organization codes (RP66) | skipped; label field 6 is just a number (§8) |
| p.60-62 | App. D header descriptors (abbreviation index) | checked against tables, consistent; diffs vs 2.1 in §8 |
| p.63-64 | App. E examples and calculations | **fully extracted** (E.1 samples/scan, E.2 skew count, E.3 filter slope) (§6) |
| p.65 | App. F max block sizes | yes (§4.13) |
| p.66 | blank | — |

Conventions used here:
- **Spec bit numbering: bit 0 = MSB (value 128), bit 7 = LSB (value 1)** [p.33]. `H` = bits 0-3 (`b shr 4`),
  `L` = bits 4-7 (`b and 0x0F`).
- All multi-byte binary fields are big-endian, **except MP factor** (CSD bytes 7-8, §3.6).
- "BCD" = packed BCD, MSD in high nibble [p.33]. "All values are in packed BCD unless otherwise specified" [p.40].
- `X` = "undefined by the format and may have any value" [p.38, p.43].

## 2. File / tape structure

### 2.1 Storage unit and record sequence [p.4-6, p.11-12, p.17, p.20, p.57]

```
Storage unit (tape, or one tape partition):
  Storage Unit Label (128 bytes ASCII, first 128 B of first user-writable record)   [optional File Mark]
  Shot record 1
  [File Mark]                     (only allowed at shot-record boundaries)
  Shot record 2
  ...
  EOD                             (tape: required after last valid record, before end of tape)

Shot record (byte stream, demultiplexed only):
  General Header #1                       32 B
  General Header #2                       32 B
  General Header #3..#(GH+1)              32 B each   (GH = GH1 byte 12 high nibble)
  Scan type header 1:
      Channel Set Descriptor 1..CS        32 B each
      Skew blocks 1..SK                   32 B each
  Scan type header 2..ST/R  (same shape, same CS count)
  Extended header                         EC x 32 B
  External header                         EX x 32 B
  Trace: Demux Trace Header 20 B + THE x 32 B Trace Header Extensions + sample data   (repeated)
  General Trailer blocks                  GT x 32 B   (optional)
```

> **AMBIGUITY [p.13-16]:** Figure 1 is image-only. The order above is from the §5.0 listing [p.20], §5.4-5.6
> [p.23-24] ("trailer … following the seismic data") and is **confirmed byte-exactly** on the real Rev 2.0 file
> `63.sgd` (§9). Trace order is not stated; identify each trace by its own header (file/ST/CS/trace numbers).

Rules:
- Rev 2 records are **demultiplexed only**; "Rev 2 does not support multiplexed data" [p.4 #2, p.11].
- No File Mark and nothing else (no ANSI label) before the label [p.6 #17, p.11, p.19].
- Label is required on **each tape** [p.5 #11, p.11 "Each SEG-D Rev 2 tape must begin with a tape label"].
  Disk files are not addressed; "If data is staged on disk, many shots can be stored in each file" [p.6, p.12].
- Each partition starts with its own label, must be decodable in isolation; partitions may mix SEG-D and non-SEG-D [p.12, p.17].
- File Marks optional, only at shot-record boundaries; "preferably for every shot" on field tapes [p.6 #15, p.11-12].
- Tape file = data between two File Marks (or FM and EOD). EOD typically = two consecutive FMs, possibly more [p.57].
- Label "Max shot records per field record": field record = data between File Marks [p.19].
- **Not in 2.0:** the multiple-production-lines rule and GH2 line sequence number (added in 2.1).

### 2.2 Device structures [p.5 #12, p.11]

| Type | Label field 3 | Block rule |
|---|---|---|
| A Variable block length | `RECORD` | each block holds data of one shot only; multiple channel sets per block; **no padding** in short blocks |
| B Byte stream | `RECORD` | no blocks; shots written consecutively without gap within a file |
| C Fixed block length | `FIXREC` | each block holds one shot only; last block of a shot **padded** ("characters without any information") to block size = label field 5 |

- Blocked data: all headers may share a block with the first channel set; channel sets may span blocks; **block boundaries may not occur within a trace** [p.11].
- On disk: A cannot reproduce interblock gaps/FMs; B and C map directly (except original FM positions) [p.5, p.11].
- Rev 1 blocked rule (historical): integral number of traces per block, headers not blocked, blocks ≤128 KB,
  same channel set per block, **GH1 byte 20 "B1 = 1" flags blocked data** [p.8 #12]. Superseded in Rev 2: GH1
  bytes 20-22 are "Not used. Record as zero" [p.33, p.41]. Blocking is signalled only by the label (field 3/5).

### 2.3 Storage Unit Label (128 bytes ASCII) [p.17-19]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | ascii | `storageUnitSeqNum` | Field 1. 1-9999, right-justified, leading blanks, no leading zeros. Optional: all blanks ⇒ only unit in set |
| 5-9 | | 5b | ascii | `segdRevision` | Field 2. **`SD2.0`** (only value defined by this doc). Required |
| 10-15 | | 6b | ascii | `storageUnitStructure` | Field 3. `RECORD` or `FIXREC`, left-justified (trailing blanks). Required |
| 16-19 | | 4b | ascii | `bindingEdition` | Field 4 (misprinted "Binding addition"). `B` + integer 1-999 (RP66 Part 3 edition), no leading zeros, left-justified, trailing blanks. Required |
| 20-29 | | 10b | ascii | `maxBlockSize` | Field 5. 0..4294967295, right-justified, leading blanks, no leading zeros. 0 = undeclared (`RECORD`: any length). `FIXREC` ⇒ ≠0 (= fixed record length). A value or 0 must be recorded |
| 30-39 | | 10b | ascii | `producerOrgCode` | Field 6. API producer organization code 0..4294967295, right-justified, leading blanks, no leading zeros. **Required in 2.0** (App. C list) |
| 40-50 | | 11b | ascii | `creationDate` | Field 7. `dd-MMM-yyyy`, MMM ∈ JAN..DEC, dd 1-31; day 1-9 may have one leading blank. Separator `-` (0x2D). Required |
| 51-62 | | 12b | ascii | `serialNumber` | Field 8. Enterprise storage-unit ID. If an external label exists, its name must be a subset occupying the rightmost chars of the serial number (or of External Label Name). Required |
| 63-68 | | 6b | ascii | `reserved` | Field 9. All blanks (0x20) |
| 69-80 | | 12b | ascii | `externalLabelName` | Field 10a (field 10 "Storage set identifier" = bytes 69-128). Right-justified, leading blanks. Blank if no physical label; required only if the physical label differs from the lower 6 chars of field 8 |
| 81-104 | | 24b | ascii | `recordingEntityName` | Field 10b. Crew/system ID, any alphanumerics. Required |
| 105-118 | | 14b | ascii | `userDefined` | Field 10c. Any ASCII |
| 119-128 | | 10b | ascii | `maxShotsPerFieldRecord` | Field 10d. Max shot records between File Marks |

Coverage: 4+5+6+4+10+10+11+12+6+12+24+14+10 = 128.

- The length column extracted cleanly in 2.0 [p.17] (it was split in the 2.1 extraction); lengths match start-end.
- "code 4510" / "code 3210" [p.18-19] are extraction of hex 2D₁₆ / 20₁₆.

> **AMBIGUITY [p.19]:** "The characters in this field are right justified" is stated for field 10 as a whole,
> before the sub-fields are listed. Justification of Recording Entity Name, User defined and Max shot records
> is not otherwise stated. Writer: right-justify numerics (Max shots), left-justify text; reader: trim both ends.

## 3. Header tables

### 3.1 General Header Block #1 (32 B) [p.33, p.40-42]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | ext | `fileNumber` | BCD F1-F4, 0-9999. `FFFF` ⇒ use GH#2 bytes 1-3 (file > 9999) |
| 3-4 | | 4n | bcd | `formatCode` | Y1-Y4, §4.1 |
| 5-10 | | 12n | bcd | `generalConstants` | K1..K12 |
| 11 | | 2n | bcd | `year` | YR1 YR2, last two digits, 0-99 |
| 12 | 12H | 4 bits | bits | `additionalGhBlocks` | GH3..GH0, **unsigned binary**: number of GH blocks after #1. ≥1 for Rev 1/2 (only #1+#2 ⇒ 1) |
| 12-13 | 12L-13L | 3n | bcd | `julianDay` | DY1 DY2 DY3, 1-366 |
| 14 | | 2n | bcd | `hour` | 0-23, **UTC** (GMT before Rev 2) [p.6 #16] |
| 15 | | 2n | bcd | `minute` | 0-59 |
| 16 | | 2n | bcd | `second` | 0-59 |
| 17 | | 2n | bcd | `manufacturerCode` | M1 M2, §4.10 |
| 18-19 | | 4n | bcd | `manufacturerSerial` | M3..M6 |
| 20-22 | | 3b | u8 | `unused20_22` | "Not used. Record as zero" (table shows `O`) |
| 23 | | 1b | fixedpt | `baseScanInterval` | binary I3..I-4 (`u4.u4`), LSB = 1/16 ms. Allowed 1,2,4,8,16,32,64,128 (= 1/16 … 8 ms) |
| 24 | 24H | 4 bits | bits | `polarity` | P, §4.6 |
| 24 | 24L | 4 bits | bits | `unused24L` | "Not used" (param text: X; bit table: `O`) |
| 25 | | 1b | u8 | `unused25` | "Not used" (param text: X; bit table: `O`) |
| 26 | 26H | 4 bits | bits | `recordType` | Z, §4.5 |
| 26-27 | 26L-27L | 3n | ext | `recordLength` | BCD R1 R2 . R3 ("RR.R") × 1.024 s; 00.5-99.5 ⇒ 0.512-101.888 s; 00.0 = indeterminate. `FFF` ⇒ use GH#2 bytes 15-17 (ms) |
| 28 | | 2n | bcd | `scanTypesPerRecord` | ST/R 1-99, 0 invalid |
| 29 | | 2n | ext | `channelSetsPerScanType` | BCD CS 1-99, 0 invalid; = max over scan types. `FF` ⇒ GH#2 bytes 4-5 |
| 30 | | 2n | bcd | `skewBlocks` | SK 0-99: 32-B skew fields after each scan type's CSDs; 0 = no skew |
| 31 | | 2n | ext | `extendedHeaderBlocks` | BCD EC 0-99. `FF` ⇒ GH#2 bytes 6-7 |
| 32 | | 2n | ext | `externalHeaderBlocks` | BCD EX 0-99. `FF` ⇒ GH#2 bytes 8-9 |

Coverage: 1-2, 3-4, 5-10, 11, 12H, 12L-13L, 14, 15, 16, 17, 18-19, 20-22, 23, 24H, 24L, 25, 26H, 26L-27L, 28, 29, 30, 31, 32 = 32 B, all nibbles.

> **AMBIGUITY [p.33, p.41]:** bytes 24L and 25: the bit table prints `O` (zero) in every bit, the parameter
> text says "X Not used". Only bytes 20-22 are explicitly "Record as zero". Reader: ignore; writer: write 0.

> **AMBIGUITY [p.33]:** byte 6 bit 6 extracted as `K` (should be K4); harmless.

### 3.2 General Header Block #2 (32 B) [p.34, p.43-44]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `extFileNumber` | EF23-EF0. Used when GH#1 bytes 1-2 = `FFFF` |
| 4-5 | | 2b | u16 | `extChannelSetsPerScanType` | EN15-EN0. Used when GH#1 byte 29 = `FF` |
| 6-7 | | 2b | u16 | `extExtendedHeaderBlocks` | ECX15-ECX0. Used when GH#1 byte 31 = `FF` |
| 8-9 | | 2b | u16 | `extExternalHeaderBlocks` | EH15-EH0. Used when GH#1 byte 32 = `FF` |
| 10 | | 1b | u8 | `undef10` | X |
| 11-12 | | 2b | fixedpt | `revision` | `u8.u8`: byte 11 REV7-REV0 integer, byte 12 REV-1..REV-8 **binary fraction**. "This version is Rev 2.00" ⇒ `02 00`. "Revisions 0 to 0.N are not valid" |
| 13-14 | | 2b | u16 | `generalTrailerBlocks` | GT15-GT0: number of 32-B General Trailer blocks |
| 15-17 | | 3b | u24 | `extRecordLength` | ERL23-ERL0: record length in **ms**; used when GH#1 26L-27L = `FFF` |
| 18 | | 1b | u8 | `undef18` | X |
| 19 | | 1b | u8 | `ghBlockNumber` | BN: = 2 (bit table `00000010`). 0 invalid |
| 20-32 | | 13b | u8 | `undef20_32` | X (**bytes 21-22 are X in 2.0**; sequence number only from 2.1) |

Coverage: 1-3, 4-5, 6-7, 8-9, 10, 11-12, 13-14, 15-17, 18, 19, 20-32 = 32 B.

> **AMBIGUITY [p.44]:** Note 1: "Two byte unsigned binary, range is 0 - FF, Four byte … 0 - FFFF, Three byte
> two's complement … -7FFFFF to +7FFFFF" — byte-count/range mismatch in source. Treat 2-byte as 0-FFFF,
> 3-byte unsigned as 0-FFFFFF.

> **AMBIGUITY [p.7 #6, p.20, p.43]:** bytes 4-5 are "Extended Channel Sets/Scan Types" but only replace GH#1
> byte 29 (channel sets per scan type). No extension exists for scan types per record (byte 28).

> **AMBIGUITY [p.43] (revision encoding):** 2.0 defines byte 12 as a binary fraction (value = b11 + b12/256);
> 2.1 redefines it as an unsigned minor number (`02 01` = 2.1). Both give 2.0 for `02 00`. Reader: treat as
> (major = b11, minor = b12) — the 2.1 reading — since no file encodes a fractional revision.

### 3.3 General Header Block #N, N ≥ 3 (32 B) [p.35, p.45-46]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `extFileNumber` | EF23-EF0, same as GH#2 |
| 4-8 | | 5b | fixedpt | `sourceLineNumber` | `i24.u16`: bytes 4-6 integer (SLNs sign, two's complement), 7-8 fraction SLN-1..SLN-16 |
| 9-13 | | 5b | fixedpt | `sourcePointNumber` | `i24.u16`: bytes 9-11 integer (SPNs), 12-13 fraction |
| 14 | | 1b | u8 | `sourcePointIndex` | SPI: starts 1, +1 each source move (even back to an old spot); 0 = not recorded |
| 15 | | 1b | u8 | `phaseControl` | PC, §4.8 |
| 16 | | 1b | u8 | `vibratorType` | V, §4.9 |
| 17-18 | | 2b | i16 | `phaseAngle` | PAs, PA14-PA0: degrees, pilot vs phase feedback. 0 when phaseControl = 0 ("undefined") |
| 19 | | 1b | u8 | `ghBlockNumber` | BN = N; 0 invalid |
| 20 | | 1b | u8 | `sourceSetNumber` | SS; "Zero is not valid" (real files write 0, §9) |
| 21-32 | | 12b | u8 | `undef21_32` | X |

Coverage: 1-3, 4-8, 9-13, 14, 15, 16, 17-18, 19, 20, 21-32 = 32 B.

Fixed-point decode: value = `int24 + u16/65536` = `int40 / 65536` over all 5 bytes (two's complement).

> **AMBIGUITY [p.7 #8, p.20 vs p.35, p.46]:** prose says phase angle is in "Bytes 28 and 29"; the bit table and
> parameter list put it at bytes 17-18 (28-29 are X). Use 17-18. (Same text in 2.1, not flagged there.)

> **AMBIGUITY [p.20, p.45 vs p.7, p.35]:** p.20 "General Header #2 provides locations to record the source
> location" and p.45 "General Header Block #2 contains the source location for one Source Set" contradict the
> tables (GH#2 has no source fields) and p.7 ("Block #3 contains the position for Source Set #1"). Use GH#3+.
> p.20 also says GH#3+ is "optional" and "Additional blocks may be added as needed by the manufacturer or user":
> check byte 19 = N before trusting the layout.

### 3.4 Scan type header = CS Channel Set Descriptors + SK skew blocks [p.20-22, p.46]

Per scan type: `CS` descriptors (32 B each, in recording order) then `SK` skew blocks (32 B each).
`ST/R` scan types, each with the same `CS` count; unused ⇒ dummy CSD with channels (bytes 9-10) = 0 [p.21 rule 3, p.42].
Ground rules [p.21]: CSD order = data order; each CSD once per scan type even with different sample intervals;
bytes per base scan interval constant over scan types; recommended order aux → long SI → short SI, same-SI sets contiguous.

Skew blocks: one byte per sample of each subscan of each channel set, in the order samples are recorded in the
scan; u8 fraction of BSI, LSB = BSI/256 (e.g. 7.8125 µs at 2 ms) [p.21]. Count: §6.2. Unused trailing bytes: unspecified (X).

### 3.5 Channel Set Descriptor (32 B) [p.36, p.46-49]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 2n | bcd | `scanTypeNumber` | ST1 ST2, 1..ST/R |
| 2 | | 2n | ext | `channelSetNumber` | BCD CN1 CN2, 1..CS. `FF` ⇒ bytes 27-28 (CS > 99 or binary numbering) |
| 3-4 | | 2b | u16 | `startTime` | TF16..TF1, LSB = 2 ms ⇒ ms = value×2 (0-131,070) |
| 5-6 | | 2b | u16 | `endTime` | TE16..TE1, LSB = 2 ms ⇒ ms = value×2. Single scan type: = record length |
| 7-8 | | 2b | fixedpt | `mpFactor` | sign-magnitude, **byte 8 is the high part**: §3.6 |
| 9-10 | | 4n | bcd | `channelCount` | C/S1-C/S4, 0-9999 (0 = dummy/unused) |
| 11 | 11H | 4 bits | bits | `channelType` | C, §4.3 |
| 11 | 11L | 4 bits | bits | `zero11L` | 0 |
| 12 | 12H | 1n | bcd | `subscanExponent` | S/C 0-9: subscans per base scan = 2^S/C (1-512) |
| 12 | 12L | 4 bits | bits | `gainControl` | J, §4.4 |
| 13-14 | | 4n | bcd | `aliasFilterFreq` | AF1-AF4, 0-9999 Hz |
| 15 | 15H | 1n | bcd | `zero15H` | 0 |
| 15-16 | 15L-16L | 3n | bcd | `aliasFilterSlope` | AS1-AS3, 0-999 dB/oct; 0 = filter out |
| 17-18 | | 4n | bcd | `lowCutFreq` | LC1-LC4, 0-9999 Hz |
| 19 | 19H | 1n | bcd | `zero19H` | 0 |
| 19-20 | 19L-20L | 3n | bcd | `lowCutSlope` | LS1-LS3, 0-999 dB/oct; 0 = filter out |
| 21-22 | | 4n | bcd | `notch1Freq` | NT1 NT2 NT3 . NT4 ⇒ Hz = value/10 (0-999.9); 000.0 = out |
| 23-24 | | 4n | bcd | `notch2Freq` | same |
| 25-26 | | 4n | bcd | `notch3Freq` | same |
| 27-28 | | 2b | u16 | `extChannelSetNumber` | ECS15-ECS0: "complete value that is (or should have been)" in byte 2 |
| 29 | 29H | 4 bits | bits | `extendedHeaderFlag` | EFH3..0, u4; 1 = extended header has more info on this channel set |
| 29 | 29L | 4 bits | bits | `traceHeaderExtensions` | THE3..0, u4 (0-15); "Must match byte 10 of the Demux Trace Header" |
| 30 | | 1b | u8 | `verticalStack` | VS: 0 = intentionally zeroed data, 1 = no stack, n = effective stack order |
| 31 | | 1b | u8 | `streamerNumber` | CAB: starboard-most = 1, port-most = N; 0 = not recorded |
| 32 | | 1b | u8 | `arrayForming` | ARY, §4.11 |

Coverage: 1, 2, 3-4, 5-6, 7-8, 9-10, 11H, 11L, 12H, 12L, 13-14, 15H, 15L-16L, 17-18, 19H, 19L-20L, 21-22, 23-24, 25-26, 27-28, 29H, 29L, 30, 31, 32 = 32 B.

> **AMBIGUITY [p.36]:** bit table typos: byte 3 `TE14` (→TF14), byte 4 `ETF4` (→TF4), byte 6
> `TE8 TE7 TE13 TE12 TE11 TE10 TE9 TE8` (→TE8..TE1), byte 20 `LS`, byte 26 `NT`. Parameter text [p.46-47]
> states bytes 3-4 = TF16..TF1, 5-6 = TE16..TE1. "TF1 = 21 msec" is extraction of 2^1. Treat both as plain u16.

> **AMBIGUITY [p.36, p.47]:** byte 8 bit 0 printed `MP5`; text says `MPS` (sign). Use sign.

### 3.6 MP factor (CSD bytes 7-8) [p.36, p.47, p.30]

| Byte | bit0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 7 | MP-3 | MP-4 | MP-5 | MP-6 | MP-7 | MP-8 | MP-9 | MP-10 |
| 8 | S | MP4 | MP3 | MP2 | MP1 | MP0 | MP-1 | MP-2 |

```
mag = ((b8 and 0x7F) shl 8) or b7        # 15-bit, LSB = 2^-10
mp  = mag / 1024.0 ; if (b8 and 0x80) != 0: mp = -mp
range ±31.9990234375 step 0.0009765625; pre-Rev1 (byte 8 only, byte 7 = 0): ±31.75 step 0.25
scale = 2^mp   (millivolts per recorded unit)
```

### 3.7 Demux Trace Header (20 B) [p.22-23, p.37, p.50-51]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | ext | `fileNumber` | BCD F1-F4. `FFFF` ⇒ bytes 18-20 |
| 3 | | 2n | bcd | `scanTypeNumber` | ST1 ST2 |
| 4 | | 2n | ext | `channelSetNumber` | BCD CN1 CN2. `FF` ⇒ bytes 16-17 |
| 5-6 | | 4n | bcd | `traceNumber` | TN1-TN4, 1-9999; first trace of each channel set = 1 |
| 7-9 | | 3b | fixedpt | `firstTimingWord` | `u16.u8` ms (T15..T-8): ms = u24/256 (0-65,535.9961; may wrap to 0 and continue) |
| 10 | | 1b | u8 | `traceHeaderExtensions` | THE7-THE0, 0-15; same for all traces of a channel set |
| 11 | | 1b | fixedpt | `sampleSkew` | SSK-1..SSK-8: u8/256 × base scan interval; = first skew byte of this channel in the scan type header |
| 12 | | 1b | u8 | `traceEdit` | TR, §4.7 |
| 13-15 | | 3b | fixedpt | `timeBreakWindow` | TW15..TW-8, `u16.u8` ms, as 7-9 |
| 16-17 | | 2b | u16 | `extChannelSetNumber` | EN15-EN0; used when byte 4 = `FF` |
| 18-20 | | 3b | u24 | `extFileNumber` | EFN23-EFN0; used when bytes 1-2 = `FFFF` |

Coverage: 1-2, 3, 4, 5-6, 7-9, 10, 11, 12, 13-15, 16-17, 18-20 = 20 B.

- Exact time of first sample = firstTimingWord + sampleSkew/256 × BSI [p.22, p.50].
- Timing word = time from energy-source event to start of that scan, whether or not the system resynchronizes
  (example: 0 + 1 + 9/256, 2 + 1 + 9/256, … ms) [p.22].
- timeBreakWindow < BSI ⇒ time break not detected; recording started at end of TB window [p.23].

> **AMBIGUITY [p.22] (resolved):** the §5.3 timing-word bit table labels its rows "Byte 5, 6, 7, 8" with byte 8 all
> zeros; this is the 4-byte multiplexed timing-word layout. The text on the same page, the §7.5 table [p.37] and
> §8.6 [p.50] all put T15..T-8 in **bytes 7, 8, 9**. Use bytes 7-9.

> **AMBIGUITY [p.50]:** "Scan Type Number … must be set to FF when the Extended Channel Set Number (bytes 16 & 17)
> is used" — meant byte 4 (Channel Set Number), which p.50-51 confirm. Byte 3 has no extension.

> **AMBIGUITY [p.5 #9, p.22, p.37, p.50] (resolved):** THE count: p.5 says byte 10 is "redefined as a 4 bit value";
> p.22 says "Byte 11"; the table [p.37] has THE7..THE0 and p.50 says "one byte, unsigned binary … Maximum allowed
> is 15". It is byte 10, a full u8 with value 0-15. Reject >15; must equal CSD byte 29L.

### 3.8 Trace Header Extension (32 B each, 0-15 per trace) [p.23, p.38, p.51]

Only the **first** extension has the layout below; extensions 2..THE are manufacturer/user defined [p.23].

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | ext | `receiverLineNumber` | i24 (RLNs sign). `FFFFFF` ⇒ use bytes 11-15 |
| 4-6 | | 3b | ext | `receiverPointNumber` | i24 (RPNs). `FFFFFF` ⇒ use bytes 16-20 |
| 7 | | 1b | i8 | `receiverPointIndex` | RPIs, RPI6-0 ("two's complement, signed"): starts 1, +1 each move |
| 8-10 | | 3b | u24 | `samplesPerTrace` | NBS23-NBS0: number of samples in this trace |
| 11-15 | | 5b | fixedpt | `extReceiverLineNumber` | `i24.u16` (§3.3 decode); "Only valid if bytes 1-3 … are set to FFFFFF" |
| 16-20 | | 5b | fixedpt | `extReceiverPointNumber` | `i24.u16`; only valid if 4-6 = `FFFFFF` |
| 21 | | 1b | u8 | `sensorType` | SEN, §4.12 (new in 2.0) |
| 22-32 | | 11b | u8 | `undef22_32` | X |

Coverage: 1-3, 4-6, 7, 8-10, 11-15, 16-20, 21, 22-32 = 32 B.

> **AMBIGUITY [p.38, p.51]:** `FFFFFF` is also two's-complement −1, so a receiver line/point of −1 cannot be
> written in bytes 1-3/4-6. Treat `FFFFFF` as the sentinel. Real files fill 11-20 even when 1-6 ≠ `FFFFFF` (§9):
> when 1-6 is not the sentinel, bytes 11-20 are X per spec (may hold a consistent copy).

### 3.9 General Trailer block (32 B each) [p.23-24, p.39, p.52]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 2b | u16 | `trailerNumber` | GT15-GT0: 1..GT; last block should equal GH#2 bytes 13-14 |
| 3-10 | | 8b | u8 | `undef3_10` | X |
| 11 | 11H | 4 bits | bits | `channelType` | C3-C0 = `1100` (0xC) = trailer |
| 11 | 11L | 4 bits | bits | `undef11L` | X ("second nibble … undefined") |
| 12-32 | | 21b | u8 | `undef12_32` | X (manufacturer/user) |

Coverage: 1-2, 3-10, 11H, 11L, 12-32 = 32 B.

### 3.10 Extended header / External header [p.23]

`EC` × 32 B (manufacturer-defined, "responsibility of the equipment manufacturer to establish a format") and
`EX` × 32 B (user-defined) opaque blobs. Keep raw.

## 4. Code tables

### 4.1 Format codes (GH#1 bytes 3-4, BCD) [p.40, p.8]

| Code | Sample format | Bytes/sample | Rev 2.0 legal |
|---|---|---|---|
| 8015 | 20-bit binary exponent (2½ byte), demux | 2.5 (10 B / 4 samples) | yes |
| 8022 | 8-bit quaternary exponent, demux | 1 | yes |
| 8024 | 16-bit quaternary exponent, demux | 2 | yes |
| 8036 | 24-bit two's complement integer, demux | 3 | yes |
| 8038 | 32-bit two's complement integer, demux | 4 | yes |
| 8042 | 8-bit hexadecimal exponent, demux | 1 | yes |
| 8044 | 16-bit hexadecimal exponent, demux | 2 | yes |
| 8048 | 32-bit hexadecimal (excess-64) exponent, demux | 4 | yes |
| 8058 | 32-bit IEEE float, demux | 4 | yes |
| 0036 / 0038 / 0058 | 24-bit int / 32-bit int / IEEE, multiplexed | 3 / 4 / 4 | no (Rev 1 additions, history only [p.8]) |
| 0200, 0000 | "Illegal, do not use" | — | — |

> **AMBIGUITY [p.25]:** "All recording methods are valid for multiplexed and demultiplexed records" is leftover
> Rev 1 text and contradicts "Rev 2 does not support multiplexed data" [p.4, p.11]. Other multiplexed codes
> (0015, 0022, …) and the multiplexed 20-bit layout are not defined here. Reader: raise unsupported for `0xxx`.

### 4.2 Unit/scale summary

| Field | Scale |
|---|---|
| GH1 base scan interval | value / 16 ms |
| GH1 record length | BCD RR.R × 1.024 s |
| GH2 ext record length | ms |
| CSD start/end time | value × 2 ms |
| CSD MP | §3.6, 2^MP mV |
| Trace timing word / TB window | u24 / 256 ms |
| Sample skew | u8/256 × BSI |
| Notch | BCD / 10 Hz |

### 4.3 Channel type (CSD byte 11H, trailer byte 11H) [p.47]

| Code | Meaning |
|---|---|
| 0x0 | Unused |
| 0x1 | Seis |
| 0x2 | Time break |
| 0x3 | Up hole |
| 0x4 | Water break |
| 0x5 | Time counter |
| 0x6 | External data |
| 0x7 | Other |
| 0x8 | Signature / unfiltered |
| 0x9 | Signature / filtered |
| 0xC | Auxiliary data trailer (General Trailer) |

### 4.4 Gain control method J (CSD byte 12L) [p.48]

| Code | Meaning |
|---|---|
| 1 | Individual AGC |
| 2 | Ganged AGC |
| 3 | Fixed gain |
| 4 | Programmed gain |
| 8 | Binary gain control |
| 9 | IFP gain control |

### 4.5 Record type Z (GH1 byte 26H) [p.41]

| Code | Meaning |
|---|---|
| 0x2 | Test record |
| 0x4 | Parallel channel test |
| 0x6 | Direct channel test |
| 0x8 | Normal record |
| 0x1 | Other |

### 4.6 Polarity P (GH1 byte 24H) [p.41]

| Code | Meaning |
|---|---|
| 0x0 | Untested |
| 0x1 | Zero |
| 0x2 | 45° |
| 0x3 | 90° |
| 0x4 | 135° |
| 0x5 | 180° |
| 0x6 | 225° |
| 0x7 | 270° |
| 0x8 | 315° |
| 0xC | unassigned |

> **AMBIGUITY [p.41]:** only `1100 unassigned` is listed; 0x9-0xB, 0xD-0xF unspecified. Pass through raw.

### 4.7 Trace edit TR (trace header byte 12) [p.50, p.5 #14]

| Code | Meaning |
|---|---|
| 0 | No edit |
| 1 | Dead channel for roll-on/roll-off; intentionally zeroed |
| 2 | Intentionally zeroed |
| 3 | Edited by acquisition system (sample fill/interpolation after telemetry error, noise edit) — new in 2.0 |
| other | "undefined at Rev 2.0" |

### 4.8 Phase control (GH#N byte 15) [p.45]

| Code | Meaning |
|---|---|
| 0 | Not recorded (phase angle undefined) |
| 1 | Baseplate accelerometer |
| 2 | Reaction mass |
| 3 | Weighted sum (baseplate accel × mass + reaction mass accel × its mass) |
| 4 | Direct force measurement |

### 4.9 Vibrator type (GH#N byte 16) [p.45]

| Code | Meaning |
|---|---|
| 0 | Not recorded |
| 1 | P wave |
| 2 | Shear wave |
| 3 | Marine |

### 4.10 Manufacturer codes (GH1 byte 17) [p.53-55]

| Code | Name | Code | Name |
|---|---|---|---|
| 01 | Alpine Geophysical Associates (obsolete) | 20 | Fairfield Industries |
| 02 | Applied Magnetics Corp (see 09) | 22 | Geco-Prakla (Gatwick) |
| 03 | Western Geophysical Exploration Products (ex Litton) | 31 | Japex Geoscience Institute |
| 04 | SIE Inc. (obsolete) | 32 | Halliburton Geophysical Services |
| 05 | Dyna-Tronics (obsolete) | 33 | Compuseis |
| 06 | Electronic Instrumentation (obsolete) | 34 | Syntron |
| 07 | Halliburton Geophysical Services (ex Geosource) | 35 | Syntron Europe |
| 08 | Fortune Electronics (obsolete) | 36 | Opseis |
| 09 | Geo Space Corporation | 39 | Grant Geophysical |
| 10 | Leach Corporation (obsolete) | 40 | Geo-X |
| 11 | Metrix Instrument (obsolete) | 41 | PGS Inc. |
| 12 | Redcor (obsolete) | 42 | SeaMap UK |
| 13 | Sercel | 43 | Hydroscience (Hydroscience Technologies) |
| 14 | Scientific Data Systems (obsolete) | 44 | JSC Special Design Bureau for Seismic Instrumentation (Saratov) |
| 15 | Texas Instruments | 45 | Fugro |
| 17 | GUS Manufacturing | 46 | ProFocus Systems AS |
| 18 | Input/Output Inc. | | |
| 19 | Geco-Prakla (Transition Zone, ex Terra Marine) | | |

(2.1 adds 47 Optoplan AS, 48 Wireless Seismic Inc. Reader: unknown codes pass through.)

### 4.11 Array forming (CSD byte 32) [p.49]

| Value | Meaning |
|---|---|
| 0x01 | No array forming |
| 0x0N (N≥2) | N groups summed, no weighting |
| 0x1N | N groups weighted, overlapping summation |
| 0x00 | not defined (written by real files, §9: read as "not recorded / none") |

### 4.12 Sensor type (THE#1 byte 21) [p.51]

| Code | Meaning |
|---|---|
| 0 | Not defined |
| 1 | Hydrophone (pressure) |
| 2 | Geophone (velocity) vertical |
| 3 | Geophone horizontal inline |
| 4 | Geophone horizontal crossline |
| 5 | Geophone horizontal other |
| 6 | Accelerometer vertical |
| 7 | Accelerometer horizontal inline |
| 8 | Accelerometer horizontal crossline |
| 9 | Accelerometer horizontal other |
| other | not defined |

### 4.13 Maximum block sizes (App. F) [p.65]

| Device | Max block |
|---|---|
| 3480 | 128 KiB |
| 3490, 3490E | 256 KiB |
| 3590 | 512 KiB |
| DST | 1,199,840 B |
| Redwood | 256 KiB |
| ½" round tape | 64 KiB |

"Kilobyte is defined as 1024 bytes." Informational only.

## 5. Data sample formats [p.25-31, p.8]

General: sample bytes follow the trace header (+extensions) contiguously; big-endian; no inter-sample padding.
Physical value (mV) = `decoded × 2^MP`, `decoded` = fraction × base^exp (float formats) or the integer (integer
formats). "The same number system is to be used on all samples in a record, including auxiliary" [p.25].
Bits below: bit 0 = MSB.

### 5.1 8015 — 20-bit binary exponent, demultiplexed (4 samples per 10 bytes) [p.26]

| Byte | bits 0-3 (H) | bits 4-7 (L) |
|---|---|---|
| 1 | C3-C0 (sample 1) | C3-C0 (sample 2) |
| 2 | C3-C0 (sample 3) | C3-C0 (sample 4) |
| 3-4 | sample 1: S Q-1..Q-15 (16 bits) | |
| 5-6 | sample 2 | |
| 7-8 | sample 3 | |
| 9-10 | sample 4 | |

- C: u4 binary exponent of 2 (0-15), "in sample order … starting with the first sample in bits 0-3 of Byte 1".
- S + Q-1..Q-15: **one's complement** 16-bit fraction, radix left of Q-1, range ±(1−2^-15).
- "Negative zero is invalid and must be converted to positive zero" (`0xFFFF` → `0x0000`) — only meaningful
  for one's complement, so the spec is unambiguous here.
- Samples per trace **must be exactly divisible by 4**; data bytes = samples/4 × 10.
- Demux uses the LSB (Q-15); the multiplexed variant does not [p.25].

```
decode group g (10 bytes):
  e = [g[0] shr 4, g[0] and 0xF, g[1] shr 4, g[1] and 0xF]
  for k in 0..3:
    w = (g[2+2k] shl 8) or g[3+2k]          # u16
    m = if (w and 0x8000) != 0: -int((not w) and 0xFFFF) else int(w)   # one's complement
    v = m / 32768.0 * 2^e[k]                 # then * 2^MP
encode (x = v / 2^MP):
  pick smallest e in 0..15 with |x| / 2^e < 1 (clip at e=15, mag 0x7FFF)
  mag = round(|x| / 2^e * 32768) clamp 0..0x7FFF
  w = if x < 0 and mag != 0: (not mag) and 0xFFFF else mag
```

> **AMBIGUITY [p.26]:** spec = one's complement (explicit, plus the negative-zero rule). Some field systems/readers
> decode as two's complement (`int16`); negatives differ by 1 LSB. Keep a reader option, default one's complement.
> No real 8015 file is available to test. Footnote marker "b" after "samples 1 thru 4" is extraction noise.

### 5.2 8022 — 1-byte quaternary exponent [p.25]

`S C2 C1 C0 Q-1 Q-2 Q-3 Q-4`. C = u3 exponent of 4 (0-7). S+Q = **one's complement** 4-bit fraction (radix left
of Q-1), range ±(1−2^-4). Decode: `q = b and 0xF; m = if S: -(q xor 0xF) else q; v = m/16 * 4^C`.
Negative zero invalid → +0.

### 5.3 8024 — 2-byte quaternary exponent [p.25-26]

Byte 1 `S C2 C1 C0 Q-1..Q-4`, byte 2 `Q-5..Q-12`. 12-bit one's complement fraction with S, range ±(1−2^-12).
`C = (w shr 12) and 7; q = w and 0x0FFF; m = if S: -(q xor 0xFFF) else q; v = m/4096 * 4^C`. Negative zero invalid → +0.

### 5.4 8042 — 1-byte hexadecimal exponent [p.27]

`S C1 C0 Q-1..Q-5`. C = u2 exponent of 16 (0-3). Q = 5-bit **positive** fraction (sign-magnitude).
`v = (-1)^S * (b and 0x1F)/32 * 16^((b shr 5) and 3)`. All-ones `0xFF` invalid.

> **AMBIGUITY [p.27]:** bit table labels exponent bits `C-1 C-0`; text says "two [bit] positive binary exponent"
> → C1 C0. Range "-(1 - 2^-4) x 16^3" inconsistent with a 5-bit fraction (should be 2^-5); ignore.

### 5.5 8044 — 2-byte hexadecimal exponent [p.27]

Byte 1 `S C1 C0 Q-1..Q-5`, byte 2 `Q-6..Q-13`. Sign-magnitude, 13-bit fraction.
`v = (-1)^S * (w and 0x1FFF)/8192 * 16^((w shr 13) and 3)`. `0xFFFF` invalid.

> **AMBIGUITY [p.27]:** range text "-(1 - 2^-12) x 16^3" (split across lines) should be 2^-13; ignore.

### 5.6 8048 — 4-byte hexadecimal excess-64 [p.28]

| Byte | bits 0..7 |
|---|---|
| 1 | S C6..C0 |
| 2 | Q-1..Q-8 |
| 3 | Q-9..Q-16 |
| 4 | Q-17..Q-23, 0 |

`v = (-1)^S * F/2^23 * 16^(C-64)` with `F = (w shr 1) and 0x7FFFFF`. Equals IBM hex float (`ibm32`) with the last
fraction bit forced 0. "Must always be written as a hexadecimal left justified number"; fraction 0 ⇒ whole word 0;
bit 7 of byte 4 must be 0. MP "may be recorded as zero".

### 5.7 8058 — IEEE 754 single, big-endian [p.8, p.28-29]

Standard `f32` BE. NaN = invalid sample; all other values valid (incl. ±∞, denormals, ±0). Bit 7 of byte 4 may be
non-zero in demux (must be 0 only in 0058).

> **AMBIGUITY [p.28]:** the second copy reads `if e = 255 & f = 0 … NaN` (≠ lost); p.8 has `f ¹ 0` (≠).
> Use standard IEEE.

### 5.8 8036 — 24-bit integer [p.30]

`i24` two's complement BE (S I22..I0). `v = i24` (then × 2^MP).

### 5.9 8038 — 32-bit integer [p.30]

`i32` two's complement BE (S I30..I0).

> **AMBIGUITY [p.30]:** 32-bit table byte 2 starts `I22 I22` (should be I23 I22). Plain `i32`.

## 6. Derived rules / algorithms

### 6.1 Resolved header counts

```
nGh   = 1 + GH1[12].H                           # total GH blocks (≥2 for Rev 1/2)
file  = GH1[1-2]==0xFFFF ? GH2.extFileNumber : bcd(GH1[1-2])
nST   = bcd(GH1[28])
nCS   = GH1[29]==0xFF ? GH2.extChannelSetsPerScanType : bcd(GH1[29])
nSK   = bcd(GH1[30])
nEC   = GH1[31]==0xFF ? GH2.extExtendedHeaderBlocks : bcd(GH1[31])
nEX   = GH1[32]==0xFF ? GH2.extExternalHeaderBlocks : bcd(GH1[32])
recLenMs = GH1[26L-27L]==0xFFF ? GH2.extRecordLength : rr_r * 1024     # rr_r = BCD RR.R as a decimal
nGT   = GH2.generalTrailerBlocks
csNum = CSD[2]==0xFF ? CSD.ext(27-28) : bcd(CSD[2])
```

### 6.2 Sizes [p.21-22, p.63-64]

```
headerBytes = 32*nGh + 32*nST*(nCS + nSK) + 32*nEC + 32*nEX
sampleInterval(cs) = BSI_ms / 2^(cs.subscanExponent)
nSamples(cs) = THE#1.samplesPerTrace if THE>=1 else (cs.endTime*2 - cs.startTime*2) / sampleInterval(cs)
traceDataBytes = nSamples * bytesPerSample          # 8015: nSamples/4*10
traceBytes(cs) = 20 + 32*cs.traceHeaderExtensions + traceDataBytes   # constant within a channel set [p.22 rule 7]
nTraces = Σ over scan types, channel sets: bcd(cs.channelCount)
recordBytes = headerBytes + Σ traceBytes + 32*nGT
FIXREC: next record starts at next multiple of label.maxBlockSize (shot records are block-aligned)
```

App. E (now extracted) [p.63-64]:
- E.1 samples per scan type: `S/S = Σ_{cs=1..CS} C/S(cs) × 2^(S/C(cs))`. "Note that all scan types must have the
  same number of data samples." Example: BSI 2 ms, 4 aux @2 ms + 96 @2 ms + 12 @½ ms ⇒ 4 + 96 + 48 = 148.
- E.2 skew fields: `SK = ceil(S/S / 32)`; example 148/32 = 4 20/32 ⇒ **5**.
- E.3 filter slopes (writer only; round to nearest integer):
  `LS = 40 / log2(fLCO/f40) = 12.04 / log10(fLCO/f40)` (f40 = 40 dB point, fLCO = cut-off, usually 6 or 12 dB);
  `AS = 60 / log2(f60/fACO) = 18.06 / log10(f60/fACO)` (fACO usually 3 or 6 dB).
- E.3 is cited from GH1 byte 30 / CSD 15-16 as "Appendix E3" (skew = this doc's E.2). E.4 (dummy CSDs,
  "Example 6") and E.7 (MP) are referenced [p.42, p.46-47, p.9] but **not present** in this document.

> **AMBIGUITY [p.23, p.47, p.63]:** samples per trace without a trace header extension is **not defined** anywhere
> in 2.0 (App. E has no such example). The real file `63.sgd` has NBS = 1000 = (2000 − 0)/2 ms exactly, i.e.
> `(TE−TF)/SI` with **no +1**. Rule: NBS when THE ≥ 1, else `(TE−TF)/SI`; validate against the next trace header.

### 6.3 Validation

| Rule | Source |
|---|---|
| nST ≥ 1, nCS ≥ 1 | p.41 |
| every scan type has nCS descriptors; unused ones have channelCount 0 | p.21, p.42 |
| bytes per base scan interval (and samples per scan) constant over scan types | p.21 rule 4, p.63 |
| THE ≤ 15; trace header byte 10 == CSD byte 29L | p.4-5, p.48, p.50 |
| all traces in a channel set same length | p.5 #10, p.22 |
| 8015: nSamples mod 4 == 0 | p.26 |
| GH2 byte 19 == 2; GH#N byte 19 == N | p.43, p.46 |
| trailer block byte 11H == 0xC, bytes 1-2 == 1..nGT | p.52 |
| label bytes 10-15 ∈ {`RECORD`,`FIXREC`}; FIXREC ⇒ maxBlockSize > 0 | p.18 |
| label bytes 5-9 == `SD2.0` | p.18 |
| BCD nibbles ≤ 9 except documented `F` sentinels | p.40 |
| GH#N byte 20 source set ≠ 0, CSD byte 32 ≠ 0: spec rules, but **warn only** (violated by real files, §9) | p.46, p.49 |

### 6.4 Version detection

| Signal | Meaning |
|---|---|
| Label bytes 5-9 = `SD2.0` | Rev 2.0 tape |
| GH1 byte 12H = 0 | original (Rev 0) SEG-D, no GH#2 |
| GH1 byte 12H ≥ 1 | Rev ≥ 1 |
| GH2 bytes 11,12 = 02,00 | Rev 2.0 (02,01 ⇒ 2.1) |

> **AMBIGUITY [p.6 #3, p.43]:** Rev 1 defined bytes 11-12 as one u16 revision "= 1" (`00 01`); Rev 2.0 reinterprets
> them as `u8.u8` ("Revisions 0 to 0.N are not valid"), under which `00 01` = 0.0039. Accept u16 = 1 or b11 = 1 as Rev 1.

## 7. Implementation notes

### 7.1 Gotchas
- Bit 0 = MSB everywhere.
- MP: byte 7 is the **low** part, byte 8 the high part with the sign.
- GH1 byte 12: binary nibble + BCD nibble in one byte; DY spans 12L-13L.
- GH1 bytes 26-27: binary record-type nibble + 3-nibble BCD record length; sentinel is `FFF` (nibbles).
- Test `FF`/`FFFF`/`FFF` sentinels before BCD-decoding (they are invalid BCD).
- CSD bytes 27-28 "contain the complete value", so they may be filled when byte 2 is BCD; same in practice for
  trace header 16-20 (§9). Accept; warn if they disagree with the BCD field.
- Trace number: BCD 4 digits only; no extended trace number.
- Fractional positions (`i24.u16`): signed int part + unsigned fraction/65536.
- Disk files: no label in practice; auto-detect `SD\d.\d` at bytes 5-9 (see §9).
- GH2 bytes 21-22 are X in 2.0: preserve raw; do not interpret as a sequence number.

### 7.2 Writer defaults for Rev 2.0
- GH2 bytes 11-12 = `02 00`; label `SD2.0`; label field 6 must be non-blank (use `         0`-style right-justified number).
- X bytes, GH1 20-22/24L/25, unused skew bytes and FIXREC padding: write 0.
- CSD byte 32 = 0x01 when no array forming; GH#N byte 20 ≥ 1.

### 7.3 Rev 2.0 vs Rev 1 [p.4-6]

| # | Change |
|---|---|
| 1-2 | Media 3490/3490E, 3590, D2, D3; multiplexed data not supported |
| 3-4 | (no change for non-shot-domain data or SPS) |
| 5 | MP description clarified for fixed-point data |
| 6 | GH1 byte 12 = number of *additional* blocks; GH1 bytes 1-2 `FFFF` when file > 9999 |
| 7 | THE bytes 1-3/4-6 `FFFFFF` ⇒ fractional extended receiver line/point at bytes 11-15/16-20 |
| 8-9 | THE count ≤ 15, uniform per channel set, stored in CSD byte 29L and trace header byte 10 |
| 10 | Uniform trace length per channel set |
| 11 | Storage unit label required on each tape |
| 12-13 | RECORD/FIXREC device structures, large blocks; App. F block sizes |
| 14 | Trace edit code 3 |
| 15 | Byte-stream model; File Marks optional at shot boundaries; EOD required on tape |
| 16 | GH1 time base GMT → UTC |
| 17 | Tape partitioning; label = first 128 B of first user-writable record |
| 18 | THE byte 21 sensor type |

### 7.4 Rev 1 vs Rev 0 [p.6-10]

| # | Change |
|---|---|
| 1 | Additional GH blocks (and trace header extensions) |
| 2 | General Trailer (count in GH2 bytes 13-14) |
| 3 | Revision number GH2 11-12 (u16 = 1); GH1 byte 12H additional blocks ≥1 |
| 4 | Source positions in GH#3+, receiver positions in THE |
| 5-7 | Extended file number, channel sets, extended/external block counts in GH2 |
| 8 | Vibrator phase control/type/phase angle in GH#N |
| 9 | THE bytes 8-10 samples per trace |
| 10 | ½" square cartridges |
| 11 | Formats 0036/0038/0058/8036/8038/8058 |
| 12 | Blocked demux data (GH1 byte 20 B1, ≤128 KB) — superseded in Rev 2 |
| 13 | CSD byte 30 vertical stack |
| 14 | Undefined fields defined as "undefined by this format" |
| 15 | Trace edit byte (codes 0-2) — text says "byte 10", actually byte 12 |
| 16 | MP extension byte 7 |
| 17 | CSD byte 31 streamer, byte 32 array forming; channel-set definition; trace number restarts at 1 per set |
| 18 | MP formula corrected |
| 19 | Extended record length in ms (GH2 15-17, R = FFF) |

> **AMBIGUITY [p.8 #15]:** history says "Trace Edit byte (byte 10 of Demux Trace Header)"; tables put trace edit at
> byte 12 and THE count at byte 10. Use the tables.

### 7.5 MP computation (writer side) [p.9, p.30-32]

| Data | Formula | Cmax |
|---|---|---|
| binary exponent (8015) | MP = FS − PA − Cmax | 15 |
| quaternary (8022/8024) | MP = FS − PA − 2·Cmax | 7 |
| hex non-excess (8042/8044) | MP = FS − PA − 4·Cmax | 3 |
| hex excess-64 (8048), IEEE (8058) | MP = FS − PA − 4·(Cmax − 64) | 64 (⇒ term 0) |
| integer (8036/8038) | MP = FS − PA − IS | 2^(IS−1) = integer positive full scale |

2^FS = converter full scale (mV); 2^PA = minimum system gain (preamp × min FP amp gain, incl. ADC adjustment;
e.g. 256×1 or 320×0.8 ⇒ PA = 8; a 10 V converter with 1.221 gain may be folded into PA).

## 8. Differences vs `segd_rev2_1.md`

Every byte table, code table and sample format is identical (word-level diff, see header). Differences:

| # | Item | Rev 2.0 (this doc) | Rev 2.1 note | Impact |
|---|---|---|---|---|
| 1 | Label bytes 5-9 | `SD2.0` only [p.18] | `SD2.1` (SD2.0 = previous) | accept both |
| 2 | Label field 6 (30-39) | **required**, API producer org code [p.18] | optional (all blanks allowed), Energistics | 2.0 writer must fill; reader accepts blanks |
| 3 | Label field 4 name | "Binding addition" (typo) [p.17] | "Binding edition" | none |
| 4 | Label length column | extracted cleanly [p.17] | split in extraction (AMBIGUITY) | 2.1 AMBIGUITY resolved, lengths confirmed |
| 5 | GH2 bytes 11-12 | REV7-0 + REV-1..-8: `u8` + **binary fraction** byte, "Rev 2.00" = `02 00` [p.34, p.43] | RMJ/RMN: major/minor u8 each, `02 01` | read as major/minor; 2.0 = `02 00` |
| 6 | GH2 bytes 21-22 | X (undefined) [p.34, p.43 "20 - 32 X"] | line sequence number u16 | 2.0: keep raw |
| 7 | GH2 undefined range | 20-32 X | 20 X, 23-32 X | — |
| 8 | Multiple lines per tape | not addressed | allowed if (file no., seq no.) unique | n/a |
| 9 | Trace edit "other codes" | "undefined at Rev 2.0" [p.50] | "undefined at Rev 2.1 and 2.0" | none |
| 10 | App. A | codes 01-46 (Jan 2006 list) | adds 47 Optoplan AS, 48 Wireless Seismic Inc. (2008) | pass unknown codes through |
| 11 | App. C | API E&P producer organization codes (older list, e.g. 40 BPB, 129 Digicon, 463 SEG High Density Media Format Subcommittee) | Energistics/POSC list (e.g. adds 9 Amerada Hess, 15 Baker Hughes Inteq, 368 PGS, 469 Sercel, 475 Troika; 40 → Reeves) | label field 6 is a number; no parsing impact |
| 12 | App. D | single `REV` entry (GH2 revision); no `SN` | `RMJ`, `RMN`, `SN` (sequence number) | consistent with #5, #6 |
| 13 | App. E | E.1 (samples per scan type, "all scan types must have the same number of data samples") **extracted** [p.63]; E.2, E.3 [p.63-64] | E.1 page blank in extraction, E.2/E.3 partial | §6.2; still no samples-per-trace rule |
| 14 | App. F | 3480, 3490/3490E, **3590 = 512 KiB** (no B/E split), DST, Redwood, ½" round [p.65] | 3590 B 512 KiB, **3590 E 2 MiB**, IBM 3592, TS1120 (2 MiB), STK 9940B 256 KiB; MiB defined | informational |
| 15 | Change history | §2.0 (2.0 vs 1) and §2.1 (Rev 1) only | adds "Changes in Rev 2.1" | — |
| 16 | Overview wording | "Rev 2" | "Rev 2.x" | none |
| 17 | Page numbers | this file's markers | 2.1 file's markers (differ) | citations not interchangeable |

Corrections/additions to the 2.1 note found while checking (same text in both revisions):
- Phase angle prose says GH#N "Bytes 28 and 29" [p.7, p.20]; tables say 17-18 (not flagged in 2.1 note) — §3.3.
- Rev 1 history says trace edit is "byte 10" [p.8 #15] — §7.4.
- GH1 24L/25: bit table `O` vs text "X not used" — §3.1.
- 8044/8038 bit-table typos — §5.5, §5.9.
- §5.3 timing-word table is the multiplexed 4-byte layout (resolves the "bytes 5-8" ambiguity) — §3.7.
- Open items resolved from 2.0: GH1 byte 20 = record as zero (Rev 1 B1 blocked flag is history only);
  timing word = bytes 7-9; THE count = byte 10 full byte; 8015 = one's complement (negative-zero rule);
  App. E extracted but samples-without-THE still undefined (real data: `(TE−TF)/SI`).

## 9. Check of `segd_rev2_0_delta.md`

Ground truth: the 2.0 text above, plus a fresh hex dump of `SEG Spec/exampleFiles/63.sgd` (first 400 B).

| Delta claim | Verdict | Evidence |
|---|---|---|
| GH2 bytes 11-12 = `02 00` | **confirmed** ("This version is Rev 2.00") | p.43; file `02 00` at offset 42-43 |
| Label bytes 5-9 = `SD2.0` | **confirmed** | p.18 |
| Label field 6 required in 2.0 | **confirmed** | p.18 "This field is required" |
| GH2 bytes 21-22 undefined (X) | **confirmed** | p.34, p.43 |
| Multiple production lines not addressed | **confirmed** | absent from 2.0 |
| Media list lacks 9940B/3592/TS1120 | **confirmed**; delta omits that 2.0 also lacks 3590 E (2 MiB) and the 3590 B/E split | p.65 |
| App. A/C are older lists | **confirmed**: A ends at 46; C is the API list (not Energistics) | p.53-59 |
| "Everything else identical" (GH1, GH#N, CSD, trace header, THE#1, trailer, EC/EX, formats, demux only) | **confirmed** by word-level diff; minor non-layout differences in §8 (#5 revision encoding semantic, App. D/E/F) | §8 |
| Disk files carry no label | **consistent**: 2.0 requires the label on *tapes* only [p.5, p.11]; disk not addressed. Real file starts at GH1 | file offset 0 = `00 63 80 58` |
| Block order GH1, GH2, GH3.., CSD/skew, EC, EX, traces, GT | **consistent** with p.20-24 listing; Figure 1 image-only; tiling of `63.sgd` (4340 B) confirmed | §2.1 |
| `recordLength` `FFF` ⇒ GH2 15-17 in ms (2000) | **confirmed** | p.41, p.43; file GH1 26-27 `8F FF`, GH2 15-17 `00 07 D0` |
| Walk values (GH1, GH2, GH3, CSD, trace, THE#1, 1000 × f32, EOF at 4340) | **re-verified** byte-by-byte for GH1-CSD, trace header and THE#1 | hex dump |
| "GH1 bytes 20-22, 24L and 25 are 0, as the spec requires" | **partly contradicted**: only 20-22 are "Record as zero"; 24L and 25 are "X Not used" in the text (bit table shows `O`) | p.33, p.41 |
| Walk: GH3 "source set 0" | **contradicts the spec** (not flagged by delta): "Source Set Number … Zero is not valid". Real file wins: accept 0 | p.46; GH3 byte 20 = `00` |
| Walk: CSD byte 32 (not reported by delta) | file writes `00`; spec defines only `01` = no array forming, `0N`, `1N`. Accept 0 as "none/not recorded" | p.49; CSD byte 32 = `00` |
| Walk: THE#1 (not reported by delta) | bytes 11-15 = `00 00 0D 00 00` (13.0) and 16-20 = `00 00 68 00 00` (104.0) filled although 1-3/4-6 are not `FFFFFF`; spec: "only valid if … FFFFFF". Consistent copy; accept | p.51 |
| Extended copies in trace header 16-20 filled while BCD valid | **consistent**: spec doesn't forbid; CSD 27-28 "is (or should have been)" | p.48, p.50-51 |
| Alias slope 461 dB/oct valid BCD | **confirmed** (0-999) | p.48; CSD 15-16 = `04 61` |
| 8015 negative polarity untested | **still open**; 2.0 text is explicit (one's complement + negative-zero rule) | p.26 |
| Samples without THE (not in delta) | real file supports `(TE−TF)/SI` (1000 = 2000/2), no +1 | §6.2 |

## 10. Open questions

1. Samples per trace when THE = 0: not defined in 2.0 (App. E has no rule). Use `(TE−TF)/SI` (consistent with
   `63.sgd`); revisit if a THE = 0 file disagrees.
2. 8015 negatives: spec = one's complement; common practice may be two's. Default one's, reader option. No test file.
3. FIXREC on disk: is the label its own 128-B block or padded to `maxBlockSize`? Alignment origin unspecified.
4. Trace order across multiple scan types is not stated: identify traces from their own headers.
5. Multiplexed codes (0015 … 0058): not defined here; raise unsupported (owner decision in 2.1 note).
6. GH#3+ may be manufacturer-specific (p.20); validate byte 19 = N.
7. Unused skew bytes, FIXREC padding, X bytes: unspecified; ignore on read, write 0.
8. Undefined code points (polarity 0x9-0xF, trace edit >3, sensor >9, array forming 0x00, manufacturer
   codes): pass through raw; warn only.
9. Spec-invalid zeros seen in real data (GH#N source set 0, CSD array forming 0): accept with warning, never reject.
10. GH2 byte 12 fraction (2.0) vs minor (2.1): only `00` occurs for 2.0, so harmless; a non-zero byte 12 with
    label `SD2.0` would be inconsistent — trust GH2 and warn.
11. Label sub-field justification in field 10 (except External Label Name) is not stated; trim on read.
