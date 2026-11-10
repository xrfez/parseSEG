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

echo "teditkeys: ok"
