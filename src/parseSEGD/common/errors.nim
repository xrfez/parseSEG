## Exception types shared by all SEG format modules.
##
## Exceptions are internal: readers convert them into diagnostics at the
## record/trace boundary (see `diagnostics.tryRecord`), so a read never aborts
## on a format problem.

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
    diagCode*: int ## `ord` of the `DiagCode` to report.

proc raiseFormat*(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises `SegFormatError` with `msg` and the byte `offset` (-1 if unknown).
  raise (ref SegFormatError)(msg: msg, offset: offset)

proc raiseTruncated*(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises `SegTruncatedError` with `msg` and the byte `offset` where data ran out.
  raise (ref SegTruncatedError)(msg: msg, offset: offset)
