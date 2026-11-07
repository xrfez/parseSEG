## SEG-Y reader: a streaming walk over any `RecordSource` (disk file, tape
## image, tape device, memory), with every problem logged as a diagnostic.
##
## ```nim
## var r = openSegy(openDiskSource("line.sgy"))
## var t: SegyTrace
## while r.readTrace(t):
##   echo t.header.fieldRecord, " ", t.numSamples
## echo r.log.toNif
## ```
##
## The reader never raises on format problems. Header values that violate
## the spec are kept as read and logged; the read stops early only when it
## physically cannot go on (truncation, I/O failure, unknown trace length),
## which is logged as `fatal`.
##
## Traces keep their raw sample bytes, so a read/write round trip is
## byte-identical; decode them into a Tensor with `decodeInto`. `readSegy` is
## a convenience that loads a whole (small) file. Large files should be
## walked trace by trace; the indexed, memory-mapped access comes in task 6.1.
##
## Spec rules applied (notes `segy_rev1.md` §6, `segy_rev2_1.md` §6):
## - optional 128-byte tape label before the textual header (a separate tape
##   record, or copied in front of a disk file);
## - byte order from the Rev 2 marker, else inferred (logged as info);
## - Rev 0 ignores bytes 3503-3506; Rev 2 `firstTraceOffset` overrides the
##   extended header count;
## - fixed-length flag 1: every trace has the file's sample count;
## - Rev 2 additional trace headers (count from Ext1 bytes 157-158, else
##   binary 3507), Ext1 sample count and interval overrides;
## - traces end at the declared trace count, at an Ext1 "last trace in file"
##   flag, at a trailer record, at a tape mark or at the end of data.

import ../common/[endians, errors, diagnostics]
import ../io/[records, diskio]
import ../model/tensors
import ./[textheader, binheader, traceheader, samples, exttext]
export textheader, binheader, traceheader, samples, exttext, diagnostics, endians, tensors

const TapeLabelSize* = 128 ## Bytes in a SEG-Y tape label.

type
  SegyFile* = object
    ## The file-level part of a SEG-Y file.
    tapeLabel*: seq[byte]           ## Raw 128-byte label, or empty.
    text*: SegyTextHeader
    binary*: SegyBinaryHeader
    extended*: ExtendedTextHeader   ## Extended textual header records.
    trailer*: ExtendedTextHeader    ## Rev 2 data trailer records.
    byteOrder*: ByteOrder           ## Byte order of binary fields and samples.
    byteOrderDeclared*: bool        ## The Rev 2 marker declared `byteOrder`.
    format*: SampleFormat           ## Valid when `formatKnown`.
    formatKnown*: bool
    firstTraceOffset*: int64        ## Medium offset of the first trace.

  SegyTrace* = object
    ## One trace record.
    header*: SegyTraceHeader
    extraHeaders*: seq[byte]
      ## Raw additional 240-byte headers (Rev 2: Ext1 first, then proprietary),
      ## in the file's byte order.
    numSamples*: int                ## Samples in `samples`.
    sampleInterval*: float64        ## Effective sample interval (µs for time data).
    samples*: seq[byte]             ## Raw sample bytes in the file's byte order.
    index*: int                     ## 0-based trace index in the file.
    offset*: int64                  ## Medium offset of the trace header.

  SegyReader* = object
    ## Streaming reader state. `file` is filled by `openSegy`.
    file*: SegyFile
    log*: DiagLog
    cursor: RecordCursor
    name: string
    tracesRead: int
    lastTraceSeen: bool
    done: bool

func isTraceHeaderTrailer(b: openArray[byte]): bool {.inline.} =
  (b[0] == 0x28 and b[1] == 0x28) or (b[0] == 0x4D and b[1] == 0x4D)

func looksLikeTapeLabel(b: openArray[byte]): bool =
  # Storage unit sequence number (digits or blanks) and "SY" in bytes 5-6;
  # a textual header starts with 'C' instead.
  b[0] in {0x20'u8, 0x30'u8..0x39'u8} and b[4] == 0x53 and b[5] == 0x59

func loc(r: SegyReader, trace = -1, field = ""): Location {.inline.} =
  Location(file: r.name, record: 0, trace: trace, field: field)

proc readBlock(r: var SegyReader, n: int): seq[byte] =
  result = newSeq[byte](n)
  r.cursor.readExactly(result)

proc readFileHeaders(r: var SegyReader) =
  var f = SegyFile()
  var head = r.readBlock(TapeLabelSize)
  var textBytes: seq[byte]
  if looksLikeTapeLabel(head):
    f.tapeLabel = head
    textBytes = r.readBlock(TextHeaderSize)
  else:
    textBytes = head
    textBytes.add r.readBlock(TextHeaderSize - TapeLabelSize)
  let labelLen = f.tapeLabel.len
  f.text = decodeTextHeader(textBytes)

  let binOffset = r.cursor.offset
  let bin = r.readBlock(BinaryHeaderSize)
  let det = detectByteOrder(bin)
  f.byteOrder = det.order
  f.byteOrderDeclared = det.fromMarker
  f.binary = decodeBinaryHeader(bin, det.order)
  let rev = f.binary.revision
  if not det.plausible:
    r.log.report(sevWarning, dcByteOrder, "no byte order gives a defined format code; " &
      "reading as " & $det.order, binOffset + (3225 - 3201), r.loc(field = "binary.formatCode"))
  elif not det.fromMarker and det.order != boBig:
    r.log.report(sevInfo, dcByteOrder, "byte order inferred as " & $det.order &
      " (no byte-order marker)", binOffset + (3297 - 3201), r.loc(field = "binary.byteOrderMarker"))
  var l = r.loc()
  f.binary.validate(r.log, sevWarning, l)

  var fmt: SampleFormat
  if toSampleFormat(int(f.binary.formatCode), fmt):
    f.format = fmt
    f.formatKnown = true
    if f.byteOrder == boPairSwapped and sampleSize(fmt) == 3:
      r.log.report(sevError, dcUnsupportedFormat, "3-byte samples cannot be pair-swapped; " &
        "samples are kept raw", binOffset + (3225 - 3201), r.loc(field = "binary.formatCode"))
  else:
    r.log.report(sevFatal, dcUnsupportedFormat, "format code " & $f.binary.formatCode &
      " is undefined, so trace lengths are unknown", binOffset + (3225 - 3201),
      r.loc(field = "binary.formatCode"))

  # Extended textual header records.
  var count = if rev.major == 0: 0 else: int(f.binary.numExtTextHeaders)
  if rev.major >= 2 and f.binary.firstTraceOffset != 0:
    let n = int64(f.binary.firstTraceOffset) - 3600 - labelLen
    if n >= 0 and n mod TextHeaderSize == 0:
      let fromOffset = int(n div TextHeaderSize)
      if count > 0 and count != fromOffset:
        r.log.report(sevWarning, dcInconsistent, "first trace offset implies " & $fromOffset &
          " extended records, the count says " & $count & "; using the offset",
          binOffset + (3521 - 3201), r.loc(field = "binary.firstTraceOffset"))
      count = fromOffset
    else:
      r.log.report(sevWarning, dcBadValue, "first trace offset " &
        $f.binary.firstTraceOffset & " is not 3600 + a multiple of 3200; ignored",
        binOffset + (3521 - 3201), r.loc(field = "binary.firstTraceOffset"))
  if count < -1: count = 0 # already reported by validate
  f.extended = initExtendedTextHeader(rev1Lines = rev.major < 2)
  f.trailer = initExtendedTextHeader(rev1Lines = rev.major < 2)
  while f.extended.needsMore(count):
    f.extended.add r.readBlock(TextHeaderSize)
  if rev.major >= 2 and count > 0 and not f.extended.hasEndText:
    r.log.report(sevWarning, dcBadValue, "the last extended textual record is not " &
      "((SEG:EndText)) (required since the Rev 2.1 clarification)",
      r.cursor.offset - TextHeaderSize, r.loc(field = "extended"))
  f.firstTraceOffset = r.cursor.offset
  r.file = f

proc openSegy*(src: RecordSource): SegyReader =
  ## Reads the file headers from `src`, positioned at the start of a SEG-Y
  ## file. Check `log.isFatal` for a file whose traces cannot be read.
  result = SegyReader(cursor: initRecordCursor(src), name: src.name)
  if not result.log.tryRecord(result.loc(), result.readFileHeaders()):
    result.done = true
  if result.log.isFatal: result.done = true

proc readTrailer(r: var SegyReader, first: seq[byte]) =
  # Reads the data trailer, `first` being its first record when already read.
  var expected = int(r.file.binary.numTrailerRecords)
  if first.len > 0:
    r.file.trailer.add first
  while (expected < 0 or r.file.trailer.recordCount < expected) and
      r.cursor.stoppedAt == rkData:
    r.file.trailer.add r.readBlock(TextHeaderSize)
  if expected > 0 and r.file.trailer.recordCount < expected:
    r.log.report(sevWarning, dcTruncated, "expected " & $expected & " trailer records, found " &
      $r.file.trailer.recordCount, r.cursor.offset, r.loc(field = "trailer"))

proc checkEnd(r: var SegyReader) =
  # Called once the traces have ended: checks the declared counts.
  let b = r.file.binary
  if b.segyMajor >= 2:
    if b.numTraces != 0 and uint64(r.tracesRead) < b.numTraces:
      r.log.report(sevWarning, dcInconsistent, "the binary header declares " & $b.numTraces &
        " traces, the file has " & $r.tracesRead, r.cursor.offset, r.loc(field = "binary.numTraces"))
    if b.numTrailerRecords > 0 and r.file.trailer.recordCount == 0:
      r.log.report(sevWarning, dcTruncated, "the binary header declares " &
        $b.numTrailerRecords & " trailer records, the file has none", r.cursor.offset,
        r.loc(field = "trailer"))
  if r.cursor.stoppedAt == rkData:
    r.log.report(sevWarning, dcInconsistent, "data follows the last trace", r.cursor.offset,
      r.loc())

proc readTraceBody(r: var SegyReader, t: var SegyTrace): bool =
  template f: untyped = r.file
  let order = f.byteOrder
  let rev = f.binary.revision
  t = SegyTrace(index: r.tracesRead, offset: r.cursor.offset)
  let hdr = r.readBlock(TraceHeaderSize)
  if f.binary.numTrailerRecords != 0 and rev.major >= 2 and isTraceHeaderTrailer(hdr):
    var rec = hdr
    rec.add r.readBlock(TextHeaderSize - TraceHeaderSize)
    r.readTrailer(rec)
    return false
  t.header = decodeTraceHeader(hdr, order)

  # Rev 2 additional trace headers; Ext1 comes first.
  var extNs = 0'u32
  var extDt = 0.0
  if rev.major >= 2 and f.binary.maxAddlTraceHeaders > 0:
    t.extraHeaders = r.readBlock(TraceHeaderSize)
    let declared = getNum[uint16](t.extraHeaders, 156, order)
    let k = if declared != 0: int(declared) else: int(f.binary.maxAddlTraceHeaders)
    if k > 1:
      t.extraHeaders.add r.readBlock((k - 1) * TraceHeaderSize)
    extNs = getNum[uint32](t.extraHeaders, 136, order)
    extDt = getNum[float64](t.extraHeaders, 144, order)
    if (getNum[uint16](t.extraHeaders, 158, order) and 4) != 0:
      r.lastTraceSeen = true

  let traceNs = if extNs != 0: int(extNs) else: int(t.header.numSamples)
  let traceDt = if extDt != 0: extDt else: float64(t.header.sampleInterval)
  if rev.major >= 1 and f.binary.fixedLengthTraces == 1:
    t.numSamples = int(f.binary.effectiveSamplesPerTrace)
    t.sampleInterval = f.binary.effectiveSampleInterval
    if rev.major < 2 and (traceNs != t.numSamples or traceDt != t.sampleInterval):
      r.log.report(sevWarning, dcInconsistent, "fixed-length file, but this trace has " &
        $traceNs & " samples at " & $traceDt & " (binary header: " & $t.numSamples & " at " &
        $t.sampleInterval & ")", t.offset + 114, r.loc(t.index, "trace.numSamples"))
  else:
    t.numSamples = traceNs
    t.sampleInterval = traceDt
  t.samples = r.readBlock(t.numSamples * sampleSize(f.format))
  inc r.tracesRead
  result = true

proc nextTrace(r: var SegyReader, t: var SegyTrace): bool =
  let b = r.file.binary
  if r.lastTraceSeen or (b.segyMajor >= 2 and b.numTraces != 0 and
      uint64(r.tracesRead) >= b.numTraces):
    if b.numTrailerRecords != 0: r.readTrailer(@[])
    result = false
  elif r.cursor.stoppedAt != rkData:
    result = false # tape mark or end of data
  else:
    result = r.readTraceBody(t)

proc readTrace*(r: var SegyReader, t: var SegyTrace): bool =
  ## Reads the next trace into `t`. Returns false when the traces have ended
  ## (or the read had to stop; see `log`). After the last trace, any data
  ## trailer is in `file.trailer`.
  if r.done:
    return false
  var more = false
  let ok = r.log.tryRecord(r.loc(r.tracesRead)):
    more = r.nextTrace(t)
  if ok and more:
    result = true
  else:
    r.done = true
    if ok: discard r.log.tryRecord(r.loc(), r.checkEnd())
    result = false

func isDone*(r: SegyReader): bool {.inline.} = r.done
func tracesRead*(r: SegyReader): int {.inline.} = r.tracesRead

proc decodeInto*[T: SampleType](file: SegyFile, trace: SegyTrace, t: var Tensor[T],
    row: int) =
  ## Decodes the trace's samples into row `row` of `t`. Raises like
  ## `decodeSamples` (`SegFormatError` for an undecodable format).
  if not file.formatKnown:
    raiseFormat("format code " & $file.binary.formatCode & " is undefined")
  t.decodeTrace(row, file.format, trace.samples, min(trace.numSamples, t.shape[1]),
    file.byteOrder)

# ---------------------------------------------------------------------------
# Whole-file convenience.

type
  SegyData* = object
    ## A whole SEG-Y file in memory: headers, raw traces and decoded samples.
    file*: SegyFile
    traces*: seq[SegyTrace]
    samples*: Tensor[float32]
      ## `[traces, maxSamples]`; shorter traces are zero-padded and
      ## undecodable ones stay zero (each has a diagnostic).
    diagnostics*: DiagLog

proc readSegy*(src: RecordSource): SegyData =
  ## Reads every trace of the SEG-Y file at the current position of `src`
  ## into memory. Meant for small files and tests; it holds the file twice
  ## (raw and decoded).
  var r = openSegy(src)
  var t: SegyTrace
  var maxNs = 0
  while r.readTrace(t):
    maxNs = max(maxNs, t.numSamples)
    result.traces.add t
  result.samples = newTraceTensor[float32](result.traces.len, maxNs)
  for i, tr in result.traces:
    discard r.log.tryRecord(r.loc(i), r.file.decodeInto(tr, result.samples, i))
  result.file = r.file
  result.diagnostics = r.log

proc readSegy*(path: string): SegyData =
  ## Reads a SEG-Y disk file into memory; see `readSegy(RecordSource)`. A file
  ## that cannot be opened gives a fatal diagnostic.
  var src: RecordSource
  if result.diagnostics.tryRecord(Location(file: path), (src = openDiskSource(path))):
    try:
      result = readSegy(src)
    finally:
      src.close()
