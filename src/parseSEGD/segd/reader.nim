## SEG-D Rev 1 / 2.x reader: a streaming walk over any `RecordSource` (disk
## file, tape image, tape device, memory), with every problem logged as a
## diagnostic (spec note `segd_rev2_0.md` §2, §6).
##
## ```nim
## var r = openSegd(openDiskSource("line.sgd"))
## while r.nextRecord():
##   var t: SegdTrace
##   while r.readTrace(t):
##     echo r.record.gh1.fileNumber, " ", t.header.traceNumber, " ", t.numSamples
## ```
##
## A stream holds an optional storage unit label, then shot records, each:
## general headers, scan type headers (channel set descriptors and skew
## blocks), extended and external headers, traces, general trailer blocks.
## Tape marks may separate records; a FIXREC label pads every record to the
## label's block size. Every trace is sized from its own header: extension
## count (byte 10), sample count from Trace Header Extension #1, else from its
## channel set's time window.
##
## Like the SEG-Y reader it never raises on format problems; reading stops
## only when the rest cannot be located (truncation, an unknown sample
## format, an unsized trace), logged as `fatal`. Headers and traces keep
## their bytes, so a read/write round trip is byte-identical. SEG-D Rev 3 is
## a separate layout (task 5).

import std/[math, tables, strutils]
import ../common/[endians, errors, diagnostics]
import ../io/[records, diskio, pushback]
import ../model/tensors
import ./[headers, samples]
export headers, samples, diagnostics, tensors

const
  MaxCount = 65535 ## Bound for counts that size header areas.
  MaxDescriptors = 65535 ## Bound for scan types × channel sets in one record.
  MaxRepeats = 5 ## Diagnostics logged per (field, severity); the rest are counted.

type
  SegdRevision* = object
    ## From General Header #2 bytes 11-12; 0.0 for Rev 0 records (no GH#2).
    major*, minor*: uint8

  SegdScanType* = object
    ## The scan type header of one scan type.
    descriptors*: seq[SegdChannelSetDescriptor] ## One per channel set.
    skew*: seq[byte]                            ## Skew blocks, raw (32 bytes each).

  SegdRecord* = object
    ## One shot record's headers and trailer.
    index*: int                ## 0-based record index in the stream.
    offset*: int64             ## Medium offset of General Header #1.
    gh1*: SegdGeneralHeader1
    hasGh2*: bool              ## False for Rev 0 records.
    gh2*: SegdGeneralHeader2
    sourceHeaders*: seq[SegdGeneralHeaderN] ## General Headers #3 and later.
    scanTypes*: seq[SegdScanType]
    extended*: seq[byte]       ## Extended header blocks, raw.
    external*: seq[byte]       ## External header blocks, raw.
    trailer*: seq[SegdTrailerBlock] ## Filled after the record's last trace.
    revision*: SegdRevision
    format*: SegdSampleFormat  ## Valid when `formatKnown`.
    formatKnown*: bool
    traceCount*: int           ## Traces announced by the channel set descriptors.

  SegdTrace* = object
    ## One trace. `readTrace` reuses the buffers of the trace it is given.
    header*: SegdTraceHeader
    hasExt1*: bool
    ext1*: SegdTraceHeaderExt1 ## Trace Header Extension #1, valid when `hasExt1`.
    extensions*: seq[byte]     ## Extensions #2 and later, raw (32 bytes each).
    numSamples*: int
    samples*: seq[byte]        ## Raw sample bytes.
    scanType*: int             ## 0-based scan type index, -1 if unknown.
    channelSet*: int           ## 0-based index into that scan type's descriptors, -1 if unknown.
    index*: int                ## 0-based trace index within the record.
    offset*: int64             ## Medium offset of the trace header.

  SegdReader* = object
    ## Streaming reader state.
    label*: SegdStorageUnitLabel
    hasLabel*: bool
    record*: SegdRecord         ## The current record (after `nextRecord`).
    log*: DiagLog
    twosComplement8015*: bool   ## Read 8015 fractions as two's complement.
    input: PushbackInput
    name: string
    byteStream: bool
    records: int
    tracesRead: int
    inRecord: bool
    done: bool
    csdWarned: bool
    noted: Table[string, int] ## Diagnostics per (field, severity), for `note`.

func `$`*(r: SegdRevision): string = $r.major & "." & $r.minor

proc note(r: var SegdReader, severity: Severity, code: DiagCode, msg: string,
    offset: int64 = -1, loc = Location()) =
  # Logs a diagnostic, but only the first `MaxRepeats` per field and
  # severity: a systematic quirk repeated on every trace of a 40 GB file must
  # not grow the log without bound. `stop` reports how many were left out.
  let key = $severity & " " & loc.field
  let n = r.noted.getOrDefault(key) + 1
  r.noted[key] = n
  if n <= MaxRepeats:
    r.log.report(severity, code, msg, offset, loc)

proc stop(r: var SegdReader) =
  # Ends the stream and summarizes the diagnostics `note` left out.
  if not r.done:
    r.done = true
    for key, n in r.noted:
      if n > MaxRepeats:
        let field = key.split(' ', 1)[1]
        r.log.report(sevInfo, dcValidation, $(n - MaxRepeats) & " more " & key.split(' ')[0] &
          " diagnostics for " & field & " were not logged", loc = Location(file: r.name,
          field: field))

func loc(r: SegdReader, trace = -1, channelSet = -1, field = ""): Location {.inline.} =
  Location(file: r.name, record: r.records - 1, trace: trace, channelSet: channelSet,
    field: field)

proc readBlock[T](r: var SegdReader): T =
  var b: array[sizeof(T.default.raw), byte]
  r.input.readExactly(b)
  decodeBlock[T](b)

proc readBytes(r: var SegdReader, n: int64): seq[byte] =
  r.input.readInto(result, n)

proc reportBcd[T](r: var SegdReader, h: T, blockName: string, offset: int64) =
  for f in h.invalidBcdFields:
    r.note(sevWarning, dcBadBcd, blockName & "." & f & " holds a non-decimal digit",
      offset, r.loc(field = blockName & "." & f))

# ------------------------------------------------------------------ label --

proc skipFixedPadding(r: var SegdReader) =
  # FIXREC: every record ends on a block boundary.
  if r.hasLabel and r.label.isFixedRecord and r.label.maxBlockSize > 0:
    if r.byteStream:
      let bs = r.label.maxBlockSize
      r.input.skip((bs - r.input.offset mod bs) mod bs)
    else:
      discard r.input.skipRecordRest()

proc skipTracePadding(r: var SegdReader) =
  # FIXREC: a block may end with zero padding so that the next trace starts
  # on a block boundary. A trace header cannot be all zero (scan type 0 is
  # invalid), so 20 zero bytes where a header should start are padding.
  if r.hasLabel and r.label.isFixedRecord and r.label.maxBlockSize > 0:
    var peek: array[SegdTraceHeaderSize, byte]
    let got = r.input.readAvail(peek)
    var zero = got == peek.len
    for i in 0..<got:
      if peek[i] != 0: zero = false
    r.input.unread(peek.toOpenArray(0, got - 1))
    if zero:
      r.skipFixedPadding()

proc readLabel(r: var SegdReader) =
  var head: array[128, byte]
  let got = r.input.readAvail(head)
  if got == 128 and isStorageUnitLabel(head):
    r.label = decodeLabel(head)
    r.hasLabel = true
    if r.label.isFixedRecord and r.label.maxBlockSize <= 0:
      r.note(sevWarning, dcTapeLayout, "FIXREC label without a block size; " &
        "records are read unpadded", 19, Location(file: r.name, field: "label.maxBlockSize"))
    if not r.byteStream:
      discard r.input.skipRecordRest() # the label is its own tape block
    else:
      r.skipFixedPadding()
  else:
    r.input.unread(head.toOpenArray(0, got - 1))

proc openSegd*(src: RecordSource, twosComplement8015 = false): SegdReader =
  ## Opens a SEG-D stream positioned at its start and reads the storage unit
  ## label if there is one. Call `nextRecord` for each shot record.
  result = SegdReader(input: initPushbackInput(src), name: src.name,
    byteStream: not src.hasRecordBoundaries, twosComplement8015: twosComplement8015)
  if not result.log.tryRecord(Location(file: src.name, field: "label"), result.readLabel()):
    result.done = true

# ---------------------------------------------------------------- headers --

proc readRecordHeaders(r: var SegdReader) =
  template rec: untyped = r.record
  rec.offset = r.input.offset
  rec.gh1 = r.readBlock[:SegdGeneralHeader1]()
  r.reportBcd(rec.gh1, "gh1", rec.offset)
  let nGh = rec.gh1.generalHeaderCount
  if nGh >= 2:
    rec.hasGh2 = true
    let o = r.input.offset
    rec.gh2 = r.readBlock[:SegdGeneralHeader2]()
    rec.revision = SegdRevision(major: rec.gh2.revisionMajor, minor: rec.gh2.revisionMinor)
    if rec.gh2.blockNumber != 2:
      r.note(sevWarning, dcBadValue, "General Header #2 block number is " &
        $rec.gh2.blockNumber & ", not 2", o + 18, r.loc(field = "gh2.blockNumber"))
    if rec.revision.major >= 3:
      raiseUnlocatable(dcUnsupportedRevision, "SEG-D Rev " & $rec.revision &
        " records use the Rev 3 layout, which this reader does not handle yet", o + 10)
    if rec.revision.major > 2 or (rec.revision.major == 2 and rec.revision.minor > 1):
      r.note(sevWarning, dcUnsupportedRevision, "revision " & $rec.revision &
        " read as Rev 2.1", o + 10, r.loc(field = "gh2.revision"))
  for n in 3..nGh:
    let o = r.input.offset
    let g = r.readBlock[:SegdGeneralHeaderN]()
    if g.blockNumber != uint8(n):
      r.note(sevWarning, dcBadValue, "General Header #" & $n & " block number is " &
        $g.blockNumber, o + 18, r.loc(field = "gh" & $n & ".blockNumber"))
    if g.sourceSetNumber == 0:
      r.note(sevInfo, dcBadValue, "General Header #" & $n & " source set number is 0 " &
        "(spec: not valid; common in real files)", o + 19, r.loc(field = "gh" & $n & ".sourceSetNumber"))
    rec.sourceHeaders.add g

  # Counts that size the rest of the header.
  let nST = rec.gh1.scanTypesPerRecord
  let nCS = if rec.hasGh2: channelSetsPerScanType(rec.gh1, rec.gh2)
            else: rec.gh1.channelSetsPerScanType
  let nSK = rec.gh1.skewBlocks
  let nEC = if rec.hasGh2: extendedHeaderBlocks(rec.gh1, rec.gh2) else: rec.gh1.extendedHeaderBlocks
  let nEX = if rec.hasGh2: externalHeaderBlocks(rec.gh1, rec.gh2) else: rec.gh1.externalHeaderBlocks
  for (name, v) in [("scanTypesPerRecord", nST), ("channelSetsPerScanType", nCS),
      ("skewBlocks", nSK), ("extendedHeaderBlocks", nEC), ("externalHeaderBlocks", nEX)]:
    if v < 0 or v > MaxCount:
      raiseUnlocatable(dcBadBcd, "General Header #1 " & name & " is unreadable (" & $v &
        "), so the header cannot be located", rec.offset)
  if nST * nCS > MaxDescriptors:
    raiseUnlocatable(dcBadValue, "the record declares " & $nST & " scan types × " & $nCS &
      " channel sets, more than " & $MaxDescriptors & "; the header is probably corrupt",
      rec.offset + 27)
  if nST == 0 or nCS == 0:
    r.note(sevWarning, dcBadValue, "the record declares " & $nST & " scan types and " &
      $nCS & " channel sets per scan type", rec.offset + 27, r.loc(field = "gh1.scanTypesPerRecord"))

  rec.traceCount = 0
  for st in 0..<nST:
    var s = SegdScanType()
    for cs in 0..<nCS:
      let o = r.input.offset
      let c = r.readBlock[:SegdChannelSetDescriptor]()
      r.reportBcd(c, "csd", o)
      if c.scanTypeNumber != st + 1:
        r.note(sevWarning, dcInconsistent, "channel set descriptor " & $(cs + 1) &
          " of scan type " & $(st + 1) & " says scan type " & $c.scanTypeNumber, o,
          r.loc(channelSet = cs, field = "csd.scanTypeNumber"))
      if c.arrayForming == 0 and c.channelCount > 0:
        r.note(sevInfo, dcBadValue, "channel set " & $c.channelSetNumber &
          " array forming code is 0 (spec: undefined; common in real files)", o + 31,
          r.loc(channelSet = cs, field = "csd.arrayForming"))
      if c.channelCount > 0: rec.traceCount += c.channelCount
      s.descriptors.add c
    s.skew = r.readBytes(32 * nSK)
    rec.scanTypes.add s
  rec.extended = r.readBytes(32 * nEC)
  rec.external = r.readBytes(32 * nEX)

  var f: SegdSampleFormat
  if toSegdFormat(rec.gh1.formatCode, f):
    rec.format = f
    rec.formatKnown = true
  else:
    raiseUnlocatable(dcUnsupportedFormat, "sample format code " & $rec.gh1.formatCode &
      " is undefined or multiplexed, so trace lengths are unknown", rec.offset + 2)

# ----------------------------------------------------------------- traces --

proc findChannelSet*(rec: SegdRecord, h: SegdTraceHeader, st, cs: var int) =
  ## The 0-based scan type and channel set indices that trace header `h`
  ## names; -1 when there is none.
  st = h.scanTypeNumber - 1
  cs = -1
  if st >= 0 and st < rec.scanTypes.len:
    let want = h.channelSetNumber
    for i, c in rec.scanTypes[st].descriptors:
      if c.channelSetNumber == want and cs < 0: cs = i
  else:
    st = -1

proc readTraceBody(r: var SegdReader, t: var SegdTrace) =
  template rec: untyped = r.record
  r.skipTracePadding()
  t.index = r.tracesRead
  t.offset = r.input.offset
  var hb: array[SegdTraceHeaderSize, byte]
  r.input.readExactly(hb)
  t.header = decodeBlock[SegdTraceHeader](hb)
  r.reportBcd(t.header, "trace", t.offset)
  findChannelSet(rec, t.header, t.scanType, t.channelSet)
  let the = int(t.header.traceHeaderExtensions)
  if t.channelSet < 0:
    if not r.csdWarned:
      r.csdWarned = true
      r.note(sevWarning, dcInconsistent, "trace header names scan type " &
        $t.header.scanTypeNumber & ", channel set " & $t.header.channelSetNumber &
        ", which no channel set descriptor has (reported once per record)", t.offset + 2,
        r.loc(t.index, field = "trace.channelSetNumber"))
  else:
    let c = rec.scanTypes[t.scanType].descriptors[t.channelSet]
    if int(c.traceHeaderExtensions) != the:
      r.note(sevWarning, dcInconsistent, "trace has " & $the & " header extensions, " &
        "its channel set descriptor says " & $c.traceHeaderExtensions, t.offset + 9,
        r.loc(t.index, t.channelSet, "trace.traceHeaderExtensions"))
  if the > 15:
    r.note(sevWarning, dcBadValue, "trace header extension count " & $the &
      " exceeds 15", t.offset + 9, r.loc(t.index, field = "trace.traceHeaderExtensions"))
  t.hasExt1 = the >= 1
  t.extensions.setLen 0
  if t.hasExt1:
    var eb: array[SegdBlockSize, byte]
    r.input.readExactly(eb)
    t.ext1 = decodeBlock[SegdTraceHeaderExt1](eb)
    if the > 1: r.input.readInto(t.extensions, 32 * (the - 1))
    t.numSamples = int(t.ext1.samplesPerTrace)
  elif t.channelSet >= 0:
    # No extension: the spec gives no rule; (TE - TF) / SI matches real data.
    let c = rec.scanTypes[t.scanType].descriptors[t.channelSet]
    let si = c.sampleIntervalMs(rec.gh1)
    if si <= 0:
      raiseUnlocatable(dcBadValue, "trace has no sample count and its sample interval is 0",
        t.offset)
    t.numSamples = int(round((c.endTimeMs - c.startTimeMs) / si))
    if t.numSamples < 0:
      raiseUnlocatable(dcBadValue, "channel set ends (" & $c.endTimeMs & " ms) before it starts (" &
        $c.startTimeMs & " ms), so the trace length is unknown", t.offset)
  else:
    raiseUnlocatable(dcInconsistent, "trace has no Trace Header Extension and no channel " &
      "set descriptor, so its length is unknown", t.offset)
  if rec.format == sd8015 and t.numSamples mod 4 != 0:
    r.note(sevWarning, dcBadValue, "format 8015 needs a multiple of 4 samples, the " &
      "trace has " & $t.numSamples, t.offset, r.loc(t.index, t.channelSet, "trace.numSamples"))
  r.input.readInto(t.samples, dataBytes(rec.format, t.numSamples))
  inc r.tracesRead

proc readRecordTrailer(r: var SegdReader) =
  template rec: untyped = r.record
  let n = if rec.hasGh2: int(rec.gh2.generalTrailerBlocks) else: 0
  for i in 1..n:
    let o = r.input.offset
    let b = r.readBlock[:SegdTrailerBlock]()
    if b.channelType != 0xC:
      r.note(sevWarning, dcBadValue, "general trailer block " & $i &
        " has channel type " & $b.channelType & ", not 0xC", o + 10,
        r.loc(field = "trailer.channelType"))
    rec.trailer.add b
  r.skipFixedPadding()

proc readTrace*(r: var SegdReader, t: var SegdTrace): bool =
  ## Reads the next trace of the current record into `t`. Returns false after
  ## the record's last trace (its general trailer is then in
  ## `record.trailer`), or when the read had to stop (see `log`).
  if not r.inRecord or r.done:
    return false
  if r.tracesRead >= r.record.traceCount:
    r.inRecord = false
    discard r.log.tryRecord(r.loc(field = "trailer"), r.readRecordTrailer())
    if r.log.isFatal: r.stop()
    return false
  if r.log.tryRecord(r.loc(r.tracesRead), r.readTraceBody(t)):
    result = true
  else:
    r.inRecord = false
    r.stop()
    result = false

proc nextRecord*(r: var SegdReader): bool =
  ## Reads the next shot record's headers into `record`. Traces left unread
  ## in the previous record are skipped. Returns false at the end of the data
  ## (or when the read had to stop; see `log`).
  if r.inRecord:
    var t: SegdTrace
    while r.readTrace(t): discard
  if r.done:
    return false
  var ok = r.log.tryRecord(Location(file: r.name, record: r.records)):
    while r.input.stoppedAt == rkTapeMark: r.input.skipTapeMark()
  if not ok or not r.input.atData:
    r.stop()
    return false
  r.record = SegdRecord(index: r.records)
  inc r.records
  r.tracesRead = 0
  r.csdWarned = false
  ok = r.log.tryRecord(r.loc(), r.readRecordHeaders())
  if ok:
    r.inRecord = true
    result = true
  else:
    r.stop()
    result = false

func isDone*(r: SegdReader): bool {.inline.} = r.done

proc decodeInto*[T: SegdSampleType](rec: SegdRecord, t: SegdTrace, dst: var Tensor[T], row: int,
    twosComplement8015 = false) =
  ## Decodes the trace's samples into row `row` of `dst` (recorded values;
  ## multiply by 2^mpFactor of its channel set for millivolts).
  if not rec.formatKnown:
    raiseFormat("sample format " & $rec.gh1.formatCode & " is not decodable")
  dst.decodeTrace(row, rec.format, t.samples, min(t.numSamples, dst.shape[1]),
    twosComplement8015)

# ---------------------------------------------------------------------------
# Whole-stream convenience.

type
  SegdRecordData* = object
    ## One shot record in memory.
    record*: SegdRecord
    traces*: seq[SegdTrace]
    samples*: Tensor[float32] ## `[traces, maxSamples]`, zero-padded.

  SegdData* = object
    ## A whole SEG-D stream in memory.
    label*: SegdStorageUnitLabel
    hasLabel*: bool
    records*: seq[SegdRecordData]
    diagnostics*: DiagLog

proc readSegd*(src: RecordSource, twosComplement8015 = false): SegdData =
  ## Reads every record of a SEG-D stream into memory. Meant for small files
  ## and tests; large files should be walked record by record.
  var r = openSegd(src, twosComplement8015)
  while r.nextRecord():
    var d = SegdRecordData()
    var t: SegdTrace
    var maxNs = 0
    while r.readTrace(t):
      maxNs = max(maxNs, t.numSamples)
      d.traces.add t
    d.record = r.record
    d.samples = newTraceTensor[float32](d.traces.len, maxNs)
    for i, tr in d.traces:
      discard r.log.tryRecord(Location(file: src.name, record: d.record.index, trace: i),
        d.record.decodeInto(tr, d.samples, i, twosComplement8015))
    result.records.add d
  result.label = r.label
  result.hasLabel = r.hasLabel
  result.diagnostics = r.log

proc readSegd*(path: string, twosComplement8015 = false): SegdData =
  ## Reads a SEG-D disk file into memory; see `readSegd(RecordSource)`.
  var src: RecordSource
  if result.diagnostics.tryRecord(Location(file: path), (src = openDiskSource(path))):
    try:
      result = readSegd(src, twosComplement8015)
    finally:
      src.close()
