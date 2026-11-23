# Changelog

## Unreleased

- `HeaderEditor.replaceTextHeader` replaces a SEG-Y textual header in place.
  The edit is journaled, so `rollbackJournal` undoes it. Up to 40 lines of up
  to 80 characters; the file's present encoding is kept unless the caller
  forces EBCDIC or ASCII.
