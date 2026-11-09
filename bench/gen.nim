## Writes the synthetic benchmark files of `bench/specs` (task 13.2).
##
##   gen [--scale=small|full] [--dir=DIR] [name ...]
##
## A file that already exists with the expected size is kept, so reruns only
## write what is missing. SEG-Y is written directly (headers through the
## library's encoders, samples through its codecs), SEG-D through the
## library's `SegdWriter` and SEG-2 through its `Seg2Writer`, so every file
## is what the library itself would write. Samples are a decaying sine plus
## a little noise (random values of random sign for the `noise` files),
## cycled over 64 variants per file; headers carry a shot
## geometry (`perRecord` channels per shot, a moving source and a fixed
## spread), so keys, gathers and geometry write-back have real values.

import std/[os, math, monotimes, times, strformat, strutils, parseopt, options]
import parseSEG/common/endians
import parseSEG/io/[records, diskio]
import parseSEG/segy/[samples, traceheader, binheader]
import parseSEG/segd/[samples as segdsamples, headers as segdheaders, rev3, reader, writer]
import parseSEG/seg2/[writer as seg2writer]
import ./specs

const Variants = 64

func amplitude(fmt: int, c: Container): float64 =
  case c
  of cSegy:
    case fmt
    of 3: 20_000.0
    of 2: 1.0e6
    else: 1000.0
  of cSegd21, cSegd30: 1000.0
  of cSeg2: 1000.0

proc waveform(v, n: int, amp: float64): seq[float64] =
  # Variant `v` of a trace: a decaying sine with a variant-dependent
  # frequency and a deterministic pseudo-random noise.
  result = newSeq[float64](n)
  var s = uint32(v) * 2654435761'u32 + 1
  for i in 0..<n:
    s = s * 1664525'u32 + 1013904223'u32
    let noise = (float64(s shr 8) / float64(1 shl 24) - 0.5) * 0.02
    let x = sin(float64(i) * 0.05 * (1 + float64(v) / 16)) *
      exp(-float64(i) / float64(n)) + noise
    result[i] = round(x * amp * 64) / 64 # few mantissa bits: exact in every format

proc noise(v, n: int, amp: float64): seq[float64] =
  # Variant `v` of a random trace: values spread over 0.001 .. 1 of `amp`
  # (16 binary orders), random signs.
  result = newSeq[float64](n)
  var s = uint32(v) * 2246822519'u32 + 7
  for i in 0..<n:
    s = s * 1664525'u32 + 1013904223'u32
    let mag = pow(2.0, -float64((s shr 8) and 15)) * (0.5 + float64(s shr 20) / 8192)
    let x = if (s and 0x8000) != 0: -mag else: mag
    result[i] = round(x * amp * 64) / 64

proc variants(s: Spec, amp: float64): seq[seq[float64]] =
  for v in 0..<Variants:
    result.add(if s.noise: noise(v, s.samples, amp) else: waveform(v, s.samples, amp))

proc report(s: Spec, path: string, t0: MonoTime) =
  let secs = (getMonoTime() - t0).inMilliseconds.float / 1000
  let gb = getFileSize(path).float / 1e9
  echo &"  {s.name}: {gb:.2f} GB in {secs:.1f} s ({gb / max(secs, 1e-3):.2f} GB/s)"

# ------------------------------------------------------------------ SEG-Y --

proc genSegy(s: Spec, path: string, traces: int) =
  let order = if s.littleEndian: boLittle else: boBig
  let fmt = toSampleFormat(s.format).get
  let traceBytes = TraceHeaderSize + s.samples * sampleSize(fmt)
  var blocks: seq[seq[byte]]
  for w in variants(s, amplitude(s.format, cSegy)):
    var b = newSeq[byte](s.samples * sampleSize(fmt))
    encodeSamples(fmt, w, b, order)
    blocks.add b
  var head = newSeq[byte](3600)
  var text = "C 1 parseSEG benchmark file " & s.name & " (bench/gen.nim)"
  text.add repeat(' ', 3200 - text.len)
  for i, c in text: head[i] = byte(c) # ASCII
  var bin = SegyBinaryHeader(sampleInterval: 2000, samplesPerTrace: uint16(s.samples),
    formatCode: int16(s.format), dataTracesPerEnsemble: int16(s.perRecord),
    measurementSystem: 1, fixedLengthTraces: 1)
  if s.littleEndian:
    bin.segyMajor = 2
    bin.byteOrderMarker = 0x01020304
  else:
    bin.segyMajor = 1
  bin.encode(head.toOpenArray(3200, 3599), order)
  var f = open(path, fmWrite)
  defer: f.close()
  doAssert f.writeBuffer(addr head[0], head.len) == head.len
  const Chunk = 1024
  var buf = newSeq[byte](Chunk * traceBytes)
  var i = 0
  while i < traces:
    let n = min(Chunk, traces - i)
    for k in 0..<n:
      let t = i + k
      let shot = t div s.perRecord
      let ch = t mod s.perRecord
      let sx = int32(shot mod 400) * 2500    # cm (scalar -100)
      let sy = int32(shot div 400) * 5000
      let gx = int32(ch) * 1250
      let gy = int32(shot div 400) * 5000 + 2500
      let h = SegyTraceHeader(traceSeqLine: int32(t + 1), traceSeqFile: int32(t + 1),
        fieldRecord: int32(shot + 1), traceNumberInField: int32(ch + 1),
        energySourcePoint: int32(shot + 1), ensembleNumber: int32(shot + 1),
        traceInEnsemble: int32(ch + 1), traceIdCode: 1, offset: (gx - sx) div 100,
        elevationScalar: -100, coordinateScalar: -100, sourceX: sx, sourceY: sy,
        groupX: gx, groupY: gy, coordinateUnits: 1, numSamples: uint16(s.samples),
        sampleInterval: 2000, year: 2026, dayOfYear: 312, hour: 12, timeBasisCode: 4,
        cdpX: (sx + gx) div 2, cdpY: (sy + gy) div 2, inlineNumber: int32(shot div 400 + 1),
        crosslineNumber: int32(ch + 1))
      let at = k * traceBytes
      h.encode(buf.toOpenArray(at, at + TraceHeaderSize - 1), order)
      let blk = blocks[t mod Variants]
      copyMem(addr buf[at + TraceHeaderSize], addr blk[0], blk.len)
    doAssert f.writeBuffer(addr buf[0], n * traceBytes) == n * traceBytes
    i += n

func segyBytes(s: Spec, traces: int): int64 =
  3600'i64 + int64(traces) * (TraceHeaderSize + s.samples *
    sampleSize(toSampleFormat(s.format).get))

# ------------------------------------------------------------------ SEG-D --

proc segdRecord(s: Spec, fileNo, ns: int, fmt: SegdSampleFormat): SegdRecord =
  if s.container == cSegd21:
    result = SegdRecord(layout: slRev2, format: some(fmt),
      revision: SegdRevision(major: 2, minor: 1))
    result.gh1 = SegdGeneralHeader1(fileNumber: (if fileNo <= 9999: fileNo else: BcdAllF),
      formatCode: ord(fmt), year: 26, additionalGhBlocks: 2, julianDay: 312, hour: 12,
      minute: 30, second: 5, manufacturerCode: 20, baseScanInterval16: 32, recordType: 8,
      recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1,
      skewBlocks: 0, extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
    result.gh2 = some SegdGeneralHeader2(extFileNumber: uint32(fileNo), revisionMajor: 2,
      revisionMinor: 1, generalTrailerBlocks: 0, extRecordLength: uint32(2 * ns),
      blockNumber: 2)
    result.sourceHeaders = @[SegdGeneralHeaderN(sourceLineNumber: float64(fileNo div 400 + 1),
      sourcePointNumber: float64(fileNo mod 400 + 1), sourcePointIndex: 1, blockNumber: 3,
      sourceSetNumber: 1)]
    let cs = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 0,
      endTime: uint16(ns), channelCount: s.perRecord, channelType: 1, gainControl: 3,
      traceHeaderExtensions: 1, verticalStack: 1, arrayForming: 1)
    result.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[cs])]
  else:
    result = SegdRecord(layout: slRev3, format: some(fmt),
      revision: SegdRevision(major: 3, minor: 0))
    result.gh1 = SegdGeneralHeader1(fileNumber: (if fileNo <= 9999: fileNo else: BcdAllF),
      formatCode: ord(fmt), year: 26, additionalGhBlocks: 2, julianDay: 312, hour: 12,
      minute: 30, manufacturerCode: 20, baseScanInterval16: 16, recordType: 8,
      recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1,
      skewBlocks: 0, extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
    result.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: uint32(fileNo), revisionMajor: 3,
      extRecordLength: uint32(1000 * (ns - 1)), blockType: 2)
    result.gh3 = SegdGeneralHeader3(timeZero: 1478_000_000_000_000'i64 +
      int64(fileNo) * 10_000_000, blockType: 3)
    let cs = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
      channelType: 0x10, endTime: int32(1000 * (ns - 1)), numSamples: uint32(ns),
      descaleMultiplier: 1.0, channelsInSet: uint32(s.perRecord), samplingInterval: 1000,
      traceHeaderExtensions: 1, verticalStack: 1, blockType1: 0x30, blockType2: 0x31,
      blockType3: 0x32)
    result.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[cs])]
  result.traceCount = s.perRecord

proc genSegd(s: Spec, path: string, traces: int) =
  let fmt = toSegdFormat(s.format).get
  var blocks: seq[seq[byte]]
  for w in variants(s, amplitude(s.format, s.container)):
    var b = newSeq[byte](dataBytes(fmt, s.samples))
    encodeSamples(fmt, w, b)
    blocks.add b
  let sink = openDiskSink(path)
  defer: sink.close()
  var w = openSegdWriter(sink)
  let records = traces div s.perRecord
  var t = if s.container == cSegd21: SegdTrace(layout: slRev2) else: SegdTrace(layout: slRev3)
  t.numSamples = s.samples
  for r in 0..<records:
    let fileNo = r + 1
    var rec = segdRecord(s, fileNo, s.samples, fmt)
    var protos: seq[SegdTrace]
    if s.container == cSegd30:
      # GH#3 sizes: every trace has the same size.
      var p = t
      p.header = SegdTraceHeader(traceHeaderExtensions: 1)
      p.samples = blocks[0]
      for k in 0..<s.perRecord: protos.add p
      computeRev3Sizes(rec, protos)
    w.writeRecordHeaders(rec)
    for k in 0..<s.perRecord:
      let tr = r * s.perRecord + k
      t.index = k
      t.header = SegdTraceHeader(fileNumber: rec.gh1.fileNumber, scanTypeNumber: 1,
        channelSetNumber: 1, traceNumber: k + 1, traceHeaderExtensions: 1,
        extFileNumber: uint32(fileNo))
      if s.container == cSegd21:
        t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: int32(r div 400 + 1),
          receiverPointNumber: int32(k + 1), receiverPointIndex: 1,
          samplesPerTrace: uint32(s.samples), sensorType: 2)
      else:
        t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: int32(r div 400 + 1),
          receiverPointNumber: int32(k + 1), receiverPointIndex: 1,
          numSamples: uint32(s.samples), sensorType: 2, blockType: 0x40)
      t.samples = blocks[tr mod Variants]
      w.writeTrace(t)
    w.endRecord()
  w.close()

func segdBytes(s: Spec, traces: int): int64 =
  let fmt = toSegdFormat(s.format).get
  let records = traces div s.perRecord
  let head = if s.container == cSegd21: 32 * 3 + 32 else: 32 * 3 + 96
  let trace = 20 + 32 + dataBytes(fmt, s.samples)
  int64(records) * (head + int64(s.perRecord) * trace)

# ------------------------------------------------------------------ SEG-2 --

proc genSeg2(s: Spec, path: string, traces: int) =
  var fdb = initSeg2File(boLittle)
  fdb.traceCount = uint16(traces)
  fdb["UNITS"] = "METERS"
  var w = openSeg2Writer(path, fdb)
  let ws = variants(s, amplitude(s.format, cSeg2))
  var f32 = newSeq[float32](s.samples)
  for i in 0..<traces:
    var t = Seg2Trace(formatCode: uint8(s.format))
    # In keyword order, as the standard asks.
    t["CHANNEL_NUMBER"] = $(i + 1)
    t["RECEIVER_LOCATION"] = $(float64(i) * 12.5)
    t["SAMPLE_INTERVAL"] = "0.002"
    t["SOURCE_LOCATION"] = "0"
    for k in 0..<s.samples: f32[k] = float32(ws[i mod Variants][k])
    w.writeTrace(t, f32)
  w.close()

# ------------------------------------------------------------------- main --

proc expectedBytes(s: Spec, traces: int): int64 =
  case s.container
  of cSegy: segyBytes(s, traces)
  of cSegd21, cSegd30: segdBytes(s, traces)
  of cSeg2: -1 # strings vary in length; existence is enough

proc generate*(s: Spec, dir: string, scale: Scale) =
  ## Writes the file of `s` at `scale` unless it is there already.
  let n = s.traces(scale)
  if n == 0: return
  let path = s.path(dir, scale)
  let want = expectedBytes(s, n)
  if fileExists(path) and (want < 0 or getFileSize(path) == want):
    echo &"  {s.name}: present ({getFileSize(path).float / 1e9:.2f} GB)"
    return
  let tmp = path & ".part"
  let t0 = getMonoTime()
  case s.container
  of cSegy: genSegy(s, tmp, n)
  of cSegd21, cSegd30: genSegd(s, tmp, n)
  of cSeg2: genSeg2(s, tmp, n)
  if want >= 0 and getFileSize(tmp) != want:
    echo &"  {s.name}: {getFileSize(tmp)} bytes written, {want} expected"
    quit 1
  moveFile(tmp, path)
  report(s, path, t0)

when isMainModule:
  var dir = dataDir()
  var sc = scale()
  var names: seq[string]
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "scale": sc = parseEnum[Scale](val)
      of "dir": dir = val
      else: quit "unknown option --" & key
    of cmdArgument: names.add key
    else: quit "unknown option -" & key
  createDir(dir)
  echo &"benchmark data ({sc}) in {dir}"
  for s in benchFiles:
    if names.len == 0 or s.name in names: generate(s, dir, sc)
