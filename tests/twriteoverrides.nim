## Writing derived traces from a template trace (Phase 16.7): header
## overrides round-trip through `openSeismic` with the samples; refused
## overrides write nothing.

import std/[assertions, math, os]
import parseSEG
import ./utils/testutils

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

echo "twriteoverrides: ok"
