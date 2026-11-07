## Smoke test for the Arraymancer dependency (task 2.0): sample decoders will
## write straight into a Tensor's raw buffer, so check that pattern works.

import std/assertions
import arraymancer/tensor

block raw_buffer_write_float32:
  var t = newTensorUninit[float32](3, 4)
  doAssert t.is_C_contiguous
  let p = cast[ptr UncheckedArray[float32]](t.unsafe_raw_offset())
  for i in 0 ..< t.size:
    p[i] = float32(i)
  doAssert t[1, 2] == 6'f32, "row-major [traces, samples] layout"
  let rows = t[1..2, _]
  doAssert rows.shape[0] == 2
  doAssert rows[0, 0] == 4'f32, "slicing a trace range shares the buffer"

block float64_tensor:
  var d = newTensorUninit[float64](2, 5)
  let p = cast[ptr UncheckedArray[float64]](d.unsafe_raw_offset())
  p[9] = 1.5
  doAssert d[1, 4] == 1.5
