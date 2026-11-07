/* C ABI test (tasks 8.4, 12.2): every seg_* function through the generated
 * header (ABI version 2).
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

/* Small accessors for results that come back through out-pointers (-999 on
   failure). */
static int64_t trace_count(SegFile *f) {
    int64_t n = -1;
    return seg_file_trace_count(f, &n) == SEG_OK ? n : -999;
}

static int32_t kind_of(SegFile *f) {
    int32_t k = -1;
    return seg_file_kind(f, &k) == SEG_OK ? k : -999;
}

static int64_t log_count(SegLog *l) {
    int64_t n = -1;
    return seg_log_count(l, &n) == SEG_OK ? n : -999;
}

static int64_t log_count_sev(SegLog *l, int32_t sev) {
    int64_t n = -1;
    return seg_log_count_severity(l, sev, &n) == SEG_OK ? n : -999;
}

/* ---- layout: every struct and field against the library -------------- */
#define SIZE(T) CHECK(seg_sizeof(#T) == (int64_t)sizeof(T))
#define OFF(T, f) CHECK(seg_offsetof(#T, #f) == (int64_t)offsetof(T, f))

static void test_layout(void) {
    SIZE(SegTraceEntry); SIZE(SegTraceKeys); SIZE(SegTensorView); SIZE(SegValue);
    SIZE(SegGather); SIZE(SegDiagnostic); SIZE(SegChunk); SIZE(DLManagedTensor);
    SIZE(SegSampleBuffer); SIZE(SegSurveyCounts);
    CHECK(sizeof(SegTraceEntry) == 24);
    OFF(SegTraceEntry, offset); OFF(SegTraceEntry, header_bytes); OFF(SegTraceEntry, num_samples);
    OFF(SegTraceEntry, record); OFF(SegTraceEntry, channel_set); OFF(SegTraceEntry, scan_type);
    OFF(SegTraceEntry, channel_type);
    OFF(SegTraceKeys, record); OFF(SegTraceKeys, ensemble); OFF(SegTraceKeys, offset);
    OFF(SegTraceKeys, src_line); OFF(SegTraceKeys, src_point); OFF(SegTraceKeys, src_x);
    OFF(SegTraceKeys, src_y); OFF(SegTraceKeys, rcv_line); OFF(SegTraceKeys, rcv_point);
    OFF(SegTraceKeys, rcv_x); OFF(SegTraceKeys, rcv_y); OFF(SegTraceKeys, src_z);
    OFF(SegTraceKeys, rcv_z); OFF(SegTraceKeys, cmp_x); OFF(SegTraceKeys, cmp_y);
    OFF(SegTraceKeys, src_index); OFF(SegTraceKeys, rcv_index); OFF(SegTraceKeys, depth_index);
    OFF(SegTraceKeys, reshoot_index); OFF(SegTraceKeys, sensor_type); OFF(SegTraceKeys, component);
    OFF(SegTraceKeys, channel);
    OFF(SegTensorView, data); OFF(SegTensorView, dtype); OFF(SegTensorView, rank);
    OFF(SegTensorView, shape); OFF(SegTensorView, strides);
    OFF(SegValue, kind); OFF(SegValue, i); OFF(SegValue, f); OFF(SegValue, text);
    OFF(SegValue, text_cap); OFF(SegValue, text_len);
    OFF(SegGather, kind); OFF(SegGather, first); OFF(SegGather, count); OFF(SegGather, sources);
    OFF(SegGather, receivers);
    OFF(SegDiagnostic, severity); OFF(SegDiagnostic, code); OFF(SegDiagnostic, offset);
    OFF(SegDiagnostic, record); OFF(SegDiagnostic, channel_set); OFF(SegDiagnostic, trace);
    OFF(SegDiagnostic, block_index); OFF(SegDiagnostic, file); OFF(SegDiagnostic, field);
    OFF(SegDiagnostic, message);
    OFF(SegChunk, first); OFF(SegChunk, count); OFF(SegChunk, failed); OFF(SegChunk, samples);
    OFF(SegSampleBuffer, data); OFF(SegSampleBuffer, dtype); OFF(SegSampleBuffer, rows);
    OFF(SegSampleBuffer, cols); OFF(SegSampleBuffer, row_stride);
    OFF(SegSurveyCounts, sources); OFF(SegSurveyCounts, receivers);
    OFF(SegSurveyCounts, relations);
    OFF(DLManagedTensor, manager_ctx); OFF(DLManagedTensor, deleter);
    CHECK(seg_sizeof("NoSuchType") == -1 && seg_offsetof("SegValue", "nope") == -1);
}

/* ---- files, fields, logs --------------------------------------------- */
static void test_files(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), true, false, &f));
    CHECK(kind_of(f) == SEG_KIND_SEGY && trace_count(f) == 200);
    int64_t n = -1;
    OK(seg_file_record_count(f, &n));
    CHECK(n == 1);
    OK(seg_file_max_samples(f, &n));
    CHECK(n == 2001);
    double si = 0;
    OK(seg_file_sample_interval(f, 0, &si));
    CHECK(si == 2000.0);
    OK(seg_file_sample_interval(f, 200, &si));
    CHECK(isnan(si));
    SegTraceEntry e;
    OK(seg_file_trace_entry(f, 199, &e));
    CHECK(e.num_samples == 2001 && e.header_bytes == 240 && e.channel_set == 0xFFFF);
    CHECK(seg_file_trace_entry(f, 200, &e) == SEG_ERR_ARGUMENT && strlen(seg_last_error()) > 0);
    SegTraceKeys k;
    OK(seg_file_trace_keys(f, 0, &k));
    CHECK(k.ensemble == 1001001.0);
    SegValue v;
    OK(seg_file_trace_field(f, 5, "trace.sourceX", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 1704188);
    OK(seg_file_file_field(f, "binary.sampleInterval", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 2000);
    /* Text: into the caller's buffer, with its full length; too small is truncated. */
    char text[256];
    v.text = text;
    v.text_cap = sizeof text;
    OK(seg_file_trace_field(f, 0, "trace.headerName", &v));
    CHECK(v.kind == SEG_VALUE_TEXT && v.text_len >= 0 && v.text_len < 256);
    v.text_cap = 1;
    OK(seg_file_trace_field(f, 0, "trace.headerName", &v));
    CHECK(text[0] == '\0');
    v.text = NULL;
    v.text_cap = 0;
    CHECK(seg_file_trace_field(f, 0, "trace.nope", &v) == SEG_ERR_ARGUMENT);
    CHECK(strstr(seg_last_error(), "trace.nope") != NULL);
    CHECK(seg_file_record_field(f, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y */
    CHECK(seg_file_trace_field(f, 0, NULL, &v) == SEG_ERR_ARGUMENT);
    SegLog *log = NULL;
    OK(seg_file_diagnostics(f, &log));
    CHECK(log_count(log) == 0);
    int64_t len = -1;
    OK(seg_log_nif(log, NULL, 0, &len));
    CHECK(len > 0);
    seg_log_release(log);
    seg_file_release(f);

    /* SEG-D: record fields, a log with entries. */
    OK(seg_file_open(path(dir, "63.sgd"), false, false, &f));
    CHECK(kind_of(f) == SEG_KIND_SEGD && trace_count(f) == 1);
    OK(seg_file_record_field(f, 0, "gh3.sourcePointNumber", &v));
    CHECK(v.kind == SEG_VALUE_FLOAT && v.f == 99.5);
    OK(seg_file_trace_field(f, 0, "ext1.sensorType", &v));
    CHECK(v.i == 2);
    CHECK(seg_file_trace_keys(f, 0, &k) == SEG_ERR_STATE); /* opened without keys */
    OK(seg_file_diagnostics(f, &log));
    CHECK(log_count(log) == 2 && log_count_sev(log, SEG_SEVERITY_INFO) == 2);
    SegDiagnostic d;
    OK(seg_log_get(log, 0, &d));
    CHECK(d.severity == SEG_SEVERITY_INFO && d.code == SEG_CODE_BAD_VALUE);
    CHECK(d.offset == 83 && strstr(d.message, "source set") != NULL && strlen(d.file) > 0);
    CHECK(seg_log_get(log, 2, &d) == SEG_ERR_ARGUMENT);
    char *nif = malloc(65536);
    OK(seg_log_nif(log, nif, 65536, &len));
    CHECK(len < 65536 && strstr(nif, "(diagnostics") != NULL);
    free(nif);
    CHECK(log_count_sev(log, 9) == -999); /* not a severity */
    seg_log_release(log);
    seg_file_release(f);

    /* Failures and junk. */
    f = (SegFile *)1;
    CHECK(seg_file_open(path(dir, "no-such-file"), false, false, &f) == SEG_ERR_IO && f == NULL);
    CHECK(seg_file_open(NULL, false, false, &f) == SEG_ERR_ARGUMENT);
    FILE *j = fopen(path(tmp, "junk.bin"), "wb");
    for (int i = 0; i < 5000; i++) fputc(0, j);
    fclose(j);
    OK(seg_file_open(path(tmp, "junk.bin"), false, false, &f));
    CHECK(kind_of(f) == SEG_KIND_UNKNOWN && trace_count(f) == 0);
    OK(seg_file_diagnostics(f, &log));
    CHECK(log_count_sev(log, SEG_SEVERITY_FATAL) == 1);
    seg_log_release(log);
    seg_file_release(f);
    seg_file_release(NULL);
    CHECK(seg_file_trace_count(NULL, &n) == SEG_ERR_ARGUMENT);
    char name[32];
    OK(seg_status_name(SEG_ERR_REFUSED, name, sizeof name, &len));
    CHECK(strcmp(name, "SEG_ERR_REFUSED") == 0 && len == 15);
    OK(seg_status_name(SEG_ERR_MEMORY, name, 4, &len));
    CHECK(strcmp(name, "SEG") == 0 && len == 14); /* truncated, full length reported */
}

/* ---- reads and tensors ----------------------------------------------- */
static void dl_check(SegTensor *t, SegTensorView *v) {
    DLManagedTensor *m = NULL;
    OK(seg_tensor_to_dlpack(t, (void **)&m));
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
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), false, false, &f));
    SegTensor *t = NULL;
    OK(seg_file_read(f, 10, 5, SEG_DTYPE_FLOAT32, -1, &t));
    SegTensorView v;
    OK(seg_tensor_view(t, &v));
    CHECK(v.dtype == SEG_DTYPE_FLOAT32 && v.rank == 2 && v.shape[0] == 5 && v.shape[1] == 2001);
    CHECK(v.strides[0] == 2001 && v.strides[1] == 1);
    int32_t dt = 0;
    OK(seg_tensor_dtype(t, &dt));
    CHECK(dt == SEG_DTYPE_FLOAT32);
    const float *a = (const float *)v.data;
    /* Into a caller buffer with a row stride: same samples. */
    float *buf = calloc(5 * 2100, sizeof(float));
    SegSampleBuffer b = {buf, SEG_DTYPE_FLOAT32, 5, 2001, 2100};
    int64_t failed = -1;
    OK(seg_file_read_into(f, &b, 10, &failed));
    CHECK(failed == 0);
    int same = 1;
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 2001; c++)
            if (buf[r * 2100 + c] != a[r * 2001 + c]) same = 0;
    CHECK(same);
    /* A selection, in list order, as doubles. */
    int64_t sel[3] = {14, 10, 14};
    double *dbuf = calloc(3 * 2001, sizeof(double));
    SegSampleBuffer db = {dbuf, SEG_DTYPE_FLOAT64, 3, 2001, 2001};
    OK(seg_file_read_traces_into(f, &db, sel, 3, &failed));
    CHECK(dbuf[0] == (double)a[4 * 2001] && dbuf[2001 + 7] == (double)a[7]);
    SegTensor *t2 = NULL;
    OK(seg_file_read_traces(f, sel, 3, SEG_DTYPE_FLOAT64, 100, &t2));
    SegTensorView v2;
    OK(seg_tensor_view(t2, &v2));
    CHECK(v2.dtype == SEG_DTYPE_FLOAT64 && v2.shape[1] == 100 &&
          ((double *)v2.data)[2 * 100 + 9] == dbuf[2 * 2001 + 9]);
    seg_tensor_release(t2);
    dl_check(t, &v);
    /* Count -1: to the end. */
    OK(seg_file_read(f, 198, -1, SEG_DTYPE_FLOAT32, -1, &t));
    OK(seg_tensor_view(t, &v));
    CHECK(v.shape[0] == 2);
    seg_tensor_release(t);
    /* Bad arguments. */
    CHECK(seg_file_read(f, 199, 2, SEG_DTYPE_FLOAT32, -1, &t) == SEG_ERR_ARGUMENT && t == NULL);
    CHECK(seg_file_read(f, 0, 1, 7, -1, &t) == SEG_ERR_ARGUMENT);
    int64_t badsel[1] = {200};
    CHECK(seg_file_read_traces(f, badsel, 1, SEG_DTYPE_FLOAT32, -1, &t) == SEG_ERR_ARGUMENT);
    SegSampleBuffer bad = {buf, SEG_DTYPE_FLOAT32, 1, 10, 5};
    CHECK(seg_file_read_into(f, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    bad.data = NULL;
    bad.row_stride = 10;
    CHECK(seg_file_read_into(f, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    bad.data = buf;
    bad.dtype = 9;
    CHECK(seg_file_read_into(f, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    CHECK(seg_file_read_traces_into(f, &db, sel, 2, &failed) == SEG_ERR_ARGUMENT); /* rows != n */
    free(buf);
    free(dbuf);
    seg_file_release(f);
}

/* ---- gathers, components, prefetch ----------------------------------- */
static void test_gathers_and_prefetch(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "inova_rev30_5traces.sgd"), true, false, &f));
    int64_t n = -1;
    OK(seg_file_gathers(f, NULL, 0, &n));
    CHECK(n == 1);
    SegGather g;
    OK(seg_file_gathers(f, &g, 1, &n));
    CHECK(g.kind == SEG_GATHER_SHOT && g.first == 0 && g.count == 5 && g.receivers == 2);
    SegTraceKeys k;
    OK(seg_file_trace_keys(f, 3, &k));
    CHECK(k.rcv_x == 1826232.375 && k.src_x == 1834704.375 && k.offset > 8000 && k.offset < 9000);
    CHECK(k.cmp_x == (k.src_x + k.rcv_x) / 2);
    int64_t group_of[5];
    OK(seg_file_component_groups(f, 0, 5, group_of, 5, &n));
    CHECK(n == 5 && group_of[0] == -1 && group_of[3] == 0 && group_of[4] == 1);
    seg_file_release(f);

    /* External geometry: SEG-D 2.0 has no coordinates in its headers. */
    OK(seg_file_open(path(dir, "63.sgd"), true, false, &f));
    SegGeometry *geo = NULL;
    OK(seg_geometry_new(&geo));
    OK(seg_geometry_add_source(geo, 13, 99.5, 1, 1000, 2000, NAN));
    OK(seg_geometry_add_receiver(geo, 13, 104, 0, 1300, 2400, 7));
    CHECK(seg_geometry_add_receiver(geo, 1, 1, 70000, 0, 0, 0) == SEG_ERR_ARGUMENT);
    int64_t updated = -1;
    OK(seg_file_apply_geometry(f, geo, false, &updated));
    CHECK(updated == 1);
    OK(seg_file_trace_keys(f, 0, &k));
    CHECK(k.offset == 500 && k.cmp_y == 2200 && k.rcv_z == 7 && isnan(k.src_z));
    CHECK(k.record == 63 && k.channel == 1);
    seg_geometry_release(geo);

    /* Survey files: an SPS relation (record 63, channel 1) names the stations. */
    const char *sps_text =
        "H00 SPS format version number   SPS 2.1;\n"
        "R     10.00    101.00  1G1                     500100.0 6000000.0  12.5 18213250\n"
        "S     20.00    205.00  1V6                     500000.0 6000400.0  10.0 19001150\n"
        "XT1          6311     20.00    205.001    1    11     10.00    101.00    101.001\n";
    FILE *fh = fopen(path(tmp, "t.sps"), "w");
    fputs(sps_text, fh);
    fclose(fh);
    OK(seg_geometry_new(&geo));
    SegLog *slog = NULL;
    OK(seg_geometry_load_sps(geo, path(tmp, "t.sps"), &slog));
    CHECK(slog != NULL && log_count(slog) == 0);
    seg_log_release(slog);
    SegSurveyCounts counts;
    OK(seg_geometry_counts(geo, &counts));
    CHECK(counts.sources == 1 && counts.receivers == 1 && counts.relations == 1);
    CHECK(seg_geometry_load_sps(geo, path(tmp, "missing.sps"), NULL) == SEG_ERR_IO);
    OK(seg_geometry_set_options(geo, true, false));
    OK(seg_geometry_map_line(geo, "LINE A", 7));
    CHECK(seg_geometry_map_line(geo, "", 7) == SEG_ERR_ARGUMENT);
    OK(seg_file_apply_geometry(f, geo, true, &updated));
    CHECK(updated == 1);
    OK(seg_file_trace_keys(f, 0, &k));
    CHECK(k.src_point == 205 && k.rcv_point == 101 && k.rcv_x == 500100 && k.offset > 412.3 &&
          k.offset < 412.4);
    seg_geometry_release(geo);
    seg_file_release(f);

    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), false, false, &f));
    CHECK(seg_file_gathers(f, NULL, 0, &n) == SEG_ERR_STATE);
    SegTensor *all = NULL;
    OK(seg_file_read(f, 0, 200, SEG_DTYPE_FLOAT32, -1, &all));
    SegTensorView av;
    OK(seg_tensor_view(all, &av));
    const float *a = (const float *)av.data;
    SegPrefetch *p = NULL;
    OK(seg_file_prefetch(f, 0, -1, 32, 3, -1, SEG_DTYPE_FLOAT32, &p));
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
    bool end = false;
    OK(seg_prefetch_at_end(p, &end));
    CHECK(end);
    CHECK(seg_prefetch_try_next(p, &c) == SEG_END);
    OK(seg_prefetch_seek(p, 150, 160));
    do { st = seg_prefetch_try_next(p, &c); } while (st == SEG_NOT_READY);
    CHECK(st == SEG_OK && c.first == 150 && c.count == 10);
    seg_tensor_release(c.samples);
    CHECK(seg_prefetch_seek(p, 10, 300) == SEG_ERR_ARGUMENT);
    int64_t at = 0;
    OK(seg_prefetch_trace_at(p, 7, &at));
    CHECK(at == 7);
    OK(seg_prefetch_trace_at(p, 200, &at));
    CHECK(at == -1);
    OK(seg_prefetch_positions(p, &n));
    CHECK(n == 200);
    OK(seg_prefetch_close(p));
    seg_prefetch_release(p);
    /* A selection prefetcher: positions index the list. */
    int64_t sel[3] = {5, 3, 1};
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), false, false, &f));
    OK(seg_file_prefetch_traces(f, sel, 3, 2, 2, -1, SEG_DTYPE_FLOAT64, &p));
    OK(seg_prefetch_trace_at(p, 0, &at));
    CHECK(at == 5);
    OK(seg_prefetch_next(p, &c));
    CHECK(c.first == 0 && c.count == 2);
    seg_tensor_release(c.samples);
    seg_prefetch_release(p); /* joins the worker */
    seg_file_release(f);
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
    SegValue v = {SEG_VALUE_INT, 0, -4242, 0, NULL, 0, 0};
    OK(seg_editor_set_trace(e, 0, "trace.sourceX", &v));
    v.i = 10;
    CHECK(seg_editor_set_trace(e, 0, "trace.numSamples", &v) == SEG_ERR_REFUSED);
    CHECK(strstr(seg_last_error(), "structure") != NULL);
    v.kind = SEG_VALUE_FLOAT; v.f = 1.5;
    CHECK(seg_editor_set_trace(e, 0, "trace.groupX", &v) == SEG_ERR_REFUSED);
    v.kind = SEG_VALUE_INT; v.i = 7;
    OK(seg_editor_set_file(e, "binary.jobId", &v));
    CHECK(seg_editor_set_record(e, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y: no records */
    v.kind = 9;
    CHECK(seg_editor_set_file(e, "binary.jobId", &v) == SEG_ERR_ARGUMENT);
    int64_t edits = -1;
    OK(seg_editor_edits(e, &edits));
    CHECK(edits == 2);
    SegLog *log = NULL;
    OK(seg_editor_diagnostics(e, &log));
    CHECK(log_count_sev(log, SEG_SEVERITY_ERROR) == 2);
    seg_log_release(log);
    OK(seg_editor_close(e));
    seg_editor_release(e);
    SegFile *f = NULL;
    OK(seg_file_open(copy, false, false, &f));
    v.kind = 0;
    OK(seg_file_trace_field(f, 0, "trace.sourceX", &v));
    CHECK(v.i == -4242);
    seg_file_release(f);
    log = NULL;
    OK(seg_journal_rollback(copy, journal, &log));
    CHECK(log_count(log) == 0);
    seg_log_release(log);
    CHECK(file_bytes(copy, &now) == n && memcmp(now, orig, (size_t)n) == 0);
    free(now);
    OK(seg_journal_apply(copy, journal, NULL));
    log = NULL;
    CHECK(seg_journal_rollback(copy, path(tmp, "missing.nif"), &log) == SEG_ERR_IO);
    CHECK(log != NULL && log_count_sev(log, SEG_SEVERITY_FATAL) == 1); /* the failure's log */
    seg_log_release(log);
    free(orig);
}

/* ---- conversion ------------------------------------------------------ */
static void test_convert(void) {
    SegLog *log = NULL;
    OK(seg_convert(path(dir, "inova_rev30_5traces.sgd"), path(tmp, "inova.sgy"), "2.1",
                   SEG_BYTE_ORDER_BIG, 0, SEG_TEXT_EBCDIC, false, true, &log));
    CHECK(log_count_sev(log, SEG_SEVERITY_ERROR) == 0 && log_count(log) > 0);
    seg_log_release(log);
    SegFile *f = NULL;
    OK(seg_file_open(path(tmp, "inova.sgy"), false, false, &f));
    CHECK(kind_of(f) == SEG_KIND_SEGY && trace_count(f) == 5);
    SegValue v;
    OK(seg_file_trace_field(f, 3, "ext1.extGroupX", &v));
    CHECK(v.kind == SEG_VALUE_FLOAT && v.f == 1826232.375);
    seg_file_release(f);
    /* Little-endian needs Rev 2: the failure hands its log out. */
    log = NULL;
    CHECK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), "1", SEG_BYTE_ORDER_LITTLE, 0,
                      SEG_TEXT_EBCDIC, false, true, &log) == SEG_ERR_FORMAT);
    CHECK(log != NULL && log_count_sev(log, SEG_SEVERITY_FATAL) == 1);
    seg_log_release(log);
    CHECK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), "7", 0, 0, 0, false, true,
                      NULL) == SEG_ERR_ARGUMENT);
    CHECK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), "2.1", 5, 0, 0, false, true,
                      NULL) == SEG_ERR_ARGUMENT); /* no such byte order */
    OK(seg_convert(path(dir, "Sweep0.sgy"), path(tmp, "sw.sgy"), NULL, 0, 0, 0, false, true,
                   NULL)); /* NULL revision: the default */
    /* SEG-D revisions (task 8.7). */
    SegLog *slog = NULL;
    OK(seg_convert_segd(path(dir, "63.sgd"), path(tmp, "63_r3.sgd"), "3.0", 0, &slog));
    CHECK(slog != NULL && log_count(slog) > 0 && log_count_sev(slog, SEG_SEVERITY_FATAL) == 0);
    seg_log_release(slog);
    OK(seg_file_open(path(tmp, "63_r3.sgd"), false, false, &f));
    CHECK(kind_of(f) == SEG_KIND_SEGD && trace_count(f) == 1);
    OK(seg_file_record_field(f, 0, "gh1.formatCode", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 8058);
    seg_file_release(f);
    OK(seg_convert_segd(path(tmp, "63_r3.sgd"), path(tmp, "63_r2.sgd"), "2.1", 0, NULL));
    slog = NULL;
    CHECK(seg_convert_segd(path(dir, "63.sgd"), path(tmp, "x.sgd"), "1.0", 0, &slog) ==
          SEG_ERR_FORMAT && slog != NULL && log_count_sev(slog, SEG_SEVERITY_FATAL) == 1);
    seg_log_release(slog);
    CHECK(seg_convert_segd(path(dir, "63.sgd"), path(tmp, "x.sgd"), "2.1", 8080, NULL) ==
          SEG_ERR_FORMAT);
    CHECK(seg_convert_segd(path(dir, "63.sgd"), path(tmp, "x.sgd"), "3.0", -1, NULL) ==
          SEG_ERR_ARGUMENT);
    CHECK(seg_convert_segd(path(dir, "63.sgd"), path(tmp, "x.sgd"), "3", 0, NULL) ==
          SEG_ERR_ARGUMENT);
    CHECK(seg_convert_segd(NULL, path(tmp, "x.sgd"), "3.0", 0, NULL) == SEG_ERR_ARGUMENT);
}

/* ---- review regressions (Phase 8) ----------------------------------- */
static void test_limits(void) {
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), false, false, &f));
    SegTensor *t = (SegTensor *)1;
    /* Hostile sizes are refused, never fatal. */
    CHECK(seg_file_read(f, 0, 1, SEG_DTYPE_FLOAT32, (int64_t)1 << 42, &t) == SEG_ERR_ARGUMENT &&
          t == NULL);
    CHECK(seg_file_read(f, 0, 2, SEG_DTYPE_FLOAT32, INT64_MAX, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_file_read(f, 0, 1, SEG_DTYPE_FLOAT32, -2, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_file_read(f, 0, INT64_MAX, SEG_DTYPE_FLOAT32, -1, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_file_read(f, 0, -2, SEG_DTYPE_FLOAT32, -1, &t) == SEG_ERR_ARGUMENT);
    float one[4];
    SegSampleBuffer b = {one, SEG_DTYPE_FLOAT32, 2, 2, INT64_MAX / 2};
    CHECK(seg_file_read_into(f, &b, 0, NULL) == SEG_ERR_ARGUMENT);
    SegPrefetch *p = (SegPrefetch *)1;
    CHECK(seg_file_prefetch(f, 0, -1, 16, 4, (int64_t)1 << 40, SEG_DTYPE_FLOAT32, &p) ==
          SEG_ERR_ARGUMENT);
    CHECK(p == NULL);
    CHECK(seg_file_prefetch(f, 0, -1, 1 << 24, 1024, 1 << 20, SEG_DTYPE_FLOAT64, &p) ==
          SEG_ERR_ARGUMENT);
    /* A request under the limit but beyond memory: SEG_ERR_MEMORY, the host lives
       on. In a child capped at 4 GiB of address space, so it is deterministic
       (not under sanitizers, whose shadow memory needs the address space). */
    if (!getenv("ASAN_OPTIONS") && !getenv("TSAN_OPTIONS")) {
        pid_t pid = fork();
        if (pid == 0) {
            struct rlimit lim = {(rlim_t)4 << 30, (rlim_t)4 << 30};
            setrlimit(RLIMIT_AS, &lim);
            SegTensor *big = NULL;
            SegStatus st = seg_file_read(f, 0, 1, SEG_DTYPE_FLOAT32, (int64_t)1 << 32, &big);
            _exit(st == SEG_ERR_MEMORY && big == NULL ? 0 : 3);
        }
        int status = 0;
        waitpid(pid, &status, 0);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    /* A huge selection count is refused before any allocation. */
    int64_t tr[1] = {999999};
    CHECK(seg_file_read_traces(f, tr, (int64_t)1 << 60, SEG_DTYPE_FLOAT32, -1, &t) ==
          SEG_ERR_ARGUMENT);
    tr[0] = 5;
    CHECK(seg_file_read_traces(f, tr, -1, SEG_DTYPE_FLOAT32, -1, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_file_read_traces(f, NULL, 1, SEG_DTYPE_FLOAT32, -1, &t) == SEG_ERR_ARGUMENT);
    OK(seg_file_read_traces(f, NULL, 0, SEG_DTYPE_FLOAT32, -1, &t)); /* empty selection */
    seg_tensor_release(t);
    /* Too-small out buffers: the full length still comes back. */
    int64_t len = -1;
    CHECK(seg_file_component_groups(f, 0, 2, NULL, -1, &len) == SEG_ERR_STATE); /* no keys */
    seg_file_release(f);
    /* Out-of-range editor indices are argument errors. */
    SegEditor *e = NULL;
    FILE *w = fopen(path(tmp, "lim.sgy"), "wb");
    unsigned char *bytes;
    long n = file_bytes(path(dir, "Sweep0.sgy"), &bytes);
    fwrite(bytes, 1, (size_t)n, w);
    fclose(w);
    free(bytes);
    remove(path(tmp, "lim.sgy.edits.nif"));
    OK(seg_editor_open(path(tmp, "lim.sgy"), NULL, &e));
    SegValue v = {SEG_VALUE_INT, 0, 1, 0, NULL, 0, 0};
    CHECK(seg_editor_set_trace(e, -1, "trace.sourceX", &v) == SEG_ERR_ARGUMENT);
    CHECK(seg_editor_set_trace(e, 1000000000, "trace.sourceX", &v) == SEG_ERR_ARGUMENT);
    CHECK(seg_editor_set_record(e, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y */
    CHECK(seg_editor_set_trace(e, 0, "trace.sourceX", NULL) == SEG_ERR_ARGUMENT);
    OK(seg_editor_close(e));
    seg_editor_release(e);
}

static void *init_and_fail(void *arg) {
    (void)arg;
    CHECK(seg_init() == SEG_ABI_VERSION);
    SegFile *f = (SegFile *)1;
    CHECK(seg_file_open("/nonexistent/zz", false, false, &f) == SEG_ERR_IO && f == NULL);
    CHECK(strlen(seg_last_error()) > 0);
    return NULL;
}

/* Concurrent seg_init (once deadlocked), and error strings on threads that
   exit (once leaked). Run first, before main's own seg_init. */
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
    SegSampleBuffer b = {buf, SEG_DTYPE_FLOAT32, 20, 2001, 2001};
    for (int round = 0; round < 50; round++) {
        int64_t failed = 0;
        if (seg_file_read_into(shared_file, &b, (id * 37 + round) % 180, &failed) != SEG_OK ||
            failed != 0) {
            fprintf(stderr, "thread %ld: read failed\n", (long)id);
            failures++;
        }
        SegTensor *t = NULL;
        if (seg_file_read(shared_file, round % 190, 10, SEG_DTYPE_FLOAT32, -1, &t) == SEG_OK) {
            DLManagedTensor *m = NULL;
            if (seg_tensor_to_dlpack(t, (void **)&m) != SEG_OK) failures++;
            seg_tensor_release(t);
            if (m) m->deleter(m);
        } else failures++;
        /* Serialized calls on the same handle from every thread. */
        SegValue v;
        if (seg_file_trace_field(shared_file, round % 200, "trace.sourceX", &v) !=
            SEG_OK) failures++;
        int64_t ng = -1;
        if (seg_file_gathers(shared_file, NULL, 0, &ng) != SEG_OK || ng < 1) failures++;
    }
    free(buf);
    return NULL;
}

static void test_threads(void) {
    OK(seg_file_open(path(dir, "BO_3D-Inglewood_rev21_v7.sgy"), true, false, &shared_file));
    pthread_t th[4];
    for (intptr_t i = 0; i < 4; i++) pthread_create(&th[i], NULL, reader, (void *)i);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    seg_file_release(shared_file);
}

/* Mappings of `name` in this process (Linux), or -1 if unknown. */
static int maps_of(const char *name) {
    FILE *m = fopen("/proc/self/maps", "r");
    if (m == NULL) return -1;
    char line[4096];
    int n = 0;
    while (fgets(line, sizeof line, m)) {
        if (strstr(line, name) != NULL) n++;
    }
    fclose(m);
    return n;
}

/* ---- Phase 8 review regressions (2) ---------------------------------- */
static void test_release_unmaps(void) {
    /* Released files used to keep their mapping forever. */
    const char *name = "Sweep0.sgy";
    int before = maps_of(name);
    for (int i = 0; i < 25; i++) {
        SegFile *f = NULL;
        OK(seg_file_open(path(dir, name), true, false, &f));
        seg_file_release(f);
    }
    if (before >= 0) CHECK(maps_of(name) == before);
    /* first + count overflowed into SEG_ERR_INTERNAL. */
    SegFile *f = NULL;
    OK(seg_file_open(path(dir, "inova_rev30_5traces.sgd"), true, false, &f));
    int64_t g[1], len = 0;
    CHECK(seg_file_component_groups(f, 5, INT64_MAX, g, 1, &len) == SEG_ERR_ARGUMENT);
    CHECK(seg_file_component_groups(f, 0, (int64_t)1 << 40, g, 1, &len) == SEG_ERR_ARGUMENT);
    SegValue v;
    CHECK(seg_file_trace_field(f, 1000000, "trace.traceNumber", &v) == SEG_ERR_ARGUMENT &&
          strstr(seg_last_error(), "no trace") != NULL);
    seg_file_release(f);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: abi_test <exampleFiles> <scratch>\n"); return 2; }
    snprintf(dir, sizeof dir, "%s", argv[1]);
    snprintf(tmp, sizeof tmp, "%s", argv[2]);
    test_concurrent_init();
    CHECK(seg_init() == SEG_ABI_VERSION && SEG_ABI_VERSION == 2);
    int32_t abi = 0;
    OK(seg_abi_version(&abi));
    CHECK(abi == SEG_ABI_VERSION);
    char ver[16];
    int64_t len = 0;
    OK(seg_version(ver, sizeof ver, &len));
    CHECK(strcmp(ver, "0.2.0") == 0 && len == 5);
    test_layout();
    test_files();
    test_reads();
    test_gathers_and_prefetch();
    test_edits();
    test_convert();
    test_release_unmaps();
    test_limits();
    test_threads();
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf("abi_test: all checks passed\n");
    return 0;
}
