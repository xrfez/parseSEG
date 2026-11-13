# Conversion, survey files and geometry

This page covers rewriting data in another standard or revision (SEG-Y, SEG-D, SEG-2), and
giving traces the geometry their headers lack, from SPS or SEG P1 survey files: in memory,
written into the file in place, or written into a copy.

## Convert a file

`convertFile(src, dst, opts)` detects the input standard and writes the one
`opts.target` names. It never raises: everything, I/O failures included, is in the returned
`DiagLog`. The output goes to a new temporary file next to `dst` (`<dst>.<random>.tmp`)
and is renamed when complete, so a failed or cancelled conversion leaves no partial file
and an existing `dst` untouched. A full disk is such a failure (a fatal diagnostic), also
when only the last flush fails; a `dst` that is a directory is refused before the input is
read. A `progress` hook (the last parameter) reports and cancels
long conversions ([processing.md](processing.md#batch-conversions-with-progress-and-cancel)).

```nim
import parseSEG

# SEG-D Rev 3.0 to SEG-Y Rev 2.1 (the defaults: big-endian, EBCDIC, lossless format).
let log = convertFile("shot.sgd", "shot.sgy")
for d in log: echo d                      # what SEG-Y had no place for, once per kind
doAssert not log.isFatal

var a = openSeismic("shot.sgd")
var b = openSeismic("shot.sgy")
doAssert b.kind == skSegy and b.len == a.len
doAssert b.readTraces(0 ..< b.len) == a.readTraces(0 ..< a.len)   # samples are exact
```

What the options choose (`ConvertOptions`):

| Field | Default | Meaning |
|---|---|---|
| `target` | `skSegy` | Output standard: `skSegy`, `skSegd` (from SEG-D or SEG-2 input), `skSeg2` (from any input) |
| `revision` | 2.1 | SEG-Y revision: 0.0, 1.0, 2.0 or 2.1 |
| `byteOrder` | `boBig` | SEG-Y byte order (`boLittle` is allowed from Rev 2) |
| `format` | `stKeep` | SEG-Y sample format: keep the input's, or choose a lossless one for SEG-D; or `st1` .. `st16` (`targetFormat(sfFloat32)` is `st5`) |
| `textEncoding` | `teEbcdic` | SEG-D → SEG-Y textual header encoding |
| `applyDescale` | false | SEG-D → SEG-Y: write millivolts instead of recorded values |
| `stationHeader` | true | SEG-D → SEG-Y Rev 2: line and point in a `PSEGD001` header, described by a Layout stanza |
| `segd` | Rev 3.0, keep format | SEG-D output: `SegdConvertOptions(revision, format)` |
| `seg2` | little-endian, keep format | SEG-2 output: `Seg2ConvertOptions(byteOrder, format)` |

Losses are reported, never silent: each kind of information the target cannot hold is one
info diagnostic; a sample value that does not fit the target format (NaN and the infinities
too, in every format but the IEEE floats) zeroes its trace with an error; a trace the
target revision cannot hold at all (more than 65535 samples, or a sample interval that is
not a whole number up to 65535, before SEG-Y Rev 2) is skipped with an error.

The trace keys survive a conversion to SEG-Y: the converters write them as
`writeTrace(w, keys, samples)` does, so `openSeismic` reads the same `TraceKeys` from the
output, among them a fractional source point (99.5), a start time that is negative,
fractional or beyond 32.767 s (with the time scalar, from Rev 1), and the fraction of the
recording time's second (Rev 2). Rev 0 holds less: whole numbers, whole milliseconds within
±32767 and trace codes 1-8; what was rounded is noted, a start time that was clamped is a
warning.

A new SEG-Y revision changes what some header bytes mean, and `convertFile` rewrites
those:

- to a later revision, the bytes the input's revision leaves unassigned and the target
  defines are cleared (Rev 0: binary header 3261-3600 and trace header 181-240; Rev 1:
  binary header 3261-3300 and 3507-3532), so vendor data there is not read as a field;
- to Rev 0, the time scalar is applied to the times of trace bytes 95-114, which become
  whole milliseconds, and bytes 181-240 are cleared. A Layout stanza is lost with the
  extended textual headers: that is a warning, because the fields it moved are then read
  from their standard bytes;
- before Rev 2, a sample count or interval held in the Rev 2 extended fields moves to the
  16-bit ones; a fixed-length file whose count or interval does not fit them is refused.

### Between SEG-Y revisions, between SEG-D revisions, to and from SEG-2

```nim
import parseSEG

# SEG-Y Rev 2.1 to Rev 1.0, IEEE float.
var log = convertFile("survey.sgy", "rev1.sgy",
  ConvertOptions(revision: SegyRevision(major: 1, minor: 0), format: st5))
echo log.count(sevInfo), " notes on what Rev 1.0 cannot hold"
doAssert not log.isFatal
var r1 = openSeismic("rev1.sgy")
doAssert r1.fileField("binary.formatCode").intVal == 5

# SEG-D Rev 2.0 to Rev 3.0 (and back with revision 2.1): samples copied byte for byte.
log = convertSegdRevision("record.sgd", "record_rev3.sgd",
  SegdConvertOptions(revision: SegdRevision(major: 3, minor: 0)))
doAssert not log.isFatal
var r3 = openSeismic("record_rev3.sgd")
doAssert r3.summary.revision.major == 3

# Any standard to SEG-2, and SEG-2 back to SEG-D.
log = convertFile("shot.sgd", "shot.sg2",
  ConvertOptions(target: skSeg2))
doAssert not log.isFatal
log = convertFile("shot.sg2", "shot_back.sgd", ConvertOptions(target: skSegd))
doAssert not log.isFatal
var s2 = openSeismic("shot.sg2")
doAssert s2.kind == skSeg2 and s2.traceField(0, "trace.SAMPLE_INTERVAL").text == "0.001"
```

The field mappings (which SEG-D field lands in which SEG-Y field, what SEG-2 keyword strings
become) are tabulated in the module docs of `src/parseSEG/convert/`: `tosegy.nim`,
`tosegd.nim` and `toseg2.nim`, one per target standard. Multiplexed SEG-D is
demultiplexed on the way (`demultiplexSegd` does only that).

Streams: `convertSegy(src, sink)`, `convertSegdToSegy(src, sink)` and
`convertSegdRevision(src, sink)` work on any `RecordSource`/`RecordSink`, tape images and
tape devices included.

## Survey files: give the traces their geometry

SEG-D 2.x headers usually carry station numbers but no coordinates, and some files not even
station numbers per channel. SPS files (Rev 1.0, 2.1) give the coordinates of every source
(S records) and receiver (R records), and X records say which stations each channel of each
field record was recorded from. O records (often in `.ops` files) are the same relations in
the receiver domain: the X layout with source and receiver swapped, one gather per receiver.
SEG P1 files give shotpoint coordinates.

A `SurveyGeometry` collects them; `applySurvey` joins them to a file's keys **in memory**
(the file does not change). **Traces are matched by their stations** (line, point, index),
not by record number: field record and channel numbers often differ from the relation
file's. Stations a header has are never replaced; the relations only fill the ones it lacks:

- source and receiver station in the header: coordinates by station, nothing else;
- source station only: the X records **of that source station** give the receiver of the
  trace's channel (the one with the trace's record number when there are several repeats,
  else they must agree);
- receiver station only: the O gathers of that receiver give the source likewise (without
  O records, the X relation of the trace's record and channel, if its receiver is the
  header's);
- no station: the trace's record and channel, the fallback.

A header that has only the line or only the point of a station (a SEG-Y shotpoint without a
line) has the station filled whole, when the relation agrees with the part it has: the same
value to 1/100, or the relation's as a whole number (an integer field holds point 99.5 as
100). A relation that contradicts the part is a conflict (`jmConflict`) and fills nothing.

Then coordinates come from the stations, then offset and midpoint. `overwrite` replaces
coordinates already known, never stations. Auxiliary traces are left alone. A `JoinStats`
says how the traces matched and how many changed: a trace that already holds the survey's
values is not a change, so joining the same survey again changes nothing (`keysRevision`
stays, and an index no join changed can still be saved with `saveIndex`).

```nim
import std/math
import parseSEG

# A small SPS 2.1 file: record.sgd's receiver and source, and the relation of
# record 63, channel 1.
writeFile("line.sps", """H00 SPS format version number   SPS 2.1;
R     10.00    104.00  1G1                     500100.0 6000000.0  12.5 18213250
S     20.00     99.50  1V6                     500000.0 6000400.0  10.0 19001150
XT1          6311     20.00     99.501    1    11     10.00    104.00    104.001
""")

var g = initSurveyGeometry()
g.addSps("line.sps")
for d in g.log: echo d                    # problems met in the survey file
echo g.sourceCount, " source(s), ", g.receiverCount, " receiver(s), ",
  g.relationCount, " relation run(s)"

var f = openSeismic("record.sgd", keys = true)
doAssert f.traceKeys(0).rcvX.isNaN        # the SEG-D 2.0 headers have no coordinates
var stats: JoinStats
let changed = f.applySurvey(g, stats)
echo stats                                # 1 traces, 1 changed; by stations 1
let k = f.traceKeys(0)
echo changed, " trace(s) joined: receiver ", k.rcvLine, "/", k.rcvPoint, " at (", k.rcvX,
  ", ", k.rcvY, "), offset ", round(k.offset, 1)
doAssert changed == 1 and k.rcvX == 500100 and k.srcPoint == 99.5
doAssert stats.matches[jmStations] == 1   # the header's own stations were the key

# The receiver domain: O records built from the X relations, written as an
# .ops file and read back.
let ops = SpsFile(revision: sps21, headers: readSps("line.sps").headers,
  relations: g.receiverRelations())
doAssert not writeSps(ops, "line.ops").hasErrors
var go = initSurveyGeometry()
go.addSps("line.ops")                     # O records are receiver gathers
doAssert go.relationCount(rdReceiver) == 1
doAssert go.recordsAt(stationKey(10, 104, 1), rdReceiver) == @[1'i64]
```

- `records(g)`, `relations(g, record)`, `expectedChannels`, `recordsAt(g, station)` (the
  records of a source station, or the gathers of a receiver) and `channelOf` enumerate and
  look up the relations, in either domain (`rdSource`, `rdReceiver`).
- `relationRuns(g, record)` yields a record's relations run by run, as the survey file's X
  (or O) records give them: a channel range on evenly spaced stations of one line, with the
  fixed station (`RelationRun`; `station(run, i)` is its i-th station). Code that visits
  every station of a survey (fold, patch description) walks the runs instead of asking per
  channel: the pre-plot fold of a 5519-shot, 11-million-trace survey takes a quarter of a
  second that way.
- Line names that are not numbers (SPS 1.0, P1) are mapped with `g.mapLine(name, number)`,
  or by their trailing digits with `g.trailingDigits = true`.
- `g.multiComponent` makes X records with a channel increment cover consecutive component
  channels; `g.tape` restricts relations to one field tape.
- A record whose last channel is not the first of a station (channels 1..10 by 4) relates
  its whole stations only (channels 1..12 multi-component, else 1, 5 and 9), in every
  lookup and in `relationRuns`; the file gets a warning.
- A host with its own coordinate database can fill the table directly:
  `g.addSource(line, point, index, x, y, z)` and `g.addReceiver(...)`.
- `readSps`/`writeSps` and `readP1`/`writeP1` read and write the survey files themselves
  (column-exact, unchanged records byte for byte, Rev 1.0 ↔ 2.1). Their logs hold the first
  five problems of each kind and field and a count of the rest, so a file of bad records
  stays readable. An SPS file without a revision in H00 is read by its column layout, with a
  warning (`SpsOptions(revision: ...)` chooses); a P1 file's angles are read as DMS or grads
  for the whole file (`P1Options.angleUnit`, by default decided from its first records).
  `readSps` keeps the text of every record for the byte-exact write-back;
  `SpsOptions(keepRaw: false)` reads the values only (`g.addSps(path)` does).
- A station that a survey file gives twice is reported in `g.log`; the later coordinates are
  used.

## Write the geometry into the file

Once the keys are joined, three calls persist them. Each is an explicit write; all of them
first let you see what would change. In place, `openEditor(f)` maps the open file read-write
and keeps its index, joined keys included, so `writeGeometry()` writes them without opening
or walking the file again (`move f` at a module's top level, where `f` is a global).

```nim
import std/os
import parseSEG

writeFile("line.sps", """H00 SPS format version number   SPS 2.1;
R     10.00    104.00  1G1                     500100.0 6000000.0  12.5 18213250
S     20.00     99.50  1V6                     500000.0 6000400.0  10.0 19001150
XT1          6311     20.00     99.501    1    11     10.00    104.00    104.001
""")
var g = initSurveyGeometry()
g.addSps("line.sps")

# 1. In place, journaled and undoable: same-size header fields only. record.sgd's
#    SEG-D 2.0 headers already hold its stations, and have no coordinate fields.
copyFile("record.sgd", "field.sgd")
var f = openSeismic("field.sgd", keys = true)
discard f.applySurvey(g)
var report: DiagLog
let plan = f.geometryChanges(GeometryFields(), report)   # a dry run: nothing is written
echo "would change ", plan                # traces per kind, values with no slot
for d in report: echo "  ", d.msg
doAssert plan.traces == 0 and plan.unwritable > 0
var ed = openEditor(move f)               # takes over the open file and its joined keys
let done = ed.writeGeometry()
ed.close()
doAssert done == plan                     # rollbackJournal undoes a write, if wanted

# 2. Into a copy in the same standard.
let copied = copyWithGeometry("record.sgd", "record_geo.sgd", g)
doAssert not copied.log.hasErrors and copied.changes.traces == 0

# 3. Converted to SEG-Y, which has coordinate fields for everything.
let convLog = convertWithGeometry("record.sgd", "record_geo.sgy", g)
doAssert not convLog.isFatal
var y = openSeismic("record_geo.sgy", keys = true)
doAssert y.traceKeys(0).rcvX == 500100 and y.traceKeys(0).srcPoint == 99.5
```

Where the values go: SEG-Y through the file's layout (source, group and CDP coordinates with
a coordinate scalar chosen to keep the precision in 4 bytes, elevations, offset, shotpoint,
the Ext1 copies in use); SEG-D Rev 1/2 only the THE#1 receiver line, point and index (2.x
trace headers have no coordinate fields: that is what `unwritable` counts); SEG-D Rev 3 the
THE#1 fields and the Position and Source Description blocks the traces already have. SEG-2
is refused for now. `GeometryFields` selects which values to write (`sourceXy`,
`receiverXy`, `elevations`, `midpoints`, `offsets`, `stations`; all by default).

The counts (`GeometryChanges`) say what the headers hold differently afterwards: a source
point 99.5 for an integer field that already holds 100 is no change. A value that a field
cannot hold exactly is written rounded, with one "rounded" warning per kind of value, unless
another field of the same value holds it exactly (the SEG-Y shotpoint with its scalar holds
99.5 beside the energy source point's 100).
