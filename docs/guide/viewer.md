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
| [The navigation tree](#the-navigation-tree) | `summary`, `gathers`, `channelSets`, `componentGroupIds`, `crs` |
| [Read what is on screen](#read-what-is-on-screen) | `readTraces`, `readTracesInto`, sample windows |
| [Sorted views](#sorted-views) | `sortTraces`, `sortOrder` |
| [Header columns and keys on demand](#header-columns-and-keys-on-demand) | `traceFieldColumn`, `traceKeys(traces)` |
| [Read ahead](#read-ahead-without-blocking-the-ui) | `newPrefetcher`, `tryNext`, `seek`, `nextInto`, `recycle` |
| [Other programs and an open file](#other-programs-and-a-file-that-is-open) | Windows sharing, `faUnmapped`, appends, renames, deletes |
| [A file cut short](#a-file-cut-short-while-it-is-open) | `cutShort`, `dcTruncated`, `SegTruncatedError` |
| [Files on a network drive](#files-on-a-network-drive) | `OpenOptions.access`, `faAuto`, `faUnmapped`, `dcIo` |
| [Files that live in memory](#files-that-live-in-memory) | `openSeismicBytes`, `openSeismicWriterBytes`, `finishBytes`, `inMemory` |
| [Survey files](#survey-files-in-the-background) | `looksLikeSps`, `readSps(progress)`, `readP1(progress)`, `SpsOptions` |
| [The header tab](#the-header-tab-and-the-textual-header) | `traceHeaders`, `copyBytes`, `textHeader` |
| [Geometry](#geometry-time-and-annotation) | `traceKeys`, inline and crossline |
| [Leap seconds](#leap-seconds-the-file-replacing-it-adding-one) | `useLeapTable`, `withLeap`, `leapKnownAt` |
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

# Coordinate reference text, when the file has one (SEG-Y stanza, SEG-D Location Data),
# and what it gives as values: the CRS, datum, projection (here only the CRS's code and name).
if s.crsFormat != ctNone:
  echo "CRS (", s.crsFormat, "): ", f.crsText.splitLines[0]
let crs = f.crs
doAssert crs.kind == ckProjected and crs.epsg == 32632 and crs.name == "WGS 84 / UTM zone 32N"
doAssert not crs.datum.known and not crs.projection.known # not given in this file

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
- A receiver-gather SEG-D file is one record per receiver. The traces are the shots that
  receiver recorded, in file order, so display them side by side in that order. Callers
  usually sort by source line then source point before writing; one system sorts by shot
  time. This library's writer does not sort ([processing.md](processing.md)). `traceKeys`
gives each trace its own source line, point, coordinates and time. `gathers` reports
`gkReceiver` when the record has one receiver and more than one source station, and also
when one receiver recorded repeated shots at one source point (more than one trace, the
components do not account for them, and the times differ): also a continuous record of one
receiver. A SEG-Y file of that shape (sorting 0) is a receiver gather too. Equal times stay
`gkUnknown`.
Time is not part of the source identity: a shot whose traces carry different timestamps
is still one source. A record
of only auxiliary traces (a vibrator pilot for several sweeps) is a receiver gather the
same way, when those traces are distinct sources or repeated shots at one point.

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
- A file opened on one thread may be closed, or dropped, on another (a job thread opens
  it, the UI thread lets it go), with or without prefetchers. Its record source is
  `{.acyclic.}`, so ORC never lists it as a possible cycle root on the thread that opened
  it, and nothing needs `clearCycleRoots` for it. ORC keeps a thread's root buffer (16
  KiB) once anything at all was listed there (the standard library's XML parser, reading
  a SEG-Y Layout stanza, does so): `GC_runOrc()` on that thread frees it, or it stays
  until the process ends.

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

## Other programs and a file that is open

A viewer keeps a file open (mapped or unmapped) for as long as it is on screen, and a
recorder or a copy job may be working on the same file. On Linux and macOS the OS lets
every program do that. On Windows a file is open for sharing only as far as the program
that opened it says, so parseSEG opens every file it reads (the map, the unmapped reads,
the index cache, the survey and header documents, the editor's journal) with read, write
and delete all shared, and a link is followed to its target. What that means in practice:

- A recorder that already has the file open for writing does not stop parseSEG from
  opening it (it must itself let readers in, as most recorders do); parseSEG does not stop
  the recorder from going on writing.
- A file can be appended to while it is open. A map covers the bytes the file had at
  open: what is appended is not read, and a read past that size
  is refused, never a fault. Open the file again to see the new end.
- A file can be renamed while it is open; the open file goes on reading the same bytes.
- Deleting a file while it is open works, mapped or unmapped (tried on Windows with
  NTFS): the open file goes on reading its bytes, and its name goes at once (Windows 10
  1809 and later on NTFS) or when the last handle closes (older Windows, FAT, network
  shares).
- Replacing a file by renaming another over it (the way the writers below finish) does
  not work while it is open: Windows refuses the rename (access denied) whether the file
  is mapped or not, although parseSEG shares it for delete, while a plain delete of the same file
  works. The writer's retry gives up after about a fifth of a second and reports the
  error; the open file is untouched. A viewer that wants to be replaced must close the
  file first.
- Cutting the file below the mapped size (opening it again with truncation,
  `SetEndOfFile`) is refused by Windows (as its documentation says; not tried here), with
  "the requested operation cannot be performed on a file with a user-mapped section open"
  (error 1224), so on a local disk
  a mapped read never meets a cut. A network share that goes away, or a removable disk
  pulled out, can still make a mapped read fault, and nothing guards a map on Windows:
  that read ends the program (this is why `faAuto` reads such files unmapped). Unmapped,
  a cut is allowed and found by the next read that must fetch past it (`cutShort`,
  `dcTruncated`), as in the next section.
- The writers that make a file by writing a temporary one next to it and renaming it
  (conversions, saved edits, the index cache, header documents) try the rename again for
  about a fifth of a second when Windows says the target is in use (access denied,
  sharing or lock violation: a reader, a virus scanner, the search indexer), and report
  the error if it still is.
- Paths are passed to Windows as given: parseSEG adds no `\\?\` prefix, so a path longer
  than 259 characters opens only in a program that is long-path aware (its manifest says
  so, and the system's `LongPathsEnabled` is on).

## A file cut short while it is open

Another program can cut short a file the viewer has open: a recorder that writes it
again, `cp` over it, a sync tool. Reading the map past the new end raises `SIGBUS` on
Linux and macOS, which ends a program (Windows refuses to cut a mapped file). parseSEG
takes that fault for its own maps: the OS gives zeros there instead, and each read checks
what it read against the cut.

```nim
import std/os
when defined(posix): import std/posix
import parseSEG

copyFile("survey.sgy", "recording.sgy")
var f = openSeismic("recording.sgy")
var view = newTraceTensor[float32](f.len, f.maxSamples)
var log: DiagLog
doAssert f.readTracesInto(0 ..< f.len, view, log) == 0 and not f.cutShort
when defined(posix):
  # Another program cuts the file to half meanwhile (here, this one does).
  doAssert truncate("recording.sgy", Off(getFileSize("recording.sgy") div 2)) == 0
  let failed = f.readTracesInto(0 ..< f.len, view, log) # no SIGBUS
  doAssert failed > 0 and log[log.len - 1].code == dcTruncated
  doAssert f.cutShort                 # let go of the file, open it again later
  try:
    discard f.traceHeaders(0)         # header calls raise once the cut is known
    doAssert false
  except SegTruncatedError:
    discard
f.close()
```

What a viewer can rely on:

- No parseSEG call on an open file ends the program because the file was cut short:
  sample reads, the prefetcher, headers, keys, fields and bytes, the open, the editor and
  the conversions; on any thread that does not block `SIGBUS` (see below).
- Sample reads (`readTracesInto`, `readTraces` with a log, the prefetcher's chunks) fail
  each trace past the cut: a zero row, counted in the result (or `c.failed`), with an
  error `dcTruncated` that says the file was cut short while it was open (or its position
  in `failedRows`). The other rows are what the file holds. `readTraces` without a log
  raises `SegTruncatedError`, as for any trace that cannot be decoded.
- Calls that read headers, keys or raw bytes from the map (`traceHeaders`, `traceField`,
  `traceFieldColumn`, keys on demand, `ensureKeys`, `startTimeMs`, `traceOrientation`,
  `traceStatics`,
  `copyBytes`, `seg2Trace`, `sortTraces`, `exportHeaders`, `writeTrace` from the file)
  raise `SegTruncatedError` once the cut is known, also for headers before it; so does
  the call whose read first meets the cut. The index and stored keys (`keys = true`) are
  in memory and keep working.
- `openSeismic` raises `IOError` for a file cut while it is being opened. The editor
  refuses edits once the cut is known, and its `close` and `release` raise `IOError`
  (edits past the new end did not reach the file; the journal has them). A conversion
  from a source cut meanwhile is fatal and writes nothing.
- `f.cutShort` says whether the file was cut, from any thread that may read the file.
- A read the OS cannot do (an I/O error: a network share that went away, a server that
  timed out, a failing disk) faults the same way, the file's size unchanged. The guard
  takes it too: from the page that failed on, the map reads as cut (`cutShort` is true),
  `f.readFailed` says it was a failed read, sample rows fail with `dcIo` ("a read of the
  file failed"), header calls raise `SegTruncatedError` that says "could not be read past
  byte ..." and `openSeismic` raises `IOError`. It lasts as long as the map, also when
  the share comes back: open the file again.

A cut becomes known when a read reaches a page wholly past the new end, or when
`cutShort` asks the OS for the file's size (one `fstat`, about 0.5 µs; reads make no
system call). The rest of the page that holds the new end (4 KiB on most systems) reads
as zeros without a fault: a read of those bytes only, before anything found the cut,
gives zeros as samples at the end of a trace, or as header values. A read that reaches
further fails every trace past the cut, those it decoded before it got there included.
Call `cutShort` after a read when you must be sure.

What the viewer still does itself:

- Let go of a file that changed (watch its size and modification time) and open it
  again once it stops changing. A file cut and written again in place gives its new bytes
  under the old index wherever they are, and the traces a file gains are not in the
  index. Let go at once when `cutShort` is true or a read reports `dcTruncated` that says
  "cut short".
- Keep the guard in place. parseSEG installs its `SIGBUS` handler when it maps the first
  file, and passes every fault that is not in its maps, and every `SIGBUS` a program
  sends, to the handler that was there before. So install a crash reporter or any other
  `SIGBUS` handler before the first file is opened. One installed later sees parseSEG's
  faults first: it must pass on the faults that are not its own to the handler it
  replaced, as parseSEG does, and a crash reporter would report a cut file as a crash.
- A program that must own `SIGBUS` itself (a JVM, a Go runtime, a crash reporter that
  must see every fault first) builds parseSEG with `-d:parseSegNoMapGuard`: then no
  handler is installed and a read past a cut, or of a page the OS cannot read, ends the
  program with `SIGBUS`, as in parseSEG 0.11. What still works: `cutShort` asks the OS
  and records the cut, and from then on sample reads fail the traces past it without
  reading them, calls that read headers, keys or bytes raise `SegTruncatedError` before
  they read, and the editor refuses edits. So such a program calls `cutShort` before it
  reads a file that may change (after a change of its size or modification time), and
  reads network files unmapped (below), where no read faults.
- Do not block `SIGBUS` on a thread that reads files (`pthread_sigmask`, a thread pool
  that blocks every signal): the OS cannot deliver a fault there and ends the program.
- A debugger stops at every fault the guard takes; let them through (gdb:
  `handle SIGBUS nostop noprint pass`; lldb: `process handle SIGBUS -s false -p true`).
- Count one open file descriptor per mapped file: it stays open with the map, so a fault
  can ask the file's size. A viewer that keeps many files open may need a higher limit
  (`RLIMIT_NOFILE`; an app started from the macOS Finder gets 256 by default), or lets
  go of files it does not show.

### Files on a network drive

A mapped read of a file on a network share is a page fault the OS answers over the
network. When the share or its server fails, the fault either fails (a soft mount after its
timeout, SMB on Linux by default) or waits until the server answers, for minutes or for
ever (a hard mount, NFS's default). So parseSEG reads such files **unmapped** by default:
`openSeismic` with `OpenOptions(access: faAuto)`, the default, reads a file that lies on a
network file system with `pread` into its own cache, and maps any other.

```nim
import parseSEG

var f = openSeismic("survey.sgy")              # faAuto: a share is read unmapped
echo f.access                                  # faMapped on a local disk
var g = openSeismic("survey.sgy", opts = OpenOptions(access: faUnmapped))
var log: DiagLog
discard g.readTraces(0 ..< g.len, log)         # a failed read: rows with dcIo, no signal
f.close()
g.close()
```

How `faAuto` decides: Linux asks `statfs` for the file system's type (NFS, SMB/CIFS, AFS,
Coda, NCP, Ceph, 9P, Lustre, GPFS, OCFS2, GFS2 and FUSE: sshfs, rclone, gvfs mounts,
s3fs, virtiofs); macOS and the BSDs take a file system without `MNT_LOCAL`, or of type
nfs, smbfs, afpfs, webdav, cifs, ftp or a FUSE one. When the OS cannot tell, the file is
mapped there: the guard turns a failed read into failed calls. Windows has no such guard
(a failed read of a map is an in-page error that ends the program), so there `faAuto`
maps only a file on a fixed drive or a RAM disk (`GetDriveTypeW` of the volume of the
path made absolute, so a relative path counts where the current directory lies; a
`subst` drive by the folder it stands for; `\\?\` and `\\?\UNC\` paths too) that is no
cloud placeholder (a synced file whose data is fetched on access); a mapped network
drive, a `\\server\share` path, a removable drive, a CD-ROM, and a path the probe cannot
place are read unmapped. Name `faMapped` or `faUnmapped` to choose; `f.access` says what
an open used. A program built with `-d:parseSegUnmapped` opens every file unmapped
unless it says otherwise.

What each gives:

| | `faMapped` | `faUnmapped` |
|---|---|---|
| A read that fails (I/O error) | the guard turns the fault into failed reads, from that page on, for as long as the file is open (`readFailed`); open it again | that call fails: rows `dcIo` ("could not be read; read them again"), header, key and field calls and `openSeismic` raise `IOError` ("... try again"), the editor refuses the edit and its `close` raises; nothing is remembered, so the next call reads again |
| A read that waits (a hung share) | waits inside the page fault | waits inside `pread` |
| A cut | found by the first read of a page past it, or `cutShort` | found by a read that must fetch past it, or `cutShort`; bytes already in parseSEG's cache read as they were |
| Signals | a process-wide `SIGBUS` handler (POSIX) | none: an unmapped file installs no handler |
| Memory | the OS's page cache | up to 64 MiB a file in parseSEG's cache, besides the OS's, and what reads in progress hold (up to 8 MiB of samples for each read or prefetch chunk, 4 MiB for a header loop, an index cache file whole while it is read) |
| Cost | as fast as memory once cached | a copy of every byte read and a system call per request (below) |

**Is unmapped slower on a share?** No: there the round trips and the link cost the time,
and both ways make about the same requests for the same bytes. A viewer's first look at a
file (open it, its file headers, the keys and samples of a window of 2000 traces, then the
next record: keys and samples of 1000 more), medians of 3 runs, from a cold cache, with
every read that misses the page cache delayed by a round trip and the link's time for its
bytes:

| file | mapped / unmapped, data in this machine's cache | 1 ms round trip, 1 Gb/s | 20 ms, 1 Gb/s | 20 ms, no bandwidth limit |
|---|---:|---:|---:|---:|
| SEG-Y, 12 000 traces of 1000 samples (50 MB) | 3 / 13 ms | 217 / 132 ms | 248 / 266 ms | 85 / 196 ms |
| SEG-D 2.1, 12 records of 1000 traces of 1000 samples (48 MB) | 6 / 29 ms | 515 / 452 ms | 534 / 547 ms | 93 / 187 ms |
| SEG-Y, 500 000 traces of 250 samples (620 MB) | 4 / 10 ms | 112 / 78 ms | 130 / 156 ms | 38 / 121 ms |
| SEG-D 2.1, 500 000 traces of 100 samples (226 MB: the open walks every header) | 98 / 220 ms | 2214 / 2152 ms | 2234 / 2406 ms | 178 / 550 ms |

Unmapped made 6 to 20 requests for all of it (the open of the large SEG-D file 20 of 16
MiB). The mapped times are a lower bound: a page fault that waited for the device counts
as one round trip, and the kernel's read-ahead requests count only by their bytes. What
the simulation leaves out: a share client's own read-ahead and its pipelined requests
(NFS reads ahead about 15 times its read size, for maps and reads alike), and the server's
disk. Unmapped is slower where the network is not the cost: data already in this
machine's cache (on a local disk, warm: a random trace 32 µs against 0.4 µs, a window of
10 000 traces 8.8 ms against 1.8 ms, a header listing 67 µs against 4 µs; decoding a file
that fits the cache 9 to 11 GB/s against 14 to 15) and a share with no bandwidth limit and
long round trips. So local files stay mapped (`faAuto`), and a file on a share is read
unmapped: a failure there is an ordinary failed read, at about the cost of a map.

What a viewer may rely on, mapped or not:

- A thread stopped in a read holds no lock of parseSEG's: other threads go on reading,
  opening and closing other files (and, unmapped, the blocks of the same file that are in
  the cache). A file's map is unmapped and its descriptor closed outside the lock that
  all files share, so a close that waits on the share holds up only the thread that
  closes.
- `tryNext` never waits for a worker; `next`, `nextInto` and a direct read
  (`readTracesInto`, headers, keys, `cutShort`, which asks the OS too) wait as long as the
  share makes them.
- A prefetcher's `close`, and dropping it, wait for a worker stopped in a read for at
  most `closeTimeout` (2 s by default; `newPrefetcher(..., closeTimeout = ...)`,
  `close(timeout)`): then they give up on it, `close` returns false, and what the
  worker holds (its buffers, the file's map or read cache) stays alive until it returns
  and `reapPrefetchers` frees it (every later `newPrefetcher` and `close` does too). The
  UI thread may close a prefetcher of a network file. A worker inside your `transform`
  is waited for, however long. Each prefetcher given up on keeps its worker threads,
  its ring and its pin until the share answers, so a host that makes a new one after
  every give-up grows by that much each time: `reapPrefetchers()` says how many still
  wait. Freeing one drops what it pinned on the thread that reaps: when the file was
  closed meanwhile, that unmaps it and closes its descriptor, and a close(2) can wait on
  the share (a mapped file can also wait up to 2 s for a fault in flight in the map).
  Every `newPrefetcher` and `close` reaps, on whichever thread calls it, so a UI thread
  that makes prefetchers of local files may be the one that frees a given-up prefetcher
  of a share; a job thread that calls `reapPrefetchers()` now and then makes that rare.

What it must still do itself:

- Read network files on job threads only, and keep the UI on `tryNext` and on what is
  already decoded.
- Unmapped: show a failed read (`dcIo` rows, an `IOError`) and offer to read again; keep
  the file open, the next read tries the share again. A prefetcher does not read a
  failed chunk again by itself: `seek` back to it, or read its `failedRows` with
  `readTracesInto`. An editor batch whose writes failed still ends with `endBatch`
  true: the error is in its `log`, the journal keeps the edits and `close` raises
  `IOError`. Mapped: open the file again once the share is back (`readFailed`).
- Give up on a thread of your own that waits too long by leaving it alone: do not close
  the file it reads while it is stopped (a prefetcher's workers are taken care of: close
  the prefetcher, then the file, as usual). Keep the file (a list of abandoned files) and
  close it once the thread has returned. A read racing the close of its own file is a
  bug: with the guard it can end the program, but it never makes the guard map zero
  pages over memory the process reused (the close waits for the handler, for at most
  2 s, and past that leaves the map mapped).
- Watch a network file for changes (size, modification time) and open it again: an
  unmapped file does not see another program's change to bytes it holds in its cache.

## Files that live in memory

Some data never was a file: a vibrator controller's signature files, say, which a small
decoder turns into trace headers and samples. Write such a shot as SEG-Y or SEG-D into
memory and open it from memory, and the viewer needs no temporary file, no cache folder
and no clean-up. Everything after the open works as on a disk file: the index, headers,
keys, sample reads, gathers, summaries, prefetchers, and reads from several threads.

```nim
import parseSEG

# Write: a growable buffer instead of a path. Same options, same checks, same bytes as
# the file writer.
var w = openSeismicWriterBytes(SegyOutputOptions(text: @["VIBRATOR SIGNATURE"]), "sig.sgy")
var k = initTraceKeys()
k.intervalUs = 2000
k.record = 1
w.writeTrace(k, [0.5'f32, 1.5, -0.25, 0.0])
let bytes = w.finishBytes() # the whole file; nothing was written to disk

# Open: the bytes are moved in (no copy); the name is only for messages.
var f = openSeismicBytes(bytes, "sig.sgy", keys = true)
doAssert f.inMemory and f.path == "sig.sgy"
doAssert f.len == 1 and f.kind == skSegy
let x = f.readTraces(0 ..< 1)
doAssert x[0, 1] == 1.5'f32
f.close() # frees the bytes (a running prefetcher keeps them until it closes)
```

What to know:

- The file is as read-only as a mapped one, and reading it from many threads is as safe.
  The bytes are never copied by the open, and no file system call is made for the name,
  which can be anything (the same name for two files is allowed; give them different ones
  so that messages tell them apart).
- The open takes `bytes` over. It is moved in, with no copy, when the call is the last use
  of the `seq` or it is passed with `move` (the `seq` is then empty); a `seq` that is used
  again afterwards is copied, as Nim does for any `sink` parameter. A view of memory the
  caller owns is not offered: a prefetcher can outlive `close`, so the caller could not
  know when the memory may go.
- What needs a disk file is refused, in plain words, with `ValueError`: `saveIndex`
  (a cache is keyed on a path and its time stamps; `OpenOptions.cache` is ignored with an
  info diagnostic and the file is indexed), `openEditor(f)` (edits are journaled to a file
  next to the one edited), and a multiplexed SEG-D file (it is demultiplexed through a
  temporary file; convert it to a demultiplexed file first). `cutShort` and `readFailed`
  are always false; `f.access` is `faMapped` (the bytes are reached in place), and
  `f.inMemory` tells such a file from a mapped one.
- `openSeismicWriterBytes` takes the three writers' arguments (`SegyOutputOptions`,
  `SegdOutputOptions` or a `like` file) and `finishBytes` replaces `close`: it returns the
  bytes, with the counts known at the end patched in, byte for byte what the file writer
  writes for the same traces. SEG-2 is not written to memory. Use
  `finishBytes(w, log)` to receive the writer's warnings.
- Bytes that are no seismic file, or a truncated or damaged one, give the same
  diagnostics and errors as a file on disk, never a crash.

### Vendor data written with the file

A decoder that hands parseSEG vendor bytes of its own (a shot's controller record, say) can
keep them in the file, where a vendor map decodes them by name. SEG-Y: `addStanza` before the
first trace puts them in a binary stanza of the extended textual header. SEG-D Rev 3: the
first trace of a record passes them as `externalHeader`. Both work for a file and for bytes.

```nim
import parseSEG

var w = openSeismicWriterBytes(SegyOutputOptions(text: @["ACME SHOTS"]))
w.addStanza("acme", "Shot v1", [byte 0x41, 0x43, 0x4D, 0x45, 0, 7])
var k = initTraceKeys()
k.intervalUs = 2000
w.writeTrace(k, [1'f32, 2, 3])
var f = openSeismicBytes(w.finishBytes(), "shot.sgy")
let ext = f.index.segy.extended
doAssert ext.stanzas[0].key == "ACME:SHOTV1" and ext.stanzas[0].byteCount == 6
doAssert ext.data[ext.stanzas[0].dataStart ..< ext.stanzas[0].dataStart + 6][5] == 7
f.close()

var d = openSeismicWriterBytes(SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 3,
  time: 1_709_273_228.0))
var dk = initTraceKeys()
dk.record = 1
dk.channel = 1
dk.intervalUs = 2000
dk.srcLine = 1
dk.srcPoint = 1
dk.rcvLine = 1
dk.rcvPoint = 1
let header = newSeq[byte](64) # whole 32-byte blocks; the record's first trace sets it
d.writeTrace(dk, [1'f32, 2, 3], externalHeader = header)
var g = openSeismicBytes(d.finishBytes(), "shot.sgd")
doAssert g.index.segdRecords[0].external == header
g.close()
```

Stanzas come in call order (a `like` file's own extended records first; Rev 2's
`((SEG:EndText))` stays last); the binary header's count follows. Later traces of a SEG-D
record pass nothing or the same bytes; different ones are a `ValueError`. Stanzas need Rev 1
or later, an external header SEG-D from keys (Rev 3), at most 0xFFFFFF blocks of 32 bytes;
the reader holds 256 MiB of header areas by default, so a longer header reads back
`incomplete`.

## Survey files in the background

A viewer that lists a folder tells SPS from SEG P1 files with `looksLikeSps` on the first
bytes it reads of each (it rewinds the stream): data records decide (SPS point records
with grid coordinates, relation records with channel numbers; P1 records with hemisphere
letters), and a head of header records only, as SPS headers often fill more than 4 KiB,
is SPS when an `H00` record names SPS. `readSps` and `readP1` then read a file of any size
in the background: `progress` gets the bytes read and the file's size about every MiB and
once at the end, and cancels when it returns false (the records read so far stay, and the
log ends with a fatal `dcCancelled`).

```nim
import std/[streams, strutils]
import parseSEG

var lines = @["H00 SPS format version number   SPS 2.1;"]
for i in 0 ..< 30: lines.add "H26 " & repeat('.', 70)   # a long header block
for i in 0 ..< 1000:
  lines.add "R     10.00" & align($(100 + i) & ".00", 10) & "  1G1" & repeat(' ', 21) &
    "500100.0 6000000.0  12.5 18213250"
writeFile("receivers.r", lines.join("\r\n") & "\r\n")

let head = newFileStream("receivers.r")
doAssert looksLikeSps(newStringStream(head.readStr(2048))) # header records only
head.close()

var cancelled = false        # set by the cancel button
let hook: Progress = proc (done, total: int64): bool =
  not cancelled              # `total` is the file's size
let sps = readSps("receivers.r", SpsOptions(keepRaw: false, skipBinary: true,
  maxJunkBytes: 16 shl 20), progress = hook)
doAssert sps.points.len == 1000 and not sps.log.isFatal
```

- `SpsOptions.skipBinary` passes by lines that hold bytes no text holds (a NUL or another
  control character but tab, form feed and CR, or DEL; bytes above 127 are text, in UTF-8,
  Latin-1, CP1251 or another encoding, and never make a line binary): they are not read as
  records, a warning names each of the first few by its line, and one counts them all.
- `SpsOptions.maxJunkBytes` stops the read where a file turns into other data: once more
  than that many bytes in a row are lines that are no SPS record (an unknown record type,
  a binary line, a piece of an over-long line; blank lines neither end nor extend such a
  run). An error says from which byte, and `others` keeps at most about the bound. 0, the
  default, reads to the end.
- A "line" longer than 64 KiB (`MaxLineBytes`) is cut into records with a warning; its
  pieces keep the one line number (`TextRecord.index`, a diagnostic's `record`), so the
  lines after it are numbered as an editor numbers them.

### A large relation file: the map and the join

A 3D survey's X file holds tens of millions of records. `addSps(g, path)` reads it as a
map or a join needs it: values only (no raw text, `keepRaw = false`, and no text of the
line and point fields that are numbers, `keepNames = false`), with room for the file's
runs made at once (`reserveRelations`), at about 70 bytes a run. Files sorted by line
rather than by record, which give each record's rows among the others' (an O file
written source line by source line does too), cost the same: amortised O(log n) a row.
`relationCount` and `recordCount` are O(1), for a status line.

A viewer that holds such a file for its map joins it to traces without reading it again:
`applySurvey` takes the stations' coordinates from one geometry and the relations from
another, the same as one geometry holding both. It works on `TraceKeys`, a `TraceIndex`
or a `SeismicFile` (`f.applySurvey(stations, relations[, stats])`), in memory only.

```nim
import std/strutils
import parseSEG

const h00 = "H00 SPS format version number   SPS 2.1;"
proc card(kind: char, line, point: string, rest: string): string =
  kind & align(line, 10) & align(point, 10) & rest

var rs = @[h00]
for k in 0 ..< 10:
  rs.add card('R', "1001.00", $(101 + k) & ".00", "  1G1" & spaces(21) &
    align(formatFloat(600000.0 + 10 * float(k), ffDecimal, 1), 8) & " 6100000.0  83.2")
for rec in 1 .. 3:
  rs.add card('S', "2001.00", $(1000 + rec) & ".00", "  1E1" & spaces(21) &
    align(formatFloat(600000.0 + 10 * float(rec), ffDecimal, 1), 8) & " 6100010.0  80.0")
writeFile("survey.rs", rs.join("\n") & "\n")

# Three shots on two receiver lines, written line by line: each record's rows
# come among the other records'.
var x = @[h00]
for (line, first) in [("1001.00", 1), ("1002.00", 11)]:
  for rec in 1 .. 3:
    x.add "X" & spaces(6) & align($rec, 8) & "11" & align("2001.00", 10) &
      align($(1000 + rec) & ".00", 10) & "1" & align($first, 5) & align($(first + 9), 5) &
      "1" & align(line, 10) & align("101.00", 10) & align("110.00", 10) & "1"
writeFile("survey.x", x.join("\n") & "\n")

var relations = initSurveyGeometry()  # the map's: read once
relations.addSps("survey.x")
doAssert relations.relationCount == 6 and relations.recordCount == 3
var stations = initSurveyGeometry()   # new coordinates, read later
stations.addSps("survey.rs")

var k = initTraceKeys()
(k.record, k.channel) = (2.0, 4.0)
doAssert k.applySurvey(stations, relations)
doAssert k.rcvPoint == 104 and k.rcvX == 600030.0 and k.srcX == 600020.0

# Read without the names of numeric fields, a file is still written back as it was.
let lean = readSps("survey.x", SpsOptions(keepNames: false))
doAssert lean.relations[0].srcLineName == "" and lean.relations[0].srcLine == 2001
doAssert spsText(lean).text == readFile("survey.x")
var g = initSurveyGeometry()
g.reserveRelations(lean.relations.len)   # room for the runs at once
g.addSps(lean)
doAssert g.relationCount == 6
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

## Vendor fields

`decodeVendorAreas(reg, record, log)` (and the overload with a trace, or a SEG-Y file) gives
a `seq[VendorBlock]` beside the raw bytes: each block has `mapName`, `name`, `blockNumber`
and `fields`. What a viewer should expect from maps that find blocks by content:

- A block's `blockNumber` is its 1-based number in its area (extended or external header,
  general header number), or the trace header extension number; -1 for a whole area.
  When a file holds the same module twice, the same `name` comes twice, with different block
  numbers: show the number beside the name.
- A module that is not in the file gives no block and no diagnostic; do not list it.
- A field can be absent from `fields` without any message: its sentinel value, or a `(when)`
  condition of the map that does not hold (e.g. a layout that another byte excludes). Look
  fields up with `name in blk` before `blk["name"]`, which raises `KeyError`.
- A map can give several blocks for one area block (one per matched target, same
  `blockNumber`): show each by `name`.
- For a SEG-D record, build `let ctx = vendorContext(rec, reg.usesRecordBlocks)` once and
  call `decodeVendorAreas(reg, ctx, rec, trace, log)` for each trace. The overload without
  `ctx` rebuilds it (copying the record's header blocks when a map reads them) on every call.
- `VendorContext.extended`, `external` and `general` are copied only when a loaded map needs
  them (`hasBlock`, `(when (record ...))`); `vendorContext(rec)` always fills them, so
  `map.applies(ctx)` is exact.
- A map's `(layout)` (SEG-Y trace header entries, with an optional `divisor`: a number stored
  times 100) reaches the keys when the file is opened with the registry:
  `openSeismic(path, keys = true, opts = OpenOptions(vendors: reg))`. Pass it on every open
  of a file (also the one that reads the index cache: it is not used for a file such a map
  applies to), so the keys, the map and the joins all see the true numbers.

## Geometry, time and annotation

With `keys = true`, `traceKeys(i)` gives what an annotation bar or a base map needs.
Unknown values are NaN. `time` is the trace's UTC time in POSIX seconds (fractional):
time zero, except when a SEG-D Rev 3 Timestamp block supplied it. `timeOrigin`
says which header that was. `firstSampleUs` is sample 0 in whole UTC
microseconds. Sample skew, time-drift blocks and relative time mode are not
applied. SEG-2 stays `toNone`. The leap-second offset comes from the current table
([below](#leap-seconds-the-file-replacing-it-adding-one)).

| `timeOrigin` | Where `time` came from | `firstSampleUs` |
|---|---|---|
| `toNone` | Unknown, keys a caller built, or SEG-2 | none |
| `toFirstSample` | SEG-D Rev 3 Timestamp (0x42): time of sample 0 | that instant |
| `toRecordTimeZero` | SEG-D Rev 3 GH#3 time zero | that instant plus `t0Ms` |
| `toHeaderSeconds` | Header clock of whole seconds (SEG-D GH#1, SEG-Y without a fraction) | that instant plus `t0Ms` |
| `toHeaderSubsec` | Header clock with a sub-second part (SEG-Y nanoseconds) | that instant plus `t0Ms` |

`sampleTimeUs(k, n)` is sample `n` in UTC microseconds. `sampleAtUs(k, us)` is
the fractional sample index (NaN when the start or the interval is missing).

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

A node's attitude, when the file carries a SEG-D Rev 3 Orientation header (0x60), is
`traceOrientation(i)`: an `Option[SegdOrientation]`, none when that trace has no block. It
does not need stored keys, and it finds the block wherever another writer put it in the
trace header extensions, so it is cheap enough to call for every trace of a record. The
first block wins; a second block is not reported. A 0x60 in the
general header is not that trace's attitude: the standard's text does not say the block
applies to every trace without its own ("A block (e.g. Position 50-52, Additional Source
Info 20, Aux Channel Ref 21) applies to the preceding Source Description block"). Read
the record's block with `recordOrientation(record)`.

A Position block in the trace extensions that does not follow a source description is the
receiver's coordinates, even when the only source description is in the general header.
That is how a shot gather is written, and how INOVA files are read: do not take that
position as the source's. A source position attaches only to the source description the
keys selected, not to a later description on the same trace. Write-back uses that rule.

```nim
import std/options
import parseSEG

var k = initTraceKeys()
k.record = 1
k.channel = 1
k.intervalUs = 1000
k.time = 1_709_273_228.0
k.status = tsLive
let att = initTraceOrientation(0.1'f32, -0.2'f32, 1.5'f32, orientationType = 1,
  refOrientationValid = true, rotationApplied = true)
var w = openSeismicWriter("node.sgd", SegdOutputOptions(sampleIntervalUs: 1000,
  numSamples: 4, time: k.time))
w.writeTrace(k, @[1'f32, 2, 3, 4], orientation = some(att))
discard w.close()
var f = openSeismic("node.sgd")
let o = f.traceOrientation(0)
doAssert o.isSome and o.get.rotationZ == 1.5'f32 and o.get.orientationType == 1
doAssert f.traceOrientation(0).get.rotationApplied == 1
f.close()
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

## leap seconds: the file, replacing it, adding one

The GPS−UTC offset is not compiled in. `data/leapseconds.nif` is the shipped
table (IERS Bulletin C, complete through 2016-12-31), embedded so the library
works with no file present. `defaultLeapTable` is that table.
`currentLeapTable` is the one every converter uses, the shipped one until
`useLeapTable`. A key already read keeps the instant it was given: after
replacing the table, re-read the keys.

`checkedTo` is the last UTC date the list is known complete. After that day
the converters still return the last offset, and `leapKnownAt` is false, so
the viewer can warn. `parseSEG leapseconds` prints the current table;
`parseSEG leapseconds --file X.nif` checks a file and prints its problems.

`withLeap` is the "add a leap second" action. The new offset starts at
00:00:00 UTC on `date`, which is the day after a month end: 1 July and
1 January by convention, the first of any other month as well. `step` is
+1 or −1. `checkedTo` is left as it was.

```nim
import parseSEG

proc addOne() =
  defer: useLeapTable(defaultLeapTable())
  let june2017 = 1496275200'i64 # 2017-06-01T00:00:00Z, after checkedTo
  let june2018 = 1527811200'i64 # 2018-06-01T00:00:00Z
  doAssert utcMinusGps(june2017 * 1_000_000) == -18
  doAssert not leapKnownAt(june2017 * 1_000_000)
  let added = currentLeapTable().withLeap(LeapDate(year: 2018, month: 1, day: 1))
  let back = parseLeapTable(leapTableNif(added))
  doAssert back.problems.len == 0
  useLeapTable(back.table)
  doAssert utcMinusGps(june2017 * 1_000_000) == -18
  doAssert utcMinusGps(june2018 * 1_000_000) == -19
  doAssert not leapKnownAt(june2018 * 1_000_000)

addOne()
```

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
