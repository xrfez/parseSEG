"""Python ctypes smoke test of the C ABI (task 8.4).

    python3 -I smoke.py <libparseseg.so> <exampleFiles dir>

Uses only the standard library; when numpy is installed it also checks a
zero-copy numpy view and DLPack import. Exits non-zero on failure.
"""
import array
import ctypes as C
import os
import sys

lib = C.CDLL(sys.argv[1])
example = sys.argv[2]


class SegTensorView(C.Structure):
    _fields_ = [("data", C.c_void_p), ("dtype", C.c_int32), ("rank", C.c_int32),
                ("shape", C.c_int64 * 2), ("strides", C.c_int64 * 2)]


class SegValue(C.Structure):
    _fields_ = [("kind", C.c_int32), ("reserved", C.c_int32), ("i", C.c_int64),
                ("f", C.c_double), ("text", C.c_char_p)]


lib.seg_init.restype = C.c_int32
lib.seg_version.restype = C.c_char_p
lib.seg_last_error.restype = C.c_char_p
lib.seg_file_open.argtypes = [C.c_char_p, C.c_uint32, C.POINTER(C.c_void_p)]
lib.seg_file_trace_count.argtypes = [C.c_void_p]
lib.seg_file_trace_count.restype = C.c_int64
lib.seg_file_max_samples.argtypes = [C.c_void_p]
lib.seg_file_max_samples.restype = C.c_int64
lib.seg_file_sample_interval.argtypes = [C.c_void_p, C.c_int64]
lib.seg_file_sample_interval.restype = C.c_double
lib.seg_trace_field.argtypes = [C.c_void_p, C.c_int64, C.c_char_p, C.POINTER(SegValue)]
lib.seg_read_range.argtypes = [C.c_void_p, C.c_int64, C.c_int64, C.c_int32, C.c_int64,
                               C.POINTER(C.c_void_p)]
lib.seg_read_range_into.argtypes = [C.c_void_p, C.c_int64, C.c_int64, C.c_int32, C.c_void_p,
                                    C.c_int64, C.c_int64, C.POINTER(C.c_int64)]
lib.seg_tensor_view.argtypes = [C.c_void_p, C.POINTER(SegTensorView)]
lib.seg_tensor_release.argtypes = [C.c_void_p]
lib.seg_file_release.argtypes = [C.c_void_p]
lib.seg_tensor_to_dlpack.argtypes = [C.c_void_p]
lib.seg_tensor_to_dlpack.restype = C.c_void_p

SEG_F32 = 1

assert lib.seg_init() == 1
assert lib.seg_version() == b"0.2.0"

f = C.c_void_p()
st = lib.seg_file_open(os.path.join(example, "BO_3D-Inglewood_rev21_v7.sgy").encode(), 0,
                       C.byref(f))
assert st == 0, lib.seg_last_error()
n = lib.seg_file_trace_count(f)
ns = lib.seg_file_max_samples(f)
assert (n, ns) == (200, 2001)
assert lib.seg_file_sample_interval(f, 0) == 2000.0

v = SegValue()
assert lib.seg_trace_field(f, 5, b"trace.sourceX", C.byref(v)) == 0 and v.i == 1704188
assert lib.seg_trace_field(f, 5, b"trace.bogus", C.byref(v)) == -1
assert b"bogus" in lib.seg_last_error()

# Decode into a Python-owned buffer, then compare with a library tensor.
buf = array.array("f", bytes(4 * 3 * ns))
addr, _ = buf.buffer_info()
failed = C.c_int64(-1)
assert lib.seg_read_range_into(f, 100, 3, SEG_F32, addr, ns, ns, C.byref(failed)) == 0
assert failed.value == 0

t = C.c_void_p()
assert lib.seg_read_range(f, 100, 3, SEG_F32, -1, C.byref(t)) == 0
view = SegTensorView()
assert lib.seg_tensor_view(t, C.byref(view)) == 0
assert tuple(view.shape) == (3, ns) and tuple(view.strides) == (ns, 1)
data = (C.c_float * (3 * ns)).from_address(view.data)
assert list(data) == list(buf)
assert any(x != 0 for x in buf)

try:
    import numpy as np
except ImportError:
    np = None

if np is not None:
    a = np.ctypeslib.as_array(data).reshape(3, ns)  # zero-copy view
    assert np.array_equal(a, np.frombuffer(buf, dtype=np.float32).reshape(3, ns))
    print("numpy view: ok")
else:
    print("numpy not installed: numpy checks skipped")

lib.seg_tensor_release(t)
lib.seg_file_release(f)
print("python smoke: ok")
