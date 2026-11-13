## The `parseSEG` command line tool (Phase 7) end to end: builds it as
## `nim cli` does and runs every command on the generated demo files
## (`tools/demofiles`) and on the sample files (skipped when they are not
## present), checking the output, the files written and the exit status (0
## ok, 1 errors, 2 usage).

import std/[assertions, os, osproc, strutils]
import parseSEG/version
import ./utils/testutils

const
  root = currentSourcePath().parentDir.parentDir
  ex = root / "SEG Spec" / "exampleFiles"
  inglewood = ex / "BO_3D-Inglewood_rev21_v7.sgy"
  s63 = ex / "63.sgd"
  inova = ex / "inova_rev30_5traces.sgd"

let tmp = getTempDir() / "parseseg_tcli"
createDir(tmp)
let exe = tmp / "parseSEG"
block build:
  let (o, code) = execCmdEx(getCurrentCompilerExe().quoteShell & " c --hints:off -d:release " &
    "--nimcache:" & quoteShell(tmp / "cache") & " -o:" & quoteShell(exe) & " " &
    quoteShell(root / "src" / "parseSEG" / "cli.nim"))
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

# ------------------------------------- the demo files (always available) --

block demo_files:
  let demo = demoDir()
  let survey = demo / "survey.sgy"
  let shot = demo / "shot.sgd"
  let rec = demo / "record.sgd"
  let line = demo / "line.sg2"
  let a = ok("info", survey, "--keys")
  doAssert "SEG-Y rev 2.1" in a and "1 (IBM float)" in a and "200 (up to 2001 samples" in a
  let b = ok("info", shot, "--keys")
  doAssert "SEG-D rev 3.0" in b and "5 (up to 4001 samples" in b and "1 shot" in b and
    "CRS stanza" in b and "field rec:   12 .. 12" in b
  doAssert "SEG-D rev 2.0" in ok("info", rec) and "SEG-2 rev 1" in ok("info", line)
  doAssert ok("diag", rec).count("info:") == 2 and "no diagnostics" in ok("diag", shot)
  let d = ok("dump", survey, "--traces=4..5", "--fields=trace.cdpX")
  doAssert d.strip.splitLines[2].startsWith("5\t") and "\t500125" in d
  doAssert "gh3.sourcePointNumber = 99.5" in ok("dump", rec, "--records=0")
  # Conversions between the three standards, and back.
  discard ok("convert", rec, tmp / "demo_rec.sgy", "--rev=1", "--text=ascii")
  doAssert "SEG-Y rev 1.0" in ok("info", tmp / "demo_rec.sgy")
  discard ok("convert", shot, tmp / "demo_shot.sg2", "--to=seg2")
  discard ok("convert", tmp / "demo_shot.sg2", tmp / "demo_shot.sgd", "--to=segd", "--rev=2.1")
  doAssert "SEG-D rev 2.1" in ok("info", tmp / "demo_shot.sgd")
  discard ok("convert", line, tmp / "demo_line.sgy")
  doAssert "24 (up to 1000 samples" in ok("info", tmp / "demo_line.sgy")
  # An edit, undone through the journal.
  let f = fresh(survey)
  doAssert "1 edits written" in ok("edit", f, "t5:trace.sourceX=1200")
  doAssert "\t1200" in ok("dump", f, "--traces=5", "--fields=trace.sourceX")
  discard ok("journal", "rollback", f, f & ".edits.nif")
  doAssert readFile(f) == readFile(survey)

block options_before_the_command_and_usage_errors:
  let survey = demoDir() / "survey.sgy"
  let rec = demoDir() / "record.sgd"
  # An option with its value as the next argument, before the command (the
  # value was taken for the command: "unknown command '0'").
  let d = ok("--traces", "0", "dump", survey)
  doAssert d == ok("dump", survey, "--traces", "0") and d == ok("--traces=0", "dump", survey)
  doAssert "unknown command" in fails(2, "--traces", "0", "frobnicate", survey)
  discard fails(2, "--traces") # no command at all
  # A revision the target standard does not have is a usage error (it ran
  # the conversion and exited 1).
  for r in ["3", "1.1", "2.2", "0.1"]:
    doAssert "SEG-Y revisions are" in fails(2, "convert", survey, tmp / "rev.sgy", "--rev=" & r)
  for r in ["1.0", "2.2", "3.2", "4.0"]:
    doAssert "SEG-D revisions are" in fails(2, "convert", rec, tmp / "rev.sgd", "--rev=" & r)
  doAssert not fileExists(tmp / "rev.sgy") and not fileExists(tmp / "rev.sgd")
  # The help names what the tool accepts.
  let help = ok("help")
  doAssert "SEG-Y, SEG-D and SEG-2" in help.splitLines[0]
  doAssert "--force" in help and "--out" in help

# -------------------------------------------------------- 7.1: inspecting --

sampleBlock usage_and_version:
  doAssert PackageVersion != "unknown" and "parseSEG " & PackageVersion in ok("version")
  doAssert "Usage: parseSEG" in ok("help")
  doAssert "unknown command" in fails(2, "frobnicate")
  doAssert "expected info <file>" in fails(2, "info")
  doAssert "no such file" in fails(2, "info", tmp / "missing.sgy")
  doAssert "unknown option --bogus" in fails(2, "info", inglewood, "--bogus")
  doAssert "Usage" in fails(2)
  writeFile(tmp / "junk.bin", "not seismic data at all")
  doAssert "is not SEG-Y, SEG-D or SEG-2" in fails(1, "info", tmp / "junk.bin")

sampleBlock info:
  let a = ok("info", inglewood, "--keys")
  doAssert "SEG-Y rev 2.1" in a and "1 (IBM float)" in a and "200 (up to 2001 samples" in a
  doAssert "2000.0 µs" in a and "gathers:" in a and "0 fatal, 0 error" in a
  let b = ok("info", inova, "--keys")
  doAssert "SEG-D rev 3.0" in b and "8058" in b and "records:     1" in b and "1 shot" in b
  doAssert "5 (up to 4001 samples" in ok("info", inova)
  doAssert "length:      4000.0 ms" in ok("info", inova) and "field rec:   151 .. 151" in
    ok("info", inova)
  doAssert "coordinates: unknown, CRS stanza (155 chars)" in ok("info", inova)
  doAssert "coordinates: meters, CRS P1/11" in ok("info", inglewood)

sampleBlock dump:
  let d = fails(1, "dump", inglewood, "--traces=4..5", "--fields=trace.sourceX,trace.bogus")
  let lines = d.strip.splitLines
  doAssert lines[0].startsWith("trace\toffset\tsamples") and "trace.sourceX" in lines[0]
  doAssert lines[2].startsWith("5\t374420\t2001") and "\t1704188\t?" in lines[2]
  doAssert "trace.bogus: is not a field" in d
  doAssert ok("dump", inglewood, "--traces=1,3").strip.splitLines.len == 3
  let all = ok("dump", s63, "--all", "--traces=0")
  doAssert "trace.traceNumber = " in all and "ext1.receiverLineNumber = " in all
  # 6.10: the listing, with offsets; record and file headers.
  doAssert "  trace.fileNumber = 63  (@" in all and "ext1.receiverLineNumber = " in all
  let rec = ok("dump", s63, "--records=0")
  doAssert rec.startsWith("record 0") and "gh3.sourcePointNumber = 99.5" in rec and
    "st1cs1.channelSetNumber = 1" in rec and "trace\toffset" notin rec
  let fh = ok("dump", inglewood, "--file")
  doAssert "text: textual header  (@0, 3200 B)" in fh and
    "binary.formatCode = 1  (@3224, 2 B)" in fh
  doAssert "record 1 out of range" in fails(2, "dump", s63, "--records=1")
  let i3 = ok("dump", inova, "--all", "--traces=3")
  doAssert "ext2.tuple1Coord1 = " in i3 and "ext5: userDefined" in i3
  doAssert "out of range" in fails(2, "dump", inglewood, "--traces=200")
  doAssert "bad trace selection" in fails(2, "dump", inglewood, "--traces=x")

sampleBlock diag:
  let d = ok("diag", s63)
  doAssert d.count("info:") == 2 and "array forming" in d
  doAssert "no diagnostics" in ok("diag", s63, "--min=warning")
  let n = ok("diag", s63, "--nif")
  doAssert n.startsWith("(.nif27)") and "(diagnostics" in n
  doAssert fails(2, "diag", s63, "--min=loud").contains("--min must be")

# -------------------------------------------------------- 7.1: converting --

sampleBlock convert:
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
  # --format=0 keeps the format, for SEG-Y as for SEG-D (12.4).
  discard ok("convert", tmp / "le.sgy", tmp / "le0.sgy", "--byte-order=little", "--format=0")
  doAssert "IEEE float32" in ok("info", tmp / "le0.sgy") and "little-endian" in ok("info", tmp / "le0.sgy")
  doAssert "applies to SEG-Y output only" in
    fails(2, "convert", s63, tmp / "x.sgd", "--to=segd", "--descale")
  doAssert "--to is segy, segd or seg2" in fails(2, "convert", s63, tmp / "x.sgy", "--to=segx")
  doAssert "SEG-D revisions are" in # a usage error, not a failed conversion
    fails(2, "convert", s63, tmp / "x.sgd", "--to=segd", "--rev=1.0")
  doAssert "--format: 1234" in fails(2, "convert", s63, tmp / "x.sgd", "--to=segd",
    "--format=1234")
  discard fails(2, "convert", inglewood, inglewood)
  doAssert "--byte-order is" in fails(2, "convert", inglewood, tmp / "x.sgy", "--byte-order=up")
  # SEG-2 (11.2): SEG-D to SEG-2 (by the .sg2 name), then to SEG-Y and SEG-D
  discard ok("convert", inova, tmp / "inova.sg2", "--byte-order=big")
  let i2 = ok("info", tmp / "inova.sg2")
  doAssert "SEG-2 rev 1, big-endian" in i2 and "pointers:    5 of 5 slots" in i2 and
    "UNITS: NONE" in i2 and "NOTE: Converted from SEG-D rev 3.0" in i2, i2
  doAssert "trace.CHANNEL_NUMBER" in ok("dump", tmp / "inova.sg2", "--all", "--traces=0")
  discard ok("convert", tmp / "inova.sg2", tmp / "inova2.sgy")
  doAssert "SEG-Y rev 2.1" in ok("info", tmp / "inova2.sgy")
  discard ok("convert", tmp / "inova.sg2", tmp / "inova2.sgd", "--to=segd", "--rev=3.1")
  doAssert "SEG-D rev 3.1" in ok("info", tmp / "inova2.sgd")
  discard ok("convert", inglewood, tmp / "ingle.dat", "--to=seg2", "--format=4")
  doAssert "format:      4" in ok("info", tmp / "ingle.dat")
  doAssert "SEG-2 formats are 1 to 5" in fails(2, "convert", inglewood, tmp / "x.sg2",
    "--format=7")
  doAssert "does not apply to SEG-2" in fails(2, "convert", inglewood, tmp / "x.sg2", "--rev=1")
  doAssert "little or big" in fails(2, "convert", inglewood, tmp / "x.sg2",
    "--byte-order=pairSwapped")
  doAssert "variable length" in fails(1, "edit", tmp / "inova.sg2", "t0:trace.DELAY=1")

# -------------------------------------------------------- 7.3: editing --

sampleBlock edit_and_journal:
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

sampleBlock headers_export_and_import:
  let f = fresh(inglewood)
  doAssert "200 traces exported" in ok("headers", "export", f, "-o", tmp / "h.nif")
  let h = readFile(tmp / "h.nif")
  doAssert h.startsWith("(.nif27)") and "(standard segy)" in h and "(raw " in h
  doAssert "0 fields written" in ok("headers", "import", f, tmp / "h.nif") # a lossless round trip
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

sampleBlock vendormaps:
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

# ------------------------------------------- Phase 7 review regressions --

sampleBlock survey:
  # 63.sgd's header stations: source 13/99.5, receiver 13/104.
  let sps = tmp / "t.sps"
  writeFile(sps, [
    "H00 SPS format version number   SPS 2.1;",
    "R     13.00    104.00  1G1                     500100.0 6000000.0  12.5 18213250",
    "S     13.00     99.50  1V6                     500000.0 6000400.0  10.0 19001150",
    "XT1          6311     13.00     99.501    1    11     13.00    104.00    104.001",
  ].join("\r\n") & "\r\n")
  let s = ok("survey", sps)
  doAssert "SPS 2.1 (H00)" in s and "CR LF" in s and "1 H, 1 S, 1 R, 1 X, 0 C" in s
  discard ok("survey", sps, "-o", tmp / "t10.sps", "--rev=1.0")
  doAssert "SPS 1.0 (H00)" in ok("survey", tmp / "t10.sps")
  discard ok("survey", tmp / "t10.sps", "-o", tmp / "t21.sps", "--rev=2.1")
  doAssert readFile(tmp / "t21.sps") == readFile(sps), "1.0 -> 2.1 restores the file"
  discard fails(2, "survey", sps, "-o", sps)
  discard fails(2, "survey", sps, "--rev=3")
  for extra in ["", "--overwrite"]:
    let k = if extra.len == 0: ok("keys", s63, "--sps=" & sps)
            else: ok("keys", s63, "--sps=" & sps, extra)
    doAssert "1 X + 0 O relation runs" in k, k
    doAssert "joined:      1 traces, 1 changed; by stations 1" in k, k
    doAssert "\t63\t1\t13\t99.50\t500000\t6000400\t13\t104\t500100" in k, k
    doAssert "412.31" in k
  doAssert "relation runs" in ok("info", s63, "--sps", sps)
  discard fails(2, "keys", s63, "--p1=" & sps, "--decimals=9,1")
  discard fails(2, "keys", s63, "--line-map=oops")
  discard fails(2, "keys", s63, "--sps=" & sps, "--line-map=A=nan")
  discard fails(2, "survey", sps, "--rev=1.0")        # needs -o
  discard fails(2, "survey", sps, "--decimals=1,1")   # P1 only
  discard fails(2, "keys", s63, "--overwrite")        # needs --sps or --p1

sampleBlock survey_apply:
  # 63.sgd converted to SEG-Y keeps its stations (the source point with its
  # scalar, and the lines and points in the fields its Layout stanza names),
  # so the join matches by them, and SEG-Y has fields for the coordinates.
  let sps = tmp / "t.sps" # from the survey block: record 63 -> stations 13/99.5, 13/104
  let path = tmp / "63cli.sgy"
  discard ok("convert", s63, path)
  let original = readFile(path)
  let dry = ok("survey-apply", path, "--sps=" & sps)
  doAssert "would change" in dry and "by stations 1" in dry, dry
  doAssert "receiver X/Y:1 traces" in dry and "rcv station: 0 traces" in dry, dry # 13/104 already
  doAssert readFile(path) == original, "a dry run writes nothing"
  let inPlace = ok("survey-apply", path, "--sps=" & sps, "--in-place")
  doAssert "changed in place" in inPlace and "journal:" in inPlace
  doAssert "\t13\t99.50\t500000\t6000400\t13\t104\t500100\t6000000\t412" in ok("keys", path)
  discard ok("journal", "rollback", path, path & ".edits.nif")
  doAssert readFile(path) == original
  let copy = tmp / "63geo.sgy"
  # The header already holds the survey's stations (13 / 99.5 and 13 / 104):
  # no byte changes, so nothing counts.
  let c = ok("survey-apply", path, "--sps=" & sps, "-o", copy, "--values=stations")
  doAssert "changed in " & copy in c and "src station: 0 traces" in c, c
  doAssert "rounded" notin c, c # sp holds 99.5 exactly, and nothing was written
  doAssert readFile(copy) == original, "the stations were there already"
  doAssert "500100" notin ok("keys", copy), "stations only"
  # SEG-D 2.0 headers already carry the stations and have no coordinate fields.
  let segd = ok("survey-apply", s63, "--sps=" & sps)
  doAssert "rcv station: 0 traces" in segd, segd
  discard fails(2, "survey-apply", s63)                       # needs --sps
  discard fails(2, "survey-apply", s63, "--sps=" & sps, "-o", tmp / "x.sgd", "--in-place")
  discard fails(2, "survey-apply", s63, "--sps=" & sps, "--journal=j")
  discard fails(2, "survey-apply", s63, "--sps=" & sps, "--values=nope")
  discard fails(2, "survey-apply", s63, "--sps=" & sps, "-o", s63)

sampleBlock review_outputs_never_clobber_inputs:
  let f = fresh(inglewood)
  doAssert "is the input file" in fails(2, "headers", "export", f, "-o", f)
  doAssert "is the input file" in fails(2, "vendormap", "scaffold", f, "-o", f)
  doAssert "is the input file" in fails(2, "convert", f, f)
  discard fails(1, "edit", f, "--journal=" & f, "t0:trace.sourceX=1")
  doAssert readFile(f) == readFile(inglewood)
  # A failed conversion leaves an existing destination alone and no partial file.
  writeFile(tmp / "keep.sgy", "precious")
  doAssert "not a SEG-Y format" in fails(2, "convert", inglewood, tmp / "keep.sgy", "--format=99")
  doAssert readFile(tmp / "keep.sgy") == "precious"
  doAssert not fileExists(tmp / "keep.sgy.tmp")
  writeFile(tmp / "half.sgy", readFile(inglewood)[0 ..< 1_000_000])
  discard run("convert", tmp / "half.sgy", tmp / "fromhalf.sgy")

sampleBlock review_option_values_are_required:
  let f = fresh(inglewood)
  doAssert "needs a value" in fails(2, "headers", "import", f, tmp / "h.nif", "-o")
  doAssert readFile(f) == readFile(inglewood)
  doAssert "needs a value" in fails(2, "dump", f, "--traces")
  doAssert "needs a value" in fails(2, "headers", "export", f, "-o")
  doAssert "takes no value" in fails(2, "info", f, "--keys=1")
  doAssert "SEG-Y rev 2.1" in ok("--keys", "info", f) # options before the command

sampleBlock review_edit_validates_first:
  let f = fresh(inglewood)
  for bad in ["bad", "q9:trace.sourceX=1", "t999:trace.sourceX=1", "t5..2:trace.sourceX=1",
      "t0:trace.nope=1", "t0:trace.sourceX=", "r0:binary.jobId=7"]:
    discard fails(2, "edit", f, "t0:trace.sourceX=1200", bad)
    doAssert readFile(f) == readFile(inglewood), bad
    doAssert not fileExists(f & ".edits.nif"), bad
  doAssert "SEG-Y has none" in fails(2, "edit", f, "r0:binary.jobId=7")
  doAssert "out of range (the file has 200 traces)" in fails(2, "edit", f, "t200:trace.sourceX=1")
  writeFile(tmp / "empty.sgy", "")
  doAssert "is not SEG-Y, SEG-D or SEG-2" in fails(1, "edit", tmp / "empty.sgy", "t0:trace.sourceX=1")
  doAssert not fileExists(tmp / "empty.sgy.edits.nif")
  # Number-like text, and big edit batches (one journal sync per batch).
  discard ok("edit", f, "t0:trace.headerName=12345678", "t0..199:trace.groupStatic=3")
  let d = ok("dump", f, "--traces=0", "--all")
  doAssert "trace.headerName = \"12345678\"" in d and "trace.groupStatic = 3" in d
  discard ok("journal", "rollback", f, f & ".edits.nif")
  doAssert readFile(f) == readFile(inglewood)

sampleBlock review_ranges_and_revisions:
  doAssert "out of range" in fails(2, "dump", inglewood, "--traces=0..99999999999")
  doAssert "empty trace range" in fails(2, "dump", inglewood, "--traces=5..2")
  for r in ["256", "258.1", "300", "-1", "2.1.1", "x.y", "2."]:
    discard fails(2, "convert", inglewood, tmp / "r.sgy", "--rev=" & r)
  doAssert "--rev parts are 0..255" in fails(2, "convert", s63, tmp / "r.sgd", "--rev=256.0")
  doAssert "needs a SEG-D or SEG-2 input" in fails(2, "convert", inglewood, tmp / "r.sgd", "--to=segd")
  # The output kind follows the input's content, not its name.
  copyFile(s63, tmp / "d.raw")
  discard ok("convert", tmp / "d.raw", tmp / "fromraw.sgd")
  doAssert "SEG-D rev 3.0" in ok("info", tmp / "fromraw.sgd")

sampleBlock review_exit_codes_and_messages:
  writeFile(tmp / "t3600.sgy", readFile(inglewood)[0 ..< 3600])
  discard fails(1, "dump", tmp / "t3600.sgy")
  doAssert "fatal" in fails(1, "info", tmp / "t3600.sgy")
  discard fails(1, "dump", inglewood, "--fields=trace.bogus")
  createDir(tmp / "adir")
  doAssert "is a directory" in fails(2, "info", tmp / "adir")
  writeFile(tmp / "empty.nif", "")
  doAssert "the document is empty" in fails(1, "headers", "import", inglewood, tmp / "empty.nif")
  doAssert "no vendor maps found in" in ok("vendormap", "list", "--map=" & tmp / "adir")
  doAssert "no unmapped vendor areas" in ok("vendormap", "scaffold", inglewood, "-o",
    tmp / "none.nif")
  doAssert not fileExists(tmp / "none.nif")
  let f = fresh(inglewood)
  discard ok("headers", "export", f, "-o", tmp / "self.nif")
  doAssert "nothing written" in fails(1, "headers", "import", f, tmp / "self.nif", "-o",
    tmp / "self.nif")

echo "tcli: ok"
