## Compiles the umbrella module, so every public module (including the
## platform tape backend) stays importable together.

import std/assertions
import parseSEGD

doAssert TraceHeaderSize == 240
