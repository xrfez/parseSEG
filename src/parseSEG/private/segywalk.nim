## The SEG-Y index walk's reader (15.3-9): `openSegy` in `headersOnly` mode
## that decodes, of each trace header, only what the walk uses (sample count
## and interval; Extension 1's counts, interval and last-trace flag) and
## hands the keys the raw header bytes it read. `SegyTrace.header` and
## `ext1` hold nothing else.

import std/importutils
import ../common/endians
import ../io/records
import ../segy/reader
import ./segykeys

privateAccess(SegyReader)

proc openSegyWalk*(src: RecordSource): SegyReader =
  ## A `headersOnly` reader for the index walk (see above).
  result = openSegy(src, headersOnly = true)
  result.walk = true

func walkHeaders*(r: SegyReader, t: SegyTrace): RawHeaders {.inline.} =
  ## The header bytes of the trace just read into `t`, for `segyKeys`.
  RawHeaders(std: cast[ByteBuf](unsafeAddr r.rawStd[0]),
    ext1: if t.hasExt1: cast[ByteBuf](unsafeAddr r.rawExt1[0]) else: nil,
    prop: byteBuf(t.proprietary), propLen: t.proprietary.len)
