## Conversion to SEG-2, and from SEG-2 to SEG-D (task 11.2). `convertFile`
## (`convert.nim`) dispatches here for `target = skSeg2`, and for SEG-2
## input with `target = skSegd`; SEG-2 to SEG-Y is in `convert.nim`.
##
## **To SEG-2** (`convertToSeg2`, from SEG-Y, SEG-D or SEG-2): one SEG-2
## trace per input trace, in file order. A SEG-2 file holds at most 16383
## traces; larger inputs are refused. SEG-2 input is rewritten with its
## strings unchanged (only the byte order and formats change). Otherwise:
##
## | SEG-2 keyword | From |
## |---|---|
## | CHANNEL_NUMBER | `TraceKeys.channel` (SEG-Y bytes 13-16, SEG-D trace number), else the trace's position |
## | SHOT_SEQUENCE_NUMBER | `TraceKeys.record` (field record / file number) |
## | CDP_NUMBER | `TraceKeys.ensemble` |
## | `SOURCE_` / RECEIVER_STATION_NUMBER, LINE_ID | `TraceKeys` source / receiver point, receiver (else source) line |
## | `SOURCE_` / RECEIVER_LOCATION | `TraceKeys` x y (z when known) |
## | RECEIVER | component 11 HYDROPHONE, 12 VERTICAL_GEOPHONE, 13 `SH_`, 14 SV_HORIZONTAL_GEOPHONE |
## | SAMPLE_INTERVAL, DELAY | `sampleIntervalUs`; SEG-Y delay recording time (time scalar applied, Rev 1 on), SEG-D channel set start time |
## | TRACE_TYPE | SEG-Y trace id 2 DEAD, 5 UPHOLE, seismic codes SEISMIC_DATA, other auxiliary codes TEST_DATA; SEG-D seismic / EM SEISMIC_DATA (trace edit 1-2: DEAD), uphole UPHOLE, other channel types TEST_DATA |
## | STACK, FIXED_GAIN, `ALIAS_` / `LOW_CUT_` / HIGH_CUT_FILTER, NOTCH_FREQUENCY, STATIC_CORRECTIONS | SEG-Y trace header (vertical sum, gain constant, filters, statics with the time scalar) |
## | STACK, DESCALING_FACTOR, `ALIAS_` / LOW_CUT_FILTER, NOTCH_FREQUENCY | SEG-D channel set (Rev 3 filters; MP factor or descale multiplier × STACK: SEG-D descales to the mV of one shot, SEG-2 gives it as sample × DESCALING_FACTOR / STACK) |
## | file: ACQUISITION_DATE / _TIME | trace 0's `TraceKeys.time`: SEG-Y date and time in its time basis; SEG-D trace timestamp, GH#3 time zero or GH#1 (two-digit years 1950-2049) |
## | file: TRACE_SORT, UNITS | SEG-Y sorting code and measurement system (SEG-D: AS_ACQUIRED, NONE) |
## | file: NOTE | where the data came from, then the SEG-Y textual header's non-blank cards |
##
## Everything else (other SEG-Y header fields, extended text, trailers,
## SEG-D general/extended/external headers and vendor blocks) is reported
## once per kind as an info diagnostic. Samples go through float64 and are
## re-encoded: the default (`format = s2tKeep`) picks per trace a format
## that holds them exactly (16-bit integers 1; 24/32-bit integers 2; IEEE
## single and SEG-D exponent formats 4; IBM, IEEE double and 64-bit
## integers 5); traces not written exactly are counted in one warning.
##
## **SEG-2 to SEG-D** (`convertSeg2ToSegd`): one Rev 3 record (Rev 3.0 or
## 3.1 written directly; Rev 2.x through a Rev 3.0 temporary file and
## `convertSegdRevision`, whose notes apply). Traces sharing a sample
## interval, sample count, delay, trace type, stack, descaling factor and
## filters form a channel set; traces are written set by set (an info note
## says when that changes their order).
##
## | SEG-D | From SEG-2 |
## |---|---|
## | GH#1 file number (GH#2 extended) | SHOT_SEQUENCE_NUMBER (file, else trace 0), else 1 |
## | GH#1 date and time, GH#3 time zero | ACQUISITION_DATE / _TIME (UTC assumed) |
## | GH#2 dominant sampling interval, record length | the first set's interval; the longest set's end time |
## | Source Description (0x15 VIBRATOR, 0x16 DYNAMITE, 0x17 GUN, else 0x1F) + Position | SOURCE, source station / line, SOURCE_LOCATION: in the general header when every trace has the same source, else in each trace's extensions |
## | CSD | channel type (0x10 seismic and DEAD, 0x11 RADAR_DATA, 0x30 UPHOLE, 0x70 TEST_DATA), DELAY, interval (whole µs), samples, DESCALING_FACTOR / STACK as the descale multiplier (else 1), STACK, ALIAS_FILTER, LOW_CUT_FILTER, NOTCH_FREQUENCY |
## | demux header | CHANNEL_NUMBER (else the position in the file), trace edit 2 for DEAD |
## | THE#1 | LINE_ID and RECEIVER_STATION_NUMBER (when numeric), RECEIVER type as sensor type (1 HYDROPHONE, 2 `VERTICAL_`, 3 `SV_` (inline), 4 SH_HORIZONTAL_GEOPHONE (crossline), 6 ACCELEROMETER) |
## | Position (trace extension) | RECEIVER_LOCATION (z plus DATUM) |
## | external header | every file string, as `KEYWORD value` lines |
##
## Coordinates are SEG-2's local ones (in its UNITS); no CRS block is
## written. Trace strings without a slot are listed in one info note.
## Format (`SegdConvertOptions.format`, "keep"): 8036 for 16-bit integers,
## 8038 for 32-bit, 8058 for formats 3 and 4 (and 16-bit integers mixed
## with them), 8080 for doubles or 32-bit integers mixed with floats (8058
## before Rev 3).

import std/[math, os, strutils, times, tables]
import ./common/[endians, errors, diagnostics, outputfile, fieldlayout, progress]
import ./io/[records, diskio]
import ./segy/[reader as segyreader, samples as segysamples]
import ./segd/[reader as segdreader, writer as segdwriter, revconvert, rev3, headers as segdheaders,
  samples as segdsamples, blocks]
import ./seg2/[reader as seg2reader, writer as seg2writer]
import ./model/[traceindex, keys, headerfields]
import ./version
import ./private/[decodeentry, progressticker]

type
  Seg2TargetFormat* = enum
    ## The SEG-2 sample format `convertToSeg2` writes: "keep" (per trace, one
    ## that holds the samples exactly), or a format code.
    s2tKeep = (0, "keep"), s2t1 = (1, "1"), s2t2 = (2, "2"), s2t3 = (3, "3"), s2t4 = (4, "4"),
    s2t5 = (5, "5")

  Seg2ConvertOptions* = object
    ## Target settings of a conversion to SEG-2.
    byteOrder*: ByteOrder = boLittle ## Little-endian (PC, the usual) or big-endian.
    format*: Seg2TargetFormat = s2tKeep ## Target sample format ("keep": exact per trace).

  Seg2Note = enum
    # Kinds of information a conversion drops; each is noted once.
    snSegyHeaders, snSegyExtended, snSegyTrailer, snSegyExtensions, snSegdHeaders,
    snSegdGeneral, snSegdTrailer, snSegdExtensions, snTraceSort, snIntervalRounded,
    snDelayRounded, snLocalCoordinates, snReordered, snNoInterval

  Conv = object
    log: DiagLog
    seen: set[Seg2Note]
    loc: Location
    inexact, firstInexact: int
    unmapped: seq[string] ## Keywords without a slot, in order of first sight.
    tk: ProgressTicker ## The writing pass's progress.

const
  ConverterName = "parseSEG " & PackageVersion

proc note(c: var Conv, kind: Seg2Note, msg: string) =
  if kind notin c.seen:
    c.seen.incl kind
    c.log.report(sevInfo, dcValidation, msg, loc = c.loc)

proc inexactTrace(c: var Conv, trace: int) =
  if c.inexact == 0: c.firstInexact = trace
  inc c.inexact

proc reportInexact(c: var Conv, what: string) =
  if c.inexact > 0:
    c.log.report(sevWarning, dcValidation, $c.inexact & " traces (the first is trace " &
      $c.firstInexact & ") could not be written exactly in " & what & "; choose a wider format",
      loc = c.loc)

proc unmappedKey(c: var Conv, key: string) =
  let k = key.toUpperAscii
  if k notin c.unmapped: c.unmapped.add k

proc reportUnmapped(c: var Conv, target: string) =
  if c.unmapped.len > 0:
    c.log.report(sevInfo, dcValidation, "SEG-2 trace strings with no " & target & " slot " &
      "are not carried: " & c.unmapped.join(", "), loc = c.loc)

func finite(x: float64): bool {.inline.} = not (x.isNaN or x == Inf or x == -Inf)

proc tickTrace(c: var Conv, f: SeismicFile, k: int) =
  # Progress after `k` of the file's traces; raises when cancelled.
  if not c.tk.tick(int64(k) * f.mappedSize div max(f.len, 1)): raiseCancelled()

proc closeQuietly(f: var SeismicFile) {.raises: [].} =
  # Unmaps a read-only input; a failure there loses nothing.
  try: f.close()
  except CatchableError: discard

proc decodeTrace(f: SeismicFile, i: int, vals: var seq[float64]) =
  # Trace `i`'s samples as float64; raises like `decodeEntry`.
  let e = f.index.entries[i]
  # Checked before the buffer: no format packs a sample in under a byte.
  if int64(e.numSamples) > f.mappedSize:
    raiseTruncated("trace samples lie past the end of the file", e.offset)
  vals.setLen int(e.numSamples)
  if vals.len > 0:
    decodeEntry(f.unsafeMemory, f.mappedSize, e, f.index.codecs[e.record],
      cast[ptr UncheckedArray[float64]](addr vals[0]), vals.len)

# ---------------------------------------------------------------- to SEG-2 --

func seg2FormatFor(c: TraceCodec): Seg2Format =
  ## The SEG-2 format that holds every sample of codec `c` exactly.
  case c.kind
  of skSegy:
    case c.segyFormat.get
    of sfInt16, sfInt8, sfUInt8: s2Int16
    of sfInt32, sfInt24, sfUInt16, sfUInt24: s2Int32
    of sfFloat32: s2Float32
    of sfIbm32, sfFixedGain, sfFloat64, sfInt64, sfUInt32, sfUInt64: s2Float64
  of skSegd:
    case bigEndianOf(c.segdFormat.get)
    of sd8036, sd8038: s2Int32
    of sd8048, sd8080: s2Float64
    else: s2Float32
  of skSeg2: c.seg2Format.get
  of skUnknown: s2Float32

proc dateText(unix: float64): (string, string) =
  # ACQUISITION_DATE (dd/mm/yyyy) and ACQUISITION_TIME (hh:mm:ss[.ffffff]).
  let whole = floor(unix)
  let dt = fromUnix(int64(whole)).utc
  var clock = intToStr(dt.hour, 2) & ":" & intToStr(dt.minute, 2) & ":" & intToStr(dt.second, 2)
  let frac = unix - whole
  if frac > 0:
    var s = formatFloat(frac, ffDecimal, 6)
    s.trimZeros()
    clock.add s[1 .. ^1]
  (intToStr(dt.monthday, 2) & "/" & intToStr(ord(dt.month), 2) & "/" & intToStr(dt.year, 4), clock)

proc segyNum(f: SeismicFile, i: int, name: string): float64 =
  # A SEG-Y trace header field as a number, NaN when missing.
  let v = f.findTraceField(i, name)
  if v.isSome: v.get.toFloat else: NaN

proc segyTimeMs(f: SeismicFile, i: int, name: string): float64 =
  # A SEG-Y time field (bytes 95-114) in ms: the time scalar (bytes 215-216)
  # applies from Rev 1 on (0 means 1); Rev 0 left those bytes unassigned.
  let v = f.segyNum(i, name)
  let scalar = if f.index.segy.revision.major >= 1: f.segyNum(i, "trace.timeScalar") else: 0
  if scalar > 0: v * scalar elif scalar < 0: v / -scalar else: v

proc firstTraceTime(f: SeismicFile): float64 =
  # UTC seconds of trace 0, as its keys give it (one century pivot, the
  # SEG-Y time basis, SEG-D timestamps); NaN when not set.
  if f.len > 0: f.traceKeys(0).time else: NaN

func printable(s: string): string =
  result = s
  for c in result.mitems:
    if c notin {' '..'~'}: c = ' '

proc fileStrings(c: var Conv, f: SeismicFile, fdb: var Seg2File) =
  # The File Descriptor Block strings of a SEG-Y or SEG-D input.
  var note = @["Converted from " & $f.kind & " " & f.path.extractFilename & " by " &
    ConverterName]
  var t = NaN
  case f.kind
  of skSegy:
    template s: untyped = f.index.segy
    note[0] = "Converted from SEG-Y rev " & $s.revision & " " & f.path.extractFilename & " by " &
      ConverterName
    let sorting = case s.binary.traceSorting
      of 1: "AS_ACQUIRED"
      of 2: "CDP_GATHER"
      of 4: "CDP_STACK"
      of 5: "COMMON_SOURCE"
      of 6: "COMMON_RECEIVER"
      of 7: "COMMON_OFFSET"
      else: ""
    if sorting.len > 0: fdb["TRACE_SORT"] = sorting
    else:
      fdb["TRACE_SORT"] = "AS_ACQUIRED"
      c.note(snTraceSort, "SEG-Y trace sorting code " & $s.binary.traceSorting &
        " has no SEG-2 TRACE_SORT; AS_ACQUIRED written")
    fdb["UNITS"] = case s.binary.measurementSystem
      of 1: "METERS"
      of 2: "FEET"
      else: "NONE"
    t = f.firstTraceTime
    for n in 1..40:
      let card = s.text.card(n).printable.strip
      let body = if card.len >= 3 and card[0] == 'C': card[3 .. ^1].strip else: card
      if body.len > 0: note.add card
    c.note(snSegyHeaders, "SEG-Y header fields without a SEG-2 keyword are not carried " &
      "(see the seg2convert module doc); the textual header is in NOTE")
    if s.extended.recordCount > 0:
      c.note(snSegyExtended, "SEG-Y extended textual headers are not carried into SEG-2")
    if s.trailer.recordCount > 0:
      c.note(snSegyTrailer, "SEG-Y data trailers are not carried into SEG-2")
  of skSegd:
    fdb["TRACE_SORT"] = "AS_ACQUIRED"
    fdb["UNITS"] = "NONE"
    if f.index.segdRecords.len > 0:
      template rec: untyped = f.index.segdRecords[0]
      note[0] = "Converted from SEG-D rev " & $rec.revision & " " & f.path.extractFilename &
        " by " & ConverterName
      note.add "SEG-D manufacturer code " & $rec.gh1.manufacturerCode & " serial " &
        $rec.gh1.manufacturerSerial & ", format " & $rec.gh1.formatCode
      t = f.firstTraceTime
    for rec in f.index.segdRecords:
      if rec.extended.len > 0 or rec.external.len > 0:
        c.note(snSegdHeaders, "SEG-D extended/external headers are not carried into SEG-2")
      let general = case rec.layout
        of slRev2: rec.sourceHeaders.len > 1
        of slRev3: rec.generalBlocks.len > 0
      if general:
        c.note(snSegdGeneral, "SEG-D general header blocks beyond the source line and " &
          "point are not carried into SEG-2")
      let trailer = case rec.layout
        of slRev2: rec.trailer.len > 0
        of slRev3: rec.trailerRev3.len > 0
      if trailer: c.note(snSegdTrailer, "SEG-D general trailers are not carried into SEG-2")
  of skSeg2, skUnknown: discard
  if finite(t) and t > -62135596800.0 and t < 253402300800.0:
    let (d, clock) = dateText(t)
    fdb["ACQUISITION_DATE"] = d
    fdb["ACQUISITION_TIME"] = clock
  fdb["NOTE"] = note.join(fdb.lineTerm)

func traceTypeOf(f: SeismicFile, i: int, idCode: float64): string =
  # TRACE_TYPE of a SEG-Y (trace id code) or SEG-D (channel type) trace.
  let e = f.index.entries[i]
  case f.kind
  of skSegy:
    if idCode.isNaN: "SEISMIC_DATA"
    else:
      case int(idCode)
      of 2: "DEAD"
      of 5: "UPHOLE"
      of 0, 1, 11..21, 27..41: "SEISMIC_DATA"
      else: "TEST_DATA"
  of skSegd:
    if e.channelSet == NoChannelSet: "SEISMIC_DATA"
    elif f.index.segdRecords[e.record].isRev3:
      case e.channelType
      of 0x10, 0x11: "SEISMIC_DATA"
      of 0x30: "UPHOLE"
      else: "TEST_DATA"
    else:
      case e.channelType
      of 1: "SEISMIC_DATA"
      of 3: "UPHOLE"
      else: "TEST_DATA"
  else: "SEISMIC_DATA"

proc traceStrings(c: var Conv, f: SeismicFile, i: int, t: var Seg2Trace) =
  # The keyword strings of trace `i` of a SEG-Y or SEG-D input.
  let k = f.traceKeys(i)
  template put(key: string, x: float64) =
    if finite(x): t[key] = formatNumber(x)
  put("CHANNEL_NUMBER", if finite(k.channel) and k.channel > 0: k.channel else: float64(i + 1))
  if finite(k.record) and k.record > 0: put("SHOT_SEQUENCE_NUMBER", k.record)
  if finite(k.ensemble) and k.ensemble != 0: put("CDP_NUMBER", k.ensemble)
  put("SOURCE_STATION_NUMBER", k.srcPoint)
  put("RECEIVER_STATION_NUMBER", k.rcvPoint)
  put("LINE_ID", if finite(k.rcvLine): k.rcvLine else: k.srcLine)
  template loc(key: string, x, y, z: float64) =
    if finite(x) and finite(y):
      t[key] = formatNumber(x) & " " & formatNumber(y) &
        (if finite(z): " " & formatNumber(z) else: "")
  loc("SOURCE_LOCATION", k.srcX, k.srcY, k.srcZ)
  loc("RECEIVER_LOCATION", k.rcvX, k.rcvY, k.rcvZ)
  case k.component
  of 11: t["RECEIVER"] = "HYDROPHONE"
  of 12: t["RECEIVER"] = "VERTICAL_GEOPHONE"
  of 13: t["RECEIVER"] = "SH_HORIZONTAL_GEOPHONE"
  of 14: t["RECEIVER"] = "SV_HORIZONTAL_GEOPHONE"
  else: discard
  let dt = f.sampleIntervalUs(i)
  put("SAMPLE_INTERVAL", dt / 1e6)
  let e = f.index.entries[i]
  case f.kind
  of skSegy:
    put("DELAY", f.segyTimeMs(i, "trace.delayRecordingTime") / 1000)
    var tt = f.traceTypeOf(i, f.segyNum(i, "trace.traceIdCode"))
    t["TRACE_TYPE"] = tt
    let stack = f.segyNum(i, "trace.numVertSummed")
    if stack > 1: put("STACK", stack)
    let gain = f.segyNum(i, "trace.instrumentGainConstant")
    if gain != 0: put("FIXED_GAIN", gain)
    template filter(key, freq, slope: string) =
      let fr = f.segyNum(i, "trace." & freq)
      if fr != 0 and finite(fr):
        t[key] = formatNumber(fr) & " " & formatNumber(f.segyNum(i, "trace." & slope))
    filter("ALIAS_FILTER", "aliasFilterFreq", "aliasFilterSlope")
    filter("LOW_CUT_FILTER", "lowCutFreq", "lowCutSlope")
    filter("HIGH_CUT_FILTER", "highCutFreq", "highCutSlope")
    let notch = f.segyNum(i, "trace.notchFilterFreq")
    if notch != 0: put("NOTCH_FREQUENCY", notch)
    let st = [f.segyTimeMs(i, "trace.sourceStatic"), f.segyTimeMs(i, "trace.groupStatic"),
      f.segyTimeMs(i, "trace.totalStatic")]
    if st[0] != 0 or st[1] != 0 or st[2] != 0:
      t["STATIC_CORRECTIONS"] = formatNumber(st[0] / 1000) & " " & formatNumber(st[1] / 1000) &
        " " & formatNumber(st[2] / 1000)
    if int(e.headerBytes) > TraceHeaderSize:
      c.note(snSegyExtensions, "SEG-Y Trace Header Extension 1 and proprietary headers are " &
        "carried only as far as the trace keys hold them")
  of skSegd:
    template rec: untyped = f.index.segdRecords[e.record]
    let st = SegdTrace(layout: rec.layout, scanType: int(e.scanType), channelSet: e.channelSetIndex)
    put("DELAY", rec.startTimeMs(st) / 1000)
    var tt = f.traceTypeOf(i, NaN)
    let edit = f.findTraceField(i, "trace.traceEdit")
    if tt == "SEISMIC_DATA" and edit.isSome and edit.get.toFloat in [1.0, 2.0]: tt = "DEAD"
    t["TRACE_TYPE"] = tt
    if e.channelSetIndex >= 0:
      # SEG-D's descale gives the mV at the system inputs (one shot);
      # SEG-2's mV per shot is sample x DESCALING_FACTOR / STACK.
      var stack = 1.0
      if rec.isRev3:
        let d = rec.scanTypes[st.scanType].descriptorsRev3[st.channelSet]
        if d.verticalStack > 1: stack = float64(d.verticalStack)
        if d.aliasFilterFreq != 0:
          t["ALIAS_FILTER"] = formatNumber(d.aliasFilterFreq) & " " &
            formatNumber(d.aliasFilterSlope)
        if d.lowCutFilterFreq != 0:
          t["LOW_CUT_FILTER"] = formatNumber(d.lowCutFilterFreq) & " " &
            formatNumber(d.lowCutFilterSlope)
        if d.notch1Freq != 0: put("NOTCH_FREQUENCY", d.notch1Freq)
      put("DESCALING_FACTOR", rec.descaleFactor(st) * stack)
      if stack > 1: put("STACK", stack)
    if int(e.headerBytes) > SegdTraceHeaderSize + SegdBlockSize:
      c.note(snSegdExtensions, "SEG-D trace header extensions after #1 (positions, vendor " &
        "blocks) are carried only as far as the trace keys hold them")
  of skSeg2, skUnknown: discard
  t.strings.sortStrings()

proc writeSeg2From(c: var Conv, f: SeismicFile, path: string, opts: Seg2ConvertOptions) =
  var fdb = if f.kind == skSeg2: f.index.seg2 else: initSeg2File(opts.byteOrder)
  fdb.order = opts.byteOrder
  fdb.traceCount = uint16(f.len)
  if f.kind != skSeg2:
    c.fileStrings(f, fdb)
    fdb.strings.sortStrings()
  var w = openSeg2Writer(path, fdb, Seg2WriteOptions(lenient: f.kind == skSeg2))
  try:
    var vals, back: seq[float64]
    var data: seq[byte]
    for i in 0..<f.len:
      c.tickTrace(f, i)
      let e = f.index.entries[i]
      let codec = f.index.codecs[e.record]
      let tl = Location(file: c.loc.file, trace: i)
      if not codec.known or (f.kind == skSeg2 and e.headerBytes == 0):
        c.log.report(sevError, dcUnsupportedFormat, "the samples cannot be decoded; the " &
          "trace is skipped", e.offset, tl)
      else:
        var t = if f.kind == skSeg2: f.seg2Trace(i) else: Seg2Trace()
        if f.kind != skSeg2: c.traceStrings(f, i, t)
        let fmt = if opts.format != s2tKeep: Seg2Format(ord(opts.format))
                  else: seg2FormatFor(codec)
        t.formatCode = uint8(ord(fmt))
        var ok = true
        try:
          f.decodeTrace(i, vals)
        except SegFormatError as x:
          c.log.report(sevError, dcTruncated, x.msg & "; the trace is skipped", e.offset, tl)
          ok = false
        if ok:
          t.numSamples = uint32(vals.len)
          data.setLen dataBytes(fmt, vals.len)
          try:
            encodeSeg2Samples(fmt, vals, data, fdb.order)
            back.setLen vals.len
            decodeSeg2Samples(fmt, data, back, fdb.order)
            for k in 0..<vals.len:
              if back[k] != vals[k] and not (back[k].isNaN and vals[k].isNaN):
                c.inexactTrace(i)
                break
          except SegFormatError as x:
            c.log.report(sevError, dcValidation, "samples do not fit SEG-2 format " & $ord(fmt) &
              " (" & x.msg & "); the trace is written as zeros", e.offset, tl)
            for b in data.mitems: b = 0
          w.writeTrace(t, data)
    c.reportInexact("the SEG-2 target format")
    if not c.tk.finish(): raiseCancelled()
  finally:
    w.close()
    c.log.add w.log

proc reportFailure(c: var Conv, e: ref CatchableError) =
  if e of SegCancelledError: c.log.reportCancelled(c.loc.file)
  else: c.log.report(sevFatal, (if e of IOError: dcIo else: dcValidation), e.msg, loc = c.loc)

proc convertToSeg2*(srcPath, dstPath: string, opts = Seg2ConvertOptions(),
    progress: Progress = nil): DiagLog {.raises: [].} =
  ## Converts the SEG-Y, SEG-D or SEG-2 file `srcPath` to the SEG-2 file
  ## `dstPath` (see the module doc). Never raises: problems, including I/O
  ## failures, are in the result (the input's own diagnostics first). The
  ## output is written to a new temporary file next to `dstPath` and renamed
  ## when complete. `progress` spans the index walk and the writing pass
  ## (see `convertFile`); when it cancels, the result holds a fatal
  ## `dcCancelled` diagnostic and nothing is written.
  var c = Conv(loc: Location(file: dstPath))
  if sameAsInput(srcPath, dstPath, result): return
  var f: SeismicFile
  try:
    f = openSeismic(srcPath, keys = true, progress = progressPhase(progress, 0, 2))
  except SegCancelledError:
    result.reportCancelled(dstPath)
    return
  except CatchableError as e:
    result.report(sevFatal, dcIo, "cannot read: " & e.msg, loc = Location(file: srcPath))
    return
  result.add f.index.log
  if f.index.log.isFatal:
    f.closeQuietly()
    return
  if f.len == 0 or f.len > Seg2MaxTraces:
    result.report(sevFatal, dcValidation, "a SEG-2 file holds 1 to " & $Seg2MaxTraces &
      " traces; the input has " & $f.len & " (split it first)", loc = c.loc)
    f.closeQuietly()
    return
  let tmp = createTempFor(dstPath, result)
  if tmp.len == 0:
    f.closeQuietly()
    return
  c.tk = initProgressTicker(progressPhase(progress, 1, 2), f.mappedSize)
  try:
    c.writeSeg2From(f, tmp, opts)
  except CatchableError as e:
    c.reportFailure(e)
  f.closeQuietly()
  result.add c.log
  finishOutput(tmp, dstPath, keep = not result.isFatal, result)

# ---------------------------------------------------------- SEG-2 to SEG-D --

type
  SetKey = object
    # What the traces of one channel set share.
    dtUs, ns: int
    startUs: int32
    channelType: uint8
    stack: uint8
    descale: float32
    alias, aliasSlope, lowCut, lowCutSlope, notch: float32

  OutTrace = object
    index: int     # SEG-2 trace
    set: int       # channel set (0-based)
    edit: uint8
    t: Seg2Trace

const MappedSegdKeys = ["CHANNEL_NUMBER", "SAMPLE_INTERVAL", "DELAY", "SHOT_SEQUENCE_NUMBER",
  "SOURCE_LOCATION", "RECEIVER_LOCATION", "SOURCE_STATION_NUMBER", "RECEIVER_STATION_NUMBER",
  "LINE_ID", "RECEIVER", "SOURCE", "TRACE_TYPE", "STACK", "DESCALING_FACTOR", "ALIAS_FILTER",
  "LOW_CUT_FILTER", "NOTCH_FREQUENCY", "DATUM"]

func segdFormatFor(formats: set[Seg2Format], rev3: bool): SegdSampleFormat =
  if formats.card == 0: sd8058
  elif formats <= {s2Int16}: sd8036
  elif formats <= {s2Int16, s2Int32}: sd8038
  elif s2Float64 in formats or s2Int32 in formats: (if rev3: sd8080 else: sd8058)
  else: sd8058

func pair(t: Seg2Trace, key: string): (float32, float32) =
  let n = t.numbers(key)
  result[0] = if n.len > 0: float32(n[0]) else: 0'f32
  result[1] = if n.len > 1: float32(n[1]) else: 0'f32

func channelTypeOf(t: Seg2Trace): uint8 =
  let tt = t.traceType
  if tt.isNone: 0x10
  else:
    case tt.get
    of ttSeismicData, ttDead: 0x10
    of ttRadarData: 0x11
    of ttUphole: 0x30
    of ttTestData: 0x70

func sensorTypeOf(t: Seg2Trace): uint8 =
  let r = t.value("RECEIVER")
  if r.isNone: return 0
  let w = r.get.splitWhitespace
  if w.len == 0: return 0
  case w[0].toUpperAscii
  of "HYDROPHONE": 1
  of "VERTICAL_GEOPHONE": 2
  of "SV_HORIZONTAL_GEOPHONE": 3
  of "SH_HORIZONTAL_GEOPHONE": 4
  of "ACCELEROMETER": 6
  else: 0

func sourceBlockType(f: Seg2File, t: Seg2Trace): uint8 =
  var v = t.value("SOURCE")
  if v.isNone: v = f.value("SOURCE")
  let w = if v.isSome: v.get.splitWhitespace else: @[]
  if w.len == 0: 0x1F
  else:
    case w[0].toUpperAscii
    of "VIBRATOR": 0x15
    of "DYNAMITE": 0x16
    of "GUN": 0x17
    else: 0x1F

func positionBlock(x, y, z: float64): seq[byte] =
  let ok = finite(x) and finite(y)
  var p = SegdPositionBlock(tuple1Coord1: (if ok: x else: Inf), tuple1Coord2: (if ok: y else: Inf),
    tuple1Coord3: (if finite(z): z else: Inf), position1Valid: uint8(ord(ok)),
    tuple2Coord1: Inf, tuple2Coord2: Inf, tuple2Coord3: Inf,
    blockType1: BlockTypePosition1, blockType2: BlockTypePosition2, blockType3: BlockTypePosition3)
  @(p.encoded)

func fix40Fits(x: float64): bool = finite(x) and abs(x) < 8388607.0

func sourceBlock(fileNo: int64, k: TraceKeys, blockType: uint8): seq[byte] =
  var s = SegdSourceDescription(extFileNumber: uint32(clamp(fileNo, 0, 0xFFFFFF)),
    sourceLineNumber: (if fix40Fits(k.srcLine): k.srcLine else: 0.0),
    sourcePointNumber: (if fix40Fits(k.srcPoint): k.srcPoint else: 0.0), blockType: blockType)
  @(s.encoded)

func sameSource(a, b: TraceKeys): bool =
  template eq(x, y: float64): bool = (x.isNaN and y.isNaN) or x == y
  eq(a.srcLine, b.srcLine) and eq(a.srcPoint, b.srcPoint) and eq(a.srcX, b.srcX) and
    eq(a.srcY, b.srcY) and eq(a.srcZ, b.srcZ)

proc writeSeg2AsSegd(c: var Conv, f: SeismicFile, sink: RecordSink, opts: SegdConvertOptions) =
  let fdb = f.index.seg2
  let rev3Minor = if opts.revision.major == 3: opts.revision.minor else: 0'u8
  # The traces that can be converted, and their channel sets.
  var outs: seq[OutTrace]
  var sets: seq[SetKey]
  var counts: seq[int]
  var formats: set[Seg2Format]
  for i in 0..<f.len:
    let e = f.index.entries[i]
    let codec = f.index.codecs[e.record]
    let tl = Location(file: c.loc.file, trace: i)
    if not codec.known or e.headerBytes == 0:
      c.log.report(sevError, dcUnsupportedFormat, "the samples cannot be decoded; the trace " &
        "is skipped", e.offset, tl)
    else:
      let t = f.seg2Trace(i)
      let dt = f.sampleIntervalUs(i)
      if not (finite(dt) and dt > 0 and dt < 16_777_216):
        c.log.report(sevError, dcValidation, "the trace has no usable SAMPLE_INTERVAL, which " &
          "SEG-D needs; it is skipped", e.offset, tl)
      else:
        if dt != round(dt):
          c.note(snIntervalRounded, "SEG-D Rev 3 holds sample intervals as whole µs; " &
            "intervals were rounded (" & $dt & " µs)")
        let delay = t.delay.get(0.0) * 1e6
        if delay != round(delay):
          c.note(snDelayRounded, "SEG-D holds start times as whole µs; delays were rounded")
        let (al, als) = t.pair("ALIAS_FILTER")
        let (lc, lcs) = t.pair("LOW_CUT_FILTER")
        let key = SetKey(dtUs: int(round(dt)), ns: int(e.numSamples),
          startUs: int32(clamp(round(delay), -2147483648.0, 2147483647.0)),
          channelType: channelTypeOf(t), stack: uint8(clamp(t.number("STACK").get(1), 0, 255)),
          # mV per shot (SEG-D's descale) = DESCALING_FACTOR / STACK.
          descale: float32(t.number("DESCALING_FACTOR").get(1) /
            max(t.number("STACK").get(1), 1)), alias: al, aliasSlope: als,
          lowCut: lc, lowCutSlope: lcs, notch: float32(t.number("NOTCH_FREQUENCY").get(0)))
        var s = sets.find(key)
        if s < 0:
          sets.add key
          counts.add 0
          s = sets.high
        inc counts[s]
        formats.incl codec.seg2Format.get
        let edit = if t.traceType == some(ttDead): 2'u8 else: 0'u8
        for x in t.strings:
          if x.key.toUpperAscii notin MappedSegdKeys: c.unmappedKey(x.key)
        outs.add OutTrace(index: i, set: s, edit: edit, t: t)
  if outs.len == 0:
    raiseFormat("the SEG-2 file has no convertible traces; nothing written")
  # Traces go out set by set (stable).
  var order: seq[OutTrace]
  for s in 0..<sets.len:
    for o in outs:
      if o.set == s: order.add o
  for k in 0..<order.len:
    if order[k].index != outs[k].index:
      c.note(snReordered, "SEG-D writes traces channel set by channel set; the SEG-2 traces " &
        "were reordered (CHANNEL_NUMBER and the demux trace numbers keep their identity)")
      break
  let fmt = if opts.format != tfKeep: segdSampleFormats[ord(opts.format) - 1]
            else: segdFormatFor(formats, opts.revision.major >= 3)
  # Geometry: one source for the record, or one per trace.
  var keysOf = newSeq[TraceKeys](order.len)
  for k, o in order: keysOf[k] = f.traceKeys(o.index)
  var oneSource = true
  for k in 1..<order.len:
    if not sameSource(keysOf[k], keysOf[0]): oneSource = false
  var anyRcv, anySrc = false
  for k in keysOf:
    if k.hasReceiverXY: anyRcv = true
    if k.hasSourceXY: anySrc = true
  if anyRcv or anySrc:
    c.note(snLocalCoordinates, "SEG-2 coordinates are local (UNITS " &
      fdb.value("UNITS").get("unknown") & "); the Position blocks carry them without a CRS block")
  let ext = 1 + (if anyRcv: 3 else: 0) + (if oneSource: 0 else: 1 + (if anySrc: 3 else: 0))
  # File number and time.
  var shot = fdb.integer("SHOT_SEQUENCE_NUMBER")
  if shot.isNone: shot = order[0].t.integer("SHOT_SEQUENCE_NUMBER")
  let fileNo = if shot.isSome and shot.get in 0'i64..0xFFFFFF: shot.get else: 1'i64
  let bcdFile = if fileNo <= 9999: int(fileNo) else: BcdAllF
  var rec = SegdRecord(layout: slRev3, format: some(fmt),
    revision: SegdRevision(major: 3, minor: rev3Minor))
  if oneSource:
    rec.generalBlocks.add sourceBlock(fileNo, keysOf[0], sourceBlockType(fdb, order[0].t))
    if anySrc: rec.generalBlocks.add positionBlock(keysOf[0].srcX, keysOf[0].srcY, keysOf[0].srcZ)
  var external = "SEG-2 FILE STRINGS\n"
  for s in fdb.strings: external.add (if s.value.len > 0: s.key & " " & s.value else: s.key) & "\n"
  while external.len mod SegdBlockSize != 0: external.add ' '
  for ch in external: rec.external.add byte(ch)
  let nExternal = rec.external.len div SegdBlockSize
  let nGeneral = rec.generalBlocks.len div SegdBlockSize
  let nSets = sets.len
  rec.gh1 = SegdGeneralHeader1(fileNumber: bcdFile, formatCode: ord(fmt),
    additionalGhBlocks: uint8(2 + nGeneral), manufacturerCode: 0, baseScanInterval16: 0xFF,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: (if nSets <= 99: nSets else: BcdAllF), skewBlocks: 0,
    extendedHeaderBlocks: 0, externalHeaderBlocks: (if nExternal <= 99: nExternal else: BcdAllF))
  let acq = fdb.acquisitionTime
  if acq.isSome:
    let dt = fromUnix(int64(floor(acq.get))).utc
    rec.gh1.year = dt.year mod 100
    rec.gh1.julianDay = dt.yearday + 1
    rec.gh1.hour = dt.hour
    rec.gh1.minute = dt.minute
    rec.gh1.second = dt.second
    rec.gh3.timeZero = unixToTimestamp(acq.get)
  var recordUs = 0'i64
  for s in sets: recordUs = max(recordUs, int64(s.startUs) + int64(s.ns) * int64(s.dtUs))
  rec.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: uint32(fileNo),
    extChannelSetsPerScanType: uint16(nSets), revisionMajor: 3, revisionMinor: rev3Minor,
    extRecordLength: uint32(clamp(recordUs, 0, int64(high(uint32)))),
    dominantSamplingInterval: uint32(sets[0].dtUs), extExternalHeaderBlocks: uint32(nExternal),
    blockType: BlockTypeGeneralHeader2)
  rec.gh3.blockType = BlockTypeGeneralHeader3
  var descs: seq[SegdChannelSetDescriptorRev3]
  for k, s in sets:
    var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: uint16(k + 1),
      channelType: s.channelType, startTime: s.startUs,
      endTime: int32(clamp(int64(s.startUs) + int64(max(s.ns - 1, 0)) * s.dtUs, 0,
        int64(high(int32)))),
      numSamples: uint32(s.ns), descaleMultiplier: s.descale, channelsInSet: uint32(counts[k]),
      samplingInterval: uint32(s.dtUs), traceHeaderExtensions: uint8(ext), verticalStack: s.stack,
      aliasFilterFreq: s.alias, aliasFilterSlope: s.aliasSlope, lowCutFilterFreq: s.lowCut,
      lowCutFilterSlope: s.lowCutSlope, notch1Freq: s.notch, blockType1: BlockTypeChannelSet1,
      blockType2: BlockTypeChannelSet2, blockType3: BlockTypeChannelSet3)
    for i, ch in "SEG-2": d.description[i] = ch
    descs.add d
  rec.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: descs)]
  # Sizes: headers, then every trace.
  let header = rec.headerBytes
  var data = header
  for o in order:
    data += SegdTraceHeaderSize + SegdBlockSize * ext + dataBytes(fmt, sets[o.set].ns)
  rec.gh3.headerSize = uint32(header)
  rec.gh3.dataSize = uint64(data)
  rec.gh3.recordSize = uint64(data)
  rec.gh2Rev3.generalTrailerBlocks = 0
  rec.traceCount = order.len
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(rec)
  var vals, back: seq[float64]
  for k, o in order:
    c.tickTrace(f, k)
    let kk = keysOf[k]
    let s = sets[o.set]
    let ch = o.t.channelNumber
    let traceNo = if ch.isSome and ch.get in 1'i64..0xFFFFFF: ch.get else: int64(o.index + 1)
    var t = SegdTrace(layout: slRev3, index: k, numSamples: s.ns, scanType: 0, channelSet: o.set)
    t.header = SegdTraceHeader(fileNumber: bcdFile, scanTypeNumber: 1,
      channelSetNumber: (if o.set < 99: o.set + 1 else: BcdAllF),
      extChannelSetNumber: uint16(o.set + 1),
      traceNumber: (if traceNo <= 9999: int(traceNo) else: BcdAllF),
      traceHeaderExtensions: uint8(ext), traceEdit: o.edit, extFileNumber: uint32(fileNo))
    var e1 = SegdTraceHeaderExt1Rev3(numSamples: uint32(s.ns), sensorType: sensorTypeOf(o.t),
      extTraceNumber: uint32(traceNo), blockType: BlockTypeTraceHeaderExt1)
    template station(x: float64, short, long: untyped) =
      if finite(x) and x == round(x) and x >= -8388608 and x <= 8388607 and x != -1:
        e1.short = int32(x)
      elif fix40Fits(x):
        e1.short = -1
        e1.long = x
    station(kk.rcvLine, receiverLineNumber, extReceiverLineNumber)
    station(kk.rcvPoint, receiverPointNumber, extReceiverPointNumber)
    t.ext1Rev3 = some e1
    if anyRcv: t.extensions.add positionBlock(kk.rcvX, kk.rcvY, kk.rcvZ)
    if not oneSource:
      t.extensions.add sourceBlock(fileNo, kk, sourceBlockType(fdb, o.t))
      if anySrc: t.extensions.add positionBlock(kk.srcX, kk.srcY, kk.srcZ)
    f.decodeTrace(o.index, vals)
    vals.setLen s.ns
    t.samples = newSeq[byte](dataBytes(fmt, s.ns))
    try:
      encodeSegdSamples(fmt, vals, t.samples)
      back.setLen s.ns
      decodeSegdSamples(fmt, t.samples, back)
      for q in 0..<s.ns:
        if back[q] != vals[q] and not (back[q].isNaN and vals[q].isNaN):
          c.inexactTrace(o.index)
          break
    except SegFormatError as x:
      c.log.report(sevError, dcValidation, "samples do not fit SEG-D format " & $ord(fmt) &
        " (" & x.msg & "); the trace is written as zeros", loc = Location(file: c.loc.file,
        trace: o.index))
      t.samples = newSeq[byte](dataBytes(fmt, s.ns))
    w.writeTrace(t)
  if not c.tk.finish(): raiseCancelled()
  w.endRecord()
  w.close()
  c.log.add w.log
  c.reportInexact("SEG-D format " & $ord(fmt))
  c.reportUnmapped("SEG-D")

proc convertSeg2ToSegd*(srcPath, dstPath: string, opts = SegdConvertOptions(),
    progress: Progress = nil): DiagLog {.raises: [].} =
  ## Converts the SEG-2 file `srcPath` to the SEG-D file `dstPath`, Rev 2.0,
  ## 2.1, 3.0 or 3.1 (`opts.revision`; see the module doc). Never raises:
  ## problems, including I/O failures, are in the result. The output is
  ## written to a new temporary file next to `dstPath` and renamed when
  ## complete. `progress` spans every pass (see `convertFile`); when it
  ## cancels, the result holds a fatal `dcCancelled` diagnostic and nothing
  ## is written.
  var c = Conv(loc: Location(file: dstPath))
  if sameAsInput(srcPath, dstPath, result): return
  let r = opts.revision
  let passes = if r.major == 3: 2 else: 3 # Rev 2: through a Rev 3.0 file
  if not (r.major == 2 and r.minor in {0'u8, 1} or r.major == 3 and r.minor in {0'u8, 1}):
    result.report(sevFatal, dcValidation, "target revision " & $r & " is not 2.0, 2.1, 3.0 " &
      "or 3.1", loc = c.loc)
    return
  var f: SeismicFile
  try:
    f = openSeismic(srcPath, keys = true, progress = progressPhase(progress, 0, passes))
  except SegCancelledError:
    result.reportCancelled(dstPath)
    return
  except CatchableError as e:
    result.report(sevFatal, dcIo, "cannot read: " & e.msg, loc = Location(file: srcPath))
    return
  result.add f.index.log
  let inSize = f.mappedSize
  if f.index.log.isFatal or f.kind != skSeg2:
    if f.kind != skSeg2 and not f.index.log.isFatal:
      result.report(sevFatal, dcUnsupportedFormat, srcPath & " is not SEG-2", loc = c.loc)
    f.closeQuietly()
    return
  # Rev 3 is written directly; Rev 2 through a Rev 3.0 file.
  let direct = r.major == 3
  let rev3Path = createTempFor(if direct: dstPath else: dstPath & ".rev3", result)
  if rev3Path.len == 0:
    f.closeQuietly()
    return
  var sink: RecordSink
  try:
    try:
      sink = openDiskSink(rev3Path)
      var o3 = opts
      if not direct: o3.revision = SegdRevision(major: 3, minor: 0)
      c.tk = initProgressTicker(progressPhase(progress, 1, passes), f.mappedSize)
      c.writeSeg2AsSegd(f, sink, o3)
    finally:
      if sink != nil: sink.close()
  except CatchableError as e:
    c.reportFailure(e)
  f.closeQuietly()
  result.add c.log
  if direct:
    finishOutput(rev3Path, dstPath, keep = not result.isFatal, result)
  else:
    if not result.isFatal:
      var o2 = opts
      o2.format = tfKeep # chosen by the first pass
      try:
        result.add convertSegdRevision(rev3Path, dstPath, o2,
          progressPhase(progress, 2, 3, inSize))
      except CatchableError as e: # it logs its own failures; this is a safety net
        result.report(sevFatal, dcIo, e.msg, loc = c.loc)
    try: removeFile(rev3Path)
    except OSError: discard
