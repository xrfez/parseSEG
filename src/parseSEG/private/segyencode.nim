## Encoding `TraceKeys` into SEG-Y trace headers: the one builder
## (`keysToHeaders`) behind the writer of traces built from keys
## (`model/writefile`) and the SEG-D/SEG-2 → SEG-Y conversion
## (`convert/tosegy`), so both write a key the same way and `openSeismic`
## reads it back; with the scalars and scaled values it is made of.

import std/[math, times]
import ../segy/[binheader, traceheader, reader]
import ../model/keytypes
import ./segykeys

func scalarFor*(values: openArray[float64]): int16 =
  ## The finest coordinate scalar (-1000, -100, -10, 1) whose scaled values
  ## fit in int32; NaN values are ignored.
  for s in [-1000'i16, -100, -10, 1]:
    let mult = if s < 0: float64(-s) else: 1.0
    var fits = true
    for v in values:
      if not v.isNaN and abs(round(v * mult)) > 2147483647.0: fits = false
    if fits: return s
  1

func clampI16*(x: float64): int16 =
  ## `x` rounded and clamped to int16 (0 for NaN).
  if x.isNaN: 0'i16 else: int16(clamp(round(x), -32768.0, 32767.0))

func clampI32*(x: float64): int32 =
  ## `x` rounded and clamped to int32 (0 for NaN).
  if x.isNaN: 0'i32 else: int32(clamp(round(x), -2147483648.0, 2147483647.0))

func scaled*(v: float64, scalar: int16): int32 =
  ## `v` as stored with SEG-Y scalar `scalar` (0 for NaN).
  if v.isNaN: 0'i32
  else: clampI32(v * (if scalar < 0: float64(-scalar) else: 1.0 / float64(max(scalar, 1))))

proc setGeometry*(h: var SegyTraceHeader, k: TraceKeys, datum = NaN) =
  ## Coordinates, elevations (and `datum` as both datum elevations) and
  ## offset, with the finest scalars that fit.
  h.coordinateScalar = scalarFor([k.srcX, k.srcY, k.rcvX, k.rcvY, k.cmpX, k.cmpY])
  h.sourceX = scaled(k.srcX, h.coordinateScalar)
  h.sourceY = scaled(k.srcY, h.coordinateScalar)
  h.groupX = scaled(k.rcvX, h.coordinateScalar)
  h.groupY = scaled(k.rcvY, h.coordinateScalar)
  h.cdpX = scaled(k.cmpX, h.coordinateScalar)
  h.cdpY = scaled(k.cmpY, h.coordinateScalar)
  if k.hasSourceXY or k.hasReceiverXY: h.coordinateUnits = 1
  h.elevationScalar = scalarFor([k.srcZ, k.rcvZ, datum])
  h.receiverElevation = scaled(k.rcvZ, h.elevationScalar)
  h.sourceSurfaceElevation = scaled(k.srcZ, h.elevationScalar)
  h.receiverDatumElevation = scaled(datum, h.elevationScalar)
  h.sourceDatumElevation = scaled(datum, h.elevationScalar)
  if not k.offset.isNaN: h.offset = clampI32(k.offset)

func timeScalarFor*(ms: openArray[float64]): int16 =
  ## The time scalar (trace bytes 215-216) with which every time of `ms`
  ## (NaN is ignored) fits the int16 fields of bytes 95-114 most exactly:
  ## 1 when all are whole ms (to 1 ns: float noise such as 4.0000000001 is
  ## whole), so readers that ignore the scalar still read them; else the
  ## finest of -1000, -100, -10 that holds them all; 10, 100, 1000 for times
  ## past 32767 ms.
  template all(cond: untyped): bool =
    var yes = true
    for x {.inject.} in ms:
      if not x.isNaN and not cond: yes = false
    yes
  if all(abs(x - round(x)) < 1e-6 and abs(round(x)) <= 32767): return 1
  for s in [-1000'i16, -100, -10]:
    if all(abs(round(x * float64(-s))) <= 32767): return s
  if all(abs(x) <= 32767): return 1
  for s in [10'i16, 100, 1000]:
    if all(abs(round(x / float64(s))) <= 32767): return s
  1000

func scaledTime*(ms: float64, scalar: int16): int16 =
  ## `ms` as a time field of trace bytes 95-114 holds it with time scalar
  ## `scalar` (0 for NaN; clamped to int16).
  int16(clamp(scaled(ms, scalar), -32768, 32767))

func wholeInterval*(us: float64): float64 =
  ## `us` as the whole number it is to 1e-9 of its value, else unchanged: an
  ## interval kept in another unit and converted back (ms × 1000, s × 1e6)
  ## is 1000.9999999999999 for 1001 µs, which the 16-bit fields would refuse
  ## or cut.
  if abs(us - round(us)) <= 1e-9 * us: round(us) else: us

func toInterval(us: float64): uint16 =
  # `us` rounded and clamped to the 16-bit interval field (0 for NaN).
  if us >= 65535: high(uint16) elif us >= 0: uint16(round(us)) else: 0

proc keysToHeaders*(t: var SegyTrace, k: TraceKeys, n, seqNo: int, rev: SegyRevision,
    ext1: bool, timeScalar = 0'i16, datum = NaN) =
  ## Sets the headers of `t` to hold `k` in the standard layout of `rev`,
  ## for trace number `seqNo` (1-based) of `n` samples; with Trace Header
  ## Extension 1 when `ext1` (Rev 2). What each key becomes is described at
  ## `writeTrace(w, keys, samples)`; the converters then add the fields
  ## that are not keys.
  ##
  ## `timeScalar` is the scalar of the times in bytes 95-114 (Rev 1 and
  ## later) when the caller stores more times than `t0Ms` there; 0 picks
  ## the one that suits `t0Ms`. `datum` goes into both datum elevations.
  ## Never raises: values a field cannot hold are rounded and clamped, an
  ## interval that is NaN is written as 0, and a count over 65535 without
  ## `ext1` as 0 (callers refuse or skip those).
  t.header = SegyTraceHeader(traceSeqLine: int32(min(seqNo, int(high(int32)))),
    traceSeqFile: int32(min(seqNo, int(high(int32)))))
  template h: untyped = t.header
  if not k.record.isNaN: h.fieldRecord = clampI32(k.record)
  if not k.channel.isNaN: h.traceNumberInField = clampI32(k.channel)
  if not k.ensemble.isNaN: h.ensembleNumber = clampI32(k.ensemble)
  h.traceIdCode =
    # The stored code when it says what the status says (a status changed
    # in the keys, e.g. a trace killed, wins over the input's code).
    # `component` is not used: for SEG-D, SEG-2 and survey keys it is a
    # group index or sensor type, not a SEG-Y code (a SEG-Y input's code is
    # in `traceCode`).
    if k.traceCode != 0 and segyStatus(k.traceCode, int(rev.major)) == k.status: k.traceCode
    else:
      case k.status
      of tsLive: 1
      of tsDead: 2
      of tsUnknown, tsAuxiliary: 0
  if not k.srcPoint.isNaN:
    # Readers take the energy source point when non-zero, else the scaled
    # shotpoint (Rev 1): a fractional point goes in the second alone.
    let whole = k.srcPoint == round(k.srcPoint)
    if whole or rev.major == 0: h.energySourcePoint = clampI32(k.srcPoint)
    if rev.major >= 1:
      h.shotpointScalar = if whole: 1 else: -100
      h.shotpointNumber = scaled(k.srcPoint, h.shotpointScalar)
  h.setGeometry(k, datum)
  if rev.major == 0:
    # Bytes 181-240 are unassigned in Rev 0: the midpoint has no field.
    h.cdpX = 0
    h.cdpY = 0
    h.delayRecordingTime = clampI16(k.t0Ms)
  elif timeScalar != 0 or not k.t0Ms.isNaN:
    h.timeScalar = if timeScalar != 0: timeScalar else: timeScalarFor([k.t0Ms])
    h.delayRecordingTime = scaledTime(k.t0Ms, h.timeScalar)
  let dt = wholeInterval(k.intervalUs)
  let whole = dt == round(dt) and dt >= 0 and dt <= 65535
  h.sampleInterval = if whole or rev.major < 2: toInterval(dt) else: 0
  h.numSamples = if n > int(high(uint16)): 0'u16 else: uint16(n)
  if rev.major >= 1:
    if not k.inline.isNaN: h.inlineNumber = clampI32(k.inline)
    if not k.crossline.isNaN: h.crosslineNumber = clampI32(k.crossline)
  var nanos = 0'i32
  if not k.time.isNaN and k.time > -62135596800.0 and k.time < 253402300800.0:
    let whole = floor(k.time)
    let d = fromUnix(int64(whole)).utc
    h.year = int16(d.year)
    h.dayOfYear = int16(d.yearday + 1)
    h.hour = int16(d.hour)
    h.minute = int16(d.minute)
    h.second = int16(d.second)
    h.timeBasisCode = 4 # UTC
    nanos = int32(min(round((k.time - whole) * 1e9), 999_999_999.0))
  t.hasExt1 = ext1
  t.proprietary.setLen 0
  if ext1:
    t.ext1 = initTraceHeaderExt1()
    template x: untyped = t.ext1
    x.numAddlTraceHeaders = 1
    x.extTraceSeqLine = uint64(seqNo)
    x.extTraceSeqFile = uint64(seqNo)
    if not k.record.isNaN: x.extFieldRecord = int64(clamp(round(k.record), -9.2e18, 9.2e18))
    if not k.ensemble.isNaN: x.extEnsembleNumber = int64(clamp(round(k.ensemble), -9.2e18, 9.2e18))
    if n > int(high(uint16)): x.extNumSamples = uint32(n)
    if h.sampleInterval == 0 and dt > 0: x.extSampleInterval = dt
    x.nanoseconds = nanos
    template f64(dst: untyped, v: float64) =
      if not v.isNaN: dst = v
    f64(x.extSourceX, k.srcX)
    f64(x.extSourceY, k.srcY)
    f64(x.extGroupX, k.rcvX)
    f64(x.extGroupY, k.rcvY)
    f64(x.extCdpX, k.cmpX)
    f64(x.extCdpY, k.cmpY)
    f64(x.extOffset, k.offset)
    f64(x.extReceiverElevation, k.rcvZ)
    f64(x.extSourceSurfaceElevation, k.srcZ)

func declaredSamples*(t: SegyTrace): int =
  ## The sample count the trace's own headers give: Trace Header Extension 1
  ## bytes 137-140 when non-zero, else trace bytes 115-116.
  if t.hasExt1 and t.ext1.extNumSamples != 0: int(t.ext1.extNumSamples)
  else: int(t.header.numSamples)

func setSampleCount*(t: var SegyTrace, n: int): bool =
  ## Sets the sample count in the trace's headers: in Trace Header Extension
  ## 1 when that holds the count or `n` exceeds 65535, and in bytes 115-116
  ## (0 when it does not fit). False, with nothing changed, when `n` needs an
  ## Extension 1 the trace lacks.
  if t.hasExt1 and (t.ext1.extNumSamples != 0 or n > int(high(uint16))):
    t.ext1.extNumSamples = uint32(n)
  elif n > int(high(uint16)):
    return false
  t.header.numSamples = if n > int(high(uint16)): 0'u16 else: uint16(n)
  true
