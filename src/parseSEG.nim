## parseSEG: read and write SEG-Y and SEG-D seismic data on disk and tape,
## SEG-2 on disk, and the SPS and SEG P1 survey files that give it geometry.
##
## This umbrella module re-exports the stable public API; `docs/api.md`
## lists it. The low-level byte codecs (BCD, IBM float, EBCDIC, the field
## layout pragmas) are in `parseSEG/codecs`.

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

import parseSEG/seg2/[headers as seg2headers, samples as seg2samples, reader as seg2reader,
  writer as seg2writer]
export seg2headers, seg2samples, seg2reader, seg2writer

import parseSEG/vendor/[maps, apply, scaffold]
export maps, apply, scaffold

import parseSEG/[convert, seg2convert]
export convert, seg2convert

import parseSEG/model/[keys, traceindex, gathers, prefetch, headerfields, edit,
  headernif, summary, headerlist]
export traceindex except unsafeMemory, decodeEntry, readTracesRaw, mappedSize, flush,
  requireKeys, checkSpan, spanLen
export headerfields except locate, locateBlock, readField, FieldRef, FieldRead, withBlockType,
  isLayoutField, isNamedField, fieldValueOf
export keys, gathers, prefetch, headernif, summary, headerlist
export edit except writeBytes, flushPending, batching

import parseSEG/survey/[textrec, sps, p1, join, writeback]
export textrec, sps, p1, join, writeback

import parseSEG/io/[records, diskio, memsource, tapeimage, tapedevice]
export records, diskio, memsource, tapeimage, tapedevice
when defined(linux):
  import parseSEG/io/tape_linux
  export tape_linux
elif defined(windows):
  import parseSEG/io/tape_windows
  export tape_windows
