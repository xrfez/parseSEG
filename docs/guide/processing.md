# Recipes for signal processing

A processing library wants every trace of a file as dense arrays, as fast as the disk allows,
on as many cores as it has, and then a way to write its results. This page shows how. Read
[getting-started.md](getting-started.md) first for the model.

Two facts shape everything here:

- **Nothing loads a whole file.** `openSeismic` maps the file and indexes it (24 bytes per
  trace, plus 184 with `keys`); samples are decoded only for the traces you ask for,
  straight from the mapped bytes into your tensor. Files larger than RAM work: the OS pages
  them in and out. (`readSegy`/`readSegd` do load everything; they are for small files and
  tests.)
- **Samples are the recorded values**, decoded to `float32` or `float64`: integer and SEG-D
  formats are not descaled to physical units. `convertFile` with `applyDescale` writes
  millivolts if you need them ([conversion.md](conversion.md)).

## Stream a whole file in chunks

The simplest loop reuses one buffer: decode a chunk, process it, go on. Each chunk costs no
allocation.

```nim
import parseSEG

var f = openSeismic("survey.sgy")
const Chunk = 64
var buf = newTraceTensor[float64](Chunk, f.maxSamples)   # float64: room for any format
var log: DiagLog
var energy = 0.0
var first = 0
while first < f.len:
  let last = min(first + Chunk, f.len) - 1
  let rows = last - first + 1
  discard f.readTracesInto(first .. last, buf, 0, log)
  # Only rows 0 ..< rows hold this chunk: the last chunk may be short.
  energy += sum(buf[0 ..< rows, _] *. buf[0 ..< rows, _])
  first = last + 1
echo "total energy ", energy, ", ", log.len, " traces could not be decoded"
doAssert log.len == 0 and energy > 0
```

`readTracesInto` returns how many traces it left as zero rows because they could not be
decoded, and logs each one (trace index, byte offset, reason) in `log`. Without a `log`
argument it only counts them; `readTraces` without a log raises `SegFormatError` instead.
To skip the damaged rows while processing, pass a `var seq[int]` instead of the log: it is
cleared and gets the position of each trace left zero (0-based in `traces`, ascending, as
`PrefetchChunk.failedRows`), and a list reused across chunks does not allocate. Pick the
form that matches your policy for damaged data.

### Overlap decoding with computing

A `Prefetcher` decodes the next chunks on a worker thread while you process the current one.
`chunks` (or `next` in a loop) waits for each chunk; each chunk's tensor is yours to keep.

```nim
import parseSEG

var f = openSeismic("survey.sgy")
var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 64, depth = 3)
var peak = 0'f32
var traces = 0
for c in p.chunks:
  peak = max(peak, max(abs(c.samples)))
  traces += c.count - c.failed
p.close()                     # stops and joins the worker
echo traces, " traces, peak amplitude ", peak
doAssert traces == f.len and peak > 0
```

Memory: a prefetcher holds `depth` chunks of `chunkTraces × cols` samples. A loop that is done with
each chunk before the next can give the buffers back (`nextInto`, `recycle(p, move c)`), so
it allocates nothing ([viewer.md](viewer.md#recycle-the-chunk-buffers)).

### Skip auxiliary traces, respect each trace's interval

SEG-D records mix seismic and auxiliary channel sets (time break, pilot, ...), possibly at
different sample intervals. Select the seismic traces with `isSeismic`, and take intervals
per trace or per channel set rather than per file.

```nim
import parseSEG

var f = openSeismic("shot.sgd")
var seismic: seq[int]
for i in 0 ..< f.len:
  if isSeismic(f.index, i): seismic.add i
let data = f.readTraces(seismic, float64)
for k, i in seismic:
  echo "trace ", i, ": ", f.sampleIntervalUs(i), " us, ", f.traceEntry(i).numSamples,
    " samples, rms ", sqrt(mean(data[k, _] *. data[k, _]))
doAssert seismic == @[3, 4] and data.shape == [2, 4001]
```

### Per-trace metadata in place: `TraceRows`

The stored keys (`keys = true`) are the one copy of per-trace metadata: offset, start time
(`t0Ms`), interval (`intervalUs`), status (live, dead or auxiliary), inline and crossline,
next to the geometry. A `TraceRows` view says which trace each row of a sample block is and
reads those keys in place, with no copy; it holds raw pointers only, so it can be handed to
worker threads. A prefetch chunk carries one (`c.rows`), and with `uniform = true` no chunk
mixes channel sets or sample intervals, so each has one `dt`.

```nim
import parseSEG

var f = openSeismic("shot.sgd", keys = true)
var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 8, uniform = true)
var live = 0
for c in p.chunks:
  for row in 0 ..< c.count:
    let k = c.rows.traceKeys(row)          # in place: nothing is copied
    if k.status == tsLive:
      inc live
      echo "trace ", c.rows.traceOf(row), ": offset ", k.offset, " m, t0 ", k.t0Ms,
        " ms, dt ", k.intervalUs, " us, ", c.rows.numSamples(row), " samples"
p.close()
doAssert live == 2

# Without a prefetcher: runs of traces that share a channel set, interval and length.
for run in f.uniformRuns(0 ..< f.len):
  let x = f.readTraces(run)               # one dt, no padding
  doAssert x.shape[1] == int(f.traceEntry(run.a).numSamples)

# Synthetic data needs no file: a view over the caller's own arrays.
var keys = @[initTraceKeys(), initTraceKeys()]
keys[1].offset = 25
let rows = rowsOf(keys, [100, 100])
doAssert rows.len == 2 and rows.traceKeys(1).offset == 25
```

A `transform` hook (`ChunkTransform`, a `{.nimcall.}` proc with a `user` pointer) processes
each chunk on its worker thread right after decoding, while the samples are still in the CPU
cache. A transform must not raise, so it reads keys with `keysAt(row)`, the non-raising
form of `traceKeys` for code that has checked `hasKeys` once (a view without keys is then a
programming error, an `AssertionDefect` with bound checks on). A `Defect` raised in a
transform ends the process (it is raised on a worker thread, where nothing can catch it), so
the kernels a transform calls must be free of Defects for any input: check sizes and
`hasKeys` before the prefetcher is made. Files opened without keys can build them later with
`ensureKeys`; views and prefetchers made before that call stay without keys, so make them
again. `keysRevision` goes
up whenever keys change (a survey join, a header edit), so derived data can be tagged with it.
SEG-Y datum and statics fields come per trace from `traceStatics(f, traces)`.

## Read in parallel

`readTraces` and `readTracesInto` on one open `SeismicFile` may run on many threads at once:
they only read the map and the index. Share the file by pointer, give each thread its own
tensor and log, and do not close the file or change its index (`applySurvey`) until every
thread has finished. Compile with `--threads:on` (Nim 2's default).

```nim
import std/typedthreads
import parseSEG

type Job = object
  file: ptr SeismicFile
  traces: Slice[int]
  sumAbs: float64
  failed: int

proc work(job: ptr Job) {.thread.} =
  # Each thread decodes its own share into its own buffer.
  var buf = newTraceTensor[float32](32, job.file[].maxSamples)
  var log: DiagLog
  var first = job.traces.a
  while first <= job.traces.b:
    let last = min(first + 31, job.traces.b)
    job.failed += job.file[].readTracesInto(first .. last, buf, 0, log)
    job.sumAbs += sum(abs(buf[0 .. last - first, _].astype(float64)))
    first = last + 1

var f = openSeismic("survey.sgy")
const Workers = 4
var jobs: array[Workers, Job]
var threads: array[Workers, Thread[ptr Job]]
let share = (f.len + Workers - 1) div Workers
for k in 0 ..< Workers:
  jobs[k] = Job(file: addr f, traces: k * share .. min(f.len, (k + 1) * share) - 1)
  createThread(threads[k], work, addr jobs[k])
joinThreads(threads)

var total = 0.0
for j in jobs: total += j.sumAbs
let serial = sum(abs(f.readTraces(0 ..< f.len).astype(float64)))
echo "parallel ", total, " = serial ", serial
doAssert abs(total - serial) <= 1e-9 * serial
```

Splitting by trace ranges keeps each thread's reads sequential on disk, which is what the OS
read-ahead likes. Splitting by gather (`f.gathers`, with `keys = true`) works the same way.

Size each thread's buffer for the CPU cache. From about 4 threads, decoding IEEE, int16 or
SEG-D 8058 runs at memory bandwidth (about 49 GB/s on a dual-channel DDR4-3200 machine), so
more threads add nothing for those formats; IBM float and SEG-D 8015/8024 keep scaling to
16 threads and more. When you run one thread per SMT thread, two threads share each core's
L2 cache (512 KB on AMD Zen 2), so keep each thread's tensor at about 256 KB (64 traces of
1000 float32 samples). With 1 MB tensors, 32 threads fell to 32 GB/s; with 256 KB tensors
they held 47 GB/s.

## Write results

### Write like the input

`openSeismicWriter(path, like = f)` writes a file in `f`'s standard, revision and byte order,
with `f`'s file headers; `writeTrace(w, f, i, samples)` writes trace `i` of `f` with its
headers and your samples, encoded in the file's format. Only what the samples change is
changed. `close` writes the final counts and renames the output into place: until then the
output is a temporary file, and a writer dropped without `close` leaves nothing behind. The
same code works for SEG-Y, SEG-D and SEG-2.

Failures raise, and a failed output never appears under its name: `close` returns the
writer's warnings and raises for everything else (a full disk shows at the latest there, as
`IOError`), and a `writeTrace` that raised `IOError` has already discarded the output and
closed the writer.

```nim
import std/os
import parseSEG

for input in ["survey.sgy", "shot.sgd", "line.sg2"]:
  var f = openSeismic(input)
  let output = "gain_" & input.extractFilename
  var w = openSeismicWriter(output, like = f)
  const Chunk = 64
  var buf = newTraceTensor[float64](Chunk, f.maxSamples)
  var first = 0
  while first < f.len:
    let last = min(first + Chunk, f.len) - 1
    discard f.readTracesInto(first .. last, buf)
    buf.apply_inline(2 * x)                     # the "processing": a gain of 2
    for i in first .. last: w.writeTrace(f, i, buf, i - first)  # row i - first
    first = last + 1
  for d in w.close(): echo d                    # warnings; a failure raises

  var g = openSeismic(output)
  let (a, b) = (f.readTraces(0 ..< f.len, float64), g.readTraces(0 ..< g.len, float64))
  echo output, ": ", g.len, " traces, largest error ", max(abs(b - 2.0 * a))
  doAssert g.len == f.len and max(abs(b - 2.0 * a)) <= 1e-6 * max(abs(b))
```

Options and rules:

- **Sample format.** `openSeismicWriter(path, f, segyFormat = st5)` (or `segdFormat = tf8048`,
  `seg2Format = s2t4`, for the input's standard) writes another format; the format code is
  the only header change (SEG-D Rev 3 also updates General Header #3's sizes). A value the
  format cannot hold raises `SegFormatError` and writes nothing; nothing is clamped. That
  is a value beyond the range of an integer format or of the SEG-D exponent formats (8015
  ends at ±32767, 8022 at ±15360, 8024 at ±16380, 8042 at 3968, 8044 at 4095.5), and NaN or
  an infinity in every format but the IEEE floats (SEG-Y 5 and 6, SEG-D 8058 and 8080,
  SEG-2 4 and 5). SEG-D 8015 packs four samples into ten bytes, so it is refused for
  traces whose sample count is not a multiple of 4.
- **Sample count.** A SEG-Y or SEG-2 trace may get more or fewer samples than it had (the
  tensor form takes `count = n`: the first `n` of the row). The trace header follows, and
  the SEG-Y binary header gets the count of the traces written (the largest when they
  differ). A fixed-length SEG-Y file needs one count for all traces. A SEG-D trace keeps
  its count: its channel set descriptor holds it.
- **Which traces.** SEG-Y and SEG-2 traces can be written in any order and any subset (a
  declared Rev 2 trace count becomes the number written). SEG-D records are written
  whole, each record's traces in input order: a record ends when a trace of another record
  arrives, or at `close`, and must then be complete. Records may be skipped or reordered.
  Multiplexed SEG-D is refused: convert it to a demultiplexed file first.
- **Errors.** Caller mistakes raise `ValueError` and write nothing: a trace out of range,
  another standard, a closed file, a broken SEG-D rule. Spec-invalid output raises
  `SegFormatError`, as with the per-standard writers. An output path that is a directory
  is refused when the writer opens (`IOError`).

```nim
import parseSEG

# Keep the first 1000 samples of each trace: the headers follow.
var f = openSeismic("survey.sgy")
var w = openSeismicWriter("survey_1000.sgy", like = f)
let x = f.readTraces(0 ..< f.len)
for i in 0 ..< f.len: w.writeTrace(f, i, x, i, count = 1000)
discard w.close()
var g = openSeismic("survey_1000.sgy")
doAssert g.maxSamples == 1000 and g.fileField("binary.samplesPerTrace").intVal == 1000
```

### Streaming SEG-Y (tape, or without an index)


The streaming SEG-Y reader and writer pass every header through unchanged. Decode a trace's
samples, process them, encode them back in the file's format, and write the trace. The
output is a valid SEG-Y file with the input's headers (the writer validates before it
writes and refuses spec-invalid output unless `lenient`).

```nim
import std/options
import parseSEG

var src = openDiskSource("survey.sgy")
var r = openSegy(src)
let fmt = r.file.format.get                  # format 1 (IBM float) in this file
var sink = openDiskSink("survey_gain.sgy")
var w = openSegyWriter(sink, r.file, initSegyWriteOptions(r.file))
var t: SegyTrace
var x: seq[float32]
while r.readTrace(t):
  x.setLen t.numSamples
  decodeSamples(fmt, t.samples, x, r.file.byteOrder)
  for v in x.mitems: v *= 2                  # the "processing": a gain of 2
  encodeSamples(fmt, x, t.samples, r.file.byteOrder)
  w.writeTrace(t)
w.close()
sink.close()
src.close()
for d in r.log: echo d
for d in w.log: echo d

var a = openSeismic("survey.sgy")
var b = openSeismic("survey_gain.sgy")
let (before, after) = (a.readTraces(100..100), b.readTraces(100..100))
echo "largest change from an exact gain of 2: ", max(abs(after - 2'f32 * before))
doAssert b.len == a.len and max(abs(after - 2'f32 * before)) <= 1e-6 * max(abs(after))
```

To write another sample format, give the writer a copy of the file headers with the new
format code, and encode each trace in that format:

```nim
import std/options
import parseSEG

var src = openDiskSource("survey.sgy")
var r = openSegy(src)
let inFormat = r.file.format.get
var outFile = r.file                       # the headers, with IEEE float samples
outFile.binary.formatCode = 5
outFile.format = some(sfFloat32)
var sink = openDiskSink("survey_f32.sgy")
var w = openSegyWriter(sink, outFile, initSegyWriteOptions(outFile))
var t: SegyTrace
var x: seq[float32]
while r.readTrace(t):
  x.setLen t.numSamples
  decodeSamples(inFormat, t.samples, x, r.file.byteOrder)
  t.samples.setLen t.numSamples * sampleSize(sfFloat32)
  encodeSamples(sfFloat32, x, t.samples, outFile.byteOrder)
  w.writeTrace(t)
w.close()
sink.close()
src.close()

var a = openSeismic("survey.sgy")
var b = openSeismic("survey_f32.sgy")
doAssert b.summary.formatCode == 5 and b.readTraces(0 ..< b.len) == a.readTraces(0 ..< a.len)
```

`encodeSamples` raises `SegFormatError` for a value the format cannot hold: out of range
or NaN in an integer format, NaN or an infinity in IBM float (format 1). It raises
`ValueError` when the destination is too short. A disk sink's `close` raises `IOError`
when the last bytes did not reach the file.

### Derived traces from a template trace

`writeTrace` takes header `overrides`: a stacked or otherwise derived trace is written with
a source trace's headers and its own CDP, fold, offset or coordinates (field names as the
editor uses them, values as stored).

```nim
import parseSEG

var f = openSeismic("survey.sgy")
let stack = f.readTraces(0 ..< 1)          # stands in for a computed stack trace
var w = openSeismicWriter("stack.sgy", like = f)
w.writeTrace(f, 0, stack, 0, overrides = [headerOverride("trace.ensembleNumber", 9001),
  headerOverride("trace.numHorzStacked", 48), headerOverride("trace.offset", 0)])
discard w.close()
var g = openSeismic("stack.sgy", keys = true)
doAssert g.len == 1 and g.traceKeys(0).ensemble == 9001
```

### Traces from keys, without a template

A stack of SEG-D or SEG-2 data has no SEG-Y trace to serve as a template. A writer opened
with `SegyOutputOptions` (revision, byte order, sample format, textual header lines, the
binary header's trace sorting and measurement system) takes traces built from `TraceKeys`:
`writeTrace(w, keys, samples, overrides)` fills the standard layout's fields from the keys
(record, channel, CDP, offset, source point, coordinates, elevations, midpoint, start time
with a time scalar, interval, recording time, inline and crossline), which `openSeismic`
reads back as the same keys; overrides then set the rest (the fold, say). The first trace
sets the binary header's interval; its count is that of the traces written (the largest
when they differ).

An interval within 1e-9 of a whole number of microseconds is written as that number (1001 µs
kept as 1.001 ms and multiplied back is 1000.9999999999999). Rev 0 and Rev 1 hold whole
intervals up to 65535 µs only, and Rev 0 has fewer fields: the start time is a whole
millisecond within ±32767 (a later one is refused, as a fractional interval is), a
fractional source point is rounded, and the midpoint, inline and crossline are not written
(the midpoint reads back as halfway between source and receiver).

```nim
import parseSEG

var f = openSeismic("shot.sgd", keys = true)
let x = f.readTraces(3 .. 3)            # stands in for a computed stack trace
var k = f.traceKeys(3)                  # its geometry, as the template
k.ensemble = 1201
k.offset = 0
var w = openSeismicWriter("shot_stack.sgy", SegyOutputOptions(text: @["BRUTE STACK"],
  traceSorting: 4))
var row = newSeq[float32](int(f.traceEntry(3).numSamples))
for j in 0 ..< row.len: row[j] = x[0, j]
w.writeTrace(k, row, overrides = [headerOverride("trace.numHorzStacked", 12)])
discard w.close()
var g = openSeismic("shot_stack.sgy", keys = true)
doAssert g.kind == skSegy and g.traceKeys(0).ensemble == 1201
doAssert g.traceKeys(0).cmpX == k.cmpX and g.traceKeys(0).intervalUs == k.intervalUs
```

### Results that belong in the headers

Picks, statics, or computed coordinates that fit existing header fields can be written in
place, journaled and undoable, without rewriting the file: see [editing.md](editing.md).

## Batch conversions with progress and cancel

`convertFile`, `convertSegdRevision`, `convertWithGeometry` and `copyWithGeometry` take a
`Progress` hook as their last parameter (`progress`). It is called with the input bytes
done and the input's size, about every MiB and once at the end; a conversion that reads its
input twice (a header scan first, SEG-2 input) spreads both passes over one `0 .. total`
run. Returning false cancels: the conversion stops, the returned log holds a fatal
`dcCancelled` diagnostic, and no output is left (an existing `dst` stays as it was). These
procs never raise, so a batch job checks the log, not an exception.

```nim
import std/os
import parseSEG

type Job = ref object
  name: string
  lastPercent: int
  stop: bool                  # set by a signal handler, a UI, a deadline ...

proc hook(job: Job): Progress =
  # gcsafe: the closure captures the `ref` parameter, not a global.
  proc (done, total: int64): bool =
    if total > 0: job.lastPercent = int(done * 100 div total)
    not job.stop

let inputs = ["shot.sgd",
  "survey.sgy", "record.sgd"]
for k, input in inputs:
  let job = Job(name: input.extractFilename, stop: k == 2)  # cancel the last one
  let output = "batch_" & job.name.changeFileExt("sgy")
  let log = convertFile(input, output, ConvertOptions(), hook(job))
  if log.isFatal:
    for d in log:
      if d.code == dcCancelled: echo job.name, ": cancelled, nothing written"
    doAssert not fileExists(output)
  else:
    echo job.name, ": done (", job.lastPercent, "%)"
    doAssert job.lastPercent == 100 and fileExists(output)
```

`convertSegdRevision(src, dst, opts, progress)`, `convertWithGeometry(src, dst, g, opts,
fields, overwrite, progress)` and `copyWithGeometry(src, dst, g, fields, overwrite,
progress)` take the hook in the same place and report a cancel the same way
(`copyWithGeometry` in `result.log`). `openSeismic` and `exportHeaders` raise
`SegCancelledError` instead ([viewer.md](viewer.md#open-a-file-progress-cancel-and-an-index-cache)).

## Geometry for processing

`openSeismic(path, keys = true)` gives each trace's source and receiver positions, offset
and midpoint (`traceKeys`). SEG-D 2.x headers often lack coordinates; join them from SPS or
SEG P1 survey files in memory with `applySurvey` ([conversion.md](conversion.md)), then read
the keys as usual. `gathers` and `componentGroupIds` group the traces by what the keys say.

## Sizes and limits

- All offsets are 64-bit; files over 4 GB are tested (sparse synthetic files).
- Index memory: 24 B per trace, plus 184 B with keys (10 M traces: 240 MB, or 2.1 GB with keys).
- A tensor holds only what you asked for; size your chunks to your cache and core count.
- Tape: `buildIndex` and the streaming readers work on tape images and devices, but range
  reads and the prefetcher need a plain disk file (`ValueError` otherwise).
