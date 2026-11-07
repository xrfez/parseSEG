## Header fields by name (task 8.2): every named field read from the map
## equals the reader's decoded value, for every trace of the sample files.

import std/[assertions, os, macros, strutils, math]
import parseSEGD/segy/[reader as segyreader]
import parseSEGD/segd/[reader as segdreader]
import parseSEGD/model/[traceindex, headerfields, edit]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parsesegd_theaderfields"
createDir(tmp)

proc same[T](f: SeismicFile, get: proc (name: string, v: var FieldValue): bool, h: T,
    blockName: string): int =
  ## Compares every layout field of `h` with the named read; returns the count.
  for n, x in fieldPairs(h):
    when isLayoutField(x):
      var v: FieldValue
      when x is array:
        when typeof(x[0]) is char:
          doAssert get(blockName & "." & n, v) and v.kind == fvText
          for k, c in x: doAssert v.s[k] == c
          inc result
        else:
          doAssert not get(blockName & "." & n, v) # raw bytes are not fields
      elif x is SomeFloat:
        doAssert get(blockName & "." & n, v), n
        doAssert v.kind == fvFloat and (v.f == float64(x) or (v.f != v.f and x != x)), n
        inc result
      else:
        doAssert get(blockName & "." & n, v), n
        doAssert v.kind == fvInt and v.i == int64(x), blockName & "." & n & " " & $v
        inc result

block segy_every_field_of_every_trace:
  for n in ["BO_3D-Inglewood_rev21_v7.sgy", "Sweep0.sgy"]:
    var f = openSeismic(exampleDir / n)
    let d = readSegyHeaders(exampleDir / n)
    for i, t in d.traces:
      let get = proc (name: string, v: var FieldValue): bool = f.traceField(i, name, v)
      doAssert f.same(get, t.header, "trace") > 80
    let getFile = proc (name: string, v: var FieldValue): bool = f.fileField(name, v)
    doAssert f.same(getFile, d.file.binary, "binary") > 40
    f.close()

block segd_every_field_of_every_trace:
  for n in ["63.sgd", "inova_rev30_5traces.sgd"]:
    var f = openSeismic(exampleDir / n)
    let d = readSegdHeaders(exampleDir / n)
    var i = 0
    for r, rd in d.records:
      let getRec = proc (name: string, v: var FieldValue): bool = f.recordField(r, name, v)
      doAssert f.same(getRec, rd.record.gh1, "gh1") > 15
      if not rd.record.isRev3:
        for k, s in rd.record.sourceHeaders:
          doAssert f.same(getRec, s, "gh" & $(k + 3)) > 5
      for t in rd.traces:
        let ii = i
        let get = proc (name: string, v: var FieldValue): bool = f.traceField(ii, name, v)
        doAssert f.same(get, t.header, "trace") > 8
        if t.hasExt1:
          if rd.record.isRev3: doAssert f.same(get, t.ext1r3, "ext1") > 10
          else: doAssert f.same(get, t.ext1, "ext1") > 5
        inc i
    f.close()

block names_errors_and_edits:
  doAssert "sourceX" in fieldNames(hbSegyTrace) and "raw" notin fieldNames(hbSegdTrace)
  doAssert "unassigned1" notin fieldNames(hbSegyBinary) # raw bytes
  doAssert "headerName" in fieldNames(hbSegyTrace)      # text
  doAssert "groupIndex" in fieldNames(hbSegdExt1Rev3) and "groupIndex" notin fieldNames(hbSegdExt1)
  var f = openSeismic(exampleDir / "63.sgd")
  var v: FieldValue
  var err: string
  doAssert not f.traceField(0, "trace.nope", v, err) and "not a field" in err
  doAssert not f.traceField(1, "trace.traceNumber", v, err) and "no trace" in err
  doAssert not f.recordField(0, "gh4.sourcePointNumber", v, err)
  doAssert not f.fileField("binary.jobId", v, err) # SEG-D has no binary header
  doAssert f.recordField(0, "gh3.sourcePointNumber", v) and v.toFloat == 99.5
  f.close()
  # Reads go through the map, so they see edits at once.
  let path = tmp / "e.sgy"
  copyFile(exampleDir / "Sweep0.sgy", path)
  if fileExists(path & ".edits.nif"): removeFile(path & ".edits.nif")
  var ed = openEditor(path)
  doAssert ed.setField(0, "trace.groupX", 4321)
  doAssert ed.file.traceField(0, "trace.groupX", v) and v.i == 4321
  ed.close()

block sample_intervals:
  for (n, us) in [("BO_3D-Inglewood_rev21_v7.sgy", 2000.0), ("Sweep0.sgy", 1000.0),
      ("63.sgd", -1.0), ("inova_rev30_5traces.sgd", -1.0)]:
    var f = openSeismic(exampleDir / n)
    for i in 0..<f.len:
      let dt = f.sampleIntervalUs(i)
      doAssert dt > 0, n
      if us > 0: doAssert dt == us, n & " " & $dt
    doAssert f.sampleIntervalUs(f.len).isNaN
    f.close()
  # Against the readers: SEG-Y's trace interval, SEG-D's channel set.
  let d = readSegyHeaders(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  doAssert f.sampleIntervalUs(3) == d.traces[3].sampleInterval
  f.close()
