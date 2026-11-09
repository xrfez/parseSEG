## Range decode from a mapped file's raw bytes: one trace's samples (or a
## window of them) straight into a row of the destination, and the
## read-ahead advice for a selection of traces. Raw pointers in, no
## `SeismicFile`: the readers, the prefetch workers and the converters call
## it. `tryDecodeEntry` and `adviseTraces` make no managed objects and raise
## nothing, so worker threads may call them.

import ../common/[endians, errors, seismickind]
import ../segy/samples as segysamples, ../segd/samples as segdsamples,
  ../seg2/samples as seg2samples
import ../model/indextypes
import ./pagehints

proc decodeRun[T: SampleType](c: TraceCodec, src: openArray[byte], dst: var openArray[T]) =
  # `dst.len` samples of codec `c` from the start of `src` (a known format).
  case c.kind
  # The unchecked forms: `tryDecodeEntry` checked the bytes and the order.
  of skSegy: decodeSamplesRaw(c.segyFormat.get, src, dst, c.order)
  of skSegd: decodeSegdSamplesRaw(c.segdFormat.get, src, dst, c.twosComplement8015)
  of skSeg2: decodeSeg2SamplesRaw(c.seg2Format.get, src, dst, c.order, c.twosComplement8015)
  of skUnknown: discard

func packedInFours(c: TraceCodec): bool {.inline.} =
  # 4 samples in 10 bytes (SEG-D 8015, SEG-2 format 3): a window must start
  # on a group.
  (c.kind == skSegd and c.segdFormat.get == sd8015) or
    (c.kind == skSeg2 and c.seg2Format.get == s2Float20)

type
  DecodeStatus* = enum
    ## The outcome of `tryDecodeEntry`.
    dsOk          ## Decoded.
    dsUndecodable ## The sample format is not decodable.
    dsTruncated   ## The trace's samples lie past the end of the map.

const decodeMessages*: array[DecodeStatus, string] = ["",
  "the sample format is not decodable", "trace samples lie past the end of the file"]
  ## The diagnostic text of each failure.

proc tryDecodeEntry*[T: SampleType](mem: ptr UncheckedArray[byte], size: int64, e: TraceEntry,
    c: TraceCodec, dst: ptr UncheckedArray[T], cols: int, first = 0): DecodeStatus {.
    raises: [].} =
  ## Decodes samples `first ..< first + cols` of trace `e` from
  ## the mapped bytes `mem[0 ..< size]` into `dst[0 ..< cols]`, zero past the
  ## trace's end. Only the window's bytes are read; a window of SEG-D 8015 or
  ## SEG-2 format 3 (4 samples in 10 bytes) that starts inside a group decodes
  ## that whole group first. Reports an undecodable format or a trace past
  ## `size` (the whole trace is checked, whatever the window) as a status and
  ## leaves `dst` untouched then. Makes no managed objects, not even
  ## exceptions, so a worker thread may call it: an exception destroyed on a
  ## thread makes ORC allocate that thread's cycle buffer, which is never
  ## freed (15.1).
  let n = clamp(int(e.numSamples) - first, 0, cols)
  if not c.known: return dsUndecodable
  if c.kind == skSegy and c.order == boPairSwapped and c.segyFormat.get in {sfInt24, sfUInt24}:
    return dsUndecodable # pair-swapped order is undefined for 3-byte samples
  let nbytes = c.dataBytes(int(e.numSamples))
  let start = e.sampleOffset
  if start < 0 or start + nbytes > size: return dsTruncated
  if n > 0:
    let a = int(start)
    let last = a + nbytes - 1
    if first == 0:
      c.decodeRun(mem.toOpenArray(a, last), dst.toOpenArray(0, n - 1))
    elif not c.packedInFours:
      let skip = c.dataBytes(first)
      c.decodeRun(mem.toOpenArray(a + skip, last), dst.toOpenArray(0, n - 1))
    else:
      # The group holding `first`, then whole groups straight into `dst`.
      let g = a + first div 4 * 10
      let lead = first mod 4
      var head = 0
      if lead > 0:
        var grp: array[4, T]
        head = min(4 - lead, n)
        c.decodeRun(mem.toOpenArray(g, last), grp.toOpenArray(0, lead + head - 1))
        for k in 0..<head: dst[k] = grp[lead + k]
      if head < n:
        let b = if lead > 0: g + 10 else: g
        c.decodeRun(mem.toOpenArray(b, last), dst.toOpenArray(head, n - 1))
  for k in n..<cols: dst[k] = T(0)
  dsOk

proc decodeEntry*[T: SampleType](mem: ptr UncheckedArray[byte], size: int64, e: TraceEntry,
    c: TraceCodec, dst: ptr UncheckedArray[T], cols: int, first = 0) =
  ## `tryDecodeEntry` that raises `SegFormatError` for an
  ## undecodable format and `SegTruncatedError` for a trace past `size`. For
  ## the caller's thread (conversions); worker threads use `tryDecodeEntry`.
  case tryDecodeEntry(mem, size, e, c, dst, cols, first)
  of dsOk: discard
  of dsUndecodable: raiseFormat(decodeMessages[dsUndecodable], e.offset)
  of dsTruncated: raiseTruncated(decodeMessages[dsTruncated], e.sampleOffset)

const
  AdviseMinTraces = 32       ## Smaller selections are advised only when they are large in bytes,
  AdviseMinBytes = 1'i64 shl 20 ## at least this many.
  AdviseGap = 64'i64 shl 10  ## Windows closer than this share one advice call.

proc adviseTraces*(mem: ptr UncheckedArray[byte], size: int64,
    entries: ptr UncheckedArray[TraceEntry], codecs: ptr UncheckedArray[TraceCodec],
    sel: ptr UncheckedArray[int], lo, hi, cols: int, first = 0) {.raises: [].} =
  ## Before decoding positions `lo ..< hi` (trace indices, or
  ## indices into `sel` when it is not nil), samples `first ..< first + cols`
  ## each: asks the OS to read their pages ahead (`adviseWillNeed`), so a
  ## cold scattered read waits for the disk once instead of once per trace.
  ## Skipped for small reads and when the first and last traces are
  ## in memory (a warm read pays two `mincore` calls, ~1.5 µs). Windows of traces
  ## that follow each other closely are advised as one span. Makes no
  ## managed objects and raises nothing: the prefetch worker calls it.
  let count = hi - lo
  if count <= 0 or cols <= 0 or mem == nil: return
  template entry(pos: int): TraceEntry =
    entries[if sel == nil: pos else: sel[pos]]
  template window(e: TraceEntry, a, b: var int64) =
    let c = codecs[e.record]
    let n = min(int(e.numSamples), first + cols)
    a = e.sampleOffset + int64(c.dataBytes(min(first, n)))
    b = e.sampleOffset + int64(c.dataBytes(n))
  var a, b: int64
  if count < AdviseMinTraces:
    var bytes = 0'i64
    for pos in lo..<hi:
      window(entry(pos), a, b)
      bytes += b - a
    if bytes < AdviseMinBytes: return
  var resident = true
  for pos in [lo, hi - 1]:
    window(entry(pos), a, b)
    if b > a and not isResident(mem, size, a):
      resident = false
      break
  if resident: return
  var spanA, spanB = -1'i64
  for pos in lo..<hi:
    window(entry(pos), a, b)
    if b <= a: continue
    if spanB >= 0 and a >= spanA and a <= spanB + AdviseGap:
      spanB = max(spanB, b)
    else:
      if spanB > spanA: adviseWillNeed(mem, size, spanA, spanB)
      spanA = a
      spanB = b
  if spanB > spanA: adviseWillNeed(mem, size, spanA, spanB)
