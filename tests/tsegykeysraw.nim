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
  template g(name: string): float64 = refValue(f, t, name)
  func unset(x: float64): bool = x == 0 or x.isNaN
  result = initTraceKeys()
  result.record = g("ffid")
  result.ensemble = g("cdp")
  result.offset = g("offset")
  let esp = g("espnum")
  let sp = if esp.isNaN or esp == 0: g("sp") else: esp
  if sp != 0: result.srcPoint = sp
  if not (unset(g("sht_x")) and unset(g("sht_y"))): (result.srcX, result.srcY) = (g("sht_x"), g("sht_y"))
  if not (unset(g("rec_x")) and unset(g("rec_y"))): (result.rcvX, result.rcvY) = (g("rec_x"), g("rec_y"))
  result.srcZ = g("selev")
  result.rcvZ = g("relev")
  if not (unset(g("cdp_x")) and unset(g("cdp_y"))): (result.cmpX, result.cmpY) = (g("cdp_x"), g("cdp_y"))
  result.deriveGeometry()
  let h = t.header
  if h.traceNumberInField > 0: result.channel = float64(h.traceNumberInField)
  let code = int(h.traceIdCode)
  let base = if code >= 0: code and 0x3FFF else: code
  if base in 11..17 or base in 27..41: result.component = uint8(base)
  if h.year != 0:
    let timeBasis = if f.revision.major >= 2: f.binary.timeBasisCode else: 0'i16
    let basis = if h.timeBasisCode != 0: h.timeBasisCode else: timeBasis
    let year = fullYear(int(h.year))
    let s = if year notin 1..9999 or h.dayOfYear notin 1..366 or h.hour notin 0..23 or
        h.minute notin 0..59 or h.second notin 0..60: NaN
      else: float64(dateTime(year, mJan, 1, zone = utc()).toTime.toUnix +
        int64(h.dayOfYear - 1) * 86400 + int64(h.hour) * 3600 + int64(h.minute) * 60 +
        int64(h.second))
    let ns = if t.hasExt1: float64(t.ext1.nanoseconds) * 1e-9 else: 0.0
    result.time = case basis
      of 0, 2, 4: s + ns
      of 5:
        if s.isNaN: NaN
        else: timestampToUnix(int64(round((s - float64(GpsEpochUnix)) * 1e6))) + ns
      else: NaN

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
    "co_scal", "ed_scal", "tm_scal", "sp_scal", "other"]
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
        if round mod 4 != 0: f.layout = randomLayout() # else the standard layout
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
