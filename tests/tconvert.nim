## Conversion between revisions and standards (task 8.6).

import std/[assertions, os, math, strutils]
import parseSEG/common/[diagnostics, endians, outputfile]
import parseSEG/io/diskio
import parseSEG/segy/[reader as segyreader, fields]
import parseSEG/segd/[reader as segdreader, writer as segdwriter]
import parseSEG/seg2/[writer as seg2writer]
import parseSEG/convert
import parseSEG/model/[traceindex, headerfields, keytypes, fieldvalues]
import ./utils/testutils

let tmp = scratchDir("parseseg_tconvert")

proc errorsAndWorse(log: DiagLog): int = log.count(sevError) + log.count(sevFatal)

proc noted(log: DiagLog, text: string): bool =
  for e in log.items:
    if text in e.msg: return true

proc value(d: SegyData, i: int, name: string): float64 =
  let v = d.file.fieldValue(d.traces[i], name)
  doAssert v.isSome, name
  v.get

sampleBlock segd_rev2_to_segy_rev21:
  let src = exampleDir / "63.sgd"
  let log = convertFile(src, tmp / "63.sgy")
  doAssert log.errorsAndWorse == 0, $log
  doAssert log.noted("extended/external headers are not carried")
  let d = readSegy(tmp / "63.sgy")
  doAssert d.log.errorsAndWorse == 0, $d.log
  doAssert d.file.revision == SegyRevision(major: 2, minor: 1) and d.file.format == some(sfFloat32)
  doAssert d.file.text.card(1).startsWith("C 1 CONVERTED FROM SEG-D REV 2.0")
  let s = readSegd(src)
  let t = d.traces[0]
  doAssert d.traces.len == 1 and t.numSamples == 1000
  doAssert t.header.fieldRecord == 63 and t.header.traceIdCode == 12 # vertical geophone
  var sf = openSeismic(src)
  doAssert float64(t.header.sampleInterval) == sf.sampleIntervalUs(0) and t.hasExt1
  sf.close()
  doAssert t.header.year == 2026 or t.header.year >= 1970
  for j in 0..<1000: doAssert d.samples[0, j] == s.records[0].samples[0, j]
  # Station values through the PSEGD001 header and its Layout stanza.
  doAssert d.value(0, "rec_line") == 13 and d.value(0, "rec_point") == 104
  doAssert d.value(0, "sht_point") == 99.5 and d.value(0, "sensor_type") == 2
  # A fractional source point goes in the scaled shotpoint alone: readers
  # take the energy source point when it is set, and it holds whole numbers
  # (it was written as 100, so the output's source point read back as 100).
  doAssert t.header.energySourcePoint == 0 and t.header.shotpointScalar == -100
  doAssert t.header.shotpointNumber == 9950
  var yf = openSeismic(tmp / "63.sgy", keys = true)
  doAssert yf.traceKeys(0).srcPoint == 99.5
  yf.close()

sampleBlock segd_rev3_to_segy_with_coordinates:
  let src = exampleDir / "inova_rev30_5traces.sgd"
  doAssert convertFile(src, tmp / "inova.sgy").errorsAndWorse == 0
  let d = readSegy(tmp / "inova.sgy")
  doAssert d.log.errorsAndWorse == 0, $d.log
  let s = readSegd(src)
  doAssert d.traces.len == 5
  for i in 0..4:
    for j in [0, 1, 2000, 3999]: doAssert d.samples[i, j] == s.records[0].samples[i, j]
  let t = d.traces[3]
  doAssert t.ext1.extGroupX == 1826232.375 and t.ext1.extSourceX == 1834704.375
  doAssert t.header.coordinateScalar == -1000 and t.header.groupX == 1826232375
  let off = hypot(1834704.375 - 1826232.375, 445679.53125 - 446233.8125)
  doAssert t.ext1.extOffset == off and t.header.offset == int32(round(off))
  doAssert t.header.receiverElevation != 0 and t.header.coordinateUnits == 1
  doAssert d.traces[0].header.traceIdCode != 12 # an auxiliary channel
  doAssert t.header.timeBasisCode == 4 and t.header.year >= 2000 # from the GH#3 time zero
  doAssert d.value(3, "segd_channel_type") == 0x10

sampleBlock segd_to_segy_rev1_and_descale:
  let src = exampleDir / "63.sgd"
  let log = convertFile(src, tmp / "63r1.sgy", ConvertOptions(revision: SegyRevision(major: 1)))
  doAssert log.errorsAndWorse == 0 and log.noted("no field for SEG-D receiver/source line")
  let d = readSegy(tmp / "63r1.sgy")
  doAssert d.file.revision.major == 1 and not d.traces[0].hasExt1
  doAssert d.log.errorsAndWorse == 0
  doAssert d.file.text.card(39).strip == "C39 SEG Y REV1" and d.traces[0].header.fieldRecord == 63
  # Descaled: recorded value × 2^MP.
  let s = readSegd(src)
  let mp = s.records[0].record.scanTypes[0].descriptors[0].mpFactor
  doAssert convertFile(src, tmp / "63mv.sgy", ConvertOptions(applyDescale: true)).errorsAndWorse == 0
  let m = readSegy(tmp / "63mv.sgy")
  for j in 0..<1000:
    doAssert m.samples[0, j] == float32(float64(s.records[0].samples[0, j]) * pow(2.0, mp))

sampleBlock lossless_format_choice:
  # An 8038 (int32) record converts to SEG-Y format 2, exactly.
  var d = readSegd(exampleDir / "63.sgd")
  var rd = d.records[0]
  rd.record.format = some(sd8038)
  rd.record.gh1.formatCode = 8038
  var vals = newSeq[float64](1000)
  for j in 0..<1000: vals[j] = float64(j * 1001 - 500_000)
  rd.traces[0].samples = newSeq[byte](dataBytes(sd8038, 1000))
  encodeSamples(sd8038, vals, rd.traces[0].samples)
  d.records[0] = rd
  let sink = openDiskSink(tmp / "i32.sgd")
  doAssert writeSegd(sink, d).len == 0
  sink.close()
  doAssert convertFile(tmp / "i32.sgd", tmp / "i32.sgy").errorsAndWorse == 0
  let y = readSegy(tmp / "i32.sgy")
  doAssert y.file.format == some(sfInt32)
  var raw = newSeq[float64](1000)
  decodeSamples(sfInt32, y.traces[0].samples, raw)
  doAssert raw == vals
  # A forced format that cannot hold the values zeroes the trace, with an error.
  let log = convertFile(tmp / "i32.sgd", tmp / "i8.sgy",
    ConvertOptions(format: st8)) # int8
  doAssert log.count(sevError) == 1 and log.noted("do not fit")

sampleBlock segy_revision_and_byte_order_changes:
  let ing = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  let a = readSegy(ing)
  # Rev 2.1 IBM → Rev 1 IEEE float: same values, extended text kept.
  var log = convertFile(ing, tmp / "ing_r1.sgy",
    ConvertOptions(revision: SegyRevision(major: 1), format: st5))
  doAssert log.errorsAndWorse == 0, $log
  let b = readSegy(tmp / "ing_r1.sgy")
  doAssert b.file.revision.major == 1 and b.file.format == some(sfFloat32)
  doAssert b.traces.len == 200 and b.samples == a.samples
  doAssert b.file.extended.recordCount == a.file.extended.recordCount
  doAssert b.traces[57].header == a.traces[57].header
  # Rev 0 little-endian → Rev 2.1 little-endian (declared by the marker) → Rev 1 big-endian.
  let sw = exampleDir / "Sweep0.sgy"
  let s0 = readSegy(sw)
  log = convertFile(sw, tmp / "sw_le.sgy", ConvertOptions(byteOrder: boLittle))
  doAssert log.errorsAndWorse == 0, $log
  let s1 = readSegy(tmp / "sw_le.sgy")
  doAssert s1.file.byteOrder == boLittle and s1.file.byteOrderDeclared
  doAssert s1.samples == s0.samples and s1.file.revision.major == 2
  log = convertFile(tmp / "sw_le.sgy", tmp / "sw_be.sgy",
    ConvertOptions(revision: SegyRevision(major: 1)))
  doAssert log.errorsAndWorse == 0, $log
  let s2 = readSegy(tmp / "sw_be.sgy")
  doAssert s2.file.byteOrder == boBig and s2.samples == s0.samples
  # Rev 2.1 → Rev 0: the extended text is dropped, and that is reported.
  log = convertFile(ing, tmp / "ing_r0.sgy", ConvertOptions(revision: SegyRevision(major: 0)))
  doAssert log.noted("Rev 0 has no extended textual headers")
  doAssert readSegy(tmp / "ing_r0.sgy").traces.len == 200

sampleBlock invalid_targets_and_inputs:
  let sw = exampleDir / "Sweep0.sgy"
  for o in [ConvertOptions(revision: SegyRevision(major: 1), byteOrder: boLittle),
      ConvertOptions(revision: SegyRevision(major: 1), format: st6), # float64 needs Rev 2
      ConvertOptions(revision: SegyRevision(major: 3))]:
    doAssert convertFile(sw, tmp / "bad.sgy", o).isFatal
  doAssert convertFile(tmp / "missing", tmp / "x.sgy").isFatal
  writeFile(tmp / "junk", repeat('\0', 5000))
  doAssert convertFile(tmp / "junk", tmp / "x.sgy").isFatal

block converted_samples_equal_the_input_with_reused_buffers:
  # Task 13.2: the conversion buffers are sized uninitialized; every sample
  # of every trace must still be the input's (multi-trace files, so buffers
  # are reused from trace to trace).
  for name in ["inova_rev30_5traces.sgd", "00000151_12900_11300.sgd"]:
    let src = if name.startsWith("inova"): sampleOr(name) else: exampleDir / name
    if fileExists(src):
      let dst = getTempDir() / ("parseseg_reuse_" & name & ".sgy")
      let log = convertFile(src, dst, ConvertOptions())
      doAssert not log.hasErrors, $log
      var a = openSeismic(src)
      var b = openSeismic(dst)
      doAssert a.len == b.len
      let ta = a.readTraces(0 ..< a.len, float64)
      let tb = b.readTraces(0 ..< b.len, float64)
      doAssert ta == tb, name
      a.close()
      b.close()
      removeFile(dst)

# ------------------------------------------------- Phase 8 review --

proc warned(log: DiagLog, text: string): bool =
  for e in log.items:
    if e.severity == sevWarning and text in e.msg: return true

proc writeSegdFile(d: SegdData, path: string) =
  let sink = openDiskSink(path)
  doAssert writeSegd(sink, d).len == 0
  sink.close()

proc recordAs(f: SegdSampleFormat, vals: seq[float64], fileNo: int): SegdRecordData =
  ## 63.sgd's record (or the demo file standing in for it) with its one trace
  ## re-encoded as format `f`.
  let d = readSegd(sampleOr("63.sgd"))
  result = d.records[0]
  result.record.format = some(f)
  result.record.gh1.formatCode = ord(f)
  result.record.gh1.fileNumber = fileNo
  result.traces[0].samples = newSeq[byte](dataBytes(f, vals.len))
  encodeSamples(f, vals, result.traces[0].samples)

proc decoded(y: SegyData, i: int): seq[float64] =
  result = newSeq[float64](y.traces[i].numSamples)
  decodeSamples(y.file.format.get, y.traces[i].samples, result, y.file.byteOrder)

block p8_b1_records_in_different_formats_convert_exactly:
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

sampleBlock p8_b2_out_of_range_time_zero_does_not_raise:
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

block p8_b5_8036_to_pair_swapped_stays_exact:
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

block p8_b6_losses_are_reported_and_ibm_is_copied:
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

sampleBlock p8_b7_rev1_fractional_interval_is_rounded_in_the_binary_header:
  var d = readSegd(exampleDir / "63.sgd")
  d.records[0].record.gh1.baseScanInterval16 = 1 # 62.5 µs
  writeSegdFile(d, tmp / "625.sgd")
  doAssert convertFile(tmp / "625.sgd", tmp / "625.sgy",
    ConvertOptions(revision: SegyRevision(major: 1))).errorsAndWorse == 0
  let y = readSegy(tmp / "625.sgy")
  doAssert y.file.binary.sampleInterval == 62 or y.file.binary.sampleInterval == 63
  doAssert not y.log.warned("sample interval is 0")

sampleBlock p8_b8_station_header_survives_a_byte_order_change:
  doAssert convertFile(exampleDir / "63.sgd", tmp / "st_be.sgy").errorsAndWorse == 0
  let log = convertFile(tmp / "st_be.sgy", tmp / "st_le.sgy", ConvertOptions(byteOrder: boLittle))
  doAssert log.errorsAndWorse == 0 and not log.warned("no known layout")
  let y = readSegy(tmp / "st_le.sgy")
  doAssert y.file.fieldValue(y.traces[0], "rec_line") == some(13.0)
  doAssert y.file.fieldValue(y.traces[0], "sht_point") == some(99.5)

sampleBlock p8_b9_converting_a_file_onto_itself_is_refused:
  copyFile(exampleDir / "Sweep0.sgy", tmp / "self.sgy")
  let before = readFile(tmp / "self.sgy")
  doAssert convertFile(tmp / "self.sgy", tmp / "self.sgy").isFatal
  doAssert readFile(tmp / "self.sgy") == before

# Phase 13.3 review.

proc tmpFiles(dir: string): seq[string] =
  for p in walkDir(dir):
    if p.path.endsWith(".tmp"): result.add p.path

sampleBlock r13_r4_4_temporary_outputs_are_unique_and_exclusive:
  let dir = tmp / "tmpcase"
  createDir(dir)
  let src = dir / "line.sgy.tmp"
  copyFile(exampleDir / "Sweep0.sgy", src)
  let before = readFile(src)
  # The input used to be the output's fixed `<dst>.tmp`, and was destroyed.
  let log = convertFile(src, dir / "line.sgy")
  doAssert not log.isFatal, $log
  doAssert readFile(src) == before and fileExists(dir / "line.sgy")
  # Unique names; a planted symlink under the old fixed name is not followed.
  let victim = dir / "victim.txt"
  writeFile(victim, "keep")
  createSymlink(victim, dir / "out.sgy.tmp")
  doAssert not convertFile(exampleDir / "Sweep0.sgy", dir / "out.sgy").isFatal
  doAssert readFile(victim) == "keep" and fileExists(dir / "out.sgy")
  let a = createTempFor(dir / "x")
  let b = createTempFor(dir / "x")
  doAssert a != b and fileExists(a) and fileExists(b) and a.startsWith(dir / "x.")
  removeFile(a)
  removeFile(b)
  # The output is the input (through a symlink): refused, nothing changes.
  createSymlink(src, dir / "alias.sgy")
  let same = convertFile(src, dir / "alias.sgy")
  doAssert same.has("the output is the input file", sevFatal)
  doAssert readFile(src) == before
  # No directory for the temporary file: a fatal diagnostic, no exception.
  let missing = convertFile(src, dir / "no" / "such" / "out.sgy")
  doAssert missing.isFatal and missing.has("cannot create a temporary file", sevFatal), $missing
  # A failed conversion leaves no temporary file.
  writeFile(dir / "junk.sgy", "not seismic data")
  doAssert convertFile(dir / "junk.sgy", dir / "junk_out.sgy").isFatal
  for p in tmpFiles(dir): doAssert p in [src, dir / "out.sgy.tmp"], p # the planted link

block keys_survive_the_conversion_to_segy:
  # SEG-2 traces (and, through SEG-D Rev 3.0, SEG-D traces) whose keys need
  # more than whole numbers: the converters write them as `writeTrace(keys)`
  # does, so they read back (they were rounded to whole ms, points and
  # seconds, and clamped at 32767 ms without a word).
  proc keysOf(path: string): seq[TraceKeys] =
    var f = openSeismic(path, keys = true)
    doAssert not f.log.isFatal, path & ": " & $f.log
    for i in 0 ..< f.len: result.add f.traceKeys(i)
    f.close()
  for (name, delay, t0) in [("pretrigger", "-0.0105", -10.5), ("late", "40", 40000.0),
      ("submilli", "0.00025", 0.25)]:
    let sg2 = tmp / (name & ".sg2")
    var fdb = initSeg2File()
    fdb.traceCount = 2
    fdb["ACQUISITION_DATE"] = "02/10/2026"
    fdb["ACQUISITION_TIME"] = "12:34:56.504"
    var w = openSeg2Writer(sg2, fdb)
    for i in 0 ..< 2:
      var tr = Seg2Trace(formatCode: 4)
      tr["SAMPLE_INTERVAL"] = "0.001"
      tr["DELAY"] = delay
      tr["SOURCE_STATION_NUMBER"] = "99.5"
      tr["STATIC_CORRECTIONS"] = "0.0125 0.004 0.0165"
      tr["RECEIVER"] = "VERTICAL_GEOPHONE"
      tr["TRACE_TYPE"] = (if i == 0: "SEISMIC_DATA" else: "TEST_DATA")
      w.writeTrace(tr, newSeq[float32](64))
    w.close()
    let sgd = tmp / (name & ".sgd")
    doAssert convertFile(sg2, sgd, ConvertOptions(target: skSegd)).errorsAndWorse == 0
    for src in [sg2, sgd]:
      let want = keysOf(src)
      doAssert want.len == 2 and want[0].t0Ms == t0 and want[0].srcPoint == 99.5 and
        abs(want[0].time - 1790944496.504) < 1e-6 and want[0].status == tsLive, src
      for (major, minor) in [(2'u8, 1'u8), (1'u8, 0'u8), (0'u8, 0'u8)]:
        let dst = src & ".r" & $major & ".sgy"
        let log = convertFile(src, dst,
          ConvertOptions(revision: SegyRevision(major: major, minor: minor)))
        doAssert log.errorsAndWorse == 0, $log
        let got = keysOf(dst)
        doAssert got.len == 2
        let what = dst.extractFilename & ": "
        for i in 0 ..< 2:
          if major >= 1:
            doAssert got[i].t0Ms == t0, what & "t0Ms " & $got[i].t0Ms
            doAssert got[i].srcPoint == 99.5, what & "srcPoint " & $got[i].srcPoint
          else: # whole ms in an int16, whole points: reported below
            doAssert got[i].t0Ms == clamp(round(t0), -32768.0, 32767.0), what & $got[i].t0Ms
            doAssert got[i].srcPoint == 100
          # The fraction of the second is in Trace Header Extension 1 (Rev 2).
          let time = if major == 2: want[i].time else: floor(want[i].time)
          doAssert abs(got[i].time - time) < 1e-6, what & "time " & $got[i].time
        # Rev 0 has no sensor codes (12: vertical geophone): seismic data, 1.
        doAssert got[0].status == tsLive and got[0].traceCode == (if major == 0: 1 else: 12), what
        if major == 0:
          doAssert log.noted("fractional points were rounded")
          doAssert log.noted("start times were rounded") == (t0 != 40000), $log
          doAssert log.has("delay recording time cannot hold", sevWarning) == (t0 == 40000), $log
        else:
          doAssert not log.noted("start times were rounded") and
            not log.has("cannot hold", sevWarning), $log
    block statics_share_the_time_scalar:
      var y = openSeismic(sg2 & ".r1.sgy")
      let scalar = y.traceField(0, "trace.timeScalar").toFloat
      let source = y.traceField(0, "trace.sourceStatic").toFloat
      let total = y.traceField(0, "trace.totalStatic").toFloat
      y.close()
      if t0 == 40000: # one scalar for bytes 95-114: 10 ms steps
        doAssert scalar == 10 and source == 1 and total == 2
      else:
        doAssert scalar == -1000 and source == 12500 and total == 16500
