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
`textContains` (a SEG-Y textual header substring, e.g. "INOVA"), and `blockType`. If several
maps match, the most specific one wins. Ties raise a diagnostic.

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
  `VendorBlock(mapName, name, fields: seq[(name, VendorValue)])`, and writers re-emit the raw bytes.
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
- NIF I/O uses `nifbuilder`/`nifreader` from the Nim toolchain (`$nim/dist/nimony/src/lib`),
  via `--path:"$nim/dist/nimony/src/lib"` in `config.nims`. There's no extra package. API
  notes (verified on Nim 2.4): `extract(move b)` to take the builder's string;
  `openFromBuffer(s, "")`; use `next(r, tok)` (the one-arg `next` is deprecated).
- The map loader compiles each map once into a flat field table (offset, length, decoder
  kind). Decoding is then a tight loop with no allocation per field, so it's cheap enough
  for the viewer.
