## Regression tests for the Phase 13.3 review findings (task 13.4). One block
## per finding (R<reviewer>-<n>, as in PLAN.md). The C-boundary findings
## are in tests/c/abi_test.c and tests/c/guard_test.c.

import std/[assertions, os, strutils]
import parseSEG
import parseSEG/common/outputfile

const exampleDir = currentSourcePath().parentDir / ".." / "SEG Spec" / "exampleFiles"
let tmp = getTempDir() / "parseseg_treview13"
removeDir(tmp)
createDir(tmp)

proc has(log: DiagLog, text: string, sev: Severity): bool =
  for d in log:
    if d.severity == sev and text in d.msg: return true

proc put32(s: var string, at: int, v: uint32, order: ByteOrder) =
  for k in 0..3:
    let sh = if order == boLittle: 8 * k else: 8 * (3 - k)
    s[at + k] = char((v shr sh) and 0xFF)

proc tmpFiles(dir: string): seq[string] =
  for p in walkDir(dir):
    if p.path.endsWith(".tmp"): result.add p.path

# A small SEG-2 file (63.sgd's one trace) to damage.
let seg2 = tmp / "63.sg2"
doAssert not convertFile(exampleDir / "63.sgd", seg2, ConvertOptions(target: skSeg2)).isFatal

block r4_1_seg2_sample_counts_are_bounded_by_the_file:
  # A 4 KB file declaring 2^32 - 1 samples (undefined format), or 2^30
  # samples in a 4 GB Data Block, made reads and conversions allocate
  # 4-17 GB and abort. Now the count is bounded by the bytes left in the file.
  var f = openSeismic(seg2)
  let (p, order) = (int(f.seg2Trace(0).offset), f.index.seg2.order)
  f.close()
  let good = readFile(seg2)
  var undefined = good
  undefined.put32(p + 8, 0xFFFF_FFFF'u32, order) # numSamples
  undefined[p + 12] = char(9)                    # an undefined format code
  var huge = good
  huge.put32(p + 4, 0xFFFF_FFF0'u32, order) # dataSize
  huge.put32(p + 8, 0x3FFF_FFFC'u32, order) # numSamples
  for (name, bytes) in [("undefined.sg2", undefined), ("huge.sg2", huge)]:
    let path = tmp / name
    writeFile(path, bytes)
    var g = openSeismic(path)
    doAssert g.len == 1 and int64(g.maxSamples) <= int64(bytes.len), $g.maxSamples
    var log: DiagLog
    let t = g.readTraces(0..0, log)
    doAssert t.shape[0] == 1 and t.shape[1] <= bytes.len
    doAssert log.count(sevError) == 1, $log # undecodable or truncated: a diagnostic
    g.close()
    for target in [skSegy, skSegd, skSeg2]:
      let dst = tmp / (name & "." & $target)
      let clog = convertFile(path, dst, ConvertOptions(target: target))
      doAssert clog.count(sevError) + clog.count(sevFatal) > 0, $target & " " & $clog
  doAssert tmpFiles(tmp).len == 0

block r4_2_rev3_trailer_count_is_bounded:
  # GH#2 bytes 13-16 announced 2^31 trailer blocks: Rev 3 -> Rev 3 allocated
  # 32 x that (64 GB) before reading a trace.
  let rev3 = tmp / "63_r3.sgd"
  doAssert not convertSegdRevision(exampleDir / "63.sgd", rev3).isFatal
  var s = readFile(rev3)
  s.put32(44, 0x7FFF_FFFF'u32, boBig)
  writeFile(rev3, s)
  let log = convertSegdRevision(rev3, tmp / "63_r31.sgd",
    SegdConvertOptions(revision: SegdRevision(major: 3, minor: 1)))
  doAssert log.has("trailer blocks", sevError) or log.isFatal, $log
  doAssert log.has("more than the file holds", sevError), $log
  doAssert tmpFiles(tmp).len == 0

block r4_4_temporary_outputs_are_unique_and_exclusive:
  let dir = tmp / "tmpcase"
  createDir(dir)
  let src = dir / "line.sgy.tmp"
  copyFile(exampleDir / "Sweep0.sgy", src)
  let before = readFile(src)
  # The input used to be the output's fixed `<dst>.tmp`, and was destroyed.
  let log = convertFile(src, dir / "line.sgy")
  doAssert not log.isFatal, $log
  doAssert readFile(src) == before and fileExists(dir / "line.sgy")
  # Unique names; a planted symlink under the old fixed name is not followed.
  let victim = dir / "victim.txt"
  writeFile(victim, "keep")
  createSymlink(victim, dir / "out.sgy.tmp")
  doAssert not convertFile(exampleDir / "Sweep0.sgy", dir / "out.sgy").isFatal
  doAssert readFile(victim) == "keep" and fileExists(dir / "out.sgy")
  let a = createTempFor(dir / "x")
  let b = createTempFor(dir / "x")
  doAssert a != b and fileExists(a) and fileExists(b) and a.startsWith(dir / "x.")
  removeFile(a)
  removeFile(b)
  # The output is the input (through a symlink): refused, nothing changes.
  createSymlink(src, dir / "alias.sgy")
  let same = convertFile(src, dir / "alias.sgy")
  doAssert same.has("the output is the input file", sevFatal)
  doAssert readFile(src) == before
  # No directory for the temporary file: a fatal diagnostic, no exception.
  let missing = convertFile(src, dir / "no" / "such" / "out.sgy")
  doAssert missing.isFatal and missing.has("cannot create a temporary file", sevFatal), $missing
  # A failed conversion leaves no temporary file.
  writeFile(dir / "junk.sgy", "not seismic data")
  doAssert convertFile(dir / "junk.sgy", dir / "junk_out.sgy").isFatal
  for p in tmpFiles(dir): doAssert p in [src, dir / "out.sgy.tmp"], p # the planted link

echo "treview13: ok"
