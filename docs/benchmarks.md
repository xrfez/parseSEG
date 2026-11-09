# parseSEG benchmarks (task 13.2)

What a high-performance processing library and an interactive viewer need from parseSEG,
measured on synthetic files from 0.26 GB to 24 GB and up to 10 M traces: index build and
keys, time to first trace, sequential decode per format against memory bandwidth, viewer
latencies (p50/p99/max), multi-thread scaling, the prefetcher, conversion, in-place
edits and geometry write-back. The fixes this task made are measured before and after, in
both the `-d:danger -march=native` build (`nim nimRelease`) and the `-d:release` build
(`nim cli`).

> **Current numbers: [Phase 15](#phase-15-full-scale-re-run-2026-11-09)** (full scale,
> 2026-11-09, after the Phase 15 performance review). The sections after it are history:
> the 2026-11-08 full-scale tables (before the C ABI and Python module were removed) and the
> Phase 14 small-scale re-run.

## Machine

- AMD Ryzen 9 3950X, 16 cores / 32 threads, 31 GB RAM, Debian 12 container, kernel 7.2.
- Storage: a btrfs file system with zstd compression on dm-crypt, on SATA SSDs. Cold
  reads therefore pass through decryption and decompression: sequential `read()` reached
  0.5 to 0.8 GB/s, and writes were throttled to 0.1 to 0.4 GB/s. Cold numbers measure this
  storage stack more than the library.
- Shared: on 2026-11-08 other agents ran test suites at the same time (load average 4 to
  20 on 32 threads), so multi-thread numbers above 8 threads and all tail latencies are
  noisy. The before/after tables were run back to back with the same load pattern. The
  Phase 15 re-run ran alone (load average below 1 at the start).
- Nim 2.4.0, gcc 12, default ORC memory management.

## Method

- `bench/gen.nim` writes the data set (`bench/specs.nim`): SEG-Y formats 1, 2, 3 and 5
  (big- and little-endian), SEG-D Rev 2.1 8058/8015/8024 and Rev 3.0 8058 (1000 traces per
  record), SEG-2 format 4 (16 k traces of 4000 samples), each 250 k traces of 1000 samples
  (0.26 to 1.1 GB); since 15.3-14 also 8015 and 8024 files of random values of random
  sign, which give a decoder's branches nothing to learn; SEG-Y and
  SEG-D files of 1 M and 10 M traces (250 / 100 samples; 12.4 GB and 4.5 GB at 10 M); and
  a 24.5 GB SEG-Y file (2 M traces of 3000 samples) larger than the free page cache. SEG-D
  and SEG-2 go through the library's writers; headers carry a shot geometry so keys,
  gathers and write-back see real values. Full scale is 53 GB.
- `bench/suite.nim` runs the sections and prints Markdown (also saved as
  `results-<scale>-<build>.md` in the data directory). Times are wall clock, `std/monotimes`.
  Throughput tables count file bytes. Warm: the file is read once first; best of 3.
  Cold: the file's pages are unmapped from the process (`madvise(MADV_DONTNEED)`) and
  dropped from the page cache (`posix_fadvise(POSIX_FADV_DONTNEED)`); `drop_caches` is
  not writable in the container. Memory: growth of the Nim heap (`getOccupiedMem`).
- Buffer sizes (since 15.3-14, perf audit items 9 and 10): decode chunks hold 4 MB of
  float32 samples (1000 traces of 1000 samples, 250 of the SEG-2 file's 4000; it used 1000
  traces whatever their length, so SEG-2 wrote a 16 MB tensor and looked half as fast); in
  the thread table each thread's tensor is 1 MB up to 8 threads and 256 KB from 16 threads.
- Profiles: `perf record` (installed in the container) on the hot loops; the fixes below
  came from those profiles and from the R2 performance review.

## How to rerun

```sh
nim bench                                   # small scale (about 2.6 GB), a few minutes
PARSESEG_BENCH_SCALE=full PARSESEG_BENCH_DIR=/big/disk nim bench   # 53 GB, about an hour
PARSESEG_BENCH_SECTIONS="decode latency" nim bench                 # some sections only
PARSESEG_BENCH_BUILD=release nim bench      # the shipped build: -d:release, x86-64-v3
PARSESEG_BENCH_BUILD=portable nim bench     # -d:release, baseline x86-64 (SSE2)
PARSESEG_BENCH_WARM_ONLY=1 nim bench        # skip the disk-bound cold runs
```

`nim bench` builds `bench/gen` and `bench/suite` (nimRelease flags by default:
`-d:danger -march=native`), writes the files that are missing (existing files of the
expected size are kept, so a data directory can be reused), and runs the suite. The data
directory defaults to `bench/data` (gitignored). Sections: `baseline index decode latency
threads prefetch write`.

## Phase 15: full-scale re-run (2026-11-09)

After the Phase 15 performance review (`docs/design/phase15_perf_audit.md`, steps 15.3-2 to
15.3-14 in `PLAN.md`), the whole suite at full scale (53 GB), once in each build:

- **danger:** `nim bench` (`-d:danger -d:release --opt:speed -march=native`), all sections,
  cold runs included;
- **release v3:** `PARSESEG_BENCH_BUILD=release PARSESEG_BENCH_WARM_ONLY=1 nim bench`
  (`-d:release -march=x86-64-v3`, the shipped `nim cli` build), sections `decode index latency
  prefetch write` (the cold runs measure the disk, not the build).

Machine as above (Ryzen 9 3950X, Zen 2, 32 threads, 31 GB, dual-channel DDR4-3200; btrfs on
dm-crypt), alone on it this time; Nim 2.4.0, gcc 12, ORC. Data in `/tmp/pl/benchdata`, made
by `bench/gen` (existing files reused). Method as above, with the 15.3-14 suite: 4 MB decode
chunks, L2-sized thread tensors, a full-walk column next to the default (sampled) open, a
real header column row, prefetch rows with `workers` and `quickFirst`, and random-sample
8015/8024 files. The tables were taken before the last 15.3-14 change (one residency probe
instead of two for a range: about 1 µs less per warm range read, measured separately).

### Headline: 2026-11-08 → Phase 15

2026-11-08 is the danger full-scale run below ("Full results after the fixes").

| measure | 2026-11-08 danger | Phase 15 danger | Phase 15 release v3 |
|---|---:|---:|---:|
| decode GB/s, 1 thread: SEG-Y IBM float | 6.53 | 6.55 | 6.40 |
| SEG-Y IEEE, big-endian | 22.47 | 21.57 | 25.17 |
| SEG-Y IEEE, little-endian | 17.27 | 22.29 | 22.41 |
| SEG-Y int32 / int16 | 21.85 / 15.49 | 21.34 / 15.20 | 23.91 / 15.13 |
| SEG-D 2.1 8058 / 3.0 8058 | 22.40 / 23.30 | 21.80 / 21.78 | 22.47 / 22.32 |
| SEG-D 8015 (smooth / random samples) | 2.55 / - | 4.71 / 4.71 | 4.64 / 4.67 |
| SEG-D 8024 (smooth / random samples) | 1.98 / - | 6.98 / 7.01 | 6.91 / 6.90 |
| SEG-2 float32 (4 MB chunks since 15.3-14) | 11.48 | 26.93 | 27.04 |
| open y-ieee-10m (10 M traces, 12.4 GB), warm | 2437 ms | 20.5 ms | 21.9 ms |
| open y-ieee-10m, cold / cold to first trace | 19.9 s / 23.0 s | 49 ms / 27 ms | - |
| open y-ieee-big (24.5 GB), cold | 37.4 s | 54 ms | - |
| index walk (`vfFull`), SEG-Y 10 M, ns/trace | 244 | 169 | 191 |
| index walk with keys, SEG-Y 10 M, ns/trace | 682 | 387 | 480 |
| index walk, SEG-D 2.1 10 M, ns/trace (keys) | 197 (229) | 188 (245) | 252 (299) |
| cold receiver gather p50, y-ieee-10m / d21-8058-10m | 222 / 55 ms | 72 / 21 ms | - |
| cold shot gather p50, y-ieee-10m / d21-8058-10m | 15.0 / 1.2 ms | 3.0 / 1.25 ms | - |
| header column, 1000 traces (`traceFieldColumnInto`) | - | 22.5 µs (SEG-Y), 18.0 µs (SEG-D) | 29.3 / 23.4 µs |
| 32 threads, y-ieee / y-ibm, GB/s | 30.4 / 28.9 | 46.8 / 44.6 | - |
| prefetch, 4 workers (256 x 4): y-ibm / d21-8015, GB/s | 6.44 / 2.52 (1 worker) | 22.86 / 16.23 | 22.71 / 16.78 |
| prefetch seek → first chunk, y-ieee 1024 traces, p50 | 559 µs | 242 µs (`quickFirst`) | 285 µs |
| conversion CPU, GB/s of input: y-ibm → IEEE / d21-8058 → SEG-Y / s2 → SEG-Y | 1.5 / 1.3 / 1.5 | 2.1 / 1.8 / 2.3 | 1.8 / 1.8 / 1.7 |

Reading them:
- **Decode:** the big-endian formats are at memory speed in both builds (the v3 release
  build is now as fast as danger; before 15.3-5 it was half). 8015/8024 are 2-3.5x faster
  and no longer depend on the data (random signs and exponents decode as fast as a smooth
  sine). SEG-2 was never slow: the old suite gave it a 16 MB tensor (audit item 9).
- **Open:** fixed-length SEG-Y is O(1) by default. The walk, still used for SEG-D, SEG-2,
  variable-length SEG-Y, keys and `vfFull`, is 30 % faster; keys cost about 220 ns per
  trace on top of it (was 440).
- **First touch after a sampled open:** a sampled open does not read every header page, so
  the first read of each page in this process takes a minor page fault even when the file
  is cached: random single traces on y-ieee-10m take 3.6 µs p50 instead of 0.3 µs (the walk
  used to take those faults at open, 1.7 s for this file). They are paid once per page;
  the walked SEG-D file still shows 0.3 µs.
- **Cold reads:** read-ahead advice (15.3-4, 15.3-14) makes cold gathers 3x faster here;
  cold sequential reads stay at the disk's 0.7-0.8 GB/s.
- **Threads:** with 256 KB per-thread tensors, 32 threads hold 45-47 GB/s (audit item 10);
  8015 now saturates memory bandwidth from 16 threads.
- **Conversions** are bound by this machine's write speed (0.1-0.4 GB/s); the CPU column is
  what a faster disk would see. 15.3-8 measured the conversion code alone with a null sink:
  1.4 to 5.2 GB/s.
- **Release vs danger:** within 10 % everywhere except the index walk with keys (480 vs 387
  ns/trace) and SEG-D walks (252 vs 188), where danger also drops overflow checks.

#### Warm gathers and the read-ahead probes (15.3-14)

15.3-4 noted the warm 1000-trace gathers' medians rose by about 6 µs. Measured again with
the same binary built with and without the advice (danger, 2000 gathers per run, medians):

| | no advice | 15.3-4 (two probes) | 15.3-14 |
|---|---:|---:|---:|
| d21-8058-10m shot gather (1000 traces, 452 KB), warm | 28.7-28.9 µs | 30.1-31.0 µs | 29.3-30.0 µs (one probe) |
| d21-8058-10m receiver gather (1000 traces), warm | 140.7-141.7 µs | 143.6-144.6 µs | 141.7-143.6 µs |
| y-ieee-1m receiver gather, warm | 253.6-254.9 µs | 253.5-254.2 µs | 251.3-255.0 µs |
| y-ieee-1m receiver gather, cold | 1261 ms | 105-140 ms | 105 ms |
| y-ieee-1m shot gather, cold | 6.37 ms | 1.85-2.80 ms | 1.83 ms |
| prefetch 64 x 4, warm, y-ieee | 22.3-22.5 GB/s | 18.7-19.6 GB/s | 21.8-22.3 GB/s |
| prefetch, 100 k trace range, cold, y-ieee-1m | 101-110 ms | 134-136 ms | 100 ms |
| prefetch, 4000 scattered traces, cold, y-ieee-1m | 1174-1178 ms | 382-386 ms | 384-385 ms |
| `readTracesInto` sequential, cold, 64 / 1000-trace chunks, y-ieee | 0.76 / 0.76 GB/s | 0.35 / 0.65 GB/s | 0.76 / 0.73-0.76 GB/s |

One `mincore` call costs 0.66-0.76 µs here (`madvise` of one page 0.44 µs, of 4 MB of
resident pages 40.7 µs). So the probes cost about a syscall each, a little more in cache
effects, not 6 µs;
the rest of 15.3-4's rise was run-to-run noise (one binary's y-ieee-1m shot gather median
moves between 62 and 77 µs between runs). Skipping the probe and always advising is far
worse warm (40 µs for 4 MB of resident pages). The real costs were elsewhere and are fixed:
- the prefetcher probed every chunk: 16 % of a warm 64-trace-chunk run. It now advises
  about 4 MB at a time, and a range only once after a start or `seek`;
- advice per chunk stalled the kernel's sequential read-ahead: cold sequential reads in
  64-trace chunks ran at half the disk's speed. A range that continues a sequential read
  (the byte before it is in memory) is no longer advised;
- a range is probed at its last trace only; a selection at both ends.

#### Per step, before → after

From the `PLAN.md` Log lines of each step (danger = `-d:danger -march=native`, release =
`-d:release -march=x86-64-v3` from 15.3-5 on; full-scale files unless noted).

| Step | What changed | Measure | Before → after |
|---|---|---|---|
| 15.3-2 (P7) | Branchless SEG-D 8015/8022/8024/8042/8044 and SEG-2 format 3 decoders | `readTracesInto`, GB/s, danger / release | 8015: 2.57 → 4.75 / 2.27 → 3.47; 8024: 1.94 → 7.16 / 2.14 → 4.82 (random words: 8015 0.68 → 4.82, 8024 0.50 → 6.99) |
| 15.3-3 (P3) | `decodeFields`: one length check, unchecked loads, byte order picked once | SEG-Y index walk, ns/trace, release / danger | 429 → 242 / 244 → 224 (keys 1172 → 928 / 661 → 612) |
| 15.3-4 (P12) | `madvise(WILLNEED)` before large scattered reads and in the prefetcher | cold reads, y-ieee-1m, danger | receiver gather 1261 → 106 ms; shot gather 5.97 → 1.64 ms; prefetch of 4000 scattered traces 1462 → 418 ms |
| 15.3-5 (P1, P2) | x86-64-v3 build default; plain copy loop for host-order samples | 1 thread GB/s, release v1 → v3 | y-ieee BE 10.8 → 22.5; y-ieee LE 17.1 → 22.4-23.6; d21-8058 10.6 → 23.2; d31-9058 16.5 → 23.4; s2-ieee 12.5 → 13.4 |
| 15.3-8 (P4.1, P5.1, P13) | Civil-date arithmetic, `findChannelSet` by index, conversion fast paths | conversion CPU, GB/s of input, danger; index walk ns/trace | d21-8058 → SEG-Y 1.76 → 4.20; y-ieee → 6: 1.74 → 5.23; y-ibm → 5: 1.85 → 3.26; SEG-Y keys walk 607 → 530 (release 932 → 828) |
| 15.3-9 (P4.2-4.3, P5.2) | SEG-Y keys from raw header bytes; header-only walk | y-ieee-1m walk ns/trace, danger / release | 226 → 198 / 244 → 200; keys 537 → 397 / 824 → 440 |
| 15.3-10 (P6) | O(1) sampled open for fixed-length SEG-Y | y-ieee-10m open, warm / cold | 1824 → 20 ms / 21.3 s → 39 ms |
| 15.3-11 (P11) | Prefetcher `workers`, 4 MB ring cap, `quickFirst` | GB/s, 1 → 2/4 workers (256 x 4) | y-ibm 6.2 → 10.8/20.0; d21-8015 4.6 → 8.9/16.2; y-ieee 256 x 16: 12.4 → 20.9 (cap); seek → first chunk 1024 x 4: 554 → 319 µs |
| 15.3-14 | Read-ahead advice: none for a range continuing a sequential read, one probe for a range; the prefetcher advises 4 MB at a time, a range once per start or `seek` | danger, y-ieee / y-ieee-1m / d21-8058-10m | cold sequential `readTracesInto`, 64-trace chunks 0.35 → 0.76 GB/s, 1000-trace chunks 0.65 → 0.76; cold prefetch of a 100 k trace range 135 → 100 ms; warm prefetch 64 x 4 19.4 → 21.8-22.3 GB/s; warm shot gather (452 KB) 30.1-31.0 → 29.3-30.0 µs (28.8 without advice); cold gathers unchanged (105 ms, 1.8 ms) |

### Full tables, danger build

#### Baselines: memory and disk on this machine

| what | GB/s |
| --- | ---: |
| memcpy 1 GiB, 1 thread (bytes copied) | 23.20 |
| sum of uint64 over 1 GiB, 1 thread (bytes read) | 40.11 |
| memcpy 1 GiB, 4 threads | 23.28 |
| memcpy 1 GiB, 16 threads | 22.28 |
| memcpy 1 GiB, 32 threads | 21.56 |
| y-ieee, warm: mmap + sum (fresh map each run) | 17.88 |
| y-ieee, warm: read() 8 MiB blocks | 18.42 |
| y-ieee, cold: mmap + sum | 0.76 |
| y-ieee, cold: read() 8 MiB blocks | 0.76 |

#### Index build and keys (openSeismic)

Cold: the file's pages dropped first. Warm: best of 3 with the file cached. Open: the default `openSeismic` (fixed-length SEG-Y: sampled, O(1)); walk: `verify = vfFull` (every header). Memory: managed heap growth (`getOccupiedMem`) of the open file, per trace.

| file | traces | GB | cold open ms | cold first trace ms | cold walk ms | warm open ms | walk ms | ns/trace walk | keys ms | ns/trace keys | heap B/trace | keys heap B/trace | gathers ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | 250000 | 1.06 | 22.65 | 22.33 | 1448.26 | 0.85 | 59.36 | 237. | 108.40 | 434. | 24.2 | 146.8 | 14.20 (250) |
| d21-8058 | 250000 | 1.01 | 1856.60 | 1651.63 | 1651.74 | 105.46 | 105.10 | 420. | 111.58 | 446. | 24.9 | 146.8 | 13.30 (250) |
| y-ieee-1m | 1000000 | 1.24 | 13.83 | 13.86 | 960.17 | 2.45 | 170.02 | 170. | 372.36 | 372. | 24.1 | 146.8 | 54.53 (1000) |
| d21-8058-1m | 1000000 | 0.45 | 780.24 | 780.09 | 778.78 | 177.94 | 179.10 | 179. | 199.85 | 200. | 24.9 | 146.8 | 51.87 (1000) |
| y-ieee-10m | 10000000 | 12.40 | 48.65 | 26.74 | 21629.73 | 20.54 | 1694.71 | 169. | 3869.95 | 387. | 24.3 | 144.0 | 555.33 (10000) |
| d21-8058-10m | 10000000 | 4.52 | 8215.48 | 8083.42 | 8454.36 | 1886.63 | 1879.27 | 188. | 2448.39 | 245. | 25.4 | 144.0 | 534.34 (10000) |
| y-ieee-big | 2000000 | 24.48 | 53.69 | 23.16 | 42506.95 | - | - | - | - | - | - | - | - |

#### Sequential decode throughput (readTracesInto, 4 MB chunks, 1 thread)

GB/s of file bytes. Chunks of 4 MB of float32 samples (1000 traces of 1000 samples, 250 of the SEG-2 file's 4000). First pass: right after `openSeismic` (pages not touched yet fault in); mapped: best of 3 later passes. memcpy baseline: 23.2 GB/s, read baseline 40.1 GB/s.

| file | format | GB | cold GB/s | first pass GB/s | mapped GB/s | Msamples/s | % of memcpy | float64 GB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ibm | SEG-Y 1 (IBM float) | 1.06 | 0.72 | 5.77 | 6.55 | 1544. | 28. | 6.70 |
| y-ieee | SEG-Y 5 (IEEE float) | 1.06 | 0.75 | 15.08 | 21.57 | 5087. | 93. | 17.53 |
| y-ieee-le | SEG-Y 5 (IEEE float, LE) | 1.06 | 0.66 | 11.65 | 22.29 | 5258. | 96. | 18.41 |
| y-int32 | SEG-Y 2 (int32) | 1.06 | 0.55 | 16.14 | 21.34 | 5033. | 92. | 17.58 |
| y-int16 | SEG-Y 3 (int16) | 0.56 | 0.56 | 12.47 | 15.20 | 6786. | 66. | 8.37 |
| d21-8058 | SEG-D 2.1 8058 | 1.01 | 0.62 | 21.72 | 21.80 | 5379. | 94. | 17.88 |
| d21-8015 | SEG-D 2.1 8015 | 0.64 | 0.55 | 4.70 | 4.71 | 1845. | 20. | 3.89 |
| d21-8024 | SEG-D 2.1 8024 | 0.51 | 0.55 | 6.95 | 6.98 | 3399. | 30. | 3.65 |
| d21-8015-noise | SEG-D 2.1 8015 (random samples) | 0.64 | 0.56 | 4.70 | 4.71 | 1844. | 20. | 3.90 |
| d21-8024-noise | SEG-D 2.1 8024 (random samples) | 0.51 | 0.55 | 7.02 | 7.01 | 3416. | 30. | 3.67 |
| d30-8058 | SEG-D 3.0 8058 | 1.01 | 0.55 | 21.10 | 21.78 | 5374. | 94. | 17.92 |
| s2-ieee | SEG-2 4 (float32, LE) | 0.26 | 0.56 | 26.15 | 26.93 | 6677. | 116. | 19.31 |

y-ieee-big (24.48 GB, larger than the free page cache), cold, 1 thread: 0.72 GB/s.

#### Viewer latency on y-ieee-10m (10000000 traces of 250 samples)

Warm: file cached (first touch of a page in this map still faults it in). Cold: the file's pages dropped from the cache before the run (`dropCache`).

| operation | runs | p50 µs | p90 µs | p99 µs | max µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| random single trace, warm (readTracesInto) | 20000 | 3.6 | 5.8 | 6.7 | 152.5 |
| random single trace, warm (readTraces, new tensor) | 5000 | 3.4 | 4.1 | 6.4 | 41.2 |
| shot gather (1000 consecutive traces), warm | 500 | 80.6 | 111.5 | 127.2 | 135.0 |
| receiver gather (1000 traces 1000 apart), warm | 200 | 264.7 | 973.9 | 2509.2 | 2773.9 |
| window: samples 0..199 of 10000 traces, warm | 100 | 1027.4 | 1081.2 | 1393.1 | 1456.5 |
| 10000 whole traces, warm | 100 | 961.9 | 1088.8 | 1393.5 | 1400.3 |
| trace header listing (traceHeaders), warm | 5000 | 3.8 | 7.3 | 9.7 | 57.3 |
| header field loop: traceField(i, trace.sourceX) for 1000 traces, warm | 100 | 259.2 | 271.5 | 301.3 | 301.6 |
| header column: traceFieldColumnInto(trace.sourceX) of 1000 traces, warm | 1000 | 22.5 | 32.9 | 65.6 | 78.7 |
| random single trace, cold | 300 | 256.3 | 8494.9 | 11267.4 | 17412.4 |
| shot gather (1000 traces), cold | 50 | 2972.8 | 3118.3 | 3189.4 | 3189.4 |
| receiver gather (1000 traces), cold | 20 | 71924.5 | 80563.8 | 645207.3 | 645207.3 |
| trace header listing, cold | 300 | 148.2 | 7703.9 | 9147.0 | 10871.8 |

#### Viewer latency on d21-8058-10m (10000000 traces of 100 samples)

Warm: file cached (first touch of a page in this map still faults it in). Cold: the file's pages dropped from the cache before the run (`dropCache`).

| operation | runs | p50 µs | p90 µs | p99 µs | max µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| random single trace, warm (readTracesInto) | 20000 | 0.3 | 0.4 | 0.7 | 7.9 |
| random single trace, warm (readTraces, new tensor) | 5000 | 0.3 | 0.4 | 0.7 | 6.5 |
| shot gather (1000 consecutive traces), warm | 500 | 33.9 | 41.0 | 46.1 | 60.4 |
| receiver gather (1000 traces 1000 apart), warm | 200 | 145.4 | 176.0 | 201.8 | 210.5 |
| window: samples 0..199 of 10000 traces, warm | 100 | 308.8 | 320.1 | 369.1 | 396.1 |
| 10000 whole traces, warm | 100 | 312.9 | 319.7 | 330.8 | 333.2 |
| trace header listing (traceHeaders), warm | 5000 | 1.1 | 1.4 | 1.5 | 8.8 |
| header field loop: traceField(i, ext1.receiverPointNumber) for 1000 traces, warm | 100 | 174.1 | 178.7 | 182.8 | 183.9 |
| header column: traceFieldColumnInto(ext1.receiverPointNumber) of 1000 traces, warm | 1000 | 18.0 | 18.6 | 24.5 | 49.6 |
| random single trace, cold | 300 | 140.2 | 8678.7 | 10290.4 | 10685.1 |
| shot gather (1000 traces), cold | 50 | 1254.8 | 1325.8 | 1447.1 | 1447.1 |
| receiver gather (1000 traces), cold | 20 | 21025.0 | 31909.9 | 32251.5 | 32251.5 |
| trace header listing, cold | 300 | 140.5 | 8692.1 | 10400.4 | 10549.8 |

#### Multi-thread scaling: N threads, disjoint trace ranges, one SeismicFile

Aggregate GB/s of file bytes; each thread decodes into its own tensor: 1 MB (256 traces of 1000 samples) up to 8 threads, 256 KB (64 traces) from 16, so two SMT siblings' outputs fit their shared L2. Warm: mapped, best of 3. Cold: pages dropped before each run.

| file | state | 1 | 2 | 4 | 8 | 16 | 32 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | warm | 21.59 | 37.35 | 43.14 | 50.87 | 49.74 | 46.83 |
| y-ieee | cold | 0.73 | 0.78 | 0.78 | 0.78 | 0.78 | 0.76 |
| y-ibm | warm | 6.50 | 12.76 | 24.78 | 45.50 | 48.05 | 44.64 |
| y-int16 | warm | 14.03 | 27.10 | 45.29 | 48.60 | 48.83 | 44.53 |
| d21-8015 | warm | 4.62 | 9.07 | 17.62 | 34.24 | 48.30 | 42.19 |
| d21-8015 | cold | 0.56 | 0.56 | 0.56 | 0.55 | 0.57 | 0.56 |
| d21-8058 | warm | 21.38 | 38.43 | 47.23 | 51.00 | 50.08 | 45.68 |

#### Prefetcher vs readTracesInto on the caller's thread

The consumer only takes chunks (`nextInto`, recycling its buffer). Depth: the ring depth used (capped at 4 MB of chunks). Seek: `seek` to a random trace, then wait for the first chunk; `quickFirst` makes that chunk a quarter of `chunkTraces`.

| file | mode | chunk x depth | workers | GB/s | seek -> first chunk p50 µs | p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | readTracesInto, caller thread | 1000 | - | 22.23 | - | - |
| y-ieee | prefetcher | 64 x 4 | 1 | 20.95 | 27.9 | 42.0 |
| y-ieee | prefetcher | 256 x 4 | 1 | 21.58 | 107.7 | 145.1 |
| y-ieee | prefetcher | 1024 x 2 | 1 | 13.13 | 573.8 | 645.5 |
| y-ieee | prefetcher | 256 x 4 | 1 | 21.65 | 98.8 | 129.1 |
| y-ieee | prefetcher | 256 x 4 | 2 | 35.85 | 130.4 | 201.4 |
| y-ieee | prefetcher | 256 x 4 | 4 | 42.55 | 135.4 | 220.6 |
| y-ieee | prefetcher, quickFirst | 256 x 4 | 1 | 21.61 | 65.4 | 90.8 |
| y-ieee | prefetcher, quickFirst | 1024 x 2 | 1 | 13.07 | 242.1 | 272.5 |
| y-ibm | readTracesInto, caller thread | 1000 | - | 6.50 | - | - |
| y-ibm | prefetcher | 64 x 4 | 1 | 6.31 | 87.6 | 99.7 |
| y-ibm | prefetcher | 256 x 4 | 1 | 6.44 | 335.1 | 389.5 |
| y-ibm | prefetcher | 1024 x 2 | 1 | 6.40 | 1360.4 | 1733.2 |
| y-ibm | prefetcher | 256 x 4 | 1 | 6.51 | 331.4 | 351.9 |
| y-ibm | prefetcher | 256 x 4 | 2 | 12.50 | 256.8 | 346.6 |
| y-ibm | prefetcher | 256 x 4 | 4 | 22.86 | 184.9 | 366.2 |
| y-ibm | prefetcher, quickFirst | 256 x 4 | 1 | 6.47 | 214.4 | 312.1 |
| y-ibm | prefetcher, quickFirst | 1024 x 2 | 1 | 6.39 | 831.8 | 870.0 |
| d21-8015 | readTracesInto, caller thread | 1000 | - | 4.65 | - | - |
| d21-8015 | prefetcher | 64 x 4 | 1 | 4.56 | 74.4 | 96.1 |
| d21-8015 | prefetcher | 256 x 4 | 1 | 4.62 | 284.0 | 331.3 |
| d21-8015 | prefetcher | 1024 x 2 | 1 | 4.58 | 1133.3 | 1169.1 |
| d21-8015 | prefetcher | 256 x 4 | 1 | 4.64 | 280.7 | 299.6 |
| d21-8015 | prefetcher | 256 x 4 | 2 | 9.08 | 234.2 | 295.5 |
| d21-8015 | prefetcher | 256 x 4 | 4 | 16.23 | 154.6 | 319.6 |
| d21-8015 | prefetcher, quickFirst | 256 x 4 | 1 | 4.61 | 176.8 | 201.0 |
| d21-8015 | prefetcher, quickFirst | 1024 x 2 | 1 | 4.54 | 700.5 | 741.7 |

#### Conversion, in-place header edits and geometry write-back

| operation | input | GB in | s | GB/s in | rate |
| --- | ---: | ---: | ---: | ---: | ---: |
| SEG-Y IBM -> SEG-Y IEEE | y-ibm | 1.06 | 5.31 | 0.20 | 0.20 GB/s out; CPU 0.49 s (2.1 GB/s of CPU) |
| SEG-Y -> SEG-Y (copy, same format) | y-ieee | 1.06 | 7.79 | 0.14 | 0.14 GB/s out; CPU 0.32 s (3.4 GB/s of CPU) |
| SEG-D 2.1 8058 -> SEG-Y | d21-8058 | 1.01 | 8.27 | 0.12 | 0.14 GB/s out; CPU 0.57 s (1.8 GB/s of CPU) |
| SEG-D 3.0 8058 -> SEG-Y | d30-8058 | 1.01 | 4.53 | 0.22 | 0.26 GB/s out; CPU 0.51 s (2.0 GB/s of CPU) |
| SEG-D 2.1 8015 -> SEG-Y | d21-8015 | 0.64 | 7.11 | 0.09 | 0.17 GB/s out; CPU 0.69 s (0.9 GB/s of CPU) |
| SEG-D 2.1 -> SEG-D 3.0 | d21-8058 | 1.01 | 6.92 | 0.15 | 0.15 GB/s out; CPU 1.06 s (1.0 GB/s of CPU) |
| SEG-2 -> SEG-Y | s2-ieee | 0.26 | 0.45 | 0.57 | 0.59 GB/s out; CPU 0.11 s (2.3 GB/s of CPU) |
| setTraceField trace.sourceX, one synced journal entry per edit | y-ieee-1m | 1.24 | 0.98 | - | 203. edits/s |
| setTraceField trace.sourceX, every trace in one batch | y-ieee-1m | - | 14.34 | - | 69711. edits/s |
| writeGeometry (journaled, batched) | y-ieee-1m | - | 18.92 | - | 52850. traces/s (1000000 changed) |
| setTraceField ext1.receiverPointNumber, one synced journal entry per edit | d21-8058-1m | 0.45 | 1.03 | - | 195. edits/s |
| setTraceField ext1.receiverPointNumber, every trace in one batch | d21-8058-1m | - | 6.99 | - | 143136. edits/s |
| writeGeometry (journaled, batched) | d21-8058-1m | - | 6.23 | - | 160479. traces/s (1000000 changed) |

### Release v3 build (warm)

Sections that depend on the build; the latency tables match the danger ones within noise
(SEG-Y 10 M: single trace 3.5 µs, shot gather 90 µs, receiver gather 261 µs p50; SEG-D 10 M:
0.3, 31.4 and 132 µs), as do the conversion and edit rates.

#### Sequential decode throughput (readTracesInto, 4 MB chunks, 1 thread)

GB/s of file bytes. Chunks of 4 MB of float32 samples (1000 traces of 1000 samples, 250 of the SEG-2 file's 4000). First pass: right after `openSeismic` (pages not touched yet fault in); mapped: best of 3 later passes. memcpy baseline: 22.5 GB/s, read baseline 39.4 GB/s.

| file | format | GB | cold GB/s | first pass GB/s | mapped GB/s | Msamples/s | % of memcpy | float64 GB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ibm | SEG-Y 1 (IBM float) | 1.06 | - | 5.60 | 6.40 | 1510. | 28. | 6.61 |
| y-ieee | SEG-Y 5 (IEEE float) | 1.06 | - | 17.63 | 25.17 | 5935. | 112. | 19.23 |
| y-ieee-le | SEG-Y 5 (IEEE float, LE) | 1.06 | - | 11.94 | 22.41 | 5285. | 99. | 18.60 |
| y-int32 | SEG-Y 2 (int32) | 1.06 | - | 16.12 | 23.91 | 5639. | 106. | 19.14 |
| y-int16 | SEG-Y 3 (int16) | 0.56 | - | 11.95 | 15.13 | 6757. | 67. | 8.07 |
| d21-8058 | SEG-D 2.1 8058 | 1.01 | - | 22.48 | 22.47 | 5544. | 100. | 17.97 |
| d21-8015 | SEG-D 2.1 8015 | 0.64 | - | 4.65 | 4.64 | 1817. | 21. | 3.88 |
| d21-8024 | SEG-D 2.1 8024 | 0.51 | - | 6.82 | 6.91 | 3367. | 31. | 3.65 |
| d21-8015-noise | SEG-D 2.1 8015 (random samples) | 0.64 | - | 4.67 | 4.67 | 1829. | 21. | 3.92 |
| d21-8024-noise | SEG-D 2.1 8024 (random samples) | 0.51 | - | 6.85 | 6.90 | 3364. | 31. | 3.67 |
| d30-8058 | SEG-D 3.0 8058 | 1.01 | - | 22.09 | 22.32 | 5509. | 99. | 18.05 |
| s2-ieee | SEG-2 4 (float32, LE) | 0.26 | - | 26.38 | 27.04 | 6704. | 120. | 19.87 |

#### Index build and keys (openSeismic)

Cold: the file's pages dropped first. Warm: best of 3 with the file cached. Open: the default `openSeismic` (fixed-length SEG-Y: sampled, O(1)); walk: `verify = vfFull` (every header). Memory: managed heap growth (`getOccupiedMem`) of the open file, per trace.

| file | traces | GB | cold open ms | cold first trace ms | cold walk ms | warm open ms | walk ms | ns/trace walk | keys ms | ns/trace keys | heap B/trace | keys heap B/trace | gathers ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | 250000 | 1.06 | - | - | - | 0.87 | 59.05 | 236. | 120.72 | 483. | 24.2 | 146.8 | 15.81 (250) |
| d21-8058 | 250000 | 1.01 | - | - | - | 125.85 | 125.86 | 503. | 132.40 | 530. | 24.9 | 146.8 | 15.13 (250) |
| y-ieee-1m | 1000000 | 1.24 | - | - | - | 2.50 | 173.36 | 173. | 424.49 | 424. | 24.1 | 146.8 | 62.55 (1000) |
| d21-8058-1m | 1000000 | 0.45 | - | - | - | 254.55 | 255.59 | 256. | 282.64 | 283. | 24.9 | 146.8 | 60.86 (1000) |
| y-ieee-10m | 10000000 | 12.40 | - | - | - | 21.90 | 1912.55 | 191. | 4802.40 | 480. | 24.3 | 144.0 | 653.70 (10000) |
| d21-8058-10m | 10000000 | 4.52 | - | - | - | 2522.67 | 2516.09 | 252. | 2986.93 | 299. | 25.4 | 144.0 | 616.43 (10000) |

#### Prefetcher vs readTracesInto on the caller's thread

The consumer only takes chunks (`nextInto`, recycling its buffer). Depth: the ring depth used (capped at 4 MB of chunks). Seek: `seek` to a random trace, then wait for the first chunk; `quickFirst` makes that chunk a quarter of `chunkTraces`.

| file | mode | chunk x depth | workers | GB/s | seek -> first chunk p50 µs | p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | readTracesInto, caller thread | 1000 | - | 25.15 | - | - |
| y-ieee | prefetcher | 64 x 4 | 1 | 23.37 | 24.1 | 39.1 |
| y-ieee | prefetcher | 256 x 4 | 1 | 24.68 | 87.3 | 129.3 |
| y-ieee | prefetcher | 1024 x 2 | 1 | 14.31 | 514.9 | 610.7 |
| y-ieee | prefetcher | 256 x 4 | 1 | 24.06 | 91.0 | 120.2 |
| y-ieee | prefetcher | 256 x 4 | 2 | 36.77 | 100.1 | 180.9 |
| y-ieee | prefetcher | 256 x 4 | 4 | 44.43 | 123.3 | 221.2 |
| y-ieee | prefetcher, quickFirst | 256 x 4 | 1 | 22.54 | 75.5 | 110.2 |
| y-ieee | prefetcher, quickFirst | 1024 x 2 | 1 | 14.31 | 285.0 | 355.2 |
| y-ibm | readTracesInto, caller thread | 1000 | - | 6.51 | - | - |
| y-ibm | prefetcher | 64 x 4 | 1 | 6.10 | 85.9 | 107.3 |
| y-ibm | prefetcher | 256 x 4 | 1 | 6.39 | 341.8 | 412.2 |
| y-ibm | prefetcher | 1024 x 2 | 1 | 6.38 | 1369.7 | 1513.5 |
| y-ibm | prefetcher | 256 x 4 | 1 | 6.47 | 333.9 | 359.7 |
| y-ibm | prefetcher | 256 x 4 | 2 | 12.53 | 271.7 | 354.9 |
| y-ibm | prefetcher | 256 x 4 | 4 | 22.71 | 183.9 | 379.9 |
| y-ibm | prefetcher, quickFirst | 256 x 4 | 1 | 6.43 | 212.9 | 243.0 |
| y-ibm | prefetcher, quickFirst | 1024 x 2 | 1 | 6.32 | 842.1 | 1155.6 |
| d21-8015 | readTracesInto, caller thread | 1000 | - | 4.64 | - | - |
| d21-8015 | prefetcher | 64 x 4 | 1 | 4.50 | 73.0 | 93.0 |
| d21-8015 | prefetcher | 256 x 4 | 1 | 4.61 | 283.8 | 324.8 |
| d21-8015 | prefetcher | 1024 x 2 | 1 | 4.63 | 1138.6 | 1272.7 |
| d21-8015 | prefetcher | 256 x 4 | 1 | 4.61 | 285.6 | 319.5 |
| d21-8015 | prefetcher | 256 x 4 | 2 | 9.10 | 225.9 | 301.8 |
| d21-8015 | prefetcher | 256 x 4 | 4 | 16.78 | 156.0 | 310.9 |
| d21-8015 | prefetcher, quickFirst | 256 x 4 | 1 | 4.58 | 178.0 | 199.2 |
| d21-8015 | prefetcher, quickFirst | 1024 x 2 | 1 | 4.53 | 713.0 | 794.8 |

## Phase 13 fixes, before and after (2026-11-08)

| Fix | Commit | What changed |
|---|---|---|
| R2-1, R2-7: unchecked decode loops | c198c50 | The SEG-Y, SEG-D and SEG-2 decoders check lengths once, then load through raw pointers (`endians.loadNum`, `copyMem` plus a byte swap). The `-d:release` builds had a bounds and overflow check on every byte. Samples already in host order are copied with `copyMem`. |
| R2-6: IBM float | c198c50 | fraction × `table[sign and exponent byte]` in float64: exact, no `ldexp` call per sample (`ldexp` was 78 % of the IBM profile). |
| R2-9: SEG-D exponent formats | c198c50 | 8022/8024/8042/8044 use power tables instead of `pow`; 8015 decodes whole groups of 4. |
| R2-10: `readTraces` | 2db702d | The result tensor is allocated uninitialized (every element is written). |
| R2-8: index memory | 2db702d | After the first trace the index reserves entries and keys for the rest of the file: 24.3 B and 144 B per trace instead of 35 B and 207 B (seq growth). Docs: `TraceKeys` is 144 B, not "about 100". |
| R2-2: batched edits | dda108d | A second field of a header with a pending batched edit flushed the batch (one fsync per trace). Pending writes are now laid over the map (indexed by page), for edits and for `currentTraceField`. |
| R2-3: `componentGroupIds` | c864106 | One table from group key to id; no per-group sequences. |
| Read buffers | 501a718 | `DiskSource`, `MemFileSource`, tape sources and `PushbackInput.readInto` zeroed every buffer before reading into it (a per-byte loop in `setLen`): half of `convertFile`'s CPU time on SEG-Y. |
| Conversion buffers | ec09d0a | `encodeExact` zeroed its output and scratch buffers per trace: 47 % of a SEG-D → SEG-Y conversion's CPU. |

### Sequential decode, 1 thread, warm (GB/s of file bytes)

| file | format | release before | release after | danger before | danger after |
|---|---|---:|---:|---:|---:|
| y-ibm | SEG-Y 1, IBM float | 0.54 | **5.47** | 0.63 | **6.53** |
| y-ieee | SEG-Y 5, IEEE big-endian | 2.06 | **11.13** | 8.83 | **22.47** |
| y-ieee-le | SEG-Y 5, IEEE little-endian | 2.25 | **17.01** | 8.77 | **17.27** |
| y-int32 | SEG-Y 2, int32 | 2.31 | **9.89** | 8.84 | **21.85** |
| y-int16 | SEG-Y 3, int16 | 1.51 | **14.12** | 10.75 | **15.49** |
| d21-8058 | SEG-D 2.1 8058 | 2.28 | **10.59** | 8.57 | **22.40** |
| d21-8015 | SEG-D 2.1 8015 | 0.76 | **2.26** | 1.82 | **2.55** |
| d21-8024 | SEG-D 2.1 8024 | 0.14 | **2.08** | 0.14 | **1.98** |
| d30-8058 | SEG-D 3.0 8058 | 2.28 | **10.64** | 8.61 | **23.30** |
| s2-ieee | SEG-2 4, float32 LE | 2.20 | **12.22** | 8.22 | **11.48** |

Memory baselines on the same machine: `memcpy` 22 GB/s (1 thread), a read-only sum of
uint64 22 to 34 GB/s. Little-endian IEEE (a `copyMem` per trace) reaches 74 % of `memcpy`;
big-endian IEEE about half, which is the byte swap without AVX2 in the release build (see
the remaining bottlenecks, 1). float64 output costs 10 to 20 % more (twice the bytes
written).

### Index memory (heap per trace)

| | before | after |
|---|---:|---:|
| entries (`keys = false`), 10 M traces | 35.2 B (352 MB) | **24.3 B (243 MB)** |
| entries + keys (`keys = true`), 10 M traces | 241.8 B (2.4 GB) | **168.3 B (1.68 GB)** |

### Edits and component groups (`-d:release`)

| | before | after |
|---|---:|---:|
| one batch, 2 fields on each of 2000 SEG-Y traces (R2-2) | 10 581 ms | **13 ms** |
| `componentGroupIds` over 10 M SEG-D traces, 10 M groups (R2-3) | 6.5 s | 4.0 s (no per-group objects; the table of 82-byte keys remains) |

### Conversion CPU (danger build, user CPU of `convertFile`, 1 GB inputs)

| conversion | before | after |
|---|---:|---:|
| SEG-Y → SEG-Y (y-ieee) | 0.54 s | 0.18 s |
| SEG-D 2.1 8058 → SEG-Y | 1.33 s | 0.77 s |

Wall time stays at the output disk's speed here (0.2 to 0.4 GB/s written, see below); on a
faster disk the conversion would now run at 1.3 to 5 GB/s of CPU.

## Full results after the Phase 13 fixes (danger build, full scale, 2026-11-08)

`PARSESEG_BENCH_SCALE=full nim bench`, 2026-11-08. Notes on reading them:
- warm decode of big-endian IEEE (22 GB/s) beats `memcpy` (18 to 22 GB/s): the decoder
  writes into a 4 MB tensor that stays in cache, while the `memcpy` baseline streams 1 GiB
  to DRAM. Host-order data is copied with `memcpy`, whose `rep movsb` path is slower on
  Zen 2 than the AVX2 swap loop (17 GB/s); in the SSE2 release build the order reverses
  (17 vs 11 GB/s), so the copy stays;
- cold numbers are this storage stack's (0.5 to 0.8 GB/s, latency in milliseconds),
  identical with 1 and 32 threads: reads through the map are issued one fault at a time;
- the prefetcher rows "seek -> first chunk" are the latency of one chunk's decode;
- the window row decodes from sample 0 (no sample-range API, see below).
### Baselines: memory and disk on this machine

| what | GB/s |
| --- | ---: |
| memcpy 1 GiB, 1 thread (bytes copied) | 18.19 |
| sum of uint64 over 1 GiB, 1 thread (bytes read) | 37.57 |
| memcpy 1 GiB, 4 threads | 23.94 |
| memcpy 1 GiB, 16 threads | 22.93 |
| memcpy 1 GiB, 32 threads | 21.51 |
| y-ieee, warm: mmap + sum (fresh map each run) | 17.17 |
| y-ieee, warm: read() 8 MiB blocks | 18.53 |
| y-ieee, cold: mmap + sum | 0.58 |
| y-ieee, cold: read() 8 MiB blocks | 0.68 |

#### Index build and keys (openSeismic)

Cold: the file's pages dropped first. Warm: best of 3 with the file cached. Memory: managed heap growth (`getOccupiedMem`) of the open file, per trace.

| file | traces | GB | cold open ms | cold first trace ms | warm open ms | ns/trace | keys ms | ns/trace keys | heap B/trace | keys heap B/trace | gathers ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | 250000 | 1.06 | 1437.04 | 1390.82 | 72.62 | 290. | 181.50 | 726. | 24.2 | 146.8 | 14.17 (250) |
| d21-8058 | 250000 | 1.01 | 1810.90 | 1775.02 | 79.84 | 319. | 86.88 | 348. | 24.9 | 146.8 | 13.34 (250) |
| y-ieee-1m | 1000000 | 1.24 | 967.70 | 930.02 | 228.20 | 228. | 664.84 | 665. | 24.1 | 146.8 | 55.32 (1000) |
| d21-8058-1m | 1000000 | 0.45 | 851.55 | 826.15 | 179.47 | 179. | 203.21 | 203. | 24.9 | 146.8 | 53.32 (1000) |
| y-ieee-10m | 10000000 | 12.40 | 19912.34 | 23003.88 | 2437.20 | 244. | 6815.07 | 682. | 24.3 | 144.0 | 559.08 (10000) |
| d21-8058-10m | 10000000 | 4.52 | 4018.10 | 3967.89 | 1972.78 | 197. | 2294.00 | 229. | 25.4 | 144.0 | 537.39 (10000) |
| y-ieee-big | 2000000 | 24.48 | 37378.24 | 35336.22 | - | - | - | - | - | - | - |

#### Sequential decode throughput (readTracesInto, 1000-trace chunks, 1 thread)

GB/s of file bytes. First pass: right after `openSeismic` (pages the index walk did not touch still fault in); mapped: best of 3 later passes. memcpy baseline: 18.2 GB/s, read baseline 37.6 GB/s.

| file | format | GB | cold GB/s | first pass GB/s | mapped GB/s | Msamples/s | % of memcpy | float64 GB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ibm | SEG-Y 1 (IBM float) | 1.06 | 0.72 | 6.20 | 6.53 | 1541. | 36. | 6.62 |
| y-ieee | SEG-Y 5 (IEEE float) | 1.06 | 0.77 | 22.45 | 22.47 | 5300. | 124. | 16.24 |
| y-ieee-le | SEG-Y 5 (IEEE float, LE) | 1.06 | 0.75 | 17.23 | 17.27 | 4074. | 95. | 16.49 |
| y-int32 | SEG-Y 2 (int32) | 1.06 | 0.55 | 22.43 | 21.85 | 5154. | 120. | 15.66 |
| y-int16 | SEG-Y 3 (int16) | 0.56 | 0.53 | 15.44 | 15.49 | 6914. | 85. | 8.30 |
| d21-8058 | SEG-D 2.1 8058 | 1.01 | 0.58 | 22.29 | 22.40 | 5527. | 123. | 15.87 |
| d21-8015 | SEG-D 2.1 8015 | 0.64 | 0.56 | 2.54 | 2.55 | 997. | 14. | 2.64 |
| d21-8024 | SEG-D 2.1 8024 | 0.51 | 0.56 | 1.97 | 1.98 | 963. | 11. | 2.01 |
| d30-8058 | SEG-D 3.0 8058 | 1.01 | 0.62 | 23.29 | 23.30 | 5750. | 128. | 18.12 |
| s2-ieee | SEG-2 4 (float32, LE) | 0.26 | 0.66 | 11.53 | 11.48 | 2847. | 63. | 7.21 |

y-ieee-big (24.48 GB, larger than the free page cache), cold, 1 thread: 0.70 GB/s.

#### Viewer latency on y-ieee-10m (10000000 traces of 250 samples)

Warm: file cached (first touch of a page in this map still faults it in). Cold: the file's pages dropped from the cache before the run (`dropCache`).

| operation | runs | p50 µs | p90 µs | p99 µs | max µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| random single trace, warm (readTracesInto) | 20000 | 0.3 | 0.4 | 0.7 | 8.8 |
| random single trace, warm (readTraces, new tensor) | 5000 | 0.3 | 0.4 | 0.7 | 17.9 |
| shot gather (1000 consecutive traces), warm | 500 | 64.6 | 68.8 | 78.3 | 80.0 |
| receiver gather (1000 traces 1000 apart), warm | 200 | 254.9 | 265.2 | 274.6 | 275.8 |
| window: samples 0..199 of 10000 traces, warm | 100 | 928.5 | 980.1 | 995.5 | 1019.8 |
| 10000 whole traces, warm | 100 | 914.1 | 950.9 | 1021.6 | 1041.9 |
| trace header listing (traceHeaders), warm | 5000 | 3.6 | 3.8 | 4.3 | 57.5 |
| header column: trace.sourceX of 1000 traces, warm | 100 | 270.3 | 276.6 | 285.5 | 285.7 |
| random single trace, cold | 300 | 363.9 | 9042.4 | 11807.2 | 14414.7 |
| shot gather (1000 traces), cold | 50 | 15043.9 | 16067.7 | 17410.0 | 17410.0 |
| receiver gather (1000 traces), cold | 20 | 222263.3 | 369464.1 | 441934.2 | 441934.2 |
| trace header listing, cold | 300 | 145.8 | 381.1 | 412.1 | 748.4 |

#### Viewer latency on d21-8058-10m (10000000 traces of 100 samples)

Warm: file cached (first touch of a page in this map still faults it in). Cold: the file's pages dropped from the cache before the run (`dropCache`).

| operation | runs | p50 µs | p90 µs | p99 µs | max µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| random single trace, warm (readTracesInto) | 20000 | 0.3 | 0.4 | 0.6 | 8.9 |
| random single trace, warm (readTraces, new tensor) | 5000 | 0.3 | 0.4 | 0.7 | 7.2 |
| shot gather (1000 consecutive traces), warm | 500 | 26.4 | 27.3 | 35.8 | 41.9 |
| receiver gather (1000 traces 1000 apart), warm | 200 | 129.7 | 157.9 | 174.3 | 181.8 |
| window: samples 0..199 of 10000 traces, warm | 100 | 262.3 | 273.6 | 275.7 | 326.7 |
| 10000 whole traces, warm | 100 | 264.5 | 275.5 | 284.7 | 289.6 |
| trace header listing (traceHeaders), warm | 5000 | 1.1 | 1.3 | 1.5 | 10.8 |
| header column: ext1.receiverPointNumber of 1000 traces, warm | 100 | 148.6 | 154.3 | 158.5 | 160.9 |
| random single trace, cold | 300 | 265.1 | 3133.3 | 7118.6 | 7522.2 |
| shot gather (1000 traces), cold | 50 | 1205.6 | 1413.8 | 6252.5 | 6252.5 |
| receiver gather (1000 traces), cold | 20 | 54681.9 | 249264.9 | 251303.0 | 251303.0 |
| trace header listing, cold | 300 | 254.7 | 280.4 | 324.7 | 513.5 |

#### Multi-thread scaling: N threads, disjoint trace ranges, one SeismicFile

Aggregate GB/s of file bytes; each thread decodes 256-trace chunks into its own tensor. Warm: mapped, best of 3. Cold: pages dropped before each run.

| file | state | 1 | 2 | 4 | 8 | 16 | 32 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | warm | 22.71 | 39.37 | 48.93 | 47.27 | 49.21 | 30.40 |
| y-ieee | cold | 0.77 | 0.78 | 0.77 | 0.74 | 0.77 | 0.76 |
| y-ibm | warm | 6.64 | 13.00 | 25.12 | 47.44 | 48.32 | 28.92 |
| y-int16 | warm | 15.53 | 29.51 | 47.68 | 47.84 | 48.40 | 37.89 |
| d21-8015 | warm | 2.55 | 5.01 | 9.81 | 19.13 | 37.01 | 36.28 |
| d21-8015 | cold | 0.56 | 0.56 | 0.56 | 0.56 | 0.56 | 0.56 |
| d21-8058 | warm | 22.63 | 38.94 | 50.83 | 48.69 | 49.40 | 32.71 |

#### Prefetcher (one worker thread) vs readTracesInto on the caller's thread

| file | mode | chunk x depth | GB/s | seek -> first chunk p50 µs | p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| y-ieee | readTracesInto, caller thread | 1000 | 23.12 | - | - |
| y-ieee | prefetcher, consumer only takes | 64 x 4 | 21.25 | 25.5 | 36.1 |
| y-ieee | prefetcher, consumer only takes | 256 x 4 | 21.33 | 98.0 | 107.2 |
| y-ieee | prefetcher, consumer only takes | 1024 x 4 | 13.23 | 558.9 | 603.6 |
| y-ieee | prefetcher, consumer only takes | 256 x 16 | 12.83 | 94.1 | 125.8 |
| y-ibm | readTracesInto, caller thread | 1000 | 6.64 | - | - |
| y-ibm | prefetcher, consumer only takes | 64 x 4 | 6.26 | 86.5 | 100.2 |
| y-ibm | prefetcher, consumer only takes | 256 x 4 | 6.44 | 331.9 | 350.5 |
| y-ibm | prefetcher, consumer only takes | 1024 x 4 | 6.35 | 1350.1 | 2354.6 |
| y-ibm | prefetcher, consumer only takes | 256 x 16 | 6.31 | 336.3 | 377.0 |
| d21-8015 | readTracesInto, caller thread | 1000 | 2.55 | - | - |
| d21-8015 | prefetcher, consumer only takes | 64 x 4 | 2.51 | 133.2 | 157.5 |
| d21-8015 | prefetcher, consumer only takes | 256 x 4 | 2.52 | 519.7 | 566.9 |
| d21-8015 | prefetcher, consumer only takes | 1024 x 4 | 2.53 | 2076.4 | 2286.7 |
| d21-8015 | prefetcher, consumer only takes | 256 x 16 | 2.50 | 514.8 | 527.4 |

#### Conversion, in-place header edits and geometry write-back

| operation | input | GB in | s | GB/s in | rate |
| --- | ---: | ---: | ---: | ---: | ---: |
| SEG-Y IBM -> SEG-Y IEEE | y-ibm | 1.06 | 3.65 | 0.29 | 0.29 GB/s out; CPU 0.69 s (1.5 GB/s of CPU) |
| SEG-Y -> SEG-Y (copy, same format) | y-ieee | 1.06 | 3.75 | 0.28 | 0.28 GB/s out; CPU 0.29 s (3.7 GB/s of CPU) |
| SEG-D 2.1 8058 -> SEG-Y | d21-8058 | 1.01 | 4.82 | 0.21 | 0.24 GB/s out; CPU 0.76 s (1.3 GB/s of CPU) |
| SEG-D 3.0 8058 -> SEG-Y | d30-8058 | 1.01 | 2.95 | 0.34 | 0.40 GB/s out; CPU 0.76 s (1.3 GB/s of CPU) |
| SEG-D 2.1 8015 -> SEG-Y | d21-8015 | 0.64 | 2.14 | 0.30 | 0.55 GB/s out; CPU 0.88 s (0.7 GB/s of CPU) |
| SEG-D 2.1 -> SEG-D 3.0 | d21-8058 | 1.01 | 2.92 | 0.35 | 0.35 GB/s out; CPU 1.07 s (0.9 GB/s of CPU) |
| SEG-2 -> SEG-Y | s2-ieee | 0.26 | 0.46 | 0.56 | 0.58 GB/s out; CPU 0.17 s (1.5 GB/s of CPU) |
| setTraceField trace.sourceX, one synced journal entry per edit | y-ieee-1m | 1.24 | 0.98 | - | 205. edits/s |
| setTraceField trace.sourceX, every trace in one batch | y-ieee-1m | - | 12.70 | - | 78756. edits/s |
| writeGeometry (journaled, batched) | y-ieee-1m | - | 15.90 | - | 62902. traces/s (1000000 changed) |
| setTraceField ext1.receiverPointNumber, one synced journal entry per edit | d21-8058-1m | 0.45 | 1.04 | - | 192. edits/s |
| setTraceField ext1.receiverPointNumber, every trace in one batch | d21-8058-1m | - | 5.74 | - | 174309. edits/s |
| writeGeometry (journaled, batched) | d21-8058-1m | - | 7.00 | - | 142759. traces/s (1000000 changed) |

## Phase 14 re-run (danger build, small scale, 2026-11-09)

`nim bench` at small scale after Phase 14 (C ABI and Python removed, API simplified, the
14.3 additions). The small files fit in the page cache and the CPU caches, so warm decode
GB/s are higher than at full scale and are not comparable with the 2026-11-08 tables. The
measures that do not depend on file size are the same:

| | 2026-11-08 (full scale) | 2026-11-09 (small scale) |
|---|---:|---:|
| index walk, SEG-Y, ns/trace (10 M / 500 k traces) | 244 | 218 |
| index walk with keys, SEG-Y, ns/trace | 682 | 648 |
| index heap, B/trace (without / with keys) | 24.3 / 144.0 | 24.1 / 146.8 |
| IBM float decode, 1 thread, GB/s | 5.5 | 5.6 |
| SEG-D 8015 decode, 1 thread, GB/s | 2.5 | 2.5 |
| random single trace, warm, p50 µs | 0.3 | 0.3 |

New rows from 14.3:
- **Sample window:** samples 0..199 of 10 000 traces of 250 samples take 722 µs, against
  825 µs for the whole traces. On the 100-sample SEG-D file the window covers whole traces
  and costs the same.
- **Header field loop:** `traceField(i, name)` for 1000 traces takes 263 µs on SEG-Y and
  151 µs on SEG-D (the suite's row was labelled "header column", but it timed this loop).
  `traceFieldColumnInto`, the column read, takes 5.6 to 8.9 ns per trace (Phase 15 audit
  item 14; the suite has a row for it since 15.3-14).

The 14.3 agents also measured, in their own scratch benchmarks:
- **Index cache:** opening 10 M SEG-Y traces from the cache takes 43 ms against 2.48 s
  walked, and 0.47 s against 7.0 s with keys.
- **Progress hook:** the index walk costs the same with a hook as without (2.48 s).
- **Prefetch recycling:** `nextInto` matches `next` in throughput and allocates nothing
  in steady state.


#### Baselines: memory and disk on this machine

| what | GB/s |
| --- | ---: |
| memcpy 1 GiB, 1 thread (bytes copied) | 22.38 |
| sum of uint64 over 1 GiB, 1 thread (bytes read) | 38.66 |
| memcpy 1 GiB, 4 threads | 23.23 |
| memcpy 1 GiB, 16 threads | 23.21 |
| memcpy 1 GiB, 32 threads | 21.48 |
| y-ieee, warm: mmap + sum (fresh map each run) | 19.85 |
| y-ieee, warm: read() 8 MiB blocks | 17.48 |
| y-ieee, cold: mmap + sum | 0.66 |
| y-ieee, cold: read() 8 MiB blocks | 0.65 |

#### Index build and keys (openSeismic)

Cold: the file's pages dropped first. Warm: best of 3 with the file cached. Memory: managed heap growth (`getOccupiedMem`) of the open file, per trace.

| file | traces | GB | cold open ms | cold first trace ms | warm open ms | ns/trace | keys ms | ns/trace keys | heap B/trace | keys heap B/trace | gathers ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | 12000 | 0.05 | 84.18 | 77.36 | 3.29 | 274. | 8.67 | 722. | 25.3 | 144.7 | 0.69 (12) |
| d21-8058 | 12000 | 0.05 | 73.12 | 72.55 | 4.70 | 392. | 4.73 | 394. | 25.6 | 144.7 | 0.64 (12) |
| y-ieee-1m | 50000 | 0.06 | 51.23 | 51.29 | 11.61 | 232. | 33.86 | 677. | 24.4 | 144.2 | 2.78 (50) |
| d21-8058-1m | 50000 | 0.02 | 14.57 | 13.82 | 8.40 | 168. | 9.74 | 195. | 25.2 | 144.2 | 2.64 (50) |
| y-ieee-10m | 500000 | 0.62 | 710.46 | 710.94 | 109.23 | 218. | 324.20 | 648. | 24.1 | 146.8 | 27.27 (500) |
| d21-8058-10m | 500000 | 0.23 | 383.66 | 365.76 | 78.09 | 156. | 91.07 | 182. | 24.9 | 146.8 | 26.55 (500) |

#### Sequential decode throughput (readTracesInto, 1000-trace chunks, 1 thread)

GB/s of file bytes. First pass: right after `openSeismic` (pages the index walk did not touch still fault in); mapped: best of 3 later passes. memcpy baseline: 22.4 GB/s, read baseline 38.7 GB/s.

| file | format | GB | cold GB/s | first pass GB/s | mapped GB/s | Msamples/s | % of memcpy | float64 GB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ibm | SEG-Y 1 (IBM float) | 0.05 | 0.66 | 5.56 | 5.60 | 1321. | 25. | 6.69 |
| y-ieee | SEG-Y 5 (IEEE float) | 0.05 | 0.74 | 23.08 | 25.61 | 6040. | 114. | 19.79 |
| y-ieee-le | SEG-Y 5 (IEEE float, LE) | 0.05 | 0.73 | 17.36 | 18.45 | 4352. | 82. | 20.28 |
| y-int32 | SEG-Y 2 (int32) | 0.05 | 0.54 | 23.27 | 25.37 | 5983. | 113. | 19.66 |
| y-int16 | SEG-Y 3 (int16) | 0.03 | 0.55 | 14.25 | 16.02 | 7152. | 72. | 8.36 |
| d21-8058 | SEG-D 2.1 8058 | 0.05 | 0.67 | 22.72 | 24.86 | 6136. | 111. | 19.40 |
| d21-8015 | SEG-D 2.1 8015 | 0.03 | 0.54 | 2.48 | 2.49 | 977. | 11. | 2.67 |
| d21-8024 | SEG-D 2.1 8024 | 0.02 | 0.53 | 1.95 | 1.94 | 943. | 9. | 1.98 |
| d30-8058 | SEG-D 3.0 8058 | 0.05 | 0.70 | 23.20 | 25.53 | 6300. | 114. | 20.05 |
| s2-ieee | SEG-2 4 (float32, LE) | 0.03 | 0.64 | 12.29 | 13.01 | 3226. | 58. | 8.25 |

#### Viewer latency on y-ieee-10m (500000 traces of 250 samples)

Warm: file cached (first touch of a page in this map still faults it in). Cold: the file's pages dropped from the cache before the run (`dropCache`).

| operation | runs | p50 µs | p90 µs | p99 µs | max µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| random single trace, warm (readTracesInto) | 20000 | 0.3 | 0.3 | 0.6 | 9.5 |
| random single trace, warm (readTraces, new tensor) | 5000 | 0.3 | 0.3 | 0.6 | 8.4 |
| shot gather (1000 consecutive traces), warm | 500 | 58.1 | 60.6 | 71.0 | 74.0 |
| receiver gather (500 traces 1000 apart), warm | 200 | 113.5 | 129.9 | 141.4 | 145.7 |
| window: samples 0..199 of 10000 traces, warm | 100 | 722.1 | 738.1 | 771.2 | 773.6 |
| 10000 whole traces, warm | 100 | 824.5 | 849.1 | 899.5 | 915.9 |
| trace header listing (traceHeaders), warm | 5000 | 3.5 | 3.8 | 4.4 | 22.4 |
| header column: trace.sourceX of 1000 traces, warm | 100 | 262.8 | 274.0 | 277.0 | 277.4 |
| random single trace, cold | 300 | 16.8 | 6306.9 | 8747.6 | 9089.3 |
| shot gather (1000 traces), cold | 50 | 7632.9 | 11847.7 | 15067.8 | 15067.8 |
| receiver gather (500 traces), cold | 20 | 1144.5 | 1684.5 | 895780.8 | 895780.8 |
| trace header listing, cold | 300 | 11.0 | 6787.1 | 8487.0 | 9247.0 |

#### Viewer latency on d21-8058-10m (500000 traces of 100 samples)

Warm: file cached (first touch of a page in this map still faults it in). Cold: the file's pages dropped from the cache before the run (`dropCache`).

| operation | runs | p50 µs | p90 µs | p99 µs | max µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| random single trace, warm (readTracesInto) | 20000 | 0.2 | 0.3 | 0.5 | 9.2 |
| random single trace, warm (readTraces, new tensor) | 5000 | 0.2 | 0.3 | 0.6 | 7.5 |
| shot gather (1000 consecutive traces), warm | 500 | 30.6 | 31.4 | 39.2 | 45.5 |
| receiver gather (500 traces 1000 apart), warm | 200 | 60.1 | 71.9 | 82.8 | 85.6 |
| window: samples 0..199 of 10000 traces, warm | 100 | 304.9 | 315.5 | 323.4 | 324.7 |
| 10000 whole traces, warm | 100 | 305.5 | 320.6 | 330.1 | 343.5 |
| trace header listing (traceHeaders), warm | 5000 | 0.9 | 1.0 | 1.3 | 7.3 |
| header column: ext1.receiverPointNumber of 1000 traces, warm | 100 | 150.9 | 158.7 | 164.1 | 164.9 |
| random single trace, cold | 300 | 4.1 | 6093.0 | 10097.6 | 11302.0 |
| shot gather (1000 traces), cold | 50 | 5730.4 | 9143.3 | 10892.9 | 10892.9 |
| receiver gather (500 traces), cold | 20 | 366.1 | 1556.6 | 450540.7 | 450540.7 |
| trace header listing, cold | 300 | 4.8 | 5970.9 | 8904.5 | 9553.2 |

#### Multi-thread scaling: N threads, disjoint trace ranges, one SeismicFile

Aggregate GB/s of file bytes; each thread decodes 256-trace chunks into its own tensor. Warm: mapped, best of 3. Cold: pages dropped before each run.

| file | state | 1 | 2 | 4 | 8 | 16 | 32 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| y-ieee | warm | 21.12 | 36.19 | 48.86 | 81.30 | 46.07 | 31.56 |
| y-ieee | cold | 0.72 | 0.74 | 0.73 | 0.71 | 0.68 | 0.67 |
| y-ibm | warm | 5.48 | 10.72 | 20.16 | 32.20 | 39.31 | 27.30 |
| y-int16 | warm | 14.48 | 26.57 | 45.25 | 51.59 | 35.27 | 22.56 |
| d21-8015 | warm | 2.39 | 4.57 | 8.86 | 16.33 | 23.33 | 18.65 |
| d21-8015 | cold | 0.49 | 0.51 | 0.52 | 0.54 | 0.54 | 0.55 |
| d21-8058 | warm | 23.29 | 36.18 | 60.75 | 61.07 | 43.18 | 28.18 |

#### Prefetcher (one worker thread) vs readTracesInto on the caller's thread

| file | mode | chunk x depth | GB/s | seek -> first chunk p50 µs | p99 µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| y-ieee | readTracesInto, caller thread | 1000 | 23.76 | - | - |
| y-ieee | prefetcher, consumer only takes | 64 x 4 | 20.12 | 24.8 | 34.9 |
| y-ieee | prefetcher, consumer only takes | 256 x 4 | 19.57 | 91.9 | 129.8 |
| y-ieee | prefetcher, consumer only takes | 1024 x 4 | 12.70 | 542.1 | 672.8 |
| y-ieee | prefetcher, consumer only takes | 256 x 16 | 12.98 | 92.1 | 119.2 |
| y-ibm | readTracesInto, caller thread | 1000 | 5.61 | - | - |
| y-ibm | prefetcher, consumer only takes | 64 x 4 | 5.27 | 99.2 | 130.9 |
| y-ibm | prefetcher, consumer only takes | 256 x 4 | 5.26 | 387.9 | 510.0 |
| y-ibm | prefetcher, consumer only takes | 1024 x 4 | 5.29 | 1573.3 | 1752.1 |
| y-ibm | prefetcher, consumer only takes | 256 x 16 | 5.12 | 387.5 | 401.2 |
| d21-8015 | readTracesInto, caller thread | 1000 | 2.47 | - | - |
| d21-8015 | prefetcher, consumer only takes | 64 x 4 | 2.33 | 136.0 | 173.1 |
| d21-8015 | prefetcher, consumer only takes | 256 x 4 | 2.38 | 532.6 | 556.2 |
| d21-8015 | prefetcher, consumer only takes | 1024 x 4 | 2.39 | 2117.9 | 2204.3 |
| d21-8015 | prefetcher, consumer only takes | 256 x 16 | 2.37 | 529.8 | 675.0 |

#### Conversion, in-place header edits and geometry write-back

| operation | input | GB in | s | GB/s in | rate |
| --- | ---: | ---: | ---: | ---: | ---: |
| SEG-Y IBM -> SEG-Y IEEE | y-ibm | 0.05 | 0.08 | 0.65 | 0.65 GB/s out; CPU 0.02 s (2.1 GB/s of CPU) |
| SEG-Y -> SEG-Y (copy, same format) | y-ieee | 0.05 | 0.06 | 0.87 | 0.87 GB/s out; CPU 0.01 s (7.9 GB/s of CPU) |
| SEG-D 2.1 8058 -> SEG-Y | d21-8058 | 0.05 | 0.09 | 0.55 | 0.64 GB/s out; CPU 0.02 s (2.1 GB/s of CPU) |
| SEG-D 3.0 8058 -> SEG-Y | d30-8058 | 0.05 | 0.09 | 0.56 | 0.65 GB/s out; CPU 0.03 s (1.5 GB/s of CPU) |
| SEG-D 2.1 8015 -> SEG-Y | d21-8015 | 0.03 | 0.10 | 0.30 | 0.56 GB/s out; CPU 0.05 s (0.7 GB/s of CPU) |
| SEG-D 2.1 -> SEG-D 3.0 | d21-8058 | 0.05 | 0.11 | 0.42 | 0.42 GB/s out; CPU 0.05 s (0.9 GB/s of CPU) |
| SEG-2 -> SEG-Y | s2-ieee | 0.03 | 0.04 | 0.72 | 0.75 GB/s out; CPU 0.02 s (1.5 GB/s of CPU) |
| setTraceField trace.sourceX, one synced journal entry per edit | y-ieee-1m | 0.06 | 0.93 | - | 214. edits/s |
| setTraceField trace.sourceX, every trace in one batch | y-ieee-1m | - | 0.19 | - | 260000. edits/s |
| writeGeometry (journaled, batched) | y-ieee-1m | - | 0.40 | - | 124302. traces/s (50000 changed) |
| setTraceField ext1.receiverPointNumber, one synced journal entry per edit | d21-8058-1m | 0.02 | 1.02 | - | 197. edits/s |
| setTraceField ext1.receiverPointNumber, every trace in one batch | d21-8058-1m | - | 0.16 | - | 322261. edits/s |
| writeGeometry (journaled, batched) | d21-8058-1m | - | 0.13 | - | 399243. traces/s (50000 changed) |

## Remaining bottlenecks, ranked, with proposed fixes (2026-11-08)

The list as it stood after Phase 13; each item says what Phase 15 did about it (numbers in
the [Phase 15](#phase-15-full-scale-re-run-2026-11-09) section).


1. **The `-d:release` build targets baseline x86-64 (SSE2).** The release build decodes
   big-endian IEEE at 11 GB/s; the same code with `-march=native` (AVX2 byte shuffles)
   reaches 22 GB/s (int32 10 vs 22, IBM float 5.5 vs 6.5). Proposal (owner decision, build
   policy): build the x86-64 library for `x86-64-v2` (SSSE3, every x86-64 CPU since about
   2009) or `-v3` (AVX2, since 2013/2015), or add a `target_clones("avx2","default")`
   variant of the decode loops (Linux/glibc only).
   *Phase 15 (15.3-5):* x86-64-v3 is the default for `nim cli` and the release bench;
   `nimPortable`/`zigPortable` build baseline x86-64.
2. **`openSeismic` walks every header before returning.** Time to first trace is the whole
   index: 2.4 s warm and 23 s cold for 10 M SEG-Y traces (the walk reads every page of a
   file with 1 KB traces), 35 s cold for the 24 GB file. Proposals: (a) SEG-Y with fixed-length traces (binary header
   3503, or all traces the same length): compute the entries arithmetically and check a
   sample of headers, so opening is O(1) and keys are computed on demand; (b) an
   incremental index (open returns after the first N traces, a worker extends it; `len`
   grows), which is an API change.
   *14.3e:* an index cache: `saveIndex(f, path)` once, then `openSeismic(path, opts =
   OpenOptions(cache: cachePath))` reads the index instead of walking (validated by size, mtime, the first and
   last 64 KiB, options and version; any mismatch walks the file). Danger build, warm,
   10 M SEG-Y traces (12.4 GB): open 2.48 s, from the cache 43 ms (a 240 MB cache, saved in
   95 ms); with `keys = true` 7.0 s, from the cache 0.47 s (1.68 GB). 1 M SEG-D 2.1 traces:
   0.21 s, cached 5 ms. A `progress` hook costs nothing measurable (2.48 s with and without
   one, 11 822 calls), and the walk without one is unchanged (2.58 s before, 2.48 s after;
   noise).
   *Phase 15:* (a) is in (15.3-10): fixed-length SEG-Y opens in 21 ms warm and 49 ms cold
   at 10 M traces; the walk itself is 30 % faster (15.3-3, 15.3-9). SEG-D still walks.
3. **Cold reads through the map are latency-bound.** Each page fault reads ahead 128 KB
   synchronously: a cold random trace costs one disk round trip (p50 0.3 ms, p99 12 ms on
   this storage), a cold receiver gather (1000 traces 1000 apart) 1000 sequential round
   trips (p50 222 ms, vs 0.25 ms warm), and N threads read cold no faster than one. Proposal:
   `madvise(MADV_WILLNEED)` on the byte spans of a range or selection before decoding it
   (only for spans above about 1 MB, or for selections, so warm single-trace reads keep
   their 0.3 µs), and in the prefetcher for the chunk after the one being decoded. The
   kernel then issues the reads in parallel.
   *Phase 15:* in (15.3-4, refined in 15.3-14): cold receiver gather p50 222 → 72 ms on
   y-ieee-10m. Cold sequential reads stay at the disk's speed: a range that continues a
   sequential read is left to the kernel's read-ahead.
4. **SEG-Y keys cost 450 ns per trace and 144 B per trace.** 10 M traces: 6.8 s and
   1.44 GB with `keys = true` (the plain index: 2.4 s, 243 MB). Proposals: compute keys
   lazily per gather or column (the R2-4 bulk `traceKeysInto` / `traceFieldColumn`); store
   them as float32 or as a columnar table of the fields a viewer sorts on.
   *14.3a:* `traceKeys(f, traces)` / `traceKeysInto` (on demand, without `keys = true`) and
   `traceFieldColumn` / `traceFieldColumnInto` are in; see the 14.3a Log line in `PLAN.md`.
   *Phase 15 (15.3-8, 15.3-9):* keys from the raw header bytes: about 220 ns per trace on
   top of the walk (10 M traces with keys: 6.8 → 3.9 s). Float32 keys were not adopted.
5. **No sample window.** A viewer showing samples 1000..1500 of 10 000 traces decodes the
   traces from sample 0 (the tensor width can only truncate the end). Proposal:
   `readTracesInto(f, traces, samples: Slice[int], dst)` decoding only the window (new API).
   *14.3b:* in, as proposed (`readTraces`/`readTracesInto` with `samples`, `newPrefetcher(firstSample)`);
   only the window's bytes are decoded, and the full-trace path is unchanged (7.7/9.4/5.2/15 GB/s
   for 8058/IEEE/IBM/int16, before and after).
6. **The prefetcher has one worker and delivers whole chunks.** Throughput is one core's
   (fine for every format now except 8015/8024 at about 2 GB/s); after a `seek` the first
   chunk arrives after a whole chunk's decode (chunk 1024: about 1 ms at 4 MB). Proposals:
   N workers over the ring; a smaller first chunk after a seek.
   *Phase 15 (15.3-11):* `workers` (4 workers: IBM 6.4 → 22.9 GB/s, 8015 4.6 → 16.2),
   `quickFirst` (seek → first chunk 574 → 242 µs at 1024 traces), a 4 MB ring cap.
7. **Release builds keep checks in the header and index code.** The index walk is about
   1.7 times slower in `-d:release` (450 ns per trace) than in danger (245 ns). Proposal:
   the same pattern as the decoders in `fieldlayout.decodeFields` (check the block
   length once, then unchecked loads).
   *Phase 15 (15.3-3):* done; the release v3 and danger walks now cost the same.
8. **Batched edits are bound by the journal.** 70 k to 130 k edits/s (one fsync per 4096
   edits plus a NIF line per edit, about 10 µs each); CPU is a small part. A binary or
   coalesced journal would be faster; fine for header patches as they are.
9. **Multi-thread scaling flattens at memory bandwidth**: about 50 GB/s aggregate from
    4 threads (IEEE, int16) or 8 threads (IBM), and drops at 32 threads (SMT plus the
    other load on this machine); 8015 scales to 37 GB/s at 16 threads. No lock is taken
    on the read path (R2 confirmed no refcount contention), so nothing in the library
    limits it.
    *Phase 15 (audit item 10):* the drop at 32 threads was each SMT pair writing two 1 MB
    tensors through one 512 KB L2; with 256 KB per thread 32 threads hold 47 GB/s
    (`processing.md` says so).
