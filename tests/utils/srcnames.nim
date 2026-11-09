## Reads the library's sources as text, for the boundary tests (`tumbrella`,
## `tdocs`): the names a module exports (`name*` declarations), the modules
## an `export` statement names, and the umbrella's allowlisted names. A
## line scanner, not a parser: it knows the declaration forms the library
## uses (top-level routines and consts, and `Name* = ...` in type and
## const sections), which is enough to keep the lists in step.

import std/[os, strutils]

const srcDir* = currentSourcePath().parentDir.parentDir.parentDir / "src"
  ## The library's `src` directory.

const routineKeywords = ["proc", "func", "template", "iterator", "macro", "method", "converter"]

func identAt(line: string, start: int, name: var string): int =
  ## The identifier (or backticked operator) at `start`, in `name`; returns
  ## the index after it, -1 if there is none.
  var i = start
  if i < line.len and line[i] == '`':
    let e = line.find('`', i + 1)
    if e < 0: return -1
    name = line[i + 1 ..< e]
    return e + 1
  while i < line.len and (line[i].isAlphaNumeric or line[i] == '_'): inc i
  if i == start: return -1
  name = line[start ..< i]
  i

func exportedNames*(source: string): seq[string] =
  ## The names `source` declares with `*`, once each, in order. Hooks
  ## (`=destroy`, ...) are left out: they follow their type.
  for raw in source.splitLines:
    let line = raw.strip(leading = false)
    var name = ""
    var after = -1
    if line.len == 0 or line.strip.startsWith("#"): discard
    elif line[0] != ' ':
      let word = line.split(' ', 1)[0]
      if word in routineKeywords or word in ["const", "type", "var", "let"]:
        after = identAt(line, word.len + 1, name)
    else:
      # `  Name* = ...` or `  Name*[T] = ...` inside a type or const section.
      let ind = line.len - line.strip(trailing = false).len
      after = identAt(line, ind, name)
      if after > 0 and after < line.len and line[after] == '*':
        let rest = line[after + 1 .. ^1].strip
        if not (rest.startsWith("=") or rest.startsWith("[")) or rest.startsWith("=="):
          after = -1
      else: after = -1
    if after > 0 and after < line.len and line[after] == '*' and name.len > 0 and
        not name.startsWith("=") and name notin result:
      result.add name

func exportStatements*(source: string): seq[string] =
  ## The text of each `export` statement of `source` (with its
  ## continuation lines), `when` branches included.
  let lines = source.splitLines
  var i = 0
  while i < lines.len:
    let s = lines[i].strip
    if s.startsWith("export ") or s == "export":
      var text = s
      while text.endsWith(",") and i + 1 < lines.len:
        inc i
        text.add " " & lines[i].strip
      result.add text
    inc i

func words*(text: string): seq[string] =
  ## The identifiers in `text` (anything but identifier characters splits
  ## them).
  for w in text.split(AllChars - IdentChars):
    if w.len > 0: result.add w

func allowlist*(umbrella, module: string): seq[string] =
  ## The names the umbrella exports from `module` one by one
  ## (`export module.name, module.name, ...`).
  for st in exportStatements(umbrella):
    let ws = st[len("export") .. ^1]
    for item in ws.split(','):
      let it = item.strip
      if it.startsWith(module & "."):
        var n = it[module.len + 1 .. ^1].strip
        if n.startsWith("`") and n.endsWith("`"): n = n[1 .. ^2]
        if n notin result: result.add n

proc privateModules*(): seq[string] =
  ## The module names under `src/parseSEG/private/`.
  for kind, path in walkDir(srcDir / "parseSEG" / "private"):
    if kind == pcFile and path.endsWith(".nim"): result.add path.splitFile.name

proc sourceFiles*(): seq[string] =
  ## Every `.nim` file under `src/`.
  for path in walkDirRec(srcDir):
    if path.endsWith(".nim"): result.add path
