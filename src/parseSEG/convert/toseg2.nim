## Conversion to SEG-2 (task 11.2). `convertFile` (`convert.nim`) dispatches
## here for `target = skSeg2`.
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
import std/[math, os, strutils, times, tables]
import ../common/[endians, errors, diagnostics, outputfile, progress]
import ../segy/[reader as segyreader, samples as segysamples]
import ../segd/[reader as segdreader, headers as segdheaders, samples as segdsamples, blocks]
import ../seg2/[reader as seg2reader, writer as seg2writer]
import ../model/[traceindex, headerfields]
import ../private/[progressticker, seg2conv]

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

# ---------------------------------------------------------------- to SEG-2 --

func seg2FormatFor(c: TraceCodec): Seg2SampleFormat =
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

proc fileStrings(c: var Seg2Conv, f: SeismicFile, fdb: var Seg2File) =
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
      "(see the convert/toseg2 module doc); the textual header is in NOTE")
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

proc traceStrings(c: var Seg2Conv, f: SeismicFile, i: int, t: var Seg2Trace) =
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
    put("DELAY", f.startTimeMs(i) / 1000)
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

proc writeSeg2From(c: var Seg2Conv, f: SeismicFile, path: string, opts: Seg2ConvertOptions) =
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
        let fmt = if opts.format != s2tKeep: Seg2SampleFormat(ord(opts.format))
                  else: seg2FormatFor(codec)
        t.formatCode = uint8(ord(fmt))
        var ok = true
        try:
          f.decodeFloat64(i, vals)
        except SegFormatError as x:
          c.log.report(sevError, dcTruncated, x.msg & "; the trace is skipped", e.offset, tl)
          ok = false
        if ok:
          t.numSamples = uint32(vals.len)
          data.setLen dataBytes(fmt, vals.len)
          try:
            encodeSamples(fmt, vals, data, fdb.order)
            back.setLen vals.len
            decodeSamples(fmt, data, back, fdb.order)
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

proc convertToSeg2*(srcPath, dstPath: string, opts = Seg2ConvertOptions(),
    progress: Progress = nil): DiagLog {.raises: [].} =
  ## Converts the SEG-Y, SEG-D or SEG-2 file `srcPath` to the SEG-2 file
  ## `dstPath` (see the module doc). Never raises: problems, including I/O
  ## failures, are in the result (the input's own diagnostics first). The
  ## output is written to a new temporary file next to `dstPath` and renamed
  ## when complete. `progress` spans the index walk and the writing pass
  ## (see `convertFile`); when it cancels, the result holds a fatal
  ## `dcCancelled` diagnostic and nothing is written.
  var c = Seg2Conv(loc: Location(file: dstPath))
  if sameAsInput(srcPath, dstPath, result) or isDirectory(dstPath, result): return
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
