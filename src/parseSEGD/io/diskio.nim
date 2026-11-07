## Plain disk files as record sources and sinks.
##
## A disk file is a byte stream with no physical records: reads return chunks
## of up to `maxLen` bytes, and tape marks written to a disk sink are counted
## but not stored (SEG disk files have none). For tape layouts on disk, use
## `tapeimage`.

import records

type
  DiskSource* = ref object of RecordSource
    f: File

  DiskSink* = ref object of RecordSink
    f: File

proc openDiskSource*(path: string): DiskSource =
  ## Opens `path` for reading. Raises `IOError` if it cannot be opened.
  var f: File
  if not open(f, path, fmRead):
    raise newException(IOError, "cannot open for reading: " & path)
  DiskSource(f: f, name: path)

method readRecordImpl*(s: DiskSource; buf: var seq[byte]; maxLen: int): RecordKind =
  buf.setLen maxLen
  let n = if maxLen > 0: readBuffer(s.f, addr buf[0], maxLen) else: 0
  buf.setLen n
  s.dataOffset = s.offset
  s.offset += n
  if n > 0: rkData else: rkEndOfData

method hasRecordBoundaries*(s: DiskSource): bool = false

method close*(s: DiskSource) =
  if s.f != nil:
    close(s.f)
    s.f = nil

proc openDiskSink*(path: string): DiskSink =
  ## Creates (or truncates) `path` for writing. Raises `IOError` on failure.
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "cannot open for writing: " & path)
  DiskSink(f: f, name: path)

method writeRecordImpl*(s: DiskSink; data: openArray[byte]) =
  if data.len > 0 and writeBuffer(s.f, unsafeAddr data[0], data.len) != data.len:
    raise newException(IOError, "write failed: " & s.name)
  s.offset += data.len

method writeTapeMarkImpl*(s: DiskSink) =
  discard "disk files store no tape marks"

method close*(s: DiskSink) =
  if s.f != nil:
    close(s.f)
    s.f = nil
