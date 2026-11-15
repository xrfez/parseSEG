## A file opened on one thread and released on another (a viewer opens on a
## job thread and closes on the UI thread), with and without prefetchers,
## needs no `clearCycleRoots`: the record sources and sinks cannot form
## cycles and say so (`{.acyclic.}`), so ORC never lists them as possible
## cycle roots on the thread that made them. Before, `MemFileSource` was
## listed on the opening thread, and releasing it on another made ORC write
## outside that thread's list (AddressSanitizer: heap-buffer-overflow).
## Seen failing with `{.acyclic.}` taken off `MemFileSource`, `DiskSource`,
## `DiskSink`, `TapeImageSource` or `TapeImageSink` (the opening thread's
## roots: 1, not 0), and with the `MapRef` of `openMapped` made before the
## source that raised (1000 failed opens: 96 000 bytes left). `nim asan`
## runs this file under ASan/LSan; it also passes under TSan.

import std/[assertions, atomics, os]
import parseSEG
import ./utils/testutils

let survey = demoDir() / "survey.sgy"

type
  Job = object
    path: string
    file: ptr SeismicFile    # moved out of the job's thread
    prefetch: bool           # also read through a prefetcher on the job's thread
    keys: bool
    roots: Atomic[int]       # ORC's possible cycle roots on the job's thread at its end

proc opener(j: ptr Job) {.thread.} =
  {.cast(gcsafe).}: # the record layer's methods are not known to be GC-safe
    j.file[] = openSeismic(j.path, keys = j.keys)
    if j.prefetch:
      var p = newPrefetcher[float32](j.file[], 0 ..< j.file[].len, chunkTraces = 16)
      var c: PrefetchChunk[float32]
      var n = 0
      while p.nextInto(c): n += c.count
      doAssert n == j.file[].len
      p.close()
  let roots = GC_prepareOrc()
  j.roots.store(roots)
  # Nothing is listed, but ORC keeps the thread's root buffer (16 KiB) once
  # anything was listed and unlisted on it: std/xmlparser's StringStream,
  # reading the Layout stanza of `survey.sgy`, does that. A collection with
  # an empty list frees it; without one LSan reports it when the process ends.
  if roots == 0: GC_runOrc()

proc openOn(path: string, prefetch, keys: bool): (ptr SeismicFile, int) =
  ## Opens `path` on a thread of its own; the file, moved to the caller, and
  ## the roots ORC listed on that thread.
  let slot = createShared(SeismicFile)
  var j = Job(path: path, file: slot, prefetch: prefetch, keys: keys)
  var th: Thread[ptr Job]
  createThread(th, opener, addr j)
  joinThread(th)
  (slot, j.roots.load())

proc release(slot: ptr SeismicFile) =
  reset(slot[]) # destroys the file here: the map, the source, the index
  deallocShared(slot)

block open_on_a_thread_close_on_another:
  for (prefetch, keys) in [(false, false), (true, false), (false, true), (true, true)]:
    let (slot, roots) = openOn(survey, prefetch, keys)
    doAssert roots == 0, "the opening thread lists " & $roots & " possible cycle roots"
    doAssert slot[].len == 200 and slot[].readTraces(0 ..< 4).shape == [4, 2001]
    slot[].close()
    release(slot)

block prefetcher_on_the_releasing_thread:
  # Opened on a job thread; read ahead, closed and released here, the file
  # first, so the prefetcher's pin releases the map.
  let (slot, roots) = openOn(survey, false, false)
  doAssert roots == 0
  var p = newPrefetcher[float32](slot[], 0 ..< slot[].len, chunkTraces = 32, workers = 2)
  var c: PrefetchChunk[float32]
  doAssert p.next(c) and c.count == 32
  slot[].close()
  release(slot)
  var n = c.count
  while p.next(c): n += c.count
  doAssert n == 200
  p.close()

block released_without_close:
  # Dropped (not closed) on another thread than the one that opened it.
  let (slot, roots) = openOn(survey, true, true)
  doAssert roots == 0
  release(slot)

block sources_and_sinks_on_a_thread:
  # The record sources and sinks themselves, made on a thread and released
  # here.
  type Made = object
    disk: DiskSource
    mem: MemFileSource
    tapeIn: TapeImageSource
    sink: DiskSink
    tapeOut: TapeImageSink
    roots: Atomic[int]
  let dir = getTempDir() / "parseseg_tcrossthread"
  createDir(dir)
  copyFile(survey, dir / "survey.sgy") # `demoDir` is a global: not for the thread
  proc make(m: ptr Made) {.thread.} =
    {.cast(gcsafe).}:
      let d = getTempDir() / "parseseg_tcrossthread"
      let survey = d / "survey.sgy"
      m.disk = openDiskSource(survey)
      m.mem = openMemFileSource(survey)
      m.sink = openDiskSink(d / "out.bin")
      m.tapeOut = openTapeImageSink(d / "out.tap")
      m.tapeOut.writeRecord([1'u8, 2, 3])
      m.tapeOut.close()
      m.tapeIn = openTapeImageSource(d / "out.tap")
      var buf: seq[byte]
      doAssert m.disk.readRecord(buf, 4096) == rkData
      doAssert m.mem.readRecord(buf, 4096) == rkData
      # A second reference to each, dropped again, as a reader's cursor does:
      # ORC lists a ref it may think cyclic as a root when such a drop leaves
      # it alive.
      proc touch(x: RecordSource): int {.noinline.} =
        var held = @[x] # a counted copy of the ref (a plain `let` is a borrow)
        held[0].name.len
      proc touch(x: RecordSink): int {.noinline.} =
        var held = @[x]
        held[0].name.len
      var n = 0
      for _ in 1 .. 3:
        n += touch(m.disk) + touch(m.mem) + touch(m.tapeIn) + touch(m.sink) + touch(m.tapeOut)
      doAssert n > 0
    m.roots.store(GC_prepareOrc())
  let m = createShared(Made)
  var th: Thread[ptr Made]
  createThread(th, make, m)
  joinThread(th)
  doAssert m.roots.load() == 0, $m.roots.load()
  m.disk.close()
  m.mem.close()
  m.sink.close()
  m.tapeIn.close()
  reset(m[])
  deallocShared(m)

block a_failed_open_leaks_nothing:
  # 1000 opens of a missing file: each raises, and nothing stays allocated
  # (a `MapRef`, 96 bytes, stayed per open; LSan checks it under `nim asan`).
  proc failedOpens(n: int) =
    for _ in 1 .. n:
      try:
        discard openSeismic(getTempDir() / "parseseg_no_such_file.sgy")
        doAssert false
      except IOError, OSError:
        discard
  failedOpens(10) # warm up
  GC_fullCollect()
  let before = getOccupiedMem()
  failedOpens(1000)
  GC_fullCollect()
  let grown = getOccupiedMem() - before
  doAssert grown < 1000 * 48, "1000 failed opens left " & $grown & " bytes"

echo "tcrossthread: ok"
