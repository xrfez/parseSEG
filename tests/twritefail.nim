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

proc isEmptyDir(dir: string): bool =
  result = dirExists(dir)
  for _ in walkDir(dir): return false

block a_directory_as_destination_is_refused_before_any_work:
  let dir = tmp / "taken.sgy"
  createDir(dir)
  doAssertRaises(IOError): discard openSeismicWriter(dir, SegyOutputOptions())
  for name in ["survey.sgy", "shot.sgd", "line.sg2"]:
    var f = openSeismic(demoDir() / name)
    doAssertRaises(IOError): discard openSeismicWriter(dir, like = f)
    for target in [skSegy, skSegd, skSeg2]:
      if not (name == "survey.sgy" and target == skSegd): # SEG-Y to SEG-D: unsupported
        var calls = 0
        let log = convertFile(demoDir() / name, dir, ConvertOptions(target: target),
          proc (done, total: int64): bool =
            inc calls
            true)
        doAssert log.isFatal and log.has("is a directory", sevFatal), name & ": " & $log
        doAssert calls == 0, name & " to " & $target & ": the input was read first"
  doAssert isEmptyDir(dir)
  noTempFiles()

block a_failed_rename_leaves_no_temporary_file:
  # The destination turns into a directory while the file is written.
  let dst = tmp / "late.sgy"
  var w = openSeismicWriter(dst, SegyOutputOptions())
  w.writeTrace(liveKeys(), newSeq[float32](100))
  createDir(dst)
  let log = w.close()
  doAssert log.isFatal and log.has("cannot move the output into place", sevFatal), $log
  doAssert isEmptyDir(dst)
  noTempFiles()
  removeDir(dst)

block segd_writer_calls_out_of_order_are_value_errors:
  let src = openDiskSource(demoDir() / "record.sgd")
  var r = openSegd(src)
  doAssert r.nextRecord()
  var t: SegdTrace
  doAssert r.readTrace(t)
  let sink = openDiskSink(tmp / "order.sgd")
  var w = openSegdWriter(sink)
  doAssertRaises(ValueError): w.writeTrace(t)        # no record in progress
  doAssertRaises(ValueError): w.endRecord()
  doAssertRaises(ValueError): w.setRev3Trailer(@[])
  w.writeRecordHeaders(r.record)
  doAssertRaises(ValueError): w.writeRecordHeaders(r.record) # a record inside a record
  doAssertRaises(ValueError): w.setRev3Trailer(@[])   # a Rev 2 record
  doAssertRaises(ValueError): w.close()
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.close()
  src.close()
  doAssert readFile(tmp / "order.sgd") == readFile(demoDir() / "record.sgd")

block an_abandoned_seg2_writer_writes_no_pointers:
  var fdb = initSeg2File()
  fdb.traceCount = 2
  let path = tmp / "abandoned.sg2"
  var w = openSeg2Writer(path, fdb)
  let t = Seg2Trace(formatCode: 4)
  w.writeTrace(t, [1'f32, 2])
  w.abandon()
  w.abandon() # a closed writer: nothing to do
  w.close()
  doAssertRaises(ValueError): w.writeTrace(t, [1'f32])
  let b = readFile(path)
  doAssert b[6] == '\0' and b[7] == '\0' # the trace count was never written
  removeFile(path)

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

  block a_failed_write_discards_the_output:
    # `writeTrace` raises `IOError` when the disk fills up; a `close` after
    # that (say, from a `finally`) must not install the torn file.
    block from_keys:
      let dst = tmp / "torn.sgy"
      var w = openSeismicWriter(dst, SegyOutputOptions())
      let x = newSeq[float32](1000)
      var failedAt = -1
      limitFileSize(3 shl 19) # 1.5 MiB
      try:
        for t in 0 ..< 1000:
          if failedAt < 0:
            try: w.writeTrace(liveKeys(), x)
            except IOError: failedAt = t
      finally:
        limitFileSize(-1)
      doAssert failedAt > 0, "4 MB were written under a limit of 1.5 MiB"
      doAssertRaises(ValueError): w.writeTrace(liveKeys(), x)
      doAssertRaises(ValueError): discard w.close()
      doAssert not fileExists(dst)
      noTempFiles()
    block like_an_input:
      let dst = tmp / "torn_like.sgy"
      var f = openSeismic(demoDir() / "survey.sgy")
      let x = f.readTraces(0 ..< f.len)
      var w = openSeismicWriter(dst, like = f)
      var failed = false
      limitFileSize(3 shl 19)
      try:
        for pass in 0 ..< 3: # 1.65 MB each
          for i in 0 ..< f.len:
            if not failed:
              try: w.writeTrace(f, i, x, i)
              except IOError: failed = true
      finally:
        limitFileSize(-1)
      doAssert failed, "5 MB were written under a limit of 1.5 MiB"
      doAssertRaises(ValueError): discard w.close()
      doAssert not fileExists(dst)
      noTempFiles()
else:
  echo "twritefail: the disk-full blocks need POSIX (RLIMIT_FSIZE); skipped"
