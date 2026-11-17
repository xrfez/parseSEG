## A file's map is closed (unmapped, its descriptor closed) after the lock
## that every file's pins and drops share (`mapLock`) is released: on a
## network share close(2) can block (NFS writes back an edited file's pages,
## SMB waits for the server), and the other threads (one opening, dropping
## or reading ahead in another file) must not wait for it. This test makes
## close(2) of one file's descriptor block (an interposed `close`), closes
## that file on a thread and meanwhile starts and closes a prefetcher on
## another file here: it must not wait. Seen failing with the map closed
## under the lock: the prefetcher waited until the close was let go.

# test-separate: interposes close(2); a second definition cannot link into the suite

import std/[assertions, atomics, os, posix, times]

import parseSEG

import ./utils/testutils

when not defined(linux):
  discard
else:
    {.passL: "-ldl".}
    {.emit: """/*INCLUDESECTION*/
  #include <dlfcn.h>
  #include <unistd.h>
  """.}
    {.emit: """
  static int (*parsesegRealClose)(int) = 0;
  static int parsesegBlockFd = -1, parsesegInClose = 0, parsesegLetGo = 0;
  int close(int fd) {
    /* Every close(2) of this program comes here: the one of `parsesegBlockFd`
       waits until it is let go, as on a share whose server does not answer. */
    if (!parsesegRealClose) parsesegRealClose = (int (*)(int)) dlsym(((void *) -1l), "close");
    if (fd >= 0 && fd == __atomic_load_n(&parsesegBlockFd, __ATOMIC_SEQ_CST)) {
      __atomic_store_n(&parsesegInClose, 1, __ATOMIC_SEQ_CST);
      while (!__atomic_load_n(&parsesegLetGo, __ATOMIC_SEQ_CST)) usleep(1000);
    }
    return parsesegRealClose(fd);
  }
  static void parsesegBlock(int fd) { __atomic_store_n(&parsesegBlockFd, fd, __ATOMIC_SEQ_CST); }
  static int parsesegInCloseNow(void) { return __atomic_load_n(&parsesegInClose, __ATOMIC_SEQ_CST); }
  static void parsesegLetGoNow(void) { __atomic_store_n(&parsesegLetGo, 1, __ATOMIC_SEQ_CST); }
  """.}
    proc blockClose(fd: cint) {.importc: "parsesegBlock", nodecl.}
    proc inClose(): cint {.importc: "parsesegInCloseNow", nodecl.}
    proc letGo() {.importc: "parsesegLetGoNow", nodecl.}

    proc descriptorOf(path: string): cint =
      ## The descriptor this process holds of `path` (parseSEG keeps one per map).
      var st: Stat
      doAssert stat(path.cstring, st) == 0
      result = -1
      for i in cint(3) .. cint(4096):
        var s: Stat
        if fstat(i, s) == 0 and s.st_dev == st.st_dev and s.st_ino == st.st_ino: result = i

    proc waitFor(cond: proc (): bool, seconds: float): bool =
      let t0 = epochTime()
      while not cond():
        if epochTime() - t0 > seconds: return false
        sleep(5)
      true

    let dir = getTempDir() / "parseseg_tblockedclose"
    createDir(dir)
    let a = dir / "a.sgy"
    let b = dir / "b.sgy"
    copyFile(demoDir() / "survey.sgy", a)
    copyFile(demoDir() / "survey.sgy", b)

    var fa = openSeismic(a)
    var fb = openSeismic(b)
    let fd = descriptorOf(a)
    doAssert fd >= 0, "parseSEG keeps the file's descriptor open"
    blockClose(fd)

    proc closer(f: ptr SeismicFile) {.thread.} =
      {.cast(gcsafe).}: f[].close() # the map's last holder: munmap, then close(2)
    var reader: Atomic[bool]
    proc readAhead(f: ptr SeismicFile) {.thread.} =
      {.cast(gcsafe).}:
        var p = newPrefetcher[float32](f[], 0 ..< 16, chunkTraces = 8) # pins the map
        var c: PrefetchChunk[float32]
        doAssert p.next(c)
        p.close() # drops the pin
        reader.store(true)

    proc run(): bool =
      ## True when the prefetcher on `fb` had to wait for the close of `fa`.
      var t1, t2: Thread[ptr SeismicFile]
      createThread(t1, closer, addr fa)
      doAssert waitFor(proc (): bool = inClose() != 0, 30), "the close never reached close(2)"
      createThread(t2, readAhead, addr fb)
      result = not waitFor(proc (): bool = reader.load, 10)
      letGo()
      joinThread(t1)
      joinThread(t2)
    doAssert not run(), "a prefetcher on another file waited for close(2) of this one"
    fb.close()
    echo "tblockedclose: ok"

proc main*() =
  when not defined(linux):
    echo "tblockedclose: skipped: close(2) is interposed the ELF way (Linux)"

    quit 0

when isMainModule: main()
