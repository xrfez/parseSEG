## The shared library behind the C ABI and the Python module (task 12.2):
## every export is a `{.segApi.}` proc in `abi/api.nim`. Build with `nim lib`;
## compiling also writes `include/parseseg.h` and `python/parseseg/__init__.py`.

when appType == "lib" and not defined(segCapi):
  {.error: "build the library with -d:segCapi (see `nim lib`)".}

import ./abi/api
export api
