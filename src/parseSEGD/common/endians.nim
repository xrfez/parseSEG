## Big-endian integer and IEEE float access on byte buffers.
##
## All SEG formats are big-endian. Positions are 0-based byte offsets into the
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
