## SEG-D Rev 1 / 2.x writer: emits records read by `segd/reader` (or built in
## memory) to any `RecordSink`.
##
## Device structures (spec note `segd_rev2_0.md` §2.2):
## - RECORD (the default, and every disk file without a FIXREC label): the
##   record headers are one block, each trace is a block, the general trailer
##   is a block. Disk sinks concatenate them.
## - FIXREC (a label with `structure = FIXREC` and a block size): the record
##   is cut into blocks of exactly that size, the last one zero-padded. A trace
##   that fits in one block never crosses a block boundary (the rest of the
##   block is zero-padded instead), per Rev 2.0 "block boundaries may not
##   occur within a trace"; readers skip such padding.
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

const MaxFixedBlock* = 256 shl 20 ## Largest FIXREC block size the writer accepts.

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
    bytesInRecord: int64  ## Rev 3: bytes of the record written so far (no padding).
    log*: DiagLog

proc problem(w: var SegdWriter, msg: string, field = "", trace = -1) =
  let loc = Location(file: w.sink.name, record: w.records, trace: trace, field: field)
  if w.opts.lenient:
    w.log.report(sevWarning, dcValidation, msg, loc = loc)
  else:
    w.log.report(sevError, dcValidation, msg, loc = loc)
    raiseFormat("refusing to write SEG-D the reader would misread: " & msg)

proc padToBlock(w: var SegdWriter) =
  # FIXREC: zero-fill the rest of the current block.
  if w.fixedBlock > 0 and w.pending.len > 0:
    w.pending.setLen w.fixedBlock
    w.sink.writeRecord(w.pending)
    w.pending.setLen 0

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
    let raw = label.encoded # from the fields, so FIXREC padding and the label agree
    let written = decodeLabel(raw)
    if not isStorageUnitLabel(raw):
      raiseFormat("the storage unit label revision '" & written.revision &
        "' is not SDn.n, so readers would not recognize the label")
    if written.isFixedRecord:
      if written.maxBlockSize < 128 or written.maxBlockSize > MaxFixedBlock:
        raiseFormat("a FIXREC label needs a block size of 128.." & $MaxFixedBlock &
          " bytes, not " & $written.maxBlockSize)
      result.fixedBlock = int(written.maxBlockSize)
      var blk = newSeq[byte](result.fixedBlock)
      for i in 0..127: blk[i] = raw[i]
      sink.writeRecord(blk)
    else:
      sink.writeRecord(raw)

proc rev3HeaderBytes*(rec: SegdRecord): int64 =
  ## Bytes of a Rev 3 record's header blocks (GH#3 header size).
  var n = 3 * 32 + int64(rec.generalBlocks.len) + int64(rec.extended.len) + int64(rec.external.len)
  for s in rec.scanTypes: n += 96 * int64(s.descriptors3.len) + int64(s.skew.len)
  n

proc checkRev3Record(w: var SegdWriter, rec: SegdRecord) =
  let g1 = rec.gh1
  let g2 = rec.gh2r3
  if g2.revisionMajor < 3:
    w.problem("a Rev 3 record (isRev3) needs revision 3.x in General Header #2", "gh2.revision")
  let nGh = generalHeaderCount(g1, g2)
  if rec.generalBlocks.len mod 32 != 0 or 3 + rec.generalBlocks.len div 32 != nGh:
    w.problem("the general header announces " & $nGh & " blocks, GH#1-3 plus " &
      $(rec.generalBlocks.len div 32) & " are present", "gh1.additionalGhBlocks")
  let nST = g1.scanTypesPerRecord
  let nCS = channelSetsPerScanType(g1, g2)
  let nSK = skewBlocks(g1, g2)
  if rec.scanTypes.len != nST:
    w.problem("General Header #1 announces " & $nST & " scan types, " & $rec.scanTypes.len &
      " are present", "gh1.scanTypesPerRecord")
  for i, st in rec.scanTypes:
    if st.descriptors3.len != nCS:
      w.problem("scan type " & $(i + 1) & " has " & $st.descriptors3.len &
        " channel set descriptors, " & $nCS & " announced", "gh1.channelSetsPerScanType")
    if st.skew.len != 32 * nSK:
      w.problem("scan type " & $(i + 1) & " has " & $st.skew.len & " skew bytes, " &
        $(32 * nSK) & " announced", "gh1.skewBlocks")
  if rec.extended.len != 32 * extendedHeaderBlocks(g1, g2):
    w.problem("the extended header has " & $rec.extended.len & " bytes, " &
      $(32 * extendedHeaderBlocks(g1, g2)) & " announced", "gh1.extendedHeaderBlocks")
  if rec.external.len != 32 * externalHeaderBlocks(g1, g2):
    w.problem("the external header has " & $rec.external.len & " bytes, " &
      $(32 * externalHeaderBlocks(g1, g2)) & " announced", "gh1.externalHeaderBlocks")
  var f: SegdSampleFormat
  if not rec.formatKnown or not toSegdFormat(g1.formatCode, f) or f != rec.format:
    w.problem("format code " & $g1.formatCode & " is undefined or does not match the " &
      "record's sample format", "gh1.formatCode")
  if rec.gh3.headerSize != 0 and int64(rec.gh3.headerSize) != rev3HeaderBytes(rec):
    w.problem("General Header #3 header size is " & $rec.gh3.headerSize & ", the header " &
      "blocks take " & $rev3HeaderBytes(rec) & " bytes", "gh3.headerSize")
  if rec.trailerBytes.len mod 32 != 0:
    w.problem("the general trailer is not whole 32-byte blocks", "trailer")
  if g2.generalTrailerBlocks != 0xFFFF_FFFF'u32 and
      int64(g2.generalTrailerBlocks) * 32 != rec.trailerBytes.len:
    w.problem("General Header #2 announces " & $g2.generalTrailerBlocks & " trailer blocks, " &
      $(rec.trailerBytes.len div 32) & " are present", "gh2.generalTrailerBlocks")
  if isStorageUnitLabel(rec.gh1.encoded):
    w.problem("General Header #1 bytes 5-9 read like a storage unit label ('SDn.n'), so " &
      "readers would take the record for a label", "gh1.generalConstants")

proc checkRecord(w: var SegdWriter, rec: SegdRecord) =
  if rec.isRev3:
    w.checkRev3Record(rec)
    return
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
  if rec.hasGh2 and rec.gh2.revisionMajor >= 3:
    w.problem("Rev 3 records use another layout and are not written by this writer",
      "gh2.revision")
  if isStorageUnitLabel(rec.gh1.encoded):
    w.problem("General Header #1 bytes 5-9 read like a storage unit label ('SDn.n'), so " &
      "readers would take the record for a label", "gh1.generalConstants")

proc writeRecordHeaders*(w: var SegdWriter, rec: SegdRecord) =
  ## Validates `rec` and writes its general headers, scan type headers,
  ## extended and external headers. Then write its traces and call
  ## `endRecord`.
  doAssert not w.inRecord, "call endRecord before starting another record"
  w.checkRecord(rec)
  if rec.isRev3:
    var hdr: seq[byte]
    hdr.add rec.gh1.encoded
    hdr.add rec.gh2r3.encoded
    hdr.add rec.gh3.encoded
    hdr.add rec.generalBlocks
    for s in rec.scanTypes:
      for c in s.descriptors3: hdr.add c.encoded
      hdr.add s.skew
    hdr.add rec.extended
    hdr.add rec.external
    w.emit(hdr)
    w.bytesInRecord = hdr.len
    w.record = rec
    w.record.traceCount = 0
    for st in rec.scanTypes:
      for c in st.descriptors3: w.record.traceCount += int(c.channelsInSet)
    if w.record.traceCount > 0: w.padToBlock() # the first trace starts a device block
    w.inRecord = true
    w.tracesWritten = 0
    return
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
  # The trace count the reader will expect, from the descriptors as written.
  w.record.traceCount = 0
  for st in rec.scanTypes:
    for c in st.descriptors:
      if c.channelCount > 0: w.record.traceCount += c.channelCount
  w.inRecord = true
  w.tracesWritten = 0

proc checkTrace(w: var SegdWriter, t: SegdTrace) =
  if w.record.isRev3:
    let the = int(t.header.traceHeaderExtensions)
    let have = (if t.hasExt1: 1 else: 0) + t.extensions.len div 32
    if t.extensions.len mod 32 != 0 or have != the or (not t.hasExt1 and t.extensions.len > 0):
      w.problem("the trace header announces " & $the & " extensions, the trace carries " &
        $have, "trace.traceHeaderExtensions", t.index)
    var st, cs: int
    findChannelSet(w.record, t.header, st, cs)
    if cs < 0:
      w.problem("the trace names scan type " & $t.header.scanTypeNumber & ", channel set " &
        $t.header.channelSetNumber & ", which no descriptor has", "trace.channelSetNumber",
        t.index)
    let declared = if t.hasExt1: int(t.ext1r3.numSamples)
                   elif cs >= 0: int(w.record.scanTypes[st].descriptors3[cs].numSamples)
                   else: -1
    if declared != t.numSamples:
      w.problem("the headers give " & $declared & " samples, the trace has " & $t.numSamples,
        "trace.numSamples", t.index)
    if t.samples.len != dataBytes(w.record.format, t.numSamples):
      w.problem("the trace has " & $t.samples.len & " sample bytes, " &
        $dataBytes(w.record.format, t.numSamples) & " expected", "trace.samples", t.index)
    return
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
  # FIXREC (owner decision): a trace does not cross a block boundary when it
  # fits in one block; the rest of the current block is zero-padded instead.
  b.add t.header.encoded
  if t.hasExt1:
    if w.record.isRev3: b.add t.ext1r3.encoded else: b.add t.ext1.encoded
  b.add t.extensions
  b.add t.samples
  if w.fixedBlock > 0 and w.pending.len > 0 and w.pending.len + b.len > w.fixedBlock and
      b.len <= w.fixedBlock:
    w.padToBlock()
  w.emit(b)
  w.bytesInRecord += b.len
  inc w.tracesWritten

proc endRev2Record(w: var SegdWriter, trailer: openArray[SegdTrailerBlock]) =
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

proc endRev3Record(w: var SegdWriter) =
  if w.tracesWritten != w.record.traceCount:
    w.problem("the channel set descriptors announce " & $w.record.traceCount & " traces, " &
      $w.tracesWritten & " were written", "csd.channelsInSet")
  let g3 = w.record.gh3
  if g3.dataSize != 0 and int64(g3.dataSize) != w.bytesInRecord:
    w.problem("General Header #3 data size is " & $g3.dataSize & ", " & $w.bytesInRecord &
      " bytes of headers and traces were written", "gh3.dataSize")
  let total = w.bytesInRecord + w.record.trailerBytes.len
  if g3.recordSize != 0 and int64(g3.recordSize) != total:
    w.problem("General Header #3 record size is " & $g3.recordSize & ", the record has " &
      $total & " bytes", "gh3.recordSize")
  if w.record.trailerBytes.len > 0:
    w.padToBlock() # the first trailer block starts a device block
    w.emit(w.record.trailerBytes)

proc endRecord*(w: var SegdWriter, trailer: openArray[SegdTrailerBlock] = []) =
  ## Finishes the record: checks the trace count (and, for Rev 3, the GH#3
  ## sizes), writes the general trailer (Rev 1/2: `trailer`, or the record's
  ## own when empty; Rev 3: `record.trailerBytes`), pads a FIXREC block and
  ## writes a tape mark if `tapeMarkPerRecord`.
  doAssert w.inRecord, "no record in progress"
  if w.record.isRev3: w.endRev3Record() else: w.endRev2Record(trailer)
  w.padToBlock()
  if w.opts.tapeMarkPerRecord:
    w.sink.writeTapeMark()
    w.lastWasMark = true
  w.inRecord = false
  inc w.records

proc computeRev3Sizes*(rec: var SegdRecord, traces: openArray[SegdTrace]) =
  ## Sets a Rev 3 record's GH#3 header, data and record sizes and its GH#2
  ## trailer block count from its blocks and `traces` (for records built in
  ## memory).
  rec.gh3.headerSize = uint32(rev3HeaderBytes(rec))
  var data = rev3HeaderBytes(rec)
  for t in traces:
    data += SegdTraceHeaderSize + 32 * int64(t.header.traceHeaderExtensions) + t.samples.len
  rec.gh3.dataSize = uint64(data)
  rec.gh3.recordSize = uint64(data + rec.trailerBytes.len)
  rec.gh2r3.generalTrailerBlocks = uint32(rec.trailerBytes.len div 32)

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
