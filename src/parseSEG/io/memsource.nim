## Memory-mapped disk files (`std/memfiles`).
##
## A `MemFileSource` is a byte-stream `RecordSource` over a mapped file: it
## skips forward in O(1), so a header-only walk touches only the pages that
## hold headers, and `memory` gives zero-copy access to any byte for random
## trace reads. Offsets are 64-bit, so files larger than 4 GB (or than RAM)
## work: the OS pages the mapping in on demand.
##
## A file cut short by another program while it is mapped does not end the
## program (POSIX): a read of a page past its new end gets zeros instead of
## `SIGBUS`, and `readable` says where the bytes still in the file end.
## Record reads stop there. The file's descriptor stays open with the map for this.
## Built with `-d:parseSegNoMapGuard` there is no `SIGBUS` handler: such a read
## ends the program, as in parseSEG 0.11, and `cutShort` still finds a cut.

import std/[memfiles, os]
import records
import ../private/mapguard

const DefaultMapChunk* = 64 shl 10
  ## Largest chunk a read returns. Small chunks keep a header walk from
  ## copying (and paging in) the sample bytes it skips.

type
  MemFileSource* {.acyclic.} = ref object of RecordSource
    ## A mapped disk file. It holds no reference that could lead back to it,
    ## and says so (`acyclic`): ORC never lists it as a possible cycle root,
    ## so one opened on one thread may be released on another.
    mf: MemFile
    mapped: bool
    size: int64
    chunk: int
    guard: MapGuard # nil for an empty file and where maps are not guarded

proc openMemFileSource*(path: string; writable = false;
    chunk = DefaultMapChunk): MemFileSource =
  ## Maps `path` (read-only unless `writable`). Raises `IOError` or `OSError`
  ## if it cannot be opened or mapped. An empty file maps nothing and reads
  ## as end of data.
  result = MemFileSource(name: path, chunk: max(1, chunk))
  if getFileSize(path) > 0:
    # `allowRemap` keeps the descriptor open: the guard asks it for the
    # file's size when a read meets a cut.
    result.mf = memfiles.open(path, mode = if writable: fmReadWrite else: fmRead,
      allowRemap = mapsTracked)
    result.mapped = true
    result.size = int64(result.mf.size) # the mapped size, not an earlier stat
    when mapsTracked:
      try:
        result.guard = guardMap(result.mf.mem, result.mf.size, result.mf.handle, writable)
      except OSError:
        result.mf.close()
        result.mapped = false
        raise

proc size*(s: MemFileSource): int64 {.inline.} =
  ## File size in bytes, as mapped.
  s.size

proc readable*(s: MemFileSource): int64 {.inline, raises: [].} =
  ## The bytes that can be read: `size`, or less once the file was found cut
  ## short while mapped (a read reached a page past its new end, or
  ## `cutShort` asked). The bytes from there on read as zeros.
  min(s.size, s.guard.guardCut)

proc cutShort*(s: MemFileSource): bool {.raises: [].} =
  ## The file was found shorter than it was mapped: by an earlier read, or
  ## now: this asks the OS for its size (`fstat`, about 0.5 µs) and, when it
  ## is less than the map, records the cut as a read past it would (`readable`).
  ## False for an empty or closed source, and on Windows (where a mapped file
  ## cannot be cut).
  if s.mapped:
    let n = s.guard.guardedFileSize
    if n >= 0 and n < s.size: s.guard.lowerGuardCut(n)
  s.readable < s.size

proc readFailed*(s: MemFileSource): bool {.inline, raises: [].} =
  ## The bytes from `readable` on are gone because a read of them failed
  ## (an I/O error: a network share that went away, a disk error), not
  ## because the file is shorter: its size was unchanged when the read
  ## faulted. Like a cut, it lasts as long as the map: open the file again.
  s.guard.guardReadFailed

proc mapGuard*(s: MemFileSource): MapGuard {.inline.} =
  ## **Internal** (not exported by `parseSEG`). The map's registration, for
  ## readers that check what they read against its cut from raw pointers
  ## (`private/decodeentry`).
  s.guard

proc memory*(s: MemFileSource): ptr UncheckedArray[byte] {.inline.} =
  ## The mapped bytes (nil for an empty file). Valid until `close`. Bytes
  ## from `readable` on read as zeros.
  if s.mapped: cast[ptr UncheckedArray[byte]](s.mf.mem) else: nil

proc flush*(s: MemFileSource) =
  ## Writes modified pages of a writable mapping back to the file.
  if s.mapped: s.mf.flush()

method readRecordImpl*(s: MemFileSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  var n = int(max(0'i64, min(int64(min(maxLen, s.chunk)), s.readable - s.offset)))
  buf.setLenUninit n # overwritten by the copy
  if n > 0:
    copyMem(addr buf[0], addr s.memory[s.offset], n)
    # A cut met by the copy: what lies past it were zeros, not the file.
    let left = s.readable - s.offset
    if n > left:
      n = int(max(0'i64, left))
      buf.setLen n
  s.dataOffset = s.offset
  s.offset += n
  if n > 0: rkData else: rkEndOfData

method hasRecordBoundaries*(s: MemFileSource): bool {.raises: [].} = false

method seekForward*(s: MemFileSource; n: int64): int64 {.raises: [CatchableError].} =
  result = max(0'i64, min(n, s.readable - s.offset))
  s.offset += result

method close*(s: MemFileSource) {.raises: [CatchableError].} =
  if s.mapped:
    unguard(s.guard) # before the unmap: a fault in it now is no longer ours
    s.guard = nil
    s.mf.close()
    s.mapped = false
  s.size = 0
