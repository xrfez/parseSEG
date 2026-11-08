## The library's foreign boundary, generated from the core (tasks 12.2, 12.5).
##
## The core marks what crosses the boundary with the pragmas of
## `abi/pragmas.nim`: `{.segApi.}` on routines, `{.segHandle.}` on the types
## that cross as handles, `{.segField.}` on fields exported as properties.
## `segFinish` (called once, at the end of `abi/api.nim`, under
## `-d:segCapi`) generates from the recorded signatures:
##
## - one C export per routine (`exportc, dynlib, cdecl`, `raises: []`). It
##   converts the arguments, serializes calls on a handle (unless
##   `concurrent`), maps every exception to a `SegStatus` and
##   `seg_last_error`, and writes the results through trailing out-pointers;
## - `include/parseseg.h`, with the core's doc comments;
## - `python/parseseg/__init__.py`, a ctypes module.
##
## This module is the compile-time generator. What the generated wrappers call
## at run time (status codes, `segGuard`, the argument and result helpers) is
## in `abi/runtime.nim`, which it re-exports.
##
## Names are derived, never written twice:
##
## ==========================  ===================================  =========================
## Nim                         C                                    Python
## ==========================  ===================================  =========================
## `T {.segHandle.}`           `SegT` (opaque handle)               class `T`
## `p(t: T, ...)`              `seg_<snake T>_<snake p>`            method `t.<snake p>(...)`
## `func p(t: T): R`           as above                             property `t.<snake p>`
## `p(...)` (no handle first)  `seg_<snake p>`                      function `<snake p>(...)`
## `newT` / `initT` -> `T`     `seg_<snake T>_new`                  constructor `T(...)`
## `len`, `[]`                 `seg_<snake T>_len`, `_get`          `len(t)`, `t[i]`, `iter`
## `next`                      `seg_<snake T>_next`                 also the iterator protocol
## `f {.segField.}`            `seg_<snake T>_<f>`, `_set_<f>`      property `t.<snake f>`
## enum `E`, value `v`         `SEG_<SNAKE E>_<SNAKE $v>`           the string `$v`
## object `O`                  struct `SegO` (generated mirror)     dict, snake_case keys
## ==========================  ===================================  =========================
##
## A boundary type named `XObj` crosses as `X`. Each `Slice[int]` and
## `openArray[int]` overload pair of one name becomes the C functions `<name>_range`
## and `<name>`, and one Python function that takes a `range` or a sequence.
## Any other overload of an exported name is a compile-time error.
##
## Type mapping (parameter / result through a trailing out-pointer):
##
## =====================  ===================================  ==================================
## Nim                    Parameter                            Result
## =====================  ===================================  ==================================
## integers, floats       the same width (`int` → `int64_t`)   `T *out`
## `bool`                 `bool`                               `bool *out`
## enum                   `int32_t` (checked)                  `int32_t *out`
## `string`               `const char *` (NULL = default)      `char *out, int64_t out_cap,
##                                                              int64_t *out_len`
## handle                 `SegX *` (not NULL)                  `SegX **out` (owned)
## `Slice[int]`           `int64_t x_first, int64_t x_last`
## `openArray[int]`       `const int64_t *x, int64_t x_len`
## object                 `const SegX *` (NULL = `T()`)        `SegX *out`
## `seq[T]`                                                    `T *out, int64_t out_cap,
##                                                              int64_t *out_len`
## `FieldValue`           `const SegValue *`                   `SegValue *out`
## =====================  ===================================  ==================================
##
## Out-pointers may be NULL (the result is dropped). Text and sequences are
## copied into the caller's buffer: at most `out_cap` bytes or elements, with
## `*out_len` set to the full length, so the caller detects a buffer that is
## too small and calls again. Struct fields map like parameters. A `string`
## field is a `const char *` borrowed from the receiver, so it is allowed only
## in a `lent` result. A `proc` that returns a `DiagLog` fails when the log
## `isFatal`, and still hands the log out.

import std/[macros, macrocache, strutils, tables, math]
import ./[pragmas, runtime]

export pragmas, runtime

# ----------------------------------------------------------- generator state --

type
  AbiKind = enum
    ## How a Nim type crosses the boundary.
    akVoid, akInt, akFloat, akBool, akEnum, akString, akPointer, akHandle, akStruct, akSlice,
    akIds, akSeq, akBytes, akValue

  AbiType = object
    ## A Nim type and its C and ctypes forms.
    kind: AbiKind
    nim: string      ## the Nim type (repr), without var/lent/sink
    node: NimNode    ## the type node
    cNim: string     ## Nim type of the C parameter or mirror field (`int64`, `int16`, ...)
    cType: string    ## C type
    pyType: string   ## ctypes type
    lo, hi: string   ## integer bounds (Python checks; for ranges also Nim)
    isRange: bool
    isVar, isLent: bool
    handle: int      ## index into `Bindings.handles`
    mirror: int      ## index into `Bindings.mirrors`
    elem: seq[AbiType] ## element of a seq

  HandleInfo = object
    ## A type that crosses as an opaque handle.
    name, cName, short, doc: string
    refType: string  ## Nim type held by C: `Handle[T]` or the adapter's ref
    core: bool       ## `Handle[T]` around a core value
    node: NimNode    ## the type (core value type or adapter ref type)

  MirrorField = object
    nim, c: string
    t: AbiType

  MirrorInfo = object
    ## An object type that crosses as a C struct (its `M<Seg...>` mirror).
    nim, cName, mirror: string
    node: NimNode
    fields: seq[MirrorField]
    strings: bool    ## holds borrowed text (only `lent` results)
    input: bool      ## convertible from C (no text, no handles)
    usedAsInput: bool ## a parameter (or nested in one): gets `seg_init_*` and Python defaults
    done: bool

  PyClass = object
    name, short, doc: string ## Python name, C short name (`seg_<short>_...`), doc

  BindingText = object
    ## The generated header and Python sections.
    hEnums, hHandles, hStructs, hFns: string
    pyEnums, pyStructs, pyDecls, pyFns: string
    pyClasses: seq[PyClass]
    pyMethods: Table[string, string] ## Python class -> its methods
    enumsDone: seq[string]

  Bindings = object
    ## Everything `segFinish` builds: passed by `var` through the generator.
    text: BindingText
    handles: seq[HandleInfo]
    mirrors: seq[MirrorInfo]
    typeDocs: Table[string, string]  ## Nim type -> its doc
    fieldDocs: Table[string, string] ## "Type.field" -> its doc
    mirrorCode: string ## the mirror types, their `toC`/`fromC` and the release procs
    staticCode: string ## compile-time calls that add enums and defaults to `generated`

var generated {.compileTime.}: BindingText
  ## `segFinish`'s text, handed to the `static` code it emits: that code
  ## (`registerEnum`, `addPy`, `addPyStruct`, `writeBindings`) runs after the
  ## macro has returned, so it cannot take the macro's state as a parameter.

func snake(s: string): string =
  ## `srcLine` -> `src_line` (also strips backticks).
  result = ""
  for i, c in s:
    if c.isUpperAscii:
      if i > 0 and result.len > 0 and result[^1] != '_': result.add '_'
      result.add c.toLowerAscii
    elif c != '`': result.add c

func upperSnake(s: string): string =
  ## `badValue` -> `BAD_VALUE`, `SEG-Y` -> `SEG_Y`.
  result = (if s.toUpperAscii == s: s else: snake(s)).toUpperAscii
  for c in result.mitems:
    if c notin {'A'..'Z', '0'..'9'}: c = '_'

func cComment(doc, indent: string): string =
  if doc.len == 0: return ""
  result = indent & "/*"
  let lines = doc.strip.splitLines
  if lines.len == 1: return result & " " & lines[0] & " */\n"
  result.add "\n"
  for l in lines: result.add indent & " * " & l & "\n"
  result.add indent & " */\n"

func pyDoc(doc, indent: string): string =
  if doc.len == 0: return ""
  indent & "\"\"\"" & doc.strip.replace("\\", "\\\\").replace("\"\"\"", "\\\"\\\"\\\"").replace(
    "\n", "\n" & indent) & "\"\"\"\n"

proc registerEnum*[E: enum](t: typedesc[E]) {.compileTime.} =
  ## Adds enum `E`'s `#define`s and Python name tables (run at compile time).
  let name = $E
  if name in generated.enumsDone: return
  generated.enumsDone.add name
  generated.hEnums.add "\n/* " & name & " */\n"
  var fwd = "_E_" & name & " = {"
  var back = "_N_" & name & " = {"
  for e in E:
    generated.hEnums.add "#define SEG_" & upperSnake(name) & "_" & upperSnake($e) & " " &
      $ord(e) & "\n"
    fwd.add "\"" & $e & "\": " & $ord(e) & ", "
    back.add $ord(e) & ": \"" & $e & "\", "
  generated.pyEnums.add fwd & "}\n" & back & "}\n"

proc pyLit*(v: SomeInteger): string {.compileTime.} = $v
proc pyLit*(v: bool): string {.compileTime.} = (if v: "True" else: "False")
proc pyLit*(v: SomeFloat): string {.compileTime.} =
  if v.isNaN: "float(\"nan\")"
  elif v == Inf: "float(\"inf\")"
  elif v == -Inf: "float(\"-inf\")"
  else: $v
proc pyLit*(v: string): string {.compileTime.} =
  "\"" & v.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
proc pyLit*[E: enum](v: E): string {.compileTime.} = "\"" & $v & "\""
proc pyLit*(v: Slice[int]): string {.compileTime.} = "range(" & $v.a & ", " & $(v.b + 1) & ")"
proc pyLit*[T: object](v: T): string {.compileTime.} = "None"

proc addPy*(class, text: string, defaults: varargs[string]) {.compileTime.} =
  ## Adds generated Python text, filling the default placeholders.
  var t = text
  for i, d in defaults: t = t.replace("\x01" & $i & "\x01", d)
  if class.len == 0: generated.pyFns.add t
  else: generated.pyMethods.mgetOrPut(class, "").add t

proc addPyStruct*(text: string) {.compileTime.} =
  ## Adds generated Python struct text (the input structs' defaults).
  generated.pyStructs.add text

# --------------------------------------------------------- type analysis --

func stripObj(s: string): string =
  if s.endsWith("Obj") and s.len > 3: s[0 ..< ^3] else: s

proc typeDefOf(t: NimNode): NimNode =
  if t.kind == nnkSym:
    let i = t.getImpl
    if i.kind == nnkTypeDef: return i
  nil

proc handlePragma(td: NimNode): NimNode =
  ## The `segHandle` pragma of a type definition, or nil.
  if td == nil or td[0].kind != nnkPragmaExpr: return nil
  for p in td[0][1]:
    let n = if p.kind in {nnkCall, nnkExprColonExpr}: p[0] else: p
    if n.kind in {nnkSym, nnkIdent} and $n == "segHandle": return p
  nil

proc collectDocs(b: var Bindings, t: NimNode) =
  ## Reads the doc comments of object type `t` from its source (the lines of
  ## its declaration): `##` lines right after `= object` are the type's, a
  ## field's trailing and continuation `##` lines are the field's.
  let name = t.repr
  if name in b.typeDocs: return
  b.typeDocs[name] = ""
  let impl = typeDefOf(t)
  if impl == nil: return
  let li = impl.lineInfoObj
  let lines = readFile(li.filename).splitLines
  var i = li.line - 1
  if i < 0 or i >= lines.len: return
  let typeIndent = lines[i].len - lines[i].strip(trailing = false).len
  var cur: seq[string] = @[]
  var head = true
  inc i
  while i < lines.len:
    let raw = lines[i]
    let line = raw.strip
    let indent = raw.len - raw.strip(trailing = false).len
    if line.len > 0 and indent <= typeIndent: break
    inc i
    if line.len > 0:
      let at = line.find("##")
      let code = (if at >= 0: line[0 ..< at] else: line).strip
      let doc = if at >= 0: line[at + 2 .. ^1].strip else: ""
      if code.len == 0:
        if doc.len > 0:
          if head: b.typeDocs[name] = (b.typeDocs[name] & " " & doc).strip
          else:
            for f in cur:
              b.fieldDocs[name & "." & f] = (b.fieldDocs.getOrDefault(name & "." & f) & " " &
                doc).strip
      elif ':' in code:
        head = false
        cur = @[]
        for f in code[0 ..< code.find(':')].split(','):
          var fname = f.strip
          if '{' in fname: fname = fname[0 ..< fname.find('{')].strip
          cur.add fname.strip(chars = {'*', '`', ' '})
        if doc.len > 0:
          for f in cur: b.fieldDocs[name & "." & f] = doc

proc handleIndex(b: var Bindings, t: NimNode): int =
  ## The handle that type `t` crosses as, or -1.
  var value = t
  if t.kind == nnkBracketExpr and t[0].kind == nnkSym and $t[0] == "Handle":
    value = t[1]
  let td = typeDefOf(value)
  let p = handlePragma(td)
  if p == nil: return -1
  let isRef = value == t and value.getTypeImpl.kind == nnkRefTy
  let nimName = $value
  for i, h in b.handles:
    if h.node == value or (h.refType == nimName) or
        (h.core and h.refType == "Handle[" & nimName & "]"):
      return i
  var name = stripObj(nimName)
  if p.kind in {nnkCall, nnkExprColonExpr} and p.len > 1 and p[1].kind == nnkStrLit and
      p[1].strVal.len > 0:
    name = p[1].strVal
  b.collectDocs(value)
  b.handles.add HandleInfo(name: name, cName: "Seg" & name, short: snake(name),
    doc: b.typeDocs.getOrDefault(value.repr), node: value, core: not isRef,
    refType: if isRef: nimName else: "Handle[" & nimName & "]")
  result = b.handles.high
  let h = b.handles[result]
  b.text.hHandles.add "typedef struct " & h.cName & " " & h.cName & ";\n"
  b.text.pyClasses.add PyClass(name: h.name, short: h.short, doc: h.doc)
  let rel = "seg_" & h.short & "_release"
  b.text.hFns.add "\n/* Releases a " & h.cName & " (NULL is a no-op). */\nvoid " & rel & "(" &
    h.cName & " *handle);\n"
  b.text.pyDecls.add "_lib." & rel & ".argtypes = [ctypes.c_void_p]\n_lib." & rel &
    ".restype = None\n"
  b.mirrorCode.add "proc segRelease_" & h.short & "(h: pointer) {.exportc: \"" & rel &
    "\", dynlib, cdecl, raises: [].} =\n  if h != nil: GC_unref(cast[" & h.refType & "](h))\n"

proc intInfo(k: NimTypeKind, r: var AbiType): bool =
  result = true
  case k
  of ntyInt, ntyInt64:
    (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("int64", "int64_t", "ctypes.c_int64",
      "-(1 << 63)", "(1 << 63) - 1")
  of ntyInt32: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("int32", "int32_t", "ctypes.c_int32",
    "-(1 << 31)", "(1 << 31) - 1")
  of ntyInt16: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("int16", "int16_t", "ctypes.c_int16",
    "-32768", "32767")
  of ntyInt8: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("int8", "int8_t", "ctypes.c_int8",
    "-128", "127")
  of ntyUInt64, ntyUInt: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("uint64", "uint64_t",
    "ctypes.c_uint64", "0", "(1 << 64) - 1")
  of ntyUInt32: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("uint32", "uint32_t",
    "ctypes.c_uint32", "0", "(1 << 32) - 1")
  of ntyUInt16: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("uint16", "uint16_t",
    "ctypes.c_uint16", "0", "65535")
  of ntyUInt8: (r.cNim, r.cType, r.pyType, r.lo, r.hi) = ("uint8", "uint8_t", "ctypes.c_uint8",
    "0", "255")
  else: result = false

proc mirrorIndex(b: var Bindings, t: NimNode): int

proc classify(b: var Bindings, t0: NimNode, what: string): AbiType =
  var t = t0
  if t.kind == nnkVarTy:
    result.isVar = true
    t = t[0]
  if t.kind in {nnkBracketExpr, nnkCommand} and t[0].kind == nnkSym and $t[0] in ["lent", "sink"]:
    result.isLent = $t[0] == "lent"
    t = t[1]
  result.nim = t.repr
  result.node = t
  let h = b.handleIndex(t)
  if h >= 0:
    result.kind = akHandle
    result.handle = h
    result.cType = b.handles[h].cName & " *"
    result.pyType = "ctypes.c_void_p"
    return
  case result.nim
  of "FieldValue":
    result.kind = akValue
    return
  of "string":
    result.kind = akString
    return
  of "pointer":
    (result.kind, result.cNim, result.cType, result.pyType) =
      (akPointer, "pointer", "void *", "ctypes.c_void_p")
    return
  else: discard
  if result.nim.startsWith("Slice[") or result.nim.startsWith("HSlice["):
    if result.nim notin ["Slice[int]", "HSlice[int, int]", "HSlice[system.int, system.int]"]:
      error("segApi: only Slice[int] is supported (" & what & ")", t0)
    result.kind = akSlice
    return
  let k = t.typeKind
  if intInfo(k, result):
    result.kind = akInt
    return
  case k
  of ntyBool: (result.kind, result.cNim, result.cType, result.pyType) =
    (akBool, "bool", "bool", "ctypes.c_bool")
  of ntyFloat, ntyFloat64: (result.kind, result.cNim, result.cType, result.pyType) =
    (akFloat, "float64", "double", "ctypes.c_double")
  of ntyFloat32: (result.kind, result.cNim, result.cType, result.pyType) =
    (akFloat, "float32", "float", "ctypes.c_float")
  of ntyEnum: (result.kind, result.cNim, result.cType, result.pyType) =
    (akEnum, "int32", "int32_t", "ctypes.c_int32")
  of ntyRange:
    let ti = t.getTypeImpl
    let rng = ti[1]
    result.kind = akInt
    discard intInfo(ntyInt64, result)
    result.isRange = true
    result.lo = $rng[1].intVal
    result.hi = $rng[2].intVal
  of ntyArray:
    result.kind = akVoid # an array field; see `arrayOf`
  of ntyOpenArray:
    let e = t[1].repr
    if e notin ["int", "int64"]:
      error("segApi: only openArray[int] is supported (" & what & ")", t0)
    result.kind = akIds
  of ntySequence:
    let e = b.classify(t[1], what & " element")
    if e.kind == akInt and e.cNim == "uint8": result.kind = akBytes
    elif e.kind in {akInt, akFloat, akStruct}:
      result.kind = akSeq
      result.elem = @[e]
    else: error("segApi: unsupported sequence element " & e.nim & " (" & what & ")", t0)
  of ntyObject:
    result.kind = akStruct
    result.mirror = b.mirrorIndex(t)
    result.cType = b.mirrors[result.mirror].cName
    result.pyType = b.mirrors[result.mirror].cName
  else:
    error("segApi: unsupported type " & result.nim & " (" & what & ")", t0)

# ------------------------------------------------------- struct mirrors --

proc mirrorIndex(b: var Bindings, t: NimNode): int =
  let nimName = t.repr
  for i, m in b.mirrors:
    if m.nim == nimName: return i
  let td = typeDefOf(t)
  if td == nil: error("segApi: cannot mirror " & nimName, t)
  # Exported fields from the declaration, types from the typed implementation.
  var exported: seq[string]
  let rec = td[2]
  if rec.kind != nnkObjectTy or rec[1].kind != nnkEmpty:
    error("segApi: " & nimName & " must be a plain object (no inheritance)", t)
  for d in rec[2]:
    if d.kind != nnkIdentDefs: error("segApi: " & nimName & ": variant objects are unsupported", t)
    for n in d[0 ..^ 3]:
      var x = n
      if x.kind == nnkPragmaExpr: x = x[0]
      if x.kind == nnkPostfix: exported.add $x[1]
  b.collectDocs(t)
  var m = MirrorInfo(nim: nimName, node: t, cName: "Seg" & stripObj(nimName), input: true)
  m.mirror = "M" & m.cName
  let ti = t.getTypeImpl
  for d in ti[2]:
    for n in d[0 ..^ 3]:
      if $n in exported:
        let ft = b.classify(d[^2], nimName & "." & $n)
        case ft.kind
        of akString:
          m.strings = true
          m.input = false
        of akHandle: m.input = false
        of akStruct:
          if b.mirrors[ft.mirror].strings: m.strings = true
          if not b.mirrors[ft.mirror].input: m.input = false
        of akInt, akFloat, akBool, akEnum, akPointer, akSlice: discard
        else:
          if ft.node.typeKind == ntyArray: discard
          else: error("segApi: unsupported field type " & ft.nim & " in " & nimName, t)
        m.fields.add MirrorField(nim: $n, c: snake($n), t: ft)
  b.mirrors.add m
  result = b.mirrors.high

proc arrayOf(n: NimNode): (int, NimNode) =
  ## Length and element type of an array type.
  let ti = n.getTypeImpl
  let r = ti[1]
  let len = if r.kind == nnkInfix: int(r[2].intVal - r[1].intVal + 1)
            elif r.kind in {nnkIntLit .. nnkUInt64Lit}: int(r.intVal)
            else: int(r.getTypeImpl[2].intVal - r.getTypeImpl[1].intVal + 1)
  (len, ti[2])

proc fieldC(b: var Bindings, f: MirrorField): (string, string, string, string, string, string) =
  ## Mirror type, C declaration (`$1` = name), ctypes type, C value (`$1`),
  ## Nim value from C (`$1`, `$2` = name), Python out and in conversions.
  let t = f.t
  case t.kind
  of akInt, akFloat, akBool:
    (t.cNim, t.cType & " $1", t.pyType, t.cNim & "($1)", t.nim & "($1)", "$1")
  of akEnum:
    b.staticCode.add "  registerEnum(" & t.nim & ")\n"
    ("int32", "int32_t $1", "ctypes.c_int32", "int32(ord($1))", "enumArg[" & t.nim & "]($1, $2)",
      "_N_" & t.nim & ".get($1, $1)")
  of akString:
    ("cstring", "const char *$1", "ctypes.c_char_p", "cstring($1)", "", "_dec($1)")
  of akPointer:
    ("pointer", "void *$1", "ctypes.c_void_p", "$1", "$1", "$1")
  of akHandle:
    let h = b.handles[t.handle]
    ("pointer", h.cName & " *$1", "ctypes.c_void_p", "keep($1)", "", "_wrap(" & h.name & ", $1)")
  of akStruct:
    let m = b.mirrors[t.mirror]
    (m.mirror, m.cName & " $1", m.cName, "toC($1)", "fromC($1, $2)", "_struct_dict($1)")
  of akSlice:
    ("MSegSlice", "SegSlice $1", "SegSlice", "toC($1)", "fromC($1, $2)", "range($1.a, $1.b + 1)")
  else:
    # array[N, T] of a fixed-width number
    let (len, et) = arrayOf(t.node)
    let n = $len
    let e = b.classify(et, f.nim)
    if e.kind notin {akInt, akFloat} or e.cNim != e.nim:
      error("segApi: arrays need a fixed-width number element (" & f.nim & ")", t.node)
    ("array[" & n & ", " & e.cNim & "]", e.cType & " $1[" & n & "]", "(" & e.pyType & " * " & n &
      ")", "$1", "$1", "list($1)")

proc markInput(b: var Bindings, i: int) =
  b.mirrors[i].usedAsInput = true
  for f in b.mirrors[i].fields:
    if f.t.kind == akStruct: b.markInput(f.t.mirror)

proc pyIn(b: var Bindings, f: MirrorField): string =
  let t = f.t
  case t.kind
  of akInt: "lambda _x, _n: _int(_x, _n, " & t.lo & ", " & t.hi & ")"
  of akFloat: "lambda _x, _n: _f64(_x, _n)"
  of akBool: "lambda _x, _n: bool(_x)"
  of akEnum: "lambda _x, _n: _enum(_E_" & t.nim & ", _x, _n)"
  of akPointer: "lambda _x, _n: _x"
  of akStruct: "lambda _x, _n: _struct_arg(" & b.mirrors[t.mirror].cName & ", _x, _n)"
  of akSlice: "lambda _x, _n: SegSlice(*_range_arg(_x, _n))"
  else:
    let (len, et) = arrayOf(t.node)
    "lambda _x, _n: (" & b.classify(et, f.nim).pyType & " * " & $len & ")(*_x)"

proc emitMirror(b: var Bindings, i: int) =
  ## Generates mirror `i` (after the mirrors it nests): the Nim type, `toC`,
  ## `fromC`, the header struct and the Python class.
  if b.mirrors[i].done: return
  b.mirrors[i].done = true
  for f in b.mirrors[i].fields:
    if f.t.kind == akStruct: b.emitMirror(f.t.mirror)
  let m = b.mirrors[i]
  var typ = "type " & m.mirror & "* {.bycopy.} = object\n"
  var to = "proc toC*(x: " & m.nim & "): " & m.mirror & " =\n  " & m.mirror & "("
  var frm = "proc fromC*(m: " & m.mirror & ", name: string): " & m.nim & " =\n  " & m.nim & "("
  var pyLitFn = "proc segPy_" & m.cName & "*(x: " & m.nim & "): string {.compileTime.} =\n" &
    "  \"{\""
  var hBody, pyFields, pyOut, pyInT = ""
  for k, f in m.fields:
    let (mt, cdecl, ctype, toCv, fromCv, pyOutC) = b.fieldC(f)
    typ.add "  " & f.nim & "*: " & mt & "\n"
    to.add (if k > 0: ", " else: "") & f.nim & ": " & toCv.replace("$1", "x." & f.nim)
    if m.input:
      frm.add (if k > 0: ", " else: "") & f.nim & ": " &
        fromCv.replace("$1", "m." & f.nim).replace("$2", "name & \"." & f.c & "\"")
      pyLitFn.add " & \"" & (if k > 0: ", " else: "") & "\\\"" & f.c & "\\\": \" & " &
        (if f.t.kind == akStruct: "segPy_" & b.mirrors[f.t.mirror].cName & "(x." & f.nim & ")"
         elif f.t.kind in {akPointer, akVoid}: "\"None\""
         else: "pyLit(x." & f.nim & ")")
    let fd = b.fieldDocs.getOrDefault(m.nim & "." & f.nim)
    let edoc = if f.t.kind == akEnum: "SEG_" & upperSnake(f.t.nim) & "_*" else: ""
    let doc = [edoc, fd].join(": ").strip(chars = {':', ' '})
    hBody.add "    " & cdecl.replace("$1", f.c) & ";" & (if doc.len > 0: " /* " & doc & " */"
      else: "") & "\n"
    pyFields.add "        (\"" & f.c & "\", " & ctype & "),\n"
    pyOut.add "(\"" & f.c & "\", lambda _v: " & pyOutC.replace("$1", "_v") & "), "
    if m.input: pyInT.add "\"" & f.c & "\": " & b.pyIn(f) & ", "
  to.add ")\n"
  frm.add ")\n"
  pyLitFn.add " & \"}\"\n"
  b.mirrorCode.add typ & to & (if m.input: frm & pyLitFn else: "")
  b.text.hStructs.add "\n" & cComment(b.typeDocs.getOrDefault(m.nim), "") & "typedef struct " &
    m.cName & " {\n" & hBody & "} " & m.cName & ";\n"
  b.text.pyStructs.add "\n\nclass " & m.cName & "(ctypes.Structure):\n" &
    pyDoc(b.typeDocs.getOrDefault(m.nim), "    ") & "    _fields_ = [\n" & pyFields & "    ]\n" &
    "    _out = (" & pyOut & ")\n    _in = {" & pyInT & "}\n    _defaults = {}\n"

# ------------------------------------------------------------ the routines --

type
  Param = object
    name: string
    t: AbiType
    default: NimNode

  RoutineInfo = object
    ## One exported routine: its typed signature, options and derived names.
    sig, overloads: NimNode
    name, file, doc: string
    isFunc, concurrent, abiOnly, private: bool
    hide: seq[string]
    params: seq[Param]
    ret: AbiType
    cls: int         ## handle of the Python class (-1: module function)
    isMethod, ctor, prop: bool
    cName, pyName: string
    overloadSlice: int ## the Slice parameter of a range/list pair (-1: none)
    pairName: string ## Python name of the pair's dispatcher

proc parseRec(b: var Bindings, n: NimNode): RoutineInfo =
  result.sig = n[0]
  result.overloads = n[2]
  # `info` is `(name, "proc" | "func", file, doc, [flags], [hidden params])`;
  # see `pragmas.segApi`.
  let info = n[1]
  result.name = info[0].strVal
  result.isFunc = info[1].strVal == "func"
  result.file = info[2].strVal
  result.doc = info[3].strVal
  for f in info[4]:
    case f.strVal
    of "concurrent": result.concurrent = true
    of "abiOnly": result.abiOnly = true
    of "private": result.private = true
    else: error("segApi: unknown flag " & f.strVal, result.sig)
  for h in info[5]: result.hide.add h.strVal
  let fp = result.sig.params
  for i in 1 ..< fp.len:
    for id in fp[i][0 ..^ 3]:
      let nm = id.repr.strip(chars = {'`'})
      if nm in result.hide:
        if fp[i][^1].kind == nnkEmpty: error("segApi: hide needs a defaulted parameter", id)
      else:
        result.params.add Param(name: nm, t: b.classify(id.getTypeInst, result.name & "." & nm),
          default: fp[i][^1])
  result.ret = if fp[0].kind == nnkEmpty: AbiType(kind: akVoid)
               else: b.classify(fp[0], result.name & " result")
  result.cls = -1
  result.overloadSlice = -1

proc involvesAdapter(b: Bindings, r: RoutineInfo): bool =
  ## Adapters (in `api.nim`) take or return boundary types: `Handle[T]` or a
  ## ref handle.
  for p in r.params:
    if p.t.kind == akHandle and (not b.handles[p.t.handle].core or p.t.nim.startsWith("Handle[")):
      return true
  r.ret.kind == akHandle and not b.handles[r.ret.handle].core

proc checkAdapter(r: var RoutineInfo) =
  ## An adapter must overload a core routine with the same parameter names
  ## (core `var` and defaulted ones may be left out; a generic `T` is
  ## `dtype`). Without its own doc it takes the core routine's.
  var cands: seq[NimNode]
  if r.overloads.kind in {nnkClosedSymChoice, nnkOpenSymChoice}:
    for s in r.overloads: cands.add s
  elif r.overloads.kind == nnkSym: cands.add r.overloads
  let skip = if r.params.len > 0 and r.params[0].t.kind == akHandle and not r.ctor: 1 else: 0
  var mine: seq[string]
  for p in r.params[skip .. ^1]:
    if p.name != "dtype": mine.add p.name
  for c in cands:
    let im = c.getImpl
    # A core candidate: a routine declared outside the adapters' module.
    if im.kind in RoutineNodes and im.lineInfoObj.filename != r.file:
      var core: seq[(string, bool)] # name, may be left out
      let ps = im.params
      var first = true
      for i in 1 ..< ps.len:
        for id in ps[i][0 ..^ 3]:
          if first and skip == 1: first = false
          else:
            first = false
            let optional = ps[i][^1].kind != nnkEmpty or ps[i][^2].kind == nnkVarTy or
              ps[i][^2].repr.startsWith("typedesc")
            core.add ($id, optional)
      var j = 0
      var ok = true
      for (nm, optional) in core:
        if j < mine.len and mine[j] == nm: inc j
        elif not optional: ok = false
      if ok and j == mine.len:
        if r.doc.len == 0 and im.body.kind == nnkStmtList:
          for s in im.body:
            if s.kind != nnkCommentStmt: break
            r.doc.add (if r.doc.len > 0: "\n" else: "") & s.strVal
        return
  error("segApi: adapter " & r.name & "(" & mine.join(", ") & ") overloads no core routine " &
    "with these parameter names; rename it after the core, or mark it abiOnly", r.sig)

proc deriveNames(b: Bindings, r: var RoutineInfo) =
  ## Derives the C and Python names and the Python role.
  let ctorOf = if r.ret.kind == akHandle: b.handles[r.ret.handle].name else: ""
  r.ctor = ctorOf.len > 0 and (r.name == "new" & ctorOf or r.name == "init" & ctorOf)
  r.isMethod = not r.ctor and r.params.len > 0 and r.params[0].t.kind == akHandle
  if r.ctor: r.cls = r.ret.handle
  elif r.isMethod: r.cls = r.params[0].t.handle
  let part = case r.name
    of "len": "len"
    of "[]": "get"
    else: snake(r.name)
  r.cName = if r.ctor: "seg_" & b.handles[r.cls].short & "_new"
            elif r.isMethod: "seg_" & b.handles[r.cls].short & "_" & part
            else: "seg_" & part
  r.pyName = if r.ctor: "__init__"
             elif r.isMethod and r.name == "len": "__len__"
             elif r.isMethod and r.name == "[]": "_getitem"
             elif r.isMethod and r.name == "close": "_close_native"
             else: snake(r.name)
  if r.private: r.pyName = "_" & r.pyName
  r.prop = r.isFunc and r.isMethod and r.params.len == 1 and r.ret.kind != akVoid and
    r.name notin ["len", "[]"]

# ------------------------------------------------------ wrapper generation --

type
  PyMode = enum
    ## How the Python side calls the C function and returns its result.
    pmPlain ## Through `pyPre`/`pyPost` (scalars, handles, structs, no result).
    pmText  ## Into a text buffer, retried when too small.
    pmBytes ## Into a byte buffer, retried when too small.
    pmSeq   ## Into a typed buffer (`seqType`), converted by `seqConv`.
    pmLog   ## A `DiagLog` that comes back even when the call fails.
    pmValue ## A `FieldValue`.

  Gen = object
    ## One C wrapper and its Python function, built parameter by parameter.
    cParams, hParams, pyArgTypes, callArgs, pyParams, pyCall: seq[string]
    convs, write, pyPre, pyPost, logOut: string
    pyMode: PyMode
    seqType, seqConv: string ## `pmSeq`: ctypes element type and per-element conversion
    defaults: seq[NimNode]
    outNil: bool

proc genParam(b: var Bindings, g: var Gen, k: int, p: Param, isSelf: bool) =
  let a = "a" & $k
  let v = "v" & $k
  let cn = snake(p.name)
  let t = p.t
  let pyn = if isSelf: "self" else: cn
  if not isSelf:
    if p.default.kind != nnkEmpty:
      g.pyParams.add pyn & "=\x01" & $g.defaults.len & "\x01"
      g.defaults.add p.default
    else: g.pyParams.add pyn
  var call = v
  case t.kind
  of akInt, akFloat, akBool:
    g.cParams.add a & ": " & t.cNim
    g.hParams.add t.cType & " " & cn
    g.pyArgTypes.add t.pyType
    if t.isRange:
      g.convs.add "    let " & v & " = " & t.nim & "(rangeArg(" & a & ", " & t.lo & ", " & t.hi &
        ", \"" & cn & "\"))\n"
    else:
      g.convs.add "    let " & v & " = " & t.nim & "(" & a & ")\n"
    g.pyCall.add(case t.kind
      of akInt: "_int(" & pyn & ", \"" & cn & "\", " & t.lo & ", " & t.hi & ")"
      of akFloat: "_f64(" & pyn & ", \"" & cn & "\")"
      else: "bool(" & pyn & ")")
  of akEnum:
    g.cParams.add a & ": int32"
    g.hParams.add "int32_t " & cn
    g.pyArgTypes.add "ctypes.c_int32"
    g.convs.add "    let " & v & " = enumArg[" & t.nim & "](" & a & ", \"" & cn & "\")\n"
    b.staticCode.add "  registerEnum(" & t.nim & ")\n"
    g.pyCall.add "_enum(_E_" & t.nim & ", " & pyn & ", \"" & cn & "\")"
  of akString:
    g.cParams.add a & ": cstring"
    g.hParams.add "const char *" & cn
    g.pyArgTypes.add "ctypes.c_char_p"
    g.convs.add "    let " & v & " = " &
      (if p.default.kind != nnkEmpty: "optStringArg(" & a & ", " & p.default.repr & ")\n"
       else: "stringArg(" & a & ", \"" & cn & "\")\n")
    g.pyCall.add "_str(" & pyn & ", \"" & cn & "\")"
  of akHandle:
    let h = b.handles[t.handle]
    let hn = if isSelf: h.short else: cn
    g.cParams.add a & ": pointer"
    g.hParams.add h.cName & " *" & hn
    g.pyArgTypes.add "ctypes.c_void_p"
    g.convs.add "    let " & v & " = handleArg[" & h.refType & "](" & a & ", \"" & hn & "\")\n"
    if h.core and not t.nim.startsWith("Handle["): call = v & ".v"
    g.pyCall.add(if isSelf: "_h" else: "_handle(" & pyn & ", " & h.name & ", \"" & cn & "\")")
  of akStruct:
    let m = b.mirrors[t.mirror]
    if not m.input: error("segApi: " & m.nim & " cannot be a parameter", t.node)
    b.markInput(t.mirror)
    g.cParams.add a & ": ptr " & m.mirror
    g.hParams.add "const " & m.cName & " *" & cn
    g.pyArgTypes.add "ctypes.POINTER(" & m.cName & ")"
    g.convs.add "    let " & v & " = if " & a & " == nil: " & m.nim & "() else: fromC(" & a &
      "[], \"" & cn & "\")\n"
    g.pyCall.add "ctypes.byref(_struct_arg(" & m.cName & ", " & pyn & ", \"" & cn & "\"))"
  of akSlice:
    g.cParams.add a & "f: int64"
    g.cParams.add a & "l: int64"
    g.hParams.add "int64_t " & cn & "_first"
    g.hParams.add "int64_t " & cn & "_last"
    g.pyArgTypes.add "ctypes.c_int64"
    g.pyArgTypes.add "ctypes.c_int64"
    g.convs.add "    let " & v & " = int(" & a & "f) .. int(" & a & "l)\n"
    g.pyCall.add "*_range_arg(" & pyn & ", \"" & cn & "\")"
  of akIds:
    g.cParams.add a & ": ptr UncheckedArray[int64]"
    g.cParams.add a & "n: int64"
    g.hParams.add "const int64_t *" & cn
    g.hParams.add "int64_t " & cn & "_len"
    g.pyArgTypes.add "ctypes.POINTER(ctypes.c_int64)"
    g.pyArgTypes.add "ctypes.c_int64"
    g.convs.add "    let " & v & " = idsArg(" & a & ", " & a & "n, \"" & cn & "\")\n"
    call = "toOpenArray(" & v & ", 0, int(" & a & "n) - 1)"
    g.pyCall.add "*_ids(" & pyn & ", \"" & cn & "\")"
  of akValue:
    g.cParams.add a & ": ptr SegValue"
    g.hParams.add "const SegValue *" & cn
    g.pyArgTypes.add "ctypes.POINTER(SegValue)"
    g.convs.add "    let " & v & " = valueArg(" & a & ", \"" & cn & "\")\n"
    g.pyCall.add "ctypes.byref(_value_in(" & pyn & ", \"" & cn & "\"))"
  else:
    error("segApi: unsupported parameter type " & t.nim, t.node)
  g.callArgs.add call

proc genResult(b: var Bindings, g: var Gen, t: AbiType, call: string, isProc, ctor: bool) =
  ## The out-pointer of the result and the code that fills it.
  case t.kind
  of akVoid:
    g.write = call
  of akInt, akFloat, akBool, akPointer, akEnum:
    let nt = if t.kind == akEnum: "int32" else: t.cNim
    let ct = if t.kind == akEnum: "int32_t" else: t.cType
    let pt = if t.kind == akEnum: "ctypes.c_int32" else: t.pyType
    g.cParams.add "o: ptr " & nt
    g.hParams.add ct & (if ct.endsWith("*"): "*out" else: " *out")
    g.pyArgTypes.add "ctypes.POINTER(" & pt & ")"
    g.write = "let r = " & call & "\nif o != nil: o[] = " &
      (if t.kind == akEnum: "int32(ord(r))" else: nt & "(r)")
    if t.kind == akEnum: b.staticCode.add "  registerEnum(" & t.nim & ")\n"
    g.pyPre = "_o = " & pt & "()"
    g.pyCall.add "ctypes.byref(_o)"
    g.pyPost = if t.kind == akEnum: "return _N_" & t.nim & "[_o.value]" else: "return _o.value"
  of akString:
    g.cParams.add "o: ptr UncheckedArray[char]"
    g.cParams.add "ocap: int64"
    g.cParams.add "olen: ptr int64"
    g.hParams.add "char *out"
    g.hParams.add "int64_t out_cap"
    g.hParams.add "int64_t *out_len"
    g.pyArgTypes.add "ctypes.c_char_p"
    g.pyArgTypes.add "ctypes.c_int64"
    g.pyArgTypes.add "ctypes.POINTER(ctypes.c_int64)"
    g.write = "writeText(" & call & ", o, ocap, olen)"
    g.pyMode = pmText
  of akHandle:
    let h = b.handles[t.handle]
    g.cParams.add "o: ptr pointer"
    g.hParams.add h.cName & " **out"
    g.pyArgTypes.add "ctypes.POINTER(ctypes.c_void_p)"
    g.outNil = true
    let wrapped = if h.core and not t.nim.startsWith("Handle["): h.refType & "(v: " & call & ")"
                  else: call
    if h.name == "DiagLog" and isProc and not t.isLent:
      g.write = "let r = " & call & "\nif r.isFatal: raiseFatal(r)\nif o != nil: o[] = keep(" &
        h.refType & "(v: r))"
      g.logOut = "o"
      g.pyMode = pmLog
    else:
      g.write = "let r = keep(" & wrapped & ")\nif o != nil: o[] = r\nelse: GC_unref(cast[" &
        h.refType & "](r))"
      g.pyPre = "_o = ctypes.c_void_p()"
      g.pyCall.add "ctypes.byref(_o)"
      g.pyPost = if ctor: "self._h = _o.value\nself._mu = threading.Lock()"
                 else: "return _wrap(" & h.name & ", _o.value)"
  of akStruct:
    let m = b.mirrors[t.mirror]
    if m.strings and not t.isLent:
      error("segApi: " & m.nim & " holds text, so only a lent result can return it", t.node)
    g.cParams.add "o: ptr " & m.mirror
    g.hParams.add m.cName & " *out"
    g.pyArgTypes.add "ctypes.POINTER(" & m.cName & ")"
    g.write = "if o != nil: o[] = toC(" & call & ")\nelse: discard " & call
    g.pyPre = "_o = " & m.cName & "()"
    g.pyCall.add "ctypes.byref(_o)"
    g.pyPost = "return _struct_dict(_o)"
  of akSeq, akBytes:
    var et, ct, pt, conv, pconv: string
    if t.kind == akBytes:
      (et, ct, pt, conv) = ("uint8", "uint8_t", "ctypes.c_uint8", "uint8")
    else:
      let e = t.elem[0]
      case e.kind
      of akStruct:
        let m = b.mirrors[e.mirror]
        if m.strings: error("segApi: a seq cannot hold text (" & m.nim & ")", t.node)
        (et, ct, pt, conv, pconv) = (m.mirror, m.cName, m.cName, "toC", "_struct_dict")
      else:
        (et, ct, pt, conv, pconv) = (e.cNim, e.cType, e.pyType, e.cNim, "lambda _v: _v")
    g.cParams.add "o: ptr UncheckedArray[" & et & "]"
    g.cParams.add "ocap: int64"
    g.cParams.add "olen: ptr int64"
    g.hParams.add ct & " *out"
    g.hParams.add "int64_t out_cap"
    g.hParams.add "int64_t *out_len"
    g.pyArgTypes.add "ctypes.POINTER(" & pt & ")"
    g.pyArgTypes.add "ctypes.c_int64"
    g.pyArgTypes.add "ctypes.POINTER(ctypes.c_int64)"
    g.write = "let r = " & call & "\nwriteSeqWith(r, o, ocap, olen, " & conv & ")"
    if t.kind == akBytes: g.pyMode = pmBytes
    else: (g.pyMode, g.seqType, g.seqConv) = (pmSeq, pt, pconv)
  of akValue:
    g.cParams.add "o: ptr SegValue"
    g.hParams.add "SegValue *out"
    g.pyArgTypes.add "ctypes.POINTER(SegValue)"
    g.write = "writeValue(o, " & call & ")"
    g.pyMode = pmValue
  else:
    error("segApi: unsupported result type " & t.nim, t.node)

proc pyBody(g: Gen, cName: string): seq[string] =
  ## The Python statements that call `cName` and return its result.
  let args = "_lib." & cName & (if g.pyCall.len > 0: ", " & g.pyCall.join(", ") else: "")
  case g.pyMode
  of pmText:
    result.add "return _text(lambda _b, _c, _n: _call(" & args & ", _b, _c, _n))"
  of pmBytes:
    result.add "return _bytes(lambda _b, _c, _n: _call(" & args & ", _b, _c, _n))"
  of pmLog:
    result.add "_o = ctypes.c_void_p()"
    result.add "_st = " & "_lib." & cName & "(" &
      (if g.pyCall.len > 0: g.pyCall.join(", ") & ", " else: "") & "ctypes.byref(_o))"
    result.add "return _logged(_st, _o)"
  of pmValue:
    result.add "_o = _value_out()"
    result.add "_call(" & args & ", ctypes.byref(_o))"
    result.add "return _value(_o)"
  of pmSeq:
    result.add "return _seq(lambda _b, _c, _n: _call(" & args & ", _b, _c, _n), " & g.seqType &
      ", " & g.seqConv & ")"
  of pmPlain:
    if g.pyPre.len > 0: result.add g.pyPre
    if g.pyPost.len > 0 and not g.pyPost.startsWith("self."):
      result.add "if _call(" & args & ") > 0:"
      result.add "    return None"
    else:
      result.add "_call(" & args & ")"
    for l in g.pyPost.splitLines:
      if l.len > 0: result.add l

proc pyFunction(r: RoutineInfo, g: Gen, defName: string, decorator = ""): string =
  let inClass = r.cls >= 0
  let base = if inClass: "    " else: ""
  var sig = g.pyParams
  if inClass: sig.insert("self", 0)
  result = "\n" & (if decorator.len > 0: base & decorator & "\n" else: "") & base & "def " &
    defName & "(" & sig.join(", ") & "):\n" & pyDoc(r.doc, base & "    ")
  let lines = pyBody(g, r.cName)
  if r.isMethod:
    result.add base & "    _h = self._enter()\n" & base & "    try:\n"
    for l in lines: result.add base & "        " & l & "\n"
    result.add base & "    finally:\n" & base & "        self._leave()\n"
  else:
    for l in lines: result.add base & "    " & l & "\n"

proc emitPy(b: var Bindings, cls: int, text: string, defaults: seq[NimNode]) =
  var defs = ""
  for d in defaults: defs.add ", pyLit(" & d.repr & ")"
  let class = if cls >= 0: b.handles[cls].name else: ""
  b.staticCode.add "  addPy(" & class.escape & ", " & text.escape & defs & ")\n"

proc emitDecl(b: var Bindings, cName: string, g: Gen, doc: string) =
  b.text.hFns.add "\n" & cComment(doc, "") & "SegStatus " & cName & "(" &
    (if g.hParams.len == 0: "void" else: g.hParams.join(", ")) & ");\n"
  b.text.pyDecls.add "_lib." & cName & ".argtypes = [" & g.pyArgTypes.join(", ") & "]\n" &
    "_lib." & cName & ".restype = ctypes.c_int32\n"

proc wrapper(cName, body: string, g: Gen): string =
  "proc segW_" & cName & "(" & g.cParams.join(", ") & "): int32 {.exportc: \"" & cName &
    "\", dynlib, cdecl, raises: [].} =\n  segGuard(" & (if g.logOut.len > 0: g.logOut else: "nil") &
    "):\n" & body

proc genRoutine(b: var Bindings, r: RoutineInfo): string =
  var g: Gen
  for k, p in r.params: b.genParam(g, k, p, k == 0 and r.isMethod)
  let call = (if r.name == "[]": g.callArgs[0] & "[" & g.callArgs[1 .. ^1].join(", ") & "]"
              else: "`" & r.name & "`(" & g.callArgs.join(", ") & ")")
  b.genResult(g, r.ret, call, not r.isFunc, r.ctor)
  if r.name == "[]":
    # A bad index from the host is an argument error, checked here: Nim's
    # `[]` treats it as a bug (IndexDefect), which a C boundary must not hit.
    let (recv, i) = (g.callArgs[0], g.callArgs[1])
    g.write = "if " & i & " notin 0 ..< len(" & recv & "): argError(\"index \" & $" & i &
      " & \" is out of range 0 ..< \" & $len(" & recv & "))\n" & g.write
  var body = ""
  if g.outNil: body.add "    if o != nil: o[] = nil\n"
  body.add g.convs
  let lockIt = r.params.len > 0 and r.params[0].t.kind == akHandle and not r.concurrent
  let ind = if lockIt: "      " else: "    "
  if lockIt: body.add "    withHandle(v0):\n"
  for l in g.write.splitLines: body.add ind & l & "\n"
  result = wrapper(r.cName, body, g)
  b.emitDecl(r.cName, g, r.doc)
  b.emitPy(r.cls, pyFunction(r, g, r.pyName, if r.prop: "@property" else: ""), g.defaults)

proc genField(b: var Bindings, h: int, field: NimNode, ft: NimNode, readonly: bool): string =
  ## Getter (and setter) of a `{.segField.}` field.
  let hi = b.handles[h]
  let fname = $field
  let doc = b.fieldDocs.getOrDefault(hi.node.repr & "." & fname)
  let t = b.classify(ft, hi.name & "." & fname)
  let r = RoutineInfo(name: fname, isFunc: true, cls: h, isMethod: true, prop: true, doc: doc,
    cName: "seg_" & hi.short & "_" & snake(fname), pyName: snake(fname))
  var g: Gen
  b.genParam(g, 0, Param(name: "self", t: b.classify(hi.node, hi.name)), true)
  b.genResult(g, t, "v0.v." & fname, false, false)
  var body = (if g.outNil: "    if o != nil: o[] = nil\n" else: "") & g.convs &
    "    withHandle(v0):\n"
  for l in g.write.splitLines: body.add "      " & l & "\n"
  result = wrapper(r.cName, body, g)
  b.emitDecl(r.cName, g, doc)
  b.emitPy(h, pyFunction(r, g, r.pyName, "@property"), @[])
  if not readonly:
    let s = RoutineInfo(name: fname & "=", cls: h, isMethod: true, doc: doc,
      cName: "seg_" & hi.short & "_set_" & snake(fname))
    var gs: Gen
    b.genParam(gs, 0, Param(name: "self", t: b.classify(hi.node, hi.name)), true)
    b.genParam(gs, 1, Param(name: "value", t: t, default: newEmptyNode()), false)
    let sb = gs.convs & "    withHandle(v0):\n      v0.v." & fname & " = v1\n"
    result.add wrapper(s.cName, sb, gs)
    b.emitDecl(s.cName, gs, "Sets " & snake(fname) & ".")
    b.emitPy(h, pyFunction(s, gs, snake(fname), "@" & snake(fname) & ".setter"), @[])

proc fieldPragma(n: NimNode): (bool, bool) =
  ## (exported with segField, readonly)
  if n.kind != nnkPragmaExpr: return (false, false)
  for p in n[1]:
    let id = if p.kind in {nnkCall, nnkExprColonExpr}: p[0] else: p
    if id.kind in {nnkSym, nnkIdent} and $id == "segField":
      var ro = false
      if p.kind == nnkCall:
        for a in p[1 .. ^1]:
          let v = if a.kind == nnkExprEqExpr: a[1] else: a
          if v.kind == nnkSym and $v == "true" or v.kind == nnkIntLit and v.intVal != 0:
            ro = true
      return (true, ro)
  (false, false)

proc genFields(b: var Bindings, h: int): string =
  let hi = b.handles[h]
  if not hi.core: return
  let td = typeDefOf(hi.node)
  let ti = hi.node.getTypeImpl
  var types: Table[string, NimNode]
  for d in ti[2]:
    for n in d[0 ..^ 3]: types[$n] = d[^2]
  for d in td[2][2]:
    for n in d[0 ..^ 3]:
      let (on, ro) = fieldPragma(n)
      if on:
        var x = n[0]
        if x.kind == nnkPostfix: x = x[1]
        result.add b.genField(h, x, types[$x], ro)

proc dispatcher(b: var Bindings, x, y: RoutineInfo): string =
  ## One Python function over a `Slice` / `openArray` pair.
  let (rng, lst) = if x.overloadSlice >= 0: (x, y) else: (y, x)
  let p = rng.params[rng.overloadSlice].name.snake
  var g: Gen
  for k, q in lst.params: b.genParam(g, k, q, k == 0 and lst.isMethod)
  let base = if lst.cls >= 0: "    " else: ""
  var sig = g.pyParams
  var fwd: seq[string]
  for q in sig: fwd.add q.split('=')[0]
  if lst.cls >= 0: sig.insert("self", 0)
  let target = if lst.cls >= 0: "self." else: ""
  result = "\n" & base & "def " & lst.pairName & "(" & sig.join(", ") & "):\n" &
    pyDoc(lst.doc, base & "    ") &
    base & "    if isinstance(" & p & ", range):\n" &
    base & "        return " & target & rng.pyName & "(" & fwd.join(", ") & ")\n" &
    base & "    return " & target & lst.pyName & "(" & fwd.join(", ") & ")\n"
  b.emitPy(lst.cls, result, g.defaults)

# ----------------------------------------------------------- the output --

const
  HeaderPreamble = staticRead("gen/header_preamble.h")
  PyRuntime = staticRead("gen/runtime.py")
  PyExtras = staticRead("gen/extras.py")

const segBindingsDir {.strdefine.} = ""
  ## Where `segFinish` writes the header and the Python package; default:
  ## the repository's `include/` and `python/parseseg/`.

proc headerText(abiVersion: int): string {.compileTime.} =
  result = HeaderPreamble.replace("@ABI_VERSION@", $abiVersion)
  result.add "\n/* ------------------------------------------------------ constants */\n"
  result.add generated.hEnums
  result.add "\n/* ---------------------------------------------------------- handles */\n\n"
  result.add generated.hHandles
  result.add "\n/* ---------------------------------------------------------- structs */\n"
  result.add generated.hStructs
  result.add "\n/* -------------------------------------------------------- functions */\n"
  result.add generated.hFns
  result.add "\n#ifdef __cplusplus\n}\n#endif\n\n#endif /* PARSESEG_H */\n"

proc pythonText(abiVersion: int, moduleDoc: string): string {.compileTime.} =
  result = "# Generated by parseSEG's `segApi` (src/parseSEG/abi/segapi.nim); do not edit.\n" &
    pyDoc(moduleDoc, "") & PyRuntime.replace("@ABI_VERSION@", $abiVersion)
  result.add "\n# ------------------------------------------------------------ enums\n\n"
  result.add generated.pyEnums
  result.add "\n# ---------------------------------------------------------- structs\n"
  result.add generated.pyStructs
  result.add "\n# ----------------------------------------------------- declarations\n\n"
  result.add generated.pyDecls
  result.add "\n# ----------------------------------------------------------- extras\n\n"
  result.add PyExtras
  result.add "\n# ---------------------------------------------------------- classes\n"
  for c in generated.pyClasses:
    let mixinCls =
      if ("class _" & c.name & "Extras") in PyExtras: ", _" & c.name & "Extras" else: ""
    let body = generated.pyMethods.getOrDefault(c.name, "")
    result.add "\n\nclass " & c.name & "(_Handle" & mixinCls & "):\n" & pyDoc(c.doc, "    ") &
      "    _release = _lib.seg_" & c.short & "_release\n" & body
    if "def __len__(" in body and "def _getitem(" in body:
      result.add """
    def __getitem__(self, index):
        i = operator.index(index)
        n = len(self)
        if i < 0:
            i += n
        if not 0 <= i < n:
            raise IndexError(f"{type(self).__name__} index out of range")
        return self._getitem(i)

    def __iter__(self):
        for i in range(len(self)):
            yield self._getitem(i)
"""
    if "def next(" in body:
      result.add """
    def __iter__(self):
        return self

    def __next__(self):
        c = self.next()
        if c is None:
            raise StopIteration
        return c
"""
  result.add "\n# -------------------------------------------------------- functions\n"
  result.add generated.pyFns

proc writeBindings*(abiVersion: int, moduleDoc: string) {.compileTime.} =
  ## Writes the header and the Python package (`-d:segBindingsDir`, else the
  ## repository). Joined with "/" by hand: at compile time `os./` uses the
  ## target's separator, so a Windows cross build would write "\\..." names.
  var root = currentSourcePath().replace('\\', '/')
  for _ in 1..4: root = root[0 ..< root.rfind('/')]
  let base = if segBindingsDir.len > 0: segBindingsDir.replace('\\', '/') else: root
  writeFile(base & "/include/parseseg.h", headerText(abiVersion))
  writeFile(base & "/python/parseseg/__init__.py", pythonText(abiVersion, moduleDoc))

macro segFinish*(abiVersion: static int, moduleDoc: static string): untyped =
  ## Generates the boundary from every `{.segApi.}` routine compiled so far
  ## (see the module documentation). Call it once, after all of them.
  result = newStmtList()
  when defined(segCapi):
    var b = Bindings()
    # The SegSlice mirror is built in.
    b.mirrors.add MirrorInfo(nim: "Slice[int]", cName: "SegSlice", mirror: "MSegSlice", input: true,
      done: true)
    b.text.hStructs.add "\n/* A trace range a..b, both included (Nim `Slice[int]`). */\n" &
      "typedef struct SegSlice {\n    int64_t a;\n    int64_t b;\n} SegSlice;\n"
    b.text.pyStructs.add "\n\nclass SegSlice(ctypes.Structure):\n    _fields_ = [(\"a\", " &
      "ctypes.c_int64), (\"b\", ctypes.c_int64)]\n    _out = ()\n    _in = {}\n" &
      "    _defaults = {}\n"
    var recs: seq[RoutineInfo]
    for n in segExports: recs.add b.parseRec(n)
    for r in recs.mitems:
      b.deriveNames(r)
      if not r.abiOnly and b.involvesAdapter(r): r.checkAdapter()
    # Overloads: only a Slice / openArray pair of one name.
    var groups: Table[(int, string), seq[int]]
    for i, r in recs: groups.mgetOrPut((r.cls, r.pyName), @[]).add i
    for key, ids in groups:
      if ids.len > 2:
        error("segApi: C cannot overload " & recs[ids[0]].name & " (" & $ids.len & " exports)",
          recs[ids[0]].sig)
      if ids.len == 2:
        let (x, y) = (ids[0], ids[1])
        var at = -1
        if recs[x].params.len == recs[y].params.len:
          for k in 0 ..< recs[x].params.len:
            let (kx, ky) = (recs[x].params[k].t.kind, recs[y].params[k].t.kind)
            if kx != ky:
              if at < 0 and {kx, ky} == {akSlice, akIds} and
                  recs[x].params[k].name == recs[y].params[k].name: at = k
              else: at = -2
        if at < 0:
          error("segApi: C cannot overload " & recs[x].name & "; only a Slice / openArray " &
            "pair of one parameter name is allowed", recs[y].sig)
        let (rng, lst) = if recs[x].params[at].t.kind == akSlice: (x, y) else: (y, x)
        recs[rng].overloadSlice = at
        recs[rng].cName.add "_range"
        let pyBase = recs[lst].pyName
        let stem = if pyBase == "__init__": "_init" else: "_" & pyBase.strip(chars = {'_'})
        recs[rng].pyName = stem & "_range"
        recs[lst].pyName = stem & "_list"
        recs[lst].pairName = pyBase
        recs[rng].pairName = pyBase
    var seen: Table[string, int]
    for i, r in recs:
      if r.cName in seen:
        error("segApi: two exports named " & r.cName, r.sig)
      seen[r.cName] = i
    for i in 0 ..< b.mirrors.len: b.emitMirror(i)
    var code = ""
    for r in recs: code.add b.genRoutine(r)
    for i in 0 ..< recs.len:
      let r = recs[i]
      if r.pairName.len > 0 and r.overloadSlice < 0:
        for j in 0 ..< recs.len:
          if j != i and recs[j].pairName == r.pairName and recs[j].cls == r.cls:
            discard b.dispatcher(recs[j], r)
    for h in 0 ..< b.handles.len: code.add b.genFields(h)
    for i in 0 ..< b.mirrors.len: b.emitMirror(i) # mirrors met in fields
    # Input structs: C initializers and Python defaults.
    for m in b.mirrors:
      if m.usedAsInput and m.nim != "Slice[int]":
        let fn = "seg_init_" & snake(m.cName[3 .. ^1])
        code.add "proc segI_" & fn & "(o: ptr " & m.mirror & ") {.exportc: \"" & fn &
          "\", dynlib, cdecl, raises: [].} =\n  if o != nil: o[] = toC(" & m.nim & "())\n"
        b.text.hFns.add "\n/* Fills a " & m.cName & " with the defaults. */\nvoid " & fn & "(" &
          m.cName & " *out);\n"
        b.staticCode.add "  addPyStruct(\"" & m.cName & "._defaults = \" & segPy_" & m.cName & "(" &
          m.nim & "()) & \"\\n\")\n"
    # Layout probes.
    var sz = "proc segSizeof(name: cstring): int64 {.exportc: \"seg_sizeof\", dynlib, cdecl, " &
      "raises: [].} =\n  if name == nil: return -1\n  case $name\n"
    var off = "proc segOffsetof(name, field: cstring): int64 {.exportc: \"seg_offsetof\", " &
      "dynlib, cdecl, raises: [].} =\n  if name == nil or field == nil: return -1\n" &
      "  case $name & \".\" & $field\n"
    for m in b.mirrors:
      sz.add "  of \"" & m.cName & "\": sizeof(" & m.mirror & ")\n"
      if m.nim == "Slice[int]":
        for f in ["a", "b"]:
          off.add "  of \"SegSlice." & f & "\": int64(offsetOf(MSegSlice, " & f & "))\n"
      for f in m.fields:
        off.add "  of \"" & m.cName & "." & f.c & "\": int64(offsetOf(" & m.mirror & ", " & f.nim &
          "))\n"
    sz.add "  of \"SegValue\": sizeof(SegValue)\n  else: -1\n"
    for (n, c) in [("kind", "kind"), ("i", "i"), ("f", "f"), ("text", "text"),
        ("textCap", "text_cap"), ("textLen", "text_len")]:
      off.add "  of \"SegValue." & c & "\": int64(offsetOf(SegValue, " & n & "))\n"
    off.add "  else: -1\n"
    b.text.hFns.add "\n/* Nim's size of a struct shared with C, for layout tests; " &
      "-1 if unknown. */\n" & "int64_t seg_sizeof(const char *type_name);\n" &
      "/* Nim's offset of a struct field (C field names); -1 if unknown. */\n" &
      "int64_t seg_offsetof(const char *type_name, const char *field_name);\n"
    b.text.pyDecls.add "_lib.seg_sizeof.argtypes = [ctypes.c_char_p]\n" &
      "_lib.seg_sizeof.restype = ctypes.c_int64\n"
    generated = move b.text
    result.add parseStmt(b.mirrorCode)
    result.add parseStmt(code & sz & off)
    result.add parseStmt("static:\n" & b.staticCode & "  writeBindings(" & $abiVersion & ", " &
      moduleDoc.escape & ")\n")
