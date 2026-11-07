## The C ABI end to end (tasks 8.4, 12.2): builds the shared library as
## `nim lib` does, writing the generated header and Python module into a
## temporary directory, then
## - checks that they equal the committed `include/parseseg.h` and
##   `python/parseseg/__init__.py` (rebuild with `nim lib` and commit them);
## - compiles `tests/c/abi_test.c` against the header (C99 and as C++) and
##   runs it: struct layouts against the library's own, every function,
##   errors, edits and journals, 4 host threads;
## - checks that the exported `seg_*` symbols and the header's declarations
##   are the same set.
## Each step is skipped (with a message) when its tool (cc, nm) is missing.
## `-d:capiSanitize` repeats the C test under ASan and TSan.

import std/[assertions, os, osproc, strutils, sets]

const
  root = currentSourcePath().parentDir.parentDir
  header = root / "include" / "parseseg.h"
  exampleDir = root / "SEG Spec" / "exampleFiles"

let tmp = getTempDir() / "parseseg_tcapi"
createDir(tmp)

proc run(cmd: string): (string, int) =
  let (o, code) = execCmdEx(cmd)
  (o, code)

proc mustRun(cmd: string) =
  let (o, code) = run(cmd)
  if code != 0:
    echo o
    quit "tcapi: command failed: " & cmd

proc buildLib(dir: string, extra = "") =
  ## Builds the library into `dir`, with the generated files under `dir/gen`.
  createDir(dir / "gen" / "include")
  createDir(dir / "gen" / "python" / "parseseg")
  mustRun(getCurrentCompilerExe().quoteShell & " c --hints:off --app:lib --noMain " &
    "--mm:atomicArc --threads:on -d:useMalloc -d:segCapi " & extra & " --nimcache:" &
    quoteShell(dir / "cache") & " -d:segBindingsDir=" & quoteShell(dir / "gen") &
    " -o:" & quoteShell(dir / "libparseseg.so") & " " &
    quoteShell(root / "src" / "parseSEG" / "bindings.nim"))

when defined(linux):
  let libDir = tmp / "release"
  buildLib(libDir, "-d:release")
  let lib = libDir / "libparseseg.so"
  let cc = findExe("cc")

  block generated_files_are_committed:
    for (gen, committed) in [(libDir / "gen" / "include" / "parseseg.h", header),
        (libDir / "gen" / "python" / "parseseg" / "__init__.py",
         root / "python" / "parseseg" / "__init__.py")]:
      doAssert readFile(gen) == readFile(committed),
        committed & " is out of date: rebuild with `nim lib` and commit it"

  block c_abi_test:
    if cc.len == 0:
      echo "tcapi: no C compiler; C test skipped"
    else:
      let exe = libDir / "abi_test"
      mustRun(cc & " -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pedantic -I" &
        quoteShell(root / "include") & " -o " & quoteShell(exe) & " " &
        quoteShell(root / "tests" / "c" / "abi_test.c") & " -L" & quoteShell(libDir) &
        " -lparseseg -lpthread -lm -Wl,-rpath," & quoteShell(libDir))
      mustRun(quoteShell(exe) & " " & quoteShell(exampleDir) & " " & quoteShell(tmp))
      let cxx = findExe("c++")
      if cxx.len > 0:
        mustRun(cxx & " -Wall -Wextra -Werror -fsyntax-only -x c++ " & quoteShell(header))

  block symbols_match_the_header:
    let nm = findExe("nm")
    if nm.len == 0:
      echo "tcapi: no nm; symbol check skipped"
    else:
      let (o, code) = run(nm & " -D --defined-only " & quoteShell(lib))
      doAssert code == 0
      var exported, declared: HashSet[string]
      for line in o.splitLines:
        let parts = line.splitWhitespace
        if parts.len == 3 and parts[2].startsWith("seg_"): exported.incl parts[2]
      let h = readFile(header)
      var i = h.find("seg_")
      while i >= 0:
        var j = i + 4
        while j < h.len and h[j] in {'a'..'z', '0'..'9', '_'}: inc j
        if (i == 0 or h[i - 1] notin IdentChars) and j < h.len and h[j] == '(':
          declared.incl h[i ..< j]
        i = h.find("seg_", j)
      doAssert exported.len > 40
      doAssert exported == declared, "only exported: " & $(exported - declared) &
        "; only declared: " & $(declared - exported)

  when defined(capiSanitize):
    block sanitizers:
      for san in ["address", "thread"]:
        let dir = tmp / san
        buildLib(dir, "-d:noSignalHandler --debugger:native --passC:-fsanitize=" & san &
          " --passL:-fsanitize=" & san)
        let exe = dir / "abi_test"
        mustRun(cc & " -g -fsanitize=" & san & " -std=c99 -D_POSIX_C_SOURCE=200809L -I" &
          quoteShell(root / "include") & " -o " & quoteShell(exe) & " " &
          quoteShell(root / "tests" / "c" / "abi_test.c") & " -L" & quoteShell(dir) &
          " -lparseseg -lpthread -lm -Wl,-rpath," & quoteShell(dir))
        # The out-of-memory test asks the allocator for 512 GiB.
        mustRun("ASAN_OPTIONS=allocator_may_return_null=1 TSAN_OPTIONS=allocator_may_return_null=1 " &
          quoteShell(exe) & " " & quoteShell(exampleDir) & " " & quoteShell(tmp))
else:
  echo "tcapi: the C ABI test runs on Linux only for now"
