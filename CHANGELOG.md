# Changelog

## Unreleased

- `checkTextHeader` reports faults in a SEG-Y textual header (more than 40 lines, a line over 80 characters, a character the encoding cannot hold, for Rev 1 and later a card 39 or 40 not containing the standard's text, and a header the reader would misread) without raising or changing the text.
- `SegyOutputOptions.fullText` and `fixCards`, and the same arguments on a `like:` writer, write a caller-supplied whole textual header. A length or character fault, or a header the reader would misread, raises `ValueError` before any file is created. Unset, the header is unchanged.
- `HeaderEditor.replaceTextHeader` replaces a SEG-Y textual header in place
  (all 40 lines; a missing line becomes blank). The edit is journaled, so
  `rollbackJournal` undoes it. Lines are up to 80 characters; the file's
  present encoding is kept unless the caller forces EBCDIC or ASCII. An
  encoding the reader would not detect is refused, as is a control character.
  An open batch is flushed
  first; a write that does not reach the file returns false.
