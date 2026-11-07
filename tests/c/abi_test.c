/* C ABI test (task 8.4): every seg_* function through the shipped header.
 *
 *   abi_test <exampleFiles dir> <scratch dir>
 *
 * Built and run by tests/tcapi.nim. Exits non-zero on the first failure. */
#include "parseseg.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { \
    fprintf(stderr, "FAIL %s:%d: %s (last error: %s)\n", __FILE__, __LINE__, #cond, \
            seg_last_error()); failures++; } } while (0)
#define OK(call) CHECK((call) == SEG_OK)

static char dir[1024], tmp[1024];

static const char *path(const char *base, const char *name) {
    static char buf[4][2048];
    static int k = 0;
    k = (k + 1) % 4;
    snprintf(buf[k], sizeof buf[k], "%s/%s", base, name);
    return buf[k];
}

/* ---- layout: every struct and field against the library -------------- */
#define SIZE(T) CHECK(seg_sizeof(#T) == (int64_t)sizeof(T))
#define OFF(T, f) CHECK(seg_offsetof(#T, #f) == (int64_t)offsetof(T, f))

static void test_layout(void) {
    SIZE(SegTraceEntry); SIZE(SegTraceKeys); SIZE(SegTensorView); SIZE(SegValue);
    SIZE(SegGather); SIZE(SegDiagnostic); SIZE(SegChunk); SIZE(DLManagedTensor);
    SIZE(SegConvertOptions);
    OFF(SegConvertOptions, rev_major); OFF(SegConvertOptions, rev_minor);
    OFF(SegConvertOptions, byte_order); OFF(SegConvertOptions, format);
    OFF(SegConvertOptions, text_encoding); OFF(SegConvertOptions, apply_descale);
    OFF(SegConvertOptions, station_header);
    CHECK(sizeof(SegTraceEntry) == 24);
    OFF(SegTraceEntry, offset); OFF(SegTraceEntry, header_bytes); OFF(SegTraceEntry, num_samples);
    OFF(SegTraceEntry, record); OFF(SegTraceEntry, channel_set); OFF(SegTraceEntry, scan_type);
    OFF(SegTraceEntry, channel_type);
    OFF(SegTraceKeys, record); OFF(SegTraceKeys, ensemble); OFF(SegTraceKeys, offset);
    OFF(SegTraceKeys, src_line); OFF(SegTraceKeys, src_point); OFF(SegTraceKeys, src_x);
    OFF(SegTraceKeys, src_y); OFF(SegTraceKeys, rcv_line); OFF(SegTraceKeys, rcv_point);
    OFF(SegTraceKeys, rcv_x); OFF(SegTraceKeys, rcv_y); OFF(SegTraceKeys, src_z);
    OFF(SegTraceKeys, rcv_z); OFF(SegTraceKeys, cmp_x); OFF(SegTraceKeys, cmp_y);
    OFF(SegTraceKeys, src_index);
    OFF(SegTraceKeys, rcv_index); OFF(SegTraceKeys, depth_index);
    OFF(SegTraceKeys, reshoot_index); OFF(SegTraceKeys, sensor_type); OFF(SegTraceKeys, component);
    OFF(SegTensorView, data); OFF(SegTensorView, dtype); OFF(SegTensorView, rank);
    OFF(SegTensorView, shape); OFF(SegTensorView, strides);
    OFF(SegValue, kind); OFF(SegValue, i); OFF(SegValue, f); OFF(SegValue, text);
    OFF(SegGather, kind); OFF(SegGather, first); OFF(SegGather, count); OFF(SegGather, sources);
    OFF(SegGather, receivers);
    OFF(SegDiagnostic, severity); OFF(SegDiagnostic, code); OFF(SegDiagnostic, offset);
    OFF(SegDiagnostic, record); OFF(SegDiagnostic, channel_set); OFF(SegDiagnostic, trace);
    OFF(SegDiagnostic, block_index); OFF(SegDiagnostic, file); OFF(SegDiagnostic, field);
    OFF(SegDiagnostic, message); OFF(SegDiagnostic, code_name);
    OFF(SegChunk, first); OFF(SegChunk, count); OFF(SegChunk, failed); OFF(SegChunk, samples);
    OFF(DLManagedTensor, manager_ctx); OFF(DLManagedTensor, deleter);
    CHECK(seg_sizeof("NoSuchType") == -1 && seg_offsetof("SegValue", "nope") == -1);
}

/* ---- files, fields, logs --------------------------------------------- */
static void test_files(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), SEG_OPEN_KEYS, &f));
    CHECK(seg_file_kind(f) == SEG_KIND_SEGY);
    CHECK(seg_file_trace_count(f) == 200 && seg_file_record_count(f) == 1);
    CHECK(seg_file_max_samples(f) == 2001);
    CHECK(seg_file_sample_interval(f, 0) == 2000.0);
    CHECK(isnan(seg_file_sample_interval(f, 200)));
    SegTraceEntry e;
    OK(seg_file_trace_entry(f, 199, &e));
    CHECK(e.num_samples == 2001 && e.header_bytes == 240 && e.channel_set == 0xFFFF);
    CHECK(seg_file_trace_entry(f, 200, &e) == SEG_ERR_ARGUMENT && strlen(seg_last_error()) > 0);
    SegTraceKeys k;
    OK(seg_file_trace_keys(f, 0, &k));
    CHECK(k.ensemble == 1001001.0);
    SegValue v;
    OK(seg_trace_field(f, 5, "trace.sourceX", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 1704188);
    OK(seg_file_field(f, "binary.sampleInterval", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 2000);
    OK(seg_trace_field(f, 0, "trace.headerName", &v));
    CHECK(v.kind == SEG_VALUE_TEXT && v.text != NULL); /* may hold NUL bytes */
    CHECK(seg_trace_field(f, 0, "trace.nope", &v) == SEG_ERR_ARGUMENT);
    CHECK(strstr(seg_last_error(), "trace.nope") != NULL);
    CHECK(seg_record_field(f, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y */
    SegLog *log = seg_file_log(f);
    CHECK(seg_log_count(log) == 0 && seg_log_nif(log) != NULL);
    seg_log_release(log); /* borrowed: a no-op */
    CHECK(seg_log_count(seg_file_log(f)) == 0);
    seg_file_release(f);

    /* SEG-D: record fields, a log with entries. */
    OK(seg_file_open(path(dir, "63.sgd"), 0, &f));
    CHECK(seg_file_kind(f) == SEG_KIND_SEGD && seg_file_trace_count(f) == 1);
    OK(seg_record_field(f, 0, "gh3.sourcePointNumber", &v));
    CHECK(v.kind == SEG_VALUE_FLOAT && v.f == 99.5);
    OK(seg_trace_field(f, 0, "ext1.sensorType", &v));
    CHECK(v.i == 2);
    CHECK(seg_file_trace_keys(f, 0, &k) == SEG_ERR_STATE); /* no SEG_OPEN_KEYS */
    log = seg_file_log(f);
    CHECK(seg_log_count(log) == 2 && seg_log_count_severity(log, SEG_SEV_INFO) == 2);
    SegDiagnostic d;
    OK(seg_log_get(log, 0, &d));
    CHECK(d.severity == SEG_SEV_INFO && strcmp(d.code_name, "badValue") == 0);
    CHECK(d.offset == 83 && strstr(d.message, "source set") != NULL && strlen(d.file) > 0);
    CHECK(seg_log_get(log, 2, &d) == SEG_ERR_ARGUMENT);
    CHECK(strstr(seg_log_nif(log), "(diagnostics") != NULL);
    seg_file_release(f);

    /* Failures and junk. */
    CHECK(seg_file_open(path(dir, "no-such-file"), 0, &f) == SEG_ERR_IO && f == NULL);
    CHECK(seg_file_open(NULL, 0, &f) == SEG_ERR_ARGUMENT);
    FILE *j = fopen(path(tmp, "junk.bin"), "wb");
    for (int i = 0; i < 5000; i++) fputc(0, j);
    fclose(j);
    OK(seg_file_open(path(tmp, "junk.bin"), 0, &f));
    CHECK(seg_file_kind(f) == SEG_KIND_UNKNOWN && seg_file_trace_count(f) == 0);
    CHECK(seg_log_count_severity(seg_file_log(f), SEG_SEV_FATAL) == 1);
    seg_file_release(f);
    seg_file_release(NULL);
    CHECK(strcmp(seg_status_name(SEG_ERR_REFUSED), "SEG_ERR_REFUSED") == 0);
}

/* ---- reads and tensors ----------------------------------------------- */
static void dl_check(SegTensor *t, SegTensorView *v) {
    DLManagedTensor *m = seg_tensor_to_dlpack(t);
    CHECK(m != NULL);
    CHECK(m->dl_tensor.data == v->data && m->dl_tensor.ndim == 2);
    CHECK(m->dl_tensor.shape[0] == v->shape[0] && m->dl_tensor.strides[0] == v->strides[0]);
    CHECK(m->dl_tensor.dtype.code == 2 && m->dl_tensor.device.device_type == 1);
    seg_tensor_release(t); /* the DLPack tensor keeps the data alive */
    float probe = ((float *)m->dl_tensor.data)[0];
    (void)probe;
    m->deleter(m);
}

static void test_reads(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), 0, &f));
    SegTensor *t = NULL;
    OK(seg_read_range(f, 10, 5, SEG_F32, -1, &t));
    SegTensorView v;
    OK(seg_tensor_view(t, &v));
    CHECK(v.dtype == SEG_F32 && v.rank == 2 && v.shape[0] == 5 && v.shape[1] == 2001);
    CHECK(v.strides[0] == 2001 && v.strides[1] == 1);
    const float *a = (const float *)v.data;
    /* Into a caller buffer with a row stride: same samples. */
    float *buf = calloc(5 * 2100, sizeof(float));
    int64_t failed = -1;
    OK(seg_read_range_into(f, 10, 5, SEG_F32, buf, 2001, 2100, &failed));
    CHECK(failed == 0);
    int same = 1;
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 2001; c++)
            if (buf[r * 2100 + c] != a[r * 2001 + c]) same = 0;
    CHECK(same);
    /* A selection, in list order, as doubles. */
    int64_t sel[3] = {14, 10, 14};
    double *dbuf = calloc(3 * 2001, sizeof(double));
    OK(seg_read_selection_into(f, sel, 3, SEG_F64, dbuf, 2001, 2001, &failed));
    CHECK(dbuf[0] == (double)a[4 * 2001] && dbuf[2001 + 7] == (double)a[7]);
    SegTensor *t2 = NULL;
    OK(seg_read_selection(f, sel, 3, SEG_F64, 100, &t2));
    SegTensorView v2;
    OK(seg_tensor_view(t2, &v2));
    CHECK(v2.dtype == SEG_F64 && v2.shape[1] == 100 && ((double *)v2.data)[2 * 100 + 9] == dbuf[2 * 2001 + 9]);
    seg_tensor_release(t2);
    dl_check(t, &v);
    /* Bad arguments. */
    CHECK(seg_read_range(f, 199, 2, SEG_F32, -1, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_read_range(f, 0, 1, 7, -1, &t) == SEG_ERR_ARGUMENT);
    int64_t badsel[1] = {200};
    CHECK(seg_read_selection(f, badsel, 1, SEG_F32, -1, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_read_range_into(f, 0, 1, SEG_F32, buf, 10, 5, &failed) == SEG_ERR_ARGUMENT);
    CHECK(seg_read_range_into(f, 0, 1, SEG_F32, NULL, 10, 10, &failed) == SEG_ERR_ARGUMENT);
    free(buf);
    free(dbuf);
    seg_file_release(f);
}

/* ---- gathers, components, prefetch ----------------------------------- */
static void test_gathers_and_prefetch(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "inova_rev30_5traces.sgd"), SEG_OPEN_KEYS, &f));
    int64_t n = -1;
    OK(seg_file_gather_count(f, &n));
    CHECK(n == 1);
    SegGather g;
    OK(seg_file_gather(f, 0, &g));
    CHECK(g.kind == SEG_GATHER_SHOT && g.first == 0 && g.count == 5 && g.receivers == 2);
    SegTraceKeys k;
    OK(seg_file_trace_keys(f, 3, &k));
    CHECK(k.rcv_x == 1826232.375 && k.src_x == 1834704.375 && k.offset > 8000 && k.offset < 9000);
    CHECK(k.cmp_x == (k.src_x + k.rcv_x) / 2);
    int64_t group_of[5], groups = -1;
    OK(seg_component_groups(f, 0, 5, group_of, &groups));
    CHECK(groups == 2 && group_of[0] == -1 && group_of[3] == 0 && group_of[4] == 1);
    seg_file_release(f);

    /* External geometry: SEG-D 2.0 has no coordinates in its headers. */
    OK(seg_file_open(path(dir, "63.sgd"), SEG_OPEN_KEYS, &f));
    SegGeometry *geo = NULL;
    OK(seg_geometry_new(&geo));
    OK(seg_geometry_add_source(geo, 13, 99.5, 1, 1000, 2000, NAN));
    OK(seg_geometry_add_receiver(geo, 13, 104, 0, 1300, 2400, 7));
    CHECK(seg_geometry_add_receiver(geo, 1, 1, 70000, 0, 0, 0) == SEG_ERR_ARGUMENT);
    int64_t updated = -1;
    OK(seg_file_apply_geometry(f, geo, 0, &updated));
    CHECK(updated == 1);
    OK(seg_file_trace_keys(f, 0, &k));
    CHECK(k.offset == 500 && k.cmp_y == 2200 && k.rcv_z == 7 && isnan(k.src_z));
    seg_geometry_release(geo);
    seg_file_release(f);

    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), 0, &f));
    CHECK(seg_file_gather_count(f, &n) == SEG_ERR_STATE);
    SegTensor *all = NULL;
    OK(seg_read_range(f, 0, 200, SEG_F32, -1, &all));
    SegTensorView av;
    OK(seg_tensor_view(all, &av));
    const float *a = (const float *)av.data;
    SegPrefetch *p = NULL;
    OK(seg_prefetch_open(f, 0, -1, 32, 3, -1, SEG_F32, &p));
    seg_file_release(f); /* the prefetcher keeps the file alive */
    SegChunk c;
    int64_t pos = 0;
    SegStatus st;
    while ((st = seg_prefetch_next(p, &c)) == SEG_OK) {
        SegTensorView cv;
        OK(seg_tensor_view(c.samples, &cv));
        CHECK(c.first == pos && cv.shape[0] == c.count && c.failed == 0);
        CHECK(memcmp(cv.data, a + pos * 2001, (size_t)(c.count * 2001) * sizeof(float)) == 0);
        pos += c.count;
        seg_tensor_release(c.samples);
    }
    CHECK(st == SEG_END && pos == 200);
    CHECK(seg_prefetch_try_next(p, &c) == SEG_END);
    OK(seg_prefetch_seek(p, 150, 160));
    do { st = seg_prefetch_try_next(p, &c); } while (st == SEG_NOT_READY);
    CHECK(st == SEG_OK && c.first == 150 && c.count == 10);
    seg_tensor_release(c.samples);
    CHECK(seg_prefetch_seek(p, 10, 300) == SEG_ERR_ARGUMENT);
    CHECK(seg_prefetch_trace_at(p, 7) == 7 && seg_prefetch_trace_at(p, 200) == -1);
    seg_prefetch_release(p);
    seg_tensor_release(all);
}

/* ---- in-place edits and journals ------------------------------------- */
static long file_bytes(const char *p, unsigned char **out) {
    FILE *f = fopen(p, "rb");
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    *out = malloc((size_t)n);
    if (fread(*out, 1, (size_t)n, f) != (size_t)n) n = -1;
    fclose(f);
    return n;
}

static void test_edits(void) {
    unsigned char *orig, *now;
    long n = file_bytes(path(dir, "Sweep0.sgy"), &orig);
    const char *copy = path(tmp, "edit.sgy");
    const char *journal = path(tmp, "edit.sgy.nif");
    FILE *w = fopen(copy, "wb");
    fwrite(orig, 1, (size_t)n, w);
    fclose(w);
    remove(journal);
    SegEditor *e = NULL;
    OK(seg_editor_open(copy, journal, &e));
    SegValue v = {SEG_VALUE_INT, 0, -4242, 0, NULL};
    OK(seg_editor_set_trace(e, 0, "trace.sourceX", &v));
    v.i = 10;
    CHECK(seg_editor_set_trace(e, 0, "trace.numSamples", &v) == SEG_ERR_REFUSED);
    CHECK(strstr(seg_last_error(), "structure") != NULL);
    v.kind = SEG_VALUE_FLOAT; v.f = 1.5;
    CHECK(seg_editor_set_trace(e, 0, "trace.groupX", &v) == SEG_ERR_REFUSED);
    v.kind = SEG_VALUE_INT; v.i = 7;
    OK(seg_editor_set_file(e, "binary.jobId", &v));
    CHECK(seg_editor_set_record(e, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y: no records */
    CHECK(seg_editor_edits(e) == 2);
    CHECK(seg_log_count_severity(seg_editor_log(e), SEG_SEV_ERROR) == 2);
    OK(seg_editor_close(e));
    SegFile *f = NULL;
    OK(seg_file_open(copy, 0, &f));
    OK(seg_trace_field(f, 0, "trace.sourceX", &v));
    CHECK(v.i == -4242);
    seg_file_release(f);
    SegLog *log = NULL;
    OK(seg_journal_rollback(copy, journal, &log));
    CHECK(seg_log_count(log) == 0);
    seg_log_release(log);
    CHECK(file_bytes(copy, &now) == n && memcmp(now, orig, (size_t)n) == 0);
    free(now);
    OK(seg_journal_apply(copy, journal, NULL));
    CHECK(seg_journal_rollback(copy, path(tmp, "missing.nif"), NULL) == SEG_ERR_IO);
    free(orig);
}

/* ---- conversion ------------------------------------------------------ */
static void test_convert(void) {
    SegConvertOptions o;
    seg_convert_options_default(&o);
    CHECK(o.rev_major == 2 && o.rev_minor == 1 && o.byte_order == 0 && o.station_header == 1);
    SegLog *log = NULL;
    OK(seg_convert(path(dir, "inova_rev30_5traces.sgd"), path(tmp, "inova.sgy"), &o, &log));
    CHECK(seg_log_count_severity(log, SEG_SEV_ERROR) == 0 && seg_log_count(log) > 0);
    seg_log_release(log);
    SegFile *f = NULL;
    OK(seg_file_open(path(tmp, "inova.sgy"), 0, &f));
    CHECK(seg_file_kind(f) == SEG_KIND_SEGY && seg_file_trace_count(f) == 5);
    SegValue v;
    OK(seg_trace_field(f, 3, "ext1.extGroupX", &v));
    CHECK(v.kind == SEG_VALUE_FLOAT && v.f == 1826232.375);
    seg_file_release(f);
    o.rev_major = 1; o.rev_minor = 0; o.byte_order = 1; /* little-endian needs Rev 2 */
    CHECK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) == SEG_ERR_FORMAT);
    o.rev_major = 7;
    CHECK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) == SEG_ERR_ARGUMENT);
    OK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "sw.sgy"), NULL, NULL));
}

/* ---- review regressions (Phase 8) ----------------------------------- */
static void test_limits(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), 0, &f));
    SegTensor *t = (SegTensor *)1;
    /* r2: hostile sizes are refused, never fatal. */
    CHECK(seg_read_range(f, 0, 1, SEG_F32, (int64_t)1 << 42, &t) == SEG_ERR_ARGUMENT && t == NULL);
    CHECK(seg_read_range(f, 0, 2, SEG_F32, INT64_MAX, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_read_range(f, 0, 1, SEG_F32, -2, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_read_range(f, 0, INT64_MAX, SEG_F32, -1, &t) == SEG_ERR_ARGUMENT);
    float one[4];
    CHECK(seg_read_range_into(f, 0, 2, SEG_F32, one, 2, INT64_MAX / 2, NULL) == SEG_ERR_ARGUMENT);
    SegPrefetch *p = (SegPrefetch *)1;
    CHECK(seg_prefetch_open(f, 0, -1, 16, 4, (int64_t)1 << 40, SEG_F32, &p) == SEG_ERR_ARGUMENT);
    CHECK(p == NULL);
    CHECK(seg_prefetch_open(f, 0, -1, 1 << 24, 1024, 1 << 20, SEG_F64, &p) == SEG_ERR_ARGUMENT);
    /* A request under the limit but beyond memory: SEG_ERR_IO, the host lives on.
       In a child capped at 4 GiB of address space, so it is deterministic (not
       under sanitizers, whose shadow memory needs the address space). */
    if (!getenv("ASAN_OPTIONS") && !getenv("TSAN_OPTIONS")) {
        pid_t pid = fork();
        if (pid == 0) {
            struct rlimit lim = {(rlim_t)4 << 30, (rlim_t)4 << 30};
            setrlimit(RLIMIT_AS, &lim);
            SegTensor *big = NULL;
            SegStatus st = seg_read_range(f, 0, 1, SEG_F32, (int64_t)1 << 32, &big);
            _exit(st == SEG_ERR_IO && big == NULL ? 0 : 3);
        }
        int status = 0;
        waitpid(pid, &status, 0);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    /* r3: a huge selection count is refused before any allocation. */
    int64_t tr[1] = {999999};
    CHECK(seg_read_selection(f, tr, (int64_t)1 << 60, SEG_F32, -1, &t) == SEG_ERR_ARGUMENT);
    tr[0] = 5;
    CHECK(seg_read_selection(f, tr, -1, SEG_F32, -1, &t) == SEG_ERR_ARGUMENT);
    seg_file_release(f);
    /* Out-of-range editor indices are argument errors. */
    SegEditor *e = NULL;
    FILE *w = fopen(path(tmp, "lim.sgy"), "wb");
    unsigned char *b;
    long n = file_bytes(path(dir, "Sweep0.sgy"), &b);
    fwrite(b, 1, (size_t)n, w);
    fclose(w);
    free(b);
    remove(path(tmp, "lim.sgy.edits.nif"));
    OK(seg_editor_open(path(tmp, "lim.sgy"), NULL, &e));
    SegValue v = {SEG_VALUE_INT, 0, 1, 0, NULL};
    CHECK(seg_editor_set_trace(e, -1, "trace.sourceX", &v) == SEG_ERR_ARGUMENT);
    CHECK(seg_editor_set_trace(e, 1000000000, "trace.sourceX", &v) == SEG_ERR_ARGUMENT);
    CHECK(seg_editor_set_record(e, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y */
    OK(seg_editor_close(e));
}

static void *init_and_fail(void *arg) {
    (void)arg;
    CHECK(seg_init() == SEG_ABI_VERSION);
    SegFile *f = (SegFile *)1;
    CHECK(seg_file_open("/nonexistent/zz", 0, &f) == SEG_ERR_IO && f == NULL);
    CHECK(strlen(seg_last_error()) > 0);
    return NULL;
}

/* r1 / r4: concurrent seg_init (deadlocked), and error strings on threads
   that exit (leaked). Run first, before main's own seg_init. */
static void test_concurrent_init(void) {
    pthread_t th[8];
    for (int i = 0; i < 8; i++) pthread_create(&th[i], NULL, init_and_fail, NULL);
    for (int i = 0; i < 8; i++) pthread_join(th[i], NULL);
}

/* ---- host threads ---------------------------------------------------- */
static SegFile *shared_file;

static void *reader(void *arg) {
    int64_t id = (int64_t)(intptr_t)arg;
    float *buf = malloc(20 * 2001 * sizeof(float));
    for (int round = 0; round < 50; round++) {
        int64_t failed = 0;
        if (seg_read_range_into(shared_file, (id * 37 + round) % 180, 20, SEG_F32, buf, 2001,
                                2001, &failed) != SEG_OK || failed != 0) {
            fprintf(stderr, "thread %ld: read failed\n", (long)id);
            failures++;
        }
        SegTensor *t = NULL;
        if (seg_read_range(shared_file, round % 190, 10, SEG_F32, -1, &t) == SEG_OK) {
            DLManagedTensor *m = seg_tensor_to_dlpack(t);
            seg_tensor_release(t);
            m->deleter(m);
        } else failures++;
    }
    free(buf);
    return NULL;
}

static void test_threads(void) {
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), 0, &shared_file));
    pthread_t th[4];
    for (intptr_t i = 0; i < 4; i++) pthread_create(&th[i], NULL, reader, (void *)i);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    seg_file_release(shared_file);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: abi_test <exampleFiles> <scratch>\n"); return 2; }
    snprintf(dir, sizeof dir, "%s", argv[1]);
    snprintf(tmp, sizeof tmp, "%s", argv[2]);
    test_concurrent_init();
    CHECK(seg_init() == SEG_ABI_VERSION);
    CHECK(seg_init() == SEG_ABI_VERSION && seg_abi_version() == SEG_ABI_VERSION);
    CHECK(strcmp(seg_version(), "0.2.0") == 0);
    test_layout();
    test_files();
    test_reads();
    test_gathers_and_prefetch();
    test_edits();
    test_convert();
    test_limits();
    test_threads();
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf("abi_test: all checks passed\n");
    return 0;
}
