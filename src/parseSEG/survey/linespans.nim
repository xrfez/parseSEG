## The lines of a text stream as spans of one buffer. Internal: the
## `parseSEG` umbrella does not export this module.
##
## `textrec.textRecords` and the SPS reader cut their records with it. A
## line built character by character in a string of its own, and copied once
## more for the caller, was a third of the time of an SPS read; here a line
## is two indices into the chunk it was read in.

import std/streams

const ChunkBytes = 1 shl 20 ## Read at a time (more when lines may be longer).

proc memchr(s: pointer, c: cint, n: csize_t): pointer {.importc, header: "<string.h>".}

func terminator(buf: string, first, last: int): int {.inline.} =
  # The first LF or CR in `buf[first ..< last]`; `last` if there is none.
  # (Looking at each byte in Nim, with its bound checks, was a fifth of an
  # SPS read.)
  result = last
  if last > first:
    let lf = memchr(addr buf[first], cint('\n'), csize_t(last - first))
    if lf != nil: result = first + int(cast[uint](lf) - cast[uint](addr buf[first]))
    if result > first:
      let cr = memchr(addr buf[first], cint('\r'), csize_t(result - first))
      if cr != nil: result = first + int(cast[uint](cr) - cast[uint](addr buf[first]))

type LineSpan* = object
  ## One line as `lineSpans` yields it.
  lo*, hi*: int     ## The line is `buf[lo .. hi]`; `hi == lo - 1` when it is empty.
  offset*: int64    ## Byte offset of the line in the stream.
  index*: int       ## 0-based line number.
  crlf*: bool       ## The line ended in CR LF.
  terminated*: bool ## A line terminator followed.
  cut*: bool        ## Longer than the limit: cut there, the rest is the next line.

iterator lineSpans*(s: Stream, buf: var string, maxLine: int): LineSpan =
  ## The lines of `s`, from its position to its end, as spans of `buf`. The
  ## iterator sizes and fills `buf`; a span is valid until the next one is
  ## asked for. A line ends at LF, CR LF or a lone CR (the terminator is not
  ## part of the span); NUL and other bytes are data. A final line without a
  ## terminator is still a line (`terminated` false), an empty one at the
  ## very end is not. A line of `maxLine` bytes without a terminator is cut
  ## there (`cut`), and what follows is the next line.
  buf.setLen max(ChunkBytes, 4 * maxLine)
  var n = 0                        # bytes of `buf` that hold data
  var lineLo = 0                   # where the current line starts
  var pos = 0                      # scanned so far
  var base = int64(s.getPosition)  # stream offset of buf[0]
  var eof = false
  var index = 0
  var done = false
  template emit(last: int, isCrlf, isTerminated, isCut: bool) =
    yield LineSpan(lo: lineLo, hi: last, offset: base + int64(lineLo), index: index,
      crlf: isCrlf, terminated: isTerminated, cut: isCut)
    inc index
  template refill() =
    # Keeps the unfinished line, at the front, and reads on behind it.
    if lineLo > 0:
      if n > lineLo: moveMem(addr buf[0], addr buf[lineLo], n - lineLo)
      base += int64(lineLo)
      pos -= lineLo
      n -= lineLo
      lineLo = 0
    let got = s.readData(addr buf[n], buf.len - n)
    if got <= 0: eof = true
    else: n += got
  while not done:
    pos = terminator(buf, pos, min(n, lineLo + maxLine))
    if pos - lineLo >= maxLine:
      emit(pos - 1, false, false, true)
      lineLo = pos
    elif pos < n:
      if buf[pos] == '\n':
        emit(pos - 1, false, true, false)
        inc pos
        lineLo = pos
      elif pos + 1 < n or eof:
        # A CR: with the LF after it, or alone.
        let crlf = pos + 1 < n and buf[pos + 1] == '\n'
        emit(pos - 1, crlf, true, false)
        pos += (if crlf: 2 else: 1)
        lineLo = pos
      else:
        refill() # the byte after the CR decides
    elif eof:
      if n > lineLo: emit(n - 1, false, false, false)
      done = true
    else:
      refill()
