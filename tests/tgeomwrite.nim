## Explicit write-back of joined survey geometry (task 10.5): `writeGeometry`
## through the journaled editor (and its rollback), `geometryChanges` /
## `geometryChanges` (nothing written), `copyWithGeometry` and
## `convertWithGeometry`. Synthetic SPS files and SEG-Y files built here,
## plus copies of the sample files (the originals are never written).

import std/[assertions, options, os, strutils, math]

import parseSEG

from parseSEG/model/traceindex import mindex # the tests corrupt the index

import parseSEG/survey/cards # column helpers (internal)

import ./utils/testutils

from parseSEG/private/coordscalar import chooseScalar

var tmp: typeof(getEnv("XDG_CACHE_HOME", getTempDir()) / "parseseg_tgeomwrite")

proc rec(first: char, fields: openArray[(int, string)]): string =
  result = repeat(' ', 80)
  result[0] = first
  for (c, t) in fields: result.putCol(c, t)

proc r21(kind: char, line, point: string, index: char, e, n, z: string): string =
  ## An SPS 2.1 R or S record.
  rec(kind, [(2, line.align(10)), (12, point.align(10)), (24, $index & "G1"), (47, e.align(9)),
    (56, n.align(10)), (66, z.align(6)), (72, " 18213250")])

proc x21(record: int, srcLine, srcPoint: string, fromCh, toCh: int, rcvLine, fromR,
    toR: string): string =
  ## An SPS 2.1 X record (source index 1, receiver index 1, increment 1).
  rec('X', [(2, "T1"), (8, align($record, 8)), (16, "1"), (17, "1"), (18, srcLine.align(10)),
    (28, srcPoint.align(10)), (38, "1"), (39, align($fromCh, 5)), (44, align($toCh, 5)),
    (49, "1"), (50, rcvLine.align(10)), (60, fromR.align(10)), (70, toR.align(10)),
    (80, "1")])

const H00 = "H00 SPS format version number   SPS 2.1;"

proc sps(name: string, lines: varargs[string]): SurveyGeometry =
  let path = tmp / name
  writeFile(path, (@[H00] & @lines).join("\n") & "\n")
  result.addSps(path)
  doAssert not result.log.hasErrors, $result.log.len

proc hdr(code, description, data: string): string =
  ## An SPS H record: code in cols 2-4, description in 5-32, data from 33.
  "H" & code.alignLeft(3) & description.alignLeft(28) & data

proc bytesOf(path: string): string = readFile(path)

proc copySample(name: string): string =
  result = tmp / name
  copyFile(exampleDir / name, result)

proc segyFile(path: string, rev = 1, traces = 4, espnum = 0'i32) =
  ## A small SEG-Y file: field record 10, channels 1..n, no coordinates.
  var f = SegyFile(text: initTextHeader(teEbcdic), byteOrder: boBig, format: some(sfFloat32),
    revision: SegyRevision(major: uint8(rev)), extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: uint8(rev), samplesPerTrace: 10,
    sampleInterval: 1000, measurementSystem: 1)
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, f, initSegyWriteOptions(f, lenient = true))
  for i in 0..<traces:
    var t = SegyTrace(numSamples: 10, sampleInterval: 1000, samples: newSeq[byte](40))
    t.header = SegyTraceHeader(fieldRecord: 10, traceNumberInField: int32(i + 1),
      numSamples: 10, sampleInterval: 1000, energySourcePoint: espnum)
    w.writeTrace(t)
  w.close()
  sink.close()

proc posBlock(x, y: float64): SegdPositionBlock =
  SegdPositionBlock(position1Valid: 1, position1Quality: 1, tuple1Coord1: x,
    tuple1Coord2: y, tuple1Coord3: Inf, blockType1: 0x50, blockType2: 0x51,
    blockType3: 0x52)

proc srcDesc(line, point: float64, index: uint8): SegdSourceDescription =
  SegdSourceDescription(sourceLineNumber: line, sourcePointNumber: point,
    sourcePointIndex: index, blockType: 0x1F)

proc writeRev3(path: string, extensions: seq[byte]) =
  # One seismic trace whose header extensions are `extensions` (after THE#1).
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  let the = uint8(1 + extensions.len div SegdBlockSize)
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 2, julianDay: 61, hour: 6, minute: 7, second: 8,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3, revisionMinor: 0,
    extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: unixToTimestamp(1_700_000_000.0),
    blockType: BlockTypeGeneralHeader3)
  var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, endTime: 1000, numSamples: 1, descaleMultiplier: 1.0,
    channelsInSet: 1, samplingInterval: 1000, arrayForming: 1, traceHeaderExtensions: the,
    verticalStack: 1, blockType1: BlockTypeChannelSet1, blockType2: BlockTypeChannelSet2,
    blockType3: BlockTypeChannelSet3)
  for i in 0 ..< d.description.len: d.description[i] = ' '
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[d])]
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: the)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(receiverLineNumber: 100,
    receiverPointNumber: 200, receiverPointIndex: 1, numSamples: 1, sensorType: 1,
    depthIndex: 1, blockType: BlockTypeTraceHeaderExt1))
  t.extensions = extensions
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  let sink = openDiskSink(path)
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(r)
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.close()

proc positionCoords(f: SeismicFile): seq[(float64, float64)] =
  let e = f.traceEntry(0)
  let raw = f.copyBytes(e.offset, int(e.headerBytes))
  let start = SegdTraceHeaderSize + SegdBlockSize
  for at, bt in blocks(raw.toOpenArray(start, raw.len - 1)):
    if bt == 0x50 and at + 96 <= raw.len - start:
      let p = decodeBlock[SegdPositionBlock](raw.toOpenArray(start + at, start + at + 95))
      result.add (p.tuple1Coord1, p.tuple1Coord2)

when defined(linux):
  import std/posix

  var RLIMIT_FSIZE {.importc, header: "<sys/resource.h>".}: cint

  proc limitFileSize(bytes: int) =
    ## Writes past `bytes` into any file fail with EFBIG (SIGXFSZ ignored);
    ## a negative `bytes` lifts the limit.
    signal(SIGXFSZ, SIG_IGN)
    var lim: RLimit
    doAssert getrlimit(RLIMIT_FSIZE, lim) == 0
    lim.rlim_cur = if bytes < 0: lim.rlim_max else: bytes
    doAssert setrlimit(RLIMIT_FSIZE, lim) == 0

proc main*() =
  tmp = getEnv("XDG_CACHE_HOME", getTempDir()) / "parseseg_tgeomwrite"

  removeDir(tmp)

  createDir(tmp)

  let feet = [hdr("20", "Description of grid units", "feet;"),
    hdr("201", "Factor to meters", "0.3048006096;")]

  # A survey for record 10: one source, receivers 101..104 on line 10.
  let segySurvey = [
    r21('S', "20", "205", '1', "500000.5", "6000400.0", "10.0"),
    r21('R', "10", "101", '1', "500100.0", "6000000.0", "12.5"),
    r21('R', "10", "102", '1', "500125.0", "6000000.0", "12.6"),
    r21('R', "10", "103", '1', "500150.0", "6000000.0", "12.7"),
    r21('R', "10", "104", '1', "500175.0", "6000000.0", "12.8"),
    x21(10, "20", "205", 1, 4, "10", "101", "104")]

  block segy_in_place_scalar_journal_and_rollback:
    let path = tmp / "a.sgy"
    segyFile(path)
    let original = bytesOf(path)
    let g = sps("a.sps", segySurvey)
    var f = openSeismic(path, keys = true)
    doAssert f.applySurvey(g) == 4
    # A dry run writes nothing and reports what has no slot (Rev 1: no lines).
    var log: DiagLog
    let c = f.geometryChanges(GeometryFields(), log)
    doAssert c.traces == 4 and c.sourceXy == 4 and c.receiverXy == 4, $c
    doAssert c.sourceZ == 4 and c.receiverZ == 4 and c.midpoints == 4 and c.offsets == 4
    doAssert c.sourceStations == 4, "the source point goes to espnum and sp"
    doAssert c.receiverStations == 0 and c.unwritable == 8, $c # lines/points: no slot
    doAssert log.has("source station: the file's layout has no field", sevWarning)
    doAssert log.has("receiver station: the file's layout has no field", sevWarning)
    doAssert ($c).startsWith("4 traces"), $c
    doAssert bytesOf(path) == original
    # In place, journaled.
    var ed = openEditor(path)
    let w = ed.writeGeometry(f.index)
    doAssert w == c, $w
    ed.close()
    f.close()
    doAssert not ed.log.hasErrors
    let d = readSegy(path)
    let h = d.traces[2].header
    doAssert h.coordinateScalar == -100, "the midpoint 500075.25 needs two decimals"
    doAssert h.sourceX == 50000050 and h.groupX == 50015000 and h.cdpX == 50007525
    doAssert h.elevationScalar == -10 and h.coordinateUnits == 1
    doAssert h.receiverElevation == 127 and h.energySourcePoint == 205
    var k = openSeismic(path, keys = true)
    let k2 = k.traceKeys(2)
    doAssert k2.srcX == 500000.5 and k2.rcvX == 500150 and k2.rcvZ == 12.7
    doAssert abs(k2.offset - round(hypot(149.5, 400.0))) < 1e-9, $k2.offset # int4: rounded
    doAssert k2.cmpX == 500075.25 and k2.srcPoint == 205
    # Writing again changes nothing.
    doAssert k.applySurvey(g) == 4, "the lines and receiver points have no slot"
    let again = k.geometryChanges()
    doAssert again.traces == 0 and again.unwritable == 8, $again
    k.close()
    doAssert rollbackJournal(path, path & ".edits.nif").len == 0
    doAssert bytesOf(path) == original

  block segy_scalar_choice_overflow_and_precision:
    var exact: bool
    doAssert chooseScalar([12.0, 3.0], 0, exact) == 1 and exact
    doAssert chooseScalar([12.5, 3.0], -100, exact) == -100 and exact, "the file's own"
    doAssert chooseScalar([12.25], 1, exact) == -100 and exact
    doAssert chooseScalar([5e8], -10, exact) == 1 and exact, "5e9 does not fit"
    doAssert chooseScalar([123456.123456], 1, exact) == -10000 and not exact
    doAssert chooseScalar([3e10], 1, exact) == 100 and exact
    doAssert chooseScalar([3e14], 1, exact) == 0
    let path = tmp / "b.sgy"
    segyFile(path, traces = 2)
    let g = sps("b.sps", r21('R', "10", "101", '1', "123.12345", "1.0", ""),
      r21('R', "10", "102", '1', "3E14", "1.0", ""),
      x21(10, "20", "205", 1, 2, "10", "101", "102"))
    var f = openSeismic(path, keys = true)
    discard f.applySurvey(g)
    var ed = openEditor(path)
    let w = ed.writeGeometry(f.index, GeometryFields(stations: false))
    ed.close()
    f.close()
    doAssert w.receiverXy == 1 and w.unwritable == 2, $w # x and y of trace 1
    doAssert ed.log.has("too large for a 4-byte SEG-Y field", sevError)
    doAssert ed.log.has("receiver X/Y: rounded", sevWarning)
    let d = readSegy(path)
    doAssert d.traces[0].header.coordinateScalar == -10000
    doAssert d.traces[1].header.groupX == 0, "refused: left alone"

  sampleBlock segy_rev2_station_header_via_layout:
    # SEG-D 63.sgd converted to SEG-Y Rev 2.1 carries line/point in the
    # PSEGD001 header its Layout stanza describes, and its keys read them
    # (receiver 13 / 104). A join matches by those stations and never
    # replaces them, whatever the X record says of the channel (14 / 105).
    let segy = tmp / "63.sgy"
    doAssert not convertFile(exampleDir / "63.sgd", segy).isFatal
    let g = sps("c.sps", r21('R', "13", "104", '1', "500100.0", "6000000.0", "12.5"),
      r21('R', "14", "105", '1', "500200.0", "6000000.0", "12.5"),
      x21(63, "13", "99.5", 1, 1, "14", "105", "105"))
    block:
      var f = openSeismic(segy, keys = true)
      var stats: JoinStats
      doAssert f.applySurvey(g, stats, overwrite = true) == 1 and stats.matches[jmStations] == 1
      doAssert f.traceKeys(0).rcvLine == 13 and f.traceKeys(0).rcvPoint == 104
      f.close()
      let dst = tmp / "63geo.sgy"
      let r = copyWithGeometry(segy, dst, g, overwrite = true)
      doAssert not r.log.hasErrors, $r.log.len
      doAssert r.changes.receiverStations == 0 and r.changes.receiverXy == 1, $r.changes
      let d = readSegy(dst)
      doAssert d.file.fieldValue(d.traces[0], "rec_line") == some(13.0)
      doAssert d.file.fieldValue(d.traces[0], "rec_point") == some(104.0)
    block:
      # A header without its receiver station (cleared in the keys) gets the
      # one the X record gives via the source station, written through the
      # fields the Layout stanza names.
      let path = tmp / "63b.sgy"
      copyFile(segy, path)
      var f = openSeismic(path, keys = true)
      (f.mindex.keys[0].rcvLine, f.mindex.keys[0].rcvPoint) = (NaN, NaN)
      doAssert f.applySurvey(g, overwrite = true) == 1
      var ed = openEditor(path)
      let w = ed.writeGeometry(f.index)
      ed.close()
      f.close()
      doAssert w.receiverStations == 1, $w
      let d = readSegy(path)
      doAssert d.file.fieldValue(d.traces[0], "rec_line") == some(14.0)
      doAssert d.file.fieldValue(d.traces[0], "rec_point") == some(105.0)

  sampleBlock segd_rev2_the1_in_place:
    # As above: a header without its receiver station (cleared in the keys)
    # gets the one the X record gives via the source station.
    let path = copySample("63.sgd")
    let original = bytesOf(path)
    let g = sps("d.sps", r21('R', "14", "105.5", '1', "500100.0", "6000000.0", "12.5"),
      x21(63, "13", "99.5", 1, 1, "14", "105.5", "105.5"))
    var f = openSeismic(path, keys = true)
    (f.mindex.keys[0].rcvLine, f.mindex.keys[0].rcvPoint) = (NaN, NaN)
    doAssert f.applySurvey(g, overwrite = true) == 1
    var ed = openEditor(path)
    let w = ed.writeGeometry(f.index)
    ed.close()
    f.close()
    doAssert w.receiverStations == 1 and w.receiverXy == 0, $w
    doAssert ed.log.has("receiver X/Y: SEG-D Rev 1/2 trace headers have no coordinate fields",
      sevWarning)
    var k = openSeismic(path, keys = true)
    doAssert k.traceKeys(0).rcvLine == 14 and k.traceKeys(0).rcvPoint == 105.5
    doAssert k.traceField(0, "ext1.receiverPointNumber").intVal == -1, "the extended field"
    k.close()
    doAssert rollbackJournal(path, path & ".edits.nif").len == 0
    doAssert bytesOf(path) == original

  sampleBlock segd_rev3_position_blocks:
    # The INOVA traces 3 and 4 carry receiver Position blocks (100/101, 100/102);
    # the source position is record-level (general headers).
    let path = copySample("inova_rev30_5traces.sgd")
    let original = bytesOf(path)
    var g = initSurveyGeometry()
    g.addReceiver(100, 101, 1, 1826000.5, 446000.25, 1000.0)
    g.addReceiver(100, 102, 1, 1826100.5, 446000.25, 1001.0)
    g.addSource(129, 113, 0, 1834000.0, 445000.0)
    var f = openSeismic(path, keys = true)
    doAssert f.applySurvey(g, overwrite = true) == 2, "the 3 auxiliary traces are left alone"
    let c = f.geometryChanges()
    doAssert c.receiverXy == 2 and c.receiverZ == 2, $c
    doAssert c.sourceXy == 0 and c.unwritable > 0
    var ed = openEditor(path)
    doAssert ed.writeGeometry(f.index) == c
    ed.close()
    f.close()
    doAssert ed.log.has("source X/Y: the trace has no source Position block", sevWarning)
    var k = openSeismic(path, keys = true)
    let k3 = k.traceKeys(3)
    doAssert k3.rcvX == 1826000.5 and k3.rcvY == 446000.25 and k3.rcvZ == 1000
    doAssert k.traceKeys(4).rcvX == 1826100.5
    doAssert not k.log.hasErrors
    k.close()
    doAssert rollbackJournal(path, path & ".edits.nif").len == 0
    doAssert bytesOf(path) == original

  sampleBlock convert_with_geometry_from_segd:
    let g = sps("e.sps", r21('R', "13", "104", '1', "500100.0", "6000000.0", "12.5"),
      r21('S', "13", "99.5", '1', "500000.0", "6000400.0", "10.0"))
    let dst = tmp / "63conv.sgy"
    let log = convertWithGeometry(exampleDir / "63.sgd", dst, g)
    doAssert not log.isFatal
    var k = openSeismic(dst, keys = true)
    doAssert k.traceKeys(0).rcvX == 500100 and k.traceKeys(0).srcY == 6000400
    doAssert abs(k.traceKeys(0).offset - hypot(100.0, 400.0)) < 1
    k.close()
    # Only the selected values: no receiver coordinates.
    let dst2 = tmp / "63conv2.sgy"
    doAssert not convertWithGeometry(exampleDir / "63.sgd", dst2, g,
      fields = GeometryFields(receiverXy: false)).isFatal
    var k2 = openSeismic(dst2, keys = true)
    doAssert k2.traceKeys(0).rcvX.isNaN and k2.traceKeys(0).srcX == 500000
    k2.close()
    doAssert readSegy(dst).file.binary.measurementSystem == 1 # no grid unit: metres
    # A survey in feet: the converted file's binary header says feet.
    let gf = sps("ef.sps", @feet & @[r21('R', "13", "104", '1', "500100.0", "6000000.0", "12.5")])
    let dst3 = tmp / "63convft.sgy"
    doAssert not convertWithGeometry(exampleDir / "63.sgd", dst3, gf).isFatal
    doAssert readSegy(dst3).file.binary.measurementSystem == 2

  block convert_with_geometry_from_segy:
    let path = tmp / "f.sgy"
    segyFile(path, rev = 1)
    let g = sps("f.sps", segySurvey)
    let dst = tmp / "fconv.sgy"
    let log = convertWithGeometry(path, dst, g)
    doAssert not log.isFatal and log.has("geometry written: 4 traces", sevInfo)
    var k = openSeismic(dst, keys = true)
    doAssert k.traceKeys(3).rcvX == 500175 and k.traceKeys(3).srcX == 500000.5
    k.close()
    doAssert not fileExists(dst & ".tmp") and not fileExists(dst & ".tmp.geometry.nif")

  block grid_units_reach_the_segy_binary_header:
    # An SPS survey in US survey feet: a copy or a conversion with its geometry
    # says so in the SEG-Y binary header (3255-3256: 2 = feet); a survey in
    # metres leaves the input's 1. Coordinates are never rescaled.
    let path = tmp / "u.sgy"
    segyFile(path) # measurement system 1
    let g = sps("u.sps", @feet & @segySurvey)
    doAssert g.gridUnit.name == "feet" and g.gridUnit.metres == 0.3048006096
    doAssert g.gridUnit.measurementSystem == 2
    let r = copyWithGeometry(path, tmp / "ucopy.sgy", g)
    doAssert not r.log.hasErrors and r.log.has("binary measurement system 1 -> 2", sevInfo)
    doAssert readSegy(tmp / "ucopy.sgy").file.binary.measurementSystem == 2
    var k = openSeismic(tmp / "ucopy.sgy", keys = true)
    doAssert k.traceKeys(3).rcvX == 500175 # as the survey gives it, in feet
    k.close()
    doAssert not convertWithGeometry(path, tmp / "uconv.sgy", g).isFatal
    doAssert readSegy(tmp / "uconv.sgy").file.binary.measurementSystem == 2
    let m = sps("um.sps", @[hdr("20", "Description of grid units", "Metres;"),
      hdr("201", "Factor to meters", "1.00000000;")] & @segySurvey)
    let rm = copyWithGeometry(path, tmp / "umcopy.sgy", m)
    doAssert not rm.log.has("binary measurement system", sevInfo)
    doAssert readSegy(tmp / "umcopy.sgy").file.binary.measurementSystem == 1

  block point_code_warnings_reach_the_returned_log_once:
    # Break: drop `log.add g.pointCodeWarnings` from writeInPlace
    # (writeback.nim): the copy's log, the only one a caller of
    # copyWithGeometry reads, then says nothing of the G1/G2 station. Drop
    # the SEG-D branch's add in convertWithGeometry: the same for SEG-D input.
    proc warnings(log: DiagLog): int =
      for d in log:
        if d.severity == sevWarning and "has several point codes" in d.msg: inc result
    let path = tmp / "pc.sgy"
    segyFile(path)
    var g2 = r21('R', "10", "104", '1', "500999.0", "6000999.0", "12.8")
    g2[25] = '2' # point code G2 beside the survey's G1 at 10/104/1
    let g = sps("pc.sps", @segySurvey & @[g2])
    doAssert g.pointCodeWarnings.len == 1 and not g.log.has("point codes", sevWarning)
    let r = copyWithGeometry(path, tmp / "pccopy.sgy", g)
    doAssert not r.log.hasErrors and r.log.warnings == 1, $r.log.warnings
    let c = convertWithGeometry(path, tmp / "pcconv.sgy", g)
    doAssert not c.hasErrors and c.warnings == 1, $c.warnings
    let segd = tmp / "pc.sgd"
    writeRev3(segd, @[])
    let d = convertWithGeometry(segd, tmp / "pcsegd.sgy", g)
    doAssert not d.isFatal and d.warnings == 1, $d.warnings

  block values_that_round_to_the_bytes_there_are_no_change:
    # Shotpoint 99.5 into a 4-byte espnum that already holds 100: the planned
    # bytes equal the file's, so nothing changes (it used to count as a write
    # the journal had dropped, a fatal error).
    let path = tmp / "r.sgy"
    segyFile(path, rev = 0, traces = 1, espnum = 100) # Rev 0: no scaled shotpoint field
    let g = sps("r.sps", r21('S', "20", "99.5", '1', "500000.0", "6000400.0", "10.0"),
      r21('R', "10", "101", '1', "500100.0", "6000000.0", "12.5"),
      x21(10, "20", "99.5", 1, 1, "10", "101", "101"))
    let r = copyWithGeometry(path, tmp / "r2.sgy", g, GeometryFields(sourceXy: false,
      receiverXy: false, elevations: false, midpoints: false, offsets: false))
    doAssert not r.log.isFatal and not r.log.hasErrors, $r.log.len
    doAssert r.changes.traces == 0 and r.changes.sourceStations == 0, $r.changes
    doAssert not r.log.has("rounded", sevWarning), "nothing was written, so nothing was rounded"
    var f = openSeismic(path, keys = true)
    doAssert f.applySurvey(g) == 1
    doAssert f.geometryChanges(GeometryFields(sourceXy: false, receiverXy: false,
      elevations: false, midpoints: false, offsets: false)).traces == 0
    f.close()

  block counts_and_rounding_describe_what_was_written:
    # The source point 99.5 beside coordinates that do change. Per kind, a
    # value counts when the header holds another value afterwards, and
    # "rounded" is reported only when no field of the point holds it exactly.
    let g = sps("n.sps", r21('S', "20", "99.5", '1', "500000.0", "6000400.0", "10.0"),
      r21('R', "10", "101", '1', "500100.25", "6000000.75", "12.5"),
      x21(10, "20", "99.5", 1, 1, "10", "101", "101"))
    proc written(rev: int, espnum: int32): (GeometryChanges, DiagLog) =
      let path = tmp / ("n" & $rev & "_" & $espnum & ".sgy")
      segyFile(path, rev = rev, traces = 1, espnum = espnum)
      var f = openSeismic(path, keys = true)
      doAssert f.applySurvey(g) == 1
      var log: DiagLog
      let plan = f.geometryChanges(GeometryFields(), log)
      var ed = openEditor(move f)
      result = (ed.writeGeometry(), ed.log)
      ed.close()
      doAssert result[0] == plan and not result[1].hasErrors, $result[0]
      doAssert log.has("source station: rounded", sevWarning) ==
        result[1].has("source station: rounded", sevWarning)
    # Rev 0 has espnum only, and it holds 100 already: the coordinates are
    # written, the source station is not, and nothing was rounded.
    var (c, log) = written(0, 100)
    doAssert c.traces == 1 and c.sourceXy == 1 and c.receiverXy == 1 and c.sourceStations == 0, $c
    doAssert not log.has("source station: rounded", sevWarning), $log
    # Rev 0, espnum unset: 100 is written for 99.5, the only field there is.
    (c, log) = written(0, 0)
    doAssert c.sourceStations == 1 and
      log.has("source station: rounded to what the field holds in 1 traces", sevWarning), $log
    # Rev 1 has the scaled shotpoint too: espnum takes 100, sp holds 99.5.
    (c, log) = written(1, 0)
    doAssert c.sourceStations == 1 and not log.has("source station: rounded", sevWarning), $log
    # Rev 1 with espnum 100 already: only sp changes (0 to 99.5).
    (c, log) = written(1, 100)
    doAssert c.sourceStations == 1 and not log.has("source station: rounded", sevWarning), $log
    # Receiver X and Y both round at the finest scalar: one trace, not two.
    let fine = sps("n2.sps", r21('R', "10", "101", '1', "123.12345", "7.54321", ""),
      x21(10, "20", "205", 1, 1, "10", "101", "101"))
    let path = tmp / "n2.sgy"
    segyFile(path, traces = 1)
    var f = openSeismic(path, keys = true)
    discard f.applySurvey(fine)
    var flog: DiagLog
    doAssert f.geometryChanges(GeometryFields(stations: false), flog).receiverXy == 1
    doAssert flog.has("receiver X/Y: rounded to what the field holds in 1 traces", sevWarning), $flog
    f.close()

  block refusals:
    let path = tmp / "g.sgy"
    segyFile(path)
    var f = openSeismic(path)
    doAssertRaises ValueError: discard f.geometryChanges() # no keys
    var ed = openEditor(path)
    doAssertRaises ValueError: discard ed.writeGeometry(f.index) # no keys
    ed.close()
    f.close()
    doAssert copyWithGeometry(path, path, initSurveyGeometry()).log.isFatal
    doAssert copyWithGeometry(tmp / "missing.sgy", tmp / "x.sgy", initSurveyGeometry()).log.isFatal

  block segy_in_place_from_the_open_file:
    # 14.3c: the editor takes over the joined file; its keys are the joined
    # ones (no second walk, which would read the file's empty coordinates).
    let path = tmp / "h.sgy"
    segyFile(path)
    let original = bytesOf(path)
    var f = openSeismic(path, keys = true)
    doAssert f.applySurvey(sps("h.sps", segySurvey)) == 4
    let plan = f.geometryChanges()
    var ed = openEditor(move f)
    doAssert ed.file.hasKeys and ed.file.index.keys[2].rcvX == 500150
    let w = ed.writeGeometry()
    doAssert w == plan and w.traces == 4, $w
    ed.close()
    doAssert not ed.log.hasErrors
    doAssert readSegy(path).traces[2].header.groupX == 50015000
    doAssert rollbackJournal(path, path & ".edits.nif").len == 0
    doAssert bytesOf(path) == original
    # An editor without keys refuses.
    var e = openEditor(openSeismic(path), tmp / "h.nif")
    doAssertRaises ValueError: discard e.writeGeometry()
    e.close()
    doAssert bytesOf(path) == original

  block position_after_a_later_description_is_not_the_source:
    # 0x1F 1/10, 0x1F 2/20, then a position: a join / write-back does not write
    # source XY into it. A receiver position ahead of those descriptions is
    # written, and what is written reads back.
    # Seen to fail first: positionBlocks attached any following position
    # (source X/Y was written into 999/888; the block read back 5000/6000).
    let path = tmp / "later_pos.sgd"
    var ext = newSeq[byte]()
    ext.add posBlock(111, 222).encoded
    ext.add srcDesc(1, 10, 1).encoded
    ext.add srcDesc(2, 20, 2).encoded
    ext.add posBlock(999, 888).encoded
    writeRev3(path, ext)
    var f = openSeismic(path, keys = true)
    doAssert f.traceKeys(0).srcLine == 1 and f.traceKeys(0).srcPoint == 10
    doAssert f.traceKeys(0).srcX.isNaN and f.traceKeys(0).rcvX == 111
    var g: GeometryTable
    g.addSource(1, 10, 1, 5000, 6000)
    g.addReceiver(100, 200, 1, 7000, 8000)
    doAssert f.applyGeometry(g, overwrite = true) == 1
    doAssert f.traceKeys(0).srcX == 5000 and f.traceKeys(0).rcvX == 7000
    var ed = openEditor(move f, tmp / "later_pos.nif")
    let ch = ed.writeGeometry()
    doAssert ch.sourceXy == 0 and ch.receiverXy == 1, $ch
    doAssert ed.log.has("no source Position block", sevWarning), $ed.log
    ed.close()
    var o = openSeismic(path, keys = true)
    let coords = o.positionCoords
    doAssert coords.len == 2, $coords.len
    doAssert coords[0] == (7000.0, 8000.0), $coords[0]
    doAssert coords[1] == (999.0, 888.0), $coords[1]
    let k = o.traceKeys(0)
    doAssert k.rcvX == 7000 and k.rcvY == 8000, $k
    doAssert k.srcX.isNaN and k.srcY.isNaN and k.srcLine == 1 and k.srcPoint == 10, $k
    doAssert o.readTraces(0 .. 0)[0, 0] == 1'f32
    o.close()
    # The position that follows the description sourceFrom selects is written,
    # and reads back.
    let selected = tmp / "selected_pos.sgd"
    ext.setLen 0
    ext.add srcDesc(1, 10, 1).encoded
    ext.add posBlock(50, 60).encoded
    ext.add srcDesc(2, 20, 2).encoded
    writeRev3(selected, ext)
    var f2 = openSeismic(selected, keys = true)
    doAssert f2.traceKeys(0).srcX == 50
    var g2: GeometryTable
    g2.addSource(1, 10, 1, 5000, 6000)
    doAssert f2.applyGeometry(g2, overwrite = true) == 1
    var ed2 = openEditor(move f2, tmp / "selected_pos.nif")
    let ch2 = ed2.writeGeometry()
    doAssert ch2.sourceXy == 1, $ch2
    ed2.close()
    var o2 = openSeismic(selected, keys = true)
    doAssert o2.positionCoords == @[(5000.0, 6000.0)], $o2.positionCoords
    doAssert o2.traceKeys(0).srcX == 5000 and o2.traceKeys(0).srcY == 6000
    doAssert o2.traceKeys(0).srcLine == 1 and o2.traceKeys(0).srcPoint == 10
    o2.close()

  when defined(linux):
    block failed_journal_sync_is_not_counted:
      # 13.3 R1-5: when the batch's journal sync fails its edits are dropped,
      # and the changes must not count them (they did: "4 traces").
      let path = tmp / "sync.sgy"
      segyFile(path)
      let original = bytesOf(path)
      var f = openSeismic(path, keys = true)
      doAssert f.applySurvey(sps("sync.sps", segySurvey)) == 4
      var ed = openEditor(path)
      let session = getFileSize(path & ".edits.nif")
      limitFileSize(int(session) + 20)
      var w: GeometryChanges
      try:
        w = ed.writeGeometry(f.index)
      finally:
        limitFileSize(-1)
      doAssert w.traces == 0 and w.sourceXy == 0 and w.offsets == 0, $w
      doAssert ed.log.has("4 traces' geometry was not written", sevFatal), $ed.log
      ed.close()
      f.close()
      doAssert bytesOf(path) == original

when isMainModule: main()
