## Per-trace geometry keys: who shot a trace and where it was recorded.
##
## Gather detection and component grouping (`gathers`) work on these keys
## instead of on format-specific headers, so they treat SEG-Y, every SEG-D
## revision and SEG-2 alike. Unknown values are NaN (floats) or 0 (codes).
##
## Where the values come from:
## - SEG-Y: the layout-aware `geometry` (source/group coordinates, energy
##   source point or shotpoint, field record, channel, ensemble, offset; zero
##   coordinate pairs and source points count as unknown); the component is the
##   trace identification code when it names a component (11-17, 27-41).
##   The source point is the energy source point (bytes 17-20), or the
##   scaled shotpoint (197-202) when there is no energy source point or the
##   shotpoint is that point with its fraction (99.5 beside 100). Stations
##   come from the names `sht_line`, `sht_point`, `sht_index`, `rec_line`,
##   `rec_point`, `rec_index` when the file's Layout stanza has them (a
##   SEG-D file converted by this library keeps its stations so; a line and
##   point that are both 0 are no station).
## - SEG-D Rev 1/2: the source from the record's first General Header #N; the
##   receiver from Trace Header Extension #1 (line, point, point index); the
##   component is the sensor type (byte 21), as 2.x has no group field. In
##   every SEG-D revision a line and point that are both 0 are a header left
##   empty: that station stays unknown (NaN, index 0).
## - SEG-D Rev 3: the source from a Source Description block (0x15-0x19,
##   0x1F) in the trace's extensions, else in the record's general header
##   blocks; the receiver from THE#1, plus depth and reshoot indices; the
##   component is THE#1 byte 9 (group index), else the sensor type.
## - SEG-2: the trace strings (see `traceKeys(Seg2File, Seg2Trace)`).
##
## Timing and status (`t0Ms`, `intervalUs`, `traceCode`, `status`): SEG-Y
## from the delay, time scalar, interval and trace identification code
## fields (`segyStatus`), the delay and the code where the layout has them
## (a Layout stanza may move them; one that keeps something else in their
## bytes leaves `t0Ms` NaN and the code 0), the interval always at bytes
## 117-118 and Extension 1's, where the reader reads it; SEG-D from the
## trace's channel set (start time, interval, channel type) and its trace
## edit code (`segdStatus`); SEG-2 from DELAY, SAMPLE_INTERVAL and
## TRACE_TYPE. `inline` and `crossline` are SEG-Y only (the layout's `iline`
## and `xline`).
##
## The trace time (`time`, UTC POSIX seconds, task 6.9):
## - SEG-Y: trace bytes 157-166 (year, day of year, hour, minute, second;
##   Ext1 bytes 141-144 add nanoseconds; elsewhere when a Layout stanza
##   moves them) in the time basis of bytes 167-168,
##   or of binary bytes 3511-3512 (Rev 2 and later) when those are 0.
##   GMT (2) and UTC (4) are taken as they are, GPS (5) is converted to UTC with
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
import ../private/segykeys
import ./keytypes
export keytypes

func isSourceBlock(t: uint8): bool {.inline.} = t in {0x15'u8..0x19'u8, 0x1F'u8}

proc traceKeys*(gr: GeometryReader, t: SegyTrace): TraceKeys =
  ## The keys of a SEG-Y trace, resolved through its file's layout
  ## (`initGeometryReader(file)`, made once per file).
  withRawHeaders(gr.planOrder, t, h):
    result = segyKeys(gr, h)

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

func isStation(line, point: float64): bool {.inline.} =
  # A line and a point that are both 0 are a header left empty, not station
  # 0/0: the keys stay unknown, as a zero source point and zero coordinate
  # pairs do in SEG-Y. (A join would match such a "station" to whatever the
  # survey has at 0/0, and refuse to fill the real one.)
  not (line == 0 and point == 0)

proc sourceFrom(area: openArray[byte], k: var TraceKeys): bool =
  # The first Source Description block of a Rev 3 block area that names a
  # station.
  for at, bt in blocks(area):
    if isSourceBlock(bt):
      let s = decodeBlock[SegdSourceDescription](area.toOpenArray(at, at + SegdBlockSize - 1))
      if isStation(s.sourceLineNumber, s.sourcePointNumber):
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
  generalHeaderUtc(rec.gh1)

func knownSet(rec: SegdRecord, t: SegdTrace): bool =
  # The trace's channel set is one of the record's descriptors.
  if t.channelSet < 0 or t.scanType < 0 or t.scanType >= rec.scanTypes.len: return false
  template s: untyped = rec.scanTypes[t.scanType]
  case s.layout
  of slRev2: t.channelSet < s.descriptors.len
  of slRev3: t.channelSet < s.descriptorsRev3.len

func segdStatus*(rec: SegdRecord, t: SegdTrace): TraceStatus =
  ## Auxiliary for a channel set that is not seismic (Rev 1/2 channel type
  ## 1, Rev 3 0x10 seismic and 0x11 electromagnetic), also when zeroed; else
  ## dead for trace edit codes 1 and 2 (header byte 12: zeroed), unknown for
  ## an unknown channel set, else live.
  let known = knownSet(rec, t)
  if known:
    let ct = rec.channelType(t.scanType, t.channelSet)
    if not (if rec.isRev3: ct in [0x10, 0x11] else: ct == 1): return tsAuxiliary
  if t.header.traceEdit in {1'u8, 2'u8}: tsDead
  elif known: tsLive
  else: tsUnknown

proc traceKeys*(rec: SegdRecord, t: SegdTrace): TraceKeys =
  ## The keys of a SEG-D trace in record `rec`.
  result = initTraceKeys()
  result.record = float64(rec.fileNumber)
  result.time = segdTime(rec, t)
  if knownSet(rec, t):
    result.t0Ms = rec.startTimeMs(t)
    result.intervalUs = rec.sampleIntervalUs(t)
  elif t.channelSet < 0:
    result.intervalUs = rec.baseScanIntervalUs # as `sampleIntervalUs` without a set
  result.status = segdStatus(rec, t)
  if t.header.traceNumber != BcdAllF: result.channel = float64(t.header.traceNumber)
  if rec.isRev3:
    if not sourceFrom(t.extensions, result): discard sourceFrom(rec.generalBlocks, result)
    if t.ext1Rev3.isSome:
      let e = t.ext1Rev3.get
      if isStation(e.receiverLine, e.receiverPoint):
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
      if isStation(s.sourceLineNumber, s.sourcePointNumber):
        result.srcLine = s.sourceLineNumber
        result.srcPoint = s.sourcePointNumber
        result.srcIndex = int16(s.sourcePointIndex)
    if t.ext1.isSome:
      let e = t.ext1.get
      if isStation(e.receiverLine, e.receiverPoint):
        result.rcvLine = e.receiverLine
        result.rcvPoint = e.receiverPoint
        result.rcvIndex = int16(e.receiverPointIndex)
      result.sensorType = e.sensorType
      result.component = e.sensorType

proc traceKeys*(f: Seg2File, t: Seg2Trace): TraceKeys =
  ## The keys of a SEG-2 trace, from its keyword strings (`seg2.md` §7.2):
  ## - `record`: SHOT_SEQUENCE_NUMBER (the trace's, else the file's);
  ## - `ensemble`: CDP_NUMBER; `channel`: CHANNEL_NUMBER;
  ## - `srcPoint` / `rcvPoint`: `SOURCE_` / RECEIVER_STATION_NUMBER;
  ## - `srcLine` = `rcvLine`: LINE_ID when it is a number;
  ## - source and receiver x, y, z: `SOURCE_` / RECEIVER_LOCATION, in the
  ##   file's UNITS (a one-value location is x along the line, y = 0, so
  ##   offsets still follow); z plus DATUM when DATUM is given;
  ## - `component`: RECEIVER's type as a SEG-Y trace identification code:
  ##   VERTICAL_GEOPHONE 12 (vertical), SH_HORIZONTAL_GEOPHONE 13
  ##   (crossline), SV_HORIZONTAL_GEOPHONE 14 (inline), else 0;
  ## - `time`: the file's ACQUISITION_DATE/TIME (`acquisitionTime`);
  ## - `t0Ms`: DELAY × 1000 (0 without one); `intervalUs`: SAMPLE_INTERVAL;
  ## - `status`: from TRACE_TYPE (`tsUnknown` without one);
  ## - `offset` and the midpoint: derived from the locations.
  result = initTraceKeys()
  let delay = t.delay
  result.t0Ms = if delay.isSome: delay.get * 1000 else: 0.0
  let si = t.sampleInterval
  if si.isSome: result.intervalUs = si.get * 1e6
  let tt = t.traceType
  if tt.isSome:
    result.status = case tt.get
      of ttSeismicData, ttRadarData: tsLive
      of ttDead: tsDead
      of ttTestData, ttUphole: tsAuxiliary
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
  ## unknown, unless `overwrite`), then its offset and midpoint. True if a
  ## value changed: a trace that already holds the table's values is not
  ## changed, with or without `overwrite`.
  ## A table z of NaN keeps a known elevation. With `overwrite`, the offset
  ## and midpoint are recomputed from the new coordinates; otherwise only
  ## unknown ones are filled (a signed SEG-Y header offset stays).
  func values(k: TraceKeys): array[9, float64] {.inline.} =
    [k.srcX, k.srcY, k.srcZ, k.rcvX, k.rcvY, k.rcvZ, k.offset, k.cmpX, k.cmpY]
  let before = values(k)
  var c: Coordinates
  var found = false
  if (overwrite or not k.hasSourceXY) and
      g.sources.lookup(k.srcLine, k.srcPoint, k.srcIndex, c):
    (k.srcX, k.srcY) = (c.x, c.y)
    if not c.z.isNaN: k.srcZ = c.z
    found = true
  if (overwrite or not k.hasReceiverXY) and
      g.receivers.lookup(k.rcvLine, k.rcvPoint, k.rcvIndex, c):
    (k.rcvX, k.rcvY) = (c.x, c.y)
    if not c.z.isNaN: k.rcvZ = c.z
    found = true
  result = false
  if found:
    k.deriveGeometry(overwrite)
    let after = values(k)
    for i in 0 ..< before.len:
      if not (before[i] == after[i] or (before[i].isNaN and after[i].isNaN)): return true
