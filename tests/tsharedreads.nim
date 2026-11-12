## Several threads reading one open SeismicFile (14.2a regression: the map's
## accessors once copied a ref, and ORC reference counts are not atomic).

import std/[typedthreads, os, strutils]
import parseSEG
import ./utils/testutils
let path = sampleOr("BO_3D-Inglewood_rev21_v7.sgy") # or the demo survey.sgy
var f = openSeismic(path)
proc work(p: ptr SeismicFile) {.thread.} =
  var t = newTensor[float32](4, p[].maxSamples)
  var log: DiagLog
  for i in 0..<20000:
    discard p[].readTracesInto((i mod 190) ..< (i mod 190) + 4, t, 0, log)
var th: array[8, Thread[ptr SeismicFile]]
for i in 0..<th.len: createThread(th[i], work, addr f)
joinThreads(th)
f.close()
echo "tsharedreads: ok"

# Prefetchers of one file, made and closed on several threads at once (a
# background job beside the UI thread's read-ahead): each pins and unpins the
# file's map. Before the pins had a lock this crashed most runs (the map's
# reference count went wrong and the file was unmapped under the readers);
# ThreadSanitizer shows the race itself (gcc: --passC and --passL
# -fsanitize=thread, -d:useMalloc -d:noSignalHandler).
proc mapped(): bool =
  when defined(linux): expandFilename(path) in readFile("/proc/self/maps")
  else: true

proc prefetchWork(p: ptr SeismicFile) {.thread.} =
  {.cast(gcsafe).}:
    var c: PrefetchChunk[float32]
    for i in 0 ..< 200:
      var q = newPrefetcher[float32](p[], 0 ..< 64, chunkTraces = 32, cols = 16)
      doAssert q.next(c) and c.count == 32 and c.rows.traceKeys(31).inline > 0
      if i mod 2 == 0: q.close() # else destroyed without close

var g = openSeismic(path, keys = true)
var workers: array[4, Thread[ptr SeismicFile]]
for i in 0 ..< workers.len: createThread(workers[i], prefetchWork, addr g)
prefetchWork(addr g) # the file's own thread does the same meanwhile
joinThreads(workers)
# The other threads are done with the file: its own thread may close it, also
# before a prefetcher of its own, which keeps the map until its close.
var last = newPrefetcher[float32](g, 0 ..< 64, chunkTraces = 32, cols = 16)
g.close()
doAssert mapped()
var c: PrefetchChunk[float32]
doAssert last.next(c) and c.count == 32
last.close()
when defined(linux): doAssert not mapped()
echo "prefetchers on several threads: ok"
