## Joins survey geometry (SPS, SEG P1) to seismic traces.
##
## A `SurveyGeometry` collects station coordinates (a `GeometryTable`) and,
## from SPS X records, which stations every (field record, channel) was
## recorded from. `applySurvey` then fills each trace's `TraceKeys`:
##
## 1. When the trace's field record and channel match an X record, its
##    source and receiver stations (line, point, index) are set from the
##    relation, where unknown (or always, with `overwrite`). This is how
##    SEG-D 2.x traces without station numbers in their headers get them.
## 2. The stations' coordinates come from the table (`keys.applyGeometry`),
##    then the offset and midpoint.
##
## Records are matched on `TraceKeys.record` (SEG-D file number, SEG-Y field
## record) and channels on `TraceKeys.channel`. Relations are stored as runs
## (one per X record), never expanded per channel.
##
## Line names that are not numbers (SPS 1.0, P1) go through the geometry's
## `lineNames` (a caller-supplied name → number map, see `mapLine`), then
## (with `trailingDigits`) the trailing digits of the name (`CLT4960` → 4960).

import std/[options, tables, strutils, math, sets]
import ../common/diagnostics
import ../model/[keys, traceindex]
import ./[textrec, cards, sps, p1]

export keys

type
  RelationRun = object
    fieldTape: string
    fromChannel, toChannel: int64
    step: int64
    src: StationKey
    rcvLine, fromRcv, toRcv: float64
    rcvIndex: int16

  SurveyGeometry* = object
    ## Station coordinates and channel relations from survey files.
    table*: GeometryTable
    runs: Table[int64, seq[RelationRun]]
    multiComponent*: bool
      ## X records with a channel increment k > 1 cover k consecutive
      ## channels per station (components 1..k, SPS 1.0 §"X" note); else
      ## only every k-th channel is in the run.
    tape*: string ## Only X records of this field tape ("" = all).
    lineNames*: Table[string, float64] ## Text line name → line number (see `mapLine`).
    trailingDigits*: bool ## Unmapped line names use their trailing digits.
    log: DiagLog ## See `log`.

  GeometryFields* = object
    ## Which joined values are written to a file (`writeGeometry`,
    ## `copyWithGeometry`, `convertWithGeometry`); all by default.
    sourceXy* = true   ## Source X/Y.
    receiverXy* = true ## Receiver (group) X/Y.
    elevations* = true ## Source and receiver elevation.
    midpoints* = true  ## Midpoint (SEG-Y CDP X/Y), with the coordinates.
    offsets* = true    ## Source-receiver offset (SEG-Y), with the coordinates.
    stations* = true   ## Source and receiver line, point and point index.

  StationRelation* = object
    ## The stations one channel of a field record was recorded from.
    source*, receiver*: StationKey
    component*: int ## 1-based within the station (multi-component), else 0.

func log*(g: SurveyGeometry): lent DiagLog {.inline.} =
  ## Problems met while adding survey files.
  g.log

func relationCount*(g: SurveyGeometry): int =
  ## The number of X runs loaded.
  for runs in g.runs.values: result += runs.len

func initSurveyGeometry*(): SurveyGeometry =
  ## An empty geometry: no stations, no relations.
  SurveyGeometry()

func sourceCount*(g: SurveyGeometry): int {.inline.} =
  ## Source stations held.
  g.table.sources.len

func receiverCount*(g: SurveyGeometry): int {.inline.} =
  ## Receiver stations held.
  g.table.receivers.len

proc addSource*(g: var SurveyGeometry, line, point: float64, index: int16, x, y: float64,
    z = NaN) {.inline.} =
  ## Adds or replaces a source station; index 0 matches any point index.
  g.table.addSource(line, point, index, x, y, z)

proc addReceiver*(g: var SurveyGeometry, line, point: float64, index: int16, x, y: float64,
    z = NaN) {.inline.} =
  ## Adds or replaces a receiver station; index 0 matches any point index.
  g.table.addReceiver(line, point, index, x, y, z)

proc mapLine*(g: var SurveyGeometry, name: string, line: float64) =
  ## Maps a text line name (SPS 1.0, P1) to a line number, for the files
  ## added later. Raises `ValueError` for an empty name or a NaN line.
  if name.strip.len == 0: raise newException(ValueError, "empty line name")
  if line.isNaN: raise newException(ValueError, "line number is NaN")
  g.lineNames[name.strip] = line

proc resolveLine*(g: SurveyGeometry, name: string, numeric: float64): Option[float64] =
  ## The numeric line of a line field: its value when numeric, else the
  ## `lineNames` map, else (with `trailingDigits`) the trailing digits; none
  ## when none applies.
  if not numeric.isNaN: return some(numeric)
  let key = name.strip
  if key in g.lineNames: return some(g.lineNames[key])
  if g.trailingDigits:
    var i = key.len
    while i > 0 and key[i - 1] in Digits: dec i
    if i < key.len: return some(parseFloat(key[i..^1]))
  none(float64)

func idx(i: int): int16 {.inline.} =
  ## A point index as a key part; records hold one digit, but built ones may
  ## not (out-of-range values clamp).
  int16(clamp(i, int(low(int16)), int(high(int16))))

proc note(g: var SurveyGeometry, sev: Severity, file, msg: string, record = -1) =
  g.log.report(sev, dcBadValue, msg, loc = Location(file: file, record: record))

proc lineOf(g: var SurveyGeometry, unresolved: var HashSet[string], file, name: string,
    v: float64, rec = -1): Option[float64] =
  # `resolveLine`, with one warning per unresolved line name.
  result = g.resolveLine(name, v)
  if result.isNone and not unresolved.containsOrIncl(name):
    g.note(sevWarning, file, "line '" & name & "' is not a number and has no mapping; " &
      "its records are skipped (use a line name map)", rec)

func overlaps(runs: seq[RelationRun], run: RelationRun): bool =
  for o in runs:
    if run.fromChannel <= o.toChannel and o.fromChannel <= run.toChannel: return true

proc addRelation(g: var SurveyGeometry, file: string, i: int, r: SpsRelation, sl, rl: float64) =
  let run = RelationRun(fieldTape: r.fieldTape, fromChannel: r.fromChannel,
    toChannel: r.toChannel, step: r.channelIncrement,
    src: stationKey(sl, r.srcPoint, idx(r.srcIndex)), rcvLine: rl,
    fromRcv: r.fromReceiver, toRcv: r.toReceiver, rcvIndex: idx(r.rcvIndex))
  if r.fieldRecord in g.runs and g.runs[r.fieldRecord].overlaps(run):
    g.note(sevWarning, file, "field record " & $r.fieldRecord & ": channels " &
      $run.fromChannel & ".." & $run.toChannel & " overlap an earlier X record " &
      "(different tapes or line sequences?); the earlier one wins", i)
  g.runs.mgetOrPut(r.fieldRecord, @[]).add run

proc addSps*(g: var SurveyGeometry, f: SpsFile) =
  ## Adds the stations (R and S records) and relations (X records) of `f`.
  ## Grid coordinates are taken as they are (units of H20); z is the surface
  ## elevation. Records whose line or point cannot be made numeric are
  ## skipped, with one warning per line name.
  var unresolved: HashSet[string]
  for i, p in f.points:
    let l = g.lineOf(unresolved, f.name, p.lineName, p.line, i)
    if l.isNone: discard
    elif p.point.isNaN:
      g.note(sevInfo, f.name, "point '" & p.pointName & "' on line " & p.lineName &
        " is not a number; skipped")
    elif p.easting.isNaN or p.northing.isNaN:
      discard # no coordinates: nothing to add
    elif p.kind == pkSource:
      g.table.addSource(l.get, p.point, idx(p.index), p.easting, p.northing, p.elevation)
    else:
      g.table.addReceiver(l.get, p.point, idx(p.index), p.easting, p.northing, p.elevation)
  for i, r in f.relations:
    if g.tape.len > 0 and r.fieldTape != g.tape: discard
    elif r.fieldRecord == MissingInt or r.fromChannel == MissingInt or
        r.toChannel == MissingInt or r.channelIncrement < 1 or r.toChannel < r.fromChannel:
      g.note(sevWarning, f.name, "X record without a usable record or channel range; skipped", i)
    else:
      let sl = g.lineOf(unresolved, f.name, r.srcLineName, r.srcLine, i)
      let rl = if sl.isSome: g.lineOf(unresolved, f.name, r.rcvLineName, r.rcvLine, i)
               else: none(float64)
      if rl.isNone: discard
      elif r.srcPoint.isNaN or r.fromReceiver.isNaN or r.toReceiver.isNaN:
        g.note(sevWarning, f.name, "X record with a non-numeric point; skipped", i)
      else:
        g.addRelation(f.name, i, r, sl.get, rl.get)

proc addP1*(g: var SurveyGeometry, f: P1File, elevation = false) =
  ## Adds the shotpoints of the P1 logical files in `f` as sources. The
  ## reshoot code is the point index (blank 0 = any, `A` 2, `B` 3, ...).
  ## Columns 62-66 are z only with `elevation` (the header says whether
  ## they hold elevation or water depth); else z is unknown.
  var unresolved: HashSet[string]
  var files = 0
  for lf in f.files:
    if lf.format == pfP1:
      inc files
      for i, r in lf.records:
        let numeric = if r.lineName.len == 0: NaN else: parseFortranFloat(r.lineName).get(NaN)
        if r.lineName.len == 0 and r.point.isNaN: discard # a raw (non-P1) record
        else:
          let l = g.lineOf(unresolved, f.name, r.lineName, numeric)
          if l.isNone or r.point.isNaN or r.easting.isNaN or r.northing.isNaN: discard
          else:
            let index = if r.reshoot in {'A'..'Z'}: int16(ord(r.reshoot) - ord('A') + 2)
                        else: 0'i16
            g.table.addSource(l.get, r.point, index, r.easting, r.northing,
              if elevation: r.depthOrElevation else: NaN)
  if files > 1:
    g.note(sevInfo, f.name, $files & " P1 logical files merged; each may have its own " &
      "projection (see their headers)")

proc addLog(g: var SurveyGeometry, log: DiagLog) =
  if log.isFatal: raise newException(IOError, log[log.len - 1].msg)
  g.log.add log

proc addSps*(g: var SurveyGeometry, path: string, opts = SpsOptions()) =
  ## Reads the SPS file (Rev 1.0 or 2.1) at `path` and adds it; its
  ## diagnostics go to `g.log`. Raises `IOError` if it cannot be read.
  let f = readSps(path, opts)
  g.addLog(f.log)
  g.addSps(f)

proc addP1*(g: var SurveyGeometry, path: string, opts = P1Options(), elevation = false) =
  ## Reads the SEG P1 file at `path` (`readP1` with `opts`: the implicit
  ## decimals of the grid and depth/elevation fields, which the file's header
  ## gives, and the angle unit) and adds its shotpoints; with `elevation`,
  ## columns 62-66 are z. Raises `IOError` if the file cannot be read,
  ## `ValueError` for decimals outside 0..8.
  if opts.gridDecimals notin 0..8 or opts.depthDecimals notin 0..8:
    raise newException(ValueError, "decimals must be 0..8")
  let f = readP1(path, opts)
  g.addLog(f.log)
  g.addP1(f, elevation)

proc relation*(g: SurveyGeometry, record, channel: int64): Option[StationRelation] =
  ## The stations channel `channel` of field record `record` was recorded
  ## from, per the X records; none if no run covers it.
  if record notin g.runs: return none(StationRelation)
  for run in g.runs[record]:
    let last = if g.multiComponent: run.toChannel + run.step - 1 else: run.toChannel
    if channel >= run.fromChannel and channel <= last:
      let d = channel - run.fromChannel
      if g.multiComponent or d mod run.step == 0:
        let i = d div run.step
        let n = (run.toChannel - run.fromChannel) div run.step
        let rp = if n == 0: run.fromRcv
                 else: run.fromRcv + float64(i) * (run.toRcv - run.fromRcv) / float64(n)
        return some(StationRelation(source: run.src,
          receiver: stationKey(run.rcvLine, rp, run.rcvIndex),
          component: if g.multiComponent and run.step > 1: int(d mod run.step) + 1 else: 0))
  none(StationRelation)

proc applySurvey*(k: var TraceKeys, g: SurveyGeometry, overwrite = false): bool =
  ## Fills `k` from the survey: stations from the X relations, then
  ## coordinates, offset and midpoint. True if anything changed.
  result = false
  let found = if k.record.isNaN or k.channel.isNaN: none(StationRelation)
              else: g.relation(int64(k.record), int64(k.channel))
  if found.isSome:
    let rel = found.get
    if overwrite or k.srcLine.isNaN or k.srcPoint.isNaN:
      (k.srcLine, k.srcPoint, k.srcIndex) = (rel.source.line, rel.source.point, rel.source.index)
      result = true
    if overwrite or k.rcvLine.isNaN or k.rcvPoint.isNaN:
      (k.rcvLine, k.rcvPoint, k.rcvIndex) =
        (rel.receiver.line, rel.receiver.point, rel.receiver.index)
      result = true
    if rel.component > 0 and (overwrite or k.component == 0):
      k.component = uint8(min(rel.component, 255))
      result = true
  if k.applyGeometry(g.table, overwrite): result = true

proc applySurvey*(ix: var TraceIndex, g: SurveyGeometry, overwrite = false): int =
  ## `applySurvey` on every trace; returns the traces changed. Raises
  ## `ValueError` for an index built without `keys = true`.
  ix.requireKeys()
  ix.joined = true
  for k in ix.keys.mitems:
    if k.applySurvey(g, overwrite): inc result

proc applySurvey*(f: var SeismicFile, g: SurveyGeometry, overwrite = false): int =
  ## Fills the trace keys from the survey, in memory only: the file does not
  ## change. Returns the traces changed. Raises `ValueError` for a file opened
  ## without `keys = true`.
  f.index.applySurvey(g, overwrite)

proc applySurvey*(k: var TraceKeys, g: SurveyGeometry, fields: GeometryFields,
    overwrite = false): bool =
  ## `applySurvey`, keeping only the joined values `fields` selects (the
  ## others stay as they were). True if anything changed.
  var j = k
  if not j.applySurvey(g, overwrite): return false
  let before = k
  if fields.sourceXy: (k.srcX, k.srcY) = (j.srcX, j.srcY)
  if fields.receiverXy: (k.rcvX, k.rcvY) = (j.rcvX, j.rcvY)
  if fields.elevations: (k.srcZ, k.rcvZ) = (j.srcZ, j.rcvZ)
  if fields.midpoints: (k.cmpX, k.cmpY) = (j.cmpX, j.cmpY)
  if fields.offsets: k.offset = j.offset
  if fields.stations:
    (k.srcLine, k.srcPoint, k.srcIndex) = (j.srcLine, j.srcPoint, j.srcIndex)
    (k.rcvLine, k.rcvPoint, k.rcvIndex) = (j.rcvLine, j.rcvPoint, j.rcvIndex)
    k.component = j.component
  func same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)
  not (same(k.srcX, before.srcX) and same(k.srcY, before.srcY) and
    same(k.rcvX, before.rcvX) and same(k.rcvY, before.rcvY) and
    same(k.srcZ, before.srcZ) and same(k.rcvZ, before.rcvZ) and
    same(k.cmpX, before.cmpX) and same(k.cmpY, before.cmpY) and
    same(k.offset, before.offset) and same(k.srcLine, before.srcLine) and
    same(k.srcPoint, before.srcPoint) and same(k.rcvLine, before.rcvLine) and
    same(k.rcvPoint, before.rcvPoint) and k.srcIndex == before.srcIndex and
    k.rcvIndex == before.rcvIndex and k.component == before.component)
