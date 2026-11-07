## Benchmarks (task 6.4): index build, decode throughput and read-ahead on
## the sample files that are present (the 65 MB Rev 3.0 file is local only).
##
##   nim c -r -d:danger --path:src tools/bench.nim [file ...]
##
## Times are the best of `Runs` warm-cache runs, so they measure the library,
## not the disk.

import std/[monotimes, times, os, strformat]
import parseSEGD

const
  exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
  Runs = 5

template best(body: untyped): float =
  var b = Inf
  for _ in 1..Runs:
    let t0 = getMonoTime()
    body
    b = min(b, (getMonoTime() - t0).inNanoseconds.float / 1e9)
  b

proc bench(path: string) =
  var probe = openSeismic(path)
  let traces = probe.len
  var samples = 0
  for e in probe.index.entries: samples += int(e.numSamples)
  let mb = getFileSize(path).float / 1e6
  echo &"{path.extractFilename}: {mb:.1f} MB, {traces} traces, {samples} samples ({probe.kind})"

  let tIndex = best:
    var f = openSeismic(path)
    doAssert f.len == traces
    f.close()
  let tKeys = best:
    var f = openSeismic(path, keys = true)
    doAssert f.index.keys.len == traces
    f.close()
  let tFull = best:
    if probe.kind == skSegd: discard readSegd(path) else: discard readSegy(path)
  let tHeaders = best:
    if probe.kind == skSegd: discard readSegdHeaders(path) else: discard readSegyHeaders(path)
  let tRange = best:
    discard probe.readTraces(0..<traces)
  let tPrefetch = best:
    var p = newPrefetcher[float32](probe, chunkTraces = 256, depth = 4)
    var c: PrefetchChunk[float32]
    var n = 0
    while p.next(c): n += c.count
    doAssert n == traces
    p.close()
  proc row(name: string, secs: float) =
    let ms = secs * 1e3
    let rate = mb / secs
    let msps = samples.float / secs / 1e6
    echo &"  {name:<34} {ms:9.2f} ms  {rate:9.0f} MB/s  {msps:8.1f} Msamples/s"
  row("index (headers only, mmap)", tIndex)
  row("index + per-trace keys", tKeys)
  row("headers-only read (all headers)", tHeaders)
  row("full read (raw + decoded)", tFull)
  row("range decode readTraces(all)", tRange)
  row("prefetch thread (256 x 4)", tPrefetch)
  let nsPerTrace = tIndex / traces.float * 1e9
  let entryBytes = traces * sizeof(TraceEntry)
  echo &"  index: {nsPerTrace:.0f} ns/trace, {entryBytes} bytes of entries"
  probe.close()

let args = commandLineParams()
let paths = if args.len > 0: args
            else: @["00000151_12900_11300.sgd", "inova_rev30_5traces.sgd", "63.sgd",
                    "BO_3D-Inglewood_rev21_v7.sgy", "Sweep0.sgy"]
for p in paths:
  let path = if fileExists(p): p else: exampleDir / p
  if fileExists(path): bench(path)
  else: echo p, ": not present, skipped"
