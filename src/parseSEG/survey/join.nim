## Joins survey geometry (SPS, SEG P1) to seismic traces.
##
## A `SurveyGeometry` collects station coordinates (a `GeometryTable`) and
## the relations between field records and stations:
## - **X records** (source domain, `rdSource`): channels of a source's field
##   record → receivers;
## - **O records** (receiver domain, `rdReceiver`, `.ops` files): the X layout
##   with the roles swapped, traces of a receiver's gather → sources. See
##   `receiverRelations` to build them from X.
##
## **Traces are matched by their stations** (line, point, index); the record
## number is a fallback for traces whose headers carry no station.
## `joinStations` fills the stations a header lacks, and never replaces one it
## has (header stations are the truth: field record numbers and channel
## numbers often differ from the relation file's). Per trace:
##
## 1. source and receiver station in the header: nothing to fill;
## 2. source station only: the X records **of that source station** give the
##    receiver of the trace's channel (the record equal to the trace's own
##    record number when there are several; else they must agree);
## 3. receiver station only: the O gathers of that receiver station give the
##    source likewise; without O records, the X relation of the trace's
##    record and channel, only if its receiver is the header's;
## 4. no station: the relation of the trace's record and channel (X, then O).
##
## A relation is used only when it agrees with every station the header has.
## A station is known when both its line and its point are. A header with
## only one of them (e.g. a SEG-Y shotpoint without a line) has the station
## filled whole, when the relation agrees with the part the header has: the
## same value to 1/100, or the relation's as a whole number (an integer
## header field holds point 99.5 as 100; the survey's 99.5 then replaces it).
## A relation that contradicts the part (header shotpoint 2345, relation
## 13/99.5) is a conflict (`jmConflict`): nothing is filled, as for a whole
## station.
## `applySurvey` then takes coordinates from the table by station
## (`keys.applyGeometry`), then the offset and midpoint. Auxiliary traces are
## left alone. The channel → station step (2-4) assumes the recorder numbers
## channels as the relation file does; when headers carry both stations,
## channel numbers are never used.
##
## Relations are stored as runs (one per X/O record), never expanded per
## channel. `relationRuns` yields them (a channel range on evenly spaced
## stations of one line), for code that walks a record station by station
## instead of asking per channel.
##
## Line names that are not numbers (SPS 1.0, P1) go through the geometry's
## `lineNames` (a caller-supplied name → number map, see `mapLine`), then
## (with `trailingDigits`) the trailing digits of the name (`CLT4960` → 4960).

import std/[options, tables, strutils, math, sets, algorithm, os]
import ../common/diagnostics
import ../model/[keys, traceindex]
import ./[textrec, cards, sps, p1]
import ../private/checks

export keys
export sps.GridUnit, sps.known, sps.measurementSystem # `SurveyGeometry.gridUnit`

type
  RelationDomain* = enum
    ## The domain of a relation record.
    rdSource = "source"     ## X: a source's field record; channels → receivers.
    rdReceiver = "receiver" ## O: a receiver's gather; traces → sources.

  Run = object
    fieldTape: string
    fromChannel, toChannel: int64
    step: int64
    fixed: StationKey          # X: the source; O: the receiver
    line, first, last: float64 # X: receiver line and points; O: source line and points
    index: int16               # point index of `line`'s stations

  RecordRuns = object
    ## The runs of one record, in file order.
    runs: seq[Run]
    scattered: bool
      ## A run does not start after the channels of the one before it (its
      ## multi-component extent, the wider one). Lookups then scan in file
      ## order and give a channel to the first run covering it. Otherwise the
      ## runs ascend and share no channel, with or without `multiComponent`:
      ## a lookup is a binary search and nothing needs an earlier-run scan.
    channels: array[bool, int64]
      ## Channels the runs cover, without and with `multiComponent`; the
      ## record's channel count unless `scattered`.

  RelationRun* = object
    ## One run of a record's relations (an X or O record of the survey
    ## file), as `relationRuns` yields it: `stations` evenly spaced stations
    ## of one line. Station `i` (0-based) is `station(run, i)`, at point
    ## `firstPoint + i * pointStep`. Its channel (for an O record: its trace
    ## in the gather) is `fromChannel + i * channelStep`, the first of
    ## `components` consecutive channels. A record whose last channel is not
    ## a station's first ends with its last whole station, here and in every
    ## lookup.
    fromChannel*: int64 ## The channel of the first station.
    toChannel*: int64   ## The last channel of the last station.
    channelStep*: int64 ## Channels from one station to the next.
    stations*: int      ## Stations in the run.
    components*: int
      ## Channels per station: 1, or `channelStep` in a multi-component
      ## survey (`SurveyGeometry.multiComponent`).
    fixed*: StationKey  ## X: the record's source; O: the gather's receiver.
    line*: float64      ## The line of the run's stations (X: receivers; O: sources).
    firstPoint*, lastPoint*: float64 ## The points of the first and the last station.
    pointStep*: float64 ## Point increment per station: negative when descending, 0 for one.
    index*: int16       ## The point index of the run's stations.

  StationRecord = object
    index: int16
    record: int64

  SurveyGeometry* = object
    ## Station coordinates and channel relations from survey files.
    table*: GeometryTable
    runs: array[RelationDomain, Table[int64, RecordRuns]]
    byStation: array[RelationDomain, Table[StationKey, seq[StationRecord]]]
      # (line, point, index 0) of a run's fixed station → its records
    multiComponent*: bool
      ## X records with a channel increment k > 1 cover k consecutive
      ## channels per station (components 1..k, SPS 1.0 §"X" note); else
      ## only every k-th channel is in the run.
    tape*: string ## Only X records of this field tape ("" = all).
    lineNames*: Table[string, float64] ## Text line name → line number (see `mapLine`).
    gridUnit*: GridUnit
      ## The unit of the station coordinates: the first SPS file's that gives
      ## one (H20, H201); a later file with another is a warning (nothing is
      ## rescaled). Write-back records it in SEG-Y output (`measurementSystem`).
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
    ## The stations one channel of a field record (X) or one trace of a
    ## receiver gather (O) was recorded from.
    source*, receiver*: StationKey
    component*: int ## 1-based within the station (multi-component), else 0.

  JoinMatch* = enum
    ## How `joinStations` matched a trace (see the module documentation).
    jmStations = "by stations"         ## Both stations were in the header.
    jmSource = "via the source"        ## Receiver from the X records of the source station.
    jmReceiver = "via the receiver"    ## Source from the O gathers of the receiver station.
    jmRecord = "by record number"      ## Record and channel (no station, or checked by one).
    jmAmbiguous = "ambiguous"          ## The station's records disagree on the channel.
    jmConflict = "conflicting"
      ## The relation contradicts a header station, or the line or point the
      ## header has of one.
    jmUnmatched = "unmatched"          ## No relation found.
    jmAuxiliary = "auxiliary"          ## Not seismic: left alone.

  JoinStats* = object
    ## What `applySurvey` did to a file's traces.
    traces*: int                          ## Traces seen.
    changed*: int                         ## Traces whose keys changed.
    matches*: array[JoinMatch, int]       ## Traces by how they matched.
    noSourceXy*, noReceiverXy*: int
      ## Seismic traces left without source / receiver coordinates (a
      ## station missing from the survey, or no station at all).

func log*(g: SurveyGeometry): lent DiagLog {.inline.} =
  ## Problems met while adding survey files.
  g.log


func relationCount*(g: SurveyGeometry, domain = rdSource): int =
  ## The number of relation runs (X records, or O records) loaded.
  for rr in g.runs[domain].values: result += rr.runs.len

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

template noteCapped(g: var SurveyGeometry, cap: var RepeatCap, kind: string, sev: Severity,
    file, msg: string, record = -1) =
  # `note` for the first few problems of `kind` in one file (`msg` is built
  # only for those); `cap.summarize` counts the rest.
  if cap.admit(dcBadValue, kind): g.note(sev, file, msg, record)

func sameCoordinates(a, b: Coordinates): bool =
  func same(x, y: float64): bool {.inline.} = x == y or (x.isNaN and y.isNaN)
  same(a.x, b.x) and same(a.y, b.y) and same(a.z, b.z)

func stationsOf(t: var GeometryTable, kind: SpsPointKind): var Table[StationKey, Coordinates] =
  if kind == pkSource: return t.sources
  t.receivers

proc addStation(g: var SurveyGeometry, cap: var RepeatCap, kind: SpsPointKind, file: string,
    record: int, line, point: float64, index: int16, c: Coordinates) =
  # Adds or replaces a station. One given before is reported: the later
  # coordinates are used, and nothing else would say that two records name
  # one station.
  let key = stationKey(line, point, index)
  var known = false
  var same = false
  g.table.stationsOf(kind).withValue(key, held):
    known = true
    same = sameCoordinates(held[], c)
    held[] = c
  do:
    g.table.stationsOf(kind)[key] = c
  if known:
    let what = (if kind == pkSource: "source " else: "receiver ") & $key.line & "/" &
      $key.point & "/" & $key.index
    if same:
      g.noteCapped(cap, "again", sevInfo, file, what & " is given again with the same " &
        "coordinates", record)
    else:
      g.noteCapped(cap, "moved", sevWarning, file, what & " is given again with other " &
        "coordinates; the later ones are used", record)

proc lineOf(g: var SurveyGeometry, unresolved: var HashSet[string], file, name: string,
    v: float64, rec = -1): Option[float64] =
  # `resolveLine`, with one warning per unresolved line name.
  result = g.resolveLine(name, v)
  if result.isNone and not unresolved.containsOrIncl(name):
    g.note(sevWarning, file, "line '" & name & "' is not a number and has no mapping; " &
      "its records are skipped (use a line name map)", rec)

func `==`(a, b: StationRecord): bool = a.index == b.index and a.record == b.record

func anyIndex(k: StationKey): StationKey {.inline.} =
  StationKey(line: k.line, point: k.point, index: 0)

func sameStation*(a, b: StationKey): bool =
  ## Same line and point (to 1/100), and the same point index unless either
  ## is 0 (unknown: SEG-D headers often leave it 0 where survey files write 1).
  let (x, y) = (stationKey(a.line, a.point, a.index), stationKey(b.line, b.point, b.index))
  x.line == y.line and x.point == y.point and
    (x.index == 0 or y.index == 0 or x.index == y.index)

func lastChannel(run: Run, multi: bool): int64 {.inline.} =
  # The last channel of the run's last whole station: a channel range that
  # does not end on a station (`toChannel - fromChannel` not a multiple of
  # the increment) relates no channel after it.
  let last = run.fromChannel + (run.toChannel - run.fromChannel) div run.step * run.step
  if multi: last + run.step - 1 else: last

func covers(run: Run, channel: int64, multi: bool): bool {.inline.} =
  channel >= run.fromChannel and channel <= run.lastChannel(multi) and
    (multi or (channel - run.fromChannel) mod run.step == 0)

func pointAt(first, last: float64, i, n: int64): float64 {.inline.} =
  # The point of station `i` of a run of `n + 1` evenly spaced stations.
  if n == 0: first else: first + float64(i) * (last - first) / float64(n)

func at(run: Run, channel: int64, multi: bool, domain: RelationDomain): StationRelation =
  ## The relation of a channel `run` covers.
  let d = channel - run.fromChannel
  let i = d div run.step
  let n = (run.toChannel - run.fromChannel) div run.step
  let moving = stationKey(run.line, pointAt(run.first, run.last, i, n), run.index)
  result.component = if multi and run.step > 1: int(d mod run.step) + 1 else: 0
  if domain == rdSource: (result.source, result.receiver) = (run.fixed, moving)
  else: (result.source, result.receiver) = (moving, run.fixed)

func sameRelation(a, b: StationRelation): bool =
  a.source == b.source and a.receiver == b.receiver and a.component == b.component

func overlaps(runs: seq[Run], run: Run): bool =
  for o in runs:
    if run.fromChannel <= o.toChannel and o.fromChannel <= run.toChannel: return true

func find(rr: RecordRuns, channel: int64, multi: bool): int =
  # The run that has `channel`: the first in file order covering it; -1 if
  # none does.
  result = -1
  if rr.scattered:
    for j, run in rr.runs:
      if run.covers(channel, multi): return j
  else:
    # Ascending and disjoint: only the last run starting at or before the
    # channel can cover it.
    var (lo, hi) = (0, rr.runs.len)
    while lo < hi:
      let mid = (lo + hi) shr 1
      if rr.runs[mid].fromChannel <= channel: lo = mid + 1 else: hi = mid
    if lo > 0 and rr.runs[lo - 1].covers(channel, multi): result = lo - 1

func owns(rr: RecordRuns, j: int, channel: int64, multi: bool): bool {.inline.} =
  # Run `j` covers `channel`, and no earlier run does.
  if not rr.runs[j].covers(channel, multi): return false
  if rr.scattered:
    for o in 0 ..< j:
      if rr.runs[o].covers(channel, multi): return false
  true

proc add(rr: var RecordRuns, run: sink Run): bool =
  # Appends a run; true when it overlaps an earlier one. Whether the runs
  # still ascend without sharing a channel is noted here, once, so that
  # lookups need not find out per channel: a record of thousands of X rows
  # was scanned from its first row for every channel.
  result = false
  if rr.runs.len > 0 and (rr.scattered or
      run.fromChannel <= rr.runs[^1].lastChannel(multi = true)):
    rr.scattered = true
    result = rr.runs.overlaps(run)
  let stations = (run.toChannel - run.fromChannel) div run.step + 1
  rr.channels[false] += stations
  rr.channels[true] += stations * run.step
  rr.runs.add run

proc addRelation(g: var SurveyGeometry, domain: RelationDomain, file: string, i: int,
    r: SpsRelation, fixedLine, line: float64) =
  # In both domains the record's source columns hold the fixed station and
  # its receiver columns the run of moving stations.
  let fixed = stationKey(fixedLine, r.srcPoint, idx(r.srcIndex))
  if g.runs[domain].mgetOrPut(r.fieldRecord, RecordRuns()).add Run(fieldTape: r.fieldTape,
      fromChannel: r.fromChannel, toChannel: r.toChannel, step: r.channelIncrement,
      fixed: fixed, line: line, first: r.fromReceiver, last: r.toReceiver,
      index: idx(r.rcvIndex)):
    g.note(sevWarning, file, (if domain == rdSource: "field record " else: "gather ") &
      $r.fieldRecord & ": channels " & $r.fromChannel & ".." & $r.toChannel &
      " overlap an earlier record (different tapes or line sequences?); the earlier one wins", i)
  let entry = StationRecord(index: fixed.index, record: r.fieldRecord)
  let key = fixed.anyIndex
  if key notin g.byStation[domain] or entry notin g.byStation[domain][key]:
    g.byStation[domain].mgetOrPut(key, @[]).add entry

func relationDomainOf*(path: string): RelationDomain =
  ## The domain of the X-type records of a file, by its name: `rdReceiver`
  ## for an `.ops` file (any case), else `rdSource`.
  if path.splitFile.ext.toLowerAscii == ".ops": rdReceiver else: rdSource

proc addSps*(g: var SurveyGeometry, f: SpsFile, xDomain = rdSource) =
  ## Adds the stations (R and S records) and relations of `f`. `O` records
  ## are receiver-domain relations; `X` records are of `xDomain` (pass
  ## `rdReceiver` for an O file written with `X` records, e.g. `.ops`).
  ## Grid coordinates are taken as they are (units of H20); z is the surface
  ## elevation. Records whose line or point cannot be made numeric are
  ## skipped, with one warning per line name. A station given before (in
  ## this file or an earlier one) is replaced and reported: a warning when
  ## its coordinates differ, an info when they are the same. `g.log` gets
  ## the first few reports of each kind per file, then a count.
  var unresolved: HashSet[string]
  var cap: RepeatCap
  for i, p in f.points:
    let l = g.lineOf(unresolved, f.name, p.lineName, p.line, i)
    if l.isNone: discard
    elif p.point.isNaN:
      g.noteCapped(cap, "point", sevInfo, f.name, "point '" & p.pointName & "' on line " &
        p.lineName & " is not a number; skipped", i)
    elif p.easting.isNaN or p.northing.isNaN:
      discard # no coordinates: nothing to add
    else:
      g.addStation(cap, p.kind, f.name, i, l.get, p.point, idx(p.index),
        Coordinates(x: p.easting, y: p.northing, z: p.elevation))
  for i, r in f.relations:
    let domain = if r.recordType == 'O': rdReceiver else: xDomain
    if g.tape.len > 0 and r.fieldTape != g.tape: discard
    elif r.fieldRecord == MissingInt or r.fromChannel == MissingInt or
        r.toChannel == MissingInt or r.channelIncrement < 1 or r.toChannel < r.fromChannel:
      g.noteCapped(cap, "range", sevWarning, f.name, r.recordType &
        " record without a usable record or channel range; skipped", i)
    else:
      let sl = g.lineOf(unresolved, f.name, r.srcLineName, r.srcLine, i)
      let rl = if sl.isSome: g.lineOf(unresolved, f.name, r.rcvLineName, r.rcvLine, i)
               else: none(float64)
      if rl.isNone: discard
      elif r.srcPoint.isNaN or r.fromReceiver.isNaN or r.toReceiver.isNaN:
        g.noteCapped(cap, "relpoint", sevWarning, f.name, r.recordType &
          " record with a non-numeric point; skipped", i)
      else:
        let partial = (r.toChannel - r.fromChannel) mod r.channelIncrement
        if partial != 0:
          g.noteCapped(cap, "partial", sevWarning, f.name, r.recordType & " record " &
            $r.fieldRecord & ": channel " & $r.toChannel & " is not the first of a " &
            "station (channels from " & $r.fromChannel & " by " & $r.channelIncrement &
            "); the run's last station starts at channel " & $(r.toChannel - partial), i)
        g.addRelation(domain, f.name, i, r, sl.get, rl.get)
  let u = f.gridUnit
  if u.known:
    if not g.gridUnit.known:
      g.gridUnit = u
    elif u.measurementSystem != g.gridUnit.measurementSystem or
        abs(u.metres - g.gridUnit.metres) > 1e-9 * g.gridUnit.metres:
      g.note(sevWarning, f.name, "grid units '" & u.name & "' (" & $u.metres &
        " m) differ from the survey's '" & g.gridUnit.name & "' (" & $g.gridUnit.metres &
        " m); the coordinates are taken as they are", -1)
  cap.summarize(g.log, f.name)

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

proc addSps*(g: var SurveyGeometry, path: string, opts = SpsOptions(),
    xDomain = relationDomainOf(path)) =
  ## Reads the SPS file (Rev 1.0 or 2.1) at `path` and adds it; its
  ## diagnostics go to `g.log`. `X` records of an `.ops` file are receiver
  ## domain (O) by default. Raises `IOError` if it cannot be read. The
  ## records are read without their text (`SpsOptions.keepRaw` is not used:
  ## nothing is written back from here).
  var o = opts
  o.keepRaw = false
  let f = readSps(path, o)
  g.addLog(f.log)
  g.addSps(f, xDomain)

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

proc relation*(g: SurveyGeometry, record, channel: int64,
    domain = rdSource): Option[StationRelation] =
  ## The stations channel `channel` of field record `record` (X, `rdSource`)
  ## or trace `channel` of gather `record` (O, `rdReceiver`) was recorded
  ## from; none if no run covers it. A binary search of the record's runs
  ## when they ascend without overlap (`relationsDisjoint`), else a scan in
  ## file order (the first run covering the channel has it).
  if record notin g.runs[domain]: return none(StationRelation)
  let rr = addr g.runs[domain][record]
  let j = rr[].find(channel, g.multiComponent)
  if j < 0: none(StationRelation)
  else: some(rr.runs[j].at(channel, g.multiComponent, domain))

iterator records*(g: SurveyGeometry, domain = rdSource): int64 =
  ## The field records (X) or gathers (O) that have relations, ascending.
  var all = newSeqOfCap[int64](g.runs[domain].len)
  for r in g.runs[domain].keys: all.add r
  all.sort
  for r in all: yield r

iterator relations*(g: SurveyGeometry, record: int64,
    domain = rdSource): tuple[channel: int64, relation: StationRelation] =
  ## Every channel of `record` with its stations, run by run in file order;
  ## a channel two runs cover is yielded once, for the earlier run (as
  ## `relation` does). `relationRuns` gives the same run by run, without
  ## the per-channel work.
  if record in g.runs[domain]:
    let rr = addr g.runs[domain][record]
    let multi = g.multiComponent
    for j in 0 ..< rr.runs.len:
      var c = rr.runs[j].fromChannel
      while c <= rr.runs[j].lastChannel(multi):
        if rr[].owns(j, c, multi): yield (c, rr.runs[j].at(c, multi, domain))
        inc c

func relationsDisjoint*(g: SurveyGeometry, record: int64, domain = rdSource): bool =
  ## Whether the runs of `record` ascend by channel and no two share one
  ## (also true for a record without relations). Then `relationRuns` gives
  ## every channel of the record exactly once; otherwise some of its runs
  ## overlap or are out of order, and only `relations` and `relation` say
  ## which run a shared channel belongs to (the earlier one).
  record notin g.runs[domain] or not g.runs[domain][record].scattered

func station*(run: RelationRun, i: int): StationKey =
  ## Station `i` (0-based, below `run.stations`) of the run: exactly the
  ## station `relations` gives for its channels (line and point rounded as
  ## `stationKey` does).
  stationKey(run.line, pointAt(run.firstPoint, run.lastPoint, int64(i),
    int64(run.stations - 1)), run.index)

iterator relationRuns*(g: SurveyGeometry, record: int64, domain = rdSource): RelationRun =
  ## The relation runs of field record `record` (X, `rdSource`) or gather
  ## `record` (O, `rdReceiver`), in file order; nothing for a record without
  ## relations. One run is one X or O record of the survey file: a range of
  ## channels on evenly spaced stations of one line (see `RelationRun`), so
  ## a consumer can walk a record station by station along each line (fold,
  ## patch description, completeness) instead of asking per channel.
  ##
  ## Runs are yielded as the file gives them. When `relationsDisjoint` is
  ## false for the record, two runs may cover the same channel; use
  ## `relations` for such a record if that matters.
  if record in g.runs[domain]:
    let rr = addr g.runs[domain][record]
    let multi = g.multiComponent
    for j in 0 ..< rr.runs.len:
      template run: untyped = rr.runs[j]
      let n = (run.toChannel - run.fromChannel) div run.step
      let components = if multi: run.step else: 1'i64
      yield RelationRun(fromChannel: run.fromChannel,
        toChannel: run.fromChannel + n * run.step + components - 1,
        channelStep: run.step, stations: int(n) + 1, components: int(components),
        fixed: run.fixed, line: run.line,
        firstPoint: run.first, lastPoint: run.last,
        pointStep: (if n == 0: 0.0 else: (run.last - run.first) / float64(n)),
        index: run.index)

proc expectedChannels*(g: SurveyGeometry, record: int64, domain = rdSource): int =
  ## The number of channels (X) or traces (O) `record` has relations for.
  if record in g.runs[domain]:
    let rr = addr g.runs[domain][record]
    if rr.scattered:
      for _ in g.relations(record, domain): inc result
    else:
      result = int(rr.channels[g.multiComponent])

proc recordsAt*(g: SurveyGeometry, station: StationKey, domain = rdSource): seq[int64] =
  ## The field records of a source station (X, `rdSource`) or the gathers of
  ## a receiver station (O, `rdReceiver`), ascending: several for repeated or
  ## reshot points. Index 0 on either side matches any index.
  let key = stationKey(station.line, station.point, 0)
  if key in g.byStation[domain]:
    for e in g.byStation[domain][key]:
      if station.index == 0 or e.index == 0 or e.index == station.index:
        if e.record notin result: result.add e.record
  result.sort

proc channelOf*(g: SurveyGeometry, record: int64, station: StationKey,
    domain = rdSource): Option[int64] =
  ## The channel of field record `record` recorded at receiver `station`
  ## (X), or the trace of gather `record` from source `station` (O); the
  ## first component's channel for multi-component runs. None if the record
  ## does not list the station.
  if record notin g.runs[domain]: return none(int64)
  let st = stationKey(station.line, station.point, station.index)
  for run in g.runs[domain][record].runs:
    if run.line == st.line and (st.index == 0 or run.index == 0 or st.index == run.index):
      let n = (run.toChannel - run.fromChannel) div run.step
      let i = if n == 0: 0'i64
              elif run.last == run.first: -1'i64
              else: int64(round((st.point - run.first) / (run.last - run.first) * float64(n)))
      if i in 0'i64 .. n:
        let p = if n == 0: run.first
                else: run.first + float64(i) * (run.last - run.first) / float64(n)
        if stationKey(run.line, p, run.index).point == st.point:
          let c = run.fromChannel + i * run.step
          let won = g.relation(record, c, domain) # an earlier run may cover `c`
          if won.isSome and sameRelation(won.get, run.at(c, g.multiComponent, domain)):
            return some(c)
  none(int64)

type ViaStation = enum vsNone, vsFound, vsAmbiguous

proc viaStation(g: SurveyGeometry, domain: RelationDomain, station: StationKey,
    record: float64, channel: int64, rel: var StationRelation): ViaStation =
  ## The relation of `channel` in the records of `station`: the record equal
  ## to the trace's record number when it is one of them, else the one
  ## relation all of them agree on.
  let recs = g.recordsAt(station, domain)
  if recs.len == 0: return vsNone
  if not record.isNaN and int64(record) in recs:
    let r = g.relation(int64(record), channel, domain)
    if r.isNone: return vsNone
    rel = r.get
    return vsFound
  result = vsNone
  for rec in recs:
    let r = g.relation(rec, channel, domain)
    if r.isSome:
      if result == vsNone:
        rel = r.get
        result = vsFound
      elif not sameRelation(rel, r.get): return vsAmbiguous

func partAgrees(header, relation: float64): bool {.inline.} =
  # A line or point the header has agrees with the relation's when it is the
  # same to 1/100 (`stationKey`) or the relation's as a whole number: an
  # integer field (the SEG-Y energy source point) holds 99.5 as 100.
  header.isNaN or round(header * 100) == round(relation * 100) or header == round(relation)

func contradicts(line, point: float64, index: int16, st: StationKey): bool =
  # The parts the header has of a station it does not know whole (a line or
  # a point, a point index other than 0) against the relation's station.
  not (partAgrees(line, st.line) and partAgrees(point, st.point) and
    (index == 0 or st.index == 0 or index == st.index))

proc joinStations*(k: var TraceKeys, g: SurveyGeometry): JoinMatch =
  ## Fills the source and receiver stations (line, point, index) and the
  ## component a trace's header lacks, from the relations, by the rules in
  ## the module documentation. Stations the header has are never changed; a
  ## relation that contradicts the line or the point a header has of a
  ## station is a conflict and fills nothing. Auxiliary traces are left
  ## alone.
  if k.status == tsAuxiliary: return jmAuxiliary
  let hasSrc = not (k.srcLine.isNaN or k.srcPoint.isNaN)
  let hasRcv = not (k.rcvLine.isNaN or k.rcvPoint.isNaN)
  if hasSrc and hasRcv: return jmStations
  if k.channel.isNaN: return jmUnmatched
  let channel = int64(k.channel)
  var rel: StationRelation
  if hasSrc:
    case g.viaStation(rdSource, stationKey(k.srcLine, k.srcPoint, k.srcIndex), k.record,
        channel, rel)
    of vsNone: return jmUnmatched
    of vsAmbiguous: return jmAmbiguous
    of vsFound: result = jmSource
  elif hasRcv:
    let st = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
    case g.viaStation(rdReceiver, st, k.record, channel, rel)
    of vsAmbiguous: return jmAmbiguous
    of vsFound: result = jmReceiver
    of vsNone:
      let r = if k.record.isNaN: none(StationRelation)
              else: g.relation(int64(k.record), channel)
      if r.isNone: return jmUnmatched
      if not sameStation(r.get.receiver, st): return jmConflict
      rel = r.get
      result = jmRecord
  else:
    if k.record.isNaN: return jmUnmatched
    var r = g.relation(int64(k.record), channel)
    if r.isNone: r = g.relation(int64(k.record), channel, rdReceiver)
    if r.isNone: return jmUnmatched
    rel = r.get
    result = jmRecord
  if (not hasSrc and contradicts(k.srcLine, k.srcPoint, k.srcIndex, rel.source)) or
      (not hasRcv and contradicts(k.rcvLine, k.rcvPoint, k.rcvIndex, rel.receiver)):
    return jmConflict
  if not hasSrc:
    (k.srcLine, k.srcPoint, k.srcIndex) = (rel.source.line, rel.source.point, rel.source.index)
  if not hasRcv:
    (k.rcvLine, k.rcvPoint, k.rcvIndex) =
      (rel.receiver.line, rel.receiver.point, rel.receiver.index)
  if rel.component > 0 and k.component == 0:
    k.component = uint8(min(rel.component, 255))

proc join(k: var TraceKeys, g: SurveyGeometry, overwrite: bool,
    match: var JoinMatch): set[JoinGroup] =
  # `applySurvey` on one trace: how it matched, and the groups of values
  # that are not what they were (none for a trace that already holds the
  # survey's values, also with `overwrite`).
  let before = k
  match = k.joinStations(g)
  if match != jmAuxiliary: discard k.applyGeometry(g.table, overwrite)
  changedGroups(before, k)

proc applySurvey*(k: var TraceKeys, g: SurveyGeometry, overwrite = false): bool =
  ## Fills `k` from the survey: the stations its header lacks
  ## (`joinStations`), then coordinates by station, offset and midpoint.
  ## `overwrite` replaces known coordinates, offset and midpoint; header
  ## stations are never replaced. True if a value changed (false for a trace
  ## that already holds the survey's values).
  var match: JoinMatch
  k.join(g, overwrite, match) != {}

proc applySurvey*(ix: var TraceIndex, g: SurveyGeometry, stats: var JoinStats,
    overwrite = false): int =
  ## `applySurvey` on every trace; returns the traces changed, and how they
  ## matched in `stats`. A join that changes no trace leaves the index as it
  ## was (`keysRevision`, `joined`). Raises `ValueError` for an index built
  ## without `keys = true`.
  ix.requireKeys()
  stats = JoinStats(traces: ix.keys.len)
  for i, k in ix.keys.mpairs:
    var match: JoinMatch
    let groups = k.join(g, overwrite, match)
    if groups != {}:
      inc result
      ix.markJoined(i, groups)
    inc stats.matches[match]
    if match != jmAuxiliary:
      if not k.hasSourceXY: inc stats.noSourceXy
      if not k.hasReceiverXY: inc stats.noReceiverXy
  stats.changed = result
  if result > 0:
    ix.joined = true # only now: an index no join changed is still the file's own
    inc ix.keysRevision

proc applySurvey*(ix: var TraceIndex, g: SurveyGeometry, overwrite = false): int =
  ## `applySurvey` on every trace; returns the traces changed. Raises
  ## `ValueError` for an index built without `keys = true`.
  var stats: JoinStats
  ix.applySurvey(g, stats, overwrite)

proc applySurvey*(f: var SeismicFile, g: SurveyGeometry, stats: var JoinStats,
    overwrite = false): int =
  ## Fills the trace keys from the survey, in memory only: the file does not
  ## change. Returns the traces changed, and how they matched in `stats`.
  ## Raises `ValueError` for a file opened without `keys = true`.
  f.mindex.applySurvey(g, stats, overwrite)

proc applySurvey*(f: var SeismicFile, g: SurveyGeometry, overwrite = false): int =
  ## Fills the trace keys from the survey, in memory only: the file does not
  ## change. Returns the traces changed. Raises `ValueError` for a file opened
  ## without `keys = true`.
  f.mindex.applySurvey(g, overwrite)

func `$`*(s: JoinStats): string =
  ## One line: traces, changed, the matches that occurred, missing coordinates.
  result = $s.traces & " traces, " & $s.changed & " changed"
  for m in JoinMatch:
    if s.matches[m] > 0: result.add "; " & $m & " " & $s.matches[m]
  if s.noSourceXy > 0: result.add "; " & $s.noSourceXy & " without source X/Y"
  if s.noReceiverXy > 0: result.add "; " & $s.noReceiverXy & " without receiver X/Y"

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
  changedGroups(before, k) != {}

# ------------------------------------------------------- receiver domain ---

type SourceAt = object
  line, point: float64
  index: int16

func `<`(a, b: SourceAt): bool =
  if a.line != b.line: a.line < b.line
  elif a.point != b.point: a.point < b.point
  else: a.index < b.index

func stationLess(a, b: StationKey): int =
  if a.line != b.line: cmp(a.line, b.line)
  elif a.point != b.point: cmp(a.point, b.point)
  else: cmp(a.index, b.index)

proc receiverRelations*(g: SurveyGeometry, firstGather = 1'i64,
    recordType = 'O'): seq[SpsRelation] =
  ## The receiver-domain (O) records of the X relations: one gather per
  ## receiver station, numbered from `firstGather` in receiver line, point
  ## order; its traces 1..n are the sources that recorded it, by source
  ## line and point, as runs along source lines; a repeated source point
  ## (one X record per repeat) is one more trace, after the first ones, so
  ## each X pair appears once. Components are not
  ## represented (one trace per source and receiver station). Write them with
  ## `writeSps` (records start with `recordType`: `O`, or `X` for software
  ## that expects X records in `.ops` files; `addSps(..., xDomain =
  ## rdReceiver)` reads those back). Works one
  ## receiver line at a time, so memory follows the largest line, not the
  ## survey. Raises `ValueError` for a `recordType` other than `X` or `O`.
  if recordType notin {'X', 'O'}:
    raise newException(ValueError, "record type must be 'X' or 'O'")
  let multi = g.multiComponent
  # X runs by receiver line: (record, run).
  var byLine: Table[float64, seq[(int64, int)]]
  for rec, rr in g.runs[rdSource]:
    for j, run in rr.runs: byLine.mgetOrPut(run.line, @[]).add (rec, j)
  var lines = newSeqOfCap[float64](byLine.len)
  for l in byLine.keys: lines.add l
  lines.sort
  var gather = firstGather
  for line in lines:
    var at: Table[StationKey, seq[SourceAt]]
    for (rec, j) in byLine[line]:
      # By address: a copy of the record's runs per run was most of the time.
      let rr = addr g.runs[rdSource][rec]
      var c = rr.runs[j].fromChannel
      while c <= rr.runs[j].lastChannel(multi):
        if rr[].owns(j, c, multi):
          let rel = rr.runs[j].at(c, multi, rdSource)
          if rel.component <= 1:
            at.mgetOrPut(rel.receiver, @[]).add SourceAt(line: rel.source.line,
              point: rel.source.point, index: rel.source.index)
        inc c
    var stations = newSeqOfCap[StationKey](at.len)
    for k in at.keys: stations.add k
    stations.sort(stationLess)
    for st in stations:
      var srcs = at[st]
      srcs.sort(proc (a, b: SourceAt): int = (if a < b: -1 elif b < a: 1 else: 0))
      # Each source's first occurrence, then its repeats (pass by pass), so a
      # repeated shot does not cut its line's run in two.
      var passes: seq[SourceAt]
      var rest = srcs
      while rest.len > 0:
        var later: seq[SourceAt]
        for j, a in rest:
          if j > 0 and not (rest[j - 1] < a): later.add a
          else: passes.add a
        rest = later
      srcs = passes
      var trace = 1'i64
      var i = 0
      while i < srcs.len:
        var j = i
        if i + 1 < srcs.len and srcs[i + 1].line == srcs[i].line and
            srcs[i + 1].index == srcs[i].index and srcs[i + 1].point > srcs[i].point:
          let step = srcs[i + 1].point - srcs[i].point
          j = i + 1
          while j + 1 < srcs.len and srcs[j + 1].line == srcs[i].line and
              srcs[j + 1].index == srcs[i].index and
              abs(srcs[j + 1].point - srcs[j].point - step) < 0.005:
            inc j
        var r = initSpsRelation()
        r.recordType = recordType
        r.fieldRecord = gather
        (r.srcLine, r.srcPoint, r.srcIndex) = (st.line, st.point, int(st.index))
        r.fromChannel = trace
        r.toChannel = trace + int64(j - i)
        r.channelIncrement = 1
        (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) =
          (srcs[i].line, srcs[i].point, srcs[j].point, int(srcs[i].index))
        result.add r
        trace += int64(j - i + 1)
        i = j + 1
      inc gather
