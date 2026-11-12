## Writing a processed result "like" its input (task 14.3d): the same
## standard, revision, byte order and headers, with new samples.
##
## ```nim
## var f = openSeismic("line.sgy")
## var w = openSeismicWriter("line_gain.sgy", like = f)
## for i in 0 ..< f.len:
##   let x = 2'f32 * f.readTraces(i..i) # a [1, maxSamples] tensor
##   w.writeTrace(f, i, x, 0)            # trace i's headers, the row's samples
## let log = w.close()                 # renames the output into place
## ```
##
## `openSeismicWriter` takes the file-level headers from `like`: the SEG-Y
## tape label, textual, binary and extended textual headers and trailer; the
## SEG-D storage unit label; the SEG-2 File Descriptor Block. `writeTrace`
## copies trace `trace` of `src` (usually `like` itself) with its headers
## unchanged, except for what the new samples change:
##
## - the sample format, when one is chosen (`segyFormat`, `segdFormat`,
##   `seg2Format`; "keep" by default);
## - SEG-Y and SEG-2: the sample count, which may differ from the input's.
##   SEG-Y updates the trace header (Trace Header Extension 1 when it holds
##   the count or the count exceeds 65535) and the binary header, which gets
##   the count of the traces written (the largest when they differ); a
##   fixed-length file needs one count for all traces. The Rev 2 trace
##   count (binary bytes 3513-3520), when the input declares one, becomes
##   the number written.
##
## `overrides` (`HeaderOverride`) change named header fields of the written
## trace, so the input trace serves as a template: a stacked trace with a
## source trace's headers and its own CDP, fold, offset and coordinates.
##
## Without a template: `openSeismicWriter(path, SegyOutputOptions(...))`
## writes a new SEG-Y file whose file headers come from the options, and
## `writeTrace(w, keys, samples, overrides)` builds each trace's headers
## from its `TraceKeys` (e.g. a stack of SEG-D or SEG-2 data; any SEG-Y
## writer takes these traces).
##
## SEG-D rule: records are written whole, and each record's traces in input
## order. A record starts with its first trace and ends when a trace of
## another record arrives, or on `close`; it must then have all its traces
## (`ValueError` otherwise: write the missing traces, or drop the writer).
## Records may be skipped, repeated or reordered. Each trace keeps its sample
## count (the channel set descriptors hold it). The record headers and
## trailer come from the trace's own record in `src`; a new format sets the
## format code and, for Rev 3, the General Header #3 data and record sizes.
## Multiplexed SEG-D input is refused (convert it first).
##
## The output goes to a temporary file next to `path`, renamed when `close`
## succeeds. A writer dropped without `close`, or whose `close` raises,
## leaves no output file; nor does one whose `writeTrace` raised `IOError`
## (a full disk): it is closed, and its `close` raises `ValueError`. The per-standard writers validate as usual:
## spec-invalid output raises `SegFormatError` (see `segy/writer`,
## `segd/writer`, `seg2/writer`); a value the format cannot hold raises
## `SegFormatError` from the encoder and writes nothing. Caller errors (a
## trace out of range, another standard, a closed file, a broken SEG-D
## record rule) raise `ValueError`.

import std/[importutils, math, options, os]
import ../common/[diagnostics, endians, outputfile, seismickind]
import ../io/[records, diskio]
import ../segy/[reader as segyreader, writer as segywriter, binheader, traceheader,
  samples as segysamples, textheader, exttext]
import ../segd/[reader as segdreader, writer as segdwriter]
import ../seg2/[reader as seg2reader, writer as seg2writer]
import ../convert
import std/strutils
import ./[traceindex, fieldvalues, keytypes]
import ../common/tensors
import ../private/[tensorrows, fieldaccess, segyencode]
import ../version

type
  HeaderOverride* = object
    ## A header field to change in a trace written from a template trace
    ## (`writeTrace`'s `overrides`).
    name*: string
      ## `trace.<field>` or `ext1.<field>`, with the field names of the
      ## header types (as `HeaderEditor.setTraceField`); SEG-2:
      ## `trace.<KEYWORD>`, a trace string.
    value*: FieldValue ## The value as stored (SEG-Y: before its scalar).

  SegyOutputOptions* = object
    ## A SEG-Y file not modelled on an input (`openSeismicWriter(path,
    ## opts)`). The defaults give Rev 2.1, big-endian, IEEE float32 samples
    ## and an EBCDIC textual header.
    revision*: SegyRevision = SegyRevision(major: 2, minor: 1)
    byteOrder*: ByteOrder = boBig ## Little-endian and pair-swapped need Rev 2.
    format*: SegyTargetFormat = st5 ## The sample format; `stKeep` means 5 (IEEE float32).
    textEncoding*: TextEncoding = teEbcdic
    text*: seq[string]
      ## Textual header lines, cards 1-38 (longer ones are cut to the card,
      ## characters outside ASCII 32-126 become spaces). Empty: one card
      ## naming the writer. Cards 39 and 40 are the revision and
      ## `END TEXTUAL HEADER`.
    traceSorting*: int16 = 0 ## Binary 3229-3230: 1 as recorded, 2 CDP ensembles, 4 stack, ...
    measurementSystem*: int16 = 0 ## Binary 3255-3256: 1 metres, 2 feet, 0 unknown.

  NullSink = ref object of RecordSink
    ## Discards what it is given: `openSeismicWriter` validates the SEG-Y
    ## file headers with it before the first trace fixes the sample count.

  WriterState = object
    kind: SeismicKind
    path, tmp: string     ## The output, and its temporary file ("" once gone).
    open: bool            ## Set by `openSeismicWriter`; false once closed (and when zeroed).
    written: int
    sink: RecordSink      ## SEG-Y and SEG-D output (nil once closed).
    # SEG-Y
    segyFile: SegyFile    ## The file headers to write.
    segy: SegyWriter
    segyStarted: bool     ## `segy` is open on `sink` (from the first trace).
    segyFixed: bool       ## Fixed-length traces (Rev 1+, binary 3503 = 1).
    segyCount: int        ## The sample count of every trace so far; -1 none, -2 mixed.
    segyMax: int          ## The largest sample count so far.
    segyNumTraces: uint64 ## The input's declared Rev 2 trace count.
    segyTrace: SegyTrace  ## Reused.
    segyFresh: bool       ## Opened from `SegyOutputOptions`: the first trace sets the interval.
    # SEG-D
    segd: SegdWriter
    segdFormat: Option[SegdSampleFormat] ## none: each record's own.
    inRecord: bool
    recPath: string       ## The record in progress: its file, index and traces.
    recIndex, recFirst, recLast, nextTrace: int
    recFormat: SegdSampleFormat
    # SEG-2
    seg2: Seg2Writer
    seg2Format: Option[Seg2SampleFormat] ## none: each trace's own.

  SeismicWriter* = object
    ## Writes traces "like" an input file; create with `openSeismicWriter`,
    ## finish with `close`. Not copyable.
    s: WriterState

proc refuse(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

func headerOverride*(name: string, value: FieldValue): HeaderOverride {.inline.} =
  ## A `HeaderOverride` of field `name`.
  HeaderOverride(name: name, value: value)

func headerOverride*(name: string, value: SomeNumber | string): HeaderOverride {.inline.} =
  ## A `HeaderOverride` of field `name` with a plain number or text.
  HeaderOverride(name: name, value: toFieldValue(value))

proc splitName(o: HeaderOverride): (string, string) =
  let dot = o.name.find('.')
  if dot <= 0 or dot == o.name.len - 1:
    refuse(o.name & ": expected <block>.<field>")
  (o.name[0 ..< dot], o.name[dot + 1 .. ^1])

proc setOverride[H](h: var H, kind: HeaderBlock, field: string, o: HeaderOverride) =
  if field in structural(kind):
    refuse(o.name & ": changes the file's structure (sizes or counts); it cannot be overridden")
  var err = ""
  if not setByName(h, field, o.value, err): refuse(o.name & ": " & err)

method writeRecordImpl(s: NullSink; data: openArray[byte]) {.raises: [].} =
  s.offset += data.len

method writeTapeMarkImpl(s: NullSink) {.raises: [].} = discard

proc releaseOutput(s: WriterState) {.raises: [].} =
  # Closes what is still open and removes the temporary file, mutating
  # nothing: `=destroy` calls it, `discardOutput` adds the bookkeeping.
  if s.sink != nil:
    try: s.sink.close()
    except CatchableError: discard
  privateAccess(Seg2Writer)
  if s.seg2.open: s.seg2.file.close() # the output is dropped: no pointers to write
  if s.tmp.len > 0: discard tryRemoveFile(s.tmp)

proc discardOutput(s: var WriterState) {.raises: [].} =
  # `releaseOutput`, then marks it all gone so that it runs once.
  s.releaseOutput()
  s.open = false
  s.sink = nil
  privateAccess(Seg2Writer)
  s.seg2.open = false
  s.tmp = ""

proc `=destroy`(w: SeismicWriter) =
  if w.s.open: w.s.releaseOutput()
  # A plain object field has only the generic `=destroy(var T)`; the
  # address is taken for that call alone, nothing is mutated before it.
  `=destroy`((addr w.s)[])

proc `=copy`(dst: var SeismicWriter, src: SeismicWriter) {.error.}
  # A copy would share the temporary file and finish it twice.
proc `=dup`(src: SeismicWriter): SeismicWriter {.error.}

func len*(w: SeismicWriter): int {.inline.} =
  ## Traces written so far.
  w.s.written

func path*(w: SeismicWriter): lent string {.inline.} =
  ## The output path (written by `close`).
  w.s.path

# ------------------------------------------------------------------ open --

{.push warning[HoleEnumConv]: off.}
func toSampleFormat(t: SegyTargetFormat): SampleFormat {.inline.} =
  # The ordinal of a target other than `stKeep` is its format code.
  SampleFormat(ord(t))
{.pop.}

func definedIn(f: SegdSampleFormat, r: SegdRevision): bool =
  # Whether format `f` exists in revision `r` (8080 from 3.0, 90xx from 3.1).
  if f.isLittleEndian: SegdRevision(major: 3, minor: 1) <= r
  elif f == sd8080: r.major >= 3
  else: true

proc openSegy(s: var WriterState, like: SeismicFile, format: SegyTargetFormat) =
  var f = like.index.segy
  let fmt = if format == stKeep: f.format else: some(format.toSampleFormat)
  if fmt.isNone:
    refuse("the input's SEG-Y format code " & $f.binary.formatCode & " is undefined; " &
      "choose a segyFormat")
  if fmt.get.isRev2Format and f.revision.major < 2:
    refuse("SEG-Y format " & $ord(fmt.get) & " needs Rev 2; the input is Rev " & $f.revision)
  if sampleSize(fmt.get) == 3 and f.byteOrder == boPairSwapped:
    refuse("the 3-byte SEG-Y format " & $ord(fmt.get) & " cannot be pair-swapped")
  f.binary.formatCode = int16(ord(fmt.get))
  f.format = fmt
  s.segyNumTraces = f.binary.numTraces
  f.binary.numTraces = 0 # set by `close` when the input declares one
  s.segyFixed = f.revision.major >= 1 and f.binary.fixedLengthTraces == 1
  s.segyCount = -1
  # Validate now; the real writer opens at the first trace.
  discard openSegyWriter(NullSink(name: s.path), f, initSegyWriteOptions(f))
  s.segyFile = f
  s.sink = openDiskSink(s.tmp)

proc checkGroups(src: SeismicFile, first, last: int) =
  # 8015 packs 4 samples into 10 bytes, and a SEG-D trace keeps its count:
  # a trace of another length cannot go into that format.
  for i in first..last:
    if src.index.entries[i].numSamples mod 4 != 0:
      refuse("SEG-D format 8015 holds samples in groups of 4; trace " & $i & " of " & src.path &
        " has " & $src.index.entries[i].numSamples)

proc openSegd(s: var WriterState, like: SeismicFile, format: SegdTargetFormat) =
  if format != tfKeep:
    let fmt = segdSampleFormats[ord(format) - 1]
    for rec in like.index.segdRecords:
      if not fmt.definedIn(rec.revision):
        refuse("SEG-D format " & $format & " is not defined in Rev " & $rec.revision &
          " (record " & $rec.index & ")")
    if fmt == sd8015: checkGroups(like, 0, like.len - 1)
    s.segdFormat = some(fmt)
  s.sink = openDiskSink(s.tmp)
  s.segd = openSegdWriter(s.sink, SegdWriteOptions(), like.index.segdLabel)

proc openSeismicWriter*(path: string, like: SeismicFile, segyFormat = stKeep,
    segdFormat = tfKeep, seg2Format = s2tKeep): SeismicWriter =
  ## A writer of a file at `path` in `like`'s standard, revision and byte
  ## order, with `like`'s file-level headers (see the module doc). The
  ## sample format is the input's unless `segyFormat`, `segdFormat` or
  ## `seg2Format` (for `like`'s standard only) names one. Only `like`'s
  ## index is used, so it may be closed. Raises `ValueError` for an unrecognized or
  ## multiplexed SEG-D `like`, a format for another standard or one the
  ## revision lacks, SEG-D 8015 for traces whose sample count is not a
  ## multiple of 4, or `path` being `like`'s file; `SegFormatError` for
  ## file headers the writer refuses; `IOError` when the output cannot be
  ## created.
  let kind = like.kind
  if kind == skUnknown: refuse("the file " & like.path & " is not SEG-Y, SEG-D or SEG-2")
  if like.demuxPath.len > 0:
    refuse(like.path & " holds multiplexed SEG-D; convert it to a demultiplexed file " &
      "first (`convertSegdRevision`)")
  if (segyFormat != stKeep and kind != skSegy) or (segdFormat != tfKeep and kind != skSegd) or
      (seg2Format != s2tKeep and kind != skSeg2):
    refuse("a sample format was chosen for another standard than the input's (" & $kind & ")")
  var same = false
  try: same = fileExists(path) and sameFile(like.path, path)
  except OSError: discard
  if same: refuse("the output " & path & " is the input file")
  result = SeismicWriter(s: WriterState(kind: kind, path: path, tmp: createTempFor(path),
    open: true))
  try:
    case kind
    of skSegy: result.s.openSegy(like, segyFormat)
    of skSegd: result.s.openSegd(like, segdFormat)
    of skSeg2:
      if seg2Format != s2tKeep: result.s.seg2Format = toSeg2Format(ord(seg2Format))
      result.s.seg2 = openSeg2Writer(result.s.tmp, like.index.seg2)
    of skUnknown: discard
  except CatchableError:
    result.s.discardOutput()
    raise

func textCard(s: string): string =
  # A line as card text: printable ASCII only, cut to the card after its prefix.
  result = s[0 ..< min(s.len, CardWidth - 4)]
  for ch in result.mitems:
    if ch notin {' '..'~'}: ch = ' '

proc openSeismicWriter*(path: string, opts: SegyOutputOptions): SeismicWriter =
  ## A writer of a new SEG-Y file at `path`, with file headers from `opts`
  ## rather than an input file, for traces built from `TraceKeys`
  ## (`writeTrace(w, keys, samples)`): e.g. a stack of SEG-D or SEG-2 data.
  ## The binary header's sample interval is the first trace's and its count
  ## the largest of the traces written (set by `close`); traces are
  ## variable-length. Rev 2 traces carry Trace
  ## Header Extension 1. Raises `ValueError` for a format the revision lacks
  ## (8-byte and 3-byte formats need Rev 2), a 3-byte format pair-swapped,
  ## a byte order other than big-endian before Rev 2, or a revision other
  ## than 0, 1, 2.0 or 2.1; `IOError` when the output cannot be created.
  let rev = opts.revision
  if not (rev.major in 0'u8..1'u8 and rev.minor == 0 or rev.major == 2 and rev.minor <= 1):
    refuse("SEG-Y Rev " & $rev & " cannot be written (0, 1, 2.0 or 2.1)")
  let fmt = if opts.format == stKeep: sfFloat32 else: opts.format.toSampleFormat
  if fmt.isRev2Format and rev.major < 2:
    refuse("SEG-Y format " & $ord(fmt) & " needs Rev 2; the output is Rev " & $rev)
  if sampleSize(fmt) == 3 and opts.byteOrder == boPairSwapped:
    refuse("the 3-byte SEG-Y format " & $ord(fmt) & " cannot be pair-swapped")
  if rev.major < 2 and opts.byteOrder != boBig:
    refuse($opts.byteOrder & " output needs Rev 2 (only its byte-order marker declares it)")
  if opts.text.len > 38: refuse("the textual header holds 38 lines of text, not " & $opts.text.len)
  var f = SegyFile(byteOrder: opts.byteOrder, format: some(fmt), revision: rev,
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(opts.textEncoding))
  let lines = if opts.text.len > 0: opts.text else: @["WRITTEN BY parseSEG " & PackageVersion]
  for i, line in lines: f.text.setCard(i + 1, cardPrefix(i + 1) & line.textCard)
  f.text.setCard(39, cardPrefix(39) & (if rev.major >= 2: "SEG-Y_REV" & $rev
    elif rev.major == 1: "SEG Y REV1" else: ""))
  f.text.setCard(40, cardPrefix(40) & "END TEXTUAL HEADER")
  f.binary = SegyBinaryHeader(formatCode: int16(ord(fmt)), segyMajor: rev.major,
    segyMinor: rev.minor, traceSorting: opts.traceSorting,
    measurementSystem: opts.measurementSystem, sampleInterval: 1000, samplesPerTrace: 1)
  if rev.major >= 2:
    f.binary.byteOrderMarker = ByteOrderMarker
    f.binary.maxAddlTraceHeaders = 1
    f.extended.addEndText()
    f.binary.numExtTextHeaders = int16(f.extended.recordCount)
  result = SeismicWriter(s: WriterState(kind: skSegy, path: path, tmp: createTempFor(path),
    open: true, segyFresh: true, segyCount: -1))
  try:
    # Validate now (with a placeholder interval); the real writer opens at the first trace.
    discard openSegyWriter(NullSink(name: path), f, initSegyWriteOptions(f))
    result.s.segyFile = f
    result.s.sink = openDiskSink(result.s.tmp)
  except CatchableError:
    result.s.discardOutput()
    raise

# ----------------------------------------------------------------- SEG-Y --

proc setTraceCount(t: var SegyTrace, n: int) =
  # The trace headers' sample count.
  if not t.setSampleCount(n):
    refuse("a trace of " & $n & " samples needs Trace Header Extension 1 (SEG-Y Rev 2), " &
      "which this trace lacks")

proc setFileCount(b: var SegyBinaryHeader, n: int) =
  # The binary header's samples per trace.
  if n > int(high(uint16)) or (b.rulesRevision.major >= 2 and b.extSamplesPerTrace != 0):
    if b.rulesRevision.major < 2:
      refuse($n & " samples per trace need SEG-Y Rev 2")
    b.extSamplesPerTrace = uint32(n)
  b.samplesPerTrace = if n > int(high(uint16)): 0'u16 else: uint16(n)

proc loadSegyTrace(src: SeismicFile, trace: int, t: var SegyTrace) =
  # Trace `trace`'s headers from the map, as the reader gives them.
  let e = src.index.entries[trace]
  let mem = src.unsafeMemory
  let a = int(e.offset)
  let hb = int(e.headerBytes)
  if e.offset < 0 or e.offset + max(hb, TraceHeaderSize) > src.mappedSize:
    refuse("the headers of trace " & $trace & " lie outside the file")
  let order = src.index.segy.byteOrder
  t.header = decodeTraceHeader(mem.toOpenArray(a, a + TraceHeaderSize - 1), order)
  t.hasExt1 = hb >= 2 * TraceHeaderSize
  if t.hasExt1:
    t.ext1 = decodeTraceHeaderExt1(
      mem.toOpenArray(a + TraceHeaderSize, a + 2 * TraceHeaderSize - 1), order)
  let extra = max(hb - 2 * TraceHeaderSize, 0)
  t.proprietary.setLen extra
  if extra > 0: copyMem(addr t.proprietary[0], addr mem[a + 2 * TraceHeaderSize], extra)
  t.numSamples = int(e.numSamples)
  t.offset = e.offset

proc noteCount(s: var WriterState, n: int) =
  # A trace of `n` samples was written.
  s.segyCount = if s.segyCount == -1 or s.segyCount == n: n else: -2
  s.segyMax = max(s.segyMax, n)

proc startSegy(s: var WriterState) =
  s.segy = openSegyWriter(s.sink, s.segyFile, initSegyWriteOptions(s.segyFile))
  s.segyStarted = true

proc overrideSegy(t: var SegyTrace, overrides: openArray[HeaderOverride]) =
  for o in overrides:
    let (blk, field) = splitName(o)
    case blk
    of "trace": t.header.setOverride(hbSegyTrace, field, o)
    of "ext1":
      if not t.hasExt1: refuse(o.name & ": the trace has no Trace Header Extension 1")
      t.ext1.setOverride(hbSegyExt1, field, o)
    else: refuse(o.name & ": SEG-Y trace blocks are trace and ext1")

proc writeSegy[T: SampleType](s: var WriterState, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride]) =
  if s.segyFresh:
    # Its binary header (interval, Ext1 count) is made for traces from keys;
    # a template trace's headers would disagree with it.
    refuse("a writer opened from SegyOutputOptions takes traces from keys " &
      "(writeTrace(w, keys, samples)), not template traces")
  let n = samples.len
  template t: untyped = s.segyTrace
  loadSegyTrace(src, trace, t)
  t.overrideSegy(overrides)
  # Also when the headers do not say what the reader took: a Rev 0 trace
  # may give 0 samples and leave the count to the binary header.
  if n != t.numSamples or (not s.segyFixed and declaredSamples(t) != n): t.setTraceCount(n)
  if s.segyFixed:
    if not s.segyStarted: s.segyFile.binary.setFileCount(n)
    elif n != s.segyCount:
      refuse("the file has fixed-length traces (binary byte 3503) of " & $s.segyCount &
        " samples; trace " & $trace & " has " & $n)
  let fmt = s.segyFile.format.get
  t.samples.setLen n * sampleSize(fmt)
  encodeSamples(fmt, samples, t.samples, s.segyFile.byteOrder)
  t.numSamples = n
  t.index = s.written
  if not s.segyStarted: s.startSegy()
  s.segy.writeTrace(t)
  s.noteCount(n)

proc closeSegy(s: var WriterState, log: var DiagLog) =
  if not s.segyStarted: s.startSegy()
  s.segy.close()
  log.add s.segy.log
  s.sink.close()
  s.sink = nil
  # The binary header's counts, now known: the samples of every trace
  # written, the largest when they differ.
  var b = s.segyFile.binary
  if s.segyCount != -1 and uint32(s.segyMax) != b.effectiveSamplesPerTrace:
    b.setFileCount(s.segyMax)
  if s.segyNumTraces != 0: b.numTraces = uint64(s.written)
  if b != s.segyFile.binary:
    var bytes = newSeq[byte](BinaryHeaderSize)
    b.encode(bytes, s.segyFile.byteOrder)
    var f: File
    if not open(f, s.tmp, fmReadWriteExisting): raise newException(IOError, "cannot reopen " & s.tmp)
    try:
      f.setFilePos(s.segyFile.tapeLabel.len + TextHeaderSize)
      if f.writeBytes(bytes, 0, bytes.len) != bytes.len:
        raise newException(IOError, "cannot write the binary header of " & s.tmp)
    except IOError:
      f.close()
      raise
    closeChecked(f, s.tmp)

# ------------------------------------------------------- SEG-Y from keys --

proc writeSegyKeys[T: SampleType](s: var WriterState, k: TraceKeys, samples: openArray[T],
    overrides: openArray[HeaderOverride]) =
  let n = samples.len
  let dt = wholeInterval(k.intervalUs) # 1000.9999999999999 is 1001 (ms × 1000)
  if dt.isNaN or dt <= 0 or dt > 4.0e9:
    refuse("the keys give no usable sample interval (intervalUs " & $dt & ")")
  let rev = s.segyFile.revision
  if rev.major < 2 and dt != round(dt):
    refuse("SEG-Y Rev " & $rev & " holds whole-microsecond intervals, not " & $dt)
  if rev.major < 2 and dt > 65535:
    refuse("SEG-Y Rev " & $rev & " holds intervals up to 65535 µs, not " & $dt)
  if rev.major == 0 and abs(round(k.t0Ms)) > 32767:
    refuse("SEG-Y Rev 0 holds start times of up to ±32767 ms (it has no time scalar), not " &
      $k.t0Ms)
  template b: untyped = s.segyFile.binary
  let ext1 = rev.major >= 2 and b.maxAddlTraceHeaders > 0
  if n > int(high(uint16)) and not ext1:
    refuse("a trace of " & $n & " samples needs Trace Header Extension 1 (SEG-Y Rev 2)")
  template t: untyped = s.segyTrace
  t.keysToHeaders(k, n, s.written + 1, rev, ext1)
  t.overrideSegy(overrides)
  if s.segyFixed:
    if not s.segyStarted: b.setFileCount(n)
    elif n != s.segyCount:
      refuse("the file has fixed-length traces (binary byte 3503) of " & $s.segyCount &
        " samples; this trace has " & $n)
  if s.segyFresh and not s.segyStarted:
    b.setFileCount(n)
    let whole = dt == round(dt) and dt <= 65535
    b.sampleInterval = uint16(if whole: dt else: 0)
    if not whole: b.extSampleInterval = dt
  let fmt = s.segyFile.format.get
  t.samples.setLen n * sampleSize(fmt)
  encodeSamples(fmt, samples, t.samples, s.segyFile.byteOrder)
  t.numSamples = n
  t.index = s.written
  if not s.segyStarted: s.startSegy()
  s.segy.writeTrace(t)
  s.noteCount(n)

# ----------------------------------------------------------------- SEG-D --

proc loadSegdTrace(src: SeismicFile, trace: int, rec: SegdRecord, first: int): SegdTrace =
  # Trace `trace`'s headers from the map, as the reader gives them.
  let e = src.index.entries[trace]
  let mem = src.unsafeMemory
  let a = int(e.offset)
  let hb = int(e.headerBytes)
  if e.offset < 0 or e.offset + hb > src.mappedSize or hb < SegdTraceHeaderSize:
    refuse("the headers of trace " & $trace & " lie outside the file")
  result = SegdTrace(layout: rec.layout)
  result.header = decodeBlock[SegdTraceHeader](mem.toOpenArray(a, a + SegdTraceHeaderSize - 1))
  let b1 = a + SegdTraceHeaderSize
  let extra = hb - SegdTraceHeaderSize - SegdBlockSize
  if extra >= 0:
    case rec.layout
    of slRev2:
      result.ext1 = some(decodeBlock[SegdTraceHeaderExt1](
        mem.toOpenArray(b1, b1 + SegdBlockSize - 1)))
    of slRev3:
      result.ext1Rev3 = some(decodeBlock[SegdTraceHeaderExt1Rev3](
        mem.toOpenArray(b1, b1 + SegdBlockSize - 1)))
  if extra > 0:
    result.extensions = newSeq[byte](extra)
    copyMem(addr result.extensions[0], addr mem[b1 + SegdBlockSize], extra)
  result.offset = e.offset
  result.scanType = int(e.scanType)
  result.channelSet = e.channelSetIndex
  result.numSamples = int(e.numSamples)
  result.index = trace - first

proc finishRecord(s: var WriterState) =
  if s.nextTrace != s.recLast + 1:
    refuse("SEG-D record " & $s.recIndex & " of " & s.recPath & " is incomplete: traces " &
      $s.recFirst & ".." & $(s.nextTrace - 1) & " of " & $s.recFirst & ".." & $s.recLast &
      " were written (records are written whole)")
  s.segd.endRecord()
  s.inRecord = false

proc startRecord(s: var WriterState, src: SeismicFile, trace: int) =
  # Checks that `trace` can start its record, ends the record in progress and
  # writes the new one's headers.
  template entries: untyped = src.index.entries
  let r = int(entries[trace].record)
  if trace > 0 and int(entries[trace - 1].record) == r:
    var first = trace
    while first > 0 and int(entries[first - 1].record) == r: dec first
    refuse("SEG-D record " & $r & " must start with its first trace, " & $first &
      ", not trace " & $trace & " (records are written whole, in input order)")
  var rec = src.index.segdRecords[r]
  if rec.format.isNone:
    refuse("SEG-D record " & $r & " has the undefined format code " & $rec.gh1.formatCode)
  let fOut = s.segdFormat.get(rec.format.get)
  if not fOut.definedIn(rec.revision):
    refuse("SEG-D format " & $ord(fOut) & " is not defined in Rev " & $rec.revision &
      " (record " & $r & ")")
  var last = trace
  while last + 1 < entries.len and int(entries[last + 1].record) == r: inc last
  # A chosen 8015 (the input's own is written as it is): `src` need not be `like`.
  if fOut == sd8015 and rec.format.get != sd8015: checkGroups(src, trace, last)
  if s.inRecord: s.finishRecord()
  if fOut != rec.format.get:
    rec.gh1.formatCode = ord(fOut)
    rec.format = some(fOut)
    if rec.isRev3:
      var data = rec.headerBytes
      for k in trace..last:
        data += int64(entries[k].headerBytes) + dataBytes(fOut, int(entries[k].numSamples))
      if rec.gh3.dataSize != 0: rec.gh3.dataSize = uint64(data)
      if rec.gh3.recordSize != 0: rec.gh3.recordSize = uint64(data + rec.trailerRev3.len)
  s.segd.writeRecordHeaders(rec)
  s.inRecord = true
  s.recPath = src.path
  s.recIndex = r
  s.recFirst = trace
  s.recLast = last
  s.nextTrace = trace
  s.recFormat = fOut

proc overrideSegd(t: var SegdTrace, overrides: openArray[HeaderOverride]) =
  for o in overrides:
    let (blk, field) = splitName(o)
    case blk
    of "trace": t.header.setOverride(hbSegdTrace, field, o)
    of "ext1":
      case t.layout
      of slRev2:
        if t.ext1.isNone: refuse(o.name & ": the trace has no Trace Header Extension #1")
        var x = t.ext1.get
        x.setOverride(hbSegdExt1, field, o)
        t.ext1 = some(x)
      of slRev3:
        if t.ext1Rev3.isNone: refuse(o.name & ": the trace has no Trace Header Extension #1")
        var x = t.ext1Rev3.get
        x.setOverride(hbSegdExt1Rev3, field, o)
        t.ext1Rev3 = some(x)
    else: refuse(o.name & ": SEG-D trace blocks are trace and ext1")

proc writeSegd[T: SampleType](s: var WriterState, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride]) =
  if src.demuxPath.len > 0:
    refuse(src.path & " holds multiplexed SEG-D; convert it to a demultiplexed file first")
  let e = src.index.entries[trace]
  if samples.len != int(e.numSamples):
    refuse("a SEG-D trace keeps its sample count (the channel set descriptors hold it): " &
      "trace " & $trace & " has " & $e.numSamples & ", " & $samples.len & " were given")
  let r = int(e.record)
  # The overrides are checked before the record's headers can be written.
  var t = loadSegdTrace(src, trace, src.index.segdRecords[r], trace)
  t.overrideSegd(overrides)
  if s.inRecord and s.recPath == src.path and s.recIndex == r:
    if trace != s.nextTrace:
      refuse("SEG-D record " & $r & ": trace " & $s.nextTrace & " comes next, not " & $trace &
        " (a record's traces are written in input order)")
  else:
    s.startRecord(src, trace)
  t.index = trace - s.recFirst
  t.samples = newSeq[byte](dataBytes(s.recFormat, samples.len))
  # 8015 fractions as the input was read: its convention is the file's.
  encodeSamples(s.recFormat, samples, t.samples, src.index.codecs[r].twosComplement8015)
  s.segd.writeTrace(t)
  s.nextTrace = trace + 1

proc closeSegd(s: var WriterState, log: var DiagLog) =
  if s.inRecord: s.finishRecord()
  s.segd.close()
  log.add s.segd.log
  s.sink.close()
  s.sink = nil

# ----------------------------------------------------------------- SEG-2 --

proc writeSeg2[T: SampleType](s: var WriterState, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride]) =
  var t = src.seg2Trace(trace)
  for o in overrides:
    let (blk, field) = splitName(o)
    if blk != "trace": refuse(o.name & ": the SEG-2 trace block is trace (trace.<KEYWORD>)")
    t[field.toUpperAscii] = if o.value.kind == fvText: o.value.text else: $o.value
  if s.seg2Format.isSome: t.formatCode = uint8(ord(s.seg2Format.get))
  let twos = src.index.codecs[src.index.entries[trace].record].twosComplement8015
  s.seg2.writeTrace(t, samples, twos)

# ------------------------------------------------------------ public API --

proc writeTrace*[T: SampleType](w: var SeismicWriter, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride] = []) =
  ## Writes trace `trace` of `src` with its headers and `samples`, encoded
  ## in the output's format (see the module doc for what changes and the
  ## SEG-D rule). `src` is a file of the output's standard, normally
  ## `like`, and must be open. Raises `ValueError` for a closed writer or
  ## file, another standard, a trace out of range, a sample count the
  ## output cannot take, a broken SEG-D rule, or a SEG-Y writer opened from
  ## `SegyOutputOptions` (it takes traces from keys) (nothing is written then);
  ## `SegFormatError` for a value the format cannot hold or output the
  ## writer refuses; `IOError` on a write failure, which discards the
  ## output and closes the writer (the file may hold part of the trace).
  ##
  ## `overrides` change header fields of the written trace (trace `trace`
  ## is then a template): e.g. a stacked trace written with a source trace's
  ## headers and its own CDP, fold, offset and coordinates. Fields that size
  ## the file (sample counts, channel set references, ...) cannot be
  ## overridden; an unknown field, a value that does not fit it or a missing
  ## block raises `ValueError` and nothing is written.
  if not w.s.open: refuse("the writer is closed")
  if src.kind != w.s.kind:
    refuse("the output is " & $w.s.kind & ", " & src.path & " is " & $src.kind)
  if not src.isOpen: refuse("the file " & src.path & " is closed")
  discard src.traceEntry(trace) # ValueError out of range
  try:
    case w.s.kind
    of skSegy: w.s.writeSegy(src, trace, samples, overrides)
    of skSegd: w.s.writeSegd(src, trace, samples, overrides)
    of skSeg2: w.s.writeSeg2(src, trace, samples, overrides)
    of skUnknown: discard
  except IOError:
    # Part of the trace may be in the file: no later `close` may install it.
    w.s.discardOutput()
    raise
  inc w.s.written

proc writeTrace*[T: SampleType](w: var SeismicWriter, src: SeismicFile, trace: int,
    x: Tensor[T], row: int, samples = -1, overrides: openArray[HeaderOverride] = []) =
  ## `writeTrace` with the first `samples` values of row `row` of a
  ## row-major `[traces, samples]` tensor (e.g. from `readTraces`); -1
  ## takes as many as the input trace has. Raises `ValueError` also for
  ## another tensor shape, a row outside it or a row too short.
  if x.rank != 2 or not x.is_C_contiguous:
    refuse("need a row-major [traces, samples] tensor")
  if row notin 0 ..< x.shape[0]: refuse("row " & $row & " is outside the tensor")
  let n = if samples >= 0: samples else: int(src.traceEntry(trace).numSamples)
  if n > x.shape[1]:
    refuse($n & " samples were asked for, the tensor rows hold " & $x.shape[1])
  let p = rowPtr(x, row)
  w.writeTrace(src, trace, p.toOpenArray(0, n - 1), overrides)

proc writeTrace*[T: SampleType](w: var SeismicWriter, keys: TraceKeys, samples: openArray[T],
    overrides: openArray[HeaderOverride] = []) =
  ## Writes a SEG-Y trace whose headers are built from `keys` (no template
  ## trace), with `samples`, then `overrides` applied: a stacked or derived
  ## trace of any input standard. The output must be SEG-Y (from
  ## `openSeismicWriter(path, SegyOutputOptions)`, or `like` a SEG-Y file).
  ## The fields are those of the standard layout, which `openSeismic`
  ## reads back into the same keys (`record`, `channel`, `ensemble`,
  ## `offset`, `srcPoint`, coordinates, elevations and midpoint, `t0Ms`,
  ## `intervalUs`, `time`, and from Rev 1 `inline` and `crossline`):
  ##
  ## - NaN keys leave their fields 0 (read back as NaN for coordinates,
  ##   points and channels, as 0 for elevations, the record, the ensemble
  ##   and the offset; a point at exactly (0, 0) reads back NaN); values
  ##   are rounded where the field is an integer, coordinates and
  ##   elevations get the finest scalar that fits (Rev 2: also unscaled in
  ##   Trace Header Extension 1, with the offset, record, ensemble, a
  ##   fractional interval and the time's nanoseconds); `t0Ms` gets the
  ##   finest time scalar that holds it;
  ## - Rev 0 has fewer fields: `t0Ms` is a whole ms (rounded) in an int16, a
  ##   fractional source point is rounded, and the midpoint, `inline` and
  ##   `crossline` are not written (bytes 181-240 are unassigned there; the
  ##   midpoint reads back as halfway between source and receiver);
  ## - the trace identification code is `traceCode` when non-zero and its
  ##   status in the output's revision is `status` (so a status changed in
  ##   the keys wins), else 1 (live), 2 (dead) or 0 (unknown; also
  ##   auxiliary, which SEG-Y has no general code for). `component` is not
  ##   written as a code: outside SEG-Y it is a group index or sensor type;
  ## - `time` is written in UTC (time basis 4);
  ## - an `intervalUs` within 1e-9 of a whole number is that number (1001 µs
  ##   kept as 1.001 ms and multiplied back is 1000.9999999999999).
  ##
  ## A file `like` an input whose Layout stanza moves these fields reads
  ## them elsewhere: write from keys into `SegyOutputOptions` files. Raises
  ## `ValueError` for a closed or non-SEG-Y writer, keys without a positive
  ## interval (`intervalUs`), a fractional interval or one over 65535 µs
  ## before Rev 2, a `t0Ms` beyond ±32767 ms in Rev 0, a count
  ## the output cannot take, or a bad override (nothing is written then);
  ## `SegFormatError` for a value the format cannot hold; `IOError` on a
  ## write failure, which discards the output and closes the writer.
  if not w.s.open: refuse("the writer is closed")
  if w.s.kind != skSegy: refuse("traces from keys are written to SEG-Y, the output is " & $w.s.kind)
  try:
    w.s.writeSegyKeys(keys, samples, overrides)
  except IOError:
    w.s.discardOutput() # as above: the file may be torn
    raise
  inc w.s.written

proc close*(w: var SeismicWriter): DiagLog =
  ## Finishes the output: ends the SEG-D record in progress, writes the
  ## SEG-Y trailer and final counts or the SEG-2 trace pointers, and renames
  ## the temporary file to the output path. Returns the writer's
  ## diagnostics (warnings; a fatal one when the rename failed). On a raise
  ## (`ValueError` for an incomplete SEG-D record, `SegFormatError` for
  ## output the writer refuses, e.g. a SEG-2 file without traces, `IOError`)
  ## the output is discarded. Raises `ValueError` when already closed.
  if not w.s.open: refuse("the writer is closed")
  try:
    case w.s.kind
    of skSegy: w.s.closeSegy(result)
    of skSegd: w.s.closeSegd(result)
    of skSeg2:
      w.s.seg2.close()
      result.add w.s.seg2.log
    of skUnknown: discard
  except CatchableError:
    w.s.discardOutput()
    raise
  w.s.open = false
  finishOutput(w.s.tmp, w.s.path, keep = true, result)
  w.s.tmp = ""
