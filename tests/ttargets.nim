## Every build target (task 8.9) runs as the nimble tasks in `config.nims`
## build it, so a changed flag or target fails here:
## - `nim lib` and `nim staticlib`: `tests/c/abi_test.c` passes against both;
## - `nim pylib`: the release module imports and works;
## - `nim csources`: the linux-x64 bundle builds with `make` alone, and
##   abi_test passes against its static and shared library; every bundle has
##   its files;
## - with zig: `nim libLinux`, `libWindows` and `libMacos`. abi_test passes
##   against the zig (clang) linux-x64 build, and every binary exports the
##   header's functions (checked with llvm-nm/llvm-objdump when present).
## Each step is skipped, with a message, when its tool is missing.

import std/[os, osproc, strutils, sets]

const
  root = currentSourcePath().parentDir.parentDir
  exampleDir = root / "SEG Spec" / "exampleFiles"
  abiTest = root / "tests" / "c" / "abi_test.c"

let tmp = getTempDir() / "parseseg_ttargets"
createDir(tmp)
let nim = getCurrentCompilerExe().quoteShell
let cc = findExe("cc")

proc mustRun(cmd: string, dir = root) =
  let (o, code) = execCmdEx(cmd, workingDir = dir)
  if code != 0:
    echo o
    quit "ttargets: command failed: " & cmd

proc task(name: string) = mustRun(nim & " --hints:off " & name)

proc headerFunctions(): HashSet[string] =
  let h = readFile(root / "include" / "parseseg.h")
  var i = h.find("seg_")
  while i >= 0:
    var j = i + 4
    while j < h.len and h[j] in {'a'..'z', '0'..'9', '_'}: inc j
    if (i == 0 or h[i - 1] notin IdentChars) and j < h.len and h[j] == '(':
      result.incl h[i ..< j]
    i = h.find("seg_", j)

let wanted = headerFunctions()

proc exportsOf(listing: string, prefix: string): HashSet[string] =
  for w in listing.splitWhitespace:
    if w.startsWith(prefix & "seg_"): result.incl w[prefix.len .. ^1]

proc runAbiTest(name, linkArgs: string) =
  ## Compiles abi_test against `linkArgs` and runs it.
  let exe = tmp / ("abi_" & name)
  mustRun(cc & " -std=c99 -D_POSIX_C_SOURCE=200809L -I" & quoteShell(root / "include") &
    " -o " & quoteShell(exe) & " " & quoteShell(abiTest) & " " & linkArgs)
  mustRun(quoteShell(exe) & " " & quoteShell(exampleDir) & " " & quoteShell(tmp))
  echo "ttargets: abi_test passes against ", name

when defined(linux):
  if cc.len == 0:
    quit "ttargets: no C compiler; skipped", 0

  block host_shared_and_static:
    task "lib"
    runAbiTest("lib", "-L" & quoteShell(root / "bin") & " -lparseseg -lpthread -lm -Wl,-rpath," &
      quoteShell(root / "bin"))
    task "staticlib"
    runAbiTest("staticlib", quoteShell(root / "bin" / "libparseseg.a") & " -lpthread -lm -ldl")

  block another_nim_library_in_the_host:
    # Every Nim library exports NimMain; seg_init must run its own even when
    # the host loaded another first (ELF interposition, Phase 8 review).
    let d = tmp / "interpose"
    createDir(d)
    writeFile(d / "other.c", "#include <stdio.h>\nvoid NimMain(void) { puts(\"OTHER\"); }\n")
    writeFile(d / "host.c", """
#include <stdio.h>
#include "parseseg.h"
int main(int argc, char **argv) {
    (void)argc;
    if (seg_init() != SEG_ABI_VERSION) return 3;
    SegFile *f = NULL;
    if (seg_file_open(argv[1], 0, &f) != SEG_OK) return 4;
    printf("traces %lld\n", (long long)seg_file_trace_count(f));
    seg_file_release(f);
    return 0;
}
""")
    mustRun(cc & " -shared -fPIC -o " & quoteShell(d / "libother.so") & " " & quoteShell(d / "other.c"))
    let lib = root / "bin"
    mustRun(cc & " -I" & quoteShell(root / "include") & " -o " & quoteShell(d / "host") & " " &
      quoteShell(d / "host.c") & " -Wl,--no-as-needed -L" & quoteShell(d) & " -lother -L" &
      quoteShell(lib) & " -lparseseg -Wl,-rpath," & quoteShell(d) & ":" & quoteShell(lib))
    let (o, code) = execCmdEx(quoteShell(d / "host") & " " &
      quoteShell(exampleDir / "Sweep0.sgy"))
    doAssert code == 0 and "OTHER" notin o and "traces 1" in o, o
    echo "ttargets: seg_init runs its own NimMain beside another Nim library"

  block python_module:
    let py = findExe("python3")
    if py.len == 0 or findExe("git").len == 0:
      echo "ttargets: no python3 or git; pylib skipped"
    else:
      task "pylib"
      mustRun(py & " -I -c " & quoteShell("import sys; sys.path.insert(0, sys.argv[1]); " &
        "import parseseg; f = parseseg.open(sys.argv[2]); " &
        "assert f.read(0, 2, dtype='float64').shape() == (2, 2001)") & " " &
        quoteShell(root / "bin") & " " &
        quoteShell(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"))
      echo "ttargets: the release Python module works"

  block csources_bundles:
    task "csources"
    for t in ["linux-x64", "linux-arm64", "windows-x64", "macos-arm64", "macos-x64"]:
      let d = root / "bin" / "csources" / t
      for f in ["Makefile", "CMakeLists.txt", "README.txt", "include/parseseg.h",
          "src/nimbase.h"]:
        doAssert fileExists(d / f), t & ": no " & f
      var cFiles = 0
      for f in walkFiles(d / "src" / "*.c"): inc cFiles
      doAssert cFiles > 50, t & ": " & $cFiles & " C files"
      for f in walkFiles(d / "src" / "*.c"):
        doAssert root notin readFile(f), f & " holds " & root
    if findExe("make").len == 0:
      echo "ttargets: no make; the bundle build is skipped"
    else:
      let b = tmp / "csources-linux-x64"
      removeDir(b)
      copyDir(root / "bin" / "csources" / "linux-x64", b)
      mustRun("make -s -j" & $max(1, countProcessors()), b)
      runAbiTest("csources-static", quoteShell(b / "libparseseg.a") & " -lpthread -lm -ldl")
      runAbiTest("csources-shared", "-L" & quoteShell(b) & " -lparseseg -lpthread -lm " &
        "-Wl,-rpath," & quoteShell(b))

  block zig_cross_builds:
    if findExe("zig").len == 0:
      echo "ttargets: no zig; cross builds skipped"
    else:
      task "libLinux"
      task "libWindows"
      task "libMacos"
      # clang drops an unused malloc/free pair: the memory probe must survive it.
      runAbiTest("zig-linux-x64", "-L" & quoteShell(root / "bin" / "linux-x64") &
        " -lparseseg -lpthread -lm -Wl,-rpath," & quoteShell(root / "bin" / "linux-x64"))
      let llvmNm = block:
        var p = findExe("llvm-nm")
        for v in countdown(20, 12):
          if p.len == 0: p = findExe("llvm-nm-" & $v)
        p
      let llvmObjdump = llvmNm.replace("llvm-nm", "llvm-objdump")
      if llvmNm.len == 0 or not fileExists(llvmObjdump):
        echo "ttargets: no llvm-nm/llvm-objdump; cross exports unchecked"
      else:
        for (t, lib, mode) in [("linux-arm64", "libparseseg.so", "elf"),
            ("windows-x64", "parseseg.dll", "pe"), ("macos-arm64", "libparseseg.dylib", "macho"),
            ("macos-x64", "libparseseg.dylib", "macho")]:
          let f = quoteShell(root / "bin" / t / lib)
          let got = case mode
            of "elf": exportsOf(execProcess(llvmNm & " -D --defined-only " & f), "")
            of "macho": exportsOf(execProcess(llvmNm & " -gU " & f), "_")
            else: exportsOf(execProcess(llvmObjdump & " -p " & f), "")
          doAssert got == wanted, t & ": missing " & $(wanted - got) & ", extra " &
            $(got - wanted)
        echo "ttargets: every cross build exports the header's ", wanted.len, " functions"
        # Loadable on older macOS, and no paths of this machine inside.
        for t in ["macos-arm64", "macos-x64"]:
          let p = execProcess(llvmObjdump & " --macho -p " &
            quoteShell(root / "bin" / t / "libparseseg.dylib"))
          doAssert "minos 15" notin p and ("minos 11.0" in p or "minos 10.15" in p), t
        for t in ["linux-x64", "linux-arm64", "windows-x64", "macos-arm64", "macos-x64"]:
          for f in walkFiles(root / "bin" / t / "*"):
            if not f.endsWith(".h"):
              doAssert root notin readFile(f), f & " holds " & root
        echo "ttargets: cross builds carry no local paths; macOS minimums are 11.0 / 10.15"
else:
  echo "ttargets: build targets are tested on Linux only for now"
