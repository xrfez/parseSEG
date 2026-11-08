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
## Fields without a layout pragma are not part of the layout; the owning
## module decodes them itself.
##
## SEG-D packs fields on nibbles and uses BCD, 24-bit integers and fixed
## point. Those use the other pragmas (all big-endian; `order` only applies
## to `at`):
##
## | Pragma | Field type | Bytes |
## |---|---|---|
## | `bcdAt(b, digits)` / `bcdAtL(b, digits)` | int: BCD digits from the high / low nibble (note 1) | digits nibbles |
## | `nibAt(b)` / `nibAtL(b)` | uint8: the high / low nibble of byte b, binary | 1 nibble |
## | `at24(b)` | int32 / uint32: 3-byte two's complement / unsigned | 3 |
## | `fix40(b)` | float64: `i24.u16` fixed point (note 2); encode rounds to 2^-16 | 5 |
## | `fix24(b)` | float64: `u16.u8` fixed point; encode rounds to 2^-8 | 3 |
##
## Note 1: starting at byte b; -1 = all `F` (sentinel), -2 = not BCD.
## Note 2: signed integer part, binary fraction.
##
## `encodeChanged` writes only the fields that differ from the bytes already
## in the buffer, so undefined bytes, invalid BCD and vendor quirks in an
## unedited header survive a round trip unchanged.

import std/[macros, math]
import ./[endians, bcd, errors]

template at*(specByte: int) {.pragma.}
  ## The 1-based byte number of the field's first byte, as the spec numbers it.
template bcdAt*(specByte: int, digits: int) {.pragma.}
  ## BCD digits starting at the high nibble of `specByte`.
template bcdAtL*(specByte: int, digits: int) {.pragma.}
  ## BCD digits starting at the low nibble of `specByte`.
template nibAt*(specByte: int) {.pragma.}
  ## The high nibble of `specByte` as a binary number.
template nibAtL*(specByte: int) {.pragma.}
  ## The low nibble of `specByte` as a binary number.
template at24*(specByte: int) {.pragma.}
  ## A 3-byte big-endian integer.
template fix40*(specByte: int) {.pragma.}
  ## A 5-byte `i24.u16` fixed-point number.
template fix24*(specByte: int) {.pragma.}
  ## A 3-byte `u16.u8` fixed-point number.

const
  BcdAllF* = -1  ## A BCD field holding only `F` nibbles (a "see extended field" sentinel).
  BcdInvalid* = -2 ## A BCD field holding a non-decimal nibble.

type
  FieldKind* = enum
    ## How a field's bytes are interpreted.
    fkInt = "int"     ## Two's-complement integer.
    fkUInt = "uint"   ## Unsigned integer.
    fkFloat = "float" ## IEEE float.
    fkBytes = "bytes" ## Raw bytes, never reordered.
    fkText = "text"   ## Characters, never reordered.
    fkBcd = "bcd"     ## Packed BCD digits.
    fkNibble = "nibble" ## A binary nibble.
    fkFixed = "fixed" ## Fixed-point binary.

  FieldSpec* = object
    ## One field of a fixed-layout header.
    name*: string   ## Nim field name.
    specByte*: int  ## 1-based spec byte number of the first byte.
    size*: int      ## Width in bytes (0 for nibble-sized fields; see `nibbles`).
    kind*: FieldKind
    firstNibble*: int ## 0-based nibble index of the first nibble within the block.
    nibbles*: int     ## Width in nibbles.

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
      const b = v.getCustomPragmaVal(at)
      result.add FieldSpec(name: fieldName, specByte: b, size: sizeof(v), kind: kindOf(v),
        firstNibble: 2 * (b - 1), nibbles: 2 * sizeof(v))
    elif v.hasCustomPragma(bcdAt):
      const p = v.getCustomPragmaVal(bcdAt)
      result.add FieldSpec(name: fieldName, specByte: p.specByte, kind: fkBcd,
        firstNibble: 2 * (p.specByte - 1), nibbles: p.digits)
    elif v.hasCustomPragma(bcdAtL):
      const p = v.getCustomPragmaVal(bcdAtL)
      result.add FieldSpec(name: fieldName, specByte: p.specByte, kind: fkBcd,
        firstNibble: 2 * (p.specByte - 1) + 1, nibbles: p.digits)
    elif v.hasCustomPragma(nibAt):
      const b = v.getCustomPragmaVal(nibAt)
      result.add FieldSpec(name: fieldName, specByte: b, kind: fkNibble,
        firstNibble: 2 * (b - 1), nibbles: 1)
    elif v.hasCustomPragma(nibAtL):
      const b = v.getCustomPragmaVal(nibAtL)
      result.add FieldSpec(name: fieldName, specByte: b, kind: fkNibble,
        firstNibble: 2 * (b - 1) + 1, nibbles: 1)
    elif v.hasCustomPragma(at24):
      const b = v.getCustomPragmaVal(at24)
      result.add FieldSpec(name: fieldName, specByte: b, size: 3, kind: kindOf(v),
        firstNibble: 2 * (b - 1), nibbles: 6)
    elif v.hasCustomPragma(fix40):
      const b = v.getCustomPragmaVal(fix40)
      result.add FieldSpec(name: fieldName, specByte: b, size: 5, kind: fkFixed,
        firstNibble: 2 * (b - 1), nibbles: 10)
    elif v.hasCustomPragma(fix24):
      const b = v.getCustomPragmaVal(fix24)
      result.add FieldSpec(name: fieldName, specByte: b, size: 3, kind: fkFixed,
        firstNibble: 2 * (b - 1), nibbles: 6)

func decodeBcdField(b: openArray[byte], first, digits: int): int =
  if isAllF(b, first, digits):
    result = BcdAllF
  else:
    result = 0
    for n in first..<first + digits:
      let d = nibble(b, n)
      if d > 9: return BcdInvalid
      result = result * 10 + int(d)

func get40(b: openArray[byte], pos: int): int64 {.inline.} =
  # 5-byte big-endian two's complement.
  var u = 0'u64
  for i in 0..4: u = (u shl 8) or uint64(b[pos + i])
  cast[int64](u shl 24) shr 24

template decodeOne(v: untyped, b: openArray[byte], firstByte: static int,
    order: ByteOrder) =
  when v.hasCustomPragma(at):
    const pos = v.getCustomPragmaVal(at) - firstByte
    when v is array:
      for i in 0..<v.len:
        v[i] = typeof(v[0])(b[pos + i])
    else:
      v = getNum[typeof(v)](b, pos, order)
  elif v.hasCustomPragma(bcdAt):
    const p = v.getCustomPragmaVal(bcdAt)
    v = decodeBcdField(b, 2 * (p.specByte - firstByte), p.digits)
  elif v.hasCustomPragma(bcdAtL):
    const p = v.getCustomPragmaVal(bcdAtL)
    v = decodeBcdField(b, 2 * (p.specByte - firstByte) + 1, p.digits)
  elif v.hasCustomPragma(nibAt):
    v = nibble(b, 2 * (v.getCustomPragmaVal(nibAt) - firstByte))
  elif v.hasCustomPragma(nibAtL):
    v = nibble(b, 2 * (v.getCustomPragmaVal(nibAtL) - firstByte) + 1)
  elif v.hasCustomPragma(at24):
    const pos = v.getCustomPragmaVal(at24) - firstByte
    when v is int32: v = beI24(b, pos) else: v = beU24(b, pos)
  elif v.hasCustomPragma(fix40):
    v = float64(get40(b, v.getCustomPragmaVal(fix40) - firstByte)) / 65536.0
  elif v.hasCustomPragma(fix24):
    v = float64(beU24(b, v.getCustomPragmaVal(fix24) - firstByte)) / 256.0

proc encodeBcdField(b: var openArray[byte], first, digits, value: int, name: string) =
  if value == BcdAllF:
    putAllF(b, first, digits)
  elif value == BcdInvalid:
    raiseFormat(name & ": the invalid-BCD marker cannot be written")
  else:
    # Check before writing, so a refused value leaves the buffer untouched.
    if value < 0 or (digits < 19 and value >= 10 ^ digits):
      raiseFormat(name & ": " & $value & " does not fit " & $digits & " BCD digits")
    putBcd(b, first, digits, value)

proc fixedToInt(x: float64, scale: float64, lo, hi: int64, name: string): int64 =
  # Rounds to the nearest representable value (e.g. 100.1 -> 100.1000061...);
  # refuses NaN and values out of range.
  let r = round(x * scale)
  if not (r >= float64(lo) and r <= float64(hi)):
    raiseFormat(name & ": " & $x & " is out of range for this fixed-point field")
  int64(r)

template encodeOne(v: untyped, name: string, b: var openArray[byte], firstByte: static int,
    order: ByteOrder) =
  when v.hasCustomPragma(at):
    const pos = v.getCustomPragmaVal(at) - firstByte
    when v is array:
      for i in 0..<v.len:
        b[pos + i] = byte(v[i])
    else:
      putNum(b, pos, v, order)
  elif v.hasCustomPragma(bcdAt):
    const p = v.getCustomPragmaVal(bcdAt)
    encodeBcdField(b, 2 * (p.specByte - firstByte), p.digits, int(v), name)
  elif v.hasCustomPragma(bcdAtL):
    const p = v.getCustomPragmaVal(bcdAtL)
    encodeBcdField(b, 2 * (p.specByte - firstByte) + 1, p.digits, int(v), name)
  elif v.hasCustomPragma(nibAt):
    if v > 15: raiseFormat(name & ": " & $v & " does not fit a nibble")
    setNibble(b, 2 * (v.getCustomPragmaVal(nibAt) - firstByte), uint8(v))
  elif v.hasCustomPragma(nibAtL):
    if v > 15: raiseFormat(name & ": " & $v & " does not fit a nibble")
    setNibble(b, 2 * (v.getCustomPragmaVal(nibAtL) - firstByte) + 1, uint8(v))
  elif v.hasCustomPragma(at24):
    const pos = v.getCustomPragmaVal(at24) - firstByte
    when v is int32:
      if v < -0x80_0000 or v > 0x7F_FFFF: raiseFormat(name & ": " & $v & " does not fit 24 bits")
      putBeI24(b, pos, v)
    else:
      if v > 0xFF_FFFF'u32: raiseFormat(name & ": " & $v & " does not fit 24 bits")
      putBeU24(b, pos, v)
  elif v.hasCustomPragma(fix40):
    const pos = v.getCustomPragmaVal(fix40) - firstByte
    let n = fixedToInt(v, 65536.0, -(1'i64 shl 39), (1'i64 shl 39) - 1, name)
    let u = cast[uint64](n)
    for i in 0..4: b[pos + i] = byte((u shr (8 * (4 - i))) and 0xFF)
  elif v.hasCustomPragma(fix24):
    const pos = v.getCustomPragmaVal(fix24) - firstByte
    putBeU24(b, pos, uint32(fixedToInt(v, 256.0, 0, 0xFF_FFFF, name)))

proc decodeFields*[T: object](h: var T, b: openArray[byte], firstByte: static int,
    order: ByteOrder) =
  ## Fills every layout field of `h` from `b`, where `b[0]` holds spec byte
  ## `firstByte`.
  for _, v in fieldPairs(h):
    decodeOne(v, b, firstByte, order)

proc encodeFields*[T: object](h: T, b: var openArray[byte], firstByte: static int,
    order: ByteOrder) =
  ## Writes every layout field of `h` into `b`, where `b[0]` holds spec byte
  ## `firstByte`. Raises `SegFormatError` for a value the field cannot hold.
  for name, v in fieldPairs(h):
    encodeOne(v, name, b, firstByte, order)

proc encodeChanged*[T: object](h: T, b: var openArray[byte], firstByte: static int,
    order: ByteOrder) =
  ## Writes only the layout fields of `h` whose values differ from what `b`
  ## already decodes to. With `b` holding the header as read, an unedited
  ## header comes out byte-identical. Raises `SegFormatError` for a value the
  ## field cannot hold.
  var old: T
  decodeFields(old, b, firstByte, order)
  for name, v in fieldPairs(h):
    var changed = false
    for name2, o in fieldPairs(old):
      when name == name2:
        changed = v != o
    if changed:
      encodeOne(v, name, b, firstByte, order)
