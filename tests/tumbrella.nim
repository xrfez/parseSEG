## Compiles the umbrella module, so every public module (including the
## platform tape backend) stays importable together.

import std/[assertions, os]
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

block copy_bytes_is_a_bounds_checked_copy:
  const sample = currentSourcePath().parentDir.parentDir / "SEG Spec" / "exampleFiles" / "63.sgd"
  if fileExists(sample):
    var f = openSeismic(sample)
    doAssert not compiles(f.memory) and not compiles(f.unsafeMemory)
    var b = f.copyBytes(0, 32)
    doAssert b.len == 32
    b[0] = not b[0]                                   # the copy, not the file
    doAssert f.copyBytes(0, 1)[0] == not b[0]
    doAssertRaises(ValueError): discard f.copyBytes(f.mappedSize - 1, 2)
    f.close()
    doAssert not f.isOpen
    doAssertRaises(ValueError): discard f.copyBytes(0, 1)
