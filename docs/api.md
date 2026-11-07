# parseSEGD public API (task 8.2)

`import parseSEGD` gives the stable surface listed here. Everything else is internal or
low-level:
- `parseSEGD/codecs` holds the byte codecs and the field-layout pragmas;
- the `parseSEGD/<area>/<module>` paths can still be imported one by one.

C, C++, Python and other hosts use the same model through the C ABI: `include/parseseg.h`,
the `seg_*` functions, built from `parseSEGD/capi` (see `docs/design/c_abi.md`).

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
| `f.len`, `f.kind`, `f.log`, `f.index.entries[i]` (`TraceEntry`), `f.index.segy`, `f.index.segdRecords`, `f.close()` | File access. |

## Reading samples
| Proc | What |
|---|---|
| `readTraces(f, a..b, T = float32)` | A range as a new tensor. |
| `readTraces(f, traces: openArray[int], T)` | A **selection** (gather, component group, sort order) in list order. |
| `readTracesInto(f, first, count, var tensor, row, log)` and `readTracesInto(f, traces, var tensor, row, log)` | Decode into an existing tensor. |
| `readTracesRaw(f, traces, ptr, cols, rowStride, log)` | Decode into a caller-owned buffer (numpy, C). |
| `newPrefetcher[T](f, first, last, chunkTraces, depth, cols)` and `newPrefetcher[T](f, selection, ...)` | Read-ahead on a worker thread: `tryNext` (never blocks), `next`, `seek`, `atEnd`, `traceAt`, `close`. |

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

## In-place edits
`openEditor(path, journal)` and `setField(trace, "trace.<f>", v)` / `setField("binary.<f>", v)`
/ `setRecordField(record, "gh1.<f>", v)`, then `close`. Field names are as above. Edits are
size-preserving and validated, and each is journaled before it is written.
`rollbackJournal(path, journal)` / `applyJournal(path, journal)` undo or redo them.

## Streaming readers and writers (disk and tape)
- SEG-Y: `openSegy(src)` / `readTrace`, `readSegy(path)`, `openSegyWriter(sink, file, opts)` /
  `writeTrace` / `close`, `initSegyWriteOptions(file, lenient)`.
- SEG-D: `openSegd(src)` / `nextRecord` / `readTrace`, `readSegd(path)`,
  `openSegdWriter(sink, opts)`, `writeSegd(sink, data)`.
- Vendor maps: `loadVendorMaps`, `registerVendorDecoder`, `decode`.
- Media: `openDiskSource`/`openDiskSink`, `openMemFileSource`,
  `openTapeImageSource`/`openTapeImageSink`, `newDeviceSource`/`newDeviceSink` over a
  `TapeDevice` (Linux `st`, Windows tape, `MemoryTape`).

## Conversion
`convertToSegy(...)` and `convertSegyRevision(...)` (task 8.6).

## Diagnostics
`DiagLog` (`len`, `items`, `count(severity)`, `isFatal`, `toNif`, `writeNif`), `Diagnostic`,
`Severity`, `DiagCode`, `Location`, and `readDiagnostics` / `parseDiagnostics` for NIF round
trips.
