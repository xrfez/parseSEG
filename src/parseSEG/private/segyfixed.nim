## The index of a fixed-length SEG-Y file without the walk (15.3-10, perf
## audit item 6). When the binary header says every trace has the same
## length (Rev 1 or later, bytes 3503-3504 = 1), the walk finds every trace
## at `firstTraceOffset + i * stride` with the binary header's sample count,
## whatever the trace headers say. So the entries follow from the file size,
## and only a sample of the headers is read to confirm they agree.
##
## It applies only where the walk would find nothing else: a known format, no
## Rev 2 additional headers (Ext1 can change a trace's count and flag the last
## trace) or trailer records, a Rev 2 trace count of 0 or the computed one,
## and a file that ends exactly after the last trace (else the walk reports
## the short trace or the extra data).

import std/options
import ../common/endians
import ../io/memsource
import ../segy/reader
import ../model/indextypes
import ./pagehints

const SampledHeaders* = 64
  ## Trace headers `fixedEntries` reads at most: the first, the last and the
  ## rest spread evenly between.

func traceStride(f: SegyFile): int64 {.inline.} =
  int64(TraceHeaderSize) + int64(f.binary.effectiveSamplesPerTrace) * sampleSize(f.format.get)

func fixedTraceCount(f: SegyFile, size: int64): int =
  # The trace count when `f` qualifies (see above), else -1.
  template b: untyped = f.binary
  let rev2 = f.revision.major >= 2
  if f.revision.major < 1 or b.fixedLengthTraces != 1 or f.format.isNone or
      (rev2 and (b.maxAddlTraceHeaders > 0 or b.numTrailerRecords != 0)):
    return -1
  let bytes = size - f.firstTraceOffset
  let stride = f.traceStride
  if bytes <= 0 or bytes mod stride != 0: return -1
  let n = bytes div stride
  if rev2 and b.numTraces != 0 and b.numTraces != uint64(n): -1 else: int(n)

proc fixedEntries*(r: SegyReader, src: MemFileSource, entries: var seq[TraceEntry]): int =
  ## Fills `entries` as the walk would for a fixed-length file, from its
  ## size, after checking that the sample count and interval of the sampled
  ## trace headers equal the binary header's. Returns the number of headers
  ## checked; 0, with `entries` unchanged, when the file does not qualify or
  ## a header disagrees (walk it then). `r` is a reader just past the file
  ## headers of `src`.
  template f: untyped = r.file
  if r.isDone: return 0
  let n = fixedTraceCount(f, src.size)
  if n <= 0: return 0
  let mem = src.memory
  let stride = f.traceStride
  let ns = f.binary.effectiveSamplesPerTrace
  let dt = f.binary.effectiveSampleInterval
  let m = min(n, SampledHeaders)
  template headerOf(k: int): int64 =
    f.firstTraceOffset + (if m == 1: 0'i64 else: int64(k) * int64(n - 1) div int64(m - 1)) * stride
  if not isResident(mem, src.size, headerOf(m - 1)):
    # Cold: queue the sampled pages' reads at once, not one fault at a time.
    for k in 0..<m: adviseWillNeed(mem, src.size, headerOf(k), headerOf(k) + TraceHeaderSize)
  for k in 0..<m:
    let at = int(headerOf(k))
    template h: untyped = mem.toOpenArray(at, at + TraceHeaderSize - 1)
    if uint32(getNum[uint16](h, 114, f.byteOrder)) != ns or
        float64(getNum[uint16](h, 116, f.byteOrder)) != dt:
      return 0
  entries = newSeqUninit[TraceEntry](n)
  for i in 0..<n:
    entries[i] = TraceEntry(offset: f.firstTraceOffset + int64(i) * stride,
      headerBytes: TraceHeaderSize, numSamples: ns, channelSet: NoChannelSet, scanType: -1)
  m
