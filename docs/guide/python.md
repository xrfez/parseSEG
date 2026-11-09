# Using parseSEG from Python

The `parseseg` package is generated from the Nim API and loads the same shared library as C
(through `ctypes`; no compiled extension, so one build serves every Python 3). Names are the
Nim names in snake_case, docstrings are the Nim doc comments (`help(parseseg)`), so the
other guides apply to Python too. numpy is optional: with it, samples are numpy arrays
without a copy; without it, tensors still give lists and bytes. Design notes:
`docs/design/python.md`.

## Install

```sh
nim pylib                                # bin/python/parseseg/: __init__.py + the library
PYTHONPATH=bin/python python3 -c "import parseseg; print(parseseg.version())"
```

Copy `bin/python/parseseg` into site-packages to install it; `PARSESEG_LIBRARY` points the
module at another build of the library.

## Open, inspect, read

```python
import parseseg

with parseseg.open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy") as f:
    s = f.summary()                       # a dict, the same keys for every standard
    print(f.kind, len(f), "traces,", f.max_samples, "samples at", s["sample_interval_us"], "us")
    print("revision", s["revision"], "format", s["format_code"], s["coordinate_units"])

    t = f.read_traces(range(100, 150))    # a Tensor [50, 2001], float32
    print(t.shape, t.dtype)
    rows = t.tolist()                     # without numpy: lists (or t.tobytes())
    print("peak of trace 100:", max(abs(x) for x in rows[0]))

    picks = f.read_traces([199, 0, 100], dtype="float64")   # a selection, in that order
    assert picks.shape == (3, 2001) and picks.tolist()[2] == [float(x) for x in rows[0]]
    print(f.trace_field(5, "trace.sourceX"), f.file_field("binary.formatCode"))
    assert len(f) == 200 and len(f.log) == 0
```

`range` objects are trace ranges (step 1); lists are selections. A file is closed by `with`
or `close()`; afterwards every call raises `parseseg.StateError`, but tensors (and numpy
arrays) you already have stay valid.

## numpy, zero-copy

```python
import numpy as np
import parseseg

with parseseg.open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy") as f:
    a = f.read_traces(range(200)).numpy()          # np.from_dlpack: no copy
    b = np.asarray(f.read_traces([5, 3, 1]))       # __array__: no copy either
    print(a.shape, a.dtype, b.shape)

    # Decode straight into your own array: no intermediate buffer at all.
    out = np.zeros((64, 2001), np.float32)
    failed = f.read_traces_into(range(64, 128), out)
    big = np.zeros((128, 3000), np.float32)
    f.read_traces_into(range(64), big[::2, 10:2011])   # strided rows are fine
    assert failed == 0 and np.array_equal(out, a[64:128])
# `a` and `b` outlive the file: each holds a reference to its samples.
print(float(np.abs(a).max()))
```

Destination arrays must be 2-D with contiguous rows (C order; any row stride), native
float32 or float64, and writable. Rows are cut or zero-padded to the array's width.
`Tensor` also speaks DLPack (`torch.from_dlpack(t)`).

### Without numpy

Any writable 2-D buffer works as a destination, for example a `memoryview` cast over a
`bytearray`:

```python
import parseseg

with parseseg.open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy") as f:
    rows, cols = 4, 2001
    buf = memoryview(bytearray(rows * cols * 4)).cast("B").cast("f", [rows, cols])
    failed = f.read_traces_into([95, 100, 105, 110], buf)
    assert failed == 0
    assert buf[1, 1000] == f.read_traces([100]).tolist()[0][1000]
    print("trace 100, sample 1000:", buf[1, 1000])
```

## Prefetch

A `Prefetcher` decodes ahead on a worker thread. Iterate it, or poll with `try_next()`
(`None` until a chunk is ready); `seek(range)` jumps. A chunk is a dict with `first`,
`count`, `failed` and `samples` (a `Tensor`). The prefetcher keeps the file's map alive, even
if the file is closed first.

```python
import parseseg

f = parseseg.open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")
with parseseg.Prefetcher(f, range(len(f)), chunk_traces=64, depth=3) as p:
    firsts = [c["first"] for c in p]           # chunks in order, decoded ahead
    print("chunks start at", firsts)
    p.seek(range(150, len(p)))                 # the user jumped
    c = p.next()
    assert c["first"] == 150 and c["samples"].shape == (50, 2001)
f.close()
assert firsts == [0, 64, 128, 192]
```

## Threads

Every call releases the GIL while it runs, and reads on one file run in parallel in the
library, so Python threads decode concurrently.

```python
import threading
import parseseg

f = parseseg.open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")
parts = [None] * 4

def work(k):
    parts[k] = f.read_traces(range(50 * k, 50 * k + 50)).tobytes()

threads = [threading.Thread(target=work, args=(k,)) for k in range(4)]
for t in threads:
    t.start()
for t in threads:
    t.join()
assert b"".join(parts) == f.read_traces(range(200)).tobytes()
print("4 threads agree with one")
f.close()
```

## Headers, keys, gathers

```python
import math
import parseseg

with parseseg.open_seismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", keys=True) as f:
    k = f.trace_keys(3)                        # a dict; NaN where unknown
    print("receiver", k["rcv_line"], k["rcv_point"], "offset", round(k["offset"], 1))
    print("gathers:", f.gathers())             # kind, traces (a range), sources, receivers
    print("component groups:", f.component_group_ids(range(len(f))))
    for cs in f.channel_sets():
        print("channel set", cs["number"], "type", hex(cs["channel_type"]), cs["trace_count"],
              "trace(s)")

    rows = f.trace_headers(3)                  # the header tab: a sequence of row dicts
    for r in list(rows)[:4]:
        print(f'{r["block_name"]}.{r["field"]} = {r["value"]} at byte {r["offset"]}')
    first = rows[0]
    raw = f.copy_bytes(first["block_offset"], first["block_size"])   # for a hex pane
    assert len(raw) == first["block_size"]
    assert f.gathers()[0]["kind"] == "shot" and not math.isnan(k["time"])
```

## Edits, journals, patches

```python
import shutil
import parseseg

shutil.copyfile("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", "line.sgy")
original = open("line.sgy", "rb").read()

with parseseg.open_editor("line.sgy") as ed:          # journal: line.sgy.edits.nif
    assert ed.set_trace_field(5, "trace.sourceX", 1_700_000)
    assert not ed.set_trace_field(5, "trace.numSamples", 10)    # refused: structural
    print("refused:", ed.log[-1]["msg"])
with parseseg.open_seismic("line.sgy") as f:
    assert f.trace_field(5, "trace.sourceX") == 1_700_000

parseseg.rollback_journal("line.sgy", "line.sgy.edits.nif")
assert open("line.sgy", "rb").read() == original

# A viewer's pending edits, saved without touching the file.
p = parseseg.HeaderPatch()
p.add("trace", 5, "trace.sourceX", 1_700_000)
p.add("file", 0, "binary.jobId", 7)
p.write("pending.nif")
print(open("pending.nif").read())
```

Applying a patch (`importHeaders`) is not in the Python module; use Nim or
`parseSEG headers import line.sgy pending.nif` ([editing.md](editing.md)).

## Conversion and survey geometry

Options are dicts of the Nim option fields in snake_case; enum values are their names.

```python
import parseseg

log = parseseg.convert_file("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", "inova.sgy",
                            {"revision": (1, 0), "format": "5", "text_encoding": "ascii"})
for d in log:
    print(d["severity"], d["msg"])
log = parseseg.convert_file("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", "inova.sg2",
                            {"target": "SEG-2", "seg2": {"byte_order": "little"}})
assert not log.is_fatal

with open("line.sps", "w") as fh:
    fh.write("H00 SPS format version number   SPS 2.1;\n"
             "R     10.00    101.00  1G1                     500100.0 6000000.0  12.5 18213250\n"
             "S     20.00    205.00  1V6                     500000.0 6000400.0  10.0 19001150\n"
             "XT1          6311     20.00    205.001    1    11     10.00    101.00    101.001\n")
g = parseseg.SurveyGeometry()
g.add_sps("line.sps")
with parseseg.open_seismic("SEG Spec/exampleFiles/63.sgd", keys=True) as f:
    assert f.apply_survey(g, True) == 1        # in memory only
    print("receiver at", f.trace_keys(0)["rcv_x"], f.trace_keys(0)["rcv_y"])
    print("writing it back would change", f.geometry_changes()["traces"], "trace(s)")
parseseg.convert_with_geometry("SEG Spec/exampleFiles/63.sgd", "63_geo.sgy", g, None, None,
                               True)
with parseseg.open_seismic("63_geo.sgy", keys=True) as y:
    assert y.trace_keys(0)["rcv_x"] == 500100
```

## Errors

| Exception | When |
|---|---|
| `parseseg.ArgumentError` (a `ValueError`) | A bad argument: trace out of range, unknown field name, missing keys |
| `parseseg.FormatError` (a `ValueError`) | Bytes that cannot be decoded (`read_traces` naming the first bad trace), or a conversion whose log is fatal |
| `parseseg.IOError` (an `OSError`) | The OS refused: missing file, permissions |
| `parseseg.StateError` | A call on a closed object |
| `TypeError` | A wrong Python type (a path that is not a `str`, a `range` with a step) |

All derive from `parseseg.Error`. A failure that comes with diagnostics carries them in
`e.diagnostics`. Problems *in the file* are not exceptions: they are in `f.log`
([diagnostics.md](diagnostics.md)).

```python
import parseseg

f = parseseg.open_seismic("SEG Spec/exampleFiles/63.sgd")
try:
    f.trace_field(0, "trace.noSuchField")
except parseseg.ArgumentError as e:
    print("bad call:", e)
try:
    parseseg.convert_file("missing.sgd", "out.sgy")
except parseseg.Error as e:
    print("failed:", e.diagnostics[-1]["msg"])
for d in f.log:
    print(d["severity"], d["code"], d["loc"]["field"], d["msg"])
f.close()
```
