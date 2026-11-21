## One trace-header skeleton per SEG-D channel set.
##
## Seen to fail first, by breaking the change and restoring it:
## - strict_receiver_gather: Additional Source Info omitted on the shot at
##   record time while the descriptor still counted it (the strict walker:
##   trace header extensions != the descriptor's count)
## - mixed_orientation: the refusal removed (close wrote the file; expected
##   ValueError containing "give every trace of a channel set an orientation, or none")
## - uniform_option_sets: a filler block written on a uniform shot gather
##   (checksum of the bare file was not 2804808630)

import std/[assertions, math, os, strutils]

import parseSEG

import ./utils/testutils

var tmp: typeof(scratchDir("parseseg_tskeleton"))

const ShotTime = 1_709_273_228.0

proc fileSum(path: string): uint32 =
  for c in readFile(path):
    result = result * 16777619'u32 xor uint32(ord(c))

proc shot(record, channel: float64, receiver: bool): TraceKeys =
  result = initTraceKeys()
  result.record = record
  result.channel = channel
  result.intervalUs = 1000
  result.time = ShotTime
  result.srcLine = 1
  result.srcPoint = 99.5
  result.srcIndex = 1
  result.srcX = 500_000
  result.srcY = 6_000_000
  result.srcZ = 12.5
  if receiver:
    result.rcvLine = 100
    result.rcvPoint = 200 + channel
    result.rcvIndex = 1
    result.rcvX = 506_000 + 50 * channel
    result.rcvY = 6_008_000
    result.rcvZ = 10
    result.status = tsLive
    result.component = 2
    result.sensorType = 2
  else:
    result.status = tsAuxiliary

proc node(channel, srcPoint, dt: float64, source: bool): TraceKeys =
  result = initTraceKeys()
  result.record = 1
  result.channel = channel
  result.intervalUs = 1000
  result.time = ShotTime + dt
  result.rcvLine = 500
  result.rcvPoint = 12
  result.rcvIndex = 1
  result.rcvX = 1000
  result.rcvY = 2000
  result.rcvZ = 15
  result.status = tsLive
  result.component = 1
  result.sensorType = 1
  if source:
    result.srcLine = 10
    result.srcPoint = srcPoint
    result.srcIndex = 1
    result.srcX = 5000 + srcPoint
    result.srcY = 6000
    result.srcZ = 20

proc strictWalk(path: string, rows: seq[seq[float32]]) =
  # Strides each trace by the channel set descriptor's extension count, not
  # by the trace header's own count. A short trace desynchronizes the rest.
  let raw = readFile(path)
  var f = openSeismic(path)
  doAssert f.recordCount == 1
  let rec = f.index.segdRecords[0]
  var off = int(rec.headerBytes)
  let descs = rec.scanTypes[0].descriptorsRev3
  let fmt = rec.format.get
  var n = 0
  while off < raw.len:
    doAssert off + SegdTraceHeaderSize <= raw.len, "header past end at " & $off
    let hdr = decodeBlock[SegdTraceHeader](raw.toOpenArrayByte(off, off + SegdTraceHeaderSize - 1))
    let cs = channelSetNumber(hdr)
    doAssert cs >= 1 and cs <= descs.len
    let the = int(descs[cs - 1].traceHeaderExtensions)
    doAssert int(hdr.traceHeaderExtensions) == the
    let nbytes = dataBytes(fmt, int(descs[cs - 1].numSamples))
    let stride = SegdTraceHeaderSize + SegdBlockSize * the + nbytes
    doAssert off + stride <= raw.len
    var expect = newSeq[byte](nbytes)
    encodeSamples(fmt, rows[n], expect)
    let sampleAt = off + SegdTraceHeaderSize + SegdBlockSize * the
    for k in 0 ..< nbytes:
      doAssert uint8(raw[sampleAt + k]) == expect[k]
    off += stride
    inc n
  doAssert off == raw.len and n == rows.len
  f.close()

proc optsOf(name: string): SegdOutputOptions =
  result = SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 4, time: ShotTime)
  if name == "feet": result.units = cuFeet
  if name == "crs": result.crsText = "((OGP:P1/11 CRS))\nHC,1,6,1,local\n"
  if name == "fmt": result.format = sd8038
  if name == "units": result.units = cuUnknown

proc writeOpt(name: string, body: proc(w: var SeismicWriter)) =
  var w = openSeismicWriter(tmp / (name & ".sgd"), optsOf(name))
  body(w)
  discard w.close()

proc main*() =
  tmp = scratchDir("parseseg_tskeleton")

  block strict_receiver_gather:
    # Shots at T, T+60s, T+120s, plus a trace with no source, every trace
    # oriented. Before the skeleton the counts were 10, 11, 11, 6.
    let path = tmp / "rg.sgd"
    var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 2,
      time: ShotTime, receiverGather: true))
    let att = some(initTraceOrientation(0.1'f32, 0.2'f32, 0.3'f32, orientationType = 1,
      rotationApplied = true))
    let keys = [node(1, 30, 0, true), node(2, 40, 60, true), node(3, 50, 120, true),
      node(4, 0, 90, false)]
    var rows: seq[seq[float32]]
    for i, k in keys:
      let row = @[float32(i + 1), float32(10 + i)]
      w.writeTrace(k, row, orientation = att)
      rows.add row
    discard w.close()
    strictWalk(path, rows)
    var f = openSeismic(path, keys = true)
    doAssert f.len == 4
    let the = f.traceField(0, "trace.traceHeaderExtensions").intVal
    doAssert the == 11
    for i in 0 .. 3:
      doAssert f.traceField(i, "trace.traceHeaderExtensions").intVal == the
    doAssert f.traceKeys(0).srcPoint == 30 and f.traceKeys(2).srcPoint == 50
    doAssert f.traceKeys(3).srcLine.isNaN and f.traceKeys(3).srcX.isNaN
    doAssert f.traceKeys(1).time == ShotTime + 60
    doAssert f.traceOrientation(3).get.rotationZ == 0.3'f32
    # The shot at record time carries Additional Source Info with time 0.
    let raw = readFile(path)
    let rec = f.index.segdRecords[0]
    var off = int(rec.headerBytes)
    var sawZero, sawLater = false
    for i in 0 .. 3:
      let ext = off + SegdTraceHeaderSize
      for b in 0 ..< the:
        let at = ext + b * SegdBlockSize
        if raw[at + SegdBlockSize - 1] == char(0x20):
          var time = 0'i64
          for k in 0 .. 7: time = (time shl 8) or int64(uint8(raw[at + k]))
          if i == 0: sawZero = time == 0
          elif time != 0: sawLater = true
      off += SegdTraceHeaderSize + SegdBlockSize * int(the) + dataBytes(sd8058, 2)
    doAssert sawZero and sawLater
    f.close()

  block mixed_orientation:
    let path = tmp / "mix.sgd"
    var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 1000, numSamples: 1,
      time: ShotTime))
    let att = some(initTraceOrientation(0.1'f32, 0, 0, orientationType = 1, rotationApplied = true))
    w.writeTrace(shot(1, 1, true), @[1'f32], orientation = att)
    w.writeTrace(shot(1, 2, true), @[2'f32])
    try:
      discard w.close()
      doAssert false, "expected ValueError"
    except ValueError as e:
      doAssert e.msg.find("sctSeismic") >= 0, e.msg
      doAssert e.msg.find("trace channel 2") >= 0, e.msg
      doAssert e.msg.find("give every trace of a channel set an orientation, or none") >= 0, e.msg
    doAssert not fileExists(path)
    # A receiver gather, the first trace the one without an orientation.
    var r = openSeismicWriter(tmp / "mixrg.sgd", SegdOutputOptions(sampleIntervalUs: 1000,
      numSamples: 1, time: ShotTime, receiverGather: true))
    r.writeTrace(node(3, 10, 0, true), @[1'f32])
    r.writeTrace(node(4, 20, 60, true), @[2'f32], orientation = att)
    try:
      discard r.close()
      doAssert false, "expected ValueError"
    except ValueError as e:
      doAssert e.msg.find("trace channel 3") >= 0, e.msg
      doAssert e.msg.find("give every trace of a channel set an orientation, or none") >= 0, e.msg

  block uniform_option_sets:
    # Shot gathers that were already uniform, checksummed before the skeleton.
    const want = [
      ("bare", 972'i64, 2804808630'u32),
      ("norcv", 584'i64, 699064518'u32),
      ("nosrc", 680'i64, 101546848'u32),
      ("feet", 580'i64, 2791501907'u32),
      ("crs", 580'i64, 2280562458'u32),
      ("tworec", 1160'i64, 1181900870'u32),
      ("dead", 580'i64, 4010361477'u32),
      ("natime", 580'i64, 2701964292'u32),
      ("fmt", 580'i64, 4054038917'u32),
      ("aux", 584'i64, 754805421'u32),
      ("frac", 580'i64, 2481940808'u32),
      ("units", 324'i64, 1016372755'u32),
      ("three", 972'i64, 4237364105'u32)]
    writeOpt("bare"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
        w.writeTrace(shot(2, 2, true), @[5'f32, 6, 7, 8])
        w.writeTrace(shot(2, 3, false), @[9'f32, 10, 11, 12], channelType = sctTimeBreak)
    writeOpt("norcv"):
      proc (w: var SeismicWriter) =
        var a = shot(2, 1, true)
        a.rcvX = NaN; a.rcvY = NaN; a.rcvZ = NaN
        var b = shot(2, 2, true)
        b.rcvX = NaN; b.rcvY = NaN; b.rcvZ = NaN
        w.writeTrace(a, @[1'f32, 2, 3, 4])
        w.writeTrace(b, @[5'f32, 6, 7, 8])
    writeOpt("nosrc"):
      proc (w: var SeismicWriter) =
        var a = shot(2, 1, true)
        a.srcX = NaN; a.srcY = NaN; a.srcZ = NaN
        var b = shot(2, 2, true)
        b.srcX = NaN; b.srcY = NaN; b.srcZ = NaN
        w.writeTrace(a, @[1'f32, 2, 3, 4])
        w.writeTrace(b, @[5'f32, 6, 7, 8])
    writeOpt("feet"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
    writeOpt("crs"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
    writeOpt("tworec"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
        w.writeTrace(shot(5, 1, true), @[5'f32, 6, 7, 8])
    writeOpt("dead"):
      proc (w: var SeismicWriter) =
        var a = shot(2, 1, true)
        a.status = tsDead
        w.writeTrace(a, @[1'f32, 2, 3, 4])
    writeOpt("natime"):
      proc (w: var SeismicWriter) =
        var a = shot(2, 1, true)
        a.time = NaN
        w.writeTrace(a, @[1'f32, 2, 3, 4])
    writeOpt("fmt"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
    writeOpt("aux"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, false), @[1'f32, 2, 3, 4], channelType = sctTimeBreak)
        w.writeTrace(shot(2, 2, false), @[5'f32, 6, 7, 8], channelType = sctTimeBreak)
    writeOpt("frac"):
      proc (w: var SeismicWriter) =
        var a = shot(2, 1, true)
        a.rcvPoint = 200.25
        w.writeTrace(a, @[1'f32, 2, 3, 4])
    writeOpt("units"):
      proc (w: var SeismicWriter) =
        var a = shot(2, 1, true)
        a.srcX = NaN; a.srcY = NaN; a.srcZ = NaN
        a.rcvX = NaN; a.rcvY = NaN; a.rcvZ = NaN
        w.writeTrace(a, @[1'f32, 2, 3, 4])
    writeOpt("three"):
      proc (w: var SeismicWriter) =
        w.writeTrace(shot(2, 1, true), @[1'f32, 2, 3, 4])
        w.writeTrace(shot(2, 1, false), @[5'f32, 6, 7, 8], channelType = sctTimeBreak)
        w.writeTrace(shot(2, 1, false), @[9'f32, 10, 11, 12], channelType = sctUpHole)
    for (name, size, sum) in want:
      let path = tmp / (name & ".sgd")
      doAssert getFileSize(path) == size, name & " " & $getFileSize(path)
      doAssert fileSum(path) == sum, name & " " & $fileSum(path)

  echo "tskeleton ok"

when isMainModule: main()
