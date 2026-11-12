## Header fields by name (task 8.2): every named field read from the map
## equals the reader's decoded value, for every trace of the sample files.

import std/[assertions, os, macros, options, strutils, math]
import parseSEG/segy/[reader as segyreader]
import parseSEG/segd/[reader as segdreader]
import parseSEG/model/[traceindex, headerfields, edit]
import parseSEG/private/fieldaccess
import ./utils/testutils

let tmp = scratchDir("parseseg_theaderfields")

proc same[T](f: SeismicFile, get: proc (name: string): Option[FieldValue], h: T,
    blockName: string): int =
  ## Compares every layout field of `h` with the named read; returns the count.
  for n, x in fieldPairs(h):
    when isLayoutField(x):
      let r = get(blockName & "." & n)
      when x is array:
        when typeof(x[0]) is char:
          doAssert r.isSome and r.get.kind == fvText
          for k, c in x: doAssert r.get.text[k] == c
          inc result
        else:
          doAssert r.isNone # raw bytes are not fields
      elif x is SomeFloat:
        doAssert r.isSome, n
        let v = r.get
        doAssert v.kind == fvFloat and (v.floatVal == float64(x) or (v.floatVal.isNaN and x.isNaN)), n
        inc result
      else:
        doAssert r.isSome, n
        let v = r.get
        doAssert v.kind == fvInt and v.intVal == int64(x), blockName & "." & n & " " & $v
        inc result

sampleBlock segy_every_field_of_every_trace:
  for n in ["BO_3D-Inglewood_rev21_v7.sgy", "Sweep0.sgy"]:
    var f = openSeismic(exampleDir / n)
    let d = readSegyHeaders(exampleDir / n)
    for i, t in d.traces:
      let get = proc (name: string): Option[FieldValue] = f.findTraceField(i, name)
      doAssert f.same(get, t.header, "trace") > 80
    let getFile = proc (name: string): Option[FieldValue] = f.findFileField(name)
    doAssert f.same(getFile, d.file.binary, "binary") > 40
    f.close()

sampleBlock segd_every_field_of_every_trace:
  for n in ["63.sgd", "inova_rev30_5traces.sgd"]:
    var f = openSeismic(exampleDir / n)
    let d = readSegdHeaders(exampleDir / n)
    var i = 0
    for r, rd in d.records:
      let getRec = proc (name: string): Option[FieldValue] = f.findRecordField(r, name)
      doAssert f.same(getRec, rd.record.gh1, "gh1") > 15
      if not rd.record.isRev3:
        for k, s in rd.record.sourceHeaders:
          doAssert f.same(getRec, s, "gh" & $(k + 3)) > 5
      for t in rd.traces:
        let ii = i
        let getField = proc (name: string): Option[FieldValue] = f.findTraceField(ii, name)
        doAssert f.same(getField, t.header, "trace") > 8
        case t.layout
        of slRev2:
          if t.ext1.isSome: doAssert f.same(getField, t.ext1.get, "ext1") > 5
        of slRev3:
          if t.ext1Rev3.isSome: doAssert f.same(getField, t.ext1Rev3.get, "ext1") > 10
        inc i
    f.close()

block field_names_are_one_table:
  # `fieldNames` built a new seq on every call; the lists are constants now
  # and a call lends one: the same storage every time, nothing allocated.
  for kind in HeaderBlock:
    doAssert fieldNames(kind).len == fieldNames(kind).len
    if fieldNames(kind).len > 0:
      doAssert addr(fieldNames(kind)[0]) == addr(fieldNames(kind)[0]), $kind
  doAssert fieldNames(hbRaw).len == 0
  doAssert fieldNames(hbSegyTrace).len == 91 and fieldNames(hbSegyTrace)[0] == "traceSeqLine"
  doAssert fieldNames(hbSegyBinary)[0] == "jobId" and fieldNames(hbSegdGh1)[0] == "fileNumber"
  doAssert fieldNames(hbSeg2Trace)[0] == "blockId"
  # A caller's copy is its own.
  var mine = fieldNames(hbSegdGh1)
  mine.add "extra"
  doAssert "extra" notin fieldNames(hbSegdGh1) and mine.len == fieldNames(hbSegdGh1).len + 1
  let before = getOccupiedMem()
  var total = 0
  for i in 0 ..< 1000:
    for kind in HeaderBlock: total += fieldNames(kind).len
  doAssert getOccupiedMem() == before and total > 0

sampleBlock names_errors_and_edits:
  doAssert "sourceX" in fieldNames(hbSegyTrace) and "raw" notin fieldNames(hbSegdTrace)
  doAssert "unassigned1" notin fieldNames(hbSegyBinary) # raw bytes
  doAssert "headerName" in fieldNames(hbSegyTrace)      # text
  doAssert "groupIndex" in fieldNames(hbSegdExt1Rev3) and "groupIndex" notin fieldNames(hbSegdExt1)
  var f = openSeismic(exampleDir / "63.sgd")
  template raisesWith(body: untyped, what: string) =
    try:
      discard body
      doAssert false, "no ValueError"
    except ValueError as e:
      doAssert what in e.msg, e.msg
  raisesWith(f.traceField(0, "trace.nope"), "trace.nope: is not a field")
  raisesWith(f.traceField(1, "trace.traceNumber"), "no trace")
  raisesWith(f.traceField(0, "traceNumber"), "expected <block>.<field>")
  doAssert f.findTraceField(0, "trace.nope").isNone
  doAssert f.findRecordField(0, "gh4.sourcePointNumber").isNone
  doAssert f.findFileField("binary.jobId").isNone # SEG-D has no binary header
  doAssert f.recordField(0, "gh3.sourcePointNumber").toFloat == 99.5
  doAssert f.blockKind(hsTrace, 0, "ext1") == some(hbSegdExt1) and
    f.blockKind(hsFile, 0, "binary").isNone
  # `fieldByName` reads a decoded header object.
  let d = readSegdHeaders(exampleDir / "63.sgd")
  doAssert d.records[0].record.gh1.fieldByName("fileNumber") == some(toFieldValue(63))
  doAssert d.records[0].record.gh1.fieldByName("raw").isNone
  f.close()
  # Reads go through the map, so they see edits at once.
  let path = tmp / "e.sgy"
  copyFile(exampleDir / "Sweep0.sgy", path)
  if fileExists(path & ".edits.nif"): removeFile(path & ".edits.nif")
  var ed = openEditor(path)
  doAssert ed.setTraceField(0, "trace.groupX", 4321)
  doAssert ed.file.traceField(0, "trace.groupX").intVal == 4321
  ed.close()

sampleBlock sample_intervals:
  for (n, us) in [("BO_3D-Inglewood_rev21_v7.sgy", 2000.0), ("Sweep0.sgy", 1000.0),
      ("63.sgd", -1.0), ("inova_rev30_5traces.sgd", -1.0)]:
    var f = openSeismic(exampleDir / n)
    for i in 0..<f.len:
      let dt = f.sampleIntervalUs(i)
      doAssert dt > 0, n
      if us > 0: doAssert dt == us, n & " " & $dt
    doAssertRaises(ValueError): discard f.sampleIntervalUs(f.len)
    f.close()
    doAssertRaises(ValueError): discard f.sampleIntervalUs(0) # closed
  # Against the readers: SEG-Y's trace interval, SEG-D's channel set.
  let d = readSegyHeaders(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  doAssert f.sampleIntervalUs(3) == d.traces[3].sampleInterval
  f.close()
