# parseSEG usage guides

Task-oriented guides to the public API, for developers who know seismic data but not this
codebase. They are written with two kinds of users in mind: the developer of a seismic
**viewer** (random access, prefetch, headers, patches, never blocking the UI) and the
developer of a **signal-processing** library (whole files into tensors, threads, writing
results).

`docs/api.md` stays the reference (every public name, one line each); these pages show how
the pieces fit together. Every code example on these pages is compiled and run by
`tests/tdocs.nim` against the sample files in `SEG Spec/exampleFiles/`, so the examples
match the code.

## Which page to read

| You want to | Read |
|---|---|
| Understand the model: index, trace numbers, records, channel sets, keys, gathers, lifetimes, threads | [getting-started.md](getting-started.md) (start here) |
| Open a large file with a progress bar, a cancel button and an index cache | [viewer.md](viewer.md#open-a-file-progress-cancel-and-an-index-cache) |
| Navigate a file: overview, gathers, channel sets, multi-component stations | [viewer.md](viewer.md#the-navigation-tree) |
| Read what is on screen: ranges, selections, reused buffers, sample windows (deep zoom) | [viewer.md](viewer.md#read-what-is-on-screen) |
| Show sorted views (`sortTraces`, `sortOrder`) | [viewer.md](viewer.md#sorted-views) |
| Read header columns and keys on demand (`traceFieldColumn`, `traceKeys(traces)`) | [viewer.md](viewer.md#header-columns-and-keys-on-demand) |
| Read ahead on a worker thread, and recycle its buffers (`nextInto`, `recycle`) | [viewer.md](viewer.md#read-ahead-without-blocking-the-ui) |
| Show a header tab, a hex pane and the SEG-Y textual header (`textHeader`) | [viewer.md](viewer.md#the-header-tab-and-the-textual-header) |
| Show geometry, time, inline and crossline | [viewer.md](viewer.md#geometry-time-and-annotation) |
| Process data: stream files into tensors, threads, write results (`SeismicWriter`) | [processing.md](processing.md) |
| Convert many files with progress and cancel | [processing.md](processing.md#batch-conversions-with-progress-and-cancel) |
| Change headers: in-place edits, an already open file (`openEditor(f)`, `release`), journal and undo, header documents, patches | [editing.md](editing.md) |
| Convert SEG-Y / SEG-D / SEG-2, join SPS or P1 geometry, write it back | [conversion.md](conversion.md) |
| Understand and act on diagnostics and errors (cancelled operations included) | [diagnostics.md](diagnostics.md) |

## Related documents

- `docs/api.md`: the API reference; `nim docs`: the generated HTML from the doc comments.
- `docs/design/vendor_maps.md`: decoding vendor-specific header blocks.
- `docs/spec/`: distilled notes on the SEG standards.
- `README.md`: build tasks and the command line tool.
