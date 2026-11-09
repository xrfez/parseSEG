## Per-trace geometry keys: who shot a trace and where it was recorded.
##
## Gather detection and component grouping (`gathers`) work on these keys
## instead of on format-specific headers, so they treat SEG-Y, every SEG-D
## revision and SEG-2 alike. Unknown values are NaN (floats) or 0 (codes).
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
## - SEG-2: the trace strings (see `traceKeys(Seg2File, Seg2Trace)`).
##
## The trace time (`time`, UTC POSIX seconds, task 6.9):
## - SEG-Y: trace bytes 157-166 (year, day of year, hour, minute, second;
##   Ext1 bytes 141-144 add nanoseconds) in the time basis of bytes 167-168,
##   or of binary bytes 3511-3512 (Rev 2 and later) when those are 0. GMT
##   (2) and UTC (4) are taken as they are, GPS (5) is converted to UTC with
##   the leap second table, and an unset basis (0) is read as UTC, as most
##   files leave it unset; local (1) and other (3) times are unknown (NaN).
##   Year 0 is unknown; years 1-99 (Rev 0 files) are 1950-2049.
## - SEG-D Rev 1/2: the record's GH#1 date and time (1 s resolution; years
##   1950-2049).
## - SEG-D Rev 3: the trace's Timestamp block (0x42) when it has one, else
##   the GH#3 time zero (both GPS µs), else GH#1 as for Rev 1/2.
## - SEG-2: ACQUISITION_DATE/TIME (`Seg2File.acquisitionTime`).

import std/[math, tables, hashes, strutils]
import ../segy/[reader as segyreader, fields]
import ../segd/[reader as segdreader]
import ../seg2/headers as seg2headers
import ../common/years

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

func isComponentCode(code: int): bool {.inline.} =
  # SEG-Y trace identification codes naming a sensor component: pressure,
  # multicomponent V/X/I, rotated V/T/R (11-17), electric and magnetic field
  # components (27-38), rotational pitch/roll/yaw (39-41).
  code in 11..17 or code in 27..41

func unset(x: float64): bool {.inline.} = x == 0 or x.isNaN

func isSourceBlock(t: uint8): bool {.inline.} = t in {0x15'u8..0x19'u8, 0x1F'u8}

func civilSeconds(year, day, hour, minute, second: int): float64 =
  # POSIX seconds of a date given as year and day of year, as if it were UTC;
  # NaN when a field is out of range.
  if year notin 1..9999 or day notin 1..366 or hour notin 0..23 or minute notin 0..59 or
      second notin 0..60:
    return NaN
  let jan1 = daysFromCivil(year, 1, 1) * 86400
  float64(jan1 + int64(day - 1) * 86400 + int64(hour) * 3600 + int64(minute) * 60 + second)

proc segyTime(gr: GeometryReader, t: SegyTrace): float64 =
  let h = t.header
  if h.year == 0: return NaN
  let basis = if h.timeBasisCode != 0: h.timeBasisCode else: gr.timeBasis
  let s = civilSeconds(fullYear(int(h.year)), int(h.dayOfYear), int(h.hour), int(h.minute),
    int(h.second))
  let ns = if t.hasExt1: float64(t.ext1.nanoseconds) * 1e-9 else: 0.0
  case basis
  of 0, 2, 4: s + ns
  of 5: # GPS time of day: as a SEG-D timestamp, which converts with the leap seconds
    if s.isNaN: NaN
    else: timestampToUnix(int64(round((s - float64(GpsEpochUnix)) * 1e6))) + ns
  else: NaN

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
  if t.header.traceNumberInField > 0: result.channel = float64(t.header.traceNumberInField)
  let code = int(t.header.traceIdCode)
  let base = if code >= 0: code and 0x3FFF else: code
  if isComponentCode(base): result.component = uint8(base)
  result.time = gr.segyTime(t)


func finite(x: float64): bool {.inline.} = not x.isNaN and x != Inf and x != -Inf

proc positionOf(area: openArray[byte], at: int, x, y, z: var float64): bool =
  # The first usable tuple of the 96-byte Position block at `at`: valid,
  # not of bad quality (3), with finite coordinates 1-2 (coordinate 3 may be
  # +Inf for a 2-D CRS). Coordinates are kept in the CRS's axis order.
  if at + 96 > area.len or area[at + 63] != 0x51 or area[at + 95] != 0x52: return false
  let p = decodeBlock[SegdPositionBlock](area.toOpenArray(at, at + 95))
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
    elif bt notin {0x51'u8, 0x52'u8, 0x56'u8, 0x20'u8, 0x1A'u8, 0x21'u8}:
      # Position parts, relative positions, and a source's Additional Source
      # Info / Aux Channel Reference blocks (§6.5: they sit between the
      # source description and its position) keep the block described.
      after = bt

proc sourceFrom(area: openArray[byte], k: var TraceKeys): bool =
  # The first Source Description block of a Rev 3 block area.
  for at, bt in blocks(area):
    if isSourceBlock(bt):
      let s = decodeBlock[SegdSourceDescription](area.toOpenArray(at, at + SegdBlockSize - 1))
      k.srcLine = s.sourceLineNumber
      k.srcPoint = s.sourcePointNumber
      k.srcIndex = int16(s.sourcePointIndex)
      return true

proc segdTime(rec: SegdRecord, t: SegdTrace): float64 =
  if rec.isRev3:
    let at = findBlock(t.extensions, 0x42'u8)
    if at >= 0:
      let ts = decodeBlock[SegdTimestampHeader](t.extensions.toOpenArray(at,
        at + SegdBlockSize - 1))
      if ts.timeZeroOfData != 0: return timestampToUnix(ts.timeZeroOfData)
    if rec.gh3.timeZero != 0: return timestampToUnix(rec.gh3.timeZero)
  if rec.gh1.year < 0: NaN else: generalHeaderUtc(rec.gh1, fullYear(rec.gh1.year) - rec.gh1.year)

proc traceKeys*(rec: SegdRecord, t: SegdTrace): TraceKeys =
  ## The keys of a SEG-D trace in record `rec`.
  result = initTraceKeys()
  result.record = float64(rec.fileNumber)
  result.time = segdTime(rec, t)
  if t.header.traceNumber != BcdAllF: result.channel = float64(t.header.traceNumber)
  if rec.isRev3:
    if not sourceFrom(t.extensions, result): discard sourceFrom(rec.generalBlocks, result)
    if t.ext1Rev3.isSome:
      let e = t.ext1Rev3.get
      result.rcvLine = e.receiverLine
      result.rcvPoint = e.receiverPoint
      result.rcvIndex = int16(e.receiverPointIndex)
      result.depthIndex = e.depthIndex
      result.reshootIndex = e.reshootIndex
      result.channel = float64(traceNumber(t.header, e))
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
    if t.ext1.isSome:
      let e = t.ext1.get
      result.rcvLine = e.receiverLine
      result.rcvPoint = e.receiverPoint
      result.rcvIndex = int16(e.receiverPointIndex)
      result.sensorType = e.sensorType
      result.component = e.sensorType

proc traceKeys*(f: Seg2File, t: Seg2Trace): TraceKeys =
  ## The keys of a SEG-2 trace, from its keyword strings (`seg2.md` §7.2):
  ## - `record`: SHOT_SEQUENCE_NUMBER (the trace's, else the file's);
  ## - `ensemble`: CDP_NUMBER; `channel`: CHANNEL_NUMBER;
  ## - `srcPoint` / `rcvPoint`: SOURCE_ / RECEIVER_STATION_NUMBER;
  ## - `srcLine` = `rcvLine`: LINE_ID when it is a number;
  ## - source and receiver x, y, z: SOURCE_ / RECEIVER_LOCATION, in the
  ##   file's UNITS (a one-value location is x along the line, y = 0, so
  ##   offsets still follow); z plus DATUM when DATUM is given;
  ## - `component`: RECEIVER's type as a SEG-Y trace identification code:
  ##   VERTICAL_GEOPHONE 12 (vertical), SH_HORIZONTAL_GEOPHONE 13
  ##   (crossline), SV_HORIZONTAL_GEOPHONE 14 (inline), else 0;
  ## - `time`: the file's ACQUISITION_DATE/TIME (`acquisitionTime`);
  ## - `offset` and the midpoint: derived from the locations.
  result = initTraceKeys()
  let at = f.acquisitionTime
  if at.isSome: result.time = at.get
  template num(key: string): Option[float64] =
    (let v = t.number(key); if v.isSome: v else: f.number(key))
  let shot = num("SHOT_SEQUENCE_NUMBER")
  if shot.isSome: result.record = shot.get
  let cdp = t.number("CDP_NUMBER")
  if cdp.isSome: result.ensemble = cdp.get
  let ch = t.number("CHANNEL_NUMBER")
  if ch.isSome: result.channel = ch.get
  let sp = t.number("SOURCE_STATION_NUMBER")
  if sp.isSome: result.srcPoint = sp.get
  let rp = t.number("RECEIVER_STATION_NUMBER")
  if rp.isSome: result.rcvPoint = rp.get
  let line = t.value("LINE_ID")
  if line.isSome:
    try:
      let x = parseFloat(line.get.strip)
      (result.srcLine, result.rcvLine) = (x, x)
    except ValueError: discard # a line name, not a number
  let datum = num("DATUM")
  let dz = if datum.isSome: datum.get else: 0.0
  let src = t.sourceLocation
  if src.isSome:
    (result.srcX, result.srcY, result.srcZ) = (src.get.x, src.get.y, src.get.z + dz)
  let rcv = t.receiverLocation
  if rcv.isSome:
    (result.rcvX, result.rcvY, result.rcvZ) = (rcv.get.x, rcv.get.y, rcv.get.z + dz)
  let r = t.value("RECEIVER")
  if r.isSome:
    let w = r.get.splitWhitespace
    if w.len > 0:
      result.component = case w[0].toUpperAscii
        of "VERTICAL_GEOPHONE": 12
        of "SH_HORIZONTAL_GEOPHONE": 13
        of "SV_HORIZONTAL_GEOPHONE": 14
        else: 0
  result.deriveGeometry()

proc traceKeys*(f: SegyFile, t: SegyTrace): TraceKeys =
  ## The keys of a SEG-Y trace (resolves the layout on every call).
  initGeometryReader(f).traceKeys(t)

# ------------------------------------------------------ external geometry --
# Survey files (SPS, SEG P1; Phase 10) or a host's own database give the
# coordinates that SEG-D 2.x headers lack. They are joined to traces on the
# station keys: (line, point, index).

type
  StationKey* = object
    ## A survey station: line, point and point index (see `stationKey`).
    line*, point*: float64
    index*: int16 ## 0 in a table entry matches any index.

  Coordinates* = object
    ## A station's position, in the survey's grid units.
    x*, y*, z*: float64 ## z may be NaN.

  GeometryTable* = object
    ## Source and receiver coordinates by station.
    sources*, receivers*: Table[StationKey, Coordinates]

func hash*(k: StationKey): Hash =
  ## Consistent with `==` (0.0 and -0.0 hash alike).
  var h: Hash = 0
  h = h !& hash(if k.line == 0: 0.0 else: k.line)
  h = h !& hash(if k.point == 0: 0.0 else: k.point)
  h = h !& hash(k.index)
  !$h

func `==`*(a, b: StationKey): bool =
  ## Same line, point and index.
  a.line == b.line and a.point == b.point and a.index == b.index

func stationKey*(line, point: float64, index: int16): StationKey =
  ## The table key of a station. Line and point are rounded to 1/100, the
  ## resolution of survey files (SPS F10.2), so values decoded from binary
  ## fractions (SEG-D) match the same station.
  StationKey(line: round(line * 100) / 100, point: round(point * 100) / 100, index: index)

proc addSource*(g: var GeometryTable, line, point: float64, index: int16, x, y: float64,
    z = NaN) =
  ## Adds or replaces a source station; `index` 0 matches any point index.
  g.sources[stationKey(line, point, index)] = Coordinates(x: x, y: y, z: z)

proc addReceiver*(g: var GeometryTable, line, point: float64, index: int16, x, y: float64,
    z = NaN) =
  ## Adds or replaces a receiver station; `index` 0 matches any point index.
  g.receivers[stationKey(line, point, index)] = Coordinates(x: x, y: y, z: z)

proc lookup(t: Table[StationKey, Coordinates], line, point: float64, index: int16,
    c: var Coordinates): bool =
  ## Tries the exact station, then an entry for any index (0). A trace with
  ## no index (0) also matches index 1: survey files number the original
  ## position 1 and never write 0.
  if line.isNaN or point.isNaN: return false
  let keys = [stationKey(line, point, index), stationKey(line, point, 0),
    stationKey(line, point, 1)]
  for i in 0 .. (if index == 0: 2 else: 1):
    let key = keys[i]
    if key in t:
      c = t[key]
      return true

proc applyGeometry*(k: var TraceKeys, g: GeometryTable, overwrite = false): bool =
  ## Fills the trace's source and receiver coordinates from `g` (only where
  ## unknown, unless `overwrite`), then its offset and midpoint. True if
  ## anything changed.
  ## A table z of NaN keeps a known elevation. With `overwrite`, the offset
  ## and midpoint are recomputed from the new coordinates; otherwise only
  ## unknown ones are filled (a signed SEG-Y header offset stays).
  var c: Coordinates
  result = false
  if (overwrite or not k.hasSourceXY) and
      g.sources.lookup(k.srcLine, k.srcPoint, k.srcIndex, c):
    (k.srcX, k.srcY) = (c.x, c.y)
    if not c.z.isNaN: k.srcZ = c.z
    result = true
  if (overwrite or not k.hasReceiverXY) and
      g.receivers.lookup(k.rcvLine, k.rcvPoint, k.rcvIndex, c):
    (k.rcvX, k.rcvY) = (c.x, c.y)
    if not c.z.isNaN: k.rcvZ = c.z
    result = true
  if result: k.deriveGeometry(overwrite)
