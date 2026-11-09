# SEG-D Rev 3.1 (October 2015): delta on Rev 3.0

Source: `SEG Spec/text/seg_d_rev3_1-oct2015.txt`. `[p.N]` = `=== PAGE N ===` marker of the **3.1** text.
`[3.0 p.N]` cites `seg_d_rev3_0-sep2014.txt`. Base notes: `segd_rev3_0_a.md` ("3.0-A") and `segd_rev3_0_b.md`
("3.0-B"). Anything not listed here is byte-identical to Rev 3.0.

Method: both texts were normalised (page markers, running footers and TOC dot-leader lines dropped, whitespace
collapsed, the strings "Rev 3.0"/"Rev 3.1" folded together) and line-diffed with `difflib`. That left 110 changed
regions, and each one was read. Most are pagination (3.1 is 4 pages longer before Appendix D and 30 pages longer
overall), typo fixes ("compliment" to "complement", "offten", "auxillary", "by who"), wording, and committee
membership. Only the items below change bytes, codes or semantics.

## 1. Scope

| 3.1 pages | Content | Covered |
|---|---|---|
| 1-6 | Title, TOC, committee | skipped (front matter; TOC used for the new appendix structure) |
| 7 | **§2.0 Changes introduced in Revision 3.1** (new section; old §2.0-2.3 renumbered to §2.1-2.4) | yes |
| 8-30 | Change history, overview, timestamp, multi-component, ERM, permanent systems | diffed: only the leap-second table (p.28) and the CRS-type table (p.30-31) change |
| 30-31 | §3.6 Positions in SEG-D: CRS types, CRS referencing | yes |
| 33-40 | Storage Unit Label, TOC | yes (revision strings, a TOC text fix) |
| 41-51 | Header-block overview, trailer types | yes (Position-data-backup renames, P6/11 example p.50) |
| 52-58 | §6.1 data recording methods | yes (**new little-endian layouts**) |
| 62-131 | §7 header tables, §8 parameters | yes: GH1 format list (p.91), GH2 byte 12 (p.94), CRS block text (p.111), Position block (p.77-78, p.112-113), trailer type names (p.131) |
| 132-142 | App. A manufacturers, B glossary, C API codes | yes (two new manufacturers, p.136) |
| 143-168 | **App. D1 (new): OGP P1/11 CRS definition** | summarised (§4.6, §6.3); the record field lists are IOGP's and are cited, not copied |
| 169-190 | App. D2 = old App. D (stanzas), now **deprecated** | diffed: renumbering plus a dropped "continuation over 3200 bytes" sentence (§7) |
| 191-217 | App. E examples, F units | yes (leap-second code tables p.200-203; Energistics table only reordered) |

## 2. File / tape structure

Unchanged: the record layout, block typing (byte 32), sizes, device structures, and the label/TOC layouts are the same as 3.0-A §2.
The text changes are:
- Storage Unit Label field 2 is `SD3.1` [p.34]; TOC header field 2 is `SD3.1` and must equal the label [p.37].
- The TOC text now says "one **128** byte entry for each SEG-D record" [p.35]. 3.0 [p.33] said "64 byte", but its own
  entry table [3.0 p.36] runs to byte 128, so this is an erratum fix. The code already uses 128 (`TocEntrySize`).
- All headers stay big-endian. **Only trace samples** may be little-endian, and only when the record's format code is 90xx
  [p.7 item 1: "all the rest of SEG-D (headers etc.) remains big endian format"].

## 3. Header tables (changed blocks only)

### 3.1 General Header Block #1, bytes 3-4: format code [p.91]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 3-4 | 3H-4L | 4n | bcd | `formatCode` | 8015, 8022, 8024, 8036, 8038, 8042, 8044, 8048, 8058, 8080 (as 3.0). **New: 9036, 9038, 9058, 9080** (little-endian samples, §5). 0000 and 0200 are illegal. "80xx are big endian sample formats, 90xx are little endian." |

The code is still BCD, so `9036` is stored as bytes `90 36`. No other GH1 byte changes.

### 3.2 General Header Block #2, byte 12: minor revision [p.94]

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|
| 11 | | 1b | u8 | `revisionMajor` | 0x03 (unchanged). |
| 12 | | 1b | u8 | `revisionMinor` | **0x01 for Rev 3.1** (was 0x00 in 3.0). |

> **AMBIGUITY [p.94]:** the text reads "Set to 0116" (the hex subscript is glued to the digits) = 0x01.

### 3.3 Coordinate Reference System Identification block (ID 0x55) [p.111, p.76]

The layout is unchanged: bytes 1-31 hold text and byte 32 = 0x55 (3.0-B §3.8). Two things change. The text may now be **either** an OGP P1/11 CRS
definition (App. D1, recommended) **or** the old stanza text (App. D2, deprecated). For P1/11, each record is
terminated by CR (0x0D) and/or LF (0x0A). "Both CRS formats … use the same Header Type 55₁₆" [p.143, p.169].

> **AMBIGUITY [p.111 vs p.143]:** §8.12 says the string is split into **31**-byte blocks and padded with spaces. D1.1 says it is "broken up
> into multiple **32** byte blocks … the last block is padded with space". Byte 32 of every block is the type ID 0x55, so the text
> capacity is 31 bytes per block. Read and write 31 (as 3.0). The "32" refers to the block size.

### 3.4 Position Block (IDs 0x50/0x51/0x52), 96 bytes [p.77-78 table, p.112-114 detail]

Byte layout unchanged (3.0-B §3.9). The changes are in field meaning and names:

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values (3.1) |
|---|---|---|---|---|---|
| 29-30 | | 2b | u16 | `horizErrorOrientation` | Orientation of the error ellipse, 1/100 degree, **relative to the CRS north axis (the HC,1,6,1 record of the P1/11 definition)**. 3.0 said "map grid north". 0 = vertical-only CRS; 0xFFFF = n/a. |
| 33-40, 41-48, 49-56 | | 8b each | f64 | `tuple1Coord1..3` | "Coordinate tuple 1 / **CRS A**". Units and axis order come from the CRS named by `crsRef1` (P1/11 CRSREF) or, for the deprecated D2 format, by the Location Data stanza with that ID. +Inf = not used (as 3.0). |
| 57-58 | | 2b | u16 | `crsRef1` (3.0: `stanzaId1`) | **CRSREF** (P1/11 CRS Number, field 6 of the HC,1,3,0/HC,1,4,0 records) **or** Location Data Stanza ID. 0 = unknown. 3.1 drops the "range 0 to 65535" sentence; the encoding is unchanged. |
| 65-72, 73-80, 81-88 | | 8b each | f64 | `tuple2Coord1..3` | "Coordinate tuple 2 / **CRS B**" (as tuple 1). |
| 89-90 | | 2b | u16 | `crsRef2` (3.0: `stanzaId2`) | As 57-58, for tuple 2. |

No other header block (GH3, GH4-8, source blocks, CSD, demux trace header, extensions 0x40-0x45, 0x60, 0x61, 0x70) changes at
all. The diff found no changed line in any §7 or §8 table except those above.

## 4. Code tables

### 4.1 Sample format codes [p.7, p.91]

| Code | Format | Bytes/sample | New in |
|---|---|---|---|
| 8015 … 8058, 8080 | as 3.0-A §4.1 (big-endian) | | ≤3.0 |
| **9036** | 24-bit two's complement, little-endian | 3 | 3.1 |
| **9038** | 32-bit two's complement, little-endian | 4 | 3.1 |
| **9058** | IEEE 754 single, little-endian | 4 | 3.1 |
| **9080** | IEEE 754 double, little-endian | 8 | 3.1 |

No 9015/9022/9024/9042/9044/9048 codes exist. They are deliberately excluded: "other formats does not match internal data types" [p.7].
The "one number system per record" rule [p.52] still holds, so a record has one format code for all its channels, aux channels included.

### 4.2 Sensor types (THE#1 byte 21, `sensorType`) [p.121-122]: **unchanged**
The 3.1 table is identical to 3.0: 0x00 not defined, 0x01 hydrophone, 0x02-0x05 geophone V/H-inline/H-crossline/H-other,
0x06-0x09 accelerometer (same four), 0x15 electric dipole, 0x16 magnetic coil, and "other values are not defined at the present
time". **3.1 adds no rotational sensor type.** It still has only the Orientation Header (0x60) rotation matrix [p.29, p.87]. The
first SEG standard with rotational sensors is SEG-Y 2.0, which added trace-id codes 39-41 (pitch/roll/yaw); see `segy_rev2_0_delta.md`.

### 4.3 Channel types, block-type IDs, units, sensor-calibration codes: **unchanged**
The diff found no changes to channel types (CSD byte 4), the header block type table [p.41-42], physical units, or App. F. App. F has the same
entries in a different page order (area 1018, heat flow rate 1064, per area 1110 and time per length 1156 only move pages).
The 3.0 Additional Source Info ID typo (Table 2 = 0x20, §7.10 bits = 0x1A; 3.0-A §3.1 AMBIGUITY) is **not** fixed in 3.1.

### 4.4 General Trailer block types [p.49, p.131]: codes unchanged, labels renamed

| Type | 3.0 label | 3.1 label |
|---|---|---|
| 0x02 | Navigation data backup | **Position data backup** |
| 0x20 | P1 processed navigation data | P1 Processed position data |
| 0x21 | P2 Raw marine positioning data | P2 Raw positioning data |
| 0x24 | P6 3D seismic binning grids | P6 3D seismic bin grid data |

The "P3 File Format" identifier string capitalisation also changes in the extraction (`“P3 FILE Format ”`) [p.49].
> **AMBIGUITY [p.49]:** 3.0 shows `"P3 File Format "` and 3.1 shows `"P3 FILE Format "`. The other entries are all uppercase (`"P1 FILE FORMAT "`).
> Compare the identifier case-insensitively.

New example [p.50]: a P6/11 bin-grid CRS (an engineering CRS plus an affine transform, EPSG method 9666) carried in a 0x24 trailer
block, with its P1/11 CRS text in the general header.

### 4.5 Manufacturers (App. A) [p.136]

| Code | Name | Year |
|---|---|---|
| 58 | OCTIO (Bergen, Norway) | 2014 |
| 59 | inApril AS (Oslo, Norway) | 2015 |

### 4.6 CRS types for coordinate tuples (§3.6) [p.30-31, p.152]

This table replaces 3.0-A §4.4. 3.1 adds the engineering types and changes the compound row to a reference.

| CRS type | Coord 1 | Coord 2 | Coord 3 |
|---|---|---|---|
| Projected | easting or northing (CRS axis order) | northing or easting | +Inf (not used) |
| Geographic 2D | latitude | longitude | +Inf |
| Geographic 3D | latitude | longitude | ellipsoidal height |
| Geocentric | X | Y | Z |
| Vertical | +Inf | +Inf | gravity-related height or depth (the sign convention comes from the CRS) |
| **Engineering 1D** | distance along X | +Inf | +Inf |
| **Engineering 2D** | X | Y | +Inf (seismic bin grids: engineering 2D plus an affine transform) |
| **Engineering 3D** | X | Y | Z |
| Compound | per the horizontal CRS | per the horizontal CRS | per the vertical CRS |

The engineering 1D/2D/3D types share CRSTYPEREF 6; the dimension comes from HC,1,6,0 field 11 [p.31 note 4].

CRSTYPEREF (Table 10) [p.153]: 1 projected, 2 geographic 2D, 3 geographic 3D, 4 geocentric, 5 vertical, 6 engineering,
7 compound. CSTYPEREF (Table 11) [p.159-160]: 1 affine, 2 Cartesian, 3 ellipsoidal, 4 polar, 5 vertical.

### 4.7 Leap seconds [p.28, p.202-203]
The table adds the leap second of 2015-06-30 (GPS-UTC = 17 s from 2015-07-01). The example C code adds `{12960, 17}` and
`TSDECL(1119744017000000)`, plus Jan-1 timestamps for 2013-2015. The leap second of 2016-12-31 is not in the spec, since 3.1 predates it.

## 5. Data sample formats: little-endian layouts [p.55-58]

Each 90xx format is its 80xx counterpart with the byte order of each sample **fully reversed** (not pair-swapped).
The bit tables number bits 0 (MSB) … 7 within each byte, as for 80xx.

| Code | Byte 1 | Byte 2 | Byte 3 | Byte 4 | Bytes 5-8 | Decode |
|---|---|---|---|---|---|---|
| 9036 | I7…I0 | I15…I8 | I23…I16 | | | `v = sext24(b1 \| b2<<8 \| b3<<16)` |
| 9038 | I7…I0 | I15…I8 | I23…I16 | I31…I24 | | `v = i32 LE` |
| 9058 | Q−16…Q−23 | Q−8…Q−15 | C0 Q−1…Q−7 | S C7…C1 | | `v = f32 LE` |
| 9080 | Q−45…Q−52 | Q−37…Q−44 | Q−29…Q−36 | Q−21…Q−28 | B5 Q−13…Q−20; B6 Q−5…Q−12; B7 C4…C1 Q−1…Q−4; B8 S C11…C5 | `v = f64 LE` |

The value semantics (two's complement, IEEE NaN/Inf/denormal rules, Input signal = v × DSM mV, DSM in CSD bytes 17-20) are
identical to 8036/8038/8058/8080 (3.0-A §5.7-5.10). There is no padding and no grouping. Traces are still demultiplexed.

> **AMBIGUITY [p.56-57]:** the 9080 byte-4 row prints `Q27` without its minus sign. It is Q−27 (the same typo is in the 8080 table).

## 6. Derived rules / algorithms

### 6.1 Version detection (supersedes 3.0-A §6.9 for 3.1)

| Where | 3.0 | 3.1 |
|---|---|---|
| SUL bytes 5-9 [p.34] | `SD3.0` | `SD3.1` |
| TOC header field 2 [p.37] | `SD3.0` | `SD3.1` |
| GH2 bytes 11-12 [p.94] | `03 00` | `03 01` |

Header parsing is **identical** for 3.0 and 3.1. A reader therefore uses the 3.0 header walk for any `03 0x`. It must accept 90xx format codes
when the minor version is ≥ 1, and it should tolerate them (with a warning) in a record labelled 3.0.

### 6.2 Sample byte order
`littleEndianSamples = formatCode div 100 == 90` (BCD-decoded code 9036/9038/9058/9080). Trace length:
`bytesPerSample(90xx) = bytesPerSample(80xx)`. This applies to the trace data only. Trace headers, extensions,
trailer blocks and the 0x55 text are unaffected.

### 6.3 CRS text format detection (0x55 blocks) [p.143-144]
Concatenate bytes 1-31 of the consecutive 0x55 blocks (as 3.0). Then:
- Text starting with `((OGP:P1/11 CRS))` is the **P1/11** format (App. D1). The match is case- and whitespace-insensitive: `((ogp:p1/11crs))` is
  valid. The next line should be the OGP File Identification record (`OGP,<contents>,<format list>,1.1,…`) [p.147]. Then come the `HC,…` header
  records and `CC,1,0,0` comments. A line starting with `C` is a comment. An optional `((SEG:EndText))` ends the definition
  ("included for compatibility … to support same text as SEG-Y"). Strip both markers and pass the rest to a P1/11
  parser. `#` comments and `&` continuations are **not** allowed in P1/11.
- Text starting with `((SEG: Location Data …))`, `((SEG: Location Data EPSG Reference …))` or a similar stanza is the deprecated **D2** format.
  Parse it as 3.0-B §6.7.
- Position-block bytes 57-58 / 89-90 then index CRS Number (field 6 of HC,1,3,0 / HC,1,4,0) for P1/11, or the
  Location Data Stanza ID for D2.

P1/11 records used for the SEG-D CRS [p.148-166]: HC,1,0,0 summary; HC,1,1,0 units (UNITREF 1 metre, 2 radian,
3 degree, 4 unity reserved); HC,1,3,0 implicit CRS id (EPSG code) **mandatory for every CRS**; HC,1,4,0 explicit CRS
**mandatory**; HC,1,4,1/4,2 compound horizontal/vertical; HC,1,4,3 base geographic CRS; HC,1,4,4 datum; HC,1,4,5 prime
meridian; HC,1,4,6 ellipsoid; HC,1,4,7 vertical datum; HC,1,4,8 engineering datum; HC,1,5,0-5,2 projection; HC,1,6,0 CS
(field 11 = dimension); HC,1,6,1 axes; HC,1,7,0 implicit transformation; HC,1,8,0-8,4 explicit transformation;
HC,1,9,0 example point. Reserved characters inside fields are written as `,` (`,`), `;` (`;`), `:` (`:`)
and `&` (`&`) [p.145]. The P1/11 text "requires" the explicit definition, so EPSG codes alone do not suffice [p.150].

> **AMBIGUITY [p.167]:** the D1.11 example file-identification record reads `OGP,OGP P1/11,1,1.1,…`, while D1.6 [p.147]
> gives `OGP,OGP P1,1,1.1,…`. Treat field 2 as free text.

## 7. Implementation notes

- 3.1 is a **strict superset** of 3.0 for readers: four extra format codes, plus a second CRS text syntax in the same 0x55 blocks.
  Every 3.0 file is a valid 3.1 file except for the GH2 minor revision byte and the label/TOC strings.
- Converting 3.1 to 3.0 must map 90xx to the matching 80xx (a byte reversal per sample) and set GH2 byte 12 = 0, SUL = `SD3.0`, TOC = `SD3.0`. A
  P1/11 CRS text has no lossless D2 equivalent. Keep it raw and warn, since a 3.0 reader will not understand it.
- Converting 3.1 to 2.x: SEG-D 2.x has no little-endian codes either. Map them as above, then apply the usual 3-to-2 rules.
- D2 (deprecated) drops the 3.0 sentence that multiple Location Data Stanza IDs may continue a stanza longer than 3200 bytes
  [3.0 p.140, p.152]. 3.1 has no such continuation. Readers may still accept it.
- The 3.1 text says SEG-Y "2.0 will only support" the P1/11 CRS format [p.143, p.169]. SEG-Y 2.0 actually also keeps the old stanzas,
  deprecated (`segy_rev2_0_delta.md`).

## 8. Open questions

1. Should a 3.0-labelled record with a 90xx code be read (lenient) or rejected? Recommendation: read it and warn `dcInconsistent`.
2. Should a P1/11 parser be in scope? For now, expose the raw text with a `crsFormat` = {p111, stanzaD2, unknown} tag.
3. Should a writer that outputs 3.1 keep 90xx when converting from 80xx input? Recommendation: keep the input code unless the user asks.

## 9. Implementation gap analysis (code as of commit 14fbb9d)

Ranked by impact on reading real 3.1 files.

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `src/parseSEG/segd/samples.nim:20-37` (`SegdSampleFormat`, `segdSampleFormats`, `toSegdFormat`), `:39-47` (`dataBytes`), `:57+` (`decodeSamples`), the encoder | 9036/9038/9058/9080 are not in the enum, so `toSegdFormat` returns false. The module doc (line 2) says "All formats are big-endian". | Add `sd9036, sd9038, sd9058, sd9080`. Make sizes equal 80xx. Decode/encode with LE reads (`common/endians`). Update `prefersFloat64` (`sd9038`, `sd9080`). |
| 2 | `src/parseSEG/segd/reader.nim:320-325` (Rev 3 path) | The consequence of #1: any 3.1 record with LE samples raises `dcUnsupportedFormat` ("trace lengths are unknown"), so **the whole record is unreadable**, headers included. | Fixed by #1. Optionally warn when 90xx appears with `revision.minor == 0`. |
| 3 | `src/parseSEG/model/traceindex.nim:129` (`looksLikeSegdGh1`) | Format detection accepts only `toSegdFormat` codes plus multiplexed 00xx/10xx. A 3.1 file with a 90xx code is **not recognised as SEG-D** when there is no label (the comment at :116 already claims "9xxx"). | Fixed by #1, or list 9036/9038/9058/9080 explicitly. |
| 4 | `src/parseSEG/segd/reader.nim:255-257` | Every 3.1 record warns `dcUnsupportedRevision` "revision 3.1 read as Rev 3.0", although the header layout is identical. | Warn only for `major > 3 or minor > 1`. |
| 5 | `src/parseSEG/segd/writer.nim:146`, `:204` | The writer validates `gh1.formatCode` through `toSegdFormat`, so a 3.1 LE record cannot be written back (read/write round trip). | Fixed by #1. Also reject 90xx when GH2 says < 3.1, or warn. |
| 6 | `src/parseSEG/segd/revconvert.nim:63-64`, `:546`, `:580-592` | The target revision may only be 2.0/2.1/3.0, so 3.1 cannot be produced. 3.1 to 3.0 copies the record with `revisionMinor = 0` and "3.1 additions are not checked". A 90xx format would be copied into a 3.0 file, which is invalid there. `fOut` (`:128-129`) only remaps 8080 for 2.x. | Allow target 3.1. When the target is < 3.1, map 90xx to 80xx in `fOut`, and warn about P1/11 CRS text. |
| 7 | `src/parseSEG/segd/rev3.nim:336-341` (`crsText`) | Returns the concatenated text without telling P1/11 (`((OGP:P1/11 CRS))`) from D2 stanzas. No consumer can resolve a position's CRSREF. | Add a `crsFormat` detector (§6.3). A P1/11 record parser is optional. |
| 8 | `src/parseSEG/segd/rev3.nim:116`, `:124` | The fields are named `stanzaId1/2`. In 3.1 they are CRSREF (or stanza ID). This is naming and doc only; the bytes are the same. | Rename or alias to `crsRef1/2`, and update the doc comment at :103-104. |
| 9 | `src/parseSEG/segd/headers.nim:249-253`, `rev3.nim:513` | `SD3.1` labels and TOC revisions are accepted, and nothing cross-checks them against GH2 `03 01`. | Optionally add a consistency warning. |

Already correct for 3.1: GH2 decoding (`rev3.nim:25-26`), the 3.x dispatch (`reader.nim:339`), the TOC entry size of 128
(`rev3.nim:471`), the 0x1A/0x20 Additional Source Info aliasing (`rev3.nim:287`), and the leap-second table, which already includes 2015-06-30
(`rev3.nim:411-418`).
