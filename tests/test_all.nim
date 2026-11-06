## Test suite for parsesegd.
## Exercises module functionality using the standard unittest framework.

import std/unittest
import ../src/parsesegd

suite "parsesegd test suite":
  test "basic initialization":
    check runApplication("test_run") == 0
