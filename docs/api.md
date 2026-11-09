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
| `openSeismic(path, keys = false, progress: Progress = nil, opts = OpenOptions()): SeismicFile`; `OpenOptions` (`verify = vfSampled`, `cache`, `demuxDir`, `twosComplement8015`) | Memory-maps the file, detects SEG-Y, SEG-D or SEG-2, and builds the trace index (`index`, 24 B per trace). With `keys`, also collects per-trace geometry (`TraceKeys`, 144 B per trace). Multiplexed SEG-D (formats 0015 ... 0058) is demultiplexed once into a temporary copy in `opts.demuxDir` (default: the OS temp dir; `f.demuxPath`, a warning in `f.log`), which is indexed instead and deleted on `close`; `openEditor` refuses such a file (`ValueError`). `progress` reports the walk (below); `opts.cache` names an index cache (below). `opts.verify` (`VerifyMode`: `vfSampled`, `vfFull`): by default a fixed-length SEG-Y file (Rev 1+, binary bytes 3503-3504 = 1, no Rev 2 extension headers or trailers, a size of whole traces) is indexed from its size, with 64 trace headers (first, last, spread between) checked for the binary header's sample count and interval and an info `dcIndexSampled` saying how many; any disagreement falls back to the walk. The entries are the walk's; per-trace warnings of unsampled headers are not made. `vfFull`, and `keys`, always walk. |
| `Progress = proc (done, total: int64): bool {.closure, gcsafe, raises: [].}` | A progress and cancel hook: input bytes done and the input's size (-1 if unknown), about every MiB (`ProgressStep`) and once at the end (`done == total`); return false to cancel. Never per trace: a nil hook (the default) costs one comparison per trace. `openSeismic`, `buildIndex` and `exportHeaders` raise `SegCancelledError` when cancelled (the file is unmapped, no output is left); `convertFile`, `convertSegy`, `convertSegdToSegy`, `convertSeg2ToSegy`, `convertToSeg2`, `convertSeg2ToSegd`, `convertSegdRevision`, `copyWithGeometry` and `convertWithGeometry` take it as their last parameter and return a fatal `dcCancelled` with nothing written. Operations that read the input more than once (a header scan first, SEG-2 input, a copy then an index) spread their passes over one `0 .. total` run. The hook must be gcsafe: capture a parameter or a local `ref`, not a global. |
| `saveIndex(f, path)`, `f.fromCache` | Write `f`'s index as an index cache: entries, codecs, file and record headers, the walk's diagnostics and keys (if opened with them), about 24 B per trace (+ 144 with keys), a NIF header with the file's stamps and a checksum. `openSeismic(path, opts = OpenOptions(cache: cachePath))` reads it instead of walking the file when it was saved for the same path, size, modification time and first/last 64 KiB, with the same `twosComplement8015` (and keys, when asked for), by the same parseSEG version, and is intact (and, for `verify = vfFull`, not from a sampled open); otherwise it walks the file and logs why (`dcIndexCache`, info). `fromCache` says which. `saveIndex` raises `ValueError` for a closed or unrecognized file, a demultiplexed copy, keys changed by `applyGeometry`/`applySurvey`, a file changed since it was opened, or the file itself as `path`. |
| `detectKind(bytes): SeismicKind` | Detection only (`skUnknown` when nothing fits). |
| `buildIndex(src: RecordSource, kind, keys = false, progress = nil, verify = vfFull): TraceIndex` | The same index from any source: disk, tape image or tape device (`contiguous` is false for tape). Walks every trace unless `verify = vfSampled` (a fixed-length SEG-Y `MemFileSource`, as `openSeismic`). SEG-2 needs a `MemFileSource` (`ValueError` otherwise). |
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
| `readTracesInto(f, traces, var tensor, row = 0[, log]): int` | Decode a range or a selection into an existing tensor; returns the number of traces left zero (logged in `log`). |
| `readTraces(f, traces, samples: Slice[int][, log], T)`, `readTracesInto(f, traces, samples, var tensor, row = 0[, log]): int` | A **sample window** (`a..b`, 0-based) of a range or selection: `[traces, samples.len]`, and the tensor's width must be `samples.len`. Only the window's bytes are decoded (SEG-D 8015 and SEG-2 format 3, 4 samples in 10 bytes, also decode the rest of the group the window starts in); zero past a trace's end. `ValueError` for an empty window or one starting below 0. |
| `maxSamples(f, traces)` | Longest trace of a range or selection. |
| `newTraceTensor[T](traces, samples)` | A zero-filled `[traces, samples]` tensor to decode into (`T` is a `SampleType`: `float32` or `float64`). This and the next row are in `common/tensors`, which also re-exports Arraymancer's CPU tensor API (`arraymancer/tensor` without its CUDA/OpenCL backends). |
| `decodeTrace(t, row, format, src, samples, ...)`, `encodeTrace(t, row, format, dst, samples, ...)` | One row of a tensor from or to raw sample bytes, for a SEG-Y `SampleFormat`, a `SegdSampleFormat` or a `Seg2Format` (as `decodeSamples` & co). |
| `newPrefetcher[T](f, traces, chunkTraces, depth, cols, firstSample = 0, workers = 1, quickFirst = false, maxRingBytes = DefaultRingBytes)` (a range or a list) | Read-ahead on `workers` threads, chunks delivered in order whatever the count (rows hold samples `firstSample ..< firstSample + cols`). The ring holds at most `maxRingBytes` of chunks (`DefaultRingBytes`, 4 MiB, so a decoded chunk is still in cache when taken), but at least `workers + 1` and at most `depth`; `p.depth` is the depth used. `quickFirst`: the first chunk of the range and after each `seek` has `chunkTraces div 4` traces (at least 1), the rest follow at full size from there (`c.first`/`c.count` show the boundaries). `tryNext` (never blocks), `next`, `for c in p.chunks`, `nextInto` / `tryNextInto` (the caller gives up `c.samples`: swapped into the slot, so a steady consumer allocates nothing), `recycle(p, chunk or tensor)` (a buffer for a later chunk; reused only if of the chunk shape and unshared, at most `depth` kept), `seek(span)`, `atEnd`, `traceAt`, `len` (positions), `close`. A `Prefetcher` is not copyable; it keeps the file's map alive until its `close`. A `PrefetchChunk` has `first`, `count`, `samples`, `failed` and `log` (one error per trace left zero, with its trace index). |

Bad caller input (a trace, range or position out of range, a closed file) raises
`ValueError` everywhere.

Sorting is a selection: a sort produces a list of trace indices, and no data is moved
(PLAN.md, "Future").

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
| `fieldNames(HeaderBlock)`, `f.blockKind(scope, index, "ext1")`, `h.fieldByName("sourceX")` | The fields of a block kind; the kind of a file's block (`hsFile`, `hsRecord`, `hsTrace`); a field of a decoded header object (`Option`). |
| `f.traceHeaders(i)`, `f.recordHeaders(r)`, `f.fileHeaders` (`seq[HeaderRow]`) | A viewer's headers tab (task 6.10, `model/headerlist`): every header block of a trace, SEG-D record or the file as ordered rows of `blockName`, `kind` (`HeaderBlock`, `hbRaw` for blocks without named fields), `field`, `value`, `offset`, `size`, `blockOffset`, `blockSize` (raw bytes for a hex pane: `copyBytes(blockOffset, blockSize)`). It covers the blocks the trace or record has: SEG-Y `trace`/`ext1`/`ext2..`, SEG-D `trace`/`ext1`/`ext2..` (Rev 3 blocks typed by byte 32), `gh1`, `gh2`, ..., `st<s>cs<c>`, `extended`, `external`, `trailer`; SEG-Y `label`, `text`, `binary`, `extended`, `trailer`; SEG-2 `file` and `trace` (fixed fields, then one row per keyword string: `field` = keyword, `offset`/`size` = the string entry). Read-only; names as in `traceField` and the editor. |
| `readSegyHeaders(path)`, `readSegdHeaders(path)`; `openSegy`/`openSegd(src, headersOnly = true)` | Every header object, samples skipped (also on tape). |
| `traceKeys(...)`, `TraceKeys` | Per-trace geometry (record, source and receiver line/point/index/coordinates, component) and the trace's UTC time (`time`, POSIX seconds, NaN if unknown; task 6.9: SEG-Y bytes 157-168 with the time basis, SEG-D GH#1, Rev 3 GH#3 time zero or the trace's Timestamp block). |
| `f.traceKeys(traces): seq[TraceKeys]`, `f.traceKeysInto(traces, dst: var openArray[TraceKeys])` | Keys of a list or range of traces. Without `keys = true` they are made on demand from the mapped headers, the same as the index walk makes them (the file's own geometry: `applyGeometry`/`applySurvey` changes are only in stored keys); with it the stored keys are copied. |

## Gathers and components
`gathers(f or index)`: a split into `Gather` (`kind`, a `GatherKind`: shot, receiver, cmp, offset, other or
unknown; `traces`; `sources`; `receivers`), derived from the geometry, never assumed.
`classify(index, range)`. `componentGroups(f or index, traces)` returns a `ComponentGroup`
(station, traces, components) per station and source; see `isMultiComponent`.
`componentGroupIds(f, traces)` labels each trace with its group (-1 for none).
`isSeismic(index, trace)` is false for SEG-D auxiliary traces (channel types other than
seismic or EM) and SEG-2 `TEST_DATA` and `UPHOLE` traces.

## Survey files and external geometry (Phase 10)
SPS (Rev 1.0, 2.1) and SEG P1 (1983) give the coordinates that SEG-D 2.x headers lack, and SPS
X records name the stations each channel was recorded from. Spec notes: `docs/spec/sps.md`,
`docs/spec/p1_p2_p3.md`.

| Proc | What |
|---|---|
| `readSps(path or stream, SpsOptions)`, `parseSps(text)` → `SpsFile` | H, R/S (`points`, `kind` `pkReceiver`/`pkSource`), X (`relations`) and C records; revision from H00 or the columns. Every record keeps its raw text. Blank integers are `MissingInt`, blank reals NaN. |
| `writeSps(f, path or stream, SpsWriteOptions(revision, lineEnding, lenient))`, `spsText(f)` (a `SurveyText`: `text`, `log`), `encodeSps(record, rev)` | Column-exact; unchanged records byte for byte; 1.0 ↔ 2.1. A value that does not fit is an error and nothing is written (unless `lenient`). |
| `readP1(path or stream, P1Options(gridDecimals, depthDecimals, angleUnit))`, `parseP1` → `P1File` | Logical files (`files`), each with its header text and records; P1 decoded, P2-P4 kept raw. |
| `writeP1(f, path or stream, P1WriteOptions)`, `p1Text(f)` (a `SurveyText`), `encodeP1(record, opts)` | Header blocks padded to 20 records; unchanged records byte for byte. |
| `SurveyGeometry` (`initSurveyGeometry()`): `addSps(g, sps or path)`, `addP1(g, p1 or path[, P1Options], elevation)`, `addSource`/`addReceiver`, `relation(g, record, channel)` (an `Option[StationRelation]`), `resolveLine(g, name, numeric)` (an `Option`) | Station coordinates (`table`, `sourceCount`, `receiverCount`) and relation runs (`relationCount`). Text line names go through `mapLine(g, name, line)` (`lineNames`), then `trailingDigits`. `multiComponent`, `tape` refine X records; problems are in `log`. |
| `applySurvey(f, keys or index, g, overwrite = false)` | Stations from relations (on `TraceKeys.record` and `.channel`), then coordinates, offset, midpoint; in memory only, the file does not change. |
| `geometryChanges(f, fields[, log])` | What writing the joined keys of `f` (opened with keys, `applySurvey` done) would change, as `GeometryChanges` (traces per kind, `unwritable` values; `$` gives a one-line summary), with the reports in `log`; nothing is written. |
| `writeGeometry(editor, fields = GeometryFields())`, `writeGeometry(editor, f.index, fields)` | Writes the joined geometry in place through the journaled `HeaderEditor`: from the editor's own index (an editor made with `openEditor(f)` from the joined file; `ValueError` without keys), or from the index of the same file opened separately. Same-size fields; undo with `rollbackJournal`. SEG-Y: through the layout (`sht_x`, `rec_x`, `cdp_x` with a coordinate scalar chosen to keep the precision in 4 bytes; `selev`/`relev`; `offset`; `espnum`/`sp`; Ext1 copies in use; `sht_line`, `rec_point`, ... where a Layout stanza defines them). SEG-D Rev 1/2: THE#1 receiver line/point/index. Rev 3: THE#1 and the Position / Source Description blocks already in the trace header extensions. Values with no slot or too large for theirs are reported in `editor.log`. `GeometryFields` selects source/receiver X/Y, elevations, midpoints, offsets, stations. SEG-2 is refused for now. |
| `copyWithGeometry(src, dst, g, fields, overwrite)`, `convertWithGeometry(src, dst, g, opts, fields, overwrite)` | A copy in the same standard (multiplexed SEG-D demultiplexed), or a `convertFile` SEG-Y output, with `g` joined and written. `copyWithGeometry` returns a `GeometryCopy` (`changes`, `log`), `convertWithGeometry` a `DiagLog`; both logs carry an info summary. |
| `GeometryTable`, `addSource`/`addReceiver`, `applyGeometry` | The coordinate table alone (a host's database). Keys are rounded to 1/100; a trace without a point index also matches index 1. |

CLI: `parseSEG survey-apply <file> --sps=... [-o out | --in-place]`.

## Writing results like the input
| Proc | What |
|---|---|
| `openSeismicWriter(path, like: SeismicFile, segyFormat = stKeep, segdFormat = tfKeep, seg2Format = s2tKeep): SeismicWriter` (`model/writefile`) | A writer in `like`'s standard, revision and byte order, with its file headers (SEG-Y label, textual, binary, extended text and trailer; SEG-D storage unit label; SEG-2 File Descriptor Block). A format other than "keep" (for `like`'s standard only) changes the format code. `ValueError` for an unknown or multiplexed `like`, a format for another standard or one the revision lacks, `path` = `like`'s file; `SegFormatError` for headers the writer refuses; `IOError` when the output cannot be created. |
| `w.writeTrace(src, trace, samples: openArray[T])`, `w.writeTrace(src, trace, x: Tensor[T], row, samples = -1)` | Trace `trace` of `src` (open, the same standard; usually `like`) with its headers and the samples encoded in the output format (the tensor form: the row's first `samples` values, -1 = the trace's own count). SEG-Y and SEG-2 traces may change sample count (trace header; the SEG-Y binary header when all agree; fixed-length files need one count) and come in any order. SEG-D: a trace keeps its count; records are written whole, each one's traces in input order, and a record ends when another record's trace arrives or at `close` (`ValueError` when incomplete). `ValueError` for caller errors (nothing is written), `SegFormatError` for a value the format cannot hold. |
| `w.close(): DiagLog`, `w.len`, `w.path` | Finishes (ends the SEG-D record, SEG-Y trailer and final counts: samples per trace when uniform, the Rev 2 trace count when declared; SEG-2 pointers) and renames the temporary output into place; on a raise the output is discarded. A writer dropped without `close` leaves no output file. Not copyable. |

## In-place edits
`openEditor(path, journalPath)` and `setTraceField(trace, "trace.<f>", v)` /
`setFileField("binary.<f>", v)` / `setRecordField(record, "gh1.<f>", v)` (each `false` when
refused, with the reason in `log`; never raises), then `close`. `v` is a `FieldValue` or a
plain number or string. Field names are as above. Edits are size-preserving and validated,
and each is journaled, and synced to disk, before it is written: an edit whose journal
entry cannot be synced is refused, and its entry is cut from the journal again (when that
fails too, the editor refuses every further edit). `beginBatch` / `endBatch` (false when the
batch's journal sync fails) share one sync among many edits; `close` raises `IOError` when
the final batch cannot be journaled. `currentTraceField` (...) read fields as edited so far
(a batch's pending edits included, without a sync; also `currentFileField`,
`currentRecordField`). Several fields of one header can be
edited in one batch without a flush. `openEditor`
raises `ValueError` when the journal is the file itself.
`openEditor(f: sink SeismicFile, journalPath = "")` takes over an open file: maps it
read-write and keeps its index (keys joined by `applySurvey` included), no second walk;
`ValueError` for a closed file, a demultiplexed copy, or a file whose size changed since it
was opened. `release(ed): SeismicFile` ends the session (as `close`) and returns the file,
still mapped and as edited.
`rollbackJournal(path, journal)` / `applyJournal(path, journal)` undo or redo them;
`readJournal(journal)` lists its edits (`JournalEdit`, oldest first).

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
  `headerBytes`, `findChannelSet` (an `Option[SegdChannelSetRef]`), and per trace
  `channelType`, `sampleIntervalUs`, `startTimeMs`, `descaleFactor`. The reader's `record`,
  `label`, `log` and `toc` are read-only.
- SEG-2 (random access, so the reader works on the whole file as an `openArray[byte]`,
  normally the map): `readSeg2(bytes, log, name): Seg2File` (File Descriptor Block: `order`,
  `revision`, `stringTerm`, `lineTerm`, `pointers`, `strings`), `traces(bytes, file, log)` /
  `readSeg2Trace(bytes, file, i, log): Seg2Trace` (`valid`, `blockSize`, `dataSize`,
  `numSamples`, `formatCode`, `strings`, `sampleCount`), `readSamples(bytes, file, trace,
  dst)`, `decodeSeg2Samples` (formats 1-5 as `Seg2Format`). Strings are kept verbatim as
  `Seg2String(key, value)`; lookups are case-insensitive: `value`, `contains`, `number`,
  `numbers`, `integer`, `noteLines`, and typed getters `sampleInterval`, `delay`,
  `channelNumber`, `receiverLocation`/`sourceLocation` (`Seg2Location`), `traceType`,
  `traceSort`, `units`, `acquisitionTime` (UTC seconds), all `Option`s; `h[key] = value`
  sets one, `sortStrings` orders a list (keyword, NOTE last), `formatNumber` spells a number
  the SEG-2 way. `blockStrings(bytes, first, limit, file[, spans])` parses a string list
  (with each entry's byte span), `fileBlockSize` gives the File Descriptor Block's length.
  - Writer (`seg2/writer`): `openSeg2Writer(path, initSeg2File(order), opts)` (set
    `traceCount` first: it sizes the pointer subblock), `writeTrace(t, rawData)` or
    `writeTrace(t, samples)` (encoded in `t.formatCode`; `encodeSeg2Samples`), `close()`
    (writes N and the pointers). A file this writer wrote, read and written back, is
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
  loss once.
- `convertSegdToSegy(src, sink, opts)` converts SEG-D Rev 1/2/3 to SEG-Y, using a documented
  field mapping (see `convert.nim`):
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
trips. `recordException(log, loc, e)` turns a caught exception into a diagnostic, and
`tryRecord(log, loc): body` runs `body` and records what it raises (false then).

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
| SEG-Y headers (`segy/binheader`, `segy/traceheader`, `segy/textheader`) | `SegyBinaryHeader`, `SegyRevision`, `BinaryHeaderSize`, `binaryHeaderFields`, `decodeBinaryHeader`, `encode`, `validate`, `rulesRevision`, `bytesPerSample`, `detectByteOrder` (`ByteOrderDetection`), `ByteOrderMarker`, `effectiveSampleInterval`, `effectiveSamplesPerTrace` (and `...Orig`), `effectiveEnsembleFold`, `effectiveDataTracesPerEnsemble`, `effectiveAuxTracesPerEnsemble`; `SegyTraceHeader`, `SegyTraceHeaderExt1`, `TraceHeaderSize`, `traceHeaderFields`, `traceHeaderExt1Fields`, `decodeTraceHeader`, `decodeTraceHeaderExt1`, `initTraceHeaderExt1`, `applyScalar`, `scaleCoordinate`, `scaleElevation`, `scaleTime`, `shotpoint`, `headerBlockName`, `headerNameText`, `LastInEnsemble`, `LastInLine`, `LastInFile`, `LastInSurvey`; `SegyTextHeader`, `TextEncoding`, `TextHeaderSize`, `CardCount`, `CardWidth`, `CardNumber`, `initTextHeader`, `card`, `setCard`, `cardPrefix`, `decodeTextHeader`, `detectTextEncoding`, `decodeText`, `encodeText`, `looksLikeText` |
| SEG-Y extended text (`segy/exttext`) | `ExtendedTextHeader` (`initExtendedTextHeader`, `add`, `finish`, `find`, `isComplete`, `needsMore`, `hasEndText`, `inBinaryStanza`, `continuesUserData`), `Stanza` (`stanzaText`, `stanzaBytes`, `isBinary`, `isEndText`, `isUserData`), `ExtTextIssue`, `UserDataBlock` (`userDataBytes`, `isRetained`), `UserDataItem`; writing: `addText`, `addStanza`, `addUserData`, `addEndText`, `toDescXml`; `startsStanza`, `startsStanzaRecord`, `normalizeStanzaName` |
| SEG-Y layout and streaming (`segy/layout`, `segy/fields`, `segy/reader`, `segy/writer`, `segy/samples`) | `TraceLayout`, `LayoutEntry`, `LayoutType`, `standardLayout`, `parseLayout`, `merge`, `normalizeEntryName`; `GeometryReader`, `TraceGeometry`, `timeBasis`; `SegyFile`, `SegyReader`, `SegyTrace`, `SegyData`, `decodeInto`, `isDone`, `tracesRead`, `extractUserData`, `binaryAsRead`, `isBinaryAsRead`, `isExtendedAsRead`, `isTrailerAsRead`, `TapeLabelSize`, `DefaultMaxRetained`, `MaxLayoutBytes`; `SegyWriter`, `SegyWriteOptions`, `tracesWritten`; `SampleType`, `sampleSize`, `toSampleFormat`, `isRev2Format`, `definedSampleFormats`, `decodeSamples`, `encodeSamples`, `prefersFloat64` |
| SEG-D headers (`segd/headers`, `segd/blocks`) | `SegdStorageUnitLabel` (`decodeLabel`, `isStorageUnitLabel`), `SegdGeneralHeader1`, `SegdGeneralHeader2`, `SegdGeneralHeaderN`, `SegdChannelSetDescriptor`, `SegdTraceHeader`, `SegdTraceHeaderExt1`, `SegdTrailerBlock`, `SegdHeaderBlock`, `SegdBlock`, their `segd...Fields` tables, `SegdBlockSize`, `SegdTraceHeaderSize`; `decodeBlock`, `encode`, `invalidBcdFields`, `asciiText`; accessors `generalHeaderCount`, `extendedHeaderBlocks`, `externalHeaderBlocks`, `skewBlocks`, `baseScanIntervalMs`, `recordLengthMs`, `sampleIntervalMs`, `channelSetNumber`, `endTimeMs`, `mpFactor`, `receiverLine`, `receiverPoint`, `isFixedRecord`, `bytesPerScan`, `scansPerBlock` |
| SEG-D Rev 3 (`segd/rev3`) | `SegdGeneralHeader2Rev3`, `SegdGeneralHeader3`, `SegdChannelSetDescriptorRev3`, `SegdTraceHeaderExt1Rev3`, `SegdPositionBlock`, `SegdSourceDescription` (`vibratorType`, `phaseControl`, `phaseAngle`), `SegdAdditionalSourceInfo`, `SegdSensorInfo`, `SegdSensorCalibration`, `SegdTimeDrift`, `SegdTimestampHeader`, `SegdOrientation`, `SegdTrailerDescription`, `SegdRev3Block`, their `segd...Fields` tables, `BlockType...` constants, `blockTypeName`, `isDefinedBlock`, `isUserBlock`, `findBlock`, `blockText`, `descriptionText`, `traceNumber`, `traceBytes`, `recordLengthUs`, `crsFormat`; time: `timestampToUnix`, `unixToTimestamp`, `gpsMinusUtc`, `generalHeaderUtc`, `GpsEpochUnix`; tables of contents: `SegdToc`, `SegdTocEntry`, `decodeToc`, `isTocFile`, `tocEntryCount`, `TocIdentifier`, `TocHeaderSize`, `TocEntrySize` |
| SEG-D streaming (`segd/reader`, `segd/writer`, `segd/samples`, `convert/tosegd`) | `SegdReader`, `SegdData`, `SegdRecordData`, `SegdLayout`, `SegdRevision`, `isRev3`, `isDone`, `decodeInto`, `announcedTraces`, `channelSetCount`, `DefaultMaxHeaderBytes`, `DefaultMaxTraceBytes`, `UnknownTrailerBlocks`; `SegdWriter`, `SegdWriteOptions`, `writeRecordHeaders`, `endRecord`, `setRev3Trailer`, `computeRev3Sizes`, `MaxFixedBlock`; `SegdSampleFormat`, `SegdSampleType`, `segdSampleFormats`, `toSegdFormat`, `decodeSegdSamples`, `encodeSegdSamples`, `dataBytes`, `isLittleEndian`, `bigEndianOf`, `prefersFloat64`; `SegdRecordScan` |
| Multiplexed SEG-D (`segd/mux`, `segd/demux`) | `MuxScanLayout`, `MuxChannelSet`, `ScanHeader`, `ScanHeaderSize`, `timingMs`, `isMultiplexedCode`, `demuxFormat`, `muxBytes`, `muxTraceHeader`, `demultiplexedRecord` |
| SEG-2 (`seg2/headers`, `seg2/reader`, `seg2/samples`, `seg2/writer`, `convert/toseg2`) | `Seg2Header`, `Seg2TraceType`, `Seg2TraceSort`, `Seg2Units`, `Seg2FixedSize`, `Seg2FileBlockId`, `Seg2TraceBlockId`, `Seg2MaxTraces`, `isSeg2`, `seg2Order`, `toSeg2String`, `find`; `dataOffset`, `stringListEnd`; `Seg2SampleType`, `toSeg2Format`, `samplesIn`, `dataBytes`, `prefersFloat64`; `Seg2Writer`; `Seg2TargetFormat` |
| Survey files (`survey/sps`, `survey/p1`, `survey/textrec`) | `SpsRevision`, `SpsHeader`, `SpsPoint` (`initSpsPoint`), `SpsPointKind`, `SpsRelation` (`initSpsRelation`), `SpsEntry`, `SpsEntryKind`, `looksLikeSps`; `P1Record` (`initP1Record`), `PLogicalFile`, `PFormat`, `AngleUnit`; `TextRecord`, `TextLayout`, `detectLayout`, `openLayout`, `textRecords`, `CardWidth`, `MaxLineBytes` |
| Vendor maps (`vendor/maps`, `vendor/scaffold`) | `VendorRegistry` (`addMap`), `VendorMap`, `loadVendorMap`, `checkVendorMap`, `vendorSearchPath`, `VendorContext`, `VendorArea`, `VendorDecoder`, `decodeTarget`, `VendorField`, `VendorValue`, `VendorValueKind`, `toFloat`; the compiled map: `VendorMatch`, `VendorRevision`, `VendorRevisionRange`, `VendorTarget`, `VendorTargetKind`, `VendorFieldPlan`, `VendorRepeatPlan`, `VendorEncoding`, `VendorTrim`, `VendorEnumLabel`, `VendorBitFlag`; `VendorScaffold` |
| Records and media (`io/records`, `io/diskio`, `io/memsource`, `io/tapeimage`, `io/tapedevice`, `io/tape_linux`) | `RecordSink`, `RecordCursor` (`initRecordCursor`, `readExactly`, `skip`, `skipTapeMark`, `stoppedAt`, `remainingInRecord`, `atRecordStart`, `readRecordRest`, `preferSmallReads`), `readRecord`, `writeRecord`, `writeTapeMark`, `DefaultChunkSize`; a custom source or sink overrides the methods `readRecordImpl`, `seekForward`, `hasRecordBoundaries`, `writeRecordImpl`, `writeTapeMarkImpl`; `DiskSource`, `DiskSink`, `DefaultMapChunk`, `TapeImageSource`, `TapeImageSink`, `DeviceSource`, `DeviceSink`, `DefaultMaxBlockSize`, `TapeStatus`, `newMemoryTape` (`TapeItem`, `TapeItemKind`, `dataBlock`, `tapeMark`; a `MemoryTape` has `len`, `[]` and `items`), `LinuxTape` / `openLinuxTape` (Linux) |
