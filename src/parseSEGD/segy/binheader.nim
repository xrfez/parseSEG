## SEG-Y binary file header: 400 bytes at file bytes 3201-3600
## (spec notes `segy_rev1.md` §3.2, `segy_rev2_1.md` §3.2).
##
## One type covers every revision. All 400 bytes are mapped, using the Rev 2.1
## layout, so a decode/encode round trip is byte-identical for any revision
## and any content. The fields that Rev 2 added are meaningful only when
## `revision.major >= 2`; the `effective*` accessors apply that rule. The
## field names and byte numbers follow the spec notes.
##
## Rev 2.0 differs from 2.1 only in bytes 3507-3510: one u32 maximum number of
## additional trace headers, where 2.1 has a u16 count plus a u16 survey type.
## `decodeBinaryHeader` and `encode` branch on the revision bytes for that.

import ../common/[endians, fieldlayout, diagnostics]

const
  BinaryHeaderSize* = 400   ## Bytes in the binary file header.
  BinaryHeaderFirstByte = 3201

type
  SegyRevision* = object
    ## SEG-Y revision from bytes 3501 (major) and 3502 (minor). 0.0 is the
    ## traditional 1975 format.
    major*, minor*: uint8

  SegyBinaryHeader* = object
    ## The binary file header. Each field carries its spec byte number.
    jobId* {.at: 3201.}: int32
    lineNumber* {.at: 3205.}: int32
    reelNumber* {.at: 3209.}: int32
    dataTracesPerEnsemble* {.at: 3213.}: int16
    auxTracesPerEnsemble* {.at: 3215.}: int16
    sampleInterval* {.at: 3217.}: uint16       ## µs (time), Hz or m/ft; primary trace set.
    sampleIntervalOrig* {.at: 3219.}: uint16   ## Of the original field recording.
    samplesPerTrace* {.at: 3221.}: uint16      ## Primary trace set.
    samplesPerTraceOrig* {.at: 3223.}: uint16  ## Of the original field recording.
    formatCode* {.at: 3225.}: int16            ## Data sample format code.
    ensembleFold* {.at: 3227.}: int16
    traceSorting* {.at: 3229.}: int16          ## 6 = common receiver point.
    verticalSumCode* {.at: 3231.}: int16
    sweepFreqStart* {.at: 3233.}: int16        ## Hz.
    sweepFreqEnd* {.at: 3235.}: int16          ## Hz.
    sweepLength* {.at: 3237.}: int16           ## ms.
    sweepType* {.at: 3239.}: int16
    sweepChannel* {.at: 3241.}: int16
    sweepTaperStart* {.at: 3243.}: int16       ## ms.
    sweepTaperEnd* {.at: 3245.}: int16         ## ms.
    taperType* {.at: 3247.}: int16
    correlated* {.at: 3249.}: int16            ## 1 = no, 2 = yes.
    binaryGainRecovered* {.at: 3251.}: int16   ## 1 = yes, 2 = no.
    amplitudeRecovery* {.at: 3253.}: int16
    measurementSystem* {.at: 3255.}: int16     ## 1 = meters, 2 = feet.
    impulsePolarity* {.at: 3257.}: int16
    vibratoryPolarity* {.at: 3259.}: int16
    extDataTracesPerEnsemble* {.at: 3261.}: uint32 ## Rev 2: overrides 3213 if non-zero.
    extAuxTracesPerEnsemble* {.at: 3265.}: uint32  ## Rev 2: overrides 3215 if non-zero.
    extSamplesPerTrace* {.at: 3269.}: uint32       ## Rev 2: overrides 3221 if non-zero.
    extSampleInterval* {.at: 3273.}: float64       ## Rev 2: overrides 3217 if non-zero.
    extSampleIntervalOrig* {.at: 3281.}: float64   ## Rev 2: overrides 3219 if non-zero.
    extSamplesPerTraceOrig* {.at: 3289.}: uint32   ## Rev 2: overrides 3223 if non-zero.
    extEnsembleFold* {.at: 3293.}: uint32          ## Rev 2: overrides 3227 if non-zero.
    byteOrderMarker* {.at: 3297.}: uint32
      ## Rev 2: 0x01020304 written in the file's byte order; 0 before Rev 2.
    unassigned1* {.at: 3301.}: array[200, byte]
    segyMajor* {.at: 3501.}: uint8
    segyMinor* {.at: 3502.}: uint8
    fixedLengthTraces* {.at: 3503.}: int16     ## 1 = every trace has the file's ns and dt.
    numExtTextHeaders* {.at: 3505.}: int16     ## -1 = variable, ended by EndText.
    maxAddlTraceHeaders*: uint32
      ## Maximum additional 240-byte trace headers per trace: u16 at 3507 in
      ## Rev 2.1, u32 at 3507-3510 in Rev 2.0.
    surveyType*: uint16                        ## Rev 2.1, byte 3509; 0 in Rev 2.0.
    timeBasisCode* {.at: 3511.}: int16
    numTraces* {.at: 3513.}: uint64            ## Rev 2: 0 = unknown.
    firstTraceOffset* {.at: 3521.}: uint64     ## Rev 2: 0 = unknown.
    numTrailerRecords* {.at: 3529.}: int32     ## Rev 2: -1 = unknown.
    unassigned2* {.at: 3533.}: array[68, byte]

const
  ByteOrderMarker* = 0x0102_0304'u32 ## Value of bytes 3297-3300 in every byte order.
  binaryHeaderFields* = fieldTable(SegyBinaryHeader)
    ## Layout of the `at` fields. 3507-3510 are handled separately.

func revision*(h: SegyBinaryHeader): SegyRevision {.inline.} =
  SegyRevision(major: h.segyMajor, minor: h.segyMinor)

func `revision=`*(h: var SegyBinaryHeader, r: SegyRevision) {.inline.} =
  h.segyMajor = r.major
  h.segyMinor = r.minor

func `==`*(a, b: SegyRevision): bool {.inline.} = a.major == b.major and a.minor == b.minor

func `<`*(a, b: SegyRevision): bool {.inline.} =
  a.major < b.major or (a.major == b.major and a.minor < b.minor)

func `<=`*(a, b: SegyRevision): bool {.inline.} = not (b < a)

func `$`*(r: SegyRevision): string = $r.major & "." & $r.minor

func isRev20(h: SegyBinaryHeader): bool {.inline.} = h.segyMajor == 2 and h.segyMinor == 0

func decodeBinaryHeader*(b: openArray[byte], order: ByteOrder): SegyBinaryHeader =
  ## Decodes a binary header from the first 400 bytes of `b` (file offset
  ## 3200), with numbers in `order`.
  doAssert b.len >= BinaryHeaderSize, "binary header needs 400 bytes"
  decodeFields(result, b, BinaryHeaderFirstByte, order)
  if result.isRev20:
    result.maxAddlTraceHeaders = getNum[uint32](b, 3507 - BinaryHeaderFirstByte, order)
  else:
    result.maxAddlTraceHeaders = getNum[uint16](b, 3507 - BinaryHeaderFirstByte, order)
    result.surveyType = getNum[uint16](b, 3509 - BinaryHeaderFirstByte, order)

func encode*(h: SegyBinaryHeader, b: var openArray[byte], order: ByteOrder) =
  ## Writes `h` to the first 400 bytes of `b`, with numbers in `order`.
  ## `maxAddlTraceHeaders` must fit in 16 bits unless the revision is 2.0
  ## (`validate` reports it).
  doAssert b.len >= BinaryHeaderSize, "binary header needs 400 bytes"
  encodeFields(h, b, BinaryHeaderFirstByte, order)
  if h.isRev20:
    putNum(b, 3507 - BinaryHeaderFirstByte, h.maxAddlTraceHeaders, order)
  else:
    doAssert h.maxAddlTraceHeaders <= high(uint16), "maxAddlTraceHeaders exceeds u16"
    putNum(b, 3507 - BinaryHeaderFirstByte, uint16(h.maxAddlTraceHeaders), order)
    putNum(b, 3509 - BinaryHeaderFirstByte, h.surveyType, order)

# ---------------------------------------------------------------------------
# Effective values: a Rev 2 extended field overrides its 16-bit field when
# it is non-zero.

template override(h: SegyBinaryHeader, ext, std: untyped): untyped =
  if h.segyMajor >= 2 and ext != 0: typeof(ext)(ext) else: typeof(ext)(std)

func effectiveSamplesPerTrace*(h: SegyBinaryHeader): uint32 =
  ## Samples per trace of the primary trace set.
  override(h, h.extSamplesPerTrace, h.samplesPerTrace)

func effectiveSampleInterval*(h: SegyBinaryHeader): float64 =
  ## Sample interval of the primary trace set (µs for time data).
  override(h, h.extSampleInterval, h.sampleInterval)

func effectiveSamplesPerTraceOrig*(h: SegyBinaryHeader): uint32 =
  override(h, h.extSamplesPerTraceOrig, h.samplesPerTraceOrig)

func effectiveSampleIntervalOrig*(h: SegyBinaryHeader): float64 =
  override(h, h.extSampleIntervalOrig, h.sampleIntervalOrig)

func effectiveDataTracesPerEnsemble*(h: SegyBinaryHeader): int64 =
  override(h, int64(h.extDataTracesPerEnsemble), h.dataTracesPerEnsemble)

func effectiveAuxTracesPerEnsemble*(h: SegyBinaryHeader): int64 =
  override(h, int64(h.extAuxTracesPerEnsemble), h.auxTracesPerEnsemble)

func effectiveEnsembleFold*(h: SegyBinaryHeader): int64 =
  override(h, int64(h.extEnsembleFold), h.ensembleFold)

func bytesPerSample*(formatCode: int, rev: SegyRevision): int =
  ## Bytes per sample of `formatCode` in revision `rev`, or 0 if the code is
  ## not defined there. Codes 6, 7 and 9-16 exist from Rev 2 on.
  case formatCode
  of 1, 2, 4, 5: 4
  of 3: 2
  of 8: 1
  of 10: (if rev.major >= 2: 4 else: 0)
  of 11: (if rev.major >= 2: 2 else: 0)
  of 7, 15: (if rev.major >= 2: 3 else: 0)
  of 6, 9, 12: (if rev.major >= 2: 8 else: 0)
  of 16: (if rev.major >= 2: 1 else: 0)
  else: 0

proc validate*(h: SegyBinaryHeader, log: var DiagLog, severity = sevWarning,
    loc = Location()) =
  ## Reports spec violations in `h` to `log` at `severity`: readers use
  ## warnings, writers use errors. `loc` supplies the file name and record.
  ## Offsets are absolute file offsets of the fields.
  template check(cond: bool, code: DiagCode, specByte: int, fieldName, msg: string) =
    if not cond:
      var l = loc
      l.field = "binary." & fieldName
      log.report(severity, code, msg, offset = specByte - 1, loc = l)
  let rev = h.revision
  check rev.major <= 2 and (rev.major == 2 or rev.minor == 0), dcUnsupportedRevision, 3501,
    "segyRevision", "revision " & $rev & " is not defined"
  check bytesPerSample(h.formatCode, rev) != 0, dcBadValue, 3225, "formatCode",
    "format code " & $h.formatCode & " is not defined in revision " & $rev
  check h.effectiveSampleInterval != 0, dcBadValue, 3217, "sampleInterval",
    "sample interval is 0"
  check h.effectiveSamplesPerTrace != 0, dcBadValue, 3221, "samplesPerTrace",
    "samples per trace is 0"
  if rev.major >= 1:
    check h.fixedLengthTraces in 0..1, dcBadValue, 3503, "fixedLengthTraces",
      "fixed-length flag " & $h.fixedLengthTraces & " is not 0 or 1"
    check h.numExtTextHeaders >= -1, dcBadValue, 3505, "numExtTextHeaders",
      "extended textual header count " & $h.numExtTextHeaders & " is below -1"
  if rev.major >= 2:
    check h.byteOrderMarker == ByteOrderMarker, dcByteOrder, 3297, "byteOrderMarker",
      "byte-order marker is not 0x01020304 in the byte order used"
    check h.numTrailerRecords >= -1, dcBadValue, 3529, "numTrailerRecords",
      "trailer record count " & $h.numTrailerRecords & " is below -1"
    check h.isRev20 or h.maxAddlTraceHeaders <= high(uint16), dcBadValue, 3507,
      "maxAddlTraceHeaders", "additional trace header count " & $h.maxAddlTraceHeaders &
      " does not fit in 16 bits"
