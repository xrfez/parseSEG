## A record sink that collects what it is given in memory: the bytes of a
## file that is never written to disk (`openSeismicWriterBytes`).
##
## Like `DiskSink` it appends records back to back and drops tape marks; the
## bytes are the file. The buffer grows by doubling (a `seq`), and
## `takeBytes` moves it out without a copy.

import records

type
  MemSink* {.acyclic.} = ref object of RecordSink
    ## Collects records back to back in a growable buffer. Acyclic, as
    ## `DiskSink`.
    buf: seq[byte]

proc openMemSink*(name: string): MemSink =
  ## A sink with no bytes yet; `name` is for diagnostics, nothing is created
  ## on disk for it.
  MemSink(name: name)

func len*(s: MemSink): int {.inline.} =
  ## Bytes collected so far.
  s.buf.len

method writeRecordImpl*(s: MemSink; data: openArray[byte]) {.raises: [CatchableError].} =
  if data.len > 0: s.buf.add data
  s.offset += data.len

method writeTapeMarkImpl*(s: MemSink) {.raises: [CatchableError].} = discard

proc patch*(s: MemSink, at: int, data: openArray[byte]) =
  ## Overwrites the bytes at `at` with `data`, which must lie inside what was
  ## written (the back-patching of counts that are known at the end, as a
  ## file is patched). Raises `IndexDefect` otherwise.
  if at < 0 or data.len > s.buf.len - at: # not `at + data.len`: that can wrap
    raise newException(IndexDefect, "patch outside the bytes written")
  if data.len > 0: copyMem(addr s.buf[at], addr data[0], data.len)

proc takeBytes*(s: MemSink): seq[byte] =
  ## The bytes collected, moved out (the sink is empty afterwards).
  result = move s.buf
  s.offset = 0
