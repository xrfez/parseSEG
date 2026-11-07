# SEG-Y Rev 0 (1975): delta on `segy_rev1.md`

Source: `SEG Spec/text/SEG-Y Rev 0.txt`, which is Barry, K. M., Cavers, D. A. and Kneale, C. W., 1975,
"Recommended standards for digital tape formats", *Geophysics* 40(2), 344-352 (the citation is printed
on [p.1]; manuscript received 7 Oct 1974). `[p.N]` = `=== PAGE N ===` marker of that file (printed
page "N of 10").

This note lists only what differs from `segy_rev1.md` (the baseline, which claims to cover Rev 0 too).
Where a table here repeats Rev 1 bytes, it does so because the Rev 0 meaning or status differs.
Section numbers follow `CONVENTIONS.md`.

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| p.1 | Introduction, general rules 1-4 (tape spec, density, number system, parity) | yes (§2, §5) |
| p.2-3 | Fig. 1 notes (preamble, postamble, IBG, EOF, PE burst), definitions 5a-h, rules 6-7 | yes (§2) |
| p.3 | Fig. 2-A caption (EBCDIC card images) | caption only; the figure is **image-only** |
| p.4 | Rules 8-10 (BOT spacing, units conventions) | yes (§3.1, §6) |
| p.5-6 | Description of the reel header and trace block; sample formats in prose | yes (§3, §5) |
| p.6 | Conclusion, acknowledgements, references | skipped |
| p.7 | Fig. 3A-D sample-format bit diagrams | **image-only**: only the captions and the LSB note survive (§5) |
| p.8 | Fig. 2-B binary header | yes (§3.2) |
| p.9-10 | Fig. 3-E trace header | yes (§3.3) |
| p.11 | empty | — |

> **AMBIGUITY [p.3, p.7]:** Fig. 2-A (the 40-card layout) and Fig. 3A-D (bit diagrams) are images. Only
> their captions were extracted. The bit layouts in §5 come from the prose on [p.5] and are cross-checked
> against Rev 1 App. E (`segy_rev1.md` §5), which reprints the same four formats.

## 2. File / tape structure

Rev 0 defines a **tape** format only. There is no disk-file rule, no tape label, no blocking and no
extended textual header.

### 2.1 Reel layout [p.2-3, Fig. 1 notes]

```
BOT marker  (NRZI: first block ≥ 3.0 in past the BOT trailing edge [p.4 rule 8];
             PE: identification burst first, see below)
Reel identification header, part 1: 3200 B EBCDIC card images   (one tape block)
IBG
Reel identification header, part 2:  400 B binary                (one tape block)
IBG
Trace data block 1: 240 B trace header + samples                (one tape block, "ungapped")
IBG
...
Trace data block M
EOF (one or more)
```

| Rule | Rev 0 | Rev 1 (`segy_rev1.md` §2) |
|---|---|---|
| Medium | 9-track ½" tape only, IBM GA 22-6862; 800 bpi NRZI or 1600 bpi PE; 6250 GCR "would apply" if adopted [p.1] | any medium resolvable to variable-length records; disk file = byte stream |
| Unit | "seismic reel" | "SEG-Y file" / data set |
| Lines per unit | **one line per reel**; long lines continue on more reels, each with its own reel header [p.5] | no restriction |
| Records | each block = one tape record; text, binary, each trace separately gapped [p.3 rule 6-7] | same on unblocked tape; App. C blocking optional |
| End | last trace block followed by one or more EOF [p.3 rule 7] | file mark semantics not specified (Q6) |
| Label | none | optional 128 B tape label (App. B) |
| Extended textual headers | none | 0..N or −1 (3505-3506) |
| Byte order | big-endian (implicit: IBM tape, MSB first; LSB in bit 7 of the last byte [p.7]) | big-endian, stated explicitly |
| Parity | 8-bit bytes, odd vertical parity [p.1 rule 4] | n/a |

Tape physical definitions [p.2-3] (only relevant for real tape drives, which handle them in hardware):
IBG = 0.6 in nominal, 0.5 in minimum of erased tape; PE preamble = 40 zero bytes + 1 all-ones byte; PE
postamble = 1 all-ones byte + 40 zero bytes; EOF = IBG + tape mark (NRZI: two bytes with ones in bits
3, 6, 7 separated by seven zero bytes; PE: 80 flux reversals at 3200 fci in bits P,0,2,5,6,7).

> **AMBIGUITY [p.2]:** note 1 says the preamble precedes "each of the 45 blocks within the reel
> identification header"; the reel header has 2 blocks. Physical-layer text, no effect on parsing.

### 2.2 Consequences for a reader of a Rev 0 disk image

- The trace length on tape is the **tape block length**. Rev 0 has no fixed-length-trace flag and does
  not say whether trace bytes 115-116 must equal binary 3221-3222. Rev 1 [p.6 of the Rev 1 text]
  says "the original standard is unclear about how these are to be used together". On a disk copy, the
  only length source is trace bytes 115-116 (marked `*` = strongly recommended, so it may be 0 or wrong).
- No extended header: the first trace starts at file byte 3601 (offset 3600).

## 3. Header tables

### 3.1 Reel identification header part 1: textual (3200 B) [p.3, p.4, p.5]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3200 | | 3200b | ebcdic | `textualHeader` | 40 card images × 80 bytes, **EBCDIC only** (ASCII from Rev 1). Free-form, left-justified; unused characters EBCDIC blank (0x40). |

| Card rule | Rev 0 | Rev 1 |
|---|---|---|
| Col 1 | "should contain the character `C`" [p.5] | required `C` |
| Assigned cards | 1-22 and 40, per Fig. 2-A (image, not extracted) | C1-C22 suggested labels (Table 1) |
| Unassigned | **cards 23-39** "for optional information" [p.3, p.5] | C23-C38 free |
| Card 39 | unassigned (optional text) | **mandatory `SEG Y REV1`** |
| Card 40 | per Fig. 2-A; Rev 1 calls `END EBCDIC` the traditional (acceptable) form | `END TEXTUAL HEADER` preferred |
| Card 7 | carries the measurement system ("specified in card image 7") [p.4 rule 9e] | C7 example label "MEASUREMENT SYSTEM" (same) |
| Encoding | EBCDIC | EBCDIC or ASCII |

> **AMBIGUITY [p.3, p.5]:** Fig. 2-A is an image; the per-card labels of Rev 0 cannot be recovered from
> this text. Rev 1 Table 1 says it keeps "the data locations for the initial 3200-byte Textual File
> Header" unchanged [Rev 1 p.4], so `segy_rev1.md` §3.1 C1-C22 is the best available proxy. Treat card
> contents as free text in either revision.

### 3.2 Reel identification header part 2: binary (400 B; file bytes 3201-3600) [p.8]

Absolute byte numbers as printed. All entries binary, right-justified [p.4 rule 9a], two's complement
[p.1 rule 3]. `*` = "strongly recommended that this information always be recorded" [p.8].

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values (Rev 0) | Δ vs Rev 1 |
|---|---|---|---|---|---|---|
| 3201-3204 | | 4b | i32 | `jobId` | Job identification number | — |
| 3205-3208 | | 4b | i32 | `lineNumber` | `*` Line number (**only one line per reel**) | Rev 1: not `*` |
| 3209-3212 | | 4b | i32 | `reelNumber` | `*` Reel number | Rev 1: not `*` |
| 3213-3214 | | 2b | i16 | `dataTracesPerEnsemble` | `*` Data traces **per record** (includes dummy and zero traces inserted to fill out the record or CDP) | Rev 1: "per ensemble", M-pre |
| 3215-3216 | | 2b | i16 | `auxTracesPerEnsemble` | `*` Auxiliary traces per record (sweep, timing, gain, sync and all other non-data traces) | Rev 1: per ensemble, M-pre |
| 3217-3218 | | 2b | i16 | `sampleInterval` | `*` µs, "for this reel of data" | Rev 1: primary trace set, M |
| 3219-3220 | | 2b | i16 | `sampleIntervalOrig` | µs, original field recording | — |
| 3221-3222 | | 2b | i16 | `samplesPerTrace` | `*` Samples per data trace, "for this reel" | Rev 1: primary set, M |
| 3223-3224 | | 2b | i16 | `samplesPerTraceOrig` | Samples per data trace, original field recording | — |
| 3225-3226 | | 2b | i16 | `formatCode` | `*` **1-4 only** (§4.1). "Auxiliary traces use the same number of bytes per sample." "Only one data sample format is permitted within each reel" [p.5] | Rev 1 adds 5, 8 |
| 3227-3228 | | 2b | i16 | `ensembleFold` | `*` **CDP fold** (expected data traces per CDP ensemble) | Rev 1: ensemble fold, R |
| 3229-3230 | | 2b | i16 | `traceSorting` | 1 as recorded, 2 CDP ensemble, 3 single fold continuous profile, 4 horizontally stacked | Rev 1 adds −1, 0, 5-9 |
| 3231-3232 | | 2b | i16 | `verticalSumCode` | 1 = no sum, 2 = two sum, …, N = N sum (N ≤ 32,767) | Rev 1 text garbled to "N = M−1 sum" (rev1 Q11); Rev 0 is unambiguous: value = fold of the sum |
| 3233-3234 | | 2b | i16 | `sweepFreqStart` | Hz | — |
| 3235-3236 | | 2b | i16 | `sweepFreqEnd` | Hz | — |
| 3237-3238 | | 2b | i16 | `sweepLength` | ms | — |
| 3239-3240 | | 2b | i16 | `sweepType` | 1 linear, 2 parabolic, 3 exponential, 4 other | — |
| 3241-3242 | | 2b | i16 | `sweepChannel` | Trace number of sweep channel | — |
| 3243-3244 | | 2b | i16 | `sweepTaperStart` | ms, taper starts at zero time | — |
| 3245-3246 | | 2b | i16 | `sweepTaperEnd` | ms, ending taper starts at sweep length − this | — |
| 3247-3248 | | 2b | i16 | `taperType` | 1 linear, 2 cos², 3 other | — |
| 3249-3250 | | 2b | i16 | `correlated` | 1 no, 2 yes | — |
| 3251-3252 | | 2b | i16 | `binaryGainRecovered` | 1 yes, 2 no | — |
| 3253-3254 | | 2b | i16 | `amplitudeRecovery` | 1 none, 2 spherical divergence, 3 AGC, 4 other | — |
| 3255-3256 | | 2b | i16 | `measurementSystem` | 1 meters, 2 feet; also in card 7; units "not mixed within a reel" [p.4 rule 9e] | Rev 1: R; Location Data stanza may override |
| 3257-3258 | | 2b | i16 | `impulsePolarity` | 1 = pressure increase / upward case movement gives **negative** number; 2 = **positive** | — |
| 3259-3260 | | 2b | i16 | `vibratoryPolarity` | 1-8, seismic lags pilot by 337.5°-22.5° … 292.5°-337.5° (45° bins) | — |
| 3261-3600 | | **340b** | — | `unassigned` | **Unassigned, for optional information** | Rev 1 defines 3501-3506 inside this range |

Coverage: 3201-3212 (3×4) + 3213-3260 (24×2) + 3261-3600 (340) = 12 + 48 + 340 = 400. "There are 60
bytes assigned; 340 are unassigned for optional use" [p.5] — consistent.

#### Rev 1 binary-header fields that are **not** in Rev 0

| Bytes | Rev 1 field | Rev 0 status | Reader rule for a Rev 0 file |
|---|---|---|---|
| 3501-3502 | `segyRevision` (u8.u8; 0x0100 = 1.0; 0 = "traditional 1975 SEG-Y") | unassigned, optional vendor data | Rev 1 itself defines **0 = Rev 0**. A non-zero value in a genuine Rev 0 file is vendor data; it cannot be told apart from a real revision byte except by plausibility. |
| 3503-3504 | `fixedLengthTraces` | unassigned | ignore; there is no fixed-length guarantee |
| 3505-3506 | `numExtTextHeaders` | unassigned | ignore; there are no extended headers |
| (Rev 2) 3261-3300, 3507-3532 | ext counts, byte-order marker, trace count, first-trace offset, … | unassigned | ignore (`segy_rev2_1.md`) |

### 3.3 Trace identification header (240 B) [p.9-10]

Bytes 1-180 have the same positions, sizes and (with the code-table additions in §4) meanings as
`segy_rev1.md` §3.4. Rows below are only those whose Rev 0 text differs.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Rev 0 meaning | Δ vs Rev 1 |
|---|---|---|---|---|---|---|
| 1-4 | | 4b | i32 | `traceSeqLine` | `*` Trace sequence number within line; continues across reels of the same line | same |
| 5-8 | | 4b | i32 | `traceSeqFile` | Trace sequence number **within reel**; each reel starts at 1 | "within SEG-Y file" |
| 21-24 | | 4b | i32 | `ensembleNumber` | **CDP** ensemble number | any ensemble (CDP, CMP, CRP, …) |
| 25-28 | | 4b | i32 | `traceInEnsemble` | Trace number within the CDP ensemble, starts at 1 | any ensemble |
| 29-30 | | 2b | i16 | `traceId` | `*` codes 1-8, 9…N optional (§4.2) | Rev 1 adds −1, 0, 9-10+ meanings |
| 37-40 | | 4b | i32 | `offset` | Distance source point to receiver group; negative if opposite to shooting direction | same (no scalar) |
| 69-70 | | 2b | i16 | `elevationScalar` | 1, ±10, ±100, ±1000, ±10000; >0 multiply, <0 divide; applies to 41-68 | same (0 undefined) |
| 71-72 | | 2b | i16 | `coordinateScalar` | same values; applies to **73-88** | Rev 1: also 181-188 |
| 73-88 | | 4×4b | i32 | `sourceX` … `groupY` | length, or **seconds of arc** (X = longitude, Y = latitude; + = east/north) | Rev 1 adds decimal degrees, DMS |
| 89-90 | | 2b | i16 | `coordinateUnits` | **1 = length (m or ft), 2 = seconds of arc** only | Rev 1 adds 3, 4 |
| 95-114 | | 2b each | i16 | uphole, statics, lag A/B, delay, mute | **milliseconds, unscaled** (no time scalar exists) [p.4 rule 9b] | Rev 1: × time scalar 215-216 (0 ⇒ 1) |
| 109-110 | | 2b | i16 | `delayRecordingTime` | "Delay according [sic] time": ms from source initiation to the first sample, "for deep water work if data recording does not start at zero time" | Rev 1 explicitly allows negative values |
| 111-112 | | 2b | i16 | `muteStart` | printed "brute time--start" (OCR of "Mute") | same field |
| 115-116 | | 2b | i16 | `numSamples` | `*` Number of samples in this trace | Rev 1 ties it to the fixed-length flag |
| 117-118 | | 2b | i16 | `sampleInterval` | `*` µs for this trace | same |
| 157-158 | | 2b | i16 | `year` | "Year data recorded"; 2- or 4-digit not specified | Rev 1: 4-digit for rev ≥ 1 |
| 167-168 | | 2b | i16 | `timeBasisCode` | 1 local, 2 GMT, 3 other | Rev 1 adds 4 = UTC |
| 169-170 | | 2b | i16 | `traceWeightingFactor` | LSB = 2^−N V (N = 0..32767). **Required for fixed-point formats 2 and 3** to give absolute input voltage [p.5-6] | Rev 1: general |
| 179-180 | | 2b | i16 | `overTravel` | 1 down/behind, 2 up/ahead | same |
| 181-240 | | **60b** | — | `unassigned` | **Unassigned, for optional information** | Rev 1 defines 181-232 |

Coverage: 1-180 as in `segy_rev1.md` §3.4 (180 B) + 181-240 (60 B) = 240.

`*` fields [p.9-10]: 1-4, 9-12, 13-16, 29-30, 115-116, 117-118 (same set as Rev 1's "R").

> **AMBIGUITY [p.10]:** "169-170 … defined as 2-N volts" = 2^−N (superscript lost). "Delay according
> time" and "brute time" are OCR errors for "Delay recording time" and "Mute time" (Rev 1 has them so).

> **AMBIGUITY [p.9]:** scaler values printed "1, +10, +100, +1000, or +10,000" (the ± sign was lost),
> while the next sentence makes negative values divisors. Read as ±1..±10000, same as Rev 1.

#### Rev 1 trace-header fields that are **not** in Rev 0 (all in Rev 0's unassigned 181-240)

| Bytes | Rev 1 field (`segy_rev1.md` §3.4) |
|---|---|
| 181-184, 185-188 | `cdpX`, `cdpY` (× coordinate scalar) |
| 189-192, 193-196 | `inlineNumber`, `crosslineNumber` |
| 197-200, 201-202 | `shotpointNumber`, `shotpointScalar` |
| 203-204 | `traceValueUnit` |
| 205-210, 211-212 | `transductionMantissa`/`Exponent`, `transductionUnits` |
| 213-214 | `deviceTraceId` |
| 215-216 | `timeScalar` (so Rev 0 times 95-114 are plain ms) |
| 217-218, 219-224 | `sourceTypeOrientation`, `sourceEnergyDirection` |
| 225-230, 231-232 | `sourceMeasurementMantissa`/`Exponent`, `sourceMeasurementUnit` |
| 233-240 | unassigned in Rev 1 too (Rev 2: `headerName`) |

In a Rev 0 file these 60 bytes may hold anything (vendor data), so no Rev 1 interpretation is valid.

## 4. Code tables (Rev 0 values only; Rev 1 is a superset)

### 4.1 Data sample format code (binary 3225-3226) [p.5, p.8]

| Code | Rev 0 name | Bytes | Fig. | In Rev 1 |
|---|---|---|---|---|
| 1 | 32-bit floating point (IBM) | 4 | 3-A | same |
| 2 | 32-bit fixed point | 4 | 3-B | "4-byte two's complement integer" |
| 3 | 16-bit fixed point | 2 | 3-C | "2-byte two's complement integer" |
| 4 | 32-bit fixed point **with gain values** ("w/gain code") | 4 | 3-D | kept, marked **obsolete** |
| 5, 8 | — | — | — | added in Rev 1 (IEEE f32, i8) |

### 4.2 Trace identification code (trace 29-30) [p.9]

| Code | Meaning |
|---|---|
| 1 | seismic data |
| 2 | dead |
| 3 | dummy |
| 4 | time break |
| 5 | uphole |
| 6 | sweep |
| 7 | timing |
| 8 | water break |
| 9 … N | optional use (N ≤ 32,767) |

Rev 1 adds −1 (other), 0 (unknown) and assigns 9 and up (`segy_rev1.md` C8). A Rev 0 file may use
9..N for its own purposes.

### 4.3 Other Rev 0 code ranges

| Field | Rev 0 codes | Rev 1 additions |
|---|---|---|
| Trace sorting 3229-3230 | 1-4 | −1, 0, 5-9 |
| Coordinate units 89-90 | 1 length, 2 seconds of arc | 3 decimal degrees, 4 DMS |
| Time basis 167-168 | 1 local, 2 GMT, 3 other | 4 UTC |
| Gain type 119-120 | 1 fixed, 2 binary, 3 floating point, 4..N optional | same |

All others (sweep type, taper type, correlated, gain recovered, amplitude recovery, measurement system,
impulse and vibratory polarity, data use, over travel) are identical to Rev 1.

## 5. Data sample formats [p.1, p.5-7]

General [p.1 rule 3, p.7 note]: every data value is two's complement except format 1 (sign, characteristic,
fraction). The least significant bit is bit 7 of the last byte (byte 4, or byte 2 for format 3), i.e.
big-endian, MSB first. "In all four data formats, the channel or trace data should represent the absolute
input voltage at the recording instrument" [p.5]. Bit numbering below: bit 0 = MSB.

| Code | Layout | Decode |
|---|---|---|
| 1 | `S C6..C0 \| Q-1..Q-24` (IBM hex float, IBM GA 22-6821) | `(-1)^S × 16^(C−64) × 0.Q` (unchanged in Rev 1) |
| 2 | `S I30..I0` | `i32`; volts = value × 2^−N, N = trace 169-170 |
| 3 | `S I14..I0` | `i16`; volts = value × 2^−N, N = trace 169-170 |
| 4 | see below | see below |

> **AMBIGUITY [p.1, p.5]:** "except the 320bit floating point format" = "32-bit". The value formula on
> [p.5] reads "QS X 16 (O C—64) X QF" = (sign) × 16^(QC−64) × QF.

### 5.1 Code 4: 32-bit fixed point with gain (Fig. 3-D) [p.5]

Rev 0 text: "The first byte of this format is all zeros. The second byte provides eight available gain
bits 2^0 through 2^7. The last two bytes are identical to Figure 3-C."

| Byte | bit 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 2 | G7 | G6 | G5 | G4 | G3 | G2 | G1 | G0 |
| 3 | S | I14 | I13 | I12 | I11 | I10 | I9 | I8 |
| 4 | I7 | I6 | I5 | I4 | I3 | I2 | I1 | I0 |

- Byte 1 must be 0x00.
- G = u8 gain code, bit weights 2^7 (bit 0) … 2^0 (bit 7), range 0..255.
- Bytes 3-4 = format 3 word = `i16` two's complement mantissa (Rev 0 rule 3: all non-float values are
  two's complement).
- The bit table above is the Rev 1 App. E reprint (`segy_rev1.md` §5 Code 4), which matches the Rev 0 prose
  byte for byte.

> **AMBIGUITY [p.5]:** Rev 0 gives **no formula** for combining G and the mantissa, and does not say
> whether G is a gain applied (so the input voltage = mantissa × 2^−G) or a gain to be recovered
> (× 2^+G). Rev 1 App. E prints `* 2^GGGGGGGG` (positive superscript); Rev 2.1 prints `2^−GGGGGGGG`
> (`segy_rev2_1.md` §5). The physical reading ("gain values" of a binary-gain instrument, with the data
> meant to represent input voltage) favours **value = i16 × 2^−G**. Also unspecified: whether format 4
> also uses the trace weighting factor 169-170 (the text names only formats 3-B and 3-C for that).

Encode (not in the spec; a design choice for a writer that supports format 4, under the 2^−G
reading): pick the largest G in 0..255 with `|round(x × 2^G)| ≤ 32767` (maximum precision), then write
byte 1 = 0x00, byte 2 = G, bytes 3-4 = `i16(round(x × 2^G))`.

## 6. Derived rules / algorithms

### 6.1 Sizes

| Item | Rev 0 |
|---|---|
| Header | 3200 + 400 = 3600 bytes, always; no extended records |
| bytes/sample | formats 1, 2, 4: 4; format 3: 2; anything else invalid |
| Trace | 240 + ns × bps, ns = trace 115-116; on tape also = block length |
| Offset of trace k (0-based, all traces equal length) | 3600 + k × (240 + ns × bps) |

### 6.2 Version detection (how a Rev 0 file looks)

| Check | Rev 0 file |
|---|---|
| Binary 3501-3502 | 0x0000 if the writer zero-filled the unassigned area (common); else **arbitrary vendor data** |
| Binary 3503-3506 | same: 0 or vendor data, never meaningful |
| Text card 39 | no `SEG Y REV1` (may hold anything or blanks) |
| Text encoding | EBCDIC (byte 0 = 0xC3 `C`). An ASCII text header implies a post-1975 writer, regardless of 3501 |
| Format code | 1-4 (a 5 or 8 means a post-Rev 1 writer that left 3501 at 0, e.g. `Sweep0.sgy`, see `segy_rev1.md` Resolutions) |

Rule: rev bytes = 0 ⇒ Rev 0 rules. Rev bytes ∉ {defined revisions} ⇒ Rev 0 rules (they are vendor data).
A defined revision value (`01 00`, `02 00`, `02 01`) in a file that is really Rev 0 is undetectable from
3501-3502 alone; cross-checks: Rev 2 needs the 3297-3300 byte-order marker; Rev 1 should have `SEG Y REV1`
in card 39.

### 6.3 Units and conventions [p.4 rule 9]
Binary entries right-justified, EBCDIC left-justified; times ms except sample intervals (µs); frequencies
Hz; slopes dB/octave; lengths feet or meters, not mixed within a reel; velocities ft/s or m/s, not mixed;
elevation + above, − below sea level.

## 7. Implementation notes

- Rev 0 is a **strict subset** of Rev 1 in layout: every byte Rev 0 defines has the same position and type
  in Rev 1. A Rev 1 reader reads Rev 0 correctly if it (a) ignores 3261-3600 and 181-240, (b) applies no
  time scalar, (c) does not trust a fixed-length flag, (d) reads no extended headers, (e) supports format 4.
- "Rev 0" files in the wild are mostly post-1975 files that never set 3501: they may be ASCII, little-endian,
  format 5 and carry Rev 1 fields in 181-240. Accept them, but do not *interpret* 181-240 without a layout.
- Year 157-158 may be 2-digit (e.g. 75 = 1975).
- One line per reel: binary `lineNumber` is the line of every trace.
- Writer for Rev 0 output: EBCDIC text, `C` in column 1 of every card, 3261-3600 zero (in particular
  3501-3506 = 0), trace 181-240 zero unless the user asks to keep vendor bytes, big-endian, format 1-4,
  no extended headers, every trace with correct 115-116.

## 8. Open questions

| # | Question | Suggested default |
|---|---|---|
| R0-Q1 | Format 4 gain sign (§5.1). | Read as i16 × 2^−G (current code); offer an option for 2^+G; keep raw bytes. |
| R0-Q2 | Rev 0 trace with 115-116 = 0 on disk. | Fall back to binary 3221-3222 with a warning; on tape use the block length. |
| R0-Q3 | Does format 4 also scale by the trace weighting factor? | No (text names only formats 2 and 3). |
| R0-Q4 | Rev 0 card 40 content. | Not recoverable (image); accept anything; write `C40 END EBCDIC`. |

## 9. Implementation gap analysis (code as of commit `14fbb9d`)

### 9.1 What the code does today with a Rev 0 file

| Step | Behaviour | Where |
|---|---|---|
| Revision | 3501-3502 = `00 00` ⇒ Rev 0; any undefined pair ⇒ Rev 0 rules ("ignore bytes 3261-3600") | `src/parseSEG/segy/binheader.nim:102-116` |
| Revision warning | non-canonical revision bytes logged (`dcUnsupportedRevision`) and read with Rev 0 rules | `binheader.nim:198-202` |
| Rev 2 extended binary fields | used only when `rulesRevision.major >= 2` | `binheader.nim:147-171` |
| Fixed-length / ext-count checks | skipped for Rev 0 | `binheader.nim:209-213` |
| Format codes | 1, 2, 4, 5 → 4 B; 3 → 2 B; 8 → 1 B **for every revision, including Rev 0**; Rev 2 codes refused before Rev 2 | `binheader.nim:173-185` |
| Byte order | Rev 2 marker at 3297-3300 if present, else plausibility scoring (uses 3503-3506 too) | `binheader.nim:234-275` |
| Text | EBCDIC/ASCII auto-detected; no C39/C40 requirement | `src/parseSEG/segy/textheader.nim:36-49, 85-91` |
| Extended headers | count forced to 0 for Rev 0 | `src/parseSEG/segy/reader.nim:269-270` |
| Trace length | `numSamples` = trace 115-116 (Rev 0 never uses the fixed-length path) | `reader.nim:471-485` |
| Trace header 181-240 | decoded into Rev 1+ named fields, re-encoded unchanged | `src/parseSEG/segy/traceheader.nim:5-8` |
| Standard layout | Rev 0 layout = bytes 1-179 only, times unscaled (`time2` → `int2`) | `src/parseSEG/segy/layout.nim:176-185` |
| Format 4 decode | byte 2 = G, bytes 3-4 = i16, value = i16 × 2^−G | `src/parseSEG/segy/samples.nim:123-129` |
| Format 4 encode | refused ("obsolete and read-only") | `samples.nim:179-180` |
| Writer | Rev 0: extended headers refused, trailers refused, LE output warned/refused | `src/parseSEG/segy/writer.nim:116-128, 153-154` |

Verdict: a well-formed big-endian Rev 0 file (zeros in 3261-3600, correct 115-116) is read correctly and
written back byte-identically. The gaps are edge cases of real Rev 0 data.

### 9.2 Gaps, ranked by importance

1. **Trace length when 115-116 is missing or wrong** (`reader.nim:471-485`). Rev 0 sized traces by tape
   block, so old writers sometimes left 115-116 = 0 or unequal to the data. Today such a file is
   misaligned after trace 1 (0 samples read) and the read fails or yields garbage. Needed: (a) on a source
   with record boundaries (tape / tape image), take the trace length from the record length and warn on a
   mismatch with 115-116; (b) on disk, if 115-116 = 0 and binary 3221-3222 > 0, use the binary value with a
   warning; optionally confirm with `(fileSize − 3600) mod (240 + ns·bps) == 0` or by checking that the next
   240 bytes look like a header (trace sequence numbers increasing).
2. **Revision bytes that are vendor data but happen to look valid** (`binheader.nim:102-116`). A Rev 0
   file whose unassigned bytes hold `01 00`, `00 01`, `02 00`, `02 01` (or `2.x`) is read with Rev 1/2
   rules, which then trusts 3503-3506 (fixed-length flag ⇒ wrong lengths; ext count ⇒ traces swallowed as
   text) and, for "Rev 2", 3261-3300 overrides, 3513-3532 counts and offsets. Needed: cross-checks before
   upgrading the rules — Rev 2 only with the 3297-3300 marker (or a `SEG Y REV2` card 39), Rev 1 with
   3503 ∈ {0,1} and 3505 ≥ −1 and a plausible ext count (the record after 3600 must be text if 3505 > 0);
   else fall back to Rev 0 with a warning.
3. **Format 4 gain sign** (`samples.nim:123-129`). The 2^−G reading is a choice (§5.1 AMBIGUITY). Needed: a
   reader option (as `twosComplement8015` in SEG-D) and a doc note; raw bytes are already kept, so data is
   never lost.
4. **Format 4 cannot be written** (`samples.nim:179-180`). Raw pass-through works (samples are kept raw);
   edited or converted format-4 data cannot be produced. Needed only for full Rev 0 write support:
   implement the encoder in §5.1 (low demand; the format is obsolete).
5. **Byte-order detection reads unassigned bytes** (`binheader.nim:241-242, 247, 258-264`). For a Rev 0
   file, 3297-3300 and 3503-3506 are vendor data; a coincidental `01 02 03 04` would be taken as a Rev 2
   marker, and vendor values skew the plausibility score. Low risk; fix by scoring only 3201-3260 when the
   revision bytes are 0/undefined, and by honouring the marker only when the revision is 2.x.
6. **No Rev 0 strictness diagnostics** (`binheader.nim:173-185, 187-221`). Formats 5 and 8 in a Rev 0
   file pass silently (correct for real data such as `Sweep0.sgy`, but worth a `sevInfo`); an ASCII text
   header in a "Rev 0" file is not reported. Low.
7. **Rev 0 writer defaults** (`writer.nim`, `textheader.nim:107-115`). Writing a *new* Rev 0 file does not
   enforce EBCDIC text, zero 3261-3600, zero 181-240, or format ∈ 1-4. Pass-through is fine. Low.
8. **2-digit year** (`traceheader.nim:80`). No helper to expand 2-digit years for Rev 0 data. Cosmetic.
