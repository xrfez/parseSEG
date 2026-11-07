## Runs every tests/t*.nim file. Usage from the project root: nim c -r tests/tester.nim

import std/[os, strutils]

proc fatal(msg: string) = quit "FAILURE " & msg

proc exec(cmd: string) =
  echo "Running: ", cmd
  if execShellCmd(cmd) != 0: fatal cmd

# Forward the build mode, so `nim c -d:danger -r tests/tester.nim` tests danger builds.
const mode =
  when defined(danger): " -d:danger"
  elif defined(release): " -d:release"
  else: ""

let testDir = getCurrentDir() / "tests"
for f in walkFiles(testDir / "t*.nim"):
  if f.extractFilename != "tester.nim":
    exec getCurrentCompilerExe().quoteShell & " c -r --hints:off" & mode & " --outdir:" &
      quoteShell(getTempDir() / ("parseseg_tests" & mode.replace(" -d:", "_"))) & " " &
      quoteShell(f)

echo "All test files completed."
