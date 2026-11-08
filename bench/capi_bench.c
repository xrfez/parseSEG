/* C ABI overhead (task 13.2): the operations of bench/suite.nim's decode and
 * latency sections through include/parseseg.h, for comparison with native
 * Nim on the same file.
 *
 *   cc -O2 -Iinclude bench/capi_bench.c -Lbin -lparseseg -Wl,-rpath,bin -o capi_bench
 *   ./capi_bench FILE [FILE ...]
 *
 * Prints one Markdown row per file: sequential decode GB/s (read_traces_into
 * with 1000-trace chunks into a caller buffer, best of 3, warm), random
 * single-trace latency p50/p99 (into a caller buffer, and as a new SegTensor),
 * a trace header listing p50, and one trace_field call p50. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include "parseseg.h"

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static double pct(double *xs, int n, double q) {
    qsort(xs, (size_t)n, sizeof *xs, cmp);
    int i = (int)(q * n + 0.999999) - 1;
    if (i < 0) i = 0;
    if (i >= n) i = n - 1;
    return xs[i];
}

static unsigned long long rng = 88172645463325252ULL;
static long long rnd(long long n) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return (long long)(rng % (unsigned long long)n);
}

#define CHECK(x) do { if ((x) < 0) { fprintf(stderr, "%s: %s\n", #x, seg_last_error()); exit(1); } } while (0)

static void bench(const char *path) {
    struct stat st;
    stat(path, &st);
    double size = (double)st.st_size;
    SegSeismicFile *f;
    CHECK(seg_open_seismic(path, false, false, &f));
    int64_t n, ns;
    CHECK(seg_seismic_file_len(f, &n));
    CHECK(seg_seismic_file_max_samples(f, &ns));
    const int64_t chunk = 1000;
    float *buf = malloc((size_t)(chunk * ns) * sizeof(float));
    SegTensorView v = { buf, SEG_DTYPE_FLOAT32, 2, { chunk, ns }, { ns, 1 } };
    double best = 1e30;
    for (int run = 0; run < 4; run++) { /* the first run maps the pages */
        double t0 = now();
        for (int64_t i = 0; i < n; i += chunk) {
            int64_t last = i + chunk - 1 < n - 1 ? i + chunk - 1 : n - 1;
            int64_t failed;
            CHECK(seg_seismic_file_read_traces_into_range(f, i, last, &v, 0, &failed));
        }
        double t = now() - t0;
        if (run > 0 && t < best) best = t;
    }
    enum { R = 20000 };
    static double xs[R];
    SegTensorView one = { buf, SEG_DTYPE_FLOAT32, 2, { 1, ns }, { ns, 1 } };
    for (int k = 0; k < R; k++) {
        int64_t i = rnd(n), failed;
        double t0 = now();
        CHECK(seg_seismic_file_read_traces_into_range(f, i, i, &one, 0, &failed));
        xs[k] = now() - t0;
    }
    double into50 = pct(xs, R, 0.5), into99 = pct(xs, R, 0.99);
    for (int k = 0; k < R; k++) {
        int64_t i = rnd(n);
        SegTensor *t;
        SegTensorView tv;
        double t0 = now();
        CHECK(seg_seismic_file_read_traces_range(f, i, i, SEG_DTYPE_FLOAT32, &t));
        CHECK(seg_tensor_view(t, &tv));
        seg_tensor_release(t);
        xs[k] = now() - t0;
    }
    double new50 = pct(xs, R, 0.5), new99 = pct(xs, R, 0.99);
    for (int k = 0; k < 5000; k++) {
        int64_t i = rnd(n);
        SegHeaderListing *l;
        double t0 = now();
        CHECK(seg_seismic_file_trace_headers(f, i, &l));
        seg_header_listing_release(l);
        xs[k] = now() - t0;
    }
    double list50 = pct(xs, 5000, 0.5);
    char name[64];
    const char *field = strstr(path, ".sgy") ? "trace.sourceX" : "ext1.receiverPointNumber";
    for (int k = 0; k < R; k++) {
        int64_t i = rnd(n);
        SegValue val;
        memset(&val, 0, sizeof val);
        val.text = name;
        val.text_cap = sizeof name;
        double t0 = now();
        CHECK(seg_seismic_file_trace_field(f, i, field, &val));
        xs[k] = now() - t0;
    }
    double field50 = pct(xs, R, 0.5);
    const char *base = strrchr(path, '/');
    printf("| %s | %.2f | %.2f / %.2f | %.2f / %.2f | %.2f | %.2f |\n", base ? base + 1 : path,
           size / best / 1e9, into50 * 1e6, into99 * 1e6, new50 * 1e6, new99 * 1e6,
           list50 * 1e6, field50 * 1e6);
    free(buf);
    seg_seismic_file_release(f);
}

int main(int argc, char **argv) {
    if (seg_init() != SEG_ABI_VERSION) {
        fprintf(stderr, "ABI version mismatch\n");
        return 1;
    }
    printf("| file | decode GB/s | single trace into µs p50 / p99 | single trace new tensor µs "
           "p50 / p99 | header listing µs p50 | trace_field µs p50 |\n");
    printf("| --- | ---: | ---: | ---: | ---: | ---: |\n");
    for (int i = 1; i < argc; i++) bench(argv[i]);
    return 0;
}
