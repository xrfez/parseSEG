## The Python module end to end (task 8.8): builds `parseseg.so` as `nim pylib`
## does (applying the nimpy patch in `tools/patches`), with runtime checks on,
## then runs `tests/python/test_pyapi.py` under `python3 -I`, with numpy when
## it is installed and once more with numpy hidden. Skipped (with a message)
## without python3 or git.

import std/[os, osproc, strutils]

const
  root = currentSourcePath().parentDir.parentDir
  exampleDir = root / "SEG Spec" / "exampleFiles"
  patch = root / "tools" / "patches" / "nimpy-method-kwargs.patch"
  nimpyDir = root / "deps" / "nimpy"

proc mustRun(cmd: string) =
  let (o, code) = execCmdEx(cmd)
  if code != 0:
    echo o
    quit "tpython: command failed: " & cmd

when defined(linux) or defined(macosx):
  let py = findExe("python3")
  let git = findExe("git")
  if py.len == 0 or git.len == 0:
    echo "tpython: no python3 or git; Python module test skipped"
  else:
    let tmp = getTempDir() / "parsesegd_tpython"
    createDir(tmp)
    if execCmdEx(git & " -C " & quoteShell(nimpyDir) & " apply --reverse --check " &
        quoteShell(patch)).exitCode != 0:
      mustRun(git & " -C " & quoteShell(nimpyDir) & " apply " & quoteShell(patch))
    let modDir = tmp / "module"
    createDir(modDir)
    mustRun(getCurrentCompilerExe().quoteShell & " c --hints:off --app:lib --mm:atomicArc " &
      "--threads:on -d:useMalloc -d:segPython --nimcache:" & quoteShell(tmp / "cache") &
      " -o:" & quoteShell(modDir / "parseseg.so") & " " &
      quoteShell(root / "src" / "parseSEGD" / "pyapi.nim"))
    let script = py & " -I " & quoteShell(root / "tests" / "python" / "test_pyapi.py") & " " &
      quoteShell(modDir) & " " & quoteShell(exampleDir) & " " & quoteShell(tmp / "scratch")
    for mode in ["", " nonumpy"]:
      let (o, code) = execCmdEx(script & mode)
      if code != 0 or "python module: ok" notin o:
        echo o
        quit "tpython: test_pyapi.py" & mode & " failed"
      echo o.strip
else:
  echo "tpython: the Python module test runs on Linux and macOS only for now"
