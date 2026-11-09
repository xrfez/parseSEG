## The core procs added for task 12.5: file accessors, raising lookups, Slice ranges, survey geometry
## setup, and the `ValueError`s that replace assertions on bad input.

import std/[os, math, tables]
import parseSEG

const exampleDir = currentSourcePath().parentDir.parentDir / "SEG Spec" / "exampleFiles"

proc raisesValue(body: proc ()) =
  try:
    body()
    doAssert false, "no ValueError"
  except ValueError: discard

block file_accessors:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy", keys = true)
  doAssert f.kind == skSegy and f.len == 200 and f.recordCount == 1 and f.maxSamples == 2001
  doAssert f.hasKeys and f.isOpen and f.traceEntry(5).numSamples == 2001
  doAssert f.traceKeys(0).ensemble == 1001001.0
  doAssert f.traceField(5, "trace.sourceX").intVal == 1704188
  doAssert f.sampleIntervalUs() == 2000.0
  raisesValue(proc () = discard f.traceEntry(200))
  raisesValue(proc () = discard f.sampleIntervalUs(200))
  raisesValue(proc () = discard f.sampleIntervalUs(-1))
  raisesValue(proc () = discard f.maxSamples(0 .. 200))
  raisesValue(proc () = discard f.maxSamples([3, 200]))
  doAssert f.maxSamples(200 .. 199) == 0
  raisesValue(proc () = discard f.traceField(0, "trace.bogus"))
  raisesValue(proc () = discard f.fileField("gh1.year"))
  raisesValue(proc () = discard f.readTraces(199..200))
  raisesValue(proc () = discard f.readTraces([0, 200]))
  raisesValue(proc () = discard f.componentGroupIds(0 .. 1 shl 40))
  doAssert f.readTraces(200 .. 199).shape[0] == 0 # an empty range
  block closed:
    var g = openSeismic(exampleDir / "Sweep0.sgy")
    g.close()
    raisesValue(proc () = discard g.sampleIntervalUs(0))
  doAssert f.gathers.len >= 1 and f.componentGroupIds(0..9).len == 10
  let nokeys = openSeismic(exampleDir / "Sweep0.sgy")
  raisesValue(proc () = discard nokeys.traceKeys(0))
  raisesValue(proc () = discard nokeys.gathers)

block unknown_file:
  let path = getTempDir() / "parseseg_tcoreapi_junk.bin"
  writeFile(path, newString(5000))
  let f = openSeismic(path)
  doAssert f.kind == skUnknown and f.len == 0 and f.recordCount == 0 and f.log.isFatal
  doAssert f.log[f.log.len - 1].severity == sevFatal
  when compileOption("boundChecks"): # off under -d:danger
    try:
      discard f.log[f.log.len]
      doAssert false
    except IndexDefect: discard

block prefetch_ranges:
  var f = openSeismic(exampleDir / "Sweep0.sgy")
  raisesValue(proc () = discard newPrefetcher[float32](f, 0 .. f.len))
  raisesValue(proc () = discard newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 0))
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 4)
  raisesValue(proc () = discard p.traceAt(-1))
  raisesValue(proc () = discard p.traceAt(f.len))
  p.seek(f.len ..< f.len)
  var c: PrefetchChunk[float32]
  doAssert not p.next(c) and p.atEnd
  p.close()

block survey_setup:
  var g = initSurveyGeometry()
  g.addSource(1, 2, 0, 10, 20)
  g.addReceiver(1, 3, 0, 11, 21, 5)
  doAssert g.sourceCount == 1 and g.receiverCount == 1 and g.relationCount == 0
  g.mapLine(" LINE A ", 7)
  doAssert g.lineNames["LINE A"] == 7
  raisesValue(proc () = g.mapLine("", 1))
  raisesValue(proc () = g.mapLine("x", NaN))
  try:
    g.addSps(getTempDir() / "parseseg_no_such.sps")
    doAssert false
  except IOError: discard
  raisesValue(proc () = g.addP1(getTempDir() / "x.p1", P1Options(gridDecimals: 9)))

echo "tcoreapi: ok"
