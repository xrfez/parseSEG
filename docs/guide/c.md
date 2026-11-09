# Using parseSEG from C and C++

The C ABI is the same library as the Nim API, with mechanically derived names: Nim
`f.readTraces(a..b)` is `seg_seismic_file_read_traces_range(f, a, b, ...)`, `f.traceKeys(i)`
is `seg_seismic_file_trace_keys(f, i, &out)`. So the other guides ([viewer.md](viewer.md),
[processing.md](processing.md), ...) apply to C too; this page shows the C mechanics. The
header `include/parseseg.h` documents every function, and `docs/design/c_abi.md` the design.

## Build and link

```sh
nim lib          # bin/libparseseg.so (.dylib, .dll) and include/parseseg.h
nim staticlib    # bin/libparseseg.a: link with -lpthread -lm -ldl
nim csources     # bin/csources/<triple>/: generated C + Makefile/CMakeLists, no Nim needed
cc -std=c99 -Iinclude app.c -Lbin -lparseseg -Wl,-rpath,bin -o app
```

The header is self-contained C99 and also compiles as C++ (`extern "C"`).

## The rules, in brief

- Call `seg_init()` once (any thread, repeat calls are harmless) and compare its result with
  `SEG_ABI_VERSION`.
- Every function returns a `SegStatus`: `SEG_OK` (0); positive non-errors `SEG_END` and
  `SEG_NOT_READY`; negative `SEG_ERR_*` failures, after which `seg_last_error()` holds the
  reason (per thread, valid until that thread's next call).
- Results come through trailing out-pointers (NULL if you do not want them). Text and lists
  are copied into your buffer: `out, out_cap, out_len`, where `*out_len` is the full length,
  so a short buffer is detected and the call repeated (`out_cap` 0 asks for the length).
- Handles (`SegSeismicFile`, `SegTensor`, `SegPrefetcher`, `SegHeaderEditor`,
  `SegSurveyGeometry`, `SegDiagLog`, `SegHeaderListing`, `SegHeaderPatch`) are
  reference-counted and owned by you: release each with its `seg_<x>_release`.
- Trace ranges are `first, last` with **both ends included**; lists are
  `const int64_t *traces, int64_t traces_len`.
- Option structs: fill with `seg_init_<name>(&opts)`, change fields, pass a pointer (or NULL
  for the defaults).

## Open, inspect, read

```c
#include "parseseg.h"
#include <stdio.h>

#define TRY(call) do { SegStatus s_ = (call); if (s_ < 0) { \
    fprintf(stderr, "%s failed: %s\n", #call, seg_last_error()); return 1; } } while (0)

int main(void) {
    if (seg_init() != SEG_ABI_VERSION) return 1;

    SegSeismicFile *f = NULL;
    TRY(seg_open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", false, false, &f));
    int64_t n = 0, ns = 0;
    TRY(seg_seismic_file_len(f, &n));
    TRY(seg_seismic_file_max_samples(f, &ns));
    SegFileSummary s;
    TRY(seg_seismic_file_summary(f, &s));
    printf("%lld traces, %lld samples at %g us, SEG-Y rev %lld.%lld, format %lld\n",
           (long long)n, (long long)ns, s.sample_interval_us, (long long)s.revision.major,
           (long long)s.revision.minor, (long long)s.format_code);

    /* Traces 100..149 (both included) as a new tensor, float32. */
    SegTensor *t = NULL;
    TRY(seg_seismic_file_read_traces_range(f, 100, 149, SEG_DTYPE_FLOAT32, &t));
    SegTensorView v;
    TRY(seg_tensor_view(t, &v));          /* valid until seg_tensor_release(t) */
    const float *data = (const float *)v.data;
    float peak = 0;
    for (int64_t r = 0; r < v.shape[0]; r++)
        for (int64_t c = 0; c < v.shape[1]; c++) {
            float x = data[r * v.strides[0] + c * v.strides[1]];
            if (x > peak) peak = x;
            if (-x > peak) peak = -x;
        }
    printf("tensor %lld x %lld, peak %g\n", (long long)v.shape[0], (long long)v.shape[1], peak);
    seg_tensor_release(t);

    /* A bad argument is a status, never a crash. */
    SegStatus st = seg_seismic_file_read_traces_range(f, 190, 250, SEG_DTYPE_FLOAT32, &t);
    printf("read past the end: %d (%s)\n", (int)st, seg_last_error());
    if (st != SEG_ERR_ARGUMENT || n != 200 || ns != 2001) return 1;

    seg_seismic_file_release(f);          /* unmaps the file */
    return 0;
}
```

## Decode into your own buffer

For a viewer's framebuffer or a processing library's arrays, decode straight into memory you
own: describe it with a `SegTensorView` (rows contiguous, any row stride). Rows are cut or
zero-padded to `shape[1]`. The result counts traces that could not be decoded (left zero).

```c
#include "parseseg.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    if (seg_init() != SEG_ABI_VERSION) return 1;
    SegSeismicFile *f = NULL;
    if (seg_open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", false, false,
                         &f) != SEG_OK) return 1;

    /* A 64 x 2001 window inside a wider, caller-owned image (row stride 2048). */
    enum { ROWS = 64, COLS = 2001, STRIDE = 2048 };
    float *image = calloc((size_t)ROWS * STRIDE, sizeof(float));
    SegTensorView dst;
    seg_init_tensor_view(&dst);
    dst.data = image;
    dst.dtype = SEG_DTYPE_FLOAT32;
    dst.rank = 2;
    dst.shape[0] = ROWS;
    dst.shape[1] = COLS;
    dst.strides[0] = STRIDE;
    dst.strides[1] = 1;

    int64_t failed = -1;
    if (seg_seismic_file_read_traces_into_range(f, 64, 127, &dst, 0, &failed) != SEG_OK) {
        fprintf(stderr, "%s\n", seg_last_error());
        return 1;
    }
    /* A selection, in any order, into rows 0..2. */
    const int64_t picks[] = {199, 0, 100};
    if (seg_seismic_file_read_traces_into(f, picks, 3, &dst, 0, &failed) != SEG_OK) return 1;
    float peak = 0;
    for (size_t i = 0; i < (size_t)ROWS * STRIDE; i++)
        if (image[i] > peak) peak = image[i];
    printf("decoded, %lld failed; peak %g\n", (long long)failed, peak);

    free(image);
    seg_seismic_file_release(f);
    return failed == 0 ? 0 : 1;
}
```

`seg_tensor_to_dlpack` hands a `SegTensor` to DLPack consumers (PyTorch, JAX, CuPy, numpy)
without a copy; the `DLManagedTensor` holds a reference until its `deleter` is called.

## Prefetch on a worker thread

`seg_prefetcher_try_next` never blocks (`SEG_NOT_READY` until a chunk is decoded);
`seg_prefetcher_next` waits. Both return `SEG_END` after the last chunk. Each chunk's
`samples` tensor is yours: release it.

```c
#include "parseseg.h"
#include <stdio.h>

int main(void) {
    if (seg_init() != SEG_ABI_VERSION) return 1;
    SegSeismicFile *f = NULL;
    if (seg_open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", false, false,
                         &f) != SEG_OK) return 1;
    SegPrefetcher *p = NULL;
    /* All traces, 32 per chunk, at most 4 chunks ahead, rows as wide as the longest trace. */
    if (seg_prefetcher_new_range(f, 0, 199, 32, 4, -1, SEG_DTYPE_FLOAT32, &p) != SEG_OK)
        return 1;
    seg_seismic_file_release(f);   /* safe: the prefetcher keeps the map open */

    SegPrefetchChunk c;
    int64_t traces = 0;
    SegStatus s;
    while ((s = seg_prefetcher_next(p, &c)) == SEG_OK) {
        SegTensorView v;
        seg_tensor_view(c.samples, &v);
        traces += c.count;
        seg_tensor_release(c.samples);
    }
    printf("%lld traces prefetched, last status %d\n", (long long)traces, (int)s);

    seg_prefetcher_seek(p, 150, 199);          /* the user jumped */
    while ((s = seg_prefetcher_try_next(p, &c)) == SEG_NOT_READY) { /* draw the UI */ }
    if (s != SEG_OK || c.first != 150) return 1;
    seg_tensor_release(c.samples);

    seg_prefetcher_close(p);                   /* joins the worker */
    seg_prefetcher_release(p);
    return traces == 200 ? 0 : 1;
}
```

## Headers, keys and diagnostics

Named fields come back as a `SegValue`: an integer, a float, or text copied into a buffer
you supply. A header listing is a handle you index with `_len` / `_get`; the strings in its
rows are borrowed from it, as the strings of a `SegDiagnostic` are from its `SegDiagLog`.

```c
#include "parseseg.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    if (seg_init() != SEG_ABI_VERSION) return 1;
    SegSeismicFile *f = NULL;
    if (seg_open_seismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", false, true, &f)
        != SEG_OK) return 1;

    SegTraceKeys k;
    seg_seismic_file_trace_keys(f, 3, &k);
    printf("trace 3: receiver %g/%g at (%.1f, %.1f), offset %.1f\n", k.rcv_line, k.rcv_point,
           k.rcv_x, k.rcv_y, k.offset);

    SegValue v;
    memset(&v, 0, sizeof v);
    if (seg_seismic_file_record_field(f, 0, "gh1.fileNumber", &v) != SEG_OK) return 1;
    printf("file number %lld\n", (long long)v.i);

    /* Rev 3 THE#1: a 3-byte line number of -1 (FFFFFF) means "see the extended field". */
    seg_seismic_file_trace_field(f, 3, "ext1.receiverLineNumber", &v);
    if (v.kind == SEG_VALUE_INT && v.i == -1)
        seg_seismic_file_trace_field(f, 3, "ext1.extReceiverLineNumber", &v);
    printf("THE#1 receiver line: %g\n", v.f);

    /* The header tab: every row of trace 3's headers. */
    SegHeaderListing *rows = NULL;
    seg_seismic_file_trace_headers(f, 3, &rows);
    int64_t nrows = 0;
    seg_header_listing_len(rows, &nrows);
    for (int64_t i = 0; i < nrows && i < 5; i++) {
        SegHeaderRow r;
        seg_header_listing_get(rows, i, &r);
        printf("  %s.%s at byte %lld\n", r.block_name, r.field, (long long)r.offset);
    }
    seg_header_listing_release(rows);

    /* Gathers, as a list copied into a caller buffer. */
    SegGather g[8];
    int64_t ng = 0;
    seg_seismic_file_gathers(f, g, 8, &ng);
    printf("%lld gather(s); the first is kind %d, traces %lld..%lld\n", (long long)ng,
           (int)g[0].kind, (long long)g[0].traces.a, (long long)g[0].traces.b);

    /* The index's diagnostics. */
    SegDiagLog *log = NULL;
    seg_seismic_file_log(f, &log);
    int64_t nd = 0;
    seg_diag_log_len(log, &nd);
    for (int64_t i = 0; i < nd; i++) {
        SegDiagnostic d;
        seg_diag_log_get(log, i, &d);
        printf("severity %d code %d at %lld: %s\n", (int)d.severity, (int)d.code,
               (long long)d.offset, d.msg);
    }
    seg_diag_log_release(log);
    seg_seismic_file_release(f);
    return (fabs(k.offset - 8490.11) < 0.01 && ng == 1 && g[0].kind == SEG_GATHER_KIND_SHOT)
        ? 0 : 1;
}
```

## Threads

Any thread may call in. Calls on one handle are serialized by a lock inside the handle,
except the reads (`seg_seismic_file_read_traces*`), which run in parallel on one file.

```c
#include "parseseg.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { SegSeismicFile *f; int64_t first, last; double sum; } Job;

static void *work(void *arg) {
    Job *j = arg;
    SegTensor *t = NULL;
    if (seg_seismic_file_read_traces_range(j->f, j->first, j->last, SEG_DTYPE_FLOAT64, &t)
        != SEG_OK) return NULL;
    SegTensorView v;
    seg_tensor_view(t, &v);
    const double *x = v.data;
    for (int64_t i = 0; i < v.shape[0] * v.shape[1]; i++) j->sum += x[i] < 0 ? -x[i] : x[i];
    seg_tensor_release(t);
    return NULL;
}

int main(void) {
    if (seg_init() != SEG_ABI_VERSION) return 1;
    SegSeismicFile *f = NULL;
    if (seg_open_seismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", false, false,
                         &f) != SEG_OK) return 1;
    Job jobs[4];
    pthread_t th[4];
    for (int k = 0; k < 4; k++) {
        jobs[k] = (Job){f, k * 50, k * 50 + 49, 0};
        pthread_create(&th[k], NULL, work, &jobs[k]);
    }
    double total = 0;
    for (int k = 0; k < 4; k++) {
        pthread_join(th[k], NULL);
        total += jobs[k].sum;
    }
    printf("sum of |samples| over 4 threads: %.1f\n", total);
    seg_seismic_file_release(f);
    return total > 0 ? 0 : 1;
}
```

## Edit, journal, convert

```c
#include "parseseg.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int copy_file(const char *from, const char *to) {
    FILE *a = fopen(from, "rb"), *b = fopen(to, "wb");
    if (!a || !b) return 1;
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, a)) > 0) fwrite(buf, 1, n, b);
    fclose(a);
    fclose(b);
    return 0;
}

int main(void) {
    if (seg_init() != SEG_ABI_VERSION) return 1;
    if (copy_file("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", "line.sgy")) return 1;

    /* In place, journaled. A refused edit is `false`, with the reason in the editor's log. */
    SegHeaderEditor *ed = NULL;
    if (seg_open_editor("line.sgy", NULL, &ed) != SEG_OK) return 1;   /* line.sgy.edits.nif */
    SegValue v;
    memset(&v, 0, sizeof v);
    v.kind = SEG_VALUE_INT;
    v.i = 1700000;
    bool ok = false;
    seg_header_editor_set_trace_field(ed, 5, "trace.sourceX", &v, &ok);
    printf("edit written: %d\n", ok);
    v.i = 10;
    seg_header_editor_set_trace_field(ed, 5, "trace.numSamples", &v, &ok);
    printf("structural edit written: %d\n", ok);
    seg_header_editor_close(ed);
    seg_header_editor_release(ed);

    /* Undo everything. */
    SegDiagLog *log = NULL;
    if (seg_rollback_journal("line.sgy", "line.sgy.edits.nif", &log) != SEG_OK) return 1;
    seg_diag_log_release(log);

    /* SEG-D to SEG-Y Rev 1.0, IEEE float: a fatal log is a failed status. */
    SegConvertOptions opts;
    seg_init_convert_options(&opts);
    opts.revision.major = 1;
    opts.revision.minor = 0;
    opts.format = SEG_SEGY_TARGET_FORMAT_5;
    SegStatus s = seg_convert_file("SEG Spec/exampleFiles/inova_rev30_5traces.sgd",
                                   "inova_rev1.sgy", &opts, &log);
    int64_t notes = 0;
    seg_diag_log_count(log, SEG_SEVERITY_INFO, &notes);
    printf("convert: status %d, %lld notes\n", (int)s, (long long)notes);
    seg_diag_log_release(log);
    return s == SEG_OK ? 0 : 1;
}
```

## Lifetimes

| You hold | Valid until |
|---|---|
| Any handle | You release it (releasing NULL is a no-op; using a released handle is undefined) |
| `SegTensorView.data` from `seg_tensor_view` | `seg_tensor_release` of that tensor |
| A DLPack tensor | Its consumer calls `deleter` (it holds its own reference) |
| Strings in a `SegDiagnostic`, `SegHeaderRow` | The `SegDiagLog` / `SegHeaderListing` they came from is released |
| `seg_last_error()` | That thread's next call into the library |
| A `SegPrefetcher` | Keeps its file's map alive: the file may be released first |

There is no `close` for a `SegSeismicFile`: releasing the last reference (yours, or a
prefetcher's) unmaps it. `seg_header_editor_close` and `seg_prefetcher_close` end the work
(flush the journal, join the worker); release the handle afterwards.

Out of scope for C so far: the writers other than conversion, `importHeaders` and
`exportHeaders`, vendor-map registration and tape devices (Nim only).
