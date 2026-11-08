## Demultiplexed copies of SEG-D streams with multiplexed records (Rev 0 and
## Rev 1 format codes 0015 ... 0058).
##
## `demultiplexSegd` reads a stream with the reader, which demultiplexes
## multiplexed records as it reads them (`segd/reader`, `segd/mux`), and
## writes it as a demultiplexed SEG-D stream that any SEG-D reader can index:
## every header is kept, except that a multiplexed record's format code
## becomes the demultiplexed twin (0015 → 8015, ...) and its multiplexed
## fields (GH#1 bytes per scan, S/B, S/BX) become 0. `openSeismic` uses it
## for multiplexed files (a temporary copy); the original is never changed.
##
## The trace length of a demultiplexed Rev 0-2 trace without extensions
## comes from its channel set window, `(end − start) / sample interval`. When
## the scans give another length (the spec leaves open whether the window's
## end is inclusive), the copy's traces of that channel set carry a Trace
## Header Extension #1 with the sample count, and its descriptor announces
## it (an info diagnostic says which).

import std/[math, sets]
import ../common/diagnostics
import ../io/[records, diskio]
import ./[reader, writer]

func demultiplexedRecord*(rec: SegdRecord): SegdRecord =
  ## The headers of `rec` as a demultiplexed record: GH#1's format code is
  ## the demultiplexed twin and its bytes per scan, S/B and S/BX are 0.
  ## `rec` itself when it is not multiplexed.
  result = rec
  if rec.multiplexed:
    result.multiplexed = false
    result.gh1.formatCode = ord(rec.format.get)
    result.gh1.unused20 = [0'u8, 0, 0]
    result.gh1.unused24L = 0
    result.gh1.unused25 = 0

func windowSamples(rec: SegdRecord, c: SegdChannelSetDescriptor): int =
  # The trace length a reader gives a trace without extensions; -1 if none.
  let si = c.sampleIntervalMs(rec.gh1)
  if si > 0: int(round((c.endTimeMs - c.startTimeMs) / si)) else: -1

proc fitTraceLengths(rec: var SegdRecord, traces: var seq[SegdTrace], log: var DiagLog,
    loc: Location) =
  # Traces whose scans give another length than their channel set window
  # get Trace Header Extension #1 with the sample count.
  var fitted: HashSet[(int, int)]
  for t in traces.mitems:
    template c: untyped = rec.scanTypes[t.scanType].descriptors[t.channelSet]
    if t.channelSet >= 0 and windowSamples(rec, c) != t.numSamples:
      if not fitted.containsOrIncl((t.scanType, t.channelSet)):
        c.traceHeaderExtensions = 1
        var l = loc
        l.channelSet = t.channelSet
        log.report(sevInfo, dcMultiplexed, "scan type " & $(t.scanType + 1) & ", channel set " &
          $(t.channelSet + 1) & ": the scans give " & $t.numSamples & " samples, the window " &
          $windowSamples(rec, c) & "; the copy's traces carry Trace Header Extension #1 " &
          "with the sample count", loc = l)
      t.header.traceHeaderExtensions = 1
      t.ext1 = some(SegdTraceHeaderExt1(samplesPerTrace: uint32(t.numSamples)))

proc demultiplexSegd*(src: RecordSource, sink: RecordSink,
    twosComplement8015 = false): DiagLog =
  ## Copies the SEG-D stream at the current position of `src` to `sink`,
  ## demultiplexing its multiplexed records (see the module docs);
  ## demultiplexed records are copied unchanged. A multiplexed record is held
  ## in memory while it is copied. Returns the reader's diagnostics, then the
  ## copy's: a record the writer refuses (as it would refuse to write it from
  ## memory) ends the copy with an error entry.
  ## `twosComplement8015` reads 0015 words as two's complement (the copy then
  ## needs the same option for 8015).
  var r = openSegd(src, twosComplement8015)
  var w = openSegdWriter(sink, label = r.label)
  var copyLog: DiagLog
  var broken = false
  while not broken and r.nextRecord():
    let loc = Location(file: sink.name, record: r.record.index)
    var t: SegdTrace
    if r.record.multiplexed:
      var traces: seq[SegdTrace]
      while r.readTrace(t): traces.add t
      var rec = demultiplexedRecord(r.record)
      fitTraceLengths(rec, traces, copyLog, loc)
      let ok = copyLog.tryRecord(loc):
        w.writeRecordHeaders(rec)
        for x in traces: w.writeTrace(x)
        w.endRecord(rec.trailer)
      broken = not ok
    else:
      let ok = copyLog.tryRecord(loc):
        w.writeRecordHeaders(r.record)
        while r.readTrace(t): w.writeTrace(t)
        if r.record.isRev3:
          w.setRev3Trailer(r.record.trailerRev3)
          w.endRecord()
        else:
          w.endRecord(r.record.trailer)
      broken = not ok
  if not broken: w.close()
  result = r.log
  result.add copyLog # the writer's refusals, which `w.log` holds too

proc demultiplexSegd*(srcPath, dstPath: string, twosComplement8015 = false): DiagLog =
  ## Writes a demultiplexed copy of the SEG-D disk file `srcPath` to
  ## `dstPath` (see above). Raises `IOError`/`OSError` if either file cannot
  ## be opened.
  let src = openDiskSource(srcPath)
  try:
    let sink = openDiskSink(dstPath)
    try:
      result = demultiplexSegd(src, sink, twosComplement8015)
    finally:
      sink.close()
  finally:
    src.close()
