## Tests for the record I/O layer: memory tape (mock drive), tape images,
## disk files and the byte cursor.

import std/[assertions, os]
import parseSEG/common/[errors, diagnostics]
import parseSEG/io/[records, diskio, tapeimage, tapedevice, pushback, memsource]

let tmp = getTempDir() / "parseseg_tio"
createDir tmp

proc bytes(n: int; seed = 0): seq[byte] =
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = byte((i + seed) and 0xFF)

proc drain(src: RecordSource): seq[(RecordKind, int)] =
  ## Reads until end of data, returning (kind, data length) pairs.
  result = @[]
  var buf: seq[byte]
  var k = rkData
  while k != rkEndOfData:
    k = src.readRecord(buf, 1000)
    result.add (k, buf.len)

proc writeSample(sink: RecordSink) =
  ## label, mark, two records, mark, one odd-length record, end of data.
  sink.writeRecord bytes(128)
  sink.writeTapeMark
  sink.writeRecord bytes(10, 1)
  sink.writeRecord bytes(20, 2)
  sink.writeTapeMark
  sink.writeRecord bytes(7, 3)
  sink.writeTapeMark 2

const sampleKinds = @[(rkData, 128), (rkTapeMark, 0), (rkData, 10), (rkData, 20),
  (rkTapeMark, 0), (rkData, 7), (rkTapeMark, 0), (rkEndOfData, 0)]

block memory_tape_round_trip:
  let tape = newMemoryTape()
  let sink = newDeviceSink(tape)
  sink.writeSample
  doAssert sink.recordIndex == 4 and sink.fileIndex == 4
  doAssert tape.len == 8
  tape.rewind
  let src = newDeviceSource(tape)
  doAssert src.drain == sampleKinds
  doAssert src.recordIndex == 4 and src.fileIndex == 3 and src.atEnd
  var buf: seq[byte]
  doAssert src.readRecord(buf) == rkEndOfData, "stays at end of data"

block memory_tape_blank_end:
  # A single trailing mark followed by blank tape also ends cleanly.
  let tape = newMemoryTape(@[dataBlock(bytes(4)), tapeMark()])
  doAssert newDeviceSource(tape).drain == @[(rkData, 4), (rkTapeMark, 0), (rkEndOfData, 0)]

block memory_tape_positioning:
  let tape = newMemoryTape()
  newDeviceSink(tape).writeSample
  tape.rewind
  doAssert tape.status.atBeginning and tape.status.fileNumber == 0
  tape.spaceFiles 2
  var buf = newSeq[byte](64)
  var n = -1
  doAssert tape.readBlock(buf, n) == rkData and n == 7
  doAssert tape.status.fileNumber == 2 and tape.status.blockNumber == 1
  tape.spaceFiles -1
  doAssert tape[tape.pos].kind == tiMark, "BSF stops on the BOT side of the mark"
  doAssert tape.readBlock(buf, n) == rkTapeMark and n == 0
  doAssert tape.status.atTapeMark
  doAssertRaises IOError:
    tape.spaceFiles 5
  tape.rewind
  doAssertRaises IOError:
    tape.spaceFiles -1

block memory_tape_overwrite_truncates:
  let tape = newMemoryTape()
  newDeviceSink(tape).writeSample
  tape.rewind
  tape.spaceFiles 1
  tape.writeBlock bytes(3)
  doAssert tape.len == 3 and tape.status.atEndOfData

block memory_tape_media_limits:
  let tape = newMemoryTape()
  tape.writeProtected = true
  doAssertRaises IOError:
    tape.writeBlock bytes(1)
  let small = newMemoryTape()
  small.capacity = 10
  small.writeBlock bytes(8)
  doAssertRaises IOError:
    small.writeBlock bytes(8)
  small.rewind
  var tiny = newSeq[byte](4)
  var n = 0
  doAssertRaises IOError:
    discard small.readBlock(tiny, n)
  # Overwriting from BOT frees the truncated blocks' capacity.
  small.writeBlock bytes(8)
  doAssert not small.status.atEndOfMedium
  small.writeBlock bytes(2)
  doAssert small.status.atEndOfMedium
  doAssert small.readBlock(tiny, n) == rkEndOfData and n == 0

block tape_image_round_trip:
  let path = tmp / "sample.tap"
  let sink = openTapeImageSink(path)
  sink.writeSample
  sink.close
  # 4 records framed by 8 bytes each, 1 pad byte for the odd record, 4 marks.
  doAssert getFileSize(path) == (128 + 10 + 20 + 7) + 4 * 8 + 1 + 4 * 4
  let src = openTapeImageSource(path)
  doAssert src.hasRecordBoundaries
  doAssert src.drain == sampleKinds
  src.close

block tape_image_e11_unpadded:
  let path = tmp / "e11.tap"
  let sink = openTapeImageSink(path, padOdd = false)
  sink.writeRecord bytes(7)
  sink.writeTapeMark 2
  sink.close
  doAssert getFileSize(path) == 7 + 8 + 8
  let src = openTapeImageSource(path, padOdd = false)
  doAssert src.drain == @[(rkData, 7), (rkTapeMark, 0), (rkEndOfData, 0)]
  src.close

block tape_image_gap_and_end_of_medium:
  # SIMH erase gaps (sim_tape.h): the word 0xFFFFFFFE marks a gap (MTR_GAP).
  # 0xFFFEFFFF (MTR_FHGAP) is no marker of its own: it is the second half of
  # one gap marker and the first half of the next, where a gap was
  # overwritten off the 4-byte grid; 2 bytes are passed and the read is
  # aligned again. This test once had 0xFFFEFFFF as a 4-byte gap in front of
  # a record, which no SIMH image holds: the module took it for the gap
  # marker and refused the real one as a record of class 0xF.
  const gap = "\xFE\xFF\xFF\xFF"
  proc rec(s: string): string =
    let n = char(s.len) & "\x00\x00\x00"
    n & s & n
  let path = tmp / "gap.tap"
  writeFile path, gap & gap & rec("ab") & gap & rec("cd") & "\xFF\xFF" & gap & gap &
    rec("ef") & "\x00\x00\x00\x00" & "\xFF\xFF" & gap & "\xFF\xFF\xFF\xFF" &
    "garbage after end of medium"
  var src = openTapeImageSource(path)
  var buf: seq[byte]
  doAssert src.readRecord(buf) == rkData and buf == @[byte 'a', byte 'b']
  doAssert src.dataOffset == 12
  doAssert src.readRecord(buf) == rkData and buf == @[byte 'c', byte 'd']
  doAssert src.dataOffset == 26
  doAssert src.readRecord(buf) == rkData and buf == @[byte 'e', byte 'f']
  doAssert src.dataOffset == 46 and src.offset == 52 # 2 + 4 + 4 gap bytes, then the header
  doAssert src.readRecord(buf) == rkTapeMark
  doAssert src.readRecord(buf) == rkEndOfData and src.offset == 66
  src.close
  # A gap, whole or half, up to the end of the image.
  for tail in [gap, gap & gap, "\xFF\xFF" & gap]:
    writeFile path, rec("ab") & tail
    src = openTapeImageSource(path)
    doAssert src.drain == @[(rkData, 2), (rkEndOfData, 0)]
    src.close
  # Half a marker at the end is a cut image.
  writeFile path, rec("ab") & gap & "\xFF\xFF"
  src = openTapeImageSource(path)
  doAssert src.readRecord(buf) == rkData
  doAssertRaises SegTruncatedError: discard src.readRecord(buf)
  src.close

block tape_image_corruption:
  let path = tmp / "bad.tap"
  writeFile path, "\x04\x00\x00\x00ab"
  var src = openTapeImageSource(path)
  var buf: seq[byte]
  try:
    discard src.readRecord(buf)
    doAssert false, "truncated record must raise"
  except SegTruncatedError as e:
    doAssert e.offset == 4
  src.close
  # A trailer word that differs from the header word, and a record class
  # other than 0: where the next record starts is unknown, so both are
  # unlocatable (fatal at a reader's boundary) with the tape layout code.
  for (image, offset) in [("\x02\x00\x00\x00ab\x03\x00\x00\x00", 6),
      ("\x02\x00\x00\x80ab\x02\x00\x00\x80", 0)]:
    writeFile path, image
    src = openTapeImageSource(path)
    try:
      discard src.readRecord(buf)
      doAssert false, "a damaged record must raise"
    except SegUnlocatableError as e:
      doAssert e.diagCode == dcTapeLayout and e.offset == offset
    src.close
    var log = DiagLog()
    src = openTapeImageSource(path)
    doAssert not log.tryRecord(Location(file: path), (discard src.readRecord(buf)))
    doAssert log.isFatal and log[0].code == dcTapeLayout
    src.close
  let sink = openTapeImageSink(path)
  doAssertRaises SegFormatError:
    sink.writeRecord newSeq[byte]()
  sink.close

block disk_round_trip:
  let path = tmp / "plain.bin"
  let sink = openDiskSink(path)
  sink.writeSample
  sink.close
  doAssert getFileSize(path) == 128 + 10 + 20 + 7, "tape marks are not stored on disk"
  let src = openDiskSource(path)
  doAssert not src.hasRecordBoundaries
  var buf: seq[byte]
  doAssert src.readRecord(buf, 100) == rkData and buf.len == 100
  doAssert src.readRecord(buf, 100) == rkData and buf.len == 65
  doAssert src.dataOffset == 100 and src.offset == 165
  doAssert src.readRecord(buf, 100) == rkEndOfData
  src.close

block disk_missing_file:
  doAssertRaises IOError:
    discard openDiskSource(tmp / "does-not-exist")

block cursor_spans_blocks_and_stops_at_marks:
  let tape = newMemoryTape(@[dataBlock(bytes(5)), dataBlock(bytes(5, 5)), tapeMark(),
    dataBlock(bytes(3, 100)), tapeMark(), tapeMark()])
  var c = initRecordCursor(newDeviceSource(tape))
  var a: array[8, byte]
  c.readExactly a
  doAssert a == [0'u8, 1, 2, 3, 4, 5, 6, 7], "read spans two blocks"
  doAssert c.offset == 8 and not c.atRecordStart
  doAssert c.readRecordRest == @[8'u8, 9]
  var b: array[4, byte]
  doAssert c.read(b) == 0
  doAssert c.stoppedAt == rkTapeMark
  c.skipTapeMark
  try:
    c.readExactly b
    doAssert false, "only 3 bytes before the next mark"
  except SegTruncatedError as e:
    doAssert e.offset == 13
  doAssert c.stoppedAt == rkTapeMark
  c.skipTapeMark
  doAssert c.stoppedAt == rkEndOfData

block pushback_unread:
  # Unread in front of buffered bytes, into consumed room and growing the buffer.
  var p = initPushbackInput(newDeviceSource(newMemoryTape(@[dataBlock(bytes(10))])))
  var six: array[6, byte]
  p.readExactly six
  p.unread six.toOpenArray(2, 5)
  var two: array[2, byte]
  p.readExactly two
  doAssert two == [2'u8, 3]
  p.unread two
  p.readExactly two
  p.unread [0'u8, 1, 2, 3]
  doAssert p.offset == 0
  var all: array[12, byte]
  doAssert p.readAvail(all) == 10
  doAssert all[0 .. 9] == bytes(10)
  doAssert p.stoppedAt == rkEndOfData

block cursor_on_disk_with_diagnostics_boundary:
  let path = tmp / "short.bin"
  writeFile path, "0123456789"
  var c = initRecordCursor(openDiskSource(path), chunkSize = 3)
  var log = DiagLog()
  var hdr: array[4, byte]
  let first = log.tryRecord(Location(file: path, record: 0)):
    c.readExactly hdr
  doAssert first and c.offset == 4
  var big: array[16, byte]
  let second = log.tryRecord(Location(file: path, record: 1)):
    c.readExactly big
  doAssert not second
  doAssert log.isFatal and log[0].code == dcTruncated and log[0].offset == 10
  doAssert log[0].loc.file == path
  c.source.close

removeDir tmp

block memory_tape_head_is_clamped:
  # 12.4: `pos` is writable; a head past the end means end of data.
  let tape = newMemoryTape(@[dataBlock(bytes(4)), tapeMark(), dataBlock(bytes(2))])
  tape.pos = 99
  doAssert tape.status.atEndOfData and tape.status.fileNumber == 1
  tape.pos = 99
  tape.writeBlock(bytes(3)) # appends at the end
  doAssert tape.len == 4 and tape.pos == 4
  tape.pos = -5
  var buf = newSeq[byte](16)
  var n = 0
  doAssert tape.readBlock(buf, n) == rkData and n == 4
  tape.pos = 99
  tape.spaceFiles(-1)
  doAssert tape.pos == 1

block reused_buffers_hold_exactly_the_bytes_read:
  # Task 13.2: sources size their buffers uninitialized (zeroing a 1 MB
  # buffer per read cost more than the read); a reused buffer full of old
  # bytes must still come back holding exactly the medium's bytes.
  createDir tmp
  let path = tmp / "reuse.bin"
  let data = bytes(3 * 1024 + 17, 5)
  var s = newString(data.len)
  for i, c in data: s[i] = char(c)
  writeFile(path, s)
  for src in [RecordSource(openDiskSource(path)), RecordSource(openMemFileSource(path))]:
    var buf = newSeq[byte](1 shl 16)
    for b in buf.mitems: b = 0xEE
    var got: seq[byte]
    while src.readRecord(buf, 1000) == rkData:
      doAssert buf.len <= 1000
      got.add buf
    doAssert got == data
    src.close()
  var src2: RecordSource = openDiskSource(path)
  var p = initPushbackInput(src2)
  var buf = newSeq[byte](64)
  for b in buf.mitems: b = 0xEE
  p.readInto(buf, 2000)
  doAssert buf == data[0 ..< 2000]
  p.unread(buf.toOpenArray(1990, 1999))
  var tail: seq[byte]
  p.readInto(tail, 10 + data.len - 2000)
  doAssert tail == data[1990 .. ^1]
  src2.close()
