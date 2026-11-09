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

func onesFraction(q, mask: uint32, negative: bool): int {.inline.} =
  # One's complement fraction: a negative value stores the inverted magnitude.
  # Negative zero (all bits set) reads as 0.
  if negative: -int((not q) and mask) else: int(q)

const
  pow4 = [1.0, 4.0, 16.0, 64.0, 256.0, 1024.0, 4096.0, 16384.0] ## 4^e, e in 0..7.
  pow16 = [1.0, 16.0, 256.0, 4096.0]                           ## 16^e, e in 0..3.

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
# Lengths are checked once, up front; the loops then load through unchecked
# pointers, in every build.

proc decodeSegdSamples*[T: SegdSampleType](f: SegdSampleFormat, src: openArray[byte],
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
  let s = byteBuf(src)
  let d = cast[ptr UncheckedArray[T]](addr dst[0])
  template be16(pos: int): uint32 = uint32(loadNum[uint16](s, pos, boBig))
  case f
  of sd8015:
    # Groups of 4 samples in 10 bytes: 4 exponent nibbles, 4 fraction words.
    template one(g, k: int, twos: static bool): T =
      let e = (s[10 * g + k div 2] shr (4 * (1 - k mod 2))) and 0xF
      let w = be16(10 * g + 2 + 2 * k)
      let m = when twos: int(cast[int16](uint16(w)))
              else: onesFraction(w and 0x7FFF, 0x7FFF, (w and 0x8000) != 0)
      T(float64(m) * (float64(1 shl e) / 32768.0))
    template groups(twos: static bool) =
      for g in 0..<n div 4:
        d[4 * g] = one(g, 0, twos)
        d[4 * g + 1] = one(g, 1, twos)
        d[4 * g + 2] = one(g, 2, twos)
        d[4 * g + 3] = one(g, 3, twos)
      for i in n div 4 * 4 ..< n: d[i] = one(i div 4, i mod 4, twos)
    if twosComplement8015: groups(true) else: groups(false)
  of sd8022:
    for i in 0..<n:
      let b = uint32(s[i])
      let m = onesFraction(b and 0xF, 0xF, (b and 0x80) != 0)
      d[i] = T(float64(m) / 16.0 * pow4[(b shr 4) and 7])
  of sd8024:
    for i in 0..<n:
      let w = be16(2 * i)
      let m = onesFraction(w and 0xFFF, 0xFFF, (w and 0x8000) != 0)
      d[i] = T(float64(m) / 4096.0 * pow4[(w shr 12) and 7])
  of sd8042:
    for i in 0..<n:
      let b = uint32(s[i])
      let v = float64(b and 0x1F) / 32.0 * pow16[(b shr 5) and 3]
      d[i] = T(if (b and 0x80) != 0: -v else: v)
  of sd8044:
    for i in 0..<n:
      let w = be16(2 * i)
      let v = float64(w and 0x1FFF) / 8192.0 * pow16[(w shr 13) and 3]
      d[i] = T(if (w and 0x8000) != 0: -v else: v)
  of sd8048:
    for i in 0..<n:
      when T is float64: d[i] = ibmToFloat64(loadNum[uint32](s, 4 * i, boBig))
      else: d[i] = ibmToFloat32(loadNum[uint32](s, 4 * i, boBig))
  of sd8036:
    for i in 0..<n: d[i] = T(cast[int32](loadU24(s, 3 * i, boBig) shl 8) shr 8)
  of sd8038:
    for i in 0..<n: d[i] = T(loadNum[int32](s, 4 * i, boBig))
  of sd8058:
    when T is float32 and hostOrder == boBig: copyMem(d, s, 4 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float32](s, 4 * i, boBig))
  of sd8080:
    when T is float64 and hostOrder == boBig: copyMem(d, s, 8 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float64](s, 8 * i, boBig))
  of sd9036:
    for i in 0..<n: d[i] = T(cast[int32](loadU24(s, 3 * i, boLittle) shl 8) shr 8)
  of sd9038:
    for i in 0..<n: d[i] = T(loadNum[int32](s, 4 * i, boLittle))
  of sd9058:
    when T is float32 and hostOrder == boLittle: copyMem(d, s, 4 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float32](s, 4 * i, boLittle))
  of sd9080:
    when T is float64 and hostOrder == boLittle: copyMem(d, s, 8 * n)
    else:
      for i in 0..<n: d[i] = T(loadNum[float64](s, 8 * i, boLittle))

{.pop.}

proc expFraction(x: float64, base: float64, maxExp, fracBits: int, i: int):
    tuple[e: int, mag: uint32] =
  # The smallest exponent whose fraction fits `fracBits` bits (most
  # precision); clamps at the largest exponent.
  if x.isNaN:
    raiseFormat("sample " & $i & " is NaN, which this format cannot hold")
  let full = float64(1 shl fracBits)
  let a = abs(x)
  for e in 0..maxExp:
    let m = round(a / pow(base, float64(e)) * full)
    if m < full or e == maxExp:
      return (e, uint32(min(m, full - 1)))

proc toInt(x: float64, lo, hi: int64, i: int): int64 =
  let r = round(x)
  if not (r >= float64(lo) and r <= float64(hi)):
    raiseFormat("sample " & $i & " = " & $x & " does not fit the integer format")
  int64(r)

proc encodeSegdSamples*[T: SegdSampleType](f: SegdSampleFormat, src: openArray[T],
    dst: var openArray[byte]) =
  ## Encodes `src` as format `f` into the start of `dst`. Exponent formats
  ## quantize (rounding to nearest) and clamp at full scale; integer formats
  ## round and refuse values out of range; NaN is refused by every format
  ## except the IEEE ones. Raises `SegFormatError`.
  let n = src.len
  doAssert dst.len >= dataBytes(f, n), "destination too short"
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
          let (ee, mag) = expFraction(x, 2.0, 15, 15, i)
          e = ee
          w = if x < 0 and mag != 0: uint16((not mag) and 0xFFFF) else: uint16(mag)
        if k mod 2 == 0: dst[10 * g + k div 2] = dst[10 * g + k div 2] or byte(e shl 4)
        else: dst[10 * g + k div 2] = dst[10 * g + k div 2] or byte(e)
        putBeU16(dst, 10 * g + 2 + 2 * k, w)
  of sd8022, sd8024:
    let bits = if f == sd8022: 4 else: 12
    for i in 0..<n:
      let x = float64(src[i])
      let (e, mag) = expFraction(x, 4.0, 7, bits, i)
      let mask = (1'u32 shl bits) - 1
      let neg = x < 0 and mag != 0
      let q = if neg: (not mag) and mask else: mag
      let s = if neg: 1'u32 else: 0'u32
      if f == sd8022: dst[i] = byte((s shl 7) or (uint32(e) shl 4) or q)
      else: putBeU16(dst, 2 * i, uint16((s shl 15) or (uint32(e) shl 12) or q))
  of sd8042, sd8044:
    let bits = if f == sd8042: 5 else: 13
    for i in 0..<n:
      let x = float64(src[i])
      var (e, mag) = expFraction(x, 16.0, 3, bits, i)
      let s = if x < 0 and mag != 0: 1'u32 else: 0'u32
      # All ones (negative full scale) is an invalid code: clamp one step in.
      if s == 1 and e == 3 and mag == (1'u32 shl bits) - 1: dec mag
      if f == sd8042: dst[i] = byte((s shl 7) or (uint32(e) shl 5) or mag)
      else: putBeU16(dst, 2 * i, uint16((s shl 15) or (uint32(e) shl 13) or mag))
  of sd8048:
    for i in 0..<n:
      if float64(src[i]).isNaN:
        raiseFormat("sample " & $i & " is NaN, which format 8048 cannot hold")
      var w = float32ToIbm(float32(src[i]))
      if (w and 1) != 0:
        # Round the 24-bit fraction to 23 bits; a carry renormalizes.
        var frac = (w and 0xFF_FFFF'u32) + 1
        var expo = (w shr 24) and 0x7F
        if frac == 0x100_0000'u32:
          if expo == 0x7F:
            frac = 0xFF_FFFE'u32 # already the largest exponent: clamp at full scale
          else:
            frac = 0x10_0000'u32
            inc expo
        w = (w and 0x8000_0000'u32) or (expo shl 24) or frac
      putBeU32(dst, 4 * i, w and not 1'u32)
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
