## parseSEG: read and write SEG-Y and SEG-D seismic data on disk and tape,
## SEG-2 on disk, and the SPS and SEG P1 survey files that give it geometry.
##
## This umbrella module re-exports the stable public API; `docs/api.md`
## lists it. Modules that also export internals for the library's own use
## (`traceindex`, `headerfields`, `edit`, `convert`, `convert/tosegy`) are
## re-exported by name, an allowlist that no later re-export can widen; the
## rest whole. The
## library's helpers live in `parseSEG/private/`, which nothing re-exports.
## The low-level byte codecs (BCD, IBM float, EBCDIC, the field
## layout pragmas) are in `parseSEG/codecs`.

import parseSEG/version
export version

import parseSEG/common/[errors, diagnostics, endians]
export errors, diagnostics, endians

import parseSEG/segy/[textheader, binheader, traceheader, samples, exttext, layout, reader,
  writer, fields]
export textheader, binheader, traceheader, exttext, layout, reader, writer, fields
export samples except decodeSamplesRaw

import parseSEG/segd/[headers as segdheaders, samples as segdsamples, rev3 as segdrev3,
  reader as segdreader, writer as segdwriter, mux as segdmux,
  demux as segddemux]
export segdsamples except decodeSamplesRaw
export segdheaders, segdrev3, segdreader, segdwriter, segdmux,
  segddemux

import parseSEG/seg2/[headers as seg2headers, samples as seg2samples, reader as seg2reader,
  writer as seg2writer]
export seg2samples except decodeSamplesRaw
export seg2headers, seg2reader, seg2writer

import parseSEG/vendor/[maps, apply, scaffold]
export maps, apply, scaffold

import parseSEG/convert
import parseSEG/convert/[tosegy, tosegd, toseg2]
export tosegy.SegyTargetFormat, tosegy.ConvertOptions, tosegy.targetFormat, tosegy.convertSegy,
  tosegy.convertSegdToSegy, tosegy.convertSeg2ToSegy, convert.convertFile
export tosegd, toseg2

import parseSEG/model/[keys, keytypes, indextypes, indexwalk, traceindex, gathers, prefetch,
  fieldvalues, headerfields, edit, headernif, summary, headerlist, sorting, writefile, tracerows, statics]
import parseSEG/common/[seismickind, progress, tensors]
export seismickind, progress, keys, keytypes, indextypes, indexwalk, tensors, fieldvalues
# Allowlists: traceindex, edit, convert and tosegy also export helpers that need
# their private fields (for the library's own modules), so their public
# names are listed one by one, as are headerfields'. A new public name goes
# here and in docs/api.md (tdocs checks both).
export traceindex.SeismicFile, traceindex.openSeismic, traceindex.close, traceindex.isOpen,
  traceindex.path, traceindex.fromCache, traceindex.demuxPath, traceindex.len,
  traceindex.kind, traceindex.log, traceindex.recordCount, traceindex.maxSamples,
  traceindex.traceEntry, traceindex.hasKeys, traceindex.traceKeys, traceindex.traceKeysInto,
  traceindex.startTimeMs, traceindex.startTimeMsInto, traceindex.ensureKeys,
  traceindex.keysRevision,
  traceindex.seg2Trace, traceindex.textHeader, traceindex.extendedTextHeaders,
  traceindex.copyBytes, traceindex.readTracesInto, traceindex.readTraces,
  traceindex.applyGeometry, traceindex.saveIndex, traceindex.index
export headerfields.fieldNames, headerfields.fieldByName, headerfields.traceField,
  headerfields.recordField, headerfields.fileField, headerfields.findTraceField,
  headerfields.findRecordField, headerfields.findFileField, headerfields.blockKind,
  headerfields.seg2Strings, headerfields.sampleIntervalUs, headerfields.traceFieldColumn,
  headerfields.traceFieldColumnInto
export edit.HeaderEditor, edit.openEditor, edit.close, edit.release, edit.file, edit.log,
  edit.journalPath, edit.edits, edit.beginBatch, edit.endBatch, edit.currentTraceField,
  edit.currentRecordField, edit.currentFileField, edit.setTraceField, edit.setRecordField,
  edit.setFileField, edit.JournalEdit, edit.readJournal, edit.rollbackJournal,
  edit.applyJournal
export gathers, prefetch, headernif, summary, headerlist, sorting, writefile, tracerows,
  statics

import parseSEG/survey/[textrec, sps, p1, join, writeback]
export textrec, sps, p1, join
export writeback except KeysPlan, planKeys, finishKeys # internal: model/writefile

import parseSEG/io/[records, diskio, memsource, tapeimage, tapedevice]
export records, diskio, memsource, tapeimage, tapedevice
when defined(linux):
  import parseSEG/io/tape_linux
  export tape_linux
elif defined(windows):
  import parseSEG/io/tape_windows
  export tape_windows
