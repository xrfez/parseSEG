## The `parseSEG` command line tool (Phase 7), written against the public
## API (`import parseSEG`), so it doubles as an end-to-end test of it.
## Build with `nim cli` (bin/parseSEG). `parseSEG help` lists the commands.
##
## Exit status: 0 success; 1 the command ran but reported errors (an error or
## fatal diagnostic); 2 a usage error.

import std/[os, strutils, sequtils, tables, math, streams]
import ../parseSEG
import ./common/niftext

const
  Usage = """
parseSEG """ & PackageVersion & """ — read, index, edit and convert SEG-Y and SEG-D

Usage: parseSEG <command> [options] <arguments>

Inspecting
  info <file> [--keys] [SURVEY] what the file is: standard, revision, format,
                                records, traces, samples, record length, field
                                records, coordinate units and CRS, gathers,
                                diagnostics
  dump <file> [--traces=SEL] [--fields=a,b,...] [--all] [--records=SEL] [--file]
                                trace headers as a table (SEL: 5 | 0..9 | 1,4,7);
                                --fields picks header fields (trace.sourceX,
                                ext1.receiverLineNumber, ...); --all lists
                                every field of every block of the traces, with
                                its byte offset and size; --records and --file
                                list the SEG-D record and the file headers
  diag <file> [--nif] [--min=info|warning|error|fatal]
                                the diagnostics of indexing the file
  keys <file> [--traces=SEL] [SURVEY]
                                per-trace geometry: record, channel, source
                                and receiver stations and coordinates, offset

Survey files (SPS 1.0/2.1, SEG P1 1983; docs/spec/sps.md, p1_p2_p3.md)
  SURVEY options join survey geometry to the traces (info, keys):
    --sps=F[,F...]              SPS R/S/X files: stations, and X relations
                                (field record + channel -> stations)
    --p1=F[,F...]               SEG P1 shotpoints (sources)
    --decimals=G,D              P1 implicit decimals: grid, depth/elevation
    --elevation                 P1 columns 62-66 are elevation (else depth)
    --line-map=NAME=N[,...]     text line names -> line numbers
    --trailing-digits           unmapped names use their trailing digits
    --multi-component           SPS channel increment k: k components/station
    --overwrite                 replace stations and coordinates already known
  survey <file> [-o out] [--rev=1.0|2.1] [--decimals=G,D]
                                summary and diagnostics of an SPS or P1 file;
                                with -o, write it back (SPS: in revision --rev)

Converting
  convert <src> <dst> [--to=segy|segd] [--rev=R] [--format=N]
          [--byte-order=big|little|pairSwapped] [--text=ebcdic|ascii]
          [--descale] [--no-station-header]
                                SEG-Y/SEG-D to SEG-Y (revision 0, 1, 2.0, 2.1;
                                default 2.1), or SEG-D to SEG-D (--to=segd,
                                revision 2.0, 2.1, 3.0 or 3.1; default 3.0). The
                                target is segd when both files end in .sgd/.segd

Editing (in place, size-preserving, journaled; see `journal`)
  edit <file> [--journal=J] <assignment>...
                                assignment: <scope>:<block>.<field>=<value>,
                                scope t5 | t0..9 | r0 (SEG-D record) | file;
                                e.g. t5:trace.sourceX=1200 file:binary.jobId=7
  headers export <file> [-o out.nif] [--fields-only]
                                every header field as NIF (with raw bytes)
  headers import <file> <patch.nif> [-o new-file] [--journal=J] [--dry-run]
                                apply an (edited) export: only changed fields
                                are written, in place or into a copy
  journal apply|rollback <file> <journal>
                                re-apply or undo journaled edits

Vendor maps (NIF plugins for vendor header areas; docs/design/vendor_maps.md)
  vendormap check <map.nif>...  load and validate maps
  vendormap list [<file>] [--map=PATH]
                                the maps on the search path (vendormaps/,
                                PARSESEG_VENDOR_PATH, --map), and which match
  vendormap apply <file> [--map=PATH] [--traces=SEL]
                                decode the vendor areas, printed as NIF
  vendormap scaffold <file> [-o map.nif] [--map=PATH] [--name=N]
                                a skeleton map for every unmapped vendor area

Other
  version | help
"""

type
  UsageError = object of CatchableError
    ## The command line is wrong: exit status 2.
  CommandError = object of CatchableError
    ## The command cannot run on its input (an unreadable or unrecognized
    ## file): exit status 1.

proc usage(msg: string) {.noinline, noreturn.} =
  raise newException(UsageError, msg)

proc cannot(msg: string) {.noinline, noreturn.} =
  raise newException(CommandError, msg)

type Args = object
  pos: seq[string]
  opts: seq[(string, string)]

const ValueOptions = ["o", "out", "journal", "traces", "fields", "rev", "format", "to",
  "byte-order", "text", "min", "map", "name", "sps", "p1", "decimals", "line-map", "records"]

const Flags = ["force", "keys", "all", "nif", "descale", "no-station-header", "fields-only",
  "dry-run", "help", "h", "elevation", "trailing-digits", "multi-component", "overwrite", "file"]

const SurveyOptions = ["sps", "p1", "decimals", "line-map", "elevation", "trailing-digits",
  "multi-component", "overwrite"]

proc parseArgs(args: seq[string]): Args =
  ## `--key=value`, `--key:value` or `--key value` (and `-o value`) for value
  ## options; flags take no value; `--` ends the options.
  var i = 0
  var optionsDone = false
  while i < args.len:
    let x = args[i]
    if optionsDone or x.len < 2 or x[0] != '-':
      result.pos.add x
    elif x == "--":
      optionsDone = true
    else:
      let body = if x.startsWith("--"): x[2..^1] else: x[1..^1]
      let sep = body.find({'=', ':'})
      let key = if sep >= 0: body[0 ..< sep] else: body
      var val = ""
      if sep >= 0:
        val = body[sep + 1 .. ^1]
      elif key notin Flags and key in ValueOptions and i + 1 < args.len and
          not (args[i + 1].startsWith("-") and args[i + 1].len > 1 and
               args[i + 1][1] notin Digits):
        val = args[i + 1]
        inc i
      if key in ValueOptions and val.len == 0:
        usage("option " & x & " needs a value")
      if key in Flags and sep >= 0:
        usage("option --" & key & " takes no value")
      result.opts.add (key, val) # an unknown option is reported by its command
    inc i

func has(a: Args, key: string): bool = a.opts.anyIt(it[0] == key)

func get(a: Args, key: string, default = ""): string =
  result = default
  for (k, v) in a.opts:
    if k == key: result = v

proc onlyOptions(a: Args, allowed: openArray[string]) =
  for (k, _) in a.opts:
    if k notin allowed: usage("unknown option --" & k)

proc needArgs(a: Args, n: int, what: string) =
  if a.pos.len != n: usage("expected " & what)

proc parseIntOpt(s, name: string): int =
  try: parseInt(s)
  except ValueError: usage("--" & name & " must be an integer, not '" & s & "'")

proc failed(log: DiagLog): bool = log.count(sevError) + log.count(sevFatal) > 0

proc printLog(log: DiagLog, minSeverity = sevWarning, toErr = true) =
  for d in log:
    if d.severity >= minSeverity:
      var where: seq[string]
      if d.loc.record >= 0: where.add "record " & $d.loc.record
      if d.loc.trace >= 0: where.add "trace " & $d.loc.trace
      if d.loc.field.len > 0: where.add d.loc.field
      if d.offset >= 0: where.add "byte " & $d.offset
      let line = $d.severity & ": " & d.msg &
        (if where.len > 0: " [" & where.join(", ") & "]" else: "")
      if toErr: stderr.writeLine line else: stdout.writeLine line

proc checkInput(path: string) =
  if dirExists(path): usage(path & " is a directory")
  if not fileExists(path): usage("no such file: " & path)
  try:
    var fh = open(path, fmRead)
    fh.close()
  except IOError:
    cannot("cannot read " & path & " (" & osErrorMsg(osLastError()) & ")")

proc openFile(path: string, keys = false): SeismicFile =
  checkInput(path)
  result = openSeismic(path, keys = keys)
  if not result.index.detected:
    printLog(result.index.log, sevError)
    cannot(path & " is neither SEG-Y nor SEG-D")

proc refuseSame(output, input: string) =
  if output == input or (fileExists(output) and fileExists(input) and sameFile(output, input)):
    usage("the output " & output & " is the input file")

# ------------------------------------------------------------------- info --

func formatName(f: SampleFormat): string =
  $ord(f) & " (" & (case f
    of sfIbm32: "IBM float"
    of sfFixedGain: "fixed point with gain"
    of sfFloat32: "IEEE float32"
    of sfFloat64: "IEEE float64"
    else: ($f)[2..^1].toLowerAscii) & ")"

proc parseDecimals(a: Args): (int, int) =
  result = (0, 0)
  if a.has("decimals"):
    let parts = a.get("decimals").split(',')
    if parts.len != 2: usage("--decimals needs G,D (e.g. 1,1)")
    result = (parseIntOpt(parts[0], "decimals"), parseIntOpt(parts[1], "decimals"))
    if result[0] notin 0..8 or result[1] notin 0..8: usage("--decimals must be 0-8")

proc wantsSurvey(a: Args): bool =
  ## Whether survey files are to be joined; their options need one.
  result = a.has("sps") or a.has("p1")
  if not result:
    for o in SurveyOptions:
      if a.has(o): usage("--" & o & " needs --sps or --p1")

proc loadSurvey(a: Args, log: var DiagLog): SurveyGeometry =
  ## The survey geometry named by the SURVEY options.
  result.trailingDigits = a.has("trailing-digits")
  if a.has("line-map"):
    for item in a.get("line-map").split(','):
      let kv = item.split('=')
      if kv.len != 2 or kv[0].strip.len == 0: usage("--line-map needs NAME=N[,NAME=N...]")
      let v = try: parseFloat(kv[1].strip)
              except ValueError: usage("--line-map: '" & kv[1] & "' is not a number")
      if v.isNaN or v.classify in {fcInf, fcNegInf}:
        usage("--line-map: '" & kv[1] & "' is not finite")
      result.mapLine(kv[0], v)
  result.multiComponent = a.has("multi-component")
  let (grid, depth) = parseDecimals(a)
  for path in a.get("sps").split(','):
    if path.len > 0:
      checkInput(path)
      let f = readSps(path)
      log.add f.log
      result.addSps(f)
  for path in a.get("p1").split(','):
    if path.len > 0:
      checkInput(path)
      let f = readP1(path, P1Options(gridDecimals: grid, depthDecimals: depth))
      log.add f.log
      result.addP1(f, a.has("elevation"))
  log.add result.log

proc joinSurvey(a: Args, f: var SeismicFile): DiagLog =
  ## Joins the SURVEY options' geometry to `f` (opened with keys) and prints
  ## what was joined.
  let g = loadSurvey(a, result)
  let n = f.index.applySurvey(g, a.has("overwrite"))
  echo "survey:      ", g.table.sources.len, " sources, ", g.table.receivers.len,
    " receivers, ", g.relationCount, " relation runs; ", n, " traces updated"

proc info(a: Args): int =
  a.onlyOptions(@["keys"] & @SurveyOptions)
  a.needArgs(1, "info <file>")
  var f = openFile(a.pos[0], keys = a.has("keys") or a.wantsSurvey)
  defer: f.close()
  let surveyLog = if a.wantsSurvey: joinSurvey(a, f) else: DiagLog()
  template ix: untyped = f.index
  echo "file:        ", a.pos[0], " (", getFileSize(a.pos[0]), " bytes)"
  if f.kind == skSegy:
    template s: untyped = ix.segy
    echo "standard:    SEG-Y rev ", s.revision, ", ", s.byteOrder, "-endian",
      (if s.byteOrderDeclared: " (declared)" else: "")
    echo "format:      ", (if s.format.isSome: formatName(s.format.get) else: "unknown")
  elif f.kind == skSeg2:
    template s: untyped = ix.seg2
    echo "standard:    SEG-2 rev ", s.revision, ", ", s.order, "-endian"
    var fmts: seq[string]
    for c in ix.codecs:
      fmts.add (if c.seg2Format.isSome: $ord(c.seg2Format.get) else: "undecodable")
    echo "format:      ", fmts.join(", ")
  else:
    var revs, fmts: seq[string]
    for r in ix.segdRecords:
      let rv = $r.revision
      if rv notin revs: revs.add rv
      let fm = if r.format.isSome: $ord(r.format.get)
               else: "unknown (" & $r.gh1.formatCode & ")"
      if fm notin fmts: fmts.add fm
    echo "standard:    SEG-D rev ", revs.join(", "),
      (if ix.segdLabel.isSome: ", label " & ix.segdLabel.get.revision & " " &
        ix.segdLabel.get.structure
       else: "")
    echo "format:      ", fmts.join(", ")
    echo "records:     ", ix.segdRecords.len
  var intervals: seq[float64]
  for i in 0..<f.len:
    let dt = f.sampleIntervalUs(i)
    if dt notin intervals: intervals.add dt
    if intervals.len > 4: break
  echo "traces:      ", f.len, " (up to ", ix.maxSamples, " samples, interval ",
    intervals.mapIt($it & " µs").join(", "), ")"
  let s = f.summary
  echo "length:      ", (if s.recordLengthMs.isNaN: "varies" else: $s.recordLengthMs & " ms")
  if s.firstFieldRecord >= 0:
    echo "field rec:   ", s.firstFieldRecord, " .. ", s.lastFieldRecord
  echo "coordinates: ", s.coordinateUnits,
    (if s.crsFormat != ctNone: ", CRS " & $s.crsFormat & " (" & $f.crsText.len & " chars)"
     else: "")
  if a.has("keys"):
    var kinds: CountTable[GatherKind]
    for g in ix.gathers: kinds.inc g.kind
    var parts: seq[string]
    for k in GatherKind:
      if k in kinds: parts.add $kinds[k] & " " & $k
    echo "gathers:     ", parts.join(", ")
  echo "diagnostics: ", ix.log.count(sevFatal), " fatal, ", ix.log.count(sevError), " error, ",
    ix.log.count(sevWarning), " warning, ", ix.log.count(sevInfo), " info"
  printLog(ix.log, sevError)
  printLog(surveyLog, sevWarning)
  if ix.log.failed or surveyLog.failed: 1 else: 0

# ------------------------------------------------------------------- dump --

proc parseSelection(s: string, n: int, unit = "trace", all = true): seq[int] =
  ## `5`, `0..9`, `1,4,7` (or every index when `s` is empty and `all`); each
  ## index is checked against `n` before anything is expanded.
  if s.len == 0:
    if all: return toSeq(0..<n)
    usage("empty " & unit & " selection")
  template check(i: int) =
    if i < 0 or i >= n:
      usage(unit & " " & $i & " out of range (the file has " & $n & " " & unit & "s)")
  for part in s.split(','):
    let p = part.strip
    let dots = p.find("..")
    var a, b: int
    try:
      if dots >= 0:
        a = parseInt(p[0 ..< dots])
        b = parseInt(p[dots + 2 .. ^1])
      else:
        a = parseInt(p)
        b = a
    except ValueError:
      usage("bad " & unit & " selection '" & p & "' (use 5, 0..9 or 1,4,7)")
    if a > b: usage("empty " & unit & " range '" & p & "' (" & $a & " > " & $b & ")")
    check(a)
    check(b)
    for i in a..b: result.add i

proc printListing(title: string, l: HeaderListing) =
  echo title
  for r in l:
    let where = "  (@" & $r.offset & ", " & $r.size & " B)"
    if r.field.len > 0: echo "  ", r.blockName, ".", r.field, " = ", r.value, where
    else: echo "  ", r.blockName, ": ", r.value.text, where

proc dump(a: Args): int =
  ## Exit 1 when the index has errors or a requested field is unknown.
  a.onlyOptions(["traces", "fields", "all", "records", "file"])
  a.needArgs(1, "dump <file>")
  var f = openFile(a.pos[0])
  defer: f.close()
  printLog(f.index.log, sevError)
  result = if f.index.log.failed: 1 else: 0
  let sel = parseSelection(a.get("traces"), f.len)
  let listings = a.has("file") or a.has("records")
  if a.has("file"): printListing("file", f.fileHeaders)
  if a.has("records"):
    for r in parseSelection(a.get("records"), f.recordCount, "record"):
      printListing("record " & $r, f.recordHeaders(r))
  if a.has("all"):
    for t in sel: printListing("trace " & $t, f.traceHeaders(t))
    return
  if listings and not (a.has("traces") or a.has("fields")): return
  let fields = if a.has("fields"): a.get("fields").split(',').mapIt(it.strip)
               else: @[]
  var header = @["trace", "offset", "samples", "record", "chset"]
  header.add fields
  echo header.join("\t")
  for t in sel:
    let e = f.index.entries[t]
    var row = @[$t, $e.offset, $e.numSamples, $e.record,
      (if e.channelSetIndex < 0: "-" else: $e.channelSetIndex)]
    for name in fields:
      let v = f.findTraceField(t, name)
      row.add(if v.isSome: $v.get else: "?")
    echo row.join("\t")
  for name in fields:
    if sel.len > 0:
      try: discard f.traceField(sel[0], name)
      except ValueError as e:
        stderr.writeLine "error: ", e.msg
        result = 1

# ------------------------------------------------------------------- diag --

proc diag(a: Args): int =
  a.onlyOptions(["nif", "min"])
  a.needArgs(1, "diag <file>")
  var f = openFile(a.pos[0])
  defer: f.close()
  let minSev = try: parseEnum[Severity](a.get("min", "info"))
               except ValueError: usage("--min must be info, warning, error or fatal")
  var log: DiagLog
  for d in f.index.log:
    if d.severity >= minSev: log.add d
  if a.has("nif"): stdout.write log.toNif
  else:
    printLog(log, minSev, toErr = false)
    if log.len == 0: echo "no diagnostics"
  if f.index.log.failed: 1 else: 0

# ---------------------------------------------------------------- convert --

proc isSegdName(p: string): bool = p.toLowerAscii.endsWith(".sgd") or
  p.toLowerAscii.endsWith(".segd")

proc sourceKind(path: string): SeismicKind =
  ## What the file is, from its content.
  var head = newString(8192)
  var fh = open(path, fmRead)
  head.setLen fh.readBuffer(addr head[0], head.len)
  fh.close()
  result = detectKind(head.toOpenArrayByte(0, head.len - 1))
  if result == skUnknown: cannot(path & " is neither SEG-Y nor SEG-D")

proc parseRev(s: string, minParts, maxParts: int, what: string): (uint8, uint8) =
  let parts = s.split('.')
  if parts.len notin minParts..maxParts: usage("--rev must look like " & what)
  var n: array[2, int]
  for i, p in parts:
    if p.len == 0 or not p.allCharsInSet(Digits): usage("--rev must look like " & what)
    n[i] = try: parseInt(p) except ValueError: 256
    if n[i] > 255: usage("--rev parts are 0..255, not " & p)
  (uint8(n[0]), uint8(n[1]))

proc convertCmd(a: Args): int =
  a.onlyOptions(["to", "rev", "format", "byte-order", "text", "descale", "no-station-header"])
  a.needArgs(2, "convert <src> <dst>")
  let (src, dst) = (a.pos[0], a.pos[1])
  checkInput(src)
  refuseSame(dst, src)
  let kind = sourceKind(src)
  if kind == skSeg2: cannot(src & ": conversion is not supported for SEG-2 yet")
  let to = a.get("to", if kind == skSegd and isSegdName(dst): "segd" else: "segy")
  var log: DiagLog
  case to
  of "segd":
    if kind != skSegd: usage("--to=segd needs a SEG-D input; " & src & " is SEG-Y")
    for k in ["byte-order", "text", "descale", "no-station-header"]:
      if a.has(k): usage("--" & k & " applies to SEG-Y output only")
    var o = SegdConvertOptions()
    let (ma, mi) = parseRev(a.get("rev", "3.0"), 2, 2, "2.0, 2.1, 3.0 or 3.1")
    o.revision = SegdRevision(major: ma, minor: mi)
    let code = parseIntOpt(a.get("format", "0"), "format")
    if code != 0:
      let f = toSegdFormat(code)
      if f.isNone: usage("--format: " & $code & " is not a SEG-D demultiplexed format")
      o.format = targetFormat(f.get)
    log = convertSegdRevision(src, dst, o)
  of "segy":
    var o = ConvertOptions()
    if a.has("rev"):
      let (ma, mi) = parseRev(a.get("rev"), 1, 2, "0, 1, 2.0 or 2.1")
      o.revision = SegyRevision(major: ma, minor: mi)
    let code = parseIntOpt(a.get("format", "0"), "format")
    if code != 0: # 0 keeps the format, as for SEG-D
      let f = toSampleFormat(code)
      if f.isNone: usage("--format: " & $code & " is not a SEG-Y format code")
      o.format = targetFormat(f.get)
    try:
      o.byteOrder = parseEnum[ByteOrder](a.get("byte-order", "big"))
      o.textEncoding = parseEnum[TextEncoding](a.get("text", "ebcdic"))
    except ValueError:
      usage("--byte-order is big, little or pairSwapped; --text is ebcdic or ascii")
    o.applyDescale = a.has("descale")
    o.stationHeader = not a.has("no-station-header")
    log = convertFile(src, dst, o)
  else: usage("--to is segy or segd")
  printLog(log, sevWarning)
  if log.failed:
    stderr.writeLine "parseSEG: conversion ", (if log.isFatal: "failed; " & dst &
      " was not written" else: "had errors")
    1
  else:
    echo dst, ": written (", log.count(sevInfo), " notes, ", log.count(sevWarning),
      " warnings; `parseSEG diag` lists the file's own)"
    0

# ------------------------------------------------------------------- edit --

proc parseValue(s: string): FieldValue =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"': return toFieldValue(s[1 .. ^2])
  try: return toFieldValue(parseBiggestInt(s))
  except ValueError: discard
  try: return toFieldValue(parseFloat(s))
  except ValueError: discard
  toFieldValue(s)

type Assignment = object
  scope: HeaderScope
  targets: seq[int]  ## traces or records
  name: string
  value: FieldValue

proc parseAssignments(f: SeismicFile, args: seq[string]): seq[Assignment] =
  ## Every assignment checked (syntax, scope, selection, field) before any edit.
  for asg in args:
    let colon = asg.find(':')
    let eq = asg.find('=')
    if colon <= 0 or eq < colon or eq == colon + 1:
      usage("bad assignment '" & asg & "' (want <scope>:<block>.<field>=<value>)")
    let scope = asg[0 ..< colon]
    var x = Assignment(name: asg[colon + 1 ..< eq])
    let raw = asg[eq + 1 .. ^1]
    if raw.len == 0: usage("assignment '" & asg & "' has no value")
    x.value = parseValue(raw)
    if scope == "file":
      x.scope = hsFile
    elif scope.len > 1 and scope[0] == 't':
      x.scope = hsTrace
      x.targets = parseSelection(scope[1..^1], f.len, "trace", all = false)
    elif scope.len > 1 and scope[0] == 'r':
      x.scope = hsRecord
      if f.kind != skSegd:
        usage("record scopes (r0, ...) are for SEG-D; " & $f.kind & " has none")
      x.targets = parseSelection(scope[1..^1], f.index.segdRecords.len, "record", all = false)
    else:
      usage("bad scope '" & scope & "' (t5, t0..9, r0 or file)")
    let cur = try:
        case x.scope
        of hsFile: f.fileField(x.name)
        of hsRecord: f.recordField(x.targets[0], x.name)
        of hsTrace: f.traceField(x.targets[0], x.name)
      except ValueError as e: usage(e.msg)
    # A text field takes the value as written, even when it looks like a number.
    if cur.kind == fvText and x.value.kind != fvText:
      x.value = toFieldValue(if raw.len >= 2 and raw[0] == '"' and raw[^1] == '"': raw[1 .. ^2]
                             else: raw)
    result.add x

proc edit(a: Args): int =
  a.onlyOptions(["journal"])
  if a.pos.len < 2: usage("expected edit <file> <assignment>...")
  let path = a.pos[0]
  var plan: seq[Assignment]
  block:
    var f = openFile(path) # checked read-only first: nothing is written on a usage error
    plan = parseAssignments(f, a.pos[1..^1])
  var ed = openEditor(path, a.get("journal"))
  var refused = 0
  try:
    ed.beginBatch()
    for x in plan:
      var ok = true
      case x.scope
      of hsFile: ok = ed.setFileField(x.name, x.value)
      of hsTrace:
        for i in x.targets: ok = ed.setTraceField(i, x.name, x.value) and ok
      of hsRecord:
        for i in x.targets: ok = ed.setRecordField(i, x.name, x.value) and ok
      if not ok: inc refused
  finally:
    ed.close()
  printLog(ed.log, sevWarning)
  echo ed.edits, " edits written; journal ", ed.journalPath
  if refused > 0 or ed.log.failed: 1 else: 0

proc headers(a: Args): int =
  if a.pos.len == 0: usage("expected headers export|import ...")
  case a.pos[0]
  of "export":
    a.onlyOptions(["o", "out", "fields-only"])
    if a.pos.len != 2: usage("expected headers export <file> [-o out.nif]")
    var f = openFile(a.pos[1])
    defer: f.close()
    let outPath = a.get("o", a.get("out", a.pos[1] & ".headers.nif"))
    refuseSame(outPath, a.pos[1])
    exportHeaders(f, outPath, raw = not a.has("fields-only"))
    echo outPath, ": ", f.len, " traces exported"
    0
  of "import":
    a.onlyOptions(["o", "out", "journal", "dry-run", "force"])
    if a.pos.len != 3: usage("expected headers import <file> <patch.nif>")
    checkInput(a.pos[1])
    checkInput(a.pos[2])
    let dry = a.has("dry-run")
    let r = importHeaders(a.pos[1], a.pos[2], ImportOptions(outPath: a.get("o", a.get("out")),
      journal: a.get("journal"), dryRun: dry, force: a.has("force"),
      onChange: proc (c: HeaderChange) =
        echo c.scope, " ", c.index, " ", c.name, ": ", c.old, " -> ", c.new))
    printLog(r.log, sevWarning)
    if dry:
      echo r.applied, " changed fields (dry run: nothing written)"
    elif r.log.isFatal and r.applied == 0:
      echo "nothing written"
    else:
      echo r.applied, " fields written", (if r.refused > 0: ", " & $r.refused & " refused"
                                          else: ""),
        (if r.log.isFatal: " before the import stopped" else: "")
    if r.log.failed: 1 else: 0
  else: usage("expected headers export|import")

proc journal(a: Args): int =
  a.onlyOptions([])
  if a.pos.len != 3 or a.pos[0] notin ["apply", "rollback"]:
    usage("expected journal apply|rollback <file> <journal>")
  for p in a.pos[1..2]:
    if not fileExists(p): usage("no such file: " & p)
  let log = if a.pos[0] == "apply": applyJournal(a.pos[1], a.pos[2])
            else: rollbackJournal(a.pos[1], a.pos[2])
  printLog(log, sevWarning)
  if log.failed: 1
  else:
    echo a.pos[0], ": done"
    0

# -------------------------------------------------------------- vendormap --

proc mapPaths(a: Args): seq[string] =
  ## The vendor map search path plus every `--map`.
  result = vendorSearchPath()
  for (k, v) in a.opts:
    if k == "map": result.add v

proc loadRegistry(a: Args, log: var DiagLog): VendorRegistry =
  result.loadVendorMaps(a.mapPaths, log)

func `$`(v: VendorValue): string =
  result = case v.kind
    of vvInt: $v.intVal
    of vvFloat: $v.floatVal
    of vvText: nifString(v.text)
    of vvBytes:
      var h = "\""
      for b in v.bytes: h.add toHex(b, 2)
      h & "\""
  if v.label.len > 0: result.add " (label " & nifString(v.label) & ")"
  if v.flags.len > 0: result.add " (flags " & v.flags.join(" ") & ")"
  if v.unit.len > 0: result.add " (unit " & nifString(v.unit) & ")"

proc printBlocks(indent: string, blocks: seq[VendorBlock]) =
  for b in blocks:
    stdout.write indent, "(block ", nifString(b.mapName), " ", b.name
    for f in b.fields: stdout.write "\n", indent, "  (f ", f.name, " ", $f.value, ")"
    stdout.write ")\n"

proc vendormap(a: Args): int =
  if a.pos.len == 0: usage("expected vendormap check|list|apply|scaffold ...")
  case a.pos[0]
  of "check":
    a.onlyOptions([])
    if a.pos.len < 2: usage("expected vendormap check <map.nif>...")
    result = 0
    for p in a.pos[1..^1]:
      try:
        let m = loadVendorMap(readFile(p), p)
        let problems = m.checkVendorMap
        echo p, ": ", m.name, " version ", m.version, ", ", m.targets.len, " targets",
          (if problems.len == 0: ", ok" else: "")
        for x in problems: echo "  note: ", x
      except CatchableError as e:
        echo p, ": not loaded: ", e.msg
        result = 1
  of "list":
    a.onlyOptions(["map"])
    if a.pos.len > 2: usage("expected vendormap list [<file>]")
    var log: DiagLog
    let reg = loadRegistry(a, log)
    printLog(log, sevWarning)
    var ctx: VendorContext
    var haveCtx = false
    if a.pos.len == 2:
      var f = openFile(a.pos[1])
      defer: f.close()
      case f.kind
      of skSegd:
        if f.index.segdRecords.len > 0:
          ctx = vendorContext(f.index.segdRecords[0])
          haveCtx = true
      of skSegy:
        ctx = vendorContext(f.index.segy)
        haveCtx = true
      of skSeg2, skUnknown: discard # no vendor maps for SEG-2 yet
    if reg.maps.len == 0:
      echo "no vendor maps found in: ", a.mapPaths.join(", ")
    for m in reg.maps:
      echo m.name, " (version ", m.version, ", ", m.targets.len, " targets) ", m.source,
        (if haveCtx: (if m.applies(ctx): "  [matches]" else: "  [does not match]") else: "")
    result = if log.failed: 1 else: 0
  of "apply":
    a.onlyOptions(["map", "traces"])
    if a.pos.len != 2: usage("expected vendormap apply <file>")
    var log: DiagLog
    let reg = loadRegistry(a, log)
    let path = a.pos[1]
    var f = openFile(path)
    let n = f.len
    let kind = f.kind
    f.close()
    if kind == skSeg2: cannot(path & ": vendor maps are not supported for SEG-2 yet")
    let sel = parseSelection(a.get("traces"), n)
    var want = newSeq[bool](n)
    for i in sel: want[i] = true
    echo "(.nif27)\n(vendor ", nifString(path.extractFilename)
    var src: RecordSource = openDiskSource(path)
    try:
      var k = 0
      if kind == skSegd:
        var r = openSegd(src, headersOnly = true)
        while r.nextRecord():
          echo " (record ", r.record.index
          printBlocks("  ", decodeVendorAreas(reg, r.record, log, path))
          var t: SegdTrace
          while r.readTrace(t):
            if k < n and want[k]:
              let blocks = decodeVendorAreas(reg, r.record, t, log, path)
              if blocks.len > 0:
                echo "  (trace ", k
                printBlocks("   ", blocks)
                echo "  )"
            inc k
          echo " )"
      else:
        var r = openSegy(src)
        printBlocks(" ", decodeVendorAreas(reg, r.file, log, path))
        var t: SegyTrace
        while r.readTrace(t):
          if k < n and want[k]:
            let blocks = decodeVendorAreas(reg, r.file, t, log, path)
            if blocks.len > 0:
              echo " (trace ", k
              printBlocks("  ", blocks)
              echo " )"
          inc k
    finally:
      src.close()
    echo ")"
    printLog(log, sevWarning)
    result = if log.failed: 1 else: 0
  of "scaffold":
    a.onlyOptions(["map", "o", "out", "name"])
    if a.pos.len != 2: usage("expected vendormap scaffold <file> [-o map.nif]")
    checkInput(a.pos[1])
    let outPath = a.get("o", a.get("out"))
    if outPath.len > 0: refuseSame(outPath, a.pos[1])
    var log: DiagLog
    let reg = loadRegistry(a, log)
    printLog(log, sevWarning)
    let s = scaffoldVendorMap(a.pos[1], reg)
    if s.len == 0:
      echo "no unmapped vendor areas",
        (if outPath.len > 0: "; " & outPath & " not written" else: "")
    elif outPath.len == 0: stdout.write s.toNif(a.get("name"))
    else:
      writeFile(outPath, s.toNif(a.get("name")))
      echo outPath, ": ", s.len, " unmapped vendor areas"
    result = if log.failed: 1 else: 0
  else: usage("expected vendormap check|list|apply|scaffold")

# ------------------------------------------------------------ keys, survey --

proc fmtNum(v: float64): string =
  if v.isNaN: "-" elif v == round(v) and abs(v) < 1e15: $int64(v) else: formatFloat(v, ffDecimal, 2)

proc keysCmd(a: Args): int =
  a.onlyOptions(@["traces"] & @SurveyOptions)
  a.needArgs(1, "keys <file>")
  var f = openFile(a.pos[0], keys = true)
  defer: f.close()
  let surveyLog = if a.wantsSurvey: joinSurvey(a, f) else: DiagLog()
  let sel = if f.len == 0 and not a.has("traces"): @[]
            else: parseSelection(a.get("traces", "0.." & $(min(f.len, 10) - 1)), f.len)
  echo ["trace", "record", "channel", "srcLine", "srcPoint", "srcX", "srcY", "rcvLine",
    "rcvPoint", "rcvX", "rcvY", "offset"].join("\t")
  for i in sel:
    let k = f.index.keys[i]
    echo [$i, fmtNum(k.record), fmtNum(k.channel), fmtNum(k.srcLine), fmtNum(k.srcPoint),
      fmtNum(k.srcX), fmtNum(k.srcY), fmtNum(k.rcvLine), fmtNum(k.rcvPoint), fmtNum(k.rcvX),
      fmtNum(k.rcvY), fmtNum(k.offset)].join("\t")
  printLog(f.index.log, sevError)
  printLog(surveyLog, sevWarning)
  if f.index.log.failed or surveyLog.failed: 1 else: 0

proc isSps(path: string): bool =
  ## SPS or SEG P1, from the shape of the data records (`looksLikeSps`).
  let s = newFileStream(path, fmRead)
  if s == nil: cannot("cannot read " & path)
  try: looksLikeSps(s)
  finally: s.close()

proc surveyCmd(a: Args): int =
  a.onlyOptions(["o", "out", "rev", "decimals"])
  a.needArgs(1, "survey <file>")
  let path = a.pos[0]
  checkInput(path)
  let output = a.get("o", a.get("out"))
  if output.len > 0: refuseSame(output, path)
  elif a.has("rev"): usage("--rev needs -o (the output file)")
  var rev = spsAuto
  case a.get("rev")
  of "": discard
  of "1.0", "1": rev = sps10
  of "2.1": rev = sps21
  else: usage("--rev must be 1.0 or 2.1")
  var log: DiagLog
  if isSps(path):
    if a.has("decimals"): usage("--decimals applies to P1 files only")
    let f = readSps(path)
    log.add f.log
    var kinds: array[SpsPointKind, int]
    for p in f.points: inc kinds[p.kind]
    echo "file:        ", path
    echo "standard:    SPS ", f.revision,
      (if f.revisionDeclared: " (H00)" else: " (from the columns)"),
      ", ", f.layout, (if f.crlf: ", CR LF" else: "")
    echo "records:     ", f.headers.len, " H, ", kinds[pkSource], " S, ", kinds[pkReceiver], " R, ",
      f.relations.len, " X, ", f.comments.len, " C"
    if output.len > 0:
      log.add writeSps(f, output, SpsWriteOptions(revision: rev))
  else:
    if a.has("rev"): usage("--rev applies to SPS files only")
    let (grid, depth) = parseDecimals(a)
    let opts = P1Options(gridDecimals: grid, depthDecimals: depth)
    let f = readP1(path, opts)
    log.add f.log
    echo "file:        ", path
    echo "standard:    SEG positional exchange (1983), ", f.layout
    for i, lf in f.files:
      echo "file ", i, ":      ", lf.format, ", ", lf.header.len, " header records, ",
        lf.records.len, " data records"
    if output.len > 0:
      log.add writeP1(f, output)
  echo "diagnostics: ", log.count(sevFatal), " fatal, ", log.count(sevError), " error, ",
    log.count(sevWarning), " warning, ", log.count(sevInfo), " info"
  printLog(log, sevWarning)
  if log.failed: 1 else: 0

# ------------------------------------------------------------------- main --

proc run*(args: seq[string]): int =
  ## Runs one command line; returns the exit status.
  if args.len == 0:
    stdout.write Usage
    return 2
  # Options may come before the command: the command is the first argument.
  var k = 0
  while k < args.len and args[k].startsWith("-") and args[k] notin ["--help", "-h", "--version"]:
    inc k
  if k == args.len: k = 0
  let cmd = args[k]
  try:
    let a = parseArgs(args[0 ..< k] & args[k + 1 .. ^1])
    if a.has("help") or a.has("h"):
      stdout.write Usage
      return 0
    case cmd
    of "info": info(a)
    of "dump": dump(a)
    of "diag": diag(a)
    of "keys": keysCmd(a)
    of "survey": surveyCmd(a)
    of "convert": convertCmd(a)
    of "edit": edit(a)
    of "headers": headers(a)
    of "journal": journal(a)
    of "vendormap": vendormap(a)
    of "version", "--version":
      echo "parseSEG ", PackageVersion
      0
    of "help", "--help", "-h":
      stdout.write Usage
      0
    else: usage("unknown command '" & cmd & "'")
  except UsageError as e:
    stderr.writeLine "parseSEG: ", e.msg, "\n(parseSEG help lists the commands)"
    2
  except CatchableError as e:
    stderr.writeLine "parseSEG: ", e.msg
    1

when isMainModule:
  quit run(commandLineParams())
