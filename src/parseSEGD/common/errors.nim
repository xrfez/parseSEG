## Exception types shared by all SEG format modules.

type
  SegError* = object of CatchableError
    ## Base type for every recoverable error raised by this library.
  SegFormatError* = object of SegError
    ## The bytes being decoded violate the format specification, or a value
    ## cannot be represented in the encoding being written.

proc raiseFormat*(msg: string) {.noinline, noreturn.} =
  ## Raises `SegFormatError` with `msg`.
  raise newException(SegFormatError, msg)
