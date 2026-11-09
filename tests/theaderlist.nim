## Header listing (task 6.10): `traceHeaders`, `recordHeaders`,
## `fileHeaders`, and viewer change sets saved with `writeHeaderPatch`.

import std/[assertions, os, strutils, math]
import parseSEG

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_theaderlist"
createDir(tmp)

const
  s63 = exampleDir / "63.sgd"
  inova = exampleDir / "inova_rev30_5traces.sgd"
  inglewood = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"

proc blocksOf(l: openArray[HeaderRow]): seq[string] =
  ## The block names in listing order, once each.
  for r in l:
    if result.len == 0 or result[^1] != r.blockName: result.add r.blockName

proc row(l: openArray[HeaderRow], name: string): HeaderRow =
  for r in l:
    if r.blockName & "." & r.field == name: return r
  raiseAssert "no row " & name

proc checkTiling(l: openArray[HeaderRow]) =
  ## Every row lies inside its block, and the blocks do not overlap.
  var lastEnd = -1'i64
  var lastBlock = ""
  for r in l:
    doAssert r.offset >= r.blockOffset and r.offset + r.size <= r.blockOffset + r.blockSize, $r
    doAssert r.size > 0 and r.blockSize > 0
    if r.blockName != lastBlock:
      doAssert r.blockOffset >= lastEnd, r.blockName
      lastEnd = r.blockOffset + r.blockSize
      lastBlock = r.blockName

block segd_rev2_trace_and_record:
  let before = readFile(s63)
  let f = openSeismic(s63)
  let e = f.traceEntry(0)
  let t = f.traceHeaders(0)
  doAssert t.blocksOf[0 .. 1] == @["trace", "ext1"]
  checkTiling(t)
  let fileNumber = t.row("trace.fileNumber")
  doAssert fileNumber.kind == hbSegdTrace and fileNumber.offset == e.offset and fileNumber.size == 2
  doAssert fileNumber.blockOffset == e.offset and fileNumber.blockSize == 20
  let rl = t.row("ext1.receiverLineNumber")
  doAssert rl.kind == hbSegdExt1 and rl.offset == e.offset + 20 and rl.size == 3
  # The same names and values as `traceField` (and so the editor and NIF).
  for r in t:
    if r.blockName in ["trace", "ext1"]:
      doAssert f.traceField(0, r.blockName & "." & r.field) == r.value, r.field
  for name in fieldNames(hbSegdTrace):
    discard t.row("trace." & name)
  # Extensions after #1: raw rows.
  for r in t:
    if r.blockName.startsWith("ext") and r.blockName != "ext1":
      doAssert r.kind == hbRaw and r.field == "" and r.value.text == "traceHeaderExtension"
      doAssert r.blockSize == 32
  let rec = f.recordHeaders(0)
  checkTiling(rec)
  let blocks = rec.blocksOf
  doAssert blocks[0 .. 3] == @["gh1", "gh2", "gh3", "st1cs1"], $blocks
  let r0 = f.index.segdRecords[0].offset
  doAssert rec.row("gh1.fileNumber").blockOffset == r0
  doAssert rec.row("gh2.revisionMajor").kind == hbSegdGh2 and
    rec.row("gh2.revisionMajor").value == toFieldValue(2)
  doAssert rec.row("gh3.sourcePointNumber").value == toFieldValue(99.5)
  doAssert rec.row("gh3.sourcePointNumber").blockOffset == r0 + 64
  let cs = rec.row("st1cs1.channelSetNumber")
  doAssert cs.kind == hbSegdChannelSet and cs.value == toFieldValue(1) and cs.blockOffset == r0 + 96
  # BCD nibble fields: the bytes their nibbles touch (julianDay: bytes 12L-13).
  let jd = rec.row("gh1.julianDay")
  doAssert jd.offset == r0 + 11 and jd.size == 2
  for r in rec:
    if r.blockName in ["gh1", "gh3"]:
      doAssert f.recordField(0, r.blockName & "." & r.field) == r.value, r.field
  doAssert f.fileHeaders.len == 0 # no storage unit label
  # A hex pane: the block's bytes.
  doAssert f.copyBytes(cs.blockOffset, cs.blockSize).len == 32
  doAssert readFile(s63) == before # listing never writes
  doAssertRaises(ValueError): discard f.traceHeaders(1)
  doAssertRaises(ValueError): discard f.recordHeaders(1)
  doAssertRaises(ValueError): discard f.traceHeaders(-1)

block segd_rev3_blocks:
  let f = openSeismic(inova, keys = true)
  let t = f.traceHeaders(3)
  checkTiling(t)
  let blocks = t.blocksOf
  doAssert blocks[0 .. 2] == @["trace", "ext1", "ext2"], $blocks
  doAssert t.row("ext1.receiverLineNumber").kind == hbSegdExt1Rev3
  for r in t:
    if r.blockName in ["trace", "ext1"]:
      doAssert f.traceField(3, r.blockName & "." & r.field) == r.value, r.field
    elif r.kind == hbRaw:
      doAssert r.value.text == "userDefined" and r.blockSize == 32 # INOVA's 0xB0-0xB8 blocks
  # A Position block (0x50-0x52) counts as three extensions: ext2 to ext4.
  doAssert t.row("ext2.tuple1Coord1").kind == hbSegdPosition and "ext3" notin blocks
  doAssert blocks[^1] == "ext" & $(int(f.traceEntry(3).headerBytes - 20) div 32)
  let rec = f.recordHeaders(0)
  checkTiling(rec)
  let rb = rec.blocksOf
  # GH#1-#3, then 14 typed general blocks (0x10-0x14, five 0x55, one
  # Position spanning three, one explosive source), then 4 descriptors.
  doAssert rb[0 .. 3] == @["gh1", "gh2", "gh3", "gh4"], $rb
  doAssert rec.row("gh2.revisionMajor").kind == hbSegdGh2Rev3
  doAssert rec.row("gh3.timeZero").value == toFieldValue(1474994765504000'i64)
  doAssert rec.row("gh4.").value.text == "vesselCrew"
  doAssert rec.row("gh9.").value.text == "crs"
  let pos = rec.row("gh14.tuple1Coord1")
  doAssert pos.kind == hbSegdPosition and pos.blockSize == 96 and pos.size == 8
  doAssert "gh15" notin rb and "gh16" notin rb # inside the Position block
  let src = rec.row("gh17.sourceLineNumber")
  doAssert src.kind == hbSegdSourceDescription
  doAssert src.value.toFloat == f.traceKeys(3).srcLine
  for k in 1..4:
    let c = rec.row("st1cs" & $k & ".channelSetNumber")
    doAssert c.kind == hbSegdChannelSetRev3 and c.value == toFieldValue(k) and c.blockSize == 96
  doAssert fieldNames(hbSegdPosition)[0] == "timeOfPosition" and fieldNames(hbRaw).len == 0

block segy_file_and_trace:
  let f = openSeismic(inglewood)
  let fh = f.fileHeaders
  checkTiling(fh)
  doAssert fh.blocksOf == @["text", "binary", "extended"], $fh.blocksOf
  doAssert fh.row("text.").blockOffset == 0 and fh.row("text.").blockSize == 3200
  let fmt = fh.row("binary.formatCode")
  doAssert fmt.kind == hbSegyBinary and fmt.offset == 3224 and fmt.size == 2
  doAssert fmt.value == toFieldValue(1)
  for r in fh:
    if r.blockName == "binary":
      doAssert f.fileField("binary." & r.field) == r.value, r.field
  doAssert fh.row("extended.").blockOffset == 3600 and
    fh.row("extended.").blockSize == f.index.segy.extended.recordCount * 3200
  let t = f.traceHeaders(5)
  doAssert t.blocksOf == @["trace"]
  let sx = t.row("trace.sourceX")
  doAssert sx.value == toFieldValue(1704188) and sx.offset == f.traceEntry(5).offset + 72 and
    sx.size == 4
  doAssert t.len == fieldNames(hbSegyTrace).len
  doAssert f.recordHeaders(0).len == 0 # SEG-Y has no record headers
  doAssertRaises(ValueError): discard f.recordHeaders(1)

block segy_extensions:
  # Ext1 plus one proprietary 240-byte header per trace.
  var d = readSegy(inglewood)
  var file = SegyFile(text: d.file.text, binary: d.file.binary, byteOrder: boBig,
    format: d.file.format, extended: initExtendedTextHeader(),
    trailer: initExtendedTextHeader())
  file.binary.numExtTextHeaders = 0
  file.binary.maxAddlTraceHeaders = 2
  let path = tmp / "ext2.sgy"
  block write:
    let sink = openDiskSink(path)
    var w = openSegyWriter(sink, file, initSegyWriteOptions(file, lenient = true))
    for k in 0..<2:
      var t = d.traces[k]
      t.hasExt1 = true
      t.ext1 = initTraceHeaderExt1()
      t.ext1.numAddlTraceHeaders = 2
      t.ext1.nanoseconds = 7
      t.proprietary = newSeq[byte](240)
      w.writeTrace(t)
    w.close()
    sink.close()
  var f = openSeismic(path)
  doAssert f.len == 2 and f.log.len == 0
  let t = f.traceHeaders(1)
  checkTiling(t)
  doAssert t.blocksOf == @["trace", "ext1", "ext2"]
  doAssert t.row("ext1.nanoseconds").value == toFieldValue(7)
  doAssert t.row("ext2.").value.text == "proprietary" and t.row("ext2.").blockSize == 240
  f.close()
  doAssertRaises(ValueError): discard f.traceHeaders(0)
  doAssertRaises(ValueError): discard f.fileHeaders

block unknown_file:
  let junk = tmp / "junk.bin"
  writeFile(junk, repeat('\0', 5000))
  let f = openSeismic(junk)
  doAssert f.fileHeaders.len == 0
  doAssertRaises(ValueError): discard f.recordHeaders(0)

block header_patch_round_trip:
  # A viewer's edits, saved as a patch and applied by an explicit import.
  let f = openSeismic(inglewood)
  var p: seq[HeaderChange]
  p.add initHeaderChange(hsTrace, 5, "trace.sourceX", toFieldValue(1_700_000))
  p.add initHeaderChange(hsTrace, 5, "trace.groupX", toFieldValue(3))
  p.add initHeaderChange(hsFile, 0, "binary.jobId", toFieldValue(7))
  p.add initHeaderChange(hsTrace, 0, "trace.headerName", toFieldValue("A\"B"))
  p.add initHeaderChange(hsTrace, 5, "trace.sourceX", toFieldValue(1_700_001)) # the last change wins
  doAssert p.len == 5
  let patch = tmp / "viewer.nif"
  writeHeaderPatch(p, patch)
  let text = readFile(patch)
  doAssert text.startsWith("(.nif27)") and "(standard" notin text
  doAssert "(trace 5 (block trace (f sourceX 1700000) (f groupX 3)))" in text, text
  doAssert "(file (block binary (f jobId 7)))" in text
  let before = readFile(inglewood)
  let dry = importHeaders(inglewood, patch, ImportOptions(dryRun: true))
  doAssert dry.applied == 5 and dry.refused == 0 and dry.log.len == 0, $dry.log
  doAssert readFile(inglewood) == before
  let copy = tmp / "patched.sgy"
  let r = importHeaders(inglewood, patch, ImportOptions(outPath: copy))
  doAssert r.applied == 5 and not r.log.hasErrors, $r.log
  let g = openSeismic(copy)
  doAssert g.traceHeaders(5).row("trace.sourceX").value == toFieldValue(1_700_001)
  doAssert g.traceHeaders(5).row("trace.groupX").value == toFieldValue(3)
  doAssert g.fileHeaders.row("binary.jobId").value == toFieldValue(7)
  doAssert g.traceField(0, "trace.headerName").text.startsWith("A\"B")
  doAssert readFile(inglewood) == before
  # Floats and the special values survive the NIF form.
  let q = [initHeaderChange(hsRecord, 0, "gh3.sourcePointNumber", toFieldValue(12.25)),
    initHeaderChange(hsTrace, 0, "trace.firstTimingWord", toFieldValue(NaN))]
  writeHeaderPatch(q, tmp / "floats.nif")
  let ft = readFile(tmp / "floats.nif")
  doAssert "(record 0 (block gh3 (f sourcePointNumber 12.25)))" in ft and "(nan)" in ft
  # Malformed names and indices are refused, and nothing is written.
  for name in ["trace", "trace.", ".x", "a.b.c", "trace.so urce", "1x.y", "x.(y)"]:
    doAssertRaises(ValueError): discard initHeaderChange(hsTrace, 0, name, toFieldValue(1))
  doAssertRaises(ValueError): discard initHeaderChange(hsTrace, -1, "trace.sourceX", toFieldValue(1))
  doAssertRaises(ValueError): discard initHeaderChange(hsFile, 1, "binary.jobId", toFieldValue(1))
  doAssertRaises(ValueError):
    writeHeaderPatch([HeaderChange(scope: hsTrace, index: 0, name: "bogus")], tmp / "bad.nif")
  doAssert not fileExists(tmp / "bad.nif")
  doAssertRaises(IOError): writeHeaderPatch(p, tmp / "no-such-dir" / "x.nif")
  # A patch to a block the editor cannot reach is refused by the import,
  # with the reason in its log.
  writeHeaderPatch([initHeaderChange(hsRecord, 0, "gh2.extFileNumber", toFieldValue(5))],
    tmp / "gh2.nif")
  let r2 = importHeaders(s63, tmp / "gh2.nif", ImportOptions(dryRun: true))
  doAssert r2.applied == 0 and r2.log.hasErrors

block large_sample_local_only:
  let big = exampleDir / "00000151_12900_11300.sgd"
  if fileExists(big):
    let f = openSeismic(big)
    let t = f.traceHeaders(2000)
    checkTiling(t)
    doAssert t.row("trace.traceNumber").value == f.traceField(2000, "trace.traceNumber")
    checkTiling(f.recordHeaders(0))

echo "theaderlist: ok"
