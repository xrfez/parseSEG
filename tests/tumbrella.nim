## Compiles the umbrella module, so every public module (including the
## platform tape backend) stays importable together.

import std/[algorithm, assertions, os, macros]
import parseSEG
import ./utils/srcnames

doAssert TraceHeaderSize == 240
doAssert SegdTraceHeaderSize == 20 and traceHeaderFields.len > 0 and segdTraceHeaderFields.len > 0

# The stable surface does not export the field-layout pragmas (which clash
# with Arraymancer's `at`); they are in parseSEG/codecs.
doAssert not declared(bcdAt) and not declared(fix40)

# Files change only on an explicit write: the raw mapped pointer is internal,
# so a caller cannot write through it and bypass the editor's journal.
# `copyBytes` gives raw bytes as a copy.
doAssert not declared(unsafeMemory)
doAssert declared(copyBytes) and declared(isOpen)

block private_modules_stay_private:
  # `src/parseSEG/private/` holds the library's internal helpers: library
  # modules import them, no module re-exports them, so `import parseSEG`
  # cannot reach them whatever the re-export graph does.
  const privateMods = ["checks", "coordscalar", "decodeentry", "fieldaccess", "pagehints",
    "progressticker", "tensorrows"]
  doAssert sorted(privateModules()) == @privateMods,
    "update privateMods (and the hidden-name check below) for " & $privateModules()
  for path in sourceFiles():
    for st in exportStatements(readFile(path)):
      for w in words(st):
        doAssert w notin privateMods and w != "private",
          path & " re-exports a private module: " & st
  # Every name a private module exports is undeclared here. Names that a
  # public overload shares are checked by signature instead (below).
  const shared = ["finish", "blockStrings"]
  macro assertPrivateHidden(mods: static openArray[string],
      skip: static openArray[string]): untyped =
    result = newStmtList()
    for m in mods:
      for n in exportedNames(staticRead(srcDir / "parseSEG" / "private" / m & ".nim")):
        if n notin skip:
          result.add newCall(bindSym"doAssert",
            newCall(bindSym"not", newCall(bindSym"declared", ident(n))),
            newLit(m & "." & n & " leaks"))
  assertPrivateHidden(privateMods, shared)
  var sf: SeismicFile
  doAssert not compiles(sf.blockStrings(BlockRef()))
  doAssert not declared(ProgressTicker) # so `finish(var ProgressTicker)` is unreachable

block umbrella_except_lists_hide_what_they_name:
  # The internals still exported by public modules (they need a type's
  # private fields, or live in a codec module): an `except` list filters one
  # export path only, so check each name from the umbrella. Keep this list
  # equal to the `except` lists in src/parseSEG.nim (update both together).
  const hidden = [
    "decodeSamplesRaw", "decodeSegdSamplesRaw", "decodeSeg2SamplesRaw",
    "convertJoined", "convertSegdToSegyJoined", "GeometryJoin",
    "unsafeMemory", "mappedSize", "MapPin", "pinMap", "openSeismicRw", "remapWritable",
    "requireOpen", "requireTrace", "requireKind",
    "flushPending", "batching", "logVar"]
  macro assertHidden(names: static openArray[string]): untyped =
    result = newStmtList()
    for n in names:
      result.add newCall(bindSym"doAssert",
        newCall(bindSym"not", newCall(bindSym"declared", ident(n))), newLit(n & " leaks"))
  assertHidden(hidden)
  # Names that public overloads elsewhere share (system's `flush(File)` and
  # `writeBytes(File, ...)`, memsource's `flush`): check the hidden overload
  # itself.
  var sf: SeismicFile
  var ed: HeaderEditor
  doAssert not compiles(sf.flush())
  doAssert not compiles(ed.writeBytes(0'i64, [1'u8], "x", Location()))

block copy_bytes_is_a_bounds_checked_copy:
  const sample = currentSourcePath().parentDir.parentDir / "SEG Spec" / "exampleFiles" / "63.sgd"
  if fileExists(sample):
    var f = openSeismic(sample)
    doAssert not compiles(f.memory) and not compiles(f.unsafeMemory)
    var b = f.copyBytes(0, 32)
    doAssert b.len == 32
    b[0] = not b[0]                                   # the copy, not the file
    doAssert f.copyBytes(0, 1)[0] == not b[0]
    doAssertRaises(ValueError): discard f.copyBytes(getFileSize(sample) - 1, 2)
    f.close()
    doAssert not f.isOpen
    doAssertRaises(ValueError): discard f.copyBytes(0, 1)
