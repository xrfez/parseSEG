## Datum and projection as values (18.5): `parseCrsText` on OGP P1/11
## header records and SEG Location Data stanzas (the SEG-Y Rev 2 and SEG-D
## Rev 3 CRS text), `crs(SpsFile)` on SPS header records, `crs(SeismicFile)`
## on a file's own CRS text; unknown where nothing is given. Synthetic
## records from the spec examples (SEG-Y Rev 2.0 D-1, SEG-Y Rev 1 D-1.2,
## SEG-D Rev 3.0 Appendix D, SPS 1.0 and 2.1 §3). Seen failing with the
## P1/11 CRS choice taken as the first CRS (a compound one: no datum), and
## with the stanza keywords compared with their blanks. Also seen failing
## with SPS fields cut after their leading blanks were
## stripped (a false easting of 5e15), an H12 cut through its words (1/f
## 0.15281), decimal degrees read as DMS, `&` continuations in quadratic
## time and the last one dropped, a table kept per stanza (1.6 GB for 2 MiB
## of text), `known` blind to parameters, "geographic" taken as 2D and any
## H18 as projected, Rev 1 card images read as one line, and an invented
## `Projection parameter n = name, value, ...` syntax.

import std/[assertions, math, monotimes, os, strutils, times]
import parseSEG
import parseSEG/survey/cards # column helpers (internal)
import ./utils/testutils

block stanza_memory_is_bounded:
  # First in the file, so the allocator's high-water mark is still low. Each
  # stanza becomes a value as it closes: 2 MiB of one-keyword stanzas (as a
  # hostile SEG-D 0x55 text or Rev 2 stanza could hold) peak far below the
  # 0.7 GB that a table per stanza took (1.6 GB for 2 MiB of `((\nk=v\n`).
  when not defined(useMalloc): # the system allocator keeps no high-water mark
    let text = repeat("((\nCRS type = x\n", (2 shl 20) div 16)
    let before = getMaxMem()
    let c = parseCrsText(text)
    let peak = getMaxMem() - before
    doAssert not c.known
    doAssert peak < 16 shl 20, "parsing 2 MiB of stanzas peaked at " & $(peak shr 20) & " MiB"
    # Keywords the parser does not read are not kept at all.
    let before2 = getMaxMem()
    doAssert not parseCrsText(repeat("((\nk=v\n", (2 shl 20) div 7)).known
    doAssert getMaxMem() - before2 < 16 shl 20

const p111 = """
HC,1,0,0,Reference Systems Summary.........................,5,1,4,2
HC,1,3,0,CRS Number/EPSG Code/Name/Source…,1,      , WGS 84 / UTM zone 31N / EGM96,    ,          ,    ,
HC,1,3,0,CRS Number/EPSG Code/Name/Source…,2,32631,          WGS 84 / UTM zone 31N,7.6,2010:11:02,EPSG,Loaded
HC,1,3,0,CRS Number/EPSG Code/Name/Source…,3, 4326,                          WGS 84,7.6,2010:11:02,EPSG,Loaded
HC,1,3,0,CRS Number/EPSG Code/Name/Source…,4, 5773,             EGM96 Geoid Height,7.6,2010:11:02,EPSG,Loaded
HC,1,4,0,CRS Number/EPSG Code/Type/Name…,1,     ,7,compound   ,WGS 84 / UTM zone 31N / EGM96
HC,1,4,0,CRS Number/EPSG Code/Type/Name…,2,32631,1,projected  ,WGS 84 / UTM zone 31N
HC,1,4,0,CRS Number/EPSG Code/Type/Name…,3, 4326,2,geographic 2D,WGS 84
HC,1,4,0,CRS Number/EPSG Code/Type/Name…,4, 5773,5,vertical   ,EGM96 Geoid Height
HC,1,4,1,Compound Horizontal CRS…,1,2,32631,WGS 84 / UTM zone 31N
HC,1,4,2,Compound Vertical CRS…,1,4,5773,EGM96 Geoid Height
HC,1,4,3,Base Geographic CRS…,2,3,4326,WGS 84
HC,1,4,4,Geodetic Datum…,3,6326,World Geodetic System 1984,1984:01:01
HC,1,4,6,Ellipsoid…,3,7030,WGS 84,6378137,1,metre,298.257223563
HC,1,4,7,Vertical Datum…,4,5171,EGM96 geoid
HC,1,5,0,Map Projection ,2,16031,UTM zone 31N
HC,1,5,1,Projection Method… ,2,9807,Transverse Mercator,5
HC,1,5,2,Latitude of natural origin........................,2,8801,                  0,3,degree
HC,1,5,2,Longitude of natural origin.......................,2,8802,                3,3,degree
HC,1,5,2,Scale factor at natural origin....................,2,8805,0.9996,4, unity
HC,1,5,2,False easting.....................................,2,8806,500000,1, metre
HC,1,5,2,False northing....................................,2,8807,                  0,1, metre
"""

block p1_11_records:
  let c = parseCrsText(p111)
  doAssert c.known and c.kind == ckProjected
  doAssert c.name == "WGS 84 / UTM zone 31N" and c.epsg == 32631
  # The projected CRS's datum is its base geographic CRS's (CRS 3).
  doAssert c.datum.name == "World Geodetic System 1984" and c.datum.epsg == 6326
  doAssert c.datum.ellipsoid == "WGS 84" and c.datum.ellipsoidEpsg == 7030
  doAssert c.datum.semiMajorAxis == 6378137 and c.datum.semiMajorAxisUnit == "metre"
  doAssert abs(c.datum.inverseFlattening - 298.257223563) < 1e-9
  doAssert c.projection.name == "UTM zone 31N" and c.projection.epsg == 16031
  doAssert c.projection.methodName == "Transverse Mercator" and c.projection.methodEpsg == 9807
  doAssert c.projection.parameters.len == 5
  doAssert c.projection.parameters[3].name == "False easting" and
    c.projection.parameters[3].epsg == 8806 and c.projection.parameters[3].unit == "metre"
  doAssert c.projection.parameter("false easting") == 500000
  doAssert c.projection.parameter("Scale factor at natural origin") == 0.9996
  doAssert c.projection.parameter("no such").isNaN
  doAssert c.verticalDatum == "EGM96 geoid" and c.verticalEpsg == 5171
  # A geographic CRS only: no projection; reserved characters escaped.
  let g = parseCrsText("HC,1,4,0,CRS…,1,4326,2,geographic 2D,WGS 84\\u002C as given\n" &
    "HC,1,4,4,Geodetic Datum…,1,6326,World Geodetic System 1984")
  doAssert g.kind == ckGeographic2D and g.name == "WGS 84, as given" and g.epsg == 4326
  doAssert g.datum.name == "World Geodetic System 1984" and not g.projection.known

block location_data_stanzas:
  # SEG-Y Rev 1 D-1.2 (keywords with blanks, case as written).
  let st = """((SEG: Location Data ver 1.0))
CRS type =                                  projected
CRS name =                                  NAD27 / Texas South Central
Geodetic Datum name =                       North American Datum 1927
Ellipsoid name =                            Clarke 1866
Ellipsoid semi-major axis =                 6378206.4
Semi-major axis unit name =                 meter
Ellipsoid inverse flattening =              294.9786982
Projection zone name =                      Texas CS27 South Central zone
Projection method name =                    Lambert Conic Conformal (2SP)
Projection parameter 1 name =               latitude of false origin
Projection parameter 1 value =              27.5
Projection parameter 1 unit name =          DDD.MMSSsss
Projection parameter 2 name =               longitude of false origin
Projection parameter 2 value =              -99
Projection parameter 2 unit name =          degrees
"""
  let c = parseCrsText(st)
  doAssert c.kind == ckProjected and c.name == "NAD27 / Texas South Central" and c.epsg == 0
  doAssert c.datum.name == "North American Datum 1927" and c.datum.ellipsoid == "Clarke 1866"
  doAssert c.datum.semiMajorAxis == 6378206.4 and c.datum.semiMajorAxisUnit == "meter"
  doAssert c.datum.inverseFlattening == 294.9786982
  doAssert c.projection.name == "Texas CS27 South Central zone"
  doAssert c.projection.methodName == "Lambert Conic Conformal (2SP)"
  doAssert c.projection.parameters.len == 2 and c.projection.parameter("longitude of false origin") == -99
  # The data of a stanza without its header line, keywords in other case and
  # spacing, a comment and a continuation: the same.
  let body = st.splitLines[1 .. ^1].join("\n").replace("CRS type", "CRSTYPE").
    replace("Geodetic Datum name =", "# a comment\ngeodetic datum NAME = &\n")
  doAssert parseCrsText(body).datum.name == "North American Datum 1927"
  doAssert parseCrsText(body).kind == ckProjected
  # SEG-D Rev 3.0 App. D.1.2 [p.147-148], as printed: EPSG reference
  # stanzas 1-2, then the explicit stanza 5 (`−99` of the extraction written
  # with an ASCII minus), then a vertical one. The projected one is chosen.
  let segd = """((SEG: Location Data EPSG Reference ver 3.0))
Location Data Stanza ID =          1
CRS code =                         4267
CRS name =                         NAD27
Dataset version =                  6.13
((SEG: Location Data EPSG Reference ver 3.0))
Location Data Stanza ID =          2
CRS code =                         34020
CRS name =                         NAD27 / Texas South Central
Dataset version =                  6.13
 ((SEG: LOCATION DATA VER 3.0))
 Location Data Stanza ID =                   5
 CRS type =                                  projected
 CRS name =                              NAD27 / Texas South Central
 Geodetic Datum name =                   North American Datum 1927
 Ellipsoid name =                        Clarke 1866
 Ellipsoid semi-major axis =             6378206.4
 Semi-major axis unit name =             meter
 Ellipsoid inverse flattening =          294.9786982
 Projection name =                       Texas CS27 South Central zone
 Projection method name =                Lambert Conic Conformal (2SP)
 Projection parameter 1 name =           latitude of false origin
 Projection parameter 1 value =          27.5
 Projection parameter 1 unit name =      sexagesimal DMS
 Projection parameter 2 name =           longitude of false origin
 Projection parameter 2 value =          -99
 Projection parameter 2 unit name =      degree
 Projection parameter 3 name =           latitude of first standard parallel
 Projection parameter 3 value =          28.23
 Projection parameter 3 unit name =      sexagesimal DMS
 Projection parameter 4 name =           latitude of second standard parallel
 Projection parameter 4 value =          30.17
 Projection parameter 4 unit name =      sexagesimal DMS
 Projection parameter 5 name =           easting at false origin
 Projection parameter 5 value =          2000000.0
 Projection parameter 5 unit name =      US survey foot
 Projection parameter 6 name =           northing at false origin
 Projection parameter 6 value =          0.0
 Projection parameter 6 unit name =      US survey foot
 Coordinate System axis 1 name =         X
 CS axis 1 orientation =                 East
 CS axis 1 unit code =                   9003
 CS axis 1 unit name =                   US Survey foot
((SEG: Location Data ver 3.0))
Location Data Stanza ID = 7
CRS type = vertical
Vertical Datum name = National Geodetic Vertical Datum 1929
"""
  let d = parseCrsText(segd)
  doAssert d.kind == ckProjected and d.epsg == 0 and d.name == "NAD27 / Texas South Central"
  doAssert d.datum.name == "North American Datum 1927" and d.datum.ellipsoid == "Clarke 1866"
  doAssert d.datum.semiMajorAxis == 6378206.4 and d.datum.semiMajorAxisUnit == "meter" and
    d.datum.inverseFlattening == 294.9786982
  doAssert d.projection.name == "Texas CS27 South Central zone"
  doAssert d.projection.methodName == "Lambert Conic Conformal (2SP)"
  doAssert d.projection.parameters.len == 6
  doAssert d.projection.parameters[0].name == "latitude of false origin" and
    d.projection.parameters[0].value == 27.5 and
    d.projection.parameters[0].unit == "sexagesimal DMS" and d.projection.parameters[0].epsg == 0
  doAssert d.projection.parameter("longitude of false origin") == -99
  doAssert d.projection.parameters[4].name == "easting at false origin" and
    d.projection.parameters[4].value == 2000000 and
    d.projection.parameters[4].unit == "US survey foot"
  doAssert d.verticalDatum == "National Geodetic Vertical Datum 1929"
  # No spec defines `Projection parameter n = name, value, ...` (SEG-Y Rev 1
  # D-1, Rev 2 D-3 and SEG-D 3.0/3.1 D all spell `... n name / value / unit
  # name`): such a line gives no parameter.
  let odd = parseCrsText("CRS type = projected\nProjection name = x\n" &
    "Projection parameter 1 = latitude of false origin, 27.5, 9110, sexagesimal DMS, 1\n")
  doAssert odd.projection.parameters.len == 0 and odd.projection.name == "x"

block nothing_given:
  for text in ["", "\n\n", "free text without keywords", "((SEG: Location Data ver 1.0))\n",
      "HC,1,3,0,x", "HC,1,4,0,CRS,abc,,,", "CRS type = something else"]:
    let c = parseCrsText(text)
    doAssert not c.known, text
    doAssert c.kind == ckUnknown and c.name == "" and c.epsg == 0 and c.datum.semiMajorAxis.isNaN
    doAssert not c.datum.known and not c.projection.known

proc hrec(code, description, data: string): string =
  ## An SPS header record: code in 2-4, description in 5-32, data from 33.
  result = repeat(' ', 32)
  result[0] = 'H'
  result.putCol(2, code)
  result.putCol(5, description)
  result.add data

block sps_headers:
  let text = [
    hrec("00", "SPS format version number", "SPS 2.1;"),
    hrec("12", "Geodetic datum,-spheroid", "WGS84".alignLeft(12) & "WGS84".alignLeft(12) &
      "6378137.000".align(12) & "298.2572236".align(12)),
    hrec("17", "Vertical datum description", "Mean sea level;"),
    hrec("18", "Projection type", "UTM;"),
    hrec("19", "Projection zone", "Zone 30, North;"),
    hrec("20", "Description of grid units", "Metres;"),
    hrec("220", "Long. of central meridian", "  3 0  0.000W"),
    hrec("232", "Grid coord. at origin", "  500000.00E        0.00N"),
    hrec("241", "Scale factor", "0.9996000000"),
    hrec("210", "Lat. of standard parallel(s)", "N/A")].join("\r\n") & "\r\n"
  let f = parseSps(text, "h.s")
  let c = f.crs
  doAssert c.known and c.kind == ckProjected
  doAssert c.datum.name == "WGS84" and c.datum.ellipsoid == "WGS84"
  doAssert c.datum.semiMajorAxis == 6378137 and abs(c.datum.inverseFlattening - 298.2572236) < 1e-9
  doAssert c.verticalDatum == "Mean sea level"
  doAssert c.projection.name == "UTM" and c.projection.zone == "Zone 30, North"
  doAssert c.projection.parameter("longitude of central meridian") == -3
  doAssert c.projection.parameter("false easting") == 500000 and
    c.projection.parameter("false northing") == 0
  doAssert c.projection.parameter("scale factor") == 0.9996
  doAssert c.projection.parameter("latitude of 1st standard parallel").isNaN # N/A
  # Comma-separated H12, DMS without blanks, N/A everywhere else.
  let g = parseSps([hrec("12", "Geodetic datum,-spheroid", "ED50,International 1924,6378388," &
      "297;"), hrec("18", "Projection type", "N/A"),
    hrec("220", "Long. of central meridian", "0033000.000E")].join("\n"), "g.s").crs
  doAssert g.datum.name == "ED50" and g.datum.ellipsoid == "International 1924"
  doAssert g.datum.semiMajorAxis == 6378388 and g.datum.inverseFlattening == 297
  doAssert g.kind == ckUnknown and g.projection.name == ""
  doAssert abs(g.projection.parameter("longitude of central meridian") - 3.5) < 1e-12
  # No header records: unknown.
  doAssert not parseSps("").crs.known

block seismic_file:
  # `shot.sgd` carries a SEG-D Rev 3 Location Data stanza (0x55 blocks);
  # `record.sgd` (Rev 2) none.
  var f = openSeismic(demoDir() / "shot.sgd")
  doAssert f.crsText.startsWith("((SEG: Location Data ver 3.0))\r\nLocation Data Stanza ID = 1")
  let c = f.crs
  doAssert c.kind == ckProjected and c.name == "WGS 84 / UTM zone 32N" and c.epsg == 32632
  doAssert not c.datum.known and not c.projection.known and c.verticalDatum == "" and
    c.verticalEpsg == 0 # the stanza gives a CRS name, code and type only
  f.close()
  doAssert f.crs.kind == ckProjected # from the index: works on a closed file
  var r = openSeismic(demoDir() / "record.sgd")
  doAssert not r.crs.known
  r.close()

block sps_fields_by_column:
  # SPS 2.1 §3 [p.9]: H210 and H231 2(I3,I2,F6.3,A1), H232 2(F11.2,A1), from
  # column 33. Fortran writes I3 and F11.2 right-justified, so the first
  # field starts with blanks. Values of the SPS 1.0 examples [p.16]: grid
  # origin 5° N, 15° 10' 25" E; standard parallels 5° N and 10° N; with a
  # false northing of 10 000 000 (UTM south) that fills its F11.2.
  let p = parseSps([
    hrec("231", "Grid origin", "  5 0 0.000N 151025.000E"),
    hrec("232", "Grid coord. at origin", "  500000.00E10000000.00N"),
    hrec("210", "Lat. of standard parallel(s)", "  5 0 0.000N 10 0 0.000N")].join("\n"),
    "c.s").crs.projection
  doAssert p.parameter("latitude of grid origin") == 5
  doAssert abs(p.parameter("longitude of grid origin") - (15 + 10 / 60 + 25 / 3600)) < 1e-12
  doAssert p.parameter("false easting") == 500000, $p.parameter("false easting")
  doAssert p.parameter("false northing") == 10000000, $p.parameter("false northing")
  doAssert p.parameter("latitude of 1st standard parallel") == 5 and
    p.parameter("latitude of 2nd standard parallel") == 10
  # The SPS 2.1 appendix records [p.27], verbatim: zero-filled, with `;`.
  let g = parseSps([
    "H220Long. of central meridian   0510000.000E;",
    "H231Grid origin                 0000000.000N0510000.000E;",
    "H232Grid coord. at origin       00500000.00E00000000.00N;",
    "H241Scale factor                0.9996000000;"].join("\n"), "a.s").crs.projection
  doAssert g.parameter("longitude of central meridian") == 51 and
    g.parameter("latitude of grid origin") == 0 and g.parameter("longitude of grid origin") == 51
  doAssert g.parameter("false easting") == 500000 and g.parameter("false northing") == 0 and
    g.parameter("scale factor") == 0.9996
  # SPS 1.0 [p.16]: "For 2 standard parallels of 5 degr N and 10 degr N.
  # Example: 0050000.0000100000.000N": the first has lost its N, so it is
  # unknown (no parameter); the second is 10.
  let h = parseSps(hrec("210", "Lat. of standard parallel(s)", "0050000.0000100000.000N"),
    "b.s").crs.projection
  doAssert h.parameter("latitude of 1st standard parallel").isNaN and
    h.parameter("latitude of 2nd standard parallel") == 10
  # The letter of F11.2,A1 is E, then N, and the number has no exponent.
  for bad in ["  500000.00N        0.00N", "     5.00E3E        0.00N"]:
    doAssert parseSps(hrec("232", "Grid coord. at origin", bad), "d.s").crs.projection.
      parameter("false easting").isNaN, bad

block sps_h12_free_text:
  # SPS 1.0 [p.15]: "Example: RD datum Bessel 1841 6377397.155 299.15281",
  # from column 33 with blanks between, as the examples write H12 (sps.md,
  # AMBIGUITY [1.0 p.14-16]). Columns 44/45 cut a word, so the record is
  # read by its tokens: the last two numbers are a and 1/f; the names are
  # unknown (which words name the datum and which the spheroid is not said).
  let c = parseSps(hrec("12", "Geodetic datum,-spheroid",
    "RD datum Bessel 1841 6377397.155 299.15281"), "r.s").crs
  doAssert c.datum.semiMajorAxis == 6377397.155 and c.datum.inverseFlattening == 299.15281,
    $c.datum
  doAssert c.datum.name == "" and c.datum.ellipsoid == "" and c.datum.known
  # SPS 2.1 appendix [p.27], verbatim: INTERNATIONAL fills columns 33-45.
  let d = parseSps(
    "H12 Geodetic datum,-spheroid    INTERNATIONAL             6378388.000 297.0000000", "i.s").crs
  doAssert d.datum.semiMajorAxis == 6378388 and d.datum.inverseFlattening == 297, $d.datum
  doAssert d.datum.name == "" and d.datum.ellipsoid == ""
  # Words without the two numbers give nothing; a positional record still
  # gives its names (a name shorter than its 12 columns).
  doAssert not parseSps(hrec("12", "Geodetic datum,-spheroid",
    "World Geodetic System 1984  WGS 84"), "w.s").crs.datum.known
  doAssert parseSps(hrec("12", "Geodetic datum,-spheroid", "WGS 84;"), "n.s").crs.datum.name ==
    "WGS 84"

block sps_angles_are_exact_or_unknown:
  # H220 is I3,I2,F6.3,A1: dddmmss.sss and E/W (SPS 2.1 §3 [p.9]). SPS 1.0
  # [p.16]: "For 15 degr 30 min. Example: 0153000.000E".
  proc meridian(data: string): float64 =
    parseSps(hrec("220", "Long. of central meridian", data), "m.s").crs.projection.
      parameter("longitude of central meridian")
  doAssert meridian("0153000.000E") == 15.5
  doAssert meridian(" 1530 0.000W") == -15.5 # as Fortran writes it
  doAssert meridian("15 30 0.000W") == -15.5 # the parts separated by blanks
  # Not dddmmss.sss: unknown, never another angle.
  for bad in ["  51.000000E", "51E", "-3 0 0.000W", "3 -30 0.000E", "1950000.000E",
      "0156000.000E", "015300.0000E"]:
    doAssert meridian(bad).isNaN, bad & ": " & $meridian(bad)
  doAssert parseSps(hrec("231", "Grid origin", "0950000.000N0000000.000E"), "o.s").crs.
    projection.parameter("latitude of grid origin").isNaN # 95° N

block stanza_continuations:
  # SEG-Y Rev 1 §6.1 [p.13]: a line whose last non-blank character is `&`
  # goes on on the next line. The last line of a text may end so too.
  doAssert parseCrsText("CRS type = projected\nCRS name = NAD27 / Texas &\nSouth Central").name ==
    "NAD27 / Texas South Central"
  let last = parseCrsText("CRS type = projected\nCRS name = NAD27 / Texas South Central &")
  doAssert last.name == "NAD27 / Texas South Central", last.name
  # Linear: 350 000 continued lines (1 MiB) took minutes when each one copied
  # the text before it.
  let t0 = getMonoTime()
  doAssert not parseCrsText(repeat("a&\n", 350_000)).known
  let took = getMonoTime() - t0
  doAssert took < initDuration(seconds = 10), "continuations took " & $took

block known_counts_every_value:
  # Parameters alone (SPS H220 and H241 without H18), or an inverse
  # flattening and a prime meridian alone: the file gives something.
  let s = parseSps([hrec("220", "Long. of central meridian", "0030000.000E"),
    hrec("241", "Scale factor", "0.9996000000")].join("\n"), "p.s").crs
  doAssert s.projection.parameters.len == 2 and s.projection.known and s.known
  let d = parseCrsText("Ellipsoid inverse flattening = 298.257223563\nPrime Meridian name = Paris")
  doAssert d.datum.inverseFlattening == 298.257223563 and d.datum.primeMeridian == "Paris"
  doAssert d.datum.known and d.known

block kinds_are_not_guessed:
  # SEG-Y Rev 1 D-1.1 [p.27]: "Geographic = latitude, longitude; and in the
  # case of a 3-D CRS additionally ellipsoidal height": the bare value says
  # neither 2D nor 3D.
  doAssert kindOf("geographic") == ckUnknown and kindOf("Geographic 2D") == ckGeographic2D and
    kindOf("geographic3D") == ckGeographic3D
  # IOGP P1/11 v2.0 spells the type `projected 2D` (BO_3D-Inglewood_rev21_v7.sgy).
  doAssert kindOf("projected 2D") == ckProjected
  # SPS H18, the projection type (1.0 [p.7]: Transverse Mercator, UTM,
  # Stereographic, Oblique Mercator, Lambert Conical; 2.1 [p.27] `UTM;`):
  # projected for a projection's name only.
  for (h18, k) in [("Transverse Mercator;", ckProjected), ("UTM;", ckProjected),
      ("Lambert Conical;", ckProjected), ("Oblique Mercator;", ckProjected),
      ("Stereographic;", ckProjected), ("Geographic;", ckUnknown),
      ("Geographic (lat/long);", ckUnknown), ("Local grid;", ckUnknown)]:
    let c = parseSps(hrec("18", "Projection type", h18), "k.s").crs
    doAssert c.kind == k and c.projection.name == h18[0 ..< ^1], h18 & ": " & $c.kind

block segy_rev1_card_images:
  # SEG-Y Rev 1 §6.1 [p.13]: the extended textual header holds 3200-byte
  # records of 80-column card images; the reader starts a line at every 80th
  # column as well as after a line end (`rev1Lines`). The D-1.2 example
  # [p.29-30], each line a card without CR LF.
  proc be16(s: var string, at, v: int) =
    s[at] = char((v shr 8) and 0xFF)
    s[at + 1] = char(v and 0xFF)
  var text = ""
  for i in 1 .. 40:
    text.add (if i == 40: "C40 END TEXTUAL HEADER" else: "C" & align($i, 2)).alignLeft(80)
  var bin = repeat('\0', 400)
  bin.be16(16, 1000)    # 3217: interval
  bin.be16(20, 4)       # 3221: samples
  bin.be16(24, 5)       # 3225: IEEE floats
  bin.be16(300, 0x0100) # 3501: Rev 1.0
  bin.be16(302, 1)      # 3503: fixed length
  bin.be16(304, 1)      # 3505: one extended record
  var ext = ""
  for card in [" ((SEG: Location Data ver 1.0))".strip,
      " CRS type =                                  projected",
      " CRS name =                                  NAD27 / Texas South Central",
      " Geodetic Datum name =                       North American Datum 1927",
      " Ellipsoid name =                            Clarke 1866",
      " Ellipsoid semi-major axis =                 6378206.4",
      " Semi-major axis unit name =                 meter",
      " Ellipsoid inverse flattening =              294.9786982",
      " Projection zone name =                      Texas CS27 South Central zone",
      " Projection method name =                    Lambert Conic Conformal (2SP)",
      " Projection parameter 1 name =               latitude of false origin",
      " Projection parameter 1 value =              27.5",
      " Projection parameter 1 unit name =          DDD.MMSSsss"]:
    ext.add card.alignLeft(80)
  ext = ext.alignLeft(3200)
  var trace = repeat('\0', 240 + 16)
  trace.be16(114, 4)
  trace.be16(116, 1000)
  let path = scratchDir("parseseg_tcrs") / "rev1cards.sgy"
  writeFile(path, text & bin & ext & trace)
  var f = openSeismic(path)
  doAssert f.len == 1 and f.index.segy.extended.stanzas.len == 1
  doAssert '\n' notin f.crsText # as stored
  let c = f.crs
  doAssert c.kind == ckProjected and c.name == "NAD27 / Texas South Central", $c.kind
  doAssert c.datum.name == "North American Datum 1927" and c.datum.semiMajorAxis == 6378206.4
  doAssert c.projection.name == "Texas CS27 South Central zone" and
    c.projection.parameter("latitude of false origin") == 27.5
  f.close()

sampleBlock real_crs_texts:
  # IOGP P1/11 v2.0 in a SEG-Y Rev 2.1 file: CRS 1 is projected (EPSG 2193),
  # its base geographic CRS 2 gives the datum, CRS 4 the vertical datum.
  var f = openSeismic(exampleDir / "BO_3D-Inglewood_rev21_v7.sgy")
  let c = f.crs
  doAssert c.kind == ckProjected and c.epsg == 2193 and
    c.name == "NZGD2000 / New Zealand Transverse Mercator 2000"
  doAssert c.datum.name == "New Zealand Geodetic Datum 2000" and c.datum.epsg == 6167
  doAssert c.datum.ellipsoid == "GRS 1980" and c.datum.ellipsoidEpsg == 7019 and
    c.datum.semiMajorAxis == 6378137 and c.datum.inverseFlattening == 298.257222101 and
    c.datum.semiMajorAxisUnit == "metre" and c.datum.primeMeridian == "Greenwich"
  doAssert c.projection.name == "New Zealand Transverse Mercator 2000" and
    c.projection.epsg == 19971 and c.projection.methodName == "Transverse Mercator" and
    c.projection.methodEpsg == 9807
  doAssert c.projection.parameters.len == 5 and
    c.projection.parameter("Longitude of natural origin") == 173 and
    c.projection.parameter("False northing") == 10000000
  doAssert c.verticalDatum == "Instantaneous Water Level" and c.verticalEpsg == 5113
  f.close()
  # A SEG-D Rev 3.0 EPSG reference stanza alone: its code and name, nothing else.
  var g = openSeismic(exampleDir / "inova_rev30_5traces.sgd")
  let d = g.crs
  doAssert d.kind == ckUnknown and d.epsg == 32050 and d.name == "Clarke 1866/unnamed"
  doAssert not d.datum.known and not d.projection.known and d.verticalDatum == ""
  g.close()

echo "tcrs: ok"
