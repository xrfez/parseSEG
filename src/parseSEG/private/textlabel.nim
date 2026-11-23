## Pure byte tests the SEG-Y reader uses to tell a tape label from a textual
## header. Not a public API.

const LabelBytes* = 128 ## Bytes in a SEG-Y tape label.

func looksLikeTapeLabel*(b: openArray[byte]): bool =
  ## Storage unit sequence number (digits or blanks) and "SY" in bytes 5-6.
  b[0] in {0x20'u8, 0x30'u8..0x39'u8} and b[4] == 0x53 and b[5] == 0x59

func startsWithC*(b: openArray[byte]): bool {.inline.} =
  ## `C` in EBCDIC (0xC3) or ASCII (0x43).
  b[0] == 0xC3 or b[0] == 0x43

func wouldTakeTapeLabel*(head, following: openArray[byte]): bool =
  ## True when `head` looks like a tape label and `following` starts with `C`.
  ## A label may also be kept after a peek at the binary header; this does not
  ## do that peek.
  looksLikeTapeLabel(head) and startsWithC(following)
