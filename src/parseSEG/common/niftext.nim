## NIF text for the documents the library reads and writes by hand: the
## diagnostics log, the header export and its patches, the edit journal,
## vendor map scaffolds and the CLI's NIF output.
##
## `nifString` writes a string literal. `NifIn` reads a document, from a
## string or streamed from a file, with a small strict tokenizer: documents
## are untrusted input, so it bounds tags, strings and numbers, refuses what
## the library never writes (line information suffixes), and reports every
## problem as `SegFormatError` with the document's name and the line.

import std/strutils
import ./errors

const
  MaxNifDepth* = 64         ## Deepest nesting `skipTree` follows.
  MaxNifString* = 1 shl 20  ## Longest string literal, in decoded bytes.
  NifIdentStart* = {'A'..'Z', 'a'..'z', '_'} ## What an identifier starts with.
  NifIdentChars* = NifIdentStart + {'0'..'9', '.'}
    ## What an identifier or a tag goes on with (a directive's tag starts
    ## with the dot: `(.nif27)`).

type
  NifTokKind* = enum
    ## The kinds of token `next` gives.
    ntOpen  ## `(` with its tag (possibly empty).
    ntClose ## `)`.
    ntIdent ## An identifier.
    ntInt   ## An integer that fits `int64`.
    ntFloat ## A number with a fraction or an exponent.
    ntStr   ## A string literal, decoded.
    ntEof   ## The end of the document.

  NifTok* = object
    ## One token of a NIF document.
    kind*: NifTokKind
    s*: string  ## The tag, identifier or decoded string.
    i*: int64   ## The value of an `ntInt`.
    f*: float64 ## The value of an `ntFloat`.

  NifIn* = object
    ## A NIF document being read: `initNifIn` for one held in a string,
    ## `openNifIn` for a file, which is streamed through a 64 KiB buffer (so
    ## memory does not grow with the document) and needs `close`.
    f: File      # nil for a string
    buf: string
    pos: int
    eof: bool    # nothing more comes after `buf`
    line: int
    name: string

func nifString*(s: string): string =
  ## `s` as a quoted NIF string literal: `"`, `\`, control and non-ASCII
  ## bytes are written as `\HH`.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for c in s:
    if c in {'"', '\\'} or ord(c) < 0x20 or ord(c) >= 0x7F: result.add "\\" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

func initNifIn*(text: sink string, name: string): NifIn =
  ## A reader of the document `text`; error messages call it `name`.
  NifIn(buf: text, eof: true, line: 1, name: name)

proc openNifIn*(path: string): NifIn =
  ## A reader of the document in the file `path`, which error messages
  ## name. Raises `IOError` if it cannot be opened. `close` it when done.
  result = NifIn(line: 1, name: path)
  if not open(result.f, path, fmRead):
    raise newException(IOError, "cannot open for reading: " & path)

proc close*(n: var NifIn) =
  ## Closes the file of a reader made by `openNifIn` (no-op otherwise, and
  ## when it is closed already).
  if n.f != nil:
    n.f.close()
    n.f = nil

func line*(n: NifIn): int {.inline.} =
  ## The 1-based line the reader is at.
  n.line

proc docError*(n: NifIn, msg: string) {.noinline, noreturn.} =
  ## Raises `SegFormatError`: `<name> line <line>: <msg>`.
  raiseFormat(n.name & " line " & $n.line & ": " & msg)

proc fill(n: var NifIn): bool =
  # True when at least one byte is available.
  if n.pos < n.buf.len: return true
  if n.eof: return false
  n.buf.setLen 64 * 1024
  let got = n.f.readBuffer(addr n.buf[0], n.buf.len)
  n.buf.setLen got
  n.pos = 0
  if got == 0: n.eof = true
  got > 0

proc peek(n: var NifIn): char =
  if n.fill: n.buf[n.pos] else: '\0'

proc take(n: var NifIn): char =
  if not n.fill: n.docError("unexpected end of the document")
  result = n.buf[n.pos]
  inc n.pos
  if result == '\n': inc n.line

proc next*(n: var NifIn): NifTok =
  ## The next token; `ntEof` at the end of the document. White space and
  ## `;` comments (to the end of the line) are skipped. Raises
  ## `SegFormatError` for anything that is not a token (see `docError`),
  ## and `IOError` when the file cannot be read.
  while true:
    if not n.fill: return NifTok(kind: ntEof)
    let c = n.peek
    if c in Whitespace: discard n.take
    elif c == ';':
      while n.fill and n.peek != '\n': discard n.take
    else: break
  let c = n.take
  case c
  of '(':
    result = NifTok(kind: ntOpen)
    while n.fill and n.peek in NifIdentChars:
      result.s.add n.take
      if result.s.len > 256: n.docError("tag too long")
    if n.fill and n.peek == '@': n.docError("line information is not supported")
  of ')': result = NifTok(kind: ntClose)
  of '"':
    result = NifTok(kind: ntStr)
    while true:
      let d = n.take
      if d == '"': break
      if d == '\\':
        var h = ""
        h.add n.take
        h.add n.take
        if h[0] notin HexDigits or h[1] notin HexDigits: n.docError("bad string escape \\" & h)
        result.s.add char(parseHexInt(h))
      else: result.s.add d
      if result.s.len > MaxNifString: n.docError("string longer than 1 MB")
  of '-', '+', '0'..'9':
    var t = $c
    while n.fill and n.peek in {'0'..'9', '.', 'e', 'E', '+', '-'}:
      t.add n.take
      if t.len > 64: n.docError("number too long")
    if n.fill and n.peek == '@': n.docError("line information is not supported")
    if t.contains({'.', 'e', 'E'}):
      try: result = NifTok(kind: ntFloat, f: parseFloat(t))
      except ValueError: n.docError("bad number " & t)
    else:
      try: result = NifTok(kind: ntInt, i: parseBiggestInt(t))
      except ValueError: n.docError("bad or out-of-range integer " & t)
  else:
    if c notin NifIdentStart: n.docError("unexpected character " & escape($c))
    result = NifTok(kind: ntIdent, s: $c)
    while n.fill and n.peek in NifIdentChars:
      result.s.add n.take
      if result.s.len > 256: n.docError("identifier too long")
    if n.fill and n.peek == '@': n.docError("line information is not supported")

proc skipTree*(n: var NifIn, depth: int) =
  ## After an `ntOpen` at nesting `depth`: skips to its matching `)`. Raises
  ## `SegFormatError` when the document ends first or nests deeper than
  ## `MaxNifDepth`.
  var d = 1
  while d > 0:
    let t = n.next
    case t.kind
    of ntOpen:
      inc d
      if depth + d > MaxNifDepth: n.docError("nesting deeper than " & $MaxNifDepth)
    of ntClose: dec d
    of ntEof: n.docError("unexpected end of the document")
    else: discard

proc expectClose*(n: var NifIn, what: string) =
  ## Reads a `)`, or raises `SegFormatError` ("expected ')' after `what`").
  if n.next.kind != ntClose: n.docError("expected ')' after " & what)

proc expectInt*(n: var NifIn, what: string): int64 =
  ## Reads an integer, or raises `SegFormatError` ("expected `what`").
  let t = n.next
  if t.kind != ntInt: n.docError("expected " & what)
  t.i

proc expectStr*(n: var NifIn, what: string): string =
  ## Reads a string literal, or raises `SegFormatError` ("expected `what`").
  var t = n.next
  if t.kind != ntStr: n.docError("expected " & what)
  move t.s
