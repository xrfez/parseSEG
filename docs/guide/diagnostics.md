# Diagnostics: how problems are reported, and what to do about them

Real seismic files break the standards in small ways all the time. parseSEG's rule is
**never silent, never interrupting**: reading a file runs to completion whenever that is
physically possible, and every problem becomes an entry in a log instead of an exception.
Exceptions are reserved for mistakes in the *call* and for the operating system refusing.

## Three kinds of outcome

| What happened | How you learn it | Where |
|---|---|---|
| The file breaks a rule (bad value, unknown block, truncated data) | A `Diagnostic` in a `DiagLog` | `f.log`, a read's `log`, a result's `log` |
| You passed a bad argument (trace out of range, closed file, unknown field name, missing keys) | An exception | `ValueError` |
| The OS refused (missing file, permissions, disk full) | An exception | `IOError` / `OSError` |

Opening a damaged or unrecognized file *succeeds*: you get a `SeismicFile` with what could be
indexed and a log saying what could not.

```nim
import std/os
import parseSEG

# Not seismic data at all: a fatal diagnostic, not an exception.
writeFile("junk.bin", newString(5000))
var j = openSeismic("junk.bin")
doAssert j.kind == skUnknown and j.len == 0 and j.log.isFatal
echo j.log[0]

# A file that does not exist is the operating system's problem: an exception.
try:
  discard openSeismic("missing.sgy")
  doAssert false
except IOError, OSError:
  echo "cannot open: ", getCurrentExceptionMsg()

# A bad argument is the caller's problem: ValueError, with the reason.
var f = openSeismic("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")
try:
  discard f.traceField(0, "trace.noSuchField")
  doAssert false
except ValueError as e:
  echo "bad call: ", e.msg
```

## What an entry says

A `Diagnostic` has:

- `severity`: `sevInfo` (noteworthy but valid, e.g. a vendor block kept raw), `sevWarning`
  (spec-invalid or suspicious, but decoded), `sevError` (a part could not be decoded and
  was kept raw, or a trace was left as zeros), `sevFatal` (the operation stopped early);
- `code`: a `DiagCode` (stable names, also in NIF);
- `offset`: the absolute byte offset in the file (-1 if unknown);
- `loc`: file, record, channel set, trace, header block index and field name, each -1 or
  empty when not applicable;
- `msg`: a sentence for humans.

`$d` gives a one-line form (`warning badValue @4340 [63.sgd, record 0, field ...]: ...`).
A `DiagLog` has `len`, `[]`, `items`, `count(severity)`, `hasErrors` (an error or fatal
entry), `isFatal`, and `toNif` / `writeNif` (and `readDiagnostics` / `parseDiagnostics` to
read them back).

## A damaged file, end to end

Here the last trace of a copy of the Inglewood file is cut short, as an interrupted copy
would leave it. The index walk stops at the cut with a `fatal` `truncated` entry that names
the trace and the byte offset; the index holds every trace before it, and those read
normally.

```nim
import parseSEG

let whole = readFile("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy")
writeFile("cut.sgy", whole[0 ..< whole.len - 1000])   # lose the last 1000 bytes

var f = openSeismic("cut.sgy")
for d in f.log: echo d
let last = f.log[f.log.len - 1]
doAssert f.log.isFatal and last.code == dcTruncated and last.loc.trace == 199
doAssert f.len == 199                                # every complete trace is indexed

var log: DiagLog
let data = f.readTraces(0 ..< f.len, log)            # the healthy part reads cleanly
doAssert log.len == 0 and data.shape == [199, 2001]
```

`isFatal` on an index log means "the walk stopped early", not "the file is unusable": decide
from `f.len` and the entry's location whether what was indexed is enough.

### Traces that cannot be decoded

A trace that is indexed but cannot be decoded (a sample format the library does not support,
or samples past the end of the mapped file) is handled by the read call, and you choose the
policy:

- `readTraces(f, traces, log)` and `readTracesInto(f, traces, dst, row, log)`: read past it.
  The trace is a zero row, `readTracesInto` counts it in its result, and `log` gets one
  `error` entry with the trace index, byte offset and reason. A `Prefetcher` does the same
  per chunk (`c.failed`, `c.log`).
- `readTraces(f, traces)` without a log: refuse damaged data. It raises `SegFormatError`
  (`SegTruncatedError` for samples past the end) naming the first such trace.
- `f.summary.decodable` says up front whether every trace's format can be decoded.

## How to act on each code

| Code | Typical cause | What to do |
|---|---|---|
| `io` | The OS failed a read or write | Check the path, permissions, free space; usually `fatal` |
| `truncated` | The data ends inside an announced structure (cut copy, interrupted transfer) | Traces before the cut are fine; the affected trace reads as zeros. Re-copy the file if you can |
| `badValue` | A field outside the spec's range (often harmless, e.g. a GH#3 source set number of 0) | `info`/`warning`: the value is kept as read. Decide per field whether your code relies on it |
| `badBcd` | A BCD field holds a non-decimal nibble | The field reads as -2; fix it with the editor if it matters |
| `inconsistent` | Two headers disagree (counts vs lengths, ...) | The message names the values that disagree; check the trace count against what you expect |
| `byteOrder` | The byte order was inferred, not declared (common for little-endian Rev 0/1 SEG-Y) | `info`: nothing to do unless the samples look wrong |
| `unsupportedRevision` | An unknown revision number | Parsed as the nearest known revision; check the summary |
| `unsupportedFormat` | A sample format the library cannot decode | Those traces read as zero rows (`error`); headers are still indexed |
| `unknownBlock` | A header block type the standard does not define | Kept raw (listed as `hbRaw`); nothing is lost |
| `vendorBlock` | A vendor block with no registered decoder | Kept raw; add a vendor map (`docs/design/vendor_maps.md`) to decode it |
| `vendorMap` | A vendor map is malformed or does not fit | Fix the map; the block stays raw |
| `tapeLayout` | Tape marks, labels or block sizes off the spec | Usually harmless on disk copies of tapes |
| `validation` | A writer or converter found something the target cannot hold or forbids; also conversion loss notes (`info`) | `error`: nothing was written unless `lenient`. `info`: read the note, it says what was dropped |
| `multiplexed` | The file holds multiplexed SEG-D, demultiplexed into a temporary copy | `warning`: reads and keys use the copy (`f.demuxPath`); edits need a demultiplexed file |
| `internal` | A library bug | Please report it with the message |

## Where logs come from

| Operation | Log | Fatal means |
|---|---|---|
| `openSeismic`, `buildIndex` | `f.log` (`f.index.log`) | Not recognized, or the walk stopped (truncation, I/O); the index has what came before |
| `readTraces(..., log)`, `readTracesInto(..., log)` | your `log` | (errors only: one per undecodable trace) |
| `Prefetcher` | each chunk's `c.log` | (errors only, one per failed row) |
| Streaming readers (`openSegy`, `openSegd`) and writers | `r.log`, `w.log` | The stream ended early |
| `HeaderEditor` | `ed.log` | Refused edits (`error`) and journal problems |
| `importHeaders` | `result.log` | The document was refused or unreadable |
| `convertFile`, `convertSegdRevision`, `copyWithGeometry`, `convertWithGeometry`, `rollbackJournal`, `applyJournal` | the returned `DiagLog` | Nothing usable was written (`dst` is untouched) |
| `SurveyGeometry.addSps` / `addP1`, `readSps`, `readP1` | `g.log`, the file's `log` | |

## Logs as files

Logs serialize to NIF, a small S-expression format, so a batch job can keep them next to its
outputs and a viewer can show them later.

```nim
import parseSEG

var f = openSeismic("SEG Spec/exampleFiles/63.sgd")
f.log.writeNif("63.diagnostics.nif")
echo readFile("63.diagnostics.nif")
let back = readDiagnostics("63.diagnostics.nif")
doAssert back.len == f.log.len and back.count(sevInfo) == 2
```
