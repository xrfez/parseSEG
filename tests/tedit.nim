## In-place header edits with an undo journal (task 6.6).

import std/[assertions, os, strutils]
import parseSEG/common/[diagnostics, endians]
import parseSEG/io/diskio
import parseSEG/segy/[reader as segyreader, writer as segywriter]
import parseSEG/segd/[reader as segdreader]
import parseSEG/model/[traceindex, headerfields, edit, prefetch]
import ./utils/testutils

let tmp = scratchDir("parseseg_tedit")

proc fresh(name: string): (string, string) =
  ## A copy of a sample file and a path for its journal (removed first).
  let path = tmp / name
  copyFile(exampleDir / name, path)
  let j = path & ".edits.nif"
  if fileExists(j): removeFile(j)
  (path, j)

proc diffCount(a, b: seq[byte]): int =
  doAssert a.len == b.len
  for i in 0..<a.len:
    if a[i] != b[i]: inc result

proc editLines(journal: string): int =
  for l in lines(journal):
    if l.startsWith("(edit "): inc result

proc segyWithExt1(path: string) =
  ## A Rev 2.1 SEG-Y file whose traces carry Trace Header Extension 1.
  var d = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var f = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boBig,
    format: d.file.format, extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  f.binary.numExtTextHeaders = 0
  f.binary.maxAddlTraceHeaders = 1
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, f, initSegyWriteOptions(f, lenient = true))
  for k in 0..<4:
    var t = d.traces[k]
    t.hasExt1 = true
    t.ext1 = initTraceHeaderExt1()
    t.ext1.numAddlTraceHeaders = 1
    w.writeTrace(t)
  w.close()
  sink.close()

sampleBlock segy_trace_and_binary_edits_and_rollback:
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let original = readBytes(path)
  var ed = openEditor(path)
  doAssert ed.journalPath == journal
  doAssert ed.setTraceField(5, "trace.sourceX", 1_700_000)
  doAssert ed.setTraceField(5, "trace.sourceX", 1_700_000) # a no-op writes nothing
  doAssert ed.setTraceField(7, "trace.groupStatic", -12)
  doAssert ed.setFileField("binary.jobId", 4242)
  doAssert ed.setTraceField(0, "trace.headerName", "ABC") # text, space padded
  doAssert ed.edits == 4 and ed.log.len == 0
  doAssert ed.file.index.segy.binary.jobId == 4242 # cached copy refreshed
  ed.close()
  let edited = readBytes(path)
  doAssert diffCount(original, edited) <= 4 + 2 + 4 + 8
  doAssert editLines(journal) == 4
  let d = readSegy(path)
  doAssert d.log.len == 0
  doAssert d.traces[5].header.sourceX == 1_700_000 and d.traces[7].header.groupStatic == -12
  doAssert d.file.binary.jobId == 4242 and d.traces[0].header.headerNameText == "ABC     "
  # Undo, twice (the second finds nothing to do), then redo.
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == original
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == original
  doAssert applyJournal(path, journal).len == 0
  doAssert readBytes(path) == edited

sampleBlock refused_edits_change_nothing:
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let original = readBytes(path)
  var ed = openEditor(path)
  let refused = [
    ed.setTraceField(0, "trace.numSamples", 10),           # structural
    ed.setFileField("binary.formatCode", 5),              # structural
    ed.setFileField("binary.maxAddlTraceHeaders", 1),     # structural, revision dependent
    ed.setTraceField(0, "trace.traceIdCode", 40000),       # int16 overflow
    ed.setTraceField(0, "trace.sourceX", 1.5),             # not an integer
    ed.setTraceField(0, "trace.sourceX", "east"),          # text for a number
    ed.setTraceField(0, "trace.headerName", "TOO LONG!"),  # 9 characters for 8
    ed.setTraceField(0, "trace.noSuchField", 1),
    ed.setTraceField(0, "sourceX", 1),                     # no block
    ed.setTraceField(0, "ext1.extSourceX", 1.0),           # the trace has no Ext1
    ed.setTraceField(200, "trace.sourceX", 1),             # no such trace
    ed.setFileField("binary.unassigned1", "x"),           # raw bytes
    ed.setRecordField(0, "gh1.year", 1)]              # SEG-Y has no records
  for r in refused: doAssert not r
  doAssert ed.log.count(sevError) == refused.len and ed.edits == 0
  ed.close()
  doAssert readBytes(path) == original and editLines(journal) == 0

sampleBlock segy_little_endian_and_ext1:
  let (path, journal) = fresh("Sweep0.sgy")
  var ed = openEditor(path)
  doAssert ed.setTraceField(0, "trace.sourceX", -123456)
  ed.close()
  doAssert readSegy(path).traces[0].header.sourceX == -123456
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == readBytes(exampleDir / "Sweep0.sgy")
  let p2 = tmp / "ext1.sgy"
  segyWithExt1(p2)
  if fileExists(p2 & ".edits.nif"): removeFile(p2 & ".edits.nif")
  var e2 = openEditor(p2)
  doAssert e2.file.len == 4
  doAssert e2.setTraceField(2, "ext1.extSourceX", 512300.25)
  doAssert e2.setTraceField(2, "ext1.extTraceSeqLine", 18_000_000_000'i64) # beyond 32 bits
  doAssert not e2.setTraceField(2, "ext1.numAddlTraceHeaders", 2)
  doAssert not e2.setTraceField(2, "ext1.extTraceSeqLine", -1)
  e2.close()
  let d = readSegy(p2)
  doAssert d.traces[2].ext1.extSourceX == 512300.25
  doAssert d.traces[2].ext1.extTraceSeqLine == 18_000_000_000'u64

sampleBlock segd_rev2_edits:
  let (path, journal) = fresh("63.sgd")
  let original = readBytes(path)
  var ed = openEditor(path)
  doAssert ed.setTraceField(0, "ext1.receiverPointNumber", 2050)     # 24-bit
  doAssert not ed.setTraceField(0, "ext1.receiverPointNumber", 9_000_000)
  doAssert ed.setTraceField(0, "trace.traceNumber", 77)              # 4 BCD digits
  doAssert not ed.setTraceField(0, "trace.traceNumber", 12345)
  doAssert not ed.setTraceField(0, "trace.traceHeaderExtensions", 1) # structural
  doAssert ed.setRecordField(0, "gh1.year", 27)                 # 2 BCD digits
  doAssert not ed.setRecordField(0, "gh1.year", 100)
  doAssert not ed.setRecordField(0, "gh1.formatCode", 8048)     # structural
  doAssert ed.setRecordField(0, "gh3.sourcePointNumber", 101.25) # i24.u16 fixed point
  doAssert not ed.setRecordField(0, "gh4.sourcePointNumber", 1.0) # no second source block
  doAssert not ed.setRecordField(1, "gh1.year", 1)
  doAssert ed.edits == 4 and ed.log.count(sevError) == 7
  doAssert ed.file.index.segdRecords[0].gh1.year == 27
  doAssert ed.file.index.segdRecords[0].sourceHeaders[0].sourcePointNumber == 101.25
  ed.close()
  let d = readSegd(path)
  doAssert d.log.len == readSegd(exampleDir / "63.sgd").log.len
  let t = d.records[0].traces[0]
  doAssert t.ext1.get.receiverPointNumber == 2050 and t.header.traceNumber == 77
  doAssert d.records[0].record.gh1.year == 27
  doAssert d.records[0].record.sourceHeaders[0].sourcePointNumber == 101.25
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == original

sampleBlock segd_rev3_edits:
  let (path, journal) = fresh("inova_rev30_5traces.sgd")
  var ed = openEditor(path)
  doAssert ed.setTraceField(4, "ext1.receiverLineNumber", 1234)   # Rev 3 layout
  doAssert ed.setTraceField(4, "ext1.sensorMoving", 1)            # a Rev 3-only field
  doAssert not ed.setTraceField(4, "ext1.numSamples", 10)         # structural
  doAssert not ed.setRecordField(0, "gh3.timeZero", 0)       # Rev 3 blocks are not editable
  ed.close()
  let d = readSegd(path)
  doAssert d.log.len == 0
  doAssert d.records[0].traces[4].ext1Rev3.get.receiverLineNumber == 1234
  doAssert d.records[0].traces[4].ext1Rev3.get.sensorMoving == 1
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == readBytes(exampleDir / "inova_rev30_5traces.sgd")

sampleBlock journal_conflicts_crashes_and_damage:
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let original = readBytes(path)
  var ed = openEditor(path)
  doAssert ed.setTraceField(1, "trace.sourceX", 11)
  doAssert ed.setTraceField(2, "trace.sourceX", 22)
  let at1 = int(ed.file.index.entries[1].offset + 72)
  let at2 = ed.file.index.entries[2].offset + 72
  ed.close()
  # Someone else changes trace 2's bytes: that edit is a conflict and stays.
  block:
    var f = open(path, fmReadWriteExisting)
    f.setFilePos(at2 + 3)
    f.write('\x63')
    f.close()
  # A crash left a cut-short line, and garbage follows.
  block:
    var f = open(journal, fmAppend)
    f.write("(edit 3816 \"00\" \"0")
    f.write("\n(edit nonsense)\n")
    f.close()
  let conflicted = readBytes(path)
  let log = rollbackJournal(path, journal)
  doAssert log.count(sevError) == 3, $log.len # two malformed lines, one conflict
  # Trace 1 restored; everything else, trace 2 included, as it was.
  var want = conflicted
  for k in 0..3: want[at1 + k] = original[at1 + k]
  doAssert readBytes(path) == want
  # An entry journaled before a crash, never written: rollback skips it.
  let (p2, j2) = fresh("Sweep0.sgy")
  writeFile(j2, "(edit 3600 \"aaaa\" \"bbbb\" \"x\")\n")
  let before = readBytes(p2)
  var b = before
  b[3600] = 0xAA
  b[3601] = 0xAA
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(p2, s)
  doAssert rollbackJournal(p2, j2).len == 0 and readBytes(p2) == b
  doAssert applyJournal(p2, j2).len == 0 and readBytes(p2)[3600] == 0xBB
  # A missing journal is a fatal diagnostic, not an exception.
  doAssert rollbackJournal(p2, tmp / "nope.nif").isFatal

sampleBlock edit_through_the_mapped_index:
  # Values written through the editor are what range reads see next.
  let (path, _) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  var ed = openEditor(path)
  doAssert ed.setTraceField(3, "trace.sourceY", 99)
  let t = ed.file.readTraces(3..3)
  doAssert t.shape == [1, 2001]
  ed.close()

sampleBlock journal_is_the_file:
  let (path, _) = fresh("Sweep0.sgy")
  doAssertRaises(ValueError): discard openEditor(path, path)

sampleBlock current_fields_raise_like_the_reads:
  let (path, _) = fresh("Sweep0.sgy")
  var ed = openEditor(path)
  ed.beginBatch()
  doAssert ed.setTraceField(0, "trace.groupX", 77)
  doAssert ed.currentTraceField(0, "trace.groupX").intVal == 77 # the batched edit
  doAssertRaises(ValueError): discard ed.currentTraceField(0, "trace.nope")
  doAssertRaises(ValueError): discard ed.currentRecordField(0, "gh1.year")
  doAssert ed.endBatch()
  ed.close()

when defined(linux):
  import std/posix

  proc failJournal(journal: string) =
    ## Points the open journal's descriptor at /dev/full: every write to it
    ## from now on fails with ENOSPC, as on a full disk.
    let want = expandFilename(journal)
    for kind, p in walkDir("/proc/self/fd"):
      var target = ""
      try: target = expandSymlink(p)
      except OSError: discard
      if target == want:
        let full = posix.open("/dev/full", O_WRONLY)
        doAssert full >= 0 and dup2(full, cint(parseInt(p.extractFilename))) >= 0
        discard posix.close(full)
        return
    doAssert false, "the journal is not open"

  sampleBlock journal_sync_failure_refuses_the_edit:
    # The map is written only after its journal entry is on disk: when the
    # journal cannot be written or synced, the edit is refused (false and an
    # error in `log`), never raised, and the file keeps its bytes. /dev/full
    # cannot be truncated either, so the refused entries cannot be cut from
    # the journal: the editor then refuses every further edit.
    let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
    let original = readBytes(path)
    var ed = openEditor(path)
    let before = ed.file.traceField(3, "trace.groupX")
    failJournal(journal)
    ed.beginBatch()
    doAssert ed.setTraceField(3, "trace.groupX", 4242) # journaled in memory only
    doAssert not ed.endBatch()                          # the sync fails: nothing written
    doAssert ed.file.traceField(3, "trace.groupX") == before and ed.edits == 0
    doAssert ed.log.count(sevError) == 2 and "cut back" in ed.log[0].msg and
      "cannot be synced" in ed.log[1].msg
    doAssert not ed.setTraceField(3, "trace.groupX", 4343) # refused at once
    doAssert ed.file.traceField(3, "trace.groupX") == before and ed.edits == 0
    doAssert ed.log.count(sevError) == 3 and "cut back" in ed.log[2].msg
    doAssert not ed.setFileField("binary.jobId", 5)
    ed.close()
    doAssert readBytes(path) == original and editLines(journal) == 0

  var RLIMIT_FSIZE {.importc, header: "<sys/resource.h>".}: cint

  proc limitFileSize(bytes: int) =
    ## Writes past `bytes` into any file fail with EFBIG (SIGXFSZ ignored);
    ## a negative `bytes` lifts the limit.
    var lim: RLimit
    doAssert getrlimit(RLIMIT_FSIZE, lim) == 0
    lim.rlim_cur = if bytes < 0: lim.rlim_max else: bytes
    doAssert setrlimit(RLIMIT_FSIZE, lim) == 0

  sampleBlock failed_entries_are_cut_from_the_journal:
    # A batch whose journal write fails part-way (the disk fills up) leaves
    # no entry behind: `applyJournal` must not redo refused edits.
    let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
    let original = readBytes(path)
    var ed = openEditor(path)
    let session = getFileSize(journal)
    signal(SIGXFSZ, SIG_IGN)
    limitFileSize(int(session) + 20) # room for part of an entry
    try:
      ed.beginBatch()
      for t in 0..9: doAssert ed.setTraceField(t, "trace.groupX", 5000 + t)
      doAssert not ed.endBatch() and ed.edits == 0
      doAssert getFileSize(journal) == session # the partial write was cut off
      doAssert not ed.setTraceField(0, "trace.groupY", 123456789) # the journal still fails
      doAssert getFileSize(journal) == session
    finally:
      limitFileSize(-1)
    doAssert ed.setTraceField(0, "trace.groupY", 7) and ed.edits == 1 # the journal works again
    ed.beginBatch()
    doAssert ed.setTraceField(1, "trace.groupY", 8)
    ed.close()
    doAssert editLines(journal) == 2
    doAssert diffCount(readBytes(path), original) > 0
    doAssert rollbackJournal(path, journal).len == 0 and readBytes(path) == original

  sampleBlock close_raises_when_the_last_batch_is_lost:
    let (path, journal) = fresh("Sweep0.sgy")
    let original = readBytes(path)
    var ed = openEditor(path)
    ed.beginBatch()
    doAssert ed.setTraceField(0, "trace.groupX", 77)
    failJournal(journal)
    doAssertRaises(IOError): ed.close()
    doAssert readBytes(path) == original and editLines(journal) == 0

  sampleBlock current_field_needs_no_sync:
    # Since 13.2 a batch's pending edits are read without a sync, so a
    # journal that fails shows only when the batch ends.
    let (path, journal) = fresh("Sweep0.sgy")
    let original = readBytes(path)
    var ed = openEditor(path)
    ed.beginBatch()
    doAssert ed.setTraceField(0, "trace.groupX", 77)
    failJournal(journal)
    doAssert ed.currentTraceField(0, "trace.groupX").intVal == 77
    doAssertRaises(IOError): ed.close()
    doAssert ed.edits == 0 and readBytes(path) == original

sampleBlock batch_edits_several_fields_of_one_header_without_a_flush:
  # Task 13.2 (review R2-2): a second field of a header with a pending edit
  # used to flush the batch (one fsync per trace). The edit now decodes the
  # header with the pending bytes laid over it, so nothing reaches the map
  # before `endBatch`, and the journal still holds every step.
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let orig = readBytes(path)
  var ed = openEditor(path, journal)
  let n = ed.file.len
  let x0 = ed.file.traceField(0, "trace.sourceX").intVal
  ed.beginBatch()
  for i in 0..<n:
    doAssert ed.setTraceField(i, "trace.sourceX", 1000 + i)
    doAssert ed.setTraceField(i, "trace.sourceY", 2000 + i)
    doAssert ed.setTraceField(i, "trace.sourceX", 3000 + i) # the same field again
    doAssert ed.currentTraceField(i, "trace.sourceX").intVal == 3000 + i
  # Not flushed: the map still holds the original values.
  doAssert ed.file.traceField(0, "trace.sourceX").intVal == x0
  doAssert ed.file.traceField(n - 1, "trace.sourceY").intVal != 2000 + n - 1 or n == 0
  doAssert ed.endBatch()
  for i in 0..<n:
    doAssert ed.file.traceField(i, "trace.sourceX").intVal == 3000 + i
    doAssert ed.file.traceField(i, "trace.sourceY").intVal == 2000 + i
  ed.close()
  doAssert editLines(journal) == 3 * n
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == orig

sampleBlock editor_from_an_open_file:
  # 14.3c: the editor takes over the open file and its index (no second
  # open or walk); journal, rollback and refusals as `openEditor(path)`.
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let orig = readBytes(path)
  var f = openSeismic(path, keys = true)
  let n = f.len
  let entries = f.index.entries
  var ed = openEditor(move f)
  doAssert not f.isOpen # moved into the editor
  doAssert ed.journalPath == journal and fileExists(journal)
  doAssert ed.file.isOpen and ed.file.len == n and ed.file.hasKeys
  doAssert ed.file.index.entries == entries
  doAssert ed.setTraceField(5, "trace.sourceX", 1_700_000)
  doAssert ed.setFileField("binary.jobId", 4242)
  doAssert ed.file.traceField(5, "trace.sourceX").intVal == 1_700_000
  doAssert ed.file.index.segy.binary.jobId == 4242 # cached header refreshed
  ed.close()
  doAssert not ed.file.isOpen and editLines(journal) == 2
  var g = openSeismic(path)
  doAssert g.traceField(5, "trace.sourceX").intVal == 1_700_000
  g.close()
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == orig

sampleBlock editor_from_an_open_file_released:
  # `release` hands the file back, still mapped and as edited.
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let orig = readBytes(path)
  var ed = openEditor(openSeismic(path), journal)
  ed.beginBatch()
  doAssert ed.setTraceField(3, "trace.groupStatic", -12)
  var f = release(move ed)
  doAssert f.isOpen and f.traceField(3, "trace.groupStatic").intVal == -12
  doAssert editLines(journal) == 1
  # Edit again from the released file: a fresh session in the same journal.
  var ed2 = openEditor(move f, journal)
  doAssert ed2.setTraceField(4, "trace.groupStatic", -13)
  ed2.close()
  doAssert editLines(journal) == 2
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == orig

sampleBlock editor_from_an_open_file_refusals:
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let orig = readBytes(path)
  var closed = openSeismic(path)
  closed.close()
  doAssertRaises(ValueError): discard openEditor(move closed)
  doAssertRaises(ValueError): discard openEditor(openSeismic(path), path) # journal is the file
  # A file that changed size since it was opened: its index would be stale.
  var f = openSeismic(path)
  block:
    let h = open(path, fmAppend)
    h.write("x")
    h.close()
  doAssertRaises(ValueError): discard openEditor(move f)
  doAssert not fileExists(journal), "nothing opened on a refusal"
  doAssert readBytes(path)[0 ..< orig.len] == orig

sampleBlock editor_from_a_file_with_a_running_prefetcher:
  # The prefetcher pins the old read-only map and the index tables it reads;
  # the editor maps anew and works on copies, so closing the editor first
  # leaves the prefetcher reading valid memory.
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let orig = readBytes(path)
  var f = openSeismic(path)
  let all = f.readTraces(0 ..< f.len)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 7, depth = 2)
  proc editAndDrop(f: sink SeismicFile, journal: string) =
    # The editor, its file and that file's index tables go at the return.
    var ed = openEditor(f, journal)
    doAssert ed.setTraceField(0, "trace.sourceX", 1_700_000) # headers only: samples unchanged
    ed.close()
  doAssert f.len > 3 * 7, "the worker still decodes after the editor is gone"
  editAndDrop(move f, journal)
  var c: PrefetchChunk[float32]
  var expect = 0
  while p.next(c):
    doAssert c.first == expect and c.failed == 0
    doAssert c.samples == all[c.first ..< c.first + c.count, _]
    expect += c.count
  doAssert expect == all.shape[0]
  p.close()
  doAssert rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == orig

# Phase 6 review (prefetch and edit).

block p6_b1_edits_refused_on_files_that_are_not_seismic:
  writeFile(tmp / "junk.bin", repeat('\xEE', 8000))
  if fileExists(tmp / "junk.bin.edits.nif"): removeFile(tmp / "junk.bin.edits.nif")
  var ed = openEditor(tmp / "junk.bin")
  doAssert not ed.setFileField("binary.jobId", 5)
  doAssert not ed.setTraceField(0, "trace.sourceX", 5)
  ed.close()
  doAssert readFile(tmp / "junk.bin") == repeat('\xEE', 8000)

sampleBlock p6_b2_repeated_rollback_with_overlapping_spans:
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let original = readBytes(path)
  var ed = openEditor(path)
  doAssert ed.setTraceField(3, "trace.sourceX", 0x0100_0001) # 4 bytes change
  doAssert ed.setTraceField(3, "trace.sourceX", 1)           # then only 1 byte
  ed.close()
  let edited = readBytes(path)
  for _ in 1..2:
    doAssert rollbackJournal(path, journal).len == 0
    doAssert readBytes(path) == original
  for _ in 1..2:
    doAssert applyJournal(path, journal).len == 0
    doAssert readBytes(path) == edited

sampleBlock p6_b3_field_edited_twice_has_no_spurious_conflicts:
  let (path, journal) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  let original = readBytes(path)
  var ed = openEditor(path)
  doAssert ed.setTraceField(5, "trace.sourceX", 111)
  doAssert ed.setTraceField(5, "trace.sourceX", 222)
  ed.close()
  let edited = readBytes(path)
  doAssert rollbackJournal(path, journal).len == 0 and rollbackJournal(path, journal).len == 0
  doAssert readBytes(path) == original
  doAssert applyJournal(path, journal).len == 0 and applyJournal(path, journal).len == 0
  doAssert readBytes(path) == edited

sampleBlock p6_b4_hostile_journals_stay_bounded:
  let j = tmp / "hostile.nif"
  block:
    var f = open(j, fmWrite)
    for _ in 0..<8: f.write repeat('a', 1 shl 20) # 8 MB, no newline
    f.write "\n"
    for _ in 0..<1000: f.write "x\n"
    f.close()
  var log: DiagLog
  doAssert readJournal(j, log).len == 0
  doAssert log.count(sevError) == 5 and log.count(sevInfo) == 1 # 1001 malformed lines
  # A conflict-ridden journal is capped too.
  let (path, _) = fresh("Sweep0.sgy")
  var lines = ""
  for k in 0..<50: lines.add "(edit " & $(4000 + 4 * k) & " \"abab\" \"cdcd\" \"x\")\n"
  writeFile(j, lines)
  let r = rollbackJournal(path, j)
  doAssert r.count(sevError) == 5 and r.count(sevInfo) == 1

sampleBlock p6_b5_huge_general_header_numbers_are_refused:
  let (path, _) = fresh("63.sgd")
  var ed = openEditor(path)
  var raised = false
  try:
    doAssert not ed.setRecordField(0, "gh99999999999999999999.sourceSetNumber", 1)
    doAssert not ed.setRecordField(0, "gh0003x.sourceSetNumber", 1)
  except CatchableError:
    raised = true
  doAssert not raised
  ed.close()

# An edit interrupted between its journal sync and its map write.

proc writeAt(path: string, at: int64, bytes: openArray[byte]) =
  var f = open(path, fmReadWriteExisting)
  f.setFilePos(at)
  doAssert f.writeBytes(bytes, 0, bytes.len) == bytes.len
  f.close()

proc chainStates(path, journal: string, original: seq[byte]): seq[seq[byte]] =
  ## The file after 0, 1, ... of the journal's edits, from `original`.
  var log: DiagLog
  let edits = readJournal(journal, log)
  doAssert log.len == 0
  result.add original
  for e in edits:
    var s = result[^1]
    for k, b in e.new: s[int(e.offset) + k] = b
    result.add s

block interrupted_edit_over_or_beside_an_earlier_one:
  # A crash can leave the file at any state between two edits: the journal
  # must undo and redo from each, also when the spans overlap or abut.
  let src = sampleOr("BO_3D-Inglewood_rev21_v7.sgy")
  for scenario in ["twice", "adjacent", "overlapping"]:
    let path = tmp / ("chain_" & scenario & ".sgy")
    let journal = path & ".edits.nif"
    copyFile(src, path)
    if fileExists(journal): removeFile(journal)
    let original = readBytes(path)
    var ed = openEditor(path)
    let at = ed.file.index.entries[5].offset
    doAssert ed.setTraceField(5, "trace.sourceX", 0x11223344) # bytes 73-76
    case scenario
    of "twice": doAssert ed.setTraceField(5, "trace.sourceX", 0x55667788)
    of "adjacent": doAssert ed.setTraceField(5, "trace.sourceY", 0x55667788) # bytes 77-80
    else:
      # Three spans, each sharing bytes with the next only.
      doAssert ed.writeBytes(at + 74, [0xA1'u8, 0xA2, 0xA3, 0xA4], "bytes 75-78",
        Location(file: path, trace: 5))
      doAssert ed.setTraceField(5, "trace.sourceY", 0x55667788)
    ed.close()
    let states = chainStates(path, journal, original)
    doAssert states[^1] == readBytes(path)
    for k, state in states:
      for undo in [true, false]:
        writeAt(path, at, state.toOpenArray(int(at), int(at) + 239))
        let log = if undo: rollbackJournal(path, journal) else: applyJournal(path, journal)
        doAssert log.len == 0, scenario & " at state " & $k & ": " & $log
        doAssert readBytes(path) == (if undo: states[0] else: states[^1]),
          scenario & " at state " & $k
    # Bytes of no state of the chain are still a conflict, left alone.
    var odd = states[1]
    odd[int(at) + 73] = odd[int(at) + 73] xor 0xFF
    writeAt(path, at, odd.toOpenArray(int(at), int(at) + 239))
    let log = rollbackJournal(path, journal)
    doAssert log.count(sevError) == 1 and readBytes(path)[int(at) + 72 .. int(at) + 75] ==
      odd[int(at) + 72 .. int(at) + 75], scenario
    # The same on the editor's own map.
    var ed2 = openEditor(path, tmp / "chain_other.nif")
    let mem = ed2.file.unsafeMemory
    for undo in [true, false]:
      copyMem(addr mem[at], addr states[1][int(at)], 240)
      let log = if undo: rollbackJournal(path, journal) else: applyJournal(path, journal)
      doAssert log.len == 0, scenario & ": " & $log
      let want = if undo: states[0] else: states[^1]
      doAssert equalMem(addr mem[0], addr want[0], want.len), scenario
    ed2.close()

block current_fields_read_through_an_editor_that_is_not_var:
  let path = tmp / "peek.sgy"
  copyFile(sampleOr("BO_3D-Inglewood_rev21_v7.sgy"), path)
  if fileExists(path & ".edits.nif"): removeFile(path & ".edits.nif")
  proc peek(ed: HeaderEditor): (int64, int64) =
    # Compiles only when the readers take the editor by value.
    (ed.currentTraceField(3, "trace.groupStatic").intVal, ed.currentFileField("binary.jobId").intVal)
  var ed = openEditor(path)
  ed.beginBatch()
  doAssert ed.setTraceField(3, "trace.groupStatic", -7) and ed.setFileField("binary.jobId", 77)
  doAssert peek(ed) == (-7'i64, 77'i64)
  doAssert ed.endBatch()
  ed.close()

block refused_edits_do_not_grow_the_log_without_bound:
  # A script that keeps trying a refused edit (here a structural field of
  # every "trace") gets false each time; the log holds the first 1000
  # refusals and counts the rest.
  let path = tmp / "refused.sgy"
  copyFile(sampleOr("BO_3D-Inglewood_rev21_v7.sgy"), path)
  if fileExists(path & ".edits.nif"): removeFile(path & ".edits.nif")
  let original = readBytes(path)
  var ed = openEditor(path)
  for i in 0 ..< 3000:
    doAssert not ed.setTraceField(i mod 4, "trace.numSamples", 5)
  doAssert not ed.setTraceField(0, "trace.nope", 5)
  doAssert ed.log.count(sevError) == 1000 and ed.log.count(sevInfo) == 1, $ed.log.len
  doAssert ed.setTraceField(0, "trace.groupStatic", 3) and ed.edits == 1 # edits go on
  ed.close()
  doAssert ed.log.len == 1002 and ed.log.has("2001 refused edits were not logged", sevInfo)
  doAssert rollbackJournal(path, path & ".edits.nif").len == 0 and readBytes(path) == original
