## SEG-Y standard trace header: the first 240 bytes of every trace record
## (spec notes `segy_rev1.md` §3.4, `segy_rev2_1.md` §3.4).
##
## All 240 bytes are mapped, so a decode/encode round trip is byte-identical
## for any revision. In Rev 0, bytes 181-240 were free for vendor use: they
## still decode into the Rev 1+ fields and re-encode unchanged. Bytes 233-240
## (`headerName`) are text and are never byte-swapped.
##
## The Rev 2 Trace Header Extension 1 (`SEG00001`) is `SegyTraceHeaderExt1`,
## also fully mapped.

import ../common/[endians, fieldlayout, ebcdic]

const
  TraceHeaderSize* = 240 ## Bytes in a standard trace header (and in each extension).

type
  SegyTraceHeader* = object
    ## The standard trace header. Each field carries its spec byte number.
    ## Scalars: E = `elevationScalar`, C = `coordinateScalar`, T = `timeScalar`.
    traceSeqLine* {.at: 1.}: int32
    traceSeqFile* {.at: 5.}: int32
    fieldRecord* {.at: 9.}: int32
    traceNumberInField* {.at: 13.}: int32
    energySourcePoint* {.at: 17.}: int32
    ensembleNumber* {.at: 21.}: int32
    traceInEnsemble* {.at: 25.}: int32
    traceIdCode* {.at: 29.}: int16
    numVertSummed* {.at: 31.}: int16
    numHorzStacked* {.at: 33.}: int16
    dataUse* {.at: 35.}: int16                  ## 1 = production, 2 = test.
    offset* {.at: 37.}: int32                   ## Source to receiver group distance.
    receiverElevation* {.at: 41.}: int32        ## ×E.
    sourceSurfaceElevation* {.at: 45.}: int32   ## ×E.
    sourceDepth* {.at: 49.}: int32              ## ×E.
    receiverDatumElevation* {.at: 53.}: int32   ## ×E.
    sourceDatumElevation* {.at: 57.}: int32     ## ×E.
    sourceWaterDepth* {.at: 61.}: int32         ## ×E.
    groupWaterDepth* {.at: 65.}: int32          ## ×E.
    elevationScalar* {.at: 69.}: int16
    coordinateScalar* {.at: 71.}: int16
    sourceX* {.at: 73.}: int32                  ## ×C.
    sourceY* {.at: 77.}: int32                  ## ×C.
    groupX* {.at: 81.}: int32                   ## ×C.
    groupY* {.at: 85.}: int32                   ## ×C.
    coordinateUnits* {.at: 89.}: int16          ## 1 length, 2 arc seconds, 3 degrees, 4 DMS.
    weatheringVelocity* {.at: 91.}: int16
    subweatheringVelocity* {.at: 93.}: int16
    upholeTimeSource* {.at: 95.}: int16         ## ms ×T.
    upholeTimeGroup* {.at: 97.}: int16          ## ms ×T.
    sourceStatic* {.at: 99.}: int16             ## ms ×T.
    groupStatic* {.at: 101.}: int16             ## ms ×T.
    totalStatic* {.at: 103.}: int16             ## ms ×T.
    lagTimeA* {.at: 105.}: int16                ## ms ×T.
    lagTimeB* {.at: 107.}: int16                ## ms ×T.
    delayRecordingTime* {.at: 109.}: int16      ## ms ×T; may be negative.
    muteStart* {.at: 111.}: int16               ## ms ×T.
    muteEnd* {.at: 113.}: int16                 ## ms ×T.
    numSamples* {.at: 115.}: uint16             ## Samples in this trace.
    sampleInterval* {.at: 117.}: uint16         ## µs (time), Hz or m/ft.
    gainType* {.at: 119.}: int16
    instrumentGainConstant* {.at: 121.}: int16  ## dB.
    instrumentInitialGain* {.at: 123.}: int16   ## dB.
    correlated* {.at: 125.}: int16              ## 1 = no, 2 = yes.
    sweepFreqStart* {.at: 127.}: int16          ## Hz.
    sweepFreqEnd* {.at: 129.}: int16            ## Hz.
    sweepLength* {.at: 131.}: int16             ## ms.
    sweepType* {.at: 133.}: int16
    sweepTaperStart* {.at: 135.}: int16         ## ms.
    sweepTaperEnd* {.at: 137.}: int16           ## ms.
    taperType* {.at: 139.}: int16
    aliasFilterFreq* {.at: 141.}: int16         ## Hz.
    aliasFilterSlope* {.at: 143.}: int16        ## dB/octave.
    notchFilterFreq* {.at: 145.}: int16         ## Hz.
    notchFilterSlope* {.at: 147.}: int16        ## dB/octave.
    lowCutFreq* {.at: 149.}: int16              ## Hz.
    highCutFreq* {.at: 151.}: int16             ## Hz.
    lowCutSlope* {.at: 153.}: int16             ## dB/octave.
    highCutSlope* {.at: 155.}: int16            ## dB/octave.
    year* {.at: 157.}: int16                    ## 4 digits from Rev 1; Rev 0 may have 2.
    dayOfYear* {.at: 159.}: int16
    hour* {.at: 161.}: int16
    minute* {.at: 163.}: int16
    second* {.at: 165.}: int16
    timeBasisCode* {.at: 167.}: int16           ## 1 local, 2 GMT, 3 other, 4 UTC, 5 GPS.
    traceWeightingFactor* {.at: 169.}: int16    ## LSB = 2^-N volts.
    rollSwitchGroup* {.at: 171.}: int16
    firstTraceGroup* {.at: 173.}: int16
    lastTraceGroup* {.at: 175.}: int16
    gapSize* {.at: 177.}: int16
    overTravel* {.at: 179.}: int16              ## 1 down/behind, 2 up/ahead.
    cdpX* {.at: 181.}: int32                    ## ×C.
    cdpY* {.at: 185.}: int32                    ## ×C.
    inlineNumber* {.at: 189.}: int32
    crosslineNumber* {.at: 193.}: int32
    shotpointNumber* {.at: 197.}: int32         ## Scaled by `shotpointScalar`.
    shotpointScalar* {.at: 201.}: int16         ## 0 = not scaled.
    traceValueUnit* {.at: 203.}: int16
    transductionMantissa* {.at: 205.}: int32
    transductionExponent* {.at: 209.}: int16
    transductionUnits* {.at: 211.}: int16
    deviceTraceId* {.at: 213.}: int16
    timeScalar* {.at: 215.}: int16
    sourceTypeOrientation* {.at: 217.}: int16
    sourceEnergyDirVert* {.at: 219.}: int16     ## Tenths of a degree (Rev 2 layout).
    sourceEnergyDirXline* {.at: 221.}: int16    ## Tenths of a degree.
    sourceEnergyDirInline* {.at: 223.}: int16   ## Tenths of a degree.
    sourceMeasurementMantissa* {.at: 225.}: int32
    sourceMeasurementExponent* {.at: 229.}: int16
    sourceMeasurementUnit* {.at: 231.}: int16
    headerName* {.at: 233.}: array[8, char]
      ## Rev 2: `SEG00000` (ASCII or EBCDIC) or 8 zero bytes. Unassigned in Rev 1.

const traceHeaderFields* = fieldTable(SegyTraceHeader)
  ## Layout of the standard trace header.

func decodeTraceHeader*(b: openArray[byte], order: ByteOrder): SegyTraceHeader =
  ## Decodes a trace header from the first 240 bytes of `b`, with numbers in
  ## `order`.
  doAssert b.len >= TraceHeaderSize, "trace header needs 240 bytes"
  decodeFields(result, b, 1, order)

func encode*(h: SegyTraceHeader, b: var openArray[byte], order: ByteOrder) =
  ## Writes `h` to the first 240 bytes of `b`, with numbers in `order`.
  doAssert b.len >= TraceHeaderSize, "trace header needs 240 bytes"
  encodeFields(h, b, 1, order)

func applyScalar*(value: SomeNumber, scalar: int16): float64 {.inline.} =
  ## Applies a SEG-Y scalar: positive multiplies, negative divides, 0 means 1.
  if scalar > 0: float64(value) * float64(scalar)
  elif scalar < 0: float64(value) / float64(-int32(scalar))
  else: float64(value)

func scaleElevation*(h: SegyTraceHeader, value: SomeNumber): float64 {.inline.} =
  ## Applies the elevation scalar (bytes 69-70) to one of bytes 41-68.
  applyScalar(value, h.elevationScalar)

func scaleCoordinate*(h: SegyTraceHeader, value: SomeNumber): float64 {.inline.} =
  ## Applies the coordinate scalar (bytes 71-72) to one of bytes 73-88 or 181-188.
  applyScalar(value, h.coordinateScalar)

func scaleTime*(h: SegyTraceHeader, value: SomeNumber): float64 {.inline.} =
  ## Applies the time scalar (bytes 215-216) to one of bytes 95-114, giving ms.
  applyScalar(value, h.timeScalar)

func shotpoint*(h: SegyTraceHeader): float64 {.inline.} =
  ## The shotpoint number (197-200) with its scalar (201-202) applied.
  applyScalar(h.shotpointNumber, h.shotpointScalar)

# ---------------------------------------------------------------------------
# Rev 2 Trace Header Extension 1 (spec note `segy_rev2_1.md` §3.5).

type
  SegyTraceHeaderExt1* = object
    ## Trace Header Extension 1 (`SEG00001`), the first additional 240-byte
    ## header of a Rev 2 trace. The `ext*` fields override their standard
    ## header counterparts when non-zero; the f64 fields are unscaled.
    extTraceSeqLine* {.at: 1.}: uint64
    extTraceSeqFile* {.at: 9.}: uint64
    extFieldRecord* {.at: 17.}: int64
    extEnsembleNumber* {.at: 25.}: int64
    extReceiverElevation* {.at: 33.}: float64
    receiverDepth* {.at: 41.}: float64          ## Below the receiver's surface; no std counterpart.
    extSourceSurfaceElevation* {.at: 49.}: float64
    extSourceDepth* {.at: 57.}: float64
    extReceiverDatumElevation* {.at: 65.}: float64
    extSourceDatumElevation* {.at: 73.}: float64
    extSourceWaterDepth* {.at: 81.}: float64
    extGroupWaterDepth* {.at: 89.}: float64
    extSourceX* {.at: 97.}: float64
    extSourceY* {.at: 105.}: float64
    extGroupX* {.at: 113.}: float64
    extGroupY* {.at: 121.}: float64
    extOffset* {.at: 129.}: float64
    extNumSamples* {.at: 137.}: uint32
    nanoseconds* {.at: 141.}: int32             ## Added to `second`; may be negative.
    extSampleInterval* {.at: 145.}: float64
    cableNumber* {.at: 153.}: int32             ## Cable, or recording device/sensor ID.
    numAddlTraceHeaders* {.at: 157.}: uint16    ## Including this one; 0 = binary 3507.
    lastTraceFlag* {.at: 159.}: uint16          ## 1 ensemble, 2 line, 4 file, 8 survey.
    extCdpX* {.at: 161.}: float64
    extCdpY* {.at: 169.}: float64
    reserved* {.at: 177.}: array[56, byte]
    headerName* {.at: 233.}: array[8, char]     ## `SEG00001`, ASCII or EBCDIC.

const
  traceHeaderExt1Fields* = fieldTable(SegyTraceHeaderExt1)
    ## Layout of Trace Header Extension 1.
  LastInEnsemble* = 1'u16 ## `lastTraceFlag` bits.
  LastInLine* = 2'u16
  LastInFile* = 4'u16
  LastInSurvey* = 8'u16

func decodeTraceHeaderExt1*(b: openArray[byte], order: ByteOrder): SegyTraceHeaderExt1 =
  ## Decodes Extension 1 from the first 240 bytes of `b`.
  doAssert b.len >= TraceHeaderSize, "trace header extension needs 240 bytes"
  decodeFields(result, b, 1, order)

func encode*(h: SegyTraceHeaderExt1, b: var openArray[byte], order: ByteOrder) =
  ## Writes Extension 1 to the first 240 bytes of `b`.
  doAssert b.len >= TraceHeaderSize, "trace header extension needs 240 bytes"
  encodeFields(h, b, 1, order)

func blockName(name: array[8, char]): string =
  # An 8-character header name as text: ASCII as stored, EBCDIC decoded,
  # "" for all zero bytes.
  var allZero = true
  for c in name:
    if c != '\0': allZero = false
  if allZero:
    result = ""
  else:
    result = newString(8)
    let ebcdic = name[0] >= '\xC1'
    for i, c in name:
      result[i] = if ebcdic: char(ebcdicToLatin1[uint8(c)]) else: c

func headerNameText*(h: SegyTraceHeader): string = blockName(h.headerName)
  ## `headerName` as text: ASCII as stored, EBCDIC decoded, or "" when it is
  ## all zero bytes.

func headerNameText*(h: SegyTraceHeaderExt1): string = blockName(h.headerName)
  ## `headerName` as text (normally `SEG00001`).

func initTraceHeaderExt1*(): SegyTraceHeaderExt1 =
  ## An empty Extension 1 named `SEG00001` (ASCII).
  for i, c in "SEG00001": result.headerName[i] = c

func headerBlockName*(b: openArray[byte]): string =
  ## Name (bytes 233-240) of a raw 240-byte additional header, e.g. a
  ## proprietary extension; "" for zero bytes.
  var name: array[8, char]
  for i in 0..7: name[i] = char(b[232 + i])
  blockName(name)
