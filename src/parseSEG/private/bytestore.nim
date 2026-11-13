## Unchecked stores of numbers in a byte order known at compile time: the
## store side of `endians.loadNum`, for the sample encoders' loops
## (`segy/samples`, `segd/samples`, `seg2/samples`, `private/sampleconv`).
## The caller has checked the buffer's length.

import std/math
import ../common/endians

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}
# Inline procs keep the checks of the module they are defined in, whatever
# their caller has pushed. Call them from a `{.raises: [].}` kernel: only
# there does the compiler leave out the error check after each call, which
# keeps a loop from being vectorized.

func toStored*[T: uint16 | uint32 | uint64](x: T, order: static ByteOrder): T {.
    inline, raises: [].} =
  ## Native `x` as host-order bits of its bytes stored in `order` (and back:
  ## each reordering is its own inverse).
  const lowBytes = when T is uint32: 0x00FF_00FF'u32 else: 0x00FF_00FF_00FF_00FF'u64
  template pairs(y: T): T =
    when T is uint16: swapBytes(y) else: ((y and lowBytes) shl 8) or ((y shr 8) and lowBytes)
  when order == hostOrder: x
  elif order == boPairSwapped:
    when hostOrder == boLittle: pairs(swapBytes(x)) else: pairs(x)
  else: swapBytes(x)

template storeNum*(p: ByteBuf, pos: int, v: typed, order: static ByteOrder) =
  ## Writes the number `v` in `order` at `pos`, unchecked. A template: after
  ## a call of a generic proc the compiler checks its error flag, and that
  ## exit keeps the loop around it from being vectorized.
  when sizeof(v) == 1:
    p[pos] = cast[uint8](v)
  else:
    var u = toStored(cast[(when sizeof(v) == 2: uint16 elif sizeof(v) == 4: uint32
                           else: uint64)](v), order)
    copyMem(addr p[pos], addr u, sizeof(u))

template storeU24*(p: ByteBuf, pos: int, v: uint32, order: static ByteOrder) =
  ## Writes the low 3 bytes of `v` at `pos`, little-endian for `boLittle`,
  ## else big-endian (3-byte samples have no pair-swapped order).
  let w = v
  when order == boLittle:
    p[pos] = uint8(w and 0xFF)
    p[pos + 1] = uint8((w shr 8) and 0xFF)
    p[pos + 2] = uint8((w shr 16) and 0xFF)
  else:
    p[pos] = uint8((w shr 16) and 0xFF)
    p[pos + 1] = uint8((w shr 8) and 0xFF)
    p[pos + 2] = uint8(w and 0xFF)

func truncToInt32*(x: float64): int32 {.importc: "(NI32)", nodecl.}
  ## `x`, within int32's range, as an int32: the C conversion itself. Nim's
  ## `int32(x)` goes through int64, for which x86 before AVX-512 has no
  ## packed conversion.

func roundAway*(x: float64): float64 {.inline, raises: [].} =
  ## `x` rounded to the nearest integer, halves away from zero: `round(x)`
  ## bit for bit (NaN and the infinities too), from `trunc`, which compilers
  ## turn into one instruction where `round` is a library call per sample.
  let t = trunc(x)
  # `x - t` is exact, so the tie test is too (0.49999999999999994 stays 0).
  t + (if abs(x - t) >= 0.5: copySign(1.0, x) else: 0.0)

{.pop.}
