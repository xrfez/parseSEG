## Files read unmapped (`OpenOptions.access = faUnmapped`): no map, so a
## read that fails or meets a cut is an ordinary failed read, with no signal
## handler involved, and a later read tries again.
##
## - `no_handler_unmapped` (first: nothing has been mapped yet): opens, reads
##   and cuts files unmapped; the `SIGBUS` action is still the one before.
## - `cut_short_unmapped`: the cut-short matrix of tcutshort, unmapped:
##   samples, the prefetcher, headers, keys, fields, bytes, the open, the
##   editor, the record reader, SEG-D and SEG-2.
## - `failed_reads_retry`: `pread` interposed to fail with EIO: rows fail with
##   `dcIo`, header calls and the open raise `IOError`, the editor refuses;
##   the same calls succeed once reads work again.
## - `network_file_systems_are_read_unmapped`: `statfs` interposed to say NFS
##   (and FUSE, SMB): `faAuto` opens unmapped there, mapped elsewhere.
## - `same_results_mapped_and_unmapped`: every input file, both ways, and
##   every result byte for byte: index, keys, samples (ranges, windows,
##   selections, the prefetcher), headers, fields, statics, bytes, the header
##   export, index caches, edits.
## - `few_requests`: the open walk and a window of traces in few requests.
##
## Seen failing: without the hold in the walk's record reads (every SEG-D
## and SEG-2 file mismatched), with spans that did not start at a group
## of 4 samples (`readSpan`, SEG-D 8015 windows), without the retry
## (a failed block kept as loaded), ... (see the Log of 18.10).

import std/[algorithm, assertions, os, osproc, sequtils, strutils]
import parseSEG
from parseSEG/model/traceindex import unsafeCache
import parseSEG/private/readcache
import ./utils/testutils

when not defined(linux):
  echo "tunmapped: skipped: pread and statfs are interposed the ELF way (Linux)"
  quit 0
else:
  import std/posix

  {.passL: "-ldl".}
  {.emit: """/*INCLUDESECTION*/
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/vfs.h>
""".}
  {.emit: """
static ssize_t (*parsesegRealPread)(int, void *, size_t, off_t) = 0;
static int (*parsesegRealStatfs)(const char *, struct statfs *) = 0;
static long long parsesegFailFrom = -1; /* reads at or past this offset fail with EIO */
static long parsesegPreads = 0;
static const char *parsesegNetworkMark = 0; /* a path holding it is on "NFS" */
static long parsesegNetworkMagic = 0x6969;
ssize_t pread(int fd, void *buf, size_t n, off_t at) {
  /* Every pread(2) of this program: fails with EIO while asked to. */
  if (!parsesegRealPread)
    parsesegRealPread = (ssize_t (*)(int, void *, size_t, off_t)) dlsym(((void *) -1l), "pread");
  __atomic_add_fetch(&parsesegPreads, 1, __ATOMIC_SEQ_CST);
  long long from = __atomic_load_n(&parsesegFailFrom, __ATOMIC_SEQ_CST);
  if (from >= 0 && (long long) at + (long long) n > from) { errno = EIO; return -1; }
  return parsesegRealPread(fd, buf, n, at);
}
int statfs(const char *path, struct statfs *buf) {
  if (!parsesegRealStatfs)
    parsesegRealStatfs = (int (*)(const char *, struct statfs *)) dlsym(((void *) -1l), "statfs");
  int r = parsesegRealStatfs(path, buf);
  if (r == 0 && parsesegNetworkMark && strstr(path, parsesegNetworkMark))
    buf->f_type = parsesegNetworkMagic;
  return r;
}
static void parsesegFailReadsFrom(long long at) { __atomic_store_n(&parsesegFailFrom, at, __ATOMIC_SEQ_CST); }
static long parsesegPreadCount(void) { return __atomic_load_n(&parsesegPreads, __ATOMIC_SEQ_CST); }
static void parsesegNetwork(const char *mark, long magic) { parsesegNetworkMark = mark; parsesegNetworkMagic = magic; }
""".}
  proc failReadsFrom(at: int64) {.importc: "parsesegFailReadsFrom", nodecl.}
  proc preadCount(): clong {.importc: "parsesegPreadCount", nodecl.}
  proc network(mark: cstring, magic: clong) {.importc: "parsesegNetwork", nodecl.}

  let tmp = scratchDir("parseseg_tunmapped")
  var copies = 0
  const unmapped = OpenOptions(access: faUnmapped)
  const mapped = OpenOptions(access: faMapped)

  proc fresh(name: string): string =
    inc copies
    result = tmp / ($copies & "_" & name)
    copyFile(demoDir() / name, result)

  proc cut(path: string, size: int64) =
    doAssert posix.truncate(path.cstring, Off(size)) == 0, "truncate " & path

  proc sampleEnd(f: SeismicFile, i: int): int64 =
    f.traceEntry(i).sampleOffset + int64(f.index.dataBytes(i))

  proc pastCut(f: SeismicFile, size: int64): seq[int] =
    for i in 0 ..< f.len:
      if f.sampleEnd(i) > size: result.add i

  proc zeroRow(t: Tensor[float32], r: int): bool =
    for c in 0 ..< t.shape[1]:
      if t[r, c] != 0: return false
    true

  proc sameRow(a: Tensor[float32], ra: int, b: Tensor[float32], rb: int): bool =
    for c in 0 ..< a.shape[1]:
      if cast[uint32](a[ra, c]) != cast[uint32](b[rb, c]): return false
    true

  proc c_sigaction(sig: cint, act, old: ptr Sigaction): cint {.
    importc: "sigaction", header: "<signal.h>".}
  proc busAction(): pointer =
    var a: Sigaction
    doAssert c_sigaction(SIGBUS, nil, addr a) == 0
    cast[pointer](a.sa_handler)
  let busBefore = busAction()

  block no_handler_unmapped:
    # Nothing is mapped in this block: parseSEG installs no handler.
    for name in ["survey.sgy", "shot.sgd", "line.sg2"]:
      let p = fresh(name)
      var f = openSeismic(p, keys = true, opts = unmapped)
      doAssert f.access == faUnmapped
      discard f.readTraces(0 ..< f.len)
      discard f.traceHeaders(f.len - 1)
      cut(p, getFileSize(p) div 2)
      var log: DiagLog
      discard f.readTraces(0 ..< f.len, log)
      f.close()
    var ed = openEditor(fresh("survey.sgy"), tmp / "nohandler.edits.nif", access = faUnmapped)
    doAssert ed.setTraceField(0, "trace.sourceX", 17)
    ed.close()
    doAssert busAction() == busBefore, "an unmapped open installed a SIGBUS handler"

  block cut_short_unmapped:
    # A cut is found by a read that must fetch past it (nothing kept from
    # before: a fresh open), or by `cutShort`; then the reads fail as on a
    # mapped file: rows `dcTruncated`, header calls `SegTruncatedError`.
    block samples:
      let p = fresh("survey.sgy")
      var whole: Tensor[float32]
      block:
        var g = openSeismic(p, opts = mapped)
        whole = g.readTraces(0 ..< g.len)
      var f = openSeismic(p, opts = unmapped)
      let size = getFileSize(p) div 2
      cut(p, size)
      f.unsafeCache.dropUnpinned() # nothing kept from the open's reads
      let gone = f.pastCut(size)
      doAssert gone.len > 0 and gone.len < f.len
      var t = newTraceTensor[float32](f.len, f.maxSamples)
      var log: DiagLog
      doAssert f.readTracesInto(0 ..< f.len, t, log) == gone.len, $log.len
      for d in log: doAssert d.code == dcTruncated and "cut short" in d.msg, $d
      for i in 0 ..< f.len:
        if i in gone: doAssert t.zeroRow(i)
        else: doAssert sameRow(t, i, whole, i), $i
      doAssert f.cutShort and not f.readFailed
      doAssertRaises(SegTruncatedError): discard f.traceHeaders(0)
      doAssertRaises(SegTruncatedError): discard f.traceKeys(0 .. 1)
      doAssertRaises(SegTruncatedError): discard f.traceField(f.len - 1, "trace.sourceX")
      doAssertRaises(SegTruncatedError): discard f.copyBytes(0, 16)
      var failedRows: seq[int]
      let picks = toSeq(countdown(f.len - 1, 0, 3))
      var u = newTraceTensor[float32](picks.len, f.maxSamples)
      discard f.readTracesInto(picks, u, failedRows)
      var expected: seq[int]
      for k, i in picks:
        if i in gone: expected.add k
      doAssert failedRows == expected
      f.close()
    block kept_bytes_until_asked:
      # Bytes held before the cut are kept: they read as they were until a
      # read must fetch past the cut or `cutShort` asks.
      let p = fresh("survey.sgy")
      var f = openSeismic(p, opts = unmapped)
      let before = f.readTraces(0 ..< f.len) # all of it in the cache (16 MiB budget)
      let size = getFileSize(p) div 2
      cut(p, size)
      var log: DiagLog
      let again = f.readTraces(0 ..< f.len, log)
      when defined(parseSegReadCacheStress):
        doAssert log.len == f.pastCut(size).len # nothing kept: read again, cut found
      else:
        doAssert log.len == 0 and again == before
        doAssert f.cutShort
        doAssert f.readTraces(0 ..< f.len, log).shape[0] == f.len
        doAssert log.len == f.pastCut(size).len
      f.close()
    block prefetch:
      let p = fresh("survey.sgy")
      var f = openSeismic(p, opts = unmapped)
      let size = getFileSize(p) div 2
      cut(p, size)
      f.unsafeCache.dropUnpinned()
      let gone = f.pastCut(size)
      var pf = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, workers = 2)
      var failed: seq[int]
      for c in pf.chunks:
        for d in c.log: doAssert d.code == dcTruncated
        for r in c.failedRows: failed.add c.first + r
      pf.close()
      doAssert failed == gone, $failed
      f.close()
    block open_and_record_reader:
      let p = fresh("survey.sgy")
      let size = getFileSize(p)
      proc openWhileCut(p: string, size: int64): bool =
        var done = false
        let hook: Progress = proc (walked, total: int64): bool =
          if not done:
            cut(p, size div 4)
            done = true
          true
        try:
          var f = openSeismic(p, keys = true, progress = hook,
            opts = OpenOptions(verify: vfFull, access: faUnmapped))
          f.close()
        except IOError as e:
          result = "cut short while it was opened" in e.msg
      doAssert openWhileCut(p, size)
      let q = fresh("survey.sgy")
      var src = openMemFileSource(q, access = faUnmapped)
      var r = openSegy(src)
      var tr: SegyTrace
      doAssert r.readTrace(tr)
      cut(q, getFileSize(q) div 2)
      while r.readTrace(tr): discard
      doAssert r.log.isFatal and src.cutShort
      src.close()
    block editor:
      let p = fresh("survey.sgy")
      var ed = openEditor(p, tmp / "cut.edits.nif", access = faUnmapped)
      cut(p, getFileSize(p) div 2)
      doAssert ed.file.cutShort
      doAssert not ed.setTraceField(ed.file.len - 1, "trace.sourceX", 5)
      doAssert "cut short" in ed.log[ed.log.len - 1].msg
      doAssertRaises(IOError): ed.close()
    block segd_and_seg2:
      for name in ["shot.sgd", "line.sg2"]:
        let p = fresh(name)
        var f = openSeismic(p, opts = unmapped)
        let size = getFileSize(p) div 2
        cut(p, size)
        f.unsafeCache.dropUnpinned()
        let gone = f.pastCut(size)
        var t = newTraceTensor[float32](f.len, f.maxSamples)
        var failedRows: seq[int]
        doAssert f.readTracesInto(0 ..< f.len, t, failedRows) == gone.len, name
        doAssert failedRows == gone
        doAssertRaises(SegTruncatedError): discard f.traceHeaders(f.len - 1)
        f.close()

  block failed_reads_retry:
    # A share that fails: every read past byte `at` fails with EIO. Unmapped,
    # each call fails on its own, nothing is remembered, and the same calls
    # work once the reads do again.
    let p = fresh("survey.sgy")
    var whole: Tensor[float32]
    block:
      var g = openSeismic(p, opts = mapped)
      whole = g.readTraces(0 ..< g.len)
    var f = openSeismic(p, opts = unmapped)
    let at = getFileSize(p) div 2
    let gone = f.pastCut(at) # the traces whose bytes reach past `at`
    f.unsafeCache.dropUnpinned()
    failReadsFrom(at)
    var t = newTraceTensor[float32](f.len, f.maxSamples)
    var log: DiagLog
    # A request that fails loses all it asked for: every trace of a span that
    # reaches past `at` fails, those wholly before the span did not.
    let n = f.readTracesInto(0 ..< f.len, t, log)
    doAssert n >= gone.len and log.len == n, $n & " " & $gone.len
    for d in log: doAssert d.code == dcIo and "could not be read" in d.msg, $d
    doAssert not f.cutShort and not f.readFailed # no cut, nothing sticky
    try:
      discard f.traceHeaders(f.len - 1)
      doAssert false, "a header past the failed reads"
    except IOError as e:
      doAssert "could not be read" in e.msg and "try again" in e.msg, e.msg
    var pf = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16)
    var pfFailed = 0
    for c in pf.chunks:
      for d in c.log: doAssert d.code == dcIo
      pfFailed += c.failed
    pf.close()
    doAssert pfFailed > 0
    doAssertRaises(IOError):
      var g = openSeismic(p, opts = OpenOptions(verify: vfFull, access: faUnmapped))
      g.close()
    failReadsFrom(-1)
    var ed = openEditor(p, tmp / "eio.edits.nif", access = faUnmapped)
    ed.file.unsafeCache.dropUnpinned()
    failReadsFrom(0) # the read of the header to edit fails: the edit is refused
    doAssert not ed.setTraceField(0, "trace.sourceX", 99)
    doAssert ed.log.len > 0 and "could not be read" in ed.log[ed.log.len - 1].msg, $ed.log
    failReadsFrom(-1)
    doAssert ed.setTraceField(0, "trace.sourceX", 99) # the share is back
    ed.close()
    # The share is back: the same calls read again and give the file's bytes.
    log = DiagLog()
    doAssert f.readTracesInto(0 ..< f.len, t, log) == 0 and log.len == 0
    for i in 1 ..< f.len: doAssert sameRow(t, i, whole, i), $i
    doAssert f.traceHeaders(f.len - 1).len > 0
    f.close()

  block network_file_systems_are_read_unmapped:
    let d = tmp / "share_nfs"
    createDir(d)
    let p = d / "survey.sgy"
    copyFile(demoDir() / "survey.sgy", p)
    const auto = OpenOptions(access: faAuto) # the default, but in `-d:parseSegUnmapped`
    for magic in [0x6969, 0xFE534D42, 0x65735546]: # NFS, SMB2/3, FUSE
      network("share_nfs", clong(magic))
      var f = openSeismic(p, opts = auto)
      doAssert f.access == faUnmapped, $magic
      f.close()
    network(nil, 0)
    var g = openSeismic(p, opts = auto)
    doAssert g.access == faMapped
    g.close()
    var h = openSeismic(p, opts = unmapped)
    doAssert h.access == faUnmapped
    h.close()

  # ------------------------------------------------ the same results both ways

  proc sameTensor(a, b: Tensor[float32]): bool =
    if a.shape != b.shape: return false
    for r in 0 ..< a.shape[0]:
      if not sameRow(a, r, b, r): return false
    true

  proc compare(path: string) =
    let name = path.extractFilename
    var m = openSeismic(path, keys = true, opts = mapped)
    var u = openSeismic(path, keys = true, opts = unmapped)
    doAssert m.access == faMapped and u.access == faUnmapped
    doAssert m.kind == u.kind and m.len == u.len and m.maxSamples == u.maxSamples, name
    doAssert $m.log == $u.log, name
    doAssert m.index.entries == u.index.entries and m.index.codecs == u.index.codecs, name
    doAssert $m.index.keys == $u.index.keys, name
    if m.kind == skUnknown or m.len == 0: return
    if m.index.contiguous:
      var lm, lu: DiagLog
      doAssert sameTensor(m.readTraces(0 ..< m.len, lm), u.readTraces(0 ..< u.len, lu)), name
      doAssert $lm == $lu, name
      let ns = m.maxSamples
      if ns > 9:
        doAssert sameTensor(m.readTraces(0 ..< m.len, 3 .. ns - 5, lm),
          u.readTraces(0 ..< u.len, 3 .. ns - 5, lu)), name & " window"
        doAssert sameTensor(m.readTraces(0 ..< m.len, 1 .. 6, lm),
          u.readTraces(0 ..< u.len, 1 .. 6, lu)), name & " early window"
      let sel = toSeq(countdown(m.len - 1, 0, 2))
      doAssert sameTensor(m.readTraces(sel, lm), u.readTraces(sel, lu)), name & " selection"
      var pm = newPrefetcher[float32](m, sel, chunkTraces = 5, workers = 2)
      var pu = newPrefetcher[float32](u, sel, chunkTraces = 5, workers = 2)
      var cm, cu: PrefetchChunk[float32]
      while pm.next(cm):
        doAssert pu.next(cu) and cm.first == cu.first and sameTensor(cm.samples, cu.samples)
        doAssert cm.failedRows == cu.failedRows, name
      doAssert not pu.next(cu)
      pm.close()
      pu.close()
    # Each step from an empty cache: a read outside a hold finds zeros there.
    u.unsafeCache.dropUnpinned()
    for i in [0, m.len div 2, m.len - 1]:
      doAssert $m.traceHeaders(i) == $u.traceHeaders(i), name & " trace " & $i
    doAssert $m.fileHeaders == $u.fileHeaders, name
    for r in 0 ..< m.recordCount:
      doAssert $m.recordHeaders(r) == $u.recordHeaders(r), name
    doAssert m.copyBytes(0, int(getFileSize(path))) == u.copyBytes(0, int(getFileSize(path)))
    var km = openSeismic(path, opts = mapped)
    var ku = openSeismic(path, opts = unmapped)
    template fresh() = ku.unsafeCache.dropUnpinned()
    fresh()
    doAssert $km.traceKeys(0 ..< km.len) == $ku.traceKeys(0 ..< ku.len), name & " keys"
    var t0m = newSeq[float64](km.len)
    var t0u = newSeq[float64](ku.len)
    km.startTimeMsInto(0 ..< km.len, t0m)
    fresh()
    ku.startTimeMsInto(0 ..< ku.len, t0u)
    doAssert $t0m == $t0u
    let field = case m.kind
      of skSegy: "trace.sourceX"
      of skSegd: "trace.channelSetNumber"
      else: "trace.CHANNEL_NUMBER"
    fresh()
    doAssert $km.traceFieldColumn(field, 0 ..< km.len) ==
      $ku.traceFieldColumn(field, 0 ..< ku.len), name & " column"
    fresh()
    for i in [0, km.len div 2, km.len - 1]:
      doAssert $km.traceField(i, field) == $ku.traceField(i, field), name & " field"
    if m.kind == skSegy:
      fresh()
      doAssert $km.fileField("binary.formatCode") == $ku.fileField("binary.formatCode")
      fresh()
      doAssert $km.traceStatics(0 ..< km.len) == $ku.traceStatics(0 ..< ku.len)
      doAssert km.extendedTextHeaders == ku.extendedTextHeaders
    if m.kind == skSeg2:
      fresh()
      for i in 0 ..< m.len: doAssert $km.seg2Trace(i) == $ku.seg2Trace(i)
    fresh()
    ku.ensureKeys()
    doAssert $ku.index.keys == $m.index.keys, name & " ensureKeys"
    let em = tmp / (name & ".m.nif")
    let eu = tmp / (name & ".u.nif")
    km.exportHeaders(em, raw = true)
    fresh()
    ku.exportHeaders(eu, raw = true)
    doAssert readFile(em) == readFile(eu), name & " export"
    km.close()
    ku.close()
    m.close()
    u.close()

  block same_results_mapped_and_unmapped:
    var files = inputFiles()
    for n in ["survey.sgy", "shot.sgd", "record.sgd", "line.sg2"]: files.add demoDir() / n
    # Packed samples (4 in 10 bytes): a window starts inside a group.
    for (fmt, name) in [(tf8015, "shot8015.sgd"), (tf8024, "shot8024.sgd")]:
      let log = convertSegdRevision(demoDir() / "shot.sgd", tmp / name,
        SegdConvertOptions(revision: SegdRevision(major: 2, minor: 1), format: fmt))
      doAssert not log.isFatal, $log
      files.add tmp / name
    for p in files: compare(p)
    # The index cache, saved and read back unmapped.
    let p = fresh("survey.sgy")
    var f = openSeismic(p, keys = true, opts = unmapped)
    f.saveIndex(tmp / "survey.idx")
    f.close()
    var g = openSeismic(p, keys = true,
      opts = OpenOptions(cache: tmp / "survey.idx", access: faUnmapped))
    doAssert g.fromCache
    g.close()
    # The same edits, mapped and unmapped: the same file and journal.
    let a = fresh("survey.sgy")
    let b = fresh("survey.sgy")
    for (path, how) in [(a, faMapped), (b, faUnmapped)]:
      var ed = openEditor(path, path & ".edits.nif", access = how)
      ed.beginBatch()
      for i in countup(0, ed.file.len - 1, 7):
        doAssert ed.setTraceField(i, "trace.sourceX", 1000 + i)
      doAssert ed.endBatch()
      doAssert ed.setTraceField(3, "trace.groupX", -44)
      doAssert ed.setFileField("binary.jobId", 4242)
      ed.close()
    doAssert readFile(a) == readFile(b)
    doAssert readFile(a & ".edits.nif").replace(a, "X") == readFile(b & ".edits.nif").replace(b, "X")

  block few_requests:
    # A walk reads ahead in windows that double up to 8 MiB, and a window of
    # traces is one request per 8 MiB of consecutive traces: on a share the
    # round trips are the cost.
    let p = fresh("survey.sgy") # 1.6 MB, 5 records of 120 traces of 501 samples
    let size = getFileSize(p)
    let before = preadCount()
    var f = openSeismic(p, opts = OpenOptions(verify: vfFull, access: faUnmapped))
    let walk = preadCount() - before
    when not defined(parseSegReadCacheStress):
      doAssert walk <= 6, "the walk of " & $size & " bytes took " & $walk & " requests"
      f.unsafeCache.dropUnpinned()
      let r0 = preadCount()
      discard f.readTraces(0 ..< f.len)
      doAssert preadCount() - r0 <= 2, $(preadCount() - r0)
    f.close()

  echo "tunmapped: ok"
