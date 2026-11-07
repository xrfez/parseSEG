## The one export pragma of the library's foreign boundaries (task 8.8).
## `{.segExport.}` or `{.segExport: "name".}` marks a boundary proc; a define
## picks what it becomes:
##
## - `-d:segCapi`: `exportc: "name", dynlib, cdecl`, a C ABI symbol (`nim lib`);
##   the name is required.
## - `-d:segPython`: nimpy's `exportpy` (as `name` when given), a function or
##   method of the Python module (`nim pylib`).
## - neither: nothing, so plain Nim builds are unchanged.
##
## C-shaped procs live in `capi.nim` and Python-shaped ones in `pyapi.nim`;
## both wrap `abi/core.nim`.

import std/macros

when defined(segCapi) and defined(segPython):
  {.error: "define segCapi or segPython, not both".}

when defined(segPython):
  import nimpy
  export nimpy

macro segExport*(args: varargs[untyped]): untyped =
  ## `{.segExport.}` / `{.segExport: "name".}` on a proc.
  let prc = args[^1]
  let name = if args.len > 1: args[0] else: nil
  expectKind(prc, {nnkProcDef, nnkFuncDef})
  when defined(segCapi):
    if name == nil: error("segExport needs the C symbol name under -d:segCapi", prc)
    var pragmas = newNimNode(nnkPragma)
    # exportc must come first: the other pragmas apply to the exported symbol
    pragmas.add newColonExpr(ident"exportc", name)
    pragmas.add ident"dynlib"
    pragmas.add ident"cdecl"
    if prc.pragma.kind == nnkPragma:
      for p in prc.pragma: pragmas.add p
    prc.pragma = pragmas
    result = prc
  elif defined(segPython):
    result = if name == nil: newCall(bindSym"exportpy", prc)
             else: newCall(bindSym"exportpy", name, prc)
  else:
    result = prc
