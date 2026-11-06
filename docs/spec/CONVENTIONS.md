# Spec note conventions

Every file in `docs/spec/` distills one SEG standard (or part of one) from the
page-marked text in `SEG Spec/text/`. These notes are the **only** spec source
that implementation sessions should read. Nobody should open the PDFs again.

## Source citations
- Cite the PDF page for every table and rule as `[p.N]`. N is the number from the
  `=== PAGE N ===` markers in the text file, which is the PDF page index, not the
  printed page number.
- If the text extraction is garbled or ambiguous (misaligned table columns,
  footnote digits glued to byte ranges, and so on), say so in an
  `> **AMBIGUITY:**` blockquote with the page number. Don't guess silently.

## Byte layout tables
Use one table per header/block, with these columns:

| Bytes | Nibble | Len | Enc | Field (`nimIdent`) | Meaning / values |
|---|---|---|---|---|---|

- **Bytes**: 1-based, inclusive, and relative to the start of that block, as the
  spec numbers them. For SEG-Y file-level offsets (such as 3217-3218), keep the
  spec's absolute numbers and state the block start.
- **Nibble**: blank for whole bytes. For BCD/packed fields that start or end
  mid-byte, write `H` (high nibble, bits 7-4) or `L` (low nibble, bits 3-0),
  e.g. `1H-2L`.
- **Len**: the field size in bytes (`b`), nibbles (`n`) or bits.
- **Enc**: use exactly one of these:
  - `u8`, `u16`, `u24`, `u32`, `u64`: unsigned big-endian binary
  - `i8`, `i16`, `i24`, `i32`, `i64`: two's-complement big-endian
  - `bcd`: packed BCD, digit count = nibbles
  - `f32`, `f64`: IEEE big-endian
  - `ibm32`: IBM hex float
  - `ascii`, `ebcdic`
  - `bits`: a bitfield (give the per-bit meaning)
  - `fixedpt`: binary fraction (give the format, e.g. `i16.i8`, or the scale)
  - `ext`: "extended" fields, such as a value of FFFF that means "look elsewhere"
- **Field**: a proposed camelCase Nim identifier.
- **Meaning**: units, allowed values / code tables, mandatory or optional,
  sentinel values (e.g. `FF` = use extended field), and any cross-references.

## Required sections per note
1. **Scope**: which document, which pages were covered, and which pages were skipped and why.
2. **File / tape structure**: the order of blocks, record boundaries, tape marks /
   EOF semantics, and the disk vs tape differences.
3. **Header tables**: every block, byte-exact (format above).
4. **Code tables**: format codes, units, and enumerations, each as a table.
5. **Data sample formats**: the exact bit layout of every sample format, with
   enough detail to implement encode/decode (sign, exponent, nibble ordering,
   multiplexed vs demux, padding).
6. **Derived rules / algorithms**: size computations (block counts, trace lengths,
   skew blocks, extended fields), validation rules, and version detection.
7. **Implementation notes**: gotchas, edge cases, and differences from other revisions.
8. **Open questions**: anything the implementer must decide.

Keep prose terse. Tables beat paragraphs. Omit marketing, history and committee
text, glossary entries that just restate the obvious, and the manufacturer list
(except as a compact code→name table).
