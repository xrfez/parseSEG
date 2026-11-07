# Strict build configuration and task orchestrator for parseSEG
import std/[compilesettings, strutils]

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

task cli, "Build the parseSEG command line tool (bin/parseSEG; `bin/parseSEG help`)":
  selfExec "c -d:release" & release("cli") & "-o:bin/parseSEG " & cliMain

task nimRelease, "Build native host-optimized binary (aggressive speed, march=native)":
  ## Compiles high-performance binary optimized strictly for the current host CPU.
  selfExec "c -d:release -d:danger --opt:speed --passC:\"-march=native -mtune=native\"" &
    release("nimRelease") & "-o:bin/parseSEG " & cliMain

task nimPortable, "Build portable binary for generic CPUs (stripped, baseline instructions)":
  ## Compiles stripped, portable binary targeting generic CPU baseline compatibility.
  selfExec "c -d:release --opt:size --passC:\"-mtune=generic\" --passL:\"-s\"" &
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

task zigPortable, "Build portable binary for generic CPUs using Zig CC (stripped, baseline instructions)":
  ## Compiles stripped binary using Zig toolchain targeting generic baseline CPUs and size reduction.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe &
    "\" -d:release --opt:size --passC:\"-Oz\" --passC:\"-mcpu=baseline\" --passL:\"-s\"" &
    release("zigPortable") & "-o:bin/parseSEG " & cliMain

task zigDebug, "Build debug binary using Zig CC with debug symbols":
  ## Compiles debug binary using Zig toolchain preserving debug symbols.
  selfExec "c --cc:clang --clang.exe:\"" & zigccExe & "\" --clang.linkerexe:\"" & zigccExe &
    "\" --debuginfo:on" & dev() & "-o:bin/parseSEG " & cliMain

# ------------------------------------------------- library targets (8.9) --
# Every embeddable artifact: the C ABI (shared and static), the Python module,
# and per-target C source bundles. Shared flags:
# - atomicArc: handles may be released from any host thread;
# - useMalloc: host threads need no allocator setup (and ASan/valgrind see
#   every allocation);
# - threads: the prefetcher's worker; tlsEmulation off on Windows, since
#   emulated thread-locals break on threads the host created.
# Outputs go to bin/ (host) or bin/<triple>/ (cross builds through zig).

type Target = tuple[triple, os, cpu, zig: string]

const
  targets: array[5, Target] = [
    ("linux-x64", "linux", "amd64", "x86_64-linux-gnu.2.28"),
    ("linux-arm64", "linux", "arm64", "aarch64-linux-gnu.2.28"),
    ("windows-x64", "windows", "amd64", "x86_64-windows-gnu"),
    # A minimum OS version: zig's default is its newest (macOS 15).
    ("macos-arm64", "macosx", "arm64", "aarch64-macos.11.0"),
    ("macos-x64", "macosx", "amd64", "x86_64-macos.10.15")]
  abiFlags = "--mm:atomicArc --threads:on -d:useMalloc -d:release"
  capiFlags = "--noMain " & abiFlags & " -d:segCapi"
  capiMain = "src/parseSEG/bindings.nim"
    ## Every export is a {.segApi.} proc in src/parseSEG/abi/api.nim; compiling
    ## also writes include/parseseg.h and python/parseseg/__init__.py.

func libFile(os: string): string =
  case os
  of "windows": "parseseg.dll"
  of "macosx": "libparseseg.dylib"
  else: "libparseseg.so"

func staticFile(os: string): string = "libparseseg.a" # an ar archive, also from MinGW

func osFlags(os: string): string =
  if os == "windows": " --tlsEmulation:off" else: ""

func libLinkFlags(os: string): string =
  ## Shared-library link flags:
  ## - Linux: an SONAME, and `-Bsymbolic` so `seg_init` calls this
  ##   library's NimMain even when the host loads another Nim library that
  ##   exports one (ELF would otherwise bind the first);
  ## - macOS: a relocatable install name (two-level namespaces bind locally).
  case os
  of "linux": " --passL:-Wl,-Bsymbolic --passL:-Wl,-soname,libparseseg.so"
  of "macosx": " --passL:-Wl,-install_name,@rpath/libparseseg.dylib"
  else: ""

proc zigOsFlags(os: string): string =
  ## macOS: zig has the headers but no frameworks; a link-time stub stands in
  ## for Security.framework (see tools/macos-stubs).
  if os == "macosx": " --passL:\"-F" & thisDir() & "/tools/macos-stubs\""
  else: ""

const hostOs = when defined(windows): "windows" elif defined(macosx): "macosx" else: "linux"

proc zigFlags(t: Target): string =
  ## Cross-compiles with zig cc for `t` (zig ships every target's libc headers).
  "--cc:clang --clang.exe:" & zigccExe & " --clang.linkerexe:" & zigccExe &
    " --os:" & t.os & " --cpu:" & t.cpu & osFlags(t.os) & zigOsFlags(t.os) &
    " --passC:\"-target " & t.zig & "\" --passL:\"-target " & t.zig & "\"" &
    # No debug info: zig emits it by default, with this machine's paths.
    " --passC:-g0 --passL:-s" & release(t.triple)

proc crossLib(t: Target) =
  rmDir "bin/" & t.triple # no stale files (e.g. an old .pdb) in the artifacts
  mkDir "bin/" & t.triple
  var extra = ""
  if t.os == "windows":
    # An import library, so MSVC and MinGW hosts can link the DLL.
    extra = " --passL:-Wl,--out-implib,bin/" & t.triple & "/parseseg.dll.lib"
  selfExec "c --app:lib " & capiFlags & " " & zigFlags(t) & libLinkFlags(t.os) & extra &
    " --out:bin/" & t.triple &
    "/" & libFile(t.os) & " " & capiMain
  cpFile "include/parseseg.h", "bin/" & t.triple & "/parseseg.h"

proc crossLibs(os: string) =
  for t in targets:
    if t.os == os: crossLib(t)

task lib, "Build the C ABI shared library for this host (bin/libparseseg.so, include/parseseg.h)":
  ## Windows (MinGW): linked statically, so the DLL needs no libgcc/winpthread.
  selfExec "c --app:lib " & capiFlags & osFlags(hostOs) & libLinkFlags(hostOs) &
    (when defined(windows): " --passL:-static" else: "") & release("lib") &
    " --out:bin/" & libFile(hostOs) & " " & capiMain

task libLinux, "Cross-build the C ABI for linux-x64 and linux-arm64 with zig (bin/<triple>/)":
  crossLibs("linux")

task libWindows, "Cross-build the C ABI for windows-x64 with zig (bin/windows-x64/parseseg.dll)":
  crossLibs("windows")

task libMacos, "Cross-build the C ABI for macos-arm64 and macos-x64 with zig (bin/<triple>/)":
  crossLibs("macosx")

task staticlib, "Build the C ABI as a static library for this host (bin/libparseseg.a)":
  ## Link it with -lpthread -lm -ldl (Linux) and call seg_init() first, as with the .so.
  selfExec "c --app:staticlib " & capiFlags & osFlags(hostOs) & release("staticlib") &
    " --out:bin/" & staticFile(hostOs) & " " & capiMain

task pylib, "Build the Python package for this host (bin/python/parseseg; `import parseseg`)":
  ## The package is the generated python/parseseg/__init__.py (ctypes) next to
  ## the C ABI library: one binary serves C and Python. Put bin/python on
  ## sys.path, or copy bin/python/parseseg into site-packages.
  let pkg = "bin/python/parseseg"
  rmDir pkg
  mkDir pkg
  selfExec "c --app:lib " & capiFlags & osFlags(hostOs) & libLinkFlags(hostOs) &
    (when defined(windows): " --passL:-static" else: "") & release("pylib") &
    " --out:" & pkg & "/" & libFile(hostOs) & " " & capiMain
  cpFile "python/parseseg/__init__.py", pkg & "/__init__.py"

func bundleFlags(os: string): tuple[cflags, libs, shared, sharedFlag: string] =
  ## The C flags Nim itself uses for `os`, and how to link a shared library.
  case os
  of "windows":
    ("-mno-ms-bitfields -DWIN32_LEAN_AND_MEAN", "-static", "parseseg.dll",
      "-shared -Wl,--out-implib,libparseseg.dll.a")
  of "macosx":
    ("-pthread", "-lpthread -lm -framework Security", "libparseseg.dylib",
      "-dynamiclib -install_name @rpath/libparseseg.dylib")
  else:
    ("-pthread", "-lpthread -lm -ldl", "libparseseg.so",
      "-shared -Wl,-soname,libparseseg.so -Wl,-Bsymbolic")

proc bundleMakefile(t: Target): string =
  let b = bundleFlags(t.os)
  "# parseseg " & t.triple & ": builds the static and shared library from the generated C\n" &
    "# with GCC or Clang, no Nim needed:  make  |  make CC=clang  |  make CFLAGS=-O2\n" &
    "# (MinGW: make CC=gcc). LDFLAGS adds link options, e.g. -L or -F paths.\n" &
    "CC ?= cc\nAR ?= ar\nCFLAGS ?= -O3\nLDFLAGS ?=\n" &
    "NIMFLAGS := -w -fno-strict-aliasing -fno-ident -fno-math-errno " & b.cflags &
    (if t.os == "windows": "" else: " -fPIC") & " -Isrc\n" &
    "LIBS := " & b.libs & "\n" &
    "OBJS := $(patsubst %.c,%.o,$(wildcard src/*.c))\n\n" &
    "all: " & staticFile(t.os) & " " & b.shared & "\n\n" &
    "%.o: %.c\n\t$(CC) -c $(NIMFLAGS) $(CFLAGS) -o $@ $<\n\n" &
    staticFile(t.os) & ": $(OBJS)\n\t$(AR) rcs $@ $^\n\n" &
    b.shared & ": $(OBJS)\n\t$(CC) " & b.sharedFlag & " -o $@ $^ $(LDFLAGS) $(LIBS)\n\n" &
    "clean:\n\trm -f $(OBJS) " & staticFile(t.os) & " " & b.shared &
    (if t.os == "windows": " libparseseg.dll.a" else: "") & "\n\n" &
    ".PHONY: all clean\n"

proc bundleCmake(t: Target): string =
  let b = bundleFlags(t.os)
  let libs = b.libs.replace("-static", "").strip
  result = "# parseseg " & t.triple & ": the library from the generated C (GCC or Clang).\n" &
    "#   cmake -B build [-DBUILD_SHARED_LIBS=ON] && cmake --build build\n" &
    "cmake_minimum_required(VERSION 3.13)\nproject(parseseg C)\n" &
    "if(MSVC)\n  message(FATAL_ERROR \"the generated C needs GCC or Clang, not MSVC\")\n" &
    "endif()\n" &
    "if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)\n" &
    "  set(CMAKE_BUILD_TYPE Release)\nendif()\n" &
    "file(GLOB PARSESEG_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/*.c)\n" &
    "add_library(parseseg ${PARSESEG_SOURCES})\n" &
    "set_target_properties(parseseg PROPERTIES POSITION_INDEPENDENT_CODE ON)\n" &
    "target_include_directories(parseseg PRIVATE src PUBLIC include)\n" &
    "target_compile_options(parseseg PRIVATE -w -fno-strict-aliasing -fno-ident " &
    "-fno-math-errno " & b.cflags & ")\n" &
    (if t.os == "linux": "target_link_options(parseseg PRIVATE -Wl,-Bsymbolic)\n"
     else: "") &
    (if libs.len > 0:
       "target_link_libraries(parseseg PUBLIC " &
         libs.replace("-framework Security", "\"-framework Security\"") & ")\n"
     else: "")

proc csources(t: Target) =
  ## The generated C for `t` (word size and OS code are baked in, so one
  ## bundle per triple), with nimbase.h, the header and two build files.
  let dir = "bin/csources/" & t.triple
  rmDir dir
  mkDir dir & "/src"
  mkDir dir & "/include"
  selfExec "c --app:staticlib " & capiFlags & " --os:" & t.os & " --cpu:" & t.cpu &
    osFlags(t.os) & " --ic:off --compileOnly --genScript --nimcache:" & dir & "/src " & capiMain
  cpFile querySetting(libPath) & "/nimbase.h", dir & "/src/nimbase.h"
  cpFile "include/parseseg.h", dir & "/include/parseseg.h"
  for f in listFiles(dir & "/src"):
    if not (f.endsWith(".c") or f.endsWith(".h")): rmFile f
    elif f.endsWith(".c"):
      # Nim's header comment records this machine's compiler command and paths.
      # Blanked in place: slicing megabyte strings is slow in the NimScript VM.
      var c = readFile(f)
      let i = c.find("/* Command for C compiler:")
      if i >= 0:
        let j = c.find("*/", i)
        if j >= 0:
          for k in i + 2 .. j - 1:
            if c[k] notin {'\n', '\r'}: c[k] = ' '
          writeFile(f, c)
  writeFile dir & "/Makefile", bundleMakefile(t)
  writeFile dir & "/CMakeLists.txt", bundleCmake(t)
  writeFile dir & "/README.txt", "parseseg " & t.triple & " C sources, generated by " &
    "`nim csources` from parseSEG " & gorge("git describe --always --dirty") & ".\n" &
    "Build with `make` or CMake (GCC or Clang); include include/parseseg.h and call\n" &
    "seg_init() once before anything else. The C is specific to " & t.triple & ".\n"

task csources, "Generate a C source bundle per target triple (bin/csources/<triple>/)":
  for t in targets: csources(t)

task test, "Run test suite":
  ## Executes unittest suite (PARSESEG_IC=1: incremental compilation).
  selfExec "c -r --hints:off" & dev() & "tests/tester.nim"

task fmt, "Format codebase via nimpretty":
  ## Formats source and test files in-place.
  exec "nimpretty --indent:2 src/parseSEG.nim"

task docs, "Generate HTML documentation":
  ## Emits HTML documentation into htmldocs directory.
  selfExec "doc --project --outdir:htmldocs src/parseSEG.nim"
