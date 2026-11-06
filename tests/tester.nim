## Runs every tests/t*.nim file. Usage from the project root: nim c -r tests/tester.nim

import std/os

proc fatal(msg: string) = quit "FAILURE " & msg

proc exec(cmd: string) =
  echo "Running: ", cmd
  if execShellCmd(cmd) != 0: fatal cmd

let testDir = getCurrentDir() / "tests"
for f in walkFiles(testDir / "t*.nim"):
  if f.extractFilename != "tester.nim":
    exec getCurrentCompilerExe().quoteShell & " c -r --hints:off --outdir:" &
      quoteShell(getTempDir() / "parsesegd_tests") & " " & quoteShell(f)

echo "All test files completed."
