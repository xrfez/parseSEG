## Tape-image files in the SIMH `.tap` format, which preserve record lengths
## and tape marks.
##
## Layout: each record is `len (u32 LE) | data | len (u32 LE)`; a tape mark is
## a single zero length word; `0xFFFFFFFF` marks end of medium and
## `0xFFFEFFFF` is an erase gap (skipped). In the standard SIMH format odd
## records are padded with one zero byte (not counted in `len`); E11 images
## are not padded (`padOdd = false`). The top 4 bits of `len` are a record
## class; class 0 is good data. Any other class, and a trailer word that
## differs from its header word, raise `SegUnlocatableError` (`dcTapeLayout`):
## where the next record starts is then unknown, so readers stop there with a
## fatal entry.

from std/strutils import toHex
import ../common/[errors, diagnostics]
import records

const
  TapMark = 0x0000_0000'u32
  TapEndOfMedium = 0xFFFF_FFFF'u32
  TapEraseGap = 0xFFFE_FFFF'u32
  TapClassMask = 0xF000_0000'u32

type
  TapeImageSource* = ref object of RecordSource
    f: File
    padOdd: bool

  TapeImageSink* = ref object of RecordSink
    f: File
    padOdd: bool

func le32(b: openArray[byte]): uint32 =
  uint32(b[0]) or (uint32(b[1]) shl 8) or (uint32(b[2]) shl 16) or (uint32(b[3]) shl 24)

proc openTapeImageSource*(path: string; padOdd = true): TapeImageSource =
  ## Opens a tape image for reading. Raises `IOError` if it cannot be opened.
  var f: File
  if not open(f, path, fmRead):
    raise newException(IOError, "cannot open for reading: " & path)
  TapeImageSource(f: f, name: path, padOdd: padOdd)

proc readWord(s: TapeImageSource; what: string; atEofOk: bool; word: var uint32): bool =
  ## Reads a length word into `word`. Returns false at a clean end of file
  ## when `atEofOk`; raises `SegTruncatedError` on a partial word.
  var w: array[4, byte]
  let n = readBuffer(s.f, addr w[0], 4)
  if n == 0 and atEofOk:
    result = false
  elif n < 4:
    raiseTruncated("tape image ends inside " & what, s.offset)
  else:
    s.offset += 4
    word = le32(w)
    result = true

method readRecordImpl*(s: TapeImageSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  result = rkEndOfData
  var done = false
  while not done:
    let start = s.offset
    var word = 0'u32
    let ok = s.readWord("a record header", atEofOk = true, word)
    done = true
    if not ok or word == TapEndOfMedium:
      result = rkEndOfData
    elif word == TapEraseGap:
      done = false
    elif word == TapMark:
      result = rkTapeMark
    elif (word and TapClassMask) != 0:
      # The length of such a record is not known to be one, so the next
      # record cannot be located: readers stop (a fatal `tapeLayout` entry).
      raiseUnlocatable(dcTapeLayout, "tape image record class 0x" & toHex(word shr 28, 1) &
        " (bad or private record) is not supported", start)
    else:
      let n = int(word)
      buf.setLenUninit n # filled by the read
      s.dataOffset = s.offset
      if readBuffer(s.f, addr buf[0], n) < n:
        raiseTruncated("tape image ends inside a " & $n & "-byte record", s.dataOffset)
      s.offset += n
      if s.padOdd and (n and 1) == 1:
        var pad: byte
        if readBuffer(s.f, addr pad, 1) < 1:
          raiseTruncated("tape image ends inside record padding", s.offset)
        s.offset += 1
      var trailer = 0'u32
      discard s.readWord("a record trailer", atEofOk = false, trailer)
      if trailer != word:
        raiseUnlocatable(dcTapeLayout, "tape image record trailer " & $trailer &
          " does not match header " & $word, s.offset - 4)
      result = rkData

method close*(s: TapeImageSource) {.raises: [CatchableError].} =
  if s.f != nil:
    close(s.f)
    s.f = nil

proc openTapeImageSink*(path: string; padOdd = true): TapeImageSink =
  ## Creates (or truncates) a tape image for writing. Raises `IOError` on failure.
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "cannot open for writing: " & path)
  TapeImageSink(f: f, name: path, padOdd: padOdd)

proc writeBytes(s: TapeImageSink; p: pointer; n: int) =
  if n > 0 and writeBuffer(s.f, p, n) != n:
    raise newException(IOError, "write failed: " & s.name)
  s.offset += n

proc writeWord(s: TapeImageSink; w: uint32) =
  var b = [byte(w and 0xFF), byte((w shr 8) and 0xFF), byte((w shr 16) and 0xFF),
    byte(w shr 24)]
  s.writeBytes(addr b[0], 4)

method writeRecordImpl*(s: TapeImageSink; data: openArray[byte]) {.raises: [CatchableError].} =
  if data.len == 0 or uint64(data.len) >= uint64(TapClassMask):
    raiseFormat("tape image records must hold 1..268435455 bytes, got " & $data.len, s.offset)
  s.writeWord uint32(data.len)
  s.writeBytes(addr data[0], data.len)
  if s.padOdd and (data.len and 1) == 1:
    var pad = 0'u8
    s.writeBytes(addr pad, 1)
  s.writeWord uint32(data.len)

method writeTapeMarkImpl*(s: TapeImageSink) {.raises: [CatchableError].} =
  s.writeWord TapMark

method close*(s: TapeImageSink) {.raises: [CatchableError].} =
  if s.f != nil:
    close(s.f)
    s.f = nil
