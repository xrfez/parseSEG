## The package version, defined once: in `parseSEG.nimble`.
##
## Nimble builds pass it as `-d:NimblePkgVersion`. Other builds read it from
## the nimble file at compile time.

import std/[os, strutils]

const NimblePkgVersion {.strdefine.} = ""

proc nimbleVersion(): string {.compileTime.} =
  let path = currentSourcePath().parentDir.parentDir.parentDir / "parseSEG.nimble"
  if fileExists(path):
    for line in staticRead(path).splitLines:
      let parts = line.split('=', maxsplit = 1)
      if parts.len == 2 and parts[0].strip == "version":
        return parts[1].strip.strip(chars = {'"'})
  "unknown"

const PackageVersion* = when NimblePkgVersion.len > 0: NimblePkgVersion else: nimbleVersion()
  ## The package version, e.g. "0.3.0".
