## In-place header edits on disk, with an undo journal (task 6.6).
##
## Updating positions, coordinates or statics in place is far faster than
## re-exporting a file. A `HeaderEditor` maps the file read-write, locates a
## header through the trace index, and changes one field at a time:
##
## ```nim
## var ed = openEditor("line.sgy")              # journal: line.sgy.edits.nif
## discard ed.setField(17, "trace.sourceX", 512_300)
## discard ed.setField("binary.sampleInterval", 2000)
## ed.close()
## echo rollbackJournal("line.sgy", "line.sgy.edits.nif")  # undo everything
## ```
##
## Every edit is checked and journaled before a byte changes:
## - the field is encoded with the library's own field codecs, so a value
##   that does not fit the field's width, BCD digits, nibble or range is
##   refused;
## - fields that size the file's structure (sample counts, formats, header
##   and extension counts, channel set references, revision and byte-order
##   fields) are refused: such changes need a full rewrite;
## - only the bytes that change are written; a no-op edit writes nothing;
## - the journal entry (offset, original bytes, new bytes) is appended and
##   flushed before the map is written, so an interrupted session can still
##   be rolled back.
##
## A refused edit returns false and leaves a diagnostic in `log`; it never
## raises. Not available on tape (there is no map); `contiguous` sources
## only.
##
## Fields are named `<block>.<field>`, with the field names of the header
## types:
##
## | Standard | Blocks |
## |---|---|
## | SEG-Y | `binary` (`setField(name, value)`), `trace`, `ext1` (Trace Header Extension 1) |
## | SEG-D | `trace` (demux header), `ext1` (THE#1, Rev 1/2 or Rev 3 layout by record), `gh1` and, for Rev 1/2, `gh3`, `gh4`, ... (source headers) via `setRecordField` |
##
## The journal is NIF, one entry per line, so it can be read back even when
## the last line was cut short:
##
## ```
## (session (file "line.sgy") (size 2051200))
## (edit 3816 "0007d000" "0007d0f0" "trace 0 trace.sourceX")
## ```
##
## `rollbackJournal` undoes a journal (newest first), `applyJournal` replays
## it (oldest first). Both check each location first: bytes that already
## hold the target are skipped, and bytes that hold neither the original
## nor the edited value are a conflict, logged and left alone.

import std/[algorithm, macros, math, strutils, tables]
when defined(posix):
  import std/posix
import ../common/[endians, errors, diagnostics, fieldlayout]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ./traceindex

type
  EditKind = enum ekInt, ekFloat, ekText

  EditValue* = object
    ## A new field value: an integer, a float or text.
    case kind: EditKind
    of ekInt: i: int64
    of ekFloat: f: float64
    of ekText: s: string

  HeaderEditor* = object
    ## An open file with its journal. Call `close` to flush both.
    file*: SeismicFile   ## The mapped file and its index (headers as opened).
    log*: DiagLog        ## Refused edits and journal problems.
    journalPath*: string
    journal: File
    journalBroken: bool  ## A journal write failed part-way (see `journalLine`).
    edits: int

const
  MaxJournalLine = 1 shl 16 ## Longer journal lines are malformed.
  MaxRepeats = 5 ## Journal diagnostics of one kind logged per call; the rest are counted.

  segyBinaryStructural = ["samplesPerTrace", "formatCode", "extSamplesPerTrace",
    "byteOrderMarker", "segyMajor", "segyMinor", "fixedLengthTraces", "numExtTextHeaders",
    "maxAddlTraceHeaders", "numTraces", "firstTraceOffset", "numTrailerRecords"]
  segyTraceStructural = ["numSamples"]
  segyExt1Structural = ["numAddlTraceHeaders", "extNumSamples", "lastTraceFlag", "headerName"]
  segdTraceStructural = ["scanTypeNumber", "channelSetNumber", "extChannelSetNumber",
    "traceHeaderExtensions"]
  segdExt1Structural = ["samplesPerTrace", "numSamples", "blockType"]
  segdGh1Structural = ["formatCode", "additionalGhBlocks", "baseScanInterval16", "recordLength",
    "scanTypesPerRecord", "channelSetsPerScanType", "skewBlocks", "extendedHeaderBlocks",
    "externalHeaderBlocks"]
  segdGhNStructural = ["blockNumber"]

func toEditValue*(v: SomeInteger): EditValue = EditValue(kind: ekInt, i: int64(v))
func toEditValue*(v: SomeFloat): EditValue = EditValue(kind: ekFloat, f: float64(v))
func toEditValue*(v: string): EditValue = EditValue(kind: ekText, s: v)

func `$`*(v: EditValue): string =
  case v.kind
  of ekInt: $v.i
  of ekFloat: $v.f
  of ekText: v.s.escape

# ---------------------------------------------------------------- journal --

func hexOf(b: openArray[byte]): string =
  result = newStringOfCap(2 * b.len)
  for x in b: result.add toHex(x, 2).toLowerAscii

func nifEscape(s: string): string =
  # NIF string body: `"`, `\`, control and non-ASCII bytes as `\hh`.
  for c in s:
    if c in {'"', '\\'} or ord(c) < 0x20 or ord(c) >= 0x7F: result.add "\\" & toHex(ord(c), 2)
    else: result.add c

proc syncJournal(ed: var HeaderEditor) =
  # The entry must be on disk before the map is written: mapped pages can
  # reach the disk any time after.
  ed.journal.flushFile()
  when defined(posix):
    if fsync(getFileHandle(ed.journal)) != 0:
      raise newException(IOError, "fsync failed: " & ed.journalPath)

proc journalLine(ed: var HeaderEditor, line: string) =
  # After a failed write the file may end in a partial line: start afresh so
  # the next entry does not merge into it.
  if ed.journalBroken: ed.journal.write "\n"
  ed.journalBroken = true
  ed.journal.writeLine line
  ed.syncJournal()
  ed.journalBroken = false

proc openJournal(ed: var HeaderEditor) =
  if not open(ed.journal, ed.journalPath, fmAppend):
    raise newException(IOError, "cannot open the edit journal: " & ed.journalPath)
  ed.journalLine "(session (file \"" & nifEscape(ed.file.path) & "\") (size " &
    $ed.file.mappedSize & "))"

proc journalEdit(ed: var HeaderEditor, at: int64, old, new: openArray[byte], label: string) =
  ed.journalLine "(edit " & $at & " \"" & hexOf(old) & "\" \"" & hexOf(new) & "\" \"" &
    nifEscape(label) & "\")"

type JournalEdit* = object
  ## One journaled edit.
  offset*: int64
  old*, new*: seq[byte]
  label*: string
  line*: int

proc parseString(line: string, i: var int, s: var string): bool =
  # A NIF string literal at `i` with `\hh` escapes.
  while i < line.len and line[i] == ' ': inc i
  if i >= line.len or line[i] != '"': return false
  inc i
  s = ""
  while i < line.len and line[i] != '"':
    if line[i] == '\\':
      if i + 2 >= line.len or line[i + 1] notin HexDigits or line[i + 2] notin HexDigits:
        return false
      s.add char(fromHex[int](line[i + 1 .. i + 2]))
      i += 3
    else:
      s.add line[i]
      inc i
  if i >= line.len: return false
  inc i
  true

proc parseHexBytes(s: string, b: var seq[byte]): bool =
  if s.len mod 2 != 0 or not s.allCharsInSet(HexDigits): return false
  b = newSeq[byte](s.len div 2)
  for k in 0..<b.len: b[k] = byte(fromHex[int](s[2 * k .. 2 * k + 1]))
  true

proc parseEditLine(line: string, e: var JournalEdit): bool =
  # `(edit <offset> "<old hex>" "<new hex>" "<label>")`
  const head = "(edit "
  if not line.startsWith(head): return false
  var i = head.len
  var j = i
  while j < line.len and line[j] in Digits: inc j
  if j == i or j - i > 18: return false
  e.offset = parseBiggestInt(line[i ..< j])
  i = j
  var old, new: string
  if not (parseString(line, i, old) and parseString(line, i, new) and
      parseString(line, i, e.label)): return false
  if not (parseHexBytes(old, e.old) and parseHexBytes(new, e.new)): return false
  if e.old.len != e.new.len or e.old.len == 0: return false
  while i < line.len and line[i] == ' ': inc i
  i == line.len - 1 and line[i] == ')'

proc capped(log: var DiagLog, n: var int, severity: Severity, code: DiagCode, msg: string,
    offset: int64, loc: Location) =
  # Logs the first `MaxRepeats` problems of a kind; `n` counts them all.
  inc n
  if n <= MaxRepeats: log.report(severity, code, msg, offset, loc)

proc summarize(log: var DiagLog, n: int, what: string, loc: Location) =
  if n > MaxRepeats:
    log.report(sevInfo, dcValidation, $(n - MaxRepeats) & " more " & what & " were not logged",
      loc = loc)

proc readJournal*(journalPath: string, log: var DiagLog): seq[JournalEdit] =
  ## The edits of a journal, oldest first. Malformed lines (e.g. one cut short
  ## by a crash) are logged as errors (the first few; then a count) and
  ## skipped; lines longer than 64 KB are malformed and never held whole;
  ## `(session ...)` lines are skipped. Raises `IOError` if the journal cannot
  ## be read.
  var f: File
  if not open(f, journalPath, fmRead):
    raise newException(IOError, "cannot open the edit journal: " & journalPath)
  defer: f.close()
  var bad = 0
  var lineNo = 0
  var line = ""
  var tooLong = false
  var buf {.noinit.}: array[65536, char]
  proc finish(line: var string, tooLong: var bool, lineNo, bad: var int,
      res: var seq[JournalEdit], log: var DiagLog, journalPath: string) {.nimcall.} =
    inc lineNo
    if tooLong or not (line.len == 0 or line.startsWith("(session ")):
      var e = JournalEdit(line: lineNo)
      if not tooLong and parseEditLine(line, e):
        res.add e
      else:
        capped(log, bad, sevError, dcValidation, "malformed journal line " & $lineNo &
          "; skipped", -1, Location(file: journalPath, field: "journal"))
    line.setLen 0
    tooLong = false
  while true:
    let n = f.readChars(buf)
    if n == 0: break
    for k in 0..<n:
      let c = buf[k]
      if c == '\n':
        finish(line, tooLong, lineNo, bad, result, log, journalPath)
      elif not tooLong:
        if line.len >= MaxJournalLine:
          tooLong = true
          line.setLen 0
        elif c != '\r':
          line.add c
  if line.len > 0 or tooLong: finish(line, tooLong, lineNo, bad, result, log, journalPath)
  summarize(log, bad, "malformed journal lines", Location(file: journalPath, field: "journal"))

type
  ByteState = object
    original, final: byte
    label: string # of the last edit touching the byte (for diagnostics)

proc replay(path, journalPath: string, undo: bool): DiagLog =
  # Merges the journal per byte (original = the first edit's old byte, final
  # = the last edit's new byte) and moves each contiguous run of touched
  # bytes as a whole: from final to original (undo) or back (apply). A run
  # already at the target is skipped and any other run is a conflict, so
  # both operations can be repeated, also when a location was edited twice.
  var log: DiagLog
  var edits: seq[JournalEdit]
  if not log.tryRecord(Location(file: journalPath), (edits = readJournal(journalPath, log))):
    return log
  var f: File
  if not open(f, path, fmReadWriteExisting):
    log.report(sevFatal, dcIo, "cannot open for writing", loc = Location(file: path))
    return log
  defer: f.close()
  let size = f.getFileSize
  var bytes: Table[int64, ByteState]
  var pastEnd = 0
  for e in edits:
    if e.offset + e.old.len > size:
      capped(log, pastEnd, sevError, dcInconsistent, "journal line " & $e.line &
        " lies past the end of the file; skipped", e.offset, Location(file: path, field: e.label))
    else:
      for k in 0..<e.old.len:
        let at = e.offset + k
        if at in bytes:
          bytes[at].final = e.new[k]
          bytes[at].label = e.label
        else:
          bytes[at] = ByteState(original: e.old[k], final: e.new[k], label: e.label)
  summarize(log, pastEnd, "journal lines past the end of the file", Location(file: path))
  var offsets = newSeqOfCap[int64](bytes.len)
  for at in bytes.keys: offsets.add at
  offsets.sort()
  var conflicts = 0
  var i = 0
  while i < offsets.len:
    var j = i + 1
    while j < offsets.len and offsets[j] == offsets[j - 1] + 1: inc j
    let at = offsets[i]
    var cur = newSeq[byte](j - i)
    f.setFilePos(at)
    if f.readBytes(cur, 0, cur.len) != cur.len:
      log.report(sevFatal, dcIo, "short read", at, Location(file: path))
      return log
    var target = newSeq[byte](cur.len)
    var atTarget, atSource = true
    for k in 0..<cur.len:
      let b = bytes[offsets[i + k]]
      let (src, dst) = if undo: (b.final, b.original) else: (b.original, b.final)
      target[k] = dst
      if cur[k] != dst: atTarget = false
      if cur[k] != src: atSource = false
    if atTarget:
      discard "already done"
    elif atSource:
      f.setFilePos(at)
      if f.writeBytes(target, 0, target.len) != target.len:
        log.report(sevFatal, dcIo, "write failed", at, Location(file: path))
        return log
    else:
      capped(log, conflicts, sevError, dcInconsistent, "the file holds " & hexOf(cur) &
        ", neither the original nor the edited bytes; left alone", at,
        Location(file: path, field: bytes[at].label))
    i = j
  summarize(log, conflicts, "conflicts", Location(file: path))
  log

proc rollbackJournal*(path, journalPath: string): DiagLog =
  ## Undoes the journal's edits on `path`, newest first. Locations already
  ## holding their original bytes are skipped (so a rollback can be
  ## repeated); conflicts are logged and left alone.
  replay(path, journalPath, undo = true)

proc applyJournal*(path, journalPath: string): DiagLog =
  ## Replays the journal's edits on `path`, oldest first: redo after a
  ## rollback, or the same edits on a copy of the file. Locations already
  ## holding the edited bytes are skipped; conflicts are logged and left alone.
  replay(path, journalPath, undo = false)

# ------------------------------------------------------------------ edits --

proc openEditor*(path: string, journalPath = ""): HeaderEditor =
  ## Maps `path` read-write, builds its trace index and opens the journal
  ## (default `path & ".edits.nif"`) for appending. Raises `IOError`/`OSError`
  ## if either cannot be opened. Problems reading the file are in
  ## `file.index.log`; a file whose index has a fatal problem can still be
  ## edited where its headers were located.
  result = HeaderEditor(file: openSeismic(path, writable = true),
    journalPath: if journalPath.len > 0: journalPath else: path & ".edits.nif")
  result.openJournal()

proc close*(ed: var HeaderEditor) =
  ## Flushes the map and the journal and closes both.
  ed.file.flush()
  ed.file.close()
  if ed.journal != nil:
    ed.journal.close()
    ed.journal = nil

func edits*(ed: HeaderEditor): int {.inline.} =
  ## Edits written in this session (no-op edits excluded).
  ed.edits

template isLayoutField(f: untyped): bool =
  f.hasCustomPragma(fieldlayout.at) or f.hasCustomPragma(bcdAt) or f.hasCustomPragma(bcdAtL) or
    f.hasCustomPragma(nibAt) or f.hasCustomPragma(nibAtL) or f.hasCustomPragma(at24) or
    f.hasCustomPragma(fix40) or f.hasCustomPragma(fix24)

proc assign[F](f: var F, v: EditValue, err: var string): bool =
  when F is SomeInteger:
    var i: int64
    case v.kind
    of ekInt: i = v.i
    of ekFloat:
      if not (v.f == trunc(v.f) and abs(v.f) < 9.2e18):
        err = $v & " is not an integer"
        return false
      i = int64(v.f)
    of ekText:
      err = "expects a number"
      return false
    when F is uint64:
      if i < 0:
        err = $v & " is out of range for uint64"
        return false
    else:
      if i < int64(low(F)) or uint64(max(i, 0)) > uint64(high(F)):
        err = $v & " is out of range for " & $F
        return false
    f = F(i)
    true
  elif F is SomeFloat:
    var x: float64
    case v.kind
    of ekInt: x = float64(v.i)
    of ekFloat: x = v.f
    of ekText:
      err = "expects a number"
      return false
    when F is float32:
      # NaN and infinities pass (+Inf means "not set" in SEG-D Rev 3).
      if abs(x) != Inf and abs(x) > float64(high(float32)):
        err = $v & " is out of range for float32"
        return false
    f = F(x)
    true
  elif F is array and typeof(f[0]) is char:
    if v.kind != ekText or v.s.len > f.len:
      err = "expects text of at most " & $f.len & " characters"
      return false
    for k in 0..<f.len: f[k] = (if k < v.s.len: v.s[k] else: ' ')
    true
  else:
    err = "raw bytes cannot be edited as a field"
    false

proc setByName[T](h: var T, name: string, v: EditValue, err: var string): bool =
  var found = false
  for n, f in fieldPairs(h):
    when isLayoutField(f):
      if n == name:
        found = true
        result = assign(f, v, err)
  if not found:
    err = "is not an editable field"
    result = false

proc editBlock[T](ed: var HeaderEditor, at: int64, size: int, firstByte: static int,
    order: ByteOrder, blockName, field: string, structural: openArray[string],
    v: EditValue, loc: Location): bool =
  # Decodes the block at `at`, sets the field, re-encodes only what changed,
  # journals the changed span and writes it.
  template refuse(msg: string) =
    var l = loc
    l.field = blockName & "." & field
    ed.log.report(sevError, dcValidation, blockName & "." & field & ": " & msg, at, l)
    return false
  if ed.file.memory == nil: refuse "the file is closed"
  if not ed.file.index.detected: refuse "the file is neither SEG-Y nor SEG-D"
  if at < 0 or at + size > ed.file.mappedSize: refuse "the header lies outside the file"
  if field in structural:
    refuse "changes the file's structure (sizes or counts); rewrite the file instead"
  let mem = ed.file.memory
  let a = int(at)
  var h: T
  decodeFields(h, mem.toOpenArray(a, a + size - 1), firstByte, order)
  var err = ""
  if not setByName(h, field, v, err): refuse err
  var buf = newSeq[byte](size)
  copyMem(addr buf[0], addr mem[a], size)
  try:
    encodeChanged(h, buf, firstByte, order)
  except SegFormatError as e:
    refuse e.msg
  var first = 0
  while first < size and buf[first] == mem[a + first]: inc first
  if first == size: return true # no change
  var last = size - 1
  while buf[last] == mem[a + last]: dec last
  let label = (if loc.trace >= 0: "trace " & $loc.trace & " "
               elif loc.record >= 0: "record " & $loc.record & " " else: "") &
    blockName & "." & field
  try:
    ed.journalEdit(at + first, mem.toOpenArray(a + first, a + last),
      buf.toOpenArray(first, last), label)
  except IOError as e:
    refuse "the journal cannot be written (" & e.msg & "); nothing changed"
  copyMem(addr mem[a + first], addr buf[first], last - first + 1)
  inc ed.edits
  true

func splitName(name: string, blockName, field: var string): bool =
  let dot = name.find('.')
  if dot <= 0 or dot == name.len - 1: return false
  blockName = name[0 ..< dot]
  field = name[dot + 1 .. ^1]
  true

proc refuseName(ed: var HeaderEditor, name, msg: string, loc: Location): bool =
  var l = loc
  l.field = name
  ed.log.report(sevError, dcValidation, name & ": " & msg, loc = l)
  false

proc setField*(ed: var HeaderEditor, trace: int, name: string, value: EditValue): bool =
  ## Sets field `name` (`trace.<field>` or `ext1.<field>`) of trace `trace`.
  ## False, with a diagnostic in `log`, if the edit is refused.
  let ix = addr ed.file.index
  var loc = Location(file: ed.file.path, trace: trace)
  var blockName, field: string
  if not splitName(name, blockName, field):
    return ed.refuseName(name, "expected <block>.<field>", loc)
  if trace < 0 or trace >= ix[].len:
    return ed.refuseName(name, "no trace " & $trace, loc)
  let e = ix.entries[trace]
  loc.record = int(e.record)
  if ix.kind == skSegy:
    let order = ix.segy.byteOrder
    case blockName
    of "trace":
      ed.editBlock[:SegyTraceHeader](e.offset, TraceHeaderSize, 1, order, blockName, field,
        segyTraceStructural, value, loc)
    of "ext1":
      if int(e.headerBytes) < 2 * TraceHeaderSize:
        ed.refuseName(name, "the trace has no Trace Header Extension 1", loc)
      else:
        ed.editBlock[:SegyTraceHeaderExt1](e.offset + TraceHeaderSize, TraceHeaderSize, 1,
          order, blockName, field, segyExt1Structural, value, loc)
    else: ed.refuseName(name, "SEG-Y trace blocks are trace and ext1", loc)
  else:
    case blockName
    of "trace":
      ed.editBlock[:SegdTraceHeader](e.offset, SegdTraceHeaderSize, 1, boBig, blockName, field,
        segdTraceStructural, value, loc)
    of "ext1":
      if int(e.headerBytes) < SegdTraceHeaderSize + SegdBlockSize:
        ed.refuseName(name, "the trace has no Trace Header Extension #1", loc)
      elif ix.segdRecords[e.record].isRev3:
        ed.editBlock[:SegdTraceHeaderExt1Rev3](e.offset + SegdTraceHeaderSize, SegdBlockSize, 1,
          boBig, blockName, field, segdExt1Structural, value, loc)
      else:
        ed.editBlock[:SegdTraceHeaderExt1](e.offset + SegdTraceHeaderSize, SegdBlockSize, 1,
          boBig, blockName, field, segdExt1Structural, value, loc)
    else: ed.refuseName(name, "SEG-D trace blocks are trace and ext1", loc)

proc setField*(ed: var HeaderEditor, name: string, value: EditValue): bool =
  ## Sets a SEG-Y binary header field (`binary.<field>`); the index's copy of
  ## the binary header is refreshed.
  let ix = addr ed.file.index
  let loc = Location(file: ed.file.path)
  var blockName, field: string
  if not splitName(name, blockName, field) or blockName != "binary" or ix.kind != skSegy:
    return ed.refuseName(name, "file-level fields are SEG-Y binary.<field>", loc)
  let at = int64(ix.segy.tapeLabel.len + TextHeaderSize)
  let order = ix.segy.byteOrder
  result = ed.editBlock[:SegyBinaryHeader](at, BinaryHeaderSize, 3201, order, blockName, field,
    segyBinaryStructural, value, loc)
  if result:
    ix.segy.binary = decodeBinaryHeader(ed.file.memory.toOpenArray(int(at),
      int(at) + BinaryHeaderSize - 1), order)

proc setRecordField*(ed: var HeaderEditor, record: int, name: string,
    value: EditValue): bool =
  ## Sets a SEG-D general header field of record `record`: `gh1.<field>`, or
  ## for Rev 1/2 `gh<N>.<field>` (N ≥ 3: the source headers). The index's
  ## copy of the record's headers is refreshed.
  let ix = addr ed.file.index
  let loc = Location(file: ed.file.path, record: record)
  var blockName, field: string
  if not splitName(name, blockName, field):
    return ed.refuseName(name, "expected <block>.<field>", loc)
  if ix.kind != skSegd or record < 0 or record >= ix.segdRecords.len:
    return ed.refuseName(name, "no SEG-D record " & $record, loc)
  let rec = addr ix.segdRecords[record]
  if blockName == "gh1":
    result = ed.editBlock[:SegdGeneralHeader1](rec.offset, SegdBlockSize, 1, boBig, blockName,
      field, segdGh1Structural, value, loc)
    if result:
      rec.gh1 = decodeBlock[SegdGeneralHeader1](ed.file.memory.toOpenArray(int(rec.offset),
        int(rec.offset) + SegdBlockSize - 1))
  elif blockName.len in 3..6 and blockName.startsWith("gh") and
      blockName[2..^1].allCharsInSet(Digits):
    let n = parseInt(blockName[2..^1])
    if rec.isRev3 or not rec.hasGh2:
      result = ed.refuseName(name, "only Rev 1/2 records have source blocks gh3, gh4, ... " &
        "(Rev 3 general header blocks after GH#1 are not editable in place yet)", loc)
    elif n < 3 or n - 3 >= rec.sourceHeaders.len:
      result = ed.refuseName(name, "the record has no general header #" & $n & " source block", loc)
    else:
      let at = rec.offset + int64(SegdBlockSize) * int64(n - 1)
      result = ed.editBlock[:SegdGeneralHeaderN](at, SegdBlockSize, 1, boBig, blockName, field,
        segdGhNStructural, value, loc)
      if result:
        rec.sourceHeaders[n - 3] = decodeBlock[SegdGeneralHeaderN](
          ed.file.memory.toOpenArray(int(at), int(at) + SegdBlockSize - 1))
  else:
    result = ed.refuseName(name, "SEG-D record blocks are gh1 and gh3, gh4, ...", loc)

proc setField*(ed: var HeaderEditor, trace: int, name: string,
    value: SomeNumber | string): bool {.inline.} =
  ed.setField(trace, name, toEditValue(value))

proc setField*(ed: var HeaderEditor, name: string, value: SomeNumber | string): bool {.inline.} =
  ed.setField(name, toEditValue(value))

proc setRecordField*(ed: var HeaderEditor, record: int, name: string,
    value: SomeNumber | string): bool {.inline.} =
  ed.setRecordField(record, name, toEditValue(value))
