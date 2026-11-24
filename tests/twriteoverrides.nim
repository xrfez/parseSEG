## Writing derived traces from a template trace (Phase 16.7): header
## overrides round-trip through `openSeismic` with the samples; refused
## overrides write nothing.

import std/[assertions, math, os]

import parseSEG

import ./utils/testutils

proc main*() =
  let tmp = scratchDir("parseseg_twriteoverrides")

  block segy_stack_from_a_template_trace:
    var f = openSeismic(demoDir() / "survey.sgy", keys = true)
    let dst = tmp / "stack.sgy"
    var w = openSeismicWriter(dst, like = f)
    let x = f.readTraces(0 ..< 3)
    for k in 0..2:
      # survey.sgy's Layout stanza reads the CDP X from bytes 73-76 (sourceX).
      w.writeTrace(f, 10, x, k, overrides = [headerOverride("trace.ensembleNumber", 5000 + k),
        headerOverride("trace.numHorzStacked", 24), headerOverride("trace.offset", 150 * k),
        headerOverride("trace.sourceX", 600_000 + k)])
    discard w.close()
    var g = openSeismic(dst, keys = true)
    doAssert g.len == 3
    for k in 0..2:
      let a = g.traceKeys(k)
      doAssert a.ensemble == float64(5000 + k) and a.offset == float64(150 * k)
      doAssert a.cmpX == float64(600_000 + k)
      doAssert a.inline == f.traceKeys(10).inline and a.crossline == f.traceKeys(10).crossline
      doAssert g.traceField(k, "trace.numHorzStacked").toFloat == 24
    doAssert g.readTraces(0 ..< 3) == x
    g.close()
    # Refused: nothing is written, the writer stays usable.
    var v = openSeismicWriter(tmp / "refused.sgy", like = f)
    doAssertRaises(ValueError): v.writeTrace(f, 0, x, 0, overrides = [headerOverride("trace.nope", 1)])
    doAssertRaises(ValueError):
      v.writeTrace(f, 0, x, 0, overrides = [headerOverride("trace.numSamples", 10)])
    doAssertRaises(ValueError):
      v.writeTrace(f, 0, x, 0, overrides = [headerOverride("trace.traceIdCode", 1_000_000)])
    doAssertRaises(ValueError): v.writeTrace(f, 0, x, 0, overrides = [headerOverride("ext1.x", 1)])
    doAssertRaises(ValueError): v.writeTrace(f, 0, x, 0, overrides = [headerOverride("cdp", 1)])
    doAssert v.len == 0
    v.writeTrace(f, 0, x, 0)
    discard v.close()
    f.close()

  block segd_override:
    var f = openSeismic(demoDir() / "record.sgd", keys = true)
    let dst = tmp / "record.sgd"
    var w = openSeismicWriter(dst, like = f)
    let x = f.readTraces(0..0)
    w.writeTrace(f, 0, x, 0, overrides = [headerOverride("ext1.receiverPointNumber", 222),
      headerOverride("trace.traceEdit", 2)])
    discard w.close()
    var g = openSeismic(dst, keys = true)
    doAssert g.traceKeys(0).rcvPoint == 222 and g.traceKeys(0).status == tsDead
    doAssert g.readTraces(0..0) == x
    g.close()
    var v = openSeismicWriter(tmp / "refused.sgd", like = f)
    doAssertRaises(ValueError):
      v.writeTrace(f, 0, x, 0, overrides = [headerOverride("trace.channelSetNumber", 2)])
    f.close()

  block seg2_override:
    var f = openSeismic(demoDir() / "line.sg2", keys = true)
    let dst = tmp / "line.sg2"
    var w = openSeismicWriter(dst, like = f)
    let x = f.readTraces(0 ..< 2)
    for k in 0..1:
      w.writeTrace(f, k, x, k, overrides = [headerOverride("trace.CDP_NUMBER", 77 + k),
        headerOverride("trace.delay", "0.01")])
    discard w.close()
    var g = openSeismic(dst, keys = true)
    doAssert g.len == 2 and g.traceKeys(1).ensemble == 78 and g.traceKeys(0).t0Ms == 10
    doAssert g.readTraces(0 ..< 2) == x
    g.close()
    f.close()

  block binary_header_overrides:
    # Seen failing with the overrides not applied (withBinaryOverrides returning its argument at once):
    # every read-back below found 0 and the refusals did not raise.
    const names = ["jobId", "lineNumber", "reelNumber", "measurementSystem", "sweepFreqStart",
      "sweepFreqEnd", "sweepLength", "sweepType", "sweepChannel", "sweepTaperStart",
      "sweepTaperEnd", "taperType", "correlated", "binaryGainRecovered", "amplitudeRecovery",
      "impulsePolarity", "vibratoryPolarity", "traceSorting", "verticalSumCode", "ensembleFold"]
    proc ovs(): seq[HeaderOverride] =
      for i, n in names: result.add headerOverride("binary." & n, 1000 * (i + 1) + 7)
    proc check(g: SeismicFile, what: string) =
      for i, n in names:
        doAssert g.fileField("binary." & n).toFloat == float64(1000 * (i + 1) + 7), what & " " & n
    proc fileBytes(path: string): string = readFile(path)
    let x = @[1'f32, 2, 3, 4]
    var k = initTraceKeys()
    k.intervalUs = 2000
    for (major, minor) in [(0, 0), (1, 0), (2, 1)]:
      let r = SegyRevision(major: uint8(major), minor: uint8(minor))
      let tag = "rev" & $major & $minor
      # From options (keys path).
      let a = tmp / (tag & "_opts.sgy")
      var w = openSeismicWriter(a, SegyOutputOptions(revision: r, traceSorting: 3,
        binaryOverrides: ovs()))
      w.writeTrace(k, x)
      discard w.close()
      var g = openSeismic(a)
      g.check(tag & " options")
      g.close()
      # Like a SEG-Y file (template path), copying that file's headers.
      let base = tmp / (tag & "_base.sgy")
      var wb = openSeismicWriter(base, SegyOutputOptions(revision: r))
      wb.writeTrace(k, x)
      discard wb.close()
      var f = openSeismic(base)
      let b = tmp / (tag & "_like.sgy")
      var wl = openSeismicWriter(b, like = f, binaryOverrides = ovs())
      wl.writeTrace(f, 0, f.readTraces(0 ..< 1), 0)
      discard wl.close()
      var h = openSeismic(b)
      h.check(tag & " like")
      doAssert h.readTraces(0 ..< 1) == f.readTraces(0 ..< 1)
      h.close()
      # No overrides, or overrides that set what is there: the same bytes.
      let c = tmp / (tag & "_plain.sgy")
      var wc = openSeismicWriter(c, like = f)
      wc.writeTrace(f, 0, f.readTraces(0 ..< 1), 0)
      discard wc.close()
      let d = tmp / (tag & "_same.sgy")
      var wd = openSeismicWriter(d, like = f, binaryOverrides = [
        headerOverride("binary.jobId", 0), headerOverride("binary.sweepLength", 0)])
      wd.writeTrace(f, 0, f.readTraces(0 ..< 1), 0)
      discard wd.close()
      doAssert fileBytes(c) == fileBytes(d), tag & " like bytes"
      let e = tmp / (tag & "_plain_opts.sgy")
      var we = openSeismicWriter(e, SegyOutputOptions(revision: r))
      we.writeTrace(k, x)
      discard we.close()
      doAssert fileBytes(e) == fileBytes(base), tag & " options bytes"
      let e2 = tmp / (tag & "_same_opts.sgy")
      var we2 = openSeismicWriter(e2, SegyOutputOptions(revision: r,
        binaryOverrides: @[headerOverride("binary.jobId", 0)]))
      we2.writeTrace(k, x)
      discard we2.close()
      doAssert fileBytes(e2) == fileBytes(base), tag & " options same bytes"
      # A revision change: applied to the rewritten header.
      if major < 2:
        var wr = openSeismicWriterBytes(f, segyRevision = some(SegyRevision(major: 2, minor: 1)),
          binaryOverrides = ovs())
        wr.writeTrace(f, 0, f.readTraces(0 ..< 1), 0)
        var rd = openSeismicBytes(wr.finishBytes(), "rev.sgy")
        doAssert rd.fileField("binary.segyMajor").toFloat == 2
        rd.check(tag & " to 2.1")
        rd.close()
      f.close()

    # Refusals: before any file is created.
    let refused = tmp / "refused_binary.sgy"
    proc refusedBy(o: HeaderOverride, rev = SegyRevision(major: 2, minor: 1)) =
      doAssertRaises(ValueError):
        discard openSeismicWriter(refused, SegyOutputOptions(revision: rev,
          binaryOverrides: @[o]))
      doAssert not fileExists(refused)
    for n in ["samplesPerTrace", "formatCode", "extSamplesPerTrace", "byteOrderMarker",
        "segyMajor", "segyMinor", "fixedLengthTraces", "numExtTextHeaders",
        "maxAddlTraceHeaders", "numTraces", "firstTraceOffset", "numTrailerRecords",
        "sampleInterval", "extSampleInterval"]:
      refusedBy headerOverride("binary." & n, 1)
    refusedBy headerOverride("binary.nope", 1)
    refusedBy headerOverride("jobId", 1)
    refusedBy headerOverride("trace.jobId", 1)
    refusedBy headerOverride("binary.ensembleFold", 40000)
    refusedBy headerOverride("binary.jobId", "abc")
    refusedBy headerOverride("binary.sweepLength", 1.5)
    refusedBy headerOverride("binary.extEnsembleFold", 1), SegyRevision(major: 0, minor: 0)
    refusedBy headerOverride("binary.timeBasisCode", 1), SegyRevision(major: 1, minor: 0)
    # The Orig interval fields are the caller's.
    var wo = openSeismicWriter(tmp / "orig.sgy", SegyOutputOptions(binaryOverrides: @[
      headerOverride("binary.extSampleIntervalOrig", 4000.5)]))
    wo.writeTrace(k, x)
    discard wo.close()
    var go = openSeismic(tmp / "orig.sgy")
    doAssert go.fileField("binary.extSampleIntervalOrig").toFloat == 4000.5
    go.close()
    var wo2 = openSeismicWriter(tmp / "orig16.sgy", SegyOutputOptions(binaryOverrides: @[
      headerOverride("binary.sampleIntervalOrig", 4000)]))
    wo2.writeTrace(k, x)
    discard wo2.close()
    var go2 = openSeismic(tmp / "orig16.sgy")
    doAssert go2.fileField("binary.sampleIntervalOrig").toFloat == 4000
    go2.close()
    # A 16-bit field hidden by its set extended twin is refused, in either order.
    for (a, b) in [("extEnsembleFold", "ensembleFold"), ("ensembleFold", "extEnsembleFold")]:
      doAssertRaises(ValueError):
        discard openSeismicWriter(refused, SegyOutputOptions(binaryOverrides: @[
          headerOverride("binary." & a, 5), headerOverride("binary." & b, 6)]))
    # Rev 2 holds its own fields.
    var w2 = openSeismicWriter(tmp / "rev2fields.sgy", SegyOutputOptions(binaryOverrides: @[
      headerOverride("binary.extEnsembleFold", 70000), headerOverride("binary.timeBasisCode", 4)]))
    w2.writeTrace(k, x)
    discard w2.close()
    var g2 = openSeismic(tmp / "rev2fields.sgy")
    doAssert g2.fileField("binary.extEnsembleFold").toFloat == 70000
    doAssert g2.fileField("binary.timeBasisCode").toFloat == 4
    g2.close()
    # Like: the same refusals, on a SEG-Y file, and none for another standard.
    var f = openSeismic(tmp / "rev00_base.sgy")
    doAssertRaises(ValueError):
      discard openSeismicWriter(refused, like = f, binaryOverrides = [headerOverride(
        "binary.sampleInterval", 1)])
    doAssertRaises(ValueError):
      discard openSeismicWriter(refused, like = f, binaryOverrides = [headerOverride(
        "binary.extEnsembleFold", 1)])
    f.close()
    block:
      var wt = openSeismicWriter(tmp / "twin.sgy", SegyOutputOptions(binaryOverrides: @[
        headerOverride("binary.extEnsembleFold", 5)]))
      wt.writeTrace(k, x)
      discard wt.close()
      var ft = openSeismic(tmp / "twin.sgy")
      doAssertRaises(ValueError):
        discard openSeismicWriter(refused, like = ft, binaryOverrides = [headerOverride(
          "binary.ensembleFold", 6)])
      doAssert not fileExists(refused)
      ft.close()
    # The revision the output is written in decides which fields exist.
    f = openSeismic(tmp / "rev21_base.sgy")
    doAssertRaises(ValueError):
      discard openSeismicWriter(refused, like = f, binaryOverrides = [headerOverride(
        "binary.extEnsembleFold", 1)], segyRevision = some(SegyRevision(major: 1, minor: 0)))
    doAssert not fileExists(refused)
    f.close()
    var sd = openSeismic(demoDir() / "record.sgd", keys = true)
    doAssertRaises(ValueError):
      discard openSeismicWriter(refused, like = sd, binaryOverrides = [headerOverride(
        "binary.jobId", 1)])
    doAssert not fileExists(refused)
    sd.close()

  echo "twriteoverrides: ok"

when isMainModule: main()
