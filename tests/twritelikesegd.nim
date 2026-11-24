## A `like:` SEG-D writer may give a record a new sample count (one count for
## the record). Seen failing before the change: `writeTrace` raised
## `ValueError` ("a SEG-D trace keeps its sample count"), with no truncation
## and no header rewrite.

import std/[assertions, os, strutils]

import parseSEG
import parseSEG/common/diagnostics
import parseSEG/io/diskio
import parseSEG/segd/[reader, writer, headers, samples, rev3]

import ./utils/testutils

proc put(path: string, d: SegdData) =
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, d)
    doAssert log.count(sevError) + log.count(sevFatal) == 0, $log
  finally:
    sink.close()

proc wave(n: int): seq[float32] =
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = float32((i mod 7) - 3) * 0.25'f32

proc readAll(path: string): string = readFile(path)

proc outside(a, b: openArray[byte], skip: openArray[Slice[int]]): string =
  ## "" when `a` and `b` agree outside the inclusive ranges in `skip`.
  if a.len != b.len: return "length " & $a.len & " vs " & $b.len
  for i in 0 ..< a.len:
    if a[i] == b[i]: continue
    var skipped = false
    for s in skip:
      if i >= s.a and i <= s.b: skipped = true
    if not skipped: return "byte " & $i & ": " & $a[i] & " vs " & $b[i]

proc makeRev2(fileNo: int, format: SegdSampleFormat, ns: int): SegdRecordData =
  ## One Rev 2.1 record: aux (2 traces, no extensions) and seismic (3 traces
  ## with THE#1). Record length is `FFF` plus GH#2 milliseconds.
  var r = SegdRecord(layout: slRev2, format: some(format),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: fileNo, formatCode: ord(format), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, minute: 30, second: 5,
    manufacturerCode: 9, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 2, skewBlocks: 1, extendedHeaderBlocks: 1,
    externalHeaderBlocks: 0)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: uint32(fileNo), revisionMajor: 2,
    revisionMinor: 1, generalTrailerBlocks: 2, extRecordLength: uint32(2 * ns),
    blockNumber: 2, lineSequenceNumber: 77)
  r.sourceHeaders = @[SegdGeneralHeaderN(sourceLineNumber: 1001.5, sourcePointNumber: -12.25,
    sourcePointIndex: 1, phaseControl: 1, vibratorType: 2, phaseAngle: -90, blockNumber: 3,
    sourceSetNumber: 1)]
  var aux = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
    endTime: uint16(ns), channelCount: 2, channelType: 9, gainControl: 3, verticalStack: 1,
    arrayForming: 1)
  let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 2,
    endTime: uint16(ns), channelCount: 3, channelType: 1, gainControl: 3,
    aliasFilterFreq: 200, aliasFilterSlope: 370, lowCutFreq: 3, lowCutSlope: 18,
    notch1Freq: 500, traceHeaderExtensions: 2, verticalStack: 1, arrayForming: 1)
  var skew = newSeq[byte](32)
  for i in 0 ..< skew.len: skew[i] = byte(i)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[aux, seis], skew: skew)]
  r.extended = newSeq[byte](32)
  for i in 0 ..< 32: r.extended[i] = byte(200 + i mod 50)
  r.trailer = @[SegdTrailerBlock(trailerNumber: 1, channelType: 0xC),
    SegdTrailerBlock(trailerNumber: 2, channelType: 0xC)]
  r.trailer[1].undef12[0] = 0x5A
  r.traceCount = 5
  result.record = r
  for k in 0 ..< 5:
    let isAux = k < 2
    var t = SegdTrace(index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: fileNo, scanTypeNumber: 1,
      channelSetNumber: (if isAux: 1 else: 2), traceNumber: (if isAux: k + 1 else: k - 1),
      traceHeaderExtensions: (if isAux: 0'u8 else: 2'u8))
    if not isAux:
      t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000,
        receiverPointNumber: int32(100 + k), receiverPointIndex: 1,
        samplesPerTrace: uint32(ns), sensorType: 2)
      t.extensions = newSeq[byte](32)
      t.extensions[0] = byte(k)
    var vals = newSeq[float64](ns)
    for i in 0 ..< ns: vals[i] = float64((i mod 9) - 4) * 0.125
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSamples(format, vals, t.samples)
    result.traces.add t

proc makeRev3(format: SegdSampleFormat, ns: int): SegdRecordData =
  ## One Rev 3.0 record, one seismic set of 2 traces. End time is the
  ## source's `(ns - 1) * interval`, which a same-count rewrite must keep.
  var r = SegdRecord(layout: slRev3, format: some(format),
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 5, formatCode: ord(format), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, manufacturerCode: 50,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 5, revisionMajor: 3,
    extRecordLength: uint32(1000 * (ns - 1)), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
  let seis = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, endTime: int32(1000 * (ns - 1)), numSamples: uint32(ns),
    descaleMultiplier: 0.25, channelsInSet: 2, samplingInterval: 1000,
    traceHeaderExtensions: 1, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[seis])]
  var traces: seq[SegdTrace]
  for k in 0 .. 1:
    var t = SegdTrace(layout: slRev3, index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: 5, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: k + 1, traceHeaderExtensions: 1)
    t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: 7,
      receiverPointNumber: int32(k), numSamples: uint32(ns), sensorType: 2,
      groupIndex: 1, blockType: 0x40)
    var vals = newSeq[float64](ns)
    for i in 0 ..< ns: vals[i] = float64(i - 3) * 0.5
    t.samples = newSeq[byte](dataBytes(format, ns))
    encodeSamples(format, vals, t.samples)
    traces.add t
  computeRev3Sizes(r, traces)
  r.traceCount = 2
  result.record = r
  result.traces = traces

proc writeLike(src, dst: string, n: int) =
  var f = openSeismic(src)
  var w = openSeismicWriter(dst, f)
  let s = wave(n)
  for i in 0 ..< f.len: w.writeTrace(f, i, s)
  doAssert not w.close().isFatal

proc checkSamples(path: string, n: int, traces: int, want: openArray[float32]) =
  var g = openSeismic(path)
  doAssert not g.log.isFatal, $g.log
  doAssert g.len == traces and g.maxSamples == n
  let got = g.readTraces(0 ..< g.len, float32)
  for i in 0 ..< g.len:
    doAssert g.traceEntry(i).numSamples == uint32(n)
    for k in 0 ..< n:
      doAssert got[i, k] == want[k], "trace " & $i & " sample " & $k

proc rev2Ends(path: string, n: int) =
  var g = openSeismic(path)
  let rec = g.index.segdRecords[0]
  doAssert rec.gh1.recordType == 8
  doAssert rec.gh1.recordLength == BcdAllF
  doAssert rec.gh2.get.extRecordLength == uint32(2 * n)
  doAssert recordLengthMs(rec.gh1, rec.gh2.get) == float64(2 * n)
  for c in rec.scanTypes[0].descriptors:
    doAssert c.startTime == 0
    doAssert c.endTime == uint16(n)
    doAssert c.endTimeMs == float64(2 * n)

proc rev3Ends(path: string, n: int) =
  var g = openSeismic(path)
  let rec = g.index.segdRecords[0]
  doAssert rec.gh1.recordType == 8
  doAssert rec.gh1.recordLength == BcdAllF
  doAssert rec.gh2Rev3.extRecordLength == uint32(1000 * n)
  doAssert recordLengthUs(rec.gh1, rec.gh2Rev3) == float64(1000 * n)
  let c = rec.scanTypes[0].descriptorsRev3[0]
  doAssert c.startTime == 0
  doAssert c.endTime == int32(1000 * n)
  doAssert c.numSamples == uint32(n)
  doAssert rec.gh3.headerSize == uint32(rec.headerBytes)

proc headerSame(src, dst: string, recSkip, traceSkip: openArray[Slice[int]]) =
  var a = openSeismic(src)
  var b = openSeismic(dst)
  doAssert a.len == b.len
  let ha = a.copyBytes(0, int(a.traceEntry(0).offset))
  let hb = b.copyBytes(0, int(b.traceEntry(0).offset))
  let bad = outside(ha, hb, recSkip)
  doAssert bad.len == 0, "record header " & bad
  for i in 0 ..< a.len:
    let ea = a.traceEntry(i)
    let eb = b.traceEntry(i)
    doAssert ea.headerBytes == eb.headerBytes
    let ta = a.copyBytes(ea.offset, ea.headerBytes)
    let tb = b.copyBytes(eb.offset, eb.headerBytes)
    let tbBad = outside(ta, tb, traceSkip)
    doAssert tbBad.len == 0, "trace " & $i & " header " & tbBad

proc main*() =
  let tmp = scratchDir("parseseg_twritelikesegd")
  let fmt = sd8058
  let ns = 52

  block rev2_shorter_and_longer:
    let src = tmp / "rev2.sgd"
    put(src, SegdData(records: @[makeRev2(3, fmt, ns)]))
    for n in [20, 80]:
      let dst = tmp / "rev2_" & $n & ".sgd"
      writeLike(src, dst, n)
      rev2Ends(dst, n)
      checkSamples(dst, n, 5, wave(n))
      # GH#2 ext record length (bytes 15-17) and both channel-set end times.
      # Seismic THE samples-per-trace is bytes 8-10 of the extension.
      headerSame(src, dst, [46 .. 48, 100 .. 101, 132 .. 133], [27 .. 29])
      var g = openSeismic(dst)
      doAssert g.traceEntry(0).headerBytes == 20 # aux: no sample-count field
      doAssert not g.log.isFatal, $g.log

  block rev3_shorter_and_longer:
    let src = tmp / "rev3.sgd"
    put(src, SegdData(records: @[makeRev3(fmt, ns)]))
    for n in [20, 80]:
      let dst = tmp / "rev3_" & $n & ".sgd"
      writeLike(src, dst, n)
      rev3Ends(dst, n)
      checkSamples(dst, n, 2, wave(n))
      # GH#2 ext length, GH#3 record/data size, CSD end and sample count.
      # THE sample count is bytes 25-28.
      headerSame(src, dst, [48 .. 51, 72 .. 79, 80 .. 87, 104 .. 107, 108 .. 111],
        [44 .. 47])

  block same_count_is_byte_identical:
    for (name, rec) in [("id2.sgd", makeRev2(3, fmt, ns)), ("id3.sgd", makeRev3(fmt, ns))]:
      let src = tmp / name
      put(src, SegdData(records: @[rec]))
      var f = openSeismic(src)
      let dst = tmp / "out_" & name
      var w = openSeismicWriter(dst, f)
      let x = f.readTraces(0 ..< f.len, float32)
      for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
      doAssert not w.close().isFatal
      doAssert readAll(src) == readAll(dst), name

  block mixed_counts_write_nothing_of_the_record:
    let src = tmp / "mix.sgd"
    put(src, SegdData(records: @[makeRev2(3, fmt, ns)]))
    var f = openSeismic(src)
    var w = openSeismicWriterBytes(f, "mix")
    w.writeTrace(f, 0, wave(20))
    var msg = ""
    try: w.writeTrace(f, 1, wave(21))
    except ValueError as e: msg = e.msg
    doAssert "0" in msg and "20" in msg and "21" in msg, msg
    for i in 1 ..< f.len: w.writeTrace(f, i, wave(20))
    let bytes = w.finishBytes()
    var g = openSeismicBytes(bytes, "mix-out")
    doAssert g.recordCount == 1 and g.len == f.len
    doAssert g.traceEntry(0).numSamples == 20
    doAssert not g.log.isFatal, $g.log
    doAssert g.readTraces(0 ..< g.len, float32)[1, 0] == wave(20)[0]

  block memory_writer_and_a_dropped_refusal:
    let src = tmp / "mem.sgd"
    put(src, SegdData(records: @[makeRev3(fmt, ns)]))
    var f = openSeismic(src)
    block:
      var rev2 = openSeismic(tmp / "rev2.sgd")
      var w = openSeismicWriter(tmp / "drop.sgd", rev2)
      doAssertRaises(ValueError): w.writeTrace(rev2, 0, wave(70000))
    doAssert not fileExists(tmp / "drop.sgd")
    var w = openSeismicWriterBytes(f, "mem")
    let s = wave(10)
    for i in 0 ..< f.len: w.writeTrace(f, i, s)
    var g = openSeismicBytes(w.finishBytes(), "mem-out")
    doAssert g.len == 2 and g.traceEntry(1).numSamples == 10
    doAssert recordLengthUs(g.index.segdRecords[0].gh1,
      g.index.segdRecords[0].gh2Rev3) == 10000

  block incomplete_close_discards_and_keeps_the_message:
    var f = openSeismic(tmp / "rev2.sgd")
    let dst = tmp / "inc.sgd"
    var w = openSeismicWriter(dst, f)
    w.writeTrace(f, 0, wave(20))
    var msg = ""
    try: discard w.close()
    except ValueError as e: msg = e.msg
    doAssert "is incomplete: traces 0..0 of 0..4 were written " &
      "(records are written whole)" in msg, msg
    doAssert not fileExists(dst)

  block written_8015_count_must_be_a_multiple_of_4:
    let src = tmp / "f8015.sgd"
    put(src, SegdData(records: @[makeRev2(1, sd8015, 8)]))
    var f = openSeismic(src)
    block:
      var w = openSeismicWriter(tmp / "bad8015.sgd", f)
      doAssertRaises(ValueError): w.writeTrace(f, 0, wave(6))
    doAssert not fileExists(tmp / "bad8015.sgd")
    let dst = tmp / "ok8015.sgd"
    writeLike(src, dst, 4)
    var g = openSeismic(dst)
    doAssert g.traceEntry(0).numSamples == 4
    doAssert not g.log.isFatal, $g.log

proc makeRev3At(ns, startUs, intervalUs: int): SegdRecordData =
  ## One Rev 3.0 seismic trace. End time is start + ns * interval.
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 7, formatCode: ord(sd8058), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, manufacturerCode: 50,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1)
  let endUs = startUs + ns * intervalUs
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 7, revisionMajor: 3,
    extRecordLength: uint32(max(ns * intervalUs, endUs)), blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
  let seis = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, startTime: int32(startUs), endTime: int32(endUs),
    numSamples: uint32(ns), descaleMultiplier: 1.0, channelsInSet: 1,
    samplingInterval: uint32(intervalUs), traceHeaderExtensions: 1, blockType1: 0x30,
    blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[seis])]
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: ns)
  t.header = SegdTraceHeader(fileNumber: 7, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: 1)
  t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: 7, receiverPointNumber: 1,
    numSamples: uint32(ns), sensorType: 2, groupIndex: 1, blockType: 0x40)
  var vals = newSeq[float64](ns)
  for i in 0 ..< ns: vals[i] = float64(i - 1) * 0.5
  t.samples = newSeq[byte](dataBytes(sd8058, ns))
  encodeSamples(sd8058, vals, t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  result.record = r
  result.traces = @[t]

proc makeRev3Dummy(): SegdRecordData =
  ## One live set (8 samples, 1000 us) and a dummy set (start 500000 us).
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 8, formatCode: ord(sd8058), year: 26,
    additionalGhBlocks: 2, julianDay: 311, hour: 12, manufacturerCode: 50,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 2)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 8, revisionMajor: 3,
    extRecordLength: 8000, blockType: 2)
  r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
  let dummy = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x20, startTime: 500000, endTime: 12345, numSamples: 3,
    descaleMultiplier: 1.0, channelsInSet: 0, samplingInterval: 0,
    traceHeaderExtensions: 1, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  let seis = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 2,
    channelType: 0x10, endTime: 8000, numSamples: 8, descaleMultiplier: 1.0,
    channelsInSet: 1, samplingInterval: 1000, traceHeaderExtensions: 1,
    blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[dummy, seis])]
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 8)
  t.header = SegdTraceHeader(fileNumber: 8, scanTypeNumber: 1, channelSetNumber: 2,
    traceNumber: 1, traceHeaderExtensions: 1)
  t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: 8, receiverPointNumber: 1,
    numSamples: 8, sensorType: 2, groupIndex: 1, blockType: 0x40)
  t.samples = newSeq[byte](dataBytes(sd8058, 8))
  encodeSamples(sd8058, newSeq[float64](8), t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  result.record = r
  result.traces = @[t]

proc makeRev2Dummy(): SegdRecordData =
  ## A 1 ms dummy set (subscan exponent 1) beside a 2 ms seismic set.
  let fmt = sd8058
  let ns = 20
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 2, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 1, manufacturerCode: 9, baseScanInterval16: 32, recordType: 8,
    recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 2)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 2, revisionMajor: 2, revisionMinor: 1,
    extRecordLength: uint32(2 * ns), blockNumber: 2)
  let dummy = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
    startTime: 250, endTime: 500, channelCount: 0, channelType: 1, subscanExponent: 1,
    traceHeaderExtensions: 1)
  let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 2,
    endTime: uint16(ns), channelCount: 1, channelType: 1, subscanExponent: 0,
    traceHeaderExtensions: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[dummy, seis])]
  r.traceCount = 1
  var t = SegdTrace(index: 0, numSamples: ns)
  t.header = SegdTraceHeader(fileNumber: 2, scanTypeNumber: 1, channelSetNumber: 2,
    traceNumber: 1, traceHeaderExtensions: 1)
  t.ext1 = some SegdTraceHeaderExt1(samplesPerTrace: uint32(ns), sensorType: 1)
  t.samples = newSeq[byte](dataBytes(fmt, ns))
  encodeSamples(fmt, newSeq[float64](ns), t.samples)
  result.record = r
  result.traces = @[t]

proc mainThree*() =
  ## Negative Rev 3 starts. Seen failing before the change: start -5000 us,
  ## interval 1000, n=2 raised ValueError "end time of -3000 us does not fit";
  ## start -2000, n=6 wrote a record length of 4000, shorter than the 6000 us
  ## trace.
  let tmp = scratchDir("parseseg_twritelikesegd")
  block rev3_negative_start_is_written_and_the_trace_is_covered:
    let src = tmp / "neg.sgd"
    put(src, SegdData(records: @[makeRev3At(8, -5000, 1000)]))
    let dst = tmp / "neg_out.sgd"
    writeLike(src, dst, 2)
    var g = openSeismic(dst)
    let rec = g.index.segdRecords[0]
    let c = rec.scanTypes[0].descriptorsRev3[0]
    doAssert c.startTime == -5000
    doAssert c.endTime == -3000
    doAssert c.numSamples == 2
    doAssert recordLengthUs(rec.gh1, rec.gh2Rev3) == 2000
    doAssert g.traceEntry(0).numSamples == 2
    doAssert not g.log.isFatal, $g.log
    let later = tmp / "neg2.sgd"
    put(later, SegdData(records: @[makeRev3At(4, -2000, 1000)]))
    let covered = tmp / "neg2_out.sgd"
    writeLike(later, covered, 6)
    var h = openSeismic(covered)
    let hrec = h.index.segdRecords[0]
    let hc = hrec.scanTypes[0].descriptorsRev3[0]
    doAssert hc.endTime == 4000
    doAssert hc.numSamples == 6
    doAssert recordLengthUs(hrec.gh1, hrec.gh2Rev3) == 6000, $recordLengthUs(hrec.gh1,
      hrec.gh2Rev3)
    doAssert not h.log.isFatal, $h.log
    let pos = tmp / "pos.sgd"
    put(pos, SegdData(records: @[makeRev3At(4, 1000, 1000)]))
    let posOut = tmp / "pos_out.sgd"
    writeLike(pos, posOut, 8)
    var p = openSeismic(posOut)
    let prec = p.index.segdRecords[0]
    doAssert prec.scanTypes[0].descriptorsRev3[0].endTime == 9000
    doAssert recordLengthUs(prec.gh1, prec.gh2Rev3) == 9000
    let over = tmp / "over.sgd"
    put(over, SegdData(records: @[makeRev3At(1, 2_000_000_000, 1_000_000)]))
    var f = openSeismic(over)
    block:
      var w = openSeismicWriter(tmp / "over_out.sgd", f)
      doAssertRaises(ValueError): w.writeTrace(f, 0, wave(200))
    doAssert not fileExists(tmp / "over_out.sgd")

  block empty_channel_set_is_left_untouched:
    ## Seen failing before the change: a Rev 3 dummy set with start 500000 us
    ## was given numSamples 8 and its end time was rewritten; a Rev 2 dummy
    ## with subscan exponent 1 refused n=11 for the whole record.
    let src = tmp / "dum3.sgd"
    put(src, SegdData(records: @[makeRev3Dummy()]))
    let dst = tmp / "dum3_out.sgd"
    writeLike(src, dst, 4)
    var g = openSeismic(dst)
    let rec = g.index.segdRecords[0]
    let dummy = rec.scanTypes[0].descriptorsRev3[0]
    let live = rec.scanTypes[0].descriptorsRev3[1]
    doAssert dummy.channelsInSet == 0
    doAssert dummy.startTime == 500000
    doAssert dummy.endTime == 12345
    doAssert dummy.numSamples == 3
    doAssert live.numSamples == 4
    doAssert live.endTime == 4000
    doAssert recordLengthUs(rec.gh1, rec.gh2Rev3) == 4000
    doAssert not g.log.isFatal, $g.log
    let src2 = tmp / "dum2.sgd"
    put(src2, SegdData(records: @[makeRev2Dummy()]))
    let dst2 = tmp / "dum2_out.sgd"
    writeLike(src2, dst2, 11)
    var h = openSeismic(dst2)
    let hrec = h.index.segdRecords[0]
    let hd = hrec.scanTypes[0].descriptors[0]
    let hl = hrec.scanTypes[0].descriptors[1]
    doAssert hd.channelCount == 0
    doAssert hd.startTime == 250
    doAssert hd.endTime == 500
    doAssert hd.subscanExponent == 1
    doAssert hl.endTime == 11
    doAssert hl.startTime == 0
    doAssert hrec.gh2.get.extRecordLength == 22
    doAssert h.traceEntry(0).numSamples == 11
    doAssert not h.log.isFatal, $h.log

proc mainTwo*() =
  let tmp = scratchDir("parseseg_twritelikesegd")
  let fmt = sd8058

  block two_intervals_record_length_is_the_longest:
    var r = SegdRecord(layout: slRev2, format: some(fmt),
      revision: SegdRevision(major: 2, minor: 1))
    r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: ord(fmt), year: 26,
      additionalGhBlocks: 1, manufacturerCode: 9, baseScanInterval16: 32, recordType: 8,
      recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 2,
      skewBlocks: 0, extendedHeaderBlocks: 0, externalHeaderBlocks: 0)
    r.gh2 = some SegdGeneralHeader2(extFileNumber: 1, revisionMajor: 2, revisionMinor: 1,
      extRecordLength: 40, blockNumber: 2)
    var a = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
      endTime: 20, channelCount: 1, channelType: 1, subscanExponent: 0,
      traceHeaderExtensions: 1)
    var b = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 2,
      endTime: 10, channelCount: 1, channelType: 1, subscanExponent: 1,
      traceHeaderExtensions: 1)
    r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[a, b])]
    r.traceCount = 2
    var traces: seq[SegdTrace]
    for k in 0 .. 1:
      var t = SegdTrace(index: k, numSamples: 20)
      t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1,
        channelSetNumber: k + 1, traceNumber: 1, traceHeaderExtensions: 1)
      t.ext1 = some SegdTraceHeaderExt1(samplesPerTrace: 20, sensorType: 1)
      t.samples = newSeq[byte](dataBytes(fmt, 20))
      encodeSamples(fmt, newSeq[float64](20), t.samples)
      traces.add t
    let src = tmp / "two.sgd"
    put(src, SegdData(records: @[SegdRecordData(record: r, traces: traces)]))
    let dst = tmp / "two_out.sgd"
    writeLike(src, dst, 10)
    var g = openSeismic(dst)
    let rec = g.index.segdRecords[0]
    doAssert rec.scanTypes[0].descriptors[0].endTime == 10 # 2 ms * 10
    doAssert rec.scanTypes[0].descriptors[1].endTime == 5  # 1 ms * 10
    doAssert rec.scanTypes[0].descriptors[0].startTime == 0
    doAssert rec.gh2.get.extRecordLength == 20
    doAssert g.traceEntry(0).numSamples == 10 and g.traceEntry(1).numSamples == 10

  block odd_count_does_not_fit_a_1_ms_interval:
    var f = openSeismic(tmp / "two.sgd")
    block:
      var w = openSeismicWriter(tmp / "odd.sgd", f)
      doAssertRaises(ValueError): w.writeTrace(f, 0, wave(11))
    doAssert not fileExists(tmp / "odd.sgd")

  block short_bcd_fits_and_overflow_uses_fff:
    var r = SegdRecord(layout: slRev2, format: some(fmt),
      revision: SegdRevision(major: 2, minor: 1))
    r.gh1 = SegdGeneralHeader1(fileNumber: 4, formatCode: ord(fmt), year: 26,
      additionalGhBlocks: 1, manufacturerCode: 9, baseScanInterval16: 32, recordType: 8,
      recordLength: 10, scanTypesPerRecord: 1, channelSetsPerScanType: 1)
    r.gh2 = some SegdGeneralHeader2(extFileNumber: 4, revisionMajor: 2, revisionMinor: 1,
      extRecordLength: 0, blockNumber: 2, lineSequenceNumber: 9)
    let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
      endTime: 512, channelCount: 1, channelType: 1, traceHeaderExtensions: 1)
    r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[seis])]
    r.traceCount = 1
    var t = SegdTrace(index: 0, numSamples: 512)
    t.header = SegdTraceHeader(fileNumber: 4, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: 1, traceHeaderExtensions: 1)
    t.ext1 = some SegdTraceHeaderExt1(samplesPerTrace: 512, sensorType: 1)
    t.samples = newSeq[byte](dataBytes(fmt, 512))
    encodeSamples(fmt, newSeq[float64](512), t.samples)
    let src = tmp / "bcd.sgd"
    put(src, SegdData(records: @[SegdRecordData(record: r, traces: @[t])]))
    let fit = tmp / "bcd_fit.sgd"
    writeLike(src, fit, 256)
    var g = openSeismic(fit)
    let rec = g.index.segdRecords[0]
    doAssert rec.gh1.recordLength == 5 # 512 ms = 5 × 102.4 ms
    doAssert rec.gh1.recordType == 8
    doAssert rec.gh2.get.extRecordLength == 0 # source used the short field
    doAssert rec.scanTypes[0].descriptors[0].endTime == 256
    let over = tmp / "bcd_over.sgd"
    writeLike(src, over, 100) # 200 ms is not a tenth of 1.024 s
    var h = openSeismic(over)
    let orec = h.index.segdRecords[0]
    doAssert orec.gh1.recordLength == BcdAllF
    doAssert orec.gh1.recordType == 8
    doAssert orec.gh2.get.extRecordLength == 200
    doAssert orec.scanTypes[0].descriptors[0].endTime == 100

proc mainFour*() =
  ## Conversion to 8015 checks the count that is written, not the source's.
  ## Seen failing before the change: opening the writer on a 6-sample source
  ## raised ValueError before any trace was written.
  let tmp = scratchDir("parseseg_twritelikesegd")
  let src = tmp / "src6.sgd"
  put(src, SegdData(records: @[makeRev2(1, sd8058, 6)]))
  var f = openSeismic(src)
  doAssert f.traceEntry(0).numSamples == 6
  let dst = tmp / "to8015.sgd"
  var w = openSeismicWriter(dst, f, segdFormat = tf8015)
  let s = wave(4)
  for i in 0 ..< f.len: w.writeTrace(f, i, s)
  doAssert not w.close().isFatal
  var g = openSeismic(dst)
  doAssert g.index.segdRecords[0].format.get == sd8015
  doAssert g.traceEntry(0).numSamples == 4
  doAssert g.index.segdRecords[0].gh2.get.extRecordLength == 8
  doAssert not g.log.isFatal, $g.log
  let bad = tmp / "to8015bad.sgd"
  block:
    var w2 = openSeismicWriter(bad, f, segdFormat = tf8015)
    doAssertRaises(ValueError): w2.writeTrace(f, 0, wave(6))
  doAssert not fileExists(bad)

proc mainFive*() =
  ## A new sample count of 0 is refused before any record byte is written.
  ## Seen failing before the change: the write succeeded, and a short-form
  ## record length became BCD 000 (indeterminate, not 0 ms).
  let tmp = scratchDir("parseseg_twritelikesegd")
  let fmt = sd8058
  let src = tmp / "z.sgd"
  put(src, SegdData(records: @[makeRev2(1, fmt, 8)]))
  var f = openSeismic(src)
  block:
    var w = openSeismicWriter(tmp / "z_out.sgd", f)
    doAssertRaises(ValueError): w.writeTrace(f, 0, wave(0))
  doAssert not fileExists(tmp / "z_out.sgd")
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 4, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 1, manufacturerCode: 9, baseScanInterval16: 32, recordType: 8,
    recordLength: 10, scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 4, revisionMajor: 2, revisionMinor: 1,
    extRecordLength: 0, blockNumber: 2)
  let seis = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
    endTime: 8, channelCount: 1, channelType: 1, traceHeaderExtensions: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[seis])]
  r.traceCount = 1
  var t = SegdTrace(index: 0, numSamples: 8)
  t.header = SegdTraceHeader(fileNumber: 4, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: 1)
  t.ext1 = some SegdTraceHeaderExt1(samplesPerTrace: 8, sensorType: 1)
  t.samples = newSeq[byte](dataBytes(fmt, 8))
  encodeSamples(fmt, newSeq[float64](8), t.samples)
  let bcd = tmp / "zbcd.sgd"
  put(bcd, SegdData(records: @[SegdRecordData(record: r, traces: @[t])]))
  var b = openSeismic(bcd)
  doAssert b.index.segdRecords[0].gh1.recordLength == 10
  block:
    var w = openSeismicWriter(tmp / "zbcd_out.sgd", b)
    doAssertRaises(ValueError): w.writeTrace(b, 0, wave(0))
  doAssert not fileExists(tmp / "zbcd_out.sgd")
  let src3 = tmp / "z3.sgd"
  put(src3, SegdData(records: @[makeRev3(fmt, 8)]))
  var g = openSeismic(src3)
  block:
    var w = openSeismicWriter(tmp / "z3_out.sgd", g)
    doAssertRaises(ValueError): w.writeTrace(g, 0, wave(0))
  doAssert not fileExists(tmp / "z3_out.sgd")

proc makeTwoCounts(): SegdRecordData =
  ## Two channel sets, 8 and 12 samples, each with one trace.
  let fmt = sd8058
  var r = SegdRecord(layout: slRev2, format: some(fmt),
    revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 9, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 1, manufacturerCode: 9, baseScanInterval16: 32, recordType: 8,
    recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 2)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 9, revisionMajor: 2, revisionMinor: 1,
    extRecordLength: 24, blockNumber: 2)
  let a = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1,
    endTime: 8, channelCount: 1, channelType: 1, traceHeaderExtensions: 1)
  let b = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 2,
    endTime: 12, channelCount: 1, channelType: 1, traceHeaderExtensions: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[a, b])]
  r.traceCount = 2
  let counts = [8, 12]
  for k in 0 .. 1:
    let ns = counts[k]
    var t = SegdTrace(index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: 9, scanTypeNumber: 1,
      channelSetNumber: k + 1, traceNumber: 1, traceHeaderExtensions: 1)
    t.ext1 = some SegdTraceHeaderExt1(samplesPerTrace: uint32(ns), sensorType: 1)
    var vals = newSeq[float64](ns)
    for i in 0 ..< ns: vals[i] = float64((i mod 5) - 2) * 0.25
    t.samples = newSeq[byte](dataBytes(fmt, ns))
    encodeSamples(fmt, vals, t.samples)
    result.traces.add t
  result.record = r

proc mainSix*() =
  ## Traces written with their own source counts are accepted when channel
  ## sets differ. The api.md sentence is what was missing.
  let tmp = scratchDir("parseseg_twritelikesegd")
  let src = tmp / "sets.sgd"
  put(src, SegdData(records: @[makeTwoCounts()]))
  var f = openSeismic(src)
  doAssert f.traceEntry(0).numSamples == 8
  doAssert f.traceEntry(1).numSamples == 12
  let dst = tmp / "sets_out.sgd"
  var w = openSeismicWriter(dst, f)
  let x = f.readTraces(0 ..< f.len, float32)
  for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
  doAssert not w.close().isFatal
  doAssert readAll(src) == readAll(dst)
  var g = openSeismic(dst)
  doAssert g.traceEntry(0).numSamples == 8
  doAssert g.traceEntry(1).numSamples == 12
  doAssert g.index.segdRecords[0].scanTypes[0].descriptors[0].endTime == 8
  doAssert g.index.segdRecords[0].scanTypes[0].descriptors[1].endTime == 12
  let api = readFile(currentSourcePath().parentDir.parentDir / "docs" / "api.md")
  doAssert "own source count" in api, "docs/api.md does not state the own-count exception"
  doAssert "channel sets differ" in api


proc makeSubsetRec(rev3: bool, ns: int, nA = 3, nB = 2, skew = false,
    numbered = false): SegdRecordData =
  ## Two channel sets, `nA` and `nB` traces (set 1: traces 0..2, set 2: 3..4), each
  ## trace with its header extension and 32 more bytes of its own; an extended
  ## header. Rev 2: set 2 has a 1 ms interval, set 1 2 ms. Rev 3: both 1 ms.
  let fmt = sd8058
  var r = SegdRecord(layout: (if rev3: slRev3 else: slRev2), format: some(fmt),
    revision: SegdRevision(major: (if rev3: 3 else: 2), minor: (if rev3: 0 else: 1)))
  r.gh1 = SegdGeneralHeader1(fileNumber: 12, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: (if rev3: 2 else: 1), julianDay: 311, manufacturerCode: 9,
    baseScanInterval16: (if rev3: 16 else: 32), recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 2, extendedHeaderBlocks: 1)
  r.extended = newSeq[byte](32)
  for i in 0 ..< 32: r.extended[i] = byte(90 + i)
  if rev3:
    r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 12, revisionMajor: 3,
      extRecordLength: uint32(1000 * ns), blockType: 2)
    r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
    var sets: seq[SegdChannelSetDescriptorRev3]
    for k in 1 .. 2:
      sets.add SegdChannelSetDescriptorRev3(scanTypeNumber: 1,
        channelSetNumber: uint16(if numbered: 5 + 2 * k else: k),
        channelType: 0x10, endTime: int32(1000 * ns), numSamples: uint32(ns),
        descaleMultiplier: 0.25, channelsInSet: uint32(if k == 1: nA else: nB),
        samplingInterval: 1000,
        traceHeaderExtensions: 2, blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)
    r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: sets)]
  else:
    r.gh2 = some SegdGeneralHeader2(extFileNumber: 12, revisionMajor: 2, revisionMinor: 1,
      extRecordLength: uint32(2 * ns), blockNumber: 2)
    var sets: seq[SegdChannelSetDescriptor]
    for k in 1 .. 2:
      sets.add SegdChannelSetDescriptor(scanTypeNumber: 1,
        channelSetNumber: (if numbered: 5 + 2 * k else: k),
        endTime: uint16(if k == 1: ns else: ns div 2), channelCount: (if k == 1: nA else: nB),
        channelType: 1, traceHeaderExtensions: 2, subscanExponent: k - 1)
    r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: sets)]
    if skew:
      r.gh1.skewBlocks = (nA + 2 * nB + 31) div 32
      var b = newSeq[byte](32 * r.gh1.skewBlocks)
      for i in 0 ..< nA + 2 * nB: b[i] = byte(100 + i)
      r.scanTypes[0].skew = b
  r.traceCount = nA + nB
  var traces: seq[SegdTrace]
  for k in 0 ..< nA + nB:
    let set = if k < nA: 1 else: 2
    let setNo = if numbered: 5 + 2 * set else: set
    var t = SegdTrace(layout: r.layout, index: k, numSamples: ns)
    t.header = SegdTraceHeader(fileNumber: 12, scanTypeNumber: 1, channelSetNumber: setNo,
      traceNumber: k + 1, traceHeaderExtensions: 2'u8)
    if rev3:
      t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: 7,
        receiverPointNumber: int32(100 + k), numSamples: uint32(ns), sensorType: 2,
        groupIndex: 1, blockType: 0x40)
    else:
      t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000,
        receiverPointNumber: int32(100 + k), receiverPointIndex: 1,
        samplesPerTrace: uint32(ns), sensorType: 2)
    t.extensions = newSeq[byte](32)
    for i in 0 ..< 32: t.extensions[i] = byte(17 * k + i)
    var vals = newSeq[float64](ns)
    for i in 0 ..< ns: vals[i] = float64((i * (k + 2)) mod 11 - 5) * 0.125
    t.samples = newSeq[byte](dataBytes(fmt, ns))
    encodeSamples(fmt, vals, t.samples)
    traces.add t
  if rev3: computeRev3Sizes(r, traces)
  result.record = r
  result.traces = traces

proc setOfTrace(k: int): int = (if k < 3: 0 else: 1)

proc feedSubset(w: var SeismicWriter, f: SeismicFile, x: Tensor[float32], kept: openArray[int],
    counts: array[2, int]) =
  w.startSubset(f, kept)
  for k in kept: w.writeTrace(f, k, x, k, counts[setOfTrace(k)])

func endUnits(rev3: bool, set, n: int): int64 =
  ## A channel set's end time for `n` samples: microseconds (Rev 3) or 2 ms units
  ## (Rev 2, where set 2 samples at 1 ms).
  if rev3: 1000'i64 * n elif set == 0: int64(n) else: int64(n div 2)

proc checkSubset(g: SeismicFile, f: SeismicFile, x: Tensor[float32], first: int,
    kept: openArray[int], counts: array[2, int], chans: array[2, int]) =
  ## The output record whose traces start at trace `first` of `g`.
  let rec = g.index.segdRecords[g.traceEntry(first).record]
  doAssert rec.extended == f.index.segdRecords[0].extended
  let rev3 = rec.layout == slRev3
  var longest = 0'i64
  for j in 0 .. 1:
    let end1 = endUnits(rev3, j, counts[j])
    if rev3:
      let c = rec.scanTypes[0].descriptorsRev3[j]
      doAssert int(c.channelsInSet) == chans[j]
      if chans[j] > 0:
        doAssert int64(c.endTime) == end1 and int(c.numSamples) == counts[j]
    else:
      let c = rec.scanTypes[0].descriptors[j]
      doAssert c.channelCount == chans[j]
      if chans[j] > 0: doAssert int64(c.endTime) == end1
    if chans[j] > 0: longest = max(longest, end1)
  if rev3: doAssert int64(recordLengthUs(rec.gh1, rec.gh2Rev3)) == longest
  else: doAssert int64(recordLengthMs(rec.gh1, rec.gh2.get)) == 2 * longest
  var bytes = int64(rec.headerBytes)
  for i, k in kept:
    let eo = g.traceEntry(first + i)
    let ei = f.traceEntry(k)
    doAssert eo.record == g.traceEntry(first).record
    let n = counts[setOfTrace(k)]
    doAssert eo.numSamples == uint32(n)
    bytes += int64(eo.headerBytes) + int64(dataBytes(sd8058, n))
    let y = g.readTraces(first + i ..< first + i + 1, float32)
    for q in 0 ..< n: doAssert y[0, q] == x[k, q], "trace " & $k & " sample " & $q
    doAssert eo.headerBytes == ei.headerBytes
    let ho = g.copyBytes(eo.offset, eo.headerBytes)
    let hi = f.copyBytes(ei.offset, ei.headerBytes)
    # The trace header and the bytes after THE#1 stay; THE#1 keeps all but its count.
    doAssert ho[0 ..< 20] == hi[0 ..< 20]
    doAssert ho[52 ..< ho.len] == hi[52 ..< hi.len]
    var diff = 0
    for q in 20 ..< 52:
      if ho[q] != hi[q]: inc diff
    if n == int(ei.numSamples): doAssert diff == 0 else: doAssert diff in 1 .. 4
  if rev3: doAssert int64(rec.gh3.dataSize) == bytes

proc mainSeven*() =
  ## A `like:` SEG-D writer writes records made of some traces of one source
  ## record (`startSubset`), each channel set with its own sample count.
  ## Seen failing: with the channel counts left as the source's, with the
  ## record length left as the source's, with the Rev 3 sizes left as the
  ## source's, and with the order check removed.
  let tmp = scratchDir("parseseg_twritelikesegd")
  for rev3 in [false, true]:
    let nm = if rev3: "sub3" else: "sub2"
    let src = tmp / (nm & ".sgd")
    put(src, SegdData(records: @[makeSubsetRec(rev3, 8)]))
    var f = openSeismic(src)
    doAssert not f.log.isFatal, $f.log
    let x = f.readTraces(0 ..< f.len, float32)
    let dst = tmp / (nm & "_out.sgd")
    var w = openSeismicWriter(dst, f)
    let a = [1, 2, 4]
    let b = [0, 3]
    let c = [3, 4]
    w.feedSubset(f, x, a, [4, 4]) # shorter in both sets
    w.feedSubset(f, x, b, [6, 8]) # trace 3 used again; set 2 keeps its count
    w.feedSubset(f, x, c, [8, 6]) # set 1 left empty
    doAssert not w.close().isFatal
    var g = openSeismic(dst)
    doAssert not g.log.isFatal, $g.log
    doAssert g.len == 7 and g.index.segdRecords.len == 3
    g.checkSubset(f, x, 0, a, [4, 4], [2, 1])
    g.checkSubset(f, x, 3, b, [6, 8], [1, 1])
    g.checkSubset(f, x, 5, c, [8, 6], [0, 2])
    # Errors: nothing of the output is installed.
    let bad = tmp / (nm & "_bad.sgd")
    let two = tmp / (nm & "_two.sgd")
    put(two, SegdData(records: @[makeSubsetRec(rev3, 8), makeSubsetRec(rev3, 8)]))
    var h = openSeismic(two)
    var v = openSeismicWriter(bad, f)
    let none: seq[int] = @[]
    doAssertRaises(ValueError): v.startSubset(f, none)
    doAssertRaises(ValueError): v.startSubset(f, [1, 5])
    doAssertRaises(ValueError): v.startSubset(f, [-1])
    doAssertRaises(ValueError): v.startSubset(f, [2, 1])
    doAssertRaises(ValueError): v.startSubset(f, [1, 1])
    var v2 = openSeismicWriter(bad, h)
    doAssertRaises(ValueError): v2.startSubset(h, [1, 6]) # the second record
    # Traces of one set with two counts.
    block:
      var e = openSeismicWriter(bad, f)
      e.startSubset(f, [0, 1])
      e.writeTrace(f, 0, x, 0, 8)
      doAssertRaises(ValueError): e.writeTrace(f, 1, x, 1, 6)
    # Out of order, past the subset, and a count of 0 or one the revision cannot hold.
    var e = openSeismicWriter(bad, f)
    e.startSubset(f, [1, 2])
    doAssertRaises(ValueError): e.writeTrace(f, 2, x, 2, 8) # not its first
    e.writeTrace(f, 1, x, 1, 8)
    doAssertRaises(ValueError): e.startSubset(f, [0]) # the record is incomplete
    e.writeTrace(f, 2, x, 2, 8)
    doAssertRaises(ValueError): e.writeTrace(f, 2, x, 2, 8)
    e.startSubset(f, [0, 1, 2])
    e.writeTrace(f, 0, x, 0, 8)
    doAssertRaises(ValueError): e.writeTrace(f, 2, x, 2, 8) # 1 comes next
    e.writeTrace(f, 1, x, 1, 8)
    e.writeTrace(f, 2, x, 2, 8)
    e.startSubset(f, [3])
    if rev3:
      doAssertRaises(ValueError): e.writeTrace(f, 3, wave(3_000_000)) # end past 2^31 µs
    else:
      doAssertRaises(ValueError): e.writeTrace(f, 3, x, 3, 5) # not a multiple of 2 ms
    e.startSubset(f, [3]) # a refused first trace leaves no record
    doAssertRaises(ValueError): e.writeTrace(f, 3, x, 3, 0)
    e.startSubset(f, [3])
    e.writeTrace(f, 3, x, 3, 8)
    doAssert not e.close().isFatal
    var u = openSeismicWriter(tmp / (nm & "_inc.sgd"), f)
    u.startSubset(f, [1, 2])
    u.writeTrace(f, 1, x, 1, 8)
    doAssertRaises(ValueError): discard u.close()
    doAssert not fileExists(tmp / (nm & "_inc.sgd"))

proc mainEight*() =
  ## Subset records, the finer points: a whole record after a subset, a refused
  ## first trace, `abandonRecord`, a pending subset, extended recording mode, a
  ## Rev 3 set that starts at a negative time, Rev 2 skew bytes, set names.
  ## Seen failing: the whole record after a subset was refused ("all traces of
  ## its subset are written"); a refused first trace left the writer stuck and
  ## `close` discarded the output; `close` with a pending subset wrote nothing
  ## and raised nothing; the record length of the negative start was 6000, not
  ## 8000; the skew bytes were the source's 100 and the blocks 4; a set was
  ## named by its index, not its number.
  let tmp = scratchDir("parseseg_twritelikesegd")
  for rev3 in [false, true]:
    let nm = if rev3: "fine3" else: "fine2"
    let src = tmp / (nm & ".sgd")
    put(src, SegdData(records: @[makeSubsetRec(rev3, 8)]))
    var f = openSeismic(src)
    let x = f.readTraces(0 ..< f.len, float32)
    # (1) a whole record after a finished subset
    block:
      var w = openSeismicWriter(tmp / (nm & "_whole.sgd"), f)
      w.feedSubset(f, x, [1, 2], [4, 4])
      for k in 0 ..< f.len: w.writeTrace(f, k, x, k)
      doAssert not w.close().isFatal
      var g = openSeismic(tmp / (nm & "_whole.sgd"))
      doAssert g.len == 7 and g.index.segdRecords.len == 2
      g.checkSubset(f, x, 0, [1, 2], [4, 4], [2, 0])
      doAssert readAll(tmp / (nm & "_whole.sgd")).len > 0
    # (2) a refused first trace, then a good subset; abandonRecord
    block:
      let out2 = tmp / (nm & "_skip.sgd")
      var w = openSeismicWriter(out2, f)
      w.feedSubset(f, x, [0], [8, 8])
      w.startSubset(f, [3])
      if rev3:
        doAssertRaises(ValueError): w.writeTrace(f, 3, wave(3_000_000))
      else:
        doAssertRaises(ValueError): w.writeTrace(f, 3, x, 3, 5)
      w.feedSubset(f, x, [1, 2], [8, 8])
      w.startSubset(f, [0, 1])
      w.writeTrace(f, 0, x, 0)
      w.abandonRecord()
      doAssert w.len == 3
      w.feedSubset(f, x, [4], [8, 8])
      doAssert not w.close().isFatal
      var g = openSeismic(out2)
      doAssert g.len == 4 and g.index.segdRecords.len == 3
      g.checkSubset(f, x, 0, [0], [8, 8], [1, 0])
      g.checkSubset(f, x, 1, [1, 2], [8, 8], [2, 0])
      g.checkSubset(f, x, 3, [4], [8, 8], [0, 1])
    # (6) a pending subset: another startSubset and close both refuse
    block:
      var w = openSeismicWriter(tmp / (nm & "_pend.sgd"), f)
      w.startSubset(f, [0])
      doAssertRaises(ValueError): w.startSubset(f, [1])
      w.abandonRecord()
      w.startSubset(f, [0])
      w.writeTrace(f, 0, x, 0)
      doAssert not w.close().isFatal
      var v = openSeismicWriter(tmp / (nm & "_pend2.sgd"), f)
      v.startSubset(f, [0])
      doAssertRaises(ValueError): discard v.close()
      doAssert not fileExists(tmp / (nm & "_pend2.sgd"))
    # (8) a set is named by its own numbers
    block:
      let p = tmp / (nm & "_num.sgd")
      put(p, SegdData(records: @[makeSubsetRec(rev3, 8, numbered = true)]))
      var h = openSeismic(p)
      var w = openSeismicWriter(tmp / (nm & "_num_out.sgd"), h)
      w.startSubset(h, [3, 4])
      let y = h.readTraces(0 ..< h.len, float32)
      w.writeTrace(h, 3, y, 3)
      var msg = ""
      try: w.writeTrace(h, 4, y, 4, 6)
      except ValueError: msg = getCurrentExceptionMsg()
      doAssert "channel set 9 of scan type 1" in msg, msg
  # (4) Rev 3 extended recording mode
  block:
    var d = makeSubsetRec(true, 8)
    d.record.gh3.extendedRecordingMode = 1
    d.record.gh1.recordLength = 0
    d.record.gh2Rev3.extRecordLength = 0
    for c in d.record.scanTypes[0].descriptorsRev3.mitems: c.endTime = 0
    let p = tmp / "erm.sgd"
    put(p, SegdData(records: @[d]))
    var f = openSeismic(p)
    var w = openSeismicWriter(tmp / "erm_out.sgd", f)
    var msg = ""
    try: w.startSubset(f, [0])
    except ValueError: msg = getCurrentExceptionMsg()
    doAssert "extended recording mode" in msg, msg
  # (5) a Rev 3 set that starts at a negative time keeps the span of its traces
  block:
    var d = makeSubsetRec(true, 8)
    for c in d.record.scanTypes[0].descriptorsRev3.mitems:
      c.startTime = -2000
      c.endTime = 6000
    d.record.gh2Rev3.extRecordLength = 8000
    let p = tmp / "neg.sgd"
    put(p, SegdData(records: @[d]))
    var f = openSeismic(p)
    let x = f.readTraces(0 ..< f.len, float32)
    var w = openSeismicWriter(tmp / "neg_out.sgd", f)
    w.feedSubset(f, x, [0], [8, 8]) # set 2 emptied, own count
    w.feedSubset(f, x, [0], [6, 8]) # a new count: 6000 µs of samples, end 4000
    doAssert not w.close().isFatal
    var g = openSeismic(tmp / "neg_out.sgd")
    let a = g.index.segdRecords[0]
    let b = g.index.segdRecords[1]
    doAssert a.gh2Rev3.extRecordLength == 8000
    doAssert b.gh2Rev3.extRecordLength == 6000
    doAssert b.scanTypes[0].descriptorsRev3[0].endTime == 4000
  # (7) Rev 2 skew bytes follow the kept channels
  block:
    let p = tmp / "skew.sgd"
    put(p, SegdData(records: @[makeSubsetRec(false, 8, 40, 30, skew = true)]))
    var f = openSeismic(p)
    doAssert f.index.segdRecords[0].gh1.skewBlocks == 4
    let x = f.readTraces(0 ..< f.len, float32)
    var w = openSeismicWriter(tmp / "skew_out.sgd", f)
    w.startSubset(f, [0, 1, 40])
    for k in [0, 1, 40]: w.writeTrace(f, k, x, k)
    w.startSubset(f, [1, 41])
    for k in [1, 41]: w.writeTrace(f, k, x, k)
    doAssert not w.close().isFatal
    var g = openSeismic(tmp / "skew_out.sgd")
    doAssert not g.log.isFatal, $g.log
    let r0 = g.index.segdRecords[0]
    let r1 = g.index.segdRecords[1]
    doAssert r0.gh1.skewBlocks == 1 and r0.scanTypes[0].skew.len == 32
    doAssert r0.scanTypes[0].skew[0 .. 4] == @[100'u8, 101, 140, 170, 0]
    doAssert r1.scanTypes[0].skew[0 .. 4] == @[101'u8, 141, 171, 0, 0]

main()
mainTwo()
mainThree()
mainFour()
mainFive()
mainSix()
mainSeven()
mainEight()
