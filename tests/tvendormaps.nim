## Vendor maps: loader, validator, matcher, decoding, code decoders (task 4.5).

import std/[assertions, os, math, strutils]
import parseSEGD/common/[ibmfloat, ebcdic]
import parseSEGD/segd/[reader as segdreader]
import parseSEGD/segy/[reader as segyreader]
import parseSEGD/vendor/apply

const here = currentSourcePath().parentDir
const exampleDir = here / ".." / "SEG Spec" / "exampleFiles"

proc ctxAcme(): VendorContext =
  VendorContext(format: "segd", revision: 2.1, manufacturer: 13, serial: 77, byteOrder: boBig)

proc area(kind: VendorTargetKind, blockIndex = -1, ext = -1): VendorArea =
  VendorArea(kind: kind, blockIndex: blockIndex, blockType: -1, extIndex: ext)

proc block1(): seq[byte] =
  result = newSeq[byte](32)
  for i, c in "CREW 7": result[i] = byte(c)
  for i in 6..15: result[i] = byte(' ')
  result[16] = 0b101                        # clipped + reversed
  result[17] = 0x12; result[18] = 0x34      # unitSn BCD 1234
  result[19] = 2                            # mode: calibration
  putBeI16(result, 20, -150)                # tilt -1.50 deg
  putBeU24(result, 22, 0xFFFFFF)            # depth: sentinel -> absent
  result[25] = 4                            # nChannels
  result[26] = 0xE8; result[27] = 0x03      # battery 1000 (little) -> 10 + 1.0 V
  for i in 28..31: result[i] = byte(i)

proc block2(): seq[byte] =
  result = newSeq[byte](32)
  for k in 0..3:
    putBeU32(result, 8 * k, uint32(100 + k))
    putBeF32(result, 8 * k + 4, float32(k) * 0.5)

var reg: VendorRegistry
var log: DiagLog
reg.loadVendorMaps([here / "vendormaps"], log)

block load_example_map:
  doAssert log.len == 0, $log[0]
  doAssert reg.maps.len == 1
  let m = reg.maps[0]
  doAssert m.name == "acme-extended" and m.version == 1 and m.targets.len == 3
  doAssert m.match.manufacturers == @[13] and m.match.revMin == 2.0 and m.match.revMax == 2.1
  doAssert m.targets[0].fields.len == 9 and m.targets[1].repeats[0].fields.len == 2
  doAssert m.targets[0].fields[5].hasSentinel and m.targets[0].fields[5].sentinel == 0xFFFFFF
  doAssert m.targets[2].fields[4].enums == @[(0xB0'i64, "status"), (0xB1'i64, "gps")]
  doAssert m.checkVendorMap.len == 0

block decode_every_field_kind:
  var blk: VendorBlock
  var l: DiagLog
  doAssert reg.decode(ctxAcme(), area(vtExtendedHeader, 1), block1(), blk, l)
  doAssert l.len == 0, $l[0]
  doAssert blk.mapName == "acme-extended" and blk.name == "acmeRecordInfo"
  doAssert blk.get("crewName").text == "CREW 7"
  doAssert blk.get("status").flags == @["clipped", "reversed"]
  doAssert blk.get("unitSn").intVal == 1234
  doAssert blk.get("mode").label == "calibration"
  doAssert blk.get("tilt").floatVal == -1.5 and blk.get("tilt").unit == "deg"
  doAssert "depth" notin blk # sentinel
  doAssert abs(blk.get("battery").floatVal - 11.0) < 1e-12
  doAssert blk.get("tail").bytes == @[28'u8, 29, 30, 31]
  var b2: VendorBlock
  doAssert reg.decode(ctxAcme(), area(vtExtendedHeader, 2), block2(), b2, l)
  doAssert b2.get("chanId[3]").intVal == 103 and b2.get("gain[2]").floatVal == 1.0
  # Trace extension #2: fixed point, IBM float, EBCDIC, low-nibble BCD, hex enum.
  var e = newSeq[byte](32)
  e[0] = 0xFF; e[1] = 0xFF; e[2] = 0xFE; e[3] = 0x80; e[4] = 0x00 # -1.5
  putBeU32(e, 5, float32ToIbm(-118.625))
  let lbl = asciiToEbcdic("GPS1")
  for i in 0..3: e[9 + i] = lbl[i]
  e[13] = 0x01; e[14] = 0x23                                      # low nibble: 123
  e[15] = 0xB1
  var b3: VendorBlock
  doAssert reg.decode(ctxAcme(), area(vtTraceExt, ext = 2), e, b3, l)
  doAssert b3.get("position").floatVal == -1.5 and b3.get("level").floatVal == -118.625
  doAssert b3.get("label").text == "GPS1" and b3.get("code").intVal == 123
  doAssert b3.get("kind").label == "gps"

block matching_and_precedence:
  var l: DiagLog
  var blk: VendorBlock
  var other = ctxAcme()
  other.manufacturer = 9
  doAssert not reg.decode(other, area(vtExtendedHeader, 1), block1(), blk, l)
  var old = ctxAcme()
  old.revision = 1.0
  doAssert not reg.decode(old, area(vtExtendedHeader, 1), block1(), blk, l)
  doAssert not reg.decode(ctxAcme(), area(vtExtendedHeader, 3), block1(), blk, l)
  # A less specific map loses; an equally specific one is reported.
  var r2 = reg
  r2.addMap loadVendorMap("""(.nif27)
(vendormap "generic" (version 1) (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (field x (at 1) (enc u8))))""")
  doAssert r2.decode(ctxAcme(), area(vtExtendedHeader, 1), block1(), blk, l)
  doAssert blk.mapName == "acme-extended" and l.len == 0
  r2.addMap loadVendorMap("""(.nif27)
(vendormap "rival" (version 1) (match (format segd) (rev 2.0 2.1) (manufacturer 13))
  (target (kind extendedHeader) (blockIndex 1) (field y (at 1) (enc u8))))""")
  doAssert r2.decode(ctxAcme(), area(vtExtendedHeader, 1), block1(), blk, l)
  doAssert l.len == 1 and "equally" in l[0].msg
  # A code decoder beats every map.
  proc acmeCode(b: openArray[byte], a: VendorArea, c: VendorContext,
      blk: var VendorBlock): bool {.nimcall.} =
    blk.name = "fromCode"
    blk.fields.add ("first", VendorValue(kind: vvInt, intVal: int64(b[0])))
    true
  r2.registerVendorDecoder(13, vtExtendedHeader, "acme-code", acmeCode)
  doAssert r2.decode(ctxAcme(), area(vtExtendedHeader, 1), block1(), blk, l)
  doAssert blk.mapName == "acme-code" and blk.get("first").intVal == int64(byte('C'))

block areas_too_small_and_repeats_too_long:
  var l: DiagLog
  var blk: VendorBlock
  doAssert reg.decode(ctxAcme(), area(vtExtendedHeader, 1), block1()[0..19], blk, l)
  doAssert "crewName" in blk and "tilt" notin blk
  doAssert l.len >= 1 and "beyond" in l[0].msg
  var m = loadVendorMap("""(.nif27)
(vendormap "rep" (match (format segd))
  (target (kind externalHeader) (field n (at 1) (enc u8))
    (repeat (count (ref n)) (stride 4) (at 2) (field v (at 1) (enc u32)))))""")
  var r: VendorRegistry
  r.addMap m
  var bytes = newSeq[byte](10)
  bytes[0] = 200 # claims 200 elements, 2 fit
  var l2: DiagLog
  doAssert r.decode(ctxAcme(), area(vtExternalHeader), bytes, blk, l2)
  doAssert "v[1]" in blk and "v[2]" notin blk and "exceeds" in l2[0].msg

block malformed_maps_are_diagnostics:
  for (bad, why) in [
      ("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u7))))", "unknown encoding"),
      ("(vendormap \"a\" (target (kind block) (field x (enc u8))))", "no (at)"),
      ("(vendormap \"a\" (target (kind block) (field x (at 1) (len 3) (enc u16))))", "disagrees"),
      ("(vendormap \"a\" (target (kind nowhere)))", "unknown target kind"),
      ("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8) (when (y 1)))))", "not supported"),
      ("(vendormap \"a\" (target (kind block) (field x (at 1) (enc u8))", "unbalanced"),
      ("(vendormap \"a\")", "no target"),
      ("(something)", "no (vendormap")]:
    try:
      discard loadVendorMap("(.nif27)\n" & bad)
      doAssert false, "accepted: " & bad
    except ValueError as e:
      doAssert why in e.msg, e.msg
  let dir = getTempDir() / "parsesegd_tvendormaps"
  createDir(dir)
  writeFile(dir / "bad.nif", "(.nif27)\n(vendormap \"a\" (target (kind block)))\n(")
  writeFile(dir / "overlap.nif", """(.nif27)
(vendormap "o" (target (kind block) (field a (at 1) (enc u16)) (field b (at 2) (enc u8))))""")
  var r: VendorRegistry
  var l: DiagLog
  r.loadVendorMaps([dir], l)
  doAssert r.maps.len == 1 and r.maps[0].name == "o"
  doAssert l.count(sevWarning) == 1 and l.count(sevInfo) == 1 # bad.nif skipped; overlap noted

block applied_to_63_sgd:
  # Geo Space (manufacturer 9) extended header: 3 blocks, kept raw by the
  # reader. A map decodes block 1's first bytes; raw bytes stay intact.
  let d = readSegd(exampleDir / "63.sgd")
  let rec = d.records[0].record
  var r: VendorRegistry
  r.addMap loadVendorMap("""(.nif27)
(vendormap "geospace-probe" (match (format segd) (manufacturer 9))
  (target (kind extendedHeader) (blockIndex 1) (name gsBlock1)
    (field first (at 1) (enc u32)) (field second (at 5) (enc u32))))""")
  var l: DiagLog
  let blocks = r.decodeVendorAreas(rec, l, "63.sgd")
  doAssert l.len == 0 and blocks.len == 1 and blocks[0].name == "gsBlock1"
  doAssert blocks[0].get("first").intVal == int64(beU32(rec.extended, 0))
  doAssert blocks[0].get("second").intVal == int64(beU32(rec.extended, 4))
  # The trace's extensions #2 and #3 (manufacturer-defined) by number.
  r.addMap loadVendorMap("""(.nif27)
(vendormap "geospace-ext" (match (format segd) (manufacturer 9))
  (target (kind traceExt) (extension 3) (name gsExt3) (field w (at 1) (enc u16))))""")
  let tb = r.decodeVendorAreas(rec, d.records[0].traces[0], l, "63.sgd")
  doAssert tb.len == 1 and tb[0].get("w").intVal == int64(beU16(d.records[0].traces[0].extensions, 32))

block applied_to_segy:
  let f = readSegy(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  var r: VendorRegistry
  r.addMap loadVendorMap("""(.nif27)
(vendormap "inglewood" (match (format segy) (textContains "INGLEWOOD"))
  (target (kind traceHeaderBytes) (name relocated)
    (field iline (at 13) (enc i32)) (field xline (at 17) (enc i32)))
  (target (kind stanza) (stanza "SEG:Catalog") (name catalogStart)
    (field head (at 1) (len 1) (enc ascii))))""")
  var l: DiagLog
  let tb = r.decodeVendorAreas(f.file, f.traces[7], l)
  doAssert tb.len == 1 and tb[0].get("iline").intVal == 1001 and tb[0].get("xline").intVal == 8
  let fb = r.decodeVendorAreas(f.file, l)
  doAssert fb.len == 1 and fb[0].name == "catalogStart"
  doAssert l.len == 0
