## A tiny C library for `tests/tcapi.nim`: three exports through the real
## `segGuard`, to prove that a Defect inside an export becomes
## `SEG_ERR_INTERNAL` and leaves the thread usable (task 13.4, R3-1).

import ../../src/parseSEG/abi/runtime

proc guardDefect(i: int64): int32 {.exportc: "guard_defect", dynlib, cdecl, raises: [].} =
  ## Indexes a one-element seq at `i`: an `IndexDefect` for any `i` but 0.
  segGuard(nil):
    let s = @[7]
    discard s[int(i)]

proc guardOk(o: ptr int64): int32 {.exportc: "guard_ok", dynlib, cdecl, raises: [].} =
  ## Sets `*o` to 42, after raising and catching an exception internally.
  segGuard(nil):
    var v = 0'i64
    try:
      raise newException(ValueError, "caught inside")
    except ValueError:
      v = 42
    o[] = v

proc guardArgument(): int32 {.exportc: "guard_argument", dynlib, cdecl, raises: [].} =
  ## Fails with `SEG_ERR_ARGUMENT`.
  segGuard(nil):
    argError("bad argument")

proc guardLastError(): cstring {.exportc: "guard_last_error", dynlib, cdecl, raises: [].} =
  lastErrorPtr()
