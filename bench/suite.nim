## The parseSEG benchmark suite (task 13.2). Reads the files `bench/gen`
## writes and prints Markdown tables (also saved as
## `<data dir>/results-<scale>.md`).
##
##   suite [--scale=small|full] [--dir=DIR] [section ...]
##
## Sections: `baseline`, `index`, `decode`, `latency`, `threads`, `prefetch`,
## `write`, `abi` (C and Python); all of them when none is named. `nim bench` builds this with the
## release flags (`-d:danger`, `-march=native`) and runs it; see
## `docs/benchmarks.md` for the method.
##
## Warm runs read the file once first so it is in the page cache; cold runs
## drop the file's pages first (`posix_fadvise(POSIX_FADV_DONTNEED)`, after
## unmapping them), so they read from the disk.

import std/[os, strformat, strutils, random, parseopt, monotimes, times, math, sequtils,
  typedthreads, memfiles, osproc]
import parseSEG
import parseSEG/model/traceindex as ti
import ./[specs, harness]

var
  dir = dataDir()
  sc = scale()
  rep: Report
  warmOnly = getEnv("PARSESEG_BENCH_WARM_ONLY") == "1"
    ## Skip the cold (disk-bound) runs, e.g. for before/after builds.

proc pathOf(name: string): string = find(name).path(dir, sc)

proc present(name: string): bool =
  let s = find(name)
  s.traces(sc) > 0 and fileExists(s.path(dir, sc))

proc dropCache(f: SeismicFile) =
  ## Cold state for an open file: unmap its pages here, drop them from the cache.
  dropMapping(ti.unsafeMemory(f), int(ti.mappedSize(f)))
  evict(f.path)

proc samplesOf(f: SeismicFile): float =
  var n = 0
  for e in f.index.entries: n += int(e.numSamples)
  float(n)

func formatName(s: Spec): string =
  case s.container
  of cSegy:
    let names = ["", "IBM float", "int32", "int16", "", "IEEE float"]
    "SEG-Y " & $s.format & " (" & names[s.format] & (if s.littleEndian: ", LE" else: "") & ")"
  of cSegd21: "SEG-D 2.1 " & $s.format
  of cSegd30: "SEG-D 3.0 " & $s.format
  of cSeg2: "SEG-2 " & $s.format & " (float32, LE)"

# --------------------------------------------------------------- baseline --

var memcpyRate, readRate: float # GB/s, single thread (for the decode table)

proc copyWorker(a: (ptr UncheckedArray[byte], ptr UncheckedArray[byte], int)) {.thread.} =
  copyMem(a[1], a[0], a[2])

proc baseline() =
  rep.heading "Baselines: memory and disk on this machine"
  const N = 1 shl 30
  var src = newSeq[byte](N)
  var dst = newSeq[byte](N)
  for i in countup(0, N - 1, 4096): src[i] = byte(i shr 12)
  copyMem(addr dst[0], addr src[0], N) # fault the pages in
  let tCopy = best(5): copyMem(addr dst[0], addr src[0], N)
  var acc = 0'u64
  let words = cast[ptr UncheckedArray[uint64]](addr src[0])
  let tRead = best(5):
    var s = 0'u64
    for i in 0..<N div 8: s += words[i]
    acc += s
  memcpyRate = N / tCopy / 1e9
  readRate = N / tRead / 1e9
  rep.table ["what", "GB/s"]
  rep.row ["memcpy 1 GiB, 1 thread (bytes copied)", gbps(N, tCopy)]
  rep.row ["sum of uint64 over 1 GiB, 1 thread (bytes read)", gbps(N, tRead)]
  for threads in [4, 16, 32]:
    let part = N div threads
    var th = newSeq[Thread[(ptr UncheckedArray[byte], ptr UncheckedArray[byte], int)]](threads)
    let t = best(3):
      for k in 0..<threads:
        createThread(th[k], copyWorker, (cast[ptr UncheckedArray[byte]](addr src[k * part]),
          cast[ptr UncheckedArray[byte]](addr dst[k * part]), part))
      joinThreads(th)
    rep.row [&"memcpy 1 GiB, {threads} threads", gbps(N, t)]
  src = @[]
  dst = @[]
  if present("y-ieee"):
    let p = pathOf("y-ieee")
    let size = float(getFileSize(p))
    proc sumMapped(p: string): uint64 =
      var m = memfiles.open(p)
      defer: m.close()
      let w = cast[ptr UncheckedArray[uint64]](m.mem)
      for i in 0..<m.size div 8: result += w[i]
    warm(p)
    let tMapWarm = best(3): acc += sumMapped(p)
    evict(p)
    let tMapCold = timed: acc += sumMapped(p)
    evict(p)
    let tReadCold = timed: warm(p)
    let tReadWarm = best(3): warm(p)
    rep.row ["y-ieee, warm: mmap + sum (fresh map each run)", gbps(size, tMapWarm)]
    rep.row ["y-ieee, warm: read() 8 MiB blocks", gbps(size, tReadWarm)]
    rep.row ["y-ieee, cold: mmap + sum", gbps(size, tMapCold)]
    rep.row ["y-ieee, cold: read() 8 MiB blocks", gbps(size, tReadCold)]
  if acc == 42: echo "" # keep the sums

# ------------------------------------------------------------------ index --

proc index() =
  rep.heading "Index build and keys (openSeismic)"
  rep.line "Cold: the file's pages dropped first. Warm: best of 3 with the file cached. " &
    "Memory: managed heap growth (`getOccupiedMem`) of the open file, per trace."
  rep.line()
  rep.table ["file", "traces", "GB", "cold open ms", "cold first trace ms", "warm open ms",
    "ns/trace", "keys ms", "ns/trace keys", "heap B/trace", "keys heap B/trace", "gathers ms"]
  for name in ["y-ieee", "d21-8058", "y-ieee-1m", "d21-8058-1m", "y-ieee-10m", "d21-8058-10m",
      "y-ieee-big"]:
    if not present(name): continue
    let p = pathOf(name)
    let size = float(getFileSize(p))
    if warmOnly and find(name).role == rBig: continue
    var n = 0
    var cells: seq[string]
    if warmOnly:
      var f = openSeismic(p)
      n = f.len
      f.close()
      cells = @[name, $n, gb(size), "-", "-"]
    else:
      evict(p)
      let tCold = timed:
        var f = openSeismic(p)
        n = f.len
        f.close()
      evict(p)
      let tFirst = timed:
        var f = openSeismic(p)
        discard f.readTraces(0..0)
        f.close()
      cells = @[name, $n, gb(size), ms(tCold), ms(tFirst)]
    if find(name).role == rBig:
      cells.add ["-", "-", "-", "-", "-", "-", "-"] # larger than the free page cache
    else:
      warm(p)
      let runs = if n >= 5_000_000: 2 else: 3
      let tWarm = best(runs):
        var f = openSeismic(p)
        f.close()
      let tKeys = best(runs):
        var f = openSeismic(p, keys = true)
        f.close()
      let m0 = getOccupiedMem()
      var f = openSeismic(p)
      let m1 = getOccupiedMem()
      f.close()
      f = openSeismic(p, keys = true)
      let m2 = getOccupiedMem()
      var gs: seq[Gather]
      let tGathers = timed: gs = f.gathers
      f.close()
      cells.add [ms(tWarm), &"{tWarm / float(n) * 1e9:.0f}", ms(tKeys),
        &"{tKeys / float(n) * 1e9:.0f}", &"{float(m1 - m0) / float(n):.1f}",
        &"{float(m2 - m1) / float(n):.1f}", &"{ms(tGathers)} ({gs.len})"]
    rep.row cells

# ----------------------------------------------------------------- decode --

const ChunkTraces = 1000

proc readAll[T](f: SeismicFile, t: var Tensor[T]): int =
  var i = 0
  while i < f.len:
    let n = min(ChunkTraces, f.len - i)
    result += f.readTracesInto(i ..< i + n, t)
    i += n

proc decode() =
  rep.heading "Sequential decode throughput (readTracesInto, 1000-trace chunks, 1 thread)"
  rep.line &"GB/s of file bytes. First pass: right after `openSeismic` (pages the index walk " &
    "did not touch still fault in); mapped: best of 3 later passes. memcpy baseline: " &
    &"{memcpyRate:.1f} GB/s, read baseline {readRate:.1f} GB/s."
  rep.line()
  rep.table ["file", "format", "GB", "cold GB/s", "first pass GB/s", "mapped GB/s",
    "Msamples/s", "% of memcpy", "float64 GB/s"]
  for s in benchFiles:
    if s.role != rFormat or not present(s.name): continue
    let p = s.path(dir, sc)
    let size = float(getFileSize(p))
    var f = openSeismic(p)
    doAssert f.log.count(sevError) + f.log.count(sevFatal) == 0, s.name & ": " & $f.log[0]
    let samples = f.samplesOf
    var t = newTraceTensor[float32](ChunkTraces, f.maxSamples)
    var cold = "-"
    if not warmOnly:
      f.dropCache()
      let tCold = timed: doAssert f.readAll(t) == 0
      cold = gbps(size, tCold)
    f.close()
    warm(p)
    f = openSeismic(p)
    let tFirst = timed: doAssert f.readAll(t) == 0
    let tMapped = best(3): doAssert f.readAll(t) == 0
    var t64 = newTraceTensor[float64](ChunkTraces, f.maxSamples)
    let t64Mapped = best(3): doAssert f.readAll(t64) == 0
    f.close()
    rep.row [s.name, formatName(s), gb(size), cold, gbps(size, tFirst),
      gbps(size, tMapped), msps(samples, tMapped),
      &"{size / tMapped / 1e9 / memcpyRate * 100:.0f}", gbps(size, t64Mapped)]
  if present("y-ieee-big") and not warmOnly:
    let p = pathOf("y-ieee-big")
    let size = float(getFileSize(p))
    evict(p)
    var f = openSeismic(p)
    var t = newTraceTensor[float32](ChunkTraces, f.maxSamples)
    f.dropCache()
    let tCold = timed: doAssert f.readAll(t) == 0
    f.close()
    rep.line()
    rep.line &"y-ieee-big ({gb(size)} GB, larger than the free page cache), cold, " &
      &"1 thread: {gbps(size, tCold)} GB/s."

# ---------------------------------------------------------------- latency --

template sample(xs: var seq[float], body: untyped) =
  xs.add timed(body)

proc row(r: var Report, what: string, xs: openArray[float]) =
  let s = stats(xs)
  r.row [what, $s.n, us(s.p50), us(s.p90), us(s.p99), us(s.max)]

proc latency(name: string) =
  if not present(name): return
  let p = pathOf(name)
  warm(p)
  var f = openSeismic(p)
  let n = f.len
  let ns = f.maxSamples
  let per = find(name).perRecord
  var r = initRand(13)
  rep.heading &"Viewer latency on {name} ({n} traces of {ns} samples)"
  rep.line "Warm: file cached (first touch of a page in this map still faults it in). " &
    "Cold: the file's pages dropped from the cache before the run (`dropCache`)."
  rep.line()
  rep.table ["operation", "runs", "p50 µs", "p90 µs", "p99 µs", "max µs"]
  var one = newTraceTensor[float32](1, ns)
  var xs: seq[float]
  for _ in 0..<20_000:
    let i = r.rand(n - 1)
    xs.sample: discard f.readTracesInto(i..i, one)
  rep.row("random single trace, warm (readTracesInto)", xs)
  xs.setLen 0
  for _ in 0..<5_000:
    let i = r.rand(n - 1)
    xs.sample: discard f.readTraces(i..i)
  rep.row("random single trace, warm (readTraces, new tensor)", xs)
  var shot = newTraceTensor[float32](per, ns)
  xs.setLen 0
  for _ in 0..<500:
    let g = r.rand(n div per - 1)
    xs.sample: discard f.readTracesInto(g * per ..< (g + 1) * per, shot)
  rep.row(&"shot gather ({per} consecutive traces), warm", xs)
  # A receiver gather: the same channel of every shot (strided traces).
  let shots = min(n div per, 1000)
  var rcv = newTraceTensor[float32](shots, ns)
  xs.setLen 0
  for _ in 0..<200:
    let ch = r.rand(per - 1)
    let sel = toSeq(0..<shots).mapIt(it * per + ch)
    xs.sample: discard f.readTracesInto(sel, rcv)
  rep.row(&"receiver gather ({shots} traces {per} apart), warm", xs)
  # A time window across many traces: samples 100..199 of 10 000 traces. The
  # API decodes whole traces (the tensor holds samples 0 ..< 200 here), so
  # the window costs the traces' first 200 samples.
  let wt = min(10_000, n)
  var win = newTraceTensor[float32](wt, min(200, ns))
  xs.setLen 0
  for _ in 0..<100:
    let a = r.rand(n - wt)
    xs.sample: discard f.readTracesInto(a ..< a + wt, win)
  rep.row(&"window: samples 0..199 of {wt} traces, warm", xs)
  var full = newTraceTensor[float32](wt, ns)
  xs.setLen 0
  for _ in 0..<100:
    let a = r.rand(n - wt)
    xs.sample: discard f.readTracesInto(a ..< a + wt, full)
  rep.row(&"{wt} whole traces, warm", xs)
  xs.setLen 0
  for _ in 0..<5_000:
    let i = r.rand(n - 1)
    xs.sample: discard f.traceHeaders(i)
  rep.row("trace header listing (traceHeaders), warm", xs)
  let field = if f.kind == skSegy: "trace.sourceX" else: "ext1.receiverPointNumber"
  xs.setLen 0
  for _ in 0..<100:
    let a = r.rand(n - 1000)
    xs.sample:
      for i in a ..< a + 1000: discard f.traceField(i, field)
  rep.row(&"header column: {field} of 1000 traces, warm", xs)
  # Cold: drop the pages, then each run touches pages no earlier run touched.
  f.dropCache()
  xs.setLen 0
  for _ in 0..<300:
    let i = r.rand(n - 1)
    xs.sample: discard f.readTracesInto(i..i, one)
  rep.row("random single trace, cold", xs)
  f.dropCache()
  xs.setLen 0
  for _ in 0..<50:
    let g = r.rand(n div per - 1)
    xs.sample: discard f.readTracesInto(g * per ..< (g + 1) * per, shot)
  rep.row(&"shot gather ({per} traces), cold", xs)
  f.dropCache()
  xs.setLen 0
  for _ in 0..<20:
    let ch = r.rand(per - 1)
    let sel = toSeq(0..<shots).mapIt(it * per + ch)
    xs.sample: discard f.readTracesInto(sel, rcv)
  rep.row(&"receiver gather ({shots} traces), cold", xs)
  f.dropCache()
  xs.setLen 0
  for _ in 0..<300:
    let i = r.rand(n - 1)
    xs.sample: discard f.traceHeaders(i)
  rep.row("trace header listing, cold", xs)
  f.close()

proc latency() =
  latency("y-ieee-10m")
  latency("d21-8058-10m")

# ---------------------------------------------------------------- threads --

type
  Job = object
    f: ptr SeismicFile
    first, stop: int
    failed: int

proc readRange(j: ptr Job) {.thread.} =
  var t = newTraceTensor[float32](256, j.f[].maxSamples)
  var i = j.first
  while i < j.stop:
    let n = min(256, j.stop - i)
    j.failed += j.f[].readTracesInto(i ..< i + n, t)
    i += n

proc parallelRead(f: var SeismicFile, threads: int): float =
  var jobs = newSeq[Job](threads)
  var th = newSeq[Thread[ptr Job]](threads)
  let per = (f.len + threads - 1) div threads
  result = timed:
    for k in 0..<threads:
      jobs[k] = Job(f: addr f, first: min(f.len, k * per), stop: min(f.len, (k + 1) * per))
      createThread(th[k], readRange, addr jobs[k])
    joinThreads(th)
  for j in jobs: doAssert j.failed == 0

proc threads() =
  rep.heading "Multi-thread scaling: N threads, disjoint trace ranges, one SeismicFile"
  rep.line "Aggregate GB/s of file bytes; each thread decodes 256-trace chunks into its " &
    "own tensor. Warm: mapped, best of 3. Cold: pages dropped before each run."
  rep.line()
  const counts = [1, 2, 4, 8, 16, 32]
  var cols = @["file", "state"]
  for c in counts: cols.add $c
  rep.table cols
  for name in ["y-ieee", "y-ibm", "y-int16", "d21-8015", "d21-8058"]:
    if not present(name): continue
    let p = pathOf(name)
    let size = float(getFileSize(p))
    warm(p)
    var f = openSeismic(p)
    discard f.parallelRead(8) # map every page
    var cells = @[name, "warm"]
    for c in counts:
      var b = Inf
      for _ in 1..3: b = min(b, f.parallelRead(c))
      cells.add gbps(size, b)
    rep.row cells
    if name in ["y-ieee", "d21-8015"]:
      cells = @[name, "cold"]
      for c in counts:
        f.dropCache()
        cells.add gbps(size, f.parallelRead(c))
      rep.row cells
    f.close()

# --------------------------------------------------------------- prefetch --

proc prefetch() =
  rep.heading "Prefetcher (one worker thread) vs readTracesInto on the caller's thread"
  rep.table ["file", "mode", "chunk x depth", "GB/s", "seek -> first chunk p50 µs",
    "p99 µs"]
  for name in ["y-ieee", "y-ibm", "d21-8015"]:
    if not present(name): continue
    let p = pathOf(name)
    let size = float(getFileSize(p))
    warm(p)
    var f = openSeismic(p)
    var t = newTraceTensor[float32](ChunkTraces, f.maxSamples)
    discard f.readAll(t)
    let tDirect = best(3): discard f.readAll(t)
    rep.row [name, "readTracesInto, caller thread", $ChunkTraces, gbps(size, tDirect), "-",
      "-"]
    for (chunk, depth) in [(64, 4), (256, 4), (1024, 4), (256, 16)]:
      let tPre = best(3):
        var pf = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = chunk, depth = depth)
        var c: PrefetchChunk[float32]
        var got = 0
        while pf.next(c): got += c.count
        doAssert got == f.len
        pf.close()
      var pf = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = chunk, depth = depth)
      var r = initRand(5)
      var xs: seq[float]
      var c: PrefetchChunk[float32]
      for _ in 0..<300:
        let a = r.rand(f.len - 1)
        let t0 = getMonoTime()
        pf.seek(a ..< f.len)
        doAssert pf.next(c)
        xs.add seconds(t0)
      pf.close()
      let s = stats(xs)
      rep.row [name, "prefetcher, consumer only takes", &"{chunk} x {depth}",
        gbps(size, tPre), us(s.p50), us(s.p99)]
    f.close()

# ------------------------------------------------------------------ write --

proc write() =
  rep.heading "Conversion, in-place header edits and geometry write-back"
  rep.table ["operation", "input", "GB in", "s", "GB/s in", "rate"]
  let outDir = dir / "out"
  createDir(outDir)
  for (name, target, label) in [("y-ibm", "segy-ieee", "SEG-Y IBM -> SEG-Y IEEE"),
      ("y-ieee", "segy-keep", "SEG-Y -> SEG-Y (copy, same format)"),
      ("d21-8058", "segy-keep", "SEG-D 2.1 8058 -> SEG-Y"),
      ("d30-8058", "segy-keep", "SEG-D 3.0 8058 -> SEG-Y"),
      ("d21-8015", "segy-keep", "SEG-D 2.1 8015 -> SEG-Y"),
      ("d21-8058", "segd", "SEG-D 2.1 -> SEG-D 3.0"),
      ("s2-ieee", "segy-keep", "SEG-2 -> SEG-Y")]:
    if not present(name): continue
    let p = pathOf(name)
    let size = float(getFileSize(p))
    warm(p)
    let dst = outDir / ("conv-" & name & (if target == "segd": ".sgd" else: ".sgy"))
    var opts = ConvertOptions()
    case target
    of "segy-ieee": opts.format = st5
    of "segd":
      opts.target = skSegd
      opts.segd.revision = SegdRevision(major: 3, minor: 0)
    else: discard
    var log: DiagLog
    let cpu0 = userCpu()
    let t = timed: log = convertFile(p, dst, opts)
    let cpu = userCpu() - cpu0
    if not fileExists(dst) or log.isFatal or log.hasErrors:
      rep.row [label & " (refused: " & (if log.len > 0: log[0].msg else: "?") & ")", name,
        gb(size), "-", "-", "-"]
    else:
      rep.row [label, name, gb(size), &"{t:.2f}", gbps(size, t),
        &"{float(getFileSize(dst)) / t / 1e9:.2f} GB/s out; CPU {cpu:.2f} s " &
        &"({size / cpu / 1e9:.1f} GB/s of CPU)"]
    removeFile(dst)
  # In-place edits on a copy of the 1 M trace file.
  for name in ["y-ieee-1m", "d21-8058-1m"]:
    if not present(name): continue
    let src = pathOf(name)
    let copy = outDir / ("edit-" & extractFilename(src))
    copyFile(src, copy)
    let journal = copy & ".edits.nif"
    removeFile(journal)
    let field = if name.startsWith("y"): "trace.sourceX" else: "ext1.receiverPointNumber"
    var ed = openEditor(copy, journal)
    let n = ed.file.len
    let single = 200
    let tSingle = timed:
      for i in 0..<single: doAssert ed.setTraceField(i, field, 1000 + i)
    rep.row [&"setTraceField {field}, one synced journal entry per edit", name,
      gb(float(getFileSize(src))), &"{tSingle:.2f}", "-",
      &"{float(single) / tSingle:.0f} edits/s"]
    let tBatch = timed:
      ed.beginBatch()
      for i in 0..<n: doAssert ed.setTraceField(i, field, 2000 + i mod 5000)
      doAssert ed.endBatch()
    rep.row [&"setTraceField {field}, every trace in one batch", name, "-",
      &"{tBatch:.2f}", "-", &"{float(n) / tBatch:.0f} edits/s"]
    ed.close()
    removeFile(journal)
    # Geometry write-back: shift every receiver by 1 m, write it.
    var f = openSeismic(copy, keys = true)
    for k in f.index.keys.mitems:
      if f.kind == skSegy:
        k.rcvX += 1
        k.rcvY += 1
        k.srcX += 1
      else:
        k.rcvPoint += 1 # SEG-D 2.1 holds stations, not coordinates
    ed = openEditor(copy, journal)
    var ch: GeometryChanges
    let tGeom = timed: ch = ed.writeGeometry(f)
    ed.close()
    f.close()
    rep.row ["writeGeometry (journaled, batched)", name, "-", &"{tGeom:.2f}", "-",
      &"{float(n) / tGeom:.0f} traces/s ({ch.traces} changed)"]
    removeFile(journal)
    removeFile(copy)

# -------------------------------------------------------------- C, Python --

proc abi() =
  ## Runs bench/capi_bench (built by `nim bench` against bin/libparseseg.so)
  ## and bench/py_bench.py (against bin/python) on the same files.
  rep.heading "C ABI and Python overhead (warm, the shipped -d:release library)"
  let root = currentSourcePath().parentDir.parentDir
  var files: seq[string]
  for name in ["y-ieee", "d21-8058", "y-ieee-10m"]:
    if present(name): files.add pathOf(name)
  let args = files.mapIt(it.quoteShell).join(" ")
  let capi = root / "bin" / "bench" / "capi_bench"
  if fileExists(capi):
    for p in files: warm(p)
    let (o, code) = execCmdEx(capi.quoteShell & " " & args)
    rep.line "C (bench/capi_bench.c):"
    rep.line()
    for l in o.strip.splitLines: rep.line l
    if code != 0: rep.line &"(exit code {code})"
  else:
    rep.line "bench/capi_bench was not built (`nim bench` builds it); skipped."
  rep.line()
  let pkg = root / "bin" / "python"
  if dirExists(pkg / "parseseg"):
    let (o, code) = execCmdEx("PYTHONPATH=" & pkg.quoteShell & " python3 " &
      quoteShell(root / "bench" / "py_bench.py") & " " & args)
    rep.line "Python (bench/py_bench.py, numpy):"
    rep.line()
    for l in o.strip.splitLines: rep.line l
    if code != 0: rep.line &"(exit code {code})"
  else:
    rep.line "bin/python/parseseg was not built (`nim bench` builds it); skipped."

# ------------------------------------------------------------------- main --

when isMainModule:
  var sections: seq[string]
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "scale": sc = parseEnum[Scale](val)
      of "dir": dir = val
      else: quit "unknown option --" & key
    of cmdArgument: sections.add key
    else: quit "unknown option -" & key
  if sections.len == 0:
    sections = @["baseline", "index", "decode", "latency", "threads", "prefetch", "write",
      "abi"]
  rep.line &"# parseSEG benchmarks ({sc} scale, {now().format(\"yyyy-MM-dd HH:mm\")})"
  rep.line()
  rep.line &"{cpuModel()}, {countProcessors()} hardware threads, {memTotalGb():.0f} GB RAM; " &
    &"Nim {NimVersion}; data in {dir}."
  for s in sections:
    case s
    of "baseline": baseline()
    of "index": index()
    of "decode":
      if memcpyRate == 0: baseline()
      decode()
    of "latency": latency()
    of "threads": threads()
    of "prefetch": prefetch()
    of "write": write()
    of "abi": abi()
    else: quit "unknown section " & s
  writeFile(dir / &"results-{sc}.md", rep.text)
