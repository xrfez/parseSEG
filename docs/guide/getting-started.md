# Getting started

This page takes you from nothing to decoded samples, and explains the model that every
other guide builds on.

## Build and import

parseSEG needs Nim 2.4 and Arraymancer (the dependency checkouts are pinned in `atlas.lock`;
on a fresh clone run `atlas rep atlas.lock`). From Nim, add `src/` to the search path and
`import parseSEG`: the umbrella module re-exports the whole public API (`docs/api.md`).

```sh
nim test                # the test suite, these guides' examples included
nim cli                 # bin/parseSEG (command line tool)
```

The examples use the sample files in `SEG Spec/exampleFiles/`:

| File | What it is |
|---|---|
| `63.sgd` | SEG-D Rev 2.0, one record with one trace (format 8058) |
| `inova_rev30_5traces.sgd` | SEG-D Rev 3.0, one record: 3 auxiliary and 2 seismic traces, 4001 samples at 1 ms |
| `Sweep0.sgy` | SEG-Y Rev 0, little-endian, one 12001-sample sweep trace |
| `BO_3D-Inglewood_rev21_v7.sgy` | SEG-Y Rev 2.1, 200 post-stack traces of 2001 samples at 2 ms, IBM float (live data in traces 93-116 only, the rest are zero) |

## A first program

```nim
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd")
echo f.kind, ": ", f.len, " traces in ", f.recordCount, " record(s), up to ",
  f.maxSamples, " samples"
let s = f.summary
echo "revision ", s.revision.major, ".", s.revision.minor, ", format ", s.formatCode,
  ", ", s.sampleIntervalUs, " us"

let samples = f.readTraces(3..4)      # Tensor[float32], shape [2, 4001]
echo samples.shape, " first sample of trace 3: ", samples[0, 0]
for d in f.log: echo d                # problems found while indexing (none here)
f.close()

doAssert f.kind == skSegd and f.len == 5 and samples.shape == [2, 4001]
```

`openSeismic` memory-maps the file, detects the standard (SEG-Y, SEG-D or SEG-2) and walks
the headers once to build the **trace index**. Nothing else is read until you ask for it, so
opening a 40 GB file costs one header walk and about 24 bytes of memory per trace.

## The model in ten concepts

**Trace number.** Every trace has one number: its 0-based position in the file, in file
order, across all records. Ranges are Nim slices with both ends included (`0 ..< f.len`,
`1000..1999`); lists of trace numbers (`openArray[int]`, called a *selection*) give any order
you like, such as a gather, a sort order or every other trace. Bad numbers raise
`ValueError`; an empty range must still start inside `0 .. f.len`.

**Record vs trace.** A SEG-D file holds one or more *records* (field records, one per shot
or per acquisition window). Each record has general headers, then its traces. SEG-Y and
SEG-2 files count as one record. `f.recordCount` gives the number of records,
`f.traceEntry(i).record` the record of SEG-D trace `i` (for SEG-2 that field indexes the
sample codec instead), and `recordField(f, record, "gh1.<field>")` reads record headers.

**Channel sets.** Inside a SEG-D record, traces are grouped into channel sets (per scan
type). Each set has a channel type (seismic, or an auxiliary type such as time break or
pilot), a sample interval and a time window. `f.channelSets` describes them;
`f.traceEntry(i).channelSetIndex` and `.channelType` place a trace in one, and
`isSeismic(f.index, i)` tells seismic traces from auxiliary ones. SEG-Y has no channel sets
(`channelSetIndex` is -1).

**The index.** `f.index` (`TraceIndex`) holds one `TraceEntry` per trace (header offset,
header size, sample count, record, channel set, channel type) plus the file-level and
record-level headers, already decoded. It is built once at open and stays in memory.

**Keys.** `openSeismic(path, keys = true)` also collects each trace's geometry as
`TraceKeys`: source and receiver line, point, index and coordinates, elevations, midpoint,
offset, channel, component and the trace's UTC time. Values the headers do not give are NaN
(numbers) or 0 (codes). Keys cost 144 bytes per trace and are needed by `gathers`,
`componentGroupIds`, `applySurvey` and the geometry write-back. Without `keys = true`,
`traceKeys(traces)` makes the keys of a few traces on demand.

**Gathers.** `f.gathers` splits the file into runs of traces and *derives* each run's kind
(shot, receiver, CMP, offset, other, unknown) from the keys. Nothing assumes shot gathers:
node data packed as receiver gathers is recognized as such.

**Samples.** Samples come out as Arraymancer tensors shaped `[traces, samples]`, `float32` by
default or `float64` (`readTraces(f, r, float64)`; `f.index.prefersFloat64` says whether
some format would lose precision in float32). Shorter traces are zero-padded to the longest
one in the request. The decoders write straight from the mapped bytes into the tensor.

**Headers by name.** Any header field can be read by name, straight from the map:
`traceField(f, i, "trace.sourceX")`, `recordField(f, r, "gh1.year")`,
`fileField(f, "binary.formatCode")`. `fieldNames(hbSegyTrace)` lists the names of a block
kind. Values are `FieldValue`s (`intVal`, `floatVal` or `text` by `kind`).

**Diagnostics.** Reading never raises on bad file content. Every problem becomes a
`Diagnostic` (severity, code, byte offset, location, message) in a `DiagLog`: the index's
log (`f.log`), a read's log, an editor's log, a conversion's result. Exceptions are kept
for bad *arguments* (`ValueError`) and for the operating system refusing (`IOError`,
`OSError`). See [diagnostics.md](diagnostics.md).

**Files change only on an explicit write.** Opening, indexing, reading and joining survey
geometry never touch the file, which is mapped read-only. Bytes on disk change only through
the writers, the converters, or the journaled `HeaderEditor` ([editing.md](editing.md)).

```nim
import std/[math, strutils]
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", keys = true)
for i in 0 ..< f.len:
  let e = f.traceEntry(i)
  let k = f.traceKeys(i)
  echo "trace ", i, ": record ", e.record, ", channel set ", e.channelSetIndex,
    ", type 0x", e.channelType.toHex, (if isSeismic(f.index, i): " seismic" else: " aux"),
    ", receiver ", k.rcvLine, "/", k.rcvPoint
for cs in f.channelSets:
  echo "set ", cs.channelSet, ": type 0x", cs.channelType.toHex(2), ", ", cs.traceCount,
    " traces, ", cs.sampleIntervalUs, " us"
for g in f.gathers:
  echo g.kind, " gather, traces ", g.traces, ", ", g.sources, " source(s), ",
    g.receivers, " receiver(s)"

doAssert not isSeismic(f.index, 0) and isSeismic(f.index, 3)
doAssert f.gathers[0].kind == gkShot and f.traceKeys(3).rcvLine == 100
doAssert not f.traceKeys(0).srcX.isNaN and f.recordField(0, "gh1.fileNumber").intVal == 151
```

## Lifetimes: what you may keep after `close`

A `SeismicFile` owns its mapping. It cannot be copied (the compiler refuses `=copy`), only
moved; when it goes out of scope it unmaps itself, and `close` does that early.

| After `close` | Still works | Raises `ValueError` ("the file is closed") |
|---|---|---|
| In-memory index | `len`, `kind`, `log`, `recordCount`, `maxSamples`, `traceEntry`, `traceKeys(i)` (stored keys), `gathers`, `componentGroupIds`, `textHeader`, `f.index` | |
| Reads from the map | | `readTraces`, `readTracesInto`, `traceField` & co, `traceFieldColumn` & co, `traceKeys(traces)` without stored keys, `sortTraces`, `traceHeaders` & co, `summary`, `sampleIntervalUs`, `copyBytes`, `newPrefetcher`, `saveIndex` |

Everything a read returns is an owned copy: tensors, `FieldValue`s, header listings, byte
copies and logs stay valid after the file is closed. The library never hands out pointers
into the map.

```nim
import parseSEG

var kept: Tensor[float32]
block:
  var f = openSeismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", keys = true)
  kept = f.readTraces(0..9)
  f.close()
  doAssert f.len == 200 and f.gathers.len == 1  # the index outlives the map
  try:
    discard f.readTraces(0..0)
    doAssert false
  except ValueError as e:
    echo "after close: ", e.msg
echo "the tensor is still ours: ", kept.shape
doAssert kept.shape == [10, 2001]
```

Four contracts go beyond "values are copies":

| Object | Contract |
|---|---|
| `Prefetcher` | It pins the file's map: closing (or dropping) the file while it runs is safe, and the unmap waits for the prefetcher's `close`. The file's index must not change while it runs (`applySurvey`, `applyGeometry`). |
| `openEditor(f)`, `release(ed)` | Both take ownership (`sink`): the editor takes over the open file, and `release` gives it back. A variable at module top level is a global, so write `openEditor(move f)` and `f = release(move ed)` there ([editing.md](editing.md#editing-a-file-that-is-already-open)). |
| `nextInto`, `tryNextInto`, `recycle` | You hand a chunk's buffer back to the prefetcher, which decodes later chunks into it. In a loop write `p.recycle(move c)`. Keep no raw pointer into a buffer you handed back; a copy or view you kept stays valid (that buffer is just not reused). |
| `Progress` hook | It must be `gcsafe`: capture a parameter or a `ref`, not a global (see [viewer.md](viewer.md#open-a-file-progress-cancel-and-an-index-cache)). It runs on the thread that called the operation. |

## Thread rules

- `readTraces`, `readTracesInto` and their sample-window forms on one open `SeismicFile` may
  run on several threads at once: they only read the map and the index. So may
  `traceFieldColumnInto` and `traceKeysInto`.
  Share the file by pointer and give each thread its own tensor (or buffer) and log. While
  any thread reads, nothing may `close` the file or change its index (`applySurvey`,
  `applyGeometry`). [processing.md](processing.md#read-in-parallel) has a complete example.
- Everything else on a `SeismicFile` (and every `HeaderEditor`, `SeismicWriter` and
  `SurveyGeometry`) is single-threaded: call it from one thread, or serialize the calls
  yourself.
- A `Prefetcher` decodes on its own worker thread; its consumer procs (`next`, `tryNext`,
  `nextInto`, `tryNextInto`, `recycle`, `seek`, `close`) must all be called from one thread.
- A `Progress` hook is called on the thread that runs the operation (the opening or
  converting thread), never on a worker.

## Where next

- Building a viewer: [viewer.md](viewer.md).
- Batch or HPC processing: [processing.md](processing.md).
- Editing headers in place, patches and journals: [editing.md](editing.md).
- Converting between standards, survey files and geometry: [conversion.md](conversion.md).
- Understanding the diagnostics: [diagnostics.md](diagnostics.md).
