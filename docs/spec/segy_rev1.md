# SEG-Y rev 1.0 (May 2002) — spec note

Source: `SEG Spec/text/SEG Y rev 1Release 1.02.txt`. `[p.N]` = `=== PAGE N ===` marker (PDF page index;
printed page = N−3 for the body).

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| 1-3 | Title, TOC | skipped (front matter) |
| 4-5 | Intro, summary, changes from rev 0, notation | rules only (CDP ≡ CMP) |
| 5-7 | §3 File structure, medium, number formats, varying trace lengths, coordinates | yes |
| 7-8 | §4 Textual File Header, Table 1 | yes |
| 9-12 | §5 Binary File Header, Table 2 | yes |
| 12-15 | §6 Extended Textual File Header, stanza syntax, EndText, example | yes |
| 15-23 | §7 Trace header (Table 3), trace data | yes |
| 23-24 | App. A disk files | yes |
| 24-26 | App. B tape label (Table 4) | yes |
| 26 | App. C tape blocking | yes |
| 27-42 | App. D standard stanzas (Tables 5-12) | yes (keyword tables) |
| 42-44 | App. E data word formats | yes |
| 45-48 | App. F EBCDIC/ASCII (Table 13) | yes (compact mapping) |
| 48 | App. G references | skipped |
| 49 | empty | — |

Acknowledgments, SEG address, POSC contact address and history prose omitted.

## 2. File / tape structure

### 2.1 Logical byte stream [p.5, p.6]

| # | Block | Size | Count | Notes |
|---|---|---|---|---|
| 0 | SEG-Y Tape Label | 128 | 0/1 | Optional; only on unformatted removable media (tape). Separate record. Never in a disk file. [p.24] |
| 1 | Textual File Header | 3200 | 1 | 40 × 80-char card images, EBCDIC or ASCII. [p.7, p.24] |
| 2 | Binary File Header | 400 | 1 | File bytes 3201-3600. |
| 3 | Extended Textual File Header records | 3200 each | N ≥ 0 | N given by binary 3505-3506 (−1 = variable, terminated by `((SEG: EndText))`). [p.11-12] |
| 4 | Data trace records | 240 + data | M | Each = 240-byte trace header immediately followed by its sample data. [p.6, p.23] |

- "SEG-Y file" ≡ "data set" ≡ rev-0 "seismic reel". No "one line per reel" restriction. [p.5]
- All binary values are **big-endian** on every medium (disk or tape, any host). Little-endian files are **not** SEG-Y rev 1 compatible. [p.6, p.24]
- Medium: anything resolvable to a stream of variable-length records. A SEG-Y file may also be a logical file inside SEG RODE encapsulation (out of scope). [p.5]

### 2.2 Disk file (App. A) [p.23-24]

Plain byte stream, no encapsulation, no record markers, no padding:

```
offset 0      : textual header (3200)
offset 3200   : binary header (400)
offset 3600   : extended textual header records, 3200 each (N records)
offset 3600+3200*N : trace 1 header (240) + trace 1 data (ns1*bps)
              : trace 2 header immediately after trace 1 data, etc.
```

- ns_i = trace header bytes 115-116 of that trace; bps from binary 3225-3226 (§6.1). Trace-record byte count **must** be consistent with trace-header sample count. [p.18, p.23]
- No tape label in disk files.

### 2.3 Tape (unblocked, default) [p.5, p.26]

- Each SEG-Y record = one tape record: 3200 textual, 400 binary, each 3200 extended textual, each (240 header + data) trace. [p.26 defines "SEG Y record" this way]
- Optional 128-byte label as first record; **no file mark** between label and first data record. [p.24]
- Partitioned media: each partition handled in isolation; each partition starts with its own label (if labels used); data may not run over partitions; SEG-Y and non-SEG-Y partitions may be mixed. [p.24]
- File-mark semantics for unblocked tapes are not stated explicitly beyond App. C; see Open question Q6.

### 2.4 Tape with App. C blocking [p.26]

| Rule |
|---|
| Tape **must** begin with a SEG-Y tape label as a separate 128-byte tape record (per partition). |
| First tape record after label begins with the 3200-byte Textual File Header record. |
| Each tape record = one or more whole SEG-Y records concatenated; a tape record starts on a SEG-Y record boundary; integral number of SEG-Y records. |
| Tape record length ≤ label "Maximum Block Size" (if non-zero) and ≤ medium maximum record length. |
| Reader must unblock by walking SEG-Y records: 3200, 400, N×3200, then 240 + ns×bps per trace (ns from each trace header). |
| Between SEG-Y files: optional single file mark. If a file mark is present, it ends the SEG-Y file and must be followed by a tape record starting with a 3200-byte textual header, or another file mark. |
| Without file mark, a new SEG-Y file is recognised by a tape record starting with a textual header: first byte `C` (EBCDIC 0xC3 / ASCII 0x43) and revision level in card C39. |
| A tape record never holds data from two SEG-Y files (each file starts on a tape-record boundary). |
| Double file mark = end of data. |

## 3. Header tables

General: all binary-header and trace-header values are 2- or 4-byte **two's-complement** big-endian integers; there are no floating-point header values [p.6]. The only exception stated is the revision number (unsigned, 3501-3502) [p.11]. Field width follows from the byte range.

Mandatory markers (footnotes in the source): **M-pre** = footnote 5 "mandatory for prestack data"; **M** = footnote 6 "mandatory for all data types"; **R** = footnote 7 "strongly recommended that this information always be recorded" [p.9, p.15].

### 3.1 Textual File Header (3200 bytes, file bytes 1-3200) [p.7-8]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3200 | | 3200b | ebcdic (or ascii) | `textualHeader` | 40 card images × 80 bytes. Card k occupies bytes (k−1)*80+1 .. k*80. EBCDIC traditional; ASCII allowed in rev 1 [p.4, p.24]. |

Card-image layout (Table 1 [p.8]; columns 1-80):

| Cols | Content |
|---|---|
| 1 | `C` (EBCDIC 0xC3 / ASCII 0x43). Required: App. C uses it to find file starts [p.26]; §6.1 contrasts extended lines that do *not* start with `C` [p.13]. |
| 2-3 | Card number, right-justified, blank-padded (` 1`..`40`, shown as `C 1`, `C10`). |
| 4 | blank |
| 5-80 | Free text. |

Card contents (Table 1 is an *example* for C1-C38; content is free-form except C39/C40):

| Card | Example labels (Table 1) | Status |
|---|---|---|
| C1 | CLIENT, COMPANY, CREW NO | suggested |
| C2 | LINE, AREA, MAP ID | suggested |
| C3 | REEL NO, DAY-START OF REEL, YEAR, OBSERVER | suggested |
| C4 | INSTRUMENT: MFG, MODEL, SERIAL NO | suggested |
| C5 | DATA TRACES/RECORD, AUXILIARY TRACES/RECORD, CDF FOLD [sic] | suggested |
| C6 | SAMPLE INTERVAL, SAMPLES/TRACE, BITS/IN, BYTES/SAMPLE | suggested |
| C7 | RECORDING FORMAT, FORMAT THIS REEL, MEASUREMENT SYSTEM | suggested |
| C8 | SAMPLE CODE: FLOATING PT, FIXED PT, FIXED PT-GAIN, CORRELATED | suggested |
| C9 | GAIN TYPE: FIXED, BINARY, FLOATING POINT, OTHER | suggested |
| C10 | FILTERS: ALIAS HZ, NOTCH HZ, BAND - HZ, SLOPE - DB/OCT | suggested |
| C11 | SOURCE: TYPE, NUMBER/POINT, POINT INTERVAL | suggested |
| C12 | PATTERN: LENGTH, WIDTH | suggested |
| C13 | SWEEP: START HZ, END HZ, LENGTH MS, CHANNEL NO, TYPE | suggested |
| C14 | TAPER: START LENGTH MS, END LENGTH MS, TYPE | suggested |
| C15 | SPREAD: OFFSET, MAX DISTANCE, GROUP INTERVAL | suggested |
| C16 | GEOPHONES: PER GROUP, SPACING, FREQUENCY, MFG, MODEL | suggested |
| C17 | PATTERN: LENGTH, WIDTH | suggested |
| C18 | TRACES SORTED BY: RECORD, CDP, OTHER | suggested |
| C19 | AMPLITUDE RECOVERY: NONE, SPHERICAL DIV, AGC, OTHER | suggested |
| C20 | MAP PROJECTION, ZONE ID, COORDINATE UNITS | suggested; overridden by a Location Data stanza (footnote 3) |
| C21 | PROCESSING: | suggested |
| C22 | PROCESSING: (shown as a 2nd "C21") | suggested |
| C23-C38 | free | free |
| C39 | `SEG Y REV1` | **M** — revision level mandatory in textual header for rev 1 files; App. C requires it in C39 [p.7, p.26] |
| C40 | `END TEXTUAL HEADER` (preferred) or `END EBCDIC` (acceptable) | **M** (footnotes 4, 6) |

Also: textual header should mention unusual features, e.g. non-zero delay recording time (trace bytes 109-110) and non-standard shotpoint meaning [p.7, p.20].

> **AMBIGUITY:** [p.8] Table 1 text extraction inserts spurious spaces inside words ("COMPAN Y", "SA MPLES/TRAC E", "BINS RY" = BINARY, "BYTES/SAMP PLE"), so exact label columns of C1-C22 cannot be recovered. Only cols 1-4 and the C39/C40 contents are treated as normative; label columns are cosmetic.

> **AMBIGUITY:** [p.8] "C21 PROCESSING:" appears twice; the second is taken to be C22.

> **AMBIGUITY:** [p.8] "C39 SEG Y REV16" = text `SEG Y REV1` + footnote 6. "C40 END TEXTUAL HEADER4,6" = text `END TEXTUAL HEADER` + footnotes 4 and 6. "COORDINATE UNITS 3" = footnote 3. Assumed C39 text starts at col 5 (as other labels).

### 3.2 Binary File Header (400 bytes; file bytes 3201-3600; absolute numbering) [p.9-12]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 3201-3204 | | 4b | i32 | `jobId` | Job identification number. |
| 3205-3208 | | 4b | i32 | `lineNumber` | Line number. 3-D poststack: typically in-line number (= trace 189-192 if one in-line per file). |
| 3209-3212 | | 4b | i32 | `reelNumber` | Reel number. |
| 3213-3214 | | 2b | i16 | `dataTracesPerEnsemble` | Data traces per ensemble. **M-pre**. |
| 3215-3216 | | 2b | i16 | `auxTracesPerEnsemble` | Auxiliary traces per ensemble. **M-pre**. |
| 3217-3218 | | 2b | i16 | `sampleInterval` | Sample interval, µs. **M**. For the primary set of traces. |
| 3219-3220 | | 2b | i16 | `sampleIntervalOrig` | Sample interval of original field recording, µs. |
| 3221-3222 | | 2b | i16 | `samplesPerTrace` | Samples per data trace. **M**. For the primary set of traces. |
| 3223-3224 | | 2b | i16 | `samplesPerTraceOrig` | Samples per trace of original field recording. |
| 3225-3226 | | 2b | i16 | `formatCode` | Data sample format code, Table C1. **M**. |
| 3227-3228 | | 2b | i16 | `ensembleFold` | Expected data traces per ensemble (e.g. CMP fold). **R** (highly recommended). |
| 3229-3230 | | 2b | i16 | `traceSorting` | Trace sorting code, Table C2. **R**. |
| 3231-3232 | | 2b | i16 | `verticalSumCode` | 1 = no sum, 2 = two sum, …, N = M−1 sum (M = 2..32767). See AMBIGUITY. |
| 3233-3234 | | 2b | i16 | `sweepFreqStart` | Sweep frequency at start, Hz. |
| 3235-3236 | | 2b | i16 | `sweepFreqEnd` | Sweep frequency at end, Hz. |
| 3237-3238 | | 2b | i16 | `sweepLength` | Sweep length, ms. |
| 3239-3240 | | 2b | i16 | `sweepType` | Table C5. |
| 3241-3242 | | 2b | i16 | `sweepChannel` | Trace number of sweep channel. |
| 3243-3244 | | 2b | i16 | `sweepTaperStart` | Taper length at start, ms (taper starts at zero time). |
| 3245-3246 | | 2b | i16 | `sweepTaperEnd` | Taper length at end, ms (end taper starts at sweep length − this). |
| 3247-3248 | | 2b | i16 | `taperType` | Table C6. |
| 3249-3250 | | 2b | i16 | `correlated` | 1 = no, 2 = yes. |
| 3251-3252 | | 2b | i16 | `binaryGainRecovered` | 1 = yes, 2 = no. |
| 3253-3254 | | 2b | i16 | `amplitudeRecovery` | 1 = none, 2 = spherical divergence, 3 = AGC, 4 = other. |
| 3255-3256 | | 2b | i16 | `measurementSystem` | 1 = meters, 2 = feet. **R**. Must agree with Location Data stanza; on conflict the last Location Data stanza wins. |
| 3257-3258 | | 2b | i16 | `impulsePolarity` | 1 = pressure increase / upward geophone case movement gives **negative** number; 2 = gives **positive** number. |
| 3259-3260 | | 2b | i16 | `vibratoryPolarity` | Table C7. |
| 3261-3500 | | 240b | — | `unassigned1` | Unassigned. |
| 3501-3502 | | 2b | u16 (fixedpt `u8.u8`) | `segyRevision` | Format revision, unsigned, Q-point between byte 3501 and 3502: byte 3501 = integer part, 3502 = fraction. Rev 1.0 = **0x0100**. 0 = traditional rev-0 (1975) SEG-Y. **M**. |
| 3503-3504 | | 2b | i16 | `fixedLengthTraces` | 1 = all traces have the binary-header sample interval (3217-3218) and sample count (3221-3222); 0 = may vary, read trace 115-116 per trace. **M**. 0 also = rev 0. |
| 3505-3506 | | 2b | i16 | `numExtTextHeaders` | Count of 3200-byte extended textual header records after the binary header. 0 = none; >0 = exactly that many; −1 = variable, ended by `((SEG: EndText))` record. Positive value not mandatory even if known. **M**. 0 also = rev 0. |
| 3507-3600 | | 94b | — | `unassigned2` | Unassigned. |

Coverage check: 3201-3212 (3×4) + 3213-3260 (24×2) + 3261-3500 (240) + 3501-3506 (3×2) + 3507-3600 (94) = 12+48+240+6+94 = 400. No gaps/overlaps.

> **AMBIGUITY:** [p.9-11] Footnote markers glued to byte ranges, resolved: "3215-32165" = 3215-3216 + fn5; "3225-32266" = 3225-3226 + fn6; "3229-32307" = 3229-3230 + fn7; "3255-32567" = 3255-3256 + fn7; "3501-35026" = 3501-3502 + fn6. Stand-alone digits on adjacent lines: fn5 on 3213-3214, fn6 on 3217-3218, 3221-3222, 3503-3504, 3505-3506; fn7 on 3227-3228. Footnote texts: fn5 "mandatory for prestack data", fn6 "mandatory for all data types" [p.9]; fn7 "strongly recommended" [p.15].

> **AMBIGUITY:** [p.11] "recorded as 010016" = 0100₁₆ (subscript 16 glued), i.e. bytes 0x01 0x00.

> **AMBIGUITY:** [p.11] 3503-3504 text says "as specified in **Textual** File Header bytes 3217-3218 and 3221-3222"; these are Binary File Header bytes. Treated as a typo.

> **AMBIGUITY:** [p.10] Vertical sum code "N = M-1 sum (M = 2 to 32,767)" is self-inconsistent with "1 = no sum, 2 = two sum". Interpret as: value N = N-fold sum (N = 1..32767); store raw.

> **AMBIGUITY:** [p.9] Sample interval and sample counts are declared two's-complement (max 32767), but values > 32767 (e.g. ns up to 65535) exist in practice; see Q1.

### 3.3 Extended Textual File Header records (3200 bytes each) [p.12-15]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-3200 | | 3200b | ebcdic (or ascii) | `extTextRecord` | 40 lines × 80 chars of card-image text. Lines do **not** start with `C`. All records concatenated form one logical text (record boundaries insignificant). |

Stanza syntax:

| Rule | Detail |
|---|---|
| Stanza header | Line starting in **column 1** with `((`, ending with `))`: `((Org: Stanza Name))`. `(`=EBCDIC 0x4D / ASCII 0x28; `)`=0x5D / 0x29. |
| Org separator | `:` (EBCDIC 0x7A / ASCII 0x3A) between organization and stanza name, e.g. `((SEG: Location Data ver 1.0))`. Org name `SEG` (and variants) reserved for SEG. |
| Name matching | Case-insensitive; spaces (0x40 / 0x20) ignored. `(( SEG: Recording Parameters ))` ≡ `((seg:RECORDINGPARAMETERS))`. |
| Stanza extent | From its header to the next stanza header or end of the extended header. |
| Line syntax (keyword/value stanzas) | `keyword = value`. Keywords/values may contain any printable char except `((`, `))`, `=`. Punctuation in keywords discouraged. |
| Keyword matching | Case-insensitive; spaces ignored ("Line Name" ≡ "LINENAME"). |
| Value | From first non-blank after `=` to last non-blank on the line. Subfields separated by `,` (EBCDIC 0x6B / ASCII 0x2C). |
| Blank lines | Ignored. |
| Comments | First non-blank char `#` (EBCDIC 0x7B / ASCII 0x23): line ignored. |
| Continuation | Last non-blank char `&` (EBCDIC 0x50 / ASCII 0x26): next line is appended, `&` removed. |
| Line end | Each line ends with CR LF: EBCDIC 0x0D 0x25, ASCII 0x0D 0x0A. See Q3. |
| Unknown stanzas | Reader must be able to ignore them (possibly the whole extended header). |
| Duplicates | Each stanza recommended once per file; on multiple/conflicting entries the **last** wins. |
| Name uniqueness | If org name may be non-unique, first keyword should be `Stanza Definer = Full Company Name`. User stanzas should carry revision numbering. |
| Encoding | EBCDIC or ASCII [p.4, p.24]. |

EndText [p.14]:

| Rule |
|---|
| `((SEG: EndText))` required when binary 3505-3506 = −1; optional when > 0. |
| Must be alone in the **final** 3200-byte record: stanza header on the first line of that record, rest of the record blank (empty stanza). |
| Preceding records are padded with blank lines/records to 3200 bytes (example [p.15]). |

> **AMBIGUITY:** [p.13-14] Hex codes in §6 have the subscript "16" glued: "7A16"=0x7A, "3A16"=0x3A, "4D16"=0x4D, "2816"=0x28, "5D16"=0x5D, "2916"=0x29, "4016"=0x40, "2016"=0x20, "C316"=0xC3, "4316"=0x43, "6B16"=0x6B, "2C16"=0x2C, "7B16"=0x7B, "2316"=0x23, "5016"=0x50, "0D2516"=0x0D 0x25, "0D0A16"=0x0D 0x0A.

> **AMBIGUITY:** [p.14] Ampersand given as "ASCII 1616" (0x16 is SYN). App. F [p.46, p.48] gives `&` = EBCDIC 0x50, ASCII 0x26. Use 0x26.

> **AMBIGUITY:** [p.13] Double parentheses printed as `"("` / `")"` (single) in the code descriptions; the examples use `((` and `))`. The stanza header is two of each.

### 3.4 Trace Header (240 bytes; offsets relative to trace-record start) [p.15-23]

Scalars: **E** = elevation scalar 69-70; **C** = coordinate scalar 71-72; **T** = time scalar 215-216 (§6.3).

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | i32 | `traceSeqLine` | Trace sequence number within line; keeps increasing across files of the same line. **R**. |
| 5-8 | | 4b | i32 | `traceSeqFile` | Trace sequence number within SEG-Y file; starts at 1 in each file. |
| 9-12 | | 4b | i32 | `fieldRecord` | Original field record number. **R**. |
| 13-16 | | 4b | i32 | `traceNumberInField` | Trace number within original field record. **R**. |
| 17-20 | | 4b | i32 | `energySourcePoint` | Energy source point number (multiple records at same location). Use 197-202 for shotpoint. |
| 21-24 | | 4b | i32 | `ensembleNumber` | Ensemble number (CDP, CMP, CRP, …). |
| 25-28 | | 4b | i32 | `traceInEnsemble` | Trace number within ensemble; starts at 1. |
| 29-30 | | 2b | i16 | `traceIdCode` | Trace identification code, Table C8. **R**. |
| 31-32 | | 2b | i16 | `numVertSummed` | Number of vertically summed traces (1 = one trace). |
| 33-34 | | 2b | i16 | `numHorzStacked` | Number of horizontally stacked traces (1 = one trace). |
| 35-36 | | 2b | i16 | `dataUse` | 1 = production, 2 = test. |
| 37-40 | | 4b | i32 | `offset` | Source-center to receiver-group-center distance; negative if opposite to shooting direction. No scalar stated. |
| 41-44 | | 4b | i32 | `receiverElevation` | Receiver group elevation; above vertical datum positive, below negative. ×E. Units per 3255-3256. |
| 45-48 | | 4b | i32 | `sourceSurfaceElevation` | Surface elevation at source. ×E. |
| 49-52 | | 4b | i32 | `sourceDepth` | Source depth below surface (positive). ×E. |
| 53-56 | | 4b | i32 | `receiverDatumElevation` | Datum elevation at receiver group. ×E. |
| 57-60 | | 4b | i32 | `sourceDatumElevation` | Datum elevation at source. ×E. |
| 61-64 | | 4b | i32 | `sourceWaterDepth` | Water depth at source. ×E. |
| 65-68 | | 4b | i32 | `groupWaterDepth` | Water depth at group. ×E. |
| 69-70 | | 2b | i16 | `elevationScalar` | Scalar for 41-68: ±1, ±10, ±100, ±1000, ±10000; >0 multiply, <0 divide. |
| 71-72 | | 2b | i16 | `coordinateScalar` | Scalar for 73-88 and 181-188: same rule. |
| 73-76 | | 4b | i32 | `sourceX` | Source coordinate X. ×C. Units per 89-90. |
| 77-80 | | 4b | i32 | `sourceY` | Source coordinate Y. ×C. |
| 81-84 | | 4b | i32 | `groupX` | Group coordinate X. ×C. |
| 85-88 | | 4b | i32 | `groupY` | Group coordinate Y. ×C. |
| 89-90 | | 2b | i16 | `coordinateUnits` | Table C9. |
| 91-92 | | 2b | i16 | `weatheringVelocity` | ft/s or m/s per 3255-3256. |
| 93-94 | | 2b | i16 | `subweatheringVelocity` | ft/s or m/s per 3255-3256. |
| 95-96 | | 2b | i16 | `upholeTimeSource` | Uphole time at source, ms. ×T. |
| 97-98 | | 2b | i16 | `upholeTimeGroup` | Uphole time at group, ms. ×T. |
| 99-100 | | 2b | i16 | `sourceStatic` | Source static correction, ms. ×T. |
| 101-102 | | 2b | i16 | `groupStatic` | Group static correction, ms. ×T. |
| 103-104 | | 2b | i16 | `totalStatic` | Total static applied, ms (0 = none). ×T. |
| 105-106 | | 2b | i16 | `lagTimeA` | ms between end of 240-byte header and time break; + if time break after end of header. ×T. |
| 107-108 | | 2b | i16 | `lagTimeB` | ms between time break and source initiation; ±. ×T. |
| 109-110 | | 2b | i16 | `delayRecordingTime` | ms between source initiation and first sample; may be negative. Non-zero → note in textual header. ×T. |
| 111-112 | | 2b | i16 | `muteStart` | Mute start time, ms. ×T. |
| 113-114 | | 2b | i16 | `muteEnd` | Mute end time, ms. ×T. |
| 115-116 | | 2b | i16 | `numSamples` | Number of samples in this trace. **R**. Determines data length. Must equal 3221-3222 if fixed-length flag = 1. |
| 117-118 | | 2b | i16 | `sampleInterval` | Sample interval for this trace, µs. **R**. Must equal 3217-3218 if fixed-length flag = 1. |
| 119-120 | | 2b | i16 | `gainType` | 1 = fixed, 2 = binary, 3 = floating point, 4..N = optional use. |
| 121-122 | | 2b | i16 | `instrumentGainConstant` | dB. |
| 123-124 | | 2b | i16 | `instrumentInitialGain` | Early/initial gain, dB. |
| 125-126 | | 2b | i16 | `correlated` | 1 = no, 2 = yes. |
| 127-128 | | 2b | i16 | `sweepFreqStart` | Hz. |
| 129-130 | | 2b | i16 | `sweepFreqEnd` | Hz. |
| 131-132 | | 2b | i16 | `sweepLength` | ms. |
| 133-134 | | 2b | i16 | `sweepType` | Table C5. |
| 135-136 | | 2b | i16 | `sweepTaperStart` | ms. |
| 137-138 | | 2b | i16 | `sweepTaperEnd` | ms. |
| 139-140 | | 2b | i16 | `taperType` | Table C6. |
| 141-142 | | 2b | i16 | `aliasFilterFreq` | Hz, if used. |
| 143-144 | | 2b | i16 | `aliasFilterSlope` | dB/octave. |
| 145-146 | | 2b | i16 | `notchFilterFreq` | Hz, if used. |
| 147-148 | | 2b | i16 | `notchFilterSlope` | dB/octave. |
| 149-150 | | 2b | i16 | `lowCutFreq` | Hz, if used. |
| 151-152 | | 2b | i16 | `highCutFreq` | Hz, if used. |
| 153-154 | | 2b | i16 | `lowCutSlope` | dB/octave. |
| 155-156 | | 2b | i16 | `highCutSlope` | dB/octave. |
| 157-158 | | 2b | i16 | `year` | Year recorded; rev ≥ 1: full 4-digit Gregorian year (2001 = 0x07D1). Rev 0 files may hold 2-digit years. |
| 159-160 | | 2b | i16 | `dayOfYear` | Day of year (Julian day for GMT/UTC). |
| 161-162 | | 2b | i16 | `hour` | 0-23. |
| 163-164 | | 2b | i16 | `minute` | |
| 165-166 | | 2b | i16 | `second` | |
| 167-168 | | 2b | i16 | `timeBasisCode` | Table C10. |
| 169-170 | | 2b | i16 | `traceWeightingFactor` | N; LSB = 2^−N volts (N = 0..32767). |
| 171-172 | | 2b | i16 | `rollSwitchGroup` | Geophone group number of roll switch position one. |
| 173-174 | | 2b | i16 | `firstTraceGroup` | Geophone group number of trace 1 in original field record. |
| 175-176 | | 2b | i16 | `lastTraceGroup` | Geophone group number of last trace in original field record. |
| 177-178 | | 2b | i16 | `gapSize` | Total number of groups dropped. |
| 179-180 | | 2b | i16 | `overTravel` | 1 = down (behind), 2 = up (ahead). |
| 181-184 | | 4b | i32 | `cdpX` | Ensemble (CDP) X. ×C. |
| 185-188 | | 4b | i32 | `cdpY` | Ensemble (CDP) Y. ×C. |
| 189-192 | | 4b | i32 | `inlineNumber` | 3-D poststack in-line number (= binary 3205-3208 if one in-line per file). |
| 193-196 | | 4b | i32 | `crosslineNumber` | 3-D poststack cross-line number (often = 21-24, not required). |
| 197-200 | | 4b | i32 | `shotpointNumber` | Shotpoint (mainly 2-D poststack); source location nearest the CDP, else explain in textual header. Scaled by 201-202. |
| 201-202 | | 2b | i16 | `shotpointScalar` | >0 multiply, <0 divide, **0 = not scaled**. Typical −10. |
| 203-204 | | 2b | i16 | `traceValueUnit` | Trace value measurement unit, Table C11. |
| 205-208 | | 4b | i32 | `transductionMantissa` | Transduction constant = mantissa × 10^exponent; converts samples to units in 211-212. |
| 209-210 | | 2b | i16 | `transductionExponent` | Power-of-ten exponent. |
| 211-212 | | 2b | i16 | `transductionUnits` | Table C11. |
| 213-214 | | 2b | i16 | `deviceTraceId` | Device/trace id (e.g. vibrator serial 4368; 20316 = gun 16, string 3, vessel 2). |
| 215-216 | | 2b | i16 | `timeScalar` | Scalar for 95-114 to give ms: ±1..±10000; >0 multiply, <0 divide, **0 = 1**. |
| 217-218 | | 2b | i16 | `sourceTypeOrientation` | Table C12. |
| 219-224 | | 6b | ext | `sourceEnergyDirection` | Energy direction w.r.t. source orientation (217-218), tenths of degree (347.8° → 3478). Internal layout unspecified — see AMBIGUITY. |
| 225-228 | | 4b | i32 | `sourceMeasurementMantissa` | Source measurement = mantissa × 10^exponent. |
| 229-230 | | 2b | i16 | `sourceMeasurementExponent` | Power-of-ten exponent. |
| 231-232 | | 2b | i16 | `sourceMeasurementUnit` | Table C13. |
| 233-240 | | 8b | — | `unassigned` | Unassigned, optional information. |

Coverage check: 1-28 (7×4=28), 29-36 (4×2=8), 37-68 (8×4=32), 69-72 (2×2=4), 73-88 (4×4=16), 89-180 (46×2=92), 181-200 (5×4=20), 201-204 (4), 205-210 (6), 211-218 (4×2=8), 219-224 (6), 225-230 (6), 231-232 (2), 233-240 (8) = 240. No gaps/overlaps.

Bytes 1-180 = 1975 fields (unchanged, clarified); 181-240 newly standardised in rev 1 (were optional in rev 0) [p.15].

> **AMBIGUITY:** [p.15-18] Footnote digits glued/adjacent, resolved: "13-167" = 13-16 + fn7; "29-307" = 29-30 + fn7; "115-1167" = 115-116 + fn7; stand-alone "7" beside 1-4, 9-12 and 117-118 = fn7 ("strongly recommended").

> **AMBIGUITY:** [p.17] Coordinate/elevation scalar values listed as "1, +10, +100, +1000, or +10,000" but negative values are explicitly divisors and the DMS example uses −100; read as ±1..±10000. Value 0 is not defined for 69-70 / 71-72 (only for 215-216 and 201-202). Recommend reader treats 0 as 1.

> **AMBIGUITY:** [p.17] DMS note says "bytes 89-90 equal = ±DDD*104 + MM*102 + SS". Bytes 89-90 are the units code; the encoded value belongs in the **coordinate** fields (73-88, 181-188), with 89-90 = 4. Exponents are superscripts lost in extraction: ±DDD·10⁴ + MM·10² + SS with 71-72 = 1; ±DDDMMSS.ss → ±DDD·10⁶ + MM·10⁴ + SS·10² with 71-72 = −100. Sign presumably applies to the whole value.

> **AMBIGUITY:** [p.19] "200110 (7D116)" = 2001₁₀ (7D1₁₆).

> **AMBIGUITY:** [p.20] "Defined as 2 -N volts" — superscript −N on its own line; LSB = 2^(−N) V.

> **AMBIGUITY:** [p.22] Source Measurement text says exponent in "bytes 209-230"; the field range (225-230) and formula ("Bytes 225-228 * 10**Bytes 229-230") give **229-230**. Typo.

> **AMBIGUITY:** [p.22] 219-224 (6 bytes) encoding is not specified beyond "tenths of degrees". Plausible: three i16 values (vertical, cross-line, in-line). Treat as 6 raw bytes; optionally expose as 3×i16. See Q4.

> **AMBIGUITY:** [p.23] Source Measurement Unit table lists **two code 4s**: "4 = Bar (Bar)" and "4 = Bar-meter (Bar-m)", then 5 = Newton, 6 = Kilograms. Codes as printed are kept; see Q5.

> **AMBIGUITY:** [p.18] 117-118 refers to "Appendix C" for disk files; disk files are App. A.

> **AMBIGUITY:** [p.17-18] Right-column annotations ("The scalar in Trace Header bytes 69-70 applies…", "Time in milliseconds as scaled by the scalar specified in Trace Header bytes 215-216") are interleaved with rows; resolved as applying to rows 41-68 and 95-114 respectively, consistent with the scalar field definitions on p.17 and p.22.

## 4. Code tables

### C1 Data sample format code (binary 3225-3226) [p.9, p.23]

| Code | Format | Bytes/sample | Enc |
|---|---|---|---|
| 1 | IBM floating point | 4 | ibm32 |
| 2 | Two's-complement integer | 4 | i32 |
| 3 | Two's-complement integer | 2 | i16 |
| 4 | Fixed point with gain (obsolete) | 4 | fixedpt (see §5) |
| 5 | IEEE floating point | 4 | f32 |
| 6 | Not currently used | — | — |
| 7 | Not currently used | — | — |
| 8 | Two's-complement integer | 1 | i8 |

### C2 Trace sorting code (binary 3229-3230) [p.10]

| Code | Meaning |
|---|---|
| −1 | Other (explain in user Extended Textual stanza) |
| 0 | Unknown |
| 1 | As recorded (no sorting) |
| 2 | CDP ensemble |
| 3 | Single fold continuous profile |
| 4 | Horizontally stacked |
| 5 | Common source point |
| 6 | Common receiver point |
| 7 | Common offset point |
| 8 | Common mid-point |
| 9 | Common conversion point |

### C3 Measurement system (binary 3255-3256) [p.11]
| Code | Meaning |
|---|---|
| 1 | Meters |
| 2 | Feet |

### C4 Amplitude recovery (binary 3253-3254) [p.11]
| Code | Meaning |
|---|---|
| 1 | None |
| 2 | Spherical divergence |
| 3 | AGC |
| 4 | Other |

### C5 Sweep type (binary 3239-3240, trace 133-134) [p.10, p.19]
| Code | Meaning |
|---|---|
| 1 | Linear |
| 2 | Parabolic |
| 3 | Exponential |
| 4 | Other |

### C6 Taper type (binary 3247-3248, trace 139-140) [p.10, p.19]
| Code | Meaning |
|---|---|
| 1 | Linear |
| 2 | cos² |
| 3 | Other |

### C7 Vibratory polarity (binary 3259-3260): seismic signal lags pilot by [p.11]
| Code | Phase lag |
|---|---|
| 1 | 337.5° to 22.5° |
| 2 | 22.5° to 67.5° |
| 3 | 67.5° to 112.5° |
| 4 | 112.5° to 157.5° |
| 5 | 157.5° to 202.5° |
| 6 | 202.5° to 247.5° |
| 7 | 247.5° to 292.5° |
| 8 | 292.5° to 337.5° |

Other small binary codes: correlated 3249-3250 (1 no, 2 yes); binary gain recovered 3251-3252 (1 yes, 2 no); impulse polarity 3257-3258 (1 negative, 2 positive). [p.10-11]

### C8 Trace identification code (trace 29-30) [p.16]

| Code | Meaning |
|---|---|
| −1 | Other |
| 0 | Unknown |
| 1 | Seismic data |
| 2 | Dead |
| 3 | Dummy |
| 4 | Time break |
| 5 | Uphole |
| 6 | Sweep |
| 7 | Timing |
| 8 | Waterbreak |
| 9 | Near-field gun signature |
| 10 | Far-field gun signature |
| 11 | Seismic pressure sensor |
| 12 | Multicomponent sensor – vertical |
| 13 | Multicomponent sensor – cross-line |
| 14 | Multicomponent sensor – in-line |
| 15 | Rotated multicomponent – vertical |
| 16 | Rotated multicomponent – transverse |
| 17 | Rotated multicomponent – radial |
| 18 | Vibrator reaction mass |
| 19 | Vibrator baseplate |
| 20 | Vibrator estimated ground force |
| 21 | Vibrator reference |
| 22 | Time-velocity pairs |
| 23..32767 | Optional use |

### C9 Coordinate units (trace 89-90) [p.17]
| Code | Meaning | X / Y |
|---|---|---|
| 1 | Length (meters or feet per binary 3255-3256) | map grid |
| 2 | Seconds of arc | X = longitude, Y = latitude |
| 3 | Decimal degrees | X = longitude, Y = latitude |
| 4 | Degrees, minutes, seconds (DMS) | X = longitude, Y = latitude; encoding in §6.4 |

For codes 2-4: positive = east of Greenwich / north of equator; negative = west / south. One CRS and one coordinate unit for all coordinates in a data set [p.7].

### C10 Time basis code (trace 167-168) [p.20]
| Code | Meaning |
|---|---|
| 1 | Local |
| 2 | GMT |
| 3 | Other (explain in user stanza) |
| 4 | UTC |

### C11 Trace value measurement unit (203-204) and Transduction units (211-212) [p.21]
| Code | Meaning |
|---|---|
| −1 | Other (Data Sample Measurement Unit stanza) |
| 0 | Unknown |
| 1 | Pascal (Pa) |
| 2 | Volts (V) |
| 3 | Millivolts (mV) |
| 4 | Amperes (A) |
| 5 | Meters (m) |
| 6 | Meters per second (m/s) |
| 7 | Meters per second squared (m/s²) |
| 8 | Newton (N) |
| 9 | Watt (W) |

### C12 Source type/orientation (trace 217-218) [p.22]
| Code | Meaning |
|---|---|
| −1..−n | Other (Source Type/Orientation stanza with matching "Source type identifier") |
| 0 | Unknown |
| 1 | Vibratory – vertical |
| 2 | Vibratory – cross-line |
| 3 | Vibratory – in-line |
| 4 | Impulsive – vertical |
| 5 | Impulsive – cross-line |
| 6 | Impulsive – in-line |
| 7 | Distributed impulsive – vertical |
| 8 | Distributed impulsive – cross-line |
| 9 | Distributed impulsive – in-line |

### C13 Source measurement unit (trace 231-232) [p.23] (as printed; see AMBIGUITY in §3.4)
| Code | Meaning |
|---|---|
| −1 | Other (Source Measurement Unit stanza) |
| 0 | Unknown |
| 1 | Joule (J) |
| 2 | Kilowatt (kW) |
| 3 | Pascal (Pa) |
| 4 | Bar (Bar) |
| 4 (dup) | Bar-meter (Bar-m) |
| 5 | Newton (N) |
| 6 | Kilograms (kg) |

Other trace codes: data use 35-36 (1 production, 2 test); gain type 119-120 (1 fixed, 2 binary, 3 floating point, 4..N optional); correlated 125-126 (1 no, 2 yes); over travel 179-180 (1 down/behind, 2 up/ahead). [p.16, p.19-20]

### C14 Textual-header encoding — EBCDIC ↔ ASCII (App. F, Table 13, IBM 3270 char set) [p.45-48]

Printable characters (EBCDIC → ASCII):

| EBCDIC | ASCII | Char(s) |
|---|---|---|
| 40 | 20 | space |
| 4A | A2 | ¢ |
| 4B 4C 4D 4E 4F | 2E 3C 28 2B 7C | `. < ( + \|` |
| 50 | 26 | `&` |
| 5A 5B 5C 5D 5E 5F | 21 24 2A 29 3B AC | `! $ * ) ;` ¬ |
| 60 61 | 2D 2F | `- /` |
| 6A | A6 | ¦ (broken bar) |
| 6B 6C 6D 6E 6F | 2C 25 5F 3E 3F | `, % _ > ?` |
| 79 7A 7B 7C 7D 7E 7F | 60 3A 23 40 27 3D 22 | `` ` : # @ ' = " `` |
| 81-89 | 61-69 | a-i |
| 91-99 | 6A-72 | j-r |
| A1 | 7E | `~` |
| A2-A9 | 73-7A | s-z |
| C0 | 7B | `{` |
| C1-C9 | 41-49 | A-I |
| D0 | 7D | `}` |
| D1-D9 | 4A-52 | J-R |
| E0 | 5C | `\` |
| E2-E9 | 53-5A | S-Z |
| F0-F9 | 30-39 | 0-9 |
| (none: listed as x00) | 5B 5D 5E | `[ ] ^` — no EBCDIC code in this table |

Control characters (EBCDIC → ASCII):

| EBCDIC | ASCII | | EBCDIC | ASCII | | EBCDIC | ASCII | | EBCDIC | ASCII |
|---|---|---|---|---|---|---|---|---|---|---|
| 00 | 00 | | 10 | 10 | | 20 | 80 | | 30 | 90 |
| 01 | 01 | | 11 | 11 | | 21 | 81 | | 31 | 91 |
| 02 | 02 | | 12 | 12 | | 22 | 82 | | 32 | 16 |
| 03 | 03 | | 13 | 13 | | 23 | 83 | | 33 | 93 |
| 04 | 9C | | 14 | 9D | | 24 | 84 | | 34 | 94 |
| 05 | 09 | | 15 | 85 | | 25 | 0A | | 35 | 95 |
| 06 | 86 | | 16 | 08 | | 26 | 17 | | 36 | 96 |
| 07 | 7F | | 17 | 87 | | 27 | 1B | | 37 | 04 |
| 08 | 97 | | 18 | 18 | | 28 | 88 | | 38 | 98 |
| 09 | 8D | | 19 | 19 | | 29 | 89 | | 39 | 99 |
| 0A | 8E | | 1A | 92 | | 2A | 8A | | 3A | 9A |
| 0B | 0B | | 1B | 8F | | 2B | 8B | | 3B | 9B |
| 0C | 0C | | 1C | 1C | | 2C | 8C | | 3C | 14 |
| 0D | 0D | | 1D | 1D | | 2D | 05 | | 3D | 15 |
| 0E | 0E | | 1E | 1E | | 2E | 06 | | 3E | 9E |
| 0F | 0F | | 1F | 1F | | 2F | 07 | | 3F | 1A |
| FF | 9F | | | | | | | | | |

> **AMBIGUITY:** [p.45-48] Table 13 is two-column, interleaved by extraction; pairs above were re-associated by row. Oddities kept as printed: `[`, `]`, `^` map to EBCDIC "x00"/"X00" (no code); "DT x07 7F" (missing `x`); "{ xC0 x07B" (=0x7B); "intro x1D x1D" alias row. EBCDIC codes not listed (e.g. 41-49, 51-59, 62-69, 70-78, 80, 8A-90, 9A-A0, AA-BF, CA-CF, DA-DF, E1, EA-EF, FA-FE) have no mapping. See Q2.

## 5. Data sample formats (App. E) [p.42-44]

Bit numbering in App. E: **bit 0 = MSB** of each byte; byte 1 is first in the file. All formats big-endian. Samples of one trace are stored consecutively (demultiplexed: one trace per record), no padding between samples or after the last sample.

### Code 1 — IBM 32-bit hexadecimal float (`ibm32`)

| Byte | bit0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 1 | S | C6 | C5 | C4 | C3 | C2 | C1 | C0 |
| 2 | Q-1 | Q-2 | Q-3 | Q-4 | Q-5 | Q-6 | Q-7 | Q-8 |
| 3 | Q-9 | … | | | | | | Q-16 |
| 4 | Q-17 | Q-18 | Q-19 | Q-20 | Q-21 | Q-22 | Q-23 | 0 (as printed) |

- S: sign, 1 = negative (sign-magnitude).
- C: 7-bit exponent, excess 64, base 16; C ∈ 0..127.
- Q: fraction, radix point left of Q-1 (Q-1 = 2⁻¹).
- value = (−1)^S × 0.Q × 16^(C−64). Equivalently with `w` = u32: `sign = w shr 31; e = (w shr 24) and 0x7F; f = w and 0xFFFFFF; v = ±(f / 2^24) × 16^(e−64)`.
- Must be hex-normalised ("left-justified": first hex digit of the fraction, bits Q-1..Q-4, non-zero) unless value is zero.
- Zero: fraction 0 ⇒ sign and exponent must be 0 (whole word 0x00000000).
- Range: |v| from 16⁻⁶⁵ to (1−2⁻²⁴)×16⁶³; no NaN/Inf.

> **AMBIGUITY:** [p.42-43] The layout shows 23 fraction bits with byte 4 bit 7 forced to 0 ("to guarantee the uniqueness of the start of scan", a SEG-D multiplexed-format relic), and text says "23-bit fraction" and range "1 − 2⁻²³". Standard IBM System/360 single precision has a 24-bit fraction. Recommendation: **decode all 24 bits**; on encode see Q7. Also "16(ccccccc-64)" = 16^(CCCCCCC−64) (superscript lost); "2-1"/"2-23" = 2⁻¹/2⁻²³.

### Code 2 — 32-bit two's complement (`i32`)

| Byte | bit0 | 1-7 |
|---|---|---|
| 1 | S | I30..I24 |
| 2 | I23 | I22..I16 |
| 3 | I15 | I14..I8 |
| 4 | I7 | I6..I0 |

value = two's-complement i32 (S = bit 31).

> **AMBIGUITY:** [p.43] Byte 2 printed as "I22 I22 I21…"; first entry is I23. "Value = S (I30*230 …)" means superscripts 2^30 etc.; S denotes the sign of a two's-complement number, not sign-magnitude.

### Code 3 — 16-bit two's complement (`i16`)

Two bytes: [S I14..I8][I7..I0] (printed as "Byte 3/Byte 4", i.e. the low two bytes of the code-2 diagram). value = i16.

### Code 4 — 32-bit fixed point with gain (obsolete) (`fixedpt`)

| Byte | Content |
|---|---|
| 1 | 0x00 (all bits zero) |
| 2 | G7..G0 — gain exponent, 8 bits |
| 3 | S I14..I8 |
| 4 | I7..I0 |

value = i16(bytes 3-4) × 2^G (as printed: "* 2GGGGGGGG", superscript lost).

> **AMBIGUITY:** [p.43-44] Sign of the gain exponent and whether G is signed are not recoverable from the extraction (printed as a positive superscript). Implement value = mantissa × 2^G with G unsigned 0..255 per the literal text; flag Q8.

### Code 5 — IEEE 754 single (`f32`)

| Byte | bit0 | 1 | … | 7 |
|---|---|---|---|---|
| 1 | S | C7 | … | C1 |
| 2 | C0 | Q-1 | … | Q-7 |
| 3 | Q-8 | … | | Q-15 |
| 4 | Q-16 | … | | Q-23 |

| e (8 bit) | f | value |
|---|---|---|
| 255 | ≠ 0 | NaN (invalid) |
| 255 | 0 | (−1)^s × ∞ (overflow) |
| 1..254 | any | (−1)^s × 2^(e−127) × 1.f |
| 0 | ≠ 0 | (−1)^s × 2^(−126) × 0.f (denormal) |
| 0 | 0 | ±0 |

Note 1 (byte 4 bit 7 must be zero) applies only to SEG-D multiplexed format 0058; SEG-Y is demultiplexed, so bit may be non-zero.

> **AMBIGUITY:** [p.44] Extraction shows "e = 255 & f = 0 → NaN" for both first rows and "f ¹ 0" for denormal; "¹" is the Symbol-font ≠. First row is f ≠ 0. "2e-127" = 2^(e−127), "2e-126" = 2^(−126) (the printed "e-126" for denormals is the standard −126; e = 0). "(0058)/(8058)" are SEG-D format codes.

### Code 8 — 8-bit two's complement (`i8`)

One byte [S I6..I0]; value = i8.

## 6. Derived rules / algorithms

### 6.1 Bytes per sample and trace length [p.23]
| Format | bps |
|---|---|
| 1, 2, 4, 5 | 4 |
| 3 | 2 |
| 8 | 1 |
| 6, 7, other | invalid → error |

traceDataBytes = ns × bps, ns = trace 115-116. traceRecordBytes = 240 + traceDataBytes.

### 6.2 Offsets / reading algorithm (disk) [p.11-12, p.23]
```
read 3200 textual; detect encoding (§6.6)
read 400 binary (file offset 3200)
rev = u16 @3501; fixed = i16 @3503; nExt = i16 @3505
if nExt > 0: skip nExt*3200 bytes (offset 3600 .. 3600+3200*nExt)
if nExt == -1: read 3200-byte records until one whose first line,
   normalised (strip spaces, uppercase), == "((SEG:ENDTEXT))"; that record is the last
if nExt == 0 (incl. rev 0): no extended headers
loop: read 240 header; ns = i16 @115; read ns*bps; repeat until EOF
```
- Fixed-length flag = 1 ⇒ every trace has ns = binary 3221-3222 and dt = 3217-3218 ⇒ random access: offset(trace k, 0-based) = 3600 + 3200·nExt + k·(240 + ns·bps). Not possible when nExt = −1 until EndText found (offset then known).
- Fixed-length flag = 0 ⇒ sequential access only (must read each header). [p.7]
- Varying trace lengths explicitly allowed in rev 1; binary ns/dt describe the primary trace set, not max length [p.6-7].

### 6.3 Scalar application [p.17, p.21, p.22]
```
applyScalar(raw, s): if s > 0: raw*s elif s < 0: raw / abs(s) else raw
```
| Scalar field | Applies to | 0 means |
|---|---|---|
| 69-70 | 41-68 | undefined (treat as 1) |
| 71-72 | 73-88, 181-188 | undefined (treat as 1) |
| 201-202 | 197-200 | not scaled |
| 215-216 | 95-114 (→ ms) | 1 |

Allowed magnitudes for 69-72, 215-216: 1, 10, 100, 1000, 10000.

### 6.4 DMS coordinate encoding (units = 4) [p.17]
| Form | Coordinate value | Coord scalar 71-72 |
|---|---|---|
| ±DDDMMSS | ±(DDD·10⁴ + MM·10² + SS) | 1 |
| ±DDDMMSS.ss | ±(DDD·10⁶ + MM·10⁴ + SS·10²) (incl. hundredths) | −100 |

### 6.5 Engineering conversions [p.21-22]
- physical = sample × (205-208) × 10^(209-210), in units of 211-212.
- source measurement = (225-228) × 10^(229-230), unit 231-232.
- trace weighting: LSB = 2^(−N) V, N = 169-170.

### 6.6 Version / encoding detection
| Check | Rule |
|---|---|
| Revision | 3501-3502: 0x0000 = rev 0; 0x0100 = rev 1.0 (byte 3501 major, 3502 minor/256). [p.11] |
| Rev-0 defaults | When rev = 0: treat 3503-3506 as 0 (no fixed-length guarantee, no extended headers). [p.11-12] |
| Textual encoding | Byte 0 = 0xC3 ⇒ EBCDIC; 0x43 ⇒ ASCII (`C` col 1). [p.26] |
| File start on tape | Tape record starts with textual header `C` and C39 revision. [p.26] |

### 6.7 Tape label (App. B, 128 bytes ASCII, record 1 on tape) [p.24-26]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | ascii | `storageUnitSeqNum` | Integer 1-9999, right-justified, leading blanks, no leading zeros; rightmost char in byte 4. Optional: all blanks ⇒ only storage unit in set. |
| 5-9 | | 5b | ascii | `segyRevision` | `SY1.0` for rev 1. Required. |
| 10-15 | | 6b | ascii | `storageUnitStructure` | Left-justified, trailing blanks; must be `RECORD` for rev 1 (variable-length records up to max block size, any length if that is 0). Required. |
| 16-19 | | 4b | ascii | `bindingEdition` | `B` in byte 16 + integer 1-999, left-justified, trailing blanks, no leading zeros (RP66 Part 3 edition). Required. |
| 20-29 | | 10b | ascii | `maxBlockSize` | Integer 0..4294967295 (2³²−1), right-justified, leading blanks; 0 = undeclared. Rightmost char byte 29. Required (valid value or 0). |
| 30-39 | | 10b | ascii | `producerOrgCode` | Integer 0..4294967295, right-justified, leading blanks; rightmost char byte 39. POSC-assigned. Required. |
| 40-50 | | 11b | ascii | `creationDate` | `dd-MMM-yyyy`; MMM ∈ JAN..DEC; dd 1-31, days 1-9 may have one leading blank; separator `-` (0x2D). Required. |
| 51-62 | | 12b | ascii | `serialNumber` | Enterprise ID; may be all blanks. |
| 63-68 | | 6b | ascii | `reserved` | All blanks (0x20). |
| 69-128 | | 60b | ascii | `storageSetId` | Descriptive name, embedded blanks allowed, must be non-blank (≥1 non-space char); identical across all units of a set. |

Coverage: 4+5+6+4+10+10+11+12+6+60 = 128, contiguous.

> **AMBIGUITY:** [p.25] "(232-1)" = 2³²−1; "code 4510" = 45 decimal (0x2D, hyphen); "code 3210" = 32 decimal (space).

### 6.8 Validation rules (writer must / reader should check)
| Rule | Source |
|---|---|
| 3217-3218, 3221-3222, 3225-3226 non-zero/valid | fn6 [p.9] |
| 3213-3216 set for prestack | fn5 [p.9] |
| 3501-3502 = 0x0100 for rev 1; C39 says `SEG Y REV1` | [p.7, p.11] |
| fixed flag = 1 ⇒ all trace ns/dt equal binary values | [p.11, p.18] |
| nExt = −1 ⇒ EndText record present and last | [p.14] |
| EndText record: header on line 1, rest blank | [p.14] |
| Format code ∈ {1,2,3,4,5,8} | [p.9] |
| Label present iff tape and (optional, or mandatory with App. C blocking) | [p.24, p.26] |
| Big-endian only | [p.6, p.24] |

## 7. Appendix D standard stanzas (keyword tables) [p.27-42]

All keywords required unless noted optional. Formats: Text; Text 60 (≤ 60 chars); Real Number; Integer; enumerated list.

### D-1 Location Data — `((SEG: Location Data ver 1.0))` [p.27-30]
Defines CRS for trace 71-90, 181-188 and vertical reference for 41-70.

| Keyword | Format | Notes |
|---|---|---|
| CRS type | enum: projected / geographic / compound | |
| CRS name | Text | |
| Geodetic Datum name | Text | |
| Prime Meridian name | Text | mandatory if not "Greenwich" |
| PM Greenwich longitude | Real | + east; not required if PM = Greenwich |
| PM Greenwich longitude unit name | Text | not required if PM = Greenwich |
| Ellipsoid name | Text | |
| Ellipsoid semi-major axis | Real | |
| Semi-major axis unit name | Text | |
| Ellipsoid inverse flattening | Real | |
| Coordinate System axis 1 name | Text | axis for 73-76, 81-84, 181-184 |
| CS axis 1 orientation | Text | e.g. east/north |
| Coordinate System axis 2 name | Text | axis for 77-80, 85-88, 185-188 |
| CS axis 2 orientation | Text | |
| Vertical Datum name | Text | not required if ellipsoidal heights |
| Coordinate System axis 3 name | Text | for 41-68 |
| CS axis 3 orientation | Text | e.g. up |
| *Projected CRS only* (units code 1, or Bin Grid / Extent / Perimeter stanza present): | | |
| Projection zone name | Text | |
| Projection method name | Text | e.g. Transverse Mercator, Lambert Conic Conformal (1SP/2SP) |
| Projection parameter n name / value / unit name | Text / Real / Text | n = 1..7 as needed by method (TM, LCC1SP: 5; LCC2SP: 6) |

### D-2 Bin Grid Definition — `((SEG: Bin Grid Definition ver 1.0))` [p.30-33]
I axis is 90° clockwise from J; coordinates given (I, J). Based on UKOOA P6/98 v3.0.

| Keyword | Format |
|---|---|
| Bin grid name | Text |
| Alternate I-Axis description | Text |
| Alternate J-Axis description | Text |
| Bin grid origin I coordinate / J coordinate | Real |
| Bin grid origin Easting / Northing | Real |
| Scale factor of bin grid | Real |
| Scale factor node I coordinate / J coordinate | Real (not required if scale factor = 1) |
| Nominal bin width on I axis / J axis | Real (map grid units) |
| Grid bearing of bin grid J axis | Real (clockwise from grid north) |
| Grid bearing unit name | Text |
| Bin node increment on I axis / J axis | Real |
| First / Second / Third check node I coordinate, J coordinate, Easting, Northing | Real (12 keywords) |

> **AMBIGUITY:** [p.31, p.33] "Alternate I-Axis description" and "Alternate J-Axis description" have no `=` in both table and example, violating `keyword = value`. Parser should tolerate a missing `=` (or treat line as unparsed).

### D-3 Data Geographic Extent — `((SEG: Data Geographic Extent ver 1.0))` [p.36-37]
| Keyword | Format |
|---|---|
| Minimum / Maximum Easting | Real |
| Minimum / Maximum Northing | Real |
| Minimum / Maximum Latitude | Real |
| Minimum / Maximum Longitude | Real |
| Geographical coordinate unit name | Text |
| Minimum / Maximum I coordinate | Real |
| Minimum / Maximum J coordinate | Real |
| Data Extent comment | Text, repeatable |

### D-3 Coverage Perimeter — `((SEG: Coverage Perimeter ver 1.0))` [p.37-39]
| Keyword | Format | Notes |
|---|---|---|
| Coverage type | enum: total / full-fold / null full-fold / null fold | |
| Perimeter coordinate type | enum: `I,J` / `E,N` / `I,J,E,N` | |
| Perimeter node number | Integer | n for n-sided perimeter |
| Perimeter node coordinates | 2 or 4 comma-separated reals | repeated n+1 times (first point repeated at end) |
| Coverage Perimeter comment | Text | repeatable |

Multiple Coverage Perimeter stanzas may appear (one per perimeter) [p.38-39].

### D-4 Data Sample Measurement Unit — `((SEG: Data Sample Measurement Unit ver 1.0))` [p.39-40]
| Keyword | Format | Notes |
|---|---|---|
| Data Sample Measurement Unit | Text 60 | used when 203-204 = −1 |
| Volt conversion | Real | multiplier unit → volts |

### D-5 Processing History — `((SEG: Processing History ver 1.0))` [p.40-41]
Six keywords repeated per processing step: Processing Company (Text 60), Processing Software (Text 60), Input Data Set (Text 60), Processing Date (Text 60, `YYYYMMDD-HHMMSS`), Process Applied (Text 60), Process Parameters (Text 60).

### D-6 Source Type/Orientation — `((SEG: Source Type/Orientation ver 1.0))` [p.41-42]
| Keyword | Format | Notes |
|---|---|---|
| Source description | Text 60 | |
| Source description (continued 1) | Text 60 | |
| Source description (continued 2) | Text 60 | |
| Source type identifier | Negative Integer | value used in trace 217-218 |
One stanza per source type/orientation.

### D-7 Source Measurement Unit — `((SEG: Source Measurement Unit ver 1.0))` [p.42]
| Keyword | Format | Notes |
|---|---|---|
| Source Measurement Unit | Text 60 | used when 231-232 = −1 |
| Joule conversion | Real | multiplier → joules; 0 = not convertible |

> **AMBIGUITY:** [p.14-15, p.40-42] Examples disagree with tables: §6.3 uses `((SEG: Measurement Units ver 1.0))` (D-4 name is "Data Sample Measurement Unit"); D-5 example uses keyword "Processing Applied" (table: "Process Applied"); D-6 example uses "Source description (continued)" twice (table: "(continued 1)", "(continued 2)"); §6.3 example uses "Definer name" (§6 recommends "Stanza Definer"). Tables are taken as normative; readers should be lenient.

> **AMBIGUITY:** [p.12] Stanza names include the version suffix (`ver 1.0`) inside `(( ))`; with space-stripping the canonical key becomes e.g. `SEG:LOCATIONDATAVER1.0`. Whether the version is part of the identity or a separate attribute is not stated; recommend parsing a trailing `ver X.Y` as version.

## 8. Implementation notes

- Header ints are signed (`i16`/`i32`) per spec; only 3501-3502 is unsigned. Provide raw accessors; do not silently reinterpret.
- Use binary 3225-3226 for every trace's sample format (no per-trace format field).
- Prefer trace 115-116 over binary 3221-3222 for data length (required when fixed flag = 0; equal when = 1).
- Rev-0 files: 3501-3506 are 0 (or garbage in non-conforming files); 181-240 may hold vendor data; year may be 2-digit; textual header EBCDIC only.
- Delay recording time (109-110) may be negative.
- Coordinates in degrees (units 3) need a negative coordinate scalar (e.g. −10000) for precision; i32 range limits.
- Extended textual records and the textual header may be EBCDIC or ASCII; detect per block.
- Writer defaults: textual header EBCDIC or ASCII (configurable), C39 `SEG Y REV1`, C40 `END TEXTUAL HEADER`, rev 0x0100, nExt exact count (positive) and optionally EndText.
- Tape: one SEG-Y record per tape record unless App. C blocking; label only on tape.
- IBM↔IEEE conversion loses up to 3 bits precision (hex normalisation) and IBM has larger range; clamp on overflow.

## 9. Open questions

| # | Question | Suggested default |
|---|---|---|
| Q1 | ns (3221-3222, 115-116) and dt (3217-3218, 117-118) are i16; read as u16 to support 32768-65535? | Read as u16 for ns/dt with a flag; write ≤ 32767 for strict mode. |
| Q2 | EBCDIC table lacks `[ ] ^` and many code points. Fallback mapping? | Decode unknown EBCDIC to `?`/space; encode `[ ] ^` via CP037 (0xBA, 0xBB, 0xB0) or substitute; make table pluggable. |
| Q3 | Extended header lines "end in CR LF" yet records are 40×80 = 3200 bytes. Are CR LF inside the 80 columns (cols 79-80) or is the record not strictly 80-col? | Reader: split on 80-byte cards and also strip CR/LF anywhere; writer: 78 text cols + CR LF. |
| Q4 | Layout of 6-byte Source Energy Direction (219-224). | Expose raw 6 bytes + optional 3×i16 view. |
| Q5 | Source Measurement Unit duplicate code 4 (Bar, Bar-meter). | Keep raw value; map 4 → "Bar"; note ambiguity. |
| Q6 | Tape file-mark semantics without App. C blocking are not specified (rev 0 convention: file mark after each SEG-Y file, double at end?). | Treat a file mark as end of SEG-Y file; double mark as end of data, same as App. C. |
| Q7 | IBM float encode: honour "byte 4 bit 7 = 0" (23-bit fraction) or full 24 bits? Rounding mode? | Full 24-bit fraction, round-to-nearest; option for truncation. |
| Q8 | Format 4 gain exponent sign/width. | value = i16 × 2^G, G = u8; mark format 4 read-only/obsolete. |
| Q9 | Coordinate/elevation scalar = 0. | Treat as 1. |
| Q10 | Must extended textual headers use the same encoding as the textual header? | Detect independently. |
| Q11 | Vertical sum code semantics ("N = M−1 sum"). | Store raw. |
| Q12 | Offset (37-40) units/scalar unspecified. | Raw; units per 3255-3256, no scalar. |

## Resolutions (added in the review, task 1.5)
- **Verified on `Sweep0.sgy`** (51,844 B, INOVA, Rev 0, ASCII text, **little-endian**): the
  binary and trace header tables decode correctly when every multi-byte field is byte-swapped.
  Binary: SI 1000 µs, NS 12001, format 5, aux traces 1, units 2 (feet). Trace 1: seq 1/1, FFID 1,
  channel 1, **trace ID 6 (sweep)**, NS 12001, SI 1000, date fields 0. Size 3600 + 240 + 12001×4 = file size.
- **Byte-order detection rule** (owner decision): try big-endian. If the format code (3225-3226) is
  not a known code, or the sample count/interval is implausible, try little-endian. Rev 2 files also
  carry the 3297-3300 marker (see `segy_rev2_1.md`). Store the detected order as metadata. Writers
  default to big-endian.
- **Text encoding detection:** byte 0 = 0x43 ('C' in ASCII) ⇒ ASCII; 0xC3 ⇒ EBCDIC. Sweep0 uses
  ASCII ("C 1 ", with a space instead of a zero pad), so don't require the exact "C01" form.
- Q1 (u16 vs i16 for NS/SI): **read as u16.** Values over 32767 are legal in practice, and Rev 2
  makes them unsigned.
- Q7 (IBM float bits): **24-bit fraction** (implemented in `common/ibmfloat.nim`).
