## `TraceRows` views (Phase 16.2), `ensureKeys` and `keysRevision` (16.3):
## range, selection and synthetic views give the stored keys; `sub` at its
## edges; views read from 4 threads; no allocation; keys built on demand
## equal the keys of `openSeismic(keys = true)`, also through an index cache;
## every key-changing path bumps the revision.

import std/[assertions, math, os, typedthreads]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_ttracerows")

func sameKeys(a, b: TraceKeys): bool =
  result = true
  for x, y in fields(a, b):
    when x is SomeFloat:
      if not (x == y or (x.isNaN and y.isNaN)): return false
    else:
      if x != y: return false

let files = [demoDir() / "survey.sgy", demoDir() / "shot.sgd", demoDir() / "record.sgd",
  demoDir() / "line.sg2"]

block range_selection_and_synthetic_views:
  for p in files:
    var f = openSeismic(p, keys = true)
    let all = f.rowsOf(0 ..< f.len)
    doAssert all.len == f.len
    for row in 0 ..< all.len:
      doAssert all.traceOf(row) == row
      doAssert sameKeys(all.traceKeys(row), f.traceKeys(row))
      doAssert all.numSamples(row) == int(f.traceEntry(row).numSamples)
      doAssert all.channelSetIndex(row) == f.traceEntry(row).channelSetIndex
    var sel: seq[int]
    for t in countdown(f.len - 1, 0, 2): sel.add t
    let s = f.rowsOf(sel)
    doAssert s.len == sel.len
    for row in 0 ..< s.len:
      doAssert s.traceOf(row) == sel[row]
      doAssert sameKeys(s.traceKeys(row), f.traceKeys(sel[row]))
      doAssert s.numSamples(row) == int(f.traceEntry(sel[row]).numSamples)
    if f.len > 2:
      let mid = f.rowsOf(1 ..< f.len)
      doAssert mid.traceOf(0) == 1 and sameKeys(mid.traceKeys(0), f.traceKeys(1))
    f.close()
  var keys = newSeq[TraceKeys](3)
  for i in 0..2:
    keys[i] = initTraceKeys()
    keys[i].offset = 100.0 * float64(i)
  let ns = [10, 20, 30]
  let syn = rowsOf(keys, ns)
  doAssert syn.len == 3 and syn.traceOf(2) == 2 and syn.traceKeys(2).offset == 200
  doAssert syn.numSamples(1) == 20 and syn.channelSetIndex(1) == -1
  let tail = syn.sub(1..2)
  doAssert tail.len == 2 and tail.traceOf(0) == 1 and tail.traceKeys(1).offset == 200
  doAssert tail.numSamples(0) == 20
  doAssertRaises(ValueError): discard rowsOf(keys, [1, 2])
  doAssert rowsOf(newSeq[TraceKeys](), newSeq[int]()).len == 0

block sub_at_the_edges:
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  let r = f.rowsOf(10 ..< 20)
  doAssert r.sub(0 .. -1).len == 0 and r.sub(10 .. 9).len == 0
  let whole = r.sub(0..9)
  doAssert whole.len == 10 and whole.traceOf(0) == 10 and whole.traceOf(9) == 19
  let last = r.sub(9..9)
  doAssert last.len == 1 and last.traceOf(0) == 19
  doAssert r.sub(3..5).sub(1..2).traceOf(1) == 15
  doAssertRaises(ValueError): discard r.sub(5..10)
  doAssertRaises(ValueError): discard r.sub(-1..2)
  doAssertRaises(ValueError): discard r.sub(11..10)
  let sel = [7, 3, 199, 0]
  let s = f.rowsOf(sel)
  doAssert s.sub(1..2).traceOf(0) == 3 and s.sub(1..2).traceOf(1) == 199
  doAssert s.sub(4..3).len == 0
  when compileOption("boundChecks"):
    doAssertRaises(IndexDefect): discard r.traceOf(10)
    doAssertRaises(IndexDefect): discard r.traceKeys(-1)
    doAssertRaises(IndexDefect): discard s.sub(1..2).numSamples(2)
  doAssertRaises(ValueError): discard f.rowsOf(0..200)
  doAssertRaises(ValueError): discard f.rowsOf([0, 200])
  # Without stored keys: traces, sample counts and channel sets, no keys.
  var n = openSeismic(demoDir() / "survey.sgy")
  let nk = n.rowsOf(0..1)
  doAssert not nk.hasKeys and nk.numSamples(1) == 2001 and nk.traceOf(1) == 1
  doAssertRaises(ValueError): discard nk.traceKeys(0)
  doAssertRaises(ValueError): discard n.rowsOf([0]).traceKeys(0)
  doAssert f.rowsOf(0..1).hasKeys
  n.close()
  f.close()

block views_do_not_allocate:
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  let sel = @[1, 2, 3]
  let before = getOccupiedMem()
  var total = 0
  for k in 0..999:
    let r = f.rowsOf(0 ..< f.len).sub(k mod 100 .. 150)
    let s = f.rowsOf(sel).sub(1..2)
    total += r.len + s.len + r.traceOf(0)
  doAssert getOccupiedMem() == before and total > 0
  f.close()

type Job = object
  rows: TraceRows
  sum: ptr float64

proc work(j: Job) {.thread.} =
  var s = 0.0
  for pass in 0..99:
    for row in 0 ..< j.rows.len:
      s += j.rows.traceKeys(row).cmpX + float64(j.rows.numSamples(row))
  j.sum[] = s

block views_read_from_four_threads:
  var f = openSeismic(demoDir() / "survey.sgy", keys = true)
  let r = f.rowsOf(0 ..< f.len)
  var sums: array[4, float64]
  var th: array[4, Thread[Job]]
  for i in 0..3:
    createThread(th[i], work, Job(rows: r.sub(i * 50 ..< (i + 1) * 50), sum: addr sums[i]))
  joinThreads(th)
  var want = 0.0
  for i in 0..3:
    var s = 0.0
    for pass in 0..99:
      for t in i * 50 ..< (i + 1) * 50: s += f.traceKeys(t).cmpX + 2001
    doAssert sums[i] == s
    want += s
  doAssert want > 0
  f.close()

block ensure_keys_matches_open_with_keys:
  for p in files:
    var k = openSeismic(p, keys = true)
    var f = openSeismic(p)
    doAssert not f.hasKeys and f.keysRevision == 0
    f.ensureKeys()
    doAssert f.hasKeys and f.keysRevision == 1
    for i in 0 ..< f.len: doAssert sameKeys(f.traceKeys(i), k.traceKeys(i)), p & " " & $i
    f.ensureKeys() # a no-op
    doAssert f.keysRevision == 1
    # Through an index cache saved without keys.
    let cache = tmp / (p.extractFilename & ".idx")
    var c = openSeismic(p)
    c.saveIndex(cache)
    c.close()
    var g = openSeismic(p, opts = OpenOptions(cache: cache))
    doAssert g.fromCache and not g.hasKeys
    g.ensureKeys()
    for i in 0 ..< g.len: doAssert sameKeys(g.traceKeys(i), k.traceKeys(i)), p & " " & $i
    g.close()
    k.close()
    f.close()

block ensure_keys_can_be_cancelled:
  var f = openSeismic(demoDir() / "survey.sgy")
  let stop: Progress = proc (done, total: int64): bool {.closure, gcsafe, raises: [].} = false
  doAssertRaises(SegCancelledError): f.ensureKeys(stop)
  doAssert not f.hasKeys and f.keysRevision == 0
  var calls = 0
  let count: Progress = proc (done, total: int64): bool {.closure, gcsafe, raises: [].} =
    inc calls
    true
  f.ensureKeys(count)
  doAssert f.hasKeys and calls >= 1
  f.close()

block joins_bump_the_revision_and_record_groups:
  var f = openSeismic(demoDir() / "record.sgd", keys = true)
  doAssert f.keysRevision == 0 and f.index.joinedGroups(0) == {}
  var g: GeometryTable
  g.addReceiver(10, 104, 0, 1000, 2000)
  doAssert f.index.applyGeometry(g) == 1
  doAssert f.keysRevision == 1 and f.index.joinedGroups(0) == {jgCoordinates}
  doAssert f.index.applyGeometry(g) == 0 # nothing changed: no new revision
  doAssert f.keysRevision == 1
  f.close()
  var s = openSeismic(demoDir() / "record.sgd", keys = true)
  var sg: SurveyGeometry
  sg.table.addSource(20, 99.5, 0, 10, 20)
  doAssert s.applySurvey(sg) == 1
  doAssert s.keysRevision == 1 and s.index.joinedGroups(0) == {jgCoordinates}
  s.close()

echo "ttracerows: ok"
