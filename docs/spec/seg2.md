# SEG-2 (Pullan 1990, version 1) — spec note

Source: `SEG Spec/text/seg_2.txt` (Pullan, S. E., 1990, "Recommended standard for
seismic (/radar) data files in the personal computer environment", Geophysics 55,
1260-1271). `[p.N]` = `=== PAGE N ===` marker (PDF page index = printed "N of 20").

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| 1-3 | Title, introduction, scope, requirements | rules only |
| 3-6 | §III.A file structure, §B1 File Descriptor Block, §B2 Trace Descriptor Block, §B3 Data Block | yes |
| 6-11 | §C string format, §C1 file strings, §C2 trace strings | yes |
| 11-12 | Acknowledgments, references | skipped |
| 13 | App. A definitions (byte/integer/long) | yes (folded into §3 conventions) |
| 14-18 | App. B data formats | yes |
| 19-20 | App. C string sub-block examples | captions only |

Figures 1, 2, 3, B-1..B-5, C-1, C-2 are images and **absent from the text**. All
byte layouts below come from the prose; the prose is complete for every fixed
field.

> **AMBIGUITY:** [p.1-3, p.14-20] Every figure is missing from the text extraction
> (Fig. 1 file layout, Fig. 2 FDB, Fig. 3 TDB, Fig. B-3 the 20-bit packing, Fig. C-1/C-2
> string examples with their offset values). Where a rule depends on a figure it is
> flagged below.

## 2. File structure [p.3]

```
offset 0        File Descriptor Block (FDB)
                  32-byte fixed part
                  Trace Pointer Subblock: M bytes at offset 32 (N used u32 pointers)
                  free-format string list (file strings), offset 32+M
                  (padding to a 4-byte boundary)
ptr[0]          Trace Descriptor Block 1 (TDB): 32-byte fixed part + string list
ptr[0]+tdbSize  Data Block 1 (dataSize bytes)
ptr[1]          TDB 2 ... Data Block 2 ...
...
```

| Rule | Source |
|---|---|
| Order: FDB, then (TDB, Data Block) pairs. One Data Block per TDB, 1:1. ≥ 1 TDB per file. | [p.3, p.5] |
| A Data Block **immediately follows** its TDB. | [p.3] |
| Pointers are unsigned 32-bit byte offsets from the start of the file (not segment:offset). | [p.3] |
| All blocks start on a 4-byte ("double word") boundary; every block size is a multiple of 4. | [p.3, p.4, p.5] |
| A file may be built one trace at a time: append TDB+data, add a pointer, bump N. M is fixed at creation. | [p.4] |
| Disk/tape storage is out of scope; this is a single-file format. | [p.3] |

Conventions in this note (overriding CONVENTIONS.md for SEG-2 only):

- **Bytes are 0-based**, as the spec numbers them ("bytes 0 and 1") [p.4]. Add 1 for
  the usual 1-based convention.
- `u16`/`u32`/`i16`/`i32`/`f32`/`f64` mean **file byte order** (set by the FDB
  block ID, §5), not big-endian.
- Integer = 16 bit, long integer = 32 bit, byte = 8 bit [p.13].

## 3. Header tables

### 3.1 File Descriptor Block, fixed part (32 bytes) [p.3-4]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 0-1 | | 2b | u16 | `blockId` | `0x3A55`. Identifies SEG-2, this block, and the byte order: first byte `0x55` = little-endian (PC); first byte `0x3A` = big-endian (68000 UNIX). Mandatory. |
| 2-3 | | 2b | u16 | `revision` | Revision of the standard. This paper = **1**. |
| 4-5 | | 2b | u16 | `tracePointerBytes` (M) | Size of the Trace Pointer Subblock in bytes. 4 ≤ M ≤ 65532, M mod 4 = 0. |
| 6-7 | | 2b | u16 | `numTraces` (N) | Number of traces (pointers in use). 1 ≤ N ≤ 16383, N ≤ M/4. |
| 8 | | 1b | u8 | `stringTermLen` | 1 or 2: number of String Terminator chars. |
| 9-10 | | 2b | ascii | `stringTerm` | String Terminator: 1-2 chars, each ASCII 0-31. If 1 char, it is in byte 9 (byte 10 unused). |
| 11 | | 1b | u8 | `lineTermLen` | 1 or 2: number of Line Terminator chars. |
| 12-13 | | 2b | ascii | `lineTerm` | Line Terminator (separates lines inside NOTE): 1-2 chars, ASCII 0-31, normally CR or CR LF. If 1 char, it is in byte 12. |
| 14-31 | | 18b | — | `reserved` | Reserved. Write 0. |

> **AMBIGUITY:** [p.4] Bytes 6-7: the text says "N is an unsigned integer" but does not
> say explicitly "bytes 6 and 7 contain N" in the B1 list; it is implied twice ("specified
> in bytes 6 and 7"). Treat as u16.

> **AMBIGUITY:** [p.4] Whether byte 10 / byte 13 must be 0 when only one terminator
> char is used is not stated. Readers must ignore it; writers should write 0.

### 3.2 Trace Pointer Subblock [p.4]

| Bytes | Len | Enc | Field | Meaning |
|---|---|---|---|---|
| 32 + 4i .. 35 + 4i | 4b | u32 | `tracePointers[i]` | File offset of TDB i (i = 0..N-1). Slots N..M/4-1 are unused (content undefined; write 0). |

### 3.3 File string list [p.4-5, p.6]

Starts at byte `32 + M` and runs to the `0` end marker (§3.6). Contents: §4.1.

### 3.4 Trace Descriptor Block, fixed part (32 bytes) [p.5-6]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 0-1 | | 2b | u16 | `blockId` | `0x4422`. Mandatory. In a little-endian file the bytes are `22 44`. |
| 2-3 | | 2b | u16 | `blockSize` | Size of this TDB in bytes (fixed part + strings + padding). 32 ≤ x ≤ 65532, x mod 4 = 0. |
| 4-7 | | 4b | u32 | `dataSize` | Size of the following Data Block in bytes. Multiple of 4. |
| 8-11 | | 4b | u32 | `numSamples` | Number of samples in the Data Block. |
| 12 | | 1b | u8 | `dataFormat` | Sample format code (§4.4). |
| 13-31 | | 19b | — | `reserved` | Reserved. Write 0. |

Strings start at TDB byte 32 (§3.6, §4.2). The Data Block starts at
`tracePointer + blockSize` [p.3, p.5].

### 3.5 Data Block [p.6]

`numSamples` samples of `dataFormat`, contiguous, in file byte order (App. B). No header.

### 3.6 String encoding [p.4-6, p.19]

Each entry in a string list:

| Bytes (rel.) | Len | Enc | Field | Meaning |
|---|---|---|---|---|
| 0-1 | 2b | u16 | `nextOffset` | Offset to the next string. `0` = end of list (no keyword follows). |
| 2 .. | var | ascii | `text` | `KEYWORD<sp/tab>value(s)`, then the String Terminator (1-2 chars). |

Rules:

| Rule | Source |
|---|---|
| List ends with a 2-byte `0` offset after the last string. | [p.6] |
| Keyword: no embedded spaces, uppercase, words joined by `_` (ASCII 95). | [p.6, p.7] |
| Keyword and value(s) separated by spaces or tabs (one or more). | [p.6] |
| Values chosen from a word list: uppercase, no embedded spaces. | [p.6] |
| Strings sorted alphabetically by keyword; `NOTE` (if present) is always last. | [p.6, p.7] |
| Every string is optional; unknown keywords must not stop the reader. | [p.6] |
| Terminators are ASCII 0-31 so they cannot clash with printable values. | [p.4] |
| NOTE may span lines, separated by the Line Terminator; it ends with the String Terminator. | [p.7-8] |
| App. C example: String Terminator = NUL (`00`), Line Terminator = LF CR (`0A 0D`). | [p.19] |

> **AMBIGUITY:** [p.6, p.19] The base of `nextOffset` is not stated in the text (Fig. C-1 shows
> it, but is an image). Common practice (ObsPy, vendor files): it is the **length of the whole
> entry including its own 2 bytes**, i.e. next entry at `entryStart + nextOffset`; the text is
> `bytes[entryStart+2 ..< entryStart+nextOffset]` with the terminator and any trailing pad
> stripped. Readers should use this and tolerate trailing NUL/terminator padding inside an entry.

> **AMBIGUITY:** [p.3, p.6] Whether individual strings are padded/aligned is not stated; only
> *blocks* must be 4-aligned. Writers: pack strings, then pad the end of the whole block
> (after the `0` marker) with zeros to a multiple of 4. For the FDB, pad so that `ptr[0]`
> is 4-aligned.

Numeric values [p.6, p.13]:

| Kind | Syntax | Examples |
|---|---|---|
| decimal integer | `-?[0-9]+`; magnitude < 32768 unless stated otherwise | `12`, `-3` |
| decimal float | `-?digits[.digits][E[-]digits]`; a `.` must be followed by a digit | `12.657`, `-34.6`, `1.345E24`, `5.6E-11`, `-2.0E-9` |

## 4. Code tables

### 4.1 File Descriptor strings (C1) [p.7-8]

`*` = "likely required by application software; strongly recommended" [p.7].

| Keyword | Value syntax | Units | Meaning |
|---|---|---|---|
| `ACQUISITION_DATE` | date | — | Acquisition date. Recommended `dd/mm/yyyy`, or `dd/MMM/yyyy` (MMM = 3-letter month, e.g. `01/APR/1988`). |
| `ACQUISITION_TIME` | time | — | Acquisition time, 24-hour `hh:mm:ss` (`15:30:00`). |
| `CLIENT` | name | — | Organization sponsoring acquisition/processing. |
| `COMPANY` | name | — | Company acquiring and/or processing the data. |
| `GENERAL_CONSTANT` | value | — | Positive decimal number, ≤ 12 digits. |
| `INSTRUMENT` | `<manufacturer> <model> <serial>` | — | Acquisition instrument. |
| `JOB_ID` | string | — | Any printable ASCII (32-126). |
| `OBSERVER` | name | — | Person responsible for acquisition. |
| `PROCESSING_DATE` | date | — | Creation date of a processed file (format as ACQUISITION_DATE). |
| `PROCESSING_TIME` | time | — | Creation time of a processed file (format as ACQUISITION_TIME). |
| `*TRACE_SORT` | enum | — | `AS_ACQUIRED`, `CDP_GATHER`, `CDP_STACK`, `COMMON_OFFSET`, `COMMON_RECEIVER`, `COMMON_SOURCE`. |
| `*UNITS` | enum | — | Linear units for the whole file: `FEET`, `METERS`, `INCHES`, `CENTIMETERS`, `NONE` (user interprets). |
| `NOTE` | multi-line text | — | Free notes; always last (§3.6). |

> **AMBIGUITY:** [p.7] ACQUISITION_DATE says "dd/mm/yyyy" but its own example is `01/04/88`
> (2-digit year). Parse 2- and 4-digit years, numeric or 3-letter month; keep the raw string.

### 4.2 Trace Descriptor strings (C2) [p.8-11]

| Keyword | Value syntax | Units | Meaning |
|---|---|---|---|
| `ALIAS_FILTER` | `<freq> <slope>` | Hz, dB/oct | Anti-alias filter 3 dB point. freq 0 = not applied. |
| `AMPLITUDE_RECOVERY` | `<method> [params…]` | — | `NONE`, `AGC`, `SPHERICAL_DIVERGENCE` or free description; method mandatory if keyword present; params e.g. AGC window. |
| `BAND_REJECT_FILTER` | `<lp freq> <lp slope> <hp freq> <hp slope>` | Hz, dB/oct | Analog band-reject applied by the seismograph. freqs 0 = not applied. |
| `CDP_NUMBER` | int | — | CDP gather / stacked trace number. |
| `CDP_TRACE` | positive int | — | Trace number within the CDP gather, starting at 1. |
| `CHANNEL_NUMBER` | positive int < 32768 | — | Recording channel. If used in one TDB, must be in all. Several Data Blocks may share a channel (switched rates, time gaps); they must be in time order and not overlap. |
| `DATUM` | number | UNITS | Elevation (w.r.t. mean sea level) that source/receiver z values refer to. |
| `*DELAY` | float | s | Time from start pulse to the first sample. |
| `DESCALING_FACTOR` | float | mV/count | `voltage(mV, one shot) = sample × DESCALING_FACTOR / STACK`. |
| `DIGITAL_BAND_REJECT_FILTER` | `<lp freq> <lp slope> <hp freq> <hp slope>` | Hz, dB/oct | Digital band-reject applied after acquisition / in processing. 0 = not applied. |
| `DIGITAL_HIGH_CUT_FILTER` | `<freq> <slope>` | Hz, dB/oct | Digital high-cut, post-acquisition. 0 = not applied. |
| `DIGITAL_LOW_CUT_FILTER` | `<freq> <slope>` | Hz, dB/oct | Digital low-cut, post-acquisition. 0 = not applied. |
| `END_OF_GROUP` | `0` or `1` | — | 1 = last trace of a user-defined group/sort. |
| `FIXED_GAIN` | int | dB | Fixed gain incl. preamp applied by a fixed-gain instrument. |
| `HIGH_CUT_FILTER` | `<freq> <slope>` | Hz, dB/oct | Analog high-cut applied in acquisition. 0 = not applied. |
| `LINE_ID` | string | — | Any printable ASCII (32-126). |
| `LOW_CUT_FILTER` | `<freq> <slope>` | Hz, dB/oct | Analog low-cut applied in acquisition. 0 = not applied. |
| `NOTCH_FREQUENCY` | number ≥ 0 | Hz | Notch filter. 0 = not applied. |
| `POLARITY` | `1` or `-1` | — | Sign of the sample for upward ground motion at the phone. |
| `RAW_RECORD` | file name | — | Raw file (name + extension) this trace came from. |
| `RECEIVER` | `<type> [<count>]` | — | `VERTICAL_GEOPHONE`, `SH_HORIZONTAL_GEOPHONE`, `SV_HORIZONTAL_GEOPHONE`, `ACCELEROMETER`, `ANTENNA` or free; optional receivers per group. |
| `RECEIVER_GEOMETRY` | `[n] <x> [<y> <z>]` | UNITS | Position of the nth receiver of the group relative to RECEIVER_LOCATION. |
| `*RECEIVER_LOCATION` | `<x> [<y> <z>]` | UNITS | Receiver / group centre relative to start of line or a user point. 1 value = x along line; else all 3. z: + up, − down, relative to DATUM. |
| `RECEIVER_SPECS` | `<manufacturer> <model or freq>` | — | Receiver make/model/natural frequency. |
| `RECEIVER_STATION_NUMBER` | int | — | Station number of the receiver location. |
| `*SAMPLE_INTERVAL` | float | s | Sample period. |
| `SHOT_SEQUENCE_NUMBER` | positive int | — | User ordering of field files/traces. |
| `SKEW` | float | s | Delay between scan start and acquisition on this channel. |
| `SOURCE` | `<type> [params…]` | — | `HAMMER`, `WEIGHT_DROP`, `GUN`, `DYNAMITE`, `VIBRATOR` or free; params = size, charge, sweep… |
| `SOURCE_GEOMETRY` | `[n/N] <x> [<y> <z>]` | UNITS | Position of element n of an N-element source array relative to SOURCE_LOCATION. |
| `SOURCE_LOCATION` | `<x> [<y> <z>]` | UNITS | Source / array centre relative to start of line or a user point. Same 1-or-3 value and z rules as RECEIVER_LOCATION. |
| `SOURCE_STATION_NUMBER` | int | — | Station number of the source location. |
| `STACK` | positive int | — | Number of shots summed into this trace. |
| `STATIC_CORRECTIONS` | `<src> <rcv> <total applied>` | s | Statics attributed to source and receiver, and total applied to this Data Block (0 = none applied). |
| `TRACE_TYPE` | enum | — | `SEISMIC_DATA`, `DEAD`, `TEST_DATA`, `UPHOLE`, `RADAR_DATA`. |
| `NOTE` | multi-line text | — | As in C1; last. |

> **AMBIGUITY:** [p.10, p.11] Only `RECEIVER_LOCATION`, `DELAY`, `SAMPLE_INTERVAL` are
> starred in the extracted text; the asterisk on `SOURCE_LOCATION` may have been lost in
> extraction. Treat SOURCE_LOCATION as recommended anyway.

> **AMBIGUITY:** [p.10, p.11] `RECEIVER_GEOMETRY [n]` / `SOURCE_GEOMETRY [n/N]`: whether the
> brackets are literal characters or "optional" notation is unclear without Fig. C-2. Parse
> both `[3] x y z` and `3 x y z` (and `[2/4]`, `2/4`).

> **AMBIGUITY:** [p.6] "integers must have magnitude < 32768 unless stated otherwise":
> station numbers, CDP numbers, shot sequence numbers routinely exceed this in practice.
> Parse integers as int64 (or float64) and don't reject large values.

### 4.3 Recommended / likely-required strings

FDB: `TRACE_SORT`, `UNITS`. TDB: `DELAY`, `RECEIVER_LOCATION`, `SAMPLE_INTERVAL`
(+ `SOURCE_LOCATION`, see above). [p.7, p.9-10]

### 4.4 Data format codes (TDB byte 12) [p.6]

| Code | Format | Bytes/sample | Fixed point convention |
|---|---|---|---|
| `0x01` | 16-bit fixed point (integer) | 2 | two's complement |
| `0x02` | 32-bit fixed point (integer) | 4 | two's complement |
| `0x03` | 20-bit floating point (SEG-D based) | 2.5 (10 bytes / 4 samples) | — |
| `0x04` | 32-bit IEEE 754 float | 4 | — |
| `0x05` | 64-bit IEEE 754 float | 8 | — |

Any other code: unsupported (no other codes defined).

## 5. Data sample formats [p.14-18]

Every multibyte unit below is stored in file byte order (block ID). "LB first or HB first is
dependent on the first two bytes of the FDB" [p.14, p.16, p.17].

| Code | Layout (value bits, msb→lsb) | Decode |
|---|---|---|
| 1 | `S QD×15` in one 16-bit word; radix right of lsb [p.15] | `i16`; range −32768..32767 |
| 2 | `S QD×31` in one 32-bit word [p.15] | `i32`; range −2147483648..2147483647 |
| 4 | `S C×8 F×23` [p.17] | IEEE single: `(-1)^S × 1.F × 2^(C−127)`; C=0,F=0 → 0; C=0,F≠0 → "underflow" (denormal); C=255,F=0 → ∞; C=255,F≠0 → NaN [p.18] |
| 5 | `S C×11 F×52` [p.18] | IEEE double, bias 1023, same special cases |

### 5.1 Format 3: 20-bit floating point [p.15-17]

Group of 10 bytes = 4 samples:

| Group bytes | Unit | Content |
|---|---|---|
| 0-1 | 16-bit word E (file order) | Exponents: sample 1 = bits 0-3 (low nibble of the **low** byte), sample 2 = bits 4-7, sample 3 = bits 8-11, sample 4 = bits 12-15. Each `C` = 0..15. |
| 2-3 | 16-bit word (file order) | Sample 1 mantissa |
| 4-5 | 16-bit word | Sample 2 mantissa |
| 6-7 | 16-bit word | Sample 3 mantissa |
| 8-9 | 16-bit word | Sample 4 mantissa |

Mantissa word: bit 15 = sign S (1 = negative), bits 14-0 = 15-bit magnitude, **one's
complement**; radix point right of the lsb (lsb = 2^0) — a scaled **integer**, not a fraction
as in SEG-D 8015. Range −32767..32767; negative zero (`0xFFFF`) invalid, write as +0.

```
e = (E shr (4*k)) and 0xF          # k = 0..3 within the group
w = mantissa word k
m = if (w and 0x8000) != 0: -int((not w) and 0x7FFF) else: int(w)   # one's complement
value = m * 2^e                    # max |value| = 32767 * 2^15 ≈ 2^30
```

- `numSamples` must be a multiple of 4 [p.17].
- Data bytes = `numSamples div 4 * 10` (then the Data Block is padded to a multiple of 4).

> **AMBIGUITY:** [p.16] Fig. B-3 (the bit picture) is missing. The prose fixes the exponent
> nibble order ("first sample in bits 0-3 of the low byte") and the integer scaling, which
> **differ from SEG-D 8015** (8015: exponents in BCD-like nibble order from the high nibble of
> byte 0, fraction /2^15). Do not reuse the `sd8015` decoder as-is: the exponent order and
> scale differ, the mantissa sign rule (one's complement) is the same. "One's complement" is
> ambiguous vs. sign-magnitude for the 15 bits; the stated range (±32767, −0 invalid) fits
> both. Offer a `twosComplement` switch like `twosComplement8015`, since some writers may use
> two's complement. Verify against a real format-3 file before trusting either.

## 6. Derived rules / algorithms

### 6.1 Detection (first bytes)

| Bytes 0-1 | Result |
|---|---|
| `55 3A` | SEG-2, little-endian |
| `3A 55` | SEG-2, big-endian |
| anything else | not SEG-2 |

Strengthen (the 2-byte magic is weak): `revision` small (1; accept ≤ 10?), `M` in 4..65532
and `M mod 4 = 0`, `1 ≤ N ≤ M/4`, `stringTermLen` and `lineTermLen` in {1, 2}, terminator chars
in 0..31, and `ptr[0]` ≥ `32 + M`, `ptr[0] mod 4 = 0`, and the u16 at `ptr[0]` = `0x4422`.
No clash with SEG-Y (byte 0 is EBCDIC `C` = 0xC3 or ASCII `C`) or SEG-D (BCD file number).

### 6.2 Offsets and sizes

| Quantity | Formula |
|---|---|
| Trace pointer i | `u32 @ 32 + 4i`, i < N |
| File strings | from `32 + M` to the `0` end marker; must end ≤ min(ptr) |
| TDB i strings | `[ptr[i] + 32, ptr[i] + blockSize)` |
| Data Block i | offset `ptr[i] + blockSize`, length `dataSize` |
| Payload bytes | f1: `2n`; f2: `4n`; f3: `10·n/4`; f4: `4n`; f5: `8n` |
| Data padding | `dataSize = roundUp4(payload)`; reader uses `numSamples`, not `dataSize`, for sample count |
| Next TDB (sequential writer) | `ptr[i+1] = ptr[i] + blockSize + dataSize` |
| Limits | N ≤ 16383; TDB ≤ 65532 bytes (so trace strings ≤ 65500 bytes); FDB fixed+pointers ≤ 32+65532 |

### 6.3 Validation (reader)

| Check | Severity |
|---|---|
| block ID `0x3A55` / `0x4422` | fatal / trace error |
| M, TDB size, dataSize multiples of 4; ranges in §3 | warning (tolerate) |
| N > M/4 | error; clamp to M/4 |
| pointer beyond EOF, not 4-aligned, or overlapping another block | trace error |
| `dataSize < payload(numSamples, format)` | truncated: decode `dataSize` worth |
| format code ∉ 1..5 | unsupported trace (index it, don't decode) |
| format 3 and `numSamples mod 4 ≠ 0` | warning (same as SEG-D 8015 path) |
| string `nextOffset` runs past block end, or < 2 | stop parsing that list, warn |
| keywords out of order, lowercase, NOTE not last | info only (vendors violate it) |
| `CHANNEL_NUMBER` present in some TDBs only | warning |

### 6.4 Writer

1. Choose byte order (default little-endian, as on PC), M = roundUp4(4·N) (or larger to
   allow appending), String Terminator = `00` (len 1), Line Terminator = `0D 0A` or `0A`.
2. FDB: fixed 32 bytes, pointers, sorted strings, NOTE last, `00 00` end, zero-pad to 4.
3. Per trace: TDB (fixed 32 + sorted strings + `00 00` + pad), `blockSize` = total; data
   padded to 4; `dataSize` = padded length.
4. Always write `SAMPLE_INTERVAL`, `DELAY`, `RECEIVER_LOCATION`, `SOURCE_LOCATION`,
   `CHANNEL_NUMBER` (in every TDB), FDB `UNITS`, `TRACE_SORT`.
5. Floats: shortest round-trip decimal (`$`), but never `1.` or `.5` (digit after the point,
   digit before is customary) — exponent form `1.5E-4` allowed.

## 7. Implementation notes

### 7.1 Model

Follow the per-standard pattern (`segy/` → `SegyFile`, `segd/` → `SegdRecord`):

```nim
# src/parseSEG/seg2/{headers,reader,writer,samples}.nim
type
  Seg2Format* = enum s2I16 = 1, s2I32 = 2, s2Float20 = 3, s2F32 = 4, s2F64 = 5
  Seg2String* = object
    key*: string          # keyword as written (uppercase per spec; keep case)
    value*: string        # raw text after the separator, terminators stripped
  Seg2File* = object
    order*: ByteOrder     # from the block ID
    revision*: uint16
    pointerBytes*: uint16 # M
    stringTerm*, lineTerm*: string
    pointers*: seq[uint32]
    strings*: seq[Seg2String]          # FDB list, in file order
  Seg2Trace* = object
    offset*: int64        # TDB offset
    blockSize*: uint16
    dataSize*, numSamples*: uint32
    format*: uint8        # raw code; Seg2Format when 1..5
    strings*: seq[Seg2String]
```

- Keep **all** strings as raw ordered `(key, value)` pairs; add typed getters
  (`sampleInterval`, `delay`, `receiverLocation`, …) on top. Vendor files (Geometrics,
  Geospace, OYO, etc.) add non-standard keywords and sometimes unsorted / mixed-case lists;
  preserve them verbatim for round-trip, and have the writer keep their order unless asked to
  sort.
- `openSeismic`: add `skSeg2 = "SEG-2"` to `SeismicKind`; extend `detectKind` (§6.1) and
  `buildIndex`. SEG-2 is a random-access file: the index is just the pointer table, so
  `TraceEntry.offset` = TDB offset, `headerBytes` = `blockSize`, `numSamples` as read. Format is
  per trace (not per file/record), so either one `TraceCodec` per distinct (format, order) pair
  with `TraceEntry.record` indexing it, or a per-trace codec. Sample intervals may also differ
  per trace (switched rates); `maxSamples` handles lengths.
- Tape/`RecordSource` streaming is unnecessary (SEG-2 is a disk format) but a sequential
  reader still works if pointers are ascending; random pointer order must be supported.
- Sample decode: formats 1, 2, 4, 5 are plain `getNum[T](…, order)` (`common/endians`).
  Format 3 needs its own decoder (§5.1).

### 7.2 TraceKeys mapping (`model/keys.nim`)

| TraceKeys field | SEG-2 source |
|---|---|
| `record` | `SHOT_SEQUENCE_NUMBER`, else a number parsed from `RAW_RECORD` / vendor file-number key, else NaN |
| `ensemble` | `CDP_NUMBER` |
| `offset` | none standard → `deriveGeometry` from x/y; if only x known (1-value location), `abs(rcvX − srcX)` |
| `srcPoint` | `SOURCE_STATION_NUMBER` |
| `srcX`, `srcY`, `srcZ` | `SOURCE_LOCATION` x [y z] (`srcY` = 0 when a single value is given, so 2-D lines still have offsets) |
| `rcvPoint` | `RECEIVER_STATION_NUMBER` |
| `rcvX`, `rcvY`, `rcvZ` | `RECEIVER_LOCATION` x [y z] |
| `srcLine`, `rcvLine` | `LINE_ID` if numeric (FDB has no LINE_ID; it is a trace string) |
| `cmpX`, `cmpY` | derived |
| `component` | from `RECEIVER` type, reusing SEG-Y trace ID codes: `VERTICAL_GEOPHONE` → 12 (vertical); `SH_`/`SV_HORIZONTAL_GEOPHONE` → 13/14 (which is crossline vs inline is a choice); else 0 |
| `sensorType`, indices | 0 |

- Coordinates are in FDB `UNITS`; z is relative to `DATUM` (add DATUM for absolute
  elevation). `UNITS NONE` → keep values, flag as unitless.
- Per-trace sample interval comes from `SAMPLE_INTERVAL` (seconds → µs for SEG-Y conversion);
  `DELAY` → SEG-Y delay recording time (ms).
- `DESCALING_FACTOR`/`STACK` give mV; a converter may scale or record them as metadata.
- `CHANNEL_NUMBER` → trace sequence within record / SEG-Y channel.

### 7.3 Gotchas

- 0-based byte numbering in the spec, unlike SEG-Y/SEG-D notes.
- Whole file, including sample data and string offsets, follows the block-ID byte order;
  little-endian is the norm. Only the ASCII text is order-independent.
- TDB sizes are u16 → strings capped at ~64 KB per trace; data size is u32.
- `numSamples` and `dataSize` can disagree (padding); trust `numSamples`, bound by `dataSize`.
- NOTE text contains Line Terminators and may contain spaces/tabs freely.
- Terminator chars may be NUL; don't use C-string functions on string entries.

## 8. Open questions

1. String `nextOffset` base (§3.6): assume "entry length incl. the 2 offset bytes"; confirm on a
   Geospace file.
2. Format 3 exponent nibble order, sign convention and scale (§5.1): confirm on a real file;
   expose a two's-complement switch?
3. Writer default: sort strings alphabetically (spec) vs. preserve input order (round-trip).
4. Accept revisions other than 1? (No later SEG-2 revision exists in `SEG Spec/text/`.)
5. Per-trace formats / sample intervals in one file: how to expose in the tensor API (resample
   or reject mixed intervals?).
6. Should `TRACE_TYPE DEAD` / `TEST_DATA` map to SEG-Y trace ID codes 2/… on conversion, and
   `POLARITY` -1 flip samples or be recorded?
7. Date parsing: `dd/mm/yy[yy]` vs `dd/MMM/yyyy`; vendors also write `mm/dd/yyyy` — keep raw.
