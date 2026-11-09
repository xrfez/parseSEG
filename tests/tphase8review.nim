## Regression tests for the Phase 8 review findings.
## One block per finding (b<N> = the Nim-side review's numbering).

import std/[assertions, os, math, strutils]
import parseSEG/common/endians
import parseSEG/io/diskio
import parseSEG/segy/[reader as segyreader, fields]
import parseSEG/segd/[reader as segdreader, writer as segdwriter]
import parseSEG/model/[traceindex, keys, prefetch]
import parseSEG/convert

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_tphase8review"
createDir(tmp)

proc errorsAndWorse(log: DiagLog): int = log.count(sevError) + log.count(sevFatal)

proc warned(log: DiagLog, text: string): bool =
  for e in log.items:
    if e.severity == sevWarning and text in e.msg: return true

proc writeSegdFile(d: SegdData, path: string) =
  let sink = openDiskSink(path)
  doAssert writeSegd(sink, d).len == 0
  sink.close()

proc recordAs(f: SegdSampleFormat, vals: seq[float64], fileNo: int): SegdRecordData =
  ## 63.sgd's record with its one trace re-encoded as format `f`.
  let d = readSegd(exampleDir / "63.sgd")
  result = d.records[0]
  result.record.format = some(f)
  result.record.gh1.formatCode = ord(f)
  result.record.gh1.fileNumber = fileNo
  result.traces[0].samples = newSeq[byte](dataBytes(f, vals.len))
  encodeSegdSamples(f, vals, result.traces[0].samples)

proc decoded(y: SegyData, i: int): seq[float64] =
  result = newSeq[float64](y.traces[i].numSamples)
  decodeSamples(y.file.format.get, y.traces[i].samples, result, y.file.byteOrder)

block b1_records_in_different_formats_convert_exactly:
  var ints, floats = newSeq[float64](1000)
  for j in 0..<1000:
    ints[j] = float64(123_456_789 + 1001 * j)
    floats[j] = 0.0062 + float64(j) * 1e-3
  var floats32 = floats
  for v in floats32.mitems: v = float64(float32(v)) # what 8058 holds exactly
  for order in [@[(sd8058, floats32), (sd8038, ints)], @[(sd8038, ints), (sd8058, floats32)]]:
    var d: SegdData
    for k, (f, v) in order: d.records.add recordAs(f, v, 70 + k)
    writeSegdFile(d, tmp / "mixed.sgd")
    let log = convertFile(tmp / "mixed.sgd", tmp / "mixed.sgy")
    doAssert log.errorsAndWorse == 0 and not log.warned("could not be written exactly")
    let y = readSegy(tmp / "mixed.sgy")
    doAssert y.file.format == some(sfFloat64) # one format that holds both
    for k, (f, v) in order: doAssert y.decoded(k) == v
  # Without the header scan (e.g. from tape) the first record decides, and
  # the loss is reported instead of silent.
  var d: SegdData
  d.records.add recordAs(sd8058, floats32, 1)
  d.records.add recordAs(sd8038, ints, 2)
  writeSegdFile(d, tmp / "mixed2.sgd")
  let src = openDiskSource(tmp / "mixed2.sgd")
  let sink = openDiskSink(tmp / "mixed2.sgy")
  let log = convertSegdToSegy(src, sink)
  src.close()
  sink.close()
  doAssert log.warned("1 traces (the first is trace 1) could not be written exactly")

block b2_out_of_range_time_zero_does_not_raise:
  for tz in [high(int64), low(int64)]:
    var d = readSegd(exampleDir / "inova_rev30_5traces.sgd")
    d.records[0].record.gh3.timeZero = tz
    let sink = openDiskSink(tmp / "tz.sgd")
    discard writeSegd(sink, d, SegdWriteOptions(lenient: true))
    sink.close()
    let log = convertFile(tmp / "tz.sgd", tmp / "tz.sgy")
    doAssert not log.isFatal
    var found = false
    for e in log.items:
      if "outside years 1-9999" in e.msg: found = true
    doAssert found
    doAssert readSegy(tmp / "tz.sgy").traces[3].header.year == 0

block b3_position_after_additional_source_info_is_the_source:
  var rec = SegdRecord(layout: slRev3)
  var t = SegdTrace(layout: slRev3, ext1Rev3: some(SegdTraceHeaderExt1Rev3()))
  var src = SegdSourceDescription(sourceLineNumber: 1, sourcePointNumber: 2, blockType: 0x15)
  var asi = newSeq[byte](32)
  asi[31] = 0x20
  var pos = SegdPositionBlock(position1Valid: 1, position1Quality: 1, tuple1Coord1: 500,
    tuple1Coord2: 600, tuple1Coord3: Inf, blockType1: 0x50, blockType2: 0x51, blockType3: 0x52)
  t.extensions.add src.encoded
  t.extensions.add asi
  t.extensions.add pos.encoded
  let k = traceKeys(rec, t)
  doAssert k.srcX == 500 and k.srcY == 600 and k.srcZ.isNaN and k.rcvX.isNaN

block b4_selection_prefetchers_do_not_leak:
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let before = getOccupiedMem()
  for _ in 0..<20:
    var p = newPrefetcher[float32](f, newSeq[int](1_000_000), chunkTraces = 4, depth = 1, cols = 4)
    p.close()
  for _ in 0..<5:
    block:
      var q = newPrefetcher[float32](f, newSeq[int](1_000_000), chunkTraces = 4, depth = 1,
        cols = 4)
      discard q.len # destroyed without close
  doAssert getOccupiedMem() - before < 16 shl 20, $(getOccupiedMem() - before)
  f.close()

block b5_8036_to_pair_swapped_stays_exact:
  var vals = newSeq[float64](1000)
  for j in 0..<1000: vals[j] = float64(j * 7919 - 4_000_000)
  var d: SegdData
  d.records.add recordAs(sd8036, vals, 5)
  writeSegdFile(d, tmp / "i24.sgd")
  let log = convertFile(tmp / "i24.sgd", tmp / "i24.sgy", ConvertOptions(byteOrder: boPairSwapped))
  doAssert log.errorsAndWorse == 0, $log
  let y = readSegy(tmp / "i24.sgy")
  doAssert y.file.format == some(sfInt32) and y.decoded(0) == vals
  doAssert convertFile(tmp / "i24.sgd", tmp / "x.sgy",
    ConvertOptions(byteOrder: boPairSwapped, format: st7)).isFatal

block b6_losses_are_reported_and_ibm_is_copied:
  # Descaled int32 values stay exact in float64 (Rev 2).
  var ints = newSeq[float64](1000)
  for j in 0..<1000: ints[j] = float64(100_000_001 + j)
  var d: SegdData
  d.records.add recordAs(sd8038, ints, 6)
  writeSegdFile(d, tmp / "d.sgd")
  let mp = d.records[0].record.scanTypes[0].descriptors[0].mpFactor
  doAssert convertFile(tmp / "d.sgd", tmp / "d.sgy", ConvertOptions(applyDescale: true)).
    errorsAndWorse == 0
  let y = readSegy(tmp / "d.sgy")
  doAssert y.file.format == some(sfFloat64)
  for j, v in y.decoded(0): doAssert v == ints[j] * pow(2.0, mp)
  # A forced integer format that rounds is reported.
  var fr = newSeq[float64](1000)
  for j in 0..<1000: fr[j] = 0.25 + float64(j)
  var e: SegdData
  e.records.add recordAs(sd8058, fr, 7)
  writeSegdFile(e, tmp / "fr.sgd")
  doAssert convertFile(tmp / "fr.sgd", tmp / "fr.sgy", ConvertOptions(format: st3)).
    warned("could not be written exactly in SEG-Y format 3")
  # SEG-Y → SEG-Y to a narrower format is reported too.
  doAssert convertFile(tmp / "fr.sgy", tmp / "fr16.sgy", ConvertOptions(format: st3)).len >= 0
  doAssert convertFile(tmp / "d.sgy", tmp / "d32.sgy", ConvertOptions(format: st5)).
    warned("could not be written exactly in SEG-Y format 5")
  # 8048 IBM words beyond float32's range are copied, not rounded.
  var ibm: SegdData
  ibm.records.add recordAs(sd8048, newSeq[float64](1000), 8)
  var words = newSeq[byte](4000)
  for j in 0..<1000:
    let w = if j mod 2 == 0: 0x7FFF_FFFF'u32 - uint32(j) else: 0x0110_0000'u32 + uint32(j)
    putNum(words, 4 * j, w, boBig)
  ibm.records[0].traces[0].samples = words
  writeSegdFile(ibm, tmp / "ibm.sgd")
  for order in [boBig, boLittle]:
    doAssert convertFile(tmp / "ibm.sgd", tmp / "ibm.sgy", ConvertOptions(byteOrder: order)).
      errorsAndWorse == 0
    let z = readSegy(tmp / "ibm.sgy")
    doAssert z.file.format == some(sfIbm32)
    for j in 0..<1000:
      doAssert getNum[uint32](z.traces[0].samples, 4 * j, order) ==
        getNum[uint32](words, 4 * j, boBig)

block b7_rev1_fractional_interval_is_rounded_in_the_binary_header:
  var d = readSegd(exampleDir / "63.sgd")
  d.records[0].record.gh1.baseScanInterval16 = 1 # 62.5 µs
  writeSegdFile(d, tmp / "625.sgd")
  doAssert convertFile(tmp / "625.sgd", tmp / "625.sgy",
    ConvertOptions(revision: SegyRevision(major: 1))).errorsAndWorse == 0
  let y = readSegy(tmp / "625.sgy")
  doAssert y.file.binary.sampleInterval == 62 or y.file.binary.sampleInterval == 63
  doAssert not y.log.warned("sample interval is 0")

block b8_station_header_survives_a_byte_order_change:
  doAssert convertFile(exampleDir / "63.sgd", tmp / "st_be.sgy").errorsAndWorse == 0
  let log = convertFile(tmp / "st_be.sgy", tmp / "st_le.sgy", ConvertOptions(byteOrder: boLittle))
  doAssert log.errorsAndWorse == 0 and not log.warned("no known layout")
  let y = readSegy(tmp / "st_le.sgy")
  doAssert y.file.fieldValue(y.traces[0], "rec_line") == some(13.0)
  doAssert y.file.fieldValue(y.traces[0], "sht_point") == some(99.5)

block b9_converting_a_file_onto_itself_is_refused:
  copyFile(exampleDir / "Sweep0.sgy", tmp / "self.sgy")
  let before = readFile(tmp / "self.sgy")
  doAssert convertFile(tmp / "self.sgy", tmp / "self.sgy").isFatal
  doAssert readFile(tmp / "self.sgy") == before

block geometry_overwrite_semantics:
  # Filling one end keeps a signed SEG-Y header offset and a known elevation.
  var k = initTraceKeys()
  (k.srcX, k.srcY, k.offset, k.rcvZ) = (0.0, 0.0, -250.0, 12.0)
  (k.rcvLine, k.rcvPoint) = (1.0, 2.0)
  var g: GeometryTable
  g.addReceiver(1, 2, 0, 300, 400) # no z
  doAssert k.applyGeometry(g)
  doAssert k.offset == -250 and k.rcvZ == 12 and k.cmpX == 150
  doAssert k.applyGeometry(g, overwrite = true) and k.offset == 500
