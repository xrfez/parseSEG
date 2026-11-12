## Exact sample re-encoding for the SEG-Y conversions (`convert`).
##
## A conversion decodes each trace to float64 and writes it in the target
## format; a trace whose values the target cannot hold exactly is reported.
## `encodeExact` checks that by encoding, decoding the result again and
## comparing: the reference, kept as the fallback and as the tests' oracle.
## `encodeChecked` gives the same bytes, verdict and raises in one pass: each
## sample's encoded word is decoded on the spot (float64 targets need no
## check, float32 one compare, integers a rounding compare; a value an
## integer format cannot hold sends the trace to `encodeExact` for its error).
## `copyFloatWords` moves IEEE float samples between byte orders without the
## float64 round trip, with the same bytes as that round trip.

import std/math
import ../common/[endians, ibmfloat, errors]
import ../segy/samples

proc encodeExact*(fmt: SampleFormat, vals: openArray[float64], dst: var seq[byte],
    order: ByteOrder, scratch: var seq[float64]): bool =
  ## Encodes, then decodes back: false if any value changed (rounding,
  ## float32 narrowing, overflow to infinity). Raises like `encodeSamples`.
  ## Both buffers are overwritten whole: no zero-fill.
  dst.setLenUninit vals.len * sampleSize(fmt)
  encodeSamples(fmt, vals, dst, order)
  scratch.setLenUninit vals.len
  decodeSamples(fmt, dst, scratch, order)
  for i in 0..<vals.len:
    if scratch[i] != vals[i] and not (scratch[i].isNaN and vals[i].isNaN): return false
  true

template eachOrder(order: ByteOrder, o: untyped, body: untyped) =
  # `body` once per byte order, with `o` a constant.
  case order
  of boBig:
    const o = boBig
    body
  of boLittle:
    const o = boLittle
    body
  of boPairSwapped:
    const o = boPairSwapped
    body

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

func toStored[T: uint16 | uint32 | uint64](x: T, order: static ByteOrder): T {.inline.} =
  # Native `x` as host-order bits of its bytes stored in `order` (and back:
  # each reordering is its own inverse).
  const lowBytes = when T is uint32: 0x00FF_00FF'u32 else: 0x00FF_00FF_00FF_00FF'u64
  template pairs(y: T): T =
    when T is uint16: swapBytes(y) else: ((y and lowBytes) shl 8) or ((y shr 8) and lowBytes)
  when order == hostOrder: x
  elif order == boPairSwapped:
    when hostOrder == boLittle: pairs(swapBytes(x)) else: pairs(x)
  else: swapBytes(x)

func storeNum[T: SomeNumber](p: ByteBuf, pos: int, v: T, order: static ByteOrder) {.inline.} =
  # Writes `v` in `order` at `pos`, unchecked (the store side of `loadNum`).
  when sizeof(T) == 1:
    p[pos] = cast[uint8](v)
  else:
    type U = (when sizeof(T) == 2: uint16 elif sizeof(T) == 4: uint32 else: uint64)
    var u = toStored(cast[U](v), order)
    copyMem(addr p[pos], addr u, sizeof(U))

func storeU24(p: ByteBuf, pos: int, v: uint32, order: static ByteOrder) {.inline.} =
  when order == boLittle:
    p[pos] = uint8(v and 0xFF)
    p[pos + 1] = uint8((v shr 8) and 0xFF)
    p[pos + 2] = uint8((v shr 16) and 0xFF)
  else:
    p[pos] = uint8((v shr 16) and 0xFF)
    p[pos + 1] = uint8((v shr 8) and 0xFF)
    p[pos + 2] = uint8(v and 0xFF)

proc encodeChecked*(fmt: SampleFormat, vals: openArray[float64], dst: var seq[byte],
    order: ByteOrder, scratch: var seq[float64]): bool =
  ## `encodeExact` in one pass, with the same bytes in `dst`, result and
  ## raises. Format 4 and the 8-byte integers go through `encodeExact`
  ## (`scratch`), as do 3-byte formats in pair-swapped order (which it
  ## refuses).
  if fmt in {sfFixedGain, sfInt64, sfUInt64} or
      (order == boPairSwapped and fmt in {sfInt24, sfUInt24}):
    return encodeExact(fmt, vals, dst, order, scratch)
  let n = vals.len
  dst.setLenUninit n * sampleSize(fmt) # every byte is written below
  if n == 0: return true
  let d = cast[ByteBuf](addr dst[0])
  let v = cast[ptr UncheckedArray[float64]](addr vals[0])
  var lost = 0 # or-ed flags, no branch per sample
  template differs(back, x: float64): int =
    ord(back != x) and not (ord(back != back) and ord(x != x)) # NaN == NaN here
  var outside = 0
  template ints(I: typedesc, lo, hi: untyped, put: untyped) =
    # Rounded to nearest, as `encodeSamples` does. Values outside `lo..hi`
    # (or NaN) are only flagged here: `encodeExact` then raises its error.
    const a = float64(lo)
    const b = float64(hi)
    for i {.inject.} in 0..<n:
      let r = round(v[i])
      outside = outside or ord(not (r >= a and r <= b))
      let k {.inject.} = I(max(a, min(r, b))) # in range: no undefined conversion
      put
      lost = lost or ord(float64(k) != v[i])
  eachOrder(order, o):
    case fmt
    of sfFloat64:
      for i in 0..<n: storeNum(d, 8*i, v[i], o) # float64 to float64: always exact
    of sfFloat32:
      for i in 0..<n:
        let f = float32(v[i])
        storeNum(d, 4*i, f, o)
        lost = lost or (ord(float64(f) != v[i]) and ord(v[i] == v[i])) # NaN stays NaN
    of sfIbm32:
      for i in 0..<n:
        let w = float32ToIbm(float32(v[i]))
        storeNum(d, 4*i, w, o)
        lost = lost or differs(ibmToFloat64(w), v[i])
    of sfInt32:
      ints(int32, low(int32), high(int32)):
        storeNum(d, 4*i, k, o)
    of sfInt16:
      ints(int16, low(int16), high(int16)):
        storeNum(d, 2*i, k, o)
    of sfInt8:
      ints(int8, low(int8), high(int8)):
        d[i] = cast[byte](k)
    of sfUInt32:
      ints(uint32, low(uint32), high(uint32)):
        storeNum(d, 4*i, k, o)
    of sfUInt16:
      ints(uint16, low(uint16), high(uint16)):
        storeNum(d, 2*i, k, o)
    of sfUInt8:
      ints(uint8, low(uint8), high(uint8)):
        d[i] = k
    of sfInt24:
      when o != boPairSwapped: # sent to encodeExact above
        ints(int32, -0x80_0000, 0x7F_FFFF):
          storeU24(d, 3*i, cast[uint32](k) and 0xFF_FFFF'u32, o)
    of sfUInt24:
      when o != boPairSwapped:
        ints(uint32, 0, 0xFF_FFFF):
          storeU24(d, 3*i, k, o)
    of sfFixedGain, sfInt64, sfUInt64: discard # sent to encodeExact above
  if outside != 0: return encodeExact(fmt, vals, dst, order, scratch) # raises
  lost == 0

proc copyFloatWords*(T: typedesc[float32 | float64], src: openArray[byte], srcOrder: ByteOrder,
    n: int, dst: var seq[byte], dstOrder: ByteOrder) =
  ## `n` IEEE floats of type `T` from `src` (stored in `srcOrder`) into `dst`
  ## in `dstOrder`, with the bytes of decoding them to float64 and encoding
  ## that as `T` (always exact): float64 bits unchanged, float32 bits
  ## unchanged except that a signaling NaN comes out quiet, as the
  ## conversion to float64 makes it. `src` must hold the samples.
  type U = (when T is float32: uint32 else: uint64)
  dst.setLenUninit n * sizeof(U)
  if n == 0: return
  let s = byteBuf(src)
  let d = cast[ByteBuf](addr dst[0])
  eachOrder(srcOrder, so):
    eachOrder(dstOrder, to):
      for i in 0..<n:
        var u = loadNum[U](s, sizeof(U) * i, so)
        when T is float32:
          if (u and 0x7F80_0000'u32) == 0x7F80_0000'u32 and (u and 0x7F_FFFF'u32) != 0:
            u = u or 0x40_0000'u32 # quiet NaN
        storeNum(d, sizeof(U) * i, u, to)

{.pop.}
