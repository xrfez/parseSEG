"""The Python module `parseseg` end to end (tasks 8.8, 12.2, 12.5): the generated ctypes
package over the shared library.

    python3 -I test_pyapi.py <dir holding the parseseg package> <exampleFiles dir> <scratch dir> [nonumpy]

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
assert parseseg.version() == "0.4.0" and parseseg.abi_version() == 4
assert "SEG-Y" in parseseg.__doc__
assert parseseg.status_name(-2) == "SEG_ERR_IO"
# Exception classes exist before any error, with their documented bases.
E = parseseg
assert issubclass(E.ArgumentError, E.Error) and issubclass(E.ArgumentError, ValueError)
assert issubclass(E.FormatError, E.Error) and issubclass(E.FormatError, ValueError)
assert issubclass(E.IOError, E.Error) and issubclass(E.IOError, OSError)
assert issubclass(E.StateError, RuntimeError) and issubclass(E.InternalError, RuntimeError)
assert issubclass(E.Error, Exception) and E.FormatError is parseseg.FormatError
assert "FormatError" in dir(parseseg) and "open_seismic" in dir(parseseg)
raises(AttributeError, getattr, parseseg, "NoSuchThing")

# ------------------------------------------------------------ open / index --
f = parseseg.open_seismic(INGLEWOOD, keys=True)
assert f.kind == "SEG-Y" and len(f) == 200 and f.max_samples == 2001 and f.has_keys
assert f.record_count == 1 and f.sample_interval_us(0) == 2000.0 and f.sample_interval_us() == 2000.0
assert f.is_open and f.path == INGLEWOOD
raises(parseseg.ArgumentError, f.sample_interval_us, 200)
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
assert len(f.log) == 0 and list(f.log) == [] and f.log.to_nif().startswith("(")
assert not f.log.has_errors and not f.log.is_fatal
head = f.copy_bytes(0, 4)
assert isinstance(head, bytes) and len(head) == 4 and head[0] == 0xC3   # EBCDIC "C"
raises(parseseg.ArgumentError, f.copy_bytes, -1, 1)
raises(parseseg.ArgumentError, f.copy_bytes, 0, -1)
nolog = parseseg.open_seismic(INGLEWOOD)                  # keys=False, as in Nim
assert not nolog.has_keys
raises(parseseg.ArgumentError, nolog.trace_keys, 0)
raises(parseseg.ArgumentError, nolog.gathers)
nolog.close()
raises(parseseg.IOError, parseseg.open_seismic, os.path.join(scratch, "missing.sgy"))
raises(TypeError, parseseg.open_seismic, 42)
junk = os.path.join(scratch, "junk.bin")
with open(junk, "wb") as fh:
    fh.write(b"\0" * 5000)
with parseseg.open_seismic(junk) as j:
    assert j.kind == "unknown" and len(j) == 0 and j.log.is_fatal   # a log, not a failure
    assert j.log[-1]["severity"] == "fatal" and j.log[0]["loc"]["file"] == junk

# Text fields come back as str.
assert isinstance(f.trace_field(0, "trace.headerName"), str)

# ------------------------------------------------------------------ reads --
s = f.read_traces(range(100, 103))
assert s.shape == (3, 2001) and s.dtype == "float32" and "3x2001" in repr(s)
rows = s.tolist()
assert len(rows) == 3 and len(rows[0]) == 2001 and any(x != 0 for x in rows[0])
raw = s.tobytes()
assert len(raw) == 3 * 2001 * 4
assert list(array.array("f", raw)) == [x for r in rows for x in r]
s64 = f.read_traces(range(100, 103), dtype="float64")
assert s64.dtype == "float64" and s64.tolist() == rows
assert f.read_traces(range(198, 200)).shape == (2, 2001)
assert f.read_traces(range(200, 200)).shape == (0, 0)      # width from no trace
raises(parseseg.ArgumentError, f.read_traces, range(199, 201))
raises(parseseg.ArgumentError, f.read_traces, range(-1, 1))
raises(parseseg.ArgumentError, f.read_traces, range(1), dtype="int16")
raises(TypeError, f.read_traces, range(0, 10, 2))           # a Slice has step 1
sel = f.read_traces([102, 100, 101])
assert sel.tolist() == [rows[2], rows[0], rows[1]]
assert f.read_traces([]).shape == (0, 0)
raises(parseseg.ArgumentError, f.read_traces, [0, 200])
raises(parseseg.ArgumentError, f.read_traces, [-1])

# read_traces_into a stdlib buffer: array.array is 1-D, so it is refused (2-D needed).
raises(parseseg.ArgumentError, f.read_traces_into, range(1), array.array("f", bytes(4 * 2001)))

if np is not None:
    a = s.numpy()
    assert a.shape == (3, 2001) and a.dtype == np.float32 and not a.flags["OWNDATA"]
    assert a.tolist() == rows
    b = np.asarray(s)
    assert np.shares_memory(a, b)
    c = np.from_dlpack(s)
    assert np.shares_memory(a, c)
    assert np.asarray(s, dtype=np.float64).dtype == np.float64
    # The arrays keep the samples alive after the Tensor, the file and a GC pass.
    keep = a.copy()
    del s, b, c
    gc.collect()
    assert np.array_equal(a, keep)
    # Straight into the caller's arrays, rows padded or cut to its width.
    out = np.full((3, 2001), 7, np.float32)
    assert f.read_traces_into(range(100, 103), out) == 0 and np.array_equal(out, keep)
    out64 = np.zeros((3, 2001), np.float64)
    assert f.read_traces_into(range(100, 103), out64) == 0
    assert np.array_equal(out64, keep.astype(np.float64))
    wide = np.full((2, 2100), 7, np.float32)
    assert f.read_traces_into(range(100, 102), wide) == 0
    assert np.array_equal(wide[:, :2001], keep[:2]) and not wide[:, 2001:].any()
    narrow = np.zeros((2, 50), np.float32)
    assert f.read_traces_into(range(100, 102), narrow) == 0
    assert np.array_equal(narrow, keep[:2, :50])
    big = np.zeros((4, 3000), np.float32)
    view = big[::2, 10:2011]                     # strided rows, contiguous samples
    assert f.read_traces_into(range(100, 102), view) == 0 and np.array_equal(view, keep[:2])
    assert not big[1].any() and not big[0, :10].any()
    some = np.zeros((3, 2001), np.float32)
    assert f.read_traces_into([102, 100], some, row=1) == 0      # rows 1 and 2
    assert np.array_equal(some[1:], keep[[2, 0]]) and not some[0].any()
    raises(parseseg.ArgumentError, f.read_traces_into, [1, 2, 3], some, row=1)
    raises(parseseg.ArgumentError, f.read_traces_into, range(2), np.zeros((2, 10), np.int32))
    raises(parseseg.ArgumentError, f.read_traces_into, range(2),
           np.zeros((2, 10), np.float32, order="F"))
    raises(parseseg.ArgumentError, f.read_traces_into, range(2), np.zeros(10, np.float32))
    raises(parseseg.ArgumentError, f.read_traces_into, range(2), np.zeros((2, 10), ">f4"))
    raises(parseseg.ArgumentError, f.read_traces_into, range(300), np.zeros((300, 10), np.float32))
    ro = np.zeros((2, 10), np.float32)
    ro.flags.writeable = False
    raises(Exception, f.read_traces_into, range(2), ro)
    print("numpy: ok")
else:
    raises(ImportError, parseseg.Tensor.numpy, f.read_traces(range(1)))
    raises(ImportError, __import__("operator").methodcaller("__array__"), f.read_traces(range(1)))
    print("numpy not installed: numpy checks skipped")

# Reads release the GIL: four threads reading at once agree with one.
want = f.read_traces(range(200)).tobytes()
results = [None] * 4


def worker(i):
    results[i] = f.read_traces(range(200)).tobytes()


ts = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
for t in ts:
    t.start()
for t in ts:
    t.join()
assert all(r == want for r in results)

# --------------------------------------------------------------- prefetch --
with parseseg.Prefetcher(f, range(len(f)), chunk_traces=64, depth=3) as p:
    assert len(p) == 200 and p.trace_at(199) == 199
    raises(parseseg.ArgumentError, p.trace_at, 200)
    got, firsts = b"", []
    for c in p:                                 # the iterator protocol
        firsts.append(c["first"])
        assert c["failed"] == 0 and c["samples"].shape == (c["count"], 2001)
        got += c["samples"].tobytes()
    assert firsts == [0, 64, 128, 192] and got == want and p.at_end
    assert p.next() is None and p.try_next() is None
    p.seek(range(190, len(p)))
    while (c := p.try_next()) is None:
        pass
    assert c["first"] == 190 and c["count"] == 10
    raises(parseseg.ArgumentError, p.seek, range(5, 202))
raises(parseseg.StateError, p.next)
p.close()  # closing twice is fine
with parseseg.Prefetcher(f, [5, 3, 1], chunk_traces=2, depth=2, dtype="float64") as p:
    assert len(p) == 3 and p.trace_at(0) == 5
    c = p.next()
    assert c["first"] == 0 and c["count"] == 2 and c["samples"].dtype == "float64"
    assert c["samples"].tolist() == f.read_traces([5, 3], dtype="float64").tolist()
raises(parseseg.ArgumentError, parseseg.Prefetcher, f, range(200), 0)
raises(parseseg.ArgumentError, parseseg.Prefetcher, f, range(200), 1, 0)
raises(parseseg.ArgumentError, parseseg.Prefetcher, f, range(0, 201))
raises(parseseg.ArgumentError, parseseg.Prefetcher, f, [200])
raises(parseseg.ArgumentError, parseseg.Prefetcher, f, range(200), cols=1 << 40)  # 1 TiB limit
raises(TypeError, parseseg.Prefetcher, "not a file", range(1))
# A prefetcher keeps its file's map alive after the file is closed.
p = parseseg.Prefetcher(f, range(10))
f.close()
assert f.closed() and "closed" in repr(f)
c = p.next()
assert c["samples"].tobytes() == want[:10 * 2001 * 4]
p.close()
raises(parseseg.StateError, f.read_traces, range(1))
raises(parseseg.StateError, len, f)

# ---------------------------------------------------------------- SEG-D --
with parseseg.open_seismic(S63, keys=True) as d:
    assert d.kind == "SEG-D" and len(d) == 1 and d.record_count == 1
    assert d.record_field(0, "gh3.sourcePointNumber") == 99.5
    raises(parseseg.ArgumentError, d.record_field, 0, "gh4.sourcePointNumber")
    raises(parseseg.ArgumentError, d.file_field, "binary.jobId")
    assert [g["kind"] for g in d.gathers()] == ["shot"] and d.gathers()[0]["traces"] == range(1)
    assert d.read_traces(range(1)).shape[0] == 1
    infos = d.log
    assert len(infos) == 2 and all(x["severity"] == "info" for x in infos)
    assert set(infos[0]) == {"severity", "code", "offset", "loc", "msg"}
    assert set(infos[0]["loc"]) == {"file", "record", "channel_set", "trace", "block_index",
                                    "field"}
    assert infos.count("info") == 2 and infos[-1] == infos[1]
    raises(IndexError, infos.__getitem__, 2)
assert d.closed()

with parseseg.open_seismic(INOVA, keys=True) as r3:
    assert len(r3) == 5
    k = r3.trace_keys(3)                         # the first seismic trace
    assert abs(k["rcv_x"] - 1826232.375) < 1e-6 and abs(k["src_x"] - 1834704.375) < 1e-6
    assert abs(k["offset"] - math.hypot(1834704.375 - 1826232.375,
                                        445679.53125 - 446233.8125)) < 1e-3
    groups = r3.component_group_ids(range(len(r3)))
    assert groups == [-1, -1, -1, 0, 1]          # aux traces are in none
    assert len(r3.component_group_ids(range(1, 3))) == 2
    raises(parseseg.ArgumentError, r3.component_group_ids, range(3, 8))

# --------------------------------------------------------------- geometry --
with parseseg.open_seismic(S63, keys=True) as d:
    k = d.trace_keys(0)
    g = parseseg.SurveyGeometry()
    g.add_receiver(k["rcv_line"], k["rcv_point"], 0, 1000.5, 2000.25, 3.0)
    g.add_source(k["src_line"], k["src_point"], 0, 1100.5, 2000.25)
    assert g.source_count == 1 and g.receiver_count == 1
    raises(parseseg.ArgumentError, g.add_source, 1, 1, 1 << 20, 0, 0)   # int16 index
    assert d.apply_survey(g) == 1
    k2 = d.trace_keys(0)
    assert (k2["rcv_x"], k2["rcv_y"], k2["rcv_z"]) == (1000.5, 2000.25, 3.0)
    assert k2["src_x"] == 1100.5 and math.isnan(k2["src_z"]) and abs(k2["offset"] - 100) < 1e-9
    raises(TypeError, d.apply_survey, "not a geometry")

# Survey files: an SPS relation (record 63, channel 1) names the stations.
sps_path = os.path.join(scratch, "t.sps")
with open(sps_path, "w") as fh:
    fh.write("\n".join([
    'H00 SPS format version number   SPS 2.1;',
    'R     10.00    101.00  1G1                     500100.0 6000000.0  12.5 18213250',
    'S     20.00    205.00  1V6                     500000.0 6000400.0  10.0 19001150',
    'XT1          6311     20.00    205.001    1    11     10.00    101.00    101.001',
    ]) + "\n")
with parseseg.open_seismic(S63, keys=True) as d:
    assert d.trace_keys(0)["channel"] == 1
    g = parseseg.SurveyGeometry()
    g.add_sps(sps_path)
    assert len(g.log) == 0
    assert (g.source_count, g.receiver_count, g.relation_count) == (1, 1, 1)
    raises(parseseg.IOError, g.add_sps, sps_path + ".missing")
    raises(parseseg.ArgumentError, g.add_sps, sps_path, {"revision": "nope"})
    raises(parseseg.ArgumentError, g.add_sps, sps_path, {"bogus": 1})
    g.map_line("LINE A", 7)
    raises(parseseg.ArgumentError, g.map_line, "", 7)
    assert not g.trailing_digits and not g.multi_component and g.tape == ""
    g.trailing_digits = True
    g.tape = "T1"
    assert g.trailing_digits and g.tape == "T1"
    assert d.apply_survey(g, True) == 1
    k = d.trace_keys(0)
    assert (k["src_point"], k["rcv_point"], k["rcv_x"]) == (205, 101, 500100)
    raises(parseseg.ArgumentError, g.add_p1, sps_path, 9)

# ---------------------------------------------------------------- editing --
path = fresh(INGLEWOOD)
original = open(path, "rb").read()
journal = path + ".j.nif"
with parseseg.open_editor(path, journal) as ed:
    assert ed.journal_path == journal
    assert ed.set_trace_field(5, "trace.sourceX", 1_700_000)
    assert ed.set_trace_field(7, "trace.groupStatic", -12)
    assert ed.set_file_field("binary.jobId", 4242)
    assert ed.set_trace_field(0, "trace.headerName", "ABC")
    if np is not None:
        assert ed.set_trace_field(8, "trace.sourceX", np.int64(5))
    assert not ed.set_trace_field(0, "trace.numSamples", 10)        # refused: structural
    assert "numSamples" in ed.log[-1]["msg"] or "structural" in ed.log[-1]["msg"]
    assert not ed.set_trace_field(200, "trace.sourceX", 1)
    assert not ed.set_record_field(0, "gh1.year", 1)
    raises(parseseg.ArgumentError, ed.set_trace_field, 0, "trace.sourceX", [1])
    raises(parseseg.ArgumentError, ed.set_trace_field, 0, "trace.sourceX", 1 << 70)
    assert ed.edits >= 4
    assert any(x["severity"] in ("warning", "error") for x in ed.log)
raises(parseseg.StateError, getattr, ed, "edits")
with parseseg.open_seismic(path) as e2:
    assert e2.trace_field(5, "trace.sourceX") == 1_700_000
    assert e2.file_field("binary.jobId") == 4242
assert len(parseseg.rollback_journal(path, journal)) == 0
assert open(path, "rb").read() == original
assert len(parseseg.apply_journal(path, journal)) == 0
assert open(path, "rb").read() != original
assert len(parseseg.rollback_journal(path, journal)) == 0
err = raises(parseseg.IOError, parseseg.apply_journal, path, os.path.join(scratch, "nope.nif"))
assert isinstance(err.diagnostics, parseseg.DiagLog)
assert err.diagnostics[-1]["severity"] == "fatal"
raises(parseseg.IOError, parseseg.open_editor, os.path.join(scratch, "missing.sgy"))
raises(parseseg.ArgumentError, parseseg.open_editor, path, path)  # the journal is the file

# ------------------------------------------------------------- conversion --
dst = os.path.join(scratch, "rev1.sgy")
log = parseseg.convert_file(INGLEWOOD, dst, {"revision": (1, 0), "byte_order": "big",
                                             "format": "5"})
assert isinstance(log, parseseg.DiagLog) and not log.is_fatal
with parseseg.open_seismic(dst) as c1, parseseg.open_seismic(INGLEWOOD) as c0:
    assert len(c1) == 200 and c1.file_field("binary.formatCode") == 5
    assert c1.read_traces(range(5)).tobytes() == c0.read_traces(range(5)).tobytes()
dst2 = os.path.join(scratch, "inova.sgy")
log = parseseg.convert_file(INOVA, dst2, {"text_encoding": "ascii"})
assert any(x["severity"] == "info" for x in log)
with parseseg.open_seismic(dst2) as c2:
    assert len(c2) == 5
raises(parseseg.Error, parseseg.convert_file, INGLEWOOD, dst, {"revision": {"major": 3}})
raises(TypeError, parseseg.convert_file, INGLEWOOD, dst, {"revision": "x"})
raises(parseseg.ArgumentError, parseseg.convert_file, INGLEWOOD, dst, {"byte_order": "middle"})
raises(parseseg.ArgumentError, parseseg.convert_file, INGLEWOOD, dst, {"format": "13"})  # a hole
raises(parseseg.ArgumentError, parseseg.convert_file, INGLEWOOD, dst, {"format": 15})  # a name
dst16 = os.path.join(scratch, "f16.sgy")
log = parseseg.convert_file(INGLEWOOD, dst16, {"format": "16", "revision": (2, 1)})
with parseseg.open_seismic(dst16) as c16:
    assert c16.file_field("binary.formatCode") == 16
assert parseseg._E_SegyTargetFormat["15"] == 15 and parseseg.SegTensorView._defaults["dtype"] is None
raises(parseseg.ArgumentError, parseseg.convert_file, INGLEWOOD, dst,
       {"revision": {"major": 300}})                                   # uint8
err = raises(parseseg.Error, parseseg.convert_file, os.path.join(scratch, "missing.sgy"), dst)
assert err.diagnostics and err.diagnostics[-1]["severity"] == "fatal"
err = raises(parseseg.Error, parseseg.convert_file, INGLEWOOD, INGLEWOOD)
assert err.diagnostics

# SEG-D revisions (task 8.7).
r3 = os.path.join(scratch, "63_r3.sgd")
log = parseseg.convert_segd_revision(S63, r3)          # default 3.0
assert all(x["severity"] == "info" for x in log) and len(log)
with parseseg.open_seismic(r3) as d3, parseseg.open_seismic(S63) as d2:
    assert open(r3, "rb").read()[42] == 3        # GH#2 byte 11: revision major
    assert d3.record_field(0, "gh1.formatCode") == 8058
    assert d3.read_traces(range(1)).tobytes() == d2.read_traces(range(1)).tobytes()
r21 = os.path.join(scratch, "63_r21.sgd")
log = parseseg.convert_segd_revision(r3, r21, {"revision": (2, 1)})
assert open(r21, "rb").read()[42:44] == bytes([2, 1])
with parseseg.open_seismic(r21) as d21:
    assert len(d21) == 1
err = raises(parseseg.FormatError, parseseg.convert_segd_revision, S63, dst,
             {"revision": (1, 0)})
assert err.diagnostics[-1]["severity"] == "fatal"
raises(parseseg.FormatError, parseseg.convert_segd_revision, S63, dst,
       {"revision": (2, 1), "format": "8080"})
raises(parseseg.ArgumentError, parseseg.convert_segd_revision, S63, dst,
       {"format": 8080})                                 # a name, not a code

# ---------------------------------------------------------- object hygiene --
# Objects made directly from their classes are empty, not crashes.
raises(parseseg.StateError, len, parseseg.SeismicFile())
raises(parseseg.StateError, getattr, parseseg.Tensor(), "shape")
raises(parseseg.StateError, getattr, parseseg.HeaderEditor(), "edits")
assert "closed" in repr(parseseg.Tensor())
# Many short-lived handles: nothing leaks a worker or a map (the count of
# threads stays put).
before = threading.active_count()
for _ in range(50):
    with parseseg.open_seismic(SWEEP) as sw:
        with parseseg.Prefetcher(sw, range(len(sw)), 1, 1) as p:
            p.next()
        sw.read_traces(range(1)).tolist()
gc.collect()
assert threading.active_count() == before

# ------------------------------------------- Phase 8 review regressions --
with parseseg.open_seismic(INGLEWOOD, keys=True) as rf:
    # A wrong object raised a Defect that broke every later call.
    for wrong in (parseseg.Tensor(), rf.read_traces(range(1)), rf, None, 3):
        raises(TypeError, rf.apply_survey, wrong)
    assert len(rf) == 200 and parseseg.SurveyGeometry() is not None
    # Huge ranges were allocated before being checked (the process died).
    raises(parseseg.ArgumentError, rf.component_group_ids, range(0, 2 ** 40))
    raises(parseseg.ArgumentError, rf.component_group_ids, range(5, 2 ** 63))
    raises(parseseg.ArgumentError, rf.trace_field, 10 ** 6, "trace.sourceX")
    raises(parseseg.ArgumentError, rf.trace_entry, 2 ** 63 - 1)
    raises(parseseg.ArgumentError, rf.trace_entry, 2 ** 63)       # beyond int64, checked
    # Buffer errors keep their Python class (and no longer leak).
    raises(TypeError, rf.read_traces_into, range(1), None)
    raises(TypeError, rf.read_traces_into, range(1), [1])
    if np is not None:
        ro = np.zeros((2, 10), np.float32)
        ro.flags.writeable = False
        e = raises(Exception, rf.read_traces_into, range(2), ro)
        assert isinstance(e, (BufferError, ValueError)) and not isinstance(e, parseseg.Error)

if sys.platform.startswith("linux"):
    def maps_of(path):
        with open("/proc/self/maps") as m:
            return sum(1 for line in m if line.rstrip().endswith(os.path.basename(path)))

    def fds():
        return len(os.listdir("/proc/self/fd"))

    # Closed or dropped files and editors leave no mapping or descriptor.
    base = maps_of(INGLEWOOD)
    for _ in range(30):
        with parseseg.open_seismic(INGLEWOOD) as lf:
            lf.read_traces(range(1))
        lf2 = parseseg.open_seismic(INGLEWOOD)
        del lf2
    gc.collect()
    assert maps_of(INGLEWOOD) == base, (maps_of(INGLEWOOD), base)
    ed_path = fresh(SWEEP)
    before_fds = fds()
    for _ in range(20):
        e = parseseg.open_editor(ed_path, ed_path + ".j.nif")
        del e
    gc.collect()
    assert fds() == before_fds and maps_of(ed_path) == 0

print("python module: ok")
