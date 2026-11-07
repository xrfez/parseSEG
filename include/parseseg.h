/*
 * parseseg.h: C ABI of parseSEGD, a SEG-Y / SEG-D reader, indexer and
 * in-place header editor. The library is libparseseg.so, parseseg.dll or
 * libparseseg.dylib.
 *
 * This header is self-contained (C99 / C++). It is hand-written and checked
 * by tests: tests/c/abi_test.c compares every struct's sizeof/offsetof with
 * the library's own (seg_sizeof / seg_offsetof), and every seg_* symbol of
 * the library is declared here. Design notes: docs/design/c_abi.md.
 *
 * ---------------------------------------------------------------------------
 * RULES THAT HOLD FOR EVERY FUNCTION
 *
 * Initialization
 *   Call seg_init() once, from any thread, before anything else. Repeated
 *   calls are harmless. After that, any thread may call into the library.
 *
 * Handles
 *   SegFile, SegTensor, SegPrefetch, SegEditor and SegLog are opaque. A
 *   handle returned through an `out` parameter is owned by the caller, who
 *   must release it with the matching function. Releasing NULL is a no-op.
 *   Using a released handle is undefined behaviour, as with free().
 *
 * Errors
 *   Functions returning SegStatus give SEG_OK (0) on success, a positive
 *   value for a normal non-error outcome (SEG_END, SEG_NOT_READY) and a
 *   negative SEG_ERR_* on failure. After a failure, seg_last_error() holds
 *   the reason. No C++ exception or longjmp ever leaves the library.
 *
 * Diagnostics are not errors
 *   Opening a damaged file succeeds. Every problem found while reading is a
 *   diagnostic entry (severity, code, byte offset, location, message) in the
 *   file's log: see seg_file_log(). A read stops early only when the file is
 *   truncated or I/O fails, and that is logged as SEG_SEV_FATAL.
 *
 * Strings
 *   Strings are UTF-8 and NUL-terminated. A string the library returns is
 *   owned by the handle it came from: it stays valid until that handle is
 *   released or the same accessor is called on it again. Copy it to keep it.
 *
 * Threads
 *   A handle must not be used by two threads at once. The exception is the
 *   seg_read_* functions on one SegFile, which only read the memory map and
 *   may run in parallel. A SegPrefetch decodes on its own worker thread, but
 *   its functions must be called from one thread at a time.
 *
 * Sizes
 *   Counts, trace numbers and offsets are int64_t; files over 4 GB work.
 *   Trace numbers are 0-based positions in the file, in file order.
 *
 * Samples
 *   Samples come as row-major [traces, samples] arrays of float or double
 *   (SEG_F32 / SEG_F64). Shorter traces are zero-padded. A trace whose bytes
 *   cannot be decoded is left as zeros and counted. There are three ways to
 *   get them, all zero-copy:
 *     1. seg_read_*_into: decode into your own buffer (e.g. a numpy array's
 *        data pointer) with any row stride;
 *     2. seg_read_range / seg_read_selection: a new SegTensor, then
 *        seg_tensor_view() for its pointer, shape and strides;
 *     3. seg_tensor_to_dlpack(): a DLManagedTensor for numpy.from_dlpack,
 *        PyTorch, JAX and CuPy.
 * ---------------------------------------------------------------------------
 */
#ifndef PARSESEG_H
#define PARSESEG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- versions -------------------------------------------------------- */

/* The ABI version this header describes. seg_init() returns the library's
   version; refuse to run if they differ. */
#define SEG_ABI_VERSION 1

/* ---- status codes ---------------------------------------------------- */

typedef int32_t SegStatus;
#define SEG_OK            0  /* success */
#define SEG_END           1  /* a prefetcher has delivered every chunk */
#define SEG_NOT_READY     2  /* seg_prefetch_try_next: the next chunk is not decoded yet */
#define SEG_ERR_ARGUMENT (-1) /* NULL pointer, out-of-range index, bad dtype, ... */
#define SEG_ERR_IO       (-2) /* the operating system refused (open, map, read, write) */
#define SEG_ERR_FORMAT   (-3) /* bytes that cannot be decoded */
#define SEG_ERR_STATE    (-4) /* not possible in this state (e.g. keys not collected) */
#define SEG_ERR_REFUSED  (-5) /* an edit was refused; its diagnostic is in the editor's log */
#define SEG_ERR_INTERNAL (-6) /* a library bug; please report seg_last_error() */

/* ---- constants ------------------------------------------------------- */

/* Sample element types. */
#define SEG_F32 1 /* float */
#define SEG_F64 2 /* double */

/* seg_file_open flags (bitwise or). */
#define SEG_OPEN_KEYS      1u /* collect per-trace geometry (keys, gathers), ~100 B/trace */
#define SEG_OPEN_8015_TWOS 2u /* read SEG-D 8015 fractions as two's complement */

/* seg_file_kind results. */
#define SEG_KIND_UNKNOWN 0 /* neither SEG-Y nor SEG-D (see the log) */
#define SEG_KIND_SEGY    1
#define SEG_KIND_SEGD    2

/* SegValue kinds. */
#define SEG_VALUE_INT   1
#define SEG_VALUE_FLOAT 2
#define SEG_VALUE_TEXT  3

/* Diagnostic severities (SegDiagnostic.severity); later is worse. */
#define SEG_SEV_INFO    0 /* noteworthy but valid */
#define SEG_SEV_WARNING 1 /* spec-invalid or suspicious, but decoded */
#define SEG_SEV_ERROR   2 /* a part could not be decoded and was kept raw */
#define SEG_SEV_FATAL   3 /* the read had to stop early */

/* Gather kinds (SegGather.kind). Derived from the geometry, never assumed. */
#define SEG_GATHER_UNKNOWN  0 /* the keys cannot tell */
#define SEG_GATHER_SHOT     1 /* common source */
#define SEG_GATHER_RECEIVER 2 /* common receiver */
#define SEG_GATHER_CMP      3 /* common midpoint / stack (declared by a SEG-Y sorting code) */
#define SEG_GATHER_OFFSET   4 /* common offset (declared by a SEG-Y sorting code) */
#define SEG_GATHER_OTHER    5 /* several sources and several receivers */

/* ---- opaque handles -------------------------------------------------- */

typedef struct SegFile SegFile;         /* a memory-mapped file and its trace index */
typedef struct SegTensor SegTensor;     /* a 2-D sample array owned by the library */
typedef struct SegPrefetch SegPrefetch; /* read-ahead on a worker thread */
typedef struct SegEditor SegEditor;     /* in-place header edits with an undo journal */
typedef struct SegLog SegLog;           /* a list of diagnostics */

/* ---- structs (filled by the library through out pointers) ------------ */

/* Where one trace lives (24 bytes, the index entry itself). */
typedef struct SegTraceEntry {
    int64_t  offset;       /* byte offset of the trace header in the file */
    uint32_t header_bytes; /* header bytes before the samples (extensions included) */
    uint32_t num_samples;
    uint32_t record;       /* SEG-D record index (0 for SEG-Y) */
    uint16_t channel_set;  /* SEG-D channel set index; 0xFFFF = unknown / SEG-Y */
    int8_t   scan_type;    /* SEG-D scan type index; -1 = unknown / SEG-Y */
    uint8_t  channel_type; /* SEG-D channel type (Rev 1/2: 1 = seismic; Rev 3: 0x10 = seismic) */
} SegTraceEntry;

/* A trace's geometry (with SEG_OPEN_KEYS). NaN or 0 where unknown. */
typedef struct SegTraceKeys {
    double  record;     /* SEG-Y field record; SEG-D file number */
    double  ensemble;   /* SEG-Y ensemble (CDP) number */
    double  offset;     /* SEG-Y source-receiver offset */
    double  src_line, src_point;
    double  src_x, src_y;
    double  rcv_line, rcv_point;
    double  rcv_x, rcv_y;
    int16_t src_index, rcv_index;    /* SEG-D point indices */
    uint8_t depth_index, reshoot_index; /* SEG-D Rev 3 THE#1 bytes 10 and 8 */
    uint8_t sensor_type;  /* SEG-D THE#1 byte 21 */
    uint8_t component;    /* distinguishes the components of one station */
} SegTraceKeys;

/* A typed header value. `text` is owned by the SegFile it came from and holds
   the field's characters as stored (EBCDIC or ASCII as in the file); a field
   padded with NUL bytes reads shorter than its width. */
typedef struct SegValue {
    int32_t     kind; /* SEG_VALUE_INT, SEG_VALUE_FLOAT or SEG_VALUE_TEXT */
    int32_t     reserved;
    int64_t     i;    /* SEG_VALUE_INT */
    double      f;    /* SEG_VALUE_FLOAT (also set, as a double, for ints) */
    const char *text; /* SEG_VALUE_TEXT */
} SegValue;

/* A tensor's memory: data[r * strides[0] + c * strides[1]] is row r, sample c. */
typedef struct SegTensorView {
    void   *data;       /* float* or double* per dtype; NULL for an empty tensor */
    int32_t dtype;      /* SEG_F32 or SEG_F64 */
    int32_t rank;       /* always 2 */
    int64_t shape[2];   /* traces, samples */
    int64_t strides[2]; /* in elements, not bytes */
} SegTensorView;

/* A gather: the traces first .. first + count - 1. */
typedef struct SegGather {
    int32_t kind;      /* SEG_GATHER_* */
    int32_t reserved;
    int64_t first, count;
    int64_t sources;   /* distinct known sources among its seismic traces */
    int64_t receivers; /* distinct known receiver stations among its seismic traces */
} SegGather;

/* One diagnostic. Strings are owned by the SegLog. -1 means not applicable. */
typedef struct SegDiagnostic {
    int32_t     severity;  /* SEG_SEV_* */
    int32_t     code;      /* stable catalog index; code_name is its stable spelling */
    int64_t     offset;    /* byte offset in the file */
    int64_t     record, channel_set, trace, block_index;
    const char *file;
    const char *field;     /* e.g. "trace.numSamples" */
    const char *message;
    const char *code_name; /* e.g. "truncated", "badValue" */
} SegDiagnostic;

/* One prefetched chunk. `samples` is owned by the caller: release it. */
typedef struct SegChunk {
    int64_t    first;  /* position of the first row (its trace number, or its index
                          in the selection: see seg_prefetch_trace_at) */
    int64_t    count;  /* rows */
    int64_t    failed; /* rows that could not be decoded (left zero) */
    SegTensor *samples;
} SegChunk;

/* ---- DLPack v0.8 (https://github.com/dmlc/dlpack) -------------------- */
#ifndef DLPACK_VERSION
typedef struct { int32_t device_type; int32_t device_id; } DLDevice; /* CPU = 1 */
typedef struct { uint8_t code; uint8_t bits; uint16_t lanes; } DLDataType; /* float = 2 */
typedef struct {
    void      *data;
    DLDevice   device;
    int32_t    ndim;
    DLDataType dtype;
    int64_t   *shape;
    int64_t   *strides;     /* in elements */
    uint64_t   byte_offset;
} DLTensor;
typedef struct DLManagedTensor {
    DLTensor dl_tensor;
    void    *manager_ctx;
    void   (*deleter)(struct DLManagedTensor *self);
} DLManagedTensor;
#endif

/* ---- library --------------------------------------------------------- */

/* Initializes the library (runs the Nim runtime once). Returns the
   library's ABI version, to compare with SEG_ABI_VERSION. */
int32_t seg_init(void);
int32_t seg_abi_version(void);
const char *seg_version(void);         /* package version, e.g. "0.2.0" */
const char *seg_last_error(void);      /* this thread's last failure ("" if none) */
const char *seg_status_name(SegStatus status); /* "SEG_OK", "SEG_ERR_IO", ... (static) */

/* ---- files ----------------------------------------------------------- */

/* Opens and memory-maps a SEG-Y or SEG-D disk file, detects which it is,
   and indexes every trace by reading headers only (fast even for 40 GB
   files). Format problems do not fail the open: see seg_file_log() and
   seg_file_kind(). Fails with SEG_ERR_IO if the file cannot be opened. */
SegStatus seg_file_open(const char *path, uint32_t flags, SegFile **out);

/* Releases the caller's reference. The map closes once no SegPrefetch uses
   the file any more. */
void seg_file_release(SegFile *file);

int32_t seg_file_kind(const SegFile *file);          /* SEG_KIND_* */
int64_t seg_file_trace_count(const SegFile *file);   /* -1 for NULL */
int64_t seg_file_record_count(const SegFile *file);  /* SEG-D records; 1 for SEG-Y */
int64_t seg_file_max_samples(const SegFile *file);   /* the longest trace */

SegStatus seg_file_trace_entry(const SegFile *file, int64_t trace, SegTraceEntry *out);

/* SEG_ERR_STATE unless the file was opened with SEG_OPEN_KEYS. */
SegStatus seg_file_trace_keys(const SegFile *file, int64_t trace, SegTraceKeys *out);

/* The trace's sample interval in microseconds (SEG-Y non-time data: its
   unit); NaN if unknown. */
double seg_file_sample_interval(const SegFile *file, int64_t trace);

/* The file's diagnostics, borrowed: valid until the file is released.
   Do not release it. */
SegLog *seg_file_log(SegFile *file);

/* ---- header fields by name ------------------------------------------- */
/* Names are "<block>.<field>", the field names of the library's header
   types (see docs/api.md):
     SEG-Y   per trace:  trace.sourceX, trace.numSamples, ext1.extSourceX, ...
             per file:   binary.sampleInterval, binary.jobId, ...
     SEG-D   per trace:  trace.traceNumber, ext1.receiverPointNumber, ...
             per record: gh1.year, gh3.sourcePointNumber (Rev 1/2), ...
   Values are read from the file, so they reflect in-place edits at once.
   Unknown names or blocks give SEG_ERR_ARGUMENT with the reason. */
SegStatus seg_trace_field(SegFile *file, int64_t trace, const char *name, SegValue *out);
SegStatus seg_record_field(SegFile *file, int64_t record, const char *name, SegValue *out);
SegStatus seg_file_field(SegFile *file, const char *name, SegValue *out);

/* ---- reading samples ------------------------------------------------- */
/* `cols` is the samples per row: longer traces are cut and shorter ones
   zero-padded; -1 means the longest trace read. A "selection" is a list of
   trace numbers read in list order (a gather, a component group, a sort
   order); repeats are allowed. */

/* Traces first .. first + count - 1 as a new tensor. */
SegStatus seg_read_range(SegFile *file, int64_t first, int64_t count, int32_t dtype,
                         int64_t cols, SegTensor **out);
SegStatus seg_read_selection(SegFile *file, const int64_t *traces, int64_t n, int32_t dtype,
                             int64_t cols, SegTensor **out);

/* Decode into your own buffer: row k is at buffer + k * row_stride elements
   and holds `cols` samples (cols >= 0, row_stride >= cols). The buffer must
   hold count (or n) rows. `failed` (may be NULL) receives the number of rows
   that could not be decoded; they are zero, and seg_last_error() describes
   the first one. */
SegStatus seg_read_range_into(SegFile *file, int64_t first, int64_t count, int32_t dtype,
                              void *buffer, int64_t cols, int64_t row_stride, int64_t *failed);
SegStatus seg_read_selection_into(SegFile *file, const int64_t *traces, int64_t n,
                                  int32_t dtype, void *buffer, int64_t cols,
                                  int64_t row_stride, int64_t *failed);

/* ---- tensors --------------------------------------------------------- */

/* Pointer, dtype, shape and strides; valid until seg_tensor_release(). */
SegStatus seg_tensor_view(const SegTensor *tensor, SegTensorView *out);

/* A DLPack tensor sharing the samples. It holds its own reference: you may
   release `tensor` afterwards. The consumer calls out->deleter(out) once.
   NULL on failure. */
DLManagedTensor *seg_tensor_to_dlpack(SegTensor *tensor);

void seg_tensor_release(SegTensor *tensor);

/* ---- gathers and components (need SEG_OPEN_KEYS) --------------------- */

SegStatus seg_file_gather_count(SegFile *file, int64_t *count);
SegStatus seg_file_gather(SegFile *file, int64_t index, SegGather *out);

/* Groups the seismic traces of first .. first + count - 1 by (source,
   receiver station, depth, reshoot): group_of[k] receives the group of trace
   first + k, or -1 for auxiliary traces. `groups` (may be NULL) receives the
   number of groups. group_of must hold `count` entries. */
SegStatus seg_component_groups(SegFile *file, int64_t first, int64_t count, int64_t *group_of,
                               int64_t *groups);

/* ---- read-ahead ------------------------------------------------------ */
/* A worker thread decodes chunks of `chunk_traces` rows, at most `depth`
   chunks ahead, so a viewer never waits on the disk. seg_prefetch_try_next
   never blocks. Positions are trace numbers (seg_prefetch_open) or indices
   into the selection (seg_prefetch_open_selection). The prefetcher keeps
   its file alive. */

/* Traces first .. last - 1 (last = -1: to the end). */
SegStatus seg_prefetch_open(SegFile *file, int64_t first, int64_t last, int64_t chunk_traces,
                            int64_t depth, int64_t cols, int32_t dtype, SegPrefetch **out);
SegStatus seg_prefetch_open_selection(SegFile *file, const int64_t *traces, int64_t n,
                                      int64_t chunk_traces, int64_t depth, int64_t cols,
                                      int32_t dtype, SegPrefetch **out);

/* SEG_OK with a chunk (release out->samples), SEG_NOT_READY, or SEG_END. */
SegStatus seg_prefetch_try_next(SegPrefetch *prefetch, SegChunk *out);
/* As try_next, but waits for the chunk: SEG_OK or SEG_END. */
SegStatus seg_prefetch_next(SegPrefetch *prefetch, SegChunk *out);
/* Restarts at position `first` (to `last`, -1 = the end); chunks decoded
   for the old position are dropped. */
SegStatus seg_prefetch_seek(SegPrefetch *prefetch, int64_t first, int64_t last);
/* The trace number at a position; -1 if out of range. */
int64_t seg_prefetch_trace_at(const SegPrefetch *prefetch, int64_t position);
/* Stops and joins the worker. */
void seg_prefetch_release(SegPrefetch *prefetch);

/* ---- in-place header edits ------------------------------------------- */
/* The file is mapped read-write. Each edit changes one field in place: the
   value is checked against the field's width, BCD digits and range, fields
   that size the file's structure (sample counts, formats, header counts,
   ...) are refused, and the original bytes are written (and flushed) to the
   journal before the file changes. Field names are as for seg_trace_field.
   A refused edit returns SEG_ERR_REFUSED and leaves the file unchanged. */

/* `journal` NULL means path + ".edits.nif". */
SegStatus seg_editor_open(const char *path, const char *journal, SegEditor **out);
SegStatus seg_editor_set_trace(SegEditor *editor, int64_t trace, const char *name,
                               const SegValue *value);
SegStatus seg_editor_set_record(SegEditor *editor, int64_t record, const char *name,
                                const SegValue *value);
SegStatus seg_editor_set_file(SegEditor *editor, const char *name, const SegValue *value);
int64_t   seg_editor_edits(const SegEditor *editor); /* edits written so far */
SegLog   *seg_editor_log(SegEditor *editor);         /* borrowed, like seg_file_log */
/* Flushes the file and journal, then releases the editor. */
SegStatus seg_editor_close(SegEditor *editor);

/* Undo (newest first) or redo (oldest first) a journal's edits. Both can be
   repeated safely; locations changed by someone else are left alone and
   reported. Returns SEG_ERR_STATE if some entries could not be applied, and
   SEG_ERR_IO if the file or journal cannot be used. `log` (may be NULL)
   receives an owned log: release it. */
SegStatus seg_journal_rollback(const char *path, const char *journal, SegLog **log);
SegStatus seg_journal_apply(const char *path, const char *journal, SegLog **log);

/* ---- diagnostics ----------------------------------------------------- */

int64_t   seg_log_count(const SegLog *log);
int64_t   seg_log_count_severity(const SegLog *log, int32_t severity);
SegStatus seg_log_get(const SegLog *log, int64_t index, SegDiagnostic *out);
const char *seg_log_nif(SegLog *log); /* the whole log as NIF text */
/* Releases an owned log (from seg_journal_*). A no-op for borrowed logs. */
void seg_log_release(SegLog *log);

/* ---- layout self-test ------------------------------------------------ */
/* The library's sizeof / offsetof for the structs above (C field names), so
   a host can check that it was built against a matching header; -1 for
   unknown names. */
int64_t seg_sizeof(const char *type_name);
int64_t seg_offsetof(const char *type_name, const char *field_name);

#ifdef __cplusplus
}
#endif

#endif /* PARSESEG_H */
