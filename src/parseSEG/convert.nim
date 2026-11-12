## Conversion between revisions and standards (task 8.6), one module per
## target standard: `convert/tosegy` (`convertSegy`, `convertSegdToSegy`,
## `convertSeg2ToSegy`), `convert/tosegd` (`convertSegdRevision`,
## `convertSeg2ToSegd`) and `convert/toseg2` (`convertToSeg2`), each
## documenting its mapping. This module re-exports them and adds
## `convertFile`, which detects the input standard and dispatches on
## `ConvertOptions.target`: SEG-Y, SEG-D (`convertSegdRevision` for SEG-D
## input, `convertSeg2ToSegd` for SEG-2) or SEG-2 (`convertToSeg2`, from
## any standard).

import ./common/[errors, diagnostics, outputfile, progress]
import ./io/[records, diskio, memsource]
import ./segd/samples
import ./model/[traceindex, indexwalk]
import ./convert/[tosegy, tosegd, toseg2]
import ./private/progressticker

export tosegy, tosegd, toseg2

# ------------------------------------------------------------------- files --

proc recordFormats(srcPath: string, progress: Progress,
    cancelled: var bool): set[SegdSampleFormat] {.raises: [].} =
  # The formats of all records of a SEG-D file, from a header-only scan;
  # empty when the scan fails (the conversion reports what is wrong).
  try:
    let m = openMemFileSource(srcPath)
    try:
      let ix = buildIndex(m, skSegd, progress = progress)
      for c in ix.codecs:
        if c.segdFormat.isSome: result.incl c.segdFormat.get
    finally:
      m.close()
  except SegCancelledError:
    cancelled = true
  except CatchableError:
    result = {}

proc convertJoined*(srcPath, dstPath: string, opts: ConvertOptions,
    join: GeometryJoin, progress: Progress = nil): DiagLog {.raises: [].} =
  ## **Internal** (`convertWithGeometry`; not exported by `parseSEG`).
  ## `convertFile` with survey geometry joined to SEG-D keys (SEG-Y target).
  var head = newSeq[byte](8192)
  try:
    let f = open(srcPath, fmRead)
    try: head.setLen f.readBytes(head, 0, head.len)
    finally: f.close()
  except IOError as e:
    result.report(sevFatal, dcIo, "cannot read: " & e.msg, loc = Location(file: srcPath))
    return
  let kind = detectKind(head)
  if kind == skUnknown:
    result.report(sevFatal, dcUnsupportedFormat, "not a SEG-Y, SEG-D or SEG-2 file",
      loc = Location(file: srcPath))
    return
  case opts.target
  of skSeg2: return convertToSeg2(srcPath, dstPath, opts.seg2, progress)
  of skSegd:
    case kind
    of skSegd:
      try: return convertSegdRevision(srcPath, dstPath, opts.segd, progress)
      except CatchableError as e:
        result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
        return
    of skSeg2: return convertSeg2ToSegd(srcPath, dstPath, opts.segd, progress)
    else:
      result.report(sevFatal, dcUnsupportedFormat, "SEG-Y to SEG-D conversion is not " &
        "supported (only SEG-D and SEG-2 input)", loc = Location(file: srcPath))
      return
  of skUnknown:
    result.report(sevFatal, dcValidation, "the target standard is unknown (SEG-Y, SEG-D or " &
      "SEG-2)", loc = Location(file: dstPath))
    return
  of skSegy: discard
  if sameAsInput(srcPath, dstPath, result) or isDirectory(dstPath, result):
    return
  # SEG-D: one target format must hold every record, so the headers are
  # scanned first (a second pass over the input, for `progress`).
  let scan = kind == skSegd and opts.format == stKeep
  var cancelled = false
  let formats = if scan: recordFormats(srcPath, progressPhase(progress, 0, 2), cancelled)
                else: {}
  if cancelled:
    result.reportCancelled(dstPath)
    return
  let pass = if scan or kind == skSeg2: progressPhase(progress, 1, 2) else: progress
  let tmp = createTempFor(dstPath, result)
  if tmp.len == 0: return
  var src: RecordSource
  var sink: RecordSink
  var seg2: SeismicFile
  try:
    try:
      sink = openDiskSink(tmp)
      case kind
      of skSeg2:
        seg2 = openSeismic(srcPath, keys = true, progress = progressPhase(progress, 0, 2))
        result = convertSeg2ToSegy(seg2, sink, opts, pass)
      of skSegy:
        src = openDiskSource(srcPath)
        result = convertSegy(src, sink, opts, pass)
      else:
        src = openDiskSource(srcPath)
        result = convertSegdToSegyJoined(src, sink, opts, formats, join, pass)
    finally:
      if src != nil: src.close()
      if sink != nil: sink.close()
      seg2.close()
  except SegCancelledError:
    result.reportCancelled(dstPath)
  except CatchableError as e:
    result.report(sevFatal, dcIo, e.msg, loc = Location(file: dstPath))
  finishOutput(tmp, dstPath, keep = not result.isFatal, result)

proc convertFile*(srcPath, dstPath: string, opts = ConvertOptions(),
    progress: Progress = nil): DiagLog {.raises: [].} =
  ## Detects whether `srcPath` is SEG-Y, SEG-D or SEG-2 and converts it to
  ## `dstPath` in the standard `opts.target` names: SEG-Y (`convertSegy`,
  ## `convertSegdToSegy`, `convertSeg2ToSegy`), SEG-D (`convertSegdRevision`
  ## with `opts.segd` for SEG-D input, `convertSeg2ToSegd` for SEG-2; SEG-Y
  ## input is refused) or SEG-2 (`convertToSeg2` with `opts.seg2`). Never
  ## raises: problems, including I/O failures, are in the result. The output
  ## is written to a new temporary file next to `dstPath` (`<dstPath>.<random>.tmp`,
  ## created exclusively) and renamed when complete, so a failed conversion
  ## leaves an existing `dstPath` untouched and no partial file. For survey
  ## geometry in the output use `convertWithGeometry`.
  ##
  ## `progress` is called about every MiB of input with the bytes read and
  ## the input's size, and once at the end. Conversions that read the input
  ## twice (SEG-D with a format chosen from every record, SEG-2 input,
  ## SEG-D output) spread both passes over one `0 .. total` run. When it
  ## returns false the conversion stops: the result holds a fatal
  ## `dcCancelled` diagnostic and nothing is written.
  convertJoined(srcPath, dstPath, opts, GeometryJoin(), progress)
