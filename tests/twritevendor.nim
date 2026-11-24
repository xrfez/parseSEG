## `vendor.<field>` overrides of a `like:` SEG-D writer (`useVendorMaps`): a field
## of a vendor header map is written into the copied trace's extension blocks, in
## a whole record and in a subset, Rev 2 (by extension number) and Rev 3 (by block
## type); every other byte of the blocks stays the source's. Seen failing: with the
## 64-bit time passed through float64, 2^53+1 read back as 2^53; with the record
## condition read from an empty record, the time field was refused as absent.

import std/[assertions, options, os, strformat, strutils]

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

proc refusedWith(w: var SeismicWriter, f: SeismicFile, x: Tensor[float32],
    patch: SubsetPatch, part: string) =
  ## The patch is refused, at `startSubset` or at the first trace, with `part` in the message.
  var msg = ""
  try:
    w.startSubset(f, [0, 1], patch)
    w.writeTrace(f, 0, x, 0)
  except ValueError as e:
    msg = e.msg
  doAssert part in msg, "message: " & msg
  w.abandonRecord()

proc skewRec(n1, n2, seed: int): SegdRecordData =
  ## Rev 2, one scan type of two sets of `n1` and `n2` traces, one skew block from `seed`.
  let fmt = sd8058
  var r = SegdRecord(layout: slRev2, format: some(fmt), revision: SegdRevision(major: 2, minor: 1))
  r.gh1 = SegdGeneralHeader1(fileNumber: 12, formatCode: ord(fmt), year: 26,
    additionalGhBlocks: 1, julianDay: 311, manufacturerCode: 9, baseScanInterval16: 32,
    recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 2,
    skewBlocks: 1)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 12, revisionMajor: 2, revisionMinor: 1,
    extRecordLength: uint32(2 * Ns), blockNumber: 2)
  var sets: seq[SegdChannelSetDescriptor]
  for k in 1 .. 2:
    sets.add SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: k,
      endTime: uint16(Ns), channelCount: (if k == 1: n1 else: n2), channelType: 1,
      traceHeaderExtensions: 1, arrayForming: 1)
  var skew = newSeq[byte](32)
  for i in 0 ..< 32: skew[i] = byte(seed + i)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: sets, skew: skew)]
  r.traceCount = n1 + n2
  for k in 0 ..< n1 + n2:
    var t = SegdTrace(layout: slRev2, index: k, numSamples: Ns)
    t.header = SegdTraceHeader(fileNumber: 12, scanTypeNumber: 1,
      channelSetNumber: (if k < n1: 1 else: 2), traceNumber: (if k < n1: k + 1 else: k - n1 + 1),
      traceHeaderExtensions: 1'u8)
    t.ext1 = some SegdTraceHeaderExt1(receiverLineNumber: 2000, receiverPointNumber: int32(k),
      receiverPointIndex: 1, samplesPerTrace: uint32(Ns), sensorType: 2)
    t.samples = newSeq[byte](dataBytes(fmt, Ns))
    result.traces.add t
  result.record = r

proc firstDifference(a, b: openArray[byte]): int =
  for i in 0 ..< a.len:
    if a[i] != b[i]: return i
  -1

proc mapOf(kind3: bool, cond: string): string =
  ## The block-A map with the time field under `cond` (Rev 2).
  fmt"""(.nif27)
(vendormap "cond" (match (format segd) (manufacturer 77))
  (target (kind traceExt) (extension 2) (name blkA)
    (field time (at 5) (enc i64) (when {cond}))))"""

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

  block patch_and_timestamp_refusals:
    # Seen failing: `timestamp.blockType` 0x41 was accepted; `gh1.fileNumber` and the
    # time fields were set in General Header #1 alone; a 20-digit `gh` number gave a
    # bare integer-parse error.
    let tmp = scratchDir("parseseg_twritevendor_patch")
    var d = makeRec(true, 3)
    for t in d.traces.mitems:
      t.extensions[0 ..< 32] = @(SegdTimestampHeader(timeZeroOfData: 777, blockType: 0x42).encoded)
    let src3 = tmp / "src3.sgd"
    put(src3, SegdData(records: @[d]))
    var f3 = openSeismic(src3)
    let x3 = f3.readTraces(0 ..< f3.len, float32)
    var w3 = openSeismicWriter(tmp / "o3.sgd", f3)
    doAssertRaises(ValueError):
      w3.writeTrace(f3, 0, x3, 0, overrides = [headerOverride("timestamp.blockType", 0x41)])
    w3.writeTrace(f3, 0, x3, 0, overrides = [headerOverride("timestamp.timeZeroOfData", 5)])
    w3.abandonRecord()
    let src2 = tmp / "src2.sgd"
    put(src2, SegdData(records: @[makeRec(false, 3)]))
    var f2 = openSeismic(src2)
    let x2 = f2.readTraces(0 ..< f2.len, float32)
    var w2 = openSeismicWriter(tmp / "o2.sgd", f2)
    for name in ["gh1.fileNumber", "gh1.year", "gh1.julianDay", "gh1.hour", "gh1.minute",
        "gh1.second"]:
      w2.refusedWith(f2, x2, SubsetPatch(headers: @[headerOverride(name, 3)]),
        "SubsetPatch.fileNumber")
    w2.refusedWith(f2, x2,
      SubsetPatch(headers: @[headerOverride("gh99999999999999999999.sourceSetNumber", 3)]),
      "the record fields are gh1")
    w2.refusedWith(f2, x2, SubsetPatch(headers: @[headerOverride("gh3.nosuch", 3)]), "nosuch")

  block value_that_does_not_fit_is_not_tried_later:
    # Seen failing: `vendor.x` of 300 (u8 in the first block, u16 in the second) was
    # written into the second block, which the reader does not read it from; so was
    # a value equal to the first block's sentinel and one of the wrong kind.
    for rev3 in [false, true]:
      let tmp = scratchDir("parseseg_twritevendor_fit" & $rev3)
      let src = tmp / "src.sgd"
      put(src, SegdData(records: @[makeRec(rev3, 3)]))
      var f = openSeismic(src)
      let x = f.readTraces(0 ..< f.len, float32)
      let head = if rev3: "(target (kind block) (type 0xB0) (where traceHeader) (name a)"
        else: "(target (kind traceExt) (extension 2) (name a)"
      let tail = if rev3: "(target (kind block) (type 0xB1) (where traceHeader) (name b)"
        else: "(target (kind traceExt) (extension 3) (name b)"
      let reg = regOf("(.nif27)\n(vendormap \"fit\" (match (format segd) (manufacturer 77))\n" &
        head & " (field x (at 1) (enc u8) (sentinel 0xFF)))\n" &
        tail & " (field x (at 1) (enc u16))))")
      var w = openSeismicWriter(tmp / "o.sgd", f)
      w.useVendorMaps(reg)
      for v in [300'i64, 255, -1]:
        doAssertRaises(ValueError):
          w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.x", v)])
      doAssertRaises(ValueError):
        w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.x", "ab")])
      w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.x", 200)])
      for i in 1 .. 2: w.writeTrace(f, i, x, i)
      doAssert not w.close().isFatal
      let g = openSeismic(tmp / "o.sgd")
      doAssert g.blocks(0)[0][0] == 200
      doAssert g.blocks(0)[1] == f.blocks(0)[1]
      doAssert g.blocks(0)[0][1 .. ^1] == f.blocks(0)[0][1 .. ^1]

  block record_context_is_the_patched_record:
    # Seen failing: the condition read the source's source-header bytes, so a patched
    # sourceSetNumber or file number did not change what the map saw.
    let tmp = scratchDir("parseseg_twritevendor_ctx")
    var a = SegdGeneralHeaderN(extFileNumber: 12, blockNumber: 3, sourceSetNumber: 1)
    var b = a
    b.sourceSetNumber = 2
    let eA = a.encoded
    let eB = b.encoded
    let setAt = firstDifference(eA, eB)
    var c = a
    c.extFileNumber = 33
    let fileAt = firstDifference(eA, c.encoded)
    doAssert setAt >= 0 and fileAt >= 0
    # The matched byte: the one after the last 2 bytes that never change.
    let mAt = block:
      var q = 0
      while q in [setAt, fileAt]: inc q
      q
    let match = fmt"(match (at {mAt + 1}) (bytes {eA[mAt]}))"
    for (cond, patch, ok) in [
        (fmt"(record generalHeader {match} (byte {setAt + 1})) (is 1)",
          SubsetPatch(headers: @[headerOverride("gh3.sourceSetNumber", 2)]), false),
        (fmt"(record generalHeader {match} (byte {setAt + 1})) (is 2)",
          SubsetPatch(headers: @[headerOverride("gh3.sourceSetNumber", 2)]), true),
        (fmt"(record generalHeader {match} (byte {setAt + 1})) (is 1)", SubsetPatch(), true),
        (fmt"(record generalHeader {match} (byte {fileAt + 1})) (is 33)",
          SubsetPatch(fileNumber: 33), true),
        (fmt"(record generalHeader {match} (byte {fileAt + 1})) (is 33)", SubsetPatch(), false)]:
      let src = tmp / "src.sgd"
      put(src, SegdData(records: @[makeRec(false, 3)]))
      var d = makeRec(false, 3)
      d.record.sourceHeaders = @[a]
      d.record.gh1.additionalGhBlocks = 2
      put(src, SegdData(records: @[d]))
      var f = openSeismic(src)
      let x = f.readTraces(0 ..< f.len, float32)
      let reg = regOf(mapOf(false, cond))
      let dst = tmp / "o.sgd"
      var w = openSeismicWriter(dst, f)
      w.useVendorMaps(reg)
      w.startSubset(f, [0, 1], patch)
      if ok:
        w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.time", Big)])
        w.writeTrace(f, 1, x, 1, overrides = [headerOverride("vendor.time", 7)])
        doAssert not w.close().isFatal
        let g = openSeismic(dst)
        doAssert g.decodeA(reg, 0, false)["time"].intVal == Big, cond
        doAssert g.decodeA(reg, 1, false)["time"].intVal == 7
      else:
        doAssertRaises(ValueError):
          w.writeTrace(f, 0, x, 0, overrides = [headerOverride("vendor.time", Big)])
        w.abandonRecord()

  block skew_cache_is_per_open_file:
    # Seen failing: a path rewritten with another layout and opened again used the
    # first file's channel positions (IndexDefect or wrong skew bytes).
    let tmp = scratchDir("parseseg_twritevendor_skew")
    let pa = tmp / "a.sgd"
    put(pa, SegdData(records: @[skewRec(3, 2, 0)]))
    var fa = openSeismic(pa)
    var w = openSeismicWriter(tmp / "o.sgd", fa)
    w.startSubset(fa, [1, 4])
    for k in [1, 4]: w.writeTrace(fa, k, newSeq[float32](Ns))
    fa.close()
    put(pa, SegdData(records: @[skewRec(1, 5, 30)]))
    var fb = openSeismic(pa)
    w.startSubset(fb, [0, 2, 5])
    for k in [0, 2, 5]: w.writeTrace(fb, k, newSeq[float32](Ns))
    doAssert not w.close().isFatal
    let g = openSeismic(tmp / "o.sgd")
    let sk = g.index.segdRecords[1].scanTypes[0].skew
    # Kept: set 1 channel 0; set 2 channels 1 and 4 (traces 2 and 5).
    doAssert sk[0 .. 2] == @[byte(30), byte(30 + 1 + 1), byte(30 + 1 + 4)]

  block vendor_maps_need_a_like_segd_writer:
    let tmp = scratchDir("parseseg_twritevendor_kinds")
    var w = openSeismicWriter(tmp / "k.sgy", SegyOutputOptions())
    doAssertRaises(ValueError): w.useVendorMaps(regOf(Rev2Map))
    let src = tmp / "src.sgd"
    put(src, SegdData(records: @[makeRec(false, 3)]))
    var f = openSeismic(src)
    var v = openSeismicWriter(tmp / "v.sgd", f)
    v.useVendorMaps(regOf(Rev2Map))
    discard v.close()
    doAssertRaises(ValueError): v.useVendorMaps(regOf(Rev2Map))

when isMainModule: main()
