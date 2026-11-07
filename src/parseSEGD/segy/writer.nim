## SEG-Y writer: emits a `SegyFile` and its traces to any `RecordSink`.
##
## Each SEG-Y record (tape label, textual header, binary header, each
## extended or trailer record, each trace) is written as one record, which is
## the unblocked tape layout; disk sinks simply concatenate them. A file read
## with `reader` and written back in its own byte order is byte-identical.
##
## Validation comes first, in two classes:
## - output that a reader could not decode correctly (counts that disagree
##   with the records, sample counts that disagree with the data, ...) is
##   refused with `SegFormatError` unless `lenient`;
## - values the spec forbids but readers can cope with (little-endian Rev 0/1,
##   a zero sample interval, an undefined revision, a missing EndText, ...) are
##   warnings when they are unchanged from what was read, so any file can be
##   written back as it came in, and errors when they are new or edited.
## With `lenient`, every problem is a warning in `log`.
##
## `byteOrder` chooses the output order (default: the file's). Header fields
## and samples are reordered; text blocks never are. Rev 2 additional trace
## headers are kept raw, so they can only be written in the order they were
## read until task 3.4 decodes them.

import ../common/[endians, errors, diagnostics, ebcdic]
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
    rev: SegyRevision
    order: ByteOrder
    lenient: bool
    wasRead: bool  ## The file came from the reader (not built in memory).
    log*: DiagLog
    tracesWritten: int

func initSegyWriteOptions*(file: SegyFile, lenient = false): SegyWriteOptions =
  ## Options that keep `file`'s byte order.
  SegyWriteOptions(byteOrder: file.byteOrder, lenient: lenient)

proc problem(w: var SegyWriter, msg: string, field = "", trace = -1, asRead = false) =
  # A validation failure: an error that stops the write, or a logged warning
  # with `lenient` or when the offending content is unchanged from the read.
  let loc = Location(file: w.sink.name, record: 0, trace: trace, field: field)
  if w.lenient or asRead:
    w.log.report(sevWarning, dcValidation, msg, loc = loc)
  else:
    w.log.report(sevError, dcValidation, msg, loc = loc)
    raiseFormat("refusing to write spec-invalid SEG-Y: " & msg)

func fieldSize(field: string): int =
  # Width of a binary header field named "binary.<name>" by `validate`.
  result = 2
  for spec in binaryHeaderFields:
    if "binary." & spec.name == field: result = spec.size

proc checkFile(w: var SegyWriter) =
  let f = w.file
  let b = f.binary
  let rev = w.rev
  let loc = Location(file: w.sink.name)
  let extAsRead = f.isExtendedAsRead
  # Readable but spec-invalid values: a warning when the field's bytes are
  # unchanged from the read, else an error.
  let headerOffset = int64(3200 + f.tapeLabel.len)
  var found: DiagLog
  b.validate(found, sevError, loc, headerOffset)
  var cur = newSeq[byte](BinaryHeaderSize)
  b.encode(cur, f.byteOrder)
  var newProblems = 0
  for d in found:
    var e = d
    let rel = int(d.offset - headerOffset)
    let size = fieldSize(d.loc.field)
    let unchanged = w.wasRead and rel >= 0 and rel + size <= BinaryHeaderSize and
      cur[rel ..< rel + size] == f.binaryAsRead[rel ..< rel + size]
    if w.lenient or unchanged:
      e.severity = sevWarning
    else:
      inc newProblems
    w.log.add e
  if newProblems > 0:
    raiseFormat("refusing to write spec-invalid SEG-Y (" & $newProblems &
      " new or edited header values; see the writer log or set lenient)")
  # Unreadable output.
  if not f.extended.isComplete or not f.trailer.isComplete:
    raiseFormat("the extended header or trailer was only indexed, not held in memory " &
      "(retention limit); read the file with a larger maxRetained to rewrite it")
  if not f.formatKnown:
    w.problem("format code " & $b.formatCode & " is undefined, so traces cannot be written",
      "binary.formatCode")
  if not (b.segyMajor == 2 and b.segyMinor == 0) and b.maxAddlTraceHeaders > high(uint16):
    w.problem("additional trace header count " & $b.maxAddlTraceHeaders &
      " does not fit in 16 bits", "binary.maxAddlTraceHeaders")
  if rev.major < 2:
    if w.order == boPairSwapped:
      w.problem("pair-swapped output needs Rev 2 (only its byte-order marker declares it)",
        "binary.byteOrderMarker")
    elif w.order == boLittle:
      w.problem("little-endian output is not valid before Rev 2; readers must infer the " &
        "byte order", "binary.byteOrderMarker", asRead = w.wasRead and f.byteOrder == boLittle)
  let n = f.extended.recordCount
  let count = if rev.major == 0: 0 else: int(b.numExtTextHeaders)
  if rev.major == 0 and n > 0:
    w.problem("Rev 0 files have no extended textual headers, but " & $n & " are present",
      "extended")
  elif count > 0 and count != n:
    w.problem("the binary header declares " & $count & " extended records, " & $n &
      " are present", "binary.numExtTextHeaders")
  elif count == 0 and n > 0:
    w.problem("the binary header declares no extended records, " & $n & " are present",
      "binary.numExtTextHeaders")
  elif count == -1 and not f.extended.hasEndText:
    w.problem("a variable extended record count (-1) needs a final ((SEG:EndText)) record",
      "extended", asRead = extAsRead)
  elif rev.major >= 2 and count > 0 and not f.extended.hasEndText:
    w.problem("Rev 2 extended textual headers must end with ((SEG:EndText))", "extended",
      asRead = extAsRead)
  if rev.major >= 2 and b.firstTraceOffset != 0 and
      b.firstTraceOffset != uint64(3600 + f.tapeLabel.len + n * 3200):
    w.problem("the first trace offset " & $b.firstTraceOffset & " does not match the " &
      $n & " extended records", "binary.firstTraceOffset")
  let t = f.trailer.recordCount
  if rev.major < 2 and t > 0:
    w.problem("data trailers need Rev 2", "trailer")
  elif rev.major >= 2 and b.numTrailerRecords >= 0 and int(b.numTrailerRecords) != t:
    w.problem("the binary header declares " & $b.numTrailerRecords & " trailer records, " &
      $t & " are present", "binary.numTrailerRecords")

proc openSegyWriter*(sink: RecordSink, file: SegyFile, opts: SegyWriteOptions): SegyWriter =
  ## Validates `file` and writes its tape label, textual, binary and extended
  ## textual headers. Raises `SegFormatError` if validation fails and
  ## `opts.lenient` is false; I/O errors propagate.
  result = SegyWriter(sink: sink, file: file, order: opts.byteOrder, lenient: opts.lenient,
    rev: file.binary.rulesRevision, wasRead: file.binaryAsRead.len == BinaryHeaderSize)
  result.checkFile()
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

func isExt1Name(b: openArray[byte]): bool =
  const ascii = "SEG00001"
  var a, e = true
  for i, c in ascii:
    if b[232 + i] != byte(c): a = false
    if b[232 + i] != latin1ToEbcdic[uint8(c)]: e = false
  a or e

proc checkTrace(w: var SegyWriter, t: SegyTrace) =
  # The reader must recover exactly this trace from what is written.
  let b = w.file.binary
  let order = w.file.byteOrder # extra headers are raw, in the file's order
  var extNs = 0'u32
  if w.rev.major >= 2 and b.maxAddlTraceHeaders > 0:
    if t.extraHeaders.len == 0 or t.extraHeaders.len mod TraceHeaderSize != 0:
      w.problem("the binary header announces additional trace headers; this trace needs " &
        "whole 240-byte headers, it has " & $t.extraHeaders.len & " bytes",
        "trace.extraHeaders", t.index)
    else:
      if not isExt1Name(t.extraHeaders):
        w.problem("the first additional trace header must be named SEG00001",
          "ext1.headerName", t.index, asRead = w.wasRead)
      let declared = getNum[uint16](t.extraHeaders, 156, order)
      let k = if declared != 0: int(declared) else: int(b.maxAddlTraceHeaders)
      if k * TraceHeaderSize != t.extraHeaders.len:
        w.problem("the trace declares " & $k & " additional headers but carries " &
          $(t.extraHeaders.len div TraceHeaderSize), "ext1.numAddlTraceHeaders", t.index)
      extNs = getNum[uint32](t.extraHeaders, 136, order)
  elif t.extraHeaders.len > 0:
    w.problem("additional trace headers need Rev 2 and a non-zero binary header count " &
      "(3507)", "trace.extraHeaders", t.index)
  if w.rev.major >= 1 and b.fixedLengthTraces == 1:
    if uint32(t.numSamples) != b.effectiveSamplesPerTrace:
      w.problem("fixed-length file with " & $b.effectiveSamplesPerTrace &
        " samples per trace, but this trace has " & $t.numSamples, "trace.numSamples", t.index)
  else:
    let declared = if extNs != 0: int(extNs) else: int(t.header.numSamples)
    if declared != t.numSamples:
      w.problem("the trace header declares " & $declared & " samples, the trace has " &
        $t.numSamples, "trace.numSamples", t.index)
  let size = sampleSize(w.file.format)
  if t.samples.len != t.numSamples * size:
    w.problem("the trace has " & $t.samples.len & " sample bytes, " &
      $(t.numSamples * size) & " expected", "trace.samples", t.index)

proc writeTrace*(w: var SegyWriter, t: SegyTrace) =
  ## Validates and writes one trace record. Raises `SegFormatError` if the
  ## trace is inconsistent with the file headers (unless lenient) or cannot be
  ## expressed in the output byte order.
  w.checkTrace(t)
  var rec = newSeq[byte](TraceHeaderSize)
  t.header.encode(rec, w.order)
  if t.extraHeaders.len > 0:
    if w.order != w.file.byteOrder:
      raiseFormat("additional trace headers cannot be byte-reordered yet (task 3.4)")
    rec.add t.extraHeaders
  if w.order == w.file.byteOrder:
    rec.add t.samples
  else:
    rec.add reorderSamples(t.samples, sampleSize(w.file.format), w.file.byteOrder, w.order)
  w.sink.writeRecord(rec)
  inc w.tracesWritten

proc close*(w: var SegyWriter, endOfData = true) =
  ## Writes the data trailer records, then a tape mark (two when `endOfData`,
  ## marking the end of recorded data). Disk sinks ignore tape marks. The sink
  ## stays open. Raises `SegFormatError` (unless lenient) when the number of
  ## traces written differs from a declared Rev 2 trace count.
  let declared = w.file.binary.numTraces
  if w.rev.major >= 2 and declared != 0 and declared != uint64(w.tracesWritten):
    w.problem("the binary header declares " & $declared & " traces, " & $w.tracesWritten &
      " were written", "binary.numTraces")
  for i in countup(0, w.file.trailer.data.len - 1, 3200):
    w.sink.writeRecord(w.file.trailer.data.toOpenArray(i, i + 3199))
  w.sink.writeTapeMark(if endOfData: 2 else: 1)

func tracesWritten*(w: SegyWriter): int {.inline.} = w.tracesWritten
