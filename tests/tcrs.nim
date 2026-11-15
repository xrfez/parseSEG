## Datum and projection as values (18.5): `parseCrsText` on OGP P1/11
## header records and SEG Location Data stanzas (the SEG-Y Rev 2 and SEG-D
## Rev 3 CRS text), `crs(SpsFile)` on SPS header records, `crs(SeismicFile)`
## on a file's own CRS text; unknown where nothing is given. Synthetic
## records from the spec examples (SEG-Y Rev 2.0 D-1, SEG-Y Rev 1 D-1.2,
## SEG-D Rev 3.0 Appendix D, SPS 2.1 §3). Seen failing with the P1/11 CRS
## choice taken as the first CRS (a compound one: no datum), and with the
## stanza keywords compared with their blanks.

import std/[assertions, math, os, strutils]
import parseSEG
import parseSEG/survey/cards # column helpers (internal)
import ./utils/testutils

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
  # SEG-D Rev 3: EPSG reference stanzas, then a full one; the projected one is chosen.
  let segd = """((SEG: Location Data EPSG Reference ver 3.0))
Location Data Stanza ID = 1
CRS code = 4267
CRS name = NAD27
((SEG: Location Data EPSG Reference ver 3.0))
Location Data Stanza ID = 2
CRS type = projected
CRS code = 32040
CRS name = NAD27 / Texas South Central
Projection name = Texas CS27 South Central zone
Projection parameter 1 = latitude of false origin, 27.5, 9110, sexagesimal DMS, 1
((SEG: Location Data ver 3.0))
Location Data Stanza ID = 7
CRS type = vertical
Vertical Datum name = National Geodetic Vertical Datum 1929
"""
  let d = parseCrsText(segd)
  doAssert d.kind == ckProjected and d.epsg == 32040 and d.name == "NAD27 / Texas South Central"
  doAssert d.projection.name == "Texas CS27 South Central zone"
  doAssert d.projection.parameters.len == 1 and d.projection.parameters[0].value == 27.5 and
    d.projection.parameters[0].unit == "sexagesimal DMS"
  doAssert d.verticalDatum == "National Geodetic Vertical Datum 1929"

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
  let c = f.crs
  doAssert c.kind == ckProjected and c.name == "WGS 84 / UTM zone 32N" and c.epsg == 32632
  doAssert c.name == parseCrsText(f.crsText).name and not c.datum.known
  f.close()
  doAssert f.crs.kind == ckProjected # from the index: works on a closed file
  var r = openSeismic(demoDir() / "record.sgd")
  doAssert not r.crs.known
  r.close()

echo "tcrs: ok"
