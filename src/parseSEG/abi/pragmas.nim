## The pragmas that put a core routine or type on the library's foreign
## boundary (task 12.5). They need only `std/macros`, so any core module can
## use them.
##
## - `{.segApi.}` on a public proc or func exports it to C and Python under
##   names derived from its Nim name (see `abi/segapi.nim`). Options:
##   `concurrent` (no handle lock, so calls on one handle may overlap),
##   `abiOnly` (a boundary routine with no core counterpart), `private` (a
##   Python name with a leading underscore), and `hide = name` (a trailing
##   defaulted parameter the boundary leaves at its default).
## - `{.segHandle.}` on an object type makes it cross as an opaque handle (a
##   counted reference), not as a struct.
## - `{.segField.}` / `{.segField(readonly = true).}` on a public field of a
##   handle type exports it as a property.
##
## Without `-d:segCapi` the pragmas change nothing. With it, `segApi` records
## the routine's resolved signature, and `segFinish` (in `abi/api.nim`)
## generates the wrappers, `include/parseseg.h` and the Python module.

import std/[macros, macrocache]

const segExports* = CacheSeq"parseSEG.segApi"
  ## One entry per `{.segApi.}` routine: `(signature, info, overloads)`.

template segHandle*(name = "") {.pragma.}
  ## The type crosses the boundary as a handle; `name` replaces the type's name
  ## (default: the Nim name without an `Obj` suffix).

template segField*(readonly = false) {.pragma.}
  ## The field crosses the boundary as a property of its handle.

macro segRecord(sig: typed, info: untyped, overloads: varargs[typed]): untyped =
  ## Stores a routine's typed signature, its `info` tuple (see `segApi`) and
  ## its overload set for `segFinish`.
  segExports.add newTree(nnkPar, sig, info,
    if overloads.len > 0: overloads[0] else: newEmptyNode())
  newEmptyNode()

macro segApi*(args: varargs[untyped]): untyped =
  ## Exports the routine; see the module documentation.
  let prc = args[^1]
  expectKind(prc, {nnkProcDef, nnkFuncDef})
  # The options are checked in every build, so a typo fails without `-d:segCapi` too.
  let flags = newNimNode(nnkBracket)
  let hidden = newNimNode(nnkBracket)
  for a in args[0 ..^ 2]:
    case a.kind
    of nnkIdent:
      if $a notin ["concurrent", "abiOnly", "private"]:
        error("segApi: unknown flag " & $a, a)
      flags.add newLit($a)
    of nnkExprEqExpr, nnkExprColonExpr:
      if $a[0] != "hide": error("segApi: unknown option " & $a[0], a)
      hidden.add newLit($a[1])
    else: error("segApi: unexpected argument", a)
  when not defined(segCapi):
    result = prc
  else:
    var doc = ""
    if prc.body.kind == nnkStmtList:
      for n in prc.body:
        if n.kind != nnkCommentStmt: break
        doc.add (if doc.len > 0: "\n" else: "") & n.strVal
    var name = prc.name
    if name.kind == nnkPostfix: name = name[1]
    if name.kind == nnkAccQuoted: name = name[0]
    let sig = newNimNode(nnkLambda)
    sig.add newEmptyNode(), newEmptyNode(), newEmptyNode(), copyNimTree(prc.params),
      newEmptyNode(), newEmptyNode(),
      newStmtList(newCall(ident"raiseAssert", newLit"signature only"))
    let info = newTree(nnkPar, newLit($name),
      newLit(if prc.kind == nnkFuncDef: "func" else: "proc"),
      newLit(prc.lineInfoObj.filename), newLit(doc), flags, hidden)
    result = newStmtList(prc, newCall(bindSym"segRecord", sig, info,
      nnkAccQuoted.newTree(ident($name))))
