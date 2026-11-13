## SEG-Y sample codecs on byte buffers (spec notes `segy_rev1.md` §5,
## `segy_rev2_1.md` §5).
##
## Decoders convert stored samples to `float32` or `float64` in a
## caller-provided buffer (e.g. a Tensor row), with no intermediate `seq`.
## Encoders convert back and refuse values that do not fit the format
## (`SegFormatError`: nothing is clamped). This module has no Arraymancer
## dependency; `model/tensors` builds on it.
##
## In a non-big-endian file each sample is reordered like any header field.
## Pair-swapping is undefined for 3-byte samples (formats 7 and 15), which are
## rejected in that order.

import std/[math, options]
import ../common/[endians, ibmfloat, errors]
import ../private/bytestore
export options

type
  SampleFormat* = enum
    ## SEG-Y data sample format codes (binary header bytes 3225-3226).
    sfIbm32 = 1      ## IBM hexadecimal float, 4 bytes.
    sfInt32 = 2      ## Two's complement, 4 bytes.
    sfInt16 = 3      ## Two's complement, 2 bytes.
    sfFixedGain = 4  ## Fixed point with gain (obsolete, Rev 0-1), 4 bytes.
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
    ## The element types samples decode to.

const definedSampleFormats* = [sfIbm32, sfInt32, sfInt16, sfFixedGain, sfFloat32, sfFloat64,
  sfInt24, sfInt8, sfInt64, sfUInt32, sfUInt16, sfUInt64, sfUInt24, sfUInt8]
  ## Every format code, in code order (codes 13 and 14 are undefined, so the
  ## enum has holes and cannot be iterated directly).

func toSampleFormat*(code: int): Option[SampleFormat] =
  ## Converts a format code; none if the code is not defined in any revision.
  case code
  of 1..12, 15, 16:
    {.push warning[HoleEnumConv]: off.}
    result = some(SampleFormat(code)) # checked against the holes above
    {.pop.}
  else:
    result = none(SampleFormat)

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

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
# The decoders check the buffer lengths once, up front, then load through
# unchecked pointers: no per-sample check in any build (the shipped library
# is -d:release).

proc decodeSamplesRaw*[T: SampleType](f: SampleFormat, src: openArray[byte],
    dst: var openArray[T], order = boBig) {.raises: [].} =
  ## **Internal.** `decodeSamples` without its checks: `src` must hold the
  ## samples (and, SEG-Y, the format must suit `order`). Raises nothing, so
  ## worker threads make no exceptions (`tryDecodeEntry`).
  let n = dst.len
  if n == 0: return
  let s = byteBuf(src)
  let d = cast[ptr UncheckedArray[T]](addr dst[0])
  forEachOrder(order):
    case f
    of sfIbm32:
      when T is float64:
        for i in 0..<n: d[i] = ibmToFloat64(loadNum[uint32](s, 4*i, o))
      else:
        template word(i: int): uint32 = loadNum[uint32](s, 4*i, o)
        decodeIbm32(d, n, word) # 8 wide when the build targets AVX2
    of sfInt32:
      for i in 0..<n: d[i] = T(loadNum[int32](s, 4*i, o))
    of sfInt16:
      for i in 0..<n: d[i] = T(loadNum[int16](s, 2*i, o))
    of sfFixedGain:
      # Byte 1 zero, byte 2 gain exponent G, bytes 3-4 an i16 mantissa;
      # value = mantissa * 2^-G (Rev 2.1 reading). Reordering applies to the
      # whole 4-byte word.
      for i in 0..<n:
        let w = loadNum[uint32](s, 4*i, o)
        d[i] = T(float64(cast[int16](uint16(w and 0xFFFF))) *
          pow(2.0, -float64((w shr 16) and 0xFF)))
    of sfFloat32:
      when T is float32 and o == hostOrder:
        copyHostOrder(d, s, 4 * n)
      else:
        for i in 0..<n: d[i] = T(loadNum[float32](s, 4*i, o))
    of sfFloat64:
      when T is float64 and o == hostOrder:
        copyHostOrder(d, s, 8 * n)
      else:
        for i in 0..<n: d[i] = T(loadNum[float64](s, 8*i, o))
    of sfInt24:
      when o != boPairSwapped: # rejected by checkOrder
        for i in 0..<n: d[i] = T(cast[int32](loadU24(s, 3*i, o) shl 8) shr 8)
    of sfInt8:
      for i in 0..<n: d[i] = T(cast[int8](s[i]))
    of sfInt64:
      for i in 0..<n: d[i] = T(loadNum[int64](s, 8*i, o))
    of sfUInt32:
      for i in 0..<n: d[i] = T(loadNum[uint32](s, 4*i, o))
    of sfUInt16:
      for i in 0..<n: d[i] = T(loadNum[uint16](s, 2*i, o))
    of sfUInt64:
      for i in 0..<n: d[i] = T(loadNum[uint64](s, 8*i, o))
    of sfUInt24:
      when o != boPairSwapped:
        for i in 0..<n: d[i] = T(loadU24(s, 3*i, o))
    of sfUInt8:
      for i in 0..<n: d[i] = T(s[i])

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
  if n == 0: return
  decodeSamplesRaw(f, src, dst, order)

{.pop.}

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

proc fixedGainWord(x: float64, i: int): uint32 =
  ## Format 4: the largest gain G (0-255) whose mantissa round(x * 2^G)
  ## still fits an i16, so value = mantissa * 2^-G keeps the most precision.
  ## |x| above 32767 does not fit any G.
  if x.isNaN or abs(x) > 32767.5:
    raiseFormat("sample " & $i & " = " & $x & " does not fit format 4 (|value| <= 32767)")
  var g = 0
  if x != 0:
    g = clamp(int(floor(log2(32767.0 / abs(x)))), 0, 255)
    while g > 0 and abs(round(x * pow(2.0, float64(g)))) > 32767: dec g
    while g < 255 and abs(round(x * pow(2.0, float64(g + 1)))) <= 32767: inc g
  let m = clamp(round(x * pow(2.0, float64(g))), -32768.0, 32767.0)
  (uint32(g) shl 16) or uint32(cast[uint16](int16(m)))

proc ibmWord[T: SampleType](x: T, i: int): uint32 {.inline.} =
  # Format 1: the IBM float nearest to the float32 nearest to `x`, as ever;
  # a double beyond float32's range directly. NaN, the infinities and
  # magnitudes beyond the IBM range (about 7.237e75) have no IBM float.
  let f = float32(x)
  if f - f == 0: # finite as a float32
    result = float32ToIbm(f)
  else:
    when T is float64:
      if float64ToIbm(x, result): return
    raiseFormat("sample " & $i & " = " & $x & " does not fit format 1 (IBM float: finite, " &
      "up to 7.237e75)")

proc encodePlain[T: SampleType](f: SampleFormat, src: openArray[T], dst: var openArray[byte],
    order: ByteOrder) =
  # One sample at a time through the checked accessors: the formats without
  # a kernel in `encodeSamples` (4 and the 64-bit integers), and every trace
  # a kernel flags, for its error (it names the first sample that does not
  # fit) or its rare values (IBM: subnormals, doubles beyond float32).
  let n = src.len
  forEachOrder(order):
    case f
    of sfIbm32:
      for i in 0..<n: putNum(dst, 4*i, ibmWord(src[i], i), o)
    of sfInt32:
      for i in 0..<n: putNum(dst, 4*i, toInt[int32](float64(src[i]), i), o)
    of sfInt16:
      for i in 0..<n: putNum(dst, 2*i, toInt[int16](float64(src[i]), i), o)
    of sfFixedGain:
      for i in 0..<n: putNum(dst, 4*i, fixedGainWord(float64(src[i]), i), o)
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

when defined(gcc):
  # The integer kernels round and clamp without a branch; gcc vectorizes
  # them only when it need not keep the floating-point exception flags as
  # the scalar code would raise them (its default). The values do not
  # depend on it. This C file only.
  {.localPassC: "-fno-trapping-math".}

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
# As the decoders: the lengths are checked once, then the loops load and
# store through unchecked pointers with the byte order a constant, in every
# build. In the shipped build (-d:release, x86-64-v3; f32 traces of 2000
# samples) big-endian IEEE went from 1.4 to 56 GB/s, IBM float from 0.22 to
# 10.6, int32 from 0.64 to 4.0 and int16 from 0.43 to 2.2.

proc encodeKernel[T: SampleType](f: SampleFormat, src: openArray[T], dst: var openArray[byte],
    order: ByteOrder): bool {.raises: [].} =
  # The loops of `encodeSamples`, which has checked the order and that `dst`
  # holds the `src.len > 0` samples. True when `encodePlain` must do the
  # trace instead (then `dst` holds clamped or unfinished values). It
  # raises nothing, so the compiler puts no error check into the loops.
  let n = src.len
  let s = cast[ptr UncheckedArray[T]](addr src[0])
  let d = cast[ByteBuf](addr dst[0])
  var redo = 0 # or-ed flags, no branch per sample
  template ints(I: typedesc, lo, hi: untyped, put: untyped) =
    # Rounded to nearest, halves away from zero. A value outside `lo..hi`
    # (or NaN) is only flagged here, and stored clamped: no undefined
    # conversion.
    const a = float64(lo)
    const b = float64(hi)
    for i {.inject.} in 0..<n:
      let r = roundAway(float64(s[i]))
      redo = redo or (ord(not (r >= a)) or ord(not (r <= b)))
      let c = max(a, min(r, b))
      let k {.inject.} = when I is uint32: uint32(c) else: I(truncToInt32(c))
      put
  forEachOrder(order):
    case f
    of sfFloat32:
      when T is float32 and o == hostOrder:
        copyMem(d, s, 4 * n)
      else:
        for i in 0..<n: storeNum(d, 4*i, float32(s[i]), o)
    of sfFloat64:
      when T is float64 and o == hostOrder:
        copyMem(d, s, 8 * n)
      else:
        for i in 0..<n: storeNum(d, 8*i, float64(s[i]), o)
    of sfIbm32:
      for i in 0..<n:
        let b = cast[uint32](float32(s[i]))
        let e = (b shr 23) and 0xFF
        # Subnormals, NaN, the infinities and doubles beyond float32.
        redo = redo or ord(e == 255) or (ord(e == 0) and ord((b and 0x7F_FFFF'u32) != 0))
        storeNum(d, 4*i, (if (b and 0x7FFF_FFFF'u32) == 0: 0'u32 else: normalToIbm(b)), o)
    of sfInt32:
      ints(int32, low(int32), high(int32)):
        storeNum(d, 4*i, k, o)
    of sfInt16:
      ints(int16, low(int16), high(int16)):
        storeNum(d, 2*i, k, o)
    of sfInt8:
      ints(int8, low(int8), high(int8)):
        d[i] = cast[byte](k)
    of sfUInt32:
      ints(uint32, low(uint32), high(uint32)):
        storeNum(d, 4*i, k, o)
    of sfUInt16:
      ints(uint16, low(uint16), high(uint16)):
        storeNum(d, 2*i, k, o)
    of sfUInt8:
      ints(uint8, low(uint8), high(uint8)):
        d[i] = k
    of sfInt24:
      when o != boPairSwapped: # refused by checkOrder
        ints(int32, -0x80_0000, 0x7F_FFFF):
          storeU24(d, 3*i, cast[uint32](k) and 0xFF_FFFF'u32, o)
    of sfUInt24:
      when o != boPairSwapped:
        ints(int32, 0, 0xFF_FFFF):
          storeU24(d, 3*i, cast[uint32](k), o)
    of sfFixedGain, sfInt64, sfUInt64:
      redo = 1
  redo != 0

proc encodeSamples*[T: SampleType](f: SampleFormat, src: openArray[T],
    dst: var openArray[byte], order = boBig) =
  ## Encodes `src` as format `f` into the start of `dst` (at least
  ## `src.len * sampleSize(f)` bytes). Integer formats round to nearest.
  ## Raises `SegFormatError` for a value the format cannot hold (NaN or out
  ## of range in an integer format or format 4; NaN, an infinity or a
  ## magnitude beyond about 7.237e75 in format 1, IBM float) and for a
  ## 3-byte format in pair-swapped order; `ValueError` when `dst` is too
  ## short. Format 1 goes through float32, except for doubles beyond its
  ## range; format 4 picks the largest gain per sample; the IEEE formats
  ## hold every value (a double beyond float32 becomes an infinity in
  ## format 5).
  checkOrder(f, order)
  let n = src.len
  if dst.len < n * sampleSize(f):
    raise newException(ValueError, "the destination has " & $dst.len & " bytes, " &
      $(n * sampleSize(f)) & " needed for " & $n & " samples")
  if n > 0 and encodeKernel(f, src, dst, order): encodePlain(f, src, dst, order)

{.pop.}
