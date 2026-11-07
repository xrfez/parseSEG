## The `parseSEGD` command line tool (Phase 7), written against the public
## API (`import parseSEGD`), so it doubles as an end-to-end test of it.
## Build with `nim cli` (bin/parseSEGD). `parseSEGD help` lists the commands.
##
## Exit status: 0 success; 1 the command ran but reported errors (an error or
## fatal diagnostic); 2 a usage error.

import std/[os, strutils, sequtils]
import ../parseSEGD

const
  Version = "0.2.0"
  Usage = """
parseSEGD """ & Version & """ — read, index, edit and convert SEG-Y and SEG-D

Usage: parseSEGD <command> [options] <arguments>

Inspecting
  info <file> [--keys]          what the file is: standard, revision, format,
                                records, traces, samples, gathers, diagnostics
  dump <file> [--traces=SEL] [--fields=a,b,...] [--all]
                                trace headers as a table (SEL: 5 | 0..9 | 1,4,7);
                                --fields picks header fields (trace.sourceX,
                                ext1.receiverLineNumber, ...); --all prints
                                every field of every block
  diag <file> [--nif] [--min=info|warning|error|fatal]
                                the diagnostics of indexing the file

Converting
  convert <src> <dst> [--to=segy|segd] [--rev=R] [--format=N]
          [--byte-order=big|little|pairSwapped] [--text=ebcdic|ascii]
          [--descale] [--no-station-header]
                                SEG-Y/SEG-D to SEG-Y (revision 0, 1, 2.0, 2.1;
                                default 2.1), or SEG-D to SEG-D (--to=segd,
                                revision 2.0, 2.1 or 3.0; default 3.0). The
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
                                PARSESEGD_VENDOR_PATH, --map), and which match
  vendormap apply <file> [--map=PATH] [--traces=SEL]
                                decode the vendor areas, printed as NIF
  vendormap scaffold <file> [-o map.nif] [--map=PATH] [--name=N]
                                a skeleton map for every unmapped vendor area

Other
  version | help
"""

type UsageError = object of CatchableError

proc usage(msg: string) {.noinline, noreturn.} =
  raise newException(UsageError, msg)

type Args = object
  pos: seq[string]
  opts: seq[(string, string)]

const Flags = ["keys", "all", "nif", "descale", "no-station-header", "fields-only", "dry-run",
  "help", "h"]

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
      if sep >= 0:
        result.opts.add (body[0 ..< sep], body[sep + 1 .. ^1])
      elif body in Flags:
        result.opts.add (body, "")
      elif i + 1 < args.len and not args[i + 1].startsWith("-"):
        result.opts.add (body, args[i + 1])
        inc i
      else:
        result.opts.add (body, "") # an unknown option is reported by its command
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

proc openFile(path: string, keys = false): SeismicFile =
  if not fileExists(path): usage("no such file: " & path)
  result = openSeismic(path, keys = keys)
  if not result.index.detected:
    printLog(result.index.log, sevError)
    quit("parseSEGD: " & path & " is neither SEG-Y nor SEG-D", 1)

# ------------------------------------------------------------------- info --

func formatName(f: SampleFormat): string =
  $ord(f) & " (" & (case f
    of sfIbm32: "IBM float"
    of sfFixedGain: "fixed point with gain"
    of sfFloat32: "IEEE float32"
    of sfFloat64: "IEEE float64"
    else: ($f)[2..^1].toLowerAscii) & ")"

proc info(a: Args): int =
  a.onlyOptions(["keys"])
  a.needArgs(1, "info <file>")
  var f = openFile(a.pos[0], keys = a.has("keys"))
  defer: f.close()
  let ix = f.index
  echo "file:        ", a.pos[0], " (", getFileSize(a.pos[0]), " bytes)"
  if f.kind == skSegy:
    let s = ix.segy
    echo "standard:    SEG-Y rev ", s.revision, ", ", s.byteOrder, "-endian",
      (if s.byteOrderDeclared: " (declared)" else: "")
    echo "format:      ", (if s.formatKnown: formatName(s.format) else: "unknown")
  else:
    var revs, fmts: seq[string]
    for r in ix.segdRecords:
      let rv = $r.revision
      if rv notin revs: revs.add rv
      let fm = if r.formatKnown: $ord(r.format) else: "unknown (" & $r.gh1.formatCode & ")"
      if fm notin fmts: fmts.add fm
    echo "standard:    SEG-D rev ", revs.join(", "),
      (if ix.hasSegdLabel: ", label " & ix.segdLabel.revision & " " & ix.segdLabel.structure
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
  if a.has("keys"):
    var kinds: seq[(GatherKind, int)]
    for g in ix.gathers:
      var found = false
      for k in kinds.mitems:
        if k[0] == g.kind:
          inc k[1]
          found = true
      if not found: kinds.add (g.kind, 1)
    echo "gathers:     ", kinds.mapIt($it[1] & " " & $it[0]).join(", ")
  echo "diagnostics: ", ix.log.count(sevFatal), " fatal, ", ix.log.count(sevError), " error, ",
    ix.log.count(sevWarning), " warning, ", ix.log.count(sevInfo), " info"
  if ix.log.failed: 1 else: 0

# ------------------------------------------------------------------- dump --

proc parseSelection(s: string, n: int): seq[int] =
  if s.len == 0: return toSeq(0..<n)
  for part in s.split(','):
    let p = part.strip
    let dots = p.find("..")
    try:
      if dots >= 0:
        let a = parseInt(p[0 ..< dots])
        let b = parseInt(p[dots + 2 .. ^1])
        for i in a..b: result.add i
      else:
        result.add parseInt(p)
    except ValueError:
      usage("bad trace selection '" & p & "' (use 5, 0..9 or 1,4,7)")
  for i in result:
    if i < 0 or i >= n: usage("trace " & $i & " out of range (the file has " & $n & ")")

proc dump(a: Args): int =
  a.onlyOptions(["traces", "fields", "all"])
  a.needArgs(1, "dump <file>")
  var f = openFile(a.pos[0])
  defer: f.close()
  let sel = parseSelection(a.get("traces"), f.len)
  if a.has("all"):
    for t in sel:
      echo "trace ", t
      for blockName in ["trace", "ext1"]:
        var b: BlockRef
        var err: string
        if f.index.locateTraceBlock(t, blockName, b, err):
          for n in fieldNames(b.kind):
            var v: FieldValue
            if f.readBlockField(b, n, v, err): echo "  ", blockName, ".", n, " = ", v
    return 0
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
      var v: FieldValue
      var err: string
      row.add(if f.traceField(t, name, v, err): $v else: "?")
    echo row.join("\t")
  for name in fields:
    var v: FieldValue
    var err: string
    if sel.len > 0 and not f.traceField(sel[0], name, v, err):
      stderr.writeLine "warning: ", name, ": ", err
  0

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

proc convertCmd(a: Args): int =
  a.onlyOptions(["to", "rev", "format", "byte-order", "text", "descale", "no-station-header"])
  a.needArgs(2, "convert <src> <dst>")
  let (src, dst) = (a.pos[0], a.pos[1])
  if not fileExists(src): usage("no such file: " & src)
  let to = a.get("to", if isSegdName(src) and isSegdName(dst): "segd" else: "segy")
  var log: DiagLog
  case to
  of "segd":
    for k in ["byte-order", "text", "descale", "no-station-header"]:
      if a.has(k): usage("--" & k & " applies to SEG-Y output only")
    var o = SegdConvertOptions()
    let rev = a.get("rev", "3.0").split('.')
    if rev.len != 2: usage("--rev for SEG-D is 2.0, 2.1 or 3.0")
    o.revision = SegdRevision(major: uint8(parseIntOpt(rev[0], "rev")),
      minor: uint8(parseIntOpt(rev[1], "rev")))
    o.format = parseIntOpt(a.get("format", "0"), "format")
    log = convertSegdRevision(src, dst, o)
  of "segy":
    var o = ConvertOptions()
    if a.has("rev"):
      let rev = a.get("rev").split('.')
      o.revision = SegyRevision(major: uint8(parseIntOpt(rev[0], "rev")),
        minor: uint8(if rev.len > 1: parseIntOpt(rev[1], "rev") else: 0))
    o.format = parseIntOpt(a.get("format", "0"), "format")
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
    stderr.writeLine "parseSEGD: conversion ", (if log.isFatal: "failed" else: "had errors")
    1
  else:
    echo dst, ": written (", log.count(sevInfo), " notes, ", log.count(sevWarning),
      " warnings; `parseSEGD diag` lists the file's own)"
    0

# ------------------------------------------------------------------- edit --

proc parseValue(s: string): EditValue =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"': return toEditValue(s[1 .. ^2])
  try: return toEditValue(parseBiggestInt(s))
  except ValueError: discard
  try: return toEditValue(parseFloat(s))
  except ValueError: discard
  toEditValue(s)

proc edit(a: Args): int =
  a.onlyOptions(["journal"])
  if a.pos.len < 2: usage("expected edit <file> <assignment>...")
  let path = a.pos[0]
  if not fileExists(path): usage("no such file: " & path)
  var ed = openEditor(path, a.get("journal"))
  var refused = 0
  try:
    for asg in a.pos[1..^1]:
      let colon = asg.find(':')
      let eq = asg.find('=')
      if colon <= 0 or eq < colon:
        usage("bad assignment '" & asg & "' (want <scope>:<block>.<field>=<value>)")
      let scope = asg[0 ..< colon]
      let name = asg[colon + 1 ..< eq]
      let value = parseValue(asg[eq + 1 .. ^1])
      var ok = true
      if scope == "file":
        ok = ed.setField(name, value)
      elif scope.len > 1 and scope[0] in {'t', 'r'}:
        let sel = parseSelection(scope[1..^1],
          if scope[0] == 't': ed.file.len else: ed.file.index.segdRecords.len)
        for i in sel:
          if scope[0] == 't': ok = ed.setField(i, name, value) and ok
          else: ok = ed.setRecordField(i, name, value) and ok
      else:
        usage("bad scope '" & scope & "' (t5, t0..9, r0 or file)")
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
    exportHeaders(f, outPath, raw = not a.has("fields-only"))
    echo outPath, ": ", f.len, " traces exported"
    0
  of "import":
    a.onlyOptions(["o", "out", "journal", "dry-run"])
    if a.pos.len != 3: usage("expected headers import <file> <patch.nif>")
    if not fileExists(a.pos[1]): usage("no such file: " & a.pos[1])
    if not fileExists(a.pos[2]): usage("no such file: " & a.pos[2])
    let (changes, log) = importHeaders(a.pos[1], a.pos[2], a.get("o", a.get("out")),
      a.get("journal"), a.has("dry-run"))
    for c in changes:
      echo c.scope, " ", c.index, " ", c.name, ": ", c.old, " -> ", c.new
    printLog(log, sevWarning)
    echo changes.len, " changed fields", (if a.has("dry-run"): " (dry run: nothing written)"
                                           else: "")
    if log.failed: 1 else: 0
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

proc loadRegistry(a: Args, log: var DiagLog): VendorRegistry =
  var paths = vendorSearchPath()
  for (k, v) in a.opts:
    if k == "map": paths.add v
  result.loadVendorMaps(paths, log)

func `$`(v: VendorValue): string =
  result = case v.kind
    of vvInt: $v.intVal
    of vvFloat: $v.floatVal
    of vvText: v.text.escape
    of vvBytes:
      var h = "\""
      for b in v.bytes: h.add toHex(b, 2)
      h & "\""
  if v.label.len > 0: result.add " (label " & v.label.escape & ")"
  if v.flags.len > 0: result.add " (flags " & v.flags.join(" ") & ")"
  if v.unit.len > 0: result.add " (unit " & v.unit.escape & ")"

proc printBlocks(indent: string, blocks: seq[VendorBlock]) =
  for b in blocks:
    stdout.write indent, "(block ", b.mapName.escape, " ", b.name
    for (n, v) in b.fields: stdout.write "\n", indent, "  (f ", n, " ", $v, ")"
    stdout.write ")\n"

func contextOf(rec: SegdRecord): VendorContext = segdContext(rec)

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
      if f.kind == skSegd:
        if f.index.segdRecords.len > 0:
          ctx = contextOf(f.index.segdRecords[0])
          haveCtx = true
      else:
        ctx = segyContext(f.index.segy)
        haveCtx = true
    if reg.maps.len == 0: echo "no vendor maps on the search path: ", vendorSearchPath().join(", ")
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
    let sel = parseSelection(a.get("traces"), n)
    var want = newSeq[bool](n)
    for i in sel: want[i] = true
    echo "(.nif27)\n(vendor ", path.extractFilename.escape
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
        printBlocks(" ", decodeVendorAreas(reg, r.file, log))
        var t: SegyTrace
        while r.readTrace(t):
          if k < n and want[k]:
            let blocks = decodeVendorAreas(reg, r.file, t, log)
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
    if not fileExists(a.pos[1]): usage("no such file: " & a.pos[1])
    var log: DiagLog
    let reg = loadRegistry(a, log)
    printLog(log, sevWarning)
    let s = scaffold(a.pos[1], reg)
    let text = s.toNif(a.get("name"))
    let outPath = a.get("o", a.get("out"))
    if outPath.len == 0: stdout.write text
    else:
      writeFile(outPath, text)
      echo outPath, ": ", s.len, " unmapped vendor areas"
    result = 0
  else: usage("expected vendormap check|list|apply|scaffold")

# ------------------------------------------------------------------- main --

proc run*(args: seq[string]): int =
  ## Runs one command line; returns the exit status.
  if args.len == 0:
    stdout.write Usage
    return 2
  let cmd = args[0]
  try:
    let a = parseArgs(args[1..^1])
    if a.has("help") or a.has("h"):
      stdout.write Usage
      return 0
    case cmd
    of "info": info(a)
    of "dump": dump(a)
    of "diag": diag(a)
    of "convert": convertCmd(a)
    of "edit": edit(a)
    of "headers": headers(a)
    of "journal": journal(a)
    of "vendormap": vendormap(a)
    of "version", "--version":
      echo "parseSEGD ", Version
      0
    of "help", "--help", "-h":
      stdout.write Usage
      0
    else: usage("unknown command '" & cmd & "'")
  except UsageError as e:
    stderr.writeLine "parseSEGD: ", e.msg, "\n(parseSEGD help lists the commands)"
    2
  except CatchableError as e:
    stderr.writeLine "parseSEGD: ", e.msg
    1

when isMainModule:
  quit run(commandLineParams())
