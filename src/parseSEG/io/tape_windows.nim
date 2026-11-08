## Windows tape drives through the Win32 tape API (`\\.\TAPE0`).
##
## Each `ReadFile`/`WriteFile` transfers one tape block (the drive should be
## in variable-block mode, block size 0). Tape marks surface as
## `ERROR_FILEMARK_DETECTED`, blank tape as `ERROR_NO_DATA_DETECTED`.

when not defined(windows):
  {.error: "tape_windows is only available on Windows".}

import std/[os, winlean]
import tapedevice

const
  ErrorMoreData = 234'i32
  ErrorEndOfMedia = 1100'i32
  ErrorFilemarkDetected = 1101'i32
  ErrorBeginningOfMedia = 1102'i32
  ErrorSetmarkDetected = 1103'i32
  ErrorNoDataDetected = 1104'i32
  ErrorWriteProtect = 19'i32
  TapeRewind = 0'i32
  TapeSpaceFilemarks = 6'i32
  TapeFilemarks = 1'i32
  GetTapeMediaInformation = 0'i32

type
  TapeGetMediaParameters {.pure.} = object
    capacity, remaining: int64
    blockSize, partitionCount: int32
    writeProtected: uint8

proc writeTapemark(h: Handle; kind, count: DWORD; immediate: WINBOOL): DWORD {.
  stdcall, dynlib: "kernel32", importc: "WriteTapemark".}
proc setTapePosition(h: Handle; mode, partition, offsetLow, offsetHigh: DWORD;
  immediate: WINBOOL): DWORD {.stdcall, dynlib: "kernel32", importc: "SetTapePosition".}
proc getTapeStatus(h: Handle): DWORD {.stdcall, dynlib: "kernel32", importc: "GetTapeStatus".}
proc getTapeParameters(h: Handle; op: DWORD; size: ptr DWORD; info: pointer): DWORD {.
  stdcall, dynlib: "kernel32", importc: "GetTapeParameters".}

type
  WindowsTape* = ref object of TapeDevice
    h: Handle
    lastError: int32  ## Error code of the last read (0 after a data block).

proc check(t: WindowsTape; code: DWORD; what: string) =
  if code != 0:
    raiseOSError(OSErrorCode(code), t.name & ": " & what)

proc openWindowsTape*(path = r"\\.\TAPE0"; write = false): WindowsTape =
  ## Opens a tape drive. Raises `OSError` if the device cannot be opened.
  let access = if write: GENERIC_READ or GENERIC_WRITE else: GENERIC_READ
  let h = createFileW(newWideCString(path), access, 0, nil, OPEN_EXISTING, 0, 0)
  if h == INVALID_HANDLE_VALUE:
    raiseOSError(osLastError(), "cannot open tape device " & path)
  WindowsTape(h: h, name: path)

method readBlock*(t: WindowsTape; buf: var openArray[byte]): int {.raises: [CatchableError].} =
  var n = 0'i32
  let ok = readFile(t.h, if buf.len > 0: addr buf[0] else: nil, int32(buf.len), addr n, nil)
  t.lastError = if ok != 0: 0'i32 else: getLastError()
  case t.lastError
  of 0: result = (if n > 0: int(n) else: 0)
  of ErrorFilemarkDetected, ErrorSetmarkDetected: result = 0
  of ErrorNoDataDetected, ErrorEndOfMedia: result = -1
  of ErrorMoreData:
    raise newException(IOError, t.name & ": block exceeds the " & $buf.len &
      "-byte read buffer")
  else:
    raiseOSError(OSErrorCode(t.lastError), t.name & ": read")

method writeBlock*(t: WindowsTape; data: openArray[byte]) {.raises: [CatchableError].} =
  var n = 0'i32
  if writeFile(t.h, if data.len > 0: unsafeAddr data[0] else: nil, int32(data.len),
      addr n, nil) == 0:
    raiseOSError(osLastError(), t.name & ": write")
  if n != data.len:
    raise newException(IOError, t.name & ": short write (" & $n & " of " & $data.len &
      " bytes), end of medium?")

method writeTapeMarks*(t: WindowsTape; count: Positive) {.raises: [CatchableError].} =
  t.check(writeTapemark(t.h, TapeFilemarks, DWORD(count), 0), "WriteTapemark")

method rewind*(t: WindowsTape) {.raises: [CatchableError].} =
  t.check(setTapePosition(t.h, TapeRewind, 0, 0, 0, 0), "rewind")
  t.lastError = ErrorBeginningOfMedia

method spaceFiles*(t: WindowsTape; count: int) {.raises: [CatchableError].} =
  if count != 0:
    let c = int64(count)
    t.check(setTapePosition(t.h, TapeSpaceFilemarks, 0, DWORD(c and 0xFFFF_FFFF),
      DWORD(c shr 32), 0), "space filemarks")

method status*(t: WindowsTape): TapeStatus {.raises: [CatchableError].} =
  let s = getTapeStatus(t.h)
  var info = TapeGetMediaParameters()
  var size = DWORD(sizeof(info))
  let haveInfo = getTapeParameters(t.h, GetTapeMediaInformation, addr size, addr info) == 0
  TapeStatus(online: s == 0 or s == ErrorWriteProtect,
    writeProtected: s == ErrorWriteProtect or (haveInfo and info.writeProtected != 0),
    atBeginning: t.lastError == ErrorBeginningOfMedia,
    atTapeMark: t.lastError in [ErrorFilemarkDetected, ErrorSetmarkDetected],
    atEndOfData: t.lastError == ErrorNoDataDetected,
    atEndOfMedium: t.lastError == ErrorEndOfMedia)

method close*(t: WindowsTape) {.raises: [CatchableError].} =
  if t.h != INVALID_HANDLE_VALUE:
    discard closeHandle(t.h)
    t.h = INVALID_HANDLE_VALUE
