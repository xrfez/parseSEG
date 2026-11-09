## SEG-D Rev 3 writer and round trips (tasks 5.3 and 5.4).

import std/[assertions, os, strutils, math]
import parseSEG/common/errors
import parseSEG/io/[records, diskio, tapeimage]
import parseSEG/segd/[reader, writer]
import ./utils/testutils

const bigFile = exampleDir / "00000151_12900_11300.sgd" # local only, not in git
let tmp = scratchDir("parseseg_tsegdrev3io")

proc toDisk(d: SegdData, path: string, opts = SegdWriteOptions()): DiagLog =
  let sink = openDiskSink(path)
  try: result = writeSegd(sink, d, opts)
  finally: sink.close()

proc toTape(d: SegdData, path: string, opts = SegdWriteOptions()): DiagLog =
  let sink = openTapeImageSink(path)
  try: result = writeSegd(sink, d, opts)
  finally: sink.close()

proc fromTape(path: string): SegdData =
  var src: RecordSource = openTapeImageSource(path)
  try: result = readSegd(src)
  finally: src.close()

proc blk(t: uint8, text = ""): seq[byte] =
  result = newSeq[byte](32)
  for i, c in text: result[i] = byte(c)
  result[31] = t

proc label(structure: string, blockSize: int64): SegdStorageUnitLabel =
  SegdStorageUnitLabel(storageUnitSeqNum: "1", revision: "SD3.0", structure: structure,
    bindingEdition: "B2", maxBlockSize: blockSize, creationDate: "07-NOV-2026",
    serialNumber: "T3", recordingEntityName: "CREW")

proc makeRev3Record(fileNo: int, format: SegdSampleFormat, ns = 40): SegdRecordData =
  var r = SegdRecord(layout: slRev3, format: some(format),
    revision: SegdRevision(major: 3, minor: 0))
  # Optional general header blocks: text, CRS, position (3 blocks), explosive
  # source, a user block.
  r.generalBlocks.add blk(0x11, "Synthetic Area")
  r.generalBlocks.add blk(0x55, "EPSG:32615")
  var pos = SegdPositionBlock(timeOfPosition: 1_000_000, tuple1Coord1: 512_345.5,
    tuple1Coord2: 4_123_456.25, blockType1: 0x50, blockType2: 0x51, blockType3: 0x52)
  r.generalBlocks.add @(pos.encoded)
  var src = SegdSourceDescription(extFileNumber: uint32(fileNo), sourceLineNumber: 1001.5,
    sourcePointNumber: 2002.25, sourcePointIndex: 1, blockType: 0x16)
  r.generalBlocks.add @(src.encoded)
  r.generalBlocks.add blk(0xB0, "vendor")
  let nOpt = r.generalBlocks.len div 32
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(format), year: 26,
    additionalGhBlocks: uint8(2 + nOpt), julianDay: 311, hour: 12, minute: 30,
    manufacturerCode: 50, baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 2, skewBlocks: 0,
    extendedHeaderBlocks: 1, externalHeaderBlocks: 2)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: uint32(fileNo), revisionMajor: 3,
    revisionMinor: (if format.isLittleEndian: 1'u8 else: 0'u8),
    extRecordLength: uint32(1000 * (ns - 1)), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
  var aux = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x20, endTime: int32(1000 * (ns - 1)), numSamples: uint32(ns),
    descaleMultiplier: 1.0, channelsInSet: 1, samplingInterval: 1000,
    traceHeaderExtensions: 1, verticalStack: 1, blockType1: 0x30, blockType2: 0x31,
    blockType3: 0x32)
  var seis = aux
  seis.channelSetNumber = 2
  seis.channelType = 0x10
  seis.channelsInSet = 3
  seis.traceHeaderExtensions = 4
  seis.descaleMultiplier = 1000.0
  for i, c in "GEOPHONES": seis.description[i] = c
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[aux, seis])]
  r.extended = blk(0, "extended")
  r.external = blk(0, "ext1") & blk(0, "ext2")
  # Trailer: a trace-edit description block and one ASCII data block.
  var d = SegdTrailerDescription(trailerBlockType: 1, asciiOrBinary: 2, blockSize: 1,
    blockType: 0x70)
  for i, c in "TRACE EDIT v1.0": d.description[i] = c
  r.trailerRev3 = @(d.encoded) & blk(0x20, "V 1.0\nT\n")
  var traces: seq[SegdTrace]
  # Physical order: the 3 seismic traces first, then the aux trace.
  for k in 0..<4:
    let isAux = k == 3
    var t = SegdTrace(layout: slRev3, index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: fileNo, scanTypeNumber: 1,
      channelSetNumber: (if isAux: 1 else: 2), traceNumber: (if isAux: 1 else: k + 1),
      traceHeaderExtensions: (if isAux: 1'u8 else: 4'u8))
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: -1,
      receiverPointNumber: int32(100 + k),
      extReceiverLineNumber: 100.5, receiverPointIndex: 1, numSamples: uint32(ns),
      sensorType: (if isAux: 0'u8 else: 2'u8), blockType: 0x40)
    if not isAux:
      var p = pos
      p.tuple1Coord1 = 600_000.0 + float64(k)
      t.extensions = @(p.encoded)
    var vals = newSeq[float64](ns)
    for i in 0..<ns: vals[i] = float64((i mod 7) - 3) * (if format in {sd8036, sd8038, sd9036, sd9038}: 100.0 else: 0.25)
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSegdSamples(format, vals, t.samples)
    traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = 4
  result = SegdRecordData(record: r, traces: traces)

proc stream(formats: openArray[SegdSampleFormat]): SegdData =
  for i, f in formats: result.records.add makeRev3Record(200 + i, f)

proc same(a, b: SegdData) =
  doAssert a.records.len == b.records.len
  for i in 0..<a.records.len:
    let x = a.records[i].record
    let y = b.records[i].record
    doAssert y.isRev3 and x.gh2Rev3.encoded == y.gh2Rev3.encoded and x.gh3.encoded == y.gh3.encoded
    doAssert x.generalBlocks == y.generalBlocks and x.trailerRev3 == y.trailerRev3
    doAssert x.extended == y.extended and x.external == y.external
    for k in 0..<a.records[i].traces.len:
      let s = a.records[i].traces[k]
      let t = b.records[i].traces[k]
      doAssert s.header.encoded == t.header.encoded and
        s.ext1Rev3.get.encoded == t.ext1Rev3.get.encoded
      doAssert s.extensions == t.extensions and s.samples == t.samples

block rev3_disk_round_trip_every_format:
  let d = stream(segdSampleFormats)
  let path = tmp / "rev3.sgd"
  doAssert d.toDisk(path).len == 0
  let e = readSegd(path)
  doAssert e.log.len == 0, $e.log[0]
  same(d, e)
  for rd in e.records:
    doAssert rd.traces[0].channelSet == 1 and rd.traces[3].channelSet == 0 # physical order kept
    doAssert rd.traces[0].ext1Rev3.get.receiverLine == 100.5
    let p = decodeBlock[SegdPositionBlock](rd.traces[2].extensions)
    doAssert p.tuple1Coord1 == 600_002.0
    doAssert blockText(rd.record.generalBlocks.toOpenArray(0, 31)) == "Synthetic Area"
    doAssert descriptionText(rd.record.scanTypes[0].descriptorsRev3[1]) == "GEOPHONES"
    doAssert rd.record.gh3.dataSize + 64 == rd.record.gh3.recordSize
  doAssert e.toDisk(tmp / "rev3b.sgd").len == 0
  doAssert readBytes(tmp / "rev3b.sgd") == readBytes(path)

block rev3_tape_record_and_fixrec:
  var d = stream([sd8058, sd8036])
  d.label = some label("RECORD", 0)
  discard d.toTape(tmp / "rev3.tap", SegdWriteOptions(tapeMarkPerRecord: true))
  let e = fromTape(tmp / "rev3.tap")
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.label.get.revision == "SD3.0"
  same(d, e)
  for bs in [4096'i64, 1000]:
    var f = d
    f.label = some label("FIXREC", bs)
    for (path, tape) in [(tmp / "rev3fix.tap", true), (tmp / "rev3fix.sgd", false)]:
      if tape: discard f.toTape(path) else: discard f.toDisk(path)
      let g = if tape: fromTape(path) else: readSegd(path)
      doAssert g.log.len == 0, $g.log[0]
      same(f, g)
      if not tape:
        doAssert readBytes(path).len mod bs == 0
        for rd in g.records:
          doAssert rd.record.offset mod bs == 0 and rd.traces[0].offset mod bs == 0

block rev3_trailer_count_unknown:
  for useSizes in [true, false]:
    var d = stream([sd8058])
    d.records[0].record.gh2Rev3.generalTrailerBlocks = 0xFFFF_FFFF'u32
    if not useSizes:
      d.records[0].record.gh3.recordSize = 0
    discard d.toDisk(tmp / "gtunknown.sgd")
    let e = readSegd(tmp / "gtunknown.sgd")
    doAssert e.log.len == 0, $e.log[0]
    doAssert e.records[0].record.trailerRev3 == d.records[0].record.trailerRev3

block rev3_writer_refusals:
  var a = stream([sd8058])
  a.records[0].record.gh3.headerSize += 32
  doAssertRaises SegFormatError: discard a.toDisk(tmp / "bad1.sgd")
  var b = stream([sd8058])
  b.records[0].record.gh3.dataSize += 1
  doAssertRaises SegFormatError: discard b.toDisk(tmp / "bad2.sgd")
  var c = stream([sd8058])
  c.records[0].record.scanTypes[0].descriptorsRev3[1].channelsInSet = 4
  doAssertRaises SegFormatError: discard c.toDisk(tmp / "bad3.sgd")
  var g = stream([sd8058])
  g.records[0].record.generalBlocks.setLen 32 * 3
  doAssertRaises SegFormatError: discard g.toDisk(tmp / "bad4.sgd")
  var h = stream([sd8058])
  h.records[0].traces[1].extensions.setLen 64 # header says 4 extensions
  doAssertRaises SegFormatError: discard h.toDisk(tmp / "bad5.sgd")
  var l = stream([sd8058])
  l.records[0].record.gh2Rev3.generalTrailerBlocks = 5
  doAssertRaises SegFormatError: discard l.toDisk(tmp / "bad6.sgd")

block rev3_toc_between_records:
  var d = stream([sd8058, sd8058])
  let path = tmp / "toc.sgd"
  discard d.toDisk(path)
  # Append a TOC file after the records, as on a disk copy of a tape.
  var toc = alignLeft("SEGD TOC FILE", 13) & alignLeft("SD3.0", 6) & alignLeft("T3", 12)
  while toc.len < 438: toc.add ' '
  toc.add align("1", 10)
  toc.add align("2", 8) & align("1", 7) & align("1474994765504000", 20) & align("200", 10) &
    spaces(15) & align("0", 10) & alignLeft("L1", 24) & spaces(34)
  let f = open(path, fmAppend)
  f.write toc
  f.close()
  let e = readSegd(path)
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.records.len == 2

block real_rev3_file_rewrites_byte_identically:
  if not fileExists(bigFile):
    echo "  (skipped: ", bigFile, " is not present)"
  else:
    let d = readSegd(bigFile)
    doAssert d.log.len == 0 and d.records[0].traces.len == 3957
    doAssert d.toDisk(tmp / "big.sgd").len == 0
    doAssert readBytes(tmp / "big.sgd") == readBytes(bigFile)
    removeFile(tmp / "big.sgd")

block committed_rev3_fixture:
  # 5 traces of the real INOVA Rev 3.0 record, all headers as recorded
  # (tools/make_rev3_fixture.nim): always available, unlike the 65 MB file.
  let fixture = exampleDir / "inova_rev30_5traces.sgd"
  let d = readSegd(fixture)
  doAssert d.log.len == 0, $d.log[0]
  let rd = d.records[0]
  let r = rd.record
  doAssert r.isRev3 and r.gh1.manufacturerCode == 50 and r.gh1.fileNumber == 151
  doAssert r.gh3.timeZero == 1474994765504000 and r.gh3.headerSize == 4544
  doAssert r.gh3.dataSize == 86744 and r.gh3.recordSize == 86744
  doAssert r.generalBlocks.len == 14 * 32 and r.external.len == 113 * 32
  doAssert blockText(r.generalBlocks.toOpenArray(32, 63)) == "West Virginia"
  doAssert rd.traces.len == 5
  var order: seq[int]
  for t in rd.traces: order.add t.channelSet
  doAssert order == @[0, 2, 1, 3, 3] # physical order as recorded: CS1, CS3, CS2, CS4, CS4
  doAssert rd.traces[3].offset == 53864 and rd.traces[3].ext1Rev3.get.receiverLine == 100.0
  doAssert rd.samples[3, 0] == 9.369352937937947e-07'f32
  for t in rd.traces:
    var user = 0
    for (i, bt) in blocks(t.extensions):
      if isUserBlock(bt): inc user
    doAssert user == 9 # INOVA blocks 0xB0-0xB8
  doAssert d.toDisk(tmp / "fixture.sgd").len == 0
  doAssert readBytes(tmp / "fixture.sgd") == readBytes(fixture)
  if fileExists(bigFile):
    # The fixture is the big file's first 86744 bytes but for the GH#3 sizes
    # and CS4's trace count.
    let big = readFile(bigFile)
    let fx = readBytes(fixture)
    var diff: seq[int]
    for i in 0..<fx.len:
      if byte(big[i]) != fx[i]: diff.add i
    doAssert diff == @[76, 77, 78, 79, 84, 85, 86, 87, 853, 854]

# --------------------------------------------- Phase 5 review regressions --

block r1_fixrec_gaps_below_a_header:
  # Every gap size 1..19 before a trace: block sizes around 320 bytes.
  for bs in 280'i64 .. 360:
    var d = stream([sd8058])
    d.label = some label("FIXREC", bs)
    for (path, tape) in [(tmp / "gap.sgd", false), (tmp / "gap.tap", true)]:
      if tape: discard d.toTape(path) else: discard d.toDisk(path)
      let e = if tape: fromTape(path) else: readSegd(path)
      doAssert e.log.len == 0, "block " & $bs & ": " & $e.log[0]
      same(d, e)

block r2_huge_trailer_sizes_are_not_a_defect:
  var b = readBytes(exampleDir / "inova_rev30_5traces.sgd")
  for i in 44..47: b[i] = 0xFF            # GH#2 bytes 13-16: trailer count unknown
  for i in 72..79: b[i] = 0xFF            # GH#3 recordSize
  for i in 80..86: b[i] = 0; b[87] = 1    # GH#3 dataSize = 1
  let f = open(tmp / "hugegt.sgd", fmWrite)
  discard f.writeBytes(b, 0, b.len)
  f.close()
  let e = readSegd(tmp / "hugegt.sgd")
  doAssert e.log.isFatal and e.records[0].traces.len == 5

block r3_extended_channel_set_numbers:
  var d = stream([sd8058])
  d.records[0].record.scanTypes[0].descriptorsRev3[1].channelSetNumber = 200
  for k in 0..2:
    d.records[0].traces[k].header.channelSetNumber = BcdAllF
    d.records[0].traces[k].header.extChannelSetNumber = 200
  doAssert d.toDisk(tmp / "cs200.sgd").len == 0
  let e = readSegd(tmp / "cs200.sgd")
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.records[0].traces[0].channelSet == 1

block r4_unknown_trailer_count_multi_record:
  var d = stream([sd8058, sd8058])
  d.records[0].record.gh2Rev3.generalTrailerBlocks = 0xFFFF_FFFF'u32
  d.records[0].record.gh3.recordSize = 0
  d.records[1].record.gh1.externalHeaderBlocks = 70 # GH#1 byte 32 = 0x70
  d.records[1].record.external = newSeq[byte](70 * 32)
  computeRev3Sizes(d.records[1].record, d.records[1].traces)
  doAssert d.toDisk(tmp / "gt70.sgd").len == 0
  let e = readSegd(tmp / "gt70.sgd")
  doAssert e.log.len == 0, $e.log[0]
  doAssert e.records.len == 2 and e.records[0].record.trailerRev3.len == 64
  # A trailer readers cannot walk is refused when nothing else sizes it.
  var g = stream([sd8058])
  g.records[0].record.gh2Rev3.generalTrailerBlocks = 0xFFFF_FFFF'u32
  g.records[0].record.gh3.recordSize = 0
  g.records[0].record.trailerRev3 = blk(0x20, "not a description block")
  doAssertRaises SegFormatError: discard g.toDisk(tmp / "gtbad.sgd")

block r5_large_areas_are_skipped_and_huge_traces_stop:
  let d = stream([sd8058])
  discard d.toDisk(tmp / "areas.sgd")
  var src: RecordSource = openDiskSource(tmp / "areas.sgd")
  var r = openSegd(src)
  r.maxHeaderBytes = 40 # the 64-byte external header and trailer are skipped
  doAssert r.nextRecord()
  var t: SegdTrace
  var n = 0
  while r.readTrace(t): inc n
  src.close()
  doAssert n == 4 and r.record.incomplete and r.record.external.len == 0
  doAssert not r.log.hasErrors
  var e = SegdData(records: @[SegdRecordData(record: r.record, traces: d.records[0].traces)])
  doAssertRaises SegFormatError: discard e.toDisk(tmp / "incomplete.sgd")
  src = openDiskSource(tmp / "areas.sgd")
  var r2 = openSegd(src)
  r2.maxTraceBytes = 100 # 40 samples x 4 bytes = 160
  doAssert r2.nextRecord()
  doAssert not r2.readTrace(t) and r2.log.isFatal
  src.close()

block r6_rev32_warns:
  # 3.1 is read as itself (task 5.5); a later minor revision warns.
  var d = stream([sd8058])
  d.records[0].record.gh2Rev3.revisionMinor = 1
  discard d.toDisk(tmp / "rev31.sgd")
  doAssert readSegd(tmp / "rev31.sgd").log.len == 0
  d.records[0].record.gh2Rev3.revisionMinor = 2
  discard d.toDisk(tmp / "rev32.sgd")
  let e = readSegd(tmp / "rev32.sgd")
  doAssert e.records[0].traces.len == 4
  doAssert e.log.len == 1 and e.log[0].code == dcUnsupportedRevision
  # A 90xx format in a record that says 3.0 is decoded, with a warning.
  var l = stream([sd9058])
  l.records[0].record.gh2Rev3.revisionMinor = 0
  discard l.toDisk(tmp / "rev30le.sgd", SegdWriteOptions(lenient: true))
  let le = readSegd(tmp / "rev30le.sgd")
  doAssert le.records[0].traces.len == 4 and le.log.count(sevWarning) == 1

block r7_minor_time_fields_checked:
  var g1 = SegdGeneralHeader1(year: 26, julianDay: 999, hour: 1)
  doAssert generalHeaderUtc(g1).isNaN
  g1.julianDay = 1
  g1.hour = 24
  doAssert generalHeaderUtc(g1).isNaN
