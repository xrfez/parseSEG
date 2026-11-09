## Helpers shared by the test files (`import ./utils/testutils`). Kept out of
## `tests/t*.nim`, so `tester.nim` does not run it as a test.

import std/[os, strutils]
import parseSEG/common/diagnostics
import ../../tools/demofiles

const
  exampleDir* = currentSourcePath().parentDir.parentDir.parentDir / "SEG Spec" /
    "exampleFiles"
    ## The sample files (`SEG Spec/exampleFiles`). They are not in the public
    ## repository (their redistribution rights are unknown): tests that need
    ## them skip when they are missing (`haveSamples`, `sampleBlock`).
  sampleNames* = ["63.sgd", "BO_3D-Inglewood_rev21_v7.sgy", "Sweep0.sgy",
    "inova_rev30_5traces.sgd"]
    ## The sample files the tests use (the 65 MB INOVA file is optional on top).

proc samplesPresent(): bool =
  for n in sampleNames:
    if not fileExists(exampleDir / n): return false
  true

let haveSamples* = samplesPresent()
  ## Every file of `sampleNames` is on disk.

proc skipped*(what: string) =
  ## Reports a test block skipped because the sample files are missing.
  echo "  skipped: sample files not present (", what, ")"

template sampleBlock*(name, body: untyped) =
  ## `block name: body`, run only when the sample files are present (else
  ## reported as skipped).
  block name:
    if haveSamples:
      body
    else:
      skipped(astToStr(name))

template requireSamples*() =
  ## Ends the test file here (exit code 0) when the sample files are missing.
  if not haveSamples:
    echo instantiationInfo().filename, ": skipped: sample files not present"
    quit 0

var demoDirPath: string

proc demoDir*(): string =
  ## A directory holding the generated demo files of `tools/demofiles`
  ## (`survey.sgy`, `shot.sgd`, `record.sgd`, `line.sg2`), written on the
  ## first call of the process.
  if demoDirPath.len == 0:
    demoDirPath = getTempDir() / "parseseg_demofiles"
    removeDir(demoDirPath)
    writeDemoFiles(demoDirPath)
  demoDirPath

proc sampleOr*(name: string): string =
  ## `exampleDir / name`; without the sample files, the demo file that stands
  ## in for it (`63.sgd`: `record.sgd`, `inova_rev30_5traces.sgd`:
  ## `shot.sgd`, `BO_3D-Inglewood_rev21_v7.sgy`: `survey.sgy`). Only for
  ## tests whose checks hold for any file of the kind (round trips,
  ## equivalences), not for values of one sample.
  if haveSamples: return exampleDir / name
  let stand = case name
    of "63.sgd": "record.sgd"
    of "inova_rev30_5traces.sgd": "shot.sgd"
    of "BO_3D-Inglewood_rev21_v7.sgy": "survey.sgy"
    else: ""
  doAssert stand.len > 0, name & " has no demo stand-in"
  demoDir() / stand

proc inputFiles*(): seq[string] =
  ## Every sample file (the optional 65 MB one included when present), or
  ## without them every demo file.
  let dir = if haveSamples: exampleDir else: demoDir()
  for n in walkFiles(dir / "*"): result.add n

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
