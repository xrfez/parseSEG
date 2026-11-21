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

import ./utils/testutils

const
  Sentence = "C37 SOURCE AND RECEIVER LINE AND POINT NUMBERS ARE X 100 IN TRACE HEADERS"
  MapPath = currentSourcePath().parentDir / ".." / "vendormaps" / "segy-x100-stations.nif"

proc put32(b: var seq[byte], at: int, v: int) =
  for k in 0..3: b[at + k] = byte((v shr (8 * (3 - k))) and 0xFF)

proc put16(b: var seq[byte], at: int, v: int) =
  b[at] = byte((v shr 8) and 0xFF)
  b[at + 1] = byte(v and 0xFF)

proc writeStored(path: string, rev: int, text: string, stored: openArray[array[4, int]]) =
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
