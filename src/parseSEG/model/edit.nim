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
## A file already open (`openSeismic`) is taken over with `openEditor(f)`,
## which keeps its index (joined keys included); `release` hands it back.
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
## Stored keys (`openSeismic(keys = true)`) follow the edits: a trace,
## record or keyed binary field edit refreshes the keys of the traces it
## touches once its bytes are on the map (a batch's at `endBatch`) and bumps
## `keysRevision` when they changed. Keys a join wrote (`applyGeometry`,
## `applySurvey`: `TraceIndex.joinedTraces`, by `JoinGroup`) keep their joined
## values; the trace's other keys follow its headers, and an offset and
## midpoint the join derived follow an end it left to the headers.
##
## `rollbackJournal` undoes a journal (newest first), `applyJournal` replays
## it (oldest first); their editor forms do it on the open file and refresh
## its cached headers and keys. Both check each location first: bytes that
## already hold the target are skipped, and so are the bytes of an edit that
## was journaled but never written (an interrupted session), also where that
## edit overlaps or abuts an earlier one. Bytes that hold none of the values
## the journal's edits gave them are a conflict, logged and left alone.

import std/[algorithm, macros, math, options, os, strutils, tables]
when defined(posix):
  import std/posix
import ../common/[endians, errors, diagnostics, fieldlayout, niftext]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ./[traceindex, headerfields]
import ../private/fieldaccess


type
  JournalFile = object
    ## The open journal: closed when it goes, so an editor dropped without
    ## `close` does not leak its descriptor (the file unmaps on its own).
    f: File

  HeaderEditor* = object
    ## An open file with its journal. Call `close` to flush both.
    file: SeismicFile    ## See `file`.
    log: DiagLog         ## See `log`.
    journalPath: string  ## See `journalPath`.
    journal: JournalFile ## Unbuffered: entries wait in `unsynced` (see `syncJournal`).
    unsynced: string     ## Journal lines not yet written and synced.
    journalDead: bool    ## The journal could not be cut back after a failed write.
    edits: int
    stale: seq[int] ## Traces edited in the batch: their keys are refreshed when it is written.
    intervalStale: bool ## A batched interval edit: `segyIntervalUs` is refreshed with the keys.
    batch: bool          ## Inside `beginBatch` / `endBatch`.
    pending: seq[PendingWrite] ## Batched writes, journaled but not yet on the map.
    pendingPages: Table[int64, seq[int32]]
      ## `pending` indices by the 4 KiB pages their bytes touch, so an edit
      ## finds the pending writes under its block without a scan.

  PendingWrite = object
    at: int64
    bytes: seq[byte]

proc `=destroy`(j: JournalFile) =
  if j.f != nil:
    try: j.f.close()
    except CatchableError: discard

proc `=copy`(dst: var JournalFile, src: JournalFile) {.error.}
proc `=dup`(src: JournalFile): JournalFile {.error.}

const
  MaxJournalLine = 1 shl 16 ## Longer journal lines are malformed.
  MaxRepeats = 5 ## Journal diagnostics of one kind logged per call; the rest are counted.


# ---------------------------------------------------------------- journal --

func hexOf(b: openArray[byte]): string =
  # Two lowercase digits per byte, from a table: `toHex` and `toLowerAscii`
  # allocate two strings per byte (57 % of a geometry write-back).
  const digits = "0123456789abcdef"
  result = newString(2 * b.len)
  for i, x in b:
    result[2 * i] = digits[int(x shr 4)]
    result[2 * i + 1] = digits[int(x and 15)]

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
  ed.pendingPages.clear()
  ed.stale.setLen 0

proc refreshStale(ed: var HeaderEditor) =
  # The keys of the traces edited since the last refresh, from the map.
  if ed.stale.len == 0: return
  ed.stale.sort()
  var u = newSeqOfCap[int](ed.stale.len)
  for t in ed.stale:
    if u.len == 0 or u[^1] != t: u.add t
  ed.stale.setLen 0
  discard ed.file.refreshKeys(u)

proc keysChanged(ed: var HeaderEditor, trace: int) =
  # Trace `trace`'s headers changed: refresh its keys now, or when the batch
  # reaches the map.
  if trace < 0 or not ed.file.hasKeys: return
  ed.stale.add trace
  if not ed.batch: ed.refreshStale()

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
  ed.pendingPages.clear()
  ed.refreshStale()
  if ed.intervalStale:
    ed.intervalStale = false
    ed.file.refreshSegyInterval()

const PageShift = 12

proc pendingUnder(ed: HeaderEditor, at: int64, size: int): seq[int32] =
  # The pending writes overlapping `at ..< at + size`, oldest first.
  if size <= 0 or ed.pending.len == 0: return
  for page in (at shr PageShift) .. ((at + size - 1) shr PageShift):
    for i in ed.pendingPages.getOrDefault(page):
        let p = ed.pending[i]
        if at < p.at + p.bytes.len and p.at < at + size and i notin result: result.add i
  result.sort()

proc overlapsPending(ed: HeaderEditor, at: int64, size: int): bool =
  ed.pendingUnder(at, size).len > 0

proc addPending(ed: var HeaderEditor, at: int64, bytes: openArray[byte]) =
  let i = int32(ed.pending.len)
  ed.pending.add PendingWrite(at: at, bytes: @bytes)
  for page in (at shr PageShift) .. ((at + bytes.len - 1) shr PageShift):
    ed.pendingPages.mgetOrPut(page, @[]).add i

proc currentBytes(ed: HeaderEditor, at: int64, size: int): seq[byte] =
  # The bytes `at ..< at + size` as edited so far: the map, with the batch's
  # pending writes laid over it in order.
  let mem = ed.file.unsafeMemory
  result = newSeq[byte](size)
  if size > 0: copyMem(addr result[0], addr mem[at], size)
  for i in ed.pendingUnder(at, size):
    let p = ed.pending[i]
    let a = max(at, p.at)
    let b = min(at + size, p.at + p.bytes.len)
    copyMem(addr result[a - at], addr p.bytes[a - p.at], b - a)

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

func hexVal(c: char): int {.inline.} =
  # The value of a hex digit, -1 for any other character.
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc parseHexBytes(s: string, b: var seq[byte]): bool =
  if s.len mod 2 != 0: return false
  b = newSeq[byte](s.len div 2)
  for k in 0..<b.len:
    let (h, l) = (hexVal(s[2 * k]), hexVal(s[2 * k + 1]))
    if h < 0 or l < 0: return false
    b[k] = byte(h shl 4 or l)
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
  ReadSpan = proc (at: int64, buf: var seq[byte]): bool {.closure.}
  WriteSpan = proc (at: int64, buf: seq[byte]): bool {.closure.}

const MaxShownBytes = 32 ## Bytes of a conflicting span quoted in its diagnostic.

proc replayOn(path, journalPath: string, size: int64, undo: bool, readAt: ReadSpan,
    writeAt: WriteSpan, log: var DiagLog) =
  # Edits whose spans share a byte form one component, replayed as a chain of
  # states: the original bytes, then the bytes after each edit in journal
  # order. The file may hold any state of the chain (a crash between the
  # journal sync and the map write leaves an earlier one) and is moved to the
  # first state (undo) or the last (apply). A component already there is
  # skipped and one that holds no state of its chain is a conflict, so both
  # operations can be repeated. Spans that only abut share no byte: they are
  # independent, and an interrupted edit beside an earlier one is no conflict.
  #
  # One pass over the edits sorted by offset, with buffers of the largest
  # component: a table entry per journaled byte took 26 KiB and 100 us per
  # trace of a geometry write-back (200 000 traces: 5.3 GiB, 21 s).
  var edits: seq[JournalEdit]
  if not log.tryRecord(Location(file: journalPath), (edits = readJournal(journalPath, log))):
    return
  var order = newSeqOfCap[int](edits.len)
  var pastEnd = 0
  for i, e in edits:
    if e.offset + e.old.len > size:
      capped(log, pastEnd, sevError, dcInconsistent, "journal line " & $e.line &
        " lies past the end of the file; skipped", e.offset, Location(file: path, field: e.label))
    else:
      order.add i
  summarize(log, pastEnd, "journal lines past the end of the file", Location(file: path))
  order.sort(proc (a, b: int): int =
    result = cmp(edits[a].offset, edits[b].offset)
    if result == 0: result = cmp(a, b))
  var conflicts = 0
  var cur, first, last: seq[byte]
  var seen: seq[bool]
  var members: seq[int]
  var i = 0
  while i < order.len:
    let lo = edits[order[i]].offset
    var hi = lo + edits[order[i]].old.len
    var j = i + 1
    while j < order.len and edits[order[j]].offset < hi:
      hi = max(hi, edits[order[j]].offset + edits[order[j]].old.len)
      inc j
    members.setLen 0
    for k in i ..< j: members.add order[k]
    if members.len > 1: members.sort() # journal order
    let n = int(hi - lo)
    cur.setLen n
    if not readAt(lo, cur):
      log.report(sevFatal, dcIo, "short read", lo, Location(file: path))
      return
    # The first state: each byte as the first edit touching it found it.
    first.setLen n
    seen.setLen 0
    seen.setLen n
    for m in members:
      let at = int(edits[m].offset - lo)
      for k, b in edits[m].old:
        if not seen[at + k]:
          first[at + k] = b
          seen[at + k] = true
    # Walk the chain, counting the bytes where the file differs from the
    # state: 0 at any state puts the file on the chain.
    last = first
    var differing = 0
    for k in 0 ..< n:
      if cur[k] != first[k]: inc differing
    let atFirst = differing == 0
    var onChain = atFirst
    for m in members:
      let at = int(edits[m].offset - lo)
      for k, b in edits[m].new:
        differing += ord(cur[at + k] != b) - ord(cur[at + k] != last[at + k])
        last[at + k] = b
      if differing == 0: onChain = true
    let atTarget = if undo: atFirst else: differing == 0
    if atTarget:
      discard "already done"
    elif onChain:
      if not (if undo: writeAt(lo, first) else: writeAt(lo, last)):
        log.report(sevFatal, dcIo, "write failed", lo, Location(file: path))
        return
    else:
      let shown = if n <= MaxShownBytes: hexOf(cur)
                  else: hexOf(cur.toOpenArray(0, MaxShownBytes - 1)) & "... (" & $n & " bytes)"
      capped(log, conflicts, sevError, dcInconsistent, "the file holds " & shown &
        ", neither the original nor the edited bytes; left alone", lo,
        Location(file: path, field: edits[members[^1]].label))
    i = j
  summarize(log, conflicts, "conflicts", Location(file: path))

proc replay(path, journalPath: string, undo: bool): DiagLog =
  # `replayOn` the file at `path`, read and written through a `File`.
  var f: File
  if not open(f, path, fmReadWriteExisting):
    result.report(sevFatal, dcIo, "cannot open for writing", loc = Location(file: path))
    return
  defer: f.close()
  let readAt = proc (at: int64, buf: var seq[byte]): bool =
    f.setFilePos(at)
    f.readBytes(buf, 0, buf.len) == buf.len
  let writeAt = proc (at: int64, buf: seq[byte]): bool =
    f.setFilePos(at)
    f.writeBytes(buf, 0, buf.len) == buf.len
  replayOn(path, journalPath, f.getFileSize, undo, readAt, writeAt, result)

proc rollbackJournal*(path, journalPath: string): DiagLog =
  ## Undoes the journal's edits on `path`, newest first. Locations already
  ## holding their original bytes are skipped (so a rollback can be
  ## repeated), also when the session was interrupted before its last edits
  ## reached the file; conflicts (bytes that are neither the original nor
  ## what one of the journal's edits left there) are logged and left alone.
  replay(path, journalPath, undo = true)

proc applyJournal*(path, journalPath: string): DiagLog =
  ## Replays the journal's edits on `path`, oldest first: redo after a
  ## rollback, the same edits on a copy of the file, or the rest of an
  ## interrupted session. Locations already holding the edited bytes are
  ## skipped; conflicts are logged and left alone.
  replay(path, journalPath, undo = false)

# ------------------------------------------------------------------ edits --

proc journalFor(path, journalPath: string): string =
  # The journal path (default `path & ".edits.nif"`); `ValueError` if it is the file.
  result = if journalPath.len > 0: journalPath else: path & ".edits.nif"
  if result == path or (fileExists(result) and fileExists(path) and sameFile(result, path)):
    raise newException(ValueError, "the journal " & result & " is the file being edited")

proc openEditor*(path: string, journalPath = ""): HeaderEditor =
  ## Maps `path` read-write, builds its trace index and opens the journal
  ## (default `path & ".edits.nif"`) for appending. Raises `IOError`/`OSError`
  ## if either cannot be opened, and `ValueError` if the journal is the file
  ## itself or the file holds multiplexed SEG-D (convert it to a
  ## demultiplexed file first; see `openSeismic`). Problems reading the file
  ## are in `file.index.log`; a file whose index has a fatal problem can
  ## still be edited where its headers were located.
  let jp = journalFor(path, journalPath)
  result = HeaderEditor(file: openSeismicRw(path), journalPath: jp)
  result.openJournal()

proc openEditor*(f: sink SeismicFile, journalPath = ""): HeaderEditor =
  ## Takes over the open file `f` (from `openSeismic`) for editing: maps
  ## `f.path` read-write in place of its read-only map and keeps its index
  ## (entries, codecs, and keys, joined ones included), so the file is not
  ## walked again; then as `openEditor(path, journalPath)`. A prefetcher still
  ## running on `f` keeps reading the old map, and sees the edits. Raises
  ## `ValueError` for a closed file, a demultiplexed copy of multiplexed
  ## SEG-D, a file whose size changed since it was opened, or a journal that
  ## is the file itself; `IOError`/`OSError` if the file or the journal
  ## cannot be opened. On a raise, `f` is closed with it.
  var file = f
  let jp = journalFor(file.path, journalPath)
  file.remapWritable()
  result = HeaderEditor(file: file, journalPath: jp)
  result.openJournal()

proc close*(ed: var HeaderEditor) =
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

proc release*(ed: sink HeaderEditor): SeismicFile =
  ## Ends the editing session and hands back the file, still mapped, with its
  ## index (cached headers as edited): `close` without unmapping, for a
  ## viewer that goes on reading. Ends a batch, flushes the map and closes
  ## the journal. Raises `IOError` as `close` does; the file is closed then.
  var e = ed
  var synced = true
  try:
    if e.batch: synced = e.endBatch()
    e.file.flush()
  finally:
    if e.journal.f != nil:
      e.journal.f.close()
      e.journal.f = nil
  if not synced:
    raise newException(IOError, "the journal " & e.journalPath &
      " cannot be synced; the batch's pending edits were not written")
  result = ensureMove e.file

func file*(ed: HeaderEditor): lent SeismicFile {.inline.} =
  ## The mapped file and its index (cached headers refreshed by the edits).
  ## Read-only: change the file through the editor's setters.
  ed.file

func log*(ed: HeaderEditor): lent DiagLog {.inline.} =
  ## Refused edits and journal problems.
  ed.log

proc logVar*(ed: var HeaderEditor): var DiagLog {.inline.} =
  ## **Internal** (`writeGeometry`). The editor's log, to report into. Not
  ## exported by `parseSEG`.
  ed.log

func journalPath*(ed: HeaderEditor): lent string {.inline.} =
  ## Where the edits are journaled.
  ed.journalPath

func edits*(ed: HeaderEditor): int {.inline.} =
  ## Edits written in this session (no-op edits excluded).
  ed.edits

proc commitSpan(ed: var HeaderEditor, at: int64, cur, buf: openArray[byte],
    label: string): string =
  # Journals and writes the bytes of `buf` (meant for `at ..< at + buf.len`,
  # inside the map) that differ from `cur`, the bytes there as edited so far
  # (`currentBytes`), as one span from the first to the last changed byte.
  # "" when done (also when nothing differs), else why nothing changed.
  let mem = ed.file.unsafeMemory
  let a = int(at)
  let size = buf.len
  var first = 0
  while first < size and buf[first] == cur[first]: inc first
  if first == size: return "" # no change
  var last = size - 1
  while buf[last] == cur[last]: dec last
  try:
    ed.journalEdit(at + first, cur.toOpenArray(first, last),
      buf.toOpenArray(first, last), label)
  except IOError as e:
    return "the journal cannot be written (" & e.msg & "); nothing changed"
  inc ed.edits
  if ed.batch:
    ed.addPending(at + first, buf.toOpenArray(first, last))
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
  if not ed.file.index.detected: refuse "the file is not SEG-Y, SEG-D or SEG-2"
  if ed.journalDead: refuse "the journal could not be cut back after a failed write; no edits"
  if at < 0 or at + size > ed.file.mappedSize: refuse "the header lies outside the file"
  if b.kind in {hbSeg2File, hbSeg2Trace}:
    refuse "SEG-2 headers cannot be edited in place: keyword strings are variable length, " &
      "so a changed value changes the block's size and moves every byte after it (and the " &
      "fixed fields are those sizes and counts); rewrite the file instead (seg2/writer, or " &
      "convertFile with target SEG-2)"
  if field in structural(b.kind):
    refuse "changes the file's structure (sizes or counts); rewrite the file instead"
  # The block as edited so far (a batch's pending writes included), so
  # several fields of one header in a batch need no flush.
  let cur = ed.currentBytes(at, size)
  var h: T
  decodeFields(h, cur, firstByte, b.order)
  var err = ""
  if not setByName(h, field, v, err): refuse err
  var buf = cur
  try:
    encodeChanged(h, buf, firstByte, b.order)
  except SegFormatError as e:
    refuse e.msg
  let label = (if loc.trace >= 0: "trace " & $loc.trace & " "
               elif loc.record >= 0: "record " & $loc.record & " " else: "") &
    b.name & "." & field
  let failure = ed.commitSpan(at, cur, buf, label)
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
  ## through a SEG-Y Layout stanza (`survey/writeback`). Only the stored keys
  ## of `loc.trace` are refreshed (the span is one trace's headers). The caller encodes
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
  let failure = ed.commitSpan(at, ed.currentBytes(at, bytes.len), bytes, label)
  if failure.len > 0: refuse failure
  ed.keysChanged(loc.trace)
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
  # The block as edited so far: a batch's pending writes laid over the map.
  let inRange = r.blk.offset >= 0 and r.blk.offset + r.blk.size <= ed.file.mappedSize
  let v = if ed.batch and inRange and ed.overlapsPending(r.blk.offset, r.blk.size):
      ed.file.readField(r.blk, r.field, ed.currentBytes(r.blk.offset, r.blk.size))
    else: ed.file.readField(r.blk, r.field)
  if v.error.len > 0: raise newException(ValueError, name & ": " & v.error)
  v.value

proc currentTraceField*(ed: var HeaderEditor, trace: int, name: string): FieldValue =
  ## Reads `trace.<field>` / `ext1.<field>` of trace `trace` as edited so far
  ## (a batch's pending edits included, without syncing them). Raises
  ## `ValueError` like `traceField`.
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

proc setTraceField*(ed: var HeaderEditor, trace: int, name: string, value: FieldValue): bool =
  ## Sets field `name` (`trace.<field>` or `ext1.<field>`) of trace `trace`.
  ## False, with a diagnostic in `log`, if the edit is refused.
  var loc = Location(file: ed.file.path, trace: trace)
  if trace in 0 ..< ed.file.len: loc.record = int(ed.file.index.entries[trace].record)
  var b: BlockRef
  result = ed.setLocated(hsTrace, trace, name, value, loc, b)
  if result:
    ed.keysChanged(trace)
    if name in ["trace.sampleInterval", "ext1.extSampleInterval"]:
      if ed.batch: ed.intervalStale = true # once the batch is on the map
      else: ed.file.refreshSegyInterval()

const keyedBinaryFields = ["binary.sampleInterval", "binary.extSampleInterval",
  "binary.timeBasisCode"] ## Binary header fields the keys depend on.

proc refreshAllKeys(ed: var HeaderEditor) =
  if not ed.file.hasKeys: return
  var all = newSeq[int](ed.file.len)
  for i in 0 ..< all.len: all[i] = i
  discard ed.file.refreshKeys(all)

proc setFileField*(ed: var HeaderEditor, name: string, value: FieldValue): bool =
  ## Sets a SEG-Y binary header field (`binary.<field>`); the index's copy of
  ## the binary header is refreshed. False, with a diagnostic in `log`, if
  ## the edit is refused.
  var b: BlockRef
  result = ed.setLocated(hsFile, 0, name, value, Location(file: ed.file.path), b) and
    ed.flushBatch() # the index copy is refreshed from the map
  if result:
    ed.file.index.segy.binary = decodeBinaryHeader(ed.file.unsafeMemory.toOpenArray(int(b.offset),
      int(b.offset) + b.size - 1), b.order)
    if name in keyedBinaryFields:
      ed.refreshAllKeys()
      ed.file.refreshSegyInterval()

proc setRecordField*(ed: var HeaderEditor, record: int, name: string,
    value: FieldValue): bool =
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
    if ed.file.hasKeys:
      var traces: seq[int]
      for i, e in ed.file.index.entries:
        if int(e.record) == record: traces.add i
      discard ed.file.refreshKeys(traces)

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

# ------------------------------------------------ journal on an open editor --

proc reloadHeaders(ed: var HeaderEditor) =
  # The index's copies of the headers a journal can touch (the SEG-Y binary
  # header, SEG-D GH#1 and Rev 1/2 source headers) and the stored keys,
  # re-read from the map after a replay.
  template ix: untyped = ed.file.index
  let mem = ed.file.unsafeMemory
  let size = ed.file.mappedSize
  case ix.kind
  of skSegy:
    let b = ix.locateBlock(hsFile, 0, "binary").blk
    if b.offset >= 0 and b.offset + b.size <= size:
      ix.segy.binary = decodeBinaryHeader(mem.toOpenArray(int(b.offset),
        int(b.offset) + b.size - 1), b.order)
  of skSegd:
    for rec in ix.segdRecords.mitems:
      let a = int(rec.offset)
      if a < 0 or a + SegdBlockSize > size: continue
      rec.gh1 = decodeBlock[SegdGeneralHeader1](mem.toOpenArray(a, a + SegdBlockSize - 1))
      if not rec.isRev3 and rec.gh2.isSome:
        for n in 0 ..< rec.sourceHeaders.len:
          let at = a + SegdBlockSize * (n + 2) # block gh<n + 3>
          if at + SegdBlockSize <= size:
            rec.sourceHeaders[n] = decodeBlock[SegdGeneralHeaderN](mem.toOpenArray(at,
              at + SegdBlockSize - 1))
  else: discard
  ed.refreshAllKeys()
  ed.file.refreshSegyInterval()

proc replayHere(ed: var HeaderEditor, undo: bool): DiagLog =
  # `replay` on the editor's own map, then the cached headers and keys.
  let loc = Location(file: ed.file.path)
  if not ed.file.isOpen:
    result.report(sevFatal, dcValidation, "the file is closed", loc = loc)
    return
  if not ed.flushBatch():
    result.report(sevFatal, dcIo, "the batch's journal entries cannot be synced; nothing " &
      "was replayed", loc = loc)
    return
  let mem = ed.file.unsafeMemory
  let readAt = proc (at: int64, buf: var seq[byte]): bool =
    if buf.len > 0: copyMem(addr buf[0], addr mem[at], buf.len)
    true
  let writeAt = proc (at: int64, buf: seq[byte]): bool =
    if buf.len > 0: copyMem(addr mem[at], addr buf[0], buf.len)
    true
  replayOn(ed.file.path, ed.journalPath, ed.file.mappedSize, undo, readAt, writeAt, result)
  ed.reloadHeaders()

proc rollbackJournal*(ed: var HeaderEditor): DiagLog =
  ## Undoes the editor's journal on its open file, as
  ## `rollbackJournal(path, journalPath)` does on disk, then re-reads the
  ## index's copies of the edited headers and refreshes the stored keys
  ## (bumping `keysRevision` when they change), so a viewer holding the
  ## editor sees the file as it was. A batch is written first; when its
  ## journal entries cannot be synced, nothing is undone (a fatal
  ## diagnostic). The journal keeps its entries: `applyJournal(ed)` redoes
  ## them. The undo itself is not journaled.
  ed.replayHere(undo = true)

proc applyJournal*(ed: var HeaderEditor): DiagLog =
  ## Replays the editor's journal on its open file (redo after
  ## `rollbackJournal(ed)`), refreshing headers and keys as that does.
  ed.replayHere(undo = false)
