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

import std/[hashes, os]
import ../common/[endians, errors, diagnostics, ebcdic]
import ../io/[records, diskio]
import ../model/tensors
import ./[textheader, binheader, traceheader, samples, exttext, layout]
export textheader, binheader, traceheader, samples, exttext, layout, diagnostics, endians, tensors

const
  TapeLabelSize* = 128 ## Bytes in a SEG-Y tape label.
  ReadChunk = 4 shl 20
    ## Large blocks are read in chunks of this size, so a corrupt length in a
    ## header costs memory only for the bytes actually present.
  MaxExtendedRecords = 1_000_000
    ## Bound on extended records implied by a Rev 2 first-trace offset (3.2 GB).
  MaxLayoutBytes* = 1 shl 20 ## Larger Layout stanzas are ignored (with a warning).
  DefaultMaxRetained* = 256 shl 20
    ## Extended header and trailer bytes kept in memory by default. Beyond it,
    ## stanzas and User Data are only indexed; extract attachments from disk.

type
  SegyFile* = object
    ## The file-level part of a SEG-Y file.
    tapeLabel*: seq[byte]           ## Raw 128-byte label, or empty.
    text*: SegyTextHeader
    binary*: SegyBinaryHeader
    revision*: SegyRevision
      ## The revision whose rules were applied (`rulesRevision`); the raw
      ## bytes are `binary.revision`.
    extended*: ExtendedTextHeader   ## Extended textual header records.
    trailer*: ExtendedTextHeader    ## Rev 2 data trailer records.
    byteOrder*: ByteOrder           ## Byte order of binary fields and samples.
    byteOrderDeclared*: bool        ## The Rev 2 marker declared `byteOrder`.
    format*: SampleFormat           ## Valid when `formatKnown`.
    formatKnown*: bool
    firstTraceOffset*: int64        ## Medium offset of the first trace.
    layout*: TraceLayout
      ## Effective trace header layout: the revision's standard layout with
      ## the file's Layout stanza merged over it. Empty for files built in
      ## memory (`layoutOf` then gives the standard layout).
    binaryAsRead: seq[byte]         ## Raw binary header as read; empty for new files.
    extendedAsRead: Hash            ## Hash of the extended records as read.
    extendedAsReadLen: int          ## -1 for new files.
    trailerAsRead: Hash             ## Hash of the trailer records as read.
    trailerAsReadLen: int

  SegyTrace* = object
    ## One trace record. `readTrace` reuses the buffers of the `SegyTrace` it
    ## is given, so a loop over one variable allocates once.
    header*: SegyTraceHeader
    hasExt1*: bool                  ## The trace has Rev 2 additional headers.
    ext1*: SegyTraceHeaderExt1      ## Trace Header Extension 1, valid when `hasExt1`.
    proprietary*: seq[byte]
      ## Raw proprietary 240-byte headers after Ext1, in the file's byte order
      ## (their layout is user-defined; see `headerBlockName`).
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
    pending: seq[byte]   ## Bytes read ahead and pushed back (`unread`).
    pendingPos: int
    name: string
    tracesRead: int
    lastTraceSeen: bool
    ext1Warned: bool
    maxRetained: int
    byteStream: bool     ## The source has no record boundaries (disk): offsets are file offsets.
    mediumSize: int64    ## File size for disk sources, -1 if unknown.
    done: bool
    headersOnly: bool    ## Skip sample bytes (`SegyTrace.samples` stays empty).

func looksLikeTapeLabel(b: openArray[byte]): bool =
  # Storage unit sequence number (digits or blanks) and "SY" in bytes 5-6;
  # a textual header starts with 'C' instead.
  b[0] in {0x20'u8, 0x30'u8..0x39'u8} and b[4] == 0x53 and b[5] == 0x59

func startsWithC(b: openArray[byte]): bool {.inline.} = b[0] == 0xC3 or b[0] == 0x43

func loc(r: SegyReader, trace = -1, field = ""): Location {.inline.} =
  Location(file: r.name, record: 0, trace: trace, field: field)

# -------------------------------------------------------------- byte input --
# The cursor plus a push-back buffer: the reader may read a block ahead,
# decide it is not what it hoped for (a trailer, an extended record), and
# un-read it. This works on tape, where seeking back is not possible.

func offset(r: SegyReader): int64 {.inline.} =
  ## Medium offset of the next byte the reader will return.
  r.cursor.offset - int64(r.pending.len - r.pendingPos)

proc readAvail(r: var SegyReader, dst: var openArray[byte]): int =
  # Reads up to dst.len bytes; fewer only at a tape mark or end of data.
  while result < dst.len and r.pendingPos < r.pending.len:
    dst[result] = r.pending[r.pendingPos]
    inc result
    inc r.pendingPos
  if result < dst.len:
    result += r.cursor.read(dst.toOpenArray(result, dst.len - 1))

proc unread(r: var SegyReader, data: openArray[byte]) =
  # Pushes `data` (just read) back in front of the unread bytes.
  var rest = r.pending[r.pendingPos..^1]
  r.pending = @data
  r.pending.add rest
  r.pendingPos = 0

proc atData(r: var SegyReader): bool =
  r.pendingPos < r.pending.len or r.cursor.stoppedAt == rkData

proc readInto(r: var SegyReader, buf: var seq[byte], n: int64) =
  # Reads exactly n bytes into buf (reusing its storage), growing it chunk by
  # chunk as data arrives. Raises SegTruncatedError if the data ends first.
  if n < 0 or n > int64(high(int) div 2):
    raiseFormat("block length " & $n & " is not representable", r.offset)
  buf.setLen 0
  var got = 0
  while got < n:
    let step = int(min(n - got, ReadChunk))
    buf.setLen got + step
    let k = r.readAvail(buf.toOpenArray(got, got + step - 1))
    got += k
    if k < step:
      buf.setLen got
      raiseTruncated("expected " & $n & " bytes, got " & $got, r.offset)

proc skipExactly(r: var SegyReader, n: int64) =
  # Passes n bytes without keeping them (seeking where the source can).
  # Raises SegTruncatedError if the data ends first.
  var got = min(n, int64(r.pending.len - r.pendingPos))
  r.pendingPos += int(got)
  if got < n: got += r.cursor.skip(n - got)
  if got < n:
    raiseTruncated("expected " & $n & " bytes, got " & $got, r.offset)

proc readBlock(r: var SegyReader, n: int): seq[byte] =
  r.readInto(result, n)

# ------------------------------------------------------------ file headers --

proc readExtendedHeader(r: var SegyReader, count: int, checkText: bool) =
  # Reads extended records per `count` (see `needsMore`). With `checkText`
  # (count -1, or a count implied by the first-trace offset), a record that
  # is neither text, a stanza start nor binary stanza data ends the header
  # early: it is pushed back and read as a trace.
  template f: untyped = r.file
  var rec = newSeq[byte](TextHeaderSize)
  while f.extended.needsMore(count):
    let start = r.offset
    let got = r.readAvail(rec)
    if got < TextHeaderSize:
      raiseTruncated("extended textual record " & $f.extended.recordCount & " has " & $got &
        " of 3200 bytes", r.offset)
    if checkText and not f.extended.inBinaryStanza and not startsStanza(rec) and
        not f.extended.continuesUserData(rec) and not looksLikeText(rec):
      r.unread(rec)
      r.log.report(sevWarning, dcInconsistent, "extended textual header ends after " &
        $f.extended.recordCount & " records: the record at this offset is not text " &
        "(missing ((SEG:EndText)) or a wrong count)", start, r.loc(field = "extended"))
      break
    f.extended.add(rec, if r.byteStream: start else: -1)

proc reportIssues(r: var SegyReader, h: ExtendedTextHeader, start: int64, field: string) =
  # Walker issues become warnings. Stream offsets map to file offsets on disk.
  for i in h.issues:
    r.log.report(sevWarning, dcBadValue, i.msg, if r.byteStream: start + i.pos else: -1,
      r.loc(field = field))
  if not h.isComplete:
    r.log.report(sevInfo, dcValidation, field & ": " & $h.recordCount & " records exceed the " &
      "retention limit; stanzas and User Data are indexed but not held in memory",
      start, r.loc(field = field))

proc readFileHeaders(r: var SegyReader) =
  # Fills r.file as it goes, so whatever was read survives a later failure.
  template f: untyped = r.file
  let head = r.readBlock(TapeLabelSize)
  var textBytes: seq[byte]
  if looksLikeTapeLabel(head):
    textBytes = r.readBlock(TextHeaderSize)
    if startsWithC(textBytes):
      f.tapeLabel = head
    else:
      # Not a label after all: the textual header started at byte 0.
      r.unread(textBytes.toOpenArray(TextHeaderSize - TapeLabelSize, TextHeaderSize - 1))
      textBytes.setLen TextHeaderSize - TapeLabelSize
      textBytes = head & textBytes
  else:
    textBytes = head
    textBytes.add r.readBlock(TextHeaderSize - TapeLabelSize)
  let labelLen = f.tapeLabel.len
  f.text = decodeTextHeader(textBytes)

  let binOffset = r.offset
  let bin = r.readBlock(BinaryHeaderSize)
  f.binaryAsRead = bin
  let det = detectByteOrder(bin)
  f.byteOrder = det.order
  f.byteOrderDeclared = det.fromMarker
  f.binary = decodeBinaryHeader(bin, det.order)
  f.revision = f.binary.rulesRevision
  let rev = f.revision
  template binLoc(specByte: int, name: string): untyped =
    (binOffset + (specByte - 3201), r.loc(field = "binary." & name))
  if not det.plausible:
    let (o, l) = binLoc(3225, "formatCode")
    r.log.report(sevWarning, dcByteOrder, "no byte order gives a defined format code; " &
      "reading as " & $det.order, o, l)
  elif not det.fromMarker and det.order != boBig:
    let (o, l) = binLoc(3297, "byteOrderMarker")
    r.log.report(sevInfo, dcByteOrder, "byte order inferred as " & $det.order &
      " (no byte-order marker)", o, l)
  f.binary.validate(r.log, sevWarning, r.loc(), binOffset)

  var fmt: SampleFormat
  if toSampleFormat(int(f.binary.formatCode), fmt):
    f.format = fmt
    f.formatKnown = true
    if f.byteOrder == boPairSwapped and sampleSize(fmt) == 3:
      let (o, l) = binLoc(3225, "formatCode")
      r.log.report(sevError, dcUnsupportedFormat, "3-byte samples cannot be pair-swapped; " &
        "samples are kept raw", o, l)
  else:
    let (o, l) = binLoc(3225, "formatCode")
    r.log.report(sevFatal, dcUnsupportedFormat, "format code " & $f.binary.formatCode &
      " is undefined, so trace lengths are unknown", o, l)

  # Extended textual header records. Rev 0 has none.
  var count = if rev.major == 0: 0 else: int(f.binary.numExtTextHeaders)
  var fromOffset = false
  let fto = f.binary.firstTraceOffset
  if rev.major >= 2 and fto != 0:
    let base = uint64(3600 + labelLen)
    let (o, l) = binLoc(3521, "firstTraceOffset")
    if fto < base or (fto - base) mod TextHeaderSize != 0 or
        (fto - base) div TextHeaderSize > MaxExtendedRecords:
      r.log.report(sevWarning, dcBadValue, "first trace offset " & $fto &
        " is not 3600 + a plausible multiple of 3200; ignored", o, l)
    else:
      let n = int((fto - base) div TextHeaderSize)
      if count > 0 and count != n:
        r.log.report(sevWarning, dcInconsistent, "first trace offset implies " & $n &
          " extended records, the count says " & $count & "; using the offset", o, l)
      count = n
      fromOffset = true
  if count < -1: count = 0 # already reported by validate
  f.extended = initExtendedTextHeader(rev1Lines = rev.major < 2, maxRetained = r.maxRetained)
  f.trailer = initExtendedTextHeader(rev1Lines = rev.major < 2, maxRetained = r.maxRetained)
  let extStart = r.offset
  if r.mediumSize >= 0: f.extended.streamLimit = r.mediumSize - extStart
  try:
    r.readExtendedHeader(count, checkText = count == -1 or fromOffset)
  finally:
    f.extended.finish()
    r.reportIssues(f.extended, extStart, "extended")
  f.layout = standardLayout(rev)
  let li = f.extended.find("SEG:Layout")
  if li >= 0:
    let st = f.extended.stanzas[li]
    try:
      if st.dataEnd - st.dataStart > MaxLayoutBytes:
        raise newException(ValueError, "Layout stanza of " & $(st.dataEnd - st.dataStart) &
          " bytes exceeds " & $MaxLayoutBytes)
      f.layout = merge(f.layout, parseLayout(f.extended.stanzaText(st)))
    except ValueError as e:
      r.log.report(sevWarning, dcBadValue, e.msg & "; using the standard layout",
        extStart + st.headerStart, r.loc(field = "extended.layout"))
  f.extendedAsRead = hash(f.extended.data)
  f.extendedAsReadLen = f.extended.data.len
  if rev.major >= 2 and count > 0 and not f.extended.hasEndText:
    r.log.report(sevWarning, dcBadValue, "the last extended textual record is not " &
      "((SEG:EndText)) (required since the Rev 2.1 clarification)",
      r.offset - TextHeaderSize, r.loc(field = "extended"))
  f.firstTraceOffset = r.offset

func isBinaryAsRead*(f: SegyFile): bool =
  ## True when the binary header, encoded in `byteOrder`, is byte-identical
  ## to the one read from the file (false for files built in memory).
  if f.binaryAsRead.len != BinaryHeaderSize:
    result = false
  else:
    var b = newSeq[byte](BinaryHeaderSize)
    f.binary.encode(b, f.byteOrder)
    result = b == f.binaryAsRead

func layoutOf*(f: SegyFile): TraceLayout =
  ## The file's effective layout, or the standard one of its revision for a
  ## file built in memory.
  if f.layout.entries.len > 0: f.layout else: standardLayout(f.binary.rulesRevision)

func binaryAsRead*(f: SegyFile): lent seq[byte] {.inline.} =
  ## The raw binary header bytes as read (in `byteOrder`); empty for files
  ## built in memory.
  f.binaryAsRead

func isExtendedAsRead*(f: SegyFile): bool =
  ## True when the extended textual records are unchanged since the read.
  f.binaryAsRead.len == BinaryHeaderSize and f.extended.data.len == f.extendedAsReadLen and
    hash(f.extended.data) == f.extendedAsRead

func isTrailerAsRead*(f: SegyFile): bool =
  ## True when the trailer records are unchanged since the read (an empty
  ## trailer counts as unchanged for a file that was read).
  f.binaryAsRead.len == BinaryHeaderSize and f.trailer.data.len == f.trailerAsReadLen and
    (f.trailerAsReadLen == 0 or hash(f.trailer.data) == f.trailerAsRead)

proc openSegy*(src: RecordSource, maxRetained = DefaultMaxRetained,
    headersOnly = false): SegyReader =
  ## Reads the file headers from `src`, positioned at the start of a SEG-Y
  ## file. Check `log.isFatal` for a file whose traces cannot be read.
  ## Whatever headers were read before a failure are kept in `file`.
  ## Extended header and trailer bytes are held in memory up to
  ## `maxRetained` bytes each; beyond that they are only indexed.
  ##
  ## With `headersOnly`, `readTrace` skips the sample bytes (seeking on disk,
  ## reading and discarding on tape): `samples` stays empty, `numSamples` and
  ## the offsets are set, and a trace cut short still ends the read.
  result = SegyReader(cursor: initRecordCursor(src), name: src.name, maxRetained: maxRetained,
    byteStream: not src.hasRecordBoundaries, mediumSize: -1, headersOnly: headersOnly)
  if result.byteStream:
    try:
      result.mediumSize = getFileSize(src.name)
    except CatchableError:
      discard # not a plain file (e.g. a pipe): no size limit
  if not result.log.tryRecord(result.loc(), result.readFileHeaders()):
    result.done = true
  if result.log.isFatal: result.done = true

# ------------------------------------------------------------------ traces --

proc readTrailer(r: var SegyReader) =
  # Reads data trailer records: the declared number, or (count -1) all the
  # remaining records.
  let expected = int(r.file.binary.numTrailerRecords)
  let start = r.offset
  if r.mediumSize >= 0 and r.file.trailer.recordCount == 0:
    r.file.trailer.streamLimit = r.mediumSize - start
  var rec = newSeq[byte](TextHeaderSize)
  try:
    while (expected < 0 or r.file.trailer.recordCount < expected) and r.atData:
      let at = r.offset
      let got = r.readAvail(rec)
      if got < TextHeaderSize:
        raiseTruncated("trailer record " & $r.file.trailer.recordCount & " has " & $got &
          " of 3200 bytes", r.offset)
      r.file.trailer.add(rec, if r.byteStream: at else: -1)
  finally:
    r.file.trailer.finish()
    r.file.trailerAsRead = hash(r.file.trailer.data)
    r.file.trailerAsReadLen = r.file.trailer.data.len
    r.reportIssues(r.file.trailer, start, "trailer")
  if expected > 0 and r.file.trailer.recordCount < expected:
    r.log.report(sevWarning, dcTruncated, "expected " & $expected & " trailer records, found " &
      $r.file.trailer.recordCount, r.offset, r.loc(field = "trailer"))

proc trailerStartsHere(r: var SegyReader): bool =
  # Looks ahead one record: a trailer record starts with a stanza header and
  # is text. Trace data (whatever its first bytes) is pushed back.
  var rec = newSeq[byte](TextHeaderSize)
  let got = r.readAvail(rec)
  result = got == TextHeaderSize and startsStanzaRecord(rec)
  r.unread(rec.toOpenArray(0, got - 1))

proc checkEnd(r: var SegyReader) =
  # Called once the traces have ended: checks the declared counts.
  let b = r.file.binary
  if r.file.revision.major >= 2:
    if b.numTraces != 0 and uint64(r.tracesRead) < b.numTraces:
      r.log.report(sevWarning, dcInconsistent, "the binary header declares " & $b.numTraces &
        " traces, the file has " & $r.tracesRead, r.offset, r.loc(field = "binary.numTraces"))
    if b.numTrailerRecords > 0 and r.file.trailer.recordCount == 0:
      r.log.report(sevWarning, dcTruncated, "the binary header declares " &
        $b.numTrailerRecords & " trailer records, the file has none", r.offset,
        r.loc(field = "trailer"))
  if r.atData:
    r.log.report(sevWarning, dcInconsistent, "data follows the last trace", r.offset, r.loc())

func isExt1Name(b: openArray[byte]): bool =
  # "SEG00001" in ASCII or EBCDIC at bytes 233-240.
  const ascii = "SEG00001"
  var a, e = true
  for i, c in ascii:
    if b[232 + i] != byte(c): a = false
    if b[232 + i] != latin1ToEbcdic[uint8(c)]: e = false
  a or e

proc readTraceBody(r: var SegyReader, t: var SegyTrace) =
  template f: untyped = r.file
  let order = f.byteOrder
  t.index = r.tracesRead
  t.offset = r.offset
  var hdr: array[TraceHeaderSize, byte]
  if r.readAvail(hdr) < TraceHeaderSize:
    raiseTruncated("trace header ends early", r.offset)
  t.header = decodeTraceHeader(hdr, order)

  # Rev 2 additional trace headers; Ext1 comes first.
  var extNs = 0'u32
  var extDt = 0.0
  t.hasExt1 = false
  t.proprietary.setLen 0
  if f.revision.major >= 2 and f.binary.maxAddlTraceHeaders > 0:
    var raw: array[TraceHeaderSize, byte]
    if r.readAvail(raw) < TraceHeaderSize:
      raiseTruncated("trace header extension 1 ends early", r.offset)
    t.hasExt1 = true
    t.ext1 = decodeTraceHeaderExt1(raw, order)
    if not r.ext1Warned and not isExt1Name(raw):
      r.ext1Warned = true
      r.log.report(sevWarning, dcBadValue, "the first additional trace header is not named " &
        "SEG00001; reading it as Trace Header Extension 1 anyway (reported once)",
        t.offset + TraceHeaderSize + 232, r.loc(t.index, "ext1.headerName"))
    let declared = t.ext1.numAddlTraceHeaders
    let k = if declared != 0: int64(declared) else: int64(f.binary.maxAddlTraceHeaders)
    if k > 1:
      r.readInto(t.proprietary, (k - 1) * TraceHeaderSize)
    extNs = t.ext1.extNumSamples
    extDt = t.ext1.extSampleInterval
    if (t.ext1.lastTraceFlag and LastInFile) != 0:
      r.lastTraceSeen = true

  let traceNs = if extNs != 0: int(extNs) else: int(t.header.numSamples)
  let traceDt = if extDt != 0: extDt else: float64(t.header.sampleInterval)
  if f.revision.major >= 1 and f.binary.fixedLengthTraces == 1:
    t.numSamples = int(f.binary.effectiveSamplesPerTrace)
    t.sampleInterval = f.binary.effectiveSampleInterval
    if f.revision.major < 2 and (traceNs != t.numSamples or traceDt != t.sampleInterval):
      r.log.report(sevWarning, dcInconsistent, "fixed-length file, but this trace has " &
        $traceNs & " samples at " & $traceDt & " (binary header: " & $t.numSamples & " at " &
        $t.sampleInterval & ")", t.offset + 114, r.loc(t.index, "trace.numSamples"))
  else:
    t.numSamples = traceNs
    t.sampleInterval = traceDt
  let nbytes = int64(t.numSamples) * sampleSize(f.format)
  if r.headersOnly:
    t.samples.setLen 0
    r.skipExactly(nbytes)
  else:
    r.readInto(t.samples, nbytes)
  inc r.tracesRead

proc nextTrace(r: var SegyReader, t: var SegyTrace): bool =
  let b = r.file.binary
  let rev2 = r.file.revision.major >= 2
  if r.lastTraceSeen or (rev2 and b.numTraces != 0 and uint64(r.tracesRead) >= b.numTraces):
    if rev2 and b.numTrailerRecords != 0: r.readTrailer()
    result = false
  elif not r.atData:
    result = false # tape mark or end of data
  elif rev2 and b.numTrailerRecords != 0 and r.trailerStartsHere():
    r.readTrailer()
    result = false
  else:
    r.readTraceBody(t)
    result = true

proc readTrace*(r: var SegyReader, t: var SegyTrace): bool =
  ## Reads the next trace into `t`, reusing its buffers. Returns false when
  ## the traces have ended (or the read had to stop; see `log`). After the
  ## last trace, any data trailer is in `file.trailer`.
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
func headersOnly*(r: SegyReader): bool {.inline.} = r.headersOnly
func tracesRead*(r: SegyReader): int {.inline.} = r.tracesRead

proc decodeInto*[T: SampleType](file: SegyFile, trace: SegyTrace, t: var Tensor[T],
    row: int) =
  ## Decodes the trace's samples into row `row` of `t`. Raises like
  ## `decodeSamples` (`SegFormatError` for an undecodable format).
  if not file.formatKnown:
    raiseFormat("format code " & $file.binary.formatCode & " is undefined")
  if trace.samples.len < trace.numSamples * sampleSize(file.format):
    raiseFormat("trace " & $trace.index & " holds no samples (read with headersOnly)")
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

proc readSegy*(src: RecordSource, maxRetained = DefaultMaxRetained,
    headersOnly = false): SegyData =
  ## Reads every trace of the SEG-Y file at the current position of `src`
  ## into memory. Meant for small files and tests; it holds the file twice
  ## (raw and decoded).
  ##
  ## With `headersOnly`, every header is read and the sample bytes are
  ## skipped (seeking on disk): `samples` is `[traces, 0]` and each trace's
  ## `samples` is empty. This is the cheap way to scan a large file's headers.
  var r = openSegy(src, maxRetained, headersOnly)
  var t: SegyTrace
  var maxNs = 0
  while r.readTrace(t):
    maxNs = max(maxNs, t.numSamples)
    result.traces.add t
  result.samples = newTraceTensor[float32](result.traces.len, if headersOnly: 0 else: maxNs)
  if not headersOnly:
    for i, tr in result.traces:
      discard r.log.tryRecord(r.loc(i), r.file.decodeInto(tr, result.samples, i))
  result.file = r.file
  result.diagnostics = r.log

proc readSegy*(path: string, maxRetained = DefaultMaxRetained, headersOnly = false): SegyData =
  ## Reads a SEG-Y disk file into memory; see `readSegy(RecordSource)`. A file
  ## that cannot be opened gives a fatal diagnostic.
  var src: RecordSource
  if result.diagnostics.tryRecord(Location(file: path), (src = openDiskSource(path))):
    try:
      result = readSegy(src, maxRetained, headersOnly)
    finally:
      src.close()

proc readSegyHeaders*(path: string, maxRetained = DefaultMaxRetained): SegyData =
  ## Every header of a SEG-Y disk file, samples skipped (`readSegy` with
  ## `headersOnly`).
  readSegy(path, maxRetained, headersOnly = true)

proc extractUserData*(path: string, b: UserDataBlock, dest: string) =
  ## Copies a User Data attachment from the disk file `path` to the file
  ## `dest`, in 4 MB chunks, without holding it in memory. Raises
  ## `ValueError` if the attachment's file offset is unknown (it was read
  ## from tape), `IOError` on I/O failure or a short file.
  if b.mediumOffset < 0:
    raise newException(ValueError, "User Data block '" & b.dataLabel &
      "' has no file offset (it was not read from a disk file)")
  if b.available < b.blockSize:
    raise newException(ValueError, "User Data block '" & b.dataLabel & "' declares " &
      $b.blockSize & " bytes, but only " & $b.available & " are inside the records")
  var src, dst: File
  if not open(src, path, fmRead):
    raise newException(IOError, "cannot open for reading: " & path)
  try:
    if not open(dst, dest, fmWrite):
      raise newException(IOError, "cannot open for writing: " & dest)
    try:
      src.setFilePos(b.mediumOffset)
      var buf = newSeq[byte](ReadChunk)
      var left = b.blockSize
      while left > 0:
        let n = int(min(left, ReadChunk))
        if src.readBuffer(addr buf[0], n) != n:
          raise newException(IOError, path & ": file ends inside User Data block '" &
            b.dataLabel & "'")
        if dst.writeBuffer(addr buf[0], n) != n:
          raise newException(IOError, "write failed: " & dest)
        left -= n
    finally:
      dst.close()
  finally:
    src.close()
