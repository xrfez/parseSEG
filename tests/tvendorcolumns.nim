## Vendor fields by name: `vendorFieldNames` lists what the maps in force decode and
## `vendorColumn` / `vendorColumnInt` read one field for every trace from the mapped
## header bytes, equal to a per-trace `decodeAll` of the same block.
## Seen to fail when the guarded code is broken: skipping `fieldIsOn` in `readCand`
## fails `segd_columns` (tUs of a record whose `(when)` is off); choosing the map without
## `selectMapWith` fails `most_specific_map_per_block`; ignoring `stop` fails
## `stop_ends_early`; dropping the sentinel test of `readNumber` fails `segd_columns`;
## keeping a clashing field's bare name fails `shipped_maps_listing`; passing the integer
## through float64 in `vendorColumnInt` fails `exact_integers`. Taking a record-level field
## from any block of the map's targets without (match) by its name fails
## `record_fields_of_several_areas` and `one_name_twice_in_a_block`; reading later blocks
## when the field is off in the first fails `record_field_reads_the_first_block`. Letting
## `fieldIsOn` recurse into a field at or after the one asked about fails
## `when_on_a_later_field` (the recursion never ends).

import std/[assertions, math, monotimes, options, os, sequtils, strutils, times]

import parseSEG
import parseSEG/vendor/maps # valueKind, internal to the library

import parseSEG/io/[memsink, memsource]

const mapDir = currentSourcePath().parentDir / ".." / "vendormaps"

const mapText = """(.nif27)
(vendormap "colmap" (version 1) (match (format segd) (rev 2.0 2.0) (manufacturer 9))
  (target (kind traceExt) (extension 2) (name unitInfo)
    (field serial (at 1) (enc u32))
    (field gain (at 5) (enc f32) (unit "dB"))
    (field label (at 9) (len 8) (enc ascii) (trim right))
    (field tUs (at 17) (enc i64) (unit "us")
      (when (record extendedHeader (match (at 1) (bytes 0xAA)) (byte 2)) (is 1)))
    (field cnt (at 25) (enc u16) (sentinel 0xFFFF))
    (field temp (at 27) (enc i16) (scale 0.5) (unit "C"))
    (field mode (at 29) (enc u8) (enum (1 "on") (2 "off")))
    (field n (at 30) (enc u8))
    (repeat (count (ref n)) (stride 1) (at 31) (field item (at 1) (enc u8))))
  (target (kind traceExt) (extension 3) (name aux)
    (field serial (at 1) (enc u16))))"""

const Big = 1_700_000_000_000_000_000'i64 # beyond 2^53

proc u32(b: var seq[byte], at: int, v: uint32) =
  for i in 0 .. 3: b[at + i] = byte(v shr (8 * (3 - i)))

proc ext2(r, j: int): seq[byte] =
  result = newSeq[byte](32)
  result.u32(0, uint32(1000 * r + j))
  result.u32(4, cast[uint32](float32(j) * 0.5 + float32(r)))
  let label = "T" & $r & $j
  for i in 0 .. 7: result[8 + i] = if i < label.len: byte(label[i]) else: byte(' ')
  let t = Big + int64(j)
  for i in 0 .. 7: result[16 + i] = byte(t shr (8 * (7 - i)))
  let k = j mod 200 # large files wrap the small fields
  let cnt = if j == 2: 0xFFFF else: 10 + k
  result[24] = byte(cnt shr 8)
  result[25] = byte(cnt and 255)
  let temp = cast[uint16](int16(-20 + k))
  result[26] = byte(temp shr 8)
  result[27] = byte(temp and 255)
  result[28] = byte(1 + j mod 3)
  result[29] = 2
  result[30] = byte(40 + k)
  result[31] = byte(50 + k)

proc ext3(j: int): seq[byte] =
  result = newSeq[byte](32)
  let v = 7 * j and 0xFFFF
  result[0] = byte(v shr 8)
  result[1] = byte(v and 255)

type RecSpec = object
  manufacturer: int
  second: int    ## Byte 2 of the extended header block.
  traces: int
  exts: int      ## Trace header extensions after #1.

proc record(spec: RecSpec, n: int): SegdRecordData =
  var r = SegdRecord(layout: slRev2, format: some(sd8058),
    revision: SegdRevision(major: 2, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 1, julianDay: 1, manufacturerCode: spec.manufacturer,
    baseScanInterval16: 32, recordType: 8, recordLength: BcdAllF, scanTypesPerRecord: 1,
    channelSetsPerScanType: 1, extendedHeaderBlocks: 1)
  r.gh2 = some SegdGeneralHeader2(extFileNumber: 1, revisionMajor: 2, revisionMinor: 0,
    extRecordLength: 1000, blockNumber: 2)
  r.extended = newSeq[byte](32)
  r.extended[0] = 0xAA
  r.extended[1] = byte(spec.second)
  let the = uint8(1 + spec.exts)
  let c = SegdChannelSetDescriptor(scanTypeNumber: 1, channelSetNumber: 1, startTime: 1,
    endTime: 2, channelCount: spec.traces, channelType: 1, gainControl: 1,
    traceHeaderExtensions: the, verticalStack: 1, arrayForming: 1)
  r.scanTypes = @[SegdScanType(layout: slRev2, descriptors: @[c])]
  r.traceCount = spec.traces
  result.record = r
  for j in 0 ..< spec.traces:
    var t = SegdTrace(layout: slRev2, index: j, numSamples: 1)
    t.ext1 = some(SegdTraceHeaderExt1())
    t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: j + 1, traceHeaderExtensions: the)
    if spec.exts >= 1: t.extensions.add ext2(n, j)
    if spec.exts >= 2: t.extensions.add ext3(j)
    t.samples = newSeq[byte](dataBytes(sd8058, 1))
    encodeSamples(sd8058, [1.0'f32], t.samples)
    result.traces.add t

proc build(specs: openArray[RecSpec]): SegdData =
  for i, s in specs: result.records.add record(s, i)

proc bytesOf(d: SegdData): seq[byte] =
  let sink = openMemSink("cols")
  doAssert writeSegd(sink, d).count(sevError) == 0
  sink.takeBytes()

proc same(a, b: float64): bool = (a.isNaN and b.isNaN) or a == b

proc registry(text = mapText): VendorRegistry =
  result.addMap loadVendorMap(text)

proc listed(reg: VendorRegistry, ctx: VendorContext, name: string): VendorFieldInfo =
  for i in reg.vendorFieldNames(ctx):
    if i.name == name: return i
  doAssert false, name & " is not listed"

template expectError(part: string, body: untyped) =
  try:
    body
    doAssert false, "expected ValueError containing: " & part
  except ValueError as e:
    doAssert part in e.msg, e.msg

proc allocs(): int =
  ## Allocations so far (`tvendorcolumns.nims` turns the counter on).
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc main*() =
  block shipped_maps_listing:
    # Each shipped map lists what it declares, once per address, in a stable order.
    let ctxs = [
      ("mfr09-rev2", VendorContext(format: skSegd, revision: VendorRevision(major: 2),
        manufacturer: 9, serial: -1, byteOrder: boBig,
        extended: @[9'u8, 0, 0, 1] & newSeq[byte](28))),
      ("mfr50-rev3", VendorContext(format: skSegd, revision: VendorRevision(major: 3),
        manufacturer: 50, serial: -1, byteOrder: boBig)),
      ("segy-x100-stations", VendorContext(format: skSegy,
        revision: VendorRevision(major: 2), manufacturer: -1, serial: -1, byteOrder: boBig,
        text: "LINE AND POINT NUMBERS ARE X 100 IN TRACE HEADERS"))]
    var total = 0
    for (mapName, ctx) in ctxs:
      var reg: VendorRegistry
      var m: VendorMap
      for path in walkFiles(mapDir / "*.nif"):
        let one = loadVendorMap(readFile(path), path)
        if one.name == mapName: m = one
      doAssert m.name == mapName, mapName
      reg.addMap m
      doAssert m.applies(ctx), mapName
      let infos = reg.vendorFieldNames(ctx)
      doAssert infos == reg.vendorFieldNames(ctx), "stable order"
      var names, addrs: seq[string]
      for i in infos:
        doAssert i.name notin names, "duplicate name " & i.name
        doAssert i.blockName & "." & i.fieldName notin addrs
        names.add i.name
        addrs.add i.blockName & "." & i.fieldName
        doAssert i.name == i.fieldName or i.name == i.blockName & "." & i.fieldName
      # Every declared field is listed with the map's kind, unit and labels; none else.
      var declared = 0
      var seen: seq[string]
      for t in m.targets:
        for f in t.fields:
          if t.name & "." & f.name notin seen:
            seen.add t.name & "." & f.name
            inc declared
            var found = false
            for i in infos:
              if i.blockName == t.name and i.fieldName == f.name:
                found = true
                doAssert i.kind == f.valueKind and i.unit == f.unit and
                  i.hasLabels == (f.enums.len > 0) and not i.isRepeat, i.name
                doAssert i.level == (if t.kind == vtTraceExt or t.where == "traceHeader": vlTrace
                                     else: vlRecord), i.name
            doAssert found, t.name & "." & f.name
        for r in t.repeats:
          for f in r.fields:
            if t.name & "." & f.name notin seen:
              seen.add t.name & "." & f.name
              inc declared
              var found = false
              for i in infos:
                if i.blockName == t.name and i.fieldName == f.name:
                  found = true
                  doAssert i.isRepeat and i.kind == f.valueKind
              doAssert found
      doAssert infos.len == declared, mapName
      total += infos.len
      # The map's declaration order is the listing's.
      var last = -1
      for i in infos:
        let at = seen.find(i.blockName & "." & i.fieldName)
        doAssert at > last, i.name
        last = at
    doAssert total > 10
    # A map that does not apply lists nothing.
    var reg: VendorRegistry
    reg.addMap loadVendorMap(readFile(mapDir / "mfr50-rev3.nif"))
    doAssert reg.vendorFieldNames(ctxs[0][1]).len == 0

  block clash_is_block_dot_name:
    let reg = registry()
    let ctx = VendorContext(format: skSegd, revision: VendorRevision(major: 2),
      manufacturer: 9, serial: -1, byteOrder: boBig, extended: @[0xAA'u8, 1] & newSeq[byte](30))
    var names: seq[string]
    for i in reg.vendorFieldNames(ctx): names.add i.name
    doAssert names == @["unitInfo.serial", "gain", "label", "tUs", "cnt", "temp", "mode", "n",
      "item", "aux.serial"], $names
    doAssert reg.listed(ctx, "gain").unit == "dB"
    doAssert reg.listed(ctx, "gain").kind == vvFloat and reg.listed(ctx, "label").kind == vvText
    doAssert reg.listed(ctx, "tUs").kind == vvInt and reg.listed(ctx, "temp").kind == vvFloat
    doAssert reg.listed(ctx, "mode").hasLabels and not reg.listed(ctx, "cnt").hasLabels
    doAssert reg.listed(ctx, "item").isRepeat and reg.listed(ctx, "item").level == vlTrace

  block segd_columns:
    let specs = [RecSpec(manufacturer: 9, second: 1, traces: 4, exts: 2),
      RecSpec(manufacturer: 9, second: 0, traces: 3, exts: 1),
      RecSpec(manufacturer: 7, second: 1, traces: 2, exts: 1)]
    let d = build(specs)
    var f = openSeismicBytes(bytesOf(d), "cols")
    doAssert f.len == 9 and f.recordCount == 3
    let reg = registry()
    # What a per-trace decodeAll gives for the same blocks.
    var log: DiagLog
    var expect: seq[tuple[serial, gain, tUs, cnt, temp, mode, aux: Option[VendorValue],
      label: Option[VendorValue]]]
    for r in 0 ..< 3:
      let ctx = vendorContext(d.records[r].record)
      for t in d.records[r].traces:
        var e: typeof(expect[0])
        for k in 0 ..< t.extensions.len div 32:
          let area = VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1,
            extIndex: k + 2)
          for blk in reg.decodeAll(ctx, area, t.extensions.toOpenArray(32 * k, 32 * k + 31),
              log):
            template get(n: string): Option[VendorValue] =
              if n in blk: some(blk[n]) else: none(VendorValue)
            if blk.name == "unitInfo":
              e.serial = get("serial")
              e.gain = get("gain")
              e.label = get("label")
              e.tUs = get("tUs")
              e.cnt = get("cnt")
              e.temp = get("temp")
              e.mode = get("mode")
            else: e.aux = get("serial")
        expect.add e
    doAssert expect.len == 9
    # Sanity: the case table covers what the columns must tell apart.
    doAssert expect[0].tUs.isSome and expect[4].tUs.isNone and expect[2].cnt.isNone
    doAssert expect[0].aux.isSome and expect[4].aux.isNone and expect[7].serial.isNone

    template numbers(name: string, field: untyped) =
      let col = f.vendorColumn(reg, name)
      doAssert col.numbers.len == 9 and col.texts.len == 0 and not col.stopped
      var missing = 0
      for i in 0 ..< 9:
        if expect[i].field.isNone:
          inc missing
          doAssert col.numbers[i].isNaN, name & " " & $i
        else: doAssert same(col.numbers[i], expect[i].field.get.toFloat), name & " " & $i
      doAssert col.absent == missing, name & " " & $col.absent & " " & $missing

    numbers("unitInfo.serial", serial)
    numbers("gain", gain)
    numbers("tUs", tUs)
    numbers("cnt", cnt)
    numbers("temp", temp)
    numbers("mode", mode)
    numbers("aux.serial", aux)
    doAssert f.vendorColumn(reg, "gain").unit == "dB"
    doAssert f.vendorColumn(reg, "tUs").kind == vvInt
    doAssert f.vendorColumn(reg, "temp").kind == vvFloat
    # Absent cases: the sentinel, a failed (when), a missing block, a map that does not apply.
    let cnt = f.vendorColumn(reg, "cnt")
    doAssert cnt.numbers[2].isNaN and cnt.numbers[0] == 10.0
    let tUs = f.vendorColumn(reg, "tUs")
    for i in 4 ..< 9: doAssert tUs.numbers[i].isNaN
    doAssert tUs.absent == 5
    let aux = f.vendorColumn(reg, "aux.serial")
    doAssert aux.numbers[3] == 21.0 and aux.absent == 5
    let gain = f.vendorColumn(reg, "gain")
    for i in 7 ..< 9: doAssert gain.numbers[i].isNaN
    # Text: "" where absent.
    let label = f.vendorColumn(reg, "label")
    doAssert label.kind == vvText and label.numbers.len == 0 and label.texts.len == 9
    for i in 0 ..< 9:
      doAssert label.texts[i] == (if expect[i].label.isSome: expect[i].label.get.text else: "")
    doAssert label.texts[0] == "T00" and label.texts[4] == "T10" and label.texts[7] == ""
    doAssert label.absent == 2
    # A repeat's element, asked as name[i].
    let item = f.vendorColumn(reg, "item[1]")
    doAssert item.numbers[0] == 50.0 and item.numbers[1] == 51.0 and item.numbers[7].isNaN
    doAssert f.vendorColumn(reg, "item[2]").absent == 9 # the repeat has 2 elements
    f.close()

  block exact_integers:
    let d = build([RecSpec(manufacturer: 9, second: 1, traces: 3, exts: 2),
      RecSpec(manufacturer: 9, second: 0, traces: 2, exts: 1)])
    var f = openSeismicBytes(bytesOf(d), "ints")
    let reg = registry()
    let col = f.vendorColumnInt(reg, "tUs")
    doAssert col.values.len == 5 and col.present == @[true, true, true, false, false]
    for j in 0 ..< 3: doAssert col.values[j] == Big + int64(j)
    doAssert col.absent == 2 and col.unit == "us"
    # Beyond 2^53 a float64 cannot tell neighbours apart; the integer column does.
    let fl = f.vendorColumn(reg, "tUs")
    doAssert fl.numbers[0] == fl.numbers[1] and col.values[0] != col.values[1]
    expectError("not an unscaled integer"):
      discard f.vendorColumnInt(reg, "gain")
    expectError("not an unscaled integer"):
      discard f.vendorColumnInt(reg, "temp")
    f.close()

  block names_and_errors:
    let d = build([RecSpec(manufacturer: 9, second: 1, traces: 2, exts: 2)])
    var f = openSeismicBytes(bytesOf(d), "names")
    let reg = registry()
    expectError("not a field"):
      discard f.vendorColumn(reg, "nosuch")
    expectError("several blocks"):
      discard f.vendorColumn(reg, "serial")
    expectError("repeat"):
      discard f.vendorColumn(reg, "item")
    expectError("not in a repeat"):
      discard f.vendorColumn(reg, "gain[0]")
    let a = f.vendorColumn(reg, "unitInfo.serial")
    doAssert a.numbers == @[0.0, 1.0] and a.level == vlTrace
    doAssert f.vendorColumn(reg, "aux.serial").numbers == @[0.0, 7.0]
    # No map loaded: nothing is a field.
    expectError("not a field"):
      discard f.vendorColumn(VendorRegistry(), "gain")
    f.close()
    expectError("closed"):
      discard f.vendorColumn(reg, "gain")

  block most_specific_map_per_block:
    # Two maps decode the same extension; the one with more clauses wins, as in decodeAll.
    var reg = registry()
    reg.addMap loadVendorMap("""(.nif27)
(vendormap "specific" (version 1) (match (format segd) (manufacturer 9) (rev 2.0 2.0) (serial 0 100))
  (target (kind traceExt) (extension 2) (name unitInfo)
    (field serial (at 2) (enc u32))))""")
    let d = build([RecSpec(manufacturer: 9, second: 1, traces: 2, exts: 1)])
    var f = openSeismicBytes(bytesOf(d), "spec")
    let col = f.vendorColumn(reg, "unitInfo.serial")
    # The record's serial is 0, inside 0..100: the second map decodes it, one byte on.
    var log: DiagLog
    let ctx = vendorContext(d.records[0].record)
    for j, t in d.records[0].traces:
      let blk = reg.decode(ctx, VendorArea(kind: vtTraceExt, blockIndex: -1, blockType: -1,
        extIndex: 2), t.extensions.toOpenArray(0, 31), log).get
      doAssert col.numbers[j] == blk["serial"].toFloat and
        (j == 0 or col.numbers[j] != float64(beU32(t.extensions, 0)))
    f.close()

  block record_level_field:
    let reg = registry("""(.nif27)
(vendormap "rec" (version 1) (match (format segd) (manufacturer 9))
  (target (kind extendedHeader) (blockIndex 1) (name recInfo)
    (field marker (at 1) (enc u8)) (field flag (at 2) (enc u8)) (field tag (at 3) (len 2) (enc ascii))))""")
    let d = build([RecSpec(manufacturer: 9, second: 5, traces: 2, exts: 1),
      RecSpec(manufacturer: 9, second: 6, traces: 3, exts: 1)])
    var f = openSeismicBytes(bytesOf(d), "rec")
    let col = f.vendorColumn(reg, "flag")
    doAssert col.level == vlRecord and col.numbers == @[5.0, 5.0, 6.0, 6.0, 6.0]
    let tag = f.vendorColumn(reg, "tag")
    doAssert tag.kind == vvText and tag.texts == newSeq[string](5).mapIt("\0\0")
    f.close()

  block stop_ends_early:
    let specs = [RecSpec(manufacturer: 9, second: 1, traces: 9000, exts: 1)]
    var f = openSeismicBytes(bytesOf(build(specs)), "stop")
    let reg = registry()
    var asked = 0
    let col = f.vendorColumn(reg, "gain", proc(): bool =
      inc asked
      asked >= 2)
    doAssert col.stopped and col.numbers.len == 0 and col.texts.len == 0
    doAssert asked == 2 # every 4096 traces: at 0 and at 4096
    let full = f.vendorColumn(reg, "gain", proc(): bool = false)
    doAssert not full.stopped and full.numbers.len == 9000 and full.absent == 0
    let ci = f.vendorColumnInt(reg, "cnt", proc(): bool = true)
    doAssert ci.stopped and ci.values.len == 0
    f.close()

  block segy_headers:
    # SEG-Y: the standard header bytes and a named proprietary header, by field plan.
    var sf = SegyFile(text: initTextHeader(teEbcdic), byteOrder: boBig,
      format: some(sfFloat32), revision: SegyRevision(major: 2),
      extended: initExtendedTextHeader())
    sf.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 2, segyMinor: 1,
      samplesPerTrace: 4, sampleInterval: 1000, measurementSystem: 1,
      maxAddlTraceHeaders: 2, byteOrderMarker: ByteOrderMarker)
    let sink = openMemSink("sy")
    var w = openSegyWriter(sink, sf, initSegyWriteOptions(sf, lenient = true))
    for j in 0 ..< 3:
      var t = SegyTrace(numSamples: 4, sampleInterval: 1000, samples: newSeq[byte](16))
      t.header = SegyTraceHeader(fieldRecord: 10, traceNumberInField: int32(j + 1),
        traceSeqFile: int32(100 + j), numSamples: 4, sampleInterval: 1000, traceIdCode: 1)
      t.hasExt1 = true
      t.ext1 = initTraceHeaderExt1()
      t.ext1.numAddlTraceHeaders = 2
      t.ext1.extNumSamples = 4
      t.proprietary = newSeq[byte](TraceHeaderSize)
      for i, c in "VENDOR01": t.proprietary[232 + i] = byte(c)
      t.proprietary[0] = byte(60 + j)
      t.proprietary[1] = 0xFF
      w.writeTrace(t)
    w.close()
    var f = openSeismicBytes(sink.takeBytes(), "segy")
    let reg = registry("""(.nif27)
(vendormap "sgy" (version 1) (match (format segy))
  (target (kind traceHeaderBytes) (name std)
    (field seqFile (at 5) (enc i32)))
  (target (kind traceHeaderBlock) (headerName VENDOR01) (name prop)
    (field first (at 1) (enc u8)) (field second (at 2) (enc u8) (sentinel 255))))""")
    doAssert f.len == 3
    doAssert f.vendorColumn(reg, "seqFile").numbers == @[100.0, 101.0, 102.0]
    doAssert f.vendorColumn(reg, "first").numbers == @[60.0, 61.0, 62.0]
    let second = f.vendorColumn(reg, "second")
    doAssert second.absent == 3 and second.numbers[0].isNaN
    # A target for the standard header with a header name is for no trace: the name of the
    # previous trace's proprietary block must not leak into the standard header's area.
    let named = registry("""(.nif27)
(vendormap "named" (version 1) (match (format segy))
  (target (kind traceHeaderBytes) (headerName VENDOR01) (name std) (field seqFile (at 5) (enc i32))))""")
    doAssert f.vendorColumn(named, "seqFile").absent == 3
    f.close()

  block shipped_map_on_a_file:
    # The shipped Rev 3 map's fields read from a Rev 3 trace block.
    var reg: VendorRegistry
    reg.addMap loadVendorMap(readFile(mapDir / "mfr50-rev3.nif"))
    var r = SegdRecord(layout: slRev3, format: some(sd8058),
      revision: SegdRevision(major: 3, minor: 0))
    r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
      additionalGhBlocks: 2, julianDay: 61, baseScanInterval16: 16, recordType: 8,
      recordLength: BcdAllF, scanTypesPerRecord: 1, channelSetsPerScanType: 1,
      manufacturerCode: 50)
    r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3,
      extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
    r.gh3 = SegdGeneralHeader3(blockType: BlockTypeGeneralHeader3)
    var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
    t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(numSamples: 1, sensorType: 1, depthIndex: 1,
      blockType: BlockTypeTraceHeaderExt1))
    var blk = newSeq[byte](32)
    blk[31] = 0xB0
    for i in 0 .. 31: (if i != 31: blk[i] = byte(i + 1))
    t.extensions = blk
    t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
      traceNumber: 1, traceHeaderExtensions: 2)
    var cd = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
      channelType: 0x10, endTime: 1000, numSamples: 1, descaleMultiplier: 1.0,
      channelsInSet: 1, samplingInterval: 1000, arrayForming: 1, traceHeaderExtensions: 2,
      verticalStack: 1, blockType1: BlockTypeChannelSet1, blockType2: BlockTypeChannelSet2,
      blockType3: BlockTypeChannelSet3)
    for i in 0 ..< cd.description.len: cd.description[i] = ' '
    r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[cd])]
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
    var f = openSeismicBytes(sink.takeBytes(), "r3")
    doAssert f.len == 1
    # Every plain numeric field of the block matches decode of the same bytes.
    let ctx = vendorContext(f.index.segdRecords[0])
    var log: DiagLog
    let got = reg.decodeAll(ctx, VendorArea(kind: vtBlock, blockIndex: -1, blockType: 0xB0,
      where: "traceHeader", extIndex: -1), blk, log)
    doAssert got.len == 1 and got[0].fields.len > 0
    var checked = 0
    for info in reg.vendorFieldNames(ctx):
      if info.level == vlTrace and not info.isRepeat and info.kind in {vvInt, vvFloat}:
        let col = f.vendorColumn(reg, info.name)
        if info.fieldName in got[0]:
          doAssert same(col.numbers[0], got[0][info.fieldName].toFloat), info.name
          inc checked
        else: doAssert col.numbers[0].isNaN, info.name
    doAssert checked > 0
    f.close()

  block long_when_chain_is_linear:
    # 30 fields, each conditioned on the 16 before it: a column must not walk the tree of
    # conditions (that took time exponential in the depth).
    var t = "(.nif27)\n(vendormap \"chain\" (version 1) (match (format segd))\n" &
      "  (target (kind traceExt) (extension 2) (name chain)\n"
    for i in 0 ..< 30:
      t.add "    (field f" & $i & " (at " & $(1 + i) & ") (enc u8)"
      for k in 1 .. min(16, i): t.add " (when (field f" & $(i - k) & ") (range 0 255))"
      t.add ")\n"
    t.add "))"
    let reg = registry(t)
    var f = openSeismicBytes(bytesOf(build([RecSpec(manufacturer: 9, second: 1, traces: 50,
      exts: 1)])), "chain")
    let t0 = getMonoTime()
    let col = f.vendorColumn(reg, "f29")
    doAssert (getMonoTime() - t0).inMilliseconds < 2000
    doAssert col.absent == 0 and col.numbers[0] == float64(ext2(0, 0)[29])
    f.close()

  block positional_targets_at_record_level:
    # Two targets without (match) on one block give one block, named after the last: the
    # field of the first is still found.
    let reg = registry("""(.nif27)
(vendormap "pos" (version 1) (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name first) (field a (at 2) (enc u8)))
  (target (kind extendedHeader) (blockIndex 1) (name second) (field b (at 1) (enc u8))))""")
    var f = openSeismicBytes(bytesOf(build([RecSpec(manufacturer: 9, second: 5, traces: 2,
      exts: 1)])), "pos")
    doAssert f.vendorColumn(reg, "a").numbers == @[5.0, 5.0]
    doAssert f.vendorColumn(reg, "b").numbers == @[170.0, 170.0]
    # Asked per record: stop is asked once per record.
    var asked = 0
    let c = f.vendorColumn(reg, "a", proc(): bool =
      inc asked
      true)
    doAssert c.stopped and asked == 1
    f.close()

  block records_that_disagree_are_mixed:
    # Map for manufacturer 9 gives v as an integer in "a", manufacturer 7's as a float,
    # manufacturer 5's as an integer in "b": the float record is absent, the other unit kept.
    var reg: VendorRegistry
    for (m, def) in [(9, "(enc u8) (unit \"a\")"), (7, "(enc f32)"), (5, "(enc u8) (unit \"b\")")]:
      reg.addMap loadVendorMap("(.nif27)\n(vendormap \"m" & $m &
        "\" (version 1) (match (format segd) (manufacturer " & $m &
        "))\n  (target (kind traceExt) (extension 2) (name e) (field v (at 4) " & def & ")))")
    let d = build([RecSpec(manufacturer: 9, second: 1, traces: 2, exts: 1),
      RecSpec(manufacturer: 7, second: 1, traces: 2, exts: 1),
      RecSpec(manufacturer: 5, second: 1, traces: 2, exts: 1)])
    var f = openSeismicBytes(bytesOf(d), "mixed")
    let col = f.vendorColumn(reg, "v")
    doAssert col.kind == vvInt and col.unit == "a" and col.mixed
    doAssert "map m7" in col.mixedWhy and "vvFloat" in col.mixedWhy, col.mixedWhy
    doAssert col.numbers[0] == float64(ext2(0, 0)[3]) and col.numbers[2].isNaN and
      col.numbers[3].isNaN and col.numbers[4] == float64(ext2(2, 0)[3]) and col.absent == 2
    let ci = f.vendorColumnInt(reg, "v")
    doAssert ci.mixed and ci.present == @[true, true, false, false, true, true]
    # Without the disagreeing record the column is not mixed, and its unit is the first's.
    var g = openSeismicBytes(bytesOf(build([RecSpec(manufacturer: 9, second: 1, traces: 2,
      exts: 1)])), "plain")
    doAssert not g.vendorColumn(reg, "v").mixed
    # Only the unit differs: values kept.
    var h = openSeismicBytes(bytesOf(build([RecSpec(manufacturer: 9, second: 1, traces: 1,
      exts: 1), RecSpec(manufacturer: 5, second: 1, traces: 1, exts: 1)])), "unit")
    let u = h.vendorColumn(reg, "v")
    doAssert u.mixed and "unit" in u.mixedWhy and u.absent == 0
    f.close()
    g.close()
    h.close()

  block dotted_names_that_collide:
    let reg = registry("""(.nif27)
(vendormap "dots" (version 1) (match (format segd))
  (target (kind traceExt) (extension 2) (name p) (field "v.w" (at 1) (enc u8)))
  (target (kind traceExt) (extension 2) (name "p.v") (field w (at 2) (enc u8))))""")
    var f = openSeismicBytes(bytesOf(build([RecSpec(manufacturer: 9, second: 1, traces: 1,
      exts: 1)])), "dots")
    expectError("several fields"):
      discard f.vendorColumn(reg, "p.v.w")
    f.close()

  block present_nan_is_not_absent:
    var d = build([RecSpec(manufacturer: 9, second: 1, traces: 3, exts: 1)])
    d.records[0].traces[1].extensions.u32(4, 0x7FC00000'u32)
    var f = openSeismicBytes(bytesOf(d), "nan")
    let col = f.vendorColumn(registry(), "gain")
    doAssert col.absent == 0 and col.numbers[1].isNaN and not col.numbers[0].isNaN
    f.close()

  # A record with two extended header blocks (bytes 100..163) and one external header
  # block (bytes 1..32), for record-level fields in several areas.
  proc twoAreas(): SegdData =
    result = build([RecSpec(manufacturer: 9, second: 1, traces: 2, exts: 1)])
    template r: untyped = result.records[0].record
    r.extended = newSeq[byte](64)
    for i in 0 .. 63: r.extended[i] = byte(i + 100)
    r.gh1.extendedHeaderBlocks = 2
    r.external = newSeq[byte](32)
    for i in 0 .. 31: r.external[i] = byte(i + 1)
    r.gh1.externalHeaderBlocks = 1

  proc decoded(reg: VendorRegistry, f: SeismicFile, blockName: string): seq[VendorField] =
    # The fields of the record's first decoded block named `blockName`.
    var log: DiagLog
    for blk in reg.decodeVendorAreas(f.index.segdRecords[0], log):
      if blk.name == blockName: return blk.fields
    doAssert false, blockName & " is not decoded"

  block record_fields_of_several_areas:
    # One name in positional targets of different areas: each address reads its own
    # target's block. Matching the field by name in any positional target's block gave all
    # three columns the extended header block 1 value (102).
    let reg = registry("""(.nif27)
(vendormap "m" (version 1) (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name ext) (field x (at 3) (enc u8)))
  (target (kind externalHeader) (blockIndex 1) (name xh) (field x (at 5) (enc u8)))
  (target (kind extendedHeader) (blockIndex 2) (name ext2) (field x (at 7) (enc u8))))""")
    var f = openSeismicBytes(bytesOf(twoAreas()), "areas")
    for (name, blockName, want) in [("ext.x", "ext", 102.0), ("ext2.x", "ext2", 138.0),
        ("xh.x", "xh", 5.0)]:
      let col = f.vendorColumn(reg, name)
      doAssert reg.decoded(f, blockName)[0].value.intVal == int64(want)
      doAssert col.level == vlRecord and col.numbers == @[want, want], name & " " & $col.numbers
      doAssert f.vendorColumnInt(reg, name).values == @[int64(want), int64(want)]
    f.close()

  block one_name_twice_in_a_block:
    # Two positional targets of one block both have x: decode gives one block (named after
    # the last) listing p's x, then q's. An address reads the x its own target decodes:
    # p.x the first, q.x the second (matching by name gave q.x the first).
    let reg = registry("""(.nif27)
(vendormap "m" (version 1) (match (format segd))
  (target (kind extendedHeader) (blockIndex 1) (name p) (field x (at 1) (enc u8))
    (field y (at 4) (enc u8)))
  (target (kind extendedHeader) (blockIndex 1) (name q) (field x (at 2) (enc u8))))""")
    var f = openSeismicBytes(bytesOf(twoAreas()), "twice")
    let fields = reg.decoded(f, "q")
    doAssert fields.len == 3 and fields[0].name == "x" and fields[2].name == "x"
    doAssert f.vendorColumn(reg, "p.x").numbers == @[float64(fields[0].value.intVal), 100.0]
    doAssert f.vendorColumn(reg, "q.x").numbers == @[float64(fields[2].value.intVal), 101.0]
    doAssert f.vendorColumn(reg, "y").numbers == @[103.0, 103.0]
    f.close()

  block record_field_reads_the_first_block:
    # As for a trace: a target with (match) and no blockIndex reads the first block it holds
    # for; when the field is off there (its sentinel) a later block is not looked at.
    let reg = registry("""(.nif27)
(vendormap "m" (version 1) (match (format segd))
  (target (kind extendedHeader) (match (at 1) (bytes 0x64)) (name hit)
    (field v (at 2) (enc u8) (sentinel 101))))""")
    var d = twoAreas()
    d.records[0].record.extended[32] = 0x64
    var f = openSeismicBytes(bytesOf(d), "first")
    var log: DiagLog
    var shown: seq[string]
    for blk in reg.decodeVendorAreas(f.index.segdRecords[0], log):
      shown.add blk.name & ":" & $blk.fields.len
    doAssert shown == @["hit:0", "hit:1"], $shown
    let col = f.vendorColumn(reg, "v")
    doAssert col.absent == 2 and col.numbers[0].isNaN
    f.close()

  block when_on_a_later_field:
    # The loader refuses (when (field j)) with j at or after the field, but a target can be
    # built by hand: a (when) on itself and a cycle (a on b, b on a). fieldIsOn ends and
    # agrees with decodeTarget, which reads a later field's raw value (its own (when) not yet
    # worked out). Recursing into a later field never ended (a stack overflow).
    var reg = registry("""(.nif27)
(vendormap "m" (version 1) (match (format segd))
  (target (kind traceExt) (extension 2) (name c)
    (field a (at 1) (enc u8))
    (field b (at 2) (enc u8) (when (field a) (range 0 9)))
    (field s (at 3) (enc u8))))""")
    template t: untyped = reg.maps[0].targets[0]
    var onA = t.fields[1].conds[0]
    onA.fieldIndex = 1
    onA.fieldName = "b"
    t.fields[0].conds.add onA # a on b, b on a
    var onSelf = t.fields[1].conds[0]
    onSelf.fieldIndex = 2
    onSelf.fieldName = "s"
    t.fields[2].conds.add onSelf # s on itself
    for (x, y, z) in [(5, 5, 5), (5, 50, 50), (50, 5, 5), (50, 50, 50)]:
      var b = newSeq[byte](32)
      b[0] = byte(x)
      b[1] = byte(y)
      b[2] = byte(z)
      var blk: VendorBlock
      var problems: seq[string]
      t.decodeTarget(b, boBig, blk, problems)
      for i, fp in t.fields:
        doAssert t.fieldIsOn(i, b, boBig, VendorContext()) == (fp.name in blk),
          fp.name & " " & $(x, y, z)
    var f = openSeismicBytes(bytesOf(build([RecSpec(manufacturer: 9, second: 1, traces: 2,
      exts: 1)])), "cycle")
    discard f.vendorColumn(reg, "a")
    discard f.vendorColumn(reg, "s")
    f.close()

  block timing_and_allocations:
    # 100k traces (2000 in a debug build): per-trace allocation of the numeric path.
    let n = when defined(release) or defined(danger): 100_000 else: 2000
    # A channel set holds at most 9999 traces: records of 5000.
    var specs: seq[RecSpec]
    for i in 0 ..< n div 5000 + 1:
      specs.add RecSpec(manufacturer: 9, second: 1, traces: min(5000, n - 5000 * i), exts: 2)
    if specs[^1].traces == 0: specs.setLen specs.len - 1
    var f = openSeismicBytes(bytesOf(build(specs)), "big")
    let reg = registry()
    # The same records with 10 traces each: only the per-record set-up is common.
    var small: seq[RecSpec]
    for s in specs: small.add RecSpec(manufacturer: 9, second: 1, traces: 10, exts: 2)
    var f2 = openSeismicBytes(bytesOf(build(small)), "small")
    discard f.vendorColumn(reg, "gain") # warm
    discard f2.vendorColumn(reg, "gain")
    let a0 = allocs()
    discard f2.vendorColumn(reg, "gain")
    let a1 = allocs()
    let t0 = getMonoTime()
    let col = f.vendorColumn(reg, "gain")
    let dt = getMonoTime() - t0
    let a2 = allocs()
    doAssert col.numbers.len == n and col.absent == 0
    let ci0 = allocs()
    let t1 = getMonoTime()
    let ci = f.vendorColumnInt(reg, "tUs")
    let dti = getMonoTime() - t1
    let ci1 = allocs()
    doAssert ci.values.len == n and ci.present[n - 1]
    echo "vendorColumn (f32 field, ", n, " traces, 2 extension blocks): ",
      formatFloat(dt.inNanoseconds.float / 1e6, ffDecimal, 2), " ms (",
      formatFloat(dt.inNanoseconds.float / n.float, ffDecimal, 0), " ns/trace); vendorColumnInt ",
      "(i64 under (when (record ...))): ", formatFloat(dti.inNanoseconds.float / 1e6, ffDecimal, 2),
      " ms; allocations: ", a1 - a0, " for ", specs.len * 10, " traces, ", a2 - a1, " for ", n,
      " traces, ",
      ci1 - ci0, " for the integer column"
    when defined(nimAllocStats):
      # The same for 10 traces as for n: nothing is allocated per trace.
      doAssert a2 - a1 == a1 - a0, $(a2 - a1) & " vs " & $(a1 - a0)
      doAssert ci1 - ci0 <= a1 - a0 + 2, $(ci1 - ci0)
    f.close()
    f2.close()

when isMainModule: main()
