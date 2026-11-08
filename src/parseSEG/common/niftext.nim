## NIF string literals for the documents the library writes by hand: the
## edit journal, the header export, vendor map scaffolds and the CLI's NIF
## output.

import std/strutils

func nifString*(s: string): string =
  ## `s` as a quoted NIF string literal: `"`, `\`, control and non-ASCII
  ## bytes are written as `\HH`.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for c in s:
    if c in {'"', '\\'} or ord(c) < 0x20 or ord(c) >= 0x7F: result.add "\\" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'
