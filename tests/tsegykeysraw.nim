## SEG-Y layout values and keys from the raw header bytes (15.3-9) against
## the decode / re-encode implementation they replaced (kept here as the
## reference): `geometry`, `fieldValue`, `traceKeys` and the walk's
## `segyKeys`, on random headers through random layouts (every entry type,
## standard / Extension 1 / proprietary headers, if-non-zero, scalars) in
## every byte order, and on every trace of the sample files.

import std/[assertions, math, options, os, random, strutils, times]
import parseSEG
import parseSEG/common/[endians, ibmfloat, years]
import parseSEG/io/memsource
import parseSEG/private/[segykeys, segywalk]
import ./utils/testutils

# ------------------------------------------------- the reference (15.3-8) --

type
  RefView = object
    std, ext1: array[TraceHeaderSize, byte]
    hasExt1: bool
    order: ByteOrder

  RefResolved = object
    entry: LayoutEntry
    scalar: seq[LayoutEntry]

const refNames = ["ffid", "chan", "espnum", "cdp", "cdptrc", "iline", "xline", "offset",
  "sht_x", "sht_y", "rec_x", "rec_y", "cdp_x", "cdp_y", "relev", "selev", "sdepth",
  "coorunit", "sp"]

func refView(order: ByteOrder, t: SegyTrace): RefView =
  result = RefView(order: order, hasExt1: t.hasExt1)
  t.header.encode(result.std, order)
  if t.hasExt1: t.ext1.encode(result.ext1, order)

func refRaw(v: RefView, t: SegyTrace, e: LayoutEntry, value: var float64): bool =
  template read(b: openArray[byte]): untyped =
    let p = e.bytePos - 1
    case e.kind
    of ltInt2, ltTime2: float64(getNum[int16](b, p, v.order))
    of ltInt4, ltCoor4, ltElev4, ltSpNum4: float64(getNum[int32](b, p, v.order))
    of ltInt8: float64(getNum[int64](b, p, v.order))
    of ltUInt2: float64(getNum[uint16](b, p, v.order))
    of ltUInt4, ltLineTrc, ltReelTrc: float64(getNum[uint32](b, p, v.order))
    of ltUInt8, ltLineTrc8, ltReelTrc8: float64(getNum[uint64](b, p, v.order))
    of ltIbmFp: ibmToFloat64(getNum[uint32](b, p, v.order))
    of ltIeee32: float64(getNum[float32](b, p, v.order))
    of ltIeee64: getNum[float64](b, p, v.order)
    of ltScale6:
      float64(getNum[int32](b, p, v.order)) *
        pow(10.0, float64(getNum[int16](b, p + 4, v.order)))
  result = true
  if e.extension == "" or e.extension == "SEG00000":
    value = read(v.std)
  elif cmpIgnoreCase(e.extension, "SEG00001") == 0:
    if v.hasExt1: value = read(v.ext1) else: result = false
  else:
    result = false
    var i = 0
    while i + TraceHeaderSize <= t.proprietary.len and not result:
      if cmpIgnoreCase(headerBlockName(t.proprietary.toOpenArray(i, i + TraceHeaderSize - 1)),
          e.extension) == 0:
        value = read(t.proprietary.toOpenArray(i, i + TraceHeaderSize - 1))
        result = true
      i += TraceHeaderSize

func scalarName(k: LayoutType): string =
  case k
  of ltCoor4: "co_scal"
  of ltElev4: "ed_scal"
  of ltTime2: "tm_scal"
  of ltSpNum4: "sp_scal"
  else: ""

func refResolve(lay: TraceLayout, name: string): seq[RefResolved] =
  for e in lay.entriesFor(name):
    var r = RefResolved(entry: e)
    let sn = scalarName(e.kind)
    if sn.len > 0:
      for s in lay.entriesFor(sn): r.scalar.add s
    result.add r

func refPlain(es: openArray[LayoutEntry], v: RefView, t: SegyTrace, value: var float64): bool =
  for e in es:
    var x: float64
    if refRaw(v, t, e, x) and (not e.ifNonZero or x != 0):
      value = x
      result = true

func refEval(rs: openArray[RefResolved], v: RefView, t: SegyTrace, value: var float64): bool =
  for r in rs:
    var x: float64
    if refRaw(v, t, r.entry, x) and (not r.entry.ifNonZero or x != 0):
      var s: float64
      if r.scalar.len > 0 and refPlain(r.scalar, v, t, s) and s == trunc(s) and
          s >= -32768.0 and s <= 32767.0:
        x = applyScalar(x, int16(s))
      value = x
      result = true

proc refValue(f: SegyFile, t: SegyTrace, name: string): float64 =
  if not refEval(refResolve(f.layoutOf, name), refView(f.byteOrder, t), t, result):
    result = NaN

proc refKeys(f: SegyFile, t: SegyTrace): TraceKeys =
  # Every value through the layout, entry by entry (the keys read the trace
  # code, the delay and the date at their standard bytes when the layout has
  # them there, which this reference does not know about), except the
  # sample interval, which is read where the reader reads it.
  template g(name: string): float64 = refValue(f, t, name)
  func unset(x: float64): bool = x == 0 or x.isNaN
  func whole16(x: float64, default: int): int =
    if x == trunc(x) and x >= -32768.0 and x <= 32767.0: int(x) else: default
  result = initTraceKeys()
  result.record = g("ffid")
  result.ensemble = g("cdp")
  result.offset = g("offset")
  # The scaled shotpoint when it is the energy source point with its
  # fraction, or the only one.
  let esp = g("espnum")
  let shot = g("sp")
  let sp = if unset(esp): shot elif not unset(shot) and round(shot) == esp: shot else: esp
  if sp != 0: result.srcPoint = sp
  # The stations a layout names (the library's converters store them).
  if not (unset(g("sht_line")) and unset(g("sht_point"))):
    if not g("sht_line").isNaN: result.srcLine = g("sht_line")
    if not g("sht_point").isNaN: result.srcPoint = g("sht_point")
  if not (unset(g("rec_line")) and unset(g("rec_point"))):
    if not g("rec_line").isNaN: result.rcvLine = g("rec_line")
    if not g("rec_point").isNaN: result.rcvPoint = g("rec_point")
  if whole16(g("sht_index"), 0) != 0: result.srcIndex = int16(whole16(g("sht_index"), 0))
  if whole16(g("rec_index"), 0) != 0: result.rcvIndex = int16(whole16(g("rec_index"), 0))
  if not (unset(g("sht_x")) and unset(g("sht_y"))): (result.srcX, result.srcY) = (g("sht_x"), g("sht_y"))
  if not (unset(g("rec_x")) and unset(g("rec_y"))): (result.rcvX, result.rcvY) = (g("rec_x"), g("rec_y"))
  result.srcZ = g("selev")
  result.rcvZ = g("relev")
  if not (unset(g("cdp_x")) and unset(g("cdp_y"))): (result.cmpX, result.cmpY) = (g("cdp_x"), g("cdp_y"))
  result.deriveGeometry()
  let h = t.header
  if g("chan") > 0: result.channel = g("chan")
  let code = whole16(g("trctype"), 0)
  let base = if code >= 0: code and 0x3FFF else: code
  if base in 11..17 or base in 27..41: result.component = uint8(base)
  let yr = whole16(g("year"), 0)
  if yr != 0:
    let timeBasis = if f.revision.major >= 2: int(f.binary.timeBasisCode) else: 0
    let tb = whole16(g("timebase"), 0)
    let basis = if tb != 0: tb else: timeBasis
    let year = fullYear(yr)
    let (day, hour, minute, second) = (whole16(g("day"), -1), whole16(g("hour"), -1),
      whole16(g("minute"), -1), whole16(g("second"), -1))
    let s = if year notin 1..9999 or day notin 1..366 or hour notin 0..23 or
        minute notin 0..59 or second notin 0..60: NaN
      else: float64(dateTime(year, mJan, 1, zone = utc()).toTime.toUnix +
        int64(day - 1) * 86400 + int64(hour) * 3600 + int64(minute) * 60 + int64(second))
    let ns = if g("nanosecs").isNaN: 0.0 else: g("nanosecs") * 1e-9
    result.time = case basis
      of 0, 2, 4: s + ns
      of 5:
        if s.isNaN: NaN
        else: timestampToUnix(int64(round((s - float64(GpsEpochUnix)) * 1e6))) + ns
      else: NaN
  # Phase 16: timing, trace code and status.
  result.traceCode = int16(code)
  let rev = int(f.revision.major)
  let sb = if rev >= 2: base else: code
  let defined = if rev == 0: 1..8 elif rev == 1: 1..22 else: 1..41
  result.status =
    if sb notin defined: tsUnknown
    elif sb == 1 or sb in 11..17 or sb == 25 or sb in 27..41: tsLive
    elif sb in [2, 3]: tsDead
    else: tsAuxiliary
  result.t0Ms = g("delay")
  result.intervalUs =
    if rev >= 1 and f.binary.fixedLengthTraces == 1: f.binary.effectiveSampleInterval
    elif t.hasExt1 and t.ext1.extSampleInterval != 0 and not t.ext1.extSampleInterval.isNaN:
      t.ext1.extSampleInterval
    else: float64(h.sampleInterval)
  if not unset(g("iline")): result.inline = g("iline")
  if not unset(g("xline")): result.crossline = g("xline")

# ------------------------------------------------------------- checks --

func same(a, b: float64): bool = cast[uint64](a) == cast[uint64](b) or (a.isNaN and b.isNaN)

proc sameKeys(a, b: TraceKeys): bool =
  for x, y in fields(a, b):
    when x is float64:
      if not same(x, y): return false
    else:
      if x != y: return false
  true

proc checkTrace(f: SegyFile, gr: GeometryReader, t: SegyTrace, raw: RawHeaders, what: string) =
  let g = gr.geometry(t)
  let want = [refValue(f, t, "ffid"), refValue(f, t, "cdp_x"), refValue(f, t, "sht_y"),
    refValue(f, t, "selev"), refValue(f, t, "sp"), refValue(f, t, "iline")]
  doAssert same(g.fieldRecord, want[0]) and same(g.cdpX, want[1]) and same(g.sourceY, want[2]) and
    same(g.sourceSurfaceElevation, want[3]) and same(g.shotpoint, want[4]) and
    same(g.inline, want[5]), what
  for e in f.layoutOf.entries:
    let v = f.fieldValue(t, e.name)
    let r = refValue(f, t, e.name)
    doAssert (v.isNone and r.isNaN) or (v.isSome and same(v.get, r)), what & " " & e.name
  let k = refKeys(f, t)
  doAssert sameKeys(gr.traceKeys(t), k), what
  doAssert sameKeys(segyKeys(gr, raw), k), what & " (raw)"

var rng = initRand(1539)

proc randomLayout(): TraceLayout =
  # Entries of every type at random positions in the standard header,
  # Extension 1 (in its spellings) or two proprietary headers, for the
  # geometry names and their scalars; a third of them if-non-zero.
  const exts = ["", "SEG00000", "SEG00001", "seg00001", "PROP0001", "prop0002", "NOPE0003"]
  const names = ["ffid", "chan", "espnum", "cdp", "cdptrc", "iline", "xline", "offset", "sht_x",
    "sht_y", "rec_x", "rec_y", "cdp_x", "cdp_y", "relev", "selev", "sdepth", "coorunit", "sp",
    "co_scal", "ed_scal", "tm_scal", "sp_scal", "other", "trctype", "delay", "year", "day",
    "hour", "minute", "second", "timebase", "nanosecs", "sht_line", "sht_point", "sht_index",
    "rec_line", "rec_point", "rec_index", "other2", "other3"]
  for i in 0..<60:
    let kind = LayoutType(rng.rand(ord(high(LayoutType))))
    result.entries.add LayoutEntry(name: names[rng.rand(names.high)],
      extension: exts[rng.rand(exts.high)], bytePos: 1 + rng.rand(TraceHeaderSize - kind.size),
      kind: kind, ifNonZero: rng.rand(2) == 0)

proc randomHeader(b: var array[TraceHeaderSize, byte]) =
  for x in b.mitems: x = byte(rng.rand(255))
  # Mostly small numbers: zeros and usable scalars show up.
  for i in 0..<TraceHeaderSize:
    if rng.rand(3) > 0: b[i] = 0
  if rng.rand(1) == 0:
    b[rng.rand(TraceHeaderSize - 1)] = byte(rng.rand(5))

block encode_decode_round_trip:
  # The raw path reads the bytes the reader decoded; the old path re-encoded
  # the decoded header. They agree because the codec is a byte-exact round
  # trip of all 240 bytes (standard and Extension 1).
  for order in [boBig, boLittle, boPairSwapped]:
    for n in 0..<2000:
      var b, back: array[TraceHeaderSize, byte]
      for x in b.mitems: x = byte(rng.rand(255))
      decodeTraceHeader(b, order).encode(back, order)
      doAssert back == b, $order
      decodeTraceHeaderExt1(b, order).encode(back, order)
      doAssert back == b, $order

block random_headers_through_random_layouts:
  for order in [boBig, boLittle, boPairSwapped]:
    for rev in [0'u8, 1, 2]:
      for round in 0..<40:
        var f = SegyFile(byteOrder: order, revision: SegyRevision(major: rev))
        f.binary.timeBasisCode = int16(rng.rand(6))
        # The revision's standard layout, a stanza over it (some fields
        # moved, some of their bytes reused), or nothing standard at all.
        let standard = standardLayout(SegyRevision(major: rev, minor: 0))
        f.layout = if round mod 4 == 0: standard
                   elif round mod 4 == 1: merge(standard, randomLayout())
                   else: randomLayout()
        let gr = initGeometryReader(f)
        for n in 0..<50:
          var std, ext1: array[TraceHeaderSize, byte]
          randomHeader(std)
          randomHeader(ext1)
          var t = SegyTrace(header: decodeTraceHeader(std, order), hasExt1: rng.rand(3) > 0,
            ext1: decodeTraceHeaderExt1(ext1, order))
          if rng.rand(2) == 0: # dates that resolve
            t.header.year = int16(rng.rand(0..120))
            t.header.dayOfYear = int16(rng.rand(0..367))
            t.header.timeBasisCode = int16(rng.rand(0..6))
            t.header.encode(std, order)
          for p in 0..<rng.rand(3):
            var block240: array[TraceHeaderSize, byte]
            randomHeader(block240)
            let name = ["PROP0001", "PROP0002", "XYZ00009"][rng.rand(2)]
            for i, c in name: block240[232 + i] = byte(c)
            t.proprietary.add block240
          let raw = RawHeaders(std: cast[ByteBuf](addr std[0]),
            ext1: if t.hasExt1: cast[ByteBuf](addr ext1[0]) else: nil,
            prop: byteBuf(t.proprietary), propLen: t.proprietary.len)
          checkTrace(f, gr, t, raw, $order & " rev " & $rev & " round " & $round)

block fields_a_layout_stanza_moved:
  # A stanza that keeps the trace code, the delay with its scalar and the
  # date elsewhere and uses their standard bytes for other things; and one
  # that only takes the bytes away.
  proc keysOf(xml: string, std: array[TraceHeaderSize, byte]): TraceKeys =
    var f = SegyFile(byteOrder: boBig, revision: SegyRevision(major: 2, minor: 1))
    f.layout = merge(standardLayout(f.revision), parseLayout(xml))
    var h = std
    segyKeys(initGeometryReader(f), RawHeaders(std: cast[ByteBuf](addr h[0])))
  var b: array[TraceHeaderSize, byte]
  template put16(at, v: int) = putNum(b, at - 1, int16(v), boBig)
  put16(29, 2)       # standard trace code: dead
  put16(109, 100)    # standard delay
  put16(215, 10)     # standard time scalar
  put16(157, 2020); put16(159, 1); put16(161, 0); put16(163, 0); put16(165, 5); put16(167, 4)
  put16(13 + 2, 9)   # channel 9 (bytes 13-16)
  put16(181, 12)     # moved trace code: a vertical component
  put16(183, 30)     # moved delay
  put16(185, -10)    # moved time scalar
  put16(187, 2021); put16(189, 2); put16(191, 1); put16(193, 2); put16(195, 3); put16(197, 4)
  let standard = keysOf("<segy-layout/>", b)
  doAssert standard.traceCode == 2 and standard.status == tsDead and standard.component == 0
  doAssert standard.t0Ms == 1000 and standard.channel == 9
  doAssert standard.time == 1577836805.0 # 2020-01-01 00:00:05 UTC
  let moved = keysOf("""<segy-layout>
    <entry name="other" byte="29" type="int2"/> <entry name="trctype" byte="181" type="int2"/>
    <entry name="other2" byte="109" type="int2"/> <entry name="delay" byte="183" type="time2"/>
    <entry name="other3" byte="215" type="int2"/> <entry name="tm_scal" byte="185" type="int2"/>
    <entry name="year" byte="187" type="int2"/> <entry name="day" byte="189" type="int2"/>
    <entry name="hour" byte="191" type="int2"/> <entry name="minute" byte="193" type="int2"/>
    <entry name="second" byte="195" type="int2"/> <entry name="timebase" byte="197" type="int2"/>
    </segy-layout>""", b)
  doAssert moved.traceCode == 12 and moved.status == tsLive and moved.component == 12
  doAssert moved.t0Ms == 3 and moved.channel == 9
  doAssert moved.time == 1609459200.0 + 86400 + 3723 # 2021-01-02 01:02:03 UTC
  let gone = keysOf("""<segy-layout>
    <entry name="other" byte="29" type="int2"/> <entry name="other2" byte="109" type="int2"/>
    <entry name="other3" byte="157" type="int2"/> <entry name="iline" byte="13" type="int4"/>
    </segy-layout>""", b)
  doAssert gone.traceCode == 0 and gone.status == tsUnknown and gone.t0Ms.isNaN
  doAssert gone.time.isNaN and gone.channel.isNaN and gone.inline == 9
  doAssert gone.intervalUs == standard.intervalUs # read where the reader reads it

sampleBlock sample_files:
  # Every trace of the sample SEG-Y files: the reference, the public calls,
  # the walk's raw headers and the stored keys agree.
  for name in ["BO_3D-Inglewood_rev21_v7.sgy", "Sweep0.sgy"]:
    let path = exampleDir / name
    let src = openMemFileSource(path)
    var r = openSegyWalk(src)
    let gr = initGeometryReader(r.file)
    let fullSrc = openMemFileSource(path)
    var full = openSegy(fullSrc)
    var sf = openSeismic(path, keys = true)
    var t, ft: SegyTrace
    var i = 0
    while r.readTrace(t):
      doAssert full.readTrace(ft)
      doAssert t.numSamples == ft.numSamples and t.sampleInterval == ft.sampleInterval
      checkTrace(full.file, gr, ft, r.walkHeaders(t), name & " trace " & $i)
      doAssert sameKeys(sf.traceKeys(i), refKeys(full.file, ft)), name
      inc i
    doAssert i == sf.len and i > 0
    sf.close()
    src.close()
    fullSrc.close()
