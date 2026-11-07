## Compiles the umbrella module, so every public module (including the
## platform tape backend) stays importable together.

import std/assertions
import parseSEGD

doAssert TraceHeaderSize == 240
doAssert SegdTraceHeaderSize == 20 and traceHeaderFields.len > 0 and segdTraceHeaderFields.len > 0
