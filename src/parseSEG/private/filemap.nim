## The memory map of a disk file (`MemFileSource` holds one).
##
## Not Windows: `std/memfiles`, as always.
##
## Windows: the file is opened here, not by `std/memfiles`. `memfiles` opens
## a read-only map with `FILE_SHARE_READ` alone, which makes the OS refuse
## every other program that wants to write to, append to, rename or delete
## the file while it is mapped, and refuse the map itself when a recorder
## has the file open for writing. Here the file is opened with
## `FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE`, as on Linux
## and macOS, then mapped with `CreateFileMappingW` and `MapViewOfFile`.
## The file is sized from the opened handle (`GetFileSizeEx`), so a file
## reached through a symbolic link has the size of its target, not the
## link's own (0), and the map covers exactly that many bytes: a file that
## grows meanwhile is read only up to the size at open.
##
## What the OS still refuses while the map exists, and parseSEG cannot
## change (the other program's call fails, not parseSEG's reads): cutting the
## file below the mapped size (`ERROR_USER_MAPPED_FILE`, 1224) and, to the
## best of this module's knowledge, deleting or replacing the file (access
## denied). `docs/guide/viewer.md` says so for users of the library.
##
## Paths longer than `MAX_PATH` are not handled specially (the library adds no
## long-path prefix anywhere): they open on Windows 10 and later
## when the program's manifest says it is long-path aware.

import std/memfiles
when defined(windows):
  import std/[oserrors, winlean, widestrs]

when defined(windows):
  type
    FileMap* = object
      ## A mapped file: `mem` and `size` as in `MemFile`, `handle` the open file.
      mem*: pointer
      size*: int
      handle*: Handle ## the file, open with full sharing until `close`
      writable: bool

  type LargeInteger {.importc: "LARGE_INTEGER", header: "<windows.h>".} = object
    QuadPart: int64

  type MemoryBasicInformation {.importc: "MEMORY_BASIC_INFORMATION",
      header: "<windows.h>".} = object
    RegionSize: csize_t

  proc virtualQuery(address: pointer, info: ptr MemoryBasicInformation,
      length: csize_t): csize_t {.stdcall, dynlib: "kernel32", importc: "VirtualQuery".}

  proc getFileSizeEx(h: Handle, size: ptr LargeInteger): int32 {.stdcall,
    dynlib: "kernel32", importc: "GetFileSizeEx".}

  proc openFileMap*(path: string; writable: bool): FileMap {.
      raises: [OSError, IOError].} =
    ## Opens and maps `path` (read-only unless `writable`). An empty file maps
    ## nothing: `size` is 0, `mem` nil and no handle is held. Raises `OSError`
    ## (with the Windows message) when it cannot be opened, sized or mapped,
    ## `IOError` when it is larger than the address space.
    result = FileMap(handle: INVALID_HANDLE_VALUE)
    let access = if writable: GENERIC_READ or GENERIC_WRITE else: GENERIC_READ
    let file = createFileW(newWideCString(path), access,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0)
    if file == INVALID_HANDLE_VALUE:
      raiseOSError(osLastError(), "cannot open " & path)
    var n: LargeInteger
    if getFileSizeEx(file, addr n) == 0:
      let e = osLastError()
      discard closeHandle(file)
      raiseOSError(e, "cannot get the size of " & path)
    if n.QuadPart == 0:
      discard closeHandle(file)
      return
    if n.QuadPart > int64(high(int)):
      discard closeHandle(file)
      raise newException(IOError, path & " is too large to map (" & $n.QuadPart & " bytes)")
    var bytes = uint64(n.QuadPart)
    # Read-only: the size is given, so the section covers what was sized,
    # even when the file is cut between the size and here (then this fails,
    # instead of a view with pages the file no longer has). Writable: a
    # section larger than the file would grow the file, so the file's size
    # at this moment is taken (0), and sized again once it exists (a section
    # keeps the file from being cut below it).
    let sectionSize = if writable: 0'u64 else: bytes
    let sizeHigh = cast[DWORD](uint32(sectionSize shr 32))
    let sizeLow = cast[DWORD](uint32(sectionSize and 0xFFFF_FFFF'u64))
    let mapping = createFileMappingW(file, nil,
      if writable: PAGE_READWRITE else: PAGE_READONLY, sizeHigh, sizeLow, nil)
    if mapping == 0:
      let e = osLastError()
      discard closeHandle(file)
      raiseOSError(e, "cannot map " & path)
    let view = mapViewOfFileEx(mapping,
      if writable: FILE_MAP_READ or FILE_MAP_WRITE else: FILE_MAP_READ, 0, 0,
      WinSizeT(sectionSize), nil) # 0: the whole section
    # The view keeps the section alive: its handle is not needed.
    let mapError = osLastError()
    discard closeHandle(mapping)
    if view == nil:
      discard closeHandle(file)
      raiseOSError(mapError, "cannot map a view of " & path)
    if writable:
      var now: LargeInteger
      if getFileSizeEx(file, addr now) != 0: bytes = min(bytes, uint64(now.QuadPart))
      # And no more than the view holds, whatever the file's size says.
      var info: MemoryBasicInformation
      if virtualQuery(view, addr info, csize_t(sizeof(info))) != 0:
        bytes = min(bytes, uint64(info.RegionSize))
    result = FileMap(mem: view, size: int(bytes), handle: file, writable: writable)

  proc flush*(m: var FileMap) {.raises: [OSError].} =
    ## Writes modified pages of a writable map back to the file and the
    ## file's buffers to the device.
    if m.mem != nil and m.writable:
      var last: OSErrorCode
      for _ in 1 .. 3:
        if flushViewOfFile(m.mem, 0) != 0:
          # `FlushViewOfFile` hands the pages to the file system; the file's
          # own buffers are written out by `FlushFileBuffers`.
          if flushFileBuffers(m.handle) == 0:
            raiseOSError(osLastError(), "error flushing the file of a mapping")
          return
        last = osLastError()
        if last != OSErrorCode(ERROR_LOCK_VIOLATION): break
      raiseOSError(last, "error flushing mapping")

  proc close*(m: var FileMap) {.raises: [OSError].} =
    ## Unmaps the view and closes the file. Both are released even when the
    ## unmap fails (then the first error is raised after).
    var err = OSErrorCode(0)
    if m.mem != nil:
      if unmapViewOfFile(m.mem) == 0: err = osLastError()
      m.mem = nil
    if m.handle != INVALID_HANDLE_VALUE:
      if closeHandle(m.handle) == 0 and err == OSErrorCode(0): err = osLastError()
      m.handle = INVALID_HANDLE_VALUE
    m.size = 0
    if err != OSErrorCode(0): raiseOSError(err, "error closing mapping")

else:
  type FileMap* = MemFile

  export memfiles.close, memfiles.flush

  proc openFileMap*(path: string; writable: bool; allowRemap = false): FileMap {.
      raises: [OSError, IOError].} =
    ## Opens and maps `path` (read-only unless `writable`); `allowRemap` keeps
    ## the descriptor open (`MemFile.handle`).
    memfiles.open(path, mode = if writable: fmReadWrite else: fmRead,
      allowRemap = allowRemap)
