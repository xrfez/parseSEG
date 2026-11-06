# SEG-D Rev 3.0, part B: header block parameters and appendices

## 1. Scope

- Source: `SEG Spec/text/seg_d_rev3_0-sep2014.txt` (SEG-D Rev 3.0, September 2014).
- Covered: pages **87–188**. That is §8.0 Header Block Parameters (§8.1–§8.26), Appendix A (manufacturer codes),
  B (glossary, format-relevant terms only), C (API/Energistics organization codes), D (CRS stanza syntax),
  E (examples and calculations: only the normative/derivable rules are kept), and F (Energistics UoM codes; the snapshot
  continues past p.188, so the remainder is out of scope).
- Skipped on purpose: the D.1.2 and D.1.4 stanza examples (p.147–151, p.159–160), the narrative in E.5 and E.10
  (survey-geometry prose, figures), the C++ test `main` in E.9, and the addresses and phone numbers in A and C.
- Pages 1–86 (overview, structure, tape label, TOC, data body, sample formats, §7 layout tables, Table 2 of header
  types, the timestamp definition and the Trace Edit v1.0 grammar) are in **`segd_rev3_0_a.md`**.
- All values written `NN16` in the source are hex; this note writes them as `0xNN`.

## 2. File / tape structure

See `segd_rev3_0_a.md`. The part relevant here is the block order inside one record, which you can infer from §8. Every block is a multiple of 32 bytes, except the 20-byte demux trace header:

```
General Header: GH1 (32) + GH2 (32) + GH3 (32) + [optional 32-byte blocks: GH4..GH8, source blocks,
                CRS blocks, position blocks (96), ...]              -- count = GH (or EGH), see 6.1
Scan type headers: for each of ST/R scan types:
                CS channel set descriptors (96 bytes each) + SK skew blocks (32 bytes each)
Extended Header: EC × 32 bytes      (manufacturer defined content)
External Header: EX × 32 bytes      (user defined content)
Traces:         per trace: Demux Trace Header (20) + THE × 32 (trace header extensions) + samples
General Trailer: GT × 32 bytes = [GTDB(32)][data SI×32][GTDB][data]...
```

Disk layout recommended by E.4 [p.162–163]: `|Tape Label|SEG-D Header|Trace Data|General Trailer|EOF|`. Use one
record per file (e.g. `<filenumber>.segd`). Set the label to storage unit structure `RECORD` and max block size `1`. Convert FIXREC
data to RECORD before you store it on disk.

## 3. Header tables

General rules [p.87]:
- **Extended-field rule.** When an extended field is used, *all nibbles* of the original field are set to F
  (e.g. `FFFF`, `FF`, `FFF`, or `F` for a nibble field). When the normal field is used, the extended field must be **0 or equal
  to the normal value**. No other values are allowed.
- Location indexes (line, point, point index, depth, group, reshoot) are `0` when unknown, unless the field says otherwise.
- Every block except GH1 and the demux trace header ends with byte 32 = **header block type** (see the master table in §4.1).
  Multi-block headers (96 bytes) carry a type byte at 32, 64 and 96.
- "Undefined / X" bytes: "may have any value" unless the field says "set to 0". A writer should emit 0.
- **SEG-D timestamp** = `i64`, microseconds since 1980-01-06 00:00:00 GPS epoch (GPS time, so leap seconds count). Negative values
  are allowed before the epoch (definition in part A; algorithm in §6.8).

### 3.1 General Header Block #1 [p.87–89]
All fields are packed BCD unless marked otherwise. There is **no** header-type byte.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–2 | | 4n | bcd | `fileNumber` | 0–9999. `FFFF` → use GH2 bytes 1–3. |
| 3–4 | | 4n | bcd | `formatCode` | See §4.2. `0200`, `0000` are illegal. |
| 5–10 | | 12n | bcd | `generalConstants` | K1–K12, 12 digits. |
| 11 | | 2n | bcd | `year` | Last two digits of year, 0–99. |
| 12 | 12H | 4 bits | bits | `additionalGhBlocks` | **Unsigned binary nibble** GH = number of general header blocks *after* GH1 (≥2 in Rev 3; GH1+GH2+GH3 only → 2). 0–14; `F` → use GH2 bytes 23–24. |
| 12–13 | 12L-13L | 3n | bcd | `julianDay` | 1–366 (DY1 = low nibble of byte 12, DY2 DY3 = byte 13). |
| 14 | | 2n | bcd | `hour` | 0–23, UTC. |
| 15 | | 2n | bcd | `minute` | 0–59. |
| 16 | | 2n | bcd | `second` | 0–60 (60 only during a UTC leap second). |
| 17 | | 2n | bcd | `manufacturerCode` | Appendix A (§4.20). |
| 18–19 | | 4n | bcd | `manufacturerSerial` | 4 digits. |
| 20–22 | | 3b | u24 | `reserved20` | Not used, record as 0. |
| 23 | | 1b | u8 | `baseScanInterval` | **Binary**, LSB = 1/16 ms (bits I3…I−4). Allowed: 1,2,4,…,128 (1/16…8 ms). Rev 3: the "dominant" rate, not a divisor of the channel-set rates. `FF` → use GH2 bytes 25–27 (µs). |
| 24 | 24H | 4 bits | bits | `polarity` | Binary nibble, §4.3. |
| 24 | 24L | 4 bits | bits | `unused24` | Not used. |
| 25 | | 1b | u8 | `unused25` | Not used. |
| 26 | 26H | 4 bits | bits | `recordType` | Binary nibble, §4.4. |
| 26–27 | 26L-27L | 3n | bcd | `recordLength` | R1R2.R3 × 1.024 s, i.e. value = BCD/10 × 1.024 s, in 0.5 steps (00.5 = 0.512 s … 99.5 = 101.888 s). `000` = indeterminate. `FFF` → use GH2 bytes 17–20. Must be `000` in Extended Recording Mode (GH3 byte 29 = 1). Max length of any trace. |
| 28 | | 2n | bcd | `scanTypesPerRecord` | ST/R, 0–99. |
| 29 | | 2n | bcd | `channelSetsPerScanType` | CS, 0–99. `FF` → GH2 bytes 4–5. Equals the **max** over scan types; shorter scan types are padded with dummy descriptors (channel count 0). |
| 30 | | 2n | bcd | `skewBlocks` | SK = number of 32-byte skew fields at the end of **each** scan type header, 0–99. 0 = no skew. `FF` → GH2 bytes 9–10. |
| 31 | | 2n | bcd | `extendedHeaderBlocks` | EC = number of 32-byte Extended Header blocks, 0–99. `FF` → GH2 bytes 6–8. |
| 32 | | 2n | bcd | `externalHeaderBlocks` | EX = number of 32-byte External Header blocks, 0–99. `FF` → GH2 bytes 28–30. |

### 3.2 General Header Block #2 [p.89–91]
All fields are unsigned binary unless marked otherwise.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–3 | | 3b | u24 | `extFileNumber` | Used when GH1 bytes 1–2 = `FFFF`. |
| 4–5 | | 2b | u16 | `extChannelSetsPerScanType` | Used when GH1 byte 29 = `FF`. |
| 6–8 | | 3b | u24 | `extExtendedHeaderBlocks` | Used when GH1 byte 31 = `FF`. Max 16,777,215 × 32 = 536,870,880 bytes. |
| 9–10 | | 2b | u16 | `extSkewBlocks` | Used when GH1 byte 30 = `FF`. |
| 11 | | 1b | u8 | `revisionMajor` | `0x03`. |
| 12 | | 1b | u8 | `revisionMinor` | `0x00`. Revision 0.x is not valid. |
| 13–16 | | 4b | u32 | `generalTrailerBlocks` | GT = number of 32-byte General Trailer blocks. `FFFFFFFF` = unknown: the reader walks the trailer block by block (§6.6). Max quoted 137,438,953,408 bytes (= 0xFFFFFFFE × 32). Set it correctly on tape. |
| 17–20 | | 4b | u32 | `extRecordLength` | Used when GH1 R = `FFF`. 0 = indeterminate. Max trace length; must be 0 in Extended Recording Mode. Negative channel-set start times are allowed. |
| 21–22 | | 2b | u16 | `recordSetNumber` | Sequence/swath/etc. 1–65535; 0 = not valid. Should match GH8. |
| 23–24 | | 2b | u16 | `extAdditionalGhBlocks` | EGH, used when GH1 byte 12 high nibble = `F`. Same meaning as GH. |
| 25–27 | | 3b | u24 | `dominantSamplingInterval` | µs. Used only if GH1 byte 23 = `FF`. 0 = indeterminate. Informational only: **do not** use it for size calculations. |
| 28–30 | | 3b | u24 | `extExternalHeaderBlocks` | Used when GH1 byte 32 = `FF`. Max 536,870,880 bytes. |
| 31 | | 1b | u8 | `undefined31` | Any value. |
| 32 | | 1b | u8 | `headerType` | `0x02`. |

> **AMBIGUITY [p.89 vs p.90]:** GH1 byte 26–27 text says the Extended Record Length is "record length in
> **milliseconds**", but GH2 bytes 17–20 says "**microseconds**". GH2 is the field's own definition and every other
> Rev 3 time is in µs, so prefer µs. See §8 Q1.

> **AMBIGUITY [p.90]:** GH2 bytes 6–8 says "use these **two** bytes", but the field is 3 bytes (6,7,8). Treat it as u24.

### 3.3 General Header Block #3 (timestamp and size) [p.91–92]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `timeZero` | SEG-D timestamp of record time zero, µs accuracy. Matches GH1 bytes 11–16. 0 if absolute time is unknown (then all times are relative). Must be 0 if byte 30 = 1. |
| 9–16 | | 8b | u64 | `recordSize` | Total record size in bytes. 0 = unknown (e.g. GT = `FFFFFFFF`). If there is no trailer, it equals `dataSize`. |
| 17–24 | | 8b | u64 | `dataSize` | Headers + trace data in bytes (= offset of the trailer from record start). |
| 25–28 | | 4b | u32 | `headerSize` | All headers (general, scan type/skew, extended, external) in bytes (= offset of the first trace). |
| 29 | | 1b | u8 | `extendedRecordingMode` | 1 = ERM, 0 = normal. |
| 30 | | 1b | u8 | `relativeTimeMode` | 1 = no absolute timestamps (TZ must be 0, all times relative to record start), 0 = normal. |
| 31 | | 1b | u8 | `undefined31` | Any value. |
| 32 | | 1b | u8 | `headerType` | `0x03`. |

### 3.4 General Header Blocks #4–#8 (optional, ASCII) [p.92–94]
All text is left-justified and padded with space (`0x20`).

| Block | Bytes | Len | Enc | Field | Meaning | Byte 32 type |
|---|---|---|---|---|---|---|
| #4 Vessel/Crew | 1–3 | 3b | ascii | `vesselCrewAbbrev` | May be blank. | `0x10` |
| | 4–31 | 28b | ascii | `vesselCrewName` | Unique within the enterprise. | |
| #5 Survey Area | 1–31 | 31b | ascii | `surveyAreaName` | | `0x11` |
| #6 Client | 1–31 | 31b | ascii | `clientId` | | `0x12` |
| #7 Job | 1–5 | 5b | ascii | `jobAbbrev` | May be blank. | `0x13` |
| | 6–31 | 26b | ascii | `jobId` | | |
| #8 Line | 1–7 | 7b | ascii | `lineAbbrev` | Pre-plot line, without sequence/type info. | `0x14` |
| | 8–31 | 24b | ascii | `lineId` | Should match GH2 bytes 21–22. | |

### 3.5 Source Description Blocks (optional) [p.94–105]
Placement: general header and/or trace headers (e.g. source aux traces). They may be replicated. Each source event in the record needs
its own block. If the event is not at record time zero, an **Additional Source Info** block (§3.6) must follow each source
block. Source Aux Channel Reference blocks (§3.7) and Position blocks (§3.9) may follow. Index fields use 0 = not set.

Common layout (all six types):

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–3 | | 3b | u24 | `extFileNumber` | Must equal the file number (GH1 bytes 1–2 or GH2 bytes 1–3). |
| 4–8 | | 5b | fixedpt | `sourceLineNumber` | `i24.u16`: the i40 formed by bytes 4–8 = 65536 × line number (spec splits it as 4–6 integer, 7–8 fraction). |
| 9–13 | | 5b | fixedpt | `sourcePointNumber` | `i24.u16`, same rule (9–11 integer, 12–13 fraction). |
| 14 | | 1b | u8 | `sourcePointIndex` | Starts at 1 and increments on every move. 0 = not recorded. |
| 15–18 | | 4b | — | *type-specific* | See the variant table. |
| 19 | | 1b | u8 | `sourceId` | Unique per survey. 0 = unknown (same as source set). |
| 20 | | 1b | u8 | `sourceSetNumber` | 0 = not part of a set. |
| 21 | | 1b | u8 | `reshootIndex` | 0 = first recording. |
| 22 | | 1b | u8 | `groupIndex` | 0 = not part of a group (stack fold / sweep # / HFVS phase index). |
| 23 | | 1b | u8 | `depthIndex` | **0 not allowed.** |
| 24–25 | | 2b | i16 | `offsetCrossline` | cm. `0x8000` (−32768) = unknown. |
| 26–27 | | 2b | i16 | `offsetInline` | cm. `0x8000` = unknown. |
| 28–29 | | 2b | — | *type-specific* | See the variant table. |
| 30–31 | | 2b | i16 | `offsetDepth` | cm, positive **up**. `0x8000` = unknown. |
| 32 | | 1b | u8 | `headerType` | `0x15` Vibrator, `0x16` Explosive, `0x17` Airgun, `0x18` Watergun, `0x19` Electromagnetic, `0x1F` Other. |

Type-specific bytes:

| Type (byte 32) | Bytes | Len | Enc | Field | Meaning |
|---|---|---|---|---|---|
| Vibrator `0x15` [p.95–96] | 15 | 1b | u8 | `phaseControl` | §4.5. |
| | 16 | 1b | u8 | `vibratorType` | §4.6. |
| | 17–18 | 2b | i16 | `phaseAngle` | Degrees. 0 when phaseControl = 0. |
| | 28–29 | 2b | **u16** | `size` | Total peak force, unit 100 lbf. 0 = unknown. |
| Explosive `0x16` [p.97–98] | 15–16 | 2b | u16 | `depth` | Nominal shot depth, cm. 0 = unknown. |
| | 17 | 1b | u8 | `chargeLength` | dm. 0 = unknown. |
| | 18 | 1b | u8 | `soilType` | §4.7. |
| | 28–29 | 2b | i16 | `size` | Charge, grams. 0 = unknown. |
| Airgun `0x17` [p.99–100] | 15–16 | 2b | u16 | `depth` | cm below the water surface (0–655.35 m). 0 = unknown. |
| | 17–18 | 2b | u16 | `airPressure` | PSI. 0 = unknown. |
| | 28–29 | 2b | i16 | `size` | Total volume, in³. 0 = unknown. |
| Watergun `0x18` [p.100–101] | 15–16 | 2b | u16 | `depth` | cm. 0 = unknown. |
| | 17–18 | 2b | u16 | `airPressure` | PSI. 0 = unknown. |
| | 28–29 | 2b | i16 | `size` | Total volume, in³. 0 = unknown. |
| Electromagnetic `0x19` [p.102–103] | 15 | 1b | u8 | `emSourceType` | §4.8. |
| | 16–18 | 3b | u24 | `sourceMoment` | A·m (dipole) or A·m² (coil). 0 = unknown. |
| | 28–29 | 2b | u16 | `currentOrVoltage` | A or V depending on type. 0 = unknown. |
| Other `0x1F` [p.104–105] | 15–18 | 4b | u32 | `unused15` | Any value. |
| | 28–29 | 2b | u16 | `unused28` | Any value. |

### 3.6 Additional Source Info (optional; follows a Source Description block) [p.105]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `time` | SEG-D timestamp of the source event. 0 = at record time zero (GH3 bytes 1–8). |
| 9 | | 1b | u8 | `sourceStatus` | §4.9. |
| 10 | | 1b | u8 | `sourceId` | Links this block to its source block. |
| 11 | | 1b | u8 | `sourceMoving` | 1 = moving, 0 = stationary. |
| 12–31 | | 20b | ascii | `errorDescription` | Free text, e.g. "OK", space padded. |
| 32 | | 1b | u8 | `headerType` | `0x20`. |

### 3.7 Source Auxiliary Channel Reference (optional; follows a Source Description block) [p.106]
Multiple blocks per source are allowed. A channel slot with ST, CS and TN all 0 (and Source Id 0) = "no channel referenced".

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 1b | u8 | `sourceId` | |
| 2 | | 2n | bcd | `ch1ScanType` | 1–99. |
| 3–4 | | 2b | u16 | `ch1ChannelSet` | |
| 5–7 | | 3b | u24 | `ch1TraceNumber` | |
| 8 | | 2n | bcd | `ch2ScanType` | |
| 9–10 | | 2b | u16 | `ch2ChannelSet` | |
| 11–13 | | 3b | u24 | `ch2TraceNumber` | |
| 14 | | 2n | bcd | `ch3ScanType` | |
| 15–16 | | 2b | u16 | `ch3ChannelSet` | |
| 17–19 | | 3b | u24 | `ch3TraceNumber` | |
| 20 | | 2n | bcd | `ch4ScanType` | |
| 21–22 | | 2b | u16 | `ch4ChannelSet` | |
| 23–25 | | 3b | u24 | `ch4TraceNumber` | |
| 26 | | 2n | bcd | `ch5ScanType` | |
| 27–28 | | 2b | u16 | `ch5ChannelSet` | |
| 29–31 | | 3b | u24 | `ch5TraceNumber` | |
| 32 | | 1b | u8 | `headerType` | `0x21`. |

(Model it as `array[5, (scanType, channelSet, traceNumber)]` at offset 1 + 6·k.)

### 3.8 Coordinate Reference System Identification (conditional) [p.107]
**Mandatory if any Position block is present.** The full CRS text (all Appendix D stanzas, including transformation
stanzas) is concatenated, split into 31-byte chunks, and stored in **consecutive** CRS blocks in the general header. Stanzas
should be separated by `\n` (0x0A) or `\r\n`.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–31 | | 31b | ascii | `crsChunk` | Left-justified, space-padded (last chunk). |
| 32 | | 1b | u8 | `headerType` | `0x55`. |

### 3.9 Position Block (optional; 96 bytes = 3 × 32) [p.107–110]
A position block describes the block it **follows** (source description → source position; demux trace header → trace
position; measurement → measurement position). Other blocks may sit in between. Infinity sentinel = `f32`
`0x7F800000` / `f64` `0x7FF0000000000000` (the spec says exponent all ones and mantissa zero, with no sign; accept ±∞).

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `timeOfPosition` | SEG-D timestamp the position applies to (sample time). |
| 9–16 | | 8b | i64 | `timeOfMeasurement` | SEG-D timestamp when it was measured/calculated. |
| 17–20 | | 4b | f32 | `verticalError` | 95% estimate, vertical units. 0 if horizontal-only CRS; +∞ = n/a. |
| 21–24 | | 4b | f32 | `horizErrSemiMajor` | 95% ellipse semi-major, horizontal units. 0 if vertical-only; +∞ = n/a. |
| 25–28 | | 4b | f32 | `horizErrSemiMinor` | Same rules. |
| 29–30 | | 2b | u16 | `horizErrBearing` | 0.01° from grid north. 0 if vertical-only; `FFFF` = n/a. HEA/HEB/HEO are all valid or all n/a. |
| 31 | | 1b | u8 | `positionType` | §4.10. |
| 32 | | 1b | u8 | `headerType1` | `0x50`. |
| 33–40 | | 8b | f64 | `t1Coord1` | Units per CRS stanza ID1. +∞ if the CRS is 1-D (vertical). |
| 41–48 | | 8b | f64 | `t1Coord2` | +∞ if the CRS is 1-D. |
| 49–56 | | 8b | f64 | `t1Coord3` | +∞ if the CRS is 2-D (projected / geographic2D). |
| 57–58 | | 2b | u16 | `t1StanzaId` | Location Data Stanza ID (Appendix D). 0 = unknown. |
| 59 | | 1b | u8 | `t1Valid` | 1 = valid, 0 = not. |
| 60 | | 1b | u8 | `t1Quality` | §4.11. Always filled. |
| 61–63 | | 3b | u24 | `undefined61` | |
| 64 | | 1b | u8 | `headerType2` | `0x51`. |
| 65–72 | | 8b | f64 | `t2Coord1` | Tuple 2, units per ID2. Same ∞ rules. |
| 73–80 | | 8b | f64 | `t2Coord2` | |
| 81–88 | | 8b | f64 | `t2Coord3` | |
| 89–90 | | 2b | u16 | `t2StanzaId` | 0 = unknown. |
| 91 | | 1b | u8 | `t2Valid` | |
| 92 | | 1b | u8 | `t2Quality` | §4.11 (0 = tuple 2 not present). |
| 93–95 | | 3b | u24 | `undefined93` | |
| 96 | | 1b | u8 | `headerType3` | `0x52`. |

### 3.10 Relative Position Block (optional) [p.110]
Follows **directly** after the 96-byte position block it is relative to. There may be several (e.g. the front and tail of a source).
Offsets are in projected/grid terms only.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–4 | | 4b | f32 | `offsetEasting` | Projected CRS units. Not necessarily coordinate 1. |
| 5–8 | | 4b | f32 | `offsetNorthing` | |
| 9–12 | | 4b | f32 | `offsetVertical` | Vertical CRS units. The sign convention (height/depth) comes from the CRS. |
| 13–31 | | 19b | ascii | `description` | Space padded. |
| 32 | | 1b | u8 | `headerType` | `0x56`. |

### 3.11 Scan Type Header / Channel Set Descriptor (96 bytes = 3 × 32) [p.111–115]
A scan type header = `CS` channel set descriptors (96 bytes each) followed by `SK` skew blocks of 32 bytes. There are 1–65535
descriptors per scan type, and **every scan type has the same number**. Dummy descriptors have 0 channels.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 2n | bcd | `scanTypeNumber` | 1–99. 1…GH1 byte 28. Repeated in each descriptor of the scan type. |
| 2–3 | | 2b | u16 | `channelSetNumber` | 1–65535. 1…CS (GH1 byte 29 / GH2 bytes 4–5). |
| 4 | | 1b | u8 | `channelType` | §4.12. |
| 5–8 | | 4b | i32 | `startTime` | TF, µs. Must be 0 in ERM, and 0 when a Timestamp header gives the trace start. |
| 9–12 | | 4b | i32 | `endTime` | TE, µs. Same rules. TE = TF + NS × SR. |
| 13–16 | | 4b | u32 | `samplesPerTrace` | NS. |
| 17–20 | | 4b | f32 | `descaleMultiplier` | Multiply the samples by this to get input mV. |
| 21–23 | | 3b | u24 | `channelCount` | 0–16,777,215 (0 = dummy). |
| 24–26 | | 3b | u24 | `samplingInterval` | SR, µs. |
| 27 | | 1b | u8 | `arrayForming` | §4.13. |
| 28 | | 1b | u8 | `traceHeaderExtensions` | THE, 1–255 (**0 not allowed**). Must equal demux trace header byte 10. |
| 29 | 29H | 4 bits | bits | `extendedHeaderFlag` | 1 = the Extended Header has extra info for this channel set. |
| 29 | 29L | 4 bits | bits | `gainControlMethod` | §4.14. |
| 30 | | 1b | u8 | `verticalStack` | 0 = trace intentionally zeroed, 1 = no stack, n = effective stack order. |
| 31 | | 1b | u8 | `streamerCable` | 1 = starboard-most … N = port-most. 0 = not recorded. |
| 32 | | 1b | u8 | `headerType1` | `0x30`. |
| 33–36 | | 4b | f32 | `aliasFilterFreq` | Hz. |
| 37–40 | | 4b | f32 | `lowCutFilterFreq` | Hz. |
| 41–44 | | 4b | f32 | `aliasFilterSlope` | dB/octave. 0 = filter out (§6.9). |
| 45–48 | | 4b | f32 | `lowCutFilterSlope` | dB/octave. 0 = filter out. |
| 49–52 | | 4b | f32 | `notch1Freq` | Hz. 0.0 = out. |
| 53–56 | | 4b | f32 | `notch2Freq` | |
| 57–60 | | 4b | f32 | `notch3Freq` | |
| 61 | | 1b | u8 | `filterPhase` | §4.15. |
| 62 | | 1b | u8 | `physicalUnit` | §4.16. |
| 63 | | 1b | u8 | `undefined63` | |
| 64 | | 1b | u8 | `headerType2` | `0x31`. |
| 65–68 | | 4b | u32 | `filterDelay` | µs. |
| 69–95 | | 27b | ascii | `description` | Space padded. **`0x00` not allowed.** |
| 96 | | 1b | u8 | `headerType3` | `0x32`. |

Skew blocks: SK × 32 bytes after the last descriptor of each scan type. Their content is legacy (E.2). Rev 3 has no samples per
scan (§6.10).

### 3.12 Demux Trace Header (20 bytes) [p.115–116]
No header-type byte. It is followed by THE × 32-byte trace header extensions, the first being THE#1 (`0x40`).

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–2 | | 4n | bcd | `fileNumber` | `FFFF` → bytes 18–20. |
| 3 | | 2n | bcd | `scanTypeNumber` | 1–99. |
| 4 | | 2n | bcd | `channelSetNumber` | 1–99. `FF` → bytes 16–17 (also used for a binary channel set number). |
| 5–6 | | 4n | bcd | `traceNumber` | 1–9999. `FFFF` → THE#1 bytes 22–24. |
| 7–9 | | 3b | fixedpt | `firstTimingWord` | `i16.u8` (signed, 2 integer bytes + 1 fraction byte). Units ms, LSB 1/256 ms (E.11). The exact sample time = this + skew. |
| 10 | | 1b | u8 | `traceHeaderExtensions` | THE, 1–255, ≥1. Same for every trace in a channel set, and equal to CSD byte 28. |
| 11 | | 1b | fixedpt | `sampleSkew` | `u0.8`: fraction of the channel-set SR (skew = v/256 × SR). |
| 12 | | 1b | u8 | `traceEdit` | §4.17. |
| 13–15 | | 3b | fixedpt | `timeBreakWindow` | `u16.u8` timing word of the scan in which TWI went to 1. |
| 16–17 | | 2b | u16 | `extChannelSetNumber` | Used when byte 4 = `FF`. |
| 18–20 | | 3b | u24 | `extFileNumber` | Used when bytes 1–2 = `FFFF`. |

> **AMBIGUITY [p.115–116]:** §8.17 gives no unit for bytes 7–9 and 13–15. Only the E.11 example table [p.181] labels the
> First Timing Word "(1/256 ms)" and the sample skew "(1/256 of the sampling interval)".

### 3.13 Trace Header Extension #1 (mandatory, first extension) [p.116–118]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–3 | | 3b | i24 | `receiverLineNumber` | `FFFFFF` → use bytes 11–15. |
| 4–6 | | 3b | i24 | `receiverPointNumber` | `FFFFFF` → use bytes 16–20. |
| 7 | | 1b | i8 | `receiverPointIndex` | Initial 1, +1 per move. May be 0 when it extends the depth-index range (VSP). Spec says *signed*. |
| 8 | | 1b | u8 | `reshootIndex` | 0 = first. |
| 9 | | 1b | u8 | `groupIndex` | 0 = none. 3C: 1 = X, 2 = Y, 3 = Z (§3.19). |
| 10 | | 1b | u8 | `depthIndex` | 0 not allowed. 1 = shallowest, increasing downward. |
| 11–15 | | 5b | fixedpt | `extReceiverLineNumber` | `i24.u16`: i40 = 65536 × value. Valid only if bytes 1–3 = `FFFFFF`. |
| 16–20 | | 5b | fixedpt | `extReceiverPointNumber` | `i24.u16`. Valid only if bytes 4–6 = `FFFFFF`. |
| 21 | | 1b | u8 | `sensorType` | §4.18. |
| 22–24 | | 3b | u24 | `extTraceNumber` | Valid only if demux bytes 5–6 = `FFFF`. |
| 25–28 | | 4b | u32 | `samplesPerTrace` | Must equal CSD bytes 13–16. |
| 29 | | 1b | u8 | `sensorMoving` | 1 = moving, 0 = stationary. |
| 30 | | 1b | u8 | `undefined30` | |
| 31 | | 1b | u8 | `physicalUnit` | Same codes as CSD byte 62 (§4.16). |
| 32 | | 1b | u8 | `headerType` | `0x40`. |

> **AMBIGUITY [p.117]:** the `FFFFFF` sentinel in bytes 1–3 / 4–6 of a field declared *signed* is −1 as i24. So a
> receiver line/point of −1 cannot be stored in the short field. Compare the raw bytes, not the decoded value.

### 3.14 Sensor Info Header Extension (optional) [p.118]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `equipmentTestTime` | SEG-D timestamp. 0 = not recorded. |
| 9–12 | | 4b | f32 | `sensorSensitivity` | STY. physical = sample / STY (unit per THE#1 byte 31). 0 = unknown. |
| 13 | | 1b | u8 | `equipmentTestResult` | 0 unknown/untested, 1 passed, 2 failed, 3 uncertain (warning). |
| 14–31 | | 18b | ascii | `sensorSerial` | Space padded. |
| 32 | | 1b | u8 | `headerType` | `0x41`. |

### 3.15 Timestamp Header (optional) [p.119]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `timeZero` | Time of the first sample of the described data. Actual sample time = this + sample skew + first timing word. If absolute time is unknown, it is relative to GH3 TZ (µs since record time zero). |
| 9–31 | | 23b | — | `undefined9` | |
| 32 | | 1b | u8 | `headerType` | `0x42`. |

### 3.16 Sensor Calibration Header (optional, repeatable) [p.119–120]
Two (f, A, φ) points per block. Use several blocks for one calibration curve (max ≈ 500 points, limited by the trace header size).

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–4 | | 4b | f32 | `freq1` | 0.0 = unused. |
| 5–8 | | 4b | f32 | `amp1` | |
| 9–12 | | 4b | f32 | `phase1` | |
| 13–16 | | 4b | f32 | `freq2` | 0.0 = unused. |
| 17–20 | | 4b | f32 | `amp2` | |
| 21–24 | | 4b | f32 | `phase2` | |
| 25 | | 1b | u8 | `calibrationApplied` | 1 = trace already corrected. |
| 26–31 | | 6b | — | `undefined26` | |
| 32 | | 1b | u8 | `headerType` | `0x43`. |

### 3.17 Time Drift Header (optional) [p.120–121]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `timeOfDeployment` | SEG-D timestamp. |
| 9–16 | | 8b | i64 | `timeOfRetrieval` | SEG-D timestamp. |
| 17–20 | | 4b | i32 | `offsetAtDeployment` | µs. |
| 21–24 | | 4b | i32 | `offsetAtRetrieval` | µs. |
| 25 | | 1b | u8 | `timeDriftCorrected` | 1 = corrected. Data must be corrected before records are merged. |
| 26 | | 1b | u8 | `correctionMethod` | 0x00 uncorrected, 0x01 linear (values in this header), 0xFF other/manufacturer. |
| 27–31 | | 5b | — | `undefined27` | |
| 32 | | 1b | u8 | `headerType` | `0x44`. |

### 3.18 Electromagnetic Src/Recv Desc Block (optional) [p.124–125]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–3 | | 3b | u24 | `dimX` | Equipment length inline, cm. |
| 4–6 | | 3b | u24 | `dimY` | Crossline, cm. |
| 7–9 | | 3b | u24 | `dimZ` | Height, cm. |
| 10 | | 1b | bits | `positiveTerminal` | bit0 = X, bit1 = Y, bit2 = Z: 1 = the positive end is the positive terminal. Example: 15 m inline antenna, + at the + end → X=`0x0005DC`, PT=`0x01`. Diagonal antenna with + at −X/+Y → X=Y=`0x0006E8`, PT=`0x02`. |
| 11–13 | | 3b | i24 | `offsetX` | cm from the equipment center. |
| 14–16 | | 3b | i24 | `offsetY` | cm. |
| 17–19 | | 3b | i24 | `offsetZ` | cm. |
| 20–31 | | 12b | — | `undefined20` | |
| 32 | | 1b | u8 | `headerType` | `0x45`. |

### 3.19 Orientation Header (optional) [p.121–123]
X = inline (along the cable), Y = crossline, Z = vertical, positive **down**, right-hand rule. RX/RY/RZ are rotations about X/Y/Z.
`[C_north, C_east, C_vertical]ᵀ = R(3×3) · [C_x, C_y, C_z]ᵀ` (eq. 1). Group index for 3C traces: 1 = X, 2 = Y, 3 = Z.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–4 | | 4b | f32 | `rotX` | rad. |
| 5–8 | | 4b | f32 | `rotY` | rad. |
| 9–12 | | 4b | f32 | `rotZ` | rad. Referenced to the system in byte 25. |
| 13–16 | | 4b | f32 | `referenceOrientation` | rad, rotation about Z so that X points to true north. 0 if n/a or unknown. |
| 17–24 | | 8b | i64 | `timestamp` | Sample time the rotation applies to. 0 = the first sample. |
| 25 | | 1b | u8 | `orientationType` | §4.19. |
| 26 | | 1b | u8 | `referenceOrientationValid` | 1 = bytes 13–16 are valid. |
| 27 | | 1b | u8 | `rotationApplied` | 1 = rotation (bytes 1–12) is already applied to the samples. |
| 28 | | 1b | u8 | `rotationToNorthApplied` | 1 = already rotated to true north. If 1, byte 27 must be 1. |
| 29–31 | | 3b | — | `undefined29` | |
| 32 | | 1b | u8 | `headerType` | `0x60`. |

### 3.20 Measurement Block (optional; may be followed by a Position block) [p.123–124]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1–8 | | 8b | i64 | `timestamp` | For time measurements relative to the record start (e.g. uphole), use GH3 TZ. |
| 9–12 | | 4b | f32 | `value` | NaN `0x7FFFFFFF` = undefined. |
| 13–16 | | 4b | f32 | `maxValue` | NaN = undefined. |
| 17–20 | | 4b | f32 | `minValue` | NaN = undefined. |
| 21–22 | | 2b | u16 | `quantityClass` | Energistics QC code (§4.23), e.g. 1069 = length. |
| 23–24 | | 2b | u16 | `unitOfMeasure` | Energistics UoM code (§4.23), e.g. 2066 = m. |
| 25–26 | | 2b | u16 | `measurementDescription` | SEG Measurement Description code (external table, not in the spec), e.g. `0x0502` = "Equipment height". |
| 27–31 | | 5b | — | `undefined27` | |
| 32 | | 1b | u8 | `headerType` | `0x61`. |

### 3.21 General Trailer and General Trailer Description Block [p.125–127]
Trailer = a sequence of `[GTDB 32 B][data SI × 32 B]` units. Binary data is padded with `0x00` and ASCII with `0x20` up to a 32-byte boundary.
Content is recorder defined. All trailer types are optional.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 1b | u8 | `blockType` | §4.21. |
| 2 | | 1b | u8 | `dataEncoding` | 0x01 binary, 0x02 ASCII. |
| 3–4 | | 2b | u16 | `undefined3` | Set to 0. |
| 5–8 | | 4b | u32 | `blockSize` | SI = number of 32-byte blocks of data **in this data block**. Bytes = 32 × SI. |
| 9–24 | | 16b | ascii | `description` | Required for user types 0xA0–0xFF. Space padded. |
| 25–31 | | 7b | — | `undefined25` | Set to 0. |
| 32 | | 1b | u8 | `headerType` | `0x70`. |

> **AMBIGUITY [p.126]:** the summary table lists "Undefined (zero-filled) **6** bytes, 25–31", but 25–31 is 7 bytes. The
> INDEX table confirms 25–31. Use 7.

## 4. Code tables

### 4.1 Header block type (byte 32) — every value defined in §8
Cross-check against Table 2 in part A.

| Type | Block | Where | Size |
|---|---|---|---|
| — | General Header #1 | GH | 32 (no type byte) |
| 0x02 | General Header #2 | GH | 32 |
| 0x03 | General Header #3 | GH | 32 |
| 0x10 | GH #4 Vessel/Crew | GH | 32 |
| 0x11 | GH #5 Survey Area | GH | 32 |
| 0x12 | GH #6 Client | GH | 32 |
| 0x13 | GH #7 Job | GH | 32 |
| 0x14 | GH #8 Line | GH | 32 |
| 0x15 | Source: Vibrator | GH / TH | 32 |
| 0x16 | Source: Explosive | GH / TH | 32 |
| 0x17 | Source: Airgun | GH / TH | 32 |
| 0x18 | Source: Watergun | GH / TH | 32 |
| 0x19 | Source: Electromagnetic | GH / TH | 32 |
| 0x1F | Source: Other | GH / TH | 32 |
| 0x20 | Additional Source Info | GH / TH | 32 |
| 0x21 | Source Aux Channel Reference | GH / TH | 32 |
| 0x30/0x31/0x32 | Channel Set Descriptor blocks 1/2/3 | Scan type header | 96 |
| 0x40 | Trace Header Extension #1 | TH | 32 |
| 0x41 | Sensor Info Header Ext | TH | 32 |
| 0x42 | Timestamp Header | TH | 32 |
| 0x43 | Sensor Calibration | TH | 32 |
| 0x44 | Time Drift | TH | 32 |
| 0x45 | EM Src/Recv Desc | TH (likely) | 32 |
| 0x50/0x51/0x52 | Position Block 1/2/3 | GH / TH | 96 |
| 0x55 | CRS Identification | GH | 32 |
| 0x56 | Relative Position | GH / TH | 32 |
| 0x60 | Orientation | TH | 32 |
| 0x61 | Measurement | GH / TH | 32 |
| 0x70 | General Trailer Description | Trailer | 32 |

GH = general header, TH = trace header extension area. §8 does not restrict where blocks may go beyond the notes above; part A Table 2 is authoritative.

### 4.2 Format code (GH1 bytes 3–4, BCD) [p.87]
| Code | Meaning |
|---|---|
| 8015 | 20-bit binary |
| 8022 | 8-bit quaternary |
| 8024 | 16-bit quaternary |
| 8036 | 24-bit two's complement integer |
| 8038 | 32-bit two's complement integer |
| 8042 | 8-bit hexadecimal |
| 8044 | 16-bit hexadecimal |
| 8048 | 32-bit hexadecimal |
| 8058 | 32-bit IEEE |
| 8080 | 64-bit IEEE |
| 0200, 0000 | Illegal |

The bit layouts are in part A.

### 4.3 Polarity (GH1 byte 24 high nibble) [p.88]
| 0 untested | 1 0° | 2 45° | 3 90° | 4 135° | 5 180° | 6 225° | 7 270° | 8 315° | C unassigned |
|---|---|---|---|---|---|---|---|---|---|

> **AMBIGUITY [p.88]:** only `C` is listed as "unassigned". The values 9–B and D–F are not mentioned. Treat them as unassigned too.

### 4.4 Record type (GH1 byte 26 high nibble) [p.88]
| 0x2 Test record | 0x4 Parallel channel test | 0x6 Direct channel test | 0x8 Normal record | 0x1 Other |
|---|---|---|---|---|

### 4.5 Vibrator phase control (byte 15) [p.95]
0x00 not recorded (phase angle undefined) · 0x01 baseplate accelerometer · 0x02 reaction mass · 0x03 weighted sum ·
0x04 direct force measurement.

### 4.6 Vibrator type (byte 16) [p.95]
0x00 not recorded · 0x01 P-wave · 0x02 shear-wave · 0x03 marine.

### 4.7 Soil type (explosive byte 18) [p.97]
| 00 Water | 01 Alluvium | 02 Dry sand | 03 Weathering | 04 Mud | 05 Glacial | 06 Shale | 07 Sand |
|---|---|---|---|---|---|---|---|
| **08 Sandstone** | **09 Limestone** | **0A Granite** | **0B Chalk** | **0C Gypsum** | **0D Salt** | **0E Gabbro** | **FF Other** |

### 4.8 EM source type (EM source byte 15) [p.102]
0x00 unknown · 0x01 dipole · 0x02 loop coil · 0x03 airborne · 0x04 open loop · 0x05 closed loop · 0x0F other.

### 4.9 Source status (Additional Source Info byte 9) [p.105]
0x00 untested/unknown · 0x01 fired OK · 0x12 timing error · 0x13 mechanical failure · 0x14 software error ·
0x15 hydraulics failure · 0x16 air leakage · 0x17 power failure · 0x18 communication failure · 0xFF unknown error.

### 4.10 Position type (Position byte 31) [p.108]
0x01 planned/preplot · 0x02 measured · 0x03 processed · 0x04 final · 0x0F unknown.

### 4.11 Position quality (Position bytes 60, 92) [p.109–110]
0x00 tuple not present · 0x01 good · 0x02 uncertain · 0x03 bad, not to be used.

### 4.12 Channel type (CSD byte 4) [p.111–112]
| Code | Meaning | Code | Meaning |
|---|---|---|---|
| 0x00 | Unused | 0x94 | Source signature/measured |
| 0x10 | Seis | 0x95 | Source base plate |
| 0x11 | Electromagnetic (EM) | 0x96 | Source reference sweep |
| 0x20 | Time break | 0x97 | Source other |
| 0x21 | Clock timebreak | 0x98 | Source reference pilot |
| 0x22 | Field timebreak | 0x99 | Source mass |
| 0x30 | Up hole | 0x9A | Source excitation |
| 0x40 | Water break | 0x9B | Source valve |
| 0x50 | Time counter | 0x9C | Source overload |
| 0x60 | External data | 0xA0 | Auxiliary data trailer (no longer used) |
| 0x61 | Acoustic range measurement | 0xB0 | True reference sweep (correlation ref) |
| 0x62 | Acoustic reference measured (corr. ref) | 0xB1 | Radio reference sweep |
| 0x63 | Acoustic reference nominal (corr. ref) | 0xB2 | Radio similarity signal |
| 0x70 | Other | 0xB3 | Wireline reference sweep |
| 0x80 | Signature/unfiltered | 0xC0 | Depth |
| 0x90 | Signature/filtered | 0xC1 | Wind |
| 0x91 | Source signature/unfiltered | 0xC2 | Current |
| 0x92 | Source signature/filtered | 0xC3 | Voltage |
| 0x93 | Source signature/estimated | 0xC4 | Velocity |
| | | 0xC5 | Acceleration |
| | | 0xC6 | Pressure |
| | | 0xC7 | Tension |
| | | 0xC8 | Tilt measurement |
| | | 0xC9 | Angle measurement |
| | | 0xF0 | Calibration trace (time series) |

### 4.13 Array forming (CSD byte 27) [p.113]
0x01 no array forming · 0x0N N groups summed, no weighting (N = 2…15) · 0x1N N groups weighted, overlapping summation.
(So the high nibble is the mode (0 = plain sum, 1 = weighted) and the low nibble is N.)

### 4.14 Channel gain control method (CSD byte 29 low nibble) [p.113]
0x1 individual AGC · 0x2 ganged AGC · 0x3 fixed gain · 0x4 programmed gain · 0x8 binary gain control · 0x9 IFP gain control.

### 4.15 Filter phase (CSD byte 61) [p.114]
0x00 unknown · 0x01 minimum · 0x02 linear · 0x03 zero · 0x04 mixed · 0x05 maximum.

### 4.16 Physical unit (CSD byte 62, THE#1 byte 31) [p.114–115]
| 00 Unknown | 01 Millibar | 02 Bar | 03 mm/s | 04 m/s | 05 mm/s² | 06 m/s² | 07 Newton |
|---|---|---|---|---|---|---|---|
| **08 Kelvin** | **09 Hertz** | **0A Second** | **0B Tesla** | **0C Volt/meter** | **0D Volt·meter** | **0E Ampere/meter** | **0F Volt** |
| **10 Ampere** | **11 Radians** | **12 Pascal** | **13 Micropascal** | **14 Millimeter** | **15 Meter** | | |

### 4.17 Trace edit (demux byte 12) [p.116]
0x00 no edit · 0x01 dead channel for roll-on/roll-off, intentionally zeroed · 0x02 intentionally zeroed ·
0x03 edited (the acquisition system modified one or more samples). Other values are undefined.

### 4.18 Sensor type (THE#1 byte 21) [p.117]
| 00 Not defined | 01 Hydrophone | 02 Geophone vertical | 03 Geophone horiz. inline | 04 Geophone horiz. crossline | 05 Geophone horiz. other |
|---|---|---|---|---|---|
| **06 Accel. vertical** | **07 Accel. horiz. inline** | **08 Accel. horiz. crossline** | **09 Accel. horiz. other** | **15 Electric dipole** | **16 Magnetic coil** |

Other values are undefined.

### 4.19 Orientation type (Orientation byte 25) [p.122]
0x00 none/unknown · 0x01 earth true north · 0x02 cable direction · 0x03 sensor housing · 0x04 survey orientation ·
0x05 magnetic north · 0x09 other.

### 4.20 Manufacturer codes (GH1 byte 17, BCD) — Appendix A [p.128–132]
| Code | Name | Code | Name |
|---|---|---|---|
| 01 | Alpine Geophysical Associates (obsolete) | 34 | Syntron, Inc. |
| 02 | Applied Magnetics Corp. (see 09) | 35 | Syntron Europe Ltd. |
| 03 | Western Geophysical Exploration Products (ex Litton) | 36 | Opseis |
| 04 | SIE, Inc. (obsolete) | 39 | Grant Geophysical |
| 05 | Dyna-Tronics Mfg. (obsolete) | 40 | Geo-X |
| 06 | Electronic Instrumentation, Inc. (obsolete) | 41 | PGS Inc. |
| 07 | Halliburton Geophysical Services (ex Electro-Technical Labs / Geosource) | 42 | SeaMap UK Ltd. |
| 08 | Fortune Electronics (obsolete) | 43 | Hydroscience Technologies |
| 09 | Geo Space Corporation | 44 | JSC "Special Design Bureau for Seismic Instrumentation" (Saratov) |
| 10 | Leach Corporation (obsolete) | 45 | Fugro |
| 11 | Metrix Instrument Co. (obsolete) | 46 | ProFocus Systems AS |
| 12 | Redcor Corporation (obsolete) | 47 | Optoplan AS |
| 13 | Sercel | 48 | Wireless Seismic Inc. |
| 14 | Scientific Data Systems (obsolete) | 49 | AutoSeis |
| 15 | Texas Instruments | 50 | INOVA Geophysical |
| 17 | GUS Manufacturing | 51 | Verif-i Ltd. |
| 18 | Input/Output, Inc. | 52 | Troika International |
| 19 | Geco-Prakla (Transition Zone; ex Terra Marine) | 53 | MagSeis AS |
| 20 | Fairfield Industries | 54 | Seismic Instruments, Inc. |
| 22 | Geco-Prakla (Gatwick, UK) | 55 | TGS |
| 31 | Japex Geoscience Institute | 56 | Hewlett Packard Co. |
| 32 | Halliburton Geophysical Services | 57 | Modern Seismic Technology, LLC |
| 33 | Compuseis, Inc. | | |

Codes not listed (16, 21, 23–30, 37, 38, 58+) are unassigned.

### 4.21 General Trailer block type (GTDB byte 1) [p.126]
0x01 edits (SEG-D Trace Edit v1.0, grammar in part A) · 0x10 text comments · 0x11 observer log · 0x20 P1 processed nav ·
0x21 P2 raw marine positioning · 0x22 P3 land survey field data · 0x23 P5 pipeline positioning · 0x24 P6 3D binning grids ·
0x25 P7 well deviation · 0x26 SPS · 0x27 SEG-Y Extended Textual Stanza · 0xA0–0xFF other/user defined (description required).

### 4.22 API / Energistics producer organization codes — Appendix C [p.135–138]
Used by the storage unit (tape) label "producer organization code" field (part A). The table is dated 5 Oct 2011.
0 Subcommittee on Recommended Format for Digital Well Data, Basic Schema · 1 Operator · 2 Driller · 3 Mud Logger ·
9 Amerada Hess · 10 Analysts, The · 15 Baker Hughes Inteq · 20 Baroid · 30 Birdwell · 40 Reeves (ex BPB) · 50 Brett Exploration ·
58 Canrig · 60 Cardinal · 65 Center Line Data · 66 Subcommittee …, DLIS Schema · 70 Century Geophysical · 77 CGG Logging ·
80 Charlene Well Surveying · 90 Compagnie de Services Numerique · 95 Comprobe · 100 Computer Data Processors · 110 Computrex ·
115 COPGO Wood Group · 120 Core Laboratories · 125 CRC Wireline · 126 Crocker Data Processing · 127 Tucker Wireline Services ·
128 Datalog Technology · 130 Digigraph · 137 Tucker Technologies · 140 Digitech · 145 Deines Perforating ·
148 Drillog Petro-Dynamics · 150 Baker Atlas · 160 Earthworm Drilling · 170 Electronic Logging Co. · 180 Elgen · 190 El Toro ·
200 Empire · 205 Encom Technology · 206 Ensigh Geophysics · 208 Epoch · 210 Frontier · 215 Geolog · 217 Geoshare ·
218 GEO·X Systems · 220 G O International · 230 Gravilog · 240 Great Guns Servicing · 250 Great Lakes Petroleum Services ·
260 GTS · 268 Guardian Data Seismic · 270 Guns · 280 Halliburton Logging · 285 Horizon Production Logging · 290 Husky ·
293 INOVA Geophysical · 295 Input/Output · 300 Jetwell · 305 Landmark Graphics · 310 Lane Wells · 315 Logicom Computer Services ·
320 Magnolia · 330 McCullough Tool · 332 Mitchell Energy · 335 Paradigm Geophysical · 337 DPTS Limited · 338 NRI On-Line ·
339 Oilware · 340 Pan Geo Atlas · 342 Pathfinder Energy Services · 345 Perfco · 350 Perfojet Services ·
360 Perforating Guns of Canada · 361 Petcom · 362 Petroleum Exploration Computer Consultants · 363 Petrologic ·
366 Phillips Petroleum · 367 Phoenixdata Services · 368 PGS · 370 Petroleum Information · 380 Petrophysics · 390 Pioneer ·
392 Practical Well Log Standards Group · 395 IHS Energy Log Services · 400 Ram Guns · 410 Riley's Datashare · 418 RODE ·
420 Roke · 430 Sand Surveys · 440 Schlumberger · 450 Scientific Software · 460 Seismograph Service · 462 SEGDEF ·
463 SEG Tech. Standards High Density Media Format Subcommittee · 464 Shell Services · 465 Stratigraphic Systems ·
466 Spectrum ASA · 467 Sperry-Sun · 468 SEPTCO · 469 Sercel, Inc. · 470 Triangle · 471 Thrubit Logging ·
475 Troika International · 480 Welex · 490 Well Reconnaissance · 495 WITS · 500 Well Surveys · 510 Western · 520 Westronics ·
525 Winters Wireline · 530 Wireline Electronics · 540 Worth Well · 560 Z & S Consultants · 999 reserved for local schemas ·
1000 Energistics (ex POSC).

### 4.23 Energistics codes for the Measurement block — Appendix F [p.183–188]
Snapshot of UoM v1.0 RC (2014-03-07). The live list is maintained by Energistics. The PDF marks deprecated codes with
strikethrough, which the text extraction **loses** (see §8 Q6).

**Quantity Class (bytes 21–22), 1001–1177, in order:**
1001 (mass per time) per area · 1002 (mass per time) per length · 1003 (mass per volume) per length · 1004 (mole per time) per area ·
1005 (volume per time) length · 1006 (volume per time) per area · 1007 (volume per time) per length · 1008 (volume per time) per time ·
1009 (volume per time) per volume · 1010 absorbed dose · 1011 acceleration linear · 1012 activity (of radioactivity) ·
1013 amount of substance · 1014 angle per length · 1015 angle per volume · 1016 angular acceleration · 1017 angular velocity ·
1018 area · 1019 area per area · 1020 area per volume · 1021 attenuation · 1022 attenuation per length · 1023 capacitance ·
1024 concentration of B · 1025 conductivity · 1026 cross section absorption · 1027 current density · 1028 Darcy flow coefficient ·
1029 data transmission speed · 1030 delta temperature · 1031 diffusion coefficient · 1032 digital storage · 1033 dimensionless ·
1034 dose equivalent · 1035 dose equivalent rate · 1036 dynamic viscosity · 1037 electric charge · 1038 electric charge density ·
1039 electric charge per area · 1040 electric conductance · 1041 electric current · 1042 electric dipole moment ·
1043 electric field strength · 1044 electric potential · 1045 electric resistance · 1046 electrical resistivity ·
1047 electromagnetic moment · 1048 energy · 1049 energy length per area · 1050 energy length per time area temperature ·
1051 energy per area · 1052 energy per length · 1053 energy per volume · 1054 exposure (radioactivity) · 1055 force ·
1056 force area · 1057 force length per length · 1058 force per force · 1059 force per length · 1060 force per volume ·
1061 frequency · 1062 frequency interval · 1063 heat capacity · 1064 heat flow rate · 1065 heat transfer coefficient ·
1066 illuminance · 1067 isothermal compressibility · 1068 kinematic viscosity · 1069 length · 1070 length per length ·
1071 length per mass · 1072 length per pressure · 1073 length per temperature · 1074 length per volume ·
1075 level of power intensity · 1076 light exposure · 1077 linear thermal expansion · 1078 luminance · 1079 luminous efficacy ·
1080 luminous flux · 1081 luminous intensity · 1082 magnetic dipole moment · 1083 magnetic field strength · 1084 magnetic flux ·
1085 magnetic flux density · 1086 magnetic flux density per length · 1087 magnetic permeability · 1088 magnetic vector potential ·
1089 mass · 1090 mass attenuation coefficient · 1091 mass length · 1092 mass per area · 1093 mass per energy ·
1094 mass per length · 1095 mass per mass · 1096 mass per time · 1097 mass per volume · 1098 mobility · 1099 molar energy ·
1100 molar heat capacity · 1101 molar volume · 1102 mole per area · 1103 mole per time · 1104 moment of force ·
1105 moment of inertia · 1106 momentum · 1107 nonDarcy flow coefficient · 1108 normalized power · 1109 parachor ·
1110 per area · 1111 per electric potential · 1112 per force · 1113 per length · 1114 per mass · 1115 per pressure ·
1116 per time · 1117 per volume · 1118 permeability length · 1119 permeability rock · 1120 permeance · 1121 permittivity ·
1122 plane angle · 1123 potential difference per power drop · 1124 power · 1125 power per area · 1126 power per power ·
1127 power per volume · 1128 pressure · 1129 pressure per time · 1130 pressure squared ·
1131 pressure squared per force (time per area) · 1132 pressure time per volume · 1133 productivity index ·
1134 quantity of light · 1135 radiance · 1136 radiant intensity · 1137 reluctance · 1138 resistivity per length ·
1139 second moment of area · 1140 solid angle · 1141 specific activity (of radioactivity) · 1142 specific energy ·
1143 specific heat capacity · 1144 specific productivity index · 1145 specific volume · 1146 temperature per length ·
1147 temperature per pressure · 1148 temperature per time · 1149 thermal conductance · 1150 thermal conductivity ·
1151 thermal diffusivity · 1152 thermal insulance · 1153 thermal resistance · 1154 thermodynamic temperature · 1155 time ·
1156 time per length · 1157 time per mass · 1158 time per time · 1159 time per volume · 1160 unit productivity index ·
1161 velocity · 1162 volume · 1163 volume flow rate per volume flow rate · 1164 volume per area · 1165 volume per length ·
1166 volume per pressure · 1167 volume per rotation · 1168 volume per time · 1169 volume per volume ·
1170 volumetric heat transfer coefficient · 1171 volumetric thermal expansion · 1172 area per time · 1173 API oil gravity ·
1174 API gamma ray · 1175 API neutron · 1176 amount of substance per amount of substance · 1177 molecular weight.

**Unit symbol (bytes 23–24), 2001–2146 (p.188; the list may continue on p.189+, which is out of scope):**
2001 % (use Euc) · 2002 1/H · 2003 1/K · 2004 1/kg · 2005 1/m · 2006 1/m2 · 2007 1/m3 · 2008 1/N · 2009 1/Pa · 2010 1/s · 2011 1/V ·
2012 A · 2013 A.m2 · 2014 A/m · 2015 A/m2 · 2016 B · 2017 B.W · 2018 B/m · 2019 B/O · 2020 bit · 2021 bit/s · 2022 Bq · 2023 Bq/kg ·
2024 C · 2025 C.m · 2026 C/kg · 2027 C/m2 · 2028 C/m3 · 2029 cd · 2030 cd/m2 · 2031 F · 2032 F/m · 2033 Gy · 2034 H · 2035 H/m ·
2036 Hz · 2037 J · 2038 J/(kg.K) · 2039 J/(mol.K) · 2040 J/K · 2041 J/kg · 2042 J/m3 · 2043 J/mol · 2044 K · 2045 K.m2/W ·
2046 K/m · 2047 K/Pa · 2048 K/s · 2049 K/W · 2050 kg · 2051 kg.m · 2052 kg.m/s · 2053 kg.m2 · 2054 kg/(m2.s) · 2055 kg/J ·
2056 kg/m · 2057 kg/m2 · 2058 kg/m3 · 2059 kg/m4 · 2060 kg/s · 2061 lm · 2062 lm.s · 2063 lm/W · 2064 lx · 2065 lx.s · 2066 m ·
2067 m/K · 2068 m/kg · 2069 m/Pa · 2070 m/s · 2071 m/s2 · 2072 m2 · 2073 m2/(Pa.s) · 2074 m2/kg · 2075 m2/mol · 2076 m2/s ·
2077 m3 · 2078 m3/(Pa.s) · 2079 m3/(Pa2.s2) · 2080 m3/J · 2081 m3/kg · 2082 m3/mol · 2083 m3/Pa · 2084 m3/rad · 2085 m3/s ·
2086 m3/s2 · 2087 m4 · 2088 m4/s · 2089 mol · 2090 mol/(s.m2) · 2091 mol/m2 · 2092 mol/m3 · 2093 mol/s · 2094 N · 2095 N.m2 ·
2096 N/m · 2097 N/m3 · 2098 N4/(kg.m7) · 2099 O · 2100 ohm · 2101 ohm.m · 2102 ohm/m · 2103 Pa · 2104 Pa.s · 2105 Pa.s/m3 ·
2106 Pa.s/m6 · 2107 Pa/m3 · 2108 Pa/s · 2109 Pa2 · 2110 rad · 2111 rad/m · 2112 rad/m3 · 2113 rad/s · 2114 rad/s2 · 2115 S ·
2116 s · 2117 s/kg · 2118 S/m · 2119 s/m · 2120 s/m3 · 2121 sr · 2122 Sv · 2123 Sv/s · 2124 T · 2125 T/m · 2126 V · 2127 V/B ·
2128 V/m · 2129 W · 2130 W/(m.K) · 2131 W/(m2.K) · 2132 W/(m2.sr) · 2133 W/(m3.K) · 2134 W/K · 2135 W/m2 · 2136 W/m3 ·
2137 W/sr · 2138 Wb · 2139 Wb.m · 2140 Wb/m · 2141 deltaK · 2142 Euc · 2143 dAPI · 2144 gAPI · 2145 nAPI · 2146 kg/mol.

Treat these as opaque `u16` with an optional name lookup. Do not reject unknown codes.

## 5. Data sample formats

See `segd_rev3_0_a.md` (format codes are listed in §4.2 here). Related facts from part B:
- Physical value = sample × CSD `descaleMultiplier` → mV [p.113]. Sensor-unit value = sample / `sensorSensitivity` [p.118].
- Trace sample count NS: CSD bytes 13–16 = THE#1 bytes 25–28.

## 6. Derived rules / algorithms

### 6.1 Counts that size the header
| Quantity | Normal field | Sentinel → extended field | Size contributed |
|---|---|---|---|
| Additional general header blocks `nGH` | GH1 byte 12H (binary nibble 0–14) | `F` → GH2 23–24 (u16) | 32 × nGH (plus 32 for GH1) |
| Scan types `nST` | GH1 byte 28 (BCD 0–99) | — | |
| Channel sets / scan type `nCS` | GH1 byte 29 (BCD) | `FF` → GH2 4–5 | nST × nCS × 96 |
| Skew blocks / scan type `nSK` | GH1 byte 30 (BCD) | `FF` → GH2 9–10 | nST × nSK × 32 |
| Extended header blocks `nEC` | GH1 byte 31 (BCD) | `FF` → GH2 6–8 (u24) | 32 × nEC |
| External header blocks `nEX` | GH1 byte 32 (BCD) | `FF` → GH2 28–30 (u24) | 32 × nEX |
| Trailer blocks `nGT` | GH2 13–16 (u32) | `FFFFFFFF` = unknown | 32 × nGT |

- `headerSize` (GH3 25–28) should be `32·(1+nGH) + nST·(96·nCS + 32·nSK) + 32·nEC + 32·nEX`. Verify this against the part A ordering.
  If the computed and stored values differ, trust neither silently: report it.
- nGH counts **every** 32-byte block in the general header after GH1: GH2, GH3, GH4–8, source/aux/CRS blocks, and each
  96-byte position block as **3**. Blocks are not in a fixed order after GH3. Identify each one by byte 32 (§4.1). Multi-block
  headers are identified by their first type (0x50, 0x30) and consumed as 96 bytes.
- `dataSize` = offset of the trailer. `recordSize` = `dataSize` + 32·nGT (0 if unknown).

### 6.2 Trace size
`traceBytes = 20 + 32·THE + NS·bytesPerSample(formatCode)`. THE ≥ 1, the same for all traces of a channel set, and equal to CSD byte 28.
Inside the THE area, block #1 is THE#1 (0x40). The remaining THE−1 blocks are any TH-capable blocks (§4.1), identified by byte 32
(a position block = 3 of the THE count). Number of traces per channel set = CSD `channelCount`.

### 6.3 Extended-number resolution
| Value | Short field | Use extended when short = | Extended field |
|---|---|---|---|
| File number | GH1 1–2, demux 1–2 (BCD) | `FFFF` | GH2 1–3, demux 18–20 (u24). Source blocks 1–3 always hold it. |
| Channel set number (trace) | demux 4 (BCD) | `FF` | demux 16–17 (u16) |
| Trace number | demux 5–6 (BCD) | `FFFF` | THE#1 22–24 (u24) |
| Receiver line / point | THE#1 1–3 / 4–6 (i24) | raw `FFFFFF` | THE#1 11–15 / 16–20 (i24.u16) |
| Record length | GH1 26L–27 (BCD 3n) | `FFF` | GH2 17–20 (u32, µs — see AMBIGUITY) |
| Base scan interval | GH1 23 (u8, 1/16 ms) | `FF` | GH2 25–27 (u24 µs) |
| GH count | GH1 12H | `F` | GH2 23–24 |

The writer rule (p.87): when the short field holds the value, set the extended field to 0 or to the same value. When the value does not
fit, set the short field to all-F. Readers should accept both 0 and an equal value.

### 6.4 Time model
- Record time zero = GH3 TZ (0 if unknown, or in relative time mode).
- Channel set: TF/TE in µs relative to TZ. `TE = TF + NS·SR`. Negative TF is allowed.
- Per-trace start (when TF = TE = 0 and a Timestamp header is present) = Timestamp.timeZero + skew + first timing word.
- Sample skew = `byte11/256 · SR`.
- 1/16 ms base rate: only every second sample falls on a whole µs [p.88].
- Extended Recording Mode (GH3 29 = 1): GH1 record length = 000, GH2 ERL = 0, CSD TF = TE = 0, and every channel set (a "time
  block") carries a Timestamp header in its trace headers. Up to 65535 channel sets × 2³²−1 samples. Channel sets need not
  be contiguous in time (E.8, E.11) [p.169–182].

### 6.5 Source block grouping
- `[SourceDesc][AdditionalSourceInfo?][SourceAuxChanRef*][Position(96)?][RelativePosition*]…`. The Additional Source Info is
  required when the event time ≠ record T0 [p.94]. Link the blocks by `sourceId`.
- Source set convention (E.7) [p.167–169]: individual sources carry `sourceSetNumber = S`. The combined source has
  `sourceId = S`, `sourceSetNumber = 0`. So ids and set numbers share one 1–255 space.

### 6.6 General trailer walk
```
pos = dataSize (or the end of the last trace)
while (nGT known and consumed < nGT) or (nGT == 0xFFFFFFFF and not EOF/end of record):
  gtdb = read 32 B; assert gtdb[31] == 0x70
  data = read 32 * u32be(gtdb[4..7]) B
  consumed += 1 + SI
```
For unknown nGT, the trailer ends at the end of the record. What marks that end (file EOF on disk, tape mark, or the next record's GH1) depends on the media; see part A.

### 6.7 CRS text (Appendix D) — storage and round trip [p.107, p.139–158]
- Reassemble: concatenate bytes 1–31 of each **consecutive** 0x55 block in header order. For lossless round trip, keep the raw
  chunks (or the concatenation including trailing pad) and rewrite them byte for byte. Only trailing spaces of the final chunk are padding.
- Syntax (SEG-Y Rev 1 §6.1 extended textual stanza rules):
  - The stanza header line is `((SEG: <name> ver 3.0))`. Match the name case-insensitively; the examples use both `Location Data` and `LOCATION DATA`. Names:
    `Location Data EPSG Reference`, `Location Data`, `Location Data Coordinate Transformation EPSG Reference`,
    `Location Data Coordinate Transformation`.
  - Body lines are `keyword = value`. Keywords are case-insensitive, and spaces inside a keyword are ignored (`Line Name` ≡ `LINENAME`). The value
    runs from the first to the last non-blank character after `=`. Subfields are comma separated. `((`, `))` and `=` are not allowed in
    keywords or values.
  - Blank lines are ignored. A line whose first non-blank character is `#` is a comment. A line whose last non-blank character is `&` continues on the next line
    (drop the `&`, then concatenate).
  - Line end: SEG-Y says CRLF. §8.12 says `\n` or `\r\n` between stanzas. Accept both and preserve what you read.
- Keywords that matter for linking:
  - `Location Data Stanza ID` (1–65535) is referenced by Position block bytes 57–58 / 89–90.
  - Transformation stanzas carry `Location Data Coordinate Transformation Stanza ID` and the target `Location Data Stanza ID`.
  - A stanza over 3200 bytes may continue under further stanza IDs.
- Other keywords (for typed access only, optional): `CRS code`, `CRS name`, `Dataset version`, `CRS type`
  ∈ {projected, geographic2D, geographic3D, vertical, geocentric, compound}, datum/ellipsoid/prime-meridian/projection
  parameter n {name,value,unit code,unit name,unit conversion}, `Coordinate System axis n name`, `CS axis n orientation/unit …`,
  `Transformation type` ∈ {transformation, concatenated operation}, `Step m …`. Treat unknown keywords as opaque.
- "Sexagesimal DMS" values (e.g. `−50.0446461` = 50°04'46.461"S) appear only in stanza parameters. Header lat/long are decimal degrees.

### 6.8 SEG-D timestamp ↔ UTC (E.9) [p.170–176]
- `ts` = µs since 1980-01-06T00:00:00 **GPS** (UTC + leap seconds since 1980). Before 1980 the offset goes negative (9 s at
  1970-01-01). It is `i64`.
- utc→ts: `nd` = days since 1980-01-06 (negative before). `ts = 1e6·(nd·86400 + h·3600 + m·60 + s) + µs + 1e6·leap(nd)`.
- ts→utc: find the year from the Jan-1 table, subtract `1e6·leap(ts)` from both ts and that year's Jan-1 ts, then divide down. If
  day == 32 (leap second): 31 Dec / 30 Jun 23:59:60.
- Leap table (days since epoch → cumulative leap s): −3657→−9, −2745→−8, −2561→−7, −2196→−6, −1831→−5, −1466→−4,
  −1100→−3, −735→−2, −370→−1, −5→0, 542→1, 907→2, 1272→3, 2003→4, 2917→5, 3648→6, 4013→7, 4560→8, 4925→9, 5290→10,
  5839→11, 6386→12, 6935→13, 9492→14, 10588→15, 11865→16 (1 Jul 2012).
  Equivalent ts thresholds: e.g. 2012-07-01 = 1025136016000000, 1980-01-01 = −432000000000, 1970-01-01 = −315964809000000.
- The table stops at 2012. **Add** the 2015-07-01 (→17) and 2017-01-01 (→18) leap seconds (see §8 Q2).
- GH1 date/time (bytes 11–16) is **UTC**. GH3 TZ is GPS-based µs. They must match after conversion.

### 6.9 Filter slope definitions (E.3) [p.162]
`LS = 40 / log2(f_LCO / f40)` (≈ 12.04 / log10(…)), `AS = 60 / log2(f60 / f_ACO)` (≈ 18.06 / log10(…)) dB/octave.
These are informational (stored as f32 in CSD 41–48).

### 6.10 Legacy skew sizing (E.1/E.2; Rev 3 has no base scan) [p.161–162]
`S/S = Σ_cs C/S · 2^(s/c)` (samples per scan). `SK = ceil(S/S / 32)`. Example: 4 + 96 + 12·4 = 148 → SK = 5. This is only for storing old data.

### 6.11 Validation checklist
- GH2 byte 11 = 3 (rev 3.x). GH2/GH3 type bytes = 0x02/0x03.
- GH ≥ 2. THE ≥ 1. depthIndex ≠ 0 (sources and receivers). CSD description has no 0x00.
- Every non-GH1, non-demux 32-byte block has a known type in byte 32. Unknown type → keep it as an opaque block, don't fail.
- Position present ⇒ a CRS block is present. Position/Orientation `rotationToNorthApplied = 1` ⇒ `rotationApplied = 1`.
- HEA/HEB/HEO all valid or all n/a.

## 7. Implementation notes

- **Mixed nibble fields in GH1**: byte 12 = binary high nibble + BCD low nibble. Byte 26 = binary high nibble + 3-digit BCD
  spanning 26L–27. Byte 24 = binary high nibble. CSD byte 29 = two binary nibbles.
- **BCD vs binary**: Source Aux Chan Ref scan-type bytes and CSD byte 1 are BCD even though the neighbouring fields are binary.
- **Signedness traps**: Vibrator size is u16 but Explosive/Airgun/Watergun size is i16. THE#1 receiver point index is i8.
  Source/receiver line/point are signed fixed-point i24.u16 (5 bytes); decode as `i40 / 65536.0` (sign-extend from 40 bits).
- Offsets use the `0x8000` sentinel for unknown, not 0.
- Float sentinels: Position uses +∞ for n/a. Measurement uses the NaN bit pattern `0x7FFFFFFF` exactly. Write that exact pattern.
- ASCII fields: space padded. Preserve bytes for round trip and don't trim when re-encoding. Writers should pad with 0x20.
- "Undefined, may have any value" bytes: store raw for lossless round trip, and write zeros for new data.
- CRS blocks must be consecutive. A writer must split the text into 31-byte chunks and pad the last one with spaces.
- Glossary terms with format implications (Appendix B) [p.133–134]:
  - **Record** = header (mandatory) + traces + trailer. Header-only records are allowed.
  - **Field record** = data between two filemarks. It may hold several SEG-D records. On media without filemarks it equals one record.
  - **Tape file / EOD** = EOD is typically two consecutive filemarks (some systems write more).
  - **Scan type** = a complete set of channel sets.
  - **Channel set** = channels with identical SR/filter/gain parameters.
  - **Sample skew** = the fraction of the interval between the timing word and the actual sample time.
  - **Trace block** = one trace, or part of a trace with constant parameters.
  - **Tape record** = the unit of tape I/O; it need not align with physical blocks.
- Differences from Rev 2.x visible in part B:
  - The base scan interval is no longer a common divisor; the per-channel-set SR is authoritative.
  - The CSD is 96 bytes with µs times, a u32 NS, and f32 filters.
  - GH3 (sizes, ERM, RTM) is new.
  - The trace header extension count (THE) is ≥ 1 and is mirrored in the CSD.
  - Typed 32-byte blocks with a type byte are new.
  - The legacy byte references in E.3 (CSD bytes 15–16 / 19–20 for slopes) are from older revisions. In Rev 3 they are bytes 41–48.

## 8. Open questions

1. **Extended Record Length unit** (GH2 17–20): µs (GH2 text) or ms (GH1 text) [p.89–90]. Recommendation: µs, with a
   sanity check against max(CSD TE).
2. **Leap seconds after 2012**: E.9 tables end at 16 s (2012-07-01). The implementer must extend them (2015-07-01 → 17,
   2016-12-31/2017-01-01 → 18) and decide on a policy for future leap seconds.
3. **GT block count semantics**: does GH2 13–16 count the GTDB blocks themselves? Its wording ("number of 32 byte blocks
   to be used for General Trailers") suggests the total including descriptors. GTDB `SI` counts data blocks only [p.90, p.126].
4. **Order/placement of optional general-header blocks**: §8 says only "follows" for Additional Source Info, Aux Chan Ref,
   and Relative Position. Readers must dispatch on byte 32 and not assume an order. Cross-check with part A §5.1 / Table 2.
5. **Polarity nibble values 9–B, D–F** are undefined (only `C` is listed as unassigned) [p.88].
6. **Appendix F deprecated codes**: strikethrough is lost in the text, so deprecated vs current cannot be told apart. The unit list
   continues past p.188 (out of scope). The Measurement Description code table (bytes 25–26) is only on an external SEG wiki and is not in the spec.
7. **Appendix D ampersand code**: the text says `"&"` = "ASCII 1616". The real ASCII code is 0x26 (EBCDIC 0x50 is correct) [p.139].
   Use 0x26.
8. **Demux timing-word units**: ms integer + 1/256 ms fraction is inferred from the E.11 tables only [p.181]. §8.17 gives no unit.
9. **Receiver line/point sentinel** `FFFFFF` collides with the signed value −1 [p.117].
10. **EM Src/Recv block (0x45) location**: §8.25 does not say whether it may appear in the general header (the E.10 figure shows it in
    trace headers and an "Electromagnetic Source" block in the GH) [p.124, p.179].
11. **GTDB undefined length**: "6 bytes" vs bytes 25–31 (7) [p.126]. Use 7.
