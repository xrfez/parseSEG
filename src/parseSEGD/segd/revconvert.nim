## SEG-D revision conversion (task 8.7): Rev 1 / 2.x to Rev 3.0, Rev 3.x to
## Rev 2.0 / 2.1, and within a layout (2.x to 2.y, 3.x to 3.0, format
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

import std/[math, os, strutils]
import ../common/[errors, diagnostics, endians]
import ../io/[records, diskio]
import ./[headers, samples, reader, writer, rev3]

type
  SegdConvertOptions* = object
    revision*: SegdRevision = SegdRevision(major: 3, minor: 0)
      ## Target revision: 2.0, 2.1 or 3.0.
    format*: int = 0
      ## Target sample format code; 0 keeps each record's (8080 becomes 8058
      ## for Rev 2).
    twosComplement8015*: bool = false ## Decode 8015 as two's complement when re-encoding.

  RecordScan* = object
    ## What a record's headers do not say exactly (see `scanRecords`).
    setSamples*: seq[seq[int]]
      ## Samples per trace of each channel set, `[scan type][set]`: the
      ## longest trace (-1 when the set has no trace).
    rev2Trailer*: int
      ## Rev 3: blocks of a wrapped Rev 2 trailer (see the module doc), or -1.

  SkipRecord = object of CatchableError
    ## The record cannot be represented in the target revision.

  Conv = object
    log: DiagLog
    seen: set[0..63]
    droppedTypes: set[uint8]
    loc: Location
    opts: SegdConvertOptions
    inexact: int
    adjusted: int

const
  WrapDescription = "SEG-D REV2 TRLR " ## Trailer group holding a Rev 2 trailer.
  WrapType = 0xA0'u8

proc note(c: var Conv, id: int, msg: string) =
  if id notin c.seen:
    c.seen.incl id
    c.log.report(sevInfo, dcValidation, msg, loc = c.loc)

proc skipRecord(msg: string) {.noinline, noreturn.} =
  raise newException(SkipRecord, msg)

func validTarget(r: SegdRevision): bool =
  (r.major == 2 and r.minor in {0'u8, 1}) or (r.major == 3 and r.minor == 0)

func bcd(x: int): int {.inline.} = max(x, 0) # BcdAllF / BcdInvalid count as 0

func rev3ChannelType(t: uint8): uint8 =
  if t == 0xC: 0xA0'u8 elif t <= 9: t shl 4 else: 0x70'u8

func rev2ChannelType(t: uint8, exact: var bool): uint8 =
  exact = true
  case t
  of 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90: t shr 4
  of 0xA0: 0xC'u8
  else:
    exact = false
    case t
    of 0x21, 0x22: 0x2'u8      # clock / field time break
    of 0x61..0x63: 0x6'u8      # acoustic measurements: external data
    of 0x91: 0x8'u8            # source signature, unfiltered
    of 0x92: 0x9'u8            # source signature, filtered
    else: 0x7'u8               # other

proc outFormat(c: var Conv, f: SegdSampleFormat): SegdSampleFormat =
  if c.opts.format != 0: discard toSegdFormat(c.opts.format, result) # checked up front
  elif f == sd8080 and c.opts.revision.major < 3: result = sd8058
  else: result = f

proc samplesFor(c: var Conv, src: seq[byte], nIn, nOut: int, fIn, fOut: SegdSampleFormat):
    seq[byte] =
  ## The trace's samples in `fOut`, cut or zero-padded to `nOut` samples.
  if fIn == fOut and (fIn != sd8015 or nOut mod 4 == 0):
    let keep = min(dataBytes(fIn, min(nIn, nOut)), src.len)
    result = newSeq[byte](dataBytes(fOut, nOut))
    if keep > 0: copyMem(addr result[0], unsafeAddr src[0], keep)
  else:
    var v = newSeq[float64](nIn)
    decodeSegdSamples(fIn, src, v, c.opts.twosComplement8015)
    v.setLen nOut
    result = newSeq[byte](dataBytes(fOut, nOut))
    try:
      encodeSegdSamples(fOut, v, result)
    except SegFormatError:
      # A value out of the target's range: the trace is zeroed, and counted.
      for b in result.mitems: b = 0
      inc c.inexact
      return
    var back = newSeq[float64](nOut)
    decodeSegdSamples(fOut, result, back)
    for i in 0..<nOut:
      if back[i] != v[i] and not (back[i].isNaN and v[i].isNaN):
        inc c.inexact
        break

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

proc csdToRev3(c: var Conv, d: SegdChannelSetDescriptor, g1: SegdGeneralHeader1,
    ns: var int): SegdChannelSetDescriptor3 =
  let si = d.sampleIntervalMs(g1)
  let siUs = si * 1000.0
  if siUs != round(siUs):
    c.note(1, "a sample interval of " & $siUs & " µs is rounded to whole µs (Rev 3 CSD)")
  ns = if si > 0: int(round((d.endTimeMs - d.startTimeMs) / si)) else: 0
  result = SegdChannelSetDescriptor3(scanTypeNumber: bcd(d.scanTypeNumber),
    channelSetNumber: uint16(max(0, d.channelSetNumber)),
    channelType: rev3ChannelType(d.channelType),
    startTime: int32(round(d.startTimeMs * 1000)), endTime: int32(round(d.endTimeMs * 1000)),
    numSamples: uint32(max(0, ns)), descaleMultiplier: float32(pow(2.0, d.mpFactor)),
    channelsInSet: uint32(bcd(d.channelCount)), samplingInterval: uint32(round(siUs)),
    arrayForming: d.arrayForming, traceHeaderExtensions: 1,
    extendedHeaderFlag: d.extendedHeaderFlag, channelGainControl: d.gainControl,
    verticalStack: d.verticalStack, streamerNumber: d.streamerNumber, blockType1: BtCsd1,
    aliasFilterFreq: float32(bcd(d.aliasFilterFreq)),
    lowCutFilterFreq: float32(bcd(d.lowCutFreq)),
    aliasFilterSlope: float32(bcd(d.aliasFilterSlope)),
    lowCutFilterSlope: float32(bcd(d.lowCutSlope)),
    notch1Freq: float32(bcd(d.notch1Freq)) / 10, notch2Freq: float32(bcd(d.notch2Freq)) / 10,
    notch3Freq: float32(bcd(d.notch3Freq)) / 10, blockType2: BtCsd2, blockType3: BtCsd3)
  for i in 0..<result.description.len: result.description[i] = ' '

proc toRev3(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat, scan: RecordScan,
    setSamples: var seq[seq[int]]): SegdRecord =
  ## The Rev 3 record headers for Rev 1/2 `rec`; `setSamples[st][cs]` gets
  ## each channel set's sample count: `known` (from the traces) where it has
  ## one, else from the descriptor. The trailer is a placeholder of the right
  ## size (filled once the traces are read).
  result = SegdRecord(index: rec.index, isRev3: true, hasGh2: true, format: fOut,
    formatKnown: true, revision: SegdRevision(major: 3, minor: 0))
  var g1 = rec.gh1
  g1.formatCode = ord(fOut)
  for g in rec.sourceHeaders: result.generalBlocks.add sourceFromGhn(g)
  let after = 2 + result.generalBlocks.len div 32 # GH#2, GH#3, sources
  var g2 = SegdGeneralHeader2Rev3(revisionMajor: 3, revisionMinor: 0, blockType: BtGeneralHeader2)
  if after > 14:
    g1.additionalGhBlocks = 0xF
    g2.extAdditionalGhBlocks = uint16(after)
  else:
    g1.additionalGhBlocks = uint8(after)
  if rec.hasGh2:
    let o = rec.gh2
    g2.extFileNumber = o.extFileNumber
    g2.extChannelSetsPerScanType = o.extChannelSetsPerScanType
    g2.extExtendedHeaderBlocks = uint32(o.extExtendedHeaderBlocks)
    g2.extExternalHeaderBlocks = uint32(o.extExternalHeaderBlocks)
    g2.extRecordLength = o.extRecordLength * 1000 # ms to µs
    if rec.revision.major == 2 and rec.revision.minor >= 1:
      g2.recordSetNumber = o.lineSequenceNumber
  # The trailer is read after the traces; GH#2 announces its size.
  let n2 = if rec.hasGh2: int(rec.gh2.generalTrailerBlocks) else: 0
  g2.generalTrailerBlocks = uint32(if n2 > 0: n2 + 1 else: 0)
  if n2 > 0: c.note(2, "the Rev 2 general trailer is carried as one user trailer group " &
    "(0xA0, \"" & WrapDescription.strip & "\")")
  var g3 = SegdGeneralHeader3(blockType: BtGeneralHeader3)
  let utc = generalHeaderUtc(g1, if g1.year < 80: 2000 else: 1900)
  if utc.isNaN:
    g3.relativeTimeMode = 1
    c.note(3, "General Header #1 has no valid date and time: GH#3 time zero is 0 " &
      "(relative time mode)")
  else:
    g3.timeZero = unixToTimestamp(utc)
    c.note(4, "GH#3 time zero comes from General Header #1 (whole seconds, UTC)")
  setSamples.setLen rec.scanTypes.len
  for i, st in rec.scanTypes:
    var s3 = SegdScanType(skew: st.skew)
    for k, d in st.descriptors:
      var ns: int
      var d3 = c.csdToRev3(d, rec.gh1, ns)
      if i < scan.setSamples.len and k < scan.setSamples[i].len and
          scan.setSamples[i][k] >= 0:
        ns = scan.setSamples[i][k]
        d3.numSamples = uint32(ns)
      elif d.channelCount > 0:
        c.note(31, "without a header scan, channel set sample counts come from the " &
          "descriptors' times ((end - start) / interval); traces that differ are adjusted")
      s3.descriptors3.add d3
      setSamples[i].add ns
    result.scanTypes.add s3
  result.gh1 = g1
  result.gh2r3 = g2
  result.extended = rec.extended
  result.external = rec.external
  result.trailerBytes = newSeq[byte](if n2 > 0: 32 * (n2 + 1) else: 0)
  # Sizes: every trace of a set has the set's sample count and THE#1 only.
  let header = rev3HeaderBytes(result)
  var data = header
  for i, st in result.scanTypes:
    for k, d in st.descriptors3:
      result.traceCount += int(d.channelsInSet)
      data += int64(d.channelsInSet) *
        int64(SegdTraceHeaderSize + SegdBlockSize + dataBytes(fOut, setSamples[i][k]))
  g3.headerSize = uint32(header)
  g3.dataSize = uint64(data)
  g3.recordSize = uint64(data + result.trailerBytes.len)
  result.gh3 = g3

proc wrapTrailer(trailer: openArray[SegdTrailerBlock]): seq[byte] =
  if trailer.len == 0: return
  var d = SegdTrailerDescription(trailerBlockType: WrapType, asciiOrBinary: 1,
    blockSize: uint32(trailer.len), blockType: BtTrailerDescription)
  for i, ch in WrapDescription: d.description[i] = ch
  result = @(d.encoded)
  for b in trailer: result.add b.encoded

proc traceToRev3(c: var Conv, t: SegdTrace, fIn, fOut: SegdSampleFormat, ns: int): SegdTrace =
  result = SegdTrace(header: t.header, hasExt1: true, numSamples: ns, scanType: t.scanType,
    channelSet: t.channelSet, index: t.index)
  result.header.traceHeaderExtensions = 1
  var e = SegdTraceHeaderExt1Rev3(numSamples: uint32(ns), blockType: BtTraceExt1)
  if t.hasExt1:
    e.receiverLineNumber = t.ext1.receiverLineNumber
    e.receiverPointNumber = t.ext1.receiverPointNumber
    e.receiverPointIndex = t.ext1.receiverPointIndex
    e.extReceiverLineNumber = t.ext1.extReceiverLineNumber
    e.extReceiverPointNumber = t.ext1.extReceiverPointNumber
    e.sensorType = t.ext1.sensorType
  result.ext1r3 = e
  if t.extensions.len > 0:
    c.note(5, "trace header extensions after #1 are dropped (Rev 2 blocks have no type " &
      "byte, so Rev 3 readers would misread them)")
  if t.numSamples != ns: inc c.adjusted
  result.samples = c.samplesFor(t.samples, t.numSamples, ns, fIn, fOut)

# ------------------------------------------------------- Rev 3 to Rev 2 --

proc ghnFromSource(c: var Conv, b: openArray[byte], n: int): SegdGeneralHeaderN =
  let s = decodeRev3[SegdSourceDescription](b)
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
    c.note(10, "Source Description fields Rev 2 lacks (source id, reshoot/group/depth " &
      "index, offsets, type-specific values) are dropped")

proc toBcdUnits(c: var Conv, v: float32, scale: float64, digits: int): int =
  ## `v × scale` as a BCD field of `digits` digits (rounded and clamped, noted).
  let x = round(float64(v) * scale)
  let top = float64(10 ^ digits - 1)
  if x != float64(v) * scale or x < 0 or x > top:
    c.note(14, "filter frequencies and slopes are rounded to Rev 2's BCD units")
  int(clamp(x, 0, top))

proc csdToRev2(c: var Conv, d: SegdChannelSetDescriptor3, bsiUs: float64,
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
  var exact = true
  result = SegdChannelSetDescriptor(scanTypeNumber: d.scanTypeNumber,
    channelCount: int(d.channelsInSet),
    channelType: rev2ChannelType(d.channelType, exact),
    subscanExponent: (if k >= 0 and k <= 9: int(k) else: 0),
    gainControl: d.channelGainControl, extendedHeaderFlag: d.extendedHeaderFlag,
    traceHeaderExtensions: the, verticalStack: d.verticalStack,
    streamerNumber: d.streamerNumber, arrayForming: d.arrayForming)
  if not exact:
    c.note(11, "Rev 3 channel types without a Rev 2 code are approximated (time break, " &
      "external data, signature or other)")
  if d.channelSetNumber <= 99:
    result.channelSetNumber = int(d.channelSetNumber)
  else:
    result.channelSetNumber = BcdAllF
    result.extChannelSetNumber = d.channelSetNumber
  let st = float64(d.startTime) / 2000
  let en = float64(d.endTime) / 2000
  if st != round(st) or en != round(en):
    c.note(12, "start and end times are rounded to Rev 2's 2 ms units")
  if round(st) > 65535 or round(en) > 65535:
    skipRecord("channel set " & $d.channelSetNumber & " ends after 131 s, Rev 2's limit")
  result.startTime = uint16(round(st))
  result.endTime = uint16(round(en))
  let dsm = float64(d.descaleMultiplier)
  if dsm > 0 and dsm.classify in {fcNormal, fcSubnormal}:
    result.mpFactor = clamp(log2(dsm), -32.0, 31.99)
    if pow(2.0, result.mpFactor) != dsm:
      c.note(13, "descale multipliers are approximated by MP factors (2^MP, MP in 1/1024)")
  else:
    result.mpFactor = 0
    c.note(13, "descale multipliers are approximated by MP factors (2^MP, MP in 1/1024)")
  result.aliasFilterFreq = c.toBcdUnits(d.aliasFilterFreq, 1, 4)
  result.aliasFilterSlope = c.toBcdUnits(d.aliasFilterSlope, 1, 3)
  result.lowCutFreq = c.toBcdUnits(d.lowCutFilterFreq, 1, 4)
  result.lowCutSlope = c.toBcdUnits(d.lowCutFilterSlope, 1, 3)
  result.notch1Freq = c.toBcdUnits(d.notch1Freq, 10, 4)
  result.notch2Freq = c.toBcdUnits(d.notch2Freq, 10, 4)
  result.notch3Freq = c.toBcdUnits(d.notch3Freq, 10, 4)
  if d.filterPhase != 0 or d.physicalUnit != 0 or d.filterDelay != 0 or
      d.descriptionText.strip.len > 0:
    c.note(15, "channel set fields Rev 2 lacks (filter phase and delay, physical unit, " &
      "description) are dropped")

proc unwrapTrailer(b: openArray[byte], blocks: var seq[SegdTrailerBlock]): bool =
  ## The Rev 2 trailer blocks of a trailer `wrapTrailer` made.
  if b.len < 32 or b[31] != BtTrailerDescription: return false
  let d = decodeRev3[SegdTrailerDescription](b)
  var text = ""
  for ch in d.description: text.add ch
  if d.trailerBlockType != WrapType or text != WrapDescription or
      b.len != 32 * (1 + int(d.blockSize)):
    return false
  for i in 1..int(d.blockSize):
    blocks.add decodeBlock[SegdTrailerBlock](b.toOpenArray(32 * i, 32 * i + 31))
  true

proc toRev2(c: var Conv, rec: SegdRecord, fOut: SegdSampleFormat, minor: uint8,
    scan: RecordScan, the: var seq[seq[uint8]]): SegdRecord =
  let g2o = rec.gh2r3
  result = SegdRecord(index: rec.index, hasGh2: true, format: fOut, formatKnown: true,
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
    c.note(16, "Rev 2 holds 14 source headers (GH#3-#16); the rest are dropped")
    srcBlocks.setLen 14
  for i, off in srcBlocks:
    result.sourceHeaders.add c.ghnFromSource(rec.generalBlocks.toOpenArray(off, off + 31),
      i + 3)
  c.note(17, "General Header #3 (time zero, sizes, recording modes) has no Rev 2 place " &
    "and is dropped")
  g1.additionalGhBlocks = uint8(1 + result.sourceHeaders.len)
  var g2 = SegdGeneralHeader2(extFileNumber: g2o.extFileNumber,
    extChannelSetsPerScanType: g2o.extChannelSetsPerScanType, revisionMajor: 2,
    revisionMinor: minor, blockNumber: 2)
  if minor >= 1: g2.lineSequenceNumber = g2o.recordSetNumber
  elif g2o.recordSetNumber != 0:
    c.note(18, "Rev 2.0 has no record set (line sequence) number; it is dropped")
  # Counts behind FF sentinels.
  let nSK = skewBlocks(rec.gh1, g2o)
  if nSK > 99: skipRecord($nSK & " skew blocks; Rev 2 holds 99")
  g1.skewBlocks = nSK
  let nEC = extendedHeaderBlocks(rec.gh1, g2o)
  let nEX = externalHeaderBlocks(rec.gh1, g2o)
  if nEC > 65535 or nEX > 65535:
    skipRecord("more than 65535 extended or external header blocks")
  # Kept even when GH#1 does not point at them (they round-trip that way).
  g2.extExtendedHeaderBlocks = uint16(if rec.gh1.extendedHeaderBlocks == BcdAllF: nEC
    else: int(min(g2o.extExtendedHeaderBlocks, 0xFFFF)))
  g2.extExternalHeaderBlocks = uint16(if rec.gh1.externalHeaderBlocks == BcdAllF: nEX
    else: int(min(g2o.extExternalHeaderBlocks, 0xFFFF)))
  g2.extRecordLength = uint32(round(float64(g2o.extRecordLength) / 1000))
  if g2o.extRecordLength mod 1000 != 0 and rec.gh1.recordLength == BcdAllF:
    c.note(19, "record lengths are rounded to Rev 2's whole ms")
  let bsiUs = baseScanIntervalUs(rec.gh1, g2o)
  if rec.gh1.baseScanInterval16 == 0xFF:
    let b16 = bsiUs * 16 / 1000
    if b16 != round(b16) or b16 < 1 or b16 > 254:
      skipRecord("a base scan interval of " & $bsiUs & " µs is not a whole 1/16 ms (Rev 2)")
    g1.baseScanInterval16 = uint8(b16)
  # Scan types: Rev 2 THE counts (THE#1 plus up to 14 kept blocks).
  the.setLen rec.scanTypes.len
  for i, st in rec.scanTypes:
    var s2 = SegdScanType(skew: st.skew)
    for d in st.descriptors3:
      let n = min(int(d.traceHeaderExtensions), 15)
      if int(d.traceHeaderExtensions) > 15:
        c.note(6, "Rev 2 holds 15 trace header extensions; later Rev 3 blocks are dropped")
      the[i].add uint8(n)
      s2.descriptors.add c.csdToRev2(d, bsiUs, uint8(n))
    result.scanTypes.add s2
  result.gh1 = g1
  result.gh2 = g2
  result.extended = rec.extended
  result.external = rec.external
  for st in result.scanTypes:
    for d in st.descriptors: result.traceCount += d.channelCount
  # The trailer is read after the traces: the scan says whether it unwraps.
  result.gh2.generalTrailerBlocks = uint16(max(0, scan.rev2Trailer))

proc traceToRev2(c: var Conv, t: SegdTrace, fIn, fOut: SegdSampleFormat, the: uint8):
    SegdTrace =
  result = SegdTrace(header: t.header, hasExt1: t.hasExt1 and the > 0,
    numSamples: t.numSamples, scanType: t.scanType, channelSet: t.channelSet, index: t.index)
  if t.header.traceNumber == BcdAllF:
    let n = int64(t.ext1r3.extTraceNumber)
    if n <= 9999:
      result.header.traceNumber = int(n)
    else:
      c.log.report(sevError, dcValidation, "trace number " & $n & " does not fit Rev 2's " &
        "four BCD digits; written as 9999", loc = Location(file: c.loc.file,
        record: c.loc.record, trace: t.index, field: "trace.traceNumber"))
      result.header.traceNumber = 9999
  if result.hasExt1:
    let e = t.ext1r3
    if t.numSamples > 0xFF_FFFF:
      raiseFormat("a trace of " & $t.numSamples & " samples exceeds Rev 2's 24-bit count")
    result.ext1 = SegdTraceHeaderExt1(receiverLineNumber: e.receiverLineNumber,
      receiverPointNumber: e.receiverPointNumber, receiverPointIndex: e.receiverPointIndex,
      samplesPerTrace: uint32(t.numSamples), extReceiverLineNumber: e.extReceiverLineNumber,
      extReceiverPointNumber: e.extReceiverPointNumber, sensorType: e.sensorType)
    if e.reshootIndex != 0 or e.groupIndex != 0 or e.depthIndex != 0 or e.sensorMoving != 0 or
        e.physicalUnit != 0:
      c.note(8, "Trace Header Extension #1 fields Rev 2 lacks (reshoot, group and depth " &
        "index, sensor moving, physical unit) are dropped")
    let keep = min(t.extensions.len div 32, int(the) - 1)
    result.extensions = t.extensions[0 ..< 32 * keep]
    if keep > 0:
      c.note(9, "Rev 3 trace header blocks after #1 are kept as raw Rev 2 extensions")
  result.header.traceHeaderExtensions = uint8((if result.hasExt1: 1 else: 0) +
    result.extensions.len div 32)
  result.samples = c.samplesFor(t.samples, t.numSamples, t.numSamples, fIn, fOut)

# ------------------------------------------------------------ the stream --

proc scanRecords*(src: RecordSource, twosComplement8015 = false): seq[RecordScan] =
  ## A headers-only pass over every record. A record's headers are written
  ## before its traces and trailer are read, but some header values depend on
  ## them: Rev 2 descriptors do not hold sample counts exactly (real data
  ## counts both end points), and a wrapped Rev 2 trailer sets the Rev 2
  ## trailer block count.
  var r = openSegd(src, twosComplement8015, headersOnly = true)
  while r.nextRecord():
    var rs = RecordScan(rev2Trailer: -1)
    for st in r.record.scanTypes:
      rs.setSamples.add newSeq[int](max(st.descriptors.len, st.descriptors3.len))
      for x in rs.setSamples[^1].mitems: x = -1
    var t: SegdTrace
    while r.readTrace(t):
      if t.scanType >= 0 and t.channelSet >= 0:
        rs.setSamples[t.scanType][t.channelSet] =
          max(rs.setSamples[t.scanType][t.channelSet], t.numSamples)
    var blocks: seq[SegdTrailerBlock]
    if r.record.isRev3 and unwrapTrailer(r.record.trailerBytes, blocks):
      rs.rev2Trailer = blocks.len
    result.add rs

proc convertSegdRevision*(src: RecordSource, sink: RecordSink,
    opts = SegdConvertOptions(), scan: seq[RecordScan] = @[]): DiagLog =
  ## Converts the SEG-D stream at `src` to revision `opts.revision` on
  ## `sink` (see the module doc). `scan`, from `scanRecords` over the same
  ## data (`convertSegdRevision(path, ...)` makes one), gives Rev 1/2 to
  ## Rev 3 each channel set's exact sample count and Rev 3 to Rev 2 the
  ## unwrapped trailer size. Without it the descriptors' times decide, traces
  ## that differ are adjusted (with a warning), and Rev 3 trailers are
  ## dropped. The reader's, the writer's and the conversion's diagnostics are
  ## all in the result; a fatal one means the output is incomplete.
  var c = Conv(opts: opts, loc: Location(file: sink.name))
  let target = opts.revision
  var f: SegdSampleFormat
  if not validTarget(target):
    c.log.report(sevFatal, dcValidation, "target SEG-D revision " & $target &
      " is not 2.0, 2.1 or 3.0", loc = c.loc)
    return c.log
  if opts.format != 0 and (not toSegdFormat(opts.format, f) or
      (f == sd8080 and target.major < 3)):
    c.log.report(sevFatal, dcValidation, "SEG-D format " & $opts.format &
      " is not defined in Rev " & $target, loc = c.loc)
    return c.log
  var r = openSegd(src, opts.twosComplement8015)
  var w: SegdWriter
  try:
    var label = r.label
    label.revision = "SD" & $target
    w = openSegdWriter(sink, SegdWriteOptions(), r.hasLabel, label)
    while r.nextRecord():
      let rec = r.record
      c.loc.record = rec.index
      if not rec.formatKnown:
        c.log.report(sevError, dcUnsupportedFormat, "record " & $rec.index & ": SEG-D " &
          "format " & $rec.gh1.formatCode & " cannot be decoded; the record is skipped",
          rec.offset, c.loc)
      else:
        let fOut = c.outFormat(rec.format)
        var ok = true
        var outRec: SegdRecord
        var setSamples: seq[seq[int]]
        var the: seq[seq[uint8]]
        let rs = if rec.index < scan.len: scan[rec.index] else: RecordScan(rev2Trailer: -1)
        try:
          if target.major == 3 and not rec.isRev3:
            outRec = c.toRev3(rec, fOut, rs, setSamples)
          elif target.major == 2 and rec.isRev3:
            outRec = c.toRev2(rec, fOut, target.minor, rs, the)
          elif target.major == 3:
            outRec = rec # 3.x to 3.0: the same layout
            outRec.gh2r3.revisionMinor = 0
            outRec.gh1.formatCode = ord(fOut)
            outRec.format = fOut
            if rec.revision.minor != 0:
              c.note(30, "Rev 3." & $rec.revision.minor & " records are written as 3.0 " &
                "unchanged; 3.1 additions are not checked")
          else:
            outRec = rec # 1/2.x to 2.y
            outRec.gh1.formatCode = ord(fOut)
            outRec.format = fOut
            if not rec.hasGh2:
              outRec.hasGh2 = true
              outRec.gh1.additionalGhBlocks = rec.gh1.additionalGhBlocks + 1
              outRec.gh2 = SegdGeneralHeader2(blockNumber: 2)
            outRec.gh2.revisionMajor = 2
            outRec.gh2.revisionMinor = target.minor
            if target.minor == 0 and outRec.gh2.lineSequenceNumber != 0:
              c.note(18, "Rev 2.0 has no record set (line sequence) number; it is dropped")
              outRec.gh2.lineSequenceNumber = 0
        except SkipRecord as e:
          ok = false
          c.log.report(sevError, dcValidation, "record " & $rec.index & " cannot be written " &
            "as Rev " & $target & ": " & e.msg & "; it is skipped", rec.offset, c.loc)
        if ok:
          if outRec.isRev3 and rec.isRev3 and fOut != rec.format:
            # 3.x with a new format: sizes from the descriptors.
            var traces: seq[SegdTrace]
            computeRev3Sizes(outRec, traces)
            var data = int64(outRec.gh3.headerSize)
            for st in outRec.scanTypes:
              for d in st.descriptors3:
                data += int64(d.channelsInSet) * int64(traceBytes(d, dataBytes(fOut,
                  int(d.numSamples))))
            outRec.gh3.dataSize = uint64(data)
            outRec.gh3.recordSize = uint64(data + outRec.trailerBytes.len)
          w.writeRecordHeaders(outRec)
          var t: SegdTrace
          while r.readTrace(t):
            if t.scanType < 0 or t.channelSet < 0:
              raiseFormat("trace " & $t.index & " names a channel set no descriptor has")
            if outRec.isRev3 and not rec.isRev3:
              w.writeTrace(c.traceToRev3(t, rec.format, fOut, setSamples[t.scanType][t.channelSet]))
            elif not outRec.isRev3 and rec.isRev3:
              w.writeTrace(c.traceToRev2(t, rec.format, fOut, the[t.scanType][t.channelSet]))
            else:
              var o = t
              o.samples = c.samplesFor(t.samples, t.numSamples, t.numSamples, rec.format, fOut)
              w.writeTrace(o)
          if outRec.isRev3 and not rec.isRev3:
            w.setRev3Trailer(wrapTrailer(r.record.trailer))
            w.endRecord()
          elif not outRec.isRev3 and rec.isRev3:
            var blocks: seq[SegdTrailerBlock]
            let tb = r.record.trailerBytes
            if tb.len > 0 and (not unwrapTrailer(tb, blocks) or blocks.len != rs.rev2Trailer):
              blocks.setLen 0
              c.note(7, "Rev 3 general trailers (description-block groups) have no Rev 2 " &
                "place and are dropped")
            w.endRecord(blocks)
          else:
            w.endRecord()
    w.close()
  except CatchableError as e:
    c.log.report(sevFatal, dcValidation, "conversion stopped: " & e.msg, loc = c.loc)
  if c.adjusted > 0:
    c.log.report(sevWarning, dcValidation, $c.adjusted & " traces were cut or zero-padded " &
      "to their channel set's sample count (Rev 3 requires one count per set)", loc = c.loc)
  if c.inexact > 0:
    c.log.report(sevWarning, dcValidation, $c.inexact & " traces could not be re-encoded " &
      "exactly in the target format", loc = c.loc)
  result = r.log
  for d in c.log: result.add d
  for d in w.log: result.add d

proc convertSegdRevision*(srcPath, dstPath: string, opts = SegdConvertOptions()): DiagLog =
  ## Converts the SEG-D disk file `srcPath` to `dstPath` (see the stream
  ## version). Never raises: problems, including I/O failures, are in the result.
  try:
    if fileExists(dstPath) and sameFile(srcPath, dstPath):
      result.report(sevFatal, dcValidation, "the output is the input file; refusing to " &
        "overwrite it", loc = Location(file: dstPath))
      return
  except OSError:
    discard
  var src: RecordSource
  var sink: RecordSink
  try:
    src = openDiskSource(srcPath)
    let scan = scanRecords(src, opts.twosComplement8015)
    src.close()
    src = nil
    src = openDiskSource(srcPath)
    sink = openDiskSink(dstPath)
    result = convertSegdRevision(src, sink, opts, scan)
  except CatchableError as e:
    result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
  finally:
    if src != nil: src.close()
    if sink != nil: sink.close()
