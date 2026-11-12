# SPS (Shell Processing Support format), Rev 1.0 (1993) and Rev 2.1 (2006): spec note

Sources (page markers `=== PAGE N ===`):
- **1.0**: `SEG Spec/text/SEG SPS Format for Land 3D Surveys.txt` ("as adopted by the SEG in 1993"). Cited `[1.0 p.N]`.
- **2.1**: `SEG Spec/text/seg_sps_rev2.1.txt` ("Rev 2.1", aligned with SEG-D Rev 2.1, Jan 2006). Cited `[2.1 p.N]`.

There was never an SPS Rev 2.0. 2.1 was numbered to match SEG-D 2.1 [2.1 p.3].

SPS is fixed-column **text** (80-column card images), not binary. Because of that, the layout
tables below use **Cols** (1-based, inclusive) and a **Fmt** column with the Fortran edit descriptor,
not the Bytes/Nibble/Enc columns from `CONVENTIONS.md`. The encoding is ASCII on disk and EBCDIC on
legacy tape.

## 1. Scope

| 1.0 pages | 2.1 pages | Content | Covered |
|---|---|---|---|
| 1-2 | 1-2 | Title, TOC | skipped |
| 3-5 | 3-6 | Intro, field system, figures 1-2 | skipped (prose). The 2.1 change list [2.1 p.3-4] is in §8 |
| 6-7 | 7-8 | General: file set, sorting, tape and floppy layout | yes |
| 7-10 | 8-11 | Header record spec, H-type table, I/Rx/Sx code tables, QC records | yes |
| 11 | 12 | Point record (R/S) | yes |
| 12 | 13 | Relation record (X) | yes |
| 13 | 14 | Comment record (C) | yes |
| 14-21 | 15-21 | Header record descriptions with examples | yes (condensed) |
| 22-24 | 22-24 | Point record descriptions, elevation figures 3-4 | yes |
| 25-26 | 25-26 | Relation record descriptions | yes |
| 27-35 | 27-34 | Appendix 1: example R, S and X files | used to verify columns (§9) |

## 2. File set and record structure

### 2.1 Files [1.0 p.6] [2.1 p.7-8]

| Order | File | Ext. prefix | Records | Content |
|---|---|---|---|---|
| 1 | Receiver | `R` (e.g. `PRJX90.R01`) | H…, R… | One point record per receiver group or permanent marker |
| 2 | Source | `S` (`PRJX90.S01`) | H…, S… | One point record per shotpoint |
| 3 | Cross-reference (relation) | `X` (`PRJX90.X01`) | H…, X… | Maps field record → shot, and channels → receiver groups |
| opt. | Comment | `C` (`PRJX90.C01`) | H…, C… | Observer-report comments |

- Every file starts with an **identical block of header (H) records**, followed by its data records [1.0 p.6, p.7].
- Each physical position (shotpoint or receiver group) **must have a unique name** [1.0 p.6].
- Point files hold all geophysical points, observed and interpolated, plus all permanent markers [1.0 p.6].

### 2.2 Physical layout

| Medium | Rule | Ref |
|---|---|---|
| Disk ("floppy", MS-DOS) | ASCII. **80-character record + CR (col 81) + LF (col 82)**, so 82 bytes per line | [1.0 p.7] [2.1 p.8] |
| 9-track tape | IBM-compatible, unlabelled, **EBCDIC**, 80-byte logical records, **1600-byte blocks (20 records)**, 6250 bpi (1600 allowed) | [1.0 p.6] [2.1 p.7] |
| Tape EOF | Each file ends with a record holding `EOF` in cols 1-3, followed by a tape mark. The tape ends with two tape marks | [1.0 p.6] [2.1 p.7] |
| 2.1 labelling | Both sections are titled "**Legacy** Format…". No other medium is defined | [2.1 p.7-8] |

### 2.3 Record types (col 1)

| Col 1 | Record | Files |
|---|---|---|
| `H` | Header | all |
| `R` | Receiver point | R |
| `S` | Source point | S |
| `X` | Relation | X |
| `C` | Comment | C (optional) |
| `EOF` (cols 1-3) | End of file (tape only) | all |

### 2.4 Field-format conventions [1.0 p.13] [2.1 p.12-13]

| Fmt | Meaning | Read | Write |
|---|---|---|---|
| `An`, `kAn` | Character, k×n columns | Keep raw; trim trailing blanks | **Left-justified**, blank-padded |
| `In` | Integer, n columns | Right-justified. All blank = missing (see "blank" defaults) | Right-justified, blank-padded |
| `Fw.d` | Real, w columns, d decimals | Right-justified. An explicit `.` wins. See the implied-decimal AMBIGUITY in §4.3 | `%w.df`, right-justified |
| `3I2` (time) | `hhmmss`, 6 digits | Zero-padded digits | Zero-padded `hhmmss` |

"Alphanumeric (A) fields are to be left justified and Numeric (I and F) fields are to be right
justified unless specified otherwise" [1.0 p.13] [2.1 p.12, p.13].

## 3. Header (H) records

### 3.1 General layout [1.0 p.7] [2.1 p.8]

| Cols | Len | Fmt | Field (`nimIdent`) | Meaning |
|---|---|---|---|---|
| 1 | 1 | A1 | `recordId` | `H` |
| 2-3 | 2 | I2 | `headerType` | Header record type, e.g. `00`, `26`, `40`, `99` |
| 4 | 1 | I1 | `typeModifier` | Modifier digit, or blank. `H021` = type 02 / modifier 1. `H26 ` = type 26 / blank |
| 5-32 | 28 | 7A4 | `description` | Parameter description, left-justified (the standard label text below) |
| 33-80 | 48 | see table | `data` | Parameter data. H26 is the exception: free text in **cols 5-80** |

- Identify a header by its cols 2-4, with trailing blanks trimmed (`"00"`, `"021"`, `"26"`, `"400"`).
- **Mandatory**: H0-H20 for every survey. Use `N/A` where needed, except that **H18 may not be N/A**. H21-H25 are mandatory where they apply to the projection [1.0 p.7].

  > **AMBIGUITY [1.0 p.7]:** The text says "H21 to H25". No H21-H25 records exist, so this
  > presumably means the H210-H259 family.
- Required headers by projection [1.0 p.7]:

  | Projection | Required |
  |---|---|
  | Transverse Mercator | H220, H231, H232, H241, H242 |
  | UTM | H19, H220 |
  | Stereographic | H231, H232, H241, H242 |
  | Oblique Mercator | H231, H232, H241, H242, H259, plus one of H256/H257/H258 |
  | Lambert Conical | H210, H220, H231, H232, H241, H242 |
- **Free-format parsing rule** for 12A4 data fields: parameters are separated by `,` and the string is terminated by `;`. Parameter text may not contain `,` or `;` [1.0 p.14] [2.1 p.15]. The examples often leave out the `;` (e.g. H12), so treat a missing `;` as the end of the field.
- For the H4xx/H6xx/H7xx-H8xx tables, **cols 33-34 must hold the instrument/receiver/source code** (`1,`..`9,` or `G1`, `V1`, ...), followed by `,` [1.0 p.14] [1.0 p.17].
- Distances are in metres, except grid coordinates, which are in the units of H20 (convert to metres with the H201 factor) [1.0 p.14]. In 2.1, point depth, datum and water depth are in "header defined" units [2.1 p.12].

### 3.2 General / geodetic header records [1.0 p.8] [2.1 p.8-9]

| ID | 1.0 | 2.1 | Description (cols 5-32) | Data cols | Fmt | Sub-fields / notes |
|---|---|---|---|---|---|---|
| H00 | ✓ | ✓ | SPS format version num. | 33-80 | 12A4 | **Revision marker.** 1.0 example: `SPS001,01.10.90;` [1.0 p.14] and `SPS001,08OCT1990 (...)` [1.0 p.27]. 2.1: `SPS 2.1;` ("should be in this format") [2.1 p.15] |
| H01 | ✓ | ✓ | Description of survey area | 33-80 | 12A4 | country, area, survey type (L2D/L3D/TZ2D/TZ3D), project no. |
| H02 | ✓ | ✓ | Date of survey | 33-80 | 12A4 | first and last date on this file |
| H021 | ✓ | ✓ | Post-plot date of issue | 33-80 | 12A4 | |
| H022 | ✓ | ✓ | Tape/disk identifier | 33-80 | 12A4 | |
| **H023** | – | ✓ | Line sequence number | 33-80 | **I5** | **New in 2.1.** Lets more than one production line share a tape, provided that (field file number, line sequence number) is unique per storage unit [2.1 p.3, p.9, p.15]. Example `5;` |
| H03 | ✓ | ✓ | Client | 33-80 | 12A4 | |
| H04 | ✓ | ✓ | Geophysical contractor | 33-80 | 12A4 | company, party |
| H05 | ✓ | ✓ | Positioning contractor | 33-80 | 12A4 | |
| H06 | ✓ | ✓ | Pos. proc. contractor | 33-80 | 12A4 | |
| H07 | ✓ | ✓ | Field computer system(s) | 33-80 | 12A4 | |
| H08 | ✓ | ✓ | Coordinate location | 33-80 | 12A4 | what the coordinates refer to |
| H09 | ✓ | ✓ | Offset from coord. location | 33-80 | 12A4 | |
| H10 | ✓ | ✓ | Clock time w.r.t. GMT | 33-80 | 12A4 | hours, e.g. `+2;` |
| H11 | ✓ | ✓ | Spare | 33-80 | 12A4 | |
| H12 | ✓ | ✓ | Geodetic datum,-spheroid | 33-80 | 3A4,3A4,F12.3,F12.7 | datum name 33-44, spheroid name 45-56, semi-major axis a 57-68, inverse flattening 1/f 69-80 |
| H13 | ✓ | ✓ | Spare | 33-80 | 12A4 | |
| H14 | ✓ | ✓ | Geodetic datum parameters | 33-80 | 3(F8.3),4(F6.3) | dx 33-40, dy 41-48, dz 49-56 (m); rx 57-62, ry 63-68, rz 69-74 (arcsec, clockwise); ds 75-80 (ppm). Transformation to **WGS72 (1.0)** / **WGS84 (2.1)** [1.0 p.15] [2.1 p.16] |
| H15, H16 | ✓ | ✓ | Spare | 33-80 | 12A4 | |
| H17 | ✓ | ✓ | Vertical datum description | 33-80 | 12A4 | name, type, origin, undulation |
| H18 | ✓ | ✓ | Projection type | 33-80 | 12A4 | **N/A not allowed** |
| H19 | ✓ | ✓ | Projection zone | 33-80 | 12A4 | e.g. `Zone 30, North;` |
| H20 | ✓ | ✓ | Description of grid units | 33-56 | 6A4 | Metres / International Feet / ... |
| H201 | ✓ | ✓ | Factor to metre (2.1: meter) | 33-46 | F14.8 | grid unit → metres |
| H210 | ✓ | ✓ | Lat. of standard parallel(s) | 33-56 | 2(I3,I2,F6.3,A1) | per parallel: ddd 33-35, mm 36-37, ss.sss 38-43, N/S 44; second parallel 45-56 |
| H220 | ✓ | ✓ | Long. of central meridian | 33-44 | I3,I2,F6.3,A1 | dddmmss.sss E/W |
| H231 | ✓ | ✓ | Grid origin | 33-56 | 2(I3,I2,F6.3,A1) | lat 33-44, long 45-56 |
| H232 | ✓ | ✓ | Grid coord. at origin | 33-56 | 2(F11.2,A1) | false easting 33-43 + `E` 44, false northing 45-55 + `N` 56 |
| H241 | ✓ | ✓ | Scale factor | 33-44 | F12.10 | |
| H242 | ✓ | ✓ | Lat., long. scale factor | 33-56 | 2(F11.2,A1) | see AMBIGUITY below |
| H256 | ✓ | ✓ | Lat., long. initial line | 33-56 | 4(I3,I2,F6.3,A1) | lat1, long1, lat2, long2. See AMBIGUITY |
| H257 | ✓ | ✓ | Circular bearing of H256 | 33-44 | I3,I2,F7.4 | dddmmss.ssss |
| H258 | ✓ | ✓ | Quadrant bearing of H256 | 33-44 | A1,2I2,F6.3,A1 | N/S, dd, mm, ss.sss, E/W |
| H259 | ✓ | ✓ | Angle from skew | 33-44 | I3,I2,F7.4 | |
| H26 | ✓ | ✓ | Any other relevant information | **5-80** | 19A4 | Free text. Repeatable. Also used to describe the PM/KL codes [1.0 p.9] |
| H30 | ✓ | ✓ | Project code and description | 33-78 | 3A2,10A4 | 6-char code 33-38, then area name / type 39-78 |
| H31 | ✓ | ✓ **obsolete** | Line number format | 33-80 | 12A4 | `NAME1(POS1:LEN1),...;`, e.g. `BLOCK(1:4),STRIP(5:4),LINE NUMBER(9:8);`, or `LINE NUMBER(1:16);` when the field is not split. In 2.1 it is marked "(Obsolete)" because the line is numeric F10.2 [2.1 p.4, p.9, p.18] |

> **AMBIGUITY [1.0 p.8, p.16; 2.1 p.9, p.17]:** H242 is given as `2(F11.2,A1)`, but the text and
> both examples hold lat/long in `dddmmss.sss` form (`0000000.000N0510000.000E` [2.1 p.27]).
> The two layouts have the same widths (11+1, twice), so parse H242 like H231 (`I3,I2,F6.3,A1` ×2).

> **AMBIGUITY [1.0 p.8]:** H256 is `4(I3,I2,F6.3,A1)`, which is 48 columns (33-80), but the table
> says 33-56. Read 33-80.

> **AMBIGUITY [2.1 p.9, p.30]:** H023 is "33-80 I5". I5 covers only cols 33-37. The example puts the
> digit at col 38 followed by `;`, but the extraction shifts blanks, so this can't be verified.
> Read it as a free integer from cols 33-80, up to `;`. Write it right-justified in 33-37.

> **AMBIGUITY [1.0 p.14-16]:** The H210/H220/H231 examples are fixed-format (no commas). The
> H12/H14 examples are blank-separated. The H232 example `50000000.0E` overflows F11.2. Expect
> real files to deviate. Parse the geodetic headers by position first, then fall back to tokens.

### 3.3 Instrument code tables (H400-H579) [1.0 p.8-9, p.17-18]

Code n (1..9) uses **H(400 + 20·(n−1)) … H(419 + 20·(n−1))**: code 1 = H400-H419, code 2 = H420-H439, …, code 9 = H560-H579.
Cols 33-34 hold `n,`. X-record col 13 (1.0) or col 17 (2.1) refers to `n`. A new code is needed for each
instrument, or for any change of parameter.

| Offset | Description (cols 5-32) | Data (33-80, 12A4) | Example |
|---|---|---|---|
| +0 (H400) | Type,Model,Polarity | type/model, serial, SEG or NON SEG polarity | `1,SN368+LXU,12345,SEG;` |
| +1 | Crew name,Comment | | `1,Prakla SON 1;` |
| +2 | Sample int.,Record Len. | | `1,2MSEC,6SEC;` |
| +3 | Number of channels | | `1,480;` |
| +4 | Tape type,format,density | | `1,9 track,SEGD,6250;` |
| +5 | Filter_alias Hz,dB pnt,slope | | `177HZ,-6DB,72 DB/OCT;` (the spec example omits the code) |
| +6 | Filter_notch Hz,-3dB points | | `1,NONE;` / `1,50,45,55;` |
| +7 | Filter_low Hz,dB pnt,slope | | `1,8HZ,-3DB,18 DB/OCT;` |
| +8 | Time delay FTB-SOD app Y/N | | `1,0 Msec,not applied;` |
| +9 | Multi component recording | component order on consecutive channels, from `X`,`Y`,`Z` | `1,Z;` / `1,Z,X,Y;` |
| +10..+13 | Aux. channel 1..4 contents | | `1,FTB;` |
| +14..+19 | Spare | | |

### 3.4 Receiver code tables (H600-H699) [1.0 p.9, p.18-19]

Code k (1..10) uses **H(600 + 10·(k−1)) … H(609 + 10·(k−1))**: H600-H609 … H690-H699. Cols 33-34 hold the receiver
point code (`G1`, ...).

| Offset | Description | Example |
|---|---|---|
| +0 | Type,model,polarity | `G1,SM-4,1234,SEG;` |
| +1 | Damp coeff,natural freq. | `G1,0.68,10Hz;` |
| +2 | Nunits,len(X),width(Y) | `G1,12,25M,6M;` |
| +3 | Unit spacing X,Y | `G1,4M,6M;` |
| +4..+9 | Spare | (the 2.1 example puts a description in +4, e.g. `H614Description G2`) [2.1 p.27] |

PM and KL have no table and are described in H26 records [1.0 p.9].

### 3.5 Source code tables (H700-H899) [1.0 p.9-10, p.19-20]

Code k (1..10) uses **H(700 + 20·(k−1)) … H(719 + 20·(k−1))**: H700-H719 … H880-H899. Cols 33-34 hold the source code.
The 2.1 example uses H800/H820/H840 (tables 6/7/8) for V6/V7/V8 [2.1 p.28]. The table slot is independent of the
code text. Map by cols 33-34.

| Offset | Description | Applies to | Example |
|---|---|---|---|
| +0 | Type,model,polarity | all | `E1,EXPLOSIVE,SEISMOGEL 125gram,SEG;` |
| +1 | Size,vert. stk fold | all | `V1,93 kN,1 SWEEP/VP;` |
| +2 | Nunits,len(X),width(Y) | all | `V1,4 VIBS,25M,45M;` |
| +3 | Unit spacing X,Y | all | `V1,8M,15M;` |
| +4 | Control type | vibroseis V1-V9 | `V1,GND FORCE PHASE&AMPL LOCK;` |
| +5 | Correlator,noise supp | vibroseis | |
| +6 | Sweep type,length | vibroseis | `V1,LINEAR,30 SECONDS;` |
| +7 | Sweep freq start,end | vibroseis | `V1,5HZ,60HZ;` |
| +8 | Taper,length start,end | vibroseis | `V1,COSINE,500MSEC,500MSEC;` |
| +9, +10 | Spare | vibroseis | |
| +11 | Nom. shot depth,charge len. | explosive E1-E9 | `E1,15M,1M;` |
| +12 | Nom. soil,drill method | explosive | |
| +13 | Weathering thickness | explosive | `E1,8-12M;` |
| +14, +15 | Spare | explosive | |
| +16 | P-P bar m,prim/bubble | air gun A1-A9 / water gun W1-W9 | `A1,50,13:1;` |
| +17 | Air pressure psi | air/water gun | `A1,2000PSI;` |
| +18 | No. sub arrays,Nom depth | air/water gun | `A1,3,5.5M;` |
| +19 | Spare | | |

### 3.6 Point code values (R/S cols 27-28 in 1.0, 25-26 in 2.1) [1.0 p.9, p.11]

| Code | Meaning | File |
|---|---|---|
| `G1`-`G9` | geophone types | R |
| `H1`-`H9` | hydrophone types | R |
| `R1`-`R9` | multi-component and other receiver types | R |
| `V1`-`V9` | vibroseis | S |
| `E1`-`E9` | explosive | S |
| `A1`-`A9` | air gun | S |
| `W1`-`W9` | water gun | S |
| `S1`-`S9` | other source types | S |
| `PM` | permanent marker | R (or S) |
| `KL` | kill / omit point | R, S |

These are "examples of possible codes". The authoritative set is whatever the header tables define.

### 3.7 QC header records [1.0 p.10, p.20-21] [2.1 p.11, p.21]

| ID | Description | Cols | Fmt | Example |
|---|---|---|---|---|
| H990 | R,S,X file quality control | 33-60 | 2A4,I4,4A4 | `01JUN90,0930,Mr J Smith;`: date, time hhmm, name |
| H991 | Coord. status final/prov | 33-68 | 4A4,I4,4A4 | `Final,01jun90,0930,Mr J. Jansen;`: status, date, time, name |

> **AMBIGUITY [1.0 p.10]:** The fixed formats (`2A4,I4,4A4`) and the comma-separated examples
> disagree. Parse by tokens.

## 4. Point records (R and S)

### 4.1 Side-by-side layout [1.0 p.11] [2.1 p.12]

Shift = 2.1 start col minus 1.0 start col.

| # | Field (`nimIdent`) | 1.0 cols | 1.0 fmt | 2.1 cols | 2.1 fmt | Shift | Range (1.0 / 2.1) | Default (1.0 / 2.1) | Units | Meaning |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `recordId` | 1 | A1 | 1 | A1 | 0 | `R`/`S` | none | – | record type |
| 2 | `line` | **2-17** | **4A4** (left-adj.) | **2-11** | **F10.2** (right) | width 16→10 | free / −999999.99..9999999.99 | none | – | shot or receiver line name/number |
| 3 | `point` | **18-25** | **2A4** (right-adj.) | **12-21** | **F10.2** (right) | −6 | free / −999999.99..9999999.99 | none | – | point (station) number, centre of the array |
| – | (blank) | – | – | **22-23** | blank | new | – | blank | – | "For compatibility reasons cols 22-23 are left blank" [2.1 p.12] |
| 4 | `pointIndex` | 26 | I1 | 24 | I1 | −2 | 1-9 | 1 | – | reshoot or reposition index |
| 5 | `pointCode` | 27-28 | A2 | 25-26 | A2 (left) | −2 | §3.6 | none | – | source/receiver code |
| 6 | `staticCorrection` | 29-32 | I4 | 27-30 | I4 | −2 | −999..999 | **blank** | ms | field static, referenced to `seismicDatum` |
| 7 | `pointDepth` | 33-36 | F4.1 | 31-34 | F4.1 | −2 | 0..99.9 | none / **0** | m / header-defined | depth below surface to the top of the charge or receiver array |
| 8 | `seismicDatum` | 37-40 | I4 | 35-38 | I4 | −2 | −999..9999 | none / **0** | m / header-defined | seismic datum relative to H17 (+ above, − below) |
| 9 | `upholeTime` | 41-42 | I2 | 39-40 | I2 | −2 | 0..99 | **blank** | ms | vertical travel time (shots, or a reverse uphole at receivers) |
| 10 | `waterDepth` | 43-46 | F4.1 (read as F5.1, see note) | **41-46** | **F6.1** | −2, width 4→6 | 0..99.9/999 / 0..9999.9 | **blank** | m / header-defined | water surface height above the bottom; always ≥ 0 |
| 11 | `easting` | 47-55 | F9.1 | 47-55 | F9.1 | 0 | – | none | grid (H20) | map grid easting |
| 12 | `northing` | 56-65 | F10.1 | 56-65 | F10.1 | 0 | – | none | grid (H20) | map grid northing |
| 13 | `elevation` | 66-71 | F6.1 | 66-71 | F6.1 | 0 | −999.9..9999.9 | none | m | surface elevation relative to H17 |
| 14 | `dayOfYear` | 72-74 | I3 | 72-74 | I3 | 0 | 1..999 | none | – | Julian day. Does **not** reset at the new year (1 Jan → 366/367) |
| 15 | `time` (`hh`,`mm`,`ss`) | 75-80 | 3I2 | 75-80 | 3I2 | 0 | 000000..235959 | none | – | clock of the master recording instrument |

Notes:
- **Cols 47-80 are identical in both revisions.** Only cols 2-46 differ.
- For a receiver, the depth, water depth, elevation, day and time values are those at the time of the **first shot recorded into that receiver** [1.0 p.11, p.22-23].
- Item 4 semantics [1.0 p.22]. *Shot*: 1 for the original shot in the grid cell (line, point), +1 for each later shot there. Vertically stacked (unsummed vibroseis) shots keep the same index. *Receiver*: 1 for the original position, +1 every time the group is moved, even when it goes back to a previous position.
- 1.0 water-depth footnote: "Water depth should be read in as F5.1 to allow for 4 character decimal and integer values" [1.0 p.11].

> **AMBIGUITY [1.0 p.11]:** F5.1 would overlap col 42 (uphole time). Read cols 43-46 only, and
> parse the field as free-form real: `99.9` → 99.9, `999` → 999.0 (no implied decimal). That is
> what the footnote seems to mean.

> **AMBIGUITY [1.0 p.11, p.22]:** The 1.0 point number is `2A4` "Free" but "should be read as a
> numeric and be right justified". The 1.0 example has non-numeric points (`su`, `SA`, `MP`)
> on PM records, written **left**-justified [1.0 p.28]. The 1.0 line name is alphanumeric
> (`91LW1124`, `N061.014`, `1228.339`). Keep both as strings and add a best-effort numeric value.

> **AMBIGUITY [2.1 p.12, p.13, p.22]:** "If no decimal point is provided it should be taken as
> implied." Under Fortran `F10.2` rules, `      5646` reads as 56.46. Most writers mean 5646.
> Proposed: an explicit `.` wins. With no `.`, read the value as an integer (5646.0), and offer a
> strict Fortran mode as an option.

> **AMBIGUITY [2.1 p.12]:** Note "+": cols 22-23 are blank "for compatibility". This does **not**
> keep 1.0 compatibility, because index and code still move from 26/27-28 to 24/25-26. The 2.1
> examples confirm the 2.1 positions (§9).

### 4.2 Blank / default semantics

| Situation | Reader | Writer |
|---|---|---|
| Default "blank" (static, uphole, water depth) | all-blank → missing (`NaN` / `none`), **not 0** | missing → blanks |
| Default "1" (point index) | blank → 1 | always write the digit |
| Default "0" (2.1 depth, datum) | blank → 0 | write 0 |
| Default "none" (mandatory) | blank → missing; validation error for line, point, code, easting, northing | must be present |
| Header "undefined" value | the 1.0 example notes "Undefined value is replaced by ----" in H26 [1.0 p.27]. Treat non-numeric dashes in a numeric field as missing | – |

### 4.3 Reading robustness (real-world)

- Lines may be shorter than 80 (trailing blanks stripped) or end in LF only. Pad to 80 before slicing.
- Accept a 1.0 PM record with blank time (e.g. `...112.1 48` with cols 75-80 blank [1.0 p.28]).

## 5. Relation records (X)

### 5.1 Side-by-side layout [1.0 p.12] [2.1 p.13]

| # | Field (`nimIdent`) | 1.0 cols | 1.0 fmt | 2.1 cols | 2.1 fmt | Shift | Range (1.0 / 2.1) | Default | Meaning |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `recordId` | 1 | A1 | 1 | A1 | 0 | `X` | none | |
| 2 | `fieldTape` | 2-7 | 3A2 (left) | 2-7 | 3A2 | 0 | free | none | tape/carrier identifier |
| 3 | `fieldRecord` | **8-11** | **I4** | **8-15** | **I8** | width 4→8 | 0..9999 / 0..16777216 | none | field record (file) number |
| 4 | `recordIncrement` | 12 | I1 | 16 | I1 | +4 | 1-9 | 1 | increment for consecutive records of the same shot and spread |
| 5 | `instrumentCode` | 13 | A1 | 17 | A1 | +4 | 1-9 | 1 | instrument table (§3.3) |
| 6 | `srcLine` | **14-29** | **4A4** (left) | **18-27** | **F10.2** | +4, width 16→10 | free / ±F10.2 | none | = S record field 2 |
| 7 | `srcPoint` | **30-37** | **2A4** (right) | **28-37** | **F10.2** | −2, width 8→10 | free / ±F10.2 | none | = S record field 3 |
| 8 | `srcIndex` | 38 | I1 | 38 | I1 | 0 | 1-9 | 1 | = S record field 4 |
| 9 | `fromChannel` | **39-42** | **I4** | **39-43** | **I5** | width 4→5 | 1-9999 / 1-99999 | none | first channel of the run |
| 10 | `toChannel` | **43-46** | **I4** | **44-48** | **I5** | +1, width 4→5 | 1-9999 / 1-99999 | none | last channel of the run |
| 11 | `channelIncrement` | 47 | I1 | 49 | I1 | +2 | 1-9 | 1 | channel step |
| 12 | `rcvLine` | **48-63** | **4A4** (left) | **50-59** | **F10.2** | +2, width 16→10 | free / ±F10.2 | none | = R record field 2 |
| 13 | `fromReceiver` | **64-71** | **2A4** (right) | **60-69** | **F10.2** | −4, width 8→10 | free / ±F10.2 | none | receiver point for `fromChannel` |
| 14 | `toReceiver` | **72-79** | **2A4** (right) | **70-79** | **F10.2** | −2, width 8→10 | free / ±F10.2 | none | receiver point for `toChannel` |
| 15 | `rcvIndex` | 80 | I1 | 80 | I1 | 0 | 1-9 | 1 | = R record field 4 for the whole run |

Notes:
- Only cols 1-7, 38 and 80 are at the same positions in both revisions. Every other X field moves.
- Every shotpoint has **at least one** X record. Each X record covers one run of **consecutively numbered channels and receiver groups**. Start a new X record after a numbering gap, a change of receiver line, or a repositioning (index change). Channel numbers should be ascending [1.0 p.12].
- Fields 6-8 must equal fields 2-4 of the matching S record. The pairs (12,13,15) and (12,14,15) must match R records [1.0 p.12, p.26].
- `fromChannel`/`toChannel` are "the seismic channel number as recorded in the seismic trace header" [1.0 p.25].

> **AMBIGUITY [2.1 p.13, p.25]:** The 2.1 table gives `fieldTape` (3A2) justification "right".
> The description still says "left justified in the field". The example `B79480` fills all
> 6 columns, so it can't settle this. Read trimmed, write left-justified.

> **AMBIGUITY [2.1 p.13]:** The `fieldRecord` max of 16777216 is 2^24. A 3-byte SEG-D extended
> file number holds at most 16777215. Accept any I8 value.

> **AMBIGUITY [2.1 p.13]:** `instrumentCode` is A1 with justification "right". In one column
> that makes no difference.

### 5.2 Channel → receiver mapping (algorithm)

The spec gives the endpoints only. The receiver point step is **implied** by linear
interpolation between `fromReceiver` and `toReceiver` over the channel run [1.0 p.12, p.25-26].

```
n     = (toChannel - fromChannel) div channelIncrement + 1     # stations in the run
step  = if n > 1: (toReceiver - fromReceiver) / (n - 1) else: 0   # may be negative or fractional
for i in 0 ..< n:
  channel(i)  = fromChannel + i*channelIncrement
  receiver(i) = (rcvLine, fromReceiver + i*step, rcvIndex)
source      = (srcLine, srcPoint, srcIndex)     # join to the S record
records     = fieldRecord, fieldRecord + recordIncrement, ...   # see AMBIGUITY
```

- Validation: `(toChannel - fromChannel) mod channelIncrement == 0`. `n == 1` ⇒ `fromReceiver == toReceiver`. Each `receiver(i)` should exist in the R file. A non-integer `step` is legal (F10.2 points) but suspicious; warn if the interpolated point has no R record.
- Receivers may run **descending** (negative step) while channels ascend.
- 1.0 with non-numeric point names: interpolation is impossible. Only the endpoints can be resolved, plus single-station runs.
- **Multi-component** (`channelIncrement` > 1) [1.0 p.25]: "when the three components (Z,X and Y) for one receiver point are recorded on three consecutive seismic channels, then one 'X' record can define three components using a channel increment of 3. The components and their order are defined by the instrument code" (H4x9 multi-component record). Proposed mapping: channel `channel(i) + k`, for `k` in `0 ..< channelIncrement`, is component `k` (order from H409) at `receiver(i)`.

> **AMBIGUITY [1.0 p.25]:** The spec does not say whether channels between the stepped channels
> (k > 0) belong to station i, or are simply not in this X record. Choosing the
> multi-component reading (above) only when H409 lists more than one component is the
> conservative option.

> **AMBIGUITY [1.0 p.25]:** `recordIncrement` lets "several consecutive records which recorded
> the same shotpoint and spread" (e.g. unsummed vibroseis) share one X record. The **count** of
> such records is not given anywhere. Candidates: the vertical stack fold in the source table
> (H7x1 "Size,vert. stk fold"), or "until the next X record's fieldRecord". Default: the X
> record applies to `fieldRecord` only, unless the caller supplies a count.

### 5.3 Worked examples (from the appendices)

**2.1** [2.1 p.32], rebuilt at the exact 2.1 columns (the extracted line has shifted blanks):

```
         1         2         3         4         5         6         7         8
12345678901234567890123456789012345678901234567890123456789012345678901234567890
XB79480       111   5713.00 542525.002    1  3201   5646.00 534550.00 550500.001
```
`fieldTape`=B79480, `fieldRecord`=1, `recordIncrement`=1, `instrumentCode`=1, source = (5713.00, 542525.00, idx 2),
channels 1..320 step 1, receivers on line 5646.00 from 534550.00 to 550500.00, idx 1.
n = 320, step = (550500 − 534550)/319 = **50.0**. This matches the 50-unit point spacing in the R file [2.1 p.28-29].
So channel 1 → 534550, channel 2 → 534600, channel 100 → 534550 + 99·50 = 539500, channel 320 → 550500.
The next X records for the same shot continue with channels 321-640 on line 5662, …, 1601-1920 on
line 5726: 6 lines × 320 = 1920 channels, which matches H403 `1, 1920` [2.1 p.27].
The source (5713.00, 542525.00, 2) matches the S record `S   5713.00 542525.00 2V6 …` [2.1 p.31].

**1.0** [1.0 p.33]: the extracted line `X100        11191LW1117            2251    1 37191LW1124              225     2611` (blank runs distorted) decodes to
tape `100`, record 1, rec. incr 1, instr 1, source line `91LW1117` point `225` index 1, channels 1-37 step 1,
receiver line `91LW1124` points 225→261 index 1. Step = 36/36 = 1, so channel 13 → point 237. The second X record
for the same shot maps channels 38-74 to line `91LW1132`, points 225-261. Later shots widen to 1-50 / 51-100
→ points 225-274 [1.0 p.33-34] (rolling spread). Tape `101` restarts at record 1 [1.0 p.35].

## 6. Comment records (C) [1.0 p.13] [2.1 p.14]

| Cols | Len | Fmt | Field | Meaning |
|---|---|---|---|---|
| 1 | 1 | A1 | `recordId` | `C` |
| 2-80 | 79 | 79A1 | `comment` | free text (bad/noisy traces per record, tests, observer notes). Default blank |

Same in both revisions. Comments go in the optional C file, not in R/S/X files.

## 7. Derived rules

### 7.1 Sort order [1.0 p.6] [2.1 p.7]

| File | Sort key |
|---|---|
| R | ascending (line, point, point index) |
| S | **chronological**: (day of year, time). Day does not wrap at the year end |
| X | same order as the S file (chronological by shot). Within a shot, channels ascending |
| C | – |

In 1.0, the R sort on alphanumeric line names is a string sort. The 2.1 R sort is numeric.

### 7.2 Revision detection

| Signal | 1.0 | 2.1 | Strength |
|---|---|---|---|
| H00 data (cols 33-80) | `SPS001,...` (any non-"2.1") | `SPS 2.1` [2.1 p.15] | primary, if present |
| H023 present | never | optional | proves 2.1 |
| H31 | meaningful | "Obsolete" | weak |
| R/S cols 22-23 | part of the point number (blank for points of up to 3 digits) | **blank** | medium |
| R/S col 24 / col 26 | col 26 = index digit | col 24 = index digit, cols 25-26 = code | strong |
| R/S cols 2-11, 12-21 | free text | both parse as F10.2 (often with `.` at col 9 and col 19) | weak: a numeric 1.0 line name and a 5-digit point parse too |
| X col 49 / col 47 | 47 = channel increment | 49 = channel increment, cols 44-48 to-channel | medium |

Algorithm: if H00 declares `SPS 2.1` (also `SPS V2.1`, `SPS REV 2.1`), use 2.1. If it declares
`SPS001` or `SPS 1.0` (`SPS V1.0`, `SPS REV 1.0`), use 1.0. Otherwise each of the first 50 data
records votes for the layout whose structural rules it satisfies more of (where the fields
end, which columns are blank, digits or letters: R/S cols 11, 21, 22-28; X the right-justified
`Iw` fields at 8-15, 39-43, 44-48 against 8-11, 39-42, 43-46), ties count for 2.1, and the reader
warns that the revision was not declared. A caller's choice wins. Whether the fields parse as
numbers does not separate the layouts: 1.0 files with numeric line names, five-digit points
or relation records pass as 2.1 on that test.

> **AMBIGUITY:** There is no mandated machine-readable version token. 2.1 says only the version
> "should be in this format. Example: SPS 2.1;" [2.1 p.15].

### 7.3 Validation rules (checklist)

| # | Rule | Ref |
|---|---|---|
| V1 | Every record is 80 columns. Col 1 ∈ {H,R,S,X,C}. On tape, `EOF` closes the file | [1.0 p.6-7] |
| V2 | The header block is identical in R, S, X (and C) | [1.0 p.6] |
| V3 | H00-H20 present. H18 ≠ `N/A`. Projection headers as in §3.1 | [1.0 p.7] |
| V4 | H4xx/H6xx/H7xx data starts with the code in cols 33-34 | [1.0 p.14] |
| V5 | Every point code in R/S is defined by a table or is PM/KL (described in H26) | [1.0 p.9, p.22] |
| V6 | Every X instrument code has an H4xx table | [1.0 p.25] |
| V7 | Point index 1-9, channel increment 1-9, record increment 1-9 | tables |
| V8 | Day 1-999. Time 000000-235959 (hh ≤ 23, mm ≤ 59, ss ≤ 59) | tables |
| V9 | Value ranges as in §4.1 / §5.1 | tables |
| V10 | (line, point, index) is unique within R and within S | [1.0 p.6] |
| V11 | Each S record has ≥ 1 X record. Each X record's (6,7,8) matches an S record | [1.0 p.12] |
| V12 | X (12,13,15) and (12,14,15) exist in R. Interpolated stations should exist | [1.0 p.12, p.26] |
| V13 | Within a shot's X records, channel runs ascend and don't overlap | [1.0 p.12] |
| V14 | Sort order as in §7.1 (warn, don't reject) | [1.0 p.6] |
| V15 | 2.1: (H023 line sequence number, fieldRecord) is unique per storage unit (tape) | [2.1 p.15] |

## 8. Revision differences (1.0 → 2.1)

| Area | 1.0 (1993) | 2.1 (2006) | Ref |
|---|---|---|---|
| Version string (H00) | `SPS001,<date>` | `SPS 2.1;` | [1.0 p.14] [2.1 p.15] |
| Line sequence number | – | **H023** (I5) | [2.1 p.9, p.15] |
| H31 line number format | used (splits a 16-char line name) | obsolete | [2.1 p.4, p.9] |
| Datum transform target (H14/H17) | WGS72 | WGS84 | [2.1 p.4, p.16] |
| UKOOA reference | P1/84 | P1/90 | [2.1 p.4, p.23] |
| R/S line | A16 (2-17), alphanumeric | F10.2 (2-11), numeric | [2.1 p.12] |
| R/S point | A8 (18-25) | F10.2 (12-21) | [2.1 p.12] |
| R/S cols 22-23 | in point/index area | blank | [2.1 p.12] |
| R/S index / code / static / depth / datum / uphole | 26 / 27-28 / 29-32 / 33-36 / 37-40 / 41-42 | 24 / 25-26 / 27-30 / 31-34 / 35-38 / 39-40 | [1.0 p.11] [2.1 p.12] |
| R/S water depth | F4.1 at 43-46 ("read as F5.1") | F6.1 at 41-46 | same |
| R/S depth/datum default | none | 0 | [2.1 p.12] |
| R/S depth/datum/water units | metres | "header defined" | [2.1 p.12, p.22] |
| R/S cols 47-80 | – | unchanged | |
| X field record | I4 (8-11), ≤ 9999 | I8 (8-15), ≤ 16777216 | [2.1 p.13] |
| X source line / point | A16 (14-29) / A8 (30-37) | F10.2 (18-27) / F10.2 (28-37) | |
| X channels | I4/I4 (39-42/43-46), ≤ 9999 | I5/I5 (39-43/44-48), ≤ 99999 | |
| X receiver line / from / to | A16 (48-63) / A8 (64-71) / A8 (72-79) | F10.2 (50-59/60-69/70-79) | |
| Tape and floppy sections | normative | "Legacy" | [2.1 p.7-8] |
| Survey scope | land 3D (2D possible) | "3D surveys", other types possible | [2.1 p.1, p.3] |

## 9. Column verification against the appendices

The extracted examples **do not keep blank runs**: multiple blanks are collapsed or expanded,
so absolute positions in the data-record examples are off by ±1-3 columns. What was verified:

| Check | Result |
|---|---|
| Ruler lines `H26 5678901234…` [1.0 p.28, p.31, p.34] [2.1 p.28, p.31, p.33] | exactly 80 columns. The digit at col N is N mod 10, so records are 80 columns |
| 2.1 H14 example [2.1 p.27] (80 cols) | `-179.466` 33-40, `-207.757` 41-48, ` -54.446` 49-56, `-2.598` 57-62, ` 0.287` 63-68, ` 0.843` 69-74, `-1.000` 75-80: **matches** 3(F8.3),4(F6.3) |
| 2.1 H220/H231/H232/H241/H242 examples | start at col 33 with widths 12/24/24/12/24: **match** |
| 2.1 R/S cols 1-21 | `R   5646.00 534450.00`: line `   5646.00` = cols 2-11, point ` 534450.00` = 12-21: **match** F10.2 ×2 |
| 2.1 R/S index+code | ` 1G1` / ` 2V6`: index digit immediately followed by the 2-char code, so contiguous 24 / 25-26. Example S index 2 agrees with X srcIndex 2 |
| R/S tail (cols 66-80), both revisions | `106.8113071245` → ` 106.8`+`113`+`071245` (day 113 = 23 Apr 1991, the survey start [1.0 p.27]). 2.1 `60.6019001150` → `  60.6`+`019`+`001150` (day 19, within 19-21 Jan 2006). 2.1 R `85.2 18213250` → day 18, 21:32:50. **Matches** F6.1, I3, 3I2 |
| 1.0 R/S cols 18-28 | `2251G1`: point `225` right-adjusted ending col 25, index `1` col 26, code `G1` 27-28: **contiguous, matches** |
| 1.0 X | `11191LW1117`: record `1` ending col 11, incr col 12, instr col 13, line from col 14. `2251` = point ending 37 + index 38. `1 37191LW1124` = from-ch ending 42, to-ch ending 46, incr col 47, line from 48. `2611` = to-rcv ending 79 + index 80: **all adjacencies match** |
| 2.1 X | `XB79480` fills cols 2-7. `111` = record ending col 15 + incr 16 + instr 17. `542525.002` = point ending 37 + index 38. `3201` = to-channel ending 48 + incr 49. `550500.001` = to-rcv ending 79 + index 80: **all adjacencies match** |
| 2.1 X channel runs | 1-320, 321-640, …, 1601-1920 ⇒ 1920 = H403 channel count |

Not verifiable from the examples: the exact columns of 1.0 static/depth/datum/uphole/water
(`0.0 10` = depth `0.0` and datum `10`, but the blank runs are unreliable). The spec tables are used for these.

## 10. Implementation notes: geometry join

### 10.1 Mapping to `src/parseSEG/model/keys.nim`

`GeometryTable` holds `sources`/`receivers: Table[StationKey, Coordinates]`.
`StationKey = (line, point: float64, index: int16)`, where index 0 in a table entry matches any index.
`lookup` tries `(line, point, index)` first, then `(line, point, 0)`. `Coordinates = (x, y, z)`.

| SPS | → | keys.nim |
|---|---|---|
| S record (line, point, pointIndex) | `addSource(line, point, index, easting, northing, elevation)` | `StationKey` |
| R record (line, point, pointIndex) | `addReceiver(...)` | `StationKey` |
| easting / northing (F9.1 / F10.1) | `x` / `y` | in **grid units (H20)**. Multiply by H201 for metres if required. keys.nim does not track units |
| elevation (F6.1) | `z` | metres relative to H17. Not seismic datum, not elevation minus depth |
| 2.1 line/point F10.2 | `float64` | direct. Matches SEG-D 2.1 THE#1 receiver line/point (integer + fraction) and GH#N source line/point |
| pointIndex I1 1-9 | `int16` | direct |
| X record | not representable | needs a new table (below) |

**What does not fit:**
1. **1.0 alphanumeric line/point** (`91LW1124`, `N061.014`, points `su`/`SA`). `StationKey` is numeric. Options: (a) parse with `parseFloat` when the trimmed field is numeric; (b) use H31 sub-fields (`LINE NUMBER(9:8)`) to pull out a numeric part; (c) skip the station with a warning. Keep the raw strings in the SPS model either way (`lineName`, `pointName`), so a writer round-trips them byte-exact.
2. **Index 0 vs 1.** SPS never writes index 0 (default 1). A trace with unknown index (`rcvIndex`/`srcIndex` = 0 from `initTraceKeys`) looks up `(l, p, 0)` twice and **misses** an SPS entry stored with index 1. Proposed: when loading SPS, also add each station under index 0 (first come wins, or the lowest index) so that index-less traces still match. Or teach `lookup` to fall back to index 1.
3. **±0 and float equality.** F10.2 values parse exactly enough (`5646.00` → 5646.0). Hashing uses raw floats, so SEG-D fractional points must be decoded to the same binary value. Round both sides to 2 decimals before building the key (e.g. `round(x*100)/100`).
4. **X record join needs keys `TraceKeys` doesn't have.** The (fieldRecord, channel) → (source station, receiver station) map needs:
   - `TraceKeys.record`, which exists (SEG-D file number / SEG-Y field record).
   - **channel**, which is **missing** from `TraceKeys`. SEG-D: trace header channel number. SEG-Y: bytes 13-16 "trace number within the original field record". This field has to be added.
   - **field tape** and (2.1) **line sequence number H023**: record numbers can repeat across tapes or lines. Key on `(fieldTape, fieldRecord)` when the caller knows the tape, else `fieldRecord` alone, and warn on duplicates.
   Proposed type: `RelationTable = Table[(record: int64, channel: int32), (src, rcv: StationKey, component: uint8)]`, built by expanding each X record with §5.2, then joined through `GeometryTable` for coordinates. This lets SEG-D 2.x files with no source/receiver numbers in the headers get geometry from SPS.
5. **Units and CRS** (H12-H259, H20/H201) have no slot in `GeometryTable`. Keep them on the SPS header model.
6. **Elevation vs depth.** SPS gives the surface `elevation`, `pointDepth` (below surface) and `waterDepth`. `Coordinates.z` gets the surface elevation. A source depth is `pointDepth`, which the caller applies.

### 10.1b Join order (as implemented)

Field record numbers and channel numbers in the data often differ from the X file's: a
recorder numbers its traces its own way (all live channels, not the X file's patch), and a
reshoot or renumbered post-plot moves records. Seen on a 3D land survey: a SEG-D file whose
FFID was another shot's X record, and whose trace numbers matched the X channels for 23 of
1127 traces, while its header stations matched the R/S/X stations exactly. So
`survey/join` matches **by stations**: header stations are never replaced; a missing
receiver comes from the X records of the header's source station, a missing source from the
O gathers of the header's receiver station, and only a trace with no station uses
(record, channel). See the module documentation.

**O records** (receiver domain): not in either SPS revision, but in use (`.ops` files): the X
layout with the source and receiver fields swapped, one gather per receiver station, its
traces numbered across the sources that recorded it. Read with record letter `O`, or `X` in
an `.ops` file; `receiverRelations` builds them from X.

### 10.2 Reader/writer guidance

- Parse each line with a per-revision column table (`[(first, last, fmt)]`). Pad short lines to 80. Lines longer than 80: keep the extra in a `tail` field and warn.
- Store the raw 80-character card alongside the parsed fields, so an untouched record is rewritten byte-exact.
- Writer: format fields per §4.1/§5.1. Emit CR LF (spec). Optionally emit LF only. Overflow (a value too wide for its field) is an error, never a silent truncation.
- Revision conversion 1.0 → 2.1 is possible only when line and point are numeric and fit F10.2, and field record/channels fit. 2.1 → 1.0 requires fieldRecord ≤ 9999, channels ≤ 9999, and water depth that fits 4 columns.

## 11. Open questions

1. Implied decimal in F10.2 without a `.` (§4.1 AMBIGUITY): integer or Fortran-implied? Proposed: integer, with a strict option.
2. Number of records covered by `recordIncrement` (§5.2).
3. Meaning of `channelIncrement` > 1: multi-component grouping vs skipped channels (§5.2).
4. Handling of 1.0 non-numeric line/point names in `StationKey` (§10.1 item 1). Use H31 sub-fields?
5. Index-0 fallback policy in `GeometryTable` (§10.1 item 2).
6. Whether to key X on `fieldTape` and the H023 line sequence number as well as `fieldRecord`.
7. Units: should the SPS loader convert grid coordinates to metres via H201, or leave them in grid units like SEG-Y coordinates?
8. H242 and H256 width conflicts (§3.2). Proposed: as resolved in the AMBIGUITY notes.
9. Non-standard real-world variants (e.g. the later SPS 2.1 extensions some vendors use, CSV-like spacing) are out of scope for this spec. Should the reader be lenient, using token fallback?
