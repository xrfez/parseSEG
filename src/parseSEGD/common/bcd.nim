## Packed binary-coded-decimal access at arbitrary nibble offsets.
##
## SEG-D headers pack fields on nibble boundaries. Nibble index `n` addresses
## byte `n div 2`; even indices are the high nibble (bits 7-4), odd indices
## the low nibble (bits 3-0). Digits are most-significant first.

import ./errors

func nibble*(b: openArray[byte], n: int): uint8 {.inline.} =
  ## Returns nibble `n` (0-based) of `b`.
  if (n and 1) == 0: b[n shr 1] shr 4 else: b[n shr 1] and 0x0F

func setNibble*(b: var openArray[byte], n: int, v: uint8) {.inline.} =
  ## Stores the low 4 bits of `v` into nibble `n` of `b`.
  let i = n shr 1
  if (n and 1) == 0:
    b[i] = (b[i] and 0x0F) or ((v and 0x0F) shl 4)
  else:
    b[i] = (b[i] and 0xF0) or (v and 0x0F)

func isAllF*(b: openArray[byte], first, count: int): bool =
  ## True when the `count` nibbles starting at `first` are all 0xF. SEG-D uses
  ## this pattern as an "undefined / see extended field" sentinel.
  result = true
  for n in first..<first+count:
    if nibble(b, n) != 0x0F:
      return false

proc bcd*(b: openArray[byte], first, count: int): int =
  ## Decodes `count` BCD digits starting at nibble `first`.
  ## Raises `SegFormatError` if a nibble is not a decimal digit.
  result = 0
  for n in first..<first+count:
    let d = nibble(b, n)
    if d > 9:
      raiseFormat("invalid BCD digit 0x" & "0123456789ABCDEF"[d] & " at nibble " & $n)
    result = result * 10 + int(d)

proc putBcd*(b: var openArray[byte], first, count, value: int) =
  ## Encodes `value` as `count` BCD digits starting at nibble `first`.
  ## Raises `SegFormatError` if `value` is negative or needs more digits.
  if value < 0:
    raiseFormat("negative value " & $value & " cannot be BCD encoded")
  var v = value
  for n in countdown(first+count-1, first):
    setNibble(b, n, uint8(v mod 10))
    v = v div 10
  if v != 0:
    raiseFormat("value " & $value & " does not fit in " & $count & " BCD digits")

func putAllF*(b: var openArray[byte], first, count: int) =
  ## Fills `count` nibbles starting at `first` with 0xF.
  for n in first..<first+count:
    setNibble(b, n, 0x0F)
