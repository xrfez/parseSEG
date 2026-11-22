## SEG-Y stanzas (`addStanza`, `addTextStanza`) and SEG-D external headers
## (`writeTrace(keys, samples, externalHeader = ...)`) written by the high-level
## writers: read back byte for byte through the public reading API and through
## a (made-up) vendor map, for files and for memory, with every refusal.
##
## Seen to fail first, by breaking the code and restoring it:
## - segy_stanzas: the binary header's extended-record count left as it was
##   (the stanza was refused: "declares no extended records, 1 are present")
## - segy_stanzas: the EndText record not put back after the stanza (the
##   record count of a Rev 2 file was one short)
## - segd_external_headers: GH#1's external block count left 0 (the writer
##   refused the record: "the external header has 32 bytes, 0 announced")
## - segd_external_headers: the extended count (GH#2) left 0 for 100 blocks

import std/[assertions, os, strutils]

import parseSEG

import ./utils/testutils

const
  SegyMap = """(.nif27)
(vendormap "acme-segy" (version 1)
  (match (format segy) (textContains "ACME SHOT STANZAS"))
  (target (kind stanza) (stanza "acme:Shot v1") (name acmeShot)
    (field magic (at 1) (len 4) (enc ascii))
    (field count (at 5) (enc u16))
    (field value (at 7) (enc f32))))
"""
  SegdMap = """(.nif27)
(vendormap "acme-segd" (version 1)
  (match (format segd) (rev 3.0 3.1) (hasBlock externalHeader (match (at 1) (bytes 0x41 0x43 0x4D 0x45))))
  (target (kind externalHeader) (name acmeShot)
    (field magic (at 1) (len 4) (enc ascii))
    (field count (at 5) (enc u16))
    (field value (at 7) (enc f32))))
"""

template expect(part: string, body: untyped) =
  try:
    body
    doAssert false, "expected ValueError containing: " & part
  except ValueError as e:
    doAssert e.msg.find(part) >= 0, e.msg

proc shotBytes(n: int, count: uint16, value: float32): seq[byte] =
  # "ACME", a u16 count, an f32 value (big-endian), then `n` filler bytes.
  result = @[byte 0x41, 0x43, 0x4D, 0x45, byte(count shr 8), byte(count and 0xFF)]
  let bits = cast[uint32](value)
  for k in 0 .. 3: result.add byte((bits shr (8 * (3 - k))) and 0xFF)
  for i in 0 ..< n: result.add byte(i * 7 + 3)

proc keys(i: int): TraceKeys =
  result = initTraceKeys()
  result.record = float64(1 + i div 2)
  result.channel = float64(1 + i mod 2)
  result.intervalUs = 2000
  result.srcLine = 1
  result.srcPoint = 100.5 + float64(1 + i div 2)
  result.srcIndex = 1
  result.srcX = 500_000.5
  result.srcY = 6_000_000.25
  result.rcvLine = 7
  result.rcvPoint = float64(200 + i)
  result.rcvIndex = 1
  result.rcvX = 501_000 + 25 * float64(i)
  result.rcvY = 6_001_000
  result.status = tsLive

proc row(i: int, n = 8): seq[float32] =
  result = newSeq[float32](n)
  for j in 0 ..< n: result[j] = float32(i) + float32(j) * 0.5'f32

proc registry(map: string): VendorRegistry =
  result.addMap loadVendorMap(map, "test")

proc stanzaData(f: SeismicFile, i: int): seq[byte] =
  # The bytes of the i-th binary stanza, through the reader's index.
  let ext = f.index.segy.extended
  var seen = 0
  for st in ext.stanzas:
    if st.isBinary and not st.isUserData:
      if seen == i:
        return ext.data[st.dataStart ..< st.dataStart + st.byteCount]
      inc seen
  doAssert false, "no binary stanza " & $i

proc segyOpts(major, minor: int): SegyOutputOptions =
  SegyOutputOptions(revision: SegyRevision(major: uint8(major), minor: uint8(minor)),
    text: @["ACME SHOT STANZAS VERSION 1"])

proc main*() =
  let tmp = scratchDir("parseseg_tstanzas")

  block segy_stanzas:
    let a = shotBytes(0, 1, 1.5)
    let b = shotBytes(3200, 2, -2.25) # a stanza of more than one record
    let c = @[byte 1] # one byte
    let empty: seq[byte] = @[]
    for (major, minor) in [(1, 0), (2, 0), (2, 1)]:
      for memory in [false, true]:
        let o = segyOpts(major, minor)
        var w = if memory: openSeismicWriterBytes(o) else: openSeismicWriter(tmp / "s.sgy", o)
        w.addStanza("acme", "Shot v1", a)
        w.addStanza("acme", "Shot v1", b, "application/x-acme")
        w.addTextStanza("acme", "Notes", "hello stanza")
        w.addStanza("acme", "One", c)
        w.addStanza("acme", "Empty", empty)
        for i in 0 ..< 3: w.writeTrace(keys(i), row(i))
        var bytes: seq[byte]
        if memory: bytes = w.finishBytes() else: discard w.close()
        var f = if memory: openSeismicBytes(bytes, "m.sgy", keys = true)
          else: openSeismic(tmp / "s.sgy", keys = true)
        doAssert f.kind == skSegy and f.len == 3 and not f.log.isFatal, $f.log
        doAssert f.log.count(sevWarning) == 0 and f.log.count(sevError) == 0, $f.log
        let ext = f.index.segy.extended
        # a: 1 record; b: 2 records (3200 + header); text: 1; one: 1; empty: 1.
        let want = 1 + 2 + 1 + 1 + 1 + (if major >= 2: 1 else: 0) # Rev 2 ends with EndText
        doAssert ext.recordCount == want, $ext.recordCount & " vs " & $want
        doAssert int(f.index.segy.binary.numExtTextHeaders) == want
        doAssert stanzaData(f, 0) == a and stanzaData(f, 1) == b
        doAssert stanzaData(f, 2) == c and stanzaData(f, 3) == empty
        doAssert ext.stanzas[1].contentType == "application/x-acme"
        doAssert ext.stanzas[2].name == "Notes" and not ext.stanzas[2].isBinary
        doAssert ext.hasEndText == (major >= 2)
        # The samples and keys are those written.
        let x = f.readTraces(0 ..< 3)
        for i in 0 ..< 3:
          for j in 0 ..< 8: doAssert x[i, j] == row(i)[j]
          doAssert f.traceKeys(i).rcvX == keys(i).rcvX
        # Through a map: the first "acme:Shot v1" stanza decodes by name.
        var log: DiagLog
        let blocks = registry(SegyMap).decodeVendorAreas(f.index.segy, log)
        doAssert blocks.len >= 1 and blocks[0].name == "acmeShot", $blocks.len
        var count = -1'i64
        var value = NaN
        for fl in blocks[0].fields:
          if fl.name == "count": count = fl.value.intVal
          if fl.name == "value": value = fl.value.floatVal
        doAssert count == 1 and value == 1.5, $count & " " & $value
        f.close()
        if not memory: writeFile(tmp / "disk.bin", readFile(tmp / "s.sgy"))
        else: doAssert readFile(tmp / "disk.bin").toBytes == bytes, "memory differs from disk"

  block segy_like_writers:
    # A template file's own extended header stays first; the stanza follows.
    var f = openSeismic(demoDir() / "survey.sgy", keys = true)
    let before = f.index.segy.extended.recordCount
    let x = f.readTraces(0 ..< 3)
    var d = openSeismicWriter(tmp / "like.sgy", f)
    var m = openSeismicWriterBytes(f)
    for w in [addr d, addr m]:
      w[].addStanza("acme", "Shot v1", shotBytes(10, 5, 0.5))
      for i in 0 ..< 3: w[].writeTrace(f, i, x, i)
    discard d.close()
    let bytes = m.finishBytes()
    doAssert readFile(tmp / "like.sgy").toBytes == bytes
    var g = openSeismic(tmp / "like.sgy")
    doAssert g.len == 3 and not g.log.isFatal and g.log.count(sevError) == 0, $g.log
    doAssert g.index.segy.extended.recordCount == before + 1
    var found = false
    for st in g.index.segy.extended.stanzas:
      if st.key == "ACME:SHOTV1":
        found = true
        doAssert g.index.segy.extended.data[st.dataStart ..< st.dataStart + st.byteCount] ==
          shotBytes(10, 5, 0.5)
    doAssert found
    doAssert g.readTraces(0 ..< 3) == x
    g.close()
    f.close()

  block segy_refusals:
    var w = openSeismicWriter(tmp / "r.sgy", segyOpts(2, 1))
    expect("company"): w.addStanza("", "x", [byte 1])
    expect("name"): w.addStanza("acme", "a:b", [byte 1])
    expect("name"): w.addStanza("acme", "a))b", [byte 1])
    expect("content type"): w.addStanza("acme", "x", [byte 1], "a:b")
    expect("company"): w.addTextStanza("ac\nme", "x", "t")
    w.addStanza("acme", "ok", [byte 1])
    w.writeTrace(keys(0), row(0))
    expect("before the first trace"): w.addStanza("acme", "late", [byte 1])
    expect("before the first trace"): w.addTextStanza("acme", "late", "t")
    discard w.close()
    expect("closed"): w.addStanza("acme", "x", [byte 1])
    # The terminator is the writer's, in every revision.
    for (major, minor) in [(1, 0), (2, 0), (2, 1)]:
      var we = openSeismicWriterBytes(segyOpts(major, minor))
      for (c, n) in [("SEG", "EndText"), ("seg", "End Text"), (" SEG ", "endtext")]:
        expect("EndText"): we.addStanza(c, n, [byte 1])
        expect("EndText"): we.addTextStanza(c, n, "t")
      we.addStanza("acme", "ok", [byte 1]) # the writer is intact
      we.writeTrace(keys(0), row(0))
      var fe = openSeismicBytes(we.finishBytes(), "e.sgy")
      doAssert not fe.log.isFatal and fe.log.count(sevError) == 0, $fe.log
      fe.close()
    var r0 = openSeismicWriter(tmp / "r0.sgy", segyOpts(0, 0))
    expect("Rev 0"): r0.addStanza("acme", "x", [byte 1])
    var rd = openSeismicWriter(tmp / "rd.sgd", SegdOutputOptions(sampleIntervalUs: 2000,
      numSamples: 8, time: 1_709_273_228.0))
    expect("SEG-D"): rd.addStanza("acme", "x", [byte 1])
    # Data that looks like a stanza header is data: the byte count covers it.
    var tricky = openSeismicWriterBytes(segyOpts(2, 1))
    var evil = newSeq[byte](3200)
    let inner = "((acme:inner:application/octet-stream:5))"
    for i, c in inner: evil[i] = byte(c)
    tricky.addStanza("acme", "outer", evil)
    discard tricky.finishBytes # headers only: a valid file
    # Too many records for the binary header's count.
    var big = openSeismicWriterBytes(segyOpts(2, 1))
    let chunk = newSeq[byte](3200 * 4000)
    for i in 0 ..< 8: big.addStanza("acme", "n" & $i, chunk)
    expect("32767"): big.addStanza("acme", "n9", chunk)
    # A like-writer on a SEG-D file is refused too.
    var sd = openSeismic(demoDir() / "shot.sgd")
    var lw = openSeismicWriterBytes(sd)
    expect("SEG-D"): lw.addStanza("acme", "x", [byte 1])
    sd.close()

  block segd_external_headers:
    # Several records, each with its own external header; sizes around the
    # two-digit BCD limit (99 blocks; 100 and more go to GH#2's count).
    let sizes = [32, 64, 99 * 32, 100 * 32, 3200 * 3 + 32, 0]
    var heads: seq[seq[byte]]
    for r, n in sizes:
      heads.add(if n == 0: @[] else: shotBytes(n - 10, uint16(r), float32(r) + 0.25'f32))
    for memory in [false, true]:
      let o = SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 8, time: 1_709_273_228.0)
      var w = if memory: openSeismicWriterBytes(o) else: openSeismicWriter(tmp / "e.sgd", o)
      var t = 0
      for r in 0 ..< sizes.len:
        for ch in 0 ..< 3:
          var k = keys(2 * r)
          k.record = float64(r + 1)
          k.channel = float64(ch + 1)
          k.rcvPoint = float64(200 + ch)
          k.rcvX = 501_000 + 25 * float64(ch)
          # The first trace sets it; later traces pass nothing or the same bytes.
          let pass = if ch == 0 or ch == 2: heads[r] else: @[]
          w.writeTrace(k, row(t), externalHeader = pass)
          inc t
      var bytes: seq[byte]
      if memory: bytes = w.finishBytes() else: discard w.close()
      var f = if memory: openSeismicBytes(bytes, "m.sgd", keys = true)
        else: openSeismic(tmp / "e.sgd", keys = true)
      doAssert f.kind == skSegd and f.len == 3 * sizes.len, $f.len
      doAssert not f.log.isFatal and f.log.count(sevError) == 0, $f.log
      let reg = registry(SegdMap)
      for r in 0 ..< sizes.len:
        let rec = f.index.segdRecords[r]
        doAssert rec.external == heads[r], "record " & $r
        doAssert rec.externalHeaderBlocks == sizes[r] div 32
        var log: DiagLog
        let blocks = reg.decodeVendorAreas(rec, log)
        if sizes[r] == 0: doAssert blocks.len == 0
        else:
          doAssert blocks.len >= 1 and blocks[0].name == "acmeShot", $r
          for fl in blocks[0].fields:
            if fl.name == "count": doAssert fl.value.intVal == r
      let x = f.readTraces(0 ..< f.len)
      for i in 0 ..< f.len:
        for j in 0 ..< 8: doAssert x[i, j] == row(i)[j]
      f.close()
      if not memory: writeFile(tmp / "disk.bin", readFile(tmp / "e.sgd"))
      else: doAssert readFile(tmp / "disk.bin").toBytes == bytes, "memory differs from disk"

  block segd_refusals:
    let o = SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 8, time: 1_709_273_228.0)
    var w = openSeismicWriterBytes(o)
    let h = shotBytes(22, 1, 1.0) # 32 bytes
    expect("32-byte blocks"): w.writeTrace(keys(0), row(0), externalHeader = h[0 ..< 31])
    expect("32-byte blocks"): w.writeTrace(keys(0), row(0), externalHeader = h & @[byte 0])
    # More blocks than GH#2's 24-bit count holds: a ValueError, not a failed flush.
    let tooLong = newSeq[byte](0xFF_FFFF * 32 + 32)
    expect("24-bit"): w.writeTrace(keys(0), row(0), externalHeader = tooLong)
    doAssert w.len == 0 # nothing was written by the refusals
    w.writeTrace(keys(0), row(0), externalHeader = h)
    var other = h
    other[20] = 99
    expect("differs"): w.writeTrace(keys(1), row(1), externalHeader = other)
    expect("differs"): w.writeTrace(keys(1), row(1), externalHeader = h & h)
    w.writeTrace(keys(1), row(1), externalHeader = h)   # the same bytes
    doAssert w.len == 2
    # The next record may set another one, or none.
    var k2 = keys(2)
    w.writeTrace(k2, row(2), externalHeader = other)
    discard w.finishBytes()
    # SEG-Y and a SEG-D file written like another refuse it in plain words.
    var wy = openSeismicWriterBytes(segyOpts(2, 1))
    expect("only to SEG-D"): wy.writeTrace(keys(0), row(0), externalHeader = h)
    var sd = openSeismic(demoDir() / "shot.sgd")
    var wl = openSeismicWriterBytes(sd)
    expect("only to SEG-D"): wl.writeTrace(keys(0), row(0), externalHeader = h)
    sd.close()

  block unchanged_without_the_calls:
    # No stanza and no external header: the file is the one written before these
    # arguments existed (an empty one is the same as none).
    var a = openSeismicWriterBytes(segyOpts(2, 1))
    var b = openSeismicWriterBytes(segyOpts(2, 1))
    a.writeTrace(keys(0), row(0))
    b.writeTrace(keys(0), row(0), externalHeader = [])
    doAssert a.finishBytes() == b.finishBytes()

when isMainModule: main()
