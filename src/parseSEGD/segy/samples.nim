## SEG-Y sample codecs on byte buffers (spec notes `segy_rev1.md` §5,
## `segy_rev2_1.md` §5).
##
## Decoders convert stored samples to `float32` or `float64` in a
## caller-provided buffer (e.g. a Tensor row), with no intermediate `seq`.
## Encoders convert back and refuse values that do not fit the format. This
## module has no Arraymancer dependency; `model/tensors` builds on it.
##
## In a non-big-endian file each sample is reordered like any header field.
## Pair-swapping is undefined for 3-byte samples (formats 7 and 15), which are
## rejected in that order.

import std/math
import ../common/[endians, ibmfloat, errors]

type
  SampleFormat* = enum
    ## SEG-Y data sample format codes (binary header bytes 3225-3226).
    sfIbm32 = 1      ## IBM hexadecimal float, 4 bytes.
    sfInt32 = 2      ## Two's complement, 4 bytes.
    sfInt16 = 3      ## Two's complement, 2 bytes.
    sfFixedGain = 4  ## Fixed point with gain (obsolete), 4 bytes; read-only.
    sfFloat32 = 5    ## IEEE single, 4 bytes.
    sfFloat64 = 6    ## IEEE double, 8 bytes (Rev 2).
    sfInt24 = 7      ## Two's complement, 3 bytes (Rev 2).
    sfInt8 = 8       ## Two's complement, 1 byte.
    sfInt64 = 9      ## Two's complement, 8 bytes (Rev 2).
    sfUInt32 = 10    ## Unsigned, 4 bytes (Rev 2).
    sfUInt16 = 11    ## Unsigned, 2 bytes (Rev 2).
    sfUInt64 = 12    ## Unsigned, 8 bytes (Rev 2).
    sfUInt24 = 15    ## Unsigned, 3 bytes (Rev 2).
    sfUInt8 = 16     ## Unsigned, 1 byte (Rev 2).

  SampleType* = float32 | float64

const definedSampleFormats* = [sfIbm32, sfInt32, sfInt16, sfFixedGain, sfFloat32, sfFloat64,
  sfInt24, sfInt8, sfInt64, sfUInt32, sfUInt16, sfUInt64, sfUInt24, sfUInt8]
  ## Every format code, in code order (codes 13 and 14 are undefined, so the
  ## enum has holes and cannot be iterated directly).

func toSampleFormat*(code: int, f: var SampleFormat): bool =
  ## Converts a format code; false if the code is not defined in any revision.
  case code
  of 1..12, 15, 16:
    {.push warning[HoleEnumConv]: off.}
    f = SampleFormat(code) # checked against the holes above
    {.pop.}
    result = true
  else:
    result = false

func sampleSize*(f: SampleFormat): int =
  ## Bytes per stored sample.
  case f
  of sfInt8, sfUInt8: 1
  of sfInt16, sfUInt16: 2
  of sfInt24, sfUInt24: 3
  of sfIbm32, sfInt32, sfFixedGain, sfFloat32, sfUInt32: 4
  of sfFloat64, sfInt64, sfUInt64: 8

func isRev2Format*(f: SampleFormat): bool =
  ## True for codes that SEG-Y Rev 0 and Rev 1 do not define.
  f notin {sfIbm32, sfInt32, sfInt16, sfFixedGain, sfFloat32, sfInt8}

func prefersFloat64*(f: SampleFormat): bool =
  ## True when float32 cannot hold the format's values without losing
  ## precision in common data: 8-byte formats.
  f in {sfFloat64, sfInt64, sfUInt64}

func checkOrder(f: SampleFormat, order: ByteOrder) =
  if order == boPairSwapped and f in {sfInt24, sfUInt24}:
    raiseFormat("pair-swapped byte order is undefined for 3-byte sample format " & $ord(f))

func get24(b: openArray[byte], pos: int, order: ByteOrder): uint32 {.inline.} =
  if order == boLittle:
    (uint32(b[pos+2]) shl 16) or (uint32(b[pos+1]) shl 8) or uint32(b[pos])
  else:
    beU24(b, pos)

func put24(b: var openArray[byte], pos: int, v: uint32, order: ByteOrder) {.inline.} =
  if order == boLittle:
    b[pos] = uint8(v and 0xFF)
    b[pos+1] = uint8((v shr 8) and 0xFF)
    b[pos+2] = uint8((v shr 16) and 0xFF)
  else:
    putBeU24(b, pos, v)

template forEachOrder(order: ByteOrder, body: untyped) =
  # Instantiates `body` once per byte order with `o` a constant, so the hot
  # loops carry no per-sample branch on the order.
  case order
  of boBig:
    const o {.inject.} = boBig
    body
  of boLittle:
    const o {.inject.} = boLittle
    body
  of boPairSwapped:
    const o {.inject.} = boPairSwapped
    body

proc decodeSamples*[T: SampleType](f: SampleFormat, src: openArray[byte],
    dst: var openArray[T], order = boBig) =
  ## Decodes `dst.len` samples of format `f` from the start of `src`.
  ## Raises `SegTruncatedError` if `src` is too short, and `SegFormatError` for
  ## a 3-byte format in pair-swapped order.
  checkOrder(f, order)
  let n = dst.len
  if src.len < n * sampleSize(f):
    raiseTruncated("trace data has " & $src.len & " bytes, " & $(n * sampleSize(f)) &
      " needed for " & $n & " samples")
  forEachOrder(order):
    case f
    of sfIbm32:
      when T is float64:
        for i in 0..<n: dst[i] = ibmToFloat64(getNum[uint32](src, 4*i, o))
      else:
        for i in 0..<n: dst[i] = ibmToFloat32(getNum[uint32](src, 4*i, o))
    of sfInt32:
      for i in 0..<n: dst[i] = T(getNum[int32](src, 4*i, o))
    of sfInt16:
      for i in 0..<n: dst[i] = T(getNum[int16](src, 2*i, o))
    of sfFixedGain:
      # Byte 1 zero, byte 2 gain exponent G, bytes 3-4 an i16 mantissa;
      # value = mantissa * 2^-G (Rev 2.1 reading). Reordering applies to the
      # whole 4-byte word.
      for i in 0..<n:
        let w = getNum[uint32](src, 4*i, o)
        dst[i] = T(float64(cast[int16](uint16(w and 0xFFFF))) * pow(2.0, -float64((w shr 16) and 0xFF)))
    of sfFloat32:
      for i in 0..<n: dst[i] = T(getNum[float32](src, 4*i, o))
    of sfFloat64:
      for i in 0..<n: dst[i] = T(getNum[float64](src, 8*i, o))
    of sfInt24:
      for i in 0..<n: dst[i] = T(cast[int32](get24(src, 3*i, o) shl 8) shr 8)
    of sfInt8:
      for i in 0..<n: dst[i] = T(cast[int8](src[i]))
    of sfInt64:
      for i in 0..<n: dst[i] = T(getNum[int64](src, 8*i, o))
    of sfUInt32:
      for i in 0..<n: dst[i] = T(getNum[uint32](src, 4*i, o))
    of sfUInt16:
      for i in 0..<n: dst[i] = T(getNum[uint16](src, 2*i, o))
    of sfUInt64:
      for i in 0..<n: dst[i] = T(getNum[uint64](src, 8*i, o))
    of sfUInt24:
      for i in 0..<n: dst[i] = T(get24(src, 3*i, o))
    of sfUInt8:
      for i in 0..<n: dst[i] = T(src[i])

proc toInt[I: SomeInteger](x: float64, i: int): I {.inline.} =
  # Rounds to nearest; refuses NaN and values outside I.
  let r = round(x)
  if not (r >= float64(low(I)) and r <= float64(high(I))):
    raiseFormat("sample " & $i & " = " & $x & " does not fit " & $I)
  # float64(high(int64)) rounds up to 2^63, so clamp before converting.
  when sizeof(I) == 8:
    if r >= float64(high(I)): high(I) else: I(r)
  else:
    I(r)

proc encodeSamples*[T: SampleType](f: SampleFormat, src: openArray[T],
    dst: var openArray[byte], order = boBig) =
  ## Encodes `src` as format `f` into the start of `dst`. Integer formats
  ## round to nearest. Raises `SegFormatError` for a value that does not fit
  ## (including NaN in an integer format), for format 4 (read-only) and for a
  ## 3-byte format in pair-swapped order.
  checkOrder(f, order)
  let n = src.len
  doAssert dst.len >= n * sampleSize(f), "destination too short"
  forEachOrder(order):
    case f
    of sfIbm32:
      for i in 0..<n: putNum(dst, 4*i, float32ToIbm(float32(src[i])), o)
    of sfInt32:
      for i in 0..<n: putNum(dst, 4*i, toInt[int32](float64(src[i]), i), o)
    of sfInt16:
      for i in 0..<n: putNum(dst, 2*i, toInt[int16](float64(src[i]), i), o)
    of sfFixedGain:
      raiseFormat("sample format 4 (fixed point with gain) is obsolete and read-only")
    of sfFloat32:
      for i in 0..<n: putNum(dst, 4*i, float32(src[i]), o)
    of sfFloat64:
      for i in 0..<n: putNum(dst, 8*i, float64(src[i]), o)
    of sfInt24:
      for i in 0..<n:
        let v = toInt[int32](float64(src[i]), i)
        if v < -0x80_0000 or v > 0x7F_FFFF:
          raiseFormat("sample " & $i & " = " & $v & " does not fit 24 bits")
        put24(dst, 3*i, cast[uint32](v) and 0xFF_FFFF'u32, o)
    of sfInt8:
      for i in 0..<n: dst[i] = cast[byte](toInt[int8](float64(src[i]), i))
    of sfInt64:
      for i in 0..<n: putNum(dst, 8*i, toInt[int64](float64(src[i]), i), o)
    of sfUInt32:
      for i in 0..<n: putNum(dst, 4*i, toInt[uint32](float64(src[i]), i), o)
    of sfUInt16:
      for i in 0..<n: putNum(dst, 2*i, toInt[uint16](float64(src[i]), i), o)
    of sfUInt64:
      for i in 0..<n: putNum(dst, 8*i, toInt[uint64](float64(src[i]), i), o)
    of sfUInt24:
      for i in 0..<n:
        let v = toInt[uint32](float64(src[i]), i)
        if v > 0xFF_FFFF'u32:
          raiseFormat("sample " & $i & " = " & $v & " does not fit 24 bits")
        put24(dst, 3*i, v, o)
    of sfUInt8:
      for i in 0..<n: dst[i] = toInt[uint8](float64(src[i]), i)
