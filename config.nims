# Strict build configuration and task orchestrator for parseSEGD

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

task nimRelease, "Build native host-optimized binary (aggressive speed, march=native)":
  ## Compiles high-performance binary optimized strictly for the current host CPU.
  selfExec "c -d:release -d:danger --opt:speed --passC:\"-march=native -mtune=native\" src/parseSEGD.nim"

task nimPortable, "Build portable binary for generic CPUs (stripped, baseline instructions)":
  ## Compiles stripped, portable binary targeting generic CPU baseline compatibility.
  selfExec "c -d:release --opt:size --passC:\"-mtune=generic\" --passL:\"-s\" src/parseSEGD.nim"

task nimDebug, "Build debug binary with stack traces and assertions":
  ## Compiles debug binary with full assertions, line tracing, and symbols.
  selfExec "c --debuginfo:on --assertions:on --lineTrace:on --stackTrace:on src/parseSEGD.nim"

task zigRelease, "Build native host-optimized binary using Zig CC (O3, march=native)":
  ## Compiles native binary using Zig toolchain with -O3 optimization for host CPU.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" -d:release -d:danger --opt:speed --passC:\"-O3 -march=native\" src/parseSEGD.nim"

task zigPortable, "Build portable binary for generic CPUs using Zig CC (stripped, baseline instructions)":
  ## Compiles stripped binary using Zig toolchain targeting generic baseline CPUs and size reduction.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" -d:release --opt:size --passC:\"-Oz\" --passC:\"-mcpu=baseline\" --passL:\"-s\" src/parseSEGD.nim"

task zigDebug, "Build debug binary using Zig CC with debug symbols":
  ## Compiles debug binary using Zig toolchain preserving debug symbols.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe & "\" --debuginfo:on src/parseSEGD.nim"

const libName =
  when defined(windows): "parseseg.dll"
  elif defined(macosx): "libparseseg.dylib"
  else: "libparseseg.so"

task lib, "Build the C ABI shared library (bin/libparseseg.so, see include/parseseg.h)":
  ## atomicArc: handles may be released from any host thread; useMalloc: host
  ## threads need no allocator setup.
  selfExec "c --app:lib --noMain --mm:atomicArc --threads:on -d:useMalloc -d:release -d:segCapi " &
    "--out:bin/" & libName & " src/parseSEGD/capi.nim"

const pyModName = when defined(windows): "parseseg.pyd" else: "parseseg.so"

proc patchNimpy() =
  ## Applies tools/patches/nimpy-method-kwargs.patch to the Atlas checkout
  ## once (nimpy 0.2.1 miscounts a method's arguments when keywords are
  ## passed); a no-op when it is already applied. Drop it once upstream is fixed.
  const patch = "../../tools/patches/nimpy-method-kwargs.patch"
  if gorgeEx("git -C deps/nimpy apply --reverse --check " & patch).exitCode != 0:
    exec "git -C deps/nimpy apply " & patch

task pylib, "Build the Python module (bin/parseseg.so, `import parseseg`; needs no libpython)":
  ## nimpy loads the CPython API from the importing process, so one build
  ## serves every Python 3 version. atomicArc/useMalloc as for `lib`: objects
  ## may be freed on any Python thread. Windows/MinGW needs tlsEmulation off.
  patchNimpy()
  selfExec "c --app:lib --mm:atomicArc --threads:on -d:useMalloc -d:release -d:segPython " &
    (when defined(windows): "--tlsEmulation:off --passL:-static " else: "") &
    "--out:bin/" & pyModName & " src/parseSEGD/pyapi.nim"

task test, "Run test suite":
  ## Executes unittest suite.
  selfExec "c -r --hints:off tests/tester.nim"

task fmt, "Format codebase via nimpretty":
  ## Formats source and test files in-place.
  exec "nimpretty --indent:2 src/parseSEGD.nim"

task docs, "Generate HTML documentation":
  ## Emits HTML documentation into htmldocs directory.
  selfExec "doc --project --outdir:htmldocs src/parseSEGD.nim"
