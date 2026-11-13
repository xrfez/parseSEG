## IBM System/360 hexadecimal floating point (SEG-Y sample format 1).
##
## Layout (32 bits, big-endian): sign bit 31, 7-bit excess-64 base-16
## exponent in bits 30-24, 24-bit fraction in bits 23-0.
## value = (-1)^sign * 0.fraction * 16^(exponent - 64).

import std/[math, os]
import ./endians

func ldexp(x: float64, e: cint): float64 {.importc: "ldexp", header: "<math.h>".}

func ibmScales(): array[256, float64] =
  # The value of fraction 1 for each sign-and-exponent byte:
  # (-1)^sign * 16^(exponent - 64) * 2^-24, a power of two that float64 holds
  # exactly (2^-280 .. 2^228).
  # Built by halving and doubling (exact), so it also runs at compile time.
  for b in 0..255:
    let e = 4 * ((b and 0x7F) - 64) - 24
    var m = 1.0
    for _ in 1..abs(e): m = if e < 0: m * 0.5 else: m * 2
    result[b] = if (b and 0x80) != 0: -m else: m

const ibmScale = ibmScales()

func ibmToFloat64*(bits: uint32): float64 {.inline.} =
  ## Converts IBM float bits to IEEE double, exactly (every IBM single fits).
  ## A zero fraction (any sign or exponent) gives +0.
  let frac = bits and 0x00FF_FFFF'u32
  # The fraction (24 bits) converts exactly; scaling by a power of two is
  # exact in float64's range. One table load and one multiply: no branch on
  # the data except for zero, which keeps +0 for a negative zero.
  if frac == 0: 0.0 else: float64(frac) * ibmScale[bits shr 24]

func ibmToFloat32*(bits: uint32): float32 {.inline.} =
  ## Converts IBM float bits to the nearest IEEE single. Magnitudes beyond
  ## float32 range become +/-Inf; tiny values round to subnormals or zero.
  # The exact float64 value, rounded once to float32.
  float32(ibmToFloat64(bits))

func ibmToFloat32Fast*(bits: uint32): float32 {.inline.} =
  ## `ibmToFloat32` bit for bit, without a branch or a table and in single
  ## precision, so that a loop over it vectorizes 8 wide with AVX2
  ## (`decodeIbm32`). The value is fraction × 2^k with k = 4·exponent − 280,
  ## made as two multiplies by powers of two: the first (2^k1, k1 in
  ## −125 .. 102) is exact, a 24-bit integer times a power of two that stays
  ## normal; the second (2^k2, k2 = k − k1) rounds once, and only when the
  ## result is subnormal or overflows to infinity. k2 stops at −126, the
  ## smallest scale that is a normal number: that is reached for k below
  ## −251 only, where the value is under 2^−227 and rounds to 0 either way.
  ## The sign rides on the first scale and is dropped for a zero fraction
  ## (+0, as `ibmToFloat64`).
  let frac = bits and 0x00FF_FFFF'u32
  let k = 4'i32 * cast[int32]((bits shr 24) and 0x7F'u32) - 280'i32
  let k1 = max(-125'i32, min(k, 102'i32))
  let k2 = max(k - k1, -126'i32)
  let sign = (bits shr 31) and uint32(frac != 0)
  let f1 = cast[float32]((cast[uint32](k1 + 127'i32) shl 23) or (sign shl 31))
  let f2 = cast[float32](cast[uint32](k2 + 127'i32) shl 23)
  (float32(cast[int32](frac)) * f1) * f2

const cpuHeader = currentSourcePath().parentDir / "cpu.h"
let avx2Target {.importc: "PARSESEG_AVX2", header: cpuHeader.}: cint
  # 1 when the C compiler targets AVX2 (`-march=x86-64-v3`, or native on
  # such a CPU), else 0: a C constant, so the branch below folds away.

template decodeIbm32*(d: ptr UncheckedArray[float32], n: int, word: untyped) =
  ## `d[i] = ibmToFloat32(word(i))` for `i` in `0 ..< n`, where `word(i)` is
  ## the IBM float bits of sample `i` (an unchecked load). When the C
  ## compiler targets AVX2 the loop runs `ibmToFloat32Fast`, 8 samples at a
  ## time: 6.3 -> 13 GB/s on a file of IBM floats (Zen 2, x86-64-v3). A
  ## baseline SSE2 build keeps the table (5.3 GB/s): the same kernel is 3
  ## times slower there (1.8 GB/s) without 32-bit `max`/`min` and variable
  ## shifts. Both give the same bits.
  if avx2Target != 0:
    for i in 0 ..< n: d[i] = ibmToFloat32Fast(word(i))
  else:
    for i in 0 ..< n: d[i] = ibmToFloat32(word(i))

func float32ToIbm*(x: float32): uint32 =
  ## Converts an IEEE single to IBM float bits with round-to-nearest.
  ## Every finite float32 fits in the IBM range. Infinities clamp to the
  ## largest IBM magnitude and NaN encodes as zero. Zero encodes as 0
  ## (the sign is dropped).
  let sign = if signbit(x): 0x8000_0000'u32 else: 0'u32
  case classify(x)
  of fcZero, fcNegZero, fcNan:
    result = 0
  of fcInf, fcNegInf:
    result = sign or 0x7FFF_FFFF'u32
  of fcNormal, fcSubnormal:
    # |x| = m * 2^e with 0.5 <= m < 1. Pick base-16 exponent e16 = ceil(e/4);
    # then the 24-bit fraction is m * 2^(24 - (4*e16 - e)).
    let (m, e) = frexp(abs(float64(x)))
    var e16 = (e + 3 + 256) div 4 - 64          # ceil(e / 4) for negative e too
    var frac = uint32(round(ldexp(m, cint(24 - (4 * e16 - e)))))
    if frac == 0x0100_0000'u32:                  # rounding carried out
      frac = frac shr 4
      inc e16
    result = sign or (uint32(e16 + 64) shl 24) or frac

func normalToIbm*(bits: uint32): uint32 {.inline, raises: [].} =
  ## `float32ToIbm` of the normal float32 with the bits `bits` (not zero,
  ## subnormal, infinite or NaN), in integer arithmetic: the sample
  ## encoders' kernel (17 ns per sample through frexp, ldexp and round, 0.4
  ## this way). With the value 0.1mmm... x 2^(e - 126), the base-16 exponent
  ## is ceil((e - 126) / 4) and the 24-bit mantissa moves right by the 0..3
  ## bits that takes, rounded half up, as `round` does for a magnitude. A
  ## carry cannot happen: the mantissa is below 2^24 and loses bits whenever
  ## it is rounded.
  let t = ((bits shr 23) and 0xFF) + 133 # excess-64 exponent x 4, plus 3 - shift
  let shift = 3 - (t and 3)
  let mant = (bits and 0x7F_FFFF'u32) or 0x80_0000'u32
  (bits and 0x8000_0000'u32) or ((t shr 2) shl 24) or
    ((mant + ((1'u32 shl shift) shr 1)) shr shift)

func float64ToIbm*(x: float64, bits: var uint32, fractionBits = 24): bool =
  ## Converts an IEEE double of any magnitude to IBM float bits in `bits`,
  ## the fraction rounded to nearest at `fractionBits` bits (24; 23 leaves
  ## the last fraction bit 0, as SEG-D format 8048 has it). False, with
  ## `bits` unchanged, for NaN, an infinity and a magnitude beyond the
  ## largest the format holds (about 7.237e75); a magnitude below the
  ## smallest gives 0. The sample encoders use it for the doubles beyond
  ## float32's range: within it they write `float32ToIbm(float32(x))`.
  case classify(x)
  of fcNan, fcInf, fcNegInf:
    result = false
  of fcZero, fcNegZero:
    bits = 0
    result = true
  of fcNormal, fcSubnormal:
    # As `float32ToIbm`, on the double itself.
    let (m, e) = frexp(abs(x))
    var e16 = (e + 3 + 4096) div 4 - 1024 # ceil(e / 4)
    var frac = uint32(round(ldexp(m, cint(fractionBits - (4 * e16 - e))))) shl
      (24 - fractionBits)
    if frac == 0x0100_0000'u32: # rounding carried out
      frac = frac shr 4
      inc e16
    result = e16 <= 63
    if e16 < -64: bits = 0
    elif result:
      bits = (if x < 0: 0x8000_0000'u32 else: 0'u32) or (uint32(e16 + 64) shl 24) or frac

func ibmF32*(b: openArray[byte], pos: int): float32 {.inline.} =
  ## Reads an IBM float at byte offset `pos`.
  ibmToFloat32(beU32(b, pos))

func putIbmF32*(b: var openArray[byte], pos: int, v: float32) {.inline.} =
  ## Writes `v` as an IBM float at byte offset `pos`.
  putBeU32(b, pos, float32ToIbm(v))
