# SEG-D Rev 2.1 (January 2006) — implementation spec note

Source: `SEG Spec/text/seg_d_rev2.1_.txt`. All `[p.N]` are `=== PAGE N ===` markers.

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| p.1-4 | Title, TOC, introduction, committee | skipped (no format content) |
| p.5-11 | Changes in Rev 2.1 / 2.0 / 1.0 | yes (§7) |
| p.12-13 | Format overview, device structures, file marks | yes (§2) |
| p.14-17 | Figures (Figure 1 record structure etc.) | **blank in extraction**, see AMBIGUITY in §2 |
| p.18-20 | Storage unit (tape) label | yes |
| p.21-24 | Header block descriptions | yes |
| p.25-30 | Data recording methods, MP factor | yes (§5, §6) |
| p.31-37 | Header bit tables (7.x) | yes (§3) |
| p.38-47 | Header parameter descriptions (8.x) | yes (§3, §4) |
| p.48-51 | App. A manufacturer codes | compact table (§4) |
| p.52-53 | App. B glossary | only tape-file/EOD terms used (§2) |
| p.54-57 | App. C producer organization codes (RP66) | skipped except note; label field 6 is just a number |
| p.58-60 | App. D abbreviation index | skipped (redundant with tables) |
| p.61-62 | App. E examples/calculations | **p.61 blank, p.62 partial** (skew example, filter slope) |
| p.63 | App. F max block sizes | yes (§4) |

Conventions used here:
- **Spec bit numbering: bit 0 = MSB (value 128), bit 7 = LSB (value 1)** [p.31]. In the tables below
  `H` = bits 0-3 (`b shr 4`), `L` = bits 4-7 (`b and 0x0F`).
- All multi-byte binary fields are big-endian, **except MP factor** (CSD bytes 7-8, see §3.6).
- "BCD" = packed BCD, MSD in high nibble [p.31]. "All values are in packed BCD unless otherwise specified" [p.38].
- `X` = undefined by the format, any value [p.36].

## 2. File / tape structure

### 2.1 Storage unit and record sequence [p.7, p.12-13, p.18]

```
Storage unit (tape, or one tape partition):
  Storage Unit Label (128 bytes ASCII, first user-writable record)   [optional File Mark]
  Shot record 1
  [File Mark]                     (only allowed at shot-record boundaries)
  Shot record 2
  ...
  EOD                             (tape: required after last valid record)

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
  Trace 1: Demux Trace Header 20 B + THE x 32 B Trace Header Extensions + sample data
  Trace 2 ...
  General Trailer blocks                  GT x 32 B   (optional)
```

> **AMBIGUITY [p.14-17, p.21]:** Figure 1 (record structure) did not extract. Order GH → scan-type headers →
> extended → external is inferred from the listing order in §5.0 [p.21] and "Section 5.4/5.5" order; trailer
> "follows all other recorded data" [p.24]. Trace order (by scan type, then channel set in descriptor order,
> then channel/trace number) is inferred from ground rule 1 [p.22] ("order in which the data are recorded for
> each channel set") and "first channel in each channel set will start with trace number one" [p.22]. Not stated
> explicitly.

Rules:
- Rev 2.x records are **demultiplexed only**; "Rev 2.x does not support multiplexed data records" [p.12, p.6 #2].
- No File Mark before the label; nothing (no ANSI label) before the label [p.7 #17, p.20].
- Each partition starts with its own label and must be decodable in isolation; partitions may mix SEG-D and non-SEG-D [p.13, p.18].
- File Marks optional, only at shot-record boundaries; "preferably for every shot" on field tapes [p.12].
- Several shots per file allowed on disk [p.12].
- More than one production line per tape allowed if (field file number, line sequence number GH#2 bytes 21-22) is unique per storage unit [p.5 #4].
- Tape file = data between two File Marks (or FM and EOD). EOD is typically two consecutive FMs, possibly more [p.52].
- Label field 10 "Max shot records per field record": field record = data between File Marks [p.20].

### 2.2 Device structures [p.7, p.12]

| Type | Label field 3 | Block rule |
|---|---|---|
| A Variable block length | `RECORD` | each block holds data of one shot only; multiple channel sets per block; **no padding** in short blocks |
| B Byte stream | `RECORD` | no blocks; shots written consecutively without gap within a file |
| C Fixed block length | `FIXREC` | each block holds one shot only; last block of a shot **padded** (content meaningless) to block size = label field 5 |

- Blocked data: all headers may share a block with the first channel set; channel sets may span blocks; **block boundaries may not occur within a trace** [p.12].
- Rev 1 blocked rule (historical): integral number of traces per block, headers not blocked, blocks ≤128 KB, all traces in a block same channel set [p.10 #12]. Superseded by the above for Rev 2.x.
- On disk: A cannot reproduce gaps/FMs; B and C map directly (except original FM positions) [p.12].

> **AMBIGUITY [p.7, p.10, p.39]:** Rev 1 says GH#1 byte 20 bit B1 = 1 flags blocked data [p.10 #12]; Rev 2.1 GH#1
> table says bytes 20-22 "Not used. Record as zero" [p.39]. Do not rely on byte 20 for blocking.

### 2.3 Storage Unit Label (128 bytes ASCII) [p.18-20]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | ascii | `storageUnitSeqNum` | 1-9999, right-justified, leading blanks, no leading zeros. Optional: all blanks ⇒ only unit in set |
| 5-9 | | 5b | ascii | `segdRevision` | `SD2.1` (Rev 2.1), `SD2.0` (Rev 2.0). Required |
| 10-15 | | 6b | ascii | `storageUnitStructure` | `RECORD` or `FIXREC`, left-justified. Required |
| 16-19 | | 4b | ascii | `bindingEdition` | `B` + integer 1-999 (RP66 Part 3 edition), left-justified, trailing blanks. Required |
| 20-29 | | 10b | ascii | `maxBlockSize` | 0..4294967295, right-justified, leading blanks. 0 = undeclared (`RECORD`: any length). Must be ≠0 for `FIXREC` (= the fixed record length) |
| 30-39 | | 10b | ascii | `producerOrgCode` | 0..4294967295 right-justified, or all blanks (not specified). Optional in Rev 2.1 (required in 2.0) |
| 40-50 | | 11b | ascii | `creationDate` | `dd-MMM-yyyy`, MMM ∈ JAN..DEC; day 1-9 may have one leading blank. Required |
| 51-62 | | 12b | ascii | `serialNumber` | enterprise ID; external label name must be its rightmost chars. Required |
| 63-68 | | 6b | ascii | `reserved` | all blanks |
| 69-80 | | 12b | ascii | `externalLabelName` | part of field 10 "Storage set identifier" (60 B, bytes 69-128). Right-justified, leading blanks; blank if no physical label |
| 81-104 | | 24b | ascii | `recordingEntityName` | crew/system ID, required |
| 105-118 | | 14b | ascii | `userDefined` | any ASCII |
| 119-128 | | 10b | ascii | `maxShotsPerFieldRecord` | max shot records between File Marks |

> **AMBIGUITY [p.18]:** The "Bytes" length column is split across lines (e.g. `1`/`0` = 10); lengths above were
> reconstructed from the start-end column and verified to tile 1-128 exactly. The text for field 10 says the
> sub-fields are "right justified"; justification of fields 9-10 sub-fields other than External Label Name and of
> field 10 "Max shot records" (right-justified numeric presumed) is not stated.

## 3. Header tables

### 3.1 General Header Block #1 (32 B) [p.31, p.38-40]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | bcd/ext | `fileNumber` | 0-9999. `FFFF` ⇒ use GH#2 bytes 1-3 |
| 3-4 | | 4n | bcd | `formatCode` | §4.1 |
| 5-10 | | 12n | bcd | `generalConstants` | K1..K12 |
| 11 | | 2n | bcd | `year` | last two digits, 0-99 |
| 12 | 12H | 4 bits | bits | `additionalGhBlocks` | **unsigned binary** GH3..GH0: number of GH blocks after #1. ≥1 for Rev 1/2 (only #1+#2 ⇒ 1) |
| 12-13 | 12L-13L | 3n | bcd | `julianDay` | DY1 DY2 DY3, 1-366 |
| 14 | | 2n | bcd | `hour` | 0-23 UTC (GMT before Rev 2.0) |
| 15 | | 2n | bcd | `minute` | 0-59 |
| 16 | | 2n | bcd | `second` | 0-59 |
| 17 | | 2n | bcd | `manufacturerCode` | §4.10 |
| 18-19 | | 4n | bcd | `manufacturerSerial` | M3..M6 |
| 20-22 | | 3b | u8 | `unused20_22` | record as 0 |
| 23 | | 1b | fixedpt | `baseScanInterval` | binary I3..I-4, LSB = 1/16 ms. Allowed 1,2,4,8,16,32,64,128 (= 1/16 … 8 ms) |
| 24 | 24H | 4 bits | bits | `polarity` | §4.6 |
| 24 | 24L | 4 bits | bits | `unused24L` | not used |
| 25 | | 1b | u8 | `unused25` | not used |
| 26 | 26H | 4 bits | bits | `recordType` | §4.5 |
| 26-27 | 26L-27L | 3n | bcd/ext | `recordLength` | R1 R2 . R3 (digits "RR.R") × 1.024 s; 00.5-99.5 ⇒ 0.512-101.888 s; 00.0 = indeterminate. `FFF` ⇒ use GH#2 bytes 15-17 |
| 28 | | 2n | bcd | `scanTypesPerRecord` | 1-99, 0 invalid |
| 29 | | 2n | bcd/ext | `channelSetsPerScanType` | 1-99, 0 invalid; = max over scan types. `FF` ⇒ use GH#2 bytes 4-5 |
| 30 | | 2n | bcd | `skewBlocks` | 0-99: number of 32-B skew fields after each scan type's CSDs; 0 = no skew |
| 31 | | 2n | bcd/ext | `extendedHeaderBlocks` | 0-99. `FF` ⇒ GH#2 bytes 6-7 |
| 32 | | 2n | bcd/ext | `externalHeaderBlocks` | 0-99. `FF` ⇒ GH#2 bytes 8-9 |

Coverage check: 1-2,3-4,5-10,11,12H,12L-13L,14,15,16,17,18-19,20-22,23,24H,24L,25,26H,26L-27L,28,29,30,31,32 = 32 bytes, all nibbles.

### 3.2 General Header Block #2 (32 B) [p.32, p.40-41]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `extFileNumber` | used when GH#1 bytes 1-2 = `FFFF`. Range 0-16,777,215 |
| 4-5 | | 2b | u16 | `extChannelSetsPerScanType` | used when GH#1 byte 29 = `FF` |
| 6-7 | | 2b | u16 | `extExtendedHeaderBlocks` | used when GH#1 byte 31 = `FF` |
| 8-9 | | 2b | u16 | `extExternalHeaderBlocks` | used when GH#1 byte 32 = `FF` |
| 10 | | 1b | u8 | `undef10` | X |
| 11 | | 1b | u8 | `revisionMajor` | `0x02` |
| 12 | | 1b | u8 | `revisionMinor` | `0x01` (Rev 2.1); `0x00` for Rev 2.0 |
| 13-14 | | 2b | u16 | `generalTrailerBlocks` | number of 32-B General Trailer blocks |
| 15-17 | | 3b | u24 | `extRecordLength` | record length in ms; used when GH#1 26L-27L = `FFF` |
| 18 | | 1b | u8 | `undef18` | X |
| 19 | | 1b | u8 | `ghBlockNumber` | = 2. 0 invalid |
| 20 | | 1b | u8 | `undef20` | X |
| 21-22 | | 2b | u16 | `sequenceNumber` | **new in 2.1**: line's unique sequence number 1-65535; 0 = not valid |
| 23-32 | | 10b | u8 | `undef23_32` | X |

> **AMBIGUITY [p.41]:** Note 1 says "Two byte unsigned binary, range is 0 - FF, Four byte … 0 - FFFF, Three byte
> two's complement … -7FFFFF to +7FFFFF" — byte-count/range mismatch, garbled in source. Treat 2-byte fields as
> 0-FFFF, 3-byte unsigned as 0-FFFFFF.

> **AMBIGUITY [p.9, p.40]:** GH#2 bytes 4-5 are called "Extended Channel Sets/Scan Types" and replace GH#1 byte 29
> (channel sets per scan type). There is no extended field for *scan types per record* (byte 28). Interpret as
> channel sets per scan type only.

### 3.3 General Header Block #N, N ≥ 3 (32 B) [p.33, p.41-42]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `extFileNumber` | same as GH#2 |
| 4-8 | | 5b | fixedpt | `sourceLineNumber` | `i24.u16`: bytes 4-6 integer (two's complement), 7-8 fraction (SLN-1..SLN-16) |
| 9-13 | | 5b | fixedpt | `sourcePointNumber` | `i24.u16`: bytes 9-11 integer, 12-13 fraction |
| 14 | | 1b | u8 | `sourcePointIndex` | starts 1, +1 each move; 0 = not recorded |
| 15 | | 1b | u8 | `phaseControl` | §4.8 |
| 16 | | 1b | u8 | `vibratorType` | §4.9 |
| 17-18 | | 2b | i16 | `phaseAngle` | degrees, pilot vs phase feedback; 0 when phaseControl = 0 |
| 19 | | 1b | u8 | `ghBlockNumber` | = N; 0 invalid |
| 20 | | 1b | u8 | `sourceSetNumber` | 0 invalid |
| 21-32 | | 12b | u8 | `undef21_32` | X |

Fixed-point decode: value = `int24 + u16/65536` (identical to `int40 / 65536` taken over all 5 bytes as two's complement).

> **AMBIGUITY [p.8, p.21, p.41]:** p.41 says "General Header Block #2 contains the source location for one Source
> Set", but GH#2 has no source fields; p.8 says "Block #3 contains the position for Source Set #1". Use GH#3+.
> Also "Additional blocks may be added as needed by the manufacturer or user" [p.21]: blocks ≥3 may be
> manufacturer-defined in practice; check byte 19 = N before trusting the layout.

### 3.4 Scan type header = CS Channel Set Descriptors + SK skew blocks [p.21-22, p.42]

Per scan type: `CS` descriptors (32 B each, in recording order) then `SK` skew blocks (32 B each).
`ST/R` scan types, each with the same `CS` count (unused ⇒ dummy CSD with channels = 0) [p.22, p.39].

Skew blocks: one byte per sample of each subscan of each channel set, in the same order as samples in the scan; u8 fraction of base scan interval, LSB = BSI/256 [p.21-22]. Unused trailing bytes of the last block: not specified (treat X).

### 3.5 Channel Set Descriptor (32 B) [p.34, p.42-45]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 2n | bcd | `scanTypeNumber` | 1..ST/R |
| 2 | | 2n | bcd/ext | `channelSetNumber` | 1..CS. `FF` ⇒ use bytes 27-28 (CS > 99 or binary numbering) |
| 3-4 | | 2b | u16 | `startTime` | TF16..TF1, LSB = 2 ms ⇒ ms = value×2 (0-131,070) |
| 5-6 | | 2b | u16 | `endTime` | TE16..TE1, LSB = 2 ms ⇒ ms = value×2. Single scan type: = record length |
| 7-8 | | 2b | fixedpt | `mpFactor` | sign-magnitude, **byte 8 is high part**: see §3.6 |
| 9-10 | | 4n | bcd | `channelCount` | 0-9999 (0 = dummy/unused) |
| 11 | 11H | 4 bits | bits | `channelType` | §4.3 |
| 11 | 11L | 4 bits | bits | `zero11L` | 0 |
| 12 | 12H | 1n | bcd | `subscanExponent` | S/C 0-9: subscans per base scan = 2^S/C (1-512) |
| 12 | 12L | 4 bits | bits | `gainControl` | J, §4.4 |
| 13-14 | | 4n | bcd | `aliasFilterFreq` | 0-9999 Hz |
| 15 | 15H | 1n | bcd | `zero15H` | 0 |
| 15-16 | 15L-16L | 3n | bcd | `aliasFilterSlope` | 0-999 dB/oct; 0 = filter out |
| 17-18 | | 4n | bcd | `lowCutFreq` | 0-9999 Hz |
| 19 | 19H | 1n | bcd | `zero19H` | 0 |
| 19-20 | 19L-20L | 3n | bcd | `lowCutSlope` | 0-999 dB/oct; 0 = filter out |
| 21-22 | | 4n | bcd | `notch1Freq` | NT1 NT2 NT3 . NT4 ⇒ Hz = value/10 (0-999.9); 000.0 = out |
| 23-24 | | 4n | bcd | `notch2Freq` | same |
| 25-26 | | 4n | bcd | `notch3Freq` | same |
| 27-28 | | 2b | u16 | `extChannelSetNumber` | full channel set number ("is or should have been" in byte 2) |
| 29 | 29H | 4 bits | bits | `extendedHeaderFlag` | EFH3..0, u4; 1 = extended header has more info on this channel set |
| 29 | 29L | 4 bits | bits | `traceHeaderExtensions` | THE3..0, u4 (0-15); must equal demux trace header byte 10 |
| 30 | | 1b | u8 | `verticalStack` | 0 = intentionally zeroed data, 1 = no stack, n = stack order |
| 31 | | 1b | u8 | `streamerNumber` | starboard-most = 1; 0 = not recorded |
| 32 | | 1b | u8 | `arrayForming` | §4.11 |

Coverage check: 1,2,3-4,5-6,7-8,9-10,11H,11L,12H,12L,13-14,15H,15L-16L,17-18,19H,19L-20L,21-22,23-24,25-26,27-28,29H,29L,30,31,32 = 32 bytes.

> **AMBIGUITY [p.34]:** bit table has typos: byte 3 shows `TE14`, byte 4 `ETF4`, byte 6 shows
> `TE8 TE7 TE13 TE12 TE11 TE10 TE9 TE8`. Text [p.43] states bytes 5-6 = TE16..TE1. Treat both as plain u16.
> Also the p.43 text "TF1 = 21 msec" is extraction of 2^1.

> **AMBIGUITY [p.34, p.44]:** p.34 table byte 8 bit 0 reads `MP5`; text says `MPS` (sign). Use sign.

### 3.6 MP factor (CSD bytes 7-8) [p.34, p.44, p.29]

| Byte | bit0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 7 | MP-3 | MP-4 | MP-5 | MP-6 | MP-7 | MP-8 | MP-9 | MP-10 |
| 8 | S | MP4 | MP3 | MP2 | MP1 | MP0 | MP-1 | MP-2 |

```
mag = ((b8 and 0x7F) shl 8) or b7        # 15-bit, LSB = 2^-10
mp  = mag / 1024.0 ; if (b8 and 0x80) != 0: mp = -mp
range ±31.9990234375 step 0.0009765625; pre-Rev1 (byte 8 only): ±31.75 step 0.25
scale = 2^mp   (millivolts per recorded unit)
```

### 3.7 Demux Trace Header (20 B) [p.35, p.45-46]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | bcd/ext | `fileNumber` | `FFFF` ⇒ bytes 18-20 |
| 3 | | 2n | bcd | `scanTypeNumber` | |
| 4 | | 2n | bcd/ext | `channelSetNumber` | `FF` ⇒ bytes 16-17 |
| 5-6 | | 4n | bcd | `traceNumber` | 1-9999; first trace of each channel set = 1 |
| 7-9 | | 3b | fixedpt | `firstTimingWord` | `u16.u8` ms (T15..T-8): ms = u24/256 (0-65,535.9961; may wrap) |
| 10 | | 1b | u8 | `traceHeaderExtensions` | 0-15 (same for all traces of a channel set) |
| 11 | | 1b | fixedpt | `sampleSkew` | u8/256 × base scan interval |
| 12 | | 1b | u8 | `traceEdit` | §4.7 |
| 13-15 | | 3b | fixedpt | `timeBreakWindow` | `u16.u8` ms, same encoding as 7-9 |
| 16-17 | | 2b | u16 | `extChannelSetNumber` | used when byte 4 = `FF` |
| 18-20 | | 3b | u24 | `extFileNumber` | used when bytes 1-2 = `FFFF` |

Exact time of first sample = firstTimingWord + sampleSkew/256 × BSI [p.23].
TW < BSI ⇒ time break not detected, recording started at end of TB window [p.23].

> **AMBIGUITY [p.23]:** §5.3 timing-word bit table labels the bytes "Byte 5, 6, 7, 8" (byte 8 all zeros) and text
> says bytes 7-9; §7.5 and §8.6 [p.35, p.45] say bytes 7,8,9 with T15..T-8. Use bytes 7-9.

> **AMBIGUITY [p.45]:** "Scan Type Number … must be set to FF when the Extended Channel Set Number (bytes 16 & 17)
> is used" — almost certainly meant byte 4 (Channel Set Number), which p.46 confirms. Byte 3 has no extension.

> **AMBIGUITY [p.6, p.22, p.45]:** Byte 10 THE: p.45 says "one byte, unsigned binary, max 15"; p.6/p.22 say it is
> "redefined as a 4 bit value" (p.22 even says "Byte 11"). Read the full byte; reject/clamp >15; prefer CSD byte 29L.

### 3.8 Trace Header Extension (32 B each, 0-15 per trace) [p.36, p.46-47]

Only the **first** extension has the layout below.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | i24/ext | `receiverLineNumber` | integer; `FFFFFF` ⇒ use bytes 11-15 |
| 4-6 | | 3b | i24/ext | `receiverPointNumber` | integer; `FFFFFF` ⇒ use bytes 16-20 |
| 7 | | 1b | i8 | `receiverPointIndex` | starts 1, +1 each move (signed per text) |
| 8-10 | | 3b | u24 | `samplesPerTrace` | number of samples in this trace |
| 11-15 | | 5b | fixedpt | `extReceiverLineNumber` | `i24.u16` (see §3.3 decode); valid only if 1-3 = `FFFFFF` |
| 16-20 | | 5b | fixedpt | `extReceiverPointNumber` | `i24.u16`; valid only if 4-6 = `FFFFFF` |
| 21 | | 1b | u8 | `sensorType` | §4.12 (new in 2.0) |
| 22-32 | | 11b | u8 | `undef22_32` | X |

Extensions 2..THE: manufacturer/user defined [p.24].

> **AMBIGUITY [p.36]:** `FFFFFF` is also the two's-complement encoding of −1, so a receiver line/point of −1
> cannot be written in bytes 1-3/4-6. Treat `FFFFFF` as the sentinel.

### 3.9 General Trailer block (32 B each) [p.37, p.47]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 2b | u16 | `trailerNumber` | 1..GT (GH#2 bytes 13-14) |
| 3-10 | | 8b | u8 | `undef3_10` | X |
| 11 | 11H | 4 bits | bits | `channelType` | `1100` (0xC) = trailer |
| 11 | 11L | 4 bits | bits | `undef11L` | X |
| 12-32 | | 21b | u8 | `undef12_32` | X (manufacturer/user) |

### 3.10 Extended header / External header

`EC` × 32 B and `EX` × 32 B opaque blobs; extended = manufacturer-defined, external = user-defined [p.24].

## 4. Code tables

### 4.1 Format codes (GH#1 bytes 3-4, BCD) [p.9, p.38]

| Code | Sample format | Bytes/sample | Rev 2.1 legal |
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
| 0036 | 24-bit integer, multiplexed | 3 | no (Rev 1 only, p.9) |
| 0038 | 32-bit integer, multiplexed | 4 | no (Rev 1 only) |
| 0058 | 32-bit IEEE, multiplexed | 4 | no (Rev 1 only) |
| 0200, 0000 | illegal, do not use | — | — |

> **AMBIGUITY / gap:** This document does **not** list or define multiplexed codes 0015, 0022, 0024, 0042, 0044,
> 0048, nor the multiplexed 20-bit layout (only states that the multiplexed 2½-byte method "does not use the LSB"
> [p.25]). Rev 2.x forbids multiplexed records. A reader should reject `0xxx` codes (or delegate to a Rev 1 note).

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

### 4.3 Channel type (CSD byte 11H, trailer byte 11H) [p.43]

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

### 4.4 Gain control method J (CSD byte 12L) [p.44]

| Code | Meaning |
|---|---|
| 1 | Individual AGC |
| 2 | Ganged AGC |
| 3 | Fixed gain |
| 4 | Programmed gain |
| 8 | Binary gain control |
| 9 | IFP gain control |

### 4.5 Record type Z (GH1 byte 26H) [p.39]

| Code | Meaning |
|---|---|
| 0x2 | Test record |
| 0x4 | Parallel channel test |
| 0x6 | Direct channel test |
| 0x8 | Normal record |
| 0x1 | Other |

### 4.6 Polarity P (GH1 byte 24H) [p.39]

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

> **AMBIGUITY [p.39]:** lists `1100 unassigned` only; 0x9-0xB, 0xD-0xF unspecified. Treat all ≥0x9 as unassigned.

### 4.7 Trace edit TR (trace header byte 12) [p.45]

| Code | Meaning |
|---|---|
| 0 | No edit |
| 1 | Dead channel for roll-on/roll-off; intentionally zeroed |
| 2 | Intentionally zeroed |
| 3 | Edited by acquisition system (new in 2.0) |
| other | undefined |

### 4.8 Phase control (GH#N byte 15) [p.41-42]

| Code | Meaning |
|---|---|
| 0 | Not recorded (phase angle undefined) |
| 1 | Baseplate accelerometer |
| 2 | Reaction mass |
| 3 | Weighted sum (baseplate accel × mass + reaction mass accel × its mass) |
| 4 | Direct force measurement |

### 4.9 Vibrator type (GH#N byte 16) [p.42]

| Code | Meaning |
|---|---|
| 0 | Not recorded |
| 1 | P wave |
| 2 | Shear wave |
| 3 | Marine |

### 4.10 Manufacturer codes (GH1 byte 17) [p.48-51]

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
| 13 | Sercel | 43 | Hydroscience Technologies |
| 14 | Scientific Data Systems (obsolete) | 44 | JSC Special Design Bureau for Seismic Instrumentation (Saratov) |
| 15 | Texas Instruments | 45 | Fugro |
| 17 | GUS Manufacturing | 46 | ProFocus Systems AS |
| 18 | Input/Output Inc. | 47 | Optoplan AS |
| 19 | Geco-Prakla (Transition Zone, ex Terra Marine) | 48 | Wireless Seismic Inc. |

### 4.11 Array forming (CSD byte 32) [p.45]

| Value | Meaning |
|---|---|
| 0x01 | No array forming |
| 0x0N (N≥2) | N groups summed, no weighting |
| 0x1N | N groups weighted, overlapping summation |

### 4.12 Sensor type (THE#1 byte 21) [p.46]

| Code | Meaning |
|---|---|
| 0 | Not defined |
| 1 | Hydrophone (pressure) |
| 2 | Geophone vertical |
| 3 | Geophone horizontal inline |
| 4 | Geophone horizontal crossline |
| 5 | Geophone horizontal other |
| 6 | Accelerometer vertical |
| 7 | Accelerometer horizontal inline |
| 8 | Accelerometer horizontal crossline |
| 9 | Accelerometer horizontal other |

### 4.13 Maximum block sizes (App. F) [p.63]

| Device | Max block |
|---|---|
| 3480 | 128 KiB |
| 3490, 3490E | 256 KiB |
| 3590 B | 512 KiB |
| 3590 E | 2 MiB |
| IBM 3592 (Jaguar-1) | 2,097,152 B |
| IBM TS1120 (Jaguar-2) | 2,097,152 B |
| DST | 1,199,840 B |
| Redwood | 256 KiB |
| STK 9940B | 256 KiB |
| ½" round tape | 64 KiB |

## 5. Data sample formats [p.25-30, p.9]

General: sample bytes follow the trace header (+extensions) contiguously; big-endian; no inter-sample padding.
Physical value (mV) = `decoded × 2^MP` where `decoded` is the fraction×base^exp (float formats) or the integer
(integer formats). "Same number system on all samples in a record, including aux channels" [p.25].
Bits below: bit 0 = MSB.

### 5.1 8015 — 20-bit binary exponent, demultiplexed (4 samples per 10 bytes) [p.26]

| Byte | bits 0-3 (H) | bits 4-7 (L) |
|---|---|---|
| 1 | C(sample 1) | C(sample 2) |
| 2 | C(sample 3) | C(sample 4) |
| 3-4 | sample 1: S Q-1..Q-15 (16 bits) | |
| 5-6 | sample 2 | |
| 7-8 | sample 3 | |
| 9-10 | sample 4 | |

- C: u4 binary exponent of 2 (0-15).
- S + Q-1..Q-15: **one's complement** 16-bit fraction, radix point left of Q-1, range ±(1−2^-15).
- Negative zero (`0xFFFF`) invalid → write `0x0000`.
- Samples per trace **must be divisible by 4** [p.26]; data bytes = samples/4 × 10.
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
  (each of the 4 samples has its own exponent nibble; partial final groups are not allowed)
```

> **AMBIGUITY [p.26]:** spec says one's complement. Many field systems/readers decode the 16-bit word as two's
> complement (`int16`); results differ by 1 LSB for negatives. Make this a reader option, default one's complement.

### 5.2 8022 — 1-byte quaternary exponent [p.25]

`S C2 C1 C0 Q-1 Q-2 Q-3 Q-4`. C = u3 exponent of 4 (0-7). S+Q = 5-bit **one's complement** fraction (radix left of Q-1), range ±(1−2^-4).
Decode: `q = b and 0xF; m = if S: -(q xor 0xF) else q; v = m/16 * 4^C`. Negative zero (S=1,Q=1111) invalid → +0.

### 5.3 8024 — 2-byte quaternary exponent [p.25-26]

Byte 1 `S C2 C1 C0 Q-1..Q-4`, byte 2 `Q-5..Q-12`. 12-bit fraction, one's complement with S.
`q = w and 0x0FFF; m = if S: -(q xor 0xFFF) else q; v = m/4096 * 4^C`, `C = (w shr 12) and 7`. Negative zero invalid.

### 5.4 8042 — 1-byte hexadecimal exponent [p.26-27]

`S C1 C0 Q-1..Q-5`. C = u2 exponent of 16 (0-3). Q = 5-bit **positive** fraction (sign-magnitude).
`v = (-1)^S * Q/32 * 16^C`. All-ones byte `0xFF` invalid.

> **AMBIGUITY [p.26-27]:** bit table labels exponent bits `C-1 C-0`; text says 2-bit exponent → C1 C0. Range text
> "-(1-2^-4) x 16^3" inconsistent with 5-bit fraction; ignore.

### 5.5 8044 — 2-byte hexadecimal exponent [p.27]

Byte 1 `S C1 C0 Q-1..Q-5`, byte 2 `Q-6..Q-13`. Sign-magnitude, 13-bit fraction.
`v = (-1)^S * (w and 0x1FFF)/8192 * 16^((w shr 13) and 3)`. `0xFFFF` invalid.

### 5.6 8048 — 4-byte hexadecimal excess-64 [p.27-28]

| Byte | bits 0..7 |
|---|---|
| 1 | S C6..C0 |
| 2 | Q-1..Q-8 |
| 3 | Q-9..Q-16 |
| 4 | Q-17..Q-23, 0 |

`v = (-1)^S * F/2^23 * 16^(C-64)` with `F = (w shr 1) and 0x7FFFFF`. Equivalent to IBM hex float (`ibm32`)
with the last fraction bit forced 0. Fraction 0 ⇒ whole word 0. Encoder: left-justify (normalize hex), clear bit 7 of byte 4. MP may be 0 [p.28].

### 5.7 8058 — IEEE 754 single, big-endian [p.9, p.28]

Standard `f32` BE. NaN = invalid sample. Bit 7 of byte 4 may be non-zero in demux (must be 0 only in 0058).

> **AMBIGUITY [p.28]:** second copy of the IEEE rule reads `if e = 255 & f = 0 … NaN` (≠ lost in extraction); p.9 has
> `f ¹ 0` (≠). Use standard IEEE.

### 5.8 8036 — 24-bit integer [p.28-29]

`i24` two's complement BE (S I22..I0). `v = i24` (then × 2^MP).

### 5.9 8038 — 32-bit integer [p.29]

`i32` two's complement BE.

## 6. Derived rules / algorithms

### 6.1 Resolved header counts

```
nGh   = 1 + GH1[12].H                           # total GH blocks (≥2 for Rev 1/2)
file  = GH1[1-2]=="FFFF" ? GH2.extFileNumber : bcd(GH1[1-2])
nST   = bcd(GH1[28])
nCS   = GH1[29]==0xFF ? GH2.extChannelSetsPerScanType : bcd(GH1[29])
nSK   = bcd(GH1[30])
nEC   = GH1[31]==0xFF ? GH2.extExtendedHeaderBlocks : bcd(GH1[31])
nEX   = GH1[32]==0xFF ? GH2.extExternalHeaderBlocks : bcd(GH1[32])
recLenMs = GH1[26L-27L]=="FFF" ? GH2.extRecordLength : rr_r * 1024
nGT   = GH2.generalTrailerBlocks
csNum = CSD[2]==0xFF ? CSD.ext(27-28) : bcd(CSD[2])
```

### 6.2 Sizes

```
headerBytes = 32*nGh + 32*nST*(nCS + nSK) + 32*nEC + 32*nEX
sampleInterval(cs) = BSI_ms / 2^(cs.subscanExponent)
nSamples(cs) = THE#1.samplesPerTrace if THE>=1 else (cs.endTime*2 - cs.startTime*2) / sampleInterval(cs)
traceDataBytes = nSamples * bytesPerSample          # 8015: nSamples/4*10
traceBytes(cs) = 20 + 32*cs.traceHeaderExtensions + traceDataBytes   # constant within a channel set [p.22]
nTraces = Σ over scan types, channel sets: bcd(cs.channelCount)
recordBytes = headerBytes + Σ traceBytes + 32*nGT
FIXREC: next record starts at next multiple of label.maxBlockSize (block-aligned)
```

Skew block count (App. E example) [p.62]:
`SK = ceil( Σ_cs channelCount(cs) * 2^(S/C(cs)) / 32 )`; e.g. 4×1 + 96×1 + 12×4 = 148 ⇒ 5 blocks.

> **AMBIGUITY [p.43, p.61]:** Samples-per-trace without a trace header extension is not defined explicitly (App. E,
> p.61, did not extract). Whether `(TE−TF)/SI` or `+1` is unspecified; prefer NBS (THE bytes 8-10), else
> `(TE−TF)/SI`, and validate against the next trace header (file/scan/channel-set numbers).

### 6.3 Validation

| Rule | Source |
|---|---|
| nST ≥ 1, nCS ≥ 1 | p.39 |
| every scan type has nCS descriptors; unused ones have channelCount 0 | p.22, p.39 |
| bytes per base scan interval constant over scan types | p.22 rule 4 |
| THE ≤ 15; trace header byte 10 == CSD byte 29L | p.6, p.44-45 |
| all traces in a channel set same length | p.22 |
| 8015: nSamples mod 4 == 0 | p.26 |
| GH2 byte 19 == 2; GH#N byte 19 == N | p.41-42 |
| trailer block byte 11H == 0xC, bytes 1-2 == 1..nGT | p.47 |
| label bytes 10-15 ∈ {`RECORD`,`FIXREC`}; FIXREC ⇒ maxBlockSize > 0 | p.19 |
| BCD nibbles ≤ 9 except documented `F` sentinels | p.38 |

### 6.4 Version detection

| Signal | Meaning |
|---|---|
| Label bytes 5-9 = `SD2.1` / `SD2.0` | Rev 2.1 / 2.0 tape |
| GH1 byte 12H = 0 | original (Rev 0) SEG-D, no GH#2 |
| GH1 byte 12H ≥ 1 | Rev ≥ 1 |
| GH2 bytes 11,12 = 02,01 | Rev 2.1; 02,00 ⇒ Rev 2.0 |

> **AMBIGUITY [p.8, p.40]:** Rev 1 defined bytes 11-12 as one u16 revision "= 1"; Rev 2 splits into major/minor and
> says "Revisions 0 to 0.N are not valid". A Rev 1 file may read as 00 01 or 01 00. Accept major=1 or u16=1 as Rev 1.

## 7. Implementation notes and revision differences

### 7.1 Gotchas
- Bit 0 = MSB everywhere.
- MP: byte 7 is the **low** part, byte 8 the high part with the sign.
- GH1 byte 12: binary nibble + BCD nibble in one byte; DY spans 12L-13L.
- GH1 bytes 26-27: binary record-type nibble + 3-nibble BCD record length; sentinel is `FFF` (nibbles), not a whole byte.
- CSD byte 2 `FF` ⇒ bytes 27-28; bytes 27-28 "contain the complete value" so may also be filled when byte 2 is BCD.
- Trace number is BCD 4 digits only; no extended trace number in Rev 2.1.
- "FF"/"FFFF" sentinels are invalid BCD, so test the sentinel before BCD-decoding.
- Fractional position fields (`i24.u16`): value = signed int part + unsigned fraction/65536.
- Disk files: the 128-byte label is mandatory on tape; disk files may or may not carry it (see open questions).

### 7.2 Rev 2.1 vs 2.0 [p.5]

| # | Change |
|---|---|
| 1 | Revision 2.1: label `SD2.1`, GH2 bytes 11-12 = 2,1 |
| 2 | Media: STK 9940B, IBM 3592, TS1120 (App. F) |
| 3 | Field file number range 0-16,777,215 (unchanged) |
| 4 | Multiple lines per tape; **GH2 bytes 21-22 sequence number** added |
| 5-6 | App. C (now Energistics) and App. A updated |
| 7 | Label field 6 producer organization code no longer required |

### 7.3 Rev 2.0 vs 1.0 [p.6-8, p.10-11]

| Change |
|---|
| Media 3490/3490E, 3590, D2, D3; multiplexed data not supported |
| GH1 byte 12 = number of *additional* blocks; GH1 bytes 1-2 `FFFF` when file > 9999 |
| THE bytes 1-3/4-6 `FFFFFF` ⇒ fractional extended receiver line/point at bytes 11-15/16-20 |
| THE count ≤ 15, uniform per channel set, stored in CSD byte 29L |
| Uniform trace length per channel set |
| Storage unit label required; RECORD/FIXREC structures, large blocks; App. F block sizes |
| Trace edit code 3 |
| Byte-stream model; File Marks optional at shot boundaries; EOD required on tape |
| GH1 time base GMT → UTC |
| Tape partitioning; label = first 128 B of first user record |
| THE byte 21 sensor type |

### 7.4 Rev 1 vs Rev 0 [p.8-11]

| Change |
|---|
| Additional GH blocks; GH#2; GH#N source/vibrator fields |
| General Trailer (GH2 bytes 13-14) |
| Revision number GH2 11-12 |
| Extended file number, channel sets, extended/external block counts |
| THE bytes 8-10 samples per trace |
| Formats 0036/0038/0058/8036/8038/8058 |
| Blocked demux data (GH1 byte 20 B1, ≤128 KB) |
| CSD byte 30 vertical stack, 31 streamer, 32 array forming; byte 7 MP extension |
| Trace edit codes 0-2 |
| MP formula corrected; extended record length in ms (GH2 15-17, R = FFF) |

### 7.5 MP computation (writer side) [p.29-30, p.10-11]

| Data | Formula | Cmax |
|---|---|---|
| binary exponent (8015) | MP = FS − PA − Cmax | 15 |
| quaternary (8022/8024) | MP = FS − PA − 2·Cmax | 7 |
| hex non-excess (8042/8044) | MP = FS − PA − 4·Cmax | 3 |
| hex excess-64 (8048), IEEE (8058) | MP = FS − PA − 4·(Cmax − 64) | 64 (⇒ term 0) |
| integer (8036/8038) | MP = FS − PA − IS | 2^(IS−1) = integer positive full scale |

2^FS = converter full scale (mV); 2^PA = minimum system gain (preamp × min FP amp gain, incl. ADC adjustment).

## 8. Open questions

1. Disk files: does a file begin with the 128-B storage unit label? Recommend auto-detect: bytes 5-9 match `SD\d.\d` ⇒ label present; otherwise start at GH#1.
2. FIXREC on disk: is the label its own block (128 B) or padded to `maxBlockSize`? Block alignment origin for subsequent records unspecified.
3. Samples-per-trace when THE = 0 (`(TE−TF)/SI` vs `+1`).
4. 8015 negative mantissa: one's complement (spec) vs two's complement (common practice).
5. Trace ordering across multiple scan types (scan type → channel set → trace assumed).
6. Multiplexed codes (0015, 0022, …, 0058) and the multiplexed 20-bit layout are not defined in this document; out of scope for Rev 2.x — reject or implement from a Rev 1 source.
7. Whether CSD bytes 27-28 / trace header 16-17 should be trusted when the BCD field is not `FF`.
8. GH#3+ layout may be manufacturer-specific; validate block number byte 19.
9. Contents of unused bytes at the end of the last skew block, and FIXREC padding bytes: unspecified (ignore on read; write zeros).
10. Polarity codes 0x9-0xF and other undefined code points: pass through as raw values.
