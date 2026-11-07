## SEG-D Rev 1/2 header blocks (task 4.1), checked against 63.sgd.

import std/[assertions, os, strutils]
import parseSEGD/common/errors
import parseSEGD/segd/headers

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"

proc readBytes(name: string): seq[byte] =
  let s = readFile(exampleDir / name)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc checkNibbleTiling(fields: openArray[FieldSpec], blockBytes: int) =
  ## Every nibble of the block belongs to exactly one field.
  var owner = newSeq[string](2 * blockBytes)
  for f in fields:
    for n in f.firstNibble ..< f.firstNibble + f.nibbles:
      doAssert n < owner.len, f.name & " lies outside the block"
      doAssert owner[n] == "", f.name & " overlaps " & owner[n]
      owner[n] = f.name
  for i, o in owner:
    doAssert o != "", "nibble " & $i & " (byte " & $(i div 2 + 1) & ") is not covered"

block layouts_tile_their_blocks:
  checkNibbleTiling(generalHeader1Fields, 32)
  checkNibbleTiling(generalHeader2Fields, 32)
  checkNibbleTiling(generalHeaderNFields, 32)
  checkNibbleTiling(channelSetDescriptorFields, 32)
  checkNibbleTiling(traceHeaderFields, 20)
  checkNibbleTiling(traceHeaderExt1Fields, 32)

let f = readBytes("63.sgd")

block sample_63_headers:
  # Values from the verified walk (docs/spec/segd_rev2_0_delta.md §4).
  let g1 = decodeBlock[SegdGeneralHeader1](f.toOpenArray(0, 31))
  doAssert g1.fileNumber == 63 and g1.formatCode == 8058 and g1.year == 24
  doAssert g1.julianDay == 163 and g1.hour == 17 and g1.minute == 40 and g1.second == 2
  doAssert g1.manufacturerCode == 9 and g1.manufacturerSerial == 0
  doAssert g1.additionalGhBlocks == 2 and g1.generalHeaderCount == 3
  doAssert g1.baseScanInterval16 == 32 and g1.baseScanIntervalMs == 2.0
  doAssert g1.polarity == 0 and g1.recordType == 8 and g1.recordLength == BcdAllF
  doAssert g1.scanTypesPerRecord == 1 and g1.channelSetsPerScanType == 1
  doAssert g1.skewBlocks == 0 and g1.extendedHeaderBlocks == 3 and g1.externalHeaderBlocks == 0
  doAssert g1.invalidBcdFields.len == 0
  let g2 = decodeBlock[SegdGeneralHeader2](f.toOpenArray(32, 63))
  doAssert g2.extFileNumber == 63 and g2.extChannelSetsPerScanType == 1
  doAssert g2.extExtendedHeaderBlocks == 3 and g2.revisionMajor == 2 and g2.revisionMinor == 0
  doAssert g2.generalTrailerBlocks == 0 and g2.extRecordLength == 2000 and g2.blockNumber == 2
  doAssert recordLengthMs(g1, g2) == 2000.0 and fileNumber(g1, g2) == 63
  doAssert extendedHeaderBlocks(g1, g2) == 3 and channelSetsPerScanType(g1, g2) == 1
  let g3 = decodeBlock[SegdGeneralHeaderN](f.toOpenArray(64, 95))
  doAssert g3.blockNumber == 3 and g3.sourceLineNumber == 13.0
  doAssert g3.sourcePointNumber == 99.5 and g3.sourcePointIndex == 1 and g3.sourceSetNumber == 0
  let c = decodeBlock[SegdChannelSetDescriptor](f.toOpenArray(96, 127))
  doAssert c.scanTypeNumber == 1 and c.channelSetNumber == 1
  doAssert c.startTimeMs == 0.0 and c.endTimeMs == 2000.0 and c.mpFactor == 0.0
  doAssert c.channelCount == 1 and c.channelType == 1 and c.subscanExponent == 0
  doAssert c.gainControl == 3 and c.aliasFilterFreq == 207 and c.aliasFilterSlope == 461
  doAssert c.lowCutFreq == 1 and c.lowCutSlope == 6 and c.traceHeaderExtensions == 3
  doAssert c.verticalStack == 1 and c.arrayForming == 0
  doAssert c.sampleIntervalMs(g1) == 2.0
  let t = decodeBlock[SegdTraceHeader](f.toOpenArray(224, 243))
  doAssert t.fileNumber == 63 and t.scanTypeNumber == 1 and t.channelSetNumber == 1
  doAssert t.traceNumber == 1 and t.traceHeaderExtensions == 3 and t.traceEdit == 0
  doAssert t.extChannelSetNumber == 1 and t.extFileNumber == 63
  let e = decodeBlock[SegdTraceHeaderExt1](f.toOpenArray(244, 275))
  doAssert e.receiverLineNumber == 13 and e.receiverPointNumber == 104
  doAssert e.receiverPointIndex == 1 and e.samplesPerTrace == 1000 and e.sensorType == 2
  doAssert e.extReceiverLineNumber == 13.0 and e.extReceiverPointNumber == 104.0
  doAssert e.receiverLine == 13.0 and e.receiverPoint == 104.0
  # Unedited blocks re-encode byte for byte.
  doAssert g1.encoded == g1.raw and g2.encoded == g2.raw and g3.encoded == g3.raw
  doAssert c.encoded == c.raw and t.encoded == t.raw and e.encoded == e.raw
  for i in 0..31: doAssert g1.raw[i] == f[i]

block edits_touch_only_their_field:
  var g1 = decodeBlock[SegdGeneralHeader1](f.toOpenArray(0, 31))
  g1.julianDay = 7 # shares byte 12 with the binary additionalGhBlocks nibble
  let b = g1.encoded
  for i in 0..31:
    if i notin [11, 12]: doAssert b[i] == f[i]
  doAssert b[11] == 0x20 and b[12] == 0x07 # 2 | 0 0 7 (BCD 007)
  doAssert decodeBlock[SegdGeneralHeader1](b).julianDay == 7
  doAssert decodeBlock[SegdGeneralHeader1](b).additionalGhBlocks == 2
  g1.fileNumber = BcdAllF
  doAssert g1.encoded[0] == 0xFF and g1.encoded[1] == 0xFF
  g1.fileNumber = 12345
  doAssertRaises SegFormatError: discard g1.encoded

block invalid_bcd_and_undefined_bytes_survive:
  var raw = f[0..31]
  raw[14] = 0x7A # minute: "7A" is not BCD
  raw[19] = 0x55 # bytes 20-22 should be zero
  var g1 = decodeBlock[SegdGeneralHeader1](raw)
  doAssert g1.minute == BcdInvalid and g1.invalidBcdFields == @["minute"]
  g1.hour = 18
  let b = g1.encoded
  doAssert b[14] == 0x7A and b[19] == 0x55 and b[13] == 0x18

block fixed_point_and_mp:
  var g3 = SegdGeneralHeaderN(sourceLineNumber: -1.5, sourcePointNumber: 99.5, blockNumber: 3)
  let b = g3.encoded
  doAssert b[3..7] == @[0xFF'u8, 0xFF, 0xFE, 0x80, 0x00] # -2 + 0.5
  doAssert decodeBlock[SegdGeneralHeaderN](b).sourceLineNumber == -1.5
  g3.sourcePointNumber = 1.0 / 3.0 # not a multiple of 2^-16
  doAssertRaises SegFormatError: discard g3.encoded
  var c: SegdChannelSetDescriptor
  c.mpFactor = -3.5
  doAssert c.mpRaw == [0x00'u8, 0x8E] and c.mpFactor == -3.5
  c.mpFactor = 0.0009765625
  doAssert c.mpRaw == [0x01'u8, 0x00]
  var t = SegdTraceHeader(firstTimingWord: 1.03515625, timeBreakWindow: 2.0)
  let tb = t.encoded
  doAssert tb[6..8] == @[0x00'u8, 0x01, 0x09] and decodeBlock[SegdTraceHeader](tb).firstTimingWord == 1.03515625

block trailer_and_label:
  checkNibbleTiling(trailerBlockFields, 32)
  var tb = SegdTrailerBlock(trailerNumber: 1, channelType: 0xC)
  let b = tb.encoded
  doAssert b[0] == 0 and b[1] == 1 and b[10] == 0xC0
  doAssert not isStorageUnitLabel(f) # 63.sgd starts with GH1
  let text = align("1", 4) & "SD2.0" & "RECORD" & alignLeft("B1", 4) & align("0", 10) &
    align("163", 10) & "07-NOV-2026" & align("TAPE01", 12) & spaces(6) & align("TAPE01", 12) &
    alignLeft("CREW 7", 24) & spaces(14) & align("10", 10)
  doAssert text.len == 128, $text.len
  var raw = newSeq[byte](128)
  for i, c in text: raw[i] = byte(c)
  doAssert isStorageUnitLabel(raw)
  let l = decodeLabel(raw)
  doAssert l.storageUnitSeqNum == "1" and l.revision == "SD2.0" and l.structure == "RECORD"
  doAssert l.bindingEdition == "B1" and l.maxBlockSize == 0 and l.producerOrgCode == "163"
  doAssert l.creationDate == "07-NOV-2026" and l.serialNumber == "TAPE01"
  doAssert l.recordingEntityName == "CREW 7" and l.maxShotsPerFieldRecord == "10"
  doAssert not l.isFixedRecord
