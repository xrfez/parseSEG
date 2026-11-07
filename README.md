# parsesegd

Nim project configured with standard compilation tasks, MCP support, and automated CI workflows.

## Directory Layout

- `src/`: Source code modules.
- `tests/`: Test suites.
- `tools/`: Build helper wrappers (`tools/zigcc` for Zig CC invocations).
- `bin/`: Compiled binary target directory.
- `.mcp/`: MCP server configuration.
- `.agents/skills/`: Local agent skill definitions.
- `.github/workflows/`: GitHub Actions CI pipeline.

## Build Tasks

Six optimized build modes are defined in `config.nims` and output to `./bin/`:

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
all and runs the C ABI test against them.

| Task | Output | Notes |
|---|---|---|
| `nim lib` | `bin/libparseseg.so` / `parseseg.dll` / `libparseseg.dylib` | C ABI for this host; header `include/parseseg.h` (`docs/design/c_abi.md`) |
| `nim staticlib` | `bin/libparseseg.a` (also on Windows: a MinGW ar archive) | Link with `-lpthread -lm -ldl` (Linux); call `seg_init()` first |
| `nim pylib` | `bin/parseseg.so` (`.pyd` on Windows) | Python module, `import parseseg` (`docs/design/python.md`); applies `tools/patches/nimpy-method-kwargs.patch` |
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
