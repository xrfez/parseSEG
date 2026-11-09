## Argument checks shared by the model modules (`traceindex`, `gathers`,
## `prefetch`, `sorting`, `headerfields`, `survey/join`), with their raisers
## kept out of line (`{.noinline, noreturn.}`) so the hot accessors stay
## small.

import ../model/indextypes

proc raiseClosed*() {.noinline, noreturn.} =
  ## Raises `ValueError` "the file is closed".
  raise newException(ValueError, "the file is closed")

proc raiseNoTrace*(trace, len: int) {.noinline, noreturn.} =
  ## Raises `ValueError` for trace `trace` of a file of `len` traces.
  raise newException(ValueError, "no trace " & $trace & " (the file has " & $len & ")")

proc requireKeys*(ix: TraceIndex) =
  ## Raises `ValueError` unless the index holds per-trace keys.
  if ix.keys.len != ix.entries.len:
    raise newException(ValueError, "open the file with keys = true")

proc checkSpan*(span: Slice[int], len: int, what = "traces") =
  ## Raises `ValueError` unless `span` lies in `0 ..< len`; an
  ## empty span must start in `0 .. len` (so `len .. len - 1` is allowed,
  ## `len + 2 .. len + 1` is not).
  if span.a < 0 or span.a > len or span.b >= len:
    raise newException(ValueError, what & " " & $span & " lie outside 0.." & $(len - 1))

func spanLen*(span: Slice[int]): int {.inline.} =
  ## The number of elements of `span`; 0 when empty.
  if span.b < span.a: 0 else: span.len
