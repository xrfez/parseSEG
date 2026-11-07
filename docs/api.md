# parseSEG public API (task 8.2)

`import parseSEG` gives the stable surface listed here. Everything else is internal or
low-level:
- `parseSEG/codecs` holds the byte codecs and the field-layout pragmas;
- the `parseSEG/<area>/<module>` paths can still be imported one by one.

C, C++, Python and other hosts use the same model through the C ABI: `include/parseseg.h`,
the `seg_*` functions, and the `parseseg` Python package over the same library. Both are
generated from the `{.segApi.}` procs in `parseSEG/abi/api.nim` (see
`docs/design/c_abi.md` and `docs/design/python.md`).

Conventions that hold throughout:
- **Reads never raise on file content.** Problems go into a `DiagLog` (`log` /
  `diagnostics`) with a severity, code, offset and location. A read ends early only on
  truncation or I/O failure, and that is logged as `fatal`.
- **Programmer errors are Defects.** Out-of-range trace numbers or a closed file passed to a
  Nim proc are `doAssert`s. The C ABI checks for them and returns `SEG_ERR_ARGUMENT`.
- **Samples are Arraymancer tensors** `[traces, samples]` (`float32`, or `float64` where it
  matters). Headers are plain objects that keep their raw bytes, so a write → read round
  trip is byte-identical.
- **Offsets are 64-bit**, and nothing loads a whole file unless asked to (`readSegy`,
  `readSegd`).

## Opening and indexing (any size, disk)
| Proc | What |
|---|---|
| `openSeismic(path, keys = false, writable = false): SeismicFile` | Memory-maps the file, detects SEG-Y or SEG-D, and builds the trace index (`index`, 24 B per trace). With `keys`, also collects per-trace geometry. |
| `detectKind(bytes, kind): bool` | Detection only. |
| `buildIndex(src: RecordSource, kind, keys = false): TraceIndex` | The same index from any source: disk, tape image or tape device (`contiguous` is false for tape). |
| `f.len`, `f.kind`, `f.log`, `f.index.entries[i]` (`TraceEntry`), `f.index.segy`, `f.index.segdRecords`, `f.close()` | File access. A `SeismicFile` that goes out of scope unmaps itself; `close` does it early. |

## Reading samples
| Proc | What |
|---|---|
| `readTraces(f, a..b, T = float32)` | A range as a new tensor. |
| `readTraces(f, traces: openArray[int], T)` | A **selection** (gather, component group, sort order) in list order. |
| `readTracesInto(f, first, count, var tensor, row, log)` and `readTracesInto(f, traces, var tensor, row, log)` | Decode into an existing tensor. |
| `readTracesRaw(f, traces, ptr, cols, rowStride, log)` | Decode into a caller-owned buffer (numpy, C). |
| `newPrefetcher[T](f, first, last, chunkTraces, depth, cols)` and `newPrefetcher[T](f, selection, ...)` | Read-ahead on a worker thread: `tryNext` (never blocks), `next`, `seek`, `atEnd`, `traceAt`, `positions`, `close`. |

Sorting is a selection: a sort produces a list of trace indices, and no data is moved
(PLAN.md, "Future").

## Headers
| Proc | What |
|---|---|
| `traceField(f, trace, "trace.sourceX", v)`, `recordField(f, record, "gh1.year", v)`, `fileField(f, "binary.sampleInterval", v)` | Any named header field, read from the map. Names are listed by `fieldNames(HeaderBlock)`. |
| `readSegyHeaders(path)`, `readSegdHeaders(path)`; `openSegy`/`openSegd(src, headersOnly = true)` | Every header object, samples skipped (also on tape). |
| `traceKeys(...)`, `TraceKeys` | Per-trace geometry (record, source and receiver line/point/index/coordinates, component). |

## Gathers and components
`gathers(index)`: a split into `Gather` (`kind`: shot, receiver, cmp, offset, other or
unknown; `traces`; `sources`; `receivers`), derived from the geometry, never assumed.
`classify(index, range)`. `componentGroups(index, range)` returns a `ComponentGroup`
(station, traces, components) per station and source; see `isMultiComponent`.

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
| `SurveyGeometry`: `addSps(g, sps, LineNames)`, `addP1(g, p1, LineNames, elevation)`, `relation(g, record, channel, rel)` | Station coordinates (`table`) and relation runs. `LineNames` maps text line names (`names`, `trailingDigits`). `multiComponent`, `tape` refine X records. |
| `applySurvey(keys or index, g, overwrite = false)` | Stations from relations (on `TraceKeys.record` and `.channel`), then coordinates, offset, midpoint. |
| `GeometryTable`, `addSource`/`addReceiver`, `applyGeometry` | The coordinate table alone (a host's database). Keys are rounded to 1/100; a trace without a point index also matches index 1. |

C: `seg_geometry_load_sps`, `seg_geometry_load_p1`, `seg_geometry_map_line`,
`seg_geometry_set_options`, `seg_geometry_counts`, then `seg_file_apply_geometry`. Python:
`Geometry.load_sps`, `load_p1`, `map_line`, `set_options`, `counts`, then
`SeismicFile.apply_geometry`.

## In-place edits
`openEditor(path, journal)` and `setField(trace, "trace.<f>", v)` / `setField("binary.<f>", v)`
/ `setRecordField(record, "gh1.<f>", v)`, then `close`. Field names are as above. Edits are
size-preserving and validated, and each is journaled before it is written.
`rollbackJournal(path, journal)` / `applyJournal(path, journal)` undo or redo them.

Header documents (`model/headernif`): `exportHeaders(f, path, raw = true)` streams every named
field (and raw bytes) as NIF; `diffHeaders(f, nifPath, log)` lists the fields an edited
document changes; `importHeaders(path, nifPath, outPath, journal, dryRun)` applies them as a
patch through the editor, in place or into a copy.

## Streaming readers and writers (disk and tape)
- SEG-Y: `openSegy(src)` / `readTrace`, `readSegy(path)`, `openSegyWriter(sink, file, opts)` /
  `writeTrace` / `close`, `initSegyWriteOptions(file, lenient)`.
- SEG-D: `openSegd(src)` / `nextRecord` / `readTrace`, `readSegd(path)`,
  `openSegdWriter(sink, opts)`, `writeSegd(sink, data)`.
- Vendor maps: `loadVendorMaps`, `registerVendorDecoder`, `decode`, `applies`,
  `decodeVendorAreas`; `scaffold(path, reg)` / `toNif` write a skeleton map for every area no
  map decodes.
- Media: `openDiskSource`/`openDiskSink`, `openMemFileSource`,
  `openTapeImageSource`/`openTapeImageSink`, `newDeviceSource`/`newDeviceSink` over a
  `TapeDevice` (Linux `st`, Windows tape, `MemoryTape`).

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
`DiagLog` (`len`, `items`, `count(severity)`, `isFatal`, `toNif`, `writeNif`), `Diagnostic`,
`Severity`, `DiagCode`, `Location`, and `readDiagnostics` / `parseDiagnostics` for NIF round
trips.
