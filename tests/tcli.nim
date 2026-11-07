## The `parseSEGD` command line tool (Phase 7) end to end: builds it as
## `nim cli` does and runs every command on the sample files, checking the
## output, the files written and the exit status (0 ok, 1 errors, 2 usage).

import std/[assertions, os, osproc, strutils]

const
  root = currentSourcePath().parentDir.parentDir
  ex = root / "SEG Spec" / "exampleFiles"
  inglewood = ex / "BO_3D-Inglewood_rev21_v7.sgy"
  s63 = ex / "63.sgd"
  inova = ex / "inova_rev30_5traces.sgd"

let tmp = getTempDir() / "parsesegd_tcli"
createDir(tmp)
let exe = tmp / "parseSEGD"
block build:
  let (o, code) = execCmdEx(getCurrentCompilerExe().quoteShell & " c --hints:off -d:release " &
    "--nimcache:" & quoteShell(tmp / "cache") & " -o:" & quoteShell(exe) & " " &
    quoteShell(root / "src" / "parseSEGD" / "cli.nim"))
  doAssert code == 0, o

proc run(args: varargs[string]): (string, int) =
  var cmd = quoteShell(exe)
  for a in args: cmd.add " " & quoteShell(a)
  execCmdEx(cmd & " 2>&1")

proc ok(args: varargs[string]): string =
  let (o, code) = run(args)
  doAssert code == 0, $args & " exited " & $code & ":\n" & o
  o

proc fails(code: int, args: varargs[string]): string =
  let (o, c) = run(args)
  doAssert c == code, $args & " exited " & $c & ", not " & $code & ":\n" & o
  o

proc fresh(src: string): string =
  result = tmp / src.extractFilename
  copyFile(src, result)
  for j in [result & ".edits.nif", result & ".j.nif"]:
    if fileExists(j): removeFile(j)

# -------------------------------------------------------- 7.1: inspecting --

block usage_and_version:
  doAssert "parseSEGD 0.2.0" in ok("version")
  doAssert "Usage: parseSEGD" in ok("help")
  doAssert "unknown command" in fails(2, "frobnicate")
  doAssert "expected info <file>" in fails(2, "info")
  doAssert "no such file" in fails(2, "info", tmp / "missing.sgy")
  doAssert "unknown option --bogus" in fails(2, "info", inglewood, "--bogus")
  doAssert "Usage" in fails(2)
  writeFile(tmp / "junk.bin", "not seismic data at all")
  doAssert "neither SEG-Y nor SEG-D" in fails(1, "info", tmp / "junk.bin")

block info:
  let a = ok("info", inglewood, "--keys")
  doAssert "SEG-Y rev 2.1" in a and "1 (IBM float)" in a and "200 (up to 2001 samples" in a
  doAssert "2000.0 µs" in a and "gathers:" in a and "0 fatal, 0 error" in a
  let b = ok("info", inova, "--keys")
  doAssert "SEG-D rev 3.0" in b and "8058" in b and "records:     1" in b and "1 shot" in b
  doAssert "5 (up to 4001 samples" in ok("info", inova)

block dump:
  let d = ok("dump", inglewood, "--traces=4..5", "--fields=trace.sourceX,trace.bogus")
  let lines = d.strip.splitLines
  doAssert lines[0].startsWith("trace\toffset\tsamples") and "trace.sourceX" in lines[0]
  doAssert lines[2].startsWith("5\t374420\t2001") and "\t1704188\t?" in lines[2]
  doAssert "trace.bogus: is not a field" in d
  doAssert ok("dump", inglewood, "--traces=1,3").strip.splitLines.len == 3
  let all = ok("dump", s63, "--all", "--traces=0")
  doAssert "trace.traceNumber = " in all and "ext1.receiverLineNumber = " in all
  doAssert "out of range" in fails(2, "dump", inglewood, "--traces=200")
  doAssert "bad trace selection" in fails(2, "dump", inglewood, "--traces=x")

block diag:
  let d = ok("diag", s63)
  doAssert d.count("info:") == 2 and "array forming" in d
  doAssert "no diagnostics" in ok("diag", s63, "--min=warning")
  let n = ok("diag", s63, "--nif")
  doAssert n.startsWith("(.nif27)") and "(diagnostics" in n
  doAssert fails(2, "diag", s63, "--min=loud").contains("--min must be")

# -------------------------------------------------------- 7.1: converting --

block convert:
  let o = ok("convert", s63, tmp / "63.sgy", "--rev=1", "--text=ascii")
  doAssert "written" in o
  doAssert "SEG-Y rev 1.0" in ok("info", tmp / "63.sgy")
  # Both names SEG-D: SEG-D to SEG-D (default 3.0), then back to 2.1.
  discard ok("convert", s63, tmp / "63_r3.sgd")
  doAssert "SEG-D rev 3.0" in ok("info", tmp / "63_r3.sgd")
  discard ok("convert", tmp / "63_r3.sgd", tmp / "63_r21.sgd", "--rev=2.1")
  doAssert "SEG-D rev 2.1" in ok("info", tmp / "63_r21.sgd")
  discard ok("convert", inglewood, tmp / "le.sgy", "--byte-order=little", "--format=5")
  doAssert "little-endian" in ok("info", tmp / "le.sgy")
  doAssert "applies to SEG-Y output only" in
    fails(2, "convert", s63, tmp / "x.sgd", "--to=segd", "--descale")
  doAssert "--to is segy or segd" in fails(2, "convert", s63, tmp / "x.sgy", "--to=segx")
  discard fails(1, "convert", s63, tmp / "x.sgd", "--to=segd", "--rev=1.0")
  discard fails(1, "convert", inglewood, inglewood)
  doAssert "--byte-order is" in fails(2, "convert", inglewood, tmp / "x.sgy", "--byte-order=up")

# -------------------------------------------------------- 7.3: editing --

block edit_and_journal:
  let f = fresh(inglewood)
  let o = ok("edit", f, "t5:trace.sourceX=1200", "t0..2:trace.groupStatic=-7",
    "file:binary.jobId=7", "t0:trace.headerName=\"AB\"")
  doAssert "6 edits written" in o
  let d = ok("dump", f, "--traces=0,5", "--fields=trace.sourceX,trace.groupStatic")
  doAssert "\t1200\t0" in d and "\t-7" in d
  doAssert "changes the file's structure" in fails(1, "edit", f, "t0:trace.numSamples=5")
  doAssert "bad assignment" in fails(2, "edit", f, "trace.sourceX=1")
  doAssert "bad scope" in fails(2, "edit", f, "x5:trace.sourceX=1")
  discard ok("journal", "rollback", f, f & ".edits.nif")
  doAssert readFile(f) == readFile(inglewood)
  discard ok("journal", "apply", f, f & ".edits.nif")
  doAssert "\t1200" in ok("dump", f, "--traces=5", "--fields=trace.sourceX")
  doAssert "expected journal" in fails(2, "journal", "undo", f, f & ".edits.nif")
  # SEG-D record fields.
  let g = fresh(s63)
  discard ok("edit", g, "--journal=" & g & ".j.nif", "r0:gh1.year=25")
  doAssert "1 traces exported" in ok("headers", "export", g, "-o", tmp / "g.nif")
  let h = readFile(tmp / "g.nif")
  doAssert "(standard segd)" in h and "(block gh1" in h and "(f year 25)" in h
  doAssert "(block gh3" in h and "(f sourcePointNumber 99.5)" in h

block headers_export_and_import:
  let f = fresh(inglewood)
  doAssert "200 traces exported" in ok("headers", "export", f, "-o", tmp / "h.nif")
  let h = readFile(tmp / "h.nif")
  doAssert h.startsWith("(.nif27)") and "(standard segy)" in h and "(raw " in h
  doAssert "0 changed fields" in ok("headers", "import", f, tmp / "h.nif") # a lossless round trip
  discard ok("headers", "export", f, "-o", tmp / "fo.nif", "--fields-only")
  doAssert "(raw " notin readFile(tmp / "fo.nif")
  # Edit two values in the document; import as a dry run, into a copy, in place.
  var e = h
  let i = e.find("(trace 7")
  let j = e.find("(f sourceX ", i)
  e = e[0 ..< j] & "(f sourceX 4242" & e[e.find(")", j) .. ^1]
  let k = e.find("(f jobId ")
  e = e[0 ..< k] & "(f jobId 99" & e[e.find(")", k) .. ^1]
  writeFile(tmp / "h2.nif", e)
  let dry = ok("headers", "import", f, tmp / "h2.nif", "--dry-run")
  doAssert "trace 7 trace.sourceX: 1704245 -> 4242" in dry and "2 changed fields (dry run" in dry
  doAssert readFile(f) == readFile(inglewood)
  discard ok("headers", "import", f, tmp / "h2.nif", "-o", tmp / "copy.sgy")
  doAssert readFile(f) == readFile(inglewood)
  doAssert "\t4242" in ok("dump", tmp / "copy.sgy", "--traces=7", "--fields=trace.sourceX")
  discard ok("headers", "import", f, tmp / "h2.nif", "--journal=" & f & ".j.nif")
  doAssert "\t4242" in ok("dump", f, "--traces=7", "--fields=trace.sourceX")
  discard ok("journal", "rollback", f, f & ".j.nif")
  doAssert readFile(f) == readFile(inglewood)
  # Bad documents: unknown names are errors, broken syntax is fatal; nothing breaks.
  writeFile(tmp / "bad.nif", "(.nif27)\n(headers (trace 999 (block trace (f sourceX 1)))" &
    " (trace 1 (block trace (f nope 1))))\n")
  let bad = fails(1, "headers", "import", f, tmp / "bad.nif")
  doAssert "no trace 999" in bad and "is not a field" in bad
  writeFile(tmp / "broken.nif", "(headers (trace 1")
  doAssert "fatal" in fails(1, "headers", "import", f, tmp / "broken.nif")
  doAssert "no such file" in fails(2, "headers", "import", f, tmp / "none.nif")

# --------------------------------------------------- 7.1b: vendor maps --

block vendormaps:
  let example = root / "tests" / "vendormaps" / "example.nif"
  doAssert "acme-extended version 1, 3 targets, ok" in ok("vendormap", "check", example)
  writeFile(tmp / "broken_map.nif", "(vendormap \"x\" (version 1) (target")
  doAssert "not loaded" in fails(1, "vendormap", "check", tmp / "broken_map.nif")
  doAssert "[does not match]" in ok("vendormap", "list", s63, "--map=" & example)
  # Scaffold the INOVA vendor blocks, check the skeleton, apply it, rescan.
  let o = ok("vendormap", "scaffold", inova, "-o", tmp / "inova.nif")
  doAssert "unmapped vendor areas" in o
  let m = readFile(tmp / "inova.nif")
  doAssert "(kind block) (type 0xB0) (where traceHeader)" in m and "(manufacturer 50)" in m
  doAssert ", ok" in ok("vendormap", "check", tmp / "inova.nif")
  doAssert "[matches]" in ok("vendormap", "list", inova, "--map=" & tmp / "inova.nif")
  let a = ok("vendormap", "apply", inova, "--map=" & tmp / "inova.nif", "--traces=3")
  doAssert "(trace 3" in a and "blockB0Trace" in a and "(f blockB0Trace_1 " in a
  let again = ok("vendormap", "scaffold", inova, "--map=" & tmp / "inova.nif")
  doAssert "(target" notin again # everything is mapped now
  doAssert "(kind extendedHeader) (blockIndex 1)" in ok("vendormap", "scaffold", s63)
  doAssert "expected vendormap" in fails(2, "vendormap", "frob")

echo "tcli: ok"
