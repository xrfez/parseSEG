## Tests for SEG-Y sample codecs, Tensor decoding, byte-order detection and
## extended textual headers (task 3.2).

import std/[assertions, os, math, strutils]
import parseSEGD/common/[endians, errors]
import parseSEGD/segy/[textheader, binheader, traceheader, samples, exttext]
import parseSEGD/model/tensors

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"

proc readBytes(name: string): seq[byte] =
  let s = readFile(exampleDir / name)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc sumAbs(t: Tensor[float32], row: int): float64 =
  for j in 0..<t.shape[1]: result += abs(float64(t[row, j]))

block format_codes:
  var f: SampleFormat
  doAssert toSampleFormat(5, f) and f == sfFloat32 and sampleSize(f) == 4
  doAssert toSampleFormat(15, f) and sampleSize(f) == 3 and f.isRev2Format
  doAssert not toSampleFormat(13, f) and not toSampleFormat(0, f)
  doAssert sfFloat64.prefersFloat64 and not sfIbm32.isRev2Format

block every_format_round_trips_in_every_order:
  let values = [0.0, 1.0, -1.0, 100.0, -128.0, 127.0, 42.0]
  for f in definedSampleFormats:
    if f != sfFixedGain:
      for order in ByteOrder:
        if not (order == boPairSwapped and sampleSize(f) == 3):
          var vals: seq[float64]
          for v in values:
            if f in {sfUInt8, sfUInt16, sfUInt24, sfUInt32, sfUInt64}: vals.add abs(v)
            else: vals.add v
          var buf = newSeq[byte](vals.len * sampleSize(f))
          encodeSamples(f, vals, buf, order)
          var back = newSeq[float64](vals.len)
          decodeSamples(f, buf, back, order)
          doAssert back == vals, $f & " " & $order

block known_encodings:
  var b = newSeq[byte](8)
  encodeSamples(sfInt24, [-2.0], b)
  doAssert b[0..2] == @[0xFF'u8, 0xFF, 0xFE]
  encodeSamples(sfInt24, [-2.0], b, boLittle)
  doAssert b[0..2] == @[0xFE'u8, 0xFF, 0xFF]
  encodeSamples(sfIbm32, [-118.625'f32], b)
  doAssert b[0..3] == @[0xC2'u8, 0x76, 0xA0, 0x00] # the classic IBM example
  encodeSamples(sfInt16, [2.6'f32], b)
  doAssert beI16(b, 0) == 3 # rounds to nearest
  # Format 4: zero byte, gain 2, mantissa -400 -> -100.
  let fixed = [0'u8, 2, 0xFE, 0x70]
  var one = [0'f32]
  decodeSamples(sfFixedGain, fixed, one)
  doAssert one[0] == -100'f32

block encode_refuses_bad_values:
  var b = newSeq[byte](8)
  doAssertRaises SegFormatError: encodeSamples(sfInt16, [40000.0], b)
  doAssertRaises SegFormatError: encodeSamples(sfInt8, [NaN], b)
  doAssertRaises SegFormatError: encodeSamples(sfUInt16, [-1.0], b)
  doAssertRaises SegFormatError: encodeSamples(sfInt24, [9_000_000.0], b)
  doAssertRaises SegFormatError: encodeSamples(sfFixedGain, [1.0], b)
  doAssertRaises SegFormatError: encodeSamples(sfInt24, [1.0], b, boPairSwapped)
  var one = [0'f32]
  doAssertRaises SegTruncatedError: decodeSamples(sfFloat32, [1'u8, 2], one)
  doAssertRaises SegFormatError: encodeSamples(sfInt64, [1e30], b)
  encodeSamples(sfInt64, [float64(high(int64))], b) # = 2^63 as a float64: clamps
  doAssert beI64(b, 0) == high(int64)

block detect_byte_order:
  let sweep = readBytes("Sweep0.sgy")
  let d = detectByteOrder(sweep.toOpenArray(3200, 3599))
  doAssert d.order == boLittle and not d.fromMarker and d.plausible
  let ingle = readBytes("BO_3D-Inglewood_rev21_v7.sgy")
  let e = detectByteOrder(ingle.toOpenArray(3200, 3599))
  doAssert e.order == boBig and e.fromMarker and e.plausible
  # Re-encode Inglewood's header in each order; detection follows the marker
  # and, with the marker cleared, the plausibility score.
  let bh = decodeBinaryHeader(ingle.toOpenArray(3200, 3599), boBig)
  for order in ByteOrder:
    var b = newSeq[byte](BinaryHeaderSize)
    bh.encode(b, order)
    doAssert detectByteOrder(b).order == order and detectByteOrder(b).fromMarker
    for i in 96..99: b[i] = 0
    doAssert detectByteOrder(b).order == order, $order
  var junk = newSeq[byte](BinaryHeaderSize)
  for i in 0..<junk.len: junk[i] = 0xEE
  doAssert not detectByteOrder(junk).plausible

block sweep0_samples_into_tensor:
  let f = readBytes("Sweep0.sgy")
  let order = detectByteOrder(f.toOpenArray(3200, 3599)).order
  let th = decodeTraceHeader(f.toOpenArray(3600, 3839), order)
  let ns = int(th.numSamples)
  var t = newTraceTensor[float32](1, ns)
  t.decodeTrace(0, sfFloat32, f.toOpenArray(3840, f.len - 1), ns, order)
  doAssert t[0, 0] == -1.0624706874295953e-06'f32
  doAssert t[0, 6000] == -0.04068503528833389'f32
  doAssert abs(sumAbs(t, 0) - 36906.99097998912) < 1e-3
  var back = newSeq[byte](ns * 4)
  t.encodeTrace(0, sfFloat32, back, ns, order)
  doAssert back == f[3840..^1]

block inglewood_ibm_samples:
  let f = readBytes("BO_3D-Inglewood_rev21_v7.sgy")
  const first = 333200
  const recLen = 240 + 2001 * 4
  var t = newTraceTensor[float32](200, 2001)
  for k in 0..<200:
    let p = first + k * recLen + 240
    t.decodeTrace(k, sfIbm32, f.toOpenArray(p, p + 2001 * 4 - 1), 2001)
  doAssert t[100, 94] == -825.605712890625'f32
  doAssert t[100, 1000] == 5572.83203125'f32
  doAssert abs(sumAbs(t, 100) - 10533479.859054565) < 1.0
  doAssert sumAbs(t, 0) == 0.0
  # A trace range is a view on the same rows.
  let mid = t[100..101, _]
  doAssert mid[0, 1000] == 5572.83203125'f32
  # IBM -> float32 -> IBM is exact for these samples.
  var back = newSeq[byte](2001 * 4)
  t.encodeTrace(100, sfIbm32, back, 2001)
  let p = first + 100 * recLen + 240
  doAssert back == f[p..<p + 2001 * 4]

block inglewood_extended_header:
  let f = readBytes("BO_3D-Inglewood_rev21_v7.sgy")
  let bh = decodeBinaryHeader(f.toOpenArray(3200, 3599), boBig)
  var h = initExtendedTextHeader()
  var pos = 3600
  while h.needsMore(bh.numExtTextHeaders):
    h.add f.toOpenArray(pos, pos + TextHeaderSize - 1)
    pos += TextHeaderSize
  doAssert h.recordCount == 103 and pos == 333200
  doAssert h.data == f[3600..<333200] # lossless
  var keys: seq[string]
  for s in h.stanzas: keys.add s.key
  doAssert keys == @["SEG:LAYOUT", "OGP:P1/11", "OGP:P6/11", "SEG:CATALOG",
    "TROIKA:IMAGEPNG", "SEG:ENDTEXT"], $keys
  let layout = h.stanzas[0]
  doAssert layout.contentType == "text/xml" and not layout.isBinary
  doAssert h.stanzaText(layout).strip.startsWith("<?xml") or
    h.stanzaText(layout).contains("<")
  let png = h.stanzas[h.find("troika : imagepng")]
  doAssert png.isBinary and png.byteCount == 208104 and png.contentType == "image/png"
  let pngBytes = h.stanzaBytes(png)
  doAssert pngBytes.len == 208104
  doAssert pngBytes[0..7] == @[0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  doAssert pngBytes[^4..^1] == @[0xAE'u8, 0x42, 0x60, 0x82]
  doAssert h.stanzas[1].dataEnd == h.stanzas[2].headerStart # text runs to the next stanza
  doAssert h.stanzas[1].headerStart == 1 * TextHeaderSize
  doAssert h.stanzas[2].headerStart == 13 * TextHeaderSize
  doAssert h.hasEndText

block build_and_reparse:
  var w = initExtendedTextHeader()
  w.addText("SEG", "Catalog", "{\"a\": 1}", "application/json")
  var blob = newSeq[byte](5000)
  for i in 0..<blob.len: blob[i] = byte(i mod 256)
  blob[3200] = 0x28 # a continuation record that starts with "((" by chance
  blob[3201] = 0x28
  blob[3200 - 15] = 0x28
  w.addStanza("ACME", "Blob", blob, "application/octet-stream", binary = true)
  w.addEndText(teEbcdic)
  doAssert w.recordCount == 1 + 2 + 1
  var r = initExtendedTextHeader()
  var i = 0
  while r.needsMore(-1):
    r.add w.data.toOpenArray(i, i + TextHeaderSize - 1)
    i += TextHeaderSize
  doAssert r.recordCount == 4 and r.data == w.data
  doAssert r.stanzas.len == 3
  doAssert r.stanzaText(r.stanzas[0]) == "{\"a\": 1}"
  doAssert r.stanzaBytes(r.stanzas[1]) == blob
  doAssert r.stanzas[2].isEndText and r.stanzas[2].encoding == teEbcdic
  # A positive count is trusted even without EndText.
  var c = initExtendedTextHeader()
  c.add w.data.toOpenArray(0, TextHeaderSize - 1)
  doAssert not c.needsMore(1) and c.needsMore(2) and not c.needsMore(0)

block rev1_stanzas_on_card_lines:
  var text = ""
  for line in ["((SEG: Location Data ver 1.0))", "CRS type = projected",
      "((SEG: Data Sample Measurement Unit ver 1.0))", "Volt conversion = 1.0"]:
    text.add alignLeft(line, CardWidth)
  var rec = encodeText(alignLeft(text, TextHeaderSize), teEbcdic)
  var h = initExtendedTextHeader(rev1Lines = true)
  h.add rec
  doAssert h.stanzas.len == 2
  doAssert h.stanzas[0].key == "SEG:LOCATIONDATAVER1.0"
  doAssert h.stanzaText(h.stanzas[0]).strip == "CRS type = projected"
  doAssert h.stanzas[1].headerStart == 2 * CardWidth
  doAssert h.find("SEG:Data Sample Measurement Unit ver 1.0") == 1
  var h2 = initExtendedTextHeader()
  h2.add rec
  doAssert h2.stanzas.len == 1 # Rev 2 rule: record starts only
