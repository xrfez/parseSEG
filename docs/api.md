# parseSEG public API (task 8.2)

`import parseSEG` gives the stable surface listed here. Everything else is internal or
low-level:
- `parseSEG/codecs` holds the byte codecs and the field-layout pragmas;
- the `parseSEG/<area>/<module>` paths can still be imported one by one.

C, C++, Python and other hosts use the same model through the C ABI: `include/parseseg.h`,
the `seg_*` functions, and the `parseseg` Python package over the same library. Both are
generated from this API itself: the procs below marked `{.segApi.}` are exported, and their
C and Python names are derived from the Nim ones (`f.traceKeys(i)` is
`seg_seismic_file_trace_keys` in C and `f.trace_keys(i)` in Python; see
`docs/design/c_abi.md` and `docs/design/python.md`).

Conventions that hold throughout:
- **Reads never raise on file content.** Problems go into a `DiagLog` (`log` /
  `diagnostics`) with a severity, code, offset and location. A read ends early only on
  truncation or I/O failure, and that is logged as `fatal`.
- **Bad arguments raise `ValueError`.** An out-of-range trace or range, a closed file, or a
  file opened without `keys` where keys are needed, raise a catchable `ValueError` from the
  public procs (the C ABI returns `SEG_ERR_ARGUMENT`). Lookups by name have a raising form
  (`traceField(f, trace, name): FieldValue`) and a `bool` form with `var` results.
- **Trace ranges are `Slice[int]`** (`0 ..< f.len`, both ends included as in Nim) and
  selections are `openArray[int]`; both parameters are named `traces`.
- **Samples are Arraymancer tensors** `[traces, samples]` (`float32`, or `float64` where it
  matters). Headers are plain objects that keep their raw bytes, so a write → read round
  trip is byte-identical.
- **Offsets are 64-bit**, and nothing loads a whole file unless asked to (`readSegy`,
  `readSegd`).

## Opening and indexing (any size, disk)
| Proc | What |
|---|---|
| `openSeismic(path, twosComplement8015 = false, keys = false, writable = false): SeismicFile` | Memory-maps the file, detects SEG-Y or SEG-D, and builds the trace index (`index`, 24 B per trace). With `keys`, also collects per-trace geometry (about 100 B per trace). |
| `detectKind(bytes, kind): bool` | Detection only. |
| `buildIndex(src: RecordSource, kind, keys = false): TraceIndex` | The same index from any source: disk, tape image or tape device (`contiguous` is false for tape). |
| `f.len`, `f.kind` (`skSegy`, `skSegd`, `skUnknown`), `f.log`, `f.recordCount`, `f.maxSamples`, `f.hasKeys`, `f.isOpen`, `f.path` | File facts. |
| `f.traceEntry(i)` (`TraceEntry`), `f.traceKeys(i)` (`TraceKeys`), `f.copyBytes(offset, n)`, `f.sampleIntervalUs(i)` | One trace's location, geometry, raw bytes and sample interval. |
| `f.index.segy`, `f.index.segdRecords`, `f.close()` | The format's own headers. A `SeismicFile` that goes out of scope unmaps itself; `close` does it early. |

## Reading samples
| Proc | What |
|---|---|
| `readTraces(f, traces: Slice[int], T = float32)` | A range as a new tensor. |
| `readTraces(f, traces: openArray[int], T)` | A **selection** (gather, component group, sort order) in list order. |
| `readTracesInto(f, traces, var tensor, row = 0[, log])` | Decode a range or a selection into an existing tensor. |
| `readTracesRaw(f, traces, ptr, cols, rowStride, log)` | Decode into a caller-owned buffer (numpy, C). |
| `newPrefetcher[T](f, traces, chunkTraces, depth, cols)` (a range or a list) | Read-ahead on a worker thread: `tryNext` (never blocks), `next`, `seek(span)`, `atEnd`, `traceAt`, `positions`, `close`. |

Sorting is a selection: a sort produces a list of trace indices, and no data is moved
(PLAN.md, "Future").

## Headers
| Proc | What |
|---|---|
| `traceField(f, trace, "trace.sourceX")`, `recordField(f, record, "gh1.year")`, `fileField(f, "binary.sampleInterval")` | Any named header field, read from the map (raises `ValueError` for an unknown name; the `bool` forms take `var v[, err]`). Names are listed by `fieldNames(HeaderBlock)`. |
| `readSegyHeaders(path)`, `readSegdHeaders(path)`; `openSegy`/`openSegd(src, headersOnly = true)` | Every header object, samples skipped (also on tape). |
| `traceKeys(...)`, `TraceKeys` | Per-trace geometry (record, source and receiver line/point/index/coordinates, component). |

## Gathers and components
`gathers(f or index)`: a split into `Gather` (`kind`: shot, receiver, cmp, offset, other or
unknown; `traces`; `sources`; `receivers`), derived from the geometry, never assumed.
`classify(index, range)`. `componentGroups(f or index, traces)` returns a `ComponentGroup`
(station, traces, components) per station and source; see `isMultiComponent`.
`componentGroupIds(f, traces)` labels each trace with its group (-1 for none).

## Survey files and external geometry (Phase 10)
SPS (Rev 1.0, 2.1) and SEG P1 (1983) give the coordinates that SEG-D 2.x headers lack, and SPS
X records name the stations each channel was recorded from. Spec notes: `docs/spec/sps.md`,
`docs/spec/p1_p2_p3.md`.

| Proc | What |
|---|---|
| `readSps(path or stream, SpsOptions)`, `parseSps(text)` → `SpsFile` | H, R/S (`points`), X (`relations`) and C records; revision from H00 or the columns. Every record keeps its raw text. |
| `writeSps(f, path or stream, SpsWriteOptions(revision, lineEnding, lenient))`, `spsText(f)` | Column-exact; unchanged records byte for byte; 1.0 ↔ 2.1. A value that does not fit is an error and nothing is written (unless `lenient`). |
| `readP1(path or stream, P1Options(gridDecimals, depthDecimals, angleUnit))`, `parseP1` → `P1File` | Logical files (`files`), each with its header text and records; P1 decoded, P2-P4 kept raw. |
| `writeP1(f, path or stream, P1WriteOptions)`, `p1Text(f)` | Header blocks padded to 20 records; unchanged records byte for byte. |
| `SurveyGeometry` (`initSurveyGeometry()`): `addSps(g, sps or path)`, `addP1(g, p1 or path, ..., elevation)`, `addSource`/`addReceiver`, `relation(g, record, channel, rel)` | Station coordinates (`table`, `sourceCount`, `receiverCount`) and relation runs (`relationCount`). Text line names go through `mapLine(g, name, line)` (`lineNames`), then `trailingDigits`. `multiComponent`, `tape` refine X records; problems are in `log`. |
| `applySurvey(f, keys or index, g, overwrite = false)` | Stations from relations (on `TraceKeys.record` and `.channel`), then coordinates, offset, midpoint; in memory only, the file does not change. |
| `GeometryTable`, `addSource`/`addReceiver`, `applyGeometry` | The coordinate table alone (a host's database). Keys are rounded to 1/100; a trace without a point index also matches index 1. |

C: `seg_survey_geometry_new`, `seg_survey_geometry_add_sps`, `..._add_p1`, `..._map_line`,
`..._set_trailing_digits`, then `seg_seismic_file_apply_survey`. Python:
`SurveyGeometry()`, `add_sps`, `add_p1`, `map_line`, `trailing_digits = True`, then
`SeismicFile.apply_survey`.

## In-place edits
`openEditor(path, journalPath)` and `setTraceField(trace, "trace.<f>", v)` /
`setFileField("binary.<f>", v)` / `setRecordField(record, "gh1.<f>", v)` (each `false` when
refused, with the reason in `log`), then `close`. Field names are as above. Edits are
size-preserving and validated, and each is journaled before it is written.
`rollbackJournal(path, journal)` / `applyJournal(path, journal)` undo or redo them.

Header documents (`model/headernif`): `exportHeaders(f, path, raw = true)` streams every named
field (and raw bytes) as NIF; `diffHeaders(f, nifPath, log)` lists the fields an edited
document changes; `importHeaders(path, nifPath, outPath, journal, dryRun)` applies them as a
patch through the editor, in place or into a copy.

## Streaming readers and writers (disk and tape)
- SEG-Y: `openSegy(src)` / `readTrace`, `readSegy(path)`, `openSegyWriter(sink, file, opts)` /
  `writeTrace` / `close`, `initSegyWriteOptions(file, lenient)`. `file.format` is an
  `Option[SampleFormat]` (none for an undefined format code). Named trace values go through
  the file's Layout: `fieldValue(file, trace, "iline")` returns an `Option[float64]`,
  `initGeometryReader(file).geometry(trace)` the common ones; `layoutOf(file).entriesFor(name)`
  lists the entries.
- SEG-D: `openSegd(src)` / `nextRecord` / `readTrace`, `readSegd(path)`,
  `openSegdWriter(sink, opts)`, `writeSegd(sink, data)`.
- Vendor maps: `loadVendorMaps`, `registerVendorDecoder`, `decode`, `applies`,
  `decodeVendorAreas`; `scaffold(path, reg)` / `toNif` write a skeleton map for every area no
  map decodes.
- Media: `openDiskSource`/`openDiskSink`, `openMemFileSource`,
  `openTapeImageSource`/`openTapeImageSink`, `newDeviceSource`/`newDeviceSink` over a
  `TapeDevice` (Linux `st`, Windows tape, `MemoryTape`). A custom drive overrides
  `readBlock(buf, n): RecordKind` (the block length goes to `n`), `writeBlock`,
  `writeTapeMarks`, `rewind`, `spaceFiles`, `status` and `close`. Sources and sinks count
  through the read-only `recordIndex` and `fileIndex`.

## Conversion
- `convertFile(src, dst, ConvertOptions(...))` detects the input and writes SEG-Y.
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
  samples copied byte for byte; the mapping and what is dropped are in `segd/revconvert.nim`.
  The stream form takes `scanRecords` (a headers-only pass) for exact sample counts.

## Diagnostics
`DiagLog` (`len`, `[]`, `items`, `count(severity)`, `hasErrors`, `isFatal`, `toNif`, `writeNif`), `Diagnostic`,
`Severity`, `DiagCode`, `Location`, and `readDiagnostics` / `parseDiagnostics` for NIF round
trips.
