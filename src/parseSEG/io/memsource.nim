## Files whose bytes are reached in memory: a disk file mapped
## (`private/filemap`), or unmapped, read into parseSEG's own cache
## (`private/readcache`); or no file at all, bytes the caller handed over
## (`openMemorySource`).
##
## A `MemFileSource` is a byte-stream `RecordSource` over such a file: it
## skips forward in O(1), so a header-only walk touches only the pages that
## hold headers, and `memory` gives zero-copy access to any byte for random
## trace reads. Offsets are 64-bit, so files larger than 4 GB (or than RAM)
## work: the OS pages the mapping in on demand.
##
## How the bytes are reached is a `FileAccess`. Mapped, a read is a page
## fault the OS answers. A file cut short by another program while it is
## mapped does not end the program (POSIX): a read of a page past its new end
## gets zeros instead of `SIGBUS`, and `readable` says where the bytes still
## in the file end. Record reads stop there. The file's descriptor stays open
## with the map for this. Built with `-d:parseSegNoMapGuard` there is no
## `SIGBUS` handler: such a read ends the program, as in parseSEG 0.11, and
## `cutShort` still finds a cut. Unmapped, nothing is mapped from the file:
## its bytes are read with `pread` (Windows: `ReadFile` at an offset) into a
## region laid out like the file, in few, large requests, and a read that
## fails (a network share gone) or meets a cut is a failed read like any
## other, with no signal involved; a later read tries again.
##
## On Windows both ways open the file shared with every other program (read,
## write and delete): a recorder may keep writing to it, and it may be
## renamed or appended to while it is open. A map's reads cover the size at
## open (`size`); what is appended later is not read. See the viewer guide
## for what the OS still refuses another program while a map exists.
##
## A source made from bytes (`openMemorySource`) owns them and reads them in place:
## nothing is copied, mapped or registered with the cut guard (the bytes
## cannot be cut), and no file system access happens. It reads like a
## mapped file, from any number of threads.

import std/os
import records
import ../private/[filemap, mapguard, netfs, readcache]

const DefaultMapChunk* = 64 shl 10
  ## Largest chunk a read returns. Small chunks keep a header walk from
  ## copying (and paging in) the sample bytes it skips.

type
  FileAccess* = enum
    ## How a file's bytes are reached (`OpenOptions.access`,
    ## `openMemFileSource`).
    faAuto
      ## Unmapped where the file lies on a network file system (NFS,
      ## SMB/CIFS, AFS, 9P, FUSE and the like on Linux; not `MNT_LOCAL` on
      ## macOS; a remote drive or UNC path on Windows), mapped elsewhere.
      ## When the OS cannot tell: mapped on Linux and macOS (the guard takes
      ## a failed read), unmapped on Windows, which maps only files on a
      ## fixed drive or a RAM disk that are no cloud placeholders (a failed
      ## read of a map there ends the program).
    faMapped
      ## Memory-mapped: the OS pages the file in on demand, and reads are
      ## as fast as memory once it is cached. A read the OS cannot do (a
      ## share gone) faults; the guard turns that into failed reads for as
      ## long as the file stays open (`readFailed`), and a read that waits on
      ## a hung share waits inside the fault.
    faUnmapped
      ## Read with `pread` into parseSEG's own cache (64 MiB a file, in
      ## 64 KiB blocks; reads ahead up to 16 MiB while reads go forward, and a
      ## read of many traces is one request per 8 MiB of them). No map, no
      ## fault, no signal handler: a failed read fails that call (sample rows
      ## `dcIo`, header calls `IOError`) and the next call reads again. Costs
      ## a copy of every byte read and a system call per request: on a local
      ## disk slower than a map (see the guide), on a share a small part of
      ## what the round trips and the link cost.

  MemFileSource* {.acyclic.} = ref object of RecordSource
    ## A disk file, mapped or unmapped. It holds no reference that could
    ## lead back to it, and says so (`acyclic`): ORC never lists it as a
    ## possible cycle root, so one opened on one thread may be released on
    ## another.
    mf: FileMap       # in memory: `mem` and `size` of `owned`, nothing else
    owned: seq[byte]  # in memory: the bytes (`mf.mem` points into it; never resized)
    mapped: bool      # bytes can be read (mapped or unmapped); false once closed or empty
    size: int64
    chunk: int
    guard: MapGuard   # the cut: the map's registration, or a slot of its own unmapped
    cache: ptr ReadCache # unmapped: the descriptor, the region, the blocks; nil when mapped
    walk: Cursor      # unmapped: what the record reads hold
    walkError: string # unmapped: why a record read failed ("" if none did)
    access: FileAccess # in memory: `faMapped` (the bytes are reached in place)
    inMemory: bool    # the bytes are `owned`, not a file

const DefaultAccess* = when defined(parseSegUnmapped): faUnmapped else: faAuto
  ## The access of an open that names none: `faAuto`, or `faUnmapped` in a
  ## build with `-d:parseSegUnmapped` (every file unmapped unless an open
  ## says otherwise; `nim testUnmapped` runs the suite so).

proc resolveAccess*(path: string, access: FileAccess): FileAccess =
  ## `access`, with `faAuto` resolved for `path`: `faUnmapped` on a network
  ## file system, `faMapped` elsewhere; when the OS cannot tell, `faMapped`
  ## on Linux and macOS and `faUnmapped` on Windows (one `statfs`; on
  ## Windows `GetVolumePathNameW`, `GetDriveTypeW`, `QueryDosDeviceW` and
  ## `GetFileAttributesW`).
  if access != faAuto: access
  elif unmappedByDefault(onNetworkFileSystem(path)): faUnmapped
  else: faMapped

proc openMemFileSource*(path: string; writable = false; chunk = DefaultMapChunk;
    access = DefaultAccess): MemFileSource =
  ## Opens `path` (read-only unless `writable`), mapped or unmapped as
  ## `access` says (see `FileAccess`; `faAuto` asks the OS once where the
  ## file lies). Raises `IOError` or `OSError` if it cannot be opened, mapped,
  ## or its region reserved. An empty file maps nothing and reads as end of
  ## data.
  let how = resolveAccess(path, access)
  result = MemFileSource(name: path, chunk: max(1, chunk), access: how)
  if how == faUnmapped:
    let g = newTrackSlot()
    try:
      result.cache = openReadCache(path, writable, g)
    except CatchableError:
      freeTrackSlot(g)
      raise
    result.guard = g
    result.size = result.cache.openedSize
    result.mapped = true
  else:
    # An empty file maps nothing. Not Windows: `getFileSize(path)` follows a
    # link. Windows: sized from the opened handle, which follows it too
    # (`getFileSize(path)` there is the link's own size, 0).
    when not defined(windows):
      if getFileSize(path) <= 0: return
    # `allowRemap` keeps the descriptor open: the guard asks it for the
    # file's size when a read meets a cut.
    result.mf = when defined(windows): openFileMap(path, writable)
      else: openFileMap(path, writable, allowRemap = mapsTracked)
    if result.mf.size > 0:
      result.mapped = true
      result.size = int64(result.mf.size) # the mapped size, not an earlier stat
      when mapsTracked:
        try:
          result.guard = guardMap(result.mf.mem, result.mf.size, result.mf.handle, writable)
        except OSError:
          result.mf.close()
          result.mapped = false
          raise

proc openMemorySource*(bytes: sink seq[byte]; name: string;
    chunk = DefaultMapChunk): MemFileSource =
  ## A source over `bytes`, which it takes over: moved in when this call is the
  ## argument's last use (or it is passed with `move`; the caller's `seq` is then
  ## empty), copied otherwise, as Nim does for any `sink` parameter. `name` is a display name for
  ## messages; no file system access happens for it. Empty `bytes` read as
  ## end of data. The bytes are never changed, and may be read from any
  ## number of threads until `close`.
  result = MemFileSource(name: name, chunk: max(1, chunk), access: faMapped,
    inMemory: true, owned: move bytes)
  if result.owned.len > 0:
    result.mf.mem = addr result.owned[0]
    result.mf.size = result.owned.len
    when not defined(windows): result.mf.handle = -1
    result.mapped = true
    result.size = int64(result.owned.len)

func isMemory*(s: MemFileSource): bool {.inline.} =
  ## The bytes were handed over (`openMemorySource`), not read from a file.
  s.inMemory

proc access*(s: MemFileSource): FileAccess {.inline.} =
  ## How the file's bytes are reached: `faMapped` or `faUnmapped` (an open
  ## with `faAuto` resolved it); `faMapped` for bytes in memory (`isMemory`),
  ## which are reached in place.
  s.access

proc size*(s: MemFileSource): int64 {.inline.} =
  ## File size in bytes, as mapped.
  s.size

proc readable*(s: MemFileSource): int64 {.inline, raises: [].} =
  ## The bytes that can be read: `size`, or less once the file was found cut
  ## short while mapped (a read reached a page past its new end, or
  ## `cutShort` asked). The bytes from there on read as zeros.
  min(s.size, s.guard.guardCut)

proc cutShort*(s: MemFileSource): bool {.raises: [].} =
  ## The file was found shorter than it was opened: by an earlier read, or
  ## now: this asks the OS for its size (`fstat`, about 0.5 µs) and, when it
  ## is less than the size opened, records the cut as a read past it would
  ## (`readable`). False for an empty or closed source, and for a mapped one
  ## on Windows (where a mapped file cannot be cut).
  if s.mapped:
    let n = if s.cache != nil: s.cache.fileSize else: s.guard.guardedFileSize
    if n >= 0 and n < s.size: s.guard.lowerGuardCut(n)
  s.readable < s.size

proc readFailed*(s: MemFileSource): bool {.inline, raises: [].} =
  ## Mapped: the bytes from `readable` on are gone because a read of them
  ## failed (an I/O error: a network share that went away, a disk error),
  ## not because the file is shorter: its size was unchanged when the read
  ## faulted. Like a cut, it lasts as long as the map: open the file again.
  ## Unmapped always false: a failed read fails only its own call.
  s.guard.guardReadFailed

proc mapGuard*(s: MemFileSource): MapGuard {.inline.} =
  ## **Internal** (not exported by `parseSEG`). The map's registration, for
  ## readers that check what they read against its cut from raw pointers
  ## (`private/decodeentry`).
  s.guard

proc readCache*(s: MemFileSource): ptr ReadCache {.inline.} =
  ## **Internal** (not exported by `parseSEG`). An unmapped file's cache
  ## (nil when mapped or closed): readers hold what they read in it.
  s.cache

proc memory*(s: MemFileSource): ptr UncheckedArray[byte] {.inline.} =
  ## The file's bytes, byte `i` at `memory[i]` (nil for an empty file).
  ## Valid until `close`. Bytes from `readable` on read as zeros. Unmapped,
  ## only bytes held in `readCache` (`private/readcache.hold`) are the file's.
  if s.cache != nil: s.cache.region
  elif s.mapped: cast[ptr UncheckedArray[byte]](s.mf.mem)
  else: nil

proc flush*(s: MemFileSource) =
  ## Writes modified pages of a writable mapping back to the file (unmapped:
  ## the written bytes to the device, `fsync`; raises `IOError` when it
  ## fails).
  if s.inMemory: return
  if s.cache != nil:
    if not s.cache.sync():
      raise newException(IOError, "cannot write " & s.name & " to its device: " &
        osErrorMsg(osLastError()))
  elif s.mapped: s.mf.flush()

proc readFailure(s: MemFileSource, at: int64): ref IOError =
  result = newException(IOError, s.name & " could not be read at byte " & $at & " (" &
    s.cache.errorText & "); try again")
  s.walkError = result.msg

proc walkError*(s: MemFileSource): lent string {.inline.} =
  ## **Internal.** Unmapped: why a record read failed (an I/O error), the
  ## last one; "" when none did. A walk's reader logs such a failure as a
  ## fatal diagnostic; `openSeismic` raises it instead.
  s.walkError

method readRecordImpl*(s: MemFileSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  var n = int(max(0'i64, min(int64(min(maxLen, s.chunk)), s.readable - s.offset)))
  buf.setLenUninit n # overwritten by the copy
  if n > 0:
    if s.cache != nil and s.cache.cover(s.walk, s.offset, s.offset + n) == rsFailed and
        not s.cache.holds(s.offset, s.offset + n):
      raise s.readFailure(s.offset)
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

proc endWalk*(s: MemFileSource) {.raises: [].} =
  ## **Internal.** Releases what the record reads hold (after an index walk).
  s.walk.drop()

method close*(s: MemFileSource) {.raises: [CatchableError].} =
  if s.cache != nil:
    s.walk.drop()
    closeCache(s.cache)
    s.cache = nil
    freeTrackSlot(s.guard)
    s.guard = nil
    s.mapped = false
  elif s.inMemory:
    s.mf = FileMap()
    s.owned = @[]
    s.mapped = false
  elif s.mapped:
    # Before the unmap: a fault in it now is no longer ours. A handler that
    # does not leave the slot keeps the map, and its descriptor, mapped for
    # good (it would map zero pages over whatever came there next).
    if unguard(s.guard): s.mf.close()
    s.guard = nil
    s.mapped = false
  s.size = 0
