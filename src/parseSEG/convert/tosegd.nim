## Conversion to SEG-D. `convertFile` (`convert.nim`) dispatches here for
## `target = skSegd`.
##
## **SEG-D revisions** (`convertSegdRevision`, tasks 8.7, 5.5): Rev 1 / 2.x to Rev 3.0 or 3.1, Rev 3.x to
## Rev 2.0 / 2.1, and within a layout (2.x to 2.y, 3.x to 3.y, format
## changes). The conversion streams record by record, so files of any size
## convert in bounded memory.
##
## Samples are copied byte for byte: every Rev 2 demultiplexed format is still
## defined in Rev 3, with the same encoding. They are re-encoded only for
## `format` (an explicit target format), and for 8080, which Rev 2 lacks
## (8080 to 8058 by default). Re-encoded traces are decoded back and compared;
## inexact ones are counted in one warning.
##
## Everything the target cannot hold is logged: an info note once per kind
## for dropped or approximated values, an error for a record that cannot be
## represented at all (that record is skipped). Writer validation still
## applies, so the output is always readable.
##
## Rev 1/2 to Rev 3:
##
## | Rev 3 | From Rev 1/2 |
## |---|---|
## | GH#1 | the same bytes; byte 12H = blocks after #1 (F with GH#2 bytes 23-24 when > 14); format code |
## | GH#2 (0x02) | ext file number, ext channel sets, ext extended/external counts (widened), record length (FFF: ms to µs), record set number = 2.1 line sequence number, revision 3.0 |
## | GH#3 (0x03) | time zero from GH#1's date and time (whole seconds, UTC to GPS); sizes computed |
## | Source Description | each GH#N: line, point, index, set number; Vibrator (0x15, with phase control, vibrator type and phase angle) when any of those is set, else Other (0x1F) |
## | CSD (96 bytes) | scan type, channel set (resolved), channel type (nibble n to n·0x10; 0xC to 0xA0), start/end time (µs), samples = (end − start) / interval, DSM = 2^MP, channels, interval (µs), array forming, J, EFH, stack, streamer, filters (Hz; notches from tenths) |
## | Demux header | the same, with one extension (THE#1) |
## | THE#1 (0x40) | receiver line, point, index, extended line/point, sensor type; samples |
## | Extended, external, skew | the same bytes |
## | Trailer | one user group (0xA0, "SEG-D REV2 TRLR") holding the Rev 2 trailer blocks unchanged |
##
## Dropped: trace header extensions after #1 (Rev 2 blocks carry no type
## byte, so Rev 3 readers would misread them). Every trace of a channel set
## gets the set's sample count (Rev 3 requires it): longer traces are cut,
## shorter ones zero-padded, with a warning.
##
## Rev 3 to Rev 2: the inverse mapping, plus:
##
## - Source Description blocks become GH#N blocks (line, point, index, set;
##   vibrator fields); every other general header block (text, CRS, position,
##   additional source info, vendor) is dropped and listed once by type.
##   GH#3 (time zero, sizes, recording modes) is dropped.
## - Trace extensions after THE#1 are kept as raw Rev 2 extensions, up to 14
##   (the Rev 2 count is one nibble). THE#1's Rev 3 fields (reshoot, group,
##   depth index, extended trace number, sensor moving, physical unit) are
##   dropped.
## - CSD fields Rev 2 has no place for (numSamples, filter phase and delay,
##   physical unit, description) are dropped; MP = log2(DSM) in 1/1024 steps;
##   times in 2 ms units, filters in whole Hz (notch tenths) are rounded.
## - A trailer this module wrapped is unwrapped (a lossless round trip);
##   any other Rev 3 trailer is dropped.
## - Not representable (the record is skipped): more than 9999 channels in a
##   set, a negative start time, a sample interval that is not the base scan
##   interval / 2^k (k = 0..9), more than 99 skew blocks, more than 65535
##   extended or external blocks.
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
import ../common/[errors, diagnostics, endians, outputfile, years, progress, fieldlayout]
import ../io/[records, diskio]
import ../segd/[headers, samples, reader, writer, rev3, blocks]
import ../seg2/[reader as seg2reader]
import ../model/[traceindex, keys, headerfields]
import ../private/[progressticker, seg2conv]

type
  SegdTargetFormat* = enum
    ## The sample format `convertSegdRevision` writes: "keep", or a format
    ## code. The values' ordinals are not the format codes (they are 0, 1,
    ## 2, ...); use the names.
    tfKeep = "keep" ## Each record's own (8080 becomes 8058 before Rev 3, 90xx its 80xx twin
                    ## before Rev 3.1).
    tf8015 = "8015", tf8022 = "8022", tf8024 = "8024", tf8036 = "8036", tf8038 = "8038",
    tf8042 = "8042", tf8044 = "8044", tf8048 = "8048", tf8058 = "8058", tf8080 = "8080",
    tf9036 = "9036", tf9038 = "9038", tf9058 = "9058", tf9080 = "9080"

  SegdConvertOptions* = object
    ## Options of `convertSegdRevision`.
    revision*: SegdRevision = SegdRevision(major: 3, minor: 0)
      ## Target revision: 2.0, 2.1, 3.0 or 3.1.
    format*: SegdTargetFormat = tfKeep
      ## Target sample format; "keep" keeps each record's (8080 becomes 8058
      ## before Rev 3, a 90xx format its 80xx twin before Rev 3.1).
    twosComplement8015*: bool = false ## Decode 8015 as two's complement when re-encoding.

  SegdRecordScan* = object
    ## What a record's headers do not say exactly (see `scanSegdRecords`).
    setSamples*: seq[seq[int]]
      ## Samples per trace of each channel set, `[scan type][set]`: the
      ## longest trace (-1 when the set has no trace).
    rev2Trailer*: int
      ## Rev 3: blocks of a wrapped Rev 2 trailer (see the module doc), or -1.
    orphans*: int
      ## Traces naming a channel set no descriptor has (the record is skipped).

  SkipRecordError = object of CatchableError
    ## The record cannot be represented in the target revision.

  RevisionNote = enum
    ## Kinds of information a conversion drops or approximates; each is noted once.
    rnIntervalRounded     ## Rev 3 target: sample intervals rounded to whole µs.
    rnTrailerWrapped      ## Rev 3 target: the Rev 2 trailer carried as a user group.
    rnNoTimeZero          ## Rev 3 target: no GH#1 date, so relative time mode.
    rnTimeZeroFromGh1     ## Rev 3 target: GH#3 time zero from GH#1.
    rnExtensionsDropped   ## Rev 3 target: Rev 2 trace header extensions after #1.
    rnExtensionsOver15    ## Rev 2 target: trace header blocks after the 15th.
    rnRev3TrailerDropped  ## Rev 2 target: a Rev 3 general trailer.
    rnExt1FieldsDropped   ## Rev 2 target: THE#1 fields Rev 2 lacks.
    rnBlocksKeptRaw       ## Rev 2 target: Rev 3 trace header blocks kept as raw extensions.
    rnSourceFieldsDropped ## Rev 2 target: Source Description fields Rev 2 lacks.
    rnChannelTypeApprox   ## Rev 2 target: channel types without a Rev 2 code.
    rnTimesRounded        ## Rev 2 target: start/end times rounded to 2 ms.
    rnDescaleApprox       ## Rev 2 target: descale multipliers as MP factors.
    rnFiltersRounded      ## Rev 2 target: filter values rounded to BCD units.
    rnCsdFieldsDropped    ## Rev 2 target: CSD fields Rev 2 lacks.
    rnSourcesOver14       ## Rev 2 target: source headers after the 14th.
    rnGh3Dropped          ## Rev 2 target: General Header #3.
    rnRecordSetDropped    ## Rev 2.0 target: the record set (line sequence) number.
    rnRecordLengthRounded ## Rev 2 target: record lengths rounded to whole ms.
    rnCrsNotConverted     ## 3.1 to 3.0: the CRS text is not converted.
    rnCountsFromTimes     ## Rev 3 target without a scan: sample counts from the CSD times.
    rnUndefinedChannelType ## Rev 3 target: undefined Rev 2 channel types.
    rnRecordLengthClamped ## Rev 3 target: record lengths over 4294 s.
    rnRev0StackArray      ## Rev 0 source: vertical stack and array forming set to 1.

  Conv = object
    log: DiagLog
    seen: set[RevisionNote]
    droppedTypes: set[uint8]
    loc: Location
    opts: SegdConvertOptions
    inexact: int
    zeroed: int
    adjusted: int
    srcSize: int64 # bytes of the input file; -1 unknown (a stream)
    records, written: int # records read; records whose headers were written
    tk: ProgressTicker

const
  WrapDescription = "SEG-D REV2 TRLR " ## Trailer group holding a Rev 2 trailer.
  WrapType = 0xA0'u8

static:
  # `SegdTargetFormat` lists `segdSampleFormats` in order, after `tfKeep`.
  for i, f in segdSampleFormats: doAssert $SegdTargetFormat(i + 1) == $ord(f)

func sampleFormat(t: SegdTargetFormat): SegdSampleFormat =
  # The sample format of a target other than `tfKeep`.
  segdSampleFormats[ord(t) - 1]

func targetFormat*(f: SegdSampleFormat): SegdTargetFormat =
  ## The target format that writes `f`.
  for i, x in segdSampleFormats:
    if x == f: return SegdTargetFormat(i + 1)
  tfKeep # not reached: every format has a target

proc note(c: var Conv, kind: RevisionNote, msg: string) =
  if kind notin c.seen:
    c.seen.incl kind
    c.log.report(sevInfo, dcValidation, msg, loc = c.loc)

proc skipRecord(msg: string) {.noinline, noreturn.} =
  raise newException(SkipRecordError, msg)

func validTarget(r: SegdRevision): bool =
  (r.major == 2 and r.minor in {0'u8, 1}) or (r.major == 3 and r.minor in {0'u8, 1})

func definedIn(f: SegdSampleFormat, r: SegdRevision): bool =
  ## Whether format `f` exists in revision `r` (8080 from 3.0, 90xx from 3.1).
  if f.isLittleEndian: SegdRevision(major: 3, minor: 1) <= r
  elif f == sd8080: r.major >= 3
  else: true

func bcd(x: int): int {.inline.} = max(x, 0) # BcdAllF / BcdInvalid count as 0

func rev3ChannelType(t: uint8): uint8 =
  if t == 0xC: 0xA0'u8 elif t <= 9: t shl 4 else: 0x70'u8

func rev2ChannelType(t: uint8): tuple[code: uint8, exact: bool] =
  case t
  of 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90: (t shr 4, true)
  of 0xA0: (0xC'u8, true)
  of 0x21, 0x22: (0x2'u8, false) # clock / field time break
  of 0x61..0x63: (0x6'u8, false) # acoustic measurements: external data
  of 0x91: (0x8'u8, false)       # source signature, unfiltered
  of 0x92: (0x9'u8, false)       # source signature, filtered
  else: (0x7'u8, false)          # other

func outFormat(c: Conv, f: SegdSampleFormat): SegdSampleFormat =
  if c.opts.format != tfKeep: return c.opts.format.sampleFormat # checked up front
  result = f
  if not result.definedIn(c.opts.revision): result = bigEndianOf(result) # 90xx before 3.1
  if not result.definedIn(c.opts.revision): result = sd8058              # 8080 before 3.0

proc samplesFor(c: var Conv, src: openArray[byte], nIn, nOut: int,
    fIn, fOut: SegdSampleFormat): seq[byte] =
  ## The trace's samples in `fOut`, cut or zero-padded to `nOut` samples.
  result = newSeq[byte](dataBytes(fOut, nOut))
  if fIn == fOut and (fIn != sd8015 or nIn == nOut):
    let keep = min(dataBytes(fIn, min(nIn, nOut)), src.len)
    if keep > 0: copyMem(addr result[0], addr src[0], keep)
    return
  var v = newSeq[float64](nIn)
  decodeSamples(fIn, src, v, c.opts.twosComplement8015)
  v.setLen nOut
  # A resized 8015 trace keeps the input's convention, as the copied ones do.
  let twos = c.opts.twosComplement8015 and fIn == sd8015
  try:
    encodeSamples(fOut, v, result, twos)
  except SegFormatError:
    # A value out of the target's range: the trace is zeroed, and counted.
    for b in result.mitems: b = 0
    inc c.zeroed
    return
  var back = newSeq[float64](nOut)
  decodeSamples(fOut, result, back, twos)
  for i in 0..<nOut:
    if back[i] != v[i] and not (back[i].isNaN and v[i].isNaN):
      inc c.inexact
      return

# ------------------------------------------------------- Rev 1/2 to Rev 3 --

proc sourceFromGhn(g: SegdGeneralHeaderN): seq[byte] =
  let vib = g.phaseControl != 0 or g.vibratorType != 0 or g.phaseAngle != 0
  let s = SegdSourceDescription(extFileNumber: g.extFileNumber,
    sourceLineNumber: g.sourceLineNumber, sourcePointNumber: g.sourcePointNumber,
    sourcePointIndex: g.sourcePointIndex, sourceSetNumber: g.sourceSetNumber,
    blockType: (if vib: 0x15'u8 else: 0x1F'u8))
  result = @(s.encoded)
  if vib:
    result[14] = g.phaseControl
    result[15] = g.vibratorType
    putBeI16(result, 16, g.phaseAngle)

proc fromRev0(c: var Conv, d: var SegdChannelSetDescriptor) =
  ## Rev 0 descriptors leave bytes 27-32 at 0, where Rev 1+ define vertical
  ## stack (0 = intentionally zeroed data) and array forming (0 = undefined):
  ## write "no stack" and "no array forming" (1) instead.
  if d.verticalStack == 0 or d.arrayForming == 0:
    c.note(rnRev0StackArray, "Rev 0 channel sets have no vertical stack or array forming; " &
      "written as 1 (no stacking, no array forming)")
    if d.verticalStack == 0: d.verticalStack = 1
    if d.arrayForming == 0: d.arrayForming = 1

func timeSamples(d: SegdChannelSetDescriptor, g1: SegdGeneralHeader1): int =
  # Samples per trace from the descriptor's times: (end - start) / interval.
  let si = d.sampleIntervalMs(g1)
  if si > 0: max(0, int(round((d.endTimeMs - d.startTimeMs) / si))) else: 0

proc csdToRev3(c: var Conv, d: SegdChannelSetDescriptor, g1: SegdGeneralHeader1,
    samples: int): SegdChannelSetDescriptorRev3 =
  ## The Rev 3 descriptor of `d`, with `samples` samples per trace.
  let siUs = d.sampleIntervalMs(g1) * 1000.0
  if siUs != round(siUs):
    c.note(rnIntervalRounded, "a sample interval of " & $siUs &
      " µs is rounded to whole µs (Rev 3 CSD)")
  result = SegdChannelSetDescriptorRev3(scanTypeNumber: bcd(d.scanTypeNumber),
    channelSetNumber: uint16(max(0, headers.channelSetNumber(d))), # resolves FF + extended
    channelType: rev3ChannelType(d.channelType),
    startTime: int32(round(d.startTimeMs * 1000)), endTime: int32(round(d.endTimeMs * 1000)),
    numSamples: uint32(samples), descaleMultiplier: float32(pow(2.0, d.mpFactor)),
    channelsInSet: uint32(bcd(d.channelCount)), samplingInterval: uint32(round(siUs)),
    arrayForming: d.arrayForming, traceHeaderExtensions: 1,
    extendedHeaderFlag: d.extendedHeaderFlag, channelGainControl: d.gainControl,
    verticalStack: d.verticalStack, streamerNumber: d.streamerNumber,
    blockType1: BlockTypeChannelSet1,
    aliasFilterFreq: float32(bcd(d.aliasFilterFreq)),
    lowCutFilterFreq: float32(bcd(d.lowCutFreq)),
    aliasFilterSlope: float32(bcd(d.aliasFilterSlope)),
    lowCutFilterSlope: float32(bcd(d.lowCutSlope)),
    notch1Freq: float32(bcd(d.notch1Freq)) / 10, notch2Freq: float32(bcd(d.notch2Freq)) / 10,
    notch3Freq: float32(bcd(d.notch3Freq)) / 10, blockType2: BlockTypeChannelSet2,
    blockType3: BlockTypeChannelSet3)
  for i in 0..<result.description.len: result.description[i] = ' '
  if d.channelType notin {0'u8..9'u8, 0xC'u8}:
    c.note(rnUndefinedChannelType, "undefined Rev 2 channel types (0xA, 0xB, 0xD-0xF) are " &
      "written as 0x70 (other)")

proc toRev3(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat,
    scan: SegdRecordScan): SegdRecord =
  ## The Rev 3 record headers for Rev 1/2 `rec`. Each channel set's sample
  ## count (`numSamples`) is the scan's (from the traces) where it has one,
  ## else from the descriptor's times. The trailer is a placeholder of the
  ## right size (filled once the traces are read).
  result = SegdRecord(layout: slRev3, index: rec.index, format: some(fOut),
    revision: SegdRevision(major: 3, minor: c.opts.revision.minor))
  var g1 = rec.gh1
  g1.formatCode = ord(fOut)
  for g in rec.sourceHeaders: result.generalBlocks.add sourceFromGhn(g)
  let after = 2 + result.generalBlocks.len div SegdBlockSize # GH#2, GH#3, sources
  var g2 = SegdGeneralHeader2Rev3(revisionMajor: 3, revisionMinor: c.opts.revision.minor,
    blockType: BlockTypeGeneralHeader2)
  if after > 14:
    g1.additionalGhBlocks = 0xF
    g2.extAdditionalGhBlocks = uint16(after)
  else:
    g1.additionalGhBlocks = uint8(after)
  if rec.gh2.isSome:
    let o = rec.gh2.get
    g2.extFileNumber = o.extFileNumber
    g2.extChannelSetsPerScanType = o.extChannelSetsPerScanType
    g2.extExtendedHeaderBlocks = uint32(o.extExtendedHeaderBlocks)
    g2.extExternalHeaderBlocks = uint32(o.extExternalHeaderBlocks)
    let us = uint64(o.extRecordLength) * 1000 # ms to µs
    if us > uint64(high(uint32)):
      c.note(rnRecordLengthClamped, "record lengths over 4294 s do not fit Rev 3's µs field " &
        "and are clamped")
    g2.extRecordLength = uint32(min(us, uint64(high(uint32))))
    if SegdRevision(major: 2, minor: 1) <= rec.revision:
      g2.recordSetNumber = o.lineSequenceNumber
  # The trailer is read after the traces; GH#2 announces its size.
  let n2 = if rec.gh2.isSome: int(rec.gh2.get.generalTrailerBlocks) else: 0
  g2.generalTrailerBlocks = uint32(if n2 > 0: n2 + 1 else: 0)
  if n2 > 0:
    c.note(rnTrailerWrapped, "the Rev 2 general trailer is carried as one user trailer " &
      "group (0xA0, \"" & WrapDescription.strip & "\")")
  var g3 = SegdGeneralHeader3(blockType: BlockTypeGeneralHeader3)
  let utc = generalHeaderUtc(g1, fullYear(g1.year) - g1.year)
  if utc.isNaN:
    g3.relativeTimeMode = 1
    c.note(rnNoTimeZero, "General Header #1 has no valid date and time: GH#3 time zero is 0 " &
      "(relative time mode)")
  else:
    g3.timeZero = unixToTimestamp(utc)
    c.note(rnTimeZeroFromGh1, "GH#3 time zero comes from General Header #1 (whole seconds, UTC)")
  for i, st in rec.scanTypes:
    var s3 = SegdScanType(layout: slRev3, skew: st.skew)
    for k, d in st.descriptors:
      var d = d
      if rec.gh2.isNone: c.fromRev0(d)
      var ns = timeSamples(d, rec.gh1)
      if i < scan.setSamples.len and k < scan.setSamples[i].len and scan.setSamples[i][k] >= 0:
        ns = scan.setSamples[i][k]
      elif d.channelCount > 0:
        c.note(rnCountsFromTimes, "without a header scan, channel set sample counts come " &
          "from the descriptors' times ((end - start) / interval); traces that differ are " &
          "adjusted")
      s3.descriptorsRev3.add c.csdToRev3(d, rec.gh1, ns)
    result.scanTypes.add s3
  result.gh1 = g1
  result.gh2Rev3 = g2
  result.extended = rec.extended
  result.external = rec.external
  result.trailerRev3 = newSeq[byte](if n2 > 0: SegdBlockSize * (n2 + 1) else: 0)
  result.traceCount = result.announcedTraces
  # Sizes: every trace of a set has the set's sample count and THE#1 only.
  let header = result.headerBytes
  var data = header
  for st in result.scanTypes:
    for d in st.descriptorsRev3:
      data += int64(d.channelsInSet) * int64(traceBytes(d, dataBytes(fOut, int(d.numSamples))))
  g3.headerSize = uint32(header)
  g3.dataSize = uint64(data)
  g3.recordSize = uint64(data + result.trailerRev3.len)
  result.gh3 = g3

proc wrapTrailer(trailer: openArray[SegdTrailerBlock]): seq[byte] =
  if trailer.len == 0: return
  var d = SegdTrailerDescription(trailerBlockType: WrapType, asciiOrBinary: 1,
    blockSize: uint32(trailer.len), blockType: BlockTypeTrailerDescription)
  for i, ch in WrapDescription: d.description[i] = ch
  result = @(d.encoded)
  for b in trailer: result.add b.encoded

proc traceToRev3(c: var Conv, t: SegdTrace, fIn, fOut: SegdSampleFormat, ns: int): SegdTrace =
  result = SegdTrace(layout: slRev3, header: t.header, numSamples: ns, scanType: t.scanType,
    channelSet: t.channelSet, index: t.index)
  result.header.traceHeaderExtensions = 1
  var e = SegdTraceHeaderExt1Rev3(numSamples: uint32(ns), blockType: BlockTypeTraceHeaderExt1)
  if t.ext1.isSome:
    template o: untyped = t.ext1.get
    e.receiverLineNumber = o.receiverLineNumber
    e.receiverPointNumber = o.receiverPointNumber
    e.receiverPointIndex = o.receiverPointIndex
    e.extReceiverLineNumber = o.extReceiverLineNumber
    e.extReceiverPointNumber = o.extReceiverPointNumber
    e.sensorType = o.sensorType
  result.ext1Rev3 = some(e)
  if t.extensions.len > 0:
    c.note(rnExtensionsDropped, "trace header extensions after #1 are dropped (Rev 2 blocks " &
      "have no type byte, so Rev 3 readers would misread them)")
  if t.numSamples != ns: inc c.adjusted
  result.samples = c.samplesFor(t.samples, t.numSamples, ns, fIn, fOut)

# ------------------------------------------------------- Rev 3 to Rev 2 --

proc ghnFromSource(c: var Conv, b: openArray[byte], n: int): SegdGeneralHeaderN =
  let s = decodeBlock[SegdSourceDescription](b)
  result = SegdGeneralHeaderN(extFileNumber: s.extFileNumber,
    sourceLineNumber: s.sourceLineNumber, sourcePointNumber: s.sourcePointNumber,
    sourcePointIndex: s.sourcePointIndex, blockNumber: uint8(n),
    sourceSetNumber: s.sourceSetNumber)
  if s.blockType == 0x15:
    result.phaseControl = s.phaseControl
    result.vibratorType = s.vibratorType
    result.phaseAngle = s.phaseAngle
  if s.sourceId != 0 or s.reshootIndex != 0 or s.groupIndex != 0 or s.depthIndex != 0 or
      s.offsetCrossline != 0 or s.offsetInline != 0 or s.offsetDepth != 0 or
      (s.blockType != 0x15 and (s.depth != 0 or s.size != 0)):
    c.note(rnSourceFieldsDropped, "Source Description fields Rev 2 lacks (source id, " &
      "reshoot/group/depth index, offsets, type-specific values) are dropped")

proc toBcdUnits(c: var Conv, v: float32, scale: float64, digits: int): int =
  ## `v × scale` as a BCD field of `digits` digits (rounded and clamped, noted).
  let x = if v.isNaN: -1.0 else: round(float64(v) * scale) # NaN: noted, written as 0
  let top = float64(10 ^ digits - 1)
  if x != float64(v) * scale or x < 0 or x > top:
    c.note(rnFiltersRounded, "filter frequencies and slopes are rounded to Rev 2's BCD units")
  int(clamp(x, 0, top))

proc csdToRev2(c: var Conv, d: SegdChannelSetDescriptorRev3, bsiUs: float64,
    the: uint8): SegdChannelSetDescriptor =
  if d.channelsInSet > 9999:
    skipRecord("channel set " & $d.channelSetNumber & " has " & $d.channelsInSet &
      " channels; Rev 2 holds 9999")
  if d.numSamples > 0xFF_FFFF:
    skipRecord("channel set " & $d.channelSetNumber & " has " & $d.numSamples &
      " samples per trace; Rev 2 counts to 2^24 - 1")
  if d.startTime < 0 or d.endTime < 0:
    skipRecord("channel set " & $d.channelSetNumber & " starts or ends before time zero")
  let k = if d.samplingInterval > 0: log2(bsiUs / float64(d.samplingInterval)) else: -1.0
  if d.channelsInSet > 0 and (k != round(k) or k < 0 or k > 9):
    skipRecord("channel set " & $d.channelSetNumber & ": a sample interval of " &
      $d.samplingInterval & " µs is not the base scan interval (" & $bsiUs & " µs) / 2^k")
  let channelType = rev2ChannelType(d.channelType)
  result = SegdChannelSetDescriptor(scanTypeNumber: d.scanTypeNumber,
    channelCount: int(d.channelsInSet), channelType: channelType.code,
    subscanExponent: (if k >= 0 and k <= 9: int(k) else: 0),
    gainControl: d.channelGainControl, extendedHeaderFlag: d.extendedHeaderFlag,
    traceHeaderExtensions: the, verticalStack: d.verticalStack,
    streamerNumber: d.streamerNumber, arrayForming: d.arrayForming)
  if not channelType.exact:
    c.note(rnChannelTypeApprox, "Rev 3 channel types without a Rev 2 code are approximated " &
      "(time break, external data, signature or other)")
  if d.channelSetNumber <= 99:
    result.channelSetNumber = int(d.channelSetNumber)
  else:
    result.channelSetNumber = BcdAllF
    result.extChannelSetNumber = d.channelSetNumber
  let st = float64(d.startTime) / 2000
  let en = float64(d.endTime) / 2000
  if st != round(st) or en != round(en):
    c.note(rnTimesRounded, "start and end times are rounded to Rev 2's 2 ms units")
  if round(st) > 65535 or round(en) > 65535:
    skipRecord("channel set " & $d.channelSetNumber & " ends after 131 s, Rev 2's limit")
  result.startTime = uint16(round(st))
  result.endTime = uint16(round(en))
  let dsm = float64(d.descaleMultiplier)
  let exactMp = dsm > 0 and dsm.classify in {fcNormal, fcSubnormal}
  result.mpFactor = if exactMp: clamp(log2(dsm), -32.0, 31.99) else: 0
  if not exactMp or pow(2.0, result.mpFactor) != dsm:
    c.note(rnDescaleApprox, "descale multipliers are approximated by MP factors (2^MP, MP " &
      "in 1/1024)")
  result.aliasFilterFreq = c.toBcdUnits(d.aliasFilterFreq, 1, 4)
  result.aliasFilterSlope = c.toBcdUnits(d.aliasFilterSlope, 1, 3)
  result.lowCutFreq = c.toBcdUnits(d.lowCutFilterFreq, 1, 4)
  result.lowCutSlope = c.toBcdUnits(d.lowCutFilterSlope, 1, 3)
  result.notch1Freq = c.toBcdUnits(d.notch1Freq, 10, 4)
  result.notch2Freq = c.toBcdUnits(d.notch2Freq, 10, 4)
  result.notch3Freq = c.toBcdUnits(d.notch3Freq, 10, 4)
  if d.filterPhase != 0 or d.physicalUnit != 0 or d.filterDelay != 0 or
      d.descriptionText.len > 0:
    c.note(rnCsdFieldsDropped, "channel set fields Rev 2 lacks (filter phase and delay, " &
      "physical unit, description) are dropped")

proc unwrapTrailer(b: openArray[byte]): Option[seq[SegdTrailerBlock]] =
  ## The Rev 2 trailer blocks of a trailer `wrapTrailer` made; none for any
  ## other trailer.
  if b.len < SegdBlockSize or b[31] != BlockTypeTrailerDescription:
    return none(seq[SegdTrailerBlock])
  let d = decodeBlock[SegdTrailerDescription](b)
  var text = ""
  for ch in d.description: text.add ch
  if d.trailerBlockType != WrapType or text != WrapDescription or
      b.len != SegdBlockSize * (1 + int(d.blockSize)):
    return none(seq[SegdTrailerBlock])
  var blocks: seq[SegdTrailerBlock]
  for i in 1..int(d.blockSize):
    blocks.add decodeBlock[SegdTrailerBlock](b.toOpenArray(32 * i, 32 * i + 31))
  some(blocks)

proc toRev2(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat, minor: uint8,
    scan: SegdRecordScan): SegdRecord =
  ## The Rev 2 record headers for Rev 3 `rec`. Each descriptor's
  ## `traceHeaderExtensions` is what its traces keep (THE#1 plus up to 14).
  let g2o = rec.gh2Rev3
  result = SegdRecord(layout: slRev2, index: rec.index, format: some(fOut),
    revision: SegdRevision(major: 2, minor: minor))
  var g1 = rec.gh1
  g1.formatCode = ord(fOut)
  # Source Description blocks become GH#N; the rest is dropped.
  var srcBlocks: seq[int]
  for off, t in blocks(rec.generalBlocks):
    if t in {0x15'u8..0x19'u8, 0x1F'u8}: srcBlocks.add off
    elif t notin c.droppedTypes:
      c.droppedTypes.incl t
      c.log.report(sevInfo, dcValidation, "Rev 3 general header blocks of type 0x" &
        toHex(t, 2) & " (" & blockTypeName(t) & ") have no Rev 2 place and are dropped",
        loc = c.loc)
  if srcBlocks.len > 14:
    c.note(rnSourcesOver14, "Rev 2 holds 14 source headers (GH#3-#16); the rest are dropped")
    srcBlocks.setLen 14
  for i, off in srcBlocks:
    result.sourceHeaders.add c.ghnFromSource(rec.generalBlocks.toOpenArray(off, off + 31),
      i + 3)
  c.note(rnGh3Dropped, "General Header #3 (time zero, sizes, recording modes) has no Rev 2 " &
    "place and is dropped")
  g1.additionalGhBlocks = uint8(1 + result.sourceHeaders.len)
  var g2 = SegdGeneralHeader2(extFileNumber: g2o.extFileNumber,
    extChannelSetsPerScanType: g2o.extChannelSetsPerScanType, revisionMajor: 2,
    revisionMinor: minor, blockNumber: 2)
  if minor >= 1: g2.lineSequenceNumber = g2o.recordSetNumber
  elif g2o.recordSetNumber != 0:
    c.note(rnRecordSetDropped, "Rev 2.0 has no record set (line sequence) number; it is " &
      "dropped")
  # Counts behind FF sentinels.
  let nSK = rec.skewBlocks
  if nSK > 99: skipRecord($nSK & " skew blocks; Rev 2 holds 99")
  g1.skewBlocks = nSK
  let nEC = rec.extendedHeaderBlocks
  let nEX = rec.externalHeaderBlocks
  if nEC > 65535 or nEX > 65535:
    skipRecord("more than 65535 extended or external header blocks")
  # Kept even when GH#1 does not point at them (they round-trip that way).
  g2.extExtendedHeaderBlocks = uint16(if rec.gh1.extendedHeaderBlocks == BcdAllF: nEC
    else: int(min(g2o.extExtendedHeaderBlocks, 0xFFFF)))
  g2.extExternalHeaderBlocks = uint16(if rec.gh1.externalHeaderBlocks == BcdAllF: nEX
    else: int(min(g2o.extExternalHeaderBlocks, 0xFFFF)))
  g2.extRecordLength = uint32(round(float64(g2o.extRecordLength) / 1000))
  if g2o.extRecordLength mod 1000 != 0 and rec.gh1.recordLength == BcdAllF:
    c.note(rnRecordLengthRounded, "record lengths are rounded to Rev 2's whole ms")
  let bsiUs = rec.baseScanIntervalUs
  if rec.gh1.baseScanInterval16 == 0xFF:
    let b16 = bsiUs * 16 / 1000
    if b16 != round(b16) or b16 < 1 or b16 > 254:
      skipRecord("a base scan interval of " & $bsiUs & " µs is not a whole 1/16 ms (Rev 2)")
    g1.baseScanInterval16 = uint8(b16)
  for st in rec.scanTypes:
    var s2 = SegdScanType(layout: slRev2, skew: st.skew)
    for d in st.descriptorsRev3:
      if int(d.traceHeaderExtensions) > 15:
        c.note(rnExtensionsOver15, "Rev 2 holds 15 trace header extensions; later Rev 3 " &
          "blocks are dropped")
      s2.descriptors.add c.csdToRev2(d, bsiUs, min(d.traceHeaderExtensions, 15))
    result.scanTypes.add s2
  # The trailer is read after the traces: the scan says whether it unwraps.
  g2.generalTrailerBlocks = uint16(max(0, scan.rev2Trailer))
  result.gh1 = g1
  result.gh2 = some(g2)
  result.extended = rec.extended
  result.external = rec.external
  result.traceCount = result.announcedTraces

proc traceToRev2(c: var Conv, t: SegdTrace, fIn, fOut: SegdSampleFormat, the: uint8):
    SegdTrace =
  result = SegdTrace(layout: slRev2, header: t.header, numSamples: t.numSamples,
    scanType: t.scanType, channelSet: t.channelSet, index: t.index)
  if t.header.traceNumber == BcdAllF:
    let n = if t.ext1Rev3.isSome: int64(t.ext1Rev3.get.extTraceNumber) else: 0
    if n <= 9999:
      result.header.traceNumber = int(n)
    else:
      c.log.report(sevError, dcValidation, "trace number " & $n & " does not fit Rev 2's " &
        "four BCD digits; written as 9999", loc = Location(file: c.loc.file,
        record: c.loc.record, trace: t.index, field: "trace.traceNumber"))
      result.header.traceNumber = 9999
  if t.ext1Rev3.isSome and the > 0:
    template e: untyped = t.ext1Rev3.get
    if t.numSamples > 0xFF_FFFF:
      raiseFormat("a trace of " & $t.numSamples & " samples exceeds Rev 2's 24-bit count")
    result.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: e.receiverLineNumber,
      receiverPointNumber: e.receiverPointNumber, receiverPointIndex: e.receiverPointIndex,
      samplesPerTrace: uint32(t.numSamples), extReceiverLineNumber: e.extReceiverLineNumber,
      extReceiverPointNumber: e.extReceiverPointNumber, sensorType: e.sensorType)
    if e.reshootIndex != 0 or e.groupIndex != 0 or e.depthIndex != 0 or e.sensorMoving != 0 or
        e.physicalUnit != 0:
      c.note(rnExt1FieldsDropped, "Trace Header Extension #1 fields Rev 2 lacks (reshoot, " &
        "group and depth index, sensor moving, physical unit) are dropped")
    let keep = min(t.extensions.len div SegdBlockSize, int(the) - 1)
    result.extensions = t.extensions[0 ..< SegdBlockSize * keep]
    if keep > 0:
      c.note(rnBlocksKeptRaw, "Rev 3 trace header blocks after #1 are kept as raw Rev 2 " &
        "extensions")
  result.header.traceHeaderExtensions = uint8(ord(result.ext1.isSome) +
    result.extensions.len div SegdBlockSize)
  result.samples = c.samplesFor(t.samples, t.numSamples, t.numSamples, fIn, fOut)

# ----------------------------------------------------- within a layout --

proc withinRev3(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat): SegdRecord =
  ## 3.x to 3.y: the same layout, a new minor revision and maybe format.
  let target = c.opts.revision
  result = rec
  result.revision = target
  result.gh2Rev3.revisionMinor = target.minor
  # The trailer comes after the traces; a placeholder of the announced size
  # until then (see setRev3Trailer).
  let gt = rec.gh2Rev3.generalTrailerBlocks
  if gt != UnknownTrailerBlocks:
    # Bounded before the placeholder is allocated: a damaged count (up to
    # 2^32 blocks, 137 GB) must not cost memory (13.3 R4-2).
    let bytes = SegdBlockSize * int64(gt)
    let limit = if c.srcSize >= 0: c.srcSize else: DefaultMaxHeaderBytes
    if bytes > limit:
      skipRecord("General Header #2 announces " & $gt & " trailer blocks (" & $bytes &
        " bytes), more than the " & (if c.srcSize >= 0: "file holds" else: "reader holds"))
  result.trailerRev3 = newSeq[byte](if gt == UnknownTrailerBlocks: 0
                                    else: SegdBlockSize * int(gt))
  result.gh1.formatCode = ord(fOut)
  result.format = some(fOut)
  if rec.revision.minor > target.minor:
    c.note(rnCrsNotConverted, "Rev 3." & $rec.revision.minor & " records are written as 3." &
      $target.minor & " unchanged; their CRS text (P1/11 in 3.1) is not converted")
  if fOut != rec.format.get:
    # A new format: sizes from the descriptors (the trailer, read after the
    # traces, keeps the size GH#2 announces).
    var data = result.headerBytes
    for st in result.scanTypes:
      for d in st.descriptorsRev3:
        data += int64(d.channelsInSet) *
          int64(traceBytes(d, dataBytes(fOut, int(d.numSamples))))
    result.gh3.headerSize = uint32(result.headerBytes)
    result.gh3.dataSize = uint64(data)
    result.gh3.recordSize = if gt == UnknownTrailerBlocks or rec.gh3.recordSize == 0: 0'u64
                            else: uint64(data + SegdBlockSize * int64(gt))

proc withinRev2(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat): SegdRecord =
  ## Rev 0/1/2.x to 2.y: the same layout, a GH#2 for Rev 0, a new revision
  ## and maybe format.
  let target = c.opts.revision
  result = rec
  result.revision = target
  result.gh1.formatCode = ord(fOut)
  result.format = some(fOut)
  if rec.gh2.isNone:
    result.gh1.additionalGhBlocks = rec.gh1.additionalGhBlocks + 1
    result.gh2 = some(SegdGeneralHeader2(blockNumber: 2))
    # Rev 0: the multiplexed-only GH1 fields are "record as zero" in 2.x.
    result.gh1.unused20 = [0'u8, 0, 0]
    result.gh1.unused24L = 0
    result.gh1.unused25 = 0
    for st in result.scanTypes.mitems:
      for d in st.descriptors.mitems: c.fromRev0(d)
  template g2: untyped = result.gh2.get
  g2.revisionMajor = 2
  g2.revisionMinor = target.minor
  if target.minor >= 1 and rec.revision < SegdRevision(major: 2, minor: 1):
    g2.lineSequenceNumber = 0 # bytes 21-22 are undefined before 2.1
  if target.minor == 0 and g2.lineSequenceNumber != 0:
    c.note(rnRecordSetDropped, "Rev 2.0 has no record set (line sequence) number; it is " &
      "dropped")
    g2.lineSequenceNumber = 0

# ------------------------------------------------------------ the stream --

func inputSize(src: RecordSource): int64 =
  if src of DiskSource: DiskSource(src).size else: -1

proc scanSegdRecords*(src: RecordSource, twosComplement8015 = false,
    progress: Progress = nil): seq[SegdRecordScan] =
  ## A headers-only pass over every record. A record's headers are written
  ## before its traces and trailer are read, but some header values depend on
  ## them: Rev 2 descriptors do not hold sample counts exactly (real data
  ## counts both end points), and a wrapped Rev 2 trailer sets the Rev 2
  ## trailer block count. Raises `SegCancelledError` when `progress`
  ## (called about every MiB, see `Progress`) returns false.
  var r = openSegd(src, twosComplement8015, headersOnly = true)
  var tk = initProgressTicker(progress, inputSize(src))
  while r.nextRecord():
    var rs = SegdRecordScan(rev2Trailer: -1)
    for st in r.record.scanTypes:
      rs.setSamples.add newSeq[int](st.channelSetCount)
      for x in rs.setSamples[^1].mitems: x = -1
    var t: SegdTrace
    while r.readTrace(t):
      if not tk.tick(t.offset): raiseCancelled()
      if t.scanType >= 0 and t.channelSet >= 0:
        rs.setSamples[t.scanType][t.channelSet] =
          max(rs.setSamples[t.scanType][t.channelSet], t.numSamples)
      else:
        inc rs.orphans
    if r.record.isRev3:
      let blocks = unwrapTrailer(r.record.trailerRev3)
      if blocks.isSome: rs.rev2Trailer = blocks.get.len
    result.add rs
  if not tk.finish(): raiseCancelled()

proc convertHeaders(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat,
    scan: SegdRecordScan): SegdRecord =
  ## The record's headers in the target revision. Raises `SkipRecordError`
  ## when they cannot be represented there.
  if scan.orphans > 0:
    skipRecord($scan.orphans & " traces name a channel set no descriptor has")
  let target = c.opts.revision
  if target.major == 3 and not rec.isRev3: c.toRev3(rec, fOut, scan)
  elif target.major == 2 and rec.isRev3: c.toRev2(rec, fOut, target.minor, scan)
  elif rec.isRev3: c.withinRev3(rec, fOut)
  else: c.withinRev2(rec, fOut)

proc convertRecord(c: var Conv, r: var SegdReader, w: var SegdWriter, scan: SegdRecordScan) =
  ## Converts the reader's current record: its headers, its traces as they
  ## are read, then its trailer. A record the target cannot represent is
  ## skipped with an error.
  let rec = r.record
  c.loc.record = rec.index
  inc c.records
  if rec.format.isNone:
    c.log.report(sevError, dcUnsupportedFormat, "record " & $rec.index & ": SEG-D " &
      "format " & $rec.gh1.formatCode & " cannot be decoded; the record is skipped",
      rec.offset, c.loc)
    return
  let fIn = rec.format.get
  let fOut = c.outFormat(fIn)
  var outRec: SegdRecord
  try:
    outRec = c.convertHeaders(rec, fOut, scan)
  except SkipRecordError as e:
    c.log.report(sevError, dcValidation, "record " & $rec.index & " cannot be written " &
      "as Rev " & $c.opts.revision & ": " & e.msg & "; it is skipped", rec.offset, c.loc)
    return
  w.writeRecordHeaders(outRec)
  inc c.written
  var t: SegdTrace
  while r.readTrace(t):
    if not c.tk.tick(t.offset): raiseCancelled()
    if t.scanType < 0 or t.channelSet < 0:
      raiseFormat("trace " & $t.index & " names a channel set no descriptor has " &
        "(convert the file by path: its header scan skips such records)")
    template outSet: untyped = outRec.scanTypes[t.scanType]
    if outRec.layout == rec.layout:
      if fIn != fOut:
        var samples = c.samplesFor(t.samples, t.numSamples, t.numSamples, fIn, fOut)
        swap(t.samples, samples)
      w.writeTrace(t)
    elif outRec.isRev3:
      let ns = int(outSet.descriptorsRev3[t.channelSet].numSamples)
      w.writeTrace(c.traceToRev3(t, fIn, fOut, ns))
    else:
      let the = outSet.descriptors[t.channelSet].traceHeaderExtensions
      w.writeTrace(c.traceToRev2(t, fIn, fOut, the))
  # The trailer is read after the traces.
  case outRec.layout
  of slRev3:
    w.setRev3Trailer(if rec.isRev3: r.record.trailerRev3 else: wrapTrailer(r.record.trailer))
    w.endRecord()
  of slRev2:
    if not rec.isRev3:
      w.endRecord(r.record.trailer)
    else:
      template tb: untyped = r.record.trailerRev3
      let blocks = unwrapTrailer(tb)
      if tb.len > 0 and (blocks.isNone or blocks.get.len != scan.rev2Trailer):
        c.note(rnRev3TrailerDropped, "Rev 3 general trailers (description-block groups) " &
          "have no Rev 2 place and are dropped")
        w.endRecord()
      else:
        w.endRecord(blocks.get(@[]))

proc convertStream(src: RecordSource, sink: RecordSink, opts: SegdConvertOptions,
    scan: seq[SegdRecordScan], srcSize: int64, progress: Progress): DiagLog

proc convertSegdRevision*(src: RecordSource, sink: RecordSink,
    opts = SegdConvertOptions(), scan: seq[SegdRecordScan] = @[],
    progress: Progress = nil): DiagLog =
  ## Converts the SEG-D stream at `src` to revision `opts.revision` on
  ## `sink` (see the module doc). `scan`, from `scanSegdRecords` over the
  ## same data (`convertSegdRevision(path, ...)` makes one), gives Rev 1/2 to
  ## Rev 3 each channel set's exact sample count and Rev 3 to Rev 2 the
  ## unwrapped trailer size. Without it the descriptors' times decide, traces
  ## that differ are adjusted (with a warning), and Rev 3 trailers are
  ## dropped. The reader's, the writer's and the conversion's diagnostics are
  ## all in the result; a fatal one means the output is incomplete.
  ## `progress` is called about every MiB of input (see `Progress`); when it
  ## returns false the conversion stops with a fatal `dcCancelled`
  ## diagnostic.
  convertStream(src, sink, opts, scan, -1, progress)

proc convertStream(src: RecordSource, sink: RecordSink, opts: SegdConvertOptions,
    scan: seq[SegdRecordScan], srcSize: int64, progress: Progress): DiagLog =
  # `convertSegdRevision`; `srcSize` (-1: unknown) bounds what damaged
  # headers may make it allocate.
  var c = Conv(opts: opts, loc: Location(file: sink.name), srcSize: srcSize,
    tk: initProgressTicker(progress, inputSize(src)))
  let target = opts.revision
  if not validTarget(target):
    c.log.report(sevFatal, dcValidation, "target SEG-D revision " & $target &
      " is not 2.0, 2.1, 3.0 or 3.1", loc = c.loc)
    return c.log
  if opts.format != tfKeep and not opts.format.sampleFormat.definedIn(target):
    c.log.report(sevFatal, dcValidation, "SEG-D format " & $opts.format &
      " is not defined in Rev " & $target, loc = c.loc)
    return c.log
  var r = openSegd(src, opts.twosComplement8015)
  var w: SegdWriter
  try:
    var label = r.label
    if label.isSome: label.get.revision = "SD" & $target
    w = openSegdWriter(sink, SegdWriteOptions(), label)
    while r.nextRecord():
      let rs = if r.record.index < scan.len: scan[r.record.index]
               else: SegdRecordScan(rev2Trailer: -1)
      c.convertRecord(r, w, rs)
    if not c.tk.finish(): raiseCancelled()
    w.close()
  except SegCancelledError:
    c.log.reportCancelled(sink.name)
  except CatchableError as e:
    c.log.report(sevFatal, dcValidation, "conversion stopped: " & e.msg, loc = c.loc)
  if c.records > 0 and c.written == 0 and not c.log.isFatal:
    # Every record was skipped: an empty output is no conversion (13.3 R1-4).
    c.log.report(sevFatal, dcValidation, "none of the " & $c.records & " records can be " &
      "written as Rev " & $target & "; nothing was converted", loc = c.loc)
  if c.adjusted > 0:
    c.log.report(sevWarning, dcValidation, $c.adjusted & " traces were cut or zero-padded " &
      "to their channel set's sample count (Rev 3 requires one count per set)", loc = c.loc)
  if c.zeroed > 0:
    c.log.report(sevError, dcValidation, $c.zeroed & " traces hold values the target " &
      "format cannot represent and were written as zeros", loc = c.loc)
  if c.inexact > 0:
    c.log.report(sevWarning, dcValidation, $c.inexact & " traces could not be re-encoded " &
      "exactly in the target format", loc = c.loc)
  result = r.log
  for d in c.log: result.add d
  for d in w.log: result.add d

proc convertSegdRevision*(srcPath, dstPath: string, opts = SegdConvertOptions(),
    progress: Progress = nil): DiagLog {.raises: [].} =
  ## Converts the SEG-D disk file `srcPath` to `dstPath` (see the stream
  ## version). Never raises: problems, including I/O failures, are in the
  ## result. The output is written to a new temporary file next to
  ## `dstPath` and renamed when complete. `progress` spans the header scan
  ## and the conversion (see `convertFile`); when it cancels, the result
  ## holds a fatal `dcCancelled` diagnostic and nothing is written.
  if sameAsInput(srcPath, dstPath, result) or isDirectory(dstPath, result):
    return
  let tmp = createTempFor(dstPath, result)
  if tmp.len == 0: return
  var src: RecordSource
  var sink: RecordSink
  try:
    src = openDiskSource(srcPath)
    let scan = scanSegdRecords(src, opts.twosComplement8015, progressPhase(progress, 0, 2))
    src.close()
    src = nil
    src = openDiskSource(srcPath)
    sink = openDiskSink(tmp)
    result = convertStream(src, sink, opts, scan, getFileSize(srcPath),
      progressPhase(progress, 1, 2))
  except SegCancelledError:
    result.reportCancelled(dstPath)
  except CatchableError as e:
    result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
  finally:
    # A failed close of the output (its last flush) loses data: fatal.
    try:
      if src != nil: src.close()
    except CatchableError as e:
      result.report(sevWarning, dcIo, e.msg, loc = Location(file: srcPath))
    try:
      if sink != nil: sink.close()
    except CatchableError as e:
      result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
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

func segdFormatFor(formats: set[Seg2SampleFormat], rev3: bool): SegdSampleFormat =
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

proc writeSeg2AsSegd(c: var Seg2Conv, f: SeismicFile, sink: RecordSink, opts: SegdConvertOptions) =
  let fdb = f.index.seg2
  let rev3Minor = if opts.revision.major == 3: opts.revision.minor else: 0'u8
  # The traces that can be converted, and their channel sets.
  var outs: seq[OutTrace]
  var sets: seq[SetKey]
  var counts: seq[int]
  var formats: set[Seg2SampleFormat]
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
    f.decodeFloat64(o.index, vals)
    vals.setLen s.ns
    t.samples = newSeq[byte](dataBytes(fmt, s.ns))
    try:
      encodeSamples(fmt, vals, t.samples)
      back.setLen s.ns
      decodeSamples(fmt, t.samples, back)
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
  var c = Seg2Conv(loc: Location(file: dstPath))
  if sameAsInput(srcPath, dstPath, result) or isDirectory(dstPath, result): return
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
