## Header field values and block descriptions (`FieldValue`, `HeaderBlock`,
## `HeaderScope`, `BlockRef`), shared by `model/headerfields`, the editor
## and the header listings; `model/headerfields` re-exports this module.

import std/strutils
import ../common/endians

type
  FieldValueKind* = enum
    ## The kind of value a header field holds.
    fvInt   ## Integers, BCD included.
    fvFloat ## Floats and fixed point.
    fvText  ## Character fields.

  FieldValue* = object
    ## A header field's value.
    case kind*: FieldValueKind
    of fvInt: intVal*: int64
    of fvFloat: floatVal*: float64
    of fvText: text*: string

  HeaderBlock* = enum
    ## The header block types that have named fields. Fields and edits by
    ## name reach the first eight; header listings (`model/headerlist`) show
    ## them all.
    hbSegyBinary = "SEG-Y binary"
    hbSegyTrace = "SEG-Y trace"
    hbSegyExt1 = "SEG-Y ext1"
    hbSegdTrace = "SEG-D trace"
    hbSegdExt1 = "SEG-D ext1"
    hbSegdExt1Rev3 = "SEG-D Rev 3 ext1"
    hbSegdGh1 = "SEG-D gh1"
    hbSegdGhN = "SEG-D ghN"
    hbSegdGh2 = "SEG-D gh2"
    hbSegdGh2Rev3 = "SEG-D Rev 3 gh2"
    hbSegdGh3Rev3 = "SEG-D Rev 3 gh3"
    hbSegdChannelSet = "SEG-D channel set"
    hbSegdChannelSetRev3 = "SEG-D Rev 3 channel set"
    hbSegdPosition = "SEG-D position"
    hbSegdSourceDescription = "SEG-D source description"
    hbSegdAdditionalSourceInfo = "SEG-D additional source info"
    hbSegdSensorInfo = "SEG-D sensor info"
    hbSegdTimestamp = "SEG-D timestamp"
    hbSegdSensorCalibration = "SEG-D sensor calibration"
    hbSegdTimeDrift = "SEG-D time drift"
    hbSegdOrientation = "SEG-D orientation"
    hbSegdTrailerDescription = "SEG-D trailer description"
    hbRaw = "raw" ## A block without named fields (listings only).
    hbSeg2File = "SEG-2 file"   ## The File Descriptor Block (fixed part and strings).
    hbSeg2Trace = "SEG-2 trace" ## A Trace Descriptor Block (fixed part and strings).

  HeaderScope* = enum
    ## Where a named field lives: the file (`fileField`), a SEG-D record
    ## (`recordField`) or a trace (`traceField`).
    hsFile = "file", hsRecord = "record", hsTrace = "trace"

  BlockRef* = object
    ## Where one header block of a file lies.
    kind*: HeaderBlock
    offset*: int64     ## Medium offset of the block's first byte.
    size*: int
    order*: ByteOrder
    name*: string      ## The block name as written (`trace`, `gh3`, ...).
    sourceIndex*: int  ## For `hbSegdGhN`: index into `SegdRecord.sourceHeaders`.

func toFieldValue*(v: SomeInteger): FieldValue =
  ## An integer value (`fvInt`).
  FieldValue(kind: fvInt, intVal: int64(v))

func toFieldValue*(v: SomeFloat): FieldValue =
  ## A float value (`fvFloat`).
  FieldValue(kind: fvFloat, floatVal: float64(v))

func toFieldValue*(v: string): FieldValue =
  ## A text value (`fvText`).
  FieldValue(kind: fvText, text: v)

func `==`*(a, b: FieldValue): bool =
  ## Same kind and value (floats compare as floats: NaN differs from NaN).
  a.kind == b.kind and (case a.kind
    of fvInt: a.intVal == b.intVal
    of fvFloat: a.floatVal == b.floatVal
    of fvText: a.text == b.text)

func `$`*(v: FieldValue): string =
  ## The value as written in edits and listings: text quoted and escaped.
  case v.kind
  of fvInt: $v.intVal
  of fvFloat: $v.floatVal
  of fvText: v.text.escape

func toFloat*(v: FieldValue): float64 =
  ## The value as a number (NaN for text).
  case v.kind
  of fvInt: float64(v.intVal)
  of fvFloat: v.floatVal
  of fvText: NaN
