## Compiles the umbrella module, so every public module (including the
## platform tape backend) stays importable together.

import std/assertions
import parseSEG

doAssert TraceHeaderSize == 240
doAssert SegdTraceHeaderSize == 20 and traceHeaderFields.len > 0 and segdTraceHeaderFields.len > 0

# The stable surface does not export the field-layout pragmas (which clash
# with Arraymancer's `at`); they are in parseSEG/codecs.
doAssert not declared(bcdAt) and not declared(fix40)
