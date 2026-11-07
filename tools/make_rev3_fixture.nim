## Builds the committed SEG-D Rev 3.0 fixture from the local 65 MB INOVA
## sample (task 5.4): every header block as recorded, the 3 auxiliary traces
## and the first 2 seismic traces in their original physical order, with
## CS4's trace count and the GH#3 sizes updated.
##
## nim c -r --path:src tools/make_rev3_fixture.nim

import std/os
import parseSEGD/io/diskio
import parseSEGD/segd/[reader, writer]

const
  dir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
  src = dir / "00000151_12900_11300.sgd"
  dst = dir / "inova_rev30_5traces.sgd"

var d = readSegd(src)
doAssert d.diagnostics.len == 0 and d.records.len == 1
var rd = d.records[0]
var keep: seq[SegdTrace]
var seismic = 0
for t in rd.traces:
  let c = rd.record.scanTypes[t.scanType].descriptors3[t.channelSet]
  if c.channelType != 0x10:
    keep.add t
  elif seismic < 2:
    keep.add t
    inc seismic
for i in 0..<keep.len: keep[i].index = i
rd.record.scanTypes[0].descriptors3[3].channelsInSet = 2
computeRev3Sizes(rd.record, keep)
rd.traces = keep
d.records = @[rd]
let sink = openDiskSink(dst)
let log = writeSegd(sink, d)
sink.close()
doAssert log.len == 0
echo "wrote ", dst, " (", getFileSize(dst), " bytes, ", keep.len, " traces)"
