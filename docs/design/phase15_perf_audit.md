# Phase 15.3 performance audit

Status: complete (2026-11-09). Read-only audit; no source changed. Prototypes lived in a scratch copy of `src`.

Machine: Ryzen 9 3950X (Zen 2), 32 threads, Nim 2.4.0, gcc 12, ORC. Builds: "danger" =
`-d:danger -d:release --opt:speed --passC:-march=native`; "release" = `-d:release` (the CLI).
Data: bench/data small scale unless noted.

Scratch tools (not in the repo): a decode loop over `readTracesInto` with a chosen chunk,
best of N passes, warm; full-scale format files generated with `bench/gen --scale=full`
into `/tmp/pl/benchdata` (y-ibm, y-ieee, y-int16, d21-8058, d21-8015, d21-8024, s2-ieee,
y-ieee-1m). GB/s are of file bytes, float32 output, 1000-trace chunks unless noted.

## 1. Build target: SSE2 release vs x86-64-v2/v3 [owner decision] S

Measured (full-scale files, `readTracesInto`, 1 thread, warm, GB/s):

| file | `-d:release` (SSE2) | release `-march=x86-64-v2` | release `-march=x86-64-v3` | danger native |
|---|---:|---:|---:|---:|
| y-ibm | 5.44 | 5.48 | 6.52 | 6.67 |
| y-ieee (BE) | 8.17 | **19.67** | **25.52** | 23.85 |
| y-int16 | 14.05 | 13.90 | 14.82 | 15.88 |
| d21-8058 | 10.63 | **19.07** | **22.56** | 24.27 |
| d21-8015 | 2.27 | 2.26 | 2.50 | 2.54 |
| d21-8024 | 2.13 | 2.12 | 1.94 | 1.94 |

- Root cause: the big-endian loops (`segy/samples.nim` `loadNum` + `fromStored` →
  `swapBytes`) need `pshufb` (SSSE3) to vectorize; baseline x86-64 does the swap with
  shifts. v2 alone gives 2.4x on BE IEEE and 1.8x on 8058; v3 (AVX2) another 15 to 30 %.
  The release-vs-danger gap is entirely the ISA, not the checks: release+v3 matches danger.
- Options, for the owner:
  (a) `--passC:-march=x86-64-v2` in `nim cli`/library guidance (every x86-64 CPU since
  ~2009; safe default); (b) v3 (Haswell 2013 / Zen 1 2017+; breaks on old Atoms/Pentiums
  and some VMs that mask AVX); (c) function multiversioning on the decode loops only:
  `{.codegenDecl: "__attribute__((target_clones(\"avx2\",\"default\"))) $1 $2 $3".}` on
  `decodeSamplesRaw`/`decodeSegdSamplesRaw`/`decodeSeg2SamplesRaw` (they are generic: the
  attribute has to sit on non-generic per-format/per-type inner procs). GCC/clang + glibc
  ifunc only (no macOS/Windows MSVC); the library is consumed as Nim source so the flag is
  really the *application's* build policy.
- Recommendation: (a) now in the `cli` task and in `docs/` guidance for HPC users
  ("build with `-march=x86-64-v3` or native"); (c) only if a portable binary is shipped.
- Risk: none for correctness (same C, different ISA); binaries won't start on older CPUs.

## 2. Host-order copies (LE IEEE SEG-Y, SEG-D 9058, SEG-2 float32): memcpy is the slow path on Zen 2 [optional] S

- `y-ieee-le` (a `copyMem` per trace, `segy/samples.nim` sfFloat32 `when o == hostOrder`)
  runs at 18.5 GB/s vs 26.3 GB/s for big-endian (a swap loop). perf: 95 % in
  `__memmove_avx_unaligned_erms`; 4000-byte rows sit right at glibc's `rep movsb`
  threshold, and Zen 2 has no FSRM.
- Scratch prototype (12 000 rows of 4000 B at stride 4240 into a 4 MB tensor): danger
  native: memcpy 25.4, plain loop 35.0 (with
  `__attribute__((optimize("no-tree-loop-distribute-patterns")))` so gcc does not turn
  the loop back into memcpy), swap loop 36.1 GB/s. SSE2 release: memcpy 30.9, loop 8.7.
- So the win (+35 %) exists only with AVX2 and on CPUs without fast `rep movsb`; it
  reverses in the SSE2 build. Do it only together with item 1 (b) or (c): under
  `when defined(avx2)`-style gating (`-d:parsesegLoopCopy`), else keep `copyMem`.

## 3. Release-mode checks in header decoding (`fieldlayout.decodeFields`) [do] S

- Profile (`-d:release`, SEG-Y index walk, 500 k traces): `endians.getNum` 36 %,
  `fieldlayout.decodeFields` 13 %, memmove 27 %. 4 370 instructions per trace against
  1 460 in danger. Root cause: `decodeOne` (`common/fieldlayout.nim:150-158`) calls
  `getNum` (`common/endians.nim:110`), which goes through `beU16`/`beU32` byte by byte,
  each byte index bounds-checked in release, with a runtime `case order` per field
  (`reorder`, endians.nim:102) and not inlined.
- Prototype (scratch copy of src): `decodeFields` dispatches the order once
  (`case order` around three `fieldPairs` loops with a `static ByteOrder`) and uses
  `loadNum(byteBuf(b), pos, o)` under `{.push boundChecks: off.}` for numeric `at` fields.
  Measured, 500 k SEG-Y traces:

  | build | before ns/trace | after ns/trace |
  |---|---:|---:|
  | release, index walk | 429 | **246** (1.74x) |
  | release, `keys = true` | 1163 | **971** |
  | danger, index walk | 245 | **225** |
  | danger, `keys = true` | 654 | 610 |

  SEG-D is unchanged by it (its headers are BCD/nibble fields; see item 4).
- Production version: one up-front check `if b.len < layoutBytes(T)` computed at compile
  time from the pragmas (max `at` + size − firstByte), raising `SegTruncatedError` (or a
  `doAssert` since all callers pass fixed-size arrays/map slices). Applies to every
  `decodeFields` caller (binheader, traceheader, headerlist, headerfields, edit, blocks),
  so header listing and `traceFieldColumn` get it too. Risk: low; the round-trip tests
  cover every layout. No API change.

## 4. SEG-Y keys: 430 ns per trace on top of the walk [do] M

Profile (danger, `openSeismic(keys = true)`, 500 k SEG-Y traces, 655 ns/trace):
`fields.evalResolved` 22 %, `fields.raw` 11 %, `fields.geometry` 7 %, `encodeFields` +
memset + `putNum` 8.5 %, `std/times` (`dateTime`, `initDateTime`, `fromEpochDay`,
`floorDiv`, `utcTzInfo`, `civilSeconds`) 12 %, the walk itself the rest.

Root causes, in `segy/fields.nim` and `model/keys.nim`:
- `geometry` (`fields.nim:153`) calls `initView`, which **re-encodes** the decoded
  `SegyTraceHeader` (and Ext1) back into 240-byte arrays (`fields.nim:33-37`) so that
  `raw` can read layout entries by byte position. The reader had those bytes a moment
  earlier (`segy/reader.nim:414`, `hdr`).
- `raw` (`fields.nim:39`) dispatches `case e.kind` and the extension by string
  (`e.extension == ""`, `cmpIgnoreCase(.., "SEG00001")`) for every one of the 19 fields,
  and loads through checked `getNum` with a runtime order.
- Scalars (`co_scal`) are re-read and applied per coordinate; 30 % of `evalResolved`
  is the `vdivsd` of negative scalars (exact division; keep it, but read the scalar once).
- `keys.civilSeconds` (`keys.nim:105`) builds a `DateTime` through `std/times` for every
  trace to get Jan 1 of the year.

Fixes:
1. `civilSeconds`: Jan 1 by the days-from-civil formula (integer only). Prototype checked
   against `std/times` for years 1..9999 (identical), measured **655 → 542 ns/trace**
   together with item 3 (item 3 alone: 610), i.e. about −70 ns/trace. [do] S
2. Keep the raw header bytes: give `SegyTrace` (or the reader) a `rawHeader`/`rawExt1`
   array filled by `readTraceBody` (it already reads into `hdr`/`raw`) and let
   `GeometryReader.geometry` read from them; drop `initView`'s re-encode. Estimated
   −50 to −60 ns (the encode share). Also benefits `fieldValue`. [do] S
3. Resolve each `LayoutEntry`'s header (std / ext1 / proprietary index) to a small enum in
   `Resolved` at `initGeometryReader` time; unchecked `loadNum` with the order dispatched
   once per trace. Estimated −50 ns. [do] S
- Expected total: about 650 → 350 to 400 ns/trace (10 M traces with keys: 6.5 s → ~3.7 s
  warm). Risk: `fieldValue`/geometry semantics must not change; the layout tests
  (`tlayout`, keys tests) cover the stanzas. No API change (a new field in `SegyTrace`
  is additive).
- Not proposed: storing keys as float32 (144 → ~80 B/trace) changes values (coordinates
  above 2^24 lose precision) — owner decision if memory matters more than exactness.

## 5. The index walk goes through the generic stream reader [do] M

After item 3 the danger walk is 221 ns/trace (SEG-Y) and 186 ns (SEG-D). Measured floors
(scratch, danger, 500 k SEG-Y traces of 1 KB samples, fresh map each run):

| walk | ns/trace | user instructions/trace |
|---|---:|---:|
| direct loop over the map, read `numSamples` only, append a `TraceEntry` | **117** | 29 |
| same + `decodeTraceHeader` of the 240 bytes (danger / release) | 196 / 293 | - |
| `openSeismic` (library walk), after item 3 | 221 | ~1 400 |

- The floor (117 ns) is the kernel: one minor fault per 64 KiB of fault-around plus a
  DRAM miss per header; `madvise` SEQUENTIAL/WILLNEED change nothing warm, and
  `MADV_POPULATE_READ` on the whole map is slower (263 ns) because it maps the sample
  pages too. Software prefetch of the header k traces ahead (k = 1..14) is 5 % slower.
- Above the floor: `decodeTraceHeader` of all ~90 fields (80 ns danger, 175 ns release)
  though the walk needs only bytes 115-118 (+ Ext1 bytes for Rev 2, + the fixed-length
  flag); and the `RecordCursor`/`PushbackInput` machinery: two `copyMem`s per trace (a
  512-byte refill `records.nim:176` with `SkipRefill = 512` after every seek, then the
  240-byte header), method dispatch (`readRecordImpl`, `seekForward`,
  `hasRecordBoundaries`), `tryRecord` per trace. Cutting the refill to 240 B: −1 % SEG-Y,
  −10 % SEG-D (172 vs 192 ns).
- SEG-D extra: `findChannelSet` (`segd/reader.nim:300`) iterates `for i, c in
  s.descriptors`, which copies each `SegdChannelSetDescriptor` (the `eqdup_` of
  `segd/headers` at 3.5 % of the walk) — iterate by index / `pairs` over `lent`, and
  try the previous trace's channel set first; `decodeBcdField` is 14 % in release
  (BCD nibble loads checked).
Fixes:
1. [do] S: `findChannelSet` by index plus a last-hit cache. Est. −10 to −15 ns SEG-D.
2. [do] M: a `headersOnly` fast path in `SegyReader.readTraceBody` (`segy/reader.nim:409`)
   for the index walk: decode only `numSamples`, `sampleInterval` (and Ext1 when
   present) unless `keys`; the full `SegyTraceHeader` stays for normal reads. Est.
   −60 to −80 ns/trace SEG-Y (221 → ~150).
3. [optional] M: a zero-copy cursor for `MemFileSource` (`fill` points at the map
   instead of copying into `buf`); removes the memmoves (~20 % of the walk's user time).
   Touches `io/records` and `io/pushback`, used by every reader — test-heavy.
- Together: SEG-Y 221 → ~130 ns/trace danger (10 M traces: 2.4 s → ~1.3 s warm), close to
  the 117 ns floor. The floor itself only moves with item 6 or the index cache (14.3e).

## 6. O(1) open for fixed-length SEG-Y [owner decision] M

- With 1 KB traces every page holds a header, so the walk faults in the whole file:
  10 M traces 2.4 s warm, 23 s cold; 24 GB file 35 s cold (benchmarks.md). The index
  cache (14.3e) fixes repeat opens only.
- Proposal: in `openMapped`, for SEG-Y Rev ≥ 1 with binary 3503 = 1 (fixed length), no
  Ext1 headers (`maxAddlTraceHeaders == 0`), no trailers, and `(size − first) mod stride
  == 0`: fill `entries` arithmetically (`offset = first + i*stride`, a tight loop, about
  1 ns/trace → 10 ms for 10 M, no page touched) and verify a sample of headers (first,
  last, ~64 spread) for `numSamples`/`sampleInterval`. Any mismatch → full walk.
  Expected: 10 M traces open in ~15 ms warm and a few ms + 64 random reads cold (vs 23 s).
- Why it needs the owner: behaviour changes. The walk now reports per-trace
  `dcInconsistent` warnings (`segy/reader.nim:449-455`, up to `MaxRepeats`) and Rev 0
  zero-sample traces; a sampled check misses most of them, and `segyIntervalUs` is taken
  from the binary header. Options: an `openSeismic(…, verify = vfFull|vfSampled)` flag
  (default full, the viewer passes sampled), or sampled by default with a
  `dcInfo` "index computed, N headers checked" diagnostic. `keys = true` still walks
  (or keys stay on-demand via `traceKeysInto`, 14.3a, which already exists).
- The incremental index (open returns after N traces, a worker extends it) is the other
  route; it makes `len` change under the caller and the worker would have to follow the
  thread rules (no `f.map` copies, no raises) — larger and riskier; not recommended
  while the fixed-length path and the index cache cover the big cases.

## 7. SEG-D 8015 and 8024 decoders: data-dependent branches [do] S

- Root cause (`segd/samples.nim`, `decodeSegdSamplesRaw`): `onesFraction` (`:78`) is
  `if negative: -int(...) else: int(q)`, a branch on each sample's sign; the result goes
  through `int` → `float64` → multiply by `float64(1 shl e) / 32768.0` (8015) or
  `pow4[...]` (8024) → `T`. gcc keeps the branch, so nothing vectorizes, and **on real
  data (random signs) it mispredicts half the time**. The benchmark files have smooth
  synthetic waveforms with long runs of one sign, which hides this: on random words the
  current 8015 decoder does 265 Msamples/s (0.66 GB/s), not the 1000 of the benchmark.
  In 8015, stores to `d` sit between byte loads of `s`; `s` is a byte pointer that may
  alias `d`, so every store forces the next group's bytes to be reloaded (perf annotate:
  the four `vmovss` stores take 46 % of the loop).
- Fix (prototyped, bit-exact against the current decoder on 4 M random words, float32):
  - one's complement without a branch: `w = int32(cast[int16](word)); m = w - (w shr 31)`
    (negative → +1, so `0xFFFF` → 0, as `onesFraction`);
  - the scale `2^(e−15)` (8015) / `2^(2e−12)` (8024) built from bits
    (`cast[float32]((127 + e − 15) shl 23)`), exact, no table;
  - compute in `T` directly: m·2^k is exact in float32 (≤ 16-bit fraction), so float32
    output needs no float64 step and gives identical bits;
  - 8015: load the 10 bytes of a group into locals before the 4 stores.
- Measured (full-scale files, 1 thread, warm, GB/s):

  | | danger before | danger after | release before | release after |
  |---|---:|---:|---:|---:|
  | d21-8015 (bench data) | 2.54 | **4.70** | 2.28 | **3.50** |
  | d21-8024 (bench data) | 1.93 | **7.40** | 2.11 | **4.72** |
  | 8015, random words (kernel only) | 0.66 | **4.53** | 0.67 | **3.92** |
  | 8024, random words (kernel only) | 0.50 | **7.79** | 0.51 | **4.93** |

- The same branch is in 8022 (`:144`), 8042/8044 (`if (b and 0x80) != 0: -v`), and the
  SEG-2 format-3 (`s2Float20`) decoder; apply the same pattern (8042/8044: sign-magnitude
  → `copySign`-style xor of the sign bit into the float). Also the encoders
  (`expFraction` calls `pow` in a loop per sample) if conversions to 8015/8024 matter.
- Bench data: add a noisy (random-sign) variant to `bench/gen.nim` or the 8015/8024 rows
  will keep overstating branchy decoders.
- Risk: low; existing codec tests plus a randomized decode-equivalence test against the
  old formula (keep it as a test oracle).

## 8. IBM float: no cheap win found [optional]

- `ibmToFloat64` (`common/ibmfloat.nim:30`) is fraction × `ibmScale[bits shr 24]`, 2.4
  cycles/sample (6.5 GB/s danger, 5.4 release); gcc vectorizes the loop with a gather.
- Tried: scale built from bits in float64 (no table, no select; vectorized with 32-byte
  vectors): 6.1 GB/s, i.e. no better. A float32-only path (24-bit fraction is exact in
  float32) needs two-step scaling for the subnormal range to stay single-rounded; not
  worth it for ≤ 20 %. With N threads IBM already reaches memory bandwidth at 8 threads.

## 9. "SEG-2 at half the SEG-Y speed" is a benchmark artifact [do: bench only] S

- `s2-ieee` has 4 000 samples per trace (`bench/specs.nim:59`), so the suite's 1000-trace
  chunk is a 16 MB float32 tensor, against 4 MB for the 1000-sample SEG-Y files; it no
  longer stays in L2/L3. Same decoder path (`copyMem`, LE float32). Measured (small file,
  danger): chunk 1000 → 12.8 GB/s, chunk 250 → **24.3**, chunk 64 → 23.9 GB/s, i.e. the
  same as host-order SEG-Y. No library change; size the suite's chunk by bytes
  (e.g. `chunk = 4 MB div (maxSamples * 4)`) so the rows compare like with like.

## 10. Multi-thread fall-off beyond 16 threads: per-thread tensor vs L2 [do: docs/bench] S

Measured on a quiet machine (load < 1), full-scale y-ieee, threads created and tensors
touched before timing, GB/s of the slowest thread:

| chunk (tensor/thread) | 1 | 4 | 8 | 16 | 24 | 32 |
|---|---:|---:|---:|---:|---:|---:|
| 256 traces (1 MB) | 22.8 | 48.8 | 47.1 | 49.4 | 45.5 | **32.3** |
| 64 traces (256 KB) | 23.3 | 47.9 | 48.0 | 49.4 | 48.8 | **47.4** |

- The plateau (~49 GB/s from 4 threads) is DRAM bandwidth (dual-channel DDR4-3200,
  51 GB/s peak). The drop at 32 threads appears only when two SMT siblings each write a
  1 MB tensor through one 512 KB L2: the output spills and is written back. With 256 KB
  tensors 32 threads hold 47 GB/s. 8015 (compute-bound) keeps scaling to 32 threads.
- No lock or refcount on the read path (confirmed again: `readTracesInto` makes no
  managed objects per call). Fix: guidance in `docs/processing.md` (“per-thread output
  ≤ 256 KB, i.e. chunk ≈ 64 K samples, when using all SMT threads”) and use 64-trace
  chunks in the suite's 16/32-thread columns. No code change.

## 11. Prefetcher: one worker; large rings fall out of cache [do] S–M

- Throughput with one worker is one core: fine for IEEE (21 GB/s), the limit for IBM
  (6.3), 8015 (2.5; 4.7 after item 7) and 8024. Measured `next` vs `nextInto`
  (recycling) are identical (20.7/20.8, 12.8/12.9 GB/s): allocation is not the cost.
- The drop for 1024×4 and 256×16 (21 → 12.8 GB/s) is the ring's size: 16 MB of slot
  buffers no longer fit L3, so every chunk goes to DRAM and back. Cap the default ring
  at ~4 MB (or document "chunkTraces × depth × cols × sizeof(T) ≤ 4 MB").
- N workers (`newPrefetcher(..., workers = 1)`): the slot protocol already lets a
  worker claim `nextChunk` under the lock and decode unlocked (`prefetch.nim:160-180`),
  and the consumer takes in order (`takeChunk`), so more workers need: N threads, `quit`
  broadcast and join in `shutdown`, `broadcast(work)` instead of `signal`, and the
  per-slot `gen` check (already there) for seeks. Est. 2 workers: IBM 6.3 → ~12 GB/s,
  8015 4.7 → ~9 GB/s; the seek latency (one chunk's decode) unchanged. Additive API
  (default 1). Thread rules: workers already only call `tryDecodeEntry` (no raises, no
  `f.map` copy), so nothing new. [do] M
- Seek latency = one chunk's decode (1024 traces: 540 µs). A smaller first chunk after
  `seek` (e.g. chunkTraces div 4, then full chunks) would cut it ~4x; this changes chunk
  boundaries the consumer sees (`c.first`/`c.count`) — [owner decision] S.

## 12. Cold reads: `madvise(MADV_WILLNEED)` before scattered reads [do] S

Measured (danger, pages dropped from the cache and unmapped before each run, median of 5):

| read (1000 traces) | file | plain | + WILLNEED per trace span | warm plain | warm + WILLNEED |
|---|---|---:|---:|---:|---:|
| receiver gather (1000 apart) | y-ieee-1m (1.24 GB) | 1 261 ms | **106 ms** (12x) | 0.056 ms | 0.53 ms |
| receiver gather | y-ieee (1.06 GB, 4 KB traces) | 1 687 ms | **183 ms** (9x) | - | - |
| shot gather (consecutive) | y-ieee-1m | 6.0 ms | **1.6 ms** (3.7x) | 0.034 ms | 0.50 ms |

- Root cause: each fault reads one readahead window synchronously, so a scattered read
  is one disk round trip per trace; WILLNEED queues all the reads at once.
- The cost is the syscall when warm: ~0.5 µs per call (0.53 ms for 1000 calls, 10x the
  warm read). So: coalesce consecutive traces into one span (a shot gather is one call),
  advise only selections of ≥ 32 traces or spans ≥ 1 MB, and first probe residency with
  one `mincore` on the first span (and the last); skip the advice when resident. Est. warm
  overhead < 5 µs per call; cold gathers 4 to 12x faster. In `readTracesInto`
  (`traceindex.nim:998-1095`) before `decodeLoop`, and in the prefetcher for chunk n+1
  when it starts chunk n.
- Linux/macOS only (`posix_madvise(POSIX_MADV_WILLNEED)` works on both; Windows:
  `PrefetchVirtualMemory`, or no-op). Read-only advice: no correctness risk; it is a
  hint and the read path is unchanged. Thread rule: the call takes no managed memory and
  raises nothing (ignore the result), so it is safe on the prefetch worker.

## 13. Conversion CPU: a verify-by-re-decode on every trace [do] S–M

Profile (danger, `convertFile` d21-8058 → SEG-Y format 5, 1 GB): `convert.encodeExact`
20 %, `segy.encodeSamples` 15 %, `segy.decodeSamplesRaw` 6 % (the re-decode),
`decodeSegdSamplesRaw` 5 % (the real decode), memmove 8 %, `encodeFields` 4 %.
- Root cause: `encodeExact` (`convert.nim:202`) decodes every trace to float64, encodes
  it, decodes the encoded bytes again into `scratch` and compares element-wise, for
  every pair of formats — including float32 → float32 (8058 → 5), where it cannot
  fail, and int16 → int32 etc. `encodeSamples` (`segy/samples.nim:219`) writes through
  `putNum` with a runtime order (checked byte stores in release).
- Fixes:
  1. Skip the check when the target holds every value of the source format (a static
     table: 8058/9058/SEG-2 4/SEG-Y 5 → 5 or 6; any integer ≤ 24 bits → 5; int32 → 6; …).
     [do] S. Est. −40 % of the CPU for 8058 → SEG-Y.
  2. For an IEEE float32 target, check `float64(float32(x)) == x` (or both NaN) while
     encoding, instead of encode + decode + compare (IBM → IEEE). [do] S.
  3. Same byte layout (SEG-D 8058 big-endian → SEG-Y 5 big-endian, SEG-Y → SEG-Y same
     format and order): copy the sample bytes (no float round trip). [do] S.
  4. `encodeSamples`: `forEachOrder` + unchecked stores as in the decoders. [do] S.
- Expected: SEG-D 8058 → SEG-Y from 1.3 to ~4 GB/s of CPU, IBM → IEEE 1.5 → ~3 GB/s.
  Wall time here stays at this machine's write speed (0.2 to 0.4 GB/s), so the gain
  shows on NVMe or with several conversions in parallel. Risk: the "exact" guarantee
  must be preserved — keep `encodeExact` as the fallback and as a test oracle over
  every (source, target) pair.

## 14. Per-trace header access [optional] S

Measured (danger / release, 1000 random consecutive traces, pages mapped):

| | SEG-Y | SEG-D |
|---|---:|---:|
| `traceFieldColumnInto` | **5.6 / 8.9 ns** per trace | 6.1 / 8.5 ns |
| `traceField` loop | 196 / 382 ns | 137 / 156 ns |
| `traceKeysInto` | 483 / 988 ns | 76 / 139 ns |

- The benchmark row "header column: trace.sourceX of 1000 traces" (263 µs) is a
  `traceField` loop (`bench/suite.nim:302`), not `traceFieldColumn`; benchmarks.md's
  Phase 14 text attributes 0.15-0.26 µs/trace to `traceFieldColumn`. Fix the label and
  add a real column row (5.6 ns/trace) — [do] S.
- `traceField` decodes the whole block and then compares the name with every field
  (`headerfields.nim:389`, `fieldByName`): fine for one-off reads; the docs already
  steer loops to `traceFieldColumn`. Item 3 halves it in release.
- `traceKeysInto` for SEG-Y is item 4's cost.

## 15. Journaled edits and allocation churn [optional]

- Batched edits are journal-bound (NIF line + fsync per 4 096 edits; 78 k to 260 k edits/s);
  CPU is small. A binary journal would be 5 to 10x faster; not needed for header patches.
- Allocation churn: no per-trace managed allocation on the decode path (`decodeLoop`,
  `tryDecodeEntry`, prefetch `take` with recycling). The walk's SEG-D copies in
  `findChannelSet` (item 5) are the only per-trace `=dup` seen in the profiles; the
  conversion path shows `rawAlloc` at 1 %.

## Summary

| # | item | tag | size | gain |
|---|---|---|---|---|
| 1 | build target x86-64-v2/v3 or multiversioning | owner decision | S | measured: release BE IEEE 8.2 → 19.7 (v2) / 25.5 (v3) GB/s; 8058 10.6 → 19.1 / 22.6 |
| 2 | loop instead of `copyMem` for host-order samples | optional (with 1) | S | measured kernel +38 % (AVX2 only; −70 % in SSE2) |
| 3 | unchecked, order-dispatched `decodeFields` | do | S | measured: release SEG-Y walk 429 → 246 ns/trace; danger 245 → 225 |
| 4 | SEG-Y keys: civil date, raw bytes, resolved entries | do | M | measured −70 ns (date); est. 650 → 350-400 ns/trace |
| 5 | index walk: header-only fast path, `findChannelSet` | do | M | est. SEG-Y 221 → ~130-150 ns/trace (floor 117) |
| 6 | O(1) open for fixed-length SEG-Y | owner decision | M | est. 10 M traces 2.4 s → ~15 ms warm, 23 s → ms cold |
| 7 | branchless 8015/8024 (and 8022/8042/8044/SEG-2 f3) | do | S | measured 8015 2.5 → 4.7, 8024 1.9 → 7.4 GB/s; 7-15x on random-sign data |
| 8 | IBM float | optional | - | none found |
| 9 | SEG-2 "half speed" | do (bench) | S | artifact: 12.8 vs 24.3 GB/s at equal tensor size |
| 10 | >16-thread fall-off | do (docs/bench) | S | artifact: 32.3 → 47.4 GB/s at 32 threads with 256 KB tensors |
| 11 | prefetch: N workers, ring ≤ 4 MB, small first chunk | do / owner (first chunk) | M | est. 2x for IBM/8015; measured ring 16 MB → 4 MB: 12.8 → 21 GB/s |
| 12 | `MADV_WILLNEED` for scattered cold reads | do | S | measured cold receiver gather 1261 → 106 ms, shot gather 6.0 → 1.6 ms |
| 13 | conversion: skip impossible-loss checks, byte copy | do | S–M | est. 8058 → SEG-Y 1.3 → ~4 GB/s of CPU |
| 14 | header access; fix bench label | optional / do (bench) | S | column read is 5.6 ns/trace already |
| 15 | journal, allocation churn | optional | - | nothing hot |

## Ordered plan (commit-sized, biggest gain per risk first)

1. **7: 8015/8024 branchless decoders** (+ 8022/8042/8044, SEG-2 format 3) with a
   randomized equivalence test against the old formulas. Biggest real-data gain, local.
2. **3: unchecked `decodeFields`** with a compile-time layout size check. Closes the
   release/danger index gap; every header path benefits.
3. **12: `madvise(WILLNEED)`** in `readTracesInto` (selections/large spans, mincore
   probe) and in the prefetcher for the next chunk.
4. **4.1 + 5.1: `civilSeconds` arithmetic; `findChannelSet` by index + last hit.**
5. **13.1-13.4: conversion** fast paths (exactness table, float32 check, byte copy,
   unchecked encoders), keeping `encodeExact` as the fallback/oracle.
6. **4.2-4.3: SEG-Y keys from raw header bytes** with resolved entries.
7. **5.2: header-only fast path** in `SegyReader.readTraceBody` for the walk.
8. **11: prefetcher** `workers` parameter and ring-size cap/guidance.
9. **Bench/docs (9, 10, 14):** size suite chunks by bytes, 64-trace chunks at 16/32
   threads, a noisy 8015/8024 file, the `traceFieldColumn` row; per-thread buffer
   guidance in `processing.md`. Re-run the full scale once.
10. **Owner decisions:** 1 (build target / `target_clones`; then 2), 6 (O(1) fixed-length
    open and its `verify` semantics), 11 (smaller first chunk after `seek`), keys as
    float32 (item 4, not recommended).
