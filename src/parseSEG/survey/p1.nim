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
## - Latitude/longitude are DMS unless the option says grads; `p1Auto`
##   picks per record (DMS when minutes < 60 and seconds < 60).
## - Headers: lenient. After an `H` record, every record is header text until
##   the first record that validates as data; an `H` after data starts a new
##   logical file.
## - Two-digit years: < 50 is 20YY, else 19YY.

import std/[streams, strutils, math, os]
import ../common/[diagnostics, errors]
import ./textrec

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
    name*: string
    layout*: TextLayout
    crlf*: bool
    files*: seq[PLogicalFile]
    log*: DiagLog

  P1Options* = object
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

proc dms(deg, minutes, sec: string, v: var float64): bool =
  ## DMS sub-fields; seconds have 2 implicit decimals.
  var d, m: int64
  var sc: float64
  if not (parseFortranInt(deg, d) and parseFortranInt(minutes, m) and
      parseFortranFloat(sec, 2, sc)):
    return false
  if d == MissingInt: d = 0
  if m == MissingInt: m = 0
  if sc.isNaN: sc = 0
  if m >= 60 or sc >= 60: return false
  v = float64(d) + float64(m) / 60 + sc / 3600
  true

proc angle(text: string, degDigits: int, hemi: char, neg: char, unit: AngleUnit,
    v: var float64, used: var AngleUnit): bool =
  ## Latitude (`degDigits` 2) or longitude (3) from its 9- or 10-column field.
  if text[0 ..< text.len - 1].isBlank:
    v = NaN
    return true
  var ok = false
  if unit in {auAuto, auDms}:
    ok = dms(text[0 ..< degDigits], text[degDigits ..< degDigits + 2],
      text[degDigits + 2 ..< degDigits + 6], v)
    if ok: used = auDms
  if not ok and unit in {auAuto, auGrads}:
    var g: float64
    ok = parseFortranFloat(text[0 ..< text.len - 1], 5, g) and not g.isNaN
    if ok:
      v = g * 0.9
      used = auGrads
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
  var n: int64
  line.colChar(1) == 'S' and parseFortranInt(line.col(8, 10), n) and n == 1

type Ctx = object
  f: ptr P1File
  rec: TextRecord
  opts: P1Options

proc problem(x: Ctx, sev: Severity, code: DiagCode, field, msg: string) =
  x.f.log.report(sev, code, msg, x.rec.offset,
    Location(file: x.f.name, record: x.rec.index, field: field))

proc decodeP1(x: Ctx, line: string): P1Record =
  result = initP1Record()
  result.raw = line
  result.lineName = line.col(2, 17).strip
  result.pointName = line.col(18, 25).strip
  if not parseFortranFloat(line.col(18, 25), 0, result.point) or result.pointName.len == 0:
    result.point = NaN
  result.reshoot = line.colChar(26)
  var latUnit, lonUnit = x.opts.angleUnit
  if not angle(line.col(27, 35), 2, line.colChar(35), 'S', x.opts.angleUnit, result.latitude,
      latUnit):
    x.problem(sevWarning, dcBadValue, "P1.latitude", "bad latitude '" & line.col(27, 35) & "'")
    result.latitude = NaN
  if not angle(line.col(36, 45), 3, line.colChar(45), 'W', x.opts.angleUnit, result.longitude,
      lonUnit):
    x.problem(sevWarning, dcBadValue, "P1.longitude", "bad longitude '" & line.col(36, 45) & "'")
    result.longitude = NaN
  result.angleUnit = if latUnit == auAuto: lonUnit else: latUnit
  if abs(result.latitude) > 90 or abs(result.longitude) > 180:
    x.problem(sevWarning, dcBadValue, "P1.latitude", "position out of range")
  template num(first, last: int, decimals: int, field: string, v: untyped) =
    if not parseFortranFloat(line.col(first, last), decimals, v):
      x.problem(sevWarning, dcBadValue, field, "not a number: '" & line.col(first, last) & "'")
      v = NaN
  num(46, 53, x.opts.gridDecimals, "P1.easting", result.easting)
  num(54, 61, x.opts.gridDecimals, "P1.northing", result.northing)
  num(62, 66, x.opts.depthDecimals, "P1.depthOrElevation", result.depthOrElevation)
  template int2(first, last: int, field: string, v: untyped, hi: int) =
    var n: int64
    if not parseFortranInt(line.col(first, last), n):
      x.problem(sevWarning, dcBadValue, field, "not an integer: '" & line.col(first, last) & "'")
    elif n != MissingInt:
      v = int(n)
      if v > hi: x.problem(sevWarning, dcBadValue, field, $v & " is out of range")
  int2(67, 68, "P1.year", result.year, 99)
  int2(69, 71, "P1.dayOfYear", result.dayOfYear, 366)
  int2(72, 73, "P1.hour", result.hour, 23)
  int2(74, 75, "P1.minute", result.minute, 59)
  int2(76, 77, "P1.second", result.second, 59)
  if result.year >= 0: result.year = if result.year < 50: 2000 + result.year else: 1900 + result.year

proc detect(lines: openArray[string]): PFormat =
  ## The format of a logical file from its first data records.
  result = pfUnknown
  if lines.len > 0:
    if isP4Data(lines[0]): result = pfP4
    elif lines.len > 1 and isP2Pair(lines[0], lines[1]): result = pfP2
    elif isP1Data(lines[0]): result = pfP1
    elif isP3Data(lines[0]): result = pfP3

proc readP1*(s: Stream, name = "", opts = P1Options()): P1File =
  ## Reads P1-P4 logical files from `s`. Problems are in `result.log`; the
  ## read stops early only on an I/O failure (fatal).
  result = P1File(name: name)
  result.layout = if opts.forceLayout: opts.layout else: openLayout(s)
  var x = Ctx(f: result.addr, opts: opts)
  var cur = PLogicalFile()
  var inHeader = false
  var pending: seq[TextRecord] # data records until the format is known
  var prev: TextRecord          # the previous record (P2 groups start one early)
  proc flushPending(x: Ctx, cur: var PLogicalFile, pending: var seq[TextRecord]) =
    if pending.len > 0:
      if cur.format == pfUnknown:
        var texts: seq[string]
        for r in pending: texts.add r.text
        cur.format = detect(texts)
        if cur.format == pfUnknown:
          x.f.log.report(sevWarning, dcBadValue, "data records match none of P1-P4; kept raw",
            pending[0].offset, Location(file: x.f.name, record: pending[0].index))
      for r in pending:
        var xr = x
        xr.rec = r
        if cur.format == pfP1:
          if isP1Data(r.text): cur.records.add xr.decodeP1(r.text)
          else:
            xr.problem(sevWarning, dcBadValue, "", "not a P1 data record; kept raw")
            cur.records.add P1Record(raw: r.text)
        else: cur.records.add P1Record(raw: r.text)
      pending.setLen(0)
  try:
    for r in textRecords(s, result.layout):
      x.rec = r
      if r.index == 0: result.crlf = r.crlf
      let line = r.text
      let isH = line.colChar(1) == 'H'
      if isH and (cur.records.len > 0 or pending.len > 0):
        x.flushPending(cur, pending)
        result.files.add cur
        cur = PLogicalFile()
      if isH:
        inHeader = true
        cur.header.add line
      elif inHeader and not (isP1Data(line) or isP4Data(line) or
          (cur.format == pfUnknown and isP3Data(line)) or line.colChar(1) in Digits):
        cur.header.add line
      else:
        if cur.header.len == 0 and pending.len == 0 and cur.records.len == 0:
          x.problem(sevWarning, dcBadValue, "", "data before any header record")
        if inHeader and line.colChar(1) in Digits and cur.header.len > 1 and
            isP2Pair(prev.text, line):
          cur.header.setLen(cur.header.len - 1) # a P2 group's first record
          pending.add prev
        inHeader = false
        pending.add r
        if pending.len >= 6: x.flushPending(cur, pending)
      prev = r
    x.flushPending(cur, pending)
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

proc fit(text: string, width: int, field: string): string =
  if text.len == 0 or text.len > width:
    raiseFormat(field & ": value does not fit in " & $width & " columns")
  text

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

proc encode*(r: P1Record, opts = P1Options()): string =
  ## The 80-column text of a P1 record; raises `SegFormatError` when a value
  ## does not fit its field.
  result = repeat(' ', 80)
  if r.lineName.len > 16: raiseFormat("P1.lineName: more than 16 characters")
  result.putCol(2, r.lineName)
  let pt = if r.pointName.len > 0: r.pointName
           elif r.point.isNaN: ""
           elif r.point == round(r.point): $int64(r.point)
           else: $r.point
  result.putCol(18, rjust(fit(if pt.len == 0: " " else: pt, 8, "P1.point"), 8))
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
    padHeaders*: bool = true ## Pad header blocks to 20 records (the spec's tape blocking).
    decimals*: P1Options     ## Implicit decimals used to encode.

proc recordLine(r: P1Record, format: PFormat, opts: P1WriteOptions): string =
  ## The raw text when `r` is unchanged since it was read, else encoded.
  if format != pfP1 and r.raw.len > 0: return r.raw
  result = encode(r, opts.decimals)
  if r.raw.len > 0:
    var scratch = P1File()
    let x = Ctx(f: scratch.addr, opts: P1Options(gridDecimals: opts.decimals.gridDecimals,
      depthDecimals: opts.decimals.depthDecimals, angleUnit: r.angleUnit))
    if isP1Data(r.raw) and encode(x.decodeP1(r.raw), opts.decimals) == result: result = r.raw

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
        lines.add recordLine(r, lf.format, opts)
      except SegFormatError as e:
        result.report(if opts.lenient: sevWarning else: sevError, dcValidation, e.msg,
          loc = Location(file: f.name, record: lines.len))
        if r.raw.len > 0: lines.add r.raw
  if result.count(sevError) == 0:
    for l in lines:
      s.write l
      s.write nl

proc writeP1*(f: P1File, path: string, opts = P1WriteOptions()): DiagLog =
  ## Writes `f` to `path` through `<path>.tmp`, renamed on success.
  let tmp = path & ".tmp"
  let s = newFileStream(tmp, fmWrite)
  if s == nil:
    result.report(sevFatal, dcIo, "cannot create " & tmp, loc = Location(file: path))
  else:
    try:
      result = writeP1(f, s, opts)
    finally:
      s.close()
    if result.count(sevError) == 0: moveFile(tmp, path)
    else: removeFile(tmp)

proc p1Text*(f: P1File, opts = P1WriteOptions()): (string, DiagLog) =
  ## `f` written to a string, with the writer's diagnostics.
  let s = newStringStream()
  let log = writeP1(f, s, opts)
  (s.data, log)
