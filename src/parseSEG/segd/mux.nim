## Multiplexed SEG-D (Rev 0 and Rev 1 format codes 0015 ... 0058) on byte
## buffers: the scan layout, the start-of-scan and timing word, and
## demultiplexing one channel into the demultiplexed format's bytes (spec
## notes `segd_rev0.md` §2.3, §3.6, §5, `segd_rev2_1.md` §4).
##
## A multiplexed data body is a sequence of scans of `bytesPerScan` bytes
## (GH#1 bytes 20-22). Each scan starts with a 4-byte start-of-scan code and
## a 4-byte timing word, then holds, for each channel set of the scan type in
## descriptor order, `2^subscanExponent` subscans of one sample per channel.
##
## Each multiplexed code has a demultiplexed twin (0015 → 8015, 0022 → 8022,
## ...). Except for 0015, a sample has the same bytes in both, so
## demultiplexing only regroups bytes. 0015 packs four *channels* in 10 bytes
## and its 15-bit word does not use the LSB; 8015 packs four *samples* and
## uses it. `demuxChannel` transcodes 0015 to 8015 exactly (see there), so
## the 8015 decoders give the 0015 values.
##
## | Code | Format (as 80xx) | Bytes per sample |
## |---|---|---|
## | 0015 | 20-bit binary exponent | 10 per 4 channels |
## | 0022 / 0024 | quaternary exponent | 1 / 2 |
## | 0036 / 0038 | two's complement integer (Rev 1) | 3 / 4 |
## | 0042 / 0044 | hexadecimal exponent | 1 / 2 |
## | 0048 | hexadecimal excess-64 | 4 |
## | 0058 | IEEE single (Rev 1) | 4 |

import std/options
import ../common/[endians, bcd]
import ./[blocks, samples]

const
  ScanHeaderSize* = 8 ## Start-of-scan code (4 bytes) plus timing word (4 bytes).
  muxCodes = [15, 22, 24, 36, 38, 42, 44, 48, 58]

type
  ScanHeader* = object
    ## The start-of-scan code and timing word that begin a multiplexed scan.
    twi*: bool  ## Time-break window indicator: 1 after the time-break window closed.
    itb*: bool  ## Internal time break (abnormal sync condition).
    dp*: bool   ## Dynamic parameter change: toggles at each new scan type.
    timing*: array[3, byte] ## Timing word, `u16.u8` ms (wraps after 65,536 ms).
    byte8*: uint8 ## Byte 8, which the spec sets to 0.

  MuxChannelSet* = object
    ## Where one channel set's samples lie in a multiplexed scan.
    offset*: int       ## Byte offset of its first subscan within the scan.
    channels*: int     ## Channels (0 for a dummy descriptor).
    subscans*: int     ## Subscans per scan, 2^subscanExponent.
    subscanBytes*: int ## Bytes of one subscan (all channels).
    firstSample*: int
      ## Index of its first sample in the scan's sample order, which is also
      ## the index of its first skew byte.

  MuxScanLayout* = object
    ## The layout of one scan type's scans.
    channelSets*: seq[MuxChannelSet] ## One per channel set descriptor.
    bytesPerScan*: int ## Bytes the layout needs, start of scan and timing word included.

func isMultiplexedCode*(code: int): bool {.inline.} =
  ## True for the multiplexed codes 0015 ... 0058 that this module demultiplexes.
  code in muxCodes

func demuxFormat*(code: int): Option[SegdSampleFormat] =
  ## The demultiplexed twin of a multiplexed format code (0015 → 8015, ...);
  ## none for any other code.
  if code.isMultiplexedCode: toSegdFormat(8000 + code) else: none(SegdSampleFormat)

func muxBytes*(code, channels: int): int =
  ## Bytes holding one sample of each of `channels` channels in format `code`
  ## (0015 packs four channels in 10 bytes; a count that is not a multiple of
  ## 4, which the spec forbids, is rounded up). 0 for a code that is not
  ## multiplexed.
  case code
  of 15: (channels + 3) div 4 * 10
  of 22, 42: channels
  of 24, 44: 2 * channels
  of 36: 3 * channels
  of 38, 48, 58: 4 * channels
  else: 0

func muxLayout*(code: int, descriptors: openArray[SegdChannelSetDescriptor]): MuxScanLayout =
  ## The scan layout of a scan type with these channel set descriptors, in
  ## format `code`. A descriptor whose channel count is 0 or not BCD adds no
  ## bytes; a subscan exponent outside 0-9 counts as 0.
  result = MuxScanLayout(bytesPerScan: ScanHeaderSize)
  var first = 0
  for c in descriptors:
    let channels = max(c.channelCount, 0)
    let subscans = 1 shl (if c.subscanExponent in 0..9: c.subscanExponent else: 0)
    let b = muxBytes(code, channels)
    result.channelSets.add MuxChannelSet(offset: result.bytesPerScan, channels: channels,
      subscans: subscans, subscanBytes: b, firstSample: first)
    result.bytesPerScan += subscans * b
    first += subscans * channels

func isStartOfScan*(b: openArray[byte], pos = 0): bool {.inline.} =
  ## True when `b[pos ..< pos + 4]` is a start-of-scan code: `FF FF FF`, then
  ## a byte whose two low bits are `01`.
  pos + 4 <= b.len and b[pos] == 0xFF and b[pos + 1] == 0xFF and b[pos + 2] == 0xFF and
    (b[pos + 3] and 0x03) == 0x01

func scanHeader*(b: openArray[byte], pos = 0): ScanHeader =
  ## Decodes the start-of-scan flags and the timing word of the scan at `pos`
  ## (call `isStartOfScan` first).
  let flags = b[pos + 3]
  ScanHeader(twi: (flags and 0x40) != 0, itb: (flags and 0x20) != 0,
    dp: (flags and 0x10) != 0, timing: [b[pos + 4], b[pos + 5], b[pos + 6]],
    byte8: b[pos + 7])

func timingMs*(h: ScanHeader): float64 {.inline.} =
  ## The timing word in ms.
  float64((uint32(h.timing[0]) shl 16) or (uint32(h.timing[1]) shl 8) or
    uint32(h.timing[2])) / 256.0

func transcode0015(w: uint16, twosComplement: bool): uint16 {.inline.} =
  # A 0015 word (S, 14 fraction bits, LSB 0) as the 8015 word of the same
  # value. One's complement: a negative 0015 word inverts 14 bits, an 8015
  # word 15, so the LSB becomes 1 (and 0 for a positive word). Two's
  # complement: clearing the LSB gives the same value.
  if not twosComplement and (w and 0x8000) != 0: w or 1 else: w and not 1'u16

proc demuxChannel*(code: int, scans: openArray[byte], stride, nScans: int,
    cs: MuxChannelSet, channel: int, dst: var openArray[byte], twosComplement = false) =
  ## Writes channel `channel` (0-based) of channel set `cs` from `nScans`
  ## scans of `stride` bytes, starting at `scans[0]`, into `dst` in the
  ## demultiplexed twin's layout: `nScans * cs.subscans` samples, scan by
  ## scan and subscan by subscan. `dst` must hold `dataBytes(demuxFormat(code),
  ## nScans * cs.subscans)` bytes.
  ##
  ## 0015 becomes 8015: the channel's exponent nibble and word are moved into
  ## 8015's groups of four samples, and the word's LSB is set so that 8015's
  ## 15-bit fraction gives 0015's 14-bit value (with `twosComplement`, as
  ## the readers' `twosComplement8015` option reads 8015, the LSB is cleared
  ## instead). The rest of a last, partial 8015 group is zero.
  let f = demuxFormat(code)
  doAssert f.isSome, "not a multiplexed format code"
  doAssert channel in 0 ..< cs.channels, "no such channel"
  let n = nScans * cs.subscans
  doAssert dst.len >= dataBytes(f.get, n) and scans.len >= nScans * stride,
    "buffer too short"
  if code == 15:
    for i in 0 ..< dataBytes(f.get, n): dst[i] = 0
    let group = 10 * (channel div 4)
    let slot = channel mod 4
    for j in 0..<n:
      let src = (j div cs.subscans) * stride + cs.offset + (j mod cs.subscans) * cs.subscanBytes +
        group
      let g = 10 * (j div 4)
      setNibble(dst, 2 * g + j mod 4, nibble(scans, 2 * src + slot))
      putBeU16(dst, g + 2 + 2 * (j mod 4),
        transcode0015(beU16(scans, src + 2 + 2 * slot), twosComplement))
  else:
    let bps = muxBytes(code, 1)
    for j in 0..<n:
      let src = (j div cs.subscans) * stride + cs.offset + (j mod cs.subscans) * cs.subscanBytes +
        channel * bps
      for k in 0..<bps: dst[j * bps + k] = scans[src + k]

proc decodeMux0015*[T: SegdSampleType](group: openArray[byte], dst: var openArray[T],
    twosComplement = false) =
  ## Decodes one 10-byte 0015 group: one sample of each of up to four
  ## channels (`dst.len` ≤ 4), `S.Q × 2^C` with a 14-bit one's complement
  ## fraction (two's complement with `twosComplement`). A reference for the
  ## 0015 layout; readers demultiplex to 8015 instead.
  doAssert dst.len <= 4 and group.len >= 10, "one 0015 group holds 4 channels in 10 bytes"
  for k in 0..<dst.len:
    let e = nibble(group, k)
    let w = beU16(group, 2 + 2 * k)
    let m = if twosComplement: int(cast[int16](w) shr 1)
            elif (w and 0x8000) != 0: -int(((w shr 1) and 0x3FFF) xor 0x3FFF)
            else: int((w shr 1) and 0x3FFF)
    dst[k] = T(float64(m) / 16384.0 * float64(1 shl e))

func muxTraceHeader*(gh1: SegdGeneralHeader1, gh2: Option[SegdGeneralHeader2],
    c: SegdChannelSetDescriptor, channel: int, firstTiming: array[3, byte], skew: uint8,
    timeBreakWindow: array[3, byte]): SegdTraceHeader =
  ## The demultiplexed trace header of channel `channel` (0-based) of the
  ## channel set described by `c`, as a demultiplexing system writes it
  ## (`segd_rev0.md` §3.7): file number from GH#1 (and GH#2's extended one),
  ## scan type and channel set numbers from the descriptor, trace number
  ## `channel + 1`, the timing word of the scan type's first scan, the
  ## channel's skew byte, and the timing word of the scan in which the
  ## time-break window closed. No trace header extensions.
  var b: array[SegdTraceHeaderSize, byte]
  b[0] = gh1.raw[0]
  b[1] = gh1.raw[1]
  b[2] = c.raw[0] # scan type number, BCD
  b[3] = c.raw[1] # channel set number, BCD (FF: see bytes 16-17)
  putBcd(b, 8, 4, (channel + 1) mod 10000)
  for i in 0..2:
    b[6 + i] = firstTiming[i]
    b[12 + i] = timeBreakWindow[i]
  b[10] = skew
  if c.raw[1] == 0xFF:
    b[15] = c.raw[26]
    b[16] = c.raw[27]
  if gh1.fileNumber == BcdAllF and gh2.isSome:
    putBeU24(b, 17, gh2.get.extFileNumber)
  decodeBlock[SegdTraceHeader](b)
