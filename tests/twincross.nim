## A Windows build from a POSIX host (18.3): `common/endians` and
## `common/ibmfloat` include `cpu.h` by a path made at compile time, which
## `/` joined with `\` under `--os:windows`, so the host's C compiler could
## not find it. Checked as far as this repository can without a Windows
## toolchain: the C that `nim c --os:windows --cpu:amd64 --compileOnly`
## makes for both modules names the header by a path that exists here and
## has no `\`; and, when `zig` is on the PATH, `zig cc -target
## x86_64-windows-gnu` compiles both C files. Seen failing with the path
## joined by `/` again (the include held `\cpu.h`; zig: file not found).
## Zig also compiles the Windows system calls of `faAuto` (`private/netfs`:
## `GetVolumePathNameW`, `GetDriveTypeW`, `QueryDosDeviceW`,
## `GetFileAttributesW`), of unmapped reads (`private/readcache`) and of the
## shared open and map (`private/sharedfile`, `private/filemap`:
## `CreateFileW`, `CreateFileMappingW`, `MapViewOfFile`, `_open_osfhandle`)
## against the real `windows.h`.
##
## The same cross build must give `PackageVersion` (it read the nimble file
## by a path the `\` of the target broke: "unknown"); checked by compiling
## a program with `static: doAssert PackageVersion != "unknown"` for
## `--os:windows`, which needs no C compiler (`--compileOnly`), only this
## Nim. Seen failing with `parentDir` and `/` in `version.nim` again.

import std/[assertions, os, osproc, strutils]

const root = currentSourcePath().parentDir.parentDir

proc nimPaths(): string =
  ## The project's search paths, absolute.
  result = " --noNimblePath --path:" & quoteShell(root / "src")
  for line in readFile(root / "nim.cfg").splitLines:
    let s = line.strip
    if s.startsWith("--path:"):
      result.add " --path:" & quoteShell(root / s["--path:".len .. ^1].strip(chars = {'"'}))

proc main*() =
  when defined(windows):
    echo "twincross: skipped: the cross build from a POSIX host is what is checked"

    quit 0

  let tmp = getTempDir() / "parseseg_twincross"

  removeDir(tmp)

  createDir(tmp)

  let main = tmp / "winmain.nim"

  # Reads traces, so that the sample decoders, which use `cpu.h`, are compiled.
  writeFile(main, "import std/os\nimport parseSEG\n" &
    "var f = openSeismic(paramStr(1))\necho f.readTraces(0 .. 0).shape\n" &
    # Files in memory: opened from bytes, written to bytes.
    "var w = openSeismicWriterBytes(SegyOutputOptions())\n" &
    "w.addStanza(\"acme\", \"x\", [byte 1])\n" &
    "var dw = openSeismicWriterBytes(SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1))\n" &
    "dw.writeTrace(initTraceKeys(), [1'f32], externalHeader = newSeq[byte](32))\n" &
    "var m = openSeismicBytes(w.finishBytes(), \"memory\")\necho m.inMemory\n")

  let cache = tmp / "nimcache"

  let (o, code) = execCmdEx(getCurrentCompilerExe().quoteShell & " c --os:windows --cpu:amd64" &
    " --compileOnly --hints:off --warnings:off --skipParentCfg --skipUserCfg" & nimPaths() &
    " --nimcache:" & quoteShell(cache) & " " & quoteShell(main))

  doAssert code == 0, o

  var checked = 0

  var cFiles: seq[string]

  for path in walkFiles(cache / "*.c"):
    let c = readFile(path)
    for line in c.splitLines:
      if line.startsWith("#include") and "cpu.h" in line:
        let header = line.split('"')[1]
        doAssert '\\' notin header, path.extractFilename & ": " & line
        doAssert fileExists(header), path.extractFilename & ": " & header & " is not there"
        inc checked
        cFiles.add path

  doAssert checked >= 2, "the generated C that includes cpu.h: " & $checked & " files"

  for name in ["netfs.nim.c", "readcache.nim.c", "filemap.nim.c", "sharedfile.nim.c"]:
    var found = false
    for path in walkFiles(cache / "*.c"):
      if path.endsWith(name):
        cFiles.add path
        found = true
    doAssert found, name & " is not in the generated C"

  # The package version, found in a cross build.
  let vmain = tmp / "winversion.nim"
  writeFile(vmain, "import parseSEG/version\n" &
    "static: doAssert PackageVersion != \"unknown\", \"PackageVersion is unknown\"\n")
  let (vo, vcode) = execCmdEx(getCurrentCompilerExe().quoteShell & " c --os:windows --cpu:amd64" &
    " --compileOnly --hints:off --warnings:off --skipParentCfg --skipUserCfg" & nimPaths() &
    " --nimcache:" & quoteShell(tmp / "nimcachev") & " " & quoteShell(vmain))
  doAssert vcode == 0, "PackageVersion in a cross build for Windows: " & vo

  let zig = findExe("zig")

  if zig.len == 0:
    echo "twincross: the includes are checked; zig is not installed, so the C is not compiled"
  else:
    let lib = getCurrentCompilerExe().parentDir.parentDir / "lib"
    for c in cFiles:
      let (zo, zcode) = execCmdEx(quoteShell(zig) & " cc -target x86_64-windows-gnu -c -w" &
        " -I" & quoteShell(lib) & " -o " & quoteShell(c & ".o") & " " & quoteShell(c))
      doAssert zcode == 0, c.extractFilename & ": " & zo
    echo "twincross: the includes are checked and zig compiles the C for x86_64-windows-gnu"

  echo "twincross: ok"

when isMainModule: main()
