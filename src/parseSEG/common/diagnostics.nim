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
import errors, diagcodes, niftext

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

proc recordException*(log: var DiagLog; loc: Location; e: ref CatchableError;
    fatal = false) =
  ## Converts a caught exception into a diagnostic. Truncation, unlocatable
  ## data and I/O failures are fatal; format violations are errors; anything
  ## else is an internal error. With `fatal`, for a failure that ends the
  ## operation, the entry is fatal whatever was raised.
  let offset = if e of SegError: (ref SegError)(e).offset else: -1'i64
  let (severity, code) =
    if e of SegTruncatedError: (sevFatal, dcTruncated)
    elif e of SegUnlocatableError:
      (sevFatal, (ref SegUnlocatableError)(e).diagCode)
    elif e of SegFormatError: (sevError, dcBadValue)
    elif e of IOError or e of OSError: (sevFatal, dcIo)
    else: (sevError, dcInternal)
  log.report(if fatal: sevFatal else: severity, code, e.msg, offset, loc)

proc raiseUnlocatable*(code: DiagCode, msg: string, offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises `SegUnlocatableError`: the reader cannot locate the rest of the
  ## data and stops; `tryRecord` logs it as `fatal` with `code`.
  raise (ref SegUnlocatableError)(msg: msg, offset: offset, diagCode: code)

template tryRecord*(log: var DiagLog; loc: Location; body: untyped): bool =
  ## Runs `body`; if it raises a `CatchableError`, records it in `log` (see
  ## `recordException`) and evaluates to false. Evaluates to true on success.
  ## Use at the record/trace boundary so one bad part never aborts the read;
  ## stop reading when `log.isFatal`. Where any failure ends the read, use
  ## `tryRecordFatal`.
  block:
    var ok = false
    try:
      body
      ok = true
    except CatchableError as e:
      recordException(log, loc, e)
    ok

template tryRecordFatal*(log: var DiagLog; loc: Location; body: untyped): bool =
  ## `tryRecord` for a boundary where a failure ends the read: whatever
  ## `body` raises is recorded as `fatal` (`recordException` with `fatal`),
  ## so a read that stopped early always has `isFatal`. Stop reading when it
  ## evaluates to false.
  block:
    var ok = false
    try:
      body
      ok = true
    except CatchableError as e:
      recordException(log, loc, e, fatal = true)
    ok

# --------------------------------------------------------------------- NIF --
# Written and read with `niftext`, not the toolchain's NIF library: that one
# ends the process on a damaged document (its reader calls `quit`), and
# importing it ties the library to a Nim install that ships `dist/nimony`.

const
  NifVendor = "parseSEG"
  DocName = "diagnostics NIF" # what parse errors call the document

proc toNif*(log: DiagLog): string =
  ## Serializes `log` as a NIF document.
  result = newStringOfCap(64 + 96 * log.len)
  result.add "(.nif27)\n(.vendor " & nifString(NifVendor) & ")\n(diagnostics"
  template child(tag: string, value: int64) =
    if value >= 0: result.add "\n  (" & tag & " " & $value & ")"
  template child(tag: string, value: string) =
    if value.len > 0: result.add "\n  (" & tag & " " & nifString(value) & ")"
  for d in log.entries:
    result.add "\n (diag " & $d.severity & " " & $d.code & " " & nifString(d.msg)
    child "file", d.loc.file
    child "offset", d.offset
    child "record", d.loc.record
    child "channelSet", d.loc.channelSet
    child "trace", d.loc.trace
    child "blockIndex", d.loc.blockIndex
    child "field", d.loc.field
    result.add ')'
  result.add ')'

proc writeNif*(log: DiagLog; filename: string) =
  ## Writes `log` as a NIF file. Raises `IOError` if the file cannot be written.
  writeFile(filename, log.toNif)

proc enumIdent[T: enum](n: var NifIn; what: string): T =
  let t = n.next
  if t.kind != ntIdent: n.docError("expected " & what)
  try:
    result = parseEnum[T](t.s)
  except ValueError:
    n.docError("unknown " & what & " '" & t.s & "'")

proc index(n: var NifIn; tag: string): int =
  # The integer of a location child; one that does not fit `int` (a 32-bit
  # build) is malformed, not a `RangeDefect`.
  let v = n.expectInt("an integer in (" & tag)
  if v < int64(low(int)) or v > int64(high(int)): n.docError("(" & tag & " is out of range")
  int(v)

proc parseDiag(n: var NifIn): Diagnostic =
  # After `(diag`: severity, code, then the message and the children in any order.
  result = Diagnostic()
  result.severity = enumIdent[Severity](n, "severity")
  result.code = enumIdent[DiagCode](n, "code")
  var done = false
  while not done:
    let t = n.next
    case t.kind
    of ntClose: done = true
    of ntStr: result.msg = t.s
    of ntOpen:
      case t.s
      of "file": result.loc.file = n.expectStr("a string in (file")
      of "field": result.loc.field = n.expectStr("a string in (field")
      of "offset": result.offset = n.expectInt("an integer in (offset")
      of "record": result.loc.record = n.index(t.s)
      of "channelSet": result.loc.channelSet = n.index(t.s)
      of "trace": result.loc.trace = n.index(t.s)
      of "blockIndex": result.loc.blockIndex = n.index(t.s)
      else: n.docError("unknown tag (" & t.s)
      n.expectClose("(" & t.s)
    else: n.docError("unexpected token in (diag")

proc parseDiagnostics*(nif: string): DiagLog =
  ## Parses a NIF document written by `toNif`. Raises `SegFormatError` if it
  ## is malformed (the message gives the line), whatever its bytes are:
  ## documents are untrusted input.
  result = DiagLog()
  var n = initNifIn(nif, DocName)
  var t = n.next
  while t.kind == ntOpen and t.s.startsWith("."): # directives: (.nif27), (.vendor ...)
    n.skipTree(1)
    t = n.next
  if t.kind != ntOpen or t.s != "diagnostics": n.docError("expected (diagnostics")
  var done = false
  while not done:
    t = n.next
    if t.kind == ntClose: done = true
    elif t.kind == ntOpen and t.s == "diag": result.add parseDiag(n)
    else: n.docError("expected (diag or ')'")

proc readDiagnostics*(filename: string): DiagLog =
  ## Reads a NIF diagnostics file. Raises `IOError` if it cannot be read and
  ## `SegFormatError` if it is malformed.
  parseDiagnostics(readFile(filename))
