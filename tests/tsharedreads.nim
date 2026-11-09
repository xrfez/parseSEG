## Several threads reading one open SeismicFile (14.2a regression: the map's
## accessors once copied a ref, and ORC reference counts are not atomic).

import std/typedthreads
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
