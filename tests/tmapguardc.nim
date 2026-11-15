## The `SIGBUS` handler of `private/mapguard` runs at any point of a read,
## so it must call nothing that is not async-signal-safe, in every build. A
## debug build gives each Nim proc a stack frame (thread-local writes, the
## call-depth check); `std/atomics`' procs are Nim procs. This compiles a
## program with parseSEG in a debug build and reads the C of the handler's
## functions: no frame, and no call but the ones listed. Seen failing with
## the handler on `std/atomics` (`load_u1`, `compareExchangeWeak_u0`, with
## `nimfr_`).

import std/[assertions, os, osproc, sets, strutils]

when not defined(posix):
  echo "tmapguardc: skipped: the guard is POSIX only"
  quit 0

const root = currentSourcePath().parentDir.parentDir

proc nimPaths(): string =
  ## The project's search paths, absolute.
  result = " --noNimblePath --path:" & quoteShell(root / "src")
  for line in readFile(root / "nim.cfg").splitLines:
    let s = line.strip
    if s.startsWith("--path:"):
      result.add " --path:" & quoteShell(root / s["--path:".len .. ^1].strip(chars = {'"'}))

let tmp = getTempDir() / "parseseg_tmapguardc"
removeDir(tmp)
createDir(tmp)
let main = tmp / "guardmain.nim"
writeFile(main, "import std/os\nimport parseSEG\nvar f = openSeismic(paramStr(1))\nf.close()\n")
let cache = tmp / "nimcache"
let (o, code) = execCmdEx(getCurrentCompilerExe().quoteShell & " c --compileOnly" &
  " --hints:off --warnings:off --skipParentCfg --skipUserCfg --stackTrace:on" &
  " --lineTrace:on --checks:on" & nimPaths() & " --nimcache:" & quoteShell(cache) & " " &
  quoteShell(main))
doAssert code == 0, o

var cFile = ""
for path in walkFiles(cache / "*mapguard.nim.c"): cFile = path
doAssert cFile.len > 0, "no C file for private/mapguard"

# Every function defined in the file: its name (before the `__` of the
# module suffix) and its body.
type Fn = tuple[name, body: string]
var fns: seq[Fn]
let lines = readFile(cFile).splitLines
var i = 0
while i < lines.len:
  let l = lines[i]
  if (l.startsWith("static N_INLINE(") or l.startsWith("N_LIB_PRIVATE N_")) and
      l.endsWith(") {"):
    # `N_NOCONV(void, onBus_u0__...)(int sig_p0, ...) {`
    let a = l.find(", ") + 2
    let name = l[a ..< l.find(')', a)]
    var body: seq[string]
    inc i
    while i < lines.len and lines[i] != "}":
      body.add lines[i]
      inc i
    fns.add (name, body.join("\n"))
  inc i

iterator callees(body: string): string =
  ## The names called in `body`: identifiers followed by `(`.
  var k = 0
  while k < body.len:
    if body[k] in IdentStartChars:
      let a = k
      while k < body.len and body[k] in IdentChars: inc k
      var j = k
      while j < body.len and body[j] == ' ': inc j
      if j < body.len and body[j] == '(': yield body[a ..< k]
    else: inc k

func isLocal(name: string): bool =
  ## A local of the generated C: the previous handler (`h_1`), a temporary (`T12_`).
  (name.len > 2 and name.startsWith("h_") and name[2 .. ^1].allCharsInSet(Digits)) or
    (name.len > 2 and name[0] == 'T' and name.endsWith("_") and
      name[1 .. ^2].allCharsInSet(Digits))

func short(name: string): string =
  ## `name` without the module suffix that follows its first inner `__`.
  let k = name.find("__", 1)
  if k < 0: name else: name[0 ..< k]

let handler = ["onBus", "chain", "lowerCut", "sentByTheKernel"]
let allowed = toHashSet(["__atomic_load_n", "__atomic_store_n", "__atomic_compare_exchange_n",
  "fstat", "mmap",
  "sigaction", "sigemptyset", "raise", "nimZeroMem", "nimErrorFlag", "NIM_UNLIKELY",
  "if", "while", "sizeof"])
var seen = 0
for f in fns:
  let n = f.name.short
  if n.split('_')[0] notin handler: continue
  inc seen
  doAssert "nimfr_" notin f.body and "nimFrame" notin f.body, n & " has a stack frame"
  for c in f.body.callees:
    let callee = c.short
    if callee.split('_')[0] in handler or callee in allowed or callee.isLocal: continue
    doAssert false, n & " calls " & callee
doAssert seen == handler.len, "found " & $seen & " of the handler's functions in " & cFile
echo "tmapguardc: ok"
