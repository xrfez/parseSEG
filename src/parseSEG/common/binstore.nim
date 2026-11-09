## A compact native binary snapshot of plain Nim values, for the index
## cache (`model/traceindex`): numbers, enums, strings, `seq`s, arrays,
## `Option`s, objects (variants included) and tuples. Not re-exported.
##
## Fixed-size scalars are stored as their native bytes, and `seq`s and
## arrays of plain-memory elements (`TraceEntry`, `TraceKeys`, bytes) as one
## block, so millions of entries cost a single copy each way. Objects are
## walked field by field (`fieldPairs`), so private fields come along and
## no type needs code of its own. The layout is native (byte order, sizes):
## a snapshot is read back only by the same build of the same layout, which
## `schemaOf` checks: it describes a type's whole structure (field names,
## types, enum members, sizes), so any change to a stored type changes it.
##
## Reading is bounds-checked and raises `SegFormatError` on a short or
## inconsistent snapshot; a reader checks the snapshot's checksum first, so
## the bytes it decodes are the ones written.

import std/[macros, options, typetraits]
import ./errors

type
  BinWriter* = object
    ## Writes a snapshot to a file through a buffer.
    f: File
    buf: seq[byte]
    written: int64

  BinReader* = object
    ## Reads a snapshot from memory (a mapped file).
    p: ptr UncheckedArray[byte]
    pos, len: int

const FlushAt = 1 shl 16

# ----------------------------------------------------------------- schema --

proc describe(t: NimNode, s: var string, seen: var seq[string]) =
  let impl = t.getTypeImpl
  case impl.kind
  of nnkObjectTy:
    let name = t.repr
    if name in seen:
      s.add "@" & name
      return
    seen.add name
    s.add "{" & name & ":" & $impl.getSize
    proc fields(n: NimNode, s: var string, seen: var seq[string]) =
      case n.kind
      of nnkRecList:
        for c in n: fields(c, s, seen)
      of nnkIdentDefs:
        for i in 0 ..< n.len - 2:
          s.add " " & $n[i] & "="
          describe(n[^2], s, seen)
      of nnkRecCase:
        s.add " case"
        fields(n[0], s, seen)
        for b in n[1 .. ^1]: fields(b[^1], s, seen)
      of nnkOfBranch, nnkElse:
        fields(n[^1], s, seen)
      of nnkSym:
        s.add " " & $n & "="
        describe(n.getTypeInst, s, seen)
      of nnkEmpty, nnkNilLit: discard
      else: error("schemaOf: unsupported object part " & $n.kind, n)
    fields(impl[2], s, seen)
    s.add "}"
  of nnkEnumTy:
    s.add "enum("
    for f in impl[1 .. ^1]: s.add $f & ","
    s.add ")"
  of nnkBracketExpr:
    s.add "[" & impl[0].repr
    for a in impl[1 .. ^1]:
      s.add ","
      if a.kind == nnkInfix or a.kind in nnkLiterals: s.add a.repr
      else: describe(a, s, seen)
    s.add "]"
  of nnkTupleTy:
    s.add "("
    for d in impl:
      for i in 0 ..< d.len - 2:
        s.add $d[i] & "="
        describe(d[^2], s, seen)
        s.add ","
    s.add ")"
  of nnkDistinctTy:
    s.add "distinct "
    describe(impl[0], s, seen)
  of nnkRefTy, nnkPtrTy, nnkProcTy:
    error("schemaOf: " & t.repr & " cannot be stored", t)
  else:
    s.add impl.repr & ":" & $impl.getSize

macro schemaOf*(T: typedesc): string =
  ## A description of `T`'s whole layout: two builds store `T` alike only
  ## when their descriptions are equal.
  var s = ""
  var seen: seq[string]
  describe(T.getTypeInst[1], s, seen)
  newLit(s)

# ----------------------------------------------------------------- writer --

proc initBinWriter*(f: File): BinWriter =
  ## A writer appending to `f`.
  BinWriter(f: f)

proc flush*(w: var BinWriter) =
  ## Writes the buffered bytes. Raises `IOError` on a write failure.
  if w.buf.len > 0:
    if w.f.writeBuffer(addr w.buf[0], w.buf.len) != w.buf.len:
      raise newException(IOError, "cannot write the index cache")
    w.written += w.buf.len
    w.buf.setLen 0

proc putRaw(w: var BinWriter, p: pointer, n: int) =
  if n >= FlushAt:
    w.flush()
    if w.f.writeBuffer(p, n) != n: raise newException(IOError, "cannot write the index cache")
    w.written += n
  elif n > 0:
    let at = w.buf.len
    w.buf.setLen at + n
    copyMem(addr w.buf[at], p, n)
    if w.buf.len >= FlushAt: w.flush()

func written*(w: BinWriter): int64 {.inline.} =
  ## Bytes written so far, buffered ones included.
  w.written + w.buf.len

proc put*[T](w: var BinWriter, x: T) =
  ## Appends `x`.
  when T is object and not supportsCopyMem(T) or T is object and compiles(x.isSome):
    when compiles(x.isSome): # Option
      w.put x.isSome
      if x.isSome: w.put x.get
    else:
      for _, v in fieldPairs(x): w.put v
  elif T is string or T is seq:
    w.put int64(x.len)
    when supportsCopyMem(typeof(x[0])):
      if x.len > 0: w.putRaw(addr x[0], x.len * sizeof(x[0]))
    else:
      for e in x: w.put e
  elif T is array:
    when supportsCopyMem(T): w.putRaw(addr x, sizeof(x))
    else:
      for e in x: w.put e
  elif T is tuple:
    for v in fields(x): w.put v
  elif T is object: # plain memory
    for _, v in fieldPairs(x): w.put v
  elif supportsCopyMem(T): # numbers, enums, bools, chars, sets, ranges, distinct
    w.putRaw(addr x, sizeof(x))
  else:
    {.error: "put: " & $T & " cannot be stored".}

# ----------------------------------------------------------------- reader --

func initBinReader*(p: ptr UncheckedArray[byte], len: int): BinReader =
  ## A reader of the `len` bytes at `p`.
  BinReader(p: p, len: len)

func atEnd*(r: BinReader): bool {.inline.} =
  ## Every byte was read.
  r.pos == r.len

proc short() {.noinline, noreturn.} =
  raiseFormat("the index cache is shorter than its contents")

proc getRaw(r: var BinReader, p: pointer, n: int) =
  if n < 0 or n > r.len - r.pos: short()
  if n > 0: copyMem(p, addr r.p[r.pos], n)
  r.pos += n

proc getLen(r: var BinReader, elem: int): int =
  var n: int64
  r.getRaw(addr n, sizeof(n))
  if n < 0 or n > int64(r.len - r.pos) div max(elem, 1): short()
  int(n)

proc get*[T](r: var BinReader, x: var T) =
  ## Reads a value stored by `put` into `x` (a default value of `T`).
  when T is object and not supportsCopyMem(T) or T is object and compiles(x.isSome):
    when compiles(x.isSome):
      var has: bool
      r.get has
      if has:
        var v: typeof(x.get)
        r.get v
        x = some(move v)
      else:
        x = none(typeof(x.get))
    else:
      for _, v in fieldPairs(x):
        # A variant's discriminator comes before its branch's fields, so the
        # branch read next is the stored one; the object is a fresh default.
        var tmp: typeof(v)
        r.get tmp
        {.cast(uncheckedAssign).}:
          v = move tmp
  elif T is string or T is seq:
    let n = r.getLen(when supportsCopyMem(typeof(x[0])): sizeof(x[0]) else: 1)
    x.setLen n
    when supportsCopyMem(typeof(x[0])):
      if n > 0: r.getRaw(addr x[0], n * sizeof(x[0]))
    else:
      for e in x.mitems: r.get e
  elif T is array:
    when supportsCopyMem(T): r.getRaw(addr x, sizeof(x))
    else:
      for e in x.mitems: r.get e
  elif T is tuple:
    for v in fields(x): r.get v
  elif T is object:
    for _, v in fieldPairs(x): r.get v
  elif supportsCopyMem(T):
    r.getRaw(addr x, sizeof(x))
  else:
    {.error: "get: " & $T & " cannot be stored".}

proc skipSeq*(r: var BinReader, T: typedesc) =
  ## Skips a stored `seq[T]` of plain-memory `T` without reading it.
  let n = r.getLen(sizeof(T))
  r.pos += n * sizeof(T)

# --------------------------------------------------------------- checksum --

func checksum*(p: ptr UncheckedArray[byte], n: int, seed = 0'u64): uint64 =
  ## A fast 64-bit checksum of `n` bytes at `p` (four multiply-xor lanes;
  ## detects corruption, not tampering).
  const k = 0x9E3779B97F4A7C15'u64
  var h = [seed xor 0x243F6A8885A308D3'u64, seed xor 0x13198A2E03707344'u64,
    seed xor 0xA4093822299F31D0'u64, seed xor 0x082EFA98EC4E6C89'u64]
  var i = 0
  while i + 32 <= n:
    for l in 0..3:
      var w: uint64
      copyMem(addr w, addr p[i + 8 * l], 8)
      h[l] = (h[l] xor w) * k
      h[l] = h[l] xor (h[l] shr 31)
    i += 32
  var tail = uint64(n)
  while i < n:
    tail = (tail xor uint64(p[i])) * k
    inc i
  result = tail
  for l in 0..3: result = (result xor h[l]) * k xor (result shr 29)
