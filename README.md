# parseSEG

Read, write, index, edit and convert SEG-Y (Rev 0, 1, 2.0, 2.1) and SEG-D (Rev 0 and 1 multiplexed
or demultiplexed, 2.0, 2.1, 3.0, 3.1) seismic data, on disk and tape, for viewers and HPC processing, read,
write, index and convert SEG-2, and the SPS and SEG P1 survey files that give traces their geometry. Files of any size are
memory-mapped and indexed, never loaded whole. Problems are reported as diagnostics instead of
stopping a read.

| Use it from | How | Docs |
|---|---|---|
| Nim | `import parseSEG` | [`docs/guide/`](docs/guide/README.md), `docs/api.md` |
| The shell | `nim cli`, then `bin/parseSEG help` | below |

New here? Start with the usage guides in [`docs/guide/`](docs/guide/README.md): getting
started, recipes for viewers and for signal processing, editing, conversion and
diagnostics, each with examples that the test suite compiles and runs.

## Command line

```
parseSEG info line.sgy --keys                  # standard, revision, format, traces, units, gathers
parseSEG dump line.sgy --traces=0..9 --fields=trace.sourceX,trace.groupX
parseSEG dump shot.sgd --traces=3 --all --records=0 --file  # every header, with offsets
parseSEG diag shot.sgd --min=warning           # the diagnostics (--nif: as NIF)
parseSEG convert shot.sgd shot.sgy --rev=2.1   # SEG-D or SEG-Y to SEG-Y
parseSEG convert old.sgd new.sgd --rev=3.0     # SEG-D revisions
parseSEG convert shot.sgd shot.sg2             # any standard to SEG-2 (--to=seg2)
parseSEG convert shot.sg2 shot.sgd --to=segd   # SEG-2 to SEG-D (or SEG-Y)
parseSEG edit line.sgy t5:trace.sourceX=1200 file:binary.jobId=7    # in place, journaled
parseSEG headers export line.sgy -o h.nif      # edit h.nif, then:
parseSEG headers import line.sgy h.nif -o fixed.sgy                # only changed fields
parseSEG journal rollback line.sgy line.sgy.edits.nif
parseSEG vendormap scaffold shot.sgd -o vendor.nif                 # skeleton vendor map
parseSEG vendormap apply shot.sgd --map=vendor.nif
parseSEG survey line.s01                       # an SPS or SEG P1 file: summary, diagnostics
parseSEG survey line.s01 -o line10.s01 --rev=1.0                   # SPS revisions
parseSEG keys shot.sgd --sps=line.r01,line.s01,line.x01            # geometry joined to traces
parseSEG survey-apply shot.sgd --sps=line.r01,line.s01,line.x01    # what writing it would change
parseSEG survey-apply shot.sgd --sps=... -o shot_geo.sgd           # ... or --in-place (journaled)
```

Exit status: 0 success, 1 the command reported errors, 2 a usage error.

## Directory Layout

- `src/parseSEG.nim`: the public API (umbrella module); `src/parseSEG/`: the library, by
  area (`common`, `io`, `segy`, `segd`, `seg2`, `model`, `vendor`, `survey`), plus `cli.nim`.
- `tests/`: `nim test` runs every `tests/t*.nim` (the CLI and the guides' examples included).
- `bench/`: the `nim bench` suite (`docs/benchmarks.md`).
- `docs/`: usage guides (`guide/`), `api.md`, design notes (`design/`), distilled spec notes
  (`spec/`).
- `vendormaps/`: built-in vendor maps (NIF), searched with `PARSESEG_VENDOR_PATH`.
- `tools/`: zig wrappers, Python oracles for the samples (test tooling only).
- `bin/`: build outputs.
- `SEG Spec/`: the standards and sample files.
- `.github/workflows/`: GitHub Actions CI pipeline.

## Build Tasks

`nim cli` builds the command line tool (`bin/parseSEG`). Six more build modes of it are
defined in `config.nims`, also output to `bin/parseSEG`:

| Task | Toolchain | Profile Description | Key Flags |
|---|---|---|---|
| `nim nimRelease` | GCC/Default | Native Host Optimized | `-d:release -d:danger --opt:speed -march=native` |
| `nim nimPortable` | GCC/Default | Generic Portable Size | `-d:release --opt:size -mtune=generic -s` |
| `nim nimDebug` | GCC/Default | Full Debug & Diagnostics | `--debuginfo:on --assertions:on --stackTrace:on` |
| `nim zigRelease` | Zig CC | Native Host Optimized | `-d:release -d:danger --opt:speed -O3 -march=native` |
| `nim zigPortable` | Zig CC | Generic Portable Size | `-d:release --opt:size -Oz -mcpu=baseline -s` |
| `nim zigDebug` | Zig CC | Full Debug & Diagnostics | `--debuginfo:on` |

Release builds get a fresh `nimcache/release-<task>` and `--ic:off`; `PARSESEG_IC=1` turns on
Nim 2.4's experimental incremental compilation for `nim test`, `nimDebug` and `zigDebug`.

## Development Commands

- Run test suite: `nim test`
- Run the benchmarks: `nim bench`
- Format codebase: `nim fmt`
- Generate documentation: `nim docs`

## Acknowledgements & Attributions

- **[nimlangserver](https://github.com/nim-lang/langserver)**: Official Nim Language Server with MCP support.
- **[planetis-m/skills](https://github.com/planetis-m/skills)**: Curated agent skill repository for Nim development by [planetis-m](https://github.com/planetis-m).
- **[setup-nim-action](https://github.com/jiro4989/setup-nim-action)**: Nim GitHub Actions runner by [jiro4989](https://github.com/jiro4989).
