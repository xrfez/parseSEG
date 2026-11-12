## `SeismicWriter` (task 14.3d): read, scale, write "like" the input, read
## back. SEG-Y Rev 0, 1, 2.1 (big- and little-endian, fixed- and
## variable-length), SEG-D Rev 2.0, 2.1 and 3.0, SEG-2; new sample formats;
## changed sample counts; refusals; a writer dropped without `close`.

import std/[assertions, math, os, strutils]
import parseSEG
import ./utils/testutils

requireSamples()
let tmp = scratchDir("parseseg_twritefile")

proc convert(src, name: string, o: ConvertOptions): string =
  result = tmp / name
  let log = convertFile(src, result, o)
  doAssert not log.isFatal, name & ": " & $log

let
  bo = exampleDir / "BO_3D-Inglewood_rev21_v7.sgy"   # Rev 2.1, IBM, fixed-length
  sweep = exampleDir / "Sweep0.sgy"                  # Rev 0, little-endian, IEEE
  d63 = exampleDir / "63.sgd"                        # SEG-D Rev 2.0, 8058
  inova = exampleDir / "inova_rev30_5traces.sgd"     # SEG-D Rev 3.0, 5 traces
  boRev1 = convert(bo, "bo_rev1.sgy", ConvertOptions(revision: SegyRevision(major: 1)))
  inovaSegy = convert(inova, "inova.sgy", ConvertOptions()) # Ext1 + PSEGD001
  d63le = convert(d63, "d63le.sgy", ConvertOptions(byteOrder: boLittle))
  inovaRev21 = block:
    var o = ConvertOptions(target: skSegd)
    o.segd.revision = SegdRevision(major: 2, minor: 1)
    convert(inova, "inova_rev21.sgd", o)
  d63Rev3 = block:
    var o = ConvertOptions(target: skSegd)
    o.segd.revision = SegdRevision(major: 3, minor: 0)
    convert(d63, "d63_rev3.sgd", o)
  boSg2 = convert(bo, "bo.sg2", ConvertOptions(target: skSeg2))
  inovaSg2 = convert(inova, "inova.sg2", ConvertOptions(target: skSeg2))
  twoRecords = tmp / "two_records.sgd" # 63.sgd twice: two records
  twoInova = tmp / "two_inova.sgd"     # 2 Rev 3 records of 5 traces
writeFile(twoRecords, readFile(d63) & readFile(d63))
writeFile(twoInova, readFile(inovaRev21) & readFile(inovaRev21))

# A variable-length Rev 2.1 file declaring its trace count.
let boVar = tmp / "bo_var.sgy"
block:
  var b = readFile(bo)
  b[3502] = '\0' # fixedLengthTraces (3503-3504, big-endian) = 0
  b[3503] = '\0'
  b[3519] = char(200) # numTraces (3513-3520) = 200
  writeFile(boVar, b)

proc noTempFiles() =
  for p in walkDir(tmp):
    doAssert not p.path.endsWith(".tmp"), "left behind: " & p.path

proc rewrite(src, dst: string, scale: float64, segyFormat = stKeep, segdFormat = tfKeep,
    seg2Format = s2tKeep): DiagLog =
  # Every trace of `src`, scaled, written like `src`.
  var f = openSeismic(src)
  doAssert not f.log.isFatal, src
  var w = openSeismicWriter(dst, f, segyFormat, segdFormat, seg2Format)
  let x = scale * f.readTraces(0 ..< f.len, float64)
  for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
  doAssert w.len == f.len
  doAssert not fileExists(dst) or dst == src # written only on close
  result = w.close()
  doAssert fileExists(dst)
  doAssert not result.isFatal, $result

proc headerBytes(f: SeismicFile, i: int): seq[byte] =
  let e = f.traceEntry(i)
  f.copyBytes(e.offset, e.headerBytes)

proc checkSamples(a, b: string, scale, tol: float64) =
  # `b` holds `scale` times `a`'s samples, to `tol` relative to the largest.
  var f = openSeismic(a)
  var g = openSeismic(b)
  doAssert g.len == f.len and not g.log.isFatal, b & ": " & $g.log
  let want = scale * f.readTraces(0 ..< f.len, float64)
  let got = g.readTraces(0 ..< g.len, float64)
  let err = max(abs(got - want))
  doAssert err <= tol * max(max(abs(want)), 1.0), b & ": error " & $err

proc checkTraceHeaders(a, b: string) =
  var f = openSeismic(a)
  var g = openSeismic(b)
  for i in 0 ..< f.len:
    doAssert f.headerBytes(i) == g.headerBytes(i), b & " trace " & $i

proc fileHead(p: string): seq[byte] =
  # The headers before the first trace.
  var f = openSeismic(p)
  f.copyBytes(0, f.traceEntry(0).offset)

proc differing(a, b: seq[byte]): seq[int] =
  doAssert a.len == b.len
  for i in 0 ..< a.len:
    if a[i] != b[i]: result.add i

block identity_rewrite_is_byte_identical:
  # Scale 1 in the input's format: the output is the input.
  for src in [bo, sweep, boRev1, inovaSegy, d63le, boVar, d63, inova, inovaRev21, d63Rev3,
      twoRecords, twoInova, boSg2, inovaSg2]:
    let dst = tmp / ("same_" & src.extractFilename)
    discard rewrite(src, dst, 1.0)
    doAssert readFile(dst) == readFile(src), dst
  noTempFiles()

block scaled_segy:
  for (src, fmt, tol) in [(bo, stKeep, 1e-6), (bo, st5, 1e-6), (bo, st6, 1e-15),
      (sweep, stKeep, 1e-6), (boRev1, st2, 2e-5), (inovaSegy, stKeep, 1e-6),
      (inovaSegy, st6, 1e-15), (d63le, st9, 2e-5), (sweep, st3, 2e-5), (boVar, st1, 1e-6)]:
    let dst = tmp / ("x2_" & $fmt & "_" & src.extractFilename)
    # Integer formats: scaled to a peak of 30000 (int16 range) before rounding.
    let scale = if fmt in {st2, st3, st9}:
        (var f = openSeismic(src); 30000.0 / max(abs(f.readTraces(0 ..< f.len, float64))))
      else: 2.0
    discard rewrite(src, dst, scale, segyFormat = fmt)
    checkSamples(src, dst, scale, tol)
    checkTraceHeaders(src, dst)
    # The file headers differ only in the format code (binary bytes 3225-3226).
    let d = differing(fileHead(src), fileHead(dst))
    if fmt == stKeep: doAssert d.len == 0, dst
    else:
      for i in d: doAssert i in 3224..3225, dst & " byte " & $i
      var g = openSeismic(dst)
      doAssert g.summary.formatCode == ord(fmt)

block scaled_segd:
  for (src, fmt) in [(d63, tfKeep), (d63, tf8048), (inova, tfKeep), (inova, tf8080),
      (inovaRev21, tf8048), (d63Rev3, tf8080), (twoInova, tfKeep), (twoRecords, tf8058)]:
    let dst = tmp / ("x2_" & $fmt & "_" & src.extractFilename)
    discard rewrite(src, dst, 2.0, segdFormat = fmt)
    checkSamples(src, dst, 2.0, if fmt == tf8048: 1e-6 else: 0.0)
    checkTraceHeaders(src, dst)
    var f = openSeismic(src)
    var g = openSeismic(dst)
    doAssert g.recordCount == f.recordCount
    for r in 0 ..< f.recordCount:
      let a = f.index.segdRecords[r]
      let b = g.index.segdRecords[r]
      doAssert b.revision == a.revision and b.layout == a.layout
      if fmt != tfKeep: doAssert b.gh1.formatCode == parseInt($fmt)
      else: doAssert b.gh1.formatCode == a.gh1.formatCode
      # The record headers differ only in the format code (GH#1 bytes 3-4)
      # and, for Rev 3, GH#3's sizes (bytes 65-96).
      let hb = int(a.headerBytes)
      for i in differing(f.copyBytes(a.offset, hb), g.copyBytes(b.offset, hb)):
        doAssert fmt != tfKeep and (i in 2..3 or (a.isRev3 and i in 64..95)), dst & " " & $i
      if a.isRev3: doAssert b.trailerRev3 == a.trailerRev3
      else: doAssert b.trailer == a.trailer

block segd_8015_read_as_twos_complement_is_written_like_that:
  # The reader's `twosComplement8015` is the file's convention: written
  # "like" it, the samples read back the same (they were one LSB off on
  # every negative sample).
  var o = ConvertOptions(target: skSegd)
  o.segd.format = tf8015
  let src = convert(inova, "inova_8015.sgd", o)
  var f = openSeismic(src, opts = OpenOptions(twosComplement8015: true))
  let x = f.readTraces(0 ..< f.len, float64)
  let dst = tmp / "inova_8015_like.sgd"
  var w = openSeismicWriter(dst, like = f)
  for i in 0 ..< f.len: w.writeTrace(f, i, x, i)
  discard w.close()
  var g = openSeismic(dst, opts = OpenOptions(twosComplement8015: true))
  doAssert g.len == f.len and g.readTraces(0 ..< g.len, float64) == x
  doAssert readFile(dst) == readFile(src)
  g.close()
  f.close()

block scaled_seg2:
  for (src, fmt, tol) in [(boSg2, s2tKeep, 1e-6), (boSg2, s2t5, 1e-15), (inovaSg2, s2tKeep, 0.0),
      (inovaSg2, s2t4, 1e-6)]:
    let dst = tmp / ("x2_" & $fmt & "_" & src.extractFilename)
    discard rewrite(src, dst, 2.0, seg2Format = fmt)
    checkSamples(src, dst, 2.0, tol)
    var f = openSeismic(src)
    var g = openSeismic(dst)
    doAssert g.index.seg2.strings == f.index.seg2.strings
    for i in 0 ..< f.len:
      let (a, b) = (f.seg2Trace(i), g.seg2Trace(i))
      doAssert a.strings == b.strings
      doAssert b.formatCode == (if fmt == s2tKeep: a.formatCode else: uint8(ord(fmt)))

block changed_sample_counts_segy:
  for src in [bo, boVar, boRev1, inovaSegy, sweep]:
    var f = openSeismic(src)
    let n = f.maxSamples div 2
    let dst = tmp / ("half_" & src.extractFilename)
    var w = openSeismicWriter(dst, f)
    let x = f.readTraces(0 ..< f.len, float64)
    for i in 0 ..< f.len: w.writeTrace(f, i, x, i, count = n)
    discard w.close()
    var g = openSeismic(dst)
    doAssert g.len == f.len and g.maxSamples == n and not g.log.isFatal, $g.log
    doAssert g.readTraces(0 ..< g.len, float64) == x[_, 0 ..< n]
    doAssert g.fileField("binary.samplesPerTrace").intVal == n
    for i in 0 ..< g.len: doAssert g.traceField(i, "trace.numSamples").intVal == n
    if f.index.segy.binary.extSamplesPerTrace != 0:
      doAssert g.fileField("binary.extSamplesPerTrace").intVal == n
  block mixed_counts_write_the_largest_in_the_binary_header:
    # (The binary header kept the input's count, whatever was written.)
    var f = openSeismic(boVar)
    let n = f.maxSamples div 2
    let dst = tmp / "mixed.sgy"
    var w = openSeismicWriter(dst, f)
    let x = f.readTraces(0 ..< f.len)
    for i in 0 ..< f.len: w.writeTrace(f, i, x, i, count = n - i mod 2)
    discard w.close()
    var g = openSeismic(dst)
    doAssert g.fileField("binary.samplesPerTrace").intVal == n
    doAssert g.maxSamples == n
    doAssert g.traceField(1, "trace.numSamples").intVal == n - 1
    doAssert g.readTraces(1..1)[0, 0 ..< n - 1] == x[1, 0 ..< n - 1]
  block fixed_length_needs_one_count:
    var f = openSeismic(bo)
    var w = openSeismicWriter(tmp / "fixed.sgy", f)
    let x = f.readTraces(0..1)
    w.writeTrace(f, 0, x, 0, count = 100)
    doAssertRaises(ValueError): w.writeTrace(f, 1, x, 1, count = 99)
    w.writeTrace(f, 1, x, 1, count = 100)
    discard w.close()
    var g = openSeismic(tmp / "fixed.sgy")
    doAssert g.len == 2 and g.maxSamples == 100

block declared_trace_count_follows:
  var f = openSeismic(boVar)
  var w = openSeismicWriter(tmp / "subset.sgy", f)
  let x = f.readTraces(0 ..< 10)
  for i in countdown(9, 0): w.writeTrace(f, i, x, i) # any order, any subset
  discard w.close()
  var g = openSeismic(tmp / "subset.sgy")
  doAssert g.len == 10 and g.fileField("binary.numTraces").intVal == 10
  doAssert g.readTraces(0..0) == x[9..9, _]

block changed_sample_counts_seg2:
  var f = openSeismic(boSg2)
  var w = openSeismicWriter(tmp / "half.sg2", f)
  let x = f.readTraces(0 ..< f.len)
  for i in 0 ..< f.len: w.writeTrace(f, i, x, i, count = 10 + i)
  discard w.close()
  var g = openSeismic(tmp / "half.sg2")
  doAssert g.len == f.len and g.maxSamples == 10 + f.len - 1
  for i in 0 ..< g.len:
    doAssert g.traceEntry(i).numSamples == uint32(10 + i)
    doAssert g.seg2Trace(i).strings == f.seg2Trace(i).strings

block segd_record_rule:
  var f = openSeismic(twoInova)
  doAssert f.recordCount == 2 and f.len == 10
  let x = f.readTraces(0 ..< f.len)
  block skip_and_reorder_records:
    var w = openSeismicWriter(tmp / "rec10.sgd", f)
    for i in 5..9: w.writeTrace(f, i, x, i)
    for i in 0..4: w.writeTrace(f, i, x, i)
    discard w.close()
    var g = openSeismic(tmp / "rec10.sgd")
    doAssert g.recordCount == 2 and g.readTraces(0 ..< 10) == x[[5, 6, 7, 8, 9, 0, 1, 2, 3, 4], _]
    var w2 = openSeismicWriter(tmp / "rec1.sgd", f)
    for i in 5..9: w2.writeTrace(f, i, x, i)
    discard w2.close()
    doAssert openSeismic(tmp / "rec1.sgd").len == 5
  block refusals:
    var w = openSeismicWriter(tmp / "bad.sgd", f)
    doAssertRaises(ValueError): w.writeTrace(f, 1, x, 1)    # not the record's first trace
    w.writeTrace(f, 0, x, 0)
    doAssertRaises(ValueError): w.writeTrace(f, 2, x, 2)    # trace 1 is next
    doAssertRaises(ValueError): w.writeTrace(f, 0, x, 0)    # nor again
    doAssertRaises(ValueError): w.writeTrace(f, 5, x, 5)    # record 0 is incomplete
    doAssertRaises(ValueError): w.writeTrace(f, 1, x, 1, count = 10) # count changes
    w.writeTrace(f, 1, x, 1)                                # the writer is still usable
    doAssertRaises(ValueError): discard w.close()           # record 0 is incomplete
    doAssert not fileExists(tmp / "bad.sgd")
    doAssertRaises(ValueError): w.writeTrace(f, 2, x, 2)    # closed
    doAssertRaises(ValueError): discard w.close()
  noTempFiles()

block refusals:
  var sy = openSeismic(bo)
  var sd = openSeismic(d63)
  var s2 = openSeismic(boSg2)
  var r1 = openSeismic(boRev1)
  let x = sy.readTraces(0..0)
  doAssertRaises(ValueError): discard openSeismicWriter(tmp / "a.sgd", sd, segyFormat = st5)
  doAssertRaises(ValueError): discard openSeismicWriter(tmp / "a.sgy", sy, segdFormat = tf8058)
  doAssertRaises(ValueError): discard openSeismicWriter(tmp / "a.sgy", r1, segyFormat = st6)
  doAssertRaises(ValueError): discard openSeismicWriter(tmp / "a.sgd", sd, segdFormat = tf8080)
  block: # 8015 packs 4 samples in 10 bytes: shot.sgd's traces have 4001
    var odd = openSeismic(demoDir() / "shot.sgd")
    doAssert odd.maxSamples mod 4 != 0
    doAssertRaises(ValueError): discard openSeismicWriter(tmp / "a.sgd", odd, segdFormat = tf8015)
    var w8015 = openSeismicWriter(tmp / "a.sgd", sd, segdFormat = tf8015) # 1000 samples: fine
    doAssertRaises(ValueError): w8015.writeTrace(odd, 0, odd.readTraces(0..0), 0)
    odd.close()
  doAssertRaises(ValueError): discard openSeismicWriter(bo, sy)       # the input itself
  doAssertRaises(IOError): discard openSeismicWriter(tmp / "no" / "dir.sgy", sy)
  var w = openSeismicWriter(tmp / "r.sgy", sy, segyFormat = st3)
  doAssertRaises(ValueError): w.writeTrace(sd, 0, x, 0)               # another standard
  doAssertRaises(ValueError): w.writeTrace(s2, 0, x, 0)
  doAssertRaises(ValueError): w.writeTrace(sy, sy.len, x, 0)          # out of range
  doAssertRaises(ValueError): w.writeTrace(sy, 0, x, 1)               # no such row
  doAssertRaises(ValueError): w.writeTrace(sy, 0, x, 0, count = 5000) # row too short
  doAssertRaises(SegFormatError): # int16 overflow
    w.writeTrace(sy, 0, 1e9'f32 * ones[float32](1, sy.maxSamples), 0)
  doAssert w.len == 0
  w.writeTrace(sy, 0, x, 0)
  sy.close()
  doAssertRaises(ValueError): w.writeTrace(sy, 1, x, 0)               # closed file
  discard w.close()
  doAssert openSeismic(tmp / "r.sgy").len == 1
  block seg2_without_traces:
    var w2 = openSeismicWriter(tmp / "empty.sg2", s2)
    doAssertRaises(SegFormatError): discard w2.close()
    doAssert not fileExists(tmp / "empty.sg2")
  noTempFiles()

block dropped_writer_leaves_no_file:
  for src in [bo, d63, boSg2]:
    let dst = tmp / ("dropped_" & src.extractFilename)
    block:
      var f = openSeismic(src)
      var w = openSeismicWriter(dst, f)
      w.writeTrace(f, 0, f.readTraces(0..0), 0)
    doAssert not fileExists(dst)
  # An existing output is left as it was.
  let dst = tmp / "kept.sgy"
  writeFile(dst, "old")
  block:
    var f = openSeismic(bo)
    var w = openSeismicWriter(dst, f)
    w.writeTrace(f, 0, f.readTraces(0..0), 0)
  doAssert readFile(dst) == "old"
  noTempFiles()

block moved_writer:
  # The moved-from writer is zeroed: closed, with nothing to release; the
  # writer moved into finishes the output (or drops it).
  for drop in [false, true]:
    let dst = tmp / "moved.sgy"
    block:
      var f = openSeismic(bo)
      var w = openSeismicWriter(dst, f)
      w.writeTrace(f, 0, f.readTraces(0..0), 0)
      var w2 = move w
      doAssertRaises(ValueError): discard w.close()
      doAssert w2.len == 1
      if not drop: discard w2.close()
    doAssert fileExists(dst) == not drop
    removeFile(dst)
  noTempFiles()

removeDir(tmp)
