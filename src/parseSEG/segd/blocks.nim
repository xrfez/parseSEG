## The codec shared by every typed SEG-D header block: the Rev 1/2 blocks of
## `headers` and the Rev 3 blocks of `rev3` (both re-exported).
##
## A decoded block keeps the bytes it was decoded from (`raw`), and `encode`
## re-encodes only the fields whose values changed, so an unedited block is
## reproduced byte for byte.

import ../common/[endians, fieldlayout]
import ./[headers, rev3]
export headers, rev3

type
  SegdBlock* = SegdHeaderBlock | SegdRev3Block
    ## Every typed SEG-D block, of any revision.

func decodeBlock*[T: SegdBlock](b: openArray[byte]): T =
  ## Decodes a block of type `T` from the start of `b` and keeps its bytes.
  static: doAssert layoutBytes(T, 1) <= sizeof(default(T).raw),
    "the layout of " & $T & " overruns its block" # `decodeFields` loads unchecked
  doAssert b.len >= result.raw.len, "SEG-D header block too short"
  for i in 0..<result.raw.len: result.raw[i] = b[i]
  decodeFields(result, b, 1, boBig)

proc encode*[T: SegdBlock](h: T, b: var openArray[byte]) =
  ## Writes `h` to the start of `b`: its raw bytes, with every changed field
  ## re-encoded. Raises `SegFormatError` for a value a field cannot hold.
  doAssert b.len >= h.raw.len, "SEG-D header block buffer too short"
  for i in 0..<h.raw.len: b[i] = h.raw[i]
  encodeChanged(h, b.toOpenArray(0, h.raw.len - 1), 1, boBig)

proc encoded*[T: SegdBlock](h: T): typeof(h.raw) =
  ## The block's bytes as `encode` writes them.
  h.encode(result)

func invalidBcdFields*[T: SegdBlock](h: T): seq[string] =
  ## Names of BCD fields holding a non-decimal nibble.
  for name, v in fieldPairs(h):
    when v is int:
      if v == BcdInvalid: result.add name
