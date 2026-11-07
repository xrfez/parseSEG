# SEG-Y Rev 2.0 (January 2017): delta against Rev 2.1

Source: `SEG Spec/text/SEG-Yrev2Release.txt`. `[p.N]` = `=== PAGE N ===` marker of the **2.0** text (152 pages).
`[2.1 p.N]` cites `seg_y_rev2_1-oct2023.txt`, and `[clar p.N]` cites `seg-y_rev2-1_clarification_2025-05-01.txt`.
Base note: `segy_rev2_1.md` ("2.1 note"). This note tells a reader how to treat a file whose bytes 3501-3502 are `02 00`.
Anything not listed here is the same in 2.0 and 2.1.

Method: the two-column layout defeats a plain diff. So the binary header (Table 2), the trace header (Table 3), Extension 1
(Table 4), Table 5, the tape label (Table 6), App. D-10/D-7 (Trace Header Mapping), D-11/D-9 (User Data) and App. E were
cut out of both texts and line-diffed with `difflib`. The prose sections (§1-§8 and the App. D intros) were compared as word
5-grams, and every remaining difference was read. Typos, hyphenation, page references and acknowledgments are ignored.

## 1. Scope

| 2.0 pages | Content | Result |
|---|---|---|
| 1-8 | Front matter, §1-§3 | §2.2 "Changes from rev 2 to rev 2.1" exists only in 2.1 [2.1 p.4]. §3 is identical in substance. |
| 9 | Table 1 Textual File Header | C39 reads `SEG-Y_REV2.0` (2.1: `SEG-Y_REV2.1`) |
| 10-15 | Table 2 Binary File Header | **3507-3510 differ**; cross-reference and wording fixes (§3) |
| 15-18 | §6 Extended Textual File Header, §6.2 EndText | identical rules |
| 19-28 | Table 3 Standard Trace Header | identical (trace ids 0-41 including rotational 39-41, units, etc.) |
| 28-31 | Table 4 Extension 1, Table 5 Proprietary extension, §7.2, §8 | identical |
| 32-36 | App. A-C | identical except tape label field 2 = `SY2.0` [p.34] |
| 37-117 | App. D-1…D-5 location data | 2.0 has the full P1/11 (D-1) and P6/11 (D-2) descriptions and the **deprecated D-3/D-4/D-5** stanzas, which 2.1 removes from the document |
| 118-131 | D-6…D-10 | = 2.1 D-3…D-7. D-10 Trace Header Mapping is **not deprecated** in 2.0 |
| — | 2.1 D-8 Trace Header Layout (XML) | **does not exist in 2.0** |
| 132-140 | D-11 User Data | = 2.1 D-9 (2.1 adds LF-only line breaks in the XML description block) |
| 141-146 | App. E data word formats | identical code set (1-12, 15, 16) and layouts |
| 147-152 | App. F, G | not compared (code tables identical to rev 1) |

## 2. File / tape structure
Same as 2.1 (2.1 note §2): optional 128-byte label, 3200 text, 400 binary, N × 3200 extended records, traces with
0-65535 additional 240-byte headers, and M × 3200 trailer records. The byte-order marker, pair swapping, the 3200-byte stanza
boundaries and CRLF lines all already exist in 2.0 [p.13, p.16-17].

## 3. Header tables (only the differing rows)

### 3.1 Binary File Header, bytes 3501-3532 [p.14-15] (2.0 layout)

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values (2.0) |
|---|---|---|---|---|---|
| 3501 | | 1b | u8 | `segyMajor` | 0x02. |
| 3502 | | 1b | u8 | `segyMinor` | **0x00** ("radix point between the first and second bytes"). |
| 3503-3504 | | 2b | i16 | `fixedLengthTraces` | As 2.1. See the AMBIGUITY below about its cross-references. |
| 3505-3506 | | 2b | i16 | `numExtTextHeaders` | As 2.1 (0, >0, −1; overridden by a non-zero 3521-3528). |
| **3507-3510** | | **4b** | **u32** | `maxAddlTraceHeaders` | **Maximum number of additional 240-byte trace headers; 0 = none.** The per-trace actual count is in Ext1 157-158 [p.14]. 2.1 splits these bytes into u16 3507-3508 (same meaning) and u16 3509-3510 `surveyType` [2.1 p.13-14]. **There is no survey type in 2.0.** |
| 3511-3512 | | 2b | i16 | `timeBasisCode` | As 2.1 (1 local, 2 GMT, 3 other, 4 UTC, 5 GPS) [p.15]. |
| 3513-3520 | | 8b | u64 | `numTraces` | "If zero, all bytes in the file or stream are part of this SEG-Y dataset" [p.15]. 2.1 adds: "monitor the end-of-data flag in … Extension 1, bytes 159-160, if present" [2.1 p.14]. That flag (value 4 = last trace in file) is defined in 2.0's Ext1 too [p.30], so applying the 2.1 rule to 2.0 is safe. |
| 3521-3528 | | 8b | u64 | `firstTraceOffset` | As 2.1. |
| 3529-3532 | | 4b | i32 | `numTrailerRecords` | As 2.1. |
| 3533-3600 | | 68b | — | `unassigned2` | Unassigned. |

Bytes 3201-3500 are identical in layout and meaning. 2.1 adds one sentence at 3297-3300: "If this value is zero, pre-rev 2
big-endian byte ordering should be assumed" [2.1 p.12]. 2.0 says nothing about a zero marker [p.13]. Use the 2.1 rule.

> **AMBIGUITY [p.14]:** the 2.0 fixed-length flag text says traces share "the same sample interval, number of trace header
> blocks and trace samples, as specified in … 3217–3218 or **3281–3288, 3517–3518**, and 3221–3222 or **3289–3292**". These
> are erratum cross-references: 3281-3288 and 3289-3292 are the *original-recording* fields, and 3517-3518 lies inside the 8-byte trace count.
> 2.1 corrects them to 3273-3280, 3507-3508, 3269-3272 [2.1 p.13]. **Read 2.0 files with the 2.1 meaning** (extended
> interval 3273, extended sample count 3269, and the trace-header-block count, which is 3507-3510 in 2.0).

> **AMBIGUITY [p.14]:** 2.0 gives no signedness for 3507-3510. u32 is assumed (it is a count, and Ext1 157-158 is a "2 byte unsigned"
> per-trace count [p.30]). Values above 65535 are legal in 2.0 but not representable in 2.1. Any
> value above 65535 is implausible in practice, because Ext1 157-158 can only count to 65535.

Endianness: 3507-3510 is **one** 4-byte field in the file's byte order (3297-3300). In big-endian, a 2.0 file with 1 extra
header holds `00 00 00 01`, which a 2.1 decoder reads as maxAddl = 0, surveyType = 1. In little-endian it holds `01 00 00 00`, which a 2.1 decoder
reads as maxAddl = 1, surveyType = 0. Big-endian 2.0 files therefore lose all their extension headers under 2.1 rules.

### 3.2 Trace headers [p.19-31]: no change
Table 3, Table 4 (Extension 1) and Table 5 match 2.1 field for field (including trace id codes 39-41 for rotational
pitch/roll/yaw, Ext1 157-158 / 159-160, and the `SEG00000`/`SEG00001` names). Ext1 157-158 refers to "Binary File Header bytes
3507–3510" in **both** documents. That is correct for 2.0 and stale for 2.1.

### 3.3 Textual File Header and tape label
- Table 1, line C39: `SEG-Y_REV2.0` [p.9] (2.1: `SEG-Y_REV2.1`). Informational only; the binary bytes 3501-3502 are authoritative.
- Tape label field 2: `SY2.0` [p.34] (2.1: `SY2.1`). The other label fields are identical.

## 4. Code tables
- Data sample format codes (3225-3226) [p.11, p.141-146]: **identical** to 2.1: 1-12, 15, 16, with the same App. E layouts.
- Trace identification, sorting, time basis, units, source type/orientation, measurement units: identical.
- Survey type (2.1 3509-3510, 2.1 note §4.3): **absent** in 2.0. Report it as 0 / unknown.

## 5. Data sample formats
Identical to 2.1 (2.1 note §5). 2.1 App. E only adds the note that its layouts are written big-endian and that 3297-3300
governs byte order [2.1 p.74]. That rule is already in 2.0 §3.3 and Table 2.

## 6. Extended Textual Header and stanzas

### 6.1 Structural rules: identical
These rules are identical in 2.0 [p.15-17]: stanzas begin on 3200-byte boundaries, lines end in CRLF and need not be 80 columns, `#` comments,
`&` continuations, case- and space-insensitive stanza names, "keyword = value", the EndText stanza as the final record with the EndText
rule below, the count of −1 meaning EndText-terminated, and the >32767-record rule.

EndText rule (2.0 §6.2 [p.17] = 2.1 §6.2 [2.1 p.17]): **required only when 3505-3506 = −1**. When the count is > 0,
EndText is optional, but if present it must be counted. The rule that EndText is **always** the last record whenever the count is ≠ 0 comes from
the **2.1 clarification** [clar p.9 rule 7], which covers "SEG-Y rev 2.1" only [clar p.1]. Do not apply it to 2.0 files.

The 2025 clarification (Layout XML recommended [clar p.9 rules 1-2], `((COMPANY:NAME:CONTENTTYPE:BYTES))` stanza names with
binary content and NUL padding [clar p.8], mixed EBCDIC/ASCII documents [rule 5]) is 2.1-only. A 2.0 file has no binary stanzas
except the User Data stanza (D-11), whose data blocks are binary-capable in 2.0 too [p.132-140].

### 6.2 Stanzas that a 2.0 file may contain (and a 2.1 reader may not know)

| Stanza header | 2.0 appendix | Status in 2.0 | Status in 2.1 |
|---|---|---|---|
| `((OGP:P1/11 CRS))` | D-1 [p.37-68] | preferred | D-1 (summary only) |
| `((OGP:P1/11 Data Geographic Extent))` | D-1.12 [p.66] | preferred | mentioned in D-1 |
| `((OGP:P6/11 Coverage Perimeter))`, `((OGP:P6/11 Bin Node Coordinates))` | D-2 [p.69-79] | preferred | D-2 (summary only) |
| `((SEG: Location Data ver 3.0))`, `((SEG: Location Data EPSG Reference ver 3.0))` | D-3 [p.80-107] | **deprecated, still allowed** | removed from the document; "still allowed by the format" [2.1 p.4] |
| `((SEG: Location Data Coordinate Transformation ver 3.0))`, `… Transformation EPSG Reference ver 3.0` | D-3 | deprecated | removed (allowed) |
| `((SEG: Bin Grid Definition ver 1.0))` | D-4 [p.108-111] | deprecated | removed (allowed) |
| `((SEG: Data Geographic Extent ver 1.0))`, `((SEG: Coverage Perimeter ver 1.0))` | D-5 [p.112-117] | deprecated | removed (allowed) |
| `((SEG: Data Sample Measurement Unit ver 1.0))`, `Processing History`, `Source Type/Orientation`, `Source Measurement Unit` | D-6…D-9 [p.118-120] | current | D-3…D-6 (unchanged) |
| `((SEG: Trace Header Mapping ver 1.0))` | D-10 [p.121-131] | **current: the only trace-layout override mechanism** | D-7, **deprecated**, replaced by D-8 |
| `((SEG:Layout:text/xml))` | — | **does not exist** | D-8, recommended by the clarification |
| `((SEG:User Data ver 1.0))`, `((SEG:UserHeader))`, `((SEG:UserData))` | D-11 [p.132-140] | current | D-9 (unchanged) |
| `((SEG: EndText))` | §6.2 | as above | as above, plus clarification rule 7 |

Trace Header Mapping D-10 vs D-7: the keyword set (`Header name`, `Delete field name`, `Field name n`, `Byte position n`,
`Value format code n`, `Number of values n`, `Field description n`) and the predefined SEG00000/SEG00001 mappings are identical.
2.1 only adds "the enumeration 1 … N is optional" [2.1 p.43]. Its parsing rules are in the 2.1 note §7.2.

> **AMBIGUITY [p.38, p.39, p.69]:** 2.0 shows `((SEG:EndText))` as the last line of the P1/11 and P6/11 text examples
> ("The ((SEG: EndText)) may be omitted, but is included for compatibility reasons") [p.39]. This text was copied from SEG-D 3.1 App. D1,
> where EndText closes the CRS string inside 0x55 blocks. In SEG-Y every stanza, EndText included, must start a 3200-byte record [p.16-17],
> so a well-formed 2.0 file puts it in its own final record. A 2.0 writer that followed the example literally leaves an
> **in-record** `((SEG:EndText))` line right after the CRS text. 2.1 deletes the line from both examples [2.1 p.38-39]. Readers should
> treat an in-record `((SEG:EndText))` line as the end of the P1/11 data. It must not count as the EndText record.

## 7. Derived rules / reading a `02 00` file

1. Detect the byte order exactly as for 2.1 (2.1 note §6.1). If the marker is zero, assume big-endian (the 2.1 rule).
2. Decode 3507-3510 as **u32** `maxAddlTraceHeaders`, and set `surveyType = 0` (unknown).
3. Fixed-length flag: use the 2.1 cross-references (§3.1 AMBIGUITY).
4. Extended header: use the 2.1 walking rules (2.1 note §6.3). Raise **no** missing-EndText diagnostic when the count is > 0. EndText is
   required only for a count of −1.
5. Trace layout: the standard Rev 2 layout (Fig. 3 of 2.1 = the D-10.1 mappings of 2.0) plus any **Trace Header Mapping** stanza.
   A Layout stanza in a 2.0 file is non-standard. Accept it leniently, and let it win if both are present (2.1 precedence).
6. Coordinates: the CRS may come from deprecated `Location Data` stanzas (parse as `segy_rev1.md` §7 / SEG-D 3.0-B §6.7), not only
   from P1/11.
7. `numTraces = 0`: stop at the Ext1 159-160 "last trace in file" flag if Ext1 is present (also valid in 2.0); otherwise read to EOF
   minus the trailer.

Writing 2.0: emit u32 at 3507-3510, drop the survey type (warn if it is non-zero), translate or drop a Layout stanza (warn), and
write `SY2.0` / `SEG-Y_REV2.0` if those fields are regenerated.

Revision-byte variants seen for Rev 1 (`00 01` = u16 0x0100 written LE) have a 2.0 analogue. `00 02` is Rev 2.0 written as a
little-endian u16 0x0200, or 3501-3502 pair-swapped. It is not a defined revision, so read it as 2.0, just as `01 02` is read as 2.1.

## 8. Implementation notes
- The 3507-3510 split is the **only** byte-level difference between 2.0 and 2.1. Everything else is documentation (deprecations,
  appendix removal and renumbering, the XML Layout stanza, erratum fixes) or the 2025 clarification.
- 2.0 is the revision that introduced rotational sensor trace ids 39-41, EM/gravity ids, formats 6/7/9-12/15/16, byte-order
  marker, Ext1, proprietary extensions, the trailer and the User Data stanza. These are **not** 2.1 additions.

## 9. Open questions
1. Should 3507-3510 values > 65535 in a 2.0 file be treated as implausible (warn) or honoured? Recommendation: honour them for reading. Ext1 157-158 governs each trace.
2. Should Trace Header Mapping (D-10) be implemented for 2.0 (and 1.0 user headers), or should such stanzas only be indexed?

## 10. Implementation gap analysis (code as of commit 14fbb9d)

Ranked by impact on reading real 2.0 files. 3507-3510 is already handled: `binheader.nim:10-12, 69-72, 100, 123-127, 136-141, 219`,
`writer.nim:80, 113`.

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `src/parseSEG/segy/binheader.nim:102-116` (`rulesRevision`), `:100` (`isRev20`) | `00 02` (2.0 written as an LE u16, or pair-swapped) falls into the `else` branch and is read with **Rev 0 rules**: the byte-order marker, extended counts, Ext1, trailer and all 3261-3600 fields are ignored. `01 02` (2.1 pair-swapped) is handled; the 2.0 analogue is not. `isRev20` also tests the raw bytes, so even after a `rulesRevision` fix, 3507-3510 would decode as 2.1 (u16 + survey type). | Map `00 02` to 2.0 in `rulesRevision`, and base `isRev20` on `rulesRevision` (decode and encode, `:123`, `:136`, `:219`). Also `writer.nim:113`. |
| 2 | `src/parseSEG/segy/reader.nim:311-314` | Warns "the last extended textual record is not ((SEG:EndText)) (required since the Rev 2.1 clarification)" for **every** `rev.major >= 2` file with a count > 0, including 2.0, where EndText is optional (§6.1). | Condition on `rev >= 2.1` (or downgrade to info for 2.0). |
| 3 | `src/parseSEG/segy/writer.nim:139-141` | The same rule as a writer **problem** for 2.0 output ("Rev 2 extended textual headers must end with ((SEG:EndText))"). It is relaxed only when the bytes are unchanged (`asRead`), so a 2.0 file built or edited in memory is rejected by a strict writer. | Apply only for `rev >= 2.1`. |
| 4 | `src/parseSEG/segy/reader.nim:297-309`, `layout.nim:176-185` | Only the 2.1 `SEG:Layout` stanza is applied. The 2.0 trace-layout mechanism, `((SEG: Trace Header Mapping ver 1.0))`, is not parsed anywhere (no match in `src/`), so 2.0 (and 1.0) files that remap or describe proprietary headers through it are read with the standard layout, and their proprietary headers stay opaque. | Parse Trace Header Mapping into a `TraceLayout` (2.1 note §7.2) and merge it before Layout. |
| 5 | `src/parseSEG/convert.nim:206-208` (with `binheader.nim:136-137`) | Converting 2.1 to 2.0 sets the revision bytes, and `encode` then writes the u32 count over 3509-3510. A non-zero `surveyType` is **silently** lost. A `SEG:Layout` stanza is copied into a 2.0 file that cannot define it. | Note the survey-type loss. Warn about, or translate, the Layout stanza into Trace Header Mapping. |
| 6 | `src/parseSEG/segy/exttext.nim` (stanza scan for `rev1Lines = false`) | An in-record `((SEG:EndText))` line after P1/11/P6/11 text (the 2.0 example form, §6.2 AMBIGUITY) is kept as stanza data. The file is then reported as missing EndText (made worse by #2). | Tolerate it: end the OGP stanza's text there, and skip the warning for 2.0. |
| 7 | `src/parseSEG/segy/binheader.nim:72` docs, `reader.nim` API | `surveyType` reads 0 for 2.0, which is indistinguishable from "unknown" in 2.1. | Document it, or expose `Option`. |

Already correct for 2.0: the u32 at 3507-3510 in decode, encode and validate; the format codes per revision (`bytesPerSample`, rev ≥ 2); the
byte-order marker; Ext1 and its end-of-data flag; `rev1Lines = rev.major < 2` (2.0 already requires stanzas at record starts); and
`convert.nim:92-95`, which accepts 2.0 as a target.
