# Vendor maps

Drop `.nif` vendor maps here (or in a directory listed in `PARSESEG_VENDOR_PATH`) to decode
manufacturer-specific header areas without recompiling. Format and examples:
`docs/design/vendor_maps.md` and the module documentation of `src/parseSEG/vendor/maps.nim`.
No maps ship yet; `tests/vendormaps/example.nif` is the reference example.

A map can find a block by its bytes (`(match (at 1) (bytes ...))` in a target, `(hasBlock ...)`
in the map's `match`), decode a field only under `(when ...)` or in a `(group ...)`, and read
4-bit and 12-bit fields (`(enc unibble)`); see "Blocks found by their bytes", "Conditions" and
"Narrow fields" in `docs/design/vendor_maps.md`.
