## `openSeismicWriter(..., like, segyRevision)` writes the source headers as
## another SEG-Y revision, by the same rules as `convertSegy`. Synthetic files.
## Seen failing with `segyRevOn` forced false: the output kept Rev 0.0.
## Seen failing before the card-39 warning: `revisionNotes` was empty.

import std/[assertions, options, os, strutils]

import parseSEG

import ./utils/testutils

var tmp: typeof(scratchDir("parseseg_twritelikerev"))

func rev(major: int, minor = 0): SegyRevision =
  SegyRevision(major: uint8(major), minor: uint8(minor))

proc baseKeys(): TraceKeys =
  result = initTraceKeys()
  result.record = 7
  result.srcPoint = 12
  (result.srcX, result.srcY) = (500000.0, 6000000.0)
  (result.rcvX, result.rcvY) = (500100.0, 6000200.0)
  result.offset = 224
  result.t0Ms = 100
  result.intervalUs = 2000
  result.status = tsLive

proc keysFile(name: string, r: SegyRevision, k: TraceKeys, traces = 3, ns = 100): string =
  result = tmp / name
  var w = openSeismicWriter(result, SegyOutputOptions(revision: r))
  var x = newSeq[float32](ns)
  for i in 0 ..< ns: x[i] = float32(i)
  var kk = k
  for t in 0 ..< traces:
    kk.channel = float64(t + 1)
    w.writeTrace(kk, x)
  discard w.close()

proc fixedRev2(name: string, ns: int): string =
  ## One fixed-length Rev 2.1 trace whose count lives only in the extended field.
  result = tmp / name
  var f = SegyFile(byteOrder: boBig, format: some(sfFloat32), revision: rev(2, 1),
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(teEbcdic))
  f.text.setCard(39, "C39 SEG-Y_REV2.1")
  f.text.setCard(40, "C40 END TEXTUAL HEADER")
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 2, segyMinor: 1,
    samplesPerTrace: 0, extSamplesPerTrace: uint32(ns), sampleInterval: 2000,
    fixedLengthTraces: 1, byteOrderMarker: ByteOrderMarker)
  let sink = openDiskSink(result)
  var w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: boBig, lenient: true))
  var x = newSeq[float32](ns)
  for i in 0 ..< ns: x[i] = float32(i mod 1000)
  var tr = SegyTrace(index: 0, numSamples: ns)
  tr.header = SegyTraceHeader(traceSeqLine: 1, fieldRecord: 1, traceNumberInField: 1,
    traceIdCode: 1, numSamples: 0, sampleInterval: 2000)
  tr.samples = newSeq[byte](4 * ns)
  encodeSamples(sfFloat32, x, tr.samples, boBig)
  w.writeTrace(tr)
  w.close()
  sink.close()

proc differences(a, b: TraceKeys): string =
  for name, x, y in fieldPairs(a, b):
    when name == "traceCodeRev": discard
    elif x is float64:
      if not ((x.isNaN and y.isNaN) or x == y): result.add name & " " & $x & " -> " & $y & "; "
    else:
      if x != y: result.add name & " " & $x & " -> " & $y & "; "

proc keysOf(path: string): seq[TraceKeys] =
  var f = openSeismic(path, keys = true)
  doAssert not f.log.isFatal, path & ": " & $f.log
  for i in 0 ..< f.len: result.add f.traceKeys(i)
  f.close()

proc newSamples(n: int): seq[float32] =
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = float32(1000 + i)

proc cardFile(name, card39: string): string =
  ## One short fixed-length Rev 2.1 trace whose card 39 is `card39`.
  result = tmp / name
  var f = SegyFile(byteOrder: boBig, format: some(sfFloat32), revision: rev(2, 1),
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(teEbcdic))
  f.text.setCard(39, card39)
  f.text.setCard(40, "C40 END TEXTUAL HEADER")
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 2, segyMinor: 1,
    samplesPerTrace: 8, sampleInterval: 2000, fixedLengthTraces: 1,
    byteOrderMarker: ByteOrderMarker)
  let sink = openDiskSink(result)
  var w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: boBig, lenient: true))
  var x = newSeq[float32](8)
  for i in 0 ..< 8: x[i] = float32(i)
  var tr = SegyTrace(index: 0, numSamples: 8)
  tr.header = SegyTraceHeader(traceSeqLine: 1, fieldRecord: 1, traceNumberInField: 1,
    traceIdCode: 1, numSamples: 8, sampleInterval: 2000)
  tr.samples = newSeq[byte](32)
  encodeSamples(sfFloat32, x, tr.samples, boBig)
  w.writeTrace(tr)
  w.close()
  sink.close()

proc writeLike(src, dst: string, samples: seq[float32], revision: Option[SegyRevision]) =
  var f = openSeismic(src)
  var w = openSeismicWriter(dst, like = f, segyRevision = revision)
  for i in 0 ..< f.len: w.writeTrace(f, i, samples)
  discard w.close()
  f.close()

proc headersEqual(a, b: string): bool =
  ## File headers, and each trace's header bytes, not the samples.
  var fa = openSeismic(a)
  var fb = openSeismic(b)
  if fa.len != fb.len or fa.len == 0:
    fa.close()
    fb.close()
    return false
  let aa = readFile(a)
  let bb = readFile(b)
  let endA = int(fa.traceEntry(0).offset)
  let endB = int(fb.traceEntry(0).offset)
  result = endA == endB and aa[0 ..< endA] == bb[0 ..< endB]
  if result:
    for i in 0 ..< fa.len:
      let ea = fa.traceEntry(i)
      let eb = fb.traceEntry(i)
      let n = int(ea.headerBytes)
      if n != int(eb.headerBytes) or
          aa[int(ea.offset) ..< int(ea.offset) + n] != bb[int(eb.offset) ..< int(eb.offset) + n]:
        result = false
        break
  fa.close()
  fb.close()

proc expectRefuse(body: proc(), outPath, part: string) =
  var raised = false
  try: body()
  except ValueError as e:
    raised = true
    doAssert part in e.msg, e.msg
  doAssert raised, "expected ValueError containing " & part
  if outPath.len > 0: doAssert not fileExists(outPath), outPath & " was created"

proc main*() =
  tmp = scratchDir("parseseg_twritelikerev")
  let revisions = [rev(0), rev(1), rev(2, 0), rev(2, 1)]
  var sources: array[4, string]
  for i, r in revisions: sources[i] = keysFile("src_" & $r.major & "_" & $r.minor & ".sgy", r,
    baseKeys())

  block rewritten_headers_match_convertSegy:
    let samples = newSamples(100)
    for si, srcRev in revisions:
      for dstRev in revisions:
        if dstRev == srcRev: continue
        let (conv, clog) = (tmp / "conv.sgy",
          convertFile(sources[si], tmp / "conv.sgy", ConvertOptions(revision: dstRev)))
        doAssert not clog.isFatal, $srcRev & " -> " & $dstRev & ": " & $clog
        let dst = tmp / "like.sgy"
        var f = openSeismic(sources[si])
        var w = openSeismicWriter(dst, like = f, segyRevision = some(dstRev))
        for i in 0 ..< f.len: w.writeTrace(f, i, samples)
        discard w.close()
        f.close()
        var got = openSeismic(dst)
        doAssert got.index.segy.revision == dstRev, $srcRev & " -> " & $dstRev
        doAssert got.len == 3
        got.close()
        let wantKeys = keysOf(conv)
        let gotKeys = keysOf(dst)
        for i in 0 ..< 3:
          doAssert differences(wantKeys[i], gotKeys[i]).len == 0,
            $srcRev & " -> " & $dstRev & ": " & differences(wantKeys[i], gotKeys[i])
        doAssert headersEqual(conv, dst), $srcRev & " -> " & $dstRev & " header bytes differ"
        var written = openSeismic(dst)
        let back = written.readTraces(0 ..< written.len)
        written.close()
        doAssert back.shape == [3, 100]
        for t in 0 ..< 3:
          for j in 0 ..< 100: doAssert back[t, j] == samples[j]

  block none_and_same_revision_are_byte_identical:
    let samples = newSamples(100)
    let src = sources[3] # Rev 2.1
    let plain = tmp / "plain.sgy"
    var f = openSeismic(src)
    var w = openSeismicWriter(plain, like = f)
    for i in 0 ..< f.len: w.writeTrace(f, i, samples)
    discard w.close()
    f.close()
    let noneOut = tmp / "none.sgy"
    writeLike(src, noneOut, samples, none(SegyRevision))
    doAssert readFile(plain) == readFile(noneOut)
    let sameOut = tmp / "same.sgy"
    writeLike(src, sameOut, samples, some(rev(2, 1)))
    doAssert readFile(plain) == readFile(sameOut)
    var g = openSeismic(src)
    var ww = openSeismicWriter(tmp / "notes.sgy", like = g, segyRevision = none(SegyRevision))
    doAssert ww.revisionNotes.len == 0
    discard ww.close()
    g.close()

  block refusals_leave_no_file:
    var f = openSeismic(sources[3])
    let refused = tmp / "refused.sgy"
    expectRefuse(proc() = discard openSeismicWriter(refused, like = f,
      segyRevision = some(SegyRevision(major: 3, minor: 0))), refused, "not 0, 1, 2.0 or 2.1")
    expectRefuse(proc() = discard openSeismicWriter(refused, like = f, segyFormat = st6,
      segyRevision = some(rev(1))), refused, "needs SEG-Y Rev 2")
    f.close()
    let le = tmp / "little.sgy"
    var lw = openSeismicWriter(le, SegyOutputOptions(revision: rev(2, 1), byteOrder: boLittle))
    lw.writeTrace(baseKeys(), newSamples(8))
    discard lw.close()
    var lf = openSeismic(le)
    expectRefuse(proc() =
      discard openSeismicWriter(refused, like = lf, segyRevision = some(rev(1))),
      refused, "little-endian and pair-swapped")
    lf.close()
    let segd = demoDir() / "shot.sgd"
    var sd = openSeismic(segd)
    expectRefuse(proc() =
      discard openSeismicWriter(refused, like = sd, segyRevision = some(rev(1))),
      refused, "segyRevision")
    expectRefuse(proc() = discard openSeismicWriterBytes(like = sd, segyRevision = some(rev(1))),
      "", "segyRevision")
    sd.close()

  block memory_writer_matches_the_file:
    let samples = newSamples(100)
    var f = openSeismic(sources[3])
    var mem = openSeismicWriterBytes(like = f, segyRevision = some(rev(1)))
    for i in 0 ..< f.len: mem.writeTrace(f, i, samples)
    let bytes = mem.finishBytes()
    f.close()
    let path = tmp / "mem.sgy"
    writeFile(path, bytes)
    let fileOut = tmp / "file.sgy"
    writeLike(sources[3], fileOut, samples, some(rev(1)))
    doAssert readFile(path) == readFile(fileOut)
    var got = openSeismic(path)
    doAssert got.index.segy.revision == rev(1) and got.len == 3
    got.close()

  block ext1_drop_is_noted_once_and_not_in_close:
    var f = openSeismic(sources[3])
    var w = openSeismicWriter(tmp / "ext1.sgy", like = f, segyRevision = some(rev(1)))
    for i in 0 ..< f.len: w.writeTrace(f, i, newSamples(100))
    var n = 0
    for d in w.revisionNotes:
      if "Trace Header Extension 1" in d.msg: inc n
    doAssert n == 1, $w.revisionNotes
    let closed = w.close()
    doAssert not closed.has("Trace Header Extension 1", sevInfo), $closed
    f.close()

  block a_variable_length_trace_that_does_not_fit_is_skipped:
    let src = keysFile("long_var.sgy", rev(2, 1), baseKeys(), traces = 2, ns = 70000)
    var f = openSeismic(src)
    let dst = tmp / "skipped.sgy"
    var w = openSeismicWriter(dst, like = f, segyRevision = some(rev(1)))
    for i in 0 ..< f.len: w.writeTrace(f, i, newSamples(70000))
    doAssert w.len == 0
    doAssert w.revisionNotes.has("70000 samples, which Rev 1 cannot hold", sevError),
      $w.revisionNotes
    discard w.close()
    f.close()
    var g = openSeismic(dst)
    doAssert g.len == 0
    g.close()

  block a_fixed_length_count_the_target_cannot_hold_is_refused:
    let src = fixedRev2("long_fixed.sgy", 70000)
    var f = openSeismic(src)
    doAssert f.len == 1 and f.maxSamples == 70000
    let dst = tmp / "fixed_refused.sgy"
    expectRefuse(proc() = discard openSeismicWriter(dst, like = f, segyRevision = some(rev(1))),
      dst, "70000 samples per trace need Rev 2")
    f.close()

  block fullText_cards_name_the_target_revision:
    var f = openSeismic(sources[3])
    var lines = newSeq[string](40)
    for i in 0 ..< 40: lines[i] = "line " & $(i + 1)
    let dst = tmp / "cards.sgy"
    var w = openSeismicWriter(dst, like = f, fullText = lines, segyRevision = some(rev(1)))
    w.writeTrace(f, 0, newSamples(100))
    discard w.close()
    f.close()
    let d = readSegy(dst)
    doAssert d.file.text.card(39).strip == "C39 SEG Y REV1", d.file.text.card(39)
    doAssert d.file.text.card(40).strip == "C40 END TEXTUAL HEADER"

  block a_custom_card_39_is_replaced_and_reported:
    let src = cardFile("custom39.sgy", "C39 CUSTOM REV TEXT HERE")
    var f = openSeismic(src)
    let dst = tmp / "custom39_out.sgy"
    var w = openSeismicWriter(dst, like = f, segyRevision = some(rev(1)))
    w.writeTrace(f, 0, newSamples(8))
    doAssert w.revisionNotes.has("CUSTOM REV TEXT HERE", sevWarning), $w.revisionNotes
    discard w.close()
    f.close()
    var g = openSeismic(dst)
    doAssert g.index.segy.text.card(39).strip == "C39 SEG Y REV1", g.index.segy.text.card(39)
    g.close()

  block a_standard_card_39_is_replaced_without_a_report:
    let src = cardFile("std39.sgy", "C39 SEG-Y_REV2.1")
    var f = openSeismic(src)
    let dst = tmp / "std39_out.sgy"
    var w = openSeismicWriter(dst, like = f, segyRevision = some(rev(1)))
    w.writeTrace(f, 0, newSamples(8))
    doAssert not w.revisionNotes.has("card 39 held", sevWarning), $w.revisionNotes
    discard w.close()
    f.close()
    var g = openSeismic(dst)
    doAssert g.index.segy.text.card(39).strip == "C39 SEG Y REV1", g.index.segy.text.card(39)
    g.close()

  block a_blank_card_39_is_replaced_without_a_report:
    let src = cardFile("blank39.sgy", "C39 ")
    var f = openSeismic(src)
    let dst = tmp / "blank39_out.sgy"
    var w = openSeismicWriter(dst, like = f, segyRevision = some(rev(1)))
    w.writeTrace(f, 0, newSamples(8))
    doAssert not w.revisionNotes.has("card 39 held", sevWarning), $w.revisionNotes
    discard w.close()
    f.close()
    var g = openSeismic(dst)
    doAssert g.index.segy.text.card(39).strip == "C39 SEG Y REV1", g.index.segy.text.card(39)
    g.close()

when isMainModule: main()
