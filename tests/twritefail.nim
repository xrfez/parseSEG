## Output that cannot be completed: a full disk (a write or the last flush
## fails) or a destination that cannot be replaced. Nothing is installed,
## nothing is left behind, and the failure is reported: `IOError` from the
## writers, a fatal diagnostic from the converters.
##
## The full disk is a file size limit (RLIMIT_FSIZE, with SIGXFSZ ignored so
## that the write fails with EFBIG instead of ending the process): POSIX only.

import std/[assertions, os, strutils]
import parseSEG
import ./utils/testutils

let tmp = scratchDir("parseseg_twritefail")

proc noTempFiles() =
  for p in walkDir(tmp):
    doAssert not p.path.endsWith(".tmp"), "left behind: " & p.path

proc liveKeys(): TraceKeys =
  result = initTraceKeys()
  result.intervalUs = 2000
  result.status = tsLive

when defined(posix):
  import std/posix

  var RLIMIT_FSIZE {.importc, header: "<sys/resource.h>".}: cint

  proc limitFileSize(bytes: int) =
    ## Writes past `bytes` into any file fail with EFBIG; a negative `bytes`
    ## lifts the limit.
    var lim: RLimit
    doAssert getrlimit(RLIMIT_FSIZE, lim) == 0
    lim.rlim_cur = if bytes < 0: lim.rlim_max else: bytes
    doAssert setrlimit(RLIMIT_FSIZE, lim) == 0

  signal(SIGXFSZ, SIG_IGN)

  template failsUnder(limit: int, dst: string, body: untyped) =
    ## `body` writes `dst` through to its `close`: under a file size limit of
    ## `limit` bytes it must raise `IOError` and leave no file.
    var raised = false
    limitFileSize(limit)
    try:
      body
    except IOError:
      raised = true
    finally:
      limitFileSize(-1)
    doAssert raised, dst & ": no IOError under a limit of " & $limit & " bytes"
    doAssert not fileExists(dst), dst & " was installed, " & $getFileSize(dst) & " bytes"
    noTempFiles()

  proc writeLike(src, dst: string) =
    # Every trace of `src`, written like `src`.
    var f = openSeismic(src)
    var w = openSeismicWriter(dst, like = f)
    let x = f.readTraces(0 ..< f.len)
    for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
    discard w.close()

  block a_failed_last_flush_raises_and_installs_nothing:
    # The file is some hundred bytes short of the space it needs, so the
    # writes fit the buffers and only the last flush fails.
    block segy_from_keys:
      const traces = 10
      const ns = 1000
      let dst = tmp / "full.sgy"
      let x = newSeq[float32](ns)
      failsUnder(3600 + traces * (240 + 4 * ns) - 900, dst):
        var w = openSeismicWriter(dst,
          SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0)))
        for t in 0 ..< traces: w.writeTrace(liveKeys(), x)
        discard w.close()
    for name in ["survey.sgy", "shot.sgd", "line.sg2"]:
      let src = demoDir() / name
      let dst = tmp / ("like_" & name)
      writeLike(src, dst)
      let size = int(getFileSize(dst))
      doAssert size == getFileSize(src), name
      removeFile(dst)
      failsUnder(size - 900, dst): writeLike(src, dst)

  block a_failed_last_flush_is_fatal_for_convertFile:
    for (name, target) in [("survey.sgy", skSegy), ("record.sgd", skSegd), ("shot.sgd", skSegd),
        ("survey.sgy", skSeg2), ("line.sg2", skSegy)]:
      let src = demoDir() / name
      let dst = tmp / ("conv_" & name & "." & $target)
      let opts = ConvertOptions(target: target)
      doAssert not convertFile(src, dst, opts).isFatal, dst
      let size = int(getFileSize(dst))
      removeFile(dst)
      limitFileSize(size - 900)
      let log = convertFile(src, dst, opts)
      limitFileSize(-1)
      doAssert log.isFatal, dst & ": a file " & $(size - 900) & " bytes short is not fatal"
      doAssert not fileExists(dst), dst
      noTempFiles()
else:
  echo "twritefail: the disk-full blocks need POSIX (RLIMIT_FSIZE); skipped"
