## Format-independent file summary (task 6.8): the metadata a viewer or a
## processing job needs, with no branch on the standard or the revision.
##
## ```nim
## let f = openSeismic("line.sgd")
## let s = f.summary
## echo s.standard, " rev ", s.revision, ", ", s.traceCount, " traces @ ",
##   s.sampleIntervalUs, " µs"
## for cs in f.channelSets: echo cs.channelSet, ": ", cs.sampleIntervalUs
## ```
##
## Where the values come from:
##
## ==================  ==============================  ==================================
## value               SEG-Y                           SEG-D
## ==================  ==============================  ==================================
## revision            binary 3501-3502 (as applied)   GH#2 bytes 11-12 (first record)
## format code         binary 3225-3226                GH#1 bytes 3-4
## field records       trace bytes 9-12, first/last    file number, first/last record
## sample interval     each trace's effective one      each trace's channel set
## record length       (samples - 1) × interval        GH#1 / GH#2 record length
## coordinate units    trace 89-90, binary 3255-3256   CRS text (Rev 3), else unknown
## CRS text            P1/11 or Location Data stanza   0x55 blocks of the general header
## ==================  ==============================  ==================================
##
## SEG-2: the File Descriptor Block revision and byte order, the format code
## when every trace shares one, SHOT_SEQUENCE_NUMBER of the first and last
## trace, SAMPLE_INTERVAL, and UNITS (meters or feet; no CRS text).
##
## SEG-Y and SEG-D are read from the index and from at most two trace
## headers, so a summary costs no walk over the file; SEG-2 re-reads each
## Trace Descriptor Block for its sample interval.

import std/[math, strutils]
import ../common/endians
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ../seg2/headers as seg2headers
import ./[traceindex, headerfields]

type
  CoordinateUnits* = enum
    ## Units of a file's coordinates.
    cuUnknown = "unknown"
    cuMeters = "meters"
    cuFeet = "feet"
    cuLength = "length"         ## SEG-Y trace code 1 (length) with no measurement system.
    cuArcSeconds = "arcSeconds" ## SEG-Y trace code 2 (deprecated in Rev 2).
    cuDegrees = "degrees"       ## Decimal degrees.
    cuDms = "dms"               ## SEG-Y trace code 4: degrees, minutes, seconds.

  StandardRevision* = object
    ## A revision of the standard, e.g. 2.1.
    major*, minor*: int

  FileSummary* = object
    ## A file's common metadata, the same for every standard and revision.
    ## Unknown or non-uniform numbers are NaN (floats) or -1 (integers).
    standard*: SeismicKind
    revision*: StandardRevision
      ## SEG-Y: the revision whose rules were applied. SEG-D: the first
      ## record's (0.0 for Rev 0); see `mixedRevisions`.
    mixedRevisions*: bool ## SEG-D records of more than one revision.
    byteOrder*: ByteOrder ## Of binary fields and samples (SEG-D: always big).
    formatCode*: int
      ## The sample format code (SEG-Y 1-16, SEG-D 8058, ...); -1 when SEG-D
      ## records differ or there are none.
    decodable*: bool ## Every trace's sample format can be decoded.
    traceCount*, recordCount*: int
    firstFieldRecord*, lastFieldRecord*: int64
      ## SEG-Y: field record numbers of the first and last trace; SEG-D: file
      ## numbers of the first and last record; -1 when there are none.
    sampleIntervalUs*: float64
      ## The interval every trace shares (µs; SEG-Y non-time data: Hz or
      ## m/ft); NaN when they differ (SEG-D: see `channelSets`).
    samplesPerTrace*: int ## Samples every trace has; -1 when they differ.
    recordLengthMs*: float64
      ## SEG-Y: (samples - 1) × interval when both are uniform. SEG-D: the
      ## general header's record length when every record has the same (NaN
      ## for 0, "indeterminate", and for a field that is not valid BCD).
    coordinateUnits*: CoordinateUnits
    crsFormat*: CrsTextFormat ## Format of `crsText`; `ctNone` when there is none.

  ChannelSetSummary* = object
    ## One SEG-D channel set of one record.
    record*: int           ## 0-based record index.
    scanType*: int         ## 0-based scan type index.
    channelSet*: int       ## 0-based index within the scan type.
    number*: int           ## The channel set number in the headers.
    channelType*: int      ## Rev 1/2 nibble (1 = seismic) or Rev 3 byte (0x10 = seismic).
    traceCount*: int       ## Traces of this set in the index.
    samplesPerTrace*: int  ## Samples of its longest trace; 0 when it has none.
    sampleIntervalUs*: float64
    startTimeMs*, endTimeMs*: float64

func `$`*(r: StandardRevision): string =
  ## `major.minor`, e.g. `2.1`.
  $r.major & "." & $r.minor

# -------------------------------------------------------------------- CRS --

func isCrsStanza(s: Stanza): bool =
  let name = s.name.toLowerAscii
  name.startsWith("p1/11") or name.startsWith("location data")

proc segyCrs(file: SegyFile, text: var string): CrsTextFormat =
  # The first P1/11 or Location Data stanza of the extended textual header.
  for s in file.extended.stanzas:
    if isCrsStanza(s):
      text = file.extended.stanzaText(s)
      return if s.name.toLowerAscii.startsWith("p1/11"): ctP1_11 else: ctStanza
  ctNone

proc segdCrs(ix: TraceIndex, text: var string): CrsTextFormat =
  # The first Rev 3 record with 0x55 blocks in its general header.
  for rec in ix.segdRecords:
    if rec.isRev3:
      let t = crsText(rec.generalBlocks)
      if t.len > 0:
        text = t
        return crsFormat(t)
  ctNone

func unitsOf(name: string): CoordinateUnits =
  let n = name.strip.toLowerAscii
  if n in ["metre", "meter", "metres", "meters", "m"]: cuMeters
  elif "foot" in n or "feet" in n or n == "ft": cuFeet
  elif n.startsWith("degree") or n == "deg": cuDegrees
  else: cuUnknown

func crsUnits(text: string, format: CrsTextFormat): CoordinateUnits =
  # P1/11: the unit of the first coordinate axis record (HC,1,6,1), which
  # belongs to the first CRS. Other formats: unknown.
  if format == ctP1_11:
    for line in text.splitLines:
      let l = line.strip
      if l.startsWith("HC,1,6,1,"):
        let parts = l.split(',')
        return unitsOf(parts[^1])
  cuUnknown

proc crsText*(f: SeismicFile): string =
  ## The coordinate reference system text, as stored: SEG-Y, the first P1/11
  ## or Location Data stanza of the extended textual header (its data);
  ## SEG-D Rev 3, the 0x55 blocks of the first record that has them (from
  ## `((SEG:` or `((OGP:`). Empty when the file has none; `summary` says
  ## which format it is in.
  if f.kind == skSegy: discard segyCrs(f.index.segy, result)
  elif f.kind == skSegd: discard segdCrs(f.index, result)

# ---------------------------------------------------------------- summary --

proc intField(f: SeismicFile, trace: int, name: string): int64 =
  let v = f.findTraceField(trace, name)
  if v.isSome and v.get.kind == fvInt: v.get.intVal else: 0

proc segyUnits(f: SeismicFile, crs: CoordinateUnits): CoordinateUnits =
  # Trace bytes 89-90 of the first trace; length (1) or unset (0) take the
  # binary measurement system, then the CRS.
  let code = if f.len > 0: f.intField(0, "trace.coordinateUnits") else: 0
  let system = case f.index.segy.binary.measurementSystem
    of 1: cuMeters
    of 2: cuFeet
    else: cuUnknown
  case code
  of 1: (if system != cuUnknown: system elif crs != cuUnknown: crs else: cuLength)
  of 2: cuArcSeconds
  of 3: cuDegrees
  of 4: cuDms
  else: (if system != cuUnknown: system else: crs)

func segdRecordLengthMs(rec: SegdRecord): float64 =
  result = case rec.layout
    of slRev3: recordLengthUs(rec.gh1, rec.gh2Rev3) / 1000
    of slRev2:
      if rec.gh2.isSome: recordLengthMs(rec.gh1, rec.gh2.get)
      elif rec.gh1.recordLength >= 0: float64(rec.gh1.recordLength) * 102.4
      else: NaN
  if result == 0: result = NaN

func sameSet(a, b: TraceEntry): bool {.inline.} =
  # Traces of one channel set of one SEG-D record.
  a.record == b.record and a.scanType == b.scanType and a.channelSet == b.channelSet

func uniformSamples(ix: TraceIndex): int =
  result = -1
  for i, e in ix.entries:
    if i == 0: result = int(e.numSamples)
    elif int(e.numSamples) != result: return -1

proc summary*(f: SeismicFile): FileSummary =
  ## The file's common metadata: standard, revision, byte order, sample
  ## format, trace and record counts, first and last field record, sample
  ## interval, samples per trace, record length, coordinate units and the
  ## CRS text's format. Reads the index and at most two trace headers. An unrecognized file gives
  ## `standard == skUnknown` and zero counts. Raises `ValueError` for a SEG-Y
  ## file that has been closed (its trace headers are read from the map).
  template ix: untyped = f.index
  result = FileSummary(standard: f.kind, formatCode: -1, firstFieldRecord: -1,
    lastFieldRecord: -1, sampleIntervalUs: NaN, samplesPerTrace: ix.uniformSamples,
    recordLengthMs: NaN, traceCount: f.len, recordCount: f.recordCount)
  result.decodable = f.kind != skUnknown
  for c in ix.codecs:
    if not c.known: result.decodable = false
  var text = ""
  case f.kind
  of skUnknown: discard
  of skSegy:
    if f.len > 0: f.requireOpen()
    template s: untyped = ix.segy
    result.revision = StandardRevision(major: int(s.revision.major), minor: int(s.revision.minor))
    result.byteOrder = s.byteOrder
    result.formatCode = int(s.binary.formatCode)
    if f.len > 0:
      result.firstFieldRecord = f.intField(0, "trace.fieldRecord")
      result.lastFieldRecord = f.intField(f.len - 1, "trace.fieldRecord")
      result.sampleIntervalUs = ix.segyIntervalUs
      if result.samplesPerTrace >= 0 and not result.sampleIntervalUs.isNaN:
        result.recordLengthMs = float64(max(result.samplesPerTrace - 1, 0)) *
          result.sampleIntervalUs / 1000
    result.crsFormat = segyCrs(s, text)
    result.coordinateUnits = segyUnits(f, crsUnits(text, result.crsFormat))
  of skSegd:
    result.byteOrder = boBig
    result.coordinateUnits = cuUnknown
    for i in 0 ..< ix.segdRecords.len:
      # By index: `for i, rec in` copies each record, its header bytes included.
      template rec: untyped = ix.segdRecords[i]
      let rv = StandardRevision(major: int(rec.revision.major), minor: int(rec.revision.minor))
      let code = int(rec.gh1.formatCode)
      let len = segdRecordLengthMs(rec)
      if i == 0:
        (result.revision, result.formatCode, result.recordLengthMs) = (rv, code, len)
        result.firstFieldRecord = rec.fileNumber
      else:
        if rv != result.revision: result.mixedRevisions = true
        if code != result.formatCode: result.formatCode = -1
        if len != result.recordLengthMs: result.recordLengthMs = NaN
      result.lastFieldRecord = rec.fileNumber
    # The interval is its channel set's: asked once per run of traces of one
    # set, not once per trace.
    var i = 0
    while i < ix.entries.len:
      let e = ix.entries[i]
      let cs = if e.scanType >= 0: e.channelSetIndex else: -1
      let dt = ix.segdRecords[e.record].sampleIntervalUs(int(e.scanType), cs)
      if i == 0: result.sampleIntervalUs = dt
      elif dt != result.sampleIntervalUs:
        result.sampleIntervalUs = NaN
        break
      inc i
      while i < ix.entries.len and ix.entries[i].sameSet(e): inc i
    result.crsFormat = segdCrs(ix, text)
    result.coordinateUnits = crsUnits(text, result.crsFormat)
  of skSeg2:
    if f.len > 0: f.requireOpen()
    template s: untyped = ix.seg2
    result.revision = StandardRevision(major: int(s.revision))
    result.byteOrder = s.order
    if ix.codecs.len == 1 and ix.codecs[0].seg2Format.isSome:
      result.formatCode = ord(ix.codecs[0].seg2Format.get) # the code itself (1-5)
    result.coordinateUnits = case s.units.get(unNone)
      of unMeters: cuMeters
      of unFeet: cuFeet
      else: cuUnknown
    if f.len > 0:
      proc shot(f: SeismicFile, i: int): int64 =
        let v = f.seg2Trace(i).integer("SHOT_SEQUENCE_NUMBER")
        if v.isSome: v.get else: f.index.seg2.integer("SHOT_SEQUENCE_NUMBER").get(-1)
      result.firstFieldRecord = f.shot(0)
      result.lastFieldRecord = f.shot(f.len - 1)
      for i in 0 ..< f.len:
        let dt = float64(f.sampleIntervalUs(i))
        if i == 0: result.sampleIntervalUs = dt
        elif dt != result.sampleIntervalUs:
          result.sampleIntervalUs = NaN
          break
      if result.samplesPerTrace >= 0 and not result.sampleIntervalUs.isNaN:
        result.recordLengthMs = float64(max(result.samplesPerTrace - 1, 0)) *
          result.sampleIntervalUs / 1000

proc channelSets*(f: SeismicFile): seq[ChannelSetSummary] =
  ## Every channel set of every SEG-D record, in record, scan type and
  ## channel set order, with its sample interval, timing and the traces the
  ## index holds for it. Empty for SEG-Y.
  template ix: untyped = f.index
  if f.kind != skSegd: return
  # The sets of scan type `k`, counted through all records, are
  # `result[firstSet[k] ..< firstSet[k + 1]]`; record `r` has the scan types
  # `firstScanType[r] ..< firstScanType[r + 1]`. Records and scan types are
  # read in place (`for r, rec in` copies each one).
  let records = ix.segdRecords.len
  var firstScanType = newSeq[int](records + 1)
  var firstSet: seq[int]
  for r in 0 ..< records:
    template rec: untyped = ix.segdRecords[r]
    firstScanType[r] = firstSet.len
    for st in 0 ..< rec.scanTypes.len:
      template s: untyped = rec.scanTypes[st]
      firstSet.add result.len
      for cs in 0 ..< s.channelSetCount:
        var c = ChannelSetSummary(record: r, scanType: st, channelSet: cs,
          channelType: rec.channelType(st, cs), sampleIntervalUs: rec.sampleIntervalUs(st, cs))
        case s.layout
        of slRev2:
          template d: untyped = s.descriptors[cs]
          (c.number, c.startTimeMs, c.endTimeMs) = (channelSetNumber(d), d.startTimeMs,
            d.endTimeMs)
        of slRev3:
          template d: untyped = s.descriptorsRev3[cs]
          (c.number, c.startTimeMs, c.endTimeMs) = (int(d.channelSetNumber),
            float64(d.startTime) / 1000, float64(d.endTime) / 1000)
        result.add c
  firstScanType[records] = firstSet.len
  firstSet.add result.len
  # The traces of each set, added once per run of traces of one set (they
  # are consecutive in a file) instead of a table update per trace: 0.40 ms
  # where that took 10.9 ms for 500000 traces in 500 records.
  let n = ix.entries.len
  var i = 0
  while i < n:
    let e = ix.entries[i]
    var longest = e.numSamples
    var j = i + 1
    while j < n and ix.entries[j].sameSet(e):
      longest = max(longest, ix.entries[j].numSamples)
      inc j
    # A trace that names no set, or one its record does not have, counts nowhere.
    if int(e.record) < records and e.scanType >= 0:
      let k = firstScanType[e.record] + int(e.scanType)
      if k < firstScanType[e.record + 1] and int(e.channelSet) < firstSet[k + 1] - firstSet[k]:
        template c: untyped = result[firstSet[k] + int(e.channelSet)]
        c.traceCount += j - i
        c.samplesPerTrace = max(c.samplesPerTrace, int(longest))
    i = j
