## The prefetcher's entry points are GC-safe: a `{.gcsafe.}` proc and a
## thread made with `createThread` call `newPrefetcher` (a range and a
## list), take chunks, `close` it (both forms: as a statement, discarded,
## used) and `reapPrefetchers`, without a cast. This file compiling is the
## check; the run shows the calls work. Seen failing (0.12.0): "'readAll'
## is not GC-safe as it calls 'newPrefetcher'" (which calls
## `reapPrefetchers`, which "performs an indirect call": the given-up
## prefetchers' list called procs of a type that did not say `gcsafe`).
##
## `openSeismic` is not GC-safe (the record sources dispatch by method), in
## 0.11 neither: the file is opened under a cast, which is not what this
## checks.

import std/[assertions, atomics, os, times]
import parseSEG
import ./utils/testutils

proc openFile(path: string): SeismicFile =
  {.cast(gcsafe).}: result = openSeismic(path)

proc readAll(path: string): int {.gcsafe.} =
  ## Every trace of `path` through prefetchers; the traces taken.
  var f = openFile(path)
  var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 16)
  var c: PrefetchChunk[float32]
  while p.nextInto(c): result += c.count
  p.close() # a statement
  doAssert p.close(initDuration(seconds = 1)), "a closed prefetcher closes again"
  var q = newPrefetcher[float32](f, @[f.len - 1, 0], closeTimeout = initDuration(seconds = 5))
  while q.next(c): result += c.count
  discard q.close()
  doAssert reapPrefetchers() == 0
  var dropped = newPrefetcher[float32](f, 0 ..< f.len) # its destructor closes it
  doAssert dropped.len == f.len

proc closeLastInBlock(path: string) {.gcsafe.} =
  # As the last statement of a pragma block that ends a proc, the result is
  # not discarded for the caller (as the docs say): `discard` it.
  var f = openFile(path)
  var p = newPrefetcher[float32](f, 0 ..< f.len)
  {.cast(gcsafe).}:
    discard p.close()

let path = demoDir() / "survey.sgy"
let traces = block:
  var f = openSeismic(path)
  f.len

block a_gcsafe_proc:
  doAssert readAll(path) == traces + 2
  closeLastInBlock(path)

var taken: Atomic[int]

proc job(path: string) {.thread.} =
  taken.store(readAll(path))
  closeLastInBlock(path)
  discard reapPrefetchers()

block a_thread:
  var t: Thread[string]
  createThread(t, job, path)
  joinThread(t)
  doAssert taken.load == traces + 2, $taken.load

echo "tgcsafe: ok"
