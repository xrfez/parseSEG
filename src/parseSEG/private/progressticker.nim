## The library's progress plumbing (`common/progress` has the public
## `Progress` callback type): a ticker that calls a `Progress` every
## `ProgressStep` bytes, the per-pass scaling of a multi-pass operation, and
## the cancellation diagnostic. Library modules import it; nothing
## re-exports it.

import ../common/[diagnostics, progress]

type
  ProgressTicker* = object
    ## Calls a `Progress` every `ProgressStep` bytes of input.
    hook: Progress
    total: int64
    next: int64 ## `done` at or past which the hook is called next.

func initProgressTicker*(hook: Progress, total: int64): ProgressTicker =
  ## A ticker for `hook` over an input of `total` bytes (-1 if
  ## unknown). With a nil hook, `tick` never calls anything.
  ProgressTicker(hook: hook, total: total, next: if hook == nil: high(int64) else: 0)

proc fire(p: var ProgressTicker, done: int64): bool {.noinline.} =
  p.next = done + ProgressStep
  p.hook(done, p.total)

template tick*(p: var ProgressTicker, done: int64): bool =
  ## False when the callback cancelled. Calls it when `done`
  ## reached the next step; otherwise one comparison.
  let d = done
  d < p.next or p.fire(d)

proc finish*(p: var ProgressTicker): bool =
  ## The final call (`done == total`, or `done == -1` when
  ## the size is unknown); false when the callback cancelled.
  p.hook == nil or p.hook(p.total, p.total)

func progressPhase*(hook: Progress, k, n: int, total = -1'i64): Progress =
  ## Pass `k` (0-based) of an operation that reads its input
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
  ## The fatal `dcCancelled` diagnostic of a cancelled
  ## conversion or export of `output`.
  log.report(sevFatal, dcCancelled, "cancelled by the progress callback; nothing was written",
    loc = Location(file: output))
