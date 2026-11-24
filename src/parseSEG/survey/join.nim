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
## (`keys.applyGeometry`), then the offset and midpoint. A receiver row keeps
## its SPS point code: several codes at one station are matched by
## `sensorClass` (one row is taken as stored; `KL` and `PM` still replace the
## station). `receiverPointCode` is the code that join used. Source rows are
## unchanged. Auxiliary traces are left alone. The channel → station step
## (2-4) assumes the recorder numbers
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
    ## One X or O record, as kept: 56 bytes (a survey's X file holds tens of
    ## millions). Its tape is only compared as it is added (`tape`).
    fromChannel, toChannel: int64
    step: int64
    fixed: int32               # X: the source; O: the receiver (in `RunStore.fixed`)
    index: int16               # point index of `line`'s stations
    line, first, last: float64 # X: receiver line and points; O: source line and points

  RecordRuns = object
    ## The runs of one record, in file order: `RunStore.runs[first ..< first
    ## + count]`, in `room` slots from `first` (the rest free for its next
    ## runs).
    first, count, room: int
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

  RunStore = object
    ## The relations of one domain. Every run is in one list, each record's
    ## together: a run costs its 56 bytes and the list's room to grow, where
    ## a list of its own per record and a tape string per run took 154.
    ##
    ## A record given again after other records (a file sorted by line, not
    ## by record) moves to the end of the list when its slots are full, and
    ## takes twice as many as it has runs there: it moves again only once it
    ## has doubled. The slots it leaves are gaps, and the list is compacted
    ## (each record keeping its slots) once the gaps outnumber the runs.
    ## Its moves and compactions cost amortised O(log n) a run for n runs
    ## added in any order (a record whose runs do not ascend also checks a
    ## new run against its earlier ones: `RecordRuns.scattered`):
    ## - a record moves at counts that at least double (its room never
    ##   shrinks), so its moves copy fewer runs than twice its final count,
    ##   and all moves fewer than 2n;
    ## - a move leaves as many gaps as it copies, so fewer than 2n gaps are
    ##   ever made; a compaction needs more gaps than the `held` runs, so the
    ##   `held` of all compactions add up to less than 2n;
    ## - a compaction copies the list (a record has at most 2 slots a run;
    ##   the gaps, at most the runs before the last move and that move's
    ##   count after it: 2 a run) and sorts the records: O(held log held).
    ## Record order, the common case, never moves anything.
    runs: seq[Run]
    records: Table[int64, RecordRuns]
    fixed: seq[StationKey] # the runs' fixed stations, one entry per change from run to run
    held, gaps: int        # runs held, and slots left behind by records moved
    byStation: Table[StationKey, seq[StationRecord]]
      # (line, point, index 0) of a run's fixed station → its records
    lastStation: (StationKey, StationRecord) # the entry `byStation` was given last
    hasLastStation: bool

  SurveyGeometry* = object
    ## Station coordinates and channel relations from survey files.
    table*: GeometryTable
    runs: array[RelationDomain, RunStore]
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
    logStore: DiagLog ## Empty stand-in when `logRef` is nil (`var` does not
                      ## apply a field default). Writes go to `logRef`.
    logRef: ref DiagLog ## See `log`. Shared across copies.
    codes: RcvCodes

  ReceiverRow = object
    code: string
    c: Coordinates

  RcvCodes = ref object
    ## Coded receiver rows, shared across copies so a by-value join can note
    ## an ambiguous choice. `table.receivers` still holds the last loaded
    ## coordinates (one per station).
    rows: Table[StationKey, seq[ReceiverRow]]
    noted: Table[StationKey, string] ## Codes already named in `log`.
    ambiguousNoted: HashSet[StationKey]
    ambiguousLogged: int

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
  ## Problems met while adding survey files, and an ambiguous receiver
  ## point-code choice (`applySurvey` appends it here).
  if g.logRef.isNil: return g.logStore
  g.logRef[]


func relationCount*(g: SurveyGeometry, domain = rdSource): int {.inline.} =
  ## The number of relation runs (X records, or O records) loaded.
  g.runs[domain].held

func recordCount*(g: SurveyGeometry, domain = rdSource): int {.inline.} =
  ## The number of field records (X) or gathers (O) that have relations:
  ## as many as `records` yields, without sorting them.
  g.runs[domain].records.len

proc reserveRelations*(g: var SurveyGeometry, runs: int, domain = rdSource) =
  ## Room for `runs` more relation runs (X or O records) of `domain`, so that
  ## a large relation file's runs are not copied as their list grows (with
  ## Nim's allocator the memory of the copies stays with the program: a
  ## viewer reading an X file of 3 million records held about three times
  ## what it kept). `addSps(g, path)` reserves for the file's records itself.
  template s: untyped = g.runs[domain]
  if runs > 0 and s.runs.len + runs > s.runs.capacity:
    var room = newSeqOfCap[Run](s.runs.len + runs)
    for r in s.runs: room.add r
    s.runs = move room

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
    z = NaN) =
  ## Adds or replaces a receiver station; index 0 matches any point index.
  ## A coded row from SPS at that station is dropped: this coordinate is the
  ## one `applySurvey` uses.
  g.table.addReceiver(line, point, index, x, y, z)
  if not g.codes.isNil:
    let key = stationKey(line, point, index)
    g.codes.rows.del(key)
    if key in g.codes.noted: g.codes.noted.del(key)

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

proc ensureLog(g: var SurveyGeometry) {.inline.} =
  if g.logRef.isNil: g.logRef = (ref DiagLog)()

proc note(g: var SurveyGeometry, sev: Severity, file, msg: string, record = -1) =
  g.ensureLog()
  g.logRef[].report(sev, dcBadValue, msg, loc = Location(file: file, record: record))

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

proc noteAgain(g: var SurveyGeometry, cap: var RepeatCap, kind: SpsPointKind, file: string,
    record: int, key: StationKey, same: bool) =
  let what = (if kind == pkSource: "source " else: "receiver ") & $key.line & "/" &
    $key.point & "/" & $key.index
  if same:
    g.noteCapped(cap, "again", sevInfo, file, what & " is given again with the same " &
      "coordinates", record)
  else:
    g.noteCapped(cap, "moved", sevWarning, file, what & " is given again with other " &
      "coordinates; the later ones are used", record)

func isMarker(code: string): bool =
  # KL (kill) and PM (permanent marker) are not sensor classes: a later row
  # still replaces the station, as before codes were kept.
  let u = code.toUpperAscii
  u == "KL" or u == "PM"

proc ensureCodes(g: var SurveyGeometry) {.inline.} =
  g.ensureLog()
  if g.codes.isNil: g.codes = RcvCodes()

proc addReceiverRow(g: var SurveyGeometry, cap: var RepeatCap, file: string, record: int,
    line, point: float64, index: int16, code: string, c: Coordinates) =
  # A different point code is kept; the same code again replaces that row
  # (later coordinates, and the row becomes the last loaded). KL/PM, or a
  # row arriving at a station that holds one, replaces the station.
  g.ensureCodes()
  let key = stationKey(line, point, index)
  var rows: seq[ReceiverRow] = @[]
  if key in g.codes.rows: rows = g.codes.rows[key]
  let marker = isMarker(code) or (rows.len == 1 and isMarker(rows[0].code))
  if marker:
    let known = rows.len > 0
    let same = known and sameCoordinates(rows[^1].c, c)
    g.codes.rows[key] = @[ReceiverRow(code: code, c: c)]
    g.table.receivers[key] = c
    if key in g.codes.noted: g.codes.noted.del(key)
    if known: g.noteAgain(cap, pkReceiver, file, record, key, same)
    return
  var found = -1
  for i, row in rows:
    if row.code == code:
      found = i
      break
  if found >= 0:
    let same = sameCoordinates(rows[found].c, c)
    var row = rows[found]
    row.c = c
    rows.delete(found)
    rows.add row
    g.codes.rows[key] = rows
    g.table.receivers[key] = c
    g.noteAgain(cap, pkReceiver, file, record, key, same)
  else:
    rows.add ReceiverRow(code: code, c: c)
    g.codes.rows[key] = rows
    g.table.receivers[key] = c

proc noteSeveralCodes(g: var SurveyGeometry, cap: var RepeatCap, file: string) =
  # One line per station that holds more than one point code, naming them.
  # The first few per file, then a count, as for "given again".
  if g.codes.isNil: return
  for key, rows in g.codes.rows:
    if rows.len < 2: continue
    var sig = ""
    for i, row in rows:
      if i > 0: sig.add ", "
      sig.add row.code
    if g.codes.noted.getOrDefault(key) == sig: continue
    g.noteCapped(cap, "codes", sevInfo, file, "receiver " & $key.line & "/" &
      $key.point & "/" & $key.index & " has several point codes: " & sig)
    g.codes.noted[key] = sig

proc addStation(g: var SurveyGeometry, cap: var RepeatCap, kind: SpsPointKind, file: string,
    record: int, line, point: float64, index: int16, c: Coordinates, code = "") =
  # Adds or replaces a station. One given before is reported: the later
  # coordinates are used, and nothing else would say that two records name
  # one station. A receiver with another point code is kept beside it.
  if kind == pkReceiver:
    g.addReceiverRow(cap, file, record, line, point, index, code, c)
    return
  let key = stationKey(line, point, index)
  var known = false
  var same = false
  g.table.stationsOf(kind).withValue(key, held):
    known = true
    same = sameCoordinates(held[], c)
    held[] = c
  do:
    g.table.stationsOf(kind)[key] = c
  if known: g.noteAgain(cap, kind, file, record, key, same)

func lineText(name: string, line: float64): string =
  # A line as a message names it: its text, or (read without names,
  # `SpsOptions.keepNames`) its number.
  if name.len > 0: name
  elif line == trunc(line) and abs(line) < 1e15: $int64(line)
  else: $line

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

func fixedOf(s: RunStore, run: Run): StationKey {.inline.} = s.fixed[run.fixed]

func at(s: RunStore, run: Run, channel: int64, multi: bool,
    domain: RelationDomain): StationRelation =
  ## The relation of a channel `run` covers.
  let d = channel - run.fromChannel
  let i = d div run.step
  let n = (run.toChannel - run.fromChannel) div run.step
  let moving = stationKey(run.line, pointAt(run.first, run.last, i, n), run.index)
  result.component = if multi and run.step > 1: int(d mod run.step) + 1 else: 0
  if domain == rdSource: (result.source, result.receiver) = (s.fixedOf(run), moving)
  else: (result.source, result.receiver) = (moving, s.fixedOf(run))

func sameRelation(a, b: StationRelation): bool =
  a.source == b.source and a.receiver == b.receiver and a.component == b.component

template runsOf(s: RunStore, rr: RecordRuns): untyped =
  ## The runs of record `rr`, in file order.
  s.runs.toOpenArray(rr.first, rr.first + rr.count - 1)

func overlaps(runs: openArray[Run], run: Run): bool =
  for o in runs:
    if run.fromChannel <= o.toChannel and o.fromChannel <= run.toChannel: return true

func find(s: RunStore, rr: RecordRuns, channel: int64, multi: bool): int =
  # The run that has `channel` (its place in the record): the first in file
  # order covering it; -1 if none does.
  result = -1
  if rr.scattered:
    for j, run in s.runsOf(rr):
      if run.covers(channel, multi): return j
  else:
    # Ascending and disjoint: only the last run starting at or before the
    # channel can cover it.
    var (lo, hi) = (0, rr.count)
    while lo < hi:
      let mid = (lo + hi) shr 1
      if s.runs[rr.first + mid].fromChannel <= channel: lo = mid + 1 else: hi = mid
    if lo > 0 and s.runs[rr.first + lo - 1].covers(channel, multi): result = lo - 1

func owns(s: RunStore, rr: RecordRuns, j: int, channel: int64, multi: bool): bool {.inline.} =
  # Run `j` of the record covers `channel`, and no earlier run does.
  if not s.runs[rr.first + j].covers(channel, multi): return false
  if rr.scattered:
    for o in 0 ..< j:
      if s.runs[rr.first + o].covers(channel, multi): return false
  true

proc compact(s: var RunStore) =
  # The runs again without the gaps records moved to the end left, each
  # record's in the order they were, with its room. The list keeps its spare
  # capacity (`reserveRelations`).
  var order = newSeqOfCap[(int, int64)](s.records.len)
  for record, rr in s.records: order.add (rr.first, record)
  order.sort
  var runs = newSeqOfCap[Run](s.runs.capacity - s.gaps)
  for (_, record) in order:
    s.records.withValue(record, rr):
      let first = runs.len
      for run in s.runsOf(rr[]): runs.add run
      runs.setLen(first + rr.room)
      rr.first = first
  s.runs = move runs
  s.gaps = 0

proc add(s: var RunStore, record: int64, run: sink Run): bool =
  # Appends a run to `record`'s; true when it overlaps an earlier one.
  # Whether the runs still ascend without sharing a channel is noted here,
  # once, so that lookups need not find out per channel: a record of
  # thousands of X rows was scanned from its first row for every channel.
  # (See `RunStore` for the moves and why they cost O(log n) a run.)
  result = false
  var moved = false
  s.records.withValue(record, rr):
    if rr.count == rr.room and rr.first + rr.room != s.runs.len:
      # Full, and other records after it: it moves to the end, with room
      # for as many runs again.
      let old = rr.first
      rr.first = s.runs.len
      s.runs.setLen(rr.first + 2 * rr.count)
      for i in 0 ..< rr.count: s.runs[rr.first + i] = s.runs[old + i]
      s.gaps += rr.room
      rr.room = 2 * rr.count
      moved = true
    if rr.count > 0 and (rr.scattered or
        run.fromChannel <= s.runs[rr.first + rr.count - 1].lastChannel(multi = true)):
      rr.scattered = true
      result = s.runsOf(rr[]).overlaps(run)
    let stations = (run.toChannel - run.fromChannel) div run.step + 1
    rr.channels[false] += stations
    rr.channels[true] += stations * run.step
    if rr.count == rr.room: # the last record: the list grows
      s.runs.add run
      inc rr.room
    else:
      s.runs[rr.first + rr.count] = run
    inc rr.count
  do:
    let stations = (run.toChannel - run.fromChannel) div run.step + 1
    s.records[record] = RecordRuns(first: s.runs.len, count: 1, room: 1,
      channels: [stations, stations * run.step])
    s.runs.add run
  inc s.held
  if moved and s.gaps > s.held: s.compact()

proc addRelation(g: var SurveyGeometry, domain: RelationDomain, file: string, i: int,
    r: SpsRelation, fixedLine, line: float64) =
  # In both domains the record's source columns hold the fixed station and
  # its receiver columns the run of moving stations.
  template s: untyped = g.runs[domain]
  let fixed = stationKey(fixedLine, r.srcPoint, idx(r.srcIndex))
  if s.fixed.len == 0 or s.fixed[^1] != fixed: s.fixed.add fixed
  if s.add(r.fieldRecord, Run(fromChannel: r.fromChannel, toChannel: r.toChannel,
      step: r.channelIncrement, fixed: int32(s.fixed.high), line: line, first: r.fromReceiver,
      last: r.toReceiver, index: idx(r.rcvIndex))):
    g.note(sevWarning, file, (if domain == rdSource: "field record " else: "gather ") &
      $r.fieldRecord & ": channels " & $r.fromChannel & ".." & $r.toChannel &
      " overlap an earlier record (different tapes or line sequences?); the earlier one wins", i)
  let entry = StationRecord(index: fixed.index, record: r.fieldRecord)
  let key = fixed.anyIndex
  if not s.hasLastStation or (key, entry) != s.lastStation:
    # (the runs of a record share it: it is looked up once)
    (s.lastStation, s.hasLastStation) = ((key, entry), true)
    s.byStation.withValue(key, records):
      if entry notin records[]: records[].add entry
    do:
      s.byStation[key] = @[entry]

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
  ## skipped, with one warning per line name. A source given before is
  ## replaced and reported. A receiver with the same point code is too; a
  ## different code is kept beside it (one info per such station, naming the
  ## codes). `KL` and `PM` still replace the station. A warning when the
  ## later coordinates differ, an info when they are the same. `g.log` gets
  ## the first few reports of each kind per file, then a count.
  var unresolved: HashSet[string]
  var cap: RepeatCap
  # (by index: `pairs` of a seq gives each record as a copy, its strings too)
  for i in 0 ..< f.points.len:
    template p: untyped = f.points[i]
    let l = g.lineOf(unresolved, f.name, p.lineName, p.line, i)
    if l.isNone: discard
    elif p.point.isNaN:
      g.noteCapped(cap, "point", sevInfo, f.name, "point '" & p.pointName & "' on line " &
        lineText(p.lineName, l.get) & " is not a number; skipped", i)
    elif p.easting.isNaN or p.northing.isNaN:
      discard # no coordinates: nothing to add
    else:
      g.addStation(cap, p.kind, f.name, i, l.get, p.point, idx(p.index),
        Coordinates(x: p.easting, y: p.northing, z: p.elevation), p.code)
  g.noteSeveralCodes(cap, f.name)
  for i in 0 ..< f.relations.len:
    template r: untyped = f.relations[i]
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
  g.ensureLog()
  cap.summarize(g.logRef[], f.name)

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
  if log.len == 0: return
  g.ensureLog()
  g.logRef[].add log

proc addSps*(g: var SurveyGeometry, path: string, opts = SpsOptions(),
    xDomain = relationDomainOf(path)) =
  ## Reads the SPS file (Rev 1.0 or 2.1) at `path` and adds it; its
  ## diagnostics go to `g.log`. `X` records of an `.ops` file are receiver
  ## domain (O) by default. Raises `IOError` if it cannot be read. The
  ## records are read without their text (`SpsOptions.keepRaw` and
  ## `keepNames` are not used: nothing is written back from here).
  var o = opts
  o.keepRaw = false
  o.keepNames = false
  let f = readSps(path, o)
  g.addLog(f.log)
  for domain in RelationDomain:
    var n = 0
    for r in f.relations:
      if (if r.recordType == 'O': rdReceiver else: xDomain) == domain: inc n
    g.reserveRelations(n, domain)
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
  template s: untyped = g.runs[domain]
  s.records.withValue(record, rr):
    let j = s.find(rr, channel, g.multiComponent)
    if j >= 0: return some(s.at(s.runs[rr.first + j], channel, g.multiComponent, domain))
  none(StationRelation)

iterator records*(g: SurveyGeometry, domain = rdSource): int64 =
  ## The field records (X) or gathers (O) that have relations, ascending.
  var all = newSeqOfCap[int64](g.runs[domain].records.len)
  for r in g.runs[domain].records.keys: all.add r
  all.sort
  for r in all: yield r

iterator relations*(g: SurveyGeometry, record: int64,
    domain = rdSource): tuple[channel: int64, relation: StationRelation] =
  ## Every channel of `record` with its stations, run by run in file order;
  ## a channel two runs cover is yielded once, for the earlier run (as
  ## `relation` does). `relationRuns` gives the same run by run, without
  ## the per-channel work.
  template s: untyped = g.runs[domain]
  if record in s.records:
    let rr = s.records[record]
    let multi = g.multiComponent
    for j in 0 ..< rr.count:
      let run = s.runs[rr.first + j]
      var c = run.fromChannel
      while c <= run.lastChannel(multi):
        if s.owns(rr, j, c, multi): yield (c, s.at(run, c, multi, domain))
        inc c

func relationsDisjoint*(g: SurveyGeometry, record: int64, domain = rdSource): bool =
  ## Whether the runs of `record` ascend by channel and no two share one
  ## (also true for a record without relations). Then `relationRuns` gives
  ## every channel of the record exactly once; otherwise some of its runs
  ## overlap or are out of order, and only `relations` and `relation` say
  ## which run a shared channel belongs to (the earlier one).
  record notin g.runs[domain].records or not g.runs[domain].records[record].scattered

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
  template s: untyped = g.runs[domain]
  if record in s.records:
    let rr = s.records[record]
    let multi = g.multiComponent
    for j in 0 ..< rr.count:
      let run = s.runs[rr.first + j]
      let n = (run.toChannel - run.fromChannel) div run.step
      let components = if multi: run.step else: 1'i64
      yield RelationRun(fromChannel: run.fromChannel,
        toChannel: run.fromChannel + n * run.step + components - 1,
        channelStep: run.step, stations: int(n) + 1, components: int(components),
        fixed: s.fixedOf(run), line: run.line,
        firstPoint: run.first, lastPoint: run.last,
        pointStep: (if n == 0: 0.0 else: (run.last - run.first) / float64(n)),
        index: run.index)

proc expectedChannels*(g: SurveyGeometry, record: int64, domain = rdSource): int =
  ## The number of channels (X) or traces (O) `record` has relations for.
  g.runs[domain].records.withValue(record, rr):
    if rr.scattered:
      for _ in g.relations(record, domain): inc result
    else:
      result = int(rr.channels[g.multiComponent])

proc recordsAt*(g: SurveyGeometry, station: StationKey, domain = rdSource): seq[int64] =
  ## The field records of a source station (X, `rdSource`) or the gathers of
  ## a receiver station (O, `rdReceiver`), ascending: several for repeated or
  ## reshot points. Index 0 on either side matches any index.
  let key = stationKey(station.line, station.point, 0)
  g.runs[domain].byStation.withValue(key, records):
    for e in records:
      if station.index == 0 or e.index == 0 or e.index == station.index:
        if e.record notin result: result.add e.record
  result.sort

proc channelOf*(g: SurveyGeometry, record: int64, station: StationKey,
    domain = rdSource): Option[int64] =
  ## The channel of field record `record` recorded at receiver `station`
  ## (X), or the trace of gather `record` from source `station` (O); the
  ## first component's channel for multi-component runs. None if the record
  ## does not list the station.
  template s: untyped = g.runs[domain]
  if record notin s.records: return none(int64)
  let st = stationKey(station.line, station.point, station.index)
  for run in s.runsOf(s.records[record]):
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
          if won.isSome and sameRelation(won.get, s.at(run, c, g.multiComponent, domain)):
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

func codeClass(code: string): SensorClass =
  if code.len == 0: return scUnknown
  case code[0].toUpperAscii
  of 'H': scHydrophone
  of 'G': scGeophone
  of 'R': scOther
  else: scUnknown

func chooseRow(rows: openArray[ReceiverRow], class: SensorClass): tuple[i: int, ambiguous: bool] =
  # One row: take it. Several: the unique row of the trace's class, else the
  # last loaded of the candidates (the matching class, or every row).
  if rows.len == 0: return (-1, false)
  if rows.len == 1: return (0, false)
  var last = -1
  var n = 0
  if class != scUnknown:
    for i, row in rows:
      if codeClass(row.code) == class:
        last = i
        inc n
  if n == 1: return (last, false)
  if n > 1: return (last, true)
  (rows.high, true)

func rowsAt(g: SurveyGeometry, line, point: float64, index: int16):
    tuple[ok: bool, key: StationKey, rows: seq[ReceiverRow]] =
  # The same index rules as `lookup`: exact, then index 0, and a trace with
  # index 0 also tries index 1. The first key that has rows, not a merge.
  if g.codes.isNil or line.isNaN or point.isNaN: return
  let keys = [stationKey(line, point, index), stationKey(line, point, 0),
    stationKey(line, point, 1)]
  for i in 0 .. (if index == 0: 2 else: 1):
    if keys[i] in g.codes.rows:
      return (true, keys[i], g.codes.rows[keys[i]])

proc noteAmbiguous(g: SurveyGeometry, key: StationKey, rows: openArray[ReceiverRow]) =
  # One warning per station, not per trace. The first few, then one count.
  if g.codes.isNil or g.logRef.isNil: return
  if g.codes.ambiguousNoted.containsOrIncl(key): return
  if g.codes.ambiguousLogged >= MaxRepeats:
    if g.codes.ambiguousLogged == MaxRepeats:
      g.logRef[].report(sevInfo, dcBadValue,
        "further ambiguous receiver point-code choices are not logged")
    inc g.codes.ambiguousLogged
    return
  var sig = ""
  for i, row in rows:
    if i > 0: sig.add ", "
    sig.add row.code
  inc g.codes.ambiguousLogged
  g.logRef[].report(sevWarning, dcBadValue, "receiver " & $key.line & "/" & $key.point &
    "/" & $key.index & " is ambiguous (point codes " & sig & "); the later row is used")

proc applyReceiverChoice(stations: SurveyGeometry, k: var TraceKeys, overwrite: bool,
    before: TraceKeys) =
  # Class-aware receiver coordinates, after `applyGeometry`'s last-wins fill.
  # Sources are left as `applyGeometry` set them.
  if stations.codes.isNil: return
  if not overwrite and before.hasReceiverXY: return
  let found = stations.rowsAt(k.rcvLine, k.rcvPoint, k.rcvIndex)
  if not found.ok: return
  let choice = chooseRow(found.rows, k.sensorClass)
  if choice.i < 0: return
  if choice.ambiguous: stations.noteAmbiguous(found.key, found.rows)
  let c = found.rows[choice.i].c
  let xySame = k.rcvX == c.x and k.rcvY == c.y
  let zSame = c.z.isNaN or k.rcvZ == c.z
  (k.rcvX, k.rcvY) = (c.x, c.y)
  if not c.z.isNaN: k.rcvZ = c.z
  if xySame and zSame: return
  if overwrite or before.offset.isNaN or before.offset == 0: k.offset = NaN
  if overwrite or before.cmpX.isNaN or before.cmpY.isNaN:
    k.cmpX = NaN
    k.cmpY = NaN
  k.deriveGeometry(overwrite)

func receiverPointCode*(g: SurveyGeometry, k: TraceKeys): string =
  ## The SPS point code of the receiver row `applySurvey` uses for `k`
  ## ("" when that station has no coded row). One row is returned as stored.
  ## Several are matched by `sensorClass`: `H*` hydrophone, `G*` geophone or
  ## other particle-motion sensor, `R*` any other identified receiver. No
  ## unique match is the later candidate, the same row the coordinates come
  ## from.
  let found = g.rowsAt(k.rcvLine, k.rcvPoint, k.rcvIndex)
  if not found.ok: return ""
  let i = chooseRow(found.rows, k.sensorClass).i
  if i < 0: return ""
  found.rows[i].code

proc join(k: var TraceKeys, stations, relations: SurveyGeometry, overwrite: bool,
    match: var JoinMatch): set[JoinGroup] =
  # `applySurvey` on one trace: how it matched, and the groups of values
  # that are not what they were (none for a trace that already holds the
  # survey's values, also with `overwrite`).
  let before = k
  match = k.joinStations(relations)
  if match != jmAuxiliary:
    discard k.applyGeometry(stations.table, overwrite)
    stations.applyReceiverChoice(k, overwrite, before)
  changedGroups(before, k)

proc applySurvey*(k: var TraceKeys, g: SurveyGeometry, overwrite = false): bool =
  ## Fills `k` from the survey: the stations its header lacks
  ## (`joinStations`), then coordinates by station, offset and midpoint.
  ## `overwrite` replaces known coordinates, offset and midpoint; header
  ## stations are never replaced. True if a value changed (false for a trace
  ## that already holds the survey's values). A receiver station with several
  ## point codes is matched by `sensorClass` (see `receiverPointCode`); one
  ## row is taken whatever its code. No unique class match uses the later
  ## candidate and logs an ambiguous warning on `g.log`.
  var match: JoinMatch
  k.join(g, g, overwrite, match) != {}

proc applySurvey*(k: var TraceKeys, stations, relations: SurveyGeometry,
    overwrite = false): bool =
  ## `applySurvey` with the stations' coordinates of one geometry and the
  ## relations (and `multiComponent`) of another: a survey whose relation
  ## file is held already (a viewer's map keeps it) is joined without reading
  ## that file again. The same as one geometry holding both. An ambiguous
  ## receiver point-code choice is logged on `stations`.
  var match: JoinMatch
  k.join(stations, relations, overwrite, match) != {}

proc applySurvey*(ix: var TraceIndex, stations, relations: SurveyGeometry,
    stats: var JoinStats, overwrite = false): int =
  ## `applySurvey` on every trace, with the stations of `stations` and the
  ## relations of `relations` (see `applySurvey` of trace keys); returns the
  ## traces changed, and how they matched in `stats`. A join that changes no
  ## trace leaves the index as it was (`keysRevision`, `joined`). Raises
  ## `ValueError` for an index built without `keys = true`.
  ix.requireKeys()
  stats = JoinStats(traces: ix.keys.len)
  for i, k in ix.keys.mpairs:
    var match: JoinMatch
    let groups = k.join(stations, relations, overwrite, match)
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

proc applySurvey*(ix: var TraceIndex, g: SurveyGeometry, stats: var JoinStats,
    overwrite = false): int =
  ## `applySurvey` on every trace; returns the traces changed, and how they
  ## matched in `stats`. A join that changes no trace leaves the index as it
  ## was (`keysRevision`, `joined`). Raises `ValueError` for an index built
  ## without `keys = true`.
  ix.applySurvey(g, g, stats, overwrite)

proc applySurvey*(ix: var TraceIndex, g: SurveyGeometry, overwrite = false): int =
  ## `applySurvey` on every trace; returns the traces changed. Raises
  ## `ValueError` for an index built without `keys = true`.
  var stats: JoinStats
  ix.applySurvey(g, stats, overwrite)

proc applySurvey*(ix: var TraceIndex, stations, relations: SurveyGeometry,
    overwrite = false): int =
  ## `applySurvey` on every trace with the stations of `stations` and the
  ## relations of `relations`; returns the traces changed. Raises
  ## `ValueError` for an index built without `keys = true`.
  var stats: JoinStats
  ix.applySurvey(stations, relations, stats, overwrite)

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

proc applySurvey*(f: var SeismicFile, stations, relations: SurveyGeometry,
    stats: var JoinStats, overwrite = false): int =
  ## `applySurvey` with the stations' coordinates of `stations` and the
  ## relations (and `multiComponent`) of `relations`: a survey whose
  ## relation file is held already is joined without reading it again. The
  ## same as one geometry holding both. In memory only.
  f.mindex.applySurvey(stations, relations, stats, overwrite)

proc applySurvey*(f: var SeismicFile, stations, relations: SurveyGeometry,
    overwrite = false): int =
  ## `applySurvey` with the stations' coordinates of `stations` and the
  ## relations of `relations`, in memory only; returns the traces changed.
  ## Raises `ValueError` for a file opened without `keys = true`.
  f.mindex.applySurvey(stations, relations, overwrite)

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
  template s: untyped = g.runs[rdSource]
  var byLine: Table[float64, seq[(int64, int)]]
  for rec, rr in s.records:
    for j, run in s.runsOf(rr): byLine.mgetOrPut(run.line, @[]).add (rec, j)
  var lines = newSeqOfCap[float64](byLine.len)
  for l in byLine.keys: lines.add l
  lines.sort
  var gather = firstGather
  for line in lines:
    var at: Table[StationKey, seq[SourceAt]]
    for (rec, j) in byLine[line]:
      let rr = s.records[rec]
      let run = s.runs[rr.first + j]
      var c = run.fromChannel
      while c <= run.lastChannel(multi):
        if s.owns(rr, j, c, multi):
          let rel = s.at(run, c, multi, rdSource)
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
