## `writeTrace(w, src, trace, samples, keys)`: processed traces written like
## their input, with the geometry of keys held in memory (joined or edited)
## written into the template's headers, for SEG-Y, SEG-D Rev 2 and Rev 3 and
## SEG-2; values with no slot are reported by `close`, never dropped
## silently. Runs on the demo files (`tools/demofiles`).

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils
import ../tools/demofiles

let tmp = scratchDir("parseseg_twritejoined")

proc doubled(f: SeismicFile, i: int): seq[float32] =
  ## Trace `i`'s samples, times 2: "processed".
  let x = f.readTraces(i..i)
  for j in 0 ..< int(f.traceEntry(i).numSamples): result.add 2'f32 * x[0, j]

proc warned(log: DiagLog, text: string): bool =
  for d in log:
    if d.severity == sevWarning and text in d.msg: return true

proc shotSegy(path: string) =
  ## A SEG-Y shot in the standard layout, from keys: 8 traces of 50
  ## samples, source and receiver coordinates and stations.
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(major: 1)))
  for i in 0 ..< 8:
    var k = initTraceKeys()
    (k.record, k.channel, k.intervalUs, k.t0Ms) = (7.0, float64(i + 1), 2000.0, 0.0)
    (k.srcX, k.srcY, k.srcZ, k.srcPoint) = (500000.0, 6_000_000.0, 10.0, 101.0)
    (k.rcvX, k.rcvY, k.rcvZ) = (500025.0 * 1 + 25.0 * float64(i), 6_000_000.0, 12.0)
    var x = newSeq[float32](50)
    for j in 0 ..< 50: x[j] = float32(i * 100 + j)
    w.writeTrace(k, x)
  discard w.close()

block segy_like_input_with_edited_keys:
  # Every trace gets new source and receiver coordinates; they read back
  # with the samples, and the midpoint and offset follow them.
  let src = tmp / "shot.sgy"
  shotSegy(src)
  var f = openSeismic(src, keys = true)
  let dst = tmp / "shot_xy.sgy"
  var w = openSeismicWriter(dst, like = f)
  var want: seq[TraceKeys]
  for i in 0 ..< f.len:
    var k = f.index.keys[i]
    (k.srcX, k.srcY) = (600000.0, 4_100_000.5)
    (k.rcvX, k.rcvY) = (600100.0 + float64(i), 4_100_000.5)
    want.add k
    w.writeTrace(f, i, f.doubled(i), k)
  let log = w.close()
  doAssert not log.hasErrors, $log
  var o = openSeismic(dst, keys = true)
  for i in 0 ..< f.len:
    let k = o.traceKeys(i)
    doAssert k.srcX == want[i].srcX and k.srcY == want[i].srcY, $i
    doAssert k.rcvX == want[i].rcvX and k.rcvY == want[i].rcvY, $i
    doAssert k.offset == 100 + float64(i) and k.cmpX == 600050.0 + float64(i) / 2, $k
    doAssert k.srcZ == 10 and k.rcvZ == 12 and k.channel == float64(i + 1)
    doAssert o.readTraces(i..i)[0, 30] == 2'f32 * f.readTraces(i..i)[0, 30]
  o.close()
  # The same keys as the headers: nothing changes but the samples.
  var same = openSeismicWriter(tmp / "shot_same.sgy", like = f)
  for i in 0 ..< f.len: same.writeTrace(f, i, f.doubled(i), f.index.keys[i])
  let sameLog = same.close()
  doAssert sameLog.len == 0, $sameLog
  doAssert readFile(tmp / "shot_same.sgy").len == readFile(src).len
  f.close()

block segy_value_without_a_slot:
  # survey.sgy's Layout stanza keeps the inline and crossline numbers where
  # the standard layout has the source X/Y: they have no field there, so
  # they are reported, while the receiver X/Y are written.
  let src = tmp / "survey.sgy"
  writeSurveySegy(src)
  var f = openSeismic(src, keys = true)
  var w = openSeismicWriter(tmp / "survey_xy.sgy", like = f)
  for i in 0 ..< f.len:
    var k = f.index.keys[i]
    (k.srcX, k.srcY, k.rcvX, k.rcvY) = (600000.0, 4_100_000.0, 600100.0, 4_100_000.0)
    w.writeTrace(f, i, f.doubled(i), k)
  let log = w.close()
  doAssert log.warned("source X/Y: the file's layout has no field for it; not written " &
    "in 200 traces"), $log
  var o = openSeismic(tmp / "survey_xy.sgy", keys = true)
  doAssert o.traceKeys(5).rcvX == 600100 and o.traceKeys(5).srcX.isNaN
  doAssert o.traceKeys(5).inline == f.index.keys[5].inline
  o.close()
  f.close()

block segy_joined_by_a_survey:
  # The use this exists for: SEG-Y converted from SEG-D carries its stations
  # (the PSEGD001 header of its Layout stanza) and no coordinates; a join
  # gives them, in memory only. Written like the input with its keys, the
  # output holds them; written without, it does not.
  let segd = tmp / "record_j.sgd"
  writeRecordSegd(segd)
  let src = tmp / "record_j.sgy"
  doAssert not convertFile(segd, src).isFatal
  var f = openSeismic(src, keys = true)
  var g: GeometryTable
  var seismic = -1
  for i in 0 ..< f.len:
    let k = f.index.keys[i]
    if not k.rcvPoint.isNaN:
      seismic = i
      g.addReceiver(k.rcvLine, k.rcvPoint, k.rcvIndex, 500100, 6_000_000, 12.5)
  doAssert seismic >= 0 and f.index.keys[seismic].rcvX.isNaN
  doAssert f.applyGeometry(g) >= 1 and f.index.keys[seismic].rcvX == 500100
  var w = openSeismicWriter(tmp / "record_joined.sgy", like = f)
  for i in 0 ..< f.len: w.writeTrace(f, i, f.doubled(i), f.index.keys[i])
  doAssert not w.close().hasErrors
  var o = openSeismic(tmp / "record_joined.sgy", keys = true)
  doAssert o.traceKeys(seismic).rcvX == 500100 and o.traceKeys(seismic).rcvZ == 12.5
  doAssert o.traceKeys(seismic).rcvPoint == f.index.keys[seismic].rcvPoint
  o.close()
  var plain = openSeismicWriter(tmp / "record_plain.sgy", like = f)
  for i in 0 ..< f.len: plain.writeTrace(f, i, f.doubled(i))
  discard plain.close()
  var p = openSeismic(tmp / "record_plain.sgy", keys = true)
  doAssert p.traceKeys(seismic).rcvX.isNaN
  p.close()
  f.close()

block segd_rev2_stations_and_no_slot_for_coordinates:
  # SEG-D Rev 2 holds the receiver station in THE#1 and no coordinates:
  # the station is written, the coordinates are reported, not dropped
  # silently.
  let src = tmp / "record.sgd"
  writeRecordSegd(src)
  var f = openSeismic(src, keys = true)
  let dst = tmp / "record_keys.sgd"
  var w = openSeismicWriter(dst, like = f)
  var edited = -1
  for i in 0 ..< f.len:
    var k = f.index.keys[i]
    if k.status != tsAuxiliary and not k.rcvPoint.isNaN:
      edited = i
      k.rcvPoint = k.rcvPoint + 1
      (k.rcvX, k.rcvY) = (500100.0, 6_000_000.0)
    w.writeTrace(f, i, f.doubled(i), k)
  let log = w.close()
  doAssert edited >= 0
  doAssert log.warned("not written in 1 traces"), $log
  var o = openSeismic(dst, keys = true)
  doAssert o.traceKeys(edited).rcvPoint == f.index.keys[edited].rcvPoint + 1
  doAssert o.traceKeys(edited).rcvX.isNaN
  doAssert o.readTraces(edited..edited)[0, 10] == 2'f32 * f.readTraces(edited..edited)[0, 10]
  o.close()
  f.close()

block segd_rev3_positions:
  # SEG-D Rev 3 traces with receiver Position blocks: new coordinates go
  # there. Records are written whole: the auxiliary traces with their own
  # keys.
  let src = tmp / "shot.sgd"
  writeShotSegd(src)
  var f = openSeismic(src, keys = true)
  let dst = tmp / "shot_keys.sgd"
  var w = openSeismicWriter(dst, like = f)
  var moved: seq[int]
  for i in 0 ..< f.len:
    var k = f.index.keys[i]
    if not k.rcvX.isNaN:
      moved.add i
      (k.rcvX, k.rcvY) = (k.rcvX + 10, k.rcvY - 5)
    w.writeTrace(f, i, f.doubled(i), k)
  doAssert not w.close().hasErrors
  doAssert moved.len >= 1
  var o = openSeismic(dst, keys = true)
  for i in moved:
    doAssert abs(o.traceKeys(i).rcvX - (f.index.keys[i].rcvX + 10)) < 1e-6, $i
    doAssert abs(o.traceKeys(i).rcvY - (f.index.keys[i].rcvY - 5)) < 1e-6, $i
  o.close()
  f.close()

block seg2_strings:
  # SEG-2: locations, station numbers and the line go into the trace
  # strings; a source line other than the receiver line has no slot.
  let src = tmp / "line.sg2"
  writeLineSeg2(src)
  var f = openSeismic(src, keys = true)
  let dst = tmp / "line_keys.sg2"
  var w = openSeismicWriter(dst, like = f)
  for i in 0 ..< f.len:
    var k = f.index.keys[i]
    (k.srcX, k.srcY, k.srcZ) = (-5.0, 0.0, 101.5)
    (k.rcvX, k.rcvY) = (2.5 * float64(i), 1.0)
    (k.rcvPoint, k.srcPoint) = (float64(200 + i), 199.0)
    (k.rcvLine, k.srcLine) = (7.0, if i == 3: 8.0 else: 7.0)
    w.writeTrace(f, i, f.doubled(i), k)
  let log = w.close()
  doAssert log.warned("SEG-2 has one LINE_ID"), $log
  var o = openSeismic(dst, keys = true)
  for i in [0, 3, 23]:
    let k = o.traceKeys(i)
    doAssert k.srcX == -5 and k.srcY == 0 and k.srcZ == 101.5, $k
    doAssert k.rcvX == 2.5 * float64(i) and k.rcvY == 1, $k
    doAssert k.rcvPoint == float64(200 + i) and k.srcPoint == 199, $k
    if i == 3: doAssert k.rcvLine.isNaN, $k # two lines: no LINE_ID (the warning)
    else: doAssert k.rcvLine == 7 and k.srcLine == 7, $k
    doAssert k.offset == hypot(2.5 * float64(i) + 5, 1)
    doAssert o.readTraces(i..i)[0, 10] == 2'f32 * f.readTraces(i..i)[0, 10]
  o.close()
  f.close()
