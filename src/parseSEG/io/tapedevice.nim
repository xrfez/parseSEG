## Tape drives as record sources and sinks.
##
## `TapeDevice` is the minimal drive interface (block read/write, tape marks,
## positioning, status). Real drives implement it in `tape_linux` and
## `tape_windows`. `MemoryTape` implements it in memory; it is both the
## memory backend and the mock drive used to test tape logic without
## hardware. `DeviceSource`/`DeviceSink` adapt any `TapeDevice` to the record
## layer.

import records

const DefaultMaxBlockSize* = 4 shl 20
  ## Default read buffer for drives: above every SEG App. F maximum (DST, 1.2 MB).

type
  TapeStatus* = object
    ## Drive state. Fields a drive cannot report stay at their defaults.
    fileNumber*: int = -1   ## Tape marks between BOT and the head; -1 if unknown.
    blockNumber*: int = -1  ## Block within the current file; -1 if unknown.
    atBeginning*: bool      ## At beginning of tape (BOT).
    atTapeMark*: bool       ## Just after a tape mark.
    atEndOfData*: bool      ## At end of recorded data.
    atEndOfMedium*: bool    ## Early-warning or physical end of medium reached.
    writeProtected*: bool
    online*: bool = true

  TapeDevice* = ref object of RootObj
    ## Base type of tape drives.
    name*: string ## Device path (e.g. `/dev/nst0`, `\\.\TAPE0`), for diagnostics.

method readBlock*(d: TapeDevice; buf: var openArray[byte]): int {.base, raises: [CatchableError].} =
  ## Reads one block into `buf`. Returns its length, 0 for a tape mark, or -1
  ## at end of data (blank tape). Raises `IOError` if the block is larger
  ## than `buf` or the drive fails.
  raiseAssert "readBlock not implemented for this device"

method writeBlock*(d: TapeDevice; data: openArray[byte]) {.base, raises: [CatchableError].} =
  ## Writes one block. Raises `IOError` on failure (e.g. end of medium).
  raiseAssert "writeBlock not implemented for this device"

method writeTapeMarks*(d: TapeDevice; count: Positive) {.base, raises: [CatchableError].} =
  ## Writes `count` tape marks.
  raiseAssert "writeTapeMarks not implemented for this device"

method rewind*(d: TapeDevice) {.base, raises: [CatchableError].} =
  ## Rewinds to the beginning of tape.
  raiseAssert "rewind not implemented for this device"

method spaceFiles*(d: TapeDevice; count: int) {.base, raises: [CatchableError].} =
  ## Positive `count`: skips forward past `count` tape marks. Negative: moves
  ## backward over `-count` tape marks and stops on their BOT side.
  raiseAssert "spaceFiles not implemented for this device"

method status*(d: TapeDevice): TapeStatus {.base, raises: [CatchableError].} =
  ## Queries the drive state.
  TapeStatus()

method close*(d: TapeDevice) {.base, raises: [CatchableError].} =
  ## Releases the drive (does not rewind).
  discard

# ------------------------------------------------------ record adapters --

type
  DeviceSource* = ref object of RecordSource
    dev: TapeDevice
    maxBlock: int

  DeviceSink* = ref object of RecordSink
    dev: TapeDevice

proc newDeviceSource*(dev: TapeDevice; maxBlockSize = DefaultMaxBlockSize): DeviceSource =
  ## Reads records from `dev`, one block per record, with a buffer of at least
  ## `maxBlockSize` bytes.
  DeviceSource(dev: dev, name: dev.name, maxBlock: maxBlockSize)

proc device*(s: DeviceSource): TapeDevice {.inline.} = s.dev

method readRecordImpl*(s: DeviceSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  buf.setLen max(s.maxBlock, maxLen)
  let n = s.dev.readBlock(buf)
  buf.setLen max(n, 0)
  s.dataOffset = s.offset
  if n > 0:
    s.offset += n
    rkData
  elif n == 0: rkTapeMark
  else: rkEndOfData

method close*(s: DeviceSource) {.raises: [CatchableError].} = s.dev.close()

proc newDeviceSink*(dev: TapeDevice): DeviceSink =
  ## Writes records to `dev`, one block per record.
  DeviceSink(dev: dev, name: dev.name)

proc device*(s: DeviceSink): TapeDevice {.inline.} = s.dev

method writeRecordImpl*(s: DeviceSink; data: openArray[byte]) {.raises: [CatchableError].} =
  s.dev.writeBlock(data)
  s.offset += data.len

method writeTapeMarkImpl*(s: DeviceSink) {.raises: [CatchableError].} = s.dev.writeTapeMarks(1)

method close*(s: DeviceSink) {.raises: [CatchableError].} = s.dev.close()

# ------------------------------------------------------------ memory tape --

type
  TapeItemKind* = enum
    tiBlock, tiMark

  TapeItem* = object
    ## One item on a `MemoryTape`.
    case kind*: TapeItemKind
    of tiBlock: data*: seq[byte]
    of tiMark: discard

  MemoryTape* = ref object of TapeDevice
    ## In-memory tape drive. Behaves like a real drive: writing truncates
    ## everything after the head, reading past the last item reports end of
    ## data, and `writeProtected`/`capacity` simulate media limits.
    items*: seq[TapeItem]
    pos*: int              ## Index of the next item under the head.
    writeProtected*: bool
    capacity*: int = -1    ## Maximum stored data bytes; -1 for unlimited.

proc newMemoryTape*(items: sink seq[TapeItem] = @[]; name = "memory"): MemoryTape =
  ## Creates an in-memory tape holding `items`, positioned at BOT.
  MemoryTape(items: items, name: name)

proc dataBlock*(data: openArray[byte]): TapeItem = TapeItem(kind: tiBlock, data: @data)
proc tapeMark*(): TapeItem = TapeItem(kind: tiMark)

proc usedBytes(t: MemoryTape): int =
  for it in t.items:
    if it.kind == tiBlock: result += it.data.len

method readBlock*(t: MemoryTape; buf: var openArray[byte]): int {.raises: [CatchableError].} =
  if t.pos >= t.items.len:
    return -1
  let it = t.items[t.pos]
  if it.kind == tiMark:
    inc t.pos
    return 0
  if it.data.len > buf.len:
    raise newException(IOError, t.name & ": block of " & $it.data.len &
      " bytes exceeds the " & $buf.len & "-byte read buffer")
  inc t.pos
  if it.data.len > 0: copyMem(addr buf[0], unsafeAddr it.data[0], it.data.len)
  it.data.len

proc truncateAtHead(t: MemoryTape) =
  if t.writeProtected:
    raise newException(IOError, t.name & ": tape is write protected")
  t.items.setLen t.pos

method writeBlock*(t: MemoryTape; data: openArray[byte]) {.raises: [CatchableError].} =
  t.truncateAtHead()
  if t.capacity >= 0 and t.usedBytes + data.len > t.capacity:
    raise newException(IOError, t.name & ": end of medium")
  t.items.add dataBlock(data)
  inc t.pos

method writeTapeMarks*(t: MemoryTape; count: Positive) {.raises: [CatchableError].} =
  t.truncateAtHead()
  for _ in 1..count:
    t.items.add tapeMark()
    inc t.pos

method rewind*(t: MemoryTape) {.raises: [CatchableError].} = t.pos = 0

method spaceFiles*(t: MemoryTape; count: int) {.raises: [CatchableError].} =
  if count > 0:
    var left = count
    while left > 0:
      if t.pos >= t.items.len:
        raise newException(IOError, t.name & ": end of data while spacing forward")
      if t.items[t.pos].kind == tiMark: dec left
      inc t.pos
  elif count < 0:
    var left = -count
    while left > 0:
      if t.pos == 0:
        raise newException(IOError, t.name & ": beginning of tape while spacing backward")
      dec t.pos
      if t.items[t.pos].kind == tiMark: dec left

method status*(t: MemoryTape): TapeStatus {.raises: [CatchableError].} =
  result = TapeStatus(atBeginning: t.pos == 0, atEndOfData: t.pos >= t.items.len,
    writeProtected: t.writeProtected, fileNumber: 0, blockNumber: 0)
  for i in 0 ..< t.pos:
    if t.items[i].kind == tiMark:
      inc result.fileNumber
      result.blockNumber = 0
    else:
      inc result.blockNumber
  result.atTapeMark = t.pos > 0 and t.items[t.pos - 1].kind == tiMark
  result.atEndOfMedium = t.capacity >= 0 and t.usedBytes >= t.capacity
