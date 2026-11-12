## Encoding geometry into SEG-Y trace headers: the scalars and scaled
## values shared by the SEG-D/SEG-2 → SEG-Y conversion (`convert/tosegy`)
## and the writer of traces built from `TraceKeys` (`model/writefile`).

import std/math
import ../segy/[traceheader, reader]
import ../model/keytypes

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

func clampI16*(x: float64): int16 = int16(clamp(round(x), -32768.0, 32767.0))
  ## `x` rounded and clamped to int16.

func clampI32*(x: float64): int32 = int32(clamp(round(x), -2147483648.0, 2147483647.0))
  ## `x` rounded and clamped to int32.

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
