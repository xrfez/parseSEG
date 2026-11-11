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
## A station is known when both its line and its point are; a header with
## only one of them (e.g. a SEG-Y shotpoint without a line) has it filled
## whole.
## `applySurvey` then takes coordinates from the table by station
## (`keys.applyGeometry`), then the offset and midpoint. Auxiliary traces are
## left alone. The channel → station step (2-4) assumes the recorder numbers
## channels as the relation file does; when headers carry both stations,
## channel numbers are never used.
##
## Relations are stored as runs (one per X/O record), never expanded per
## channel.
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

type
  RelationDomain* = enum
    ## The domain of a relation record.
    rdSource = "source"     ## X: a source's field record; channels → receivers.
    rdReceiver = "receiver" ## O: a receiver's gather; traces → sources.

  RelationRun = object
    fieldTape: string
    fromChannel, toChannel: int64
    step: int64
    fixed: StationKey          # X: the source; O: the receiver
    line, first, last: float64 # X: receiver line and points; O: source line and points
    index: int16               # point index of `line`'s stations

  StationRecord = object
    index: int16
    record: int64

  SurveyGeometry* = object
    ## Station coordinates and channel relations from survey files.
    table*: GeometryTable
    runs: array[RelationDomain, Table[int64, seq[RelationRun]]]
    byStation: array[RelationDomain, Table[StationKey, seq[StationRecord]]]
      # (line, point, index 0) of a run's fixed station → its records
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
    jmConflict = "conflicting"         ## The record's relation contradicts a header station.
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
  for runs in g.runs[domain].values: result += runs.len

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

func `==`(a, b: StationRecord): bool = a.index == b.index and a.record == b.record

func anyIndex(k: StationKey): StationKey {.inline.} =
  StationKey(line: k.line, point: k.point, index: 0)

func sameStation*(a, b: StationKey): bool =
  ## Same line and point (to 1/100), and the same point index unless either
  ## is 0 (unknown: SEG-D headers often leave it 0 where survey files write 1).
  let (x, y) = (stationKey(a.line, a.point, a.index), stationKey(b.line, b.point, b.index))
  x.line == y.line and x.point == y.point and
    (x.index == 0 or y.index == 0 or x.index == y.index)

func lastChannel(run: RelationRun, multi: bool): int64 {.inline.} =
  if multi: run.toChannel + run.step - 1 else: run.toChannel

func covers(run: RelationRun, channel: int64, multi: bool): bool {.inline.} =
  channel >= run.fromChannel and channel <= run.lastChannel(multi) and
    (multi or (channel - run.fromChannel) mod run.step == 0)

func at(run: RelationRun, channel: int64, multi: bool, domain: RelationDomain): StationRelation =
  ## The relation of a channel `run` covers.
  let d = channel - run.fromChannel
  let i = d div run.step
  let n = (run.toChannel - run.fromChannel) div run.step
  let p = if n == 0: run.first
          else: run.first + float64(i) * (run.last - run.first) / float64(n)
  let moving = stationKey(run.line, p, run.index)
  result.component = if multi and run.step > 1: int(d mod run.step) + 1 else: 0
  if domain == rdSource: (result.source, result.receiver) = (run.fixed, moving)
  else: (result.source, result.receiver) = (moving, run.fixed)

func sameRelation(a, b: StationRelation): bool =
  a.source == b.source and a.receiver == b.receiver and a.component == b.component

func overlaps(runs: seq[RelationRun], run: RelationRun): bool =
  for o in runs:
    if run.fromChannel <= o.toChannel and o.fromChannel <= run.toChannel: return true

proc addRelation(g: var SurveyGeometry, domain: RelationDomain, file: string, i: int,
    r: SpsRelation, fixedLine, line: float64) =
  # In both domains the record's source columns hold the fixed station and
  # its receiver columns the run of moving stations.
  let run = RelationRun(fieldTape: r.fieldTape, fromChannel: r.fromChannel,
    toChannel: r.toChannel, step: r.channelIncrement,
    fixed: stationKey(fixedLine, r.srcPoint, idx(r.srcIndex)), line: line,
    first: r.fromReceiver, last: r.toReceiver, index: idx(r.rcvIndex))
  if r.fieldRecord in g.runs[domain] and g.runs[domain][r.fieldRecord].overlaps(run):
    g.note(sevWarning, file, (if domain == rdSource: "field record " else: "gather ") &
      $r.fieldRecord & ": channels " & $run.fromChannel & ".." & $run.toChannel &
      " overlap an earlier record (different tapes or line sequences?); the earlier one wins", i)
  g.runs[domain].mgetOrPut(r.fieldRecord, @[]).add run
  let entry = StationRecord(index: run.fixed.index, record: r.fieldRecord)
  let key = run.fixed.anyIndex
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
    let domain = if r.recordType == 'O': rdReceiver else: xDomain
    if g.tape.len > 0 and r.fieldTape != g.tape: discard
    elif r.fieldRecord == MissingInt or r.fromChannel == MissingInt or
        r.toChannel == MissingInt or r.channelIncrement < 1 or r.toChannel < r.fromChannel:
      g.note(sevWarning, f.name, r.recordType & " record without a usable record or channel " &
        "range; skipped", i)
    else:
      let sl = g.lineOf(unresolved, f.name, r.srcLineName, r.srcLine, i)
      let rl = if sl.isSome: g.lineOf(unresolved, f.name, r.rcvLineName, r.rcvLine, i)
               else: none(float64)
      if rl.isNone: discard
      elif r.srcPoint.isNaN or r.fromReceiver.isNaN or r.toReceiver.isNaN:
        g.note(sevWarning, f.name, r.recordType & " record with a non-numeric point; skipped", i)
      else:
        g.addRelation(domain, f.name, i, r, sl.get, rl.get)

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
  ## domain (O) by default. Raises `IOError` if it cannot be read.
  let f = readSps(path, opts)
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
  ## from; none if no run covers it.
  if record notin g.runs[domain]: return none(StationRelation)
  for run in g.runs[domain][record]:
    if run.covers(channel, g.multiComponent):
      return some(run.at(channel, g.multiComponent, domain))
  none(StationRelation)

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
  ## `relation` does).
  if record in g.runs[domain]:
    let runs = g.runs[domain][record]
    let multi = g.multiComponent
    for j, run in runs:
      var c = run.fromChannel
      while c <= run.lastChannel(multi):
        if run.covers(c, multi):
          var earlier = false
          for o in 0 ..< j:
            if runs[o].covers(c, multi):
              earlier = true
              break
          if not earlier: yield (c, run.at(c, multi, domain))
        inc c

proc expectedChannels*(g: SurveyGeometry, record: int64, domain = rdSource): int =
  ## The number of channels (X) or traces (O) `record` has relations for.
  for _ in g.relations(record, domain): inc result

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
  for run in g.runs[domain][record]:
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

proc joinStations*(k: var TraceKeys, g: SurveyGeometry): JoinMatch =
  ## Fills the source and receiver stations (line, point, index) and the
  ## component a trace's header lacks, from the relations, by the rules in
  ## the module documentation. Stations the header has are never changed.
  ## Auxiliary traces are left alone.
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
  if not hasSrc:
    (k.srcLine, k.srcPoint, k.srcIndex) = (rel.source.line, rel.source.point, rel.source.index)
  if not hasRcv:
    (k.rcvLine, k.rcvPoint, k.rcvIndex) =
      (rel.receiver.line, rel.receiver.point, rel.receiver.index)
  if rel.component > 0 and k.component == 0:
    k.component = uint8(min(rel.component, 255))

func coordinatesDiffer(a, b: TraceKeys): bool =
  func same(x, y: float64): bool = x == y or (x.isNaN and y.isNaN)
  not (same(a.srcX, b.srcX) and same(a.srcY, b.srcY) and same(a.srcZ, b.srcZ) and
    same(a.rcvX, b.rcvX) and same(a.rcvY, b.rcvY) and same(a.rcvZ, b.rcvZ) and
    same(a.offset, b.offset) and same(a.cmpX, b.cmpX) and same(a.cmpY, b.cmpY))

func stationsDiffer(a, b: TraceKeys): bool =
  func same(x, y: float64): bool = x == y or (x.isNaN and y.isNaN)
  not (same(a.srcLine, b.srcLine) and same(a.srcPoint, b.srcPoint) and
    same(a.rcvLine, b.rcvLine) and same(a.rcvPoint, b.rcvPoint) and
    a.srcIndex == b.srcIndex and a.rcvIndex == b.rcvIndex and a.component == b.component)

proc join(k: var TraceKeys, g: SurveyGeometry, overwrite: bool, match: var JoinMatch): bool =
  let before = k
  match = k.joinStations(g)
  result = stationsDiffer(before, k)
  if match != jmAuxiliary and k.applyGeometry(g.table, overwrite): result = true

proc applySurvey*(k: var TraceKeys, g: SurveyGeometry, overwrite = false): bool =
  ## Fills `k` from the survey: the stations its header lacks
  ## (`joinStations`), then coordinates by station, offset and midpoint.
  ## `overwrite` replaces known coordinates, offset and midpoint; header
  ## stations are never replaced. True if anything changed.
  var match: JoinMatch
  k.join(g, overwrite, match)

proc applySurvey*(ix: var TraceIndex, g: SurveyGeometry, stats: var JoinStats,
    overwrite = false): int =
  ## `applySurvey` on every trace; returns the traces changed, and how they
  ## matched in `stats`. Raises `ValueError` for an index built without
  ## `keys = true`.
  ix.requireKeys()
  ix.joined = true
  stats = JoinStats(traces: ix.keys.len)
  for i, k in ix.keys.mpairs:
    let before = k
    var match: JoinMatch
    if k.join(g, overwrite, match):
      inc result
      var groups: set[JoinGroup]
      if coordinatesDiffer(before, k): groups.incl jgCoordinates
      if stationsDiffer(before, k): groups.incl jgStations
      ix.markJoined(i, groups)
    inc stats.matches[match]
    if match != jmAuxiliary:
      if not k.hasSourceXY: inc stats.noSourceXy
      if not k.hasReceiverXY: inc stats.noReceiverXy
  stats.changed = result
  if result > 0: inc ix.keysRevision

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
  f.index.applySurvey(g, stats, overwrite)

proc applySurvey*(f: var SeismicFile, g: SurveyGeometry, overwrite = false): int =
  ## Fills the trace keys from the survey, in memory only: the file does not
  ## change. Returns the traces changed. Raises `ValueError` for a file opened
  ## without `keys = true`.
  f.index.applySurvey(g, overwrite)

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
  func same(a, b: float64): bool = a == b or (a.isNaN and b.isNaN)
  not (same(k.srcX, before.srcX) and same(k.srcY, before.srcY) and
    same(k.rcvX, before.rcvX) and same(k.rcvY, before.rcvY) and
    same(k.srcZ, before.srcZ) and same(k.rcvZ, before.rcvZ) and
    same(k.cmpX, before.cmpX) and same(k.cmpY, before.cmpY) and
    same(k.offset, before.offset) and same(k.srcLine, before.srcLine) and
    same(k.srcPoint, before.srcPoint) and same(k.rcvLine, before.rcvLine) and
    same(k.rcvPoint, before.rcvPoint) and k.srcIndex == before.srcIndex and
    k.rcvIndex == before.rcvIndex and k.component == before.component)

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
  for rec, runs in g.runs[rdSource]:
    for j, run in runs: byLine.mgetOrPut(run.line, @[]).add (rec, j)
  var lines = newSeqOfCap[float64](byLine.len)
  for l in byLine.keys: lines.add l
  lines.sort
  var gather = firstGather
  for line in lines:
    var at: Table[StationKey, seq[SourceAt]]
    for (rec, j) in byLine[line]:
      let runs = g.runs[rdSource][rec]
      let run = runs[j]
      var c = run.fromChannel
      while c <= run.lastChannel(multi):
        if run.covers(c, multi):
          var earlier = false
          for o in 0 ..< j:
            if runs[o].covers(c, multi):
              earlier = true
              break
          let rel = run.at(c, multi, rdSource)
          if not earlier and rel.component <= 1:
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
