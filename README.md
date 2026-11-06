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

## Development Commands

- Run test suite: `nim test`
- Format codebase: `nim fmt`
- Generate documentation: `nim docs`

## Acknowledgements & Attributions

- **[nimlangserver](https://github.com/nim-lang/langserver)**: Official Nim Language Server with MCP support.
- **[planetis-m/skills](https://github.com/planetis-m/skills)**: Curated agent skill repository for Nim development by [planetis-m](https://github.com/planetis-m).
- **[setup-nim-action](https://github.com/jiro4989/setup-nim-action)**: Nim GitHub Actions runner by [jiro4989](https://github.com/jiro4989).
