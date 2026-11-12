## Conversion to SEG-Y (task 8.6). `convertFile` (`convert.nim`) dispatches
## here for `target = skSegy`.
##
## - `convertSegy`: SEG-Y to SEG-Y, with a new revision (0, 1, 2.0 or 2.1),
##   byte order and/or sample format. Headers are carried over. Structures the
##   target revision lacks (extended text before Rev 1; Trace Header
##   Extension 1, proprietary headers and trailers before Rev 2) are dropped,
##   and each kind of loss is logged once. Bytes whose meaning the revision
##   changes are rewritten:
##   - to a later revision: what the input's revision leaves unassigned and
##     the target defines is cleared (Rev 0: binary header bytes 3261-3600
##     and trace header bytes 181-240; Rev 1: binary 3261-3300 and
##     3507-3532), so vendor data there is not read as a field;
##   - to Rev 0: the time scalar is applied to the times of trace bytes
##     95-114, which become whole ms (rounded; clamped beyond ±32767, with a
##     warning), and bytes 181-240 are cleared. A Layout stanza is lost with
##     the extended text, with a warning: the fields it moved stay put;
##   - before Rev 2: a sample count or interval held in the Rev 2 extended
##     fields moves to the 16-bit ones; a trace whose count or interval
##     does not fit them is skipped with an error (a fixed-length file of
##     such traces is refused).
## - `convertSegdToSegy`: SEG-D (Rev 1, 2.x, 3.x) to SEG-Y. Every record's
##   traces go out in file order, one SEG-Y trace per SEG-D trace (auxiliary
##   traces included, with their trace identification code). The mapping is
##   the table below. Everything SEG-Y has no place for (general, extended
##   and external headers, vendor blocks, the general trailer) is reported,
##   once per kind, as an info diagnostic.
## - `convertSeg2ToSegy`: SEG-2 to SEG-Y, one SEG-Y trace per SEG-2 trace
##   (table below).
## Samples go through float64 (exact for every SEG-D and SEG-Y format) and
## are re-encoded in the target format. The default (`format = stKeep`) picks a
## lossless one: 8048 → 1 (IBM), 8036 → 7 (int24, Rev 2) or 2, 8038 → 2,
## 8080 → 6 (Rev 2) or 5, everything else → 5 (IEEE float32, exact for the
## SEG-D binary-exponent formats). Values are the recorded ones unless
## `applyDescale` multiplies by the channel set's MP factor (Rev 1/2) or
## descale multiplier (Rev 3), giving millivolts. A value that does not fit
## the target format zeroes its trace, with an error diagnostic.
##
## | SEG-Y field | SEG-D source |
## |---|---|
## | traceSeqLine, traceSeqFile | running trace count (1-based) |
## | fieldRecord (Ext1 extFieldRecord) | file number |
## | traceNumberInField, traceInEnsemble | trace number (Rev 3: with extTraceNumber) / index in record |
## | energySourcePoint, shotpointNumber (with shotpointScalar) | source point |
## | traceIdCode | channel type (seismic: by sensor type, 11-14) |
## | numSamples, sampleInterval (Ext1 `ext*`) | trace sample count, channel set interval (µs) |
## | delayRecordingTime | channel set start time (ms) |
## | sourceX/Y, groupX/Y, cdpX/Y, offset (scaled; Ext1 f64) | `TraceKeys` coordinates, offset, midpoint |
## | receiverElevation, sourceSurfaceElevation (scaled; Ext1 f64) | `TraceKeys` z |
## | year, dayOfYear, hour, minute, second, timeBasisCode | GH1 (UTC), or Rev 3 GH#3 time zero |
##
## Rev 2 targets also get a proprietary trace header `PSEGD001` and a
## `((SEG:Layout))` stanza describing it (source/receiver line, point and
## index; sensor type; component; SEG-D record, channel set and channel
## type). SEG-Y readers that honour Layout stanzas, this library included
## (`fieldValue(file, trace, "rec_line")`), read those values back.
##
## SEG-2 to SEG-Y (the SEG-D rules above for formats, losses, Ext1 and the
## `PSEGD001` header apply; record 0, channel set -1):
##
## | SEG-Y field | SEG-2 source |
## |---|---|
## | fieldRecord, traceNumberInField | SHOT_SEQUENCE_NUMBER; CHANNEL_NUMBER (else the trace's position) |
## | ensembleNumber, traceInEnsemble | CDP_NUMBER; CDP_TRACE (else the position) |
## | energySourcePoint, shotpointNumber | SOURCE_STATION_NUMBER |
## | traceIdCode | TRACE_TYPE: DEAD 2, UPHOLE 5, TEST_DATA -1 (other), else the RECEIVER component (12-14) or 1 |
## | numVertSummed, instrumentGainConstant | STACK, FIXED_GAIN |
## | delayRecordingTime; source/group/totalStatic | DELAY; STATIC_CORRECTIONS (s to whole ms) |
## | alias, low-cut, high-cut, notch filter fields | ALIAS_FILTER, LOW_CUT_FILTER, HIGH_CUT_FILTER, NOTCH_FREQUENCY |
## | coordinates, offset, elevations | `TraceKeys` (`SOURCE_` / RECEIVER_LOCATION, z plus DATUM); receiver/sourceDatumElevation: DATUM |
## | transduction constant, units (mV) | DESCALING_FACTOR / STACK |
## | year ... second | ACQUISITION_DATE / _TIME (time basis left 0: SEG-2 gives no zone) |
## | binary traceSorting, measurementSystem, impulsePolarity | TRACE_SORT, UNITS (METERS 1, FEET 2), trace 0's POLARITY (1 → 2, -1 → 1) |
## | textual header | the file strings, one per card (NOTE: one card per line) |
##
## SEG-2 samples go out in one format: their own (1 → 3, 2 → 2, 3 and 4 → 5,
## 5 → 6 in Rev 2), int32 for mixed integer formats, else float64 (Rev 2) or
## float32. Trace strings with no slot are listed in one info note.

import std/[math, os, strutils, times]
import ../common/[endians, errors, diagnostics, years, progress]
import ../io/[records, diskio, memsource]
import ../segy/[reader as segyreader, writer as segywriter, textheader, binheader, traceheader,
  samples, exttext, layout]
import ../segd/[reader as segdreader]
import ../seg2/[reader as seg2reader]
import ../model/[traceindex, keys, headerfields]
import ../survey/join
import ./[tosegd, toseg2]
import ../version
import ../private/[decodeentry, progressticker, sampleconv, segyencode]

const
  ConverterName = "parseSEG " & PackageVersion
  StationHeaderName = "PSEGD001"
  stationLayout = """
<segy-layout name="parseSEG SEG-D stations">
  <extension name="PSEGD001">
    <entry name="sht_line" byte="1" type="ieee64"/>
    <entry name="sht_point" byte="9" type="ieee64"/>
    <entry name="rec_line" byte="17" type="ieee64"/>
    <entry name="rec_point" byte="25" type="ieee64"/>
    <entry name="sht_index" byte="33" type="int2"/>
    <entry name="rec_index" byte="35" type="int2"/>
    <entry name="sensor_type" byte="37" type="int2"/>
    <entry name="component" byte="39" type="int2"/>
    <entry name="segd_record" byte="41" type="int4"/>
    <entry name="segd_channel_set" byte="45" type="int4"/>
    <entry name="segd_channel_type" byte="49" type="int2"/>
  </extension>
</segy-layout>"""

type
  SegyTargetFormat* = enum
    ## The SEG-Y sample format `convertFile` writes: "keep", or a format
    ## code (each value's ordinal is its code; 13 and 14 are undefined).
    stKeep = (0, "keep")
      ## SEG-Y input: its own format. SEG-D input: one that holds every
      ## record's samples exactly (see the module doc).
    st1 = (1, "1"), st2 = (2, "2"), st3 = (3, "3"), st4 = (4, "4"), st5 = (5, "5"),
    st6 = (6, "6"), st7 = (7, "7"), st8 = (8, "8"), st9 = (9, "9"), st10 = (10, "10"),
    st11 = (11, "11"), st12 = (12, "12"), st15 = (15, "15"), st16 = (16, "16")

  ConvertOptions* = object
    ## Target settings. The defaults give SEG-Y Rev 2.1, big-endian, EBCDIC
    ## text, a lossless sample format and recorded (not descaled) values.
    revision*: SegyRevision = SegyRevision(major: 2, minor: 1)
    byteOrder*: ByteOrder = boBig
    format*: SegyTargetFormat = stKeep ## Target sample format ("keep": keep or choose).
    textEncoding*: TextEncoding = teEbcdic ## SEG-D → SEG-Y: the textual header's encoding.
    applyDescale*: bool = false ## SEG-D: write millivolts (MP factor / descale multiplier).
    stationHeader*: bool = true ## SEG-D → SEG-Y Rev 2: the `PSEGD001` header and Layout stanza.
    target*: SeismicKind = skSegy
      ## `convertFile`'s output standard: SEG-Y (the fields above), SEG-D
      ## (`segd`; from SEG-D or SEG-2 input) or SEG-2 (`seg2`; from any input).
    segd*: SegdConvertOptions ## SEG-D output: revision and sample format.
    seg2*: Seg2ConvertOptions ## SEG-2 output: byte order and sample format.

  LossNote = enum
    ## Kinds of information a conversion drops; each is noted once.
    lnExtendedText ## Rev 0 target: extended textual headers dropped.
    lnStanzasAsText ## Rev 1 target: Rev 2 stanzas kept as plain text.
    lnTrailers ## Rev 1 target: data trailers dropped.
    lnTraceExtensions ## Rev 1 target: Trace Header Extension 1 and proprietary headers dropped.
    lnIntervalRounding ## Rev 1 target: fractional sample intervals rounded.
    lnUnassignedBinary ## A later revision: binary header bytes the input's leaves unassigned.
    lnUnassignedTrace ## Rev 0 input: trace bytes 181-240, unassigned there, cleared.
    lnRev1TraceFields ## Rev 0 target: the Rev 1 fields in trace bytes 181-240 dropped.
    lnTimeRounding ## Rev 0 target: times with a time scalar rounded to whole ms.
    lnSegdHeaders ## SEG-D extended/external headers.
    lnSegdGeneral ## SEG-D general header blocks beyond the first source.
    lnSegdTrailers ## SEG-D general trailers.
    lnSegdIntervalRounding ## Rev 1 target: SEG-D intervals rounded to whole µs.
    lnSegdLinePoint ## Rev 1 target: SEG-D line and point not carried.
    lnSegdTimeRange ## A SEG-D record time outside years 1-9999.
    lnSurveyType ## Rev 2.0 target: survey type dropped.
    lnLayoutStanza ## Rev 2.0 target: the Layout stanza is not read.
    lnSeg2Text ## SEG-2 file strings that do not fit the textual header.
    lnSeg2Rounding ## SEG-2 delays or statics rounded to whole ms.
    lnSeg2Units ## SEG-2 UNITS without a SEG-Y measurement system.
    lnSeg2Polarity ## SEG-2 POLARITY varying between traces.

  GeometryJoin* = object
    ## **Internal.** Survey geometry joined to the SEG-D keys before they go
    ## into the SEG-Y headers (`convertWithGeometry`); none when `survey`
    ## is nil.
    survey*: ptr SurveyGeometry
    fields*: GeometryFields
    overwrite*: bool

  Losses = object
    ## Traces whose samples could not be written exactly.
    traces, first: int

proc note(log: var DiagLog, seen: var set[LossNote], kind: LossNote, msg: string,
    loc: Location) =
  # An information-loss note, logged once per kind.
  if kind notin seen:
    seen.incl kind
    log.report(sevInfo, dcValidation, msg, loc = loc)

{.push warning[HoleEnumConv]: off.}
static:
  # `SegyTargetFormat` has a value for each format code, with that ordinal.
  for f in definedSampleFormats: doAssert $SegyTargetFormat(ord(f)) == $ord(f)

func sampleFormat(t: SegyTargetFormat): SampleFormat =
  # The sample format of a target other than `stKeep` (same ordinal).
  SampleFormat(ord(t))

func targetFormat*(f: SampleFormat): SegyTargetFormat =
  ## The target format that writes `f`.
  SegyTargetFormat(ord(f))
{.pop.}

func checkTarget(opts: ConvertOptions, err: var string): bool =
  let r = opts.revision
  if not (r.major == 0 and r.minor == 0 or r.major == 1 and r.minor == 0 or
      r.major == 2 and r.minor in {0'u8, 1}):
    err = "target revision " & $r & " is not 0, 1, 2.0 or 2.1"
    return false
  if opts.format != stKeep:
    let f = opts.format.sampleFormat
    if f.isRev2Format and r.major < 2:
      err = "format " & $opts.format & " needs SEG-Y Rev 2"
      return false
    if sampleSize(f) == 3 and opts.byteOrder == boPairSwapped:
      err = "3-byte format " & $opts.format & " cannot be pair-swapped"
      return false
  if opts.byteOrder != boBig and r.major < 2:
    err = "little-endian and pair-swapped SEG-Y need Rev 2"
    return false
  true

proc add(l: var Losses, trace: int) =
  if l.traces == 0: l.first = trace
  inc l.traces

proc report(log: var DiagLog, l: Losses, fmt: SampleFormat, loc: Location) =
  if l.traces > 0:
    log.report(sevWarning, dcValidation, $l.traces & " traces (the first is trace " & $l.first &
      ") could not be written exactly in SEG-Y format " & $ord(fmt) & "; choose a wider " &
      "format (e.g. 6, float64, in Rev 2)", loc = loc)

proc swapField(b: var openArray[byte], pos, size: int, src, dst: ByteOrder) =
  case size
  of 2: putNum(b, pos, getNum[uint16](b, pos, src), dst)
  of 4: putNum(b, pos, getNum[uint32](b, pos, src), dst)
  of 8: putNum(b, pos, getNum[uint64](b, pos, src), dst)
  else: discard

proc reorderProprietary(lay: TraceLayout, blocks: var seq[byte], src, dst: ByteOrder): bool =
  # Converts the fields that the file's Layout stanza describes in each
  # proprietary header to `dst` order (each byte position once). True if
  # every block has a description.
  result = true
  var i = 0
  while i + TraceHeaderSize <= blocks.len:
    let name = headerBlockName(blocks.toOpenArray(i, i + TraceHeaderSize - 1))
    var done: set[0..239]
    var described = false
    for e in lay.entries:
      if e.extension.len > 0 and cmpIgnoreCase(e.extension, name) == 0:
        described = true
        let p = e.bytePos - 1
        let parts = if e.kind == ltScale6: @[(p, 4), (p + 4, 2)] else: @[(p, e.kind.size)]
        for (q, n) in parts:
          if q >= 0 and q + n <= TraceHeaderSize and q notin done:
            swapField(blocks.toOpenArray(i, i + TraceHeaderSize - 1), q, n, src, dst)
            done.incl q
    if not described: result = false
    i += TraceHeaderSize

# ------------------------------------------------------------- SEG-Y → SEG-Y --

func inputSize(src: RecordSource): int64 =
  # The size `Progress` reports for `src`: -1 unless it is a file.
  if src of MemFileSource: MemFileSource(src).size
  elif src of DiskSource: DiskSource(src).size
  else: -1

func dropUnassigned(b: var SegyBinaryHeader, fromRev: SegyRevision): bool =
  # Zeroes the binary header fields that revision `fromRev` (0 or 1) leaves
  # unassigned and a later revision defines, so that vendor data there is
  # not read as a count or a flag: Rev 0 bytes 3261-3600, Rev 1 bytes
  # 3261-3300 and 3507-3532. True if any of them was set.
  let was = b
  b.extDataTracesPerEnsemble = 0
  b.extAuxTracesPerEnsemble = 0
  b.extSamplesPerTrace = 0
  b.extSampleInterval = 0
  b.extSampleIntervalOrig = 0
  b.extSamplesPerTraceOrig = 0
  b.extEnsembleFold = 0
  b.byteOrderMarker = 0
  b.maxAddlTraceHeaders = 0
  b.surveyType = 0
  b.timeBasisCode = 0
  b.numTraces = 0
  b.firstTraceOffset = 0
  b.numTrailerRecords = 0
  if fromRev.major == 0:
    b.unassigned1 = default(typeof(b.unassigned1))
    b.fixedLengthTraces = 0
    b.numExtTextHeaders = 0
    b.unassigned2 = default(typeof(b.unassigned2))
  was != b

func dropRev1Fields(h: var SegyTraceHeader): bool =
  # Zeroes trace bytes 181-240, which Rev 0 leaves unassigned and Rev 1
  # fills (CDP position, inline and crossline, shotpoint, transduction,
  # time scalar, source fields). True if any of them was set.
  let was = h
  h.cdpX = 0
  h.cdpY = 0
  h.inlineNumber = 0
  h.crosslineNumber = 0
  h.shotpointNumber = 0
  h.shotpointScalar = 0
  h.traceValueUnit = 0
  h.transductionMantissa = 0
  h.transductionExponent = 0
  h.transductionUnits = 0
  h.deviceTraceId = 0
  h.timeScalar = 0
  h.sourceTypeOrientation = 0
  h.sourceEnergyDirVert = 0
  h.sourceEnergyDirXline = 0
  h.sourceEnergyDirInline = 0
  h.sourceMeasurementMantissa = 0
  h.sourceMeasurementExponent = 0
  h.sourceMeasurementUnit = 0
  h.headerName = default(typeof(h.headerName))
  was != h

func unscaleTimes(h: var SegyTraceHeader): tuple[rounded, clamped: bool] =
  # Rev 0 has no time scalar: the times of bytes 95-114 become whole ms,
  # with the scalar (bytes 215-216) applied. `rounded`: a value lost its
  # fraction; `clamped`: one is beyond the int16 a Rev 0 field holds.
  let scalar = h.timeScalar
  if scalar != 0 and scalar != 1:
    template whole(field: untyped) =
      let ms = applyScalar(h.field, scalar)
      if abs(ms) > 32767.5: result.clamped = true
      elif ms != round(ms): result.rounded = true
      h.field = clampI16(ms)
    whole(upholeTimeSource)
    whole(upholeTimeGroup)
    whole(sourceStatic)
    whole(groupStatic)
    whole(totalStatic)
    whole(lagTimeA)
    whole(lagTimeB)
    whole(delayRecordingTime)
    whole(muteStart)
    whole(muteEnd)

proc convertSegy*(src: RecordSource, sink: RecordSink, opts = ConvertOptions(),
    progress: Progress = nil): DiagLog =
  ## Rewrites the SEG-Y file at `src` with the target revision, byte order and
  ## format of `opts` (`stKeep` keeps the input format). The reader's,
  ## the writer's and the conversion's diagnostics are all in the result; a
  ## fatal one means the output is incomplete. `progress` is called about
  ## every MiB of input (see `Progress`); when it returns false the
  ## conversion stops with a fatal `dcCancelled` diagnostic.
  ##
  ## A new revision changes what some header bytes mean, so those are
  ## rewritten (see the module doc); what the target cannot hold is
  ## reported, never dropped silently.
  var err: string
  if not checkTarget(opts, err):
    result.report(sevFatal, dcValidation, err, loc = Location(file: sink.name))
    return
  var r = openSegy(src)
  if r.log.isFatal:
    result.add r.log
    return
  var f = r.file
  let loc = Location(file: sink.name)
  var seen: set[LossNote]
  let fromRev = f.revision
  let rev = opts.revision
  let inFmt = f.format.get # known: else the read is fatal
  let outFmt = if opts.format != stKeep: opts.format.sampleFormat else: inFmt
  if outFmt.isRev2Format and rev.major < 2:
    result.add r.log
    result.report(sevFatal, dcUnsupportedFormat, "the input format " & $ord(outFmt) &
      " needs Rev 2; choose a Rev 1 format (e.g. 5)", loc = loc)
    return
  if sampleSize(outFmt) == 3 and opts.byteOrder == boPairSwapped:
    result.add r.log
    result.report(sevFatal, dcUnsupportedFormat, "the 3-byte format " & $ord(outFmt) &
      " cannot be pair-swapped; choose another target format", loc = loc)
    return
  # By the input's rules, before the revision bytes change.
  let fileNs = f.binary.effectiveSamplesPerTrace
  let fileDt = f.binary.effectiveSampleInterval
  let fixedIn = fromRev.major >= 1 and f.binary.fixedLengthTraces == 1
  if fromRev.major < 2 and fromRev.major < rev.major and f.binary.dropUnassigned(fromRev):
    result.note(seen, lnUnassignedBinary, "the Rev " & $fromRev & " input holds values in " &
      "binary header bytes its revision leaves unassigned (" &
      (if fromRev.major == 0: "3261-3600" else: "3261-3300, 3507-3532") & ") and Rev " & $rev &
      " defines: cleared", loc)
  if rev.major < 2 and fixedIn and not (fileDt >= 0 and fileDt <= 65535):
    result.add r.log
    result.report(sevFatal, dcUnsupportedFormat, "the sample interval of " & $fileDt &
      " needs Rev 2 (Rev " & $rev & " holds whole intervals up to 65535)", loc = loc)
    return
  if rev.major < 2 and fixedIn and fileNs > high(uint16):
    result.add r.log
    result.report(sevFatal, dcUnsupportedFormat, $fileNs & " samples per trace need Rev 2 " &
      "(Rev " & $rev & " holds up to 65535)", loc = loc)
    return
  f.binary.revision = rev
  f.revision = rev
  f.binary.formatCode = int16(ord(outFmt))
  if rev == SegyRevision(major: 2, minor: 0):
    if f.binary.surveyType != 0:
      result.note(seen, lnSurveyType, "Rev 2.0 has no survey type (bytes 3509-3510 belong " &
        "to the additional trace header count): survey type " & $f.binary.surveyType &
        " dropped", loc)
      f.binary.surveyType = 0
    for s in f.extended.stanzas:
      if s.company.toUpperAscii == "SEG" and s.name.toLowerAscii.startsWith("layout"):
        result.note(seen, lnLayoutStanza, "the ((SEG:Layout)) stanza is defined from Rev 2.1; " &
          "a Rev 2.0 reader ignores it (it is kept as text)", loc)
  if rev.major == 0 and f.extended.recordCount > 0:
    result.note(seen, lnExtendedText, "Rev 0 has no extended textual headers: " &
      $f.extended.recordCount & " records dropped", loc)
    if f.extended.find("SEG:Layout") >= 0:
      # Not a note: every field the stanza places is now read elsewhere.
      result.report(sevWarning, dcValidation, "the input's ((SEG:Layout)) stanza is dropped " &
        "with the extended textual headers, but the trace headers keep its layout: readers " &
        "of the output take the fields it moved from their standard bytes", loc = loc)
  if rev.major == 0 or (rev.major < 2 and f.extended.recordCount > 0 and fromRev.major >= 2):
    if rev.major == 0:
      f.extended = initExtendedTextHeader()
      f.binary.numExtTextHeaders = 0
    else:
      result.note(seen, lnStanzasAsText, "Rev 2 stanzas (Layout, User Data) are kept as " &
        "plain Rev 1 extended text", loc)
  if rev.major < 2:
    if f.trailer.recordCount > 0:
      result.note(seen, lnTrailers, "Rev 1 has no data trailers: " & $f.trailer.recordCount &
        " records dropped", loc)
    f.trailer = initExtendedTextHeader()
    f.binary.byteOrderMarker = 0
    f.binary.maxAddlTraceHeaders = 0
    f.binary.numTraces = 0
    f.binary.firstTraceOffset = 0
    f.binary.numTrailerRecords = 0
    # The count may be held in bytes 3269-3272 alone (Rev 2); over 65535 its
    # traces are skipped below.
    f.binary.samplesPerTrace = uint16(min(fileNs, uint32(high(uint16))))
    f.binary.extSamplesPerTrace = 0
    if fileDt != float64(f.binary.sampleInterval):
      # Held in bytes 3273-3280 (Rev 2), which override 3217-3218.
      if fileDt != round(fileDt):
        result.note(seen, lnIntervalRounding, "Rev 1 holds sample intervals as whole units; " &
          "extended intervals were rounded", loc)
      f.binary.sampleInterval = if fileDt >= 0 and fileDt <= 65535: uint16(round(fileDt))
                                elif fileDt > 65535: high(uint16) # its traces are skipped
                                else: 0
    f.binary.extSampleInterval = 0
  else:
    f.binary.byteOrderMarker = ByteOrderMarker
    if fromRev.major < 2:
      f.binary.firstTraceOffset = 0
      f.binary.numTrailerRecords = 0
      if f.extended.recordCount > 0 and not f.extended.hasEndText:
        f.extended.addEndText()
        f.binary.numExtTextHeaders = int16(f.extended.recordCount)
  f.format = some(outFmt)
  var w: SegyWriter
  try:
    w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: opts.byteOrder, lenient: true))
  except CatchableError as e:
    result.add r.log
    result.report(sevFatal, dcIo, "cannot write the file headers: " & e.msg, loc = loc)
    return
  var t: SegyTrace
  var buf: seq[byte]
  var vals, scratch: seq[float64]
  var losses: Losses
  var layoutReordered: seq[int] # traces whose proprietary headers the Layout fully described
  var clampedTimes: Losses
  var tk = initProgressTicker(progress, inputSize(src))
  while r.readTrace(t):
    if not tk.tick(t.offset):
      result.add r.log
      result.reportCancelled(sink.name)
      return
    let tl = Location(file: sink.name, trace: t.index)
    var ok = true
    if fromRev.major == 0 and rev.major >= 1 and t.header.dropRev1Fields():
      result.note(seen, lnUnassignedTrace, "the Rev 0 input holds values in trace header " &
        "bytes 181-240, which Rev 0 leaves unassigned and Rev " & $rev & " defines (CDP " &
        "position, inline and crossline, shotpoint, time scalar, ...): cleared", loc)
    if fromRev.major >= 1 and rev.major == 0:
      let times = t.header.unscaleTimes()
      if times.rounded:
        result.note(seen, lnTimeRounding, "Rev 0 holds the trace times (bytes 95-114) as " &
          "whole ms, without a time scalar: scaled times were rounded", loc)
      if times.clamped: clampedTimes.add(t.index)
      if t.header.dropRev1Fields():
        result.note(seen, lnRev1TraceFields, "Rev 0 leaves trace header bytes 181-240 " &
          "unassigned: the CDP position, inline and crossline numbers, shotpoint and the " &
          "other Rev 1 fields there are dropped", loc)
    if rev.major < 2:
      if t.numSamples > int(high(uint16)):
        result.report(sevError, dcValidation, "the trace has " & $t.numSamples &
          " samples, which Rev 1 cannot hold; skipped", t.offset, tl)
        ok = false
      if t.hasExt1:
        result.note(seen, lnTraceExtensions, "Rev 1 has no Trace Header Extension 1 or " &
          "proprietary trace headers: dropped", loc)
      t.hasExt1 = false
      t.proprietary.setLen 0
      t.header.numSamples = uint16(min(t.numSamples, int(high(uint16))))
      let dt = t.sampleInterval
      if not (dt >= 0 and dt <= 65535):
        if ok:
          result.report(sevError, dcValidation, "the trace has a sample interval of " & $dt &
            ", which Rev " & $rev & " cannot hold (whole, up to 65535); skipped", t.offset, tl)
        ok = false
      elif dt != float64(t.header.sampleInterval):
        if dt != round(dt):
          result.note(seen, lnIntervalRounding, "Rev 1 holds sample intervals as whole units; " &
            "extended intervals were rounded", loc)
        t.header.sampleInterval = uint16(round(dt))
    if ok and t.proprietary.len > 0 and opts.byteOrder != f.byteOrder:
      if reorderProprietary(f.layoutOf, t.proprietary, f.byteOrder, opts.byteOrder):
        layoutReordered.add t.index
    if ok and outFmt != inFmt:
      try:
        vals.setLen t.numSamples
        decodeSamples(inFmt, t.samples, vals, f.byteOrder)
        if not encodeChecked(outFmt, vals, buf, f.byteOrder, scratch): losses.add(t.index)
        swap(t.samples, buf)
      except SegFormatError as e:
        result.report(sevError, dcValidation, "samples do not fit format " & $ord(outFmt) &
          " (" & e.msg & "); the trace is written as zeros", t.offset, tl)
        t.samples = newSeq[byte](t.numSamples * sampleSize(outFmt))
    if ok:
      try:
        w.writeTrace(t)
      except CatchableError as e:
        result.report(sevFatal, dcIo, "writing trace " & $t.index & ": " & e.msg, loc = tl)
        return
  result.add r.log
  result.report(losses, outFmt, loc)
  if clampedTimes.traces > 0:
    result.report(sevWarning, dcValidation, $clampedTimes.traces & " traces (the first is " &
      "trace " & $clampedTimes.first & ") have times beyond ±32767 ms in bytes 95-114, " &
      "which Rev 0 cannot hold without a time scalar: clamped", loc = loc)
  if not tk.finish():
    result.reportCancelled(sink.name)
    return
  try:
    w.close()
  except CatchableError as e:
    result.report(sevFatal, dcIo, "closing: " & e.msg, loc = loc)
  # The writer cannot know a Layout stanza describes proprietary headers; the
  # ones reordered here are not "copied unchanged".
  var ri = 0
  for d in w.log.items:
    var keep = true
    if d.loc.field == "trace.proprietary" and "no known layout" in d.msg:
      while ri < layoutReordered.len and layoutReordered[ri] < d.loc.trace: inc ri
      keep = not (ri < layoutReordered.len and layoutReordered[ri] == d.loc.trace)
    if keep: result.add d

# ------------------------------------------------------------ SEG-D → SEG-Y --

type
  SegdToSegy = object
    ## The state of one SEG-D → SEG-Y conversion.
    opts: ConvertOptions
    loc: Location ## The output file.
    log: DiagLog ## The conversion's own diagnostics.
    seen: set[LossNote]
    outFmt: SampleFormat
    losses: Losses
    nOut: int ## Traces written so far.
    join: GeometryJoin ## Survey geometry for the keys (none: `survey` is nil).
    vals, scratch: seq[float64]

func losslessFormat(f: SegdSampleFormat, rev: SegyRevision, descale: bool,
    order: ByteOrder): SampleFormat =
  if descale:
    # A descaled value (recorded × MP / DSM) needs float64 to stay exact.
    (if rev.major >= 2: sfFloat64 else: sfFloat32)
  else:
    case bigEndianOf(f)
    of sd8048: sfIbm32
    of sd8036: (if rev.major >= 2 and order != boPairSwapped: sfInt24 else: sfInt32)
    of sd8038: sfInt32
    of sd8080: (if rev.major >= 2: sfFloat64 else: sfFloat32)
    else: sfFloat32

func commonFormat(formats: set[SegdSampleFormat], rev: SegyRevision, descale: bool,
    order: ByteOrder): SampleFormat =
  # One target format for records in several SEG-D formats: their common
  # lossless format if they share one, else float64 (exact for every SEG-D
  # format) in Rev 2, else int32 for integers only, else float32.
  var first = true
  var same = true
  for f in formats:
    let g = losslessFormat(f, rev, descale, order)
    if first: (result, first) = (g, false)
    elif g != result: same = false
  if first: result = sfFloat32
  elif not same:
    result = if rev.major >= 2: sfFloat64
             elif formats <= {sd8036, sd8038} and not descale: sfInt32
             else: sfFloat32

func segyFormatFor(opts: ConvertOptions, rec: SegdRecord,
    recordFormats: set[SegdSampleFormat]): SampleFormat =
  # The SEG-Y format: the requested one, else one that holds every record
  # exactly (or at least the first one).
  let rev = opts.revision
  if opts.format != stKeep: opts.format.sampleFormat
  elif recordFormats.card > 0: commonFormat(recordFormats, rev, opts.applyDescale, opts.byteOrder)
  elif rec.format.isSome: losslessFormat(rec.format.get, rev, opts.applyDescale, opts.byteOrder)
  else: sfFloat32

func traceIdOf(rec: SegdRecord, t: SegdTrace, sensor: uint8): int16 =
  # SEG-D channel type → SEG-Y trace identification code (Table 4.5).
  if t.channelSet < 0: return 0
  let ct = rec.channelType(t)
  let seismic = if rec.isRev3: ct in {0x10, 0x11} else: ct == 1
  if seismic:
    case sensor
    of 1: 11    # hydrophone: pressure sensor
    of 2, 6: 12 # geophone / accelerometer vertical
    of 3, 7: 14 # inline
    of 4, 8: 13 # crossline
    else: 1
  elif rec.isRev3:
    case ct
    of 0x20..0x22: 4 # time break
    of 0x30: 5       # uphole
    of 0x40: 8       # water break
    of 0x50: 7       # time counter: timing
    of 0x96, 0xB0..0xB3: 6 # reference sweeps
    of 0x80, 0x90..0x95, 0x97..0x9C: 9 # signatures and other source channels
    else: -1
  else:
    case ct
    of 2: 4
    of 3: 5
    of 4: 8
    of 5: 7 # time counter
    of 8, 9: 9
    else: -1

proc fillTime(h: var SegyTraceHeader, rec: SegdRecord): bool =
  # False (fields left 0) when the record's time is outside years 1-9999.
  result = true
  if rec.isRev3 and rec.gh3.timeZero != 0:
    let unix = timestampToUnix(rec.gh3.timeZero)
    if not (unix > -62135596800.0 and unix < 253402300800.0): return false
    let dt = fromUnix(int64(floor(unix))).utc
    h.year = int16(dt.year)
    h.dayOfYear = int16(dt.yearday + 1)
    h.hour = int16(dt.hour)
    h.minute = int16(dt.minute)
    h.second = int16(dt.second)
    h.timeBasisCode = 4 # UTC
  elif rec.gh1.year >= 0 and rec.gh1.julianDay in 0..366 and rec.gh1.hour in 0..24 and
      rec.gh1.minute in 0..60 and rec.gh1.second in 0..60:
    h.year = int16(fullYear(rec.gh1.year))
    h.dayOfYear = int16(max(rec.gh1.julianDay, 0))
    h.hour = int16(max(rec.gh1.hour, 0))
    h.minute = int16(max(rec.gh1.minute, 0))
    h.second = int16(max(rec.gh1.second, 0))
    h.timeBasisCode = 4 # SEG-D general header times are UTC

proc stationHeader(k: TraceKeys, record, channelSet, channelType: int,
    order: ByteOrder): seq[byte] =
  result = newSeq[byte](TraceHeaderSize)
  putNum(result, 0, k.srcLine, order)
  putNum(result, 8, k.srcPoint, order)
  putNum(result, 16, k.rcvLine, order)
  putNum(result, 24, k.rcvPoint, order)
  putNum(result, 32, k.srcIndex, order)
  putNum(result, 34, k.rcvIndex, order)
  putNum(result, 36, int16(k.sensorType), order)
  putNum(result, 38, int16(k.component), order)
  putNum(result, 40, int32(record), order)
  putNum(result, 44, int32(channelSet), order)
  putNum(result, 48, int16(channelType), order)
  for i, c in StationHeaderName: result[232 + i] = byte(c)

proc noteRecord(c: var SegdToSegy, rec: SegdRecord) =
  # What a record carries that SEG-Y has no place for.
  if rec.format.isNone:
    c.log.report(sevError, dcUnsupportedFormat, "record " & $rec.index & ": SEG-D format " &
      $rec.gh1.formatCode & " cannot be decoded; its traces are skipped", rec.offset, c.loc)
  if rec.extended.len > 0 or rec.external.len > 0:
    c.log.note(c.seen, lnSegdHeaders, "SEG-D extended/external headers are not carried into " &
      "SEG-Y", c.loc)
  let moreGeneral = case rec.layout
    of slRev2: rec.sourceHeaders.len > 1
    of slRev3: rec.generalBlocks.len > 0
  if moreGeneral:
    c.log.note(c.seen, lnSegdGeneral, "SEG-D general header blocks beyond the first source " &
      "are not carried into SEG-Y", c.loc)
  let hasTrailer = case rec.layout
    of slRev2: rec.trailer.len > 0
    of slRev3: rec.trailerRev3.len > 0
  if hasTrailer:
    c.log.note(c.seen, lnSegdTrailers, "SEG-D general trailers are not carried into SEG-Y",
      c.loc)

proc initSegyFileFor(c: SegdToSegy, rec: SegdRecord, t: SegdTrace, srcName: string): SegyFile =
  # The SEG-Y file headers, from the first record and trace.
  let opts = c.opts
  let rev = opts.revision
  result = SegyFile(byteOrder: opts.byteOrder, format: some(c.outFmt), revision: rev,
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(opts.textEncoding))
  let cards = [
    "CONVERTED FROM SEG-D REV " & $rec.revision & " BY " & ConverterName,
    "SOURCE " & srcName.extractFilename,
    "MANUFACTURER CODE " & $rec.gh1.manufacturerCode & " SERIAL " &
      $rec.gh1.manufacturerSerial,
    "SEG-D FORMAT " & $rec.gh1.formatCode & " WRITTEN AS SEG-Y FORMAT " & $ord(c.outFmt),
    (if opts.applyDescale: "SAMPLES DESCALED TO MILLIVOLTS (MP FACTOR / DSM)"
     else: "SAMPLES ARE RECORDED VALUES (NOT DESCALED)"),
    "ONE SEG-Y TRACE PER SEG-D TRACE, FIELD RECORD = SEG-D FILE NUMBER",
    (if rev.major >= 2 and opts.stationHeader:
       "LINE/POINT IN PROPRIETARY HEADER " & StationHeaderName & " (LAYOUT STANZA)"
     else: "SEG-D RECEIVER/SOURCE LINE AND POINT NOT CARRIED (REV 1)")]
  for i, card in cards: result.text.setCard(i + 1, cardPrefix(i + 1) & card)
  result.text.setCard(39, cardPrefix(39) & (if rev.major >= 2: "SEG-Y_REV" & $rev
    elif rev.major == 1: "SEG Y REV1" else: ""))
  result.text.setCard(40, cardPrefix(40) & "END TEXTUAL HEADER")
  let ns = t.numSamples
  let dt = rec.sampleIntervalUs(t)
  let dtWhole = dt == round(dt) and dt <= 65535 and dt >= 0
  result.binary = SegyBinaryHeader(formatCode: int16(ord(c.outFmt)), segyMajor: rev.major,
    segyMinor: rev.minor, fixedLengthTraces: 0, traceSorting: 1, measurementSystem: 1,
    samplesPerTrace: uint16(min(ns, 65535)),
    sampleInterval: uint16(if dtWhole or rev.major < 2: clamp(round(dt), 0, 65535) else: 0),
    dataTracesPerEnsemble: int16(min(rec.traceCount, 32767)))
  if rev.major >= 2:
    result.binary.byteOrderMarker = ByteOrderMarker
    if ns > 65535: result.binary.extSamplesPerTrace = uint32(ns)
    if result.binary.sampleInterval == 0: result.binary.extSampleInterval = dt
    result.binary.maxAddlTraceHeaders = if opts.stationHeader: 2 else: 1
    if opts.stationHeader:
      result.extended.addText("SEG", "Layout", stationLayout, "text/xml")
    result.extended.addEndText()
    result.binary.numExtTextHeaders = int16(result.extended.recordCount)

proc toSegyHeader(c: var SegdToSegy, rec: SegdRecord, t: SegdTrace, k: TraceKeys,
    inRecord: int): SegyTraceHeader =
  # The standard trace header of SEG-Y trace `c.nOut` (see the module doc).
  let rev = c.opts.revision
  result = SegyTraceHeader(traceSeqLine: int32(c.nOut + 1), traceSeqFile: int32(c.nOut + 1),
    fieldRecord: int32(clamp(k.record, -2147483648.0, 2147483647.0)),
    traceInEnsemble: int32(inRecord), traceIdCode: traceIdOf(rec, t, k.sensorType))
  result.traceNumberInField = int32(if t.layout == slRev3 and t.ext1Rev3.isSome:
                                      traceNumber(t.header, t.ext1Rev3.get)
                                    elif t.header.traceNumber >= 0: t.header.traceNumber
                                    else: inRecord)
  if not k.srcPoint.isNaN:
    result.energySourcePoint = clampI32(k.srcPoint)
    result.shotpointScalar = if k.srcPoint == round(k.srcPoint): 1 else: -100
    result.shotpointNumber = scaled(k.srcPoint, result.shotpointScalar)
  let dt = rec.sampleIntervalUs(t)
  result.numSamples = uint16(min(t.numSamples, 65535))
  result.sampleInterval = uint16(if dt == round(dt) and dt <= 65535: dt else: 0)
  if result.sampleInterval == 0 and rev.major < 2:
    c.log.note(c.seen, lnSegdIntervalRounding, "Rev 1 holds sample intervals as whole " &
      "microseconds; intervals were rounded", c.loc)
    result.sampleInterval = uint16(clamp(round(dt), 0, 65535))
  result.delayRecordingTime = clampI16(rec.startTimeMs(t))
  result.setGeometry(k)
  if not result.fillTime(rec):
    c.log.note(c.seen, lnSegdTimeRange, "a record's time is outside years 1-9999; the trace " &
      "time fields are left 0", c.loc)

func toSegyExt1(c: SegdToSegy, h: SegyTraceHeader, k: TraceKeys, numSamples: int,
    dt: float64): SegyTraceHeaderExt1 =
  # Trace Header Extension 1 (Rev 2 targets): the 64-bit counts and the
  # unscaled coordinates.
  result = initTraceHeaderExt1()
  result.numAddlTraceHeaders = if c.opts.stationHeader: 2 else: 1
  result.extFieldRecord = int64(h.fieldRecord)
  result.extTraceSeqLine = uint64(c.nOut + 1)
  result.extTraceSeqFile = uint64(c.nOut + 1)
  if numSamples > 65535: result.extNumSamples = uint32(numSamples)
  if h.sampleInterval == 0: result.extSampleInterval = dt
  template f64(dst: untyped, v: float64) =
    if not v.isNaN: dst = v
  f64(result.extSourceX, k.srcX)
  f64(result.extSourceY, k.srcY)
  f64(result.extGroupX, k.rcvX)
  f64(result.extGroupY, k.rcvY)
  f64(result.extCdpX, k.cmpX)
  f64(result.extCdpY, k.cmpY)
  f64(result.extOffset, k.offset)
  f64(result.extReceiverElevation, k.rcvZ)
  f64(result.extSourceSurfaceElevation, k.srcZ)

proc toSegySamples(c: var SegdToSegy, rec: SegdRecord, t: SegdTrace, twosComplement8015: bool,
    dst: var seq[byte]) =
  # The trace's samples in the target format: decoded exactly, optionally
  # descaled, re-encoded. Values the format cannot hold zero the trace.
  try:
    let f = rec.format.get
    if f == sd8048 and c.outFmt == sfIbm32 and not c.opts.applyDescale:
      # IBM words are copied: going through float64/float32 would lose
      # values outside float32's range.
      dst.setLenUninit 4 * t.numSamples # every word is written below
      for i in 0..<t.numSamples:
        putNum(dst, 4 * i, getNum[uint32](t.samples, 4 * i, boBig), c.opts.byteOrder)
    elif not c.opts.applyDescale and t.samples.len >= dataBytes(f, t.numSamples) and
        (bigEndianOf(f) == sd8058 and c.outFmt == sfFloat32 or
         bigEndianOf(f) == sd8080 and c.outFmt == sfFloat64):
      # IEEE floats into the same IEEE format: the bytes, reordered (exact).
      let order = if f.isLittleEndian: boLittle else: boBig
      if c.outFmt == sfFloat32:
        copyFloatWords(float32, t.samples, order, t.numSamples, dst, c.opts.byteOrder)
      else:
        copyFloatWords(float64, t.samples, order, t.numSamples, dst, c.opts.byteOrder)
    else:
      c.vals.setLen t.numSamples
      decodeSamples(f, t.samples, c.vals, twosComplement8015)
      if c.opts.applyDescale:
        let m = rec.descaleFactor(t)
        for v in c.vals.mitems: v *= m
      if not encodeChecked(c.outFmt, c.vals, dst, c.opts.byteOrder, c.scratch):
        c.losses.add(c.nOut)
  except SegFormatError as e:
    c.log.report(sevError, dcValidation, "samples do not fit SEG-Y format " & $ord(c.outFmt) &
      " (" & e.msg & "); the trace is written as zeros", t.offset,
      Location(file: c.loc.file, trace: c.nOut))
    dst = newSeq[byte](t.numSamples * sampleSize(c.outFmt))

proc toSegyTrace(c: var SegdToSegy, rec: SegdRecord, t: SegdTrace, inRecord: int,
    twosComplement8015: bool): SegyTrace =
  # SEG-Y trace `c.nOut` for SEG-D trace `t`, the `inRecord`-th of `rec`.
  var k = traceKeys(rec, t)
  if c.join.survey != nil:
    discard k.applySurvey(c.join.survey[], c.join.fields, c.join.overwrite)
  let dt = rec.sampleIntervalUs(t)
  result = SegyTrace(index: c.nOut, numSamples: t.numSamples, sampleInterval: dt,
    header: c.toSegyHeader(rec, t, k, inRecord))
  if c.opts.revision.major >= 2:
    result.hasExt1 = true
    result.ext1 = c.toSegyExt1(result.header, k, t.numSamples, dt)
    if c.opts.stationHeader:
      result.proprietary = stationHeader(k, rec.index, t.channelSet, rec.channelType(t),
        c.opts.byteOrder)
  elif not (k.rcvLine.isNaN and k.srcLine.isNaN):
    c.log.note(c.seen, lnSegdLinePoint, "Rev 1 has no field for SEG-D receiver/source line " &
      "and point; they are not carried", c.loc)
  c.toSegySamples(rec, t, twosComplement8015, result.samples)

proc convertSegdToSegyJoined*(src: RecordSource, sink: RecordSink, opts: ConvertOptions,
    recordFormats: set[SegdSampleFormat], join: GeometryJoin, progress: Progress = nil): DiagLog =
  ## **Internal** (`convertWithGeometry`; not exported by `parseSEG`).
  ## `convertSegdToSegy` with survey geometry joined to the keys first.
  var c = SegdToSegy(opts: opts, loc: Location(file: sink.name), join: join)
  var err: string
  if not checkTarget(opts, err):
    result.report(sevFatal, dcValidation, err, loc = c.loc)
    return
  var r = openSegd(src, headersOnly = false)
  var w: SegyWriter
  var opened = false
  template stop() =
    result = ensureMove c.log
    result.add r.log
    return
  var tk = initProgressTicker(progress, inputSize(src))
  while r.nextRecord():
    c.noteRecord(r.record)
    var t: SegdTrace
    var inRecord = 0
    while r.readTrace(t):
      if not tk.tick(t.offset):
        c.log.reportCancelled(sink.name)
        stop()
      inc inRecord
      if not opened:
        # The file headers come from the first trace.
        c.outFmt = segyFormatFor(opts, r.record, recordFormats)
        try:
          w = openSegyWriter(sink, c.initSegyFileFor(r.record, t, src.name),
            SegyWriteOptions(byteOrder: opts.byteOrder, lenient: true))
        except CatchableError as e:
          c.log.report(sevFatal, dcIo, "cannot write the file headers: " & e.msg, loc = c.loc)
          stop()
        opened = true
      if r.record.format.isNone:
        discard # reported by `noteRecord`
      elif t.numSamples > 65535 and opts.revision.major < 2:
        c.log.report(sevError, dcValidation, "the trace has " & $t.numSamples &
          " samples, which Rev 1 cannot hold; skipped", t.offset,
          Location(file: sink.name, trace: c.nOut))
      else:
        let ot = c.toSegyTrace(r.record, t, inRecord, r.twosComplement8015)
        try:
          w.writeTrace(ot)
        except CatchableError as e:
          c.log.report(sevFatal, dcIo, "writing trace " & $c.nOut & ": " & e.msg,
            loc = Location(file: sink.name, trace: c.nOut))
          stop()
        inc c.nOut
  result = ensureMove c.log
  result.add r.log
  result.report(c.losses, c.outFmt, c.loc)
  if not opened:
    result.report(sevFatal, dcValidation, "the SEG-D stream has no traces; nothing written",
      loc = c.loc)
    return
  if not tk.finish():
    result.reportCancelled(sink.name)
    return
  try:
    w.close()
  except CatchableError as e:
    result.report(sevFatal, dcIo, "closing: " & e.msg, loc = c.loc)
  result.add w.log

# ------------------------------------------------------------ SEG-2 → SEG-Y --

const MappedSeg2Keys = ["SHOT_SEQUENCE_NUMBER", "CHANNEL_NUMBER", "CDP_NUMBER", "CDP_TRACE",
  "SOURCE_STATION_NUMBER", "RECEIVER_STATION_NUMBER", "LINE_ID", "TRACE_TYPE", "RECEIVER",
  "STACK", "FIXED_GAIN", "DELAY", "STATIC_CORRECTIONS", "ALIAS_FILTER", "LOW_CUT_FILTER",
  "HIGH_CUT_FILTER", "NOTCH_FREQUENCY", "SOURCE_LOCATION", "RECEIVER_LOCATION", "DATUM",
  "DESCALING_FACTOR", "SAMPLE_INTERVAL", "POLARITY"]
  ## Trace keywords the SEG-Y headers hold (LINE_ID, station numbers: in
  ## `PSEGD001`, Rev 2 only).

func segyFormatOf(f: Seg2SampleFormat, rev: SegyRevision): SampleFormat =
  case f
  of s2Int16: sfInt16
  of s2Int32: sfInt32
  of s2Float20, s2Float32: sfFloat32
  of s2Float64: (if rev.major >= 2: sfFloat64 else: sfFloat32)

func seg2SegyFormat(ix: TraceIndex, opts: ConvertOptions): SampleFormat =
  # One format for every trace (see the module doc).
  let rev = opts.revision
  if opts.format != stKeep: return opts.format.sampleFormat
  var fs: set[Seg2SampleFormat]
  for c in ix.codecs:
    if c.seg2Format.isSome: fs.incl c.seg2Format.get
  if fs.card == 1:
    for x in fs: return segyFormatOf(x, rev)
  if fs.card == 0: sfFloat32
  elif fs <= {s2Int16, s2Int32}: sfInt32
  elif s2Float64 in fs or s2Int32 in fs: (if rev.major >= 2: sfFloat64 else: sfFloat32)
  else: sfFloat32

func seg2TraceId(t: Seg2Trace, k: TraceKeys): int16 =
  let tt = t.traceType
  if tt == some(ttDead): 2
  elif tt == some(ttUphole): 5
  elif tt == some(ttTestData): -1
  elif k.component in 12'u8..14'u8: int16(k.component)
  else: 1


proc convertSegdToSegy*(src: RecordSource, sink: RecordSink, opts = ConvertOptions(),
    recordFormats: set[SegdSampleFormat] = {}, progress: Progress = nil): DiagLog =
  ## Converts the SEG-D stream at `src` to one SEG-Y file (see the module
  ## doc for the mapping). `recordFormats`, the formats of all records (from
  ## a header scan; `convertFile` does one), lets the default format choice
  ## hold every record exactly; without it the first record decides. Either
  ## way every trace is checked after encoding, and traces not written
  ## exactly are counted in a warning. The reader's, the writer's and the
  ## conversion's diagnostics are all in the result; a fatal one means the
  ## output is incomplete. `progress` as for `convertSegy`.
  convertSegdToSegyJoined(src, sink, opts, recordFormats, GeometryJoin(), progress)

proc msRounded(c: var SegdToSegy, seconds: float64): int16 =
  # Seconds as whole ms, noting the rounding.
  let ms = seconds * 1000
  if ms != round(ms):
    c.log.note(c.seen, lnSeg2Rounding, "SEG-Y holds delays and statics as whole ms; SEG-2 " &
      "values were rounded", c.loc)
  clampI16(ms)

proc toSegyHeader(c: var SegdToSegy, fdb: Seg2File, t: Seg2Trace, k: TraceKeys, i: int,
    dt: float64, ns: int): SegyTraceHeader =
  # The standard trace header of SEG-Y trace `c.nOut` for SEG-2 trace `i`.
  let rev = c.opts.revision
  result = SegyTraceHeader(traceSeqLine: int32(c.nOut + 1), traceSeqFile: int32(c.nOut + 1),
    traceIdCode: seg2TraceId(t, k))
  if not k.record.isNaN: result.fieldRecord = clampI32(k.record)
  result.traceNumberInField = if k.channel.isNaN: int32(i + 1) else: clampI32(k.channel)
  if not k.ensemble.isNaN: result.ensembleNumber = clampI32(k.ensemble)
  let cdpTrace = t.number("CDP_TRACE")
  result.traceInEnsemble = if cdpTrace.isSome: clampI32(cdpTrace.get) else: int32(i + 1)
  if not k.srcPoint.isNaN:
    result.energySourcePoint = clampI32(k.srcPoint)
    result.shotpointScalar = if k.srcPoint == round(k.srcPoint): 1 else: -100
    result.shotpointNumber = scaled(k.srcPoint, result.shotpointScalar)
  let stack = t.number("STACK")
  if stack.isSome: result.numVertSummed = clampI16(stack.get)
  let gain = t.number("FIXED_GAIN")
  if gain.isSome: result.instrumentGainConstant = clampI16(gain.get)
  result.numSamples = uint16(min(ns, 65535))
  let whole = dt == round(dt) and dt <= 65535 and dt >= 0
  result.sampleInterval = uint16(if whole: dt else: 0)
  if result.sampleInterval == 0 and rev.major < 2 and not dt.isNaN:
    c.log.note(c.seen, lnSegdIntervalRounding, "Rev 1 holds sample intervals as whole " &
      "microseconds; intervals were rounded", c.loc)
    result.sampleInterval = uint16(clamp(round(dt), 0, 65535))
  let delay = t.delay
  if delay.isSome: result.delayRecordingTime = c.msRounded(delay.get)
  let st = t.numbers("STATIC_CORRECTIONS")
  if st.len >= 1: result.sourceStatic = c.msRounded(st[0])
  if st.len >= 2: result.groupStatic = c.msRounded(st[1])
  if st.len >= 3: result.totalStatic = c.msRounded(st[2])
  template filter(key: string, freq, slope: untyped) =
    let n = t.numbers(key)
    if n.len >= 1: result.freq = clampI16(n[0])
    if n.len >= 2: result.slope = clampI16(n[1])
  filter("ALIAS_FILTER", aliasFilterFreq, aliasFilterSlope)
  filter("LOW_CUT_FILTER", lowCutFreq, lowCutSlope)
  filter("HIGH_CUT_FILTER", highCutFreq, highCutSlope)
  let notch = t.number("NOTCH_FREQUENCY")
  if notch.isSome: result.notchFilterFreq = clampI16(notch.get)
  var datum = t.number("DATUM")
  if datum.isNone: datum = fdb.number("DATUM")
  result.setGeometry(k, datum.get(NaN))
  let df = t.number("DESCALING_FACTOR")
  if df.isSome and df.get != 0 and not df.get.isNaN:
    # mV per count for one shot: DESCALING_FACTOR / STACK, as mantissa × 10^exponent.
    let v = df.get / max(stack.get(1.0), 1.0)
    var e = int16(floor(log10(abs(v)))) - 8
    var m = round(v / pow(10.0, float64(e)))
    while abs(m) > 2147483647.0:
      inc e
      m = round(v / pow(10.0, float64(e)))
    result.transductionMantissa = int32(m)
    result.transductionExponent = e
    result.transductionUnits = 3 # millivolts
  let acq = fdb.acquisitionTime
  if acq.isSome and acq.get > -62135596800.0 and acq.get < 253402300800.0:
    let d = fromUnix(int64(floor(acq.get))).utc
    result.year = int16(d.year)
    result.dayOfYear = int16(d.yearday + 1)
    result.hour = int16(d.hour)
    result.minute = int16(d.minute)
    result.second = int16(d.second)

func textCard(s: string): string =
  result = s
  for ch in result.mitems:
    if ch notin {' '..'~'}: ch = ' '

proc initSegyFileForSeg2(c: var SegdToSegy, f: SeismicFile, t0: Seg2Trace, dt: float64,
    ns: int): SegyFile =
  # The SEG-Y file headers: binary from the file strings and trace 0, the
  # file strings as text cards.
  let opts = c.opts
  let rev = opts.revision
  let fdb = f.index.seg2
  result = SegyFile(byteOrder: opts.byteOrder, format: some(c.outFmt), revision: rev,
    extended: initExtendedTextHeader(), trailer: initExtendedTextHeader(),
    text: initTextHeader(opts.textEncoding))
  var cards = @["CONVERTED FROM SEG-2 REV " & $fdb.revision & " BY " & ConverterName,
    "SOURCE " & f.path.extractFilename,
    "SEG-2 FORMATS WRITTEN AS SEG-Y FORMAT " & $ord(c.outFmt) & "; SEG-2 FILE STRINGS:"]
  var dropped = 0
  for s in fdb.strings:
    if cmpIgnoreCase(s.key, "NOTE") == 0:
      for line in s.value.split(fdb.lineTerm): cards.add "NOTE " & line
    else:
      cards.add s.key & " " & s.value
  for i, card in cards:
    let n = i + 1
    if n > 38 or card.len > CardWidth - 4: inc dropped
    if n <= 38: result.text.setCard(n, cardPrefix(n) & card.textCard)
  if dropped > 0:
    c.log.note(c.seen, lnSeg2Text, $dropped & " SEG-2 file strings (or NOTE lines) did not " &
      "fit the textual header's cards and were cut or dropped", c.loc)
  result.text.setCard(39, cardPrefix(39) & (if rev.major >= 2: "SEG-Y_REV" & $rev
    elif rev.major == 1: "SEG Y REV1" else: ""))
  result.text.setCard(40, cardPrefix(40) & "END TEXTUAL HEADER")
  let dtWhole = dt == round(dt) and dt <= 65535 and dt >= 0
  let sorting = case fdb.traceSort.get(tsAsAcquired)
    of tsAsAcquired: 1'i16
    of tsCdpGather: 2
    of tsCdpStack: 4
    of tsCommonSource: 5
    of tsCommonReceiver: 6
    of tsCommonOffset: 7
  let units = fdb.units
  let system = if units == some(unMeters): 1'i16 elif units == some(unFeet): 2 else: 0
  if system == 0 and units.isSome and units.get != unNone:
    c.log.note(c.seen, lnSeg2Units, "SEG-Y has no measurement system for SEG-2 UNITS " &
      $units.get & "; the values are written unconverted", c.loc)
  let polarity = t0.integer("POLARITY")
  result.binary = SegyBinaryHeader(formatCode: int16(ord(c.outFmt)), segyMajor: rev.major,
    segyMinor: rev.minor, fixedLengthTraces: 0, traceSorting: sorting,
    measurementSystem: system,
    impulsePolarity: (if polarity == some(1'i64): 2 elif polarity == some(-1'i64): 1 else: 0),
    samplesPerTrace: uint16(min(ns, 65535)),
    sampleInterval: uint16(if dtWhole or rev.major < 2: clamp(round(dt), 0, 65535) else: 0),
    dataTracesPerEnsemble: int16(min(f.len, 32767)))
  if rev.major >= 2:
    result.binary.byteOrderMarker = ByteOrderMarker
    if ns > 65535: result.binary.extSamplesPerTrace = uint32(ns)
    if result.binary.sampleInterval == 0: result.binary.extSampleInterval = dt
    result.binary.maxAddlTraceHeaders = if opts.stationHeader: 2 else: 1
    if opts.stationHeader:
      result.extended.addText("SEG", "Layout", stationLayout, "text/xml")
    result.extended.addEndText()
    result.binary.numExtTextHeaders = int16(result.extended.recordCount)

proc convertSeg2ToSegy*(f: SeismicFile, sink: RecordSink, opts = ConvertOptions(),
    progress: Progress = nil): DiagLog =
  ## Converts the SEG-2 file `f` (opened with `keys = true`) to one SEG-Y
  ## file (see the module doc for the mapping). Undecodable traces are
  ## skipped with an error. The index's, the writer's and the conversion's
  ## diagnostics are all in the result; a fatal one means the output is
  ## incomplete. Raises `ValueError` when `f` is not SEG-2 or has no keys.
  ## `progress` as for `convertSegy` (done: the share of traces written, in
  ## bytes of the file).
  f.requireKind(skSeg2)
  if not f.hasKeys: raise newException(ValueError, "open the file with keys = true")
  var c = SegdToSegy(opts: opts, loc: Location(file: sink.name))
  var err: string
  if not checkTarget(opts, err):
    result.report(sevFatal, dcValidation, err, loc = c.loc)
    return
  c.outFmt = seg2SegyFormat(f.index, opts)
  var w: SegyWriter
  var opened = false
  var unmapped: seq[string]
  var polarity = none(int64)
  template stop() =
    result = ensureMove c.log
    result.add f.index.log
    return
  let size = f.mappedSize
  var tk = initProgressTicker(progress, size)
  for i in 0..<f.len:
    if not tk.tick(int64(i) * size div f.len):
      c.log.reportCancelled(sink.name)
      stop()
    let e = f.index.entries[i]
    let codec = f.index.codecs[e.record]
    let tl = Location(file: sink.name, trace: c.nOut)
    if not codec.known or e.headerBytes == 0:
      c.log.report(sevError, dcUnsupportedFormat, "SEG-2 trace " & $i & " cannot be decoded; " &
        "it is skipped", e.offset, tl)
    elif int(e.numSamples) > 65535 and opts.revision.major < 2:
      c.log.report(sevError, dcValidation, "the trace has " & $e.numSamples &
        " samples, which Rev 1 cannot hold; skipped", e.offset, tl)
    else:
      let t = f.seg2Trace(i)
      let k = f.traceKeys(i)
      let ns = int(e.numSamples)
      let dt = f.sampleIntervalUs(i)
      for x in t.strings:
        if x.key.toUpperAscii notin MappedSeg2Keys and x.key.toUpperAscii notin unmapped:
          unmapped.add x.key.toUpperAscii
      let p = t.integer("POLARITY")
      if p.isSome:
        if polarity.isSome and polarity != p:
          c.log.note(c.seen, lnSeg2Polarity, "SEG-2 POLARITY varies between traces; SEG-Y " &
            "holds one impulse polarity (trace 0's)", c.loc)
        polarity = p
      if not opened:
        try:
          w = openSegyWriter(sink, c.initSegyFileForSeg2(f, t, dt, ns),
            SegyWriteOptions(byteOrder: opts.byteOrder, lenient: true))
        except CatchableError as x:
          c.log.report(sevFatal, dcIo, "cannot write the file headers: " & x.msg, loc = c.loc)
          stop()
        opened = true
      var ot = SegyTrace(index: c.nOut, numSamples: ns, sampleInterval: dt,
        header: c.toSegyHeader(f.index.seg2, t, k, i, dt, ns))
      if opts.revision.major >= 2:
        ot.hasExt1 = true
        ot.ext1 = c.toSegyExt1(ot.header, k, ns, dt)
        if opts.stationHeader:
          ot.proprietary = stationHeader(k, 0, -1, int(e.channelType), opts.byteOrder)
      try:
        c.vals.setLen ns
        if ns > 0:
          decodeEntry(f.unsafeMemory, f.mappedSize, e, codec,
            cast[ptr UncheckedArray[float64]](addr c.vals[0]), ns)
        if not encodeChecked(c.outFmt, c.vals, ot.samples, opts.byteOrder, c.scratch):
          c.losses.add(c.nOut)
      except SegFormatError as x:
        c.log.report(sevError, dcValidation, "samples do not fit SEG-Y format " &
          $ord(c.outFmt) & " (" & x.msg & "); the trace is written as zeros", e.offset, tl)
        ot.samples = newSeq[byte](ns * sampleSize(c.outFmt))
      try:
        w.writeTrace(ot)
      except CatchableError as x:
        c.log.report(sevFatal, dcIo, "writing trace " & $c.nOut & ": " & x.msg, loc = tl)
        stop()
      inc c.nOut
  if unmapped.len > 0:
    c.log.report(sevInfo, dcValidation, "SEG-2 trace strings with no SEG-Y slot are not " &
      "carried: " & unmapped.join(", "), loc = c.loc)
  result = ensureMove c.log
  result.add f.index.log
  result.report(c.losses, c.outFmt, c.loc)
  if not opened:
    result.report(sevFatal, dcValidation, "the SEG-2 file has no decodable traces; nothing " &
      "written", loc = c.loc)
    return
  if not tk.finish():
    result.reportCancelled(sink.name)
    return
  try:
    w.close()
  except CatchableError as x:
    result.report(sevFatal, dcIo, "closing: " & x.msg, loc = c.loc)
  result.add w.log
