## Trace samples in Arraymancer tensors.
##
## A gather or trace range is a `Tensor[float32]` (or `float64`) shaped
## `[traces, samples]`, row-major. The sample codecs write straight into a
## row's storage; no intermediate `seq` is built. This is the only place the
## format layers meet Arraymancer. SEG-Y, SEG-D and SEG-2 formats are separate enums,
## so `decodeTrace` overloads on the format type.

# Arraymancer's CPU tensor modules, one by one: `arraymancer/tensor` also
# imports its CUDA and OpenCL backends under `nimdoc`, which `nim doc` cannot
# build without those toolkits. The list is that module's CPU list, so
# `import parseSEG` gives the same tensor API.
import nimblas
import arraymancer/[laser/dynamic_stack_arrays, tensor/data_structure, tensor/init_cpu,
  tensor/init_copy_cpu, tensor/accessors, tensor/accessors_macros_syntax, tensor/accessors_macros_read,
  tensor/accessors_macros_write, tensor/operators_comparison, tensor/higher_order_applymap,
  tensor/higher_order_foldreduce, tensor/shapeshifting, tensor/selectors, tensor/display,
  tensor/ufunc, tensor/operators_blas_l1, tensor/operators_blas_l2l3,
  tensor/operators_broadcasted, tensor/operators_logical, tensor/complex,
  tensor/math_functions, tensor/aggregate, tensor/algorithms, tensor/bitops_functions,
  tensor/lapack, tensor/optim_ops_fusion, tensor/syntactic_sugar, tensor/exporting]
import ../segy/samples
import ../segd/samples as segdsamples
import ../seg2/samples as seg2samples
import ./endians
import ../private/tensorrows

export OrderType, dynamic_stack_arrays, data_structure, init_cpu, init_copy_cpu, accessors,
  accessors_macros_syntax, accessors_macros_read, accessors_macros_write,
  operators_comparison, higher_order_applymap, higher_order_foldreduce, shapeshifting,
  selectors, display, ufunc, operators_blas_l1, operators_blas_l2l3, operators_broadcasted,
  operators_logical, complex, math_functions, aggregate, algorithms, bitops_functions, lapack,
  optim_ops_fusion, syntactic_sugar, exporting

proc newTraceTensor*[T: SampleType](traces, samples: Natural): Tensor[T] =
  ## A zero-filled `[traces, samples]` tensor. Traces shorter than `samples`
  ## leave their tail at zero.
  zeros[T](int(traces), int(samples))

proc checkedRow[T](t: Tensor[T], row, samples: int): ptr UncheckedArray[T] =
  doAssert t.rank == 2 and t.is_C_contiguous, "need a row-major [traces, samples] tensor"
  doAssert row in 0..<t.shape[0], "row " & $row & " is outside the tensor"
  doAssert samples <= t.shape[1], "trace has more samples than the tensor row"
  rowPtr(t, row)

proc decodeTrace*[T: SampleType](t: var Tensor[T], row: int, f: SampleFormat,
    src: openArray[byte], samples: int, order = boBig) =
  ## Decodes `samples` samples of format `f` from `src` into the start of row
  ## `row`. Raises like `decodeSamples`.
  let p = checkedRow(t, row, samples)
  decodeSamples(f, src, p.toOpenArray(0, samples - 1), order)

proc encodeTrace*[T: SampleType](t: Tensor[T], row: int, f: SampleFormat,
    dst: var openArray[byte], samples: int, order = boBig) =
  ## Encodes the first `samples` samples of row `row` as format `f` into `dst`.
  ## Raises like `encodeSamples`.
  let p = checkedRow(t, row, samples)
  encodeSamples(f, p.toOpenArray(0, samples - 1), dst, order)

proc decodeTrace*[T: SampleType](t: var Tensor[T], row: int, f: SegdSampleFormat,
    src: openArray[byte], samples: int, twosComplement8015 = false) =
  ## Decodes `samples` SEG-D samples of format `f` from `src` into the start
  ## of row `row`. Raises like `decodeSamples`.
  let p = checkedRow(t, row, samples)
  decodeSamples(f, src, p.toOpenArray(0, samples - 1), twosComplement8015)

proc decodeTrace*[T: SampleType](t: var Tensor[T], row: int, f: Seg2SampleFormat,
    src: openArray[byte], samples: int, order: ByteOrder, twosComplement = false) =
  ## Decodes `samples` SEG-2 samples of format `f`, stored in `order`, from
  ## `src` into the start of row `row`. Raises like `decodeSamples`.
  let p = checkedRow(t, row, samples)
  decodeSamples(f, src, p.toOpenArray(0, samples - 1), order, twosComplement)

proc encodeTrace*[T: SampleType](t: Tensor[T], row: int, f: SegdSampleFormat,
    dst: var openArray[byte], samples: int) =
  ## Encodes the first `samples` samples of row `row` as SEG-D format `f`.
  let p = checkedRow(t, row, samples)
  encodeSamples(f, p.toOpenArray(0, samples - 1), dst)
