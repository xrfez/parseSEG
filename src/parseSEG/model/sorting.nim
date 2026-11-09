## Sorting traces by header fields (task 14.3b): `sortTraces` returns a
## permutation, a list of trace indices, and never moves data. Decode a sorted
## view with the list forms of `readTracesInto` / `newPrefetcher`.
##
## ```nim
## var f = openSeismic("line.sgy")
## let order = f.sortTraces(["trace.ensemble", "trace.offset"]) # CMP gathers by offset
## let first = f.readTraces(order[0 ..< 100])
## f.close()
## ```
##
## Each key is read once as a float64 column (`traceFieldColumn`), mapped to
## an order-preserving 64-bit integer, and the trace positions are sorted by
## a stable LSD radix sort, last key first. Nothing is compared through the
## field names, so 10 million traces sort in well under a second per key
## (plus the column read); memory is about 32 bytes per trace.

import std/math
import ./[traceindex, headerfields]

const
  DigitBits = 11
  Buckets = 1 shl DigitBits
  Passes = (64 + DigitBits - 1) div DigitBits

func sortKey(x: float64): uint64 {.inline.} =
  # Order-preserving: negatives below positives, -0 == 0, NaN above all.
  if x.isNaN: high(uint64)
  elif x == 0: 1'u64 shl 63
  else:
    let u = cast[uint64](x)
    if (u shr 63) != 0: not u else: u or (1'u64 shl 63)

proc radixSort(keys, keyTmp: var seq[uint64], pos, posTmp: var seq[uint32]) =
  # Stable sort of `pos` by `keys` (kept parallel). Passes whose digit is the
  # same for every key are skipped.
  let n = keys.len
  var counts = newSeq[array[Buckets, int]](Passes)
  for k in keys:
    for p in 0..<Passes: inc counts[p][int((k shr (p * DigitBits)) and (Buckets - 1))]
  for p in 0..<Passes:
    let shift = p * DigitBits
    var single = false
    for c in counts[p]:
      if c == n: single = true
    if not single:
      var sum = 0
      for b in 0..<Buckets:
        let c = counts[p][b]
        counts[p][b] = sum
        sum += c
      for i in 0..<n:
        let d = int((keys[i] shr shift) and (Buckets - 1))
        let at = counts[p][d]
        keyTmp[at] = keys[i]
        posTmp[at] = pos[i]
        counts[p][d] = at + 1
      swap(keys, keyTmp)
      swap(pos, posTmp)

template sortBy(n: int, keyCount: int, fill: untyped): seq[uint32] =
  # Positions `0 ..< n` sorted by `keyCount` columns, the last first; `fill(j,
  # col)` puts column `j` (one float64 per position) into `col`.
  if n > int(high(uint32)): raise newException(ValueError, "too many traces to sort")
  var pos = newSeq[uint32](n)
  for i in 0..<n: pos[i] = uint32(i)
  var col = newSeq[float64](n)
  var keys, keyTmp = newSeq[uint64](n)
  var posTmp = newSeq[uint32](n)
  for j in countdown(keyCount - 1, 0):
    fill(j, col)
    if n > 1:
      for i in 0..<n: keys[i] = sortKey(col[int(pos[i])])
      radixSort(keys, keyTmp, pos, posTmp)
  pos

proc sortOrder*(columns: openArray[seq[float64]]): seq[int] =
  ## The positions `0 ..< n` of `n` rows sorted by the columns (one value per
  ## row, the first column first), with the rules of `sortTraces`: ascending,
  ## stable, NaN last, -0 equal to 0. For keys that are no header field, such
  ## as `TraceKeys` (`traceKeys(f, traces)`) or survey values. No columns give
  ## an empty result. Raises `ValueError` when the columns differ in length.
  if columns.len == 0: return @[]
  let n = columns[0].len
  for c in columns:
    if c.len != n: raise newException(ValueError, "the columns differ in length")
  template fill(j: int, col: var seq[float64]) =
    for i in 0..<n: col[i] = columns[j][i]
  let pos = sortBy(n, columns.len, fill)
  result = newSeq[int](n)
  for k, p in pos: result[k] = int(p)

proc sortTraces*(f: SeismicFile, by: openArray[string], traces: openArray[int]): seq[int] =
  ## The traces of `traces` sorted by the numeric header fields `by` (names
  ## as in `traceFieldColumn`, e.g. "trace.ensemble", "ext1.receiverLine"),
  ## the first key first: ascending, stable (equal keys keep their order in
  ## `traces`), NaN (a trace without the field's block, a SEG-2 keyword that
  ## is missing or not a number) after every number, and -0 equal to 0. The
  ## result is a list of trace indices: a permutation of `traces` that moves
  ## no data (decode it with `readTracesInto(f, order, ...)`). No keys give
  ## `traces` unchanged. Raises `ValueError` as `traceFieldColumn` does: an
  ## unknown, text or raw field, a trace out of range or a closed file.
  for i in traces:
    if i notin 0 ..< f.len:
      raise newException(ValueError, "no trace " & $i & " (the file has " & $f.len & ")")
  template fill(j: int, col: var seq[float64]) =
    f.traceFieldColumnInto(by[j], traces, col) # also checks the name when n < 2
  let pos = sortBy(traces.len, by.len, fill)
  result = newSeq[int](pos.len)
  for k, p in pos: result[k] = traces[int(p)]

proc sortTraces*(f: SeismicFile, by: openArray[string], traces: Slice[int]): seq[int] =
  ## `sortTraces` over a range of traces (an empty range must start in
  ## `0 .. f.len`).
  checkSpan(traces, f.len)
  var list = newSeq[int](spanLen(traces))
  for k in 0..<list.len: list[k] = traces.a + k
  f.sortTraces(by, list)

proc sortTraces*(f: SeismicFile, by: openArray[string]): seq[int] =
  ## Every trace of the file sorted by `by`; see the list form.
  f.sortTraces(by, 0 ..< f.len)
