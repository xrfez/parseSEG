## The per-trace geometry keys (`TraceKeys`) and their helpers, apart from
## the code that reads them from each standard (`model/keys`, which
## re-exports this module), so the library's SEG-Y key reader
## (`private/segykeys`) can build them.

import std/math

type
  TraceStatus* = enum
    ## What a trace holds (`TraceKeys.status`).
    tsUnknown   ## The headers do not say (SEG-Y trace code 0, -1 or an optional code).
    tsLive      ## Seismic data.
    tsDead      ## Dead or intentionally zeroed (SEG-Y codes 2 and 3, SEG-D trace edit 1 and 2,
                ## SEG-2 `TRACE_TYPE DEAD`).
    tsAuxiliary ## Not seismic data: SEG-Y time break, uphole, sweep, timing, water break,
                ## gun signature, vibrator and velocity/depth pair codes; SEG-D channel types
                ## other than seismic (and EM); SEG-2 `TEST_DATA` and `UPHOLE`.

  TraceCodeRev* = enum
    ## The SEG-Y revision a `TraceKeys.traceCode` is numbered in.
    tcrCaller ## The caller's code, in the numbering of the file it is written to.
    tcrRev0   ## Read from a Rev 0 file (codes 1-8 defined).
    tcrRev1   ## Read from a Rev 1 file (codes 1-22 defined).
    tcrRev2   ## Read from a Rev 2 file (codes 1-41 defined).

  SensorClass* = enum
    ## Which SPS receiver point-code letter a trace matches (`sensorClass`).
    scUnknown = "unknown"       ## Sensor not identified: matches no letter.
    scHydrophone = "hydrophone" ## Pressure / hydrophone: `H*`.
    scGeophone = "geophone"     ## Geophone or particle motion: `G*`.
    scOther = "other"           ## Another identified receiver: `R*`.

  TraceKeys* = object
    ## Geometry of one trace (NaN / 0 where unknown).
    record*: float64     ## SEG-Y field record number; SEG-D file number.
    ensemble*: float64   ## SEG-Y ensemble (CDP) number; NaN for SEG-D.
    offset*: float64     ## SEG-Y source-receiver offset; NaN for SEG-D.
    srcLine*, srcPoint*: float64
      ## The source station. SEG-Y has a point only (the energy source point,
      ## or the scaled shotpoint when that is the same point with its
      ## fraction), unless the file's Layout stanza names `sht_line`,
      ## `sht_point`, `sht_index` (as a SEG-D file converted by this library
      ## does).
    srcX*, srcY*: float64
    rcvLine*, rcvPoint*: float64
      ## The receiver station; SEG-Y: only from a Layout stanza's `rec_line`,
      ## `rec_point`, `rec_index`.
    rcvX*, rcvY*: float64
    srcZ*, rcvZ*: float64 ## Source and receiver elevation (SEG-Y scaled; SEG-D coordinate 3).
    cmpX*, cmpY*: float64 ## Midpoint: SEG-Y CDP X/Y, else halfway between source and receiver.
    srcIndex*: int16     ## SEG-D source point index.
    rcvIndex*: int16     ## SEG-D receiver point index.
    depthIndex*, reshootIndex*: uint8 ## SEG-D Rev 3 THE#1 bytes 10 and 8.
    sensorType*: uint8   ## SEG-D THE#1 byte 21.
    component*: uint8    ## Distinguishes the components of one station (see module doc).
    traceCode*: int16
      ## SEG-Y trace identification code (the layout's `trctype`: bytes 29-30
      ## unless a Layout stanza moves it) as stored; 0 when unknown and for
      ## SEG-D and SEG-2.
    status*: TraceStatus ## Live, dead or auxiliary (see `TraceStatus`).
    traceCodeRev*: TraceCodeRev
      ## The revision `traceCode` is numbered in: the SEG-Y reader sets it to
      ## the file's, so the writer can tell a code the source revision left
      ## undefined (status unknown) from one the output revision defines
      ## differently, and does not carry it over. `tcrCaller` (the default,
      ## also for SEG-D and SEG-2) is a code the caller chose for the output.
    channel*: float64
      ## Channel (trace) number in the field record: SEG-Y the layout's `chan`
      ## (bytes 13-16; NaN when 0, and when a Layout stanza keeps something
      ## else there), SEG-D the demux trace number (Rev 3: extended when
      ## `FFFF`). Survey relation records (SPS X) map (record, channel) to
      ## stations.
    time*: float64
      ## When the trace was recorded, in UTC POSIX seconds (fractional); NaN if
      ## unknown. SEG-Y: the layout's date and time fields (trace bytes
      ## 157-168) in their time basis; SEG-D: GH#1, for Rev 3 the trace's
      ## Timestamp block or the GH#3 time zero (see the module documentation).
    t0Ms*: float64
      ## Time of sample 0 in ms (in ms also for SEG-Y depth data, whose "time"
      ## fields hold depths). SEG-Y: the delay recording time (the layout's
      ## `delay`: bytes 109-110) times the time scalar (bytes 215-216, Rev 1
      ## and later; 0 means 1); SEG-D: the channel set's start time; SEG-2:
      ## DELAY × 1000. 0 when the field is unset, NaN when the headers cannot
      ## give it (an unknown SEG-D channel set, a SEG-Y Layout stanza that
      ## keeps something else in the delay's bytes).
    intervalUs*: float64
      ## The trace's sample interval in µs (Hz or m/ft for SEG-Y non-time
      ## data), exactly as `sampleIntervalUs(f, trace)` resolves it; NaN when
      ## the headers cannot give it.
    inline*, crossline*: float64
      ## SEG-Y: the layout's `iline` and `xline` (Rev 1 and later: bytes 189 and
      ## 193, unless a Layout stanza or vendor map moves them); 0 counts as
      ## unset. NaN when unset, and for SEG-D and SEG-2.

func initTraceKeys*(): TraceKeys =
  ## All values unknown.
  TraceKeys(record: NaN, ensemble: NaN, offset: NaN, srcLine: NaN, srcPoint: NaN, srcX: NaN,
    srcY: NaN, rcvLine: NaN, rcvPoint: NaN, rcvX: NaN, rcvY: NaN, srcZ: NaN, rcvZ: NaN,
    cmpX: NaN, cmpY: NaN, channel: NaN, time: NaN, t0Ms: NaN, intervalUs: NaN, inline: NaN,
    crossline: NaN)

func isSeismic*(k: TraceKeys): bool {.inline.} =
  ## The trace is not auxiliary (live, dead or of unknown status).
  k.status != tsAuxiliary

func hasSourceXY*(k: TraceKeys): bool {.inline.} =
  ## Both source coordinates are known.
  not (k.srcX.isNaN or k.srcY.isNaN)

func hasReceiverXY*(k: TraceKeys): bool {.inline.} =
  ## Both receiver coordinates are known.
  not (k.rcvX.isNaN or k.rcvY.isNaN)

func classOfSegd(t: uint8): SensorClass {.inline.} =
  case t
  of 1: scHydrophone
  of 2 .. 9: scGeophone
  of 21, 22: scOther
  else: scUnknown

func classOfSegy(code: int): SensorClass {.inline.} =
  # Rev 2 bit 14 is the interpolated flag, not part of the identification.
  let base = if code >= 0: code and 0x3FFF else: code
  case base
  of 11: scHydrophone
  of 12 .. 17, 39 .. 41: scGeophone
  of 27 .. 38: scOther
  else: scUnknown

func sensorClass*(k: TraceKeys): SensorClass =
  ## The sensor class of a trace, for matching an SPS receiver point code
  ## (`H*` hydrophone, `G*` geophone or other particle-motion sensor, `R*`
  ## any other identified receiver). Unknown matches no letter.
  ##
  ## SEG-D `sensorType` (THE#1 byte 21), when it is not 0, decides and
  ## `component` is not consulted (Rev 3 stores a group index there):
  ## 1 hydrophone; 2-5 geophone and 6-9 accelerometer (particle motion);
  ## 21 (0x15) electric dipole and 22 (0x16) magnetic coil (other). Any
  ## other non-zero value is unknown.
  ##
  ## Otherwise the SEG-Y trace identification code (`traceCode`, bit 14
  ## cleared when the code is non-negative), or `component` when `traceCode`
  ## is 0 and `component` holds a component code (SEG-2 writes 12, 13 or 14):
  ## 11 pressure sensor (hydrophone); 12-17 vertical, cross-line, in-line
  ## and rotated particle motion, and 39-41 rotational pitch, roll and yaw
  ## (geophone); 27-38 electric and magnetic field components (other).
  ## Anything else, including 0, -1 and 1 (seismic, sensor not named), is
  ## unknown.
  if k.sensorType != 0: return classOfSegd(k.sensorType)
  let code = if k.traceCode != 0: int(k.traceCode) else: int(k.component)
  classOfSegy(code)

func deriveGeometry*(k: var TraceKeys, overwrite = false) =
  ## Fills `offset` (the source-receiver distance) and the midpoint from the
  ## coordinates when both ends are known. An existing non-zero offset (e.g.
  ## SEG-Y's signed header offset) and midpoint are kept unless `overwrite`;
  ## a zero offset counts as unset (SEG-Y headers hold 0 when not filled).
  if k.hasSourceXY and k.hasReceiverXY:
    if overwrite or k.offset.isNaN or k.offset == 0:
      k.offset = hypot(k.rcvX - k.srcX, k.rcvY - k.srcY)
    if overwrite or k.cmpX.isNaN or k.cmpY.isNaN:
      k.cmpX = (k.srcX + k.rcvX) / 2
      k.cmpY = (k.srcY + k.rcvY) / 2
