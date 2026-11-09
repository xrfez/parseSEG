## The branchless SEG-D 8015/8022/8024/8042/8044 and SEG-2 format-3
## decoders (15.3-2) against the branchy formulas they replaced, kept here as
## reference functions: bit for bit, on millions of random words (random
## signs, so both one's complement paths), float32 and float64 outputs, both
## 8015 complements, both SEG-2 byte orders, and every 16-bit word.

import std/[assertions, random]
import parseSEG/common/endians
import parseSEG/segd/samples as segdsamples
import parseSEG/seg2/samples as seg2samples

const
  pow4 = [1.0, 4.0, 16.0, 64.0, 256.0, 1024.0, 4096.0, 16384.0]
  pow16 = [1.0, 16.0, 256.0, 4096.0]

func onesFraction(q, mask: uint32, negative: bool): int =
  if negative: -int((not q) and mask) else: int(q)

func oldSegd[T](f: SegdSampleFormat, b: openArray[byte], i: int, twos: bool): T =
  # The pre-15.3 decoder formulas, verbatim.
  case f
  of sd8015:
    let g = i div 4
    let k = i mod 4
    let e = (b[10 * g + k div 2] shr (4 * (1 - k mod 2))) and 0xF
    let w = uint32(beU16(b, 10 * g + 2 + 2 * k))
    let m = if twos: int(cast[int16](uint16(w)))
            else: onesFraction(w and 0x7FFF, 0x7FFF, (w and 0x8000) != 0)
    T(float64(m) * (float64(1 shl e) / 32768.0))
  of sd8022:
    let x = uint32(b[i])
    let m = onesFraction(x and 0xF, 0xF, (x and 0x80) != 0)
    T(float64(m) / 16.0 * pow4[(x shr 4) and 7])
  of sd8024:
    let w = uint32(beU16(b, 2 * i))
    let m = onesFraction(w and 0xFFF, 0xFFF, (w and 0x8000) != 0)
    T(float64(m) / 4096.0 * pow4[(w shr 12) and 7])
  of sd8042:
    let x = uint32(b[i])
    let v = float64(x and 0x1F) / 32.0 * pow16[(x shr 5) and 3]
    T(if (x and 0x80) != 0: -v else: v)
  of sd8044:
    let w = uint32(beU16(b, 2 * i))
    let v = float64(w and 0x1FFF) / 8192.0 * pow16[(w shr 13) and 3]
    T(if (w and 0x8000) != 0: -v else: v)
  else: raiseAssert "not a branchless format"

func oldFloat20[T](b: openArray[byte], i: int, o: ByteOrder, twos: bool): T =
  let g = 10 * (i div 4)
  let k = i mod 4
  let e = (getNum[uint16](b, g, o) shr (4 * k)) and 0xF
  let w = getNum[uint16](b, g + 2 + 2 * k, o)
  let m =
    if twos: int(cast[int16](w))
    elif (w and 0x8000) != 0: -int((not w) and 0x7FFF)
    else: int(w)
  T(float64(m * (1 shl int(e))))

func sameBits[T: float32 | float64](a, b: T): bool =
  when T is float32: cast[uint32](a) == cast[uint32](b)
  else: cast[uint64](a) == cast[uint64](b)

var rng = initRand(1532)

proc randomBytes(n: int): seq[byte] =
  result = newSeq[byte](n)
  for x in result.mitems: x = byte(rng.rand(255))

proc everyWord(): seq[byte] =
  # Word i of the stream is i mod 65536, for 5 * 65536 words: 65536 and 5 are
  # coprime, so every 16-bit value sits at each of the 5 word slots of a
  # 10-byte group (the exponent word and the 4 fractions), and every byte is
  # an 8022/8042 sample.
  result = newSeq[byte](2 * 5 * 65536)
  for i in 0 ..< result.len div 2:
    putBeU16(result, 2 * i, uint16(i mod 65536))

func samplesIn(f: SegdSampleFormat, bytes: int): int =
  case f
  of sd8015: bytes div 10 * 4
  of sd8024, sd8044: bytes div 2
  else: bytes

proc checkSegd[T](f: SegdSampleFormat, b: openArray[byte], twos: bool) =
  let n = samplesIn(f, b.len) - 3 # not a multiple of 4: the 8015 tail path too
  var got = newSeq[T](n)
  decodeSegdSamples(f, b, got, twos)
  for i in 0..<n:
    let want = oldSegd[T](f, b, i, twos)
    doAssert sameBits(got[i], want),
      $f & " " & $T & " twos=" & $twos & " sample " & $i & ": " & $got[i] & " vs " & $want

proc checkFloat20[T](b: openArray[byte], o: ByteOrder, twos: bool) =
  let n = b.len div 10 * 4 - 3
  var got = newSeq[T](n)
  decodeSeg2Samples(s2Float20, b, got, o, twos)
  for i in 0..<n:
    let want = oldFloat20[T](b, i, o, twos)
    doAssert sameBits(got[i], want),
      "float20 " & $T & " " & $o & " twos=" & $twos & " sample " & $i & ": " & $got[i] &
        " vs " & $want

const RandomBytes = 5_000_000 # 2 M samples of 8015, 2.5 M of 8024, 5 M of 8022

block segd_random_words:
  let b = randomBytes(RandomBytes)
  for f in [sd8015, sd8022, sd8024, sd8042, sd8044]:
    for twos in (if f == sd8015: @[false, true] else: @[false]):
      checkSegd[float32](f, b, twos)
      checkSegd[float64](f, b, twos)

block segd_every_word:
  # Every word in every slot; the shifted view also puts each byte in both
  # halves of a word.
  let b = everyWord()
  for f in [sd8015, sd8022, sd8024, sd8042, sd8044]:
    for twos in (if f == sd8015: @[false, true] else: @[false]):
      checkSegd[float32](f, b, twos)
      checkSegd[float64](f, b, twos)
      checkSegd[float32](f, b.toOpenArray(2, b.len - 1), twos)

block seg2_float20_random_words:
  let b = randomBytes(RandomBytes)
  for o in [boLittle, boBig]:
    for twos in [false, true]:
      checkFloat20[float32](b, o, twos)
      checkFloat20[float64](b, o, twos)
  let w = everyWord()
  for o in [boLittle, boBig]:
    for twos in [false, true]:
      checkFloat20[float32](w, o, twos)
      checkFloat20[float32](w.toOpenArray(2, w.len - 1), o, twos)
