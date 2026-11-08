## In-place header edits with an undo journal (task 6.6).

import std/[assertions, os, strutils]
import parseSEG/common/[diagnostics, endians]
import parseSEG/io/diskio
import parseSEG/segy/[reader as segyreader, writer as segywriter]
import parseSEG/segd/[reader as segdreader]
import parseSEG/model/[traceindex, edit]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_tedit"
createDir(tmp)

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

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

block segy_trace_and_binary_edits_and_rollback:
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

block refused_edits_change_nothing:
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

block segy_little_endian_and_ext1:
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

block segd_rev2_edits:
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

block segd_rev3_edits:
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

block journal_conflicts_crashes_and_damage:
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

block edit_through_the_mapped_index:
  # Values written through the editor are what range reads see next.
  let (path, _) = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  var ed = openEditor(path)
  doAssert ed.setTraceField(3, "trace.sourceY", 99)
  let t = ed.file.readTraces(3..3)
  doAssert t.shape == [1, 2001]
  ed.close()
