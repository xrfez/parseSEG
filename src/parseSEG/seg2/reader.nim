## SEG-2 reader (spec note `seg2.md` §2, §3, §6): parses the File Descriptor
## Block, the trace pointers and every Trace Descriptor Block of a SEG-2 file
## held in memory, and decodes Data Blocks, with every problem logged as a
## diagnostic.
##
## ```nim
## var f = openSeismic("shot.dat")      # detects SEG-2, maps the file
## let samples = f.readTraces(0 ..< f.len)
## ```
##
## SEG-2 is a random-access disk format: the File Descriptor Block points at
## each trace, in any order. The procs here therefore work on the whole file
## as an `openArray[byte]`, normally the read-only memory map that
## `openSeismic` keeps (`model/traceindex`), so nothing is copied and the OS
## pages in only what is touched. `readSeg2` parses the file block,
## `traces` walks the trace blocks (headers only), `readSamples` decodes one
## Data Block.
##
## Nothing here raises on format problems except `readSamples`: a damaged
## block is logged and kept (`Seg2Trace.valid` false), so trace numbers stay
## those of the pointer table.

import std/[algorithm, strutils]
import ../common/[errors, diagnostics]
import ./[headers, samples]
export headers, diagnostics
export samples except decodeSeg2SamplesRaw

type
  ListNote = enum
    # Style problems of string lists, logged once per file.
    lnLowercase, lnUnsorted, lnNoteNotLast

  WalkState = object
    # Cross-trace checks of one `traces` walk.
    notes: set[ListNote]
    withChannel, withoutChannel: int

func dataOffset*(t: Seg2Trace): int64 {.inline.} =
  ## File offset of the trace's Data Block (right after its descriptor).
  t.offset + int64(t.blockSize)

func sampleCount*(t: Seg2Trace): int =
  ## The samples a reader decodes: `numSamples`, bounded by what `dataSize`
  ## holds; `numSamples` for an undefined format (indexed, not decoded); 0
  ## for an invalid block.
  if not t.valid: 0
  elif t.format.isNone: int(t.numSamples)
  else: min(int(t.numSamples), samplesIn(t.format.get, int(t.dataSize)))

func sampleCount*(t: Seg2Trace, fileSize: int64): int =
  ## `sampleCount`, at most the bytes from the Data Block to the end of a
  ## file of `fileSize` bytes (no format stores a sample in less than one):
  ## what a reader may allocate for the trace, also when `numSamples` and
  ## `dataSize` are damaged. A trace that is cut short keeps its count (and
  ## reads as truncated).
  int(min(int64(t.sampleCount), max(0'i64, fileSize - t.dataOffset)))

proc checkList(s: openArray[Seg2String], st: var WalkState, log: var DiagLog,
    loc: Location, offset: int64) =
  # Spec style rules vendors often break: info only, once per file each.
  template note(n: ListNote, msg: string) =
    if n notin st.notes:
      st.notes.incl n
      log.report(sevInfo, dcBadValue, msg & " (logged once per file)", offset, loc)
  for i, x in s:
    if x.key != x.key.toUpperAscii:
      note(lnLowercase, "keyword " & x.key.escape & " is not uppercase")
    if cmpIgnoreCase(x.key, "NOTE") == 0 and i != s.high:
      note(lnNoteNotLast, "NOTE is not the last string")
    if i > 0 and cmpIgnoreCase(x.key, "NOTE") != 0 and cmpIgnoreCase(s[i - 1].key, "NOTE") != 0 and
        cmpIgnoreCase(s[i - 1].key, x.key) > 0:
      note(lnUnsorted, "strings are not sorted by keyword (" & s[i - 1].key & " before " &
        x.key & ")")

proc readStrings(data: openArray[byte], first, limit: int, f: Seg2File, log: var DiagLog,
    loc: Location, spans: var seq[Slice[int]]): seq[Seg2String] =
  # The string list at `first`, which must end before `limit`. Each entry is
  # a u16 offset to the next one (the entry's length, these 2 bytes
  # included; 0 ends the list), then the text up to the String Terminator.
  var p = first
  while true:
    if p + 2 > limit:
      log.report(sevWarning, dcTruncated, "the string list has no 0 end marker before byte " &
        $limit & "; strings up to there are kept", int64(p), loc)
      return
    let n = int(getNum[uint16](data, p, f.order))
    if n == 0: return
    if n < 2 or p + n > limit:
      log.report(sevWarning, dcBadValue, "a string's next-string offset " & $n &
        (if n < 2: " is below 2" else: " runs past the block end (byte " & $limit & ")") &
        "; the rest of the list is skipped", int64(p), loc)
      return
    var text = newString(n - 2)
    for k in 0 ..< n - 2: text[k] = char(data[p + 2 + k])
    let cut = if f.stringTerm.len > 0: text.find(f.stringTerm) else: -1
    if cut >= 0: text.setLen cut
    let s = toSeg2String(text)
    if s.key.len > 0:
      result.add s
      spans.add p .. p + n - 1
    p += n

proc blockStrings*(data: openArray[byte], first, limit: int, f: Seg2File): seq[Seg2String] =
  ## The string list starting at byte `first` of `data` and ending before
  ## `limit` (a Trace Descriptor Block's strings start at its byte 32, the
  ## file strings at `32 + pointerBytes`), parsed as the reader does,
  ## without diagnostics.
  var log: DiagLog
  var spans: seq[Slice[int]]
  if first >= 0 and limit <= data.len:
    result = readStrings(data, first, limit, f, log, Location(), spans)

proc blockStrings*(data: openArray[byte], first, limit: int, f: Seg2File,
    spans: var seq[Slice[int]]): seq[Seg2String] =
  ## `blockStrings`, with `spans` set to each string entry's bytes in
  ## `data` (offset word and terminator included), one per string.
  var log: DiagLog
  spans.setLen 0
  if first >= 0 and limit <= data.len:
    result = readStrings(data, first, limit, f, log, Location(), spans)

func stringListEnd*(data: openArray[byte], first, limit: int, order: ByteOrder): int =
  ## Where the string list at `first` ends: past its 0 end word, rounded up
  ## to 4 bytes and bounded by `limit` (`limit` when the list is damaged).
  var p = first
  while p + 2 <= limit:
    let n = int(getNum[uint16](data, p, order))
    if n == 0: return min(limit, (p + 2 + 3) div 4 * 4)
    if n < 2: return limit
    p += n
  limit

func fileBlockSize*(data: openArray[byte], f: Seg2File): int =
  ## Bytes of the File Descriptor Block of the file `data`: fixed part,
  ## trace pointers and the padded file strings (ending at the first trace
  ## block at the latest).
  let first = Seg2FixedSize + int(f.pointerBytes)
  var limit = data.len
  for p in f.pointers:
    if int64(p) >= first and int64(p) < limit: limit = int(p)
  if first >= limit: min(first, data.len) else: stringListEnd(data, first, limit, f.order)

proc readSeg2*(data: openArray[byte], log: var DiagLog, name = ""): Seg2File =
  ## Parses the File Descriptor Block at the start of `data` (the whole
  ## file): fixed part, trace pointers, file strings. Problems go to `log`
  ## (`name` is the file name in each entry); a block that is not SEG-2 or
  ## is cut off gives a fatal entry and a file without pointers. More than
  ## M/4 traces are clamped to M/4.
  let loc = Location(file: name)
  let o = seg2Order(data)
  if o.isNone:
    log.report(sevFatal, dcUnsupportedFormat, "no SEG-2 File Descriptor Block ID (0x3A55)",
      0, loc)
    return
  if data.len < Seg2FixedSize:
    log.report(sevFatal, dcTruncated, "the file ends inside the File Descriptor Block", 0, loc)
    return
  result.order = o.get
  template u16(at: int): uint16 = getNum[uint16](data, at, result.order)
  result.revision = u16(2)
  result.pointerBytes = u16(4)
  result.traceCount = u16(6)
  if result.revision != 1:
    log.report(sevWarning, dcUnsupportedRevision, "revision " & $result.revision &
      " is not defined; read as revision 1", 2, loc)
  let m = int(result.pointerBytes)
  if m < 4 or m mod 4 != 0:
    log.report(sevWarning, dcBadValue, "the Trace Pointer Subblock size M = " & $m &
      " is not a non-zero multiple of 4", 4, loc)
  var n = int(result.traceCount)
  if n > m div 4:
    log.report(sevError, dcInconsistent, $n & " traces do not fit the " & $m &
      "-byte Trace Pointer Subblock; " & $(m div 4) & " read", 6, loc)
    n = m div 4
  if n == 0:
    log.report(sevWarning, dcBadValue, "the file has no traces (N = 0)", 6, loc)
  elif n > Seg2MaxTraces:
    log.report(sevWarning, dcBadValue, $n & " traces exceed the standard's " & $Seg2MaxTraces, 6,
      loc)
  template terminator(at: int, what: string): string =
    var count = int(data[at])
    if count notin 1..2:
      log.report(sevWarning, dcBadValue, "the " & what & " length " & $count &
        " is not 1 or 2; 1 used", int64(at), loc)
      count = 1
    var t = ""
    for k in 1..count:
      if data[at + k] > 31:
        log.report(sevWarning, dcBadValue, "the " & what & " character 0x" &
          toHex(data[at + k]) & " is not a control character (0-31)", int64(at + k), loc)
      t.add char(data[at + k])
    t
  result.stringTerm = terminator(8, "String Terminator")
  result.lineTerm = terminator(11, "Line Terminator")
  if Seg2FixedSize + 4 * n > data.len:
    log.report(sevFatal, dcTruncated, "the file ends inside the trace pointers; " &
      $((data.len - Seg2FixedSize) div 4) & " of " & $n & " read", Seg2FixedSize, loc)
    n = max(0, (data.len - Seg2FixedSize) div 4)
  result.pointers = newSeq[uint32](n)
  for i in 0..<n: result.pointers[i] = getNum[uint32](data, Seg2FixedSize + 4 * i, result.order)
  # The file strings end before the first trace block.
  let first = Seg2FixedSize + m
  var limit = data.len
  for p in result.pointers:
    if int64(p) >= first and int64(p) < limit: limit = int(p)
  if first + 2 > data.len:
    log.report(sevWarning, dcTruncated, "the file ends before the file strings", first, loc)
  else:
    var spans: seq[Slice[int]]
    result.strings = readStrings(data, first, limit, result, log, loc, spans)

proc readTrace(data: openArray[byte], f: Seg2File, i: int, log: var DiagLog,
    name: string): Seg2Trace =
  # Trace Descriptor Block `i`, validated (see `readSeg2Trace`).
  let p = int64(f.pointers[i])
  let loc = Location(file: name, trace: i)
  result = Seg2Trace(offset: p)
  if p < int64(Seg2FixedSize) + int64(f.pointerBytes) or p + Seg2FixedSize > data.len:
    log.report(sevError, dcBadValue, "trace pointer " & $p &
      (if p + Seg2FixedSize > data.len: " lies past the end of the file (" & $data.len &
        " bytes)" else: " points into the File Descriptor Block") &
      "; the trace is not decoded", Seg2FixedSize + 4 * i, loc)
    return
  let a = int(p)
  if getNum[uint16](data, a, f.order) != Seg2TraceBlockId:
    log.report(sevError, dcBadValue, "no Trace Descriptor Block ID (0x4422) at trace pointer " &
      $p & "; the trace is not decoded", p, loc)
    return
  if p mod 4 != 0:
    log.report(sevWarning, dcBadValue, "trace pointer " & $p & " is not a multiple of 4", p, loc)
  result.blockSize = getNum[uint16](data, a + 2, f.order)
  result.dataSize = getNum[uint32](data, a + 4, f.order)
  result.numSamples = getNum[uint32](data, a + 8, f.order)
  result.formatCode = data[a + 12]
  let bs = int(result.blockSize)
  if bs < Seg2FixedSize or p + bs > data.len:
    log.report(sevError, dcBadValue, "the Trace Descriptor Block size " & $bs &
      (if bs < Seg2FixedSize: " is below 32" else: " runs past the end of the file") &
      "; the trace is not decoded", p + 2, loc)
    return
  if bs mod 4 != 0:
    log.report(sevWarning, dcBadValue, "the Trace Descriptor Block size " & $bs &
      " is not a multiple of 4", p + 2, loc)
  if result.dataSize mod 4 != 0:
    log.report(sevWarning, dcBadValue, "the Data Block size " & $result.dataSize &
      " is not a multiple of 4", p + 4, loc)
  var spans: seq[Slice[int]]
  result.strings = readStrings(data, a + Seg2FixedSize, a + bs, f, log, loc, spans)
  result.valid = true
  let fmt = result.format
  if fmt.isNone:
    log.report(sevError, dcUnsupportedFormat, "sample format code " & $result.formatCode &
      " is not defined (1-5); the trace is indexed, not decoded", p + 12, loc)
    return
  let n = int(result.numSamples)
  if fmt.get == s2Float20 and n mod 4 != 0:
    log.report(sevWarning, dcBadValue, $n &
      " samples are not a multiple of 4, as format 3 needs; the last group is read whole",
      p + 8, loc)
  let need = dataBytes(fmt.get, n)
  if need > int64(result.dataSize):
    log.report(sevWarning, dcInconsistent, $n & " samples need " & $need &
      " bytes but the Data Block has " & $result.dataSize & "; " & $result.sampleCount &
      " samples are read", p + 4, loc)
  let stored = dataBytes(fmt.get, result.sampleCount)
  if result.dataOffset + stored > data.len:
    log.report(sevError, dcTruncated, "the Data Block runs past the end of the file",
      result.dataOffset, loc)

proc readSeg2Trace*(data: openArray[byte], f: Seg2File, i: int, log: var DiagLog,
    name = ""): Seg2Trace =
  ## Parses the Trace Descriptor Block of trace `i` (pointer `f.pointers[i]`)
  ## of the file `data`. A pointer outside the file, a wrong block ID or a
  ## block size that does not fit gives an error entry and a trace with
  ## `valid` false; an undefined format code gives a valid trace that is
  ## not decoded (`format` none). Raises `ValueError` for `i` outside
  ## `f.pointers`.
  if i notin 0 ..< f.pointers.len:
    raise newException(ValueError, "no trace " & $i & " (the file has " & $f.pointers.len & ")")
  readTrace(data, f, i, log, name)

iterator traces*(data: openArray[byte], f: Seg2File, log: var DiagLog,
    name = ""): Seg2Trace =
  ## Every trace's descriptor, in pointer order (see `readSeg2Trace`). Also
  ## checks what spans traces: string style (info, once per file), a
  ## `CHANNEL_NUMBER` in only some traces, and blocks that overlap.
  var st: WalkState
  checkList(f.strings, st, log, Location(file: name), Seg2FixedSize + int64(f.pointerBytes))
  var spans: seq[(int64, int64, int)]
  for i in 0 ..< f.pointers.len:
    let t = readTrace(data, f, i, log, name)
    if t.valid:
      checkList(t.strings, st, log, Location(file: name, trace: i), t.offset)
      if "CHANNEL_NUMBER" in t: inc st.withChannel else: inc st.withoutChannel
      spans.add (t.offset, t.dataOffset + int64(t.dataSize), i)
    yield t
  if st.withChannel > 0 and st.withoutChannel > 0:
    log.report(sevWarning, dcInconsistent, $st.withoutChannel &
      " trace(s) have no CHANNEL_NUMBER while " & $st.withChannel &
      " have one (the standard wants it in all or none)", loc = Location(file: name))
  spans.sort()
  for k in 1 ..< spans.len:
    if spans[k][0] < spans[k - 1][1]:
      log.report(sevWarning, dcInconsistent, "trace " & $spans[k][2] & " overlaps trace " &
        $spans[k - 1][2] & " (block at " & $spans[k][0] & ", previous ends at " &
        $spans[k - 1][1] & ")", spans[k][0], Location(file: name, trace: spans[k][2]))

proc readSamples*[T: Seg2SampleType](data: openArray[byte], f: Seg2File, t: Seg2Trace,
    dst: var openArray[T], twosComplement = false) =
  ## Decodes trace `t` of the file `data` into `dst`: the first
  ## `min(t.sampleCount, dst.len)` samples, then zeros. `twosComplement` reads
  ## format-3 mantissas as two's complement. Raises `SegFormatError` for an
  ## invalid block or undefined format, and `SegTruncatedError` when the
  ## Data Block lies past the end of `data`.
  if not t.valid or t.format.isNone:
    raiseFormat("the trace is not decodable (" &
      (if t.valid: "sample format code " & $t.formatCode else: "damaged descriptor") & ")",
      t.offset)
  let n = min(t.sampleCount, dst.len)
  let fmt = t.format.get
  let nbytes = dataBytes(fmt, n)
  if t.dataOffset + nbytes > data.len:
    raiseTruncated("trace samples lie past the end of the file", t.dataOffset)
  if n > 0:
    let a = int(t.dataOffset)
    decodeSeg2Samples(fmt, data.toOpenArray(a, a + nbytes - 1), dst.toOpenArray(0, n - 1),
      f.order, twosComplement)
  for k in n ..< dst.len: dst[k] = T(0)
