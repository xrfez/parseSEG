## The conversions' one-pass sample encoders (`private/sampleconv`, 15.3-8)
## against their oracle, `encodeExact`: same bytes, same verdict, same
## raises, for every SEG-Y format and byte order.

import std/[assertions, math, random]
import parseSEG/common/[endians, errors]
import parseSEG/segy/samples
import parseSEG/segd/samples as segdsamples
import parseSEG/private/sampleconv

var rng = initRand(1538)

proc values(kind, n: int): seq[float64] =
  # Trace-like value sets: small integers, wide integers, float32 values,
  # float64 values, IBM-exact values, and specials.
  const specials = [0.0, -0.0, 1.0, -1.0, 0.5, 127.0, -128.0, 255.0, 32767.0, -32768.0,
    65535.0, 8388607.0, -8388608.0, 16777215.0, 2147483647.0, -2147483648.0, 4294967295.0,
    1e30, -1e-30, 3.4028234663852886e38, 1e39, Inf, -Inf, NaN, 0.49999999999999994, 2.5]
  for i in 0..<n:
    result.add case kind
      of 0: float64(rng.rand(-130..130))
      of 1: float64(rng.rand(-40000..70000))
      of 2: float64(rng.rand(-3_000_000_000'i64..5_000_000_000'i64))
      of 3: float64(float32(rng.gauss(0, 1000)))
      of 4: rng.gauss(0, 1e6)
      of 5: float64(rng.rand(-1 shl 20..1 shl 20)) * 16.0 # IBM-exact
      of 6: float64(rng.rand(0..255))
      of 7: float64(rng.rand(-8388608..8388607))
      else: specials[rng.rand(specials.high)]

block encode_checked_matches_encode_exact:
  for fmt in definedSampleFormats:
    for order in [boBig, boLittle, boPairSwapped]:
      for kind in 0..8:
        for n in [0, 1, 7, 64]:
          let vals = values(kind, n)
          var a, b: seq[byte]
          var sa, sb: seq[float64]
          var ra, rb: bool
          var ea, eb = ""
          try: ra = encodeExact(fmt, vals, a, order, sa)
          except SegFormatError as e: ea = e.msg
          try: rb = encodeChecked(fmt, vals, b, order, sb)
          except SegFormatError as e: eb = e.msg
          doAssert ea == eb, $fmt & " " & $order & ": " & ea & " | " & eb
          if ea.len == 0:
            doAssert ra == rb, $fmt & " " & $order & " kind " & $kind
            doAssert a == b, $fmt & " " & $order & " kind " & $kind

block copy_float_words_matches_the_float64_round_trip:
  # Random words (NaNs with payloads, signaling ones, denormals included):
  # the bytes of decode to float64 + encode, in every pair of orders.
  for (sf, size) in [(sd8058, 4), (sd9058, 4), (sd8080, 8), (sd9080, 8)]:
    let srcOrder = if sf.isLittleEndian: boLittle else: boBig
    let fmt = if size == 4: sfFloat32 else: sfFloat64
    for n in [0, 1, 33, 1000]:
      var raw = newSeq[byte](size * n)
      for x in raw.mitems: x = byte(rng.rand(255))
      for i in 0..<n div 8: # NaN and infinity exponents
        let at = size * rng.rand(n - 1)
        let hi = if srcOrder == boBig: at else: at + size - 1
        raw[hi] = raw[hi] or 0x7F
        let next = if srcOrder == boBig: hi + 1 else: hi - 1
        raw[next] = raw[next] or (if size == 4: 0x80 else: 0xF0)
      var vals = newSeq[float64](n)
      decodeSegdSamples(sf, raw, vals)
      for dstOrder in [boBig, boLittle, boPairSwapped]:
        var want = newSeq[byte](size * n)
        encodeSamples(fmt, vals, want, dstOrder)
        var got: seq[byte]
        if size == 4: copyFloatWords(float32, raw, srcOrder, n, got, dstOrder)
        else: copyFloatWords(float64, raw, srcOrder, n, got, dstOrder)
        doAssert got == want, $sf & " -> " & $dstOrder & " n " & $n
