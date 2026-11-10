## Zero-copy views of which trace each row of a block of samples is
## (`TraceRows`, Phase 16.2).
##
## A tensor or buffer of decoded samples has one row per trace. A
## `TraceRows` says which trace each row is and gives that trace's keys,
## sample count and channel set straight from the file's trace index:
## nothing is copied, so the index stays the only copy of per-trace
## metadata.
##
## ```nim
## var f = openSeismic("line.sgy", keys = true)
## let x = f.readTraces(100 ..< 200, 0 ..< 500)
## let rows = f.rowsOf(100 ..< 200)
## for row in 0 ..< rows.len:
##   echo rows.traceOf(row), " ", rows.traceKeys(row).offset, " ", rows.numSamples(row)
## ```
##
## A view of a file without stored keys still gives each row's trace,
## sample count and channel set; its `traceKeys` raises (`hasKeys`).
## `keysAt` is the non-raising form, for code that checked `hasKeys` once
## and must not raise (a `{.raises: [].}` kernel, a `ChunkTransform`).
##
## **Lifetime.** A view holds raw pointers into the index (or into the
## arrays it was made from) and is valid while they stay alive and keep
## their size: until the file is closed, and, for a selection, while the
## trace list lives. Keys may change in place under a view (`applySurvey`,
## `applyGeometry`, editor writes); `keysRevision` says that they did.
##
## **Threads.** A view is a plain object with no reference-counted parts: it
## can be copied into worker threads, and any number of threads may read
## through it at once. Whatever changes keys (`applySurvey`,
## `applyGeometry`, a `HeaderEditor`) needs those readers stopped first.

import std/math
import ./[traceindex, headerfields]
import ../private/checks

type
  TraceRows* = object
    ## A view of `len` rows: row `i` is trace `traceOf(i)`. See the module
    ## documentation for its lifetime and threading contract.
    count: int
    first: int ## Range mode: row i is trace first + i (also after `sub`).
    sel: ptr UncheckedArray[int] ## Selection mode, when not nil: row i is trace sel[i].
    keys: ptr UncheckedArray[TraceKeys] ## By trace.
    entries: ptr UncheckedArray[TraceEntry] ## By trace; nil for a synthetic view.
    samples: ptr UncheckedArray[int] ## By trace, for a synthetic view.

proc rowOutside(row, count: int) {.noinline, noreturn.} =
  raise newException(IndexDefect, "row " & $row & " is outside 0 ..< " & $count)

template checkRow(r: TraceRows, row: int) =
  when compileOption("boundChecks"):
    if row < 0 or row >= r.count: rowOutside(row, r.count)

proc noKeys() {.noinline, noreturn.} =
  raise newException(ValueError, "the view has no keys: open the file with keys = true " &
    "(or call ensureKeys) before making the view")

proc keysMissing() {.noinline, noreturn.} =
  raise newException(AssertionDefect, "keysAt on a view without keys: check hasKeys " &
    "first (open the file with keys = true, or call ensureKeys, before making the view)")

func len*(r: TraceRows): int {.inline.} =
  ## The number of rows.
  r.count

func traceOf*(r: TraceRows, row: int): int {.inline.} =
  ## The trace of row `row` (for a synthetic view: its index in the arrays the
  ## view was made from). An `IndexDefect` for a row outside `0 ..< len`
  ## (with bound checks on).
  r.checkRow(row)
  if r.sel != nil: r.sel[row] else: r.first + row

func hasKeys*(r: TraceRows): bool {.inline.} =
  ## The view gives keys: it was made from a file with stored keys (or from
  ## synthetic keys).
  r.keys != nil or r.count == 0

func traceKeys*(r: TraceRows, row: int): lent TraceKeys {.inline.} =
  ## The keys of row `row`'s trace, in place (no copy). Raises `ValueError`
  ## for a view without keys (`hasKeys`).
  if r.keys == nil: noKeys()
  r.keys[r.traceOf(row)]

func keysAt*(r: TraceRows, row: int): lent TraceKeys {.inline, raises: [].} =
  ## The keys of row `row`'s trace, in place, like `traceKeys` but without
  ## raising: for callers that checked `hasKeys` once, such as a
  ## `{.raises: [].}` kernel or a `ChunkTransform`. A view without keys is a
  ## precondition violation: an `AssertionDefect` with bound checks on,
  ## undefined behaviour without (`-d:danger`). A row outside `0 ..< len` is an
  ## `IndexDefect` with bound checks on, as for `traceOf`.
  runnableExamples:
    var keys = @[initTraceKeys(), initTraceKeys()]
    keys[1].offset = 25
    let rows = rowsOf(keys, [100, 100])
    if rows.hasKeys:                       # checked once, before the loop
      var far = 0.0
      for row in 0 ..< rows.len: far = max(far, abs(rows.keysAt(row).offset))
      doAssert far == 25
  when compileOption("boundChecks"):
    if r.keys == nil and r.count > 0: keysMissing()
  r.keys[r.traceOf(row)]

func numSamples*(r: TraceRows, row: int): int {.inline.} =
  ## The sample count of row `row`'s trace (its live length; a tensor's rows
  ## may be longer).
  let t = r.traceOf(row)
  if r.entries != nil: int(r.entries[t].numSamples) else: r.samples[t]

func channelSetIndex*(r: TraceRows, row: int): int {.inline.} =
  ## The 0-based SEG-D channel set of row `row`'s trace; -1 when unknown, for
  ## SEG-Y and SEG-2, and for a synthetic view.
  let t = r.traceOf(row)
  if r.entries != nil: r.entries[t].channelSetIndex else: -1

func sub*(r: TraceRows, rows: Slice[int]): TraceRows =
  ## The rows `rows` of `r` as a view of their own (row 0 is `r`'s row
  ## `rows.a`), for splitting work. Raises `ValueError` for rows outside
  ## `0 ..< len` (an empty slice may start at `len`).
  checkSpan(rows, r.count)
  result = r
  result.count = spanLen(rows)
  if result.count == 0: return
  if r.sel != nil: result.sel = cast[ptr UncheckedArray[int]](addr r.sel[rows.a])
  else: result.first = r.first + rows.a

template indexPointers(f: SeismicFile, r: var TraceRows) =
  if f.len > 0:
    if f.hasKeys: r.keys = cast[ptr UncheckedArray[TraceKeys]](unsafeAddr f.index.keys[0])
    r.entries = cast[ptr UncheckedArray[TraceEntry]](unsafeAddr f.index.entries[0])

func rowsOf*(f: SeismicFile, traces: Slice[int]): TraceRows =
  ## A view of the traces `traces`, in order: row `i` is trace
  ## `traces.a + i`. Its `traceKeys` needs the file's stored keys
  ## (`openSeismic(keys = true)` or `ensureKeys` before the view is made;
  ## see `hasKeys`); the sample counts and channel sets need none. Raises
  ## `ValueError` for traces out of range.
  checkSpan(traces, f.len)
  indexPointers(f, result)
  result.count = spanLen(traces)
  result.first = traces.a

func rowsOf*(f: SeismicFile, traces: openArray[int]): TraceRows =
  ## A view of the listed traces: row `i` is trace `traces[i]`. The list is
  ## not copied: it must outlive the view and keep its size (never pass a
  ## temporary, such as `f.rowsOf(@[1, 2])`: the view would dangle at once). Raises
  ## `ValueError` like the range form.
  for t in traces:
    if t < 0 or t >= f.len:
      raise newException(ValueError, "trace " & $t & " is outside 0 ..< " & $f.len)
  indexPointers(f, result)
  result.count = traces.len
  if traces.len > 0: result.sel = cast[ptr UncheckedArray[int]](unsafeAddr traces[0])

func rowsOf*(keys: openArray[TraceKeys], numSamples: openArray[int]): TraceRows =
  ## A view of synthetic traces with no file: row `i` has `keys[i]` and
  ## `numSamples[i]` samples (`traceOf(i) == i`, no channel set). Neither
  ## array is copied: both must outlive the view (no temporaries). Raises `ValueError` when
  ## their lengths differ.
  if keys.len != numSamples.len:
    raise newException(ValueError, "need as many sample counts as keys: " & $keys.len &
      " keys, " & $numSamples.len & " counts")
  result.count = keys.len
  if keys.len > 0:
    result.keys = cast[ptr UncheckedArray[TraceKeys]](unsafeAddr keys[0])
    result.samples = cast[ptr UncheckedArray[int]](unsafeAddr numSamples[0])

# ----------------------------------------------------------- uniform runs --

func sameInterval(a, b: float64): bool {.inline.} = a == b or (a.isNaN and b.isNaN)

proc intervalOf(f: SeismicFile, trace: int): float64 {.inline.} =
  if f.hasKeys: f.index.keys[trace].intervalUs else: f.sampleIntervalUs(trace)

template runsOver(f: SeismicFile, n, base: int, traceAt: untyped) =
  # Yields the runs over positions `0 ..< n` (trace `traceAt(pos)`), shifted by `base`.
  var a = 0
  while a < n:
    let ta = traceAt(a)
    let ea = f.index.entries[ta]
    let dt = f.intervalOf(ta)
    var b = a + 1
    while b < n:
      let tb = traceAt(b)
      let eb = f.index.entries[tb]
      if eb.channelSet != ea.channelSet or eb.numSamples != ea.numSamples or
          not sameInterval(f.intervalOf(tb), dt):
        break
      inc b
    yield (base + a) ..< (base + b)
    a = b

iterator uniformRuns*(f: SeismicFile, traces: Slice[int]): Slice[int] =
  ## Splits `traces` into runs of consecutive traces that share one channel
  ## set, sample interval and sample count, in order: each run can be read
  ## into one tensor with one `dt` and no padding (for callers that read
  ## without a `Prefetcher`, whose `uniform` chunks split on channel set
  ## and interval but not on sample count). The interval
  ## comes from the stored keys, else from the headers (`sampleIntervalUs`).
  ## Raises `ValueError` for traces out of range (an empty range must start
  ## in `0 .. len`) or a closed file without stored keys.
  checkSpan(traces, f.len)
  let first = traces.a
  template at(pos: int): int = first + pos
  runsOver(f, spanLen(traces), first, at)

iterator uniformRuns*(f: SeismicFile, traces: openArray[int]): Slice[int] =
  ## `uniformRuns` over a list of traces (a gather, a sort order): yields
  ## runs of positions in the list, whose traces share one channel set,
  ## sample interval and sample count. Raises `ValueError` for a trace out
  ## of range.
  for t in traces:
    if t < 0 or t >= f.len:
      raise newException(ValueError, "trace " & $t & " is outside 0 ..< " & $f.len)
  template at(pos: int): int = traces[pos]
  runsOver(f, traces.len, 0, at)
