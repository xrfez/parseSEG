## The coordinate reference system a file names, as structured values: the
## CRS, its geodetic datum and ellipsoid, the map projection and the
## vertical datum. Read from what the file gives: a SEG-Y Rev 1/2 or SEG-D
## Rev 3 Location Data stanza or OGP P1/11 header records (`parseCrsText`,
## and `crs(SeismicFile)` in `model/summary`), or SPS header records
## (`crs(SpsFile)` in `survey/sps`). Nothing is looked up: an EPSG code is
## the code the file gives, a name the name as written, and whatever the file
## does not give is unknown (an empty name, code 0, NaN). Nothing is guessed
## either: a value that does not read as its field's format is unknown, not
## read some other way.
##
## ```nim
## let c = parseCrsText("CRS type = projected\nCRS name = WGS 84 / UTM zone 31N\n" &
##   "Geodetic Datum name = World Geodetic System 1984\n")
## doAssert c.kind == ckProjected and c.datum.name == "World Geodetic System 1984"
## doAssert c.projection.methodName == "" and not c.projection.known
## ```

import std/[math, strutils, tables]

type
  CrsKind* = enum
    ## The kind of a coordinate reference system (P1/11 CRS type codes 1-7,
    ## the stanzas' `CRS type`).
    ckUnknown = "unknown"
    ckProjected = "projected"       ## Map grid: easting, northing.
    ckGeographic2D = "geographic 2D" ## Latitude, longitude.
    ckGeographic3D = "geographic 3D" ## Latitude, longitude, ellipsoidal height.
    ckGeocentric = "geocentric"
    ckVertical = "vertical"
    ckEngineering = "engineering"   ## A local grid, such as a bin grid.
    ckCompound = "compound"         ## A horizontal CRS with a vertical one.

  CrsParameter* = object
    ## One parameter of a map projection, as the file gives it.
    name*: string            ## As written (`False easting`, `scale factor`).
    value*: float64 = NaN
    unit*: string            ## As written (`metre`, `degree`); "" when not given.
    epsg*: int
      ## EPSG parameter code (8806 false easting, ...); 0 when not given (P1/11
      ## gives it; the stanzas and SPS do not).

  GeodeticDatum* = object
    ## A geodetic datum and its ellipsoid.
    name*: string            ## `World Geodetic System 1984`, `ED50`; "" when not given.
    epsg*: int               ## EPSG datum code; 0 when not given.
    ellipsoid*: string       ## Ellipsoid (SPS: spheroid) name.
    ellipsoidEpsg*: int
    semiMajorAxis*: float64 = NaN ## In `semiMajorAxisUnit` (metres when that is "").
    semiMajorAxisUnit*: string
    inverseFlattening*: float64 = NaN
    primeMeridian*: string   ## "" when not given (Greenwich, as a rule).

  MapProjection* = object
    ## A map projection: the conversion from the datum's latitude and
    ## longitude to the map grid.
    name*: string            ## `UTM zone 31N`, `Texas CS27 South Central zone`; SPS: H18 (projection type).
    epsg*: int               ## EPSG conversion code (16031 UTM zone 31N); 0 when not given.
    zone*: string            ## SPS: H19 (`Zone 30, North`); "" otherwise.
    methodName*: string      ## `Transverse Mercator`, `Lambert Conic Conformal (2SP)`.
    methodEpsg*: int         ## EPSG method code (9807 Transverse Mercator); 0 when not given.
    parameters*: seq[CrsParameter]

  CoordinateReference* = object
    ## What a file says its coordinates are referenced to. A field the file
    ## does not give is unknown: "" for text, 0 for codes, NaN for numbers.
    kind*: CrsKind
    name*: string            ## The CRS name (`WGS 84 / UTM zone 31N`).
    epsg*: int               ## The EPSG CRS code (32631); 0 when not given.
    datum*: GeodeticDatum
    projection*: MapProjection
    verticalDatum*: string   ## `Mean Sea Level`; SPS: H17 as written.
    verticalEpsg*: int       ## EPSG vertical datum code; 0 when not given.

func known*(d: GeodeticDatum): bool =
  ## The file gives anything of the datum: a name, a code, an ellipsoid, its
  ## axis or flattening, or a prime meridian.
  d.name.len > 0 or d.epsg > 0 or d.ellipsoid.len > 0 or d.ellipsoidEpsg > 0 or
    not d.semiMajorAxis.isNaN or not d.inverseFlattening.isNaN or d.primeMeridian.len > 0

func known*(p: MapProjection): bool =
  ## The file gives anything of the projection: a name, a zone, a code, a
  ## method or a parameter.
  p.name.len > 0 or p.epsg > 0 or p.zone.len > 0 or p.methodName.len > 0 or
    p.methodEpsg > 0 or p.parameters.len > 0

func known*(c: CoordinateReference): bool =
  ## The file gives anything of its coordinate reference system.
  c.kind != ckUnknown or c.name.len > 0 or c.epsg > 0 or c.datum.known or
    c.projection.known or c.verticalDatum.len > 0 or c.verticalEpsg > 0

func parameter*(p: MapProjection, name: string): float64 =
  ## The value of the parameter called `name` (case, blanks and the dots of
  ## P1/11 padding ignored); NaN when the projection has none of that name.
  func norm(s: string): string =
    for c in s:
      if c notin {' ', '.', '_', '-'}: result.add c.toLowerAscii
  let n = norm(name)
  for q in p.parameters:
    if norm(q.name) == n: return q.value
  NaN

# ------------------------------------------------------------------ values --

func number(s: string): float64 =
  ## A real as written ("" and anything else: NaN).
  let t = s.strip
  if t.len == 0: return NaN
  try:
    result = parseFloat(t)
    if result.classify notin {fcNormal, fcZero, fcNegZero, fcSubnormal}: result = NaN
  except ValueError: result = NaN

func code(s: string): int =
  ## An EPSG code as written; 0 for none or one that is no positive integer.
  let t = s.strip
  if t.len == 0 or t.len > 9 or not t.allCharsInSet(Digits): return 0
  parseInt(t)

func kindOf*(s: string): CrsKind =
  ## A CRS type as written (`projected`, `projected 2D` (IOGP P1/11 v2),
  ## `geographic 2D`, `geographic2D`, `compound`; case and blanks ignored),
  ## or a P1/11 type code (1-7). A bare `geographic` (SEG-Y Rev 1 D-1: lat,
  ## long, "and in the case of a 3-D CRS additionally ellipsoidal height")
  ## says neither 2D nor 3D: unknown.
  var t = ""
  for c in s:
    if c notin {' ', '_', '-'}: t.add c.toLowerAscii
  case t
  of "projected", "projected2d", "1": ckProjected
  of "geographic2d", "2": ckGeographic2D
  of "geographic3d", "3": ckGeographic3D
  of "geocentric", "4": ckGeocentric
  of "vertical", "5": ckVertical
  of "engineering", "6": ckEngineering
  of "compound", "7": ckCompound
  else: ckUnknown

func unescape(s: string): string =
  ## A P1/11 text field: `,` and the like (reserved characters) as
  ## the characters they stand for (ASCII only), blanks trimmed.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 5 < s.len and s[i + 1] in {'u', 'U'} and
        s[i + 2 .. i + 5].allCharsInSet(HexDigits):
      let v = parseHexInt(s[i + 2 .. i + 5])
      if v < 128:
        result.add char(v)
        i += 6
        continue
    result.add s[i]
    inc i
  result = result.strip

# ------------------------------------------------------------------ P1/11 --

type
  P1Crs = object
    kind: CrsKind
    epsg: int
    name: string
    datum: GeodeticDatum
    hasDatum: bool
    projection: MapProjection
    base: int                 # base geographic CRS number (projected CRSs)
    horizontal, vertical: int # components (compound CRSs)
    verticalDatum: string
    verticalEpsg: int

proc fromP1_11(text: string): CoordinateReference =
  # The HC,1,3 / 4 / 5 records: each CRS by its number; the one the
  # coordinates are in is the first projected CRS (else the horizontal part
  # of the first compound one, else the first geographic one, else the
  # first); a vertical CRS gives the vertical datum.
  result = CoordinateReference() # the field defaults: NaN, not 0
  var crss = initOrderedTable[int, P1Crs]()
  template at(n: int): var P1Crs =
    crss.mgetOrPut(n, P1Crs())
  for line in text.splitLines:
    let l = line.strip
    if not l.startsWith("HC,1,"): continue
    let f = l.split(',')
    if f.len < 6: continue
    template field(i: int): string = (if i < f.len: unescape(f[i]) else: "")
    let n = code(f[5])
    if n <= 0: continue
    case f[2].strip & "," & f[3].strip
    of "3,0":
      at(n).epsg = code(field(6))
      if at(n).name.len == 0: at(n).name = field(7)
    of "4,0":
      if at(n).epsg == 0: at(n).epsg = code(field(6))
      at(n).kind = kindOf(field(7))
      if at(n).kind == ckUnknown: at(n).kind = kindOf(field(8))
      if field(9).len > 0: at(n).name = field(9)
    of "4,1": at(n).horizontal = code(field(6))
    of "4,2": at(n).vertical = code(field(6))
    of "4,3": at(n).base = code(field(6))
    of "4,4":
      at(n).hasDatum = true
      at(n).datum.epsg = code(field(6))
      at(n).datum.name = field(7)
    of "4,5": at(n).datum.primeMeridian = field(7)
    of "4,6":
      at(n).hasDatum = true
      at(n).datum.ellipsoidEpsg = code(field(6))
      at(n).datum.ellipsoid = field(7)
      at(n).datum.semiMajorAxis = number(field(8))
      at(n).datum.semiMajorAxisUnit = field(10)
      at(n).datum.inverseFlattening = number(field(11))
    of "4,7":
      at(n).verticalEpsg = code(field(6))
      at(n).verticalDatum = field(7)
    of "5,0":
      at(n).projection.epsg = code(field(6))
      at(n).projection.name = field(7)
    of "5,1":
      at(n).projection.methodEpsg = code(field(6))
      at(n).projection.methodName = field(7)
    of "5,2":
      at(n).projection.parameters.add CrsParameter(name: field(4).strip(chars = {'.', ' '}),
        epsg: code(field(6)), value: number(field(7)), unit: field(9))
    else: discard
  if crss.len == 0: return
  var main = -1
  for want in [ckProjected, ckCompound, ckGeographic2D, ckGeographic3D]:
    for n, c in crss:
      if main < 0 and c.kind == want:
        main = if want == ckCompound and c.horizontal in crss: c.horizontal else: n
  if main < 0:
    for n, c in crss:
      if main < 0 and c.kind notin {ckVertical, ckEngineering}: main = n
  if main < 0:
    for n in crss.keys:
      if main < 0: main = n
  let m = crss[main]
  result = CoordinateReference(kind: m.kind, name: m.name, epsg: m.epsg,
    datum: m.datum, projection: m.projection)
  if not m.hasDatum and m.base in crss:
    result.datum = crss[m.base].datum
  for n, c in crss:
    if result.verticalDatum.len == 0 and result.verticalEpsg == 0 and
        (c.verticalDatum.len > 0 or c.verticalEpsg > 0):
      result.verticalDatum = c.verticalDatum
      result.verticalEpsg = c.verticalEpsg

# ---------------------------------------------------------------- stanzas --

func keyOf(s: openArray[char]): string =
  # A stanza keyword compared case- and blank-insensitively (and without
  # hyphens: `semi-major`).
  for c in s:
    if c notin {' ', '\t', '-', '_'}: result.add c.toLowerAscii

proc fromStanza(s: Table[string, string], parameters: bool): CoordinateReference =
  # The values of one stanza's keywords; `parameters`: a keyword starts with
  # `projectionparameter` (else they are not looked for).
  template v(k: string): string = s.getOrDefault(k)
  result = CoordinateReference()
  result.kind = kindOf(v("crstype"))
  result.name = v("crsname")
  result.epsg = code(v("crscode"))
  result.datum = GeodeticDatum(name: v("geodeticdatumname"), epsg: code(v("geodeticdatumcode")),
    ellipsoid: v("ellipsoidname"), ellipsoidEpsg: code(v("ellipsoidcode")),
    semiMajorAxis: number(v("ellipsoidsemimajoraxis")),
    semiMajorAxisUnit: v("semimajoraxisunitname"),
    inverseFlattening: number(v("ellipsoidinverseflattening")),
    primeMeridian: v("primemeridianname"))
  # SEG-Y Rev 1: `Projection zone name`; SEG-D Rev 3: `Projection name`.
  result.projection.name = v("projectionzonename")
  if result.projection.name.len == 0: result.projection.name = v("projectionname")
  result.projection.epsg = code(v("projectioncode"))
  result.projection.methodName = v("projectionmethodname")
  result.projection.methodEpsg = code(v("projectionmethodcode"))
  for n in 1 .. (if parameters: 20 else: 0):
    # `Projection parameter n name`, `... n value`, `... n unit name`: SEG-Y
    # Rev 1 D-1 and Rev 2 D-3, SEG-D Rev 3.0/3.1 App. D. (Their `... n unit
    # code` is the unit's EPSG code, not the parameter's: not read.)
    let p = "projectionparameter" & $n
    if p & "name" in s:
      result.projection.parameters.add CrsParameter(name: v(p & "name"),
        value: number(v(p & "value")), unit: v(p & "unitname"))
  result.verticalDatum = v("verticaldatumname")
  result.verticalEpsg = code(v("verticaldatumcode"))
  if result.verticalDatum.len == 0: result.verticalDatum = v("verticalcrsname")

type
  StanzaChoice = object
    # What the choice among stanzas needs, kept as each stanza is read: the
    # first stanza of each preferred kind, the first that gives anything,
    # and the first vertical datum.
    preferred: array[4, CoordinateReference] # projected, compound, geographic 2D, 3D
    havePreferred: array[4, bool]
    firstKnown: CoordinateReference
    haveKnown: bool
    verticalDatum: string
    verticalEpsg: int

proc take(ch: var StanzaChoice, r: CoordinateReference) =
  let slot = case r.kind
    of ckProjected: 0
    of ckCompound: 1
    of ckGeographic2D: 2
    of ckGeographic3D: 3
    else: -1
  if ch.verticalDatum.len == 0 and r.verticalDatum.len > 0:
    ch.verticalDatum = r.verticalDatum
    ch.verticalEpsg = r.verticalEpsg
  if slot >= 0 and not ch.havePreferred[slot]:
    ch.havePreferred[slot] = true
    ch.preferred[slot] = r
  elif not ch.haveKnown and r.known:
    ch.haveKnown = true
    ch.firstKnown = r

proc fromStanzas(text: string): CoordinateReference =
  # The stanza the coordinates are in: the first projected one, else the
  # first compound, geographic or other one that names a CRS; a vertical
  # datum named in any stanza fills in a missing one. The `keyword = value`
  # lines of each stanza (`((SEG:` or other `((` header lines start one;
  # text without any is one stanza), with comments (`#`), blank lines and
  # `&` continuations as SEG-Y Rev 1 §6.1 says; the first value of a
  # keyword wins. Each stanza becomes a value as it ends, so memory stays
  # that of one stanza however many the text holds, and a continuation is
  # appended, not copied, so time stays linear in the text.
  result = CoordinateReference() # the field defaults: NaN, not 0
  var ch = StanzaChoice()
  var cur = initTable[string, string]()
  var pending = ""
  var parameters = false
  template addKey(line: string) =
    # Only the keywords `fromStanza` reads are kept.
    let eq = line.find('=')
    if eq > 0:
      let k = keyOf(line.toOpenArray(0, eq - 1))
      var wanted = true
      case k
      of "crstype", "crsname", "crscode", "geodeticdatumname", "geodeticdatumcode",
          "ellipsoidname", "ellipsoidcode", "ellipsoidsemimajoraxis", "semimajoraxisunitname",
          "ellipsoidinverseflattening", "primemeridianname", "projectionzonename",
          "projectionname", "projectioncode", "projectionmethodname", "projectionmethodcode",
          "verticaldatumname", "verticaldatumcode", "verticalcrsname": discard
      elif k.startsWith("projectionparameter"): parameters = true
      else: wanted = false
      if wanted and k notin cur: cur[k] = line.substr(eq + 1).strip
  template close() =
    if cur.len > 0:
      ch.take fromStanza(cur, parameters)
      cur.clear()
      parameters = false
  for raw in text.splitLines:
    var line = raw.strip
    if pending.len > 0:
      pending.add line
      line = move pending # `pending` is empty again
    if line.len == 0 or line[0] == '#': continue
    if line.startsWith("(("):
      close()
      continue
    if line.endsWith("&"):
      line.setLen line.len - 1
      pending = move line
      continue
    addKey(line)
  if pending.len > 0: addKey(pending) # the text ends in a continuation
  close()
  var main = -1
  for slot in 0 .. 3:
    if main < 0 and ch.havePreferred[slot]: main = slot
  if main >= 0: result = move ch.preferred[main]
  elif ch.haveKnown: result = move ch.firstKnown
  else: return
  if result.verticalDatum.len == 0 and ch.verticalDatum.len > 0:
    result.verticalDatum = ch.verticalDatum
    result.verticalEpsg = ch.verticalEpsg

proc parseCrsText*(text: string): CoordinateReference =
  ## The coordinate reference system that a CRS text gives (`crsText` of a
  ## `SeismicFile`): OGP P1/11 header records (`HC,1,3,0` ... `HC,1,5,2`,
  ## told by lines starting `HC,`) or SEG Location Data stanzas (`keyword =
  ## value` lines, with or without their `((SEG: ...))` header lines;
  ## comments, `&` continuations; a keyword's first value). When the text
  ## defines several CRSs, the one returned is the first projected one (else
  ## the horizontal part of a compound one, else a geographic one), with its
  ## datum (or its base geographic CRS's) and projection; a vertical datum
  ## comes from any of them. Unknown (`known` false) for text that gives
  ## none of this. Linear in the text's length, in memory about one stanza.
  ## A text of 80-column cards without line ends (SEG-Y Rev 0/1) must be cut
  ## into lines first; `crs(SeismicFile)` does so.
  for line in text.splitLines:
    if line.strip.startsWith("HC,1,"): return fromP1_11(text)
  fromStanzas(text)
