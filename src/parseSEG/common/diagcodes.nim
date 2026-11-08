## Severity levels and problem codes of the diagnostics log.
##
## Kept apart from `diagnostics` so that `errors` can name a `DiagCode`
## without importing the log; `diagnostics` re-exports this module.

type
  Severity* = enum
    ## How bad a problem is. Order matters: later members are worse.
    sevInfo = "info"       ## Noteworthy but valid, e.g. a vendor block kept raw.
    sevWarning = "warning" ## Spec-invalid or suspicious, but the data was decoded.
    sevError = "error"     ## A part could not be decoded and was kept raw.
    sevFatal = "fatal"     ## The read had to stop early (I/O failure, truncation).

  DiagCode* = enum
    ## Catalog of problem kinds. The string spellings appear in NIF output and
    ## are stable; add members, never rename them.
    dcInternal = "internal"         ## Unexpected exception: a library bug or unhandled case.
    dcIo = "io"                     ## The operating system reported an I/O failure.
    dcTruncated = "truncated"       ## Data ends before an announced structure is complete.
    dcBadValue = "badValue"         ## A field violates the spec; the value is kept as read.
    dcBadBcd = "badBcd"             ## A BCD field holds a non-decimal nibble.
    dcInconsistent = "inconsistent" ## Two header values disagree, e.g. counts vs lengths.
    dcByteOrder = "byteOrder"       ## Byte order was inferred rather than declared.
    dcUnsupportedRevision = "unsupportedRevision" ## Unknown revision; parsed as the nearest one.
    dcUnsupportedFormat = "unsupportedFormat" ## Sample format not decodable; trace kept raw.
    dcUnknownBlock = "unknownBlock" ## Block type not defined by the spec; kept raw.
    dcVendorBlock = "vendorBlock"   ## Vendor block without a registered decoder; kept raw.
    dcVendorMap = "vendorMap"       ## A vendor map is malformed or does not fit the data.
    dcTapeLayout = "tapeLayout"     ## Tape marks, labels or block sizes deviate from the spec.
    dcValidation = "validation"     ## A writer found spec-invalid content.
    dcMultiplexed = "multiplexed"   ## Multiplexed SEG-D data, demultiplexed as it was read.
