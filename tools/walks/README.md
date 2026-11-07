# Verification walks

These are throwaway Python decoders written from the spec notes and used to verify the notes
against the real sample files. Run them with `python3 -I tools/walks/<script> <file>`. Each one
prints decoded headers and checks that the blocks tile the file exactly. Keep them as
reference implementations and regression oracles for the Nim library.

| Script | Sample | Note |
|---|---|---|
| `segd2_walk.py` | `63.sgd` (SEG-D 2.0) | `segd_rev2_0_delta.md` |
| `segd3_walk.py` | `00000151_12900_11300.sgd` (SEG-D 3.0, local only) | `segd_rev3_0_verified.md` |
| `segy21_walk.py` | `BO_3D-Inglewood_rev21_v7.sgy` (SEG-Y 2.1) | `segy_rev2_1.md` |
