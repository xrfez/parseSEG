## A read that stops early always says so with a fatal entry (`isFatal`):
## the streaming readers, the index walk and the demultiplexed copy, on a
## source that fails in the middle and on damaged tape images.

import std/[assertions, os, strutils]
import parseSEG/common/[errors, diagnostics, seismickind]
import parseSEG/io/[records, diskio, tapeimage]
import parseSEG/segy/[reader as segyreader, writer as segywriter]
import parseSEG/segd/[reader as segdreader, writer as segdwriter, demux]
import parseSEG/model/[indexwalk, indextypes]
import ./utils/testutils

let tmp = scratchDir("parseseg_tstopfatal")

type
  FailingSource = ref object of RecordSource
    ## A byte stream that raises `err` once `failAt` bytes have been read.
    data: seq[byte]
    pos, failAt: int
    err: ref CatchableError

method readRecordImpl(s: FailingSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  if s.pos >= s.failAt: raise s.err
  let n = min(maxLen, min(s.failAt, s.data.len) - s.pos)
  if n <= 0: return rkEndOfData
  buf.setLen n
  for i in 0 ..< n: buf[i] = s.data[s.pos + i]
  s.dataOffset = s.pos
  s.pos += n
  s.offset = s.pos
  rkData

method hasRecordBoundaries(s: FailingSource): bool {.raises: [].} = false

proc failing(path: string, failAt: int, err: ref CatchableError): FailingSource =
  FailingSource(data: readBytes(path), failAt: failAt, err: err, name: "failing")

proc plain(): ref CatchableError = (ref SegFormatError)(msg: "medium error", offset: 5)
proc foreign(): ref CatchableError = newException(KeyError, "not ours")

proc lastIsFatal(log: DiagLog, code: DiagCode): bool =
  log.isFatal and log.len > 0 and log[log.len - 1].severity == sevFatal and
    log[log.len - 1].code == code

let survey = demoDir() / "survey.sgy"
let shot = demoDir() / "shot.sgd"

block segy_reader_stops_with_a_fatal_entry:
  # A plain SegFormatError was logged as an error: the read ended, the index
  # held a part of the file, and `isFatal` said nothing had happened.
  let whole = readSegy(survey)
  let first = int(whole.file.firstTraceOffset)
  for (failAt, traces) in [(100, 0), (3300, 0), (first + 100, 0), (first + 10 * 8244 + 5000, 10)]:
    for (err, code) in [(plain(), dcBadValue), (foreign(), dcInternal)]:
      let d = readSegy(failing(survey, failAt, err))
      doAssert d.traces.len == traces and d.log.lastIsFatal(code), $failAt & " " & $d.log
      let ix = buildIndex(failing(survey, failAt, err), skSegy)
      doAssert ix.entries.len == traces and ix.log.lastIsFatal(code), $failAt & " " & $ix.log

block segd_reader_stops_with_a_fatal_entry:
  let whole = readSegd(shot)
  doAssert whole.records.len == 1 and whole.records[0].traces.len == 5
  let t2 = int(whole.records[0].traces[2].offset)
  for (failAt, records, traces) in [(0, 0, 0), (40, 0, 0), (t2 + 30, 1, 2), (t2 + 5000, 1, 2)]:
    for (err, code) in [(plain(), dcBadValue), (foreign(), dcInternal)]:
      let d = readSegd(failing(shot, failAt, err))
      doAssert d.records.len == records and d.log.lastIsFatal(code), $failAt & " " & $d.log
      if records > 0: doAssert d.records[0].traces.len == traces
      let ix = buildIndex(failing(shot, failAt, err), skSegd)
      doAssert ix.entries.len == traces and ix.log.lastIsFatal(code), $failAt & " " & $ix.log

# ----------------------------------------------------------- tape images --

proc tapRecords(image: string): seq[(int, int)] =
  ## (position of the header word, data length) of each data record.
  var pos = 0
  while pos + 4 <= image.len:
    let n = int(uint8(image[pos])) or (int(uint8(image[pos + 1])) shl 8) or
      (int(uint8(image[pos + 2])) shl 16) or (int(uint8(image[pos + 3])) shl 24)
    if n == 0: pos += 4
    elif n == 0xFFFF_FFFF: break
    else:
      result.add (pos, n)
      pos += 4 + n + (n and 1) + 4

proc damaged(image: string, record: int, trailer: bool): string =
  ## `image` with a bit of the trailer word of data record `record` flipped,
  ## or with the "bad record" class set in its header word.
  result = image
  let (p, n) = tapRecords(image)[record]
  if trailer: result[p + 4 + n + (n and 1)] = char(uint8(image[p + 4 + n + (n and 1)]) xor 0x40)
  else: result[p + 3] = char(uint8(image[p + 3]) or 0x80)

block damaged_segy_tape_image:
  # The reviewer's case: a trailer word that does not match its header, in
  # the middle of the image. 4 of 10 traces were indexed and the log had one
  # error, no fatal entry.
  let d = readSegy(survey)
  let tap = tmp / "survey.tap"
  block:
    let sink = openTapeImageSink(tap)
    var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file))
    for t in d.traces: w.writeTrace(t)
    w.close()
    sink.close()
  let image = readFile(tap)
  let records = tapRecords(image)
  let headers = records.len - 200 # textual, binary and extended records
  for trailer in [true, false]:
    let path = tmp / "survey_damaged.tap"
    writeFile(path, damaged(image, headers + 120, trailer))
    let src = openTapeImageSource(path)
    let ix = buildIndex(src, skSegy)
    src.close()
    doAssert ix.log.lastIsFatal(dcTapeLayout), $ix.log
    # The damaged record is trace 120: the image gives no record it cannot frame.
    doAssert ix.entries.len == 120 and ix.log[ix.log.len - 1].loc.trace == 120
    # In the headers: nothing is indexed, and that is fatal too.
    writeFile(path, damaged(image, 1, trailer))
    let src2 = openTapeImageSource(path)
    let e = readSegy(src2)
    src2.close()
    doAssert e.traces.len == 0 and e.log.lastIsFatal(dcTapeLayout), $e.log

block damaged_segd_tape_image:
  let d = readSegd(shot)
  let tap = tmp / "shot.tap"
  block:
    let sink = openTapeImageSink(tap)
    doAssert writeSegd(sink, d).len == 0
    sink.close()
  let image = readFile(tap)
  let records = tapRecords(image)
  doAssert records.len >= 3
  for trailer in [true, false]:
    for record in [0, records.len div 2, records.len - 1]:
      let path = tmp / "shot_damaged.tap"
      writeFile(path, damaged(image, record, trailer))
      let src = openTapeImageSource(path)
      let ix = buildIndex(src, skSegd)
      src.close()
      doAssert ix.log.isFatal and ix.entries.len <= 5, $record & " " & $ix.log
      var layout = 0
      for x in ix.log:
        if x.code == dcTapeLayout:
          doAssert x.severity == sevFatal
          inc layout
      doAssert layout == 1, $record & " " & $ix.log

block demultiplexed_copy_that_stops_is_fatal:
  # A record the writer refuses ends the copy: the copy lacks every record
  # from there on, so the entry is fatal, not an error.
  var b = readBytes(shot)
  let t = int(readSegd(shot).records[0].traces[3].offset)
  b[t + 3] = 0x99 # the trace names channel set 99, which no descriptor has
  writeBytes(tmp / "shot_cs99.sgd", b)
  let log = demultiplexSegd(tmp / "shot_cs99.sgd", tmp / "shot_cs99_copy.sgd")
  doAssert log.has("which no descriptor has", sevFatal), $log
  doAssert getFileSize(tmp / "shot_cs99_copy.sgd") < b.len
  doAssert not demultiplexSegd(shot, tmp / "shot_copy.sgd").isFatal
  doAssert readBytes(tmp / "shot_copy.sgd") == readBytes(shot)

echo "tstopfatal: ok"
