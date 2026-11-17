## How `faAuto` decides, as far as it can be checked on any OS: the Windows
## rule is pure functions of what the system calls answer (`GetDriveTypeW`,
## `GetFileAttributesW`, `QueryDosDeviceW`) and of the path, tested here as
## tables; twincross compiles the calls for Windows. On Windows a file is
## mapped only on a fixed drive or a RAM disk and when it is no cloud
## placeholder, since nothing there takes a failed read of a map (an in-page
## error ends the program); elsewhere an answer the OS cannot give still
## maps (the `SIGBUS` guard takes a failed read). Seen failing with
## 0.12.0's rule in `driveAnswer` (all but `DRIVE_REMOTE` local):
## "placeholder (on access): naLocal". The whole Windows probe
## (`windowsAnswer`) runs here against a made-up machine (its current
## directory on a mapped drive or a share, a `subst` drive onto a share, a
## placeholder); seen failing with the path given to `GetVolumePathNameW` as
## it is: "cwd Z:\: x.sgy: naLocal" (a relative path is taken as one on the
## boot volume).

import std/[assertions, os, strutils]

import parseSEG

import parseSEG/io/memsource

import parseSEG/private/netfs

import ./utils/testutils

proc main*() =
  block drive_answers:
    const normal = 0x80'u32  # FILE_ATTRIBUTE_NORMAL
    const archive = 0x20'u32 # FILE_ATTRIBUTE_ARCHIVE
    for (kind, attrs, want, what) in [
        (DriveFixed, normal, naLocal, "fixed"),
        (DriveFixed, archive, naLocal, "fixed, archive"),
        (DriveRamdisk, normal, naLocal, "RAM disk"),
        (DriveRemote, normal, naNetwork, "remote"),
        (DriveRemote, InvalidAttributes, naNetwork, "remote, no attributes"),
        (DriveFixed, archive or AttrRecallOnDataAccess, naNetwork, "placeholder (on access)"),
        (DriveFixed, AttrRecallOnOpen, naNetwork, "placeholder (on open)"),
        (DriveFixed, AttrOffline, naNetwork, "offline"),
        (DriveRamdisk, AttrRecallOnDataAccess, naNetwork, "RAM disk placeholder"),
        (DriveFixed, InvalidAttributes, naUnknown, "fixed, attributes failed"),
        (DriveRemovable, normal, naUnknown, "removable"),
        (DriveCdrom, normal, naUnknown, "CD-ROM"),
        (0'u32, normal, naUnknown, "DRIVE_UNKNOWN (and a failed probe)"),
        (1'u32, normal, naUnknown, "DRIVE_NO_ROOT_DIR"),
        (7'u32, normal, naUnknown, "a type of a later Windows")]:
      let got = driveAnswer(kind, attrs)
      doAssert got == want, what & ": " & $got

  block what_auto_does_with_an_answer:
    # Windows (no guard): only a local answer maps.
    doAssert unmappedByDefault(naNetwork, mapUnknown = false)
    doAssert unmappedByDefault(naUnknown, mapUnknown = false)
    doAssert not unmappedByDefault(naLocal, mapUnknown = false)
    # POSIX (the guard): only a network answer reads unmapped, as in 0.12.0.
    doAssert unmappedByDefault(naNetwork, mapUnknown = true)
    doAssert not unmappedByDefault(naUnknown, mapUnknown = true)
    doAssert not unmappedByDefault(naLocal, mapUnknown = true)
    doAssert mapsUnknown == not defined(windows)

  block windows_paths:
    for (path, want) in [
        (r"\\?\C:\data\x.sgy", r"C:\data\x.sgy"),
        (r"\\?\UNC\server\share\x.sgy", r"\\server\share\x.sgy"),
        (r"\\?\unc\server\share", r"\\server\share"),
        (r"\\.\D:\x", r"D:\x"),
        (r"//?/C:/data/x.sgy", r"C:/data/x.sgy"),
        (r"\\?\Volume{0b1c2d3e-0000-0000-0000-100000000000}\x.sgy",
          r"\\?\Volume{0b1c2d3e-0000-0000-0000-100000000000}\x.sgy"),
        (r"\\?\UNCX\x", r"\\?\UNCX\x"),
        (r"\\?\", r"\\?\"),
        (r"C:\data\x.sgy", r"C:\data\x.sgy"),
        (r"\\server\share\x.sgy", r"\\server\share\x.sgy"),
        (r"relative\x.sgy", r"relative\x.sgy"),
        ("", "")]:
      doAssert win32Path(path) == want, path & ": " & win32Path(path)

  block drive_letter_devices:
    for (device, target, remote) in [
        (r"\??\C:\data", r"C:\data", false),
        (r"\??\UNC\server\share\dir", r"\\server\share\dir", false),
        (r"\??\unc\server\share", r"\\server\share", false),
        (r"\??\Z:\projects", r"Z:\projects", false),
        (r"\Device\HarddiskVolume3", "", false),
        (r"\Device\CdRom0", "", false),
        (r"\Device\LanmanRedirector\;Z:000000000001a2b3\server\share", "", true),
        (r"\Device\Mup\;LanmanRedirector\;Z:000000000001a2b3\server\share", "", true),
        (r"\device\mup\;RdpDr\;:1\tsclient\C", "", true),
        (r"\Device\WebDavRedirector\;W:0000\host\DavWWWRoot", "", true),
        (r"\Device\RdpDr\;:1\tsclient\C", "", true),
        (r"\Device\Mupx", "", false),
        ("", "", false)]:
      doAssert substTarget(device) == target, device & ": " & substTarget(device)
      doAssert redirected(device) == remote, device

  proc windowsMachine(cwd: string): WinCalls =
    ## A made-up Windows machine whose current directory is `cwd` (a drive's,
    ## `C:\work`, or a share's, `\\server\share\dir`). Drives: C: fixed, E:
    ## removable, Z: mapped to `\\server\share` (remote), S: a `subst` of
    ## `\\server\share\proj` that the drive type calls fixed (the worst case),
    ## L: a `subst` of `C:\data`. `GetVolumePathNameW` gives the boot volume for
    ## a path without a volume, as Microsoft documents. A path "bad" cannot be
    ## made absolute.
    proc root(p: string): string =
      # The volume part of an absolute path: `C:\` or `\\server\share\`.
      if p.len >= 3 and p[1] == ':' and p[2] == '\\': return p.substr(0, 2)
      if p.startsWith("\\\\"):
        let parts = p.substr(2).split('\\')
        if parts.len >= 2: return "\\\\" & parts[0] & "\\" & parts[1] & "\\"
      ""
    result.fullPath = proc (p: string): string =
      if p == "bad": ""
      elif p.startsWith("\\\\") or (p.len >= 3 and p[1] == ':' and p[2] == '\\'): p
      elif p.startsWith("\\"): root(cwd).substr(0, root(cwd).len - 2) & p # rooted: cwd's volume
      else: cwd & "\\" & p
    result.volumeOf = proc (p: string): string =
      if p.startsWith("\\\\?\\") or p.startsWith("\\\\.\\"): "" # not taken
      elif root(p).len == 0: "C:\\" # no volume: the boot volume
      else: root(p)
    result.driveType = proc (r: string): uint32 =
      case r.toUpperAscii
      of "C:\\", "L:\\", "S:\\": DriveFixed
      of "E:\\": DriveRemovable
      of "Z:\\": DriveRemote
      of "\\\\SERVER\\SHARE\\": DriveRemote
      else: 1'u32 # DRIVE_NO_ROOT_DIR
    result.dosDevice = proc (d: string): string =
      case d.toUpperAscii
      of "C:", "E:": "\\Device\\HarddiskVolume3"
      of "Z:": "\\Device\\LanmanRedirector\\;Z:000000000001a2b3\\server\\share"
      of "S:": "\\??\\UNC\\server\\share\\proj"
      of "L:": "\\??\\C:\\data"
      else: ""
    result.attributes = proc (p: string): uint32 =
      if p.endsWith("online-only.sgy"): 0x20'u32 or AttrRecallOnDataAccess else: 0x80'u32

  block the_windows_probe:
    for (cwd, path, want) in [
        (r"C:\work", r"x.sgy", naLocal),
        (r"C:\work", r"C:\data\x.sgy", naLocal),
        (r"C:\work", r"\\?\C:\data\x.sgy", naLocal),
        (r"Z:\", r"x.sgy", naNetwork),             # a relative path, cwd on a mapped drive
        (r"Z:\proj", r"\data\x.sgy", naNetwork),  # rooted, cwd on a mapped drive
        (r"\\server\share\dir", r"x.sgy", naNetwork), # cwd on a share
        (r"\\server\share\dir", r"\data\x.sgy", naNetwork),
        (r"C:\work", r"Z:\x.sgy", naNetwork),
        (r"C:\work", r"\\server\share\x.sgy", naNetwork),
        (r"C:\work", r"\\?\UNC\server\share\x.sgy", naNetwork),
        (r"C:\work", r"S:\x.sgy", naNetwork),     # subst onto a share
        (r"C:\work", r"L:\x.sgy", naLocal),       # subst onto a local folder
        (r"C:\work", r"E:\x.sgy", naUnknown),     # removable
        (r"C:\work", r"Q:\x.sgy", naUnknown),     # no such drive
        (r"C:\work", r"online-only.sgy", naNetwork), # a placeholder
        (r"Z:\", r"bad", naUnknown)]:              # not made absolute
      let got = windowsAnswer(path, windowsMachine(cwd))
      doAssert got == want, "cwd " & cwd & ": " & path & ": " & $got
      doAssert unmappedByDefault(got, mapUnknown = false) == (want != naLocal)

  block resolve_on_this_os:
    let local = demoDir() / "survey.sgy"
    doAssert resolveAccess(local, faMapped) == faMapped
    doAssert resolveAccess(local, faUnmapped) == faUnmapped
    when defined(linux):
      # A local disk maps; a path the OS cannot place (statfs fails) maps too:
      # the guard takes a failed read (unchanged from 0.12.0).
      let answer = onNetworkFileSystem(local)
      if answer == naLocal: doAssert resolveAccess(local, faAuto) == faMapped
      doAssert onNetworkFileSystem(local / "none") == naUnknown
      doAssert resolveAccess(local / "none", faAuto) == faMapped

  echo "tnetfs: ok"

when isMainModule: main()
