## Raw row access to a tensor's storage, for the library's zero-copy
## decoders (no shape checks: the caller checks them).

import arraymancer/tensor

proc rowPtr*[T](t: Tensor[T], row: int): ptr UncheckedArray[T] {.inline.} =
  ## The storage of row `row` of a row-major `[traces, samples]` tensor;
  ## the caller checks the shape.
  let base = cast[ptr UncheckedArray[T]](t.unsafe_raw_offset())
  cast[ptr UncheckedArray[T]](addr base[row * t.strides[0]])
