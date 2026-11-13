# parseSEG API reference

`import parseSEG` gives the surface listed here (`PackageVersion` is the package version). This page is the reference; for
task-oriented guides with tested examples (viewers, processing, editing, conversion,
diagnostics) see [`docs/guide/`](guide/README.md). The main sections describe the
everyday API; [Supporting types and lower-level names](#supporting-types-and-lower-level-names)
at the end lists the rest of what the umbrella exports, one line per group. The library's own
helpers are in `parseSEG/private/`, which nothing re-exports; the few procs a public module
exports for the library's use (doc comment **Internal.**) are kept out by the umbrella's
allowlists, which `tests/tdocs.nim` checks against this page. Beyond the umbrella:
- `parseSEG/codecs` holds the byte codecs (BCD, IBM float, EBCDIC) and the field-layout
  pragmas;
- the `parseSEG/<area>/<module>` paths can still be imported one by one.

Conventions that hold throughout:
- **Reads never raise on file content.** Problems go into a `DiagLog` (`log` /
  `diagnostics`) with a severity, code, offset and location. A read ends early only on
  truncation or I/O failure, and that is logged as `fatal`.
- **Bad arguments raise `ValueError`.** An out-of-range trace or range, a closed file, or a
  file opened without `keys` where keys are needed, raise a catchable `ValueError` from the
  public procs.
- **Lookups: a raising form for required data, an `Option` for optional data.**
  `traceField(f, trace, name): FieldValue` raises `ValueError` (with the reason) when the
  field cannot be read; `findTraceField(f, trace, name): Option[FieldValue]` returns none.
  The same pattern holds across the library (`findChannelSet`, `fieldValue`,
  `parseFortranFloat`, `resolveLine`, `relation`, ...); no lookup fills `var` results.
- **Trace ranges are `Slice[int]`** (`0 ..< f.len`, both ends included as in Nim) and
  selections are `openArray[int]`; both parameters are named `traces`. An empty range
  (`a > b`) must still start in `0 .. f.len` (`f.len .. f.len - 1` is valid, `7..6` on five
  traces raises `ValueError`).
- **Samples are Arraymancer tensors** `[traces, samples]` (`float32`, or `float64` where it
  matters). Headers are plain objects that keep their raw bytes, so a write → read round
  trip is byte-identical.
- **Offsets are 64-bit**, and nothing loads a whole file unless asked to (`readSegy`,
  `readSegd`).

## Opening and indexing (any size, disk)
| Proc | What |
|---|---|
| `openSeismic(path, keys = false, progress: Progress = nil, opts = OpenOptions()): SeismicFile`; `OpenOptions` (`verify = vfSampled`, `cache`, `demuxDir`, `twosComplement8015`, `kind = skUnknown`) | Memory-maps the file, detects SEG-Y, SEG-D or SEG-2 (`opts.kind` names the standard instead, for a file detection does not recognize), and builds the trace index (`index`, 24 B per trace). With `keys`, also collects per-trace geometry (`TraceKeys`, 184 B per trace). Multiplexed SEG-D (formats 0015 ... 0058) is demultiplexed once into a temporary copy in `opts.demuxDir` (default: the OS temp dir; `f.demuxPath`, a warning in `f.log`), which is indexed instead and deleted on `close`; `openEditor` refuses such a file (`ValueError`). `progress` reports the walk (below); `opts.cache` names an index cache (below). `opts.verify` (`VerifyMode`: `vfSampled`, `vfFull`): by default a fixed-length SEG-Y file (Rev 1+, binary bytes 3503-3504 = 1, no Rev 2 extension headers or trailers, a size of whole traces) is indexed from its size, with 64 trace headers (first, last, spread between) checked for the binary header's sample count and interval and an info `dcIndexSampled` saying how many; any disagreement falls back to the walk. The entries are the walk's; per-trace warnings of unsampled headers are not made. With `keys`, the keys of such a file are then read from the mapped trace headers in one pass (the same keys as the walk's). `vfFull` always walks. |
| `Progress = proc (done, total: int64): bool {.closure, gcsafe, raises: [].}` | A progress and cancel hook: input bytes done and the input's size (-1 if unknown), about every MiB (`ProgressStep`) and once at the end (`done == total`); return false to cancel. Never per trace: a nil hook (the default) costs one comparison per trace. `openSeismic`, `buildIndex` and `exportHeaders` raise `SegCancelledError` when cancelled (the file is unmapped, no output is left); `convertFile`, `convertSegy`, `convertSegdToSegy`, `convertSeg2ToSegy`, `convertToSeg2`, `convertSeg2ToSegd`, `convertSegdRevision`, `copyWithGeometry` and `convertWithGeometry` take it as their last parameter and return a fatal `dcCancelled` with nothing written. Operations that read the input more than once (a header scan first, SEG-2 input, a copy then an index) spread their passes over one `0 .. total` run. The hook must be gcsafe: capture a parameter or a local `ref`, not a global. |
| `saveIndex(f, path)`, `f.fromCache` | Write `f`'s index as an index cache: entries, codecs, file and record headers, the walk's diagnostics and keys (if opened with them), about 24 B per trace (+ 184 with keys), a NIF header with the file's stamps and a checksum. `openSeismic(path, opts = OpenOptions(cache: cachePath))` reads it instead of walking the file when it was saved for the same path, size, modification time and first/last 64 KiB, with the same `twosComplement8015` (and keys, when asked for), by the same parseSEG version, and is intact (and, for `verify = vfFull`, not from a sampled open); otherwise it walks the file and logs why (`dcIndexCache`, info). `fromCache` says which. `saveIndex` raises `ValueError` for a closed or unrecognized file, a demultiplexed copy, keys changed by `applyGeometry`/`applySurvey`, a file changed since it was opened, or the file itself as `path`. |
| `detectKind(bytes): SeismicKind` | Detection only, from a file's first bytes (pass 3728 or more): a SEG-2 block ID, a SEG-D label, Table of Contents or General Header #1, SEG-Y `C` card text, and last a SEG-Y binary header behind a textual header that is not card text (blank, zero-filled, free text; with or without a tape label). `skUnknown` when nothing fits. |
| `buildIndex(src: RecordSource, kind, keys = false, progress = nil, verify = vfFull): TraceIndex` | The same index from any source: disk, tape image or tape device (`contiguous` is false for tape). Walks every trace unless `verify = vfSampled` (a fixed-length SEG-Y `MemFileSource`, as `openSeismic`; with `keys`, they are read from the mapped headers). SEG-2 needs a `MemFileSource` (`ValueError` otherwise). |
| `f.len`, `f.kind` (`SeismicKind`: `skSegy`, `skSegd`, `skSeg2`, `skUnknown`), `f.log`, `f.recordCount`, `f.maxSamples`, `f.hasKeys`, `f.isOpen`, `f.path`, `f.demuxPath` | File facts. |
| `f.traceEntry(i)` (`TraceEntry`), `f.traceKeys(i)` (`TraceKeys`), `f.copyBytes(offset, n)`, `f.sampleIntervalUs(i)` | One trace's location, geometry, raw bytes and sample interval (`ValueError` for a trace out of range; `sampleIntervalUs` and `copyBytes` also for a closed file). |
| `f.summary` (`FileSummary`), `f.channelSets` (`seq[ChannelSetSummary]`), `f.crsText` | Common metadata with no branch on the standard (task 6.8): standard and revision, byte order, format code, trace/record counts, first/last field record, sample interval, samples per trace and record length (NaN / -1 when not uniform), coordinate units (`CoordinateUnits`) and the CRS text's format (`CrsTextFormat`). `channelSets` gives each SEG-D channel set's interval, timing and trace count; `crsText` the CRS text (P1/11 or Location Data). |
| `f.index.segy`, `f.index.segdRecords`, `f.index.seg2`, `f.seg2Trace(i)`, `f.close()` | The format's own headers (`seg2Trace` re-reads a SEG-2 Trace Descriptor Block from the map). A `SeismicFile` that goes out of scope unmaps itself; `close` does it early. |

## Reading samples
| Proc | What |
|---|---|
| `readTraces(f, traces: Slice[int], log, T = float32)` | A range as a new tensor; a trace that cannot be decoded is a zero row and an error in `log`. |
| `readTraces(f, traces: openArray[int], log, T)` | A **selection** (gather, component group, sort order) in list order. |
| `readTraces(f, traces, T = float32)` | Without a log: raises `SegFormatError` (`SegTruncatedError`) naming the first trace that cannot be decoded. |
| `readTracesInto(f, traces, var tensor[, log], row = 0): int`, `readTracesInto(f, traces[, samples], var tensor, var failedRows: seq[int], row = 0): int` | Decode a range or a selection into an existing tensor; returns the number of traces left zero (logged in `log`). The `failedRows` form reports them as the prefetcher does instead, without a log: the list is cleared, then holds each such trace's position in `traces` (0-based, ascending), and keeps its capacity, so a reused list does not allocate, even when traces fail. Before a read of 32 traces or 1 MB that is not in memory (probed at the last trace of a range, at both ends of a selection), both forms ask the OS to read the traces' pages ahead (`madvise(MADV_WILLNEED)`, POSIX), except for a range that continues a sequential read. |
| `readTraces(f, traces, samples: Slice[int][, log], T)`, `readTracesInto(f, traces, samples, var tensor[, log], row = 0): int` | A **sample window** (`a..b`, 0-based) of a range or selection: `[traces, samples.len]`, and the tensor's width must be `samples.len`. Only the window's bytes are decoded (SEG-D 8015 and SEG-2 format 3, 4 samples in 10 bytes, also decode the rest of the group the window starts in); zero past a trace's end. `ValueError` for an empty window or one starting below 0. |
| `maxSamples(f, traces)` | Longest trace of a range or selection. |
| `newTraceTensor[T](traces, samples)` | A zero-filled `[traces, samples]` tensor to decode into (`T` is a `SampleType`: `float32` or `float64`). This and the next row are in `common/tensors`, which also re-exports Arraymancer's CPU tensor API (`arraymancer/tensor` without its CUDA/OpenCL backends). |
| `decodeTrace(t, row, format, src, samples, ...)`, `encodeTrace(t, row, format, dst, samples, ...)` | One row of a tensor from or to raw sample bytes, for a SEG-Y `SampleFormat`, a `SegdSampleFormat` or a `Seg2SampleFormat` (as `decodeSamples` & co). |
| `newPrefetcher[T](f, traces, chunkTraces, depth, cols, firstSample = 0, workers = 1, quickFirst = false, maxRingBytes = DefaultRingBytes, uniform = false, transform: ChunkTransform[T] = nil, user: pointer = nil)` (a range or a list) | Read-ahead on `workers` threads, chunks delivered in order whatever the count (rows hold samples `firstSample ..< firstSample + cols`). The ring holds at most `maxRingBytes` of chunks (`DefaultRingBytes`, 4 MiB, so a decoded chunk is still in cache when taken), but at least `workers + 1` and at most `depth`; `p.depth` is the depth used. `quickFirst`: the first chunk of the range and after each `seek` has `chunkTraces div 4` traces (at least 1), the rest follow at full size from there (`c.first`/`c.count` show the boundaries). `tryNext` (never blocks), `next`, `for c in p.chunks`, `nextInto` / `tryNextInto` (the caller gives up `c.samples`: swapped into the slot, so a steady consumer allocates nothing), `recycle(p, chunk or tensor)` (a buffer for a later chunk; reused only if of the chunk shape and unshared, at most `depth` kept), `seek(span)`, `atEnd`, `traceAt`, `len` (positions), `close`. A `Prefetcher` is not copyable and belongs to the thread that made it; it keeps the file's map and index tables alive until its `close` (after the file is closed or handed to an editor its chunks show the keys of that moment). Several threads may each make and close their own prefetchers on one open file; the index must not change, and the file must not be closed, while another thread uses it. A `seek` or `close` makes a worker give up the chunk it is decoding. A chunk shorter than `chunkTraces` has a view of a whole chunk buffer as `samples` (`clone` it to keep it for long). A `PrefetchChunk` has `first`, `count`, `samples`, `failed`, `failedRows` (those rows, 0-based in the chunk), `firstSample` (the trace sample in column 0, the prefetcher's `firstSample`), `log` (one error per trace left zero, with its trace index) and `rows` (a `TraceRows` of the chunk: trace, keys when the file has stored keys, sample count, channel set; valid until `close`). `uniform` (needs stored keys): a chunk never spans two channel sets or sample intervals, it is cut short at the boundary. `transform` (`ChunkTransform[T]`, `{.nimcall, gcsafe, raises: [].}`) runs on the worker right after each chunk is decoded with the worker index, the raw rows and their shape, the chunk's `TraceRows`, its failed rows and `user`; a `Defect` raised in it ends the process, and a chunk dropped by a `seek` is not transformed. |

Bad caller input (a trace, range or position out of range, a closed file) raises
`ValueError` everywhere.

Sorting is a selection: a sort produces a list of trace indices, and no data is moved.

| Proc | What |
|---|---|
| `f.sortTraces(by: openArray[string][, traces]): seq[int]` (`model/sorting`) | The traces (all, a range or a list) sorted by numeric header fields (`traceFieldColumn` names), first key first: ascending, stable, NaN last, -0 = 0. A permutation of trace indices for the list forms of `readTraces` / `newPrefetcher`. One column read per key, then a radix sort: 10 M traces in about 0.2 s per key plus the column reads. |
| `sortOrder(columns: openArray[seq[float64]]): seq[int]` | The same order over the caller's own columns (e.g. `TraceKeys` fields): the sorted row positions. |

## Headers
| Proc | What |
|---|---|
| `traceField(f, trace, "trace.sourceX")`, `recordField(f, record, "gh1.year")`, `fileField(f, "binary.sampleInterval")` | Any named header field, read from the map, as a `FieldValue` (`intVal`, `floatVal` or `text` by `kind`). Raises `ValueError` for an unknown name, trace or record. |
| `f.textHeader: string`, `f.extendedTextHeaders: seq[string]` | SEG-Y: the textual file header decoded (EBCDIC or ASCII, as detected) to 40 lines of 80 characters joined by `'\n'`; each extended textual header record the same way (Rev 1+; stanzas are parsed in `f.index.segy.extended`). `ValueError` for another standard. |
| `findTraceField`, `findRecordField`, `findFileField` | The same, as an `Option[FieldValue]` (none when the field cannot be read). |
| `f.traceFieldColumn(name, traces): seq[float64]`, `f.traceFieldColumnInto(name, traces, dst: var openArray[float64])` | One numeric trace field (`trace.<field>`, `ext1.<field>`; SEG-2 keyword strings parsed as numbers) for a list or range of traces. The field is resolved once and only its bytes are read per trace. NaN where the trace lacks the block (no `ext1`); `ValueError` for an unknown, text or raw field, a trace out of range or a closed file. |
| `fieldNames(HeaderBlock)`, `f.blockKind(scope, index, "ext1")`, `h.fieldByName("sourceX")` | The fields of a block kind (a constant list, lent: a call allocates nothing); the kind of a file's block (`hsFile`, `hsRecord`, `hsTrace`); a field of a decoded header object (`Option`). |
| `f.traceHeaders(i)`, `f.recordHeaders(r)`, `f.fileHeaders` (`seq[HeaderRow]`) | A viewer's headers tab (task 6.10, `model/headerlist`): every header block of a trace, SEG-D record or the file as ordered rows of `blockName`, `kind` (`HeaderBlock`, `hbRaw` for blocks without named fields), `field`, `value`, `offset`, `size`, `blockOffset`, `blockSize` (raw bytes for a hex pane: `copyBytes(blockOffset, blockSize)`). It covers the blocks the trace or record has: SEG-Y `trace`/`ext1`/`ext2..`, SEG-D `trace`/`ext1`/`ext2..` (Rev 3 blocks typed by byte 32), `gh1`, `gh2`, ..., `st<s>cs<c>`, `extended`, `external`, `trailer`; SEG-Y `label`, `text`, `binary`, `extended`, `trailer`; SEG-2 `file` and `trace` (fixed fields, then one row per keyword string: `field` = keyword, `offset`/`size` = the string entry). Read-only; names as in `traceField` and the editor. |
| `readSegyHeaders(path)`, `readSegdHeaders(path)`; `openSegy`/`openSegd(src, headersOnly = true)` | Every header object, samples skipped (also on tape). |
| `traceKeys(...)`, `TraceKeys` | Per-trace geometry (record, source and receiver line/point/index/coordinates, component; SEG-Y: all through the file's layout, the source point with its fraction when the scaled shotpoint carries it, and the stations a Layout stanza names as `sht_line`/`sht_point`/`sht_index`/`rec_line`/`rec_point`/`rec_index`, so a SEG-D file converted to SEG-Y keeps them) and the trace's UTC time (`time`, POSIX seconds, NaN if unknown; task 6.9: SEG-Y bytes 157-168 with the time basis, SEG-D GH#1, Rev 3 GH#3 time zero or the trace's Timestamp block). Also its timing and kind: `t0Ms` (time of sample 0 in ms: SEG-Y delay × time scalar, SEG-D channel set start time, SEG-2 DELAY), `intervalUs` (as `sampleIntervalUs`), `inline`/`crossline` (SEG-Y layout `iline`/`xline`), `traceCode` (SEG-Y trace identification code) and `status` (`TraceStatus`: `tsUnknown`, `tsLive`, `tsDead`, `tsAuxiliary`; `segdStatus(rec, trace)` for SEG-D). |
| `f.startTimeMs(i)`, `f.startTimeMsInto(traces, dst: var openArray[float64])` | `t0Ms` of one trace, a list or a range, also without stored keys (read from the headers then). |
| `f.ensureKeys(progress = nil)`, `f.keysRevision` | `ensureKeys` builds the stored keys of a file opened without them, as `openSeismic(keys = true)` would (a no-op when they exist; `SegCancelledError` when `progress` cancels). `keysRevision` is 0 as opened and goes up whenever the stored keys change (`ensureKeys`, `applyGeometry`, `applySurvey`, `HeaderEditor` writes): tag derived data with it. A `TraceRows` view or a `Prefetcher` made before `ensureKeys` stays without keys: make it again. `TraceIndex.joinedTraces` / `joinedGroups(index, trace)` record which keys a join changed, as a `set[JoinGroup]` (one byte per trace): `jgSourceXy`, `jgReceiverXy`, `jgSourceZ`, `jgReceiverZ`, `jgDerived` (offset and midpoint), `jgSourceStation`, `jgReceiverStation` (line, point, index), `jgComponent`. Code that joins geometry itself calls `markJoined(index, trace, groups)` with what it changed; `changedGroups(before, after)` gives that from a trace's keys before and after. |
| `rowsOf(f, traces: Slice or openArray[int])`, `rowsOf(keys, numSamples)`; `TraceRows` | A zero-copy view of rows to traces (Phase 16): `len`, `traceOf(row)`, `traceKeys(row)` (in place, `lent`; `ValueError` without keys), `keysAt(row)` (the same without raising, for callers that checked `hasKeys` once: a `{.raises: [].}` kernel, a `ChunkTransform`; no keys is an `AssertionDefect` with bound checks on), `hasKeys`, `numSamples(row)`, `channelSetIndex(row)`, `sub(rows)`. Holds raw pointers into the index (or the caller's arrays), so it can be copied into worker threads; valid while the file stays open (and a selection's list lives). Needs stored keys (`ValueError`). |
| `for run in f.uniformRuns(traces: Slice or openArray[int])` | Splits traces (a range: trace slices; a list: position slices) into runs that share one channel set, sample interval and sample count, so each reads into one tensor with one `dt` and no padding (prefetch `uniform` chunks do not split on sample count). |
| `f.traceStatics(traces): seq[TraceStatics]`, `f.traceStaticsInto(traces, dst)`, `initTraceStatics` (`model/statics`) | SEG-Y datum, depth, uphole, statics and weathering fields per trace, read on demand (kept out of `TraceKeys`): `srcDepth`, `rcvDepth` (Ext1 only), `rcvDatum`, `srcDatum`, `weatheringVelocity`, `subweatheringVelocity`, `srcUphole`, `rcvUphole`, `srcStatic`, `rcvStatic`, `totalStatic` (ms). Scaled by bytes 69-70 and the time scalar (Rev 1+); Ext1 copies override when non-zero; NaN for SEG-D and SEG-2. The two datum elevations are NaN when both standard fields (bytes 53-60) are 0, a header never given a datum, unless Extension 1 gives them. |
| `f.traceKeys(traces): seq[TraceKeys]`, `f.traceKeysInto(traces, dst: var openArray[TraceKeys])` | Keys of a list or range of traces. Without `keys = true` they are made on demand from the mapped headers, the same as the index walk makes them (the file's own geometry: `applyGeometry`/`applySurvey` changes are only in stored keys); with it the stored keys are copied. |

## Gathers and components
`gathers(f or index)`: a split into `Gather` (`kind`, a `GatherKind`: shot, receiver, cmp, offset, other or
unknown; `traces`; `sources`; `receivers`), derived from the geometry, never assumed.
`classify(index, range)`. `componentGroups(f or index, traces)` returns a `ComponentGroup`
(station, traces, components) per station and source; see `isMultiComponent`.
`componentGroupIds(f, traces)` labels each trace with its group (-1 for none).
`isSeismic(index, trace)` is false for auxiliary traces: with keys, those whose
`TraceKeys.status` is `tsAuxiliary` (SEG-Y auxiliary trace codes included; `isSeismic(keys)`);
without keys, SEG-D channel types other than seismic or EM and SEG-2 `TEST_DATA` and `UPHOLE`
traces (SEG-Y traces then count as seismic).

## Survey files and external geometry (Phase 10)
SPS (Rev 1.0, 2.1) and SEG P1 (1983) give the coordinates that SEG-D 2.x headers lack, SPS
X records name the stations each channel was recorded from, and O records (`.ops`) do the same
in the receiver domain. Traces are joined by their stations; record numbers are a fallback. Spec notes: `docs/spec/sps.md`,
`docs/spec/p1_p2_p3.md`.

| Proc | What |
|---|---|
| `readSps(path or stream, SpsOptions)`, `parseSps(text)` → `SpsFile` | H, R/S (`points`, `kind` `pkReceiver`/`pkSource`), X and O (`relations`, `recordType`) and C records; revision from H00, else from the column layout of the first data records with a warning (`SpsOptions.revision` chooses). Every record keeps its raw text (`SpsOptions(keepRaw: false)`: values only, in less memory; `addSps(g, path)` reads that way). About 200 MB/s. Blank integers are `MissingInt`, blank reals NaN; `inf`, `nan` and overflowing exponents are not numbers. Problems are diagnostics in `log`, the first 5 of each code and field, then a count; a UTF-8 byte order mark is skipped. |
| `writeSps(f, path or stream, SpsWriteOptions(revision, lineEnding, lenient))`, `spsText(f)` (a `SurveyText`: `text`, `log`), `encodeSps(record, rev)` | Column-exact; unchanged records byte for byte; 1.0 ↔ 2.1. A value that does not fit is an error and nothing is written (unless `lenient`). An `SpsFile` built by hand is written the same way (`SpsFile().revision` is `sps21`). |
| `readP1(path or stream, P1Options(gridDecimals, depthDecimals, angleUnit))`, `parseP1` → `P1File` | Logical files (`files`), each with its header text and records; P1 decoded, P2-P4 kept raw. `auAuto` (the default) decides DMS or grads once per file from its first P1 records (`options.angleUnit` holds the result; an info when it is grads). Diagnostics are capped as for `readSps`; a read that finds no data record says so (and when the records hold grid coordinates without latitude and longitude). |
| `writeP1(f, path or stream, P1WriteOptions)`, `p1Text(f)` (a `SurveyText`), `encodeP1(record, opts)` | Header blocks padded to 20 records; unchanged records byte for byte. |
| `SurveyGeometry` (`initSurveyGeometry()`): `addSps(g, sps, xDomain = rdSource)`, `addSps(g, path, opts, xDomain = relationDomainOf(path))`, `addP1(g, p1 or path[, P1Options], elevation)`, `addSource`/`addReceiver`, `relation(g, record, channel, domain = rdSource)` (an `Option[StationRelation]`), `resolveLine(g, name, numeric)` (an `Option`) | Station coordinates (`table`, `sourceCount`, `receiverCount`) and relation runs (`relationCount(g, domain)`) of both domains (`RelationDomain`: `rdSource` X, `rdReceiver` O; X records of an `.ops` file are O by default). Text line names go through `mapLine(g, name, line)` (`lineNames`), then `trailingDigits`. `multiComponent`, `tape` refine relations; problems are in `log` (the first 5 of a kind per file, then a count), among them a station given twice: a warning when its coordinates differ (the later ones are used), an info when they are the same. |
| `records(g, domain)`, `relations(g, record, domain)` (iterators: ascending records; `(channel, relation)` per channel, a channel two runs cover once), `expectedChannels(g, record, domain)`, `recordsAt(g, station, domain)`, `channelOf(g, record, station, domain)` (an `Option`), `sameStation(a, b)` | Enumerate and look up the relations: the records of a source station (X) or gathers of a receiver station (O), the channel of a station in a record. Index 0 matches any. |
| `relationRuns(g, record, domain = rdSource)` (iterator of `RelationRun`), `station(run, i)`, `relationsDisjoint(g, record, domain)` | The relation runs of a record, in file order: one X or O record of the survey file each, as a `RelationRun` (`fromChannel`, `toChannel`, `channelStep`, `stations`, `components`; `fixed`: the source of an X record, the receiver of an O gather; `line`, `firstPoint`, `lastPoint`, `pointStep`, `index` of its evenly spaced stations). `station(run, i)` is station `i` exactly as `relations` gives it; its first channel is `fromChannel + i * channelStep`. For walking a record station by station along each line (fold, patch description, completeness) without the per-channel lookups. `relationsDisjoint` says whether the record's runs ascend by channel without sharing one: then the runs give every channel once, and `relation` is a binary search; else use `relations` where a shared channel matters. |
| `receiverRelations(g, firstGather = 1, recordType = 'O')` → `seq[SpsRelation]` | The O records of the X relations: one gather per receiver station (receiver line, point order), its sources by line and point as runs, repeats after; write with `writeSps`. One receiver line in memory at a time. |
| `joinStations(keys, g)` → `JoinMatch`; `applySurvey(f, keys or index, g[, stats], overwrite = false)` | Fill the stations a header lacks, matched **by station**: both in the header (`jmStations`); source only → the X records of that source (`jmSource`); receiver only → the O gathers of that receiver (`jmReceiver`); no station → record and channel (`jmRecord`); also `jmAmbiguous`, `jmConflict`, `jmUnmatched`, `jmAuxiliary` (left alone). Header stations are never replaced; a relation must agree with the stations the header has, and with the line or point it has of a station it lacks otherwise (to 1/100, or as a whole number: header point 100 agrees with 99.5; else `jmConflict`, nothing filled). `applySurvey` then fills coordinates by station, offset, midpoint (`overwrite`: replace known coordinates); in memory only. It returns the traces whose keys changed: a trace that already holds the survey's values is not one, and a join that changes none leaves `keysRevision` and `TraceIndex.joined` alone. `JoinStats` (`traces`, `changed`, `matches`, `noSourceXy`, `noReceiverXy`; `$`). |
| `geometryChanges(f, fields[, log])` | What writing the joined keys of `f` (opened with keys, `applySurvey` done) would change, as `GeometryChanges` (traces per kind whose headers would hold another value afterwards, `unwritable` values; `$` gives a one-line summary), with the reports in `log` (no slot, does not fit, rounded in every field of the value); nothing is written. |
| `writeGeometry(editor, fields = GeometryFields())`, `writeGeometry(editor, f.index, fields)` | Writes the joined geometry in place through the journaled `HeaderEditor`: from the editor's own index (an editor made with `openEditor(f)` from the joined file; `ValueError` without keys), or from the index of the same file opened separately. Same-size fields; undo with `rollbackJournal`. SEG-Y: through the layout (`sht_x`, `rec_x`, `cdp_x` with a coordinate scalar chosen to keep the precision in 4 bytes; `selev`/`relev`; `offset`; `espnum`/`sp`; Ext1 copies in use; `sht_line`, `rec_point`, ... where a Layout stanza defines them). SEG-D Rev 1/2: THE#1 receiver line/point/index. Rev 3: THE#1 and the Position / Source Description blocks already in the trace header extensions. Values with no slot or too large for theirs are reported in `editor.log`. `GeometryFields` selects source/receiver X/Y, elevations, midpoints, offsets, stations. SEG-2 is refused for now. |
| `copyWithGeometry(src, dst, g, fields, overwrite)`, `convertWithGeometry(src, dst, g, opts, fields, overwrite)` | A copy in the same standard (multiplexed SEG-D demultiplexed), or a `convertFile` SEG-Y output, with `g` joined and written. `copyWithGeometry` returns a `GeometryCopy` (`changes`, `log`), `convertWithGeometry` a `DiagLog`; both logs carry an info summary. |
| `GeometryTable`, `addSource`/`addReceiver`, `applyGeometry` | The coordinate table alone (a host's database). Keys are rounded to 1/100; a trace without a point index also matches index 1. |

CLI: `parseSEG survey-apply <file> --sps=... [-o out | --in-place]`.

## Writing results like the input
| Proc | What |
|---|---|
| `openSeismicWriter(path, like: SeismicFile, segyFormat = stKeep, segdFormat = tfKeep, seg2Format = s2tKeep): SeismicWriter` (`model/writefile`) | A writer in `like`'s standard, revision and byte order, with its file headers (SEG-Y label, textual, binary, extended text and trailer; SEG-D storage unit label; SEG-2 File Descriptor Block). A format other than "keep" (for `like`'s standard only) changes the format code. `ValueError` for an unknown or multiplexed `like`, a format for another standard or one the revision lacks, SEG-D 8015 for traces whose sample count is not a multiple of 4, `path` = `like`'s file; `SegFormatError` for headers the writer refuses; `IOError` when the output cannot be created. |
| `w.writeTrace(src, trace, samples: openArray[T], overrides = [])`, `w.writeTrace(src, trace, x: Tensor[T], row, count = -1, overrides = [])` | Trace `trace` of `src` (open, the same standard; usually `like`) with its headers and the samples encoded in the output format (the tensor form: the row's first `count` values, -1 = the trace's own count). SEG-Y and SEG-2 traces may change sample count (trace header; the SEG-Y binary header when all agree; fixed-length files need one count) and come in any order. SEG-D: a trace keeps its count; records are written whole, each one's traces in input order, and a record ends when another record's trace arrives or at `close` (`ValueError` when incomplete). `ValueError` for caller errors (nothing is written), `SegFormatError` for a value the format cannot hold (out of range, or NaN or an infinity outside the IEEE formats; nothing is clamped), `IOError` on a write failure, which discards the output and closes the writer. `overrides` (`HeaderOverride`: `name`, `value`; made with `headerOverride(name, value)`) change header fields of the written trace, so trace `trace` serves as a template: `trace.<field>` / `ext1.<field>` as the editor names them, values as stored (SEG-2: `trace.<KEYWORD>` strings). Structural fields, unknown names, values that do not fit and missing blocks raise `ValueError`, before anything is written. |
| `openSeismicWriter(path, opts: SegyOutputOptions): SeismicWriter`; `SegyOutputOptions` (`revision` = 2.1, `byteOrder` = `boBig`, `format` = `st5`, `textEncoding`, `text` (cards 1-38), `traceSorting`, `measurementSystem`) | A new SEG-Y file not modelled on an input, for traces from keys. The first trace sets the binary header's interval; its count is the largest written; Rev 2 traces carry Trace Header Extension 1. `ValueError` for a revision other than 0, 1, 2.0, 2.1, a format the revision lacks, a 3-byte format pair-swapped, a byte order other than big-endian before Rev 2, more than 38 text lines; `IOError` when the output cannot be created. |
| `w.writeTrace(keys: TraceKeys, samples: openArray[T], overrides = [])` | A SEG-Y trace whose headers come from `keys` in the standard layout (record, channel, ensemble, offset, source point, coordinates, elevations, midpoint, `t0Ms` with a time scalar, `intervalUs`, `time` in UTC, Rev 1+: inline and crossline; Rev 2 also the f64 Ext1 values), then `overrides`; `openSeismic` reads back the same keys (NaN keys as 0 or NaN, see the doc comment; trace code from `traceCode` when it agrees with the status, else the status). For a SEG-Y output (`SegyOutputOptions`, or `like` a SEG-Y file). An interval within 1e-9 of a whole number is that number. Rev 0 has no field for the midpoint, inline and crossline and holds `t0Ms` as a whole ms. `ValueError` for another standard, keys without a positive interval, a fractional interval or one over 65535 µs before Rev 2, a `t0Ms` beyond ±32767 ms in Rev 0, more than 65535 samples without Ext1, a bad override (nothing is written). |
| `w.close(): DiagLog`, `w.len`, `w.path` | Finishes (ends the SEG-D record, SEG-Y trailer and final counts: the samples per trace of the traces written, the largest when they differ, and the Rev 2 trace count when declared; SEG-2 pointers) and renames the temporary output into place. The log holds warnings only: every failure raises and discards the output (`ValueError` for an incomplete SEG-D record, `SegFormatError`, `IOError` for a full disk or an output that cannot be moved into place). A writer dropped without `close`, or whose `writeTrace` raised `IOError`, leaves no output file. Not copyable. |

## In-place edits
`openEditor(path, journalPath)` and `setTraceField(trace, "trace.<f>", v)` /
`setFileField("binary.<f>", v)` / `setRecordField(record, "gh1.<f>", v)` (each `false` when
refused, with the reason in `log`; never raises; `log` holds the first 1000 refusals of a
session and `close` adds how many more there were), then `close`. `v` is a `FieldValue` or a
plain number or string. Field names are as above. Edits are size-preserving and validated,
and each is journaled, and synced to disk, before it is written: an edit whose journal
entry cannot be synced is refused, and its entry is cut from the journal again (when that
fails too, the editor refuses every further edit). `beginBatch` / `endBatch` (false when the
batch's journal sync fails) share one sync among many edits; `close` raises `IOError` when
the final batch cannot be journaled. `currentTraceField` (...) read fields as edited so far
(a batch's pending edits included, without a sync; also `currentFileField`,
`currentRecordField`; they only read, so they take the editor by value). In a batch a
record edit waits like a trace edit: one sync for the batch, and the index's copies of the
record headers and the keys of the records' traces are refreshed once, at `endBatch`
(`setFileField` writes the batch so far). Several fields of one header can be
edited in one batch without a flush. `openEditor`
raises `ValueError` when the journal is the file itself.
`openEditor(f: sink SeismicFile, journalPath = "")` takes over an open file: maps it
read-write and keeps its index (keys joined by `applySurvey` included), no second walk;
`ValueError` for a closed file, a demultiplexed copy, or a file whose size changed since it
was opened. `release(ed): SeismicFile` ends the session (as `close`) and returns the file,
still mapped and as edited.
`rollbackJournal(path, journal)` / `applyJournal(path, journal)` undo or redo them;
`readJournal(journal)` lists its edits (`JournalEdit`, oldest first).
`rollbackJournal(ed)` / `applyJournal(ed)` do the same on the editor's open file and re-read
the index's copies of the headers (SEG-Y binary, SEG-D GH#1 and source headers).
Stored keys follow the edits (Phase 16): each trace, record or keyed binary field edit
(`binary.sampleInterval`, `extSampleInterval`, `timeBasisCode`) refreshes the affected
traces' keys once its bytes reach the map (a batch: at `endBatch`), and `keysRevision` goes
up once when any changed. Values a join wrote (`TraceIndex.joinedTraces`) win, group by group
(`JoinGroup`): a trace whose source coordinates came from `applySurvey` keeps them when its
header coordinates are edited, while its other keys, the receiver coordinates of a join that
filled the source only included, follow the headers. The offset and midpoint a join derived
are derived again when an end it left to the headers moves.

Header documents (`model/headernif`): `exportHeaders(f, path, raw = true, progress = nil)` streams every named
field (and raw bytes) as NIF; `importHeaders(path, nifPath, ImportOptions(outPath, journal,
dryRun, force, onChange)): ImportResult` (`applied`, `refused`, `log`) applies an edited document as a patch through the editor, in
place or into a copy (`dryRun` only lists the changes). A viewer saves its pending edits with
`writeHeaderPatch(changes: openArray[HeaderChange], path)`, each change made with
`initHeaderChange(scope, index, "<block>.<field>", value)` (which checks the name), in
the same format; applying it stays an explicit `importHeaders`. Only the blocks the editor
names (`trace`, `ext1`, `gh1`, Rev 1/2 `gh3..`, `binary`) can be patched. `onChange` reports each accepted
edit; edits a later failed journal sync drops are moved from `applied` to `refused`, with a
fatal diagnostic.

## Streaming readers and writers (disk and tape)
- SEG-Y: `openSegy(src)` / `readTrace`, `readSegy(path)`, `openSegyWriter(sink, file, opts)` /
  `writeTrace` / `close`, `initSegyWriteOptions(file, lenient)`. `file.format` is an
  `Option[SampleFormat]` (none for an undefined format code). Named trace values go through
  the file's Layout: `fieldValue(file, trace, "iline")` returns an `Option[float64]`,
  `initGeometryReader(file).geometry(trace)` the common ones; `layoutOf(file).entriesFor(name)`
  lists the entries.
- SEG-D: `openSegd(src)` / `nextRecord` / `readTrace`, `readSegd(path)`,
  `openSegdWriter(sink, opts, label)`, `writeSegd(sink, data)`. A `SegdRecord`, its
  `SegdScanType`s and `SegdTrace`s are variant objects on `layout`: `slRev2` (Rev 0, 1, 2.x:
  `gh2` (an `Option`, none for Rev 0), `sourceHeaders`, `descriptors`, `ext1`, `trailer`) or
  `slRev3` (`gh2Rev3`, `gh3`, `generalBlocks`, `descriptorsRev3`, `ext1Rev3`,
  `trailerRev3`). `format`, the label and `ext1`/`ext1Rev3` are `Option`s. Accessors resolve a
  value for either layout: `fileNumber`, `channelSetsPerScanType`, `baseScanIntervalUs`,
  `headerBytes`, `findChannelSet` (an `Option[SegdChannelSetRef]`), and per channel set
  `channelType`, `sampleIntervalUs`, `startTimeMs`, `descaleFactor`, each as
  `(rec, trace)` and as `(rec, scanType, channelSet)`: the second form serves code that
  holds an index entry and no `SegdTrace` (`f.index.segdRecords[e.record]`,
  `int(e.scanType)`, `e.channelSetIndex`). The reader's `record`, `label`, `log` and `toc`
  are read-only.
- SEG-2 (random access, so the reader works on the whole file as an `openArray[byte]`,
  normally the map): `readSeg2(bytes, log, name): Seg2File` (File Descriptor Block: `order`,
  `revision`, `stringTerm`, `lineTerm`, `pointers`, `strings`), `traces(bytes, file, log)` /
  `readSeg2Trace(bytes, file, i, log): Seg2Trace` (`valid`, `blockSize`, `dataSize`,
  `numSamples`, `formatCode`, `strings`, `sampleCount`), `readSamples(bytes, file, trace,
  dst)`, `decodeSamples` (formats 1-5 as `Seg2SampleFormat`). Strings are kept verbatim as
  `Seg2String(key, value)`; lookups are case-insensitive: `value`, `contains`, `number`,
  `numbers`, `integer`, `noteLines`, and typed getters `sampleInterval`, `delay`,
  `channelNumber`, `receiverLocation`/`sourceLocation` (`Seg2Location`), `traceType`,
  `traceSort`, `units`, `acquisitionTime` (UTC seconds), all `Option`s; `h[key] = value`
  sets one, `sortStrings` orders a list (keyword, NOTE last), `formatNumber` spells a number
  the SEG-2 way. `blockStrings(bytes, first, limit, file[, spans])` parses a string list
  (with each entry's byte span), `fileBlockSize` gives the File Descriptor Block's length.
  - Writer (`seg2/writer`): `openSeg2Writer(path, initSeg2File(order), opts)` (set
    `traceCount` first: it sizes the pointer subblock), `writeTrace(t, rawData)` or
    `writeTrace(t, samples)` (encoded in `t.formatCode`; `encodeSamples`), `close()`
    (writes N and the pointers; `IOError` when the last bytes did not reach the file) or
    `abandon()` (closes it as it is, for output being discarded). A file this writer wrote, read and written back, is
    byte-identical (other writers' files may differ in padding and pointer layout); output the
    standard forbids raises `SegFormatError` unless `Seg2WriteOptions(lenient: true)`.
  - Named fields: `trace.<fixed field>` / `file.<fixed field>` (`Seg2TraceFixed`,
    `Seg2FileFixed`: `numSamples`, `formatCode`, `revision`, ...) and `trace.<KEYWORD>` /
    `file.<KEYWORD>` (the string's value as text) through `traceField`/`fileField`;
    `f.seg2Strings(trace)` (trace -1: the file; each `Seg2String` has `key` and
    `value`). Listings give a row per fixed field and per string; `exportHeaders`
    writes `(s "KEYWORD" "value")` entries. Edits are refused (strings are variable
    length: rewrite the file). Vendor maps do not apply to SEG-2.
- Multiplexed SEG-D (Rev 0/1 formats 0015, 0022, 0024, 0036, 0038, 0042, 0044, 0048, 0058):
  the reader walks each record's scans and gives demultiplexed traces in the twin format
  (8015 for 0015, ...); the record says `multiplexed`. `demultiplexSegd(src, dst)` writes a
  demultiplexed copy. `segd/mux` has the scan codecs (`muxLayout`, `isStartOfScan`,
  `scanHeader`, `demuxChannel`, `decodeMux0015`).
- Vendor maps: `loadVendorMaps`, `registerVendorDecoder`, `decode` (an
  `Option[VendorBlock]`; `blk["field"]` reads a value), `applies`, `vendorContext(rec or
  file)`, `decodeVendorAreas`; `scaffoldVendorMap(path, reg)` / `toNif` write a skeleton map
  for every area no map decodes.
- Media: `openDiskSource`/`openDiskSink`, `openMemFileSource`,
  `openTapeImageSource`/`openTapeImageSink`, `newDeviceSource`/`newDeviceSink` over a
  `TapeDevice` (Linux `st`, Windows tape, `MemoryTape`). A custom drive overrides
  `readBlock(buf, n): RecordKind` (the block length goes to `n`), `writeBlock`,
  `writeTapeMarks`, `rewind`, `spaceFiles`, `status` and `close`. Sources and sinks count
  through the read-only `recordIndex` and `fileIndex`.

## Conversion
- `convertFile(src, dst, ConvertOptions(...), progress = nil)` detects the input (SEG-Y, SEG-D or SEG-2)
  and writes the standard `target` names (`skSegy`, the default; `skSegd` with the
  `segd: SegdConvertOptions` for SEG-D or SEG-2 input; `skSeg2` with `seg2:
  Seg2ConvertOptions(byteOrder = boLittle, format = s2tKeep)` for any input). SEG-2 → SEG-Y
  is `convertSeg2ToSegy(file, sink, opts)`; to SEG-2 `convertToSeg2(src, dst, opts)`; SEG-2
  → SEG-D `convertSeg2ToSegd(src, dst, segdOpts)` (one Rev 3 record; Rev 2 through
  `convertSegdRevision`). The keyword mappings, and what has no slot (reported once per
  kind), are in `convert/tosegy.nim`, `convert/tosegd.nim` and `convert/toseg2.nim`.
  `ConvertOptions.format` is a `SegyTargetFormat`: `stKeep` (the default: keep a SEG-Y
  input's format, or choose a lossless one for SEG-D) or `st1` .. `st16` (a format code;
  `targetFormat(sfFloat32)` gives `st5`). Each value's ordinal is its format code
  (`ord(st15) == 15`; 13 and 14 are refused).
- `convertSegy(src, sink, opts)` converts SEG-Y to SEG-Y: a new revision (0, 1, 2.0, 2.1),
  byte order or sample format. It drops what the target cannot hold and reports each kind of
  loss once. A new revision rewrites the header bytes whose meaning it changes: bytes the
  input's revision leaves unassigned are cleared on the way up, the time scalar is applied
  on the way to Rev 0, and a Rev 2 extended count or interval moves to the 16-bit fields
  (a trace they cannot hold is skipped with an error; see `convert/tosegy.nim`).
- `convertSegdToSegy(src, sink, opts)` converts SEG-D Rev 1/2/3 to SEG-Y, using a documented
  field mapping (see `convert.nim`):
  - the trace's `TraceKeys` are written as `writeTrace(w, keys, samples)` writes them, so
    they read back from the output (a fractional source point, a start time with its time
    scalar, the time's nanoseconds in Rev 2);
  - samples are exact by default, through a lossless format choice;
  - `applyDescale` writes millivolts instead of recorded values;
  - Rev 2 targets carry float64 coordinates, offsets and midpoints in Trace Header
    Extension 1, and line/point in a `PSEGD001` header described by a Layout stanza.

- `convertSegdRevision(src, dst, SegdConvertOptions(revision, format))` converts SEG-D
  between revisions (Rev 1/2 → 3.0, Rev 3 → 2.0/2.1, within a layout), streaming, with
  samples copied byte for byte; the mapping and what is dropped are in `convert/tosegd.nim`.
  `format` is a `SegdTargetFormat` (`tfKeep`, or `tf8058` ...; `targetFormat(sd8058)`);
  its ordinals are not format codes.
  The stream form takes `scanSegdRecords` (a headers-only pass) for exact sample counts.

## Diagnostics
`DiagLog` (`len`, `[]`, `items`, `pairs`, `add`, `report`, `count(severity)`, `hasErrors`, `isFatal`, `toNif`, `writeNif`), `Diagnostic`,
`Severity`, `DiagCode`, `Location`, and `readDiagnostics` / `parseDiagnostics` for NIF round
trips. `recordException(log, loc, e, fatal = false)` turns a caught exception into a
diagnostic, and `tryRecord(log, loc): body` runs `body` and records what it raises (false
then). `tryRecordFatal(log, loc): body` is the same where a failure ends the read: the entry
is `fatal` whatever was raised, which is how every reader that stops early has `isFatal`.

Exceptions: `SegError` (base) → `SegFormatError` → `SegTruncatedError` (data ran out) and
`SegUnlocatableError` (the rest of the data cannot be located; readers stop);
`SegCancelledError` (a `Progress` hook cancelled; not a `SegError`). `raiseFormat`,
`raiseTruncated`, `raiseUnlocatable` and `raiseCancelled` raise them with a byte offset, for
custom decoders and sources.

## Supporting types and lower-level names
The rest of what `import parseSEG` exports, grouped by module. Most are the types of the
fields and results above, or building blocks for code that works on raw headers.

| Area | Names |
|---|---|
| Index (`model/traceindex`, `model/indexwalk`, `model/keys` with `model/keytypes`, `model/summary`) | `TraceCodec` (how one file, record or SEG-2 format encodes samples), `NoChannelSet`; per entry `channelSetIndex`, `sampleOffset`, `dataBytes`, `known` (decodable), `prefersFloat64`; `StationKey` / `stationKey` (a station's table key, rounded to 1/100), `Coordinates`, `initTraceKeys`, `deriveGeometry` (offset and midpoint from the coordinates), `hasSourceXY`, `hasReceiverXY`, `hash`; `StandardRevision` |
| Header fields (`model/headerfields`) | `FieldValueKind`, `HeaderScope`, `BlockRef` (where a header block lies), `toFieldValue`, `toFloat` |
| Byte order (`common/endians`) | `ByteOrder`, `hostOrder`, `ByteBuf` / `byteBuf`, `swapBytes`; big-endian readers `beU8` .. `beU64`, `beI8` .. `beI64`, `beU24`, `beI24`, `beF32`, `beF64` and writers `putBeU8` .. `putBeF64`; either order: `getNum`, `putNum`, `loadNum`, `loadU24` (unchecked) |
| Field layouts (`common/fieldlayout`) | `FieldSpec`, `FieldKind`, `fieldTable(T)` (a header type's layout), `BcdInvalid`, `BcdAllF` |
| SEG-Y headers (`segy/binheader`, `segy/traceheader`, `segy/textheader`) | `SegyBinaryHeader`, `SegyRevision`, `BinaryHeaderSize`, `binaryHeaderFields`, `decodeBinaryHeader`, `encode`, `validate`, `rulesRevision`, `bytesPerSample`, `detectByteOrder` (`ByteOrderDetection`), `looksLikeBinaryHeader`, `ByteOrderMarker`, `effectiveSampleInterval`, `effectiveSamplesPerTrace` (and `...Orig`), `usableExtInterval` (when a Rev 2 extended interval overrides its 16-bit field: non-zero and not NaN), `effectiveEnsembleFold`, `effectiveDataTracesPerEnsemble`, `effectiveAuxTracesPerEnsemble`; `SegyTraceHeader`, `SegyTraceHeaderExt1`, `TraceHeaderSize`, `traceHeaderFields`, `traceHeaderExt1Fields`, `decodeTraceHeader`, `decodeTraceHeaderExt1`, `initTraceHeaderExt1`, `applyScalar`, `scaleCoordinate`, `scaleElevation`, `scaleTime`, `shotpoint`, `headerBlockName`, `headerNameText`, `LastInEnsemble`, `LastInLine`, `LastInFile`, `LastInSurvey`; `SegyTextHeader`, `TextEncoding`, `TextHeaderSize`, `CardCount`, `CardWidth`, `CardNumber`, `initTextHeader`, `card`, `setCard`, `cardPrefix`, `decodeTextHeader`, `detectTextEncoding`, `decodeText`, `encodeText`, `looksLikeText` |
| SEG-Y extended text (`segy/exttext`) | `ExtendedTextHeader` (`initExtendedTextHeader`, `add`, `finish`, `find`, `isComplete`, `needsMore`, `hasEndText`, `inBinaryStanza`, `continuesUserData`), `Stanza` (`stanzaText`, `stanzaBytes`, `isBinary`, `isEndText`, `isUserData`), `ExtTextIssue`, `UserDataBlock` (`userDataBytes`, `isRetained`), `UserDataItem`; writing: `addText`, `addStanza`, `addUserData`, `addEndText`, `toDescXml`; `startsStanza`, `startsStanzaRecord`, `normalizeStanzaName` |
| SEG-Y layout and streaming (`segy/layout`, `segy/fields`, `segy/reader`, `segy/writer`, `segy/samples`) | `TraceLayout`, `LayoutEntry`, `LayoutType`, `standardLayout`, `parseLayout`, `merge`, `normalizeEntryName`; `GeometryReader`, `TraceGeometry`, `timeBasis`; `SegyFile`, `SegyReader`, `SegyTrace`, `SegyData`, `decodeInto`, `isDone`, `tracesRead`, `extractUserData`, `binaryAsRead`, `isBinaryAsRead`, `isExtendedAsRead`, `isTrailerAsRead`, `TapeLabelSize`, `DefaultMaxRetained`, `MaxLayoutBytes`; `SegyWriter`, `SegyWriteOptions`, `tracesWritten`; `SampleType`, `sampleSize`, `toSampleFormat`, `isRev2Format`, `definedSampleFormats`, `decodeSamples`, `encodeSamples`, `prefersFloat64` |
| SEG-D headers (`segd/headers`, `segd/blocks`) | `SegdStorageUnitLabel` (`decodeLabel`, `isStorageUnitLabel`), `SegdGeneralHeader1`, `SegdGeneralHeader2`, `SegdGeneralHeaderN`, `SegdChannelSetDescriptor`, `SegdTraceHeader`, `SegdTraceHeaderExt1`, `SegdTrailerBlock`, `SegdHeaderBlock`, `SegdBlock`, their `segd...Fields` tables, `SegdBlockSize`, `SegdTraceHeaderSize`; `decodeBlock`, `encode`, `invalidBcdFields`, `asciiText`; accessors `generalHeaderCount`, `extendedHeaderBlocks`, `externalHeaderBlocks`, `skewBlocks`, `baseScanIntervalMs`, `recordLengthMs`, `sampleIntervalMs`, `channelSetNumber`, `endTimeMs`, `mpFactor`, `receiverLine`, `receiverPoint`, `isFixedRecord`, `bytesPerScan`, `scansPerBlock` |
| SEG-D Rev 3 (`segd/rev3`) | `SegdGeneralHeader2Rev3`, `SegdGeneralHeader3`, `SegdChannelSetDescriptorRev3`, `SegdTraceHeaderExt1Rev3`, `SegdPositionBlock`, `SegdSourceDescription` (`vibratorType`, `phaseControl`, `phaseAngle`), `SegdAdditionalSourceInfo`, `SegdSensorInfo`, `SegdSensorCalibration`, `SegdTimeDrift`, `SegdTimestampHeader`, `SegdOrientation`, `SegdTrailerDescription`, `SegdRev3Block`, their `segd...Fields` tables, `BlockType...` constants, `blockTypeName`, `isDefinedBlock`, `isUserBlock`, `findBlock`, `blockText`, `descriptionText`, `traceNumber`, `traceBytes`, `recordLengthUs`, `crsFormat`; time: `timestampToUnix`, `unixToTimestamp`, `gpsMinusUtc`, `generalHeaderUtc(g1)` (GH#1's date and time as UTC seconds; the two-digit year is 1950-2049, or in the `century` given as a second argument), `GpsEpochUnix`; tables of contents: `SegdToc`, `SegdTocEntry`, `decodeToc`, `isTocFile`, `tocEntryCount`, `TocIdentifier`, `TocHeaderSize`, `TocEntrySize` |
| SEG-D streaming (`segd/reader`, `segd/writer`, `segd/samples`, `convert/tosegd`) | `SegdReader`, `SegdData`, `SegdRecordData`, `SegdLayout`, `SegdRevision`, `isRev3`, `isDone`, `decodeInto`, `announcedTraces`, `channelSetCount`, `DefaultMaxHeaderBytes`, `DefaultMaxTraceBytes`, `UnknownTrailerBlocks`; `SegdWriter`, `SegdWriteOptions`, `writeRecordHeaders`, `endRecord`, `setRev3Trailer`, `computeRev3Sizes`, `MaxFixedBlock`; `SegdSampleFormat`, `SegdSampleType`, `segdSampleFormats`, `toSegdFormat`, `decodeSamples`, `encodeSamples`, `dataBytes`, `isLittleEndian`, `bigEndianOf`, `prefersFloat64`; `SegdRecordScan` |
| Multiplexed SEG-D (`segd/mux`, `segd/demux`) | `MuxScanLayout`, `MuxChannelSet`, `ScanHeader`, `ScanHeaderSize`, `timingMs`, `isMultiplexedCode`, `demuxFormat`, `muxBytes`, `muxTraceHeader`, `demultiplexedRecord` |
| SEG-2 (`seg2/headers`, `seg2/reader`, `seg2/samples`, `seg2/writer`, `convert/toseg2`) | `Seg2Header`, `Seg2TraceType`, `Seg2TraceSort`, `Seg2Units`, `Seg2FixedSize`, `Seg2FileBlockId`, `Seg2TraceBlockId`, `Seg2MaxTraces`, `isSeg2`, `seg2Order`, `toSeg2String`, `find`; `dataOffset`, `stringListEnd`; `Seg2SampleType`, `toSeg2Format`, `samplesIn`, `dataBytes`, `prefersFloat64`; `Seg2Writer`; `Seg2TargetFormat` |
| Survey files (`survey/sps`, `survey/p1`, `survey/textrec`) | `SpsRevision`, `SpsHeader`, `SpsPoint` (`initSpsPoint`), `SpsPointKind`, `SpsRelation` (`initSpsRelation`), `SpsEntry`, `SpsEntryKind`, `looksLikeSps`; `P1Record` (`initP1Record`), `PLogicalFile`, `PFormat`, `AngleUnit`; `TextRecord`, `TextLayout`, `detectLayout`, `openLayout`, `textRecords`, `CardWidth`, `MaxLineBytes` |
| Vendor maps (`vendor/maps`, `vendor/scaffold`) | `VendorRegistry` (`addMap`), `VendorMap`, `loadVendorMap`, `checkVendorMap`, `vendorSearchPath`, `VendorContext`, `VendorArea`, `VendorDecoder`, `decodeTarget`, `VendorField`, `VendorValue`, `VendorValueKind`, `toFloat`; the compiled map: `VendorMatch`, `VendorRevision`, `VendorRevisionRange`, `VendorTarget`, `VendorTargetKind`, `VendorFieldPlan`, `VendorRepeatPlan`, `VendorEncoding`, `VendorTrim`, `VendorEnumLabel`, `VendorBitFlag`; `VendorScaffold` |
| Records and media (`io/records`, `io/diskio`, `io/memsource`, `io/tapeimage`, `io/tapedevice`, `io/tape_linux`) | `RecordSink`, `RecordCursor` (`initRecordCursor`, `readExactly`, `skip`, `skipTapeMark`, `stoppedAt`, `remainingInRecord`, `atRecordStart`, `readRecordRest`, `preferSmallReads`), `readRecord`, `writeRecord`, `writeTapeMark`, `DefaultChunkSize`; a custom source or sink overrides the methods `readRecordImpl`, `seekForward`, `hasRecordBoundaries`, `writeRecordImpl`, `writeTapeMarkImpl`; `DiskSource`, `DiskSink` (collects records and writes them in `SinkBufferSize` pieces: the file is complete after `close`, which raises `IOError` when bytes did not reach it), `DefaultMapChunk`, `TapeImageSource`, `TapeImageSink`, `DeviceSource`, `DeviceSink`, `DefaultMaxBlockSize`, `TapeStatus`, `newMemoryTape` (`TapeItem`, `TapeItemKind`, `dataBlock`, `tapeMark`; a `MemoryTape` has `len`, `[]` and `items`), `LinuxTape` / `openLinuxTape` (Linux) |
