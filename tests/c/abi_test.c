/* C ABI test (tasks 8.4, 12.2, 12.5): every seg_* function through the
 * generated header (ABI version 3, names derived from the Nim core).
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
static int64_t file_len(SegSeismicFile *f) {
    int64_t n = -1;
    return seg_seismic_file_len(f, &n) == SEG_OK ? n : -999;
}

static int32_t kind_of(SegSeismicFile *f) {
    int32_t k = -1;
    return seg_seismic_file_kind(f, &k) == SEG_OK ? k : -999;
}

static int64_t log_len(SegDiagLog *l) {
    int64_t n = -1;
    return seg_diag_log_len(l, &n) == SEG_OK ? n : -999;
}

static int64_t log_count(SegDiagLog *l, int32_t sev) {
    int64_t n = -1;
    return seg_diag_log_count(l, sev, &n) == SEG_OK ? n : -999;
}

static SegSeismicFile *open_file(const char *name, bool keys) {
    SegSeismicFile *f = NULL;
    OK(seg_open_seismic(path(dir, name), false, keys, &f));
    return f;
}

/* ---- layout: every struct and field against the library -------------- */
#define SIZE(T) CHECK(seg_sizeof(#T) == (int64_t)sizeof(T))
#define OFF(T, f) CHECK(seg_offsetof(#T, #f) == (int64_t)offsetof(T, f))

static void test_layout(void) {
    SIZE(SegTraceEntry); SIZE(SegTraceKeys); SIZE(SegTensorView); SIZE(SegValue);
    SIZE(SegGather); SIZE(SegDiagnostic); SIZE(SegLocation); SIZE(SegPrefetchChunk);
    SIZE(SegSlice); SIZE(SegConvertOptions); SIZE(SegSegyRevision); SIZE(SegSegdConvertOptions);
    SIZE(SegSegdRevision); SIZE(SegSpsOptions); SIZE(SegFileSummary);
    SIZE(SegGeometryFields); SIZE(SegGeometryChanges);
    SIZE(SegStandardRevision); SIZE(SegChannelSetSummary);
    SIZE(SegHeaderRow); SIZE(SegValueRef);
    OFF(SegHeaderRow, block_name); OFF(SegHeaderRow, kind); OFF(SegHeaderRow, field);
    OFF(SegHeaderRow, value); OFF(SegHeaderRow, offset); OFF(SegHeaderRow, size);
    OFF(SegHeaderRow, block_offset); OFF(SegHeaderRow, block_size);
    OFF(SegValueRef, kind); OFF(SegValueRef, i); OFF(SegValueRef, f); OFF(SegValueRef, text);
    OFF(SegValueRef, text_len);
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
    OFF(SegTraceKeys, channel); OFF(SegTraceKeys, time);
    OFF(SegTensorView, data); OFF(SegTensorView, dtype); OFF(SegTensorView, rank);
    OFF(SegTensorView, shape); OFF(SegTensorView, strides);
    OFF(SegValue, kind); OFF(SegValue, i); OFF(SegValue, f); OFF(SegValue, text);
    OFF(SegValue, text_cap); OFF(SegValue, text_len);
    OFF(SegSlice, a); OFF(SegSlice, b);
    OFF(SegGather, kind); OFF(SegGather, traces); OFF(SegGather, sources);
    OFF(SegGather, receivers);
    OFF(SegDiagnostic, severity); OFF(SegDiagnostic, code); OFF(SegDiagnostic, offset);
    OFF(SegDiagnostic, loc); OFF(SegDiagnostic, msg);
    OFF(SegLocation, file); OFF(SegLocation, record); OFF(SegLocation, channel_set);
    OFF(SegLocation, trace); OFF(SegLocation, block_index); OFF(SegLocation, field);
    OFF(SegPrefetchChunk, first); OFF(SegPrefetchChunk, count); OFF(SegPrefetchChunk, failed);
    OFF(SegPrefetchChunk, samples);
    OFF(SegConvertOptions, revision); OFF(SegConvertOptions, byte_order);
    OFF(SegConvertOptions, format); OFF(SegConvertOptions, text_encoding);
    OFF(SegConvertOptions, apply_descale); OFF(SegConvertOptions, station_header);
    OFF(SegSegdConvertOptions, revision); OFF(SegSegdConvertOptions, format);
    OFF(SegSegdConvertOptions, twos_complement8015);
    OFF(SegSpsOptions, revision); OFF(SegSpsOptions, strict_implied_decimals);
    OFF(SegSpsOptions, layout); OFF(SegSpsOptions, force_layout);
    OFF(SegFileSummary, standard); OFF(SegFileSummary, revision);
    OFF(SegFileSummary, mixed_revisions); OFF(SegFileSummary, byte_order);
    OFF(SegFileSummary, format_code); OFF(SegFileSummary, decodable);
    OFF(SegFileSummary, trace_count); OFF(SegFileSummary, record_count);
    OFF(SegFileSummary, first_field_record); OFF(SegFileSummary, last_field_record);
    OFF(SegFileSummary, sample_interval_us); OFF(SegFileSummary, samples_per_trace);
    OFF(SegFileSummary, record_length_ms); OFF(SegFileSummary, coordinate_units);
    OFF(SegFileSummary, crs_format);
    OFF(SegStandardRevision, major); OFF(SegStandardRevision, minor);
    OFF(SegChannelSetSummary, record); OFF(SegChannelSetSummary, scan_type);
    OFF(SegChannelSetSummary, channel_set); OFF(SegChannelSetSummary, number);
    OFF(SegChannelSetSummary, channel_type); OFF(SegChannelSetSummary, trace_count);
    OFF(SegChannelSetSummary, samples_per_trace); OFF(SegChannelSetSummary, sample_interval_us);
    OFF(SegChannelSetSummary, start_time_ms); OFF(SegChannelSetSummary, end_time_ms);
    CHECK(seg_sizeof("NoSuchType") == -1 && seg_offsetof("SegValue", "nope") == -1);
}

/* ---- summary (task 6.8) ----------------------------------------------- */
static void test_summary(void) {
    SegSeismicFile *f = open_file("BO_3D-Inglewood_rev21_v7.sgy", false);
    SegFileSummary s;
    OK(seg_seismic_file_summary(f, &s));
    CHECK(s.standard == SEG_SEISMIC_KIND_SEG_Y && s.revision.major == 2 && s.revision.minor == 1);
    CHECK(s.byte_order == SEG_BYTE_ORDER_BIG && s.format_code == 1 && s.decodable);
    CHECK(s.trace_count == 200 && s.record_count == 1 && s.samples_per_trace == 2001);
    CHECK(s.sample_interval_us == 2000.0 && s.record_length_ms == 4000.0);
    CHECK(s.coordinate_units == SEG_COORDINATE_UNITS_METERS);
    CHECK(s.crs_format == SEG_CRS_TEXT_FORMAT_P1_11);
    int64_t len = -1;
    OK(seg_seismic_file_crs_text(f, NULL, 0, &len));
    CHECK(len > 1000);
    char head[16];
    OK(seg_seismic_file_crs_text(f, head, sizeof head, &len));
    CHECK(strncmp(head, "IOGP,IOGP P1", 12) == 0);
    SegChannelSetSummary cs[8];
    OK(seg_seismic_file_channel_sets(f, cs, 8, &len));
    CHECK(len == 0);
    seg_seismic_file_release(f);
    f = open_file("inova_rev30_5traces.sgd", true);
    SegTraceKeys k;
    OK(seg_seismic_file_trace_keys(f, 4, &k)); /* task 6.9: the GH#3 time zero, UTC */
    CHECK(fabs(k.time - 1790959547.504) < 1e-6);
    OK(seg_seismic_file_summary(f, &s));
    CHECK(s.standard == SEG_SEISMIC_KIND_SEG_D && s.revision.major == 3 && !s.mixed_revisions);
    CHECK(s.format_code == 8058 && s.first_field_record == 151 && s.sample_interval_us == 1000.0);
    CHECK(s.crs_format == SEG_CRS_TEXT_FORMAT_STANZA);
    OK(seg_seismic_file_channel_sets(f, cs, 8, &len));
    CHECK(len == 4 && cs[3].channel_type == 0x10 && cs[3].trace_count == 2);
    CHECK(cs[0].samples_per_trace == 4001 && cs[0].end_time_ms == 4000.0);
    OK(seg_seismic_file_channel_sets(f, cs, 2, &len)); /* too small: the full length */
    CHECK(len == 4);
    seg_seismic_file_release(f);
}

/* ---- header listing and patches (task 6.10) --------------------------- */
static void test_listing(void) {
    SegSeismicFile *f = open_file("63.sgd", false);
    SegHeaderListing *l = NULL;
    OK(seg_seismic_file_record_headers(f, 0, &l));
    int64_t n = -1;
    OK(seg_header_listing_len(l, &n));
    CHECK(n > 20);
    bool found = false;
    for (int64_t i = 0; i < n; i++) { /* the C iterator: len + get */
        SegHeaderRow r;
        OK(seg_header_listing_get(l, i, &r));
        if (strcmp(r.block_name, "gh3") == 0 && strcmp(r.field, "sourcePointNumber") == 0) {
            CHECK(r.kind == SEG_HEADER_BLOCK_SEG_D_GH_N && r.value.kind == SEG_VALUE_FLOAT);
            CHECK(r.value.f == 99.5 && r.block_offset == 64 && r.block_size == 32);
            found = true;
        }
    }
    CHECK(found);
    SegHeaderRow r;
    CHECK(seg_header_listing_get(l, n, &r) == SEG_ERR_ARGUMENT);
    seg_header_listing_release(l);
    CHECK(seg_seismic_file_trace_headers(f, 1, &l) == SEG_ERR_ARGUMENT && l == NULL);
    seg_seismic_file_release(f);
    f = open_file("BO_3D-Inglewood_rev21_v7.sgy", false);
    OK(seg_seismic_file_file_headers(f, &l));
    OK(seg_header_listing_get(l, 0, &r)); /* a raw block: its value names it */
    CHECK(strcmp(r.block_name, "text") == 0 && r.field[0] == '\0' && r.kind == SEG_HEADER_BLOCK_RAW);
    CHECK(r.value.kind == SEG_VALUE_TEXT && strcmp(r.value.text, "textual header") == 0 &&
          r.value.text_len == 14 && r.block_size == 3200);
    seg_header_listing_release(l);
    seg_seismic_file_release(f);
    char names[4096];
    int64_t len = -1;
    OK(seg_field_names(SEG_HEADER_BLOCK_SEG_Y_TRACE, names, sizeof names, &len));
    CHECK(len < (int64_t)sizeof names && strcmp(names, "traceSeqLine") == 0);
    CHECK(seg_field_names(99, names, sizeof names, &len) == SEG_ERR_ARGUMENT);
    SegHeaderPatch *p = NULL;
    OK(seg_header_patch_new(&p));
    SegValue v = {0};
    v.kind = SEG_VALUE_INT;
    v.i = 1700000;
    OK(seg_header_patch_add(p, SEG_HEADER_SCOPE_TRACE, 5, "trace.sourceX", &v));
    CHECK(seg_header_patch_add(p, SEG_HEADER_SCOPE_TRACE, 5, "sourceX", &v) == SEG_ERR_ARGUMENT);
    OK(seg_header_patch_len(p, &n));
    CHECK(n == 1);
    OK(seg_header_patch_write(p, path(tmp, "c_patch.nif")));
    CHECK(seg_header_patch_write(p, path(tmp, "no-dir/x.nif")) == SEG_ERR_IO);
    seg_header_patch_release(p);
}

/* ---- files, fields, logs --------------------------------------------- */
static void test_files(void) {
    SegSeismicFile *f = open_file("BO_3D-Inglewood_rev21_v7.sgy", true);
    CHECK(kind_of(f) == SEG_SEISMIC_KIND_SEG_Y && file_len(f) == 200);
    int64_t n = -1;
    OK(seg_seismic_file_record_count(f, &n));
    CHECK(n == 1);
    OK(seg_seismic_file_max_samples(f, &n));
    CHECK(n == 2001);
    bool b = false;
    OK(seg_seismic_file_has_keys(f, &b));
    CHECK(b);
    OK(seg_seismic_file_is_open(f, &b));
    CHECK(b);
    double si = 0;
    OK(seg_seismic_file_sample_interval_us(f, 0, &si));
    CHECK(si == 2000.0);
    CHECK(seg_seismic_file_sample_interval_us(f, 200, &si) == SEG_ERR_ARGUMENT);
    char name[2048];
    int64_t len = -1;
    OK(seg_seismic_file_path(f, name, sizeof name, &len));
    CHECK(strstr(name, "Inglewood") != NULL && len == (int64_t)strlen(name));
    OK(seg_seismic_file_demux_path(f, name, sizeof name, &len));
    CHECK(len == 0 && name[0] == 0); /* not multiplexed SEG-D */
    SegTraceEntry e;
    OK(seg_seismic_file_trace_entry(f, 199, &e));
    CHECK(e.num_samples == 2001 && e.header_bytes == 240 && e.channel_set == 0xFFFF);
    CHECK(seg_seismic_file_trace_entry(f, 200, &e) == SEG_ERR_ARGUMENT &&
          strlen(seg_last_error()) > 0);
    SegTraceKeys k;
    OK(seg_seismic_file_trace_keys(f, 0, &k));
    CHECK(k.ensemble == 1001001.0 && isnan(k.time)); /* trace bytes 157-158: year 0 */
    uint8_t head[8];
    OK(seg_seismic_file_copy_bytes(f, 0, 4, head, sizeof head, &n));
    CHECK(n == 4 && head[0] == 0xC3);
    CHECK(seg_seismic_file_copy_bytes(f, 0, -1, head, 8, &n) == SEG_ERR_ARGUMENT); /* Natural */
    SegValue v;
    OK(seg_seismic_file_trace_field(f, 5, "trace.sourceX", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 1704188);
    OK(seg_seismic_file_file_field(f, "binary.sampleInterval", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 2000);
    /* Text: into the caller's buffer, with its full length; too small is truncated. */
    char text[256];
    v.text = text;
    v.text_cap = sizeof text;
    OK(seg_seismic_file_trace_field(f, 0, "trace.headerName", &v));
    CHECK(v.kind == SEG_VALUE_TEXT && v.text_len >= 0 && v.text_len < 256);
    v.text_cap = 1;
    OK(seg_seismic_file_trace_field(f, 0, "trace.headerName", &v));
    CHECK(text[0] == '\0');
    v.text = NULL;
    v.text_cap = 0;
    CHECK(seg_seismic_file_trace_field(f, 0, "trace.nope", &v) == SEG_ERR_ARGUMENT);
    CHECK(strstr(seg_last_error(), "trace.nope") != NULL);
    CHECK(seg_seismic_file_record_field(f, 0, "gh1.year", &v) == SEG_ERR_ARGUMENT); /* SEG-Y */
    CHECK(seg_seismic_file_trace_field(f, 0, NULL, &v) == SEG_ERR_ARGUMENT);
    SegDiagLog *log = NULL;
    OK(seg_seismic_file_log(f, &log));
    CHECK(log_len(log) == 0);
    OK(seg_diag_log_is_fatal(log, &b));
    CHECK(!b);
    OK(seg_diag_log_to_nif(log, NULL, 0, &len));
    CHECK(len > 0);
    seg_diag_log_release(log);
    seg_seismic_file_release(f);

    /* SEG-D: record fields, a log with entries. */
    f = open_file("63.sgd", false);
    CHECK(kind_of(f) == SEG_SEISMIC_KIND_SEG_D && file_len(f) == 1);
    OK(seg_seismic_file_record_field(f, 0, "gh3.sourcePointNumber", &v));
    CHECK(v.kind == SEG_VALUE_FLOAT && v.f == 99.5);
    OK(seg_seismic_file_trace_field(f, 0, "ext1.sensorType", &v));
    CHECK(v.i == 2);
    CHECK(seg_seismic_file_trace_keys(f, 0, &k) == SEG_ERR_ARGUMENT); /* opened without keys */
    OK(seg_seismic_file_log(f, &log));
    CHECK(log_len(log) == 2 && log_count(log, SEG_SEVERITY_INFO) == 2);
    SegDiagnostic d;
    OK(seg_diag_log_get(log, 0, &d));
    CHECK(d.severity == SEG_SEVERITY_INFO && d.code == SEG_DIAG_CODE_BAD_VALUE);
    CHECK(d.offset == 83 && strstr(d.msg, "source set") != NULL && strlen(d.loc.file) > 0);
    CHECK(seg_diag_log_get(log, 2, &d) == SEG_ERR_ARGUMENT);
    CHECK(seg_diag_log_get(log, -1, &d) == SEG_ERR_ARGUMENT);
    char *nif = malloc(65536);
    OK(seg_diag_log_to_nif(log, nif, 65536, &len));
    CHECK(len < 65536 && strstr(nif, "(diagnostics") != NULL);
    free(nif);
    CHECK(log_count(log, 9) == -999); /* not a severity */
    seg_diag_log_release(log);
    seg_seismic_file_release(f);

    /* Failures and junk. */
    f = (SegSeismicFile *)1;
    CHECK(seg_open_seismic(path(dir, "no-such-file"), false, false, &f) == SEG_ERR_IO && f == NULL);
    CHECK(seg_open_seismic(NULL, false, false, &f) == SEG_ERR_ARGUMENT);
    FILE *j = fopen(path(tmp, "junk.bin"), "wb");
    for (int i = 0; i < 5000; i++) fputc(0, j);
    fclose(j);
    OK(seg_open_seismic(path(tmp, "junk.bin"), false, false, &f));
    CHECK(kind_of(f) == SEG_SEISMIC_KIND_UNKNOWN && file_len(f) == 0);
    OK(seg_seismic_file_log(f, &log));
    CHECK(log_count(log, SEG_SEVERITY_FATAL) == 1);
    seg_diag_log_release(log);
    seg_seismic_file_release(f);
    seg_seismic_file_release(NULL);
    CHECK(seg_seismic_file_len(NULL, &n) == SEG_ERR_ARGUMENT);
    OK(seg_status_name(SEG_ERR_STATE, name, sizeof name, &len));
    CHECK(strcmp(name, "SEG_ERR_STATE") == 0 && len == 13);
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

static SegTensorView dest(void *data, int32_t dtype, int64_t rows, int64_t cols, int64_t stride) {
    SegTensorView v = {data, dtype, 2, {rows, cols}, {stride, 1}};
    return v;
}

static void test_reads(void) {
    SegSeismicFile *f = open_file("BO_3D-Inglewood_rev21_v7.sgy", false);
    SegTensor *t = NULL;
    OK(seg_seismic_file_read_traces_range(f, 10, 14, SEG_DTYPE_FLOAT32, &t)); /* 10..14 */
    SegTensorView v;
    OK(seg_tensor_view(t, &v));
    CHECK(v.dtype == SEG_DTYPE_FLOAT32 && v.rank == 2 && v.shape[0] == 5 && v.shape[1] == 2001);
    CHECK(v.strides[0] == 2001 && v.strides[1] == 1);
    int32_t dt = 0;
    OK(seg_tensor_dtype(t, &dt));
    CHECK(dt == SEG_DTYPE_FLOAT32);
    const float *a = (const float *)v.data;
    /* Into a caller buffer with a row stride: same samples. */
    float *buf = calloc(6 * 2100, sizeof(float));
    SegTensorView b = dest(buf, SEG_DTYPE_FLOAT32, 6, 2001, 2100);
    int64_t failed = -1;
    OK(seg_seismic_file_read_traces_into_range(f, 10, 14, &b, 1, &failed)); /* rows 1..5 */
    CHECK(failed == 0);
    int same = 1;
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 2001; c++)
            if (buf[(r + 1) * 2100 + c] != a[r * 2001 + c]) same = 0;
    CHECK(same && buf[0] == 0);
    /* A selection, in list order, as doubles. */
    int64_t sel[3] = {14, 10, 14};
    double *dbuf = calloc(3 * 2001, sizeof(double));
    SegTensorView db = dest(dbuf, SEG_DTYPE_FLOAT64, 3, 2001, 2001);
    OK(seg_seismic_file_read_traces_into(f, sel, 3, &db, 0, &failed));
    CHECK(dbuf[0] == (double)a[4 * 2001] && dbuf[2001 + 7] == (double)a[7]);
    SegTensor *t2 = NULL;
    OK(seg_seismic_file_read_traces(f, sel, 3, SEG_DTYPE_FLOAT64, &t2));
    SegTensorView v2;
    OK(seg_tensor_view(t2, &v2));
    CHECK(v2.dtype == SEG_DTYPE_FLOAT64 && v2.shape[1] == 2001 &&
          ((double *)v2.data)[2 * 2001 + 9] == dbuf[2 * 2001 + 9]);
    seg_tensor_release(t2);
    dl_check(t, &v);
    /* An empty range (a..a-1, as in Nim). */
    OK(seg_seismic_file_read_traces_range(f, 200, 199, SEG_DTYPE_FLOAT32, &t));
    OK(seg_tensor_view(t, &v));
    CHECK(v.shape[0] == 0);
    seg_tensor_release(t);
    /* Bad arguments. */
    t = (SegTensor *)1;
    CHECK(seg_seismic_file_read_traces_range(f, 199, 200, SEG_DTYPE_FLOAT32, &t) ==
          SEG_ERR_ARGUMENT && t == NULL);
    CHECK(seg_seismic_file_read_traces_range(f, 0, 0, 7, &t) == SEG_ERR_ARGUMENT);
    int64_t badsel[1] = {200};
    CHECK(seg_seismic_file_read_traces(f, badsel, 1, SEG_DTYPE_FLOAT32, &t) == SEG_ERR_ARGUMENT);
    SegTensorView bad = dest(buf, SEG_DTYPE_FLOAT32, 1, 10, 5); /* stride < cols */
    CHECK(seg_seismic_file_read_traces_into_range(f, 0, 0, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    bad = dest(NULL, SEG_DTYPE_FLOAT32, 1, 10, 10);
    CHECK(seg_seismic_file_read_traces_into_range(f, 0, 0, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    bad = dest(buf, 9, 1, 10, 10);
    CHECK(seg_seismic_file_read_traces_into_range(f, 0, 0, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    bad = dest(buf, SEG_DTYPE_FLOAT32, 1, 10, 10);
    bad.strides[1] = 2;
    CHECK(seg_seismic_file_read_traces_into_range(f, 0, 0, &bad, 0, &failed) == SEG_ERR_ARGUMENT);
    CHECK(seg_seismic_file_read_traces_into(f, sel, 3, &db, 1, &failed) == SEG_ERR_ARGUMENT);
    CHECK(seg_seismic_file_read_traces_into(f, sel, 3, NULL, 0, &failed) == SEG_ERR_ARGUMENT);
    free(buf);
    free(dbuf);
    seg_seismic_file_release(f);
}

/* ---- gathers, components, geometry, prefetch ------------------------- */
static void test_gathers_and_prefetch(void) {
    SegSeismicFile *f = open_file("inova_rev30_5traces.sgd", true);
    int64_t n = -1;
    OK(seg_seismic_file_gathers(f, NULL, 0, &n));
    CHECK(n == 1);
    SegGather g;
    OK(seg_seismic_file_gathers(f, &g, 1, &n));
    CHECK(g.kind == SEG_GATHER_KIND_SHOT && g.traces.a == 0 && g.traces.b == 4 &&
          g.receivers == 2);
    SegTraceKeys k;
    OK(seg_seismic_file_trace_keys(f, 3, &k));
    CHECK(k.rcv_x == 1826232.375 && k.src_x == 1834704.375 && k.offset > 8000 && k.offset < 9000);
    CHECK(k.cmp_x == (k.src_x + k.rcv_x) / 2);
    int64_t group_of[5];
    OK(seg_seismic_file_component_group_ids(f, 0, 4, group_of, 5, &n));
    CHECK(n == 5 && group_of[0] == -1 && group_of[3] == 0 && group_of[4] == 1);
    seg_seismic_file_release(f);

    /* External geometry: SEG-D 2.0 has no coordinates in its headers. */
    f = open_file("63.sgd", true);
    SegSurveyGeometry *geo = NULL;
    OK(seg_survey_geometry_new(&geo));
    OK(seg_survey_geometry_add_source(geo, 13, 99.5, 1, 1000, 2000, NAN));
    OK(seg_survey_geometry_add_receiver(geo, 13, 104, 0, 1300, 2400, 7));
    int64_t updated = -1;
    OK(seg_seismic_file_apply_survey(f, geo, false, &updated));
    CHECK(updated == 1);
    OK(seg_seismic_file_trace_keys(f, 0, &k));
    CHECK(k.offset == 500 && k.cmp_y == 2200 && k.rcv_z == 7 && isnan(k.src_z));
    CHECK(k.record == 63 && k.channel == 1);
    seg_survey_geometry_release(geo);

    /* Survey files: an SPS relation (record 63, channel 1) names the stations. */
    const char *sps_text =
        "H00 SPS format version number   SPS 2.1;\n"
        "R     10.00    101.00  1G1                     500100.0 6000000.0  12.5 18213250\n"
        "S     20.00    205.00  1V6                     500000.0 6000400.0  10.0 19001150\n"
        "XT1          6311     20.00    205.001    1    11     10.00    101.00    101.001\n";
    FILE *fh = fopen(path(tmp, "t.sps"), "w");
    fputs(sps_text, fh);
    fclose(fh);
    OK(seg_survey_geometry_new(&geo));
    OK(seg_survey_geometry_add_sps(geo, path(tmp, "t.sps"), NULL));
    SegDiagLog *slog = NULL;
    OK(seg_survey_geometry_log(geo, &slog));
    CHECK(slog != NULL && log_len(slog) == 0);
    seg_diag_log_release(slog);
    int64_t s = -1, r = -1, x = -1;
    OK(seg_survey_geometry_source_count(geo, &s));
    OK(seg_survey_geometry_receiver_count(geo, &r));
    OK(seg_survey_geometry_relation_count(geo, &x));
    CHECK(s == 1 && r == 1 && x == 1);
    CHECK(seg_survey_geometry_add_sps(geo, path(tmp, "missing.sps"), NULL) == SEG_ERR_IO);
    SegSpsOptions so;
    seg_init_sps_options(&so);
    CHECK(so.revision == SEG_SPS_REVISION_AUTO && so.layout == SEG_TEXT_LAYOUT_LINES);
    so.revision = 77;
    CHECK(seg_survey_geometry_add_sps(geo, path(tmp, "t.sps"), &so) == SEG_ERR_ARGUMENT);
    OK(seg_survey_geometry_set_trailing_digits(geo, true));
    bool on = false;
    OK(seg_survey_geometry_trailing_digits(geo, &on));
    CHECK(on);
    OK(seg_survey_geometry_set_tape(geo, ""));
    OK(seg_survey_geometry_map_line(geo, "LINE A", 7));
    CHECK(seg_survey_geometry_map_line(geo, "", 7) == SEG_ERR_ARGUMENT);
    OK(seg_seismic_file_apply_survey(f, geo, true, &updated));
    CHECK(updated == 1);
    OK(seg_seismic_file_trace_keys(f, 0, &k));
    CHECK(k.src_point == 205 && k.rcv_point == 101 && k.rcv_x == 500100 && k.offset > 412.3 &&
          k.offset < 412.4);

    /* Writing the joined geometry back (10.5): a dry run, a copy, in place. */
    SegGeometryChanges gc;
    OK(seg_seismic_file_geometry_changes(f, NULL, &gc));
    CHECK(gc.traces == 1 && gc.receiver_stations == 1 && gc.receiver_xy == 0 && gc.unwritable > 0);
    SegGeometryFields gf;
    seg_init_geometry_fields(&gf);
    CHECK(gf.source_xy && gf.stations);
    gf.stations = false;
    OK(seg_seismic_file_geometry_changes(f, &gf, &gc));
    CHECK(gc.traces == 0);
    SegDiagLog *plog = NULL;
    OK(seg_seismic_file_preview_geometry(f, NULL, &plog));
    CHECK(log_count(plog, SEG_SEVERITY_WARNING) > 0 && log_count(plog, SEG_SEVERITY_INFO) == 1);
    seg_diag_log_release(plog);
    const char *geo_copy = path(tmp, "63geo.sgd");
    OK(seg_copy_with_geometry(path(dir, "63.sgd"), geo_copy, geo, NULL, true, &plog));
    CHECK(log_count(plog, SEG_SEVERITY_ERROR) == 0);
    seg_diag_log_release(plog);
    SegSeismicFile *gcf = NULL;
    OK(seg_open_seismic(geo_copy, false, true, &gcf));
    OK(seg_seismic_file_trace_keys(gcf, 0, &k));
    CHECK(k.rcv_line == 10 && k.rcv_point == 101);
    seg_seismic_file_release(gcf);
    /* In place on a plain copy: the editor's file and its joined keys. */
    const char *plain = path(tmp, "63plain.sgd");
    SegConvertOptions co;
    seg_init_convert_options(&co);
    OK(seg_copy_with_geometry(path(dir, "63.sgd"), plain, geo, &gf, false, &plog)); /* nothing */
    seg_diag_log_release(plog);
    SegHeaderEditor *ged = NULL;
    OK(seg_open_editor(plain, path(tmp, "63plain.nif"), &ged));
    OK(seg_open_seismic(plain, false, true, &gcf));
    OK(seg_seismic_file_apply_survey(gcf, geo, true, &updated));
    OK(seg_header_editor_write_geometry(ged, gcf, NULL, &gc));
    CHECK(gc.receiver_stations == 1);
    OK(seg_header_editor_close(ged));
    seg_header_editor_release(ged);
    seg_seismic_file_release(gcf);
    OK(seg_open_seismic(plain, false, true, &gcf));
    OK(seg_seismic_file_trace_keys(gcf, 0, &k));
    CHECK(k.rcv_point == 101);
    seg_seismic_file_release(gcf);
    OK(seg_rollback_journal(plain, path(tmp, "63plain.nif"), &plog));
    seg_diag_log_release(plog);
    OK(seg_open_seismic(plain, false, true, &gcf));
    OK(seg_seismic_file_trace_keys(gcf, 0, &k));
    CHECK(k.rcv_point == 104);
    seg_seismic_file_release(gcf);
    OK(seg_convert_with_geometry(path(dir, "63.sgd"), path(tmp, "63geo.sgy"), geo, &co, NULL,
                                 true, &plog));
    seg_diag_log_release(plog);
    OK(seg_open_seismic(path(tmp, "63geo.sgy"), false, true, &gcf));
    OK(seg_seismic_file_trace_keys(gcf, 0, &k));
    CHECK(k.rcv_x == 500100);
    seg_seismic_file_release(gcf);
    seg_survey_geometry_release(geo);
    seg_seismic_file_release(f);

    f = open_file("BO_3D-Inglewood_rev21_v7.sgy", false);
    CHECK(seg_seismic_file_gathers(f, NULL, 0, &n) == SEG_ERR_ARGUMENT); /* no keys */
    SegTensor *all = NULL;
    OK(seg_seismic_file_read_traces_range(f, 0, 199, SEG_DTYPE_FLOAT32, &all));
    SegTensorView av;
    OK(seg_tensor_view(all, &av));
    const float *a = (const float *)av.data;
    SegPrefetcher *p = NULL;
    OK(seg_prefetcher_new_range(f, 0, 199, 32, 3, -1, SEG_DTYPE_FLOAT32, &p));
    seg_seismic_file_release(f); /* the prefetcher keeps the file alive */
    SegPrefetchChunk c;
    int64_t pos = 0;
    SegStatus st;
    while ((st = seg_prefetcher_next(p, &c)) == SEG_OK) {
        SegTensorView cv;
        OK(seg_tensor_view(c.samples, &cv));
        CHECK(c.first == pos && cv.shape[0] == c.count && c.failed == 0);
        CHECK(memcmp(cv.data, a + pos * 2001, (size_t)(c.count * 2001) * sizeof(float)) == 0);
        pos += c.count;
        seg_tensor_release(c.samples);
    }
    CHECK(st == SEG_END && pos == 200);
    bool end = false;
    OK(seg_prefetcher_at_end(p, &end));
    CHECK(end);
    CHECK(seg_prefetcher_try_next(p, &c) == SEG_END);
    OK(seg_prefetcher_seek(p, 150, 159));
    do { st = seg_prefetcher_try_next(p, &c); } while (st == SEG_NOT_READY);
    CHECK(st == SEG_OK && c.first == 150 && c.count == 10);
    seg_tensor_release(c.samples);
    CHECK(seg_prefetcher_seek(p, 10, 299) == SEG_ERR_ARGUMENT);
    int64_t at = 0;
    OK(seg_prefetcher_trace_at(p, 7, &at));
    CHECK(at == 7);
    CHECK(seg_prefetcher_trace_at(p, 200, &at) == SEG_ERR_ARGUMENT);
    OK(seg_prefetcher_len(p, &n));
    CHECK(n == 200);
    OK(seg_prefetcher_close(p));
    seg_prefetcher_release(p);
    /* A list prefetcher: positions index the list. */
    int64_t sel[3] = {5, 3, 1};
    f = open_file("BO_3D-Inglewood_rev21_v7.sgy", false);
    OK(seg_prefetcher_new(f, sel, 3, 2, 2, -1, SEG_DTYPE_FLOAT64, &p));
    OK(seg_prefetcher_trace_at(p, 0, &at));
    CHECK(at == 5);
    OK(seg_prefetcher_next(p, &c));
    CHECK(c.first == 0 && c.count == 2);
    seg_tensor_release(c.samples);
    seg_prefetcher_release(p); /* joins the worker */
    CHECK(seg_prefetcher_new_range(f, 0, 199, 0, 1, -1, SEG_DTYPE_FLOAT32, &p) ==
          SEG_ERR_ARGUMENT && p == NULL);
    seg_seismic_file_release(f);
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
    SegHeaderEditor *e = NULL;
    CHECK(seg_open_editor(copy, copy, &e) == SEG_ERR_ARGUMENT); /* the journal is the file */
    OK(seg_open_editor(copy, journal, &e));
    char jp[2048];
    int64_t len = 0;
    OK(seg_header_editor_journal_path(e, jp, sizeof jp, &len));
    CHECK(strcmp(jp, journal) == 0);
    SegValue v = {SEG_VALUE_INT, 0, -4242, 0, NULL, 0, 0};
    bool done = false;
    OK(seg_header_editor_set_trace_field(e, 0, "trace.sourceX", &v, &done));
    CHECK(done);
    v.i = 10;
    OK(seg_header_editor_set_trace_field(e, 0, "trace.numSamples", &v, &done));
    CHECK(!done); /* refused: structural; the log says why */
    v.kind = SEG_VALUE_FLOAT; v.f = 1.5;
    OK(seg_header_editor_set_trace_field(e, 0, "trace.groupX", &v, &done));
    CHECK(!done);
    v.kind = SEG_VALUE_INT; v.i = 7;
    OK(seg_header_editor_set_file_field(e, "binary.jobId", &v, &done));
    CHECK(done);
    OK(seg_header_editor_set_record_field(e, 0, "gh1.year", &v, &done)); /* SEG-Y: no records */
    CHECK(!done);
    OK(seg_header_editor_set_trace_field(e, -1, "trace.sourceX", &v, &done));
    CHECK(!done);
    CHECK(seg_header_editor_set_trace_field(e, 0, "trace.sourceX", NULL, &done) ==
          SEG_ERR_ARGUMENT);
    v.kind = 9;
    CHECK(seg_header_editor_set_file_field(e, "binary.jobId", &v, &done) == SEG_ERR_ARGUMENT);
    int64_t edits = -1;
    OK(seg_header_editor_edits(e, &edits));
    CHECK(edits == 2);
    SegDiagLog *log = NULL;
    OK(seg_header_editor_log(e, &log));
    CHECK(log_count(log, SEG_SEVERITY_ERROR) >= 2);
    SegDiagnostic d;
    OK(seg_diag_log_get(log, 0, &d));
    CHECK(strstr(d.msg, "structure") != NULL);
    seg_diag_log_release(log);
    OK(seg_header_editor_close(e));
    seg_header_editor_release(e);
    SegSeismicFile *f = NULL;
    OK(seg_open_seismic(copy, false, false, &f));
    v.kind = 0;
    OK(seg_seismic_file_trace_field(f, 0, "trace.sourceX", &v));
    CHECK(v.i == -4242);
    seg_seismic_file_release(f);
    log = NULL;
    OK(seg_rollback_journal(copy, journal, &log));
    CHECK(log_len(log) == 0);
    seg_diag_log_release(log);
    CHECK(file_bytes(copy, &now) == n && memcmp(now, orig, (size_t)n) == 0);
    free(now);
    OK(seg_apply_journal(copy, journal, NULL));
    log = NULL;
    CHECK(seg_rollback_journal(copy, path(tmp, "missing.nif"), &log) == SEG_ERR_IO);
    CHECK(log != NULL && log_count(log, SEG_SEVERITY_FATAL) == 1); /* the failure's log */
    seg_diag_log_release(log);
    free(orig);
}

/* ---- conversion ------------------------------------------------------ */
static void test_convert(void) {
    SegDiagLog *log = NULL;
    SegConvertOptions o;
    seg_init_convert_options(&o);
    CHECK(o.revision.major == 2 && o.revision.minor == 1 && o.byte_order == SEG_BYTE_ORDER_BIG &&
          o.text_encoding == SEG_TEXT_ENCODING_EBCDIC && o.station_header && !o.apply_descale &&
          o.format == SEG_SEGY_TARGET_FORMAT_KEEP);
    OK(seg_convert_file(path(dir, "inova_rev30_5traces.sgd"), path(tmp, "inova.sgy"), &o, &log));
    CHECK(log_count(log, SEG_SEVERITY_ERROR) == 0 && log_len(log) > 0);
    seg_diag_log_release(log);
    SegSeismicFile *f = NULL;
    OK(seg_open_seismic(path(tmp, "inova.sgy"), false, false, &f));
    CHECK(kind_of(f) == SEG_SEISMIC_KIND_SEG_Y && file_len(f) == 5);
    SegValue v;
    OK(seg_seismic_file_trace_field(f, 3, "ext1.extGroupX", &v));
    CHECK(v.kind == SEG_VALUE_FLOAT && v.f == 1826232.375);
    seg_seismic_file_release(f);
    /* SEG-2 (11.2): to SEG-2, its keyword strings, named fields, back to SEG-D. */
    CHECK(o.target == SEG_SEISMIC_KIND_SEG_Y && o.seg2.byte_order == SEG_BYTE_ORDER_LITTLE &&
          o.seg2.format == SEG_SEG2TARGET_FORMAT_KEEP && o.segd.revision.major == 3);
    o.target = SEG_SEISMIC_KIND_SEG_2;
    o.seg2.format = SEG_SEG2TARGET_FORMAT_4;
    log = NULL;
    OK(seg_convert_file(path(dir, "inova_rev30_5traces.sgd"), path(tmp, "inova.sg2"), &o, &log));
    seg_diag_log_release(log);
    OK(seg_open_seismic(path(tmp, "inova.sg2"), false, false, &f));
    CHECK(kind_of(f) == SEG_SEISMIC_KIND_SEG_2 && file_len(f) == 5);
    int64_t count = 0, len = 0;
    char text[256];
    OK(seg_seismic_file_seg2_string_count(f, -1, &count));
    CHECK(count >= 3);
    OK(seg_seismic_file_seg2_string_count(f, 0, &count));
    CHECK(count >= 3);
    int64_t channel = -1;
    for (int64_t k = 0; k < count; k++) {
        OK(seg_seismic_file_seg2_keyword(f, 0, k, text, sizeof text, &len));
        if (strcmp(text, "CHANNEL_NUMBER") == 0) channel = k;
    }
    CHECK(channel >= 0);
    OK(seg_seismic_file_seg2_value(f, 0, channel, text, sizeof text, &len));
    CHECK(len == 1 && strcmp(text, "1") == 0);
    CHECK(seg_seismic_file_seg2_value(f, 0, 99, text, sizeof text, &len) == SEG_ERR_ARGUMENT);
    OK(seg_seismic_file_trace_field(f, 0, "trace.formatCode", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 4);
    char units[16];
    v.text = units;
    v.text_cap = sizeof units;
    OK(seg_seismic_file_file_field(f, "file.UNITS", &v));
    CHECK(v.kind == SEG_VALUE_TEXT && v.text_len == 4 && strcmp(units, "NONE") == 0);
    seg_seismic_file_release(f);
    o.target = SEG_SEISMIC_KIND_SEG_D;
    log = NULL;
    OK(seg_convert_file(path(tmp, "inova.sg2"), path(tmp, "inova2.sgd"), &o, &log));
    seg_diag_log_release(log);
    CHECK(seg_convert_file(path(tmp, "inova.sgy"), path(tmp, "x.sgd"), &o, NULL) ==
          SEG_ERR_FORMAT); /* SEG-Y to SEG-D is not supported */
    seg_init_convert_options(&o);
    /* Little-endian needs Rev 2: the failure hands its log out. */
    log = NULL;
    o.revision.major = 1;
    o.revision.minor = 0;
    o.byte_order = SEG_BYTE_ORDER_LITTLE;
    CHECK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, &log) ==
          SEG_ERR_FORMAT);
    CHECK(log != NULL && log_count(log, SEG_SEVERITY_FATAL) == 1);
    seg_diag_log_release(log);
    o.revision.major = 7;
    o.byte_order = SEG_BYTE_ORDER_BIG;
    CHECK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) ==
          SEG_ERR_FORMAT);
    seg_init_convert_options(&o);
    o.byte_order = 5;
    CHECK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) ==
          SEG_ERR_ARGUMENT); /* no such byte order */
    seg_init_convert_options(&o);
    o.format = 99; /* not a SEG_SEGY_TARGET_FORMAT_* value */
    CHECK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) ==
          SEG_ERR_ARGUMENT);
    o.format = 13; /* format codes 13 and 14 are undefined: holes, not 15 and 16 */
    CHECK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) ==
          SEG_ERR_ARGUMENT);
    o.format = 14;
    CHECK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "x.sgy"), &o, NULL) ==
          SEG_ERR_ARGUMENT);
    /* The values are the format codes. */
    CHECK(SEG_SEGY_TARGET_FORMAT_5 == 5 && SEG_SEGY_TARGET_FORMAT_15 == 15 &&
          SEG_SEGY_TARGET_FORMAT_16 == 16);
    o.format = 16;
    OK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "sw16.sgy"), &o, NULL));
    OK(seg_open_seismic(path(tmp, "sw16.sgy"), false, false, &f));
    OK(seg_seismic_file_file_field(f, "binary.formatCode", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 16);
    seg_seismic_file_release(f);
    o.format = SEG_SEGY_TARGET_FORMAT_5;
    OK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "sw5.sgy"), &o, NULL));
    OK(seg_convert_file(path(dir, "Sweep0.sgy"), path(tmp, "sw.sgy"), NULL, NULL)); /* defaults */
    /* SEG-D revisions (task 8.7). */
    SegDiagLog *slog = NULL;
    OK(seg_convert_segd_revision(path(dir, "63.sgd"), path(tmp, "63_r3.sgd"), NULL, &slog));
    CHECK(slog != NULL && log_len(slog) > 0 && log_count(slog, SEG_SEVERITY_FATAL) == 0);
    seg_diag_log_release(slog);
    OK(seg_open_seismic(path(tmp, "63_r3.sgd"), false, false, &f));
    CHECK(kind_of(f) == SEG_SEISMIC_KIND_SEG_D && file_len(f) == 1);
    OK(seg_seismic_file_record_field(f, 0, "gh1.formatCode", &v));
    CHECK(v.kind == SEG_VALUE_INT && v.i == 8058);
    seg_seismic_file_release(f);
    SegSegdConvertOptions so;
    seg_init_segd_convert_options(&so);
    CHECK(so.revision.major == 3 && so.revision.minor == 0 &&
          so.format == SEG_SEGD_TARGET_FORMAT_KEEP);
    so.revision.major = 2;
    so.revision.minor = 1;
    OK(seg_convert_segd_revision(path(tmp, "63_r3.sgd"), path(tmp, "63_r2.sgd"), &so, NULL));
    slog = NULL;
    so.revision.major = 1;
    so.revision.minor = 0;
    CHECK(seg_convert_segd_revision(path(dir, "63.sgd"), path(tmp, "x.sgd"), &so, &slog) ==
          SEG_ERR_FORMAT && slog != NULL && log_count(slog, SEG_SEVERITY_FATAL) == 1);
    seg_diag_log_release(slog);
    so.revision.major = 2;
    so.revision.minor = 1;
    so.format = SEG_SEGD_TARGET_FORMAT_8080;
    CHECK(seg_convert_segd_revision(path(dir, "63.sgd"), path(tmp, "x.sgd"), &so, NULL) ==
          SEG_ERR_FORMAT);
    so.format = 8058; /* a format code is not a SEG_SEGD_TARGET_FORMAT_* value */
    CHECK(seg_convert_segd_revision(path(dir, "63.sgd"), path(tmp, "x.sgd"), &so, NULL) ==
          SEG_ERR_ARGUMENT);
    CHECK(seg_convert_segd_revision(NULL, path(tmp, "x.sgd"), NULL, NULL) == SEG_ERR_ARGUMENT);
}

/* ---- review regressions (Phase 8) ----------------------------------- */
static void test_limits(void) {
    SegSeismicFile *f = open_file("BO_3D-Inglewood_rev21_v7.sgy", false);
    SegTensor *t = (SegTensor *)1;
    /* Hostile sizes are refused, never fatal. */
    CHECK(seg_seismic_file_read_traces_range(f, 0, INT64_MAX, SEG_DTYPE_FLOAT32, &t) ==
          SEG_ERR_ARGUMENT && t == NULL);
    CHECK(seg_seismic_file_read_traces_range(f, INT64_MIN, 0, SEG_DTYPE_FLOAT32, &t) ==
          SEG_ERR_ARGUMENT);
    float one[4];
    SegTensorView b = dest(one, SEG_DTYPE_FLOAT32, 2, 2, INT64_MAX / 2);
    CHECK(seg_seismic_file_read_traces_into_range(f, 0, 1, &b, 0, NULL) == SEG_ERR_ARGUMENT);
    b = dest(one, SEG_DTYPE_FLOAT32, 2, 2, 2);
    CHECK(seg_seismic_file_read_traces_into_range(f, 0, 1, &b, INT64_MAX, NULL) ==
          SEG_ERR_ARGUMENT);
    SegPrefetcher *p = (SegPrefetcher *)1;
    CHECK(seg_prefetcher_new_range(f, 0, 199, 16, 4, (int64_t)1 << 40, SEG_DTYPE_FLOAT32, &p) ==
          SEG_ERR_ARGUMENT);
    CHECK(p == NULL);
    CHECK(seg_prefetcher_new_range(f, 0, 199, 1 << 24, 1024, 1 << 20, SEG_DTYPE_FLOAT64, &p) ==
          SEG_ERR_ARGUMENT);
    CHECK(seg_prefetcher_new_range(f, 0, 199, 16, 4, -2, SEG_DTYPE_FLOAT32, &p) ==
          SEG_ERR_ARGUMENT);
    /* A request under the limit but beyond memory: SEG_ERR_MEMORY, the host lives
       on. In a child capped at 4 GiB of address space, so it is deterministic
       (not under sanitizers, whose shadow memory needs the address space). */
    if (!getenv("ASAN_OPTIONS") && !getenv("TSAN_OPTIONS")) {
        pid_t pid = fork();
        if (pid == 0) {
            struct rlimit lim = {(rlim_t)4 << 30, (rlim_t)4 << 30};
            setrlimit(RLIMIT_AS, &lim);
            SegPrefetcher *big = NULL;
            SegStatus st = seg_prefetcher_new_range(f, 0, 199, 256, 4, (int64_t)1 << 22,
                                                   SEG_DTYPE_FLOAT32, &big);
            _exit(st == SEG_ERR_MEMORY && big == NULL ? 0 : 3);
        }
        int status = 0;
        waitpid(pid, &status, 0);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    /* A huge selection count is refused before any read. */
    int64_t tr[1] = {999999};
    CHECK(seg_seismic_file_read_traces(f, tr, (int64_t)1 << 60, SEG_DTYPE_FLOAT32, &t) ==
          SEG_ERR_ARGUMENT);
    tr[0] = 5;
    CHECK(seg_seismic_file_read_traces(f, tr, -1, SEG_DTYPE_FLOAT32, &t) == SEG_ERR_ARGUMENT);
    CHECK(seg_seismic_file_read_traces(f, NULL, 1, SEG_DTYPE_FLOAT32, &t) == SEG_ERR_ARGUMENT);
    OK(seg_seismic_file_read_traces(f, NULL, 0, SEG_DTYPE_FLOAT32, &t)); /* empty selection */
    seg_tensor_release(t);
    int64_t len = -1;
    CHECK(seg_seismic_file_component_group_ids(f, 0, 1, NULL, -1, &len) == SEG_ERR_ARGUMENT);
    seg_seismic_file_release(f);
}

static void *init_and_fail(void *arg) {
    (void)arg;
    CHECK(seg_init() == SEG_ABI_VERSION);
    SegSeismicFile *f = (SegSeismicFile *)1;
    CHECK(seg_open_seismic("/nonexistent/zz", false, false, &f) == SEG_ERR_IO && f == NULL);
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
static SegSeismicFile *shared_file;

static void *reader(void *arg) {
    int64_t id = (int64_t)(intptr_t)arg;
    float *buf = malloc(20 * 2001 * sizeof(float));
    SegTensorView b = dest(buf, SEG_DTYPE_FLOAT32, 20, 2001, 2001);
    for (int round = 0; round < 50; round++) {
        int64_t failed = 0;
        int64_t first = (id * 37 + round) % 180;
        if (seg_seismic_file_read_traces_into_range(shared_file, first, first + 19, &b, 0,
                                                    &failed) != SEG_OK || failed != 0) {
            fprintf(stderr, "thread %ld: read failed\n", (long)id);
            failures++;
        }
        SegTensor *t = NULL;
        if (seg_seismic_file_read_traces_range(shared_file, round % 190, round % 190 + 9,
                                               SEG_DTYPE_FLOAT32, &t) == SEG_OK) {
            DLManagedTensor *m = NULL;
            if (seg_tensor_to_dlpack(t, (void **)&m) != SEG_OK) failures++;
            seg_tensor_release(t);
            if (m) m->deleter(m);
        } else failures++;
        /* Serialized calls on the same handle from every thread. */
        SegValue v;
        if (seg_seismic_file_trace_field(shared_file, round % 200, "trace.sourceX", &v) !=
            SEG_OK) failures++;
        int64_t ng = -1;
        if (seg_seismic_file_gathers(shared_file, NULL, 0, &ng) != SEG_OK || ng < 1) failures++;
    }
    free(buf);
    return NULL;
}

static void test_threads(void) {
    shared_file = open_file("BO_3D-Inglewood_rev21_v7.sgy", true);
    pthread_t th[4];
    for (intptr_t i = 0; i < 4; i++) pthread_create(&th[i], NULL, reader, (void *)i);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    seg_seismic_file_release(shared_file);
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
    for (int i = 0; i < 25; i++) seg_seismic_file_release(open_file(name, true));
    if (before >= 0) CHECK(maps_of(name) == before);
    /* first + count overflowed into SEG_ERR_INTERNAL. */
    SegSeismicFile *f = open_file("inova_rev30_5traces.sgd", true);
    int64_t g[1], len = 0;
    CHECK(seg_seismic_file_component_group_ids(f, 5, INT64_MAX, g, 1, &len) == SEG_ERR_ARGUMENT);
    CHECK(seg_seismic_file_component_group_ids(f, 0, (int64_t)1 << 40, g, 1, &len) ==
          SEG_ERR_ARGUMENT);
    SegValue v;
    CHECK(seg_seismic_file_trace_field(f, 1000000, "trace.traceNumber", &v) == SEG_ERR_ARGUMENT);
    seg_seismic_file_release(f);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: abi_test <exampleFiles> <scratch>\n"); return 2; }
    snprintf(dir, sizeof dir, "%s", argv[1]);
    snprintf(tmp, sizeof tmp, "%s", argv[2]);
    test_concurrent_init();
    CHECK(seg_init() == SEG_ABI_VERSION && SEG_ABI_VERSION == 4);
    int32_t abi = 0;
    OK(seg_abi_version(&abi));
    CHECK(abi == SEG_ABI_VERSION);
    char ver[16];
    int64_t len = 0;
    OK(seg_version(ver, sizeof ver, &len));
    CHECK(strcmp(ver, "0.4.0") == 0 && len == 5);
    test_layout();
    test_files();
    test_summary();
    test_listing();
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
