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
import ./[headers, samples, rev3]
export headers, samples, rev3, diagnostics, tensors

const
  MaxCount = 65535 ## Bound for counts that size header areas.
  DefaultMaxHeaderBytes* = 256 shl 20
    ## Extended/external headers, trailers and TOC files larger than this are
    ## skipped (not held in memory; the record is marked `incomplete`).
  DefaultMaxTraceBytes* = 2'i64 shl 30
    ## A trace larger than this stops the read (a corrupt sample count would
    ## otherwise pull the rest of a huge stream into memory).
  MaxDescriptors = 65535 ## Bound for scan types × channel sets in one record.
  MaxRepeats = 5 ## Diagnostics logged per (field, severity); the rest are counted.

type
  SegdRevision* = object
    ## From General Header #2 bytes 11-12; 0.0 for Rev 0 records (no GH#2).
    major*, minor*: uint8

  SegdScanType* = object
    ## The scan type header of one scan type.
    descriptors*: seq[SegdChannelSetDescriptor] ## One per channel set (Rev 1/2).
    descriptors3*: seq[SegdChannelSetDescriptor3] ## One per channel set (Rev 3).
    skew*: seq[byte]                            ## Skew blocks, raw (32 bytes each).

  SegdRecord* = object
    ## One shot record's headers and trailer.
    index*: int                ## 0-based record index in the stream.
    offset*: int64             ## Medium offset of General Header #1.
    gh1*: SegdGeneralHeader1
    hasGh2*: bool              ## False for Rev 0 records.
    gh2*: SegdGeneralHeader2   ## Rev 1/2 layout (also holds a Rev 3 GH#2's raw bytes).
    sourceHeaders*: seq[SegdGeneralHeaderN] ## General Headers #3 and later (Rev 1/2).
    isRev3*: bool              ## Rev 3 layout: the fields below apply.
    gh2r3*: SegdGeneralHeader2Rev3
    gh3*: SegdGeneralHeader3
    generalBlocks*: seq[byte]  ## Rev 3 general header blocks after GH#3, raw (32 bytes each).
    trailerBytes*: seq[byte]   ## Rev 3 general trailer, raw (32-byte blocks).
    scanTypes*: seq[SegdScanType]
    extended*: seq[byte]       ## Extended header blocks, raw.
    external*: seq[byte]       ## External header blocks, raw.
    trailer*: seq[SegdTrailerBlock] ## Rev 1/2 general trailer, after the last trace.
    revision*: SegdRevision
    format*: SegdSampleFormat  ## Valid when `formatKnown`.
    formatKnown*: bool
    traceCount*: int           ## Traces announced by the channel set descriptors.
    incomplete*: bool          ## A header area or the trailer was too large to hold and was skipped.

  SegdTrace* = object
    ## One trace. `readTrace` reuses the buffers of the trace it is given.
    header*: SegdTraceHeader
    hasExt1*: bool
    ext1*: SegdTraceHeaderExt1 ## Trace Header Extension #1 (Rev 1/2), valid when `hasExt1`.
    ext1r3*: SegdTraceHeaderExt1Rev3 ## Trace Header Extension #1 (Rev 3), valid when `hasExt1`.
    extensions*: seq[byte]     ## Extensions #2 and later, raw (32 bytes each; Rev 3: typed by byte 32).
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
    toc*: seq[SegdToc]          ## Rev 3 Table of Contents files met in the stream.
    maxHeaderBytes*: int64      ## See `DefaultMaxHeaderBytes`.
    maxTraceBytes*: int64       ## See `DefaultMaxTraceBytes`.
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
  when T is SegdRev3Block: decodeRev3[T](b) else: decodeBlock[T](b)

proc readBytes(r: var SegdReader, n: int64): seq[byte] =
  r.input.readInto(result, n)

proc readArea(r: var SegdReader, n: int64, field: string): seq[byte] =
  # A header area or trailer: held when it fits `maxHeaderBytes`, else
  # skipped (it still must be present) and the record marked incomplete.
  if n <= r.maxHeaderBytes:
    result = r.readBytes(n)
  else:
    let at = r.input.offset
    var left = n
    var buf: array[65536, byte]
    while left > 0:
      let k = r.input.readAvail(buf.toOpenArray(0, int(min(left, buf.len)) - 1))
      if k == 0: raiseTruncated(field & ": expected " & $n & " bytes", r.input.offset)
      left -= k
    r.record.incomplete = true
    r.note(sevInfo, dcValidation, field & ": " & $n & " bytes exceed the in-memory limit; " &
      "skipped (the record cannot be rewritten from memory)", at, r.loc(field = field))

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
  # on a block boundary. Writers never start a trace header in a block's last
  # 19 bytes, and a header cannot begin with 20 zero bytes (scan type 0 is
  # invalid): so zeros up to the block end, or 20 zeros, are padding. The
  # peek never looks past the block boundary.
  if r.hasLabel and r.label.isFixedRecord and r.label.maxBlockSize > 0:
    let gap = if r.byteStream:
                int((r.label.maxBlockSize - r.input.offset mod r.label.maxBlockSize) mod
                  r.label.maxBlockSize)
              else: r.input.remainingInRecord
    if gap > 0:
      var peek: array[SegdTraceHeaderSize, byte]
      let n = min(gap, peek.len)
      let got = r.input.readAvail(peek.toOpenArray(0, n - 1))
      var zero = got == n
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
    byteStream: not src.hasRecordBoundaries, twosComplement8015: twosComplement8015,
    maxHeaderBytes: DefaultMaxHeaderBytes, maxTraceBytes: DefaultMaxTraceBytes)
  if not result.log.tryRecord(Location(file: src.name, field: "label"), result.readLabel()):
    result.done = true

# ---------------------------------------------------------------- headers --

proc alignToBlock(r: var SegdReader) =
  # Rev 3: the first trace header and the first trailer block start a device
  # block (tape: a new tape block; FIXREC disk: the next block boundary).
  if not r.byteStream:
    discard r.input.skipRecordRest()
  elif r.hasLabel and r.label.isFixedRecord and r.label.maxBlockSize > 0:
    let bs = r.label.maxBlockSize
    r.input.skip((bs - r.input.offset mod bs) mod bs)

proc readRev3Headers(r: var SegdReader, gh2Offset: int64) =
  template rec: untyped = r.record
  rec.isRev3 = true
  rec.gh2r3 = decodeRev3[SegdGeneralHeader2Rev3](rec.gh2.raw)
  if rec.gh2r3.blockType != BtGeneralHeader2:
    r.note(sevWarning, dcBadValue, "General Header #2 block type is " & $rec.gh2r3.blockType &
      ", not 2", gh2Offset + 31, r.loc(field = "gh2.blockType"))
  if rec.revision.major > 3 or rec.revision.minor > 0:
    r.note(sevWarning, dcUnsupportedRevision, "revision " & $rec.revision & " read as Rev 3.0",
      gh2Offset + 10, r.loc(field = "gh2.revision"))
  let nGh = generalHeaderCount(rec.gh1, rec.gh2r3)
  if nGh < 3 or nGh > MaxCount:
    raiseUnlocatable(dcBadValue, "a Rev 3 record needs General Header #3, but " & $nGh &
      " general header blocks are declared", rec.offset + 11)
  let o3 = r.input.offset
  rec.gh3 = r.readBlock[:SegdGeneralHeader3]()
  if rec.gh3.blockType != BtGeneralHeader3:
    r.note(sevWarning, dcBadValue, "General Header #3 block type is " & $rec.gh3.blockType &
      ", not 3", o3 + 31, r.loc(field = "gh3.blockType"))
  rec.generalBlocks = r.readBytes(32 * (nGh - 3))
  for (i, t) in blocks(rec.generalBlocks):
    if not isDefinedBlock(t):
      r.note(sevWarning, dcUnknownBlock, "general header block of undefined type 0x" &
        toHex(t) & " kept raw", o3 + 32 + i + 31, r.loc(field = "gh.blockType"))
  let nST = rec.gh1.scanTypesPerRecord
  let nCS = channelSetsPerScanType(rec.gh1, rec.gh2r3)
  let nSK = skewBlocks(rec.gh1, rec.gh2r3)
  let nEC = extendedHeaderBlocks(rec.gh1, rec.gh2r3)
  let nEX = externalHeaderBlocks(rec.gh1, rec.gh2r3)
  for (name, v) in [("scanTypesPerRecord", nST), ("channelSetsPerScanType", nCS),
      ("skewBlocks", nSK)]:
    if v < 0 or v > MaxCount:
      raiseUnlocatable(dcBadBcd, "General Header #1 " & name & " is unreadable (" & $v &
        "), so the header cannot be located", rec.offset)
  if nST * nCS > MaxDescriptors:
    raiseUnlocatable(dcBadValue, "the record declares " & $nST & " scan types × " & $nCS &
      " channel sets, more than " & $MaxDescriptors & "; the header is probably corrupt",
      rec.offset + 27)
  if nEC < 0 or nEX < 0:
    raiseUnlocatable(dcBadBcd, "General Header #1 extended or external header count is " &
      "unreadable", rec.offset + 30)
  rec.traceCount = 0
  for st in 0..<nST:
    var s = SegdScanType()
    for cs in 0..<nCS:
      let o = r.input.offset
      var b: array[96, byte]
      r.input.readExactly(b)
      let c = decodeRev3[SegdChannelSetDescriptor3](b)
      if c.blockType1 != BtCsd1 or c.blockType2 != BtCsd2 or c.blockType3 != BtCsd3:
        r.note(sevWarning, dcBadValue, "channel set descriptor block types are " &
          $c.blockType1 & "/" & $c.blockType2 & "/" & $c.blockType3 & ", not 0x30/0x31/0x32",
          o + 31, r.loc(channelSet = cs, field = "csd.blockType"))
      if c.scanTypeNumber != st + 1:
        r.note(sevWarning, dcInconsistent, "channel set descriptor " & $(cs + 1) &
          " of scan type " & $(st + 1) & " says scan type " & $c.scanTypeNumber, o,
          r.loc(channelSet = cs, field = "csd.scanTypeNumber"))
      rec.traceCount += int(c.channelsInSet)
      s.descriptors3.add c
    s.skew = r.readBytes(32 * nSK)
    rec.scanTypes.add s
  rec.extended = r.readArea(32 * int64(nEC), "extended")
  rec.external = r.readArea(32 * int64(nEX), "external")
  # From the blocks read, not medium offsets (tape images interleave markers).
  var computed = 3 * 32 + int64(rec.generalBlocks.len) + int64(rec.extended.len) +
    int64(rec.external.len)
  for st in rec.scanTypes: computed += 96 * int64(st.descriptors3.len) + int64(st.skew.len)
  if rec.gh3.headerSize != 0 and int64(rec.gh3.headerSize) != computed:
    r.note(sevWarning, dcInconsistent, "General Header #3 header size is " &
      $rec.gh3.headerSize & ", the header blocks take " & $computed & " bytes", o3 + 24,
      r.loc(field = "gh3.headerSize"))
  var f: SegdSampleFormat
  if toSegdFormat(rec.gh1.formatCode, f):
    rec.format = f
    rec.formatKnown = true
  else:
    raiseUnlocatable(dcUnsupportedFormat, "sample format code " & $rec.gh1.formatCode &
      " is undefined or multiplexed, so trace lengths are unknown", rec.offset + 2)
  if rec.traceCount > 0: r.alignToBlock()

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
    if rec.revision.major >= 3:
      r.readRev3Headers(o)
      return
    if rec.gh2.blockNumber != 2:
      r.note(sevWarning, dcBadValue, "General Header #2 block number is " &
        $rec.gh2.blockNumber & ", not 2", o + 18, r.loc(field = "gh2.blockNumber"))
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
    let want = channelSetNumber(h) # BCD byte 4, or bytes 16-17 when it is FF
    if rec.isRev3:
      for i, c in rec.scanTypes[st].descriptors3:
        if int(c.channelSetNumber) == want and cs < 0: cs = i
    else:
      for i, c in rec.scanTypes[st].descriptors:
        if channelSetNumber(c) == want and cs < 0: cs = i
  else:
    st = -1

proc readRev3TraceRest(r: var SegdReader, t: var SegdTrace, the: int) =
  # After the demux header: extension blocks (THE#1 required) and samples.
  template rec: untyped = r.record
  t.extensions.setLen 0
  t.hasExt1 = the >= 1
  var csdNs = -1
  if t.channelSet >= 0:
    csdNs = int(rec.scanTypes[t.scanType].descriptors3[t.channelSet].numSamples)
  if t.hasExt1:
    var eb: array[SegdBlockSize, byte]
    r.input.readExactly(eb)
    t.ext1r3 = decodeRev3[SegdTraceHeaderExt1Rev3](eb)
    if t.ext1r3.blockType != BtTraceExt1:
      r.note(sevWarning, dcBadValue, "the first trace header extension has block type 0x" &
        toHex(t.ext1r3.blockType) & ", not 0x40", t.offset + 20 + 31,
        r.loc(t.index, t.channelSet, "ext1.blockType"))
    if the > 1: r.input.readInto(t.extensions, 32 * (the - 1))
    t.numSamples = int(t.ext1r3.numSamples)
    if csdNs >= 0 and csdNs != t.numSamples and rec.gh3.extendedRecordingMode == 0:
      r.note(sevWarning, dcInconsistent, "trace has " & $t.numSamples & " samples, its " &
        "channel set descriptor says " & $csdNs, t.offset + 20 + 24,
        r.loc(t.index, t.channelSet, "ext1.numSamples"))
  elif csdNs >= 0:
    r.note(sevWarning, dcBadValue, "Rev 3 traces need Trace Header Extension #1; using the " &
      "channel set's sample count", t.offset + 9, r.loc(t.index, t.channelSet,
      "trace.traceHeaderExtensions"))
    t.numSamples = csdNs
  else:
    raiseUnlocatable(dcInconsistent, "trace has no Trace Header Extension and no channel " &
      "set descriptor, so its length is unknown", t.offset)
  if rec.format == sd8015 and t.numSamples mod 4 != 0:
    r.note(sevWarning, dcBadValue, "format 8015 needs a multiple of 4 samples, the " &
      "trace has " & $t.numSamples, t.offset, r.loc(t.index, t.channelSet, "trace.numSamples"))
  let nbytes = dataBytes(rec.format, t.numSamples)
  if int64(nbytes) > r.maxTraceBytes:
    raiseUnlocatable(dcBadValue, "trace of " & $t.numSamples & " samples (" & $nbytes &
      " bytes) exceeds maxTraceBytes; the sample count is probably corrupt", t.offset)
  r.input.readInto(t.samples, nbytes)
  inc r.tracesRead

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
    let declared = if rec.isRev3: int(rec.scanTypes[t.scanType].descriptors3[t.channelSet].traceHeaderExtensions)
                   else: int(rec.scanTypes[t.scanType].descriptors[t.channelSet].traceHeaderExtensions)
    if declared != the:
      r.note(sevWarning, dcInconsistent, "trace has " & $the & " header extensions, " &
        "its channel set descriptor says " & $declared, t.offset + 9,
        r.loc(t.index, t.channelSet, "trace.traceHeaderExtensions"))
  if rec.isRev3:
    r.readRev3TraceRest(t, the)
    return
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
  let nbytes = dataBytes(rec.format, t.numSamples)
  if int64(nbytes) > r.maxTraceBytes:
    raiseUnlocatable(dcBadValue, "trace of " & $t.numSamples & " samples (" & $nbytes &
      " bytes) exceeds maxTraceBytes; the sample count is probably corrupt", t.offset)
  r.input.readInto(t.samples, nbytes)
  inc r.tracesRead

proc readRev3Trailer(r: var SegdReader) =
  # The general trailer: GH#2 bytes 13-16 blocks; when unknown (FFFFFFFF),
  # GH#3 recordSize - dataSize, else description-block groups as long as they
  # last.
  template rec: untyped = r.record
  let n = rec.gh2r3.generalTrailerBlocks
  if n == 0: return
  r.alignToBlock()
  if n != 0xFFFF_FFFF'u32:
    rec.trailerBytes = r.readArea(32 * int64(n), "trailer")
  elif rec.gh3.recordSize > rec.gh3.dataSize and rec.gh3.dataSize > 0:
    let diff = rec.gh3.recordSize - rec.gh3.dataSize
    if diff > uint64(high(int64) div 2):
      raiseUnlocatable(dcBadValue, "General Header #3 sizes give a trailer of " & $diff &
        " bytes; the record end cannot be located", r.input.offset)
    rec.trailerBytes = r.readArea(int64(diff), "trailer")
  else:
    var desc: array[SegdBlockSize, byte]
    var going = true
    while going:
      let got = r.input.readAvail(desc)
      # A description block: type 0x70, binary/ASCII flag 1 or 2, bytes 3-4
      # zero (so a following record's GH#1 with EX = 70 is not taken).
      if got == SegdBlockSize and desc[31] == BtTrailerDescription and desc[1] in {1'u8, 2} and
          desc[2] == 0 and desc[3] == 0:
        rec.trailerBytes.add desc
        let d = decodeRev3[SegdTrailerDescription](desc)
        rec.trailerBytes.add r.readArea(32 * int64(d.blockSize), "trailer")
      else:
        r.input.unread(desc.toOpenArray(0, got - 1))
        going = false

proc readRecordTrailer(r: var SegdReader) =
  template rec: untyped = r.record
  if rec.isRev3:
    r.readRev3Trailer()
    r.skipFixedPadding()
    return
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
  # A Rev 3 Table of Contents file (between file marks on tape).
  var peek: array[13, byte]
  let got = r.input.readAvail(peek)
  r.input.unread(peek.toOpenArray(0, got - 1))
  if isTocFile(peek):
    ok = r.log.tryRecord(Location(file: r.name, field: "toc")):
      var head: seq[byte]
      r.input.readInto(head, TocHeaderSize)
      let n = tocEntryCount(head)
      if n < 0 or n > 10_000_000:
        raiseUnlocatable(dcBadValue, "the Table of Contents entry count is unreadable", r.input.offset)
      var entries: seq[byte]
      if int64(n) * TocEntrySize > r.maxHeaderBytes:
        discard r.readArea(int64(n) * TocEntrySize, "toc") # skipped; header kept
      else:
        r.input.readInto(entries, int64(n) * TocEntrySize)
      head.add entries
      r.toc.add decodeToc(head)
      if r.byteStream: r.skipFixedPadding() else: discard r.input.skipRecordRest()
    if not ok:
      r.stop()
      return false
    return r.nextRecord()
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
