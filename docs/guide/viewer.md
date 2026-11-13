# Recipes for a seismic viewer

A viewer needs a few things from a data library: a cheap overview of a file of any size,
random access to any trace range, gather or sort order without blocking the UI, the
headers of the trace under the cursor, and a way to keep the user's header changes without
touching the file. This page shows each with parseSEG, in the order a viewer meets them.
Read [getting-started.md](getting-started.md) first for the concepts (trace numbers,
records, channel sets, keys, gathers).

| Section | Main names |
|---|---|
| [Open a file](#open-a-file-progress-cancel-and-an-index-cache) | `openSeismic(progress, opts = OpenOptions(cache: ...))`, `saveIndex`, `SegCancelledError` |
| [The navigation tree](#the-navigation-tree) | `summary`, `gathers`, `channelSets`, `componentGroupIds` |
| [Read what is on screen](#read-what-is-on-screen) | `readTraces`, `readTracesInto`, sample windows |
| [Sorted views](#sorted-views) | `sortTraces`, `sortOrder` |
| [Header columns and keys on demand](#header-columns-and-keys-on-demand) | `traceFieldColumn`, `traceKeys(traces)` |
| [Read ahead](#read-ahead-without-blocking-the-ui) | `newPrefetcher`, `tryNext`, `seek`, `nextInto`, `recycle` |
| [The header tab](#the-header-tab-and-the-textual-header) | `traceHeaders`, `copyBytes`, `textHeader` |
| [Geometry](#geometry-time-and-annotation) | `traceKeys`, inline and crossline |
| [Edits](#keep-the-users-header-edits-as-a-patch) | `writeHeaderPatch`, `openEditor(f)`, `release` |

## Open a file: progress, cancel and an index cache

Open with `keys = true` when the viewer shows geometry or gathers for the whole file (or
make keys on demand for what is on screen: [below](#header-columns-and-keys-on-demand)).
The open walks every trace header once, which takes seconds on a 40 GB file. A
fixed-length SEG-Y file (Rev 1 or later, binary header bytes 3503-3504 = 1) is the exception:
by default (`verify = vfSampled`) its index is computed from the file size and 64 of its trace
headers (the first, the last and 62 between) are checked against the binary header, so 10 M
traces open in about 20 ms warm and 50 ms cold, against 1.7 s and 22 s for the walk. The log
then has an `indexSampled` info. The first read of each page then maps it (a few µs, once
per page), which the walk used to do at open. With `keys = true` such a file is indexed the
same way and its keys are then read from the mapped headers in one pass (about 130 ns per
trace, against 260 for the walk): the same keys, without the walk's per-trace warnings. A
sampled header that disagrees, Rev 2 extension
headers or trailers, and a size that is not a whole number of traces all fall back to the
walk; `OpenOptions(verify: vfFull)` always walks, and also reports a mismatch in a header that was not
sampled (`parseSEG diag` opens that way). Pass a
`progress` hook to show how far it got and to let the user cancel, and an index cache so the
next open of the same file is near-instant (10 M SEG-Y traces: 1.7 s to walk, 43 ms from the
cache). The hook runs on the opening thread about every MiB and once at the end; returning
false stops the walk with `SegCancelledError`. Files change only on an explicit write, so
`openSeismic` only reads the cache: `saveIndex` writes it.

```nim
import std/os
import parseSEG

type Bar = ref object
  percent: int
  cancelled: bool             # set by the cancel button

proc progressOf(bar: Bar): Progress =
  # The hook must be gcsafe: it captures `bar`, not a global.
  proc (done, total: int64): bool =
    if total > 0: bar.percent = int(done * 100 div total)
    not bar.cancelled

let path = "survey.sgy"
let cache = getTempDir() / "survey.pidx" # anywhere writable; one cache per file
removeFile(cache)
let bar = Bar()
var f = openSeismic(path, keys = true, progress = progressOf(bar), opts = OpenOptions(cache: cache))
doAssert bar.percent == 100 and not f.fromCache  # no cache yet: indexed, with an info note
f.saveIndex(cache)
f.close()

var g = openSeismic(path, keys = true, opts = OpenOptions(cache: cache))   # the second open
doAssert g.fromCache and g.len == 200
g.close()

bar.cancelled = true
try:
  discard openSeismic(path, progress = progressOf(bar))
  doAssert false
except SegCancelledError:
  discard                     # nothing stays mapped
```

- A cache is used only when it was saved for this path, size, modification time and
  first and last 64 KiB of the file, with the same `twosComplement8015` (and keys when
  you ask for them), by the same parseSEG version, and is intact. Anything else walks
  the file and says why in `f.log` (`indexCache`, info), so a stale cache never gives a
  wrong index. Save again after such an open. A cache saved from a sampled open does not
  serve `verify: vfFull`.
- Save right after opening: `saveIndex` refuses an index whose keys `applySurvey` or
  `applyGeometry` changed, a file changed since it was opened, and the temporary
  demultiplexed copy of multiplexed SEG-D (those files are never cached).
- The same hook drives conversions and exports: `convertFile(src, dst, opts, progress)`
  returns a fatal `dcCancelled` diagnostic and writes nothing; `exportHeaders(f, path,
  progress = hook)` raises `SegCancelledError` ([processing.md](processing.md#batch-conversions-with-progress-and-cancel)).

## The navigation tree

`summary` gives the facts every standard shares; `gathers` and `channelSets` give a tree to
navigate.

```nim
import std/[math, strutils]
import parseSEG

var f = openSeismic("shot.sgd", keys = true)
let s = f.summary
echo s.standard, " rev ", s.revision.major, ".", s.revision.minor, ", ", s.traceCount,
  " traces, ", s.recordCount, " record(s), ", s.sampleIntervalUs, " us, ",
  s.recordLengthMs, " ms, coordinates in ", s.coordinateUnits

# A tree: gathers, then the channel sets of each SEG-D record.
for g in f.gathers:
  echo "gather ", g.kind, ": traces ", g.traces
for cs in f.channelSets:
  echo "  record ", cs.record, " set ", cs.number, ": channel type 0x",
    toHex(cs.channelType, 2), ", ", cs.traceCount, " traces, ", cs.startTimeMs, "..",
    cs.endTimeMs, " ms"

# Coordinate reference text, when the file has one (SEG-Y stanza, SEG-D Location Data).
if s.crsFormat != ctNone:
  echo "CRS (", s.crsFormat, "): ", f.crsText.splitLines[0]

doAssert f.gathers.len == 1 and f.channelSets.len == 4 and s.crsFormat == ctStanza
```

Things worth knowing for the overview:

- `summary` fields that differ between traces are NaN or -1 (`sampleIntervalUs`,
  `samplesPerTrace`). For SEG-D, take intervals and windows per channel set
  (`channelSets`) or per trace (`f.sampleIntervalUs(i)`).
- SEG-D traces are in file order, which is not necessarily channel set order: in the example
  above, trace 1 is in channel set index 2 and trace 2 in index 1. Use
  `traceEntry(i).channelSetIndex` instead of assuming.
- Gather kinds are derived from the keys. A post-stack SEG-Y volume has no source or
  receiver to group by: in `survey.sgy`, whose traces carry CDP numbers, each trace is a
  one-trace `gkCmp` gather; a volume without them is one gather of kind `gkUnknown`.

### Gathers and multi-component stations

A gather's `traces` is a range; pass it to `readTraces` as it is. To hide auxiliary traces,
filter with `isSeismic`. For multi-component data, `componentGroupIds` labels each trace
with its station group (-1 for traces in none), so the viewer can show one station's
components side by side.

```nim
import parseSEG

var f = openSeismic("shot.sgd", keys = true)
let g = f.gathers[0]
var seismic: seq[int]
for i in g.traces:
  if isSeismic(f.index, i): seismic.add i
let shot = f.readTraces(seismic)
echo g.kind, " gather: ", seismic.len, " seismic traces of ", g.traces.len

let groups = f.componentGroupIds(g.traces)
echo "station group of each trace: ", groups
doAssert seismic == @[3, 4] and shot.shape == [2, 4001]
doAssert groups == @[-1, -1, -1, 0, 1]   # aux traces are in no group
```

## Read what is on screen

`readTraces` returns a new tensor; `readTracesInto` decodes into one you already have, so a
viewer can keep one buffer per viewport and refill it on every scroll without allocating.
Rows are cut or zero-padded to the buffer's width.

```nim
import parseSEG

var f = openSeismic("survey.sgy")

# A range: the 50 traces from trace 100 on, all samples.
let panel = f.readTraces(100 ..< 150)
doAssert panel.shape == [50, 2001]

# A viewport buffer, reused: 64 traces of up to 2001 samples (longer ones would be cut).
var view = newTraceTensor[float32](64, 2001)
var log: DiagLog
for first in countup(0, 128, 64):            # the user scrolls right
  let failed = f.readTracesInto(first ..< first + 64, view, log)
  doAssert failed == 0                        # undecodable traces would be zero rows
  echo "traces ", first, "..", first + 63, ": peak ", max(abs(view))

# A selection, in the order given: every tenth trace, newest first.
var picks: seq[int]
for i in countdown(f.len - 1, 0, 10): picks.add i
let decimated = f.readTraces(picks)
doAssert decimated.shape == [20, 2001]
```

A buffer narrower than the trace keeps the first `width` samples. For a deep time window,
pass `samples: a..b`: only those samples are decoded (rows are zero past a trace's end), and
the buffer's width must be the window's length.

```nim
import parseSEG

var f = openSeismic("survey.sgy")
# Samples 1000..1499 of traces 90..119: a zoomed-in panel.
let zoom = f.readTraces(90 ..< 120, 1000 .. 1499)
doAssert zoom.shape == [30, 500]
var view = newTraceTensor[float32](30, 500)  # the same window into a reused buffer
doAssert f.readTracesInto(90 ..< 120, 1000 .. 1499, view) == 0
doAssert view == zoom
f.close()
```

**Cold files.** When a file is not in the page cache, each page fault waits for the disk,
one at a time, so a scattered read pays one disk round trip per trace. Before a large read
(32 traces or more, or 1 MB), `readTraces` and `readTracesInto` check whether it is in memory
(one `mincore` call, about 0.7 µs, at the last trace of a range; two, at both ends, for a
selection). If it is not, the read asks the OS for all of its traces' pages at once
(`madvise(MADV_WILLNEED)`): a cold receiver gather of 1000 traces spread over 1.2 GB takes about 0.1 s instead of 1.3 s,
and a cold shot gather 2 ms instead of 6 ms. A range that continues the previous read (the
bytes just before it are in memory) is left to the kernel's sequential read-ahead, which
streams faster than advice per chunk. The prefetcher advises the first 4 MB after a start or
`seek`, and a selection 4 MB at a time. POSIX only; elsewhere reads fault in as before.

## Sorted views

A sort is a selection: `sortTraces(by)` sorts by header fields and returns trace indices,
and no data moves. Read the sorted view with the list form of `readTraces` (or
`newPrefetcher`). The sort is stable and ascending, with NaN last. `sortOrder(columns)`
does the same over columns of your own, such as `TraceKeys` fields.

```nim
import std/sequtils
import parseSEG

var f = openSeismic("survey.sgy")
let order = f.sortTraces(["trace.crosslineNumber", "trace.inlineNumber"])
let firstColumn = f.readTraces(order[0 ..< 10], 0 .. 499)   # the sorted view, a window
doAssert order.len == f.len and firstColumn.shape == [10, 500]
let byOffset = sortOrder([f.traceKeys(0 ..< f.len).mapIt(it.offset)]) # positions = traces here
doAssert byOffset.len == f.len
f.close()
```

`sortTraces(by, traces)` sorts a range or a list (one gather, say) instead of the whole file.

## Header columns and keys on demand

Stored keys (`keys = true`) cost about 184 bytes per trace, and at open about 130 ns per
trace for a fixed-length SEG-Y file and 70 ns on top of the walk for other SEG-Y files with
the standard layout (about 220 ns when a Layout stanza moves fields). A viewer that
shows geometry only for the traces on screen can open without them and ask for what it
shows: `traceKeys(traces)` (or `traceKeysInto`, into a reused buffer) makes the keys on
demand, exactly as `keys = true` would, and `traceFieldColumn(name, traces)` reads one
numeric header field for many traces (a plot axis, a colour bar), resolving the field once.

```nim
import std/math
import parseSEG

var f = openSeismic("survey.sgy") # no stored keys
let ks = f.traceKeys(0 ..< 10)                 # the keys of what is on screen
let sx = f.traceFieldColumn("trace.sourceX", 0 ..< 10)
var buf = newSeq[float64](3)                   # reused across redraws
f.traceFieldColumnInto("trace.cdpX", [9, 0, 5], buf)
echo "trace 0: ensemble ", ks[0].ensemble, ", source x (raw) ", sx[0]
doAssert not f.hasKeys and ks.len == 10 and sx.len == 10
doAssert f.traceFieldColumn("ext1.extFieldRecord", [0])[0].isNaN # this file has no Ext1
f.close()
```

Keys made on demand are the file's own geometry: geometry joined with `applySurvey` or
`applyGeometry` lives only in stored keys.

When the user first asks for geometry of the whole file, `ensureKeys` builds the stored keys
(as `keys = true` would, with progress and cancel). `keysRevision` goes up whenever stored
keys change (`ensureKeys`, a survey join, a header edit through a `HeaderEditor`): tag what
is drawn from keys (moveout overlays, binning, a map) with it and rebuild when it changes.

A `TraceRows` view and a `Prefetcher` take their pointers to the keys when they are made.
Those made while the file had stored keys see every later change in place. Those made
before `ensureKeys` have no keys and never get them (`rows.hasKeys` stays false, `traceKeys`
raises `ValueError`): after `ensureKeys`, call `rowsOf` again, and close the session's
prefetcher and make a new one.

```nim
import parseSEG

var f = openSeismic("record.sgd")          # fast: no keys yet
f.ensureKeys()                             # the user opened the map view
let drawn = f.keysRevision
var g: GeometryTable
g.addReceiver(10, 104, 0, 506000, 6008000)
discard f.applyGeometry(g)                  # a survey join changes the keys...
doAssert f.keysRevision != drawn            # ...so the map is redrawn
```

## Read ahead without blocking the UI

A `Prefetcher` decodes chunks of traces on worker threads (one by default) into a bounded
ring. The UI thread polls with `tryNext` (never blocks) or waits with `next`, and calls `seek`
when the user jumps elsewhere: chunks decoded for the old position are dropped. Each chunk's
`samples` tensor belongs to the caller; no worker writes it again. `firstSample`
and `cols` choose a sample window, as `readTraces(traces, samples)` does.

```nim
import std/os
import parseSEG

var f = openSeismic("survey.sgy")
var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 32, depth = 4)
var c: PrefetchChunk[float32]
var shown = 0
while not p.atEnd:
  if p.tryNext(c):                    # a chunk is ready: draw it
    shown += c.count
    doAssert c.samples.shape == [c.count, 2001] and c.failed == 0
  else:
    sleep(1)                          # the UI does its own work meanwhile
doAssert shown == f.len

p.seek(150 ..< 200)                   # the user jumped to trace 150
doAssert p.next(c) and c.first == 150
p.close()                             # stops and joins the workers

# A zoomed view: samples 1000..1499 of traces 90..119.
var z = newPrefetcher[float32](f, 90 ..< 120, chunkTraces = 30, cols = 500,
  firstSample = 1000)
doAssert z.next(c) and c.samples == f.readTraces(90 ..< 120, 1000 .. 1499)
z.close()
f.close()
```

- In range mode a prefetcher accepts any span of the file in `seek` (`p.len` is the trace
  count), so one prefetcher can serve a whole session. `newPrefetcher(f, @[...])` reads
  a selection (a gather, a sort order) instead; its positions index the list (`traceAt`
  maps them back).
- `cols` fixes the row width (default: the longest trace of the range, less
  `firstSample`). Rows are zero past a trace's end.
- A trace that cannot be decoded is a zero row, counted in `c.failed`, with an error in
  `c.log` that names the trace.
- One worker decodes IEEE at about 21 GB/s, but IBM float (13 in a build that targets
  AVX2, 6 without) and SEG-D 8015 (4.5) at one core's speed: `workers = 4` gives about 22
  and 16 GB/s. Chunks still arrive in order.
- The ring is capped at `maxRingBytes` (default `DefaultRingBytes`, 4 MiB; at least
  `workers + 1` chunks), so a chunk is still in the CPU cache when you take it: a 16 MB ring
  ran at 60 % of the speed. `p.depth` is the depth used.
- `quickFirst = true` makes the first chunk of the range and of each `seek` a quarter of
  `chunkTraces`, so the first rows after a jump arrive sooner (1024-trace chunks of 1000
  samples: 0.27 ms -> 0.09 ms for IEEE, 0.39 -> 0.13 ms for IBM); the full-size chunks
  follow from there. That first chunk's `samples` is a view of a whole chunk buffer: `clone`
  it if you keep it for long.
- A `seek` (or `close`) while a worker is still decoding the old position does not wait
  for that chunk: the worker gives it up within 8 traces.
- Call a prefetcher's procs from the thread that made it. It keeps the file's map alive
  until its own `close`, so that thread may close the file and the prefetcher in either
  order. The file's index must not change while it runs (`applySurvey`, `applyGeometry`).
- A prefetcher made before the file is closed or handed to an editor (`openEditor(f)`)
  goes on with the index as it was then: its chunks' `rows` show the keys of that moment,
  not later edits, until you make it again. Stop the readers made after `openEditor` before
  the editor writes: an edit refreshes the stored keys in place.
- A `transform` hook runs on a worker thread, where nothing can catch a `Defect`: an index
  out of bounds or a failed assertion in the hook ends the process. Check sizes and
  `hasKeys` before you make the prefetcher. A chunk dropped by a `seek` is not transformed.
- Several threads may each make, use and close their own prefetchers on one open file at
  the same time: a background job (a stack, an export) beside the UI's read-ahead. While
  another thread reads the file or has a prefetcher on it, do not change its index
  (`ensureKeys`, a survey join, an editor), close it or let it go out of scope: stop the
  job first.

### Recycle the chunk buffers

A viewer that is done with each chunk before it takes the next (it has copied it to the
screen or a texture) can hand the buffer back, so scrolling allocates nothing: `nextInto`
(and `tryNextInto`) swap `c.samples` into the slot the chunk came from, where a later chunk
is decoded into it. `p.recycle(move c)` returns one for `next` to reuse. Only a tensor of
the chunk shape that nothing else shares is reused: a copy or a view you kept stays intact
(it is just not reused), but a raw pointer into it must not outlive the call.

```nim
import parseSEG

var f = openSeismic("survey.sgy")
var p = newPrefetcher[float32](f, 0 ..< f.len, chunkTraces = 32, depth = 4)
var c: PrefetchChunk[float32]
var shown = 0
while p.nextInto(c):                  # c's previous buffer becomes a decode target
  shown += c.count                    # draw c.samples before the next call
doAssert shown == f.len

p.seek(0 ..< 64)
var d: PrefetchChunk[float32]
while p.next(d):
  shown += d.count
  p.recycle(move d)                   # `move`: give the buffer up, keep no pointer into it
doAssert shown == f.len + 64
p.close()
f.close()
```

## The header tab and the textual header

`traceHeaders(i)`, `recordHeaders(r)` and `fileHeaders` list every header block of a trace,
SEG-D record or file as rows: block name, field name, decoded value, and the byte offset and
size of both the field and its block. `copyBytes(blockOffset, blockSize)` gives the raw
bytes for a hex pane, and the row's offset and size highlight the field in it.

```nim
import std/strutils
import parseSEG

var f = openSeismic("record.sgd")
let rows = f.traceHeaders(0)
var shownBlocks: seq[string]
for r in rows:
  if r.blockName notin shownBlocks:
    shownBlocks.add r.blockName
    echo "[", r.blockName, "] ", r.kind, ", ", r.blockSize, " bytes at ", r.blockOffset
  if r.field.len > 0 and r.field in ["receiverLineNumber", "receiverPointNumber", "sensorType"]:
    echo "  ", r.field, " = ", r.value, "  (bytes ", r.offset - r.blockOffset, "..",
      r.offset - r.blockOffset + r.size - 1, " of the block)"

# The record's general headers, and a hex dump of GH#1.
let rec = f.recordHeaders(0)
let gh1 = rec[0]
let hex = f.copyBytes(gh1.blockOffset, gh1.blockSize)
var line = ""
for b in hex[0 ..< 16]: line.add toHex(b) & " "
echo "gh1: ", line

# Any single field by name, straight from the map.
echo "source point: ", f.recordField(0, "gh3.sourcePointNumber")
doAssert f.recordField(0, "gh3.sourcePointNumber").floatVal == 99.5
doAssert gh1.blockName == "gh1" and hex.len == 32
```

- `blockName & "." & field` is the name the editor and patches use
  ([editing.md](editing.md)).
- Blocks without named fields (text headers, vendor and undefined blocks) give one row with
  an empty `field` and kind `hbRaw`; show them as hex.
- SEG-2 blocks list the fixed fields, then one row per keyword string.
- `traceField(f, i, name)` raises `ValueError` for a name the trace does not have;
  `findTraceField` returns an `Option` instead, which suits optional columns.

For a SEG-Y file, `textHeader` gives the textual file header decoded (EBCDIC or ASCII, as
detected) as 40 lines of 80 characters, and `extendedTextHeaders` each extended textual
record the same way. Both raise `ValueError` for another standard.

```nim
import std/strutils
import parseSEG

var f = openSeismic("survey.sgy")
let lines = f.textHeader.splitLines
echo lines[0]                            # "C01 parseSEG demo survey: ..."
echo f.extendedTextHeaders.len, " extended textual records"
doAssert lines.len == 40 and lines[0].len == 80
f.close()
```

## Geometry, time and annotation

With `keys = true`, `traceKeys(i)` gives what an annotation bar or a base map needs.
Unknown values are NaN. `time` is the trace's UTC time in POSIX seconds (fractional).

```nim
import std/[math, times]
import parseSEG

var f = openSeismic("shot.sgd", keys = true)
let k = f.traceKeys(3)
echo "source ", k.srcLine, "/", k.srcPoint, " at (", k.srcX, ", ", k.srcY, ")"
echo "receiver ", k.rcvLine, "/", k.rcvPoint, " at (", k.rcvX, ", ", k.rcvY, ")"
echo "offset ", round(k.offset, 1), ", recorded ", fromUnixFloat(k.time).utc
echo "sample interval ", f.sampleIntervalUs(3), " us"
doAssert abs(k.offset - 10000) < 0.01 and f.sampleIntervalUs(3) == 1000
```

### Inline and crossline of post-stack SEG-Y

`TraceKeys` describes acquisition geometry. Post-stack volumes are addressed by inline and
crossline instead, which many files keep in non-standard bytes and describe in a SEG-Y
Layout stanza (`survey.sgy` keeps the inline at byte 13). The streaming SEG-Y
reader resolves those names through the file's layout (`fieldValue(file, trace, "iline")`);
read the headers once with `headersOnly` and keep the numbers:

```nim
import std/options
import parseSEG

var src = openDiskSource("survey.sgy")
var r = openSegy(src, headersOnly = true)    # headers only: sample bytes are skipped
var t: SegyTrace
var inlines, crosslines: seq[int]
while r.readTrace(t):
  inlines.add int(fieldValue(r.file, t, "iline").get(NaN))
  crosslines.add int(fieldValue(r.file, t, "xline").get(NaN))
src.close()
echo "inline ", inlines[0], ", crosslines ", crosslines[0], "..", crosslines[^1]
doAssert inlines.len == 200 and inlines[0] == 1001 and crosslines[^1] == 200
```

`traceField(f, i, "trace.inlineNumber")` (and `traceFieldColumn`, `sortTraces`) read the
standard bytes 189-192 only, which this file leaves at 0.

## Keep the user's header edits as a patch

A viewer should not write to the file while the user experiments. Collect the changes in a
`seq[HeaderChange]` and save it; applying it later is an explicit step ([editing.md](editing.md)).
When the user does save into the file, `openEditor(f)` takes over the open file and its index
(no second open), and `release(ed)` hands it back as edited
([editing.md](editing.md#editing-a-file-that-is-already-open)).

```nim
import parseSEG

var patch: seq[HeaderChange]
patch.add initHeaderChange(hsTrace, 5, "trace.sourceX", toFieldValue(1_700_000))
patch.add initHeaderChange(hsTrace, 6, "trace.sourceX", toFieldValue(1_700_025))
patch.add initHeaderChange(hsFile, 0, "binary.jobId", toFieldValue(7))
writeHeaderPatch(patch, "viewer-edits.nif")
doAssert patch.len == 3
echo readFile("viewer-edits.nif")
```
