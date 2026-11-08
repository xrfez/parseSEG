# parseSEG

Read, write, index, edit and convert SEG-Y (Rev 0, 1, 2.0, 2.1) and SEG-D (Rev 0 and 1 multiplexed
or demultiplexed, 2.0, 2.1, 3.0, 3.1) seismic data, on disk and tape, for viewers and HPC processing, read and
index SEG-2, and the SPS and SEG P1 survey files that give traces their geometry. Files of any size are
memory-mapped and indexed, never loaded whole. Problems are reported as diagnostics instead of
stopping a read.

| Use it from | How | Docs |
|---|---|---|
| Nim | `import parseSEG` | `docs/api.md` |
| The shell | `nim cli`, then `bin/parseSEG help` | below |
| C, C++, any FFI | `nim lib` → `libparseseg.so` + `include/parseseg.h` | `docs/design/c_abi.md` |
| Python | `nim pylib` → `import parseseg` (zero-copy numpy) | `docs/design/python.md` |

## Command line

```
parseSEG info line.sgy --keys                  # standard, revision, format, traces, gathers
parseSEG dump line.sgy --traces=0..9 --fields=trace.sourceX,trace.groupX
parseSEG diag shot.sgd --min=warning           # the diagnostics (--nif: as NIF)
parseSEG convert shot.sgd shot.sgy --rev=2.1   # SEG-D or SEG-Y to SEG-Y
parseSEG convert old.sgd new.sgd --rev=3.0     # SEG-D revisions
parseSEG edit line.sgy t5:trace.sourceX=1200 file:binary.jobId=7    # in place, journaled
parseSEG headers export line.sgy -o h.nif      # edit h.nif, then:
parseSEG headers import line.sgy h.nif -o fixed.sgy                # only changed fields
parseSEG journal rollback line.sgy line.sgy.edits.nif
parseSEG vendormap scaffold shot.sgd -o vendor.nif                 # skeleton vendor map
parseSEG vendormap apply shot.sgd --map=vendor.nif
parseSEG survey line.s01                       # an SPS or SEG P1 file: summary, diagnostics
parseSEG survey line.s01 -o line10.s01 --rev=1.0                   # SPS revisions
parseSEG keys shot.sgd --sps=line.r01,line.s01,line.x01            # geometry joined to traces
```

Exit status: 0 success, 1 the command reported errors, 2 a usage error.

## Directory Layout

- `src/parseSEG.nim`: the public API (umbrella module); `src/parseSEG/`: the library, by
  area (`common`, `io`, `segy`, `segd`, `model`, `vendor`, `survey`, `abi`), plus `cli.nim`
  and `bindings.nim` (the shared library). Every C and Python function comes from a
  `{.segApi.}` core proc (or one of the few adapters in `abi/api.nim`); the generator
  (`abi/segapi.nim`) writes the C exports, the header and the Python module, and
  `abi/runtime.nim` holds what the generated exports call at run time.
- `include/parseseg.h`, `python/parseseg/__init__.py`: the generated C header and Python
  (ctypes) module, rewritten by `nim lib` and committed.
- `tests/`: `nim test` runs every `tests/t*.nim` (C ABI, Python module, CLI and build targets
  included).
- `docs/`: `api.md`, design notes (`design/`), distilled spec notes (`spec/`).
- `vendormaps/`: built-in vendor maps (NIF), searched with `PARSESEG_VENDOR_PATH`.
- `tools/`: zig wrappers, macOS link stubs, Python oracles for the samples.
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

## Library Targets (C ABI, Python, C sources)

Every embeddable artifact has a task in `config.nims` (all use `--mm:atomicArc --threads:on
-d:useMalloc -d:release`; Windows adds `--tlsEmulation:off`). `tests/ttargets.nim` builds them
all and runs the C ABI test against them. Release builds (these and the CLI builds) get a
fresh `nimcache/release-<task>` and `--ic:off`; `PARSESEG_IC=1` turns on Nim 2.4's
experimental incremental compilation for `nim test`, `nimDebug` and `zigDebug`.

| Task | Output | Notes |
|---|---|---|
| `nim lib` | `bin/libparseseg.so` / `parseseg.dll` / `libparseseg.dylib` | C ABI for this host; header `include/parseseg.h` (`docs/design/c_abi.md`) |
| `nim staticlib` | `bin/libparseseg.a` (also on Windows: a MinGW ar archive) | Link with `-lpthread -lm -ldl` (Linux); call `seg_init()` first |
| `nim pylib` | `bin/python/parseseg/` (the generated module + the C ABI library) | Python package, `import parseseg` with `bin/python` on `sys.path` (`docs/design/python.md`) |
| `nim libLinux` | `bin/linux-x64/`, `bin/linux-arm64/` | zig cross-build (glibc 2.28) |
| `nim libWindows` | `bin/windows-x64/parseseg.dll` + `parseseg.dll.lib` | zig cross-build (MinGW ABI, UCRT) |
| `nim libMacos` | `bin/macos-arm64/`, `bin/macos-x64/` `libparseseg.dylib` | zig cross-build; links `tools/macos-stubs` in place of the SDK's Security.framework |
| `nim csources` | `bin/csources/<triple>/` | Generated C + `nimbase.h` + header + Makefile + CMakeLists.txt, one bundle per triple (the C is target-specific); builds with GCC or Clang alone |

The zig Linux builds need glibc 2.17 or later. The host builds (`nim lib`) need the glibc they were
built against. macOS builds load on macOS 11 (arm64) and 10.15 (x64) or later.

## Development Commands

- Run test suite: `nim test`
- Format codebase: `nim fmt`
- Generate documentation: `nim docs`

## Acknowledgements & Attributions

- **[nimlangserver](https://github.com/nim-lang/langserver)**: Official Nim Language Server with MCP support.
- **[planetis-m/skills](https://github.com/planetis-m/skills)**: Curated agent skill repository for Nim development by [planetis-m](https://github.com/planetis-m).
- **[setup-nim-action](https://github.com/jiro4989/setup-nim-action)**: Nim GitHub Actions runner by [jiro4989](https://github.com/jiro4989).
