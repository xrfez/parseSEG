## SEG-D Rev 1 / 2.x writer: emits records read by `segd/reader` (or built in
## memory) to any `RecordSink`.
##
## Device structures (spec note `segd_rev2_0.md` §2.2):
## - RECORD (the default, and every disk file without a FIXREC label): the
##   record headers are one block, each trace is a block, the general trailer
##   is a block. Disk sinks concatenate them.
## - FIXREC (a label with `structure = FIXREC` and a block size): the record
##   is cut into blocks of exactly that size, the last one zero-padded.
##
## Header blocks keep the bytes they were read from and re-encode only edited
## fields, so a stream read and written back is byte-identical.
##
## Validation: output the reader could not decode as intended (counts that
## disagree with the blocks present, a trace whose size or extension count
## disagrees with its headers, an undefined format) is refused with
## `SegFormatError` unless `lenient`; then it is logged as a warning.

import std/math
import ../common/[errors, diagnostics]
import ../io/records
import ./[headers, samples, reader]

type
  SegdWriteOptions* = object
    lenient*: bool        ## Log problems instead of refusing to write.
    tapeMarkPerRecord*: bool ## Write a tape mark after each record (tape only).

  SegdWriter* = object
    ## Writer state; create with `openSegdWriter`.
    sink: RecordSink
    opts: SegdWriteOptions
    fixedBlock: int       ## FIXREC block size, 0 for RECORD.
    pending: seq[byte]    ## FIXREC: bytes not yet forming a whole block.
    record: SegdRecord
    inRecord: bool
    tracesWritten: int
    records: int
    lastWasMark: bool
    log*: DiagLog

proc problem(w: var SegdWriter, msg: string, field = "", trace = -1) =
  let loc = Location(file: w.sink.name, record: w.records, trace: trace, field: field)
  if w.opts.lenient:
    w.log.report(sevWarning, dcValidation, msg, loc = loc)
  else:
    w.log.report(sevError, dcValidation, msg, loc = loc)
    raiseFormat("refusing to write SEG-D the reader would misread: " & msg)

proc emit(w: var SegdWriter, data: openArray[byte]) =
  # One logical block: a record of its own (RECORD) or part of fixed blocks.
  if w.fixedBlock == 0:
    w.sink.writeRecord(data)
  else:
    w.pending.add data
    var i = 0
    while w.pending.len - i >= w.fixedBlock:
      w.sink.writeRecord(w.pending.toOpenArray(i, i + w.fixedBlock - 1))
      i += w.fixedBlock
    if i > 0: w.pending = w.pending[i..^1]
  w.lastWasMark = false

proc openSegdWriter*(sink: RecordSink, opts = SegdWriteOptions(), hasLabel = false,
    label = SegdStorageUnitLabel()): SegdWriter =
  ## Starts a SEG-D stream; with `hasLabel`, writes the storage unit label
  ## first (its own block; padded to the block size for FIXREC).
  result = SegdWriter(sink: sink, opts: opts)
  if hasLabel:
    if label.isFixedRecord:
      if label.maxBlockSize <= 0:
        raiseFormat("a FIXREC label needs a block size")
      result.fixedBlock = int(label.maxBlockSize)
      var blk = newSeq[byte](result.fixedBlock)
      for i in 0..127: blk[i] = label.raw[i]
      sink.writeRecord(blk)
    else:
      sink.writeRecord(label.raw)

proc checkRecord(w: var SegdWriter, rec: SegdRecord) =
  let g1 = rec.gh1
  let nGh = g1.generalHeaderCount
  if (nGh >= 2) != rec.hasGh2:
    w.problem("General Header #1 announces " & $nGh & " general headers, but General " &
      "Header #2 is " & (if rec.hasGh2: "present" else: "missing"), "gh1.additionalGhBlocks")
  if rec.sourceHeaders.len != max(0, nGh - 2):
    w.problem("General Header #1 announces " & $(nGh - 2) & " headers after #2, " &
      $rec.sourceHeaders.len & " are present", "gh1.additionalGhBlocks")
  let nST = g1.scanTypesPerRecord
  let nCS = if rec.hasGh2: channelSetsPerScanType(g1, rec.gh2) else: g1.channelSetsPerScanType
  let nSK = g1.skewBlocks
  let nEC = if rec.hasGh2: extendedHeaderBlocks(g1, rec.gh2) else: g1.extendedHeaderBlocks
  let nEX = if rec.hasGh2: externalHeaderBlocks(g1, rec.gh2) else: g1.externalHeaderBlocks
  if rec.scanTypes.len != nST:
    w.problem("General Header #1 announces " & $nST & " scan types, " & $rec.scanTypes.len &
      " are present", "gh1.scanTypesPerRecord")
  for i, s in rec.scanTypes:
    if s.descriptors.len != nCS:
      w.problem("scan type " & $(i + 1) & " has " & $s.descriptors.len &
        " channel set descriptors, " & $nCS & " announced", "gh1.channelSetsPerScanType")
    if s.skew.len != 32 * nSK:
      w.problem("scan type " & $(i + 1) & " has " & $s.skew.len & " skew bytes, " &
        $(32 * nSK) & " announced", "gh1.skewBlocks")
  if rec.extended.len != 32 * nEC:
    w.problem("the extended header has " & $rec.extended.len & " bytes, " & $(32 * nEC) &
      " announced", "gh1.extendedHeaderBlocks")
  if rec.external.len != 32 * nEX:
    w.problem("the external header has " & $rec.external.len & " bytes, " & $(32 * nEX) &
      " announced", "gh1.externalHeaderBlocks")
  var f: SegdSampleFormat
  if not rec.formatKnown or not toSegdFormat(g1.formatCode, f) or f != rec.format:
    w.problem("format code " & $g1.formatCode & " is undefined or does not match the " &
      "record's sample format", "gh1.formatCode")
  if rec.revision.major >= 3:
    w.problem("Rev 3 records use another layout and are not written by this writer",
      "gh2.revision")

proc writeRecordHeaders*(w: var SegdWriter, rec: SegdRecord) =
  ## Validates `rec` and writes its general headers, scan type headers,
  ## extended and external headers. Then write its traces and call
  ## `endRecord`.
  doAssert not w.inRecord, "call endRecord before starting another record"
  w.checkRecord(rec)
  var hdr: seq[byte]
  hdr.add rec.gh1.encoded
  if rec.hasGh2: hdr.add rec.gh2.encoded
  for g in rec.sourceHeaders: hdr.add g.encoded
  for s in rec.scanTypes:
    for c in s.descriptors: hdr.add c.encoded
    hdr.add s.skew
  hdr.add rec.extended
  hdr.add rec.external
  w.emit(hdr)
  w.record = rec
  w.inRecord = true
  w.tracesWritten = 0

proc checkTrace(w: var SegdWriter, t: SegdTrace) =
  let the = int(t.header.traceHeaderExtensions)
  let have = (if t.hasExt1: 1 else: 0) + t.extensions.len div 32
  if t.extensions.len mod 32 != 0 or have != the or (not t.hasExt1 and t.extensions.len > 0):
    w.problem("the trace header announces " & $the & " extensions, the trace carries " &
      $have & " (" & $t.extensions.len & " extra bytes)", "trace.traceHeaderExtensions", t.index)
  var st, cs: int
  findChannelSet(w.record, t.header, st, cs)
  var declared = -1
  if t.hasExt1:
    declared = int(t.ext1.samplesPerTrace)
  elif cs >= 0:
    let c = w.record.scanTypes[st].descriptors[cs]
    let si = c.sampleIntervalMs(w.record.gh1)
    if si > 0: declared = int(round((c.endTimeMs - c.startTimeMs) / si))
  if declared != t.numSamples:
    w.problem("the headers give " & $declared & " samples, the trace has " & $t.numSamples,
      "trace.numSamples", t.index)
  if t.samples.len != dataBytes(w.record.format, t.numSamples):
    w.problem("the trace has " & $t.samples.len & " sample bytes, " &
      $dataBytes(w.record.format, t.numSamples) & " expected", "trace.samples", t.index)

proc writeTrace*(w: var SegdWriter, t: SegdTrace) =
  ## Validates and writes one trace of the current record.
  doAssert w.inRecord, "call writeRecordHeaders first"
  w.checkTrace(t)
  var b: seq[byte]
  b.add t.header.encoded
  if t.hasExt1: b.add t.ext1.encoded
  b.add t.extensions
  b.add t.samples
  w.emit(b)
  inc w.tracesWritten

proc endRecord*(w: var SegdWriter, trailer: openArray[SegdTrailerBlock] = []) =
  ## Finishes the record: checks the trace count, writes the general trailer
  ## blocks (`trailer`, or the record's own when empty), pads a FIXREC block
  ## and writes a tape mark if `tapeMarkPerRecord`.
  doAssert w.inRecord, "no record in progress"
  if w.tracesWritten != w.record.traceCount:
    w.problem("the channel set descriptors announce " & $w.record.traceCount & " traces, " &
      $w.tracesWritten & " were written", "csd.channelCount")
  let blocks = if trailer.len > 0: @trailer else: w.record.trailer
  let nGT = if w.record.hasGh2: int(w.record.gh2.generalTrailerBlocks) else: 0
  if blocks.len != nGT:
    w.problem("General Header #2 announces " & $nGT & " trailer blocks, " & $blocks.len &
      " are present", "gh2.generalTrailerBlocks")
  if blocks.len > 0:
    var b: seq[byte]
    for t in blocks: b.add t.encoded
    w.emit(b)
  if w.fixedBlock > 0 and w.pending.len > 0:
    w.pending.setLen w.fixedBlock
    w.sink.writeRecord(w.pending)
    w.pending.setLen 0
  if w.opts.tapeMarkPerRecord:
    w.sink.writeTapeMark()
    w.lastWasMark = true
  w.inRecord = false
  inc w.records

proc close*(w: var SegdWriter) =
  ## Marks the end of data: two tape marks (one if a record just ended with
  ## one). Disk sinks ignore tape marks. The sink stays open.
  doAssert not w.inRecord, "call endRecord before close"
  w.sink.writeTapeMark(if w.lastWasMark: 1 else: 2)

proc writeSegd*(sink: RecordSink, d: SegdData, opts = SegdWriteOptions()): DiagLog =
  ## Writes a whole in-memory stream (see `readSegd`); returns the writer log.
  var w = openSegdWriter(sink, opts, d.hasLabel, d.label)
  for r in d.records:
    w.writeRecordHeaders(r.record)
    for t in r.traces: w.writeTrace(t)
    w.endRecord()
  w.close()
  result = w.log
