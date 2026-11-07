## parseSEGD: read and write SEG-Y and SEG-D seismic data on disk and tape.
##
## This umbrella module re-exports the public API. See `PLAN.md` for the
## roadmap and implementation status.

import parseSEGD/common/[errors, diagnostics, endians, bcd, ibmfloat, ebcdic, fieldlayout]
export errors, diagnostics, endians, bcd, ibmfloat, ebcdic, fieldlayout

import parseSEGD/segy/[textheader, binheader, traceheader, samples, exttext, layout, reader, writer, fields]
export textheader, binheader, traceheader, samples, exttext, layout, reader, writer, fields

import parseSEGD/segd/[headers as segdheaders, samples as segdsamples, rev3 as segdrev3,
  reader as segdreader, writer as segdwriter]
export segdheaders, segdsamples, segdrev3, segdreader, segdwriter

import parseSEGD/vendor/[maps, apply]
export maps, apply

import parseSEGD/model/[tensors, traceindex]
export tensors, traceindex

import parseSEGD/io/[records, diskio, memsource, tapeimage, tapedevice]
export records, diskio, memsource, tapeimage, tapedevice
when defined(linux):
  import parseSEGD/io/tape_linux
  export tape_linux
elif defined(windows):
  import parseSEGD/io/tape_windows
  export tape_windows
