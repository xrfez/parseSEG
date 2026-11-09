## The SEG-2 converters' shared state (`convert/toseg2`, `convert/tosegd`):
## information-loss notes, inexact traces, unmapped trace strings, progress.

import std/[math, strutils]
import ../common/[errors, diagnostics]
import ../model/traceindex
import ../version
import ./[decodeentry, progressticker]

type
  Seg2Note* = enum
    # Kinds of information a conversion drops; each is noted once.
    snSegyHeaders, snSegyExtended, snSegyTrailer, snSegyExtensions, snSegdHeaders,
    snSegdGeneral, snSegdTrailer, snSegdExtensions, snTraceSort, snIntervalRounded,
    snDelayRounded, snLocalCoordinates, snReordered, snNoInterval

  Seg2Conv* = object
    log*: DiagLog
    seen*: set[Seg2Note]
    loc*: Location
    inexact*, firstInexact*: int
    unmapped*: seq[string] ## Keywords without a slot, in order of first sight.
    tk*: ProgressTicker ## The writing pass's progress.

const ConverterName* = "parseSEG " & PackageVersion

proc note*(c: var Seg2Conv, kind: Seg2Note, msg: string) =
  if kind notin c.seen:
    c.seen.incl kind
    c.log.report(sevInfo, dcValidation, msg, loc = c.loc)

proc inexactTrace*(c: var Seg2Conv, trace: int) =
  if c.inexact == 0: c.firstInexact = trace
  inc c.inexact

proc reportInexact*(c: var Seg2Conv, what: string) =
  if c.inexact > 0:
    c.log.report(sevWarning, dcValidation, $c.inexact & " traces (the first is trace " &
      $c.firstInexact & ") could not be written exactly in " & what & "; choose a wider format",
      loc = c.loc)

proc unmappedKey*(c: var Seg2Conv, key: string) =
  let k = key.toUpperAscii
  if k notin c.unmapped: c.unmapped.add k

proc reportUnmapped*(c: var Seg2Conv, target: string) =
  if c.unmapped.len > 0:
    c.log.report(sevInfo, dcValidation, "SEG-2 trace strings with no " & target & " slot " &
      "are not carried: " & c.unmapped.join(", "), loc = c.loc)

func finite*(x: float64): bool {.inline.} = not (x.isNaN or x == Inf or x == -Inf)

proc tickTrace*(c: var Seg2Conv, f: SeismicFile, k: int) =
  # Progress after `k` of the file's traces; raises when cancelled.
  if not c.tk.tick(int64(k) * f.mappedSize div max(f.len, 1)): raiseCancelled()

proc closeQuietly*(f: var SeismicFile) {.raises: [].} =
  # Unmaps a read-only input; a failure there loses nothing.
  try: f.close()
  except CatchableError: discard

proc decodeFloat64*(f: SeismicFile, i: int, vals: var seq[float64]) =
  # Trace `i`'s samples as float64; raises like `decodeEntry`.
  let e = f.index.entries[i]
  # Checked before the buffer: no format packs a sample in under a byte.
  if int64(e.numSamples) > f.mappedSize:
    raiseTruncated("trace samples lie past the end of the file", e.offset)
  vals.setLen int(e.numSamples)
  if vals.len > 0:
    decodeEntry(f.unsafeMemory, f.mappedSize, e, f.index.codecs[e.record],
      cast[ptr UncheckedArray[float64]](addr vals[0]), vals.len)

proc reportFailure*(c: var Seg2Conv, e: ref CatchableError) =
  if e of SegCancelledError: c.log.reportCancelled(c.loc.file)
  else: c.log.report(sevFatal, (if e of IOError: dcIo else: dcValidation), e.msg, loc = c.loc)
