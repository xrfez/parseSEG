## A read cache whose memory cannot be committed (Windows: `VirtualAlloc
## (MEM_COMMIT)` at the commit limit; injected here, `-d:parseSegFailCommits`)
## fails the hold, so no reader reads an uncommitted block: for blocks past a
## cut already known (their zeros need committed memory) and for blocks to
## be read. A later hold tries again. Seen failing with a commit past the cut
## that failed silently: "past a known cut: rsCut" (the hold said the bytes
## were there; on Windows a read of them is an access violation).

# test-separate: needs -d:parseSegFailCommits from tcommitfail.nims

import std/[assertions, atomics, os]

import parseSEG/private/[mapguard, readcache]

import ./utils/testutils

proc main*() =
  let dir = scratchDir("parseseg_tcommitfail")

  let path = dir / "four.bin"

  var bytes = newSeq[byte](4 * BlockBytes)

  for i in 0 ..< bytes.len: bytes[i] = byte(i mod 251 + 1)

  writeBytes(path, bytes)

  let g = newTrackSlot()

  let c = openReadCache(path, false, g)

  block a_block_to_read:
    var h: Hold
    failCommits.store(1)
    let st = c.hold(0, BlockBytes, h)
    doAssert st == rsFailed, "reading a block: " & $st
    doAssert not c.holds(0, BlockBytes)
    doAssert failCommits.load == 0
    doAssert c.hold(0, BlockBytes, h) == rsOk # the next hold reads it
    doAssert c.holds(0, BlockBytes)
    doAssert c.region[0] == 1 and c.region[BlockBytes - 1] == bytes[BlockBytes - 1]
    h.drop()

  block past_a_known_cut:
    lowerGuardCut(g, 2 * BlockBytes) # as a short read or `cutShort` finds it
    var h: Hold
    failCommits.store(1)
    let st = c.hold(2 * BlockBytes, 3 * BlockBytes, h)
    doAssert st == rsFailed, "past a known cut: " & $st
    doAssert not c.holds(2 * BlockBytes, 3 * BlockBytes)
    doAssert c.hold(2 * BlockBytes, 3 * BlockBytes, h) == rsCut # the next commits
    doAssert c.holds(2 * BlockBytes, 3 * BlockBytes)
    for i in 2 * BlockBytes ..< 3 * BlockBytes: doAssert c.region[i] == 0, $i
    h.drop()

  block straddling_the_cut:
    # A hold that reads a block before the cut and commits one past it: the
    # failed commit fails it, the read block is kept.
    var h: Hold
    failCommits.store(1)
    let st = c.hold(BlockBytes, 4 * BlockBytes, h)
    doAssert st == rsFailed, "across the cut: " & $st
    doAssert c.holds(BlockBytes, 2 * BlockBytes)
    doAssert c.region[BlockBytes] == bytes[BlockBytes]
    doAssert not c.holds(2 * BlockBytes, 4 * BlockBytes) # the block whose commit failed
    doAssert c.hold(BlockBytes, 4 * BlockBytes, h) == rsCut
    doAssert c.holds(BlockBytes, 4 * BlockBytes)
    h.drop()

  closeCache(c)

  freeTrackSlot(g)

  echo "tcommitfail: ok"

when isMainModule: main()
