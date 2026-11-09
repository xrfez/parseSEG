## Compiles the umbrella module, so every public module (including the
## platform tape backend) stays importable together.

import std/[assertions, os, macros]
import parseSEG

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

# Model internals (raw-pointer decoders, the map's size, shared checks) stay
# inside the library.
doAssert not declared(decodeEntry) and not declared(pinMap) and not declared(MapPin) and
  not declared(mappedSize) and not declared(rowPtr) and not declared(requireKeys) and
  not declared(checkSpan)
doAssert not declared(locate) and not declared(readField) and not declared(withBlockType) and
  not declared(FieldRef)

block umbrella_except_lists_hide_what_they_name:
  # An `except` list filters one export path only: a leaf module that re-exports
  # the same module whole undoes it. Keep this list equal to the union of the
  # `except` lists in src/parseSEG.nim (update both together).
  const hidden = [
    "decodeSamplesRaw", "decodeSegdSamplesRaw", "decodeSeg2SamplesRaw",
    "convertJoined", "convertSegdToSegyJoined", "GeometryJoin",
    "unsafeMemory", "decodeEntry", "tryDecodeEntry", "DecodeStatus", "decodeMessages",
    "mappedSize", "requireKeys", "checkSpan", "spanLen", "MapPin", "pinMap",
    "openSeismicRw", "remapWritable", "ProgressTicker", "initProgressTicker", "tick",
    "progressPhase", "reportCancelled",
    "locate", "locateBlock", "readField", "FieldRef", "FieldRead", "withBlockType",
    "isLayoutField", "isNamedField", "fieldValueOf", "readFields",
    "flushPending", "batching", "logVar",
    "chooseScalar",
    "adviseWillNeed", "isResident", "adviseTraces",
    "rowPtr"]
  macro assertHidden(names: static openArray[string]): untyped =
    result = newStmtList()
    for n in names:
      result.add newCall(bindSym"doAssert",
        newCall(bindSym"not", newCall(bindSym"declared", ident(n))), newLit(n & " leaks"))
  assertHidden(hidden)
  # Names that public overloads elsewhere share (system's `flush(File)` and
  # `writeBytes(File, ...)`, memsource's `flush`, exttext's `finish`): check
  # the hidden overload itself. `finish(var ProgressTicker)` is unreachable
  # because `ProgressTicker` is hidden (above).
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
