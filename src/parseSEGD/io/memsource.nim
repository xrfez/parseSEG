## Memory-mapped disk files (`std/memfiles`).
##
## A `MemFileSource` is a byte-stream `RecordSource` over a mapped file: it
## skips forward in O(1), so a header-only walk touches only the pages that
## hold headers, and `memory` gives zero-copy access to any byte for random
## trace reads. Offsets are 64-bit, so files larger than 4 GB (or than RAM)
## work: the OS pages the mapping in on demand.

import std/[memfiles, os]
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

proc flush*(s: MemFileSource) =
  ## Writes modified pages of a writable mapping back to the file.
  if s.mapped: s.mf.flush()

method readRecordImpl*(s: MemFileSource; buf: var seq[byte]; maxLen: int): RecordKind =
  let n = int(max(0'i64, min(int64(min(maxLen, s.chunk)), s.size - s.offset)))
  buf.setLen n
  if n > 0: copyMem(addr buf[0], addr s.memory[s.offset], n)
  s.dataOffset = s.offset
  s.offset += n
  if n > 0: rkData else: rkEndOfData

method hasRecordBoundaries*(s: MemFileSource): bool = false

method seekForward*(s: MemFileSource; n: int64): int64 =
  result = max(0'i64, min(n, s.size - s.offset))
  s.offset += result

method close*(s: MemFileSource) =
  if s.mapped:
    s.mf.close()
    s.mapped = false
  s.size = 0
