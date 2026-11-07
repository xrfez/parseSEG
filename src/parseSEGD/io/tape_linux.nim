## Linux SCSI tape drives through the `st(4)` driver.
##
## Open the non-rewinding device (`/dev/nst0`) so that closing between files
## does not rewind. The drive must be in variable-block mode (the default for
## most drives; `mt -f /dev/nst0 setblk 0`), so that each `read()`/`write()`
## transfers exactly one tape block.

when not defined(linux):
  {.error: "tape_linux is only available on Linux".}

import std/[posix, os]
import tapedevice

type
  MtOp {.importc: "struct mtop", header: "<sys/mtio.h>".} = object
    mt_op: cshort
    mt_count: cint

  MtGet {.importc: "struct mtget", header: "<sys/mtio.h>".} = object
    mt_gstat: clong
    mt_fileno: clong
    mt_blkno: clong

var
  MTIOCTOP {.importc, header: "<sys/mtio.h>".}: culong
  MTIOCGET {.importc, header: "<sys/mtio.h>".}: culong
  MTFSF {.importc, header: "<sys/mtio.h>".}: cshort
  MTBSF {.importc, header: "<sys/mtio.h>".}: cshort
  MTWEOF {.importc, header: "<sys/mtio.h>".}: cshort
  MTREW {.importc, header: "<sys/mtio.h>".}: cshort

const # mt_gstat bits (GMT_* macros in <sys/mtio.h>)
  GmtEof = 0x8000_0000
  GmtBot = 0x4000_0000
  GmtEot = 0x2000_0000
  GmtEod = 0x0800_0000
  GmtWrProt = 0x0400_0000
  GmtOnline = 0x0100_0000

type
  LinuxTape* = ref object of TapeDevice
    fd: cint

proc fail(t: LinuxTape; what: string) {.noinline, noreturn.} =
  let err = osLastError()
  raiseOSError(err, t.name & ": " & what)

proc openLinuxTape*(path = "/dev/nst0"; write = false): LinuxTape =
  ## Opens a tape drive. Raises `OSError` if the device cannot be opened.
  let flags = if write: O_RDWR else: O_RDONLY
  let fd = posix.open(path.cstring, flags)
  if fd < 0:
    raiseOSError(osLastError(), "cannot open tape device " & path)
  LinuxTape(fd: fd, name: path)

proc op(t: LinuxTape; code: cshort; count: int; what: string) =
  var m = MtOp(mt_op: code, mt_count: cint(count))
  if ioctl(t.fd, MTIOCTOP, addr m) < 0: t.fail(what)

proc rawStatus(t: LinuxTape): MtGet =
  if ioctl(t.fd, MTIOCGET, addr result) < 0: t.fail("MTIOCGET")

method status*(t: LinuxTape): TapeStatus =
  let g = t.rawStatus()
  let s = int(g.mt_gstat)
  TapeStatus(fileNumber: int(g.mt_fileno), blockNumber: int(g.mt_blkno),
    atBeginning: (s and GmtBot) != 0, atTapeMark: (s and GmtEof) != 0,
    atEndOfData: (s and GmtEod) != 0, atEndOfMedium: (s and GmtEot) != 0,
    writeProtected: (s and GmtWrProt) != 0, online: (s and GmtOnline) != 0)

method readBlock*(t: LinuxTape; buf: var openArray[byte]): int =
  let n = posix.read(t.fd, if buf.len > 0: addr buf[0] else: nil, buf.len)
  if n > 0:
    result = n
  elif n == 0:
    # 0 bytes is a tape mark, unless the drive reports blank tape.
    result = if t.status.atEndOfData: -1 else: 0
  else:
    let err = errno
    if err == ENOMEM:
      raise newException(IOError, t.name & ": block exceeds the " & $buf.len &
        "-byte read buffer")
    if (err == EIO or err == ENOSPC) and (let s = t.status; s.atEndOfData or s.atEndOfMedium):
      result = -1
    else:
      t.fail("read")

method writeBlock*(t: LinuxTape; data: openArray[byte]) =
  let n = posix.write(t.fd, if data.len > 0: unsafeAddr data[0] else: nil, data.len)
  if n < 0: t.fail("write")
  if n != data.len:
    raise newException(IOError, t.name & ": short write (" & $n & " of " & $data.len &
      " bytes), end of medium?")

method writeTapeMarks*(t: LinuxTape; count: Positive) = t.op(MTWEOF, count, "MTWEOF")

method rewind*(t: LinuxTape) = t.op(MTREW, 1, "MTREW")

method spaceFiles*(t: LinuxTape; count: int) =
  if count > 0: t.op(MTFSF, count, "MTFSF")
  elif count < 0: t.op(MTBSF, -count, "MTBSF")

method close*(t: LinuxTape) =
  if t.fd >= 0:
    discard posix.close(t.fd)
    t.fd = -1
