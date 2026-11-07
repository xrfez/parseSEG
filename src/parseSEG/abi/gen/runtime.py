# ------------------------------------------------------------------ runtime
# (src/parseSEG/abi/gen/runtime.py, spliced into the generated module)
import ctypes
import operator
import os
import sys
import threading

_ABI_VERSION = @ABI_VERSION@
_LIB_NAMES = {"win32": "parseseg.dll", "darwin": "libparseseg.dylib"}


def _load():
    name = _LIB_NAMES.get(sys.platform, "libparseseg.so")
    path = os.environ.get("PARSESEG_LIBRARY") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), name)
    lib = ctypes.CDLL(path)
    lib.seg_init.restype = ctypes.c_int32
    lib.seg_init.argtypes = []
    lib.seg_last_error.restype = ctypes.c_char_p
    lib.seg_last_error.argtypes = []
    got = lib.seg_init()
    if got != _ABI_VERSION:
        raise ImportError(f"parseseg: {path} has ABI {got}, this module needs {_ABI_VERSION}")
    return lib


_lib = _load()


class Error(Exception):
    """Base of every parseseg failure."""


class ArgumentError(Error, ValueError):
    """An argument is out of range or malformed."""


class FormatError(Error, ValueError):
    """Bytes that cannot be decoded."""


class IOError(Error, OSError):  # noqa: A001 - parseseg.IOError, also an OSError
    """The operating system refused (open, map, read, write)."""


class StateError(Error, RuntimeError):
    """Not possible in this state (e.g. a closed handle, keys not collected)."""


class RefusedError(Error):
    """An edit was refused; the editor's diagnostics say why."""


class InternalError(Error, RuntimeError):
    """A library bug; please report it."""


_STATUS = {-1: ArgumentError, -2: IOError, -3: FormatError, -4: StateError,
           -5: RefusedError, -6: InternalError, -7: MemoryError}


def _raise(st, diagnostics=None):
    msg = (_lib.seg_last_error() or b"").decode("utf-8", "replace")
    e = _STATUS.get(st, InternalError)(msg)
    if diagnostics is not None:
        e.diagnostics = diagnostics
    raise e


def _call(fn, *args):
    st = fn(*args)
    if st < 0:
        _raise(st)
    return st


def _dec(b):
    return None if b is None else b.decode("utf-8", "replace")


def _i64(x, name):
    try:
        v = operator.index(x)
    except TypeError:
        raise ArgumentError(f"{name} must be an integer, not {type(x).__name__}") from None
    if not -(1 << 63) <= v < (1 << 63):
        raise ArgumentError(f"{name} out of range")
    return v


def _i32(x, name):
    v = _i64(x, name)
    if not -(1 << 31) <= v < (1 << 31):
        raise ArgumentError(f"{name} out of range")
    return v


def _f64(x, name):
    try:
        return float(x)
    except (TypeError, ValueError):
        raise ArgumentError(f"{name} must be a number") from None


def _str(x, name):
    if hasattr(x, "__fspath__"):
        x = os.fspath(x)
    if isinstance(x, bytes):
        return x
    if not isinstance(x, str):
        raise TypeError(f"{name} must be a str, not {type(x).__name__}")
    return x.encode("utf-8")


def _enum(table, x, name):
    try:
        return table[x]
    except (KeyError, TypeError):
        raise ArgumentError(f"{name} must be one of {', '.join(map(repr, table))}, "
                            f"not {x!r}") from None


def _ids(xs, name):
    vals = [_i64(x, name) for x in xs]
    return (ctypes.c_int64 * len(vals))(*vals), len(vals)


def _handle(x, cls, name):
    if not isinstance(x, cls):
        raise TypeError(f"{name} must be a parseseg.{cls.__name__}")
    return x._ptr()


def _struct_arg(cls, x, name):
    hook = globals().get("_to_" + cls.__name__)
    if hook is not None:
        return hook(x, name)
    if isinstance(x, cls):
        return x
    return cls(**x)


def _struct_dict(s):
    return {k: f(getattr(s, k)) for k, f in type(s)._conv}


def _text(fn):
    cap = 256
    while True:
        buf = ctypes.create_string_buffer(cap)
        n = ctypes.c_int64()
        fn(buf, cap, ctypes.byref(n))
        if n.value < cap:
            return buf.raw[:n.value].decode("utf-8", "replace")
        cap = n.value + 1


def _seq(fn, ctype, conv):
    n = ctypes.c_int64()
    fn(None, 0, ctypes.byref(n))
    while True:
        cap = n.value
        arr = (ctype * max(cap, 1))()
        fn(arr, cap, ctypes.byref(n))
        if n.value <= cap:
            return [conv(arr[i]) for i in range(n.value)]


class SegValue(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_int32), ("reserved", ctypes.c_int32),
                ("i", ctypes.c_int64), ("f", ctypes.c_double),
                ("text", ctypes.c_void_p), ("text_cap", ctypes.c_int64),
                ("text_len", ctypes.c_int64)]


def _value_in(x, name):
    v = SegValue()
    if isinstance(x, str):
        v._buf = ctypes.create_string_buffer(x.encode("utf-8"))
        v.kind, v.text = 3, ctypes.cast(v._buf, ctypes.c_void_p)
    elif isinstance(x, float):
        v.kind, v.f = 2, x
    else:
        try:
            i = operator.index(x)
        except TypeError:
            try:
                v.kind, v.f = 2, float(x)
            except (TypeError, ValueError):
                raise ArgumentError(f"{name} must be an int, float or str") from None
        else:
            v.kind, v.i = 1, _i64(i, name)
    return v


def _value_out():
    v = SegValue()
    v._buf = ctypes.create_string_buffer(4096)
    v.text, v.text_cap = ctypes.cast(v._buf, ctypes.c_void_p), 4096
    return v


def _value(v):
    if v.kind == 1:
        return v.i
    if v.kind == 2:
        return v.f
    if v.text_len >= v.text_cap:
        raise InternalError("field text longer than 4 KiB")
    return v._buf.raw[:v.text_len].decode("utf-8", "replace")


def _wrap(cls, ptr):
    if not ptr:
        return None
    o = cls.__new__(cls)
    o._h = ptr
    o._mu = threading.Lock()
    return o


class _Handle:
    """A library object; `close()` (or `with`) ends its use."""
    _h = None
    _closed = False
    _busy = 0
    _mu = None
    _release = None

    def _enter(self):
        # Counts a call in flight, so that close() from another thread cannot
        # free the object under it (the last call to return releases it).
        if self._h is None or self._closed:
            raise StateError(f"the {type(self).__name__} is closed")
        with self._mu:
            if self._h is None or self._closed:
                raise StateError(f"the {type(self).__name__} is closed")
            self._busy += 1
            return self._h

    def _leave(self):
        with self._mu:
            self._busy -= 1
            last = self._closed and self._busy == 0
        if last:
            self._free()

    def _ptr(self):
        if self._h is None or self._closed:
            raise StateError(f"the {type(self).__name__} is closed")
        return self._h

    def _free(self):
        h, self._h = self._h, None
        if h is not None and type(self)._release is not None:
            try:
                type(self)._release(h)
            except Exception:  # noqa: BLE001 - interpreter shutdown
                pass

    def close(self):
        """Ends the use of this object (also on leaving a `with` block)."""
        if self._closed or self._h is None:
            return
        native = getattr(self, "_close_native", None)
        if native is not None:
            native()
        with self._mu:
            self._closed = True
            idle = self._busy == 0
        if idle:
            self._free()

    def closed(self):
        """True after `close()`."""
        return self._closed or self._h is None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def __del__(self):
        self._free()


def _log_list(ptr):
    if not ptr:
        return None
    log = _wrap(Log, ptr)
    try:
        return [log.get(i) for i in range(log.count())]
    finally:
        log._free()


def _logged(st, out):
    diags = _log_list(out.value)
    if st < 0:
        _raise(st, diags)
    return diags
