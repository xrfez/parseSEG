## A mapped file cut short by another program (a recorder, a copy over the
## file) while it is open must not end the program: on POSIX a read of a
## page past the new end raised SIGBUS. Each block cuts a fresh copy of a
## demo file with `truncate` and reads it the way a viewer does: samples
## (ranges, lists, the prefetcher, also while it runs), headers, keys,
## fields and bytes, the open walk, the editor, the record reader, SEG-D
## and SEG-2. Without the guard (`private/mapguard`) every block dies with
## "Bus error"; seen failing with the guard off (`guardMap` returning nil),
## without the re-check of rows read before a cut was found
## (`cut_inside_the_last_page`), without the check after a header read
## (`a_header_call_that_meets_the_cut_raises`), without the check at the
## end of an open (`cut_while_opening`), without the editor's refusal
## (`editor`) and with the handler returning instead of chaining
## (`a_fault_outside_parseSEG_still_ends_the_process`).

import std/[assertions, os, osproc, sequtils, streams, strutils, times]
import parseSEG
import ./utils/testutils

when not defined(posix):
  echo "tcutshort: skipped: only POSIX can cut a mapped file"
  quit 0
else:
  import std/[memfiles, posix]

let tmp = scratchDir(if paramCount() == 1: "parseseg_tcutshort_child" else: "parseseg_tcutshort")
createDir(tmp)
var copies = 0

proc fresh(name: string): string =
  ## A copy of demo file `name`, for one block to cut.
  inc copies
  result = tmp / ($copies & "_" & name)
  copyFile(demoDir() / name, result)

proc cut(path: string, size: int64) =
  doAssert posix.truncate(path.cstring, Off(size)) == 0, "truncate " & path

proc sampleEnd(f: SeismicFile, i: int): int64 =
  ## Where trace `i`'s samples end.
  f.traceEntry(i).sampleOffset + int64(f.index.dataBytes(i))

proc pastCut(f: SeismicFile, size: int64): seq[int] =
  ## The traces whose samples reach past a cut at `size`.
  for i in 0 ..< f.len:
    if f.sampleEnd(i) > size: result.add i

proc zeroRow(t: Tensor[float32], r: int): bool =
  for c in 0 ..< t.shape[1]:
    if t[r, c] != 0: return false
  true

proc sameRow(a: Tensor[float32], ra: int, b: Tensor[float32], rb: int): bool =
  for c in 0 ..< a.shape[1]:
    if a[ra, c] != b[rb, c]: return false
  true

let pageSize = int64(sysconf(SC_PAGESIZE))

block foreign:
  # Run as a child by `a_fault_outside_parseSEG_still_ends_the_process`.
  if paramCount() == 1 and paramStr(1) == "foreign":
    # No core dump of the planned crash.
    var rlimitCore {.importc: "RLIMIT_CORE", header: "<sys/resource.h>".}: cint
    var none = RLimit(rlim_cur: 0, rlim_max: 0)
    discard setrlimit(rlimitCore, none)
    when defined(linux):
      proc prctl(option: cint, arg: culong): cint {.importc, header: "<sys/prctl.h>".}
      const PrSetDumpable = 4
      discard prctl(PrSetDumpable, 0)
    var f = openSeismic(fresh("survey.sgy")) # installs parseSEG's handler
    let p = fresh("survey.sgy")
    var m = memfiles.open(p) # a map parseSEG knows nothing of
    cut(p, 1000)
    let mem = cast[ptr UncheckedArray[byte]](m.mem)
    var sum = 0
    for i in countup(0, m.size - 1, 512): sum += int(mem[i])
    echo "survived ", sum # never reached: the fault is not parseSEG's
    f.close()
    quit 0

block samples_after_a_cut:
  # A range and a list, with a log and with failed rows: the traces past the
  # cut are zero rows with `dcTruncated`; the others are what the file held.
  let p = fresh("survey.sgy")
  var f = openSeismic(p)
  let whole = f.readTraces(0 ..< f.len)
  let size = getFileSize(p) div 2
  cut(p, size)
  let gone = f.pastCut(size)
  doAssert gone.len > 0 and gone.len < f.len and gone[^1] == f.len - 1
  var t = newTraceTensor[float32](f.len, f.maxSamples)
  var log: DiagLog
  doAssert f.readTracesInto(0 ..< f.len, t, log) == gone.len
  doAssert log.len == gone.len
  for d in log: doAssert d.code == dcTruncated and d.severity == sevError
  doAssert "cut short" in log[0].msg, log[0].msg
  for i in 0 ..< f.len:
    if i in gone: doAssert t.zeroRow(i), "trace " & $i & " is past the cut"
    else: doAssert sameRow(t, i, whole, i), "trace " & $i & " was in the file"
  doAssert f.cutShort
  # A list, newest first, into failed rows (positions in the list, in order).
  let picks = toSeq(countdown(f.len - 1, 0, 3))
  var u = newTraceTensor[float32](picks.len, f.maxSamples)
  var failedRows: seq[int]
  doAssert f.readTracesInto(picks, u, failedRows) == failedRows.len
  var expected: seq[int]
  for k, i in picks:
    if i in gone: expected.add k
    else: doAssert sameRow(u, k, whole, i)
  doAssert failedRows == expected, $failedRows & " " & $expected
  # A new tensor, and a sample window: with a log, zero rows; without one,
  # `SegTruncatedError` (as for any trace that cannot be decoded).
  var wlog: DiagLog
  let w = f.readTraces(gone[0] - 2 .. gone[0] + 2, 100 .. 199, wlog)
  doAssert w.shape == [5, 100] and not w.zeroRow(0) and w.zeroRow(2) and w.zeroRow(4)
  doAssert wlog.len == 3
  doAssertRaises(SegTruncatedError): discard f.readTraces(gone[0] .. gone[0])
  f.close()

block cut_inside_the_last_page:
  # The OS gives zeros, not a fault, for the rest of the page that holds the
  # new end. A cut inside the last page of trace `k`'s samples: read alone
  # before anything found the cut, `k` comes back with zeros at its end (the
  # limit the guide states); read in one call with `k + 1`, whose bytes
  # reach the next page and fault, `k` fails too; and once `cutShort` has
  # asked the OS, `k` fails on its own.
  for mode in ["together", "prefetch", "alone", "asked"]:
    let p = fresh("survey.sgy")
    var f = openSeismic(p)
    let whole = f.readTraces(0 ..< f.len)
    let k = 60
    let lastPage = (f.sampleEnd(k) - 1) div pageSize * pageSize
    let size = max(lastPage, f.traceEntry(k).sampleOffset) + 8
    doAssert size < f.sampleEnd(k) and f.sampleEnd(k + 1) > lastPage + pageSize
    cut(p, size)
    var log: DiagLog
    case mode
    of "together":
      var t = newTraceTensor[float32](2, f.maxSamples)
      doAssert f.readTracesInto(k .. k + 1, t, log) == 2, $log
      doAssert t.zeroRow(0) and t.zeroRow(1)
    of "prefetch":
      var pf = newPrefetcher[float32](f, k - 1 .. k + 1, chunkTraces = 3)
      var c: PrefetchChunk[float32]
      doAssert pf.next(c) and c.count == 3
      doAssert c.failedRows == @[1, 2] and c.log.len == 2, $c.failedRows
      doAssert sameRow(c.samples, 0, whole, k - 1) and c.samples.zeroRow(1)
      pf.close()
    of "alone":
      var t = newTraceTensor[float32](1, f.maxSamples)
      doAssert f.readTracesInto(k .. k, t, log) == 0, "no fault: nothing to see"
      let kept = int(size - f.traceEntry(k).sampleOffset) div 4 # IBM float: 4 bytes
      for c in 0 ..< f.maxSamples:
        doAssert t[0, c] == (if c < kept: whole[k, c] else: 0'f32), $c
      doAssert f.cutShort # asks the OS: from here on `k` fails
      doAssert f.readTracesInto(k .. k, t, log) == 1 and t.zeroRow(0)
    else:
      doAssert f.cutShort
      var t = newTraceTensor[float32](3, f.maxSamples)
      var failedRows: seq[int]
      doAssert f.readTracesInto([k - 1, k, k + 1], t, failedRows) == 2
      doAssert failedRows == @[1, 2] and sameRow(t, 0, whole, k - 1)
    f.close()

block prefetch_while_the_file_is_cut:
  # The cut comes while a prefetcher reads ahead: a row it gives either is
  # what the file held or failed (zero, `dcTruncated`), and every trace past
  # the cut that was decoded after it is failed. The ring holds two chunks
  # of 8 traces, so everything from trace 24 on is decoded after the cut.
  let p = fresh("survey.sgy")
  var f = openSeismic(p)
  let whole = f.readTraces(0 ..< f.len)
  let size = getFileSize(p) div 2
  var pf = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, depth = 2,
    maxRingBytes = 2 * 8 * f.maxSamples * 4)
  doAssert pf.depth == 2
  var c: PrefetchChunk[float32]
  doAssert pf.next(c) and c.failed == 0
  cut(p, size)
  let gone = f.pastCut(size)
  var failedTraces: seq[int]
  while pf.next(c):
    for d in c.log: doAssert d.code == dcTruncated
    doAssert c.log.len == c.failed and c.failedRows.len == c.failed
    for r in 0 ..< c.count:
      let i = c.first + r
      if r in c.failedRows:
        failedTraces.add i
        doAssert c.samples.zeroRow(r)
      else:
        doAssert sameRow(c.samples, r, whole, i), "trace " & $i
  pf.close()
  doAssert failedTraces == gone, $failedTraces & " " & $gone
  # A selection with two workers, after the cut: the same rows fail.
  let sel = toSeq(countdown(f.len - 1, 0, 2))
  var q = newPrefetcher[float32](f, sel, chunkTraces = 16, workers = 2)
  var failedSel: seq[int]
  while q.next(c):
    for r in c.failedRows: failedSel.add q.traceAt(c.first + r)
  q.close()
  doAssert failedSel == sel.filterIt(it in gone), $failedSel
  f.close()

block a_header_call_that_meets_the_cut_raises:
  # The first read of the file past the cut is a header call: it raises
  # `SegTruncatedError` (it read zeros); so does every later call that reads
  # headers, keys or bytes from the map, wherever they lie.
  template meets(body: untyped) =
    block:
      let p = fresh("survey.sgy")
      var f {.inject.} = openSeismic(p)
      let last {.inject.} = f.len - 1
      cut(p, getFileSize(p) div 2)
      doAssert f.traceHeaders(0).len > 0 # before the cut: answered, nothing seen yet
      doAssertRaises(SegTruncatedError): body
      doAssertRaises(SegTruncatedError): discard f.traceHeaders(0)
      doAssert f.cutShort
      f.close()
  meets: discard f.traceHeaders(last)
  meets: discard f.traceKeys(last - 3 .. last)
  meets: discard f.traceField(last, "trace.sourceX")
  meets: discard f.traceFieldColumn("trace.cdpX", 0 .. last)
  meets: discard f.copyBytes(f.traceEntry(last).offset, 240)
  meets: discard f.traceStatics(last - 1 .. last)
  meets: discard f.startTimeMs(last)
  meets: f.ensureKeys()
  meets: discard f.sortTraces(["trace.sourceX"])

block calls_after_a_cut_was_found:
  let p = fresh("survey.sgy")
  var f = openSeismic(p)
  cut(p, getFileSize(p) div 3)
  doAssert f.cutShort
  doAssertRaises(SegTruncatedError): discard f.traceHeaders(0)
  doAssertRaises(SegTruncatedError): discard f.fileHeaders()
  doAssertRaises(SegTruncatedError): discard f.recordHeaders(0)
  doAssertRaises(SegTruncatedError): discard f.fileField("binary.formatCode")
  doAssertRaises(SegTruncatedError): discard f.findTraceField(0, "trace.sourceX")
  doAssertRaises(SegTruncatedError): discard f.copyBytes(0, 16)
  doAssertRaises(SegTruncatedError): discard f.traceKeys(0 .. 1)
  doAssertRaises(SegTruncatedError):
    f.exportHeaders(tmp / "cut.nif")
  doAssert not fileExists(tmp / "cut.nif")
  var log: DiagLog
  var t = newTraceTensor[float32](2, f.maxSamples)
  doAssert f.readTracesInto(0 .. 1, t, log) == 0 # samples before the cut still read
  f.close()
  doAssert not f.cutShort # closed

block segd_and_seg2:
  for name in ["shot.sgd", "line.sg2"]:
    let p = fresh(name)
    var f = openSeismic(p)
    let whole = f.readTraces(0 ..< f.len)
    let size = getFileSize(p) div 2
    cut(p, size)
    let gone = f.pastCut(size)
    doAssert gone.len > 0 and gone[^1] == f.len - 1 and gone[0] > 0, name
    var t = newTraceTensor[float32](f.len, f.maxSamples)
    var failedRows: seq[int]
    doAssert f.readTracesInto(0 ..< f.len, t, failedRows) == gone.len, name
    doAssert failedRows == gone and sameRow(t, 0, whole, 0)
    doAssertRaises(SegTruncatedError): discard f.traceHeaders(f.len - 1)
    if f.kind == skSeg2:
      doAssertRaises(SegTruncatedError): discard f.seg2Trace(0)
    else:
      doAssertRaises(SegTruncatedError): discard f.traceKeys(0 ..< f.len)
    f.close()

block cut_while_opening:
  # The walk (and the sampled index's keys pass) meet the cut, or it comes
  # after them: the open raises `IOError`, nothing stays mapped.
  proc openWhileCut(p: string, verify: VerifyMode, keys: bool): bool =
    # True when the open raised for the cut its progress hook made.
    let size = getFileSize(p)
    var done = false
    let hook: Progress = proc (walked, total: int64): bool =
      if not done:
        cut(p, size div 4)
        done = true
      true
    try:
      var f = openSeismic(p, keys, hook, OpenOptions(verify: verify))
      f.close()
    except IOError as e:
      result = "cut short while it was opened" in e.msg
    doAssert done
  for (verify, keys) in [(vfFull, false), (vfSampled, true), (vfFull, true)]:
    doAssert openWhileCut(fresh("survey.sgy"), verify, keys), $verify & " " & $keys

block editor:
  # Edits of a file cut short: the one that meets the cut fails, every later
  # one is refused, and `close` raises `IOError`.
  let p = fresh("survey.sgy")
  var ed = openEditor(p, tmp / "survey.edits.nif")
  let last = ed.file.len - 1
  cut(p, getFileSize(p) div 2)
  doAssert not ed.setTraceField(last, "trace.sourceX", toFieldValue(5))
  doAssert ed.log.len >= 1 and "cut short" in ed.log[ed.log.len - 1].msg, $ed.log
  doAssert not ed.setTraceField(0, "trace.sourceX", toFieldValue(5))
  doAssert "cut short" in ed.log[ed.log.len - 1].msg
  doAssertRaises(IOError): ed.close()

block record_reader:
  # A streaming read of a `MemFileSource` stops at the cut, as at the end
  # of a short file (a fatal `truncated`).
  let p = fresh("survey.sgy")
  var src = openMemFileSource(p)
  var r = openSegy(src)
  var tr: SegyTrace
  doAssert r.readTrace(tr)
  let size = getFileSize(p) div 2
  cut(p, size)
  var n = 1
  while r.readTrace(tr): inc n
  # The traces wholly before the cut, and no trace made of the zeros past it.
  var whole = 0
  block:
    var f = openSeismic(fresh("survey.sgy"))
    for i in 0 ..< f.len:
      if f.sampleEnd(i) <= size: inc whole
    f.close()
  doAssert n == whole and src.readable == size and src.cutShort, $n & " " & $whole
  doAssert r.log.isFatal
  src.close()

block conversions_of_a_cut_source:
  # Conversions that map their source (SEG-2 input; any input to SEG-2): a
  # cut while they write gives a fatal diagnostic, and nothing is written.
  let big = tmp / "big.sg2"
  var o2 = ConvertOptions(target: skSeg2)
  doAssert not convertFile(demoDir() / "survey.sgy", big, o2).isFatal # 1.6 MB
  proc convertWhileCut(src, dst: string, opts: ConvertOptions): DiagLog =
    let size = getFileSize(src)
    var done = false
    let hook: Progress = proc (walked, total: int64): bool =
      # Past the open (its walk is the first half): the writing pass.
      if not done and walked * 4 > total * 3:
        cut(src, size div 3)
        done = true
      true
    result = convertFile(src, dst, opts, hook)
    doAssert done, dst
  var od = ConvertOptions(target: skSegd)
  od.segd.revision = SegdRevision(major: 3, minor: 0)
  for (src, dst, opts) in [(big, "a.sgy", ConvertOptions()), (big, "b.sgd", od)]:
    let p = tmp / ("cut_" & dst)
    copyFile(src, p)
    let log = convertWhileCut(p, tmp / dst, opts)
    doAssert log.isFatal and "cut short" in $log and not fileExists(tmp / dst), dst & ": " & $log
  block:
    let p = tmp / "cut_survey.sgy"
    let big2 = tmp / "big2.sgy"
    doAssert not convertFile(big, big2, ConvertOptions()).isFatal # back to SEG-Y, 1.6 MB
    copyFile(big2, p)
    let log = convertWhileCut(p, tmp / "c.sg2", o2)
    doAssert log.isFatal and "cut short" in $log and not fileExists(tmp / "c.sg2"), $log

block a_fault_outside_parseSEG_still_ends_the_process:
  # The handler only takes faults in parseSEG's maps; any other goes to the
  # handler before it (here the default, or Nim's: the process ends).
  let child = startProcess(getAppFilename(), args = ["foreign"],
    options = {poStdErrToStdOut})
  let t0 = epochTime()
  while child.running and epochTime() - t0 < 30: sleep(20)
  if child.running:
    child.kill()
    doAssert false, "the foreign fault loops instead of ending the process"
  let output = child.outputStream.readAll()
  let code = child.waitForExit()
  child.close()
  doAssert code != 0 and "survived" notin output, $code & ": " & output

echo "tcutshort: ok"
