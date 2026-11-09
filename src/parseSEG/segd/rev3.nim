## SEG-D Rev 3.x header blocks (spec notes `segd_rev3_0_a.md` §3,
## `segd_rev3_0_b.md` §3, `segd_rev3_0_verified.md`).
##
## Rev 3 keeps General Header #1 and the 20-byte Demux Trace Header of
## Rev 2 (`headers.nim`), and changes General Header #2, adds General Header
## #3, a 96-byte Channel Set Descriptor and a new Trace Header Extension #1.
## Every other block is 32 bytes with its type in byte 32 and may appear in
## the general header, trace headers and trailer in any order; such blocks
## are kept raw (`Segd3Block`) and decoded on demand into the typed objects
## below. Like the Rev 2 blocks, typed blocks keep `raw` and re-encode only
## changed fields.

import std/[strutils, math]
import ../common/[endians, fieldlayout, years]
import ./headers

type
  SegdGeneralHeader2Rev3* = object
    ## General Header Block #2 (block type 0x02), Rev 3 layout.
    extFileNumber* {.at24(1).}: uint32
    extChannelSetsPerScanType* {.at: 4.}: uint16
    extExtendedHeaderBlocks* {.at24(6).}: uint32
    extSkewBlocks* {.at: 9.}: uint16
    revisionMajor* {.at: 11.}: uint8
    revisionMinor* {.at: 12.}: uint8
    generalTrailerBlocks* {.at: 13.}: uint32  ## 0xFFFFFFFF = unknown.
    extRecordLength* {.at: 17.}: uint32       ## µs.
    recordSetNumber* {.at: 21.}: uint16
    extAdditionalGhBlocks* {.at: 23.}: uint16 ## Used when GH#1 byte 12H = F.
    dominantSamplingInterval* {.at24(25).}: uint32 ## µs; used when GH#1 byte 23 = FF.
    extExternalHeaderBlocks* {.at24(28).}: uint32
    undef31* {.at: 31.}: uint8
    blockType* {.at: 32.}: uint8              ## 0x02.
    raw*: array[SegdBlockSize, byte]

  SegdGeneralHeader3* = object
    ## General Header Block #3 (0x03): time zero and sizes.
    timeZero* {.at: 1.}: int64                ## SEG-D timestamp (µs since the GPS epoch).
    recordSize* {.at: 9.}: uint64             ## 0 = unknown.
    dataSize* {.at: 17.}: uint64              ## Headers + traces; offset of the trailer.
    headerSize* {.at: 25.}: uint32            ## Offset of the first trace.
    extendedRecordingMode* {.at: 29.}: uint8
    relativeTimeMode* {.at: 30.}: uint8
    undef31* {.at: 31.}: uint8
    blockType* {.at: 32.}: uint8              ## 0x03.
    raw*: array[SegdBlockSize, byte]

  SegdChannelSetDescriptorRev3* = object
    ## Channel Set Descriptor, Rev 3 (96 bytes: block types 0x30, 0x31, 0x32).
    scanTypeNumber* {.bcdAt(1, 2).}: int
    channelSetNumber* {.at: 2.}: uint16
    channelType* {.at: 4.}: uint8             ## e.g. 0x10 seis, 0x20-0x70 auxiliary.
    startTime* {.at: 5.}: int32               ## µs.
    endTime* {.at: 9.}: int32                 ## µs.
    numSamples* {.at: 13.}: uint32
    descaleMultiplier* {.at: 17.}: float32    ## mV per unit (DSM).
    channelsInSet* {.at24(21).}: uint32       ## Traces in this set; 0 = unused.
    samplingInterval* {.at24(24).}: uint32    ## µs.
    arrayForming* {.at: 27.}: uint8
    traceHeaderExtensions* {.at: 28.}: uint8  ## Extension blocks per trace.
    extendedHeaderFlag* {.nibAt(29).}: uint8
    channelGainControl* {.nibAtL(29).}: uint8
    verticalStack* {.at: 30.}: uint8
    streamerNumber* {.at: 31.}: uint8
    blockType1* {.at: 32.}: uint8             ## 0x30.
    aliasFilterFreq* {.at: 33.}: float32      ## Hz.
    lowCutFilterFreq* {.at: 37.}: float32
    aliasFilterSlope* {.at: 41.}: float32     ## dB/octave.
    lowCutFilterSlope* {.at: 45.}: float32
    notch1Freq* {.at: 49.}: float32
    notch2Freq* {.at: 53.}: float32
    notch3Freq* {.at: 57.}: float32
    filterPhase* {.at: 61.}: uint8
    physicalUnit* {.at: 62.}: uint8
    undef63* {.at: 63.}: uint8
    blockType2* {.at: 64.}: uint8             ## 0x31.
    filterDelay* {.at: 65.}: uint32
    description* {.at: 69.}: array[27, char]
    blockType3* {.at: 96.}: uint8             ## 0x32.
    raw*: array[96, byte]

  SegdTraceHeaderExt1Rev3* = object
    ## Trace Header Extension #1 (0x40), Rev 3 layout; required on every trace.
    receiverLineNumber* {.at24(1).}: int32    ## -1 (`FFFFFF`): see extReceiverLineNumber.
    receiverPointNumber* {.at24(4).}: int32   ## -1 (`FFFFFF`): see extReceiverPointNumber.
    receiverPointIndex* {.at: 7.}: int8
    reshootIndex* {.at: 8.}: uint8
    groupIndex* {.at: 9.}: uint8              ## Component number in multi-component data.
    depthIndex* {.at: 10.}: uint8
    extReceiverLineNumber* {.fix40(11).}: float64
    extReceiverPointNumber* {.fix40(16).}: float64
    sensorType* {.at: 21.}: uint8
    extTraceNumber* {.at24(22).}: uint32      ## Used when the demux trace number is `FFFF`.
    numSamples* {.at: 25.}: uint32
    sensorMoving* {.at: 29.}: uint8
    undef30* {.at: 30.}: uint8
    physicalUnit* {.at: 31.}: uint8
    blockType* {.at: 32.}: uint8              ## 0x40.
    raw*: array[SegdBlockSize, byte]

  SegdPositionBlock* = object
    ## Position Block (96 bytes: 0x50, 0x51, 0x52); coordinates per the CRS
    ## (0x55 blocks). IEEE +Inf is used in practice for "not set".
    timeOfPosition* {.at: 1.}: int64
    timeOfMeasurement* {.at: 9.}: int64
    verticalError* {.at: 17.}: float32
    horizErrorSemiMajor* {.at: 21.}: float32
    horizErrorSemiMinor* {.at: 25.}: float32
    horizErrorOrientation* {.at: 29.}: uint16
    positionType* {.at: 31.}: uint8
    blockType1* {.at: 32.}: uint8
    tuple1Coord1* {.at: 33.}: float64
    tuple1Coord2* {.at: 41.}: float64
    tuple1Coord3* {.at: 49.}: float64
    stanzaId1* {.at: 57.}: uint16
    position1Valid* {.at: 59.}: uint8
    position1Quality* {.at: 60.}: uint8
    undef61* {.at: 61.}: array[3, byte]
    blockType2* {.at: 64.}: uint8
    tuple2Coord1* {.at: 65.}: float64
    tuple2Coord2* {.at: 73.}: float64
    tuple2Coord3* {.at: 81.}: float64
    stanzaId2* {.at: 89.}: uint16
    position2Valid* {.at: 91.}: uint8
    position2Quality* {.at: 92.}: uint8
    undef93* {.at: 93.}: array[3, byte]
    blockType3* {.at: 96.}: uint8
    raw*: array[96, byte]

  SegdSourceDescription* = object
    ## Source Description block (0x15 vibrator, 0x16 explosive, 0x17 airgun,
    ## 0x18 watergun, 0x19 EM, 0x1F other). Bytes 15-18 and 28-29 are
    ## type-specific: see the accessors.
    extFileNumber* {.at24(1).}: uint32
    sourceLineNumber* {.fix40(4).}: float64
    sourcePointNumber* {.fix40(9).}: float64
    sourcePointIndex* {.at: 14.}: uint8
    typeSpecific15* {.at: 15.}: array[4, byte]
    sourceId* {.at: 19.}: uint8
    sourceSetNumber* {.at: 20.}: uint8
    reshootIndex* {.at: 21.}: uint8
    groupIndex* {.at: 22.}: uint8
    depthIndex* {.at: 23.}: uint8
    offsetCrossline* {.at: 24.}: int16
    offsetInline* {.at: 26.}: int16
    typeSpecific28* {.at: 28.}: array[2, byte]
    offsetDepth* {.at: 30.}: int16
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdAdditionalSourceInfo* = object
    ## Additional Source Info (0x20; 0x1A in a 3.0 table typo).
    time* {.at: 1.}: int64
    sourceStatus* {.at: 9.}: uint8
    sourceId* {.at: 10.}: uint8
    sourceMoving* {.at: 11.}: uint8
    errorDescription* {.at: 12.}: array[20, char]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdSensorInfo* = object
    ## Sensor Info header extension (0x41).
    instrumentTestTime* {.at: 1.}: int64
    sensorSensitivity* {.at: 9.}: float32
    instrumentTestResult* {.at: 13.}: uint8
    serialNumber* {.at: 14.}: array[18, char]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdTimestampHeader* = object
    ## Timestamp header (0x42): time of the first sample (Extended Recording Mode).
    timeZeroOfData* {.at: 1.}: int64
    undef9* {.at: 9.}: array[23, byte]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdSensorCalibration* = object
    ## Sensor Calibration header (0x43): two (frequency, amplitude, phase) triplets.
    frequency1* {.at: 1.}: float32
    amplitude1* {.at: 5.}: float32
    phase1* {.at: 9.}: float32
    frequency2* {.at: 13.}: float32
    amplitude2* {.at: 17.}: float32
    phase2* {.at: 21.}: float32
    calibrationApplied* {.at: 25.}: uint8
    undef26* {.at: 26.}: array[6, byte]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdTimeDrift* = object
    ## Time Drift header (0x44).
    timeOfDeployment* {.at: 1.}: int64
    timeOfRetrieval* {.at: 9.}: int64
    timeOffsetDeployment* {.at: 17.}: int32
    timeOffsetRetrieval* {.at: 21.}: int32
    timeDriftCorrected* {.at: 25.}: uint8
    correctionMethod* {.at: 26.}: uint8
    undef27* {.at: 27.}: array[5, byte]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdOrientation* = object
    ## Orientation header (0x60): sensor attitude and the rotation flags used
    ## for multi-component data.
    rotationX* {.at: 1.}: float32             ## radians.
    rotationY* {.at: 5.}: float32
    rotationZ* {.at: 9.}: float32
    referenceOrientation* {.at: 13.}: float32
    timestamp* {.at: 17.}: int64
    orientationType* {.at: 25.}: uint8
    refOrientationValid* {.at: 26.}: uint8
    rotationApplied* {.at: 27.}: uint8
    rotationNorthApplied* {.at: 28.}: uint8
    undef29* {.at: 29.}: array[3, byte]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdTrailerDescription* = object
    ## General Trailer Description block (0x70).
    trailerBlockType* {.at: 1.}: uint8
    asciiOrBinary* {.at: 2.}: uint8           ## 1 binary, 2 ASCII.
    zero3* {.at: 3.}: uint16
    blockSize* {.at: 5.}: uint32              ## 32-byte data blocks that follow.
    description* {.at: 9.}: array[16, char]
    zero25* {.at: 25.}: array[7, byte]
    blockType* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdRev3Block* = SegdGeneralHeader2Rev3 | SegdGeneralHeader3 | SegdChannelSetDescriptorRev3 |
    SegdTraceHeaderExt1Rev3 | SegdPositionBlock | SegdSourceDescription |
    SegdAdditionalSourceInfo | SegdSensorInfo | SegdTimestampHeader | SegdSensorCalibration |
    SegdTimeDrift | SegdOrientation | SegdTrailerDescription
    ## The typed Rev 3 blocks.

const
  # Block type bytes (byte 32 of a 32-byte block).
  BlockTypeGeneralHeader2* = 0x02'u8   ## General Header #2.
  BlockTypeGeneralHeader3* = 0x03'u8   ## General Header #3.
  BlockTypeChannelSet1* = 0x30'u8      ## First block of a channel set descriptor.
  BlockTypeChannelSet2* = 0x31'u8      ## Second block of a channel set descriptor.
  BlockTypeChannelSet3* = 0x32'u8      ## Third block of a channel set descriptor.
  BlockTypeTraceHeaderExt1* = 0x40'u8  ## Trace Header Extension #1.
  BlockTypePosition1* = 0x50'u8        ## First block of a Position block.
  BlockTypePosition2* = 0x51'u8        ## Second block of a Position block.
  BlockTypePosition3* = 0x52'u8        ## Third block of a Position block.
  BlockTypeCrs* = 0x55'u8              ## Coordinate Reference System text.
  BlockTypeTrailerDescription* = 0x70'u8 ## General Trailer Description.
  segdGeneralHeader2Rev3Fields* = fieldTable(SegdGeneralHeader2Rev3) ## GH#2 (Rev 3) field table.
  segdGeneralHeader3Fields* = fieldTable(SegdGeneralHeader3) ## GH#3 field table.
  segdChannelSetDescriptorRev3Fields* = fieldTable(SegdChannelSetDescriptorRev3)
    ## CSD (Rev 3) field table.
  segdTraceHeaderExt1Rev3Fields* = fieldTable(SegdTraceHeaderExt1Rev3) ## THE#1 (Rev 3) field table.
  segdPositionBlockFields* = fieldTable(SegdPositionBlock) ## Position block field table.

# ---------------------------------------------------------------------------
# Raw 32-byte blocks.

func blockTypeName*(t: uint8): string =
  ## The spec name of a block type (byte 32).
  case t
  of 0x02: "generalHeader2"
  of 0x03: "generalHeader3"
  of 0x10: "vesselCrew"
  of 0x11: "surveyArea"
  of 0x12: "client"
  of 0x13: "job"
  of 0x14: "line"
  of 0x15: "vibratorSource"
  of 0x16: "explosiveSource"
  of 0x17: "airgunSource"
  of 0x18: "watergunSource"
  of 0x19: "emSource"
  of 0x1F: "otherSource"
  of 0x1A, 0x20: "additionalSourceInfo"
  of 0x21: "sourceAuxChannelRef"
  of 0x30, 0x31, 0x32: "channelSetDescriptor"
  of 0x40: "traceHeaderExtension1"
  of 0x41: "sensorInfo"
  of 0x42: "timestamp"
  of 0x43: "sensorCalibration"
  of 0x44: "timeDrift"
  of 0x45: "emSrcRecvDescription"
  of 0x50, 0x51, 0x52: "position"
  of 0x55: "crs"
  of 0x56: "relativePosition"
  of 0x60: "orientation"
  of 0x61: "measurement"
  of 0x70: "trailerDescription"
  of 0xB0..0xFF: "userDefined"
  else: "undefined"

func isUserBlock*(t: uint8): bool {.inline.} =
  ## Block types 0xB0-0xFF are manufacturer or user defined.
  t >= 0xB0

func isDefinedBlock*(t: uint8): bool =
  ## True for a block type the spec defines (user types included).
  blockTypeName(t) != "undefined"

iterator blocks*(area: openArray[byte]): (int, uint8) =
  ## The 32-byte blocks of `area` as (byte offset, block type).
  var i = 0
  while i + SegdBlockSize <= area.len:
    yield (i, area[i + SegdBlockSize - 1])
    i += SegdBlockSize

func findBlock*(area: openArray[byte], blockType: uint8, start = 0): int =
  ## Byte offset of the first block of `blockType` at or after `start`, or -1.
  var i = start - start mod SegdBlockSize
  while i + SegdBlockSize <= area.len:
    if area[i + SegdBlockSize - 1] == blockType: return i
    i += SegdBlockSize
  -1

func blockText*(b: openArray[byte], first = 1, last = 31): string =
  ## ASCII text of bytes `first`..`last` (1-based) of a block, NULs dropped
  ## and trimmed.
  asciiText(b, first, last)

func descriptionText*(c: SegdChannelSetDescriptorRev3): string =
  ## The descriptor's description (bytes 69-95), NULs dropped and trimmed.
  asciiText(c.description.toOpenArrayByte(0, c.description.high), 1, c.description.len)

func crsText*(area: openArray[byte]): string =
  ## The Coordinate Reference System text: bytes 1-31 of every 0x55 block of
  ## `area`, concatenated (one Location Data stanza may span many blocks).
  for (i, t) in blocks(area):
    if t == BlockTypeCrs:
      for k in 0..30: result.add char(area[i + k])

type
  CrsTextFormat* = enum
    ctNone = "none"       ## No CRS text.
    ctStanza = "stanza"   ## SEG Location Data stanzas (3.0; deprecated in 3.1).
    ctP1_11 = "P1/11"     ## OGP P1/11 header records (3.1 App. D1).
    ctUnknown = "unknown"

func crsFormat*(text: string): CrsTextFormat =
  ## Which format a `crsText` is in (`segd_rev3_1_delta.md` §6.3): text
  ## starting with `((OGP:P1/11 CRS))` (case and blanks ignored) is P1/11,
  ## `((SEG:` starts a stanza. Position blocks' bytes 57-58 / 89-90 then
  ## name a P1/11 CRS number or a stanza ID.
  var squeezed = ""
  for c in text:
    if c notin {' ', '\t', '\r', '\n', '\0'}: squeezed.add c.toLowerAscii
    if squeezed.len >= 17: break
  if squeezed.len == 0: ctNone
  elif squeezed.startsWith("((ogp:p1/11crs))"): ctP1_11
  elif squeezed.startsWith("((seg:"): ctStanza
  else: ctUnknown

# ---------------------------------------------------------------------------
# Resolved values.

func channelSetsPerScanType*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): int =
  ## Channel sets per scan type: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.channelSetsPerScanType == BcdAllF: int(g2.extChannelSetsPerScanType)
  else: g1.channelSetsPerScanType

func skewBlocks*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): int =
  ## Skew blocks per scan type: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.skewBlocks == BcdAllF: int(g2.extSkewBlocks) else: g1.skewBlocks

func extendedHeaderBlocks*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): int =
  ## Extended header blocks: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.extendedHeaderBlocks == BcdAllF: int(g2.extExtendedHeaderBlocks)
  else: g1.extendedHeaderBlocks

func externalHeaderBlocks*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): int =
  ## External header blocks: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.externalHeaderBlocks == BcdAllF: int(g2.extExternalHeaderBlocks)
  else: g1.externalHeaderBlocks

func generalHeaderCount*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): int =
  ## General header blocks including #1.
  1 + (if g1.additionalGhBlocks == 0xF: int(g2.extAdditionalGhBlocks)
       else: int(g1.additionalGhBlocks))

func fileNumber*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): int64 =
  ## The file number: GH#1's BCD field, or GH#2's extended one when it is `FFFF`.
  if g1.fileNumber == BcdAllF: int64(g2.extFileNumber) else: g1.fileNumber

func baseScanIntervalUs*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): float64 =
  ## Base scan interval in µs (GH#1 byte 23 in 1/16 ms, or GH#2 bytes 25-27).
  if g1.baseScanInterval16 == 0xFF: float64(g2.dominantSamplingInterval)
  else: float64(g1.baseScanInterval16) * 1000.0 / 16.0

func recordLengthUs*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2Rev3): float64 =
  ## GH#1's BCD RR.R × 1.024 s (as in Rev 2; `segd_rev3_0_b.md` §3.1), or
  ## GH#2's µs when it is `FFF`.
  if g1.recordLength == BcdAllF: float64(g2.extRecordLength)
  else: float64(g1.recordLength) * 102_400.0

func traceNumber*(t: SegdTraceHeader, e: SegdTraceHeaderExt1Rev3): int64 =
  ## The trace number: BCD bytes 5-6 of the demux header, or THE#1's
  ## extended one when they are `FFFF`.
  if t.traceNumber == BcdAllF: int64(e.extTraceNumber) else: t.traceNumber

func receiverLine*(e: SegdTraceHeaderExt1Rev3): float64 =
  ## Receiver line number, from the extended fixed-point field when bytes 1-3
  ## are `FFFFFF`.
  if e.receiverLineNumber == -1: e.extReceiverLineNumber else: float64(e.receiverLineNumber)

func receiverPoint*(e: SegdTraceHeaderExt1Rev3): float64 =
  ## Receiver point number, from the extended fixed-point field when bytes
  ## 4-6 are `FFFFFF`.
  if e.receiverPointNumber == -1: e.extReceiverPointNumber else: float64(e.receiverPointNumber)

func traceBytes*(c: SegdChannelSetDescriptorRev3, dataBytes: int): int =
  ## Bytes of one trace of this set, given its sample data size.
  SegdTraceHeaderSize + SegdBlockSize * int(c.traceHeaderExtensions) + dataBytes

# Type-specific Source Description fields, read from the decoded
# `typeSpecific15` (bytes 15-18) and `typeSpecific28` (bytes 28-29).
func phaseAngle*(s: SegdSourceDescription): int16 =
  ## Vibrator (0x15): phase angle, bytes 17-18.
  beI16(s.typeSpecific15, 2)
func vibratorType*(s: SegdSourceDescription): uint8 =
  ## Vibrator (0x15): vibrator type, byte 16.
  s.typeSpecific15[1]
func phaseControl*(s: SegdSourceDescription): uint8 =
  ## Vibrator (0x15): phase control, byte 15.
  s.typeSpecific15[0]
func depth*(s: SegdSourceDescription): uint16 =
  ## Explosive, airgun, watergun (0x16-0x18): depth, bytes 15-16.
  beU16(s.typeSpecific15, 0)
func size*(s: SegdSourceDescription): int32 =
  ## Source size, bytes 28-29 (unsigned for vibrators, signed otherwise).
  if s.blockType == 0x15: int32(beU16(s.typeSpecific28, 0))
  else: int32(beI16(s.typeSpecific28, 0))

# ---------------------------------------------------------------------------
# SEG-D timestamps: µs since 1980-01-06T00:00:00 GPS, no leap seconds.

const
  GpsEpochUnix* = 315_964_800'i64 ## POSIX seconds of 1980-01-06T00:00:00.
  leapSecondDays = [
    # (year, month, day) after which a leap second was inserted into UTC.
    (1972, 6, 30), (1972, 12, 31), (1973, 12, 31), (1974, 12, 31), (1975, 12, 31),
    (1976, 12, 31), (1977, 12, 31), (1978, 12, 31), (1979, 12, 31), (1981, 6, 30),
    (1982, 6, 30), (1983, 6, 30), (1985, 6, 30), (1987, 12, 31), (1989, 12, 31),
    (1990, 12, 31), (1992, 6, 30), (1993, 6, 30), (1994, 6, 30), (1995, 12, 31),
    (1997, 6, 30), (1998, 12, 31), (2005, 12, 31), (2008, 12, 31), (2012, 6, 30),
    (2015, 6, 30), (2016, 12, 31)]
    ## The spec's table (to 2014) plus 2015-06-30 and 2016-12-31 (IERS);
    ## append future leap seconds here.

func computeLeapUnix(): array[leapSecondDays.len, int64] =
  for i, (y, m, d) in leapSecondDays:
    result[i] = (daysFromCivil(y, m, d) + 1) * 86400 # POSIX time just after the leap second

const leapUnix = computeLeapUnix()

func leapsBefore(unix: int64): int64 =
  # Leap seconds inserted into UTC before POSIX time `unix` (9 at the GPS epoch).
  for t in leapUnix:
    if t <= unix: inc result

func timestampToUnix*(ts: int64): float64 =
  ## UTC POSIX seconds of a SEG-D timestamp (GPS µs).
  let gpsSec = float64(ts) / 1e6
  var unix = gpsSec + float64(GpsEpochUnix)
  # GPS - UTC = leapsBefore - 9; iterate once to settle at a boundary.
  for _ in 0..1:
    unix = gpsSec + float64(GpsEpochUnix) - float64(leapsBefore(int64(floor(unix))) - 9)
  unix

func unixToTimestamp*(unix: float64): int64 =
  ## The SEG-D timestamp (GPS µs) of UTC POSIX seconds `unix`.
  int64(round((unix - float64(GpsEpochUnix) + float64(leapsBefore(int64(floor(unix))) - 9)) * 1e6))

func gpsMinusUtc*(ts: int64): int =
  ## GPS − UTC in whole seconds at timestamp `ts` (18 since 2017).
  int(leapsBefore(int64(floor(timestampToUnix(ts)))) - 9)

func generalHeaderUtc*(g1: SegdGeneralHeader1, century = 2000): float64 =
  ## UTC POSIX seconds of GH#1's BCD date and time (1-second resolution;
  ## two-digit year in `century`). NaN when a field is not valid BCD.
  if g1.year notin 0..99 or g1.julianDay notin 1..366 or g1.hour notin 0..23 or
      g1.minute notin 0..59 or g1.second notin 0..60:
    return NaN
  let jan1 = daysFromCivil(century + g1.year, 1, 1) * 86400
  float64(jan1 + int64(g1.julianDay - 1) * 86400 + int64(g1.hour) * 3600 +
    int64(g1.minute) * 60 + int64(g1.second))

# ---------------------------------------------------------------------------
# Table of Contents file (optional, Rev 3): a 448-byte header and 128-byte
# entries, ASCII (spec note `segd_rev3_0_a.md` §2.6).

const
  TocHeaderSize* = 448 ## Bytes in a TOC file header.
  TocEntrySize* = 128  ## Bytes in a TOC entry.
  TocIdentifier* = "SEGD TOC FILE" ## The text a TOC file starts with.

type
  SegdTocEntry* = object
    ## One TOC entry: where a record is on the media. Fields are trimmed text
    ## (numbers stay text, as written).
    mediaFileNumber*, recordWithinFile*, timeOfShot*, segdFileNumber*: string
    recordId*, recordSetNumber*, lineId*, userDefined*: string

  SegdToc* = object
    ## A Table of Contents file.
    revision*, serialNumber*, clientId*, vesselCrewId*, country*, region*: string
    blockName*, surveyAreaName*, contractNumber*, licenseId*, surveyType*: string
    acquisitionContractor*, acquisitionDates*, jobId*, mediaSeqInRecordSet*: string
    dataTypeId*: string
    entries*: seq[SegdTocEntry]
    raw*: seq[byte]       ## The whole file as read.

func isTocFile*(b: openArray[byte]): bool =
  ## True when `b` starts with `SEGD TOC FILE`.
  if b.len < TocIdentifier.len: return false
  for i, c in TocIdentifier:
    if b[i] != byte(c): return false
  true

func tocEntryCount*(header: openArray[byte]): int =
  ## The entry count of a TOC header (bytes 439-448), -1 if not a number.
  let s = asciiText(header, 439, 448)
  if s.len > 0 and s.len <= 9 and s.allCharsInSet(Digits): parseInt(s) else: -1

func decodeToc*(b: openArray[byte]): SegdToc =
  ## Decodes a TOC file (header plus as many whole entries as `b` holds).
  result = SegdToc(raw: @b, revision: asciiText(b, 14, 19),
    serialNumber: asciiText(b, 20, 31), clientId: asciiText(b, 32, 63),
    vesselCrewId: asciiText(b, 64, 95), country: asciiText(b, 96, 127),
    region: asciiText(b, 128, 159), blockName: asciiText(b, 160, 191),
    surveyAreaName: asciiText(b, 192, 223), contractNumber: asciiText(b, 224, 255),
    licenseId: asciiText(b, 256, 287), surveyType: asciiText(b, 288, 307),
    acquisitionContractor: asciiText(b, 308, 339), acquisitionDates: asciiText(b, 340, 364),
    jobId: asciiText(b, 365, 396), mediaSeqInRecordSet: asciiText(b, 397, 402),
    dataTypeId: asciiText(b, 403, 434))
  var i = TocHeaderSize
  while i + TocEntrySize <= b.len:
    template e: untyped = b.toOpenArray(i, i + TocEntrySize - 1)
    result.entries.add SegdTocEntry(mediaFileNumber: asciiText(e, 1, 8),
      recordWithinFile: asciiText(e, 9, 15), timeOfShot: asciiText(e, 16, 35),
      segdFileNumber: asciiText(e, 36, 45), recordId: asciiText(e, 46, 60),
      recordSetNumber: asciiText(e, 61, 70), lineId: asciiText(e, 71, 94),
      userDefined: asciiText(e, 95, 128))
    i += TocEntrySize
