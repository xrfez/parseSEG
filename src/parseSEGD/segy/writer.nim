## SEG-Y writer: emits a `SegyFile` and its traces to any `RecordSink`.
##
## Each SEG-Y record (tape label, textual header, binary header, each
## extended or trailer record, each trace) is written as one record, which is
## the unblocked tape layout; disk sinks simply concatenate them. A file read
## with `reader` and written back in its own byte order is byte-identical.
##
## Validation comes first: `openSegyWriter` checks the binary header and
## refuses spec-invalid output (raising `SegFormatError`) unless
## `lenient = true`, in which case problems are only logged.
##
## `byteOrder` chooses the output order (default: the file's). Header fields
## and samples are reordered; text blocks never are. Rev 2 additional trace
## headers are kept raw, so they can only be written in the order they were
## read until task 3.4 decodes them.

import ../common/[endians, errors, diagnostics]
import ../io/records
import ./[binheader, traceheader, samples, exttext, reader]

type
  SegyWriteOptions* = object
    byteOrder*: ByteOrder ## Output byte order; set it from the file to keep the input order.
    lenient*: bool        ## Log validation problems instead of refusing to write.

  SegyWriter* = object
    ## Writer state; create with `openSegyWriter`.
    sink: RecordSink
    file: SegyFile
    order: ByteOrder
    log*: DiagLog
    tracesWritten: int

func initSegyWriteOptions*(file: SegyFile, lenient = false): SegyWriteOptions =
  ## Options that keep `file`'s byte order.
  SegyWriteOptions(byteOrder: file.byteOrder, lenient: lenient)

proc openSegyWriter*(sink: RecordSink, file: SegyFile, opts: SegyWriteOptions): SegyWriter =
  ## Validates `file` and writes its tape label, textual, binary and extended
  ## textual headers. Raises `SegFormatError` if validation fails and
  ## `opts.lenient` is false; I/O errors propagate.
  result = SegyWriter(sink: sink, file: file, order: opts.byteOrder)
  let loc = Location(file: sink.name)
  let severity = if opts.lenient: sevWarning else: sevError
  file.binary.validate(result.log, severity, loc)
  if file.binary.segyMajor >= 2 and file.binary.numExtTextHeaders != 0 and
      not file.extended.hasEndText:
    result.log.report(severity, dcValidation,
      "Rev 2 extended textual headers must end with ((SEG:EndText))", loc = loc)
  if not opts.lenient and result.log.hasErrors:
    raiseFormat("refusing to write spec-invalid SEG-Y (" & $result.log.count(sevError) &
      " problems; see the writer log or set lenient)")
  if file.tapeLabel.len > 0:
    doAssert file.tapeLabel.len == TapeLabelSize, "a tape label is 128 bytes"
    sink.writeRecord(file.tapeLabel)
  var text = newSeq[byte](3200)
  file.text.encode(text)
  sink.writeRecord(text)
  var bin = newSeq[byte](BinaryHeaderSize)
  file.binary.encode(bin, opts.byteOrder)
  sink.writeRecord(bin)
  for i in countup(0, file.extended.data.len - 1, 3200):
    sink.writeRecord(file.extended.data.toOpenArray(i, i + 3199))

func reorderSamples(src: openArray[byte], width: int, srcOrder, dstOrder: ByteOrder): seq[byte] =
  # Converts samples between byte orders without decoding them.
  result = newSeq[byte](src.len)
  for i in countup(0, src.len - width, width):
    case width
    of 1: result[i] = src[i]
    of 2: putNum(result, i, getNum[uint16](src, i, srcOrder), dstOrder)
    of 4: putNum(result, i, getNum[uint32](src, i, srcOrder), dstOrder)
    of 8: putNum(result, i, getNum[uint64](src, i, srcOrder), dstOrder)
    else:
      # 3-byte samples: big <-> little only (pair-swapping is undefined).
      if srcOrder == dstOrder or srcOrder == boPairSwapped or dstOrder == boPairSwapped:
        if srcOrder != dstOrder:
          raiseFormat("3-byte samples cannot be pair-swapped")
        for j in 0..2: result[i+j] = src[i+j]
      else:
        for j in 0..2: result[i+j] = src[i+2-j]

proc writeTrace*(w: var SegyWriter, t: SegyTrace) =
  ## Writes one trace record. Raises `SegFormatError` if the trace cannot be
  ## expressed in the output byte order.
  let size = sampleSize(w.file.format)
  if t.samples.len != t.numSamples * size:
    raiseFormat("trace " & $t.index & " has " & $t.samples.len & " sample bytes, " &
      $(t.numSamples * size) & " expected")
  var rec = newSeq[byte](TraceHeaderSize)
  t.header.encode(rec, w.order)
  if t.extraHeaders.len > 0:
    if w.order != w.file.byteOrder:
      raiseFormat("additional trace headers cannot be byte-reordered yet (task 3.4)")
    rec.add t.extraHeaders
  if w.order == w.file.byteOrder:
    rec.add t.samples
  else:
    rec.add reorderSamples(t.samples, size, w.file.byteOrder, w.order)
  w.sink.writeRecord(rec)
  inc w.tracesWritten

proc close*(w: var SegyWriter, endOfData = true) =
  ## Writes the data trailer records, then a tape mark (two when `endOfData`,
  ## marking the end of recorded data). Disk sinks ignore tape marks. The sink
  ## stays open.
  for i in countup(0, w.file.trailer.data.len - 1, 3200):
    w.sink.writeRecord(w.file.trailer.data.toOpenArray(i, i + 3199))
  w.sink.writeTapeMark(if endOfData: 2 else: 1)

func tracesWritten*(w: SegyWriter): int {.inline.} = w.tracesWritten
