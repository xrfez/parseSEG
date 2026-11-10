## The trace index's data: where each trace lives (`TraceEntry`), how its
## samples are encoded (`TraceCodec`), and the whole index with the file
## headers (`TraceIndex`). `model/traceindex` builds and reads it and
## re-exports this module.

import ../common/[endians, diagnostics, seismickind]
import ../segy/[reader as segyreader]
import ../segd/[reader as segdreader]
import ../seg2/[reader as seg2reader]
import ./keys

type
  VerifyMode* = enum
    ## How `openSeismic` checks the trace headers of a fixed-length SEG-Y
    ## file (Rev 1 or later, binary header bytes 3503-3504 = 1).
    vfSampled ## Index computed from the file size; a sample of headers checked.
    vfFull    ## Every trace header walked, as for any other file.

  OpenOptions* = object
    ## The rarely changed settings of `openSeismic` (see there). The
    ## defaults suit almost every open.
    verify*: VerifyMode = vfSampled
      ## `vfSampled`: a fixed-length SEG-Y file is indexed from its size,
      ## with a sample of its headers checked; `vfFull` walks every header.
    cache*: string ## An index cache written by `saveIndex`; "" for none.
    demuxDir*: string
      ## Where a multiplexed SEG-D file's demultiplexed copy goes; "" for the
      ## OS temp directory.
    twosComplement8015*: bool ## Read SEG-2 format-3 mantissas as two's complement.

  TraceEntry* = object
    ## Where one trace lives (24 bytes).
    offset*: int64       ## Medium offset of the trace header.
    headerBytes*: uint32 ## Header bytes before the samples (incl. extensions).
    numSamples*: uint32
    record*: uint32
      ## Indexes `codecs`: the SEG-D record index, 0 for SEG-Y, the codec of
      ## the trace's sample format for SEG-2 (a SEG-2 file is one record).
    channelSet*: uint16
      ## 0-based SEG-D channel set index, `NoChannelSet` if unknown (and for
      ## SEG-Y); see `channelSetIndex`.
    scanType*: int8      ## 0-based SEG-D scan type index (BCD, < 100), -1 if unknown (SEG-Y).
    channelType*: uint8
      ## SEG-D channel type of the trace's channel set (Rev 1/2 nibble, 1 =
      ## seismic; Rev 3 byte, 0x10 = seismic); 0 for SEG-Y and unknown sets.
      ## SEG-2: 1 + the `Seg2TraceType` ordinal of TRACE_TYPE, 0 if none.

  TraceCodec* = object
    ## How the samples of one SEG-Y file, SEG-D record or SEG-2 sample
    ## format are encoded.
    kind*: SeismicKind
    segyFormat*: Option[SampleFormat]
      ## SEG-Y format, when `kind == skSegy`; none if not decodable.
    order*: ByteOrder             ## SEG-Y and SEG-2 byte order.
    segdFormat*: Option[SegdSampleFormat]
      ## SEG-D format, when `kind == skSegd`; none if not decodable.
    seg2Format*: Option[Seg2SampleFormat]
      ## SEG-2 format, when `kind == skSeg2`; none if not decodable.
    twosComplement8015*: bool
      ## SEG-D 8015 (and SEG-2 format 3) mantissas read as two's complement.

  JoinGroup* = enum
    ## Groups of `TraceKeys` fields that a join can change.
    jgCoordinates ## Source and receiver X/Y/Z, the offset and the midpoint.
    jgStations    ## Source and receiver line, point and point index, and the component.

  TraceIndex* = object
    ## Every trace's location plus the file-level headers.
    kind*: SeismicKind
    entries*: seq[TraceEntry]
    codecs*: seq[TraceCodec]
      ## One per SEG-D record; one for SEG-Y; one per sample format for SEG-2.
    contiguous*: bool
      ## Offsets are byte offsets in a plain file, so each trace's headers and
      ## samples are contiguous there (false for tape images and devices, and
      ## for multiplexed SEG-D).
    maxSamples*: int          ## Largest `numSamples`.
    segy*: SegyFile           ## SEG-Y file headers, when `kind == skSegy`.
    segdLabel*: Option[SegdStorageUnitLabel] ## The SEG-D storage unit label, if any.
    segdRecords*: seq[SegdRecord] ## SEG-D record headers and trailers, by record index.
    segdToc*: seq[SegdToc]    ## SEG-D Rev 3 Table of Contents files met.
    seg2*: Seg2File
      ## The SEG-2 File Descriptor Block, when `kind == skSeg2` (trace
      ## descriptors are re-read from the map: `SeismicFile.seg2Trace`).
    log*: DiagLog             ## Diagnostics of the walk.
    detected*: bool           ## The stream was identified as `kind` and walked.
    keys*: seq[TraceKeys]
      ## Per-trace geometry, parallel to `entries`; empty unless the index was
      ## built with `keys = true` (184 bytes per trace).
    segyIntervalUs*: float64
      ## SEG-Y: the effective sample interval every trace shares (µs for time
      ## data), NaN when traces differ or there are none; 0 for SEG-D (see
      ## `summary`).
    joined*: bool
      ## `keys` were changed by `applyGeometry` or `applySurvey`, so they are
      ## no longer the file's own (`saveIndex` refuses such an index).
    joinedTraces*: seq[set[JoinGroup]]
      ## Per trace, the groups of keys a join (`applyGeometry`, `applySurvey`)
      ## changed; empty until a join changes one. A `HeaderEditor` keeps these
      ## values when it refreshes a trace's keys from its edited headers.
    keysRevision*: int
      ## 0 as opened; goes up whenever `keys` change (`ensureKeys`,
      ## `applyGeometry`, `applySurvey`, `HeaderEditor` writes). Data derived
      ## from the keys can be tagged with it and rebuilt when it changes.

const NoChannelSet* = 0xFFFF'u16
  ## `TraceEntry.channelSet` of a trace without a known channel set. The
  ## reader allows at most 65535 sets per scan type, so index 65535 is free.

static: doAssert sizeof(TraceEntry) == 24

proc markJoined*(ix: var TraceIndex, trace: int, groups: set[JoinGroup]) =
  ## Records that a join changed the `groups` of trace `trace`'s keys
  ## (`joinedTraces`), for code that joins geometry itself. It does not bump
  ## `keysRevision`: the joining code does, once per join that changed keys.
  if groups == {}: return
  if ix.joinedTraces.len != ix.keys.len: ix.joinedTraces.setLen ix.keys.len
  ix.joinedTraces[trace].incl groups

func joinedGroups*(ix: TraceIndex, trace: int): set[JoinGroup] {.inline.} =
  ## The groups of trace `trace`'s keys a join changed (none before a join).
  if trace < ix.joinedTraces.len: ix.joinedTraces[trace] else: {}

func channelSetIndex*(e: TraceEntry): int {.inline.} =
  ## The 0-based channel set index, -1 if unknown.
  if e.channelSet == NoChannelSet: -1 else: int(e.channelSet)

func len*(ix: TraceIndex): int {.inline.} =
  ## The number of traces indexed.
  ix.entries.len

func sampleOffset*(e: TraceEntry): int64 {.inline.} =
  ## Medium offset of the trace's first sample byte.
  e.offset + int64(e.headerBytes)

func known*(c: TraceCodec): bool {.inline.} =
  ## True when the samples are decodable (the format is known).
  case c.kind
  of skSegy: c.segyFormat.isSome
  of skSegd: c.segdFormat.isSome
  of skSeg2: c.seg2Format.isSome
  of skUnknown: false

func dataBytes*(c: TraceCodec, samples: int): int =
  ## Bytes holding `samples` samples (0 for an undecodable format).
  if not c.known: 0
  else:
    case c.kind
    of skSegy: samples * sampleSize(c.segyFormat.get)
    of skSegd: dataBytes(c.segdFormat.get, samples)
    of skSeg2: dataBytes(c.seg2Format.get, samples)
    of skUnknown: 0

func dataBytes*(ix: TraceIndex, i: int): int {.inline.} =
  ## Sample bytes of trace `i`.
  ix.codecs[ix.entries[i].record].dataBytes(int(ix.entries[i].numSamples))

func prefersFloat64*(ix: TraceIndex): bool =
  ## True when some trace's format would lose precision in float32.
  for c in ix.codecs:
    if c.known:
      let wide = case c.kind
        of skSegy: prefersFloat64(c.segyFormat.get)
        of skSegd: prefersFloat64(c.segdFormat.get)
        of skSeg2: prefersFloat64(c.seg2Format.get)
        of skUnknown: false
      if wide: return true
