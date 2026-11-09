## SEG-2 reader, trace index, keys and `openSeismic` detection (task 11.1);
## writer, named fields, export and conversions (task 11.2).
## No SEG-2 sample file exists, so every file here is built by the test.

import std/[assertions, os, math, strutils, options, times]
import parseSEG/common/[errors, years]
import parseSEG/io/[diskio, memsource]
import parseSEG/seg2/[reader as seg2reader, writer as seg2writer]
import parseSEG/segy/[reader as segyreader, writer as segywriter, samples as segysamples]
import parseSEG/segd/[reader as segdreader, revconvert]
import parseSEG/model/[traceindex, gathers, headerfields, headernif, prefetch, summary,
  headerlist, edit]
import parseSEG/[convert, seg2convert]
import parseSEG/survey/writeback
import ./utils/testutils

let tmp = scratchDir("parseseg_tseg2")

# ------------------------------------------------------------ builder --

type
  TraceSpec = object
    format: int
    samples: seq[float64]   ## Values to encode (format 3: m * 2^e, see `f20`).
    f20: seq[(int, int)]    ## Format 3: (mantissa word, exponent) per sample.
    strings: seq[string]
    numSamples = -1         ## Override of the written count.
    dataSize = -1           ## Override of the written Data Block size.
    blockId = 0x4422

  FileSpec = object
    order: ByteOrder
    strings: seq[string]
    traces: seq[TraceSpec]
    stringTerm = "\0"
    lineTerm = "\n"
    revision = 1
    extraPointers = 0       ## Unused pointer slots (M = 4 * (N + extra)).
    pointers: seq[int]      ## Overrides of trace pointers (-1 keeps the real one).
    reverse = false         ## Lay the traces out in reverse pointer order.
    count = -1              ## Override of N.
    entryPad = 0            ## NULs after each string's terminator.

proc u16(b: var seq[byte], v: int, o: ByteOrder) =
  let at = b.len
  b.setLen at + 2
  putNum(b, at, uint16(v), o)

proc u32(b: var seq[byte], v: int, o: ByteOrder) =
  let at = b.len
  b.setLen at + 4
  putNum(b, at, uint32(v), o)

proc pad4(b: var seq[byte]) =
  while b.len mod 4 != 0: b.add 0

proc stringList(b: var seq[byte], strs: seq[string], s: FileSpec) =
  for x in strs:
    let n = 2 + x.len + s.stringTerm.len + s.entryPad
    b.u16(n, s.order)
    for c in x: b.add byte(c)
    for c in s.stringTerm: b.add byte(c)
    for _ in 0 ..< s.entryPad: b.add 0
  b.u16(0, s.order)
  b.pad4

proc payload(t: TraceSpec, o: ByteOrder): seq[byte] =
  case t.format
  of 1:
    for x in t.samples: result.u16(int(cast[uint16](int16(x))), o)
  of 2:
    for x in t.samples: result.u32(int(cast[uint32](int32(x))), o)
  of 3:
    var i = 0
    while i < t.f20.len:
      var e = 0
      for k in 0..3:
        if i + k < t.f20.len: e = e or (t.f20[i + k][1] shl (4 * k))
      result.u16(e, o)
      for k in 0..3:
        result.u16(if i + k < t.f20.len: t.f20[i + k][0] else: 0, o)
      i += 4
  of 4:
    for x in t.samples:
      let at = result.len
      result.setLen at + 4
      putNum(result, at, float32(x), o)
  of 5:
    for x in t.samples:
      let at = result.len
      result.setLen at + 8
      putNum(result, at, x, o)
  else:
    for x in t.samples: result.u32(0, o)

proc build(s: FileSpec): seq[byte] =
  let o = s.order
  let n = s.traces.len
  let m = 4 * (n + s.extraPointers)
  var fdb: seq[byte]
  fdb.u16(0x3A55, o)
  fdb.u16(s.revision, o)
  fdb.u16(m, o)
  fdb.u16(if s.count >= 0: s.count else: n, o)
  fdb.add byte(s.stringTerm.len)
  for k in 0..1: fdb.add(if k < s.stringTerm.len: byte(s.stringTerm[k]) else: 0)
  fdb.add byte(s.lineTerm.len)
  for k in 0..1: fdb.add(if k < s.lineTerm.len: byte(s.lineTerm[k]) else: 0)
  fdb.setLen 32
  let ptrAt = fdb.len
  fdb.setLen ptrAt + m
  fdb.stringList(s.strings, s)
  var blocks = newSeq[seq[byte]](n)
  for i, t in s.traces:
    var tdb: seq[byte]
    tdb.u16(t.blockId, o)
    tdb.u16(0, o) # block size, patched below
    let data = t.payload(o)
    var padded = data
    padded.pad4
    tdb.u32(if t.dataSize >= 0: t.dataSize else: padded.len, o)
    let ns = if t.numSamples >= 0: t.numSamples
             elif t.format == 3: t.f20.len
             else: t.samples.len
    tdb.u32(ns, o)
    tdb.add byte(t.format)
    tdb.setLen 32
    tdb.stringList(t.strings, s)
    putNum(tdb, 2, uint16(tdb.len), o)
    blocks[i] = tdb & padded
  result = fdb
  var at = newSeq[int](n)
  let order = if s.reverse: (block: (var r: seq[int]; for i in countdown(n - 1, 0): r.add i; r))
              else: (block: (var r: seq[int]; for i in 0..<n: r.add i; r))
  for i in order:
    at[i] = result.len
    result.add blocks[i]
  for i in 0..<n:
    let p = if i < s.pointers.len and s.pointers[i] >= 0: s.pointers[i] else: at[i]
    putNum(result, ptrAt + 4 * i, uint32(p), o)

proc save(b: seq[byte], name: string): string =
  result = tmp / name
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(result, s)

proc codes(log: DiagLog, sev: Severity): seq[DiagCode] =
  for d in log:
    if d.severity == sev: result.add d.code

proc messages(log: DiagLog): string =
  for d in log: result.add $d & "\n"

let ramp = @[1.0, -2.0, 3.0, -4.0, 100.0, -32768.0, 32767.0, 0.0]
let f20Words = @[(0x0001, 0), (0xFFFE, 0), (0x7FFF, 15), (0x8000, 3), (0x0003, 2), (0, 0),
  (0x1234, 1), (0xFFFF, 0)]
  # 1, -1 (one's complement), 32767 * 2^15, -32767 * 8, 12, 0, 0x2468, -0
let f20Values = @[1.0, -1.0, 32767.0 * 32768.0, -32767.0 * 8.0, 12.0, 0.0, 9320.0, 0.0]

proc allFormats(order: ByteOrder): FileSpec =
  FileSpec(order: order,
    strings: @["ACQUISITION_DATE 01/APR/1988", "ACQUISITION_TIME 15:30:00",
      "SHOT_SEQUENCE_NUMBER 7", "TRACE_SORT AS_ACQUIRED", "UNITS METERS"],
    traces: @[
      TraceSpec(format: 1, samples: ramp, strings: @["CHANNEL_NUMBER 1", "DELAY 0.0",
        "RECEIVER VERTICAL_GEOPHONE", "RECEIVER_LOCATION 10.0", "SAMPLE_INTERVAL 0.00025",
        "SOURCE_LOCATION 0.0"]),
      TraceSpec(format: 2, samples: @[1.0, -1.0, 2147483647.0, -2147483648.0],
        strings: @["CHANNEL_NUMBER 2", "RECEIVER_LOCATION 20.0", "SAMPLE_INTERVAL 0.0005",
          "SOURCE_LOCATION 0.0"]),
      TraceSpec(format: 3, f20: f20Words, strings: @["CHANNEL_NUMBER 3",
        "RECEIVER_LOCATION 30 4 -1", "SAMPLE_INTERVAL 0.00025", "SOURCE_LOCATION 0 0 0"]),
      TraceSpec(format: 4, samples: @[0.5, -1.25, 1e10, -3.0, 7.0],
        strings: @["CHANNEL_NUMBER 4", "RECEIVER_LOCATION 40.0", "SAMPLE_INTERVAL 0.00025",
          "SOURCE_LOCATION 0.0"]),
      TraceSpec(format: 5, samples: @[0.1, -1e-300, 1e300, 2.0],
        strings: @["CHANNEL_NUMBER 5", "RECEIVER_LOCATION 50.0", "SAMPLE_INTERVAL 0.00025",
          "SOURCE_LOCATION 0.0"])])

# -------------------------------------------------------------- tests --

block detection:
  for o in [boLittle, boBig]:
    let b = build(allFormats(o))
    doAssert isSeg2(b) and detectKind(b) == skSeg2
    doAssert seg2Order(b) == some(o)
    doAssert b[0] == (if o == boLittle: 0x55 else: 0x3A)
  doAssert not isSeg2([0x55'u8, 0x3A]) # too short for the fixed part
  doAssert not isSeg2(newSeq[byte](64))
  var junk = newSeq[byte](64)
  junk[0] = 0x3A
  junk[1] = 0x55 # the ID alone, with an implausible fixed part
  doAssert not isSeg2(junk) and detectKind(junk) == skUnknown

block all_formats_both_orders:
  for o in [boLittle, boBig]:
    let path = build(allFormats(o)).save("formats_" & $o & ".sg2")
    var f = openSeismic(path, keys = true)
    doAssert f.kind == skSeg2 and f.len == 5 and f.recordCount == 1, f.index.log.messages
    doAssert f.index.log.len == 0, f.index.log.messages
    doAssert f.index.seg2.order == o and f.index.seg2.revision == 1
    doAssert f.index.codecs.len == 5 and f.index.prefersFloat64
    doAssert f.maxSamples == 8
    let t = f.readTraces(0 ..< f.len, float64)
    doAssert t.shape == [5, 8]
    for k, x in ramp: doAssert t[0, k] == x
    doAssert t[1, 0] == 1 and t[1, 1] == -1 and t[1, 2] == 2147483647.0 and
      t[1, 3] == -2147483648.0 and t[1, 4] == 0
    for k, x in f20Values: doAssert t[2, k] == x, $k & ": " & $t[2, k]
    # the summary and the (raw) header listing
    let sm = f.summary
    doAssert sm.standard == skSeg2 and sm.revision.major == 1 and sm.byteOrder == o
    doAssert sm.formatCode == -1 and sm.decodable and sm.traceCount == 5 # five formats
    doAssert sm.sampleIntervalUs.isNaN and sm.samplesPerTrace == -1 and sm.recordLengthMs.isNaN # mixed
    doAssert sm.firstFieldRecord == 7 and sm.lastFieldRecord == 7 and sm.coordinateUnits == cuMeters
    # the listing: fixed fields, then one row per keyword string
    let fh = f.fileHeaders
    doAssert fh.len == fieldNames(hbSeg2File).len + 5, $fh.len
    doAssert fh[0].blockName == "file" and fh[0].kind == hbSeg2File and fh[0].field == "blockId" and
      fh[0].offset == 0 and fh[0].size == 2 and fh[0].value == toFieldValue(0x3A55)
    doAssert fh[0].blockSize == int(f.index.entries[0].offset) # the strings end before trace 0
    let units = fh[fh.len - 1]
    doAssert units.field == "UNITS" and units.value == toFieldValue("METERS") and
      units.size == 2 + "UNITS METERS".len + 1 and units.blockOffset == 0
    doAssert fh[fieldNames(hbSeg2File).len].offset == 32 + int(f.index.seg2.pointerBytes)
    let th = f.traceHeaders(1)
    let e1 = f.index.entries[1]
    doAssert th.len == fieldNames(hbSeg2Trace).len + 4
    doAssert th[0].blockName == "trace" and th[0].kind == hbSeg2Trace and
      th[0].offset == e1.offset and th[0].blockSize == int(e1.headerBytes)
    doAssert th[1].field == "blockSize" and th[1].value == toFieldValue(int(e1.headerBytes))
    let ch = th[fieldNames(hbSeg2Trace).len]
    doAssert ch.field == "CHANNEL_NUMBER" and ch.value == toFieldValue("2") and
      ch.offset == e1.offset + 32 and ch.size == 2 + "CHANNEL_NUMBER 2".len + 1
    doAssert f.recordHeaders(0).len == 0
    doAssert t[3, 0] == 0.5 and t[3, 1] == -1.25 and t[3, 2] == float64(float32(1e10))
    doAssert t[4, 0] == 0.1 and t[4, 1] == -1e-300 and t[4, 2] == 1e300 and t[4, 3] == 2.0
    # float32 and an index list read the same samples
    let s = f.readTraces([3, 0])
    doAssert s.shape == [2, 8] and s[0, 4] == 7'f32 and s[1, 0] == 1'f32
    # sample intervals and keys
    doAssert f.sampleIntervalUs(0) == 250 and f.sampleIntervalUs(1) == 500
    let k0 = f.traceKeys(0)
    doAssert k0.record == 7 and k0.channel == 1 and k0.component == 12
    doAssert k0.srcX == 0 and k0.srcY == 0 and k0.rcvX == 10 and k0.rcvY == 0
    doAssert k0.offset == 10 and k0.cmpX == 5 and k0.srcZ.isNaN
    let k2 = f.traceKeys(2)
    doAssert k2.rcvX == 30 and k2.rcvY == 4 and k2.rcvZ == -1 and k2.srcZ == 0
    doAssert k2.offset == hypot(30.0, 4.0) and k2.record == 7 # the file's
    doAssert k0.time == 575_911_800.0 and k2.time == k0.time # ACQUISITION_DATE/TIME
    let g = f.gathers
    doAssert g.len == 1 and g[0].kind == gkShot and g[0].traces == 0..4
    # the descriptor blocks, re-read from the map
    let tr = f.seg2Trace(2)
    doAssert tr.valid and tr.format == some(s2Float20) and tr.numSamples == 8
    doAssert tr.receiverLocation.get.values == 3 and tr.channelNumber == some(3'i64)
    doAssert f.index.seg2.traceSort == some(tsAsAcquired)
    doAssert f.index.seg2.units == some(unMeters)
    doAssert f.index.seg2.acquisitionTime.get == 575_911_800.0 # 1988-04-01 15:30 UTC
    # read-ahead uses the same codecs
    var p = newPrefetcher[float64](f, 0 ..< f.len, chunkTraces = 2)
    var c: PrefetchChunk[float64]
    var got = 0
    while p.next(c):
      doAssert c.failed == 0 and c.samples == t[c.first ..< c.first + c.count, _]
      got += c.count
    doAssert got == 5
    p.close()
    f.close()

block standalone_reader:
  let b = build(allFormats(boBig))
  var log: DiagLog
  let f = readSeg2(b, log, "mem")
  doAssert f.pointers.len == 5 and f.strings.len == 5 and log.len == 0
  var n = 0
  for t in traces(b, f, log, "mem"):
    var dst = newSeq[float32](10)
    readSamples(b, f, t, dst)
    if t.formatCode == 1: doAssert dst[0 ..< 8] == @[1'f32, -2, 3, -4, 100, -32768, 32767, 0]
    doAssert dst[9] == 0
    inc n
  doAssert n == 5 and log.len == 0
  doAssertRaises(ValueError): discard readSeg2Trace(b, f, 5, log)


block format3_twos_complement_and_ragged_count:
  # 3 samples: not a multiple of 4 (warning); the last group is read whole.
  let words = @[(0xFFFE, 1), (0x0005, 0), (0x8001, 0)]
  let path = build(FileSpec(order: boLittle,
    traces: @[TraceSpec(format: 3, f20: words)])).save("f20.sg2")
  var f = openSeismic(path)
  doAssert f.index.log.codes(sevWarning) == @[dcBadValue], f.index.log.messages
  doAssert f.len == 1 and f.traceEntry(0).numSamples == 3
  let ones = f.readTraces(0..0, float64)
  doAssert ones[0, 0] == -2.0 and ones[0, 1] == 5.0 and ones[0, 2] == -32766.0
  f.close()
  var g = openSeismic(path, twosComplement8015 = true)
  let twos = g.readTraces(0..0, float64)
  doAssert twos[0, 0] == -4.0 and twos[0, 1] == 5.0 and twos[0, 2] == -32767.0
  g.close()

block odd_keyword_strings:
  # Two-character terminators, NULs after the terminator, tabs and repeated
  # spaces, mixed case, no value, an unknown keyword, unsorted, NOTE not last.
  let spec = FileSpec(order: boLittle, stringTerm: "\r\n", lineTerm: "\n\r", entryPad: 3,
    strings: @["NOTE first line\n\rsecond line", "units\t\tFEET", "COMPANY  Acme  Seismic ",
      "JOB_ID", "VENDOR_KEY x=1", "ACQUISITION_DATE 29/02/96", "ACQUISITION_TIME 23:59:30.5"],
    traces: @[TraceSpec(format: 1, samples: @[1.0, 2.0],
      strings: @["SAMPLE_INTERVAL\t1.5E-4", "Receiver_Location  12.5   -3  2",
        "RECEIVER_GEOMETRY [2/4] 1 2 3", "DATUM 100", "TRACE_TYPE test_data", "LINE_ID L7"])])
  let path = build(spec).save("strings.sg2")
  var f = openSeismic(path, keys = true)
  let fdb = f.index.seg2
  doAssert fdb.stringTerm == "\r\n" and fdb.lineTerm == "\n\r"
  doAssert fdb.strings.len == 7
  doAssert fdb.strings[1].key == "units" and fdb.strings[1].value == "FEET"
  doAssert fdb.units == some(unFeet) # matched case-insensitively
  doAssert fdb.value("COMPANY") == some("Acme  Seismic")
  doAssert fdb.value("JOB_ID") == some("") and "job_id" in fdb
  doAssert fdb.value("VENDOR_KEY") == some("x=1") and fdb.value("CLIENT").isNone
  doAssert fdb.noteLines(fdb.lineTerm) == @["first line", "second line"]
  doAssert fdb.acquisitionTime.get == 825_638_370.5 # 1996-02-29 23:59:30.5 UTC
  doAssert fdb.traceSort.isNone
  let t = f.seg2Trace(0)
  doAssert t.sampleInterval == some(1.5e-4) and f.sampleIntervalUs(0) == 150
  doAssert t.receiverLocation.get == Seg2Location(x: 12.5, y: -3, z: 2, values: 3)
  doAssert t.numbers("RECEIVER_GEOMETRY").len == 0 # "[2/4]" is not a number
  doAssert t.traceType == some(ttTestData) and t.sourceLocation.isNone
  let k = f.traceKeys(0)
  doAssert k.rcvX == 12.5 and k.rcvZ == 102 and k.srcX.isNaN and k.rcvLine.isNaN
  doAssert k.time == 825_638_370.5
  doAssert not f.index.isSeismic(0) # TEST_DATA is auxiliary
  # style problems are info only, once each per file
  let infos = f.index.log.codes(sevInfo)
  doAssert infos.len == 3 and f.index.log.count(sevWarning) == 0, f.index.log.messages
  f.close()

block bad_pointers_and_blocks:
  var spec = allFormats(boLittle)
  spec.traces[3].blockId = 0x1234 # no Trace Descriptor Block ID
  spec.pointers = @[-1, 1_000_000, 4]     # past the end; into the File Descriptor Block
  let path = build(spec).save("badptr.sg2")
  var f = openSeismic(path, keys = true)
  doAssert f.kind == skSeg2 and f.len == 5
  doAssert f.index.log.codes(sevError) == @[dcBadValue, dcBadValue, dcBadValue],
    f.index.log.messages
  for i in [1, 2, 3]:
    doAssert f.traceEntry(i).numSamples == 0 and not f.seg2Trace(i).valid
  doAssert f.traceEntry(1).offset == 1_000_000
  var log: DiagLog
  let t = f.readTraces(0 ..< f.len, log, float64)
  doAssert log.len == 3 and log[0].loc.trace == 1 and log[0].loc.record == 0
  doAssert t[0, 0] == 1 and t[4, 3] == 2 and t[1, 0] == 0
  doAssertRaises(SegFormatError): discard f.readTraces(0 ..< f.len)
  doAssert f.readTraces([0, 4]).shape == [2, 8]
  f.close()

block undefined_format_short_data_and_truncation:
  var spec = FileSpec(order: boBig, traces: @[
    TraceSpec(format: 9, samples: @[1.0, 2.0]),                       # undefined code
    TraceSpec(format: 2, samples: @[1.0, 2.0, 3.0, 4.0], dataSize: 8), # holds 2 of 4
    TraceSpec(format: 4, samples: @[5.0, 6.0, 7.0, 8.0])])
  var b = build(spec)
  b.setLen b.len - 8 # the last Data Block is cut short
  let path = b.save("short.sg2")
  var f = openSeismic(path)
  let log = f.index.log
  doAssert log.codes(sevError) == @[dcUnsupportedFormat, dcTruncated], log.messages
  doAssert log.codes(sevWarning) == @[dcInconsistent], log.messages # 2 of 4 samples
  doAssert f.traceEntry(0).numSamples == 2 and f.traceEntry(1).numSamples == 2
  var rl: DiagLog
  let t = f.readTraces(0..2, rl)
  doAssert rl.codes(sevError) == @[dcUnsupportedFormat, dcTruncated], rl.messages
  doAssert t[1, 0] == 1 and t[1, 1] == 2 and t[1, 2] == 0 and t[2, 0] == 0
  f.close()

block fixed_part_problems:
  # N larger than M/4 is clamped; revision 2 and odd terminator lengths warn.
  var spec = allFormats(boLittle)
  spec.count = 9
  spec.revision = 2
  let path = build(spec).save("clamp.sg2")
  var f = openSeismic(path)
  doAssert f.len == 5
  doAssert f.index.log.codes(sevError) == @[dcInconsistent], f.index.log.messages
  doAssert f.index.log.codes(sevWarning) == @[dcUnsupportedRevision]
  f.close()
  # a CHANNEL_NUMBER in only some traces
  var some = allFormats(boBig)
  some.traces[1].strings = @["SAMPLE_INTERVAL 0.001"]
  var g = openSeismic(build(some).save("channels.sg2"))
  doAssert g.index.log.codes(sevWarning) == @[dcInconsistent], g.index.log.messages
  g.close()

block pointers_in_any_order:
  var spec = allFormats(boBig)
  spec.reverse = true
  spec.extraPointers = 3 # unused pointer slots
  var f = openSeismic(build(spec).save("reverse.sg2"))
  doAssert f.len == 5 and f.index.log.len == 0, f.index.log.messages
  doAssert f.traceEntry(0).offset > f.traceEntry(4).offset
  doAssert f.readTraces(0..0)[0, 1] == -2
  f.close()

block overlapping_blocks:
  # trace 4's pointer repeats trace 0's: both decode, the overlap is a warning
  var b = build(allFormats(boLittle))
  let p0 = getNum[uint32](b, 32, boLittle)
  putNum(b, 32 + 4 * 4, p0, boLittle)
  var f = openSeismic(b.save("overlap.sg2"))
  doAssert f.index.log.codes(sevWarning) == @[dcInconsistent], f.index.log.messages
  doAssert f.readTraces(4..4)[0, 0] == 1
  f.close()

block format_specific_features:
  let path = build(allFormats(boLittle)).save("features.sg2")
  var f = openSeismic(path)
  try:
    discard f.traceField(0, "trace.sampleInterval") # SEG-Y's name; SEG-2 has SAMPLE_INTERVAL
    doAssert false
  except ValueError as e:
    doAssert "keyword" in e.msg, e.msg
  doAssert f.findFileField("binary.formatCode").isNone
  doAssert f.blockKind(hsTrace, 0, "trace") == some(hbSeg2Trace)
  doAssert f.blockKind(hsFile, 0, "file") == some(hbSeg2File)
  f.close()
  # SEG-2 is indexed from a map, not a stream
  let src = openDiskSource(path)
  doAssertRaises(ValueError): discard buildIndex(src, skSeg2)
  src.close()
  let m = openMemFileSource(path)
  doAssert buildIndex(m, skSeg2).len == 5
  m.close()
  var segy = openSeismic(path)
  doAssertRaises(ValueError): discard segy.seg2Trace(5)
  segy.close()
  doAssertRaises(ValueError): discard segy.seg2Trace(0) # closed

# ------------------------------------------------------- 11.2: writer --

func failed(log: DiagLog): bool = log.count(sevError) + log.count(sevFatal) > 0

func has(log: DiagLog, text: string): bool =
  for d in log:
    if text in d.msg: return true

proc readAll(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc rewrite(src, dst: string, floats = false) =
  ## Reads `src` and writes it back with the writer (raw Data Blocks, or
  ## decoded floats re-encoded).
  var f = openSeismic(src)
  var w = openSeg2Writer(dst, f.index.seg2)
  for i in 0 ..< f.len:
    let t = f.seg2Trace(i)
    if floats:
      w.writeTrace(t, f.readTraces(i..i, float64).toFlatSeq[0 ..< int(t.numSamples)])
    else:
      w.writeTrace(t, f.copyBytes(t.dataOffset, int(t.dataSize)))
  w.close()
  f.close()

block encode_decode_all_formats:
  for o in [boLittle, boBig]:
    for fmt in Seg2Format:
      let vals = if fmt == s2Float20: f20Values
                 elif fmt == s2Int32: @[1.0, -1.0, 2147483647.0, -2147483648.0]
                 elif fmt == s2Float32: @[0.5, -1.25, 17179869184.0, -3.0]
                 else: ramp
      for twos in [false, true]:
        var b = newSeq[byte](dataBytes(fmt, vals.len))
        encodeSeg2Samples(fmt, vals, b, o, twos)
        var back = newSeq[float64](vals.len)
        decodeSeg2Samples(fmt, b, back, o, twos)
        doAssert back == vals, $fmt & " " & $o & " " & $back
  var b = newSeq[byte](10)
  doAssertRaises(SegFormatError): encodeSeg2Samples(s2Int16, [40000.0], b, boLittle)
  doAssertRaises(SegFormatError): encodeSeg2Samples(s2Int32, [NaN], b, boLittle)
  doAssertRaises(SegFormatError): encodeSeg2Samples(s2Float20, [32768.0 * 32768.0], b, boLittle)
  doAssertRaises(ValueError): encodeSeg2Samples(s2Float64, [1.0, 2.0], b, boLittle)
  # format 3: the smallest exponent; -1 is one's complement 0xFFFE
  encodeSeg2Samples(s2Float20, [-1.0, 65536.0], b, boLittle)
  doAssert getNum[uint16](b, 2, boLittle) == 0xFFFE and getNum[uint16](b, 0, boLittle) == 0x0020
  doAssert getNum[uint16](b, 4, boLittle) == 0x4000 # 65536 = 16384 * 2^2

block number_text_and_strings:
  doAssert formatNumber(12.0) == "12" and formatNumber(-3.0) == "-3"
  doAssert formatNumber(0.00025) == "0.00025" and formatNumber(1.5e-30) == "1.5E-30"
  doAssert formatNumber(1e20) == "1E20" and formatNumber(NaN) == ""
  doAssert parseFloat(formatNumber(0.1 + 0.2)) == 0.1 + 0.2
  var f = initSeg2File()
  f["UNITS"] = "FEET"
  f["NOTE"] = "a"
  f["TRACE_SORT"] = "AS_ACQUIRED"
  f["units"] = "METERS" # case-insensitive: replaces
  doAssert f.strings.len == 3 and f.value("UNITS") == some("METERS")
  f.strings.sortStrings()
  doAssert f.strings[0].key == "TRACE_SORT" and f.strings[^1].key == "NOTE"

block writer_round_trip_byte_for_byte:
  for o in [boLittle, boBig]:
    for extra in [0, 3]:
      var spec = allFormats(o)
      spec.extraPointers = extra
      spec.stringTerm = (if extra == 0: "\0" else: "\r\n")
      let path = build(spec).save("rt_" & $o & $extra & ".sg2")
      rewrite(path, tmp / "rt_out.sg2")
      doAssert readAll(path) == readAll(tmp / "rt_out.sg2"), $o & " " & $extra
  # decoded floats re-encode to the same bytes (format 3 too: its words are minimal)
  var spec = allFormats(boLittle)
  spec.traces.delete(2) # 0xFFFF (-0) and non-minimal format-3 words do not survive a decode
  let path = build(spec).save("rt_floats.sg2")
  rewrite(path, tmp / "rt_floats_out.sg2", floats = true)
  doAssert readAll(path) == readAll(tmp / "rt_floats_out.sg2")

block writer_validation:
  var fdb = initSeg2File(boBig)
  doAssertRaises(ValueError): discard openSeg2Writer(tmp / "w0.sg2", fdb) # no traceCount
  fdb.traceCount = 1
  fdb["BAD KEY"] = "x"
  doAssertRaises(SegFormatError): discard openSeg2Writer(tmp / "w1.sg2", fdb)
  var w = openSeg2Writer(tmp / "w1.sg2", fdb, Seg2WriteOptions(lenient: true))
  doAssert w.log.len == 1 and w.log[0].severity == sevWarning
  var t = Seg2Trace(formatCode: 4)
  t["SAMPLE_INTERVAL"] = "0.001"
  t["NOTE"] = "zero\0here" # holds the String Terminator
  w.writeTrace(t, [1.0, 2.0])
  doAssert w.log.len == 2
  doAssertRaises(ValueError): w.writeTrace(t, [1.0]) # the pointer subblock is full
  w.close()
  var f = openSeismic(tmp / "w1.sg2")
  doAssert f.kind == skSeg2 and f.len == 1 and f.index.seg2.order == boBig
  doAssert f.readTraces(0..0, float64)[0, 1] == 2.0
  doAssert f.seg2Trace(0).value("NOTE") == some("zero") # cut by the reader, as warned
  f.close()
  var fdb2 = initSeg2File()
  fdb2.traceCount = 2
  var w2 = openSeg2Writer(tmp / "w2.sg2", fdb2)
  doAssertRaises(SegFormatError): w2.writeTrace(Seg2Trace(formatCode: 9), [1.0])
  doAssertRaises(ValueError): w2.writeTrace(Seg2Trace(formatCode: 1, numSamples: 4), [1'u8, 2])
  doAssertRaises(SegFormatError): w2.close() # no traces
  doAssert w2.log.len == 1

# ------------------------------------------- 11.2: named fields, export --

block named_fields_listing_and_edits:
  let path = build(allFormats(boLittle)).save("named.sg2")
  var f = openSeismic(path)
  doAssert f.traceField(0, "trace.SAMPLE_INTERVAL") == toFieldValue("0.00025")
  doAssert f.traceField(0, "trace.sample_interval") == toFieldValue("0.00025")
  doAssert f.traceField(1, "trace.numSamples") == toFieldValue(4)
  doAssert f.traceField(2, "trace.formatCode") == toFieldValue(3)
  doAssert f.fileField("file.UNITS") == toFieldValue("METERS")
  doAssert f.fileField("file.revision") == toFieldValue(1)
  doAssert f.fileField("file.traceCount") == toFieldValue(5)
  doAssert f.findTraceField(0, "trace.NO_SUCH").isNone
  doAssert f.findTraceField(0, "ext1.x").isNone
  doAssert "blockSize" in fieldNames(hbSeg2Trace) and "pointerBytes" in fieldNames(hbSeg2File)
  doAssert f.seg2Strings(-1).len == 5 and f.seg2Strings(0).len == 6
  doAssert f.seg2Strings(-1)[4].key == "UNITS" and f.seg2Strings(-1)[4].value == "METERS"
  let s2 = f.seg2Strings(2)[1]
  doAssert s2.key == "RECEIVER_LOCATION" and s2.value == "30 4 -1"
  doAssertRaises(ValueError): discard f.seg2Strings(5)
  # header export: fixed fields and strings; an unchanged import changes nothing
  f.exportHeaders(tmp / "named.nif")
  let doc = readFile(tmp / "named.nif")
  doAssert "(standard seg2)" in doc and "(s \"UNITS\" \"METERS\")" in doc and
    "(f numSamples 4)" in doc and "(block file" in doc, doc[0 ..< 400]
  f.close()
  let dry = importHeaders(path, tmp / "named.nif", ImportOptions(dryRun: true))
  doAssert dry.applied == 0 and dry.refused == 0 and not dry.log.failed, $dry.log
  # edits are refused: strings are variable length
  copyFile(path, tmp / "named_edit.sg2")
  var ed = openEditor(tmp / "named_edit.sg2")
  doAssert not ed.setTraceField(0, "trace.SAMPLE_INTERVAL", toFieldValue("0.0005"))
  doAssert not ed.setFileField("file.revision", toFieldValue(1))
  doAssert ed.log.len == 2 and "variable length" in ed.log[0].msg, $ed.log
  ed.close()
  doAssert readAll(path) == readAll(tmp / "named_edit.sg2")

# ---------------------------------------------------- 11.2: conversions --

proc uniformSpec(o: ByteOrder, format = 4): FileSpec =
  ## Three traces with one sample interval, length and source.
  result = FileSpec(order: o, strings: @["ACQUISITION_DATE 01/04/2024",
    "ACQUISITION_TIME 10:20:30", "COMPANY ACME", "TRACE_SORT AS_ACQUIRED", "UNITS METERS",
    "NOTE line one\nline two"])
  for k in 0..2:
    result.traces.add TraceSpec(format: format, samples: @[1.0, -2.0, 3.5, float64(k), 0.0,
      100.0, -7.0, 8.0], strings: @["CHANNEL_NUMBER " & $(k + 1), "DELAY 0.004",
      "DESCALING_FACTOR 0.5", "LINE_ID 12", "RECEIVER VERTICAL_GEOPHONE",
      "RECEIVER_LOCATION " & $(10 * (k + 1)) & " 5 1.5", "RECEIVER_STATION_NUMBER " & $(101 + k),
      "SAMPLE_INTERVAL 0.001", "SHOT_SEQUENCE_NUMBER 42", "SKEW 0.0001", "SOURCE DYNAMITE",
      "SOURCE_LOCATION 0 0 2", "SOURCE_STATION_NUMBER 7", "STACK 2"])

proc sameSamples(a, b: string, n: int) =
  var x = openSeismic(a)
  var y = openSeismic(b)
  doAssert x.len == n and y.len == n, $y.index.log
  let tx = x.readTraces(0 ..< n, float64)
  let ty = y.readTraces(0 ..< n, float64)
  for i in 0 ..< n:
    for k in 0 ..< int(x.traceEntry(i).numSamples):
      doAssert tx[i, k] == ty[i, k], $i & "," & $k & ": " & $tx[i, k] & " vs " & $ty[i, k]
  x.close()
  y.close()

block seg2_to_segy:
  let path = build(allFormats(boLittle)).save("conv.sg2")
  let log = convertFile(path, tmp / "conv.sgy")
  doAssert not log.failed, $log
  doAssert log.has("CHANNEL_NUMBER") == false
  sameSamples(path, tmp / "conv.sgy", 5)
  var y = openSeismic(tmp / "conv.sgy", keys = true)
  doAssert y.kind == skSegy and y.index.segy.format == some(sfFloat64) # five formats, Rev 2.1
  doAssert y.traceField(2, "trace.traceNumberInField") == toFieldValue(3)
  doAssert y.traceField(0, "trace.fieldRecord") == toFieldValue(7)
  doAssert y.traceField(0, "trace.traceIdCode") == toFieldValue(12) # vertical geophone
  doAssert y.sampleIntervalUs(1) == 500 and y.sampleIntervalUs(0) == 250
  doAssert y.fileField("binary.measurementSystem") == toFieldValue(1)
  doAssert y.traceField(0, "trace.year") == toFieldValue(1988)
  let k = y.traceKeys(2)
  doAssert k.rcvX == 30 and k.rcvY == 4 and k.rcvZ == -1 and k.channel == 3
  doAssert "SEG-2 FILE STRINGS" in y.index.segy.text.text and
    "UNITS METERS" in y.index.segy.text.text
  y.close()
  # uniform data, Rev 1, int16 kept
  let p2 = build(uniformSpec(boBig, 1)).save("conv16.sg2")
  var o = ConvertOptions(revision: SegyRevision(major: 1, minor: 0))
  let l2 = convertFile(p2, tmp / "conv16.sgy", o)
  doAssert not l2.failed, $l2
  doAssert l2.has("SKEW") # no slot: listed
  var z = openSeismic(tmp / "conv16.sgy")
  doAssert z.index.segy.format == some(sfInt16)
  doAssert z.traceField(1, "trace.delayRecordingTime") == toFieldValue(4)
  doAssert z.traceField(1, "trace.numVertSummed") == toFieldValue(2)
  doAssert z.traceField(1, "trace.transductionUnits") == toFieldValue(3)
  z.close()
  sameSamples(p2, tmp / "conv16.sgy", 3)

block seg2_to_segd:
  let p = build(uniformSpec(boLittle)).save("tosegd.sg2")
  for rev in [(3'u8, 0'u8), (3'u8, 1'u8), (2'u8, 1'u8)]:
    let dst = tmp / ("tosegd_" & $rev[0] & $rev[1] & ".sgd")
    var o = ConvertOptions(target: skSegd)
    o.segd.revision = SegdRevision(major: rev[0], minor: rev[1])
    let log = convertFile(p, dst, o)
    doAssert not log.failed, $rev & " " & $log
    doAssert log.has("SKEW") and log.has("local"), $log
    var d = openSeismic(dst, keys = true)
    doAssert d.kind == skSegd and d.len == 3 and not d.index.log.failed, $d.index.log
    doAssert d.index.segdRecords[0].revision == SegdRevision(major: rev[0], minor: rev[1])
    doAssert d.index.segdRecords[0].format == some(sd8058)
    doAssert d.sampleIntervalUs(0) == 1000
    let k = d.traceKeys(1)
    doAssert k.record == 42 and k.channel == 2 and k.srcPoint == 7
    doAssert k.rcvPoint == 102 and k.rcvLine == 12, $k
    if rev[0] == 3:
      doAssert k.rcvX == 20 and k.rcvY == 5 and k.rcvZ == 1.5 and k.srcZ == 2, $k
      doAssert k.time == d.traceKeys(0).time and k.time == 1711966830.0, $k.time
    d.close()
    sameSamples(p, dst, 3)
  # mixed formats and intervals: one channel set each, float64 needs 8080
  let pm = build(allFormats(boBig)).save("tosegd_mixed.sg2")
  let lm = convertFile(pm, tmp / "tosegd_mixed.sgd", ConvertOptions(target: skSegd))
  doAssert not lm.failed, $lm
  var d = openSeismic(tmp / "tosegd_mixed.sgd", keys = true)
  doAssert d.index.segdRecords[0].format == some(sd8080) and d.len == 5
  # sets 250 µs x 8 samples (traces 0, 2), 500 x 4, 250 x 5, 250 x 4: written set by set
  doAssert d.index.segdRecords[0].scanTypes[0].channelSetCount == 4
  doAssert lm.has("reordered") and d.traceKeys(1).channel == 3
  d.close()
  # SEG-Y input cannot go to SEG-D
  let ly = convertFile(tmp / "conv.sgy", tmp / "no.sgd", ConvertOptions(target: skSegd))
  doAssert ly.isFatal and not fileExists(tmp / "no.sgd")

block to_seg2:
  # SEG-2 to SEG-2: big-endian, strings kept, samples exact
  let p = build(allFormats(boLittle)).save("re.sg2")
  var o = ConvertOptions(target: skSeg2)
  o.seg2.byteOrder = boBig
  let log = convertFile(p, tmp / "re_big.sg2", o)
  doAssert not log.failed, $log
  sameSamples(p, tmp / "re_big.sg2", 5)
  var a = openSeismic(p)
  var b = openSeismic(tmp / "re_big.sg2")
  doAssert b.index.seg2.order == boBig and b.index.seg2.strings == a.index.seg2.strings
  for i in 0..4: doAssert b.seg2Trace(i).strings == a.seg2Trace(i).strings
  a.close()
  b.close()
  # SEG-Y to SEG-2 (the file converted above): keys and samples come back
  let ly = convertFile(tmp / "conv.sgy", tmp / "from_segy.sg2", ConvertOptions(target: skSeg2))
  doAssert not ly.failed, $ly
  sameSamples(tmp / "conv.sgy", tmp / "from_segy.sg2", 5)
  var s = openSeismic(tmp / "from_segy.sg2", keys = true)
  doAssert s.kind == skSeg2 and s.index.seg2.order == boLittle
  doAssert s.index.codecs.len == 1 and s.index.codecs[0].seg2Format == some(s2Float64)
  doAssert s.fileField("file.UNITS") == toFieldValue("METERS")
  doAssert s.fileField("file.ACQUISITION_DATE") == toFieldValue("01/04/1988")
  doAssert "Converted from SEG-Y" in s.fileField("file.NOTE").text
  let k = s.traceKeys(2)
  doAssert k.rcvX == 30 and k.rcvY == 4 and k.channel == 3 and k.record == 7
  doAssert s.sampleIntervalUs(1) == 500
  doAssert s.traceField(0, "trace.TRACE_TYPE") == toFieldValue("SEISMIC_DATA")
  doAssert s.traceField(0, "trace.RECEIVER") == toFieldValue("VERTICAL_GEOPHONE")
  s.close()
  # SEG-D to SEG-2, with a format override
  var o4 = ConvertOptions(target: skSeg2)
  o4.seg2.format = s2t4
  let ld = convertFile(tmp / "tosegd_30.sgd", tmp / "from_segd.sg2", o4)
  doAssert not ld.failed, $ld
  sameSamples(tmp / "tosegd_30.sgd", tmp / "from_segd.sg2", 3)
  var g = openSeismic(tmp / "from_segd.sg2", keys = true)
  doAssert g.traceKeys(1).rcvPoint == 102 and g.traceKeys(1).rcvX == 20
  doAssert g.traceField(1, "trace.DELAY") == toFieldValue("0.004")
  doAssert g.traceField(1, "trace.DESCALING_FACTOR") == toFieldValue("0.5")
  g.close()

block geometry_write_back_is_refused:
  # Survey geometry is not written to SEG-2 yet: refused, with a fatal
  # diagnostic or a ValueError (10.5).
  let path = build(allFormats(boLittle)).save("geo.sg2")
  var f = openSeismic(path, keys = true)
  doAssertRaises ValueError: discard f.geometryChanges()
  f.close()
  let log = copyWithGeometry(path, tmp / "geo2.sg2", initSurveyGeometry()).log
  doAssert log.isFatal and "SEG-2" in log.messages
  doAssert not fileExists(tmp / "geo2.sg2")
  doAssert convertWithGeometry(path, tmp / "geo.sgy", initSurveyGeometry()).isFatal

# --------------------- Phase 13.3 review (R<reviewer>-<n>, as in PLAN.md) --

let r13 = scratchDir("parseseg_tseg2_r13")

proc put32(s: var string, at: int, v: uint32, order: ByteOrder) =
  for k in 0..3:
    let sh = if order == boLittle: 8 * k else: 8 * (3 - k)
    s[at + k] = char((v shr sh) and 0xFF)

proc tmpFiles(dir: string): seq[string] =
  for p in walkDir(dir):
    if p.path.endsWith(".tmp"): result.add p.path

# A small SEG-2 file (63.sgd's one trace) to damage.
let seg2 = r13 / "63.sg2"
doAssert not convertFile(exampleDir / "63.sgd", seg2, ConvertOptions(target: skSeg2)).isFatal

block r13_r4_1_seg2_sample_counts_are_bounded_by_the_file:
  # A 4 KB file declaring 2^32 - 1 samples (undefined format), or 2^30
  # samples in a 4 GB Data Block, made reads and conversions allocate
  # 4-17 GB and abort. Now the count is bounded by the bytes left in the file.
  var f = openSeismic(seg2)
  let (p, order) = (int(f.seg2Trace(0).offset), f.index.seg2.order)
  f.close()
  let good = readFile(seg2)
  var undefined = good
  undefined.put32(p + 8, 0xFFFF_FFFF'u32, order) # numSamples
  undefined[p + 12] = char(9)                    # an undefined format code
  var huge = good
  huge.put32(p + 4, 0xFFFF_FFF0'u32, order) # dataSize
  huge.put32(p + 8, 0x3FFF_FFFC'u32, order) # numSamples
  for (name, bytes) in [("undefined.sg2", undefined), ("huge.sg2", huge)]:
    let path = r13 / name
    writeFile(path, bytes)
    var g = openSeismic(path)
    doAssert g.len == 1 and int64(g.maxSamples) <= int64(bytes.len), $g.maxSamples
    var log: DiagLog
    let t = g.readTraces(0..0, log)
    doAssert t.shape[0] == 1 and t.shape[1] <= bytes.len
    doAssert log.count(sevError) == 1, $log # undecodable or truncated: a diagnostic
    g.close()
    for target in [skSegy, skSegd, skSeg2]:
      let dst = r13 / (name & "." & $target)
      let clog = convertFile(path, dst, ConvertOptions(target: target))
      doAssert clog.count(sevError) + clog.count(sevFatal) > 0, $target & " " & $clog
  doAssert tmpFiles(r13).len == 0

block r13_r1_1_seg2_summary_format_code:
  var f = openSeismic(seg2)
  doAssert f.index.codecs.len == 1
  doAssert f.summary.formatCode == ord(f.index.codecs[0].seg2Format.get), $f.summary.formatCode
  doAssert f.summary.formatCode == int(f.seg2Trace(0).formatCode)
  f.close()

block r13_r1_2_segy_to_seg2_times_use_the_time_scalar:
  # Delay 1505 with time scalar -10 is 150.5 ms: DELAY 0.1505 s (not 1.505).
  let path = r13 / "scalar.sgy"
  var y = SegyFile(text: initTextHeader(teEbcdic), byteOrder: boBig, format: some(sfFloat32),
    revision: SegyRevision(major: 1), extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  y.binary = SegyBinaryHeader(formatCode: 5, segyMajor: 1, samplesPerTrace: 10,
    sampleInterval: 1000, measurementSystem: 1)
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, y, initSegyWriteOptions(y, lenient = true))
  var t = SegyTrace(numSamples: 10, sampleInterval: 1000, samples: newSeq[byte](40))
  t.header = SegyTraceHeader(fieldRecord: 10, traceNumberInField: 1, numSamples: 10,
    sampleInterval: 1000, delayRecordingTime: 1505, timeScalar: -10, sourceStatic: 25,
    groupStatic: -5)
  w.writeTrace(t)
  w.close()
  sink.close()
  doAssert not convertFile(path, r13 / "scalar.sg2", ConvertOptions(target: skSeg2)).isFatal
  var s = openSeismic(r13 / "scalar.sg2")
  doAssert s.seg2Trace(0).value("DELAY").get == "0.1505", s.seg2Trace(0).value("DELAY").get
  doAssert s.seg2Trace(0).value("STATIC_CORRECTIONS").get == "0.0025 -0.0005 0"
  s.close()

block r13_r1_3_one_century_pivot:
  doAssert fullYear(0) == 2000 and fullYear(49) == 2049 and fullYear(50) == 1950
  doAssert fullYear(99) == 1999 and fullYear(1988) == 1988
  # SEG-D -> SEG-2 dates were put in 2000-2099 (63.sgd: a 19xx date).
  var d = openSeismic(exampleDir / "63.sgd", keys = true)
  let expected = d.traceKeys(0).time
  d.close()
  var f = openSeismic(seg2, keys = true)
  doAssert f.traceKeys(0).time == expected, $f.traceKeys(0).time & " " & $expected
  doAssert fromUnix(int64(expected)).utc.year < 2050
  f.close()

block r13_r1_4_no_record_written_is_fatal:
  # SEG-2 -> SEG-D Rev 2.1 at 200 us (no Rev 2 base scan interval): the only
  # record was skipped and an empty output reported as success.
  let path = r13 / "dt200.sg2"
  var fdb = initSeg2File()
  fdb.traceCount = 2
  var w = openSeg2Writer(path, fdb)
  for i in 0..1:
    var t = Seg2Trace(formatCode: 4)
    t["SAMPLE_INTERVAL"] = "0.0002"
    w.writeTrace(t, [1.0, 2.0, 3.0, 4.0, 5, 6, 7, 8])
  w.close()
  let dst = r13 / "dt200.sgd"
  let log = convertFile(path, dst, ConvertOptions(target: skSegd,
    segd: SegdConvertOptions(revision: SegdRevision(major: 2, minor: 1))))
  doAssert log.isFatal and log.has("nothing was converted", sevFatal), $log
  doAssert not fileExists(dst) and tmpFiles(r13).len == 0

echo "tseg2: ok"
