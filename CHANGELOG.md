# Changelog

## Unreleased

- `checkTextHeader` reports faults in a SEG-Y textual header (more than 40 lines, a line over 80 characters, a character the encoding cannot hold, and for Rev 1 and later a card 39 or 40 the standard would not accept) without raising or changing the text.
- `SegyOutputOptions.fullText` and `fixCards`, and the same arguments on a `like:` writer, write a caller-supplied whole textual header. A length or character fault raises `ValueError` before any file is created. Unset, the header is unchanged.
