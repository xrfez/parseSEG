## The package version, defined once: in `parseSEG.nimble`.
##
## Nimble builds pass it as `-d:NimblePkgVersion`. Other builds read it from
## the nimble file at compile time.

import std/strutils
from std/os import fileExists

const NimblePkgVersion {.strdefine.} = ""

proc nimbleVersion(): string {.compileTime.} =
  # The path is cut and joined by hand with "/": in a cross-build for
  # Windows this runs on the build host, where `std/os` (`parentDir`, `/`)
  # would write the target's backslashes and find no file. Every host's
  # compiler-side file calls take "/" (Windows hosts accept it too).
  let here = currentSourcePath().replace('\\', '/')
  var root = here
  for _ in 1 .. 3: # version.nim, parseSEG/, src/
    let cut = root.rfind('/')
    root = if cut >= 0: root[0 ..< cut] else: "."
  let path = root & "/parseSEG.nimble"
  if fileExists(path):
    for line in staticRead(path).splitLines:
      let parts = line.split('=', maxsplit = 1)
      if parts.len == 2 and parts[0].strip == "version":
        return parts[1].strip.strip(chars = {'"'})
  "unknown"

const PackageVersion* = when NimblePkgVersion.len > 0: NimblePkgVersion else: nimbleVersion()
  ## The package version, e.g. "0.4.0".
