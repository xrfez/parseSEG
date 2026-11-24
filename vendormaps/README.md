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

| `segy-x100-stations.nif` | SEG-Y files whose textual header says the source and receiver line and point numbers are times 100 in the trace headers: bytes 181-196 read as `rec_line`, `rec_point`, `sht_line`, `sht_point`, divided by 100, and the offset (bytes 37-40) read through the coordinate scalar (`coor4`), as the coordinates are (a `(layout)`, no target) | SEG-Y Rev 0 | none |

## Well-known field names

An application reads two field names from a map's trace-level blocks (a trace header block or
a trace header extension); the library only decodes them.

### The sensor serial

A field named `sensorSerial` holds the serial number of the unit that recorded the trace: a
node, a field unit or a digitizer module. Keep it in a trace-level block. A controller or
recorder serial must not use this name. A value that is blank or a declared sentinel is no
serial. The fields of a map may not overlap, so a unit serial has this one name.

### The first sample time

A field named `firstSampleTime` holds a trace's own start time as a 64-bit count of
microseconds, with the unit text "us GPS" or "us UTC".

The header comment of each map gives its source, what it applies to and what it leaves out.
