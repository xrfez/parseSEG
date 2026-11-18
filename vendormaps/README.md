# Vendor maps

Drop `.nif` vendor maps here (or in a directory listed in `PARSESEG_VENDOR_PATH`) to decode
manufacturer-specific header areas without recompiling. Format and examples:
`docs/design/vendor_maps.md` and the module documentation of `src/parseSEG/vendor/maps.nim`.
`tests/vendormaps/example.nif` is the reference example.

A map can find a block by its bytes (`(match (at 1) (bytes ...))` in a target, `(hasBlock ...)`
in the map's `match`), decode a field only under `(when ...)` or in a `(group ...)`, and read
4-bit and 12-bit fields (`(enc unibble)`); see "Blocks found by their bytes", "Conditions" and
"Narrow fields" in `docs/design/vendor_maps.md`.

## Shipped maps

| File | Reads | Revision | Manufacturer code |
|---|---|---|---|
| `mfr09-rev2.nif` | Geospace GeoRes System (GeoRes Imagine and XTC) files that carry the Acquisition Detail extended header module: the extended header modules and trace header extensions #2 and #3 | SEG-D Rev 2.0 | 9 |
| `mfr50-rev3.nif` | INOVA files: trace header extension block 0xB0 (device code and device serial number), inferred from one third-party compliance report, not the vendor's own document | SEG-D Rev 3.0 | 50 |

The header comment of each map gives its source, what it applies to and what it leaves out.
