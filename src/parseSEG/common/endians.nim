## Big-endian integer and IEEE float access on byte buffers.
##
## The SEG specs are big-endian; `getNum`/`putNum` also handle the little-endian
## and pair-swapped orders seen in SEG-Y files. Positions are 0-based byte offsets into the
## buffer. Out-of-range access is an index defect: callers check record
## sizes before decoding a block.

func beU8*(b: openArray[byte], pos: int): uint8 {.inline.} = b[pos]

func beI8*(b: openArray[byte], pos: int): int8 {.inline.} = cast[int8](b[pos])

func beU16*(b: openArray[byte], pos: int): uint16 {.inline.} =
  (uint16(b[pos]) shl 8) or uint16(b[pos+1])

func beI16*(b: openArray[byte], pos: int): int16 {.inline.} = cast[int16](beU16(b, pos))

func beU24*(b: openArray[byte], pos: int): uint32 {.inline.} =
  (uint32(b[pos]) shl 16) or (uint32(b[pos+1]) shl 8) or uint32(b[pos+2])

func beI24*(b: openArray[byte], pos: int): int32 {.inline.} =
  ## Sign-extends a 24-bit two's-complement value.
  cast[int32](beU24(b, pos) shl 8) shr 8

func beU32*(b: openArray[byte], pos: int): uint32 {.inline.} =
  (uint32(beU16(b, pos)) shl 16) or uint32(beU16(b, pos+2))

func beI32*(b: openArray[byte], pos: int): int32 {.inline.} = cast[int32](beU32(b, pos))

func beU64*(b: openArray[byte], pos: int): uint64 {.inline.} =
  (uint64(beU32(b, pos)) shl 32) or uint64(beU32(b, pos+4))

func beI64*(b: openArray[byte], pos: int): int64 {.inline.} = cast[int64](beU64(b, pos))

func beF32*(b: openArray[byte], pos: int): float32 {.inline.} = cast[float32](beU32(b, pos))

func beF64*(b: openArray[byte], pos: int): float64 {.inline.} = cast[float64](beU64(b, pos))

func putBeU8*(b: var openArray[byte], pos: int, v: uint8) {.inline.} = b[pos] = v

func putBeI8*(b: var openArray[byte], pos: int, v: int8) {.inline.} = b[pos] = cast[uint8](v)

func putBeU16*(b: var openArray[byte], pos: int, v: uint16) {.inline.} =
  b[pos] = uint8(v shr 8)
  b[pos+1] = uint8(v and 0xFF)

func putBeI16*(b: var openArray[byte], pos: int, v: int16) {.inline.} =
  putBeU16(b, pos, cast[uint16](v))

func putBeU24*(b: var openArray[byte], pos: int, v: uint32) {.inline.} =
  ## Writes the low 24 bits of `v`.
  b[pos] = uint8((v shr 16) and 0xFF)
  b[pos+1] = uint8((v shr 8) and 0xFF)
  b[pos+2] = uint8(v and 0xFF)

func putBeI24*(b: var openArray[byte], pos: int, v: int32) {.inline.} =
  ## Writes the low 24 bits of `v`; the caller ensures `v` fits in 24 bits.
  putBeU24(b, pos, cast[uint32](v))

func putBeU32*(b: var openArray[byte], pos: int, v: uint32) {.inline.} =
  putBeU16(b, pos, uint16(v shr 16))
  putBeU16(b, pos+2, uint16(v and 0xFFFF))

func putBeI32*(b: var openArray[byte], pos: int, v: int32) {.inline.} =
  putBeU32(b, pos, cast[uint32](v))

func putBeU64*(b: var openArray[byte], pos: int, v: uint64) {.inline.} =
  putBeU32(b, pos, uint32(v shr 32))
  putBeU32(b, pos+4, uint32(v and 0xFFFF_FFFF'u64))

func putBeI64*(b: var openArray[byte], pos: int, v: int64) {.inline.} =
  putBeU64(b, pos, cast[uint64](v))

func putBeF32*(b: var openArray[byte], pos: int, v: float32) {.inline.} =
  putBeU32(b, pos, cast[uint32](v))

func putBeF64*(b: var openArray[byte], pos: int, v: float64) {.inline.} =
  putBeU64(b, pos, cast[uint64](v))

# ---------------------------------------------------------------------------
# Byte-order-aware access (SEG-Y files may be little-endian or pair-swapped).

type
  ByteOrder* = enum
    ## Byte order of multi-byte binary fields. SEG-Y Rev 2 declares it with the
    ## marker 0x01020304 at binary header bytes 3297-3300.
    boBig = "big"                 ## Spec order: most significant byte first.
    boLittle = "little"           ## Every field's bytes reversed.
    boPairSwapped = "pairSwapped" ## Bytes swapped within each 16-bit pair.

func swapBytes*(x: uint16): uint16 {.inline.} = (x shl 8) or (x shr 8)

func swapBytes*(x: uint32): uint32 {.inline.} =
  (x shl 24) or ((x and 0xFF00'u32) shl 8) or ((x shr 8) and 0xFF00'u32) or (x shr 24)

func swapBytes*(x: uint64): uint64 {.inline.} =
  (uint64(swapBytes(uint32(x and 0xFFFF_FFFF'u64))) shl 32) or uint64(swapBytes(uint32(x shr 32)))

func swapPairs[T: uint32 | uint64](x: T): T {.inline.} =
  const lowBytes = when T is uint32: 0x00FF_00FF'u32 else: 0x00FF_00FF_00FF_00FF'u64
  ((x and lowBytes) shl 8) or ((x shr 8) and lowBytes)

func reorder[T: uint16 | uint32 | uint64](x: T, order: ByteOrder): T {.inline.} =
  ## Converts between big-endian and `order`. The mapping is its own inverse.
  case order
  of boBig: x
  of boLittle: swapBytes(x)
  of boPairSwapped:
    when T is uint16: swapBytes(x) else: swapPairs(x)

func getNum*[T: SomeNumber](b: openArray[byte], pos: int, order: ByteOrder): T {.inline.} =
  ## Reads a 1, 2, 4 or 8 byte number stored in `order` at byte offset `pos`.
  ## Single bytes are never reordered.
  when sizeof(T) == 1:
    cast[T](b[pos])
  elif sizeof(T) == 2:
    cast[T](reorder(beU16(b, pos), order))
  elif sizeof(T) == 4:
    cast[T](reorder(beU32(b, pos), order))
  elif sizeof(T) == 8:
    cast[T](reorder(beU64(b, pos), order))
  else:
    {.error: "getNum supports 1, 2, 4 and 8 byte numbers".}

func putNum*[T: SomeNumber](b: var openArray[byte], pos: int, v: T, order: ByteOrder) {.inline.} =
  ## Writes `v` in `order` at byte offset `pos`. Single bytes are never reordered.
  when sizeof(T) == 1:
    b[pos] = cast[uint8](v)
  elif sizeof(T) == 2:
    putBeU16(b, pos, reorder(cast[uint16](v), order))
  elif sizeof(T) == 4:
    putBeU32(b, pos, reorder(cast[uint32](v), order))
  elif sizeof(T) == 8:
    putBeU64(b, pos, reorder(cast[uint64](v), order))
  else:
    {.error: "putNum supports 1, 2, 4 and 8 byte numbers".}

# ---------------------------------------------------------------------------
# Unchecked loads for the sample decoders' hot loops. The caller checks the
# buffer's length once, up front; each load is then one machine load (and a
# byte swap when the stored order is not the host's), with no bounds check
# in any build.

const hostOrder* = when cpuEndian == littleEndian: boLittle else: boBig
  ## The byte order of this machine.

type ByteBuf* = ptr UncheckedArray[byte] ## Raw bytes whose length the caller has checked.

func byteBuf*(b: openArray[byte]): ByteBuf {.inline.} =
  ## The bytes of `b` as a `ByteBuf`; nil when `b` is empty.
  if b.len == 0: nil else: cast[ByteBuf](unsafeAddr b[0])

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

func fromStored[T: uint16 | uint32 | uint64](x: T, order: static ByteOrder): T {.inline.} =
  # `x` loaded in host order from bytes stored in `order`, as a native value.
  when order == hostOrder: x
  elif hostOrder == boLittle:
    when order == boBig: swapBytes(x)
    else: reorder(swapBytes(x), boPairSwapped)
  else:
    reorder(x, order)

func loadNum*[T: SomeNumber](p: ByteBuf, pos: int, order: static ByteOrder): T {.inline.} =
  ## Reads a 1, 2, 4 or 8 byte number stored in `order` at byte offset `pos`
  ## of `p`, unchecked: the caller guarantees `pos + sizeof(T)` bytes.
  when sizeof(T) == 1:
    cast[T](p[pos])
  else:
    type U = (when sizeof(T) == 2: uint16 elif sizeof(T) == 4: uint32 else: uint64)
    var u: U
    copyMem(addr u, addr p[pos], sizeof(U))
    cast[T](fromStored(u, order))

func loadU24*(p: ByteBuf, pos: int, order: static ByteOrder): uint32 {.inline.} =
  ## Reads an unsigned 24-bit number stored big- or little-endian, unchecked.
  when order == boLittle:
    uint32(p[pos]) or (uint32(p[pos + 1]) shl 8) or (uint32(p[pos + 2]) shl 16)
  else:
    (uint32(p[pos]) shl 16) or (uint32(p[pos + 1]) shl 8) or uint32(p[pos + 2])

{.pop.}
