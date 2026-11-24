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
## SEG-D storage unit label; the SEG-2 File Descriptor Block. A non-empty
## `fullText` replaces the SEG-Y textual header. `segyRevision` writes a
## SEG-Y `like` file as another revision (the source headers, rewritten as
## `convertSegy` rewrites them); `none` or the source's own revision leaves
## the bytes unchanged. What that revision cannot hold is either refused
## before any file exists or dropped and listed by `revisionNotes` (see
## `openSeismicWriter`). `writeTrace`
## copies trace `trace` of `src` (usually `like` itself) with its headers
## unchanged, except for what the new samples change:
##
## - the sample format, when one is chosen (`segyFormat`, `segdFormat`,
##   `seg2Format`; "keep" by default);
## - SEG-Y and SEG-2: the sample count, which may differ from the input's.
##   SEG-Y updates the trace header (Trace Header Extension 1 when it holds
##   the count or the count exceeds 65535) and the binary header, which gets
##   the count of the traces written (the largest when they differ; left as
##   the source wrote it when every trace was skipped, because a variable
##   file's flag does not require 0); a fixed-length file needs one count
##   for all traces. The Rev 2 trace count (binary bytes 3513-3520), when
##   the input declares one, becomes the number written.
## - SEG-D: the sample count of a record, taken from the first trace written
##   to it. Every later trace of that record must have the same count, unless
##   it is written with its own source count and the traces so far were too
##   (channel sets may then differ). The record length, the end time of each
##   channel set that has channels and the sample count in an existing trace
##   header extension follow. A count of 0 is refused. A channel set with no
##   channels is left unchanged. A trace written with its own count leaves
##   those headers unchanged.
##
## `overrides` (`HeaderOverride`) change named header fields of the written
## trace, so the input trace serves as a template: a stacked trace with a
## source trace's headers and its own CDP, fold, offset and coordinates.
## SEG-D overrides named `vendor.<field>` set a field of a vendor header map
## in the trace's extension blocks (`useVendorMaps`; `HeaderOverride`).
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
## Records may be skipped, repeated or reordered. A record's traces may have
## a new sample count: the first trace's count is the record's, and every
## later trace must match it (`ValueError`, naming the record and the counts,
## otherwise, and nothing of that record is written), unless that trace is
## written with its own source count and the traces so far were too (channel
## sets may then differ). The record length (the
## longest, over channel sets that have channels, of the trace length and the
## end time, so a negative start still covers the trace; a negative end time
## is written as it is), each of those sets' end time (start plus count times
## the interval) and the sample count in each existing trace header extension
## follow; a count the headers cannot hold, or a count of 0, is refused the
## same way (a short-form record length of 000 is indeterminate, not 0). A
## channel set with no channels is left unchanged. A written SEG-D 8015 count still
## needs a multiple of 4 (the source count is not checked at open). A trace
## written with its own count leaves those headers unchanged. The record
## headers and trailer come from the trace's own record in `src`; a
## new format sets the format code and, for Rev 3, the General Header #3 data
## and record sizes. Multiplexed SEG-D input is refused (convert it first).
##
## `startSubset` writes a record from some of one source record's traces
## instead: its channel set counts, a changed set's sample count and end time,
## the record length and the Rev 3 sizes follow the traces kept.
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
import ../io/[records, diskio, memsink]
import ../segy/[reader as segyreader, writer as segywriter, binheader, traceheader,
  samples as segysamples, textheader, exttext]
import ../segd/[reader as segdreader, writer as segdwriter]
import ../vendor/apply as vendorapply
import ../seg2/[reader as seg2reader, writer as seg2writer]
import ../convert
import std/strutils
import ./[traceindex, fieldvalues, keytypes]
from ./summary import CoordinateUnits
from ./keys import traceKeys
from ../survey/join import GeometryFields
from ../survey/writeback import KeysPlan, planKeys, finishKeys
import ../common/tensors
import ../private/[tensorrows, fieldaccess, segyencode, readcache, segyrev]
import ../version

type
  HeaderOverride* = object
    ## A header field to change in a trace written from a template trace
    ## (`writeTrace`'s `overrides`).
    name*: string
      ## `trace.<field>` or `ext1.<field>`, with the field names of the
      ## header types (as `HeaderEditor.setTraceField`); SEG-2:
      ## `trace.<KEYWORD>`, a trace string. SEG-D: `vendor.<field>`, a field
      ## of a vendor header map in the trace's extension blocks (see
      ## `useVendorMaps`); an integer value (`fvInt`) is passed exactly.
      ## The binary file header of a SEG-Y output (`SegyOutputOptions.binaryOverrides`,
      ## `binaryOverrides` of the like SEG-Y writers): `binary.<field>`.
    value*: FieldValue ## The value as stored (SEG-Y: before its scalar).

  SubsetPatch* = object
    ## What a subset record (`startSubset`) changes of its source record's
    ## identity; the defaults keep the source's.
    fileNumber*: int64 = -1
      ## The file number, 0..16777215 (-1 keeps it). It goes into General
      ## Header #1 (BCD up to 9999, else `FFFF` and the extended number),
      ## General Header #2 and the source headers' extended numbers, each
      ## trace header, and, in Rev 3, the file number of the Source
      ## Description blocks.
    time*: float64 = NaN
      ## The record's time, UTC POSIX seconds, 1950 to 2049 (NaN keeps it).
      ## General Header #1 holds whole seconds (the fraction is dropped there).
      ## Rev 3: General Header #3's time zero is `time` to the microsecond,
      ## and a trace's Timestamp block (0x42) is the instant of its first
      ## sample, `time` plus the start time of its channel set. A trace header's
      ## first timing word and the Rev 3 additional source info's time are left as
      ## the source's: a caller whose source has a non-zero first timing word must
      ## override it.
    headers*: seq[HeaderOverride]
      ## Record header fields by name, applied before `fileNumber` and `time`:
      ## `gh1.<field>` (not the file number or the time fields `year`, `julianDay`,
      ## `hour`, `minute`, `second`: use `fileNumber` and `time`) and, in Rev 2,
      ## `gh3.<field>`, `gh4.<field>`, ... (the source headers), with the field
      ## names `recordField` uses. Fields that size the file are refused.

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
      ## `END TEXTUAL HEADER`. Ignored when `fullText` is set.
    fullText*: seq[string]
      ## The whole textual header: up to 40 lines of up to 80 characters,
      ## written exactly as given and padded with spaces. No card prefix is
      ## added. Non-empty replaces `text`. Empty means unset.
    fixCards*: bool = true
      ## With a non-empty `fullText`, true (the default) sets cards 39 and 40
      ## to the standard revision and end-marker strings for `revision`.
      ## False writes `fullText` untouched. Ignored when `fullText` is empty.
    traceSorting*: int16 = 0 ## Binary 3229-3230: 1 as recorded, 2 CDP ensembles, 4 stack, ...
    measurementSystem*: int16 = 0 ## Binary 3255-3256: 1 metres, 2 feet, 0 unknown.
    binaryOverrides*: seq[HeaderOverride]
      ## Further binary file header fields by name, `binary.<field>` (see
      ## `HeaderOverride`; e.g. `binary.jobId`, `binary.sweepLength`), applied after
      ## `traceSorting` and `measurementSystem` (which they replace) and written
      ## exactly. Refused (`ValueError`, before any file is created): fields that size
      ## the file or that the writer sets from the data or the revision, an unknown
      ## field, a value outside the field's range and a field the revision lacks.

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

  SubsetSet = object
    ## A channel set of a SEG-D record written from some of its traces.
    scan, chan: int   ## 0-based indexes of its scan type and descriptor.
    kept: int         ## Traces of the set in the subset.
    n: int            ## The sample count its traces share; -1 until one is written.
    srcN: int         ## The source count of its first kept trace.
    chans: seq[int]   ## The source channel (its place in the set) of each kept trace.

  PendingStanza = object
    company, name, contentType: string
    data: seq[byte]
    binary: bool

  WriterState = object
    kind: SeismicKind
    path, tmp: string     ## The output, and its temporary file ("" once gone, or in memory).
    memory: bool          ## The output is collected in `mem`, not written to `tmp`.
    mem: MemSink          ## `sink` when `memory`; keeps the bytes after the sink is closed.
    open: bool            ## Set by `openSeismicWriter`; false once closed (and when zeroed).
    written: int
    sink: RecordSink      ## SEG-Y and SEG-D output (nil once closed).
    # SEG-Y
    segyFile: SegyFile    ## The file headers to write.
    segy: SegyWriter
    segyStarted: bool     ## `segy` is open on `sink` (from the first trace).
    segyStanzas: seq[PendingStanza] ## Added by `addStanza`, put into the header at the first trace.
    segyStanzaRecords: int ## The records they will take.
    segyFixed: bool       ## Fixed-length traces (Rev 1+, binary 3503 = 1).
    segyCount: int        ## The sample count of every trace so far; -1 none, -2 mixed.
    segyMax: int          ## The largest sample count so far.
    segyNumTraces: uint64 ## The input's declared Rev 2 trace count.
    segyTrace: SegyTrace  ## Reused.
    segyFresh: bool       ## Opened from `SegyOutputOptions`: the first trace sets the interval.
    segyRevOn: bool       ## `segyRevision` names a revision other than the source's.
    segyRev: RevRewrite   ## That rewrite; file notes already in `segyRevLog`.
    segyRevLog: DiagLog   ## `revisionNotes`: `convertSegy`'s words for the rewrite.
    segyLenient: bool     ## A changed revision is validated as `convertSegy` validates.
    # SEG-D
    segd: SegdWriter
    segdFormat: Option[SegdSampleFormat] ## none: each record's own.
    segdFresh: bool       ## Opened from `SegdOutputOptions`: traces come from keys.
    segdOpts: SegdOutputOptions
    segdHaveRec: bool     ## A record from keys is in progress (buffered).
    segdRecNo: int64
    segdRecTime: float64 ## UTC POSIX seconds of the buffered record; NaN if none.
    segdPending: seq[SegdKeyTrace]
    segdExternal: seq[byte] ## The buffered record's external header (set by its first trace).
    segdSource: SegdSourceFix
    segdReceiver: SegdReceiverFix
    segdSetT0: seq[SegdSetT0]
    segdChannels: seq[SegdSetChannels]
    segdNoZ: int          ## Traces whose elevation has no X/Y, so is not written.
    inRecord: bool
    recPath: string       ## The record in progress: its file, index and traces.
    recMem: int           ## `recPath`'s `memoryId` (0 for a disk file).
    recIndex, recFirst, recLast, nextTrace: int
    recFormat: SegdSampleFormat
    likeTraces: seq[SegdTrace] ## Buffered traces of the like: record; written at its end.
    likeN: int                 ## The count the record's traces must share.
    likeSame: bool             ## Every buffered trace kept its source count.
    likeRec: SegdRecord        ## Headers to write; a new format is already applied.
    vendor: VendorRegistry     ## From `useVendorMaps`: the maps `vendor.<field>` overrides use.
    chOpen, chRec, chFirst: int ## The source record `chIdx` was worked out for: the open
                               ## file (`openId`), its record number and first trace.
    chIdx: seq[int32]          ## Of each of its traces, the place among those of its channel set.
    vctx: VendorContext        ## The vendor context of the record being written,
    vctxKey: string            ## made when an override needs it, for the record `vctxKey` names.
    subset: seq[int]           ## From `startSubset`: the source traces of the next record.
    subPath: string            ## That subset's file and `memoryId`.
    subMem: int
    subPatch: SubsetPatch      ## The patch of the subset listed, and of its record.
    likeKept: seq[int]         ## The record in progress is these source traces; empty: whole.
    likeSets: seq[SubsetSet]   ## Its channel sets with a kept trace.
    likeSetOf: seq[int]        ## For each kept trace, its index in `likeSets`.
    likePos: int               ## Kept traces written.
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
    refuse(o.name & (if field == "blockType":
      ": is the block's type byte, which says what the block is; it cannot be overridden"
      else: ": changes the file's structure (sizes or counts); it cannot be overridden"))
  var err = ""
  if not setByName(h, field, o.value, err): refuse(o.name & ": " & err)

const
  binaryDerived = [
    ("sampleInterval", "the writer sets it from the traces' interval"),
    ("sampleIntervalOrig", "it is tied to the interval the writer sets"),
    ("extSampleInterval", "the writer sets it from the traces' interval"),
    ("extSampleIntervalOrig", "it is tied to the interval the writer sets")]
  # Fields only Rev 2 has (the others set by name are in every revision).
  binaryRev2Only = ["extDataTracesPerEnsemble", "extAuxTracesPerEnsemble",
    "extSamplesPerTraceOrig", "extEnsembleFold", "timeBasisCode"]

proc withBinaryOverrides(b: SegyBinaryHeader, rev: SegyRevision,
    overrides: openArray[HeaderOverride]): SegyBinaryHeader =
  # `b` with the binary header fields `overrides` (`binary.<field>`) set; a refusal
  # names the override. The by-name setter alone would take a field of any
  # revision and write its bytes whatever the revision says.
  result = b
  for o in overrides:
    let (blk, field) = splitName(o)
    if blk != "binary": refuse(o.name & ": the binary file header's fields are binary.<field>")
    if field in structural(hbSegyBinary):
      refuse(o.name & ": changes the file's structure (sizes, counts or the revision); " &
        "it cannot be overridden")
    for (name, why) in binaryDerived:
      if field == name: refuse(o.name & ": " & why & "; it cannot be overridden")
    if field in binaryRev2Only and rev.major < 2:
      refuse(o.name & ": is a Rev 2 field, and the output is Rev " & $rev)
    var err = ""
    if not setByName(result, field, o.value, err): refuse(o.name & ": " & err)

method writeRecordImpl(s: NullSink; data: openArray[byte]) {.raises: [].} =
  s.offset += data.len

method writeTapeMarkImpl(s: NullSink) {.raises: [].} = discard

proc makeSink(s: var WriterState) =
  # The output's sink: the temporary file's, or the memory buffer.
  if s.memory:
    s.mem = openMemSink(s.path)
    s.sink = s.mem
  else:
    s.sink = openDiskSink(s.tmp)

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
  ## The output path (written by `close`); for a writer of bytes
  ## (`openSeismicWriterBytes`) its display name.
  w.s.path

func revisionNotes*(w: SeismicWriter): lent DiagLog {.inline.} =
  ## What a `segyRevision` change dropped or could not write, in
  ## `convertSegy`'s words. File-level notes are there after open, including a
  ## warning quoting a card 39 or 40 that held other text; a skipped
  ## trace's error after that `writeTrace`; the Rev 0 time-clamp warning after
  ## `close` or `finishBytes`. Empty when `segyRevision` was not set, or was
  ## the source revision. `close`'s log does not include these.
  w.s.segyRevLog

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

func revisionCard(rev: SegyRevision): string = revisionCardText(rev)

func endCard(): string = endCardText()

func linesAfterFix(lines: openArray[string], rev: SegyRevision): seq[string] =
  # The lines `fillFullText` writes when `fixCards` is set: caller cards,
  # then the standard cards 39 and 40.
  result = newSeq[string](CardCount)
  let n = min(lines.len, CardCount)
  for i in 0 ..< n: result[i] = lines[i]
  result[38] = revisionCard(rev)
  result[39] = endCard()

func textFault(lines: openArray[string], rev: SegyRevision, encoding: TextEncoding,
    fixCards: bool): string =
  # The first length, character or read-back fault, or "" when `lines` may
  # be written. Read-back is judged on the bytes actually written.
  let problems = checkTextHeader(lines, rev, encoding)
  for p in problems:
    if p.kind in {thfTooManyLines, thfLineTooLong, thfBadCharacter}:
      return p.message
  if not fixCards:
    for p in problems:
      if p.kind == thfReadBack: return p.message
    return ""
  for p in checkTextHeader(linesAfterFix(lines, rev), rev, encoding):
    if p.kind == thfReadBack: return p.message

proc fillFullText(h: var SegyTextHeader, lines: openArray[string], rev: SegyRevision,
    fixCards: bool) =
  # `lines` already fit. Each line is written as given and padded with spaces.
  var body = newString(TextHeaderSize)
  for i in 0 ..< TextHeaderSize: body[i] = ' '
  let n = min(lines.len, CardCount)
  for i in 0 ..< n:
    let line = lines[i]
    let start = i * CardWidth
    let take = min(line.len, CardWidth)
    for j in 0 ..< take: body[start + j] = line[j]
  h.text = body
  if fixCards:
    h.setCard(39, revisionCard(rev))
    h.setCard(40, endCard())

proc openSegy(s: var WriterState, like: SeismicFile, format: SegyTargetFormat,
    fullText: seq[string], fixCards: bool, binaryOverrides: openArray[HeaderOverride]) =
  var f = if s.segyRevOn: s.segyFile else: like.index.segy
  if not s.segyRevOn:
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
    if fullText.len > 0: fillFullText(f.text, fullText, f.revision, fixCards)
  f.binary = f.binary.withBinaryOverrides(f.revision, binaryOverrides)
  # The post-rewrite count: 0 when the target cleared it, so `close` does not
  # restore a count that revision does not hold.
  s.segyNumTraces = f.binary.numTraces
  f.binary.numTraces = 0 # set by `close` when the input declares one
  s.segyFixed = f.revision.major >= 1 and f.binary.fixedLengthTraces == 1
  s.segyCount = -1
  # Validate now; the real writer opens at the first trace.
  discard openSegyWriter(NullSink(name: s.path), f, initSegyWriteOptions(f, s.segyLenient))
  s.segyFile = f
  s.makeSink()

proc openSegd(s: var WriterState, like: SeismicFile, format: SegdTargetFormat) =
  if format != tfKeep:
    let fmt = segdSampleFormats[ord(format) - 1]
    for rec in like.index.segdRecords:
      if not fmt.definedIn(rec.revision):
        refuse("SEG-D format " & $format & " is not defined in Rev " & $rec.revision &
          " (record " & $rec.index & ")")
    s.segdFormat = some(fmt)
  s.makeSink()
  s.segd = openSegdWriter(s.sink, SegdWriteOptions(), like.index.segdLabel)

proc prepareLikeRevision(path: string, like: SeismicFile, format: SegyTargetFormat,
    fullText: seq[string], fixCards: bool, target: SegyRevision, f: var SegyFile,
    rw: var RevRewrite, log: var DiagLog) =
  # Fatals of a revision change, in `convertSegy`'s words, before any file exists.
  let fault = revisionFault(target)
  if fault.len > 0: refuse(fault)
  let order = like.index.segy.byteOrder
  let fmt = if format == stKeep: like.index.segy.format else: some(format.toSampleFormat)
  if fmt.isNone:
    refuse("the input's SEG-Y format code " & $like.index.segy.binary.formatCode &
      " is undefined; choose a segyFormat")
  if format != stKeep:
    let ff = chosenFormatFault(target, fmt.get, $format, order)
    if ff.len > 0: refuse(ff)
  let endian = endianFault(target, order)
  if endian.len > 0: refuse(endian)
  if format == stKeep:
    let ff = keptFormatFault(target, fmt.get, order)
    if ff.len > 0: refuse(ff)
  f = like.index.segy
  let fatal = prepareRevision(f, target, log, Location(file: path), rw)
  if fatal.len > 0: refuse(fatal)
  f.binary.formatCode = int16(ord(fmt.get))
  f.format = fmt
  if fullText.len > 0: fillFullText(f.text, fullText, target, fixCards)

proc openLike(path: string, memory: bool, like: SeismicFile, segyFormat: SegyTargetFormat,
    segdFormat: SegdTargetFormat, seg2Format: Seg2TargetFormat, fullText: seq[string],
    fixCards: bool, segyRevision: Option[SegyRevision],
    binaryOverrides: openArray[HeaderOverride]): SeismicWriter =
  # `openSeismicWriter(path, like)` and `openSeismicWriterBytes(like)`; see there.
  let kind = like.kind
  if binaryOverrides.len > 0 and kind != skSegy:
    refuse("binaryOverrides applies only to a SEG-Y like file, not " & $kind)
  if segyRevision.isSome and kind != skSegy:
    refuse("segyRevision applies only to a SEG-Y like file, not " & $kind)
  let changing = kind == skSegy and segyRevision.isSome and
    segyRevision.get != like.index.segy.revision
  let textRev = if kind == skSegy and segyRevision.isSome: segyRevision.get
                elif kind == skSegy: like.index.segy.revision
                else: SegyRevision()
  if fullText.len > 0:
    if kind != skSegy:
      refuse("a full textual header is only written for SEG-Y, not " & $kind)
    let fault = textFault(fullText, textRev, like.index.segy.text.encoding, fixCards)
    if fault.len > 0: refuse(fault)
  if kind == skUnknown: refuse("the file " & like.path & " is not SEG-Y, SEG-D or SEG-2")
  if like.demuxPath.len > 0:
    refuse(like.path & " holds multiplexed SEG-D; convert it to a demultiplexed file " &
      "first (`convertSegdRevision`)")
  if (segyFormat != stKeep and kind != skSegy) or (segdFormat != tfKeep and kind != skSegd) or
      (seg2Format != s2tKeep and kind != skSeg2):
    refuse("a sample format was chosen for another standard than the input's (" & $kind & ")")
  if memory and kind == skSeg2:
    refuse("SEG-2 cannot be written to memory (its writer needs a file); write it to a path")
  var same = false
  if not memory and not like.inMemory:
    try: same = fileExists(path) and sameFile(like.path, path)
    except OSError: discard
  if same: refuse("the output " & path & " is the input file")
  var prepared: SegyFile
  var rw: RevRewrite
  var revLog: DiagLog
  if changing:
    prepareLikeRevision(path, like, segyFormat, fullText, fixCards, segyRevision.get,
      prepared, rw, revLog)
  if kind == skSegy:
    # Refused here, before the output exists; `openSegy` applies them.
    discard (if changing: prepared else: like.index.segy).binary.withBinaryOverrides(
      if changing: segyRevision.get else: like.index.segy.revision, binaryOverrides)
  result = SeismicWriter(s: WriterState(kind: kind, path: path, open: true, memory: memory,
    tmp: if memory: "" else: createTempFor(path)))
  if changing:
    result.s.segyRevOn = true
    result.s.segyRev = rw
    result.s.segyRevLog = revLog
    result.s.segyLenient = true
    result.s.segyFile = prepared
  try:
    case kind
    of skSegy: result.s.openSegy(like, segyFormat, fullText, fixCards, binaryOverrides)
    of skSegd: result.s.openSegd(like, segdFormat)
    of skSeg2:
      if seg2Format != s2tKeep: result.s.seg2Format = toSeg2Format(ord(seg2Format))
      result.s.seg2 = openSeg2Writer(result.s.tmp, like.index.seg2)
    of skUnknown: discard
  except CatchableError:
    result.s.discardOutput()
    raise

proc openSeismicWriter*(path: string, like: SeismicFile, segyFormat = stKeep,
    segdFormat = tfKeep, seg2Format = s2tKeep, fullText: seq[string] = @[],
    fixCards = true, segyRevision: Option[SegyRevision] = none(SegyRevision),
    binaryOverrides: openArray[HeaderOverride] = []): SeismicWriter =
  ## A writer of a file at `path` in `like`'s standard, revision and byte
  ## order, with `like`'s file-level headers (see the module doc). The
  ## sample format is the input's unless `segyFormat`, `segdFormat` or
  ## `seg2Format` (for `like`'s standard only) names one. A non-empty
  ## `fullText` replaces the SEG-Y textual header: up to 40 lines of up to
  ## 80 characters, written as given and padded with spaces. `fixCards`
  ## (true by default) then sets cards 39 and 40 to the standard strings for
  ## the file's revision; false writes `fullText` untouched. Only `like`'s
  ## index is used, so it may be closed.
  ##
  ## `segyRevision` (`none`, the default) writes a SEG-Y `like` file as
  ## another revision: the source headers, rewritten as `convertSegy`
  ## rewrites them. `none`, or the source's own revision, leaves the bytes
  ## as a writer without the parameter writes them. Cards 39 and 40 name the
  ## target revision when it differs. `fixCards` false leaves the caller's
  ## cards 39 and 40 untouched only when `fullText` replaces the header;
  ## without `fullText`, a differing revision always rewrites them.
  ## A trace identification code is kept as stored. What the target drops
  ## (extended text, trailers, Trace Header Extension 1, a survey type, a
  ## time rounded or clamped, a card 39 or 40 that held other text) is listed
  ## by `revisionNotes`, in `convertSegy`'s
  ## words, not by `close`. A variable-length trace whose count or interval
  ## does not fit is skipped: an error in `revisionNotes`, and it is not
  ## counted. A fixed-length count or interval that does not fit is refused.
  ##
  ## `binaryOverrides` set named fields of the SEG-Y binary file header
  ## (`binary.<field>`, e.g. `binary.jobId`), after the revision change and
  ## written exactly; they apply to a SEG-Y `like` only. Refused: the fields
  ## that size the file or name the revision (`samplesPerTrace`, `formatCode`,
  ## `extSamplesPerTrace`, `byteOrderMarker`, `segyMajor`, `segyMinor`,
  ## `fixedLengthTraces`, `numExtTextHeaders`, `maxAddlTraceHeaders`,
  ## `numTraces`, `firstTraceOffset`, `numTrailerRecords`), the sample interval
  ## fields (`sampleInterval`, `sampleIntervalOrig`, `extSampleInterval`,
  ## `extSampleIntervalOrig`), an unknown field, a value outside the field's
  ## range and a Rev 2 field when the output is Rev 0 or 1.
  ##
  ## Raises `ValueError` for an unrecognized or
  ## multiplexed SEG-D `like`, a refused `binaryOverrides` entry, `binaryOverrides` on a non-SEG-Y `like`, a format for another standard or one the
  ## revision lacks, `path` being `like`'s file, `fullText` on a non-SEG-Y
  ## `like`, a `fullText` that `checkTextHeader` faults for length,
  ## characters or a header the reader would misread, `segyRevision` set on
  ## a non-SEG-Y `like` (the message names the parameter), a `segyRevision`
  ## other than 0, 1, 2.0 or 2.1, a sample format or byte order that
  ## revision cannot hold, or a fixed-length count or interval that does not
  ## fit it (each of these before any file is
  ## created); `SegFormatError` for
  ## file headers the writer refuses; `IOError` when the output cannot be
  ## created.
  openLike(path, false, like, segyFormat, segdFormat, seg2Format, fullText, fixCards,
    segyRevision, binaryOverrides)

proc openSeismicWriterBytes*(like: SeismicFile, name = "memory", segyFormat = stKeep,
    segdFormat = tfKeep, fullText: seq[string] = @[], fixCards = true,
    segyRevision: Option[SegyRevision] = none(SegyRevision),
    binaryOverrides: openArray[HeaderOverride] = []): SeismicWriter =
  ## `openSeismicWriter(path, like)` that collects the file in memory:
  ## `finishBytes` returns its bytes, and nothing touches the disk. `name`
  ## is the display name in diagnostics and `path`. SEG-Y and SEG-D only
  ## (`ValueError` for SEG-2 `like`: its writer needs a file); otherwise the
  ## same checks and refusals as the file writer, except those about the
  ## output file. `fullText`, `fixCards`, `segyRevision` and `binaryOverrides` are
  ## as for the file writer. `like` may itself be a file in memory.
  openLike(name, true, like, segyFormat, segdFormat, s2tKeep, fullText, fixCards,
    segyRevision, binaryOverrides)

func textCard(s: string): string =
  # A line as card text: printable ASCII only, cut to the card after its prefix.
  result = s[0 ..< min(s.len, CardWidth - 4)]
  for ch in result.mitems:
    if ch notin {' '..'~'}: ch = ' '

proc openNewSegy(path: string, memory: bool, opts: SegyOutputOptions): SeismicWriter =
  # `openSeismicWriter(path, opts)` and `openSeismicWriterBytes(opts)`; see there.
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
  if opts.fullText.len > 0:
    let fault = textFault(opts.fullText, rev, opts.textEncoding, opts.fixCards)
    if fault.len > 0: refuse(fault)
  elif opts.text.len > 38:
    refuse("the textual header holds 38 lines of text, not " & $opts.text.len)
  var f = SegyFile(byteOrder: opts.byteOrder, format: some(fmt), revision: rev,
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(opts.textEncoding))
  if opts.fullText.len > 0:
    fillFullText(f.text, opts.fullText, rev, opts.fixCards)
  else:
    let lines = if opts.text.len > 0: opts.text else: @["WRITTEN BY parseSEG " & PackageVersion]
    for i, line in lines: f.text.setCard(i + 1, cardPrefix(i + 1) & line.textCard)
    f.text.setCard(39, revisionCard(rev))
    f.text.setCard(40, endCard())
  f.binary = SegyBinaryHeader(formatCode: int16(ord(fmt)), segyMajor: rev.major,
    segyMinor: rev.minor, traceSorting: opts.traceSorting,
    measurementSystem: opts.measurementSystem, sampleInterval: 1000, samplesPerTrace: 1)
  if rev.major >= 2:
    f.binary.byteOrderMarker = ByteOrderMarker
    f.binary.maxAddlTraceHeaders = 1
    f.extended.addEndText()
    f.binary.numExtTextHeaders = int16(f.extended.recordCount)
  f.binary = f.binary.withBinaryOverrides(rev, opts.binaryOverrides)
  result = SeismicWriter(s: WriterState(kind: skSegy, path: path,
    tmp: if memory: "" else: createTempFor(path),
    open: true, memory: memory, segyFresh: true, segyCount: -1))
  try:
    # Validate now (with a placeholder interval); the real writer opens at the first trace.
    discard openSegyWriter(NullSink(name: path), f, initSegyWriteOptions(f))
    result.s.segyFile = f
    result.s.makeSink()
  except CatchableError:
    result.s.discardOutput()
    raise

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
  ## than 0, 1, 2.0 or 2.1, or a `fullText` that `checkTextHeader` faults
  ## for length, characters or a header the reader would misread, or a
  ## refused `binaryOverrides` entry (before any file is created); `IOError` when the output cannot be created.
  openNewSegy(path, false, opts)

proc openSeismicWriterBytes*(opts: SegyOutputOptions, name = "memory"): SeismicWriter =
  ## `openSeismicWriter(path, opts)` that collects the new SEG-Y file in memory
  ## instead of a file: `finishBytes` returns its bytes, byte for byte what the file
  ## writer writes, and nothing touches the disk. `name` is the display name in
  ## diagnostics and `path`. The same checks and refusals as the file writer (`ValueError`,
  ## `SegFormatError`), except those about the output file.
  openNewSegy(name, true, opts)

proc checkRecordingTime(t: float64, what: string)

proc openNewSegd(path: string, memory: bool, opts: SegdOutputOptions): SeismicWriter =
  # `openSeismicWriter(path, opts)` and `openSeismicWriterBytes(opts)`; see there.
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
  let window = dt * float64(opts.numSamples)
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
  result = SeismicWriter(s: WriterState(kind: skSegd, path: path,
    tmp: if memory: "" else: createTempFor(path),
    open: true, memory: memory, segdFresh: true, segdOpts: fixed, segdRecTime: NaN))
  try:
    result.s.makeSink()
    result.s.segd = openSegdWriter(result.s.sink, SegdWriteOptions())
  except CatchableError:
    result.s.discardOutput()
    raise

proc openSeismicWriter*(path: string, opts: SegdOutputOptions): SeismicWriter =
  ## A writer of a new SEG-D Rev 3 file at `path`, for traces built from
  ## `TraceKeys` (`writeTrace(w, keys, samples)`), grouped into records by
  ## `keys.record`. The sample interval, sample count and sample format come
  ## from `opts`; a record is buffered until the next record number or
  ## `close`, then written whole. Raises `ValueError` for a revision other
  ## than 3.0 or 3.1, a format that revision lacks, a sample interval that
  ## is not a whole number of microseconds from 1 to 2^32-1, a sample count
  ## below 1, a window (count times the interval) longer than
  ## 2^32-1 µs, format 8015 with a count that is not a multiple of 4,
  ## coordinate units other than metres, feet or unknown, or a `time` that
  ## is set but not a finite UTC time in 1950-2049; `IOError` when the
  ## output cannot be created.
  openNewSegd(path, false, opts)

proc openSeismicWriterBytes*(opts: SegdOutputOptions, name = "memory"): SeismicWriter =
  ## `openSeismicWriter(path, opts)` that collects the new SEG-D Rev 3 file in memory
  ## instead of a file: `finishBytes` returns its bytes, byte for byte what the file
  ## writer writes, and nothing touches the disk. `name` is the display name in
  ## diagnostics and `path`. The same checks and refusals as the file writer (`ValueError`,
  ## `SegFormatError`), except those about the output file.
  openNewSegd(name, true, opts)

# ----------------------------------------------------------------- SEG-Y --

proc setTraceCount(t: var SegyTrace, n: int) =
  # The trace headers' sample count.
  if not t.setSampleCount(n):
    refuse("a trace of " & $n & " samples needs Trace Header Extension 1 (SEG-Y Rev 2), " &
      "which this trace lacks")

proc setFileCount(b: var SegyBinaryHeader, n: int) =
  # The binary header's samples per trace.
  if not b.setBinarySampleCount(n):
    refuse($n & " samples per trace need SEG-Y Rev 2")

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

proc applyStanzas(s: var WriterState) =
  # The stanzas `addStanza` collected go into the extended header, once: before
  # a final EndText record, which is put back after them, with the binary
  # header's record count (and a set first trace offset) following.
  if s.segyStanzas.len == 0: return
  template f: untyped = s.segyFile
  let had = f.extended.recordCount
  let hadEnd = f.extended.hasEndText
  var ext = f.extended.withoutEndText()
  for st in s.segyStanzas:
    let before = ext.stanzas.len
    ext.addStanza(st.company, st.name, st.data, st.contentType, st.binary)
    # What the reader finds must be the stanza as given.
    let want = normalizeStanzaName(st.company & ":" & st.name)
    var found = false
    for k in before ..< ext.stanzas.len:
      let sn = ext.stanzas[k]
      if sn.key == want and sn.isBinary == st.binary and
          (not st.binary or sn.byteCount == st.data.len): found = true
    if not found:
      refuse("the stanza " & st.company & ":" & st.name & " does not read back as written")
  if hadEnd: ext.addEndText()
  let added = ext.recordCount - had
  f.extended = ext
  if f.binary.numExtTextHeaders >= 0: f.binary.numExtTextHeaders = int16(ext.recordCount)
  if f.binary.firstTraceOffset != 0:
    f.binary.firstTraceOffset += uint64(added * TextHeaderSize)
  s.segyStanzas = @[]

proc startSegy(s: var WriterState) =
  s.applyStanzas()
  s.segy = openSegyWriter(s.sink, s.segyFile, initSegyWriteOptions(s.segyFile, s.segyLenient))
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
    fields: GeometryFields): bool =
  # False when a revision change skips the trace (`convertSegy` would): not
  # written, and the caller must not count it.
  result = true
  if s.segyFresh:
    # Its binary header (interval, Ext1 count) is made for traces from keys;
    # a template trace's headers would disagree with it.
    refuse("a writer opened from SegyOutputOptions takes traces from keys " &
      "(writeTrace(w, keys, samples)), not template traces")
  let n = samples.len
  template t: untyped = s.segyTrace
  withTemplateHeaders(s, src, trace, TraceHeaderSize, keys, fields, h):
    loadSegyTrace(src, trace, h, t)
  if s.segyRevOn:
    t.sampleInterval = readSampleInterval(src.index.segy, t)
    if n != t.numSamples: t.numSamples = n
    let fileLoc = Location(file: s.path)
    let traceLoc = Location(file: s.path, trace: trace)
    if not rewriteTrace(s.segyRev, t, s.segyFixed, s.segyRevLog, fileLoc, traceLoc):
      return false
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
  if s.segyRevOn: finishRevision(s.segyRev, s.segyRevLog, Location(file: s.path))
  if not s.segyStarted: s.startSegy()
  s.segy.close()
  log.add s.segy.log
  s.sink.close()
  s.sink = nil
  # The binary header's counts, now known. Same bytes as `convertSegy`.
  var b = s.segyFile.binary
  let bytes = writtenCountBytes(b, s.written, s.segyMax, s.segyCount != -1,
    s.segyNumTraces, s.segyFile.byteOrder)
  if bytes.len > 0:
    if s.memory:
      s.mem.patch(s.segyFile.tapeLabel.len + TextHeaderSize, bytes)
      return
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

proc segdRec(recNo: int, path: string): string =
  "SEG-D record " & $recNo & " of " & path

proc refuse8015(trace: int, path: string, n: int) =
  refuse("SEG-D format 8015 holds samples in groups of 4; trace " & $trace & " of " &
    path & " has " & $n)

proc refuseTraceCount(recNo, n: int, path: string) =
  refuse(segdRec(recNo, path) & ": " & $n & " samples do not fit the trace header extension")

func traceCountFits(t: SegdTrace, n: int): bool =
  case t.layout
  of slRev2: t.ext1.isNone or n <= 0x00_FF_FFFF
  of slRev3: n >= 0 and n <= int(high(uint32))

proc setTraceCount(t: var SegdTrace, n: int) =
  t.numSamples = n
  case t.layout
  of slRev2:
    if t.ext1.isSome:
      var x = t.ext1.get
      x.samplesPerTrace = uint32(n)
      t.ext1 = some(x)
  of slRev3:
    if t.ext1Rev3.isSome:
      var x = t.ext1Rev3.get
      x.numSamples = uint32(n)
      t.ext1Rev3 = some(x)

proc setRev2ExtLength(rec: var SegdRecord, ms, recNo: int, path: string) =
  if rec.gh2.isNone:
    refuse(segdRec(recNo, path) & " has no General Header #2 for a record length of " &
      $ms & " ms")
  if ms < 0 or ms > 0xFFFFFF:
    refuse(segdRec(recNo, path) & ": a record length of " & $ms &
      " ms does not fit General Header #2")
  var g2 = rec.gh2.get
  g2.extRecordLength = uint32(ms)
  rec.gh2 = some(g2)

proc setRev2RecordLength(rec: var SegdRecord, ms, recNo: int, path: string) =
  if ms < 0:
    refuse(segdRec(recNo, path) & ": a record length of " & $ms & " ms is negative")
  if rec.gh1.recordLength == BcdAllF:
    setRev2ExtLength(rec, ms, recNo, path)
    return
  let ms64 = int64(ms)
  if ms64 * 10 mod 1024 == 0:
    let tenths = ms64 * 10 div 1024
    if tenths <= 999:
      rec.gh1.recordLength = int(tenths)
      return
  rec.gh1.recordLength = BcdAllF
  setRev2ExtLength(rec, ms, recNo, path)

proc setRev3RecordLength(rec: var SegdRecord, us: int64, recNo: int, path: string) =
  if us < 0 or us > int64(high(uint32)):
    refuse(segdRec(recNo, path) & ": a record length of " & $us &
      " µs does not fit General Header #2")
  if rec.gh1.recordLength == BcdAllF:
    rec.gh2Rev3.extRecordLength = uint32(us)
    return
  if us mod 102400 == 0:
    let tenths = us div 102400
    if tenths <= 999:
      rec.gh1.recordLength = int(tenths)
      return
  rec.gh1.recordLength = BcdAllF
  rec.gh2Rev3.extRecordLength = uint32(us)

proc setName(scan, ch: int): string =
  "channel set " & $ch & " of scan type " & $scan

proc setLabel(rec: SegdRecord, i, j: int): string =
  # A channel set by its own numbers, as `applySegdCount` names it.
  case rec.layout
  of slRev2:
    let c = rec.scanTypes[i].descriptors[j]
    setName(if c.scanTypeNumber > 0: c.scanTypeNumber else: i + 1,
      if c.channelSetNumber > 0: c.channelSetNumber else: j + 1)
  of slRev3:
    let c = rec.scanTypes[i].descriptorsRev3[j]
    setName(if c.scanTypeNumber > 0: c.scanTypeNumber else: i + 1,
      if c.channelSetNumber > 0: int(c.channelSetNumber) else: j + 1)

proc setRev2End(c: var SegdChannelSetDescriptor, g1: SegdGeneralHeader1, n: int,
    which: string) =
  # End time is an exact multiple of 2 ms: start + n * BSI / (32 * 2^exp).
  if c.subscanExponent < 0 or c.subscanExponent > 9 or int(g1.baseScanInterval16) <= 0:
    refuse(which & " has no usable sample interval")
  let denom = 32 * (1 shl c.subscanExponent)
  let num = int64(n) * int64(g1.baseScanInterval16)
  if num mod int64(denom) != 0:
    refuse(which & ": an end time for " & $n & " samples is not a multiple of 2 ms")
  let endAt = int64(c.startTime) + num div int64(denom)
  if endAt < 0 or endAt > int64(high(uint16)):
    refuse(which & ": an end time of " & $endAt & " (2 ms units) does not fit a channel set")
  c.endTime = uint16(endAt)
  let si = c.sampleIntervalMs(g1)
  let window = if si > 0: int(round((c.endTimeMs - c.startTimeMs) / si)) else: -1
  if window != n:
    refuse(which & ": the channel set window would not read back as " & $n & " samples")

proc setRev3End(c: var SegdChannelSetDescriptorRev3, n: int, which: string) =
  if n < 0 or n > int(high(uint32)):
    refuse(which & ": " & $n & " samples do not fit a channel set")
  let interval = int64(c.samplingInterval)
  if interval <= 0:
    refuse(which & " has no sample interval")
  let endAt = int64(c.startTime) + int64(n) * interval
  if endAt < int64(low(int32)) or endAt > int64(high(int32)):
    refuse(which & ": an end time of " & $endAt & " µs does not fit a channel set")
  c.endTime = int32(endAt)
  c.numSamples = uint32(n)

proc applySegdCount(rec: var SegdRecord, n, recNo: int, path: string) =
  # Rewrites the headers a new sample count changes. The caller passes a copy.
  if n == 0:
    refuse(segdRec(recNo, path) & ": a sample count of 0 cannot be written")
  if rec.isRev3 and rec.gh3.extendedRecordingMode == 1:
    refuse(segdRec(recNo, path) & " is in extended recording mode, which keeps the " &
      "record length at 0, so the sample count cannot change")
  if rec.scanTypes.len == 0:
    refuse(segdRec(recNo, path) &
      " has no channel set, so a new sample count cannot be written")
  case rec.layout
  of slRev2:
    if n > 0x00_FF_FFFF:
      for s in rec.scanTypes:
        if s.layout != slRev2: continue
        for c in s.descriptors:
          if c.channelCount > 0 and c.traceHeaderExtensions > 0:
            refuseTraceCount(recNo, n, path)
    var longest = 0
    var any = false
    for i in 0 ..< rec.scanTypes.len:
      if rec.scanTypes[i].layout != slRev2:
        refuse(segdRec(recNo, path) & " has a channel set the record's revision cannot update")
      for j in 0 ..< rec.scanTypes[i].descriptors.len:
        let c = addr rec.scanTypes[i].descriptors[j]
        if c.channelCount > 0:
          any = true
          let st = if c.scanTypeNumber > 0: c.scanTypeNumber else: i + 1
          let cs = if c.channelSetNumber > 0: c.channelSetNumber else: j + 1
          setRev2End(c[], rec.gh1, n, segdRec(recNo, path) & ", " & setName(st, cs))
          longest = max(longest, int(c.endTime) * 2)
    if not any:
      refuse(segdRec(recNo, path) &
        " has no channel set, so a new sample count cannot be written")
    setRev2RecordLength(rec, longest, recNo, path)
  of slRev3:
    var longest = low(int64)
    var any = false
    for i in 0 ..< rec.scanTypes.len:
      if rec.scanTypes[i].layout != slRev3:
        refuse(segdRec(recNo, path) & " has a channel set the record's revision cannot update")
      for j in 0 ..< rec.scanTypes[i].descriptorsRev3.len:
        let c = addr rec.scanTypes[i].descriptorsRev3[j]
        if c.channelsInSet > 0:
          any = true
          let st = if c.scanTypeNumber > 0: c.scanTypeNumber else: i + 1
          let cs = if c.channelSetNumber > 0: int(c.channelSetNumber) else: j + 1
          setRev3End(c[], n, segdRec(recNo, path) & ", " & setName(st, cs))
          let span = int64(n) * int64(c.samplingInterval)
          longest = max(longest, max(span, int64(c.endTime)))
    if not any:
      refuse(segdRec(recNo, path) &
        " has no channel set, so a new sample count cannot be written")
    setRev3RecordLength(rec, longest, recNo, path)

proc noteRev3Sizes(rec: var SegdRecord, traces: openArray[SegdTrace]) =
  # GH#3 sizes from the bytes about to be written. A zero stays zero.
  if not rec.isRev3: return
  var data = rec.headerBytes
  for t in traces:
    var hdr = SegdTraceHeaderSize
    if t.ext1Rev3.isSome: hdr += SegdBlockSize
    hdr += t.extensions.len
    data += int64(hdr) + int64(t.samples.len)
  if rec.gh3.dataSize != 0: rec.gh3.dataSize = uint64(data)
  if rec.gh3.recordSize != 0:
    rec.gh3.recordSize = uint64(data + int64(rec.trailerRev3.len))

proc rebuildSkew(rec: var SegdRecord, sets: openArray[SubsetSet]) =
  # Rev 2 skew blocks hold one byte per channel and subscan of each channel set, in
  # scan order. A kept channel keeps its own byte; the blocks are as many as
  # the longest scan type needs.
  if rec.layout != slRev2 or rec.gh1.skewBlocks <= 0 or rec.gh1.skewBlocks == BcdAllF:
    return
  var dropped = false
  for ss in sets:
    if ss.kept != max(rec.scanTypes[ss.scan].descriptors[ss.chan].channelCount, 0):
      dropped = true
  for i in 0 ..< rec.scanTypes.len:
    for j in 0 ..< rec.scanTypes[i].descriptors.len:
      var any = false
      for ss in sets:
        if ss.scan == i and ss.chan == j: any = true
      if not any and rec.scanTypes[i].descriptors[j].channelCount > 0: dropped = true
  if not dropped: return
  var fresh = newSeq[seq[byte]](rec.scanTypes.len)
  var most = 0
  for i in 0 ..< rec.scanTypes.len:
    var at = 0
    for j in 0 ..< rec.scanTypes[i].descriptors.len:
      let c = rec.scanTypes[i].descriptors[j]
      let subs = 1 shl (if c.subscanExponent in 0..9: c.subscanExponent else: 0)
      let have = max(c.channelCount, 0)
      var kept: seq[int] = @[]
      for ss in sets:
        if ss.scan == i and ss.chan == j: kept = ss.chans
      for sub in 0 ..< subs:
        for ch in kept:
          let from1 = at + sub * have + ch
          fresh[i].add(if ch < have and from1 < rec.scanTypes[i].skew.len:
            rec.scanTypes[i].skew[from1] else: 0'u8)
      at += subs * have
    most = max(most, (fresh[i].len + SegdBlockSize - 1) div SegdBlockSize)
  for i in 0 ..< rec.scanTypes.len:
    fresh[i].setLen most * SegdBlockSize
    rec.scanTypes[i].skew = fresh[i]
  rec.gh1.skewBlocks = most

proc applySubset(rec: var SegdRecord, sets: openArray[SubsetSet], recNo: int,
    path: string) =
  # Headers a subset changes: each channel set's channel count (0 when no kept
  # trace is in it), the Rev 2 skew bytes, the end time of a set whose count
  # changed, and, when an end time changed or a set emptied, the record
  # length. A set whose count is not known yet (-1) keeps its own. The
  # caller passes a copy.
  var recompute = false
  var longest = low(int64)
  template find(i, j: int): int =
    var at = -1
    for k in 0 ..< sets.len:
      if sets[k].scan == i and sets[k].chan == j: at = k
    at
  for ss in sets:
    if ss.n == 0: refuse(segdRec(recNo, path) & ": a sample count of 0 cannot be written")
    if ss.n > 0 and ss.n != ss.srcN: recompute = true
  rebuildSkew(rec, sets)
  case rec.layout
  of slRev2:
    for i in 0 ..< rec.scanTypes.len:
      for j in 0 ..< rec.scanTypes[i].descriptors.len:
        let c = addr rec.scanTypes[i].descriptors[j]
        let at = find(i, j)
        if at < 0:
          if c.channelCount > 0: recompute = true
          c.channelCount = 0
        else:
          c.channelCount = sets[at].kept
          if sets[at].n > 0 and sets[at].n != sets[at].srcN:
            setRev2End(c[], rec.gh1, sets[at].n, segdRec(recNo, path) & ", " &
              setLabel(rec, i, j))
    for s in rec.scanTypes:
      for c in s.descriptors:
        if c.channelCount > 0: longest = max(longest, int64(c.endTime) * 2)
  of slRev3:
    for i in 0 ..< rec.scanTypes.len:
      for j in 0 ..< rec.scanTypes[i].descriptorsRev3.len:
        let c = addr rec.scanTypes[i].descriptorsRev3[j]
        let at = find(i, j)
        if at < 0:
          if c.channelsInSet > 0: recompute = true
          c.channelsInSet = 0
        else:
          c.channelsInSet = uint32(sets[at].kept)
          if sets[at].n > 0 and sets[at].n != sets[at].srcN:
            setRev3End(c[], sets[at].n, segdRec(recNo, path) & ", " & setLabel(rec, i, j))
    for k in 0 ..< sets.len:
      # The trace length, whether the count changed or not: a set that starts
      # at a negative time ends before its traces do.
      let c = rec.scanTypes[sets[k].scan].descriptorsRev3[sets[k].chan]
      let n = if sets[k].n > 0: sets[k].n else: sets[k].srcN
      longest = max(longest, max(int64(n) * int64(c.samplingInterval), int64(c.endTime)))
  if recompute:
    case rec.layout
    of slRev2: setRev2RecordLength(rec, int(longest), recNo, path)
    of slRev3: setRev3RecordLength(rec, longest, recNo, path)

proc dropRecord(s: var WriterState) =
  # Forgets the record in progress and a pending subset. Nothing of a record
  # is written before it ends, so nothing is on disk.
  s.written -= s.likeTraces.len
  s.likeTraces.setLen 0
  s.inRecord = false
  s.subset.setLen 0
  s.likeKept.setLen 0
  s.likeSets.setLen 0
  s.likeSetOf.setLen 0
  s.likePos = 0
  s.likeN = 0
  s.likeSame = true

proc finishRecord(s: var WriterState) =
  # The like: path buffers a record so a later count mismatch can be refused
  # before any byte of it is written. Headers go out only when it is complete.
  if not s.inRecord: return
  if s.likeKept.len > 0:
    if s.likePos != s.likeKept.len:
      refuse("SEG-D record " & $s.recIndex & " of " & s.recPath & " is incomplete: " &
        $s.likePos & " of the " & $s.likeKept.len & " traces of its subset were written")
    var rec = s.likeRec
    applySubset(rec, s.likeSets, s.recIndex, s.recPath)
    if rec.isRev3: noteRev3Sizes(rec, s.likeTraces)
    s.segd.writeRecordHeaders(rec)
    for t in s.likeTraces: s.segd.writeTrace(t)
    s.segd.endRecord()
    s.inRecord = false
    s.likeTraces.setLen 0
    s.likeKept.setLen 0
    s.likeSets.setLen 0
    s.likeSetOf.setLen 0
    s.likePos = 0
    s.likeN = 0
    s.likeSame = true
    return
  if s.nextTrace != s.recLast + 1:
    refuse("SEG-D record " & $s.recIndex & " of " & s.recPath & " is incomplete: traces " &
      $s.recFirst & ".." & $(s.nextTrace - 1) & " of " & $s.recFirst & ".." & $s.recLast &
      " were written (records are written whole)")
  var rec = s.likeRec
  if not s.likeSame:
    applySegdCount(rec, s.likeN, s.recIndex, s.recPath)
    for t in s.likeTraces.mitems: setTraceCount(t, s.likeN)
    if rec.isRev3: noteRev3Sizes(rec, s.likeTraces)
  s.segd.writeRecordHeaders(rec)
  for t in s.likeTraces: s.segd.writeTrace(t)
  s.segd.endRecord()
  s.inRecord = false
  s.likeTraces.setLen 0
  s.likeN = 0
  s.likeSame = true

proc startRecord(s: var WriterState, src: SeismicFile, trace, n: int, t: SegdTrace) =
  # Checks that `trace` can start its record and ends the record in progress.
  # Headers wait until the record's last trace (`finishRecord`).
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
  let srcN = int(entries[trace].numSamples)
  # An 8015 source written with its own count keeps whatever count it has;
  # a count that is new, or a conversion to 8015, must fill whole groups.
  if fOut == sd8015 and n mod 4 != 0 and (rec.format.get != sd8015 or n != srcN):
    refuse8015(trace, src.path, n)
  if n != srcN:
    var trial = rec
    applySegdCount(trial, n, r, src.path)
    if not traceCountFits(t, n): refuseTraceCount(r, n, src.path)
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
  s.likeRec = rec
  s.likeN = n
  s.likeSame = n == srcN
  s.likeTraces.setLen 0
  s.inRecord = true
  s.recPath = src.path
  s.recMem = src.memoryId
  s.recIndex = r
  s.recFirst = trace
  s.recLast = last
  s.nextTrace = trace
  s.recFormat = fOut

const TimestampBlockType = 0x42'u8

func isSourceBlock(b: uint8): bool {.inline.} = b in 0x15'u8 .. 0x19'u8 or b == 0x1F'u8

proc patchBlocks(bytes: var seq[byte], fileNo: int64, gps: int64) =
  # Rev 3 header blocks of 32 bytes: a Source Description holds the file number,
  # a Timestamp the instant of the first sample. Negative values keep.
  var a = 0
  while a + SegdBlockSize <= bytes.len:
    let kind = bytes[a + SegdBlockSize - 1]
    if fileNo >= 0 and isSourceBlock(kind):
      var b = decodeBlock[SegdSourceDescription](bytes.toOpenArray(a, a + SegdBlockSize - 1))
      b.extFileNumber = uint32(fileNo)
      let e = b.encoded
      for q in 0 ..< SegdBlockSize: bytes[a + q] = e[q]
    elif gps != low(int64) and kind == TimestampBlockType:
      var b = decodeBlock[SegdTimestampHeader](bytes.toOpenArray(a, a + SegdBlockSize - 1))
      b.timeZeroOfData = gps
      let e = b.encoded
      for q in 0 ..< SegdBlockSize: bytes[a + q] = e[q]
    a += SegdBlockSize

proc applyRecordPatch(rec: var SegdRecord, p: SubsetPatch) =
  # The record's headers with the patch; ValueError for a name or a value that does not fit.
  if p.fileNumber < -1 or p.fileNumber > 0xFF_FFFF:
    refuse("a file number of " & $p.fileNumber & " does not fit: 0..16777215, or -1 to keep")
  if not p.time.isNaN: checkRecordingTime(p.time, "the subset's time")
  for o in p.headers:
    let (blk, field) = splitName(o)
    let digits = if blk.len > 2 and blk.startsWith("gh"): blk[2 .. ^1] else: ""
    let num = if digits.len in 1 .. 6 and digits.allCharsInSet({'0' .. '9'}): parseInt(digits)
      else: -1
    if blk == "gh1":
      if field in ["fileNumber", "year", "julianDay", "hour", "minute", "second"]:
        refuse(o.name & ": the file number and the time are set with SubsetPatch.fileNumber " &
          "and SubsetPatch.time, which change every place that holds them")
      rec.gh1.setOverride(hbSegdGh1, field, o)
    elif rec.layout == slRev2 and num >= 3 and num - 3 < rec.sourceHeaders.len:
      rec.sourceHeaders[num - 3].setOverride(hbSegdGhN, field, o)
    else:
      refuse(o.name & ": the record fields are gh1 and, in Rev 2, the source headers gh3, gh4, ...")
  if p.headers.len > 0:
    # A value that a field cannot hold (a BCD field of too few digits) comes back changed.
    template holds(h, what: untyped) =
      try:
        let e = h.encoded
        var back = decodeBlock[typeof(h)](e)
        back.raw = h.raw
        if back != h: refuse("a header value does not fit its field in " & what)
      except SegFormatError as err:
        refuse("a header value does not fit its field in " & what & ": " & err.msg)
    holds(rec.gh1, "General Header #1")
    if rec.layout == slRev2:
      for h in rec.sourceHeaders: holds(h, "a source header")
  if p.fileNumber >= 0:
    let n = p.fileNumber
    rec.gh1.fileNumber = if n < 10000: int(n) else: BcdAllF
    case rec.layout
    of slRev2:
      if rec.gh2.isSome:
        var g = rec.gh2.get
        g.extFileNumber = uint32(n)
        rec.gh2 = some(g)
      for h in rec.sourceHeaders.mitems: h.extFileNumber = uint32(n)
    of slRev3:
      rec.gh2Rev3.extFileNumber = uint32(n)
      patchBlocks(rec.generalBlocks, n, low(int64))
  if not p.time.isNaN:
    let civil = fromUnix(int64(floor(p.time))).utc
    rec.gh1.year = civil.year mod 100
    rec.gh1.julianDay = civil.yearday + 1
    rec.gh1.hour = civil.hour
    rec.gh1.minute = civil.minute
    rec.gh1.second = civil.second
    if rec.layout == slRev3: rec.gh3.timeZero = unixToTimestamp(p.time)

proc applyTracePatch(t: var SegdTrace, p: SubsetPatch, startUs: int64) =
  # The trace with the patch: its file number, and in Rev 3 its Timestamp block.
  if p.fileNumber >= 0:
    t.header.fileNumber = if p.fileNumber < 10000: int(p.fileNumber) else: BcdAllF
    t.header.extFileNumber = uint32(p.fileNumber)
  let gps = if p.time.isNaN: low(int64) else: unixToTimestamp(p.time) + startUs
  if t.layout == slRev3: patchBlocks(t.extensions, p.fileNumber, gps)

proc beginSubset(s: var WriterState, src: SeismicFile, trace: int) =
  # Starts the record of the traces `startSubset` listed, at its first.
  if src.path != s.subPath or src.memoryId != s.subMem:
    refuse("the subset was listed for " & s.subPath & ", not " & src.path)
  if trace != s.subset[0]:
    refuse("the subset starts with trace " & $s.subset[0] & ", not trace " & $trace)
  template entries: untyped = src.index.entries
  let r = int(entries[trace].record)
  var rec = src.index.segdRecords[r]
  if rec.format.isNone:
    refuse("SEG-D record " & $r & " has the undefined format code " & $rec.gh1.formatCode)
  let fOut = s.segdFormat.get(rec.format.get)
  if not fOut.definedIn(rec.revision):
    refuse("SEG-D format " & $ord(fOut) & " is not defined in Rev " & $rec.revision &
      " (record " & $r & ")")
  var sets: seq[SubsetSet] = @[]
  var setOf: seq[int] = @[]
  # Each kept trace's channel: its place among the record's traces of its set. Only a
  # Rev 2 skew rebuild reads it; the walk over the record is kept for the next subset.
  let wantChans = rec.layout == slRev2 and rec.gh1.skewBlocks in 1 .. 98
  if wantChans and not (s.chOpen == src.openId and s.chRec == r and s.chIdx.len > 0):
    var first = trace
    while first > 0 and int(entries[first - 1].record) == r: dec first
    var counts: seq[tuple[key, n: int]] = @[]
    s.chIdx.setLen 0
    var at0 = first
    while at0 < entries.len and int(entries[at0].record) == r:
      let key = int(entries[at0].scanType) * 65536 + entries[at0].channelSet.int
      var c = -1
      for q in 0 ..< counts.len:
        if counts[q].key == key: c = q
      if c < 0:
        counts.add (key: key, n: 0)
        c = counts.high
      s.chIdx.add int32(counts[c].n)
      inc counts[c].n
      inc at0
    s.chOpen = src.openId
    s.chRec = r
    s.chFirst = first
  for pos, k in s.subset:
    let e = entries[k]
    let (st, cs) = (int(e.scanType), e.channelSetIndex)
    let known = st >= 0 and st < rec.scanTypes.len and cs >= 0 and
      cs < (if rec.layout == slRev2: rec.scanTypes[st].descriptors.len
        else: rec.scanTypes[st].descriptorsRev3.len)
    if not known: refuse("trace " & $k & " of " & src.path & " has no known channel set")
    var at = -1
    for i in 0 ..< sets.len:
      if sets[i].scan == st and sets[i].chan == cs: at = i
    if at < 0:
      sets.add SubsetSet(scan: st, chan: cs, n: -1, srcN: int(e.numSamples))
      at = sets.high
    inc sets[at].kept
    sets[at].chans.add(if wantChans: int(s.chIdx[k - s.chFirst]) else: 0)
    setOf.add at
  if fOut != rec.format.get:
    rec.gh1.formatCode = ord(fOut)
    rec.format = some(fOut)
  rec.applyRecordPatch(s.subPatch)
  s.likeRec = rec
  s.vctxKey = ""
  s.likeSets = sets
  s.likeSetOf = setOf
  s.likeKept = s.subset
  s.subset.setLen 0
  s.likePos = 0
  s.likeN = 0
  s.likeSame = false
  s.likeTraces.setLen 0
  s.inRecord = true
  s.recPath = src.path
  s.recMem = src.memoryId
  s.recIndex = r
  s.recFirst = s.likeKept[0]
  s.recLast = s.likeKept[^1]
  s.nextTrace = s.recFirst
  s.recFormat = fOut

const NoVendorMaps = VendorRegistry()

proc vendorOverride(t: var SegdTrace, o: HeaderOverride, field: string,
    reg: VendorRegistry, ctx: VendorContext) =
  # Writes a vendor map field into the trace's extension blocks: the first block
  # (Rev 2: by extension number from 2; Rev 3: by type byte) where it applies.
  if reg.maps.len == 0: refuse(o.name & ": no vendor maps are set: vendor overrides need a writer opened like " &
    "a SEG-D file (openSeismicWriter(path, like = f)) and useVendorMaps")
  let v = case o.value.kind
    of fvInt: VendorValue(kind: vvInt, intVal: o.value.intVal)
    of fvFloat: VendorValue(kind: vvFloat, floatVal: o.value.floatVal)
    of fvText: VendorValue(kind: vvText, text: o.value.text)
  var why: seq[string]
  var done = false
  var at = 0
  var k = 0
  while not done and at + SegdBlockSize <= t.extensions.len:
    var span = SegdBlockSize
    var area = VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1, extIndex: k + 2)
    if t.layout == slRev3:
      let ty = t.extensions[at + 31]
      area = VendorArea(kind: vtBlock, blockIndex: -1, blockType: int(ty),
        where: "traceHeader", extIndex: -1)
      if ty == BlockTypePosition1 and at + 96 <= t.extensions.len and
          t.extensions[at + 63] == BlockTypePosition2 and
          t.extensions[at + 95] == BlockTypePosition3:
        span = 3 * SegdBlockSize
    try:
      reg.setVendorField(ctx, area, t.extensions.toOpenArray(at, at + span - 1), field, v)
      done = true
    except VendorFieldAbsentError as e:
      if e.msg notin why: why.add e.msg
    except ValueError as e:
      # The field is decoded here: a value that does not fit is refused, not tried elsewhere.
      refuse(o.name & ": " & e.msg)
    at += span
    inc k
  if not done:
    refuse(o.name & ": " & (if why.len == 0: "the trace has no extension blocks"
      else: why.join("; ")))

func hasVendorOverride(overrides: openArray[HeaderOverride]): bool =
  for o in overrides:
    if o.name.startsWith("vendor."): return true

proc ensureVendorContext(s: var WriterState, key: string, rec: SegdRecord) =
  # The context `(when (record ...))` reads, for the record as it will be written
  # (the source headers as encoded, after a subset's patch); made once per record.
  if s.vctxKey != key:
    let blocks = s.vendor.usesRecordBlocks
    s.vctx = vendorContext(rec, blocks)
    if blocks and rec.layout == slRev2:
      s.vctx.general.setLen 0
      for g in rec.sourceHeaders: s.vctx.general.add g.encoded
    s.vctxKey = key

proc overrideSegd(t: var SegdTrace, overrides: openArray[HeaderOverride],
    reg: VendorRegistry = NoVendorMaps, ctx: VendorContext = VendorContext()) =
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
    of "vendor": t.vendorOverride(o, field, reg, ctx)
    of "timestamp":
      # Rev 3: the Timestamp block's fields, e.g. the instant of the first sample.
      var at = -1
      var a = 0
      while at < 0 and t.layout == slRev3 and a + SegdBlockSize <= t.extensions.len:
        if t.extensions[a + SegdBlockSize - 1] == TimestampBlockType: at = a
        a += SegdBlockSize
      if at < 0: refuse(o.name & ": the trace has no Timestamp block")
      var x = decodeBlock[SegdTimestampHeader](
        t.extensions.toOpenArray(at, at + SegdBlockSize - 1))
      x.setOverride(hbSegdTimestamp, field, o)
      let e = x.encoded
      for q in 0 ..< SegdBlockSize: t.extensions[at + q] = e[q]
    else: refuse(o.name & ": SEG-D trace blocks are trace, ext1, vendor and (Rev 3) timestamp")

proc writeSegd[T: SampleType](s: var WriterState, src: SeismicFile, trace: int,
    samples: openArray[T], overrides: openArray[HeaderOverride], keys: ptr TraceKeys,
    fields: GeometryFields) =
  if s.segdFresh:
    refuse("a writer opened from SegdOutputOptions takes traces from keys " &
      "(writeTrace(w, keys, samples)), not template traces")
  if src.demuxPath.len > 0:
    refuse(src.path & " holds multiplexed SEG-D; convert it to a demultiplexed file first")
  let e = src.index.entries[trace]
  let r = int(e.record)
  let n = samples.len
  let srcN = int(e.numSamples)
  if int(e.headerBytes) < SegdTraceHeaderSize:
    refuse("the headers of trace " & $trace & " lie outside the file")
  # The overrides are checked before the record's headers can be written.
  var t: SegdTrace
  withTemplateHeaders(s, src, trace, SegdTraceHeaderSize, keys, fields, h):
    t = loadSegdTrace(src, trace, src.index.segdRecords[r], h)
  # A finished subset record ends when a trace that starts a record comes.
  if s.subset.len == 0 and s.likeKept.len > 0 and s.likePos == s.likeKept.len and
      (trace == 0 or int(src.index.entries[trace - 1].record) != r):
    s.finishRecord()
  # A subset's traces take the record's patch first, then the overrides.
  if s.subset.len == 0 and s.likeKept.len == 0:
    if overrides.hasVendorOverride:
      s.ensureVendorContext($src.openId & ":" & $r, src.index.segdRecords[r])
    t.overrideSegd(overrides, s.vendor, s.vctx)
  let begun = s.subset.len > 0
  if begun: s.beginSubset(src, trace)
  let sameRec = s.inRecord and s.recPath == src.path and s.recMem == src.memoryId and
    s.recIndex == r
  var flip = false
  try:
    if s.likeKept.len > 0:
      # A subset record: its traces in the listed order, one count per channel set.
      if not sameRec:
        refuse("SEG-D record " & $s.recIndex & " of " & s.recPath & " is incomplete: " &
          $s.likePos & " of the " & $s.likeKept.len & " traces of its subset were written")
      if s.likePos == s.likeKept.len:
        refuse(segdRec(r, src.path) & ": all " & $s.likeKept.len & " traces of its subset " &
          "are written (startSubset starts the next record)")
      if trace != s.likeKept[s.likePos]:
        refuse("SEG-D record " & $r & ": trace " & $s.likeKept[s.likePos] & " comes next, not " &
          $trace & " (a subset's traces are written in the order listed)")
      let at = s.likeSetOf[s.likePos]
      var sets = s.likeSets
      if sets[at].n >= 0 and sets[at].n != n:
        refuse(segdRec(r, src.path) & ": " & setLabel(s.likeRec, sets[at].scan, sets[at].chan) &
          " has " & $sets[at].n & " samples; trace " & $trace & " has " & $n)
      if s.recFormat == sd8015 and n mod 4 != 0 and
          (src.index.segdRecords[r].format.get != sd8015 or n != srcN):
        refuse8015(trace, src.path, n)
      if n != srcN and not traceCountFits(t, n): refuseTraceCount(r, n, src.path)
      var fresh = false
      if sets[at].n < 0:
        sets[at].n = n
        var trial = s.likeRec
        applySubset(trial, sets, r, src.path)
        fresh = true
      if n != srcN: setTraceCount(t, n)
      let startUs = if s.likeRec.layout == slRev3: int64(s.likeRec.scanTypes[
        sets[at].scan].descriptorsRev3[sets[at].chan].startTime) else: 0'i64
      t.applyTracePatch(s.subPatch, startUs)
      if overrides.hasVendorOverride: s.ensureVendorContext("subset", s.likeRec)
      t.overrideSegd(overrides, s.vendor, s.vctx)
      if fresh: s.likeSets = sets
    elif sameRec:
      if trace != s.nextTrace:
        refuse("SEG-D record " & $r & ": trace " & $s.nextTrace & " comes next, not " & $trace &
          " (a record's traces are written in input order)")
      if n != s.likeN and not (s.likeSame and n == srcN):
        refuse(segdRec(r, src.path) & " has " & $s.likeN & " samples; trace " & $trace &
          " has " & $n)
      if s.recFormat == sd8015 and n mod 4 != 0 and
          (src.index.segdRecords[r].format.get != sd8015 or n != srcN):
        refuse8015(trace, src.path, n)
      if s.likeSame and n != srcN:
        var trial = s.likeRec
        applySegdCount(trial, n, r, src.path)
        if not traceCountFits(t, n): refuseTraceCount(r, n, src.path)
        flip = true
      elif not s.likeSame and not traceCountFits(t, n):
        refuseTraceCount(r, n, src.path)
    else:
      s.startRecord(src, trace, n, t)
    t.index = if s.likeKept.len > 0: s.likePos else: trace - s.recFirst
    t.numSamples = n
    t.samples = newSeq[byte](dataBytes(s.recFormat, n))
    # 8015 fractions as the input was read: its convention is the file's.
    encodeSamples(s.recFormat, samples, t.samples, src.index.codecs[r].twosComplement8015)
    s.likeTraces.add t
    if flip: s.likeSame = false
    s.nextTrace = trace + 1
    if s.likeKept.len > 0: inc s.likePos
  except CatchableError:
    # A refused first trace leaves nothing of the record: the caller may start another.
    if begun: s.dropRecord()
    raise

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
  BlockTypeTimestamp = 0x42'u8 ## Timestamp header: instant of sample 0.
  BlockTypeSourceInfo = 0x20'u8 ## Additional Source Info: source event time.

func segdExtCount(hasPos, hasOrient, hasSrc, hasSrcInfo, hasSrcPos: bool): int {.inline.} =
  # THE#1, optional receiver Position (3), optional Source Description,
  # optional Additional Source Info, optional source Position (3), Timestamp,
  # optional Orientation. The flags are the channel set's skeleton, so every
  # trace of the set has this count. A shot gather passes the source flags false.
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

proc orientationBlock(o: TraceOrientation, recorded: float64): SegdOrientation =
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

proc firstSampleGpsUs(k: TraceKeys, recorded: float64): int64 =
  # 0x42 is the instant of sample 0, not time zero. An origin uses
  # `firstSampleUs`; caller-built keys (`toNone`) have `time` as time zero,
  # so add `t0Ms`. `recorded` is that time, or the record's when the trace
  # has none.
  if k.timeOrigin != toNone:
    let us = k.firstSampleUs
    if us.isSome: return utcUsToGpsUs(us.get)
  let delay = if k.t0Ms.isNaN: 0'i64 else: int64(round(k.t0Ms * 1000.0))
  utcUsToGpsUs(int64(round(recorded * 1e6)) + delay)

proc ghTimeZeroGpsUs(k: TraceKeys, recTime: float64): int64 =
  # GPS µs of the record time zero (GH#3, and GH#1's whole second). A
  # re-read Rev 3 trace has origin `toFirstSample` and `time` at sample 0,
  # so the shot is that instant minus `t0Ms` (integer µs; NaN is 0). Any
  # other origin, or a first-sample instant that is not known, is `recTime`,
  # as before. Does not change `recorded`.
  if k.timeOrigin == toFirstSample:
    let fs = k.firstSampleUs
    if fs.isSome:
      let delay = if k.t0Ms.isNaN: 0'i64 else: int64(round(k.t0Ms * 1000.0))
      return utcUsToGpsUs(fs.get - delay)
  unixToTimestamp(recTime)

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
    stanza: uint16, hasSrc, hasInfo, hasSrcPos: bool): seq[byte] =
  # This trace's source, in the order the reader and the standard use: a
  # Source Description, Additional Source Info, then the source Position.
  # The flags are the channel set's skeleton, so every trace of the set
  # carries the same blocks. A trace that does not name a source gets 0/0
  # and an invalid position; time 0 means the shot is at record time zero.
  result = @[]
  if not hasSrc and not hasInfo and not hasSrcPos: return
  let hasSt = knownStation(k.srcLine, k.srcPoint)
  if hasSrc:
    let sb = SegdSourceDescription(extFileNumber: uint32(fileNo),
      sourceLineNumber: if hasSt: k.srcLine else: 0.0,
      sourcePointNumber: if hasSt: k.srcPoint else: 0.0,
      sourcePointIndex: if hasSt: uint8(k.srcIndex) else: 0'u8,
      sourceSetNumber: 1, depthIndex: 1, blockType: 0x1F)
    result.add sb.encoded
  if hasInfo:
    let atRecord = not (hasSt or k.hasSourceXY) or sameNum(recorded, recTime)
    var info = SegdAdditionalSourceInfo(
      time: if atRecord: 0'i64 else: unixToTimestamp(recorded),
      blockType: BlockTypeSourceInfo)
    for i in 0 ..< info.errorDescription.len: info.errorDescription[i] = ' '
    result.add info.encoded
  if hasSrcPos:
    if k.hasSourceXY:
      result.add positionBlock(k.srcX, k.srcY, k.srcZ, true, stanza).encoded
    else:
      result.add positionBlock(0, 0, NaN, false, 0).encoded

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
      found = setType.len - 1
    setOf[i] = found
    inc setCount[found]
    if p.keys.hasReceiverXY: setPos[found] = true
  let rg = opts.receiverGather
  # One skeleton per channel set: Rev 3 requires every trace of a set to
  # carry the same number of header extensions, equal to the descriptor.
  var setSrc = newSeq[bool](setType.len)
  var setInfo = newSeq[bool](setType.len)
  var setSrcPos = newSeq[bool](setType.len)
  var setOrient = newSeq[bool](setType.len)
  for j, ct in setType:
    var anyOrient = false
    var missing = -1
    for i, p in s.segdPending:
      if setOf[i] != j: continue
      if p.orientation.isSome: anyOrient = true
      elif missing < 0: missing = i
    if anyOrient and missing >= 0:
      refuse("SEG-D channel set " & $ct &
        ": give every trace of a channel set an orientation, or none; trace channel " &
        $s.segdPending[missing].channel & " has none")
    setOrient[j] = anyOrient
    if not rg: continue
    for i, p in s.segdPending:
      if setOf[i] != j: continue
      let bearing = knownStation(p.keys.srcLine, p.keys.srcPoint) or p.keys.hasSourceXY
      if bearing: setSrc[j] = true
      if p.keys.hasSourceXY: setSrcPos[j] = true
      if bearing and not sameNum(p.recorded, s.segdRecTime): setInfo[j] = true
  var traces = newSeq[SegdTrace](s.segdPending.len)
  for i, p in s.segdPending:
    let si = setOf[i]
    let exts = segdExtCount(setPos[si], setOrient[si], setSrc[si], setInfo[si],
      setSrcPos[si])
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
      extBytes.add sourceExtBytes(p.keys, fileNo, p.recorded, s.segdRecTime, stanza,
        setSrc[si], setInfo[si], setSrcPos[si])
    # The reader takes a trace's time from this block when it is present,
    # ahead of General Header #3, and takes it as the instant of sample 0.
    # General Header #3 keeps the record's time zero.
    extBytes.add SegdTimestampHeader(timeZeroOfData: firstSampleGpsUs(p.keys, p.recorded),
      blockType: BlockTypeTimestamp).encoded
    if setOrient[si]:
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
  # GH#1 holds whole seconds of the time General Header #3 holds: the record
  # time zero. A re-read `toFirstSample` trace subtracts `t0Ms` in integer µs.
  let tzGps = ghTimeZeroGpsUs(s.segdPending[0].keys, recTime)
  let civil = fromUnix(int64(floor(timestampToUnix(tzGps)))).utc
  var gh1 = SegdGeneralHeader1(formatCode: ord(fmt), recordType: 8, recordLength: BcdAllF,
    year: civil.year mod 100, julianDay: civil.yearday + 1, hour: civil.hour,
    minute: civil.minute, second: civil.second,
    scanTypesPerRecord: 1, skewBlocks: 0, extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
  var extSmall = 0
  var extBig = 0'u32
  setBcdOrExt(extSmall, extBig, int64(s.segdExternal.len div SegdBlockSize), 2)
  gh1.externalHeaderBlocks = extSmall
  rec.external = move s.segdExternal
  var fileSmall = 0
  var fileExt = 0'u32
  setBcdOrExt(fileSmall, fileExt, fileNo, 4)
  gh1.fileNumber = fileSmall
  if additional <= 14: gh1.additionalGhBlocks = uint8(additional)
  else: gh1.additionalGhBlocks = 0xF
  let nCS = setType.len
  if nCS <= 99: gh1.channelSetsPerScanType = nCS
  else: gh1.channelSetsPerScanType = BcdAllF
  let span = opts.sampleIntervalUs * float64(opts.numSamples)
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
  gh2.extExternalHeaderBlocks = extBig
  if gh1.baseScanInterval16 == 0xFF:
    gh2.dominantSamplingInterval = uint32(opts.sampleIntervalUs)
  var longest = span
  for t0 in setT0: longest = max(longest, float64(t0) + span)
  # in range: writeSegdKeys refuses a window whose end does not fit an int32
  gh2.extRecordLength = uint32(longest)
  rec.gh2Rev3 = gh2
  rec.gh3 = SegdGeneralHeader3(timeZero: tzGps, blockType: BlockTypeGeneralHeader3)
  var descs: seq[SegdChannelSetDescriptorRev3] = @[]
  for j, ct in setType:
    let endUs = float64(setT0[j]) + span
    var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(j + 1),
      channelType: uint8(ord(ct)), startTime: setT0[j], numSamples: uint32(opts.numSamples),
      descaleMultiplier: 1.0, channelsInSet: uint32(setCount[j]),
      samplingInterval: uint32(opts.sampleIntervalUs), arrayForming: 1,
      traceHeaderExtensions: uint8(segdExtCount(setPos[j], setOrient[j], setSrc[j],
        setInfo[j], setSrcPos[j])), verticalStack: 1,
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

const MaxExternalHeader = 0xFF_FFFF * SegdBlockSize
  ## Bytes of a SEG-D external header the writer accepts: General Header #2's extended
  ## external header block count is 24 bits (and GH#3's 32-bit header size holds a header
  ## this long). The reader holds at most `DefaultMaxHeaderBytes` (256 MiB) of header
  ## areas by default; a longer header reads back `incomplete`.

proc checkExternal(s: WriterState, h: openArray[byte]) =
  # An external header of the keys form: its length, and agreement with the
  # one the record's first trace set. Nothing is changed.
  if h.len == 0: return
  if h.len mod SegdBlockSize != 0:
    refuse("an external header is whole 32-byte blocks; this one has " & $h.len & " bytes")
  if h.len > MaxExternalHeader:
    refuse("an external header of " & $h.len & " bytes is longer than " & $MaxExternalHeader &
      " (General Header #2's 24-bit block count could not hold it)")
  if s.segdHaveRec and (h.len != s.segdExternal.len or
      not equalMem(unsafeAddr h[0], unsafeAddr s.segdExternal[0], h.len)):
    refuse("the external header differs from the one the first trace of SEG-D record " &
      $s.segdRecNo & " set (a record has one external header: pass it with the first trace, " &
      "and nothing or the same bytes with the others)")

proc writeSegdKeys[T: SampleType](s: var WriterState, k: TraceKeys, samples: openArray[T],
    overrides: openArray[HeaderOverride], channelType: SegdChannelType,
    orientation: Option[TraceOrientation], externalHeader: openArray[byte]) =
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
  checkExternal(s, externalHeader)
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
  if float64(t0) + dt * float64(n) > float64(high(int32)):
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
  if not s.segdHaveRec: s.segdExternal = @externalHeader # the record's first trace sets it
  s.segdPending.add SegdKeyTrace(keys: k, channelType: channelType, samples: raw,
    overrides: ov, orientation: orientation, t0Us: t0, channel: num, recorded: recorded)
  s.segdHaveRec = true
  s.segdRecNo = recNo

proc closeSegd(s: var WriterState, log: var DiagLog) =
  if s.segdFresh:
    if s.written == 0: refuse("no traces were written")
    s.flushSegdKeys()
  elif s.subset.len > 0:
    refuse("the subset listed for " & s.subPath & " has no trace written (write its " &
      "traces, or abandonRecord)")
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
    of skSegy:
      if not w.s.writeSegy(src, trace, samples, overrides, keys, fields): return
    of skSegd: w.s.writeSegd(src, trace, samples, overrides, keys, fields)
    of skSeg2: w.s.writeSeg2(src, trace, samples, overrides, keys, fields)
    of skUnknown: discard
  except IOError:
    # Part of the trace may be in the file: no later `close` may install it.
    w.s.discardOutput()
    raise
  inc w.s.written


proc startSubset*(w: var SeismicWriter, src: SeismicFile, traces: openArray[int],
    patch = SubsetPatch()) =
  ## Starts a SEG-D output record made of some of the traces of one record of
  ## `src`, a file of the writer's standard (normally `like`): the next
  ## `writeTrace(w, src, trace, samples)` calls must name `traces` in this
  ## order, one per trace. The record ends when the next `startSubset`, a
  ## trace that starts a record of a whole-record write, or `close` comes
  ## (`ValueError` when traces of the list are missing). The same source trace
  ## may start any number of output records.
  ##
  ## The record keeps the source record's headers (the extended header too)
  ## and each kept trace its own header and extension bytes, except what the
  ## subset changes: each channel set's channel count (0 for a set with no
  ## kept trace, which keeps its descriptor); in Rev 2 the skew bytes, which
  ## are rebuilt from the kept channels (each keeps its own byte) with as
  ## many skew blocks as the longest scan type needs; the end time and sample
  ## count of a channel set whose traces are written with a new count; the
  ## record length (the longest trace length or end time over the sets that
  ## have traces, recomputed only when an end time changed or a set emptied);
  ## the trace header sample counts of traces written with a new count; and,
  ## in Rev 3, the General Header #3 sizes. The traces of one channel set
  ## share one count; sets may differ. Otherwise the SEG-D rules of
  ## `writeTrace` hold.
  ##
  ## `patch` gives the record its own identity: file number, time and header
  ## fields (`SubsetPatch`); the traces carry the file number and, in Rev 3,
  ## their Timestamp block. A trace's Timestamp field can be set by the
  ## override `timestamp.timeZeroOfData` (GPS microseconds, as stored) of its
  ## `writeTrace`. A value that does not fit, or an unknown field name, is a
  ## `ValueError` here.
  ##
  ## Nothing of a record is written before it ends. A first trace that
  ## `writeTrace` refuses leaves no record: the caller starts another with
  ## `startSubset`. A later trace that is refused leaves the record as it
  ## was, to be written again; `abandonRecord` drops the record instead.
  ##
  ## Raises `ValueError` for a closed writer, a writer or file of another
  ## standard, a SEG-D file from keys, an empty list, an index outside `src`
  ## or in different records, indexes that do not ascend strictly, a record in
  ## Rev 3 extended recording mode (it keeps the record length at 0), a subset
  ## listed before whose first trace was not written, or the record in
  ## progress being incomplete. A count one channel set's traces do not
  ## share, or one the revision cannot hold (Rev 2 end times are multiples of
  ## 2 ms), is `ValueError` from `writeTrace`.
  if not w.s.open: refuse("the writer is closed")
  if src.kind != w.s.kind or w.s.kind != skSegd:
    refuse("a subset needs a SEG-D writer and a SEG-D file")
  if w.s.segdFresh:
    refuse("a writer opened from SegdOutputOptions takes traces from keys, not subsets")
  if not src.isOpen: refuse("the file " & src.path & " is closed")
  if w.s.subset.len > 0:
    refuse("the subset listed for " & w.s.subPath & " has no trace written yet (write " &
      "its traces, or abandonRecord)")
  if traces.len == 0: refuse("a subset needs at least one trace")
  let rec = src.traceEntry(traces[0]).record
  for i in 0 ..< traces.len:
    if src.traceEntry(traces[i]).record != rec:
      refuse("trace " & $traces[i] & " is outside the record of trace " & $traces[0])
    if i > 0 and traces[i] <= traces[i - 1]:
      refuse("the subset's traces must ascend: " & $traces[i] & " follows " & $traces[i - 1])
  let head = src.index.segdRecords[int(rec)]
  if head.isRev3 and head.gh3.extendedRecordingMode == 1:
    refuse(segdRec(int(rec), src.path) & " is in extended recording mode, which keeps " &
      "the record length at 0: it cannot be written from a subset")
  var probe = head
  probe.applyRecordPatch(patch) # ValueError for a patch that does not fit, before any change
  w.s.finishRecord()
  w.s.subPatch = patch
  w.s.subset = @traces
  w.s.subPath = src.path
  w.s.subMem = src.memoryId

proc useVendorMaps*(w: var SeismicWriter, reg: VendorRegistry) =
  ## Sets the vendor header maps that `vendor.<field>` overrides of a SEG-D
  ## trace (`HeaderOverride`) use, replacing any set before. The field is
  ## written into the first of the copied trace's extension blocks (Rev 2:
  ## extension numbers 2 and up; Rev 3: every block type, a Position triple as
  ## one block) where the map decodes it, as `setVendorField` does, with the
  ## output record's headers (a subset's patch applied) as the context of
  ## `(when (record ...))`. A value that does not fit the field is refused, not
  ## tried in a later block. A map set after the writer opened serves every
  ## later trace; the registry is copied. Raises `ValueError` for a closed
  ## writer, a SEG-Y or SEG-2 one, or one opened from `SegdOutputOptions`.
  if not w.s.open: refuse("the writer is closed")
  if w.s.kind != skSegd or w.s.segdFresh:
    refuse("vendor maps serve a SEG-D writer opened like a SEG-D file " &
      "(openSeismicWriter(path, like = f))")
  w.s.vendor = reg
  w.s.vctxKey = ""
  w.s.vctx = VendorContext()

proc abandonRecord*(w: var SeismicWriter) =
  ## Drops the SEG-D record in progress, or the subset listed by
  ## `startSubset` whose traces were not written, with the traces buffered
  ## for it. Nothing of a record is on disk before it ends, so the output
  ## holds the records before it. Raises `ValueError` for a closed writer.
  if not w.s.open: refuse("the writer is closed")
  w.s.dropRecord()

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
  ## block raises `ValueError` and nothing is written. A `segyRevision`
  ## whose target cannot hold this trace's count or interval skips it (see
  ## `openSeismicWriter`): nothing is written, and `len` does not count it.
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
    orientation: Option[TraceOrientation] = none(TraceOrientation),
    externalHeader: openArray[byte] = []) =
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
  ## - the trace identification code is `traceCode` when non-zero and
  ##   `status` is the status the code has in the output's revision (so a
  ##   known status changed in the keys wins), or is `tsUnknown`, which says
  ##   nothing: the code is written as given, also one the revision does not
  ##   define (the file then reads back that code's status in its revision:
  ##   code 1 with `tsUnknown` reads back `tsLive`), or is `tsAuxiliary` with
  ##   a code the revision leaves to optional use. Keys read from a SEG-Y file
  ##   (`traceCodeRev`) do not carry an unknown code over into a revision that
  ##   gives that number a meaning (Rev 0 code 12 is not Rev 1's vertical
  ##   geophone): it is written as 0. Otherwise the code is 1 (live), 2
  ##   (dead) or 0 (unknown; also auxiliary, which SEG-Y has no general code
  ##   for). `component` is not written as a code: outside SEG-Y it is a
  ##   group index or sensor type;
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
  ## the description. Rev 3 requires every trace of a channel set to carry
  ## the same header extensions, equal to the descriptor's count, so the
  ## set's skeleton is fixed before the first trace is written (the record
  ## is buffered until the next record or `close`). If any trace of the set
  ## has a source description or a source position, every trace gets those
  ## blocks: 0/0 and an invalid position where the trace has none. If any
  ## source-bearing trace is not at record time zero, every trace of the set
  ## gets Additional Source Info; a shot at record time zero, or a trace
  ## with no source, is written with time 0 (at record time zero). The file
  ## keeps write order. Sort by source line then source point before writing;
  ## the writer does not sort.
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
  ## `tsAuxiliary` with seismic or EM. The record's time zero is the first
  ## trace's `keys.time` when that is set, otherwise `SegdOutputOptions.time`;
  ## with neither, the record is refused (the message names both). When that
  ## trace's origin is `toFirstSample`, the time zero written is its
  ## first-sample instant minus `t0Ms` (integer microseconds; a NaN `t0Ms`
  ## is 0): a re-read Rev 3 trace has `time` at sample 0, and this keeps
  ## the shot. This applies only when that trace's first-sample instant is
  ## known (`firstSampleUs` is some); otherwise the time zero is
  ## `SegdOutputOptions.time`. It is written in General Header #1 (year,
  ## julian day and the whole second of that time) and in General Header
  ## #3's timestamp.
  ## The Timestamp block (0x42) holds the first-sample instant:
  ## `firstSampleUs` when the keys carry an origin, otherwise `keys.time`
  ## plus `t0Ms` (caller-built keys: `time` is time zero; a trace with no
  ## `time` uses the record's). The reader takes a trace's time from that
  ## block when it is present, else from General Header #3, so a re-read
  ## Rev 3 trace has origin `toFirstSample` and its `time` is the first
  ## sample (the origin says so). A trace without a Timestamp block reads
  ## back the record's time zero. Traces of one record may
  ## differ. The writer never invents a time.
  ## `orientation` (`some` of a `TraceOrientation`, or none) writes one
  ## Orientation header (0x60) after the Timestamp block of that trace. Its
  ## timestamp is `time` when that is set, otherwise the trace's recording
  ## time. A trace given none gets no Orientation block, so a file written
  ## without one is unchanged. Every trace of a channel set must be given an
  ## orientation, or none of them: a mix is refused, and the message names
  ## the channel set and the first trace without one (a filler block would
  ## be a fake attitude). A file whose channel sets were already uniform
  ## stays byte-identical. Metres or feet are
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
  ## `rotationApplied`, a channel set that mixes traces with and without an
  ## orientation, an orientation time that is not finite or does not
  ## fit a SEG-D timestamp, or an orientation passed to a writer that is not
  ## SEG-D Rev 3 (nothing of that trace is written then); `SegFormatError` for a value
  ## the format cannot hold; `IOError` on a write failure, which discards
  ## the output and closes the writer.
  if not w.s.open: refuse("the writer is closed")
  if externalHeader.len > 0 and not w.s.segdFresh:
    refuse("an external header is written only to SEG-D Rev 3 (openSeismicWriter with " &
      "SegdOutputOptions)")
  if w.s.segdFresh:
    try:
      w.s.writeSegdKeys(keys, samples, overrides, channelType, orientation, externalHeader)
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

# ------------------------------------------------------------ SEG-Y stanzas --

proc checkStanzaName(what, v: string) =
  if v.len == 0: refuse("the stanza's " & what & " is empty")
  for c in v:
    if c notin {' ' .. '~'} or c in {':', '(', ')'}:
      refuse("the stanza's " & what & " \"" & v & "\" holds a character that a stanza header " &
        "cannot carry (only printable ASCII without ':', '(' and ')')")

proc addSegyStanza(w: var SeismicWriter, company, name: string, data: openArray[byte],
    contentType: string, binary: bool) =
  if not w.s.open: refuse("the writer is closed")
  if w.s.kind != skSegy:
    refuse("stanzas are written to SEG-Y extended textual headers; the output is " & $w.s.kind)
  if w.s.segyStarted or w.s.written > 0:
    refuse("a stanza is added before the first trace (the headers are already written)")
  template f: untyped = w.s.segyFile
  if f.revision.major == 0:
    refuse("SEG-Y Rev 0 has no extended textual header, so no stanzas (Rev 1 or later)")
  checkStanzaName("company", company)
  checkStanzaName("name", name)
  if normalizeStanzaName(company & ":" & name) == "SEG:ENDTEXT":
    refuse("((SEG:EndText)) ends the extended textual header and is written by the " &
      "writer itself; it cannot be added as a stanza")
  if contentType.len > 0: checkStanzaName("content type", contentType.replace("/", "-"))
  if binary and data.len > 999_999_999_999_999: refuse("the stanza is too long")
  let base = f.extended
  if not base.isComplete:
    refuse("the extended textual header was only indexed, not held in memory; a stanza " &
      "cannot be added to it")
  if w.s.segyStanzas.len == 0 and (base.inBinaryStanza or base.inUserDataChain):
    refuse("the extended textual header ends inside an unfinished stanza; a stanza cannot " &
      "follow it")
  let records = base.recordCount + w.s.segyStanzaRecords +
    stanzaRecordCount(company, name, data.len, contentType, binary)
  if records > int(high(int16)):
    refuse("the extended textual header would hold " & $records & " records; the binary " &
      "header's count holds up to " & $high(int16))
  # The stanza read on its own is the stanza as given (its data may hold a stanza
  # header at a line start that would end it early).
  var scratch = initExtendedTextHeader()
  scratch.addStanza(company, name, data, contentType, binary)
  let want = normalizeStanzaName(company & ":" & name)
  var found = false
  for st in scratch.stanzas:
    if st.key == want and st.isBinary == binary and (not binary or st.byteCount == data.len):
      found = true
  if not found:
    refuse("the stanza " & company & ":" & name & " would not read back as written " &
      "(its data may hold a stanza header at a line start)")
  w.s.segyStanzaRecords += stanzaRecordCount(company, name, data.len, contentType, binary)
  w.s.segyStanzas.add PendingStanza(company: company, name: name, contentType: contentType,
    data: @data, binary: binary)

proc addStanza*(w: var SeismicWriter, company, name: string, data: openArray[byte],
    contentType = "application/octet-stream") =
  ## Adds a binary stanza `((company:name:contentType:length))` and `data` to the
  ## SEG-Y file's extended textual header, as `ExtendedTextHeader.addStanza` writes it
  ## and `openSeismic` reads it (`index.segy.extended.stanzas`, and a vendor map's
  ## `stanza` target). It starts a record of its own and is padded with NULs to whole
  ## 3200-byte records; the binary header's extended-record count (and, when it was
  ## set, the first trace offset) are updated. Call it any number of times before the
  ## first trace; the stanzas come in call order, ahead of the `((SEG:EndText))`
  ## record that Rev 2 files end with. Names are matched without case or spaces, as
  ## the standard says. Works for a writer of a file and of bytes, from
  ## `SegyOutputOptions` or `like` a SEG-Y file (whose own extended header comes first).
  ## Raises `ValueError` after the first trace, for a writer of another standard (SEG-D,
  ## SEG-2), for SEG-Y Rev 0 (no extended textual header), for an empty `company` or
  ## `name` or one with a character a stanza header cannot carry (`:`, `(`, `)`,
  ## non-printable), for the `((SEG:EndText))` stanza under any spelling the reader matches
  ## (it ends the header and the writer writes it), for a `like` file whose extended header was only indexed, for more
  ## than 32767 records, and when the stanza would not read back as written.
  ## Each call costs its own size: the stanzas are kept and put into the header once, at the
  ## first trace (or `finishBytes`/`close`), so thousands of them are cheap.
  w.addSegyStanza(company, name, data, contentType, true)

proc addTextStanza*(w: var SeismicWriter, company, name, text: string,
    contentType = "text/plain") =
  ## `addStanza` for a text stanza `((company:name:contentType))` followed by `text`
  ## (ASCII; padded with blanks to whole records). The reader gives it no byte count
  ## (`isBinary` false). The same rules and refusals.
  w.addSegyStanza(company, name, encodeText(text, teAscii), contentType, false)

proc dropRecordCaches(s: var WriterState) =
  # What was worked out for a source record is not kept past the writer's end.
  s.chIdx = @[]
  s.vctx = VendorContext()
  s.vctxKey = ""

proc finishWork(w: var SeismicWriter, log: var DiagLog) =
  # What `close` and `finishBytes` share: everything up to the last byte
  # going to the sink; a raise discards the output.
  w.s.dropRecordCaches()
  try:
    case w.s.kind
    of skSegy: w.s.closeSegy(log)
    of skSegd: w.s.closeSegd(log)
    of skSeg2:
      w.s.seg2.close()
      log.add w.s.seg2.log
    of skUnknown: discard
    # Traces written with keys: the values that had no slot or did not fit.
    log.add w.s.keysPlan.finishKeys()
    for why in Seg2NoSlot:
      if w.s.seg2NoSlot[why] > 0:
        log.report(sevWarning, dcValidation, "not written: " & $why & ", in " &
          $w.s.seg2NoSlot[why] & " traces (the first is trace " & $w.s.seg2NoSlotFirst[why] &
          ")", loc = Location(file: w.s.path))
  except CatchableError:
    w.s.discardOutput()
    raise
  w.s.open = false

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
  ## closed, or for a writer of bytes (`finishBytes` finishes that one).
  if not w.s.open: refuse("the writer is closed")
  if w.s.memory:
    refuse("a writer of bytes is finished with finishBytes, not close")
  w.finishWork(result)
  var moved: DiagLog
  finishOutput(w.s.tmp, w.s.path, keep = true, moved) # removes what it cannot move
  w.s.tmp = ""
  for d in moved:
    if d.severity == sevFatal: raise newException(IOError, d.msg & ": " & w.s.path)

proc finishBytes*(w: var SeismicWriter, log: var DiagLog): seq[byte] =
  ## Finishes a writer made by `openSeismicWriterBytes` and returns the bytes
  ## of the file, moved out of the writer (no copy). Does what `close` does
  ## except the move into place: ends the SEG-D record in progress, writes
  ## the SEG-Y trailer, and patches the counts known at the end into the
  ## buffer as a file is patched, so the bytes equal what the file writer
  ## writes for the same traces. The writer's diagnostics (warnings only,
  ## see `close`) are added to `log`. Raises as `close` does (`ValueError`
  ## for an incomplete SEG-D record or a SEG-D file with no traces,
  ## `SegFormatError`), and `ValueError` for a writer opened on a path or
  ## already finished; a raise discards the output.
  if not w.s.open: refuse("the writer is closed")
  if not w.s.memory:
    refuse("a writer of a file is finished with close, not finishBytes")
  w.finishWork(log)
  result = w.s.mem.takeBytes()
  w.s.mem = nil

proc finishBytes*(w: var SeismicWriter): seq[byte] =
  ## `finishBytes(w, log)` without the diagnostics: they are warnings only
  ## (values that had no slot in the headers), which this drops.
  var log: DiagLog
  w.finishBytes(log)
