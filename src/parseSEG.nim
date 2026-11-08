## parseSEG: read and write SEG-Y and SEG-D seismic data on disk and tape,
## read SEG-2, and the SPS and SEG P1 survey files that give it geometry.
##
## This umbrella module re-exports the stable public API; `docs/api.md`
## lists it. The low-level byte codecs (BCD, IBM float, EBCDIC, the field
## layout pragmas) are in `parseSEG/codecs`; the C ABI and the Python module
## are generated from `parseSEG/abi/api` (`include/parseseg.h`,
## `python/parseseg`).

import parseSEG/version
export version

import parseSEG/common/[errors, diagnostics, endians]
export errors, diagnostics, endians

import parseSEG/segy/[textheader, binheader, traceheader, samples, exttext, layout, reader,
  writer, fields]
export textheader, binheader, traceheader, samples, exttext, layout, reader, writer, fields

import parseSEG/segd/[headers as segdheaders, samples as segdsamples, rev3 as segdrev3,
  reader as segdreader, writer as segdwriter, revconvert as segdrevconvert, mux as segdmux,
  demux as segddemux]
export segdheaders, segdsamples, segdrev3, segdreader, segdwriter, segdrevconvert, segdmux,
  segddemux

import parseSEG/seg2/[headers as seg2headers, samples as seg2samples, reader as seg2reader]
export seg2headers, seg2samples, seg2reader

import parseSEG/vendor/[maps, apply, scaffold]
export maps, apply, scaffold

import parseSEG/convert
export convert

import parseSEG/model/[keys, traceindex, gathers, prefetch, headerfields, edit,
  headernif, summary, headerlist]
export traceindex except unsafeMemory, decodeEntry, readTracesRaw, mappedSize, flush,
  requireKeys, checkSpan, spanLen
export headerfields except locate, locateBlock, readField, FieldRef, FieldRead, withBlockType,
  isLayoutField, isNamedField, fieldValueOf
export keys, gathers, prefetch, edit, headernif, summary, headerlist

import parseSEG/survey/[textrec, sps, p1, join]
export textrec, sps, p1, join

import parseSEG/io/[records, diskio, memsource, tapeimage, tapedevice]
export records, diskio, memsource, tapeimage, tapedevice
when defined(linux):
  import parseSEG/io/tape_linux
  export tape_linux
elif defined(windows):
  import parseSEG/io/tape_windows
  export tape_windows
