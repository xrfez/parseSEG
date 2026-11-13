## Format detection (`detectKind`): SEG-Y whose textual header is not `C`
## card text, recognized by its binary header, with and without a tape
## label; what is still not SEG-Y; and every SEG-D, SEG-2 and SEG-Y file at
## hand keeping its kind.

import std/[assertions, os, strutils]
import parseSEG/common/[diagnostics, endians, seismickind, tensors]
import parseSEG/io/[memsource, diskio]
import parseSEG/segy/[reader as segyreader, writer as segywriter]
import parseSEG/model/[traceindex, indextypes]
import ./utils/testutils

let tmp = scratchDir("parseseg_tdetect")
let base = readFile(demoDir() / "survey.sgy") # Rev 2.1, 200 traces of 2001 samples

proc head(s: string): seq[byte] = toBytes(s[0 ..< min(s.len, 8192)])

proc withText(s: string, fill: proc (i: int): char): string =
  ## `s` with the 3200 bytes of its textual header replaced.
  result = s
  for i in 0 ..< 3200: result[i] = fill(i)

const
  freeText = "SEG-Y written by some tool; line 7; no card numbering.                          "
  card1 = "C 1 CLIENT ACME  LINE 7"

let variants = [
  ("ebcdic_blank", withText(base, proc (i: int): char = '\x40')),
  ("ascii_blank", withText(base, proc (i: int): char = ' ')),
  ("zero_filled", withText(base, proc (i: int): char = '\0')),
  ("free_text", withText(base, proc (i: int): char = freeText[i mod 80])),
  ("lowercase_c", withText(base, proc (i: int): char = (if i mod 80 == 0: 'c' else: ' '))),
  ("c_cards_nul_padded", withText(base, proc (i: int): char =
    (if i < card1.len: card1[i] elif i mod 80 == 0: 'C' else: '\0')))]

proc notCardText(log: DiagLog): int =
  for d in log:
    if d.severity == sevInfo and d.code == dcBadValue and "not card text" in d.msg:
      doAssert d.loc.field == "text"
      inc result

block card_text_is_segy_without_a_note:
  doAssert detectKind(head(base)) == skSegy
  var f = openSeismic(demoDir() / "survey.sgy")
  doAssert f.kind == skSegy and f.len == 200 and f.log.notCardText == 0
  f.close()

block textual_header_that_is_not_card_text:
  # Blank, zero-filled, free text, a lower-case c, C cards padded with NUL:
  # the streaming reader always read these; `openSeismic` said "not a SEG-Y,
  # SEG-D or SEG-2 file", since only `C` card text made a file SEG-Y.
  var whole = openSeismic(demoDir() / "survey.sgy")
  let want = whole.readTraces(0 ..< whole.len)
  whole.close()
  for (name, bytes) in variants:
    doAssert detectKind(head(bytes)) == skSegy, name
    let p = tmp / (name & ".sgy")
    writeFile(p, bytes)
    for verify in [vfSampled, vfFull]:
      var f = openSeismic(p, opts = OpenOptions(verify: verify))
      doAssert f.kind == skSegy and f.len == 200 and not f.log.hasErrors, name & " " & $f.log
      # The reader says so, once, unless the header starts with a C card.
      doAssert f.log.notCardText == (if name == "c_cards_nul_padded": 0 else: 1), name
      doAssert f.readTraces(0 ..< f.len) == want, name
      f.close()
    let d = readSegy(p)
    doAssert d.traces.len == 200 and not d.log.hasErrors and d.file.tapeLabel.len == 0, name

block little_endian_binary_header_behind_a_blank_text:
  let d = readSegy(demoDir() / "survey.sgy")
  let le = tmp / "le.sgy"
  let sink = openDiskSink(le)
  var w = openSegyWriter(sink, d.file, SegyWriteOptions(byteOrder: boLittle))
  for t in d.traces: w.writeTrace(t)
  w.close()
  sink.close()
  let bytes = withText(readFile(le), proc (i: int): char = ' ')
  doAssert detectKind(head(bytes)) == skSegy
  writeFile(le, bytes)
  var f = openSeismic(le)
  doAssert f.kind == skSegy and f.len == 200 and not f.log.hasErrors
  doAssert f.index.segy.byteOrder == boLittle
  f.close()

block tape_label_before_a_blank_textual_header:
  # The binary header sits at 3328, behind the label; the reader keeps the
  # label although no C card follows it.
  var label = "   1SY2.1RECORD"
  label.setLen 128
  for i in 15 ..< 128: label[i] = ' '
  for (name, text) in [("blank", variants[0][1]), ("zeros", variants[2][1]),
      ("text", variants[3][1])]:
    let bytes = label & text
    doAssert detectKind(head(bytes)) == skSegy, name
    let p = tmp / ("label_" & name & ".sgy")
    writeFile(p, bytes)
    var f = openSeismic(p)
    doAssert f.kind == skSegy and f.len == 200 and not f.log.hasErrors, name & " " & $f.log
    doAssert f.index.segy.tapeLabel == toBytes(label) and f.log.notCardText == 1, name
    doAssert f.traceEntry(0).offset == 128 + f.index.segy.firstTraceOffset - 128
    doAssert f.index.segy.binary.samplesPerTrace == 2001
    f.close()
  # The label's marks alone do not make SEG-Y of other data.
  var junk = label & newString(8000)
  doAssert detectKind(head(junk)) == skUnknown

block free_text_that_starts_like_a_label_is_no_label:
  # "   1SY" opens the textual header itself: the binary header is at 3200.
  let bytes = withText(base, proc (i: int): char = (if i < 6: "   1SY"[i] else: ' '))
  doAssert detectKind(head(bytes)) == skSegy
  let p = tmp / "sy_text.sgy"
  writeFile(p, bytes)
  let d = readSegy(p)
  doAssert d.file.tapeLabel.len == 0 and d.traces.len == 200 and not d.log.hasErrors

block not_segy:
  # Without card text, only a binary header with a defined format code and a
  # sample interval and count above 0 makes SEG-Y.
  doAssert detectKind(newSeq[byte](8192)) == skUnknown
  doAssert detectKind(toBytes(repeat(' ', 8192))) == skUnknown
  doAssert detectKind(toBytes(repeat("lorem ipsum dolor sit amet ", 300))) == skUnknown
  let blank = variants[1][1]
  doAssert detectKind(toBytes(blank[0 ..< 3599])) == skUnknown # no whole binary header
  for (at, what) in [(3224, "format code"), (3216, "sample interval"), (3220, "sample count")]:
    var b = blank
    b[at] = '\0'
    b[at + 1] = '\0'
    if at == 3216: # and the Rev 2 extended interval, which would override it
      for i in 3272 ..< 3280: b[i] = '\0'
    elif at == 3220:
      for i in 3268 ..< 3272: b[i] = '\0'
    doAssert detectKind(head(b)) == skUnknown, what
  var b = blank
  b[3224] = '\0'
  b[3225] = '\x0D' # 13 is no format code in any revision
  doAssert detectKind(head(b)) == skUnknown
  # Deterministic noise: none of 20000 heads is taken for anything.
  var s = 12345'u32
  var noise = newSeq[byte](3728)
  var taken = 0
  for round in 0 ..< 20000:
    for i in 0 ..< noise.len:
      s = s * 1664525'u32 + 1013904223'u32
      noise[i] = byte(s shr 24)
    if detectKind(noise) != skUnknown: inc taken
  doAssert taken <= 20, $taken # binary header odds: about 28 format codes in 65536

block a_known_standard_can_be_forced:
  # What `OpenOptions.kind` is for: a file detection refuses is read as the
  # standard the caller names, and gets that reader's diagnostics.
  var b = variants[1][1]
  b[3224] = '\0'
  b[3225] = '\x0D'
  let p = tmp / "format13.sgy"
  writeFile(p, b)
  doAssert detectKind(head(b)) == skUnknown
  doAssert OpenOptions().kind == skUnknown
  let src = openMemFileSource(p)
  let ix = buildIndex(src, skSegy)
  src.close()
  doAssert ix.kind == skSegy and ix.detected and ix.log.isFatal
  doAssert ix.log.has("format code 13 is undefined", sevFatal)
  # Through `openSeismic`: undetected without the option, read as named with it.
  var plain = openSeismic(p)
  doAssert plain.kind == skUnknown
  plain.close()
  var f = openSeismic(p, opts = OpenOptions(kind: skSegy))
  doAssert f.kind == skSegy and f.log.has("format code 13 is undefined", sevFatal)
  f.close()
  # A file that is detected opens the same with its own kind named.
  let q = tmp / "named.sgy"
  writeFile(q, variants[1][1])
  var g = openSeismic(q, opts = OpenOptions(kind: skSegy))
  var h = openSeismic(q)
  doAssert g.kind == skSegy and g.len == h.len and g.len > 0
  g.close()
  h.close()

block every_file_at_hand_keeps_its_kind:
  # No SEG-D or SEG-2 file is taken for SEG-Y through its "binary header"
  # bytes, and no SEG-Y file for anything else.
  var files: seq[string]
  for n in ["survey.sgy", "shot.sgd", "record.sgd", "line.sg2"]: files.add demoDir() / n
  for dir in [exampleDir, currentSourcePath().parentDir.parentDir / "bench" / "data"]:
    for p in walkFiles(dir / "*"): files.add p
  var checked = 0
  for p in files:
    let want = case p.splitFile.ext.toLowerAscii
      of ".sgy", ".segy": skSegy
      of ".sgd", ".segd": skSegd
      of ".sg2", ".dat": skSeg2
      else: skUnknown
    if want != skUnknown:
      var f: File
      doAssert open(f, p)
      var b = newSeq[byte](8192)
      b.setLen f.readBytes(b, 0, b.len)
      f.close()
      doAssert detectKind(b) == want, p
      inc checked
  doAssert checked >= 4
  echo "tdetect: ", checked, " files keep their kind"
