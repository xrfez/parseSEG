## A hold that waits for another thread's read of a block fails, without
## reading again, only when that read failed (on a share that is down each
## caller waits once, not once per thread); a block that loaded and was
## evicted before the waiting hold woke is read by it, also while a read of
## another block failed meanwhile. `pread` is interposed: reads of block 0
## wait while a flag is set, reads of block 1 fail with `EIO`. Seen failing
## with one failure count for the whole file: "spurious failures: 16 of 300"
## (a "try again" for a block that had been read).

# test-separate: interposes pread(2); a second definition cannot link into the suite

import std/[assertions, atomics, os]

import parseSEG/private/[mapguard, readcache]

import ./utils/testutils

when not defined(linux):
  discard
else:
    {.passL: "-ldl".}
    {.emit: """/*INCLUDESECTION*/
  #include <dlfcn.h>
  #include <errno.h>
  #include <unistd.h>
  #include <sys/types.h>
  """.}
    {.emit: """
  static ssize_t (*trwReal)(int, void *, size_t, off_t) = 0;
  static int trwHold = 0, trwIn = 0, trwFail0 = 0, trwFail1 = 0, trwReads0 = 0;
  ssize_t pread(int fd, void *buf, size_t n, off_t at) {
    if (!trwReal) trwReal = (ssize_t (*)(int, void *, size_t, off_t)) dlsym(((void *) -1l), "pread");
    if (at == 0) {
      __atomic_add_fetch(&trwReads0, 1, __ATOMIC_SEQ_CST);
      if (__atomic_load_n(&trwHold, __ATOMIC_SEQ_CST)) {
        __atomic_add_fetch(&trwIn, 1, __ATOMIC_SEQ_CST);
        while (__atomic_load_n(&trwHold, __ATOMIC_SEQ_CST)) usleep(100);
      }
      if (__atomic_load_n(&trwFail0, __ATOMIC_SEQ_CST)) { errno = EIO; return -1; }
    } else if (__atomic_load_n(&trwFail1, __ATOMIC_SEQ_CST)) { errno = EIO; return -1; }
    return trwReal(fd, buf, n, at);
  }
  static void trwSet(int fail0, int fail1) {
    __atomic_store_n(&trwIn, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&trwReads0, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&trwFail0, fail0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&trwFail1, fail1, __ATOMIC_SEQ_CST);
    __atomic_store_n(&trwHold, 1, __ATOMIC_SEQ_CST);
  }
  static void trwLetGo(void) { __atomic_store_n(&trwHold, 0, __ATOMIC_SEQ_CST); }
  static int trwInRead(void) { return __atomic_load_n(&trwIn, __ATOMIC_SEQ_CST); }
  static int trwReadsOf0(void) { return __atomic_load_n(&trwReads0, __ATOMIC_SEQ_CST); }
  """.}
    proc setReads(fail0, fail1: cint) {.importc: "trwSet", nodecl.}
    proc letGo() {.importc: "trwLetGo", nodecl.}
    proc inRead(): cint {.importc: "trwInRead", nodecl.}
    proc readsOf0(): cint {.importc: "trwReadsOf0", nodecl.}

    let path = scratchDir("parseseg_treadwait") / "two.bin"
    writeFile(path, newString(2 * BlockBytes))
    var cache: ptr ReadCache
    var waiter: Atomic[int] # the waiting hold's `ReadStatus`

    proc first() {.thread.} =
      var h: Hold
      discard cache.hold(0, BlockBytes, h)
      h.drop() # with no budget, block 0 is evicted now

    proc second() {.thread.} =
      var h: Hold
      waiter.store(ord(cache.hold(0, BlockBytes, h)))

    proc other() {.thread.} =
      var h: Hold
      discard cache.hold(BlockBytes, 2 * BlockBytes, h)

    proc round(fail0: bool): ReadStatus =
      # `first` reads block 0 and waits in `pread`; `second` waits for that
      # read; then the read goes on (and fails with `fail0`) while `other`'s
      # read of block 1 fails.
      let g = newTrackSlot()
      cache = openReadCache(path, false, g)
      cache.setBudget(0)
      setReads(cint(fail0), 1)
      var a, b, c: Thread[void]
      createThread(a, first)
      while inRead() == 0: sleep(0)
      createThread(b, second)
      sleep(1) # `second` is waiting for the block (it cannot read it: it is being read)
      letGo()
      createThread(c, other)
      joinThread(a)
      joinThread(b)
      joinThread(c)
      result = ReadStatus(waiter.load)
      closeCache(cache)
      freeTrackSlot(g)

    block the_read_waited_for_failed:
      # A round where `second` started only after the failed read reads the
      # block itself (2 reads): one of a few rounds has it waiting.
      var waited = false
      for i in 0 ..< 10:
        doAssert round(fail0 = true) == rsFailed
        if readsOf0() == 1:
          waited = true
          break
      doAssert waited, "the waiting hold read the block again after the read it waited for failed"

    block a_block_read_and_evicted_while_another_failed:
      var spurious = 0
      const rounds = 300
      for i in 0 ..< rounds:
        if round(fail0 = false) == rsFailed: inc spurious
      doAssert spurious == 0, "spurious failures: " & $spurious & " of " & $rounds

    echo "treadwait: ok"

proc main*() =
  when not defined(linux):
    echo "treadwait: skipped: pread is interposed the ELF way (Linux)"

    quit 0

when isMainModule: main()
