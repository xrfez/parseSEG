# Python-only protocol code (src/parseSEG/abi/gen/extras.py, spliced into the
# generated module). `_<Class>Extras` classes are mixed into the generated
# class of that name; `_to_<CStruct>` functions convert a Python argument to
# that struct.

class _PyBuffer(ctypes.Structure):
    _fields_ = [("buf", ctypes.c_void_p), ("obj", ctypes.c_void_p),
                ("len", ctypes.c_ssize_t), ("itemsize", ctypes.c_ssize_t),
                ("readonly", ctypes.c_int), ("ndim", ctypes.c_int),
                ("format", ctypes.c_char_p), ("shape", ctypes.POINTER(ctypes.c_ssize_t)),
                ("strides", ctypes.POINTER(ctypes.c_ssize_t)),
                ("suboffsets", ctypes.POINTER(ctypes.c_ssize_t)),
                ("internal", ctypes.c_void_p)]


_api = ctypes.pythonapi
_api.PyObject_GetBuffer.argtypes = [ctypes.py_object, ctypes.POINTER(_PyBuffer), ctypes.c_int]
_api.PyObject_GetBuffer.restype = ctypes.c_int
_api.PyBuffer_Release.argtypes = [ctypes.POINTER(_PyBuffer)]
_api.PyBuffer_Release.restype = None
_api.PyCapsule_New.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]
_api.PyCapsule_New.restype = ctypes.py_object
_api.PyCapsule_IsValid.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_api.PyCapsule_IsValid.restype = ctypes.c_int
_api.PyCapsule_GetPointer.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_api.PyCapsule_GetPointer.restype = ctypes.c_void_p
_PyBUF_RECORDS = 0x1D  # strides, writable, format


class _HeldBuffer:
    """A Py_buffer held for one call; released when dropped."""

    def __init__(self, obj):
        self.view = _PyBuffer()
        _api.PyObject_GetBuffer(obj, ctypes.byref(self.view), _PyBUF_RECORDS)

    def __del__(self):
        _api.PyBuffer_Release(ctypes.byref(self.view))


def _to_SegSampleBuffer(x, name):  # noqa: N802 - named after the C struct
    held = _HeldBuffer(x)  # TypeError / BufferError for non-buffers and read-only ones
    v = held.view
    if v.ndim != 2:
        raise ArgumentError(f"{name} must be 2-D [traces, samples]")
    fmt = (v.format or b"B").decode()
    if len(fmt) == 2 and (fmt[0] in "@=" or (fmt[0] == "<" and sys.byteorder == "little")):
        fmt = fmt[1:]
    if fmt == "f" and v.itemsize == 4:
        dtype = _E_Dtype["float32"]
    elif fmt == "d" and v.itemsize == 8:
        dtype = _E_Dtype["float64"]
    else:
        raise ArgumentError(f"{name} must hold native float32 or float64, not '{fmt}'")
    rows, cols = v.shape[0], v.shape[1]
    es = v.itemsize
    if v.strides[1] != es or v.strides[0] % es or v.strides[0] < cols * es:
        raise ArgumentError(f"{name} rows must be contiguous (C order)")
    s = SegSampleBuffer(data=v.buf, dtype=dtype, rows=rows, cols=cols,
                        row_stride=v.strides[0] // es)
    s._held = held
    return s


# ---------------------------------------------------------------- DLPack --

class _DLManagedTensor(ctypes.Structure):
    _fields_ = [("dl_tensor", ctypes.c_byte * 48), ("manager_ctx", ctypes.c_void_p),
                ("deleter", ctypes.CFUNCTYPE(None, ctypes.c_void_p))]


_DLTENSOR = b"dltensor"


@ctypes.CFUNCTYPE(None, ctypes.c_void_p)
def _capsule_destructor(capsule):
    # A capsule nobody consumed still owns its tensor (consumers rename it to
    # "used_dltensor" and call the deleter themselves).
    if _api.PyCapsule_IsValid(capsule, _DLTENSOR):
        p = _api.PyCapsule_GetPointer(capsule, _DLTENSOR)
        if p:
            m = _DLManagedTensor.from_address(p)
            if m.deleter:
                m.deleter(p)


class _SamplesExtras:
    """Python protocols of `Samples` (numpy, DLPack, lists, bytes)."""

    def shape(self):
        """`(traces, samples)`."""
        return tuple(self.view()["shape"])

    def __repr__(self):
        if self.closed():
            return "<parseseg.Samples empty>"
        v = self.view()
        return f"<parseseg.Samples {v['shape'][0]}x{v['shape'][1]} {v['dtype']}>"

    def _rows(self):
        v = self.view()
        rows, cols = v["shape"]
        ctype = ctypes.c_float if v["dtype"] == "float32" else ctypes.c_double
        if rows == 0 or cols == 0:
            return v, rows, cols, ctype, None
        n = (rows - 1) * v["strides"][0] + (cols - 1) * v["strides"][1] + 1
        return v, rows, cols, ctype, (ctype * n).from_address(v["data"])

    def tolist(self):
        """The samples as a list of rows of floats (a copy)."""
        v, rows, cols, _, a = self._rows()
        s0, s1 = v["strides"]
        return [[a[r * s0 + c * s1] for c in range(cols)] for r in range(rows)]

    def tobytes(self):
        """The samples as native-endian bytes in row-major order (a copy)."""
        v, rows, cols, ctype, a = self._rows()
        if a is None:
            return b""
        es = ctypes.sizeof(ctype)
        s0, s1 = v["strides"]
        if s1 == 1:
            return b"".join(ctypes.string_at(v["data"] + r * s0 * es, cols * es)
                            for r in range(rows))
        out = (ctype * (rows * cols))()
        for r in range(rows):
            for c in range(cols):
                out[r * cols + c] = a[r * s0 + c * s1]
        return bytes(out)

    def __dlpack__(self, stream=None, max_version=None, dl_device=None, copy=None):
        """A DLPack capsule sharing the samples (CPU, no copy)."""
        p = self._to_dlpack()
        return _api.PyCapsule_New(p, _DLTENSOR,
                                  ctypes.cast(_capsule_destructor, ctypes.c_void_p))

    def __dlpack_device__(self):
        """`(1, 0)`: CPU memory."""
        return (1, 0)

    def numpy(self):
        """A numpy array sharing the samples (`numpy.from_dlpack(self)`)."""
        import numpy
        return numpy.from_dlpack(self)

    def __array__(self, dtype=None, copy=None):
        a = self.numpy()
        return a if dtype is None else a.astype(dtype)


class _SeismicFileExtras:
    def __repr__(self):
        if self.closed():
            return "<parseseg.SeismicFile closed>"
        kind = {"segy": "SEG-Y", "segd": "SEG-D"}.get(self.kind(), "unknown")
        return f"<parseseg.SeismicFile {kind}, {self.trace_count()} traces>"
