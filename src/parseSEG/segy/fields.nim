## Named trace header values resolved through the file's layout (task 3.4d).
##
## `fieldValue(file, trace, "iline")` reads the inline number from wherever
## the file keeps it: the standard bytes, a Layout stanza's bytes, or Trace
## Header Extension 1 when its value is non-zero, with scalars applied
## (`coor4` by `co_scal`, `elev4` by `ed_scal`, `time2` by `tm_scal`,
## `spnum4` by `sp_scal`). `geometry` collects the common values of a trace.

import std/options
import ./reader
import ../private/segykeys

type
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

  GeometryReader* = GeometryPlan
    ## The layout lookups of `geometry`, resolved once per file: reading a
    ## trace's geometry then does no name lookups and no allocation.

proc fieldValue*(f: SegyFile, t: SegyTrace, name: string): Option[float64] =
  ## Resolves the layout entry `name` (e.g. `iline`, `cdp_x`, `ffid`) for
  ## trace `t`, scaled; none if the layout has no applicable entry. For many
  ## traces of the common values, use a `GeometryReader`.
  var x: float64
  withRawHeaders(f.byteOrder, t, h):
    result = if planValue(initFieldPlan(f.layoutOf, name), h, f.byteOrder, x): some(x)
             else: none(float64)

func initGeometryReader*(f: SegyFile): GeometryReader =
  ## Resolves the file's layout for `geometry`.
  initGeometryPlan(f)

func timeBasis*(g: GeometryReader): int16 {.inline.} =
  ## The file's time basis code (binary 3511-3512; 0 before Rev 2, where
  ## those bytes are unassigned). A trace's own code (bytes 167-168)
  ## overrides it when non-zero.
  g.planTimeBasis

proc geometry*(g: GeometryReader, t: SegyTrace): TraceGeometry =
  ## The common values of trace `t` of the file `g` was made for.
  withRawHeaders(g.planOrder, t, h):
    let v = geometryValues(g, h)
    result = TraceGeometry(fieldRecord: v[gfFfid], channel: v[gfChan],
      energySourcePoint: v[gfEspnum], ensemble: v[gfCdp], traceInEnsemble: v[gfCdptrc],
      inline: v[gfIline], crossline: v[gfXline], offset: v[gfOffset],
      sourceX: v[gfShtX], sourceY: v[gfShtY], groupX: v[gfRecX], groupY: v[gfRecY],
      cdpX: v[gfCdpX], cdpY: v[gfCdpY], receiverElevation: v[gfRelev],
      sourceSurfaceElevation: v[gfSelev], sourceDepth: v[gfSdepth],
      coordinateUnits: v[gfCoorunit], shotpoint: v[gfSp])

proc geometry*(f: SegyFile, t: SegyTrace): TraceGeometry =
  ## The common values of trace `t`, resolved through the file's layout. For
  ## many traces, make one `initGeometryReader(f)` and use it instead.
  initGeometryReader(f).geometry(t)
