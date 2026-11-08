## In-place header edits on disk, with an undo journal (task 6.6).
##
## Updating positions, coordinates or statics in place is far faster than
## re-exporting a file. A `HeaderEditor` maps the file read-write, locates a
## header through the trace index, and changes one field at a time:
##
## ```nim
## var ed = openEditor("line.sgy")              # journal: line.sgy.edits.nif
## discard ed.setTraceField(17, "trace.sourceX", 512_300)
## discard ed.setFileField("binary.sampleInterval", 2000)
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
## raises. A journal entry that cannot be written or synced to disk refuses
## its edit (and, in a batch, every edit not yet on the map): the map is
## written only after its journal entry is safely on disk, and the entries
## of refused edits are cut from the journal again (if that fails, the
## editor refuses all further edits). Not available on
## tape (there is no map); `contiguous` sources only.
##
## Fields are named `<block>.<field>`, with the field names of the header
## types:
##
## - SEG-Y: `binary` (`setFileField(name, value)`), `trace` and `ext1` (Trace
##   Header Extension 1);
## - SEG-D: `trace` (demux header) and `ext1` (THE#1, in the Rev 1/2 or Rev 3
##   layout of its record), and via `setRecordField` `gh1` and, for Rev 1/2,
##   `gh3`, `gh4`, ... (source headers).
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

import std/[algorithm, macros, math, options, os, strutils, tables]
when defined(posix):
  import std/posix
import ../common/[endians, errors, diagnostics, fieldlayout, niftext]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ./[traceindex, headerfields]
import ../abi/pragmas


type
  JournalFile = object
    ## The open journal: closed when it goes, so an editor dropped without
    ## `close` does not leak its descriptor (the file unmaps on its own).
    f: File

  HeaderEditor* {.segHandle.} = object
    ## An open file with its journal. Call `close` to flush both.
    file*: SeismicFile   ## The mapped file and its index (headers as opened).
    log* {.segField(readonly = true).}: DiagLog ## Refused edits and journal problems.
    journalPath* {.segField(readonly = true).}: string ## Where the edits are journaled.
    journal: JournalFile ## Unbuffered: entries wait in `unsynced` (see `syncJournal`).
    unsynced: string     ## Journal lines not yet written and synced.
    journalDead: bool    ## The journal could not be cut back after a failed write.
    edits: int
    batch: bool          ## Inside `beginBatch` / `endBatch`.
    pending: seq[PendingWrite] ## Batched writes, journaled but not yet on the map.

  PendingWrite = object
    at: int64
    bytes: seq[byte]

proc `=destroy`(j: JournalFile) =
  if j.f != nil:
    try: j.f.close()
    except CatchableError: discard

proc `=copy`(dst: var JournalFile, src: JournalFile) {.error.}

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

# ---------------------------------------------------------------- journal --

func hexOf(b: openArray[byte]): string =
  result = newStringOfCap(2 * b.len)
  for x in b: result.add toHex(x, 2).toLowerAscii

when defined(windows):
  proc c_fileno(f: File): cint {.importc: "_fileno", header: "<stdio.h>".}
  proc c_chsize(fd: cint, size: int64): cint {.importc: "_chsize_s", header: "<io.h>".}

proc journalSize(f: File): int64 =
  # The journal's size on disk; -1 if it cannot be told.
  when defined(posix):
    var st: Stat
    if fstat(getFileHandle(f), st) != 0: -1'i64 else: int64(st.st_size)
  else:
    try: f.getFileSize except IOError: -1'i64

proc cutJournal(f: File, size: int64): bool =
  # Truncates the journal back to `size` bytes (it is unbuffered, so no
  # stdio buffer holds anything to write later).
  when defined(posix):
    ftruncate(getFileHandle(f), Off(size)) == 0
  elif defined(windows):
    c_chsize(c_fileno(f), size) == 0
  else:
    false

proc syncJournal(ed: var HeaderEditor): bool =
  # Writes the unsynced journal lines and syncs them: they must be on disk
  # before the map is written, as mapped pages can reach the disk any time
  # after. On failure the journal is cut back to its size before them, so
  # it never keeps entries of refused edits, and the result is false. When
  # it cannot be cut back, the editor refuses every further edit.
  if ed.unsynced.len == 0: return true
  if ed.journalDead:
    ed.unsynced.setLen 0
    return false
  let f = ed.journal.f
  let mark = journalSize(f)
  var ok = mark >= 0
  if ok:
    try:
      ok = f.writeBuffer(addr ed.unsynced[0], ed.unsynced.len) == ed.unsynced.len
    except IOError:
      ok = false
  when defined(posix):
    if ok: ok = fsync(getFileHandle(f)) == 0
  ed.unsynced.setLen 0
  if not ok and mark >= 0 and not cutJournal(f, mark):
    ed.journalDead = true
    ed.log.report(sevError, dcIo, "the journal " & ed.journalPath & " could not be cut " &
      "back after a failed write: it may end in entries of refused edits (remove them " &
      "before applying it); no further edits are made", loc = Location(file: ed.file.path))
  ok

proc journalLine(ed: var HeaderEditor, line: string) =
  # Adds a journal line; outside a batch it is synced at once, in a batch the
  # sync waits for `flushBatch` (the map is written only after it). Raises
  # `IOError` when the line cannot be written or synced.
  ed.unsynced.add line
  ed.unsynced.add '\n'
  if not ed.batch and not ed.syncJournal():
    raise newException(IOError, "cannot write or sync the journal " & ed.journalPath)

const MaxPending = 4096 ## Batched edits held before a flush.

proc dropPending(ed: var HeaderEditor) =
  # The batch's journal entries were not synced: its edits never reach the map.
  ed.log.report(sevError, dcIo, "the journal " & ed.journalPath & " cannot be synced; " &
    $ed.pending.len & " batched edits were not written", loc = Location(file: ed.file.path))
  ed.edits -= ed.pending.len
  ed.pending.setLen 0

proc flushBatch(ed: var HeaderEditor): bool =
  # One sync for every journaled edit of the batch, then the map writes.
  # When the journal cannot be synced, the batch's edits are dropped (the
  # map never sees them), logged, and the result is false.
  result = true
  if ed.pending.len == 0: return
  if not ed.syncJournal():
    ed.dropPending()
    return false
  let mem = ed.file.unsafeMemory
  for p in ed.pending:
    copyMem(addr mem[p.at], addr p.bytes[0], p.bytes.len)
  ed.pending.setLen 0

proc overlapsPending(ed: HeaderEditor, at: int64, size: int): bool =
  for p in ed.pending:
    if at < p.at + p.bytes.len and p.at < at + size: return true

proc beginBatch*(ed: var HeaderEditor) =
  ## Starts a batch: edits are journaled at once but synced and written to the
  ## map together, up to 4096 at a time (one fsync instead of one per edit).
  ## Reads through `file` may not see an edit until `endBatch`.
  ed.batch = true

proc endBatch*(ed: var HeaderEditor): bool =
  ## Syncs the journal and writes the batch's edits; ends the batch. False
  ## when the journal cannot be synced: then the batch's pending edits are
  ## not written (an error in `log` says how many) and their entries are cut
  ## from the journal.
  result = ed.flushBatch()
  ed.batch = false

proc openJournal(ed: var HeaderEditor) =
  if not open(ed.journal.f, ed.journalPath, fmAppend, bufSize = 0):
    raise newException(IOError, "cannot open the edit journal: " & ed.journalPath)
  ed.journalLine "(session (file " & nifString(ed.file.path) & ") (size " &
    $ed.file.mappedSize & "))"

proc journalEdit(ed: var HeaderEditor, at: int64, old, new: openArray[byte], label: string) =
  ed.journalLine "(edit " & $at & " \"" & hexOf(old) & "\" \"" & hexOf(new) & "\" " &
    nifString(label) & ")"

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

proc rollbackJournal*(path, journalPath: string): DiagLog {.segApi.} =
  ## Undoes the journal's edits on `path`, newest first. Locations already
  ## holding their original bytes are skipped (so a rollback can be
  ## repeated); conflicts are logged and left alone.
  replay(path, journalPath, undo = true)

proc applyJournal*(path, journalPath: string): DiagLog {.segApi.} =
  ## Replays the journal's edits on `path`, oldest first: redo after a
  ## rollback, or the same edits on a copy of the file. Locations already
  ## holding the edited bytes are skipped; conflicts are logged and left alone.
  replay(path, journalPath, undo = false)

# ------------------------------------------------------------------ edits --

proc openEditor*(path: string, journalPath = ""): HeaderEditor {.segApi.} =
  ## Maps `path` read-write, builds its trace index and opens the journal
  ## (default `path & ".edits.nif"`) for appending. Raises `IOError`/`OSError`
  ## if either cannot be opened, and `ValueError` if the journal is the file
  ## itself or the file holds multiplexed SEG-D (convert it to a
  ## demultiplexed file first; see `openSeismic`). Problems reading the file
  ## are in `file.index.log`; a file whose index has a fatal problem can
  ## still be edited where its headers were located.
  let jp = if journalPath.len > 0: journalPath else: path & ".edits.nif"
  if jp == path or (fileExists(jp) and fileExists(path) and sameFile(jp, path)):
    raise newException(ValueError, "the journal " & jp & " is the file being edited")
  result = HeaderEditor(file: openSeismic(path, writable = true), journalPath: jp)
  result.openJournal()

proc close*(ed: var HeaderEditor) {.segApi.} =
  ## Ends a batch, flushes the map and closes it and the journal. Both are
  ## closed even when something fails. Raises `IOError` when the map cannot
  ## be flushed, or when the batch's journal entries cannot be synced: then
  ## its pending edits are not written (see `endBatch`; `log` says how many).
  var synced = true
  try:
    if ed.batch: synced = ed.endBatch()
    ed.file.flush()
  finally:
    ed.file.close()
    if ed.journal.f != nil:
      ed.journal.f.close()
      ed.journal.f = nil
  if not synced:
    raise newException(IOError, "the journal " & ed.journalPath &
      " cannot be synced; the batch's pending edits were not written")

func edits*(ed: HeaderEditor): int {.inline, segApi.} =
  ## Edits written in this session (no-op edits excluded).
  ed.edits

proc assign[F](f: var F, v: FieldValue, err: var string): bool =
  when F is SomeInteger:
    var i: int64
    case v.kind
    of fvInt: i = v.intVal
    of fvFloat:
      if not (v.floatVal == trunc(v.floatVal) and abs(v.floatVal) < 9.2e18):
        err = $v & " is not an integer"
        return false
      i = int64(v.floatVal)
    of fvText:
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
    of fvInt: x = float64(v.intVal)
    of fvFloat: x = v.floatVal
    of fvText:
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
    if v.kind != fvText or v.text.len > f.len:
      err = "expects text of at most " & $f.len & " characters"
      return false
    for k in 0..<f.len: f[k] = (if k < v.text.len: v.text[k] else: ' ')
    true
  else:
    err = "raw bytes cannot be edited as a field"
    false

proc setByName[T](h: var T, name: string, v: FieldValue, err: var string): bool =
  var found = false
  for n, f in fieldPairs(h):
    when isLayoutField(f):
      if n == name:
        found = true
        result = assign(f, v, err)
  if not found:
    err = "is not an editable field"
    result = false

func structural(k: HeaderBlock): seq[string] =
  case k
  of hbSegyBinary: @segyBinaryStructural
  of hbSegyTrace: @segyTraceStructural
  of hbSegyExt1: @segyExt1Structural
  of hbSegdTrace: @segdTraceStructural
  of hbSegdExt1, hbSegdExt1Rev3: @segdExt1Structural
  of hbSegdGh1: @segdGh1Structural
  of hbSegdGhN: @segdGhNStructural
  else: @[] # not reachable by name (listings only)

proc commitSpan(ed: var HeaderEditor, at: int64, buf: openArray[byte], label: string): string =
  # Journals and writes the bytes of `buf` (meant for `at ..< at + buf.len`,
  # inside the map) that differ from the map, as one span from the first to
  # the last changed byte. "" when done (also when nothing differs), else
  # why nothing changed.
  let mem = ed.file.unsafeMemory
  let a = int(at)
  let size = buf.len
  var first = 0
  while first < size and buf[first] == mem[a + first]: inc first
  if first == size: return "" # no change
  var last = size - 1
  while buf[last] == mem[a + last]: dec last
  try:
    ed.journalEdit(at + first, mem.toOpenArray(a + first, a + last),
      buf.toOpenArray(first, last), label)
  except IOError as e:
    return "the journal cannot be written (" & e.msg & "); nothing changed"
  inc ed.edits
  if ed.batch:
    ed.pending.add PendingWrite(at: at + first, bytes: @(buf.toOpenArray(first, last)))
    if ed.pending.len >= MaxPending and not ed.flushBatch():
      return "the journal cannot be synced; this batch's pending edits were not written"
  else:
    copyMem(addr mem[a + first], addr buf[first], last - first + 1)
  ""

proc editBlock[T](ed: var HeaderEditor, b: BlockRef, firstByte: static int, field: string,
    v: FieldValue, loc: Location): bool =
  # Decodes the block, sets the field, re-encodes only what changed, journals
  # the changed span and writes it.
  let at = b.offset
  let size = b.size
  template refuse(msg: string) =
    var l = loc
    l.field = b.name & "." & field
    ed.log.report(sevError, dcValidation, b.name & "." & field & ": " & msg, at, l)
    return false
  if not ed.file.isOpen: refuse "the file is closed"
  if not ed.file.index.detected: refuse "the file is neither SEG-Y nor SEG-D"
  if ed.journalDead: refuse "the journal could not be cut back after a failed write; no edits"
  if at < 0 or at + size > ed.file.mappedSize: refuse "the header lies outside the file"
  if field in structural(b.kind):
    refuse "changes the file's structure (sizes or counts); rewrite the file instead"
  if ed.batch and ed.overlapsPending(at, size) and not ed.flushBatch(): # decode current bytes
    refuse "the journal cannot be synced; nothing changed"
  let mem = ed.file.unsafeMemory
  let a = int(at)
  var h: T
  decodeFields(h, mem.toOpenArray(a, a + size - 1), firstByte, b.order)
  var err = ""
  if not setByName(h, field, v, err): refuse err
  var buf = newSeq[byte](size)
  copyMem(addr buf[0], addr mem[a], size)
  try:
    encodeChanged(h, buf, firstByte, b.order)
  except SegFormatError as e:
    refuse e.msg
  let label = (if loc.trace >= 0: "trace " & $loc.trace & " "
               elif loc.record >= 0: "record " & $loc.record & " " else: "") &
    b.name & "." & field
  let failure = ed.commitSpan(at, buf, label)
  if failure.len > 0: refuse failure
  true

proc editLocated(ed: var HeaderEditor, b: BlockRef, field: string, v: FieldValue,
    loc: Location): bool =
  withBlockType(b.kind):
    result = ed.editBlock[:BlockT](b, firstByte, field, v, loc)

proc writeBytes*(ed: var HeaderEditor, at: int64, bytes: openArray[byte], label: string,
    loc: Location): bool =
  ## **Internal.** Journals and writes the bytes of `bytes` (for the file's
  ## bytes `at ..< at + bytes.len`) that differ from the file, as one span:
  ## for edits that named fields do not cover, such as geometry written
  ## through a SEG-Y Layout stanza (`survey/writeback`). The caller encodes
  ## and checks the values and keeps clear of structural fields. A no-op
  ## writes nothing. False, with an error in `log` labelled `label`, when
  ## refused.
  template refuse(msg: string) =
    var l = loc
    l.field = label
    ed.log.report(sevError, dcValidation, label & ": " & msg, at, l)
    return false
  if not ed.file.isOpen: refuse "the file is closed"
  if ed.journalDead: refuse "the journal could not be cut back after a failed write; no edits"
  if bytes.len == 0: return true
  if at < 0 or at + bytes.len > ed.file.mappedSize: refuse "the bytes lie outside the file"
  if ed.batch and ed.overlapsPending(at, bytes.len) and not ed.flushBatch():
    refuse "the journal cannot be synced; nothing changed"
  let failure = ed.commitSpan(at, bytes, label)
  if failure.len > 0: refuse failure
  true

func batching*(ed: HeaderEditor): bool {.inline.} =
  ## **Internal.** Inside `beginBatch` / `endBatch`.
  ed.batch

proc flushPending*(ed: var HeaderEditor): bool =
  ## **Internal.** Writes the batch's pending edits now (the batch goes on),
  ## so the map holds every edit made so far. False, like `endBatch`, when
  ## the journal cannot be synced.
  ed.flushBatch()

proc refuseName(ed: var HeaderEditor, name, msg: string, loc: Location): bool =
  var l = loc
  l.field = name
  ed.log.report(sevError, dcValidation, name & ": " & msg, loc = l)
  false

proc current(ed: var HeaderEditor, scope: HeaderScope, index: int, name: string): FieldValue =
  let r = ed.file.index.locate(scope, index, name)
  if r.error.len > 0: raise newException(ValueError, name & ": " & r.error)
  if ed.batch and ed.overlapsPending(r.blk.offset, r.blk.size) and not ed.flushBatch():
    raise newException(IOError, name & ": the journal " & ed.journalPath &
      " cannot be synced; the batch's pending edits were not written")
  let v = ed.file.readField(r.blk, r.field)
  if v.error.len > 0: raise newException(ValueError, name & ": " & v.error)
  v.value

proc currentTraceField*(ed: var HeaderEditor, trace: int, name: string): FieldValue =
  ## Reads `trace.<field>` / `ext1.<field>` of trace `trace` as edited so far
  ## (batched edits included). Raises `ValueError` like `traceField`, and
  ## `IOError` when pending batched edits of the header must be written
  ## first and the journal cannot be synced (they are then dropped, see
  ## `endBatch`).
  ed.current(hsTrace, trace, name)

proc currentRecordField*(ed: var HeaderEditor, record: int, name: string): FieldValue =
  ## Reads a SEG-D record field as edited so far. Raises like
  ## `currentTraceField`.
  ed.current(hsRecord, record, name)

proc currentFileField*(ed: var HeaderEditor, name: string): FieldValue =
  ## Reads a SEG-Y binary header field as edited so far. Raises like
  ## `currentTraceField`.
  ed.current(hsFile, 0, name)

proc setLocated(ed: var HeaderEditor, scope: HeaderScope, index: int, name: string,
    value: FieldValue, loc: Location, b: var BlockRef): bool =
  # Locates `name` and edits it; refuses (false, logged) when it cannot.
  let r = ed.file.index.locate(scope, index, name)
  if r.error.len > 0: return ed.refuseName(name, r.error, loc)
  b = r.blk
  ed.editLocated(r.blk, r.field, value, loc)

proc setTraceField*(ed: var HeaderEditor, trace: int, name: string, value: FieldValue): bool {.
    segApi.} =
  ## Sets field `name` (`trace.<field>` or `ext1.<field>`) of trace `trace`.
  ## False, with a diagnostic in `log`, if the edit is refused.
  var loc = Location(file: ed.file.path, trace: trace)
  if trace in 0 ..< ed.file.len: loc.record = int(ed.file.index.entries[trace].record)
  var b: BlockRef
  ed.setLocated(hsTrace, trace, name, value, loc, b)

proc setFileField*(ed: var HeaderEditor, name: string, value: FieldValue): bool {.segApi.} =
  ## Sets a SEG-Y binary header field (`binary.<field>`); the index's copy of
  ## the binary header is refreshed. False, with a diagnostic in `log`, if
  ## the edit is refused.
  var b: BlockRef
  result = ed.setLocated(hsFile, 0, name, value, Location(file: ed.file.path), b) and
    ed.flushBatch() # the index copy is refreshed from the map
  if result:
    ed.file.index.segy.binary = decodeBinaryHeader(ed.file.unsafeMemory.toOpenArray(int(b.offset),
      int(b.offset) + b.size - 1), b.order)

proc setRecordField*(ed: var HeaderEditor, record: int, name: string,
    value: FieldValue): bool {.segApi.} =
  ## Sets a SEG-D general header field of record `record`: `gh1.<field>`, or
  ## for Rev 1/2 `gh<N>.<field>` (N ≥ 3: the source headers). The index's
  ## copy of the record's headers is refreshed. False, with a diagnostic in
  ## `log`, if the edit is refused.
  var b: BlockRef
  result = ed.setLocated(hsRecord, record, name, value,
    Location(file: ed.file.path, record: record), b) and ed.flushBatch()
  if result:
    let (a, z) = (int(b.offset), int(b.offset) + b.size - 1)
    if b.kind == hbSegdGh1:
      ed.file.index.segdRecords[record].gh1 =
        decodeBlock[SegdGeneralHeader1](ed.file.unsafeMemory.toOpenArray(a, z))
    else:
      ed.file.index.segdRecords[record].sourceHeaders[b.sourceIndex] =
        decodeBlock[SegdGeneralHeaderN](ed.file.unsafeMemory.toOpenArray(a, z))

proc setTraceField*(ed: var HeaderEditor, trace: int, name: string,
    value: SomeNumber | string): bool {.inline.} =
  ## `setTraceField` with a plain number or text.
  ed.setTraceField(trace, name, toFieldValue(value))

proc setFileField*(ed: var HeaderEditor, name: string,
    value: SomeNumber | string): bool {.inline.} =
  ## `setFileField` with a plain number or text.
  ed.setFileField(name, toFieldValue(value))

proc setRecordField*(ed: var HeaderEditor, record: int, name: string,
    value: SomeNumber | string): bool {.inline.} =
  ## `setRecordField` with a plain number or text.
  ed.setRecordField(record, name, toFieldValue(value))
