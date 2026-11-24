## SEG-D Rev 3 header blocks and timestamps.

import std/[assertions, os, times, math, strutils]

import parseSEG/common/[years, leapseconds]
import parseSEG/segd/[headers, rev3, reader]

import parseSEG/io/[records, diskio]

import parseSEG/model/keys

import ./utils/testutils

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

proc main*() =
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

  block p8_b3_position_after_additional_source_info_is_the_source:
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

  block source_position_attaches_only_to_the_selected_description:
    proc pos(x, y: float64): SegdPositionBlock =
      SegdPositionBlock(position1Valid: 1, position1Quality: 1, tuple1Coord1: x,
        tuple1Coord2: y, tuple1Coord3: Inf, blockType1: 0x50, blockType2: 0x51,
        blockType3: 0x52)
    proc desc(line, point: float64, index: uint8): SegdSourceDescription =
      SegdSourceDescription(sourceLineNumber: line, sourcePointNumber: point,
        sourcePointIndex: index, blockType: 0x1F)
    var rec = SegdRecord(layout: slRev3)
    var t = SegdTrace(layout: slRev3, ext1Rev3: some(SegdTraceHeaderExt1Rev3()))
    t.extensions.add desc(1, 10, 1).encoded
    t.extensions.add desc(2, 20, 2).encoded
    t.extensions.add pos(999, 888).encoded
    let k = traceKeys(rec, t)
    doAssert k.srcLine == 1 and k.srcPoint == 10 and k.srcIndex == 1
    doAssert k.srcX.isNaN and k.srcY.isNaN and k.rcvX.isNaN
    # The position that follows the selected description is that source's.
    t.extensions.setLen 0
    t.extensions.add desc(1, 10, 1).encoded
    t.extensions.add pos(111, 222).encoded
    t.extensions.add desc(2, 20, 2).encoded
    t.extensions.add pos(999, 888).encoded
    let k2 = traceKeys(rec, t)
    doAssert k2.srcLine == 1 and k2.srcPoint == 10 and k2.srcX == 111 and k2.srcY == 222
    # Coordinates with no station (0/0) still read back: this writer emits that.
    t.extensions.setLen 0
    t.extensions.add desc(0, 0, 0).encoded
    t.extensions.add pos(50, 60).encoded
    let k3 = traceKeys(rec, t)
    doAssert k3.srcLine.isNaN and k3.srcX == 50 and k3.srcY == 60
    # Description only in the general header, position in the trace: the
    # position is the receiver's (a shot gather). Do not flip this.
    t.extensions.setLen 0
    t.extensions.add pos(111, 222).encoded
    rec.generalBlocks = @(desc(4, 8, 1).encoded)
    let k4 = traceKeys(rec, t)
    doAssert k4.srcLine == 4 and k4.srcPoint == 8
    doAssert k4.srcX.isNaN and k4.rcvX == 111 and k4.rcvY == 222

  block integer_leap_seconds:
    proc bits(x: float64): uint64 = cast[uint64](x)
    let samples = [
      0'i64, 1_123_456, 1'i64, -1_000_000'i64,
      1474994765504000'i64, 684035213123457'i64, 824035214123457'i64,
      914803212504000'i64, 914803213504000'i64, 914803215504000'i64, 914803216504000'i64,
      1167264015504000'i64, 1167264016504000'i64, 1167264018504000'i64, 1167264019504000'i64]
    let want = [
      4734080618437017600'u64, 4734080618455866064'u64, 4734080618437017617'u64,
      4734080618420240384'u64, 4745298636787696009'u64, 4741671816367426928'u64,
      4742568314554279608'u64, 4742949023132959113'u64, 4742949023137153417'u64,
      4742949023141347721'u64, 4742949023145542025'u64, 4744007920476242313'u64,
      4744007920480436617'u64, 4744007920484630921'u64, 4744007920488825225'u64]
    for i, ts in samples:
      let u = timestampToUnix(ts)
      doAssert bits(u) == want[i]
      doAssert unixToTimestamp(u) == ts
    doAssert unixToTimestamp(1230767999.504) == 914803213504000'i64
    doAssert unixToTimestamp(1483228800.504) == 1167264018504000'i64
    doAssert unixToTimestamp(1_000_000_000.123456789) == 684035213123457'i64
    doAssert gpsMinusUtc(1474994765504000'i64) == 18
    doAssert utcMinusGps(gpsUsToUtcUs(1474994765504000'i64)) == -18

    for us in [-1_000_001'i64, -1_000_000, -999_999, -1, 0, 1, 999_999, 1_000_000, 1_000_001]:
      doAssert gpsUsToUtcUs(utcUsToGpsUs(us)) == us
      doAssert utcUsToGpsUs(gpsUsToUtcUs(us)) == us

    # 4.8 h steps from mid-1972 through 2027. POSIX microseconds always
    # round-trip. A SEG-D timestamp in a leap second POSIX skips has no
    # image; those misses are exactly 1 s.
    var lo = high(int64)
    var hi = low(int64)
    var gaps = 0
    for i in -14_000 ..< 86_000:
      let step = int64(i) * 17_280_000_001
      doAssert gpsUsToUtcUs(utcUsToGpsUs(step)) == step
      let utc = gpsUsToUtcUs(step)
      let back = utcUsToGpsUs(utc)
      if back != step:
        doAssert abs(back - step) == 1_000_000
        inc gaps
      else:
        doAssert utcMinusGps(utc) == -gpsMinusUtc(step)
      if utc < lo: lo = utc
      if utc > hi: hi = utc
    doAssert gaps < 30
    doAssert lo <= daysFromCivil(1972, 6, 30) * 86_400 * 1_000_000
    doAssert hi >= daysFromCivil(2027, 1, 1) * 86_400 * 1_000_000

    proc atLeap(y, m, d, before, after: int) =
      let t = (daysFromCivil(y, m, d) + 1) * 86400
      for (us, off) in [(t * 1_000_000 - 1, before), (t * 1_000_000, after),
          (t * 1_000_000 + 1, after)]:
        doAssert utcMinusGps(us) == -off
        let gps = utcUsToGpsUs(us)
        doAssert gpsUsToUtcUs(gps) == us
        doAssert gpsMinusUtc(gps) == off
    atLeap(1972, 6, 30, -9, -8)
    atLeap(1979, 12, 31, -1, 0)
    atLeap(1981, 6, 30, 0, 1)
    atLeap(2008, 12, 31, 14, 15)
    atLeap(2016, 12, 31, 17, 18)

  block inserted_second_keeps_the_historical_float:
    # Historical rule, the old two-step expression: start from GPS seconds
    # plus the GPS epoch, then twice replace that with GPS seconds plus the
    # epoch minus the table's GPS−UTC at the floored POSIX second. Inside the
    # inserted second that is the POSIX second before the insertion plus the
    # fraction when the offset before it is negative, and the POSIX second the
    # insertion is folded into plus the fraction otherwise. Broken by taking
    # the offset from `gpsUsToUtcUs` (1972-06-30 was 78796800.0, not 78796799.0).
    proc offsetAt(unixSec: int64): int =
      let table = defaultLeapTable()
      result = table.entries[0].gpsMinusUtc
      for e in table.entries:
        if daysFromCivil(e.year, e.month, e.day) * 86400 <= unixSec:
          result = e.gpsMinusUtc
        else: break
    proc historical(ts: int64): float64 =
      let gpsSec = float64(ts) / 1e6
      result = gpsSec + float64(GpsEpochUnix)
      for _ in 0 .. 1:
        result = gpsSec + float64(GpsEpochUnix) -
          float64(offsetAt(int64(floor(result))))
    let table = defaultLeapTable()
    let firstIns = table.entries[1]
    let t1972 = daysFromCivil(firstIns.year, firstIns.month, firstIns.day) * 86400
    let start1972 = (t1972 - GpsEpochUnix + int64(table.entries[0].gpsMinusUtc)) * 1_000_000
    doAssert timestampToUnix(start1972) == 78796799.0
    for i in 1 ..< table.entries.len:
      let e = table.entries[i]
      let prev = table.entries[i - 1]
      let posix = daysFromCivil(e.year, e.month, e.day) * 86400
      let start = (posix - GpsEpochUnix + int64(prev.gpsMinusUtc)) * 1_000_000
      var us = start
      while us < start + 1_000_000:
        doAssert timestampToUnix(us) == historical(us)
        us += 100

  block integer_converters_saturate_at_int64_ends:
    # An input within one day of either int64 end is not supported. The
    # microsecond converters saturate to that end and raise nothing. Broken
    # by converting it: `sec * 1_000_000 + sub` overflowed.
    const day = 86_400_000_000'i64
    doAssert gpsUsToUtcUs(high(int64)) == high(int64)
    doAssert gpsUsToUtcUs(high(int64) - day + 1) == high(int64)
    doAssert gpsUsToUtcUs(low(int64)) == low(int64)
    doAssert gpsUsToUtcUs(low(int64) + day - 1) == low(int64)
    doAssert utcUsToGpsUs(high(int64)) == high(int64)
    doAssert utcUsToGpsUs(high(int64) - day + 1) == high(int64)
    doAssert utcUsToGpsUs(low(int64)) == low(int64)
    doAssert utcUsToGpsUs(low(int64) + day - 1) == low(int64)
    doAssert gpsUsToUtcUs(high(int64) - day - 1) == high(int64)
    doAssert utcUsToGpsUs(low(int64) + day + 1) == low(int64)
    doAssert gpsMinusUtc(high(int64)) == 18
    doAssert utcMinusGps(low(int64)) == 9

when isMainModule: main()
