## SEG-D Rev 1 / 2.x header blocks (spec notes `segd_rev2_0.md` §3,
## `segd_rev2_1.md`): General Headers #1, #2 and #N, Channel Set Descriptor,
## Demux Trace Header, Trace Header Extension #1.
##
## Each block keeps the bytes it was decoded from (`raw`) and `encode` writes
## only the fields whose values changed, so an unedited block is reproduced
## byte for byte, including undefined bytes, invalid BCD and the extended
## copies that real files fill in. Field byte numbers follow the spec (1-based
## within the block). BCD fields hold `BcdAllF` (-1) for an all-`F` sentinel
## and `BcdInvalid` (-2) for a non-decimal nibble.

import std/[math, strutils]
import ../common/[fieldlayout, errors]
export FieldSpec, FieldKind, BcdAllF, BcdInvalid, fieldTable

const
  SegdBlockSize* = 32           ## Bytes in a general header, CSD, extension or trailer block.
  SegdTraceHeaderSize* = 20     ## Bytes in a demux trace header.

type
  SegdGeneralHeader1* = object
    ## General Header Block #1.
    fileNumber* {.bcdAt(1, 4).}: int        ## 0-9999; `BcdAllF`: see GH#2 extFileNumber.
    formatCode* {.bcdAt(3, 4).}: int        ## e.g. 8058.
    generalConstants* {.at: 5.}: array[6, byte] ## K1-K12 (BCD, raw).
    year* {.bcdAt(11, 2).}: int             ## Last two digits.
    additionalGhBlocks* {.nibAt(12).}: uint8 ## General header blocks after #1 (binary).
    julianDay* {.bcdAtL(12, 3).}: int
    hour* {.bcdAt(14, 2).}: int             ## UTC (GMT in Rev 0).
    minute* {.bcdAt(15, 2).}: int
    second* {.bcdAt(16, 2).}: int
    manufacturerCode* {.bcdAt(17, 2).}: int
    manufacturerSerial* {.bcdAt(18, 4).}: int
    unused20* {.at: 20.}: array[3, byte]
      ## "Record as zero" (Rev 2); Rev 0 multiplexed: bytes per scan, see `bytesPerScan`.
    baseScanInterval16* {.at: 23.}: uint8   ## Base scan interval in 1/16 ms.
    polarity* {.nibAt(24).}: uint8
    unused24L* {.nibAtL(24).}: uint8        ## Rev 0: S/BX, see `scansPerBlock`.
    unused25* {.at: 25.}: uint8             ## Rev 0: S/B, see `scansPerBlock`.
    recordType* {.nibAt(26).}: uint8        ## 8 = normal record.
    recordLength* {.bcdAtL(26, 3).}: int    ## RR.R × 1.024 s, as tenths; `BcdAllF`: see GH#2.
    scanTypesPerRecord* {.bcdAt(28, 2).}: int
    channelSetsPerScanType* {.bcdAt(29, 2).}: int ## `BcdAllF`: see GH#2.
    skewBlocks* {.bcdAt(30, 2).}: int
    extendedHeaderBlocks* {.bcdAt(31, 2).}: int   ## `BcdAllF`: see GH#2.
    externalHeaderBlocks* {.bcdAt(32, 2).}: int   ## `BcdAllF`: see GH#2.
    raw*: array[SegdBlockSize, byte]

  SegdGeneralHeader2* = object
    ## General Header Block #2 (Rev 1 and later).
    extFileNumber* {.at24(1).}: uint32
    extChannelSetsPerScanType* {.at: 4.}: uint16
    extExtendedHeaderBlocks* {.at: 6.}: uint16
    extExternalHeaderBlocks* {.at: 8.}: uint16
    undef10* {.at: 10.}: uint8
    revisionMajor* {.at: 11.}: uint8
    revisionMinor* {.at: 12.}: uint8          ## Rev 2.0: binary fraction; 2.1: minor number.
    generalTrailerBlocks* {.at: 13.}: uint16
    extRecordLength* {.at24(15).}: uint32     ## ms; used when GH#1 recordLength is `FFF`.
    undef18* {.at: 18.}: uint8
    blockNumber* {.at: 19.}: uint8            ## 2.
    undef20* {.at: 20.}: uint8
    lineSequenceNumber* {.at: 21.}: uint16    ## Rev 2.1; undefined (kept raw) in 2.0.
    undef23* {.at: 23.}: array[10, byte]
    raw*: array[SegdBlockSize, byte]

  SegdGeneralHeaderN* = object
    ## General Header Block #N, N ≥ 3: a source position.
    extFileNumber* {.at24(1).}: uint32
    sourceLineNumber* {.fix40(4).}: float64
    sourcePointNumber* {.fix40(9).}: float64
    sourcePointIndex* {.at: 14.}: uint8
    phaseControl* {.at: 15.}: uint8
    vibratorType* {.at: 16.}: uint8
    phaseAngle* {.at: 17.}: int16             ## Degrees.
    blockNumber* {.at: 19.}: uint8            ## N.
    sourceSetNumber* {.at: 20.}: uint8
    undef21* {.at: 21.}: array[12, byte]
    raw*: array[SegdBlockSize, byte]

  SegdChannelSetDescriptor* = object
    ## Channel Set Descriptor (one per channel set and scan type).
    scanTypeNumber* {.bcdAt(1, 2).}: int
    channelSetNumber* {.bcdAt(2, 2).}: int    ## `BcdAllF`: see extChannelSetNumber.
    startTime* {.at: 3.}: uint16              ## × 2 ms.
    endTime* {.at: 5.}: uint16                ## × 2 ms.
    mpRaw* {.at: 7.}: array[2, byte]          ## MP factor, sign-magnitude; see `mpFactor`.
    channelCount* {.bcdAt(9, 4).}: int        ## 0 = unused (dummy) descriptor.
    channelType* {.nibAt(11).}: uint8         ## 1 = seis, 9 = signature filtered, ...
    zero11L* {.nibAtL(11).}: uint8
    subscanExponent* {.bcdAt(12, 1).}: int    ## Sample interval = BSI / 2^this.
    gainControl* {.nibAtL(12).}: uint8
    aliasFilterFreq* {.bcdAt(13, 4).}: int    ## Hz.
    zero15H* {.nibAt(15).}: uint8
    aliasFilterSlope* {.bcdAtL(15, 3).}: int  ## dB/octave.
    lowCutFreq* {.bcdAt(17, 4).}: int         ## Hz.
    zero19H* {.nibAt(19).}: uint8
    lowCutSlope* {.bcdAtL(19, 3).}: int       ## dB/octave.
    notch1Freq* {.bcdAt(21, 4).}: int         ## Tenths of Hz.
    notch2Freq* {.bcdAt(23, 4).}: int
    notch3Freq* {.bcdAt(25, 4).}: int
    extChannelSetNumber* {.at: 27.}: uint16
    extendedHeaderFlag* {.nibAt(29).}: uint8
    traceHeaderExtensions* {.nibAtL(29).}: uint8 ## 0-15 per trace of this set.
    verticalStack* {.at: 30.}: uint8
    streamerNumber* {.at: 31.}: uint8
    arrayForming* {.at: 32.}: uint8
    raw*: array[SegdBlockSize, byte]

  SegdTraceHeader* = object
    ## Demux Trace Header (20 bytes).
    fileNumber* {.bcdAt(1, 4).}: int          ## `BcdAllF`: see extFileNumber.
    scanTypeNumber* {.bcdAt(3, 2).}: int
    channelSetNumber* {.bcdAt(4, 2).}: int    ## `BcdAllF`: see extChannelSetNumber.
    traceNumber* {.bcdAt(5, 4).}: int
    firstTimingWord* {.fix24(7).}: float64    ## ms.
    traceHeaderExtensions* {.at: 10.}: uint8
    sampleSkew* {.at: 11.}: uint8             ## /256 of the base scan interval.
    traceEdit* {.at: 12.}: uint8
    timeBreakWindow* {.fix24(13).}: float64   ## ms.
    extChannelSetNumber* {.at: 16.}: uint16
    extFileNumber* {.at24(18).}: uint32
    raw*: array[SegdTraceHeaderSize, byte]

  SegdTraceHeaderExt1* = object
    ## Trace Header Extension #1 (Rev 1 / 2.x layout).
    receiverLineNumber* {.at24(1).}: int32    ## -1 (`FFFFFF`): see extReceiverLineNumber.
    receiverPointNumber* {.at24(4).}: int32   ## -1 (`FFFFFF`): see extReceiverPointNumber.
    receiverPointIndex* {.at: 7.}: int8
    samplesPerTrace* {.at24(8).}: uint32
    extReceiverLineNumber* {.fix40(11).}: float64
    extReceiverPointNumber* {.fix40(16).}: float64
    sensorType* {.at: 21.}: uint8             ## 1 hydrophone, 2-5 geophone, 6-9 accelerometer.
    undef22* {.at: 22.}: array[11, byte]
    raw*: array[SegdBlockSize, byte]


func bytesPerScan*(g: SegdGeneralHeader1): int =
  ## Rev 0 multiplexed data: GH1 bytes 20-22, the bytes in one scan
  ## (6-digit BCD; 0 for demultiplexed data). -1 if not BCD.
  result = 0
  for b in g.unused20:
    for d in [b shr 4, b and 0xF]:
      if d > 9: return -1
      result = result * 10 + int(d)

func scansPerBlock*(g: SegdGeneralHeader1): int =
  ## Rev 0 multiplexed data: scans per tape block, S/B × 2^S/BX (GH1 byte 25
  ## and the low nibble of 24); 0 means gapless (one block per record).
  int(g.unused25) shl int(g.unused24L)

const
  # Field tables (name, byte, kind) of each block, for field-by-name access.
  segdGeneralHeader1Fields* = fieldTable(SegdGeneralHeader1) ## GH#1 field table.
  segdGeneralHeader2Fields* = fieldTable(SegdGeneralHeader2) ## GH#2 field table.
  segdGeneralHeaderNFields* = fieldTable(SegdGeneralHeaderN) ## GH#N field table.
  segdChannelSetDescriptorFields* = fieldTable(SegdChannelSetDescriptor) ## CSD field table.
  segdTraceHeaderFields* = fieldTable(SegdTraceHeader) ## Demux trace header field table.
  segdTraceHeaderExt1Fields* = fieldTable(SegdTraceHeaderExt1) ## THE#1 field table.

# ---------------------------------------------------------------------------
# Resolved values: BCD fields with their extended alternatives, units.

func baseScanIntervalMs*(g1: SegdGeneralHeader1): float64 {.inline.} =
  ## Base scan interval in ms (byte 23 counts 1/16 ms).
  float64(g1.baseScanInterval16) / 16.0

func generalHeaderCount*(g1: SegdGeneralHeader1): int {.inline.} =
  ## General header blocks including #1.
  1 + int(g1.additionalGhBlocks)

func fileNumber*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2): int64 =
  ## The file number: GH#1's BCD field, or GH#2's extended one when it is `FFFF`.
  if g1.fileNumber == BcdAllF: int64(g2.extFileNumber) else: g1.fileNumber

func channelSetsPerScanType*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2): int =
  ## Channel sets per scan type: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.channelSetsPerScanType == BcdAllF: int(g2.extChannelSetsPerScanType)
  else: g1.channelSetsPerScanType

func extendedHeaderBlocks*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2): int =
  ## Extended header blocks: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.extendedHeaderBlocks == BcdAllF: int(g2.extExtendedHeaderBlocks)
  else: g1.extendedHeaderBlocks

func externalHeaderBlocks*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2): int =
  ## External header blocks: GH#1's, or GH#2's extended count when it is `FF`.
  if g1.externalHeaderBlocks == BcdAllF: int(g2.extExternalHeaderBlocks)
  else: g1.externalHeaderBlocks

func recordLengthMs*(g1: SegdGeneralHeader1, g2: SegdGeneralHeader2): float64 =
  ## Record length in ms (0 = indeterminate).
  if g1.recordLength == BcdAllF: float64(g2.extRecordLength)
  else: float64(g1.recordLength) * 102.4

func mpFactor*(c: SegdChannelSetDescriptor): float64 =
  ## The MP factor: samples × 2^mpFactor = millivolts. Byte 8 holds the sign
  ## and the high bits, byte 7 the low bits (LSB = 2^-10).
  let mag = (int(c.mpRaw[1] and 0x7F) shl 8) or int(c.mpRaw[0])
  result = float64(mag) / 1024.0
  if (c.mpRaw[1] and 0x80) != 0: result = -result

func `mpFactor=`*(c: var SegdChannelSetDescriptor, mp: float64) =
  ## Sets the MP factor, rounded to the nearest 2^-10 and clamped to
  ## ±31.9990234375.
  let mag = min(int(round(abs(mp) * 1024.0)), 0x7FFF)
  c.mpRaw[0] = byte(mag and 0xFF)
  c.mpRaw[1] = byte(mag shr 8) or (if mp < 0 and mag != 0: 0x80'u8 else: 0'u8)

func channelSetNumber*(c: SegdChannelSetDescriptor): int =
  ## The channel set number: BCD byte 2, or bytes 27-28 when it is `FF`.
  if c.channelSetNumber == BcdAllF: int(c.extChannelSetNumber) else: c.channelSetNumber

func startTimeMs*(c: SegdChannelSetDescriptor): float64 {.inline.} =
  ## Channel set start time in ms.
  float64(c.startTime) * 2

func endTimeMs*(c: SegdChannelSetDescriptor): float64 {.inline.} =
  ## Channel set end time in ms.
  float64(c.endTime) * 2

func sampleIntervalMs*(c: SegdChannelSetDescriptor, g1: SegdGeneralHeader1): float64 =
  ## Base scan interval / 2^subscanExponent.
  g1.baseScanIntervalMs / float64(1 shl max(0, min(c.subscanExponent, 9)))

func fileNumber*(t: SegdTraceHeader): int64 =
  ## The file number: BCD bytes 1-2, or bytes 18-20 when they are `FFFF`.
  if t.fileNumber == BcdAllF: int64(t.extFileNumber) else: t.fileNumber

func channelSetNumber*(t: SegdTraceHeader): int =
  ## The channel set number: BCD byte 4, or bytes 16-17 when it is `FF`.
  if t.channelSetNumber == BcdAllF: int(t.extChannelSetNumber) else: t.channelSetNumber

func receiverLine*(e: SegdTraceHeaderExt1): float64 =
  ## Receiver line number, from the extended fixed-point field when bytes 1-3
  ## are `FFFFFF`.
  if e.receiverLineNumber == -1: e.extReceiverLineNumber else: float64(e.receiverLineNumber)

func receiverPoint*(e: SegdTraceHeaderExt1): float64 =
  ## Receiver point number, from the extended fixed-point field when bytes
  ## 4-6 are `FFFFFF`.
  if e.receiverPointNumber == -1: e.extReceiverPointNumber else: float64(e.receiverPointNumber)

# ---------------------------------------------------------------------------
# General trailer block and storage unit label.

type
  SegdTrailerBlock* = object
    ## General Trailer block (32 bytes); bytes other than 1-2 and 11H are
    ## manufacturer or user defined.
    trailerNumber* {.at: 1.}: uint16
    undef3* {.at: 3.}: array[8, byte]
    channelType* {.nibAt(11).}: uint8      ## 0xC for a general trailer.
    undef11L* {.nibAtL(11).}: uint8
    undef12* {.at: 12.}: array[21, byte]
    raw*: array[SegdBlockSize, byte]

  SegdStorageUnitLabel* = object
    ## Storage Unit Label (128 ASCII bytes), the first record of a SEG-D tape
    ## (rarely present in disk files). Fields are the trimmed text.
    storageUnitSeqNum*: string   ## Field 1, bytes 1-4.
    revision*: string            ## Field 2, bytes 5-9: `SD2.0`, `SD2.1`, `SD3.0`, ...
    structure*: string           ## Field 3, bytes 10-15: `RECORD` or `FIXREC`.
    bindingEdition*: string      ## Field 4, bytes 16-19.
    maxBlockSize*: int64         ## Field 5, bytes 20-29; 0 = undeclared.
    producerOrgCode*: string     ## Field 6, bytes 30-39.
    creationDate*: string        ## Field 7, bytes 40-50, `dd-MMM-yyyy`.
    serialNumber*: string        ## Field 8, bytes 51-62.
    externalLabelName*: string   ## Field 10a, bytes 69-80.
    recordingEntityName*: string ## Field 10b, bytes 81-104.
    userDefined*: string         ## Field 10c, bytes 105-118.
    maxShotsPerFieldRecord*: string ## Field 10d, bytes 119-128.
    raw*: array[128, byte]

  SegdHeaderBlock* = SegdGeneralHeader1 | SegdGeneralHeader2 | SegdGeneralHeaderN |
    SegdChannelSetDescriptor | SegdTraceHeader | SegdTraceHeaderExt1 | SegdTrailerBlock
    ## The typed Rev 1/2 blocks (Rev 3 keeps GH#1 and the demux trace header).

const segdTrailerBlockFields* = fieldTable(SegdTrailerBlock) ## Trailer block field table.

func isStorageUnitLabel*(b: openArray[byte]): bool =
  ## True when bytes 5-9 read `SD<digit>.<digit>`: a SEG-D label rather than
  ## General Header #1.
  b.len >= 9 and b[4] == byte('S') and b[5] == byte('D') and b[6] in {0x30'u8..0x39'u8} and
    b[7] == byte('.') and b[8] in {0x30'u8..0x39'u8}

func asciiText*(b: openArray[byte], first, last: int): string =
  ## The ASCII text of bytes `first`..`last` (1-based, inclusive; bytes past
  ## the end of `b` are ignored), NULs dropped and blanks trimmed.
  for i in first - 1 .. min(last, b.len) - 1:
    if b[i] != 0: result.add char(b[i])
  result = result.strip

func decodeLabel*(b: openArray[byte]): SegdStorageUnitLabel =
  ## Decodes a 128-byte storage unit label. Text fields are trimmed; a
  ## non-numeric maximum block size reads as -1.
  doAssert b.len >= 128, "storage unit label needs 128 bytes"
  let mbs = asciiText(b, 20, 29)
  result = SegdStorageUnitLabel(storageUnitSeqNum: asciiText(b, 1, 4),
    revision: asciiText(b, 5, 9), structure: asciiText(b, 10, 15),
    bindingEdition: asciiText(b, 16, 19),
    maxBlockSize: (if mbs.len == 0: 0
                   elif mbs.len <= 10 and mbs.allCharsInSet(Digits): parseBiggestInt(mbs)
                   else: -1),
    producerOrgCode: asciiText(b, 30, 39), creationDate: asciiText(b, 40, 50),
    serialNumber: asciiText(b, 51, 62), externalLabelName: asciiText(b, 69, 80),
    recordingEntityName: asciiText(b, 81, 104), userDefined: asciiText(b, 105, 118),
    maxShotsPerFieldRecord: asciiText(b, 119, 128))
  for i in 0..127: result.raw[i] = b[i]

proc encoded*(l: SegdStorageUnitLabel): array[128, byte] =
  ## The label's bytes: `raw` when the fields are unchanged since
  ## `decodeLabel`, else rebuilt from the fields (numbers right-justified, text
  ## left-justified, blanks elsewhere). Raises `SegFormatError` for a field
  ## that does not fit.
  var asRead = decodeLabel(l.raw)
  asRead.raw = l.raw
  if asRead == l:
    return l.raw
  for i in 0..127: result[i] = byte(' ')
  proc put(r: var array[128, byte], first, last: int, s: string, right: bool, name: string) =
    let width = last - first + 1
    if s.len > width:
      raiseFormat("label " & name & " '" & s & "' exceeds " & $width & " characters")
    let t = if right: align(s, width) else: alignLeft(s, width)
    for i, c in t: r[first - 1 + i] = byte(c)
  result.put(1, 4, l.storageUnitSeqNum, true, "storageUnitSeqNum")
  result.put(5, 9, l.revision, false, "revision")
  result.put(10, 15, l.structure, false, "structure")
  result.put(16, 19, l.bindingEdition, false, "bindingEdition")
  result.put(20, 29, $l.maxBlockSize, true, "maxBlockSize")
  result.put(30, 39, l.producerOrgCode, true, "producerOrgCode")
  result.put(40, 50, l.creationDate, false, "creationDate")
  result.put(51, 62, l.serialNumber, true, "serialNumber")
  result.put(69, 80, l.externalLabelName, true, "externalLabelName")
  result.put(81, 104, l.recordingEntityName, false, "recordingEntityName")
  result.put(105, 118, l.userDefined, false, "userDefined")
  result.put(119, 128, l.maxShotsPerFieldRecord, true, "maxShotsPerFieldRecord")

func isFixedRecord*(l: SegdStorageUnitLabel): bool {.inline.} =
  ## Device structure C: every shot padded to `maxBlockSize`.
  l.structure == "FIXREC"

