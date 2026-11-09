## Helpers shared by the test files (`import ./utils/testutils`). Kept out of
## `tests/t*.nim`, so `tester.nim` does not run it as a test.

import std/[os, strutils]
import parseSEG/common/diagnostics

const exampleDir* = currentSourcePath().parentDir.parentDir.parentDir / "SEG Spec" /
  "exampleFiles"
  ## The sample files (`SEG Spec/exampleFiles`).

proc scratchDir*(name: string): string =
  ## `getTempDir() / name`, emptied: a previous run's files are removed.
  result = getTempDir() / name
  removeDir(result)
  createDir(result)

proc toBytes*(s: string): seq[byte] =
  ## The bytes of `s`.
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc readBytes*(path: string): seq[byte] =
  ## The whole file at `path`.
  toBytes(readFile(path))

proc writeBytes*(path: string, b: openArray[byte]) =
  ## Writes `b` as the whole file at `path`.
  var s = newString(b.len)
  for i, c in b: s[i] = char(c)
  writeFile(path, s)

proc has*(log: DiagLog, text: string, sev: Severity): bool =
  ## Some diagnostic of severity `sev` has `text` in its message.
  for d in log:
    if d.severity == sev and text in d.msg: return true
