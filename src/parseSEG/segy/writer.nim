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
## `byteOrder` chooses the output order (default: the file's). Header fields,
## Trace Header Extension 1 and samples are reordered; text blocks never are.
## Proprietary trace headers have no known layout: changing their byte order
## is refused unless lenient (they are then copied unchanged).

import ../common/[endians, errors, diagnostics]
import ../io/records
import ./[textheader, binheader, traceheader, samples, exttext, reader]

type
  SegyWriteOptions* = object
    ## Output settings of `openSegyWriter`; `initSegyWriteOptions` keeps the
    ## file's byte order.
    byteOrder*: ByteOrder ## Output byte order; set it from the file to keep the input order.
    lenient*: bool        ## Log validation problems instead of refusing to write.

  SegyWriter* = object
    ## Writer state; create with `openSegyWriter`.
    sink: RecordSink
    file: SegyFile
    rev: SegyRevision
    order: ByteOrder
    lenient: bool
    wasRead: bool        ## The file came from the reader (not built in memory).
    cur: seq[byte]       ## The binary header as it will be written, in the file's byte order.
    lastFlagged: bool    ## A trace flagged "last in file" was written.
    log*: DiagLog
    tracesWritten: int
    rec: seq[byte]       ## Reused trace record buffer.

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

func unchanged(w: SegyWriter, ranges: openArray[(int, int)]): bool =
  # True when every (spec byte, size) range of the binary header is as read.
  result = w.wasRead
  for (specByte, size) in ranges:
    let rel = specByte - 3201
    if result and w.cur[rel ..< rel + size] != w.file.binaryAsRead[rel ..< rel + size]:
      result = false

const RevisionBytes = (3501, 2)

func dependencies(field: string): seq[(int, int)] =
  # The binary header bytes a `validate` finding depends on: its own field,
  # the revision (every rule is revision-specific) and, for values with a
  # Rev 2 extended counterpart, that field too.
  result = @[RevisionBytes]
  case field
  of "binary.sampleInterval": result.add [(3217, 2), (3273, 8)]
  of "binary.samplesPerTrace": result.add [(3221, 2), (3269, 4)]
  else:
    for spec in binaryHeaderFields:
      if "binary." & spec.name == field: result.add (spec.specByte, spec.size)
    if field == "binary.maxAddlTraceHeaders": result.add (3507, 4)

proc checkFile(w: var SegyWriter) =
  template f: untyped = w.file
  template b: untyped = w.file.binary
  let rev = w.rev
  let loc = Location(file: w.sink.name)
  if f.tapeLabel.len notin [0, TapeLabelSize]:
    # Not even `lenient` can write this: the label's length is the layout.
    w.log.report(sevError, dcValidation, "a tape label is " & $TapeLabelSize & " bytes, not " &
      $f.tapeLabel.len, loc = Location(file: w.sink.name, field: "tapeLabel"))
    raiseFormat("refusing to write a " & $f.tapeLabel.len & "-byte tape label")
  let extAsRead = f.isExtendedAsRead
  # Readable but spec-invalid values: a warning when every byte the finding
  # depends on is as read, else an error.
  let headerOffset = int64(TextHeaderSize + f.tapeLabel.len)
  var found: DiagLog
  b.validate(found, sevError, loc, headerOffset)
  var newProblems = 0
  for d in found:
    var e = d
    if w.lenient or w.unchanged(dependencies(d.loc.field)):
      e.severity = sevWarning
    else:
      inc newProblems
    w.log.add e
  if newProblems > 0:
    raiseFormat("refusing to write spec-invalid SEG-Y (" & $newProblems &
      " new or edited header values; see the writer log or set lenient)")
  # Output a reader would misdecode, unless it is exactly what was read
  # (identical bytes read back identically).
  if not f.extended.isComplete or not f.trailer.isComplete:
    raiseFormat("the extended header or trailer was only indexed, not held in memory " &
      "(retention limit); read the file with a larger maxRetained to rewrite it")
  if f.format.isNone or toSampleFormat(int(b.formatCode)) != f.format:
    w.problem("the binary header format code " & $b.formatCode & " does not match the " &
      "file's sample format (set both `binary.formatCode` and `format`)", "binary.formatCode")
  if not (b.segyMajor == 2 and b.segyMinor == 0) and b.maxAddlTraceHeaders > high(uint16):
    w.problem("additional trace header count " & $b.maxAddlTraceHeaders &
      " does not fit in 16 bits", "binary.maxAddlTraceHeaders")
  if rev.major < 2:
    if w.order == boPairSwapped:
      w.problem("pair-swapped output needs Rev 2 (only its byte-order marker declares it)",
        "binary.byteOrderMarker")
    elif w.order == boLittle:
      w.problem("little-endian output is not valid before Rev 2; readers must infer the " &
        "byte order", "binary.byteOrderMarker",
        asRead = f.byteOrder == boLittle and w.unchanged([RevisionBytes]))
  let n = f.extended.recordCount
  let count = if rev.major == 0: 0 else: int(b.numExtTextHeaders)
  let countAsRead = extAsRead and w.unchanged([RevisionBytes, (3505, 2), (3521, 8)])
  if rev.major == 0 and n > 0:
    w.problem("Rev 0 files have no extended textual headers, but " & $n & " are present",
      "extended")
  elif count > 0 and count != n:
    w.problem("the binary header declares " & $count & " extended records, " & $n &
      " are present", "binary.numExtTextHeaders", asRead = countAsRead)
  elif count == 0 and n > 0:
    w.problem("the binary header declares no extended records, " & $n & " are present",
      "binary.numExtTextHeaders", asRead = countAsRead)
  elif count == -1 and not f.extended.hasEndText:
    w.problem("a variable extended record count (-1) needs a final ((SEG:EndText)) record",
      "extended", asRead = countAsRead)
  elif SegyRevision(major: 2, minor: 1) <= rev and count > 0 and not f.extended.hasEndText:
    w.problem("Rev 2.1 extended textual headers must end with ((SEG:EndText))", "extended",
      asRead = countAsRead)
  if count != 0:
    for s in f.extended.stanzas:
      if s.isEndText and s.headerStart div TextHeaderSize < n - 1:
        w.problem("((SEG:EndText)) must be the last extended record, but record " &
          $(s.headerStart div TextHeaderSize) & " of " & $n & " is one", "extended",
          asRead = countAsRead)
  if rev.major >= 2 and b.firstTraceOffset != 0 and
      b.firstTraceOffset !=
        uint64(TextHeaderSize + BinaryHeaderSize + f.tapeLabel.len + n * TextHeaderSize):
    w.problem("the first trace offset " & $b.firstTraceOffset & " does not match the " &
      $n & " extended records", "binary.firstTraceOffset", asRead = countAsRead)
  let t = f.trailer.recordCount
  let trailerAsRead = f.isTrailerAsRead and w.unchanged([RevisionBytes, (3529, 4)])
  if rev.major < 2 and t > 0:
    w.problem("data trailers need Rev 2", "trailer")
  elif rev.major >= 2 and b.numTrailerRecords >= 0 and int(b.numTrailerRecords) != t:
    w.problem("the binary header declares " & $b.numTrailerRecords & " trailer records, " &
      $t & " are present", "binary.numTrailerRecords", asRead = trailerAsRead)

proc openSegyWriter*(sink: RecordSink, file: SegyFile, opts: SegyWriteOptions): SegyWriter =
  ## Validates `file` and writes its tape label, textual, binary and extended
  ## textual headers. Raises `SegFormatError` if validation fails and
  ## `opts.lenient` is false; I/O errors propagate.
  result = SegyWriter(sink: sink, file: file, order: opts.byteOrder, lenient: opts.lenient,
    rev: file.binary.rulesRevision, wasRead: file.binaryAsRead.len == BinaryHeaderSize,
    cur: newSeq[byte](BinaryHeaderSize))
  file.binary.encode(result.cur, file.byteOrder)
  result.checkFile()
  if file.tapeLabel.len > 0:
    sink.writeRecord(file.tapeLabel)
  sink.writeRecord(file.text.data)
  var bin = newSeq[byte](BinaryHeaderSize)
  file.binary.encode(bin, opts.byteOrder)
  sink.writeRecord(bin)
  for i in countup(0, file.extended.data.len - 1, TextHeaderSize):
    sink.writeRecord(file.extended.data.toOpenArray(i, i + TextHeaderSize - 1))

func reorderSamples(src: openArray[byte], width: int, srcOrder, dstOrder: ByteOrder,
    result: var openArray[byte]) =
  # Converts samples between byte orders without decoding them into
  # `result`, which has `src.len` bytes.
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

proc checkTrace(w: var SegyWriter, t: SegyTrace) =
  # The reader must recover exactly this trace from what is written.
  template b: untyped = w.file.binary
  var extNs = 0'u32
  if w.rev.major >= 2 and b.maxAddlTraceHeaders > 0:
    if not t.hasExt1:
      w.problem("the binary header announces additional trace headers, but this trace " &
        "has no Trace Header Extension 1", "trace.ext1", t.index)
    else:
      if t.ext1.headerNameText != "SEG00001":
        w.problem("the first additional trace header must be named SEG00001",
          "ext1.headerName", t.index, asRead = w.wasRead)
      if t.proprietary.len mod TraceHeaderSize != 0:
        w.problem("proprietary trace headers must be whole 240-byte blocks, this trace has " &
          $t.proprietary.len & " bytes", "trace.proprietary", t.index)
      let declared = t.ext1.numAddlTraceHeaders
      let k = if declared != 0: int(declared) else: int(b.maxAddlTraceHeaders)
      let have = 1 + t.proprietary.len div TraceHeaderSize
      if k != have:
        w.problem("the trace declares " & $k & " additional headers but carries " & $have,
          "ext1.numAddlTraceHeaders", t.index)
      extNs = t.ext1.extNumSamples
  elif t.hasExt1 or t.proprietary.len > 0:
    w.problem("additional trace headers need Rev 2 and a non-zero binary header count " &
      "(3507)", "trace.ext1", t.index)
  if w.rev.major >= 1 and b.fixedLengthTraces == 1:
    if uint32(t.numSamples) != b.effectiveSamplesPerTrace:
      w.problem("fixed-length file with " & $b.effectiveSamplesPerTrace &
        " samples per trace, but this trace has " & $t.numSamples, "trace.numSamples", t.index)
  else:
    let declared = if extNs != 0: int(extNs) else: int(t.header.numSamples)
    if declared != t.numSamples:
      w.problem("the trace header declares " & $declared & " samples, the trace has " &
        $t.numSamples, "trace.numSamples", t.index)
  if w.file.format.isSome:
    let size = sampleSize(w.file.format.get)
    if t.samples.len != t.numSamples * size:
      w.problem("the trace has " & $t.samples.len & " sample bytes, " &
        $(t.numSamples * size) & " expected", "trace.samples", t.index)
  if t.proprietary.len > 0 and w.order != w.file.byteOrder:
    w.problem("proprietary trace headers have no known layout, so they cannot be converted " &
      "to " & $w.order & " byte order (they are copied unchanged)", "trace.proprietary", t.index)

proc writeTrace*(w: var SegyWriter, t: SegyTrace) =
  ## Validates and writes one trace record. Raises `SegFormatError` if the
  ## trace is inconsistent with the file headers (unless lenient) or cannot be
  ## expressed in the output byte order.
  w.checkTrace(t)
  if w.lastFlagged:
    w.problem("a trace follows one flagged last in file (Ext1 bytes 159-160); readers " &
      "stop at the flag", "ext1.lastTraceFlag", t.index)
  if t.hasExt1 and (t.ext1.lastTraceFlag and LastInFile) != 0: w.lastFlagged = true
  let headers = TraceHeaderSize * (if t.hasExt1: 2 else: 1) + t.proprietary.len
  w.rec.setLen headers + t.samples.len
  t.header.encode(w.rec, w.order)
  if t.hasExt1:
    t.ext1.encode(w.rec.toOpenArray(TraceHeaderSize, 2 * TraceHeaderSize - 1), w.order)
  if t.proprietary.len > 0:
    copyMem(addr w.rec[headers - t.proprietary.len], addr t.proprietary[0], t.proprietary.len)
  if t.samples.len == 0:
    discard
  elif w.order == w.file.byteOrder:
    copyMem(addr w.rec[headers], addr t.samples[0], t.samples.len)
  elif w.file.format.isNone:
    raiseFormat("samples of an undefined format cannot be converted to " & $w.order &
      " byte order")
  else:
    let width = sampleSize(w.file.format.get)
    reorderSamples(t.samples, width, w.file.byteOrder, w.order,
      w.rec.toOpenArray(headers, w.rec.high))
    # A lenient trace's partial last sample is written as zeros (`w.rec` is
    # reused: it would hold the previous trace's bytes).
    let tail = t.samples.len mod width
    if tail > 0: zeroMem(addr w.rec[w.rec.len - tail], tail)
  w.sink.writeRecord(w.rec)
  inc w.tracesWritten

proc close*(w: var SegyWriter, endOfData = true) =
  ## Writes the data trailer records, then a tape mark (two when `endOfData`,
  ## marking the end of recorded data). Disk sinks ignore tape marks. The sink
  ## stays open. Raises `SegFormatError` (unless lenient) when the number of
  ## traces written differs from a declared Rev 2 trace count.
  let declared = w.file.binary.numTraces
  if w.rev.major >= 2 and declared != 0 and declared != uint64(w.tracesWritten):
    w.problem("the binary header declares " & $declared & " traces, " & $w.tracesWritten &
      " were written", "binary.numTraces", asRead = w.unchanged([RevisionBytes, (3513, 8)]))
  for i in countup(0, w.file.trailer.data.len - 1, TextHeaderSize):
    w.sink.writeRecord(w.file.trailer.data.toOpenArray(i, i + TextHeaderSize - 1))
  w.sink.writeTapeMark(if endOfData: 2 else: 1)

func tracesWritten*(w: SegyWriter): int {.inline.} =
  ## Traces written so far.
  w.tracesWritten
