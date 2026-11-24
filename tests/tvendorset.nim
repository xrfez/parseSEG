## Vendor maps, the write side: `setVendorField` and `clearVendorField` put a value
## into a block's bytes so that `decode` reads it back; nothing else changes.
## Seen to fail when the guarded code is broken: dropping the range check in
## `setVendorField` fails `out_of_range_raises`; writing a whole byte for a nibble
## field fails `nibbles_leave_their_neighbours`; a count that ignores the field's
## sentinel or the strides that fit fails `repeat_count_is_decodes`; taking the first
## target that names the field fails `target_choice_follows_decode`; dropping the
## sentinel check fails `value_equal_to_sentinel_is_refused`.

import std/[assertions, options, os, strutils]

import parseSEG/vendor/maps
import parseSEG/common/[endians, diagnostics]

const here = currentSourcePath().parentDir

const mapText = """(.nif27)
(vendormap "setter" (version 1) (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name all)
    (field u8f (at 1) (enc u8))
    (field u16f (at 2) (enc u16))
    (field u24f (at 4) (enc u24))
    (field u32f (at 7) (enc u32))
    (field u64f (at 11) (enc u64))
    (field i8f (at 19) (enc i8))
    (field i16f (at 20) (enc i16))
    (field i24f (at 22) (enc i24))
    (field i32f (at 25) (enc i32))
    (field i64f (at 29) (enc i64))
    (field f32f (at 37) (enc f32))
    (field f64f (at 41) (enc f64))
    (field textf (at 49) (len 8) (enc ascii) (trim right))
    (field rawf (at 57) (len 4) (enc raw))
    (field nibA (at 61) (len 3 n) (enc unibble))
    (field nibB (at 62) (nibble low) (len 3 n) (enc inibble))
    (field bcdf (at 65) (len 4 n) (enc bcd))
    (field littleU32 (at 67) (enc u32) (byteOrder little))
    (field littleI24 (at 71) (enc i24) (byteOrder little))
    (field scaled (at 74) (enc i16) (scale 0.01) (offset 1.0))
    (field ebc (at 76) (len 4) (enc ebcdic) (trim right))
    (field withSentinel (at 80) (enc u16) (sentinel 0xFFFF))
    (field sentI24 (at 82) (enc i24) (sentinel 0xFFFFFF))
    (field mode (at 85) (enc u8))
    (field onlyMode1 (at 86) (enc u8) (when (field mode) (is 1)))
    (field ibm (at 88) (enc ibm32))
    (field count (at 92) (enc u8))
    (repeat (count (ref count)) (stride 2) (at 93) (field item (at 1) (enc u16)))))"""

proc ctx(): VendorContext =
  VendorContext(format: skSegd, revision: VendorRevision(major: 2), manufacturer: 1,
    serial: -1, byteOrder: boBig)

let ea = VendorArea(kind: vtExtendedHeader, blockIndex: 1, blockType: -1, extIndex: -1)

proc intV(v: int64): VendorValue = VendorValue(kind: vvInt, intVal: v)
proc floatV(v: float64): VendorValue = VendorValue(kind: vvFloat, floatVal: v)
proc textV(s: string): VendorValue = VendorValue(kind: vvText, text: s)
proc bytesV(b: seq[byte]): VendorValue = VendorValue(kind: vvBytes, bytes: b)

proc fresh(): seq[byte] =
  ## 100 bytes of a pattern no field value equals.
  result = newSeq[byte](100)
  for i in 0..<100: result[i] = byte(0xA5 xor (i * 7))
  result[84] = 1 # mode
  result[91] = 3 # count

proc read(reg: VendorRegistry, b: seq[byte]): VendorBlock =
  var l: DiagLog
  let r = reg.decode(ctx(), ea, b, l)
  doAssert r.isSome
  r.get

proc changed(a, b: seq[byte]): seq[int] =
  for i in 0..<a.len:
    if a[i] != b[i]: result.add i

proc raises(reg: VendorRegistry, b: var seq[byte], field: string, v: VendorValue,
    part: string): bool =
  # True when setting raises ValueError whose message holds `part`, leaving `b` as it was.
  let before = b
  try:
    reg.setVendorField(ctx(), ea, b, field, v)
  except ValueError as e:
    return part in e.msg and b == before


proc mk(body: string): VendorRegistry =
  result.addMap loadVendorMap("(.nif27)\n(vendormap \"t\" (version 1) (match (format segd)) " &
    body & ")")

proc whole(r: VendorRegistry, b: seq[byte]): VendorBlock =
  # The first block `decode` gives.
  r.read(b)

proc refuses(r: VendorRegistry, b: var seq[byte], field: string, v: VendorValue): bool =
  let before = b
  try:
    r.setVendorField(ctx(), ea, b, field, v)
  except ValueError:
    return b == before

proc moreTests() =
  block messages_of_odd_numbers_are_value_errors:
    # A vvInt into a field whose scale or offset makes the raw value infinite.
    for body in ["(field x (at 1) (enc i32) (scale 1e-320))",
        "(field x (at 1) (enc i32) (offset 1e999))"]:
      let r = mk("(target (kind extendedHeader) (blockIndex 1) " & body & ")")
      var b = newSeq[byte](8)
      doAssert r.refuses(b, "x", intV(10_000_000_000))

  block repeat_count_is_decodes:
    let hdr = "(target (kind extendedHeader) (blockIndex 1) "
    # 11 bytes, stride 4 from byte 2: only 2 whole strides fit, so item[2] is not decoded.
    let r = mk(hdr & "(field n (at 1) (enc u8)) (repeat (count (ref n)) (stride 4) (at 2) " &
      "(field item (at 1) (enc u8))))")
    var b = newSeq[byte](11)
    b[0] = 3
    doAssert r.refuses(b, "item[2]", intV(9))
    r.setVendorField(ctx(), ea, b, "item[1]", intV(9))
    doAssert r.whole(b)["item[1]"].intVal == 9 and "item[2]" notin r.whole(b)
    # A count field at its sentinel, scaled, or off by its own (when) leaves no elements.
    let sent = mk(hdr & "(field n (at 1) (enc u8) (sentinel 5)) (repeat (count (ref n)) " &
      "(stride 1) (at 2) (field item (at 1) (enc u8))))")
    var c = newSeq[byte](32)
    c[0] = 5
    doAssert sent.refuses(c, "item[1]", intV(9))
    let scaled = mk(hdr & "(field n (at 1) (enc u8) (scale 1)) (repeat (count (ref n)) " &
      "(stride 1) (at 2) (field item (at 1) (enc u8))))")
    c[0] = 4
    doAssert scaled.refuses(c, "item[1]", intV(9))
    let gated = mk(hdr & "(field mode (at 3) (enc u8)) (field n (at 1) (enc u8) " &
      "(when (field mode) (is 1))) (repeat (count (ref n)) (stride 1) (at 4) " &
      "(field item (at 1) (enc u8))))")
    doAssert gated.refuses(c, "item[1]", intV(9))
    # Names that are not a plain run of digits are no element.
    let fixed = mk(hdr & "(repeat (count 3) (stride 1) (at 1) (field item (at 1) (enc u8))))")
    var d = newSeq[byte](8)
    for nm in ["item[+1]", "item[1_0]", "item[-1]", "item[]", "item[ 1]", "item[3]"]:
      doAssert fixed.refuses(d, nm, intV(9)), nm
    fixed.setVendorField(ctx(), ea, d, "item[01]", intV(9))
    doAssert d[1] == 9

  block target_choice_follows_decode:
    let hdr = "(target (kind extendedHeader) (blockIndex 1) "
    # The first target's x is off by its (when); the later one is where x is decoded.
    let r = mk(hdr & "(name a) (field mode (at 1) (enc u8)) (field x (at 2) (enc u8) " &
      "(when (field mode) (is 1)))) " & hdr & "(name b) (field x (at 3) (enc u8)))")
    var b = newSeq[byte](32)
    r.setVendorField(ctx(), ea, b, "x", intV(7))
    doAssert b[2] == 7 and b[1] == 0 and r.whole(b)["x"].intVal == 7
    b[0] = 1 # now the first target decodes x: it is the one written
    r.setVendorField(ctx(), ea, b, "x", intV(8))
    doAssert b[1] == 8 and r.whole(b)["x"].intVal == 8
    # A target with `match` before a positional one with the same name: decode() gives
    # the positional block first.
    let m = mk(hdr & "(name m) (match (at 1) (bytes 0)) (field x (at 2) (enc u8))) " & hdr &
      "(name p) (field x (at 3) (enc u8)))")
    var c = newSeq[byte](32)
    m.setVendorField(ctx(), ea, c, "x", intV(7))
    doAssert c[2] == 7 and c[1] == 0 and m.whole(c)["x"].intVal == 7

  block value_equal_to_sentinel_is_refused:
    let r = mk("(target (kind extendedHeader) (blockIndex 1) (field a (at 1) (enc u16) " &
      "(sentinel 0xFFFF)) (field b (at 3) (enc i24) (sentinel 0xFFFFFF)) " &
      "(field c (at 6) (enc i64) (sentinel 0)))")
    var b = newSeq[byte](16)
    doAssert r.refuses(b, "a", intV(65535))
    doAssert r.refuses(b, "b", intV(-1))
    doAssert r.refuses(b, "c", intV(0))
    r.setVendorField(ctx(), ea, b, "b", intV(-2))
    doAssert r.whole(b)["b"].intVal == -2

  block sixty_four_bit_values_set_back:
    let r = mk("(target (kind extendedHeader) (blockIndex 1) (field u (at 1) (enc u64)) " &
      "(field nib (at 9) (len 16 n) (enc unibble)))")
    var b = newSeq[byte](32)
    for i in 0..<16: b[i] = 0xFF
    let got = r.whole(b)
    doAssert got["u"].intVal == -1 and got["nib"].intVal == -1
    var c = newSeq[byte](32)
    r.setVendorField(ctx(), ea, c, "u", got["u"])
    r.setVendorField(ctx(), ea, c, "nib", got["nib"])
    doAssert c == b
    r.setVendorField(ctx(), ea, c, "u", intV(low(int64)))
    doAssert r.whole(c)["u"].intVal == low(int64) and c[0] == 0x80

  block text_bytes_above_127_set_back:
    let r = mk("(target (kind extendedHeader) (blockIndex 1) (field t (at 1) (len 4) " &
      "(enc ascii) (trim none)))")
    var b = @[byte(0xE9), 0x80, 0xFF, 0x41, 0, 0]
    let got = r.whole(b)["t"]
    var c = newSeq[byte](6)
    r.setVendorField(ctx(), ea, c, "t", got)
    doAssert c[0..3] == b[0..3] and c[4] == 0
    # Shorter text is padded with spaces and reads back padded.
    r.setVendorField(ctx(), ea, c, "t", textV("ab"))
    doAssert r.whole(c)["t"].text == "ab  "

  block shipped_trace_extension_time_field:
    var shipped: VendorRegistry
    var l: DiagLog
    shipped.loadVendorMaps([here / ".." / "vendormaps" / "mfr09-rev2.nif"], l)
    # General: an extended header block holds the module (9 0 0 1) with byte 30 = 3.
    var ext = newSeq[byte](64)
    for (i, x) in [(32, 9), (35, 1), (37, 1), (32 + 29, 3), (32 + 31, 7)]: ext[i] = byte(x)
    for order in [boBig, boLittle]:
      let c = VendorContext(format: skSegd, revision: VendorRevision(major: 2, minor: 0),
        manufacturer: 9, serial: -1, byteOrder: order, extended: ext)
      let a3 = VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1, extIndex: 3)
      let a2 = VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1, extIndex: 2)
      for v in [1'i64, (1'i64 shl 53) + 1, high(int64), low(int64), -1]:
        var b = newSeq[byte](32)
        for i in 0..31: b[i] = byte(i * 37 + 11)
        let before = b
        shipped.setVendorField(c, a3, b, "firstSampleTime", intV(v))
        let blk = shipped.decode(c, a3, b, l)
        doAssert blk.isSome and blk.get["firstSampleTime"].intVal == v
        var changed: seq[int]
        for i in 0..31:
          if b[i] != before[i]: changed.add i
        for i in changed: doAssert i in 8..15
        var expect = newSeq[byte](8)
        putNum[int64](expect, 0, v, order)
        doAssert b[8..15] == expect
      var b = newSeq[byte](32)
      let before = b
      try:
        shipped.setVendorField(c, a2, b, "firstSampleTime", intV(1))
        doAssert false
      except ValueError: doAssert b == before
      try:
        shipped.setVendorField(c, a3, b, "firstSampleTime", intV(0)) # the sentinel
        doAssert false
      except ValueError as e: doAssert "sentinel" in e.msg

proc main*() =
  moreTests()
  var reg: VendorRegistry
  reg.addMap loadVendorMap(mapText)

  block every_encoding_round_trips:
    let cases = [("u8f", intV(200), 0, 0), ("u16f", intV(65000), 1, 2),
      ("u24f", intV(0xABCDEF), 3, 5), ("u32f", intV(4_000_000_000'i64), 6, 9),
      ("u64f", intV(high(int64)), 10, 17), ("i8f", intV(-100), 18, 18),
      ("i16f", intV(-30000), 19, 20), ("i24f", intV(-8_000_000), 21, 23),
      ("i32f", intV(-2_000_000_000), 24, 27), ("i64f", intV(low(int64)), 28, 35),
      ("f32f", floatV(-118.625), 36, 39), ("f64f", floatV(3.141592653589793), 40, 47),
      ("textf", textV("seg d"), 48, 55), ("rawf", bytesV(@[1'u8, 2, 3, 255]), 56, 59),
      ("bcdf", intV(1234), 64, 65), ("littleU32", intV(0x01020304), 66, 69),
      ("littleI24", intV(-2), 70, 72), ("ebc", textV("ABC"), 75, 78),
      ("sentI24", intV(-5), 81, 83), ("withSentinel", intV(7), 79, 80)]
    for (name, v, lo, hi) in cases:
      var b = fresh()
      let before = b
      reg.setVendorField(ctx(), ea, b, name, v)
      let blk = reg.read(b)
      doAssert name in blk, name
      let got = blk[name]
      case v.kind
      of vvInt: doAssert got.kind == vvInt and got.intVal == v.intVal, name
      of vvFloat: doAssert got.floatVal == v.floatVal, name
      of vvText: doAssert got.text == v.text, name
      of vvBytes: doAssert got.bytes == v.bytes, name
      for i in b.changed(before):
        doAssert i in lo..hi, name & " changed byte " & $i
    # Little-endian bytes land in the file's other order.
    var b = fresh()
    reg.setVendorField(ctx(), ea, b, "littleU32", intV(0x01020304))
    doAssert b[66..69] == @[4'u8, 3, 2, 1]
    reg.setVendorField(ctx(), ea, b, "u32f", intV(0x01020304))
    doAssert b[6..9] == @[1'u8, 2, 3, 4]
    var o = ctx()
    o.byteOrder = boLittle
    reg.setVendorField(o, ea, b, "u16f", intV(0x0102))
    doAssert b[1..2] == @[2'u8, 1]

  block nibbles_leave_their_neighbours:
    var b = fresh()
    b[60] = 0xAB; b[61] = 0xCD; b[62] = 0xEF
    reg.setVendorField(ctx(), ea, b, "nibA", intV(0x123))
    doAssert b[60] == 0x12 and b[61] == 0x3D, $b[60..62] # 62H = 3, 62L (D) is nibB's
    doAssert b[62] == 0xEF
    reg.setVendorField(ctx(), ea, b, "nibB", intV(-2))   # 0xFFE in 12 bits
    doAssert b[60] == 0x12 and b[61] == 0x3F and b[62] == 0xFE, $b[60..62]
    let blk = reg.read(b)
    doAssert blk["nibA"].intVal == 0x123 and blk["nibB"].intVal == -2
    doAssert reg.raises(b, "nibA", intV(0x1000), "does not fit")
    doAssert reg.raises(b, "nibB", intV(2048), "does not fit")
    doAssert reg.raises(b, "nibB", intV(-2049), "does not fit")

  block scale_offset_and_sentinel:
    var b = fresh()
    reg.setVendorField(ctx(), ea, b, "scaled", floatV(-1.5))   # raw -250
    doAssert reg.read(b)["scaled"].floatVal == -1.5 and b[73] == 0xFF and b[74] == 0x06
    reg.setVendorField(ctx(), ea, b, "scaled", intV(2))        # raw 100
    doAssert reg.read(b)["scaled"].floatVal == 2.0
    doAssert reg.raises(b, "scaled", floatV(1000.0), "does not fit")
    reg.clearVendorField(ctx(), ea, b, "withSentinel")
    doAssert b[79] == 0xFF and b[80] == 0xFF and "withSentinel" notin reg.read(b)
    reg.clearVendorField(ctx(), ea, b, "sentI24")
    doAssert b[81..83] == @[0xFF'u8, 0xFF, 0xFF] and "sentI24" notin reg.read(b)
    var failed = false
    try: reg.clearVendorField(ctx(), ea, b, "u8f")
    except ValueError as e: failed = "sentinel" in e.msg
    doAssert failed

  block repeats:
    var b = fresh()
    reg.setVendorField(ctx(), ea, b, "item[2]", intV(777))
    doAssert reg.read(b)["item[2]"].intVal == 777 and b[96] == 0x03 and b[97] == 0x09
    doAssert reg.raises(b, "item[3]", intV(1), "repeat has 3")

  block out_of_range_raises:
    var b = fresh()
    for (name, v) in [("u8f", intV(256)), ("u8f", intV(-1)), ("u16f", intV(65536)),
        ("u24f", intV(0x1000000)), ("u32f", intV(1 shl 32)),
        ("i8f", intV(128)), ("i8f", intV(-129)), ("i16f", intV(32768)),
        ("i24f", intV(8_388_608)), ("i24f", intV(-8_388_609)), ("i32f", intV(1 shl 31)),
        ("bcdf", intV(10000)), ("bcdf", intV(-1)), ("f32f", floatV(1e300)),
        ("textf", textV("123456789")), ("rawf", bytesV(@[1'u8, 2])),
        ("u8f", floatV(1.5)), ("u8f", textV("x")), ("textf", intV(1)),
        ("ebc", textV("ABCDE"))]:
      doAssert reg.raises(b, name, v, name), name & " " & $v.kind
    doAssert reg.raises(b, "ibm", floatV(1.0), "not supported")

  block unknown_field_and_when_and_no_map:
    var b = fresh()
    doAssert reg.raises(b, "nothing", intV(1), "no field nothing")
    # `(when (field mode) (is 1))`: holds with mode 1, not with mode 2.
    reg.setVendorField(ctx(), ea, b, "onlyMode1", intV(9))
    doAssert reg.read(b)["onlyMode1"].intVal == 9
    b[84] = 2
    doAssert reg.raises(b, "onlyMode1", intV(9), "condition")
    var other = ctx()
    other.format = skSegy
    let before = b
    try:
      reg.setVendorField(other, ea, b, "u8f", intV(1))
      doAssert false
    except ValueError as e: doAssert "no vendor map" in e.msg
    doAssert b == before
    var wrongArea = ea
    wrongArea.blockIndex = 2
    try:
      reg.setVendorField(ctx(), wrongArea, b, "u8f", intV(1))
      doAssert false
    except ValueError as e: doAssert "no vendor map" in e.msg
    var short = newSeq[byte](4)
    try:
      reg.setVendorField(ctx(), ea, short, "u64f", intV(1))
      doAssert false
    except ValueError as e: doAssert "lies beyond" in e.msg
    doAssert short == newSeq[byte](4)

  block shipped_map_round_trips:
    var shipped: VendorRegistry
    var l: DiagLog
    shipped.loadVendorMaps([here / ".." / "vendormaps" / "mfr09-rev2.nif"], l)
    doAssert shipped.maps.len == 1 and l.len == 0
    var c = VendorContext(format: skSegd, revision: VendorRevision(major: 2, minor: 0),
      manufacturer: 9, serial: -1, byteOrder: boBig)
    var b = newSeq[byte](32)
    for (i, x) in [(0, 9), (3, 1), (4, 1)]: b[i] = byte(x)
    c.extended = b
    let a = VendorArea(kind: vtExtendedHeader, blockIndex: 1, blockType: -1, extIndex: -1)
    shipped.setVendorField(c, a, b, "utcFractionalSecond", intV(123_456_789))
    shipped.setVendorField(c, a, b, "recordTimeOffset", intV(-250))
    shipped.setVendorField(c, a, b, "sampleClockPhaseError", intV(-999_999))
    shipped.setVendorField(c, a, b, "recordSerialNumberId", intV(0xABC))
    shipped.setVendorField(c, a, b, "sampleClockSynchronization", intV(2))
    shipped.setVendorField(c, a, b, "sampleClockSynchronizationStatus", intV(3))
    shipped.setVendorField(c, a, b, "receiverChannelCount", intV(1500))
    let blks = shipped.decodeAll(c, a, b, l)
    var seen: seq[string]
    for blk in blks:
      for f in blk.fields: seen.add f.name
      if blk.name == "acqDetail":
        doAssert blk["utcFractionalSecond"].intVal == 123_456_789
        doAssert blk["recordTimeOffset"].intVal == -250
        doAssert blk["sampleClockPhaseError"].intVal == -999_999
        doAssert blk["recordSerialNumberId"].intVal == 0xABC
        doAssert blk["sampleClockSynchronization"].intVal == 2
        doAssert blk["sampleClockSynchronizationStatus"].intVal == 3
        doAssert blk["receiverChannelCount"].intVal == 1500
    doAssert "recordTimeOffset" in seen
    doAssert b[0] == 9 and b[1] == 0 and b[2] == 0 and b[3] == 1 and b[4] == 1

when isMainModule: main()
