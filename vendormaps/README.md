# Vendor maps

Drop `.nif` vendor maps here (or in a directory listed in `PARSESEG_VENDOR_PATH`) to decode
manufacturer-specific header areas without recompiling. Format and examples:
`docs/design/vendor_maps.md` and the module documentation of `src/parseSEG/vendor/maps.nim`.
No maps ship yet; `tests/vendormaps/example.nif` is the reference example.
