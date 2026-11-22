## The trace identification code `writeTrace(w, keys, samples)` writes into a
## SEG-Y file: an explicit `traceCode` is written as given unless the status
## is known and says otherwise.
##
## Seen to fail first, by breaking the code and restoring it:
## - the status test put back to `segyStatus(code, major) == status` alone
##   (explicit code with `tsUnknown` written as 0; auxiliary with an
##   optional-use code written as 0)
## - the `traceCodeRev` test left out (keys read from a Rev 0 file with its
##   optional code 12 written as Rev 1's vertical geophone, 12)

import std/[assertions, os]

import parseSEG

import ./utils/testutils

proc options(major, minor: int): SegyOutputOptions =
  SegyOutputOptions(revision: SegyRevision(major: uint8(major), minor: uint8(minor)),
    byteOrder: boBig, format: st5, text: @["T"], traceSorting: 1, measurementSystem: 1)

proc writtenKeys(major, minor: int, k: TraceKeys): seq[byte] =
  var w = openSeismicWriterBytes(options(major, minor), "code.sgy")
  w.writeTrace(k, [1'f32, 2, 3, 4])
  w.finishBytes()

proc codeOf(b: sink seq[byte]): TraceKeys =
  var f = openSeismicBytes(b, "code.sgy", keys = true)
  result = f.traceKeys(0)
  f.close()

proc callerKeys(code: int16, status: TraceStatus): TraceKeys =
  result = initTraceKeys()
  result.record = 1
  result.channel = 1
  result.intervalUs = 2000
  result.traceCode = code
  result.status = status

proc written(major, minor: int, code: int16, status: TraceStatus): int16 =
  ## The code a trace with these keys is stored with.
  codeOf(writtenKeys(major, minor, callerKeys(code, status))).traceCode

proc carried(fromMajor, toMajor: int, code: int16, status: TraceStatus): int16 =
  ## The code of keys read from a file of one revision, written as another.
  let k = codeOf(writtenKeys(fromMajor, 0, callerKeys(code, status)))
  doAssert k.traceCodeRev == [tcrRev0, tcrRev1, tcrRev2][fromMajor]
  codeOf(writtenKeys(toMajor, 0, k)).traceCode

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
  # Auxiliary with a code the revision leaves to optional use: kept.
  doAssert written(1, 0, 30, tsAuxiliary) == 30
  doAssert written(0, 0, 12, tsAuxiliary) == 12
  doAssert written(2, 0, 30, tsAuxiliary) == 0 # Rev 2 defines 30 as seismic
  # Keys read from a file: its optional code is not carried into a revision
  # that gives the number a meaning (Rev 0 12 is a vertical geophone in
  # Rev 1; 25 and 30 are seismic and EM in Rev 2), but is carried to one
  # that leaves it undefined too, and back into its own revision.
  doAssert carried(0, 0, 12, tsUnknown) == 12
  doAssert carried(0, 1, 12, tsUnknown) == 0
  doAssert carried(0, 2, 12, tsUnknown) == 0
  doAssert carried(1, 1, 30, tsUnknown) == 30
  doAssert carried(1, 2, 30, tsUnknown) == 0
  doAssert carried(1, 0, 30, tsUnknown) == 30
  doAssert carried(0, 1, 25, tsUnknown) == 25
  doAssert carried(0, 2, 25, tsUnknown) == 0
  # A code the source defines is carried as before.
  doAssert carried(2, 2, 12, tsLive) == 12
  doAssert carried(2, 1, 12, tsLive) == 12
  doAssert carried(1, 0, 12, tsLive) == 1
  doAssert carried(1, 0, 5, tsAuxiliary) == 5

when isMainModule: main()
