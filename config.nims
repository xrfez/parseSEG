# Strict build configuration and task orchestrator for parseSEGD
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
    ("macos-arm64", "macosx", "arm64", "aarch64-macos"),
    ("macos-x64", "macosx", "amd64", "x86_64-macos")]
  abiFlags = "--mm:atomicArc --threads:on -d:useMalloc -d:release"
  capiFlags = "--noMain " & abiFlags & " -d:segCapi"
  capiMain = "src/parseSEGD/capi.nim"

func libFile(os: string): string =
  case os
  of "windows": "parseseg.dll"
  of "macosx": "libparseseg.dylib"
  else: "libparseseg.so"

func staticFile(os: string): string =
  if os == "windows": "parseseg.lib" else: "libparseseg.a"

func osFlags(os: string): string =
  if os == "windows": " --tlsEmulation:off" else: ""

proc zigOsFlags(os: string): string =
  ## macOS: zig has the headers but no frameworks; a link-time stub stands in
  ## for Security.framework (see tools/macos-stubs).
  if os == "macosx":
    " --passL:-F" & thisDir() & "/tools/macos-stubs" &
      " --passL:-Wl,-install_name,@rpath/libparseseg.dylib"
  else: ""

const hostOs = when defined(windows): "windows" elif defined(macosx): "macosx" else: "linux"

proc zigFlags(t: Target): string =
  ## Cross-compiles with zig cc for `t` (zig ships every target's libc headers).
  "--cc:clang --clang.exe:" & zigccExe & " --clang.linkerexe:" & zigccExe &
    " --os:" & t.os & " --cpu:" & t.cpu & osFlags(t.os) & zigOsFlags(t.os) &
    " --passC:\"-target " & t.zig & "\" --passL:\"-target " & t.zig & "\"" &
    " --nimcache:nimcache/" & t.triple

proc crossLib(t: Target) =
  mkDir "bin/" & t.triple
  var extra = ""
  if t.os == "windows":
    # An import library, so MSVC and MinGW hosts can link the DLL.
    extra = " --passL:-Wl,--out-implib,bin/" & t.triple & "/parseseg.dll.lib"
  selfExec "c --app:lib " & capiFlags & " " & zigFlags(t) & extra & " --out:bin/" & t.triple &
    "/" & libFile(t.os) & " " & capiMain
  cpFile "include/parseseg.h", "bin/" & t.triple & "/parseseg.h"

proc crossLibs(os: string) =
  for t in targets:
    if t.os == os: crossLib(t)

task lib, "Build the C ABI shared library for this host (bin/libparseseg.so, include/parseseg.h)":
  selfExec "c --app:lib " & capiFlags & osFlags(hostOs) &
    (when defined(macosx): " --passL:-Wl,-install_name,@rpath/libparseseg.dylib" else: "") &
    " --out:bin/" & libFile(hostOs) & " " & capiMain

task libLinux, "Cross-build the C ABI for linux-x64 and linux-arm64 with zig (bin/<triple>/)":
  crossLibs("linux")

task libWindows, "Cross-build the C ABI for windows-x64 with zig (bin/windows-x64/parseseg.dll)":
  crossLibs("windows")

task libMacos, "Cross-build the C ABI for macos-arm64 and macos-x64 with zig (bin/<triple>/)":
  crossLibs("macosx")

task staticlib, "Build the C ABI as a static library for this host (bin/libparseseg.a)":
  ## Link it with -lpthread -lm -ldl (Linux) and call seg_init() first, as with the .so.
  selfExec "c --app:staticlib " & capiFlags & osFlags(hostOs) & " --out:bin/" &
    staticFile(hostOs) & " " & capiMain

const pyModName = when defined(windows): "parseseg.pyd" else: "parseseg.so"

proc patchNimpy() =
  ## Applies tools/patches/nimpy-method-kwargs.patch to the Atlas checkout
  ## once (nimpy 0.2.1 miscounts a method's arguments when keywords are
  ## passed); a no-op when it is already applied. Drop it once upstream is fixed.
  const patch = "../../tools/patches/nimpy-method-kwargs.patch"
  if gorgeEx("git -C deps/nimpy apply --reverse --check " & patch).exitCode != 0:
    exec "git -C deps/nimpy apply " & patch

task pylib, "Build the Python module for this host (bin/parseseg.so, `import parseseg`)":
  ## No --noMain: Python's import initializes the runtime. nimpy looks the
  ## CPython API up in the importing process, so no libpython is linked and one
  ## build serves every Python 3. Windows/MinGW also links statically.
  patchNimpy()
  selfExec "c --app:lib " & abiFlags & " -d:segPython" & osFlags(hostOs) &
    (when defined(windows): " --passL:-static" else: "") &
    " --out:bin/" & pyModName & " src/parseSEGD/pyapi.nim"

func bundleFlags(os: string): tuple[cflags, libs, shared, sharedFlag: string] =
  ## The C flags Nim itself uses for `os`, and how to link a shared library.
  case os
  of "windows":
    ("-mno-ms-bitfields -DWIN32_LEAN_AND_MEAN", "", "parseseg.dll", "-shared")
  of "macosx":
    ("-pthread", "-lpthread -lm -framework Security", "libparseseg.dylib",
      "-dynamiclib -install_name @rpath/libparseseg.dylib")
  else:
    ("-pthread", "-lpthread -lm -ldl", "libparseseg.so", "-shared")

proc bundleMakefile(t: Target): string =
  let b = bundleFlags(t.os)
  "# parseseg " & t.triple & ": builds the static and shared library from the generated C\n" &
    "# with GCC or Clang, no Nim needed:  make  |  CC=clang make  |  make CFLAGS=-O2\n" &
    "CC ?= cc\nAR ?= ar\nCFLAGS ?= -O3\n" &
    "NIMFLAGS := -w -fno-strict-aliasing -fno-ident -fno-math-errno " & b.cflags &
    (if t.os == "windows": "" else: " -fPIC") & " -Isrc\n" &
    "LIBS := " & b.libs & "\n" &
    "OBJS := $(patsubst %.c,%.o,$(wildcard src/*.c))\n\n" &
    "all: " & staticFile(t.os) & " " & b.shared & "\n\n" &
    "%.o: %.c\n\t$(CC) -c $(NIMFLAGS) $(CFLAGS) -o $@ $<\n\n" &
    staticFile(t.os) & ": $(OBJS)\n\t$(AR) rcs $@ $^\n\n" &
    b.shared & ": $(OBJS)\n\t$(CC) " & b.sharedFlag & " -o $@ $^ $(LIBS)\n\n" &
    "clean:\n\trm -f $(OBJS) " & staticFile(t.os) & " " & b.shared & "\n\n" &
    ".PHONY: all clean\n"

proc bundleCmake(t: Target): string =
  let b = bundleFlags(t.os)
  "# parseseg " & t.triple & ": the library from the generated C (GCC or Clang).\n" &
    "#   cmake -B build [-DBUILD_SHARED_LIBS=ON] && cmake --build build\n" &
    "cmake_minimum_required(VERSION 3.13)\nproject(parseseg C)\n" &
    "file(GLOB PARSESEG_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/*.c)\n" &
    "add_library(parseseg ${PARSESEG_SOURCES})\n" &
    "set_target_properties(parseseg PROPERTIES POSITION_INDEPENDENT_CODE ON)\n" &
    "target_include_directories(parseseg PRIVATE src PUBLIC include)\n" &
    "target_compile_options(parseseg PRIVATE -w -fno-strict-aliasing -fno-ident " &
    "-fno-math-errno " & b.cflags & ")\n" &
    (if b.libs.len > 0:
       "target_link_libraries(parseseg PUBLIC " &
         b.libs.replace("-framework Security", "\"-framework Security\"") & ")\n"
     else: "")

proc csources(t: Target) =
  ## The generated C for `t` (word size and OS code are baked in, so one
  ## bundle per triple), with nimbase.h, the header and two build files.
  let dir = "bin/csources/" & t.triple
  rmDir dir
  mkDir dir & "/src"
  mkDir dir & "/include"
  selfExec "c --app:staticlib " & capiFlags & " --os:" & t.os & " --cpu:" & t.cpu &
    osFlags(t.os) & " --compileOnly --genScript --nimcache:" & dir & "/src " & capiMain
  cpFile querySetting(libPath) & "/nimbase.h", dir & "/src/nimbase.h"
  cpFile "include/parseseg.h", dir & "/include/parseseg.h"
  for f in listFiles(dir & "/src"):
    if not (f.endsWith(".c") or f.endsWith(".h")): rmFile f
  writeFile dir & "/Makefile", bundleMakefile(t)
  writeFile dir & "/CMakeLists.txt", bundleCmake(t)
  writeFile dir & "/README.txt", "parseseg " & t.triple & " C sources, generated by " &
    "`nim csources` from parseSEGD " & gorge("git describe --always --dirty") & ".\n" &
    "Build with `make` or CMake (GCC or Clang); include include/parseseg.h and call\n" &
    "seg_init() once before anything else. The C is specific to " & t.triple & ".\n"

task csources, "Generate a C source bundle per target triple (bin/csources/<triple>/)":
  for t in targets: csources(t)

task test, "Run test suite":
  ## Executes unittest suite.
  selfExec "c -r --hints:off tests/tester.nim"

task fmt, "Format codebase via nimpretty":
  ## Formats source and test files in-place.
  exec "nimpretty --indent:2 src/parseSEGD.nim"

task docs, "Generate HTML documentation":
  ## Emits HTML documentation into htmldocs directory.
  selfExec "doc --project --outdir:htmldocs src/parseSEGD.nim"
