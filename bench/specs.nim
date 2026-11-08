## The synthetic data set of the benchmark suite (task 13.2): every file
## `bench/gen` writes and `bench/suite` reads, at two scales.
##
## - `full`: the data set of `docs/benchmarks.md`, about 52 GB: 250 k trace
##   files per sample format, 1 M and 10 M trace files for the index, and a
##   24 GB file for streaming past the page cache.
## - `small`: the same files with 1/20 of the traces (at least 2000) and no
##   24 GB file, about 2.5 GB; a quick check that everything runs.

import std/[os, strutils]

type
  Scale* = enum
    scSmall = "small"
    scFull = "full"

  Container* = enum
    ## The standard and layout a file is written in.
    cSegy        ## SEG-Y Rev 1 (Rev 2 marker and order for little-endian).
    cSegd21      ## SEG-D Rev 2.1: GH1-GH3, one channel set, Ext1 per trace.
    cSegd30      ## SEG-D Rev 3.0: GH1-GH3, one channel set, Ext1 per trace.
    cSeg2        ## SEG-2, little-endian.

  Role* = enum
    ## What the suite uses the file for.
    rFormat      ## Sequential decode throughput, threads, C and Python.
    rIndex       ## Index build and keys; viewer latency (10 M).
    rBig         ## Streaming a file larger than the free page cache.

  Spec* = object
    name*: string
    container*: Container
    format*: int        ## SEG-Y code, SEG-D code or SEG-2 code.
    littleEndian*: bool ## SEG-Y only.
    traces*: int        ## At full scale.
    samples*: int
    perRecord*: int     ## SEG-D traces per record (shot).
    role*: Role

const benchFiles* = [
  Spec(name: "y-ibm", container: cSegy, format: 1, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "y-ieee", container: cSegy, format: 5, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "y-ieee-le", container: cSegy, format: 5, littleEndian: true,
    traces: 250_000, samples: 1000, perRecord: 1000, role: rFormat),
  Spec(name: "y-int32", container: cSegy, format: 2, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "y-int16", container: cSegy, format: 3, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "d21-8058", container: cSegd21, format: 8058, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "d21-8015", container: cSegd21, format: 8015, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "d21-8024", container: cSegd21, format: 8024, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "d30-8058", container: cSegd30, format: 8058, traces: 250_000, samples: 1000,
    perRecord: 1000, role: rFormat),
  Spec(name: "s2-ieee", container: cSeg2, format: 4, traces: 16_000, samples: 4000,
    perRecord: 16_000, role: rFormat),
  Spec(name: "y-ieee-1m", container: cSegy, format: 5, traces: 1_000_000, samples: 250,
    perRecord: 1000, role: rIndex),
  Spec(name: "y-ieee-10m", container: cSegy, format: 5, traces: 10_000_000, samples: 250,
    perRecord: 1000, role: rIndex),
  Spec(name: "d21-8058-1m", container: cSegd21, format: 8058, traces: 1_000_000,
    samples: 100, perRecord: 1000, role: rIndex),
  Spec(name: "d21-8058-10m", container: cSegd21, format: 8058, traces: 10_000_000,
    samples: 100, perRecord: 1000, role: rIndex),
  Spec(name: "y-ieee-big", container: cSegy, format: 5, traces: 2_000_000, samples: 3000,
    perRecord: 1000, role: rBig)]

func traces*(s: Spec, scale: Scale): int =
  ## The trace count at `scale` (0: the file is not part of it).
  case scale
  of scFull: s.traces
  of scSmall:
    if s.role == rBig: 0
    else: max(2000, s.traces div 20) div s.perRecord.min(2000) * s.perRecord.min(2000)

func scaledName*(s: Spec, scale: Scale): string =
  ## The name of the file at `scale`: small files carry their trace count, so
  ## the scales can share a directory.
  case scale
  of scFull: s.name
  of scSmall: s.name & "-s" & $s.traces(scale)

func extension*(s: Spec): string =
  case s.container
  of cSegy: ".sgy"
  of cSegd21, cSegd30: ".sgd"
  of cSeg2: ".sg2"

func path*(s: Spec, dir: string, scale: Scale): string =
  dir / (s.scaledName(scale) & s.extension)

func find*(name: string): Spec =
  ## The spec called `name`.
  for s in benchFiles:
    if s.name == name: return s
  raise newException(KeyError, "no benchmark file " & name)

proc dataDir*(): string =
  ## `PARSESEG_BENCH_DIR`, else `bench/data` (gitignored).
  result = getEnv("PARSESEG_BENCH_DIR")
  if result.len == 0: result = currentSourcePath().parentDir / "data"

proc scale*(): Scale =
  ## `PARSESEG_BENCH_SCALE` (`small`, the default, or `full`).
  case getEnv("PARSESEG_BENCH_SCALE", "small").toLowerAscii
  of "full": scFull
  else: scSmall
