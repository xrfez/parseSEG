## Trace index, memory-mapped range reads (task 6.1) and the headers-only
## reads (task 6.5), on the sample files, tape images and damaged input.

import std/[assertions, os, strutils]
import parseSEG/common/errors
import parseSEG/io/[records, diskio, tapeimage, tapedevice, memsource, pushback]
import parseSEG/segy/[reader as segyreader, writer as segywriter]
import parseSEG/segd/[reader as segdreader, writer as segdwriter]
import parseSEG/model/traceindex
import ./utils/testutils

let tmp = scratchDir("parseseg_ttraceindex")

const
  segdFiles = ["63.sgd", "inova_rev30_5traces.sgd"]
  segyFiles = ["Sweep0.sgy", "BO_3D-Inglewood_rev21_v7.sgy"]

proc segdToTape(d: SegdData, path: string) =
  let sink = openTapeImageSink(path)
  try: doAssert writeSegd(sink, d).len == 0
  finally: sink.close()

proc segyToTape(d: SegyData, path: string) =
  let sink = openTapeImageSink(path)
  var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()

proc indexOf(src: RecordSource, kind: SeismicKind): TraceIndex =
  try: result = buildIndex(src, kind)
  finally: src.close()

sampleBlock detect_kind:
  for n in segdFiles:
    doAssert detectKind(readBytes(exampleDir / n)) == skSegd, n
  for n in segyFiles:
    doAssert detectKind(readBytes(exampleDir / n)) == skSegy, n
  # zeros: GH1 format code 0000 is not a format
  doAssert detectKind(newSeq[byte](4000)) == skUnknown
  # A SEG-D GH1 whose BCD file number starts with 43 ('C' in ASCII) stays SEG-D:
  # its binary-header bytes hold no SEG-Y format code.
  var b = readBytes(exampleDir / "63.sgd")
  b[0] = 0x43
  doAssert detectKind(b) == skSegd

sampleBlock index_matches_full_read_segd:
  for n in segdFiles:
    var f = openSeismic(exampleDir / n)
    let full = readSegd(exampleDir / n)
    doAssert f.kind == skSegd and f.index.contiguous
    doAssert f.log.len == full.log.len
    var k = 0
    for rd in full.records:
      for i, t in rd.traces:
        let e = f.index.entries[k]
        doAssert e.offset == t.offset and int(e.numSamples) == t.numSamples
        doAssert e.channelSetIndex == t.channelSet and int(e.scanType) == t.scanType
        doAssert e.sampleOffset + f.index.dataBytes(k) <= f.mappedSize
        inc k
    doAssert k == f.len
    let all = f.readTraces(0..<f.len)
    var row = 0
    for rd in full.records:
      for i in 0..<rd.traces.len:
        for j in 0..<rd.traces[i].numSamples: doAssert all[row, j] == rd.samples[i, j]
        inc row
    f.close()

sampleBlock index_matches_full_read_segy:
  for n in segyFiles:
    var f = openSeismic(exampleDir / n)
    let full = readSegy(exampleDir / n)
    doAssert f.kind == skSegy and f.len == full.traces.len
    for i, t in full.traces:
      doAssert f.index.entries[i].offset == t.offset
    doAssert f.readTraces(0..<f.len) == full.samples
    # Narrower and wider tensors, at a row offset.
    var narrow = newTraceTensor[float32](5, 10)
    doAssert f.readTracesInto(0..0, narrow, row = 3) == 0
    for j in 0..<10: doAssert narrow[3, j] == full.samples[0, j] and narrow[0, j] == 0
    var wide = newTraceTensor[float64](1, f.index.maxSamples + 7)
    for j in 0..<wide.shape[1]: wide[0, j] = 99.0
    doAssert f.readTracesInto(f.len - 1 .. f.len - 1, wide) == 0
    doAssert wide[0, f.index.maxSamples + 6] == 0.0
    doAssert float32(wide[0, 0]) == full.samples[f.len - 1, 0]
    f.close()

sampleBlock index_on_every_source_kind:
  # Disk (seek), memory map, and a tape image (read and discard) agree.
  for n in segdFiles:
    let d = readSegd(exampleDir / n)
    segdToTape(d, tmp / "x.tap")
    let a = indexOf(openDiskSource(exampleDir / n), skSegd)
    let b = indexOf(openMemFileSource(exampleDir / n), skSegd)
    let c = indexOf(openTapeImageSource(tmp / "x.tap"), skSegd)
    doAssert a.entries == b.entries and a.contiguous and b.contiguous and not c.contiguous
    doAssert c.len == a.len and c.log.len == a.log.len
    for i in 0..<a.len: doAssert a.entries[i].numSamples == c.entries[i].numSamples
  for n in segyFiles:
    let d = readSegy(exampleDir / n)
    segyToTape(d, tmp / "y.tap")
    let a = indexOf(openDiskSource(exampleDir / n), skSegy)
    let c = indexOf(openTapeImageSource(tmp / "y.tap"), skSegy)
    doAssert c.len == a.len and c.segy.binary == a.segy.binary

sampleBlock headers_only_reads:
  for n in segdFiles:
    let full = readSegd(exampleDir / n)
    for h in [readSegdHeaders(exampleDir / n), (block:
        segdToTape(full, tmp / "h.tap")
        var src: RecordSource = openTapeImageSource(tmp / "h.tap")
        try: readSegd(src, headersOnly = true) finally: src.close())]:
      doAssert h.records.len == full.records.len and h.log.len == full.log.len
      for r in 0..<full.records.len:
        doAssert h.records[r].traces.len == full.records[r].traces.len
        doAssert h.records[r].samples.shape[1] == 0
        template a: untyped = h.records[r].record
        template b: untyped = full.records[r].record
        doAssert a.layout == b.layout
        if a.isRev3: doAssert a.trailerRev3 == b.trailerRev3
        else: doAssert a.trailer == b.trailer
        for i, t in full.records[r].traces:
          let u = h.records[r].traces[i]
          doAssert u.samples.len == 0 and u.numSamples == t.numSamples
          doAssert u.header == t.header and u.extensions == t.extensions
      # Decoding a header-only trace is refused rather than read as zeros.
      var x = newTraceTensor[float32](1, 10)
      doAssertRaises(SegFormatError):
        h.records[0].record.decodeInto(h.records[0].traces[0], x, 0)
  for n in segyFiles:
    let full = readSegy(exampleDir / n)
    let h = readSegyHeaders(exampleDir / n)
    doAssert h.traces.len == full.traces.len and h.log.len == full.log.len
    for i, t in full.traces:
      doAssert h.traces[i].header == t.header and h.traces[i].samples.len == 0
    var x = newTraceTensor[float32](1, 10)
    doAssertRaises(SegFormatError): h.file.decodeInto(h.traces[0], x, 0)

sampleBlock truncated_last_trace:
  # Headers-only walks must notice samples cut short, like full reads.
  for (n, kind) in [("BO_3D-Inglewood_rev21_v7.sgy", skSegy), ("inova_rev30_5traces.sgd", skSegd)]:
    let b = readBytes(exampleDir / n)
    let full = openSeismic(exampleDir / n)
    let last = full.index.entries[^1]
    writeBytes(tmp / "cut", b[0 ..< int(last.sampleOffset) + 7])
    var f = openSeismic(tmp / "cut")
    doAssert f.len == full.len - 1, n
    doAssert f.log.isFatal, n
    f.close()

sampleBlock range_read_of_damaged_trace_is_logged:
  # An entry pointing past the mapped bytes is logged and left zero.
  var f = openSeismic(exampleDir / "Sweep0.sgy")
  f.index.entries[0].numSamples = 1_000_000
  var t = newTraceTensor[float32](1, 5)
  t[0, 0] = 7
  var log: DiagLog
  doAssert f.readTracesInto(0..0, t, 0, log) == 1
  doAssert t[0, 0] == 0 and log.len == 1 and log.count(sevError) == 1
  f.close()
  f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  f.index.entries[0].numSamples = 1_000_000
  var t2 = newTraceTensor[float32](2, 5)
  doAssert f.readTracesInto(0..1, t2) == 1 # without a log: the count
  # readTraces: with a log, the trace is a zero row and a diagnostic; without
  # one, the failure is an exception naming the trace (never a silent zero).
  var rlog: DiagLog
  let r = f.readTraces([1, 0], rlog)
  doAssert r.shape[0] == 2 and r[1, 0] == 0 and rlog.len == 1 and
    rlog[0].loc.trace == 0 and rlog[0].code == dcTruncated
  try:
    discard f.readTraces(0..1)
    doAssert false
  except SegTruncatedError as e:
    doAssert "trace 0" in e.msg
  doAssert f.readTraces(1..1).shape[0] == 1 # good traces still read
  f.close()

block not_seismic:
  writeBytes(tmp / "junk", newSeq[byte](5000))
  var f = openSeismic(tmp / "junk")
  doAssert f.len == 0 and f.log.isFatal
  f.close()
  writeBytes(tmp / "empty", [])
  var g = openSeismic(tmp / "empty")
  doAssert g.len == 0 and g.log.isFatal
  g.close()

sampleBlock memfile_source_basics:
  let src = openMemFileSource(exampleDir / "63.sgd", chunk = 100)
  var buf: seq[byte]
  doAssert src.readRecord(buf) == rkData and buf.len == 100
  doAssert src.seekForward(1_000_000) == src.size - 100
  doAssert src.readRecord(buf) == rkEndOfData
  src.close()
  # Skipping through a cursor stops at a tape mark on record media.
  let tape = newMemoryTape(@[dataBlock(newSeq[byte](10)), tapeMark(), dataBlock(newSeq[byte](5))])
  var c = initRecordCursor(newDeviceSource(tape))
  doAssert c.skip(100) == 10 and c.stoppedAt == rkTapeMark
  c.skipTapeMark()
  doAssert c.skip(3) == 3 and c.skip(100) == 2

block disk_source_sees_a_growing_file:
  # The size is cached at open, but a file being appended to keeps reading.
  writeBytes(tmp / "grow", [1'u8, 2, 3])
  let src = openDiskSource(tmp / "grow")
  var buf: seq[byte]
  doAssert src.readRecord(buf) == rkData and buf.len == 3
  block:
    var f = open(tmp / "grow", fmAppend)
    f.write("abcd")
    f.close()
  doAssert src.seekForward(1) == 1
  doAssert src.readRecord(buf) == rkData and buf.len == 3 and buf[0] == byte('b')
  doAssert src.readRecord(buf) == rkEndOfData
  src.close()

sampleBlock segy_repeated_trace_warnings_are_capped:
  # A Rev 1 fixed-length file whose 9 trace headers all disagree with the
  # binary header: 5 warnings and one summary, in both read modes.
  let d0 = readSegy(exampleDir / "Sweep0.sgy")
  var d = d0
  d.file.binary.segyMajor = 1
  d.file.binary.fixedLengthTraces = 1
  d.traces.setLen 0
  for k in 0..<9:
    var t = d0.traces[0]
    t.header.numSamples = 7
    d.traces.add t
  let path = tmp / "fixed.sgy"
  let sink = openDiskSink(path)
  var w = openSegyWriter(sink, d.file, initSegyWriteOptions(d.file, lenient = true))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()
  for log in [readSegy(path).log, readSegyHeaders(path).log]:
    var mismatches, summaries = 0
    for e in log.items:
      if e.loc.field == "trace.numSamples":
        if e.severity == sevWarning: inc mismatches
        elif e.severity == sevInfo: inc summaries
    doAssert mismatches == 5 and summaries == 1

type CountingSource = ref object of RecordSource
  inner: RecordSource
  copied, seeked: int64

method readRecordImpl(s: CountingSource; buf: var seq[byte]; maxLen: int): RecordKind {.
    raises: [CatchableError].} =
  result = s.inner.readRecord(buf, maxLen)
  s.copied += buf.len
  s.dataOffset = s.inner.dataOffset
  s.offset = s.inner.offset

method hasRecordBoundaries(s: CountingSource): bool {.raises: [].} = s.inner.hasRecordBoundaries

method seekForward(s: CountingSource; n: int64): int64 {.raises: [CatchableError].} =
  result = s.inner.seekForward(n)
  if result > 0: s.seeked += result
  s.offset = s.inner.offset

sampleBlock headers_only_walk_copies_only_headers:
  # Review finding: refills after a seek fetched whole chunks, so a header
  # walk copied nearly the whole file. Inglewood: 200 traces of 8244 bytes.
  for inner in [RecordSource(openDiskSource(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")),
      openMemFileSource(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")]:
    let c = CountingSource(inner: inner, name: inner.name)
    let ix = buildIndex(c, skSegy)
    doAssert ix.len == 200
    let traceArea = 200 * 8244
    doAssert c.seeked > traceArea * 9 div 10, $c.seeked
    inner.close()

sampleBlock skip_guards:
  let src = openDiskSource("/dev/zero") # a device: no size, reads still work
  var buf: seq[byte]
  doAssert src.readRecord(buf, 4096) == rkData and buf.len == 4096
  doAssert src.seekForward(10) == -1
  src.close()
  var p = initPushbackInput(openMemFileSource(exampleDir / "63.sgd"))
  doAssert p.skip(-5) == 0 and p.offset == 0

sampleBlock empty_ranges_must_start_in_the_file:
  # 12.4: an empty range is valid only when it starts in `0 .. len`.
  var f = openSeismic(exampleDir / "inova_rev30_5traces.sgd")
  doAssert f.len == 5
  doAssert f.readTraces(5..4).shape[0] == 0 and f.readTraces(0 .. -1).shape[0] == 0
  doAssert f.maxSamples(5..4) == 0
  doAssertRaises(ValueError): discard f.readTraces(7..6)
  doAssertRaises(ValueError): discard f.maxSamples(-1 .. -2)
  f.close()

block index_memory_is_reserved_from_the_file_size:
  # Task 13.2 (review R2-8): after the first trace the index reserves room
  # for the rest of the file, so entries and keys cost 24 + 144 bytes per
  # trace, not up to 1.5x that from a growing seq.
  const n = 20_000
  let path = getTempDir() / "parseseg_reserve.sgy"
  var b = newSeq[byte](3600 + n * 244)
  b[0] = 0x43 # 'C', ASCII text
  for i in 1..<3200: b[i] = 0x20
  b[3220] = 0; b[3221] = 1 # 1 sample
  b[3224] = 0; b[3225] = 5 # IEEE float
  b[3502] = 0; b[3503] = 1 # fixed length
  for t in 0..<n:
    let at = 3600 + t * 244
    b[at + 3] = byte(t and 0xFF)
    b[at + 115] = 1 # 1 sample
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(path, s)
  let before = getOccupiedMem()
  var f = openSeismic(path, keys = true)
  let grown = getOccupiedMem() - before
  doAssert f.len == n and f.index.log.count(sevError) == 0
  doAssert sizeof(TraceEntry) == 24 and sizeof(TraceKeys) == 184
  doAssert grown < n * (24 + 184) + n * 12 + 65536, $grown
  f.close()
  removeFile(path)

# Phase 6 review (I/O, index and gathers). Its copy-volume (a2) and
# character-device (a7) findings are `headers_only_walk_copies_only_headers` and
# `skip_guards` above.

sampleBlock p6_a1_channel_set_index_beyond_int16:
  # 32768 dummy descriptors before the real one: the trace's set index is 32768.
  var b = readBytes(exampleDir / "63.sgd")
  b[28] = 0xFF # channel sets per scan type: see GH#2
  b[35] = 0x80 # GH#2 bytes 4-5: 32769
  b[36] = 0x01
  var dummy = newSeq[byte](32)
  dummy[0] = 0x01 # scan type 1
  dummy[1] = 0x99 # channel set 99, 0 channels
  var c = b[0 ..< 96]
  for _ in 0..<32768: c.add dummy
  c.add b[96 .. ^1]
  writeBytes(tmp / "manysets.sgd", c)
  var f = openSeismic(tmp / "manysets.sgd")
  doAssert f.len == 1 and f.index.entries[0].channelSetIndex == 32768
  doAssert f.readTraces(0..0).shape == [1, 1000]
  f.close()

sampleBlock p6_a3_segd_file_number_43xx_with_format_like_bytes:
  var b = readBytes(exampleDir / "63.sgd")
  b[0] = 0x43
  b[1] = 0x21
  b[3224] = 0x00
  b[3225] = 0x05
  doAssert detectKind(b) == skSegd
  writeBytes(tmp / "4321.sgd", b)
  var f = openSeismic(tmp / "4321.sgd")
  doAssert f.kind == skSegd and f.len == 1 and not f.log.isFatal
  f.close()

sampleBlock p6_a4_segy_with_undefined_format_code_is_still_segy:
  var b = readBytes(exampleDir / "Sweep0.sgy")
  b[3224] = 0
  b[3225] = 0
  writeBytes(tmp / "fmt0.sgy", b)
  var f = openSeismic(tmp / "fmt0.sgy")
  doAssert f.kind == skSegy and f.index.detected
  var formatDiag = false
  for e in f.log.items:
    if e.severity == sevFatal and "format code" in e.msg: formatDiag = true
  doAssert formatDiag and f.index.segy.text.data[0] == byte(0x43)
  f.close()

sampleBlock p6_a6_closed_maps_fail_cleanly:
  let s = openMemFileSource(exampleDir / "63.sgd")
  s.close()
  var buf: seq[byte]
  doAssert s.readRecord(buf) == rkEndOfData and s.memory == nil and s.size == 0
  var f = openSeismic(exampleDir / "63.sgd")
  var g: SeismicFile
  doAssert not compiles(g = f) # a copy could outlive `close`
  f.close()
  var t = newTraceTensor[float32](1, 10)
  doAssert f.readTracesInto(0 .. -1, t) == 0 and not f.isOpen
