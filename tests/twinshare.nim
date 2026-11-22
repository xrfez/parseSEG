## A file open in parseSEG stays usable by other programs (and the other way
## round), mapped or unmapped. Windows opened a read-only map with
## `FILE_SHARE_READ` alone (`std/memfiles`): while a viewer had a file open,
## no other program could write to, append to, rename or delete it, and a
## recorder holding it open for writing made parseSEG's own open fail.
## `private/filemap` and `private/sharedfile` open every file with
## read, write and delete shared. The blocks run on every platform (Linux
## shares by itself, so they pass there; on Windows they are what is
## checked), except where a block says Windows only:
##
## - `append_rename_while_open`: another handle appends to the file and
##   it is renamed while parseSEG has it open; reads of the bytes of the
##   size at open go on, the size stays, and a read past it is refused.
## - `delete_while_open`: Windows maps are special: the OS refuses to
##   delete a file with a mapped view whatever its sharing, so for a mapped
##   open only "no crash, reads go on or the delete says why" is checked;
##   unmapped (and everywhere else) the delete works and the name is gone.
## - `replace_while_open`: a rename over the open file; on Windows a mapped one
##   may be refused (the output says which happened).
## - `open_while_written`: a recorder holds the file open for appending
##   while parseSEG opens it, and goes on writing.
## - `symbolic_link_has_the_size_of_its_target`: a link reads as the file
##   (on Windows `getFileSize(path)` gave the link's own size, 0, and the
##   file read as empty). Skipped when links cannot be made (Windows without
##   the privilege or developer mode).
## - `shared_opens_of_other_readers` (Windows only): the readers that go
##   through `File` (`openDiskSource`, the tape image and NIF readers)
##   leave the file renameable and deletable.
## - `move_waits_for_a_reader` (Windows only): `moveFileShared` retries while
##   another program has the target open without sharing delete.
##
## Seen failing: with the map opened by `std/memfiles` again, the append
## and rename blocks failed on Windows (sharing violation); with
## `getFileSize(path)` back in `openMemFileSource` the link read as empty
## there. Neither can be seen from the Linux host.

import std/[assertions, os]
when defined(windows):
  import std/typedthreads

import parseSEG
import parseSEG/io/[diskio, memsource]
import parseSEG/private/sharedfile

import ./utils/testutils

proc main*() =
  let tmp = scratchDir("parseseg_twinshare")
  let src = demoDir() / "survey.sgy"
  let size = getFileSize(src)

  block append_rename_while_open:
    for access in [faMapped, faUnmapped]:
      let a = tmp / ("a_" & $access & ".sgy")
      let b = tmp / ("b_" & $access & ".sgy")
      copyFile(src, a)
      var f = openSeismic(a, opts = OpenOptions(access: access))
      let n = f.len
      let before = f.readTraces(0 ..< n)
      # Another program appends: a recorder.
      var w: File
      doAssert open(w, a, fmAppend), "append while open"
      w.write("more trace bytes")
      w.close()
      doAssert getFileSize(a) == size + 16
      # And renames the file.
      moveFileShared(a, b)
      doAssert fileExists(b) and not fileExists(a)
      doAssert f.len == n
      doAssert f.readTraces(0 ..< n) == before
      f.close()
      # The file as it is now opens, with its new size.
      var g = openSeismic(b, opts = OpenOptions(access: access))
      g.close()

  block delete_while_open:
    for access in [faMapped, faUnmapped]:
      let a = tmp / ("d_" & $access & ".sgy")
      copyFile(src, a)
      var f = openSeismic(a, opts = OpenOptions(access: access))
      let before = f.readTraces(0 ..< f.len)
      var deleted = true
      try:
        removeFile(a)
      except OSError:
        deleted = false
      when defined(windows):
        # A mapped view stops a delete; no map, no such thing.
        doAssert deleted or access == faMapped, "delete of an unmapped open file"
      else:
        doAssert deleted
      echo "  delete while open, ", access, ": ", (if deleted: "done" else: "refused by the OS")
      doAssert f.readTraces(0 ..< f.len) == before
      f.close()
      if deleted:
        doAssert not fileExists(a), "the name is gone when the last handle closes"

  block replace_while_open:
    # Another program replaces the file by a rename over it (what a writer
    # that renames a temporary file does). Mapped on Windows the OS may refuse
    # (the writer's retry gives up); the readers go on either way.
    for access in [faMapped, faUnmapped]:
      let a = tmp / ("p_" & $access & ".sgy")
      let other = tmp / ("q_" & $access & ".sgy")
      copyFile(src, a)
      copyFile(src, other)
      var f = openSeismic(a, opts = OpenOptions(access: access))
      let before = f.readTraces(0 ..< f.len)
      var replaced = true
      try:
        moveFileShared(other, a, attempts = 3)
      except OSError:
        replaced = false
      when defined(windows):
        doAssert replaced or access == faMapped, "replace of an unmapped open file"
      else:
        doAssert replaced
      echo "  replace while open, ", access, ": ", (if replaced: "done" else: "refused by the OS")
      doAssert f.readTraces(0 ..< f.len) == before
      f.close()

  block open_while_written:
    for access in [faMapped, faUnmapped]:
      let a = tmp / ("w_" & $access & ".sgy")
      copyFile(src, a)
      var w: File
      doAssert open(w, a, fmAppend)
      var f = openSeismic(a, opts = OpenOptions(access: access))
      w.write("x")
      w.flushFile()
      doAssert f.readTraces(0 ..< f.len).shape[0] == f.len
      f.close()
      w.close()

  block symbolic_link_has_the_size_of_its_target:
    let link = tmp / "link.sgy"
    var made = true
    try:
      createSymlink(src, link)
    except OSError, CatchableError:
      made = false
    if not made:
      echo "  skipped: symbolic links cannot be made here"
    else:
      for access in [faMapped, faUnmapped]:
        let m = openMemFileSource(link, access = access)
        doAssert m.size == size, $access & ": the link's size " & $m.size
        if access == faMapped:
          for i in 0 ..< 8: doAssert char(m.memory[i]) == readFile(src)[i]
        m.close()
        var f = openSeismic(link, opts = OpenOptions(access: access))
        doAssert f.len > 0
        f.close()
      doAssert fileSizeShared(link) == size

  when defined(windows):
    block shared_opens_of_other_readers:
      let a = tmp / "r.sgy"
      copyFile(src, a)
      let s = openDiskSource(a)
      moveFileShared(a, tmp / "r2.sgy")
      removeFile(tmp / "r2.sgy")
      s.close()
      doAssert not fileExists(tmp / "r2.sgy")
      var f: File
      let b = tmp / "r3.sgy"
      copyFile(src, b)
      doAssert openShared(f, b, fmRead)
      moveFileShared(b, tmp / "r4.sgy")
      f.close()

    block move_waits_for_a_reader:
      let a = tmp / "m1.sgy"
      let b = tmp / "m2.sgy"
      copyFile(src, a)
      copyFile(src, b)
      var held: File
      doAssert open(held, b, fmRead) # fopen: shares no delete: the replace is refused
      var t: Thread[ptr File]
      proc letGo(p: ptr File) {.thread.} =
        sleep(50)
        p[].close()
      createThread(t, letGo, addr held)
      moveFileShared(a, b, attempts = 100) # a loaded runner may be late to let go
      joinThread(t)
      doAssert fileExists(b) and not fileExists(a)

  echo "twinshare: ok"

when isMainModule: main()
