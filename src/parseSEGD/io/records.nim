## Record I/O: the medium-independent layer between storage and the SEG
## format codecs.
##
## A `RecordSource` yields a sequence of physical records (tape blocks),
## tape marks and finally end-of-data. A `RecordSink` accepts the same. Disk
## files have no physical records: their sources return byte chunks
## (`hasRecordBoundaries` is false) and their sinks ignore tape marks.
##
## Backends subclass `RecordSource`/`RecordSink` and override the `*Impl`
## methods; the non-virtual `readRecord`/`writeRecord`/`writeTapeMark` procs
## do the shared bookkeeping (counters, end-of-data detection).
##
## Base methods declare `raises: [CatchableError]`: call sites take their
## exception handling from the base method, so a base that cannot raise
## makes callers skip cleanup when an override does raise (leaks under ORC).
##
## `RecordCursor` turns a source into a byte stream for the format layer:
## exact-length reads that may span blocks but never cross a tape mark.

import ../common/errors

const
  DefaultChunkSize* = 1 shl 20
    ## Chunk size used by byte-stream sources when the caller does not ask for one.
  SkipRefill = 512 ## Smallest refill after a seek: most trace headers fit (see `RecordCursor.sized`).

type
  RecordKind* = enum
    rkData       ## A data record (or, for byte streams, a chunk of bytes).
    rkTapeMark   ## A tape mark (file mark).
    rkEndOfData  ## End of recorded data: a double tape mark, end of file or blank tape.

  RecordSource* = ref object of RootObj
    ## Base type of all record readers.
    name*: string           ## File path or device name, for diagnostics.
    offset*: int64          ## Medium offset of the next record (bytes read so far for devices).
    dataOffset*: int64      ## Medium offset of the first data byte of the last record read.
    recordIndex*: int       ## Data records returned so far.
    fileIndex*: int         ## Tape marks passed so far.
    lastWasMark, ended: bool

  RecordSink* = ref object of RootObj
    ## Base type of all record writers.
    name*: string     ## File path or device name, for diagnostics.
    offset*: int64    ## Medium offset where the next record will be written.
    recordIndex*: int ## Data records written so far.
    fileIndex*: int   ## Tape marks written so far.

method readRecordImpl*(s: RecordSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    base, raises: [CatchableError].} =
  ## Backend hook: reads the next item into `buf` (resized to the data length).
  ## Record-based media return one whole record regardless of `maxLen`;
  ## byte streams return up to `maxLen` bytes. Must set `s.dataOffset` to the
  ## data start and advance `s.offset` past the item.
  raiseAssert "readRecordImpl not implemented for this source"

method hasRecordBoundaries*(s: RecordSource): bool {.base.} =
  ## True if records are physical tape blocks; false for byte streams.
  true

method close*(s: RecordSource) {.base, raises: [CatchableError].} =
  ## Releases the underlying file or device.
  discard

method seekForward*(s: RecordSource; n: int64): int64 {.base, raises: [CatchableError].} =
  ## Backend hook for byte streams: advances `n` bytes without reading them
  ## (fewer at the end of the data) and returns how many were passed, or -1
  ## if the backend cannot seek, so callers read and discard instead. Must
  ## advance `s.offset`. Record-based media never seek.
  -1

method writeRecordImpl*(s: RecordSink; data: openArray[byte]) {.base, raises: [CatchableError].} =
  ## Backend hook: writes one record. Must update `s.offset`.
  raiseAssert "writeRecordImpl not implemented for this sink"

method writeTapeMarkImpl*(s: RecordSink) {.base, raises: [CatchableError].} =
  ## Backend hook: writes one tape mark. Must update `s.offset`.
  raiseAssert "writeTapeMarkImpl not implemented for this sink"

method close*(s: RecordSink) {.base, raises: [CatchableError].} =
  ## Flushes and releases the underlying file or device.
  discard

proc readRecord*(s: RecordSource; buf: var seq[byte];
    maxLen = DefaultChunkSize): RecordKind =
  ## Reads the next record into `buf`. Two consecutive tape marks are reported
  ## as one `rkTapeMark` followed by `rkEndOfData`; after end-of-data every
  ## call returns `rkEndOfData` without touching the medium. Raises `IOError`
  ## or `OSError` on device failures and `SegFormatError` on a corrupt medium.
  if s.ended:
    buf.setLen 0
    return rkEndOfData
  result = s.readRecordImpl(buf, maxLen)
  if result != rkData: buf.setLen 0
  case result
  of rkData:
    inc s.recordIndex
    s.lastWasMark = false
  of rkTapeMark:
    if s.lastWasMark:
      result = rkEndOfData
      s.ended = true
    else:
      inc s.fileIndex
      s.lastWasMark = true
  of rkEndOfData:
    s.ended = true

proc atEnd*(s: RecordSource): bool {.inline.} =
  ## True once end-of-data has been returned.
  s.ended

proc writeRecord*(s: RecordSink; data: openArray[byte]) =
  ## Writes `data` as one record (appends it, for byte-stream sinks).
  s.writeRecordImpl(data)
  inc s.recordIndex

proc writeTapeMark*(s: RecordSink; count: Positive = 1) =
  ## Writes `count` tape marks. Write 2 to mark end-of-data on tape.
  for _ in 1..count:
    s.writeTapeMarkImpl()
    inc s.fileIndex

# ------------------------------------------------------------------ cursor --

type
  RecordCursor* = object
    ## Byte-stream view of a `RecordSource`. Reads span record boundaries but
    ## stop at tape marks, which the format layer must acknowledge with
    ## `skipTapeMark`.
    src: RecordSource
    buf: seq[byte]
    pos: int
    pending: RecordKind  ## What stopped the stream; rkData while bytes flow.
    chunk: int
    sized: bool
      ## Set once a skip has seeked: refills then fetch what the next read
      ## needs (at least `SkipRefill` bytes) instead of a whole chunk, so a
      ## header-only walk copies the headers, not the samples it skips.

proc initRecordCursor*(src: RecordSource; chunkSize = DefaultChunkSize): RecordCursor =
  ## Creates a cursor reading from `src`.
  RecordCursor(src: src, chunk: chunkSize, pending: rkData)

proc source*(c: RecordCursor): RecordSource {.inline.} = c.src

proc preferSmallReads*(c: var RecordCursor) {.inline.} =
  ## Refill with what each read needs instead of whole chunks, as after a
  ## seek: for header-only walks, which skip most bytes.
  c.sized = true

proc fill(c: var RecordCursor; want = 0): bool =
  ## Ensures unread bytes are buffered (`want`: bytes the caller is about to
  ## read, a size hint). False if a tape mark or end-of-data blocks the stream.
  while c.pos >= c.buf.len and c.pending == rkData:
    c.pos = 0
    let n = if c.sized: max(SkipRefill, min(want, c.chunk)) else: c.chunk
    c.pending = c.src.readRecord(c.buf, n) # an empty data record loops again
  c.pos < c.buf.len

proc stoppedAt*(c: var RecordCursor): RecordKind =
  ## What lies ahead: `rkData` if bytes are available, else the tape mark or
  ## end-of-data that blocks the stream.
  if c.fill(): rkData else: c.pending

proc skipTapeMark*(c: var RecordCursor) =
  ## Consumes a pending tape mark so reading can continue into the next file.
  assert c.stoppedAt == rkTapeMark, "skipTapeMark called without a pending tape mark"
  c.pending = rkData

proc offset*(c: RecordCursor): int64 =
  ## Medium offset of the next unread byte (within the image file, for tape
  ## images).
  if c.pos < c.buf.len: c.src.dataOffset + c.pos else: c.src.offset

proc remainingInRecord*(c: RecordCursor): int {.inline.} =
  ## Unread bytes left in the current physical record (0 at a record start).
  max(0, c.buf.len - c.pos)

proc atRecordStart*(c: RecordCursor): bool {.inline.} =
  ## True if the next byte starts a physical record.
  c.pos == 0 or c.pos >= c.buf.len

proc read*(c: var RecordCursor; dst: var openArray[byte]): int =
  ## Reads up to `dst.len` bytes, stopping early only at a tape mark or end of
  ## data. Returns the number of bytes read.
  result = 0
  while result < dst.len and c.fill(dst.len - result):
    let n = min(dst.len - result, c.buf.len - c.pos)
    copyMem(addr dst[result], addr c.buf[c.pos], n)
    inc c.pos, n
    inc result, n

proc readExactly*(c: var RecordCursor; dst: var openArray[byte]) =
  ## Reads exactly `dst.len` bytes or raises `SegTruncatedError` (with the
  ## offset where data ran out).
  let n = c.read(dst)
  if n < dst.len:
    raiseTruncated("expected " & $dst.len & " bytes, got " & $n & " before " &
      $c.stoppedAt, c.offset)

proc skip*(c: var RecordCursor; n: int64): int64 =
  ## Passes over up to `n` bytes, stopping early only at a tape mark or end
  ## of data, and returns how many were passed. Byte streams that can seek
  ## (disk files, memory maps) skip without reading; other media read and
  ## discard.
  if n <= 0: return 0
  result = min(n, int64(c.buf.len - c.pos))
  if result > 0: c.pos += int(result)
  if result < n and c.pending == rkData and not c.src.hasRecordBoundaries:
    let k = c.src.seekForward(n - result)
    if k >= 0:
      result += k
      c.sized = true
      if result < n: discard c.fill() # let the source report end of data
  if result < n:
    var scratch {.noinit.}: array[65536, byte]
    while result < n and c.fill(int(min(n - result, scratch.len))):
      let k = c.read(scratch.toOpenArray(0, int(min(n - result, scratch.len)) - 1))
      result += k

proc readRecordRest*(c: var RecordCursor): seq[byte] =
  ## Returns the unread rest of the current physical record (empty if at a
  ## record start). Used to keep padding or unparsed tails losslessly.
  if c.pos < c.buf.len:
    result = c.buf[c.pos ..< c.buf.len]
    c.pos = c.buf.len
  else:
    result = @[]
