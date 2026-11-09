## Multiplexed SEG-D (task 4.7): the scan walker, the 0015 transcoding and
## the other multiplexed codes, demultiplexing into traces, the demultiplexed
## copy, and `openSeismic` on a multiplexed file. There is no real
## multiplexed sample file, so every record here is built by `muxRecord`,
## which writes the bytes the spec describes (`segd_rev0.md` §2.3, §3.6, §5).

import std/[assertions, os, strutils, math, options]
import parseSEG/common/[diagnostics, endians, errors]
import parseSEG/io/[records, tapeimage]
import parseSEG/segd/[reader, writer, headers, samples, mux, demux, revconvert]
import parseSEG/model/[traceindex, edit]
import parseSEG/survey/writeback


let tmp = getTempDir() / "parseseg_tsegdmux"
removeDir(tmp)
createDir(tmp)

proc has(log: DiagLog, text: string, sev = sevInfo): bool =
  for d in log:
    if d.severity == sev and text in d.msg: return true

proc problems(log: DiagLog): int =
  log.count(sevWarning) + log.count(sevError) + log.count(sevFatal)

proc writeBytes(path: string, b: openArray[byte]) =
  var s = newString(b.len)
  for i, x in b: s[i] = char(x)
  writeFile(path, s)

# ------------------------------------------------------------- fixtures --

type
  MuxSet = object
    channels, subExp: int
    channelType: uint8

  MuxSpec = object
    code: int
    sets: seq[seq[MuxSet]]    ## Channel sets per scan type.
    scans: seq[int]           ## Scans per scan type.
    window: seq[int]          ## Scans the channel set windows announce (default: `scans`).
    bsi16: int                ## Base scan interval in 1/16 ms.
    bytesPerScan: int         ## GH#1 bytes 20-22; -1 = computed.
    twiFrom: int              ## First scan with TWI = 1; -1 = never.
    dpToggles: bool           ## Toggle DP at each new scan type.
    cutLastScan: int          ## Bytes cut off the last scan.

func initSpec(code: int, sets: seq[seq[MuxSet]], scans: seq[int]): MuxSpec =
  MuxSpec(code: code, sets: sets, scans: scans, window: scans, bsi16: 32, bytesPerScan: -1,
    twiFrom: 2, dpToggles: true)

func bsiMs(s: MuxSpec): float64 = float64(s.bsi16) / 16

func exponent0015(st, cs, ch, j: int): int = (st + 2 * cs + ch + j) mod 16

func fraction0015(st, cs, ch, j: int): int =
  ## A 14-bit one's complement fraction (as a signed integer), both signs.
  let m = (st * 977 + cs * 331 + ch * 97 + j * 1013) mod 16383
  if (ch + j) mod 2 == 1: -m else: m

func value0015(st, cs, ch, j: int): float64 =
  ## What a 0015 sample is worth: S.Q × 2^C, hand-computed from the spec.
  float64(fraction0015(st, cs, ch, j)) / 16384.0 * float64(1 shl exponent0015(st, cs, ch, j))

func word0015(m: int): uint16 =
  ## Sign and 14-bit one's complement fraction, LSB 0 (`segd_rev0.md` §5.1).
  if m >= 0: uint16(m shl 1) else: uint16(0x8000 or (((-m) xor 0x3FFF) shl 1))

func valueOf(code, st, cs, ch, j: int): float64 =
  ## The value a channel's sample holds, exact in every format but 0022/0042.
  let x = float64((st * 31 + cs * 17 + ch * 7 + j * 3) mod 41 - 20)
  case code
  of 22, 42: x / 4
  of 36, 38: x * 1000 + float64(ch)
  else: x / 8

func twinOf(code: int): SegdSampleFormat = toSegdFormat(8000 + code).get

proc sampleBytes(code, st, cs, ch, j: int): seq[byte] =
  ## One sample in the twin's bytes, which are the multiplexed bytes too.
  result = newSeq[byte](dataBytes(twinOf(code), 1))
  encodeSegdSamples(twinOf(code), [valueOf(code, st, cs, ch, j)], result)

func bcd6(n: int): array[3, byte] =
  var v = n
  for i in countdown(2, 0):
    result[i] = byte((v mod 10) or ((v div 10 mod 10) shl 4))
    v = v div 100

func layoutBytes(s: MuxSpec, st: int): int =
  result = ScanHeaderSize
  for c in s.sets[st]: result += (1 shl c.subExp) * muxBytes(s.code, c.channels)

func samplesPerScan(s: MuxSpec, st: int): int =
  for c in s.sets[st]: result += (1 shl c.subExp) * c.channels

func skewByte(st, i: int): byte = byte((st * 50 + i * 3 + 1) mod 256)

func scanTiming(s: MuxSpec, scan: int): array[3, byte] =
  let t = uint32(round(float64(scan) * s.bsiMs * 256))
  [byte(t shr 16), byte((t shr 8) and 0xFF), byte(t and 0xFF)]

proc headerBlock(s: MuxSpec): seq[byte] =
  let nST = s.sets.len
  let nCS = s.sets[0].len
  let nSK = (s.samplesPerScan(0) + 31) div 32
  let b = if s.bytesPerScan >= 0: s.bytesPerScan else: s.layoutBytes(0)
  let g = SegdGeneralHeader1(fileNumber: 12, formatCode: s.code, year: 85, julianDay: 123,
    hour: 10, minute: 20, second: 30, manufacturerCode: 9, baseScanInterval16: uint8(s.bsi16),
    unused20: bcd6(b), recordType: 8, recordLength: 1, scanTypesPerRecord: nST,
    channelSetsPerScanType: nCS, skewBlocks: nSK)
  result.add g.encoded
  var firstScan = 0
  for st in 0..<nST:
    let tf = int(round(float64(firstScan) * s.bsiMs / 2))
    for cs, c in s.sets[st]:
      let te = tf + int(round(float64(s.window[st]) * s.bsiMs / 2))
      let d = SegdChannelSetDescriptor(scanTypeNumber: st + 1, channelSetNumber: cs + 1,
        startTime: uint16(tf), endTime: uint16(te), channelCount: c.channels,
        channelType: c.channelType, subscanExponent: c.subExp, gainControl: 3)
      result.add d.encoded
    for i in 0 ..< 32 * nSK: result.add skewByte(st, i)
    firstScan += s.scans[st]

proc scanBytes(s: MuxSpec, st, scan, absScan: int): seq[byte] =
  ## Scan `scan` of scan type `st` (`absScan` within the record).
  var flags = 0x01'u8
  if s.twiFrom >= 0 and absScan >= s.twiFrom: flags = flags or 0x40
  if s.dpToggles and st mod 2 == 1: flags = flags or 0x10
  result = @[0xFF'u8, 0xFF, 0xFF, flags]
  result.add s.scanTiming(absScan)
  result.add 0
  for cs, c in s.sets[st]:
    let sub = 1 shl c.subExp
    for k in 0..<sub:
      let j = scan * sub + k
      if s.code == 15:
        for g in 0 ..< (c.channels + 3) div 4:
          var e: array[4, int]
          var w: array[4, uint16]
          for p in 0..3:
            let ch = 4 * g + p
            if ch < c.channels:
              e[p] = exponent0015(st, cs, ch, j)
              w[p] = word0015(fraction0015(st, cs, ch, j))
          result.add byte((e[0] shl 4) or e[1])
          result.add byte((e[2] shl 4) or e[3])
          for p in 0..3:
            result.add byte(w[p] shr 8)
            result.add byte(w[p] and 0xFF)
      else:
        for ch in 0..<c.channels: result.add sampleBytes(s.code, st, cs, ch, j)
  let b = if s.bytesPerScan > 0: s.bytesPerScan else: result.len
  while result.len < b: result.add 0xEE # unused tail of a scan

proc muxRecord(s: MuxSpec): seq[byte] =
  ## A whole multiplexed record: header block, then every scan.
  result = s.headerBlock
  var abs = 0
  for st in 0 ..< s.sets.len:
    for scan in 0 ..< s.scans[st]:
      result.add s.scanBytes(st, scan, abs)
      inc abs
  result.setLen result.len - s.cutLastScan

proc expectedTraces(s: MuxSpec): int =
  for st in 0 ..< s.sets.len:
    for c in s.sets[st]: result += c.channels

proc checkTraces(s: MuxSpec, d: SegdRecordData) =
  ## Every demultiplexed trace against the values the fixture wrote.
  doAssert d.traces.len == s.expectedTraces, $d.traces.len
  var i = 0
  var firstScan = 0
  for st in 0 ..< s.sets.len:
    var first = 0
    for cs, c in s.sets[st]:
      let sub = 1 shl c.subExp
      for ch in 0..<c.channels:
        let t = d.traces[i]
        doAssert t.scanType == st and t.channelSet == cs
        doAssert t.header.scanTypeNumber == st + 1 and t.header.channelSetNumber == cs + 1
        doAssert t.header.traceNumber == ch + 1 and t.header.fileNumber == 12
        doAssert t.numSamples == s.scans[st] * sub
        let ft = s.scanTiming(firstScan)
        doAssert t.header.raw[6 .. 8] == @ft
        doAssert t.header.firstTimingWord == float64(firstScan) * s.bsiMs
        doAssert t.header.sampleSkew == skewByte(st, first + ch)
        if s.twiFrom >= 0:
          doAssert t.header.timeBreakWindow == float64(s.twiFrom) * s.bsiMs
        if s.code == 15:
          for j in 0..<t.numSamples:
            doAssert float64(d.samples[i, j]) == value0015(st, cs, ch, j),
              $(st, cs, ch, j) & " " & $d.samples[i, j]
        else:
          var want: seq[byte]
          for j in 0..<t.numSamples: want.add sampleBytes(s.code, st, cs, ch, j)
          doAssert t.samples == want, "code " & $s.code & " " & $(st, cs, ch)
        inc i
      first += sub * c.channels
    firstScan += s.scans[st]

proc oneSet(code: int, channels = 4, scans = 6): MuxSpec =
  initSpec(code, @[@[MuxSet(channels: channels, channelType: 1)]], @[scans])

# --------------------------------------------------------------- codecs --

block codes_and_layout:
  for c in [15, 22, 24, 36, 38, 42, 44, 48, 58]:
    doAssert c.isMultiplexedCode and demuxFormat(c) == some(toSegdFormat(8000 + c).get)
  for c in [0, 16, 200, 8015, 1015]:
    doAssert not c.isMultiplexedCode and demuxFormat(c).isNone
  # E2's example: 4 aux channels, 96 at the base interval, 12 at 4 subscans, 0015.
  let ds = [SegdChannelSetDescriptor(channelCount: 4),
    SegdChannelSetDescriptor(channelCount: 96),
    SegdChannelSetDescriptor(channelCount: 12, subscanExponent: 2)]
  let l = muxLayout(15, ds)
  doAssert l.bytesPerScan == 378 # 8 + 148 × 2.5 [p.30]
  doAssert l.channelSets[1].offset == 8 + 10 and l.channelSets[2].offset == 8 + 10 + 240
  doAssert l.channelSets[2].subscans == 4 and l.channelSets[2].subscanBytes == 30
  doAssert l.channelSets[2].firstSample == 100
  doAssert muxLayout(24, ds).bytesPerScan == 8 + 148 * 2

block start_of_scan_and_timing_word:
  let b = [0xFF'u8, 0xFF, 0xFF, 0x71, 0x01, 0x02, 0x80, 0x00]
  doAssert isStartOfScan(b)
  let h = scanHeader(b)
  doAssert h.twi and h.itb and h.dp and h.byte8 == 0
  doAssert h.timingMs == 258.5 # 0x0102 ms + 0x80/256
  doAssert not isStartOfScan([0xFF'u8, 0xFF, 0xFF, 0x02])
  doAssert not isStartOfScan([0xFF'u8, 0xFE, 0xFF, 0x01])

block decode_0015_by_hand:
  # Channel 1: C = 3, +100/16384; channel 2: C = 0, -1/16384; channel 3:
  # C = 15, -(1 - 2^-14); channel 4: negative zero (0xFFFE) = 0.
  let g = [0x30'u8, 0xF0, 0x00, 0xC8, 0xFF, 0xFC, 0x80, 0x00, 0xFF, 0xFE]
  var v: array[4, float64]
  decodeMux0015(g, v)
  doAssert v[0] == 100 / 16384 * 8 and v[0] == 0.048828125
  doAssert v[1] == -1 / 16384
  doAssert v[2] == -(16383 / 16384) * 32768
  doAssert v[3] == 0
  # Demultiplexed to 8015, the 8015 decoder gives the same values.
  let cs = MuxChannelSet(offset: 0, channels: 4, subscans: 1, subscanBytes: 10)
  for ch in 0..3:
    var o = newSeq[byte](10)
    demuxChannel(15, g, 10, 1, cs, ch, o)
    var x: array[1, float64]
    decodeSegdSamples(sd8015, o, x)
    doAssert x[0] == v[ch], $ch
  # Two's complement: 0xFFFC is -2 >> 1 = -1 LSB; read so on both sides.
  decodeMux0015(g, v, twosComplement = true)
  doAssert v[1] == -2 / 16384 and v[3] == -1 / 16384
  var o = newSeq[byte](10)
  demuxChannel(15, g, 10, 1, cs, 1, o, twosComplement = true)
  var x: array[1, float64]
  decodeSegdSamples(sd8015, o, x, twosComplement8015 = true)
  doAssert x[0] == v[1]

# ---------------------------------------------------------- the reader --

block demux_0015_two_channel_sets_and_subscans:
  var s = initSpec(15, @[@[MuxSet(channels: 4, channelType: 2),
    MuxSet(channels: 8, subExp: 1, channelType: 1)]], @[8])
  writeBytes(tmp / "m15.sgd", s.muxRecord)
  let d = readSegd(tmp / "m15.sgd")
  doAssert d.log.problems == 0, $d.log
  doAssert d.log.has("multiplexed (format 0015)")
  let r = d.records[0].record
  doAssert r.multiplexed and r.format == some(sd8015) and r.gh1.formatCode == 15
  doAssert r.gh1.bytesPerScan == 8 + 10 + 2 * 20
  doAssert d.records[0].traces[4].numSamples == 16 # 8 scans × 2 subscans
  s.checkTraces(d.records[0])
  # A hand-computed sample: channel set 2, channel 3 (0-based 2), sample 5.
  doAssert d.records[0].samples[4 + 2, 5] == float32(value0015(0, 1, 2, 5))
  doAssert value0015(0, 1, 2, 5) == -float64((331 + 2 * 97 + 5 * 1013) mod 16383) / 16384 * 512
  # Headers only: same traces, no samples.
  let h = readSegdHeaders(tmp / "m15.sgd")
  doAssert h.records[0].traces.len == 12 and h.records[0].traces[11].numSamples == 16
  doAssert h.records[0].traces[11].samples.len == 0

block every_multiplexed_code:
  for code in [22, 24, 36, 38, 42, 44, 48, 58]:
    var s = initSpec(code, @[@[MuxSet(channels: 3, channelType: 1),
      MuxSet(channels: 2, subExp: 2, channelType: 1)]], @[5])
    writeBytes(tmp / "mc.sgd", s.muxRecord)
    let d = readSegd(tmp / "mc.sgd")
    doAssert d.log.problems == 0, $code & " " & $d.log
    doAssert d.records[0].record.format == some(twinOf(code))
    s.checkTraces(d.records[0])
    # Decoded values: the twin's decoder.
    var want: array[1, float32]
    decodeSegdSamples(twinOf(code), sampleBytes(code, 0, 0, 1, 2), want)
    doAssert d.records[0].samples[1, 2] == want[0], $code

block two_scan_types_split_by_dp:
  var s = initSpec(44, @[@[MuxSet(channels: 2, channelType: 1), MuxSet(channels: 3)],
    @[MuxSet(channels: 2, subExp: 1, channelType: 1), MuxSet(channels: 0)]], @[4, 3])
  s.twiFrom = 5
  # The second scan type needs fewer bytes per scan than the first; its
  # scans are padded to GH#1's bytes per scan.
  s.bytesPerScan = s.layoutBytes(0)
  writeBytes(tmp / "st2.sgd", s.muxRecord)
  let d = readSegd(tmp / "st2.sgd")
  doAssert d.records[0].traces.len == 7
  doAssert d.log.has("scan type 2 has " & $s.layoutBytes(1) & " bytes per scan",
    sevWarning), $d.log
  s.checkTraces(d.records[0])
  doAssert d.records[0].traces[5].offset == s.headerBlock.len + 4 * s.bytesPerScan
  # Without DP toggles, the windows split the scan types (with a warning).
  # This path once read `starts[^1]` after the seq grew (13.3 R4-3, seen
  # under ASan only).
  s.dpToggles = false
  writeBytes(tmp / "st2b.sgd", s.muxRecord)
  let e = readSegd(tmp / "st2b.sgd")
  doAssert e.log.has("split by their channel set windows", sevWarning)
  s.checkTraces(e.records[0])

block window_disagrees_and_the_copy_carries_the_length:
  var s = oneSet(15, scans = 8) # 8015 wants traces in multiples of 4 samples
  s.window = @[7] # the window ends one scan early (the +1 question)
  writeBytes(tmp / "w.sgd", s.muxRecord)
  let d = readSegd(tmp / "w.sgd")
  doAssert d.log.has("has 8 scans, its channel set window gives 7"), $d.log
  doAssert d.log.problems == 0
  s.checkTraces(d.records[0])
  let log = demultiplexSegd(tmp / "w.sgd", tmp / "w_demux.sgd")
  doAssert log.problems == 0 and log.has("Trace Header Extension #1"), $log
  let c = readSegd(tmp / "w_demux.sgd")
  doAssert c.log.problems == 0, $c.log
  let r = c.records[0].record
  doAssert not r.multiplexed and r.gh1.formatCode == 8015 and r.gh1.bytesPerScan == 0
  doAssert r.scanTypes[0].descriptors[0].traceHeaderExtensions == 1
  doAssert c.records[0].traces[0].numSamples == 8
  for i in 0..3:
    doAssert c.records[0].traces[i].samples == d.records[0].traces[i].samples
    doAssert c.records[0].traces[i].header.firstTimingWord == 0
    doAssert c.records[0].traces[i].header.timeBreakWindow == 4.0

block gapped_blocks_on_a_tape_image_then_a_demux_record:
  # S/B × 2^S/BX = 2 × 2 scans per block; the last block is short. Then a
  # demultiplexed Rev 0 record on the same reel.
  var s = oneSet(42, channels = 3, scans = 9)
  let body = s.muxRecord
  let hb = s.headerBlock.len
  var head = body[0 ..< hb]
  head[24] = 2      # S/B
  head[23] = head[23] or 1 # S/BX = 1
  let stride = s.layoutBytes(0)
  let sink = openTapeImageSink(tmp / "gap.tap")
  sink.writeRecord(head)
  var p = hb
  while p < body.len:
    let q = min(body.len, p + 4 * stride)
    sink.writeRecord(body[p ..< q])
    p = q
  sink.writeTapeMark()
  # A demultiplexed record: copy the first one, demultiplexed.
  let d0 = readSegd(tmp / "m15.sgd")
  var w = openSegdWriter(sink)
  let rec = demultiplexedRecord(d0.records[0].record)
  w.writeRecordHeaders(rec)
  for t in d0.records[0].traces: w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.close()
  let src = openTapeImageSource(tmp / "gap.tap")
  let d = readSegd(src)
  src.close()
  doAssert d.log.problems == 0, $d.log
  doAssert d.records.len == 2
  doAssert d.records[0].record.gh1.scansPerBlock == 4
  s.checkTraces(d.records[0])
  doAssert not d.records[1].record.multiplexed and d.records[1].traces.len == 12
  doAssert d.records[1].samples == d0.records[0].samples

block problems_are_diagnostics:
  # Undefined multiplexed code.
  var b = oneSet(22).muxRecord
  b[3] = 0x16
  writeBytes(tmp / "p1.sgd", b)
  var d = readSegd(tmp / "p1.sgd")
  doAssert d.log.isFatal and d.log.has("undefined multiplexed code", sevFatal), $d.log
  # Bytes per scan smaller than the descriptors need.
  var s = oneSet(24)
  s.bytesPerScan = 10
  writeBytes(tmp / "p2.sgd", s.muxRecord)
  d = readSegd(tmp / "p2.sgd")
  doAssert d.log.has("needs 16 bytes per scan", sevFatal), $d.log
  # Bytes per scan 0: computed, with a warning.
  s.bytesPerScan = 0
  writeBytes(tmp / "p3.sgd", s.muxRecord)
  d = readSegd(tmp / "p3.sgd")
  doAssert d.log.has("bytes per scan is 0", sevWarning) and not d.log.isFatal
  s.bytesPerScan = -1
  s.checkTraces(d.records[0])
  # A cut last scan is dropped.
  s.cutLastScan = 3
  writeBytes(tmp / "p4.sgd", s.muxRecord)
  d = readSegd(tmp / "p4.sgd")
  doAssert d.log.has("last scan is cut short", sevWarning) and not d.log.isFatal
  doAssert d.records[0].traces[0].numSamples == 5
  # No start of scan where the data begins.
  s.cutLastScan = 0
  b = s.muxRecord
  b[s.headerBlock.len] = 0
  writeBytes(tmp / "p5.sgd", b)
  d = readSegd(tmp / "p5.sgd")
  doAssert d.log.has("does not start with a start-of-scan code", sevFatal)
  # 0015 needs channels in fours.
  writeBytes(tmp / "p6.sgd", oneSet(15, channels = 3).muxRecord)
  d = readSegd(tmp / "p6.sgd")
  doAssert d.log.has("multiple of 4 channels", sevWarning)
  doAssert d.records[0].traces.len == 3 and not d.log.isFatal

# ------------------------------------------------------- open and index --

block open_seismic_demultiplexes_into_a_temp_copy:
  var s = initSpec(15, @[@[MuxSet(channels: 4, channelType: 2),
    MuxSet(channels: 8, subExp: 1, channelType: 1)]], @[8])
  let dir = tmp / "demux"
  createDir(dir)
  var f = openSeismic(tmp / "m15.sgd", keys = true, demuxDir = dir)
  doAssert f.demuxPath.len > 0 and f.demuxPath.parentDir == dir and fileExists(f.demuxPath)
  doAssert f.log.has("demultiplexed into the temporary copy", sevWarning), $f.log
  doAssert f.log.count(sevError) + f.log.count(sevFatal) == 0
  doAssert f.kind == skSegd and f.len == 12 and f.maxSamples == 16
  doAssert f.traceEntry(4).numSamples == 16 and f.traceEntry(4).channelType == 1
  doAssert f.traceEntry(0).channelType == 2
  # Range and list reads against the hand-computed values.
  let all = f.readTraces(0..11, T = float64)
  for i in 0..11:
    let (cs, ch) = if i < 4: (0, i) else: (1, i - 4)
    for j in 0 ..< int(f.traceEntry(i).numSamples):
      doAssert all[i, j] == value0015(0, cs, ch, j)
  let sel = f.readTraces([9, 1], T = float64)
  doAssert sel[0, 3] == value0015(0, 1, 5, 3) and sel[1, 6] == value0015(0, 0, 1, 6)
  doAssert sel[1, 8] == 0 # trace 1 has 8 samples, padded
  let k = f.traceKeys(6)
  doAssert k.record == 12 and k.channel == 3
  let copy = f.demuxPath
  f.close()
  doAssert not fileExists(copy)
  # A demultiplexed file is opened as it is.
  var g = openSeismic(tmp / "w_demux.sgd")
  doAssert g.demuxPath == "" and g.len == 4
  g.close()
  # A copy left to the destructor is deleted too.
  block:
    let h = openSeismic(tmp / "w.sgd", demuxDir = dir)
    doAssert h.len == 4 and fileExists(h.demuxPath)
  for p in walkDir(dir): doAssert false, "left behind: " & p.path
  # An index of the multiplexed file itself refuses range reads.
  let m = openMemFileSource(tmp / "m15.sgd")
  let ix = buildIndex(m, skSegd)
  m.close()
  doAssert ix.len == 12 and not ix.contiguous and ix.segdRecords[0].multiplexed
  # In-place edits refuse a multiplexed file.
  doAssertRaises ValueError: discard openEditor(tmp / "m15.sgd")
  doAssertRaises ValueError: discard openEditor(tmp / "m15.sgd", tmp / "j.nif")
  doAssert not fileExists(tmp / "j.nif")
  # Survey geometry: in place is refused like any edit; a copy is written
  # demultiplexed (10.5).
  let geo = copyWithGeometry(tmp / "m15.sgd", tmp / "m15geo.sgd", initSurveyGeometry()).log
  doAssert not geo.isFatal and geo.has("geometry written: 0 traces")
  var gf = openSeismic(tmp / "m15geo.sgd")
  doAssert gf.demuxPath.len == 0 and gf.len == 12 and not gf.index.segdRecords[0].multiplexed
  gf.close()

block conversions_read_demultiplexed_traces:
  # Revision conversion and SEG-Y conversion go through the reader.
  let log = convertSegdRevision(tmp / "m15.sgd", tmp / "m15_21.sgd",
    SegdConvertOptions(revision: SegdRevision(major: 2, minor: 1)))
  doAssert not log.isFatal and log.count(sevError) == 0, $log
  let a = readSegd(tmp / "m15.sgd")
  let b = readSegd(tmp / "m15_21.sgd")
  doAssert b.records[0].record.gh1.formatCode == 8015 and not b.records[0].record.multiplexed
  doAssert b.records[0].samples == a.records[0].samples

echo "tsegdmux: ok"
