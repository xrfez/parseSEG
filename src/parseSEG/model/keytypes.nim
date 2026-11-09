## The per-trace geometry keys (`TraceKeys`) and their helpers, apart from
## the code that reads them from each standard (`model/keys`, which
## re-exports this module), so the library's SEG-Y key reader
## (`private/segykeys`) can build them.

import std/math


type
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
    channel*: float64
      ## Channel (trace) number in the field record: SEG-Y bytes 13-16, SEG-D
      ## the demux trace number (Rev 3: extended when `FFFF`). Survey relation
      ## records (SPS X) map (record, channel) to stations.
    time*: float64
      ## When the trace was recorded, in UTC POSIX seconds (fractional); NaN if
      ## unknown. SEG-Y: trace bytes 157-168 in their time basis; SEG-D: GH#1,
      ## for Rev 3 the trace's Timestamp block or the GH#3 time zero (see the
      ## module documentation).

func initTraceKeys*(): TraceKeys =
  ## All values unknown.
  TraceKeys(record: NaN, ensemble: NaN, offset: NaN, srcLine: NaN, srcPoint: NaN, srcX: NaN,
    srcY: NaN, rcvLine: NaN, rcvPoint: NaN, rcvX: NaN, rcvY: NaN, srcZ: NaN, rcvZ: NaN,
    cmpX: NaN, cmpY: NaN, channel: NaN, time: NaN)

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
