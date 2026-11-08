## Header NIF documents and vendor scaffolds at the library level (task 7.3,
## 7.1b), with the Phase 7 review regressions: hostile documents, last-wins,
## exact float comparison, documents for another file, journals, outputs that
## would clobber inputs, scaffold escaping and unassigned byte ranges.

import std/[assertions, os, strutils]
import parseSEG

const ex = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_theadernif"
createDir(tmp)

proc fresh(name: string): string =
  result = tmp / name
  copyFile(ex / name, result)
  for j in [result & ".edits.nif", result & ".j.nif"]:
    if fileExists(j): removeFile(j)

proc exportOf(path, to: string, raw = true) =
  var f = openSeismic(path)
  exportHeaders(f, to, raw)
  f.close()

proc has(log: DiagLog, text: string, sev: Severity): bool =
  for d in log:
    if d.severity == sev and text in d.msg: return true

block round_trips_change_nothing:
  for n in ["BO_3D-Inglewood_rev21_v7.sgy", "Sweep0.sgy", "63.sgd", "inova_rev30_5traces.sgd"]:
    let p = fresh(n)
    exportOf(p, tmp / "rt.nif")
    let r = importHeaders(p, tmp / "rt.nif")
    doAssert r.applied == 0 and r.refused == 0 and not r.log.hasErrors, n & " " & $r.log
    doAssert readFile(p) == readFile(ex / n), n

block hostile_documents_are_diagnostics:
  let p = fresh("63.sgd")
  for (doc, what) in [("", "empty"), ("(headers (trace 0 (block trace (f traceNumber 1E))))", "bad number"),
      ("(headers (trace 0 (block trace (f traceNumber 1.5E+))))", "bad number"),
      ("(headers@zzzzzzzzzzzzzzzzzzzz)", "line information"),
      ("(headers (trace 0 (block trace (f traceNumber 64@99999999999))))", "line information"),
      ("(headers (trace 99999999999999999999 (block trace)))", "out-of-range integer"),
      (repeat("(", 500), "expected (headers"), ("(headers " & repeat("(x ", 100), "nesting"),
      ("(headers (trace 0 (block trace (f traceNumber \"\\zz\"))))", "bad string escape"),
      ("\x00\x01\x02garbage", "unexpected character"), ("(headers (trace 0", "end of the document")]:
    writeFile(tmp / "h.nif", doc)
    let r = importHeaders(p, tmp / "h.nif")
    doAssert r.log.isFatal and r.applied == 0, what & ": " & $r.log
    doAssert r.log.has(what, sevFatal), what & ": " & $r.log
  doAssert readFile(p) == readFile(ex / "63.sgd")

block last_entry_wins_and_exact_floats:
  let p = fresh("63.sgd")
  writeFile(tmp / "dup.nif", "(headers (record 0 (block gh1 (f fileNumber 1) (f fileNumber 63))))")
  var r = importHeaders(p, tmp / "dup.nif")
  var f = openSeismic(p)
  doAssert f.recordField(0, "gh1.fileNumber").intVal == 63
  f.close()
  # An integral float for an integer field is no change.
  writeFile(tmp / "intf.nif", "(headers (record 0 (block gh1 (f fileNumber 63.0))))")
  r = importHeaders(p, tmp / "intf.nif", ImportOptions(dryRun: true))
  doAssert r.applied == 0
  # -0.0 and 0.0 differ (by bit pattern).
  var e = openEditor(p, p & ".j.nif")
  doAssert e.setTraceField(0, "ext1.extReceiverLineNumber", 0.0)
  e.close()
  writeFile(tmp / "z.nif", "(headers (trace 0 (block ext1 (f extReceiverLineNumber -0.0))))")
  r = importHeaders(p, tmp / "z.nif", ImportOptions(dryRun: true))
  doAssert r.applied == 1, $r.log
  writeFile(tmp / "z0.nif", "(headers (trace 0 (block ext1 (f extReceiverLineNumber 0.0))))")
  doAssert importHeaders(p, tmp / "z0.nif", ImportOptions(dryRun: true)).applied == 0

block documents_for_another_file:
  let p = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  exportOf(ex / "Sweep0.sgy", tmp / "sweep.nif")
  var r = importHeaders(p, tmp / "sweep.nif")
  doAssert r.log.has("not made from this file", sevFatal) and r.applied == 0
  doAssert readFile(p) == readFile(ex / "BO_3D-Inglewood_rev21_v7.sgy")
  r = importHeaders(p, tmp / "sweep.nif", ImportOptions(force: true, dryRun: true))
  doAssert r.applied > 0 and r.log.has("applied anyway", sevWarning)

block outputs_journals_and_copies:
  let p = fresh("63.sgd")
  exportOf(p, tmp / "doc.nif")
  doAssertRaises(ValueError):
    var f = openSeismic(p)
    try: exportHeaders(f, p) finally: f.close()
  doAssert readFile(p) == readFile(ex / "63.sgd")
  var r = importHeaders(p, tmp / "doc.nif", ImportOptions(outPath: tmp / "doc.nif"))
  doAssert r.log.has("the output is the document", sevFatal)
  doAssert readFile(tmp / "doc.nif").startsWith("(.nif27)")
  r = importHeaders(p, tmp / "doc.nif", ImportOptions(journal: p))
  doAssert r.log.has("the journal is the input", sevFatal)
  # A copy gets a fresh journal: a stale one would roll the copy back wrongly.
  let o = tmp / "copy.sgd"
  writeFile(o & ".edits.nif", "(edit 0 \"ff\" \"00\" \"stale\")\n")
  var d = readFile(tmp / "doc.nif")
  let y = d.find("(f year ")
  d = d[0 ..< y] & "(f year 11" & d[d.find(")", y) .. ^1]
  writeFile(tmp / "doc2.nif", d)
  r = importHeaders(p, tmp / "doc2.nif", ImportOptions(outPath: o))
  doAssert r.applied == 1 and r.log.has("earlier copy", sevInfo), $r.log
  doAssert not rollbackJournal(o, o & ".edits.nif").hasErrors
  doAssert readFile(o) == readFile(p)
  # A copy is made even when nothing changes.
  removeFile(o)
  r = importHeaders(p, tmp / "doc.nif", ImportOptions(outPath: o))
  doAssert fileExists(o) and r.applied == 0

block many_errors_are_capped:
  let p = fresh("63.sgd")
  exportOf(ex / "BO_3D-Inglewood_rev21_v7.sgy", tmp / "big.nif")
  let r = importHeaders(p, tmp / "big.nif", ImportOptions(force: true, dryRun: true))
  doAssert r.log.len < 100 and r.log.has("more entries name fields", sevError), $r.log.len

block scaffold_escapes_and_ranges:
  # Unassigned SEG-Y bytes with awkward text, and a binary byte in 3507-3600.
  let p = fresh("BO_3D-Inglewood_rev21_v7.sgy")
  var b = readFile(p)
  let text = "O'B(\"R;\\)"
  for i, c in text: b[333200 + 180 + i] = c # trace 0 (after 103 extended text records), bytes 181...
  b[3200 + 340] = '\x07'
  writeFile(p, b)
  let reg = VendorRegistry()
  let s = scaffoldVendorMap(p, reg)
  doAssert s.len == 2, $s.len
  let nif = s.toNif(name = "my \"map\" é")
  writeFile(tmp / "sc.nif", nif)
  let m = loadVendorMap(nif, tmp / "sc.nif")
  doAssert m.name == "my \"map\" é" and m.targets.len == 2
  var reg2 = VendorRegistry()
  reg2.addMap m
  doAssert scaffoldVendorMap(p, reg2).len == 0
  doAssert "(at 333)" in nif and "(at 101)" in nif # 3533-3600 and 3301-3500, 1-based in 400
  doAssert scaffoldVendorMap(ex / "BO_3D-Inglewood_rev21_v7.sgy", reg).toNif == ""

when defined(linux):
  import std/posix
  var RLIMIT_FSIZE {.importc, header: "<sys/resource.h>".}: cint

  proc limitFileSize(bytes: int) =
    ## Writes past `bytes` into any file fail with EFBIG (SIGXFSZ ignored);
    ## a negative `bytes` lifts the limit.
    signal(SIGXFSZ, SIG_IGN)
    var lim: RLimit
    doAssert getrlimit(RLIMIT_FSIZE, lim) == 0
    lim.rlim_cur = if bytes < 0: lim.rlim_max else: bytes
    doAssert setrlimit(RLIMIT_FSIZE, lim) == 0

  proc importLimited(p, doc: string, seen: var int): ImportResult =
    ## Imports with room in the journal for its session line only.
    var n = 0
    limitFileSize(100)
    try:
      result = importHeaders(p, doc, ImportOptions(onChange: proc (c: HeaderChange) = inc n))
    finally:
      limitFileSize(-1)
    seen = n

  block failed_journal_syncs_are_reported:
    # 12.4: batched edits reach the file only when their journal entries are
    # synced; when that fails, `applied` must not claim written changes.
    let name = "BO_3D-Inglewood_rev21_v7.sgy"
    var p = fresh(name)
    exportOf(p, tmp / "sync.nif", raw = false)
    let d = readFile(tmp / "sync.nif")
    # The last entry changes: only the final sync (`endBatch`) journals it.
    let last = d.rfind("(f sourceMeasurementUnit 0)")
    let tail = d.find(")", d.find("(f headerName", last)) + 1
    writeFile(tmp / "sync2.nif", d[0 ..< last] & "(f sourceMeasurementUnit 3)" & d[tail .. ^1])
    var seen = 0
    var r = importLimited(p, tmp / "sync2.nif", seen)
    doAssert seen == 1 and r.applied == 0 and r.refused == 1, $r.applied & " " & $r.log
    doAssert r.log.has("1 accepted edits were not written", sevFatal)
    doAssert readFile(p) == readFile(ex / name) and not readFile(p & ".edits.nif").contains("(edit")
    # A change followed by more fields of the same header: reading them
    # needs the sync, whose failure stops the import (an I/O error).
    p = fresh(name)
    let g = d.find("(f groupX ")
    writeFile(tmp / "sync3.nif", d[0 ..< g] & "(f groupX 901" & d[d.find(")", g) .. ^1])
    r = importLimited(p, tmp / "sync3.nif", seen)
    doAssert seen == 1 and r.applied == 0 and r.refused == 1, $r.applied & " " & $r.log
    var ioFatal = false
    for x in r.log:
      if x.severity == sevFatal and x.code == dcIo and "cannot be synced" in x.msg: ioFatal = true
    doAssert ioFatal
    doAssert not r.log.has("fields the file does not have", sevError)
    doAssert readFile(p) == readFile(ex / name)

echo "theadernif: ok"
