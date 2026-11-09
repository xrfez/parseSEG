## The unchecked sample decoders of task 13.2 (pointer loads, native-order
## copies, the IBM float table, the SEG-D exponent tables) against plain
## reference decoders written from the spec, byte for byte: every format,
## byte order and output type, odd lengths, IBM bit patterns across the whole
## exponent range (overflow to Inf, subnormal and zero results), and the
## truncation checks that guard the unchecked loops.

import std/[assertions, math, random]
import std/macros
import parseSEG/common/[endians, ibmfloat, errors, fieldlayout]
import parseSEG/segy/[traceheader, binheader]
import parseSEG/segd/headers as segdheaders
import parseSEG/seg2/headers as seg2headers
import parseSEG/segy/samples
import parseSEG/segd/samples as segdsamples
import parseSEG/seg2/samples as seg2samples

func ldexp(x: float64, e: cint): float64 {.importc: "ldexp", header: "<math.h>".}

func refIbm64(bits: uint32): float64 =
  # The pre-13.2 conversion: fraction * 2^(4 * (exponent - 64) - 24).
  let frac = bits and 0x00FF_FFFF'u32
  if frac == 0: return 0.0
  let mag = ldexp(float64(frac), cint(4 * (int((bits shr 24) and 0x7F) - 64) - 24))
  if (bits and 0x8000_0000'u32) != 0: -mag else: mag

proc sameBits[T: float32 | float64](a, b: T): bool =
  when T is float32: cast[uint32](a) == cast[uint32](b)
  else: cast[uint64](a) == cast[uint64](b)

var rng = initRand(1302)

proc randomBytes(n: int): seq[byte] =
  result = newSeq[byte](n)
  for b in result.mitems: b = byte(rng.rand(255))

block ibm_float_matches_the_ldexp_reference:
  var checked = 0
  for e in 0'u32..255'u32:
    for frac in [0'u32, 1, 2, 0xF, 0x10, 0xFFFF, 0x10_0000, 0x7F_FFFF, 0x80_0000, 0xFF_FFFF,
        0x12_3456]:
      let bits = (e shl 24) or frac
      doAssert sameBits(ibmToFloat64(bits), refIbm64(bits)), $bits
      doAssert sameBits(ibmToFloat32(bits), float32(refIbm64(bits))), $bits
      inc checked
  for _ in 1..200_000:
    let bits = uint32(rng.rand(int(high(uint32))))
    doAssert sameBits(ibmToFloat32(bits), float32(refIbm64(bits))), $bits
    doAssert sameBits(ibmToFloat64(bits), refIbm64(bits)), $bits
  # Edge results: zero of either sign, the largest magnitude, Inf, subnormals.
  doAssert ibmToFloat32(0x8000_0000'u32) == 0 and not signbit(ibmToFloat32(0x8000_0000'u32))
  doAssert ibmToFloat32(0x7FFF_FFFF'u32) == Inf and ibmToFloat32(0xFFFF_FFFF'u32) == -Inf
  doAssert ibmToFloat64(0x7FFF_FFFF'u32) == refIbm64(0x7FFF_FFFF'u32)
  doAssert ibmToFloat32(0x0000_0001'u32) == 0                  # 2^-280: rounds to zero
  doAssert ibmToFloat32(0x2110_0000'u32) == ldexp(1.0, -128)   # a float32 subnormal
  doAssert ibmToFloat32(0x4110_0000'u32) == 1.0 and ibmToFloat32(0xC276_A000'u32) == -118.625
  doAssert checked == 256 * 11

proc refSegy[T](f: SampleFormat, b: openArray[byte], n: int, o: ByteOrder): seq[T] =
  # One sample at a time through the checked `getNum` accessors.
  result = newSeq[T](n)
  for i in 0..<n:
    result[i] = case f
      of sfIbm32:
        when T is float64: ibmToFloat64(getNum[uint32](b, 4*i, o))
        else: ibmToFloat32(getNum[uint32](b, 4*i, o))
      of sfInt32: T(getNum[int32](b, 4*i, o))
      of sfInt16: T(getNum[int16](b, 2*i, o))
      of sfFixedGain:
        let w = getNum[uint32](b, 4*i, o)
        T(float64(cast[int16](uint16(w and 0xFFFF))) * pow(2.0, -float64((w shr 16) and 0xFF)))
      of sfFloat32: T(getNum[float32](b, 4*i, o))
      of sfFloat64: T(getNum[float64](b, 8*i, o))
      of sfInt24, sfUInt24:
        let u = if o == boLittle:
            uint32(b[3*i]) or (uint32(b[3*i+1]) shl 8) or (uint32(b[3*i+2]) shl 16)
          else: beU24(b, 3*i)
        if f == sfInt24: T(cast[int32](u shl 8) shr 8) else: T(u)
      of sfInt8: T(cast[int8](b[i]))
      of sfInt64: T(getNum[int64](b, 8*i, o))
      of sfUInt32: T(getNum[uint32](b, 4*i, o))
      of sfUInt16: T(getNum[uint16](b, 2*i, o))
      of sfUInt64: T(getNum[uint64](b, 8*i, o))
      of sfUInt8: T(b[i])

proc checkSegy[T](f: SampleFormat, o: ByteOrder, n: int) =
  let b = randomBytes(n * sampleSize(f) + 3)
  var got = newSeq[T](n)
  decodeSamples(f, b, got, o)
  let want = refSegy[T](f, b, n, o)
  for i in 0..<n:
    doAssert sameBits(got[i], want[i]) or (got[i].isNaN and want[i].isNaN),
      $f & " " & $o & " " & $T & " sample " & $i

block segy_formats_orders_and_types:
  for f in definedSampleFormats:
    for o in ByteOrder:
      if not (o == boPairSwapped and f in {sfInt24, sfUInt24}):
        for n in [0, 1, 3, 7, 64, 1001]:
          checkSegy[float32](f, o, n)
          checkSegy[float64](f, o, n)

block segy_length_checks_still_guard_the_loops:
  var dst = newSeq[float32](10)
  let short = newSeq[byte](39)
  for f in [sfFloat32, sfIbm32, sfInt32]:
    doAssertRaises(SegTruncatedError): decodeSamples(f, short, dst, boBig)
    doAssertRaises(SegTruncatedError): decodeSamples(f, short, dst, boLittle)
  doAssertRaises(SegFormatError): decodeSamples(sfInt24, newSeq[byte](30), dst, boPairSwapped)
  var none: seq[float32]
  decodeSamples(sfFloat32, short.toOpenArray(0, -1), none, boBig) # empty: no access

func ones(q, mask: uint32, neg: bool): float64 =
  if neg: float64(-int((not q) and mask)) else: float64(q) # an integer: never -0

proc refSegd[T](f: SegdSampleFormat, b: openArray[byte], n: int, twos: bool): seq[T] =
  # From the format definitions (segd_rev2_0.md §5), with pow and division.
  result = newSeq[T](n)
  for i in 0..<n:
    result[i] = case f
      of sd8015:
        let g = 10 * (i div 4)
        let k = i mod 4
        let e = if k mod 2 == 0: b[g + k div 2] shr 4 else: b[g + k div 2] and 0xF
        let w = uint32(beU16(b, g + 2 + 2 * k))
        let m = if twos: float64(cast[int16](uint16(w)))
                else: ones(w and 0x7FFF, 0x7FFF, (w and 0x8000) != 0)
        T(m / 32768.0 * pow(2.0, float64(e)))
      of sd8022:
        let x = uint32(b[i])
        T(ones(x and 0xF, 0xF, (x and 0x80) != 0) / 16.0 * pow(4.0, float64((x shr 4) and 7)))
      of sd8024:
        let w = uint32(beU16(b, 2 * i))
        T(ones(w and 0xFFF, 0xFFF, (w and 0x8000) != 0) / 4096.0 *
          pow(4.0, float64((w shr 12) and 7)))
      of sd8042:
        let x = uint32(b[i])
        let v = float64(x and 0x1F) / 32.0 * pow(16.0, float64((x shr 5) and 3))
        T(if (x and 0x80) != 0: -v else: v)
      of sd8044:
        let w = uint32(beU16(b, 2 * i))
        let v = float64(w and 0x1FFF) / 8192.0 * pow(16.0, float64((w shr 13) and 3))
        T(if (w and 0x8000) != 0: -v else: v)
      of sd8048:
        when T is float64: ibmToFloat64(beU32(b, 4 * i)) else: ibmToFloat32(beU32(b, 4 * i))
      of sd8036: T(beI24(b, 3 * i))
      of sd8038: T(beI32(b, 4 * i))
      of sd8058: T(beF32(b, 4 * i))
      of sd8080: T(beF64(b, 8 * i))
      of sd9036:
        let u = uint32(b[3*i]) or (uint32(b[3*i+1]) shl 8) or (uint32(b[3*i+2]) shl 16)
        T(cast[int32](u shl 8) shr 8)
      of sd9038: T(getNum[int32](b, 4 * i, boLittle))
      of sd9058: T(getNum[float32](b, 4 * i, boLittle))
      of sd9080: T(getNum[float64](b, 8 * i, boLittle))

proc checkSegd[T](f: SegdSampleFormat, n: int, twos: bool) =
  let b = randomBytes(dataBytes(f, n) + 5)
  var got = newSeq[T](n)
  decodeSamples(f, b, got, twos)
  let want = refSegd[T](f, b, n, twos)
  for i in 0..<n:
    doAssert sameBits(got[i], want[i]) or (got[i].isNaN and want[i].isNaN),
      $f & " " & $T & " sample " & $i & ": " & $got[i] & " vs " & $want[i]

block segd_formats_and_types:
  for f in segdSampleFormats:
    for n in [0, 1, 2, 3, 4, 5, 7, 8, 1001]:
      for twos in [false, true]:
        checkSegd[float32](f, n, twos)
        checkSegd[float64](f, n, twos)
  var dst = newSeq[float32](8)
  doAssertRaises(SegTruncatedError): decodeSamples(sd8015, newSeq[byte](19), dst)
  doAssertRaises(SegTruncatedError): decodeSamples(sd9058, newSeq[byte](31), dst)

proc checkSeg2[T](f: Seg2SampleFormat, o: ByteOrder, n: int, twos: bool) =
  let b = randomBytes(dataBytes(f, n) + 2)
  var got = newSeq[T](n)
  decodeSamples(f, b, got, o, twos)
  for i in 0..<n:
    let want = case f
      of s2Int16: T(getNum[int16](b, 2*i, o))
      of s2Int32: T(getNum[int32](b, 4*i, o))
      of s2Float32: T(getNum[float32](b, 4*i, o))
      of s2Float64: T(getNum[float64](b, 8*i, o))
      of s2Float20:
        let g = 10 * (i div 4)
        let e = (getNum[uint16](b, g, o) shr (4 * (i mod 4))) and 0xF
        let w = getNum[uint16](b, g + 2 + 2 * (i mod 4), o)
        let m = if twos: int(cast[int16](w))
                elif (w and 0x8000) != 0: -int((not w) and 0x7FFF)
                else: int(w)
        T(float64(m * (1 shl int(e))))
    doAssert sameBits(got[i], want) or (got[i].isNaN and want.isNaN), $f & " " & $o & " " & $i

block seg2_formats_orders_and_types:
  for f in Seg2SampleFormat:
    for o in [boLittle, boBig]:
      for n in [0, 1, 4, 5, 999]:
        for twos in [false, true]:
          checkSeg2[float32](f, o, n, twos)
          checkSeg2[float64](f, o, n, twos)
  var dst = newSeq[float64](4)
  doAssertRaises(SegTruncatedError):
    decodeSamples(s2Float64, newSeq[byte](31), dst, boLittle)

echo "tfastcodecs: ok"

block decode_fields_unchecked_loads_match_get_num:
  # 15.3-3: `decodeFields` loads `at` fields unchecked, with the byte order
  # picked once; compare each field with the checked `getNum`, in every order.
  doAssert layoutBytes(SegyTraceHeader, 1) == TraceHeaderSize
  doAssert layoutBytes(SegyBinaryHeader, 3201) <= BinaryHeaderSize
  doAssert layoutBytes(Seg2TraceFixed, 0) == 13 # 0-based: bytes 0..12
  doAssert layoutBytes(SegdGeneralHeader1, 1) == 32
  proc check[T](firstByte: static int, size: int) =
    for o in ByteOrder:
      for _ in 0..<200:
        let b = randomBytes(size)
        var h: T
        decodeFields(h, b, firstByte, o)
        for _, v in fieldPairs(h):
          when v.hasCustomPragma(at) and v isnot array:
            const pos = v.getCustomPragmaVal(at) - firstByte
            doAssert v == getNum[typeof(v)](b, pos, o) or (v != v) # NaN floats
  check[SegyTraceHeader](1, TraceHeaderSize)
  check[SegyTraceHeaderExt1](1, TraceHeaderSize)
  check[SegyBinaryHeader](3201, BinaryHeaderSize)
  check[Seg2TraceFixed](0, Seg2FixedSize)
  var h: SegyTraceHeader
  doAssertRaises(SegTruncatedError): decodeFields(h, newSeq[byte](239), 1, boBig)

block host_order_copy_is_exact:
  # 15.3-5: a plain loop under AVX2 (`-march=x86-64-v3`), `copyMem` otherwise;
  # both must copy every byte, from any source alignment, and nothing more.
  var r = initRand(5)
  var src = newSeq[byte](4 * 1100 + 3)
  for b in src.mitems: b = byte(r.rand(255))
  for shift in 0..3:
    for words in [0, 1, 7, 8, 9, 31, 64, 1000, 1100]:
      if shift + 4 * words > src.len: continue
      var dst = newSeq[uint32](words + 1)
      dst[words] = 0xDEADBEEF'u32
      if words > 0:
        copyHostOrder(addr dst[0], byteBuf(src.toOpenArray(shift, src.len - 1)), 4 * words)
      for i in 0..<words:
        var want: uint32
        copyMem(addr want, addr src[shift + 4 * i], 4)
        doAssert dst[i] == want
      doAssert dst[words] == 0xDEADBEEF'u32
