## A byte input with push-back over a `RecordCursor`.
##
## Format readers sometimes read a block ahead, find it is not what they
## hoped for, and must un-read it. Tape cannot seek back, so the bytes are
## kept in a small buffer that later reads consume first. Reads of large
## blocks grow their buffer chunk by chunk as data arrives, so a corrupt
## length in a header costs memory only for the bytes that exist.

import ./records
import ../common/errors

const ReadChunk* = 4 shl 20 ## Growth step for large reads.

type
  PushbackInput* = object
    ## A cursor plus push-back buffer.
    cursor*: RecordCursor
    pending: seq[byte]
    pendingPos: int

func initPushbackInput*(src: RecordSource): PushbackInput =
  ## Creates an input reading from `src`, with nothing pushed back.
  PushbackInput(cursor: initRecordCursor(src))

func offset*(p: PushbackInput): int64 {.inline.} =
  ## Medium offset of the next byte that will be returned.
  p.cursor.offset - int64(p.pending.len - p.pendingPos)

proc readAvail*(p: var PushbackInput, dst: var openArray[byte]): int =
  ## Reads up to `dst.len` bytes; fewer only at a tape mark or end of data.
  result = min(dst.len, p.pending.len - p.pendingPos)
  if result > 0:
    copyMem(addr dst[0], addr p.pending[p.pendingPos], result)
    p.pendingPos += result
  if result < dst.len:
    result += p.cursor.read(dst.toOpenArray(result, dst.len - 1))

proc unread*(p: var PushbackInput, data: openArray[byte]) =
  ## Pushes `data` (just read) back in front of the unread bytes.
  if data.len <= p.pendingPos:
    # The consumed bytes in front of the unread ones make room.
    p.pendingPos -= data.len
  else:
    let rest = p.pending.len - p.pendingPos
    if rest == 0:
      p.pending.setLenUninit data.len # filled below
    else:
      var grown = newSeqUninit[byte](data.len + rest)
      copyMem(addr grown[data.len], addr p.pending[p.pendingPos], rest)
      p.pending = move grown
    p.pendingPos = 0
  if data.len > 0: copyMem(addr p.pending[p.pendingPos], addr data[0], data.len)

proc stoppedAt*(p: var PushbackInput): RecordKind =
  ## `rkData` if bytes are available, else the tape mark or end of data ahead.
  if p.pendingPos < p.pending.len: rkData else: p.cursor.stoppedAt

proc atData*(p: var PushbackInput): bool {.inline.} =
  ## True if bytes are available before the next tape mark or end of data.
  p.stoppedAt == rkData

proc skipTapeMark*(p: var PushbackInput) =
  ## Consumes a pending tape mark.
  p.cursor.skipTapeMark()

proc readExactly*(p: var PushbackInput, dst: var openArray[byte]) =
  ## Reads exactly `dst.len` bytes or raises `SegTruncatedError`.
  let got = p.readAvail(dst)
  if got < dst.len:
    raiseTruncated("expected " & $dst.len & " bytes, got " & $got, p.offset)

proc readInto*(p: var PushbackInput, buf: var seq[byte], n: int64) =
  ## Reads exactly `n` bytes into `buf` (reusing its storage), growing it in
  ## `ReadChunk` steps as data arrives. Raises `SegTruncatedError` if the
  ## data ends first, `SegFormatError` for an impossible length.
  if n < 0 or n > int64(high(int) div 2):
    raiseFormat("block length " & $n & " is not representable", p.offset)
  buf.setLen 0
  var got = 0
  while got < n:
    let step = int(min(n - got, ReadChunk))
    buf.setLenUninit got + step # filled by readAvail
    let k = p.readAvail(buf.toOpenArray(got, got + step - 1))
    got += k
    if k < step:
      buf.setLen got
      raiseTruncated("expected " & $n & " bytes, got " & $got, p.offset)

proc skip*(p: var PushbackInput, n: int64): int64 {.discardable.} =
  ## Discards up to `n` bytes (fewer at a tape mark or end of data) and
  ## returns how many were passed. Seekable byte streams skip without reading.
  if n <= 0: return 0
  result = min(n, int64(p.pending.len - p.pendingPos))
  p.pendingPos += int(result)
  if result < n: result += p.cursor.skip(n - result)

proc skipExactly*(p: var PushbackInput, n: int64) =
  ## Discards exactly `n` bytes or raises `SegTruncatedError`.
  let got = p.skip(n)
  if got < n:
    raiseTruncated("expected " & $n & " bytes, got " & $got, p.offset)

proc remainingInRecord*(p: PushbackInput): int =
  ## Bytes left before the end of the current physical record (tape block),
  ## pushed-back bytes included.
  p.pending.len - p.pendingPos + p.cursor.remainingInRecord

proc skipRecordRest*(p: var PushbackInput): int =
  ## Discards the rest of the current physical record (tape block); returns
  ## the bytes skipped. Pushed-back bytes are dropped first.
  result = p.pending.len - p.pendingPos
  p.pending.setLen 0
  p.pendingPos = 0
  result += p.cursor.readRecordRest().len
