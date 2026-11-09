## SEG-D sample codecs (task 4.2).

import std/[assertions, os, math, random]
import parseSEG/common/errors
import parseSEG/segd/samples
import parseSEG/model/tensors
import ./utils/testutils


proc decode1(f: SegdSampleFormat, b: openArray[byte], n: int): seq[float64] =
  result = newSeq[float64](n)
  decodeSegdSamples(f, b, result)

block codes:
  doAssert toSegdFormat(8058) == some(sd8058)
  doAssert dataBytes(toSegdFormat(8080).get, 3) == 24
  doAssert toSegdFormat(58).isNone and toSegdFormat(8016).isNone # multiplexed / undefined
  doAssert dataBytes(sd8015, 8) == 20 and dataBytes(sd8015, 5) == 20 and dataBytes(sd8036, 2) == 6

block bit_patterns:
  # 8015: exponents 1, 2, 3, 15; fractions +0.5, -0.5 (one's complement),
  # negative zero, the largest positive.
  let g = [0x12'u8, 0x3F, 0x40, 0x00, 0xBF, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF]
  let v = decode1(sd8015, g, 4)
  doAssert v[0] == 1.0 and v[1] == -2.0 and v[2] == 0.0
  doAssert v[3] == float64(0x7FFF) / 32768.0 * 32768.0
  # The same bytes read as two's complement differ by one LSB for negatives.
  var two = newSeq[float64](4)
  decodeSegdSamples(sd8015, g, two, twosComplement8015 = true)
  doAssert two[1] == -(0x4001.float64) / 32768.0 * 4.0 and two[2] == -1.0 / 32768.0 * 8.0
  # 8022: S=1 C=1 q=1110 -> -(0001)/16 * 4 = -0.25; S=0 C=2 q=1000 -> 0.5*16 = 8.
  doAssert decode1(sd8022, [0x9E'u8, 0x28], 2) == @[-0.25, 8.0]
  # 8024: S=0 C=0 q=0x800 -> 0.5; S=1 C=1 q=0x7FF -> -(0x800)/4096*4 = -2.
  doAssert decode1(sd8024, [0x08'u8, 0x00, 0x97, 0xFF], 2) == @[0.5, -2.0]
  # 8042: sign-magnitude; 0x30 = C1, q=16 -> 0.5*16 = 8; 0x90 -> -0.5.
  doAssert decode1(sd8042, [0x30'u8, 0x90], 2) == @[8.0, -0.5]
  # 8044: 0x3000 = C1, q=0x1000 -> 0.5*16 = 8; 0x9000 -> -0.5.
  doAssert decode1(sd8044, [0x30'u8, 0x00, 0x90, 0x00], 2) == @[8.0, -0.5]
  # 8048: IBM-like; C2 76 A0 00 = -118.625.
  doAssert decode1(sd8048, [0xC2'u8, 0x76, 0xA0, 0x00], 1) == @[-118.625]
  doAssert decode1(sd8036, [0xFF'u8, 0xFF, 0xFE], 1) == @[-2.0]
  doAssert decode1(sd8038, [0x80'u8, 0, 0, 0], 1) == @[-2147483648.0]
  doAssert decode1(sd8080, [0x40'u8, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18], 1) == @[PI]

block exact_values_round_trip:
  for f in segdSampleFormats:
    let exact = if f in {sd8036, sd8038, sd9036, sd9038}: @[0.0, 1.0, -1.0, 2.0, -2.0, 8.0, -8.0, 8388607.0]
                else: @[0.0, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0, 8.0, -8.0]
    var b = newSeq[byte](dataBytes(f, exact.len))
    encodeSegdSamples(f, exact, b)
    doAssert decode1(f, b, exact.len) == exact, $f

block quantization_is_stable:
  # Any value decodes to a representable one, which then round-trips exactly.
  var rng = initRand(42)
  for f in segdSampleFormats:
    var xs = newSeq[float64](64)
    for i in 0..<xs.len: xs[i] = rng.rand(-1000.0 .. 1000.0)
    var b = newSeq[byte](dataBytes(f, xs.len))
    encodeSegdSamples(f, xs, b)
    let ys = decode1(f, b, xs.len)
    var b2 = newSeq[byte](b.len)
    encodeSegdSamples(f, ys, b2)
    doAssert b2 == b, $f
    # Worst-case relative error: half an LSB of the smallest normalized
    # mantissa (1/base) for exponent formats; half a unit for integers.
    let rel = case f
      of sd8015: 0.5 / 32768 * 2
      of sd8022: 0.5 / 16 * 4
      of sd8024: 0.5 / 4096 * 4
      of sd8042: 0.5 / 32 * 16
      of sd8044: 0.5 / 8192 * 16
      of sd8048: 2e-6 # float32, then 24 -> 23-bit fraction: two roundings
      of sd8058, sd9058: 1e-7
      else: 0.0
    let absTol = if f in {sd8036, sd8038, sd9036, sd9038}: 0.5 else: 0.0
    for i in 0..<xs.len:
      doAssert abs(ys[i] - xs[i]) <= abs(xs[i]) * rel + absTol + 1e-12,
        $f & " " & $xs[i] & " " & $ys[i]

block rev31_little_endian:
  # The 90xx formats are the 80xx ones with their bytes reversed.
  doAssert toSegdFormat(9058) == some(sd9058) and sd9058.isLittleEndian
  doAssert bigEndianOf(sd9080) == sd8080 and bigEndianOf(sd8058) == sd8058
  doAssert dataBytes(sd9036, 2) == 6 and dataBytes(sd9080, 1) == 8 and prefersFloat64(sd9038)
  doAssert decode1(sd9036, [0xFE'u8, 0xFF, 0xFF], 1) == @[-2.0]
  doAssert decode1(sd9036, [0x01'u8, 0x02, 0x03], 1) == @[float64(0x030201)]
  doAssert decode1(sd9038, [0'u8, 0, 0, 0x80], 1) == @[-2147483648.0]
  doAssert decode1(sd9080, [0x18'u8, 0x2D, 0x44, 0x54, 0xFB, 0x21, 0x09, 0x40], 1) == @[PI]
  for (le, be) in [(sd9036, sd8036), (sd9038, sd8038), (sd9058, sd8058), (sd9080, sd8080)]:
    let xs = @[1.0, -2.0, 1000.0, -8388608.0]
    var a = newSeq[byte](dataBytes(le, xs.len))
    var b = newSeq[byte](a.len)
    encodeSegdSamples(le, xs, a)
    encodeSegdSamples(be, xs, b)
    let w = dataBytes(le, 1)
    for i in 0..<xs.len:
      for k in 0..<w: doAssert a[i * w + k] == b[i * w + w - 1 - k], $le

block refusals:
  var b = newSeq[byte](16)
  doAssertRaises SegFormatError: encodeSegdSamples(sd8036, [1e8], b)
  doAssertRaises SegFormatError: encodeSegdSamples(sd8022, [NaN], b)
  doAssertRaises SegFormatError: encodeSegdSamples(sd8048, [NaN], b)
  encodeSegdSamples(sd8058, [NaN], b) # IEEE holds NaN
  var one = [0.0]
  doAssertRaises SegTruncatedError: decodeSegdSamples(sd8058, [1'u8, 2], one)

block sample_63_into_tensor:
  let s = readFile(exampleDir / "63.sgd")
  var raw = newSeq[byte](s.len)
  for i, c in s: raw[i] = byte(c)
  var t = newTraceTensor[float32](1, 1000)
  t.decodeTrace(0, sd8058, raw.toOpenArray(340, raw.len - 1), 1000)
  doAssert abs(t[0, 0] - 0.1001'f32) < 1e-4 and abs(t[0, 1] - 0.0452'f32) < 1e-4
  var back = newSeq[byte](4000)
  t.encodeTrace(0, sd8058, back, 1000)
  doAssert back == raw[340 .. ^1]

block review_clamps:
  var b = newSeq[byte](8)
  encodeSegdSamples(sd8048, [1e300, 7.2370051e75], b)
  var v = newSeq[float64](2)
  decodeSegdSamples(sd8048, b, v)
  doAssert v[0] > 7.2e75 and v[1] > 7.2e75 # full scale, not 1/16 of it
  encodeSegdSamples(sd8042, [-1e9], b)
  doAssert b[0] != 0xFF # the all-ones code is invalid
  encodeSegdSamples(sd8044, [-1e9], b)
  doAssert not (b[0] == 0xFF and b[1] == 0xFF)
  decodeSegdSamples(sd8044, b, v.toOpenArray(0, 0))
  doAssert v[0] < -4000.0
