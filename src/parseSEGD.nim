## parseSEGD: read and write SEG-Y and SEG-D seismic data on disk and tape.
##
## This umbrella module re-exports the stable public API; `docs/api.md`
## lists it. The low-level byte codecs (BCD, IBM float, EBCDIC, the field
## layout pragmas) are in `parseSEGD/codecs`; the C ABI is in
## `parseSEGD/capi` (`include/parseseg.h`).

import parseSEGD/common/[errors, diagnostics, endians]
export errors, diagnostics, endians

import parseSEGD/segy/[textheader, binheader, traceheader, samples, exttext, layout, reader, writer, fields]
export textheader, binheader, traceheader, samples, exttext, layout, reader, writer, fields

import parseSEGD/segd/[headers as segdheaders, samples as segdsamples, rev3 as segdrev3,
  reader as segdreader, writer as segdwriter]
export segdheaders, segdsamples, segdrev3, segdreader, segdwriter

import parseSEGD/vendor/[maps, apply]
export maps, apply

import parseSEGD/convert
export convert

import parseSEGD/model/[tensors, keys, traceindex, gathers, prefetch, headerfields, edit]
export tensors, keys, traceindex, gathers, prefetch, headerfields, edit

import parseSEGD/io/[records, diskio, memsource, tapeimage, tapedevice]
export records, diskio, memsource, tapeimage, tapedevice
when defined(linux):
  import parseSEGD/io/tape_linux
  export tape_linux
elif defined(windows):
  import parseSEGD/io/tape_windows
  export tape_windows
