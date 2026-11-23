## Writing SEG-Y traces built from `TraceKeys`, with no template trace:
## SEG-D and SEG-2 traces, and stacked traces, round-trip
## through `openSeismic` with their keys and samples.

import std/[assertions, math, os, strutils]

import parseSEG

import ./utils/testutils

proc same(a, b: float64): bool = (a.isNaN and b.isNaN) or a == b

proc sameOrZero(a, b: float64): bool = same(a, b) or (b.isNaN and a == 0)
  # Elevations, the record, the ensemble and the offset read back 0 when not written.

proc sameXY(ax, ay, kx, ky: float64): bool =
  # SEG-Y readers take a point at exactly (0, 0) as unset (NaN).
  (same(ax, kx) and same(ay, ky)) or (kx == 0 and ky == 0 and ax.isNaN and ay.isNaN)

proc checkKeys(a, k: TraceKeys, major: int) =
  # What a SEG-Y file of revision `major` holds of `k`.
  doAssert sameOrZero(a.record, k.record) and same(a.channel, k.channel)
  doAssert same(a.srcPoint, k.srcPoint)
  doAssert sameXY(a.srcX, a.srcY, k.srcX, k.srcY)
  doAssert sameXY(a.rcvX, a.rcvY, k.rcvX, k.rcvY)
  doAssert sameXY(a.cmpX, a.cmpY, k.cmpX, k.cmpY)
  doAssert sameOrZero(a.srcZ, k.srcZ) and sameOrZero(a.rcvZ, k.rcvZ)
  doAssert sameOrZero(a.ensemble, k.ensemble)
  # Before Rev 2 the offset is a whole number (Rev 2: also f64 in Ext1).
  doAssert k.offset.isNaN or a.offset == (if major >= 2: k.offset else: round(k.offset))
  doAssert a.t0Ms == k.t0Ms and a.intervalUs == k.intervalUs
  doAssert same(a.time, k.time) or abs(a.time - k.time) < 1e-6
  # Auxiliary has no general SEG-Y code (it reads back unknown); `component`
  # is not written as a code (outside SEG-Y it is a group index).
  doAssert a.status == (if k.status == tsAuxiliary: tsUnknown else: k.status)
  if major >= 1:
    doAssert same(a.inline, k.inline) and same(a.crossline, k.crossline)

proc paddedHeader(lines: openArray[string]): string =
  result = newString(3200)
  for i in 0 ..< result.len: result[i] = ' '
  for i, line in lines:
    if i >= 40: break
    let start = i * 80
    let n = min(line.len, 80)
    for j in 0 ..< n: result[start + j] = line[j]

proc sameHeader(path: string, lines: openArray[string], encoding: TextEncoding) =
  let want = encodeText(paddedHeader(lines), encoding)
  let got = readFile(path)
  doAssert got.len >= 3200, path
  for i in 0 ..< 3200:
    doAssert byte(got[i]) == want[i], "byte " & $i & " of " & path

proc reopenHeader(path: string, lines: openArray[string], encoding: TextEncoding) =
  var g = openSeismic(path)
  doAssert g.index.segy.text.encoding == encoding, path
  let want = paddedHeader(lines)
  for n in 1 .. 40:
    let card = g.index.segy.text.card(n)
    let start = (n - 1) * 80
    doAssert card == want[start ..< start + 80], path & " card " & $n
  g.close()

proc writeOne(path: string, opts: SegyOutputOptions) =
  var w = openSeismicWriter(path, opts)
  var k = initTraceKeys()
  k.intervalUs = 1000
  w.writeTrace(k, [1'f32, 2, 3])
  discard w.close()

proc fileCount(dir: string): int =
  for p in walkDir(dir): inc result

proc roundTrip(src: string, opts: SegyOutputOptions, dst: string) =
  var f = openSeismic(src, keys = true)
  let x = f.readTraces(0 ..< f.len)
  var w = openSeismicWriter(dst, opts)
  for t in 0 ..< f.len:
    var row = newSeq[float32](int(f.traceEntry(t).numSamples))
    for j in 0 ..< row.len: row[j] = x[t, j]
    w.writeTrace(f.traceKeys(t), row)
  discard w.close()
  var g = openSeismic(dst, keys = true)
  doAssert g.kind == skSegy and g.len == f.len
  for t in 0 ..< f.len:
    checkKeys(g.traceKeys(t), f.traceKeys(t), int(opts.revision.major))
    let n = int(f.traceEntry(t).numSamples)
    let y = g.readTraces(t..t)
    for j in 0 ..< n: doAssert y[0, j] == x[t, j]
  g.close()
  f.close()

proc main*() =
  let tmp = scratchDir("parseseg_twritekeys")

  block segd_and_seg2_to_segy:
    for name in ["record.sgd", "shot.sgd", "line.sg2"]:
      roundTrip(demoDir() / name, SegyOutputOptions(), tmp / (name & ".sgy"))
      roundTrip(demoDir() / name, SegyOutputOptions(revision: SegyRevision(major: 1),
        byteOrder: boBig), tmp / (name & ".rev1.sgy"))
      roundTrip(demoDir() / name, SegyOutputOptions(byteOrder: boLittle,
        format: st6), tmp / (name & ".le.sgy"))

  block stacked_traces:
    # A stack line: CDP numbers, midpoints, inline/crossline, a fractional
    # start time and interval, the fold through an override; one dead bin.
    let dst = tmp / "stack.sgy"
    var w = openSeismicWriter(dst, SegyOutputOptions(text: @["A STACK", "LINE 7"],
      traceSorting: 4, measurementSystem: 1))
    var keys: seq[TraceKeys]
    var data: seq[seq[float32]]
    for b in 0 ..< 4:
      var k = initTraceKeys()
      k.ensemble = float64(100 + b)
      k.cmpX = 500_000.25 + 12.5 * float64(b)
      k.cmpY = 6_100_000.5
      k.inline = 7
      k.crossline = float64(1 + b)
      k.offset = 0
      k.t0Ms = -12.5
      k.intervalUs = 1500.5
      k.time = 1_700_000_000.25
      k.status = if b == 2: tsDead else: tsLive
      var s = newSeq[float32](70_000)
      for j in 0 ..< s.len: s[j] = float32(b) + float32(j mod 97) * 0.5
      w.writeTrace(k, s, overrides = [headerOverride("trace.numHorzStacked", 10 + b)])
      keys.add k
      data.add s
    doAssert w.len == 4
    discard w.close()
    var g = openSeismic(dst, keys = true)
    doAssert g.len == 4
    doAssert g.index.segy.binary.traceSorting == 4
    doAssert g.index.segy.binary.measurementSystem == 1
    doAssert g.index.segy.binary.effectiveSamplesPerTrace == 70_000
    doAssert g.index.segy.binary.effectiveSampleInterval == 1500.5
    for b in 0 ..< 4:
      checkKeys(g.traceKeys(b), keys[b], 2)
      doAssert g.traceField(b, "trace.numHorzStacked").toFloat == float64(10 + b)
      doAssert int(g.traceEntry(b).numSamples) == 70_000
      let y = g.readTraces(b..b)
      for j in 0 ..< 70_000: doAssert y[0, j] == data[b][j]
    doAssert g.index.segy.text.card(1).contains("A STACK")
    g.close()

  block time_scalars:
    # t0 values the int16 delay holds only with a scalar, in Rev 1.
    let dst = tmp / "t0.sgy"
    var w = openSeismicWriter(dst, SegyOutputOptions(revision: SegyRevision(major: 1)))
    let t0s = [0.0, 4.0, -0.25, 1.125, 32767.0, 40000.0, -100_000.0]
    for t0 in t0s:
      var k = initTraceKeys()
      k.t0Ms = t0
      k.intervalUs = 2000
      w.writeTrace(k, [1'f32, 2, 3])
    discard w.close()
    var g = openSeismic(dst, keys = true)
    for i, t0 in t0s: doAssert g.traceKeys(i).t0Ms == t0
    doAssert g.traceKeys(0).status == tsUnknown
    g.close()
    # Float noise on a whole delay keeps the scalar 1 (readers that ignore
    # bytes 215-216 then read 4, not 4000).
    var w2 = openSeismicWriter(dst, SegyOutputOptions(revision: SegyRevision(major: 1)))
    var k2 = initTraceKeys()
    k2.t0Ms = 4.0000000001
    k2.intervalUs = 2000
    w2.writeTrace(k2, [1'f32])
    discard w2.close()
    var g2 = openSeismic(dst, keys = true)
    doAssert g2.traceField(0, "trace.timeScalar").toFloat == 1
    doAssert g2.traceField(0, "trace.delayRecordingTime").toFloat == 4
    doAssert g2.traceKeys(0).t0Ms == 4
    g2.close()

  block refused:
    var k = initTraceKeys()
    k.intervalUs = 2000
    doAssertRaises(ValueError):
      discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 1),
        format: st6))
    doAssertRaises(ValueError):
      discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 1),
        byteOrder: boLittle))
    doAssertRaises(ValueError):
      discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 3)))
    doAssertRaises(ValueError):
      discard openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(byteOrder: boPairSwapped,
        format: st7))
    var w = openSeismicWriter(tmp / "r.sgy", SegyOutputOptions(revision: SegyRevision(major: 1)))
    var bad = k
    bad.intervalUs = NaN
    doAssertRaises(ValueError): w.writeTrace(bad, [1'f32])
    bad.intervalUs = 0.5
    doAssertRaises(ValueError): w.writeTrace(bad, [1'f32]) # fractional before Rev 2
    bad.intervalUs = 70_000
    doAssertRaises(ValueError): w.writeTrace(bad, [1'f32]) # over 65535 µs before Rev 2
    doAssertRaises(ValueError): w.writeTrace(k, newSeq[float32](70_000)) # needs Ext1
    block rev0_delay:
      # Rev 0 has no time scalar: its delay is a whole ms in an int16. A start
      # time beyond that is refused, as an interval the revision cannot hold
      # is (it was written as 32767).
      var w0 = openSeismicWriter(tmp / "r0.sgy", SegyOutputOptions(revision: SegyRevision()))
      var late = k
      late.t0Ms = 40_000
      doAssertRaises(ValueError): w0.writeTrace(late, [1'f32])
      late.t0Ms = -32768.4
      doAssertRaises(ValueError): w0.writeTrace(late, [1'f32])
      late.t0Ms = 32767.4 # rounds into the field
      w0.writeTrace(late, [1'f32])
      # The midpoint has no Rev 0 field: bytes 181-188 stay unassigned, and
      # readers derive it from the source and receiver again.
      var mid = k
      (mid.srcX, mid.srcY, mid.rcvX, mid.rcvY) = (100.0, 200.0, 300.0, 400.0)
      (mid.cmpX, mid.cmpY) = (1234.0, 5678.0)
      w0.writeTrace(mid, [1'f32])
      discard w0.close()
      var g0 = openSeismic(tmp / "r0.sgy", keys = true)
      doAssert g0.traceKeys(0).t0Ms == 32767
      doAssert g0.traceKeys(1).cmpX == 200 and g0.traceKeys(1).cmpY == 300
      doAssert g0.traceField(1, "trace.cdpX").toFloat == 0
      g0.close()
    doAssertRaises(ValueError): w.writeTrace(k, [1'f32], [headerOverride("trace.nope", 1)])
    doAssert w.len == 0
    w.writeTrace(k, [1'f32])
    discard w.close()
    doAssertRaises(ValueError): w.writeTrace(k, [1'f32])
    # Keys into a SEG-D output are refused.
    var f = openSeismic(demoDir() / "record.sgd", keys = true)
    var v = openSeismicWriter(tmp / "r.sgd", like = f)
    doAssertRaises(ValueError): v.writeTrace(k, [1'f32])
    f.close()
    # Template traces into a writer from SegyOutputOptions: its binary header
    # is made for traces from keys (the interval would stay a placeholder).
    var sg = openSeismic(demoDir() / "survey.sgy")
    var fresh = openSeismicWriter(tmp / "t.sgy", SegyOutputOptions())
    doAssertRaises(ValueError): fresh.writeTrace(sg, 0, [1'f32])
    fresh.writeTrace(k, [1'f32])
    discard fresh.close()
    sg.close()
    # A writer dropped without close leaves no file.
    block:
      var d = openSeismicWriter(tmp / "dropped.sgy", SegyOutputOptions())
      d.writeTrace(k, [1'f32])
    doAssert not fileExists(tmp / "dropped.sgy")

  block status_wins_over_a_stale_code:
    # Keys read from SEG-Y (traceCode 1), then the trace killed: written dead.
    var f = openSeismic(demoDir() / "survey.sgy", keys = true)
    var k = f.traceKeys(0)
    doAssert k.traceCode == 1 and k.status == tsLive
    k.status = tsDead
    let dst = tmp / "killed.sgy"
    var w = openSeismicWriter(dst, SegyOutputOptions(revision: SegyRevision(major: 1)))
    w.writeTrace(k, [1'f32, 2])
    k.status = tsLive
    w.writeTrace(k, [1'f32, 2]) # agrees: the code is kept
    discard w.close()
    var g = openSeismic(dst, keys = true)
    doAssert g.traceKeys(0).status == tsDead and g.traceKeys(0).traceCode == 2
    doAssert g.traceKeys(1).status == tsLive and g.traceKeys(1).traceCode == 1
    g.close()
    f.close()

  block like_segy_input:
    # Keys traces into a writer `like` a SEG-Y file (no Layout stanza).
    var f = openSeismic(demoDir() / "survey.sgy", keys = true)
    let dst = tmp / "like.sgy"
    var w = openSeismicWriter(dst, like = f)
    var k = initTraceKeys()
    k.ensemble = 42
    k.t0Ms = 0
    k.intervalUs = f.traceKeys(0).intervalUs
    let n = int(f.traceEntry(0).numSamples)
    w.writeTrace(k, newSeq[float32](n))
    discard w.close()
    var g = openSeismic(dst, keys = true)
    doAssert g.len == 1 and int(g.traceEntry(0).numSamples) == n
    g.close()
    f.close()

  block like_a_rev0_input_whose_traces_leave_their_count_to_the_binary_header:
    # The reader takes the binary header's count for a Rev 0 trace that gives
    # 0 samples; written like it, each trace must say its own.
    let src = tmp / "rev0_ns0.sgy"
    block:
      var w = openSeismicWriter(src, SegyOutputOptions(revision: SegyRevision(major: 0, minor: 0)))
      var k = initTraceKeys()
      k.intervalUs = 2000
      var x = newSeq[float32](100)
      for i in 0 ..< 100: x[i] = float32(i)
      for t in 0 ..< 3: w.writeTrace(k, x)
      discard w.close()
    var b = readFile(src)
    for t in 0 ..< 3: (b[3600 + t * 640 + 114], b[3600 + t * 640 + 115]) = ('\0', '\0')
    writeFile(src, b)
    var f = openSeismic(src)
    doAssert f.len == 3 and f.maxSamples == 100
    let x = f.readTraces(0 ..< f.len)
    let dst = tmp / "rev0_ns0_like.sgy"
    var w = openSeismicWriter(dst, like = f)
    for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
    discard w.close()
    var g = openSeismic(dst)
    doAssert g.len == 3 and g.maxSamples == 100 and g.readTraces(0 ..< g.len) == x
    doAssert g.traceField(2, "trace.numSamples").toFloat == 100
    g.close()
    f.close()

  block whole_intervals_with_float_noise:
    # An interval kept in ms and handed back as ms × 1000 is not always the
    # whole number it was: 1001 µs comes back as 1000.9999999999999, as do
    # 1471 other values up to 65535. They are written as the whole numbers.
    for rev in [SegyRevision(major: 0, minor: 0), SegyRevision(major: 1, minor: 0),
        SegyRevision(major: 2, minor: 1)]:
      let dst = tmp / ("noise_r" & $rev.major & ".sgy")
      var w = openSeismicWriter(dst, SegyOutputOptions(revision: rev))
      var k = initTraceKeys()
      var noisy: seq[int]
      for us in 1 .. 65535:
        k.intervalUs = (float64(us) / 1000) * 1000
        if k.intervalUs != float64(us):
          noisy.add us
          w.writeTrace(k, [0'f32])
      doAssert noisy.len > 1000 and noisy[0] == 1001
      discard w.close()
      var g = openSeismic(dst, keys = true)
      doAssert g.len == noisy.len
      doAssert g.fileField("binary.sampleInterval").toFloat == 1001
      for i, us in noisy:
        doAssert g.traceKeys(i).intervalUs == float64(us), $rev & ": " & $us
        doAssert g.traceField(i, "trace.sampleInterval").toFloat == float64(us)
      g.close()
    # An interval that really has a fraction is another matter.
    var k = initTraceKeys()
    k.intervalUs = 1000.999
    var w1 = openSeismicWriter(tmp / "frac_r1.sgy",
      SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0)))
    doAssertRaises(ValueError): w1.writeTrace(k, [0'f32])
    var w2 = openSeismicWriter(tmp / "frac_r2.sgy", SegyOutputOptions())
    w2.writeTrace(k, [0'f32])
    discard w2.close()
    var g = openSeismic(tmp / "frac_r2.sgy", keys = true)
    doAssert g.traceKeys(0).intervalUs == 1000.999
    g.close()

  # Seen to fail first: checkTextHeader returned no problems.
  block check_text_header:
    let rev0 = SegyRevision()
    let rev1 = SegyRevision(major: 1)
    let rev20 = SegyRevision(major: 2, minor: 0)
    let rev21 = SegyRevision(major: 2, minor: 1)
    var many = newSeq[string](41)
    many[0] = "\x01" & 'y'.repeat(80)
    let all = checkTextHeader(many, rev1, teAscii)
    var kinds: set[TextHeaderFault]
    for p in all: kinds.incl p.kind
    doAssert thfTooManyLines in kinds and thfLineTooLong in kinds
    doAssert thfBadCharacter in kinds and thfRevisionCard in kinds
    doAssert thfEndMarker in kinds
    doAssert all[0].kind == thfTooManyLines and all[0].line == 41
    doAssert "41" in all[0].message
    let long = checkTextHeader(@['x'.repeat(81)], rev0, teAscii)
    doAssert long.len == 1 and long[0].kind == thfLineTooLong and long[0].line == 1
    doAssert "81" in long[0].message
    let bad = checkTextHeader(@["ok\x01"], rev0, teAscii)
    doAssert bad.len == 1 and bad[0].kind == thfBadCharacter and bad[0].line == 1
    doAssert bad[0].message.contains("column 3")
    doAssert checkTextHeader(@["ok\x01"], rev0, teEbcdic).len == 0
    let missing = checkTextHeader(@["hello"], rev1, teAscii)
    doAssert missing.len == 2
    doAssert missing[0].kind == thfRevisionCard and missing[0].line == 39
    doAssert missing[1].kind == thfEndMarker and missing[1].line == 40
    var ok = newSeq[string](40)
    ok[38] = "SEG Y REV1"
    ok[39] = "END EBCDIC"
    doAssert checkTextHeader(ok, rev1, teEbcdic).len == 0
    ok[39] = "C40 END TEXTUAL HEADER"
    doAssert checkTextHeader(ok, rev1, teEbcdic).len == 0
    ok[38] = "C39 SEG Y REV1"
    doAssert checkTextHeader(ok, rev1, teAscii).len == 0
    ok[38] = "SEG-Y_REV2.0"
    doAssert checkTextHeader(ok, rev20, teEbcdic).len == 0
    ok[38] = "SEG-Y_REV2.1"
    doAssert checkTextHeader(ok, rev21, teEbcdic).len == 0
    ok[38] = "SEG Y REV1"
    let wrong = checkTextHeader(ok, rev21, teEbcdic)
    doAssert wrong.len == 1 and wrong[0].kind == thfRevisionCard
    doAssert checkTextHeader(newSeq[string](40), rev0, teEbcdic).len == 0
    var srcLines = @["hello"]
    discard checkTextHeader(srcLines, rev1, teAscii)
    doAssert srcLines == @["hello"]
    discard checkTextHeader(@["\x00".repeat(100)], rev21, teAscii)

  # Seen to fail first: checkTextHeader reported no thfReadBack (the read-back
  # check was absent, so both misread headers came back clean).
  block check_text_readback:
    let rev0 = SegyRevision()
    let label = @[
      "1   SY rest of card one",
      repeat(' ', 48) & "C and more"]
    let asLabel = checkTextHeader(label, rev0, teAscii)
    doAssert asLabel.len == 1, $asLabel.len
    doAssert asLabel[0].kind == thfReadBack and asLabel[0].line == 1
    doAssert "tape label" in asLabel[0].message, asLabel[0].message
    doAssert asLabel[0].message == "line 1 should start with C: as written, " &
      "this header would be taken for a tape label"
    let asAscii = checkTextHeader(@["\xE4 and more"], rev0, teEbcdic)
    doAssert asAscii.len == 1, $asAscii.len
    doAssert asAscii[0].kind == thfReadBack and asAscii[0].line == 1
    doAssert asAscii[0].message == "line 1 should start with C: as written, " &
      "this header would be read back as ASCII", asAscii[0].message
    doAssert checkTextHeader(@["C 1 client"], rev0, teAscii).len == 0
    doAssert checkTextHeader(@["C 1 client"], rev0, teEbcdic).len == 0
    doAssert checkTextHeader(@["Hello free text"], rev0, teAscii).len == 0
    doAssert checkTextHeader(@["Hello free text"], rev0, teEbcdic).len == 0
    let longLabel = @[
      "1   SY " & 'x'.repeat(80),
      repeat(' ', 48) & "C and more"]
    for p in checkTextHeader(longLabel, rev0, teAscii):
      doAssert p.kind != thfReadBack
    let rev1 = checkTextHeader(@["C 1 client"], SegyRevision(major: 1), teAscii)
    doAssert rev1.len == 2
    for p in rev1: doAssert p.kind != thfReadBack

  # Seen to fail first: textFault returned "" so an over-long fullText did
  # not raise, and fillFullText did not store the lines (byte 0 differed).
  block full_textual_header:
    proc linesOf(rev: SegyRevision): seq[string] =
      result = newSeq[string](40)
      for i in 0 ..< 38:
        result[i] = align($(i + 1), 2, '0') & ":" &
          repeat(char(ord('A') + (i mod 26)), 77)
      let name = if rev.major >= 2: "SEG-Y_REV" & $rev
        elif rev.major == 1: "SEG Y REV1" else: "REV0 CARD"
      result[38] = cardPrefix(39) & name
      result[39] = cardPrefix(40) & "END TEXTUAL HEADER"
    for rev in [SegyRevision(major: 2, minor: 1), SegyRevision(major: 1),
        SegyRevision(major: 2, minor: 0)]:
      for encoding in [teEbcdic, teAscii]:
        let dst = tmp / ("full_" & $rev.major & "_" & $encoding & ".sgy")
        let lines = linesOf(rev)
        writeOne(dst, SegyOutputOptions(revision: rev, textEncoding: encoding,
          text: @["SHOULD NOT APPEAR"], fullText: lines))
        sameHeader(dst, lines, encoding)
        reopenHeader(dst, lines, encoding)
        let src = tmp / ("src_" & $rev.major & "_" & $encoding & ".sgy")
        writeOne(src, SegyOutputOptions(revision: rev, textEncoding: encoding,
          text: @["SOURCE HEADER"]))
        var f = openSeismic(src)
        let likeDst = tmp / ("like_" & $rev.major & "_" & $encoding & ".sgy")
        var w = openSeismicWriter(likeDst, like = f, fullText = lines)
        w.writeTrace(f, 0, [1'f32, 2, 3])
        discard w.close()
        f.close()
        sameHeader(likeDst, lines, encoding)
        reopenHeader(likeDst, lines, encoding)
    let untouched = newSeq[string](40)
    var custom = untouched
    custom[0] = "HI"
    custom[38] = "NOT THE REVISION"
    custom[39] = "NOT AN END"
    let raw = tmp / "untouched.sgy"
    writeOne(raw, SegyOutputOptions(fullText: custom, fixCards: false,
      text: @["SHOULD NOT APPEAR"]))
    sameHeader(raw, custom, teEbcdic)
    reopenHeader(raw, custom, teEbcdic)
    let fixed = tmp / "fixedcards.sgy"
    writeOne(fixed, SegyOutputOptions(revision: SegyRevision(major: 1),
      fullText: custom, fixCards: true))
    var g = openSeismic(fixed)
    doAssert g.index.segy.text.card(1).startsWith("HI")
    doAssert "SEG Y REV1" in g.index.segy.text.card(39)
    doAssert "END TEXTUAL HEADER" in g.index.segy.text.card(40)
    g.close()
    var fixedLines = custom
    fixedLines[38] = cardPrefix(39) & "SEG Y REV1"
    fixedLines[39] = cardPrefix(40) & "END TEXTUAL HEADER"
    reopenHeader(fixed, fixedLines, teEbcdic)
    let plain = tmp / "plain.sgy"
    writeOne(plain, SegyOutputOptions(text: @["A STACK", "LINE 7"]))
    var h = initTextHeader(teEbcdic)
    h.setCard(1, cardPrefix(1) & "A STACK")
    h.setCard(2, cardPrefix(2) & "LINE 7")
    h.setCard(39, cardPrefix(39) & "SEG-Y_REV2.1")
    h.setCard(40, cardPrefix(40) & "END TEXTUAL HEADER")
    let got = readFile(plain)
    for i in 0 ..< 3200: doAssert byte(got[i]) == h.data[i]
    var gp = openSeismic(plain)
    doAssert gp.index.segy.text.encoding == teEbcdic
    for n in 1 .. 40:
      doAssert gp.index.segy.text.card(n) == h.card(n), "plain card " & $n
    gp.close()
    var srcf = openSeismic(plain)
    let copied = tmp / "copied.sgy"
    var lw = openSeismicWriter(copied, like = srcf)
    lw.writeTrace(srcf, 0, [1'f32, 2, 3])
    discard lw.close()
    srcf.close()
    doAssert readFile(plain)[0 ..< 3200] == readFile(copied)[0 ..< 3200]
    var gc = openSeismic(copied)
    doAssert gc.index.segy.text.encoding == teEbcdic
    for n in 1 .. 40:
      doAssert gc.index.segy.text.card(n) == h.card(n), "copied card " & $n
    gc.close()
    let over = tmp / "overlong.sgy"
    let n = fileCount(tmp)
    var raised = false
    try:
      discard openSeismicWriter(over, SegyOutputOptions(fullText: @['x'.repeat(81)]))
    except ValueError as e:
      raised = true
      doAssert "81" in e.msg, e.msg
    doAssert raised
    doAssert not fileExists(over)
    doAssert fileCount(tmp) == n
    for kind, p in walkDir(tmp):
      doAssert not p.endsWith(".tmp"), p
    var badRaised = false
    try:
      discard openSeismicWriter(tmp / "badchar.sgy", SegyOutputOptions(
        textEncoding: teAscii, fullText: @["ok\x01"]))
    except ValueError as e:
      badRaised = true
      doAssert "cannot encode" in e.msg, e.msg
    doAssert badRaised and not fileExists(tmp / "badchar.sgy")
    var sd = openSeismic(demoDir() / "record.sgd")
    var segdRaised = false
    try:
      discard openSeismicWriter(tmp / "notsegy.sgy", like = sd, fullText = @["X"])
    except ValueError as e:
      segdRaised = true
      doAssert "SEG-Y" in e.msg, e.msg
    doAssert segdRaised and not fileExists(tmp / "notsegy.sgy")
    sd.close()

  # Seen to fail first: textFault ignored thfReadBack, so a misread header
  # was opened instead of raising ValueError before any file existed.
  block full_text_readback:
    let label = @["1   SY rest of card one", repeat(' ', 48) & "C and more"]
    let umlaut = @["\xE4 and more"]
    proc noFile(path: string, msgPart: string, openIt: proc () {.closure.}) =
      let n = fileCount(tmp)
      var raised = false
      try:
        openIt()
      except ValueError as e:
        raised = true
        doAssert msgPart in e.msg, e.msg
      doAssert raised, path
      doAssert not fileExists(path), path
      doAssert fileCount(tmp) == n, path
      for kind, p in walkDir(tmp):
        doAssert not p.endsWith(".tmp"), p
    let labelPath = tmp / "label_ascii.sgy"
    noFile(labelPath, "tape label", proc () =
      discard openSeismicWriter(labelPath, SegyOutputOptions(
        textEncoding: teAscii, fullText: label, fixCards: false)))
    let labelFix = tmp / "label_ascii_fix.sgy"
    noFile(labelFix, "tape label", proc () =
      discard openSeismicWriter(labelFix, SegyOutputOptions(
        textEncoding: teAscii, fullText: label, fixCards: true)))
    let umlautPath = tmp / "umlaut.sgy"
    noFile(umlautPath, "ASCII", proc () =
      discard openSeismicWriter(umlautPath, SegyOutputOptions(
        textEncoding: teEbcdic, fullText: umlaut, fixCards: false)))
    let umlautFix = tmp / "umlaut_fix.sgy"
    noFile(umlautFix, "ASCII", proc () =
      discard openSeismicWriter(umlautFix, SegyOutputOptions(
        textEncoding: teEbcdic, fullText: umlaut, fixCards: true)))
    let beforeMem = fileCount(tmp)
    noFile(tmp / "mem_label_unused.sgy", "tape label", proc () =
      discard openSeismicWriterBytes(SegyOutputOptions(
        textEncoding: teAscii, fullText: label, fixCards: true)))
    noFile(tmp / "mem_umlaut_unused.sgy", "ASCII", proc () =
      discard openSeismicWriterBytes(SegyOutputOptions(
        textEncoding: teEbcdic, fullText: umlaut, fixCards: false)))
    doAssert fileCount(tmp) == beforeMem
    let srcA = tmp / "src_ascii_rb.sgy"
    writeOne(srcA, SegyOutputOptions(textEncoding: teAscii, text: @["SOURCE"]))
    let srcE = tmp / "src_ebcdic_rb.sgy"
    writeOne(srcE, SegyOutputOptions(textEncoding: teEbcdic, text: @["SOURCE"]))
    var fa = openSeismic(srcA)
    let likeLabel = tmp / "like_label.sgy"
    noFile(likeLabel, "tape label", proc () =
      discard openSeismicWriter(likeLabel, like = fa, fullText = label, fixCards = true))
    noFile(tmp / "like_mem_label_unused.sgy", "tape label", proc () =
      discard openSeismicWriterBytes(fa, fullText = label, fixCards = false))
    fa.close()
    var fe = openSeismic(srcE)
    let likeUmlaut = tmp / "like_umlaut.sgy"
    noFile(likeUmlaut, "ASCII", proc () =
      discard openSeismicWriter(likeUmlaut, like = fe, fullText = umlaut, fixCards = false))
    noFile(tmp / "like_mem_umlaut_unused.sgy", "ASCII", proc () =
      discard openSeismicWriterBytes(fe, fullText = umlaut, fixCards = true))
    fe.close()

when isMainModule: main()
