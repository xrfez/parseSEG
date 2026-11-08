## SEG-2 sample codecs on byte buffers (spec note `seg2.md` §4.4, §5).
##
## | Code | Format | Bytes |
## |---|---|---|
## | 1 | 16-bit two's complement integer | 2 |
## | 2 | 32-bit two's complement integer | 4 |
## | 3 | 20-bit floating point (exponent word + 4 mantissa words) | 10 per 4 samples |
## | 4 | IEEE single | 4 |
## | 5 | IEEE double | 8 |
##
## Every 16, 32 and 64-bit unit is stored in the file's byte order (set by
## the File Descriptor Block ID). Format 3 is SEG-2's own variant of SEG-D
## 8015: the exponent of sample k of a group is bits 4k..4k+3 of the first
## word (sample 1 in the low nibble of the low byte), and each mantissa word
## is a 15-bit one's complement *integer* with a sign bit, so a value is
## `mantissa * 2^exponent` (at most 32767 * 2^15). No format-3 sample file
## exists yet; `twosComplement` reads the mantissas as two's complement, for
## writers that use it. `encodeSeg2Samples` is the inverse. This module has
## no Arraymancer dependency.

import std/[math, options]
import ../common/[endians, errors]
export options

type
  Seg2Format* = enum
    ## A SEG-2 sample format, by its code (Trace Descriptor Block byte 12).
    s2Int16 = 1   ## 16-bit two's complement integer.
    s2Int32 = 2   ## 32-bit two's complement integer.
    s2Float20 = 3 ## 20-bit floating point: 4 samples in 10 bytes.
    s2Float32 = 4 ## IEEE single.
    s2Float64 = 5 ## IEEE double.

  Seg2SampleType* = float32 | float64 ## Sample types the codecs decode into.

func toSeg2Format*(code: int): Option[Seg2Format] =
  ## The sample format of a format code; none for codes outside 1..5.
  if code in ord(low(Seg2Format))..ord(high(Seg2Format)): some(Seg2Format(code))
  else: none(Seg2Format)

func dataBytes*(f: Seg2Format, samples: int): int =
  ## Bytes holding `samples` samples (without the Data Block's padding to a
  ## multiple of 4). Format 3 packs 4 samples in 10 bytes; a count that is
  ## not a multiple of 4 (spec-invalid) is rounded up to whole groups.
  case f
  of s2Int16: 2 * samples
  of s2Int32, s2Float32: 4 * samples
  of s2Float64: 8 * samples
  of s2Float20: (samples + 3) div 4 * 10

func samplesIn*(f: Seg2Format, bytes: int): int =
  ## How many whole samples (format 3: whole groups of 4) `bytes` bytes hold.
  let b = max(bytes, 0)
  case f
  of s2Int16: b div 2
  of s2Int32, s2Float32: b div 4
  of s2Float64: b div 8
  of s2Float20: b div 10 * 4

func prefersFloat64*(f: Seg2Format): bool {.inline.} =
  ## True when float32 cannot hold the format's values without losing
  ## precision: IEEE double.
  f == s2Float64

func float20Value(e, w: uint16, twosComplement: bool): float64 {.inline.} =
  # One format-3 sample: mantissa word `w` scaled by 2^e.
  let m =
    if twosComplement: int(cast[int16](w))
    elif (w and 0x8000) != 0: -int((not w) and 0x7FFF) # one's complement
    else: int(w)
  float64(m * (1 shl int(e)))

proc decodeSeg2Samples*[T: Seg2SampleType](f: Seg2Format, src: openArray[byte],
    dst: var openArray[T], order: ByteOrder, twosComplement = false) =
  ## Decodes `dst.len` samples of format `f`, stored in `order`, from the
  ## start of `src`. `twosComplement` reads format-3 mantissas as two's
  ## complement instead of the spec's one's complement. Raises
  ## `SegTruncatedError` if `src` is shorter than `dataBytes(f, dst.len)`.
  let n = dst.len
  let need = dataBytes(f, n)
  if src.len < need:
    raiseTruncated("trace data has " & $src.len & " bytes, " & $need & " needed for " & $n &
      " samples")
  if n == 0: return
  let s = byteBuf(src)
  let d = cast[ptr UncheckedArray[T]](addr dst[0])
  template loop(o: static ByteOrder) =
    {.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
    # Lengths are checked above; the loops load through unchecked pointers.
    case f
    of s2Int16:
      for i in 0..<n: d[i] = T(loadNum[int16](s, 2*i, o))
    of s2Int32:
      for i in 0..<n: d[i] = T(loadNum[int32](s, 4*i, o))
    of s2Float32:
      when T is float32 and o == hostOrder: copyMem(d, s, 4 * n)
      else:
        for i in 0..<n: d[i] = T(loadNum[float32](s, 4*i, o))
    of s2Float64:
      when T is float64 and o == hostOrder: copyMem(d, s, 8 * n)
      else:
        for i in 0..<n: d[i] = T(loadNum[float64](s, 8*i, o))
    of s2Float20:
      for i in 0..<n:
        let g = 10 * (i div 4)
        let k = i mod 4
        let e = (loadNum[uint16](s, g, o) shr (4 * k)) and 0xF
        d[i] = T(float20Value(e, loadNum[uint16](s, g + 2 + 2 * k, o), twosComplement))
    {.pop.}
  if order == boLittle: loop(boLittle) else: loop(boBig)

proc toInt(x: float64, lo, hi: int64, i: int): int64 =
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

proc encodeSeg2Samples*[T: Seg2SampleType](f: Seg2Format, src: openArray[T],
    dst: var openArray[byte], order: ByteOrder, twosComplement = false) =
  ## Encodes `src` as format `f`, stored in `order`, into the start of `dst`
  ## (at least `dataBytes(f, src.len)` bytes). Integer formats round to
  ## nearest; format 3 picks per sample the smallest exponent that holds the
  ## rounded mantissa (so integers up to 32767 are exact), with one's
  ## complement mantissas unless `twosComplement`, and zero-fills a last
  ## partial group. Raises `SegFormatError` for a value the format cannot
  ## hold (NaN or out of range in an integer format or format 3) and
  ## `ValueError` when `dst` is too short.
  let n = src.len
  let need = dataBytes(f, n)
  if dst.len < need:
    raise newException(ValueError, "the destination has " & $dst.len & " bytes, " & $need &
      " needed for " & $n & " samples")
  template loop(o: static ByteOrder) =
    case f
    of s2Int16:
      for i in 0..<n: putNum(dst, 2*i, int16(toInt(float64(src[i]), -32768, 32767, i)), o)
    of s2Int32:
      for i in 0..<n:
        putNum(dst, 4*i, int32(toInt(float64(src[i]), int64(low(int32)), int64(high(int32)), i)), o)
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
