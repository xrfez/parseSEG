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
## (headers (standard segy) (traces 200) (records 1)
##   (file (block binary (f formatCode 1) (f sampleInterval 2000) ... (raw "0001...")))
##   (record 0 (block gh1 (f fileNumber 63) ...) (block gh3 ...))          ; SEG-D
##   (trace 0 (block trace (f sourceX 1704188) ...) (block ext1 ...) (raw "...")))
## ```
##
## Values are integer, float or string literals. A trace's `(raw ...)` holds
## all its header bytes (extensions included); raw bytes are informational and
## are not imported. An edited document may hold any subset of the entries.

import std/[os, strutils]
import nifbuilder, nifreader
import ../common/[errors, diagnostics]
import ../segd/reader as segdreader
import ./[traceindex, headerfields, edit]

type
  HeaderScope* = enum
    hsFile = "file", hsRecord = "record", hsTrace = "trace"

  HeaderChange* = object
    ## One field the import changes (or would change).
    scope*: HeaderScope
    index*: int        ## Record or trace index (0 for the file).
    name*: string      ## `<block>.<field>`.
    old*, new*: FieldValue

const NifVendor = "parseSEGD"

func `==`*(a, b: FieldValue): bool =
  a.kind == b.kind and (case a.kind
    of fvInt: a.i == b.i
    of fvFloat: a.f == b.f or (a.f != a.f and b.f != b.f)
    of fvText: a.s == b.s)

func hexOf(b: openArray[byte]): string =
  result = newStringOfCap(2 * b.len)
  for x in b: result.add toHex(x, 2)

proc addValue(b: var Builder, v: FieldValue) =
  case v.kind
  of fvInt: b.addIntLit v.i
  of fvFloat: b.addFloatLit v.f
  of fvText: b.addStrLit v.s

proc addBlock(b: var Builder, f: SeismicFile, blk: BlockRef, raw: bool) =
  b.withTree "block":
    b.addIdent blk.name
    for n in fieldNames(blk.kind):
      var v: FieldValue
      var err: string
      if f.readBlockField(blk, n, v, err):
        b.withTree "f":
          b.addIdent n
          b.addValue v
    if raw:
      b.withTree "raw":
        b.addStrLit hexOf(f.memory.toOpenArray(int(blk.offset), int(blk.offset) + blk.size - 1))

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
  ## (memory does not grow with the file). `raw` adds each block's bytes, and
  ## each trace's whole header, as hex. Raises `IOError` if `path` cannot be
  ## written.
  if f.memory == nil and f.len > 0: raise newException(IOError, "the file is not mapped")
  var b = nifbuilder.open(path)
  try:
    b.addHeader(vendor = NifVendor)
    b.withTree "headers":
      b.withTree "standard":
        b.addIdent(if f.kind == skSegy: "segy" else: "segd")
      b.withTree "traces":
        b.addIntLit f.len
      let records = if f.kind == skSegd: f.index.segdRecords.len else: 0
      b.withTree "records":
        b.addIntLit records
      var blk: BlockRef
      var err: string
      if f.index.locateFileBlock("binary", blk, err):
        b.withTree "file":
          b.addBlock(f, blk, raw)
      for r in 0..<records:
        b.withTree "record":
          b.addIntLit r
          for blk in f.recordBlocks(r): b.addBlock(f, blk, raw)
      for t in 0..<f.len:
        b.withTree "trace":
          b.addIntLit t
          for name in ["trace", "ext1"]:
            if f.index.locateTraceBlock(t, name, blk, err): b.addBlock(f, blk, false)
          if raw:
            let e = f.index.entries[t]
            b.withTree "raw":
              b.addStrLit hexOf(f.memory.toOpenArray(int(e.offset),
                int(e.offset) + int(e.headerBytes) - 1))
  finally:
    b.close()

# ----------------------------------------------------------------- import --

proc parseError(r: Reader, what: string) {.noinline, noreturn.} =
  raiseFormat("headers NIF line " & $r.line & ": " & what)

proc skipTree(r: var Reader, t: var ExpandedToken) =
  # After a ParLe: skips to its matching ParRi.
  var depth = 1
  while depth > 0:
    next(r, t)
    case t.tk
    of ParLe: inc depth
    of ParRi: dec depth
    of EofToken: parseError(r, "unexpected end of the document")
    else: discard

proc readValue(r: var Reader, t: var ExpandedToken, v: var FieldValue) =
  next(r, t)
  case t.tk
  of IntLit: v = toFieldValue(decodeInt(t))
  of FloatLit: v = toFieldValue(float64(decodeFloat(t)))
  of StringLit: v = toFieldValue(r.decodeStr(t))
  of ParLe:
    let tag = r.decodeStr(t)
    v = case tag
        of "nan": toFieldValue(NaN)
        of "inf": toFieldValue(Inf)
        of "neginf": toFieldValue(NegInf)
        else: parseError(r, "unexpected (" & tag & " as a value")
    r.skipTree(t)
  else: parseError(r, "expected a field value")

proc readIndex(r: var Reader, t: var ExpandedToken): int =
  next(r, t)
  if t.tk != IntLit: parseError(r, "expected a record or trace index")
  int(decodeInt(t))

iterator headerEntries(path: string): (HeaderScope, int, string, FieldValue) =
  ## Every `(f ...)` of a headers document, with its scope, index and
  ## `<block>.<field>` name. Raises `SegFormatError` for a malformed document.
  var r = nifreader.open(path)
  try:
    var t = default(ExpandedToken)
    next(r, t)
    if t.tk != ParLe or r.decodeStr(t) != "headers": parseError(r, "expected (headers")
    var done = false
    while not done:
      next(r, t)
      case t.tk
      of ParRi: done = true
      of ParLe:
        let tag = r.decodeStr(t)
        if tag in ["file", "record", "trace"]:
          let scope = parseEnum[HeaderScope](tag)
          let index = if scope == hsFile: 0 else: r.readIndex(t)
          var inScope = true
          while inScope:
            next(r, t)
            case t.tk
            of ParRi: inScope = false
            of ParLe:
              if r.decodeStr(t) == "block":
                next(r, t)
                if t.tk != Ident: parseError(r, "expected a block name")
                let blockName = r.decodeStr(t)
                var inBlock = true
                while inBlock:
                  next(r, t)
                  case t.tk
                  of ParRi: inBlock = false
                  of ParLe:
                    if r.decodeStr(t) == "f":
                      next(r, t)
                      if t.tk != Ident: parseError(r, "expected a field name")
                      let field = r.decodeStr(t)
                      var v: FieldValue
                      r.readValue(t, v)
                      next(r, t)
                      if t.tk != ParRi: parseError(r, "expected ')' after a field value")
                      yield (scope, index, blockName & "." & field, v)
                    else:
                      r.skipTree(t) # (raw ...) and anything newer
                  else: parseError(r, "unexpected token in (block")
              else:
                r.skipTree(t)
            else: parseError(r, "unexpected token in (" & tag)
        else:
          r.skipTree(t) # (standard ...), (traces ...), ...
      else: parseError(r, "unexpected token in (headers")
  finally:
    r.close()

proc currentValue(f: SeismicFile, scope: HeaderScope, index: int, name: string,
    v: var FieldValue, err: var string): bool =
  case scope
  of hsFile: f.fileField(name, v, err)
  of hsRecord: f.recordField(index, name, v, err)
  of hsTrace: f.traceField(index, name, v, err)

proc checkReadable(path: string) =
  # nifreader quits the process on a file it cannot open.
  try:
    var fh = open(path, fmRead)
    fh.close()
  except IOError as e:
    raise newException(IOError, "cannot read " & path & ": " & e.msg)

proc diffHeaders*(f: SeismicFile, nifPath: string, log: var DiagLog): seq[HeaderChange] =
  ## The fields of the headers document `nifPath` that differ from `f`.
  ## Entries naming a field or a trace `f` does not have are logged as errors.
  ## Raises `IOError` / `SegFormatError` for an unreadable or malformed document.
  checkReadable(nifPath)
  for scope, index, name, v in headerEntries(nifPath):
    var cur: FieldValue
    var err: string
    if not f.currentValue(scope, index, name, cur, err):
      log.report(sevError, dcValidation, $scope & " " & $index & ": " & name & ": " & err,
        loc = Location(file: nifPath, field: name,
          trace: (if scope == hsTrace: index else: -1),
          record: (if scope == hsRecord: index else: -1)))
    elif cur != v:
      var nv = v
      if cur.kind == fvFloat and v.kind == fvInt: nv = toFieldValue(float64(v.i))
      if cur != nv:
        result.add HeaderChange(scope: scope, index: index, name: name, old: cur, new: nv)

proc importHeaders*(path, nifPath: string, outPath = "", journal = "",
    dryRun = false): tuple[changes: seq[HeaderChange], log: DiagLog] =
  ## Applies the headers document `nifPath` to `path` as a patch: only fields
  ## whose values differ are written, each through the journaled in-place
  ## editor (`journal`, default `<target>.edits.nif`). With `outPath`, `path`
  ## is copied there first and the copy is edited. `dryRun` only lists the
  ## changes. Refused edits are in the log (as errors) and the rest still
  ## apply. Never raises: I/O and format problems are fatal diagnostics.
  var target = path
  try:
    var changes: seq[HeaderChange]
    block:
      var f = openSeismic(path)
      try:
        changes = f.diffHeaders(nifPath, result.log)
      finally:
        f.close()
    result.changes = changes
    if dryRun or changes.len == 0: return
    if outPath.len > 0:
      if fileExists(outPath) and sameFile(path, outPath):
        result.log.report(sevFatal, dcValidation, "the output is the input file",
          loc = Location(file: outPath))
        return
      copyFile(path, outPath)
      target = outPath
    var ed = openEditor(target, journal)
    try:
      for c in changes:
        let ok = case c.scope
          of hsFile: ed.setField(c.name, c.new)
          of hsRecord: ed.setRecordField(c.index, c.name, c.new)
          of hsTrace: ed.setField(c.index, c.name, c.new)
        discard ok # a refusal is in ed.log
    finally:
      ed.close()
      result.log.add ed.log
  except CatchableError as e:
    result.log.report(sevFatal, dcIo, e.msg, loc = Location(file: target))
