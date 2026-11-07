## The library's foreign boundary from one declaration (task 12.2).
##
## Every function of the C ABI and of the Python module is an ordinary Nim
## proc in `abi/api.nim` carrying `{.segApi.}`. Under `-d:segCapi` the pragma
## generates, from the proc's resolved signature:
##
## - a C export (`exportc, dynlib, cdecl`, `raises: []`) that converts the
##   arguments, serializes calls on the handle (unless `concurrent`), maps
##   every exception to a `SegStatus` and `seg_last_error`, and writes the
##   results through trailing out-pointers;
## - its declaration and documentation in `include/parseseg.h`;
## - a Python (ctypes) function or method in `python/parseseg/__init__.py`
##   with the Nim parameter names in snake_case, the Nim defaults, and the
##   status mapped to an exception.
##
## Without `-d:segCapi` the pragma leaves the proc unchanged, so plain Nim
## builds pay nothing.
##
## Pragma forms: `{.segApi.}`, `{.segApi(c = "seg_x", py = "x").}`, plus the
## flags `concurrent` (no handle lock: calls on one handle may overlap) and
## `ctor` (a handle result becomes the Python class constructor). Default
## names: `seg_<handle>_<snake name>` for a method (first parameter a
## handle), else `seg_<snake name>`; Python: the snake_case name.
##
## C mapping (Nim → parameter / result):
##
## =====================  =================================  ==================================
## Nim                    Parameter                          Result (trailing out-pointer)
## =====================  =================================  ==================================
## `int`, `int64`         `int64_t`                          `int64_t *out`
## `int32`                `int32_t`                          `int32_t *out`
## `float64`              `double`                           `double *out`
## `bool`                 `bool`                             `bool *out`
## enum                   `int32_t` (checked)                `int32_t *out`
## `string`               `const char *` (NULL = default)    `char *out, int64_t out_cap,
##                                                            int64_t *out_len`
## handle                 `SegX *` (not NULL)                `SegX **out` (owned)
## `openArray[int64]`     `const int64_t *x, int64_t x_len`
## object                 `const SegX *` (NULL = default)    `SegX *out`
## `seq[T]`                                                  `T *out, int64_t out_cap,
##                                                            int64_t *out_len`
## `DiagLog`                                                 `SegLog **out` (owned)
## `FieldValue`           `const SegValue *`                 `SegValue *out`
## `pointer`                                                 `void **out`
## =====================  =================================  ==================================
##
## Out-pointers may be NULL (the result is dropped). Text and sequences are
## copied into the caller's buffer: at most `out_cap` bytes or elements,
## `*out_len` the full length, so a too-small buffer is detected and the call
## repeated. A `LoggedError` still hands its log out through a `DiagLog`
## result before failing.

import std/[macros, strutils, tables, locks, math, os]
import ../common/[errors, diagnostics]
import ../model/headerfields

export locks, errors, diagnostics

const
  SEG_OK* = 0'i32
  SEG_END* = 1'i32
  SEG_NOT_READY* = 2'i32
  SEG_ERR_ARGUMENT* = -1'i32
  SEG_ERR_IO* = -2'i32
  SEG_ERR_FORMAT* = -3'i32
  SEG_ERR_STATE* = -4'i32
  SEG_ERR_REFUSED* = -5'i32
  SEG_ERR_INTERNAL* = -6'i32
  SEG_ERR_MEMORY* = -7'i32

  SEG_VALUE_INT = 1'i32
  SEG_VALUE_FLOAT = 2'i32
  SEG_VALUE_TEXT = 3'i32

type
  SegStatus* = int32

  AbiHandle* = ref object of RootObj
    ## Base of every object that crosses the boundary as a handle. The lock
    ## serializes calls on one handle (see `concurrent`).
    lock: Lock
    lockReady: bool

  LogObj* = ref object of AbiHandle
    ## A list of diagnostics handed to the host.
    log*: DiagLog

  AbiStateError* = object of CatchableError
    ## The handle is not in a state that allows the call (e.g. no keys).
  AbiRefusedError* = object of CatchableError
    ## An edit was refused; the editor's log says why.
  AbiMemoryError* = object of CatchableError
    ## The system refused a buffer.
  AbiEnd* = object of CatchableError
    ## `SEG_END`: nothing more to deliver (Python: `None`).
  AbiNotReady* = object of CatchableError
    ## `SEG_NOT_READY`: try again later (Python: `None`).
  LoggedError* = object of CatchableError
    ## A failure whose diagnostics go to the caller with it.
    status*: SegStatus
    log*: DiagLog

  SegValue* {.bycopy.} = object
    ## A header field value. For text the caller provides `text`/`textCap`;
    ## the library copies the value there and sets `textLen`.
    kind*: int32
    pad: int32
    i*: int64
    f*: float64
    text*: ptr UncheckedArray[char]
    textCap*: int64
    textLen*: int64

proc raiseLogged*(status: SegStatus, msg: string, log: DiagLog) {.noinline, noreturn.} =
  ## Fails with `status`, handing `log` to the caller.
  var e = newException(LoggedError, msg)
  e.status = status
  e.log = log
  raise e

func snake*(s: string): string =
  ## `srcLine` -> `src_line` (also strips backticks).
  for i, c in s:
    if c == '`': continue
    if c.isUpperAscii:
      if i > 0 and result.len > 0 and result[^1] != '_': result.add '_'
      result.add c.toLowerAscii
    else: result.add c

# ------------------------------------------------------- runtime (C side) --

const LastErrorCap = 1024

var lastErrorBuf {.threadvar.}: array[LastErrorCap, char]
  # A plain thread-local array: threads the host created never run Nim
  # threadvar destructors, so a `string` here would leak on every thread exit.

proc setLastError*(msg: string) =
  let n = min(msg.len, LastErrorCap - 1)
  if n > 0: copyMem(addr lastErrorBuf[0], unsafeAddr msg[0], n)
  lastErrorBuf[n] = '\0'

proc lastErrorPtr*(): cstring = cast[cstring](addr lastErrorBuf[0])

proc fail(code: SegStatus, msg: string): SegStatus =
  setLastError(msg)
  code

proc keep*[T: AbiHandle](h: T): pointer =
  ## A counted reference for the host (released by `seg_<x>_release`).
  if h == nil: return nil
  if not h.lockReady:
    initLock(h.lock)
    h.lockReady = true
  GC_ref(h)
  cast[pointer](h)

template segGuard*(logOut: untyped, body: untyped): SegStatus =
  ## Runs `body` with every exception mapped to a status and `lastError`.
  var st = SEG_OK
  lastErrorBuf[0] = '\0'
  try:
    body
  except LoggedError as e:
    when logOut isnot typeof(nil):
      if logOut != nil: logOut[] = keep(LogObj(log: e.log))
    st = fail(e.status, e.msg)
  except AbiEnd: st = SEG_END
  except AbiNotReady: st = SEG_NOT_READY
  except SegTruncatedError as e: st = fail(SEG_ERR_FORMAT, "truncated: " & e.msg)
  except SegFormatError as e: st = fail(SEG_ERR_FORMAT, e.msg)
  except IOError as e: st = fail(SEG_ERR_IO, e.msg)
  except OSError as e: st = fail(SEG_ERR_IO, e.msg)
  except ValueError as e: st = fail(SEG_ERR_ARGUMENT, e.msg)
  except AbiStateError as e: st = fail(SEG_ERR_STATE, e.msg)
  except AbiRefusedError as e: st = fail(SEG_ERR_REFUSED, e.msg)
  except AbiMemoryError as e: st = fail(SEG_ERR_MEMORY, e.msg)
  except Exception as e: st = fail(SEG_ERR_INTERNAL, $e.name & ": " & e.msg)
  st

template withHandle*(h: AbiHandle, body: untyped) =
  acquire(h.lock)
  try:
    body
  finally:
    release(h.lock)

proc argError(msg: string) {.noinline, noreturn.} =
  raise newException(ValueError, msg)

proc handleArg*[T: AbiHandle](p: pointer, name: string): T =
  if p == nil: argError(name & " must not be NULL")
  cast[T](p)

proc stringArg*(p: cstring, name: string): string =
  if p == nil: argError(name & " must not be NULL")
  $p

proc stringArg*(p: cstring, default: string, name: string): string =
  if p == nil: default else: $p

proc enumArg*[E: enum](v: int32, name: string): E =
  for e in E:
    if ord(e) == int(v): return e
  argError(name & ": no such value " & $v)

proc validEnum[E: enum](v: E): bool =
  for e in E:
    if ord(e) == ord(v): return true
  false

proc structArg*[T: object](p: ptr T, name: string): T =
  ## The caller's struct (NULL: the default), with every enum field checked:
  ## C can put any integer there.
  if p == nil: return T()
  result = p[]
  for fname, f in fieldPairs(result):
    when f is enum:
      if not validEnum(f): argError(name & "." & snake(fname) & ": no such value " & $ord(f))

var emptyIds: array[1, int64]

proc idsArg*(p: ptr UncheckedArray[int64], n: int64, name: string): ptr UncheckedArray[int64] =
  if n < 0 or (n > 0 and p == nil): argError(name & ": NULL list or negative length")
  if p == nil: cast[ptr UncheckedArray[int64]](addr emptyIds[0]) else: p

proc valueArg*(p: ptr SegValue, name: string): FieldValue =
  if p == nil: argError(name & " must not be NULL")
  case p.kind
  of SEG_VALUE_INT: FieldValue(kind: fvInt, i: p.i)
  of SEG_VALUE_FLOAT: FieldValue(kind: fvFloat, f: p.f)
  of SEG_VALUE_TEXT:
    if p.text == nil: argError(name & ": NULL text")
    FieldValue(kind: fvText, s: $cast[cstring](p.text))
  else: argError(name & ": bad SegValue kind " & $p.kind)

proc copyText(s: string, buf: ptr UncheckedArray[char], cap: int64) =
  # At most cap - 1 bytes, always NUL-terminated when cap > 0.
  if buf != nil and cap > 0:
    let n = min(int64(s.len), cap - 1)
    if n > 0: copyMem(addr buf[0], unsafeAddr s[0], n)
    buf[n] = '\0'

proc writeText*(s: string, buf: ptr UncheckedArray[char], cap: int64, outLen: ptr int64) =
  if cap < 0: argError("out_cap must be >= 0")
  copyText(s, buf, cap)
  if outLen != nil: outLen[] = int64(s.len)

proc writeStruct*[T: object](dst: ptr T, v: T) =
  ## Copies `v` to C memory; its `ref` fields (handles) become owned by C.
  if dst == nil: return
  copyMem(dst, unsafeAddr v, sizeof(T))
  for f in fields(v):
    when f is AbiHandle: discard keep(f)

proc writeSeq*[T](s: seq[T], buf: ptr UncheckedArray[T], cap: int64, outLen: ptr int64) =
  if cap < 0: argError("out_cap must be >= 0")
  if buf != nil:
    for i in 0 ..< min(int64(s.len), cap):
      when T is object: writeStruct(addr buf[i], s[i])
      else: buf[i] = s[i]
  if outLen != nil: outLen[] = int64(s.len)

proc writeValue*(dst: ptr SegValue, v: FieldValue) =
  if dst == nil: return
  case v.kind
  of fvInt:
    dst.kind = SEG_VALUE_INT
    dst.i = v.i
    dst.f = float64(v.i)
  of fvFloat:
    dst.kind = SEG_VALUE_FLOAT
    dst.i = 0
    dst.f = v.f
  of fvText:
    dst.kind = SEG_VALUE_TEXT
    if dst.textCap < 0: argError("SegValue.text_cap must be >= 0")
    copyText(v.s, dst.text, dst.textCap)
    dst.textLen = int64(v.s.len)

# ------------------------------------------------- compile-time registry --

type
  HandleInfo = object
    nim, c, py, short, doc: string

  StructInfo = object
    nim, c: string
    fields: seq[(string, string)] ## Nim field name, C field name

var
  handles {.compileTime.}: seq[HandleInfo]
  structNames {.compileTime.}: Table[string, string] ## Nim name -> C name
  structs {.compileTime.}: seq[StructInfo]
  enumPrefixes {.compileTime.}: Table[string, string]
  enumsDone {.compileTime.}: seq[string]
  hEnums {.compileTime.}: string
  hHandles {.compileTime.}: string
  hStructs {.compileTime.}: string
  hFns {.compileTime.}: string
  pyEnums {.compileTime.}: string
  pyStructs {.compileTime.}: string
  pyDecls {.compileTime.}: string
  pyFns {.compileTime.}: string
  pyMethods {.compileTime.}: Table[string, string]
  cSymbols {.compileTime.}: seq[string]
  typeDocs {.compileTime.}: Table[string, string]   ## Nim type -> its doc
  fieldDocs {.compileTime.}: Table[string, string]  ## "Type.field" -> its doc

func upperSnake(s: string): string = snake(s).toUpperAscii.replace('-', '_').replace('.', '_')

proc handleOf(nimName: string): int {.compileTime.} =
  for i, h in handles:
    if h.nim == nimName: return i
  -1

proc cStructName(nimName: string): string {.compileTime.} =
  structNames.getOrDefault(nimName, "Seg" & nimName)

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

macro segHandle*(T: typedesc, c, py: static string, doc: static string = ""): untyped =
  ## Registers handle type `T` as the C type `c` and the Python class `py`, and
  ## generates `seg_<x>_release`.
  let nimName = T.repr
  let short = snake(c.replace("Seg", ""))
  handles.add HandleInfo(nim: nimName, c: c, py: py, short: short, doc: doc)
  hHandles.add "typedef struct " & c & " " & c & ";" &
    (if doc.len > 0: " /* " & doc & " */" else: "") & "\n"
  let rel = "seg_" & short & "_release"
  hFns.add "\n/* Releases the handle (NULL is a no-op). */\nvoid " & rel & "(" & c & " *handle);\n"
  pyDecls.add "_lib." & rel & ".argtypes = [ctypes.c_void_p]\n_lib." & rel & ".restype = None\n"
  cSymbols.add rel
  result = newStmtList()
  when defined(segCapi):
    result.add parseStmt("""
proc segRelease$1(h: pointer) {.exportc: "$2", dynlib, cdecl, raises: [].} =
  try:
    if h != nil: GC_unref(cast[$3](h))
  except Exception: discard
""" % [short.replace("_", ""), rel, nimName])

macro segStruct*(T: typedesc, c: static string): untyped =
  ## Names the C struct of object `T` (default `Seg` & its Nim name).
  structNames[T.repr] = c
  newEmptyNode()

macro segLayout*(T: typedesc, c: static string, fields: static openArray[(string, string)]): untyped =
  ## Adds a struct declared by hand (in the header preamble) to the layout
  ## checks (`seg_sizeof` / `seg_offsetof`): Nim field name, C field name.
  structs.add StructInfo(nim: T.repr, c: c, fields: @fields)
  newEmptyNode()

macro segEnum*(T: typedesc, prefix: static string): untyped =
  ## The `#define` prefix of enum `T`'s values (default `SEG_` & its name).
  enumPrefixes[T.repr] = prefix
  newEmptyNode()

proc collectDocs(t: NimNode) =
  ## Reads the doc comments of object type `t` from its source (the lines of
  ## its declaration), for the header: `##` lines right after `= object` are
  ## the type's, a field's trailing and continuation `##` lines are the field's.
  let name = t.repr
  if name in typeDocs: return
  typeDocs[name] = ""
  let impl = t.getImpl
  if impl.kind != nnkTypeDef: return
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
    if line.len == 0: continue
    let at = line.find("##")
    let code = (if at >= 0: line[0 ..< at] else: line).strip
    let doc = if at >= 0: line[at + 2 .. ^1].strip else: ""
    if code.len == 0:
      if doc.len == 0: continue
      if head: typeDocs[name] = (typeDocs[name] & " " & doc).strip
      else:
        for f in cur: fieldDocs[name & "." & f] = (fieldDocs.getOrDefault(name & "." & f) &
          " " & doc).strip
    elif ':' in code:
      head = false
      cur = @[]
      for f in code[0 ..< code.find(':')].split(','):
        cur.add f.strip.strip(chars = {'*', '`'})
      if doc.len > 0:
        for f in cur: fieldDocs[name & "." & f] = doc

# Compile-time registration of enums and structs, run in `static:` blocks the
# wrappers emit, so Nim itself evaluates `$`, `ord`, `sizeof` and fields.

proc registerEnum*[E: enum](t: typedesc[E]) {.compileTime.} =
  let name = $E
  if name in enumsDone: return
  enumsDone.add name
  let prefix = enumPrefixes.getOrDefault(name, "SEG_" & upperSnake(name))
  hEnums.add "\n/* " & name & " */\n"
  var fwd = "_E_" & name & " = {"
  var back = "_N_" & name & " = {"
  for e in E:
    hEnums.add "#define " & prefix & "_" & upperSnake($e) & " " & $ord(e) & "\n"
    fwd.add "\"" & $e & "\": " & $ord(e) & ", "
    back.add $ord(e) & ": \"" & $e & "\", "
  pyEnums.add fwd & "}\n" & back & "}\n"

type FieldType = tuple[c, py, conv: string]
  ## C declaration with `$1` for the name, ctypes type, Python conversion
  ## (`$1` = the value) for struct-to-dict.

proc fieldType[T](v: T): FieldType {.compileTime.} =
  when T is enum:
    registerEnum(T)
    const sz = sizeof(T)
    let ct = case sz
      of 1: ("uint8_t", "ctypes.c_uint8")
      of 2: ("uint16_t", "ctypes.c_uint16")
      else: ("int32_t", "ctypes.c_int32")
    (ct[0] & " $1", ct[1], "_N_" & $T & ".get($1, $1)")
  elif T is bool: ("bool $1", "ctypes.c_bool", "$1")
  elif T is int8: ("int8_t $1", "ctypes.c_int8", "$1")
  elif T is uint8: ("uint8_t $1", "ctypes.c_uint8", "$1")
  elif T is int16: ("int16_t $1", "ctypes.c_int16", "$1")
  elif T is uint16: ("uint16_t $1", "ctypes.c_uint16", "$1")
  elif T is int32: ("int32_t $1", "ctypes.c_int32", "$1")
  elif T is uint32: ("uint32_t $1", "ctypes.c_uint32", "$1")
  elif T is int64 or T is int: ("int64_t $1", "ctypes.c_int64", "$1")
  elif T is uint64: ("uint64_t $1", "ctypes.c_uint64", "$1")
  elif T is float32: ("float $1", "ctypes.c_float", "$1")
  elif T is float64: ("double $1", "ctypes.c_double", "$1")
  elif T is cstring: ("const char *$1", "ctypes.c_char_p", "_dec($1)")
  elif T is pointer: ("void *$1", "ctypes.c_void_p", "$1")
  elif T is array:
    var e: typeof(v[low(v)])
    let inner = fieldType(e)
    (inner.c & "[" & $len(v) & "]", "(" & inner.py & " * " & $len(v) & ")",
      "[" & inner.conv.replace("$1", "_x") & " for _x in $1]")
  elif T is AbiHandle:
    let i = handleOf($T)
    doAssert i >= 0, $T & " is not a registered handle"
    (handles[i].c & " *$1", "ctypes.c_void_p", "_wrap(" & handles[i].py & ", $1)")
  else:
    {.error: "segApi: unsupported struct field type " & $T.}

proc registerStruct*[T: object](t: typedesc[T]) {.compileTime.} =
  let nimName = $T
  for s in structs:
    if s.nim == nimName: return
  let c = cStructName(nimName)
  var info = StructInfo(nim: nimName, c: c)
  var body = ""
  var pyFields = ""
  var conv = ""
  var v: T
  for name, f in fieldPairs(v):
    let ft = fieldType(f)
    let cn = snake(name)
    info.fields.add (name, cn)
    let fd = fieldDocs.getOrDefault(nimName & "." & name)
    body.add "    " & ft.c.replace("$1", cn) & ";" & (if fd.len > 0: " /* " & fd & " */" else: "") &
      "\n"
    pyFields.add "        (\"" & cn & "\", " & ft.py & "),\n"
    conv.add "(\"" & cn & "\", lambda _v: " & ft.conv.replace("$1", "_v") & "), "
  structs.add info
  hStructs.add "\n" & cComment(typeDocs.getOrDefault(nimName), "") & "typedef struct " & c &
    " {\n" & body & "} " & c & ";\n"
  pyStructs.add "\nclass " & c & "(ctypes.Structure):\n    _fields_ = [\n" & pyFields &
    "    ]\n    _conv = [" & conv & "]\n"

proc pyLit*(v: SomeInteger): string {.compileTime.} = $v
proc pyLit*(v: bool): string {.compileTime.} = (if v: "True" else: "False")
proc pyLit*(v: SomeFloat): string {.compileTime.} =
  if v.isNaN: "float(\"nan\")"
  elif v == Inf: "float(\"inf\")"
  elif v == -Inf: "float(\"-inf\")"
  else: $v
proc pyLit*(v: string): string {.compileTime.} = "\"" & v.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
proc pyLit*[E: enum](v: E): string {.compileTime.} = "\"" & $v & "\""

proc addPy*(class, text: string, defaults: varargs[string]) {.compileTime.} =
  ## Adds generated Python text, filling the default placeholders.
  var t = text
  for i, d in defaults: t = t.replace("\x01" & $i & "\x01", d)
  if class.len == 0: pyFns.add t
  else: pyMethods.mgetOrPut(class, "").add t

proc addDecl*(text: string) {.compileTime.} = pyDecls.add text

# ------------------------------------------------------------ the pragma --

type
  ArgKind = enum
    akInt64, akInt32, akFloat, akBool, akEnum, akString, akHandle, akIds, akStruct,
    akSeq, akLog, akValue, akPointer

proc classify(t: NimNode, what: string): ArgKind =
  let name = t.repr
  if handleOf(name) >= 0: return akHandle
  case name
  of "DiagLog": return akLog
  of "FieldValue", "EditValue": return akValue
  of "string": return akString
  of "pointer": return akPointer
  else: discard
  case t.getType.typeKind
  of ntyBool: akBool
  of ntyInt, ntyInt64: akInt64
  of ntyInt32: akInt32
  of ntyFloat, ntyFloat64: akFloat
  of ntyEnum: akEnum
  of ntyObject: akStruct
  of ntySequence: akSeq
  of ntyOpenArray:
    if t[1].repr != "int64": error("segApi: only openArray[int64] is supported (" & what & ")", t)
    akIds
  else:
    error("segApi: unsupported type " & name & " (" & what & ")", t)

macro segGen*(sig: typed, nimName, cName0, pyName0, doc: static string,
    concurrent, ctor: static bool): untyped =
  let fp = sig.params
  type Arg = object
    name: string
    typ: NimNode
    kind: ArgKind
    default: NimNode
  var args: seq[Arg]
  for i in 1 ..< fp.len:
    for id in fp[i][0 ..^ 3]:
      let t = id.getTypeInst
      args.add Arg(name: id.repr.strip(chars = {'`'}), typ: t,
        kind: classify(t, id.repr), default: fp[i][^1])
  let ret = fp[0]
  let retKind = if ret.kind == nnkEmpty: akPointer else: classify(ret, "result")
  let hasRet = ret.kind != nnkEmpty
  let isMethod = args.len > 0 and args[0].kind == akHandle
  let h = if isMethod: handles[handleOf(args[0].typ.repr)] else: HandleInfo()
  let cName = if cName0.len > 0: cName0
              elif isMethod: "seg_" & h.short & "_" & snake(nimName)
              else: "seg_" & snake(nimName)
  var pyName = if pyName0.len > 0: pyName0 else: snake(nimName)
  if isMethod and pyName == "close": pyName = "_close_native"
  let pyClass = if isMethod: h.py else: ""

  var cParams: seq[string]   # Nim wrapper params
  var hParams: seq[string]   # header params
  var pyArgTypes: seq[string]
  var convs = ""             # Nim conversion statements
  var callArgs: seq[string]
  var pyParams: seq[string]
  var pyCall: seq[string]
  var defaults: seq[NimNode]
  var statics = ""           # static registration calls
  for k, a in args:
    let p = "a" & $k
    let v = "v" & $k
    let cn = snake(a.name)
    let tn = a.typ.repr
    let pyn = if k == 0 and isMethod: "self" else: cn
    if not (k == 0 and isMethod):
      if a.default.kind != nnkEmpty:
        pyParams.add pyn & "=\x01" & $defaults.len & "\x01"
        defaults.add a.default
      else:
        pyParams.add pyn
    case a.kind
    of akInt64:
      cParams.add p & ": int64"
      hParams.add "int64_t " & cn
      pyArgTypes.add "ctypes.c_int64"
      convs.add "    let " & v & " = " & (if tn == "int": "int(" & p & ")" else: p) & "\n"
      pyCall.add "_i64(" & pyn & ", \"" & cn & "\")"
    of akInt32:
      cParams.add p & ": int32"
      hParams.add "int32_t " & cn
      pyArgTypes.add "ctypes.c_int32"
      convs.add "    let " & v & " = " & p & "\n"
      pyCall.add "_i32(" & pyn & ", \"" & cn & "\")"
    of akFloat:
      cParams.add p & ": float64"
      hParams.add "double " & cn
      pyArgTypes.add "ctypes.c_double"
      convs.add "    let " & v & " = " & p & "\n"
      pyCall.add "_f64(" & pyn & ", \"" & cn & "\")"
    of akBool:
      cParams.add p & ": bool"
      hParams.add "bool " & cn
      pyArgTypes.add "ctypes.c_bool"
      convs.add "    let " & v & " = " & p & "\n"
      pyCall.add "bool(" & pyn & ")"
    of akEnum:
      cParams.add p & ": int32"
      hParams.add "int32_t " & cn
      pyArgTypes.add "ctypes.c_int32"
      convs.add "    let " & v & " = enumArg[" & tn & "](" & p & ", \"" & cn & "\")\n"
      statics.add "  registerEnum(" & tn & ")\n"
      pyCall.add "_enum(_E_" & tn & ", " & pyn & ", \"" & cn & "\")"
    of akString:
      cParams.add p & ": cstring"
      hParams.add "const char *" & cn
      pyArgTypes.add "ctypes.c_char_p"
      if a.default.kind != nnkEmpty:
        convs.add "    let " & v & " = stringArg(" & p & ", " & a.default.repr & ", \"" & cn & "\")\n"
      else:
        convs.add "    let " & v & " = stringArg(" & p & ", \"" & cn & "\")\n"
      pyCall.add "_str(" & pyn & ", \"" & cn & "\")"
    of akHandle:
      let hi = handles[handleOf(tn)]
      cParams.add p & ": pointer"
      hParams.add hi.c & " *" & (if k == 0 and isMethod: hi.short else: cn)
      pyArgTypes.add "ctypes.c_void_p"
      convs.add "    let " & v & " = handleArg[" & tn & "](" & p & ", \"" &
        (if k == 0 and isMethod: hi.short else: cn) & "\")\n"
      pyCall.add(if k == 0 and isMethod: "_h"
                 else: "_handle(" & pyn & ", " & hi.py & ", \"" & cn & "\")")
    of akIds:
      cParams.add p & ": ptr UncheckedArray[int64]"
      cParams.add p & "n: int64"
      hParams.add "const int64_t *" & cn
      hParams.add "int64_t " & cn & "_len"
      pyArgTypes.add "ctypes.POINTER(ctypes.c_int64)"
      pyArgTypes.add "ctypes.c_int64"
      convs.add "    let " & v & "p = idsArg(" & p & ", " & p & "n, \"" & cn & "\")\n"
      pyCall.add "*_ids(" & pyn & ", \"" & cn & "\")"
    of akStruct:
      let sc = cStructName(tn)
      cParams.add p & ": ptr " & tn
      hParams.add "const " & sc & " *" & cn
      pyArgTypes.add "ctypes.POINTER(" & sc & ")"
      convs.add "    let " & v & " = structArg(" & p & ", \"" & cn & "\")\n"
      statics.add "  registerStruct(" & tn & ")\n"
      collectDocs(a.typ)
      pyCall.add "ctypes.byref(_struct_arg(" & sc & ", " & pyn & ", \"" & cn & "\"))"
    of akValue:
      cParams.add p & ": ptr SegValue"
      hParams.add "const SegValue *" & cn
      pyArgTypes.add "ctypes.POINTER(SegValue)"
      convs.add "    let " & v & " = valueArg(" & p & ", \"" & cn & "\")\n"
      pyCall.add "ctypes.byref(_value_in(" & pyn & ", \"" & cn & "\"))"
    else:
      error("segApi: unsupported parameter type " & tn, a.typ)
    if a.kind == akIds:
      callArgs.add "toOpenArray(" & v & "p, 0, int(" & p & "n) - 1)"
    else:
      callArgs.add v

  # The result.
  var write = ""
  var logOut = "nil"
  var pyPre = ""
  var pyPost = ""
  var pyRetCall = ""   # how the call is made: "plain", "text", "seq", "log"
  let rt = if hasRet: ret.repr else: ""
  if hasRet:
    case retKind
    of akInt64, akInt32, akFloat, akBool, akPointer:
      let (nt, ct, pt) = case retKind
        of akInt64: ((if rt == "int": "int64" else: "int64"), "int64_t", "ctypes.c_int64")
        of akInt32: ("int32", "int32_t", "ctypes.c_int32")
        of akFloat: ("float64", "double", "ctypes.c_double")
        of akBool: ("bool", "bool", "ctypes.c_bool")
        else: ("pointer", "void *", "ctypes.c_void_p")
      cParams.add "o: ptr " & nt
      hParams.add ct & " *out"
      pyArgTypes.add "ctypes.POINTER(" & pt & ")"
      write = "      if o != nil: o[] = " & nt & "(r)\n"
      pyPre = "        _o = " & pt & "()\n"
      pyCall.add "ctypes.byref(_o)"
      pyPost = "        return _o.value\n"
    of akEnum:
      cParams.add "o: ptr int32"
      hParams.add "int32_t *out"
      pyArgTypes.add "ctypes.POINTER(ctypes.c_int32)"
      write = "      if o != nil: o[] = int32(ord(r))\n"
      statics.add "  registerEnum(" & rt & ")\n"
      pyPre = "        _o = ctypes.c_int32()\n"
      pyCall.add "ctypes.byref(_o)"
      pyPost = "        return _N_" & rt & "[_o.value]\n"
    of akString:
      cParams.add "o: ptr UncheckedArray[char]"
      cParams.add "ocap: int64"
      cParams.add "olen: ptr int64"
      hParams.add "char *out"
      hParams.add "int64_t out_cap"
      hParams.add "int64_t *out_len"
      pyArgTypes.add "ctypes.c_char_p"
      pyArgTypes.add "ctypes.c_int64"
      pyArgTypes.add "ctypes.POINTER(ctypes.c_int64)"
      write = "      writeText(r, o, ocap, olen)\n"
      pyRetCall = "text"
    of akSeq:
      let et = ret[1]
      let ek = classify(et, "result element")
      var ctn, pyt, conv: string
      case ek
      of akInt64:
        (ctn, pyt, conv) = ("int64_t", "ctypes.c_int64", "lambda _v: _v")
      of akFloat:
        (ctn, pyt, conv) = ("double", "ctypes.c_double", "lambda _v: _v")
      of akStruct:
        ctn = cStructName(et.repr)
        pyt = ctn
        conv = "_struct_dict"
        statics.add "  registerStruct(" & et.repr & ")\n"
        collectDocs(et)
      else: error("segApi: unsupported sequence element " & et.repr, et)
      cParams.add "o: ptr UncheckedArray[" & et.repr & "]"
      cParams.add "ocap: int64"
      cParams.add "olen: ptr int64"
      hParams.add ctn & " *out"
      hParams.add "int64_t out_cap"
      hParams.add "int64_t *out_len"
      pyArgTypes.add "ctypes.POINTER(" & pyt & ")"
      pyArgTypes.add "ctypes.c_int64"
      pyArgTypes.add "ctypes.POINTER(ctypes.c_int64)"
      write = "      writeSeq(r, o, ocap, olen)\n"
      pyRetCall = "seq\x02" & pyt & "\x02" & conv
    of akStruct:
      let sc = cStructName(rt)
      cParams.add "o: ptr " & rt
      hParams.add sc & " *out"
      pyArgTypes.add "ctypes.POINTER(" & sc & ")"
      write = "      writeStruct(o, r)\n"
      statics.add "  registerStruct(" & rt & ")\n"
      collectDocs(ret)
      pyPre = "        _o = " & sc & "()\n"
      pyCall.add "ctypes.byref(_o)"
      pyPost = "        return _struct_dict(_o)\n"
    of akHandle:
      let hi = handles[handleOf(rt)]
      cParams.add "o: ptr pointer"
      hParams.add hi.c & " **out"
      pyArgTypes.add "ctypes.POINTER(ctypes.c_void_p)"
      write = "      if o != nil: o[] = keep(r)\n"
      pyPre = "        _o = ctypes.c_void_p()\n"
      pyCall.add "ctypes.byref(_o)"
      pyPost = (if ctor: "        self._h = _o.value\n        self._mu = threading.Lock()\n"
                else: "        return _wrap(" & hi.py & ", _o.value)\n")
    of akLog:
      cParams.add "o: ptr pointer"
      hParams.add "SegLog **out"
      pyArgTypes.add "ctypes.POINTER(ctypes.c_void_p)"
      write = "      if o != nil: o[] = keep(LogObj(log: r))\n"
      logOut = "o"
      pyRetCall = "log"
    of akValue:
      cParams.add "o: ptr SegValue"
      hParams.add "SegValue *out"
      pyArgTypes.add "ctypes.POINTER(SegValue)"
      write = "      writeValue(o, r)\n"
      pyRetCall = "value"
    else:
      error("segApi: unsupported result type " & rt, ret)

  # The C wrapper.
  let call = nimName & "(" & callArgs.join(", ") & ")"
  let lockIt = isMethod and not concurrent
  let ind = if lockIt: "      " else: "    "
  var body = ""
  if hasRet and retKind in {akHandle, akLog, akPointer}:
    body.add "    if o != nil: o[] = nil\n"
  body.add convs
  if lockIt: body.add "    withHandle(v0):\n"
  if hasRet:
    body.add ind & "let r = " & call & "\n"
    for l in write.strip.splitLines: body.add ind & l.strip & "\n"
  else:
    body.add ind & call & "\n"
  let wrapper = "proc segW_" & cName & "(" & cParams.join(", ") &
    "): int32 {.exportc: \"" & cName & "\", dynlib, cdecl, raises: [].} =\n" &
    "  segGuard(" & logOut & "):\n" & body
  result = newStmtList()
  if statics.len > 0: result.add parseStmt("static:\n" & statics)
  result.add parseStmt(wrapper)

  # The header declaration.
  cSymbols.add cName
  hFns.add "\n" & cComment(doc, "") & "SegStatus " & cName & "(" &
    (if hParams.len == 0: "void" else: hParams.join(", ")) & ");\n"

  # The Python function: body lines without indentation first.
  let inClass = isMethod or (ctor and retKind == akHandle)
  let cls = if isMethod: pyClass
            elif ctor and retKind == akHandle: handles[handleOf(rt)].py
            else: ""
  var sigParams = pyParams
  if inClass and not isMethod: sigParams.insert("self", 0)
  elif isMethod: sigParams.insert("self", 0)
  let defName = if ctor: "__init__" else: pyName
  let callArgsPy = "_lib." & cName & (if pyCall.len > 0: ", " & pyCall.join(", ") else: "")
  var lines: seq[string]
  case pyRetCall
  of "text":
    lines.add "return _text(lambda _b, _c, _n: _call(" & callArgsPy & ", _b, _c, _n))"
  of "log":
    lines.add "_o = ctypes.c_void_p()"
    lines.add "_st = _lib." & cName & "(" & (if pyCall.len > 0: pyCall.join(", ") & ", " else: "") &
      "ctypes.byref(_o))"
    lines.add "return _logged(_st, _o)"
  of "value":
    lines.add "_o = _value_out()"
    lines.add "_call(" & callArgsPy & ", ctypes.byref(_o))"
    lines.add "return _value(_o)"
  else:
    if pyRetCall.startsWith("seq\x02"):
      let parts = pyRetCall.split('\x02')
      lines.add "return _seq(lambda _b, _c, _n: _call(" & callArgsPy & ", _b, _c, _n), " &
        parts[1] & ", " & parts[2] & ")"
    else:
      for l in pyPre.strip.splitLines:
        if l.strip.len > 0: lines.add l.strip
      lines.add "if _call(" & callArgsPy & ") > 0:"
      lines.add "    return None"
      if pyPost.len > 0:
        for l in pyPost.strip.splitLines: lines.add l.strip
  let base = if inClass: "    " else: ""
  var py = "\n" & base & "def " & defName & "(" & sigParams.join(", ") & "):\n" &
    pyDoc(doc, base & "    ")
  if isMethod:
    py.add base & "    _h = self._enter()\n" & base & "    try:\n"
    for l in lines: py.add base & "        " & l & "\n"
    py.add base & "    finally:\n" & base & "        self._leave()\n"
  else:
    for l in lines: py.add base & "    " & l & "\n"
  var addCall = newCall(bindSym"addPy", newLit(cls), newLit(py))
  for d in defaults: addCall.add newCall(bindSym"pyLit", d)
  result.add newTree(nnkStaticStmt, newStmtList(addCall,
    newCall(bindSym"addDecl", newLit("_lib." & cName & ".argtypes = [" & pyArgTypes.join(", ") &
      "]\n_lib." & cName & ".restype = ctypes.c_int32\n"))))

macro segApi*(args: varargs[untyped]): untyped =
  ## Marks a boundary proc; see the module documentation.
  let prc = args[^1]
  expectKind(prc, {nnkProcDef, nnkFuncDef})
  when not defined(segCapi):
    result = prc
  else:
    var cName, pyName = ""
    var concurrent, ctor = false
    for a in args[0 ..^ 2]:
      case a.kind
      of nnkExprEqExpr, nnkExprColonExpr:
        case $a[0]
        of "c": cName = a[1].strVal
        of "py": pyName = a[1].strVal
        else: error("segApi: unknown option " & $a[0], a)
      of nnkIdent:
        case $a
        of "concurrent": concurrent = true
        of "ctor": ctor = true
        else: error("segApi: unknown flag " & $a, a)
      of nnkStrLit: cName = a.strVal
      else: error("segApi: unexpected argument", a)
    var doc = ""
    if prc.body.kind == nnkStmtList:
      for n in prc.body:
        if n.kind == nnkCommentStmt: doc.add (if doc.len > 0: "\n" else: "") & n.strVal
        else: break
    let sig = newNimNode(nnkLambda)
    sig.add newEmptyNode(), newEmptyNode(), newEmptyNode(), copyNimTree(prc.params),
      newEmptyNode(), newEmptyNode(),
      newStmtList(newNimNode(nnkDiscardStmt).add newEmptyNode())
    result = newStmtList(prc, newCall(bindSym"segGen", sig, newLit($prc.name), newLit(cName),
      newLit(pyName), newLit(doc), newLit(concurrent), newLit(ctor)))

# ------------------------------------------------------------- the output --

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
  result.add hEnums
  result.add "\n/* ---------------------------------------------------------- handles */\n\n"
  result.add hHandles
  result.add "\n/* ---------------------------------------------------------- structs */\n"
  result.add hStructs
  result.add "\n/* -------------------------------------------------------- functions */\n"
  result.add hFns
  result.add "\n#ifdef __cplusplus\n}\n#endif\n\n#endif /* PARSESEG_H */\n"

proc pythonText(abiVersion: int, moduleDoc: string): string {.compileTime.} =
  result = "# Generated by parseSEG's `segApi` (src/parseSEG/abi/segapi.nim); do not edit.\n" &
    pyDoc(moduleDoc, "") & PyRuntime.replace("@ABI_VERSION@", $abiVersion)
  result.add "\n# ------------------------------------------------------------ enums\n\n"
  result.add pyEnums
  result.add "\n# ---------------------------------------------------------- structs\n"
  result.add pyStructs
  result.add "\n# ----------------------------------------------------- declarations\n\n"
  result.add pyDecls
  result.add "\n# ----------------------------------------------------------- extras\n\n"
  result.add PyExtras
  result.add "\n# ---------------------------------------------------------- classes\n"
  for h in handles:
    let mixinCls = if ("class _" & h.py & "Extras") in PyExtras: ", _" & h.py & "Extras" else: ""
    result.add "\n\nclass " & h.py & "(_Handle" & mixinCls & "):\n" & pyDoc(h.doc, "    ") &
      "    _release = _lib.seg_" & h.short & "_release\n" & pyMethods.getOrDefault(h.py, "")
  result.add "\n# -------------------------------------------------------- functions\n\n"
  result.add pyFns

macro segFinish*(abiVersion: static int, moduleDoc: static string): untyped =
  ## Ends the boundary: emits `seg_sizeof` / `seg_offsetof` for every struct
  ## and, under `-d:segCapi`, writes the header and the Python package.
  result = newStmtList()
  when defined(segCapi):
    var sz = "proc segSizeof(name: cstring): int64 {.exportc: \"seg_sizeof\", dynlib, cdecl, raises: [].} =\n" &
      "  if name == nil: return -1\n  case $name\n"
    var off = "proc segOffsetof(name, field: cstring): int64 {.exportc: \"seg_offsetof\", dynlib, cdecl, raises: [].} =\n" &
      "  if name == nil or field == nil: return -1\n  case $name & \".\" & $field\n"
    for s in structs:
      sz.add "  of \"" & s.c & "\": sizeof(" & s.nim & ")\n"
      for (n, c) in s.fields:
        off.add "  of \"" & s.c & "." & c & "\": int64(offsetOf(" & s.nim & ", " & n & "))\n"
    sz.add "  of \"SegValue\": sizeof(SegValue)\n  else: -1\n"
    for (n, c) in [("kind", "kind"), ("i", "i"), ("f", "f"), ("text", "text"),
        ("textCap", "text_cap"), ("textLen", "text_len")]:
      off.add "  of \"SegValue." & c & "\": int64(offsetOf(SegValue, " & n & "))\n"
    off.add "  else: -1\n"
    result.add parseStmt(sz)
    result.add parseStmt(off)
    hFns.add "\n/* Nim's size of a struct shared with C, for layout tests; -1 if unknown. */\n" &
      "int64_t seg_sizeof(const char *type_name);\n" &
      "/* Nim's offset of a struct field (C field names); -1 if unknown. */\n" &
      "int64_t seg_offsetof(const char *type_name, const char *field_name);\n"
    pyDecls.add "_lib.seg_sizeof.argtypes = [ctypes.c_char_p]\n_lib.seg_sizeof.restype = ctypes.c_int64\n"
    # Joined with "/" by hand: at compile time `os./` uses the *target's*
    # separator, so a Windows cross build would write "\\..." file names.
    var root = currentSourcePath().replace('\\', '/')
    for _ in 1..4: root = root[0 ..< root.rfind('/')]
    let base = if segBindingsDir.len > 0: segBindingsDir.replace('\\', '/') else: root
    let hdir = base & "/include"
    let pdir = base & "/python/parseseg"
    writeFile(pdir & "/__init__.py", pythonText(abiVersion, moduleDoc))
