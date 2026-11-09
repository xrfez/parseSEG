## Memory-mapped disk files (`std/memfiles`).
##
## A `MemFileSource` is a byte-stream `RecordSource` over a mapped file: it
## skips forward in O(1), so a header-only walk touches only the pages that
## hold headers, and `memory` gives zero-copy access to any byte for random
## trace reads. Offsets are 64-bit, so files larger than 4 GB (or than RAM)
## work: the OS pages the mapping in on demand.

import std/[memfiles, os]
when defined(posix): import std/posix
import records

const DefaultMapChunk* = 64 shl 10
  ## Largest chunk a read returns. Small chunks keep a header walk from
  ## copying (and paging in) the sample bytes it skips.

type
  MemFileSource* = ref object of RecordSource
    mf: MemFile
    mapped: bool
    size: int64
    chunk: int

proc openMemFileSource*(path: string; writable = false;
    chunk = DefaultMapChunk): MemFileSource =
  ## Maps `path` (read-only unless `writable`). Raises `IOError` or `OSError`
  ## if it cannot be opened or mapped. An empty file maps nothing and reads
  ## as end of data.
  result = MemFileSource(name: path, chunk: max(1, chunk))
  if getFileSize(path) > 0:
    result.mf = memfiles.open(path, mode = if writable: fmReadWrite else: fmRead)
    result.mapped = true
    result.size = int64(result.mf.size) # the mapped size, not an earlier stat

proc size*(s: MemFileSource): int64 {.inline.} =
  ## File size in bytes.
  s.size

proc memory*(s: MemFileSource): ptr UncheckedArray[byte] {.inline.} =
  ## The mapped bytes (nil for an empty file). Valid until `close`.
  if s.mapped: cast[ptr UncheckedArray[byte]](s.mf.mem) else: nil

when defined(posix):
  var MADV_WILLNEED {.importc, header: "<sys/mman.h>".}: cint
  proc c_madvise(adr: pointer, len: csize_t, advice: cint): cint {.
    importc: "madvise", header: "<sys/mman.h>".}
  proc c_mincore(adr: pointer, len: csize_t, vec: ptr uint8): cint {.
    importc: "mincore", header: "<sys/mman.h>".}
  let pageSize = max(4096, int(sysconf(SC_PAGESIZE))) # read-only after module init

proc adviseWillNeed*(mem: ptr UncheckedArray[byte], size, a, b: int64) {.raises: [].} =
  ## **Internal.** Hints that bytes `a ..< b` of the mapping `mem[0 ..< size]`
  ## will be read soon, so the OS queues their disk reads at once instead of
  ## one fault at a time. A hint only: failures are ignored, nothing is
  ## allocated, so worker threads may call it. A no-op off POSIX.
  when defined(posix):
    let lo = max(a, 0'i64) and not int64(pageSize - 1)
    let hi = min(b, size)
    if mem != nil and hi > lo:
      discard c_madvise(addr mem[lo], csize_t(hi - lo), MADV_WILLNEED)

proc isResident*(mem: ptr UncheckedArray[byte], size, offset: int64): bool {.raises: [].} =
  ## **Internal.** The page holding byte `offset` of the mapping is in memory
  ## (`mincore`), so reading it will not wait for the disk. True off POSIX
  ## and for an offset outside the map (nothing to advise).
  when defined(posix):
    if mem == nil or offset < 0 or offset >= size: return true
    var v: uint8
    let lo = offset and not int64(pageSize - 1)
    c_mincore(addr mem[lo], 1, addr v) != 0 or (v and 1) != 0
  else:
    true

proc flush*(s: MemFileSource) =
  ## Writes modified pages of a writable mapping back to the file.
  if s.mapped: s.mf.flush()

method readRecordImpl*(s: MemFileSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  let n = int(max(0'i64, min(int64(min(maxLen, s.chunk)), s.size - s.offset)))
  buf.setLenUninit n # overwritten by the copy
  if n > 0: copyMem(addr buf[0], addr s.memory[s.offset], n)
  s.dataOffset = s.offset
  s.offset += n
  if n > 0: rkData else: rkEndOfData

method hasRecordBoundaries*(s: MemFileSource): bool {.raises: [].} = false

method seekForward*(s: MemFileSource; n: int64): int64 {.raises: [CatchableError].} =
  result = max(0'i64, min(n, s.size - s.offset))
  s.offset += result

method close*(s: MemFileSource) {.raises: [CatchableError].} =
  if s.mapped:
    s.mf.close()
    s.mapped = false
  s.size = 0
