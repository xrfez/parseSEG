## The per-trace geometry keys (`TraceKeys`) and their helpers, apart from
## the code that reads them from each standard (`model/keys`, which
## re-exports this module), so the library's SEG-Y key reader
## (`private/segykeys`) can build them.

import std/math

type
  TraceStatus* = enum
    ## What a trace holds (`TraceKeys.status`).
    tsUnknown   ## The headers do not say (SEG-Y trace code 0, -1 or an optional code).
    tsLive      ## Seismic data.
    tsDead      ## Dead or intentionally zeroed (SEG-Y codes 2 and 3, SEG-D trace edit 1 and 2,
                ## SEG-2 `TRACE_TYPE DEAD`).
    tsAuxiliary ## Not seismic data: SEG-Y time break, uphole, sweep, timing, water break,
                ## gun signature, vibrator and velocity/depth pair codes; SEG-D channel types
                ## other than seismic (and EM); SEG-2 `TEST_DATA` and `UPHOLE`.

  TraceKeys* = object
    ## Geometry of one trace (NaN / 0 where unknown).
    record*: float64     ## SEG-Y field record number; SEG-D file number.
    ensemble*: float64   ## SEG-Y ensemble (CDP) number; NaN for SEG-D.
    offset*: float64     ## SEG-Y source-receiver offset; NaN for SEG-D.
    srcLine*, srcPoint*: float64
    srcX*, srcY*: float64
    rcvLine*, rcvPoint*: float64
    rcvX*, rcvY*: float64
    srcZ*, rcvZ*: float64 ## Source and receiver elevation (SEG-Y scaled; SEG-D coordinate 3).
    cmpX*, cmpY*: float64 ## Midpoint: SEG-Y CDP X/Y, else halfway between source and receiver.
    srcIndex*: int16     ## SEG-D source point index.
    rcvIndex*: int16     ## SEG-D receiver point index.
    depthIndex*, reshootIndex*: uint8 ## SEG-D Rev 3 THE#1 bytes 10 and 8.
    sensorType*: uint8   ## SEG-D THE#1 byte 21.
    component*: uint8    ## Distinguishes the components of one station (see module doc).
    traceCode*: int16
      ## SEG-Y trace identification code (bytes 29-30) as stored; 0 when unknown
      ## and for SEG-D and SEG-2.
    status*: TraceStatus ## Live, dead or auxiliary (see `TraceStatus`).
    channel*: float64
      ## Channel (trace) number in the field record: SEG-Y bytes 13-16, SEG-D
      ## the demux trace number (Rev 3: extended when `FFFF`). Survey relation
      ## records (SPS X) map (record, channel) to stations.
    time*: float64
      ## When the trace was recorded, in UTC POSIX seconds (fractional); NaN if
      ## unknown. SEG-Y: trace bytes 157-168 in their time basis; SEG-D: GH#1,
      ## for Rev 3 the trace's Timestamp block or the GH#3 time zero (see the
      ## module documentation).
    t0Ms*: float64
      ## Time of sample 0 in ms (in ms also for SEG-Y depth data, whose "time"
      ## fields hold depths). SEG-Y: the delay recording time (bytes 109-110)
      ## times the time scalar (bytes 215-216, Rev 1 and later; 0 means 1);
      ## SEG-D: the channel set's start time; SEG-2: DELAY × 1000. 0 when the
      ## field is unset, NaN when the headers cannot give it (an unknown SEG-D
      ## channel set).
    intervalUs*: float64
      ## The trace's sample interval in µs (Hz or m/ft for SEG-Y non-time
      ## data), exactly as `sampleIntervalUs(f, trace)` resolves it; NaN when
      ## the headers cannot give it.
    inline*, crossline*: float64
      ## SEG-Y: the layout's `iline` and `xline` (Rev 1 and later: bytes 189 and
      ## 193, unless a Layout stanza or vendor map moves them); 0 counts as
      ## unset. NaN when unset, and for SEG-D and SEG-2.

func initTraceKeys*(): TraceKeys =
  ## All values unknown.
  TraceKeys(record: NaN, ensemble: NaN, offset: NaN, srcLine: NaN, srcPoint: NaN, srcX: NaN,
    srcY: NaN, rcvLine: NaN, rcvPoint: NaN, rcvX: NaN, rcvY: NaN, srcZ: NaN, rcvZ: NaN,
    cmpX: NaN, cmpY: NaN, channel: NaN, time: NaN, t0Ms: NaN, intervalUs: NaN, inline: NaN,
    crossline: NaN)

func isSeismic*(k: TraceKeys): bool {.inline.} =
  ## The trace is not auxiliary (live, dead or of unknown status).
  k.status != tsAuxiliary

func hasSourceXY*(k: TraceKeys): bool {.inline.} =
  ## Both source coordinates are known.
  not (k.srcX.isNaN or k.srcY.isNaN)

func hasReceiverXY*(k: TraceKeys): bool {.inline.} =
  ## Both receiver coordinates are known.
  not (k.rcvX.isNaN or k.rcvY.isNaN)

func deriveGeometry*(k: var TraceKeys, overwrite = false) =
  ## Fills `offset` (the source-receiver distance) and the midpoint from the
  ## coordinates when both ends are known. An existing non-zero offset (e.g.
  ## SEG-Y's signed header offset) and midpoint are kept unless `overwrite`;
  ## a zero offset counts as unset (SEG-Y headers hold 0 when not filled).
  if k.hasSourceXY and k.hasReceiverXY:
    if overwrite or k.offset.isNaN or k.offset == 0:
      k.offset = hypot(k.rcvX - k.srcX, k.rcvY - k.srcY)
    if overwrite or k.cmpX.isNaN or k.cmpY.isNaN:
      k.cmpX = (k.srcX + k.rcvX) / 2
      k.cmpY = (k.srcY + k.rcvY) / 2
