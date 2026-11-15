## Range decode from a mapped file's raw bytes: one trace's samples (or a
## window of them) straight into a row of the destination, and the
## read-ahead advice for a selection of traces. Raw pointers in, no
## `SeismicFile`: the readers, the prefetch workers and the converters call
## it. `tryDecodeEntry` and `adviseTraces` make no managed objects and raise
## nothing, so worker threads may call them. For an unmapped file, the bytes
## a decode reads (`readSpan`) are held first, many traces in one request
## (`holdSpan`).

import ../common/[diagcodes, endians, errors, seismickind]
import ../segy/samples as segysamples, ../segd/samples as segdsamples,
  ../seg2/samples as seg2samples
import ../model/indextypes
import ./[mapguard, pagehints, readcache]

proc decodeRun[T: SampleType](c: TraceCodec, src: openArray[byte], dst: var openArray[T]) =
  # `dst.len` samples of codec `c` from the start of `src` (a known format).
  case c.kind
  # The unchecked forms: `tryDecodeEntry` checked the bytes and the order.
  of skSegy: decodeSamplesRaw(c.segyFormat.get, src, dst, c.order)
  of skSegd: decodeSamplesRaw(c.segdFormat.get, src, dst, c.twosComplement8015)
  of skSeg2: decodeSamplesRaw(c.seg2Format.get, src, dst, c.order, c.twosComplement8015)
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
    dsCut
      ## The file was cut short while mapped, before the trace's samples
      ## ended (`pastCut`; not returned by `tryDecodeEntry`: the readers
      ## check what they decoded once per call or chunk).
    dsReadFailed
      ## As `dsCut`, but the map stopped there because a read failed (an
      ## I/O error, `guardReadFailed`), not because the file is shorter.
    dsNotRead
      ## Unmapped: the read of the trace's bytes failed (an I/O error); a
      ## later read tries again.

const decodeMessages*: array[DecodeStatus, string] = ["",
  "the sample format is not decodable", "trace samples lie past the end of the file",
  "the file was cut short while it was open: trace samples lie past its new end",
  "a read of the file failed while it was open (an I/O error: a network share or disk " &
    "that failed): trace samples lie past what could be read",
  "the trace's samples could not be read (an I/O error: a network share or disk that " &
    "failed); read them again"]
  ## The diagnostic text of each failure.

func diagCodeOf*(st: DecodeStatus): DiagCode =
  ## The diagnostic code of a failed decode.
  case st
  of dsTruncated, dsCut: dcTruncated
  of dsReadFailed, dsNotRead: dcIo
  else: dcUnsupportedFormat

func cutStatus*(guard: MapGuard): DecodeStatus {.inline.} =
  ## How the traces past `guard`'s cut fail: `dsCut`, or `dsReadFailed`.
  if guard.guardReadFailed: dsReadFailed else: dsCut

func undecodable*(e: TraceEntry, c: TraceCodec, size: int64): bool {.inline.} =
  ## `tryDecodeEntry` fails for trace `e` whatever the bytes: its format is
  ## not decodable, or its samples lie past `size`. The readers' check for a
  ## cut tells the rows that failed from those that read zeros with it.
  not c.known or
    (c.kind == skSegy and c.order == boPairSwapped and c.segyFormat.get in {sfInt24, sfUInt24}) or
    e.sampleOffset < 0 or e.sampleOffset + c.dataBytes(int(e.numSamples)) > size

proc tryDecodeEntry*[T: SampleType](mem: ptr UncheckedArray[byte], size: int64, e: TraceEntry,
    c: TraceCodec, dst: ptr UncheckedArray[T], cols: int, first = 0): DecodeStatus {.
    raises: [].} =
  ## Decodes samples `first ..< first + cols` of trace `e` from
  ## the mapped bytes `mem[0 ..< size]` into `dst[0 ..< cols]`, zero past the
  ## trace's end. Only the window's bytes are read; a window of SEG-D 8015 or
  ## SEG-2 format 3 (4 samples in 10 bytes) that starts inside a group decodes
  ## that whole group first. Reports an undecodable format or a trace past
  ## `size` (the whole trace is checked, whatever the window) as a status and
  ## leaves `dst` untouched then. A file cut short while mapped is not seen
  ## here (the OS gives zeros past the cut): the caller checks the traces it
  ## decoded against the map's cut afterwards (`pastCut`, `guardCut`), once
  ## per read, which costs nothing per trace. Makes no managed objects, not
  ## even exceptions, so a worker thread may call it: an exception destroyed
  ## on a thread makes ORC allocate that thread's cycle buffer, which is
  ## never freed (15.1).
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

func pastCut*(e: TraceEntry, c: TraceCodec, cut: int64): bool {.inline.} =
  ## Trace `e`'s samples reach past `cut` (`guardCut`): a read of them made
  ## before the cut was known gave zeros for the bytes past it. The readers
  ## check the traces they decoded again when a read finds a cut, since the
  ## OS gives zeros, not a fault, for the rest of the page holding it.
  e.sampleOffset + int64(c.dataBytes(int(e.numSamples))) > cut

const
  AdviseMinTraces = 32       ## Smaller selections are advised only when they are large in bytes,
  AdviseMinBytes = 1'i64 shl 20 ## at least this many.
  AdviseGap = 64'i64 shl 10  ## Windows closer than this share one advice call.

# ------------------------------------------------- unmapped: held spans --

func readSpan*(e: TraceEntry, c: TraceCodec, cols, first: int): (int64, int64) {.inline.} =
  ## The bytes `a ..< b` that `tryDecodeEntry(..., cols, first)` reads of
  ## trace `e` (`a == b`: none): the window's, from the start of its first
  ## 4-sample group for SEG-D 8015 and SEG-2 format 3.
  let n = clamp(int(e.numSamples) - first, 0, cols)
  if n <= 0 or not c.known: return (0'i64, 0'i64)
  let start = e.sampleOffset
  let stop = start + int64(c.dataBytes(int(e.numSamples)))
  if c.packedInFours:
    let g = start + int64(first div 4 * 10)
    (g, min(stop, g + int64((first mod 4 + n + 3) div 4 * 10)))
  else:
    let a = start + int64(c.dataBytes(first))
    (a, min(stop, a + int64(c.dataBytes(n))))

const
  SpanGap = 64'i64 shl 10   ## Bytes between two traces' windows read through, not skipped.
  SpanBytes = 8'i64 shl 20  ## A span's limit: one request at most this large.

type SpanHold* = object
  ## The sample bytes held for a run of traces (`holdSpan`).
  h: Hold
  lo*, hi*: int64 ## Bytes held: `lo ..< hi`.
  failed*: bool   ## The hold failed: a trace's bytes are held only if `holds` says so.

proc holdSpan*(c: ptr ReadCache, sp: var SpanHold, entries: ptr UncheckedArray[TraceEntry],
    codecs: ptr UncheckedArray[TraceCodec], sel: ptr UncheckedArray[int], pos, hi, cols,
    first: int) {.raises: [].} =
  ## Holds in `sp` the windows (`readSpan`) of positions `pos ..< hi`
  ## (trace indices, or indices into `sel` when it is not nil) from `pos` on,
  ## as far as each lies within 64 KiB of the span so far, before or after
  ## it, and the span fits 8 MiB: one request for a run of neighbouring
  ## traces, in either order. What `sp` held before is released. Makes no
  ## managed objects and raises nothing.
  template entry(p: int): TraceEntry = entries[if sel == nil: p else: sel[p]]
  var (a, b) = (0'i64, 0'i64)
  var p = pos
  while p < hi:
    let e = entry(p)
    let (x, y) = readSpan(e, codecs[e.record], cols, first)
    if y > x:
      if b <= a:
        (a, b) = (x, y)
      elif x > b + SpanGap or y + SpanGap < a or max(b, y) - min(a, x) > SpanBytes:
        break # far from the span (either way), or the span would be too large
      else:
        (a, b) = (min(a, x), max(b, y)) # a selection newest first grows it down
    inc p
  sp.lo = a
  sp.hi = b
  sp.failed = b > a and c.hold(a, b, sp.h) == rsFailed

proc adviseSpans*(c: ptr ReadCache, entries: ptr UncheckedArray[TraceEntry],
    codecs: ptr UncheckedArray[TraceCodec], sel: ptr UncheckedArray[int], lo, hi, cols: int,
    first = 0) {.raises: [].} =
  ## Unmapped: before reading the windows of positions `lo ..< hi` (as
  ## `holdSpan` takes them), asks the OS to read them all now (`adviseRange`),
  ## so that scattered windows (a gather, the next chunks of a prefetcher)
  ## are fetched together, not one round trip at a time. Small reads are not
  ## advised (as `adviseTraces`). Raises nothing, makes no managed objects.
  let count = hi - lo
  if count <= 0 or cols <= 0: return
  template entry(p: int): TraceEntry = entries[if sel == nil: p else: sel[p]]
  if count < AdviseMinTraces:
    var bytes = 0'i64
    for p in lo ..< hi:
      let e = entry(p)
      let (x, y) = readSpan(e, codecs[e.record], cols, first)
      bytes += y - x
    if bytes < AdviseMinBytes: return
  var a, b = -1'i64
  for p in lo ..< hi:
    let e = entry(p)
    let (x, y) = readSpan(e, codecs[e.record], cols, first)
    if y <= x: continue
    if b >= 0 and x >= a and x <= b + AdviseGap:
      b = max(b, y)
    else:
      if b > a: c.adviseRange(a, b)
      (a, b) = (x, y)
  if b > a: c.adviseRange(a, b)

proc drop*(sp: var SpanHold) {.raises: [].} =
  ## Releases the span.
  sp.h.drop()
  sp.lo = 0
  sp.hi = 0
  sp.failed = false

proc decodeEntry*[T: SampleType](mem: ptr UncheckedArray[byte], size: int64, guard: MapGuard,
    e: TraceEntry, c: TraceCodec, dst: ptr UncheckedArray[T], cols: int, first = 0,
    cache: ptr ReadCache = nil) =
  ## `tryDecodeEntry` that raises `SegFormatError` for an
  ## undecodable format and `SegTruncatedError` for a trace past `size` or,
  ## after the decode, past the cut of `guard` (the map's registration: the
  ## file was cut short while mapped), and `IOError` when an unmapped file's
  ## bytes (`cache`) could not be read. For the caller's thread
  ## (conversions); worker threads use `tryDecodeEntry`.
  # A cut known before: not read (without the guard a read past it faults).
  let known = guard.guardCut
  var h: Hold
  var st = if known < size and not undecodable(e, c, size) and pastCut(e, c, known):
      guard.cutStatus
    else: dsOk
  if st == dsOk and cache != nil:
    let (x, y) = readSpan(e, c, cols, first)
    if y > x and cache.hold(x, y, h) == rsFailed and not cache.holds(x, y): st = dsNotRead
  if st == dsOk: st = tryDecodeEntry(mem, size, e, c, dst, cols, first)
  if st == dsOk and pastCut(e, c, guard.guardCut): st = guard.cutStatus
  case st
  of dsOk: discard
  of dsUndecodable: raiseFormat(decodeMessages[st], e.offset)
  of dsTruncated, dsCut, dsReadFailed: raiseTruncated(decodeMessages[st], e.sampleOffset)
  of dsNotRead: raise newException(IOError, decodeMessages[st])

proc adviseTraces*(mem: ptr UncheckedArray[byte], size: int64,
    entries: ptr UncheckedArray[TraceEntry], codecs: ptr UncheckedArray[TraceCodec],
    sel: ptr UncheckedArray[int], lo, hi, cols: int, first = 0) {.raises: [].} =
  ## Before decoding positions `lo ..< hi` (trace indices, or
  ## indices into `sel` when it is not nil), samples `first ..< first + cols`
  ## each: asks the OS to read their pages ahead (`adviseWillNeed`), so a
  ## cold scattered read waits for the disk once instead of once per trace.
  ## Skipped for small reads, when the traces probed are in memory (the
  ## last trace of a range, the first and last of a selection: one or two
  ## `mincore` calls, ~0.7 µs each, on a warm read), and for a range
  ## (`sel` nil) that continues a sequential read: the byte before trace
  ## `lo` is in memory, so the kernel's readahead is already streaming.
  ## Windows of traces that follow each other closely are advised as one
  ## span. Makes no managed objects and raises nothing: the prefetch worker
  ## calls it.
  let count = hi - lo
  if count <= 0 or cols <= 0 or mem == nil: return
  template entry(pos: int): TraceEntry =
    entries[if sel == nil: pos else: sel[pos]]
  template window(e: TraceEntry, a, b: var int64) =
    let c = codecs[e.record]
    let ns = int(e.numSamples)
    # `min(ns, first + cols)` without the sum, which overflows for a window
    # that ends at `high(int)`.
    let n = if first >= ns or cols >= ns - first: ns else: first + cols
    a = e.sampleOffset + int64(c.dataBytes(min(first, n)))
    b = e.sampleOffset + int64(c.dataBytes(n))
  var a, b: int64
  if count < AdviseMinTraces:
    var bytes = 0'i64
    for pos in lo..<hi:
      window(entry(pos), a, b)
      bytes += b - a
    if bytes < AdviseMinBytes: return
  # A range is probed at its last trace only (a jump or a forward scroll
  # leaves its end out of memory; each probe costs a syscall, ~0.7 µs), a
  # selection at both ends.
  var resident = true
  for pos in [hi - 1, lo]:
    if resident and (pos == hi - 1 or sel != nil):
      window(entry(pos), a, b)
      if b > a and not isResident(mem, size, a): resident = false
  if resident: return
  # A range whose preceding bytes are in memory continues a sequential read:
  # the kernel's own readahead keeps that stream going, and advice per chunk
  # stalls it (cold 64-trace chunks read at half the disk's speed).
  if sel == nil and lo > 0 and isResident(mem, size, entries[lo].offset - 1): return
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
