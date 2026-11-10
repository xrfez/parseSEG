## The usage guides' examples (task 13.1): every fenced code block of
## `docs/guide/*.md` tagged `nim` is a complete program, and this test runs
## each one, so the guides cannot go stale.
##
## Each block becomes one module (`doc_<page>_<n>.nim`), imported in page
## order by one generated main program: one compile for all of them. Their
## top-level code runs at start-up, in that order. The program runs in a
## fresh scratch directory that holds the demo files of `tools/demofiles`
## (`survey.sgy`, `shot.sgd`, `record.sgd`, `line.sg2`), written by the
## library's writers, so the examples use the plain names a reader would and
## write their outputs next to themselves. Blocks tagged otherwise (`sh`,
## `text`) are not run.
##
## It also checks the umbrella's allowlists against `docs/api.md`.

import std/[algorithm, assertions, os, osproc, sets, strutils]
import ./utils/srcnames
import ../tools/demofiles

const
  root = currentSourcePath().parentDir.parentDir
  guideDir = root / "docs" / "guide"

type
  Snippet = object
    page: string ## Page name without `.md`.
    line: int    ## 1-based line of the opening fence.
    code: string

proc fail(msg: string) {.noreturn.} =
  quit "tdocs: " & msg

proc mustRun(cmd: string, what: string, dir = "") =
  let (o, code) = execCmdEx(cmd, workingDir = dir)
  if code != 0:
    echo o
    fail what & " failed: " & cmd
  if o.strip.len > 0: echo o.strip

proc snippets(path: string): seq[Snippet] =
  ## The `nim` blocks of the Markdown file `path`.
  let page = path.splitFile.name
  var inBlock = false
  var cur: Snippet
  var keep = false
  let lines = readFile(path).splitLines
  for i, line in lines:
    let s = line.strip
    if not inBlock and s.startsWith("```"):
      inBlock = true
      keep = s[3 .. ^1].strip == "nim"
      cur = Snippet(page: page, line: i + 1)
    elif inBlock and s == "```":
      inBlock = false
      if keep: result.add cur
    elif inBlock and keep:
      cur.code.add line & "\n"
  if inBlock: fail path & ": a code block is not closed"

proc ident(s: string): string =
  for c in s: result.add(if c in IdentChars: c else: '_')

proc newRunDir(base: string): string =
  ## A fresh scratch directory holding the demo files.
  result = base / "run"
  removeDir(result)
  writeDemoFiles(result)

proc nimPaths(): string =
  ## The project's search paths, absolute, for a program outside the tree.
  result = " --noNimblePath --path:" & quoteShell(root / "src") &
    " --path:" & quoteShell(getCurrentCompilerExe().parentDir.parentDir / "dist" / "nimony" /
      "src" / "lib")
  for line in readFile(root / "nim.cfg").splitLines:
    let s = line.strip
    if s.startsWith("--path:"):
      result.add " --path:" & quoteShell(root / s["--path:".len .. ^1].strip(chars = {'"'}))

block umbrella_allowlists_match_api_md:
  # `src/parseSEG.nim` re-exports these modules by name. Every name a module
  # exports is either on its allowlist or one of its internals listed here,
  # every allowlisted name is documented in docs/api.md, and no internal
  # name is (except where a public overload shares it).
  let umbrella = readFile(srcDir / "parseSEG.nim")
  let api = toHashSet(words(readFile(root / "docs" / "api.md")))
  const sharedWithPublic = ["flush"] # memsource and the writers' `flush`
  const allowlisted = [
    ("traceindex", "model/traceindex.nim", @["MapPin", "pinMap", "openSeismicRw",
      "remapWritable", "requireOpen", "requireTrace", "requireKind", "unsafeMemory",
      "mappedSize", "flush", "segyIntervalOf", "refreshKeys", "refreshSegyInterval"]),
    ("headerfields", "model/headerfields.nim", newSeq[string]()),
    ("edit", "model/edit.nim", @["logVar", "writeBytes", "batching", "flushPending"]),
    ("tosegy", "convert/tosegy.nim", @["GeometryJoin", "convertSegdToSegyJoined"]),
    ("convert", "convert.nim", @["convertJoined"])]
  for (module, file, internal) in allowlisted:
    let listed = allowlist(umbrella, module)
    let exported = exportedNames(readFile(srcDir / "parseSEG" / file))
    doAssert listed.len > 0, module & ": no allowlist in src/parseSEG.nim"
    for n in listed:
      doAssert n in exported, module & "." & n & " is allowlisted but not exported"
      doAssert n in api, module & "." & n & " is exported by parseSEG but not in docs/api.md"
      doAssert n notin internal, module & "." & n & " is both allowlisted and internal"
    for n in exported:
      doAssert n in listed or n in internal, module & "." & n &
        " is neither on the umbrella's allowlist nor a listed internal"
    for n in internal:
      doAssert n in exported, module & "." & n & " is listed as internal but not exported"
      doAssert n notin api or n in sharedWithPublic,
        module & "." & n & " is internal but docs/api.md lists it"
  echo "tdocs: umbrella allowlists ok"

let tmp = getTempDir() / "parseseg_tdocs"
createDir(tmp)

var all: seq[Snippet]
var pages: seq[string]
for f in walkFiles(guideDir / "*.md"): pages.add f
pages.sort()
for f in pages: all.add snippets(f)
doAssert all.len > 0, "no examples found in " & guideDir

block nim_examples:
  let gen = tmp / "nim"
  removeDir(gen)
  createDir(gen)
  var main = "## Generated by tests/tdocs.nim: runs every Nim example of docs/guide.\n"
  var n = 0
  for s in all:
    inc n
    let name = "doc_" & ident(s.page) & "_" & $s.line
    writeFile(gen / name & ".nim", "# docs/guide/" & s.page & ".md, line " & $s.line & "\n" &
      s.code)
    main.add "import " & name & "\n"
  writeFile(gen / "docs_main.nim", main)
  let exe = gen / "docs_main".addFileExt(ExeExt)
  mustRun(getCurrentCompilerExe().quoteShell & " c --hints:off --warnings:off" & nimPaths() &
    " --nimcache:" & quoteShell(tmp / "nimcache") & " -o:" & quoteShell(exe) & " " &
    quoteShell(gen / "docs_main.nim"), "compiling the Nim examples")
  mustRun(quoteShell(exe), "running the Nim examples", newRunDir(tmp))
  echo "tdocs: ", n, " Nim examples ok"
