## The trace identification code `writeTrace(w, keys, samples)` writes into a
## SEG-Y file: an explicit `traceCode` is written as given unless the status
## is known and says otherwise.
##
## Seen to fail first, by breaking the code and restoring it: the status
## test in `keysToHeaders` put back to `segyStatus(code, major) == status`
## alone (explicit code with `tsUnknown` written as 0).

import std/[assertions, os]

import parseSEG

import ./utils/testutils

proc written(major, minor: int, code: int16, status: TraceStatus): int16 =
  ## The code a trace with these keys is stored with.
  var k = initTraceKeys()
  k.record = 1
  k.channel = 1
  k.intervalUs = 2000
  k.traceCode = code
  k.status = status
  let o = SegyOutputOptions(revision: SegyRevision(major: uint8(major), minor: uint8(minor)),
    byteOrder: boBig, format: st5, text: @["T"], traceSorting: 1,
    measurementSystem: 1)
  var w = openSeismicWriterBytes(o, "code.sgy")
  w.writeTrace(k, [1'f32, 2, 3, 4])
  var f = openSeismicBytes(w.finishBytes(), "code.sgy", keys = true)
  result = f.traceKeys(0).traceCode
  f.close()

proc main*() =
  for (major, minor) in [(0, 0), (1, 0), (2, 0), (2, 1)]:
    let what = "Rev " & $major & "." & $minor
    # An explicit code with an unknown status: written as given.
    doAssert written(major, minor, 1, tsUnknown) == 1, what
    doAssert written(major, minor, 5, tsUnknown) == 5, what # Aux: not seismic
    doAssert written(major, minor, 2, tsUnknown) == 2, what
    # A code this revision does not define, status unknown: still as given.
    doAssert written(major, minor, 30, tsUnknown) == 30, what
    # The same code, the status the reader gives it: unchanged.
    doAssert written(major, minor, 1, tsLive) == 1, what
    doAssert written(major, minor, 2, tsDead) == 2, what
    doAssert written(major, minor, 5, tsAuxiliary) == 5, what
    # A known status that contradicts the code wins, as documented.
    doAssert written(major, minor, 1, tsDead) == 2, what
    doAssert written(major, minor, 2, tsLive) == 1, what
    doAssert written(major, minor, 5, tsLive) == 1, what
    # No code: the status gives one (auxiliary and unknown have none).
    doAssert written(major, minor, 0, tsLive) == 1, what
    doAssert written(major, minor, 0, tsDead) == 2, what
    doAssert written(major, minor, 0, tsUnknown) == 0, what
    doAssert written(major, minor, 0, tsAuxiliary) == 0, what
  # Rev 0 defines 1-8: a Rev 1 code beyond that (a vertical geophone) with
  # the status the Rev 1 reader gave it is replaced by the status code.
  doAssert written(0, 0, 12, tsLive) == 1
  doAssert written(1, 0, 12, tsLive) == 12
  # Rev 1 gives codes over 22 no status, so they are kept when unknown.
  doAssert written(1, 0, 23, tsUnknown) == 23
  doAssert written(0, 0, 12, tsUnknown) == 12
