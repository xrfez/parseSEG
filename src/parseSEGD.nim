## Main application module for parsesegd.
## Provides the primary execution entry point and core logic.

proc runApplication*(appName: string): int =
  ## Runs the primary execution workflow and returns an exit code.
  echo "Starting " & appName
  result = 0

when isMainModule:
  quit(runApplication("parsesegd"))