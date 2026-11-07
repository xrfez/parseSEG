## Gather detection and multi-component grouping (task 6.2).

import std/[assertions, os, math]
import parseSEGD/io/diskio
import parseSEGD/segy/[reader as segyreader, writer as segywriter, fields]
import parseSEGD/segd/[reader as segdreader, writer as segdwriter]
import parseSEGD/model/[traceindex, gathers]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parsesegd_tgathers"
createDir(tmp)

proc key(record = NaN, ensemble = NaN, offset = NaN, sx = NaN, rx = NaN,
    comp = 0'u8): TraceKeys =
  result = initTraceKeys()
  result.record = record
  result.ensemble = ensemble
  result.offset = offset
  result.srcX = sx
  result.rcvX = rx
  result.component = comp

proc segyIndex(sorting: int16, ks: openArray[TraceKeys]): TraceIndex =
  result = TraceIndex(kind: skSegy, keys: @ks)
  result.segy.binary.traceSorting = sorting
  for _ in ks: result.entries.add TraceEntry(channelSet: NoChannelSet, scanType: -1)

proc kinds(gs: seq[Gather]): seq[GatherKind] =
  for g in gs: result.add g.kind

proc writeSegdFile(d: SegdData, path: string) =
  let sink = openDiskSink(path)
  try: doAssert writeSegd(sink, d).len == 0
  finally: sink.close()

block sample_files:
  for (n, want) in [("63.sgd", gkShot), ("inova_rev30_5traces.sgd", gkShot),
      ("Sweep0.sgy", gkUnknown), ("BO_3D-Inglewood_rev21_v7.sgy", gkUnknown)]:
    var f = openSeismic(exampleDir / n, keys = true)
    doAssert f.index.keys.len == f.len
    let gs = f.index.gathers
    doAssert gs.len == 1 and gs[0].kind == want and gs[0].traces == 0..<f.len, n
    f.close()
  # The INOVA record: 3 auxiliary traces are ignored, 2 seismic receivers.
  var f = openSeismic(exampleDir / "inova_rev30_5traces.sgd", keys = true)
  let g = f.index.gathers[0]
  doAssert g.sources == 1 and g.receivers == 2
  doAssert not f.index.isSeismic(0) and f.index.isSeismic(3)
  let cg = f.index.componentGroups(0..<f.len)
  doAssert cg.len == 2 and cg[0].traces == @[3] and not cg[0].isMultiComponent
  doAssert f.index.keys[3].srcLine == 129 and f.index.keys[3].srcPoint == 113
  f.close()

block segy_split_and_classify:
  # No sorting code: split on field record, classify from the geometry.
  let shots = segyIndex(0, [key(1, sx = 10, rx = 1), key(1, sx = 10, rx = 2),
    key(2, sx = 20, rx = 1), key(2, sx = 20, rx = 2)])
  doAssert shots.gathers.kinds == @[gkShot, gkShot]
  doAssert shots.gathers[1].traces == 2..3
  # Receiver gathers packed with minimal header changes: the field record
  # number counts receivers, the sources vary inside it.
  let rcv = segyIndex(0, [key(7, sx = 10, rx = 5), key(7, sx = 20, rx = 5),
    key(7, sx = 30, rx = 5), key(8, sx = 10, rx = 6), key(8, sx = 20, rx = 6)])
  doAssert rcv.gathers.kinds == @[gkReceiver, gkReceiver]
  doAssert rcv.gathers[0].sources == 3 and rcv.gathers[0].receivers == 1
  # Sort 6 splits on the ensemble number ...
  let s6 = segyIndex(6, [key(ensemble = 1, sx = 1, rx = 5), key(ensemble = 1, sx = 2, rx = 5),
    key(ensemble = 2, sx = 1, rx = 6), key(ensemble = 2, sx = 2, rx = 6)])
  doAssert s6.gathers.kinds == @[gkReceiver, gkReceiver]
  # ... and, when it never changes, on the receiver station.
  let s6b = segyIndex(6, [key(ensemble = 0, sx = 1, rx = 5), key(ensemble = 0, sx = 2, rx = 5),
    key(ensemble = 0, sx = 1, rx = 6)])
  doAssert s6b.gathers.len == 2 and s6b.gathers[1].traces == 2..2
  # Declared CMP and common-offset sorts name gathers the geometry cannot.
  let cmp = segyIndex(2, [key(ensemble = 1, sx = 1, rx = 9), key(ensemble = 1, sx = 2, rx = 8),
    key(ensemble = 2, sx = 3, rx = 7)])
  doAssert cmp.gathers.kinds == @[gkCmp, gkCmp]
  let off = segyIndex(7, [key(offset = 100, sx = 1, rx = 2), key(offset = 100, sx = 2, rx = 3),
    key(offset = 200, sx = 1, rx = 3)])
  doAssert off.gathers.kinds == @[gkOffset, gkOffset]
  # Several sources and receivers without a declared sort.
  doAssert segyIndex(0, [key(1, sx = 1, rx = 1), key(1, sx = 2, rx = 2)]).gathers.kinds ==
    @[gkOther]
  # NaN keys compare equal to each other: unknown records form one gather.
  doAssert segyIndex(0, [key(sx = 1, rx = 1), key(sx = 1, rx = 2)]).gathers.kinds == @[gkShot]

block component_groups_and_single_stations:
  # One station, one source: three components make a shot, three copies of
  # one component cannot be told apart.
  let mc = segyIndex(0, [key(1, sx = 1, rx = 5, comp = 12), key(1, sx = 1, rx = 5, comp = 13),
    key(1, sx = 1, rx = 5, comp = 14)])
  doAssert mc.gathers.kinds == @[gkShot]
  let cg = mc.componentGroups(0..2)
  doAssert cg.len == 1 and cg[0].isMultiComponent and cg[0].components == @[12'u8, 13, 14]
  doAssert segyIndex(0, [key(1, sx = 1, rx = 5), key(1, sx = 1, rx = 5)]).gathers.kinds ==
    @[gkUnknown]
  # Same station, different sources: separate groups (one per shot).
  let two = segyIndex(0, [key(1, sx = 1, rx = 5, comp = 12), key(1, sx = 2, rx = 5, comp = 12)])
  doAssert two.componentGroups(0..1).len == 2

block segy_end_to_end:
  # Sweep0 copied into a sorted receiver-gather file with component codes.
  let d0 = readSegy(exampleDir / "Sweep0.sgy")
  var d = d0
  d.traces.setLen 0
  d.file.binary.traceSorting = 6
  for i in 0..5:
    var t = d0.traces[0]
    t.header.ensembleNumber = int32(1 + i div 3)
    t.header.groupX = int32(1000 + 100 * (i div 3))
    t.header.groupY = 50
    t.header.sourceX = int32(10 * (i mod 3) + 1)
    t.header.sourceY = 7
    t.header.coordinateScalar = 1
    t.header.traceIdCode = 12
    d.traces.add t
  let path = tmp / "rcv.sgy"
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()
  var f = openSeismic(path, keys = true)
  let gs = f.index.gathers
  doAssert gs.kinds == @[gkReceiver, gkReceiver] and gs[1].traces == 3..5
  doAssert f.index.keys[4].rcvX == 1100 and f.index.keys[4].component == 12
  f.close()

block segd_rev2_multicomponent:
  # 63.sgd's trace repeated: 2 stations x 3 sensor types (geophone V/I/X).
  var d = readSegd(exampleDir / "63.sgd")
  var rd = d.records[0]
  let t0 = rd.traces[0]
  rd.traces.setLen 0
  for i in 0..5:
    var t = t0
    t.header.traceNumber = i + 1
    t.ext1.receiverPointNumber = int32(104 + i div 3)
    t.ext1.sensorType = uint8(2 + i mod 3)
    rd.traces.add t
  rd.record.scanTypes[0].descriptors[0].channelCount = 6
  rd.record.traceCount = 6
  d.records[0] = rd
  writeSegdFile(d, tmp / "mc.sgd")
  var f = openSeismic(tmp / "mc.sgd", keys = true)
  doAssert f.log.count(sevError) + f.log.count(sevFatal) == 0
  doAssert f.len == 6 and f.index.gathers.kinds == @[gkShot]
  let cg = f.index.componentGroups(0..5)
  doAssert cg.len == 2 and cg[1].traces == @[3, 4, 5]
  doAssert cg[0].isMultiComponent and cg[0].components == @[2'u8, 3, 4]
  doAssert cg[1].station.rcvPoint == 105
  f.close()

block segd_rev3_receiver_gather:
  # The INOVA record turned into a receiver gather: both seismic traces get
  # the same receiver and their own Source Description block (0x16) in place
  # of the first vendor extension.
  var d = readSegd(exampleDir / "inova_rev30_5traces.sgd")
  var rd = d.records[0]
  for i in 3..4:
    var src = SegdSourceDescription(sourceLineNumber: 129, sourcePointNumber: float64(200 + i),
      blockType: 0x16)
    let b = src.encoded
    for k in 0..<32: rd.traces[i].extensions[k] = b[k]
    rd.traces[i].ext1r3.receiverLineNumber = rd.traces[3].ext1r3.receiverLineNumber
    rd.traces[i].ext1r3.receiverPointNumber = rd.traces[3].ext1r3.receiverPointNumber
    rd.traces[i].ext1r3.extReceiverLineNumber = rd.traces[3].ext1r3.extReceiverLineNumber
    rd.traces[i].ext1r3.extReceiverPointNumber = rd.traces[3].ext1r3.extReceiverPointNumber
  d.records[0] = rd
  writeSegdFile(d, tmp / "rg.sgd")
  var f = openSeismic(tmp / "rg.sgd", keys = true)
  let g = f.index.gathers
  doAssert g.len == 1 and g[0].kind == gkReceiver and g[0].sources == 2 and g[0].receivers == 1
  doAssert f.index.keys[4].srcPoint == 204
  # Traces without their own source block fall back to the record's.
  doAssert f.index.keys[0].srcPoint == 113
  f.close()

block segd_rev3_positions_offsets_and_midpoints:
  # Task 8.5: Rev 3 Position blocks give coordinates; the record-level one
  # (INOVA writes it before the Source Description) is the source's.
  var f = openSeismic(exampleDir / "inova_rev30_5traces.sgd", keys = true)
  let k = f.index.keys[3]
  doAssert k.rcvX == 1826232.375 and k.rcvY == 446233.8125 and k.rcvZ == 1061.800048828125
  doAssert k.srcX == 1834704.375 and k.srcY == 445679.53125
  doAssert abs(k.offset - hypot(1834704.375 - 1826232.375, 445679.53125 - 446233.8125)) < 1e-9
  doAssert k.cmpX == (k.srcX + k.rcvX) / 2 and k.cmpY == (k.srcY + k.rcvY) / 2
  # Auxiliary traces' Position blocks are flagged invalid: no receiver coordinates.
  doAssert f.index.keys[0].rcvX.isNaN and f.index.keys[0].offset.isNaN
  f.close()

block external_geometry_joins_on_stations:
  # SEG-D 2.x has no coordinates: join them from a table (SPS in Phase 10).
  var f = openSeismic(exampleDir / "63.sgd", keys = true)
  let k0 = f.index.keys[0]
  doAssert k0.rcvX.isNaN and k0.srcX.isNaN and k0.offset.isNaN
  var g: GeometryTable
  g.addSource(13, 99.5, 1, 1000, 2000, 5)
  g.addReceiver(13, 104, 0, 1300, 2400) # index 0 matches any point index
  doAssert f.index.applyGeometry(g) == 1
  let k = f.index.keys[0]
  doAssert k.srcX == 1000 and k.srcZ == 5 and k.rcvX == 1300 and k.rcvZ.isNaN
  doAssert k.offset == 500 and k.cmpX == 1150 and k.cmpY == 2200
  doAssert f.index.applyGeometry(g) == 0 # already filled, not overwritten
  g.addReceiver(13, 104, 1, 1000, 2000)  # an exact index wins over the wildcard
  doAssert f.index.applyGeometry(g, overwrite = true) == 1
  doAssert f.index.keys[0].offset == 0 and f.index.keys[0].cmpX == 1000
  f.close()
  # SEG-Y: the header's CDP coordinates are the midpoint.
  var y = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy", keys = true)
  let d = readSegyHeaders(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  for i in [0, 57, 199]:
    let gm = d.file.geometry(d.traces[i]) # Inglewood's Layout maps cdp_x to byte 73
    doAssert y.index.keys[i].cmpX == gm.cdpX and y.index.keys[i].cmpY == gm.cdpY
  y.close()
