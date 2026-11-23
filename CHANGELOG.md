# Changelog

## Unreleased

- `HeaderEditor.replaceTextHeader` replaces a SEG-Y textual header in place
  (all 40 lines; a missing line becomes blank). The edit is journaled, so
  `rollbackJournal` undoes it. Lines are up to 80 characters; the file's
  present encoding is kept unless the caller forces EBCDIC or ASCII. An
  encoding the reader would not detect is refused. An open batch is flushed
  first; a write that does not reach the file returns false.
