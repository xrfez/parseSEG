## Output files written through a temporary file: the data goes to
## `<path>.tmp`, which is renamed to `path` only when the write is complete,
## so a failed write leaves an existing `path` untouched and no partial file
## behind. Used by the file-level writers and converters; not re-exported.

import std/os
import ./[diagcodes, diagnostics]

func tmpPathFor*(path: string): string {.inline.} =
  ## The temporary file `path` is written through.
  path & ".tmp"

proc sameAsInput*(src, dst: string, log: var DiagLog): bool {.raises: [].} =
  ## True, with a fatal diagnostic, when `dst` is the existing file `src`:
  ## writing it would destroy the input.
  try:
    result = fileExists(dst) and sameFile(src, dst)
  except OSError:
    result = false # `src` cannot be inspected; reading it reports why
  if result:
    log.report(sevFatal, dcValidation, "the output is the input file; refusing to overwrite it",
      loc = Location(file: dst))

proc finishOutput*(tmp, path: string, keep: bool, log: var DiagLog) {.raises: [].} =
  ## Renames the complete output `tmp` to `path` when `keep`, else removes
  ## `tmp`. A failure to do either is logged as fatal.
  try:
    if not fileExists(tmp):
      discard
    elif keep:
      moveFile(tmp, path)
    else:
      removeFile(tmp)
  except OSError, IOError:
    let what = if keep: "cannot move the output into place: "
               else: "cannot remove the incomplete output: "
    log.report(sevFatal, dcIo, what & getCurrentExceptionMsg(), loc = Location(file: path))
