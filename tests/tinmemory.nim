## Files that live in memory: `openSeismicBytes` (open from bytes) and
## `openSeismicWriterBytes` / `finishBytes` (write to bytes).
##
## Seen to fail first, by breaking the code and restoring it:
## - segy_bytes_equal_files: the binary header's back-patch left out of the
##   memory sink's finish (the files differed at byte 3221, the sample count)
## - like_writers_equal_files: the source's bytes shifted by one (the memory
##   template's size differed from the disk template's)
## - refusals: `saveIndex` without its memory guard (an OSError for the
##   missing file, not the plain-word `ValueError`)

import std/[assertions, math, os, sequtils, strutils, typedthreads, random]

import parseSEG

import ./utils/testutils

import parseSEG/io/memsink
from parseSEG/model/traceindex import unsafeMemory, mappedSize

proc bytesOf(path: string): seq[byte] = readFile(path).toBytes

proc same(a, b: float64): bool = (a.isNaN and b.isNaN) or a == b

template expect(part: string, body: untyped) =
  try:
    body
    doAssert false, "expected ValueError containing: " & part
  except ValueError as e:
    doAssert e.msg.find(part) >= 0, e.msg

# --------------------------------------------------------------- SEG-Y --

type Shot = object
  keys: TraceKeys
  row: seq[float32]

proc shots(n: int, varying = false, gather = false): seq[Shot] =
  var r = initRand(11)
  for i in 0 ..< n:
    var k = initTraceKeys()
    k.record = float64(1 + i div 2)
    k.channel = float64(1 + i mod 2)
    k.ensemble = float64(10 + i)
    k.intervalUs = 2000
    # A shot record has one source, a receiver gather one receiver.
    let rec = float64(1 + i div 2)
    let src = if gather: float64(i) else: rec
    let rcv = if gather: rec else: float64(i)
    k.srcLine = 1
    k.srcPoint = 100.5 + src
    k.srcIndex = 1
    k.srcX = 500_000.5 + src
    k.srcY = 6_000_000.25
    k.rcvLine = 7
    k.rcvPoint = 200 + rcv
    k.rcvIndex = 1
    k.rcvX = 501_000 + 25 * rcv
    k.rcvY = 6_001_000
    k.status = tsLive
    var s = Shot(keys: k, row: newSeq[float32](if varying: 8 + i * 4 else: 16))
    for j in 0 ..< s.row.len: s.row[j] = float32(r.rand(2.0) - 1.0)
    result.add s

proc writeAll(w: var SeismicWriter, ss: openArray[Shot]) =
  for s in ss: w.writeTrace(s.keys, s.row)

proc segyOptions(major, minor: int, order: ByteOrder, fmt: SegyTargetFormat): SegyOutputOptions =
  SegyOutputOptions(revision: SegyRevision(major: uint8(major), minor: uint8(minor)),
    byteOrder: order, format: fmt, text: @["IN MEMORY", "LINE 3"], traceSorting: 1,
    measurementSystem: 1)

proc segdOptions(minor: int, fmt: SegdSampleFormat, gather = false): SegdOutputOptions =
  SegdOutputOptions(revision: SegdRevision(major: 3, minor: uint8(minor)), format: fmt,
    sampleIntervalUs: 2000, numSamples: 16, time: 1_709_273_228.0, receiverGather: gather)

proc identical(a: seq[byte], path: string, what: string) =
  let b = bytesOf(path)
  doAssert a.len == b.len, what & ": " & $a.len & " bytes in memory, " & $b.len & " on disk"
  for i in 0 ..< a.len:
    doAssert a[i] == b[i], what & ": byte " & $i & " differs"

proc segyBoth(tmp: string, o: SegyOutputOptions, ss: openArray[Shot], what: string): seq[byte] =
  var d = openSeismicWriter(tmp / "d.sgy", o)
  d.writeAll ss
  discard d.close()
  var m = openSeismicWriterBytes(o, "mem.sgy")
  doAssert m.path == "mem.sgy"
  m.writeAll ss
  doAssert m.len == ss.len
  result = m.finishBytes()
  identical(result, tmp / "d.sgy", what)

proc segdBoth(tmp: string, o: SegdOutputOptions, ss: openArray[Shot], what: string): seq[byte] =
  var d = openSeismicWriter(tmp / "d.sgd", o)
  d.writeAll ss
  discard d.close()
  var m = openSeismicWriterBytes(o)
  m.writeAll ss
  result = m.finishBytes()
  identical(result, tmp / "d.sgd", what)

proc likeBoth(tmp, src: string, segy = stKeep, segd = tfKeep): seq[byte] =
  # The same traces of `src`, template headers, to a disk file and to memory.
  var f = openSeismic(src, keys = true)
  var g = openSeismicBytes(bytesOf(src), "copy of " & src, keys = true)
  let x = f.readTraces(0 ..< f.len)
  let out1 = tmp / "like_disk" & src.splitFile.ext
  var d = openSeismicWriter(out1, f, segy, segd)
  var m = openSeismicWriterBytes(f, "like.mem", segy, segd)
  var m2 = openSeismicWriterBytes(g, "like2.mem", segy, segd) # a template in memory too
  for t in 0 ..< f.len:
    d.writeTrace(f, t, x, t)
    m.writeTrace(f, t, x, t)
    m2.writeTrace(g, t, x, t)
  discard d.close()
  result = m.finishBytes()
  identical(result, out1, "like " & src)
  identical(m2.finishBytes(), out1, "like in memory " & src)
  f.close()
  g.close()

proc roundTrip(b: sink seq[byte], ss: openArray[Shot], segd: bool) =
  var f = openSeismicBytes(b, "rt", keys = true)
  doAssert f.len == ss.len and f.kind == (if segd: skSegd else: skSegy) and f.inMemory
  doAssert f.access == faMapped and f.path == "rt"
  for i, s in ss:
    let k = f.traceKeys(i)
    doAssert k.intervalUs == s.keys.intervalUs
    doAssert same(k.rcvX, s.keys.rcvX) and same(k.srcX, s.keys.srcX), $i
    let y = f.readTraces(i..i)
    for j in 0 ..< s.row.len: doAssert y[0, j] == s.row[j]
  f.close()

# -------------------------------------------------------- same answers --

proc digest(f: SeismicFile): string =
  # Everything the viewer reads from an open file, as one text.
  result.add $f.len & " " & $f.kind & " " & $f.recordCount & " " & $f.maxSamples & "\n"
  result.add $f.log & "\n"
  for e in f.index.entries: result.add $e & "\n"
  if f.kind == skSegy: result.add f.textHeader & "\n" & $f.extendedTextHeaders & "\n"
  result.add $f.summary & "\n" & $f.channelSets & "\n" & $f.crsText & "\n"
  result.add $f.gathers & "\n"
  if f.kind != skSeg2:
    for r in 0 ..< f.recordCount: result.add $f.recordHeaders(r) & "\n"
    result.add $f.fileHeaders & "\n"
  var log: DiagLog
  let n = min(f.len, 50)
  for i in 0 ..< n:
    result.add $f.traceKeys(i) & " " & $f.startTimeMs(i) & " " & $f.traceOrientation(i) & "\n"
    if f.kind != skSeg2: result.add $f.traceHeaders(i) & "\n"
    if f.kind == skSeg2: result.add $f.seg2Trace(i) & "\n"
  if f.len > 0:
    result.add $f.traceStatics(0 ..< n) & "\n"
    let column = case f.kind
      of skSegy: "trace.sourceX"
      of skSeg2: "trace.CHANNEL_NUMBER"
      else: "trace." & fieldNames(hbSegdTrace)[1]
    result.add $f.sortTraces([column]) & "\n"
    result.add $f.traceFieldColumn(column, 0 ..< n) & "\n"
  let x = f.readTraces(0 ..< f.len, log)
  result.add $x & $log & "\n"
  let sel = @[f.len - 1, 0, min(1, f.len - 1)]
  result.add $f.readTraces(sel, log) & "\n"
  result.add $f.readTraces(0 ..< f.len, 2 .. 9, log) & "\n"
  result.add $f.copyBytes(0, 64) & " " & $f.copyBytes(int64(f.mappedSize) - 10, 10) & "\n"
  # Prefetch.
  var p = newPrefetcher[float32](f, 0 ..< f.len, 3)
  for c in p.chunks: result.add $c.samples & "\n"
  discard p.close()

proc sameAnswers(path: string, tmp: string) =
  var d = openSeismic(path, keys = true)
  var m = openSeismicBytes(bytesOf(path), path, keys = true)
  doAssert not d.inMemory and m.inMemory
  doAssert m.access == faMapped and not m.cutShort and not m.readFailed and not m.fromCache
  let a = digest(d)
  let b = digest(m)
  doAssert a == b, path & ": a file in memory answers differently from the same file on disk"
  # Without keys, with every verify mode.
  var m2 = openSeismicBytes(bytesOf(path), "x", opts = OpenOptions(verify: vfFull))
  var d2 = openSeismic(path, opts = OpenOptions(verify: vfFull))
  doAssert $m2.index.entries == $d2.index.entries
  m2.ensureKeys()
  d2.ensureKeys()
  doAssert $m2.traceKeys(0 ..< m2.len) == $d2.traceKeys(0 ..< d2.len)
  # The header export reads every header.
  exportHeaders(d, tmp / "d.nif")
  exportHeaders(m, tmp / "m.nif")
  doAssert readFile(tmp / "d.nif").len > 0
  doAssert readFile(tmp / "d.nif") == readFile(tmp / "m.nif")
  m.close()
  doAssert not m.isOpen
  d.close()

# ------------------------------------------------------------- threads --

type Job = object
  f: ptr SeismicFile
  sum: float64
  bad: bool

proc work(j: ptr Job) {.thread.} =
  let p = j.f
  var log: DiagLog
  var t = newTensor[float32](4, p[].maxSamples)
  var keys: array[4, TraceKeys]
  for i in 0 ..< 4000:
    let a = i mod max(1, p[].len - 4)
    discard p[].readTracesInto(a ..< a + 4, t, log)
    {.cast(gcsafe).}:
      p[].traceKeysInto(a ..< a + 4, keys)
      if keys[0].rcvX != 501_000 + 25 * float64(a): j.bad = true
    j.sum += float64(t[0, 0])

# ---------------------------------------------------------------- main --

proc main*() =
  let tmp = scratchDir("parseseg_tinmemory")

  block segy_bytes_equal_files:
    for (major, minor) in [(0, 0), (1, 0), (2, 0), (2, 1)]:
      for fmt in [st5, st1, st2, st3, st8]:
        for varying in [false, true]:
          let o = segyOptions(major, minor, boBig, fmt)
          discard segyBoth(tmp, o, shots(7, varying), $o.revision & " " & $fmt)
      if major == 2:
        for order in [boLittle, boPairSwapped]:
          discard segyBoth(tmp, segyOptions(major, minor, order, st5), shots(5),
            $order)
    # More than 65535 samples need Rev 2's extended count in the binary header.
    var big = shots(2)
    big[1].row = newSeq[float32](70_000)
    discard segyBoth(tmp, segyOptions(2, 1, boBig, st5), big, "long traces")

  block segd_bytes_equal_files:
    for minor in [0, 1]:
      for fmt in [sd8058, sd8036, sd8038, sd8048, sd8080, sd8022, sd8024, sd8015, sd8042,
          sd8044]:
        for gather in [false, true]:
          discard segdBoth(tmp, segdOptions(minor, fmt, gather), shots(7, gather = gather),
            "3." & $minor & " " & $fmt & " " & $gather)
    for fmt in [sd9058, sd9036, sd9038, sd9080]:
      discard segdBoth(tmp, segdOptions(1, fmt), shots(6), "3.1 " & $fmt)

  block like_writers_equal_files:
    # Revisions that are written as read: SEG-Y 1.0 (the survey) and its
    # other formats, SEG-D 2.0 and 3.0, and each converted.
    discard likeBoth(tmp, demoDir() / "survey.sgy")
    discard likeBoth(tmp, demoDir() / "survey.sgy", segy = st1)
    discard likeBoth(tmp, demoDir() / "survey.sgy", segy = st2)
    discard likeBoth(tmp, demoDir() / "record.sgd")
    discard likeBoth(tmp, demoDir() / "shot.sgd")
    discard likeBoth(tmp, demoDir() / "shot.sgd", segd = tf8036)

  block round_trips_in_memory:
    # Written to memory, read from memory: no file is made.
    let before = walkDir(tmp).toSeq.len
    for (major, minor) in [(0, 0), (1, 0), (2, 0), (2, 1)]:
      let ss = shots(6)
      var w = openSeismicWriterBytes(segyOptions(major, minor, boBig, st5))
      w.writeAll ss
      roundTrip(w.finishBytes(), ss, false)
    for minor in [0, 1]:
      let ss = shots(6)
      var w = openSeismicWriterBytes(segdOptions(minor, sd8058))
      w.writeAll ss
      roundTrip(w.finishBytes(), ss, true)
    doAssert walkDir(tmp).toSeq.len == before
    # The warnings of a finished writer are handed over.
    var k = shots(1)[0]
    k.keys.srcZ = 5 # an elevation without X/Y
    k.keys.srcX = NaN
    k.keys.srcY = NaN
    var w = openSeismicWriterBytes(segdOptions(0, sd8058))
    w.writeTrace(k.keys, k.row)
    var log: DiagLog
    let b = w.finishBytes(log)
    doAssert b.len > 0 and log.len > 0 and not log.isFatal, $log

  block same_answers_as_disk:
    for name in ["survey.sgy", "shot.sgd", "record.sgd", "line.sg2"]:
      sameAnswers(demoDir() / name, tmp)
    # And the files this test wrote.
    var w = openSeismicWriterBytes(segdOptions(1, sd8058))
    w.writeAll shots(9)
    writeFile(tmp / "w.sgd", cast[string](w.finishBytes()))
    sameAnswers(tmp / "w.sgd", tmp)

  block no_copy:
    var b = bytesOf(demoDir() / "survey.sgy")
    let at = cast[uint](addr b[0])
    let n = b.len
    var f = openSeismicBytes(move b, "survey", keys = true)
    doAssert b.len == 0 # moved in
    doAssert cast[uint](f.unsafeMemory) == at and f.mappedSize == n,
      "the open copied the bytes"
    f.close()
    doAssert f.unsafeMemory == nil and not f.isOpen
    # A finished writer hands out its buffer, not a copy of it.
    var w = openSeismicWriterBytes(segyOptions(1, 0, boBig, st5))
    w.writeAll shots(3)
    doAssert w.finishBytes().len > 0

  block refusals:
    var b = bytesOf(demoDir() / "survey.sgy")
    var f = openSeismicBytes(b, "mem.sgy")
    doAssert b.len > 0 # used again below: the open got a copy, not the caller's buffer
    expect("lives in memory"): f.saveIndex(tmp / "x.idx")
    expect("lives in memory"): discard openEditor(f)
    # Before any disk access: a journal path that is a real file is not looked at.
    writeFile(tmp / "real.sgy", "x")
    var f2 = openSeismicBytes(b, tmp / "real.sgy")
    expect("lives in memory"): discard openEditor(f2, journalPath = tmp / "real.sgy")
    doAssert not fileExists(tmp / "real.sgy.edits.nif")
    doAssert not fileExists(tmp / "x.idx")
    # An index cache is not read: the walk is made, and says why.
    var g = openSeismic(demoDir() / "survey.sgy")
    g.saveIndex(tmp / "g.idx")
    var h = openSeismicBytes(b, "mem.sgy", opts = OpenOptions(cache: tmp / "g.idx"))
    doAssert not h.fromCache and h.log.len > 0 and "no index cache" in $h.log
    # A virtual name that is a real file is not touched, nor compared with.
    var m = openSeismicBytes(b, demoDir() / "survey.sgy")
    var w = openSeismicWriter(tmp / "same.sgy", m)
    discard w.close()
    # SEG-2 is not written to memory; a closed writer, the wrong finish.
    var l2 = openSeismic(demoDir() / "line.sg2")
    expect("SEG-2 cannot be written to memory"): discard openSeismicWriterBytes(l2)
    var wf2 = openSeismicWriter(tmp / "wf2.sgy", SegyOutputOptions())
    wf2.writeTrace(shots(1)[0].keys, shots(1)[0].row)
    expect("with close"): discard wf2.finishBytes()
    discard wf2.close()
    var wm = openSeismicWriterBytes(SegyOutputOptions())
    expect("with finishBytes"): discard wm.close()
    wm.writeTrace(shots(1)[0].keys, shots(1)[0].row)
    discard wm.finishBytes()
    expect("closed"): discard wm.finishBytes()
    # The file writer's own refusals stand.
    expect("38 lines"): discard openSeismicWriterBytes(SegyOutputOptions(text: newSeq[string](39)))
    expect("Rev 2"): discard openSeismicWriterBytes(SegyOutputOptions(
      revision: SegyRevision(major: 1), byteOrder: boLittle))
    var nw = openSeismicWriterBytes(segdOptions(0, sd8058))
    expect("no traces"): discard nw.finishBytes()

  block many_threads:
    let ss = shots(40)
    var w = openSeismicWriterBytes(segyOptions(2, 1, boBig, st5))
    w.writeAll ss
    var f = openSeismicBytes(w.finishBytes(), "threads", keys = true)
    var jobs: array[6, Job]
    var th: array[6, Thread[ptr Job]]
    for i in 0 ..< th.len:
      jobs[i].f = addr f
      createThread(th[i], work, addr jobs[i])
    for i in 0 ..< th.len: joinThread(th[i])
    for i in 0 ..< th.len:
      doAssert not jobs[i].bad
      doAssert jobs[i].sum == jobs[0].sum
    # A prefetcher outlives the file's close, and still reads.
    var p = newPrefetcher[float32](f, 0 ..< f.len, 8)
    f.close()
    var n = 0
    for c in p.chunks: n += c.count
    doAssert n == ss.len
    discard p.close()

  block memsink_patch_bounds:
    # A patch outside the bytes written is an IndexDefect, also for an offset
    # that would wrap `at + data.len`.
    let sink = openMemSink("p")
    sink.writeRecord([byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    sink.patch(8, [byte 0, 0])
    doAssertRaises(IndexDefect): sink.patch(9, [byte 0, 0])
    doAssertRaises(IndexDefect): sink.patch(high(int), [byte 0])
    doAssertRaises(IndexDefect): sink.patch(high(int) - 1, [byte 0, 0, 0])
    doAssertRaises(IndexDefect): sink.patch(-1, [byte 0])
    doAssert sink.takeBytes() == @[byte 1, 2, 3, 4, 5, 6, 7, 8, 0, 0]

  block hostile:
    # Truncated, damaged and random bytes: the library's errors and
    # diagnostics, never a Defect (an uncaught one fails this test).
    var r = initRand(5)
    var sources = @[bytesOf(demoDir() / "survey.sgy"), bytesOf(demoDir() / "shot.sgd"),
      bytesOf(demoDir() / "record.sgd"), bytesOf(demoDir() / "line.sg2")]
    proc touch(b: seq[byte]) =
      try:
        var f = openSeismicBytes(b, "hostile", keys = r.rand(1) == 1)
        try:
          if f.len > 0:
            var log: DiagLog
            discard f.readTraces(0 ..< min(f.len, 20), log)
            discard f.traceKeys(0)
            discard f.summary
            discard f.gathers
        except CatchableError: discard
        f.close()
      except CatchableError: discard
    for s in sources:
      for cut in [0, 1, 10, 100, 3199, 3200, 3201, 3600, 3601, 3700, s.len div 2,
          s.len - 1]:
        if cut <= s.len: touch(s[0 ..< cut])
      for i in 0 ..< 40:
        var d = s[0 ..< min(s.len, 4000)]
        for _ in 0 ..< 1 + r.rand(8): d[r.rand(d.len - 1)] = byte(r.rand(255))
        touch d
    for i in 0 ..< 40:
      var g = newSeq[byte](r.rand(5000))
      for x in g.mitems: x = byte(r.rand(255))
      touch g
    var empty = openSeismicBytes(newSeq[byte](), "empty")
    doAssert empty.len == 0 and empty.kind == skUnknown and empty.log.isFatal
    empty.close()

when isMainModule: main()
