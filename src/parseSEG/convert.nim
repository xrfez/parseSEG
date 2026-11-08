## Conversion between revisions and standards (task 8.6).
##
## - `convertSegy`: SEG-Y to SEG-Y, with a new revision (0, 1, 2.0 or 2.1),
##   byte order and/or sample format. Headers are carried over. Structures the
##   target revision lacks (extended text before Rev 1; Trace Header
##   Extension 1, proprietary headers and trailers before Rev 2) are dropped,
##   and each kind of loss is logged once.
## - `convertSegdToSegy`: SEG-D (Rev 1, 2.x, 3.x) to SEG-Y. Every record's
##   traces go out in file order, one SEG-Y trace per SEG-D trace (auxiliary
##   traces included, with their trace identification code). The mapping is
##   the table below. Everything SEG-Y has no place for (general, extended
##   and external headers, vendor blocks, the general trailer) is reported,
##   once per kind, as an info diagnostic.
## - `convertFile`: detects the input standard and dispatches.
##
## Samples go through float64 (exact for every SEG-D and SEG-Y format) and
## are re-encoded in the target format. The default (`format = 0`) picks a
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
## | numSamples, sampleInterval (Ext1 ext*) | trace sample count, channel set interval (µs) |
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

import std/[math, os, strutils]
import ./common/[endians, errors, diagnostics]
import ./io/[records, diskio]
import ./segy/[reader as segyreader, writer as segywriter, textheader, binheader, traceheader,
  samples as segysamples, exttext]
import ./segd/[reader as segdreader]
import ./model/[traceindex, keys]
import ./segy/layout
import ./io/memsource
import ./abi/pragmas

const
  ConverterName = "parseSEG 0.2.0"
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
  ConvertOptions* = object
    ## Target settings. The defaults give SEG-Y Rev 2.1, big-endian, EBCDIC
    ## text, a lossless sample format and recorded (not descaled) values.
    revision*: SegyRevision = SegyRevision(major: 2, minor: 1)
    byteOrder*: ByteOrder = boBig
    format*: int = 0            ## SEG-Y format code; 0 = keep (SEG-Y) or choose losslessly.
    textEncoding*: TextEncoding = teEbcdic ## SEG-D → SEG-Y: the textual header's encoding.
    applyDescale*: bool = false ## SEG-D: write millivolts (MP factor / descale multiplier).
    stationHeader*: bool = true ## SEG-D → SEG-Y Rev 2: the `PSEGD001` header and Layout stanza.

proc note(log: var DiagLog, seen: var set[0..63], id: int, msg: string, loc: Location) =
  # An information-loss note, logged once per kind.
  if id notin seen:
    seen.incl id
    log.report(sevInfo, dcValidation, msg, loc = loc)

func checkTarget(opts: ConvertOptions, err: var string): bool =
  let r = opts.revision
  if not (r.major == 0 and r.minor == 0 or r.major == 1 and r.minor == 0 or
      r.major == 2 and r.minor in {0'u8, 1}):
    err = "target revision " & $r & " is not 0, 1, 2.0 or 2.1"
    return false
  if opts.format != 0:
    var f: SampleFormat
    if not toSampleFormat(opts.format, f):
      err = "target format " & $opts.format & " is not a writable SEG-Y format"
      return false
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

type
  Losses = object
    ## Traces whose samples could not be written exactly.
    traces, first: int

proc encodeExact(fmt: SampleFormat, vals: openArray[float64], dst: var seq[byte],
    order: ByteOrder, scratch: var seq[float64]): bool =
  # Encodes, then decodes back: false if any value changed (rounding, float32
  # narrowing, overflow to infinity). Raises like `encodeSamples`.
  dst.setLen vals.len * sampleSize(fmt)
  encodeSamples(fmt, vals, dst, order)
  scratch.setLen vals.len
  decodeSamples(fmt, dst, scratch, order)
  for i in 0..<vals.len:
    if scratch[i] != vals[i] and not (scratch[i].isNaN and vals[i].isNaN): return false
  true

proc count(l: var Losses, trace: int) =
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
        let p = e.byte - 1
        let parts = if e.kind == ltScale6: @[(p, 4), (p + 4, 2)] else: @[(p, e.kind.size)]
        for (q, n) in parts:
          if q >= 0 and q + n <= TraceHeaderSize and q notin done:
            swapField(blocks.toOpenArray(i, i + TraceHeaderSize - 1), q, n, src, dst)
            done.incl q
    if not described: result = false
    i += TraceHeaderSize

# ------------------------------------------------------------- SEG-Y → SEG-Y --

proc convertSegy*(src: RecordSource, sink: RecordSink, opts = ConvertOptions()): DiagLog =
  ## Rewrites the SEG-Y file at `src` with the target revision, byte order and
  ## format of `opts` (`format = 0` keeps the input format). The reader's,
  ## the writer's and the conversion's diagnostics are all in the result; a
  ## fatal one means the output is incomplete.
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
  var seen: set[0..63]
  let fromRev = f.revision
  let rev = opts.revision
  var outFmt = f.format
  if opts.format != 0: discard toSampleFormat(opts.format, outFmt)
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
  f.binary.segyMajor = rev.major
  f.binary.segyMinor = rev.minor
  f.revision = rev
  f.binary.formatCode = int16(ord(outFmt))
  if rev == SegyRevision(major: 2, minor: 0):
    if f.binary.surveyType != 0:
      result.note(seen, 20, "Rev 2.0 has no survey type (bytes 3509-3510 belong to the " &
        "additional trace header count): survey type " & $f.binary.surveyType & " dropped", loc)
      f.binary.surveyType = 0
    for s in f.extended.stanzas:
      if s.company.toUpperAscii == "SEG" and s.name.toLowerAscii.startsWith("layout"):
        result.note(seen, 21, "the ((SEG:Layout)) stanza is defined from Rev 2.1; a Rev 2.0 " &
          "reader ignores it (it is kept as text)", loc)
  if rev.major == 0 and f.extended.recordCount > 0:
    result.note(seen, 0, "Rev 0 has no extended textual headers: " & $f.extended.recordCount &
      " records dropped", loc)
  if rev.major == 0 or (rev.major < 2 and f.extended.recordCount > 0 and fromRev.major >= 2):
    if rev.major == 0:
      f.extended = initExtendedTextHeader()
      f.binary.numExtTextHeaders = 0
    else:
      result.note(seen, 1, "Rev 2 stanzas (Layout, User Data) are kept as plain Rev 1 " &
        "extended text", loc)
  if rev.major < 2:
    if f.trailer.recordCount > 0:
      result.note(seen, 2, "Rev 1 has no data trailers: " & $f.trailer.recordCount &
        " records dropped", loc)
    f.trailer = initExtendedTextHeader()
    f.binary.byteOrderMarker = 0
    f.binary.maxAddlTraceHeaders = 0
    f.binary.numTraces = 0
    f.binary.firstTraceOffset = 0
    f.binary.numTrailerRecords = 0
    f.binary.extSamplesPerTrace = 0
    if f.binary.sampleInterval == 0 and f.binary.extSampleInterval > 0:
      f.binary.sampleInterval = uint16(clamp(round(f.binary.extSampleInterval), 0, 65535))
      result.note(seen, 4, "Rev 1 holds sample intervals as whole units; extended " &
        "intervals were rounded", loc)
    f.binary.extSampleInterval = 0
  else:
    f.binary.byteOrderMarker = 0x0102_0304
    if fromRev.major < 2:
      f.binary.firstTraceOffset = 0
      f.binary.numTrailerRecords = 0
      if f.extended.recordCount > 0 and not f.extended.hasEndText:
        f.extended.addEndText()
        f.binary.numExtTextHeaders = int16(f.extended.recordCount)
  let inFmt = f.format
  f.format = outFmt
  var w: SegyWriter
  try:
    w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: opts.byteOrder, lenient: true))
  except CatchableError as e:
    result.add r.log
    result.report(sevFatal, dcIo, "cannot write the file headers: " & e.msg, loc = loc)
    return
  let lay = f.layoutOf
  var t: SegyTrace
  var buf: seq[byte]
  var vals, scratch: seq[float64]
  var losses: Losses
  var layoutReordered: seq[int] # traces whose proprietary headers the Layout fully described
  while r.readTrace(t):
    let tl = Location(file: sink.name, trace: t.index)
    var ok = true
    if rev.major < 2:
      if t.hasExt1:
        if t.ext1.extNumSamples > high(uint16) or t.numSamples > int(high(uint16)):
          result.report(sevError, dcValidation, "the trace has " & $t.numSamples &
            " samples, which Rev 1 cannot hold; skipped", t.offset, tl)
          ok = false
        result.note(seen, 3, "Rev 1 has no Trace Header Extension 1 or proprietary trace " &
          "headers: dropped", loc)
      t.hasExt1 = false
      t.proprietary.setLen 0
      t.header.numSamples = uint16(min(t.numSamples, int(high(uint16))))
      if t.sampleInterval != float64(t.header.sampleInterval):
        result.note(seen, 4, "Rev 1 holds sample intervals as whole units; extended " &
          "intervals were rounded", loc)
        t.header.sampleInterval = uint16(clamp(round(t.sampleInterval), 0, 65535))
    if ok and t.proprietary.len > 0 and opts.byteOrder != f.byteOrder:
      if reorderProprietary(lay, t.proprietary, f.byteOrder, opts.byteOrder):
        layoutReordered.add t.index
    if ok and outFmt != inFmt:
      try:
        vals.setLen t.numSamples
        decodeSamples(inFmt, t.samples, vals, f.byteOrder)
        if not encodeExact(outFmt, vals, buf, f.byteOrder, scratch): losses.count(t.index)
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

func traceIdOf(rec: SegdRecord, t: SegdTrace, sensor: uint8): int16 =
  # SEG-D channel type → SEG-Y trace identification code (Table 4.5).
  if t.channelSet < 0: return 0
  let ct = if rec.isRev3: int(rec.scanTypes[t.scanType].descriptors3[t.channelSet].channelType)
           else: int(rec.scanTypes[t.scanType].descriptors[t.channelSet].channelType)
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

func intervalUs(rec: SegdRecord, t: SegdTrace): float64 =
  if t.channelSet < 0:
    (if rec.isRev3: baseScanIntervalUs(rec.gh1, rec.gh2r3) else: rec.gh1.baseScanIntervalMs * 1000)
  elif rec.isRev3: float64(rec.scanTypes[t.scanType].descriptors3[t.channelSet].samplingInterval)
  else: rec.scanTypes[t.scanType].descriptors[t.channelSet].sampleIntervalMs(rec.gh1) * 1000

func startMs(rec: SegdRecord, t: SegdTrace): float64 =
  if t.channelSet < 0: 0.0
  elif rec.isRev3: float64(rec.scanTypes[t.scanType].descriptors3[t.channelSet].startTime) / 1000
  else: rec.scanTypes[t.scanType].descriptors[t.channelSet].startTimeMs

func descaleOf(rec: SegdRecord, t: SegdTrace): float64 =
  if t.channelSet < 0: 1.0
  elif rec.isRev3:
    let m = float64(rec.scanTypes[t.scanType].descriptors3[t.channelSet].descaleMultiplier)
    if m == 0 or m.isNaN: 1.0 else: m
  else: pow(2.0, rec.scanTypes[t.scanType].descriptors[t.channelSet].mpFactor)

func scalarFor(values: openArray[float64]): int16 =
  # The finest coordinate scalar (-1000, -100, -10, 1) whose scaled values
  # fit in int32; NaN values are ignored.
  for s in [-1000'i16, -100, -10, 1]:
    let mult = if s < 0: float64(-s) else: 1.0
    var fits = true
    for v in values:
      if not v.isNaN and abs(round(v * mult)) > 2147483647.0: fits = false
    if fits: return s
  1

func scaled(v: float64, scalar: int16): int32 =
  if v.isNaN: 0'i32
  else:
    let mult = if scalar < 0: float64(-scalar) else: 1.0 / float64(max(scalar, 1))
    int32(clamp(round(v * mult), -2147483648.0, 2147483647.0))

func clampI16(x: float64): int16 = int16(clamp(round(x), -32768.0, 32767.0))

proc fillTime(h: var SegyTraceHeader, rec: SegdRecord): bool =
  # False (fields left 0) when the record's time is outside years 1-9999.
  result = true
  if rec.isRev3 and rec.gh3.timeZero != 0:
    let unix = timestampToUnix(rec.gh3.timeZero)
    if not (unix > -62135596800.0 and unix < 253402300800.0): return false
    let days = floor(unix / 86400.0)
    var secs = unix - days * 86400.0
    # Civil date from days since 1970-01-01 (H. Hinnant's algorithm).
    let z = int64(days) + 719468
    let era = (if z >= 0: z else: z - 146096) div 146097
    let doe = z - era * 146097
    let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
    let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
    let mp = (5 * doy + 2) div 153
    let m = if mp < 10: mp + 3 else: mp - 9
    let y = yoe + era * 400 + (if m <= 2: 1 else: 0)
    let leap = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0
    let monthStart = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    let d = doy - (153 * mp + 2) div 5 + 1
    h.year = int16(y)
    h.dayOfYear = int16(monthStart[m - 1] + int(d) + (if leap and m > 2: 1 else: 0))
    h.hour = int16(secs / 3600)
    secs -= float64(h.hour) * 3600
    h.minute = int16(secs / 60)
    h.second = int16(secs - float64(h.minute) * 60)
    h.timeBasisCode = 4 # UTC
  elif rec.gh1.year >= 0 and rec.gh1.julianDay in 0..366 and rec.gh1.hour in 0..24 and
      rec.gh1.minute in 0..60 and rec.gh1.second in 0..60:
    h.year = int16(if rec.gh1.year < 70: 2000 + rec.gh1.year else: 1900 + rec.gh1.year)
    h.dayOfYear = int16(max(rec.gh1.julianDay, 0))
    h.hour = int16(max(rec.gh1.hour, 0))
    h.minute = int16(max(rec.gh1.minute, 0))
    h.second = int16(max(rec.gh1.second, 0))
    h.timeBasisCode = 4 # SEG-D general header times are UTC

proc stationHeader(k: TraceKeys, rec: SegdRecord, t: SegdTrace,
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
  putNum(result, 40, int32(rec.index), order)
  putNum(result, 44, int32(t.channelSet), order)
  let ct = if t.channelSet < 0: 0'i16
           elif rec.isRev3: int16(rec.scanTypes[t.scanType].descriptors3[t.channelSet].channelType)
           else: int16(rec.scanTypes[t.scanType].descriptors[t.channelSet].channelType)
  putNum(result, 48, ct, order)
  for i, c in StationHeaderName: result[232 + i] = byte(c)

proc convertSegdToSegy*(src: RecordSource, sink: RecordSink, opts = ConvertOptions(),
    recordFormats: set[SegdSampleFormat] = {}): DiagLog =
  ## Converts the SEG-D stream at `src` to one SEG-Y file (see the module
  ## doc for the mapping). `recordFormats`, the formats of all records (from
  ## a header scan; `convertFile` does one), lets the default format choice
  ## hold every record exactly; without it the first record decides. Either
  ## way every trace is checked after encoding, and traces not written
  ## exactly are counted in a warning. The reader's, the writer's and the
  ## conversion's diagnostics are all in the result; a fatal one means the
  ## output is incomplete.
  var err: string
  if not checkTarget(opts, err):
    result.report(sevFatal, dcValidation, err, loc = Location(file: sink.name))
    return
  let rev = opts.revision
  let loc = Location(file: sink.name)
  var seen: set[0..63]
  var r = openSegd(src, headersOnly = false)
  var w: SegyWriter
  var opened = false
  var outFmt: SampleFormat
  var nOut = 0
  var vals, scratch: seq[float64]
  var losses: Losses
  while r.nextRecord():
    let rec = r.record
    if not rec.formatKnown:
      result.report(sevError, dcUnsupportedFormat, "record " & $rec.index & ": SEG-D format " &
        $rec.gh1.formatCode & " cannot be decoded; its traces are skipped", rec.offset, loc)
    if rec.extended.len > 0 or rec.external.len > 0:
      result.note(seen, 10, "SEG-D extended/external headers are not carried into SEG-Y", loc)
    if rec.generalBlocks.len > 0 or rec.sourceHeaders.len > 1:
      result.note(seen, 11, "SEG-D general header blocks beyond the first source are not " &
        "carried into SEG-Y", loc)
    if rec.trailer.len > 0 or rec.trailerBytes.len > 0:
      result.note(seen, 12, "SEG-D general trailers are not carried into SEG-Y", loc)
    var t: SegdTrace
    var inRecord = 0
    while r.readTrace(t):
      inc inRecord
      if not opened:
        # The file headers come from the first trace.
        outFmt = if recordFormats.card > 0:
                   commonFormat(recordFormats, rev, opts.applyDescale, opts.byteOrder)
                 elif rec.formatKnown:
                   losslessFormat(rec.format, rev, opts.applyDescale, opts.byteOrder)
                 else: sfFloat32
        if opts.format != 0: discard toSampleFormat(opts.format, outFmt) # checked above
        var f = SegyFile(byteOrder: opts.byteOrder, format: outFmt, formatKnown: true,
          revision: rev, extended: initExtendedTextHeader(), trailer: initExtendedTextHeader())
        f.text = initTextHeader(opts.textEncoding)
        let cards = [
          "CONVERTED FROM SEG-D REV " & $rec.revision & " BY " & ConverterName,
          "SOURCE " & src.name.extractFilename,
          "MANUFACTURER CODE " & $rec.gh1.manufacturerCode & " SERIAL " &
            $rec.gh1.manufacturerSerial,
          "SEG-D FORMAT " & $rec.gh1.formatCode & " WRITTEN AS SEG-Y FORMAT " & $ord(outFmt),
          (if opts.applyDescale: "SAMPLES DESCALED TO MILLIVOLTS (MP FACTOR / DSM)"
           else: "SAMPLES ARE RECORDED VALUES (NOT DESCALED)"),
          "ONE SEG-Y TRACE PER SEG-D TRACE, FIELD RECORD = SEG-D FILE NUMBER",
          (if rev.major >= 2 and opts.stationHeader:
             "LINE/POINT IN PROPRIETARY HEADER " & StationHeaderName & " (LAYOUT STANZA)"
           else: "SEG-D RECEIVER/SOURCE LINE AND POINT NOT CARRIED (REV 1)")]
        for i, c in cards: f.text.setCard(i + 1, cardPrefix(i + 1) & c)
        f.text.setCard(39, cardPrefix(39) & (if rev.major >= 2: "SEG-Y_REV" & $rev.major &
          "." & $rev.minor elif rev.major == 1: "SEG Y REV1" else: ""))
        f.text.setCard(40, cardPrefix(40) & "END TEXTUAL HEADER")
        let ns = t.numSamples
        let dt = intervalUs(rec, t)
        let dtWhole = dt == round(dt) and dt <= 65535 and dt >= 0
        f.binary = SegyBinaryHeader(formatCode: int16(ord(outFmt)), segyMajor: rev.major,
          segyMinor: rev.minor, fixedLengthTraces: 0, traceSorting: 1, measurementSystem: 1,
          samplesPerTrace: uint16(min(ns, 65535)),
          sampleInterval: uint16(if dtWhole or rev.major < 2: clamp(round(dt), 0, 65535) else: 0),
          dataTracesPerEnsemble: int16(min(rec.traceCount, 32767)))
        if rev.major >= 2:
          f.binary.byteOrderMarker = 0x0102_0304
          if ns > 65535: f.binary.extSamplesPerTrace = uint32(ns)
          if f.binary.sampleInterval == 0: f.binary.extSampleInterval = dt
          f.binary.maxAddlTraceHeaders = if opts.stationHeader: 2 else: 1
          if opts.stationHeader:
            f.extended.addText("SEG", "Layout", stationLayout, "text/xml")
          f.extended.addEndText()
          f.binary.numExtTextHeaders = int16(f.extended.recordCount)
        try:
          w = openSegyWriter(sink, f, SegyWriteOptions(byteOrder: opts.byteOrder, lenient: true))
        except CatchableError as e:
          result.report(sevFatal, dcIo, "cannot write the file headers: " & e.msg, loc = loc)
          result.add r.log
          return
        opened = true
      if rec.formatKnown:
        let tl = Location(file: sink.name, trace: nOut)
        let k = traceKeys(rec, t)
        var ot = SegyTrace(index: nOut, numSamples: t.numSamples)
        var h = SegyTraceHeader(traceSeqLine: int32(nOut + 1), traceSeqFile: int32(nOut + 1),
          fieldRecord: int32(clamp(k.record, -2147483648.0, 2147483647.0)),
          traceInEnsemble: int32(inRecord), traceIdCode: traceIdOf(rec, t, k.sensorType))
        h.traceNumberInField = int32(if rec.isRev3: traceNumber(t.header, t.ext1r3)
                                     elif t.header.traceNumber >= 0: t.header.traceNumber
                                     else: inRecord)
        if not k.srcPoint.isNaN:
          h.energySourcePoint = int32(clamp(round(k.srcPoint), -2147483648.0, 2147483647.0))
          h.shotpointScalar = if k.srcPoint == round(k.srcPoint): 1 else: -100
          h.shotpointNumber = scaled(k.srcPoint, h.shotpointScalar)
        let dt = intervalUs(rec, t)
        h.numSamples = uint16(min(t.numSamples, 65535))
        h.sampleInterval = uint16(if dt == round(dt) and dt <= 65535: dt else: 0)
        let fits = t.numSamples <= 65535 or rev.major >= 2
        if not fits:
          result.report(sevError, dcValidation, "the trace has " & $t.numSamples &
            " samples, which Rev 1 cannot hold; skipped", t.offset, tl)
        if h.sampleInterval == 0 and rev.major < 2:
          result.note(seen, 13, "Rev 1 holds sample intervals as whole microseconds; " &
            "intervals were rounded", loc)
          h.sampleInterval = uint16(clamp(round(dt), 0, 65535))
        h.delayRecordingTime = clampI16(startMs(rec, t))
        h.coordinateScalar = scalarFor([k.srcX, k.srcY, k.rcvX, k.rcvY, k.cmpX, k.cmpY])
        h.sourceX = scaled(k.srcX, h.coordinateScalar)
        h.sourceY = scaled(k.srcY, h.coordinateScalar)
        h.groupX = scaled(k.rcvX, h.coordinateScalar)
        h.groupY = scaled(k.rcvY, h.coordinateScalar)
        h.cdpX = scaled(k.cmpX, h.coordinateScalar)
        h.cdpY = scaled(k.cmpY, h.coordinateScalar)
        if k.hasSourceXY or k.hasReceiverXY: h.coordinateUnits = 1
        h.elevationScalar = scalarFor([k.srcZ, k.rcvZ])
        h.receiverElevation = scaled(k.rcvZ, h.elevationScalar)
        h.sourceSurfaceElevation = scaled(k.srcZ, h.elevationScalar)
        if not k.offset.isNaN: h.offset = int32(clamp(round(k.offset), -2147483648.0, 2147483647.0))
        if not h.fillTime(rec):
          result.note(seen, 16, "a record's time is outside years 1-9999; the trace time " &
            "fields are left 0", loc)
        ot.header = h
        ot.sampleInterval = dt
        if rev.major >= 2:
          ot.hasExt1 = true
          var e = initTraceHeaderExt1()
          e.numAddlTraceHeaders = if opts.stationHeader: 2 else: 1
          e.extFieldRecord = int64(h.fieldRecord)
          e.extTraceSeqLine = uint64(nOut + 1)
          e.extTraceSeqFile = uint64(nOut + 1)
          if t.numSamples > 65535: e.extNumSamples = uint32(t.numSamples)
          if h.sampleInterval == 0: e.extSampleInterval = dt
          template f64(dst: untyped, v: float64) =
            if not v.isNaN: dst = v
          f64(e.extSourceX, k.srcX)
          f64(e.extSourceY, k.srcY)
          f64(e.extGroupX, k.rcvX)
          f64(e.extGroupY, k.rcvY)
          f64(e.extCdpX, k.cmpX)
          f64(e.extCdpY, k.cmpY)
          f64(e.extOffset, k.offset)
          f64(e.extReceiverElevation, k.rcvZ)
          f64(e.extSourceSurfaceElevation, k.srcZ)
          ot.ext1 = e
          if opts.stationHeader: ot.proprietary = stationHeader(k, rec, t, opts.byteOrder)
        else:
          if not (k.rcvLine.isNaN and k.srcLine.isNaN):
            result.note(seen, 14, "Rev 1 has no field for SEG-D receiver/source line and " &
              "point; they are not carried", loc)
        # Samples: decode exactly, optionally descale, encode in the target format.
        vals.setLen t.numSamples
        try:
          if rec.format == sd8048 and outFmt == sfIbm32 and not opts.applyDescale:
            # IBM words are copied: going through float64/float32 would lose
            # values outside float32's range.
            ot.samples = newSeq[byte](4 * t.numSamples)
            for i in 0..<t.numSamples:
              putNum(ot.samples, 4 * i, getNum[uint32](t.samples, 4 * i, boBig), opts.byteOrder)
          else:
            decodeSegdSamples(rec.format, t.samples, vals, r.twosComplement8015)
            if opts.applyDescale:
              let m = descaleOf(rec, t)
              for v in vals.mitems: v *= m
            if not encodeExact(outFmt, vals, ot.samples, opts.byteOrder, scratch):
              losses.count(nOut)
        except SegFormatError as e:
          result.report(sevError, dcValidation, "samples do not fit SEG-Y format " &
            $ord(outFmt) & " (" & e.msg & "); the trace is written as zeros", t.offset, tl)
          ot.samples = newSeq[byte](t.numSamples * sampleSize(outFmt))
        if fits:
          try:
            w.writeTrace(ot)
          except CatchableError as e:
            result.report(sevFatal, dcIo, "writing trace " & $nOut & ": " & e.msg, loc = tl)
            result.add r.log
            return
          inc nOut
  result.add r.log
  result.report(losses, outFmt, loc)
  if not opened:
    result.report(sevFatal, dcValidation, "the SEG-D stream has no traces; nothing written",
      loc = loc)
    return
  try:
    w.close()
  except CatchableError as e:
    result.report(sevFatal, dcIo, "closing: " & e.msg, loc = loc)
  result.add w.log

# ------------------------------------------------------------------- files --

proc finishOutput*(tmp, dstPath: string, log: var DiagLog) =
  ## Renames a complete output into place, or removes it after a fatal
  ## problem (logged: "not written").
  try:
    if log.isFatal:
      if fileExists(tmp): removeFile(tmp)
    elif fileExists(tmp):
      moveFile(tmp, dstPath)
  except OSError as e:
    log.report(sevFatal, dcIo, "cannot move the output into place: " & e.msg,
      loc = Location(file: dstPath))

proc convertFile*(srcPath, dstPath: string, opts = ConvertOptions()): DiagLog {.segApi.} =
  ## Detects whether `srcPath` is SEG-Y or SEG-D and converts it to the SEG-Y
  ## file `dstPath` (see `convertSegy` / `convertSegdToSegy`). Never raises:
  ## problems, including I/O failures, are in the result.
  var head = newSeq[byte](8192)
  try:
    var f = open(srcPath, fmRead)
    head.setLen f.readBytes(head, 0, head.len)
    f.close()
  except IOError as e:
    result.report(sevFatal, dcIo, "cannot read: " & e.msg, loc = Location(file: srcPath))
    return
  var kind: SeismicKind
  if not detectKind(head, kind):
    result.report(sevFatal, dcUnsupportedFormat, "neither a SEG-Y nor a SEG-D file",
      loc = Location(file: srcPath))
    return
  try:
    if fileExists(dstPath) and sameFile(srcPath, dstPath):
      result.report(sevFatal, dcValidation, "the output is the input file; refusing to " &
        "overwrite it", loc = Location(file: dstPath))
      return
  except OSError:
    discard
  # SEG-D: the formats of all records, from a header-only scan, so one
  # target format can hold them all.
  var formats: set[SegdSampleFormat]
  if kind == skSegd and opts.format == 0:
    try:
      let m = openMemFileSource(srcPath)
      try:
        let ix = buildIndex(m, skSegd)
        for c in ix.codecs:
          if c.known: formats.incl c.segdFormat
      finally:
        m.close()
    except CatchableError:
      discard # the conversion itself reports what is wrong with the file
  # Written to `<dst>.tmp` and renamed when complete: a failed conversion
  # leaves an existing `dstPath` untouched and no partial file behind.
  let tmp = dstPath & ".tmp"
  var src: RecordSource
  var sink: RecordSink
  try:
    src = openDiskSource(srcPath)
    sink = openDiskSink(tmp)
    result = if kind == skSegy: convertSegy(src, sink, opts)
             else: convertSegdToSegy(src, sink, opts, formats)
  except CatchableError as e:
    result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
  finally:
    if src != nil: src.close()
    if sink != nil: sink.close()
  finishOutput(tmp, dstPath, result)
