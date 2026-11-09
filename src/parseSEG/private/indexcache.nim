## The index cache file format (`saveIndex`, `openSeismic(opts =
## OpenOptions(cache: ...))`): a file holding a `TraceIndex` exactly as the
## walk made it.
##
##   (.nif27)
##   (.vendor "parseSEG")
##   (indexcache
##    (version 1) (library "0.5.0") (schema "<hex>") (endian littleEndian)
##    (path "<absolute path>") (size <bytes>) (mtime <s> <ns>)
##    (head "<hex>") (tail "<hex>") (twosComplement8015 0) (keys 1))
##   NUL, zero bytes to an 8-byte boundary,
##   the index as a `binstore` snapshot (entries and keys as single blocks),
##   the snapshot's length and checksum (2 x uint64, native order).
##
## One field per header line; a cache is valid when its header is the one
## the file would get now. `schema` changes with any stored type, `library`
## with every release, `version` with this layout.
##
## This module knows the format only; `traceindex` checks the file it is
## asked to save and passes what identifies it (`CacheKey`).

import std/[os, times, strutils]
import ../common/[diagnostics, diagcodes, binstore, niftext, outputfile]
import ../io/memsource
import ../model/[keys, indextypes]
import ../version

type
  FileStamp* = object
    ## A file's size and modification time, taken when it is opened.
    size*, mtime*: int64 ## mtime: Unix seconds.
    mtimeNs*: int

  CacheKey* = object
    ## What identifies a file's cache: the file as opened, its mapped bytes
    ## (their first and last 64 KiB are hashed) and the open's settings.
    path*: string
    stamp*: FileStamp
    mem*: ptr UncheckedArray[byte]
    size*: int64 ## Bytes at `mem`.
    twos*: bool  ## `twosComplement8015`.

const
  IndexCacheVersion = 1
  StampSpan = 64 shl 10 ## Bytes hashed at each end of the file.
  HeaderLimit = 64 shl 10 ## Longest cache header read.

proc stampOf*(path: string): FileStamp =
  ## The size and modification time of `path` now.
  let info = getFileInfo(path)
  FileStamp(size: info.size, mtime: info.lastWriteTime.toUnix,
    mtimeNs: info.lastWriteTime.nanosecond)

proc spanSums(k: CacheKey): (uint64, uint64) =
  # Checksums of the first and the last `StampSpan` bytes of the map.
  let n = int(min(k.size, StampSpan))
  if n == 0: return (checksum(nil, 0), checksum(nil, 0))
  (checksum(k.mem, n), checksum(cast[ptr UncheckedArray[byte]](addr k.mem[k.size - n]), n))

proc cacheHeader(k: CacheKey, keys: bool): string =
  const schema = schemaOf(TraceIndex)
  let (head, tail) = k.spanSums
  "(.nif27)\n(.vendor \"parseSEG\")\n(indexcache\n" &
    " (version " & $IndexCacheVersion & ")\n" &
    " (library " & nifString(PackageVersion) & ")\n" &
    " (schema \"" & toHex(checksum(cast[ptr UncheckedArray[byte]](schema.cstring),
      schema.len)) & "\")\n" &
    " (endian " & $cpuEndian & ")\n" &
    " (path " & nifString(absolutePath(k.path)) & ")\n" &
    " (size " & $k.stamp.size & ")\n" &
    " (mtime " & $k.stamp.mtime & " " & $k.stamp.mtimeNs & ")\n" &
    " (head \"" & toHex(head) & "\")\n" &
    " (tail \"" & toHex(tail) & "\")\n" &
    " (twosComplement8015 " & $ord(k.twos) & ")\n" &
    " (keys " & $ord(keys) & "))\n"

proc headerMismatch(stored: string, k: CacheKey, keys: bool): string =
  # "" when `stored` fits the file as opened; else why not.
  let want = k.cacheHeader(keys)
  if stored == want or (not keys and stored == k.cacheHeader(true)): return ""
  let a = stored.splitLines
  let b = want.splitLines
  var tag = ""
  for i in 0 ..< max(a.len, b.len):
    if tag.len == 0 and (i >= a.len or i >= b.len or a[i] != b[i]):
      let line = if i < b.len: b[i] else: a[i]
      tag = line.strip.strip(chars = {'('}).split(' ')[0]
  case tag
  of "version", "library", "schema", "endian": "it was saved by another version of parseSEG"
  of "path": "it was saved for another file"
  of "size", "mtime", "head", "tail": "the file changed since it was saved"
  of "twosComplement8015": "it was saved with another twosComplement8015"
  of "keys": "it was saved without trace keys"
  else: "its header is not an index cache header"

func sampled(ix: TraceIndex): bool =
  # The index was computed from the file size (`vfSampled`).
  for d in ix.log:
    if d.code == dcIndexSampled: return true

proc readIndexCache*(cache: string, k: CacheKey, keys: bool, verify: VerifyMode,
    ix: var TraceIndex): string {.raises: [].} =
  ## Reads `ix` from the cache `cache` saved for `k`: "" when done, else why
  ## not (then `ix` is unchanged).
  if not fileExists(cache): return "there is no such file"
  var m: MemFileSource
  try:
    m = openMemFileSource(cache)
    let size = m.size
    let mem = m.memory
    var nul = -1
    for i in 0 ..< int(min(size, HeaderLimit)):
      if nul < 0 and mem[i] == 0: nul = i
    if nul < 0: return "it has no header"
    var stored = newString(nul)
    copyMem(addr stored[0], mem, nul)
    result = headerMismatch(stored, k, keys)
    if result.len == 0:
      let start = (nul + 8) and not 7
      var trailer: array[2, uint64]
      if size < start + 16: return "it is truncated"
      copyMem(addr trailer, addr mem[size - 16], 16)
      # Compared as uint64 first: a damaged trailer may not fit an int64.
      if trailer[0] > uint64(size): return "it is truncated"
      let n = int64(trailer[0])
      if start + n + 16 != size: return "it is truncated"
      let payload = cast[ptr UncheckedArray[byte]](addr mem[start])
      if checksum(payload, int(n)) != trailer[1]: return "it is corrupt (checksum)"
      var r = initBinReader(payload, int(n))
      var got: TraceIndex
      for name, v in fieldPairs(got):
        when name == "keys":
          if keys: r.get v
          else: r.skipSeq(TraceKeys)
        else:
          r.get v
      if not r.atEnd: return "its contents do not fit its layout"
      if verify == vfFull and got.sampled:
        return "it was saved from a sampled open, and verify = vfFull reads every header"
      ix = move got
  except CatchableError as e:
    result = "it cannot be read: " & e.msg
  finally:
    if m != nil:
      try: m.close()
      except CatchableError: discard

proc writeIndexCache*(path: string, k: CacheKey, ix: TraceIndex, walkLog: int, keys: bool) =
  ## Writes `ix` as the cache `path` for `k`, with the first `walkLog`
  ## entries of its log (the walk's), through a new temporary file next to
  ## `path` renamed when complete. Raises `IOError`/`OSError`.
  var log: DiagLog # the walk's diagnostics, not later ones (a cache miss)
  for i in 0 ..< min(walkLog, ix.log.len): log.add ix.log[i]
  let head = k.cacheHeader(keys)
  let tmp = createTempFor(path)
  try:
    var o: File
    if not open(o, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
    var n: int64
    try:
      o.write head
      var pad = newString(((head.len + 8) and not 7) - head.len) # NUL, then zeros
      o.write pad
      var w = initBinWriter(o)
      for name, v in fieldPairs(ix):
        when name == "log": w.put log
        else: w.put v
      w.flush()
      n = w.written
    finally:
      o.close()
    let m = openMemFileSource(tmp)
    var trailer = [uint64(n), 0'u64]
    try:
      let start = int64((head.len + 8) and not 7)
      if m.size != start + n: raise newException(IOError, "cannot write " & tmp)
      if n > 0: trailer[1] = checksum(cast[ptr UncheckedArray[byte]](addr m.memory[start]), int(n))
      else: trailer[1] = checksum(nil, 0)
    finally:
      m.close()
    if not open(o, tmp, fmAppend): raise newException(IOError, "cannot write " & tmp)
    try:
      if o.writeBuffer(addr trailer, 16) != 16: raise newException(IOError, "cannot write " & tmp)
    finally:
      o.close()
    moveFile(tmp, path)
  except CatchableError:
    discard tryRemoveFile(tmp)
    raise
