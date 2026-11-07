## The Python module end to end (tasks 8.8, 12.2): builds the shared library
## as `nim lib` does, puts it next to the generated `python/parseseg` package
## in a temporary directory, then runs `tests/python/test_pyapi.py` under
## `python3 -I`: with numpy when it is installed, and once more with numpy
## hidden. Set `PARSESEG_NUMPY_PATH` to a directory holding numpy to test the
## numpy paths without installing it. Skipped (with a message) without
## python3.

import std/[os, osproc, strutils]

const
  root = currentSourcePath().parentDir.parentDir
  exampleDir = root / "SEG Spec" / "exampleFiles"

proc mustRun(cmd: string) =
  let (o, code) = execCmdEx(cmd)
  if code != 0:
    echo o
    quit "tpython: command failed: " & cmd

when defined(linux) or defined(macosx):
  let py = findExe("python3")
  if py.len == 0:
    echo "tpython: no python3; Python module test skipped"
  else:
    let tmp = getTempDir() / "parseseg_tpython"
    let pkg = tmp / "module" / "parseseg"
    createDir(pkg)
    createDir(tmp / "gen" / "include")
    createDir(tmp / "gen" / "python" / "parseseg")
    const libName = when defined(macosx): "libparseseg.dylib" else: "libparseseg.so"
    mustRun(getCurrentCompilerExe().quoteShell & " c --hints:off --app:lib --noMain " &
      "--mm:atomicArc --threads:on -d:useMalloc -d:segCapi --nimcache:" &
      quoteShell(tmp / "cache") & " -d:segBindingsDir=" & quoteShell(tmp / "gen") & " -o:" &
      quoteShell(pkg / libName) & " " & quoteShell(root / "src" / "parseSEG" / "bindings.nim"))
    copyFile(root / "python" / "parseseg" / "__init__.py", pkg / "__init__.py")
    let numpyPath = getEnv("PARSESEG_NUMPY_PATH")
    # -I ignores PYTHONPATH, so an extra numpy directory is appended by a stub.
    let runner = if numpyPath.len == 0: py & " -I "
                 else: py & " -I -c " & quoteShell("import sys,runpy; sys.path.append(sys.argv[1]); " &
                   "sys.argv=sys.argv[2:]; runpy.run_path(sys.argv[0], run_name='__main__')") &
                   " " & quoteShell(numpyPath) & " "
    let script = runner & quoteShell(root / "tests" / "python" / "test_pyapi.py") & " " &
      quoteShell(tmp / "module") & " " & quoteShell(exampleDir) & " " &
      quoteShell(tmp / "scratch")
    for mode in ["", " nonumpy"]:
      let (o, code) = execCmdEx(script & mode)
      if code != 0 or "python module: ok" notin o:
        echo o
        quit "tpython: test_pyapi.py" & mode & " failed"
      echo o.strip
else:
  echo "tpython: the Python module test runs on Linux and macOS only for now"
