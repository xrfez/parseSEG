## SEG-D writer for every revision: emits records read by `segd/reader` (or
## built in memory) to any `RecordSink`, in the record's own layout (Rev 0-2
## or Rev 3).
##
## Device structures (spec note `segd_rev2_0.md` §2.2):
## - RECORD (the default, and every disk file without a FIXREC label): the
##   record headers are one block, each trace is a block, the general trailer
##   is a block. Disk sinks concatenate them.
## - FIXREC (a label with `structure = FIXREC` and a block size): the record
##   is cut into blocks of exactly that size, the last one zero-padded. A trace
##   that fits in one block never crosses a block boundary (the rest of the
##   block is zero-padded instead), per Rev 2.0 "block boundaries may not
##   occur within a trace"; readers skip such padding. Rev 3 starts the first
##   trace and the trailer on a block boundary.
##
## Header blocks keep the bytes they were read from and re-encode only edited
## fields, so a stream read and written back is byte-identical.
##
## Validation: output the reader could not decode as intended (counts that
## disagree with the blocks present, a trace whose size or extension count
## disagrees with its headers, an undefined format) is refused with
## `SegFormatError` unless `lenient`; then it is logged as a warning. Calls
## out of order (a trace without a record, a record inside a record, ...)
## raise `ValueError`.

import std/math
import ../common/[errors, diagnostics, endians]
import ../io/records
import ./[samples, reader]

const MaxFixedBlock* = 256 shl 20 ## Largest FIXREC block size the writer accepts.

type
  SegdWriteOptions* = object
    ## Options of `openSegdWriter`.
    lenient*: bool        ## Log problems instead of refusing to write.
    tapeMarkPerRecord*: bool ## Write a tape mark after each record (tape only).

  SegdWriter* = object
    ## Writer state; create with `openSegdWriter`.
    sink: RecordSink
    opts: SegdWriteOptions
    fixedBlock: int       ## FIXREC block size, 0 for RECORD.
    pending: seq[byte]    ## FIXREC: bytes not yet forming a whole block.
    buf: seq[byte]        ## One trace's bytes, reused.
    record: SegdRecord
    inRecord: bool
    tracesWritten: int
    records: int
    lastWasMark: bool
    bytesInRecord: int64  ## Bytes of the record written so far (no padding).
    log: DiagLog

func log*(w: SegdWriter): lent DiagLog {.inline.} =
  ## The problems logged so far (all of them warnings unless a write was refused).
  w.log

proc problem(w: var SegdWriter, msg: string, field = "", trace = -1) =
  let loc = Location(file: w.sink.name, record: w.records, trace: trace, field: field)
  if w.opts.lenient:
    w.log.report(sevWarning, dcValidation, msg, loc = loc)
  else:
    w.log.report(sevError, dcValidation, msg, loc = loc)
    raiseFormat("refusing to write SEG-D the reader would misread: " & msg)

proc misuse(msg: string) {.noinline, noreturn.} =
  # A call out of order: the caller's error.
  raise newException(ValueError, msg)

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
    if i > 0:
      # Keep the rest at the front, in the same buffer.
      let rest = w.pending.len - i
      if rest > 0: moveMem(addr w.pending[0], addr w.pending[i], rest)
      w.pending.setLen rest
  w.lastWasMark = false

proc openSegdWriter*(sink: RecordSink, opts = SegdWriteOptions(),
    label = none(SegdStorageUnitLabel)): SegdWriter =
  ## Starts a SEG-D stream; with a `label`, writes the storage unit label
  ## first (its own block; padded to the block size for FIXREC). Raises
  ## `SegFormatError` for a label readers would not recognize.
  result = SegdWriter(sink: sink, opts: opts)
  if label.isSome:
    let raw = label.get.encoded # from the fields, so FIXREC padding and the label agree
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

func trailerGroupsWalk(b: openArray[byte]): bool =
  # True when `b` is exactly a sequence of (description block, data) groups
  # that a reader can walk.
  var i = 0
  while i < b.len:
    if i + SegdBlockSize > b.len or b[i + 31] != BlockTypeTrailerDescription or
        b[i + 1] notin {1'u8, 2} or b[i + 2] != 0 or b[i + 3] != 0:
      return false
    i += SegdBlockSize + SegdBlockSize * int(beU32(b, i + 4))
  i == b.len

func headerRevision(rec: SegdRecord): SegdRevision =
  # The revision General Header #2 gives as written (0.0 without one).
  case rec.layout
  of slRev2:
    if rec.gh2.isSome: SegdRevision(major: rec.gh2.get.revisionMajor,
      minor: rec.gh2.get.revisionMinor)
    else: SegdRevision()
  of slRev3: SegdRevision(major: rec.gh2Rev3.revisionMajor, minor: rec.gh2Rev3.revisionMinor)

proc checkGeneralHeaders(w: var SegdWriter, rec: SegdRecord) =
  # The general header blocks GH#1 announces are present.
  let nGh = rec.generalHeaderCount
  case rec.layout
  of slRev2:
    if (nGh >= 2) != rec.gh2.isSome:
      w.problem("General Header #1 announces " & $nGh & " general headers, but General " &
        "Header #2 is " & (if rec.gh2.isSome: "present" else: "missing"),
        "gh1.additionalGhBlocks")
    if rec.sourceHeaders.len != max(0, nGh - 2):
      w.problem("General Header #1 announces " & $(nGh - 2) & " headers after #2, " &
        $rec.sourceHeaders.len & " are present", "gh1.additionalGhBlocks")
    if rec.gh2.isSome and rec.gh2.get.revisionMajor >= 3:
      w.problem("Rev 3 records use the Rev 3 layout (slRev3), not slRev2", "gh2.revision")
  of slRev3:
    if rec.gh2Rev3.revisionMajor < 3:
      w.problem("a Rev 3 layout record (slRev3) needs revision 3.x in General Header #2",
        "gh2.revision")
    let blocks = rec.generalBlocks.len div SegdBlockSize
    if rec.generalBlocks.len mod SegdBlockSize != 0 or 3 + blocks != nGh:
      w.problem("the general header announces " & $nGh & " blocks, GH#1-3 plus " &
        $blocks & " are present", "gh1.additionalGhBlocks")

proc checkRev3Sizes(w: var SegdWriter, rec: SegdRecord) =
  # GH#3's header size and GH#2's trailer size agree with the blocks.
  let g2 = rec.gh2Rev3
  if rec.gh3.headerSize != 0 and int64(rec.gh3.headerSize) != rec.headerBytes:
    w.problem("General Header #3 header size is " & $rec.gh3.headerSize & ", the header " &
      "blocks take " & $rec.headerBytes & " bytes", "gh3.headerSize")
  if rec.trailerRev3.len mod SegdBlockSize != 0:
    w.problem("the general trailer is not whole 32-byte blocks", "trailer")
  if g2.generalTrailerBlocks == UnknownTrailerBlocks:
    if rec.gh3.recordSize == 0 and not trailerGroupsWalk(rec.trailerRev3):
      w.problem("with the trailer block count unknown (FFFFFFFF) and no GH#3 record size, " &
        "readers find the trailer by its description blocks, but this trailer is not a " &
        "sequence of description-block groups", "gh2.generalTrailerBlocks")
  elif int64(g2.generalTrailerBlocks) * SegdBlockSize != rec.trailerRev3.len:
    w.problem("General Header #2 announces " & $g2.generalTrailerBlocks & " trailer blocks, " &
      $(rec.trailerRev3.len div SegdBlockSize) & " are present", "gh2.generalTrailerBlocks")

proc checkRecord(w: var SegdWriter, rec: SegdRecord) =
  if rec.incomplete:
    raiseFormat("the record was read with parts too large to hold in memory; it cannot " &
      "be rewritten (raise maxHeaderBytes)")
  w.checkGeneralHeaders(rec)
  let nST = rec.gh1.scanTypesPerRecord
  let nCS = rec.channelSetsPerScanType
  let nSK = rec.skewBlocks
  if rec.scanTypes.len != nST:
    w.problem("General Header #1 announces " & $nST & " scan types, " & $rec.scanTypes.len &
      " are present", "gh1.scanTypesPerRecord")
  for i, s in rec.scanTypes:
    if s.layout != rec.layout:
      w.problem("scan type " & $(i + 1) & " has the " & $s.layout & " layout, the record " &
        $rec.layout, "scanTypes")
    if s.channelSetCount != nCS:
      w.problem("scan type " & $(i + 1) & " has " & $s.channelSetCount &
        " channel set descriptors, " & $nCS & " announced", "gh1.channelSetsPerScanType")
    if s.skew.len != SegdBlockSize * nSK:
      w.problem("scan type " & $(i + 1) & " has " & $s.skew.len & " skew bytes, " &
        $(SegdBlockSize * nSK) & " announced", "gh1.skewBlocks")
  for (area, n, field) in [("extended", rec.extended.len, "gh1.extendedHeaderBlocks"),
      ("external", rec.external.len, "gh1.externalHeaderBlocks")]:
    let announced = SegdBlockSize * (if area == "extended": rec.extendedHeaderBlocks
                                     else: rec.externalHeaderBlocks)
    if n != announced:
      w.problem("the " & area & " header has " & $n & " bytes, " & $announced &
        " announced", field)
  let f = toSegdFormat(rec.gh1.formatCode)
  if rec.format.isNone or f != rec.format:
    w.problem("format code " & $rec.gh1.formatCode & " is undefined or does not match the " &
      "record's sample format", "gh1.formatCode")
  elif f.get.isLittleEndian and rec.headerRevision < SegdRevision(major: 3, minor: 1):
    w.problem("format " & $ord(f.get) & " (little-endian) needs Rev 3.1, the record says " &
      $rec.headerRevision, "gh1.formatCode")
  if rec.isRev3: w.checkRev3Sizes(rec)
  if isStorageUnitLabel(rec.gh1.encoded):
    w.problem("General Header #1 bytes 5-9 read like a storage unit label ('SDn.n'), so " &
      "readers would take the record for a label", "gh1.generalConstants")

proc writeRecordHeaders*(w: var SegdWriter, rec: SegdRecord) =
  ## Validates `rec` and writes its general headers, scan type headers,
  ## extended and external headers. Then write its traces and call
  ## `endRecord`. Raises `ValueError` while a record is in progress.
  if w.inRecord: misuse("call endRecord before starting another record")
  w.checkRecord(rec)
  var hdr: seq[byte]
  hdr.add rec.gh1.encoded
  case rec.layout
  of slRev2:
    if rec.gh2.isSome: hdr.add rec.gh2.get.encoded
    for g in rec.sourceHeaders: hdr.add g.encoded
  of slRev3:
    hdr.add rec.gh2Rev3.encoded
    hdr.add rec.gh3.encoded
    hdr.add rec.generalBlocks
  for s in rec.scanTypes:
    case s.layout
    of slRev2:
      for c in s.descriptors: hdr.add c.encoded
    of slRev3:
      for c in s.descriptorsRev3: hdr.add c.encoded
    hdr.add s.skew
  hdr.add rec.extended
  hdr.add rec.external
  w.emit(hdr)
  w.bytesInRecord = hdr.len
  w.record = rec
  # The trace count the reader will expect, from the descriptors as written.
  w.record.traceCount = rec.announcedTraces
  if rec.isRev3 and w.record.traceCount > 0:
    w.padToBlock() # the first trace starts a device block
  w.inRecord = true
  w.tracesWritten = 0

func declaredSamples(rec: SegdRecord, t: SegdTrace, cs: Option[SegdChannelSetRef]): int =
  # The sample count the reader will give the trace (`readRev2TraceRest`,
  # `readRev3TraceRest`), -1 if it finds none (also when a lenient record's
  # scan type has another layout than the trace).
  let own = case t.layout # Trace Header Extension #1's count; -1 without one
    of slRev2: (if t.ext1.isSome: int(t.ext1.get.samplesPerTrace) else: -1)
    of slRev3: (if t.ext1Rev3.isSome: int(t.ext1Rev3.get.numSamples) else: -1)
  if own > 0 or (own == 0 and t.layout == slRev3): return own
  if cs.isSome and rec.scanTypes[cs.get.scanType].layout != t.layout: return -1
  case t.layout
  of slRev2:
    # The channel set's window, (TE − TF) / SI: for a trace without THE#1,
    # and for one whose THE#1 count is 0 (then at least 0 samples).
    var window = -1
    if cs.isSome:
      template c: untyped = rec.scanTypes[cs.get.scanType].descriptors[cs.get.channelSet]
      let si = c.sampleIntervalMs(rec.gh1)
      if si > 0: window = int(round((c.endTimeMs - c.startTimeMs) / si))
    if own == 0: max(window, 0)
    elif window >= 0: window
    else: -1
  of slRev3:
    if cs.isSome: int(rec.scanTypes[cs.get.scanType].descriptorsRev3[cs.get.channelSet].numSamples)
    else: -1

proc checkTrace(w: var SegdWriter, t: SegdTrace) =
  if t.layout != w.record.layout:
    w.problem("the trace has the " & $t.layout & " layout, the record " & $w.record.layout,
      "trace", t.index)
    return
  let hasExt1 = case t.layout
    of slRev2: t.ext1.isSome
    of slRev3: t.ext1Rev3.isSome
  let the = int(t.header.traceHeaderExtensions)
  let have = ord(hasExt1) + t.extensions.len div SegdBlockSize
  if t.extensions.len mod SegdBlockSize != 0 or have != the or
      (not hasExt1 and t.extensions.len > 0):
    w.problem("the trace header announces " & $the & " extensions, the trace carries " &
      $have & " (" & $t.extensions.len & " extra bytes)", "trace.traceHeaderExtensions", t.index)
  let cs = w.record.findChannelSet(t.header)
  if cs.isNone and t.layout == slRev3:
    w.problem("the trace names scan type " & $t.header.scanTypeNumber & ", channel set " &
      $t.header.channelSetNumber & ", which no descriptor has", "trace.channelSetNumber",
      t.index)
  let declared = declaredSamples(w.record, t, cs)
  if declared != t.numSamples:
    w.problem("the headers give " & $declared & " samples, the trace has " & $t.numSamples,
      "trace.numSamples", t.index)
  if w.record.format.isNone:
    w.problem("the record's format code " & $w.record.gh1.formatCode & " is unknown, so " &
      "the trace's sample bytes cannot be checked", "gh1.formatCode", t.index)
  elif t.samples.len != dataBytes(w.record.format.get, t.numSamples):
    w.problem("the trace has " & $t.samples.len & " sample bytes, " &
      $dataBytes(w.record.format.get, t.numSamples) & " expected", "trace.samples", t.index)

proc writeTrace*(w: var SegdWriter, t: SegdTrace) =
  ## Validates and writes one trace of the current record. Raises
  ## `ValueError` without a record in progress.
  if not w.inRecord: misuse("call writeRecordHeaders first")
  w.checkTrace(t)
  # FIXREC (owner decision): a trace does not cross a block boundary when it
  # fits in one block; the rest of the current block is zero-padded instead.
  w.buf.setLen 0
  w.buf.add t.header.encoded
  case t.layout
  of slRev2:
    if t.ext1.isSome: w.buf.add t.ext1.get.encoded
  of slRev3:
    if t.ext1Rev3.isSome: w.buf.add t.ext1Rev3.get.encoded
  w.buf.add t.extensions
  w.buf.add t.samples
  let n = w.buf.len
  # A trace header never starts in a block's last 19 bytes, so readers can
  # tell padding from a header.
  if w.fixedBlock > 0 and w.pending.len > 0 and
      ((w.pending.len + n > w.fixedBlock and n <= w.fixedBlock) or
       w.fixedBlock - w.pending.len < SegdTraceHeaderSize):
    w.padToBlock()
  w.emit(w.buf)
  w.bytesInRecord += n
  inc w.tracesWritten

proc setRev3Trailer*(w: var SegdWriter, trailer: sink seq[byte]) =
  ## Rev 3: replaces the general trailer (`trailerRev3`) of the record in
  ## progress, for a trailer known only after its traces. GH#2 and GH#3 were
  ## written with the record headers, so it must have the size they announce
  ## (`endRecord` checks). Raises `ValueError` without a Rev 3 record in
  ## progress.
  if not (w.inRecord and w.record.isRev3):
    misuse("setRev3Trailer needs a Rev 3 record in progress")
  w.record.trailerRev3 = trailer

proc endRev2Record(w: var SegdWriter, trailer: openArray[SegdTrailerBlock]) =
  let nGT = if w.record.gh2.isSome: int(w.record.gh2.get.generalTrailerBlocks) else: 0
  template check(blocks: openArray[SegdTrailerBlock]) =
    if blocks.len != nGT:
      w.problem("General Header #2 announces " & $nGT & " trailer blocks, " & $blocks.len &
        " are present", "gh2.generalTrailerBlocks")
    if blocks.len > 0:
      var b: seq[byte]
      for t in blocks: b.add t.encoded
      w.emit(b)
  if trailer.len > 0: check(trailer) else: check(w.record.trailer)

proc endRev3Record(w: var SegdWriter) =
  let g3 = w.record.gh3
  if g3.dataSize != 0 and g3.dataSize != uint64(w.bytesInRecord):
    w.problem("General Header #3 data size is " & $g3.dataSize & ", " & $w.bytesInRecord &
      " bytes of headers and traces were written", "gh3.dataSize")
  let total = w.bytesInRecord + w.record.trailerRev3.len
  if g3.recordSize != 0 and g3.recordSize != uint64(total):
    w.problem("General Header #3 record size is " & $g3.recordSize & ", the record has " &
      $total & " bytes", "gh3.recordSize")
  if w.record.trailerRev3.len > 0:
    w.padToBlock() # the first trailer block starts a device block
    w.emit(w.record.trailerRev3)

proc endRecord*(w: var SegdWriter, trailer: openArray[SegdTrailerBlock] = []) =
  ## Finishes the record: checks the trace count (and, for Rev 3, the GH#3
  ## sizes), writes the general trailer (Rev 0-2: `trailer`, or the record's
  ## own when empty; Rev 3: `trailerRev3`, set with `setRev3Trailer`;
  ## `trailer` is ignored), pads a FIXREC block and writes a tape mark if
  ## `tapeMarkPerRecord`. Raises `ValueError` without a record in progress.
  if not w.inRecord: misuse("no record in progress")
  if w.tracesWritten != w.record.traceCount:
    w.problem("the channel set descriptors announce " & $w.record.traceCount & " traces, " &
      $w.tracesWritten & " were written",
      if w.record.isRev3: "csd.channelsInSet" else: "csd.channelCount")
  case w.record.layout
  of slRev2: w.endRev2Record(trailer)
  of slRev3: w.endRev3Record()
  w.padToBlock()
  if w.opts.tapeMarkPerRecord:
    w.sink.writeTapeMark()
    w.lastWasMark = true
  w.inRecord = false
  inc w.records

proc computeRev3Sizes*(rec: var SegdRecord, traces: openArray[SegdTrace]) =
  ## Sets a Rev 3 record's GH#3 header, data and record sizes and its GH#2
  ## trailer block count from its blocks and `traces` (for records built in
  ## memory). Raises `ValueError` for a record in the Rev 0-2 layout.
  if not rec.isRev3:
    raise newException(ValueError, "computeRev3Sizes needs a Rev 3 record")
  let header = rec.headerBytes
  rec.gh3.headerSize = uint32(header)
  var data = header
  for t in traces:
    data += SegdTraceHeaderSize + SegdBlockSize * int64(t.header.traceHeaderExtensions) +
      t.samples.len
  rec.gh3.dataSize = uint64(data)
  rec.gh3.recordSize = uint64(data + rec.trailerRev3.len)
  rec.gh2Rev3.generalTrailerBlocks = uint32(rec.trailerRev3.len div SegdBlockSize)

proc close*(w: var SegdWriter) =
  ## Marks the end of data: two tape marks (one if a record just ended with
  ## one). Disk sinks ignore tape marks. The sink stays open. Raises
  ## `ValueError` while a record is in progress.
  if w.inRecord: misuse("call endRecord before close")
  w.sink.writeTapeMark(if w.lastWasMark: 1 else: 2)

proc writeSegd*(sink: RecordSink, d: SegdData, opts = SegdWriteOptions()): DiagLog =
  ## Writes a whole in-memory stream (see `readSegd`); returns the writer log.
  var w = openSegdWriter(sink, opts, d.label)
  for r in d.records:
    w.writeRecordHeaders(r.record)
    for t in r.traces: w.writeTrace(t)
    w.endRecord()
  w.close()
  result = w.log
