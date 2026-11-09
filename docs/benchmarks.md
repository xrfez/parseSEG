# parseSEG benchmarks (task 13.2)

What a high-performance processing library and an interactive viewer need from parseSEG,
measured on synthetic files from 0.26 GB to 24 GB and up to 10 M traces: index build and
keys, time to first trace, sequential decode per format against memory bandwidth, viewer
latencies (p50/p99/max), multi-thread scaling, the prefetcher, conversion, in-place
edits and geometry write-back. The fixes this task made are measured before and after, in
both the `-d:danger -march=native` build (`nim nimRelease`) and the `-d:release` build
(`nim cli`).

> The full-scale tables were measured on 2026-11-08, before the C ABI and Python module were
> removed. Phase 14 (the Nim-only library) was re-measured at small scale on 2026-11-09; see
> "Phase 14 re-run".

## Machine

- AMD Ryzen 9 3950X, 16 cores / 32 threads, 31 GB RAM, Debian 12 container, kernel 7.2.
- Storage: a btrfs file system with zstd compression on dm-crypt, on SATA SSDs. Cold
  reads therefore pass through decryption and decompression: sequential `read()` reached
  0.5 to 0.8 GB/s, and writes were throttled to 0.1 to 0.4 GB/s. Cold numbers measure this
  storage stack more than the library.
- Shared: other agents ran test suites at the same time (load average 4 to 20 on 32
  threads), so multi-thread numbers above 8 threads and all tail latencies are noisy. The
  before/after tables were run back to back with the same load pattern.
- Nim 2.4.0, gcc 12, default ORC memory management.

## Method

- `bench/gen.nim` writes the data set (`bench/specs.nim`): SEG-Y formats 1, 2, 3 and 5
  (big- and little-endian), SEG-D Rev 2.1 8058/8015/8024 and Rev 3.0 8058 (1000 traces per
  record), SEG-2 format 4, each 250 k traces of 1000 samples (0.5 to 1.1 GB); SEG-Y and
  SEG-D files of 1 M and 10 M traces (250 / 100 samples; 12.4 GB and 4.5 GB at 10 M); and
  a 24.5 GB SEG-Y file (2 M traces of 3000 samples) larger than the free page cache. SEG-D
  and SEG-2 go through the library's writers; headers carry a shot geometry so keys,
  gathers and write-back see real values. Full scale is 50 GB.
- `bench/suite.nim` runs the sections and prints Markdown (also saved as
  `results-<scale>.md` in the data directory). Times are wall clock, `std/monotimes`.
  Throughput tables count file bytes. Warm: the file is read once first; best of 3.
  Cold: the file's pages are unmapped from the process (`madvise(MADV_DONTNEED)`) and
  dropped from the page cache (`posix_fadvise(POSIX_FADV_DONTNEED)`); `drop_caches` is
  not writable in the container. Memory: growth of the Nim heap (`getOccupiedMem`).
- Profiles: `perf record` (installed in the container) on the hot loops; the fixes below
  came from those profiles and from the R2 performance review.

## How to rerun

```sh
nim bench                                   # small scale (about 2.5 GB), a few minutes
PARSESEG_BENCH_SCALE=full PARSESEG_BENCH_DIR=/big/disk nim bench   # 50 GB, about an hour
PARSESEG_BENCH_SECTIONS="decode latency" nim bench                 # some sections only
PARSESEG_BENCH_BUILD=release nim bench      # the suite in the shipped -d:release build
PARSESEG_BENCH_WARM_ONLY=1 nim bench        # skip the disk-bound cold runs
```

`nim bench` builds `bench/gen` and `bench/suite` (nimRelease flags by default), writes
the files that are missing, and runs the suite. The data directory defaults to
`bench/data` (gitignored). Sections: `baseline index decode latency threads prefetch
write`.

## Fixes made, before and after

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

## Full results after the fixes (danger build, full scale)

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
- **Header column:** `traceFieldColumn` over 1000 traces takes 263 µs on SEG-Y and 151 µs
  on SEG-D, about 0.15 to 0.26 µs per trace with the per-call checks included.

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

## Remaining bottlenecks, ranked, with proposed fixes

1. **The `-d:release` build targets baseline x86-64 (SSE2).** The release build decodes
   big-endian IEEE at 11 GB/s; the same code with `-march=native` (AVX2 byte shuffles)
   reaches 22 GB/s (int32 10 vs 22, IBM float 5.5 vs 6.5). Proposal (owner decision, build
   policy): build the x86-64 library for `x86-64-v2` (SSSE3, every x86-64 CPU since about
   2009) or `-v3` (AVX2, since 2013/2015), or add a `target_clones("avx2","default")`
   variant of the decode loops (Linux/glibc only).
2. **`openSeismic` walks every header before returning.** Time to first trace is the whole
   index: 2.4 s warm and 23 s cold for 10 M SEG-Y traces (the walk reads every page of a
   file with 1 KB traces), 35 s cold for the 24 GB file. Proposals: (a) SEG-Y with fixed-length traces (binary header
   3503, or all traces the same length): compute the entries arithmetically and check a
   sample of headers, so opening is O(1) and keys are computed on demand; (b) an
   incremental index (open returns after the first N traces, a worker extends it; `len`
   grows), which is an API change.
   *14.3e:* an index cache: `saveIndex(f, path)` once, then `openSeismic(path, cache =
   cachePath)` reads the index instead of walking (validated by size, mtime, the first and
   last 64 KiB, options and version; any mismatch walks the file). Danger build, warm,
   10 M SEG-Y traces (12.4 GB): open 2.48 s, from the cache 43 ms (a 240 MB cache, saved in
   95 ms); with `keys = true` 7.0 s, from the cache 0.47 s (1.68 GB). 1 M SEG-D 2.1 traces:
   0.21 s, cached 5 ms. A `progress` hook costs nothing measurable (2.48 s with and without
   one, 11 822 calls), and the walk without one is unchanged (2.58 s before, 2.48 s after;
   noise).
3. **Cold reads through the map are latency-bound.** Each page fault reads ahead 128 KB
   synchronously: a cold random trace costs one disk round trip (p50 0.3 ms, p99 12 ms on
   this storage), a cold receiver gather (1000 traces 1000 apart) 1000 sequential round
   trips (p50 222 ms, vs 0.25 ms warm), and N threads read cold no faster than one. Proposal:
   `madvise(MADV_WILLNEED)` on the byte spans of a range or selection before decoding it
   (only for spans above about 1 MB, or for selections, so warm single-trace reads keep
   their 0.3 µs), and in the prefetcher for the chunk after the one being decoded. The
   kernel then issues the reads in parallel.
4. **SEG-Y keys cost 450 ns per trace and 144 B per trace.** 10 M traces: 6.8 s and
   1.44 GB with `keys = true` (the plain index: 2.4 s, 243 MB). Proposals: compute keys
   lazily per gather or column (the R2-4 bulk `traceKeysInto` / `traceFieldColumn`); store
   them as float32 or as a columnar table of the fields a viewer sorts on.
   *14.3a:* `traceKeys(f, traces)` / `traceKeysInto` (on demand, without `keys = true`) and
   `traceFieldColumn` / `traceFieldColumnInto` are in; see the 14.3a Log line in `PLAN.md`.
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
7. **Release builds keep checks in the header and index code.** The index walk is about
   1.7 times slower in `-d:release` (450 ns per trace) than in danger (245 ns). Proposal:
   the same pattern as the decoders in `fieldlayout.decodeFields` (check the block
   length once, then unchecked loads).
8. **Batched edits are bound by the journal.** 70 k to 130 k edits/s (one fsync per 4096
   edits plus a NIF line per edit, about 10 µs each); CPU is a small part. A binary or
   coalesced journal would be faster; fine for header patches as they are.
9. **Multi-thread scaling flattens at memory bandwidth**: about 50 GB/s aggregate from
    4 threads (IEEE, int16) or 8 threads (IBM), and drops at 32 threads (SMT plus the
    other load on this machine); 8015 scales to 37 GB/s at 16 threads. No lock is taken
    on the read path (R2 confirmed no refcount contention), so nothing in the library
    limits it.
