# SEG-D Rev 0 (original SEG-D, c. 1980): full note + delta vs Rev 2.0

Source: `SEG Spec/text/Digital field tape format standards - SEG-D.txt`. `[p.N]` = `=== PAGE N ===`
marker of that file (printed page "N of 36").

**Citation.** The title is "Digital field tape format standards — SEG-D", by the SEG Subcommittee on
Digital Tape Formats (D. A. Cavers, chairman; members from Gulf, TI, Chevron, Litton, Input/Output, GUS,
Texaco) [p.1]. The text's own header line [p.1] says it was "converted from: Barry, K. M., Cavers, D. A.
and Kneale, C. W., 1975, … Geophysics, 40, no. 02, 344-352", and the footnote says "© 1975". **Both are
wrong**: that is the SEG-Y Rev 0 paper (same header as `SEG-Y Rev 0.txt`), and this document cites that
paper itself as "Barry et al, 1975" [p.1, p.13]. Internal evidence dates it to **1979 or later**: it cites
ANSI X3.54-1976 and Dampney et al. 1978 [p.13], and the manufacturer list refers to "the latest edition of
the Geophysical Directory (1979)" [p.26]. (Outside knowledge, not in the text: SEG-D was published in
*Geophysics* vol. 45, 1980.) This note calls it **SEG-D Rev 0**: Rev 1 (1994) and Rev 2.0 (1996) list their
changes against it (`segd_rev2_0.md` §7.3-7.4).

Bit numbering, as in all SEG-D: **bit 0 = MSB, bit 7 = LSB** (the trace header and SOS tables [p.4-5]
show it). `H` = bits 0-3 (`b shr 4`), `L` = bits 4-7 (`b and 0x0F`). "All header information is packed
BCD unless otherwise specified, with bit positions 0-3 being the most significant digit" [p.2, p.21].

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| p.1-2 | Abstract, introduction, general format requirements (1)-(10) | yes (§2, §7) |
| p.2-3 | Format overview: tape layout, header block, scan type header ground rules, extended/external headers | yes (§2, §3) |
| p.3-4 | Multiplexed data: gapped/gapless, start-of-scan code, timing word | yes (§2.3, §3.6) |
| p.4-5 | Demultiplexed data: trace blocks, 20-byte trace header | yes (§3.7) |
| p.5-9 | Data recording methods (sample formats) | yes (§5) |
| p.10-12 | Examples: header lengths, multiplexed and demultiplexed order | yes (§6.4) |
| p.13 | References | used for the date only |
| p.14-20 | **Figures 1-9: image-only** (only page numbers extracted) | not recoverable; App. A covers every header byte |
| p.21-23 | App. A: general header | yes (§3.1) |
| p.23-25 | App. A: scan type header / channel set descriptor | yes (§3.3, §3.4) |
| p.26 | App. B: manufacturer codes | compact table (§4.6) |
| p.27 | App. C: glossary | definitions used in §2 |
| p.28-29 | App. D: header descriptor abbreviations | checked against App. A, consistent |
| p.30-36 | App. E: sample calculations E1-E10 | yes (§6) |

> **AMBIGUITY [p.14-20]:** Figures 1 (record structure), 2 (multiplexed block), 3 (demultiplexed block),
> 4 (general header bit table), 5 (channel set descriptor bit table), 6A-C and 7A-C (example headers),
> 8 (start of scan / timing word) and 9 (trace header) are images. The App. A parameter lists, the prose
> bit tables on [p.4-5] and the worked examples give every byte; nothing below depends on the figures.

## 2. File / tape structure

### 2.1 Tape layout [p.2]

```
Leader, BOT
Seismic record file 1      (header block, IBG, data blocks)
EOF
Seismic record file 2
EOF
...
Seismic record file n
EOF
EOF                        (two EOFs: no more records on the tape)
EOT, trailer
```

- Medium: 9-track ½" tape (800 / 1600 bpi per ANSI X3.22 / X3.39); 6250 bpi allowed if ANSI X3.54
  compatible [p.1 req. 1]. **No storage unit label** (introduced in Rev 2).
- One record = one **file** = all blocks between file marks ("File: all data recorded from a single energy
  impulse or sweep … or the sum of a number of them" [p.27]). Records separated by one EOF; two EOFs = end
  of data [p.2].
- Multiplexed and demultiplexed records **may share a reel**, but the data recording method (word format)
  **may not change** on a reel [p.3 rule 5].
- Block = "the data between gaps on tape" [p.27]; the reader of a disk image loses these boundaries.

### 2.2 Record = header block + data [p.2-3]

```
Header block (ONE tape block, followed by an IBG):
  General header                32 B           (exactly one; no General Header #2)
  Scan type header 1:
      Channel set descriptor 1..CS   32 B each
      Sample skew fields 1..SK       32 B each
  Scan type header 2..ST/R           (same shape, same CS count)
  Extended header                EC × 32 B   (optional, manufacturer-defined)
  External header                EX × 32 B   (optional, user-defined)
Data: either
  multiplexed:   one block (gapless) or N blocks of S/B × 2^S/BX scans each (gapped)   §2.3
  demultiplexed: one tape block per trace (20 B trace header + samples)                §2.4
```

Header length [p.31, App. E4]: `HL = 32 × [ST/R × (CS + SK) + 1 + EC + EX]` bytes (the "+1" is the single
general header).

There are **no** general trailer blocks, trace header extensions, source/receiver position blocks or
extended (`FF`/`FFFF`) count fields in Rev 0.

### 2.3 Multiplexed data body [p.3-4, p.11]

- **Gapless** (GH1 byte 25 S/B = 0): the whole data body is one block after the header block's IBG,
  "divided into an integral number of scans".
- **Gapped** (S/B ≠ 0): each block holds exactly `S/B × 2^S/BX` scans and **must begin with a start of
  scan** (GH1 bytes 24L-25, §3.1; E9). Valid only for multiplexed data.
- **Scan** (one base scan interval) =

```
bytes 1-4   start-of-scan code (SOS)          §3.6
bytes 5-8   timing word                       §3.6
then, for channel set 1..CS of the current scan type (descriptor order):
    for subscan 1..2^(S/C):                   (S/C = CSD byte 12H)
        for channel 1..C/S:                    (C/S = CSD bytes 9-10)
            one sample in the record's format
```

  "All four subscans of channel set 2 are recorded before the four subscans of channel set 3"; a subscan
  "contains one sample from each channel" [p.11 Example 6]. For format 0015, each subscan of a channel set
  is a sequence of 10-byte groups of 4 channels (§5.1), so C/S must be a multiple of 4 [p.7].
- **Bytes per scan** (GH1 bytes 20-22, BCD) `B = 8 + Σ_cs C/S × 2^(S/C) × bytes/sample` [p.30 E2]. It is
  the same for every scan type of a record [p.3 rule 4].
- **Scan types**: all scans of scan type 1 come first, then all of scan type 2, etc. ("this scan type
  follows the recording of all of scan type 1" [p.12]). The DP bit in the SOS toggles at each scan type
  change (§3.6). Channel sets that are unused in a scan type have dummy descriptors (C/S = 0) and
  contribute no bytes.

> **AMBIGUITY [p.3-4, p.24]:** the number of scans of each scan type is not stated. It follows from the
> channel set start/end times (CSD bytes 3-6, all channel sets of a multiplexed scan type have the same
> length [p.24]) and the base scan interval: `scans = (TE − TF) × 2 ms / BSI`; whether the end time is
> inclusive (+1 scan) is not specified. A reader can instead walk SOS codes until the EOF.

### 2.4 Demultiplexed data body [p.4, p.12]

- One **trace block** per channel per scan type: 20-byte trace header + samples, written as **one tape
  block** with an IBG after it [p.4]. The trace length is therefore the tape block length.
- Order: for scan type 1..ST/R, for channel set 1..CS (descriptor order), for channel 1..C/S. Dummy channel
  sets give no traces. "Each new channel set starts with trace number 1" [p.12].
- Total trace blocks = Σ over scan types and channel sets of C/S [p.12 examples: 28, 28, 244, 64, 68, 68].
- Same header block as the multiplexed equivalent except format code (bytes 3-4) and bytes per scan
  (20-22 = 0) [p.4].
- "A trace is restricted to one channel of data from one channel set of one scan type" [p.4]; "trace
  block: a block containing the data of one trace **or a part of a trace with constant parameters**" [p.27].
- CSD end time TE "may be used in a demultiplexed record to allow the termination of a particular channel
  set shorter than other channel sets within its scan type" [p.24].

> **AMBIGUITY [p.4, p.24]:** samples per trace is never given as a header value. On tape it is
> `(block length − 20) / bytes per sample` (× 4/10 for 8015). On a disk image it must be computed from
> the channel set window, `(TE − TF) × 2 ms / sample interval`, with the same +1 question as Rev 2.0
> (`segd_rev2_0.md` §6.2: real Rev 2.0 data has no +1).

## 3. Header tables

### 3.1 General header (32 B, exactly one) [p.21-23]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | bcd | `fileNumber` | F1-F4, 0-9999. No `FFFF` escape |
| 3-4 | | 4n | bcd | `formatCode` | Y1-Y4, §4.1 (multiplexed `00xx` and demultiplexed `80xx`) |
| 5-10 | | 12n | bcd | `generalConstants` | K1-K12 |
| 11 | | 2n | bcd | `year` | YR1 YR2, last two digits, 0-99 |
| 12 | 12H | 1n | bcd | `zero12H` | **Fixed 0** (printed "0, DY1"). Rev 1+ redefine this nibble as "additional general header blocks" |
| 12-13 | 12L-13L | 3n | bcd | `julianDay` | DY1-DY3, 1-366 |
| 14 | | 2n | bcd | `hour` | H1 H2, 0-23, **GMT** |
| 15 | | 2n | bcd | `minute` | MI1 MI2, 0-59 |
| 16 | | 2n | bcd | `second` | SE1 SE2, 0-59 |
| 17 | | 2n | bcd | `manufacturerCode` | M1 M2, §4.6 |
| 18-19 | | 4n | bcd | `manufacturerSerial` | M3-M6 |
| 20-22 | | 6n | bcd | `bytesPerScan` | B1-B6, 1-999,999: bytes in one complete scan "including data, auxiliary, sync, and timing bytes" (multiplexed). **Demultiplexed: not used, recorded as zeros** |
| 23 | | 1b | fixedpt | `baseScanInterval` | binary I3..I-4 (`u4.u4`), LSB = 1/16 ms. Allowed 1/16, 1/8, 1/4, 1/2, 1, 2, 4, 8 ms (= 1, 2, 4, …, 128). "Always the difference between successive timing words" |
| 24 | 24H | 4 bits | bits | `polarity` | P, §4.4 |
| 24 | 24L | 4 bits | u8 | `scansPerBlockExponent` | S/BX, binary 0-15: exponent of 2 for byte 25 |
| 25 | | 1b | u8 | `scansPerBlockBase` | S/B, binary 0-255. **0 = data body is one continuous block (gapless)**; else each block holds `S/B × 2^S/BX` scans. Multiplexed only |
| 26 | 26H | 4 bits | bits | `recordType` | Z, §4.5 |
| 26-27 | 26L-27L | 3n | bcd | `recordLength` | R1 R2 . R3 ("RR.R") × 1.024 s; 00.5-99.5 ⇒ 0.512-101.888 s; 00.0 = indeterminate. No `FFF` escape |
| 28 | | 2n | bcd | `scanTypesPerRecord` | ST/R 1-99, 0 invalid |
| 29 | | 2n | bcd | `channelSetsPerScanType` | CS 1-99, 0 invalid; = max over scan types (pad with dummy descriptors) |
| 30 | | 2n | bcd | `skewBlocks` | SK 0-99: 32-byte skew fields per scan type; 0 = skew not recorded |
| 31 | | 2n | bcd | `extendedHeaderBlocks` | EC 0-99 |
| 32 | | 2n | bcd | `externalHeaderBlocks` | EX 0-99 |

Coverage: 1-2, 3-4, 5-10, 11, 12H, 12L-13L, 14, 15, 16, 17, 18-19, 20-22, 23, 24H, 24L, 25, 26H,
26L-27L, 28, 29, 30, 31, 32 = 32 B, every nibble.

> **AMBIGUITY [p.22]:** byte 24L is labelled "S/BX7 thru S/BX0" (8 bit names) for a field described as
> "this binary number (range 0 to 15)". It is a 4-bit nibble (S/BX3..S/BX0); byte 24H is the polarity
> nibble ("These 4 binary bits"). The E9 example (S/BX = 2, S/B = 173) is consistent with this.

> **AMBIGUITY [p.21]:** "1:5 MI1, MI2" = byte 15 (OCR).

#### Number of general header blocks; what sits where Rev 1+ expects GH#2

- Rev 0 has **exactly one** 32-byte general header. Its count is not expressed anywhere; GH1 byte 12H is a
  constant `0` digit. Rev 1 (1994) reused that nibble as "number of additional general header blocks"
  (≥ 1 in Rev 1/2), so **byte 12H = 0 identifies a Rev 0 record** (`segd_rev2_0.md` §6.4).
- There is no General Header #2, so there are no revision bytes. Header bytes 33-64 are the **first channel
  set descriptor** (scan type 1, channel set 1). A reader that wrongly assumes GH#2 would read "revision
  bytes 11-12" = header bytes 43-44 = **CSD #1 bytes 11-12**: byte 11 = channel type nibble + `0` (e.g.
  `0x10` seis, `0x20` time break, `0x70` other), byte 12 = subscan exponent nibble + gain control nibble
  (e.g. `0x03` = 1 subscan, fixed gain; `0x08` binary gain; `0x29` = 4 subscans, IFP gain). So the
  "revision" would read as something like 16.3 or 2.8 — garbage. Always test GH1 byte 12H first; a Rev 0
  record has revision **0.0** by definition.

### 3.2 Scan type header [p.2-3, p.23]

Per scan type: `CS` channel set descriptors (32 B, in data order) then `SK` skew fields (32 B). Up to 99
descriptors per scan type and 99 scan types per record [p.2]. Ground rules [p.3]:
1. Descriptor order = order in which the channel sets are recorded in each scan.
2. Each channel set appears once per scan type even if sampled faster (subscans).
3. Every scan type has the same number (CS) of descriptors; unused ones have bytes 9-10 = 0.
4. Bytes per base scan constant over scan types (multiplexed); all scan types have the same number of
   samples per scan [p.30 E1].
5. Word format fixed per reel; mux and demux may share the reel.
6. Suggested channel set order: auxiliary, long sample interval, short sample interval; same-interval sets
   contiguous.

### 3.3 Channel set descriptor (32 B) [p.24-25]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1 | | 2n | bcd | `scanTypeNumber` | ST1 ST2, 1..ST/R (repeated in every descriptor of the scan type) |
| 2 | | 2n | bcd | `channelSetNumber` | CN1 CN2, 1..CS. No `FF` escape |
| 3-4 | | 2b | u16 | `startTime` | TF16..TF1, LSB = 2 ms: ms = value × 2 (0-131,070). Timing word of the first scan of this set; usually 0 for one scan type |
| 5-6 | | 2b | u16 | `endTime` | TE16..TE1, LSB = 2 ms. Single scan type: the record length. Multiplexed: all channels of a set have the same length; demux: may end a set early |
| 7 | | 2n | bcd | `zero7` | **"0,0"**: fixed zero (Rev 1+: low part of MP) |
| 8 | | 1b | fixedpt | `mpFactor` | MPS, MP4..MP-2: **sign-magnitude**, radix between MP0 and MP-1 ⇒ value = (−1)^S × (b and 0x7F) / 4; range ±31.75, step 0.25 (§3.5) |
| 9-10 | | 4n | bcd | `channelCount` | C/S1-C/S4, 0-9999; 0 = dummy descriptor |
| 11 | 11H | 4 bits | bits | `channelType` | C, §4.2 |
| 11 | 11L | 1n | bcd | `zero11L` | 0 |
| 12 | 12H | 1n | bcd | `subscanExponent` | S/C (BCD digit 0-9): subscans per base scan = 2^S/C (1-512) |
| 12 | 12L | 4 bits | bits | `gainControl` | J, §4.3 |
| 13-14 | | 4n | bcd | `aliasFilterFreq` | AF1-AF4, 0-9999 Hz |
| 15 | 15H | 1n | bcd | `zero15H` | 0 |
| 15-16 | 15L-16L | 3n | bcd | `aliasFilterSlope` | AS1-AS3, 0-999 dB/oct; 0 = filter out (E5) |
| 17-18 | | 4n | bcd | `lowCutFreq` | LC1-LC4, 0-9999 Hz |
| 19 | 19H | 1n | bcd | `zero19H` | 0 |
| 19-20 | 19L-20L | 3n | bcd | `lowCutSlope` | LS1-LS3, 0-999 dB/oct; 0 = filter out (E5) |
| 21-22 | | 4n | bcd | `notch1Freq` | NT1 NT2 NT3 . NT4 ⇒ Hz = value / 10, 0-999.9; out = 000.0 |
| 23-24 | | 4n | bcd | `notch2Freq` | second notch, same coding |
| 25-26 | | 4n | bcd | `notch3Freq` | third notch, same coding |
| 27-32 | | 6b | — | `unused27_32` | **"Unused. Written as zeros."** |

Coverage: 1, 2, 3-4, 5-6, 7, 8, 9-10, 11H, 11L, 12H, 12L, 13-14, 15H, 15L-16L, 17-18, 19H, 19L-20L, 21-22,
23-24, 25-26, 27-32 = 32 B.

> **AMBIGUITY [p.24]:** "TF1 = 21 msec (2-msec increments)" = TF1 weight 2^1 ms. "TEl6" = TE16.
> "This multiplier has a range of 231.75 to 2-31.75" = 2^31.75 to 2^−31.75.

> **AMBIGUITY [p.25]:** byte 12 is listed twice ("S/C," and ",J"): S/C is the high nibble, J the low one
> (J table says "Bits 4 5 6 7"). The S/C text says "packed BCD number" with values 2^0..2^9.

> **AMBIGUITY [p.24]:** byte 8 abbreviation "MPS, MP4 thru MP-2" = sign bit + 7 magnitude bits
> (MP4, MP3, MP2, MP1, MP0, MP-1, MP-2). App. E7 confirms "any value between −31.75 and +31.75 in
> increments of 0.25".

### 3.4 Sample skew fields (SK × 32 B per scan type) [p.2-3, p.30-31, p.35-36]

- One byte per sample of each subscan of each channel set, **in the order the samples are recorded in the
  scan** (§2.3), i.e. `S/S = Σ C/S × 2^S/C` bytes used; the rest of the last field is unspecified.
- Value = u8 fraction of the base scan interval, LSB = BSI/256 (e.g. 7.8125 µs at 2 ms).
- Actual sample time = timing word T + SS × I (I = base scan interval) [p.3].
- `SK = ceil(S/S / 32)` (E3).
- Byte offset (1-based, from the start of the header block) of the skew byte for channel k (1-based) of
  channel set i of scan type j, first subscan (E8):
  `32 + 32(j−1)(CS+SK) + 32·CS + Σ_{c<i} C/S_c × 2^(S/C_c) + k`; later subscans: add multiples of C/S_i.
  Worked example [p.36]: CS = 3, SK = 4, j = 2, i = 2, k = 11, previous set 4 × 1 ⇒ 367; second subscan
  367 + 48 = 415.

### 3.5 MP factor [p.24, p.33-34]

```
mp = (b8 and 0x7F) / 4.0 ; if (b8 and 0x80) != 0: mp = -mp      # byte 7 is 0
millivolts = decoded_sample × 2^mp
```

Writer side (App. E7): `MP = FS − PA − k·Cmax`, with 2^FS = converter full scale (mV), 2^PA = minimum
system gain (preamp × minimum floating-point amplifier gain, may absorb a non-power-of-2 converter
adjustment); `k·Cmax` = 15 (binary, 8015/0015), 2×7 (quaternary), 4×3 (hexadecimal 1/2 byte),
4×(Cmax−64) = 4×63 = 252 (excess-64, typically MP = 0). FS − PA must be a multiple of 0.25 (multiple of 4
for excess-64 with MP = 0). Examples [p.34]: quaternary, 8192 mV, gain 320 × 0.8 ⇒ MP = 13 − 8 − 14 = −9;
binary, 8192 mV, gain 128 ⇒ −9; hex, 8192 mV, gain 256 ⇒ −7.

> **AMBIGUITY [p.33]:** equation (4) as printed is `MP = FS − PA − 4(Cmax − 64)` with Cmax = 127 for
> excess-64, which gives MP = FS − PA − 252, while the note on [p.34] says MP "will generally be recorded
> as zero" for 4-byte hex and that then `FS − PA = 4(Cmax − 64)`. Rev 2.0 (`segd_rev2_0.md` §7.5) uses
> Cmax = 64 (term 0) for the excess-64 formats. Readers only apply 2^MP, so this matters only to writers.

### 3.6 Start of scan and timing word (multiplexed, 8 B per scan) [p.3-4]

| Byte | bit 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| 2 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| 3 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| 4 | x | TWI | ITB | DP | x | x | **0** | **1** |
| 5 | T15 | T14 | T13 | T12 | T11 | T10 | T9 | T8 |
| 6 | T7 | T6 | T5 | T4 | T3 | T2 | T1 | T0 |
| 7 | T-1 | T-2 | T-3 | T-4 | T-5 | T-6 | T-7 | T-8 |
| 8 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

- SOS test: `b1 == 0xFF and b2 == 0xFF and b3 == 0xFF and (b4 and 0x03) == 0x01`. `x` bits are undefined.
- **TWI** (bit 1 = 0x40): time-break window indicator; switches 0 → 1 at the close of the time-break
  window. TWI = 1 in the **first** scan of a record ⇒ time break not detected, recording started at the end
  of the window.
- **ITB** (bit 2 = 0x20): internal time break; 1 for the whole record if an abnormal sync condition was
  detected.
- **DP** (bit 3 = 0x10): dynamic parameter change; 0 in scan type 1, toggles at the first scan of each new
  scan type; always 0 without dynamic changes.
- Timing word (bytes 5-7) = `u16.u8` ms from zero time to the start of this scan (LSB 1/256 ms, MSB 32,768
  ms, range 0-65,535.9961 ms, **wraps to 0** on longer records). Byte 8 = 0x00. Whether or not the system
  resynchronizes to the source, the timing word is the time from the source event (example: 0+1+9/256,
  2+1+9/256, … ms).
- Uniqueness of the SOS is guaranteed by restrictions on each sample format (§5: negative zero / all-ones
  invalid, LSB of 0015 and byte 4 bit 7 of 0048 forced 0).

> **AMBIGUITY [p.4]:** the timing word bit table is extracted with the exponents split over lines
> ("2 -2 / 2 -3 / …"); read as above (bytes 5-7 = 2^15 … 2^−8), consistent with "LSB (2^−8) is equal to
> 1/256 msec, and the MSB (2^15) is equal to 32,768 msec".

### 3.7 Demultiplexed trace header (20 B) [p.4-5]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-2 | | 4n | bcd | `fileNumber` | F1-F4 (copy of GH1 bytes 1-2) |
| 3 | | 2n | bcd | `scanTypeNumber` | ST1 ST2 |
| 4 | | 2n | bcd | `channelSetNumber` | CN1 CN2 |
| 5-6 | | 4n | bcd | `traceNumber` | TN1-TN4 (channel number); each channel set starts at 1 |
| 7-9 | | 3b | fixedpt | `firstTimingWord` | T15..T-8, `u16.u8` ms: timing word that would accompany the first sample in the multiplexed format |
| 10 | | 1b | u8 | `zero10` | **0** (Rev 1+: number of trace header extensions) |
| 11 | | 1b | fixedpt | `sampleSkew` | SS-1..SS-8: u8/256 × BSI; = first skew byte of this channel in the scan type header |
| 12 | | 1b | u8 | `zero12` | **0** (Rev 1+: trace edit) |
| 13-15 | | 3b | fixedpt | `timeBreakWindow` | TW15..TW-8, `u16.u8` ms: timing word of the scan in which TWI changed to 1 (time from time break to the end of the TB window). A value < BSI ⇒ time break not detected |
| 16-20 | | 5b | — | `zero16_20` | **0** (Rev 1+: extended channel set and file numbers) |

Coverage: 1-2, 3, 4, 5-6, 7-9, 10, 11, 12, 13-15, 16-20 = 20 B.

- Exact time of the first sample = firstTimingWord + sampleSkew/256 × BSI [p.4-5].
- "All the information in the trace header is taken directly from the general header and scan type header
  with the exception of the channel number and the time break window end time" [p.4].
- **No trace header extensions** exist in Rev 0 (byte 10 is 0), so there is no per-trace sample count and
  no receiver position.

### 3.8 Extended header and external header [p.2-3, p.23]

`EC × 32 B` (GH1 byte 31): equipment-manufacturer parameters (e.g. a vertical stacking unit: records per
stack, rejected records, stack type); format "established and documented" by the manufacturer.
`EX × 32 B` (GH1 byte 32): user information (roll box, crew data, survey, marine parameters); format
defined by the end user. Both opaque; keep raw.

## 4. Code tables

### 4.1 Format codes (GH1 bytes 3-4, BCD) [p.21, p.30]

| Code | Data recording method | Bytes/sample |
|---|---|---|
| 0015 | 20-bit binary exponent, multiplexed | 2.5 (10 B / 4 channels) |
| 0022 | 8-bit quaternary exponent, multiplexed | 1 |
| 0024 | 16-bit quaternary exponent, multiplexed | 2 |
| 0042 | 8-bit hexadecimal exponent, multiplexed | 1 |
| 0044 | 16-bit hexadecimal exponent, multiplexed | 2 |
| 0048 | 32-bit hexadecimal (excess-64) exponent, multiplexed | 4 |
| 8015 | 20-bit binary exponent, demultiplexed | 2.5 (10 B / 4 samples) |
| 8022 | 8-bit quaternary exponent, demultiplexed | 1 |
| 8024 | 16-bit quaternary exponent, demultiplexed | 2 |
| 8042 | 8-bit hexadecimal exponent, demultiplexed | 1 |
| 8044 | 16-bit hexadecimal exponent, demultiplexed | 2 |
| 8048 | 32-bit hexadecimal (excess-64) exponent, demultiplexed | 4 |
| 0200, 0000 | "Illegal, do not use" | — |

**Not in Rev 0**: 0036, 0038, 0058, 8036, 8038, 8058 (24/32-bit integer, IEEE, added in Rev 1) and 8080
(Rev 3). The abstract's "six methods" are the six word types [p.1].

> **AMBIGUITY [p.21]:** "8044 16 bit hexadecimal &multiplexed" = demultiplexed (OCR).

### 4.2 Channel type C (CSD byte 11H) [p.25]

| Code | Meaning |
|---|---|
| 0x0 | Unused |
| 0x1 | Seis |
| 0x2 | Time break |
| 0x3 | Up hole |
| 0x4 | Water break |
| 0x5 | Time counter — **illegal in this format** (footnote 6: the timing counter is part of the start of scan) |
| 0x6 | External data |
| 0x7 | Other |
| 0x8 | Signature, unfiltered |
| 0x9 | Signature, filtered |

(No 0xC: the General Trailer is Rev 1+.)

### 4.3 Gain control method J (CSD byte 12L) [p.25]

| Code | Meaning |
|---|---|
| 1 | Individual AGC |
| 2 | Ganged AGC |
| 3 | Fixed gain |
| 4 | Programmed gain |
| 8 | Binary gain control |
| 9 | IFP gain control |

### 4.4 Polarity P (GH1 byte 24H) [p.22]

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
| 0x9-0xF | unassigned |

Set manually from sensor/cable/instrument/source tests (ref. Thigpen et al. 1975, Geophysics 40, 694).

> **AMBIGUITY [p.22]:** "1001 … 1110 11115" with "unassigned" beside 1100: read as all of 1001-1111
> unassigned ("11115" = 1111 + footnote 5). Rev 2.0's extraction lists only 1100.

### 4.5 Record type Z (GH1 byte 26H) [p.22]

| Code | Meaning |
|---|---|
| 0x2 | Test record |
| 0x4 | Parallel channel test |
| 0x6 | Direct channel test |
| 0x8 | Normal record |
| 0x1 | Other |

### 4.6 Manufacturer codes (GH1 byte 17) [p.26]

| Code | Name | Code | Name |
|---|---|---|---|
| 01 | Alpine Geophysical Associates (obsolete) | 10 | Leach Corporation (obsolete) |
| 02 | Applied Magnetics Corp (see 09) | 11 | Metrix Instrument Co. (obsolete) |
| 03 | Litton Resources Systems | 12 | Redcor Corporation (obsolete) |
| 04 | SIE, Inc. | 13 | Sercel |
| 05 | Dyna-Tronics Mfg. (obsolete) | 14 | Scientific Data Systems (obsolete) |
| 06 | Electronic Instrumentation (obsolete) | 15 | Texas Instruments |
| 07 | Electro-Technical Labs, Div. of Geosource | 17 | GUS Manufacturing |
| 08 | Fortune Electronics (obsolete) | 18 | Input/Output, Inc. |
| 09 | Geo Space Corporation | | |

No 16. Later lists (Rev 2.0 §4.10) rename 03 (Western), 04 (obsolete), 07 (Halliburton) and add 19+.

## 5. Data sample formats [p.5-9]

General [p.5-6]:
- The data word is the sign and magnitude of the instantaneous input voltage, as mantissa × base^exponent
  (base 2, 4 or 16). Physical value (mV) = decoded × 2^MP (§3.5).
- **One's complement** fractions for the binary and quaternary methods; **sign-magnitude** for the
  hexadecimal methods [p.2 req. 6].
- Same number system for all samples of a record, auxiliary channels included; every method is valid
  multiplexed and demultiplexed; only the 2½-byte method differs between the two [p.6].
- Big-endian; samples contiguous after the 20-byte trace header (demux) or the 8-byte SOS/timing (mux).

### 5.1 0015 — 20-bit binary exponent, **multiplexed** (4 channels per 10 bytes) [p.6-7]

| Byte | bits 0-3 (H) | bits 4-7 (L) |
|---|---|---|
| 1 | C3-C0 channel 1 | C3-C0 channel 2 |
| 2 | C3-C0 channel 3 | C3-C0 channel 4 |
| 3 | S Q-1 Q-2 Q-3 | Q-4 Q-5 Q-6 Q-7 (channel 1) |
| 4 | Q-8 Q-9 Q-10 Q-11 | Q-12 Q-13 Q-14 **0** |
| 5-6 | channel 2 (same as 3-4) | |
| 7-8 | channel 3 | |
| 9-10 | channel 4 | |

- C = u4 exponent of 2 (0-15), "in channel number order … starting with channel one in bits 0-3 of Byte 1".
  Channel numbers are relative within the group of four.
- S + Q-1..Q-14 = **one's complement 15-bit** value with a 14-bit fraction; **bit 7 of the second byte of
  each sample must be 0** (SOS uniqueness). Range ±(1 − 2^−14). Negative zero invalid → +0.
- Value = S.Q × 2^C × 2^MP mV. Channels per channel set must be divisible by 4.

```
decode word w (u16, bytes 3-4 of one channel):
  q  = (w shr 1) and 0x3FFF                      # 14 fraction bits
  m  = if (w and 0x8000) != 0: -int(q xor 0x3FFF) else int(q)
  v  = m / 16384.0 * 2^C
encode: as 8015 but with a 14-bit magnitude (0..0x3FFF) and one's complement over 15 bits
        (S + 14), then shift left 1 so bit 0 (Q-15 position) is 0
```

### 5.2 8015 — 20-bit binary exponent, demultiplexed (4 samples per 10 bytes) [p.7]

Same as `segd_rev2_0.md` §5.1: bytes 1-2 = four exponent nibbles (sample order), then four 16-bit words
`S Q-1 … Q-15`; one's complement 15-bit fraction, **uses the LSB**; range ±(1 − 2^−15); negative zero
invalid → +0; samples per channel divisible by 4. Value = S.Q × 2^C × 2^MP.

### 5.3 0022 / 8022 — 1-byte quaternary exponent [p.6]

`S C2 C1 C0 Q-1 Q-2 Q-3 Q-4`. C = u3 exponent of 4 (0-7). S+Q = one's complement 4-bit fraction, range
−1 + 2^−4 … 1 − 2^−4. **Negative zero (0xFF) invalid → +0** (SOS uniqueness). Value = S.QQQQ × 4^C × 2^MP.

### 5.4 0024 / 8024 — 2-byte quaternary exponent [p.6]

Byte 1 `S C2 C1 C0 Q-1..Q-4`, byte 2 `Q-5..Q-12`. One's complement 12-bit fraction, range ±(1 − 2^−12).
Negative zero (0xFFFF) invalid → +0. Value = S.Q × 4^C × 2^MP.

### 5.5 0042 / 8042 — 1-byte hexadecimal exponent [p.8]

`S C1 C0 Q-1..Q-5`. C = u2 exponent of 16 (0-3); Q = 5-bit **positive** fraction (sign-magnitude). All-ones
(0xFF: negative, C = 3, Q = 1 − 2^−5) invalid. Value = (−1)^S × Q/32 × 16^C × 2^MP.

> **AMBIGUITY [p.8]:** range printed "−(1 − 2^−4) × 16^3 to +(1 − 2^−5) × 16^3"; with all-ones invalid the
> most negative valid value is −(1 − 2·2^−5) × 16^3 = −(1 − 2^−4) × 16^3, so the text is right. (Rev 2.0
> note flags this as inconsistent; it is consistent.) Same for 0044: −(1 − 2^−12) × 16^3.

### 5.6 0044 / 8044 — 2-byte hexadecimal exponent [p.8]

Byte 1 `S C1 C0 Q-1..Q-5`, byte 2 `Q-6..Q-13`. Sign-magnitude 13-bit fraction; 0xFFFF invalid. Value =
(−1)^S × Q/8192 × 16^C × 2^MP.

### 5.7 0048 / 8048 — 4-byte hexadecimal excess-64 [p.8-9]

| Byte | bits 0..7 |
|---|---|
| 1 | S C6..C0 |
| 2 | Q-1..Q-8 |
| 3 | Q-9..Q-16 |
| 4 | Q-17..Q-23, **0** |

Value = (−1)^S × Q/2^23 × 16^(C−64) × 2^MP; "written as a hexadecimal left justified number" (normalized);
fraction 0 ⇒ whole word 0; bit 7 of byte 4 must be 0 (in demux too, as printed). = IBM float with the last
fraction bit 0. MP "may be recorded as zero".

> **AMBIGUITY [p.8]:** range "from 1 − 2^−23 to −(1 + 2^−23)" — the second should be −(1 − 2^−23); typo.

## 6. Derived rules / algorithms (App. E) [p.30-36]

| Rule | Formula | Example |
|---|---|---|
| E1 samples per scan type | `S/S = Σ_cs C/S × 2^(S/C)`; equal for all scan types | 4×1 + 96×1 + 12×4 = 148 |
| E2 bytes per scan (mux) | `B = 8 + Σ C/S × 2^(S/C) × bps` (bps 1: 0022/0042, 2: 0024/0044, 2.5: 0015, 4: 0048) | 8 + 148 × 2.5 = 378 |
| E3 skew fields | `SK = ceil(S/S / 32)` | 148/32 ⇒ 5 |
| E4 header length | `HL = 32 × [ST/R × (CS + SK) + 1 + EC + EX]` | 32 × (1 × (3 + 5) + 1) = 288 |
| E5 filter slopes | `LS = 40/log2(fLCO/f40) = 12.04/log10(…)`, `AS = 60/log2(f60/fACO) = 18.06/log10(…)`, rounded | — |
| E6 CSD byte offset | byte no. (1-based) = `32 + index + 32(CN−1) + 32(ST−1)(CS+SK)` | ST 2, CN 2, index 11, CS 2, SK 2 ⇒ 203 |
| E8 skew byte offset | §3.4 | 367 |
| E9 bytes per block (gapped mux) | `(S/B × 2^S/BX) × B` | 173 × 4 × 378 = 261,576 |
| E10 choosing S/B, S/BX | `max = floor(limit / B)`; `S/BX = ceil(log2(max / 256))`; `S/B = floor(max / 2^S/BX)` | limit 250,000, B 378 ⇒ max 661, S/BX 2, S/B 165, block 249,480 |

### 6.1 Reading algorithm (disk image of a Rev 0 tape)

```
gh1 = read 32
require gh1[12].H == 0                       # Rev 0 (no GH#2)
nST, nCS, nSK, nEC, nEX = BCD(gh1[28..32])
for st in 1..nST: read nCS CSDs, read nSK*32 skew bytes
skip nEC*32 + nEX*32
fmt = BCD(gh1[3..4])
if fmt < 8000:                                # multiplexed
  B = BCD6(gh1[20..22]); spb = gh1[25] * 2^(gh1[24] and 0xF)
  loop scans of B bytes: check SOS, read timing word, split per §2.3
  (gapped: every block holds spb scans and starts with SOS; on disk the blocks are just concatenated)
  until EOF / next record (GH1-looking block) / scans exhausted per scan type
else:                                         # demultiplexed
  for st, cs, ch: read 20 B header; ns = tape block length or (TE−TF)*2/SI; read data
```

### 6.2 Validation

| Rule | Source |
|---|---|
| GH1 byte 12H = 0 | p.21 |
| ST/R ≥ 1, CS ≥ 1 | p.23 |
| BSI ∈ {1, 2, 4, …, 128} (1/16 ms units) | p.21-22 |
| mux: bytes 20-22 = E2 value; demux: 0 | p.21, p.30 |
| S/B = 0 ⇒ gapless; S/B, S/BX = 0 in demux | p.22 |
| CSD bytes 7, 27-32 = 0; byte 11L = 0; 15H, 19H = 0 | p.24-25 |
| channel type ≠ 5 | p.25 fn 6 |
| trace header bytes 10, 12, 16-20 = 0 | p.5 |
| 0015/8015: channels (mux) / samples (demux) divisible by 4 | p.7 |
| sample words obey the SOS-uniqueness restrictions | §5 |
| SOS byte 4 `and 0x03 == 0x01`; byte 8 = 0 | p.4 |

## 7. Implementation notes

- Rev 0 is the only SEG-D revision with **multiplexed** data in practice (Rev 1 still allowed it; Rev 2
  dropped it). A Rev 0 reader is mostly a multiplexed reader.
- Every header byte that Rev 1/2 define but Rev 0 does not is **zero** in Rev 0 (GH1 12H, CSD 7, 27-32,
  trace header 10, 12, 16-20). Under Rev 2 rules these zeros mean: 0 additional GH blocks, MP low byte 0,
  extended channel set 0, EFH 0, THE 0, **vertical stack 0 = "intentionally zeroed data"**, streamer 0,
  **array forming 0 = undefined**, trace edit 0 = none. Only VS and ARY change meaning; do not report them
  as errors for Rev 0 and do not copy them into a Rev 2/3 conversion.
- But GH1 bytes 20-22, 24L and 25 are **not** zero in Rev 0 multiplexed records (bytes per scan, S/BX,
  S/B), while Rev 2 calls them unused.
- Trace header byte 4 (channel set) and byte 2 of the CSD are plain BCD (no `FF`).
- Time base is GMT.

## 8. Delta vs Rev 2.0 (`segd_rev2_0.md`)

### 8.1 Structure

| Item | Rev 0 | Rev 2.0 |
|---|---|---|
| Tape label | none | 128 B storage unit label, required on tape |
| Record delimiting | header block + data blocks per file; EOF between records; 2 × EOF = end | byte stream; file marks optional at record boundaries; EOD |
| Data organisation | **multiplexed (gapped / gapless) or demultiplexed** | demultiplexed only |
| Demux trace | one tape block per trace | traces in a byte stream, any blocking (RECORD/FIXREC) |
| General headers | **1** (32 B) | ≥ 2 (GH#1, GH#2, optional GH#3..N source blocks) |
| Revision field | none (implicitly 0.0) | GH#2 bytes 11-12 = `02 00` |
| Header length | `32 × [ST/R(CS+SK) + 1 + EC + EX]` | `32 × [nGh + ST/R(CS+SK) + EC + EX]` |
| Trace header extensions | none | 0-15 × 32 B, THE#1 has receiver position, samples per trace, sensor type |
| General trailer | none | GT × 32 B after the last trace |
| Extended counts | none (`FF`/`FFFF`/`FFF` have no meaning) | GH#2 bytes 1-9, 15-17; CSD 27-28; trace 16-20 |

### 8.2 General header #1 byte by byte

| Bytes | Rev 0 | Rev 2.0 |
|---|---|---|
| 1-2 | BCD file number | same, `FFFF` ⇒ GH#2 bytes 1-3 |
| 12H | constant 0 | additional GH blocks (u4) |
| 14 | hour, GMT | hour, UTC |
| 20-22 | **bytes per scan, 6-digit BCD** (mux; 0 in demux) | unused, record as 0 |
| 24L | **S/BX** (u4) | unused |
| 25 | **S/B** (u8) | unused |
| 26L-27L | record length RR.R | same, `FFF` ⇒ GH#2 bytes 15-17 |
| 29, 31, 32 | BCD CS / EC / EX | same, `FF` ⇒ GH#2 |
| all others | identical | identical |

### 8.3 Channel set descriptor

| Bytes | Rev 0 | Rev 2.0 |
|---|---|---|
| 2 | BCD channel set number | same, `FF` ⇒ bytes 27-28 |
| 7 | 0 | MP low byte (MP-3..MP-10) |
| 8 | MP: S + 7 bits, step 0.25, ±31.75 | MP high byte; with byte 7: step 2^−10, ±31.999 |
| 27-28 | 0 (unused) | extended channel set number |
| 29 | 0 | EFH (H), THE count (L) |
| 30 | 0 | vertical stack (0 = intentionally zeroed) |
| 31 | 0 | streamer number |
| 32 | 0 | array forming |
| 11H code 5 | time counter, footnoted "illegal code for this format" | listed as "Time counter" in `segd_rev2_0.md` §4.3 (no restriction noted) |
| others | identical | identical |

### 8.4 Demux trace header

| Bytes | Rev 0 | Rev 2.0 |
|---|---|---|
| 10 | 0 | THE count 0-15 |
| 12 | 0 | trace edit |
| 16-17 | 0 | extended channel set number |
| 18-20 | 0 | extended file number |
| others | identical | identical |

### 8.5 Formats and codes

| Item | Rev 0 | Rev 2.0 |
|---|---|---|
| Format codes | 0015, 0022, 0024, 0042, 0044, 0048, 8015, 8022, 8024, 8042, 8044, 8048 | 8015, 8022, 8024, 8036, 8038, 8042, 8044, 8048, 8058 |
| Sample layouts of 8015-8048 | identical to Rev 2.0 | — |
| Channel types | 0-9 | + 0xC (trailer) |
| Manufacturer codes | 01-18 (no 16) | 01-46, several renamed |
| Polarity | 0-8, 9-F unassigned | same (extraction lists 1100 only) |
| Gain control, record type | identical | identical |
| MP formula | §3.5 (excess-64 Cmax = 127) | Cmax = 64 for excess-64; integer formats added |

Rev 2.0's own Rev 1-vs-Rev 0 list (`segd_rev2_0.md` §7.4) is consistent with the rows above. Note that
Rev 1 briefly reused GH1 byte 20 ("B1 = 1" = blocked demux data, `segd_rev2_0.md` §2.2), so in Rev 1
files byte 20 is neither Rev 0's bytes-per-scan digit pair nor Rev 2's zero.

## 9. Open questions

| # | Question | Suggested default |
|---|---|---|
| D0-Q1 | Samples per demux trace on a disk image (no block lengths). | `(TE − TF) × 2 / SI` (no +1), then check the next 20 bytes look like a trace header (file no., ST, CS, TN+1); on tape use the block length. |
| D0-Q2 | Number of scans per scan type (mux). | Same window rule; or walk SOS codes until the next record. Treat a short final block as end of data. |
| D0-Q3 | 0015 fraction: one's complement per spec; real systems may use two's complement. | Default one's complement, reuse the existing `twosComplement8015` option. |
| D0-Q4 | Resync after a corrupt scan. | Search forward for SOS (`FF FF FF x1`) at scan stride B; log the skipped bytes. |
| D0-Q5 | Gapped mux on disk: are blocks padded? | Assume no padding (blocks concatenated); verify by SOS at each block start. |

## 10. Implementation gap analysis (code as of commit `14fbb9d`)

### 10.1 What the code does today with a Rev 0 record

| Step | Behaviour | Where |
|---|---|---|
| GH count | `generalHeaderCount = 1 + GH1 byte 12H`; Rev 0 ⇒ 1 | `src/parseSEG/segd/headers.nim:151-153` |
| Revision | GH#2 read only when the count ≥ 2; otherwise `hasGh2 = false`, `revision` stays 0.0 | `src/parseSEG/segd/reader.nim:333-347`, `reader.nim:46-47, 61` |
| Counts | GH1 BCD fields used directly when there is no GH#2 | `reader.nim:360-365` |
| CSD / skew / EC / EX | read per GH1; skew kept raw | `reader.nim:381-399` |
| Format | `toSegdFormat` accepts only 8015, 8022, 8024, 8036, 8038, 8042, 8044, 8048, 8058, 8080; **any `00xx` multiplexed code ⇒ fatal** "undefined or multiplexed, so trace lengths are unknown" | `src/parseSEG/segd/samples.nim:30-36`, `reader.nim:401-407` |
| Trace count | Σ channelCount over every scan type and channel set | `reader.nim:394` |
| Trace length | Rev 0 has THE = 0 ⇒ `round((TE − TF) / SI)` from the CSD; tape block length unused | `reader.nim:513-523` |
| MP | 15-bit decode; Rev 0 byte 7 = 0 ⇒ identical to the 0.25-step value | `headers.nim:175-180` |
| GH1 20-22, 24L, 25 | modelled as `unused20`, `unused24L`, `unused25` (raw kept, not interpreted) | `headers.nim:34-38` |
| CSD 27-32 | decoded as ext CS number, EFH/THE, VS, streamer, array forming | `headers.nim:101-106` |
| Diagnostics | info "array forming code is 0" for every non-dummy channel set | `reader.nim:390-393` |
| Trailer | none without GH#2 | `reader.nim:575` |
| Sample decode 8015-8048 | layouts identical to Rev 0 | `samples.nim:59-…` (`decodeSamples`) |
| Writer | records with `hasGh2 = false` accepted (GH count must agree); only demux formats; no Rev 0 format/field checks | `src/parseSEG/segd/writer.nim:170-212` |
| Revision conversion | Rev 0 → 2.x: adds GH#2, copies everything else; → 3.0: copies CSD VS/ARY | `src/parseSEG/segd/revconvert.nim:597-602` (to 2.x), `revconvert.nim:185-187` (to 3.0) |

Verdict: a **demultiplexed** Rev 0 disk image whose channel-set windows give the exact trace length is
read and written back correctly today (revision 0.0, no GH#2). **Multiplexed** Rev 0 — the common case for
1980s field tapes — is refused.

### 10.2 Gaps, ranked by importance

1. **No multiplexed support** (`samples.nim:4-6, 30-36`; `reader.nim:401-407`). Needed for Rev 0 reading:
   - accept `0015 … 0048` in a format enum with a mux flag;
   - decode GH1 bytes 20-22 (BCD bytes per scan), 24L (S/BX), 25 (S/B) (`headers.nim:34-38`);
   - a scan walker: per scan type, scans of `B` bytes, SOS check (`FF FF FF`, `b4 and 3 == 1`), timing word
     (`u16.u8` ms, wrap), TWI/ITB/DP flags, DP toggle check at scan type changes, channel-set/subscan split
     per §2.3, gapped blocks of `S/B × 2^S/BX` scans, end at EOF / tape mark / next record;
   - a **0015** decoder (14-bit one's-complement fraction, LSB forced 0, exponent nibbles per channel group;
     §5.1); 0022-0048 reuse the demux decoders sample by sample;
   - a demultiplexer that yields `SegdTrace`s (synthesized 20-byte headers: file, ST, CS, TN, first timing
     word, skew byte from the scan type header, TB window from the scan where TWI changed), so the rest of
     the API is unchanged; keep the raw scans for byte-exact round trip.
   For writing Rev 0 mux: the inverse (multiplexer, SOS/timing word generation, bytes-per-scan, block
   sizing per E10) — needed only if the project must emit mux tapes.
2. **Demux trace length ignores tape blocks** (`reader.nim:513-523`). On a tape or tape image
   (`not byteStream`) each Rev 0 trace is one block: take `ns` from the remaining record length
   (`(len − 20) / bps`, 8015: `/10 × 4`) and warn when the window rule disagrees. On disk, check the
   computed length by peeking at the next trace header (file number, ST, CS, TN sequence), because a +1
   convention or a short channel set (TE used to end a set early, §2.4) misaligns everything after it.
3. **Rev 0 → Rev 2/3 conversion copies Rev 0 zeros that mean something in Rev 2/3**
   (`revconvert.nim:185-187` for 3.0, `597-602` for 2.x). VS = 0 becomes "intentionally zeroed data" and ARY = 0
   "undefined"; GH1 20-22/24L/25 are copied into "unused" bytes. Needed: when the source has no GH#2, set
   CSD VS = 1, ARY = 1, zero GH1 20-22/24L/25, and log the change; refuse (or demultiplex first) mux input.
4. **Writer has no Rev 0 rules** (`writer.nim:170-212`). A record without GH#2 can be written with Rev 1+
   formats (8036/8038/8058), THE > 0, non-zero trace edit or an MP with a non-zero byte 7 (`headers.nim:182-187`
   rounds to 2^−10), none of which Rev 0 readers understand. Needed: when `hasGh2 = false`, refuse formats
   outside §4.1, THE ≠ 0, byte 7 ≠ 0 (round MP to 0.25), and non-zero CSD 27-32 / trace 10, 12, 16-20 unless
   unchanged from what was read.
5. **Diagnostic noise and wrong labels for Rev 0** (`reader.nim:390-393`; `headers.nim:29`). The "array
   forming code is 0" info fires on every channel set of every Rev 0 record; GH1 hour is documented as UTC
   (Rev 0/1: GMT). Suppress the info when `not hasGh2`; fix the doc comment.
6. **Validation of Rev 0-only rules missing** (`reader.nim:381-399`). No checks for channel type 5
   (illegal), BSI ∈ {1..128 powers of 2}, demux bytes 20-22/24L/25 = 0, CSD 7/27-32 = 0. Low; warnings only.
7. **Revision detection is correct but implicit** (`reader.nim:333-347`). GH1 byte 12H = 0 ⇒ 0.0 works and
   GH#2 bytes 11-12 are never read for Rev 0 (so CSD #1 bytes 11-12 at header bytes 43-44 are not misread as
   a revision). Worth a test and an explicit `isRev0` accessor; no functional change needed.
