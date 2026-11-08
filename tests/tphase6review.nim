## Regression tests for the Phase 6 review findings (one block per finding;
## a* = I/O, index and gathers review, b* = prefetch and edit review). The
## copy-volume (a2) and character-device (a7) findings are covered in
## tests/ttraceindex.nim (`headers_only_walk_copies_only_headers`,
## `skip_guards`).

import std/[assertions, os, strutils]
import parseSEG/io/[records, memsource]
import parseSEG/segy/[reader as segyreader]
import parseSEG/segd/[reader as segdreader]
import parseSEG/model/[traceindex, gathers, prefetch, edit]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_tphase6review"
createDir(tmp)

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc writeBytes(path: string, b: openArray[byte]) =
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(path, s)

proc copySample(name: string): (string, string) =
  let path = tmp / name
  copyFile(exampleDir / name, path)
  let j = path & ".edits.nif"
  if fileExists(j): removeFile(j)
  (path, j)

block a1_channel_set_index_beyond_int16:
  # 32768 dummy descriptors before the real one: the trace's set index is 32768.
  var b = readBytes(exampleDir / "63.sgd")
  b[28] = 0xFF # channel sets per scan type: see GH#2
  b[35] = 0x80 # GH#2 bytes 4-5: 32769
  b[36] = 0x01
  var dummy = newSeq[byte](32)
  dummy[0] = 0x01 # scan type 1
  dummy[1] = 0x99 # channel set 99, 0 channels
  var c = b[0 ..< 96]
  for _ in 0..<32768: c.add dummy
  c.add b[96 .. ^1]
  writeBytes(tmp / "manysets.sgd", c)
  var f = openSeismic(tmp / "manysets.sgd")
  doAssert f.len == 1 and f.index.entries[0].channelSetIndex == 32768
  doAssert f.readTraces(0..0).shape == [1, 1000]
  f.close()

block a3_segd_file_number_43xx_with_format_like_bytes:
  var b = readBytes(exampleDir / "63.sgd")
  b[0] = 0x43
  b[1] = 0x21
  b[3224] = 0x00
  b[3225] = 0x05
  var k: SeismicKind
  doAssert detectKind(b, k) and k == skSegd
  writeBytes(tmp / "4321.sgd", b)
  var f = openSeismic(tmp / "4321.sgd")
  doAssert f.kind == skSegd and f.len == 1 and not f.log.isFatal
  f.close()

block a4_segy_with_undefined_format_code_is_still_segy:
  var b = readBytes(exampleDir / "Sweep0.sgy")
  b[3224] = 0
  b[3225] = 0
  writeBytes(tmp / "fmt0.sgy", b)
  var f = openSeismic(tmp / "fmt0.sgy")
  doAssert f.kind == skSegy and f.index.detected
  var formatDiag = false
  for e in f.log.items:
    if e.severity == sevFatal and "format code" in e.msg: formatDiag = true
  doAssert formatDiag and f.index.segy.text.data[0] == byte(0x43)
  f.close()

block a5_segd_gathers_are_not_assumed_to_be_shots:
  # One receiver, the same record-level source on three traces of one
  # sensor type: the keys cannot tell, so the gather stays unknown.
  var ix = TraceIndex(kind: skSegd)
  for _ in 0..2:
    var k = initTraceKeys()
    k.srcLine = 10
    k.srcPoint = 5
    k.rcvLine = 7
    k.rcvPoint = 42
    k.sensorType = 2
    k.component = 2
    ix.keys.add k
    ix.entries.add TraceEntry(channelSet: NoChannelSet, scanType: -1)
  doAssert ix.gathers.len == 1 and ix.gathers[0].kind == gkUnknown

block a6_closed_maps_fail_cleanly:
  let s = openMemFileSource(exampleDir / "63.sgd")
  s.close()
  var buf: seq[byte]
  doAssert s.readRecord(buf) == rkEndOfData and s.memory == nil and s.size == 0
  var f = openSeismic(exampleDir / "63.sgd")
  var g: SeismicFile
  doAssert not compiles(`=copy`(g, f)) # a copy could outlive `close`
  f.close()
  var t = newTraceTensor[float32](1, 10)
  doAssert f.readTracesInto(0 .. -1, t) == 0 and not f.isOpen

block b1_edits_refused_on_files_that_are_not_seismic:
  writeFile(tmp / "junk.bin", repeat('\xEE', 8000))
  if fileExists(tmp / "junk.bin.edits.nif"): removeFile(tmp / "junk.bin.edits.nif")
  var ed = openEditor(tmp / "junk.bin")
  doAssert not ed.setFileField("binary.jobId", 5)
  doAssert not ed.setTraceField(0, "trace.sourceX", 5)
  ed.close()
  doAssert readFile(tmp / "junk.bin") == repeat('\xEE', 8000)

block b2_repeated_rollback_with_overlapping_spans:
  let (path, journal) = copySample("BO_3D-Inglewood_rev21_v7.sgy")
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

block b3_field_edited_twice_has_no_spurious_conflicts:
  let (path, journal) = copySample("BO_3D-Inglewood_rev21_v7.sgy")
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

block b4_hostile_journals_stay_bounded:
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
  let (path, _) = copySample("Sweep0.sgy")
  var lines = ""
  for k in 0..<50: lines.add "(edit " & $(4000 + 4 * k) & " \"abab\" \"cdcd\" \"x\")\n"
  writeFile(j, lines)
  let r = rollbackJournal(path, j)
  doAssert r.count(sevError) == 5 and r.count(sevInfo) == 1

block b5_huge_general_header_numbers_are_refused:
  let (path, _) = copySample("63.sgd")
  var ed = openEditor(path)
  var raised = false
  try:
    doAssert not ed.setRecordField(0, "gh99999999999999999999.sourceSetNumber", 1)
    doAssert not ed.setRecordField(0, "gh0003x.sourceSetNumber", 1)
  except CatchableError:
    raised = true
  doAssert not raised
  ed.close()

block b6_prefetch_of_zero_width_chunks:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  for i in 0..<10: f.index.entries[i].numSamples = 0
  var p = newPrefetcher[float32](f, 0 ..< 10, chunkTraces = 7, depth = 2)
  var c: PrefetchChunk[float32]
  var n = 0
  while p.next(c):
    doAssert c.samples.shape == [c.count, 0]
    n += c.count
  doAssert n == 10
  p.close()
  f.close()

block b7_prefetch_after_close:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 100_000) # slots capped at the file's 200
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.count == 200
  p.close()
  doAssert p.atEnd and not p.tryNext(c) and not p.next(c)
  p.seek(0 ..< p.positions)
  var q: Prefetcher[float32] # never started
  doAssert q.atEnd and not q.tryNext(c)
  f.close()
