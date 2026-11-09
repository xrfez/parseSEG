# Conversion, survey files and geometry

This page covers rewriting data in another standard or revision (SEG-Y, SEG-D, SEG-2), and
giving traces the geometry their headers lack, from SPS or SEG P1 survey files: in memory,
written into the file in place, or written into a copy.

## Convert a file

`convertFile(src, dst, opts)` detects the input standard and writes the one
`opts.target` names. It never raises: everything, I/O failures included, is in the returned
`DiagLog`. The output goes to `<dst>.tmp` and is renamed when complete, so a failed
conversion leaves no partial file and an existing `dst` untouched.

```nim
import parseSEG

# SEG-D Rev 3.0 to SEG-Y Rev 2.1 (the defaults: big-endian, EBCDIC, lossless format).
let log = convertFile("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", "inova.sgy")
for d in log: echo d                      # what SEG-Y had no place for, once per kind
doAssert not log.isFatal

var a = openSeismic("SEG Spec/exampleFiles/inova_rev30_5traces.sgd")
var b = openSeismic("inova.sgy")
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
info diagnostic; a sample value that does not fit the target format zeroes its trace with an
error.

### Between SEG-Y revisions, between SEG-D revisions, to and from SEG-2

```nim
import parseSEG

# SEG-Y Rev 2.1 to Rev 1.0, IEEE float.
var log = convertFile("SEG Spec/exampleFiles/BO_3D-Inglewood_rev21_v7.sgy", "rev1.sgy",
  ConvertOptions(revision: SegyRevision(major: 1, minor: 0), format: st5))
echo log.count(sevInfo), " notes on what Rev 1.0 cannot hold"
doAssert not log.isFatal
var r1 = openSeismic("rev1.sgy")
doAssert r1.fileField("binary.formatCode").intVal == 5

# SEG-D Rev 2.0 to Rev 3.0 (and back with revision 2.1): samples copied byte for byte.
log = convertSegdRevision("SEG Spec/exampleFiles/63.sgd", "63_rev3.sgd",
  SegdConvertOptions(revision: SegdRevision(major: 3, minor: 0)))
doAssert not log.isFatal
var r3 = openSeismic("63_rev3.sgd")
doAssert r3.summary.revision.major == 3

# Any standard to SEG-2, and SEG-2 back to SEG-D.
log = convertFile("SEG Spec/exampleFiles/inova_rev30_5traces.sgd", "inova.sg2",
  ConvertOptions(target: skSeg2))
doAssert not log.isFatal
log = convertFile("inova.sg2", "inova_back.sgd", ConvertOptions(target: skSegd))
doAssert not log.isFatal
var s2 = openSeismic("inova.sg2")
doAssert s2.kind == skSeg2 and s2.traceField(0, "trace.SAMPLE_INTERVAL").text == "0.001"
```

The field mappings (which SEG-D field lands in which SEG-Y field, what SEG-2 keyword strings
become) are tabulated in the module docs of `src/parseSEG/convert.nim`,
`src/parseSEG/segd/revconvert.nim` and `src/parseSEG/seg2convert.nim`. Multiplexed SEG-D is
demultiplexed on the way (`demultiplexSegd` does only that).

Streams: `convertSegy(src, sink)`, `convertSegdToSegy(src, sink)` and
`convertSegdRevision(src, sink)` work on any `RecordSource`/`RecordSink`, tape images and
tape devices included.

## Survey files: give the traces their geometry

SEG-D 2.x headers usually carry station numbers but no coordinates, and some files not even
station numbers per channel. SPS files (Rev 1.0, 2.1) give the coordinates of every source
(S records) and receiver (R records), and X records say which stations each channel of each
field record was recorded from. SEG P1 files give shotpoint coordinates.

A `SurveyGeometry` collects them; `applySurvey` joins them to a file's keys **in memory**
(the file does not change): stations from the relations (matched on `TraceKeys.record` and
`.channel`), then coordinates from the stations, then offset and midpoint.

```nim
import std/math
import parseSEG

# A small SPS 2.1 file: one receiver, one source, and the relation of record 63, channel 1.
writeFile("line.sps", """H00 SPS format version number   SPS 2.1;
R     10.00    101.00  1G1                     500100.0 6000000.0  12.5 18213250
S     20.00    205.00  1V6                     500000.0 6000400.0  10.0 19001150
XT1          6311     20.00    205.001    1    11     10.00    101.00    101.001
""")

var g = initSurveyGeometry()
g.addSps("line.sps")
for d in g.log: echo d                    # problems met in the survey file
echo g.sourceCount, " source(s), ", g.receiverCount, " receiver(s), ",
  g.relationCount, " relation run(s)"

var f = openSeismic("SEG Spec/exampleFiles/63.sgd", keys = true)
doAssert f.traceKeys(0).rcvX.isNaN        # the SEG-D 2.0 headers have no coordinates
let changed = f.applySurvey(g, overwrite = true)
let k = f.traceKeys(0)
echo changed, " trace(s) joined: receiver ", k.rcvLine, "/", k.rcvPoint, " at (", k.rcvX,
  ", ", k.rcvY, "), offset ", round(k.offset, 1)
doAssert changed == 1 and k.rcvX == 500100 and k.srcPoint == 205
```

- Line names that are not numbers (SPS 1.0, P1) are mapped with `g.mapLine(name, number)`,
  or by their trailing digits with `g.trailingDigits = true`.
- `g.multiComponent` makes X records with a channel increment cover consecutive component
  channels; `g.tape` restricts relations to one field tape.
- A host with its own coordinate database can fill the table directly:
  `g.addSource(line, point, index, x, y, z)` and `g.addReceiver(...)`.
- `readSps`/`writeSps` and `readP1`/`writeP1` read and write the survey files themselves
  (column-exact, unchanged records byte for byte, Rev 1.0 ↔ 2.1).

## Write the geometry into the file

Once the keys are joined, three calls persist them. Each is an explicit write; all of them
first let you see what would change. In place, `openEditor(f)` maps the open file read-write
and keeps its index, joined keys included, so `writeGeometry()` writes them without opening
or walking the file again (`move f` at a module's top level, where `f` is a global).

```nim
import std/os
import parseSEG

writeFile("line.sps", """H00 SPS format version number   SPS 2.1;
R     10.00    101.00  1G1                     500100.0 6000000.0  12.5 18213250
S     20.00    205.00  1V6                     500000.0 6000400.0  10.0 19001150
XT1          6311     20.00    205.001    1    11     10.00    101.00    101.001
""")
var g = initSurveyGeometry()
g.addSps("line.sps")

# 1. In place, journaled and undoable: same-size header fields only.
copyFile("SEG Spec/exampleFiles/63.sgd", "shot.sgd")
var f = openSeismic("shot.sgd", keys = true)
discard f.applySurvey(g, overwrite = true)
var report: DiagLog
let plan = f.geometryChanges(GeometryFields(), report)   # a dry run: nothing is written
echo "would change ", plan                # traces per kind, values with no slot
for d in report: echo "  ", d.msg
var ed = openEditor(move f)               # takes over the open file and its joined keys
let done = ed.writeGeometry()
ed.close()
doAssert done.receiverStations == 1
var check = openSeismic("shot.sgd", keys = true)
doAssert check.traceKeys(0).rcvPoint == 101
doAssert rollbackJournal("shot.sgd", "shot.sgd.edits.nif").len == 0   # undo, if wanted

# 2. Into a copy in the same standard.
let copied = copyWithGeometry("SEG Spec/exampleFiles/63.sgd", "shot_geo.sgd", g,
  overwrite = true)
doAssert not copied.log.hasErrors and copied.changes.receiverStations == 1

# 3. Converted to SEG-Y, which has coordinate fields for everything.
let convLog = convertWithGeometry("SEG Spec/exampleFiles/63.sgd", "shot_geo.sgy", g,
  overwrite = true)
doAssert not convLog.isFatal
var y = openSeismic("shot_geo.sgy", keys = true)
doAssert y.traceKeys(0).rcvX == 500100
```

Where the values go: SEG-Y through the file's layout (source, group and CDP coordinates with
a coordinate scalar chosen to keep the precision in 4 bytes, elevations, offset, shotpoint,
the Ext1 copies in use); SEG-D Rev 1/2 only the THE#1 receiver line, point and index (2.x
trace headers have no coordinate fields: that is what `unwritable` counts); SEG-D Rev 3 the
THE#1 fields and the Position and Source Description blocks the traces already have. SEG-2
is refused for now. `GeometryFields` selects which values to write (`sourceXy`,
`receiverXy`, `elevations`, `midpoints`, `offsets`, `stations`; all by default).
