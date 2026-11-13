## Stored keys stay current under header edits (Phase 16.4): trace, batch,
## file and record edits refresh them and bump `keysRevision`; values a join
## wrote win over the headers; `rollbackJournal(ed)` and `applyJournal(ed)`
## on the open editor restore and redo the keys and the cached headers.

import std/[assertions, math, os]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_teditkeys")

func sameKeys(a, b: TraceKeys): bool =
  result = true
  for x, y in fields(a, b):
    when x is SomeFloat:
      if not (x == y or (x.isNaN and y.isNaN)): return false
    else:
      if x != y: return false

proc copyOf(name, dst: string): string =
  result = tmp / dst
  copyFile(demoDir() / name, result)
  if fileExists(result & ".edits.nif"): removeFile(result & ".edits.nif")

proc freshKeys(path: string): seq[TraceKeys] =
  ## The keys of a fresh open (no index cache, no join).
  var f = openSeismic(path, keys = true)
  result = f.traceKeys(0 ..< f.len)
  f.close()

proc matchesFresh(ed: HeaderEditor, path: string): bool =
  let k = freshKeys(path)
  result = k.len == ed.file.len
  for i in 0 ..< k.len:
    if not sameKeys(ed.file.traceKeys(i), k[i]): return false

block trace_edits_refresh_the_keys:
  let p = copyOf("survey.sgy", "trace.sgy")
  let original = freshKeys(p)
  var ed = openEditor(openSeismic(p, keys = true))
  doAssert ed.file.keysRevision == 0
  doAssert ed.setTraceField(17, "trace.sourceX", 512_300)
  # survey.sgy's Layout stanza reads bytes 73-80 as the CDP X/Y.
  doAssert ed.file.traceKeys(17).cmpX == 512_300 and ed.file.keysRevision == 1
  doAssert ed.matchesFresh(p) # the bytes reached the map
  doAssert ed.setTraceField(17, "trace.delayRecordingTime", 40)
  doAssert ed.setTraceField(17, "trace.traceIdCode", 2)
  doAssert ed.file.traceKeys(17).t0Ms == 40 and ed.file.traceKeys(17).status == tsDead
  doAssert ed.file.keysRevision == 3
  doAssert ed.setTraceField(17, "trace.traceIdCode", 2) # a no-op: no new revision
  doAssert ed.file.keysRevision == 3
  # A field no key reads: no new revision.
  doAssert ed.setTraceField(3, "trace.lagTimeA", 7)
  doAssert ed.file.keysRevision == 3
  doAssert ed.matchesFresh(p)
  # The binary interval of a fixed-length file feeds every trace's keys.
  doAssert ed.setFileField("binary.sampleInterval", 4000)
  doAssert ed.file.traceKeys(0).intervalUs == 4000 and ed.file.traceKeys(199).intervalUs == 4000
  doAssert ed.file.keysRevision == 4 and ed.file.index.segyIntervalUs == 4000
  doAssert ed.matchesFresh(p)
  # Rollback on the open editor: keys and the binary header as they were.
  let undo = ed.rollbackJournal()
  doAssert undo.count(sevError) + undo.count(sevFatal) == 0, $undo
  for i in 0 ..< ed.file.len: doAssert sameKeys(ed.file.traceKeys(i), original[i])
  doAssert ed.file.index.segy.binary.sampleInterval == 2000
  doAssert ed.file.index.segyIntervalUs == 2000
  doAssert ed.file.keysRevision == 5
  doAssert ed.matchesFresh(p)
  # Redo.
  let redo = ed.applyJournal()
  doAssert redo.count(sevError) + redo.count(sevFatal) == 0, $redo
  doAssert ed.file.traceKeys(17).cmpX == 512_300 and ed.file.traceKeys(0).intervalUs == 4000
  doAssert ed.file.keysRevision == 6
  doAssert ed.matchesFresh(p)
  var f = release(move ed)
  doAssert f.traceKeys(17).t0Ms == 40 and f.keysRevision == 6
  f.close()

block batch_edits_refresh_once_written:
  let p = copyOf("survey.sgy", "batch.sgy")
  var ed = openEditor(openSeismic(p, keys = true))
  ed.beginBatch()
  for t in [5, 6, 5]:
    doAssert ed.setTraceField(t, "trace.delayRecordingTime", 10 * t)
  doAssert ed.file.traceKeys(5).t0Ms == 0 and ed.file.keysRevision == 0 # not yet on the map
  doAssert ed.endBatch()
  doAssert ed.file.traceKeys(5).t0Ms == 50 and ed.file.traceKeys(6).t0Ms == 60
  doAssert ed.file.keysRevision == 1 # once per batch
  doAssert ed.matchesFresh(p)
  ed.close()

block editor_without_keys:
  let p = copyOf("survey.sgy", "nokeys.sgy")
  var ed = openEditor(p)
  doAssert not ed.file.hasKeys
  doAssert ed.setTraceField(1, "trace.delayRecordingTime", 12)
  doAssert not ed.file.hasKeys and ed.file.keysRevision == 0
  doAssert ed.file.startTimeMs(1) == 12
  ed.close()

block joined_values_win_over_the_headers:
  let p = copyOf("record.sgd", "joined.sgd")
  var f = openSeismic(p, keys = true)
  var g: GeometryTable
  g.addReceiver(10, 104, 0, 1000, 2000)
  g.addReceiver(10, 105, 0, 3000, 4000)
  doAssert f.index.applyGeometry(g) == 1
  doAssert f.traceKeys(0).rcvX == 1000 and f.keysRevision == 1
  var ed = openEditor(move f)
  # The station is the file's own (not joined): the edit shows.
  doAssert ed.setTraceField(0, "ext1.receiverPointNumber", 105)
  let k = ed.file.traceKeys(0)
  doAssert k.rcvPoint == 105 and k.rcvX == 1000 and k.rcvY == 2000, $k # the join's coordinates stay
  doAssert ed.file.keysRevision == 2
  doAssert ed.setTraceField(0, "trace.traceEdit", 1)
  doAssert ed.file.traceKeys(0).status == tsDead and ed.file.traceKeys(0).rcvX == 1000
  # A record edit refreshes the record's traces.
  let before = ed.file.traceKeys(0).time
  doAssert ed.setRecordField(0, "gh1.hour", 3)
  doAssert ed.file.traceKeys(0).time != before and ed.file.traceKeys(0).rcvX == 1000
  ed.close()

proc receiverFile(path: string) =
  ## Four SEG-Y traces of record 1 whose headers hold the receiver X/Y and
  ## elevation only; trace 3 also a (binned) CDP X/Y.
  if fileExists(path & ".edits.nif"): removeFile(path & ".edits.nif")
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0)))
  for i in 0 ..< 4:
    var k = initTraceKeys()
    (k.record, k.channel, k.intervalUs, k.status) = (1.0, float64(i + 1), 2000.0, tsLive)
    (k.rcvX, k.rcvY, k.rcvZ) = (1000.0 + 10.0 * float64(i), 2000.0, 30.0)
    if i == 3: (k.cmpX, k.cmpY) = (750.0, 1250.0)
    w.writeTrace(k, [1'f32, 2, 3, 4])
  discard w.close()

proc sourceSurvey(): SurveyGeometry =
  ## Record 1's channels 1-4: source 10/100 (with coordinates), receivers
  ## 20/201-204 (stations only).
  result = initSurveyGeometry()
  result.addSource(10, 100, 1, 500.0, 600.0)
  var sps = SpsFile()
  var r = initSpsRelation()
  (r.fieldRecord, r.fromChannel, r.toChannel, r.channelIncrement) = (1'i64, 1'i64, 4'i64, 1)
  (r.srcLine, r.srcPoint, r.srcIndex) = (10.0, 100.0, 1)
  (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) = (20.0, 201.0, 204.0, 1)
  sps.relations.add r
  result.addSps(sps)

block a_partial_join_leaves_the_rest_to_the_headers:
  # The survey knows the source only. The receiver coordinates stay the
  # headers': the keys follow an edit of them, the offset and midpoint the
  # join derived are derived again, and writeGeometry does not write the old
  # receiver back over the edit.
  let p = tmp / "partial.sgy"
  receiverFile(p)
  var f = openSeismic(p, keys = true)
  doAssert f.applySurvey(sourceSurvey()) == 4
  doAssert f.index.joinedGroups(2) == {jgSourceXy, jgDerived, jgSourceStation,
    jgReceiverStation}, $f.index.joinedGroups(2)
  doAssert f.traceKeys(2).offset == hypot(1020.0 - 500, 2000.0 - 600)
  doAssert f.traceKeys(3).cmpX == 750 # the header's midpoint is kept (no overwrite)
  var ed = openEditor(move f)
  let raw = ed.currentTraceField(2, "trace.groupX").intVal
  doAssert ed.setTraceField(2, "trace.groupX", raw + 7000) # the scalar is -1000: 7 more
  var k = ed.file.traceKeys(2)
  doAssert k.rcvX == 1027 and k.srcX == 500 and k.srcPoint == 100 and k.rcvPoint == 203, $k
  doAssert k.offset == hypot(1027.0 - 500, 2000.0 - 600), $k.offset
  doAssert k.cmpX == (500.0 + 1027) / 2 and k.cmpY == (600.0 + 2000) / 2
  # The elevation was never joined: it follows its header too.
  doAssert ed.setTraceField(2, "trace.receiverElevation",
    ed.currentTraceField(2, "trace.receiverElevation").intVal * 2)
  doAssert ed.file.traceKeys(2).rcvZ == 60
  # A header midpoint the join kept stays when the receiver moves; the
  # offset it derived follows.
  doAssert ed.setTraceField(3, "trace.groupX", ed.currentTraceField(3, "trace.groupX").intVal +
    7000)
  k = ed.file.traceKeys(3)
  doAssert k.cmpX == 750 and k.cmpY == 1250 and k.offset == hypot(1037.0 - 500, 2000.0 - 600), $k
  # An edit elsewhere in the header changes none of the joined values.
  let before = ed.file.traceKeys(1)
  doAssert ed.setTraceField(1, "trace.delayRecordingTime", 8)
  var want = before
  want.t0Ms = 8
  doAssert sameKeys(ed.file.traceKeys(1), want)
  let ch = ed.writeGeometry()
  doAssert ch.sourceXy == 4 and ch.receiverXy == 0, $ch
  doAssert ed.currentTraceField(2, "trace.groupX").intVal == raw + 7000 # the edit stands
  ed.close()
  let fresh = freshKeys(p)
  doAssert fresh[2].rcvX == 1027 and fresh[2].srcX == 500 and fresh[2].rcvZ == 60
  doAssert abs(fresh[2].offset - hypot(1027.0 - 500, 2000.0 - 600)) <= 0.5

block a_join_of_both_ends_keeps_what_it_derived:
  let p = tmp / "both.sgy"
  receiverFile(p)
  var g = sourceSurvey()
  for i in 0 ..< 4: g.addReceiver(20, 201 + float64(i), 1, 5000.0 + float64(i), 6000.0, 7.0)
  var f = openSeismic(p, keys = true)
  doAssert f.applySurvey(g, overwrite = true) == 4
  doAssert f.index.joinedGroups(0) == {jgSourceXy, jgReceiverXy, jgReceiverZ, jgDerived,
    jgSourceStation, jgReceiverStation}, $f.index.joinedGroups(0)
  let joined = f.traceKeys(0)
  var ed = openEditor(move f)
  doAssert ed.setTraceField(0, "trace.groupX", 1)
  doAssert ed.setTraceField(0, "trace.receiverElevation", 1)
  doAssert sameKeys(ed.file.traceKeys(0), joined) # every edited value was the join's
  ed.close()

block changed_groups_name_what_differs:
  var a = initTraceKeys()
  var b = a
  doAssert changedGroups(a, b) == {}
  b.srcY = 1
  b.rcvZ = 2
  b.cmpX = 3
  b.rcvIndex = 1
  b.component = 12
  doAssert changedGroups(a, b) == {jgSourceXy, jgReceiverZ, jgDerived, jgReceiverStation,
    jgComponent}
  a = b
  b.srcZ = 4
  b.rcvX = 5
  b.offset = 6
  b.srcPoint = 7
  doAssert changedGroups(a, b) == {jgSourceZ, jgReceiverXy, jgDerived, jgSourceStation}

block rollback_restores_record_headers:
  let p = copyOf("record.sgd", "record.sgd")
  let original = freshKeys(p)
  var ed = openEditor(openSeismic(p, keys = true))
  let hour = ed.file.index.segdRecords[0].gh1.hour
  doAssert ed.setRecordField(0, "gh1.hour", (hour + 1) mod 24)
  doAssert ed.setTraceField(0, "ext1.receiverLineNumber", 11)
  doAssert not sameKeys(ed.file.traceKeys(0), original[0])
  discard ed.rollbackJournal()
  doAssert ed.file.index.segdRecords[0].gh1.hour == hour
  doAssert sameKeys(ed.file.traceKeys(0), original[0])
  ed.close()
  # The path form agrees on disk.
  discard applyJournal(p, p & ".edits.nif")
  doAssert freshKeys(p)[0].rcvLine == 11

block record_edits_wait_for_the_batch:
  # Three records (the demo record three times over, one trace each; their
  # trace time is the General Header #1 time). In a batch a record edit is
  # journaled in memory like a trace edit: no sync per edit, and the index
  # copies and the keys of its traces are refreshed once, when the batch is
  # written.
  let p = tmp / "three.sgd"
  let one = readFile(demoDir() / "record.sgd")
  writeFile(p, one & one & one)
  let journal = p & ".edits.nif"
  if fileExists(journal): removeFile(journal)
  let original = freshKeys(p)
  var ed = openEditor(openSeismic(p, keys = true))
  doAssert ed.file.recordCount == 3 and ed.file.len == 3
  let hour = ed.file.index.segdRecords[0].gh1.hour
  let synced = getFileSize(journal)
  ed.beginBatch()
  for r in 0 ..< 3:
    doAssert ed.setRecordField(r, "gh1.hour", (hour + 1 + r) mod 24)
    doAssert ed.setRecordField(r, "gh1.minute", 7 + r) # twice per record
  doAssert ed.setTraceField(2, "trace.traceEdit", 2)
  doAssert getFileSize(journal) == synced, "nothing is synced before the batch ends"
  doAssert ed.file.keysRevision == 0 and sameKeys(ed.file.traceKeys(1), original[1])
  doAssert ed.file.index.segdRecords[1].gh1.hour == hour # the copy follows the map
  doAssert ed.currentRecordField(1, "gh1.hour").intVal == (hour + 2) mod 24 # as edited so far
  doAssert ed.endBatch()
  doAssert getFileSize(journal) > synced and ed.file.keysRevision == 1 # once per batch
  for r in 0 ..< 3:
    doAssert ed.file.index.segdRecords[r].gh1.hour == (hour + 1 + r) mod 24
    doAssert ed.file.index.segdRecords[r].gh1.minute == 7 + r
    doAssert ed.file.traceKeys(r).time != original[r].time, $r
  doAssert ed.file.traceKeys(2).status == tsDead
  doAssert ed.matchesFresh(p)
  # Outside a batch a record edit shows at once, in its own traces only.
  let (k0, k1) = (ed.file.traceKeys(0), ed.file.traceKeys(1))
  doAssert ed.setRecordField(1, "gh1.second", 59)
  doAssert ed.file.index.segdRecords[1].gh1.second == 59 and ed.file.keysRevision == 2
  doAssert sameKeys(ed.file.traceKeys(0), k0) and not sameKeys(ed.file.traceKeys(1), k1)
  doAssert ed.matchesFresh(p)
  discard ed.rollbackJournal()
  for i in 0 ..< 3: doAssert sameKeys(ed.file.traceKeys(i), original[i])
  doAssert ed.file.index.segdRecords[2].gh1.minute == ed.file.index.segdRecords[0].gh1.minute
  ed.close()

block the_edit_that_fills_a_batch_refreshes_its_keys:
  # A batch is written whenever it holds 4096 edits. The keys of the trace
  # whose edit filled it were left as they were when no later edit followed
  # (trace 95 here: its key stayed 0 with 21 in the file).
  let p = copyOf("survey.sgy", "full.sgy")
  var ed = openEditor(openSeismic(p, keys = true))
  ed.beginBatch()
  for i in 0 ..< 4095:
    doAssert ed.setTraceField(0, "trace.delayRecordingTime", 1 + i mod 2)
  doAssert ed.setTraceField(95, "trace.delayRecordingTime", 21) # the 4096th: written at once
  doAssert ed.setFileField("binary.jobId", 4096) # no trace edit follows
  doAssert ed.endBatch()
  doAssert ed.edits == 4097 and ed.file.traceKeys(95).t0Ms == 21
  doAssert ed.matchesFresh(p)
  ed.close()

echo "teditkeys: ok"
