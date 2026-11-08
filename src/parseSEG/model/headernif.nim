## Header export and import as NIF (task 7.3).
##
## `exportHeaders` streams every named header field of a file to a NIF
## document, optionally with each block's raw bytes (hex) for a lossless
## record. `importHeaders` reads such a document back as a *patch*: each field
## is compared with the file, and only the changed ones are written, through
## the journaled in-place editor (`model/edit`), into the file itself or into
## a copy. Edits are size-preserving field edits, so samples never move.
##
## Document layout (field names as in `model/headerfields`):
##
## ```
## (.nif27)
## (headers
##  (standard segy) (traces 200) (records 0)
##  (file (block binary (f formatCode 1) (f sampleInterval 2000) ... (raw "0001...")))
##  (record 0 (block gh1 (f fileNumber 63) ...) (block gh3 ...))          ; SEG-D
##  (trace 0 (block trace (f sourceX 1704188) ...) (block ext1 ...) (raw "...")))
## ```
##
## Values are integer, float (`(nan)`, `(inf)`, `(neginf)` for the special
## ones) or string literals; strings escape `"`, `\`, control and non-ASCII
## bytes as `\HH`. A trace's `(raw ...)` holds all its header bytes; raw bytes
## are informational and are not imported.
##
## Both directions stream: export writes through a buffer, import reads the
## document with a small strict tokenizer (documents are untrusted input; it
## bounds nesting, strings and numbers and only raises `SegFormatError`) and
## applies each entry as it is read, so the last entry for a field wins.
## Memory does not grow with the file or the document.

import std/[os, strutils, math]
import ../common/[errors, diagnostics]
import ../segd/reader as segdreader
import ./[traceindex, headerfields, edit]

type
  HeaderScope* = enum
    hsFile = "file", hsRecord = "record", hsTrace = "trace"

  HeaderChange* = object
    ## One field the import changes (or, in a dry run, would change).
    scope*: HeaderScope
    index*: int        ## Record or trace index (0 for the file).
    name*: string      ## `<block>.<field>`.
    old*, new*: FieldValue

  ImportOptions* = object
    outPath*: string   ## Edit a copy made here instead of the file itself.
    journal*: string   ## Journal path; default `<target>.edits.nif`.
    dryRun*: bool      ## Only list the changes.
    force*: bool       ## Apply a document made from another file.
    onChange*: proc (c: HeaderChange) {.closure.}
      ## Called for each change (applied or, in a dry run, found).

  ImportResult* = object
    applied*: int      ## Fields written (dry run: fields that would be).
    refused*: int      ## Edits the editor refused (see the log).
    log*: DiagLog

const
  MaxDepth = 64
  MaxString = 1 shl 20
  MaxLoggedErrors = 50 ## Entry errors logged one by one; the rest are counted.

func sameValue(a, b: FieldValue): bool =
  ## Equal values; floats by bit pattern (so -0.0 differs from 0.0), every
  ## NaN equal to every NaN.
  a.kind == b.kind and (case a.kind
    of fvInt: a.i == b.i
    of fvFloat: (a.f.isNaN and b.f.isNaN) or cast[uint64](a.f) == cast[uint64](b.f)
    of fvText: a.s == b.s)

# ----------------------------------------------------------------- writer --

type NifOut = object
  f: File
  buf: string

proc put(o: var NifOut, s: string) =
  o.buf.add s
  if o.buf.len >= 1 shl 20:
    o.f.write o.buf
    o.buf.setLen 0

func nifString(s: string): string =
  result = "\""
  for c in s:
    if c in {'"', '\\'} or ord(c) < 0x20 or ord(c) >= 0x7F: result.add "\\" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

func nifValue(v: FieldValue): string =
  case v.kind
  of fvInt: $v.i
  of fvText: nifString(v.s)
  of fvFloat:
    case classify(v.f)
    of fcNan: "(nan)"
    of fcInf: "(inf)"
    of fcNegInf: "(neginf)"
    of fcNegZero: "-0.0"
    else:
      var s = $v.f
      if '.' notin s and 'e' notin s and 'E' notin s: s.add ".0"
      s

func hexOf(b: openArray[byte]): string =
  result = newStringOfCap(2 * b.len)
  for x in b: result.add toHex(x, 2)

proc putBlock(o: var NifOut, f: SeismicFile, blk: BlockRef, raw: bool, indent: string) =
  o.put indent & "(block " & blk.name
  for n in fieldNames(blk.kind):
    var v: FieldValue
    var err: string
    if f.readBlockField(blk, n, v, err):
      o.put "\n" & indent & " (f " & n & " " & nifValue(v) & ")"
  if raw:
    o.put "\n" & indent & " (raw \"" &
      hexOf(f.unsafeMemory.toOpenArray(int(blk.offset), int(blk.offset) + blk.size - 1)) & "\")"
  o.put ")"

proc recordBlocks(f: SeismicFile, record: int): seq[BlockRef] =
  var err: string
  var blk: BlockRef
  if f.index.locateRecordBlock(record, "gh1", blk, err): result.add blk
  var n = 3
  while f.index.locateRecordBlock(record, "gh" & $n, blk, err):
    result.add blk
    inc n

proc exportHeaders*(f: SeismicFile, path: string, raw = true) =
  ## Writes every named header field of `f` to the NIF file `path`, streamed
  ## through a buffer (memory does not grow with the file). `raw` adds each
  ## block's bytes, and each trace's whole header, as hex. The document is
  ## written to `path.tmp` and renamed when complete. Raises `IOError` if it
  ## cannot be written, or if `path` is the seismic file itself.
  if not f.isOpen and f.len > 0: raise newException(IOError, "the file is not mapped")
  if path == f.path or (fileExists(path) and sameFile(path, f.path)):
    raise newException(IOError, "the output " & path & " is the seismic file itself")
  let tmp = path & ".tmp"
  var o = NifOut()
  if not open(o.f, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
  try:
    o.put "(.nif27)\n(.vendor \"parseSEG\")\n(headers\n (standard " &
      (if f.kind == skSegy: "segy" else: "segd") & ")\n (traces " & $f.len & ")\n"
    let records = if f.kind == skSegd: f.index.segdRecords.len else: 0
    o.put " (records " & $records & ")"
    var blk: BlockRef
    var err: string
    if f.index.locateFileBlock("binary", blk, err):
      o.put "\n (file\n"
      o.putBlock(f, blk, raw, "  ")
      o.put ")"
    for r in 0..<records:
      o.put "\n (record " & $r
      for blk in f.recordBlocks(r):
        o.put "\n"
        o.putBlock(f, blk, raw, "  ")
      o.put ")"
    for t in 0..<f.len:
      o.put "\n (trace " & $t
      for name in ["trace", "ext1"]:
        if f.index.locateTraceBlock(t, name, blk, err):
          o.put "\n"
          o.putBlock(f, blk, false, "  ")
      if raw:
        let e = f.index.entries[t]
        o.put "\n  (raw \"" & hexOf(f.unsafeMemory.toOpenArray(int(e.offset),
          int(e.offset) + int(e.headerBytes) - 1)) & "\")"
      o.put ")"
    o.put ")\n"
    o.f.write o.buf
    o.f.close()
  except CatchableError:
    o.f.close()
    removeFile(tmp)
    raise
  moveFile(tmp, path)

# -------------------------------------------------------------- tokenizer --

type
  TokKind = enum tkOpen, tkClose, tkIdent, tkInt, tkFloat, tkStr, tkEof
  Tok = object
    kind: TokKind
    s: string  ## Tag, identifier or decoded string.
    i: int64
    f: float64
  NifIn = object
    f: File
    buf: string
    pos: int
    line: int
    eof: bool
    path: string

proc docError(n: NifIn, msg: string) {.noinline, noreturn.} =
  raiseFormat(n.path & " line " & $n.line & ": " & msg)

proc fill(n: var NifIn): bool =
  # True when at least one byte is available.
  if n.pos < n.buf.len: return true
  if n.eof: return false
  n.buf.setLen 64 * 1024
  let got = n.f.readBuffer(addr n.buf[0], n.buf.len)
  n.buf.setLen got
  n.pos = 0
  if got == 0: n.eof = true
  got > 0

proc peek(n: var NifIn): char =
  if n.fill: n.buf[n.pos] else: '\0'

proc take(n: var NifIn): char =
  if not n.fill: n.docError("unexpected end of the document")
  result = n.buf[n.pos]
  inc n.pos
  if result == '\n': inc n.line

const
  IdentStart = {'A'..'Z', 'a'..'z', '_'}
  IdentChars = IdentStart + {'0'..'9', '.'}

proc next(n: var NifIn): Tok =
  while true:
    if not n.fill: return Tok(kind: tkEof)
    let c = n.peek
    if c in Whitespace: discard n.take
    elif c == ';':
      while n.fill and n.peek != '\n': discard n.take
    else: break
  let c = n.take
  case c
  of '(':
    result = Tok(kind: tkOpen)
    while n.fill and n.peek in IdentChars:
      result.s.add n.take
      if result.s.len > 256: n.docError("tag too long")
    if n.fill and n.peek == '@': n.docError("line information is not supported")
  of ')': result = Tok(kind: tkClose)
  of '"':
    result = Tok(kind: tkStr)
    while true:
      let d = n.take
      if d == '"': break
      if d == '\\':
        var h = ""
        h.add n.take
        h.add n.take
        if h[0] notin HexDigits or h[1] notin HexDigits: n.docError("bad string escape \\" & h)
        result.s.add char(parseHexInt(h))
      else: result.s.add d
      if result.s.len > MaxString: n.docError("string longer than 1 MB")
  of '-', '+', '0'..'9':
    var t = $c
    while n.fill and n.peek in {'0'..'9', '.', 'e', 'E', '+', '-'}:
      t.add n.take
      if t.len > 64: n.docError("number too long")
    if n.fill and n.peek == '@': n.docError("line information is not supported")
    if t.contains({'.', 'e', 'E'}):
      try: result = Tok(kind: tkFloat, f: parseFloat(t))
      except ValueError: n.docError("bad number " & t)
    else:
      try: result = Tok(kind: tkInt, i: parseBiggestInt(t))
      except ValueError: n.docError("bad or out-of-range integer " & t)
  else:
    if c notin IdentStart: n.docError("unexpected character " & escape($c))
    result = Tok(kind: tkIdent, s: $c)
    while n.fill and n.peek in IdentChars:
      result.s.add n.take
      if result.s.len > 256: n.docError("identifier too long")
    if n.fill and n.peek == '@': n.docError("line information is not supported")

proc skipTree(n: var NifIn, depth: int) =
  # After a tkOpen: skips to its matching tkClose.
  var d = 1
  while d > 0:
    let t = n.next
    case t.kind
    of tkOpen:
      inc d
      if depth + d > MaxDepth: n.docError("nesting deeper than " & $MaxDepth)
    of tkClose: dec d
    of tkEof: n.docError("unexpected end of the document")
    else: discard

proc expectClose(n: var NifIn, what: string) =
  if n.next.kind != tkClose: n.docError("expected ')' after " & what)

proc expectInt(n: var NifIn, what: string): int64 =
  let t = n.next
  if t.kind != tkInt: n.docError("expected " & what)
  t.i

proc value(n: var NifIn): FieldValue =
  let t = n.next
  case t.kind
  of tkInt: toFieldValue(t.i)
  of tkFloat: toFieldValue(t.f)
  of tkStr: toFieldValue(t.s)
  of tkOpen:
    let v = case t.s
      of "nan": NaN
      of "inf": Inf
      of "neginf": NegInf
      else: n.docError("unexpected (" & t.s & " as a value")
    n.expectClose("(" & t.s)
    toFieldValue(v)
  else: n.docError("expected a field value")

type DocFacts = object
  standard: string
  traces, records: int64

iterator entries(n: var NifIn, facts: var DocFacts): (HeaderScope, int64, string, FieldValue) =
  ## Every `(f ...)` of the document, with its scope, index and name; `facts`
  ## holds `(standard)`, `(traces)`, `(records)` once read.
  var t = n.next
  while t.kind == tkOpen and t.s.startsWith("."): # directives
    n.skipTree(1)
    t = n.next
  if t.kind != tkOpen or t.s != "headers": n.docError("expected (headers")
  facts = DocFacts(traces: -1, records: -1)
  var done = false
  while not done:
    t = n.next
    case t.kind
    of tkClose: done = true
    of tkOpen:
      case t.s
      of "standard":
        let x = n.next
        if x.kind != tkIdent: n.docError("expected segy or segd")
        facts.standard = x.s
        n.expectClose("(standard")
      of "traces":
        facts.traces = n.expectInt("a trace count")
        n.expectClose("(traces")
      of "records":
        facts.records = n.expectInt("a record count")
        n.expectClose("(records")
      of "file", "record", "trace":
        let scope = parseEnum[HeaderScope](t.s)
        let index = if scope == hsFile: 0'i64 else: n.expectInt("a record or trace index")
        var inScope = true
        while inScope:
          let b = n.next
          case b.kind
          of tkClose: inScope = false
          of tkOpen:
            if b.s == "block":
              let bn = n.next
              if bn.kind != tkIdent: n.docError("expected a block name")
              var inBlock = true
              while inBlock:
                let e = n.next
                case e.kind
                of tkClose: inBlock = false
                of tkOpen:
                  if e.s == "f":
                    let fname = n.next
                    if fname.kind != tkIdent: n.docError("expected a field name")
                    let v = n.value
                    n.expectClose("a field value")
                    yield (scope, index, bn.s & "." & fname.s, v)
                  else:
                    n.skipTree(4) # (raw ...) and anything newer
                of tkEof: n.docError("unexpected end of the document")
                else: n.docError("unexpected token in (block")
            else:
              n.skipTree(3)
          of tkEof: n.docError("unexpected end of the document")
          else: n.docError("unexpected token in (" & t.s)
      else:
        n.skipTree(2)
    of tkEof: n.docError("unexpected end of the document")
    else: n.docError("unexpected token in (headers")

# ----------------------------------------------------------------- import --

proc checkFacts(facts: DocFacts, f: SeismicFile, force: bool, nifPath: string,
    log: var DiagLog): bool =
  ## False (with a fatal diagnostic) when the document describes another file.
  var problems: seq[string]
  let std = if f.kind == skSegy: "segy" else: "segd"
  if facts.standard.len > 0 and facts.standard != std:
    problems.add "the document is " & facts.standard & ", the file " & std
  if facts.traces >= 0 and facts.traces != f.len:
    problems.add "the document has " & $facts.traces & " traces, the file " & $f.len
  let recs = if f.kind == skSegd: f.index.segdRecords.len else: 0
  if facts.records >= 0 and facts.records != recs:
    problems.add "the document has " & $facts.records & " records, the file " & $recs
  if problems.len == 0: return true
  let msg = "the document was not made from this file: " & problems.join("; ")
  if force:
    log.report(sevWarning, dcValidation, msg & " (applied anyway: force)",
      loc = Location(file: nifPath))
    true
  else:
    log.report(sevFatal, dcValidation, msg & "; nothing written (force applies it anyway)",
      loc = Location(file: nifPath))
    false

func normalized(v, cur: FieldValue): FieldValue =
  # An integral float for an integer field, or an integer for a float one.
  result = v
  if cur.kind == fvInt and v.kind == fvFloat and v.f == trunc(v.f) and
      abs(v.f) < 9.2e18:
    result = toFieldValue(int64(v.f))
  elif cur.kind == fvFloat and v.kind == fvInt:
    result = toFieldValue(float64(v.i))

proc sameFileAs(a, b: string): bool =
  a.len > 0 and b.len > 0 and (a == b or (fileExists(a) and fileExists(b) and sameFile(a, b)))

proc importHeaders*(path, nifPath: string, opts = ImportOptions()): ImportResult =
  ## Applies the headers document `nifPath` to `path` as a patch: each entry
  ## is compared with the file as edited so far and written only when it
  ## differs, through the journaled editor (batched: one journal sync per few
  ## thousand edits). With `opts.outPath`, `path` is copied there first and
  ## the copy is edited (a journal left from an earlier copy is discarded).
  ## A document whose `(standard)`, `(traces)` or `(records)` disagree with
  ## the file is refused unless `opts.force`. Entry errors (unknown fields or
  ## traces) are logged, the first 50 one by one; refused edits are errors.
  ## Never raises: I/O and document problems are fatal diagnostics, and an
  ## import stopped by one keeps the edits made before it (journaled).
  template fatal(msg: string, at = nifPath) =
    result.log.report(sevFatal, dcValidation, msg, loc = Location(file: at))
    return
  if not fileExists(nifPath): fatal("no such document")
  if getFileSize(nifPath) == 0: fatal("the document is empty")
  let target = if opts.outPath.len > 0 and not opts.dryRun: opts.outPath else: path
  let journal = if opts.journal.len > 0: opts.journal else: target & ".edits.nif"
  if opts.outPath.len > 0:
    if sameFileAs(opts.outPath, path): fatal("the output is the input file", opts.outPath)
    if sameFileAs(opts.outPath, nifPath): fatal("the output is the document", opts.outPath)
  if not opts.dryRun:
    for (p, what) in [(path, "input"), (nifPath, "document")]:
      if sameFileAs(journal, p): fatal("the journal is the " & what & " file", journal)
  var n = NifIn(path: nifPath, line: 1)
  if not open(n.f, nifPath, fmRead): fatal("cannot read the document")
  var entryErrors = 0
  try:
    var f: SeismicFile
    var ed: HeaderEditor
    if opts.dryRun:
      f = openSeismic(path)
    else:
      if opts.outPath.len > 0:
        copyFile(path, opts.outPath)
        if fileExists(journal):
          removeFile(journal)
          result.log.report(sevInfo, dcValidation, "an earlier journal " & journal &
            " belonged to an earlier copy and was discarded", loc = Location(file: journal))
      ed = openEditor(target, journal)
      ed.beginBatch()
    try:
      var facts: DocFacts
      var checked = false
      for scope, index, name, v in n.entries(facts):
        if not checked:
          checked = true
          let fp = if opts.dryRun: addr f else: addr ed.file # (no copy of the map)
          if not checkFacts(facts, fp[], opts.force, nifPath, result.log):
            return
        var cur: FieldValue
        var err: string
        let i = int(clamp(index, -1, int64(high(int32))))
        let found = if opts.dryRun:
                      case scope
                      of hsFile: f.fileField(name, cur, err)
                      of hsRecord: f.recordField(i, name, cur, err)
                      of hsTrace: f.traceField(i, name, cur, err)
                    else:
                      case scope
                      of hsFile: ed.currentFileField(name, cur, err)
                      of hsRecord: ed.currentRecordField(i, name, cur, err)
                      of hsTrace: ed.currentTraceField(i, name, cur, err)
        if not found:
          inc entryErrors
          if entryErrors <= MaxLoggedErrors:
            result.log.report(sevError, dcValidation, "line " & $n.line & ": " & $scope & " " &
              $index & ": " & name & ": " & err, loc = Location(file: nifPath, field: name))
        else:
          let nv = normalized(v, cur)
          if not sameValue(cur, nv):
            let c = HeaderChange(scope: scope, index: i, name: name, old: cur, new: nv)
            var ok = true
            if not opts.dryRun:
              ok = case scope
                of hsFile: ed.setFileField(name, nv)
                of hsRecord: ed.setRecordField(i, name, nv)
                of hsTrace: ed.setTraceField(i, name, nv)
            if ok:
              inc result.applied
              if opts.onChange != nil: opts.onChange(c)
            else: inc result.refused
    finally:
      if not opts.dryRun:
        ed.close()
        result.log.add ed.log
  except CatchableError as e:
    result.log.report(sevFatal, dcValidation, e.msg, loc = Location(file: nifPath))
  finally:
    n.f.close()
  if entryErrors > MaxLoggedErrors:
    result.log.report(sevError, dcValidation, $(entryErrors - MaxLoggedErrors) &
      " more entries name fields or traces the file does not have", loc = Location(file: nifPath))
