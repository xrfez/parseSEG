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

type
  DiskSource* = ref object of RecordSource
    ## Reads a disk file as a byte stream, in chunks; seeks to skip.
    f: File
    size: int64

  DiskSink* = ref object of RecordSink
    ## Writes records back to back into a disk file; tape marks are dropped.
    f: File

proc openDiskSource*(path: string): DiskSource =
  ## Opens `path` for reading. Raises `IOError` if it cannot be opened.
  var f: File
  if not open(f, path, fmRead):
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

method writeRecordImpl*(s: DiskSink; data: openArray[byte]) {.raises: [CatchableError].} =
  if data.len > 0 and writeBuffer(s.f, addr data[0], data.len) != data.len:
    raise newException(IOError, "write failed: " & s.name)
  s.offset += data.len

method writeTapeMarkImpl*(s: DiskSink) {.raises: [CatchableError].} =
  discard "disk files store no tape marks"

method close*(s: DiskSink) {.raises: [CatchableError].} =
  ## Flushes and closes the file. Raises `IOError` when the last bytes did
  ## not reach it (the file is closed all the same).
  if s.f != nil:
    let f = s.f
    s.f = nil
    closeChecked(f, s.name)
