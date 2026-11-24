## Plain disk files as record sources and sinks.
##
## A disk file is a byte stream with no physical records: reads return chunks
## of up to `maxLen` bytes, and tape marks written to a disk sink are counted
## but not stored (SEG disk files have none). For tape layouts on disk, use
## `tapeimage`.

when defined(posix):
  import std/posix
import records
import ../common/outputfile
import ../private/sharedfile

type
  DiskSource* {.acyclic.} = ref object of RecordSource
    ## Reads a disk file as a byte stream, in chunks; seeks to skip. Acyclic
    ## (it refers to nothing that could lead back to it): it may be released
    ## on another thread than the one that opened it.
    f: File
    size: int64

  DiskSink* {.acyclic.} = ref object of RecordSink
    ## Writes records back to back into a disk file; tape marks are dropped.
    ## Acyclic, as `DiskSource`.
    ## Records are collected in a buffer of `SinkBufferSize` bytes and written
    ## when it is full and on `close`, so the file is complete only then.
    f: File
    buf: seq[byte] ## Records not yet written (allocated by the first one).
    used: int      ## Bytes of `buf` in use.
    failed: bool   ## A write failed: bytes are missing, so every later call raises.

const SinkBufferSize* = 1 shl 20
  ## Bytes a `DiskSink` collects before it writes them. One write per record
  ## cost two system calls per trace (stdio's own buffer is 4 KiB): 0.96 s
  ## of system time per GB of 8 kB traces, against 0.13 s in 1 MiB writes.

proc openDiskSource*(path: string): DiskSource =
  ## Opens `path` for reading. Raises `IOError` if it cannot be opened.
  var f: File
  if not openShared(f, path, fmRead):
    raise newException(IOError, "cannot open for reading: " & path)
  var size = -1'i64 # unknown (a pipe or device): skips read and discard
  try:
    # Only a regular file's size is meaningful: a character device reports 0.
    when defined(posix):
      var st: Stat
      if fstat(getFileHandle(f), st) == 0 and S_ISREG(st.st_mode): size = getFileSize(f)
    else:
      size = getFileSize(f)
  except IOError:
    discard
  DiskSource(f: f, name: path, size: size)

func size*(s: DiskSource): int64 {.inline.} =
  ## The file's size when opened; -1 for a pipe or device.
  s.size

proc refreshSize(s: DiskSource) =
  # The size is cached at open; a file still being written may have grown.
  try:
    s.size = getFileSize(s.f)
  except IOError:
    discard

method readRecordImpl*(s: DiskSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  # Never size the buffer beyond the bytes left: a 4 KB file must not cost a
  # zeroed 1 MB buffer per open.
  if s.size >= 0 and s.offset >= s.size: s.refreshSize()
  let want =
    if s.size >= 0: int(max(0'i64, min(int64(maxLen), s.size - s.offset)))
    else: maxLen
  buf.setLenUninit want # filled by the read (zeroing it cost more than the copy)
  let n = if want > 0: readBuffer(s.f, addr buf[0], want) else: 0
  buf.setLen n
  s.dataOffset = s.offset
  s.offset += n
  if n > 0: rkData else: rkEndOfData

method hasRecordBoundaries*(s: DiskSource): bool {.raises: [].} = false

method seekForward*(s: DiskSource; n: int64): int64 {.raises: [CatchableError].} =
  if s.size < 0: return -1
  if n > s.size - s.offset: s.refreshSize()
  result = max(0'i64, min(n, s.size - s.offset))
  setFilePos(s.f, s.offset + result)
  s.offset += result

method close*(s: DiskSource) {.raises: [CatchableError].} =
  if s.f != nil:
    close(s.f)
    s.f = nil

proc openDiskSink*(path: string): DiskSink =
  ## Creates (or truncates) `path` for writing. Raises `IOError` on failure.
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "cannot open for writing: " & path)
  DiskSink(f: f, name: path)

proc put(s: DiskSink, p: pointer, n: int) {.raises: [IOError].} =
  # Writes `n` bytes to the file; a failure marks the sink for good.
  var written = 0
  try:
    written = writeBuffer(s.f, p, n)
  except IOError as e:
    s.failed = true
    raise newException(IOError, "write failed: " & s.name & ": " & e.msg)
  if written != n:
    s.failed = true
    raise newException(IOError, "write failed: " & s.name)

proc flushBuffer(s: DiskSink) {.raises: [IOError].} =
  if s.used > 0:
    let n = s.used
    s.used = 0
    s.put(addr s.buf[0], n)

method writeRecordImpl*(s: DiskSink; data: openArray[byte]) {.raises: [CatchableError].} =
  if s.failed:
    raise newException(IOError, "an earlier write failed: " & s.name & " is incomplete")
  if data.len > 0:
    if s.used + data.len > SinkBufferSize: s.flushBuffer()
    if data.len >= SinkBufferSize:
      s.put(addr data[0], data.len) # as large as the buffer: no copy
    else:
      if s.buf.len == 0: s.buf = newSeqUninit[byte](SinkBufferSize)
      copyMem(addr s.buf[s.used], addr data[0], data.len)
      s.used += data.len
  s.offset += data.len

method writeTapeMarkImpl*(s: DiskSink) {.raises: [CatchableError].} =
  discard "disk files store no tape marks"

proc c_fflush(f: File): cint {.importc: "fflush", header: "<stdio.h>".}
proc c_strerror(code: cint): cstring {.importc: "strerror", header: "<string.h>".}
var cErrno {.importc: "errno", header: "<errno.h>".}: cint

proc flushChecked(f: File, name: string) {.raises: [IOError].} =
  # `flushFile` discards fflush's result (`syncio`); a patch that fits the
  # stdio buffer would otherwise return, and `close` would too.
  if c_fflush(f) != 0:
    let code = cErrno
    raise newException(IOError, "cannot patch " & name & ": " & $c_strerror(code))

proc patch*(s: DiskSink, at: int, data: openArray[byte]) =
  ## Overwrites bytes at `at` already accepted by `writeRecord` (the
  ## back-patching of counts known at the end, as `MemSink.patch`). Bytes still
  ## in the buffer are patched there; bytes already flushed are patched in the
  ## file, and the file position returns to the end of what was flushed.
  ## Raises `IndexDefect` when the range is outside what was written, and
  ## `IOError` when the file cannot be patched.
  if s.failed:
    raise newException(IOError, "an earlier write failed: " & s.name & " is incomplete")
  if at < 0 or data.len > int(s.offset) - at:
    raise newException(IndexDefect, "patch outside the bytes written")
  if data.len == 0: return
  let flushed = s.offset - int64(s.used)
  if int64(at) < flushed:
    let nFile = min(data.len, int(flushed - at))
    flushFile(s.f)
    let pos = getFilePos(s.f)
    var pending: ref IOError = nil
    try:
      setFilePos(s.f, int64(at))
      try:
        if writeBytes(s.f, data, 0, nFile) != nFile:
          raise newException(IOError, "cannot patch " & s.name)
        flushChecked(s.f, s.name)
      except IOError as e:
        s.failed = true
        pending = e
    except IOError as e:
      pending = e
    finally:
      try:
        setFilePos(s.f, pos)
      except IOError as e:
        if pending.isNil:
          s.failed = true
          pending = e
    if not pending.isNil: raise pending
  if int64(at) + data.len > flushed:
    let dataAt = int(max(int64(at), flushed) - at)
    let bufAt = int(max(int64(at), flushed) - flushed)
    let n = data.len - dataAt
    if n > 0: copyMem(addr s.buf[bufAt], addr data[dataAt], n)

method close*(s: DiskSink) {.raises: [CatchableError].} =
  ## Writes the buffered records and closes the file. Raises `IOError` when
  ## bytes did not reach it, now or in an earlier write (the file is closed
  ## all the same).
  if s.f != nil:
    let f = s.f
    try:
      if not s.failed: s.flushBuffer()
    except IOError:
      discard # reported below: the sink is marked
    s.f = nil
    s.buf = @[]
    if s.failed:
      close(f)
      raise newException(IOError, "write failed: " & s.name & " is incomplete")
    closeChecked(f, s.name)
