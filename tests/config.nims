switch("path", "$projectdir/../src")

# `-d:cpuV3` (the `nim testV3` task): the CPU target of `nim cli`.
when defined(cpuV3) and defined(amd64):
  switch("passC", "-march=x86-64-v3")
