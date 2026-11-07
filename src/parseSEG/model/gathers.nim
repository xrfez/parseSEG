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
## field record.
##
## Only seismic traces count: SEG-D auxiliary channel sets are ignored when
## classifying and grouping. Stations are compared on every known key
## (line, point, index, coordinates); unknown values (NaN) match each other.
##
## `componentGroups` collects the traces of one station recorded from one
## source: the components of a multi-component receiver (Rev 3 group index,
## else the sensor type; SEG-Y trace identification codes 11-17 and 27-41).

import std/[tables, math]
import ./[traceindex, keys]

type
  GatherKind* = enum
    gkUnknown = "unknown"
    gkShot = "shot"         ## Common source.
    gkReceiver = "receiver" ## Common receiver.
    gkCmp = "cmp"           ## Common midpoint / CDP / stack (declared by SEG-Y).
    gkOffset = "offset"     ## Common offset (declared by SEG-Y).
    gkOther = "other"       ## Several sources and several receivers.

  Gather* = object
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
  ## EM); true for SEG-Y and for traces of unknown channel sets.
  let e = ix.entries[i]
  if ix.kind == skSegy or e.channelSet == NoChannelSet: true
  elif ix.segdRecords[e.record].isRev3: e.channelType in {0x10'u8, 0x11'u8}
  else: e.channelType == 1

proc requireKeys(ix: TraceIndex) =
  doAssert ix.keys.len == ix.entries.len, "build the index with keys = true"

proc classify*(ix: TraceIndex, s: Slice[int]): Gather =
  ## Counts the distinct sources and receivers of the seismic traces in `s`
  ## (all traces, if none is seismic) and derives the gather kind from them;
  ## `gkUnknown` when the receivers are unknown.
  ix.requireKeys()
  result = Gather(traces: s)
  var anySeismic = false
  for i in s:
    if ix.isSeismic(i): anySeismic = true
  var src, rcv: Table[StationId, int]
  var n = 0
  var components: set[uint8]
  for i in s:
    if ix.isSeismic(i) or not anySeismic:
      let k = ix.keys[i]
      if knownSource(k): src[sourceId(k)] = 1
      if knownReceiver(k): rcv[receiverId(k)] = 1
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

func sameKey(a, b: TraceKeys, by: int): bool =
  case by
  of 0: bitsOf(a.record) == bitsOf(b.record)
  of 1: bitsOf(a.ensemble) == bitsOf(b.ensemble)
  of 2: bitsOf(a.offset) == bitsOf(b.offset)
  else: receiverId(a) == receiverId(b)

proc constantKey(ix: TraceIndex, by: int): bool =
  result = true
  for i in 1..<ix.len:
    if not sameKey(ix.keys[i], ix.keys[0], by): return false

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
    let sorting = int(ix.segy.binary.traceSorting)
    var declared = gkUnknown
    var by = 0 # 0 record, 1 ensemble, 2 offset, 3 receiver station
    case sorting
    of 2, 3, 4, 8, 9: (declared, by) = (gkCmp, 1)
    of 6: (declared, by) = (gkReceiver, 1)
    of 7: (declared, by) = (gkOffset, 2)
    else: discard
    if by != 0 and ix.len > 1 and ix.constantKey(by):
      by = if sorting == 6: 3 else: 0
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

proc componentGroups*(ix: TraceIndex, s: Slice[int]): seq[ComponentGroup] =
  ## Groups the seismic traces of `s` by (source, receiver station, depth
  ## index, reshoot index), in order of first appearance. Needs an index
  ## built with `keys = true`.
  ix.requireKeys()
  var at: Table[(StationId, StationId, uint8, uint8), int]
  for i in s:
    if ix.isSeismic(i):
      let k = ix.keys[i]
      let key = (sourceId(k), receiverId(k), k.depthIndex, k.reshootIndex)
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
