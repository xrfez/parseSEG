## `vendor.<field>` overrides of a `like:` SEG-D writer (`useVendorMaps`): a field
## of a vendor header map is written into the copied trace's extension blocks, in
## a whole record and in a subset, Rev 2 (by extension number) and Rev 3 (by block
## type); every other byte of the blocks stays the source's. Seen failing: with the
## 64-bit time passed through float64, 2^53+1 read back as 2^53; with the record
## condition read from an empty record, the time field was refused as absent.

import std/[assertions, options, os, strutils]

import parseSEG
import parseSEG/common/diagnostics
import parseSEG/io/diskio
import parseSEG/segd/[reader, writer, headers, samples, rev3]
import parseSEG/vendor/apply

import ./utils/testutils

const
  Rev2Map = """(.nif27)
(vendormap "pvo2" (match (format segd) (manufacturer 77))
  (target (kind traceExt) (extension 2) (name blkA)
    (field serial (at 1) (enc u32))
    (field time (at 5) (enc i64)
      (when (record extendedHeader (match (at 1) (bytes 0x5A 0 0 6)) (byte 5)) (is 3)))
    (field gain (at 13) (enc f32))
    (field label (at 17) (len 4) (enc ascii) (trim right)))
  (target (kind traceExt) (extension 3) (name blkB)
    (field tag (at 1) (enc u16))))"""
  Rev3Map = """(.nif27)
(vendormap "pvo3" (match (format segd) (manufacturer 77))
  (target (kind block) (type 0xB0) (where traceHeader) (name blkA)
    (field serial (at 1) (enc u32))
    (field time (at 5) (enc i64))
    (field gain (at 13) (enc f32)))
  (target (kind block) (type 0xB1) (where traceHeader) (name blkB)
    (field tag (at 1) (enc u16))))"""
  Big = 9007199254740993'i64 # 2^53 + 1: not a float64
  Ns = 8

proc put(path: string, d: SegdData) =
  let sink = openDiskSink(path)
  try:
    let log = writeSegd(sink, d)
    doAssert log.count(sevError) + log.count(sevFatal) == 0, $log
  finally:
    sink.close()

proc regOf(text: string): VendorRegistry =
  result.addMap loadVendorMap(text)

proc makeRec(rev3: bool, version: byte, traces = 3): SegdRecordData =
  ## One channel set of `traces` traces, each with THE#1 and two vendor blocks (Rev 2:
  ## extensions 2 and 3; Rev 3: types 0xB0 and 0xB1), a pattern in every byte.
  let fmt = sd8058
  var r = SegdRecord(layout: (if rev3: slRev3 else: slRev2), format: some(fmt),
    revision: SegdRevision(major: (if rev3: 3 else: 2), minor: (if rev3: 0 else: 1)))
  r.gh1 = SegdGeneralHeader1(fileNumber: 12, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: (if rev3: 2 else: 1), julianDay: 311, manufacturerCode: 77,
    baseScanInterval16: (if rev3: 16 else: 32), recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1, extendedHeaderBlocks: 1)
  r.extended = newSeq[byte](32)
  for i in 0 ..< 32: r.extended[i] = byte(90 + i)
  r.extended[0 .. 3] = [0x5A'u8, 0, 0, 6]
  r.extended[4] = version
  if rev3:
    r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 12, revisionMajor: 3,
      extRecordLength: uint32(1000 * Ns), blockType: 2)
    r.gh3 = SegdGeneralHeader3(timeZero: 1474994765504000, blockType: 3)
    r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[
      SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1, channelType: 0x10,
        endTime: int32(1000 * Ns), numSamples: uint32(Ns), descaleMultiplier: 0.25,
        channelsInSet: uint32(traces), samplingInterval: 1000, traceHeaderExtensions: 3,
        blockType1: 0x30, blockType2: 0x31, blockType3: 0x32)])]
  else:
    r.gh2 = some SegdGeneralHeader2(extFileNumber: 12, revisionMajor: 2, revisionMinor: 1,
      extRecordLength: uint32(2 * Ns), blockNumber: 2)
    r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[
      SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, endTime: uint16(Ns),
        channelCount: traces, channelType: 1, traceHeaderExtensions: 3)])]
  r.traceCount = traces
  var all: seq[SegdTrace]
  for k in 0 ..< traces:
    var t = SegdTrace(layout: r.layout, index: k, numSamples: Ns)
    t.header = SegdTraceHeader(fileNumber: 12, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: k + 1, traceHeaderExtensions: 3'u8)
    if rev3:
      t.ext1Rev3 = some SegdTraceHeaderExt1Rev3(receiverLineNumber: 7,
        receiverPointNumber: int32(100 + k), numSamples: uint32(Ns), sensorType: 2,
        groupIndex: 1, blockType: 0x40)
    else:
      t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000,
        receiverPointNumber: int32(100 + k), receiverPointIndex: 1,
        samplesPerTrace: uint32(Ns), sensorType: 2)
    t.extensions = newSeq[byte](64)
    for i in 0 ..< 64: t.extensions[i] = byte(31 * k + 3 * i + 1)
    if rev3:
      t.extensions[31] = 0xB0
      t.extensions[63] = 0xB1
    var vals = newSeq[float64](Ns)
    for i in 0 ..< Ns: vals[i] = float64((i * (k + 2)) mod 11 - 5) * 0.125
    t.samples = newSeq[byte](dataBytes(fmt, Ns))
    encodeSamples(fmt, vals, t.samples)
    all.add t
  if rev3: computeRev3Sizes(r, all)
  result.record = r
  result.traces = all

proc blocks(g: SeismicFile, trace: int): seq[seq[byte]] =
  ## The two vendor blocks of an output trace's header.
  let e = g.traceEntry(trace)
  let h = g.copyBytes(e.offset, e.headerBytes)
  doAssert h.len == 20 + 32 + 64
  @[h[52 ..< 84], h[84 ..< 116]]

proc decodeA(g: SeismicFile, reg: VendorRegistry, trace: int, rev3: bool): VendorBlock =
  let rec = g.index.segdRecords[g.traceEntry(trace).record]
  let ctx = vendorContext(rec, true)
  let area = if rev3: VendorArea(kind: vtBlock, blockIndex: -1, blockType: 0xB0,
      where: "traceHeader", extIndex: -1)
    else: VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1, extIndex: 2)
  var log: DiagLog
  let r = reg.decode(ctx, area, g.blocks(trace)[0], log)
  doAssert r.isSome, "block A of trace " & $trace & " is not decoded"
  r.get

func sameOutside(a, b: openArray[byte], skip: Slice[int]): bool =
  for i in 0 ..< a.len:
    if a[i] != b[i] and i notin skip: return false
  true

proc runCase(rev3: bool) =
  let nm = if rev3: "v3" else: "v2"
  let tmp = scratchDir("parseseg_twritevendor_" & nm)
  let src = tmp / "src.sgd"
  put(src, SegdData(records: @[makeRec(rev3, 3)]))
  var f = openSeismic(src)
  doAssert not f.log.isFatal, $f.log
  let x = f.readTraces(0 ..< f.len, float32)
  let reg = regOf(if rev3: Rev3Map else: Rev2Map)
  let timeSpan = 4 .. 11

  block no_overrides_identical:
    # Maps set or not, a write without vendor overrides gives the same bytes.
    let a = tmp / "a.sgd"
    let b = tmp / "b.sgd"
    for (p, maps) in [(a, false), (b, true)]:
      var w = openSeismicWriter(p, f)
      if maps: w.useVendorMaps(reg)
      for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
      doAssert not w.close().isFatal
    doAssert readFile(a) == readFile(b)
    doAssert readFile(a) == readFile(src), "a like copy differs from its source"
    let c = tmp / "c.sgd"
    var w = openSeismicWriter(c, f)
    w.useVendorMaps(reg)
    w.startSubset(f, [0, 2])
    w.writeTrace(f, 0, x, 0)
    w.writeTrace(f, 2, x, 2)
    doAssert not w.close().isFatal
    let g = openSeismic(c)
    doAssert g.blocks(0) == f.blocks(0) and g.blocks(1) == f.blocks(2)

  block whole_record:
    let dst = tmp / "whole.sgd"
    var w = openSeismicWriter(dst, f)
    w.useVendorMaps(reg)
    w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.time", Big)])
    w.writeTrace(f, 1, x, 1, overrides = [headerOverride("vendor.time", -Big),
      headerOverride("vendor.serial", 4_000_000_000'i64),
      headerOverride("vendor.gain", 1.5), headerOverride("trace.traceNumber", 9)])
    w.writeTrace(f, 2, x, 2)
    doAssert not w.close().isFatal
    var g = openSeismic(dst)
    doAssert not g.log.isFatal, $g.log
    doAssert g.decodeA(reg, 0, rev3)["time"].intVal == Big
    doAssert g.decodeA(reg, 0, rev3)["serial"].intVal == f.decodeA(reg, 0, rev3)["serial"].intVal
    doAssert g.decodeA(reg, 1, rev3)["time"].intVal == -Big
    doAssert g.decodeA(reg, 1, rev3)["serial"].intVal == 4_000_000_000'i64
    doAssert g.decodeA(reg, 1, rev3)["gain"].floatVal == 1.5
    for i in 0 .. 2:
      doAssert g.blocks(i)[1] == f.blocks(i)[1], "block B of trace " & $i
    doAssert sameOutside(g.blocks(0)[0], f.blocks(0)[0], timeSpan)
    doAssert g.blocks(2) == f.blocks(2)

  block subset:
    let dst = tmp / "subset.sgd"
    var w = openSeismicWriter(dst, f)
    w.useVendorMaps(reg)
    w.startSubset(f, [1, 2], SubsetPatch(fileNumber: 33))
    w.writeTrace(f, 1, x, 1, overrides = [headerOverride("vendor.time", Big),
      headerOverride("vendor.gain", -2)])
    w.writeTrace(f, 2, x, 2, overrides = [headerOverride("vendor.time", 5)])
    doAssert not w.close().isFatal
    var g = openSeismic(dst)
    doAssert not g.log.isFatal, $g.log
    doAssert g.decodeA(reg, 0, rev3)["time"].intVal == Big
    doAssert g.decodeA(reg, 0, rev3)["gain"].floatVal == -2.0
    doAssert g.decodeA(reg, 1, rev3)["time"].intVal == 5
    doAssert g.blocks(0)[1] == f.blocks(1)[1] and g.blocks(1)[1] == f.blocks(2)[1]
    doAssert g.decodeA(reg, 0, rev3)["serial"].intVal == f.decodeA(reg, 1, rev3)["serial"].intVal
    doAssert sameOutside(g.blocks(1)[0], f.blocks(2)[0], timeSpan)

  block refusals_write_nothing:
    let bad = ["vendor.nosuch", "vendor.tag", "vendor.serial"]
    let vals = [1'i64, 1, -1]
    for i in 0 .. 2:
      let dst = tmp / ("bad" & $i & ".sgd")
      var w = openSeismicWriter(dst, f)
      w.useVendorMaps(reg)
      w.startSubset(f, [0, 1])
      # tag is in block B and fine; a serial of -1 does not fit; the others are unknown.
      if i == 1:
        w.writeTrace(f, 0, x, 0, overrides = [headerOverride(bad[i], vals[i])])
        w.abandonRecord()
      else:
        doAssertRaises(ValueError):
          w.writeTrace(f, 0, x, 0, overrides = [headerOverride(bad[i], vals[i])])
        w.abandonRecord()
      w.startSubset(f, [1])
      w.writeTrace(f, 1, x, 1)
      doAssert not w.close().isFatal
      let g = openSeismic(dst)
      doAssert g.len == 1 and g.blocks(0) == f.blocks(1), bad[i]
    # One bad override among good ones, in a whole record: the trace is refused, not
    # half written; the record then goes on from the same trace.
    let dst = tmp / "mixed.sgd"
    var w = openSeismicWriter(dst, f)
    w.useVendorMaps(reg)
    doAssertRaises(ValueError):
      w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.gain", 3.0),
        headerOverride("vendor.serial", -5)])
    doAssertRaises(ValueError): # text for a number
      w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.gain", "abc")])
    for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
    doAssert not w.close().isFatal
    doAssert readFile(dst) == readFile(src)
    # No maps set.
    var n = openSeismicWriter(tmp / "nomaps.sgd", f)
    doAssertRaises(ValueError):
      n.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.time", 1)])
    doAssertRaises(ValueError): # the other blocks' fields are still checked
      n.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.", 1)])
    n.useVendorMaps(reg)
    n.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.time", 1)])

proc main*() =
  runCase(false)
  runCase(true)
  block record_condition_fails:
    # A record that is not version 3: the time field is absent, nothing is written.
    let tmp = scratchDir("parseseg_twritevendor_cond")
    let src = tmp / "src.sgd"
    put(src, SegdData(records: @[makeRec(false, 2)]))
    var f = openSeismic(src)
    let x = f.readTraces(0 ..< f.len, float32)
    let reg = regOf(Rev2Map)
    var w = openSeismicWriter(tmp / "o.sgd", f)
    w.useVendorMaps(reg)
    doAssertRaises(ValueError):
      w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.time", 1)])
    w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.serial", 7)])
    w.writeTrace(f, 1, x, 1)
    w.writeTrace(f, 2, x, 2)
    doAssert not w.close().isFatal
    let g = openSeismic(tmp / "o.sgd")
    doAssert g.decodeA(reg, 0, false)["serial"].intVal == 7

when isMainModule: main()
