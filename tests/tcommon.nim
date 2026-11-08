## Tests for the common primitives: endians, bcd, ibmfloat, ebcdic, output files.

import std/[assertions, os, strutils]
import parseSEG/common/[endians, bcd, ibmfloat, ebcdic, errors, diagnostics, outputfile]
from parseSEG/abi/pragmas import segApi

block endian_roundtrip:
  var b = newSeq[byte](16)
  putBeU16(b, 0, 0xBEEF'u16)
  doAssert b[0] == 0xBE and b[1] == 0xEF
  doAssert beU16(b, 0) == 0xBEEF'u16
  putBeI24(b, 2, -2)
  doAssert b[2] == 0xFF and b[3] == 0xFF and b[4] == 0xFE
  doAssert beI24(b, 2) == -2
  putBeI24(b, 2, 0x7FFFFF)
  doAssert beI24(b, 2) == 0x7FFFFF
  putBeI32(b, 5, -123456789)
  doAssert beI32(b, 5) == -123456789
  putBeI64(b, 8, -1234567890123'i64)
  doAssert beI64(b, 8) == -1234567890123'i64
  putBeF32(b, 0, 3.5'f32)
  doAssert b[0] == 0x40 and b[1] == 0x60 and b[2] == 0 and b[3] == 0
  doAssert beF32(b, 0) == 3.5'f32

block bcd_nibbles:
  var b = [0x12'u8, 0x34, 0x5F]
  doAssert nibble(b, 0) == 1 and nibble(b, 5) == 0xF
  doAssert bcd(b, 0, 4) == 1234
  doAssert bcd(b, 1, 4) == 2345
  putBcd(b, 1, 3, 987)
  doAssert b[0] == 0x19 and b[1] == 0x87
  doAssert not isAllF(b, 0, 2)
  putAllF(b, 0, 3)
  doAssert isAllF(b, 0, 3) and nibble(b, 3) == 7

block bcd_errors:
  let b = [0x1A'u8]
  doAssertRaises SegFormatError:
    discard bcd(b, 0, 2)
  var w = [0'u8, 0]
  doAssertRaises SegFormatError:
    putBcd(w, 0, 2, 100)
  doAssertRaises SegFormatError:
    putBcd(w, 0, 2, -1)

block ibm_known_values:
  # Reference values: 0x42640000 is 100.0, 0xC276A000 is -118.625 (IBM docs).
  doAssert ibmToFloat32(0x41100000'u32) == 1.0'f32
  doAssert ibmToFloat32(0x42640000'u32) == 100.0'f32
  doAssert ibmToFloat32(0xC276A000'u32) == -118.625'f32
  doAssert ibmToFloat32(0x40800000'u32) == 0.5'f32
  doAssert ibmToFloat32(0'u32) == 0'f32
  doAssert float32ToIbm(1.0'f32) == 0x41100000'u32
  doAssert float32ToIbm(-118.625'f32) == 0xC276A000'u32
  doAssert float32ToIbm(0.5'f32) == 0x40800000'u32
  doAssert float32ToIbm(0'f32) == 0'u32
  doAssert float32ToIbm(Inf.float32) == 0x7FFFFFFF'u32

block ibm_roundtrip:
  # IBM keeps 21-24 significant bits, so a round trip is within 2^-21 relative.
  for x in [1e-30'f32, 3.14159'f32, -2.5e10'f32, 7.0'f32, 1.17549435e-38'f32,
      3.4028235e38'f32, -1e-44'f32]:
    let y = ibmToFloat32(float32ToIbm(x))
    doAssert abs(float64(y) - float64(x)) <= abs(float64(x)) * 1.0e-6, $x & " -> " & $y
  # Values exactly representable in IBM must round-trip exactly.
  for x in [1.0'f32, 15.0'f32, 16.0'f32, -255.5'f32, 0.0625'f32]:
    doAssert ibmToFloat32(float32ToIbm(x)) == x

block ebcdic_roundtrip:
  doAssert decodeEbcdic([0xC3'u8, 0xF1, 0x40, 0xC3, 0xD3, 0xC9, 0xC5, 0xD5, 0xE3]) ==
    "C1 CLIENT"
  doAssert encodeEbcdic("C40 END TEXTUAL HEADER") == @[0xC3'u8, 0xF4, 0xF0, 0x40,
    0xC5, 0xD5, 0xC4, 0x40, 0xE3, 0xC5, 0xE7, 0xE3, 0xE4, 0xC1, 0xD3, 0x40,
    0xC8, 0xC5, 0xC1, 0xC4, 0xC5, 0xD9]
  for i in 0..255:
    doAssert latin1ToEbcdic[ebcdicToLatin1[i]] == uint8(i)

block seg_api_options_checked_in_every_build:
  # Without -d:segCapi too: a misspelt boundary option fails to compile.
  template exportWith(flag: untyped): untyped =
    proc probe(): int {.segApi(flag).} = 1
  doAssert compiles(exportWith(concurrent))
  doAssert not compiles(exportWith(concurent))

block output_files_through_tmp:
  # 12.3: one helper renames complete outputs into place for every writer.
  let dir = getTempDir() / "parseseg_tcommon"
  createDir(dir)
  let dst = dir / "out.bin"
  var tmp = createTempFor(dst)
  doAssert tmp.startsWith(dst & ".") and tmp.endsWith(".tmp") and getFileSize(tmp) == 0
  writeFile(tmp, "complete")
  var log: DiagLog
  finishOutput(tmp, dst, keep = true, log)
  doAssert log.len == 0 and readFile(dst) == "complete" and not fileExists(tmp)
  writeFile(tmp, "partial")
  finishOutput(tmp, dst, keep = false, log)
  doAssert log.len == 0 and readFile(dst) == "complete" and not fileExists(tmp)
  doAssert sameAsInput(dst, dst, log) and log.isFatal
  var log2: DiagLog
  doAssert not sameAsInput(dst, dir / "other.bin", log2) and log2.len == 0
  # A rename that fails is a fatal diagnostic, not an exception.
  writeFile(tmp, "x")
  finishOutput(tmp, dir / "missing" / "out.bin", keep = true, log2)
  doAssert log2.isFatal and "cannot move the output into place" in log2[0].msg
  removeFile(tmp)
