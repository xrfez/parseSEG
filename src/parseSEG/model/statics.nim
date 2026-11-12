## SEG-Y datum, depth, uphole, statics and weathering fields per trace
## (Phase 16.8), read on demand: a column set apart from `TraceKeys`, so
## the stored keys stay small. Values are scaled as the standard says
## (elevations and depths by bytes 69-70, times by the time scalar of bytes
## 215-216 from Rev 1 on) and Trace Header Extension 1's copies override the
## standard fields when non-zero. NaN where unknown, and for SEG-D and SEG-2.
##
## ```nim
## var f = openSeismic("line.sgy")
## let st = f.traceStatics(0 ..< f.len)
## echo st[0].srcStatic, " ms, datum ", st[0].srcDatum
## ```

import std/math
import ./traceindex
import ../segy/[traceheader, reader as segyreader]
import ../private/checks

type
  TraceStatics* = object
    ## The elevation and statics fields of one SEG-Y trace, scaled.
    srcDepth*: float64   ## Source depth below the surface (bytes 49-52; Ext1 57-64).
    rcvDepth*: float64   ## Receiver depth below its surface (Ext1 41-48 only).
    rcvDatum*: float64   ## Seismic datum elevation at the receiver (53-56; Ext1 65-72).
    srcDatum*: float64   ## Seismic datum elevation at the source (57-60; Ext1 73-80).
    weatheringVelocity*, subweatheringVelocity*: float64 ## Bytes 91-92, 93-94 (ft/s or m/s).
    srcUphole*, rcvUphole*: float64 ## Uphole times at source and group, ms (95-96, 97-98).
    srcStatic*, rcvStatic*: float64 ## Source and group statics, ms (99-100, 101-102).
    totalStatic*: float64 ## Total static applied, ms (103-104; 0 = none).

func initTraceStatics*(): TraceStatics =
  ## All values unknown.
  TraceStatics(srcDepth: NaN, rcvDepth: NaN, rcvDatum: NaN, srcDatum: NaN,
    weatheringVelocity: NaN, subweatheringVelocity: NaN, srcUphole: NaN, rcvUphole: NaN,
    srcStatic: NaN, rcvStatic: NaN, totalStatic: NaN)

proc staticsOf(f: SeismicFile, trace: int): TraceStatics =
  result = initTraceStatics()
  if f.kind != skSegy: return
  let e = f.index.entries[trace]
  let a = int(e.offset)
  let hb = int(e.headerBytes)
  if e.offset < 0 or e.offset + max(hb, TraceHeaderSize) > f.mappedSize: return
  let mem = f.unsafeMemory
  let order = f.index.segy.byteOrder
  let h = decodeTraceHeader(mem.toOpenArray(a, a + TraceHeaderSize - 1), order)
  let time = if f.index.segy.revision.major >= 1: h.timeScalar else: 0'i16
  template elev(v: untyped): float64 = applyScalar(v, h.elevationScalar)
  template ms(v: untyped): float64 = applyScalar(v, time)
  result.srcDepth = elev(h.sourceDepth)
  result.rcvDatum = elev(h.receiverDatumElevation)
  result.srcDatum = elev(h.sourceDatumElevation)
  result.weatheringVelocity = float64(h.weatheringVelocity)
  result.subweatheringVelocity = float64(h.subweatheringVelocity)
  result.srcUphole = ms(h.upholeTimeSource)
  result.rcvUphole = ms(h.upholeTimeGroup)
  result.srcStatic = ms(h.sourceStatic)
  result.rcvStatic = ms(h.groupStatic)
  result.totalStatic = ms(h.totalStatic)
  if hb >= 2 * TraceHeaderSize:
    let x = decodeTraceHeaderExt1(
      mem.toOpenArray(a + TraceHeaderSize, a + 2 * TraceHeaderSize - 1), order)
    template over(dst, v: untyped) =
      if v != 0 and not v.isNaN: dst = v
    over(result.srcDepth, x.extSourceDepth)
    over(result.rcvDatum, x.extReceiverDatumElevation)
    over(result.srcDatum, x.extSourceDatumElevation)
    if not x.receiverDepth.isNaN: result.rcvDepth = x.receiverDepth

proc traceStaticsInto*(f: SeismicFile, traces: openArray[int],
    dst: var openArray[TraceStatics]) =
  ## The statics of each trace of `traces` into `dst` (`dst.len ==
  ## traces.len`). Raises `ValueError` for a trace out of range, a closed
  ## file or a `dst` of the wrong length. A trace whose headers lie outside
  ## the file gets unknown values.
  if dst.len != traces.len:
    raise newException(ValueError, "need " & $traces.len & " rows, got " & $dst.len)
  for t in traces: f.requireTrace(t)
  if traces.len > 0: f.requireOpen()
  for k, t in traces: dst[k] = f.staticsOf(t)

proc traceStaticsInto*(f: SeismicFile, traces: Slice[int], dst: var openArray[TraceStatics]) =
  ## `traceStaticsInto` for a range of traces (an empty range must start in
  ## `0 .. len`).
  checkSpan(traces, f.len)
  let n = spanLen(traces)
  if dst.len != n: raise newException(ValueError, "need " & $n & " rows, got " & $dst.len)
  if n > 0: f.requireOpen()
  for k in 0 ..< n: dst[k] = f.staticsOf(traces.a + k)

proc traceStatics*(f: SeismicFile, traces: Slice[int]): seq[TraceStatics] =
  ## The statics of a range of traces (see `traceStaticsInto`).
  checkSpan(traces, f.len) # before its length is taken: that can overflow
  result = newSeq[TraceStatics](spanLen(traces))
  f.traceStaticsInto(traces, result)

proc traceStatics*(f: SeismicFile, traces: openArray[int]): seq[TraceStatics] =
  ## The statics of a list of traces (see `traceStaticsInto`).
  result = newSeq[TraceStatics](traces.len)
  f.traceStaticsInto(traces, result)
