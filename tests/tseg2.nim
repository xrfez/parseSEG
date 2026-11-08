## SEG-2 reader, trace index, keys and `openSeismic` detection (task 11.1).
## No SEG-2 sample file exists, so every file here is built by the test.

import std/[assertions, os, math, strutils, options]
import parseSEG/common/errors
import parseSEG/io/[diskio, memsource]
import parseSEG/seg2/[reader as seg2reader]
import parseSEG/model/[traceindex, gathers, headerfields, headernif, prefetch]
import parseSEG/convert

let tmp = getTempDir() / "parseseg_tseg2"
createDir(tmp)

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

block format_specific_features_say_so:
  let path = build(allFormats(boLittle)).save("features.sg2")
  var f = openSeismic(path)
  try:
    discard f.traceField(0, "trace.sampleInterval")
    doAssert false
  except ValueError as e:
    doAssert "SEG-2" in e.msg
  doAssert f.findFileField("binary.formatCode").isNone
  doAssert f.blockKind(hsTrace, 0, "trace").isNone
  doAssertRaises(ValueError): f.exportHeaders(tmp / "features.nif")
  f.close()
  let log = convertFile(path, tmp / "features.sgy")
  doAssert log.isFatal and "SEG-2" in log[0].msg
  doAssert not fileExists(tmp / "features.sgy")
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

echo "tseg2: ok"
