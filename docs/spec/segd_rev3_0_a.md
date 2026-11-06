# SEG-D Rev 3.0 (Sep 2014), part A: structure, overview, data formats, header tables

Source: `SEG Spec/text/seg_d_rev3_0-sep2014.txt`. All `[p.N]` refer to `=== PAGE N ===` markers.

## 1. Scope

| Covered | Pages | Content |
|---|---|---|
| yes | 1-86 | Sec 1.0-7.25: intro, change lists (3.0/2.1/2.0/1), format overview, timestamp, multi-component, extended recording mode, time drift, positions, storage unit label, TOC file, header-block overview, General Trailer overview + Trace Edit v1.0, data body / sample formats, DSM / physical unit, sensor calibration, header tables 7.1-7.25 |
| no (part B) | 87-188 | Sec 8 field-by-field parameter descriptions, code tables (channel type, record type, sensor type, units, etc.), appendices A-F |

Semantics in the tables below come from the 7.x tables and the overview text. Encodings (signed or unsigned, float or int) that the 7.x tables don't show were confirmed from sec 8 headings and are marked `[p.N]` with N ≥ 87. Full value tables and units are in part B (`segd_rev3_0_b.md`).

Bit numbering convention used in the spec's bit diagrams: **bit 0 = MSB (value 128), bit 7 = LSB** [p.58]. All multi-byte binary values are big-endian. "H" = bits 0-3 (high nibble), "L" = bits 4-7 (low nibble).

## 2. File / tape structure

### 2.1 Storage units [p.17-19]
- A **storage unit** is: one tape (or one tape partition); one disk file; a whole raw device if it's written as a single byte stream; or one network connection (each open/re-open starts a new storage unit). Each storage unit **must begin with a 128-byte Storage Unit Label** (SUL, "Tape Label"), with no preceding data, ANSI label or File Mark [p.17, p.33].
- An optional File Mark may follow the SUL (recommended for field tapes) [p.17]. No partition may run over into the next one. Each partition must decode on its own [p.18].
- Following the SUL comes a sequence of SEG-D records (field files). Rev 3.0 is **demultiplexed only** [p.17].
- A disk file is "proper SEG-D" only if it starts with an SUL. Directories of per-record files without SULs aren't [p.38].

### 2.2 Record layout (Figure 1) [p.17, p.20]

```
SUL(128) [EOF] | Record 1 | Record 2 | ... | Record n | [EOF] [TOC file] [EOF] EOF EOF
Record = Record Header (mandatory) + Trace Data (optional) + General Trailer (optional)
```

Record Header, in order:

| # | Part | Size | Count source |
|---|---|---|---|
| 1 | General Header #1 | 32 | always |
| 2 | General Header #2 (ID 02) | 32 | always |
| 3 | General Header #3 (ID 03) | 32 | always |
| 4 | Additional General Header blocks (GH #4-8, source info, CRS, user B0-FF, ...) in any order | N×32 | total GH blocks after #1 = GH1 byte 12 high nibble (F → GH2 bytes 23-24) |
| 5 | For each scan type 1..ST/R: channel set descriptors (96 bytes each), then skew blocks | per scan type: nCS×96 + nSK×32 | ST/R = GH1 byte 28; nCS = GH1 byte 29 (FF → GH2 4-5); nSK = GH1 byte 30 (FF → GH2 9-10) |
| 6 | Extended Header | EC×32 | GH1 byte 31 (FF → GH2 6-8) |
| 7 | External Header | EX×32 | GH1 byte 32 (FF → GH2 28-30) |

Trace data: for scan type 1..ST/R, for channel set 1..nCS, for trace 1..C/S: `trace = Demux Trace Header (20) + Trace Header Extension #1 (32, required) + further THE blocks (32 each) + samples`. The total number of THE blocks per trace = CSD byte 28 = demux byte 10 (0-255). Max trace header = 20 + 255×32 = 8180 bytes [p.18, p.42].

General Trailer: a sequence of `[Trailer Description Block (32, ID 70)] + data blocks (multiple of 32)` groups. Count = GH2 bytes 13-16 [p.44].

### 2.3 Device structures [p.17-19]

| Type | SUL field 3 | SUL field 5 (max block size) | Rules |
|---|---|---|---|
| A Variable block | `RECORD` | largest block used (0 = undeclared/any) | each block holds data from only one shot record; blocks shouldn't be padded to the maximum |
| B Byte stream (disk, D2, USB, network) | `RECORD` | `1` | no blocks; records are written back to back with no gap |
| C Fixed block | `FIXREC` | device block size (must not be 0) | each block holds data from only one shot record; the last block of a part is padded (with zeros [p.19]) |

Rev 3.0 alignment rules [p.19]:
- **GH#1 (start of record), the first Trace Header (start of data) and the first General Trailer block (start of trailer) always start at a device block boundary.** On fixed-block media the preceding block is zero-padded. On variable-block media the preceding block is just shorter.
- Otherwise tape blocks are decoupled from SEG-D blocks. Headers, trace headers and traces may start anywhere and may be split across blocks [p.17, p.19].
- The maximum device block is about 4 GB (SUL field 5 ≤ 4,294,967,295) [p.19, p.32].
- File Marks are optional and only allowed at shot-record boundaries. On tape, an EOD mark is required after the last record [p.18].
- Footnote: each new field file must begin at a record boundary [p.17].
- Byte-stream example: SUL field "10" (max shots/file) = number of records between file marks. 0 = unknown [p.23-24].

> **AMBIGUITY [p.19 vs p.91]:** For fixed-block media, the spec doesn't say whether the zero padding before the first trace header / first trailer block is counted in GH3 Header Size / Data Size / Record Size. For byte-stream media there is no padding (block size 1), so the sizes are exact.

### 2.4 Maximum sizes [p.18]

| Part | Max bytes | Derivation |
|---|---|---|
| General Header | 2,097,120 | 65535×32 |
| Skew (per scan type) | 2,097,120 | 65535×32 |
| Channel set descriptors (per scan type) | 6,291,360 | 65535×96 |
| Scan types | 99 | BCD 2 digits |
| Extended Header | 536,870,880 | (2^24−1)×32 |
| External Header | 536,870,880 | (2^24−1)×32 |
| General Trailer | 137,438,953,440 | (2^32−1)×32 |
| Trace header | 8,180 | 20+255×32 |
| Trace data | 34,359,738,360 | (2^32−1) samples × 8 bytes |
| Channels per channel set | 16,777,215 | u24 |

### 2.5 Storage Unit Label (128 bytes ASCII) [p.31-33]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | ascii | `storageUnitSeqNum` | Field 1. Integer 1-9999, right-justified, leading blanks, no leading zeros. Optional: all blanks = only unit in the set |
| 5-9 | | 5b | ascii | `segdRevision` | Field 2. `SD3.0` (2.1 used `SD2.1`). Required. **Version detection** |
| 10-15 | | 6b | ascii | `storageUnitStructure` | Field 3. `RECORD` or `FIXREC`, left-justified. Required |
| 16-19 | | 4b | ascii | `bindingEdition` | Field 4. `B` + integer 1-999, left-justified, blank-padded. Use `B2  ` for 3.0. Required |
| 20-29 | | 10b | ascii | `maxBlockSize` | Field 5. 0..4294967295, right-justified, leading blanks. 0 = undeclared, 1 = byte stream. Must not be 0 for FIXREC |
| 30-39 | | 10b | ascii | `producerOrgCode` | Field 6. 0..4294967295, right-justified. All blanks = not specified (Appendix C / Energistics) |
| 40-50 | | 11b | ascii | `creationDate` | Field 7. `dd-MMM-yyyy`. MMM ∈ JAN..DEC. Days 1-9 may have one leading blank. Separator `-` (0x2D). Required |
| 51-62 | | 12b | ascii | `serialNumber` | Field 8. Archive ID. If an external label exists, it must be the rightmost chars of this or of the External Label Name. Required |
| 63-68 | | 6b | ascii | `reserved` | Field 9. All blanks (0x20) |
| 69-80 | | 12b | ascii | `externalLabelName` | Field 11 (part of Field 10 "storage set identifier"). Right-justified, leading blanks. Blank if there is no physical label |
| 81-104 | | 24b | ascii | `recordingEntityName` | Field 12. Crew/system ID, e.g. `ABC, Gopher, P13, Zip#1`. Required |
| 105-118 | | 14b | ascii | `userDefined` | Field 13. Any ASCII |
| 119-128 | | 10b | ascii | `maxShotsPerFieldRecord` | Field 14. Max shot records between File Marks. 0 = unknown/undefined [p.24] |

> **AMBIGUITY [p.31]:** Table 1 gives Field 10 "Storage set identifier" a length of 60 with no byte range. 60 bytes = 69-128, i.e. fields 11-14 together (12+24+14+10). The text calls fields 10-12 the storage set identifier, and Figures 4/5 [p.23-24] call max-shots "Field 10" when it is Field 14 in the table. Parse by byte range as above.

> **AMBIGUITY [p.32]:** Field 3 text says `RECORD` records "range up to" field 5, and "if zero, any length". This is consistent with type A/B. Readers must not reject `maxBlockSize = 0` for `RECORD`.

### 2.6 Table of Contents file (optional) [p.33-38]
- Location on tape: separated by a File Mark before and after. Usually at the end of the tape (after the last record, before the double FM) or right after the SUL. On disk there is no FM, so a reader detects it by the ASCII `SEGD TOC FILE` at offset 0 of a "record" [p.34].
- Structure: 448-byte header + N × 128-byte entries. Text fields are ASCII.
- Recorders must reserve space at the end of the media. Example: 448 + (300000/74.1)×128 ≈ 507 kB [p.37].

> **AMBIGUITY [p.33 vs p.36-37]:** The prose says "one 64 byte entry". The entry table spans bytes 1-128 and the size example uses 128. Use **128**.

TOC Header (448 bytes). Left-justified and space-padded unless stated otherwise [p.34-36]:

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-13 | | 13b | ascii | `tocIdentifier` | `SEGD TOC FILE`. Required |
| 14-19 | | 6b | ascii | `segdRevision` | `SD3.0`. Must equal SUL field 2. Required |
| 20-31 | | 12b | ascii | `serialNumber` | Must equal SUL field 8. Required |
| 32-63 | | 32b | ascii | `clientId` | Must match GH#6 if present |
| 64-95 | | 32b | ascii | `vesselCrewId` | Must match GH#4 if present |
| 96-127 | | 32b | ascii | `country` | |
| 128-159 | | 32b | ascii | `region` | |
| 160-191 | | 32b | ascii | `block` | |
| 192-223 | | 32b | ascii | `surveyAreaName` | Must match GH#5 if present |
| 224-255 | | 32b | ascii | `contractNumber` | |
| 256-287 | | 32b | ascii | `licenseId` | |
| 288-307 | | 20b | ascii | `surveyType` | Recommended: `TOWED MARINE SEISMIC`, `LAND SEISMIC`, `TRANSITION ZONE`, `SEABED SEISMIC`, `VERTICAL SEISMIC`, `ELECTROMAGNETIC`, `COMBINATION`, `OTHER` |
| 308-339 | | 32b | ascii | `acquisitionContractor` | |
| 340-364 | | 25b | ascii | `acquisitionDates` | `DD-MMM-YYYY - DD-MMM-YYYY` (from-to) |
| 365-396 | | 32b | ascii | `jobId` | Must match GH#7 if present |
| 397-402 | | 6b | ascii | `mediaSeqInRecordSet` | Starts at 1. `1` if there are multiple record sets |
| 403-434 | | 32b | ascii | `dataTypeId` | Free text, e.g. `RAW SEISMIC ORIGINAL DATASET 1` |
| 435-438 | | 4b | ascii | `undefined` | Spaces |
| 439-448 | | 10b | ascii | `numEntries` | **Right-justified**, space-padded integer. Required |

> **AMBIGUITY [p.35-36]:** The survey-type strings are printed padded to about 30 chars, but the field is 20 bytes. Truncate/pad to 20. The date separator is printed as an en dash `–`. Use ASCII `-` with surrounding spaces to fit 25 bytes.

TOC Record Entry (128 bytes). **Right-justified**, space-padded unless stated otherwise [p.36-37]:

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | ascii | `mediaFileNumber` | Unsigned. SUL = media file 1, so the first record is usually 2. Required |
| 9-15 | | 7b | ascii | `recordWithinFile` | Unsigned, from 1. Required |
| 16-35 | | 20b | ascii | `timeOfShot` | Signed integer = GH3 bytes 1-8 (SEG-D timestamp, µs). Required |
| 36-45 | | 10b | ascii | `segdFileNumber` | Unsigned. GH1 1-2 or GH2 1-3. Required |
| 46-60 | | 15b | ascii | `recordId` | Signed decimal float text, e.g. `-4.0512` |
| 61-70 | | 10b | ascii | `recordSetNumber` | Unsigned = GH2 bytes 21-22 |
| 71-94 | | 24b | ascii | `lineId` | **Left-justified**. Must match GH#8 if present |
| 95-128 | | 34b | ascii | `userDefined` | Spaces if unused |

Recommended disk naming: `FILE_[rsn:5]_[mseq:6]_[mfn:8].SGD`, zero-padded. Each tape file goes into its own disk file, prefixed with a dummy SUL [p.38].

## 3. Header tables

### 3.0 Common rules
- Every header block is 32 bytes. **Byte 32 = block type ID**, except **GH#1** (byte 32 = EX count) and the **20-byte Demux Trace Header**, which have none [p.39, p.58, p.79].
- Multi-block structures: Channel Set Descriptor = 3 blocks (IDs 30/31/32 at bytes 32/64/96). Position block = 3 blocks (50/51/52).
- `X` = undefined. Write 0 [p.58]. Fields marked "0" in the tables must be 0.
- Extended fields: when an original BCD field is set to all-F nibbles, use the extended field. Otherwise the extended field is 0 or equal to the normal field [p.87].

### 3.1 Header block type IDs (Table 2) [p.39-40]

| ID (hex) | Block | GH | Scan type hdr | Trace hdr | Gen trailer |
|---|---|---|---|---|---|
| 02 | General Header #2 | * | | | |
| 03 | General Header #3 (timestamp & size) | * | | | |
| 10 | Vessel/Crew identification (GH#4) | * | | * | |
| 11 | Survey Area Name (GH#5) | * | | * | |
| 12 | Client Name (GH#6) | * | | * | |
| 13 | Job identification (GH#7) | * | | * | |
| 14 | Line identification (GH#8) | * | | * | |
| 15 | Vibrator source info | * | | * | |
| 16 | Explosive source info | * | | * | |
| 17 | Airgun source info | * | | * | |
| 18 | Watergun source info | * | | * | |
| 19 | Electromagnetic source | * | | * | |
| 1F | Other source type | * | | * | |
| 20 | Additional source info | * | | * | |
| 21 | Source Auxiliary Channel Reference | * | | * | |
| 30 / 31 / 32 | Channel set descriptor blocks 1 / 2 / 3 | | * | | |
| 40 | Trace header extension #1 | | | * | |
| 41 | Sensor Info header extension | * | | * | |
| 42 | Timestamp header | | | * | |
| 43 | Sensor calibration | * | | * | |
| 44 | Time drift | * | | * | |
| 45 | EM Src/Recv description | * | | * | |
| 50 / 51 / 52 | Position blocks 1 / 2 / 3 | * | | * | |
| 55 | Coordinate Reference System Identification | * | | * | |
| 56 | Relative position | * | | * | |
| 60 | Orientation header | * | | * | |
| 61 | Measurement | * | | * | |
| 70 | General Trailer Description | | | | * |
| B0-FF | User defined | * | | * | |

Any block may also appear inside General Trailer data [p.40].

Ordering semantics [p.40-41]:
- The scan type header contains only 30/31/32 (plus skew).
- **Block order carries meaning.** A block (e.g. Position 50-52, Additional Source Info 20, Aux Channel Ref 21) applies to the **preceding Source Description block** (15-19, 1F). Per source: `Source Description 0..1, Additional Source Info 0..1, Source Aux Channel Ref 0..n, Position 0..m, other 0..p`, repeated per source.
- Source info in a trace header without a preceding Source Description block is allowed only if a Source Description for that source exists in the GH. Source info in the GH without a Source Description block isn't allowed [p.41].

> **AMBIGUITY [p.40 vs p.70]:** Table 2 gives Additional Source Info ID = **0x20**. The 7.10 table's byte 32 bits are `0001 1010` = **0x1A**. Sec 8.10 doesn't state the value. Recommend reading both 0x1A and 0x20 as Additional Source Info, and writing 0x20 (Table 2).

### 3.2 General Header Block #1 [p.58; parameter detail p.87-89]
Packed BCD unless stated otherwise. No block-type byte.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | bcd | `fileNumber` | F1-F4, 0-9999. `FFFF` → GH2 1-3 |
| 3-4 | | 4n | bcd | `formatCode` | Y1-Y4. See §4.1 |
| 5-10 | | 12n | bcd | `generalConstants` | K1-K12 |
| 11 | | 2n | bcd | `year` | YR1-YR2, last 2 digits (UTC) |
| 12 | H | 4 bits | u8 (u4) | `additionalGhBlocks` | GH3-GH0, **binary**. Number of GH blocks after GH#1, ≥2 in 3.0. `F` → GH2 23-24 |
| 12-13 | 12L-13L | 3n | bcd | `julianDay` | DY1 (12L), DY2-DY3 (13). 1-366 |
| 14 | | 2n | bcd | `hour` | 0-23 UTC |
| 15 | | 2n | bcd | `minute` | 0-59 |
| 16 | | 2n | bcd | `second` | 0-**60** (leap second legal) |
| 17 | | 2n | bcd | `manufacturerCode` | M1-M2 (Appendix A) [p.88] |
| 18-19 | | 4n | bcd | `manufacturerSerial` | M3-M6 [p.88] |
| 20-22 | | 3b | u8×3 | `zero20to22` | Must be 0 |
| 23 | | 1b | fixedpt | `baseScanInterval` | Binary, bits I3..I−4 → u4.4, **ms** (value/16 ms). `FF` → GH2 25-27 (dominant sampling interval) |
| 24 | H | 4 bits | bits | `polarity` | P (code, part B) |
| 24 | L | 4 bits | — | `unused24` | 0 / not used |
| 25 | | 1b | — | `unused25` | 0 / not used |
| 26 | H | 1n | bcd | `recordType` | Z (codes in part B) |
| 26-27 | 26L-27L | 3n | bcd | `recordLength` | R1-R3, units 0.5×1.024 s. `FFF` → GH2 17-20 |
| 28 | | 2n | bcd | `scanTypesPerRecord` | ST/R, 1-99 (0 allowed: no channel sets in 3.0, change 3) |
| 29 | | 2n | bcd | `channelSetsPerScanType` | CS. `FF` → GH2 4-5 |
| 30 | | 2n | bcd | `skewBlocks` | SK, count of 32-byte skew blocks per scan type. `FF` → GH2 9-10 |
| 31 | | 2n | bcd | `extendedHeaderBlocks` | EC. `FF` → GH2 6-8 |
| 32 | | 2n | bcd | `externalHeaderBlocks` | EX. `FF` → GH2 28-30 |

> **AMBIGUITY [p.58]:** Byte 6 bit 6 is printed `K` instead of `K4` (typo). Treat 5-10 as 12 BCD digits.

### 3.3 General Header Block #2 (ID 0x02) [p.59; detail p.89-91]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `extFileNumber` | Used when GH1 1-2 = FFFF |
| 4-5 | | 2b | u16 | `extChannelSetsPerScanType` | Used when GH1 29 = FF |
| 6-8 | | 3b | u24 | `extExtendedHeaderBlocks` | Used when GH1 31 = FF. **2.1: u16 at 6-7** |
| 9-10 | | 2b | u16 | `extSkewBlocks` | Used when GH1 30 = FF. **New in 3.0** |
| 11 | | 1b | u8 | `revisionMajor` | 3 |
| 12 | | 1b | u8 | `revisionMinor` | 0 |
| 13-16 | | 4b | u32 | `generalTrailerBlocks` | Number of 32-byte GT blocks. `FFFFFFFF` = unknown [p.91]. **2.1: u16 at 13-14** |
| 17-20 | | 4b | u32 | `extRecordLength` | **µs** [p.90]. Used when GH1 26-27 = FFF. **2.1: u24 ms at 15-17** |
| 21-22 | | 2b | u16 | `recordSetNumber` | Renamed from 2.1 "sequence number" [p.39]. 0 = not valid |
| 23-24 | | 2b | u16 | `extAdditionalGhBlocks` | Used when GH1 12H = F |
| 25-27 | | 3b | u24 | `dominantSamplingInterval` | µs. Used when GH1 23 = FF [p.90] |
| 28-30 | | 3b | u24 | `extExternalHeaderBlocks` | Used when GH1 32 = FF. **2.1: u16 at 8-9** |
| 31 | | 1b | — | `undefined31` | X |
| 32 | | 1b | u8 | `blockType` | 0x02 |

> **AMBIGUITY [p.59]:** Byte 25 bit 0 is garbled (`BSI23 Sample`). Treat it as BSI23.
> **AMBIGUITY [p.44 vs p.59]:** Sec 5.4 says GH2 "bytes 6 to 8" = extended header blocks, which matches the table (u24). The Rev 1 history [p.14] says 6-7. Follow 3.0: 6-8.

### 3.4 General Header Block #3, timestamp and size (ID 0x03) [p.60; detail p.91-92]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `timeZero` | SEG-D timestamp (§6.1) of time zero. 0 in Relative Time Mode |
| 9-16 | | 8b | u64 | `recordSize` | Total record bytes. 0 = unknown (e.g. GT count unknown). = dataSize if there's no trailer |
| 17-24 | | 8b | u64 | `dataSize` | Headers + traces bytes (offset of the trailer) |
| 25-28 | | 4b | u32 | `headerSize` | All header bytes (offset of the first trace) |
| 29 | | 1b | u8 | `extendedRecordingMode` | 1 = ERM, 0 = normal |
| 30 | | 1b | u8 | `relativeTimeMode` | 1 = no absolute time (timeZero must be 0) |
| 31 | | 1b | — | `undefined31` | X |
| 32 | | 1b | u8 | `blockType` | 0x03 |

### 3.5 GH #4-#8 text blocks (optional) [p.60-64; detail p.92-93]
All ASCII.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| **GH#4 Vessel/Crew, ID 0x10** | | | | | |
| 1-3 | | 3b | ascii | `vesselCrewAbbr` | VCA |
| 4-31 | | 28b | ascii | `vesselCrewName` | VC |
| 32 | | 1b | u8 | `blockType` | 0x10 |
| **GH#5 Survey Area, ID 0x11** | | | | | |
| 1-31 | | 31b | ascii | `surveyAreaName` | SAN |
| 32 | | 1b | u8 | `blockType` | 0x11 |
| **GH#6 Client, ID 0x12** | | | | | |
| 1-31 | | 31b | ascii | `clientId` | CI |
| 32 | | 1b | u8 | `blockType` | 0x12 |
| **GH#7 Job, ID 0x13** | | | | | |
| 1-5 | | 5b | ascii | `jobIdAbbr` | JIA |
| 6-31 | | 26b | ascii | `jobId` | JI |
| 32 | | 1b | u8 | `blockType` | 0x13 |
| **GH#8 Line, ID 0x14** | | | | | |
| 1-7 | | 7b | ascii | `lineAbbr` | LA |
| 8-31 | | 24b | ascii | `lineId` | LI |
| 32 | | 1b | u8 | `blockType` | 0x14 |

### 3.6 Source Description blocks (optional) [p.64-69; detail p.94-104]
Common layout. Type-specific bytes are 15-18 and 28-29.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `extFileNumber` | Same as the record's file number |
| 4-8 | | 5b | fixedpt | `sourceLineNumber` | Bytes 4-6 integer, 7-8 fraction. The 40-bit two's complement over 4-8 = 65536 × value (i40 / 2^16) [p.94] |
| 9-13 | | 5b | fixedpt | `sourcePointNumber` | Same encoding as the line number |
| 14 | | 1b | u8 | `sourcePointIndex` | |
| 15-18 | | 4b | — | *(type-specific, below)* | |
| 19 | | 1b | u8 | `sourceId` | 0 = unknown |
| 20 | | 1b | u8 | `sourceSetNumber` | |
| 21 | | 1b | u8 | `reshootIndex` | |
| 22 | | 1b | u8 | `groupIndex` | |
| 23 | | 1b | u8 | `depthIndex` | |
| 24-25 | | 2b | i16 | `offsetCrossline` | |
| 26-27 | | 2b | i16 | `offsetInline` | |
| 28-29 | | 2b | — | *(type-specific, below)* | |
| 30-31 | | 2b | i16 | `offsetDepth` | |
| 32 | | 1b | u8 | `blockType` | 15/16/17/18/19/1F |

Type-specific fields:

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| **Vibrator, ID 0x15 [p.65]** | | | | | |
| 15 | | 1b | u8 | `phaseControl` | PC |
| 16 | | 1b | u8 | `vibratorType` | V |
| 17-18 | | 2b | i16 | `phaseAngle` | PA |
| 28-29 | | 2b | u16 | `size` | SZ (unsigned for vibrator [p.95]) |
| **Explosive, ID 0x16 [p.65-66]** | | | | | |
| 15-16 | | 2b | u16 | `depth` | DE, cm [p.96] |
| 17 | | 1b | u8 | `chargeLength` | CL, dm [p.96] |
| 18 | | 1b | u8 | `soilType` | ST |
| 28-29 | | 2b | i16 | `size` | SZ |
| **Airgun, ID 0x17 [p.66-67]; Watergun, ID 0x18 [p.67-68] identical** | | | | | |
| 15-16 | | 2b | u16 | `depth` | DE |
| 17-18 | | 2b | u16 | `airPressure` | AP |
| 28-29 | | 2b | i16 | `size` | SZ |
| **EM source, ID 0x19 [p.68]** | | | | | |
| 15 | | 1b | u8 | `emSourceType` | ST |
| 16-18 | | 3b | u24 | `moment` | MO |
| 28-29 | | 2b | u16 | `currentOrVoltage` | CV |
| **Other, ID 0x1F [p.69]** | | | | | |
| 15-18 | | 4b | — | `undefined15` | X |
| 28-29 | | 2b | — | `undefined28` | X |

### 3.7 Additional Source Info (ID 0x20, see AMBIGUITY in §3.1) [p.69-70]
Follows the Source Description block.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `time` | SEG-D timestamp (actual source firing time). 0 allowed |
| 9 | | 1b | u8 | `sourceStatus` | SST |
| 10 | | 1b | u8 | `sourceId` | |
| 11 | | 1b | u8 | `sourceMoving` | MV |
| 12-31 | | 20b | ascii | `errorDescription` | ED |
| 32 | | 1b | u8 | `blockType` | 0x20 (table bits: 0x1A) |

### 3.8 Source Auxiliary Channel Reference (ID 0x21) [p.70-71; detail p.105-106]
Follows the Source Description block. 5 channel references of 6 bytes each.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 1b | u8 | `sourceId` | |
| 2 | | 2n | bcd | `scanType1` | ST1 |
| 3-4 | | 2b | u16 | `channelSet1` | |
| 5-7 | | 3b | u24 | `traceNumber1` | |
| 8 / 9-10 / 11-13 | | | bcd / u16 / u24 | `scanType2`, `channelSet2`, `traceNumber2` | |
| 14 / 15-16 / 17-19 | | | bcd / u16 / u24 | `…3` | |
| 20 / 21-22 / 23-25 | | | bcd / u16 / u24 | `…4` | |
| 26 / 27-28 / 29-31 | | | bcd / u16 / u24 | `…5` | |
| 32 | | 1b | u8 | `blockType` | 0x21 |

> **AMBIGUITY [p.71]:** Byte 12 bit 7 is printed `TN18`. It should be `TN28` (typo).

### 3.9 Coordinate Reference System Identification (ID 0x55) [p.72]
Mandatory if any position block is in the record.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-31 | | 31b | ascii | `crsText` | Chunk of a Location Data (EPSG) stanza (Appendix D). Multiple consecutive blocks hold one stanza [p.30] |
| 32 | | 1b | u8 | `blockType` | 0x55 |

### 3.10 Position Block (3 × 32 = 96 bytes; IDs 0x50, 0x51, 0x52) [p.72-74; detail p.107-110]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `timeOfPosition` | SEG-D timestamp |
| 9-16 | | 8b | i64 | `timeOfMeasurement` | SEG-D timestamp |
| 17-20 | | 4b | f32 | `verticalError` | 95%, units of the vertical coordinate |
| 21-24 | | 4b | f32 | `horizErrorSemiMajor` | |
| 25-28 | | 4b | f32 | `horizErrorSemiMinor` | |
| 29-30 | | 2b | u16 | `horizErrorOrientation` | Bearing to grid north, 1/100 steps (part B) |
| 31 | | 1b | u8 | `positionType` | PT (part B) |
| 32 | | 1b | u8 | `blockType1` | 0x50 |
| 33-40 | | 8b | f64 | `tuple1Coord1` | §6.4 |
| 41-48 | | 8b | f64 | `tuple1Coord2` | |
| 49-56 | | 8b | f64 | `tuple1Coord3` | |
| 57-58 | | 2b | u16 | `stanzaId1` | Location Data Stanza ID (1-65535) |
| 59 | | 1b | u8 | `position1Valid` | |
| 60 | | 1b | u8 | `position1Quality` | |
| 61-63 | | 3b | — | `undefined61` | X |
| 64 | | 1b | u8 | `blockType2` | 0x51 |
| 65-72 | | 8b | f64 | `tuple2Coord1` | |
| 73-80 | | 8b | f64 | `tuple2Coord2` | |
| 81-88 | | 8b | f64 | `tuple2Coord3` | |
| 89-90 | | 2b | u16 | `stanzaId2` | |
| 91 | | 1b | u8 | `position2Valid` | |
| 92 | | 1b | u8 | `position2Quality` | |
| 93-95 | | 3b | — | `undefined93` | X |
| 96 | | 1b | u8 | `blockType3` | 0x52 |

### 3.11 Relative Position Block (ID 0x56) [p.75; detail p.110]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | f32 | `offsetEasting` | Grid units |
| 5-8 | | 4b | f32 | `offsetNorthing` | |
| 9-12 | | 4b | f32 | `offsetVertical` | Height/depth sense per CRS |
| 13-31 | | 19b | ascii | `description` | Left-justified, space-padded |
| 32 | | 1b | u8 | `blockType` | 0x56 |

### 3.12 Scan Type Header: Channel Set Descriptor (96 bytes; IDs 0x30, 0x31, 0x32) [p.75-78; detail p.111-115]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 2n | bcd | `scanTypeNumber` | 1-99 |
| 2-3 | | 2b | u16 | `channelSetNumber` | 1-65535 |
| 4 | | 1b | u8 | `channelType` | Codes in part B. 0xF0 = calibration channel set [p.57] |
| 5-8 | | 4b | i32 | `startTime` | µs. May be negative |
| 9-12 | | 4b | i32 | `endTime` | µs |
| 13-16 | | 4b | u32 | `numSamples` | Samples per trace in this set. 0 allowed (start = end) |
| 17-20 | | 4b | f32 | `descaleMultiplier` | DSM (§6.2) |
| 21-23 | | 3b | u24 | `channelsInSet` | 0 = unused channel set |
| 24-26 | | 3b | u24 | `samplingInterval` | µs |
| 27 | | 1b | u8 | `arrayForming` | |
| 28 | | 1b | u8 | `traceHeaderExtensions` | Number of THE blocks per trace (0-255). Must equal demux byte 10 |
| 29 | H | 4 bits | u8 (u4) | `extendedHeaderFlag` | EFH |
| 29 | L | 4 bits | u8 (u4) | `channelGainControl` | J |
| 30 | | 1b | u8 | `verticalStack` | 0 = data set to 0, 1 = no stack |
| 31 | | 1b | u8 | `streamerNumber` | CAB |
| 32 | | 1b | u8 | `blockType1` | 0x30 |
| 33-36 | | 4b | f32 | `aliasFilterFreq` | Hz |
| 37-40 | | 4b | f32 | `lowCutFilterFreq` | Hz |
| 41-44 | | 4b | f32 | `aliasFilterSlope` | dB/oct |
| 45-48 | | 4b | f32 | `lowCutFilterSlope` | 0 = out |
| 49-52 | | 4b | f32 | `notch1Freq` | 0.0 = out |
| 53-56 | | 4b | f32 | `notch2Freq` | |
| 57-60 | | 4b | f32 | `notch3Freq` | |
| 61 | | 1b | u8 | `filterPhase` | |
| 62 | | 1b | u8 | `physicalUnit` | Same codes as THE1 byte 31 |
| 63 | | 1b | — | `undefined63` | X |
| 64 | | 1b | u8 | `blockType2` | 0x31 |
| 65-68 | | 4b | u32 | `filterDelay` | |
| 69-95 | | 27b | ascii | `description` | Free text |
| 96 | | 1b | u8 | `blockType3` | 0x32 |

Skew blocks follow the descriptors of each scan type: nSK × 32 bytes. One byte per sample per subscan per channel set, in recording order. Value = fraction of the base scan interval, LSB = 1/256 [p.41].

### 3.13 Demux Trace Header (20 bytes, no ID) [p.79; text p.42-43; detail p.115-116]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | bcd | `fileNumber` | `FFFF` → bytes 18-20 |
| 3 | | 2n | bcd | `scanTypeNumber` | 1-99 |
| 4 | | 2n | bcd | `channelSetNumber` | 1-99. `FF` → bytes 16-17 |
| 5-6 | | 4n | bcd | `traceNumber` | 1-9999. **`FFFF` → THE1 bytes 22-24** (new in 3.0) |
| 7-9 | | 3b | fixedpt | `firstTimingWord` | i16.u8 ms (bit S, 2^14..2^−8). LSB = 1/256 ms |
| 10 | | 1b | u8 | `traceHeaderExtensions` | 0-255. Must equal CSD byte 28 |
| 11 | | 1b | fixedpt | `sampleSkew` | u0.8 fraction of the base scan interval |
| 12 | | 1b | u8 | `traceEdit` | TR (0 none, 1 roll-on/off zeroed, 2 zeroed, 3 edited by acquisition system [p.12, p.15]) |
| 13-15 | | 3b | fixedpt | `timeBreakWindow` | u16.u8 ms |
| 16-17 | | 2b | u16 | `extChannelSetNumber` | |
| 18-20 | | 3b | u24 | `extFileNumber` | |

> **AMBIGUITY [p.43]:** The timing word has a sign bit (MSB 2^14 = 16384 ms), but the same paragraph says "0 to 65535.9961 msec can be encoded" and "may overflow to zero". Sec 8.17 says signed. Decode as i24/256 ms. Writers must not depend on it in 3.0 (start times come from CSD/timestamps).

### 3.14 Trace Header Extension #1 (ID 0x40, required) [p.80; detail p.116-118]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | i24 | `receiverLineNumber` | `FFFFFF` → bytes 11-15 |
| 4-6 | | 3b | i24 | `receiverPointNumber` | `FFFFFF` → bytes 16-20 |
| 7 | | 1b | i8 | `receiverPointIndex` | Signed per [p.116] |
| 8 | | 1b | u8 | `reshootIndex` | From 0. **2.1: bytes 8-10 = samples/trace** |
| 9 | | 1b | u8 | `groupIndex` | Component number for multi-component data |
| 10 | | 1b | u8 | `depthIndex` | |
| 11-15 | | 5b | fixedpt | `extReceiverLineNumber` | i40 / 2^16 |
| 16-20 | | 5b | fixedpt | `extReceiverPointNumber` | i40 / 2^16 |
| 21 | | 1b | u8 | `sensorType` | Part B |
| 22-24 | | 3b | u24 | `extTraceNumber` | Used when demux 5-6 = FFFF |
| 25-28 | | 4b | u32 | `numSamples` | Samples in this trace |
| 29 | | 1b | u8 | `sensorMoving` | |
| 30 | | 1b | — | `undefined30` | X |
| 31 | | 1b | u8 | `physicalUnit` | Code table in sec 8 (part B) |
| 32 | | 1b | u8 | `blockType` | 0x40 |

### 3.15 Sensor Info Header Extension (ID 0x41) [p.80-81; detail p.118]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `instrumentTestTime` | SEG-D timestamp. 0 = none |
| 9-12 | | 4b | f32 | `sensorSensitivity` | STY (§6.3) |
| 13 | | 1b | u8 | `instrumentTestResult` | |
| 14-31 | | 18b | ascii | `serialNumber` | |
| 32 | | 1b | u8 | `blockType` | 0x41 |

### 3.16 Timestamp Header (ID 0x42) [p.81-82]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `timeZeroOfData` | SEG-D timestamp of the first sample of this trace/data block (required in ERM) |
| 9-31 | | 23b | — | `undefined` | X |
| 32 | | 1b | u8 | `blockType` | 0x42 |

### 3.17 Sensor Calibration Header (ID 0x43) [p.82-83]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | f32 | `frequency1` | |
| 5-8 | | 4b | f32 | `amplitude1` | |
| 9-12 | | 4b | f32 | `phase1` | |
| 13-16 | | 4b | f32 | `frequency2` | |
| 17-20 | | 4b | f32 | `amplitude2` | |
| 21-24 | | 4b | f32 | `phase2` | |
| 25 | | 1b | u8 | `calibrationApplied` | 1 = applied |
| 26-31 | | 6b | — | `undefined` | X |
| 32 | | 1b | u8 | `blockType` | 0x43 |

### 3.18 Time Drift Header (ID 0x44) [p.83]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `timeOfDeployment` | SEG-D timestamp |
| 9-16 | | 8b | i64 | `timeOfRetrieval` | SEG-D timestamp |
| 17-20 | | 4b | i32 | `timeOffsetDeployment` | Units in part B |
| 21-24 | | 4b | i32 | `timeOffsetRetrieval` | |
| 25 | | 1b | u8 | `timeDriftCorrected` | |
| 26 | | 1b | u8 | `correctionMethod` | |
| 27-31 | | 5b | — | `undefined` | X |
| 32 | | 1b | u8 | `blockType` | 0x44 |

### 3.19 Orientation Header (ID 0x60) [p.83-84]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | f32 | `rotationX` | radians |
| 5-8 | | 4b | f32 | `rotationY` | radians |
| 9-12 | | 4b | f32 | `rotationZ` | radians |
| 13-16 | | 4b | f32 | `referenceOrientation` | |
| 17-24 | | 8b | i64 | `timestamp` | SEG-D timestamp |
| 25 | | 1b | u8 | `orientationType` | |
| 26 | | 1b | u8 | `refOrientationValid` | |
| 27 | | 1b | u8 | `rotationApplied` | |
| 28 | | 1b | u8 | `rotationNorthApplied` | |
| 29-31 | | 3b | — | `undefined` | X |
| 32 | | 1b | u8 | `blockType` | 0x60 |

### 3.20 Measurement Block (ID 0x61) [p.84-85]
The spec flags this block as not finalized [p.9].

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | i64 | `timestamp` | SEG-D timestamp |
| 9-12 | | 4b | f32 | `value` | |
| 13-16 | | 4b | f32 | `maxValue` | |
| 17-20 | | 4b | f32 | `minValue` | |
| 21-22 | | 2b | u16 | `quantityClass` | |
| 23-24 | | 2b | u16 | `unitOfMeasure` | Energistics UoM code (Appendix F) |
| 25-26 | | 2b | u16 | `measurementDescription` | |
| 27-31 | | 5b | — | `undefined` | X |
| 32 | | 1b | u8 | `blockType` | 0x61 |

### 3.21 EM Src/Recv Description Block (ID 0x45) [p.85-86]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3 | | 3b | u24 | `equipDimX` | cm |
| 4-6 | | 3b | u24 | `equipDimY` | cm |
| 7-9 | | 3b | u24 | `equipDimZ` | cm |
| 10 | | 1b | u8 | `positiveTerminal` | |
| 11-13 | | 3b | i24 | `equipOffsetX` | |
| 14-16 | | 3b | i24 | `equipOffsetY` | |
| 17-19 | | 3b | i24 | `equipOffsetZ` | |
| 20-31 | | 12b | — | `undefined` | X |
| 32 | | 1b | u8 | `blockType` | 0x45 |

### 3.22 General Trailer Description Block (ID 0x70) [p.86; detail p.126]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 1b | u8 | `trailerBlockType` | §4.3 |
| 2 | | 1b | u8 | `asciiOrBinary` | 0x01 binary, 0x02 ASCII [p.126] |
| 3-4 | | 2b | u16 | `zero3to4` | 0 |
| 5-8 | | 4b | u32 | `blockSize` | Number of 32-byte blocks of data. Bytes = 32×SI [p.126] |
| 9-24 | | 16b | ascii | `description` | e.g. `TRACE EDIT v1.0 ` |
| 25-31 | | 7b | — | `zero25to31` | 0 |
| 32 | | 1b | u8 | `blockType` | 0x70 |

> **AMBIGUITY [p.44, p.126]:** It isn't stated whether `blockSize` and GH2 bytes 13-16 include the 32-byte description block itself. Recommend: `blockSize` excludes the description block (it counts the "data block"), and GH2 13-16 counts **all** 32-byte trailer blocks including descriptions. Validate against GH3 `recordSize − dataSize`.

## 4. Code tables

### 4.1 Format codes (GH1 bytes 3-4) [p.87, p.9, p.14]

| Code | Method | Bytes/sample | Section |
|---|---|---|---|
| 8015 | 20-bit binary exponent (2½ byte) | 2.5 (10 per 4 samples) | §5.3 |
| 8022 | 8-bit quaternary exponent | 1 | §5.1 |
| 8024 | 16-bit quaternary exponent | 2 | §5.2 |
| 8036 | 24-bit two's complement integer | 3 | §5.9 |
| 8038 | 32-bit two's complement integer | 4 | §5.10 |
| 8042 | 8-bit hexadecimal exponent | 1 | §5.4 |
| 8044 | 16-bit hexadecimal exponent | 2 | §5.5 |
| 8048 | 32-bit hexadecimal (excess-64, IBM-style) | 4 | §5.6 |
| 8058 | 32-bit IEEE float | 4 | §5.7 |
| 8080 | 64-bit IEEE float (**new in 3.0**) | 8 | §5.8 |
| 0000, 0200 | Illegal | | |
| 00xx (0036/0038/0058, etc.) | Multiplexed. **Not supported in 3.0** (and not since 2.0) | | |

One number system is used for all samples in a record, aux channels included [p.49].

### 4.2 Trace Edit record functions (Trailer type 0x01) [p.45-46]

| Char | Class | Meaning | Required |
|---|---|---|---|
| V | Header | `V SEGD Trace Edit v1.0` | yes |
| C | Header | Comment | no |
| S | Header | `S HH:MM:SS DD-MMM-YYYY` UTC, 1 s accuracy | yes |
| W | Header | System/person generating the edit | yes |
| A | Header | Attribute definition and range | ≥1 |
| P | Header | Additional parameters for an attribute | no |
| H | Header | Test description | yes |
| R | Header | Range of traces tested (absent = all) | no |
| Y | Header | `EXCLUDE` (default) or `WARNING` | no |
| X | Primary key | Exclude these trace ranges | |
| I | Primary key | Include (overrides X) | |
| E | Terminator | End of a header/primary-key pair | ≥1 |
| T | Terminator | End of the dataset | exactly 1 |

### 4.3 General Trailer block types [p.45-48, p.126]

| BT | ASCII/bin | Description (bytes 9-24, 16 chars) | Content |
|---|---|---|---|
| 0x01 | 0x02 | `TRACE EDIT v1.0 ` | SEG-D Trace Edit v1.0 |
| 0x10 | 0x02 | `TEXT COMMENT    ` | Free text, LF or CRLF lines |
| 0x11 | 0x02 | `OBSERVER LOG    ` | Observer log text |
| 0x20 | 0x02 | `P1 FILE FORMAT  ` | P1 processed navigation |
| 0x21 | 0x02 | `P2 FILE FORMAT  ` | P2 raw marine positioning |
| 0x22 | 0x02 | `P3 File Format  ` | P3 land survey (mixed case as printed) |
| 0x23 | 0x02 | `P5 FILE FORMAT  ` | P5 pipeline |
| 0x24 | 0x02 | `P6 FILE FORMAT  ` | P6 3D binning grids |
| 0x25 | 0x02 | `P7 FILE FORMAT  ` | P7 well deviation |
| 0x26 | 0x02 | `SPS FILE FORMAT ` | SPS |
| 0x27 | 0x02 | `SEGY TEXT STANZA` | SEG-Y extended textual stanza |
| 0xA0-0xFF | 0x01/0x02 | user | User defined |

ASCII blocks are padded with 0x20 to a multiple of 32. Binary blocks are padded with 0x00 [p.9]. A whole file goes into one trailer block. Use several blocks for several files.

> **AMBIGUITY [p.45, p.47-48]:** The description strings are printed with trailing spaces of uncertain count. Pad to 16 bytes with spaces. Match case-insensitively and trimmed when reading.

### 4.4 Coordinate tuple by CRS type [p.29-30]

| CRS type | Coord 1 | Coord 2 | Coord 3 |
|---|---|---|---|
| projected | easting or northing | northing or easting | unused |
| geographic2D | latitude | longitude | unused |
| geographic3D | latitude | longitude | ellipsoidal height |
| vertical | unused | unused | gravity-related height or depth |
| geocentric | X | Y | Z |
| compound geographic+vertical | latitude | longitude | height or depth |
| compound projected+vertical | easting/northing | northing/easting | height or depth |

Ranges: coords 1 and 2 are −9,999,999..60,800,000 (10 significant figures), coord 3 is −6,400,000..6,400,000 (9 sig. figs). All are signed. Axis order and height vs depth come from the CRS stanza.

## 5. Data sample formats [p.49-54]
Bits are numbered as in the spec: bit 0 = MSB of the byte. Traces are demultiplexed: each trace is a contiguous run of `numSamples` samples, big-endian. "Input signal (mV) = decoded value × DSM" (DSM = CSD bytes 17-20).

Notation: `w` = the sample word read big-endian as an unsigned integer.

### 5.1 8022: 1-byte quaternary exponent
`S(b7) C2 C1 C0 (b6-b4) Q−1..Q−4 (b3-b0)`. C = exponent of 4 (0-7). Q is a 4-bit **one's complement** fraction with the radix left of Q−1. Decode: `q = w & 0xF; if S: q = -(q xor 0xF)`. `v = q/2^4 × 4^C`. Range ±(1−2^−4).

### 5.2 8024: 2-byte quaternary exponent
`S(bit15) C2-C0 (14-12) Q−1..Q−12 (11-0)`. `q = w & 0xFFF; if S: q = -(q xor 0xFFF)`. `v = q/2^12 × 4^C`.

### 5.3 8015: 20-bit binary exponent, 4-sample groups of 10 bytes

| Byte | Bits 0-3 (H) | Bits 4-7 (L) |
|---|---|---|
| 1 | C (sample 1) | C (sample 2) |
| 2 | C (sample 3) | C (sample 4) |
| 3-4 | sample 1: S + Q−1..Q−15 | |
| 5-6 | sample 2 | |
| 7-8 | sample 3 | |
| 9-10 | sample 4 | |

C = 4-bit exponent of 2 (0-15). Mantissa m = 16-bit word, S = bit 15, 15-bit one's complement fraction: `q = m & 0x7FFF; if S: q = -(q xor 0x7FFF)`. `v = q/2^15 × 2^C`. **numSamples must be divisible by 4** [p.51].

> **AMBIGUITY [p.49-50]:** The general text describes one's complement as "all bits flipped". For 8022/8024/8015 the exponent sits between S and Q (or in a separate nibble). The note assumes only the fraction bits are complemented, and the exponent is unaffected. This matches the "S.QQQQ × 4^CCC" formula and the stated ranges.

### 5.4 8042: 1-byte hexadecimal exponent
`S(b7) C1 C0 (b6-b5) Q−1..Q−5 (b4-b0)`. **Sign-magnitude** ("positive binary fraction"). `v = (−1)^S × (w & 0x1F)/2^5 × 16^C`, C 0-3.

### 5.5 8044: 2-byte hexadecimal exponent
`S(15) C1 C0 (14-13) Q−1..Q−13 (12-0)`. Sign-magnitude. `v = (−1)^S × (w & 0x1FFF)/2^13 × 16^C`.

### 5.6 8048: 4-byte hexadecimal excess-64 (= IBM System/360 single, `ibm32`)
`S(31) C6..C0 (30-24) Q−1..Q−24 (23-0)`. `v = (−1)^S × (w & 0xFFFFFF)/2^24 × 16^(C−64)`. The fraction must be left-justified (hex-normalized). If the fraction = 0, the whole word must be 0.

### 5.7 8058: IEEE 754 single (`f32`)
S(31), e = bits 30-23 (C7..C0), f = bits 22-0. Standard IEEE decode. NaN = invalid sample. e=255 & f=0 = overflow (∞).

### 5.8 8080: IEEE 754 double (`f64`)
S(63), e = 11 bits (printed C11..C1), f = 52 bits. Standard IEEE. NaN = invalid.

> **AMBIGUITY [p.53]:** The double layout labels the exponent bits C11..C1 (not C10..C0), and byte 5 shows `Q27` without a minus sign. Both are cosmetic. Use standard IEEE 754 binary64.

### 5.9 8036: 24-bit two's complement
I23..I0 big-endian, 3 bytes. `v = ((w + 2^23) mod 2^24) − 2^23`.

### 5.10 8038: 32-bit two's complement
`i32` big-endian.

Historic note (Rev 1, [p.14-15]): in the multiplexed 0058 format, bit 7 of byte 4 had to be 0. That doesn't apply to demux 8058.

## 6. Derived rules / algorithms

### 6.1 SEG-D timestamp [p.25-27]
- **Definition:** `i64` big-endian, **microseconds since 1980-01-06 00:00:00 GPS (GPS epoch)**. Equal to GPS time in µs. Negative values are before the epoch. There are no leap seconds in the timestamp scale.
- The official record time is GH3 bytes 1-8. GH1 bytes 11-16 hold the same instant as **UTC** (BCD, 1 s resolution, second may be 60).
- Relative Time Mode (GH3 byte 30 = 1): GH3 TZ = 0, and all timestamps are relative to the start of the record. GH1 time is then free (1970-01-01, approximate, or relative) [p.25].
- UTC ↔ timestamp: `ts_s = (unixUtc − 315964800) + (L(utc) − 9)`, where `unixUtc` = POSIX seconds (no leap seconds), 315964800 = POSIX 1980-01-06T00:00:00, and `L(t)` = cumulative leap seconds inserted since 1970-01-01 per the table below (L = 9 at the GPS epoch). Checks from the spec: 1970-01-01 → UTC 9 s ahead of the timestamp (L=0 → −9). 2008-03-01 → UTC 14 s behind (L=23). 2009-04 → 15 s behind.
- Pre-1972: SEG-D defines no leap seconds in 1970 and 1971. The timestamp = TAI + 19 s offset from 1972-01-01 [p.26].
- During a leap second the UTC sequence is 23:59:59 → 23:59:60 → 00:00:00. Converters must accept second = 60.

Leap seconds inserted into UTC (end of the given day) [p.26-27]:

| Year | 30 Jun | 31 Dec |
|---|---|---|
| 1970-1971 | — | — |
| 1972 | +1 | +1 |
| 1973-1979 | — | +1 each year |
| 1980 | — | — |
| 1981, 1982, 1983 | +1 | — |
| 1985 | +1 | — |
| 1987 | — | +1 |
| 1989, 1990 | — | +1 |
| 1992, 1993, 1994 | +1 | — |
| 1995 | — | +1 |
| 1997 | +1 | — |
| 1998 | — | +1 |
| 2005 | — | +1 |
| 2008 | — | +1 |
| 2012 | +1 | — |
| other years ≤2014 | — | — (2014 Dec blank in source) |

Implementation note (outside this source): the table ends in 2014. Real-world leap seconds were later added on 2015-06-30 and 2016-12-31 (GPS−UTC = 18 s since 2017). Make the table data-driven and extendable.

### 6.2 DSM and physical units [p.54-56]
- `mV = sample × DSM` (DSM = CSD bytes 17-20, f32). For 8048/8058/8080, DSM may be 1.0.
- Physical value: `Vp = Vt × DSM / STY`, where STY = Sensor Info bytes 9-12 (f32). Unit = CSD byte 62 = THE1 byte 31.
- Legacy MP form: `DSM = 2^MP`.

| Data | MP | Cmax |
|---|---|---|
| Binary exponent (8015) | FS − PA − Cmax | 15 |
| Quaternary (8022/8024) | FS − PA − 2·Cmax | 7 |
| Hex, not excess-64 (8042/8044) | FS − PA − 4·Cmax | 3 |
| Hex excess-64 (8048) | FS − PA − 4·(Cmax − 64) | 127 |
| IEEE 32 (8058) | FS − PA − (Cmax − 127) | 255 |
| IEEE 64 (8080) | FS − PA − (Cmax − 1023) | 2047 |
| Integer (8036/8038) | FS − PA − IS | 2^(IS−1) = integer positive full scale |

Here 2^FS = converter full scale in mV and 2^PA = minimum system gain (preamp × minimum FP amplifier gain, e.g. 256 → PA = 8). In 2.x, MP was stored in CSD bytes 7-8 (the Rev 1 note says byte 7 was added for precision). In 3.0 only DSM f32 is stored [p.54, p.15].

### 6.3 Sensor calibration [p.56-57]
- Frequency domain: Sensor Calibration blocks (0x43) in the trace header, 2 (f, amplitude, phase) triplets per block. Up to about 500 frequencies per trace. `Vcal(f) = Fc(f) · Vtrace(f)`.
- Time domain: a calibration channel set has channel type 0xF0 (CSD byte 4). The THE1 indices tie it to its trace.

### 6.4 Size computations

```
nGH      = 1 + (GH1[12].H == 0xF ? GH2[23..24] : GH1[12].H)        # total GH blocks
nST      = bcd(GH1[28])
nCS      = GH1[29]==0xFF ? GH2[4..5]   : bcd(GH1[29])
nSK      = GH1[30]==0xFF ? GH2[9..10]  : bcd(GH1[30])
nEC      = GH1[31]==0xFF ? GH2[6..8]   : bcd(GH1[31])
nEX      = GH1[32]==0xFF ? GH2[28..30] : bcd(GH1[32])
headerSize = 32*nGH + nST*(96*nCS + 32*nSK) + 32*nEC + 32*nEX     # should equal GH3.headerSize
traceBytes(cs) = 20 + 32*cs.traceHeaderExtensions + bytesFor(cs.numSamples, format)
bytesFor(n, 8015) = n/4*10 ; others n*bytesPerSample (§4.1)
dataBytes  = Σ_scanType Σ_cs cs.channelsInSet * traceBytes(cs)
dataSize   = headerSize + dataBytes                                  # GH3.dataSize
trailer    = 32*GH2[13..16]                                          # GH3.recordSize - GH3.dataSize
nextRecord = recordStart + GH3.recordSize   (byte-stream media; fixed-block: round up to block)
```

- Prefer GH3 sizes when they're non-zero. Use the computed values for validation and recovery. `recordSize = 0` or `GT = FFFFFFFF` means the trailer size is unknown. Scan forward for the next GH1 or the end of the file.
- The first trace starts at `headerSize`. The first trailer block starts at `dataSize` (each aligned to a device block on blocked media, §2.3).
- Per-trace sample count: CSD bytes 13-16 (all traces in a CS have equal length and equal THE count [p.42]). THE1 bytes 25-28 repeats it per trace. In ERM the count may differ per channel set [p.28].
- Sample interval: CSD bytes 24-26 (µs). Base scan interval: GH1 byte 23 (1/16 ms) or GH2 bytes 25-27 (µs) when it is FF.
- Multiple scan types: each has the same nCS. Unused sets have C/S = 0. Bytes per base scan interval are constant across scan types [p.42].
- Zero-length traces: start = end, NS = 0. A record with no channel sets is allowed (header and trailer only) [p.7].

### 6.5 Extended Recording Mode [p.28-29]
- GH3 byte 29 = 1. Each trace's first-sample time = Timestamp Header (0x42) bytes 1-8 in its trace header, **not** CSD start time. The full u32 sample count is usable.
- Long recordings: the same sensors continue in successive channel sets (up to 65535). Gaps are expressed via per-CS NS and timestamps. One sensor appears at most once per channel set. A new scan type isn't required.

### 6.6 Time drift [p.29]
Linear correction from the Time Drift block (deployment/retrieval times and offsets). All channels in a record must share one time reference. Multi-unit data must be drift-corrected before merging. Irregular sample intervals aren't supported.

### 6.7 Multi-component [p.28]
Each component goes in a separate channel set. THE1 group index = component number C1/C2/C3. `[Cnorth, Ceast, Cvertical]^T = R(3×3) · [C1, C2, C3]^T`, with R from the Orientation header. Traces that share line/point/point-index/group/depth/reshoot indices rotate together.

### 6.8 Trace Edit v1.0 syntax [p.45-47]
- Lines are `<char><space><text><LF>`. LF (0x0A) or CRLF. Pad the block with spaces to a multiple of 32. Later edit blocks override earlier ones.
- Order: header (V/S/W/C), then per test H/A/P/Y/R/X/I/E/C (and optionally S/W), then T.
- R/X/I: `<L> <scanTypeList>,<channelSetList>,<traceList>`, where each list is comma-separated numbers or `a-b` ranges.

> **AMBIGUITY [p.47]:** The format line shows `;` separators (`<scanset NUMBER LIST;<channelset NUMBER LIST>;<trace NUMBER LIST>`). The examples use `,` between the three lists (`R 1-1,5-14,1-558`) and also between items in a list (`1,4,10–14`). A parser can't split the examples unambiguously. Recommend accepting `;` as the list separator, and for comma-only lines assuming exactly 3 comma-separated elements (one range each). Appendix E.6/E.7 (part B) has a complete example.

### 6.9 Version detection
- SUL bytes 5-9 = `SD3.0` (2.1 = `SD2.1`).
- GH2 bytes 11-12 = 03 00 (2.1 = 02 01).
- Rev 3 has GH3 (byte 32 = 0x03) right after GH2, and GH1 byte 12 nibble ≥ 2.
- A CSD of 96 bytes with 0x30/0x31/0x32 at offsets 32/64/96.

## 7. Implementation notes: changes in 3.0 vs 2.1 (sec 2.0 [p.7-9])

| # | Change | Library impact |
|---|---|---|
| 1 | Revision `SD3.0` in SUL field 2. GH2 bytes 11/12 = 3/0 | Version switch |
| 2 | SUL, GH1 and Demux header layouts kept for pattern matching. GH1 byte 23 may be FF (→ GH2 25-27). Demux bytes 5-6 may be FFFF (→ THE1 22-24) | Shared 2.1 parsers plus the new extension rules |
| 3 | A channel set is no longer required (header- or trailer-only records) | Allow ST/R = 0 or CS = 0 |
| 4 | Zero-length traces (start = end, NS = 0) | Handle NS = 0 |
| 5 | Extended Recording Mode (non-shot domain) | §6.5 |
| 6 | µs timestamp, GH3 bytes 1-8. Timestamps on positions, orientation and source events | §6.1 |
| 7 | Position blocks in trace headers. CRS in the GH. One datum per record | §3.9-3.10 |
| 8 | Extended indexing: line, point, point index, depth, group, reshoot | THE1 bytes 7-10 changed |
| 9 | Orientation header | §3.19 |
| 10 | Larger ranges (sampling µs, record length, channels, filters). Negative start time | CSD i32 µs |
| 11 | Header, data and record sizes in GH3 | §6.4 |
| 12 | Byte 32 of every block = type ID. Blocks optional and in any order | §3.1 |
| 13 | **CSD extended from 32 to 96 bytes**. Explicit sample interval, NS, DSM. Text description | New CSD parser. 2.1 CSD isn't compatible |
| 14 | Channels per CS up to 16,777,215 (u24) | |
| 15 | GH#4-8 (vessel, survey, client, job, line) | §3.5 |
| 16 | Extended/External up to 512 MB (u24 counts). Trailer up to 128 GB (u32 count) | GH2 6-8, 28-30, 13-16 widened |
| 17 | Trace header up to 8180 bytes (THE count 0-255, u8) | 2.0/2.1 limited to 15 |
| 18 | Per-type source description blocks replace 2.x "General Header Block N" (vibrator) | §3.6 |
| 19 | Additional Source Info (firing time, status) | §3.7 |
| 20 | Compound sources (source sets/groups) | |
| 21 | Source aux channel reference blocks | §3.8 |
| 22 | Source info may be in the GH or a trace header | Order-dependent association |
| 23 | 64-bit IEEE, format 8080 | §5.8 |
| 24 | Time drift header | §3.18 |
| 25 | EM source/receiver blocks | §3.6, §3.21 |
| 26 | Sensor sensitivity and calibration | §3.15, §3.17 |
| 27 | Measurement block (not finalized) | §3.20 |
| 28 | **General Trailer redesigned**: description block + data blocks, each a multiple of 32, padded 0x00 (binary) or 0x20 (ASCII) | 2.x trailer (CSD-like, byte 11 channel type 1100, bytes 1-2 block number [p.13]) isn't compatible |
| 29 | Trace Edit trailer format | §6.8 |
| 30 | Navigation file backups in the trailer | §4.3 |
| 31 | Observer log and text comment trailers | §4.3 |
| 32-35 | Appendix changes (examples added. Header descriptors appendix and tape-drive appendix removed. UoM appendix F added). Any device or network allowed | — |

Byte-level differences for code shared with 2.1 (2.1 side as described in this document's history sections [p.10-16]):

| Item | Rev 2.1 | Rev 3.0 |
|---|---|---|
| GH1 byte 12H (additional GH blocks) | count, max 15 | ≥2. F → GH2 23-24 (u16) |
| GH1 byte 23 | base scan interval | same. FF → GH2 25-27 µs |
| GH1 bytes 26-27 R = FFF | → GH2 15-17, u24 **ms** | → GH2 17-20, u32 **µs** |
| GH1 byte 30 SK = FF | n/a | → GH2 9-10 |
| GH1 byte 31 EC = FF | → GH2 6-7 (u16) | → GH2 6-8 (u24) |
| GH1 byte 32 EX = FF | → GH2 8-9 (u16) | → GH2 28-30 (u24) |
| GH2 bytes 13-x GT count | 13-14 u16 | 13-16 u32 |
| GH2 bytes 21-22 | sequence number | record set number (same semantics) |
| GH3 | absent | required |
| CSD | 32 bytes: MP factor (bytes 7-8), byte 29 = EFH nibble + THE nibble, 30 VS, 31 CAB, 32 array forming | 96 bytes (§3.12). Byte 28 THE (u8). Byte 29 = EFH + J. ARY at byte 27. Byte 32 = ID |
| Demux byte 10 THE | 4-bit, max 15 | u8, max 255 |
| THE1 bytes 8-10 | samples per trace (u24) | reshoot, group, depth index. NS moved to 25-28 (u32) |
| Trace number > 9999 | — | demux 5-6 = FFFF → THE1 22-24 |
| Record alignment | each record block-aligned | GH1, first trace header and first trailer block block-aligned |

Other gotchas:
- GH1 and the Demux header have **no** type byte. Don't scan for an ID in them.
- Mixed BCD/binary: GH1 byte 12 H is binary, L is BCD. CSD byte 1 is BCD, while bytes 2-3 are binary.
- An all-F BCD nibble pattern means "see extended field". Validate BCD digits otherwise.
- The block ordering in the GH and trace header is semantic (§3.1). Preserve order on round-trip.
- The 2.1-era multiplex/blocking rules (Rev 1 "blocked records ≤128 kB") don't apply.

## 8. Open questions
1. Additional Source Info block ID: 0x20 (Table 2) vs 0x1A (7.10 bit pattern). The recommendation in §3.1 needs to be confirmed against part B or real data.
2. Does GT `blockSize` (and the GH2 13-16 count) include the 32-byte description block?
3. On fixed-block media, are the pad bytes before the first trace and before the trailer counted in GH3 headerSize/dataSize/recordSize?
4. Demux timing word: signed (sec 8) vs 0-65535.996 ms (p.43). Choose signed decoding.
5. One's-complement handling for formats 8015/8022/8024 when a mantissa is negative zero (all fraction bits 1 with S = 1) → decode as 0.
6. TOC entry length: 64 vs 128 (use 128). TOC survey-type field width (20) vs printed strings.
7. SUL field numbering (field 10 vs 14 for max shots per field record).
8. Trace Edit R/X/I list separator (`;` vs `,`).
9. The leap-second table in the spec ends in 2014. Decide on a source for later leap seconds.
10. GH1 time vs GH3 timestamp consistency: how strictly should a reader validate when they disagree (beyond leap seconds and sub-second truncation)?
