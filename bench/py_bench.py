"""Python / numpy overhead (task 13.2): the C ABI operations of capi_bench.c
through the `parseseg` package, plus a zero-copy check of the numpy views.

    PYTHONPATH=bin/python python3 bench/py_bench.py FILE [FILE ...]

Prints one Markdown row per file (warm cache)."""
import sys
import time

import numpy as np
import parseseg


def pct(xs, q):
    xs = sorted(xs)
    return xs[max(0, min(len(xs) - 1, int(q * len(xs) + 0.999999) - 1))]


def bench(path):
    import os
    size = os.path.getsize(path)
    with parseseg.open_seismic(path) as f:
        n, ns = len(f), f.max_samples
        chunk = 1000
        buf = np.empty((chunk, ns), dtype=np.float32)
        best = 1e30
        for run in range(4):  # the first run maps the pages
            t0 = time.perf_counter()
            for i in range(0, n, chunk):
                f.read_traces_into(range(i, min(n, i + chunk)), buf)
            t = time.perf_counter() - t0
            if run > 0:
                best = min(best, t)
        # A numpy array decoded straight into: read_traces_into writes `buf` in
        # place; read_traces(...).numpy() shares the library's tensor.
        t = f.read_traces(range(0, 10))
        a = t.numpy()
        zero_copy = a.ctypes.data == t.view["data"] and a.base is not None
        rng = np.random.default_rng(13)
        one = np.empty((1, ns), dtype=np.float32)
        ids = rng.integers(0, n, 20000)
        xs = []
        for i in ids:
            i = int(i)
            t0 = time.perf_counter()
            f.read_traces_into(range(i, i + 1), one)
            xs.append(time.perf_counter() - t0)
        into = (pct(xs, 0.5), pct(xs, 0.99))
        xs = []
        for i in ids[:5000]:
            i = int(i)
            t0 = time.perf_counter()
            f.read_traces(range(i, i + 1)).numpy()
            xs.append(time.perf_counter() - t0)
        new = (pct(xs, 0.5), pct(xs, 0.99))
        xs = []
        for i in ids[:2000]:
            t0 = time.perf_counter()
            f.trace_headers(int(i))
            xs.append(time.perf_counter() - t0)
        listing = pct(xs, 0.5)
        field = "trace.sourceX" if path.endswith(".sgy") else "ext1.receiverPointNumber"
        xs = []
        for i in ids[:5000]:
            t0 = time.perf_counter()
            f.trace_field(int(i), field)
            xs.append(time.perf_counter() - t0)
        fld = pct(xs, 0.5)
        sel = list(range(0, min(n, 1000 * 500), 500))  # a 1000-trace selection
        t0 = time.perf_counter()
        f.read_traces(sel).numpy()
        selt = time.perf_counter() - t0
    print(f"| {os.path.basename(path)} | {size / best / 1e9:.2f} | {into[0] * 1e6:.1f} / "
          f"{into[1] * 1e6:.1f} | {new[0] * 1e6:.1f} / {new[1] * 1e6:.1f} | "
          f"{listing * 1e6:.1f} | {fld * 1e6:.1f} | {selt * 1e3:.2f} | "
          f"{'yes' if zero_copy else 'NO'} |")


print("| file | decode GB/s | single trace into µs p50 / p99 | single trace .numpy() µs p50 / "
      "p99 | header listing µs p50 | trace_field µs p50 | 1000-trace list ms | zero-copy |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for p in sys.argv[1:]:
    bench(p)
