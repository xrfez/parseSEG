## SEG-2 writer (spec note `seg2.md` §2, §3, §6.4): streams a File Descriptor
## Block and one Trace Descriptor Block plus Data Block per trace to a disk
## file, then fills in the trace pointers.
##
## ```nim
## var fdb = initSeg2File()
## fdb.traceCount = 24          # sizes the Trace Pointer Subblock
## fdb["UNITS"] = "METERS"
## var w = openSeg2Writer("shot.dat", fdb)
## var t = Seg2Trace(formatCode: 4)
## t["SAMPLE_INTERVAL"] = formatNumber(0.00025)
## w.writeTrace(t, samples)     # floats, encoded in the trace's format
## w.close()                    # writes N and the pointers
## ```
##
## Layout (the same bytes a reader of this module's output writes back, so
## a file read and rewritten is byte-identical):
## - the fixed parts are written from `Seg2File` / `Seg2Trace` (order,
##   revision, terminators, sizes, format code); reserved bytes are 0;
## - the Trace Pointer Subblock has M = `max(pointerBytes, 4 * traceCount)`
##   bytes, rounded up to 4; unused pointers are 0;
## - each string is `KEYWORD value` (one space; the keyword alone when the
##   value is empty), then the String Terminator; its offset word is the
##   entry's length, these 2 bytes included; the list ends with a 0 word and
##   is zero-padded to 4 bytes;
## - traces follow each other in the order written, each Data Block
##   zero-padded to 4 bytes.
##
## Strings keep the order given (`sortStrings` gives the standard's order).
##
## Validation: output a reader would misread or the standard forbids (a
## keyword with blanks or a value holding the String Terminator, a block or
## entry too large for its 16-bit size, an undefined format code, too many
## traces) is refused with `SegFormatError` unless `lenient`; then it is
## logged as a warning and written as asked. Caller errors (more traces than
## the pointer subblock holds, too few sample bytes) raise `ValueError`.

import std/strutils
import ../common/[errors, diagnostics]
import ./[headers, samples]
export headers, diagnostics
export samples except decodeSeg2SamplesRaw

type
  Seg2WriteOptions* = object
    ## Options of `openSeg2Writer`.
    lenient*: bool ## Log problems instead of refusing to write.

  Seg2Writer* = object
    ## Writer state; create with `openSeg2Writer`.
    file: File
    path: string
    opts: Seg2WriteOptions
    fdb: Seg2File
    capacity: int          ## Trace pointers the subblock holds (M / 4).
    pointers: seq[uint32]
    pos: int64             ## Bytes written so far.
    buf: seq[byte]
    log: DiagLog
    open: bool

func log*(w: Seg2Writer): lent DiagLog {.inline.} =
  ## The problems logged so far (warnings, unless a write was refused).
  w.log

func len*(w: Seg2Writer): int {.inline.} =
  ## Traces written so far.
  w.pointers.len

proc problem(w: var Seg2Writer, msg: string, trace = -1, field = "") =
  let loc = Location(file: w.path, trace: trace, field: field)
  if w.opts.lenient:
    w.log.report(sevWarning, dcValidation, msg, loc = loc)
  else:
    w.log.report(sevError, dcValidation, msg, loc = loc)
    raiseFormat("refusing to write SEG-2 the standard forbids: " & msg)

func roundUp4(n: int64): int64 {.inline.} = (n + 3) div 4 * 4

func entryText(s: Seg2String): string =
  if s.value.len == 0: s.key else: s.key & " " & s.value

proc checkTerminator(w: var Seg2Writer, t, what: string) =
  if t.len notin 1..2:
    w.problem("the " & what & " has " & $t.len & " characters, not 1 or 2", field = what)
  for c in t:
    if ord(c) > 31:
      w.problem("the " & what & " character 0x" & toHex(ord(c), 2) &
        " is not a control character (0-31)", field = what)

proc checkStrings(w: var Seg2Writer, s: openArray[Seg2String], trace: int) =
  for x in s:
    if x.key.len == 0 or x.key.contains({' ', '\t'}):
      w.problem("keyword " & x.key.escape & " is empty or holds a blank", trace, x.key)
    let text = entryText(x)
    if w.fdb.stringTerm.len > 0 and text.contains(w.fdb.stringTerm):
      w.problem(x.key & ": the value holds the String Terminator, so readers would cut it",
        trace, x.key)
    if 2 + text.len + w.fdb.stringTerm.len > int(high(uint16)):
      w.problem(x.key & ": the string is " & $text.len & " bytes, too long for its 16-bit " &
        "offset", trace, x.key)

proc stringList(s: openArray[Seg2String], f: Seg2File, dst: var seq[byte]) =
  # Appends the list, its 0 end word and the padding to 4 bytes.
  for x in s:
    let text = entryText(x)
    let at = dst.len
    let n = 2 + text.len + f.stringTerm.len
    dst.setLen at + 2
    putNum(dst, at, uint16(n and 0xFFFF), f.order)
    for c in text: dst.add byte(c)
    for c in f.stringTerm: dst.add byte(c)
  dst.add [0'u8, 0]
  while dst.len mod 4 != 0: dst.add 0

proc put(w: var Seg2Writer, b: openArray[byte]) =
  if b.len > 0 and w.file.writeBytes(b, 0, b.len) != b.len:
    raise newException(IOError, "cannot write " & w.path)
  w.pos += b.len

proc openSeg2Writer*(path: string, f: Seg2File, opts = Seg2WriteOptions()): Seg2Writer =
  ## Creates `path` and writes the File Descriptor Block of `f`: its order,
  ## revision, terminators and strings, and a Trace Pointer Subblock of
  ## `max(f.pointerBytes, 4 * f.traceCount)` bytes (rounded up to 4), which
  ## bounds the traces the file can take. `f.pointers` is ignored: `close`
  ## writes the real ones. Raises `ValueError` when that size is 0 or above
  ## 65532, `IOError` when `path` cannot be written, and `SegFormatError`
  ## for a block the standard forbids (unless `opts.lenient`).
  let m = roundUp4(max(int64(f.pointerBytes), 4 * int64(f.traceCount)))
  if m < 4 or m > 65532:
    raise newException(ValueError, "the Trace Pointer Subblock would be " & $m &
      " bytes; set traceCount (1.." & $Seg2MaxTraces & ") or pointerBytes (4..65532)")
  result = Seg2Writer(path: path, opts: opts, fdb: f, capacity: int(m div 4))
  result.fdb.pointerBytes = uint16(m)
  result.checkTerminator(f.stringTerm, "String Terminator")
  result.checkTerminator(f.lineTerm, "Line Terminator")
  if f.revision != 1:
    result.problem("revision " & $f.revision & " is not defined (the standard is revision 1)",
      field = "revision")
  if result.capacity > Seg2MaxTraces:
    result.problem($result.capacity & " trace pointers exceed the standard's " &
      $Seg2MaxTraces, field = "pointerBytes")
  result.checkStrings(f.strings, -1)
  var b = newSeq[byte](Seg2FixedSize + int(m))
  let o = f.order
  putNum(b, 0, Seg2FileBlockId, o)
  putNum(b, 2, f.revision, o)
  putNum(b, 4, uint16(m), o)
  b[8] = byte(min(f.stringTerm.len, 2))
  for k in 0 ..< min(f.stringTerm.len, 2): b[9 + k] = byte(f.stringTerm[k])
  b[11] = byte(min(f.lineTerm.len, 2))
  for k in 0 ..< min(f.lineTerm.len, 2): b[12 + k] = byte(f.lineTerm[k])
  stringList(f.strings, f, b)
  if not open(result.file, path, fmWrite): raise newException(IOError, "cannot write " & path)
  result.open = true
  try:
    result.put(b)
  except IOError:
    result.file.close()
    result.open = false
    raise

proc writeBlock(w: var Seg2Writer, t: Seg2Trace, fmtCode: uint8, numSamples: int,
    data: openArray[byte]) =
  # The descriptor of `t` with the given sizes, then `data` padded to 4.
  let trace = w.pointers.len
  if trace >= w.capacity:
    raise newException(ValueError, "the Trace Pointer Subblock holds " & $w.capacity &
      " traces; open the writer with a larger traceCount")
  if toSeg2Format(int(fmtCode)).isNone:
    w.problem("sample format code " & $fmtCode & " is not defined (1-5)", trace, "formatCode")
  w.checkStrings(t.strings, trace)
  w.buf.setLen Seg2FixedSize
  for k in 0 ..< Seg2FixedSize: w.buf[k] = 0
  stringList(t.strings, w.fdb, w.buf)
  let o = w.fdb.order
  if w.buf.len > 65532:
    w.problem("the Trace Descriptor Block is " & $w.buf.len & " bytes; at most 65532 fit " &
      "its 16-bit size (shorten the strings)", trace, "blockSize")
  let dataSize = roundUp4(data.len)
  if dataSize > int64(high(uint32)):
    raise newException(ValueError, "a Data Block of " & $dataSize & " bytes exceeds 4 GiB")
  putNum(w.buf, 0, Seg2TraceBlockId, o)
  putNum(w.buf, 2, uint16(w.buf.len and 0xFFFF), o)
  putNum(w.buf, 4, uint32(dataSize), o)
  putNum(w.buf, 8, uint32(numSamples), o)
  w.buf[12] = fmtCode
  if w.pos > int64(high(uint32)):
    raise newException(ValueError, "trace " & $trace & " would start past 4 GiB, which a " &
      "32-bit trace pointer cannot address")
  w.pointers.add uint32(w.pos)
  w.put(w.buf)
  w.put(data)
  const zeros = [0'u8, 0, 0]
  w.put(zeros.toOpenArray(0, int(dataSize - data.len) - 1))

proc writeTrace*(w: var Seg2Writer, t: Seg2Trace, data: openArray[byte]) =
  ## Writes trace `t` with `data` as its Data Block (padded to 4 bytes):
  ## its strings, `formatCode` and `numSamples` are written as they are;
  ## `offset`, `blockSize` and `dataSize` follow from the layout. Raises
  ## `ValueError` when the file is full or, for a defined format, `data` is
  ## shorter than `numSamples` samples; `IOError` on a write failure;
  ## `SegFormatError` for a block the standard forbids (unless lenient).
  if not w.open: raise newException(ValueError, "the writer is closed")
  let fmt = t.format
  if fmt.isSome and data.len < dataBytes(fmt.get, int(t.numSamples)):
    raise newException(ValueError, "the Data Block has " & $data.len & " bytes, " &
      $dataBytes(fmt.get, int(t.numSamples)) & " needed for " & $t.numSamples & " samples")
  w.writeBlock(t, t.formatCode, int(t.numSamples), data)

proc writeTrace*[T: Seg2SampleType](w: var Seg2Writer, t: Seg2Trace, samples: openArray[T],
    twosComplement = false) =
  ## Writes trace `t` with `samples` encoded in its format (`numSamples` is
  ## `samples.len`; `twosComplement` writes format-3 mantissas as two's
  ## complement). Raises `SegFormatError` for a value the format cannot hold
  ## or an undefined format code, otherwise like the raw `writeTrace`.
  if not w.open: raise newException(ValueError, "the writer is closed")
  let fmt = t.format
  if fmt.isNone:
    raiseFormat("sample format code " & $t.formatCode & " is not defined (1-5)")
  var data = newSeq[byte](dataBytes(fmt.get, samples.len))
  encodeSeg2Samples(fmt.get, samples, data, w.fdb.order, twosComplement)
  w.writeBlock(t, t.formatCode, samples.len, data)

proc close*(w: var Seg2Writer) =
  ## Writes the trace count and pointers into the File Descriptor Block and
  ## closes the file. The file is closed even when that fails (`IOError`).
  ## A file without traces is refused (`SegFormatError`) unless lenient.
  if not w.open: return
  w.open = false
  try:
    if w.pointers.len == 0:
      w.problem("the file has no traces (the standard wants at least one)", field = "traceCount")
    let o = w.fdb.order
    var b = newSeq[byte](2)
    putNum(b, 0, uint16(w.pointers.len), o)
    w.file.setFilePos(6)
    if w.file.writeBytes(b, 0, 2) != 2: raise newException(IOError, "cannot write " & w.path)
    b.setLen 4 * w.pointers.len
    for i, p in w.pointers: putNum(b, 4 * i, p, o)
    w.file.setFilePos(Seg2FixedSize)
    if b.len > 0 and w.file.writeBytes(b, 0, b.len) != b.len:
      raise newException(IOError, "cannot write " & w.path)
    w.file.flushFile()
  finally:
    w.file.close()
