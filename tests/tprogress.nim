## Progress and cancel (task 14.3e): `openSeismic` / `buildIndex`,
## `convertFile` (every input standard to every target),
## `convertSegdRevision`, `convertWithGeometry`, `copyWithGeometry` and
## `exportHeaders` call the hook about every MiB of input plus once at the
## end, never more often; a hook returning false cancels: `openSeismic`
## raises `SegCancelledError` and unmaps the file, conversions return a
## fatal `dcCancelled` and leave no output (nor temporary files), and
## `exportHeaders` raises with no output. Without a hook (nil, the default)
## results are unchanged.

import std/[assertions, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_tprogress")

let
  d63 = exampleDir / "63.sgd"
  inova = exampleDir / "inova_rev30_5traces.sgd"
  bo = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"

type Calls = ref object
  done, total: seq[int64]
  cancelAt: int ## Return false on this call (1-based); 0 never.

proc hook(c: Calls): Progress =
  result = proc (done, total: int64): bool =
    c.done.add done
    c.total.add total
    c.cancelAt == 0 or c.done.len < c.cancelAt

proc checkCalls(c: Calls, size: int64, what: string) =
  ## Monotonic, one total, ends at it, about once per MiB of each pass (up
  ## to four passes, each also called at its start and end).
  doAssert c.done.len >= 2, what & ": " & $c.done
  for i, d in c.done:
    doAssert c.total[i] == size, what & ": total " & $c.total[i] & " != " & $size
    doAssert d in 0'i64 .. size, what & ": " & $d
    if i > 0: doAssert d >= c.done[i - 1], what & ": not monotonic " & $c.done
  doAssert c.done[^1] == size, what & ": last " & $c.done[^1]
  doAssert c.done.len <= (int(size div ProgressStep) + 2) * 6, what & ": " & $c.done.len & " calls"

proc cancelled(log: DiagLog): bool =
  if log.isFatal:
    for d in log:
      if d.code == dcCancelled and d.severity == sevFatal: return true

proc leftovers(dir: string): seq[string] =
  for p in walkDir(dir):
    if p.path.endsWith(".tmp"): result.add p.path

# A SEG-Y file of about 10 MB: Inglewood's 200 traces five times.
let big = tmp / "big.sgy"
block:
  var src = openSeismic(bo)
  let x = src.readTraces(0 ..< src.len)
  var w = openSeismicWriter(big, like = src)
  for k in 0 ..< 5:
    for i in 0 ..< src.len: w.writeTrace(src, i, x, i)
  doAssert not w.close().isFatal
  src.close()

var inputs = @[bo, d63, inova, big]
let d21 = tmp / "d63_21.sgd"
block:
  var o = ConvertOptions(target: skSegd)
  o.segd.revision = SegdRevision(major: 2, minor: 1)
  doAssert not convertFile(d63, d21, o).isFatal
  inputs.add d21
let sg2 = tmp / "bo.sg2"
doAssert not convertFile(bo, sg2, ConvertOptions(target: skSeg2)).isFatal
inputs.add sg2
let real = exampleDir / "00000151_12900_11300.sgd" # git-ignored: may be missing
if fileExists(real): inputs.add real

# ------------------------------------------------------------------ open --

block open_reports_progress:
  for p in inputs:
    let size = getFileSize(p)
    let c = Calls()
    var f = openSeismic(p, keys = true, progress = c.hook)
    c.checkCalls(size, p)
    if size > 3 * ProgressStep: doAssert c.done.len >= 3, p & ": " & $c.done
    if p == big: doAssert c.done.len in 8..11, $c.done.len # 1000 traces, 8 MB: per MiB
    var plain = openSeismic(p, keys = true)
    doAssert plain.index.entries == f.index.entries and $plain.log == $f.log, p
    doAssert plain.index.codecs == f.index.codecs and plain.len == f.len, p
    plain.close()
    f.close()

block build_index_reports_progress:
  let m = openMemFileSource(big)
  let c = Calls()
  let ix = buildIndex(m, skSegy, progress = c.hook)
  c.checkCalls(m.size, "buildIndex")
  doAssert ix.len == 1000
  m.close()

proc mapped(path: string): bool =
  when defined(linux):
    let full = expandFilename(path)
    for line in readFile("/proc/self/maps").splitLines:
      if line.endsWith(full): return true

block open_cancels_and_unmaps:
  # vfFull: a sampled open of fixed-length SEG-Y makes only the final call.
  for p in inputs:
    for at in [1, 2]:
      let c = Calls(cancelAt: at)
      doAssertRaises(SegCancelledError):
        discard openSeismic(p, progress = c.hook, opts = OpenOptions(verify: vfFull))
      doAssert c.done.len == at, p
      doAssert not mapped(p), p & " is still mapped"
  let c = Calls(cancelAt: 1)
  doAssertRaises(SegCancelledError):
    discard openSeismic(big, progress = c.hook)
  doAssert c.done == @[getFileSize(big)] and not mapped(big), $c.done

block open_without_hook_is_unchanged:
  var f = openSeismic(big, progress = nil)
  doAssert f.len == 1000 and not f.log.isFatal
  f.close()

# --------------------------------------------------------------- convert --

proc targets(input: string): seq[(string, ConvertOptions)] =
  result.add ("sgy", ConvertOptions())
  result.add ("sg2", ConvertOptions(target: skSeg2))
  var r21 = ConvertOptions(target: skSegd)
  r21.segd.revision = SegdRevision(major: 2, minor: 1)
  var r30 = ConvertOptions(target: skSegd)
  r30.segd.revision = SegdRevision(major: 3, minor: 0)
  let f = openSeismic(input)
  if f.kind != skSegy:
    result.add ("d21.sgd", r21)
    result.add ("d30.sgd", r30)
  if f.kind == skSegd: result.add ("f5.sgy", ConvertOptions(format: st5))
  if f.len > 65535: result.setLen 0 # not a SEG-2 target; skip the real file's 2 GB writes

block convert_reports_progress_and_cancels:
  for p in [bo, d63, inova, d21, sg2, big]:
    let size = getFileSize(p)
    for (ext, o) in targets(p):
      let name = p.extractFilename & "." & ext
      let plainOut = tmp / ("plain_" & name)
      let plain = convertFile(p, plainOut, o)
      if plain.isFatal: continue # a pairing the converter refuses (e.g. > 65535 SEG-2 traces)
      let c = Calls()
      let hooked = tmp / ("hooked_" & name)
      let log = convertFile(p, hooked, o, c.hook)
      doAssert not log.isFatal, name & ": " & $log
      c.checkCalls(size, name)
      doAssert readFile(hooked) == readFile(plainOut), name & ": output differs with a hook"
      for at in [1, 2]:
        let x = Calls(cancelAt: at)
        let cancelled = tmp / ("cancel_" & name)
        let clog = convertFile(p, cancelled, o, x.hook)
        doAssert cancelled(clog), name & ": " & $clog
        doAssert not fileExists(cancelled), name
        doAssert x.done.len == at, name & ": " & $x.done
      doAssert leftovers(tmp).len == 0, $leftovers(tmp)

block convert_revision_and_streams:
  let size = getFileSize(inova)
  let c = Calls()
  let o = SegdConvertOptions(revision: SegdRevision(major: 2, minor: 1))
  doAssert not convertSegdRevision(inova, tmp / "rev.sgd", o, c.hook).isFatal
  c.checkCalls(size, "convertSegdRevision")
  let x = Calls(cancelAt: 2)
  let log = convertSegdRevision(inova, tmp / "rev_c.sgd", o, x.hook)
  doAssert log.isFatal and log.count(sevFatal) == 1 and not fileExists(tmp / "rev_c.sgd"), $log
  # The stream converters report against the source's size.
  let src = openDiskSource(big)
  let sink = openDiskSink(tmp / "stream.sgy")
  let s = Calls()
  doAssert not convertSegy(src, sink, ConvertOptions(), s.hook).isFatal
  s.checkCalls(getFileSize(big), "convertSegy")
  src.close()
  sink.close()
  let src2 = openDiskSource(big)
  let sink2 = openDiskSink(tmp / "stream_c.sgy")
  let y = Calls(cancelAt: 3)
  let clog = convertSegy(src2, sink2, ConvertOptions(), y.hook)
  doAssert cancelled(clog) and y.done.len == 3
  src2.close()
  sink2.close()

block geometry_writers_report_and_cancel:
  let g = initSurveyGeometry()
  for p in [big, d21]:
    let size = getFileSize(p)
    let c = Calls()
    let copied = copyWithGeometry(p, tmp / "geo_copy.bin", g, progress = c.hook)
    doAssert not copied.log.isFatal, $copied.log
    c.checkCalls(size, "copyWithGeometry " & p)
    let x = Calls(cancelAt: 2)
    let cc = copyWithGeometry(p, tmp / "geo_copy_c.bin", g, progress = x.hook)
    doAssert cancelled(cc.log), $cc.log
    doAssert not fileExists(tmp / "geo_copy_c.bin")
    let k = Calls()
    let conv = convertWithGeometry(p, tmp / "geo_conv.sgy", g, progress = k.hook)
    doAssert not conv.isFatal, $conv
    k.checkCalls(size, "convertWithGeometry " & p)
    let y = Calls(cancelAt: 2)
    let cv = convertWithGeometry(p, tmp / "geo_conv_c.sgy", g, progress = y.hook)
    doAssert cancelled(cv), $cv
    doAssert not fileExists(tmp / "geo_conv_c.sgy")
    doAssert leftovers(tmp).len == 0, $leftovers(tmp)

# ---------------------------------------------------------------- export --

block export_reports_and_cancels:
  for p in [big, inova, sg2]:
    var f = openSeismic(p)
    let c = Calls()
    f.exportHeaders(tmp / "h.nif", raw = false, progress = c.hook)
    c.checkCalls(getFileSize(p), "exportHeaders " & p)
    f.exportHeaders(tmp / "h_plain.nif", raw = false)
    doAssert readFile(tmp / "h.nif") == readFile(tmp / "h_plain.nif")
    let x = Calls(cancelAt: 2)
    doAssertRaises(SegCancelledError):
      f.exportHeaders(tmp / "h_c.nif", progress = x.hook)
    doAssert not fileExists(tmp / "h_c.nif") and leftovers(tmp).len == 0
    f.close()

block cancelled_code_round_trips_in_nif:
  var log: DiagLog
  log.report(sevFatal, dcCancelled, "cancelled")
  doAssert parseDiagnostics(log.toNif)[0].code == dcCancelled

removeDir(tmp)
echo "tprogress: ok"
