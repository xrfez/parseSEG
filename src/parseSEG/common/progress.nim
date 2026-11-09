## Progress reports and cancellation for long operations: opening (the
## index walk), converting and exporting.
##
## A `Progress` callback gets the input bytes done so far and the input's
## size (-1 when unknown: a tape or a pipe), and returns false to cancel.
## It is called about every `ProgressStep` bytes of input, never per trace,
## and once more at the end with `done == total`. A nil callback (the
## default everywhere) costs one comparison per trace.
##
## ```nim
## var shown = 0'i64
## let bar: Progress = proc (done, total: int64): bool =
##   shown = done
##   true # false cancels
## ```

import ./errors

export errors

type
  Progress* = proc (done, total: int64): bool {.closure, gcsafe, raises: [].}
    ## Called with the input bytes done and the input's size (-1 if
    ## unknown); returns false to cancel the operation.

const ProgressStep* = 1'i64 shl 20
  ## Input bytes between two calls of a `Progress` callback (1 MiB).
