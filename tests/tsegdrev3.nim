## SEG-D Rev 3 header blocks and timestamps (task 5.1).

import std/[assertions, os, times, math, strutils]
import parseSEG/segd/[headers, rev3, reader]
import parseSEG/io/[records, diskio]

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
const bigFile = exampleDir / "00000151_12900_11300.sgd" # local only, not in git

proc checkNibbleTiling(fields: openArray[FieldSpec], blockBytes: int) =
  var owner = newSeq[string](2 * blockBytes)
  for f in fields:
    for n in f.firstNibble ..< f.firstNibble + f.nibbles:
      doAssert n < owner.len, f.name & " lies outside the block"
      doAssert owner[n] == "", f.name & " overlaps " & owner[n]
      owner[n] = f.name
  for i, o in owner:
    doAssert o != "", "nibble " & $i & " (byte " & $(i div 2 + 1) & ") is not covered"

block layouts_tile:
  checkNibbleTiling(segdGeneralHeader2Rev3Fields, 32)
  checkNibbleTiling(segdGeneralHeader3Fields, 32)
  checkNibbleTiling(segdChannelSetDescriptorRev3Fields, 96)
  checkNibbleTiling(segdTraceHeaderExt1Rev3Fields, 32)
  checkNibbleTiling(segdPositionBlockFields, 96)
  for fields in [fieldTable(SegdSourceDescription), fieldTable(SegdAdditionalSourceInfo),
      fieldTable(SegdSensorInfo), fieldTable(SegdTimestampHeader),
      fieldTable(SegdSensorCalibration), fieldTable(SegdTimeDrift),
      fieldTable(SegdOrientation), fieldTable(SegdTrailerDescription)]:
    checkNibbleTiling(fields, 32)

block timestamps:
  # The real record: GH#3 1474994765504000 µs GPS = 2026-10-02 16:45:47.504 UTC.
  let ts = 1474994765504000'i64
  let unix = timestampToUnix(ts)
  let t = fromUnixFloat(unix).utc
  doAssert t.year == 2026 and t.month == mOct and t.monthday == 2
  doAssert t.hour == 16 and t.minute == 45 and t.second == 47
  doAssert abs(unix - floor(unix) - 0.504) < 1e-6
  doAssert unixToTimestamp(unix) == ts
  doAssert gpsMinusUtc(ts) == 18
  doAssert timestampToUnix(0) == float64(GpsEpochUnix) # GPS = UTC at the epoch
  # Before 2017-01-01 GPS - UTC was 17 s; in 2008 it was 14 s (spec example).
  doAssert gpsMinusUtc(unixToTimestamp(dateTime(2016, mDec, 1, zone = utc()).toTime.toUnixFloat)) == 17
  doAssert gpsMinusUtc(unixToTimestamp(dateTime(2008, mMar, 1, zone = utc()).toTime.toUnixFloat)) == 14

block blocks_and_names:
  var area = newSeq[byte](96)
  area[31] = 0x11
  for i, c in "West Virginia": area[i] = byte(c)
  area[63] = 0xB3
  area[95] = 0x55
  for i, c in "EPSG": area[64 + i] = byte(c)
  var seen: seq[uint8]
  for (i, t) in blocks(area): seen.add t
  doAssert seen == @[0x11'u8, 0xB3, 0x55]
  doAssert blockTypeName(0x11) == "surveyArea" and blockTypeName(0xB3) == "userDefined"
  doAssert blockTypeName(0x1A) == "additionalSourceInfo" and not isDefinedBlock(0x99)
  doAssert blockText(area.toOpenArray(0, 31)) == "West Virginia"
  doAssert findBlock(area, 0x55) == 64 and findBlock(area, 0x42) == -1
  doAssert crsText(area).len == 31

block real_rev3_headers:
  if not fileExists(bigFile):
    echo "  (skipped: ", bigFile, " is not present)"
  else:
    let s = readFile(bigFile)
    var b = newSeq[byte](4544)
    for i in 0..<b.len: b[i] = byte(s[i])
    let g1 = decodeBlock[SegdGeneralHeader1](b)
    doAssert g1.fileNumber == 151 and g1.formatCode == 8058 and g1.manufacturerCode == 50
    doAssert g1.year == 26 and g1.julianDay == 275 and g1.hour == 16 and g1.second == 47
    let g2 = decodeBlock[SegdGeneralHeader2Rev3](b.toOpenArray(32, 63))
    doAssert g2.revisionMajor == 3 and g2.revisionMinor == 0 and g2.blockType == 2
    doAssert g2.extRecordLength == 4_000_000 and g2.generalTrailerBlocks == 0
    doAssert generalHeaderCount(g1, g2) == 17 and baseScanIntervalUs(g1, g2) == 1000.0
    doAssert externalHeaderBlocks(g1, g2) == 113 and channelSetsPerScanType(g1, g2) == 4
    doAssert recordLengthUs(g1, g2) == 4_000_000.0
    let g3 = decodeBlock[SegdGeneralHeader3](b.toOpenArray(64, 95))
    doAssert g3.timeZero == 1474994765504000 and g3.headerSize == 4544
    doAssert g3.dataSize == 65057624 and g3.recordSize == 65057624
    # GH#1 time is the same instant in UTC, truncated to the second.
    doAssert generalHeaderUtc(g1) == floor(timestampToUnix(g3.timeZero))
    let ghArea = b[96 ..< 32 * 17]
    doAssert blockText(ghArea.toOpenArray(32, 63)) == "West Virginia"
    doAssert crsText(ghArea).len == 5 * 31
    let pos = decodeBlock[SegdPositionBlock](ghArea.toOpenArray(findBlock(ghArea, BlockTypePosition1),
      findBlock(ghArea, BlockTypePosition1) + 95))
    doAssert pos.blockType1 == 0x50 and pos.blockType2 == 0x51 and pos.blockType3 == 0x52
    let src = decodeBlock[SegdSourceDescription](ghArea.toOpenArray(13 * 32, 14 * 32 - 1))
    doAssert src.blockType == 0x16
    let cs4 = decodeBlock[SegdChannelSetDescriptorRev3](b.toOpenArray(544 + 3 * 96, 544 + 4 * 96 - 1))
    doAssert cs4.channelSetNumber == 4 and cs4.channelType == 0x10 and cs4.numSamples == 4001
    doAssert cs4.channelsInSet == 3954 and cs4.samplingInterval == 1000
    doAssert cs4.descaleMultiplier == 1000.0 and cs4.traceHeaderExtensions == 13
    doAssert cs4.physicalUnit == 4 and cs4.endTime == 4_000_000
    doAssert cs4.encoded == cs4.raw and g2.encoded == g2.raw and g3.encoded == g3.raw

block table_of_contents:
  var h = alignLeft("SEGD TOC FILE", 13) & alignLeft("SD3.0", 6) & alignLeft("TAPE7", 12)
  h.add alignLeft("ACME CLIENT", 32)
  while h.len < 438: h.add ' '
  h.add align("2", 10)
  doAssert h.len == 448
  var e1 = align("2", 8) & align("1", 7) & align("1474994765504000", 20) & align("151", 10) &
    align("-4.0512", 15) & align("0", 10) & alignLeft("L100", 24) & spaces(34)
  doAssert e1.len == 128
  var all = h & e1 & e1
  var b = newSeq[byte](all.len)
  for i, c in all: b[i] = byte(c)
  doAssert isTocFile(b) and tocEntryCount(b) == 2
  let t = decodeToc(b)
  doAssert t.revision == "SD3.0" and t.serialNumber == "TAPE7" and t.clientId == "ACME CLIENT"
  doAssert t.entries.len == 2 and t.entries[0].segdFileNumber == "151"
  doAssert t.entries[1].timeOfShot == "1474994765504000" and t.entries[0].lineId == "L100"

block real_rev3_reader:
  if not fileExists(bigFile):
    echo "  (skipped: ", bigFile, " is not present)"
  else:
    var src: RecordSource = openDiskSource(bigFile)
    var r = openSegd(src)
    doAssert r.nextRecord()
    let rec = r.record
    doAssert rec.isRev3 and rec.revision == SegdRevision(major: 3, minor: 0)
    doAssert rec.traceCount == 3957 and rec.generalBlocks.len == 14 * 32
    doAssert rec.external.len == 113 * 32 and rec.scanTypes[0].descriptorsRev3.len == 4
    var t: SegdTrace
    var n = 0
    var order: seq[int]
    var userBlocks = 0
    var t0 = newTraceTensor[float32](1, 4001)
    while r.readTrace(t):
      if order.len == 0 or order[^1] != t.channelSet: order.add t.channelSet
      doAssert t.ext1Rev3.isSome and t.numSamples == 4001 and t.extensions.len == 12 * 32
      for (i, bt) in blocks(t.extensions):
        if isUserBlock(bt): inc userBlocks
      if t.offset == 53864: # the first seismic trace
        doAssert t.ext1Rev3.get.receiverLine == 100.0 and t.ext1Rev3.get.receiverPoint == 101.0
        doAssert t.ext1Rev3.get.receiverLineNumber == -1 # FFFFFF sentinel
        rec.decodeInto(t, t0, 0)
        doAssert t0[0, 0] == 9.369352937937947e-07'f32 and t0[0, 3] == 1.7749355265550548e-06'f32
      inc n
    doAssert n == 3957 and order == @[0, 2, 1, 3] # CS1, CS3, CS2, CS4
    doAssert t.offset == 65041184 and t.ext1Rev3.get.receiverPoint == 225.0
    doAssert userBlocks == 9 * 3957 # INOVA blocks 0xB0-0xB8 on every trace
    doAssert r.log.len == 0, $r.log[0]
    doAssert not r.nextRecord()
    src.close()

block rev31_crs_text_format:
  doAssert crsFormat("((OGP:P1/11 CRS))\nOGP,OGP P1,1,1.1") == ctP1_11
  doAssert crsFormat("  ((ogp : p1/11crs))") == ctP1_11
  doAssert crsFormat("((SEG: Location Data ver 1.0))") == ctStanza
  doAssert crsFormat("\0\0  ") == ctNone and crsFormat("WGS 84") == ctUnknown

block source_description_accessors_follow_fields:
  # The type-specific accessors read the decoded fields, so an edit shows.
  var s = SegdSourceDescription(blockType: 0x15)
  s.typeSpecific15 = [1'u8, 2, 0xFF, 0xA6] # control 1, type 2, angle -90
  s.typeSpecific28 = [0xFF'u8, 0xFE]
  doAssert s.phaseControl == 1 and s.vibratorType == 2 and s.phaseAngle == -90
  doAssert s.size == 65534 # unsigned for a vibrator
  s.blockType = 0x16
  doAssert s.size == -2 and s.depth == 0x0102
  let back = decodeBlock[SegdSourceDescription](s.encoded)
  doAssert back.phaseAngle == -90 and back.depth == 0x0102
