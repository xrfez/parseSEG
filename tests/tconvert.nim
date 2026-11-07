## Conversion between revisions and standards (task 8.6).

import std/[assertions, os, math, strutils]
import parseSEG/io/diskio
import parseSEG/segy/[reader as segyreader, fields]
import parseSEG/segd/[reader as segdreader, writer as segdwriter]
import parseSEG/convert
import parseSEG/model/[traceindex, headerfields]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_tconvert"
createDir(tmp)

proc errorsAndWorse(log: DiagLog): int = log.count(sevError) + log.count(sevFatal)

proc noted(log: DiagLog, text: string): bool =
  for e in log.items:
    if text in e.msg: return true

proc value(d: SegyData, i: int, name: string): float64 =
  doAssert d.file.fieldValue(d.traces[i], name, result), name

block segd_rev2_to_segy_rev21:
  let src = exampleDir / "63.sgd"
  let log = convertFile(src, tmp / "63.sgy")
  doAssert log.errorsAndWorse == 0, $log
  doAssert log.noted("extended/external headers are not carried")
  let d = readSegy(tmp / "63.sgy")
  doAssert d.diagnostics.errorsAndWorse == 0, $d.diagnostics
  doAssert d.file.revision == SegyRevision(major: 2, minor: 1) and d.file.format == sfFloat32
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
  doAssert t.header.energySourcePoint == 100 and t.header.shotpointScalar == -100
  doAssert t.header.shotpointNumber == 9950

block segd_rev3_to_segy_with_coordinates:
  let src = exampleDir / "inova_rev30_5traces.sgd"
  doAssert convertFile(src, tmp / "inova.sgy").errorsAndWorse == 0
  let d = readSegy(tmp / "inova.sgy")
  doAssert d.diagnostics.errorsAndWorse == 0, $d.diagnostics
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

block segd_to_segy_rev1_and_descale:
  let src = exampleDir / "63.sgd"
  let log = convertFile(src, tmp / "63r1.sgy", ConvertOptions(revision: SegyRevision(major: 1)))
  doAssert log.errorsAndWorse == 0 and log.noted("no field for SEG-D receiver/source line")
  let d = readSegy(tmp / "63r1.sgy")
  doAssert d.file.revision.major == 1 and not d.traces[0].hasExt1
  doAssert d.diagnostics.errorsAndWorse == 0
  doAssert d.file.text.card(39).strip == "C39 SEG Y REV1" and d.traces[0].header.fieldRecord == 63
  # Descaled: recorded value × 2^MP.
  let s = readSegd(src)
  let mp = s.records[0].record.scanTypes[0].descriptors[0].mpFactor
  doAssert convertFile(src, tmp / "63mv.sgy", ConvertOptions(applyDescale: true)).errorsAndWorse == 0
  let m = readSegy(tmp / "63mv.sgy")
  for j in 0..<1000:
    doAssert m.samples[0, j] == float32(float64(s.records[0].samples[0, j]) * pow(2.0, mp))

block lossless_format_choice:
  # An 8038 (int32) record converts to SEG-Y format 2, exactly.
  var d = readSegd(exampleDir / "63.sgd")
  var rd = d.records[0]
  rd.record.format = sd8038
  rd.record.gh1.formatCode = 8038
  var vals = newSeq[float64](1000)
  for j in 0..<1000: vals[j] = float64(j * 1001 - 500_000)
  rd.traces[0].samples = newSeq[byte](dataBytes(sd8038, 1000))
  encodeSegdSamples(sd8038, vals, rd.traces[0].samples)
  d.records[0] = rd
  let sink = openDiskSink(tmp / "i32.sgd")
  doAssert writeSegd(sink, d).len == 0
  sink.close()
  doAssert convertFile(tmp / "i32.sgd", tmp / "i32.sgy").errorsAndWorse == 0
  let y = readSegy(tmp / "i32.sgy")
  doAssert y.file.format == sfInt32
  var raw = newSeq[float64](1000)
  decodeSamples(sfInt32, y.traces[0].samples, raw)
  doAssert raw == vals
  # A forced format that cannot hold the values zeroes the trace, with an error.
  let log = convertFile(tmp / "i32.sgd", tmp / "i8.sgy",
    ConvertOptions(format: 8)) # int8
  doAssert log.count(sevError) == 1 and log.noted("do not fit")

block segy_revision_and_byte_order_changes:
  let ing = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"
  let a = readSegy(ing)
  # Rev 2.1 IBM → Rev 1 IEEE float: same values, extended text kept.
  var log = convertFile(ing, tmp / "ing_r1.sgy",
    ConvertOptions(revision: SegyRevision(major: 1), format: 5))
  doAssert log.errorsAndWorse == 0, $log
  let b = readSegy(tmp / "ing_r1.sgy")
  doAssert b.file.revision.major == 1 and b.file.format == sfFloat32
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

block invalid_targets_and_inputs:
  let sw = exampleDir / "Sweep0.sgy"
  for o in [ConvertOptions(revision: SegyRevision(major: 1), byteOrder: boLittle),
      ConvertOptions(revision: SegyRevision(major: 1), format: 6), # float64 needs Rev 2
      ConvertOptions(format: 4), ConvertOptions(format: 13),
      ConvertOptions(revision: SegyRevision(major: 3))]:
    doAssert convertFile(sw, tmp / "bad.sgy", o).isFatal
  doAssert convertFile(tmp / "missing", tmp / "x.sgy").isFatal
  writeFile(tmp / "junk", repeat('\0', 5000))
  doAssert convertFile(tmp / "junk", tmp / "x.sgy").isFatal
