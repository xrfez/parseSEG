## A read that faults in a map while another thread closes its file (a
## caller's bug, but one that must not corrupt memory): the SIGBUS handler is
## inside the map's slot when `close` unregisters it. The close must wait for
## the handler to leave (or, past `UnguardWaitMs`, leave the map mapped for
## good) instead of unmapping under it: otherwise the handler then maps zero
## pages over memory the process may have reused.
##
## Built with `-d:parseSegGuardTestHook` (tguardslot.nims): the handler, once
## counted into its slot, spins while `parsesegHoldHandler` is set. Seen
## failing without the count (`unguard` returning at once): "close did not
## wait for the handler inside the slot".

import std/[assertions, atomics, monotimes, os, posix, strutils, times, volatile]
import parseSEG
from parseSEG/model/traceindex import unsafeMemory, mappedSize
import parseSEG/private/mapguard
import ./utils/testutils

when not defined(linux) or not mapsGuarded:
  echo "tguardslot: skipped: needs the guard (Linux, without -d:parseSegNoMapGuard)"
  quit 0
else:
  var holdHandler {.importc: "parsesegHoldHandler".}: cint # in mapguard's C (the hook)
  var inHandler {.importc: "parsesegInHandler".}: cint
  proc atomicStore(p: ptr cint, v: cint, order: cint) {.importc: "__atomic_store_n", nodecl.}
  proc atomicLoad(p: ptr cint, order: cint): cint {.importc: "__atomic_load_n", nodecl.}
  const SeqCst = 5 # __ATOMIC_SEQ_CST
  proc store(p: ptr cint, v: cint) = atomicStore(p, v, SeqCst)
  proc load(p: ptr cint): cint = atomicLoad(p, SeqCst)

  let tmp = scratchDir("parseseg_tguardslot")

  proc mappedAt(a: uint): bool =
    ## Some mapping of this process holds address `a`.
    for line in lines("/proc/self/maps"):
      let r = line.split(' ')[0].split('-')
      if fromHex[uint](r[0]) <= a and a < fromHex[uint](r[1]): return true
    false

  var reader: Thread[pointer]
  var done: Atomic[bool]
  var seen: Atomic[int]
  proc readPastTheCut(p: pointer) {.thread.} =
    # One load of a page wholly past the cut: it faults, and the handler holds
    # inside the map's slot. Nothing else of the map is read (a reader racing
    # the close of its own file is the caller's bug; what must not happen is
    # the handler's zero pages landing on memory reused since).
    seen.store(int(volatileLoad(cast[ptr byte](p))))
    done.store(true)

  proc run(releaseAfterMs: int): (float, bool) =
    ## Closes the file while the reader's handler is held in its slot; lets it
    ## go `releaseAfterMs` after the close started (-1: after the close
    ## returned). The close's duration in ms, and whether the map's address
    ## was still mapped right after the close returned.
    let p = tmp / ("survey" & $releaseAfterMs & ".sgy")
    copyFile(demoDir() / "survey.sgy", p)
    var f = openSeismic(p, opts = OpenOptions(access: faMapped))
    let base = cast[uint](f.unsafeMemory)
    let size = getFileSize(p)
    store(addr inHandler, 0)
    store(addr holdHandler, 1)
    doAssert posix.truncate(p.cstring, Off(size div 2)) == 0
    done.store(false)
    seen.store(-1)
    createThread(reader, readPastTheCut, cast[pointer](base + uint(size - 4096) and not 4095'u))
    let t0 = getMonoTime()
    while load(addr inHandler) == 0:
      doAssert getMonoTime() - t0 < initDuration(seconds = 10), "the read never faulted"
      sleep(1)
    var letGo: Thread[int]
    proc release(ms: int) {.thread.} =
      sleep(ms)
      store(addr holdHandler, 0)
    if releaseAfterMs >= 0: createThread(letGo, release, releaseAfterMs)
    let c0 = getMonoTime()
    f.close() # the reader is inside the handler, counted into the map's slot
    let ms = float((getMonoTime() - c0).inMicroseconds) / 1000
    let stillMapped = mappedAt(base)
    if releaseAfterMs < 0: store(addr holdHandler, 0)
    else: joinThread(letGo)
    joinThread(reader)
    doAssert done.load and seen.load == 0 # the read went on over a zero page
    (ms, stillMapped)

  block a_handler_that_leaves_the_slot_is_waited_for:
    # Let go 50 ms into the close: the close waits for it, then unmaps.
    let (ms, mapped) = run(50)
    doAssert ms >= 40, "close did not wait for the handler inside the slot (" & $ms & " ms)"
    doAssert ms < float(UnguardWaitMs), $ms
    doAssert not mapped, "a map whose handler left was not unmapped"

  block a_handler_that_stays_keeps_the_map:
    # Held past `UnguardWaitMs`: the close returns, the map stays (a leak),
    # and the handler's zero pages land on it, not on memory reused since.
    let (ms, mapped) = run(-1)
    doAssert ms >= float(UnguardWaitMs) * 0.9, "close did not wait for the handler (" & $ms &
      " ms)"
    doAssert ms < float(UnguardWaitMs) * 5, "close waited without a bound (" & $ms & " ms)"
    doAssert mapped, "the map was unmapped under a handler still inside its slot"

  block other_files_still_work:
    var g = openSeismic(demoDir() / "survey.sgy", opts = OpenOptions(access: faMapped))
    doAssert g.readTraces(0 ..< g.len).shape[0] == g.len
    g.close()

  echo "tguardslot: ok"
