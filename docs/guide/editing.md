# Editing headers: in place, journaled, as patches

Updating coordinates, statics or a job id in the headers of a 40 GB file should not mean
rewriting 40 GB. parseSEG edits header fields **in place**, through a read-write map, and
journals every edit first so it can be undone. Larger changes go through header documents
(export, edit, import as a patch) or a full rewrite ([conversion.md](conversion.md)).

The rule behind all of it: files change only on an explicit write. Opening, reading and
joining geometry never change a byte; the calls on this page do, and only these.

## The editor

`openEditor(path, journalPath)` maps the file read-write and opens the journal (default
`<path>.edits.nif`). Each `setTraceField` / `setRecordField` / `setFileField` returns `true`
when the edit was written, or `false` with the reason in `ed.log`; it never raises for a
refused edit. The log holds the first 1000 refusals of a session; a script that keeps trying
gets `false` each time, and `close` adds how many were not logged. Field names are the ones
the header listings show (`<block>.<field>`).

```nim
import std/os
import parseSEG

copyFile("survey.sgy", "line.sgy")

var ed = openEditor("line.sgy", "line.sgy.journal.nif")
doAssert ed.setTraceField(5, "trace.sourceX", 1_700_000)
doAssert ed.setTraceField(7, "trace.groupStatic", -12)
doAssert ed.setFileField("binary.jobId", 4242)
doAssert ed.setTraceField(0, "trace.headerName", "ABC")       # text fields take strings

# Refused: a value that does not fit the field, and a field that sizes the file.
doAssert not ed.setTraceField(5, "trace.groupStatic", 100_000)  # 2-byte field
doAssert not ed.setTraceField(5, "trace.numSamples", 10)
for d in ed.log: echo "refused: ", d.msg

echo "trace 5 sourceX is now ", ed.currentTraceField(5, "trace.sourceX")
echo ed.edits, " edits written"
ed.close()

var f = openSeismic("line.sgy")
doAssert f.traceField(5, "trace.sourceX").intVal == 1_700_000
doAssert f.fileField("binary.jobId").intVal == 4242
```

What the editor refuses, and why:

- values that do not fit the field (width, sign, BCD digits, nibble, range);
- fields that size the file's structure: sample counts, formats, header and extension
  counts, channel set references, revision and byte-order fields (changing them needs a
  rewrite);
- SEG-2 headers (keyword strings are variable length: rewrite the file), multiplexed SEG-D
  (`openEditor` raises `ValueError`: convert to a demultiplexed file first), tape;
- blocks without editable fields. The editor names `trace`, `ext1` (SEG-Y and SEG-D),
  `binary` (SEG-Y), `gh1`, and for SEG-D Rev 1/2 the source headers `gh3`, `gh4`, ...
  (`setRecordField`).

## Editing a file that is already open

A viewer has the file open already (`openSeismic`, maybe with joined keys). `openEditor(f)`
takes it over: it maps the same path read-write in place of the read-only map and keeps the
index, so nothing is walked twice; journal and refusals are those of `openEditor(path)`. It
refuses (`ValueError`) a closed file, a demultiplexed copy of multiplexed SEG-D, and a file
whose size changed since it was opened. `release(ed)` ends the session like `close` but hands
the file back, still mapped and showing the edits. A prefetcher running on the file keeps
its own map and sees the edits too.

```nim
import std/os
import parseSEG

copyFile("survey.sgy", "view.sgy")
var f = openSeismic("view.sgy")
echo "trace 2 static: ", f.traceField(2, "trace.totalStatic")
var ed = openEditor(move f)                 # `move`: `f` is a global here
doAssert ed.setTraceField(2, "trace.totalStatic", 9)
f = release(move ed)                        # the same file, as edited, still open
doAssert f.traceField(2, "trace.totalStatic").intVal == 9
f.close()
doAssert rollbackJournal("view.sgy", "view.sgy.edits.nif").len == 0
```

### Keys follow the edits

When the file has stored keys, they follow the edits: a trace, record or keyed binary field
edit refreshes the affected traces' keys once the bytes are on the map (a batch's at
`endBatch`), and `keysRevision` goes up. Values that a survey join wrote stay as joined, group
by group (`JoinGroup`: source X/Y, receiver X/Y, each elevation, each station, the
component); the trace's other keys follow its headers. After a join that filled the source
coordinates only, an edit of the header's receiver coordinates shows in the keys, and the
offset and midpoint the join derived are derived again. On the open editor,
`rollbackJournal(ed)` and `applyJournal(ed)` undo and redo the session's journal and refresh
the cached headers and keys too.

```nim
import std/os
import parseSEG

copyFile("survey.sgy", "keys.sgy")
var ed = openEditor(openSeismic("keys.sgy", keys = true))
doAssert ed.setTraceField(4, "trace.delayRecordingTime", 120)
doAssert ed.file.traceKeys(4).t0Ms == 120 and ed.file.keysRevision == 1
discard ed.rollbackJournal()                # undo on the open file
doAssert ed.file.traceKeys(4).t0Ms == 0 and ed.file.keysRevision == 2
ed.close()
```

## Many edits: batches

Each edit is journaled and synced to disk before the file changes. For thousands of edits,
put them in a batch to share one sync. Trace and SEG-D record edits wait for the batch
alike: the file, the stored keys and the index's copies of the record headers follow at
`endBatch` (`currentTraceField` and `currentRecordField` show an edit at once). If the
journal cannot be synced, the batch's edits are not written (`endBatch` returns `false`,
and `ed.log` says how many were dropped).

```nim
import std/os
import parseSEG

copyFile("survey.sgy", "statics.sgy")
var ed = openEditor("statics.sgy")
ed.beginBatch()
for i in 0 ..< ed.file.len:
  doAssert ed.setTraceField(i, "trace.totalStatic", i mod 7)
doAssert ed.endBatch()
ed.close()                                  # also ends an open batch
doAssert fileExists("statics.sgy.edits.nif")
var f = openSeismic("statics.sgy")
doAssert f.traceField(13, "trace.totalStatic").intVal == 13 mod 7
```

## Undo and redo: the journal

The journal is a NIF file, one entry per edit (offset, original bytes, new bytes), written
before the edit, so even an interrupted session can be rolled back. `rollbackJournal` undoes
a journal newest first; `applyJournal` replays it oldest first (redo, or the same edits on
a copy). Both skip locations that already hold the target bytes and log conflicts (bytes
that hold neither the original nor the edited value) instead of overwriting them.

```nim
import std/os
import parseSEG

copyFile("survey.sgy", "undo.sgy")
let original = readFile("undo.sgy")
var ed = openEditor("undo.sgy")
doAssert ed.setTraceField(0, "trace.sourceX", 250)
ed.close()
echo readFile("undo.sgy.edits.nif")

let undo = rollbackJournal("undo.sgy", "undo.sgy.edits.nif")
doAssert undo.len == 0 and readFile("undo.sgy") == original
let redo = applyJournal("undo.sgy", "undo.sgy.edits.nif")
doAssert redo.len == 0 and readFile("undo.sgy") != original
```

## Header documents: export, edit, import as a patch

`exportHeaders(f, path)` streams every named header field of a file (and, with `raw`, each
block's bytes in hex) to a NIF document. Edit it with any tool, then `importHeaders` applies
it as a **patch**: each field is compared with the file and only the changed ones are
written, through the journaled editor, into the file itself or into a copy (`outPath`).
Start with a dry run.

```nim
import std/[os, strutils]
import parseSEG

var f = openSeismic("record.sgd")
exportHeaders(f, "record.headers.nif", raw = false)
f.close()

# Change one value in the document, as a user or a script would.
var doc = readFile("record.headers.nif")
doAssert "(f receiverPointNumber 104)" in doc
doc = doc.replace("(f receiverPointNumber 104)", "(f receiverPointNumber 105)")
writeFile("record.headers.nif", doc)

let plan = importHeaders("record.sgd", "record.headers.nif",
  ImportOptions(dryRun: true))
echo "a dry run would change ", plan.applied, " field(s)"

# Apply it to a copy: the original file stays as it is.
let done = importHeaders("record.sgd", "record.headers.nif",
  ImportOptions(outPath: "record_fixed.sgd",
    onChange: proc (c: HeaderChange) = echo "  ", c.name, ": ", c.old, " -> ", c.new))
for d in done.log: echo d
doAssert plan.applied == 1 and done.applied == 1 and done.refused == 0
var g = openSeismic("record_fixed.sgd")
doAssert g.traceField(0, "ext1.receiverPointNumber").intVal == 105
```

A document made from another file (different standard, trace or record count) is refused
unless `force`. Entries that name fields the file lacks are errors in the result's log.
`importHeaders` never raises: I/O and document problems are fatal diagnostics, and the
edits made before one stay (journaled).

### Patches from a viewer

`writeHeaderPatch` with a list of `HeaderChange`s (made with `initHeaderChange`) writes the same layout
with only the changed fields and no standard or counts, so `importHeaders` checks only the
fields themselves. This is how a viewer saves a user's pending edits without touching the
file ([viewer.md](viewer.md)).

```nim
import std/os
import parseSEG

writeHeaderPatch([
  initHeaderChange(hsTrace, 5, "trace.sourceX", toFieldValue(1_700_000)),
  initHeaderChange(hsFile, 0, "binary.jobId", toFieldValue(7))], "pending.nif")

copyFile("survey.sgy", "patched.sgy")
let r = importHeaders("survey.sgy", "pending.nif")         # in place, journaled
doAssert r.applied == 2 and fileExists("survey.sgy.edits.nif")
var f = openSeismic("survey.sgy")
doAssert f.fileField("binary.jobId").intVal == 7
```

The command line tool applies a patch too
(`parseSEG headers import <file> <patch> [-o copy]`).

## Geometry write-back

Joined survey coordinates are written with the same editor (`writeGeometry`), so they are
journaled and undoable too; see [conversion.md](conversion.md#write-the-geometry-into-the-file).
