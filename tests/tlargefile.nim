## Files larger than 4 GB (task 6.7): sparse synthetic SEG-Y and SEG-D files
## whose last traces lie past 2^32, read through the index, range reads,
## prefetch, header-only disk reads and in-place edits near the end.
##
## Skipped where the file system does not keep the files sparse (they would
## take 4.3 GB each), and off POSIX systems.

import std/[assertions, os, strutils]
import parseSEG/common/[diagnostics, endians]
import parseSEG/segy/[reader as segyreader]
import parseSEG/segd/[reader as segdreader]
import parseSEG/model/[traceindex, prefetch, edit]
import ./utils/testutils

const
  FourGiB = 4_294_967_296'i64
  MaxAllocated = 256'i64 shl 20 # more than this means the holes were filled

let tmp = scratchDir("parseseg_tlargefile")

when defined(posix):
  import std/posix

  proc allocatedBytes(path: string): int64 =
    var st: Stat
    doAssert stat(path.cstring, st) == 0
    int64(st.st_blocks) * 512

proc writeSparse(path: string, size: int64, pieces: openArray[(int64, seq[byte])]): bool =
  ## Writes `pieces` at their offsets into a file of `size` bytes, leaving
  ## holes elsewhere. False (and the file removed) if the holes take space.
  var f = open(path, fmWrite)
  for (at, b) in pieces:
    f.setFilePos(at)
    doAssert f.writeBuffer(addr b[0], b.len) == b.len
  f.setFilePos(size - 1)
  f.write('\0')
  f.close()
  doAssert getFileSize(path) == size
  when defined(posix):
    result = allocatedBytes(path) < MaxAllocated
  else:
    result = false
  if not result: removeFile(path)

proc ramp(n: int, scale: float32): seq[float32] =
  result = newSeq[float32](n)
  for i in 0..<n: result[i] = float32(i mod 997) * scale + 1

# ------------------------------------------------------------------ SEG-Y --

const
  YSamples = 60_000
  YTraceBytes = TraceHeaderSize + 4 * YSamples # format 5 (IEEE float32)
  YTraces = 17_900
  YSize = 3600'i64 + int64(YTraces) * YTraceBytes

proc segyTrace(seqNo: int, sx: int32, vals: seq[float32]): seq[byte] =
  result = newSeq[byte](YTraceBytes)
  let h = SegyTraceHeader(traceSeqLine: int32(seqNo), numSamples: YSamples,
    sampleInterval: 1000, sourceX: sx, traceIdCode: 1)
  h.encode(result.toOpenArray(0, TraceHeaderSize - 1), boBig)
  encodeSamples(sfFloat32, vals, result.toOpenArray(TraceHeaderSize, YTraceBytes - 1), boBig)

proc makeSegy(path: string): bool =
  var head = toBytes("C" & repeat(' ', 3199))
  var bin = SegyBinaryHeader(sampleInterval: 1000, samplesPerTrace: YSamples, formatCode: 5,
    segyMajor: 1, fixedLengthTraces: 1)
  var b = newSeq[byte](BinaryHeaderSize)
  bin.encode(b, boBig)
  head.add b
  let lastAt = 3600'i64 + int64(YTraces - 1) * YTraceBytes
  writeSparse(path, YSize, [(0'i64, head), (3600'i64, segyTrace(1, 5, ramp(YSamples, 0.5))),
    (lastAt, segyTrace(YTraces, 4242, ramp(YSamples, -2)))])

block segy_larger_than_4_gib:
  let path = tmp / "big.sgy"
  if not makeSegy(path):
    echo "tlargefile: the file system does not keep sparse files; SEG-Y part skipped"
  else:
    try:
      var f = openSeismic(path)
      doAssert f.kind == skSegy and f.len == YTraces
      doAssert f.log.count(sevError) + f.log.count(sevFatal) == 0
      # The zero headers in the holes disagree with the binary header: five
      # warnings, then one summary (not 17,898 warnings).
      doAssert f.log.count(sevWarning) == 5 and f.log.count(sevInfo) == 1, $f.log.len
      let last = f.index.entries[^1]
      doAssert last.offset == YSize - YTraceBytes and last.offset > FourGiB
      let want = ramp(YSamples, -2)
      let t = f.readTraces(YTraces - 2 ..< YTraces)
      for j in [0, 1, 4567, YSamples - 1]:
        doAssert t[1, j] == want[j] and t[0, j] == 0
      # Read-ahead near the end.
      var p = newPrefetcher[float32](f, YTraces - 3 ..< f.len, chunkTraces = 2, depth = 2)
      var c: PrefetchChunk[float32]
      doAssert p.next(c) and c.first == YTraces - 3 and p.next(c) and c.first == YTraces - 1
      doAssert c.samples[0, YSamples - 1] == want[YSamples - 1] and not p.next(c)
      p.close()
      f.close()
      # Headers through a plain disk source: the skips seek past 4 GB.
      let h = readSegyHeaders(path)
      doAssert h.traces.len == YTraces and h.traces[^1].header.sourceX == 4242
      doAssert h.traces[^1].offset > FourGiB
      # An in-place edit near the end, and its rollback.
      let journal = path & ".edits.nif"
      if fileExists(journal): removeFile(journal)
      var ed = openEditor(path)
      doAssert ed.setTraceField(YTraces - 1, "trace.sourceX", -77)
      let at = ed.file.index.entries[^1].offset
      doAssert decodeTraceHeader(ed.file.copyBytes(at, TraceHeaderSize), boBig).sourceX == -77
      ed.close()
      doAssert ("(edit " & $(at + 72) & " ") in readFile(journal)
      doAssert readSegyHeaders(path).traces[^1].header.sourceX == -77
      doAssert rollbackJournal(path, journal).len == 0
      doAssert readSegyHeaders(path).traces[^1].header.sourceX == 4242
      removeFile(journal)
    finally:
      removeFile(path)

# ------------------------------------------------------------------ SEG-D --

const
  DSamples = 16_000_000 # THE#1 bytes 8-10 hold up to 2^24 - 1
  DTraces = 70
  DHeader = 224         # GH1-GH3, one CSD, 3 extended blocks (as in 63.sgd)
  DTraceHead = 116      # demux header + 3 extensions
  DTraceBytes = DTraceHead + 4 * DSamples
  DSize = int64(DHeader) + int64(DTraces) * DTraceBytes

proc makeSegd(path: string): bool =
  # 63.sgd's headers with the channel count raised to 70 and each trace
  # stretched to 16 M samples (8058); only the headers and the first and
  # last traces' first samples are written.
  let src = toBytes(readFile(exampleDir / "63.sgd"))
  var head = src[0 ..< DHeader]
  head[104] = 0x00 # CSD channel count, BCD
  head[105] = 0x70
  var pieces = @[(0'i64, head)]
  for k in 0..<DTraces:
    var th = src[DHeader ..< DHeader + DTraceHead]
    th[5] = byte(((k + 1) div 10) shl 4 or (k + 1) mod 10) # BCD trace number, byte 6
    th[27] = byte(DSamples shr 16) # THE#1 samples per trace
    th[28] = byte((DSamples shr 8) and 0xFF)
    th[29] = byte(DSamples and 0xFF)
    if k == 0 or k == DTraces - 1:
      var s = newSeq[byte](4000)
      encodeSegdSamples(sd8058, ramp(1000, float32(k + 1)), s)
      th.add s
    pieces.add (int64(DHeader) + int64(k) * DTraceBytes, th)
  writeSparse(path, DSize, pieces)

block segd_larger_than_4_gib:
  let path = tmp / "big.sgd"
  if not makeSegd(path):
    echo "tlargefile: the file system does not keep sparse files; SEG-D part skipped"
  else:
    try:
      var f = openSeismic(path)
      doAssert f.kind == skSegd and f.len == DTraces
      doAssert f.log.count(sevError) + f.log.count(sevFatal) == 0, $f.log.len
      let last = f.index.entries[^1]
      doAssert last.offset == DSize - DTraceBytes and last.offset > FourGiB
      doAssert last.numSamples == DSamples
      var t = newTraceTensor[float32](2, 1000)
      doAssert f.readTracesInto(DTraces - 2 ..< DTraces, t) == 0
      let want = ramp(1000, float32(DTraces))
      for j in [0, 1, 999]: doAssert t[1, j] == want[j] and t[0, j] == 0
      f.close()
      let h = readSegdHeaders(path)
      doAssert h.records.len == 1 and h.records[0].traces.len == DTraces
      doAssert h.records[0].traces[^1].offset > FourGiB
      let journal = path & ".edits.nif"
      if fileExists(journal): removeFile(journal)
      var ed = openEditor(path)
      doAssert ed.setTraceField(DTraces - 1, "ext1.receiverPointNumber", 31337)
      ed.close()
      doAssert readSegdHeaders(path).records[0].traces[^1].ext1.get.receiverPointNumber == 31337
      doAssert rollbackJournal(path, journal).len == 0
      doAssert readSegdHeaders(path).records[0].traces[^1].ext1.get.receiverPointNumber == 104
      removeFile(journal)
    finally:
      removeFile(path)
