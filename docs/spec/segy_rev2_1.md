# SEG-Y rev 2.1 (October 2023) — spec note (delta on rev 1)

Sources:
- Main: `SEG Spec/text/seg_y_rev2_1-oct2023.txt`. `[p.N]` = `=== PAGE N ===` marker (PDF page index;
  printed page = N−3 for the body).
- Clarification: `SEG Spec/text/seg-y_rev2-1_clarification_2025-05-01.txt` (SEG TSC, 1 May 2025).
  Cited as `[clar p.N]`. **Overrides the main document where they conflict** (Extended Textual Header only).
- Base: `docs/spec/segy_rev1.md` ("rev 1 note"). Anything not restated here is unchanged from the rev 1 note
  (§-numbers like "rev1 §3.3" refer to that file).

## 1. Scope

| Pages | Content | Covered |
|---|---|---|
| 1-3 | Title, TOC, list of figures/tables | skipped (front matter) |
| 4-5 | Intro, §2 summary of changes (2→2.1, 1→2, 0→1), Figure 1 | yes (rules only) |
| 5-7 | §3 file structure, medium, number formats, varying trace lengths, coordinates | yes |
| 7-8 | §4 Textual File Header, Table 1 | yes (delta) |
| 9-14 | §5 Binary File Header, Table 2 | yes (full re-tabulation) |
| 15-18 | §6 Extended Textual File Header, EndText, examples | yes (delta) |
| 18-27 | §7.1 Standard Trace Header, Table 3 | yes (full re-tabulation) |
| 28-30 | Table 4 Trace Header Extension 1, Table 5 Proprietary extension | yes (new) |
| 30-31 | §7.2 trace data, §8 User Header / Data Trailer | yes (new) |
| 32 | App. A disk files | yes |
| 33-35 | App. B tape label (Table 6) | yes (delta: fields 10-14) |
| 36 | App. C tape blocking | unchanged from rev 1 (rev1 §2.4) |
| 37-42 | App. D-1/D-2 IOGP stanzas, D-3..D-6 (= rev 1 D-4..D-7) | D-1/D-2 rules; D-3..D-6 → rev1 §7 |
| 43-53 | App. D-7 Trace Header Mapping (deprecated), SEG00000/SEG00001 mapping | yes (keywords + format codes) |
| 54-64 | App. D-8 XML Trace Header Layout (Tables 12, 13, Figs 3-5, D-8.1) | yes |
| 65-73 | App. D-9 User Data stanza (description block tags) | yes |
| 74-78 | App. E data word formats (codes 1-12, 15, 16) | yes |
| 79-82 | App. F EBCDIC/ASCII (Table 14) | identical to rev 1 Table 13 → rev1 C14 |
| 82-83 | App. G references | skipped |
| clar 1-14 | Extended Textual Header clarification | yes |

Omitted: acknowledgments, SEG address, IOGP / Energistics URLs, D-9 marketing prose, the long `dataformat`
example list (summarised).

## 2. File / tape structure

### 2.1 Logical byte stream [p.5, p.6, p.13-14, p.31]

| # | Block | Size | Count | Notes |
|---|---|---|---|---|
| 0 | SEG-Y Tape Label | 128 | 0/1 | Tape only; but a label "may have been copied in front of the Textual File Header" of a disk file [p.32 fn18]. See §6.8. |
| 1 | Textual File Header | 3200 | 1 | EBCDIC or ASCII. Never byte-swapped. |
| 2 | Binary File Header | 400 | 1 | File bytes 3201-3600. Byte order per 3297-3300. |
| 3 | Extended Textual File Header records | 3200 each | N ≥ 0 | N from 3505-3506 / 3521-3528 (§6.2). Text or binary stanzas. Never byte-swapped. |
| 4 | Data trace records | 240·(1+k) + ns·bps | M | Standard Trace Header, then k additional 240-byte headers (Ext 1 first, then proprietary), then samples. M from 3513-3520 if non-zero. |
| 5 | Data Trailer records | 3200 each | T ≥ 0 | T from 3529-3532 (−1 = unknown, 0 or more). Stanza format. Never byte-swapped. |

- Byte-order rule: values in the Binary File Header, all trace headers (except 8-char names) and trace samples
  follow the marker in 3297-3300; text blocks (textual, extended textual, trailer) are never reordered
  [p.6 fn3, p.12, p.37].
- All binary header / SEG trace header values are two's complement (2, 4 or 8 bytes) **except** the
  8-char extension names, the IEEE f64 fields, and "fields that cannot be negative such as the number of
  samples per trace" [p.6]. Zero = unknown/unspecified unless stated otherwise [p.7, p.9 fn6, p.19 fn11, p.28 fn16].

### 2.2 Disk file (App. A) [p.32]

```
offset 0                    : [optional copied 128-byte tape label — see §6.8]
offset L                    : textual header (3200)            L = 0 or 128
offset L+3200               : binary header (400)
offset L+3600               : extended textual records, 3200 each (N)
offset L+3600+3200*N        : trace 1: 240 std header [+ 240*k extra headers] + ns*bps samples
                              trace 2 immediately after, ...
after last trace            : trailer records, 3200 each (T)
```

- No padding/record markers. Disk file may be big-endian or little-endian (or pair-swapped) per 3297-3300 [p.32].
- Text may be EBCDIC or ASCII (UTF-8) [p.32].

### 2.3 Tape

Unchanged from rev 1 (rev1 §2.3-2.4): App. B label rules [p.33] and App. C blocking [p.36] are word-for-word
the same except label revision `SY2.1` and the remark that label field 4 = `B2` is appropriate (`B1` requires a
file mark after the label) [p.34].

> **AMBIGUITY:** [p.36] App. C lists SEG-Y record types as textual, binary, extended textual and trace
> records; Data Trailer records (new in rev 2) are not mentioned. Assume each 3200-byte trailer record is
> also one SEG-Y record for blocking purposes.

## 3. Header tables

### 3.1 Textual File Header [p.7-8]

Layout unchanged (rev1 §3.1): 40 × 80-byte cards, `C` in col 1, card number cols 2-3. Changes:

| Card | Rev 2.1 content |
|---|---|
| C39 | `SEG-Y_REV2.1` (Table 1 example). "It is mandatory that the SEG-Y revision level now be included in the Textual File Header" [p.8]. |
| C40 | `END TEXTUAL HEADER` (preferred) or `END EBCDIC` (fn5) [p.8]. |
| — | ASCII now allowed for all Textual File Headers [p.7]. |

> **AMBIGUITY:** [p.8] "C39 SEG-Y_ REV2.1" — extraction inserts a space; text is `SEG-Y_REV2.1`. Rev 1 used
> `SEG Y REV1`. The verification file has `SEG Y REV 21` in **C24** and unrelated text in C39/C40 (§9). Readers
> must not require the C39/C40 contents; use binary 3501-3502.

### 3.2 Binary File Header (400 bytes; file bytes 3201-3600; absolute numbering) [p.9-14]

Byte order of every multi-byte field below is governed by 3297-3300 (§6.1). Rev-1 "mandatory/recommended"
markers were mostly removed in rev 2 [p.4]; only those still printed are noted.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 3201-3204 | | 4b | i32 | `jobId` | Job identification number. |
| 3205-3208 | | 4b | i32 | `lineNumber` | Line number; 3-D poststack: typically in-line number. |
| 3209-3212 | | 4b | i32 | `reelNumber` | Reel number. |
| 3213-3214 | | 2b | i16 | `dataTracesPerEnsemble` | Data traces per ensemble. Mandatory for prestack. Overridden by 3261-3264 if non-zero. |
| 3215-3216 | | 2b | i16 | `auxTracesPerEnsemble` | Aux traces per ensemble. Mandatory for prestack. Overridden by 3265-3268 if non-zero. |
| 3217-3218 | | 2b | u16 | `sampleInterval` | Sample interval: µs (time), Hz (frequency), m or ft (depth). Overridden by 3273-3280 if non-zero. Primary trace set. |
| 3219-3220 | | 2b | u16 | `sampleIntervalOrig` | Sample interval of original field recording, same units. Overridden by 3281-3288. |
| 3221-3222 | | 2b | u16 | `samplesPerTrace` | Samples per data trace (primary set). Overridden by 3269-3272. |
| 3223-3224 | | 2b | u16 | `samplesPerTraceOrig` | Samples per trace, original field recording. Overridden by 3289-3292. |
| 3225-3226 | | 2b | i16 | `formatCode` | Data sample format code, §4.1. **Mandatory for all data.** |
| 3227-3228 | | 2b | i16 | `ensembleFold` | Expected data traces per ensemble (e.g. CMP fold). Overridden by 3293-3296. |
| 3229-3230 | | 2b | i16 | `traceSorting` | Trace sorting code, rev1 C2 (unchanged). |
| 3231-3232 | | 2b | i16 | `verticalSumCode` | As rev 1 (see rev1 AMBIGUITY). |
| 3233-3234 | | 2b | i16 | `sweepFreqStart` | Hz. |
| 3235-3236 | | 2b | i16 | `sweepFreqEnd` | Hz. |
| 3237-3238 | | 2b | i16 | `sweepLength` | ms. |
| 3239-3240 | | 2b | i16 | `sweepType` | rev1 C5. |
| 3241-3242 | | 2b | i16 | `sweepChannel` | Trace number of sweep channel. |
| 3243-3244 | | 2b | i16 | `sweepTaperStart` | ms. |
| 3245-3246 | | 2b | i16 | `sweepTaperEnd` | ms. |
| 3247-3248 | | 2b | i16 | `taperType` | rev1 C6. |
| 3249-3250 | | 2b | i16 | `correlated` | 1 = no, 2 = yes. |
| 3251-3252 | | 2b | i16 | `binaryGainRecovered` | 1 = yes, 2 = no. |
| 3253-3254 | | 2b | i16 | `amplitudeRecovery` | rev1 C4. |
| 3255-3256 | | 2b | i16 | `measurementSystem` | 1 = meters, 2 = feet. Last Location Data stanza wins on conflict. **New:** if units are mixed (e.g. m on surface, ft in depth) a Location Data stanza is mandatory [p.11]. |
| 3257-3258 | | 2b | i16 | `impulsePolarity` | 1 = pressure increase / upward case movement → negative; 2 → positive. |
| 3259-3260 | | 2b | i16 | `vibratoryPolarity` | rev1 C7. |
| 3261-3264 | | 4b | u32 | `extDataTracesPerEnsemble` | **New.** If non-zero overrides 3213-3214. |
| 3265-3268 | | 4b | u32 | `extAuxTracesPerEnsemble` | **New.** If non-zero overrides 3215-3216. |
| 3269-3272 | | 4b | u32 | `extSamplesPerTrace` | **New.** If non-zero overrides 3221-3222. |
| 3273-3280 | | 8b | f64 | `extSampleInterval` | **New.** IEEE double. If non-zero overrides 3217-3218, same units. |
| 3281-3288 | | 8b | f64 | `extSampleIntervalOrig` | **New.** IEEE double. If non-zero overrides 3219-3220. |
| 3289-3292 | | 4b | u32 | `extSamplesPerTraceOrig` | **New.** If non-zero overrides 3223-3224. |
| 3293-3296 | | 4b | u32 | `extEnsembleFold` | **New.** If non-zero overrides 3227-3228. |
| 3297-3300 | | 4b | u32 | `byteOrderMarker` | **New.** Constant 16909060 = 0x01020304 written in the file's byte order. Read raw bytes: `01 02 03 04` = big-endian; `04 03 02 01` = little-endian (reverse every field); `02 01 04 03` = pairwise byte-swapped; `00 00 00 00` = pre-rev-2 big-endian. Algorithm §6.1. |
| 3301-3500 | | 200b | — | `unassigned1` | Unassigned. |
| 3501 | | 1b | u8 | `segyMajor` | **Changed:** major revision, 8-bit unsigned. Rev 2.1 = 0x02. 0 = 1975 "traditional" SEG-Y. Mandatory. |
| 3502 | | 1b | u8 | `segyMinor` | **Changed:** minor revision, 8-bit unsigned, "radix point between the first and second bytes". Rev 2.1 = 0x01. Mandatory. |
| 3503-3504 | | 2b | i16 | `fixedLengthTraces` | 1 = every trace has the same sample interval (3217-3218 or 3273-3280), the same number of trace header blocks (3507-3508) and the same sample count (3221-3222 or 3269-3272); also the same header sequence and sample type in every trace [p.19]. 0 = may vary: read trace 115-116 and, if present, Ext1 137-140. Mandatory. Clarification recommends 1 [clar p.5]. |
| 3505-3506 | | 2b | i16 | `numExtTextHeaders` | Count of 3200-byte extended textual records. 0 = none; >0 = exactly that many; −1 = variable, ended by `((SEG:EndText))`. If 3521-3528 non-zero, that field overrides this one. If count > 32767: write −1 here and 3521-3528 = 3600 + 3200·N (+128 if a tape label is present). |
| 3507-3508 | | 2b | u16 | `maxAddlTraceHeaders` | **New (2.1 width).** Maximum number of additional 240-byte trace headers per trace (0 = none; up to 65535 [p.4]). Per-trace actual count in Ext1 157-158. |
| 3509-3510 | | 2b | u16 | `surveyType` | **New in 2.1.** Sum of one code from each group, §4.3. |
| 3511-3512 | | 2b | i16 | `timeBasisCode` | **New.** File-level time basis, §4.4. Trace 167-168 overrides if non-zero. |
| 3513-3520 | | 8b | u64 | `numTraces` | **New.** Number of traces in file/stream. 0 = unknown: watch Ext1 159-160 end-of-data flag if present, else all remaining bytes are traces (minus trailer). |
| 3521-3528 | | 8b | u64 | `firstTraceOffset` | **New.** Byte offset of first trace from start of file/stream, includes 3600 + extended headers (+128 if tape label). 0 = unknown. Non-zero overrides the offset implied by a non-negative 3505-3506. |
| 3529-3532 | | 4b | i32 | `numTrailerRecords` | **New.** Number of 3200-byte Data Trailer records after the last trace. 0 = none; −1 = unknown (0 or more). |
| 3533-3600 | | 68b | — | `unassigned2` | Unassigned. |

Coverage: 3201-3212 (12) + 3213-3260 (24×2 = 48) + 3261-3272 (12) + 3273-3288 (16) + 3289-3300 (12) +
3301-3500 (200) + 3501-3502 (2) + 3503-3512 (5×2 = 10) + 3513-3528 (16) + 3529-3532 (4) + 3533-3600 (68) = 400.

> **AMBIGUITY:** [p.6, p.9] "values … two's complement, or unsigned"; only fields "that cannot be negative
> such as the number of samples" are unsigned, with no per-field list for the binary header. This note uses
> u16 for 3217-3224 (ns/dt, matching the D-7 SEG00000 mapping of trace ns/dt as format 11 [p.48]) and u32/u64
> for the new extended counts ("up to 2³²−1 samples … 2⁶⁴−1 traces … 2³²−1 traces per ensemble" [p.4]).
> 3213-3216 and 3227-3228 kept i16 as in rev 1. For values ≤ 32767 both readings agree. See Q1.

> **AMBIGUITY:** [p.12] Marker decimals have the subscript glued: "1690906010 (0102030416)" = 16909060₁₀
> (0x01020304); "6730598510 (0403020116)" = 67305985₁₀ (0x04030201); "3362099510 (0201040316)" = 33620995₁₀
> (0x02010403). Values verified arithmetically.

> **AMBIGUITY:** [p.13] "0216" / "0116" = 0x02 / 0x01 (subscript glued).

> **AMBIGUITY:** [p.4, p.13] Rev 2.0 defined 3507-3510 as a single 4-byte "maximum number of additional trace
> headers" (SEG-Yrev2Release.txt Table 2). Rev 2.1 shrinks it to 3507-3508 and inserts survey type at
> 3509-3510 [p.4 "Binary header bytes 3507-10 changed"]. A big-endian rev 2.0 file with 1 extra header stores
> `00 00 00 01`, which a 2.1 layout reads as maxAddl = 0, surveyType = 1. **Branch on 3501-3502** (§6.6).
> Trace Ext1 157-158 [p.30] still says "Binary File Header bytes 3507–3510" (stale 2.0 text); read as 3507-3508.

> **AMBIGUITY:** [p.12] Signedness of 3293-3296 extended fold and 3261-3268 not stated; u32 chosen (counts).

### 3.3 Extended Textual File Header records (3200 bytes each) [p.15-18, clar p.6-12]

Each record: 3200 bytes, EBCDIC or ASCII text **or binary stanza data** (clarification). The 40×80 line
restriction is removed; lines end in CR LF and "need not be 80 characters long" [p.4, p.16 fn9]. All records
concatenate into one logical stream [p.16].

Rev 2.1 + clarification rules (supersede rev1 §3.3 where different):

| Rule | Detail | Source |
|---|---|---|
| Stanza start | Every stanza begins on a **3200-byte record boundary** with its stanza name at byte 1 of the record. | [p.4, p.16], [clar p.7] |
| Stanza name syntax | `((COMPANY:DATANAME[:CONTENTTYPE][:BYTES]))`. `((` = EBCDIC 0x4D4D / ASCII 0x2828; `))` = 0x5D5D / 0x2929; `:` = 0x7A / 0x3A. COMPANY and DATANAME mandatory; CONTENTTYPE = IANA media type (optional for text); BYTES = decimal size of embedded data, **mandatory for binary data**, excludes the stanza name itself. | [clar p.8] |
| Name matching | Case-insensitive; spaces ignored (as rev 1). Rev-1 style `((SEG: Location Data ver 1.0))` still valid. | [p.16], [p.38] |
| Data start | Stanza data begins **immediately** after `))` (no line break required): "Any content following the closing parentheses is considered to be part of the Stanza data". | [clar p.8, p.9 rule 4] |
| Stanza extent | Name appears only in the first record; data continues through following records until the next record that starts a stanza (or EndText). | [clar p.4, p.7] |
| Padding | Unused bytes of a stanza's last record: SPACE (ASCII 0x20 / EBCDIC 0x40) for text, NUL 0x00 for binary. | [clar p.7, p.9 rule 6] |
| Native format | Stanzas written in native format, not converted (e.g. Layout XML not converted to EBCDIC). EBCDIC and ASCII stanzas may be mixed in one file. | [clar p.9 rules 1, 3, 5] |
| Layout stanza | `((SEG:Layout:text/xml))` (D-8 XML) "should" be present; "recommended that all rev 2.1 files must list" it; mandatory for legacy files brought into 2.1 compliance with non-standard header locations. | [clar p.9 rules 1, 2, 8] |
| EndText | Last record **must** be `((SEG:EndText))` whenever 3505-3506 ≠ 0 (both −1 and > 0), counted in N. Stanza name at byte 1, rest of record SPACE-padded (empty stanza). | [clar p.5, p.9 rule 7] overrides [p.17] ("optional when > 0") |
| Count = 0 | No extended records, no EndText; first trace header follows binary header. | [clar p.6] |
| Keyword/value stanzas | Rules unchanged from rev1 §3.3 (`keyword = value`, `#` comment, `&` continuation — "blank lines and comments are bypassed when continuing" [p.17] is new). | [p.16-17] |
| Bytes in SEG stanzas | All SEG-defined stanzas encode numbers as text; binary data may appear in user stanzas. | [p.15 fn7] |

Predefined stanza names [clar p.12]:

| Company | Data name | Content type | Use |
|---|---|---|---|
| SEG | Layout | text/xml | Trace header layout (D-8, §7.3) |
| SEG | EndText | — | Terminator |
| SEG | Catalog | application/json | Additional survey information |
| OGP | P1/11 | text/csv | IOGP P1/11 (CRS etc., D-1) |
| OGP | P6/11 | text/csv | IOGP P6/11 (bin grid, D-2) |
| OGP | P1/90 | text/plain | IOGP P1/90 |
| OGP | P6/98 | text/plain | IOGP P6/98 |

Other SEG names in the main doc: `((SEG: Trace Header Mapping ver 1.0))` (D-7, deprecated), `((SEG:UserData))` /
`((SEG:User Data ver 1.0))` (D-9), D-3..D-6 stanzas (rev1 §7 D-4..D-7), rev-1 Location Data / Bin Grid / Extent /
Coverage stanzas (deprecated, still allowed [p.4, p.37, p.39]).

> **AMBIGUITY:** [p.17] EndText "optional" when 3505-3506 > 0 (main doc) vs "must" [clar p.9 rule 7]. The
> clarification wins: writers always emit EndText; readers with N > 0 should trust N and treat a missing
> EndText as a warning (pre-clarification files).

> **AMBIGUITY:** [p.37, p.38 vs clar p.12] Main doc spells the IOGP stanza `((OGP:P1/11 CRS))`; clarification and
> the verification file use `((OGP:P1/11))` / `((OGP:P6/11))`. Accept both (match on COMPANY + DATANAME prefix).

> **AMBIGUITY:** [p.17] "&… ASCII 1616" again (as rev 1): use 0x26.

> **AMBIGUITY:** [p.16-17, p.38, clar p.7] CR LF line ends (main) vs P1/11 "CR and/or LF" and non-text stanzas.
> Verification file's Layout stanza uses bare LF. Reader: accept CR, LF or CRLF.

> **AMBIGUITY:** [clar p.8] Verification file writes `((SEG:LAYOUT:text/xml:))` — trailing `:` with empty BYTES.
> Parse fields by splitting on `:` and treat empty trailing fields as absent. Note CONTENTTYPE itself may contain
> `/` and `+` but not `:`; DATANAME may contain `/` (`P1/11`).

### 3.4 Standard Trace Header (240 bytes, `SEG00000`) [p.19-27]

Full re-tabulation (changed rows marked **Δ**). Byte order per 3297-3300. Scalars: **E** = 69-70, **C** = 71-72,
**T** = 215-216. `[L:x]` = name in the rev-2 Layout example (Fig. 3 [p.57-59]); SU names (D-7) are in §7.2.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-4 | | 4b | i32 | `traceSeqLine` | Trace sequence number within line; continues across files. Ext1 1-8 overrides if non-zero. [L:linetrc] |
| 5-8 | | 4b | i32 | `traceSeqFile` | Trace sequence number within file, starts at 1. Ext1 9-16 overrides. [L:reeltrc] |
| 9-12 | | 4b | i32 | `fieldRecord` | Original field record number. Ext1 17-24 overrides. [L:ffid] |
| 13-16 | | 4b | i32 | `traceNumberInField` | **Δ** Trace number within field record. Multi-cable with repeated channel numbers: put cable ID in Ext1 153-156, or store `(cable−1)*nchanPerCable + channel` here. [L:chan] |
| 17-20 | | 4b | i32 | `energySourcePoint` | Energy source point number; use 197-202 for shotpoint. [L:espnum] |
| 21-24 | | 4b | i32 | `ensembleNumber` | Ensemble (CDP/CMP/CRP) number. Ext1 25-32 overrides. [L:cdp] |
| 25-28 | | 4b | i32 | `traceInEnsemble` | Trace number within ensemble, starts at 1. [L:cdptrc] |
| 29-30 | | 2b | i16 | `traceIdCode` | **Δ** Trace identification code, §4.5 (codes 23-41 new; 256..16383 optional; +16384 = interpolated). [L:trctype] |
| 31-32 | | 2b | i16 | `numVertSummed` | Vertically summed traces (1 = one). [L:vstack] |
| 33-34 | | 2b | i16 | `numHorzStacked` | Horizontally stacked traces (1 = one). [L:fold] |
| 35-36 | | 2b | i16 | `dataUse` | 1 = production, 2 = test. [L:rectype] |
| 37-40 | | 4b | i32 | `offset` | Source-to-receiver-group distance; negative if opposite to shooting direction. Ext1 129-136 overrides. [L:offset] |
| 41-44 | | 4b | i32 | `receiverElevation` | **Δ** Receiver group elevation. ×E. Units 3255-3256. Sign tied to the vertical CRS (D-1 stanza); historically above datum +. Ext1 33-40 overrides. [L:relev] |
| 45-48 | | 4b | i32 | `sourceSurfaceElevation` | Surface elevation at source. ×E. Ext1 49-56 overrides. [L:selev] |
| 49-52 | | 4b | i32 | `sourceDepth` | Source depth below surface (historically + below). ×E. Ext1 57-64 overrides. [L:sdepth] |
| 53-56 | | 4b | i32 | `receiverDatumElevation` | **Δ** Seismic Datum elevation at receiver group (vertical CRS in stanza if ≠ survey datum). ×E. Ext1 65-72. [L:rdatum] |
| 57-60 | | 4b | i32 | `sourceDatumElevation` | **Δ** Seismic Datum elevation at source. ×E. Ext1 73-80. [L:sdatum] |
| 61-64 | | 4b | i32 | `sourceWaterDepth` | **Δ** Water column height at source (at time of source event). ×E. Ext1 81-88. [L:wdepthso] |
| 65-68 | | 4b | i32 | `groupWaterDepth` | **Δ** Water column height at receiver group (at first recorded source event). ×E. Ext1 89-96. [L:wdepthrc] |
| 69-70 | | 2b | i16 | `elevationScalar` | **Δ** Scalar for 41-68: 1, ±10, ±100, ±1000, ±10000; >0 multiply, <0 divide; **0 = 1** (now explicit). [L:ed_scal] |
| 71-72 | | 2b | i16 | `coordinateScalar` | **Δ** Scalar for 73-88 and 181-188; same rule, **0 = 1**. [L:co_scal] |
| 73-76 | | 4b | i32 | `sourceX` | ×C. Units per 89-90. CRS via D-1 stanza. Ext1 97-104. [L:sht_x] |
| 77-80 | | 4b | i32 | `sourceY` | ×C. Ext1 105-112. [L:sht_y] |
| 81-84 | | 4b | i32 | `groupX` | ×C. Ext1 113-120. [L:rec_x] |
| 85-88 | | 4b | i32 | `groupY` | ×C. Ext1 121-128. [L:rec_y] |
| 89-90 | | 2b | i16 | `coordinateUnits` | **Δ** 1 = length; 2 = seconds of arc (**deprecated**); 3 = decimal degrees (**preferred**); 4 = DMS. DMS encoding as rev1 §6.4, now printed with `+ ss` term. [L:coorunit] |
| 91-92 | | 2b | i16 | `weatheringVelocity` | ft/s or m/s per 3255-3256. [L:wvel] |
| 93-94 | | 2b | i16 | `subweatheringVelocity` | ft/s or m/s. [L:subwvel] |
| 95-96 | | 2b | i16 | `upholeTimeSource` | ms ×T. [L:shuphole] |
| 97-98 | | 2b | i16 | `upholeTimeGroup` | ms ×T. [L:rcuphole] |
| 99-100 | | 2b | i16 | `sourceStatic` | ms ×T. [L:shstat] |
| 101-102 | | 2b | i16 | `groupStatic` | ms ×T. [L:rcstat] |
| 103-104 | | 2b | i16 | `totalStatic` | ms ×T; 0 = none applied. [L:stapply] |
| 105-106 | | 2b | i16 | `lagTimeA` | ms ×T. [L:lagtimea] |
| 107-108 | | 2b | i16 | `lagTimeB` | ms ×T. [L:lagtimeb] |
| 109-110 | | 2b | i16 | `delayRecordingTime` | ms ×T; may be negative; note in textual header if non-zero. [L:delay] |
| 111-112 | | 2b | i16 | `muteStart` | ms ×T. [L:mutestrt] |
| 113-114 | | 2b | i16 | `muteEnd` | ms ×T. [L:muteend] |
| 115-116 | | 2b | u16 | `numSamples` | **Δ** Samples in this trace. Ext1 137-140 overrides if non-zero. If fixed-length flag (3503) = 1 the binary-header value applies and **this field is ignored**. [L:nsamps] |
| 117-118 | | 2b | u16 | `sampleInterval` | **Δ** Sample interval: µs (time), Hz (frequency), m/ft (depth). Ext1 145-152 overrides if non-zero. Ignored when fixed-length flag = 1. [L:dt] |
| 119-120 | | 2b | i16 | `gainType` | 1 fixed, 2 binary, 3 floating point, 4..N optional. [L:gaintype] |
| 121-122 | | 2b | i16 | `instrumentGainConstant` | dB. [L:ingconst] |
| 123-124 | | 2b | i16 | `instrumentInitialGain` | dB. [L:initgain] |
| 125-126 | | 2b | i16 | `correlated` | 1 no, 2 yes. [L:corrflag] |
| 127-128 | | 2b | i16 | `sweepFreqStart` | Hz. [L:sweepsrt] |
| 129-130 | | 2b | i16 | `sweepFreqEnd` | Hz. [L:sweepend] |
| 131-132 | | 2b | i16 | `sweepLength` | ms. [L:sweeplng] |
| 133-134 | | 2b | i16 | `sweepType` | rev1 C5. [L:sweeptyp] |
| 135-136 | | 2b | i16 | `sweepTaperStart` | ms. [L:sweepstp] |
| 137-138 | | 2b | i16 | `sweepTaperEnd` | ms. [L:sweepetp] |
| 139-140 | | 2b | i16 | `taperType` | rev1 C6. [L:tapertyp] |
| 141-142 | | 2b | i16 | `aliasFilterFreq` | Hz. [L:aliasfil] |
| 143-144 | | 2b | i16 | `aliasFilterSlope` | dB/oct. [L:aliaslop] |
| 145-146 | | 2b | i16 | `notchFilterFreq` | Hz. [L:notchfil] |
| 147-148 | | 2b | i16 | `notchFilterSlope` | dB/oct. [L:notchslp] |
| 149-150 | | 2b | i16 | `lowCutFreq` | Hz. [L:lowcut] |
| 151-152 | | 2b | i16 | `highCutFreq` | Hz. [L:highcut] |
| 153-154 | | 2b | i16 | `lowCutSlope` | dB/oct. [L:lowcslop] |
| 155-156 | | 2b | i16 | `highCutSlope` | dB/oct. [L:hicslop] |
| 157-158 | | 2b | i16 | `year` | 4-digit Gregorian year (rev ≥ 1). [L:year] |
| 159-160 | | 2b | i16 | `dayOfYear` | **Δ** 1-366 for GMT, UTC and GPS time basis. [L:day] |
| 161-162 | | 2b | i16 | `hour` | 0-23. [L:hour] |
| 163-164 | | 2b | i16 | `minute` | [L:minute] |
| 165-166 | | 2b | i16 | `second` | Ext1 141-144 adds nanoseconds. [L:second] |
| 167-168 | | 2b | i16 | `timeBasisCode` | **Δ** §4.4 (5 = GPS new). If non-zero overrides binary 3511-3512. [L:timebase] |
| 169-170 | | 2b | i16 | `traceWeightingFactor` | **Δ** LSB = 2^−N units (volts unless 203-204 says otherwise), N = 0..32767. [L:trweight] |
| 171-172 | | 2b | i16 | `rollSwitchGroup` | [L:rstaswp1] |
| 173-174 | | 2b | i16 | `firstTraceGroup` | [L:rstatrc1] |
| 175-176 | | 2b | i16 | `lastTraceGroup` | [L:rstatrcn] |
| 177-178 | | 2b | i16 | `gapSize` | [L:gapsize] |
| 179-180 | | 2b | i16 | `overTravel` | 1 down/behind, 2 up/ahead. [L:overtrvl] |
| 181-184 | | 4b | i32 | `cdpX` | Ensemble X. ×C. Ext1 161-168 overrides. [L:cdp_x] |
| 185-188 | | 4b | i32 | `cdpY` | Ensemble Y. ×C. Ext1 169-176 overrides. [L:cdp_y] |
| 189-192 | | 4b | i32 | `inlineNumber` | 3-D poststack in-line. [L:iline] |
| 193-196 | | 4b | i32 | `crosslineNumber` | 3-D poststack cross-line. [L:xline] |
| 197-200 | | 4b | i32 | `shotpointNumber` | Scaled by 201-202. [L:sp] |
| 201-202 | | 2b | i16 | `shotpointScalar` | >0 ×, <0 ÷, 0 = not scaled. [L:sp_scal] |
| 203-204 | | 2b | i16 | `traceValueUnit` | **Δ** §4.6 (10-255 reserved, 256..32767 optional). [L:samp_unit] |
| 205-208 | | 4b | i32 | `transductionMantissa` | Constant = mantissa × 10^exponent. [L:trans_const (scale6)] |
| 209-210 | | 2b | i16 | `transductionExponent` | |
| 211-212 | | 2b | i16 | `transductionUnits` | §4.6 (codes −1..9). [L:trans_unit] |
| 213-214 | | 2b | i16 | `deviceTraceId` | Device/trace identifier. [L:dev_id] |
| 215-216 | | 2b | i16 | `timeScalar` | Scalar for 95-114; 0 = 1. [L:tm_scal] |
| 217-218 | | 2b | i16 | `sourceTypeOrientation` | rev1 C12. [L:src_type] |
| 219-220 | | 2b | i16 | `sourceEnergyDirVert` | **Δ** Now defined: three i16 — vertical inclination, tenths of degree (347.8° → 3478 = 0x0D96). [L:src_dir1] |
| 221-222 | | 2b | i16 | `sourceEnergyDirXline` | **Δ** Cross-line inclination, tenths of degree. [L:src_dir2] |
| 223-224 | | 2b | i16 | `sourceEnergyDirInline` | **Δ** In-line inclination, tenths of degree. [L:src_dir3] |
| 225-228 | | 4b | i32 | `sourceMeasurementMantissa` | Source measurement = mantissa × 10^exponent. [L:smeasure (scale6)] |
| 229-230 | | 2b | i16 | `sourceMeasurementExponent` | |
| 231-232 | | 2b | i16 | `sourceMeasurementUnit` | rev1 C13 (duplicate code 4 still present [p.27]). [L:sm_unit] |
| 233-240 | | 8b | ascii (or ebcdic) | `headerName` | **Δ** Was unassigned. Either 8 binary zeros or `SEG00000`, ASCII or EBCDIC. Not byte-swapped. |

Coverage: identical field boundaries to rev1 §3.4 (240 bytes) with 219-224 split into 3×2 and 233-240 assigned.

> **AMBIGUITY:** [p.26-27, p.48, p.59] Signedness of 115-118: Table 3 gives none; D-7 mapping uses format 11
> (u16) for ns and dt [p.48], Fig. 3 layout uses `int2` [p.58]. This note uses u16 (rev1 Q1 resolved in favour
> of u16). Trace sequence numbers 1-8: D-7 format 2 (i32), Layout type `linetrc`/`reeltrc` = "4-byte unsigned"
> [p.56]. Kept i32; values ≥ 2³¹ unlikely.

> **AMBIGUITY:** [p.26 vs p.21] 215-216 scalar still listed as "1, +10, +100, +1000, or +10,000" while 69-72 now
> say ±; treat as ±, 0 = 1.

> **AMBIGUITY:** [p.27] Source Measurement exponent again cited as "bytes 209–230"; it is 229-230 (formula on
> same page). Duplicate code 4 (Bar / Bar-meter) unchanged — rev1 Q5.

> **AMBIGUITY:** [p.22] DMS: "±DDD*104 + MM*102 + SS" = ±(DDD·10⁴ + MM·10² + SS) with 71-72 = 1;
> "±DDD*106 + MM*104 + SS*102 + ss" = ±(DDD·10⁶ + MM·10⁴ + SS·10² + ss) with 71-72 = −100. Footnote 14 says
> "±DDMMSS.ss" (two D's) — typo.

> **AMBIGUITY:** [p.24] "200110 (07D116)" = 2001₁₀ (0x07D1); [p.27] "347810 (0D9616)" = 3478₁₀ (0x0D96).

### 3.5 SEG-Y Trace Header Extension 1 (240 bytes, `SEG00001`) [p.28-30]

**New.** Optional; if present must immediately follow the Standard Trace Header. **Mandatory if any proprietary
extension is present** [p.18-19]. Override fields apply only when non-zero. Byte order per 3297-3300.
Signs of 33-96 follow the vertical CRS of the Location Data stanza.

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-8 | | 8b | u64 | `extTraceSeqLine` | Overrides std 1-4. [L:linetrc8] |
| 9-16 | | 8b | u64 | `extTraceSeqFile` | Overrides std 5-8. [L:reeltrc8] |
| 17-24 | | 8b | i64 | `extFieldRecord` | Overrides std 9-12. |
| 25-32 | | 8b | i64 | `extEnsembleNumber` | Overrides std 21-24. |
| 33-40 | | 8b | f64 | `extReceiverElevation` | Overrides std 41-44 (no scalar). |
| 41-48 | | 8b | f64 | `receiverDepth` | Receiver group depth below its surface location, + below. No std counterpart; **not** an override (no if-non-zero) [p.28 fn17, p.59]. |
| 49-56 | | 8b | f64 | `extSourceSurfaceElevation` | Overrides std 45-48. |
| 57-64 | | 8b | f64 | `extSourceDepth` | Overrides std 49-52. |
| 65-72 | | 8b | f64 | `extReceiverDatumElevation` | Overrides std 53-56. |
| 73-80 | | 8b | f64 | `extSourceDatumElevation` | Overrides std 57-60. |
| 81-88 | | 8b | f64 | `extSourceWaterDepth` | Overrides std 61-64. |
| 89-96 | | 8b | f64 | `extGroupWaterDepth` | Overrides std 65-68. |
| 97-104 | | 8b | f64 | `extSourceX` | Overrides std 73-76. |
| 105-112 | | 8b | f64 | `extSourceY` | Overrides std 77-80. |
| 113-120 | | 8b | f64 | `extGroupX` | Overrides std 81-84. |
| 121-128 | | 8b | f64 | `extGroupY` | Overrides std 85-88. |
| 129-136 | | 8b | f64 | `extOffset` | Overrides std 37-40. |
| 137-140 | | 4b | u32 | `extNumSamples` | Overrides std 115-116. |
| 141-144 | | 4b | i32 | `nanoseconds` | Nanoseconds to add to second of minute (std 165-166); may be negative. |
| 145-152 | | 8b | f64 | `extSampleInterval` | "microsecond sample interval"; overrides std 117-118 if non-zero. |
| 153-156 | | 4b | i32 | `cableNumber` | Cable number (multi-cable) or recording device/sensor ID. |
| 157-158 | | 2b | u16 | `numAddlTraceHeaders` | Number of additional trace header blocks **including this one** (i.e. headers after the standard one). 0 = use binary 3507-3508. |
| 159-160 | | 2b | u16 (bits) | `lastTraceFlag` | Sum of: 1 = last trace in ensemble; 2 = last in line; 4 = last in this file/stream; 8 = last in survey. 0 otherwise. |
| 161-168 | | 8b | f64 | `extCdpX` | Overrides std 181-184. |
| 169-176 | | 8b | f64 | `extCdpY` | Overrides std 185-188. |
| 177-232 | | 56b | — | `reserved` | Reserved. |
| 233-240 | | 8b | ascii (or ebcdic) | `headerName` | `SEG00001`. Not byte-swapped. |

Coverage: 1-32 (4×8 = 32) + 33-136 (13×8 = 104) + 137-140 (4) + 141-144 (4) + 145-152 (8) + 153-156 (4) +
157-160 (2×2 = 4) + 161-176 (2×8 = 16) + 177-232 (56) + 233-240 (8) = 240.

> **AMBIGUITY:** [p.29] 145-152 says "microsecond" but std 117-118 and binary dt may be Hz or m/ft
> (frequency/depth data). Interpret in the same unit as the field it overrides.

> **AMBIGUITY:** [p.32] App. A says the extended sample count is in "bytes 129–132 of SEG-Y Trace Header
> Extension 1"; Table 4, 3503-3504 and D-7/D-8 all say **137-140**. Use 137-140.

> **AMBIGUITY:** [p.28] Table 4 title "Trace Header Extension 116" = "Extension 1" + footnote 16; "below
> surface17" = footnote 17.

> **AMBIGUITY:** [p.59] Fig. 3 layout types `last_trc` (159) as `int2`; D-7 uses format 11 (u16). Bitfield
> values ≤ 15, no practical difference.

### 3.6 Proprietary (user-defined) Trace Header Extension (240 bytes) [p.30, p.18-19]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-232 | | 232b | — | `userData` | User defined. Layout should be described by a `((SEG:Layout))` `<extension name=…>` (D-8) or deprecated `((SEG: Trace Header Mapping))` stanza naming this extension. Byte order of SEG-style numeric fields follows 3297-3300 (see Q4). |
| 233-240 | | 8b | ascii (or ebcdic) | `headerName` | 8-char name, left-justified, blank-padded, printable characters of the chosen set. `SEG00000`..`SEG99999` reserved. |

Ordering rules [p.18-19]:

| Rule |
|---|
| Trace record = std header, then (if any additional headers) Ext1 `SEG00001`, then proprietary extensions, then samples. All SEG-defined headers precede user ones. |
| Proprietary extensions may vary in order and number from trace to trace unless fixed-length flag = 1, in which case every trace has the same header sequence and the same number and type of samples. |
| Per-trace number of additional headers = Ext1 157-158, or binary 3507-3508 if that is 0. |

### 3.7 Data Trailer [p.15, p.31, p.14, p.65-73]

| Item | Rule |
|---|---|
| Position | Immediately after the last trace record. |
| Count | Binary 3529-3532: 0 none, >0 exact, −1 unknown (0 or more). |
| Record | 3200 bytes; "same formatting" as Extended Textual File Header (stanzas). Not byte-swapped. |
| Content | Typically `((SEG:UserData))` blocks (§7.4) — large items (backups, databases) recommended here rather than in the header. |
| Clarification | Explicitly does **not** cover trailers [clar p.1, p.3]. |

> **AMBIGUITY:** [p.14, p.15] Whether a trailer must end with EndText, and whether trailer stanzas follow the
> clarification name/padding rules, is not stated. Recommend: parse with the same rules; do not require EndText.

## 4. Code tables

### 4.1 Data sample format code (binary 3225-3226) [p.10, p.32, p.74-78]

| Code | Format | Bytes/sample | Enc | New in rev 2 |
|---|---|---|---|---|
| 1 | IBM floating point | 4 | ibm32 | |
| 2 | Two's-complement integer | 4 | i32 | |
| 3 | Two's-complement integer | 2 | i16 | |
| 4 | Fixed point with gain (obsolete) | 4 | fixedpt | |
| 5 | IEEE floating point | 4 | f32 | |
| 6 | IEEE floating point (double) | 8 | f64 | yes |
| 7 | Two's-complement integer | 3 | i24 | yes |
| 8 | Two's-complement integer | 1 | i8 | |
| 9 | Two's-complement integer | 8 | i64 | yes |
| 10 | Unsigned integer | 4 | u32 | yes |
| 11 | Unsigned integer | 2 | u16 | yes |
| 12 | Unsigned integer | 8 | u64 | yes |
| 13, 14 | — not defined | — | — | |
| 15 | Unsigned integer | 3 | u24 | yes |
| 16 | Unsigned integer | 1 | u8 | yes |
| 0 | (D-7 mapping stanzas only) ASCII/UTF-8 text | — | ascii | not a sample format [p.43] |

### 4.2 Unchanged code tables
Trace sorting, measurement system, amplitude recovery, sweep type, taper type, vibratory polarity, source
type/orientation, source measurement unit: as rev1 C2-C7, C12, C13 [p.10-12, p.27].

### 4.3 Survey type (binary 3509-3510) — new in 2.1 [p.14]

Value = sum of one code from each group.

| Group | Code | Meaning |
|---|---|---|
| I Environment | 1 | Land |
| | 2 | Marine |
| | 3 | Transition |
| | 4 | Downhole |
| | 5-7 | Reserved |
| II Dimensionality | 8 | 1D |
| | 16 | 2D |
| | 24 | 3D |
| | 32 | Time-lapse (added to one of the three above) |
| | 64-127 | Reserved |
| III Layout | 128 | Parallel lines |
| | 256 | Cross-spread |
| | 684 (sic; see AMBIGUITY) | Patches |
| | 1024 | Towed streamer |
| | 1152 | Ocean bottom sensors/cables |
| | 1280 | Pseudo-random sensor and/or source arrangements |
| | 1281-4095 | Reserved |
| user | 4096-65535 | User defined |

Decode suggestion: `env = v and 7; dim = v and 0x78; layout = v and 0xF80; user = v >= 4096`.

> **AMBIGUITY:** [p.14] "684 = patches" is not a multiple of 128 and would collide with group I/II bits
> (684 = 512+128+32+8+4). Almost certainly a typo for **384** (3×128). Also Group II reserved "64-127" while
> dimension codes use bits 3-5 and time-lapse bit 5 (32); 40/48/56 (= 1D/2D/3D + 32) are the time-lapse combos.
> Store raw; expose decoded groups with an "invalid" flag. See Q5.

### 4.4 Time basis code (binary 3511-3512, trace 167-168) [p.14, p.25]

| Code | Meaning |
|---|---|
| 0 | Unknown / not set (trace: use binary value) |
| 1 | Local |
| 2 | GMT |
| 3 | Other (explain in user stanza) |
| 4 | UTC |
| 5 | GPS — **new** |

### 4.5 Trace identification code (trace 29-30) [p.19-20]

| Code | Meaning |
|---|---|
| −1 | Other |
| 0 | Unknown |
| 1 | **Time domain** seismic data (rev 1: "seismic data") |
| 2-22 | As rev1 C8 (dead, dummy, time break, uphole, sweep, timing, waterbreak, near/far-field gun signature, pressure sensor, multicomponent V/X/I, rotated V/T/R, vibrator reaction mass/baseplate/est. ground force/reference, time-velocity pairs) |
| 23 | Time-depth pairs |
| 24 | Depth-velocity pairs |
| 25 | Depth domain seismic data |
| 26 | Gravity potential |
| 27 | Electric field – vertical |
| 28 | Electric field – cross-line |
| 29 | Electric field – in-line |
| 30 | Rotated electric field – vertical |
| 31 | Rotated electric field – transverse |
| 32 | Rotated electric field – radial |
| 33 | Magnetic field – vertical |
| 34 | Magnetic field – cross-line |
| 35 | Magnetic field – in-line |
| 36 | Rotated magnetic field – vertical |
| 37 | Rotated magnetic field – transverse |
| 38 | Rotated magnetic field – radial |
| 39 | Rotational sensor – pitch |
| 40 | Rotational sensor – roll |
| 41 | Rotational sensor – yaw |
| 42-255 | Reserved |
| 256..N | Optional use, N ≤ 16383 |
| code + 16384 | Interpolated (not original) trace: bit 14 set. Base code = `v and 0x3FFF` for v ≥ 0. |

> **AMBIGUITY:** [p.20] "rev 1 23..32767 optional use" is now restricted to 256..16383; values 16384-32767 mean
> "interpolated". Whether the flag may combine with −1/0 is not stated (−1 has bit 14 set in two's complement).
> Apply the flag only to v ≥ 16384.

### 4.6 Trace value measurement unit (203-204) and transduction units (211-212) [p.26]

As rev1 C11 (−1..9) plus, for **203-204 only**: 10-255 reserved; 256..N optional use, N ≤ 32767.

## 5. Data sample formats (App. E) [p.74-78]

All layouts are given **big-endian** (bit 0 = MSB of byte 1). In a non-big-endian file, each sample is first
byte-reordered per §6.1, then decoded as below [p.74]. Samples contiguous, no padding. Conversion to physical
units: sample × 2^−N (N = trace 169-170) → units of 203-204; then optionally × transduction constant
(205-212). If 203-212 all zero assume volts unless a Data Sample Measurement Unit stanza says otherwise [p.74].

| Code | Layout / formula | Delta vs rev 1 |
|---|---|---|
| 1 ibm32 | `S C6..C0 \| Q-1..Q-24`; v = (−1)^S × (Q/2²⁴) × 16^(C−64). Fraction zero ⇒ whole word 0. Range ±(1−2⁻²⁴). | **Byte 4 now Q-17..Q-24 (24-bit fraction)**; resolves rev1 AMBIGUITY/Q7. |
| 2 i32 | Value = (Σ I_k 2^k + 2³¹) mod 2³² − 2³¹ (two's complement). | Formula clarified. |
| 3 i16 | (Σ + 2¹⁵) mod 2¹⁶ − 2¹⁵. | |
| 4 fixedpt | Byte 1 = 0x00; byte 2 = G7..G0; bytes 3-4 = `S I14..I0`; v = S(I14·2¹⁴+…+I0) × 2^(−G). | Exponent now printed **negative** (2^−G); see AMBIGUITY. |
| 5 f32 | IEEE 754 single (rev1 table). | |
| 6 f64 | S, 11-bit exponent e, 52-bit fraction Q-1..Q-52 (IEEE binary64); e = 2047 & f ≠ 0 NaN; e = 2047 & f = 0 ±∞; 0 < e < 2047: (−1)^s 2^(e−1023)(1.f); e = 0 & f ≠ 0: (−1)^s 2^(−1022)(0.f); e = 0 & f = 0: ±0. | new |
| 7 i24 | 3 bytes `I23..I0`; (Σ + 2²³) mod 2²⁴ − 2²³. Decode: `x = b0 shl 16 or b1 shl 8 or b2; if x >= 0x800000: x -= 0x1000000`. | new |
| 8 i8 | (Σ + 2⁷) mod 2⁸ − 2⁷. | |
| 9 i64 | 8 bytes, (Σ + 2⁶³) mod 2⁶⁴ − 2⁶³. | new |
| 10 u32 | Σ I_k 2^k, k = 0..31. | new |
| 11 u16 | Σ, k = 0..15. | new |
| 12 u64 | Σ, k = 0..63. | new |
| 15 u24 | Σ, k = 0..23 (3 bytes). | new |
| 16 u8 | Σ, k = 0..7. | new |

> **AMBIGUITY:** [p.76] Code 6 diagram labels the exponent bits "C11 C10 … C1" on bytes 1-2 (11 bits after
> S) — printed as `S C11..C5 | C4..C1 Q-1..Q-4`, i.e. 11 exponent bits labelled C11..C1 (rev 2.1) vs C10..C0
> by analogy with code 5. Bit layout is standard IEEE binary64 regardless of labels. "2e-1023" = 2^(e−1023);
> denormal "2e-1022" = 2^(−1022). "f ¹ 0" = f ≠ 0; "¥" = ∞ (Symbol font).

> **AMBIGUITY:** [p.75] Code 4: rev 2.1 prints "* 2–GGGGGGGG" (2^−G) where rev 1 printed a positive
> superscript, and writes the 15-bit magnitude after "S", suggesting sign-magnitude rather than i16. Recommend:
> mantissa = i16(bytes 3-4) (two's complement, as rev 1 note), value = mantissa × 2^(−G), G = u8. Format is
> obsolete; read-only. Updates rev1 Q8.

> **AMBIGUITY:** [p.74-78] Superscripts lost: "231" = 2³¹, "2-24" = 2⁻²⁴, "16(CCCCCCC-64)" = 16^(C−64), etc.

## 6. Derived rules / algorithms

### 6.1 Byte-order detection and application [p.6, p.12, p.30-31, p.74]

```
m = raw bytes at file offset L+3296..L+3299        # never swapped before inspection
case m
  01 02 03 04, 00 00 00 00 -> BE                    # 0 = pre-rev-2 big-endian
  04 03 02 01              -> LE                    # reverse bytes of every field
  02 01 04 03              -> PAIR                  # swap each consecutive byte pair in every field
  else                     -> error / heuristic (Q3)
```

| Scope | Swapped? |
|---|---|
| Binary File Header numeric fields (3201-3600 except unassigned) | yes, per field width |
| Standard trace header, Ext1, proprietary numeric fields | yes, per field width |
| Trace header names 233-240 | no (text) [p.6] |
| Trace samples | yes, per sample width (bps) |
| Textual header, extended textual records, trailer records | never [p.6 fn3, p.12, p.37] |
| 3501, 3502 (single-byte fields) | no-op for LE; see Q2 for PAIR |

LE reversal of a w-byte field = reverse its w bytes (w = 2, 3, 4, 8). PAIR swap of a w-byte field (w even) =
swap bytes (0,1), (2,3), …; for w = 4 that maps `01 02 03 04` ↔ `02 01 04 03`.

> **AMBIGUITY:** [p.12] Pairwise swapping is undefined for 1- and 3-byte fields/samples (formats 7, 8, 15, 16)
> and for the single-byte revision fields. Recommend: treat PAIR + odd-width format as unsupported (error);
> leave 1-byte fields untouched. See Q2.

### 6.2 Locating the first trace [p.13-14, clar p.4-6]

```
L = 128 if copied tape label detected (§6.8) else 0
nExt = i16 @3505 ; off1 = u64 @3521
if off1 != 0: firstTrace = off1                      # authoritative; already includes L per spec
elif nExt > 0: firstTrace = L+3600+3200*nExt
elif nExt == 0: firstTrace = L+3600
else (nExt == -1): walk records from L+3600 (§6.3) until the record that starts ((SEG:EndText)); firstTrace = its end
```
- Rev 2.1 writers: nExt ≠ 0 ⇒ the last extended record is EndText [clar p.9]. Reader may cross-check.
- Record count > 32767 ⇒ 3505 = −1 and 3521 set [p.13].

### 6.3 Walking extended textual records (variable count) [clar p.4, p.7-8]

```
rec = L+3600
loop:
  blk = read 3200 at rec
  if blk starts with "((" (0x2828) or EBCDIC "((" (0x4D4D):
     name = up to first "))" (0x2929 / 0x5D5D); fields = name[2..^3].split(':')
     if norm(name) == "((SEG:ENDTEXT))": rec += 3200; break
     if len(fields) >= 4 and fields[3] is digits:   # binary stanza
        nbytes = len(name) + int(fields[3]); recs = ceil(nbytes/3200)
        rec += 3200*recs; continue                    # do NOT inspect continuation records
  else: continuation of previous stanza
  rec += 3200
```
- Binary stanza continuation records can begin with bytes `28 28` or `4D 4D` by chance; always skip a binary
  stanza by its declared BYTES (§9 file has a 66-record PNG stanza).
- Text stanza with no BYTES: continuation = any following record not starting with `((`.

### 6.4 Effective per-file and per-trace values [p.12-14, p.26-30]

| Quantity | Rule |
|---|---|
| File ns | `u32@3269 if ≠ 0 else u16@3221` |
| File dt | `f64@3273 if ≠ 0 else u16@3217` |
| File ns/dt (original) | 3289 / 3281 overriding 3223 / 3219 |
| Traces/ensemble, aux, fold | 3261 / 3265 / 3293 overriding 3213 / 3215 / 3227 |
| Extra headers k (trace) | if binary 3507 = 0: k = 0 (no Ext1 to read). Else read Ext1 (header 2): `k = u16@Ext1.157 if ≠ 0 else u16@3507` |
| Trace ns | if fixed flag = 1: file ns. Else `u32@Ext1.137 if (k ≥ 1 and ≠ 0) else u16@115` |
| Trace dt | if fixed flag = 1: file dt. Else `f64@Ext1.145 if ≠ 0 else u16@117` |
| Trace record bytes | `240*(1+k) + ns*bps` |
| Any other override pair | Ext1 value if non-zero, else scaled std value |

bps: 1 for 8, 16; 2 for 3, 11; 3 for 7, 15; 4 for 1, 2, 4, 5, 10; 8 for 6, 9, 12 [p.32]. Others → error.

Random access (fixed flag = 1): `offset(trace j) = firstTrace + j*(240*(1+nAddl) + ns*bps)`, nAddl = 3507-3508.

### 6.5 End of traces / trailer [p.14, p.30]

```
if u64@3513 != 0: read exactly that many traces
elif Ext1 present: stop after a trace whose lastTraceFlag has value 4 set (last in file/stream)
elif i32@3529 > 0: stop when remaining bytes == 3200*T
else: traces run to EOF (with T = −1: heuristic — remaining bytes multiple of 3200 and next block starts "((")
trailer = remaining bytes, 3200-byte records
```

### 6.6 Version detection [p.13, p.4]

| 3501 | 3502 | Version | Notes |
|---|---|---|---|
| 0 | 0 | rev 0 | Ignore 3261-3600 fields; big-endian. |
| 1 | 0 | rev 1.0 | 3501-3502 read as u16 = 0x0100; 3261-3500 unassigned; big-endian. |
| 2 | 0 | rev 2.0 | **3507-3510 = u32 maxAddlTraceHeaders**, no survey type; everything else as 2.1. |
| 2 | 1 | rev 2.1 | This note. |
| 2 | >1 | future 2.x | Read as 2.1, warn. |

Byte-order detection (§6.1) must precede reading 3501-3506 (only 3501/3502 are endian-neutral).

### 6.7 Scalars [p.21, p.26]
As rev1 §6.3, but 69-70 and 71-72 now explicitly "0 = 1" (resolves rev1 Q9). f64 Ext1 fields are unscaled.

### 6.8 Tape label (App. B) — delta [p.33-35]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 1-68 | | 68b | ascii | — | Fields 1-9 as rev1 §6.7; field 2 = `SY2.1`; field 3 `RECORD`; field 4 `B2` appropriate (`B1` ⇒ file mark after label). Org codes now assigned by Energistics. |
| 69-80 | | 12b | ascii | `externalLabelName` | Field 11. Non-blank when tape has an external label; right-justified, leading blanks. Required only if it differs from the low 6 chars of the serial number. |
| 81-104 | | 24b | ascii | `recordingEntityName` | Field 12. Originator (field recording or processing); blank if unknown. |
| 105-118 | | 14b | ascii | `userDefined` | Field 13. Any ASCII. |
| 119-128 | | 10b | ascii | `reserved2` | Field 14. All blanks (0x20). |

Bytes 69-128 together = field 10 "Storage Set Identifier" (60 bytes), "subdivided into four individual fields"
(11-14) [p.33, p.35].

Disk-file detection of a copied label [p.32 fn18]: bytes 5-6 = ASCII `SY` and byte 129 = `C` (0xC3 / 0x43) ⇒ L = 128.

> **AMBIGUITY:** [p.35] Field 10 must be identical on all units of a storage set "for the user defined portion";
> which sub-fields are "user defined" is not stated.

### 6.9 Validation rules (2.1 writer must / reader should check)

| Rule | Source |
|---|---|
| 3297-3300 is one of the three marker patterns (or 0 only for pre-rev-2) | [p.12] |
| 3501 = 2, 3502 = 1 | [p.13] |
| 3225 ∈ {1..12, 15, 16} | [p.10] |
| Overriding extended field non-zero ⇒ use it; 16-bit field may be 0 or truncated | [p.12] |
| nExt ≠ 0 ⇒ last extended record is `((SEG:EndText))`, rest blank | [clar p.9] |
| Every stanza starts on a 3200 boundary; binary stanzas declare BYTES; NUL padding for binary | [clar p.7-9] |
| k ≥ 1 ⇒ header 2 named `SEG00001` | [p.18-19, p.30] |
| Proprietary names not in `SEG00000`..`SEG99999` | [p.30] |
| fixed flag = 1 ⇒ same ns, dt, k and header sequence in every trace | [p.13, p.19] |
| 3521 non-zero ⇒ equals actual first-trace offset | [p.14] |
| 3513 non-zero ⇒ equals trace count; 3529 > 0 ⇒ trailer length = 3200·T | [p.14] |

## 7. Appendix D stanzas (delta)

### 7.1 D-1 / D-2 IOGP stanzas [p.37-39]

| Rule |
|---|
| CRS: `((OGP:P1/11 CRS))` (clarification: `((OGP:P1/11))`, text/csv) followed by verbatim P1/11 Common Header records; must begin with the OGP File Identification Record. |
| Bin grid / coverage: `((OGP:P6/11 …))` — e.g. `Coverage Perimeter`, `Bin Node Coordinates` — starting with OGP File ID record and CRS section. |
| `keyword = value`, `#`, `&` rules **do not apply**; P1/11 lines may exceed 80 chars; lines starting `C` are comments; records end with CR and/or LF, consistent within the stanza. |
| Last 3200-byte block padded with spaces (0x20). |
| Rev-1 Location Data / Bin Grid / Extent / Coverage stanzas: deprecated but still allowed (2.0 App. D-3..D-5). |
| D-3..D-6 (Data Sample Measurement Unit, Processing History, Source Type/Orientation, Source Measurement Unit) = rev1 §7 D-4..D-7, unchanged. |

### 7.2 D-7 Trace Header Mapping (deprecated) — `((SEG: Trace Header Mapping ver 1.0))` [p.43-53]

| Keyword | Format | Notes |
|---|---|---|
| Header name | Text 8 | Name in bytes 233-240 of the header mapped; `SEG00000` = standard header. |
| Delete field name | Text | Optional; removes a predefined field; place right after Header name. |
| Field name n | Text | Optional; default `<header>.<byte>` e.g. `USER0001.21`. |
| Byte position n | Integer | 1..240, required. |
| Value format code n | Integer | §4.1 code; **0 = ASCII/UTF-8 text**. Required. |
| Number of values n | Integer | Default 1; byte position + count × width ≤ 241. |
| Field description n | Text | |

SEG00000 SU names and format codes [p.45-51] (all format 2 = i32 or 3 = i16 as in §3.4, except **ns 115 and dt
117 = 11 (u16)**; 219 = 3 × 3 values): tracl 1, tracr 5, fldr 9, tracf 13, ep 17, cdp 21, cdpt 25, trid 29,
nvs 31, nhs 33, duse 35, offset 37, gelev 41, selev 45, sdepth 49, gdel 53, sdel 57, swdep 61, gwdep 65,
scalel 69, scalco 71, sx 73, sy 77, gx 81, gy 85, counit 89, wevel 91, swevel 93, sut 95, gut 97, sstat 99,
gstat 101, tstat 103, laga 105, lagb 107, delrt 109, muts 111, mute 113, ns 115, dt 117, gain 119, igc 121,
igi 123, corr 125, sfs 127, sfe 129, slen 131, styp 133, stas 135, stae 137, tatyp 139, afilf 141, afils 143,
nofilf 145, nofils 147, lcf 149, hcf 151, lcs 153, hcs 155, year 157, day 159, hour 161, minute 163, sec 165,
timbas 167, trwf 169, grnors 171, grnofr 173, grnlof 175, gaps 177, otrav 179, cdpx 181, cdpy 185, iline 189,
xline 193, sp 197, spscal 201, tvmu 203, trdman 205, trdexp 209, trdun 211, dti 213, timscal 215, stypor 217,
sedir 219, smman 225, smexp 229, smun 231.

SEG00001 [p.51-53]: etracl 1 (12 = u64), etracr 9 (12), efldr 17 (9 = i64), ecdp 25 (9), egelev 33 (6 = f64),
gdepth 41 (6), eselev 49 (6), esdepth 57 (6), egdel 65 (6), esdel 73 (6), eswdep 81 (6), egwdep 89 (6),
esx 97 (6), esy 105 (6), egx 113 (6), egy 121 (6), eoffset 129 (6), ens 137 (10 = u32), secfrac 141 (2),
edt 145 (6), cable 153 (2), nthe 157 (11 = u16), lasttr 159 (11), ecdpx 161 (6), ecdpy 169 (6).

> **AMBIGUITY:** [p.45-51] Example uses both "Value format code n" and "Value format n" keywords, and typos
> "Field deswcription", "Field desciption"; "HEADER NAME = …… SEG00000" has dot leaders. Readers: accept
> "Value format" as alias; normalise spaces/case; strip leader dots. "Time value measurement unit" (78) = trace
> value measurement unit.

### 7.3 D-8 Trace Header Layout — `((SEG:Layout:text/xml))` [p.54-64, clar p.7-9]

XML (UTF-8 typical). Also usable as a side-car file for legacy SEG-Y. Byte order is **not** in the XML; it comes
from 3297-3300 (rev 0/1: always big-endian) [p.54].

| Element | Attributes | Meaning |
|---|---|---|
| `segy-layout` | `name` (optional) | Root. |
| `desc` | — | Optional description text. |
| `entry` | `name` (alnum, no blanks), `byte` (1-based within its header), `type` (Table 13), `if-non-zero` (bool, default false) | At top level ⇒ in the standard 240-byte header; inside `extension` ⇒ in that extension. If a name repeats, the **last** definition wins (used so Ext1 entries with `if-non-zero` supersede std ones). |
| `extension` | `name` = 8-char name in bytes 233-240 (e.g. `SEG00001`) | Contains `entry` elements; bytes relative to the extension start. |

Entry types (Table 13) [p.56-57]:

| Type | Enc | Notes |
|---|---|---|
| int2 / int4 / int8 | i16 / i32 / i64 | |
| uint2 / uint4 / uint8 | u16 / u32 / u64 | |
| ibmfp | ibm32 | |
| ieee32 / ieee64 | f32 / f64 | |
| linetrc / reeltrc | u32 | Trace sequence within line / reel; writer regenerates on output. |
| linetrc8 / reeltrc8 | u64 | Same, 8-byte. |
| coor4 | i32 | Coordinate, scaled by entry `co_scal` (normally 71-72). |
| elev4 | i32 | Elevation/depth, scaled by `ed_scal` (normally 69-70). |
| time2 | i16 | Time, scaled by `tm_scal` (normally 215-216). |
| spnum4 | i32 | Shotpoint, scaled by `sp_scal` (normally 201-202). |
| scale6 | i32 + i16 | 6 bytes: mantissa × 10^exponent. |

Fig. 3 standard rev-2 layout names = the `[L:…]` tags in §3.4; Ext1 entries [p.59]: linetrc 1 linetrc8,
reeltrc 9 reeltrc8, ffid 17 int8, cdp 25 int8, relev 33, rdepth 41 (no if-non-zero), selev 49, sdepth 57,
rdatum 65, sdatum 73, wdepthso 81, wdepthrc 89, sht_x 97, sht_y 105, rec_x 113, rec_y 121, offset 129 (all ieee64),
nsamps 137 uint4, nanosecs 141 int4 (no if-non-zero), dt 145 ieee64, cable_num 153 int4, last_trc 159 int2,
cdp_x 161, cdp_y 169 ieee64; every override has `if-non-zero="1"`. Fig. 4 (rev 1) = Fig. 3 without the extension;
Fig. 5 (rev 0) = bytes 1-179 only, with time fields as plain `int2` (no time scalar) [p.60-63].

D-8.1 minimum entries for auto-reading [p.64]:

| Data type | Required entry names |
|---|---|
| Field | ffid, chan, espnum |
| Pre-stack | ffid, chan, espnum, cdp, cdptrc, trctype, co_scal, sht_x, sht_y, rec_x, rec_y, coorunit |
| Post-stack | cdp, cdptrc, offset, co_scal, sht_x, sht_y, rec_x, rec_y, coorunit, inline (189), xline (193) |

> **AMBIGUITY:** [p.64] D-8.1 uses `inline` while Fig. 3 uses `iline`; curly quotes and a missing `=`
> (`<entry name "offset" …>`) in the printed XML. Treat names case-insensitively and accept both iline/inline.

> **AMBIGUITY:** [p.59, p.48] Fig. 3 omits Ext1 157-158 (`nthe`) and types ns/dt as int2 (D-7: u16).

### 7.4 D-9 User Data stanza / User Header / Data Trailer [p.31, p.65-73]

Stanza name: `((SEG:UserData))` [p.65] / `((SEG:User Data ver 1.0))` (examples [p.71-72]) / `((SEG:UserHeader))` [p.31].
Body = sequence of (description block, data block) pairs, no padding between; last data block padded with
binary 0 to fill the last 3200-byte record [p.65].

| Item | Rule |
|---|---|
| Description block | Well-formed XML 1.0, ASCII only, English; single level; tags only (no attributes, comments, `<?…?>`, `<!…>`); tags lower case; values case-insensitive; CR/LF/CRLF and space/tab allowed for readability [p.66]. |
| Data block | Starts at the first byte after `</segydescblock>`; exactly `blocksize` bytes; any format/endianness [p.70]. |
| Resync | On errors search for `<segydescblock>` [p.66]. |

| Tag | Req | Meaning |
|---|---|---|
| `segydescblock` | X | Top-level element. |
| `version` | X | Description-block format version; this spec = 1. |
| `blocksize` | X | Data block size in bytes (decimal; examples up to 27320014096 ⇒ needs u64). |
| `dataformat` | X | `text-…` or `bin-…`, optional `be-`/`le-` (e.g. `text-us-ascii`, `text-xml`, `text-be-utf-8`, `text-ISO-8859-1`, `text-p1/11`, `text-html`, `text-other`, `bin-pdf`, `bin-docx`, `bin-hdf5`, `bin-zip`, `bin-tar`, `bin-jar`, `bin-python`, `bin-iso`, `bin-mpeg4`, `bin-mp3`, `bin-sqlite`, `bin-segd`, `bin-segy`, `bin-le-other`, `text-<myformat>`/`bin-<myformat>`). |
| `datalabel` | X | `[a-zA-Z0-9]+`; unique per creator; labels starting `SEG` reserved. |
| `description` | | Free text. |
| `creationtime` | X | UTC `YYYY-MM-DD hh:mm:ssZ`. |
| `creator` | X | Producing system name. |
| `dataversion` | | Default "1". |
| `compression` | | e.g. zip, bzip2, gzip, compress, snappy; absent or `none` = uncompressed. |

Decoding key = (dataformat, datalabel, dataversion, creator) [p.70].

> **AMBIGUITY:** [p.65-71] Three spellings of the stanza name (UserData / User Data ver 1.0 / UserHeader); with
> space-insensitive matching the first two coincide except for `ver 1.0`. Match on prefix `SEG:USERDATA` or
> `SEG:USERHEADER`. Clarification-style `((SEG:UserData:…:BYTES))` not addressed; see Q6.

## 8. Implementation notes

- Detect byte order before reading any numeric binary-header field; keep the raw marker for round-trip writes.
- Writers: emit big-endian by default with marker `01 02 03 04`, 3501-3502 = `02 01`; fill both the 16-bit and
  extended fields when values fit; set 16-bit fields to 0 (or truncated? — see Q1) when they do not.
- Rev 2.0 vs 2.1: only 3507-3510 layout, survey type, Layout XML and doc renumbering differ (§6.6).
- 3-byte formats (7, 15) and 8-byte formats (6, 9, 12) are new sample widths; bps ∈ {1,2,3,4,8}.
- Ext1 `numAddlTraceHeaders` counts Ext1 itself; total headers per trace = 1 + k.
- f64 header fields are unscaled (no 69-72 scalars).
- Ext1 141-144 nanoseconds may be negative; full time = `second + ns·1e−9`.
- Textual header and each extended stanza may differ in encoding (EBCDIC/ASCII); detect per stanza from the
  first two bytes (`28 28` vs `4D 4D`).
- Binary stanzas (`…:BYTES`) and User Data blocks must be skipped by length, never scanned for `((`.
- Year 157-158 is still i16; 0 = unknown.
- When fixed flag = 1, trace ns/dt fields are "ignored": readers must not trust them over the binary header.
- C39 revision card is not reliable in practice (§9).

## 9. Verification against BO_3D-Inglewood_rev21_v7.sgy

Script: `/tmp/claude-1000/-workspaces-parseSEGD/0f989fde-af2f-44e5-87d5-7f31b9acb82b/scratchpad/walk_segy21.py`
(walks the file with §3.2, §3.3, §3.4, §6.1-6.5 rules). File size 1,982,000 bytes. **Tiling: exact** — every
byte assigned to exactly one block, no gaps or overlaps.

| File offset (0-based) | Bytes | Block | Decoded |
|---|---|---|---|
| 0 | 3200 | Textual header | EBCDIC (byte 0 = 0xC3). C01 `AREA : Taranaki_Basin - INGLEWOOD-3D Migration`. Revision card is **C24** `SEG Y REV 21`; C39 = `DATE : APRIL 2013`; C40 = company line (no `END TEXTUAL HEADER`). |
| 3200 | 400 | Binary header | 3297-3300 = `01 02 03 04` → big-endian. 3205 line 360; 3209 reel 7; 3213 dataTr 227; 3215 auxTr 227; 3217 dt 2000; 3221 ns 2001; 3225 format 1 (IBM); 3227 fold 1; 3255 meas 1 (m); 3261 extDataTr 227; 3265 extAuxTr 227; 3269 extNs 2001; 3273 extDt 2000.0 (f64 `40 9F 40 00 00 00 00 00`); 3293 extFold 1; 3501-3502 = `02 01`; 3503 fixed 1; 3505 nExt −1; 3507 maxAddl 0; 3509 survey 0; 3511 timeBasis 0; 3513 numTraces 0; 3521 firstTraceOffset 0; 3529 trailer 0. 3301-3500 and 3533-3600 all zero. |
| 3600 | 3200 (1 rec) | Ext rec 0 | `((SEG:LAYOUT:text/xml:))` ASCII; XML (812 bytes incl. name) immediately after `))`, LF line ends, SPACE padded (2364). Entries: linetrc 1, reeltrc 5, iline 13, xline 17, cdp 21, trctype 29, fold 31, rectype 35, offset 37, ed_scal 69, co_scal 71, cdp_x 73, cdp_y 77, relev 85, nsamps 115, dt 117. |
| 6800 | 38400 (12) | Ext rec 1-12 | `((OGP:P1/11))` ASCII, P1/11 CSV, CRLF, lines up to 283 chars, SPACE padded (174). |
| 45200 | 70400 (22) | Ext rec 13-34 | `((OGP:P6/11))` ASCII, CRLF, lines up to 2850 chars, SPACE padded. |
| 115600 | 3200 (1) | Ext rec 35 | `((SEG:catalog))` ASCII JSON (geodesy: EPSG 2193 NZTM2000, bin grid), CRLF, SPACE padded. |
| 118800 | 211200 (66) | Ext rec 36-101 | `((TROIKA:IMAGEPNG:image/png:208104))` binary stanza: 36-byte name + 208104 PNG bytes (`89 50 4E 47 0D 0A 1A 0A` … `IEND AE 42 60 82`) + 3060 NUL pad = 66×3200. BYTES excludes name — matches clarification. |
| 330000 | 3200 (1) | Ext rec 102 | `((SEG:EndText))` at byte 1, remaining 3185 bytes SPACE. |
| 333200 | 200 × 8244 | Traces 0-199 | Record = 240 (k = 0) + 2001 × 4. All ns = 2001, dt = 2000. traceSeqLine/File 1..200; 13-16 = 1001 (in-line per layout); 17-20 = 1..200 (xline per layout); 21-24 = 1001001..1001200; trace id 1; scalars 69/71 = 1; 73-76 = 1704047..1709675; 77-80 = 5667444..5669430; 85-88 = 6229184..6231174; 181-192 all 0; 233-240 = 8 binary zeros (allowed). |
| 1982000 | 0 | Trailer | none (3529 = 0). |

Spec-vs-file findings (file wins; recorded):

| # | Finding | Spec |
|---|---|---|
| F1 | Stanza name `((SEG:LAYOUT:text/xml:))` has an empty 4th (BYTES) field. | [clar p.8] shows 3 fields for text. Parser must tolerate empty fields. |
| F2 | Stanza data starts immediately after `))`, no CRLF; EndText record has no CRLF. | Consistent with [clar p.8-9]. |
| F3 | Layout XML uses LF, not CRLF. | [p.17] says CRLF. |
| F4 | OGP stanza names `((OGP:P1/11))`, `((OGP:P6/11))` (no ` CRS`). | [p.37] vs [clar p.12]. |
| F5 | `((SEG:catalog))` without content type. | [clar p.12] lists application/json; type optional for text. |
| F6 | Text header ASCII-vs-EBCDIC differs from stanzas (EBCDIC text header, ASCII stanzas). | Allowed [clar p.9 rule 5]. |
| F7 | Revision text in C24 (`SEG Y REV 21`), not C39; no `END TEXTUAL HEADER`. | [p.8] Table 1. Reader must not depend on it. |
| F8 | nExt = −1 although the count (103) is known; 3521 = 0; 3513 = 0. | Permitted [p.13-14]. |
| F9 | Standard fields re-purposed (inline at 13, xline at 17, CDP X/Y at 73/77) and documented only via Layout stanza. Layout `relev` byte 85 contradicts text card C35 (`CDP ELEVATION :BYTES 81-84`); 81-84 are zero, 85-88 hold 6.23e6. | File-internal inconsistency; Layout should drive decoding [clar p.9 rule 8]. |
| F10 | 3215-3216 aux traces = 227 (= data traces) for a poststack file. | Probably writer error; no spec impact. |

## 10. Open questions

| # | Question | Suggested default |
|---|---|---|
| Q1 | Exact signedness of binary 3213-3228 and whether writers should zero or saturate 16-bit fields when the extended field is used. | Read 3217-3224 as u16, others i16; writer: write 16-bit value if it fits, else 0, plus extended field. |
| Q2 | Pairwise byte swap for 1-/3-byte fields and samples, and for 3501-3502. | 1-byte untouched; formats 7/8/15/16 with PAIR → error; accept `01 02` at 3501-3502 under PAIR as rev 2.1. |
| Q3 | Marker not one of the three patterns (corrupt / vendor). | Heuristic: try BE then LE on format code ∈ valid set and ns > 0; warn. |
| Q4 | Byte order of numeric fields inside proprietary extensions. | Same as file (marker), since all trace headers are covered [p.6]. |
| Q5 | Survey type "684 = patches". | Treat as 384; accept 684 as alias on read; write 384. |
| Q6 | User Data stanzas vs clarification BYTES field / binary padding; trailer EndText. | Parse both; skip by `blocksize`; don't require EndText in trailer. |
| Q7 | T = −1 and numTraces = 0 without Ext1: where do traces end? | Treat trailing bytes as trailer only if count is a multiple of 3200 and the first block starts with `((`; else traces to EOF. |
| Q8 | Ext1 145-152 unit when data are frequency/depth. | Same unit as the 16-bit field it overrides. |
| Q9 | Trace id interpolated flag combined with −1/0. | Flag only for v ≥ 16384. |
| Q10 | Copied 128-byte tape label in disk files: does 3521 include it? | Yes ("relative to start of file or stream", +128 rule [p.13]). |
| Q11 | Rev 2.1 files from pre-clarification writers with N > 0 and no EndText. | Trust N; warn. |
| Q12 | Format 4 sign convention / gain sign. | i16 mantissa × 2^−G; read-only. |
