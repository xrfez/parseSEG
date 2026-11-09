# Recipes for a seismic viewer

A viewer needs four things from a data library: a cheap overview of a file of any size,
random access to any trace range or gather without blocking the UI, the headers of the
trace under the cursor, and a way to keep the user's header changes without touching the
file. This page shows each with parseSEG. Read [getting-started.md](getting-started.md)
first for the concepts (trace numbers, records, channel sets, keys, gathers).

## Open a file and build the navigation tree

Open with `keys = true` when the viewer shows geometry or gathers. The walk reads headers
only, so this is fast even for files far larger than RAM.

```nim
import std/[math, strutils]
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", keys = true)
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
- SEG-D traces are in file order, which is not necessarily channel set order: in the sample
  above, trace 1 is in channel set index 2 and trace 2 in index 1. Use `traceEntry(i).channelSetIndex`
  instead of assuming.
- Gather kinds are derived from the keys. A post-stack SEG-Y volume such as the Inglewood
  sample is a single gather of kind `gkUnknown`: there is no source or receiver to group by.

## Read what is on screen

`readTraces` returns a new tensor; `readTracesInto` decodes into one you already have, so a
viewer can keep one buffer per viewport and refill it on every scroll without allocating.
Rows are cut or zero-padded to the buffer's width.

```nim
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")

# A range: the 50 traces from trace 100 on, all samples.
let panel = f.readTraces(100 ..< 150)
doAssert panel.shape == [50, 2001]

# A viewport buffer, reused: 64 traces of up to 2001 samples (longer ones would be cut).
var view = newTraceTensor[float32](64, 2001)
var log: DiagLog
for first in countup(0, 128, 64):            # the user scrolls right
  # (this sample holds live data in traces 93..116 only: the other panels are zero)
  let failed = f.readTracesInto(first ..< first + 64, view, 0, log)
  doAssert failed == 0                        # undecodable traces would be zero rows
  echo "traces ", first, "..", first + 63, ": peak ", max(abs(view))

# A selection, in the order given: every tenth trace, newest first.
var picks: seq[int]
for i in countdown(f.len - 1, 0, 10): picks.add i
let decimated = f.readTraces(picks)
doAssert decimated.shape == [20, 2001]
```

Decoding always starts at the trace's first sample: a buffer narrower than the trace keeps
the first `width` samples. There is no call that decodes only a deep time window.

### Gathers and multi-component stations

A gather's `traces` is a range; pass it to `readTraces` as it is. To hide auxiliary traces,
filter with `isSeismic`. For multi-component data, `componentGroupIds` labels each trace
with its station group (-1 for traces in none), so the viewer can show one station's
components side by side.

```nim
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", keys = true)
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

## Read ahead without blocking the UI

A `Prefetcher` decodes chunks of traces on a worker thread into a bounded ring. The UI
thread polls with `tryNext` (never blocks) or waits with `next`, and calls `seek` when the
user jumps elsewhere: chunks decoded for the old position are dropped. Each chunk's
`samples` tensor belongs to the caller; the worker never writes it again.

```nim
import std/os
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")
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
p.close()                             # before the file goes: the worker reads its map
f.close()
```

- In range mode a prefetcher accepts any span of the file in `seek` (`p.len` is the trace
  count), so one prefetcher can serve a whole session. `newPrefetcher(f, @[...])` reads
  a selection instead; its positions index the list (`traceAt` maps them back).
- `cols` fixes the row width (default: the longest trace of the range).
- A trace that cannot be decoded is a zero row, counted in `c.failed`, with an error in
  `c.log` that names the trace.
- Close the prefetcher before the file, and call its procs from one thread.

## The header tab

`traceHeaders(i)`, `recordHeaders(r)` and `fileHeaders` list every header block of a trace,
SEG-D record or file as rows: block name, field name, decoded value, and the byte offset and
size of both the field and its block. `copyBytes(blockOffset, blockSize)` gives the raw
bytes for a hex pane, and the row's offset and size highlight the field in it.

```nim
import std/strutils
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/63.sgd")
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

## Geometry, time and annotation

With `keys = true`, `traceKeys(i)` gives what an annotation bar or a base map needs.
Unknown values are NaN. `time` is the trace's UTC time in POSIX seconds (fractional).

```nim
import std/[math, times]
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", keys = true)
let k = f.traceKeys(3)
echo "source ", k.srcLine, "/", k.srcPoint, " at (", k.srcX, ", ", k.srcY, ")"
echo "receiver ", k.rcvLine, "/", k.rcvPoint, " at (", k.rcvX, ", ", k.rcvY, ")"
echo "offset ", round(k.offset, 1), ", recorded ", fromUnixFloat(k.time).utc
echo "sample interval ", f.sampleIntervalUs(3), " us"
doAssert abs(k.offset - 8490.11) < 0.01 and f.sampleIntervalUs(3) == 1000
```

### Inline and crossline of post-stack SEG-Y

`TraceKeys` describes acquisition geometry. Post-stack volumes are addressed by inline and
crossline instead, which many files keep in non-standard bytes and describe in a SEG-Y
Layout stanza (the Inglewood sample keeps the inline at byte 13). The streaming SEG-Y
reader resolves those names through the file's layout (`fieldValue(file, trace, "iline")`);
read the headers once with `headersOnly` and keep the numbers:

```nim
import std/options
import parseSEG

var src = openDiskSource("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")
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

`traceField(f, i, "trace.inlineNumber")` reads the standard bytes 189-192 only, which this
file leaves at 0.

## Keep the user's header edits as a patch

A viewer should not write to the file while the user experiments. Collect the changes in a
`HeaderPatch` and save it; applying it later is an explicit step ([editing.md](editing.md)).

```nim
import parseSEG

var patch = initHeaderPatch()
patch.add(hsTrace, 5, "trace.sourceX", toFieldValue(1_700_000))
patch.add(hsTrace, 6, "trace.sourceX", toFieldValue(1_700_025))
patch.add(hsFile, 0, "binary.jobId", toFieldValue(7))
patch.write("viewer-edits.nif")
doAssert patch.len == 3
echo readFile("viewer-edits.nif")
```
