## Output files written through a temporary file: the data goes to a new
## file next to the output, `<path>.<random>.tmp`, which is renamed to
## `path` only when the write is complete, so a failed write leaves an
## existing `path` untouched and no partial file behind. Used by the
## file-level writers and converters; not re-exported.
##
## The temporary name is unique and the file is created exclusively, so
## concurrent writers of one output never share it, a file or symlink
## planted under that name is never opened or followed, and the temporary
## file can never be the input (13.3 R4-4).

import std/os
import ./[diagcodes, diagnostics]

when defined(posix):
  import std/[posix, random, times]

  var nameRand {.threadvar.}: Rand
  var nameRandReady {.threadvar.}: bool
else:
  import std/tempfiles

proc c_fflush(f: File): cint {.importc: "fflush", header: "<stdio.h>".}
proc c_fclose(f: File): cint {.importc: "fclose", header: "<stdio.h>".}
proc c_strerror(code: cint): cstring {.importc: "strerror", header: "<string.h>".}
var cErrno {.importc: "errno", header: "<errno.h>".}: cint

proc closeChecked*(f: File, name: string) {.raises: [IOError].} =
  ## Flushes and closes the output file `f` (named `name` in the message),
  ## which is closed either way; raises `IOError` when its buffered bytes
  ## did not all reach the file (a full disk shows only here when the last
  ## writes fit the buffer). Nim's `close` discards that result.
  let flushed = c_fflush(f) == 0
  let flushError = cErrno
  let closed = c_fclose(f) == 0
  if not (flushed and closed):
    let code = if flushed: cErrno else: flushError
    raise newException(IOError, "write failed (close): " & name & ": " & $c_strerror(code))

proc createTempFor*(path: string): string {.raises: [IOError].} =
  ## Creates a new, empty file next to `path`, named `<path>.<random>.tmp`,
  ## and returns its name. Never opens an existing file: a name that exists
  ## (a file, or a symlink, which is not followed) is passed over for
  ## another. Raises `IOError` if no file can be created there.
  when defined(posix):
    const hex = "0123456789abcdef"
    var why = "no free name"
    # The names need not be unpredictable: exclusive creation, not the
    # name, keeps a planted file out (std/sysrand would need macOS's
    # Security framework).
    if not nameRandReady:
      nameRand = initRand(getTime().toUnix * 1_000_000_007 + getTime().nanosecond +
        int64(getpid()) * 7919 + cast[int64](addr nameRandReady))
      nameRandReady = true
    for attempt in 0 ..< 16:
      var name = path & "."
      for k in 0 ..< 12: name.add hex[nameRand.rand(15)]
      name.add ".tmp"
      # O_EXCL fails on any existing name, a symlink included. The mode is
      # 0666 less the umask, as for any new output file.
      let fd = posix.open(cstring(name), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC, 0o666)
      if fd >= 0:
        discard posix.close(fd)
        return name
      let err = errno
      why = $strerror(err)
      if err != EEXIST: break
    raise newException(IOError, "cannot create a temporary file next to " & path & ": " & why)
  else:
    try:
      # Exclusive (CREATE_NEW), with a random part.
      let (f, name) = createTempFile(extractFilename(path) & ".", ".tmp", parentDir(path))
      close(f)
      name
    except OSError as e:
      raise newException(IOError, "cannot create a temporary file next to " & path & ": " &
        e.msg)

proc createTempFor*(path: string, log: var DiagLog): string {.raises: [].} =
  ## `createTempFor`, with a failure logged as fatal (`dcIo`): then "".
  try:
    result = createTempFor(path)
  except IOError as e:
    log.report(sevFatal, dcIo, e.msg, loc = Location(file: path))

proc sameAsInput*(src, dst: string, log: var DiagLog): bool {.raises: [].} =
  ## True, with a fatal diagnostic, when `dst` is the existing file `src`:
  ## writing it would destroy the input.
  try:
    result = fileExists(dst) and sameFile(src, dst)
  except OSError:
    result = false # `src` cannot be inspected; reading it reports why
  if result:
    log.report(sevFatal, dcValidation, "the output is the input file; refusing to overwrite it",
      loc = Location(file: dst))

proc finishOutput*(tmp, path: string, keep: bool, log: var DiagLog) {.raises: [].} =
  ## Renames the complete output `tmp` (from `createTempFor`) to `path` when
  ## `keep`, else removes `tmp`. A failure to do either is logged as fatal.
  try:
    if not fileExists(tmp):
      discard
    elif keep:
      moveFile(tmp, path)
    else:
      removeFile(tmp)
  except OSError, IOError:
    let what = if keep: "cannot move the output into place: "
               else: "cannot remove the incomplete output: "
    log.report(sevFatal, dcIo, what & getCurrentExceptionMsg(), loc = Location(file: path))
