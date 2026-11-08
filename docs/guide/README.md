# parseSEG usage guides

Task-oriented guides to the public API, for developers who know seismic data but not this
codebase. They are written with two kinds of users in mind: the developer of a seismic
**viewer** (random access, prefetch, headers, patches, never blocking the UI) and the
developer of a **signal-processing** library (whole files into tensors, threads, writing
results). Both may work from Nim, C or Python.

`docs/api.md` stays the reference (every public name, one line each); these pages show how
the pieces fit together. Every code example on these pages is compiled and run by
`tests/tdocs.nim` against the sample files in `SEG Spec/exampleFiles/`, so the examples
match the code.

## Which page to read

| You want to | Read |
|---|---|
| Understand the model: index, trace numbers, records, channel sets, keys, gathers, lifetimes, threads | [getting-started.md](getting-started.md) (start here) |
| Build a viewer: overview, random access, gathers, prefetch, header tab, patches | [viewer.md](viewer.md) |
| Process data: stream files into tensors, threads, write results | [processing.md](processing.md) |
| Change headers: in-place edits, journal and undo, header documents, patches | [editing.md](editing.md) |
| Convert SEG-Y / SEG-D / SEG-2, join SPS or P1 geometry, write it back | [conversion.md](conversion.md) |
| Use the library from C or C++ | [c.md](c.md) |
| Use the library from Python (numpy optional) | [python.md](python.md) |
| Understand and act on diagnostics and errors | [diagnostics.md](diagnostics.md) |

C and Python users should still skim [getting-started.md](getting-started.md): the
concepts are the same in every language, and only the calling conventions differ.

## Related documents

- `docs/api.md`: the Nim API reference; `include/parseseg.h`: the C reference;
  `help(parseseg)`: the Python reference (all three come from the same doc comments).
- `docs/design/c_abi.md`, `docs/design/python.md`: the rules of the C and Python
  boundaries.
- `docs/design/vendor_maps.md`: decoding vendor-specific header blocks.
- `docs/spec/`: distilled notes on the SEG standards.
- `README.md`: build tasks and the command line tool.
