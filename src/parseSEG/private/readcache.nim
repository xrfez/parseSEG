## Unmapped reads of a disk file (`FileAccess.faUnmapped`): its bytes reach
## memory only through positional reads (`pread`; `ReadFile` at an offset on
## Windows), never through a map. A read that fails (an I/O error: a network
## share that went away, a server that timed out) or meets a cut is an
## ordinary failed read: no signal, no handler, and the next read tries
## again, so a retry works once the share is back.
##
## The bytes live in an anonymous region of the file's size, reserved but
## not committed (`mmap(MAP_ANONYMOUS | MAP_NORESERVE)`; Windows
## `VirtualAlloc(MEM_RESERVE)`), at the offsets they have in the file: every
## reader keeps its offsets and its bounds checks against the file's size,
## and decodes the same bytes at the same places as from a map. A reader
## *holds* a byte range before it reads it (`hold`): the blocks
## (`BlockBytes`, 64 KiB) that cover it are pinned, and the missing ones are
## read in one request per run of consecutive blocks, outside the lock. A
## miss that starts within the read-ahead window after the previous miss
## doubles the window (64 KiB up to 16 MiB) and reads that far ahead, and the
## window after it is asked for ahead (`adviseRange`): a walk of the headers
## or a loop over traces makes few, large requests, which is what a network
## share needs (its cost is the round trips). Blocks no hold
## pins stay loaded up to a budget (64 MiB a file), the least recently used
## going first (their pages go back to the OS: Linux `MADV_DONTNEED`, fresh
## zero pages mapped over them elsewhere; Windows decommits them).
##
## One lock and one condition per file. A block another thread is reading is
## waited for; a hold never waits while blocks it marked are being read (it
## marks its missing blocks only after every block in its range is settled),
## so two holds cannot wait for each other. A hold that waited for a read
## that failed fails too, without reading again: on a share that is down
## each caller then waits once, not once per thread.
##
## `-d:parseSegReadCacheStress` (tests): 4 KiB blocks, no read-ahead, no
## budget (every block goes when its last hold does) and evicted blocks
## filled with 0xA5, so that a read outside a hold decodes garbage.
##
## Raw pointers and locks only: `hold`, a `Hold`'s release, `holds` and
## `writeAt` make no managed objects and raise nothing, so the prefetch
## workers call them.

import std/[locks, atomics, oserrors]
import ./mapguard
when defined(posix):
  import std/posix
elif defined(windows):
  import std/winlean

const
  stress = defined(parseSegReadCacheStress)
  BlockShift = when stress: 12 else: 16
  BlockBytes* = 1 shl BlockShift ## The unit read and kept: 64 KiB.
  AheadFirst = 1
    ## Blocks read after a miss that follows no other (a random read: one block).
  AheadMax = when stress: 1 else: (16 shl 20) shr BlockShift
    ## The read-ahead window's limit: 16 MiB (NFS reads ahead about as far);
    ## while a stream goes on, the next window is asked for ahead too.
  DefaultBudget* = when stress: 0 else: (64 shl 20) shr BlockShift
    ## Blocks kept loaded with no hold on them: 64 MiB (a viewer's window and
    ## the one before stay; a read of a block that left the cache gets fresh
    ## pages, about 2 GB/s here against 10 GB/s into pages in use).
  Poison = 0xA5'u8

type
  ReadStatus* = enum
    ## The outcome of `hold`.
    rsOk     ## Every byte of the range is held.
    rsCut
      ## The file ends before the range does: it was cut short while open
      ## (the source's cut is lowered); the bytes past its end read as zeros.
    rsFailed
      ## A read failed (an I/O error): the blocks it did not read are held
      ## but empty (`holds` tells which); a later hold reads them again.

  BlockState = enum bsEmpty, bsLoading, bsLoaded

  CacheBlock = object
    pins: int32       # holds on the block
    state: BlockState # empty, being read by the hold that marked it, loaded
    prev, next: int32 # the list of loaded blocks without pins (-1: none)

  ReadCache* = object
    ## An unmapped file: its descriptor, the region, the blocks' states.
    when defined(windows):
      handle: Handle
    else:
      fd: cint
    writable: bool
    base: ptr UncheckedArray[byte]
    size: int64       # the file's size when opened
    reserved: int     # bytes of the region: whole blocks
    count: int        # blocks
    blocks: ptr UncheckedArray[CacheBlock]
    guard: MapGuard   # the source's cut, lowered on a short read
    lock: Lock        # guards the blocks and the fields below
    settled: Cond     # a read of blocks ended
    newest, oldest: int32 # ends of the list of loaded blocks without pins
    kept: int         # blocks in that list
    budget: int       # at most this many are kept
    aheadEnd: int     # the block after the last miss read: a miss there is sequential
    aheadWindow: int  # blocks read ahead now
    failures: int     # reads that failed
    lastError: int32  # the OS error of the last failed read
    requests: Atomic[int]   # read requests made (tests, measurements)
    bytesRead: Atomic[int64]

  Hold* = object
    ## Pins blocks `first .. last` of a cache until it is destroyed: their
    ## bytes may be read. Not copyable; an empty hold (the default, and
    ## every hold of a mapped file) pins nothing.
    c: ptr ReadCache
    first, last: int

proc release(c: ptr ReadCache, first, last: int) {.raises: [].}

proc `=destroy`*(h: Hold) =
  if h.c != nil: release(h.c, h.first, h.last)

proc `=copy`*(dst: var Hold, src: Hold) {.error.}
proc `=dup`*(src: Hold): Hold {.error.}

# ------------------------------------------------------------ the region --

when defined(posix):
  proc c_madvise(a: pointer, len: csize_t, advice: cint): cint {.importc: "madvise",
    header: "<sys/mman.h>".}
  when defined(linux):
    var
      MADV_DONTNEED {.importc, header: "<sys/mman.h>".}: cint
      MADV_NOHUGEPAGE {.importc, header: "<sys/mman.h>".}: cint

  proc reserve(bytes: int): pointer {.raises: [].} =
    let p = mmap(nil, bytes, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS or MAP_NORESERVE, -1, 0)
    if p == MAP_FAILED: return nil
    when defined(linux):
      # Small pages: with transparent huge pages a first touch zeroes 2 MiB
      # and freeing one block splits a huge page (sequential reads past the
      # budget ran at 1.4 GB/s instead of 6 GB/s).
      discard c_madvise(p, csize_t(bytes), MADV_NOHUGEPAGE)
    p

  proc unreserve(p: pointer, bytes: int) {.raises: [].} =
    discard munmap(p, bytes)

  proc commit(p: pointer, bytes: int): bool {.inline, raises: [].} = true

  proc clear(p: pointer, bytes: int) {.raises: [].} =
    # The pages of `p` (whole blocks) go back to the OS and read as zeros:
    # Linux `MADV_DONTNEED`; elsewhere (macOS keeps the pages on that advice)
    # fresh zero pages mapped over them.
    when defined(linux):
      if c_madvise(p, csize_t(bytes), MADV_DONTNEED) == 0: return
    if mmap(p, bytes, PROT_READ or PROT_WRITE,
        MAP_PRIVATE or MAP_ANONYMOUS or MAP_NORESERVE or MAP_FIXED, -1, 0) == MAP_FAILED:
      zeroMem(p, bytes)

elif defined(windows):
  const
    MemCommit = 0x1000'u32
    MemReserve = 0x2000'u32
    MemDecommit = 0x4000'u32
    MemRelease = 0x8000'u32
    PageNoAccess = 0x01'u32
    PageReadWrite = 0x04'u32
  proc virtualAlloc(a: pointer, size: csize_t, kind, protect: uint32): pointer {.
    stdcall, importc: "VirtualAlloc", header: "<windows.h>".}
  proc virtualFree(a: pointer, size: csize_t, kind: uint32): int32 {.
    stdcall, importc: "VirtualFree", header: "<windows.h>".}

  proc reserve(bytes: int): pointer {.raises: [].} =
    virtualAlloc(nil, csize_t(bytes), MemReserve, PageNoAccess)

  proc unreserve(p: pointer, bytes: int) {.raises: [].} =
    discard virtualFree(p, 0, MemRelease)

  proc commit(p: pointer, bytes: int): bool {.raises: [].} =
    # Committed pages read as zeros until written.
    virtualAlloc(p, csize_t(bytes), MemCommit, PageReadWrite) != nil

  proc clear(p: pointer, bytes: int) {.raises: [].} =
    # Decommitted: a read there faults, but only a hold reads, and a hold
    # commits what it reads again.
    discard virtualFree(p, csize_t(bytes), MemDecommit)

proc c_memset(p: pointer, c: cint, n: csize_t): pointer {.importc: "memset",
  header: "<string.h>", discardable.}

template blockAt(c: ptr ReadCache, i: int): pointer =
  cast[pointer](addr c.base[i shl BlockShift])

proc emptyBlocks(c: ptr ReadCache, first, stop: int) {.raises: [].} =
  # Blocks `first ..< stop` hold nothing again: zero pages (stress: poison).
  if stop > first:
    when stress:
      c_memset(c.blockAt(first), cint(Poison), csize_t((stop - first) shl BlockShift))
    else:
      clear(c.blockAt(first), (stop - first) shl BlockShift)

# ------------------------------------------------------------- the file --

when defined(posix):
  var errnoVar {.importc: "errno", header: "<errno.h>".}: cint

  proc readAt(c: ptr ReadCache, p: pointer, n: int, at: int64, err: var int32): int {.
      raises: [].} =
    # One request: bytes read (0 at the end of the file), -1 on an error.
    while true:
      let r = pread(c.fd, p, n, Off(at))
      if r >= 0: return r
      if errnoVar != EINTR:
        err = errnoVar
        return -1

  proc writeAtFile(c: ptr ReadCache, p: pointer, n: int, at: int64, err: var int32): int {.
      raises: [].} =
    while true:
      let r = pwrite(c.fd, p, n, Off(at))
      if r >= 0: return r
      if errnoVar != EINTR:
        err = errnoVar
        return -1

  proc fileSize*(c: ptr ReadCache): int64 {.raises: [].} =
    ## The file's size now (`fstat`), -1 when it cannot be had.
    var st: Stat
    if fstat(c.fd, st) == 0: int64(st.st_size) else: -1

  proc sync*(c: ptr ReadCache): bool {.raises: [].} =
    ## Writes the file's changed data to the device (`fsync`).
    fsync(c.fd) == 0

  when defined(linux) or defined(freebsd) or defined(netbsd):
    var POSIX_FADV_WILLNEED {.importc, header: "<fcntl.h>".}: cint
    proc c_fadvise(fd: cint, offset, len: Off, advice: cint): cint {.
      importc: "posix_fadvise", header: "<fcntl.h>".}
  elif defined(macosx):
    type RAdvisory {.importc: "struct radvisory", header: "<fcntl.h>".} = object
      ra_offset: Off
      ra_count: cint
    var F_RDADVISE {.importc, header: "<fcntl.h>".}: cint

  proc adviseRange*(c: ptr ReadCache, a, b: int64) {.raises: [].} =
    ## Asks the OS to read bytes `a ..< b` into its page cache now, without
    ## waiting (`posix_fadvise(WILLNEED)`; macOS `F_RDADVISE`; nothing on
    ## Windows): a share's client sends the requests for many ranges at once,
    ## and the reads that follow find them there. A hint: failures are
    ## ignored. The unmapped form of the map's `madvise(WILLNEED)`.
    # Whole blocks: what the reads that follow ask for.
    let lo = max(a, 0'i64) and not int64(BlockBytes - 1)
    let hi = min((b + BlockBytes - 1) and not int64(BlockBytes - 1), c.size)
    if hi <= lo: return
    when defined(linux) or defined(freebsd) or defined(netbsd):
      discard c_fadvise(c.fd, Off(lo), Off(hi - lo), POSIX_FADV_WILLNEED)
    elif defined(macosx):
      var ra = RAdvisory(ra_offset: Off(lo), ra_count: cint(min(hi - lo, int64(high(cint)))))
      discard posix.fcntl(c.fd, F_RDADVISE, addr ra)

elif defined(windows):
  type LargeInteger {.importc: "LARGE_INTEGER", header: "<windows.h>".} = object
    QuadPart: int64
  proc getFileSizeEx(h: pointer, size: ptr LargeInteger): int32 {.stdcall,
    importc: "GetFileSizeEx", header: "<windows.h>".}
    # `HANDLE` in C: winlean's `Handle` is an integer

  proc readAt(c: ptr ReadCache, p: pointer, n: int, at: int64, err: var int32): int {.
      raises: [].} =
    # `ReadFile` at an offset (a synchronous handle), at most 1 GiB a call.
    var ov: OVERLAPPED
    ov.offset = DWORD(at and 0xFFFF_FFFF)
    ov.offsetHigh = DWORD(at shr 32)
    var got: int32
    if readFile(c.handle, p, int32(min(n, 1 shl 30)), addr got, addr ov) == 0:
      let e = getLastError()
      if e == ERROR_HANDLE_EOF: return 0
      err = e
      return -1
    int(got)

  proc writeAtFile(c: ptr ReadCache, p: pointer, n: int, at: int64, err: var int32): int {.
      raises: [].} =
    var ov: OVERLAPPED
    ov.offset = DWORD(at and 0xFFFF_FFFF)
    ov.offsetHigh = DWORD(at shr 32)
    var put: int32
    if writeFile(c.handle, p, int32(min(n, 1 shl 30)), addr put, addr ov) == 0:
      err = getLastError()
      return -1
    int(put)

  proc fileSize*(c: ptr ReadCache): int64 {.raises: [].} =
    ## The file's size now (`GetFileSizeEx`), -1 when it cannot be had.
    var n: LargeInteger
    if getFileSizeEx(cast[pointer](c.handle), addr n) != 0: n.QuadPart else: -1

  proc sync*(c: ptr ReadCache): bool {.raises: [].} =
    ## Writes the file's changed data to the device (`FlushFileBuffers`).
    flushFileBuffers(c.handle) != 0

  proc adviseRange*(c: ptr ReadCache, a, b: int64) {.raises: [].} =
    ## Nothing on Windows (see the POSIX form).
    discard

# ------------------------------------------------------------ open, close --

proc closeFile(c: ptr ReadCache) {.raises: [].} =
  when defined(windows): discard closeHandle(c.handle)
  else: discard posix.close(c.fd)

proc openReadCache*(path: string, writable: bool, guard: MapGuard): ptr ReadCache =
  ## Opens `path` (read-write when `writable`) for unmapped reads, with an
  ## empty cache; `guard` (a `newTrackSlot`) gets the cut when a read finds
  ## the file shorter. Raises `IOError` when the file cannot be opened or
  ## its size had, `OSError` when its region cannot be reserved. An empty
  ## file has no region (`memory` nil).
  result = createShared(ReadCache)
  let c = result
  when defined(windows):
    let access = if writable: GENERIC_READ or GENERIC_WRITE else: GENERIC_READ
    c.handle = createFileW(newWideCString(path), access,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0)
    if c.handle == INVALID_HANDLE_VALUE:
      let e = osLastError()
      freeShared(c)
      raise newException(IOError, "cannot open " & path & ": " & osErrorMsg(e))
  else:
    c.fd = posix.open(path.cstring, (if writable: O_RDWR else: O_RDONLY) or O_CLOEXEC)
    if c.fd < 0:
      let e = osLastError()
      freeShared(c)
      raise newException(IOError, "cannot open " & path & ": " & osErrorMsg(e))
  c.size = c.fileSize
  if c.size < 0:
    let e = osLastError()
    c.closeFile()
    freeShared(c)
    raise newException(IOError, "cannot get the size of " & path & ": " & osErrorMsg(e))
  c.writable = writable
  c.guard = guard
  c.count = int((c.size + BlockBytes - 1) shr BlockShift)
  c.reserved = c.count shl BlockShift
  if c.count > 0:
    c.base = cast[ptr UncheckedArray[byte]](reserve(c.reserved))
    if c.base == nil:
      let e = osLastError()
      c.closeFile()
      freeShared(c)
      raise newException(OSError, "cannot reserve " & $c.reserved & " bytes of memory for " &
        path & ": " & osErrorMsg(e))
    c.blocks = cast[ptr UncheckedArray[CacheBlock]](createSharedU(CacheBlock, c.count))
    for i in 0 ..< c.count:
      c.blocks[i] = CacheBlock(pins: 0, state: bsEmpty, prev: -1, next: -1)
    when stress: c_memset(c.base, cint(Poison), csize_t(c.reserved))
  c.newest = -1
  c.oldest = -1
  c.budget = DefaultBudget
  c.aheadWindow = AheadFirst
  initLock(c.lock)
  initCond(c.settled)

proc closeCache*(c: ptr ReadCache) {.raises: [].} =
  ## Closes the file and frees the region. No hold may be left (nil: nothing
  ## to do).
  if c == nil: return
  if c.base != nil: unreserve(c.base, c.reserved)
  if c.blocks != nil: freeShared(c.blocks)
  c.closeFile()
  deinitCond(c.settled)
  deinitLock(c.lock)
  freeShared(c)

proc region*(c: ptr ReadCache): ptr UncheckedArray[byte] {.inline, raises: [].} =
  ## The region: byte `i` of the file at `memory[i]`, valid under a hold.
  c.base

proc openedSize*(c: ptr ReadCache): int64 {.inline, raises: [].} =
  ## The file's size when it was opened.
  c.size

proc requests*(c: ptr ReadCache): int {.raises: [].} =
  ## Read requests made so far (each `pread` or `ReadFile` call).
  c.requests.load(moRelaxed)

proc bytesRead*(c: ptr ReadCache): int64 {.raises: [].} =
  ## Bytes those requests returned.
  c.bytesRead.load(moRelaxed)

proc errorText*(c: ptr ReadCache): string =
  ## The OS's message for the last read that failed.
  acquire(c.lock)
  let e = c.lastError
  release(c.lock)
  osErrorMsg(OSErrorCode(e))

# ---------------------------------------------------- the list, eviction --

proc unlink(c: ptr ReadCache, i: int) {.raises: [].} =
  let b = addr c.blocks[i]
  if b.prev >= 0: c.blocks[b.prev].next = b.next else: c.newest = b.next
  if b.next >= 0: c.blocks[b.next].prev = b.prev else: c.oldest = b.prev
  b.prev = -1
  b.next = -1
  dec c.kept

proc linkNewest(c: ptr ReadCache, i: int) {.raises: [].} =
  let b = addr c.blocks[i]
  b.prev = -1
  b.next = c.newest
  if c.newest >= 0: c.blocks[c.newest].prev = int32(i) else: c.oldest = int32(i)
  c.newest = int32(i)
  inc c.kept

proc evictOver(c: ptr ReadCache) {.raises: [].} =
  # Under the lock: the oldest blocks without pins go until `budget` are left
  # (an eighth less once over it, so that a stream frees many at a time);
  # neighbours in the file go back to the OS in one call.
  if c.kept <= c.budget: return
  let target = c.budget - c.budget div 8
  var runA, runB = -1 # blocks runA ..< runB, emptied together
  while c.kept > target:
    let i = int(c.oldest)
    c.unlink(i)
    c.blocks[i].state = bsEmpty
    if i == runB: inc runB
    else:
      c.emptyBlocks(runA, runB)
      (runA, runB) = (i, i + 1)
  c.emptyBlocks(runA, runB)

proc release(c: ptr ReadCache, first, last: int) {.raises: [].} =
  if last < first: return
  acquire(c.lock)
  for i in first .. last:
    let b = addr c.blocks[i]
    dec b.pins
    if b.pins == 0 and b.state == bsLoaded: c.linkNewest(i)
  c.evictOver()
  release(c.lock)

proc drop*(h: var Hold) {.raises: [].} =
  ## Releases `h` now (it is empty after).
  if h.c != nil:
    release(h.c, h.first, h.last)
    h.c = nil

proc dropUnpinned*(c: ptr ReadCache) {.raises: [].} =
  ## Empties every block no hold pins (a cold start for measurements; tests).
  acquire(c.lock)
  let budget = c.budget
  c.budget = 0
  c.evictOver()
  c.budget = budget
  c.aheadEnd = 0
  c.aheadWindow = AheadFirst
  release(c.lock)

proc setBudget*(c: ptr ReadCache, blocks: Natural) {.raises: [].} =
  ## Keeps at most `blocks` loaded blocks without holds (tests).
  acquire(c.lock)
  c.budget = blocks
  c.evictOver()
  release(c.lock)

# ------------------------------------------------------------------ hold --

proc readRun(c: ptr ReadCache, i, j: int, err: var int32): tuple[got: int64, st: ReadStatus] {.
    raises: [].} =
  # Reads blocks `i ..< j` (marked loading by this hold). Bytes read from the
  # run's start; past the end of the file the run is zeros.
  let at = int64(i) shl BlockShift
  let want = min(int64(j) shl BlockShift, c.size) - at
  if not commit(c.blockAt(i), (j - i) shl BlockShift):
    when defined(windows): err = getLastError()
    return (0'i64, rsFailed)
  var got = 0'i64
  while got < want:
    let n = c.readAt(addr c.base[at + got], int(want - got), at + got, err)
    c.requests.atomicInc
    if n < 0: return (got, rsFailed)
    if n == 0:
      # The file ends here: cut short since it was opened.
      zeroMem(addr c.base[at + got], int((int64(j) shl BlockShift) - at - got))
      let now = c.fileSize
      lowerGuardCut(c.guard, if now >= 0: min(now, at + got) else: at + got)
      return (got, rsCut)
    c.bytesRead.atomicInc(int64(n))
    got += n
  (got, rsOk)

proc settle(c: ptr ReadCache, i, j, last: int, got: int64, st: ReadStatus) {.raises: [].} =
  # Under the lock, after `readRun(i, j)`: the blocks read are loaded (those
  # past the hold, `last`, read ahead, go to the list), the others empty.
  let whole = int(got shr BlockShift) # blocks read in full
  for k in i ..< j:
    let b = addr c.blocks[k]
    let done = st != rsFailed or k - i < whole or
      (int64(k + 1) shl BlockShift) - (int64(i) shl BlockShift) <= got
    if done:
      b.state = bsLoaded
      if b.pins == 0: c.linkNewest(k)
    else:
      b.state = bsEmpty
  if st == rsFailed:
    # The part of a block read before the error is not kept.
    let firstEmpty = i + whole
    var stop = firstEmpty
    while stop < j and c.blocks[stop].state == bsEmpty: inc stop
    c.emptyBlocks(firstEmpty, stop)

proc hold*(c: ptr ReadCache, a, b: int64, h: var Hold): ReadStatus {.raises: [].} =
  ## Holds bytes `a ..< b` (clipped to the file) in `h`, reading the blocks
  ## that are missing: `rsOk`, `rsCut` when the file ends before `b` (also a
  ## cut found before: the bytes past it are zeros, not read), `rsFailed`
  ## when a read failed (this one, or another thread's that it waited for).
  ## What `h` held before is released first. The bytes of the range may be
  ## read until `h` is destroyed or dropped.
  h.drop()
  let lo = max(a, 0'i64)
  let hi = min(b, c.size)
  if hi <= lo: return rsOk
  let first = int(lo shr BlockShift)
  let last = int((hi - 1) shr BlockShift)
  let cut = c.guard.guardCut
  acquire(c.lock)
  # Every block of the range settled first: none marked by this hold yet,
  # so this wait never holds up another hold's read.
  var failed = false
  while true:
    var busy = -1
    for i in first .. last:
      if c.blocks[i].state == bsLoading:
        busy = i
        break
    if busy < 0: break
    let before = c.failures
    wait(c.settled, c.lock)
    if c.blocks[busy].state == bsEmpty and c.failures != before:
      failed = true # the read waited for failed: this hold does not try again
      break
  for i in first .. last:
    let blk = addr c.blocks[i]
    if blk.pins == 0 and blk.state == bsLoaded: c.unlink(i)
    inc blk.pins
  h = Hold(c: c, first: first, last: last)
  if failed:
    release(c.lock)
    return rsFailed
  # Missing blocks: those past a known cut are zeros, the others this hold reads.
  var firstMiss = -1
  var lastMiss = -1
  for i in first .. last:
    let blk = addr c.blocks[i]
    if blk.state == bsEmpty:
      if (int64(i) shl BlockShift) >= cut:
        when stress: zeroMem(c.blockAt(i), BlockBytes)
        if commit(c.blockAt(i), BlockBytes): blk.state = bsLoaded
      else:
        blk.state = bsLoading
        if firstMiss < 0: firstMiss = i
        lastMiss = i
  var stop = last + 1
  var adviseFrom, adviseTo = 0 # the window after this one, asked for ahead (a stream)
  if firstMiss >= 0:
    # Read-ahead: a miss within the window after the last one doubles it.
    if firstMiss >= c.aheadEnd and firstMiss <= c.aheadEnd + c.aheadWindow:
      c.aheadWindow = min(c.aheadWindow * 2, AheadMax)
    else:
      c.aheadWindow = AheadFirst
    if lastMiss == last:
      var runStart = last
      while runStart > first and c.blocks[runStart - 1].state == bsLoading: dec runStart
      let limit = min(c.count, min(runStart + c.aheadWindow, last + 1 + c.budget div 2))
      while stop < limit and c.blocks[stop].state == bsEmpty and
          (int64(stop) shl BlockShift) < cut:
        c.blocks[stop].state = bsLoading
        inc stop
      if c.aheadWindow > AheadFirst:
        # A stream: the OS fetches the next window while this one is read and
        # used (a share's client has its requests in flight meanwhile).
        adviseFrom = stop
        adviseTo = min(c.count, stop + c.aheadWindow)
    c.aheadEnd = stop
  release(c.lock)
  if adviseTo > adviseFrom:
    c.adviseRange(int64(adviseFrom) shl BlockShift, int64(adviseTo) shl BlockShift)
  result = if hi > cut: rsCut else: rsOk
  if firstMiss < 0: return
  # Read each run of blocks this hold marked, outside the lock: no other
  # hold changes them meanwhile (it waits for them).
  var i = firstMiss
  while i < stop:
    if c.blocks[i].state != bsLoading:
      inc i
      continue
    var j = i + 1
    while j < stop and c.blocks[j].state == bsLoading: inc j
    var err = 0'i32
    let (got, st) = c.readRun(i, j, err)
    acquire(c.lock)
    c.settle(i, j, last, got, st)
    if st == rsFailed:
      inc c.failures
      c.lastError = err
    broadcast(c.settled)
    c.evictOver()
    release(c.lock)
    if st == rsFailed: result = rsFailed
    elif st == rsCut and result == rsOk: result = rsCut
    i = j

proc holds*(c: ptr ReadCache, a, b: int64): bool {.raises: [].} =
  ## Every block of bytes `a ..< b` is loaded: after a hold of them that
  ## failed, the bytes that arrived (they stay while the hold does).
  let lo = max(a, 0'i64)
  let hi = min(b, c.size)
  if hi <= lo: return true
  result = true
  acquire(c.lock)
  for i in int(lo shr BlockShift) .. int((hi - 1) shr BlockShift):
    if c.blocks[i].state != bsLoaded:
      result = false
      break
  release(c.lock)

proc writeAt*(c: ptr ReadCache, at: int64, src: pointer, n: int, err: var int32): bool {.
    raises: [].} =
  ## Writes `n` bytes to the file at `at` (`pwrite`), then into the loaded
  ## blocks that hold them, so later reads see them. False, with the OS
  ## error in `err`, when the write failed (then the blocks are read again).
  if n <= 0: return true
  var h: Hold
  discard c.hold(at, at + n, h) # the blocks around the bytes, as they are now
  var done = 0
  while done < n:
    let r = c.writeAtFile(cast[pointer](cast[uint](src) + uint(done)), n - done,
      at + done, err)
    if r <= 0:
      if r == 0: err = 0
      h.drop()
      # What reached the file is unknown: its blocks are read again.
      acquire(c.lock)
      for i in int(at shr BlockShift) .. int((at + n - 1) shr BlockShift):
        let b = addr c.blocks[i]
        if b.pins == 0 and b.state == bsLoaded:
          c.unlink(i)
          b.state = bsEmpty
          c.emptyBlocks(i, i + 1)
      release(c.lock)
      return false
    done += r
  # Into the blocks that are loaded (a block that could not be read is read
  # from the file, which has the bytes now).
  var k = at
  while k < at + n:
    let blockEnd = min(((k shr BlockShift) + 1) shl BlockShift, at + n)
    if c.holds(k, blockEnd):
      copyMem(addr c.base[k], cast[pointer](cast[uint](src) + uint(k - at)), int(blockEnd - k))
    k = blockEnd
  true

type
  Cursor* = object
    ## A hold that a reader moving forward keeps from one read to the next:
    ## `cover` holds what the next read needs, in windows that double while
    ## the reads go on forward (one block up to `CursorMax`), so a walk takes
    ## a lock now and then, not once per header.
    h: Hold
    lo, hi: int64 # the window held: bytes `lo ..< hi`
    ahead: int64  # the next window's size

const CursorMax* = 4'i64 shl 20 ## A cursor's largest window.

proc cover*(c: ptr ReadCache, cur: var Cursor, a, b: int64): ReadStatus {.raises: [].} =
  ## Holds bytes `a ..< b` in `cur`: nothing to do when its window covers
  ## them, else a new window from `a` (the old one is released). After
  ## `rsFailed`, `holds` says whether these bytes arrived; the window is not
  ## kept then, so the next call reads again.
  if cur.h.c != nil and a >= cur.lo and b <= cur.hi: return rsOk
  if cur.ahead == 0 or a < cur.hi or a - cur.hi > cur.ahead: cur.ahead = BlockBytes
  else: cur.ahead = min(cur.ahead * 2, CursorMax)
  let want = max(b, a + cur.ahead)
  result = c.hold(a, want, cur.h)
  cur.lo = a
  cur.hi = if result == rsFailed: a else: want

proc drop*(cur: var Cursor) {.raises: [].} =
  ## Releases the window.
  cur.h.drop()
  cur.lo = 0
  cur.hi = 0

