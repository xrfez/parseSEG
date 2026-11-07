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
## Line names that are not numbers (SPS 1.0, P1) go through `LineNames`: a
## caller-supplied name → number map, then (opt-in) the trailing digits of
## the name (`CLT4960` → 4960).

import std/[tables, strutils, math, sets]
import ../common/diagnostics
import ../model/[keys, traceindex]
import ./[sps, p1]

export keys

type
  LineNames* = object
    ## How text line names become the numeric lines of `StationKey`.
    names*: Table[string, float64] ## Explicit name → line number.
    trailingDigits*: bool          ## Else use the name's trailing digits.

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
    log*: DiagLog ## Problems met while adding survey files.

  StationRelation* = object
    ## The stations one channel of a field record was recorded from.
    source*, receiver*: StationKey
    component*: int ## 1-based within the station (multi-component), else 0.

func relationCount*(g: SurveyGeometry): int =
  ## The number of X runs loaded.
  for runs in g.runs.values: result += runs.len

proc resolveLine*(n: LineNames, name: string, numeric: float64, line: var float64): bool =
  ## The numeric line of a line field: its value when numeric, else the
  ## names map, else (with `trailingDigits`) the trailing digits.
  if not numeric.isNaN:
    line = numeric
    return true
  let key = name.strip
  if key in n.names:
    line = n.names[key]
    return true
  if n.trailingDigits:
    var i = key.len
    while i > 0 and key[i - 1] in Digits: dec i
    if i < key.len:
      line = parseFloat(key[i..^1])
      return true
  false

func idx(i: int): int16 {.inline.} =
  ## A point index as a key part; records hold one digit, but built ones may
  ## not (out-of-range values clamp).
  int16(clamp(i, int(low(int16)), int(high(int16))))

proc note(g: var SurveyGeometry, sev: Severity, file, msg: string, record = -1) =
  g.log.report(sev, dcBadValue, msg, loc = Location(file: file, record: record))

proc addSps*(g: var SurveyGeometry, f: SpsFile, names = LineNames()) =
  ## Adds the stations (R and S records) and relations (X records) of `f`.
  ## Grid coordinates are taken as they are (units of H20); z is the surface
  ## elevation. Records whose line or point cannot be made numeric are
  ## skipped, with one warning per line name.
  var unresolved: HashSet[string]
  proc line(g: var SurveyGeometry, name: string, v: float64, rec: int, l: var float64): bool =
    result = names.resolveLine(name, v, l)
    if not result and name notin unresolved:
      unresolved.incl name
      g.note(sevWarning, f.name, "line '" & name & "' is not a number and has no mapping; " &
        "its records are skipped (use a line name map)", rec)
  for i, p in f.points:
    var l: float64
    if g.line(p.lineName, p.line, i, l):
      if p.point.isNaN:
        g.note(sevInfo, f.name, "point '" & p.pointName & "' on line " & p.lineName &
          " is not a number; skipped")
      elif p.easting.isNaN or p.northing.isNaN:
        discard # no coordinates: nothing to add
      elif p.kind == 'S':
        g.table.addSource(l, p.point, idx(p.index), p.easting, p.northing, p.elevation)
      else:
        g.table.addReceiver(l, p.point, idx(p.index), p.easting, p.northing, p.elevation)
  for i, r in f.relations:
    var sl, rl: float64
    if g.tape.len > 0 and r.fieldTape != g.tape: discard
    elif r.fieldRecord == MissingInt or r.fromChannel == MissingInt or
        r.toChannel == MissingInt or r.channelIncrement < 1 or r.toChannel < r.fromChannel:
      g.note(sevWarning, f.name, "X record without a usable record or channel range; skipped", i)
    elif g.line(r.srcLineName, r.srcLine, i, sl) and g.line(r.rcvLineName, r.rcvLine, i, rl):
      if r.srcPoint.isNaN or r.fromReceiver.isNaN or r.toReceiver.isNaN:
        g.note(sevWarning, f.name, "X record with a non-numeric point; skipped", i)
      else:
        let run = RelationRun(fieldTape: r.fieldTape, fromChannel: r.fromChannel,
          toChannel: r.toChannel, step: r.channelIncrement,
          src: stationKey(sl, r.srcPoint, idx(r.srcIndex)), rcvLine: rl,
          fromRcv: r.fromReceiver, toRcv: r.toReceiver, rcvIndex: idx(r.rcvIndex))
        let runs = g.runs.mgetOrPut(r.fieldRecord, @[])
        for o in runs:
          if run.fromChannel <= o.toChannel and o.fromChannel <= run.toChannel:
            g.note(sevWarning, f.name, "field record " & $r.fieldRecord & ": channels " &
              $run.fromChannel & ".." & $run.toChannel & " overlap an earlier X record " &
              "(different tapes or line sequences?); the earlier one wins", i)
            break
        g.runs[r.fieldRecord].add run

proc addP1*(g: var SurveyGeometry, f: P1File, names = LineNames(), elevation = false) =
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
        var l, numeric: float64
        if not parseFortranFloat(r.lineName, 0, numeric) or r.lineName.len == 0:
          numeric = NaN
        if r.lineName.len == 0 and r.point.isNaN: discard # a raw (non-P1) record
        elif not names.resolveLine(r.lineName, numeric, l):
          if r.lineName notin unresolved:
            unresolved.incl r.lineName
            g.note(sevWarning, f.name, "line '" & r.lineName & "' is not a number and has no " &
              "mapping; its records are skipped (use a line name map)")
        elif r.point.isNaN or r.easting.isNaN or r.northing.isNaN: discard
        else:
          let index = if r.reshoot in {'A'..'Z'}: int16(ord(r.reshoot) - ord('A') + 2) else: 0'i16
          g.table.addSource(l, r.point, index, r.easting, r.northing,
            if elevation: r.depthOrElevation else: NaN)
  if files > 1:
    g.note(sevInfo, f.name, $files & " P1 logical files merged; each may have its own " &
      "projection (see their headers)")

proc relation*(g: SurveyGeometry, record, channel: int64, rel: var StationRelation): bool =
  ## The stations channel `channel` of field record `record` was recorded
  ## from, per the X records; false if no run covers it.
  if record notin g.runs: return false
  for run in g.runs[record]:
    let last = if g.multiComponent: run.toChannel + run.step - 1 else: run.toChannel
    if channel >= run.fromChannel and channel <= last:
      let d = channel - run.fromChannel
      if g.multiComponent or d mod run.step == 0:
        let i = d div run.step
        let n = (run.toChannel - run.fromChannel) div run.step
        let rp = if n == 0: run.fromRcv
                 else: run.fromRcv + float64(i) * (run.toRcv - run.fromRcv) / float64(n)
        rel = StationRelation(source: run.src,
          receiver: stationKey(run.rcvLine, rp, run.rcvIndex),
          component: if g.multiComponent and run.step > 1: int(d mod run.step) + 1 else: 0)
        return true
  false

proc applySurvey*(k: var TraceKeys, g: SurveyGeometry, overwrite = false): bool =
  ## Fills `k` from the survey: stations from the X relations, then
  ## coordinates, offset and midpoint. True if anything changed.
  result = false
  var rel: StationRelation
  if not (k.record.isNaN or k.channel.isNaN) and
      g.relation(int64(k.record), int64(k.channel), rel):
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
  ## `applySurvey` on every trace; returns the traces changed. Needs an index
  ## built with `keys = true`.
  doAssert ix.keys.len == ix.entries.len, "build the index with keys = true"
  for k in ix.keys.mitems:
    if k.applySurvey(g, overwrite): inc result
