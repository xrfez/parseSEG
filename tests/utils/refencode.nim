## The sample encoders as they were before they got the decoders' shape
## (unchecked pointer stores, a static byte order, an integer IBM kernel,
## exponents from the float's bits): one sample at a time through the
## checked `putNum` accessors, `float32ToIbm` and `pow`. The oracle of
## `tests/tfastencode.nim`: the encoders must give these bytes and raise
## where these raise.

import std/math
import parseSEG/common/[endians, ibmfloat, errors]
import parseSEG/segy/samples as segysamples
import parseSEG/segd/samples as segdsamples
import parseSEG/seg2/samples as seg2samples

# ------------------------------------------------------------------ SEG-Y --

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

proc segyInt[I: SomeInteger](x: float64, i: int): I {.inline.} =
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

proc refEncodeSegy*[T: SampleType](f: SampleFormat, src: openArray[T],
    dst: var openArray[byte], order = boBig) =
  ## `segy/samples.encodeSamples` as it was.
  checkOrder(f, order)
  let n = src.len
  if dst.len < n * sampleSize(f):
    raise newException(ValueError, "the destination has " & $dst.len & " bytes, " &
      $(n * sampleSize(f)) & " needed for " & $n & " samples")
  forEachOrder(order):
    case f
    of sfIbm32:
      for i in 0..<n: putNum(dst, 4*i, ibmWord(src[i], i), o)
    of sfInt32:
      for i in 0..<n: putNum(dst, 4*i, segyInt[int32](float64(src[i]), i), o)
    of sfInt16:
      for i in 0..<n: putNum(dst, 2*i, segyInt[int16](float64(src[i]), i), o)
    of sfFixedGain:
      for i in 0..<n: putNum(dst, 4*i, fixedGainWord(float64(src[i]), i), o)
    of sfFloat32:
      for i in 0..<n: putNum(dst, 4*i, float32(src[i]), o)
    of sfFloat64:
      for i in 0..<n: putNum(dst, 8*i, float64(src[i]), o)
    of sfInt24:
      for i in 0..<n:
        let v = segyInt[int32](float64(src[i]), i)
        if v < -0x80_0000 or v > 0x7F_FFFF:
          raiseFormat("sample " & $i & " = " & $v & " does not fit 24 bits")
        put24(dst, 3*i, cast[uint32](v) and 0xFF_FFFF'u32, o)
    of sfInt8:
      for i in 0..<n: dst[i] = cast[byte](segyInt[int8](float64(src[i]), i))
    of sfInt64:
      for i in 0..<n: putNum(dst, 8*i, segyInt[int64](float64(src[i]), i), o)
    of sfUInt32:
      for i in 0..<n: putNum(dst, 4*i, segyInt[uint32](float64(src[i]), i), o)
    of sfUInt16:
      for i in 0..<n: putNum(dst, 2*i, segyInt[uint16](float64(src[i]), i), o)
    of sfUInt64:
      for i in 0..<n: putNum(dst, 8*i, segyInt[uint64](float64(src[i]), i), o)
    of sfUInt24:
      for i in 0..<n:
        let v = segyInt[uint32](float64(src[i]), i)
        if v > 0xFF_FFFF'u32:
          raiseFormat("sample " & $i & " = " & $v & " does not fit 24 bits")
        put24(dst, 3*i, v, o)
    of sfUInt8:
      for i in 0..<n: dst[i] = segyInt[uint8](float64(src[i]), i)

# ------------------------------------------------------------------ SEG-D --

func putLeI24(b: var openArray[byte], pos: int, v: int32) {.inline.} =
  let u = cast[uint32](v)
  b[pos] = byte(u and 0xFF)
  b[pos + 1] = byte((u shr 8) and 0xFF)
  b[pos + 2] = byte((u shr 16) and 0xFF)

proc expFraction(x: float64, base: float64, maxExp, fracBits: int, i: int, f: SegdSampleFormat,
    top: uint32): tuple[e: int, mag: uint32] =
  # The smallest exponent whose fraction fits `fracBits` bits (most
  # precision). At the largest exponent the fraction may reach `top`: a
  # value beyond that (or NaN, or an infinity) is out of the format's range.
  let full = float64(1 shl fracBits)
  let a = abs(x)
  for e in 0..maxExp:
    let m = round(a / pow(base, float64(e)) * full)
    if (e < maxExp and m < full) or (e == maxExp and m <= float64(top)):
      return (e, uint32(m))
  raiseFormat("sample " & $i & " = " & $x & " does not fit format " & $ord(f) &
    " (finite, up to " & $(float64(top) / full * pow(base, float64(maxExp))) & ")")

proc hexWord[T: SegdSampleType](x: T, i: int): uint32 {.inline.} =
  # Format 8048: an IBM float with a 23-bit fraction (its last bit 0),
  # through float32, as ever; a double beyond float32's range directly.
  let f = float32(x)
  if f - f == 0: # finite as a float32
    result = float32ToIbm(f)
    if (result and 1) != 0:
      # Round the 24-bit fraction to 23 bits; a carry renormalizes (the
      # exponent has room: a float32 ends far below the largest).
      var frac = (result and 0xFF_FFFF'u32) + 1
      var expo = (result shr 24) and 0x7F
      if frac == 0x100_0000'u32:
        frac = 0x10_0000'u32
        inc expo
      result = (result and 0x8000_0000'u32) or (expo shl 24) or frac
  else:
    when T is float64:
      if float64ToIbm(x, result, fractionBits = 23): return
    raiseFormat("sample " & $i & " = " & $x & " does not fit format 8048 (finite, up to " &
      "7.237e75)")

proc segdInt(x: float64, lo, hi: int64, i: int): int64 =
  let r = round(x)
  if not (r >= float64(lo) and r <= float64(hi)):
    raiseFormat("sample " & $i & " = " & $x & " does not fit the integer format")
  int64(r)

proc refEncodeSegd*[T: SegdSampleType](f: SegdSampleFormat, src: openArray[T],
    dst: var openArray[byte], twosComplement8015 = false) =
  ## `segd/samples.encodeSamples` as it was.
  let n = src.len
  if dst.len < dataBytes(f, n):
    raise newException(ValueError, "the destination has " & $dst.len & " bytes, " &
      $dataBytes(f, n) & " needed for " & $n & " samples")
  case f
  of sd8015:
    for g in 0..<(n + 3) div 4:
      dst[10 * g] = 0
      dst[10 * g + 1] = 0
      for k in 0..3:
        let i = 4 * g + k
        var w = 0'u16
        var e = 0
        if i < n:
          let x = float64(src[i])
          let (ee, mag) = expFraction(x, 2.0, 15, 15, i, f,
            if twosComplement8015 and x < 0: 0x8000 else: 0x7FFF)
          e = ee
          w = if x >= 0 or mag == 0: uint16(mag)
              elif twosComplement8015: uint16(0x1_0000'u32 - mag)
              else: uint16((not mag) and 0xFFFF)
        if k mod 2 == 0: dst[10 * g + k div 2] = dst[10 * g + k div 2] or byte(e shl 4)
        else: dst[10 * g + k div 2] = dst[10 * g + k div 2] or byte(e)
        putBeU16(dst, 10 * g + 2 + 2 * k, w)
  of sd8022, sd8024:
    let bits = if f == sd8022: 4 else: 12
    for i in 0..<n:
      let x = float64(src[i])
      let mask = (1'u32 shl bits) - 1
      let (e, mag) = expFraction(x, 4.0, 7, bits, i, f, mask)
      let neg = x < 0 and mag != 0
      let q = if neg: (not mag) and mask else: mag
      let s = if neg: 1'u32 else: 0'u32
      if f == sd8022: dst[i] = byte((s shl 7) or (uint32(e) shl 4) or q)
      else: putBeU16(dst, 2 * i, uint16((s shl 15) or (uint32(e) shl 12) or q))
  of sd8042, sd8044:
    let bits = if f == sd8042: 5 else: 13
    for i in 0..<n:
      let x = float64(src[i])
      # All ones (negative full scale) is not a code: the negative range
      # ends one step earlier.
      let (e, mag) = expFraction(x, 16.0, 3, bits, i, f,
        (1'u32 shl bits) - (if x < 0: 2 else: 1))
      let s = if x < 0 and mag != 0: 1'u32 else: 0'u32
      if f == sd8042: dst[i] = byte((s shl 7) or (uint32(e) shl 5) or mag)
      else: putBeU16(dst, 2 * i, uint16((s shl 15) or (uint32(e) shl 13) or mag))
  of sd8048:
    for i in 0..<n: putBeU32(dst, 4 * i, hexWord(src[i], i) and not 1'u32)
  of sd8036:
    for i in 0..<n: putBeI24(dst, 3 * i, int32(segdInt(float64(src[i]), -0x80_0000, 0x7F_FFFF, i)))
  of sd8038:
    for i in 0..<n:
      putBeI32(dst, 4 * i, int32(segdInt(float64(src[i]), int64(low(int32)), int64(high(int32)), i)))
  of sd8058:
    for i in 0..<n: putBeF32(dst, 4 * i, float32(src[i]))
  of sd8080:
    for i in 0..<n: putBeF64(dst, 8 * i, float64(src[i]))
  of sd9036:
    for i in 0..<n: putLeI24(dst, 3 * i, int32(segdInt(float64(src[i]), -0x80_0000, 0x7F_FFFF, i)))
  of sd9038:
    for i in 0..<n:
      putNum(dst, 4 * i, int32(segdInt(float64(src[i]), int64(low(int32)), int64(high(int32)), i)),
        boLittle)
  of sd9058:
    for i in 0..<n: putNum(dst, 4 * i, float32(src[i]), boLittle)
  of sd9080:
    for i in 0..<n: putNum(dst, 8 * i, float64(src[i]), boLittle)

# ------------------------------------------------------------------ SEG-2 --

proc seg2Int(x: float64, lo, hi: int64, i: int): int64 =
  # `x` rounded to the nearest integer; raises when it is NaN or outside lo..hi.
  if x.isNaN: raiseFormat("sample " & $i & " is NaN, which an integer format cannot hold")
  let r = round(x)
  if r < float64(lo) or r > float64(hi):
    raiseFormat("sample " & $i & " = " & $x & " does not fit " & $lo & ".." & $hi)
  int64(r)

func float20Word(m: int, twosComplement: bool): uint16 {.inline.} =
  # A format-3 mantissa word for |m| <= 32767 (negative zero is never written).
  if m >= 0: uint16(m)
  elif twosComplement: cast[uint16](int16(m))
  else: not uint16(-m) # one's complement

proc float20Parts(x: float64, i: int): (int, int) =
  # (exponent, mantissa) of a format-3 sample: the smallest exponent whose
  # mantissa, rounded to nearest, fits 15 bits.
  if x.isNaN: raiseFormat("sample " & $i & " is NaN, which format 3 cannot hold")
  for e in 0..15:
    let m = round(x / float64(1 shl e))
    if abs(m) <= 32767: return (e, int(m))
  raiseFormat("sample " & $i & " = " & $x & " exceeds format 3's range (32767 * 2^15)")

proc refEncodeSeg2*[T: Seg2SampleType](f: Seg2SampleFormat, src: openArray[T],
    dst: var openArray[byte], order: ByteOrder, twosComplement = false) =
  ## `seg2/samples.encodeSamples` as it was.
  let n = src.len
  let need = dataBytes(f, n)
  if dst.len < need:
    raise newException(ValueError, "the destination has " & $dst.len & " bytes, " & $need &
      " needed for " & $n & " samples")
  template loop(o: static ByteOrder) =
    case f
    of s2Int16:
      for i in 0..<n: putNum(dst, 2*i, int16(seg2Int(float64(src[i]), -32768, 32767, i)), o)
    of s2Int32:
      for i in 0..<n:
        putNum(dst, 4*i, int32(seg2Int(float64(src[i]), int64(low(int32)), int64(high(int32)), i)), o)
    of s2Float32:
      for i in 0..<n: putNum(dst, 4*i, float32(src[i]), o)
    of s2Float64:
      for i in 0..<n: putNum(dst, 8*i, float64(src[i]), o)
    of s2Float20:
      for g in 0 ..< (n + 3) div 4:
        var e = 0'u16
        for k in 0..3:
          let i = 4 * g + k
          var w = 0'u16
          if i < n:
            let (ex, m) = float20Parts(float64(src[i]), i)
            e = e or (uint16(ex) shl (4 * k))
            w = float20Word(m, twosComplement)
          putNum(dst, 10 * g + 2 + 2 * k, w, o)
        putNum(dst, 10 * g, e, o)
  if order == boLittle: loop(boLittle) else: loop(boBig)
