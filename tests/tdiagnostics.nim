## Tests for the diagnostics log: counts, formatting, the exception boundary,
## and NIF round trips.

import std/[assertions, os, strutils]
import parseSEGD/common/[errors, diagnostics]

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
  let path = getTempDir() / "parsesegd_tdiagnostics.nif"
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
