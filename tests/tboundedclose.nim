## Closing a prefetcher never waits without bound: a worker stopped in a
## read of a share that does not answer (here: `pread` interposed to wait
## while a flag is set, for one file) is given up on after `closeTimeout`.
## `close` returns false, the prefetcher is closed for the caller, every
## other file keeps working, and what the worker holds (its shared block, the
## slot buffers, the pin on the file's read cache) stays alive until it has
## returned and `reapPrefetchers` frees it. A worker inside the caller's
## `transform` is waited for instead. Seen failing with `close` waiting for
## the worker without a bound: "close waited without a bound" (the watchdog).
## A prefetcher whose worker thread the OS refuses (`pthread_create`
## interposed to fail) raises at once and leaves nothing behind (seen
## failing: it waited the whole `closeTimeout` for the thread that never ran,
## and left a given-up prefetcher that was never freed).

# test-separate: interposes pread(2) and pthread_create; a second definition cannot link

import std/[assertions, atomics, monotimes, os, posix, times]

import parseSEG

from parseSEG/model/traceindex import unsafeCache

import parseSEG/private/readcache

import ./utils/testutils

when not defined(linux):
  discard
else:
    {.passL: "-ldl".}
    {.emit: """/*INCLUDESECTION*/
  #include <dlfcn.h>
  #include <errno.h>
  #include <unistd.h>
  #include <sys/stat.h>
  #include <sys/types.h>
  #include <pthread.h>
  """.}
    {.emit: """
  static ssize_t (*tbcRealPread)(int, void *, size_t, off_t) = 0;
  static unsigned long long tbcIno = 0;
  static int tbcHang = 0, tbcInRead = 0;
  ssize_t pread(int fd, void *buf, size_t n, off_t at) {
    /* A read of the marked file waits while `tbcHang` is set: a hung share. */
    if (!tbcRealPread) tbcRealPread = (ssize_t (*)(int, void *, size_t, off_t)) dlsym(((void *) -1l), "pread");
    if (__atomic_load_n(&tbcHang, __ATOMIC_SEQ_CST)) {
      struct stat st;
      if (fstat(fd, &st) == 0 && (unsigned long long) st.st_ino == __atomic_load_n(&tbcIno, __ATOMIC_SEQ_CST)) {
        __atomic_add_fetch(&tbcInRead, 1, __ATOMIC_SEQ_CST);
        while (__atomic_load_n(&tbcHang, __ATOMIC_SEQ_CST)) usleep(1000);
        __atomic_sub_fetch(&tbcInRead, 1, __ATOMIC_SEQ_CST);
      }
    }
    return tbcRealPread(fd, buf, n, at);
  }
  static void tbcHangReadsOf(unsigned long long ino) { __atomic_store_n(&tbcIno, ino, __ATOMIC_SEQ_CST); __atomic_store_n(&tbcHang, 1, __ATOMIC_SEQ_CST); }
  static void tbcLetGo(void) { __atomic_store_n(&tbcHang, 0, __ATOMIC_SEQ_CST); }
  static int tbcStuck(void) { return __atomic_load_n(&tbcInRead, __ATOMIC_SEQ_CST); }
  static int (*tbcRealCreate)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = 0;
  static int tbcThreadsLeft = -1; /* threads made before pthread_create fails; -1: no limit */
  int pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg) {
    if (!tbcRealCreate)
      tbcRealCreate = (int (*)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *))
        dlsym(((void *) -1l), "pthread_create");
    int left = __atomic_load_n(&tbcThreadsLeft, __ATOMIC_SEQ_CST);
    if (left == 0) return EAGAIN;
    if (left > 0) __atomic_sub_fetch(&tbcThreadsLeft, 1, __ATOMIC_SEQ_CST);
    return tbcRealCreate(t, a, fn, arg);
  }
  static void tbcThreadLimit(int n) { __atomic_store_n(&tbcThreadsLeft, n, __ATOMIC_SEQ_CST); }
  """.}
    proc hangReadsOf(ino: culonglong) {.importc: "tbcHangReadsOf", nodecl.}
    proc letGo() {.importc: "tbcLetGo", nodecl.}
    proc stuck(): cint {.importc: "tbcStuck", nodecl.}
    proc threadLimit(n: cint) {.importc: "tbcThreadLimit", nodecl.}

    # A close that waits for ever must fail the test, not hang it.
    var watchdog: Thread[void]
    var finished: Atomic[bool]
    proc watch() {.thread.} =
      let t0 = getMonoTime()
      while not finished.load:
        if getMonoTime() - t0 > initDuration(seconds = 90):
          echo "tboundedclose: close waited without a bound"
          quit 1
        sleep(20)
    createThread(watchdog, watch)

    let tmp = scratchDir("parseseg_tboundedclose")
    const unmapped = OpenOptions(access: faUnmapped)

    proc inode(path: string): culonglong =
      var st: Stat
      doAssert stat(path.cstring, st) == 0
      culonglong(st.st_ino)

    proc held(path: string): bool =
      ## This process holds a descriptor of `path`.
      let full = expandFilename(path)
      for kind, fd in walkDir("/proc/self/fd"):
        try:
          if expandSymlink(fd) == full: return true
        except OSError: discard
      false

    proc waitFor(cond: proc (): bool, seconds: float): bool =
      let t0 = getMonoTime()
      while not cond():
        if getMonoTime() - t0 > initDuration(milliseconds = int(seconds * 1000)): return false
        sleep(2)
      true

    proc ms(d: Duration): float = float(d.inMicroseconds) / 1000

    proc readOther(name: string) =
      ## Another file, both ways, while a worker of the first is stopped.
      for access in [faMapped, faUnmapped]:
        var g = openSeismic(demoDir() / name, opts = OpenOptions(access: access))
        doAssert g.readTraces(0 ..< g.len).shape[0] == g.len
        var q = newPrefetcher[float32](g, 0 ..< g.len, chunkTraces = 16)
        var c: PrefetchChunk[float32]
        doAssert q.next(c) and c.count > 0
        doAssert q.close() # joined at once
        g.close()

    block close_gives_up_on_a_worker_stuck_in_a_read:
      let a = tmp / "a.sgy"
      copyFile(demoDir() / "survey.sgy", a)
      var f = openSeismic(a, opts = unmapped)
      f.unsafeCache.dropUnpinned() # what the open read is not kept: the worker must read
      hangReadsOf(inode(a))
      var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8,
        closeTimeout = initDuration(milliseconds = 300))
      doAssert waitFor(proc (): bool = stuck() > 0, 10), "the worker never read"
      let t0 = getMonoTime()
      let joined = p.close()
      let took = ms(getMonoTime() - t0)
      doAssert not joined, "a worker stopped in a read was joined"
      doAssert took >= 250 and took < 3000, "close took " & $took & " ms"
      doAssert p.close() # idempotent: closed already
      doAssert reapPrefetchers() == 1
      readOther("shot.sgd")
      readOther("line.sg2")
      f.close() # the given-up worker's pin keeps its read cache, and the descriptor
      doAssert held(a), "the file's descriptor was closed under a worker reading it"
      letGo()   # the share answers: the worker returns, and is reaped
      doAssert waitFor(proc (): bool = reapPrefetchers() == 0, 10), "never reaped"
      doAssert not held(a), "the file was not closed once its last holder went"

    block the_destructor_gives_up_too:
      let b = tmp / "b.sgy"
      copyFile(demoDir() / "survey.sgy", b)
      var f = openSeismic(b, opts = unmapped)
      f.unsafeCache.dropUnpinned()
      hangReadsOf(inode(b))
      let t0 = getMonoTime()
      block:
        var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8,
          closeTimeout = initDuration(milliseconds = 200))
        doAssert waitFor(proc (): bool = stuck() > 0, 10)
        discard p.depth
      let took = ms(getMonoTime() - t0)
      doAssert took < 3000, "the destructor took " & $took & " ms"
      doAssert reapPrefetchers() == 1
      letGo()
      doAssert waitFor(proc (): bool = reapPrefetchers() == 0, 10)
      f.close()

    var entered: Atomic[int]
    proc slowTransform(worker: int, samples: ptr UncheckedArray[float32], rows, cols: int,
        traces: TraceRows, failed: openArray[int], user: pointer) {.nimcall, gcsafe,
        raises: [].} =
      entered.atomicInc
      if entered.load == 1: sleep(400) # the caller's code: close waits for it

    block a_transform_is_waited_for:
      var f = openSeismic(demoDir() / "survey.sgy", opts = OpenOptions(access: faMapped))
      var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, transform = slowTransform,
        closeTimeout = initDuration(milliseconds = 50))
      doAssert waitFor(proc (): bool = entered.load >= 1, 10)
      let t0 = getMonoTime()
      doAssert p.close(), "a worker inside the transform was given up on"
      doAssert ms(getMonoTime() - t0) >= 200
      doAssert reapPrefetchers() == 0
      f.close()

    block a_close_with_no_stuck_worker_is_quick:
      var f = openSeismic(demoDir() / "survey.sgy", opts = OpenOptions(access: faMapped))
      for workers in [1, 4]:
        var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, workers = workers)
        var c: PrefetchChunk[float32]
        doAssert p.next(c)
        let t0 = getMonoTime()
        doAssert p.close()
        doAssert ms(getMonoTime() - t0) < 100, $workers
      f.close()

    block a_worker_the_os_refuses:
      # Not under ASan (`nim asan`, `-d:useMalloc`): the standard library's
      # `createThread` leaks the thread's storage when `pthread_create` fails
      # (Nim 2.4.2), which LeakSanitizer reports.
      when defined(useMalloc): break a_worker_the_os_refuses
      var f = openSeismic(demoDir() / "survey.sgy", opts = OpenOptions(access: faMapped))
      threadLimit(1) # the first worker is made, the second is not
      let t0 = getMonoTime()
      var raised = false
      try:
        var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, workers = 3,
          closeTimeout = initDuration(seconds = 2))
        discard p.close()
      except ResourceExhaustedError:
        raised = true
      threadLimit(-1)
      let took = ms(getMonoTime() - t0)
      doAssert raised
      doAssert took < 1500, "waited " & $took & " ms for a thread that never ran"
      doAssert reapPrefetchers() == 0, "a prefetcher with a thread that never ran was given up on"
      f.close()

    finished.store(true)
    joinThread(watchdog)
    echo "tboundedclose: ok"

proc main*() =
  when not defined(linux):
    echo "tboundedclose: skipped: pread is interposed the ELF way (Linux)"

    quit 0

when isMainModule: main()
