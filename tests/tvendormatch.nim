## Vendor maps: blocks found by their bytes (`(match (at N) (bytes ...))`),
## `(when)` conditions and `(group)`, nibble fields, and a map-level
## `(hasBlock)`. The vendor is made up (ZETA, manufacturer 77).
##
## Seen failing once (each by breaking the code, then restoring it): the
## content test of `targetMatches` removed (modules_in_any_order), the
## `hasBlock` clause not counted in the specificity (map_level_content_chooses),
## `testHolds` always true (conditions_true_and_false), the content rule
## replaced by the position rule (modules_in_any_order), the low-nibble start
## ignored (nibble_fields_both_alignments), the record's extended header left
## out of the context (map_level_content_chooses).

import std/[assertions, strutils]

import parseSEG/segd/[reader as segdreader]

import parseSEG/vendor/apply

proc ctxZeta(): VendorContext =
  VendorContext(format: skSegd, revision: VendorRevision(major: 2, minor: 1), manufacturer: 77,
    serial: 5, byteOrder: boBig)

proc module(t: byte, ver: byte, rest: openArray[byte] = []): seq[byte] =
  ## A 32-byte module: bytes 1-4 = 5A 00 00 t, byte 5 = version, then `rest`.
  result = newSeq[byte](32)
  result[0] = 0x5A
  result[3] = t
  result[4] = ver
  for i, x in rest: result[5 + i] = x

proc join(parts: varargs[seq[byte]]): seq[byte] =
  for p in parts: result.add p

proc recordWith(extended: seq[byte], external: seq[byte] = @[]): SegdRecord =
  result = SegdRecord(layout: slRev2, extended: extended, external: external)
  result.revision = SegdRevision(major: 2, minor: 1)
  result.gh1.manufacturerCode = 77
  result.gh1.manufacturerSerial = 5

proc regOf(srcs: varargs[string]): VendorRegistry =
  for s in srcs: result.addMap loadVendorMap("(.nif27)\n" & s)

const modules = """
(vendormap "zeta-modules" (version 1) (match (format segd) (manufacturer 77))
  (target (kind extendedHeader) (name alpha) (match (at 1) (bytes 0x5A 0 0 1))
    (field ver (at 5) (enc u8))
    (field serial (at 6) (enc u16)))
  (target (kind extendedHeader) (name beta) (match (at 1) (bytes 0x5A 0 0 2))
    (field ver (at 5) (enc u8))
    (field gain (at 6) (enc u8))))"""

proc names(blocks: seq[VendorBlock]): seq[string] =
  for b in blocks: result.add b.name & "#" & $b.blockNumber

proc expectError(src, why: string) =
  try:
    discard loadVendorMap("(.nif27)\n" & src)
    doAssert false, "accepted: " & src
  except ValueError as e:
    doAssert why in e.msg, e.msg

proc main*() =
  block modules_in_any_order:
    let reg = regOf(modules)
    let a = module(1, 1, [0'u8, 7])
    let b = module(2, 1, [9'u8])
    let c = module(3, 1) # a module the map does not know
    var log: DiagLog
    doAssert reg.decodeVendorAreas(recordWith(join(a, b, c)), log).names ==
      @["alpha#1", "beta#2"]
    doAssert reg.decodeVendorAreas(recordWith(join(c, b, a)), log).names ==
      @["beta#2", "alpha#3"]
    let mixed = reg.decodeVendorAreas(recordWith(join(b, a, c)), log)
    doAssert mixed.names == @["beta#1", "alpha#2"]
    doAssert mixed[1]["serial"].intVal == 7 and mixed[0]["gain"].intVal == 9
    doAssert mixed[1].mapName == "zeta-modules"
    doAssert log.len == 0, "no module, no diagnostic"

  block module_absent_decodes_nothing:
    let reg = regOf(modules)
    var log: DiagLog
    doAssert reg.decodeVendorAreas(recordWith(join(module(3, 1), module(4, 1))), log).len == 0
    doAssert reg.decodeVendorAreas(recordWith(@[]), log).len == 0
    doAssert reg.decodeVendorAreas(recordWith(module(1, 1)[0 .. 19]), log).len == 0 # a part block
    doAssert log.len == 0

  block module_twice:
    let reg = regOf(modules)
    var log: DiagLog
    let r = reg.decodeVendorAreas(recordWith(join(module(1, 1, [0'u8, 1]), module(2, 1),
      module(1, 1, [0'u8, 2]))), log)
    doAssert r.names == @["alpha#1", "beta#2", "alpha#3"]
    doAssert r[0]["serial"].intVal == 1 and r[2]["serial"].intVal == 2

  block position_and_content:
    # blockIndex 2 with a match: that block, only if it matches.
    let reg = regOf("""(vendormap "p" (match (format segd))
  (target (kind extendedHeader) (blockIndex 2) (name second) (match (at 4) (bytes 1))
    (field ver (at 5) (enc u8))))""")
    var log: DiagLog
    doAssert reg.decodeVendorAreas(recordWith(join(module(2, 1), module(1, 1))), log).names ==
      @["second#2"]
    doAssert reg.decodeVendorAreas(recordWith(join(module(1, 1), module(2, 1))), log).len == 0
    doAssert reg.decodeVendorAreas(recordWith(join(module(1, 1), module(1, 1), module(1, 1))),
      log).names == @["second#2"]
    # Two (match) clauses must both hold.
    let two = regOf("""(vendormap "q" (match (format segd))
  (target (kind extendedHeader) (name both) (match (at 4) (bytes 1)) (match (at 5) (bytes 9))
    (field ver (at 5) (enc u8))))""")
    doAssert two.decodeVendorAreas(recordWith(join(module(1, 8), module(1, 9))), log).names ==
      @["both#2"]
    doAssert log.len == 0

  block content_in_external_header_and_trace_extensions:
    let reg = regOf("""(vendormap "x" (match (format segd))
  (target (kind externalHeader) (name ext) (match (at 4) (bytes 2)) (field v (at 5) (enc u8)))
  (target (kind traceExt) (extension 3) (name t3) (match (at 1) (bytes 0x5A))
    (field v (at 5) (enc u8)))
  (target (kind traceExt) (name tany) (match (at 4) (bytes 7)) (field v (at 5) (enc u8))))""")
    var log: DiagLog
    let rec = recordWith(@[], join(module(1, 1), module(2, 4)))
    doAssert reg.decodeVendorAreas(rec, log).names == @["ext#2"]
    var t = SegdTrace(layout: slRev2, extensions: join(module(1, 5), module(7, 6), module(7, 8)))
    # Extension 3 is module(7, 6): both targets hold, each is a block of its own.
    doAssert reg.decodeVendorAreas(rec, t, log).names == @["t3#3", "tany#3", "tany#4"]
    doAssert log.len == 0

  block modules_do_not_disturb_old_position_maps:
    # A target by position and one by content in one map; the whole area is
    # still reached by a target with neither.
    let reg = regOf("""(vendormap "m" (match (format segd))
  (target (kind extendedHeader) (name whole) (field v (at 1) (enc u8)))
  (target (kind extendedHeader) (blockIndex 1) (name first) (field v (at 5) (enc u8)))
  (target (kind extendedHeader) (name byContent) (match (at 4) (bytes 2)) (field v (at 5) (enc u8))))""")
    var log: DiagLog
    doAssert reg.decodeVendorAreas(recordWith(join(module(1, 3), module(2, 4))), log).names ==
      @["whole#-1", "first#1", "byContent#2"]

  block conditions_true_and_false:
    let src = """(vendormap "c" (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name c)
    (field mode (at 1) (enc u8))
    (field isTwo (at 2) (enc u8) (when (field mode) (is 2)))
    (field oneOf (at 2) (enc u8) (when (field mode) (in 1 3 5)))
    (field inRange (at 2) (enc u8) (when (field mode) (range 4 6)))
    (field rawByte (at 2) (enc u8) (when (byte 3) (is 0x80)))
    (field hi (at 2) (enc u8) (when (highNibble 4) (in 0xA)))
    (field lo (at 2) (enc u8) (when (lowNibble 4) (range 1 3)))
    (field negative (at 2) (enc u8) (when (field signed) (is -1)))
    (field both (at 2) (enc u8) (when (field mode) (range 1 9)) (when (byte 3) (is 0x80)))
    (group (when (field mode) (is 2))
      (field g1 (at 2) (enc u8))
      (group (when (byte 3) (is 0x80)) (field g2 (at 2) (enc u8)))
      (field g3 (at 2) (enc u8)))))"""
    # `signed` is defined after use: a map error.
    expectError(src, "names no field defined earlier")
    let ok = src.replace("""(field negative (at 2) (enc u8) (when (field signed) (is -1)))
""", "").replace("""(field both""", """(field signed (at 8) (enc i8))
    (field negative (at 2) (enc u8) (when (field signed) (is -1)))
    (field both""")
    let reg = regOf(ok)
    proc run(mode, raw3, raw4, signed: byte): VendorBlock =
      var b = newSeq[byte](32)
      b[0] = mode; b[1] = 99; b[2] = raw3; b[3] = raw4; b[7] = signed
      var log: DiagLog
      let r = reg.decodeVendorAreas(recordWith(b), log)
      doAssert log.len == 0
      doAssert r.len == 1
      r[0]
    var r = run(2, 0x80, 0xA2, 0xFF)
    for n in ["isTwo", "hi", "lo", "rawByte", "both", "negative", "g1", "g2", "g3"]:
      doAssert n in r, n
    for n in ["oneOf", "inRange"]: doAssert n notin r, n
    doAssert r["isTwo"].intVal == 99
    r = run(3, 0, 0x5F, 0)
    doAssert "oneOf" in r and "both" notin r and "rawByte" notin r and "hi" notin r
    doAssert "lo" notin r and "negative" notin r and "isTwo" notin r and "g1" notin r
    r = run(5, 0x80, 0x03, 1)
    doAssert "oneOf" in r and "inRange" in r and "lo" in r and "both" in r and "g1" notin r
    r = run(6, 0x80, 0xB1, 0)
    doAssert "inRange" in r and "oneOf" notin r and "hi" notin r and "lo" in r
    r = run(7, 0, 0, 0)
    doAssert "inRange" notin r and "both" in r == false
    r = run(2, 0, 0, 0) # group: g1 and g3 only (g2 needs raw byte 3)
    doAssert "g1" in r and "g3" in r and "g2" notin r
    # A condition reads the raw value, even where the field itself is absent (sentinel).
    let sent = regOf("""(vendormap "s" (match (format segd))
  (target (kind extendedHeader) (blockIndex 1)
    (field mode (at 1) (enc u8) (sentinel 0xFF))
    (field x (at 2) (enc u8) (when (field mode) (in 0xFF)))))""")
    var log: DiagLog
    var b = newSeq[byte](32)
    b[0] = 0xFF
    let sb = sent.decodeVendorAreas(recordWith(b), log)[0]
    doAssert "mode" notin sb and "x" in sb and log.len == 0

  block condition_beyond_short_block_is_absent:
    let reg = regOf("""(vendormap "s" (match (format segd))
  (target (kind block) (name s)
    (field a (at 1) (enc u8))
    (field b (at 2) (enc u8) (when (byte 20) (is 0)))
    (field c (at 2) (enc u8) (when (field a) (is 1)))))""")
    var bytes = [1'u8, 2, 3]
    var log: DiagLog
    var blk: VendorBlock
    let b = reg.decode(ctxZeta(), VendorArea(kind: vtBlock, blockIndex: -1, blockType: -1,
      extIndex: -1), bytes, log)
    doAssert b.isSome and "b" notin b.get and "c" in b.get and log.len == 0
    discard blk

  block bad_conditions_are_map_errors_with_lines:
    expectError("(vendormap \"a\"\n (target (kind block)\n  (field x (at 1) (enc u8) (when (field nope) (is 1)))))",
      "line 4: field x: (when (field nope)) names no field")
    expectError("(vendormap \"a\" (target (kind block) (field t (at 1) (len 2) (enc ascii))" &
      " (field x (at 1) (enc u8) (when (field t) (is 1)))))", "needs an integer or bcd")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (is 1)))))",
      "needs (field name)")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (byte 1)))))",
      "needs (is v)")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (byte 1) (range 5 1)))))",
      "(range)")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (byte 1) (is a)))))",
      "takes integers")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (byte 1) (in)))))",
      "(in) takes")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (byte 0) (is 1)))))",
      "(byte) must be")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (field x) (is 1)))))",
      "names no field")
    expectError("(vendormap \"a\" (target (kind block) (repeat (count 2) (stride 2) " &
      "(field v (at 1) (enc u8) (when (byte 1) (is 1))))))", "not supported in (repeat)")
    var many = "(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (byte 1) (in"
    for i in 0 .. 300: many.add " " & $i
    expectError(many & ")))))", "(in) takes")

  block nibble_fields_both_alignments:
    let reg = regOf("""(vendormap "n" (match (format segd))
  (target (kind externalHeader) (blockIndex 1) (name nib)
    (field hiBin (at 1) (nibble high) (len 1n) (enc unibble))
    (field loBin (at 1) (nibble low) (len 1n) (enc unibble))
    (field hiBcd (at 2) (nibble high) (len 1n) (enc bcd))
    (field loBcd (at 2) (nibble low) (len 1n) (enc bcd))
    (field w12hi (at 3) (len 3n) (enc unibble))
    (field w12lo (at 3) (nibble low) (len 3n) (enc unibble))
    (field s4 (at 5) (nibble high) (len 1n) (enc inibble))
    (field s12 (at 6) (len 3n) (enc inibble))
    (field none (at 8) (nibble low) (len 1n) (enc unibble) (sentinel 0xF))
    (field bad (at 9) (nibble high) (len 1n) (enc bcd))))""")
    var b = newSeq[byte](32)
    b[0] = 0xA5; b[1] = 0x37; b[2] = 0xAB; b[3] = 0xCD; b[4] = 0xF0
    b[5] = 0x80; b[6] = 0x00; b[7] = 0x0F; b[8] = 0xB0
    var log: DiagLog
    let blk = reg.decodeVendorAreas(recordWith(@[], b), log)[0]
    doAssert blk["hiBin"].intVal == 0xA and blk["loBin"].intVal == 5
    doAssert blk["hiBcd"].intVal == 3 and blk["loBcd"].intVal == 7
    doAssert blk["w12hi"].intVal == 0xABC and blk["w12lo"].intVal == 0xBCD
    doAssert blk["s4"].intVal == -1 and blk["s12"].intVal == -2048
    doAssert "none" notin blk
    doAssert blk["bad"].label == "invalid BCD"
    # Fields beyond a short block are diagnostics, not a crash.
    var l2: DiagLog
    let short = reg.decodeVendorAreas(recordWith(@[], b), l2)
    doAssert short.len == 1
    var l3: DiagLog
    var outBlk: VendorBlock
    var problems: seq[string]
    reg.maps[0].targets[0].decodeTarget(b[0 .. 2], boBig, outBlk, problems)
    doAssert "w12lo" notin outBlk and problems.len > 0
    # Load-time bounds.
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (len 17n) (enc unibble))))",
      "exceeds 16 nibbles")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc unibble))))",
      "needs (len)")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (nibble middle) (len 1n) (enc unibble))))",
      "(nibble) is high or low")

  block map_level_content_chooses:
    let v1 = """(vendormap "zeta-v1" (match (format segd) (manufacturer 77)
    (hasBlock extendedHeader (match (at 1) (bytes 0x5A 0 0 1 1))))
  (target (kind extendedHeader) (blockIndex 1) (name v1) (field a (at 6) (enc u8))))"""
    let v2 = """(vendormap "zeta-v2" (match (format segd) (manufacturer 77)
    (hasBlock extendedHeader (match (at 1) (bytes 0x5A 0 0 1 2))))
  (target (kind extendedHeader) (blockIndex 1) (name v2) (field a (at 6) (enc u8))))"""
    let plain = """(vendormap "zeta-plain" (match (format segd) (manufacturer 77))
  (target (kind extendedHeader) (blockIndex 1) (name plain) (field a (at 6) (enc u8))))"""
    let reg = regOf(plain, v1, v2)
    var log: DiagLog
    doAssert reg.decodeVendorAreas(recordWith(join(module(1, 1))), log)[0].mapName == "zeta-v1"
    doAssert reg.decodeVendorAreas(recordWith(join(module(1, 2))), log)[0].mapName == "zeta-v2"
    # The identifying block need not be the first one.
    doAssert reg.decodeVendorAreas(recordWith(join(module(9, 1), module(1, 2))),
      log)[0].mapName == "zeta-v2"
    doAssert reg.decodeVendorAreas(recordWith(join(module(1, 3))), log)[0].mapName == "zeta-plain"
    doAssert reg.decodeVendorAreas(recordWith(@[]), log).len == 0 # no block: nothing to decode
    doAssert log.len == 0, "several maps never tied"
    # `applies` and the specificity.
    var rec = recordWith(join(module(1, 1)))
    doAssert reg.maps[1].applies(vendorContext(rec)) and not reg.maps[2].applies(vendorContext(rec))
    doAssert reg.maps[0].applies(vendorContext(rec))
    # In the external header and in a general header block.
    let ext = regOf("""(vendormap "e" (match (hasBlock externalHeader (match (at 1) (bytes 0x5A)))
      (hasBlock generalHeader (match (at 32) (bytes 0x33))))
  (target (kind block) (field a (at 1) (enc u8))))""")
    var r2 = recordWith(@[], module(1, 1))
    doAssert not ext.maps[0].applies(vendorContext(r2))
    var g = SegdGeneralHeaderN()
    g.raw[31] = 0x33
    r2.sourceHeaders.add g
    doAssert ext.maps[0].applies(vendorContext(r2))
    doAssert not ext.maps[0].applies(vendorContext(recordWith(@[], module(1, 1))))
    # A SEG-Y file has no such blocks.
    doAssert not ext.maps[0].applies(VendorContext(format: skSegy))
    # Bad clauses.
    expectError("(vendormap \"a\" (match (hasBlock block (match (at 1) (bytes 1)))) (target (kind block)))",
      "names extendedHeader")
    expectError("(vendormap \"a\" (match (hasBlock extendedHeader)) (target (kind block)))",
      "needs a (match)")

  block record_condition_from_extended_header:
    # The trace extension's layout depends on a version byte of an
    # extended-header module of the same record.
    let reg = regOf("""(vendormap "r" (match (format segd) (manufacturer 77))
  (target (kind traceExt) (extension 2) (name tx)
    (field common (at 1) (enc u8))
    (group (when (record extendedHeader (match (at 1) (bytes 0x5A 0 0 6)) (byte 5)) (is 3))
      (field v3only (at 2) (enc u8)))
    (field v2only (at 3) (enc u8)
      (when (record extendedHeader (match (at 1) (bytes 0x5A 0 0 6)) (byte 5)) (range 1 2)))
    (field lowv (at 4) (enc u8)
      (when (record extendedHeader (match (at 1) (bytes 0x5A 0 0 6)) (lowNibble 5)) (is 3)))))""")
    doAssert reg.maps[0].usesRecordBlocks
    var t = SegdTrace(layout: slRev2, extensions: module(0, 0, [1'u8, 2, 3]))
    t.extensions[0] = 1; t.extensions[1] = 11; t.extensions[2] = 12; t.extensions[3] = 13
    var log: DiagLog
    let v3 = reg.decodeVendorAreas(recordWith(join(module(1, 1), module(6, 3))), t, log)
    doAssert v3.len == 1 and "v3only" in v3[0] and "v2only" notin v3[0] and "lowv" in v3[0]
    let v2 = reg.decodeVendorAreas(recordWith(join(module(6, 2), module(1, 1))), t, log)
    doAssert "v2only" in v2[0] and "v3only" notin v2[0] and "lowv" notin v2[0]
    # No such module: both conditions fail, no diagnostic.
    let none = reg.decodeVendorAreas(recordWith(module(1, 1)), t, log)
    doAssert none[0].fields.len == 1 and log.len == 0
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) " &
      "(when (record extendedHeader (byte 5)) (is 1)))))", "needs a (match)")
    expectError("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) " &
      "(when (record extendedHeader (match (at 1) (bytes 1))) (is 1)))))", "needs (byte N)")

  block hostile_matches:
    # A match past the end of a block, a short block, an empty area.
    let reg = regOf("""(vendormap "h" (match (format segd))
  (target (kind extendedHeader) (name late) (match (at 30) (bytes 1 2 3 4 5)) (field a (at 1) (enc u8)))
  (target (kind extendedHeader) (name deep) (match (at 1000000) (bytes 1)) (field b (at 1) (enc u8))))""")
    var log: DiagLog
    doAssert reg.decodeVendorAreas(recordWith(module(1, 1)), log).len == 0
    doAssert reg.decodeVendorAreas(recordWith(module(1, 1)[0 .. 2]), log).len == 0
    let notes = reg.maps[0].checkVendorMap
    doAssert notes.len == 2 and "beyond" in notes[0], $notes
    var blk: VendorBlock
    let direct = reg.decode(ctxZeta(), VendorArea(kind: vtExtendedHeader, blockIndex: 1,
      blockType: -1, extIndex: -1), [1'u8, 2], log)
    doAssert direct.isNone
    # Load-time limits.
    var big = "(vendormap \"a\" (target (kind block) (match (at 1) (bytes"
    for i in 0 ..< 65: big.add " 1"
    expectError(big & "))))", "at most 64")
    expectError("(vendormap \"a\" (target (kind block) (match (at 1) (bytes 256))))", "0..255")
    expectError("(vendormap \"a\" (target (kind block) (match (at 1) (bytes -1))))", "0..255")
    expectError("(vendormap \"a\" (target (kind block) (match (at 1) (bytes x))))", "needs byte")
    expectError("(vendormap \"a\" (target (kind block) (match (at 1))))", "no (bytes)")
    expectError("(vendormap \"a\" (target (kind block) (match (bytes 1))))", "no (at)")
    expectError("(vendormap \"a\" (target (kind block) (match (at 1) (bytes 1) (extra 1))))",
      "unknown (match)")
    expectError("(vendormap \"a\" (target (kind block) (match (at 0) (bytes 1))))", "(at) must be")
    var lots = "(vendormap \"a\" (target (kind block)"
    for i in 0 ..< 17: lots.add " (match (at 1) (bytes 1))"
    expectError(lots & "))", "at most 16")
    discard blk

  block check_notes_for_conditions:
    let m = loadVendorMap("""(.nif27)
(vendormap "k" (target (kind extendedHeader)
  (field a (at 1) (enc u8))
  (field b (at 2) (enc u8) (when (byte 33) (is 1)))
  (field c (at 2) (enc u8) (when (byte 1) (is 2)))))""")
    let notes = m.checkVendorMap
    doAssert notes.len == 1 and "beyond" in notes[0] and "field b" in notes[0], $notes

  block condition_limits_refuse_hostile_maps:
    var many = "(vendormap \"a\" (target (kind block) (group"
    for i in 0 ..< 17: many.add " (when (byte 1) (is 1))"
    expectError(many & " (field x (at 1) (enc u8)))))", "more than 16")
    var nested = "(vendormap \"a\" (target (kind block) "
    for i in 0 ..< 9: nested.add "(group (when (byte 1) (is 1)) (when (byte 2) (is 1)) "
    expectError(nested & "(field x (at 1) (enc u8))" & ")".repeat(11), "more than 16")
    # 16 conditions on thousands of fields: refused by the running total.
    var wide = "(vendormap \"a\" (target (kind block) (group"
    for i in 0 ..< 16: wide.add " (when (byte 1) (is 1))"
    for i in 0 ..< 5000: wide.add " (field f" & $i & " (at 1) (enc u8))"
    expectError(wide & ")))", "over all its fields")
    # At the limits it loads.
    var okMap = "(vendormap \"a\" (target (kind block) (group"
    for i in 0 ..< 16: okMap.add " (when (byte 1) (is 1))"
    discard loadVendorMap("(.nif27)\n" & okMap & " (field x (at 1) (enc u8)))))")

  block low_nibble_past_the_end_is_reported:
    let m = loadVendorMap("""(.nif27)
(vendormap "n" (target (kind block) (name n)
  (field a (at 3) (nibble low) (len 2n) (enc unibble))
  (field b (at 3) (nibble low) (len 1n) (enc unibble))))""")
    var blk: VendorBlock
    var problems: seq[string]
    m.targets[0].decodeTarget([1'u8, 2, 0x3F], boBig, blk, problems)
    doAssert "a" notin blk and blk["b"].intVal == 0xF
    doAssert problems.len == 1 and "field a lies beyond" in problems[0], $problems
    expectError("(vendormap \"a\" (target (kind block) (repeat (count 1) (stride 1) (at 1) " &
      "(field v (at 1) (nibble low) (len 2n) (enc unibble)))))", "exceeds the stride")

  block rev3_trailer_content_match:
    let reg = regOf("""(vendormap "t" (match (format segd))
  (target (kind trailer) (name tr) (match (at 1) (bytes 0x56)) (field x (at 2) (enc u8))))""")
    var log: DiagLog
    let a3 = VendorArea(kind: vtTrailer, blockIndex: -1, blockType: 1, extIndex: -1)
    doAssert reg.decode(ctxZeta(), a3, [0x56'u8, 9], log).get["x"].intVal == 9
    doAssert reg.decode(ctxZeta(), a3, [0x57'u8, 9], log).isNone
    # The whole trailer area of Rev 0-2 is not a block.
    doAssert reg.decode(ctxZeta(), VendorArea(kind: vtTrailer, blockIndex: -1, blockType: -1,
      extIndex: -1), [0x56'u8, 9], log).isNone
    var rec = SegdRecord(layout: slRev3)
    var desc = SegdTrailerDescription(trailerBlockType: 1, asciiOrBinary: 2, blockSize: 1,
      blockType: 0x70)
    rec.trailerRev3 = @(desc.encoded)
    var data = newSeq[byte](32)
    data[0] = 0x56; data[1] = 4
    rec.trailerRev3.add data
    doAssert reg.decodeVendorAreas(rec, log).names == @["tr#-1"]
    doAssert log.len == 0

  block conditions_on_absent_fields_fail:
    # Two layouts selected by byte 1; the conditions of the second layout read
    # a field that exists only in the first.
    let reg = regOf("""(vendormap "l" (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name l)
    (field layout (at 1) (enc u8))
    (group (when (field layout) (is 1))
      (field kind (at 2) (enc u8))
      (field a (at 3) (enc u8) (when (field kind) (is 7))))
    (field b (at 3) (enc u8) (when (field kind) (is 7)))))""")
    var log: DiagLog
    proc run(layout, kind: byte): VendorBlock =
      var b = newSeq[byte](32)
      b[0] = layout; b[1] = kind; b[2] = 5
      reg.decodeVendorAreas(recordWith(b), log)[0]
    var r = run(1, 7)
    doAssert "kind" in r and "a" in r and "b" in r
    r = run(2, 7) # kind is absent, though its raw byte is 7
    doAssert "kind" notin r and "a" notin r and "b" notin r
    r = run(1, 6)
    doAssert "kind" in r and "a" notin r and "b" notin r

  block one_block_per_matched_target:
    let reg = regOf("""(vendormap "d" (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name pos) (field v (at 5) (enc u8)))
  (target (kind extendedHeader) (name m1) (match (at 4) (bytes 1)) (field v (at 5) (enc u8)))
  (target (kind extendedHeader) (name m2) (match (at 4) (bytes 1)) (field w (at 5) (enc u8))))""")
    var log: DiagLog
    let r = reg.decodeVendorAreas(recordWith(join(module(1, 4), module(2, 4), module(1, 6))), log)
    doAssert r.names == @["pos#1", "m1#1", "m2#1", "m1#3", "m2#3"], $r.names
    doAssert r[0].fields.len == 1 and r[1]["v"].intVal == 4 and r[3]["v"].intVal == 6
    let notes = reg.maps[0].checkVendorMap
    doAssert notes.len == 1 and "pos and m1" in notes[0] and "field v" in notes[0], $notes
    doAssert regOf(modules).maps[0].checkVendorMap.len == 0 # disjoint byte runs
    # `decode` still gives the first block.
    var ctx = ctxZeta()
    doAssert reg.decode(ctx, VendorArea(kind: vtExtendedHeader, blockIndex: 1, blockType: -1, extIndex: -1),
      module(1, 4), log).get.name == "pos"

  block check_notes_for_record_conditions:
    let m = loadVendorMap("""(.nif27)
(vendormap "k" (target (kind traceExt)
  (field a (at 1) (enc u8) (when (record extendedHeader (match (at 1) (bytes 1)) (byte 33)) (is 1)))
  (field b (at 2) (enc u8) (when (record extendedHeader (match (at 30) (bytes 1 2 3 4)) (byte 1)) (is 1)))))""")
    let notes = m.checkVendorMap
    doAssert notes.len == 2 and "field a" in notes[0] and "byte 33" in notes[0], $notes
    doAssert "field b" in notes[1] and "never holds" in notes[1], $notes

  block match_has_one_at_and_one_bytes:
    expectError("(vendormap \"a\" (target (kind block) (match (at 1) (at 2) (bytes 1))))", "two (at)")
    expectError("(vendormap \"a\" (target (kind block) (match (at 1) (bytes 1) (bytes 2))))",
      "two (bytes)")

  block first_matching_module_is_read:
    let reg = regOf("""(vendormap "r" (match (format segd) (manufacturer 77))
  (target (kind traceExt) (extension 2) (name tx)
    (field v3only (at 2) (enc u8)
      (when (record extendedHeader (match (at 1) (bytes 0x5A 0 0 6)) (byte 5)) (is 3)))))""")
    let t = SegdTrace(layout: slRev2, extensions: module(1, 0, [1'u8, 2]))
    var log: DiagLog
    let a = reg.decodeVendorAreas(recordWith(join(module(6, 3), module(6, 2))), t, log)
    doAssert "v3only" in a[0]
    let b = reg.decodeVendorAreas(recordWith(join(module(6, 2), module(6, 3))), t, log)
    doAssert "v3only" notin b[0]
    # The overload with a context built once per record gives the same.
    let rec = recordWith(join(module(6, 3)))
    let ctx = vendorContext(rec, reg.usesRecordBlocks)
    doAssert ctx.extended.len == 32
    doAssert reg.decodeVendorAreas(ctx, rec, t, log)[0].fields.len == 1
    doAssert vendorContext(rec, false).extended.len == 0
    # A map built in code reports its use of record blocks too.
    var built = VendorMap(name: "b")
    doAssert not built.usesRecordBlocks
    built.match.blocks.add VendorBlockMatch(area: vtExtendedHeader)
    doAssert built.usesRecordBlocks

  block rev3_record_blocks_and_typed_matches:
    let reg = regOf("""(vendormap "r3" (match (format segd) (manufacturer 77)
    (hasBlock generalHeader (match (at 1) (bytes 8 8))))
  (target (kind block) (type 0xB0) (where generalHeader) (name hit) (match (at 1) (bytes 7 7))
    (field x (at 3) (enc u8))))""")
    var rec = SegdRecord(layout: slRev3)
    rec.gh1.manufacturerCode = 77
    var g = newSeq[byte](96)
    g[0] = 7; g[1] = 7; g[2] = 41; g[31] = 0xB0     # matches
    g[32] = 8; g[33] = 8; g[34] = 42; g[63] = 0xB0  # type matches, bytes do not
    g[64] = 7; g[65] = 7; g[66] = 43; g[95] = 0xB0  # a second one
    rec.generalBlocks = g
    var log: DiagLog
    let r = reg.decodeVendorAreas(rec, log)
    doAssert r.len == 2 and r[0]["x"].intVal == 41 and r[1]["x"].intVal == 43, $r.names
    doAssert vendorContext(rec).general.len == 96
    rec.generalBlocks[32] = 9 # the block that identifies the map is gone: the map does not apply
    doAssert reg.decodeVendorAreas(rec, log).len == 0
    doAssert log.len == 0

  block documented_examples_load:
    for src in [
        """(vendormap "a" (match (format segd) (manufacturer 9)
  (hasBlock extendedHeader (match (at 1) (bytes 0x09 0 0 1 1)))) (target (kind block) (field x (at 1) (enc u8))))""",
        """(vendormap "a" (target (kind extendedHeader) (name acmeSource)
  (match (at 1) (bytes 0x09 0 0 2))          ; bytes 1-4 of the block
  (field shot (at 6) (enc u32))))""",
        """(vendormap "a" (target (kind traceExt) (name t) (field layout (at 1) (enc u8))
(field orientation (at 26) (enc u8) (when (field layout) (is 2)))
(group (when (byte 30) (in 1 2))              ; one condition for several fields
  (field a (at 2) (enc u8))
  (field b (at 3) (enc u16)))))""",
        """(vendormap "a" (target (kind traceExt) (name t)
(field flags  (at 12) (nibble high) (len 1n) (enc unibble))   ; high 4 bits
(field mode   (at 12) (nibble low)  (len 1n) (enc unibble))   ; low 4 bits
(field digit  (at 13) (nibble low)  (len 1n) (enc bcd))       ; one BCD digit
(field wide   (at 14) (len 3n) (enc unibble))                 ; 12 bits: nibbles 1-3 of bytes 14-15
(field wide2  (at 14) (nibble low) (len 3n) (enc unibble))))"""]:
      discard loadVendorMap("(.nif27)\n" & src) # the nibble example overlaps on purpose

when isMainModule: main()
