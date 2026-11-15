## A mapped file cut short while it is mapped must not end the program. On
## POSIX a read of a mapped page that lies wholly past the file's end raises
## `SIGBUS`, and another program (a recorder, a copy over the file, a sync
## tool) can cut a file at any time. Every map of a `MemFileSource` is
## registered here, with the file's descriptor. A `SIGBUS` handler, installed
## with the first map, finds the map the faulting address lies in, lowers its
## `cut` (the bytes still in the file: the least of the faulting page's
## offset and the file's size now) and maps anonymous zero pages over the
## map from that page to its end, so the read goes on over zeros. Readers
## compare what they read with `guardCut` afterwards and fail what lies past
## it. A fault at any other address goes to the handler installed before
## this one (Nim's, a sanitizer's, the default).
##
## The fast path costs one atomic load per check (`guardCut`). The handler
## uses only async-signal-safe system calls (`fstat`, `mmap`, `sigaction`,
## `raise`) and no managed memory. Windows refuses to cut a mapped file, so
## nothing is registered there.
##
## The OS gives zeros, not a fault, for the bytes between a new end and the
## end of its page: a read of those alone is not seen as cut until some read
## reaches a page past them, or `lowerGuardCut` is told the size.

import std/atomics
when defined(posix):
  import std/[locks, oserrors, posix]

const mapsGuarded* = defined(posix) and not defined(nimscript)
  ## Maps are guarded on this platform.

type
  GuardSlot = object
    used: bool           # taken; read and changed under `guardLock`
    span: uint           # bytes of the map, rounded up to whole pages
    fd: cint             # the mapped file's descriptor, for its size
    writable: bool       # the map is writable: the zero pages are too
    cut: Atomic[int64]   # bytes still in the file; high(int64) until a cut is seen
    base: Atomic[uint]   # the map's address; 0 while the slot is free

  MapGuard* = ptr GuardSlot
    ## A registered map (nil: not guarded: an empty file, Windows).

const SlotsPerBlock = 64

type
  SlotBlock = object
    slots: array[SlotsPerBlock, GuardSlot]
    next: Atomic[ptr SlotBlock] # blocks are added at the end and never freed

when mapsGuarded:
  var
    guardLock: Lock          # guards `used`, adding blocks and the installation
    installed: bool          # under `guardLock`
    firstBlock: SlotBlock    # the handler walks the blocks from here
    previous: Sigaction      # the SIGBUS action before ours
    pageMask: uint

  initLock(guardLock)

  var errnoVar {.importc: "errno", header: "<errno.h>".}: cint
  proc c_raise(sig: cint): cint {.importc: "raise", header: "<signal.h>".}
  proc c_sigaction(sig: cint, act, old: ptr Sigaction): cint {.
    importc: "sigaction", header: "<signal.h>".}
    # `std/posix` has no form that only reads the action (`act` nil).

  {.push stackTrace: off, lineTrace: off, checks: off.}

  proc lowerCut(s: ptr GuardSlot, cut: int64) {.inline, raises: [].} =
    var cur = s.cut.load(moRelaxed)
    while cut < cur and not s.cut.compareExchangeWeak(cur, cut, moSequentiallyConsistent,
        moRelaxed):
      discard

  proc chain(sig: cint, info: ptr SigInfo, ctx: pointer) {.raises: [].} =
    # The fault is not ours: what the action before ours would have done.
    # A C signal handler raises no Nim exception (Nim's own ends the process).
    type
      InfoHandler = proc (sig: cint, info: ptr SigInfo, ctx: pointer) {.noconv, raises: [].}
      PlainHandler = proc (sig: cint) {.noconv, raises: [].}
    if (previous.sa_flags and SA_SIGINFO) != 0:
      # `sa_sigaction` is a template on Linux (a union member in C).
      let h = cast[InfoHandler](previous.sa_sigaction)
      if h != nil:
        h(sig, info, ctx)
        return
    else:
      let h = previous.sa_handler
      if h != SIG_DFL and h != SIG_IGN and h != nil:
        cast[PlainHandler](h)(sig)
        return
    # The default action, restored, and the signal raised again: blocked
    # while this handler runs, it ends the process when the handler returns.
    var dfl: Sigaction
    dfl.sa_handler = SIG_DFL
    discard sigemptyset(dfl.sa_mask)
    discard c_sigaction(SIGBUS, addr dfl, nil)
    discard c_raise(sig)

  proc onBus(sig: cint, info: ptr SigInfo, ctx: pointer) {.noconv, raises: [].} =
    let saved = errnoVar
    if info != nil:
      let a = cast[uint](info.si_addr)
      var b = addr firstBlock
      while b != nil:
        for i in 0 ..< SlotsPerBlock:
          let s = addr b.slots[i]
          let base = s.base.load(moAcquire)
          if base != 0 and a >= base and a - base < s.span:
            let page = (a - base) and not pageMask
            var cut = int64(page)
            var st: Stat
            if fstat(s.fd, st) == 0 and int64(st.st_size) < cut: cut = int64(st.st_size)
            s.lowerCut(cut)
            let prot = if s.writable: PROT_READ or PROT_WRITE else: PROT_READ
            if mmap(cast[pointer](base + page), int(s.span - page), prot,
                MAP_PRIVATE or MAP_ANONYMOUS or MAP_FIXED, -1, 0) != MAP_FAILED:
              errnoVar = saved
              return # the faulting access runs again, over zeros
            b = nil  # could not map: the fault ends the process as before
            break
        if b != nil: b = b.next.load(moAcquire)
    errnoVar = saved
    chain(sig, info, ctx)

  {.pop.}

  proc install() =
    # Under `guardLock`. The previous action is read first, so it is in
    # place before the handler can run.
    pageMask = uint(sysconf(SC_PAGESIZE)) - 1
    if c_sigaction(SIGBUS, nil, addr previous) != 0: raiseOSError(osLastError(), "sigaction")
    var act: Sigaction
    act.sa_sigaction = onBus
    act.sa_flags = SA_SIGINFO or SA_ONSTACK
    discard sigemptyset(act.sa_mask)
    if c_sigaction(SIGBUS, addr act, nil) != 0: raiseOSError(osLastError(), "sigaction")
    installed = true

proc guardMap*(mem: pointer, len: int, fd: cint, writable: bool): MapGuard =
  ## Registers the map `mem[0 ..< len]` of the open file `fd`, which stays
  ## open until `unguard`. nil where maps are not guarded, or for an empty
  ## map. Raises `OSError` if the handler cannot be installed.
  when mapsGuarded:
    if mem == nil or len <= 0: return nil
    acquire(guardLock)
    try:
      if not installed: install()
      var b = addr firstBlock
      while result == nil:
        for i in 0 ..< SlotsPerBlock:
          if not b.slots[i].used:
            result = addr b.slots[i]
            break
        if result == nil:
          var next = b.next.load(moAcquire)
          if next == nil:
            next = createShared(SlotBlock) # zeroed: every slot free
            b.next.store(next, moRelease)
          b = next
      result.used = true
      result.span = (uint(len) + pageMask) and not pageMask
      result.fd = fd
      result.writable = writable
      result.cut.store(high(int64), moRelaxed)
      result.base.store(cast[uint](mem), moRelease) # last: the handler may see it now
    finally:
      release(guardLock)
  else:
    nil

proc unguard*(g: MapGuard) =
  ## Unregisters a map, before it is unmapped (nil: nothing to do). A fault
  ## in it after this call ends the process.
  when mapsGuarded:
    if g == nil: return
    g.base.store(0, moRelease)
    acquire(guardLock)
    g.used = false
    release(guardLock)

proc guardCut*(g: MapGuard): int64 {.inline, raises: [].} =
  ## The bytes still in the file as far as a fault (or `lowerGuardCut`) has shown:
  ## `high(int64)` until the file is seen cut short. The reads made before
  ## the call come first (a fence), so a read that met zero pages mapped by
  ## another thread's fault sees that thread's cut.
  if g == nil: return high(int64)
  fence(moAcquire)
  g.cut.load(moAcquire)

proc lowerGuardCut*(g: MapGuard, size: int64) {.raises: [].} =
  ## Lowers the cut to `size` when the file is known to hold no more.
  when mapsGuarded:
    if g != nil: g.lowerCut(size)

proc guardedFileSize*(g: MapGuard): int64 {.raises: [].} =
  ## The file's size now (`fstat` of its descriptor, about 0.5 µs), -1 when
  ## it cannot be had or the map is not guarded.
  when mapsGuarded:
    if g == nil: return -1
    var st: Stat
    if fstat(g.fd, st) == 0: int64(st.st_size) else: -1
  else:
    -1
