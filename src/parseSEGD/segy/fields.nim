## Named trace header values resolved through the file's layout (task 3.4d).
##
## `fieldValue(file, trace, "iline")` reads the inline number from wherever
## the file keeps it: the standard bytes, a Layout stanza's bytes, or Trace
## Header Extension 1 when its value is non-zero, with scalars applied
## (`coor4` by `co_scal`, `elev4` by `ed_scal`, `time2` by `tm_scal`,
## `spnum4` by `sp_scal`). `geometry` collects the common values of a trace.

import std/[math, strutils]
import ../common/[endians, ibmfloat]
import ./[traceheader, layout, reader]

type
  TraceView = object
    # The trace's headers as raw bytes in the file's byte order.
    std: array[TraceHeaderSize, byte]
    ext1: array[TraceHeaderSize, byte]
    hasExt1: bool
    order: ByteOrder

  TraceGeometry* = object
    ## Common per-trace values, NaN where the layout has no entry (or the
    ## entry's header is absent). Coordinates and elevations are scaled.
    fieldRecord*, channel*, energySourcePoint*: float64
    ensemble*, traceInEnsemble*: float64
    inline*, crossline*: float64
    offset*: float64
    sourceX*, sourceY*, groupX*, groupY*, cdpX*, cdpY*: float64
    receiverElevation*, sourceSurfaceElevation*, sourceDepth*: float64
    coordinateUnits*: float64
    shotpoint*: float64

func initView(f: SegyFile, t: SegyTrace): TraceView =
  result.order = f.byteOrder
  t.header.encode(result.std, f.byteOrder)
  if t.hasExt1:
    result.hasExt1 = true
    t.ext1.encode(result.ext1, f.byteOrder)

func raw(v: TraceView, t: SegyTrace, e: LayoutEntry, value: var float64): bool =
  # Reads an entry's unscaled value; false if its header is absent.
  template read(b: openArray[byte]): untyped =
    let p = e.byte - 1
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
      float64(getNum[int32](b, p, v.order)) * pow(10.0, float64(getNum[int16](b, p + 4, v.order)))
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

func evaluate(lay: TraceLayout, v: TraceView, t: SegyTrace, name: string,
    value: var float64, depth = 0): bool =
  # The last applicable entry for `name` wins; if-non-zero entries apply only
  # when non-zero. Scaled kinds look up their scalar the same way.
  result = false
  for e in lay.find(name):
    var x: float64
    if raw(v, t, e, x) and (not e.ifNonZero or x != 0):
      let scalarName = case e.kind
        of ltCoor4: "co_scal"
        of ltElev4: "ed_scal"
        of ltTime2: "tm_scal"
        of ltSpNum4: "sp_scal"
        else: ""
      if scalarName.len > 0 and depth == 0:
        var s: float64
        # A scalar typed wider than int2 by a Layout stanza may not fit;
        # an unusable one is ignored rather than wrapped.
        if evaluate(lay, v, t, scalarName, s, depth + 1) and s == trunc(s) and
            s >= -32768.0 and s <= 32767.0:
          x = applyScalar(x, int16(s))
      value = x
      result = true

proc fieldValue*(f: SegyFile, t: SegyTrace, name: string, value: var float64): bool =
  ## Resolves the layout entry `name` (e.g. `iline`, `cdp_x`, `ffid`) for
  ## trace `t`. False if the layout has no applicable entry.
  evaluate(f.layoutOf, initView(f, t), t, name, value)

proc geometry*(f: SegyFile, t: SegyTrace): TraceGeometry =
  ## The common values of trace `t`, resolved through the file's layout.
  let lay = f.layoutOf
  let v = initView(f, t)
  template get(name: string): float64 =
    (var x: float64; if evaluate(lay, v, t, name, x): x else: NaN)
  TraceGeometry(fieldRecord: get("ffid"), channel: get("chan"), energySourcePoint: get("espnum"),
    ensemble: get("cdp"), traceInEnsemble: get("cdptrc"), inline: get("iline"),
    crossline: get("xline"), offset: get("offset"), sourceX: get("sht_x"),
    sourceY: get("sht_y"), groupX: get("rec_x"), groupY: get("rec_y"), cdpX: get("cdp_x"),
    cdpY: get("cdp_y"), receiverElevation: get("relev"), sourceSurfaceElevation: get("selev"),
    sourceDepth: get("sdepth"), coordinateUnits: get("coorunit"), shotpoint: get("sp"))
