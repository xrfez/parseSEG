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

import std/[math, tables, hashes]
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
    srcZ*, rcvZ*: float64 ## Source and receiver elevation (SEG-Y scaled; SEG-D coordinate 3).
    cmpX*, cmpY*: float64 ## Midpoint: SEG-Y CDP X/Y, else halfway between source and receiver.
    srcIndex*: int16     ## SEG-D source point index.
    rcvIndex*: int16     ## SEG-D receiver point index.
    depthIndex*, reshootIndex*: uint8 ## SEG-D Rev 3 THE#1 bytes 10 and 8.
    sensorType*: uint8   ## SEG-D THE#1 byte 21.
    component*: uint8    ## Distinguishes the components of one station (see module doc).

func initTraceKeys*(): TraceKeys =
  ## All values unknown.
  TraceKeys(record: NaN, ensemble: NaN, offset: NaN, srcLine: NaN, srcPoint: NaN, srcX: NaN,
    srcY: NaN, rcvLine: NaN, rcvPoint: NaN, rcvX: NaN, rcvY: NaN, srcZ: NaN, rcvZ: NaN,
    cmpX: NaN, cmpY: NaN)

func hasSourceXY*(k: TraceKeys): bool {.inline.} = not (k.srcX.isNaN or k.srcY.isNaN)
func hasReceiverXY*(k: TraceKeys): bool {.inline.} = not (k.rcvX.isNaN or k.rcvY.isNaN)

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

func isComponentCode(code: int): bool {.inline.} =
  # SEG-Y trace identification codes naming a sensor component: pressure,
  # multicomponent V/X/I, rotated V/T/R (11-17), electric and magnetic field
  # components (27-38), rotational pitch/roll/yaw (39-41).
  code in 11..17 or code in 27..41

func unset(x: float64): bool {.inline.} = x == 0 or x.isNaN

func isSourceBlock(t: uint8): bool {.inline.} = t in {0x15'u8..0x19'u8, 0x1F'u8}

proc traceKeys*(gr: GeometryReader, t: SegyTrace): TraceKeys =
  ## The keys of a SEG-Y trace, resolved through its file's layout
  ## (`initGeometryReader(file)`, made once per file).
  let g = gr.geometry(t)
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
  result.srcZ = g.sourceSurfaceElevation
  result.rcvZ = g.receiverElevation
  if not (unset(g.cdpX) and unset(g.cdpY)):
    result.cmpX = g.cdpX
    result.cmpY = g.cdpY
  result.deriveGeometry()
  let code = int(t.header.traceIdCode)
  let base = if code >= 0: code and 0x3FFF else: code
  if isComponentCode(base): result.component = uint8(base)


func finite(x: float64): bool {.inline.} = x == x and x != Inf and x != -Inf

proc positionOf(area: openArray[byte], at: int, x, y, z: var float64): bool =
  # The first usable tuple of the 96-byte Position block at `at`: valid,
  # not of bad quality (3), with finite coordinates 1-2 (coordinate 3 may be
  # +Inf for a 2-D CRS). Coordinates are kept in the CRS's axis order.
  if at + 96 > area.len or area[at + 63] != 0x51 or area[at + 95] != 0x52: return false
  let p = decodeRev3[SegdPositionBlock](area.toOpenArray(at, at + 95))
  template use(c1, c2, c3: float64, valid, quality: uint8) =
    if valid == 1 and quality != 3 and finite(c1) and finite(c2):
      x = c1
      y = c2
      z = if finite(c3): c3 else: NaN
      return true
  use(p.tuple1Coord1, p.tuple1Coord2, p.tuple1Coord3, p.position1Valid, p.position1Quality)
  use(p.tuple2Coord1, p.tuple2Coord2, p.tuple2Coord3, p.position2Valid, p.position2Quality)
  false

proc positionsFrom(area: openArray[byte], k: var TraceKeys, generalArea: bool) =
  # A Position block describes the block it follows: after a source
  # description it is the source's, after a measurement block (0x61) it is
  # the measurement's (ignored), otherwise in a trace header it is the
  # trace's (the receiver). In the general headers it is taken as the
  # source's: real files (INOVA) put it before the source description.
  var after = 0'u8
  for at, bt in blocks(area):
    if bt == 0x50:
      var x, y, z: float64
      if after != 0x61 and positionOf(area, at, x, y, z):
        if generalArea or isSourceBlock(after):
          if not k.hasSourceXY: (k.srcX, k.srcY, k.srcZ) = (x, y, z)
        elif not k.hasReceiverXY: (k.rcvX, k.rcvY, k.rcvZ) = (x, y, z)
    elif bt notin {0x51'u8, 0x52'u8, 0x56'u8}: # parts of a position, relative positions
      after = bt

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
    positionsFrom(t.extensions, result, generalArea = false)
    positionsFrom(rec.generalBlocks, result, generalArea = true)
    result.deriveGeometry()
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

proc traceKeys*(f: SegyFile, t: SegyTrace): TraceKeys =
  ## The keys of a SEG-Y trace (resolves the layout on every call).
  initGeometryReader(f).traceKeys(t)

# ------------------------------------------------------ external geometry --
# Survey files (SPS, SEG P1; Phase 10) or a host's own database give the
# coordinates that SEG-D 2.x headers lack. They are joined to traces on the
# station keys: (line, point, index).

type
  StationKey* = object
    line*, point*: float64
    index*: int16 ## 0 in a table entry matches any index.

  Coordinates* = object
    x*, y*, z*: float64 ## z may be NaN.

  GeometryTable* = object
    ## Source and receiver coordinates by station.
    sources*, receivers*: Table[StationKey, Coordinates]

func hash*(k: StationKey): Hash =
  var h: Hash = 0
  h = h !& hash(if k.line == 0: 0.0 else: k.line)
  h = h !& hash(if k.point == 0: 0.0 else: k.point)
  h = h !& hash(k.index)
  !$h

func `==`*(a, b: StationKey): bool =
  a.line == b.line and a.point == b.point and a.index == b.index

proc addSource*(g: var GeometryTable, line, point: float64, index: int16, x, y: float64,
    z = NaN) =
  ## Adds or replaces a source station; `index` 0 matches any point index.
  g.sources[StationKey(line: line, point: point, index: index)] = Coordinates(x: x, y: y, z: z)

proc addReceiver*(g: var GeometryTable, line, point: float64, index: int16, x, y: float64,
    z = NaN) =
  ## Adds or replaces a receiver station; `index` 0 matches any point index.
  g.receivers[StationKey(line: line, point: point, index: index)] = Coordinates(x: x, y: y, z: z)

proc lookup(t: Table[StationKey, Coordinates], line, point: float64, index: int16,
    c: var Coordinates): bool =
  if line.isNaN or point.isNaN: return false
  for key in [StationKey(line: line, point: point, index: index),
      StationKey(line: line, point: point, index: 0)]:
    if key in t:
      c = t[key]
      return true

proc applyGeometry*(k: var TraceKeys, g: GeometryTable, overwrite = false): bool =
  ## Fills the trace's source and receiver coordinates from `g` (only where
  ## unknown, unless `overwrite`), then its offset and midpoint. True if
  ## anything changed.
  var c: Coordinates
  result = false
  if (overwrite or not k.hasSourceXY) and
      g.sources.lookup(k.srcLine, k.srcPoint, k.srcIndex, c):
    (k.srcX, k.srcY, k.srcZ) = (c.x, c.y, c.z)
    result = true
  if (overwrite or not k.hasReceiverXY) and
      g.receivers.lookup(k.rcvLine, k.rcvPoint, k.rcvIndex, c):
    (k.rcvX, k.rcvY, k.rcvZ) = (c.x, c.y, c.z)
    result = true
  if result: k.deriveGeometry(overwrite = true)
