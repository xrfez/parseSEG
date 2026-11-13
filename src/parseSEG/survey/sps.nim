## SPS (Shell Processing Support) survey files: Rev 1.0 (1993) and Rev 2.1
## (2006). Spec note: `docs/spec/sps.md`.
##
## An SPS survey is a set of files that share one block of header (H)
## records: receiver points (R), source points (S), relations (X: field
## record and channel → source and receiver stations; O: the same layout in
## the receiver domain, see `SpsRelation`) and, optionally, comments (C). `readSps` reads any of them (or a file mixing them) into one
## `SpsFile`; `writeSps` writes the records back, column-exact.
##
## Reading never stops on a bad record: each problem is a diagnostic in
## `SpsFile.log` (location `record` = 0-based line number), and the line is
## kept raw. Every record keeps its raw text, so an unedited record is
## written back byte for byte (`SpsOptions.keepRaw = false` reads the values
## only, in less memory). A file is read in chunks and each record parsed
## where it lies: about 200 MB/s.
##
## Decisions on the spec's open points (`docs/spec/sps.md` §11):
## - Rev 2.1 F10.2 fields without a `.` read as integers (`5646` = 5646.0);
##   `SpsOptions.strictImpliedDecimals` reads them the FORTRAN way (56.46).
## - Rev 1.0 line and point names are text; `line`/`point` hold their numeric
##   value when the name is a number, else NaN (see `survey/join` for line
##   name maps).
## - The revision comes from H00 (`SPS 2.1` / `SPS001`, also `SPS V1.0`,
##   `SPS REV 2.1`), else from the column layout of the first data records
##   (a warning says which was taken), unless the caller sets it.

import std/[options, streams, strutils, math, os]
import ../common/[diagnostics, errors, outputfile]
import ./[textrec, cards, linespans]

export textrec, diagnostics

type
  SpsRevision* = enum
    spsAuto = "auto"  ## Detect (only as an option).
    sps10 = "1.0"     ## SEG 1993 (original Shell format).
    sps21 = "2.1"     ## Rev 2.1 (2006).

  SpsHeader* = object
    ## An H record: `code` is cols 2-4 trimmed (`"00"`, `"021"`, `"400"`).
    code*: string
    description*: string ## Cols 5-32, trailing blanks trimmed.
    data*: string        ## Cols 33-80, trailing blanks trimmed (H26: cols 5-80).
    raw*: string         ## The line as read; "" for a built record.

  SpsPointKind* = enum
    ## The record type of a point record (column 1).
    pkReceiver = "R"
    pkSource = "S"

  SpsPoint* = object
    ## An R (receiver) or S (source) point record. Missing numbers are NaN,
    ## missing day/time parts -1.
    kind*: SpsPointKind
    lineName*: string    ## The line field as text (trimmed).
    pointName*: string   ## The point field as text (trimmed).
    line*, point*: float64 ## Numeric line and point; NaN for non-numeric 1.0 names.
    index*: int          ## Point index 1-9 (blank reads as 1).
    code*: string        ## Point code (A2, trimmed).
    staticCorrection*: float64 ## ms.
    pointDepth*: float64
    seismicDatum*: float64
    upholeTime*: float64 ## ms.
    waterDepth*: float64
    easting*, northing*: float64 ## Grid units (H20).
    elevation*: float64
    dayOfYear*: int
    hour*, minute*, second*: int
    raw*: string

  SpsRelation* = object
    ## An X record: channels `fromChannel..toChannel` (step
    ## `channelIncrement`) of field record `fieldRecord` were recorded from
    ## receivers `fromReceiver..toReceiver` on `rcvLine`, shot at
    ## (`srcLine`, `srcPoint`, `srcIndex`).
    ##
    ## An O record (receiver domain, `recordType` `'O'`) has the same layout
    ## with the roles swapped: traces `fromChannel..toChannel` of gather
    ## `fieldRecord` were recorded at the receiver in the source fields, from
    ## the sources `fromReceiver..toReceiver` on `rcvLine` (see
    ## `survey/join`). Files named `.ops` often hold O relations as `X`
    ## records.
    recordType*: char = 'X' ## `X`, or `O` for a receiver-domain record.
    fieldTape*: string
    fieldRecord*: int64
    recordIncrement*: int
    instrumentCode*: char
    srcLineName*, srcPointName*: string
    srcLine*, srcPoint*: float64
    srcIndex*: int
    fromChannel*, toChannel*: int64
    channelIncrement*: int
    rcvLineName*, fromReceiverName*, toReceiverName*: string
    rcvLine*, fromReceiver*, toReceiver*: float64
    rcvIndex*: int
    raw*: string

  SpsFile* = object
    ## The records of one or more SPS files, in file order per kind.
    name*: string         ## Path or name, for diagnostics.
    revision*: SpsRevision = sps21
      ## The layout of the records: `sps10` or `sps21` (a built file is 2.1
      ## unless it says otherwise; `spsAuto` counts as 2.1).
    revisionDeclared*: bool ## The revision came from H00.
    layout*: TextLayout
    crlf*: bool           ## Lines ended in CR LF (the spec's disk layout).
    headers*: seq[SpsHeader]
    points*: seq[SpsPoint]       ## R and S records.
    relations*: seq[SpsRelation] ## X records.
    comments*: seq[string]       ## C records (cols 2-80).
    others*: seq[string]         ## Blank, `EOF` and unknown lines, kept raw.
    options*: SpsOptions         ## How the file was read (decimals mode, revision).
    finalNewline*: bool = true   ## The last line had a terminator.
    order*: seq[SpsEntry]        ## Every record in file order, for writing.
    log*: DiagLog

  SpsEntryKind* = enum
    ## The list a record of the file went to (see `SpsEntry`).
    seHeader   ## `headers`
    sePoint    ## `points`
    seRelation ## `relations`
    seComment  ## `comments`
    seOther    ## `others`

  SpsEntry* = object
    ## Where record N of the file went: `kind` and the index in its list.
    ## `seOther` lines (blank, `EOF`, unparsable) are kept in `others`.
    kind*: SpsEntryKind
    at*: int

  SpsOptions* = object
    ## How `readSps` reads a file.
    revision*: SpsRevision = spsAuto ## Force a revision.
    strictImpliedDecimals*: bool     ## F10.2 without `.`: FORTRAN-implied decimals.
    layout*: TextLayout = tlLines    ## Used only with `forceLayout`.
    forceLayout*: bool               ## Don't detect the layout.
    keepRaw*: bool = true
      ## Keep the text of every R, S, X and O record (`raw`), so that
      ## `writeSps` writes unedited records back byte for byte. Without it a
      ## read takes about half the memory, and written records are encoded
      ## from their values; `SurveyGeometry.addSps(path)` reads that way.

func initSpsPoint*(kind = pkSource): SpsPoint =
  ## A point with every value missing (index 1).
  SpsPoint(kind: kind, line: NaN, point: NaN, index: 1, staticCorrection: NaN, pointDepth: NaN,
    seismicDatum: NaN, upholeTime: NaN, waterDepth: NaN, easting: NaN, northing: NaN,
    elevation: NaN, dayOfYear: -1, hour: -1, minute: -1, second: -1)

func initSpsRelation*(): SpsRelation =
  ## A relation with every value missing (increments and indices 1).
  SpsRelation(recordType: 'X', fieldRecord: MissingInt, recordIncrement: 1, instrumentCode: '1', srcLine: NaN,
    srcPoint: NaN, srcIndex: 1, fromChannel: MissingInt, toChannel: MissingInt,
    channelIncrement: 1, rcvLine: NaN, fromReceiver: NaN, toReceiver: NaN, rcvIndex: 1)

# ------------------------------------------------------------- column maps --

type
  PointCols = object
    line, point, index, code, statics, depth, datum, uphole, water: Slice[int]

  RelCols = object
    tape, rec, recInc, instr, srcLine, srcPoint, srcIndex, fromCh, toCh, chInc, rcvLine,
      fromRcv, toRcv, rcvIndex: Slice[int]

const
  pointCols: array[sps10..sps21, PointCols] = [
    PointCols(line: 2..17, point: 18..25, index: 26..26, code: 27..28, statics: 29..32,
      depth: 33..36, datum: 37..40, uphole: 41..42, water: 43..46),
    PointCols(line: 2..11, point: 12..21, index: 24..24, code: 25..26, statics: 27..30,
      depth: 31..34, datum: 35..38, uphole: 39..40, water: 41..46)]
  relCols: array[sps10..sps21, RelCols] = [
    RelCols(tape: 2..7, rec: 8..11, recInc: 12..12, instr: 13..13, srcLine: 14..29,
      srcPoint: 30..37, srcIndex: 38..38, fromCh: 39..42, toCh: 43..46, chInc: 47..47,
      rcvLine: 48..63, fromRcv: 64..71, toRcv: 72..79, rcvIndex: 80..80),
    RelCols(tape: 2..7, rec: 8..15, recInc: 16..16, instr: 17..17, srcLine: 18..27,
      srcPoint: 28..37, srcIndex: 38..38, fromCh: 39..43, toCh: 44..48, chInc: 49..49,
      rcvLine: 50..59, fromRcv: 60..69, toRcv: 70..79, rcvIndex: 80..80)]
  # Columns 47-80 of point records are the same in both revisions.
  eastingCols = 47..55
  northingCols = 56..65
  elevationCols = 66..71
  dayCols = 72..74

# ------------------------------------------------------------------ reading --

type Ctx = object
  ## Where a record is being parsed; problems go to the `log` passed along,
  ## the first few of each code and field (`cap`).
  name: string
  offset: int64 ## Of the record in the stream.
  index: int    ## 0-based record (line) number.
  opts: SpsOptions
  cap: RepeatCap

template problem(x: var Ctx, log: var DiagLog, sev: Severity, code: DiagCode, where,
    msg: string) =
  # A diagnostic for field `where` of the current record; `msg` is built
  # only when it is logged.
  if x.cap.admit(code, where):
    log.report(sev, code, msg, x.offset, Location(file: x.name, record: x.index, field: where))

# The field readers take the record as a view and a field as its columns,
# and name it by a record letter and a suffix (`'R'`, `".easting"`), so a
# good field costs no string: a padded copy of the columns and a label per
# field were most of the parse.

proc numberAt(x: var Ctx, log: var DiagLog, line: openArray[char], f: Slice[int],
    kind: char, name: string, decimals: int, rev: SpsRevision): float64 =
  ## A real field, `f` being its `trimmed` columns; bad text is a warning and
  ## NaN. In Rev 2.1, `decimals` only applies in strict mode (else a value
  ## without `.` is an integer).
  let d = if rev == sps21 and not x.opts.strictImpliedDecimals: 0 else: decimals
  if not line.fortranFloat(f, d, result):
    result = NaN
    var dashes = true # "----": undefined
    for i in f.a .. f.b:
      if line[i] != '-': dashes = false
    if not dashes:
      x.problem(log, sevWarning, dcBadValue, kind & name,
        "not a number: '" & line.fieldText(f) & "'")

proc numberField(x: var Ctx, log: var DiagLog, line: openArray[char], cols: Slice[int],
    kind: char, name: string, decimals: int, rev: SpsRevision): float64 {.inline.} =
  x.numberAt(log, line, line.trimmed(cols.a, cols.b), kind, name, decimals, rev)

proc intField(x: var Ctx, log: var DiagLog, line: openArray[char], cols: Slice[int],
    kind: char, name: string, default: int64): int64 =
  let f = line.trimmed(cols.a, cols.b)
  if not line.fortranInt(f, result):
    x.problem(log, sevWarning, dcBadValue, kind & name,
      "not an integer: '" & line.fieldText(f) & "'")
    result = MissingInt
  elif result == MissingInt: result = default

proc smallField(x: var Ctx, log: var DiagLog, line: openArray[char], cols: Slice[int],
    kind: char, name: string, default: int): int =
  let v = x.intField(log, line, cols, kind, name, default)
  if v == MissingInt: default else: int(v)

proc nameField(x: var Ctx, log: var DiagLog, line: openArray[char], cols: Slice[int],
    kind: char, name: string, rev: SpsRevision, text: var string, value: var float64) =
  ## A line or point: text in 1.0 (numeric value when it is a number), F10.2
  ## in 2.1.
  let f = line.trimmed(cols.a, cols.b)
  text = line.fieldText(f)
  if rev == sps10:
    if not line.fortranFloat(f, 0, value): value = NaN
  else:
    value = x.numberAt(log, line, f, kind, name, 2, rev)

proc parsePoint(x: var Ctx, log: var DiagLog, line: openArray[char], rev: SpsRevision,
    keepRaw = true): SpsPoint =
  let cols = pointCols[rev]
  let k = line[0]
  result = initSpsPoint(if k == 'R': pkReceiver else: pkSource)
  x.nameField(log, line, cols.line, k, ".line", rev, result.lineName, result.line)
  x.nameField(log, line, cols.point, k, ".point", rev, result.pointName, result.point)
  if result.lineName.len == 0: x.problem(log, sevWarning, dcBadValue, k & ".line", "no line")
  if result.pointName.len == 0: x.problem(log, sevWarning, dcBadValue, k & ".point", "no point")
  result.index = x.smallField(log, line, cols.index, k, ".index", 1)
  result.code = line.fieldText(line.trimmed(cols.code.a, cols.code.b))
  result.staticCorrection = x.numberField(log, line, cols.statics, k, ".staticCorrection", 0, rev)
  result.pointDepth = x.numberField(log, line, cols.depth, k, ".pointDepth", 1, rev)
  result.seismicDatum = x.numberField(log, line, cols.datum, k, ".seismicDatum", 0, rev)
  result.upholeTime = x.numberField(log, line, cols.uphole, k, ".upholeTime", 0, rev)
  # 1.0 writes water depth as "99.9" or "999" (no implied decimal).
  result.waterDepth = x.numberField(log, line, cols.water, k, ".waterDepth",
    (if rev == sps10: 0 else: 1), rev)
  result.easting = x.numberField(log, line, eastingCols, k, ".easting", 1, rev)
  result.northing = x.numberField(log, line, northingCols, k, ".northing", 1, rev)
  result.elevation = x.numberField(log, line, elevationCols, k, ".elevation", 1, rev)
  result.dayOfYear = x.smallField(log, line, dayCols, k, ".dayOfYear", -1)
  var t: array[6, char] # columns 75-80, blank past the end of the line
  var blank = true
  for i in 0 .. 5:
    t[i] = line.colChar(75 + i)
    if t[i] != ' ': blank = false
  if not blank:
    # 3I2: a blank stands for a leading zero (" 91530" is 09:15:30).
    var parts: array[3, int]
    var valid = true
    for i in 0 .. 2:
      let (a, b) = (t[2 * i], t[2 * i + 1])
      if b in Digits and a in Digits + {' '}:
        parts[i] = (if a == ' ': 0 else: ord(a) - ord('0')) * 10 + ord(b) - ord('0')
      elif a == ' ' and b == ' ': parts[i] = 0
      else: valid = false
    if valid:
      (result.hour, result.minute, result.second) = (parts[0], parts[1], parts[2])
      if result.hour > 23 or result.minute > 59 or result.second > 59:
        x.problem(log, sevWarning, dcBadValue, k & ".time", "time out of range: " & t.join)
    else:
      x.problem(log, sevWarning, dcBadValue, k & ".time", "not hhmmss: '" & t.join & "'")
  if result.index notin 1..9:
    x.problem(log, sevWarning, dcBadValue, k & ".index", "point index " & $result.index &
      " is not 1-9")
  if result.easting.isNaN or result.northing.isNaN:
    x.problem(log, sevWarning, dcBadValue, k & ".easting", "no coordinates")
  if keepRaw: result.raw = line.fieldText(0 .. line.high)

proc parseRelation(x: var Ctx, log: var DiagLog, line: openArray[char], rev: SpsRevision,
    keepRaw = true): SpsRelation =
  let cols = relCols[rev]
  const k = 'X' # O records are reported under the X names too
  result = initSpsRelation()
  result.recordType = line[0]
  result.fieldTape = line.fieldText(line.trimmed(cols.tape.a, cols.tape.b))
  result.fieldRecord = x.intField(log, line, cols.rec, k, ".fieldRecord", MissingInt)
  result.recordIncrement = x.smallField(log, line, cols.recInc, k, ".recordIncrement", 1)
  let ic = line.colChar(cols.instr.a)
  result.instrumentCode = if ic == ' ': '1' else: ic
  x.nameField(log, line, cols.srcLine, k, ".srcLine", rev, result.srcLineName, result.srcLine)
  x.nameField(log, line, cols.srcPoint, k, ".srcPoint", rev, result.srcPointName,
    result.srcPoint)
  result.srcIndex = x.smallField(log, line, cols.srcIndex, k, ".srcIndex", 1)
  result.fromChannel = x.intField(log, line, cols.fromCh, k, ".fromChannel", MissingInt)
  result.toChannel = x.intField(log, line, cols.toCh, k, ".toChannel", MissingInt)
  result.channelIncrement = x.smallField(log, line, cols.chInc, k, ".channelIncrement", 1)
  x.nameField(log, line, cols.rcvLine, k, ".rcvLine", rev, result.rcvLineName, result.rcvLine)
  x.nameField(log, line, cols.fromRcv, k, ".fromReceiver", rev, result.fromReceiverName,
    result.fromReceiver)
  x.nameField(log, line, cols.toRcv, k, ".toReceiver", rev, result.toReceiverName,
    result.toReceiver)
  result.rcvIndex = x.smallField(log, line, cols.rcvIndex, k, ".rcvIndex", 1)
  if result.fieldRecord == MissingInt:
    x.problem(log, sevWarning, dcBadValue, "X.fieldRecord", "no field record number")
  if result.fromChannel == MissingInt or result.toChannel == MissingInt:
    x.problem(log, sevWarning, dcBadValue, "X.fromChannel", "no channel range")
  elif result.channelIncrement < 1:
    x.problem(log, sevWarning, dcBadValue, "X.channelIncrement", "channel increment " &
      $result.channelIncrement & " is not 1-9")
  elif result.toChannel < result.fromChannel or
      (result.toChannel - result.fromChannel) mod result.channelIncrement != 0:
    x.problem(log, sevWarning, dcInconsistent, "X.toChannel", "channels " & $result.fromChannel &
      ".." & $result.toChannel & " are not a run with increment " & $result.channelIncrement)
  if keepRaw: result.raw = line.fieldText(0 .. line.high)

proc parseHeader(line: string): SpsHeader =
  result.code = line.col(2, 4).strip
  if result.code == "26":
    result.data = line.col(5, max(80, line.len)).strip(leading = false)
  else:
    result.description = line.col(5, 32).strip(leading = false)
    result.data = line.col(33, max(80, line.len)).strip(leading = false)
  result.raw = line

func revisionFromH00(data: string): (bool, SpsRevision) =
  ## The revision an H00 record declares: `SPS001,<date>` (1.0) or `SPS 2.1;`
  ## (2.1), and the spellings in use (`SPS 1.0`, `SPS V1.0`, `SPS REV 2.1`,
  ## `SPS Revision 2.1`); blanks and case are ignored. 1.0 dates such as
  ## `12.10.90` contain "2.1", so the number is matched right after its
  ## `SPS` prefix.
  var d = ""
  for c in data:
    if c != ' ': d.add c.toUpperAscii
  if not d.startsWith("SPS"): return (false, sps21)
  var i = 3
  for word in ["REVISION", "VERSION", "REV", "VER", "V"]:
    if i == 3 and d.continuesWith(word, i): i += word.len
  if i > 3 and i < d.len and d[i] == '.': inc i # "REV. 1.0"
  let next = if i + 1 < d.len: d[i + 1] else: ';'
  if d.continuesWith("001", i): (true, sps10)
  elif d.continuesWith("2.1", i) and (i + 3 >= d.len or d[i + 3] notin Digits): (true, sps21)
  elif d.continuesWith("1", i) and next notin Digits: (true, sps10) # "1.0", "1,", "1;"
  else: (false, sps21)

func rightInt(line: string, first, last: int): bool =
  # An `Iw` field in columns `first..last`: digits ending in the last
  # column, with at most a sign and blanks before them.
  if line.colChar(last) notin Digits: return false
  var i = last
  while i >= first and line.colChar(i) in Digits: dec i
  if i >= first and line.colChar(i) in {'-', '+'}: dec i
  while i >= first:
    if line.colChar(i) != ' ': return false
    dec i
  true

func layoutScore(line: string): int =
  ## 1 when a data record's columns fit the Rev 2.1 layout better, -1 for
  ## Rev 1.0, 0 when they fit both alike. Each layout has structural rules
  ## (where its fields end, which columns are blank, digits or letters), and
  ## the record votes for the layout whose rules it satisfies more of.
  ## Counting numeric fields instead read 1.0 files with numeric line names,
  ## five-digit points or relation records as 2.1.
  var s21, s10 = 0
  template rule(v: var int, cond: bool) =
    if cond: inc v
  const digitOrBlank = Digits + {' '}
  case line[0]
  of 'R', 'S':
    # 2.1: F10.2 line and point right-justified in 2-11 and 12-21, 22-23
    # blank, index 24, code 25-26, static I4 27-30.
    let line21 = parseFortranFloat(line.col(2, 11)).get(NaN)
    rule s21, line.colChar(11) != ' '
    rule s21, line.colChar(21) != ' '
    rule s21, line.col(22, 23).isBlank
    rule s21, line.colChar(24) in digitOrBlank
    rule s21, line.colChar(25) in Letters
    rule s21, line.colChar(27) notin Letters
    rule s21, line21.classify == fcNormal or line.col(2, 11).strip == "0"
    # 1.0: line name left-justified from 2, point right-justified in 18-25,
    # index 26, code 27-28.
    rule s10, line.colChar(2) != ' '
    rule s10, line.colChar(25) != ' ' or line.colChar(18) != ' '
    rule s10, line.colChar(26) in digitOrBlank
    rule s10, line.colChar(27) in Letters
    rule s10, line.colChar(28) != ' '
    rule s10, line.col(12, 17).isBlank or line.colChar(11) != ' ' # a name has no inner gap
    rule s10, line.colChar(25) notin Letters or line.colChar(24) in Letters
  of 'X', 'O':
    # 2.1: record I8 in 8-15, increment 16, line F10.2 ending in 27,
    # channels I5 in 39-43 and 44-48, increment 49, receivers ending in 59, 69.
    rule s21, rightInt(line, 8, 15)
    rule s21, line.colChar(16) in digitOrBlank
    rule s21, line.colChar(27) != ' '
    rule s21, rightInt(line, 39, 43)
    rule s21, rightInt(line, 44, 48)
    rule s21, line.colChar(49) in digitOrBlank
    rule s21, line.colChar(59) != ' '
    rule s21, line.colChar(69) != ' '
    # 1.0: record I4 in 8-11, increment 12, line name from 14, channels I4
    # in 39-42 and 43-46, increment 47, receiver line name from 48.
    rule s10, rightInt(line, 8, 11)
    rule s10, line.colChar(12) in digitOrBlank
    rule s10, line.colChar(14) != ' '
    rule s10, rightInt(line, 39, 42)
    rule s10, rightInt(line, 43, 46)
    rule s10, line.colChar(47) in digitOrBlank
    rule s10, line.colChar(48) != ' '
    rule s10, line.colChar(71) != ' '
  else: discard
  cmp(s21, s10)

proc readRecords(s: Stream, name: string, opts: SpsOptions, expected: int): SpsFile =
  # `readSps`; `expected` is about how many records the stream holds (0 if
  # unknown), to size the lists once.
  result = SpsFile(name: name)
  skipBom(s)
  result.layout = if opts.forceLayout: opts.layout else: openLayout(s)
  # The revision is needed before data records are parsed: decide it from
  # H00 or the first data records, then rewind.
  let start = s.getPosition
  var rev = opts.revision
  if rev == spsAuto:
    var score, seen = 0
    for r in textRecords(s, result.layout):
      if r.text.len > 0:
        if r.text[0] == 'H' and r.text.col(2, 4).strip == "00":
          let (found, rv) = revisionFromH00(r.text.col(33, 80))
          if found:
            rev = rv
            result.revisionDeclared = true
            break
        elif r.text[0] in {'R', 'S', 'X', 'O'}:
          score += layoutScore(r.text)
          inc seen
          if seen >= 50: break
    if rev == spsAuto:
      rev = if score >= 0: sps21 else: sps10
      # A guess the caller should see: the two layouts share few columns,
      # so a wrong one reads every line, point and channel from other bytes.
      result.log.report(sevWarning, dcUnsupportedRevision, "no SPS revision in H00; read as " &
        $rev & " from the column layout (set SpsOptions.revision to choose)",
        loc = Location(file: name))
    s.setPosition(start)
  result.revision = rev
  result.options = opts
  result.options.revision = rev
  var x = Ctx(name: name, opts: opts)
  template take(line: untyped, lineOffset: int64, lineNumber: int, isCrlf, isTerminated,
      isCut: bool) =
    # One record: `line` is a view of its text.
    (x.offset, x.index) = (lineOffset, lineNumber)
    if lineNumber == 0: result.crlf = isCrlf
    result.finalNewline = isTerminated
    if isCut:
      x.problem(result.log, sevWarning, dcBadValue, "", "line longer than " & $MaxLineBytes &
        " bytes; cut into records (is this a text file?)")
    if line.len == 0 or line.allBlank:
      result.order.add SpsEntry(kind: seOther, at: result.others.len)
      result.others.add line.fieldText(0 .. line.high)
    else:
      case line[0]
      of 'H':
        result.order.add SpsEntry(kind: seHeader, at: result.headers.len)
        result.headers.add parseHeader(line.fieldText(0 .. line.high))
      of 'R', 'S':
        if result.points.len == 0 and expected > result.order.len:
          result.points = newSeqOfCap[SpsPoint](expected - result.order.len)
        result.order.add SpsEntry(kind: sePoint, at: result.points.len)
        result.points.add x.parsePoint(result.log, line, rev, opts.keepRaw)
      of 'X', 'O':
        if result.relations.len == 0 and expected > result.order.len:
          result.relations = newSeqOfCap[SpsRelation](expected - result.order.len)
        result.order.add SpsEntry(kind: seRelation, at: result.relations.len)
        result.relations.add x.parseRelation(result.log, line, rev, opts.keepRaw)
      of 'C':
        result.order.add SpsEntry(kind: seComment, at: result.comments.len)
        result.comments.add line.fieldText(1 .. line.high)
      else:
        if not (line.len >= 3 and line[0] == 'E' and line[1] == 'O' and line[2] == 'F'):
          x.problem(result.log, sevWarning, dcBadValue, "recordId", "unknown record type '" &
            line[0] & "'; kept raw")
        result.order.add SpsEntry(kind: seOther, at: result.others.len)
        result.others.add line.fieldText(0 .. line.high)
      if line.len > 80 and not line.toOpenArray(80, line.high).allBlank:
        x.problem(result.log, sevInfo, dcBadValue, "",
          "record longer than 80 columns (" & $line.len & ")")
  try:
    # A file of one kind of record is the rule: room for its records at once
    # (a seq that grows by doubling held three times its final size meanwhile).
    if expected > 0: result.order = newSeqOfCap[SpsEntry](expected)
    if result.layout == tlLines:
      # Each line parsed where it lies in the chunk it was read in.
      var buf: string
      for span in lineSpans(s, buf, MaxLineBytes):
        take(buf.toOpenArray(span.lo, span.hi), span.offset, span.index, span.crlf,
          span.terminated, span.cut)
    else:
      for r in textRecords(s, result.layout):
        take(r.text.toOpenArray(0, r.text.high), r.offset, r.index, r.crlf, r.terminated, r.cut)
  except IOError, OSError:
    result.log.report(sevFatal, dcIo, getCurrentExceptionMsg(), loc = Location(file: name))
  x.cap.summarize(result.log, name)

proc readSps*(s: Stream, name = "", opts = SpsOptions()): SpsFile =
  ## Reads SPS records from `s`. Problems are in `result.log` (the first few
  ## of each code and field, then a count); only an I/O failure ends the
  ## read early (fatal).
  readRecords(s, name, opts, expected = 0)

proc looksLikeSps*(s: Stream, maxRecords = 200): bool =
  ## Whether `s` holds SPS rather than SEG P1 records, judged from the data
  ## records of its first `maxRecords` records: SPS point records have a
  ## record letter (R, S) and grid coordinates in columns 47-65, relation
  ## records (X) channel numbers in 39-48; P1 data records start with a blank and
  ## have hemisphere letters in columns 35 and 45. Rewinds `s`.
  let start = s.getPosition
  skipBom(s)
  var sps, p1 = 0
  for r in textRecords(s, openLayout(s)):
    let t = r.text
    if t.len > 0:
      case t[0]
      of 'R', 'S':
        let (e, n) = (parseFortranFloat(t.col(47, 55), 1), parseFortranFloat(t.col(56, 65), 1))
        if e.isSome and n.isSome and not (e.get.isNaN or n.get.isNaN):
          inc sps
      of 'X', 'O':
        if t.col(39, 48).strip.len > 0 and t.col(39, 48).strip.allCharsInSet(Digits + {' '}):
          inc sps
      of ' ':
        if t.colChar(35) in {'N', 'S'} and t.colChar(45) in {'E', 'W'}: inc p1
      else: discard
    if r.index >= maxRecords: break
  s.setPosition(start)
  sps > p1

proc readSps*(path: string, opts = SpsOptions()): SpsFile =
  ## Reads the SPS file at `path` (streamed, never loaded whole). A file
  ## that cannot be opened gives a fatal diagnostic and no records.
  let s = newFileStream(path, fmRead)
  if s == nil:
    result = SpsFile(name: path)
    result.log.report(sevFatal, dcIo, "cannot open " & path, loc = Location(file: path))
  else:
    try:
      # Cards are 80 columns and a line end.
      let size = try: getFileSize(path) except OSError: 0'i64
      result = readRecords(s, path, opts, expected = int(size div 82))
    finally: s.close()

proc parseSps*(text: string, name = "", opts = SpsOptions()): SpsFile =
  ## Reads SPS records from a string.
  readSps(newStringStream(text), name, opts)

# ------------------------------------------------------------------ writing --

type
  SpsWriteOptions* = object
    revision*: SpsRevision = spsAuto ## Target revision; `spsAuto` keeps the file's.
    lineEnding*: string              ## "" keeps the file's (CR LF if it had them, else LF).
    lenient*: bool                   ## Write records that fail to encode as read (raw).

func numText(v: float64): string =
  ## A short text for a numeric name: integers without a fraction.
  if v == round(v) and abs(v) < 1e15: $int64(v) else: $v

proc fixed(v: float64, width, decimals: int, field: string): string =
  fit(formatFixed(v, width, decimals), width, field)

proc whole(v: float64, width: int, field: string): string =
  if v.isNaN: repeat(' ', width)
  elif v != round(v): raiseFormat(field & ": " & $v & " is not an integer")
  elif abs(v) >= 1e15: raiseFormat(field & ": value does not fit in " & $width & " columns")
  else: fit(formatInt(int64(v), width), width, field)

proc digit(v: int, field: string): string =
  if v notin 0..9: raiseFormat(field & ": " & $v & " is not one digit")
  $v

proc nameText(name: string, v: float64, width: int, rev: SpsRevision, left: bool,
    field: string): string =
  ## A line or point field: F10.2 in 2.1; in 1.0 the name when it still
  ## matches the value (keeps "0225"), else the number.
  if rev == sps21:
    if v.isNaN: raiseFormat(field & ": not numeric ('" & name & "'); Rev 2.1 needs F10.2")
    result = fixed(v, width, 2, field)
  else:
    let keep = name.len in 1..width and (v.isNaN or parseFortranFloat(name) == some(v))
    let t = if keep: name elif v.isNaN: "" else: numText(v)
    if t.len == 0: raiseFormat(field & ": missing")
    result = fit(t, width, field)
    result = if left: alignLeft(result, width) else: align(result, width)

proc checkTarget(rev: SpsRevision) =
  if rev notin {sps10, sps21}:
    raise newException(ValueError, "encode for SPS 1.0 or 2.1, not " & $rev)

proc encodeSps*(p: SpsPoint, rev: SpsRevision): string =
  ## The 80-column text of `p` in revision `rev`; raises `SegFormatError`
  ## when a value does not fit its field, `ValueError` for `spsAuto`.
  checkTarget(rev)
  let cols = pointCols[rev]
  let k = $p.kind
  result = repeat(' ', 80)
  result[0] = k[0]
  result.putCol(cols.line.a, nameText(p.lineName, p.line, cols.line.len, rev, true, k & ".line"))
  result.putCol(cols.point.a, nameText(p.pointName, p.point, cols.point.len, rev, false,
    k & ".point"))
  result.putCol(cols.index.a, digit(p.index, k & ".index"))
  if p.code.len > 2: raiseFormat(k & ".code: more than 2 characters")
  result.putCol(cols.code.a, alignLeft(p.code, 2))
  result.putCol(cols.statics.a, whole(p.staticCorrection, cols.statics.len,
    k & ".staticCorrection"))
  result.putCol(cols.depth.a, fixed(p.pointDepth, cols.depth.len, 1, k & ".pointDepth"))
  result.putCol(cols.datum.a, whole(p.seismicDatum, cols.datum.len, k & ".seismicDatum"))
  result.putCol(cols.uphole.a, whole(p.upholeTime, cols.uphole.len, k & ".upholeTime"))
  let water = if rev == sps10 and p.waterDepth == round(p.waterDepth) and
                  formatFixed(p.waterDepth, 4, 1).len == 0:
                whole(p.waterDepth, 4, k & ".waterDepth") # 1.0: "999"
              else: fixed(p.waterDepth, cols.water.len, 1, k & ".waterDepth")
  result.putCol(cols.water.a, water)
  result.putCol(eastingCols.a, fixed(p.easting, eastingCols.len, 1, k & ".easting"))
  result.putCol(northingCols.a, fixed(p.northing, northingCols.len, 1, k & ".northing"))
  result.putCol(elevationCols.a, fixed(p.elevation, elevationCols.len, 1, k & ".elevation"))
  result.putCol(dayCols.a, whole(if p.dayOfYear < 0: NaN else: float64(p.dayOfYear), 3,
    k & ".dayOfYear"))
  if p.hour >= 0:
    if p.hour > 99 or p.minute notin 0..99 or p.second notin 0..99:
      raiseFormat(k & ".time: not hhmmss")
    result.putCol(75, align($p.hour, 2, '0') & align($p.minute, 2, '0') &
      align($p.second, 2, '0'))

proc encodeSps*(r: SpsRelation, rev: SpsRevision): string =
  ## The 80-column text of `r` in revision `rev`; raises `SegFormatError`
  ## when a value does not fit its field, `ValueError` for `spsAuto`.
  checkTarget(rev)
  let cols = relCols[rev]
  if r.recordType notin {'X', 'O'}:
    raiseFormat("X.recordType: '" & $r.recordType & "' is not X or O")
  result = repeat(' ', 80)
  result[0] = r.recordType
  result.putCol(cols.tape.a, alignLeft(fit(r.fieldTape & (if r.fieldTape.len == 0: " " else: ""),
    cols.tape.len, "X.fieldTape"), cols.tape.len))
  result.putCol(cols.rec.a, fit(formatInt(r.fieldRecord, cols.rec.len), cols.rec.len,
    "X.fieldRecord"))
  result.putCol(cols.recInc.a, digit(r.recordIncrement, "X.recordIncrement"))
  result.putCol(cols.instr.a, $r.instrumentCode)
  result.putCol(cols.srcLine.a, nameText(r.srcLineName, r.srcLine, cols.srcLine.len, rev, true,
    "X.srcLine"))
  result.putCol(cols.srcPoint.a, nameText(r.srcPointName, r.srcPoint, cols.srcPoint.len, rev,
    false, "X.srcPoint"))
  result.putCol(cols.srcIndex.a, digit(r.srcIndex, "X.srcIndex"))
  result.putCol(cols.fromCh.a, fit(formatInt(r.fromChannel, cols.fromCh.len), cols.fromCh.len,
    "X.fromChannel"))
  result.putCol(cols.toCh.a, fit(formatInt(r.toChannel, cols.toCh.len), cols.toCh.len,
    "X.toChannel"))
  result.putCol(cols.chInc.a, digit(r.channelIncrement, "X.channelIncrement"))
  result.putCol(cols.rcvLine.a, nameText(r.rcvLineName, r.rcvLine, cols.rcvLine.len, rev, true,
    "X.rcvLine"))
  result.putCol(cols.fromRcv.a, nameText(r.fromReceiverName, r.fromReceiver, cols.fromRcv.len,
    rev, false, "X.fromReceiver"))
  result.putCol(cols.toRcv.a, nameText(r.toReceiverName, r.toReceiver, cols.toRcv.len, rev,
    false, "X.toReceiver"))
  result.putCol(cols.rcvIndex.a, digit(r.rcvIndex, "X.rcvIndex"))

proc encodeSps*(h: SpsHeader): string =
  ## The text of an H record (data past column 80 is kept).
  if h.code.len == 0 or h.code.len > 3: raiseFormat("H.code: '" & h.code & "' is not 2-3 digits")
  result = "H" & alignLeft(h.code, 3)
  if h.code == "26": result.add h.data
  else:
    if h.description.len > 28: raiseFormat("H" & h.code & ".description: more than 28 columns")
    result.add alignLeft(h.description, 28) & h.data

func quietCtx(strict: bool): Ctx =
  # Re-parses a record to compare it; its diagnostics are not made.
  Ctx(opts: SpsOptions(strictImpliedDecimals: strict), cap: RepeatCap(quiet: true))

proc pointLine(p: SpsPoint, rev, fileRev: SpsRevision, strict: bool): string =
  ## The raw text when `p` is unchanged since it was read (its raw text
  ## parses to the same values), else encoded.
  if p.raw.len > 0 and rev == fileRev and p.raw[0] in {'R', 'S'}:
    var scratch: DiagLog
    var quiet = quietCtx(strict)
    if sameValues(quiet.parsePoint(scratch, p.raw, rev), p): return p.raw
  encodeSps(p, rev)

proc relationLine(r: SpsRelation, rev, fileRev: SpsRevision, strict: bool): string =
  if r.raw.len > 0 and rev == fileRev and r.raw[0] in {'X', 'O'}:
    var scratch: DiagLog
    var quiet = quietCtx(strict)
    if sameValues(quiet.parseRelation(scratch, r.raw, rev), r): return r.raw
  encodeSps(r, rev)

proc headerLine(h: SpsHeader): string =
  if h.raw.len > 0 and h.raw[0] == 'H' and sameValues(parseHeader(h.raw), h): h.raw
  else: encodeSps(h)

proc writeSps*(f: SpsFile, s: Stream, opts = SpsWriteOptions()): DiagLog =
  ## Writes `f` to `s`: records in file order (`f.order`), then any records
  ## added to the lists since. Records are validated first: a value that does
  ## not fit its field is an error, and nothing is written unless
  ## `opts.lenient` (then the record is written as read, or skipped if it
  ## has no raw text). Unchanged records are written byte for byte. Output is
  ## always text lines (fixed 80-byte or EBCDIC input comes back as lines).
  ## A file built by hand is written like one that was read; its records are
  ## Rev 2.1 unless `f.revision` says 1.0.
  let fileRev = if f.revision == spsAuto: sps21 else: f.revision
  let rev = if opts.revision == spsAuto: fileRev else: opts.revision
  let nl = if opts.lineEnding.len > 0: opts.lineEnding elif f.crlf: "\r\n" else: "\n"
  let strict = f.options.strictImpliedDecimals
  var lines: seq[string]
  var used: array[SpsEntryKind, int]
  proc fail(log: var DiagLog, i: int, msg: string) =
    log.report(if opts.lenient: sevWarning else: sevError, dcValidation, msg,
      loc = Location(file: f.name, record: i))
  proc emit(log: var DiagLog, e: SpsEntry) =
    let i = lines.len
    let size = case e.kind
      of seHeader: f.headers.len
      of sePoint: f.points.len
      of seRelation: f.relations.len
      of seComment: f.comments.len
      of seOther: f.others.len
    if e.at notin 0..<size:
      log.fail(i, "order entry " & $e.kind & " " & $e.at & " has no record (" & $size &
        " left); edit `order` together with the record lists")
      return
    try:
      case e.kind
      of seHeader:
        var h = f.headers[e.at]
        if rev != fileRev and h.code == "00":
          h.data = if rev == sps21: "SPS 2.1;" else: "SPS001;"
          h.raw = ""
          log.report(sevInfo, dcValidation, "H00 set to '" & h.data & "' for revision " & $rev,
            loc = Location(file: f.name, record: i))
        lines.add headerLine(h)
      of sePoint: lines.add pointLine(f.points[e.at], rev, fileRev, strict)
      of seRelation: lines.add relationLine(f.relations[e.at], rev, fileRev, strict)
      of seComment:
        let t = "C" & f.comments[e.at]
        lines.add t
      of seOther: lines.add f.others[e.at]
    except SegFormatError as err:
      log.fail(i, err.msg)
      let raw = case e.kind
        of seHeader: f.headers[e.at].raw
        of sePoint: f.points[e.at].raw
        of seRelation: f.relations[e.at].raw
        else: ""
      if raw.len > 0: lines.add raw
  for e in f.order:
    result.emit(e)
    used[e.kind] = max(used[e.kind], e.at + 1)
  for i in used[seHeader]..<f.headers.len: result.emit(SpsEntry(kind: seHeader, at: i))
  for i in used[sePoint]..<f.points.len: result.emit(SpsEntry(kind: sePoint, at: i))
  for i in used[seRelation]..<f.relations.len: result.emit(SpsEntry(kind: seRelation, at: i))
  for i in used[seComment]..<f.comments.len: result.emit(SpsEntry(kind: seComment, at: i))
  if result.count(sevError) == 0:
    for i, l in lines:
      s.write l
      if i < lines.len - 1 or f.finalNewline: s.write nl

proc writeSps*(f: SpsFile, path: string, opts = SpsWriteOptions()): DiagLog =
  ## Writes `f` to `path` through a new temporary file next to it, renamed on
  ## success; on
  ## validation errors nothing is written.
  let tmp = createTempFor(path, result)
  let s = if tmp.len > 0: newFileStream(tmp, fmWrite) else: nil
  if s == nil:
    if tmp.len > 0:
      result.report(sevFatal, dcIo, "cannot create " & tmp, loc = Location(file: path))
      finishOutput(tmp, path, keep = false, result)
  else:
    try:
      result = writeSps(f, s, opts)
    finally:
      s.close()
    finishOutput(tmp, path, keep = result.count(sevError) == 0, result)

proc spsText*(f: SpsFile, opts = SpsWriteOptions()): SurveyText =
  ## `f` written to a string, with the writer's diagnostics.
  let s = newStringStream()
  result.log = writeSps(f, s, opts)
  result.text = s.data
