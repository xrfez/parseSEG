## SEG-Y datum and statics columns (Phase 16.8): scaled by the elevation and
## time scalars, Ext1 copies override, unknown for SEG-D and SEG-2.

import std/[assertions, math, os]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tstatics")

block segy_statics_scaled:
  let p = tmp / "statics.sgy"
  copyFile(demoDir() / "survey.sgy", p)
  if fileExists(p & ".edits.nif"): removeFile(p & ".edits.nif")
  var ed = openEditor(p)
  for (name, v) in [("trace.elevationScalar", -10), ("trace.timeScalar", 10),
      ("trace.sourceDepth", 125), ("trace.receiverDatumElevation", 3000),
      ("trace.sourceDatumElevation", 3100), ("trace.weatheringVelocity", 800),
      ("trace.subweatheringVelocity", 2000), ("trace.upholeTimeSource", 4),
      ("trace.upholeTimeGroup", 5), ("trace.sourceStatic", -3), ("trace.groupStatic", 2),
      ("trace.totalStatic", 1)]:
    doAssert ed.setTraceField(7, name, v), name & " " & $ed.log
  doAssert ed.setTraceField(9, "trace.receiverDatumElevation", 250)
  ed.close()
  var f = openSeismic(p)
  let s = f.traceStatics(7..7)[0]
  doAssert s.srcDepth == 12.5 and s.rcvDatum == 300 and s.srcDatum == 310
  doAssert s.weatheringVelocity == 800 and s.subweatheringVelocity == 2000
  doAssert s.srcUphole == 40 and s.rcvUphole == 50 and s.srcStatic == -30 and
    s.rcvStatic == 20 and s.totalStatic == 10
  doAssert s.rcvDepth.isNaN # no Trace Header Extension 1
  let all = f.traceStatics(0 ..< f.len)
  doAssert all.len == 200 and all[0].srcStatic == 0 and all[0].srcDepth == 0
  # Datum fields that were never filled in (both 0) are unknown, not a datum
  # at elevation 0; one of the pair set makes both known.
  doAssert all[0].srcDatum.isNaN and all[0].rcvDatum.isNaN
  doAssert all[9].rcvDatum == 250 and all[9].srcDatum == 0
  var two = newSeq[TraceStatics](2)
  f.traceStaticsInto([7, 0], two)
  doAssert two[0].srcStatic == -30 and two[0].srcDatum == 310 and two[1].srcStatic == 0
  doAssertRaises(ValueError): f.traceStaticsInto(0..2, two)
  doAssertRaises(ValueError): discard f.traceStatics([200])
  f.close()

block extension_1_gives_a_datum_the_standard_header_lacks:
  # A converted SEG-D record has Trace Header Extension 1: its datum fields
  # override, also when the standard pair is unset.
  let p = tmp / "ext1.sgy"
  doAssert not convertFile(demoDir() / "shot.sgd", p).isFatal
  if fileExists(p & ".edits.nif"): removeFile(p & ".edits.nif")
  var before = openSeismic(p)
  let was = before.traceStatics(0 .. 1)
  doAssert was[0].srcDatum.isNaN and was[0].rcvDatum.isNaN and was[1].srcDatum.isNaN
  before.close()
  var ed = openEditor(p)
  doAssert ed.setTraceField(0, "ext1.extSourceDatumElevation", 12.5), $ed.log
  ed.close()
  var f = openSeismic(p)
  let st = f.traceStatics(0 .. 1)
  doAssert st[0].srcDatum == 12.5 and st[0].rcvDatum.isNaN and st[1].srcDatum.isNaN
  f.close()

block other_standards_are_unknown:
  for n in ["shot.sgd", "line.sg2"]:
    var f = openSeismic(demoDir() / n)
    let s = f.traceStatics(0..0)[0]
    doAssert s.srcStatic.isNaN and s.srcDatum.isNaN and s.weatheringVelocity.isNaN
    f.close()

echo "tstatics: ok"
