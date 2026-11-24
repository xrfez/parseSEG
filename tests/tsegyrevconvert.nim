## SEG-Y to SEG-Y with a new revision (`convertSegy`): the header bytes
## whose meaning the revision changes are rewritten, and what the target
## cannot hold is reported. Synthetic files, written by the library.
## Seen failing before the card-39 warning: a custom card was replaced and
## the log had no warning quoting it.
## Seen failing before the written-count patch: `convertSegy` bytes differed
## from the `like:` writer (the source trace count was left in place).

import std/[assertions, math, options, os, strutils]

import parseSEG

import ./utils/testutils

var tmp: typeof(scratchDir("parseseg_tsegyrevconvert"))

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
  ## A file of `traces` traces of `ns` samples with keys `k` and channels 1, 2, ...
  result = tmp / name
  var w = openSeismicWriter(result, SegyOutputOptions(revision: r))
  var x = newSeq[float32](ns)
  for i in 0 ..< ns: x[i] = float32(i)
  var kk = k
  for t in 0 ..< traces:
    kk.channel = float64(t + 1)
    w.writeTrace(kk, x)
  discard w.close()

proc convertTo(src: string, r: SegyRevision, name = ""): (string, DiagLog) =
  let dst = if name.len > 0: tmp / name else: src & ".to" & $r.major & $r.minor & ".sgy"
  (dst, convertFile(src, dst, ConvertOptions(revision: r)))

proc keysOf(path: string): seq[TraceKeys] =
  var f = openSeismic(path, keys = true)
  doAssert not f.log.isFatal, path & ": " & $f.log
  for i in 0 ..< f.len: result.add f.traceKeys(i)
  f.close()

proc differences(a, b: TraceKeys): string =
  ## The fields in which `a` and `b` differ (NaN equals NaN), apart from the
  ## revision the trace code is numbered in (it is the file's).
  for name, x, y in fieldPairs(a, b):
    when name == "traceCodeRev": discard
    elif x is float64:
      if not ((x.isNaN and y.isNaN) or x == y): result.add name & " " & $x & " -> " & $y & "; "
    else:
      if x != y: result.add name & " " & $x & " -> " & $y & "; "

proc sameSamples(a, b: string): bool =
  var f = openSeismic(a)
  var g = openSeismic(b)
  result = f.len == g.len and f.readTraces(0 ..< f.len) == g.readTraces(0 ..< g.len)
  f.close()
  g.close()

proc traceBytes(path: string, trace, first, last: int): string =
  ## Spec bytes `first..last` of the standard header of trace `trace`.
  var f = openSeismic(path)
  let at = f.traceEntry(trace).offset
  f.close()
  readFile(path)[int(at) + first - 1 .. int(at) + last - 1]

func allZero(s: string): bool =
  for c in s:
    if c != '\0': return false
  true

proc rev2File(name: string, ns: int, fixed: bool, binNs: uint16, binExtNs: uint32,
    dtUs: float64): string =
  ## A Rev 2.1 big-endian float32 file of 3 traces without Trace Header
  ## Extension 1, with the given binary header counts.
  result = tmp / name
  var f = SegyFile(byteOrder: boBig, format: some(sfFloat32), revision: rev(2, 1),
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(teEbcdic))
  f.text.setCard(39, "C39 SEG-Y_REV2.1")
  f.text.setCard(40, "C40 END TEXTUAL HEADER")
  let whole = dtUs == round(dtUs) and dtUs <= 65535
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 2, segyMinor: 1,
    samplesPerTrace: binNs, extSamplesPerTrace: binExtNs,
    sampleInterval: (if whole: uint16(dtUs) else: 0),
    extSampleInterval: (if whole: 0.0 else: dtUs),
    fixedLengthTraces: (if fixed: 1 else: 0), byteOrderMarker: ByteOrderMarker)
  let sink = openDiskSink(result)
  var w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: boBig, lenient: true))
  var x = newSeq[float32](ns)
  for i in 0 ..< ns: x[i] = float32(i mod 1000)
  for t in 0 ..< 3:
    var tr = SegyTrace(index: t, numSamples: ns)
    tr.header = SegyTraceHeader(traceSeqLine: int32(t + 1), fieldRecord: 1,
      traceNumberInField: int32(t + 1), traceIdCode: 1,
      numSamples: (if ns > 65535: 0'u16 else: uint16(ns)),
      sampleInterval: (if whole: uint16(dtUs) else: 0))
    tr.samples = newSeq[byte](4 * ns)
    encodeSamples(sfFloat32, x, tr.samples, boBig)
    w.writeTrace(tr)
  w.close()
  sink.close()

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

proc card39Of(path: string): string =
  var g = openSeismic(path)
  result = g.index.segy.text.card(39)
  g.close()

proc varFile(name: string, counts: openArray[int]): (string, seq[seq[float32]]) =
  ## A Rev 2.1 variable file, `extSamplesPerTrace` 70000, no Extension 1, with
  ## `numTraces` declared. A count above 65535 stays only in the binary header.
  result[0] = tmp / name
  var samples = newSeq[seq[float32]](counts.len)
  var f = SegyFile(byteOrder: boBig, format: some(sfFloat32), revision: rev(2, 1),
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(teEbcdic))
  f.text.setCard(39, "C39 SEG-Y_REV2.1")
  f.text.setCard(40, "C40 END TEXTUAL HEADER")
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 2, segyMinor: 1,
    samplesPerTrace: 0, extSamplesPerTrace: 70000, sampleInterval: 2000,
    fixedLengthTraces: 0, numTraces: uint64(counts.len), byteOrderMarker: ByteOrderMarker)
  let sink = openDiskSink(result[0])
  var w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: boBig, lenient: true))
  for t, n in counts:
    samples[t] = newSeq[float32](n)
    for i in 0 ..< n: samples[t][i] = float32((i + t) mod 1000)
    var tr = SegyTrace(index: t, numSamples: n)
    tr.header = SegyTraceHeader(traceSeqLine: int32(t + 1), fieldRecord: 1,
      traceNumberInField: int32(t + 1), traceIdCode: 1,
      numSamples: (if n > 65535: 0'u16 else: uint16(n)), sampleInterval: 2000)
    tr.samples = newSeq[byte](4 * n)
    encodeSamples(sfFloat32, samples[t], tr.samples, boBig)
    w.writeTrace(tr)
  w.close()
  sink.close()
  result[1] = samples

proc likeFile(src: string, samples: seq[seq[float32]], r: SegyRevision, name: string): string =
  var f = openSeismic(src)
  result = tmp / name
  var w = openSeismicWriter(result, like = f, segyRevision = some(r))
  for i in 0 ..< f.len: w.writeTrace(f, i, samples[i])
  discard w.close()
  f.close()

proc main*() =
  tmp = scratchDir("parseseg_tsegyrevconvert")

  block rev0_unassigned_bytes_do_not_become_fields:
    let src = keysFile("r0.sgy", rev(0), baseKeys())
    # Vendor data where Rev 0 assigns nothing.
    var b = readFile(src)
    for t in 0 ..< 3:
      let a = 3600 + t * (240 + 400)
      for i in 180 ..< 240: b[a + i] = char(0x70 + i mod 7)
    for i in 3260 ..< 3500: b[i] = '\x11' # binary header bytes 3261-3500
    (b[3504], b[3505]) = ('\0', '\2') # Rev 1 would read 2 extended textual headers,
    (b[3506], b[3507]) = ('\0', '\1') # Rev 2 one additional trace header
    writeFile(src, b)
    let want = keysOf(src) # by Rev 0 rules
    doAssert want.len == 3 and want[0].inline.isNaN and want[0].t0Ms == 100 and
      want[0].cmpX == 500050.0
    for r in [rev(1), rev(2, 0), rev(2, 1)]:
      let (dst, log) = convertTo(src, r)
      doAssert not log.isFatal and log.count(sevError) == 0, $r & ": " & $log
      doAssert log.has("binary header bytes", sevInfo) and log.has("bytes 181-240", sevInfo), $log
      let got = keysOf(dst)
      doAssert got.len == 3, $r & ": " & $got.len & " traces"
      for i in 0 ..< 3:
        doAssert differences(want[i], got[i]).len == 0, $r & ": " & differences(want[i], got[i])
        doAssert allZero(traceBytes(dst, i, 181, 240))
      doAssert sameSamples(src, dst)
    block rev1_to_rev2:
      # Rev 1 leaves the Rev 2 fields of the binary header unassigned.
      let (r1, _) = convertTo(src, rev(1))
      var c = readFile(r1)
      (c[3506], c[3507]) = ('\0', '\1') # one additional trace header, to Rev 2
      c[3519] = '\1'                     # one trace in the file
      writeFile(r1, c)
      let (dst, log) = convertTo(r1, rev(2, 1))
      doAssert not log.isFatal and log.has("3507-3532", sevInfo), $log
      let got = keysOf(dst)
      doAssert got.len == 3
      for i in 0 ..< 3: doAssert differences(want[i], got[i]).len == 0
    block same_revision_keeps_the_bytes:
      let (dst, log) = convertTo(src, rev(0))
      doAssert not log.isFatal and not log.has("unassigned", sevInfo), $log
      doAssert traceBytes(dst, 1, 181, 240) == traceBytes(src, 1, 181, 240)

  block rev0_has_no_time_scalar_and_no_rev1_fields:
    for r in [rev(1), rev(2, 1)]:
      for (t0, want, loss) in [(100.0, 100.0, ""), (0.25, 0.0, "rounded"), (-10.5, -11.0, "rounded"),
          (40000.0, 32767.0, "clamped")]:
        var k = baseKeys()
        k.t0Ms = t0
        k.srcPoint = 99.5 # fractional: held in the Rev 1 shotpoint fields alone
        (k.cmpX, k.cmpY) = (1234.5, 5678.5)
        (k.inline, k.crossline) = (17.0, 23.0)
        let src = keysFile("t0_" & $r.major & "_" & $int(t0 * 100) & ".sgy", r, k)
        let before = keysOf(src)
        doAssert before[0].t0Ms == t0 and before[0].inline == 17 and before[0].srcPoint == 99.5
        let (dst, log) = convertTo(src, rev(0))
        doAssert not log.isFatal and log.count(sevError) == 0, $log
        let got = keysOf(dst)
        doAssert got.len == 3
        for i in 0 ..< 3:
          doAssert got[i].t0Ms == want, $r & ": t0Ms " & $t0 & " -> " & $got[i].t0Ms
          # What Rev 0 has no field for is gone (the midpoint is derived again).
          doAssert got[i].inline.isNaN and got[i].crossline.isNaN and got[i].srcPoint.isNaN
          doAssert got[i].cmpX == 500050.0 and got[i].cmpY == 6000100.0
          var expected = before[i]
          expected.t0Ms = want
          (expected.inline, expected.crossline, expected.srcPoint) = (NaN, NaN, NaN)
          (expected.cmpX, expected.cmpY) = (500050.0, 6000100.0)
          doAssert differences(expected, got[i]).len == 0, differences(expected, got[i])
          doAssert allZero(traceBytes(dst, i, 181, 240))
        doAssert log.has("bytes 181-240", sevInfo), $log
        doAssert log.has("scaled times were rounded", sevInfo) == (loss == "rounded"), $log
        doAssert log.has("beyond ±32767 ms", sevWarning) == (loss == "clamped"), $log
        doAssert sameSamples(src, dst)

  block a_lost_layout_stanza_is_a_warning:
    # survey.sgy keeps inline and crossline in bytes 13 and 17, by its stanza.
    let src = demoDir() / "survey.sgy"
    let before = keysOf(src)
    doAssert before[5].inline == 1001 and before[5].crossline == 6
    let (d0, log0) = convertTo(src, rev(0), "survey_r0.sgy")
    doAssert not log0.isFatal and log0.has("((SEG:Layout)) stanza is dropped", sevWarning), $log0
    doAssert keysOf(d0)[5].inline.isNaN
    # Rev 1 keeps the stanza as extended text, where readers still find it.
    let (d1, log1) = convertTo(src, rev(1), "survey_r1.sgy")
    doAssert not log1.isFatal and not log1.has("stanza is dropped", sevWarning), $log1
    doAssert keysOf(d1)[5].inline == 1001 and keysOf(d1)[5].crossline == 6

  block intervals_rev1_cannot_hold:
    var k = baseKeys()
    k.intervalUs = 100000
    let wide = keysFile("dt100000.sgy", rev(2, 1), k)
    doAssert keysOf(wide)[0].intervalUs == 100000
    for r in [rev(1), rev(0)]:
      let (dst, log) = convertTo(wide, r)
      # Not written as 65535: each trace is skipped, with an error.
      doAssert log.count(sevError) == 3 and log.has("sample interval of 100000", sevError), $log
      var g = openSeismic(dst)
      doAssert g.len == 0
      g.close()
    k.intervalUs = 250.5
    let fractional = keysFile("dt250_5.sgy", rev(2, 1), k)
    let (dst, log) = convertTo(fractional, rev(1))
    doAssert log.count(sevError) == 0 and log.has("intervals were rounded", sevInfo), $log
    let got = keysOf(dst)
    doAssert got.len == 3 and got[0].intervalUs == 251

  block a_count_held_in_the_extended_field_alone:
    # Fixed-length Rev 2, the count only in binary bytes 3269-3272.
    let src = rev2File("ext_count.sgy", 1000, true, 0, 1000, 2000)
    for r in [rev(1), rev(0)]:
      let (dst, log) = convertTo(src, r)
      doAssert not log.isFatal and log.count(sevError) == 0, $log
      var g = openSeismic(dst)
      doAssert not g.log.isFatal and g.len == 3 and g.maxSamples == 1000, $r & ": " & $g.len &
        " traces of " & $g.maxSamples
      doAssert g.fileField("binary.samplesPerTrace").toFloat == 1000
      g.close()
      doAssert sameSamples(src, dst)

  block fixed_length_traces_rev1_cannot_hold:
    for (name, ns, dt, what) in [("long.sgy", 70000, 2000.0, "70000 samples per trace need Rev 2"),
        ("slow.sgy", 1000, 100000.0, "sample interval of 100000.0 needs Rev 2")]:
      let src = rev2File(name, ns, true, 0, uint32(ns), dt)
      var f = openSeismic(src)
      doAssert f.len == 3 and f.maxSamples == ns and f.sampleIntervalUs(0) == dt
      f.close()
      for r in [rev(1), rev(0)]:
        let (dst, log) = convertTo(src, r)
        doAssert log.isFatal and log.has(what, sevFatal), $log
        doAssert not fileExists(dst)

  block variable_length_traces_too_long_are_skipped:
    let src = keysFile("long_var.sgy", rev(2, 1), baseKeys(), traces = 2, ns = 70000)
    let (dst, log) = convertTo(src, rev(1))
    doAssert not log.isFatal and log.count(sevError) == 2 and
      log.has("70000 samples, which Rev 1 cannot hold", sevError), $log
    var g = openSeismic(dst)
    doAssert g.len == 0
    g.close()

  block rev0_traces_that_leave_their_count_to_the_binary_header:
    # Some Rev 0 writers left trace bytes 115-116 at 0 (and some 117-118
    # too); the reader then takes the binary header's values.
    for last in [116, 118]:
      let src = keysFile("r0_zero" & $last & ".sgy", rev(0), baseKeys())
      var b = readFile(src)
      for t in 0 ..< 3:
        for i in 114 ..< last: b[3600 + t * (240 + 400) + i] = '\0'
      writeFile(src, b)
      var want = keysOf(src)
      doAssert want.len == 3
      for r in [rev(0), rev(1), rev(2, 0), rev(2, 1)]:
        let (dst, log) = convertTo(src, r)
        doAssert not log.isFatal and log.count(sevError) == 0, $r & ": " & $log
        var g = openSeismic(dst, keys = true)
        doAssert not g.log.isFatal and g.len == 3 and g.maxSamples == 100, $r & ": " & $g.len &
          " traces of " & $g.maxSamples & " samples"
        # The output's traces say it themselves.
        doAssert not g.log.has("the trace header gives 0 samples", sevWarning), $r
        for i in 0 ..< 3:
          doAssert g.traceField(i, "trace.numSamples").toFloat == 100
          doAssert g.traceField(i, "trace.sampleInterval").toFloat == 2000
          want[i].intervalUs = 2000 # the keys of the input give the header's 0
          doAssert differences(want[i], g.traceKeys(i)).len == 0,
            differences(want[i], g.traceKeys(i))
        g.close()
        doAssert sameSamples(src, dst)

  block a_custom_card_39_is_replaced_and_reported:
    let src = cardFile("custom39.sgy", "C39 CUSTOM REV TEXT HERE")
    let (dst, log) = convertTo(src, rev(1), "custom39_r1.sgy")
    doAssert log.has("CUSTOM REV TEXT HERE", sevWarning), $log
    doAssert card39Of(dst).strip == "C39 SEG Y REV1", card39Of(dst)

  block a_standard_card_39_is_replaced_without_a_report:
    let src = cardFile("std39.sgy", "C39 SEG-Y_REV2.1")
    let (dst, log) = convertTo(src, rev(1), "std39_r1.sgy")
    doAssert not log.has("card 39 held", sevWarning), $log
    doAssert card39Of(dst).strip == "C39 SEG Y REV1", card39Of(dst)

  block a_blank_card_39_is_replaced_without_a_report:
    let src = cardFile("blank39.sgy", "C39 ")
    let (dst, log) = convertTo(src, rev(1), "blank39_r1.sgy")
    doAssert not log.has("card 39 held", sevWarning), $log
    doAssert card39Of(dst).strip == "C39 SEG Y REV1", card39Of(dst)

  block skipped_traces_do_not_keep_the_source_count:
    # Both traces need Extension 1, which they lack: Rev 2.0 skips both.
    let (src, samples) = varFile("skip2.sgy", [70000, 70000])
    let (dst, _) = convertTo(src, rev(2, 0), "skip2_out.sgy")
    let like = likeFile(src, samples, rev(2, 0), "skip2_like.sgy")
    doAssert readFile(dst) == readFile(like)
    var g = openSeismic(dst)
    doAssert not g.log.has("declares", sevWarning), $g.log
    doAssert g.len == 0
    doAssert g.index.segy.binary.numTraces == 0
    # Variable: the binary sample count is not a per-trace declaration.
    doAssert g.index.segy.binary.extSamplesPerTrace == 70000
    doAssert not g.log.has("samples per trace is 0", sevWarning), $g.log
    g.close()

  block a_kept_trace_sets_the_count_a_skipped_one_does_not:
    let (src, samples) = varFile("skip1.sgy", [8, 70000])
    let (dst, _) = convertTo(src, rev(2, 0), "skip1_out.sgy")
    let like = likeFile(src, samples, rev(2, 0), "skip1_like.sgy")
    doAssert readFile(dst) == readFile(like)
    var g = openSeismic(dst)
    doAssert not g.log.has("declares", sevWarning), $g.log
    doAssert g.len == 1 and g.index.segy.binary.numTraces == 1
    doAssert g.index.segy.binary.effectiveSamplesPerTrace == 8
    doAssert g.traceEntry(0).numSamples == 8
    g.close()

when isMainModule: main()
