## The sampled index of fixed-length SEG-Y (15.3-10): `openSeismic`'s default
## `verify = vfSampled` gives the same index as the full walk (`vfFull`) for
## every sample file and a set of conversions (all fields, through a binary
## snapshot; the log differs only by the `dcIndexSampled` info). A sampled
## header that disagrees, a file that does not end after its last trace,
## `keys`, `vfFull` and `buildIndex`'s default all walk. A cache saved from a
## sampled open does not serve `vfFull`.

import std/[assertions, os, strutils]
import parseSEG
import parseSEG/common/binstore
import ./utils/testutils

let tmp = scratchDir("parseseg_tsampledindex")
let bo = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"

proc convert(src, name: string, o: ConvertOptions): string =
  result = tmp / name
  let log = convertFile(src, result, o)
  doAssert not log.isFatal, name & ": " & $log

proc fixtures(): seq[string] =
  for p in walkFiles(exampleDir / "*"): result.add p
  result.add convert(bo, "bo_rev1.sgy", ConvertOptions(revision: SegyRevision(major: 1)))
  result.add convert(bo, "bo_rev1_ibm.sgy",
    ConvertOptions(revision: SegyRevision(major: 1), format: st1))
  result.add convert(bo, "bo_le.sgy", ConvertOptions(byteOrder: boLittle, format: st5))
  result.add convert(bo, "bo_ps.sgy", ConvertOptions(byteOrder: boPairSwapped, format: st2))
  result.add convert(bo, "bo_int16.sgy", ConvertOptions(format: st3))
  result.add convert(bo, "bo_rev20.sgy", ConvertOptions(revision: SegyRevision(major: 2)))
  result.add convert(bo, "bo_rev0.sgy", ConvertOptions(revision: SegyRevision(major: 0)))
  result.add convert(exampleDir / "63.sgd", "d63_rev1.sgy",
    ConvertOptions(revision: SegyRevision(major: 1)))

proc sampled(log: DiagLog): bool =
  for d in log:
    if d.code == dcIndexSampled: return true

proc snapshot(ix: TraceIndex): string =
  # The whole index as `binstore` bytes, the `dcIndexSampled` info left out.
  var c = ix
  c.log = DiagLog()
  for d in ix.log:
    if d.code != dcIndexSampled: c.log.add d
  let p = tmp / "snap.bin"
  var f = open(p, fmWrite)
  var w = initBinWriter(f)
  w.put c
  w.flush()
  f.close()
  readFile(p)

proc headerAt(f: SeismicFile, trace: int): int64 = f.index.entries[trace].offset

proc patchNs(src, dst: string, trace: int) =
  # A copy of `src` whose trace `trace` has another sample count in its header.
  var s = readFile(src)
  var f = openSeismic(src, opts = OpenOptions(verify: vfFull))
  let at = int(f.headerAt(trace)) + 114
  f.close()
  s[at] = char(byte(s[at]) xor 0x01)
  writeFile(dst, s)

block sampled_equals_full_walk:
  var nSampled = 0
  for p in fixtures():
    var a = openSeismic(p)
    if a.kind == skSegy:
      var b = openSeismic(p, opts = OpenOptions(verify: vfFull))
      let what = p.extractFilename
      doAssert not b.log.sampled, what
      doAssert a.index.entries == b.index.entries, what
      doAssert a.index.maxSamples == b.index.maxSamples, what
      doAssert $a.index.segyIntervalUs == $b.index.segyIntervalUs, what
      doAssert snapshot(a.index) == snapshot(b.index), what & ": the indexes differ"
      if a.log.sampled:
        inc nSampled
        doAssert a.log.len == b.log.len + 1, what
        doAssert a.log.has("64 of their headers checked", sevInfo) or a.len < 64, what
      else:
        doAssert $a.log == $b.log, what
      # Reads and keys on demand see the same file.
      if a.len > 0:
        let n = min(a.len, 20)
        doAssert a.readTraces(0 ..< n) == b.readTraces(0 ..< n), what
        doAssert $a.traceKeys(0 ..< n) == $b.traceKeys(0 ..< n), what
      b.close()
    a.close()
  doAssert nSampled >= 6, $nSampled & " files sampled"

block rev0_and_variable_files_walk:
  for name in ["bo_rev0.sgy", "d63_rev1.sgy"]:
    var f = openSeismic(tmp / name)
    let fixed = f.index.segy.revision.major >= 1 and
      f.index.segy.binary.fixedLengthTraces == 1
    doAssert fixed or not f.log.sampled, name
    f.close()

block sampled_mismatch_falls_back:
  # Rev 1: the walk warns about a fixed-length mismatch. Trace 3 is sampled
  # (200 traces: 0, 3, 6, ..., 199), so the open walks and warns.
  let src = tmp / "bo_rev1.sgy"
  var good = openSeismic(src)
  doAssert good.log.sampled and good.len == 200
  let p = tmp / "mismatch3.sgy"
  patchNs(src, p, 3)
  var f = openSeismic(p)
  doAssert not f.log.sampled, $f.log
  doAssert f.log.has("fixed-length file, but this trace has", sevWarning), $f.log
  doAssert f.index.entries == good.index.entries
  f.close()
  for last in [0, 199]:
    let q = tmp / ("mismatch" & $last & ".sgy")
    patchNs(src, q, last)
    var g = openSeismic(q)
    doAssert not g.log.sampled and g.log.has("fixed-length file", sevWarning), $last
    g.close()
  good.close()

block unsampled_mismatch_needs_vfFull:
  # Trace 1 is not sampled: the default open misses it, vfFull reports it.
  let p = tmp / "mismatch1.sgy"
  patchNs(tmp / "bo_rev1.sgy", p, 1)
  var a = openSeismic(p)
  doAssert a.log.sampled and not a.log.has("fixed-length file", sevWarning), $a.log
  var b = openSeismic(p, opts = OpenOptions(verify: vfFull))
  doAssert not b.log.sampled and b.log.has("fixed-length file", sevWarning), $b.log
  doAssert a.index.entries == b.index.entries
  a.close()
  b.close()

block size_that_does_not_fit_walks:
  for extra in ["x", repeat('\0', 239)]:
    let p = tmp / "longer.sgy"
    writeFile(p, readFile(bo) & extra)
    var a = openSeismic(p)
    var b = openSeismic(p, opts = OpenOptions(verify: vfFull))
    doAssert not a.log.sampled and $a.log == $b.log, $a.log
    doAssert a.index.entries == b.index.entries
    a.close()
    b.close()
  let p = tmp / "shorter.sgy"
  let s = readFile(bo)
  writeFile(p, s[0 ..< s.len - 4])
  var c = openSeismic(p)
  doAssert not c.log.sampled and c.log.has("expected 8004 bytes", sevFatal), $c.log
  c.close()

block keys_vfFull_and_buildIndex_walk:
  var k = openSeismic(bo, keys = true)
  doAssert not k.log.sampled and k.hasKeys
  k.close()
  var f = openSeismic(bo, opts = OpenOptions(verify: vfFull))
  doAssert not f.log.sampled
  f.close()
  let m = openMemFileSource(bo)
  doAssert not buildIndex(m, skSegy).log.sampled
  m.close()
  let m2 = openMemFileSource(bo)
  let ix = buildIndex(m2, skSegy, verify = vfSampled)
  doAssert ix.log.sampled and ix.len == 200
  m2.close()

block sampled_cache_and_vfFull:
  let p = tmp / "cached.sgy"
  copyFile(bo, p)
  let sc = tmp / "sampled.pidx"
  var a = openSeismic(p)
  doAssert a.log.sampled
  a.saveIndex(sc)
  a.close()
  var b = openSeismic(p, opts = OpenOptions(cache: sc))
  doAssert b.fromCache and b.log.sampled
  b.close()
  var c = openSeismic(p, opts = OpenOptions(cache: sc, verify: vfFull))
  doAssert not c.fromCache and not c.log.sampled
  doAssert c.log.has("saved from a sampled open", sevInfo), $c.log
  c.close()
  # A cache of a full walk serves both.
  let fc = tmp / "full.pidx"
  var d = openSeismic(p, opts = OpenOptions(verify: vfFull))
  d.saveIndex(fc)
  d.close()
  for v in [vfSampled, vfFull]:
    var e = openSeismic(p, opts = OpenOptions(cache: fc, verify: v))
    doAssert e.fromCache and not e.log.sampled, $v
    e.close()

echo "tsampledindex: ok"
