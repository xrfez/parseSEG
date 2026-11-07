## parseSEGD: read and write SEG-Y and SEG-D seismic data on disk and tape.
##
## This umbrella module re-exports the public API. See `PLAN.md` for the
## roadmap and implementation status.

import parseSEGD/common/[errors, diagnostics, endians, bcd, ibmfloat, ebcdic, fieldlayout]
export errors, diagnostics, endians, bcd, ibmfloat, ebcdic, fieldlayout

import parseSEGD/segy/[textheader, binheader, traceheader]
export textheader, binheader, traceheader

import parseSEGD/io/[records, diskio, tapeimage, tapedevice]
export records, diskio, tapeimage, tapedevice
when defined(linux):
  import parseSEGD/io/tape_linux
  export tape_linux
elif defined(windows):
  import parseSEGD/io/tape_windows
  export tape_windows
