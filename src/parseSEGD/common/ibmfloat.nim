## IBM System/360 hexadecimal floating point (SEG-Y sample format 1).
##
## Layout (32 bits, big-endian): sign bit 31, 7-bit excess-64 base-16
## exponent in bits 30-24, 24-bit fraction in bits 23-0.
## value = (-1)^sign * 0.fraction * 16^(exponent - 64).

import std/math
import ./endians

func ldexp(x: float64, e: cint): float64 {.importc: "ldexp", header: "<math.h>".}

func ibmToFloat32*(bits: uint32): float32 =
  ## Converts IBM float bits to the nearest IEEE single. Magnitudes beyond
  ## float32 range become +/-Inf; tiny values round to subnormals or zero.
  let frac = bits and 0x00FF_FFFF'u32
  if frac == 0:
    result = 0'f32
  else:
    let expo = int((bits shr 24) and 0x7F) - 64
    let mag = ldexp(float64(frac), cint(4 * expo - 24))
    result = float32(if (bits and 0x8000_0000'u32) != 0: -mag else: mag)

func ibmToFloat64*(bits: uint32): float64 =
  ## Converts IBM float bits to IEEE double, exactly (every IBM single fits).
  let frac = bits and 0x00FF_FFFF'u32
  if frac == 0:
    result = 0.0
  else:
    let expo = int((bits shr 24) and 0x7F) - 64
    let mag = ldexp(float64(frac), cint(4 * expo - 24))
    result = if (bits and 0x8000_0000'u32) != 0: -mag else: mag

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
