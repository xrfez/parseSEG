## SEG-D demultiplexed sample codecs on byte buffers (spec notes
## `segd_rev2_0.md` §5, `segd_rev3_0_a.md` §5, `segd_rev3_1_delta.md` §5). All
## formats are big-endian except Rev 3.1's 90xx, the little-endian twins of
## 8036/8038/8058/8080.
##
## Decoders give the recorded value; multiply by `2^mpFactor` (Rev 2 CSD) for
## millivolts. Rev 2 multiplexed codes (0015 ... 0058) are not supported:
## `toSegdFormat` rejects them and readers keep such traces raw.
##
## | Code | Format | Bytes |
## |---|---|---|
## | 8015 | 20-bit binary exponent, one's complement fraction | 10 per 4 samples |
## | 8022 / 8024 | quaternary exponent, one's complement 4 / 12-bit fraction | 1 / 2 |
## | 8042 / 8044 | hexadecimal exponent, sign-magnitude 5 / 13-bit fraction | 1 / 2 |
## | 8048 | hexadecimal excess-64 (IBM-like, 23-bit fraction) | 4 |
## | 8036 / 8038 | two's complement integer | 3 / 4 |
## | 8058 / 8080 | IEEE single / double (8080 from Rev 3.0) | 4 / 8 |
## | 9036 / 9038 / 9058 / 9080 | as 80xx, little-endian (Rev 3.1) | 3 / 4 / 4 / 8 |

import std/[math, options]
export options
import ../common/[endians, ibmfloat, errors]
import ../private/bytestore

type
  SegdSampleFormat* = enum
    ## A demultiplexed sample format, by its code (GH#1 bytes 3-4).
    sd8015 = 8015, sd8022 = 8022, sd8024 = 8024, sd8036 = 8036, sd8038 = 8038,
    sd8042 = 8042, sd8044 = 8044, sd8048 = 8048, sd8058 = 8058, sd8080 = 8080,
    sd9036 = 9036, sd9038 = 9038, sd9058 = 9058, sd9080 = 9080

  SegdSampleType* = float32 | float64 ## Sample types the codecs decode into.

const segdSampleFormats* = [sd8015, sd8022, sd8024, sd8036, sd8038, sd8042, sd8044, sd8048,
  sd8058, sd8080, sd9036, sd9038, sd9058, sd9080]
  ## Every supported code (the enum has holes and cannot be iterated).

func isLittleEndian*(f: SegdSampleFormat): bool {.inline.} =
  ## The Rev 3.1 little-endian formats (90xx).
  f in {sd9036, sd9038, sd9058, sd9080}

func bigEndianOf*(f: SegdSampleFormat): SegdSampleFormat =
  ## The big-endian twin of a 90xx format (8036 for 9036, ...); `f` itself
  ## for the others.
  case f
  of sd9036: sd8036
  of sd9038: sd8038
  of sd9058: sd8058
  of sd9080: sd8080
  else: f

func toSegdFormat*(code: int): Option[SegdSampleFormat] =
  ## The sample format of a format code; none for undefined or multiplexed
  ## codes.
  for x in segdSampleFormats:
    if ord(x) == code: return some(x)
  none(SegdSampleFormat)

func dataBytes*(f: SegdSampleFormat, samples: int): int =
  ## Bytes holding `samples` samples. 8015 packs 4 samples in 10 bytes; a
  ## count that is not a multiple of 4 (spec-invalid) is rounded up.
  case f
  of sd8015: (samples + 3) div 4 * 10
  of sd8022, sd8042: samples
  of sd8024, sd8044: 2 * samples
  of sd8036, sd9036: 3 * samples
  of sd8038, sd8048, sd8058, sd9038, sd9058: 4 * samples
  of sd8080, sd9080: 8 * samples

func prefersFloat64*(f: SegdSampleFormat): bool =
  ## True when float32 would lose precision: 8080 and 32-bit integers.
  f in {sd8080, sd8038, sd9080, sd9038}

func putLeI24(b: var openArray[byte], pos: int, v: int32) {.inline.} =
  let u = cast[uint32](v)
  b[pos] = byte(u and 0xFF)
  b[pos + 1] = byte((u shr 8) and 0xFF)
  b[pos + 2] = byte((u shr 16) and 0xFF)

template pow2(T: typedesc, k: int32): untyped =
  # 2^k, exact, built from the exponent bits (k stays in the normal range).
  when T is float32: cast[float32](uint32(127'i32 + k) shl 23)
  else: cast[float64](uint64(1023'i32 + k) shl 52)

template onesComplement(w: int32): int32 =
  # A sign-extended 16-bit one's complement word as an integer, without a
  # branch: a negative word is one less than its value, so add the sign.
  # Negative zero (0xFFFF) reads as 0.
  w - (w shr 31)

template onesField(w, signBit, mask: uint32): int32 =
  # The one's complement fraction under `mask`, signed by bit `signBit`, without a
  # branch: `sm` is 0 or -1; xor with it inverts a negative fraction and negates.
  let sm = -cast[int32]((w shr signBit) and 1)
  let mag = (cast[int32](w) xor sm) and cast[int32](mask)
  (mag xor sm) - sm

template withSign(T: typedesc, v: untyped, sign: uint32): untyped =
  # `v` (>= 0) with its sign bit set when `sign` is 1: sign-magnitude formats,
  # so a negative zero stays -0.0.
  when T is float32: cast[float32](cast[uint32](v) or (sign shl 31))
  else: cast[float64](cast[uint64](v) or (uint64(sign) shl 63))

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
# Lengths are checked once, up front; the loops then load through unchecked
# pointers, in every build.

proc decodeSamplesRaw*[T: SegdSampleType](f: SegdSampleFormat, src: openArray[byte],
    dst: var openArray[T], twosComplement8015 = false) {.raises: [].} =
  ## **Internal.** `decodeSamples` without its checks: `src` must hold the
  ## samples (and, SEG-Y, the format must suit `order`). Raises nothing, so
  ## worker threads make no exceptions (`tryDecodeEntry`).
  let n = dst.len
  if n == 0: return
  let s = byteBuf(src)
  let d = cast[ptr UncheckedArray[T]](addr dst[0])
  template be16(pos: int): uint32 = uint32(loadNum[uint16](s, pos, boBig))
  case f
  of sd8015:
    # Groups of 4 samples in 10 bytes: 4 exponent nibbles, 4 fraction words;
    # a sample is fraction * 2^(e - 15). The group is loaded before any store
    # (`d` may alias `s`, a byte pointer, so a store in between forces reloads).
    template frac(pos: int, twos: static bool): int32 =
      let w = int32(loadNum[int16](s, pos, boBig))
      when twos: w else: onesComplement(w)
    template groups(twos: static bool) =
      for g in 0..<n div 4:
        let a = 10 * g
        let e = uint32(loadNum[uint16](s, a, boBig))
        let m0 = frac(a + 2, twos)
        let m1 = frac(a + 4, twos)
        let m2 = frac(a + 6, twos)
        let m3 = frac(a + 8, twos)
        let v0 = T(m0) * pow2(T, cast[int32](e shr 12) - 15)
        let v1 = T(m1) * pow2(T, cast[int32]((e shr 8) and 0xF) - 15)
        let v2 = T(m2) * pow2(T, cast[int32]((e shr 4) and 0xF) - 15)
        let v3 = T(m3) * pow2(T, cast[int32](e and 0xF) - 15)
        d[4 * g] = v0
        d[4 * g + 1] = v1
        d[4 * g + 2] = v2
        d[4 * g + 3] = v3
      for i in n div 4 * 4 ..< n:
        let k = i mod 4
        let e = (uint32(s[10 * (i div 4) + k div 2]) shr (4 * (1 - k mod 2))) and 0xF
        d[i] = T(frac(10 * (i div 4) + 2 + 2 * k, twos)) * pow2(T, cast[int32](e) - 15)
    if twosComplement8015: groups(true) else: groups(false)
  of sd8022:
    # Sign bit 7, exponent bits 4-6, one's complement fraction bits 0-3:
    # fraction * 4^e / 16.
    for i in 0..<n:
      let b = uint32(s[i])
      d[i] = T(onesField(b, 7, 0xF)) * pow2(T, 2 * cast[int32]((b shr 4) and 7) - 4)
  of sd8024:
    # Sign bit 15, exponent bits 12-14, one's complement fraction bits 0-11:
    # fraction * 4^e / 4096.
    for i in 0..<n:
      let w = be16(2 * i)
      d[i] = T(onesField(w, 15, 0xFFF)) * pow2(T, 2 * cast[int32]((w shr 12) and 7) - 12)
  of sd8042:
    # Sign-magnitude: sign bit 7, exponent bits 5-6, fraction bits 0-4:
    # fraction * 16^e / 32.
    for i in 0..<n:
      let b = uint32(s[i])
      let v = T(b and 0x1F) * pow2(T, 4 * cast[int32]((b shr 5) and 3) - 5)
      d[i] = withSign(T, v, b shr 7)
  of sd8044:
    # Sign-magnitude: sign bit 15, exponent bits 13-14, fraction bits 0-12:
    # fraction * 16^e / 8192.
    for i in 0..<n:
      let w = be16(2 * i)
      let v = T(w and 0x1FFF) * pow2(T, 4 * cast[int32]((w shr 13) and 3) - 13)
      d[i] = withSign(T, v, w shr 15)
  of sd8048:
    for i in 0..<n:
      when T is float64: d[i] = ibmToFloat64(loadNum[uint32](s, 4 * i, boBig))
      else: d[i] = ibmToFloat32(loadNum[uint32](s, 4 * i, boBig))
  of sd8036:
    for i in 0..<n: d[i] = T(cast[int32](loadU24(s, 3 * i, boBig) shl 8) shr 8)
  of sd8038:
    for i in 0..<n: d[i] = T(loadNum[int32](s, 4 * i, boBig))
  of sd8058:
    when T is float32 and hostOrder == boBig: copyHostOrder(d, s, 4 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float32](s, 4 * i, boBig))
  of sd8080:
    when T is float64 and hostOrder == boBig: copyHostOrder(d, s, 8 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float64](s, 8 * i, boBig))
  of sd9036:
    for i in 0..<n: d[i] = T(cast[int32](loadU24(s, 3 * i, boLittle) shl 8) shr 8)
  of sd9038:
    for i in 0..<n: d[i] = T(loadNum[int32](s, 4 * i, boLittle))
  of sd9058:
    when T is float32 and hostOrder == boLittle: copyHostOrder(d, s, 4 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float32](s, 4 * i, boLittle))
  of sd9080:
    when T is float64 and hostOrder == boLittle: copyHostOrder(d, s, 8 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float64](s, 8 * i, boLittle))

proc decodeSamples*[T: SegdSampleType](f: SegdSampleFormat, src: openArray[byte],
    dst: var openArray[T], twosComplement8015 = false) =
  ## Decodes `dst.len` samples of format `f` from the start of `src`.
  ## `twosComplement8015` reads 8015 fractions as two's complement, as some
  ## field systems write them (the spec says one's complement). Raises
  ## `SegTruncatedError` if `src` is too short.
  let n = dst.len
  if src.len < dataBytes(f, n):
    raiseTruncated("trace data has " & $src.len & " bytes, " & $dataBytes(f, n) &
      " needed for " & $n & " samples")
  if n == 0: return
  decodeSamplesRaw(f, src, dst, twosComplement8015)

{.pop.}

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

proc toInt(x: float64, lo, hi: int64, i: int): int64 =
  let r = round(x)
  if not (r >= float64(lo) and r <= float64(hi)):
    raiseFormat("sample " & $i & " = " & $x & " does not fit the integer format")
  int64(r)

proc encodePlain[T: SegdSampleType](f: SegdSampleFormat, src: openArray[T],
    dst: var openArray[byte], twosComplement8015: bool) =
  # One sample at a time through the checked accessors: the exponent
  # formats, and every trace a kernel of `encodeSamples` flags, for its
  # error (it names the first sample that does not fit) or its rare values
  # (8048: subnormals, doubles beyond float32).
  let n = src.len
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
    for i in 0..<n: putBeI24(dst, 3 * i, int32(toInt(float64(src[i]), -0x80_0000, 0x7F_FFFF, i)))
  of sd8038:
    for i in 0..<n:
      putBeI32(dst, 4 * i, int32(toInt(float64(src[i]), int64(low(int32)), int64(high(int32)), i)))
  of sd8058:
    for i in 0..<n: putBeF32(dst, 4 * i, float32(src[i]))
  of sd8080:
    for i in 0..<n: putBeF64(dst, 8 * i, float64(src[i]))
  of sd9036:
    for i in 0..<n: putLeI24(dst, 3 * i, int32(toInt(float64(src[i]), -0x80_0000, 0x7F_FFFF, i)))
  of sd9038:
    for i in 0..<n:
      putNum(dst, 4 * i, int32(toInt(float64(src[i]), int64(low(int32)), int64(high(int32)), i)),
        boLittle)
  of sd9058:
    for i in 0..<n: putNum(dst, 4 * i, float32(src[i]), boLittle)
  of sd9080:
    for i in 0..<n: putNum(dst, 8 * i, float64(src[i]), boLittle)

when defined(gcc):
  # The integer kernels round and clamp without a branch; gcc vectorizes
  # them only when it need not keep the floating-point exception flags as
  # the scalar code would raise them (its default). The values do not
  # depend on it. This C file only.
  {.localPassC: "-fno-trapping-math".}

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

proc encodeKernel[T: SegdSampleType](f: SegdSampleFormat, src: openArray[T],
    dst: var openArray[byte]): bool {.raises: [].} =
  # The loops of `encodeSamples`, which has checked that `dst` holds the
  # `src.len > 0` samples: unchecked stores, the byte order a constant, as
  # the decoders. True when `encodePlain` must do the trace instead (then
  # `dst` holds clamped or unfinished values). It raises nothing, so the
  # compiler puts no error check into the loops.
  let n = src.len
  let s = cast[ptr UncheckedArray[T]](addr src[0])
  let d = cast[ByteBuf](addr dst[0])
  var redo = 0 # or-ed flags, no branch per sample
  template ints(lo, hi: untyped, put: untyped) =
    # Rounded to nearest, halves away from zero. A value outside `lo..hi`
    # (or NaN) is only flagged here, and stored clamped.
    const a = float64(lo)
    const b = float64(hi)
    for i {.inject.} in 0..<n:
      let r = roundAway(float64(s[i]))
      redo = redo or (ord(not (r >= a)) or ord(not (r <= b)))
      let k {.inject.} = truncToInt32(max(a, min(r, b)))
      put
  template floats(F: typedesc, o: static ByteOrder) =
    when T is F and o == hostOrder:
      copyMem(d, s, sizeof(F) * n)
    else:
      for i in 0..<n: storeNum(d, sizeof(F) * i, F(s[i]), o)
  case f
  of sd8058: floats(float32, boBig)
  of sd9058: floats(float32, boLittle)
  of sd8080: floats(float64, boBig)
  of sd9080: floats(float64, boLittle)
  of sd8036:
    ints(-0x80_0000, 0x7F_FFFF):
      storeU24(d, 3 * i, cast[uint32](k) and 0xFF_FFFF'u32, boBig)
  of sd9036:
    ints(-0x80_0000, 0x7F_FFFF):
      storeU24(d, 3 * i, cast[uint32](k) and 0xFF_FFFF'u32, boLittle)
  of sd8038:
    ints(low(int32), high(int32)):
      storeNum(d, 4 * i, k, boBig)
  of sd9038:
    ints(low(int32), high(int32)):
      storeNum(d, 4 * i, k, boLittle)
  of sd8048:
    for i in 0..<n:
      let b = cast[uint32](float32(s[i]))
      let e = (b shr 23) and 0xFF
      # Subnormals, NaN, the infinities and doubles beyond float32.
      redo = redo or ord(e == 255) or (ord(e == 0) and ord((b and 0x7F_FFFF'u32) != 0))
      # The IBM float, its 24-bit fraction rounded to 23 bits: an odd one
      # goes up, and a carry out of 0xFFFFFF, which lands in the exponent,
      # leaves the fraction 0.1 (hexadecimal).
      var w = normalToIbm(b)
      w = w + (w and 1)
      w = w or (uint32(ord((w and 0xFF_FFFF'u32) == 0)) shl 20)
      storeNum(d, 4 * i, (if (b and 0x7FFF_FFFF'u32) == 0: 0'u32 else: w), boBig)
  of sd8015, sd8022, sd8024, sd8042, sd8044:
    redo = 1
  redo != 0

proc encodeSamples*[T: SegdSampleType](f: SegdSampleFormat, src: openArray[T],
    dst: var openArray[byte], twosComplement8015 = false) =
  ## Encodes `src` as format `f` into the start of `dst` (at least
  ## `dataBytes(f, src.len)` bytes). The exponent formats and 8048 quantize
  ## (rounding to nearest), the integer formats round. Raises
  ## `SegFormatError` for a value the format cannot hold, NaN and the
  ## infinities included (only the IEEE formats hold those): beyond ±32767
  ## in 8015, ±15360 in 8022, ±16380 in 8024, 3968 and -3840 in 8042, 4095.5
  ## and -4095 in 8044 (all ones is not a code), about ±7.237e75 in 8048,
  ## and the integer range in 8036 and 8038. Raises `ValueError` when `dst`
  ## is too short. `twosComplement8015` writes 8015 fractions as two's
  ## complement, the inverse of the decoders' option (the spec says one's
  ## complement); it reaches -32768.
  let n = src.len
  if dst.len < dataBytes(f, n):
    raise newException(ValueError, "the destination has " & $dst.len & " bytes, " &
      $dataBytes(f, n) & " needed for " & $n & " samples")
  if n > 0 and encodeKernel(f, src, dst): encodePlain(f, src, dst, twosComplement8015)

{.pop.}
