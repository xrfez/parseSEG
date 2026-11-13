## The sample encoders (unchecked stores, a static byte order, native-order
## copies, the integer IBM kernel, exponents from the float's bits) against
## the plain encoders they replaced (`utils/refencode`): the same bytes for
## every format, byte order and input type, and the same refusals, on
## random and edge values.

import std/[assertions, math, random]
import parseSEG/common/[endians, ibmfloat, errors]
import parseSEG/segy/samples
import parseSEG/segd/samples as segdsamples
import parseSEG/seg2/samples as seg2samples
import ./utils/refencode

var rng = initRand(2611)

const Lengths = [0, 1, 2, 3, 4, 5, 7, 8, 64, 1001]

proc values(kind, n: int): seq[float64] =
  ## Trace-like sets: small and wide integers, float32 and float64 noise,
  ## values around each format's limits, and values no format refuses.
  const edges = [0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 2.5, -2.5, 127.0, 127.5, -128.0, -128.5, 255.0,
    255.5, 3839.9, -3840.0, 3968.0, 4095.0, -4095.0, 4095.5, 15360.0, -15360.0, 16380.0, 32767.0,
    -32767.0, 32767.4, -32768.0, 32767.5, 65535.0, 65535.5, 8388607.0, -8388608.0, 16777215.0,
    2147483647.0, -2147483648.0, 4294967295.0, 0.49999999999999994, 1e-30, -1e-30, 1e-300,
    9.2e18, -9.2e18, 1.8e19]
  for i in 0 ..< n:
    result.add case kind
      of 0: float64(rng.rand(-130..130))
      of 1: float64(rng.rand(-33000..33000))
      of 2: float64(rng.rand(-3_000_000_000'i64..5_000_000_000'i64))
      of 3: float64(float32(rng.gauss(0, 1000)))
      of 4: rng.gauss(0, 1e6)
      of 5: rng.gauss(0, 3000) # the SEG-D exponent formats' ranges
      of 6: rng.rand(-1.0..1.0) * pow(2.0, float64(rng.rand(-20..12)))
      of 7: float64(rng.rand(0..255))
      else: edges[rng.rand(edges.high)]

const Refused = [NaN, Inf, NegInf, 1e39, -1e39, 1e76, -1e300]
  ## What some formats cannot hold, mixed into otherwise fine traces.

proc same[T](what: string, vals: seq[float64], newEnc, oldEnc: proc (src: openArray[T],
    dst: var openArray[byte]), bytes: int) =
  ## `newEnc` and `oldEnc` give the same bytes for `vals`, or raise the same error.
  var src = newSeq[T](vals.len)
  for i, v in vals: src[i] = T(v)
  var a = newSeq[byte](bytes + 3)
  var b = newSeq[byte](bytes + 3)
  for x in a.mitems: x = 0xA5
  for x in b.mitems: x = 0xA5
  var ea, eb = ""
  try: newEnc(src, a)
  except SegFormatError as e: ea = e.msg
  try: oldEnc(src, b)
  except SegFormatError as e: eb = e.msg
  doAssert ea == eb, what & ": raised '" & ea & "', the reference '" & eb & "'"
  if ea.len == 0:
    doAssert a == b, what & ": bytes differ (" & $vals.len & " samples)"
  else: # nothing beyond the trace is touched even then
    doAssert a[bytes .. ^1] == b[bytes .. ^1], what

proc sets(n: int): seq[seq[float64]] =
  for kind in 0..8: result.add values(kind, n)
  if n > 0:
    for bad in Refused: # one value some formats refuse, anywhere in the trace
      var v = values(3, n)
      v[rng.rand(n - 1)] = bad
      result.add v

block segy_encoders_match_the_reference:
  for f in definedSampleFormats:
    for order in ByteOrder:
      if not (order == boPairSwapped and sampleSize(f) == 3):
        for n in Lengths:
          for vals in sets(n):
            let what = "SEG-Y " & $ord(f) & " " & $order
            same[float64](what & " f64", vals,
              proc (s: openArray[float64], d: var openArray[byte]) = encodeSamples(f, s, d, order),
              proc (s: openArray[float64], d: var openArray[byte]) = refEncodeSegy(f, s, d, order),
              n * sampleSize(f))
            same[float32](what & " f32", vals,
              proc (s: openArray[float32], d: var openArray[byte]) = encodeSamples(f, s, d, order),
              proc (s: openArray[float32], d: var openArray[byte]) = refEncodeSegy(f, s, d, order),
              n * sampleSize(f))
  var b = newSeq[byte](8)
  doAssertRaises SegFormatError: encodeSamples(sfInt24, [1.0], b, boPairSwapped)
  doAssertRaises ValueError: encodeSamples(sfInt64, [1.0, 2.0], b.toOpenArray(0, 6))

block segd_encoders_match_the_reference:
  for f in segdSampleFormats:
    for twos in (if f == sd8015: @[false, true] else: @[false]):
      for n in Lengths:
        for vals in sets(n):
          let what = "SEG-D " & $ord(f) & (if twos: " two's complement" else: "")
          same[float64](what & " f64", vals,
            proc (s: openArray[float64], d: var openArray[byte]) = encodeSamples(f, s, d, twos),
            proc (s: openArray[float64], d: var openArray[byte]) = refEncodeSegd(f, s, d, twos),
            dataBytes(f, n))
          same[float32](what & " f32", vals,
            proc (s: openArray[float32], d: var openArray[byte]) = encodeSamples(f, s, d, twos),
            proc (s: openArray[float32], d: var openArray[byte]) = refEncodeSegd(f, s, d, twos),
            dataBytes(f, n))

block segd_exponent_formats_over_their_whole_range:
  # Values the formats hold, of every binary order from 2^-40 to full scale,
  # with those that sit on an exponent step or round up to one: the exponent
  # taken from the float's bits against the reference's search with `pow`.
  for (f, most, least) in [(sd8015, 32767.0, -32767.0), (sd8022, 15360.0, -15360.0),
      (sd8024, 16380.0, -16380.0), (sd8042, 3968.0, -3840.0), (sd8044, 4095.5, -4095.0)]:
    var vals: seq[float64]
    for e in -40 .. 15:
      let step = pow(2.0, float64(e))
      for m in [1.0, 1.0 - 1e-16, 1.0 + 3e-16, 0.99999, 0.999985, 0.96875, 0.9999, 0.75, 0.5,
          1.5, 1.9999999, 1.99996, 1.9, 1.25, 1.0001]:
        for sign in [1.0, -1.0]: vals.add sign * m * step
    for _ in 0 ..< 60_000:
      vals.add rng.rand(-1.0..1.0) * pow(2.0, float64(rng.rand(-30..15)))
    for edge in [most, least, most - 0.25, least + 0.25, 0.0, -0.0, 4.9e-324, -1e-310]:
      vals.add edge
    var kept: seq[float64]
    for v in vals:
      if v <= most and v >= least: kept.add v
    doAssert kept.len > 40_000
    for twos in (if f == sd8015: @[false, true] else: @[false]):
      for T in [0, 1]:
        var a = newSeq[byte](dataBytes(f, kept.len))
        var b = newSeq[byte](a.len)
        if T == 0:
          encodeSamples(f, kept, a, twos)
          refEncodeSegd(f, kept, b, twos)
        else:
          var k32 = newSeq[float32](kept.len)
          for i, v in kept: k32[i] = float32(v) # rounding cannot leave the range
          encodeSamples(f, k32, a, twos)
          refEncodeSegd(f, k32, b, twos)
        doAssert a == b, "SEG-D " & $ord(f) & (if twos: " two's complement" else: "") &
          (if T == 0: " f64" else: " f32")

block seg2_encoders_match_the_reference:
  for f in Seg2SampleFormat:
    for order in [boLittle, boBig]:
      for twos in (if f == s2Float20: @[false, true] else: @[false]):
        for n in Lengths:
          for vals in sets(n):
            let what = "SEG-2 " & $ord(f) & " " & $order & (if twos: " two's complement" else: "")
            same[float64](what & " f64", vals,
              proc (s: openArray[float64], d: var openArray[byte]) =
                encodeSamples(f, s, d, order, twos),
              proc (s: openArray[float64], d: var openArray[byte]) =
                refEncodeSeg2(f, s, d, order, twos),
              dataBytes(f, n))
            same[float32](what & " f32", vals,
              proc (s: openArray[float32], d: var openArray[byte]) =
                encodeSamples(f, s, d, order, twos),
              proc (s: openArray[float32], d: var openArray[byte]) =
                refEncodeSeg2(f, s, d, order, twos),
              dataBytes(f, n))

block ibm_kernel_matches_float32ToIbm_on_every_kind_of_float32:
  # Format 1 and SEG-D 8048 through the encoders, against `float32ToIbm`
  # itself: random bit patterns (2 M), and every exponent with the mantissas
  # that round, carry or sit on a tie.
  const Count = 4096
  var x = newSeq[float32](Count)
  var got = newSeq[byte](4 * Count)
  var checked = 0
  proc check(what: string) =
    encodeSamples(sfIbm32, x, got, boBig)
    for i in 0 ..< Count:
      doAssert beU32(got, 4 * i) == float32ToIbm(x[i]), what & ": " & $x[i] & " (bits " &
        $cast[uint32](x[i]) & ")"
    encodeSamples(sfIbm32, x, got, boLittle)
    for i in 0 ..< Count: doAssert getNum[uint32](got, 4 * i, boLittle) == float32ToIbm(x[i])
    checked += Count
  for round in 0 ..< 500:
    for i in 0 ..< Count:
      var bits = uint32(rng.rand(int(high(uint32))))
      if ((bits shr 23) and 0xFF) == 0xFF: bits = bits and 0xBFFF_FFFF'u32 # no NaN, no infinity
      x[i] = cast[float32](bits)
    check("random")
  const mantissas = [0'u32, 1, 2, 3, 4, 5, 6, 7, 8, 0xF, 0x10, 0x7F_FFF8, 0x7F_FFF9, 0x7F_FFFA,
    0x7F_FFFB, 0x7F_FFFC, 0x7F_FFFD, 0x7F_FFFE, 0x7F_FFFF, 0x40_0000, 0x12_3456]
  var i = 0
  for e in 0'u32..254'u32:
    for m in mantissas:
      for sign in [0'u32, 0x8000_0000'u32]:
        x[i mod Count] = cast[float32](sign or (e shl 23) or m)
        inc i
        if i mod Count == 0: check("edges")
  check("edges")
  doAssert checked > 2_000_000

echo "tfastencode: ok"
