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

import ./[errors, diagnostics]

export errors

type
  Progress* = proc (done, total: int64): bool {.closure, gcsafe, raises: [].}
    ## Called with the input bytes done and the input's size (-1 if
    ## unknown); returns false to cancel the operation.

  ProgressTicker* = object
    ## **Internal.** Calls a `Progress` every `ProgressStep` bytes of input.
    hook: Progress
    total: int64
    next: int64 ## `done` at or past which the hook is called next.

const ProgressStep* = 1'i64 shl 20
  ## Input bytes between two calls of a `Progress` callback (1 MiB).

func initProgressTicker*(hook: Progress, total: int64): ProgressTicker =
  ## **Internal.** A ticker for `hook` over an input of `total` bytes (-1 if
  ## unknown). With a nil hook, `tick` never calls anything.
  ProgressTicker(hook: hook, total: total, next: if hook == nil: high(int64) else: 0)

proc fire(p: var ProgressTicker, done: int64): bool {.noinline.} =
  p.next = done + ProgressStep
  p.hook(done, p.total)

template tick*(p: var ProgressTicker, done: int64): bool =
  ## **Internal.** False when the callback cancelled. Calls it when `done`
  ## reached the next step; otherwise one comparison.
  let d = done
  d < p.next or p.fire(d)

proc finish*(p: var ProgressTicker): bool =
  ## **Internal.** The final call (`done == total`, or `done == -1` when
  ## the size is unknown); false when the callback cancelled.
  p.hook == nil or p.hook(p.total, p.total)

func progressPhase*(hook: Progress, k, n: int, total = -1'i64): Progress =
  ## **Internal.** Pass `k` (0-based) of an operation that reads its input
  ## `n` times: reports each pass's share `done / t` scaled into `k/n ..
  ## (k+1)/n`, so one bar spans every pass, in bytes of `total` (default:
  ## the pass's own `t`). Nil for a nil hook.
  if hook == nil or (n <= 1 and total < 0): return hook
  result = proc (done, t: int64): bool {.closure, gcsafe, raises: [].} =
    let whole = if total >= 0: total else: t
    if t <= 0 or whole < 0: hook(done, whole)
    else:
      let x = (float64(k) + float64(min(done, t)) / float64(t)) / float64(n) * float64(whole)
      hook(min(int64(x), whole), whole)

proc reportCancelled*(log: var DiagLog, output: string) =
  ## **Internal.** The fatal `dcCancelled` diagnostic of a cancelled
  ## conversion or export of `output`.
  log.report(sevFatal, dcCancelled, "cancelled by the progress callback; nothing was written",
    loc = Location(file: output))
