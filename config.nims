# Strict build configuration and task orchestrator for parseSEG

switch("outdir", "bin")
# NIF reader/builder ship with the Nim toolchain (used for the diagnostics log
# and vendor maps); no extra package is needed.
switch("path", "$nim/dist/nimony/src/lib")

let zigccExe =
  if findExe("zigcc").len > 0:
    "zigcc"
  elif defined(windows):
    "tools/zigcc.cmd"
  else:
    "./tools/zigcc"

const cliMain = "src/parseSEG/cli.nim" ## The `parseSEG` command line tool (Phase 7).

# ---------------------------------------------------------- build caches --
# Release builds never reuse a cache: each gets its own nimcache under
# nimcache/, wiped first, and incremental compilation off. Development builds
# (test, nimDebug, zigDebug) use the default cache, and Nim 2.4's incremental
# compilation when PARSESEG_IC=1 (experimental: it needs working `nifler` and
# `nifmake` next to the compiler).

proc release(name: string): string =
  ## Flags for a release build: a fresh nimcache/<name>, IC off.
  let dir = "nimcache/release-" & name
  rmDir dir
  " --ic:off --nimcache:" & dir & " "

proc dev(): string =
  ## Flags for a development build: IC when PARSESEG_IC=1.
  if getEnv("PARSESEG_IC") == "1": " --ic:on " else: " "

# The CPU baseline of the default builds (owner, 15.3): x86-64-v3 (AVX2,
# Haswell 2013 / Zen 1 2017 and later) on x86-64 hosts, where it decodes
# big-endian IEEE and SEG-D 8058 2x faster than baseline SSE2. Other CPUs
# (arm64) keep the compiler's default. `nimPortable`/`zigPortable` are the
# baseline x86-64 (v1, SSE2) builds for older CPUs; the *Release tasks
# target the build host (-march=native).
const
  cpuTarget = when defined(amd64): " --passC:-march=x86-64-v3 " else: " "
  baseTarget = when defined(amd64): " --passC:-march=x86-64 " else: " "

task cli, "Build the parseSEG command line tool (bin/parseSEG, x86-64-v3; `bin/parseSEG help`)":
  selfExec "c -d:release" & cpuTarget & release("cli") & "-o:bin/parseSEG " & cliMain

task nimRelease, "Build native host-optimized binary (aggressive speed, march=native)":
  ## Compiles high-performance binary optimized strictly for the current host CPU.
  selfExec "c -d:release -d:danger --opt:speed --passC:\"-march=native -mtune=native\"" &
    release("nimRelease") & "-o:bin/parseSEG " & cliMain

task nimPortable, "Build portable binary for any x86-64 CPU (stripped, baseline x86-64 v1/SSE2)":
  ## Compiles stripped, portable binary for CPUs without AVX2 (slower decodes).
  selfExec "c -d:release --opt:size --passC:\"-mtune=generic\" --passL:\"-s\"" & baseTarget &
    release("nimPortable") & "-o:bin/parseSEG " & cliMain

task nimDebug, "Build debug binary with stack traces and assertions":
  ## Compiles debug binary with full assertions, line tracing, and symbols.
  selfExec "c --debuginfo:on --assertions:on --lineTrace:on --stackTrace:on" & dev() &
    "-o:bin/parseSEG " & cliMain

task zigRelease, "Build native host-optimized binary using Zig CC (O3, march=native)":
  ## Compiles native binary using Zig toolchain with -O3 optimization for host CPU.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe &
    "\" -d:release -d:danger --opt:speed --passC:\"-O3 -march=native\"" & release("zigRelease") &
    "-o:bin/parseSEG " & cliMain

task zigPortable, "Build portable binary for any CPU of its kind using Zig CC (stripped, baseline x86-64 v1/SSE2)":
  ## Compiles stripped binary using Zig toolchain for baseline CPUs (no AVX2) and size reduction.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe &
    "\" -d:release --opt:size --passC:\"-Oz\" --passC:\"-mcpu=baseline\" --passL:\"-s\"" &
    release("zigPortable") & "-o:bin/parseSEG " & cliMain

task zigDebug, "Build debug binary using Zig CC with debug symbols":
  ## Compiles debug binary using Zig toolchain preserving debug symbols.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe &
    "\" --debuginfo:on" & dev() & "-o:bin/parseSEG " & cliMain

task test, "Run test suite":
  ## Executes unittest suite (PARSESEG_IC=1: incremental compilation).
  selfExec "c -r --hints:off" & dev() & "tests/tester.nim"

task testRelease, "Run the test suite in -d:release and -d:danger builds (as shipped)":
  ## The shipped CLI and the benchmarks are release builds, and the hot
  ## decoders turn their checks off: run every test in both modes too.
  selfExec "c -r --hints:off -d:release" & dev() & "tests/tester.nim"
  selfExec "c -r --hints:off -d:danger" & dev() & "tests/tester.nim"

task asan, "Run the threaded tests under ASan/LSan (any leak or memory error fails)":
  ## The tests whose worker or caller threads decode (15.1: a leak there once
  ## came from exceptions destroyed on worker threads). Needs gcc or clang
  ## with libasan. Each test gets its own nimcache under nimcache/asan.
  for t in ["tprefetch", "tsharedreads", "tcolumns", "tviewerreads", "tdiagnostics"]:
    selfExec "c -r --hints:off -d:useMalloc -d:noSignalHandler --debugger:native " &
      "--passC:-fsanitize=address " &
      "--passL:-fsanitize=address --nimcache:nimcache/asan/" & t & " -o:bin/asan/" & t &
      " tests/" & t & ".nim"

task fmt, "Format codebase via nimpretty":
  ## Formats source and test files in-place.
  exec "nimpretty --indent:2 src/parseSEG.nim"

task docs, "Generate HTML documentation":
  ## Emits HTML documentation into htmldocs directory. A broken link or an
  ## RST style warning fails the build (CI runs it).
  selfExec "doc --project --warningAsError:BrokenLink:on --warningAsError:warnRstStyle:on " &
    "--outdir:htmldocs src/parseSEG.nim"

# ------------------------------------------------------- benchmarks (13.2) --

task bench, "Benchmark suite (bench/, docs/benchmarks.md)":
  ## Builds bench/gen and bench/suite with the nimRelease flags (or the
  ## `nim cli` flags, -d:release for x86-64-v3, with PARSESEG_BENCH_BUILD=release;
  ## baseline x86-64 with PARSESEG_BENCH_BUILD=portable), writes
  ## the synthetic files (PARSESEG_BENCH_SCALE=small, the default, about
  ## 2.5 GB, or full, about 52 GB; into PARSESEG_BENCH_DIR, default
  ## bench/data) and runs the suite (PARSESEG_BENCH_SECTIONS: a space-separated
  ## subset of baseline index decode latency threads prefetch write).
  let flags =
    case getEnv("PARSESEG_BENCH_BUILD")
    of "release": "c -d:release" & cpuTarget
    of "portable": "c -d:release" & baseTarget
    else: "c -d:release -d:danger --opt:speed --passC:\"-march=native -mtune=native\""
  mkDir "bin/bench"
  selfExec flags & release("benchGen") & "-o:bin/bench/gen bench/gen.nim"
  selfExec flags & release("benchSuite") & "-o:bin/bench/suite bench/suite.nim"
  let sections = getEnv("PARSESEG_BENCH_SECTIONS")
  exec "bin/bench/gen"
  exec "bin/bench/suite " & sections
