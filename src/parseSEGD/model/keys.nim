## Per-trace geometry keys: who shot a trace and where it was recorded.
##
## Gather detection and component grouping (`gathers`) work on these keys
## instead of on format-specific headers, so they treat SEG-Y and every SEG-D
## revision alike. Unknown values are NaN (floats) or 0 (codes).
##
## Where the values come from:
## - SEG-Y: the layout-aware `geometry` (source/group coordinates, energy
##   source point or shotpoint, field record, ensemble, offset; zero
##   coordinate pairs and source points count as unknown); the component is the
##   trace identification code when it names a component (11-17, 27-41).
## - SEG-D Rev 1/2: the source from the record's first General Header #N; the
##   receiver from Trace Header Extension #1 (line, point, point index); the
##   component is the sensor type (byte 21), as 2.x has no group field.
## - SEG-D Rev 3: the source from a Source Description block (0x15-0x19,
##   0x1F) in the trace's extensions, else in the record's general header
##   blocks; the receiver from THE#1, plus depth and reshoot indices; the
##   component is THE#1 byte 9 (group index), else the sensor type.

import std/math
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader]

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
    srcIndex*: int16     ## SEG-D source point index.
    rcvIndex*: int16     ## SEG-D receiver point index.
    depthIndex*, reshootIndex*: uint8 ## SEG-D Rev 3 THE#1 bytes 10 and 8.
    sensorType*: uint8   ## SEG-D THE#1 byte 21.
    component*: uint8    ## Distinguishes the components of one station (see module doc).

func initTraceKeys*(): TraceKeys =
  ## All values unknown.
  TraceKeys(record: NaN, ensemble: NaN, offset: NaN, srcLine: NaN, srcPoint: NaN, srcX: NaN,
    srcY: NaN, rcvLine: NaN, rcvPoint: NaN, rcvX: NaN, rcvY: NaN)

func isComponentCode(code: int): bool {.inline.} =
  # SEG-Y trace identification codes naming a sensor component: pressure,
  # multicomponent V/X/I, rotated V/T/R (11-17), electric and magnetic field
  # components (27-38), rotational pitch/roll/yaw (39-41).
  code in 11..17 or code in 27..41

func unset(x: float64): bool {.inline.} = x == 0 or x.isNaN

proc traceKeys*(f: SegyFile, t: SegyTrace): TraceKeys =
  ## The keys of a SEG-Y trace, resolved through the file's layout.
  let g = f.geometry(t)
  result = initTraceKeys()
  result.record = g.fieldRecord
  result.ensemble = g.ensemble
  result.offset = g.offset
  # Zero means "not set" in practice: a station at exactly (0, 0) or energy
  # source point 0 does not identify anything.
  let sp = if g.energySourcePoint.isNaN or g.energySourcePoint == 0: g.shotpoint
           else: g.energySourcePoint
  if sp != 0: result.srcPoint = sp
  if not (unset(g.sourceX) and unset(g.sourceY)):
    result.srcX = g.sourceX
    result.srcY = g.sourceY
  if not (unset(g.groupX) and unset(g.groupY)):
    result.rcvX = g.groupX
    result.rcvY = g.groupY
  let code = int(t.header.traceIdCode)
  let base = if code >= 0: code and 0x3FFF else: code
  if isComponentCode(base): result.component = uint8(base)

func isSourceBlock(t: uint8): bool {.inline.} = t in {0x15'u8..0x19'u8, 0x1F'u8}

proc sourceFrom(area: openArray[byte], k: var TraceKeys): bool =
  # The first Source Description block of a Rev 3 block area.
  for at, bt in blocks(area):
    if isSourceBlock(bt):
      let s = decodeRev3[SegdSourceDescription](area.toOpenArray(at, at + SegdBlockSize - 1))
      k.srcLine = s.sourceLineNumber
      k.srcPoint = s.sourcePointNumber
      k.srcIndex = int16(s.sourcePointIndex)
      return true

proc traceKeys*(rec: SegdRecord, t: SegdTrace): TraceKeys =
  ## The keys of a SEG-D trace in record `rec`.
  result = initTraceKeys()
  result.record = float64(if rec.isRev3: fileNumber(rec.gh1, rec.gh2r3)
                          elif rec.hasGh2: fileNumber(rec.gh1, rec.gh2)
                          else: int64(rec.gh1.fileNumber))
  if rec.isRev3:
    if not sourceFrom(t.extensions, result): discard sourceFrom(rec.generalBlocks, result)
    if t.hasExt1:
      let e = t.ext1r3
      result.rcvLine = e.receiverLine
      result.rcvPoint = e.receiverPoint
      result.rcvIndex = int16(e.receiverPointIndex)
      result.depthIndex = e.depthIndex
      result.reshootIndex = e.reshootIndex
      result.sensorType = e.sensorType
      result.component = if e.groupIndex != 0: e.groupIndex else: e.sensorType
  else:
    if rec.sourceHeaders.len > 0:
      let s = rec.sourceHeaders[0]
      result.srcLine = s.sourceLineNumber
      result.srcPoint = s.sourcePointNumber
      result.srcIndex = int16(s.sourcePointIndex)
    if t.hasExt1:
      result.rcvLine = t.ext1.receiverLine
      result.rcvPoint = t.ext1.receiverPoint
      result.rcvIndex = int16(t.ext1.receiverPointIndex)
      result.sensorType = t.ext1.sensorType
      result.component = t.ext1.sensorType
