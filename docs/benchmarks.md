# parseSEG benchmarks (task 13.2)

What a high-performance processing library and an interactive viewer need from parseSEG,
measured on synthetic files from 0.26 GB to 24 GB and up to 10 M traces: index build and
keys, time to first trace, sequential decode per format against memory bandwidth, viewer
latencies (p50/p99/max), multi-thread scaling, the prefetcher, conversion, in-place
edits and geometry write-back. The fixes this task made are measured before and after, in
both the `-d:danger -march=native` build (`nim nimRelease`) and the `-d:release` build
(`nim cli`).

> Measured on 2026-11-08, before the C ABI and Python module were removed (Phase 14); task
> 14.4 re-runs the suite.

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
5. **No sample window.** A viewer showing samples 1000..1500 of 10 000 traces decodes the
   traces from sample 0 (the tensor width can only truncate the end). Proposal:
   `readTracesInto(f, traces, samples: Slice[int], dst)` decoding only the window (new API).
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
