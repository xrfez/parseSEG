## Gather detection and multi-component grouping (task 6.2).
##
## The library never assumes shot gathers: node data is often packed as
## receiver gathers in standard SEG-D or SEG-Y with minimal header changes.
## `gathers` splits an index (built with `keys = true`) into gathers and
## derives each one's kind from its geometry:
##
## - at most one known source and several receivers: a shot (common
##   source) gather;
## - one receiver and several sources: a receiver gather;
## - one receiver, at most one source: a shot if it is a single trace or one
##   trace per component, else `gkUnknown` (the keys cannot tell);
## - several of both: `gkOther`.
##
## A SEG-Y sorting code of CMP/stack (2-4, 8, 9) or common offset (7) names
## the gathers outright; common receiver (6) does unless the geometry is
## plainly a shot (one source, several receivers).
##
## Nothing is assumed: a gather whose keys cannot tell (e.g. a SEG-D 2.x
## receiver gather whose sources live only in vendor blocks) is `gkUnknown`.
##
## Splitting: a SEG-D record is one gather. SEG-Y has no record structure, so
## the trace sorting code (binary 3229-3230) picks the key whose changes
## separate gathers: the ensemble number for sorted data (2-4, 6, 8, 9), the
## offset for common-offset data (7), else the field record number. A key
## that never changes falls back to the receiver station (sort 6) or the
## field record. SEG-2 files split the same way, with TRACE_SORT read as the
## SEG-Y code it names (AS_ACQUIRED 1, CDP_GATHER 2, CDP_STACK 4,
## COMMON_SOURCE 5, COMMON_RECEIVER 6, COMMON_OFFSET 7); the record key is
## SHOT_SEQUENCE_NUMBER.
##
## Only seismic traces count: SEG-D auxiliary channel sets and SEG-2
## TEST_DATA / UPHOLE traces are ignored when classifying and grouping.
## Stations are compared on every known key (line, point, index,
## coordinates); unknown values (NaN) match each other.
##
## `componentGroups` collects the traces of one station recorded from one
## source: the components of a multi-component receiver (Rev 3 group index,
## else the sensor type; SEG-Y trace identification codes 11-17 and 27-41).

import std/[tables, sets, math, options]
import ./[traceindex, keys]
import ../private/checks
from ../seg2/headers import Seg2TraceType, Seg2TraceSort, traceSort
from ../segd/reader import isRev3

type
  GatherKind* = enum
    ## What a gather holds, derived from its geometry (see the module doc).
    gkUnknown = "unknown"   ## The keys cannot tell.
    gkShot = "shot"         ## Common source.
    gkReceiver = "receiver" ## Common receiver.
    gkCmp = "cmp"           ## Common midpoint / CDP / stack (declared by SEG-Y).
    gkOffset = "offset"     ## Common offset (declared by SEG-Y).
    gkOther = "other"       ## Several sources and several receivers.

  Gather* = object
    ## A run of consecutive traces that form one gather.
    kind*: GatherKind
    traces*: Slice[int]     ## Trace indices into the index.
    sources*: int           ## Distinct known sources among its seismic traces.
    receivers*: int         ## Distinct known receiver stations among its seismic traces.

  ComponentGroup* = object
    ## The traces of one receiver station from one source.
    station*: TraceKeys     ## Keys of the group's first trace.
    traces*: seq[int]       ## Trace indices, in file order.
    components*: seq[uint8] ## Component of each trace (parallel to `traces`).

  StationId = array[5, uint64]

  SplitKey = enum
    ## The key whose changes separate SEG-Y gathers.
    byRecord, byEnsemble, byOffset, byReceiver

func bitsOf(x: float64): uint64 {.inline.} =
  # Bit pattern with one NaN and one zero, so equal keys hash equally.
  if x.isNaN: 0x7FF8_0000_0000_0000'u64 else: cast[uint64](x + 0.0)

func sourceId(k: TraceKeys): StationId =
  [bitsOf(k.srcLine), bitsOf(k.srcPoint), uint64(cast[uint16](k.srcIndex)), bitsOf(k.srcX),
    bitsOf(k.srcY)]

func receiverId(k: TraceKeys): StationId =
  [bitsOf(k.rcvLine), bitsOf(k.rcvPoint), uint64(cast[uint16](k.rcvIndex)), bitsOf(k.rcvX),
    bitsOf(k.rcvY)]

func knownSource(k: TraceKeys): bool =
  not (k.srcLine.isNaN and k.srcPoint.isNaN and k.srcX.isNaN and k.srcY.isNaN)

func knownReceiver(k: TraceKeys): bool =
  not (k.rcvLine.isNaN and k.rcvPoint.isNaN and k.rcvX.isNaN and k.rcvY.isNaN)

func isSeismic*(ix: TraceIndex, i: int): bool =
  ## False for SEG-D auxiliary traces (channel type other than seismic or
  ## EM) and SEG-2 TEST_DATA and UPHOLE traces; true for SEG-Y and for traces
  ## of unknown channel sets.
  let e = ix.entries[i]
  if ix.kind == skSeg2:
    e.channelType notin {uint8(ord(ttTestData) + 1), uint8(ord(ttUphole) + 1)}
  elif ix.kind == skSegy or e.channelSet == NoChannelSet: true
  elif ix.segdRecords[e.record].isRev3: e.channelType in {0x10'u8, 0x11'u8}
  else: e.channelType == 1

proc classify*(ix: TraceIndex, s: Slice[int]): Gather =
  ## Counts the distinct sources and receivers of the seismic traces in `s`
  ## (all traces, if none is seismic) and derives the gather kind from them;
  ## `gkUnknown` when the receivers are unknown.
  ix.requireKeys()
  result = Gather(traces: s)
  var anySeismic = false
  for i in s:
    if ix.isSeismic(i): anySeismic = true
  var src, rcv: HashSet[StationId]
  var n = 0
  var components: set[uint8]
  for i in s:
    if ix.isSeismic(i) or not anySeismic:
      template k: untyped = ix.keys[i]
      if knownSource(k): src.incl sourceId(k)
      if knownReceiver(k): rcv.incl receiverId(k)
      components.incl k.component
      inc n
  result.sources = src.len
  result.receivers = rcv.len
  result.kind =
    if rcv.len == 0: gkUnknown
    elif src.len <= 1 and rcv.len > 1: gkShot
    elif rcv.len == 1 and src.len > 1: gkReceiver
    elif rcv.len == 1:
      # One station, at most one source: a shot when it is one trace or the
      # components of one multi-component station; else the keys do not tell.
      if n == 1 or components.card == n: gkShot else: gkUnknown
    else: gkOther

func sameKey(a, b: TraceKeys, by: SplitKey): bool =
  case by
  of byRecord: bitsOf(a.record) == bitsOf(b.record)
  of byEnsemble: bitsOf(a.ensemble) == bitsOf(b.ensemble)
  of byOffset: bitsOf(a.offset) == bitsOf(b.offset)
  of byReceiver: receiverId(a) == receiverId(b)

proc constantKey(ix: TraceIndex, by: SplitKey): bool =
  result = true
  for i in 1..<ix.len:
    if not sameKey(ix.keys[i], ix.keys[0], by): return false

func sortingCode(s: Option[Seg2TraceSort]): int =
  # The SEG-Y trace sorting code a SEG-2 TRACE_SORT names; 0 if none.
  if s.isNone: 0
  else:
    case s.get
    of tsAsAcquired: 1
    of tsCdpGather: 2
    of tsCdpStack: 4
    of tsCommonSource: 5
    of tsCommonReceiver: 6
    of tsCommonOffset: 7

proc gathers*(ix: TraceIndex): seq[Gather] =
  ## Splits the index into gathers and classifies each (see the module doc).
  ## Needs an index built with `keys = true`.
  ix.requireKeys()
  if ix.len == 0: return
  if ix.kind == skSegd:
    var first = 0
    for i in 1..ix.len:
      if i == ix.len or ix.entries[i].record != ix.entries[first].record:
        result.add ix.classify(first..i - 1)
        first = i
  else:
    let sorting = if ix.kind == skSeg2: sortingCode(ix.seg2.traceSort)
                  else: int(ix.segy.binary.traceSorting)
    var declared = gkUnknown
    var by = byRecord
    case sorting
    of 2, 3, 4, 8, 9: (declared, by) = (gkCmp, byEnsemble)
    of 6: (declared, by) = (gkReceiver, byEnsemble)
    of 7: (declared, by) = (gkOffset, byOffset)
    else: discard
    if by != byRecord and ix.len > 1 and ix.constantKey(by):
      by = if sorting == 6: byReceiver else: byRecord
    var first = 0
    for i in 1..ix.len:
      if i == ix.len or not sameKey(ix.keys[i], ix.keys[first], by):
        var g = ix.classify(first..i - 1)
        if declared in {gkCmp, gkOffset}:
          g.kind = declared
        elif declared == gkReceiver and not (g.kind == gkShot and g.receivers > 1):
          g.kind = declared # unless the geometry is plainly a shot
        result.add g
        first = i

type GroupKey = (StationId, StationId, uint8, uint8)

func groupKey(k: TraceKeys): GroupKey {.inline.} =
  (sourceId(k), receiverId(k), k.depthIndex, k.reshootIndex)

proc componentGroups*(ix: TraceIndex, traces: Slice[int]): seq[ComponentGroup] =
  ## Groups the seismic traces of `traces` by (source, receiver station,
  ## depth index, reshoot index), in order of first appearance. Raises
  ## `ValueError` for traces outside the index (an empty range must still
  ## start in `0 .. ix.len`) or an index built without `keys = true`.
  ix.requireKeys()
  checkSpan(traces, ix.len)
  var at: Table[GroupKey, int]
  for i in traces:
    if ix.isSeismic(i):
      template k: untyped = ix.keys[i]
      let key = groupKey(k)
      var g = at.getOrDefault(key, -1)
      if g < 0:
        g = result.len
        at[key] = g
        result.add ComponentGroup(station: k)
      result[g].traces.add i
      result[g].components.add k.component

func isMultiComponent*(g: ComponentGroup): bool =
  ## True when the group holds more than one distinct component.
  for c in g.components:
    if c != g.components[0]: return true

proc gathers*(f: SeismicFile): seq[Gather] =
  ## The file's gathers: `f.index.gathers`.
  f.index.gathers

proc componentGroups*(f: SeismicFile, traces: Slice[int]): seq[ComponentGroup] {.inline.} =
  ## `f.index.componentGroups(traces)`.
  f.index.componentGroups(traces)

proc componentGroupIds*(f: SeismicFile, traces: Slice[int]): seq[int] =
  ## The component group of each trace of `traces` (see `componentGroups`),
  ## numbered from 0 in order of first appearance; -1 for a trace in none
  ## (an auxiliary trace).
  # One table from group key to id, no per-group objects: 10 M traces with
  # 10 M groups would otherwise build 10 M groups of seqs and key copies.
  template ix: untyped = f.index
  ix.requireKeys()
  checkSpan(traces, ix.len)
  result = newSeq[int](traces.spanLen)
  var at: Table[GroupKey, int]
  for i in traces:
    var g = -1
    if ix.isSeismic(i):
      let key = groupKey(ix.keys[i])
      g = at.getOrDefault(key, -1)
      if g < 0:
        g = at.len
        at[key] = g
    result[i - traces.a] = g
