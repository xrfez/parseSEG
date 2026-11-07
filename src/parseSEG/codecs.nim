## Low-level byte codecs: byte order, BCD, IBM floats, EBCDIC and the
## `{.at.}` field-layout machinery that the header types are built with.
##
## These are reusable on any `openArray[byte]` and carry no stability promise
## beyond the library's own needs; the umbrella `parseSEG` module does not
## export them (they would also clash with Arraymancer's `at`). Import this
## module, or the individual `parseSEG/common/*` modules, to use them.

import ./common/[endians, bcd, ibmfloat, ebcdic, fieldlayout]
export endians, bcd, ibmfloat, ebcdic, fieldlayout
