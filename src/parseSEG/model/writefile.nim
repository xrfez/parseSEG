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
## `writeTrace(w, src, trace, samples, keys)` writes the geometry of `keys`
## into the template's headers first, where it differs from what they hold:
## keys joined from survey files (`applySurvey`) or edited in memory are not
## in the mapped headers. The slots are those of write-back (`writeGeometry`);
## values with no slot are reported by `close`.
##
## Without a template: `openSeismicWriter(path, SegyOutputOptions(...))`
## writes a new SEG-Y file whose file headers come from the options, and
## `writeTrace(w, keys, samples, overrides)` builds each trace's headers
## from its `TraceKeys` (e.g. a stack of SEG-D or SEG-2 data; any SEG-Y
## writer takes these traces). `openSeismicWriter(path,
## SegdOutputOptions(...))` does the same for a new SEG-D Rev 3 file:
## traces are grouped into records by `keys.record`, one channel set per
## channel type, and `close` writes each record whole. `receiverGather`
## makes each record one receiver, with each trace's source in its header
## extensions; the default is one source per record, as in 0.14.0.
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
## (a full disk): it is closed, and its `close` raises `ValueError`. The
## per-standard writers validate as usual: spec-invalid output raises
## `SegFormatError` (see `segy/writer`, `segd/writer`, `seg2/writer`); a
## value the format cannot hold raises `SegFormatError` from the encoder
## and writes nothing. Caller errors (a trace out of range, another
## standard, a closed file, a broken SEG-D record rule) raise `ValueError`.

import std/[math, options, os, sets, times]
import ../common/[diagnostics, endians, outputfile, seismickind]
import ../io/[records, diskio]
import ../segy/[reader as segyreader, writer as segywriter, binheader, traceheader,
  samples as segysamples, textheader, exttext]
import ../segd/[reader as segdreader, writer as segdwriter]
import ../seg2/[reader as seg2reader, writer as seg2writer]
import ../convert
import std/strutils
import ./[traceindex, fieldvalues, keytypes]
from ./summary import CoordinateUnits
from ./keys import traceKeys
from ../survey/join import GeometryFields
from ../survey/writeback import KeysPlan, planKeys, finishKeys
import ../common/tensors
import ../private/[tensorrows, fieldaccess, segyencode, readcache]
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

  SegdChannelType* = enum
    ## A Rev 3 channel type (channel set descriptor byte 4). The codes are
    ## those `channelType` reads (`docs/spec/segd_rev3_0_b.md` §4.12); none
    ## are invented. Seismic (0x10) and electromagnetic (0x11) read back as
    ## live or dead; every other code reads back as auxiliary. `TraceKeys`
    ## has no channel-type field, so `writeTrace` takes one (`sctSeismic`
    ## when omitted).
    sctUnused = 0x00
    sctSeismic = 0x10
    sctEm = 0x11
    sctTimeBreak = 0x20
    sctClockTimeBreak = 0x21
    sctFieldTimeBreak = 0x22
    sctUpHole = 0x30
    sctWaterBreak = 0x40
    sctTimeCounter = 0x50
    sctExternalData = 0x60
    sctAcousticRange = 0x61
    sctAcousticRefMeasured = 0x62
    sctAcousticRefNominal = 0x63
    sctOther = 0x70
    sctSignatureUnfiltered = 0x80
    sctSignatureFiltered = 0x90
    sctSourceSigUnfiltered = 0x91
    sctSourceSigFiltered = 0x92
    sctSourceSigEstimated = 0x93
    sctSourceSigMeasured = 0x94
    sctSourceBasePlate = 0x95
    sctSourceRefSweep = 0x96
    sctSourceOther = 0x97
    sctSourceRefPilot = 0x98
    sctSourceMass = 0x99
    sctSourceExcitation = 0x9A
    sctSourceValve = 0x9B
    sctSourceOverload = 0x9C
    sctAuxDataTrailer = 0xA0
    sctTrueRefSweep = 0xB0
    sctRadioRefSweep = 0xB1
    sctRadioSimilarity = 0xB2
    sctWirelineRefSweep = 0xB3
    sctDepth = 0xC0
    sctWind = 0xC1
    sctCurrent = 0xC2
    sctVoltage = 0xC3
    sctVelocity = 0xC4
    sctAcceleration = 0xC5
    sctPressure = 0xC6
    sctTension = 0xC7
    sctTilt = 0xC8
    sctAngle = 0xC9
    sctCalibration = 0xF0

  SegdOutputOptions* = object
    ## A SEG-D Rev 3 file not modelled on an input
    ## (`openSeismicWriter(path, opts)`), for traces built from `TraceKeys`.
    revision*: SegdRevision = SegdRevision(major: 3, minor: 0)
      ## 3.0 or 3.1. The little-endian formats (9036, 9038, 9058, 9080) need 3.1.
    format*: SegdSampleFormat = sd8058
      ## Sample format of every trace. `sd8058` is IEEE float32, bit-exact
      ## for float32 samples. Also 8036, 8038, 8048, 8080 (IEEE float64), the
      ## Rev 3.1 little-endian twins, and the quantizing formats 8015, 8022,
      ## 8024, 8042 and 8044.
    sampleIntervalUs*: float64
      ## Sample interval in µs, a whole number, written into every channel set.
    numSamples*: int
      ## Samples of every trace. A channel set has this one count.
    units*: CoordinateUnits = cuMeters
      ## Metres or feet. With an empty `crsText`, written as a P1/11 axis
      ## record, which `summary.coordinateUnits` reads. Coordinates are not
      ## rescaled.
    crsText*: string
      ## CRS text written in 0x55 blocks, as the reader concatenates them (a
      ## Location Data stanza or P1/11 records). Empty: a P1/11 fragment
      ## naming `units`, or none when `units` is unknown.
    time*: float64 = NaN
      ## Fallback recording time, UTC POSIX seconds, for a record whose first
      ## trace has no `keys.time`. NaN (the default) means not set. The writer
      ## never invents a time.
    receiverGather*: bool = false
      ## When true, each record is one receiver and each trace carries its own
      ## source (a receiver gather). When false (the default), each record is
      ## one source, as in 0.14.0. Not inferred from the traces. The file keeps
      ## write order; sort by source line then source point before writing.

  TraceOrientation* = object
    ## Attitude of one trace, written as a SEG-D Rev 3 Orientation header
    ## (0x60, `SegdOrientation`). Rotations are radians, about X, Y and Z
    ## (X inline, Y crossline, Z positive down).
    rotationX*, rotationY*, rotationZ*: float32
    referenceOrientation*: float32
      ## Rotation about Z so that X points to true north. 0 when unknown.
    orientationType*: uint8
      ## Spec §4.19: 0 unknown, 1 true north, 2 cable direction, 3 sensor
      ## housing, 4 survey, 5 magnetic north, 9 other.
    refOrientationValid*: bool ## Byte 26: the reference orientation is valid.
    rotationApplied*: bool     ## Byte 27: bytes 1-12 are already applied to the samples.
    rotationNorthApplied*: bool
      ## Byte 28: already rotated to true north. The spec requires
      ## `rotationApplied` as well.
    time*: float64 = NaN
      ## UTC POSIX seconds the rotation applies to. NaN (the default) writes
      ## the trace's recording time.

  SegdKeyTrace = object
    keys: TraceKeys
    channelType: SegdChannelType
    samples: seq[byte]
    overrides: seq[HeaderOverride]
    orientation: Option[TraceOrientation]
    t0Us: int32
    channel: int ## The trace number in its channel set (assigned when kept).
    recorded: float64 ## This trace's time, or the record's when the trace has none.

  SegdSetChannels = object
    ## The trace numbers a record's channel set has taken.
    channelType: SegdChannelType
    used: HashSet[int]
    nextFree: int ## The lowest number not in `used`.

  SegdSourceFix = object
    seen, hasStation, hasXY: bool
    line, point, x, y, z: float64
    index: int16

  SegdReceiverFix = object
    seen, hasStation, hasXY: bool
    line, point, x, y, z: float64
    index: int16

  SegdSetT0 = object
    channelType: SegdChannelType
    t0Us: int32

  NullSink {.acyclic.} = ref object of RecordSink
    ## Discards what it is given: `openSeismicWriter` validates the SEG-Y
    ## file headers with it before the first trace fixes the sample count.

  Seg2NoSlot = enum
    ## SEG-2 key values that have no string to go in (`writeTrace` with keys).
    nsLine = "a source line other than the receiver line (SEG-2 has one LINE_ID)"
    nsZ = "an elevation without its location's X/Y"

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
    segdFresh: bool       ## Opened from `SegdOutputOptions`: traces come from keys.
    segdOpts: SegdOutputOptions
    segdHaveRec: bool     ## A record from keys is in progress (buffered).
    segdRecNo: int64
    segdRecTime: float64 ## UTC POSIX seconds of the buffered record; NaN if none.
    segdPending: seq[SegdKeyTrace]
    segdSource: SegdSourceFix
    segdReceiver: SegdReceiverFix
    segdSetT0: seq[SegdSetT0]
    segdChannels: seq[SegdSetChannels]
    segdNoZ: int          ## Traces whose elevation has no X/Y, so is not written.
    inRecord: bool
    recPath: string       ## The record in progress: its file, index and traces.
    recIndex, recFirst, recLast, nextTrace: int
    recFormat: SegdSampleFormat
    # SEG-2
    seg2: Seg2Writer
    seg2Format: Option[Seg2SampleFormat] ## none: each trace's own.
    # Traces written with keys (`writeTrace(w, src, trace, samples, keys)`)
    keysPlan: KeysPlan    ## Write-back's planner for the template file.
    hdr: seq[byte]        ## A template trace's header bytes, reused.
    seg2NoSlot: array[Seg2NoSlot, int]   ## SEG-2 key values without a string to go in.
    seg2NoSlotFirst: array[Seg2NoSlot, int] ## The first trace of each.


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

func initTraceOrientation*(rotationX, rotationY, rotationZ: float32,
    referenceOrientation: float32 = 0, orientationType: uint8 = 0,
    refOrientationValid = false, rotationApplied = false,
    rotationNorthApplied = false, time = NaN): TraceOrientation {.inline.} =
  ## An orientation to pass to `writeTrace`. `time` of NaN uses the trace's
  ## recording time.
  TraceOrientation(rotationX: rotationX, rotationY: rotationY, rotationZ: rotationZ,
    referenceOrientation: referenceOrientation, orientationType: orientationType,
    refOrientationValid: refOrientationValid, rotationApplied: rotationApplied,
    rotationNorthApplied: rotationNorthApplied, time: time)

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

proc discardOutput(s: var WriterState) {.raises: [].} =
  # Closes what is still open and removes the temporary file; once.
  if s.sink != nil:
    try: s.sink.close()
    except CatchableError: discard
    s.sink = nil
  s.seg2.abandon() # the output is dropped: no pointers to write
  if s.tmp.len > 0: discard tryRemoveFile(s.tmp)
  s.tmp = ""
  s.open = false

proc `=destroy`(w: SeismicWriter) =
  # `discardOutput` and the field's generic `=destroy` take `var`: the
  # address gives that view of the writer being destroyed.
  let s = addr w.s
  if s.open: s[].discardOutput()
  `=destroy`(s[])

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

proc checkRecordingTime(t: float64, what: string)

proc openSeismicWriter*(path: string, opts: SegdOutputOptions): SeismicWriter =
  ## A writer of a new SEG-D Rev 3 file at `path`, for traces built from
  ## `TraceKeys` (`writeTrace(w, keys, samples)`), grouped into records by
  ## `keys.record`. The sample interval, sample count and sample format come
  ## from `opts`; a record is buffered until the next record number or
  ## `close`, then written whole. Raises `ValueError` for a revision other
  ## than 3.0 or 3.1, a format that revision lacks, a sample interval that
  ## is not a whole number of microseconds from 1 to 2^32-1, a sample count
  ## below 1, a window (count less one, times the interval) longer than
  ## 2^32-1 µs, format 8015 with a count that is not a multiple of 4,
  ## coordinate units other than metres, feet or unknown, or a `time` that
  ## is set but not a finite UTC time in 1950-2049; `IOError` when the
  ## output cannot be created.
  let rev = opts.revision
  if rev.major != 3 or rev.minor > 1:
    refuse("SEG-D Rev " & $rev & " cannot be written from keys (3.0 or 3.1)")
  if not opts.format.definedIn(rev):
    refuse("SEG-D format " & $ord(opts.format) & " is not defined in Rev " & $rev)
  let dt = wholeInterval(opts.sampleIntervalUs)
  if dt.isNaN or dt <= 0 or dt != round(dt) or dt > float64(high(uint32)):
    refuse("SegdOutputOptions.sampleIntervalUs must be a whole number of microseconds " &
      "from 1 to " & $high(uint32) & ", not " & $opts.sampleIntervalUs)
  if opts.numSamples <= 0 or opts.numSamples > int(high(uint32)):
    refuse("SegdOutputOptions.numSamples must be at least 1, not " & $opts.numSamples)
  let window = dt * float64(opts.numSamples - 1)
  if window > float64(high(uint32)):
    refuse("a window of " & $opts.numSamples & " samples at " & $dt & " µs is " & $window &
      " µs, longer than a SEG-D Rev 3 channel set can hold (" & $high(uint32) & " µs)")
  if opts.format == sd8015 and opts.numSamples mod 4 != 0:
    refuse("SEG-D format 8015 holds samples in groups of 4; numSamples is " & $opts.numSamples)
  if opts.units notin {cuUnknown, cuMeters, cuFeet}:
    refuse("SEG-D coordinates are in metres or feet, not " & $opts.units)
  if not opts.time.isNaN: checkRecordingTime(opts.time, "SegdOutputOptions.time")
  var fixed = opts
  fixed.sampleIntervalUs = dt
  result = SeismicWriter(s: WriterState(kind: skSegd, path: path, tmp: createTempFor(path),
    open: true, segdFresh: true, segdOpts: fixed, segdRecTime: NaN))
  try:
    result.s.sink = openDiskSink(result.s.tmp)
    result.s.segd = openSegdWriter(result.s.sink, SegdWriteOptions())
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

proc headerBytes(src: SeismicFile, trace: int, minimum: int): (int, int) =
  # Where trace `trace`'s header bytes start in the map, and how many there
  # are (at least `minimum`); `ValueError` when they lie outside the file.
  let e = src.index.entries[trace]
  let n = max(int(e.headerBytes), minimum)
  if e.offset < 0 or e.offset + n > src.mappedSize:
    refuse("the headers of trace " & $trace & " lie outside the file")
  (int(e.offset), n)

proc loadSegyTrace(src: SeismicFile, trace: int, h: openArray[byte], t: var SegyTrace) =
  # Trace `trace`'s headers from `h` (its header bytes), as the reader
  # gives them.
  let e = src.index.entries[trace]
  let hb = int(e.headerBytes)
  let order = src.index.segy.byteOrder
  t.header = decodeTraceHeader(h.toOpenArray(0, TraceHeaderSize - 1), order)
  t.hasExt1 = hb >= 2 * TraceHeaderSize
  if t.hasExt1:
    t.ext1 = decodeTraceHeaderExt1(h.toOpenArray(TraceHeaderSize, 2 * TraceHeaderSize - 1),
      order)
  let extra = max(hb - 2 * TraceHeaderSize, 0)
  t.proprietary.setLen extra
  if extra > 0: copyMem(addr t.proprietary[0], addr h[2 * TraceHeaderSize], extra)
  t.numSamples = int(e.numSamples)
  t.offset = e.offset

template withTemplateHeaders(s: var WriterState, src: SeismicFile, trace, minimum: int,
    keys: ptr TraceKeys, fields: GeometryFields, h, body: untyped) =
  # Runs `body` with `h`, a copy of trace `trace`'s header bytes, with
  # `keys` the keys' geometry written in (write-back). The copy is checked
  # against a cut of the file (`SegTruncatedError`) before any of it can
  # reach the output: bytes read past a cut are zeros.
  let (a, n) = src.headerBytes(trace, minimum)
  src.requireUncutFirst()
  s.hdr.setLen n
  block:
    var held: Hold
    src.holdBytes(held, a, a + n)
    copyMem(addr s.hdr[0], addr src.unsafeMemory[a], n)
  src.requireUncut()
  if keys != nil: s.keysPlan.planKeys(src, trace, keys[], s.hdr, fields)
  template h: untyped = s.hdr.toOpenArray(0, n - 1)
  body

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
    samples: openArray[T], overrides: openArray[HeaderOverride], keys: ptr TraceKeys,
    fields: GeometryFields) =
  if s.segyFresh:
    # Its binary header (interval, Ext1 count) is made for traces from keys;
    # a template trace's headers would disagree with it.
    refuse("a writer opened from SegyOutputOptions takes traces from keys " &
      "(writeTrace(w, keys, samples)), not template traces")
  let n = samples.len
  template t: untyped = s.segyTrace
  withTemplateHeaders(s, src, trace, TraceHeaderSize, keys, fields, h):
    loadSegyTrace(src, trace, h, t)
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

proc loadSegdTrace(src: SeismicFile, trace: int, rec: SegdRecord,
    mem: openArray[byte]): SegdTrace =
  # Trace `trace`'s headers from `mem` (its header bytes), as the reader
  # gives them.
  let e = src.index.entries[trace]
  let hb = int(e.headerBytes)
  result = SegdTrace(layout: rec.layout)
  result.header = decodeBlock[SegdTraceHeader](mem.toOpenArray(0, SegdTraceHeaderSize - 1))
  let b1 = SegdTraceHeaderSize
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
    samples: openArray[T], overrides: openArray[HeaderOverride], keys: ptr TraceKeys,
    fields: GeometryFields) =
  if s.segdFresh:
    refuse("a writer opened from SegdOutputOptions takes traces from keys " &
      "(writeTrace(w, keys, samples)), not template traces")
  if src.demuxPath.len > 0:
    refuse(src.path & " holds multiplexed SEG-D; convert it to a demultiplexed file first")
  let e = src.index.entries[trace]
  if samples.len != int(e.numSamples):
    refuse("a SEG-D trace keeps its sample count (the channel set descriptors hold it): " &
      "trace " & $trace & " has " & $e.numSamples & ", " & $samples.len & " were given")
  let r = int(e.record)
  if int(e.headerBytes) < SegdTraceHeaderSize:
    refuse("the headers of trace " & $trace & " lie outside the file")
  # The overrides are checked before the record's headers can be written.
  var t: SegdTrace
  withTemplateHeaders(s, src, trace, SegdTraceHeaderSize, keys, fields, h):
    t = loadSegdTrace(src, trace, src.index.segdRecords[r], h)
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

# ------------------------------------------------------- SEG-D from keys --

const SegdExtNumMax = 0xFF_FFFF ## Extended file and trace numbers are 24-bit.

func segdSeismic(c: SegdChannelType): bool {.inline.} =
  c == sctSeismic or c == sctEm

func crsToWrite(opts: SegdOutputOptions): string =
  if opts.crsText.len > 0: opts.crsText
  elif opts.units == cuMeters: "((OGP:P1/11 CRS))\nHC,1,6,1,metre\n"
  elif opts.units == cuFeet: "((OGP:P1/11 CRS))\nHC,1,6,1,feet\n"
  else: ""

proc crsBlockBytes(text: string): seq[byte] =
  result = @[]
  var i = 0
  while i < text.len:
    let n = min(31, text.len - i)
    var b = newSeq[byte](32)
    for k in 0 ..< n: b[k] = byte(text[i + k])
    for k in n .. 30: b[k] = byte(' ')
    b[31] = BlockTypeCrs
    result.add b
    i += 31

proc positionBlock(x, y, z: float64, valid: bool, stanza: uint16): SegdPositionBlock =
  let zz = if z.isNaN or not valid: Inf else: z
  let xx = if valid: x else: Inf
  let yy = if valid: y else: Inf
  SegdPositionBlock(tuple1Coord1: xx, tuple1Coord2: yy, tuple1Coord3: zz,
    stanzaId1: (if valid: stanza else: 0'u16), position1Valid: uint8(ord(valid)),
    position1Quality: uint8(ord(valid)),
    tuple2Coord1: Inf, tuple2Coord2: Inf, tuple2Coord3: Inf,
    blockType1: BlockTypePosition1, blockType2: BlockTypePosition2,
    blockType3: BlockTypePosition3)

const
  SegdTimeMin = -631152000.0 ## 1950-01-01T00:00:00 UTC: the earliest GH#1 year.
  SegdTimeMax = 2524608000.0 ## 2050-01-01T00:00:00 UTC: past the latest GH#1 year.
  BlockTypeTimestamp = 0x42'u8 ## Timestamp header: time of the trace's data.
  BlockTypeSourceInfo = 0x20'u8 ## Additional Source Info: source event time.

func segdExtCount(hasPos, hasOrient, hasSrc, hasSrcInfo, hasSrcPos: bool): int {.inline.} =
  # THE#1, optional receiver Position (3), optional Source Description,
  # optional Additional Source Info, optional source Position (3), Timestamp,
  # optional Orientation. A shot gather passes the source flags false.
  1 + (if hasPos: 3 else: 0) + (if hasSrc: 1 else: 0) + (if hasSrcInfo: 1 else: 0) +
    (if hasSrcPos: 3 else: 0) + 1 + (if hasOrient: 1 else: 0)

proc checkRotation(v: float32, what: string) =
  if v.isNaN or v == Inf or v == -Inf:
    refuse(what & " is not a finite rotation (" & $v & ")")

proc checkOrientation(o: TraceOrientation) =
  checkRotation(o.rotationX, "rotationX")
  checkRotation(o.rotationY, "rotationY")
  checkRotation(o.rotationZ, "rotationZ")
  checkRotation(o.referenceOrientation, "referenceOrientation")
  if o.rotationNorthApplied and not o.rotationApplied:
    refuse("rotationNorthApplied is set but rotationApplied is not")
  if o.time.isNaN: return
  if o.time == Inf or o.time == -Inf:
    refuse("orientation time is not finite (" & $o.time & ")")
  let us = (o.time - float64(GpsEpochUnix)) * 1e6
  if us < -9.0e18 or us > 9.0e18:
    refuse("orientation time does not fit a SEG-D timestamp (" & $o.time & ")")

func orientationBlock(o: TraceOrientation, recorded: float64): SegdOrientation =
  let t = if o.time.isNaN: recorded else: o.time
  SegdOrientation(rotationX: o.rotationX, rotationY: o.rotationY, rotationZ: o.rotationZ,
    referenceOrientation: o.referenceOrientation, timestamp: unixToTimestamp(t),
    orientationType: o.orientationType,
    refOrientationValid: uint8(ord(o.refOrientationValid)),
    rotationApplied: uint8(ord(o.rotationApplied)),
    rotationNorthApplied: uint8(ord(o.rotationNorthApplied)),
    blockType: BlockTypeOrientation)

proc checkRecordingTime(t: float64, what: string) =
  # General Header #1 holds a two-digit year read as 1950-2049. A time outside
  # that, or one that is not finite, cannot be written.
  if t.isNaN or t == Inf or t == -Inf:
    refuse(what & " is not a finite recording time (" & $t & ")")
  if t < SegdTimeMin or t >= SegdTimeMax:
    refuse(what & " does not fit a SEG-D General Header #1 year (1950-2049), not " & $t)

proc recordingTime(k: TraceKeys, opts: SegdOutputOptions, recNo: int64): float64 =
  # The record's time: the first trace's keys, else the option. Never invented.
  if not k.time.isNaN:
    checkRecordingTime(k.time, "keys.time")
    return k.time
  if not opts.time.isNaN:
    checkRecordingTime(opts.time, "SegdOutputOptions.time")
    return opts.time
  refuse("SEG-D record " & $recNo & " has no recording time: set keys.time or " &
    "SegdOutputOptions.time")

proc fileNumberOf(k: TraceKeys): int64 =
  let r = k.record
  if r.isNaN or r < 0 or r > float64(SegdExtNumMax) or r != round(r):
    refuse("the keys give no SEG-D file number (record " & $r &
      "; a whole number 0.." & $SegdExtNumMax & ")")
  int64(r)

proc t0Of(k: TraceKeys): int32 =
  if k.t0Ms.isNaN: return 0
  let us = round(k.t0Ms * 1000)
  if us < float64(low(int32)) or us > float64(high(int32)):
    refuse("start time " & $k.t0Ms & " ms does not fit a SEG-D Rev 3 channel set")
  int32(us)

proc checkStation(line, point: float64, what: string): bool =
  # True when the station is known. A line and a point that are both 0, or
  # both NaN, are unknown (the reader gives NaN back).
  let ln = not line.isNaN
  let pn = not point.isNaN
  if ln != pn:
    refuse("a " & what & " station needs both a line and a point")
  if not ln: return false
  if line <= -8388608.0 or line >= 8388608.0 or point <= -8388608.0 or point >= 8388608.0:
    refuse(what & " station " & $line & "/" & $point & " does not fit a SEG-D Rev 3 field")
  not (line == 0 and point == 0)

proc setReceiverStation(e: var SegdTraceHeaderExt1Rev3, line, point: float64) =
  proc one(whole: var int32, ext: var float64, v: float64) =
    let r = round(v)
    if v == r and r >= -8388607 and r <= 8388607 and int32(r) != -1:
      whole = int32(r)
    else:
      whole = -1
      ext = v
  if line == 0 and point == 0: return
  one(e.receiverLineNumber, e.extReceiverLineNumber, line)
  one(e.receiverPointNumber, e.extReceiverPointNumber, point)

proc noteSetT0(s: var WriterState, ct: SegdChannelType, t0: int32) =
  for c in s.segdSetT0:
    if c.channelType == ct:
      if c.t0Us != t0:
        refuse("SEG-D channel set " & $ct & " has one start time, " &
          $(float64(c.t0Us) / 1000) & " ms; this trace has " & $(float64(t0) / 1000) &
          " ms (a channel set has one sample window)")
      return
  s.segdSetT0.add SegdSetT0(channelType: ct, t0Us: t0)

proc sameNum(a, b: float64): bool {.inline.} =
  a == b or (a.isNaN and b.isNaN)

proc noteSource(s: var WriterState, k: TraceKeys, hasSt, hasXY: bool) =
  if not hasSt and not hasXY: return
  if not s.segdSource.seen:
    s.segdSource = SegdSourceFix(seen: true, hasStation: hasSt, hasXY: hasXY, line: k.srcLine,
      point: k.srcPoint, x: k.srcX, y: k.srcY, z: k.srcZ, index: k.srcIndex)
    return
  let src = s.segdSource
  let stationDiff = hasSt != src.hasStation or
    (hasSt and not (sameNum(k.srcLine, src.line) and sameNum(k.srcPoint, src.point) and
      k.srcIndex == src.index))
  let xyDiff = hasXY != src.hasXY or
    (hasXY and not (sameNum(k.srcX, src.x) and sameNum(k.srcY, src.y) and sameNum(k.srcZ, src.z)))
  if stationDiff or xyDiff:
    refuse("SEG-D record " & $s.segdRecNo & " has one source (the general header); " &
      "this trace's source differs")

func knownStation(line, point: float64): bool {.inline.} =
  # True when checkStation would accept the station. A partial station was
  # already refused at write time.
  not line.isNaN and not point.isNaN and not (line == 0.0 and point == 0.0)

proc noteReceiver(s: var WriterState, k: TraceKeys, hasSt, hasXY: bool, channel: int,
    ct: SegdChannelType) =
  # A receiver gather is one receiver. The first trace fixes it; a later
  # trace that differs is the caller's error, named by its channel.
  if not s.segdReceiver.seen:
    s.segdReceiver = SegdReceiverFix(seen: true, hasStation: hasSt, hasXY: hasXY,
      line: k.rcvLine, point: k.rcvPoint, x: k.rcvX, y: k.rcvY, z: k.rcvZ, index: k.rcvIndex)
    return
  let r = s.segdReceiver
  let stationDiff = hasSt != r.hasStation or
    (hasSt and not (sameNum(k.rcvLine, r.line) and sameNum(k.rcvPoint, r.point) and
      k.rcvIndex == r.index))
  let xyDiff = hasXY != r.hasXY or
    (hasXY and not (sameNum(k.rcvX, r.x) and sameNum(k.rcvY, r.y) and sameNum(k.rcvZ, r.z)))
  if stationDiff or xyDiff:
    refuse("SEG-D record " & $s.segdRecNo & " is one receiver; trace channel " & $channel &
      " (" & $ct & ") has a different receiver")

proc sourceExtBytes(k: TraceKeys, fileNo: int64, recorded, recTime: float64,
    stanza: uint16): seq[byte] =
  # This trace's source, in the order the reader and the standard use: a
  # Source Description, Additional Source Info when the shot is not at record
  # time zero, then the source Position. Empty when the trace names no source.
  result = @[]
  let hasSt = knownStation(k.srcLine, k.srcPoint)
  if not hasSt and not k.hasSourceXY: return
  let sb = SegdSourceDescription(extFileNumber: uint32(fileNo),
    sourceLineNumber: if hasSt: k.srcLine else: 0.0,
    sourcePointNumber: if hasSt: k.srcPoint else: 0.0,
    sourcePointIndex: if hasSt: uint8(k.srcIndex) else: 0'u8,
    sourceSetNumber: 1, depthIndex: 1, blockType: 0x1F)
  result.add sb.encoded
  if not sameNum(recorded, recTime):
    var info = SegdAdditionalSourceInfo(time: unixToTimestamp(recorded),
      blockType: BlockTypeSourceInfo)
    for i in 0 ..< info.errorDescription.len: info.errorDescription[i] = ' '
    result.add info.encoded
  if k.hasSourceXY:
    result.add positionBlock(k.srcX, k.srcY, k.srcZ, true, stanza).encoded

proc checkFinite(v: float64, what: string) =
  # NaN is an unknown coordinate; an infinite one reads back as no position.
  if v == Inf or v == -Inf:
    refuse(what & " is infinite (" & $v & "); a coordinate or elevation is a number, or NaN for unknown")

proc checkSegdStatus(k: TraceKeys, ct: SegdChannelType) =
  if segdSeismic(ct) and k.status == tsAuxiliary:
    refuse("an auxiliary trace needs an auxiliary SEG-D channel type, not " & $ct)
  if not segdSeismic(ct) and k.status in {tsLive, tsDead}:
    refuse("channel type " & $ct & " reads back as auxiliary, not " & $k.status)

func depthIndexOf(k: TraceKeys): uint8 =
  # A receiver depth index is never 0 (1 = shallowest). The keys leave it 0
  # when unset. The field is a byte, as the keys hold it, so every other
  # value fits.
  if k.depthIndex == 0: 1'u8 else: k.depthIndex

proc channelOf(k: TraceKeys): int =
  if k.channel.isNaN: return -1
  if k.channel < 1 or k.channel > float64(SegdExtNumMax) or k.channel != round(k.channel):
    refuse("channel " & $k.channel & " is not a SEG-D trace number (a whole number 1.." &
      $SegdExtNumMax & ")")
  int(k.channel)

proc setBcdOrExt(small: var int, ext: var uint32, n: int64, digits: int) =
  # `digits` BCD digits, or all-F plus the extended field.
  var lim = 1
  for i in 1 .. digits: lim *= 10
  if n < lim: small = int(n)
  else:
    small = BcdAllF
    ext = uint32(n)

proc chNumber(s: WriterState, ct: SegdChannelType, ch: int): int =
  # The trace number for a trace of channel set `ct`: `ch` (-1 for NaN),
  # refused when the set has it already; for NaN the lowest number the set
  # has not used. Nothing is recorded until the trace is kept (`noteChannel`).
  for c in s.segdChannels:
    if c.channelType == ct:
      if ch < 0: return c.nextFree
      if ch in c.used:
        refuse("channel " & $ch & " is already used in SEG-D channel set " & $ct &
          " (a trace number is unique in a channel set)")
      return ch
  if ch < 0: 1 else: ch

proc noteChannel(s: var WriterState, ct: SegdChannelType, n: int) =
  var i = -1
  for j, c in s.segdChannels:
    if c.channelType == ct: i = j
  if i < 0:
    s.segdChannels.add SegdSetChannels(channelType: ct, nextFree: 1)
    i = s.segdChannels.high
  s.segdChannels[i].used.incl n
  while s.segdChannels[i].nextFree in s.segdChannels[i].used:
    inc s.segdChannels[i].nextFree

proc flushSegdKeys(s: var WriterState) =
  # Writes the buffered record and forgets it. A failure while writing
  # discards the output: the record headers are already in the file.
  if s.segdPending.len == 0:
    s.segdHaveRec = false
    return
  let opts = s.segdOpts
  let fileNo = s.segdRecNo
  let fmt = opts.format
  let crs = crsToWrite(opts)
  let stanza: uint16 = if crs.len > 0: 1 else: 0
  var setType: seq[SegdChannelType] = @[]
  var setCount: seq[int] = @[]
  var setT0: seq[int32] = @[]
  var setPos: seq[bool] = @[]
  var setExt: seq[int] = @[]
  var setOf = newSeq[int](s.segdPending.len)
  for i, p in s.segdPending:
    var found = -1
    for j, ct in setType:
      if ct == p.channelType: found = j
    if found < 0:
      setType.add p.channelType
      setCount.add 0
      setT0.add p.t0Us
      setPos.add false
      setExt.add 0
      found = setType.len - 1
    setOf[i] = found
    inc setCount[found]
    if p.keys.hasReceiverXY: setPos[found] = true
  let rg = opts.receiverGather
  for i, p in s.segdPending:
    let hasSrc = rg and (knownStation(p.keys.srcLine, p.keys.srcPoint) or p.keys.hasSourceXY)
    let hasInfo = hasSrc and not sameNum(p.recorded, s.segdRecTime)
    let n = segdExtCount(setPos[setOf[i]], p.orientation.isSome, hasSrc, hasInfo,
      rg and p.keys.hasSourceXY)
    if n > setExt[setOf[i]]: setExt[setOf[i]] = n
  var traces = newSeq[SegdTrace](s.segdPending.len)
  for i, p in s.segdPending:
    let si = setOf[i]
    let hasSrc = rg and (knownStation(p.keys.srcLine, p.keys.srcPoint) or p.keys.hasSourceXY)
    let hasInfo = hasSrc and not sameNum(p.recorded, s.segdRecTime)
    let exts = segdExtCount(setPos[si], p.orientation.isSome, hasSrc, hasInfo,
      rg and p.keys.hasSourceXY)
    let ch = p.channel
    var t = SegdTrace(layout: slRev3, index: i, numSamples: opts.numSamples)
    var hdr = SegdTraceHeader(scanTypeNumber: 1, traceHeaderExtensions: uint8(exts),
      traceEdit: case p.keys.status
        of tsDead: 1'u8
        of tsUnknown: 0'u8 # stored as live: SEG-D has no unknown seismic status
        of tsLive, tsAuxiliary: 0'u8)
    var fileSmall = 0
    var fileExt = 0'u32
    setBcdOrExt(fileSmall, fileExt, fileNo, 4)
    hdr.fileNumber = fileSmall
    hdr.extFileNumber = fileExt
    let csNo = si + 1
    var csSmall = 0
    var csExt = 0'u32
    setBcdOrExt(csSmall, csExt, int64(csNo), 2)
    hdr.channelSetNumber = csSmall
    hdr.extChannelSetNumber = uint16(csNo)
    var trSmall = 0
    var trExt = 0'u32
    setBcdOrExt(trSmall, trExt, int64(ch), 4)
    hdr.traceNumber = trSmall
    t.header = hdr
    var e = SegdTraceHeaderExt1Rev3(numSamples: uint32(opts.numSamples),
      sensorType: p.keys.sensorType, groupIndex: p.keys.component,
      depthIndex: depthIndexOf(p.keys), reshootIndex: p.keys.reshootIndex,
      extTraceNumber: uint32(ch), blockType: BlockTypeTraceHeaderExt1)
    if checkStation(p.keys.rcvLine, p.keys.rcvPoint, "receiver"):
      e.setReceiverStation(p.keys.rcvLine, p.keys.rcvPoint)
      e.receiverPointIndex = int8(p.keys.rcvIndex)
    t.ext1Rev3 = some(e)
    var extBytes = newSeq[byte]()
    if setPos[si]:
      let k = p.keys
      let pos = if k.hasReceiverXY: positionBlock(k.rcvX, k.rcvY, k.rcvZ, true, stanza)
        else: positionBlock(0, 0, NaN, false, 0)
      extBytes.add pos.encoded
    # Receiver position first, so it does not follow a source description.
    # A receiver gather then puts this trace's source here: the reader takes
    # a trace's source from a Source Description in the extensions before the
    # general header, and a Position that follows it is that source's.
    if rg:
      extBytes.add sourceExtBytes(p.keys, fileNo, p.recorded, s.segdRecTime, stanza)
    # The reader takes a trace's time from this block when it is present,
    # ahead of General Header #3.
    extBytes.add SegdTimestampHeader(timeZeroOfData: unixToTimestamp(p.recorded),
      blockType: BlockTypeTimestamp).encoded
    if p.orientation.isSome:
      extBytes.add orientationBlock(p.orientation.get, p.recorded).encoded
    t.extensions = extBytes
    t.samples = p.samples
    t.overrideSegd(p.overrides)
    traces[i] = t
  var rec = SegdRecord(layout: slRev3, format: some(fmt), revision: opts.revision)
  rec.generalBlocks = crsBlockBytes(crs)
  let src = s.segdSource
  if src.hasStation:
    # The keys' depth index is the receiver's (THE#1). The source description
    # has its own, which the keys do not carry, and 0 is not allowed there
    # either: 1 is the shallowest.
    let sb = SegdSourceDescription(extFileNumber: uint32(fileNo), sourceLineNumber: src.line,
      sourcePointNumber: src.point, sourcePointIndex: uint8(src.index), sourceSetNumber: 1,
      depthIndex: 1, blockType: 0x1F)
    rec.generalBlocks.add @(sb.encoded)
  if src.hasXY:
    rec.generalBlocks.add @(positionBlock(src.x, src.y, src.z, true, stanza).encoded)
  let nOpt = rec.generalBlocks.len div SegdBlockSize
  let additional = 2 + nOpt
  let recTime = s.segdRecTime
  doAssert not recTime.isNaN, "a SEG-D record was buffered without a recording time"
  # GH#1 holds whole seconds of the time as General Header #3 holds it: the
  # time rounded to the microsecond (unixToTimestamp), read back.
  let civil = fromUnix(int64(floor(timestampToUnix(unixToTimestamp(recTime))))).utc
  var gh1 = SegdGeneralHeader1(formatCode: ord(fmt), recordType: 8, recordLength: BcdAllF,
    year: civil.year mod 100, julianDay: civil.yearday + 1, hour: civil.hour,
    minute: civil.minute, second: civil.second,
    scanTypesPerRecord: 1, skewBlocks: 0, extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  var fileSmall = 0
  var fileExt = 0'u32
  setBcdOrExt(fileSmall, fileExt, fileNo, 4)
  gh1.fileNumber = fileSmall
  if additional <= 14: gh1.additionalGhBlocks = uint8(additional)
  else: gh1.additionalGhBlocks = 0xF
  let nCS = setType.len
  if nCS <= 99: gh1.channelSetsPerScanType = nCS
  else: gh1.channelSetsPerScanType = BcdAllF
  let span = opts.sampleIntervalUs * float64(max(opts.numSamples - 1, 0))
  # The short field holds only these intervals (1/16 ms units); any other
  # is 0xFF, with the µs value in General Header #2.
  const ShortScanIntervals = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]
  let sixteenths = opts.sampleIntervalUs / 62.5
  if sixteenths in ShortScanIntervals:
    gh1.baseScanInterval16 = uint8(sixteenths)
  else:
    gh1.baseScanInterval16 = 0xFF
  rec.gh1 = gh1
  var gh2 = SegdGeneralHeader2Rev3(extFileNumber: uint32(fileNo),
    revisionMajor: opts.revision.major, revisionMinor: opts.revision.minor,
    blockType: BlockTypeGeneralHeader2)
  if additional > 14: gh2.extAdditionalGhBlocks = uint16(additional)
  if nCS > 99: gh2.extChannelSetsPerScanType = uint16(nCS)
  if gh1.baseScanInterval16 == 0xFF:
    gh2.dominantSamplingInterval = uint32(opts.sampleIntervalUs)
  gh2.extRecordLength = uint32(span) # in range: openSeismicWriter refuses a longer window
  rec.gh2Rev3 = gh2
  rec.gh3 = SegdGeneralHeader3(timeZero: unixToTimestamp(recTime),
    blockType: BlockTypeGeneralHeader3)
  var descs: seq[SegdChannelSetDescriptorRev3] = @[]
  for j, ct in setType:
    let endUs = float64(setT0[j]) + span
    var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(j + 1),
      channelType: uint8(ord(ct)), startTime: setT0[j], numSamples: uint32(opts.numSamples),
      descaleMultiplier: 1.0, channelsInSet: uint32(setCount[j]),
      samplingInterval: uint32(opts.sampleIntervalUs), arrayForming: 1,
      traceHeaderExtensions: uint8(setExt[j]), verticalStack: 1,
      blockType1: BlockTypeChannelSet1, blockType2: BlockTypeChannelSet2,
      blockType3: BlockTypeChannelSet3)
    for i in 0 ..< d.description.len: d.description[i] = ' '
    d.endTime = int32(endUs) # in range: writeSegdKeys refuses a window past it
    descs.add d
  rec.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  computeRev3Sizes(rec, traces)
  rec.traceCount = traces.len
  try:
    s.segd.writeRecordHeaders(rec)
    for t in traces: s.segd.writeTrace(t)
    s.segd.endRecord()
  except CatchableError:
    s.discardOutput()
    raise
  s.segdPending.setLen 0
  s.segdHaveRec = false
  s.segdRecTime = NaN
  s.segdSource = SegdSourceFix()
  s.segdReceiver = SegdReceiverFix()
  s.segdSetT0.setLen 0
  s.segdChannels.setLen 0

proc writeSegdKeys[T: SampleType](s: var WriterState, k: TraceKeys, samples: openArray[T],
    overrides: openArray[HeaderOverride], channelType: SegdChannelType,
    orientation: Option[TraceOrientation]) =
  let n = s.segdOpts.numSamples
  if samples.len != n:
    refuse("a SEG-D channel set has one sample count, " & $n &
      " (SegdOutputOptions.numSamples); this trace has " & $samples.len)
  let recNo = fileNumberOf(k)
  if s.segdHaveRec and recNo < s.segdRecNo:
    refuse("SEG-D records are written in order; record " & $recNo & " follows record " &
      $s.segdRecNo)
  if s.segdHaveRec and recNo > s.segdRecNo: s.flushSegdKeys()
  if not s.open: return
  if not k.intervalUs.isNaN and wholeInterval(k.intervalUs) != s.segdOpts.sampleIntervalUs:
    refuse("the keys' sample interval is " & $wholeInterval(k.intervalUs) &
      " µs, the output's is " & $s.segdOpts.sampleIntervalUs)
  checkSegdStatus(k, channelType)
  for (v, what) in [(k.srcX, "source X"), (k.srcY, "source Y"), (k.srcZ, "source elevation"),
      (k.rcvX, "receiver X"), (k.rcvY, "receiver Y"), (k.rcvZ, "receiver elevation")]:
    checkFinite(v, what)
  if (k.hasSourceXY or k.hasReceiverXY) and crsToWrite(s.segdOpts).len == 0:
    refuse("coordinates need a CRS in the file: set SegdOutputOptions.units (metres or feet) " &
      "or crsText")
  let ch = channelOf(k)
  let num = s.chNumber(channelType, ch)
  let t0 = t0Of(k)
  let dt = s.segdOpts.sampleIntervalUs
  if float64(t0) + dt * float64(n - 1) > float64(high(int32)):
    refuse("a window of " & $n & " samples at " & $dt & " µs from " & $(float64(t0) / 1000) &
      " ms does not fit a SEG-D Rev 3 channel set end time")
  let hasRcv = checkStation(k.rcvLine, k.rcvPoint, "receiver")
  let hasSrc = checkStation(k.srcLine, k.srcPoint, "source")
  if hasRcv and (k.rcvIndex < -128 or k.rcvIndex > 127):
    refuse("receiver point index " & $k.rcvIndex & " does not fit a SEG-D Rev 3 int8")
  if hasSrc and (k.srcIndex < 0 or k.srcIndex > 255):
    refuse("source point index " & $k.srcIndex & " does not fit a SEG-D Rev 3 byte")
  if not s.segdHaveRec:
    s.segdRecTime = recordingTime(k, s.segdOpts, recNo)
  elif not k.time.isNaN:
    checkRecordingTime(k.time, "keys.time")
  let recorded = if k.time.isNaN: s.segdRecTime else: k.time
  if orientation.isSome: checkOrientation(orientation.get)
  if s.segdOpts.receiverGather:
    s.noteReceiver(k, hasRcv, k.hasReceiverXY, num, channelType)
  else:
    s.noteSource(k, hasSrc, k.hasSourceXY)
  s.noteSetT0(channelType, t0)
  # A bad override fails here, before the trace joins the record.
  var probe = SegdTrace(layout: slRev3, ext1Rev3: some(SegdTraceHeaderExt1Rev3()))
  probe.overrideSegd(overrides)
  var raw = newSeq[byte](dataBytes(s.segdOpts.format, n))
  encodeSamples(s.segdOpts.format, samples, raw)
  var ov = newSeq[HeaderOverride](overrides.len)
  for i, o in overrides: ov[i] = o
  if (not k.rcvZ.isNaN and not k.hasReceiverXY) or (not k.srcZ.isNaN and not k.hasSourceXY):
    inc s.segdNoZ
  s.noteChannel(channelType, num)
  s.segdPending.add SegdKeyTrace(keys: k, channelType: channelType, samples: raw,
    overrides: ov, orientation: orientation, t0Us: t0, channel: num, recorded: recorded)
  s.segdHaveRec = true
  s.segdRecNo = recNo

proc closeSegd(s: var WriterState, log: var DiagLog) =
  if s.segdFresh:
    if s.written == 0: refuse("no traces were written")
    s.flushSegdKeys()
  elif s.inRecord: s.finishRecord()
  if s.segdNoZ > 0:
    log.report(sevWarning, dcValidation, "not written: an elevation without its location's " &
      "X/Y, in " & $s.segdNoZ & " traces", loc = Location(file: s.path))
  s.segd.close()
  log.add s.segd.log
  s.sink.close()
  s.sink = nil

# ----------------------------------------------------------------- SEG-2 --

func seg2Number(v: float64): string =
  # A SEG-2 number string: whole values without a fraction.
  if v == round(v) and abs(v) < 1e15: $int64(v) else: $v

proc seg2Geometry(s: var WriterState, src: SeismicFile, trace: int, t: var Seg2Trace,
    k: TraceKeys, fields: GeometryFields) =
  # The keys' geometry into the trace's strings, where it differs from what
  # they hold: SOURCE_/RECEIVER_LOCATION (x y, and z less DATUM),
  # SOURCE_/RECEIVER_STATION_NUMBER, and LINE_ID when both lines are one.
  let cur = traceKeys(src.index.seg2, t)
  let datum = block:
    let d = t.number("DATUM")
    if d.isSome: d.get
    else:
      let fd = src.index.seg2.number("DATUM")
      if fd.isSome: fd.get else: 0.0
  template known(v: float64): bool = not v.isNaN
  template same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)
  template noSlot(why: Seg2NoSlot) =
    if s.seg2NoSlot[why] == 0: s.seg2NoSlotFirst[why] = trace
    inc s.seg2NoSlot[why]
  template location(key: string, x, y, z, cx, cy, cz: float64, writeXy: bool) =
    let nx = if writeXy and known(x) and known(y): x else: cx
    let ny = if writeXy and known(x) and known(y): y else: cy
    let nz = if fields.elevations and known(z): z else: cz
    if not (same(nx, cx) and same(ny, cy) and same(nz, cz)):
      if known(nx) and known(ny):
        t[key] = seg2Number(nx) & " " & seg2Number(ny) &
          (if known(nz): " " & seg2Number(nz - datum) else: "")
      else: noSlot(nsZ)
  location("SOURCE_LOCATION", k.srcX, k.srcY, k.srcZ, cur.srcX, cur.srcY, cur.srcZ,
    fields.sourceXy)
  location("RECEIVER_LOCATION", k.rcvX, k.rcvY, k.rcvZ, cur.rcvX, cur.rcvY, cur.rcvZ,
    fields.receiverXy)
  if fields.stations:
    if known(k.srcPoint) and not same(k.srcPoint, cur.srcPoint):
      t["SOURCE_STATION_NUMBER"] = seg2Number(k.srcPoint)
    if known(k.rcvPoint) and not same(k.rcvPoint, cur.rcvPoint):
      t["RECEIVER_STATION_NUMBER"] = seg2Number(k.rcvPoint)
    let line = if known(k.rcvLine): k.rcvLine else: k.srcLine
    if known(line) and not same(line, cur.rcvLine):
      if known(k.srcLine) and known(k.rcvLine) and k.srcLine != k.rcvLine: noSlot(nsLine)
      else: t["LINE_ID"] = seg2Number(line)

proc writeSeg2[T: SampleType](s: var WriterState, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride], keys: ptr TraceKeys,
    fields: GeometryFields) =
  var t = src.seg2Trace(trace)
  if keys != nil: s.seg2Geometry(src, trace, t, keys[], fields)
  for o in overrides:
    let (blk, field) = splitName(o)
    if blk != "trace": refuse(o.name & ": the SEG-2 trace block is trace (trace.<KEYWORD>)")
    t[field.toUpperAscii] = if o.value.kind == fvText: o.value.text else: $o.value
  if s.seg2Format.isSome: t.formatCode = uint8(ord(s.seg2Format.get))
  let twos = src.index.codecs[src.index.entries[trace].record].twosComplement8015
  s.seg2.writeTrace(t, samples, twos)

# ------------------------------------------------------------ public API --

proc writeLike[T: SampleType](w: var SeismicWriter, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride], keys: ptr TraceKeys,
    fields: GeometryFields) =
  # Trace `trace` of `src` as the template; with `keys`, their geometry
  # written into its headers first.
  if not w.s.open: refuse("the writer is closed")
  if src.kind != w.s.kind:
    refuse("the output is " & $w.s.kind & ", " & src.path & " is " & $src.kind)
  if not src.isOpen: refuse("the file " & src.path & " is closed")
  discard src.traceEntry(trace) # ValueError out of range
  try:
    case w.s.kind
    of skSegy: w.s.writeSegy(src, trace, samples, overrides, keys, fields)
    of skSegd: w.s.writeSegd(src, trace, samples, overrides, keys, fields)
    of skSeg2: w.s.writeSeg2(src, trace, samples, overrides, keys, fields)
    of skUnknown: discard
  except IOError:
    # Part of the trace may be in the file: no later `close` may install it.
    w.s.discardOutput()
    raise
  inc w.s.written


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
  w.writeLike(src, trace, samples, overrides, nil, GeometryFields())

proc writeTrace*[T: SampleType](w: var SeismicWriter, src: SeismicFile, trace: int,
    x: Tensor[T], row: int, count = -1, overrides: openArray[HeaderOverride] = []) =
  ## `writeTrace` with the first `count` values of row `row` of a
  ## row-major `[traces, samples]` tensor (e.g. from `readTraces`); -1
  ## takes as many as the input trace has. Raises `ValueError` also for
  ## another tensor shape, a row outside it or a row too short.
  if x.rank != 2 or not x.is_C_contiguous:
    refuse("need a row-major [traces, samples] tensor")
  if row notin 0 ..< x.shape[0]: refuse("row " & $row & " is outside the tensor")
  let n = if count >= 0: count else: int(src.traceEntry(trace).numSamples)
  if n > x.shape[1]:
    refuse($n & " samples were asked for, the tensor rows hold " & $x.shape[1])
  let p = rowPtr(x, row)
  w.writeTrace(src, trace, p.toOpenArray(0, n - 1), overrides)

proc writeTrace*[T: SampleType](w: var SeismicWriter, src: SeismicFile, trace: int,
    samples: openArray[T], keys: TraceKeys, overrides: openArray[HeaderOverride] = [],
    fields = GeometryFields()) =
  ## `writeTrace` like trace `trace` of `src`, with the geometry of `keys`
  ## written into its headers: the template trace's headers, then the
  ## values of `keys` that differ from what they hold (NaN keys leave their
  ## fields alone), then `overrides`. For processed traces whose keys were
  ## joined (`applySurvey`) or edited in memory: the mapped headers do not
  ## hold those. The values and their slots are write-back's
  ## (`writeGeometry`, `GeometryFields` selects them):
  ##
  ## - SEG-Y through the layout: source and receiver X/Y, elevations,
  ##   midpoint, offset, source point, stations where a Layout stanza names
  ##   them, with the coordinate scalar chosen per trace;
  ## - SEG-D: THE#1's receiver line, point and index; Rev 3 also the
  ##   receiver's and the source's Position blocks and the Source
  ##   Description block, where the trace header extensions hold them;
  ## - SEG-2: `SOURCE_LOCATION` and `RECEIVER_LOCATION` (x y, and z less
  ##   `DATUM`), `SOURCE_STATION_NUMBER`, `RECEIVER_STATION_NUMBER`, and
  ##   `LINE_ID` when the source and receiver lines are one.
  ##
  ## A value with no slot in the trace, or too large for its slot, is not
  ## written; `close`'s log reports each kind once, with a count (values
  ## that do not fit are errors there). Otherwise as `writeTrace(w, src,
  ## trace, samples, overrides)`, and the same exceptions.
  w.writeLike(src, trace, samples, overrides, addr keys, fields)

proc writeTrace*[T: SampleType](w: var SeismicWriter, src: SeismicFile, trace: int,
    x: Tensor[T], row: int, keys: TraceKeys, count = -1,
    overrides: openArray[HeaderOverride] = [], fields = GeometryFields()) =
  ## The keys form of `writeTrace` with the first `count` values of row
  ## `row` of a row-major `[traces, samples]` tensor (-1: as many as the
  ## input trace has).
  if x.rank != 2 or not x.is_C_contiguous:
    refuse("need a row-major [traces, samples] tensor")
  if row notin 0 ..< x.shape[0]: refuse("row " & $row & " is outside the tensor")
  let n = if count >= 0: count else: int(src.traceEntry(trace).numSamples)
  if n > x.shape[1]:
    refuse($n & " samples were asked for, the tensor rows hold " & $x.shape[1])
  let p = rowPtr(x, row)
  w.writeLike(src, trace, p.toOpenArray(0, n - 1), overrides, addr keys, fields)

proc writeTrace*[T: SampleType](w: var SeismicWriter, keys: TraceKeys, samples: openArray[T],
    overrides: openArray[HeaderOverride] = [], channelType: SegdChannelType = sctSeismic,
    orientation: Option[TraceOrientation] = none(TraceOrientation)) =
  ## Writes a trace whose headers are built from `keys` (no template
  ## trace), with `samples`, then `overrides` applied: a stacked or derived
  ## trace of any input standard. The output is SEG-Y (from
  ## `openSeismicWriter(path, SegyOutputOptions)`, or `like` a SEG-Y file)
  ## or SEG-D Rev 3 (from `SegdOutputOptions`). `channelType` is the SEG-D
  ## channel type (`sctSeismic` when omitted); a SEG-Y writer ignores it.
  ## The SEG-Y fields are those of the standard layout, which `openSeismic`
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
  ## them elsewhere: write from keys into `SegyOutputOptions` files. For
  ## SEG-Y, raises `ValueError` for a closed writer, keys without a positive
  ## interval, a fractional interval or one over 65535 µs before Rev 2, a
  ## `t0Ms` beyond ±32767 ms in Rev 0, a count the output cannot take, or a
  ## bad override (nothing is written then).
  ##
  ## SEG-D Rev 3 (a writer from `SegdOutputOptions`) groups traces into
  ## records by `keys.record` (the file number), in the order written, and
  ## writes a record when a higher number arrives or on `close`. Records
  ## must not go backwards. One channel set per channel type in a record,
  ## in the order that type first appears; every trace of a set has
  ## `numSamples` samples and the options' interval (a keys `intervalUs`
  ## that differs is refused, a NaN one is left to the options). `channel`
  ## is the trace number (NaN assigns the lowest number the channel set has
  ## not used).
  ## Receiver line and point go in Trace Header Extension #1. With
  ## `receiverGather` false (the default), source line and point go in one
  ## Source Description block in the general header (one source per record;
  ## a trace that names none inherits it on read). With `receiverGather`
  ## true, the record is one receiver: every trace's receiver line, point,
  ## index and coordinates must agree, or this raises `ValueError` naming
  ## that trace's channel. Each trace's source is a Source Description
  ## block (0x1F) in its own header extensions, which is where the reader
  ## and other software take a per-trace source; a Position block follows
  ## it for that source's coordinates, and Additional Source Info follows
  ## when the trace's time is not the record's time zero. The file keeps
  ## write order. Sort by source line then source point before writing; the
  ## writer does not sort.
  ## An unset depth index (`depthIndex` 0) is written, and reads back, as 1
  ## (the standard forbids 0; 1 is the shallowest). The source description's
  ## depth index, which the keys do not carry, is written as 1. A reshoot
  ## index of 0 is the first recording, and a point index of 0 is allowed
  ## (not recorded, or a VSP extension of the depth index), so those are
  ## written as given.
  ## Source and receiver coordinates and elevations go in Position blocks
  ## (a shot gather: the general header for the source, the trace extensions
  ## for a receiver; a receiver gather: both in the trace extensions, the
  ## receiver's before the source description). A channel set that has any
  ## receiver position gives every trace of the set one, invalid where the
  ## coordinates are missing. A station of 0/0,
  ## or NaN, reads back NaN. A NaN `t0Ms` reads back 0, and `component` 0
  ## reads back as the `sensorType` value. An elevation with no X/Y is not
  ## written; `close` warns once for the file. `status` of `tsDead` sets the
  ## trace edit flag
  ## (byte 12 = 1) on a seismic or EM channel and reads back `tsDead`;
  ## `tsLive` reads back `tsLive`. `tsUnknown` is stored as a live trace
  ## (trace edit 0), on purpose: SEG-D has no unknown status for a seismic
  ## channel, so `tsUnknown` reads back `tsLive`. An auxiliary channel type
  ## reads back as `tsAuxiliary` (including `tsUnknown`, and `tsAuxiliary`
  ## itself), so `tsLive` or `tsDead` with one is refused, as is
  ## `tsAuxiliary` with seismic or EM. The record's time is the first
  ## trace's `keys.time` when that is set, otherwise `SegdOutputOptions.time`;
  ## with neither, the record is refused (the message names both). It is
  ## written in General Header #1 (year, julian day and the whole second of
  ## the time rounded to the microsecond) and in General Header #3's timestamp.
  ## The reader takes a trace's time from its Timestamp block (0x42) when that
  ## trace has one, else from General Header #3, so a trace's own `keys.time`
  ## is written there and reads back; a trace without one reads back the
  ## record's time. Traces of one record may
  ## differ. The writer never invents a time.
  ## `orientation` (`some` of a `TraceOrientation`, or none) writes one
  ## Orientation header (0x60) after the Timestamp block of that trace. Its
  ## timestamp is `time` when that is set, otherwise the trace's recording
  ## time. A trace given none gets no Orientation block, so a file written
  ## without one is unchanged. Traces of one channel set may differ: the
  ## channel set descriptor's extension count is the largest, and a trace
  ## with fewer is the reader's usual warning (`dcInconsistent`); each trace
  ## header's own count is the blocks that trace carries. Metres or feet are
  ## written as a P1/11 axis record when `crsText` is empty, which
  ## `summary.coordinateUnits` reads; a caller-supplied `crsText` is written
  ## in 0x55 blocks as given. Raises `ValueError` for a closed writer, a
  ## SEG-D writer not opened from `SegdOutputOptions`, a SEG-2 writer, a
  ## record number going backwards, a sample count other than the options',
  ## a start time that differs inside a channel set, a second source in a
  ## shot record (`receiverGather` false), a receiver that differs inside a
  ## receiver-gather record (the message names the trace's channel), a
  ## station with only a line or only a point, a channel number
  ## used twice in its channel set, a window whose end does not fit the
  ## set's end time, an infinite coordinate or elevation, coordinates with
  ## units unknown and no `crsText`, a record with no recording time, a
  ## recording time outside 1950-2049, a bad override, a NaN or infinite
  ## rotation (the message names the value), `rotationNorthApplied` without
  ## `rotationApplied`, an orientation time that is not finite or does not
  ## fit a SEG-D timestamp, or an orientation passed to a writer that is not
  ## SEG-D Rev 3 (nothing of that trace is written then); `SegFormatError` for a value
  ## the format cannot hold; `IOError` on a write failure, which discards
  ## the output and closes the writer.
  if not w.s.open: refuse("the writer is closed")
  if w.s.segdFresh:
    try:
      w.s.writeSegdKeys(keys, samples, overrides, channelType, orientation)
    except IOError:
      w.s.discardOutput()
      raise
    inc w.s.written
    return
  if orientation.isSome:
    refuse("an orientation is written only to SEG-D Rev 3 (openSeismicWriter with " &
      "SegdOutputOptions)")
  if w.s.kind != skSegy:
    refuse("traces from keys are written to SEG-Y, or to SEG-D opened from " &
      "SegdOutputOptions; the output is " & $w.s.kind)
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
  ## diagnostics: warnings only, since every failure raises and discards
  ## the output (`ValueError` for an incomplete SEG-D record, a SEG-D file
  ## from keys with no traces,
  ## `SegFormatError` for output the writer refuses, e.g. a SEG-2 file
  ## without traces, `IOError` when the last bytes cannot be written or the
  ## file cannot be moved into place). Raises `ValueError` when already
  ## closed.
  if not w.s.open: refuse("the writer is closed")
  try:
    case w.s.kind
    of skSegy: w.s.closeSegy(result)
    of skSegd: w.s.closeSegd(result)
    of skSeg2:
      w.s.seg2.close()
      result.add w.s.seg2.log
    of skUnknown: discard
    # Traces written with keys: the values that had no slot or did not fit.
    result.add w.s.keysPlan.finishKeys()
    for why in Seg2NoSlot:
      if w.s.seg2NoSlot[why] > 0:
        result.report(sevWarning, dcValidation, "not written: " & $why & ", in " &
          $w.s.seg2NoSlot[why] & " traces (the first is trace " & $w.s.seg2NoSlotFirst[why] &
          ")", loc = Location(file: w.s.path))
  except CatchableError:
    w.s.discardOutput()
    raise
  w.s.open = false
  var moved: DiagLog
  finishOutput(w.s.tmp, w.s.path, keep = true, moved) # removes what it cannot move
  w.s.tmp = ""
  for d in moved:
    if d.severity == sevFatal: raise newException(IOError, d.msg & ": " & w.s.path)
