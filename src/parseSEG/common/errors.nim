## Exception types shared by all SEG format modules.
##
## Exceptions are internal: readers convert them into diagnostics at the
## record/trace boundary (see `diagnostics.tryRecord`), so a read never aborts
## on a format problem.

import diagcodes

type
  SegError* = object of CatchableError
    ## Base type for every recoverable error raised by this library.
    offset*: int64 = -1 ## Absolute byte offset of the problem; -1 if unknown.
  SegFormatError* = object of SegError
    ## The bytes being decoded violate the format specification, or a value
    ## cannot be represented in the encoding being written.
  SegTruncatedError* = object of SegFormatError
    ## The data ends before a structure that the headers announce is complete.
  SegUnlocatableError* = object of SegFormatError
    ## The rest of the data cannot be located (e.g. an unknown sample format
    ## leaves trace lengths unknown): readers stop. Raise it with
    ## `diagnostics.raiseUnlocatable`, which records the diagnostic code.
    diagCode*: DiagCode ## The code to report.
  SegCancelledError* = object of CatchableError
    ## A `Progress` callback returned false: the caller cancelled the
    ## operation (`openSeismic`, `exportHeaders`). Not a `SegError`, so the
    ## readers' format-error boundaries never swallow it.

proc raiseFormat*(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises `SegFormatError` with `msg` and the byte `offset` (-1 if unknown).
  raise (ref SegFormatError)(msg: msg, offset: offset)

proc raiseTruncated*(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises `SegTruncatedError` with `msg` and the byte `offset` where data ran out.
  raise (ref SegTruncatedError)(msg: msg, offset: offset)

proc raiseCancelled*(msg = "cancelled by the progress callback") {.noinline, noreturn.} =
  ## Raises `SegCancelledError`.
  raise newException(SegCancelledError, msg)
