## SEG-Y to SEG-Y with a new revision (`convertSegy`): the header bytes
## whose meaning the revision changes are rewritten, and what the target
## cannot hold is reported. Synthetic files, written by the library.

import std/[assertions, math, os]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tsegyrevconvert")

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
  ## The fields in which `a` and `b` differ (NaN equals NaN).
  for name, x, y in fieldPairs(a, b):
    when x is float64:
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
