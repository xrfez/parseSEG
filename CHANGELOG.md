# Changelog

## Unreleased

- `checkTextHeader` reports faults in a SEG-Y textual header (more than 40 lines, a line over 80 characters, a character the encoding cannot hold, and for Rev 1 and later a card 39 or 40 the standard would not accept) without raising or changing the text.
