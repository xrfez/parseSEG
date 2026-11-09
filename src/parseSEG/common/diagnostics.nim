## Diagnostics: the never-silent, never-interrupting error log.
##
## Readers run to completion whenever that is physically possible. Every
## problem becomes a `Diagnostic` in a `DiagLog` instead of an exception that
## aborts the read. Internal code raises `SegError` subtypes (see `errors`),
## and `tryRecord` converts them into entries at the record/trace boundary.
##
## A log serializes to NIF:
##
## ```
## (.nif27)
## (.vendor "parseSEG")
## (diagnostics
##  (diag warning badValue "format code 0 is not defined"
##   (file "63.sgd")
##   (offset 4340)
##   (record 0)
##   (field "GH1.formatCode")))
## ```
##
## Each entry is severity, code, message, then the optional children
## (`file`, `offset`, `record`, `channelSet`, `trace`, `blockIndex`, `field`), which are
## omitted when unknown.

import std/strutils
import "$nim/dist/nimony/src/lib/nifbuilder", "$nim/dist/nimony/src/lib/nifreader",
  "$nim/dist/nimony/src/lib/nifcore", "$nim/dist/nimony/src/lib/stringviews"
  # The NIF reader/builder ship with the Nim toolchain (2.4+); imported by path
  # so dependent projects need no --path switch.
import errors, diagcodes

export diagcodes

type
  Location* = object
    ## Where a problem sits: which file, and where in its logical structure.
    ## -1 / "" mean "not applicable" or "unknown".
    file*: string          ## Path or name of the file, tape device or stream being read/written.
    record*: int = -1      ## Record (SEG-D shot record, or SEG-Y file) index.
    channelSet*: int = -1  ## SEG-D channel set index within the scan type.
    trace*: int = -1       ## Trace index within the record.
    blockIndex*: int = -1  ## Header block index (e.g. general header N, trace header extension N).
    field*: string         ## Header field name, e.g. "GH1.formatCode".

  Diagnostic* = object
    ## One problem found while reading or writing.
    severity*: Severity
    code*: DiagCode
    offset*: int64 = -1 ## Absolute byte offset in the file or stream; -1 if unknown.
    loc*: Location
    msg*: string

  DiagLog* = object
    ## Ordered list of diagnostics with per-severity counts.
    entries: seq[Diagnostic]
    counts: array[Severity, int]

func `$`*(loc: Location): string =
  ## Human-readable location such as `record 0, trace 3, field GH1.format`.
  result = loc.file
  template part(name: string; value: int) =
    if value >= 0:
      if result.len > 0: result.add ", "
      result.add name & " " & $value
  part "record", loc.record
  part "channel set", loc.channelSet
  part "trace", loc.trace
  part "block", loc.blockIndex
  if loc.field.len > 0:
    if result.len > 0: result.add ", "
    result.add "field " & loc.field

func `$`*(d: Diagnostic): string =
  ## One-line form: `warning badValue @4340 [record 0, trace 3]: message`.
  result = $d.severity & " " & $d.code
  if d.offset >= 0: result.add " @" & $d.offset
  let loc = $d.loc
  if loc.len > 0: result.add " [" & loc & "]"
  result.add ": " & d.msg

proc add*(log: var DiagLog; d: sink Diagnostic) =
  ## Appends `d` to the log.
  inc log.counts[d.severity]
  log.entries.add d

proc add*(log: var DiagLog; other: DiagLog) =
  ## Appends every entry of `other`, in order.
  for d in other.entries: log.add d

proc report*(log: var DiagLog; severity: Severity; code: DiagCode; msg: string;
    offset: int64 = -1; loc = Location()) =
  ## Appends a new diagnostic built from the arguments.
  log.add Diagnostic(severity: severity, code: code, offset: offset, loc: loc, msg: msg)

func len*(log: DiagLog): int {.inline.} =
  ## The number of diagnostics.
  log.entries.len

func `[]`*(log: DiagLog; i: int): lent Diagnostic {.inline.} =
  ## Diagnostic `i`, oldest first. As for a `seq`, an `i` outside
  ## `0 ..< len` is a bug (`IndexDefect`; unchecked under `-d:danger`).
  log.entries[i]

iterator items*(log: DiagLog): lent Diagnostic =
  ## Yields the diagnostics, oldest first.
  for d in log.entries: yield d

iterator pairs*(log: DiagLog): (int, lent Diagnostic) =
  ## Yields `(index, diagnostic)` pairs, oldest first.
  for i, d in log.entries: yield (i, d)

func count*(log: DiagLog; severity: Severity): int {.inline.} =
  ## Number of entries with exactly `severity`.
  log.counts[severity]

func hasErrors*(log: DiagLog): bool {.inline.} =
  ## True if any entry is `sevError` or `sevFatal`.
  log.counts[sevError] + log.counts[sevFatal] > 0

func isFatal*(log: DiagLog): bool {.inline.} =
  ## True if the operation stopped early.
  log.counts[sevFatal] > 0

# ---------------------------------------------------------------- boundary --

proc recordException*(log: var DiagLog; loc: Location; e: ref CatchableError) =
  ## Converts a caught exception into a diagnostic. Truncation, unlocatable
  ## data and I/O failures are fatal; format violations are errors; anything
  ## else is an internal error.
  let offset = if e of SegError: (ref SegError)(e).offset else: -1'i64
  let (severity, code) =
    if e of SegTruncatedError: (sevFatal, dcTruncated)
    elif e of SegUnlocatableError:
      (sevFatal, (ref SegUnlocatableError)(e).diagCode)
    elif e of SegFormatError: (sevError, dcBadValue)
    elif e of IOError or e of OSError: (sevFatal, dcIo)
    else: (sevError, dcInternal)
  log.report(severity, code, e.msg, offset, loc)

proc raiseUnlocatable*(code: DiagCode, msg: string, offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises `SegUnlocatableError`: the reader cannot locate the rest of the
  ## data and stops; `tryRecord` logs it as `fatal` with `code`.
  raise (ref SegUnlocatableError)(msg: msg, offset: offset, diagCode: code)

template tryRecord*(log: var DiagLog; loc: Location; body: untyped): bool =
  ## Runs `body`; if it raises a `CatchableError`, records it in `log` (see
  ## `recordException`) and evaluates to false. Evaluates to true on success.
  ## Use at the record/trace boundary so one bad part never aborts the read;
  ## stop reading when `log.isFatal`.
  block:
    var ok = false
    try:
      body
      ok = true
    except CatchableError as e:
      recordException(log, loc, e)
    ok

# --------------------------------------------------------------------- NIF --

const NifVendor = "parseSEG"

proc addInt(b: var Builder; tag: string; value: int64) =
  if value >= 0:
    b.withTree tag:
      b.addIntLit value

proc addNif(b: var Builder; log: DiagLog) =
  b.addHeader(vendor = NifVendor)
  b.withTree "diagnostics":
    for d in log.entries:
      b.withTree "diag":
        b.addIdent $d.severity
        b.addIdent $d.code
        b.addStrLit d.msg
        if d.loc.file.len > 0:
          b.withTree "file":
            b.addStrLit d.loc.file
        b.addInt "offset", d.offset
        b.addInt "record", d.loc.record
        b.addInt "channelSet", d.loc.channelSet
        b.addInt "trace", d.loc.trace
        b.addInt "blockIndex", d.loc.blockIndex
        if d.loc.field.len > 0:
          b.withTree "field":
            b.addStrLit d.loc.field

proc toNif*(log: DiagLog): string =
  ## Serializes `log` as a NIF document.
  var b = nifbuilder.open(64 + 96 * log.len)
  b.addNif log
  result = extract(move b)

proc writeNif*(log: DiagLog; filename: string) =
  ## Writes `log` as a NIF file. Raises `IOError` if the file cannot be written.
  writeFile(filename, log.toNif)

proc parseError(r: Reader; what: string) {.noinline, noreturn.} =
  raiseFormat("diagnostics NIF line " & $r.line & ": " & what)

proc expect(r: var Reader; t: var ExpandedToken; kind: NifKind; what: string) =
  next(r, t)
  if t.tk != kind: parseError(r, "expected " & what)

proc expectTag(r: var Reader; t: var ExpandedToken; tag: string) =
  next(r, t)
  if t.tk != ParLe or t.data != tag: parseError(r, "expected (" & tag)

proc parseEnumToken[T: enum](r: var Reader; t: var ExpandedToken; what: string): T =
  r.expect(t, Ident, what)
  let s = r.decodeStr(t)
  try:
    result = parseEnum[T](s)
  except ValueError:
    parseError(r, "unknown " & what & " '" & s & "'")

proc parseDiag(r: var Reader; t: var ExpandedToken): Diagnostic =
  result = Diagnostic()
  result.severity = parseEnumToken[Severity](r, t, "severity")
  result.code = parseEnumToken[DiagCode](r, t, "code")
  var done = false
  while not done:
    next(r, t)
    case t.tk
    of ParRi:
      done = true
    of StrLit:
      result.msg = r.decodeStr(t)
    of ParLe:
      let tag = r.decodeStr(t)
      if tag == "field" or tag == "file":
        r.expect(t, StrLit, "string")
        if tag == "field": result.loc.field = r.decodeStr(t)
        else: result.loc.file = r.decodeStr(t)
      else:
        r.expect(t, IntLit, "integer")
        let v = decodeInt(t)
        case tag
        of "offset": result.offset = v
        of "record": result.loc.record = int v
        of "channelSet": result.loc.channelSet = int v
        of "trace": result.loc.trace = int v
        of "blockIndex": result.loc.blockIndex = int v
        else: parseError(r, "unknown tag (" & tag)
      r.expect(t, ParRi, "')'")
    else:
      parseError(r, "unexpected token in (diag")

proc parseDiagnostics*(nif: string): DiagLog =
  ## Parses a NIF document written by `toNif`. Raises `SegFormatError` if it
  ## is malformed.
  result = DiagLog()
  var r = openFromBuffer(nif, "")
  var t = default(ExpandedToken)
  r.expectTag(t, "diagnostics")
  var done = false
  while not done:
    next(r, t)
    case t.tk
    of ParRi:
      done = true
    of ParLe:
      if t.data != "diag": parseError(r, "expected (diag")
      result.add parseDiag(r, t)
    else:
      parseError(r, "expected (diag or ')'")
  r.close()

proc readDiagnostics*(filename: string): DiagLog =
  ## Reads a NIF diagnostics file. Raises `IOError` if it cannot be read and
  ## `SegFormatError` if it is malformed.
  parseDiagnostics(readFile(filename))
