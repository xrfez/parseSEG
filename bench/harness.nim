## Measurement helpers of the benchmark suite: timers, latency statistics,
## page-cache control (cold runs), memory counters and Markdown tables.

import std/[monotimes, times, algorithm, strutils, strformat, os, math, posix]

# ----------------------------------------------------------------- timing --

proc seconds*(t0: MonoTime): float {.inline.} =
  ## Seconds since `t0`.
  (getMonoTime() - t0).inNanoseconds.float / 1e9

template timed*(body: untyped): float =
  ## Seconds `body` takes.
  block:
    let t0 = getMonoTime()
    body
    seconds(t0)

template best*(runs: int, body: untyped): float =
  ## The fastest of `runs` runs of `body`, in seconds.
  block:
    var b = Inf
    for _ in 1..runs:
      b = min(b, timed(body))
    b

type
  Stats* = object
    ## Latencies in seconds.
    n*: int
    p50*, p90*, p99*, max*, mean*: float

func stats*(xs: openArray[float]): Stats =
  ## Percentiles (nearest rank) of `xs`.
  var s = @xs
  s.sort()
  result.n = s.len
  if s.len == 0: return
  func at(s: seq[float], q: float): float =
    s[clamp(int(ceil(q * float(s.len))) - 1, 0, s.len - 1)]
  result.p50 = s.at(0.50)
  result.p90 = s.at(0.90)
  result.p99 = s.at(0.99)
  result.max = s[^1]
  result.mean = sum(s) / float(s.len)

# ------------------------------------------------------------ page cache --

var POSIX_FADV_DONTNEED {.importc, header: "<fcntl.h>".}: cint
var POSIX_FADV_WILLNEED {.importc, header: "<fcntl.h>".}: cint
proc c_fadvise(fd: cint, offset, len: Off, advice: cint): cint {.
  importc: "posix_fadvise", header: "<fcntl.h>".}
var MADV_DONTNEED {.importc, header: "<sys/mman.h>".}: cint
proc c_madvise(adr: pointer, len: csize_t, advice: cint): cint {.
  importc: "madvise", header: "<sys/mman.h>".}
proc c_mincore(adr: pointer, len: csize_t, vec: ptr UncheckedArray[uint8]): cint {.
  importc: "mincore", header: "<sys/mman.h>".}

proc advise(path: string, advice: cint, offset = 0'i64, len = 0'i64) =
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: raiseOSError(osLastError(), path)
  discard c_fadvise(fd, Off(offset), Off(len), advice)
  discard posix.close(fd)

proc evict*(path: string, offset = 0'i64, len = 0'i64) =
  ## Drops the file's pages (all, or `len` bytes at `offset`) from the page
  ## cache, so the next read comes from the disk. Pages a process still maps
  ## stay: unmap first (`dropMapping`).
  advise(path, POSIX_FADV_DONTNEED, offset, len)

proc dropMapping*(mem: pointer, len: int) =
  ## Removes the pages of a read-only shared file mapping from this
  ## process's page tables (they fault back in from the page cache or the
  ## disk), so `evict` can drop them.
  if mem != nil and len > 0:
    # Not posix_madvise: glibc makes its POSIX_MADV_DONTNEED a no-op.
    discard c_madvise(mem, csize_t(len), MADV_DONTNEED)

proc warm*(path: string) =
  ## Reads the whole file once, so it is in the page cache.
  var f = open(path)
  defer: f.close()
  var buf = newSeq[byte](8 shl 20)
  while f.readBuffer(addr buf[0], buf.len) > 0: discard

proc residentFraction*(path: string): float =
  ## The part of the file that is in the page cache (mincore).
  let size = getFileSize(path)
  if size == 0: return 1
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: raiseOSError(osLastError(), path)
  defer: discard posix.close(fd)
  let p = mmap(nil, int(size), PROT_READ, MAP_SHARED, fd, 0)
  if p == MAP_FAILED: raiseOSError(osLastError(), path)
  defer: discard munmap(p, int(size))
  let pages = (int(size) + 4095) div 4096
  var vec = newSeq[uint8](pages)
  if c_mincore(p, csize_t(size), cast[ptr UncheckedArray[uint8]](addr vec[0])) != 0:
    raiseOSError(osLastError(), path)
  var n = 0
  for v in vec: n += int(v and 1)
  n / pages

proc userCpu*(): float =
  ## User CPU seconds this process has used (all threads).
  var ru: Rusage
  discard getrusage(RUSAGE_SELF, addr ru)
  float(ru.ru_utime.tv_sec) + float(ru.ru_utime.tv_usec) / 1e6

# ----------------------------------------------------------------- memory --

proc statusKb(key: string): int =
  for line in lines("/proc/self/status"):
    if line.startsWith(key & ":"):
      return parseInt(line[key.len + 1 .. ^1].strip.split[0])

proc rssAnon*(): int =
  ## Anonymous resident memory of the process in bytes (heap, not file maps).
  statusKb("RssAnon") * 1024

proc cpuModel*(): string =
  for line in lines("/proc/cpuinfo"):
    if line.startsWith("model name"): return line.split(':', 1)[1].strip

proc memTotalGb*(): float =
  for line in lines("/proc/meminfo"):
    if line.startsWith("MemTotal:"):
      return parseFloat(line.split[^2]) / 1024 / 1024

# ----------------------------------------------------------------- tables --

type
  Report* = object
    ## Markdown output: printed as it is made and kept for the results file.
    text*: string

proc line*(r: var Report, s = "") =
  echo s
  r.text.add s & "\n"

proc heading*(r: var Report, s: string) =
  r.line()
  r.line("### " & s)
  r.line()

proc table*(r: var Report, cols: openArray[string]) =
  r.line("| " & cols.join(" | ") & " |")
  var sep: seq[string]
  for i, c in cols: sep.add(if i == 0: "---" else: "---:")
  r.line("| " & sep.join(" | ") & " |")

proc row*(r: var Report, cells: openArray[string]) =
  r.line("| " & cells.join(" | ") & " |")

func ms*(secs: float): string = &"{secs * 1e3:.2f}"
func us*(secs: float): string = &"{secs * 1e6:.1f}"
func gbps*(bytes: float, secs: float): string = &"{bytes / secs / 1e9:.2f}"
func msps*(samples: float, secs: float): string = &"{samples / secs / 1e6:.0f}"
func gb*(bytes: float): string = &"{bytes / 1e9:.2f}"
