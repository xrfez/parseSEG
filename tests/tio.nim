## Tests for the record I/O layer: memory tape (mock drive), tape images,
## disk files and the byte cursor.

import std/[assertions, os]
import parseSEG/common/[errors, diagnostics]
import parseSEG/io/[records, diskio, tapeimage, tapedevice]

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
  doAssert tape.items.len == 8
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
  doAssert tape.readBlock(buf) == 7
  doAssert tape.status.fileNumber == 2 and tape.status.blockNumber == 1
  tape.spaceFiles -1
  doAssert tape.items[tape.pos].kind == tiMark, "BSF stops on the BOT side of the mark"
  doAssert tape.readBlock(buf) == 0
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
  doAssert tape.items.len == 3 and tape.status.atEndOfData

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
  doAssertRaises IOError:
    discard small.readBlock(tiny)

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
  let path = tmp / "gap.tap"
  writeFile path, "\xFF\xFF\xFE\xFF" & "\x02\x00\x00\x00ab\x02\x00\x00\x00" &
    "\xFF\xFF\xFF\xFF" & "garbage after end of medium"
  let src = openTapeImageSource(path)
  var buf: seq[byte]
  doAssert src.readRecord(buf) == rkData and buf == @[byte 'a', byte 'b']
  doAssert src.dataOffset == 8
  doAssert src.readRecord(buf) == rkEndOfData
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
  writeFile path, "\x02\x00\x00\x00ab\x03\x00\x00\x00"
  src = openTapeImageSource(path)
  doAssertRaises SegFormatError:
    discard src.readRecord(buf)
  src.close
  writeFile path, "\x02\x00\x00\x80ab\x02\x00\x00\x80"
  src = openTapeImageSource(path)
  doAssertRaises SegFormatError:
    discard src.readRecord(buf)
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
