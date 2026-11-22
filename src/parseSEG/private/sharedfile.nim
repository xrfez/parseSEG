## Files opened and moved so that other programs may use them meanwhile.
##
## Not Windows: the plain `std/syncio` and `std/os` calls (POSIX lets other
## programs write, rename and delete a file that is open).
##
## Windows: `fopen`, which `std/syncio.open` calls, opens a file with
## `FILE_SHARE_READ or FILE_SHARE_WRITE` but not `FILE_SHARE_DELETE`, so
## while a file is open here no other program can rename or delete it.
## `openShared` opens it with `CreateFileW` and all three, then wraps the
## handle in a `File`. A link is followed. And `os.moveFile` fails with
## access denied, a sharing violation or a lock violation (errors 5, 32,
## 33) while another program (a reader of the file, a virus scanner, the
## search indexer) has the target open: `moveFileShared` tries again for
## about a fifth of a second before it gives up.

import std/[os, streams, syncio]
when defined(windows):
  import std/[oserrors, winlean, widestrs]

when defined(windows):
  proc openOsfhandle(h: Handle, flags: cint): cint {.importc: "_open_osfhandle",
    header: "<io.h>".}
  proc closeFd(fd: cint): cint {.importc: "_close", header: "<io.h>".}
  proc setvbuf(f: File, buf: pointer, mode: cint, size: csize_t): cint {.importc: "setvbuf",
    header: "<stdio.h>".}

  const
    OAppend = 0x0008.cint
    OBinary = 0x8000.cint
    IoFullBuffer = 0.cint
    IoNoBuffer = 4.cint # _IONBF

  proc openShared*(f: var File, path: string, mode: FileMode = fmRead,
      bufSize: int = -1): bool {.raises: [], tags: [].} =
    ## `open`, with every other program allowed to read, write, rename and
    ## delete the file meanwhile. For `fmRead`, `fmReadWriteExisting` and
    ## `fmAppend`; the other modes make or empty a file and open as `open`
    ## does. False when it cannot be opened (a directory too).
    if mode notin {fmRead, fmReadWriteExisting, fmAppend}:
      return open(f, path, mode, bufSize)
    let access = case mode
      of fmRead: GENERIC_READ
      of fmReadWriteExisting: GENERIC_READ or GENERIC_WRITE
      else: GENERIC_WRITE
    let h = createFileW(newWideCString(path), access,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      if mode == fmAppend: OPEN_ALWAYS else: OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)
    if h == INVALID_HANDLE_VALUE: return false
    let fd = openOsfhandle(h, OBinary or (if mode == fmAppend: OAppend else: 0.cint))
    if fd < 0:
      discard closeHandle(h)
      return false
    # `open` by descriptor: the handle becomes the `File`'s and is closed
    # with it; if that fails it is ours still.
    if not open(f, FileHandle(fd), mode):
      discard closeFd(fd) # closes the handle too
      return false
    if bufSize > 0: discard setvbuf(f, nil, IoFullBuffer, csize_t(bufSize))
    elif bufSize == 0: discard setvbuf(f, nil, IoNoBuffer, 0)
    true

  const RetryErrors = [5'i32, 32, 33]

  proc moveFileShared*(source, dest: string, attempts = 10, pauseMs = 20) {.
      raises: [OSError, IOError].} =
    ## `os.moveFile`, tried again (`attempts` times in all, `pauseMs` apart:
    ## about a fifth of a second) when Windows says access denied, sharing
    ## violation or lock violation: another program has `dest` open for a
    ## moment.
    var attempt = 0
    while true:
      try:
        os.moveFile(source, dest)
        return
      except OSError as e:
        inc attempt
        if attempt >= attempts or e.errorCode notin RetryErrors: raise
        sleep pauseMs

else:
  proc openShared*(f: var File, path: string, mode: FileMode = fmRead,
      bufSize: int = -1): bool {.raises: [], tags: [].} =
    ## `open`: nothing to share on this platform (see the module's text).
    open(f, path, mode, bufSize)

  proc moveFileShared*(source, dest: string, attempts = 10, pauseMs = 20) {.
      raises: [OSError, IOError].} =
    ## `os.moveFile` (nothing to retry on this platform).
    os.moveFile(source, dest)

proc readFileShared*(path: string): string {.raises: [IOError].} =
  ## `readFile`, with the file opened by `openShared`.
  var f: File
  if not openShared(f, path):
    raise newException(IOError, "cannot open: " & path)
  try:
    result = f.readAll()
  finally:
    close(f)

proc newFileStreamShared*(path: string, mode: FileMode = fmRead): FileStream {.
    raises: [].} =
  ## `newFileStream`, with the file opened by `openShared`; nil when it
  ## cannot be opened.
  var f: File
  if openShared(f, path, mode): newFileStream(f) else: nil

proc openFileShared*(path: string, mode: FileMode = fmRead, bufSize: int = -1): File {.
    raises: [IOError].} =
  ## `open(path, mode)` (which raises `IOError`), with the file opened by
  ## `openShared`.
  result = default(File)
  if not openShared(result, path, mode, bufSize):
    raise newException(IOError, "cannot open: " & path)

proc fileSizeShared*(path: string): int64 {.raises: [OSError].} =
  ## The size of the file `path` names, a link followed: `os.getFileSize`
  ## elsewhere, and on Windows the size of the target (where
  ## `os.getFileSize` answers a link's own size, 0). Raises `OSError`.
  when defined(windows):
    result = getFileInfo(path, followSymlink = true).size
  else:
    result = getFileSize(path)

proc copyFileShared*(source, dest: string) {.raises: [OSError, IOError].} =
  ## `os.copyFile`. On Windows `CopyFileW` does not say how it shares the
  ## source, so the copy is made here, in chunks, from a file opened by
  ## `openShared` (other programs may write to, rename and delete it
  ## meanwhile), and the copy gets the source's modification time, as
  ## `CopyFileW` gives it. A partial copy is removed when the copy fails.
  when defined(windows):
    var i, o: File
    if not openShared(i, source, fmRead):
      raise newException(IOError, "cannot open for reading: " & source)
    try:
      if not open(o, dest, fmWrite):
        raise newException(IOError, "cannot write " & dest)
      var done = false
      try:
        var buf = newSeq[byte](1 shl 20)
        while true:
          let n = readBuffer(i, addr buf[0], buf.len)
          if n > 0 and writeBuffer(o, addr buf[0], n) != n:
            raise newException(IOError, "write failed: " & dest)
          if n < buf.len: break
        flushFile(o)
        done = true
      finally:
        close(o)
        if not done: discard tryRemoveFile(dest)
    finally:
      close(i)
    setLastModificationTime(dest, getLastModificationTime(source))
  else:
    os.copyFile(source, dest)
