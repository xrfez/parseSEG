## Declarative fixed-layout headers.
##
## A header type declares each field once, with the spec's 1-based byte number
## as an `at` pragma:
##
## ```nim
## type TraceHeader = object
##   traceSeqLine* {.at: 1.}: int32
##   numSamples* {.at: 115.}: uint16
##   headerName* {.at: 233.}: array[8, char]
## ```
##
## `decodeFields`, `encodeFields` and `fieldTable` are derived from that
## declaration. The loops unroll at compile time, so decoding is a straight
## sequence of loads.
##
## Field types:
## - 1, 2, 4 or 8 byte integers and floats are numbers in the file's byte order;
## - `array[N, byte]` and `array[N, char]` are copied verbatim and never
##   reordered (raw or text bytes).
##
## Fields without an `at` pragma are not part of the layout; the owning module
## decodes them itself.

import std/macros
import ./endians

template at*(specByte: int) {.pragma.}
  ## The 1-based byte number of the field's first byte, as the spec numbers it.

type
  FieldKind* = enum
    ## How a field's bytes are interpreted.
    fkInt = "int"     ## Two's-complement integer.
    fkUInt = "uint"   ## Unsigned integer.
    fkFloat = "float" ## IEEE float.
    fkBytes = "bytes" ## Raw bytes, never reordered.
    fkText = "text"   ## Characters, never reordered.

  FieldSpec* = object
    ## One field of a fixed-layout header.
    name*: string   ## Nim field name.
    specByte*: int  ## 1-based spec byte number of the first byte.
    size*: int      ## Width in bytes.
    kind*: FieldKind

func kindOf[T](x: T): FieldKind =
  when T is SomeSignedInt: fkInt
  elif T is SomeUnsignedInt: fkUInt
  elif T is SomeFloat: fkFloat
  elif T is array:
    when typeof(x[0]) is char: fkText else: fkBytes
  else:
    {.error: "unsupported header field type: " & $T.}

func fieldTable*(T: typedesc): seq[FieldSpec] =
  ## The layout of `T`, in declaration order. Use it in a `const`.
  var x = default(T)
  for fieldName, v in fieldPairs(x):
    when v.hasCustomPragma(at):
      result.add FieldSpec(name: fieldName, specByte: v.getCustomPragmaVal(at),
        size: sizeof(v), kind: kindOf(v))

proc decodeFields*[T: object](h: var T, b: openArray[byte], firstByte: static int,
    order: ByteOrder) {.inline.} =
  ## Fills every `at` field of `h` from `b`, where `b[0]` holds spec byte
  ## `firstByte`.
  for _, v in fieldPairs(h):
    when v.hasCustomPragma(at):
      const pos = v.getCustomPragmaVal(at) - firstByte
      when v is array:
        for i in 0..<v.len:
          v[i] = typeof(v[0])(b[pos + i])
      else:
        v = getNum[typeof(v)](b, pos, order)

proc encodeFields*[T: object](h: T, b: var openArray[byte], firstByte: static int,
    order: ByteOrder) {.inline.} =
  ## Writes every `at` field of `h` into `b`, where `b[0]` holds spec byte
  ## `firstByte`.
  for _, v in fieldPairs(h):
    when v.hasCustomPragma(at):
      const pos = v.getCustomPragmaVal(at) - firstByte
      when v is array:
        for i in 0..<v.len:
          b[pos + i] = byte(v[i])
      else:
        putNum(b, pos, v, order)
