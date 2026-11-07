## SEG-Y trace header layouts: the `((SEG:Layout:text/xml))` stanza (D-8,
## spec note `segy_rev2_1.md` §7.3) and the standard layouts of Rev 0, 1 and 2.
##
## Many real files keep values in non-standard trace header bytes (e.g. the
## Inglewood sample stores the inline number at byte 13 and CDP X/Y at 73/77)
## and say so in a Layout stanza. The reader merges that stanza over the
## standard layout of the file's revision, so named values (`iline`,
## `cdp_x`, ...) come from the right bytes; see `reader.fieldValue` and
## `reader.geometry`.
##
## Entry names follow the spec's Fig. 3 (`ffid`, `chan`, `iline`, `xline`,
## `sht_x`, `rec_y`, `cdp_x`, ...), lower case. `inline` is accepted for
## `iline` (D-8.1 uses both).

import std/[strutils, xmlparser, xmltree]
import ./binheader

type
  LayoutType* = enum
    ## Entry value types (D-8 Table 13).
    ltInt2 = "int2", ltInt4 = "int4", ltInt8 = "int8"
    ltUInt2 = "uint2", ltUInt4 = "uint4", ltUInt8 = "uint8"
    ltIbmFp = "ibmfp", ltIeee32 = "ieee32", ltIeee64 = "ieee64"
    ltLineTrc = "linetrc", ltReelTrc = "reeltrc"       ## u32
    ltLineTrc8 = "linetrc8", ltReelTrc8 = "reeltrc8"   ## u64
    ltCoor4 = "coor4"   ## i32 scaled by `co_scal`.
    ltElev4 = "elev4"   ## i32 scaled by `ed_scal`.
    ltTime2 = "time2"   ## i16 scaled by `tm_scal`.
    ltSpNum4 = "spnum4" ## i32 scaled by `sp_scal`.
    ltScale6 = "scale6" ## i32 mantissa × 10^(i16 exponent).

  LayoutEntry* = object
    ## Where one named value lives.
    name*: string      ## Lower case, e.g. `iline`.
    extension*: string ## "" for the standard header, else the header name, e.g. `SEG00001`.
    byte*: int         ## 1-based byte within its 240-byte header.
    kind*: LayoutType
    ifNonZero*: bool   ## Overrides earlier entries of the same name only when non-zero.

  TraceLayout* = object
    ## An ordered set of entries; for a repeated name the last applicable one wins.
    name*: string
    desc*: string
    entries*: seq[LayoutEntry]

func size*(kind: LayoutType): int =
  ## Bytes occupied by a value of `kind`.
  case kind
  of ltInt2, ltUInt2, ltTime2: 2
  of ltInt4, ltUInt4, ltIbmFp, ltIeee32, ltLineTrc, ltReelTrc, ltCoor4, ltElev4, ltSpNum4: 4
  of ltInt8, ltUInt8, ltIeee64, ltLineTrc8, ltReelTrc8: 8
  of ltScale6: 6

func normalizeEntryName*(s: string): string =
  ## Lower case, with `inline` mapped to `iline`.
  result = s.strip.toLowerAscii
  if result == "inline": result = "iline"

const rev2Entries = [
  ("linetrc", "", 1, "linetrc", false),
  ("reeltrc", "", 5, "reeltrc", false),
  ("ffid", "", 9, "int4", false),
  ("chan", "", 13, "int4", false),
  ("espnum", "", 17, "int4", false),
  ("cdp", "", 21, "int4", false),
  ("cdptrc", "", 25, "int4", false),
  ("trctype", "", 29, "int2", false),
  ("vstack", "", 31, "int2", false),
  ("fold", "", 33, "int2", false),
  ("rectype", "", 35, "int2", false),
  ("offset", "", 37, "int4", false),
  ("relev", "", 41, "elev4", false),
  ("selev", "", 45, "elev4", false),
  ("sdepth", "", 49, "elev4", false),
  ("rdatum", "", 53, "elev4", false),
  ("sdatum", "", 57, "elev4", false),
  ("wdepthso", "", 61, "elev4", false),
  ("wdepthrc", "", 65, "elev4", false),
  ("ed_scal", "", 69, "int2", false),
  ("co_scal", "", 71, "int2", false),
  ("sht_x", "", 73, "coor4", false),
  ("sht_y", "", 77, "coor4", false),
  ("rec_x", "", 81, "coor4", false),
  ("rec_y", "", 85, "coor4", false),
  ("coorunit", "", 89, "int2", false),
  ("wvel", "", 91, "int2", false),
  ("subwvel", "", 93, "int2", false),
  ("shuphole", "", 95, "time2", false),
  ("rcuphole", "", 97, "time2", false),
  ("shstat", "", 99, "time2", false),
  ("rcstat", "", 101, "time2", false),
  ("stapply", "", 103, "time2", false),
  ("lagtimea", "", 105, "time2", false),
  ("lagtimeb", "", 107, "time2", false),
  ("delay", "", 109, "time2", false),
  ("mutestrt", "", 111, "time2", false),
  ("muteend", "", 113, "time2", false),
  ("nsamps", "", 115, "uint2", false),
  ("dt", "", 117, "uint2", false),
  ("gaintype", "", 119, "int2", false),
  ("ingconst", "", 121, "int2", false),
  ("initgain", "", 123, "int2", false),
  ("corrflag", "", 125, "int2", false),
  ("sweepsrt", "", 127, "int2", false),
  ("sweepend", "", 129, "int2", false),
  ("sweeplng", "", 131, "int2", false),
  ("sweeptyp", "", 133, "int2", false),
  ("sweepstp", "", 135, "int2", false),
  ("sweepetp", "", 137, "int2", false),
  ("tapertyp", "", 139, "int2", false),
  ("aliasfil", "", 141, "int2", false),
  ("aliaslop", "", 143, "int2", false),
  ("notchfil", "", 145, "int2", false),
  ("notchslp", "", 147, "int2", false),
  ("lowcut", "", 149, "int2", false),
  ("highcut", "", 151, "int2", false),
  ("lowcslop", "", 153, "int2", false),
  ("hicslop", "", 155, "int2", false),
  ("year", "", 157, "int2", false),
  ("day", "", 159, "int2", false),
  ("hour", "", 161, "int2", false),
  ("minute", "", 163, "int2", false),
  ("second", "", 165, "int2", false),
  ("timebase", "", 167, "int2", false),
  ("trweight", "", 169, "int2", false),
  ("rstaswp1", "", 171, "int2", false),
  ("rstatrc1", "", 173, "int2", false),
  ("rstatrcn", "", 175, "int2", false),
  ("gapsize", "", 177, "int2", false),
  ("overtrvl", "", 179, "int2", false),
  ("cdp_x", "", 181, "coor4", false),
  ("cdp_y", "", 185, "coor4", false),
  ("iline", "", 189, "int4", false),
  ("xline", "", 193, "int4", false),
  ("sp", "", 197, "spnum4", false),
  ("sp_scal", "", 201, "int2", false),
  ("samp_unit", "", 203, "int2", false),
  ("trans_const", "", 205, "scale6", false),
  ("trans_unit", "", 211, "int2", false),
  ("dev_id", "", 213, "int2", false),
  ("tm_scal", "", 215, "int2", false),
  ("src_type", "", 217, "int2", false),
  ("src_dir1", "", 219, "int2", false),
  ("src_dir2", "", 221, "int2", false),
  ("src_dir3", "", 223, "int2", false),
  ("smeasure", "", 225, "scale6", false),
  ("sm_unit", "", 231, "int2", false),
  ("linetrc", "SEG00001", 1, "linetrc8", true),
  ("reeltrc", "SEG00001", 9, "reeltrc8", true),
  ("ffid", "SEG00001", 17, "int8", true),
  ("cdp", "SEG00001", 25, "int8", true),
  ("relev", "SEG00001", 33, "ieee64", true),
  ("rdepth", "SEG00001", 41, "ieee64", false),
  ("selev", "SEG00001", 49, "ieee64", true),
  ("sdepth", "SEG00001", 57, "ieee64", true),
  ("rdatum", "SEG00001", 65, "ieee64", true),
  ("sdatum", "SEG00001", 73, "ieee64", true),
  ("wdepthso", "SEG00001", 81, "ieee64", true),
  ("wdepthrc", "SEG00001", 89, "ieee64", true),
  ("sht_x", "SEG00001", 97, "ieee64", true),
  ("sht_y", "SEG00001", 105, "ieee64", true),
  ("rec_x", "SEG00001", 113, "ieee64", true),
  ("rec_y", "SEG00001", 121, "ieee64", true),
  ("offset", "SEG00001", 129, "ieee64", true),
  ("nsamps", "SEG00001", 137, "uint4", true),
  ("nanosecs", "SEG00001", 141, "int4", false),
  ("dt", "SEG00001", 145, "ieee64", true),
  ("cable_num", "SEG00001", 153, "int4", false),
  ("last_trc", "SEG00001", 159, "int2", false),
  ("cdp_x", "SEG00001", 161, "ieee64", true),
  ("cdp_y", "SEG00001", 169, "ieee64", true),
]
  ## The spec's Fig. 3 (standard Rev 2 layout); ns/dt typed u16 per the
  ## spec-note resolution.

func standardLayout*(rev: SegyRevision): TraceLayout =
  ## The standard layout of a revision: Fig. 3 (Rev 2), Fig. 4 (Rev 1:
  ## without Extension 1) or Fig. 5 (Rev 0: bytes 1-179 only, times unscaled).
  result = TraceLayout(name: "rev" & $rev.major, desc: "SEG-Y Rev " & $rev & " standard entries")
  for (name, ext, b, t, inz) in rev2Entries:
    var e = LayoutEntry(name: name, extension: ext, byte: b, kind: parseEnum[LayoutType](t),
      ifNonZero: inz)
    if rev.major >= 2 or (ext == "" and (rev.major == 1 or b < 181)):
      if rev.major == 0 and e.kind == ltTime2: e.kind = ltInt2
      result.entries.add e

proc addEntry(r: var TraceLayout, n: XmlNode, ext: string) =
  let name = normalizeEntryName(n.attr("name"))
  let b = n.attr("byte").strip
  let t = n.attr("type").strip.toLowerAscii
  if name.len == 0 or b.len == 0 or not b.allCharsInSet(Digits) or b.len > 4:
    raise newException(ValueError, "Layout XML: entry '" & name & "' has no valid byte")
  var kind: LayoutType
  try:
    kind = parseEnum[LayoutType](t)
  except ValueError:
    raise newException(ValueError, "Layout XML: entry '" & name & "' has unknown type '" &
      t & "'")
  let pos = parseInt(b)
  if pos < 1 or pos + kind.size - 1 > 240:
    raise newException(ValueError, "Layout XML: entry '" & name & "' at byte " & $pos &
      " does not fit a 240-byte header")
  let inz = n.attr("if-non-zero").strip.toLowerAscii in ["1", "true", "yes"]
  r.entries.add LayoutEntry(name: name, extension: ext, byte: pos, kind: kind, ifNonZero: inz)

proc parseLayout*(xml: string): TraceLayout =
  ## Parses a D-8 layout document. Raises `ValueError` for malformed XML or
  ## entries (bad byte, unknown type, an entry that does not fit its header).
  var root: XmlNode
  try:
    root = parseXml(xml.strip)
  except XmlError as e:
    raise newException(ValueError, "Layout XML: " & e.msg)
  except CatchableError as e:
    raise newException(ValueError, "Layout XML: " & e.msg)
  if root.tag != "segy-layout":
    raise newException(ValueError, "Layout XML: root element is <" & root.tag &
      ">, not <segy-layout>")
  result = TraceLayout(name: root.attr("name"))
  for n in root:
    if n.kind == xnElement:
      case n.tag
      of "desc": result.desc = n.innerText.strip
      of "entry": result.addEntry(n, "")
      of "extension":
        let ext = n.attr("name").strip
        for m in n:
          if m.kind == xnElement and m.tag == "entry": result.addEntry(m, ext)
      else: discard

func overlaps(a, b: LayoutEntry): bool =
  a.extension == b.extension and a.byte < b.byte + b.kind.size and b.byte < a.byte + a.kind.size

func merge*(base, file: TraceLayout): TraceLayout =
  ## `file` (a Layout stanza) over `base` (a standard layout): file entries
  ## come last, so they win for their names, and base entries whose bytes a
  ## file entry reuses for something else are dropped (Inglewood puts CDP X at
  ## byte 73, so the standard `sht_x` there no longer applies).
  result = TraceLayout(name: file.name, desc: file.desc)
  for e in base.entries:
    var reused = false
    for f in file.entries:
      if f.name != e.name and overlaps(e, f): reused = true
    if not reused: result.entries.add e
  result.entries.add file.entries

func find*(layout: TraceLayout, name: string): seq[LayoutEntry] =
  ## The entries for `name` in order (apply the last applicable one).
  let n = normalizeEntryName(name)
  for e in layout.entries:
    if e.name == n: result.add e
