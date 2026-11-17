# Vendor maps: declarative NIF plugins for vendor-specific blocks

Goal: support manufacturer-specific header areas **without recompiling**. A vendor map is a
`.nif` file that describes where vendor data lives and how to decode it. Dropping a map into
a search directory is enough to make the library (and the CLI/viewer) decode those blocks.
Programmatic decoders (Nim procs) remain available for layouts that a declarative map can't
express, and both go through the same registry.

## Where vendor data appears (what a map can target)
| Target `kind` | Standard | Identified by |
|---|---|---|
| `extendedHeader` | SEG-D 2.x/3.x | EC × 32 B after the scan type headers. The whole area, or a block index within it |
| `externalHeader` | SEG-D | EX × 32 B. The whole area, or a block index |
| `generalHeader` | SEG-D 2.x | GH#N with N ≥ 3 (when byte 19 = N is not the standard source layout) |
| `block` | SEG-D 3.x | 32 B blocks by **type byte** (byte 32), user range 0xB0-0xFF, in GH or trace header |
| `traceExt` | SEG-D 2.x | trace header extension #k (k ≥ 2), by position |
| `trailer` | SEG-D | general trailer blocks, by description-block type/text |
| `binaryHeaderBytes` | SEG-Y | unassigned binary header ranges (e.g. 3261-3500 in Rev 1) |
| `traceHeaderBytes` | SEG-Y | unassigned trace header bytes (e.g. 181-240 in Rev 1) |
| `traceHeaderBlock` | SEG-Y 2.x | proprietary extra 240 B trace header blocks, by their 8-char name (bytes 233-240) |
| `stanza` | SEG-Y | extended text / trailer stanzas, by `((COMPANY:DATANAME...))` name |

## Matching (when a map applies)
A map applies to a file when every clause in its `match` holds. Possible clauses: `format`
(segd/segy), `rev` range, `manufacturer` code (SEG-D GH1 byte 17), `serial` range,
`textContains` (a SEG-Y textual header substring, e.g. "INOVA"), `hasBlock` (below) and
`blockType`. If several maps match, the most specific one wins. Ties raise a diagnostic.

The specificity is the number of clauses that hold: one for `format`, `rev`, `manufacturer`
and `serial`, one for each `textContains` and one for each `hasBlock`. A map that also
requires a block by its bytes therefore beats one with the same other clauses without it.

**`(hasBlock <area> (match ...) ...)`** requires that some 32-byte block of a record-level
area (`extendedHeader`, `externalHeader` or `generalHeader`: the GH blocks after GH#2) holds
all the given byte runs (the `(match)` of a target, below). It tells two maps of one
manufacturer apart by what the file contains:
```
(match (format segd) (manufacturer 9)
  (hasBlock extendedHeader (match (at 1) (bytes 0x09 0 0 1 1))))
```
It reads only what `vendorContext(record)` holds (`extended`, `external`, `general` of
`VendorContext`); a SEG-Y file has none, so a map with `hasBlock` does not apply to it.
Without the block, the map does not apply and nothing is logged.

## Blocks found by their bytes
Some manufacturers fill the extended header with 32-byte modules that identify themselves
in their first bytes and come in no fixed order. A target then says what the block holds,
not where it is:
```
(target (kind extendedHeader) (name acmeSource)
  (match (at 1) (bytes 0x09 0 0 2))          ; bytes 1-4 of the block
  (field shot (at 6) (enc u32)))
```
- **Spelling.** `(match (at N) (bytes b...))`: one clause names the whole identifying run
  as the spec tables write it (`09 00 00 02`), and `(at)` is 1-based like every offset. A
  per-byte form (`(byteIs 1 9)`) would need one clause per byte and say less. Several
  `(match)` clauses in a target (at most 16) must all hold, which covers runs that are not
  adjacent. A run holds at most 64 bytes, each 0..255.
- **Meaning.** With `match` and no position, the target applies to **every** block of the
  area whose bytes equal the run, wherever it sits. Two such blocks are two decoded
  `VendorBlock`s, each with its block number in `blockNumber`. A file with no such block
  decodes nothing for the target and logs nothing. `(blockIndex k)` with `match` means: block
  `k`, only if it matches. A target with `match` is never tried on the whole area
  (`blockIndex` -1) of the extended or external header.
- **Block size.** Content is matched on the bytes handed to the decoder: 32-byte blocks for
  the SEG-D extended and external headers (a final part of fewer than 32 bytes is not a block),
  the 32-byte GH blocks, and each trace header extension (`traceExt`, with or without
  `(extension k)`). A run that reaches past the block's end does not match; `vendormap check`
  notes it. The other kinds (`block`, `trailer`, SEG-Y) get the area as it is offered.
- Existing maps are unaffected: a target without `match` behaves as before.

## Conditions: `(when)` and `(group)`
A field is decoded only when its conditions hold. A field whose condition does not hold is
absent, like one holding its sentinel, and nothing is logged. Several `(when)` on a field
all have to hold.
```
(field orientation (at 26) (enc u8) (when (field layout) (is 2)))
(group (when (byte 30) (in 1 2))              ; one condition for several fields
  (field a (at 2) (enc u8))
  (field b (at 3) (enc u16)))
```
- **Source:** `(field name)` is the raw value of an integer or `bcd` field defined **earlier
  in the same target** (read again from the block, even where that field is absent by its
  sentinel; a name that is not defined earlier is a map error with its line). `(byte N)`,
  `(highNibble N)`, `(lowNibble N)` read a raw byte of the block (1-based); one past the end
  of the block makes the condition false.
- **Test:** `(is v)`, `(in v...)` (at most 256 values) or `(range lo hi)` (both included).
- **From another target of the same record:** `(record <area> (match ...) (byte N))`
  (also `highNibble`/`lowNibble`) reads that byte in the **first** block of the record's
  extended header, external header or general header blocks that holds the `(match)` runs.
  The module is looked up in `VendorContext`, so a trace extension layout can depend on a
  version byte of an extended-header module. With no such block the condition is false.
  `decodeVendorAreas` fills the context blocks only when a loaded map uses them
  (`VendorMap.usesRecordBlocks`).
- `(when)` is not supported inside `(repeat)`.

## Narrow fields
`(enc unibble)` and `(enc inibble)` read an unsigned or signed binary number of `(len N n)`
nibbles (1..16), starting at the high or the `(nibble low)` nibble of the byte at `(at)`:
```
(field flags  (at 12) (nibble high) (len 1n) (enc unibble))   ; high 4 bits
(field mode   (at 12) (nibble low)  (len 1n) (enc unibble))   ; low 4 bits
(field digit  (at 13) (nibble low)  (len 1n) (enc bcd))       ; one BCD digit
(field wide   (at 14) (len 3n) (enc unibble))                 ; 12 bits: nibbles 1-3 of bytes 14-15
(field wide2  (at 14) (nibble low) (len 3n) (enc unibble))    ; 12 bits: nibbles 2-4
```
Nibbles are read most significant first; the byte order does not apply. `sentinel`,
`scale`, `enum` and `bits` work as for other integers. A field that does not fit the block
is reported as for any field.

## File format sketch (NIF, `.nif27` header)
```
(.nif27)
(vendormap "inova-g3i-traceblocks" (version 1)
  (match (format segd) (rev 3.0 3.1) (manufacturer 50))
  (doc "INOVA user trace-header blocks")
  (target (kind block) (type 0xB0) (where traceHeader) (name inovaStatus)
    (field gpsLat   (at 1)  (enc f64) (unit "deg"))
    (field flags    (at 9)  (enc u8)
      (bits (0 clipped) (1 dead) (2 reversed)))
    (field unitSn   (at 10) (len 4n) (enc bcd))          ; nibble-addressed, like the spec notes
    (field mode     (at 13) (enc u8)
      (enum (0 "normal") (1 "test") (2 "calibration")))
    (field tilt     (at 14) (enc i16) (scale 0.01) (unit "deg"))
    (field reserved (at 16) (len 16) (enc raw)))
  (target (kind extendedHeader) (blockIndex 1) (name inovaRecordInfo)
    (field crewName (at 1) (len 16) (enc ascii) (trim right))
    (repeat (count (ref nChannels)) (stride 8) (at 17)       ; repeating groups
      (field chanId (at 0) (enc u32)) (field gain (at 4) (enc f32)))))
```
- Encodings reuse the spec-note vocabulary (`docs/spec/CONVENTIONS.md`): `u8..u64`, `i8..i64`,
  `u24`/`i24`, `bcd`, `f32`, `f64`, `ibm32`, `ascii`, `ebcdic`, `bits`, `fixedpt (i24.u16 ...)`,
  `raw`.
- Optional per field: `byteOrder` (default: the file's), `scale`/`offset`, `unit`, `enum`,
  `bits`, `sentinel` (e.g. FFFFFF = "use extended field"), and `when` (a conditional on
  another field).
- Offsets are 1-based within the target, which matches how the spec tables number bytes.

## Runtime behaviour
- **Search path:** the built-in `vendormaps/` directory in the repo, then the
  `PARSESEG_VENDOR_PATH` directories (colon-separated), then paths passed to `loadVendorMaps()`.
- **Lossless:** raw bytes are always kept. Decoded vendor fields appear beside them as
  `VendorBlock(mapName, name, fields: seq[VendorField])` (each a `name` and a `VendorValue`),
  and writers re-emit the raw bytes.
- **Never fatal:** a malformed map, an out-of-range field or an unmatched block all become
  diagnostics (NIF log) and the raw block is kept.
- **Precedence:** a code decoder registered via `registerVendorDecoder` beats a declarative map
  for the same (manufacturer, target).

## Tooling (CLI subcommands)
| Command | Purpose |
|---|---|
| `parseSEG vendormap check <map.nif>` | validate syntax, overlaps/gaps, encodings, and target sizes |
| `parseSEG vendormap scaffold <data-file> [-o map.nif]` | find every unmapped vendor area in a file and emit a **skeleton map**: targets, sizes, byte ranges that are constant across traces vs varying, and ASCII-looking runs. This is the starting point for integrating a new vendor's layout |
| `parseSEG vendormap apply <data-file> [--map m.nif]` | decode and print the vendor fields (NIF output), for checking a map against real data |
| `parseSEG vendormap list` | the maps found on the search path and which ones match a given file |

## Implementation notes
- NIF I/O needs no package and nothing from the Nim toolchain. Maps are untrusted input,
  so `vendor/maps` reads them with a small tokenizer of its own for the NIF subset they use
  (iterative, bounded nesting, sizes and numbers, `ValueError` for anything else). The
  scaffold writes NIF with `common/niftext`. The toolchain's NIF library is not used: its
  reader can end the process on a damaged document.
- The map loader compiles each map once into a flat field table (offset, length, decoder
  kind). Decoding is then a tight loop with no allocation per field, so it's cheap enough
  for the viewer.
