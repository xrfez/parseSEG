# SEG-D Rev 3.0: facts verified against a real file

Source: `SEG Spec/exampleFiles/00000151_12900_11300.sgd` (65,057,624 bytes; INOVA, mfr code 50;
recorded 2026 day 275; **not in git**, local only). Walk script logic: §6.4 of
`segd_rev3_0_a.md`. These facts **override** any conflicting note text.

## Size formulas: CONFIRMED exactly
| Quantity | Computed | GH3 field |
|---|---|---|
| headerSize = 32·nGH + nST·(96·nCS + 32·nSK) + 32·nEC + 32·nEX | 4544 | 4544 |
| dataSize = headerSize + Σ traces (20 + 32·THE + ns·4) | 65,057,624 | 65,057,624 |
| recordSize (GT = 0) | 65,057,624 | 65,057,624 (= file size, 1 record) |

nGH = 1 + GH1 12H = 17 blocks (GH1 + 16). EX = 113 external blocks, which **do** count in headerSize.

## Ambiguities resolved by the data
| Topic | Resolution |
|---|---|
| GH2 bytes 17-20 extended record length unit (part B AMBIGUITY 1) | **µs**: the value is 4,000,000 with ns 4001 @ 1000 µs |
| Storage unit label on disk | **absent**: the file starts at GH1 (same as the 2.0 sample) |
| Optional GH block order | any order, dispatched on byte 32. Seen: 02, 03, 10, 11, 12, 13, 14, 55×5, 50, 51, 52, 16 |
| Timestamp epoch / GPS−UTC | GH1 UTC 16:45:47 vs GH3 GPS µs → 16:46:05.504. Offset **18 s** (+ sub-second, truncated in GH1). The leap-second table needs 2015-06-30 and 2016-12-31 (GPS−UTC = 18 s since 2017-01-01) |
| THE `FFFFFF` sentinel | used in practice: bytes 1-3 / 4-6 = FFFFFF, and the extended i40/2^16 fields hold 100.0 / 101.0 |
| User-defined trace header blocks | **heavily used**: every trace has THE = 13 blocks: 0x40, position 0x50/51/52, then 9 vendor blocks **0xB0-0xB8**. They must be preserved raw and be decodable through the vendor-decoder registry |
| Position block numbers | 0x51 holds f64 coordinates (e.g. 0x413BDDB860000000 ≈ 1,826,232.4). 0x7F800000 / 0x7FF0... = IEEE +Inf is used as "not set" |

## New rule: trace order is NOT channel-set-descriptor order
The physical trace sequence was CS1, **CS3, CS2**, CS4 (3 one-trace auxiliary sets with channel
types 0x20/0x30/0x70, then 3954 seismic traces of type 0x10). **Readers must identify each trace's
channel set from its own demux header** (scan type byte 3, CS byte 4 or extended bytes 16-17) and
take that CSD's trace size. Never assume descriptor order. Writers should emit descriptor order.

## Record summary (for future regression tests)
- format 8058, BSI byte 16 (1 ms), record type 8, rev 3.0, GT 0, ERM 0, RTM 0
- GH text blocks: 0x11 "West Virginia", 0x12 "NNE", 0x13 "NNE_West_Morgantown_"
- CSDs: 4 × (ns 4001, SI 1000 µs, 0-4,000,000 µs, DSM 1000.0, THE 13); channel counts 1, 1, 1, 3954;
  CS4 physical unit 4
- First seismic trace at offset 53,864; last trace (#3954) at 65,041,184
