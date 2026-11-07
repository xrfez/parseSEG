"""The nimpy module `parseseg` end to end (task 8.8).

    python3 -I test_pyapi.py <dir holding parseseg.so> <exampleFiles dir> <scratch dir> [nonumpy]

Standard library only; the numpy checks (zero-copy views, DLPack, read_into a
numpy array) run when numpy is installed, unless `nonumpy` hides it to test
the module without numpy. Exits non-zero on failure.
"""
import array
import gc
import math
import os
import shutil
import sys
import threading

sys.path.insert(0, sys.argv[1])
example, scratch = sys.argv[2], sys.argv[3]
os.makedirs(scratch, exist_ok=True)

if sys.argv[4:] == ["nonumpy"]:
    sys.modules["numpy"] = None  # import numpy now raises ImportError

import parseseg  # noqa: E402

try:
    import numpy as np
except ImportError:
    np = None

INGLEWOOD = os.path.join(example, "BO_3D-Inglewood_rev21_v7.sgy")
SWEEP = os.path.join(example, "Sweep0.sgy")
S63 = os.path.join(example, "63.sgd")
INOVA = os.path.join(example, "inova_rev30_5traces.sgd")


def raises(exc, fn, *args, **kw):
    try:
        fn(*args, **kw)
    except exc as e:
        return e
    raise AssertionError(f"{fn} did not raise {exc.__name__}")


def fresh(name):
    path = os.path.join(scratch, os.path.basename(name))
    shutil.copyfile(name, path)
    for j in (path + ".edits.nif", path + ".j.nif"):
        if os.path.exists(j):
            os.remove(j)
    return path


# ------------------------------------------------------------- the module --
assert parseseg.version() == "0.2.0" and parseseg.abi_version() == 1
assert "SEG-Y" in parseseg.__doc__
# Exception classes exist before any error, with their documented bases.
E = parseseg
assert issubclass(E.ArgumentError, E.Error) and issubclass(E.ArgumentError, ValueError)
assert issubclass(E.FormatError, E.Error) and issubclass(E.FormatError, ValueError)
assert issubclass(E.IOError, E.Error) and issubclass(E.IOError, OSError)
assert issubclass(E.StateError, RuntimeError) and issubclass(E.InternalError, RuntimeError)
assert issubclass(E.RefusedError, E.Error) and issubclass(E.Error, Exception)
assert E.FormatError is parseseg.FormatError  # one class, not one per raise
from parseseg import StateError  # noqa: E402
assert StateError is E.StateError
assert "FormatError" in dir(parseseg) and "open" in dir(parseseg)
raises(AttributeError, getattr, parseseg, "NoSuchThing")

# ------------------------------------------------------------ open / index --
f = parseseg.open(INGLEWOOD)
assert f.kind() == "segy" and f.trace_count() == 200 and f.max_samples() == 2001
assert f.record_count() == 1 and f.sample_interval(0) == 2000.0
assert math.isnan(f.sample_interval(200))
assert "200 traces" in repr(f)
e = f.trace_entry(5)
assert e["num_samples"] == 2001 and e["header_bytes"] == 240 and e["offset"] > 3600
assert set(e) == {"offset", "header_bytes", "num_samples", "record", "channel_set",
                  "scan_type", "channel_type"}
k = f.trace_keys(5)
assert "src_x" in k and "rcv_line" in k and "cmp_x" in k
assert f.trace_field(5, "trace.sourceX") == 1704188
assert isinstance(f.file_field("binary.formatCode"), int)
err = raises(parseseg.ArgumentError, f.trace_field, 5, "trace.bogus")
assert "bogus" in str(err) and isinstance(err, ValueError)
raises(parseseg.ArgumentError, f.trace_entry, 200)
raises(parseseg.ArgumentError, f.trace_entry, -1)
assert f.diagnostics() == [] and f.log_nif().startswith("(")
nolog = parseseg.open(INGLEWOOD, keys=False)
raises(parseseg.StateError, nolog.trace_keys, 0)
raises(parseseg.StateError, nolog.gathers)
nolog.close()
raises(parseseg.IOError, parseseg.open, os.path.join(scratch, "missing.sgy"))
raises(TypeError, parseseg.open, 42)

# Text fields come back as str.
assert isinstance(f.trace_field(0, "trace.headerName"), str)

# ------------------------------------------------------------------ reads --
s = f.read(100, 3)
assert s.shape() == (3, 2001) and s.dtype() == "float32" and "3x2001" in repr(s)
rows = s.tolist()
assert len(rows) == 3 and len(rows[0]) == 2001 and any(x != 0 for x in rows[0])
raw = s.tobytes()
assert len(raw) == 3 * 2001 * 4
assert list(array.array("f", raw)) == [x for r in rows for x in r]
s64 = f.read(100, 3, dtype="float64")
assert s64.dtype() == "float64" and s64.tolist() == rows
assert f.read(198).shape() == (2, 2001)          # count -1: to the end
assert f.read(200, 0).shape() == (0, 0)             # width from no trace
assert f.read(0, 2, cols=10).shape() == (2, 10)
assert f.read(0, 2, cols=0).shape() == (2, 0)
raises(parseseg.ArgumentError, f.read, 199, 2)
raises(parseseg.ArgumentError, f.read, -1, 1)
raises(parseseg.ArgumentError, f.read, 0, 1, dtype="int16")
raises(parseseg.ArgumentError, f.read, 0, 1, cols=-2)
sel = f.read_traces([102, 100, 101])
assert sel.tolist() == [rows[2], rows[0], rows[1]]
assert f.read_traces([]).shape() == (0, 0)
raises(parseseg.ArgumentError, f.read_traces, [0, 200])
raises(parseseg.ArgumentError, f.read_traces, [-1])
raises(parseseg.ArgumentError, f.read, 0, 200, "float64", 1 << 40)  # over the 1 TiB limit

# read_into a stdlib buffer: array.array is 1-D, so it is refused (2-D needed).
raises(parseseg.ArgumentError, f.read_into, array.array("f", bytes(4 * 2001)), 0)

if np is not None:
    a = s.numpy()
    assert a.shape == (3, 2001) and a.dtype == np.float32 and not a.flags["OWNDATA"]
    assert a.tolist() == rows
    b = np.asarray(s)
    assert np.shares_memory(a, b)
    c = np.from_dlpack(s)
    assert np.shares_memory(a, c)
    assert np.asarray(s, dtype=np.float64).dtype == np.float64
    # The arrays keep the samples alive after the Samples, the file and a GC pass.
    keep = a.copy()
    del s, b, c
    gc.collect()
    assert np.array_equal(a, keep)
    # read_into: straight into the caller's arrays, rows padded or cut to its width.
    out = np.full((3, 2001), 7, np.float32)
    assert f.read_into(out, 100) == 0 and np.array_equal(out, keep)
    out64 = np.zeros((3, 2001), np.float64)
    assert f.read_into(out64, 100) == 0 and np.array_equal(out64, keep.astype(np.float64))
    wide = np.full((2, 2100), 7, np.float32)
    assert f.read_into(wide, 100) == 0
    assert np.array_equal(wide[:, :2001], keep[:2]) and not wide[:, 2001:].any()
    narrow = np.zeros((2, 50), np.float32)
    assert f.read_into(narrow, 100) == 0 and np.array_equal(narrow, keep[:2, :50])
    big = np.zeros((4, 3000), np.float32)
    view = big[::2, 10:2011]                     # strided rows, contiguous samples
    assert f.read_into(view, 100) == 0 and np.array_equal(view, keep[:2])
    assert not big[1].any() and not big[0, :10].any()
    some = np.zeros((2, 2001), np.float32)
    assert f.read_traces_into(some, [102, 100]) == 0
    assert np.array_equal(some, keep[[2, 0]])
    raises(parseseg.ArgumentError, f.read_traces_into, some, [1, 2, 3])
    raises(parseseg.ArgumentError, f.read_into, np.zeros((2, 10), np.int32))
    raises(parseseg.ArgumentError, f.read_into, np.zeros((2, 10), np.float32, order="F"))
    raises(parseseg.ArgumentError, f.read_into, np.zeros(10, np.float32))
    raises(parseseg.ArgumentError, f.read_into, np.zeros((2, 10), ">f4"))
    raises(parseseg.ArgumentError, f.read_into, np.zeros((300, 10), np.float32))
    ro = np.zeros((2, 10), np.float32)
    ro.flags.writeable = False
    raises(Exception, f.read_into, ro)
    print("numpy: ok")
else:
    raises(ImportError, parseseg.Samples.numpy, f.read(0, 1))
    raises(ImportError, __import__("operator").methodcaller("__array__"), f.read(0, 1))
    print("numpy not installed: numpy checks skipped")

# Reads release the GIL: four threads reading at once agree with one.
want = f.read(0, 200).tobytes()
results = [None] * 4


def worker(i):
    results[i] = f.read(0, 200).tobytes()


ts = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
for t in ts:
    t.start()
for t in ts:
    t.join()
assert all(r == want for r in results)

# --------------------------------------------------------------- prefetch --
with f.prefetch(0, -1, chunk_traces=64, depth=3) as p:
    assert p.positions() == 200 and p.trace_at(199) == 199 and p.trace_at(200) == -1
    got, firsts = b"", []
    while (c := p.next()) is not None:
        firsts.append(c["first"])
        assert c["failed"] == 0 and c["samples"].shape() == (c["count"], 2001)
        got += c["samples"].tobytes()
    assert firsts == [0, 64, 128, 192] and got == want and p.at_end()
    assert p.next() is None and p.try_next() is None
    p.seek(190)
    while (c := p.try_next()) is None:
        pass
    assert c["first"] == 190 and c["count"] == 10
    raises(parseseg.ArgumentError, p.seek, 5, 201)
raises(parseseg.StateError, p.next)
p.close()  # closing twice is fine
with f.prefetch_traces([5, 3, 1], chunk_traces=2, depth=2, dtype="float64") as p:
    assert p.positions() == 3 and p.trace_at(0) == 5
    c = p.next()
    assert c["first"] == 0 and c["count"] == 2 and c["samples"].dtype() == "float64"
    assert c["samples"].tolist() == f.read_traces([5, 3], dtype="float64").tolist()
raises(parseseg.ArgumentError, f.prefetch, 0, -1, 0)
raises(parseseg.ArgumentError, f.prefetch, 0, -1, 1, 0)
raises(parseseg.ArgumentError, f.prefetch, 0, 201)
raises(parseseg.ArgumentError, f.prefetch_traces, [200])
# A prefetcher keeps its file's map alive after the file is closed.
p = f.prefetch(0, 10)
f.close()
assert f.closed() and "closed" in repr(f)
c = p.next()
assert c["samples"].tobytes() == want[:10 * 2001 * 4]
p.close()
raises(parseseg.StateError, f.read, 0, 1)
raises(parseseg.StateError, f.trace_count)

# ---------------------------------------------------------------- SEG-D --
with parseseg.open(S63) as d:
    assert d.kind() == "segd" and d.trace_count() == 1 and d.record_count() == 1
    assert d.record_field(0, "gh3.sourcePointNumber") == 99.5
    raises(parseseg.ArgumentError, d.record_field, 0, "gh4.sourcePointNumber")
    raises(parseseg.ArgumentError, d.file_field, "binary.jobId")
    assert [g["kind"] for g in d.gathers()] == ["shot"]
    assert d.read(0, 1).shape()[0] == 1
    infos = d.diagnostics()
    assert len(infos) == 2 and all(x["severity"] == "info" for x in infos)
    assert set(infos[0]) == {"severity", "code", "message", "offset", "record", "channel_set",
                             "trace", "block_index", "file", "field"}
assert d.closed()

with parseseg.open(INOVA) as r3:
    assert r3.trace_count() == 5
    k = r3.trace_keys(3)                         # the first seismic trace
    assert abs(k["rcv_x"] - 1826232.375) < 1e-6 and abs(k["src_x"] - 1834704.375) < 1e-6
    assert abs(k["offset"] - math.hypot(1834704.375 - 1826232.375,
                                        445679.53125 - 446233.8125)) < 1e-3
    groups = r3.component_groups()
    assert groups == [-1, -1, -1, 0, 1]          # aux traces are in none
    assert len(r3.component_groups(1, 2)) == 2
    raises(parseseg.ArgumentError, r3.component_groups, 3, 5)
    raises(parseseg.ArgumentError, r3.component_groups, 0, -2)

# --------------------------------------------------------------- geometry --
with parseseg.open(S63) as d:
    k = d.trace_keys(0)
    g = parseseg.Geometry()
    g.add_receiver(k["rcv_line"], k["rcv_point"], 0, 1000.5, 2000.25, 3.0)
    g.add_source(k["src_line"], k["src_point"], 0, 1100.5, 2000.25)
    raises(parseseg.ArgumentError, g.add_source, 1, 1, 1 << 20, 0, 0)
    assert d.apply_geometry(g) == 1
    k2 = d.trace_keys(0)
    assert (k2["rcv_x"], k2["rcv_y"], k2["rcv_z"]) == (1000.5, 2000.25, 3.0)
    assert k2["src_x"] == 1100.5 and math.isnan(k2["src_z"]) and abs(k2["offset"] - 100) < 1e-9
    raises(TypeError, d.apply_geometry, "not a geometry")

# ---------------------------------------------------------------- editing --
path = fresh(INGLEWOOD)
original = open(path, "rb").read()
journal = path + ".j.nif"
with parseseg.open_editor(path, journal) as ed:
    ed.set_trace(5, "trace.sourceX", 1_700_000)
    ed.set_trace(7, "trace.groupStatic", -12)
    ed.set_file("binary.jobId", 4242)
    ed.set_trace(0, "trace.headerName", "ABC")
    if np is not None:
        ed.set_trace(8, "trace.sourceX", np.int64(5))
    err = raises(parseseg.RefusedError, ed.set_trace, 0, "trace.numSamples", 10)
    assert "numSamples" in str(err) or "structural" in str(err)
    raises(parseseg.ArgumentError, ed.set_trace, 200, "trace.sourceX", 1)
    raises(parseseg.ArgumentError, ed.set_record, 0, "gh1.year", 1)
    raises(parseseg.ArgumentError, ed.set_trace, 0, "trace.sourceX", [1])
    raises(parseseg.ArgumentError, ed.set_trace, 0, "trace.sourceX", 1 << 70)
    assert ed.edits() >= 4
    assert any(x["severity"] in ("warning", "error") for x in ed.diagnostics())
raises(parseseg.StateError, ed.edits)
with parseseg.open(path) as e2:
    assert e2.trace_field(5, "trace.sourceX") == 1_700_000
    assert e2.file_field("binary.jobId") == 4242
assert parseseg.journal_rollback(path, journal) == []
assert open(path, "rb").read() == original
assert parseseg.journal_apply(path, journal) == []
assert open(path, "rb").read() != original
assert parseseg.journal_rollback(path, journal) == []
err = raises(parseseg.IOError, parseseg.journal_apply, path, os.path.join(scratch, "nope.nif"))
assert isinstance(err.diagnostics, list) and err.diagnostics[-1]["severity"] == "fatal"
raises(parseseg.IOError, parseseg.open_editor, os.path.join(scratch, "missing.sgy"))

# ------------------------------------------------------------- conversion --
dst = os.path.join(scratch, "rev1.sgy")
log = parseseg.convert(INGLEWOOD, dst, revision="1", byte_order="big", format=5)
assert isinstance(log, list)
with parseseg.open(dst) as c1, parseseg.open(INGLEWOOD) as c0:
    assert c1.trace_count() == 200 and c1.file_field("binary.formatCode") == 5
    assert c1.read(0, 5).tobytes() == c0.read(0, 5).tobytes()
dst2 = os.path.join(scratch, "inova.sgy")
log = parseseg.convert(INOVA, dst2, text_encoding="ascii")
assert any(x["severity"] == "info" for x in log)
with parseseg.open(dst2) as c2:
    assert c2.trace_count() == 5
raises(parseseg.ArgumentError, parseseg.convert, INGLEWOOD, dst, revision="3")
raises(parseseg.ArgumentError, parseseg.convert, INGLEWOOD, dst, revision="x")
raises(parseseg.ArgumentError, parseseg.convert, INGLEWOOD, dst, byte_order="middle")
raises(parseseg.ArgumentError, parseseg.convert, INGLEWOOD, dst, format=300)
err = raises(parseseg.Error, parseseg.convert, os.path.join(scratch, "missing.sgy"), dst)
assert err.diagnostics and err.diagnostics[-1]["severity"] == "fatal"
err = raises(parseseg.Error, parseseg.convert, INGLEWOOD, INGLEWOOD)
assert err.diagnostics

# ---------------------------------------------------------- object hygiene --
# Objects made directly from their classes are empty, not crashes.
raises(parseseg.StateError, parseseg.SeismicFile().trace_count)
raises(parseseg.StateError, parseseg.Samples().shape)
raises(parseseg.StateError, parseseg.Prefetch().next)
raises(parseseg.StateError, parseseg.Editor().edits)
assert "empty" in repr(parseseg.Samples())
# Many short-lived handles: nothing leaks a worker or a map (the count of
# threads stays put).
before = threading.active_count()
for _ in range(50):
    with parseseg.open(SWEEP) as sw:
        with sw.prefetch(0, -1, 1, 1) as p:
            p.next()
        sw.read(0, 1).tolist()
gc.collect()
assert threading.active_count() == before

print("python module: ok")
