## Rewriting SEG-Y headers for another revision: the one implementation behind
## `convertSegy` and `openSeismicWriter(..., like, segyRevision)`. The messages
## are `convertSegy`'s; do not reword them here.

import std/[math, strutils]
import ../common/[diagnostics, endians]
import ../segy/[reader, binheader, traceheader, textheader, exttext, samples]
import ./segyencode

type
  RevLoss = enum
    rlExtendedText, rlStanzasAsText, rlTrailers, rlTraceExtensions, rlIntervalRounding,
    rlUnassignedBinary, rlUnassignedTrace, rlRev1TraceFields, rlTimeRounding, rlSurveyType,
    rlLayoutStanza

  RevRewrite* = object
    ## State of one file's revision rewrite. File-level notes are reported by
    ## `prepareRevision`; trace notes and skips by `rewriteTrace`; the Rev 0
    ## time-clamp warning by `finishRevision`.
    fromRev*, toRev*: SegyRevision
    seen: set[RevLoss]
    clamped, clampedFirst: int
    finished: bool

func revisionCardText*(rev: SegyRevision): string =
  ## Card 39 as the SEG-Y writers name `rev`, prefix included.
  cardPrefix(39) & (if rev.major >= 2: "SEG-Y_REV" & $rev
    elif rev.major == 1: "SEG Y REV1" else: "")

func endCardText*(): string =
  ## Card 40, the end marker, prefix included.
  cardPrefix(40) & "END TEXTUAL HEADER"

func setBinarySampleCount*(b: var SegyBinaryHeader, n: int): bool =
  ## Sets the binary header's samples-per-trace fields to `n`, as the writers
  ## do. False, with nothing changed, when `n` needs Rev 2 and `b` is earlier.
  if n > int(high(uint16)) or (b.rulesRevision.major >= 2 and b.extSamplesPerTrace != 0):
    if b.rulesRevision.major < 2: return false
    b.extSamplesPerTrace = uint32(n)
  b.samplesPerTrace = if n > int(high(uint16)): 0'u16 else: uint16(n)
  true

proc writtenCountBytes*(b: var SegyBinaryHeader, written, maxSamples: int,
    anyWritten: bool, declaredTraces: uint64, order: ByteOrder): seq[byte] =
  ## The binary-header bytes to patch once the traces are known, or empty when
  ## `b` already holds them. `declaredTraces` is the count the rewritten header
  ## declared (0 when the revision has no such field, or the input declared
  ## none): it becomes `written`. When any trace was written, the sample count
  ## becomes the largest of those traces.
  ##
  ## When every trace was skipped, the sample-count field is left as the source
  ## wrote it. A variable file (`fixedLengthTraces == 0`) does not require 0:
  ## the flag says each trace carries its own count, so the binary field is not
  ## a declaration of traces that were not written, and 0 makes a reader warn
  ## that samples per trace is 0. A fixed-length count the target cannot hold
  ## is refused before any trace, so this path does not clear that field either.
  let before = b
  if anyWritten and uint32(maxSamples) != b.effectiveSamplesPerTrace:
    discard b.setBinarySampleCount(maxSamples)
  if declaredTraces != 0: b.numTraces = uint64(written)
  if b != before:
    result = newSeq[byte](BinaryHeaderSize)
    b.encode(result, order)

func trimmedCard(card: string): string =
  var n = card.len
  while n > 0 and card[n - 1] == ' ': dec n
  if n == 0: "" else: card.substr(0, n - 1)

func quotedCard(card: string): string =
  # Printable ASCII only, as `textCard`: a control byte must not enter a log line.
  result = card
  for ch in result.mitems:
    if ch notin {' '..'~'}: ch = ' '
  result = trimmedCard(result)

func cardBody(card: string, n: int): string =
  let p = cardPrefix(n)
  if card.len >= p.len and card.substr(0, p.len - 1) == p:
    var i = card.len
    while i > p.len and card[i - 1] == ' ': dec i
    if i <= p.len: "" else: card.substr(p.len, i - 1)
  else:
    trimmedCard(card)

func blankCard(card: string, n: int): bool =
  let p = cardPrefix(n)
  if card.len >= p.len and card.substr(0, p.len - 1) == p:
    for i in p.len ..< card.len:
      if card[i] != ' ': return false
    true
  else:
    trimmedCard(card).len == 0

func standardCard(card: string, n: int): bool =
  # Blank, or exactly a revision/end text the writers and the reader accept.
  # `END EBCDIC` is the traditional end marker `checkTextHeader` allows.
  if blankCard(card, n): return true
  let body = cardBody(card, n)
  if n == 39:
    body == "SEG Y REV1" or body == "SEG-Y_REV2.0" or body == "SEG-Y_REV2.1"
  else:
    body == "END TEXTUAL HEADER" or body == "END EBCDIC"

proc noteReplacedCard(log: var DiagLog, card: string, n: int, loc: Location) =
  if standardCard(card, n): return
  log.report(sevWarning, dcValidation, "card " & $n & " held \"" & quotedCard(card) &
    "\"; replaced with the target revision", loc = loc)

func revisionFault*(rev: SegyRevision): string =
  ## `convertSegy`'s message when `rev` is not 0, 1, 2.0 or 2.1; "" otherwise.
  if not (rev.major == 0 and rev.minor == 0 or rev.major == 1 and rev.minor == 0 or
      rev.major == 2 and rev.minor in {0'u8, 1}):
    "target revision " & $rev & " is not 0, 1, 2.0 or 2.1"
  else: ""

func endianFault*(rev: SegyRevision, order: ByteOrder): string =
  ## `convertSegy`'s message when `order` needs Rev 2 and `rev` is earlier; "".
  if order != boBig and rev.major < 2: "little-endian and pair-swapped SEG-Y need Rev 2"
  else: ""

func chosenFormatFault*(rev: SegyRevision, format: SampleFormat, label: string,
    order: ByteOrder): string =
  ## `checkTarget`'s message for a format the caller named (`label` is how
  ## that call names it). "" when `rev` and `order` can hold `format`.
  if format.isRev2Format and rev.major < 2:
    "format " & label & " needs SEG-Y Rev 2"
  elif sampleSize(format) == 3 and order == boPairSwapped:
    "3-byte format " & label & " cannot be pair-swapped"
  else: ""

func keptFormatFault*(rev: SegyRevision, format: SampleFormat, order: ByteOrder): string =
  ## `convertSegy`'s message when the input's own format does not fit `rev`
  ## or `order`. "" when it does.
  if format.isRev2Format and rev.major < 2:
    "the input format " & $ord(format) & " needs Rev 2; choose a Rev 1 format (e.g. 5)"
  elif sampleSize(format) == 3 and order == boPairSwapped:
    "the 3-byte format " & $ord(format) &
      " cannot be pair-swapped; choose another target format"
  else: ""

proc note(log: var DiagLog, seen: var set[RevLoss], kind: RevLoss, msg: string, loc: Location) =
  if kind notin seen:
    seen.incl kind
    log.report(sevInfo, dcValidation, msg, loc = loc)

func dropUnassigned(b: var SegyBinaryHeader, fromRev: SegyRevision): bool =
  # Zeroes the binary header fields that revision `fromRev` (0 or 1) leaves
  # unassigned and a later revision defines, so that vendor data there is
  # not read as a count or a flag: Rev 0 bytes 3261-3600, Rev 1 bytes
  # 3261-3300 and 3507-3532. True if any of them was set.
  let was = b
  b.extDataTracesPerEnsemble = 0
  b.extAuxTracesPerEnsemble = 0
  b.extSamplesPerTrace = 0
  b.extSampleInterval = 0
  b.extSampleIntervalOrig = 0
  b.extSamplesPerTraceOrig = 0
  b.extEnsembleFold = 0
  b.byteOrderMarker = 0
  b.maxAddlTraceHeaders = 0
  b.surveyType = 0
  b.timeBasisCode = 0
  b.numTraces = 0
  b.firstTraceOffset = 0
  b.numTrailerRecords = 0
  if fromRev.major == 0:
    b.unassigned1 = default(typeof(b.unassigned1))
    b.fixedLengthTraces = 0
    b.numExtTextHeaders = 0
    b.unassigned2 = default(typeof(b.unassigned2))
  was != b

func dropRev1Fields(h: var SegyTraceHeader): bool =
  # Zeroes trace bytes 181-240, which Rev 0 leaves unassigned and Rev 1
  # fills. True if any of them was set.
  let was = h
  h.cdpX = 0
  h.cdpY = 0
  h.inlineNumber = 0
  h.crosslineNumber = 0
  h.shotpointNumber = 0
  h.shotpointScalar = 0
  h.traceValueUnit = 0
  h.transductionMantissa = 0
  h.transductionExponent = 0
  h.transductionUnits = 0
  h.deviceTraceId = 0
  h.timeScalar = 0
  h.sourceTypeOrientation = 0
  h.sourceEnergyDirVert = 0
  h.sourceEnergyDirXline = 0
  h.sourceEnergyDirInline = 0
  h.sourceMeasurementMantissa = 0
  h.sourceMeasurementExponent = 0
  h.sourceMeasurementUnit = 0
  h.headerName = default(typeof(h.headerName))
  was != h

func unscaleTimes(h: var SegyTraceHeader): tuple[rounded, clamped: bool] =
  # Rev 0 has no time scalar: the times of bytes 95-114 become whole ms.
  let scalar = h.timeScalar
  if scalar != 0 and scalar != 1:
    template whole(field: untyped) =
      let ms = applyScalar(h.field, scalar)
      if abs(ms) > 32767.5: result.clamped = true
      elif ms != round(ms): result.rounded = true
      h.field = clampI16(ms)
    whole(upholeTimeSource)
    whole(upholeTimeGroup)
    whole(sourceStatic)
    whole(groupStatic)
    whole(totalStatic)
    whole(lagTimeA)
    whole(lagTimeB)
    whole(delayRecordingTime)
    whole(muteStart)
    whole(muteEnd)

proc prepareRevision*(f: var SegyFile, toRev: SegyRevision, log: var DiagLog, loc: Location,
    rw: var RevRewrite): string =
  ## Rewrites `f`'s file headers for `toRev` as `convertSegy` does, before any
  ## trace. Returns `convertSegy`'s fatal message when the file cannot be
  ## written (a fixed-length count or interval the target cannot hold); ""
  ## otherwise. Notes of what was dropped are appended to `log`. Cards 39 and
  ## 40 name `toRev` when it differs from the source revision. A card that held
  ## anything other than blanks or a standard revision or end text is a
  ## warning, the old text quoted.
  rw = RevRewrite(fromRev: f.revision, toRev: toRev)
  let fromRev = f.revision
  let rev = toRev
  let fileNs = f.binary.effectiveSamplesPerTrace
  let fileDt = f.binary.effectiveSampleInterval
  let fixedIn = fromRev.major >= 1 and f.binary.fixedLengthTraces == 1
  if fromRev.major < 2 and fromRev.major < rev.major and f.binary.dropUnassigned(fromRev):
    log.note(rw.seen, rlUnassignedBinary, "the Rev " & $fromRev & " input holds values in " &
      "binary header bytes its revision leaves unassigned (" &
      (if fromRev.major == 0: "3261-3600" else: "3261-3300, 3507-3532") & ") and Rev " & $rev &
      " defines: cleared", loc)
  if rev.major < 2 and fixedIn and not (fileDt >= 0 and fileDt <= 65535):
    return "the sample interval of " & $fileDt & " needs Rev 2 (Rev " & $rev &
      " holds whole intervals up to 65535)"
  if rev.major < 2 and fixedIn and fileNs > high(uint16):
    return $fileNs & " samples per trace need Rev 2 (Rev " & $rev & " holds up to 65535)"
  f.binary.revision = rev
  f.revision = rev
  if rev == SegyRevision(major: 2, minor: 0):
    if f.binary.surveyType != 0:
      log.note(rw.seen, rlSurveyType, "Rev 2.0 has no survey type (bytes 3509-3510 belong " &
        "to the additional trace header count): survey type " & $f.binary.surveyType &
        " dropped", loc)
      f.binary.surveyType = 0
    for s in f.extended.stanzas:
      if s.company.toUpperAscii == "SEG" and s.name.toLowerAscii.startsWith("layout"):
        log.note(rw.seen, rlLayoutStanza, "the ((SEG:Layout)) stanza is defined from Rev 2.1; " &
          "a Rev 2.0 reader ignores it (it is kept as text)", loc)
  if rev.major == 0 and f.extended.recordCount > 0:
    log.note(rw.seen, rlExtendedText, "Rev 0 has no extended textual headers: " &
      $f.extended.recordCount & " records dropped", loc)
    if f.extended.find("SEG:Layout") >= 0:
      log.report(sevWarning, dcValidation, "the input's ((SEG:Layout)) stanza is dropped " &
        "with the extended textual headers, but the trace headers keep its layout: readers " &
        "of the output take the fields it moved from their standard bytes", loc = loc)
  if rev.major == 0 or (rev.major < 2 and f.extended.recordCount > 0 and fromRev.major >= 2):
    if rev.major == 0:
      f.extended = initExtendedTextHeader()
      f.binary.numExtTextHeaders = 0
    else:
      log.note(rw.seen, rlStanzasAsText, "Rev 2 stanzas (Layout, User Data) are kept as " &
        "plain Rev 1 extended text", loc)
  if rev.major < 2:
    if f.trailer.recordCount > 0:
      log.note(rw.seen, rlTrailers, "Rev 1 has no data trailers: " & $f.trailer.recordCount &
        " records dropped", loc)
    f.trailer = initExtendedTextHeader()
    f.binary.byteOrderMarker = 0
    f.binary.maxAddlTraceHeaders = 0
    f.binary.numTraces = 0
    f.binary.firstTraceOffset = 0
    f.binary.numTrailerRecords = 0
    f.binary.samplesPerTrace = uint16(min(fileNs, uint32(high(uint16))))
    f.binary.extSamplesPerTrace = 0
    if fileDt != float64(f.binary.sampleInterval):
      if fileDt != round(fileDt):
        log.note(rw.seen, rlIntervalRounding, "Rev 1 holds sample intervals as whole units; " &
          "extended intervals were rounded", loc)
      f.binary.sampleInterval = if fileDt >= 0 and fileDt <= 65535: uint16(round(fileDt))
                                elif fileDt > 65535: high(uint16)
                                else: 0
    f.binary.extSampleInterval = 0
  else:
    f.binary.byteOrderMarker = ByteOrderMarker
    if fromRev.major < 2:
      f.binary.firstTraceOffset = 0
      f.binary.numTrailerRecords = 0
      if f.extended.recordCount > 0 and not f.extended.hasEndText:
        f.extended.addEndText()
        f.binary.numExtTextHeaders = int16(f.extended.recordCount)
  if fromRev != rev:
    noteReplacedCard(log, f.text.card(39), 39, loc)
    noteReplacedCard(log, f.text.card(40), 40, loc)
    f.text.setCard(39, revisionCardText(rev))
    f.text.setCard(40, endCardText())

func readSampleInterval*(f: SegyFile, t: SegyTrace): float64 =
  ## The interval `openSegy` stores on a trace: fixed-length files take the
  ## binary header's; a trace whose own count is 0 takes it when the header
  ## interval is 0; otherwise Extension 1 when that interval is usable, else
  ## trace bytes 117-118. `rewriteTrace` reads `t.sampleInterval`.
  let extDt = if t.hasExt1: t.ext1.extSampleInterval else: 0.0
  let traceDt = if usableExtInterval(extDt): extDt else: float64(t.header.sampleInterval)
  let traceNs = if t.hasExt1 and t.ext1.extNumSamples != 0: int(t.ext1.extNumSamples)
                else: int(t.header.numSamples)
  if f.revision.major >= 1 and f.binary.fixedLengthTraces == 1:
    f.binary.effectiveSampleInterval
  elif traceNs == 0 and f.binary.effectiveSamplesPerTrace != 0:
    if traceDt != 0: traceDt else: f.binary.effectiveSampleInterval
  else:
    traceDt

proc rewriteTrace*(rw: var RevRewrite, t: var SegyTrace, fixedOut: bool, log: var DiagLog,
    fileLoc, traceLoc: Location): bool =
  ## Rewrites `t`'s headers for `rw.toRev` as `convertSegy` does. `fixedOut`
  ## is the output binary header's fixed-length flag after `prepareRevision`.
  ## False when `convertSegy` would skip the trace: the same error is in
  ## `log`, and `t` must not be written. Notes use `fileLoc`; a skip uses
  ## `traceLoc` and `t.offset`. A trace identification code is kept:
  ## `convertSegy` does not remap one on a SEG-Y to SEG-Y copy.
  result = true
  let fromRev = rw.fromRev
  let rev = rw.toRev
  if fromRev.major == 0 and rev.major >= 1 and t.header.dropRev1Fields():
    log.note(rw.seen, rlUnassignedTrace, "the Rev 0 input holds values in trace header " &
      "bytes 181-240, which Rev 0 leaves unassigned and Rev " & $rev & " defines (CDP " &
      "position, inline and crossline, shotpoint, time scalar, ...): cleared", fileLoc)
  if fromRev.major >= 1 and rev.major == 0:
    let times = t.header.unscaleTimes()
    if times.rounded:
      log.note(rw.seen, rlTimeRounding, "Rev 0 holds the trace times (bytes 95-114) as " &
        "whole ms, without a time scalar: scaled times were rounded", fileLoc)
    if times.clamped:
      if rw.clamped == 0: rw.clampedFirst = traceLoc.trace
      inc rw.clamped
    if t.header.dropRev1Fields():
      log.note(rw.seen, rlRev1TraceFields, "Rev 0 leaves trace header bytes 181-240 " &
        "unassigned: the CDP position, inline and crossline numbers, shotpoint and the " &
        "other Rev 1 fields there are dropped", fileLoc)
  if rev.major < 2:
    if t.numSamples > int(high(uint16)):
      log.report(sevError, dcValidation, "the trace has " & $t.numSamples &
        " samples, which Rev 1 cannot hold; skipped", t.offset, traceLoc)
      result = false
    if t.hasExt1:
      log.note(rw.seen, rlTraceExtensions, "Rev 1 has no Trace Header Extension 1 or " &
        "proprietary trace headers: dropped", fileLoc)
    t.hasExt1 = false
    t.proprietary.setLen 0
    t.header.numSamples = uint16(min(t.numSamples, int(high(uint16))))
    let dt = t.sampleInterval
    if not (dt >= 0 and dt <= 65535):
      if result:
        log.report(sevError, dcValidation, "the trace has a sample interval of " & $dt &
          ", which Rev " & $rev & " cannot hold (whole, up to 65535); skipped", t.offset,
          traceLoc)
      result = false
    elif dt != float64(t.header.sampleInterval):
      if dt != round(dt):
        log.note(rw.seen, rlIntervalRounding, "Rev 1 holds sample intervals as whole units; " &
          "extended intervals were rounded", fileLoc)
      t.header.sampleInterval = uint16(round(dt))
  elif not fixedOut:
    # Each trace gives its own count and interval. A Rev 0 trace may leave
    # them to the binary header (the reader says so): write them out.
    if declaredSamples(t) != t.numSamples and not t.setSampleCount(t.numSamples):
      log.report(sevError, dcValidation, "the trace has " & $t.numSamples &
        " samples, which need a Trace Header Extension 1 it lacks; skipped", t.offset, traceLoc)
      return false
    let dt = t.sampleInterval
    if t.header.sampleInterval == 0 and dt >= 1 and dt <= 65535 and dt == round(dt) and
        not (t.hasExt1 and t.ext1.extSampleInterval != 0):
      t.header.sampleInterval = uint16(dt)

proc finishRevision*(rw: var RevRewrite, log: var DiagLog, loc: Location) =
  ## The warning `convertSegy` reports once the traces are written: times
  ## clamped to what Rev 0 can hold. Once.
  if rw.finished: return
  rw.finished = true
  if rw.clamped > 0:
    log.report(sevWarning, dcValidation, $rw.clamped & " traces (the first is trace " &
      $rw.clampedFirst & ") have times beyond ±32767 ms in bytes 95-114, which Rev 0 " &
      "cannot hold without a time scalar: clamped", loc = loc)
