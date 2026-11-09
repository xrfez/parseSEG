# parseSEG

A fast Nim library and command line tool for seismic data. It reads, writes, indexes, edits and converts:
- **SEG-Y:** Rev 0, 1, 2.0 and 2.1;
- **SEG-D:** Rev 0 to 3.1, multiplexed or not;
- **SEG-2.**

It reads from disk and from tape. It also joins geometry from SPS and SEG P1 survey files.

- **Any file size.** Files are memory-mapped and indexed with one pass over the headers, using about 24 bytes per trace; the data is never loaded whole. A fixed-length SEG-Y file opens in milliseconds whatever its size: 12 GB and 10 M traces open in about 20 ms.
- **Samples go straight into tensors.** You get Arraymancer `Tensor[float32]` or `Tensor[float64]` arrays shaped `[traces, samples]`. A request can be a range, a list of traces (a gather or a sort order) or a sample window. Several threads can read from one open file, and a multi-threaded prefetcher can read ahead. Decoding runs at up to 20-27 GB/s per thread.
- **Headers by name.** You can read any header field by name, a column of one field across many traces, per-trace geometry keys, gathers, header listings with byte offsets, and the SEG-Y textual header.
- **Safe writes.** Header edits happen in place, and each one is journaled and can be undone. Writers produce files like the input, and conversions report every loss.
- **Diagnostics, not crashes.** Bad file content never raises an exception. It is reported as a diagnostic with a severity, a code, a byte offset and a location.

## Install

parseSEG needs **Nim 2.4 or later** and depends on [Arraymancer](https://github.com/mratsim/Arraymancer).

With [Atlas](https://github.com/nim-lang/atlas):

```sh
atlas use https://github.com/xrfez/parseSEG
```

With Nimble, in your `.nimble` file:

```nim
requires "https://github.com/xrfez/parseSEG >= 0.6.0"
```

Releases are git tags (`v0.6.0`). Then:

```nim
import parseSEG   # the whole public API
```

### Build flags (optional, recommended)

No special flags are required. parseSEG builds with Nim's defaults and runs on any CPU. It is compiled into your program, though, so **your** flags decide how fast it runs. For production builds on x86-64, add these to your project's `config.nims` (or `nim.cfg`):

```nim
switch("define", "release")
switch("passC", "-march=x86-64-v3")   # AVX2: Intel 2013+ / AMD Zen 2017+
# or: switch("passC", "-march=native")  -- only if it runs on the build machine
```

With x86-64-v3, the sample decoders run up to about 2x faster than a baseline build. Big-endian IEEE SEG-Y goes from 11 to 22 GB/s, and SEG-D 8058 from 11 to 23 GB/s. Leave the flag out for CPUs or VMs without AVX2: a v3 build crashes there with an illegal instruction.

The library does not set `-march` itself, because a library's `passC` applies to your whole program and cannot be undone. Threads and ORC, which parseSEG needs, are on by default in Nim 2.

## Usage

The file names below match the small demo files that `nim c -r --path:src tools/demofiles.nim demo` writes into `demo/`. To try the examples, `cd demo` first.

### Open a file and read samples

```nim
import parseSEG

var f = openSeismic("survey.sgy")          # SEG-Y, SEG-D or SEG-2: detected
echo f.kind, ": ", f.len, " traces, up to ", f.maxSamples, " samples"
let s = f.summary                           # one summary type for all three standards
echo "format ", s.formatCode, ", ", s.sampleIntervalUs, " us"

let a = f.readTraces(0..99)                 # Tensor[float32], shape [100, maxSamples]
let b = f.readTraces([5, 3, 9], float64)    # any list of traces, in list order
let w = f.readTraces(0..99, 500..999)       # a window: samples 500-999 only
for d in f.log: echo d                      # problems found while indexing
f.close()                                   # optional: it unmaps itself when it goes out of scope
```

Trace numbers are 0-based positions in the file. Ranges are Nim slices and include both ends.

- **Bad arguments:** a trace out of range or a closed file raises `ValueError`.
- **Bad file content:** it never raises. A trace that cannot be decoded becomes a zero row and an error in the log: pass a `DiagLog` as `readTraces(f, traces, log)`.

### Headers, keys and gathers

```nim
var f = openSeismic("survey.sgy", keys = true)      # keys: per-trace geometry
echo f.traceField(3, "trace.sourceX")             # any field by name -> FieldValue
echo f.fileField("binary.sampleInterval")         # SEG-D: recordField(f, r, "gh1.year")
let offsets = f.traceFieldColumn("trace.offset", 0 ..< f.len)   # seq[float64]
let k = f.traceKeys(3)                            # TraceKeys: lines, points, x/y, offset, time
for g in f.gathers: echo g.kind, " ", g.traces    # shot / receiver / CMP / ...: derived, not assumed
let order = f.sortTraces(["trace.ensembleNumber", "trace.offset"])  # a permutation
let gather = f.readTraces(order[0 ..< 48])
for row in f.traceHeaders(3): echo row.field, " = ", row.value, " @", row.offset
```

`fieldNames(hbSegyTrace)` lists the field names of a header block. The `parseSEG dump` command below shows them for a real file.

### Large files: read ahead, threads, index cache

```nim
var f = openSeismic("survey.sgy", opts = OpenOptions(cache: "survey.sgy.idx"))
if not f.fromCache: f.saveIndex("survey.sgy.idx")    # the next open skips the header walk

var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 256, depth = 4, cols = f.maxSamples,
                               workers = 4)       # decodes on 4 threads, chunks arrive in order
for c in p.chunks:
  discard c.samples      # Tensor [c.count, cols] for traces c.first ..< c.first + c.count
p.close()
```

- **Threads:** `readTraces` and `readTracesInto` may run on many threads over one open file. Give each thread its own tensor, or a slice of a shared one. Everything else on a file is single-threaded.
- **Progress and cancel:** a hook (`Progress`) reports the walk of a variable-length file and can cancel it.
- **Strict open:** a fixed-length SEG-Y file is indexed from its size and checks 64 sampled headers. `OpenOptions(verify: vfFull)` reads every header instead.

### Write results like the input

```nim
var f = openSeismic("survey.sgy")
var w = openSeismicWriter("gained.sgy", like = f)  # same standard, revision, format, file headers
for i in 0 ..< f.len:
  var t = f.readTraces(i..i)
  t.apply_inline(2 * x)
  w.writeTrace(f, i, t, 0)                         # trace i's headers, new samples (row 0)
let log = w.close()                                # writes to a temp file, renames into place
doAssert not log.isFatal
```

### Edit headers in place

Edits are journaled and can be undone:

```nim
var ed = openEditor("survey.sgy")                  # journal: survey.sgy.edits.nif
doAssert ed.setTraceField(5, "trace.sourceX", 1_700_000)
doAssert not ed.setTraceField(5, "trace.numSamples", 10)   # refused; the reason is in ed.log
ed.close()
let undo = rollbackJournal("survey.sgy", "survey.sgy.edits.nif")   # undo everything
doAssert not undo.isFatal
```

### Convert

```nim
let log = convertFile("shot.sgd", "shot.sgy")      # any standard to SEG-Y (lossless format by default)
for d in log: echo d                               # what the target had no place for
discard convertFile("survey.sgy", "survey_rev1.sgy",
  ConvertOptions(revision: SegyRevision(major: 1, minor: 0), format: st5))
discard convertFile("shot.sgd", "shot.sg2", ConvertOptions(target: skSeg2))
```

### Vendor header maps

Vendor-specific header blocks, such as SEG-D extended and external headers and SEG-Y proprietary trace headers, are decoded by maps written in NIF. Your program chooses where the maps come from:

```nim
var reg: VendorRegistry
var log: DiagLog
reg.loadVendorMaps(vendorSearchPath() & @["my/vendormaps", "acme.nif"], log)  # directories or files
# reg.addMap loadVendorMap(staticRead("acme.nif"), "acme.nif")             # or compiled in

let segd = readSegd("shot.sgd", headersOnly = true)
for r in segd.records:
  for blk in reg.decodeVendorAreas(r.record, log): echo blk
```

`vendorSearchPath()` returns two kinds of directory:
- **Built-in:** the repository's `vendormaps/` folder, located from parseSEG's source checkout at compile time. A program you deploy elsewhere should ship its own maps or compile them in with `staticRead`.
- **From the environment:** the directories in `PARSESEG_VENDOR_PATH`. The CLI also searches these.

A map that fails to load is skipped with a warning in `log`. `parseSEG vendormap scaffold` writes a starting map for every area that no map decodes yet.

To join survey geometry, see `readSps`, `SurveyGeometry`, `applySurvey` and `writeGeometry` in the [conversion guide](docs/guide/conversion.md).

## Command line tool

Build it with `nim cli` (output `bin/parseSEG`, targeting x86-64-v3); `nim nimPortable` builds for any x86-64.

```
parseSEG info line.sgy --keys                    # standard, revision, format, traces, gathers
parseSEG dump line.sgy --traces=0..9 --fields=trace.sourceX,trace.groupX
parseSEG dump shot.sgd --traces=3 --all          # every header field, with byte offsets
parseSEG diag shot.sgd --min=warning             # diagnostics (--nif for machine-readable)
parseSEG convert shot.sgd shot.sgy --rev=2.1     # also --to=segd / --to=seg2, SEG-D revisions
parseSEG edit line.sgy t5:trace.sourceX=1200 file:binary.jobId=7      # in place, journaled
parseSEG headers export line.sgy -o h.nif        # edit h.nif, then:
parseSEG headers import line.sgy h.nif -o fixed.sgy
parseSEG journal rollback line.sgy line.sgy.edits.nif
parseSEG keys shot.sgd --sps=line.r01,line.s01,line.x01   # geometry joined from SPS
parseSEG survey-apply shot.sgd --sps=... -o shot_geo.sgd
parseSEG vendormap scaffold shot.sgd -o vendor.nif        # map vendor header blocks
```

`parseSEG help` lists everything. The exit status is 0 on success, 1 when the command reported errors, and 2 for a usage error.

## Documentation

| Read | For |
|---|---|
| [docs/guide/getting-started.md](docs/guide/getting-started.md) | The model: trace numbers, records, channel sets, the index, keys, lifetimes, thread rules |
| [docs/guide/viewer.md](docs/guide/viewer.md) | Interactive use: fast open, progress and cancel, caches, windows, prefetch, header tabs |
| [docs/guide/processing.md](docs/guide/processing.md) | Batch and HPC work: parallel reads, buffer reuse, writing results |
| [docs/guide/editing.md](docs/guide/editing.md) | In-place edits, journals, header patches |
| [docs/guide/conversion.md](docs/guide/conversion.md) | Between standards and revisions, SPS/P1 geometry |
| [docs/guide/diagnostics.md](docs/guide/diagnostics.md) | Severities, codes, NIF logs |
| [docs/api.md](docs/api.md) | The full API reference: every exported name |
| [docs/benchmarks.md](docs/benchmarks.md) | Measured speeds and method |

The test suite compiles and runs every example in the guides.

### For AI coding agents

To use parseSEG well from generated code:

- **Read first:** [docs/api.md](docs/api.md) is the complete public surface, kept in sync by a test, and its "Conventions" section is short. Copy patterns from the [guide](docs/guide/README.md) examples: they are tested programs.
- **Import:** `import parseSEG` gives the whole public API. Do not import `parseSEG/private/*`.
- **Errors:**
  - File problems go to a `DiagLog` (`f.log`, a read's `log`, the result of `convertFile`); check `log.isFatal` or `log.hasErrors`.
  - Bad arguments raise `ValueError`.
  - Lookups: `traceField` raises when the field can't be read, while `findTraceField` returns an `Option`.
- **Speed:**
  - Open with `keys = true` only when you need geometry or gathers.
  - Read in large chunks into reused tensors (`readTracesInto`).
  - Use `newPrefetcher(..., workers = N)` for streaming, and `traceFieldColumn` rather than looping over `traceField`.
- **Ownership:** a `SeismicFile`, `Prefetcher`, `SeismicWriter` or `HeaderEditor` can't be copied, only moved (`move f`). Values returned by reads are owned copies and stay valid after `close`.

## Development

```sh
atlas rep atlas.lock   # fetch the pinned dependencies into deps/
nim test               # the test suite (nim testRelease: release and danger builds; nim asan: ASan/LSan)
nim bench              # benchmarks (docs/benchmarks.md)
nim docs               # API docs into htmldocs/
```

- **Sample files:** the real-world sample files are not distributed. Tests that need them are skipped when `SEG Spec/exampleFiles/` is absent, and everything else, including the guide examples and CI, runs on files that `tools/demofiles.nim` generates.
- **Layout:**
  - `src/parseSEG.nim` is the umbrella module;
  - `src/parseSEG/` holds the modules, by area: `common`, `io`, `segy`, `segd`, `seg2`, `model`, `convert`, `survey` and `vendor`, plus `private` for internals;
  - `vendormaps/` holds the built-in vendor header maps.

## License

[MIT](LICENSE) © Joshua Fenner
