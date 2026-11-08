## SEG positional exchange formats P1-P4 (1983). Spec note:
## `docs/spec/p1_p2_p3.md`.
##
## A file holds one or more logical files, each a block of 20-record header
## card images (an `H` in column 1 of a block's first record, free text
## otherwise) followed by data records. P1 (postplot shotpoint positions)
## is decoded field by field; P2 (marine field data), P3 (land survey
## observations) and P4 (Transit Doppler) are recognised and kept as raw
## records, which the writer re-emits unchanged.
##
## Decisions on the spec's open points (`docs/spec/p1_p2_p3.md` §9):
## - Implicit decimals of the `F8.X`/`F5.X` fields (grid, depth/elevation)
##   come from `P1Options` (default 0); they are never guessed from the
##   header text.
## - Latitude/longitude are DMS unless the option says grads; `auAuto`
##   picks per record (DMS when minutes < 60 and seconds < 60).
## - Headers: lenient. After an `H` record, every record is header text until
##   the first record that validates as data; an `H` after data starts a new
##   logical file.
## - Two-digit years: < 50 is 20YY, else 19YY.

import std/[options, streams, strutils, math]
import ../common/[diagnostics, errors, outputfile]
import ./[textrec, cards]

export textrec, diagnostics

type
  PFormat* = enum
    pfUnknown = "unknown"
    pfP1 = "P1"  ## Postplot location data.
    pfP2 = "P2"  ## Marine positioning field data.
    pfP3 = "P3"  ## Land survey field data.
    pfP4 = "P4"  ## Transit Doppler satellite field data.

  AngleUnit* = enum
    auAuto = "auto"    ## Per record: DMS if it is valid DMS, else grads.
    auDms = "dms"      ## Degrees, minutes, seconds (implicit 2 decimals).
    auGrads = "grads"  ## Grads to 5 decimals.

  P1Record* = object
    ## A data record. `raw` always holds the text as read; the decoded fields
    ## are set for P1 records only. Missing numbers are NaN, missing time
    ## parts -1.
    raw*: string
    lineName*: string   ## Cols 2-17, trimmed.
    pointName*: string  ## Cols 18-25, trimmed.
    point*: float64     ## Numeric point; NaN if not a number.
    reshoot*: char      ## Col 26: ' ' original, 'A' first reshoot, ...
    latitude*, longitude*: float64 ## Degrees, negative south / west.
    angleUnit*: AngleUnit ## How the latitude/longitude were (or will be) written.
    easting*, northing*: float64
    depthOrElevation*: float64
    year*, dayOfYear*, hour*, minute*, second*: int

  PLogicalFile* = object
    ## One logical file: its header text and data records.
    format*: PFormat
    header*: seq[string] ## Header records as read (an `H` in col 1 of the first).
    records*: seq[P1Record]

  P1File* = object
    ## The logical files of one P1-P4 file.
    name*: string ## Path or name, for diagnostics.
    layout*: TextLayout
    crlf*: bool
    finalNewline*: bool = true ## The last line had a terminator.
    files*: seq[PLogicalFile]
    options*: P1Options
      ## How the file was read: the implicit decimals, which the writer
      ## also uses (set them to re-encode with other decimals).
    log*: DiagLog

  P1Options* = object
    ## How `readP1` decodes (and the writer encodes) P1 records.
    gridDecimals*: int = 0   ## Implicit decimals of easting/northing (F8.X).
    depthDecimals*: int = 0  ## Implicit decimals of depth/elevation (F5.X).
    angleUnit*: AngleUnit = auAuto
    layout*: TextLayout = tlLines ## Used only with `forceLayout`.
    forceLayout*: bool

func initP1Record*(): P1Record =
  ## A P1 record with every value missing.
  P1Record(point: NaN, reshoot: ' ', latitude: NaN, longitude: NaN, angleUnit: auDms,
    easting: NaN, northing: NaN, depthOrElevation: NaN, year: -1, dayOfYear: -1, hour: -1,
    minute: -1, second: -1)

# ----------------------------------------------------------------- decoding --

func allDigitsOrBlank(s: string): bool = s.allCharsInSet(Digits + {' '}) and not s.isBlank

proc dms(deg, minutes, sec: string): Option[float64] =
  ## DMS sub-fields; seconds have 2 implicit decimals. None when invalid.
  let (pd, pm, ps) = (parseFortranInt(deg), parseFortranInt(minutes), parseFortranFloat(sec, 2))
  if pd.isNone or pm.isNone or ps.isNone: return none(float64)
  let d = if pd.get == MissingInt: 0'i64 else: pd.get
  let m = if pm.get == MissingInt: 0'i64 else: pm.get
  let sc = if ps.get.isNaN: 0.0 else: ps.get
  if m >= 60 or sc >= 60: none(float64)
  else: some(float64(d) + float64(m) / 60 + sc / 3600)

proc angle(text: string, degDigits: int, hemi: char, neg: char, unit: AngleUnit,
    v: var float64, used: var AngleUnit): bool =
  ## Latitude (`degDigits` 2) or longitude (3) from its 9- or 10-column field.
  if text[0 ..< text.len - 1].isBlank:
    v = NaN
    return true
  var ok = false
  if unit in {auAuto, auDms}:
    let d = dms(text[0 ..< degDigits], text[degDigits ..< degDigits + 2],
      text[degDigits + 2 ..< degDigits + 6])
    if d.isSome:
      (ok, v, used) = (true, d.get, auDms)
  if not ok and unit in {auAuto, auGrads}:
    let g = parseFortranFloat(text[0 ..< text.len - 1], 5)
    if g.isSome and not g.get.isNaN:
      (ok, v, used) = (true, g.get * 0.9, auGrads)
  if ok and hemi == neg: v = -v
  ok

proc isP1Data(line: string): bool =
  line.colChar(1) == ' ' and line.colChar(35) in {'N', 'S'} and
    line.colChar(45) in {'E', 'W'} and line.col(27, 34).allDigitsOrBlank

proc isP2Pair(a, b: string): bool =
  a.colChar(1) == ' ' and b.colChar(1) in Digits and b.colChar(9) in {'N', 'S'} and
    b.colChar(19) in {'E', 'W'}

proc isP3Data(line: string): bool =
  line.colChar(1) == ' ' and line.colChar(36) in {'1', '2'} and
    line.col(37, 64).allCharsInSet(Digits + {' ', '.', '-', '+'})

proc isP4Data(line: string): bool =
  line.colChar(1) == 'S' and parseFortranInt(line.col(8, 10)) == some(1'i64)

type Ctx = object
  ## Where a record is being decoded; problems go to the `log` passed along.
  name: string
  rec: TextRecord
  opts: P1Options

proc problem(x: Ctx, log: var DiagLog, sev: Severity, code: DiagCode, field, msg: string) =
  log.report(sev, code, msg, x.rec.offset,
    Location(file: x.name, record: x.rec.index, field: field))

proc decodeP1(x: Ctx, log: var DiagLog, line: string): P1Record =
  result = initP1Record()
  result.raw = line
  result.lineName = line.col(2, 17).strip
  result.pointName = line.col(18, 25).strip
  result.point = if result.pointName.len == 0: NaN
                 else: parseFortranFloat(line.col(18, 25)).get(NaN)
  result.reshoot = line.colChar(26)
  var latUnit, lonUnit = x.opts.angleUnit
  if not angle(line.col(27, 35), 2, line.colChar(35), 'S', x.opts.angleUnit, result.latitude,
      latUnit):
    x.problem(log, sevWarning, dcBadValue, "P1.latitude", "bad latitude '" & line.col(27, 35) & "'")
    result.latitude = NaN
  if not angle(line.col(36, 45), 3, line.colChar(45), 'W', x.opts.angleUnit, result.longitude,
      lonUnit):
    x.problem(log, sevWarning, dcBadValue, "P1.longitude",
      "bad longitude '" & line.col(36, 45) & "'")
    result.longitude = NaN
  result.angleUnit = if latUnit == auAuto: lonUnit else: latUnit
  if abs(result.latitude) > 90 or abs(result.longitude) > 180:
    x.problem(log, sevWarning, dcBadValue, "P1.latitude", "position out of range")
  template num(first, last: int, decimals: int, field: string, v: untyped) =
    let p = parseFortranFloat(line.col(first, last), decimals)
    if p.isNone:
      x.problem(log, sevWarning, dcBadValue, field, "not a number: '" & line.col(first, last) & "'")
    v = p.get(NaN)
  num(46, 53, x.opts.gridDecimals, "P1.easting", result.easting)
  num(54, 61, x.opts.gridDecimals, "P1.northing", result.northing)
  num(62, 66, x.opts.depthDecimals, "P1.depthOrElevation", result.depthOrElevation)
  template int2(first, last: int, field: string, v: untyped, hi: int) =
    let n = parseFortranInt(line.col(first, last))
    if n.isNone:
      x.problem(log, sevWarning, dcBadValue, field,
        "not an integer: '" & line.col(first, last) & "'")
    elif n.get != MissingInt:
      v = int(n.get)
      if v > hi: x.problem(log, sevWarning, dcBadValue, field, $v & " is out of range")
  int2(67, 68, "P1.year", result.year, 99)
  int2(69, 71, "P1.dayOfYear", result.dayOfYear, 366)
  int2(72, 73, "P1.hour", result.hour, 23)
  int2(74, 75, "P1.minute", result.minute, 59)
  int2(76, 77, "P1.second", result.second, 59)
  if result.year >= 0:
    result.year = if result.year < 50: 2000 + result.year else: 1900 + result.year

proc detect(lines: openArray[string]): PFormat =
  ## The format of a logical file from the first of its data records that
  ## matches one of P1-P4.
  result = pfUnknown
  for i in 0..<lines.len:
    if isP4Data(lines[i]): return pfP4
    if i + 1 < lines.len and isP2Pair(lines[i], lines[i + 1]): return pfP2
    if isP1Data(lines[i]): return pfP1
    if isP3Data(lines[i]): return pfP3

proc readP1*(s: Stream, name = "", opts = P1Options()): P1File =
  ## Reads P1-P4 logical files from `s`. Problems are in `result.log`; the
  ## read stops early only on an I/O failure (fatal).
  result = P1File(name: name, options: opts)
  result.layout = if opts.forceLayout: opts.layout else: openLayout(s)
  var x = Ctx(name: name, opts: opts)
  var cur = PLogicalFile()
  var inHeader = false
  var pending: seq[TextRecord] # data records until the format is known
  var prev: TextRecord          # the previous record (P2 groups start one early)
  proc flushPending(x: Ctx, log: var DiagLog, cur: var PLogicalFile,
      pending: var seq[TextRecord]) {.nimcall.} =
    if pending.len > 0:
      if cur.format == pfUnknown:
        var texts: seq[string]
        for r in pending: texts.add r.text
        cur.format = detect(texts)
        if cur.format == pfUnknown:
          log.report(sevWarning, dcBadValue, "data records match none of P1-P4; kept raw",
            pending[0].offset, Location(file: x.name, record: pending[0].index))
      for r in pending:
        var xr = x
        xr.rec = r
        if cur.format == pfP1:
          if isP1Data(r.text): cur.records.add xr.decodeP1(log, r.text)
          else:
            xr.problem(log, sevWarning, dcBadValue, "", "not a P1 data record; kept raw")
            var raw = initP1Record()
            raw.raw = r.text
            cur.records.add raw
        else:
          var raw = initP1Record()
          raw.raw = r.text
          cur.records.add raw
      pending.setLen(0)
  try:
    for r in textRecords(s, result.layout):
      x.rec = r
      if r.index == 0: result.crlf = r.crlf
      result.finalNewline = r.terminated
      if r.cut:
        x.problem(result.log, sevWarning, dcBadValue, "", "line longer than " & $MaxLineBytes &
          " bytes; cut into records (is this a text file?)")
      let line = r.text
      let isH = line.colChar(1) == 'H'
      if isH and (cur.records.len > 0 or pending.len > 0):
        x.flushPending(result.log, cur, pending)
        result.files.add cur
        cur = PLogicalFile()
      if isH:
        inHeader = true
        cur.header.add line
      elif inHeader and not (isP1Data(line) or isP4Data(line) or
          (cur.format == pfUnknown and isP3Data(line)) or
          (line.colChar(1) in Digits and isP2Pair(prev.text, line))):
        cur.header.add line
      else:
        if cur.header.len == 0 and pending.len == 0 and cur.records.len == 0:
          x.problem(result.log, sevWarning, dcBadValue, "", "data before any header record")
        if inHeader and line.colChar(1) in Digits and cur.header.len > 1 and
            isP2Pair(prev.text, line):
          cur.header.setLen(cur.header.len - 1) # a P2 group's first record
          pending.add prev
        inHeader = false
        pending.add r
        if pending.len >= 6: x.flushPending(result.log, cur, pending)
      prev = r
    x.flushPending(result.log, cur, pending)
    if cur.header.len > 0 or cur.records.len > 0: result.files.add cur
  except IOError, OSError:
    result.log.report(sevFatal, dcIo, getCurrentExceptionMsg(), loc = Location(file: name))

proc readP1*(path: string, opts = P1Options()): P1File =
  ## Reads the P1-P4 file at `path` (streamed).
  let s = newFileStream(path, fmRead)
  if s == nil:
    result = P1File(name: path)
    result.log.report(sevFatal, dcIo, "cannot open " & path, loc = Location(file: path))
  else:
    try: result = readP1(s, path, opts)
    finally: s.close()

proc parseP1*(text: string, name = "", opts = P1Options()): P1File =
  ## Reads P1-P4 records from a string.
  readP1(newStringStream(text), name, opts)

# ----------------------------------------------------------------- encoding --

proc encodeAngle(v: float64, degDigits: int, unit: AngleUnit, pos, neg: char,
    field: string): string =
  let width = degDigits + 7 # 9 or 10 columns with the hemisphere
  if v.isNaN: return repeat(' ', width)
  let hemi = if v < 0: neg else: pos
  let a = abs(v)
  if unit == auGrads:
    let g = int64(round(a / 0.9 * 1e5))
    result = fit(align($g, width - 1, '0'), width - 1, field) & hemi
  else:
    var cs = int64(round(a * 360_000)) # hundredths of a second
    let d = cs div 360_000
    cs = cs mod 360_000
    let m = cs div 6000
    cs = cs mod 6000
    result = fit(align($d, degDigits, '0'), degDigits, field) & align($m, 2, '0') &
      align($cs, 4, '0') & hemi

proc encodeP1*(r: P1Record, opts = P1Options()): string =
  ## The 80-column text of a P1 record; raises `SegFormatError` when a value
  ## does not fit its field.
  result = repeat(' ', 80)
  if r.lineName.len > 16: raiseFormat("P1.lineName: more than 16 characters")
  result.putCol(2, r.lineName)
  let nameFits = r.pointName.len > 0 and (r.point.isNaN or
    parseFortranFloat(r.pointName) == some(r.point))
  let pt = if nameFits: r.pointName
           elif r.point.isNaN: ""
           elif r.point == round(r.point) and abs(r.point) < 1e15: $int64(r.point)
           else: $r.point
  result.putCol(18, align(fit(if pt.len == 0: " " else: pt, 8, "P1.point"), 8))
  result[25] = r.reshoot
  let unit = if r.angleUnit == auAuto: auDms else: r.angleUnit
  result.putCol(27, encodeAngle(r.latitude, 2, unit, 'N', 'S', "P1.latitude"))
  result.putCol(36, encodeAngle(r.longitude, 3, unit, 'E', 'W', "P1.longitude"))
  template num(first, width, decimals: int, field: string, v: float64) =
    result.putCol(first, fit(formatFixed(v, width, decimals, implicit = true), width, field))
  num(46, 8, opts.gridDecimals, "P1.easting", r.easting)
  num(54, 8, opts.gridDecimals, "P1.northing", r.northing)
  num(62, 5, opts.depthDecimals, "P1.depthOrElevation", r.depthOrElevation)
  template int2(first, width: int, field: string, v: int) =
    result.putCol(first, if v < 0: repeat(' ', width)
                         else: fit(align($v, width, '0'), width, field))
  int2(67, 2, "P1.year", (if r.year < 0: -1 else: r.year mod 100))
  int2(69, 3, "P1.dayOfYear", r.dayOfYear)
  int2(72, 2, "P1.hour", r.hour)
  int2(74, 2, "P1.minute", r.minute)
  int2(76, 2, "P1.second", r.second)

type
  P1WriteOptions* = object
    lineEnding*: string ## "" keeps the file's (CR LF if it had them, else LF).
    lenient*: bool      ## Write records that fail to encode as read.
    padHeaders*: bool ## Pad header blocks to 20 records (the spec's tape blocking).

proc recordLine(r: P1Record, format: PFormat, decimals: P1Options): string =
  ## The raw text when `r` is unchanged since it was read (or is not a P1
  ## record), else encoded.
  if r.raw.len > 0:
    if format != pfP1 or not isP1Data(r.raw): return r.raw
    var scratch: DiagLog # a re-decode to compare; its diagnostics are dropped
    if sameValues(Ctx(opts: decimals).decodeP1(scratch, r.raw), r): return r.raw
  encodeP1(r, decimals)

proc writeP1*(f: P1File, s: Stream, opts = P1WriteOptions()): DiagLog =
  ## Writes every logical file of `f`: header records (padded to blocks of
  ## 20 with `padHeaders`; the first gets an `H` in column 1), then the data
  ## records. Unchanged records are written byte for byte. A value that does
  ## not fit its field is an error and nothing is written, unless `lenient`.
  let nl = if opts.lineEnding.len > 0: opts.lineEnding elif f.crlf: "\r\n" else: "\n"
  var lines: seq[string]
  for li, lf in f.files:
    var header = lf.header
    if header.len == 0: header.add "H"
    if header[0].colChar(1) != 'H':
      header[0] = "H" & header[0].substr(1)
    if opts.padHeaders:
      while header.len mod 20 != 0: header.add ""
    lines.add header
    for r in lf.records:
      try:
        lines.add recordLine(r, lf.format, f.options)
      except SegFormatError as e:
        result.report(if opts.lenient: sevWarning else: sevError, dcValidation, e.msg,
          loc = Location(file: f.name, record: lines.len))
        if r.raw.len > 0: lines.add r.raw
  if result.count(sevError) == 0:
    for i, l in lines:
      s.write l
      if i < lines.len - 1 or f.finalNewline: s.write nl

proc writeP1*(f: P1File, path: string, opts = P1WriteOptions()): DiagLog =
  ## Writes `f` to `path` through a new temporary file next to it, renamed on
  ## success.
  let tmp = createTempFor(path, result)
  let s = if tmp.len > 0: newFileStream(tmp, fmWrite) else: nil
  if s == nil:
    if tmp.len > 0:
      result.report(sevFatal, dcIo, "cannot create " & tmp, loc = Location(file: path))
      finishOutput(tmp, path, keep = false, result)
  else:
    try:
      result = writeP1(f, s, opts)
    finally:
      s.close()
    finishOutput(tmp, path, keep = result.count(sevError) == 0, result)

proc p1Text*(f: P1File, opts = P1WriteOptions()): SurveyText =
  ## `f` written to a string, with the writer's diagnostics.
  let s = newStringStream()
  result.log = writeP1(f, s, opts)
  result.text = s.data
