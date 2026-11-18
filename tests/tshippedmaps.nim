## Every vendor map shipped in `vendormaps/` loads through the library's own loader
## without error and says what it reads.

import std/[assertions, os]

import parseSEG/vendor/maps

const mapDir = currentSourcePath().parentDir / ".." / "vendormaps"

proc main*() =
  var count = 0
  for path in walkFiles(mapDir / "*.nif"):
    let m = loadVendorMap(readFile(path), path)
    doAssert m.doc.len > 0, path & " has no description"
    doAssert m.name.len > 0, path & " has no name"
    doAssert m.targets.len > 0, path & " has no target"
    inc count
  doAssert count >= 2, "the shipped maps were not found in " & mapDir

when isMainModule: main()
