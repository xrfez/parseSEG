## Page-cache hints for a mapped file (`madvise`, `mincore`): ask the OS
## to read a byte range ahead, and test whether a page is in memory. Raw
## pointers only, nothing allocated, so worker threads may call them. POSIX
## only (no-ops elsewhere).

when defined(posix): import std/posix

when defined(posix):
  var MADV_WILLNEED {.importc, header: "<sys/mman.h>".}: cint
  proc c_madvise(adr: pointer, len: csize_t, advice: cint): cint {.
    importc: "madvise", header: "<sys/mman.h>".}
  proc c_mincore(adr: pointer, len: csize_t, vec: ptr uint8): cint {.
    importc: "mincore", header: "<sys/mman.h>".}
  let pageSize = max(4096, int(sysconf(SC_PAGESIZE))) # read-only after module init

proc adviseWillNeed*(mem: ptr UncheckedArray[byte], size, a, b: int64) {.raises: [].} =
  ## Hints that bytes `a ..< b` of the mapping `mem[0 ..< size]`
  ## will be read soon, so the OS queues their disk reads at once instead of
  ## one fault at a time. A hint only: failures are ignored, nothing is
  ## allocated, so worker threads may call it. A no-op off POSIX.
  when defined(posix):
    let lo = max(a, 0'i64) and not int64(pageSize - 1)
    let hi = min(b, size)
    if mem != nil and hi > lo:
      discard c_madvise(addr mem[lo], csize_t(hi - lo), MADV_WILLNEED)

proc isResident*(mem: ptr UncheckedArray[byte], size, offset: int64): bool {.raises: [].} =
  ## The page holding byte `offset` of the mapping is in memory
  ## (`mincore`), so reading it will not wait for the disk. True off POSIX
  ## and for an offset outside the map (nothing to advise).
  when defined(posix):
    if mem == nil or offset < 0 or offset >= size: return true
    var v: uint8
    let lo = offset and not int64(pageSize - 1)
    c_mincore(addr mem[lo], 1, addr v) != 0 or (v and 1) != 0
  else:
    true
