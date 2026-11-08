## The seismic standards a file can be in; shared by the trace index and the
## vendor maps.

type
  SeismicKind* = enum
    ## The standard of a file or stream.
    skUnknown = "unknown" ## Neither format was recognized (see the log).
    skSegy = "SEG-Y"
    skSegd = "SEG-D"
