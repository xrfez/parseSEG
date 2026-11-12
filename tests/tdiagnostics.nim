## Tests for the diagnostics log: counts, formatting, the exception boundary,
## and NIF round trips.

import std/[assertions, os, strutils]
import parseSEG/common/[errors, diagnostics]

proc sampleLog(): DiagLog =
  result = DiagLog()
  result.report(sevInfo, dcVendorBlock, "block 0xB0 kept raw",
    offset = 1024, loc = Location(record: 0, trace: 5, blockIndex: 2))
  result.report(sevWarning, dcBadValue, "format code 0 is not defined",
    offset = 4340, loc = Location(file: "a dir/63.sgd", record: 0, field: "GH1.formatCode"))
  result.report(sevError, dcUnsupportedFormat,
    "tricky \"quotes\" (parens) [brackets] #hash 'tick' back\\slash\nnewline\ttab ünïcode",
    loc = Location(channelSet: 1, trace: 0))
  result.report(sevFatal, dcTruncated, "")

block counts_and_queries:
  let log = sampleLog()
  doAssert log.len == 4
  doAssert log.count(sevInfo) == 1
  doAssert log.count(sevFatal) == 1
  doAssert log.hasErrors
  doAssert log.isFatal
  doAssert log[1].code == dcBadValue
  var merged = DiagLog()
  doAssert not merged.hasErrors and not merged.isFatal
  merged.add log
  doAssert merged.len == 4 and merged.count(sevWarning) == 1

block defaults_mean_unknown:
  let d = Diagnostic(severity: sevInfo, code: dcIo, msg: "x")
  doAssert d.offset == -1
  doAssert d.loc.record == -1 and d.loc.trace == -1 and d.loc.channelSet == -1
  doAssert $d == "info io: x"
  doAssert $Diagnostic(code: dcIo, loc: Location(file: "f.sgy"), msg: "x") == "info io [f.sgy]: x"

block string_form:
  doAssert $sampleLog()[0] ==
    "info vendorBlock @1024 [record 0, trace 5, block 2]: block 0xB0 kept raw"
  doAssert $sampleLog()[1] ==
    "warning badValue @4340 [a dir/63.sgd, record 0, field GH1.formatCode]: " &
    "format code 0 is not defined"

block boundary_maps_exceptions:
  var log = DiagLog()
  let loc = Location(record: 2, trace: 7)
  let ok = log.tryRecord(loc):
    discard 1
  doAssert ok and log.len == 0
  for i in 0..3:
    let passed = log.tryRecord(loc):
      case i
      of 0: raiseFormat("bad", offset = 99)
      of 1: raiseTruncated("short", offset = 120)
      of 2: raise newException(IOError, "disk")
      else: raise newException(KeyError, "oops")
    doAssert not passed
  doAssert log.len == 4
  doAssert log[0].severity == sevError and log[0].code == dcBadValue and log[0].offset == 99
  doAssert log[0].loc.trace == 7 and log[0].msg == "bad"
  doAssert log[1].severity == sevFatal and log[1].code == dcTruncated and log[1].offset == 120
  doAssert log[2].severity == sevFatal and log[2].code == dcIo and log[2].offset == -1
  doAssert log[3].severity == sevError and log[3].code == dcInternal

block stop_boundary_always_records_fatal:
  # Where a failure ends the read, the entry is fatal whatever was raised,
  # so `isFatal` tells every read that stopped early.
  var log = DiagLog()
  let loc = Location(record: 1)
  let ok = log.tryRecordFatal(loc):
    discard 1
  doAssert ok and log.len == 0
  for i in 0..4:
    let passed = log.tryRecordFatal(loc):
      case i
      of 0: raiseFormat("bad", offset = 99)
      of 1: raiseTruncated("short", offset = 120)
      of 2: raise newException(IOError, "disk")
      of 3: raiseUnlocatable(dcTapeLayout, "class", offset = 7)
      else: raise newException(KeyError, "oops")
    doAssert not passed and log.isFatal
  doAssert log.len == 5 and log.count(sevFatal) == 5
  doAssert log[0].code == dcBadValue and log[0].offset == 99 and log[0].msg == "bad"
  doAssert log[1].code == dcTruncated and log[2].code == dcIo
  doAssert log[3].code == dcTapeLayout and log[3].offset == 7
  doAssert log[4].code == dcInternal and log[4].loc.record == 1
  doAssertRaises AssertionDefect:
    discard log.tryRecordFatal(Location()):
      doAssert false

block boundary_lets_defects_through:
  var log = DiagLog()
  doAssertRaises AssertionDefect:
    discard log.tryRecord(Location()):
      doAssert false

proc sameEntries(a, b: DiagLog): bool =
  result = a.len == b.len
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: result = false

block nif_round_trip:
  let log = sampleLog()
  let nif = log.toNif
  doAssert nif.startsWith("(.nif27)")
  doAssert "(diag warning badValue \"format code 0 is not defined\"" in nif
  doAssert "(field \"GH1.formatCode\")" in nif
  doAssert "(file \"a dir/63.sgd\")" in nif
  let back = parseDiagnostics(nif)
  doAssert sameEntries(log, back)
  doAssert back.count(sevFatal) == 1

block nif_empty_log:
  doAssert parseDiagnostics(DiagLog().toNif).len == 0

block nif_file_round_trip:
  let path = getTempDir() / "parseseg_tdiagnostics.nif"
  sampleLog().writeNif(path)
  doAssert sameEntries(readDiagnostics(path), sampleLog())
  removeFile path

block nif_malformed:
  doAssertRaises SegFormatError:
    discard parseDiagnostics("(.nif27)\n(other)")
  doAssertRaises SegFormatError:
    discard parseDiagnostics("(.nif27)\n(diagnostics (diag severe io \"x\"))")
  doAssertRaises SegFormatError:
    discard parseDiagnostics("(.nif27)\n(diagnostics (diag info io (bogus 1) \"x\"))")
  doAssertRaises SegFormatError:
    discard parseDiagnostics("(.nif27)\n(diagnostics (diag info io")

block nif_damaged_documents_raise:
  # A damaged document is malformed, whatever its bytes are. The toolchain's
  # NIF reader ended the process on the first (an unreadable line-info
  # suffix after `(~`) and raised RangeDefect on the second.
  for doc in ["(.nif27)\n(.vendor \"parseSEG\")\n(~diag2ostics\n (diag warni",
      "(.nif27)\n(diagnostics\n (diag warning badValue \"x\" (offset 4340@99999999999,1)))",
      "(.nif27)\n(diagnostics\n (diag warning badValue \"x\" (offset 99999999999999999999)))",
      "(.nif27)\n(diagnostics\n (diag warning badValue \"x\" (offset 1.5)))",
      "(.nif27)\n(diagnostics\n (diag warning badValue \"x\" (file 3)))",
      "(.nif27)\n(diagnostics\n (diag warning badValue \"x\\ZZ\"))",
      "(.nif27)\n(diagnostics\n (diag warning badValue \"unterminated))",
      "(.nif27)\n(diagnostics\n (diag warning badValue@1,2 \"x\"))",
      "(.nif27)\n(diagnostics\n (diag \"warning\" badValue \"x\"))",
      "(.nif27)\n(diagnostics 7)", "(.nif27", "", "\0\xFF(", "(.nif27)\n(diagnostics"]:
    doAssertRaises SegFormatError:
      discard parseDiagnostics(doc)

block nif_every_truncation_and_byte_change:
  # Cut at every length, and with every byte replaced by each of a few
  # hostile ones, the document parses or raises SegFormatError; nothing else.
  let nif = sampleLog().toNif
  var parsed, refused = 0
  proc attempt(doc: string) =
    try:
      discard parseDiagnostics(doc)
      inc parsed
    except SegFormatError:
      inc refused
  for n in 0 ..< nif.len: attempt(nif[0 ..< n])
  for i in 0 ..< nif.len:
    for c in "()\"\\@~#;\0\xFF9 ":
      var doc = nif
      doc[i] = c
      attempt(doc)
  doAssert parsed > 0 and refused > nif.len div 2

block nif_message_bytes_round_trip:
  # Every byte value survives in a message, a file name and a field name.
  var all = ""
  for c in 0..255: all.add char(c)
  var log = DiagLog()
  log.report(sevWarning, dcBadValue, all, offset = high(int64),
    loc = Location(file: all, record: high(int), field: all))
  doAssert sameEntries(parseDiagnostics(log.toNif), log)

block nif_reads_documents_of_earlier_versions:
  # As written with the toolchain's builder up to 0.9.0: punctuation escaped
  # as \HH, bytes past 0x7E written as they are.
  let old = "(.nif27)\n(.vendor \"parseSEG\")\n(diagnostics\n" &
    " (diag error unsupportedFormat \"tricky \\22quotes\\22 \\28parens\\29 \\5Bbrackets\\5D " &
    "\\23hash \\27tick\\27 back\\5Cslash\\0Anewline\\09tab \xC3\xBCn\xC3\xAFcode\"\n" &
    "  (channelSet 1)\n  (trace 0))\n (diag fatal truncated \"\"))"
  let log = parseDiagnostics(old)
  doAssert log.len == 2 and log[0] == sampleLog()[2] and log[1] == sampleLog()[3]

block nif_layout:
  var log = DiagLog()
  log.report(sevWarning, dcBadValue, "format code 0 is not defined", 4340,
    Location(file: "63.sgd", record: 0, field: "GH1.formatCode"))
  doAssert log.toNif == "(.nif27)\n(.vendor \"parseSEG\")\n(diagnostics\n" &
    " (diag warning badValue \"format code 0 is not defined\"\n  (file \"63.sgd\")\n" &
    "  (offset 4340)\n  (record 0)\n  (field \"GH1.formatCode\")))"
  doAssert DiagLog().toNif == "(.nif27)\n(.vendor \"parseSEG\")\n(diagnostics)"
