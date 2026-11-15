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
## it. A fault at any other address, and a `SIGBUS` that a program sent
## (`kill`, `sigqueue`), goes to the handler installed before this one
## (Nim's, a sanitizer's, the default).
##
## The fast path costs one atomic load per check (`guardCut`). The handler
## makes no managed memory, no Nim stack frame (also in a debug build: its
## atomics are the C compiler's builtins) and these system calls only:
## `fstat`, `sigaction` and `raise`, which POSIX lists as async-signal-safe,
## and `mmap`, which it does not list but which is a plain system call on
## Linux and macOS. Windows refuses to cut a mapped file, so nothing is
## registered there.
##
## The OS gives zeros, not a fault, for the bytes between a new end and the
## end of its page: a read of those alone is not seen as cut until some read
## reaches a page past them, or `lowerGuardCut` is told the size.
##
## `-d:parseSegNoMapGuard` leaves the handler out, for a program that owns
## `SIGBUS` itself (a JVM, a Go runtime, a crash reporter that must see every
## fault first): no `sigaction` is made, and a read past a cut, or of a page
## the OS cannot read, ends the program with `SIGBUS` as in parseSEG 0.11.
## Every map still gets its slot and keeps its descriptor (`mapsTracked`), so
## a cut that `lowerGuardCut` is told of (`cutShort` asks the size) fails the
## reads past it as with the guard.

import std/atomics
when defined(posix):
  import std/[locks, posix]

const
  mapsTracked* = defined(posix) and not defined(nimscript)
    ## Maps are registered with their descriptor and cut on this platform.
  mapsGuarded* = mapsTracked and not defined(parseSegNoMapGuard)
    ## The `SIGBUS` handler guards the registered maps (not with
    ## `-d:parseSegNoMapGuard`).

type
  GuardSlot = object
    used: bool           # taken; read and changed under `guardLock`
    span: uint           # bytes of the map, rounded up to whole pages
    fd: cint             # the mapped file's descriptor, for its size
    writable: bool       # the map is writable: the zero pages are too
    cut: Atomic[int64]   # bytes still in the file; high(int64) until a cut is seen
    failed: Atomic[bool] # a fault was a read that failed (an I/O error), not a shorter file
    base: Atomic[uint]   # the map's address; 0 while the slot is free

  MapGuard* = ptr GuardSlot
    ## A registered map (nil: not guarded: an empty file, Windows).

const SlotsPerBlock = 64

type
  SlotBlock = object
    slots: array[SlotsPerBlock, GuardSlot]
    next: Atomic[ptr SlotBlock] # blocks are added at the end and never freed

when mapsTracked:
  var
    guardLock: Lock          # guards `used`, adding blocks and the installation
    installed: bool          # under `guardLock`
    firstBlock: SlotBlock    # the handler walks the blocks from here
    pageMask: uint

  initLock(guardLock)

when mapsGuarded:
  import std/oserrors
  var previous: Sigaction    # the SIGBUS action before ours
  var errnoVar {.importc: "errno", header: "<errno.h>".}: cint
  proc c_raise(sig: cint): cint {.importc: "raise", header: "<signal.h>".}
  proc c_sigaction(sig: cint, act, old: ptr Sigaction): cint {.
    importc: "sigaction", header: "<signal.h>".}
    # `std/posix` has no form that only reads the action (`act` nil).
  when defined(linux):
    var busAdrErr {.importc: "BUS_ADRERR", header: "<signal.h>".}: cint
      # The code of a fault on a page the file no longer backs (or cannot be read).

when mapsTracked:

  # The handler's atomics are the C compiler's builtins (POSIX: gcc or clang),
  # on the same words as the `Atomic` fields: `std/atomics`' procs are Nim
  # procs, which push a stack frame in a debug build.
  var
    atomicRelaxed {.importc: "__ATOMIC_RELAXED", nodecl.}: cint
    atomicAcquire {.importc: "__ATOMIC_ACQUIRE", nodecl.}: cint
    atomicSeqCst {.importc: "__ATOMIC_SEQ_CST", nodecl.}: cint
  proc atomicLoad(p: ptr uint, order: cint): uint {.importc: "__atomic_load_n", nodecl.}
  proc atomicLoad(p: ptr int64, order: cint): int64 {.importc: "__atomic_load_n", nodecl.}
  proc atomicCas(p, expected: ptr int64, desired: int64, weak: bool,
    success, failure: cint): bool {.importc: "__atomic_compare_exchange_n", nodecl.}
  proc atomicStore(p: ptr bool, value: bool, order: cint) {.importc: "__atomic_store_n", nodecl.}
  static:
    doAssert sizeof(Atomic[uint]) == sizeof(uint) and sizeof(Atomic[int64]) == 8 and
      sizeof(Atomic[ptr SlotBlock]) == sizeof(uint) and sizeof(Atomic[bool]) == sizeof(bool)

  {.push stackTrace: off, lineTrace: off, checks: off.}

  proc lowerCut(s: ptr GuardSlot, cut: int64) {.inline, raises: [].} =
    let p = cast[ptr int64](addr s.cut)
    var cur = atomicLoad(p, atomicRelaxed)
    while cut < cur and not atomicCas(p, addr cur, cut, true, atomicSeqCst, atomicRelaxed):
      discard

  {.pop.}

when mapsGuarded:
  {.push stackTrace: off, lineTrace: off, checks: off.}

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

  proc sentByTheKernel(info: ptr SigInfo): bool {.inline.} =
    # A fault of this thread's access, whose `si_addr` is the address: not a
    # `SIGBUS` a program sent (`kill`, `sigqueue`, `raise`), whose `si_addr`
    # is other data (Linux: the sender's pid and uid) and may lie in a map.
    when defined(linux): info.si_code == busAdrErr
    else: info.si_code < 0x10000 # BSD and macOS: `SI_USER` and the like are 0x1000x

  proc onBus(sig: cint, info: ptr SigInfo, ctx: pointer) {.noconv, raises: [].} =
    let saved = errnoVar
    if info != nil and info.sentByTheKernel:
      let a = cast[uint](info.si_addr)
      var b = addr firstBlock
      while b != nil:
        for i in 0 ..< SlotsPerBlock:
          let s = addr b.slots[i]
          let base = atomicLoad(cast[ptr uint](addr s.base), atomicAcquire)
          if base != 0 and a >= base and a - base < s.span:
            let page = (a - base) and not pageMask
            var cut = int64(page)
            var st: Stat
            if fstat(s.fd, st) == 0 and int64(st.st_size) <= cut:
              cut = int64(st.st_size) # the file is shorter: cut short
            else:
              # The file still holds the page (or cannot say): the OS could
              # not read it, an I/O error (a network share gone, a disk).
              atomicStore(cast[ptr bool](addr s.failed), true, atomicSeqCst)
            s.lowerCut(cut)
            let prot = if s.writable: PROT_READ or PROT_WRITE else: PROT_READ
            if mmap(cast[pointer](base + page), int(s.span - page), prot,
                MAP_PRIVATE or MAP_ANONYMOUS or MAP_FIXED, -1, 0) != MAP_FAILED:
              errnoVar = saved
              return # the faulting access runs again, over zeros
            b = nil  # could not map: the fault ends the process as before
            break
        if b != nil: b = cast[ptr SlotBlock](atomicLoad(cast[ptr uint](addr b.next), atomicAcquire))
    errnoVar = saved
    chain(sig, info, ctx)

  {.pop.}

  proc install() =
    # Under `guardLock`. The previous action is read first, so it is in
    # place before the handler can run.
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
  ## map. Raises `OSError` if the handler cannot be installed. With
  ## `-d:parseSegNoMapGuard` the map gets its slot (its cut, its descriptor)
  ## but no handler: a fault in it ends the program.
  when mapsTracked:
    if mem == nil or len <= 0: return nil
    acquire(guardLock)
    try:
      if pageMask == 0: pageMask = uint(sysconf(SC_PAGESIZE)) - 1
      when mapsGuarded:
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
      result.failed.store(false, moRelaxed)
      result.base.store(cast[uint](mem), moRelease) # last: the handler may see it now
    finally:
      release(guardLock)
  else:
    nil

proc unguard*(g: MapGuard) =
  ## Unregisters a map, before it is unmapped (nil: nothing to do). A fault
  ## in it after this call ends the process.
  when mapsTracked:
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

proc guardReadFailed*(g: MapGuard): bool {.inline, raises: [].} =
  ## The cut came from a read the OS could not do (`SIGBUS` on a page the
  ## file, by `fstat`, still holds, or whose size `fstat` could not give: an
  ## I/O error, a network share that went away), not from a shorter file.
  ## A file cut and grown again before the handler asked its size looks so too.
  if g == nil: false else: g.failed.load(moAcquire)

proc lowerGuardCut*(g: MapGuard, size: int64) {.raises: [].} =
  ## Lowers the cut to `size` when the file is known to hold no more.
  if g != nil:
    var cur = g.cut.load(moRelaxed)
    while size < cur and not g.cut.compareExchangeWeak(cur, size, moSequentiallyConsistent, moRelaxed):
      discard

proc newTrackSlot*(): MapGuard {.raises: [].} =
  ## A slot that records a cut and nothing else, for a file read without a
  ## map (`private/readcache`): on every platform, outside the registry, so
  ## no handler ever looks at it. Free it with `freeTrackSlot`.
  result = createShared(GuardSlot)
  result.cut.store(high(int64), moRelaxed)

proc freeTrackSlot*(g: MapGuard) {.raises: [].} =
  ## Frees a slot of `newTrackSlot` (nil: nothing to do).
  if g != nil: freeShared(g)

proc guardedFileSize*(g: MapGuard): int64 {.raises: [].} =
  ## The file's size now (`fstat` of its descriptor, about 0.5 µs), -1 when
  ## it cannot be had or the map is not guarded.
  when mapsTracked:
    if g == nil: return -1
    var st: Stat
    if fstat(g.fd, st) == 0: int64(st.st_size) else: -1
  else:
    -1
