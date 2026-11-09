## SEG-2 header model (spec note `seg2.md` §2-§4): the File Descriptor Block
## (`Seg2File`), the Trace Descriptor Blocks (`Seg2Trace`) and their keyword
## strings, with typed getters for the standard keywords.
##
## Byte positions in this module are 0-based, as the SEG-2 paper numbers
## them, and every binary field is in the file's byte order: the File
## Descriptor Block ID `0x3A55` reads `55 3A` in a little-endian (PC) file and
## `3A 55` in a big-endian one.
##
## Strings are kept verbatim and in file order (`Seg2String`: keyword as
## written, value with the terminators stripped), so vendor keywords,
## mixed-case keywords and unsorted lists survive. Lookups match keywords
## case-insensitively and take the first match; `[]=` sets a value (the first
## match, else a new string at the end) and `formatNumber` writes numbers as
## the standard spells them.
##
## `Seg2FileFixed` and `Seg2TraceFixed` describe the fixed parts as layout
## types, for named header fields (`model/headerfields`).

import std/[algorithm, math, options, parseutils, strutils, times]
import ../common/[endians, fieldlayout, years]
import ./samples
export options, endians
export samples except decodeSeg2SamplesRaw

const
  Seg2FileBlockId* = 0x3A55'u16  ## File Descriptor Block ID, in file byte order.
  Seg2TraceBlockId* = 0x4422'u16 ## Trace Descriptor Block ID, in file byte order.
  Seg2FixedSize* = 32            ## Bytes of the fixed part of either descriptor block.
  Seg2MaxTraces* = 16383         ## Largest trace count the standard allows.

type
  Seg2String* = object
    ## One keyword string of a descriptor block.
    key*: string   ## The keyword as written (uppercase per the spec; case kept).
    value*: string ## The text after the keyword's separator, terminators stripped.

  Seg2File* = object
    ## The File Descriptor Block: fixed part, trace pointers and file strings.
    order*: ByteOrder       ## From the block ID: `boLittle` or `boBig`.
    revision*: uint16       ## Bytes 2-3; 1 for the 1990 standard.
    pointerBytes*: uint16   ## Bytes 4-5 (M): size of the Trace Pointer Subblock.
    traceCount*: uint16     ## Bytes 6-7 (N) as written; `pointers` may hold fewer.
    stringTerm*: string     ## Bytes 8-10: the String Terminator (1 or 2 chars).
    lineTerm*: string       ## Bytes 11-13: the Line Terminator inside NOTE (1 or 2 chars).
    pointers*: seq[uint32]  ## File offsets of the Trace Descriptor Blocks, in pointer order.
    strings*: seq[Seg2String] ## The file strings, in file order.

  Seg2Trace* = object
    ## One Trace Descriptor Block (its Data Block follows it).
    offset*: int64          ## File offset of the block (its trace pointer).
    valid*: bool
      ## The block lies in the file and has the `0x4422` ID. An invalid trace
      ## is still indexed (so trace numbers match the pointers) but not decoded.
    blockSize*: uint16      ## Bytes 2-3: the whole block, strings and padding included.
    dataSize*: uint32       ## Bytes 4-7: the Data Block's size in bytes.
    numSamples*: uint32     ## Bytes 8-11, as written.
    formatCode*: uint8      ## Byte 12: the sample format code.
    strings*: seq[Seg2String] ## The trace strings, in file order.

  Seg2Header* = Seg2File | Seg2Trace ## Either descriptor block (both hold strings).

  Seg2FileFixed* = object
    ## The fixed part of the File Descriptor Block as a layout (0-based
    ## bytes): the named fields `file.<field>`.
    blockId* {.at: 0.}: uint16
    revision* {.at: 2.}: uint16
    pointerBytes* {.at: 4.}: uint16
    traceCount* {.at: 6.}: uint16
    stringTermLength* {.at: 8.}: uint8
    stringTerm* {.at: 9.}: array[2, char]
    lineTermLength* {.at: 11.}: uint8
    lineTerm* {.at: 12.}: array[2, char]

  Seg2TraceFixed* = object
    ## The fixed part of a Trace Descriptor Block as a layout (0-based
    ## bytes): the named fields `trace.<field>`.
    blockId* {.at: 0.}: uint16
    blockSize* {.at: 2.}: uint16
    dataSize* {.at: 4.}: uint32
    numSamples* {.at: 8.}: uint32
    formatCode* {.at: 12.}: uint8

  Seg2Location* = object
    ## A `SOURCE_LOCATION` / `RECEIVER_LOCATION` value, in the file's `UNITS`.
    x*, y*, z*: float64
      ## A one-value location (x along the line) has y = 0 and z = NaN; z is
      ## relative to `DATUM`.
    values*: int ## How many coordinates were given (1 to 3).

  Seg2TraceSort* = enum
    ## The file's `TRACE_SORT`.
    tsAsAcquired = "AS_ACQUIRED", tsCdpGather = "CDP_GATHER", tsCdpStack = "CDP_STACK",
    tsCommonOffset = "COMMON_OFFSET", tsCommonReceiver = "COMMON_RECEIVER",
    tsCommonSource = "COMMON_SOURCE"

  Seg2Units* = enum
    ## The file's `UNITS` (linear units of every coordinate).
    unFeet = "FEET", unMeters = "METERS", unInches = "INCHES",
    unCentimeters = "CENTIMETERS", unNone = "NONE"

  Seg2TraceType* = enum
    ## A trace's `TRACE_TYPE`.
    ttSeismicData = "SEISMIC_DATA", ttDead = "DEAD", ttTestData = "TEST_DATA",
    ttUphole = "UPHOLE", ttRadarData = "RADAR_DATA"

# --------------------------------------------------------- fixed parts --

# `decodeFields` loads unchecked within `layoutBytes`: every layout must fit its block.
static: doAssert layoutBytes(Seg2FileFixed, 0) <= Seg2FixedSize and
  layoutBytes(Seg2TraceFixed, 0) <= Seg2FixedSize

func initSeg2File*(order = boLittle): Seg2File =
  ## An empty File Descriptor Block for writing: revision 1, `order` (PC
  ## files are little-endian), NUL as String Terminator and CR LF as Line
  ## Terminator (the standard's usual choices). Set `traceCount` (or
  ## `pointerBytes`) to size the trace pointers before writing.
  Seg2File(order: order, revision: 1, stringTerm: "\0", lineTerm: "\r\n")

func seg2Order*(b: openArray[byte]): Option[ByteOrder] =
  ## The byte order the first two bytes declare (`55 3A` little-endian,
  ## `3A 55` big-endian); none when they are not a SEG-2 block ID.
  if b.len < 2: none(ByteOrder)
  elif b[0] == 0x55 and b[1] == 0x3A: some(boLittle)
  elif b[0] == 0x3A and b[1] == 0x55: some(boBig)
  else: none(ByteOrder)

func isSeg2*(head: openArray[byte]): bool =
  ## Guesses whether `head` (the first bytes of a stream; 32 suffice, more
  ## let the first trace's block ID be checked) is SEG-2: the File Descriptor
  ## Block ID, then either the Trace Descriptor Block ID at the first trace
  ## pointer, or (when that pointer lies past `head` or is damaged) a
  ## plausible fixed part: M a non-zero multiple of 4, 1 <= N <= M/4 and
  ## terminator lengths of 1 or 2.
  let o = seg2Order(head)
  if o.isNone or head.len < Seg2FixedSize: return false
  let order = o.get
  let m = int(getNum[uint16](head, 4, order))
  let n = int(getNum[uint16](head, 6, order))
  if m >= 4 and head.len >= 36:
    let p = int64(getNum[uint32](head, 32, order))
    if p >= 32 and p + 2 <= head.len and getNum[uint16](head, int(p), order) == Seg2TraceBlockId:
      return true
  m >= 4 and m mod 4 == 0 and n in 1 .. m div 4 and head[8] in {1'u8, 2'u8} and
    head[11] in {1'u8, 2'u8}

# ------------------------------------------------------------- strings --

func isBlank(c: char): bool {.inline.} = c in {' ', '\t'}

func toSeg2String*(text: string): Seg2String =
  ## Splits the text of one string entry (terminators already stripped) into
  ## keyword and value: the keyword runs to the first space or tab, the value
  ## starts after the following spaces and tabs. Trailing spaces, tabs and
  ## NULs are dropped from the value.
  var i = 0
  while i < text.len and not text[i].isBlank: inc i
  var j = i
  while j < text.len and text[j].isBlank: inc j
  var e = text.len
  while e > j and text[e - 1] in {' ', '\t', '\0'}: dec e
  Seg2String(key: text[0 ..< i], value: text[j ..< e])

func find*(s: openArray[Seg2String], key: string): int =
  ## The index of the first string with keyword `key` (case-insensitive), -1
  ## if none.
  for i, x in s:
    if cmpIgnoreCase(x.key, key) == 0: return i
  -1

func value*(h: Seg2Header, key: string): Option[string] =
  ## The value of keyword `key` (case-insensitive, first match); none when
  ## the block has no such string.
  let i = h.strings.find(key)
  if i < 0: none(string) else: some(h.strings[i].value)

func contains*(h: Seg2Header, key: string): bool {.inline.} =
  ## The block has a string with keyword `key` (case-insensitive).
  h.strings.find(key) >= 0

proc `[]=`*(h: var Seg2Header, key, value: string) =
  ## Sets keyword `key`'s value: the first string with that keyword
  ## (case-insensitive) gets `value`, else a string is appended (the writer
  ## keeps the order; `sortStrings` puts it where the standard wants it).
  let i = h.strings.find(key)
  if i >= 0: h.strings[i].value = value
  else: h.strings.add Seg2String(key: key, value: value)

proc sortStrings*(s: var seq[Seg2String]) =
  ## Orders a string list as the standard wants: by keyword, `NOTE` last.
  ## The sort is stable, so repeated keywords keep their order.
  func rank(x: Seg2String): (bool, string) =
    (cmpIgnoreCase(x.key, "NOTE") == 0, x.key.toUpperAscii)
  s.sort(proc (a, b: Seg2String): int = cmp(rank(a), rank(b)))

func formatNumber*(x: float64): string =
  ## `x` as a SEG-2 decimal number: an integer without a point when `x` is
  ## integral (below 1e15), else the shortest text that reads back exactly,
  ## with an `E` exponent (`0.001`, `1.5E-30`). NaN and infinities have no
  ## SEG-2 spelling: the result is empty.
  if x.isNaN or x == Inf or x == -Inf: return ""
  if x == trunc(x) and abs(x) < 1e15: return $int64(x)
  let t = $x
  let e = t.find({'e', 'E'})
  if e < 0: return t
  var mant = t[0 ..< e]
  var expo = t[e + 1 .. ^1]
  var neg = false
  if expo.len > 0 and expo[0] in {'+', '-'}:
    neg = expo[0] == '-'
    expo = expo[1 .. ^1]
  while expo.len > 1 and expo[0] == '0': expo = expo[1 .. ^1]
  if mant.endsWith(".0"): mant.setLen mant.len - 2
  mant & "E" & (if neg: "-" else: "") & expo

func words(s: string): seq[string] =
  # Whitespace-separated words (spaces, tabs, line breaks).
  for w in s.splitWhitespace: result.add w

func parseNumber(w: string, x: var float64): bool =
  # A whole word as a decimal number (`12`, `-3.5`, `1.5E-4`).
  w.len > 0 and parseFloat(w, x) == w.len

func numbers*(h: Seg2Header, key: string): seq[float64] =
  ## The leading numeric words of keyword `key`'s value, in order (empty
  ## when the string is missing or starts with text). Brackets and a
  ## `n/N` element prefix (`[2/4] x y z`, as RECEIVER_GEOMETRY and
  ## SOURCE_GEOMETRY may write) are not numbers and stop the list.
  let v = h.value(key)
  if v.isSome:
    for w in v.get.words:
      var x: float64
      if not parseNumber(w, x): return
      result.add x

func number*(h: Seg2Header, key: string): Option[float64] =
  ## The first number of keyword `key`'s value; none when missing or not
  ## numeric.
  let n = h.numbers(key)
  if n.len > 0: some(n[0]) else: none(float64)

func integer*(h: Seg2Header, key: string): Option[int64] =
  ## The first number of keyword `key`'s value when it is integral; none
  ## otherwise. Large values (station numbers past 32767) are accepted.
  let n = h.number(key)
  if n.isSome and n.get == float64(int64(n.get)): some(int64(n.get)) else: none(int64)

func enumValue[E: enum](h: Seg2Header, key: string): Option[E] =
  let v = h.value(key)
  if v.isSome:
    let w = v.get.words
    if w.len > 0:
      for e in E:
        if cmpIgnoreCase(w[0], $e) == 0: return some(e)
  none(E)

func noteLines*(h: Seg2Header, lineTerm: string): seq[string] =
  ## The `NOTE` string split at the Line Terminator `lineTerm` (the file's
  ## `Seg2File.lineTerm`); empty without a NOTE.
  let v = h.value("NOTE")
  if v.isSome and v.get.len > 0:
    result = if lineTerm.len > 0: v.get.split(lineTerm) else: @[v.get]

# ----------------------------------------------------- typed trace keys --

func location(h: Seg2Header, key: string): Option[Seg2Location] =
  let n = h.numbers(key)
  case n.len
  of 0: none(Seg2Location)
  of 1: some(Seg2Location(x: n[0], y: 0, z: NaN, values: 1))
  of 2: some(Seg2Location(x: n[0], y: n[1], z: NaN, values: 2))
  else: some(Seg2Location(x: n[0], y: n[1], z: n[2], values: 3))

func sampleInterval*(t: Seg2Trace): Option[float64] {.inline.} =
  ## `SAMPLE_INTERVAL`: the sample period in seconds.
  t.number("SAMPLE_INTERVAL")

func delay*(t: Seg2Trace): Option[float64] {.inline.} =
  ## `DELAY`: seconds from the start pulse to the first sample.
  t.number("DELAY")

func channelNumber*(t: Seg2Trace): Option[int64] {.inline.} =
  ## `CHANNEL_NUMBER`: the recording channel.
  t.integer("CHANNEL_NUMBER")

func receiverLocation*(t: Seg2Trace): Option[Seg2Location] {.inline.} =
  ## `RECEIVER_LOCATION`: x, or x y z, in the file's `UNITS`.
  t.location("RECEIVER_LOCATION")

func sourceLocation*(t: Seg2Trace): Option[Seg2Location] {.inline.} =
  ## `SOURCE_LOCATION`: x, or x y z, in the file's `UNITS`.
  t.location("SOURCE_LOCATION")

func traceType*(t: Seg2Trace): Option[Seg2TraceType] {.inline.} =
  ## `TRACE_TYPE`; none when missing or not a standard value.
  enumValue[Seg2TraceType](t, "TRACE_TYPE")

func format*(t: Seg2Trace): Option[Seg2Format] {.inline.} =
  ## The sample format; none for an undefined code.
  toSeg2Format(int(t.formatCode))

func traceSort*(f: Seg2File): Option[Seg2TraceSort] {.inline.} =
  ## `TRACE_SORT`; none when missing or not a standard value.
  enumValue[Seg2TraceSort](f, "TRACE_SORT")

func units*(f: Seg2File): Option[Seg2Units] {.inline.} =
  ## `UNITS`; none when missing or not a standard value.
  enumValue[Seg2Units](f, "UNITS")

# ------------------------------------------------------------------ time --

const monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT",
  "NOV", "DEC"]

func parseDate(s: string, day, month, year: var int): bool =
  # `dd/mm/yyyy`, `dd/mm/yy` or `dd/MMM/yyyy`; also `-` or `.` as separator.
  let p = s.strip.split({'/', '-', '.'})
  if p.len != 3: return false
  if parseInt(p[0], day) != p[0].len or p[0].len == 0: return false
  if parseInt(p[1], month) != p[1].len or p[1].len == 0:
    month = monthNames.find(p[1].toUpperAscii) + 1
  if parseInt(p[2], year) != p[2].len or p[2].len == 0: return false
  if p[2].len <= 2: year = fullYear(year)
  day in 1..31 and month in 1..12 and year in 1..9999

func parseClock(s: string, secs: var float64): bool =
  # `hh:mm[:ss[.fff]]`, 24-hour.
  let p = s.strip.split(':')
  if p.len notin 2..3: return false
  var h, m: int
  var sec = 0.0
  if parseInt(p[0], h) != p[0].len or parseInt(p[1], m) != p[1].len: return false
  if p.len == 3 and not parseNumber(p[2], sec): return false
  secs = float64(h * 3600 + m * 60) + sec
  h in 0..23 and m in 0..59 and sec >= 0 and sec < 61

proc acquisitionTime*(f: Seg2File): Option[float64] =
  ## `ACQUISITION_DATE` and `ACQUISITION_TIME` as UTC seconds since 1970
  ## (the standard gives no time zone; UTC is assumed). Day first:
  ## `dd/mm/yyyy`, `dd/mm/yy` (50-99 are 19xx) or `dd/MMM/yyyy`. Without a
  ## time, midnight. None when the date is missing or unparsable; the raw
  ## strings stay in `strings`.
  let d = f.value("ACQUISITION_DATE")
  var day, month, year: int
  if d.isNone or not parseDate(d.get, day, month, year): return none(float64)
  var secs = 0.0
  let t = f.value("ACQUISITION_TIME")
  if t.isSome and not parseClock(t.get, secs): return none(float64)
  if day > getDaysInMonth(Month(month), year): return none(float64) # e.g. 31/02
  some(float64(daysFromCivil(year, month, day) * 86400) + secs)
