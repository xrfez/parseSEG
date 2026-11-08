## IBM System/360 hexadecimal floating point (SEG-Y sample format 1).
##
## Layout (32 bits, big-endian): sign bit 31, 7-bit excess-64 base-16
## exponent in bits 30-24, 24-bit fraction in bits 23-0.
## value = (-1)^sign * 0.fraction * 16^(exponent - 64).

import std/math
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

func ibmF32*(b: openArray[byte], pos: int): float32 {.inline.} =
  ## Reads an IBM float at byte offset `pos`.
  ibmToFloat32(beU32(b, pos))

func putIbmF32*(b: var openArray[byte], pos: int, v: float32) {.inline.} =
  ## Writes `v` as an IBM float at byte offset `pos`.
  putBeU32(b, pos, float32ToIbm(v))
