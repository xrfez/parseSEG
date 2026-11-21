## A vendor map's `(layout)` and the layout entry `divisor`: the line and point
## numbers a file stores times 100 (its textual header says so) are read as the
## numbers themselves, by the keys of an open file, whole numbers exactly and a
## fraction (100.5 stored as 10050) kept. Hand-built Rev 0 and Rev 1 files.
##
## Seen failing (each by breaking the code, then restoring it): the division
## in `segykeys.read` removed (every key 100 times too large), the map's
## layout not merged in `indexSegy` (keys NaN), the cache check in
## `openMapped` removed (cached keys NaN), `(divisor)` not compiled.

import std/[assertions, math, os, strutils]

import parseSEG

from parseSEG/model/traceindex import mindex

import ./utils/testutils

const
  Sentence = "C37 SOURCE AND RECEIVER LINE AND POINT NUMBERS ARE X 100 IN TRACE HEADERS"
  MapPath = currentSourcePath().parentDir / ".." / "vendormaps" / "segy-x100-stations.nif"

proc put32(b: var seq[byte], at: int, v: int) =
  for k in 0..3: b[at + k] = byte((v shr (8 * (3 - k))) and 0xFF)

proc put16(b: var seq[byte], at: int, v: int) =
  b[at] = byte((v shr 8) and 0xFF)
  b[at + 1] = byte(v and 0xFF)

proc writeStored(path: string, rev: int, text: string, stored: openArray[array[4, int]],
    codes: openArray[int] = []) =
  ## Big-endian, IEEE float, one sample per trace; per trace the four stored
  ## numbers (receiver line and point, source line and point) at bytes 181-196.
  var b = newSeq[byte](3600 + stored.len * 244)
  for i, c in text: b[i] = byte(c)
  b.put16(3216, 2000)
  b.put16(3220, 1)
  b.put16(3224, 5)
  b[3500] = byte(rev)
  if rev >= 1: b.put16(3502, 1)
  for t, s in stored:
    let at = 3600 + t * 244
    b.put32(at, t + 1)
    b.put16(at + 114, 1)
    b.put16(at + 116, 2000)
    if t < codes.len: b.put16(at + 28, codes[t])
    for k in 0..3: b.put32(at + 180 + 4 * k, s[k])
  writeBytes(path, b)

proc registry(): VendorRegistry =
  result.addMap loadVendorMap(readFile(MapPath), MapPath)

proc checkKeys(f: SeismicFile) =
  let ks = f.traceKeys(0 ..< f.len)
  let k0 = ks[0]
  doAssert k0.rcvLine == 100.0 and k0.rcvPoint == 316.0, $k0.rcvLine & " " & $k0.rcvPoint
  doAssert k0.srcLine == 519.0 and k0.srcPoint == 136.0, $k0.srcLine & " " & $k0.srcPoint
  let k1 = ks[1] # a point with a fraction
  doAssert k1.srcPoint == 100.5 and k1.rcvPoint == 7.25, $k1.srcPoint & " " & $k1.rcvPoint
  doAssert k1.srcLine == 519.0 and k1.rcvLine == 100.0

proc expectMapError(src, why: string) =
  try:
    discard loadVendorMap("(.nif27)\n" & src)
    doAssert false, "accepted: " & src
  except ValueError as e:
    doAssert why in e.msg, e.msg

proc main*() =
  let tmp = scratchDir("parseseg_tvendorlayout")
  let stored = [[10000, 31600, 51900, 13600], [10000, 725, 51900, 10050]]
  let reg = registry()

  block stated_in_the_text:
    for rev in [0, 1]: # Rev 1 is fixed-length: the sampled index reads the keys
      let p = tmp / "x100.sgy"
      writeStored(p, rev, Sentence, stored)
      var plain = openSeismic(p, keys = true)
      doAssert plain.traceKeys(0).srcLine.isNaN # as before: not a station
      doAssert plain.traceKeys(0).srcPoint.isNaN
      plain.close()
      for withKeys in [true, false]: # stored keys and keys on demand agree
        var f = openSeismic(p, keys = withKeys, opts = OpenOptions(vendors: reg))
        f.checkKeys()
        f.close()
      var full = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg, verify: vfFull))
      full.checkKeys()
      full.close()

  block no_sentence_no_change:
    let p = tmp / "plain.sgy"
    writeStored(p, 0, "C 1 NOTHING SAID", stored)
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg))
    doAssert f.traceKeys(0).srcLine.isNaN and f.traceKeys(0).srcPoint.isNaN
    f.close()

  block index_cache_is_not_used_with_the_map:
    let p = tmp / "cached.sgy"
    let c = tmp / "cached.idx"
    writeStored(p, 0, Sentence, stored)
    var a = openSeismic(p, keys = true) # the cache is made without the map
    a.saveIndex(c)
    a.close()
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg, cache: c))
    doAssert not f.fromCache
    f.checkKeys()
    f.close()

  block rev1_cdp_phrase_reads_as_before:
    # "... ARE X 100 IN TRACE HEADERS" about something else (CDP coordinates): no map
    let p = tmp / "cdp.sgy"
    writeStored(p, 1, "C 5 CDP COORDINATES ARE X 100 IN TRACE HEADERS", stored)
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg))
    doAssert f.traceKeys(0).srcLine.isNaN and f.traceKeys(0).rcvLine.isNaN
    doAssert f.traceKeys(0).inline == 51900.0 and f.traceKeys(0).crossline == 13600.0
    doAssert not f.index.vendorLayout
    f.close()

  block auxiliary_traces_have_no_receiver:
    let p = tmp / "aux.sgy"
    writeStored(p, 0, Sentence, [stored[0], stored[0], stored[0]], [1, 4, 6])
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg))
    let ks = f.traceKeys(0 ..< f.len)
    doAssert ks[0].rcvLine == 100.0 and ks[0].rcvPoint == 316.0
    for i in 1 .. 2: # time break and sweep: the source stays, the receiver is blank
      doAssert ks[i].srcLine == 519.0 and ks[i].srcPoint == 136.0
      doAssert ks[i].rcvLine.isNaN and ks[i].rcvPoint.isNaN, $ks[i].rcvLine
    f.close()

  block cache_saved_with_the_map_is_refused:
    let p = tmp / "refuse.sgy"
    writeStored(p, 0, Sentence, stored)
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg))
    doAssert f.index.vendorLayout
    try:
      f.saveIndex(tmp / "refuse.idx")
      doAssert false, "saved"
    except ValueError as e:
      doAssert "vendor map" in e.msg, e.msg
    f.close()

  block write_back_says_read_only:
    let p = tmp / "wb.sgy"
    writeStored(p, 0, Sentence, stored)
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg))
    f.mindex.keys[0].srcLine = 600.0
    var ed = openEditor(move f)
    discard ed.writeGeometry()
    doAssert ed.log.has("times 100", sevWarning), $ed.log
    ed.close()

  block files_own_stanza_wins:
    # the file's Layout stanza names sht_point at byte 21: the map's does not replace it
    let p = tmp / "stanza.sgy"
    writeStored(p, 2, Sentence, stored)
    var raw = readBytes(p)
    # a tiny extended text header holding the stanza, announced in the binary header
    let xml = "((SEG:Layout:text/xml))\n<segy-layout name=\"own\"><entry name=\"sht_point\" " &
      "byte=\"21\" type=\"int4\"/></segy-layout>\n((SEG:EndText))\n"
    var rec = newSeq[byte](3200)
    for i in 0 ..< 3200: rec[i] = 0x20
    for i, c in xml: rec[i] = byte(c)
    raw.put16(3504, 1)
    var all = raw[0 ..< 3600] & rec & raw[3600 .. ^1]
    for t in 0 ..< stored.len: all.put32(3600 + 3200 + t * 244 + 20, 777 + t)
    writeBytes(p, all)
    var f = openSeismic(p, keys = true, opts = OpenOptions(vendors: reg))
    let k = f.traceKeys(0 ..< f.len)
    doAssert k[0].srcPoint == 777.0, "the stanza's sht_point stays: " & $k[0].srcPoint
    doAssert k[0].srcLine == 519.0, "the map's other entries apply"
    f.close()

  block layout_stanza_divisor:
    let lay = parseLayout("""<segy-layout name="t">
      <entry name="sht_point" byte="193" type="int4" divisor="100"/></segy-layout>""")
    doAssert lay.entries[0].divisor == 100
    for bad in ["0", "-3", "x", "100000000"]:
      try:
        discard parseLayout("<segy-layout><entry name=\"sht_point\" byte=\"193\" " &
          "type=\"int4\" divisor=\"" & bad & "\"/></segy-layout>")
        doAssert false, "accepted divisor " & bad
      except ValueError as e:
        doAssert "divisor" in e.msg, e.msg

  block map_errors:
    expectMapError("(vendormap \"a\" (version 1) (match (format segy)) " &
      "(layout (entry sht_point (at 193) (type int4) (divisor 0))))", "divisor")
    expectMapError("(vendormap \"a\" (version 1) (match (format segy)) " &
      "(layout (entry sht_point (at 239) (type int4))))", "240-byte")
    expectMapError("(vendormap \"a\" (version 1) (match (format segy)) " &
      "(layout (entry sht_point (at 193) (type nope))))", "layout type")
    expectMapError("(vendormap \"a\" (version 1) (match (format segy)))", "no target or layout")

  echo "tvendorlayout: ok"

when isMainModule: main()
