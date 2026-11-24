## Exact sample-0 time and where `TraceKeys.time` came from.
##
## A stored sub-second of 500000 us with a float fraction below 0.5 was
## taken as a crossed second, so `firstSampleUs` was 1000000 us early
## (SEG-Y rev 2, 2024-01-01 00:00:00, Ext1 nanoseconds 499999500, delay 0).
##
## A write from keys stored time zero in the SEG-D Rev 3 Timestamp block,
## so a trace with `t0Ms` 2.5 read back 2500 us early.
##
## The generic reader and the index walk must agree on `firstSampleUs`.
## Skipping `noteRecordedTime` in `noteHeaderClock` left the origin
## unrecorded, so sample 0 was missing (SEG-Y rev 2, 2024-01-01, Ext1
## nanoseconds 1234567, delay 4 ms).
##
## A second write of re-read `toFirstSample` keys stored GH#3 as
## `keys.time` (sample 0, T+d) instead of time zero T. With T =
## 1700000020.125 and d = -20.125 ms, that moved GH#3 by -20125 us.
## Reverting `ghTimeZeroGpsUs` to `unixToTimestamp(recTime)` fails
## `record_time_zero_stable` on the GH#3 bytes and `recordTimeZeroUs`.
## Returning none from `recordTimeZeroUs` fails that block and the
## Rev 2 and SEG-Y blocks.

import std/[assertions, math, options, times]

import parseSEG

import parseSEG/io/[memsink, memsource]

import parseSEG/common/years

proc keysOf(b: seq[byte], name: string): TraceKeys =
  var f = openSeismicBytes(b, name, keys = true)
  doAssert f.len == 1
  doAssert f.log.count(sevError) == 0
  result = f.traceKeys(0)
  f.close()

proc rev3File(stamp: int64, startUs: int32, withStamp: bool,
    gh3Us = utcUsToGpsUs(1_700_000_000_000_000'i64)): seq[byte] =
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  let the = uint8(1 + ord(withStamp))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 2, julianDay: 1, hour: 0, minute: 0, second: 0,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1, manufacturerCode: 9)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3,
    revisionMinor: 0, extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: gh3Us, blockType: BlockTypeGeneralHeader3)
  var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, startTime: startUs, endTime: startUs + 1000, numSamples: 1,
    descaleMultiplier: 1.0, channelsInSet: 1, samplingInterval: 1000, arrayForming: 1,
    traceHeaderExtensions: the, verticalStack: 1, blockType1: BlockTypeChannelSet1,
    blockType2: BlockTypeChannelSet2, blockType3: BlockTypeChannelSet3)
  for i in 0 ..< d.description.len: d.description[i] = ' '
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[d])]
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: the)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(receiverLineNumber: 100,
    receiverPointNumber: 200, receiverPointIndex: 1, numSamples: 1, sensorType: 1,
    depthIndex: 1, blockType: BlockTypeTraceHeaderExt1))
  if withStamp:
    var ts = SegdTimestampHeader(timeZeroOfData: stamp, blockType: 0x42)
    let raw = ts.encoded
    t.extensions = @raw
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  let sink = openMemSink("r3")
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(r)
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.takeBytes()

proc rev2File(year = 24, julian = 1, hour = 0, minute = 0, second = 0): seq[byte] =
  var r = SegdRecord(layout: slRev2, format: some(sd8058),
    revision: SegdRevision(major: 2, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: year,
    additionalGhBlocks: 1, julianDay: julian, hour: hour, minute: minute, second: second,
    manufacturerCode: 9, baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 1, revisionMajor: 2, revisionMinor: 0,
    extRecordLength: 1000, blockNumber: 2)
  let c = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 1,
    endTime: 2, channelCount: 1, channelType: 1, gainControl: 1, traceHeaderExtensions: 0,
    verticalStack: 1, arrayForming: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[c])]
  r.traceCount = 1
  var t = SegdTrace(index: 0, numSamples: 1)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1)
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  var d = SegdData()
  d.records.add SegdRecordData(record: r, traces: @[t])
  let sink = openMemSink("r2")
  doAssert writeSegd(sink, d).count(sevError) == 0
  sink.takeBytes()

proc segyFile(rev: int, delay: int16, ns: int32, basis: int16, hasNs: bool): seq[byte] =
  var f = SegyFile(text: initTextHeader(teEbcdic), byteOrder: boBig, format: some(sfFloat32),
    revision: SegyRevision(major: uint8(rev)), extended: initExtendedTextHeader())
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: uint8(rev), samplesPerTrace: 4,
    sampleInterval: 1000, measurementSystem: 1)
  if rev >= 2:
    f.binary.segyMinor = 1
    f.binary.maxAddlTraceHeaders = 1
    f.binary.byteOrderMarker = ByteOrderMarker
    f.binary.timeBasisCode = basis
  let sink = openMemSink("sy")
  var w = openSegyWriter(sink, f, initSegyWriteOptions(f, lenient = true))
  var t = SegyTrace(numSamples: 4, sampleInterval: 1000, samples: newSeq[byte](16))
  t.header = SegyTraceHeader(fieldRecord: 10, traceNumberInField: 1, traceSeqFile: 1,
    numSamples: 4, sampleInterval: 1000, year: 2024, dayOfYear: 1, hour: 0, minute: 0,
    second: 0, timeBasisCode: basis, delayRecordingTime: delay, traceIdCode: 1)
  if hasNs:
    t.hasExt1 = true
    t.ext1 = initTraceHeaderExt1()
    t.ext1.nanoseconds = ns
    t.ext1.numAddlTraceHeaders = 1
    t.ext1.extNumSamples = 4
  w.writeTrace(t)
  w.close()
  sink.takeBytes()

proc nearest(ns: int64): int64 = int64(round(float64(ns) / 1000.0))

proc halfSecondNs(): seq[int32] =
  # 499990000..500010000 step 10, plus the ends the fraction can sit on.
  result = newSeqOfCap[int32](2004)
  var ns = 499_990_000
  while ns <= 500_010_000:
    result.add int32(ns)
    inc ns, 10
  result.add 0
  result.add 1
  result.add 999_999_999

proc segyNsFile(basis: int16, counts: openArray[int32]): seq[byte] =
  var f = SegyFile(text: initTextHeader(teEbcdic), byteOrder: boBig, format: some(sfFloat32),
    revision: SegyRevision(major: 2), extended: initExtendedTextHeader())
  f.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 2, segyMinor: 1, samplesPerTrace: 4,
    sampleInterval: 1000, measurementSystem: 1, maxAddlTraceHeaders: 1,
    byteOrderMarker: ByteOrderMarker, timeBasisCode: basis)
  let sink = openMemSink("ns")
  var w = openSegyWriter(sink, f, initSegyWriteOptions(f, lenient = true))
  for i, ns in counts:
    var t = SegyTrace(numSamples: 4, sampleInterval: 1000, samples: newSeq[byte](16))
    t.header = SegyTraceHeader(fieldRecord: 10, traceNumberInField: int32(i + 1),
      traceSeqFile: int32(i + 1), numSamples: 4, sampleInterval: 1000, year: 2024,
      dayOfYear: 1, hour: 0, minute: 0, second: 0, timeBasisCode: basis,
      delayRecordingTime: 0, traceIdCode: 1)
    t.hasExt1 = true
    t.ext1 = initTraceHeaderExt1()
    t.ext1.nanoseconds = ns
    t.ext1.numAddlTraceHeaders = 1
    t.ext1.extNumSamples = 4
    w.writeTrace(t)
  w.close()
  sink.takeBytes()

proc expectFirstUs(k: TraceKeys): int64 =
  if k.timeOrigin != toNone: return k.firstSampleUs.get
  int64(round(k.time * 1e6)) + int64(round(k.t0Ms * 1000.0))

proc keysAt(origin: TimeOrigin, t0: float64): TraceKeys =
  const Shot = 1_700_000_000.0
  result = initTraceKeys()
  result.time = Shot
  result.t0Ms = t0
  if origin != toNone: result.noteRecordedTime(origin, int64(Shot * 1e6))

proc keysAll(b: seq[byte], name: string): seq[TraceKeys] =
  var f = openSeismicBytes(b, name, keys = true)
  doAssert f.log.count(sevError) == 0
  result = newSeq[TraceKeys](f.len)
  for i in 0 ..< f.len: result[i] = f.traceKeys(i)
  f.close()

proc writeKeys(rows: openArray[TraceKeys]): seq[TraceKeys] =
  var w = openSeismicWriterBytes(SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1))
  for i, k in rows:
    var t = k
    t.record = float64(i + 1)
    w.writeTrace(t, [1'f32])
  result = keysAll(w.finishBytes(), "wd")

proc main*() =
  let civil = daysFromCivil(2024, 1, 1) * 86400

  block both_segy_key_paths:
    # keysOf walks raw header bytes; traceKeys re-encodes the decoded header.
    let ns = 1_234_567'i32
    let b = segyFile(2, 4, ns, 4, true)
    let rawK = keysOf(b, "rawpath")
    var src = openMemorySource(b, "genpath")
    var full = openSegy(src, headersOnly = true)
    doAssert full.log.count(sevError) == 0
    var ft: SegyTrace
    doAssert full.readTrace(ft)
    let generic = full.file.traceKeys(ft)
    let want = civil * 1_000_000 + nearest(int64(ns)) + 4_000
    doAssert generic.timeOrigin == rawK.timeOrigin
    doAssert generic.timeOrigin == toHeaderSubsec
    doAssert generic.firstSampleUs.isSome and rawK.firstSampleUs.isSome
    doAssert generic.firstSampleUs.get == rawK.firstSampleUs.get
    doAssert generic.firstSampleUs.get == want
    src.close()

  block size_and_caller:
    doAssert sizeof(TraceKeys) == 184
    var k = initTraceKeys()
    k.time = 1_700_000_000.0
    k.t0Ms = 5
    k.intervalUs = 1000
    doAssert k.timeOrigin == toNone
    doAssert k.firstSampleUs.isNone
    doAssert k.sampleTimeUs(0).isNone
    doAssert k.sampleAtUs(0).isNaN

  block rev3_timestamp:
    let stampUs = 1_700_000_100_504_000'i64
    let stamp = utcUsToGpsUs(stampUs)
    let k = keysOf(rev3File(stamp, 2500, true), "stamp")
    doAssert k.timeOrigin == toFirstSample
    doAssert k.time == timestampToUnix(stamp)
    doAssert k.firstSampleUs.get == stampUs # start time is not added
    doAssert k.firstSampleUs.get != gpsUsToUtcUs(utcUsToGpsUs(1_700_000_000_000_000'i64)) + 2500

  block rev3_time_zero:
    let gh3 = 1_700_000_000_000_000'i64
    let k = keysOf(rev3File(0, 2500, false), "gh3")
    doAssert k.timeOrigin == toRecordTimeZero
    doAssert k.time == timestampToUnix(utcUsToGpsUs(gh3))
    doAssert k.t0Ms == 2.5
    doAssert k.firstSampleUs.get == gh3 + 2500

  block rev2_header_seconds:
    let k = keysOf(rev2File(), "rev2")
    doAssert k.timeOrigin == toHeaderSeconds
    doAssert k.time == float64(civil)
    doAssert k.t0Ms == 2.0
    doAssert k.firstSampleUs.get == civil * 1_000_000 + 2000

  block segy_delay:
    let k = keysOf(segyFile(1, 5, 0, 4, false), "sy1")
    doAssert k.timeOrigin == toHeaderSeconds
    doAssert k.time == float64(civil)
    doAssert k.t0Ms == 5.0
    doAssert k.firstSampleUs.get == civil * 1_000_000 + 5_000

  block segy_nanoseconds:
    let ns = 1_234_567'i32
    let k = keysOf(segyFile(2, 4, ns, 4, true), "ns+")
    doAssert k.timeOrigin == toHeaderSubsec
    doAssert k.firstSampleUs.get == civil * 1_000_000 + nearest(ns) + 4_000
    let neg = keysOf(segyFile(2, 0, -1_500_000, 4, true), "ns-")
    doAssert neg.timeOrigin == toHeaderSubsec
    doAssert neg.firstSampleUs.get == civil * 1_000_000 + nearest(-1_500_000)

  block segy_gps:
    let k = keysOf(segyFile(1, 12, 0, 5, false), "gps")
    doAssert k.timeOrigin == toHeaderSeconds
    let gpsUs = int64(round((float64(civil) - float64(GpsEpochUnix)) * 1e6))
    doAssert k.time == timestampToUnix(gpsUs)
    doAssert gpsMinusUtc(gpsUs) == 18
    doAssert k.firstSampleUs.get == gpsUsToUtcUs(gpsUs) + 12_000
    doAssert k.firstSampleUs.get != civil * 1_000_000 + 12_000

  block segy_half_second:
    let civil = daysFromCivil(2024, 1, 1) * 86400
    let counts = halfSecondNs()
    let gpsBase = gpsUsToUtcUs(int64(round((float64(civil) - float64(GpsEpochUnix)) * 1e6)))
    for basis in [4'i16, 5'i16]:
      let ks = keysAll(segyNsFile(basis, counts), "half" & $basis)
      doAssert ks.len == counts.len
      let base = if basis == 5: gpsBase else: civil * 1_000_000
      for i, ns in counts:
        let want = base + nearest(int64(ns))
        let got = ks[i].firstSampleUs
        doAssert got.isSome, $basis & " ns " & $ns
        doAssert got.get == want, $basis & " ns " & $ns & " got " & $got.get & " want " & $want

  block segd_timestamp_is_first_sample:
    var rows: seq[TraceKeys] = @[]
    for origin in [toNone, toFirstSample, toRecordTimeZero, toHeaderSeconds, toHeaderSubsec]:
      for t0 in [0.0, 2.5, -2.5]:
        rows.add keysAt(origin, t0)
    let back = writeKeys(rows)
    doAssert back.len == rows.len
    for i, k in rows:
      let want = expectFirstUs(k)
      doAssert back[i].timeOrigin == toFirstSample, $k.timeOrigin & " t0 " & $k.t0Ms
      let got = back[i].firstSampleUs
      doAssert got.isSome, $k.timeOrigin & " t0 " & $k.t0Ms
      doAssert got.get == want, $k.timeOrigin & " t0 " & $k.t0Ms & " got " & $got.get &
        " want " & $want

  block record_time_zero_stable:
    # T has a non-zero microsecond part. d = 900 ms crosses a second, so a
    # rewrite that stored keys.time would move GH#1 as well as GH#3.
    const ShotT = 1_700_000_020.125
    const ShotUs = 1_700_000_020_125_000'i64
    proc writeShot(k: TraceKeys): seq[byte] =
      var w = openSeismicWriterBytes(SegdOutputOptions(sampleIntervalUs: 1000,
        numSamples: 1))
      var t = k
      if t.record.isNaN: t.record = 1
      t.intervalUs = 1000
      w.writeTrace(t, [1'f32])
      w.finishBytes()
    proc shotOf(b: seq[byte]): tuple[k: TraceKeys, tz: int64, gh3, gh1: seq[byte]] =
      var f = openSeismicBytes(b, "shot", keys = true)
      doAssert f.len == 1
      doAssert f.log.count(sevError) == 0
      let tz = f.recordTimeZeroUs(0)
      doAssert tz.isSome, "record time zero missing"
      result = (f.traceKeys(0), tz.get, @(f.index.segdRecords[0].gh3.encoded),
        @(f.index.segdRecords[0].gh1.encoded))
      f.close()
      doAssert b.len >= 96 and b[95] == 0x03
      doAssert result.gh3 == b[64 .. 95]
    for d in [-20.125, 0.0, 20.125, 900.0]:
      var k = initTraceKeys()
      k.time = ShotT
      k.t0Ms = d
      k.intervalUs = 1000
      k.record = 1
      let b1 = writeShot(k)
      let a = shotOf(b1)
      doAssert a.tz == ShotUs, "d " & $d & " tz " & $a.tz
      doAssert a.k.timeOrigin == toFirstSample
      doAssert a.k.firstSampleUs.get == ShotUs + int64(round(d * 1000.0)), $d
      var bare = openSeismicBytes(b1, "nokeys")
      doAssert not bare.hasKeys
      doAssert bare.recordTimeZeroUs(0).get == ShotUs
      bare.close()
      let b2 = writeShot(a.k)
      let c = shotOf(b2)
      doAssert c.tz == ShotUs, "rewrite d " & $d & " tz " & $c.tz
      doAssert c.k.firstSampleUs.get == a.k.firstSampleUs.get, $d
      doAssert c.k.t0Ms == a.k.t0Ms, $d
      doAssert c.gh3 == a.gh3, "GH#3 moved for d " & $d
      doAssert c.gh1 == a.gh1, "GH#1 moved for d " & $d
      doAssert b2[64 .. 95] == b1[64 .. 95], "GH#3 file bytes moved for d " & $d

  block record_time_zero_rev2:
    const ShotT = 1_700_000_020.125
    let sec = int64(floor(ShotT))
    let civil = fromUnix(sec).utc
    let b = rev2File(year = civil.year mod 100, julian = civil.yearday + 1,
      hour = civil.hour, minute = civil.minute, second = civil.second)
    var f = openSeismicBytes(b, "r2tz", keys = true)
    doAssert f.log.count(sevError) == 0
    let tz = f.recordTimeZeroUs(0)
    doAssert tz.isSome
    doAssert tz.get == sec * 1_000_000, $tz.get
    f.close()

  block record_time_zero_segy:
    const ShotT = 1_700_000_020.125
    const ShotUs = 1_700_000_020_125_000'i64
    let whole = int64(floor(ShotT)) * 1_000_000
    for rev in [1, 2]:
      let want = if rev == 1: whole else: ShotUs
      for d in [-20.125, 0.0, 20.125]:
        var k = initTraceKeys()
        k.time = ShotT
        k.t0Ms = d
        k.intervalUs = 1000
        var w = openSeismicWriterBytes(SegyOutputOptions(
          revision: SegyRevision(major: uint8(rev), minor: uint8(ord(rev >= 2)))))
        w.writeTrace(k, [1'f32])
        let b = w.finishBytes()
        var f = openSeismicBytes(b, "sytz", keys = true)
        doAssert f.log.count(sevError) == 0
        let tz = f.recordTimeZeroUs(0)
        doAssert tz.isSome, "rev " & $rev & " d " & $d
        doAssert tz.get == want, "rev " & $rev & " d " & $d & " got " & $tz.get
        f.close()

  block record_time_zero_none:
    var k = initTraceKeys()
    k.intervalUs = 1000
    var w = openSeismicWriterBytes(SegyOutputOptions())
    w.writeTrace(k, [1'f32])
    var f = openSeismicBytes(w.finishBytes(), "notime", keys = true)
    doAssert f.traceKeys(0).time.isNaN
    doAssert f.recordTimeZeroUs(0).isNone
    f.close()
    var g = openSeismicBytes(rev3File(0, 0, false, 0), "gh3zero", keys = true)
    doAssert g.recordTimeZeroUs(0).isNone
    g.close()

  block sample_index:
    let k = keysOf(segyFile(1, 0, 0, 4, false), "idx")
    doAssert k.intervalUs == 1000
    for n in [0'i64, 1, 7, 1000, -3]:
      let us = k.sampleTimeUs(n)
      doAssert us.isSome
      doAssert k.sampleAtUs(us.get) == float64(n)

when isMainModule: main()
