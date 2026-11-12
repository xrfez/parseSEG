## SEG-D reader for every revision (Rev 0, 1, 2.x and 3.x): a streaming walk
## over any `RecordSource` (disk file, tape image, tape device, memory), with
## every problem logged as a diagnostic (spec notes `segd_rev2_0.md` §2, §6,
## `segd_rev3_0_a.md` §2).
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
## channel set's descriptor.
##
## The record's `layout` says which header layout it has: `slRev2` (Rev 0, 1
## and 2.x) or `slRev3` (Rev 3.x: General Header #3, 96-byte channel set
## descriptors, typed 32-byte blocks). The layout-specific blocks are the
## branches of `SegdRecord`, `SegdScanType` and `SegdTrace`; accessors such
## as `sampleIntervalUs` and `channelType` resolve a value for either.
##
## Multiplexed records (Rev 0 and Rev 1 format codes 0015 ... 0058, see
## `segd/mux`) are demultiplexed as they are read: the reader walks the
## record's scans (start-of-scan codes and timing words, GH#1 bytes per
## scan), splits them into scan types, and `readTrace` gives one
## demultiplexed trace per channel, in the demultiplexed twin format (8015
## for 0015, ...), with the trace header a demultiplexing system writes. The
## record is flagged `multiplexed`, and its headers stay as read (GH#1 still
## says 0015). A record's scans are held in memory while its traces are read.
##
## Like the SEG-Y reader it never raises on format problems; reading stops
## only when the rest cannot be located (truncation, an unknown sample
## format, an unsized trace), logged as `fatal`. Headers and traces keep
## their bytes, so a read/write round trip is byte-identical.

import std/[math, tables, strutils]
import ../common/[errors, diagnostics]
import ../io/[records, diskio, pushback]
import ../common/tensors
import ./[blocks, samples, mux]
export blocks, diagnostics
export samples except decodeSamplesRaw
export tensors

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
  UnknownTrailerBlocks* = 0xFFFF_FFFF'u32 ## Rev 3 GH#2: the trailer size is not given.

type
  SegdRevision* = object
    ## From General Header #2 bytes 11-12; 0.0 for Rev 0 records (no GH#2).
    major*, minor*: uint8

  SegdLayout* = enum
    ## The header layout of a record, which its revision decides.
    slRev2 = "Rev 0-2" ## Rev 0, 1 and 2.x: 32-byte channel set descriptors, untyped
                       ## trace header extensions, General Header #N source blocks.
    slRev3 = "Rev 3"   ## Rev 3.x: General Header #3, 96-byte channel set descriptors,
                       ## blocks typed by their byte 32.

  SegdScanType* = object
    ## The scan type header of one scan type.
    skew*: seq[byte]                            ## Skew blocks, raw (32 bytes each).
    case layout*: SegdLayout
    of slRev2:
      descriptors*: seq[SegdChannelSetDescriptor] ## One per channel set.
    of slRev3:
      descriptorsRev3*: seq[SegdChannelSetDescriptorRev3] ## One per channel set.

  SegdRecord* = object
    ## One shot record's headers and trailer.
    index*: int                ## 0-based record index in the stream.
    offset*: int64             ## Medium offset of General Header #1.
    gh1*: SegdGeneralHeader1
    revision*: SegdRevision
    scanTypes*: seq[SegdScanType] ## Each of the record's layout.
    extended*: seq[byte]       ## Extended header blocks, raw.
    external*: seq[byte]       ## External header blocks, raw.
    format*: Option[SegdSampleFormat]
      ## The sample format of the traces; none if not decodable. For a
      ## `multiplexed` record, the demultiplexed twin of GH#1's code.
    multiplexed*: bool
      ## The record's data is multiplexed (GH#1 format 0015 ... 0058); the
      ## reader gives its traces demultiplexed (see the module docs).
    traceCount*: int           ## Traces announced by the channel set descriptors.
    incomplete*: bool
      ## A header area or the trailer was too large to hold and was skipped.
    case layout*: SegdLayout
    of slRev2:
      gh2*: Option[SegdGeneralHeader2] ## None for Rev 0 records.
      sourceHeaders*: seq[SegdGeneralHeaderN] ## General Headers #3 and later.
      trailer*: seq[SegdTrailerBlock] ## General trailer, after the last trace.
    of slRev3:
      gh2Rev3*: SegdGeneralHeader2Rev3
      gh3*: SegdGeneralHeader3
      generalBlocks*: seq[byte]  ## General header blocks after GH#3, raw (32 bytes each).
      trailerRev3*: seq[byte]    ## General trailer, raw (32-byte blocks).

  SegdTrace* = object
    ## One trace. `readTrace` reuses the buffers of the trace it is given.
    header*: SegdTraceHeader
    extensions*: seq[byte]
      ## Trace header extensions after #1, raw (32 bytes each; Rev 3: typed by byte 32).
    numSamples*: int
    samples*: seq[byte]
      ## Raw sample bytes (of a multiplexed record: demultiplexed, in the
      ## record's `format`).
    scanType*: int             ## 0-based scan type index, -1 if unknown.
    channelSet*: int           ## 0-based index into that scan type's descriptors, -1 if unknown.
    index*: int                ## 0-based trace index within the record.
    offset*: int64
      ## Medium offset of the trace header (of a multiplexed record, which has
      ## none: of the first scan of the trace's scan type).
    case layout*: SegdLayout   ## The layout of the trace's record.
    of slRev2:
      ext1*: Option[SegdTraceHeaderExt1] ## Trace Header Extension #1, if the trace has one.
    of slRev3:
      ext1Rev3*: Option[SegdTraceHeaderExt1Rev3]
        ## Trace Header Extension #1; none when the trace has none (Rev 3 requires one).

  SegdChannelSetRef* = object
    ## Where a trace's channel set descriptor is (see `findChannelSet`).
    scanType*: int   ## 0-based scan type index.
    channelSet*: int ## 0-based index into that scan type's descriptors.

  MuxBody = object
    # The scans of the multiplexed record being read, and the next channel.
    data: seq[byte]          # whole scans, back to back (empty with headersOnly)
    heads: seq[ScanHeader]   # every scan's start of scan and timing word
    stride: int              # bytes per scan
    offset: int64            # medium offset of the first scan
    layouts: seq[MuxScanLayout] # per scan type
    first, count: seq[int]   # first scan and scans of each scan type
    timeBreakWindow: array[3, byte] # timing word of the scan where TWI became 1
    st, cs, ch: int          # the next trace's scan type, channel set, channel

  SegdReader* = object
    ## Streaming reader state.
    twosComplement8015*: bool   ## Read 8015 fractions as two's complement.
    maxHeaderBytes*: int64      ## See `DefaultMaxHeaderBytes`.
    maxTraceBytes*: int64       ## See `DefaultMaxTraceBytes`.
    label: Option[SegdStorageUnitLabel]
    record: SegdRecord
    log: DiagLog
    toc: seq[SegdToc]
    input: PushbackInput
    name: string
    byteStream: bool
    records: int
    tracesRead: int
    inRecord: bool
    done: bool
    csdWarned: bool
    lastChannelSet: SegdChannelSetRef ## The previous trace's, for `findChannelSet` (-1s: none).
    noted: Table[(Severity, string), int] ## Diagnostics per (severity, field), for `note`.
    headersOnly: bool          ## Skip sample bytes (`SegdTrace.samples` stays empty).
    mux: MuxBody               ## The current record's scans, when it is multiplexed.

func `$`*(r: SegdRevision): string =
  ## `major.minor`, e.g. `2.1`.
  $r.major & "." & $r.minor

func `<`*(a, b: SegdRevision): bool =
  ## Revision order (major, then minor).
  (a.major, a.minor) < (b.major, b.minor)

func `<=`*(a, b: SegdRevision): bool =
  ## Revision order (major, then minor).
  (a.major, a.minor) <= (b.major, b.minor)

func isRev3*(rec: SegdRecord): bool {.inline.} =
  ## True for the Rev 3 layout (`layout == slRev3`).
  rec.layout == slRev3

func record*(r: SegdReader): lent SegdRecord {.inline.} =
  ## The current record (after `nextRecord`).
  r.record

func label*(r: SegdReader): lent Option[SegdStorageUnitLabel] {.inline.} =
  ## The storage unit label, if the stream starts with one.
  r.label

func log*(r: SegdReader): lent DiagLog {.inline.} =
  ## Every diagnostic of the read so far.
  r.log

func toc*(r: SegdReader): lent seq[SegdToc] {.inline.} =
  ## The Rev 3 Table of Contents files met in the stream so far.
  r.toc

func channelSetCount*(s: SegdScanType): int {.inline.} =
  ## Channel set descriptors of the scan type.
  case s.layout
  of slRev2: s.descriptors.len
  of slRev3: s.descriptorsRev3.len

# ------------------------------------------- values resolved per layout --

func generalHeaderCount*(rec: SegdRecord): int =
  ## General header blocks including #1 (Rev 3: GH#2 bytes 23-24 when GH#1
  ## byte 12H is `F`).
  case rec.layout
  of slRev2: rec.gh1.generalHeaderCount
  of slRev3: generalHeaderCount(rec.gh1, rec.gh2Rev3)

func fileNumber*(rec: SegdRecord): int64 =
  ## The file number, from GH#2 when GH#1's is `FFFF`.
  case rec.layout
  of slRev2:
    if rec.gh2.isSome: fileNumber(rec.gh1, rec.gh2.get) else: int64(rec.gh1.fileNumber)
  of slRev3: fileNumber(rec.gh1, rec.gh2Rev3)

func channelSetsPerScanType*(rec: SegdRecord): int =
  ## Channel sets per scan type, from GH#2 when GH#1's is `FF`.
  case rec.layout
  of slRev2:
    if rec.gh2.isSome: channelSetsPerScanType(rec.gh1, rec.gh2.get)
    else: rec.gh1.channelSetsPerScanType
  of slRev3: channelSetsPerScanType(rec.gh1, rec.gh2Rev3)

func skewBlocks*(rec: SegdRecord): int =
  ## Skew blocks per scan type (Rev 3: from GH#2 when GH#1's is `FF`).
  case rec.layout
  of slRev2: rec.gh1.skewBlocks
  of slRev3: skewBlocks(rec.gh1, rec.gh2Rev3)

func extendedHeaderBlocks*(rec: SegdRecord): int =
  ## Extended header blocks, from GH#2 when GH#1's is `FF`.
  case rec.layout
  of slRev2:
    if rec.gh2.isSome: extendedHeaderBlocks(rec.gh1, rec.gh2.get)
    else: rec.gh1.extendedHeaderBlocks
  of slRev3: extendedHeaderBlocks(rec.gh1, rec.gh2Rev3)

func externalHeaderBlocks*(rec: SegdRecord): int =
  ## External header blocks, from GH#2 when GH#1's is `FF`.
  case rec.layout
  of slRev2:
    if rec.gh2.isSome: externalHeaderBlocks(rec.gh1, rec.gh2.get)
    else: rec.gh1.externalHeaderBlocks
  of slRev3: externalHeaderBlocks(rec.gh1, rec.gh2Rev3)

func baseScanIntervalUs*(rec: SegdRecord): float64 =
  ## The base scan interval in µs (Rev 3: GH#2's when GH#1 byte 23 is `FF`).
  case rec.layout
  of slRev2: rec.gh1.baseScanIntervalMs * 1000
  of slRev3: baseScanIntervalUs(rec.gh1, rec.gh2Rev3)

func headerBytes*(rec: SegdRecord): int64 =
  ## Bytes of the record's header blocks, from the blocks it holds: general
  ## headers, scan type headers, extended and external headers (for Rev 3,
  ## what GH#3's header size gives).
  let general = case rec.layout
    of slRev2: (1 + ord(rec.gh2.isSome) + rec.sourceHeaders.len) * SegdBlockSize
    of slRev3: 3 * SegdBlockSize + rec.generalBlocks.len
  result = int64(general) + int64(rec.extended.len) + int64(rec.external.len)
  for s in rec.scanTypes:
    let csd = case s.layout
      of slRev2: SegdBlockSize
      of slRev3: 3 * SegdBlockSize
    result += int64(csd) * int64(s.channelSetCount) + int64(s.skew.len)

func announcedTraces*(rec: SegdRecord): int =
  ## Traces the channel set descriptors announce (what `traceCount` holds
  ## after a read).
  for s in rec.scanTypes:
    case s.layout
    of slRev2:
      for c in s.descriptors:
        if c.channelCount > 0: result += c.channelCount
    of slRev3:
      for c in s.descriptorsRev3: result += int(c.channelsInSet)

func scanTypeIndex(rec: SegdRecord, h: SegdTraceHeader): int =
  # The 0-based scan type a trace header names, -1 if the record has none.
  let st = h.scanTypeNumber - 1
  if st >= 0 and st < rec.scanTypes.len: st else: -1

func findChannelSet(rec: SegdRecord, h: SegdTraceHeader,
    last: SegdChannelSetRef): Option[SegdChannelSetRef] =
  # `findChannelSet`, trying `last` (this record's previous answer, or -1s)
  # first: consecutive traces mostly share a channel set. A hit is the
  # first descriptor with its number, as the search below would find, since
  # `last` came from that search in the same record. Descriptors are read in
  # place by index (`for i, c in` copied each one).
  let st = scanTypeIndex(rec, h)
  if st >= 0:
    let want = channelSetNumber(h) # BCD byte 4, or bytes 16-17 when it is FF
    template s: untyped = rec.scanTypes[st]
    template search(descs: untyped, number: untyped) =
      let n = descs.len
      if last.scanType == st and last.channelSet in 0..<n and
          number(descs[last.channelSet]) == want:
        return some(last)
      for i in 0..<n:
        if number(descs[i]) == want:
          return some(SegdChannelSetRef(scanType: st, channelSet: i))
    template rev3Number(c: SegdChannelSetDescriptorRev3): int = int(c.channelSetNumber)
    case s.layout
    of slRev2: search(s.descriptors, channelSetNumber)
    of slRev3: search(s.descriptorsRev3, rev3Number)
  none(SegdChannelSetRef)

func findChannelSet*(rec: SegdRecord, h: SegdTraceHeader): Option[SegdChannelSetRef] =
  ## The channel set descriptor that trace header `h` names (its scan type
  ## and channel set number); none when the record has no such descriptor.
  findChannelSet(rec, h, SegdChannelSetRef(scanType: -1, channelSet: -1))

# Channel set values of a trace, the same for every revision; the Rev 1/2 or
# Rev 3 descriptor is chosen here. A channel set that is unknown
# (`channelSet` -1) gives the record-level value or a neutral one.

func channelType*(rec: SegdRecord, scanType, channelSet: int): int =
  ## The channel type code of a channel set (Rev 1/2: 1 = seis,
  ## 9 = signature filtered, ...; Rev 3: 0x10 seis, 0x20-0x70 auxiliary,
  ## ...); 0 when `channelSet` is -1.
  if channelSet < 0: return 0
  template s: untyped = rec.scanTypes[scanType]
  case s.layout
  of slRev2: int(s.descriptors[channelSet].channelType)
  of slRev3: int(s.descriptorsRev3[channelSet].channelType)

func channelType*(rec: SegdRecord, t: SegdTrace): int {.inline.} =
  ## The channel type code of the trace's channel set (see above).
  rec.channelType(t.scanType, t.channelSet)

func sampleIntervalUs*(rec: SegdRecord, scanType, channelSet: int): float64 =
  ## The sample interval of a channel set in µs (Rev 3: its sampling
  ## interval; Rev 1/2: base scan interval / 2^subscan), or the record's base
  ## scan interval when `channelSet` is -1.
  if channelSet < 0: return rec.baseScanIntervalUs
  template s: untyped = rec.scanTypes[scanType]
  case s.layout
  of slRev2: s.descriptors[channelSet].sampleIntervalMs(rec.gh1) * 1000
  of slRev3: float64(s.descriptorsRev3[channelSet].samplingInterval)

func sampleIntervalUs*(rec: SegdRecord, t: SegdTrace): float64 {.inline.} =
  ## The trace's sample interval in µs (see above).
  rec.sampleIntervalUs(t.scanType, t.channelSet)

func startTimeMs*(rec: SegdRecord, t: SegdTrace): float64 =
  ## The start time of the trace's channel set in ms; 0 when it is unknown.
  if t.channelSet < 0: return 0.0
  template s: untyped = rec.scanTypes[t.scanType]
  case s.layout
  of slRev2: s.descriptors[t.channelSet].startTimeMs
  of slRev3: float64(s.descriptorsRev3[t.channelSet].startTime) / 1000

func descaleFactor*(rec: SegdRecord, t: SegdTrace): float64 =
  ## Millivolts per recorded unit of the trace's channel set: 2^MP factor
  ## (Rev 1/2) or the descale multiplier (Rev 3; 1 when it is 0 or NaN).
  ## 1 when the channel set is unknown.
  if t.channelSet < 0: return 1.0
  template s: untyped = rec.scanTypes[t.scanType]
  case s.layout
  of slRev2: pow(2.0, s.descriptors[t.channelSet].mpFactor)
  of slRev3:
    let m = float64(s.descriptorsRev3[t.channelSet].descaleMultiplier)
    if m == 0 or m.isNaN: 1.0 else: m

# ------------------------------------------------------------ bookkeeping --

proc note(r: var SegdReader, severity: Severity, code: DiagCode, msg: string,
    offset: int64 = -1, loc = Location()) =
  # Logs a diagnostic, but only the first `MaxRepeats` per field and
  # severity: a systematic quirk repeated on every trace of a 40 GB file must
  # not grow the log without bound. `stop` reports how many were left out.
  let n = r.noted.getOrDefault((severity, loc.field)) + 1
  r.noted[(severity, loc.field)] = n
  if n <= MaxRepeats:
    r.log.report(severity, code, msg, offset, loc)

proc stop(r: var SegdReader) =
  # Ends the stream and summarizes the diagnostics `note` left out.
  if not r.done:
    r.done = true
    for key, n in r.noted:
      if n > MaxRepeats:
        let (severity, field) = key
        r.log.report(sevInfo, dcValidation, $(n - MaxRepeats) & " more " & $severity &
          " diagnostics for " & field & " were not logged",
          loc = Location(file: r.name, field: field))

func loc(r: SegdReader, trace = -1, channelSet = -1, field = ""): Location {.inline.} =
  Location(file: r.name, record: r.records - 1, trace: trace, channelSet: channelSet,
    field: field)

proc readBlock[T](r: var SegdReader): T =
  var b: array[sizeof(T.default.raw), byte]
  r.input.readExactly(b)
  decodeBlock[T](b)

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

func fixedBlockSize(r: SegdReader): int64 =
  # FIXREC: the label's block size; 0 without a FIXREC label (or its size).
  if r.label.isSome and r.label.get.isFixedRecord: max(r.label.get.maxBlockSize, 0)
  else: 0

proc skipToBlockEnd(r: var SegdReader) =
  # Disk: the next multiple of the FIXREC block size; tape: the next block.
  if r.byteStream:
    let bs = r.fixedBlockSize
    if bs > 0: r.input.skip((bs - r.input.offset mod bs) mod bs)
  else:
    discard r.input.skipRecordRest()

proc skipFixedPadding(r: var SegdReader) =
  # FIXREC: every record ends on a block boundary.
  if r.fixedBlockSize > 0: r.skipToBlockEnd()

proc skipTracePadding(r: var SegdReader) =
  # FIXREC: a block may end with zero padding so that the next trace starts
  # on a block boundary. Writers never start a trace header in a block's last
  # 19 bytes, and a header cannot begin with 20 zero bytes (scan type 0 is
  # invalid): so zeros up to the block end, or 20 zeros, are padding. The
  # peek never looks past the block boundary.
  let bs = r.fixedBlockSize
  if bs > 0:
    let gap = if r.byteStream: int((bs - r.input.offset mod bs) mod bs)
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
    let label = decodeLabel(head)
    if label.isFixedRecord and label.maxBlockSize <= 0:
      r.note(sevWarning, dcTapeLayout, "FIXREC label without a block size; " &
        "records are read unpadded", 19, Location(file: r.name, field: "label.maxBlockSize"))
    r.label = some(label)
    if not r.byteStream:
      discard r.input.skipRecordRest() # the label is its own tape block
    else:
      r.skipFixedPadding()
  else:
    r.input.unread(head.toOpenArray(0, got - 1))

proc openSegd*(src: RecordSource, twosComplement8015 = false,
    headersOnly = false): SegdReader =
  ## Opens a SEG-D stream positioned at its start and reads the storage unit
  ## label if there is one. Call `nextRecord` for each shot record.
  ##
  ## With `headersOnly`, `readTrace` skips the sample bytes (seeking on disk,
  ## reading and discarding on tape): `samples` stays empty, `numSamples` and
  ## the offsets are set, and a trace cut short still ends the read.
  result = SegdReader(input: initPushbackInput(src), name: src.name,
    byteStream: not src.hasRecordBoundaries, twosComplement8015: twosComplement8015,
    maxHeaderBytes: DefaultMaxHeaderBytes, maxTraceBytes: DefaultMaxTraceBytes,
    headersOnly: headersOnly)
  if headersOnly: result.input.cursor.preferSmallReads()
  # A failure here, and wherever the reader stops on one (`nextRecord`,
  # `readTrace`), ends the read: always a fatal entry.
  if not result.log.tryRecordFatal(Location(file: src.name, field: "label"),
      result.readLabel()):
    result.done = true

# ---------------------------------------------------------------- headers --

proc checkCounts(r: var SegdReader) =
  # The counts that size the rest of the header must be readable.
  template rec: untyped = r.record
  let nST = rec.gh1.scanTypesPerRecord
  let nCS = rec.channelSetsPerScanType
  for (name, v, limit) in [("scanTypesPerRecord", nST, MaxCount),
      ("channelSetsPerScanType", nCS, MaxCount), ("skewBlocks", rec.skewBlocks, MaxCount),
      ("extendedHeaderBlocks", rec.extendedHeaderBlocks, high(int)),
      ("externalHeaderBlocks", rec.externalHeaderBlocks, high(int))]:
    if v < 0 or v > limit:
      raiseUnlocatable(dcBadBcd, "General Header #1 " & name & " is unreadable (" & $v &
        "), so the header cannot be located", rec.offset)
  if nST * nCS > MaxDescriptors:
    raiseUnlocatable(dcBadValue, "the record declares " & $nST & " scan types × " & $nCS &
      " channel sets, more than " & $MaxDescriptors & "; the header is probably corrupt",
      rec.offset + 27)

proc readDescriptor(r: var SegdReader, s: var SegdScanType, st, cs: int) =
  # Channel set descriptor `cs` of scan type `st`, with its checks.
  template rec: untyped = r.record
  let o = r.input.offset
  var scanTypeNumber: int
  case s.layout
  of slRev2:
    let c = r.readBlock[:SegdChannelSetDescriptor]()
    r.reportBcd(c, "csd", o)
    if c.arrayForming == 0 and c.channelCount > 0 and rec.gh2.isSome: # Rev 0: unused
      r.note(sevInfo, dcBadValue, "channel set " & $c.channelSetNumber &
        " array forming code is 0 (spec: undefined; common in real files)", o + 31,
        r.loc(channelSet = cs, field = "csd.arrayForming"))
    scanTypeNumber = c.scanTypeNumber
    s.descriptors.add c
  of slRev3:
    let c = r.readBlock[:SegdChannelSetDescriptorRev3]()
    if c.blockType1 != BlockTypeChannelSet1 or c.blockType2 != BlockTypeChannelSet2 or
        c.blockType3 != BlockTypeChannelSet3:
      r.note(sevWarning, dcBadValue, "channel set descriptor block types are " &
        $c.blockType1 & "/" & $c.blockType2 & "/" & $c.blockType3 & ", not 0x30/0x31/0x32",
        o + 31, r.loc(channelSet = cs, field = "csd.blockType"))
    scanTypeNumber = c.scanTypeNumber
    s.descriptorsRev3.add c
  if scanTypeNumber != st + 1:
    r.note(sevWarning, dcInconsistent, "channel set descriptor " & $(cs + 1) &
      " of scan type " & $(st + 1) & " says scan type " & $scanTypeNumber, o,
      r.loc(channelSet = cs, field = "csd.scanTypeNumber"))

proc readScanTypes(r: var SegdReader) =
  # Scan type headers, extended and external headers, and the sample format.
  template rec: untyped = r.record
  r.checkCounts()
  let nCS = rec.channelSetsPerScanType
  if not rec.isRev3 and (rec.gh1.scanTypesPerRecord == 0 or nCS == 0):
    r.note(sevWarning, dcBadValue, "the record declares " & $rec.gh1.scanTypesPerRecord &
      " scan types and " & $nCS & " channel sets per scan type", rec.offset + 27,
      r.loc(field = "gh1.scanTypesPerRecord"))
  for st in 0 ..< rec.gh1.scanTypesPerRecord:
    var s = SegdScanType(layout: rec.layout)
    for cs in 0..<nCS: r.readDescriptor(s, st, cs)
    s.skew = r.readBytes(SegdBlockSize * rec.skewBlocks)
    rec.scanTypes.add s
  rec.traceCount = rec.announcedTraces
  rec.extended = r.readArea(SegdBlockSize * int64(rec.extendedHeaderBlocks), "extended")
  rec.external = r.readArea(SegdBlockSize * int64(rec.externalHeaderBlocks), "external")
  let code = rec.gh1.formatCode
  rec.format = toSegdFormat(code)
  if rec.format.isNone and code.isMultiplexedCode and not rec.isRev3:
    rec.format = demuxFormat(code)
    rec.multiplexed = true
    r.note(sevInfo, dcMultiplexed, "the record is multiplexed (format " & align($code, 4, '0') &
      "); its traces are demultiplexed as format " & $ord(rec.format.get), rec.offset + 2,
      r.loc(field = "gh1.formatCode"))
    if SegdRevision(major: 2, minor: 0) <= rec.revision:
      r.note(sevWarning, dcBadValue, "Rev " & $rec.revision & " does not allow multiplexed " &
        "data; demultiplexed anyway", rec.offset + 2, r.loc(field = "gh1.formatCode"))
  elif rec.format.isNone:
    let what = if code.isMultiplexedCode: " is multiplexed, which Rev 3 does not allow"
               elif code in 0..999: " is an undefined multiplexed code (supported: 0015, " &
                 "0022, 0024, 0036, 0038, 0042, 0044, 0048, 0058)"
               else: " is undefined"
    raiseUnlocatable(dcUnsupportedFormat, "sample format code " & $code & what &
      ", so trace lengths are unknown", rec.offset + 2)
  if rec.format.get.isLittleEndian and rec.revision < SegdRevision(major: 3, minor: 1):
    r.note(sevWarning, dcBadValue, "format " & $rec.gh1.formatCode & " (little-endian) is " &
      "defined from Rev 3.1, but the record says " & $rec.revision & "; decoded anyway",
      rec.offset + 2, r.loc(field = "gh1.formatCode"))

# ------------------------------------------------------------ multiplexed --

func windowScans(rec: SegdRecord, st: int): int =
  # Scans of scan type `st` by its first non-dummy channel set's window
  # (all channel sets of a multiplexed scan type have the same length);
  # -1 when it has none or the base scan interval is 0.
  let bsi = rec.gh1.baseScanIntervalMs
  result = -1
  if bsi > 0:
    for c in rec.scanTypes[st].descriptors:
      if c.channelCount > 0:
        return int(round((c.endTimeMs - c.startTimeMs) / bsi))

proc muxStride(r: var SegdReader): int =
  # Bytes per scan: GH#1 bytes 20-22, checked against the descriptors.
  template rec: untyped = r.record
  template m: untyped = r.mux
  let declared = rec.gh1.bytesPerScan
  result = if declared > 0: declared
           elif m.layouts.len > 0: m.layouts[0].bytesPerScan
           else: ScanHeaderSize
  if declared <= 0:
    r.note(sevWarning, dcBadValue, "General Header #1 bytes per scan is " &
      (if declared == 0: "0" else: "not BCD") & "; using the " & $result &
      " bytes the channel set descriptors give", rec.offset + 19, r.loc(field = "gh1.bytesPerScan"))
  if result < ScanHeaderSize:
    # No scan fits: every one starts with these 8 bytes. A record without
    # scan types has no descriptor that would refuse the count below.
    raiseUnlocatable(dcBadValue, "General Header #1 bytes per scan is " & $result &
      ", less than the " & $ScanHeaderSize & "-byte start of scan and timing word, so the " &
      "scans cannot be located", rec.offset + 19)
  for i, l in m.layouts:
    if l.bytesPerScan > result:
      raiseUnlocatable(dcInconsistent, "scan type " & $(i + 1) & " needs " & $l.bytesPerScan &
        " bytes per scan, General Header #1 says " & $result & ", so its samples cannot be " &
        "located", rec.offset + 19)
    if l.bytesPerScan != result:
      r.note(sevWarning, dcInconsistent, "scan type " & $(i + 1) & " has " & $l.bytesPerScan &
        " bytes per scan, General Header #1 says " & $result & "; the rest of each scan is " &
        "ignored", rec.offset + 19, r.loc(field = "gh1.bytesPerScan"))
    if rec.gh1.formatCode == 15:
      for k, c in l.channelSets:
        if c.channels mod 4 != 0:
          r.note(sevWarning, dcBadValue, "format 0015 needs a multiple of 4 channels per " &
            "channel set, channel set " & $(k + 1) & " of scan type " & $(i + 1) & " has " &
            $c.channels, rec.offset + 2, r.loc(channelSet = k, field = "csd.channelCount"))

proc walkScans(r: var SegdReader) =
  # Reads scans for as long as they start with a start-of-scan code (to the
  # end of the data, a tape mark, or the next record's General Header #1,
  # which cannot start with FF FF FF).
  template m: untyped = r.mux
  var head: array[ScanHeaderSize, byte]
  var going = true
  while going:
    let at = r.input.offset
    let got = r.input.readAvail(head)
    if got < ScanHeaderSize or not isStartOfScan(head):
      r.input.unread(head.toOpenArray(0, got - 1))
      going = false
    else:
      if int64(m.heads.len + 1) * m.stride > r.maxTraceBytes:
        raiseUnlocatable(dcBadValue, "the multiplexed record's scans exceed maxTraceBytes",
          at)
      let rest = m.stride - ScanHeaderSize
      var full: bool
      if r.headersOnly:
        full = r.input.skip(rest) == int64(rest)
      else:
        let old = m.data.len
        m.data.setLen old + m.stride
        for i in 0..<ScanHeaderSize: m.data[old + i] = head[i]
        full = rest == 0 or
          r.input.readAvail(m.data.toOpenArray(old + ScanHeaderSize, old + m.stride - 1)) == rest
        if not full: m.data.setLen old
      if full:
        let h = scanHeader(head)
        if h.byte8 != 0:
          r.note(sevWarning, dcBadValue, "timing word byte 8 is " & $h.byte8 & ", not 0",
            at + 7, r.loc(field = "scan.timingWord"))
        m.heads.add h
      else:
        r.note(sevWarning, dcTruncated, "the last scan is cut short; it is dropped", at,
          r.loc(field = "scan"))
        going = false

proc splitScanTypes(r: var SegdReader) =
  # The scans of each scan type: the DP bit toggles at each new scan type;
  # without such toggles, the channel set windows decide.
  template rec: untyped = r.record
  template m: untyped = r.mux
  let n = m.heads.len
  let nST = rec.scanTypes.len
  var toggles: seq[int]
  for i in 1..<n:
    if m.heads[i].dp != m.heads[i - 1].dp: toggles.add i
  var starts = @[0]
  if nST > 1 and toggles.len == nST - 1:
    starts.add toggles
  else:
    if nST > 1:
      r.note(sevWarning, dcInconsistent, "the start-of-scan DP bit changes " & $toggles.len &
        " times, not at each of the " & $nST & " scan types; scan types are split by their " &
        "channel set windows", m.offset, r.loc(field = "scan.dp"))
    elif toggles.len > 0:
      r.note(sevWarning, dcInconsistent, "the start-of-scan DP bit changes in a record with " &
        "one scan type", m.offset, r.loc(field = "scan.dp"))
    for st in 0 ..< nST - 1:
      # Read before `add`: `starts.add f(starts[^1])` may take the element's
      # address, then grow (and free) the seq (13.3 R4-3, a use-after-free).
      let last = starts[^1]
      starts.add min(n, last + max(0, rec.windowScans(st)))
  for st in 0..<nST:
    let a = starts[st]
    let b = if st + 1 < nST: starts[st + 1] else: n
    m.first.add a
    m.count.add b - a
    let w = rec.windowScans(st)
    if w >= 0 and w != b - a:
      r.note(sevInfo, dcInconsistent, "scan type " & $(st + 1) & " has " & $(b - a) &
        " scans, its channel set window gives " & $w & "; the traces have the scans' length",
        m.offset, r.loc(field = "csd.endTime"))

proc readMuxBody(r: var SegdReader) =
  # The scans of a multiplexed record, after its headers.
  template rec: untyped = r.record
  template m: untyped = r.mux
  m = MuxBody(offset: r.input.offset)
  for s in rec.scanTypes: m.layouts.add muxLayout(rec.gh1.formatCode, s.descriptors)
  m.stride = r.muxStride()
  r.walkScans()
  if m.heads.len == 0 and rec.traceCount > 0:
    raiseUnlocatable(dcBadValue, "the multiplexed record's data does not start with a " &
      "start-of-scan code", m.offset)
  r.splitScanTypes()
  for h in m.heads:
    if h.twi:
      m.timeBreakWindow = h.timing
      break

proc nextChannel(m: var MuxBody): bool =
  # Moves the cursor to the next channel, at or after it; false after the last.
  while m.st < m.layouts.len:
    if m.cs >= m.layouts[m.st].channelSets.len:
      inc m.st
      m.cs = 0
      m.ch = 0
    elif m.ch >= m.layouts[m.st].channelSets[m.cs].channels:
      inc m.cs
      m.ch = 0
    else:
      return true
  false

proc readMuxTrace(r: var SegdReader, t: var SegdTrace) =
  # The next channel of a multiplexed record, demultiplexed.
  template rec: untyped = r.record
  template m: untyped = r.mux
  if not m.nextChannel():
    raiseUnlocatable(dcInconsistent, "the multiplexed record has fewer channels than its " &
      "descriptors announce", m.offset)
  let (st, cs, ch) = (m.st, m.cs, m.ch)
  inc m.ch
  let l = m.layouts[st].channelSets[cs]
  template s: untyped = rec.scanTypes[st]
  if t.layout != slRev2: t = SegdTrace(layout: slRev2) # else its buffers are reused
  t.index = r.tracesRead
  t.scanType = st
  t.channelSet = cs
  t.offset = m.offset + int64(m.first[st]) * m.stride
  t.extensions.setLen 0
  t.ext1 = none(SegdTraceHeaderExt1)
  t.numSamples = m.count[st] * l.subscans
  let skew = if l.firstSample + ch < s.skew.len: s.skew[l.firstSample + ch] else: 0'u8
  let timing = if m.count[st] > 0: m.heads[m.first[st]].timing else: [0'u8, 0, 0]
  t.header = muxTraceHeader(rec.gh1, rec.gh2, s.descriptors[cs], ch, timing, skew,
    m.timeBreakWindow)
  if r.headersOnly or t.numSamples == 0:
    t.samples.setLen 0
  else:
    t.samples.setLen dataBytes(rec.format.get, t.numSamples)
    let a = m.first[st] * m.stride
    demuxChannel(rec.gh1.formatCode, m.data.toOpenArray(a, a + m.count[st] * m.stride - 1),
      m.stride, m.count[st], l, ch, t.samples, r.twosComplement8015)
  inc r.tracesRead

proc readRev2Headers(r: var SegdReader, gh2Offset: int64) =
  # After GH#1 and GH#2 (if any): source headers, then the scan type headers.
  template rec: untyped = r.record
  if rec.gh2.isSome:
    let g2 = rec.gh2.get
    if g2.blockNumber != 2:
      r.note(sevWarning, dcBadValue, "General Header #2 block number is " &
        $g2.blockNumber & ", not 2", gh2Offset + 18, r.loc(field = "gh2.blockNumber"))
    if SegdRevision(major: 2, minor: 1) < rec.revision:
      r.note(sevWarning, dcUnsupportedRevision, "revision " & $rec.revision &
        " read as Rev 2.1", gh2Offset + 10, r.loc(field = "gh2.revision"))
  for n in 3..rec.gh1.generalHeaderCount:
    let o = r.input.offset
    let g = r.readBlock[:SegdGeneralHeaderN]()
    if g.blockNumber != uint8(n):
      r.note(sevWarning, dcBadValue, "General Header #" & $n & " block number is " &
        $g.blockNumber, o + 18, r.loc(field = "gh" & $n & ".blockNumber"))
    if g.sourceSetNumber == 0:
      r.note(sevInfo, dcBadValue, "General Header #" & $n & " source set number is 0 " &
        "(spec: not valid; common in real files)", o + 19,
        r.loc(field = "gh" & $n & ".sourceSetNumber"))
    rec.sourceHeaders.add g
  r.readScanTypes()
  if rec.multiplexed: r.readMuxBody()

proc readRev3Headers(r: var SegdReader, gh2Offset: int64) =
  # After GH#1 and GH#2: GH#3, the other general header blocks, then the
  # scan type headers; the first trace starts a device block.
  template rec: untyped = r.record
  if rec.gh2Rev3.blockType != BlockTypeGeneralHeader2:
    r.note(sevWarning, dcBadValue, "General Header #2 block type is " &
      $rec.gh2Rev3.blockType & ", not 2", gh2Offset + 31, r.loc(field = "gh2.blockType"))
  if SegdRevision(major: 3, minor: 1) < rec.revision:
    r.note(sevWarning, dcUnsupportedRevision, "revision " & $rec.revision & " read as Rev 3.1",
      gh2Offset + 10, r.loc(field = "gh2.revision"))
  let nGh = rec.generalHeaderCount
  if nGh < 3 or nGh > MaxCount:
    raiseUnlocatable(dcBadValue, "a Rev 3 record needs General Header #3, but " & $nGh &
      " general header blocks are declared", rec.offset + 11)
  let o3 = r.input.offset
  rec.gh3 = r.readBlock[:SegdGeneralHeader3]()
  if rec.gh3.blockType != BlockTypeGeneralHeader3:
    r.note(sevWarning, dcBadValue, "General Header #3 block type is " & $rec.gh3.blockType &
      ", not 3", o3 + 31, r.loc(field = "gh3.blockType"))
  rec.generalBlocks = r.readBytes(SegdBlockSize * (nGh - 3))
  for (i, t) in blocks(rec.generalBlocks):
    if not isDefinedBlock(t):
      r.note(sevWarning, dcUnknownBlock, "general header block of undefined type 0x" &
        toHex(t) & " kept raw", o3 + 32 + i + 31, r.loc(field = "gh.blockType"))
  r.readScanTypes()
  # From the blocks read, not medium offsets (tape images interleave markers).
  let computed = rec.headerBytes
  if rec.gh3.headerSize != 0 and int64(rec.gh3.headerSize) != computed:
    r.note(sevWarning, dcInconsistent, "General Header #3 header size is " &
      $rec.gh3.headerSize & ", the header blocks take " & $computed & " bytes", o3 + 24,
      r.loc(field = "gh3.headerSize"))
  if rec.traceCount > 0: r.skipToBlockEnd()

proc readRecordHeaders(r: var SegdReader, index: int) =
  # GH#1 and GH#2 decide the layout; the record is then read in it.
  let offset = r.input.offset
  let gh1 = r.readBlock[:SegdGeneralHeader1]()
  r.record = SegdRecord(layout: slRev2, index: index, offset: offset, gh1: gh1)
  r.reportBcd(gh1, "gh1", offset)
  let o = r.input.offset
  if gh1.generalHeaderCount < 2:
    r.readRev2Headers(o) # Rev 0: no GH#2
  else:
    var b: array[SegdBlockSize, byte]
    r.input.readExactly(b)
    let revision = SegdRevision(major: b[10], minor: b[11]) # GH#2 bytes 11-12
    if revision.major >= 3:
      r.record = SegdRecord(layout: slRev3, index: index, offset: offset, gh1: gh1,
        revision: revision, gh2Rev3: decodeBlock[SegdGeneralHeader2Rev3](b))
      r.readRev3Headers(o)
    else:
      r.record.revision = revision
      r.record.gh2 = some(decodeBlock[SegdGeneralHeader2](b))
      r.readRev2Headers(o)

# ----------------------------------------------------------------- traces --

proc readSamples(r: var SegdReader, t: var SegdTrace) =
  # The trace's sample bytes, once `numSamples` is known.
  template rec: untyped = r.record
  let f = rec.format.get
  if f == sd8015 and t.numSamples mod 4 != 0:
    r.note(sevWarning, dcBadValue, "format 8015 needs a multiple of 4 samples, the " &
      "trace has " & $t.numSamples, t.offset, r.loc(t.index, t.channelSet, "trace.numSamples"))
  let nbytes = dataBytes(f, t.numSamples)
  if int64(nbytes) > r.maxTraceBytes:
    raiseUnlocatable(dcBadValue, "trace of " & $t.numSamples & " samples (" & $nbytes &
      " bytes) exceeds maxTraceBytes; the sample count is probably corrupt", t.offset)
  if r.headersOnly:
    t.samples.setLen 0
    r.input.skipExactly(nbytes)
  else:
    r.input.readInto(t.samples, nbytes)
  inc r.tracesRead

proc readRev2TraceRest(r: var SegdReader, t: var SegdTrace, the: int) =
  # After the demux header: extension blocks and the sample count.
  template rec: untyped = r.record
  if the > 15:
    r.note(sevWarning, dcBadValue, "trace header extension count " & $the &
      " exceeds 15", t.offset + 9, r.loc(t.index, field = "trace.traceHeaderExtensions"))
  t.ext1 = none(SegdTraceHeaderExt1)
  var own = -1 # the sample count of Trace Header Extension #1; -1 without one
  if the >= 1:
    let e = r.readBlock[:SegdTraceHeaderExt1]()
    t.ext1 = some(e)
    if the > 1: r.input.readInto(t.extensions, SegdBlockSize * (the - 1))
    own = int(e.samplesPerTrace)
  if own > 0:
    t.numSamples = own
  elif t.channelSet >= 0:
    # No extension: the spec gives no rule; (TE - TF) / SI matches real data.
    # The same for an extension whose count the writer left at 0: taken as a
    # trace without samples, its samples would be read as the next header.
    template c: untyped = rec.scanTypes[t.scanType].descriptors[t.channelSet]
    let si = c.sampleIntervalMs(rec.gh1)
    let window = if si > 0: int(round((c.endTimeMs - c.startTimeMs) / si)) else: -1
    if own == 0:
      t.numSamples = max(window, 0)
      if window > 0:
        r.note(sevWarning, dcInconsistent, "Trace Header Extension #1 gives 0 samples; " &
          "using the " & $window & " of the channel set's window", t.offset + 20 + 7,
          r.loc(t.index, t.channelSet, "ext1.samplesPerTrace"))
    elif si <= 0:
      raiseUnlocatable(dcBadValue, "trace has no sample count and its sample interval is 0",
        t.offset)
    elif window < 0:
      raiseUnlocatable(dcBadValue, "channel set ends (" & $c.endTimeMs &
        " ms) before it starts (" & $c.startTimeMs & " ms), so the trace length is unknown",
        t.offset)
    else:
      t.numSamples = window
  elif own == 0:
    t.numSamples = 0
  else:
    raiseUnlocatable(dcInconsistent, "trace has no Trace Header Extension and no channel " &
      "set descriptor, so its length is unknown", t.offset)

proc readRev3TraceRest(r: var SegdReader, t: var SegdTrace, the: int) =
  # After the demux header: extension blocks (THE#1 required) and the
  # sample count.
  template rec: untyped = r.record
  let csdNs = if t.channelSet >= 0:
                int(rec.scanTypes[t.scanType].descriptorsRev3[t.channelSet].numSamples)
              else: -1
  t.ext1Rev3 = none(SegdTraceHeaderExt1Rev3)
  if the >= 1:
    let e = r.readBlock[:SegdTraceHeaderExt1Rev3]()
    t.ext1Rev3 = some(e)
    if e.blockType != BlockTypeTraceHeaderExt1:
      r.note(sevWarning, dcBadValue, "the first trace header extension has block type 0x" &
        toHex(e.blockType) & ", not 0x40", t.offset + 20 + 31,
        r.loc(t.index, t.channelSet, "ext1.blockType"))
    if the > 1: r.input.readInto(t.extensions, SegdBlockSize * (the - 1))
    t.numSamples = int(e.numSamples)
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

proc readTraceBody(r: var SegdReader, t: var SegdTrace) =
  template rec: untyped = r.record
  r.skipTracePadding()
  if t.layout != rec.layout: t = SegdTrace(layout: rec.layout) # else its buffers are reused
  t.index = r.tracesRead
  t.offset = r.input.offset
  t.extensions.setLen 0
  t.header = r.readBlock[:SegdTraceHeader]()
  r.reportBcd(t.header, "trace", t.offset)
  let found = rec.findChannelSet(t.header, r.lastChannelSet)
  if found.isSome:
    r.lastChannelSet = found.get
    t.scanType = found.get.scanType
    t.channelSet = found.get.channelSet
  else:
    t.scanType = scanTypeIndex(rec, t.header)
    t.channelSet = -1
  let the = int(t.header.traceHeaderExtensions)
  if t.channelSet < 0:
    if not r.csdWarned:
      r.csdWarned = true
      r.note(sevWarning, dcInconsistent, "trace header names scan type " &
        $t.header.scanTypeNumber & ", channel set " & $t.header.channelSetNumber &
        ", which no channel set descriptor has (reported once per record)", t.offset + 2,
        r.loc(t.index, field = "trace.channelSetNumber"))
  else:
    template s: untyped = rec.scanTypes[t.scanType]
    let declared = case s.layout
      of slRev2: int(s.descriptors[t.channelSet].traceHeaderExtensions)
      of slRev3: int(s.descriptorsRev3[t.channelSet].traceHeaderExtensions)
    if declared != the:
      r.note(sevWarning, dcInconsistent, "trace has " & $the & " header extensions, " &
        "its channel set descriptor says " & $declared, t.offset + 9,
        r.loc(t.index, t.channelSet, "trace.traceHeaderExtensions"))
  case rec.layout
  of slRev2: r.readRev2TraceRest(t, the)
  of slRev3: r.readRev3TraceRest(t, the)
  r.readSamples(t)

proc readRev3Trailer(r: var SegdReader) =
  # The general trailer: GH#2 bytes 13-16 blocks; when unknown (FFFFFFFF),
  # GH#3 recordSize - dataSize, else description-block groups as long as they
  # last.
  template rec: untyped = r.record
  let n = rec.gh2Rev3.generalTrailerBlocks
  if n == 0: return
  r.skipToBlockEnd()
  if n != UnknownTrailerBlocks:
    rec.trailerRev3 = r.readArea(SegdBlockSize * int64(n), "trailer")
  elif rec.gh3.recordSize > rec.gh3.dataSize and rec.gh3.dataSize > 0:
    let diff = rec.gh3.recordSize - rec.gh3.dataSize
    if diff > uint64(high(int64) div 2):
      raiseUnlocatable(dcBadValue, "General Header #3 sizes give a trailer of " & $diff &
        " bytes; the record end cannot be located", r.input.offset)
    rec.trailerRev3 = r.readArea(int64(diff), "trailer")
  else:
    var desc: array[SegdBlockSize, byte]
    var going = true
    while going:
      let got = r.input.readAvail(desc)
      # A description block: type 0x70, binary/ASCII flag 1 or 2, bytes 3-4
      # zero (so a following record's GH#1 with EX = 70 is not taken).
      if got == SegdBlockSize and desc[31] == BlockTypeTrailerDescription and
          desc[1] in {1'u8, 2} and desc[2] == 0 and desc[3] == 0:
        rec.trailerRev3.add desc
        let d = decodeBlock[SegdTrailerDescription](desc)
        rec.trailerRev3.add r.readArea(SegdBlockSize * int64(d.blockSize), "trailer")
      else:
        r.input.unread(desc.toOpenArray(0, got - 1))
        going = false

proc readRev2Trailer(r: var SegdReader) =
  template rec: untyped = r.record
  let n = if rec.gh2.isSome: int(rec.gh2.get.generalTrailerBlocks) else: 0
  for i in 1..n:
    let o = r.input.offset
    let b = r.readBlock[:SegdTrailerBlock]()
    if b.channelType != 0xC:
      r.note(sevWarning, dcBadValue, "general trailer block " & $i &
        " has channel type " & $b.channelType & ", not 0xC", o + 10,
        r.loc(field = "trailer.channelType"))
    rec.trailer.add b

proc readRecordTrailer(r: var SegdReader) =
  case r.record.layout
  of slRev2: r.readRev2Trailer()
  of slRev3: r.readRev3Trailer()
  r.skipFixedPadding()

proc readTrace*(r: var SegdReader, t: var SegdTrace): bool =
  ## Reads the next trace of the current record into `t`. Returns false after
  ## the record's last trace (its general trailer is then in `record`), or
  ## when the read had to stop (see `log`).
  if not r.inRecord or r.done:
    return false
  if r.tracesRead >= r.record.traceCount:
    r.inRecord = false
    # A trailer that cannot be read leaves the next record unlocated.
    if not r.log.tryRecordFatal(r.loc(field = "trailer"), r.readRecordTrailer()): r.stop()
    return false
  let ok = r.log.tryRecordFatal(r.loc(r.tracesRead)):
    if r.record.multiplexed: r.readMuxTrace(t) else: r.readTraceBody(t)
  if ok:
    result = true
  else:
    r.inRecord = false
    r.stop()
    result = false

proc readToc(r: var SegdReader) =
  # A Rev 3 Table of Contents file (between file marks on tape).
  var head: seq[byte]
  r.input.readInto(head, TocHeaderSize)
  let n = tocEntryCount(head)
  if n < 0 or n > 10_000_000:
    raiseUnlocatable(dcBadValue, "the Table of Contents entry count is unreadable",
      r.input.offset)
  var entries: seq[byte]
  if int64(n) * TocEntrySize > r.maxHeaderBytes:
    discard r.readArea(int64(n) * TocEntrySize, "toc") # skipped; header kept
  else:
    r.input.readInto(entries, int64(n) * TocEntrySize)
  head.add entries
  r.toc.add decodeToc(head)
  if r.byteStream: r.skipFixedPadding() else: discard r.input.skipRecordRest()

proc nextRecord*(r: var SegdReader): bool =
  ## Reads the next shot record's headers into `record`. Traces left unread
  ## in the previous record are skipped. Returns false at the end of the data
  ## (or when the read had to stop; see `log`).
  if r.inRecord:
    var t: SegdTrace
    while r.readTrace(t): discard
  if r.done:
    return false
  # To the next record, over tape marks and Table of Contents files: in a
  # loop, since a call per TOC file overflowed the stack on a run of them
  # (50000 files of 448 bytes).
  var toc = true
  while toc:
    var more = false
    let ok = r.log.tryRecordFatal(Location(file: r.name, record: r.records)):
      while r.input.stoppedAt == rkTapeMark: r.input.skipTapeMark()
      more = r.input.atData
      if more:
        var peek: array[13, byte]
        let got = r.input.readAvail(peek)
        r.input.unread(peek.toOpenArray(0, got - 1))
        toc = isTocFile(peek.toOpenArray(0, got - 1))
    if not ok or not more or
        (toc and not r.log.tryRecordFatal(Location(file: r.name, field: "toc"), r.readToc())):
      r.stop()
      return false
  let index = r.records
  inc r.records
  r.tracesRead = 0
  r.csdWarned = false
  r.lastChannelSet = SegdChannelSetRef(scanType: -1, channelSet: -1)
  r.mux = MuxBody()
  r.record = SegdRecord(index: index) # not the previous record if GH#1 cannot be read
  if r.log.tryRecordFatal(r.loc(), r.readRecordHeaders(index)):
    r.inRecord = true
    result = true
  else:
    r.stop()
    result = false

func isDone*(r: SegdReader): bool {.inline.} =
  ## True once the stream has ended (or the read had to stop).
  r.done

func headersOnly*(r: SegdReader): bool {.inline.} =
  ## True when the reader skips sample bytes (see `openSegd`).
  r.headersOnly

proc decodeInto*[T: SegdSampleType](rec: SegdRecord, t: SegdTrace, dst: var Tensor[T], row: int,
    twosComplement8015 = false) =
  ## Decodes the trace's samples into row `row` of `dst` (recorded values;
  ## multiply by `descaleFactor` for millivolts). Raises `SegFormatError`
  ## for an undecodable format or a trace read with `headersOnly`.
  if rec.format.isNone:
    raiseFormat("sample format " & $rec.gh1.formatCode & " is not decodable")
  let f = rec.format.get
  if t.samples.len < dataBytes(f, t.numSamples):
    raiseFormat("trace " & $t.index & " holds no samples (read with headersOnly)")
  dst.decodeTrace(row, f, t.samples, min(t.numSamples, dst.shape[1]), twosComplement8015)

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
    label*: Option[SegdStorageUnitLabel] ## The storage unit label, if any.
    records*: seq[SegdRecordData]
    log*: DiagLog                        ## The reader's diagnostics.

proc readSegd*(src: RecordSource, twosComplement8015 = false, headersOnly = false): SegdData =
  ## Reads every record of a SEG-D stream into memory. Meant for small files
  ## and tests; large files should be walked record by record.
  ##
  ## With `headersOnly`, every header is read and the sample bytes are
  ## skipped (seeking on disk): each record's `samples` is `[traces, 0]` and
  ## each trace's `samples` is empty.
  var r = openSegd(src, twosComplement8015, headersOnly)
  while r.nextRecord():
    var d = SegdRecordData()
    var t: SegdTrace
    var maxNs = 0
    while r.readTrace(t):
      maxNs = max(maxNs, t.numSamples)
      d.traces.add t
    d.record = r.record
    d.samples = newTraceTensor[float32](d.traces.len, if headersOnly: 0 else: maxNs)
    if not headersOnly:
      for i, tr in d.traces:
        discard r.log.tryRecord(Location(file: src.name, record: d.record.index, trace: i),
          d.record.decodeInto(tr, d.samples, i, twosComplement8015))
    result.records.add d
  result.label = r.label
  result.log = r.log

proc readSegd*(path: string, twosComplement8015 = false, headersOnly = false): SegdData =
  ## Reads a SEG-D disk file into memory; see `readSegd(RecordSource)`.
  var src: RecordSource
  if result.log.tryRecord(Location(file: path), (src = openDiskSource(path))):
    try:
      result = readSegd(src, twosComplement8015, headersOnly)
    finally:
      src.close()

proc readSegdHeaders*(path: string, twosComplement8015 = false): SegdData =
  ## Every header of a SEG-D disk file, samples skipped (`readSegd` with
  ## `headersOnly`).
  readSegd(path, twosComplement8015, headersOnly = true)
