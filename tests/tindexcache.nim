## Index sidecar cache (task 14.3e): `saveIndex` / `openSeismic(cache =)`.
## A cached index equals the rebuilt one field by field (the whole
## `TraceIndex`, compared through its binary snapshot, plus the main fields
## directly) for every sample file and for SEG-Y LE, SEG-D 2.1 / 3.x and
## SEG-2 conversions, with and without keys. A stale cache (file size,
## modification time, first or last bytes, path, twosComplement8015,
## missing keys, another version or schema) or a damaged one (truncated,
## flipped byte, not a cache) is never used: the file is indexed again
## with an info diagnostic. Demultiplexed copies are not cached (tsegdmux).

import std/[assertions, os, strutils, times]
import parseSEG
import parseSEG/common/binstore
import ./utils/testutils

let tmp = scratchDir("parseseg_tindexcache")

let
  d63 = exampleDir / "63.sgd"
  inova = exampleDir / "inova_rev30_5traces.sgd"
  bo = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"

proc convert(src, name: string, o: ConvertOptions): string =
  result = tmp / name
  let log = convertFile(src, result, o)
  doAssert not log.isFatal, name & ": " & $log

proc fixtures(): seq[string] =
  for n in walkFiles(exampleDir / "*"): result.add n
  result.add convert(bo, "bo_le.sgy", ConvertOptions(byteOrder: boLittle, format: st2))
  result.add convert(d63, "d63_rev1.sgy", ConvertOptions(revision: SegyRevision(major: 1)))
  for (name, rev) in [("d63_20.sgd", (2'u8, 0'u8)), ("d63_21.sgd", (2'u8, 1'u8)),
      ("inova_31.sgd", (3'u8, 1'u8)), ("bo_30.sgd", (3'u8, 0'u8))]:
    var o = ConvertOptions(target: skSegd)
    o.segd.revision = SegdRevision(major: rev[0], minor: rev[1])
    let src = if name.startsWith("d63"): d63 elif name.startsWith("inova"): inova else: bo
    if src == bo: result.add convert(convert(bo, "bo.sg2", ConvertOptions(target: skSeg2)),
      name, o)
    else: result.add convert(src, name, o)
  var o8015 = ConvertOptions(target: skSegd)
  o8015.segd.format = tf8015
  o8015.segd.revision = SegdRevision(major: 2, minor: 1)
  result.add convert(d63, "d63_8015.sgd", o8015)
  result.add tmp / "bo.sg2"
  result.add convert(d63, "d63.sg2", ConvertOptions(target: skSeg2))

proc snapshot(ix: TraceIndex): string =
  ## The whole index as `binstore` bytes: equal snapshots, equal fields.
  let p = tmp / "snap.bin"
  var f = open(p, fmWrite)
  var w = initBinWriter(f)
  w.put ix
  w.flush()
  f.close()
  readFile(p)

proc has(log: DiagLog, code: DiagCode, text = ""): bool =
  for d in log:
    if d.code == code and text in d.msg: return true

proc sameIndex(a, b: SeismicFile, what: string) =
  template ia: untyped = a.index
  template ib: untyped = b.index
  doAssert ia.kind == ib.kind and ia.detected == ib.detected, what
  doAssert ia.entries == ib.entries, what
  doAssert ia.codecs == ib.codecs, what
  doAssert ia.contiguous == ib.contiguous and ia.maxSamples == ib.maxSamples, what
  doAssert $ia.log == $ib.log, what
  doAssert ia.keys.len == ib.keys.len and $ia.keys == $ib.keys, what
  doAssert ia.segdRecords.len == ib.segdRecords.len and $ia.segdToc == $ib.segdToc, what
  doAssert $ia.segdLabel == $ib.segdLabel, what
  doAssert snapshot(ia) == snapshot(ib), what & ": the snapshots differ"

proc reopen(p, cache: string, keys = false): SeismicFile =
  openSeismic(p, keys = keys, cache = cache)

# ---------------------------------------------------------------- round trip --

block cached_index_equals_rebuilt:
  for p in fixtures():
    for keys in [false, true]:
      let what = p.extractFilename & (if keys: " keys" else: "")
      let cache = tmp / (p.extractFilename & ".pidx")
      removeFile(cache)
      var built = openSeismic(p, keys = keys, cache = cache)
      doAssert not built.fromCache and built.log.has(dcIndexCache, "there is no such file"), what
      built.saveIndex(cache)
      var walked = openSeismic(p, keys = keys) # without the cache diagnostic
      var c = reopen(p, cache, keys)
      doAssert c.fromCache, what & ": " & $c.log
      doAssert not c.log.has(dcIndexCache), what
      sameIndex(c, walked, what)
      doAssert c.hasKeys == keys or c.len == 0, what
      # Reads, summaries and header listings work alike.
      if c.len > 0 and c.index.contiguous:
        var la, lb: DiagLog
        let n = min(c.len, 50)
        doAssert c.readTraces(0 ..< n, la) == walked.readTraces(0 ..< n, lb), what
        doAssert $c.traceHeaders(n - 1) == $walked.traceHeaders(n - 1), what
      doAssert $c.summary == $walked.summary, what
      if not keys:
        # A cache with keys serves an open without them.
        let kc = tmp / "withkeys.pidx"
        var k = openSeismic(p, keys = true)
        k.saveIndex(kc)
        var nk = reopen(p, kc)
        doAssert nk.fromCache and (not nk.hasKeys or nk.len == 0), what
        sameIndex(nk, walked, what & " from a keys cache")
        nk.close()
        k.close()
      c.close()
      walked.close()
      built.close()

block progress_on_a_cached_open:
  let cache = tmp / "bo.pidx"
  var f = openSeismic(bo)
  f.saveIndex(cache)
  f.close()
  let calls = new seq[(int64, int64)]
  proc recorder(calls: ref seq[(int64, int64)]): Progress =
    # A hook must be gcsafe: it captures a parameter, not a global.
    proc (d, t: int64): bool =
      calls[].add (d, t)
      true
  var c = openSeismic(bo, cache = cache, progress = recorder(calls))
  doAssert c.fromCache and calls[] == @[(getFileSize(bo), getFileSize(bo))]
  c.close()
  doAssertRaises(SegCancelledError):
    discard openSeismic(bo, cache = cache, progress = proc (d, t: int64): bool = false)

# ----------------------------------------------------------------- staleness --

proc fresh(name: string): (string, string) =
  ## A private copy of Inglewood and its saved cache.
  let p = tmp / name
  copyFile(bo, p)
  let cache = p & ".pidx"
  var f = openSeismic(p)
  f.saveIndex(cache)
  f.close()
  (p, cache)

proc rebuiltBecause(p, cache, why: string, keys = false, twos = false) =
  var f = openSeismic(p, keys = keys, twosComplement8015 = twos, cache = cache)
  doAssert not f.fromCache, p & ": the stale cache was used"
  doAssert f.log.has(dcIndexCache, why), p & ": " & $f.log
  var g = openSeismic(p, keys = keys, twosComplement8015 = twos)
  doAssert f.index.entries == g.index.entries
  f.close()
  g.close()

proc patch(p: string, at: int64, b: byte, keepTime = true) =
  let t = getLastModificationTime(p)
  var s = readFile(p)
  let i = int(if at < 0: s.len + at else: at)
  s[i] = char(b)
  writeFile(p, s)
  if keepTime: setLastModificationTime(p, t)

block stale_size:
  let (p, cache) = fresh("size.sgy")
  let f = open(p, fmAppend)
  f.write "x"
  f.close()
  rebuiltBecause(p, cache, "the file changed")

block stale_mtime:
  let (p, cache) = fresh("mtime.sgy")
  setLastModificationTime(p, getLastModificationTime(p) + initDuration(seconds = 5))
  rebuiltBecause(p, cache, "the file changed")

block stale_first_and_last_bytes:
  # Same size and time: the hashed ends catch it.
  let (p, cache) = fresh("head.sgy")
  patch(p, 3300, 0x55) # binary header
  rebuiltBecause(p, cache, "the file changed")
  let (q, qc) = fresh("tail.sgy")
  patch(q, -2, 0x55) # last sample
  rebuiltBecause(q, qc, "the file changed")

block stale_options_and_path:
  let (p, cache) = fresh("opts.sgy")
  rebuiltBecause(p, cache, "twosComplement8015", twos = true)
  rebuiltBecause(p, cache, "without trace keys", keys = true)
  let other = tmp / "other.sgy"
  copyFile(p, other)
  setLastModificationTime(other, getLastModificationTime(p))
  rebuiltBecause(other, cache, "another file")

block stale_version_or_schema:
  let (p, cache) = fresh("version.sgy")
  let s = readFile(cache)
  doAssert "(version 1)" in s
  writeFile(cache, s.replace("(version 1)", "(version 2)"))
  rebuiltBecause(p, cache, "another version")
  let i = s.find("(schema \"") + 9
  var t = s
  t[i] = (if t[i] == '0': '1' else: '0')
  writeFile(cache, t)
  rebuiltBecause(p, cache, "another version")
  writeFile(cache, s.replace("(library ", "(library \"0\" "))
  rebuiltBecause(p, cache, "another version")

block damaged_caches:
  let (p, cache) = fresh("damage.sgy")
  let s = readFile(cache)
  writeFile(cache, s[0 ..< s.len - 1])
  rebuiltBecause(p, cache, "truncated")
  writeFile(cache, s[0 ..< s.len div 2])
  rebuiltBecause(p, cache, "truncated")
  var t = s
  t[s.len - 100] = char(ord(t[s.len - 100]) xor 1)
  writeFile(cache, t)
  rebuiltBecause(p, cache, "corrupt")
  var u = s
  let body = s.find('\0') + 64
  u[body] = char(ord(u[body]) xor 0x80)
  writeFile(cache, u)
  rebuiltBecause(p, cache, "corrupt")
  writeFile(cache, "")
  rebuiltBecause(p, cache, "no header")
  writeFile(cache, "(.nif27)\n(diagnostics)\n\0garbage")
  rebuiltBecause(p, cache, "not an index cache")
  removeFile(cache)
  createDir(cache)
  rebuiltBecause(p, cache, "")
  removeDir(cache)
  # The rebuilt index saves a cache without the miss diagnostic.
  var f = openSeismic(p, cache = cache)
  doAssert f.log.has(dcIndexCache)
  f.saveIndex(cache)
  var g = openSeismic(p, cache = cache)
  doAssert g.fromCache and not g.log.has(dcIndexCache), $g.log
  f.close()
  g.close()

# ---------------------------------------------------------------- refusals --

block save_refusals:
  let (p, cache) = fresh("refuse.sgy")
  var f = openSeismic(p, keys = true)
  doAssertRaises(ValueError): f.saveIndex(p)
  discard f.index.applyGeometry(GeometryTable())
  doAssertRaises(ValueError): f.saveIndex(cache)
  f.close()
  doAssertRaises(ValueError): f.saveIndex(cache)
  var g = openSeismic(p)
  setLastModificationTime(p, getLastModificationTime(p) + initDuration(seconds = 3))
  doAssertRaises(ValueError): g.saveIndex(cache)
  g.close()
  writeFile(tmp / "junk.bin", repeat('j', 5000))
  var j = openSeismic(tmp / "junk.bin")
  doAssertRaises(ValueError): j.saveIndex(tmp / "junk.pidx")
  j.close()
  doAssertRaises(IOError):
    var h = openSeismic(p)
    try: h.saveIndex(tmp / "no" / "such" / "dir.pidx")
    finally: h.close()
  for x in walkDir(tmp):
    doAssert not x.path.endsWith(".tmp"), x.path

removeDir(tmp)
echo "tindexcache: ok"
