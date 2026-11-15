## Whether a file lies on a network file system, for `FileAccess.faAuto`:
## a mapped read of such a file is a page fault that the OS answers over the
## network, so a share that fails or hangs makes it fail or wait there.
##
## - Linux: `statfs` `f_type`: NFS, SMB, CIFS and SMB2/3, AFS, Coda, NCP,
##   Ceph, 9P (WSL's Windows drives, VM shares), Lustre, GPFS, OCFS2, GFS2,
##   and FUSE (sshfs, rclone, gvfs, s3fs, virtiofs: a daemon in user space
##   that can fail or hang like a server).
## - macOS and the BSDs: `statfs` without `MNT_LOCAL`, or a file system type
##   of nfs, smbfs, afpfs, webdav, cifs, ftp or a FUSE one (macfuse,
##   osxfuse, fusefs).
## - Windows: local only on a fixed drive or a RAM disk (`GetDriveTypeW` of
##   the volume, `GetVolumePathNameW`, of the path made absolute,
##   `GetFullPathNameW`, after a ``\\?\`` or ``\\?\UNC\`` prefix is taken off;
##   a `subst` drive by the folder it stands for, `QueryDosDeviceW`), and
##   the file no cloud placeholder (an offline or recall-on-access
##   attribute: a sync provider fetches its data on a read). A path the OS
##   cannot make absolute is `naUnknown`.
##   A remote drive, a UNC path, a drive letter a network redirector serves
##   and a placeholder are network; a removable drive, a CD-ROM, a drive of
##   no known type, and a probe that fails are `naUnknown`.
##
## `faAuto` reads unmapped on a network file system, and also when the
## answer is `naUnknown` where no guard takes a failed read of a map
## (`unmappedByDefault`): on Windows, such a read is an in-page error that
## ends the program, so only a file known to lie on a local fixed disk is
## mapped there. Elsewhere the `SIGBUS` guard turns it into a failed read,
## and a file the OS cannot place is mapped.
##
## A few system calls; they ask the path, not an open descriptor.

import std/strutils

type NetworkAnswer* = enum
  ## What `onNetworkFileSystem` found.
  naUnknown
    ## The OS could not tell (the call failed, or no probe here); on
    ## Windows also a drive that is neither fixed nor a RAM disk.
  naLocal   ## A local file system.
  naNetwork ## A network (or user-space) file system, or a cloud placeholder.

const mapsUnknown* = not defined(windows)
  ## Whether `faAuto` maps a file whose answer is `naUnknown`: everywhere
  ## but Windows, where nothing takes a failed read of a map.

func unmappedByDefault*(answer: NetworkAnswer, mapUnknown = mapsUnknown): bool =
  ## Whether `faAuto` reads a file with this answer unmapped: on a network
  ## file system, and when the OS cannot tell unless `mapUnknown`.
  case answer
  of naNetwork: true
  of naLocal: false
  of naUnknown: not mapUnknown

# Windows: the decisions, as pure functions (tested on every OS).
const
  DriveRemovable* = 2'u32
  DriveFixed* = 3'u32
  DriveRemote* = 4'u32
  DriveCdrom* = 5'u32
  DriveRamdisk* = 6'u32
  AttrOffline* = 0x1000'u32
  AttrRecallOnOpen* = 0x40000'u32
  AttrRecallOnDataAccess* = 0x400000'u32
  InvalidAttributes* = 0xFFFF_FFFF'u32

func driveAnswer*(driveType, attributes: uint32): NetworkAnswer =
  ## Windows: what a `GetDriveTypeW` result and the file's
  ## `GetFileAttributesW` say. Local only on a fixed drive or a RAM disk,
  ## for a file that is no cloud placeholder (offline, or recalled on open
  ## or on access: a sync provider fetches its data, and can fail).
  if driveType == DriveRemote: naNetwork
  elif driveType != DriveFixed and driveType != DriveRamdisk: naUnknown
  elif attributes == InvalidAttributes: naUnknown
  elif (attributes and (AttrOffline or AttrRecallOnOpen or AttrRecallOnDataAccess)) != 0:
    naNetwork
  else: naLocal

func win32Path*(path: string): string =
  ## Windows: `path` without a ``\\?\`` or ``\\.\`` prefix, which
  ## `GetVolumePathNameW` does not take: ``\\?\UNC\server\share\x`` is
  ## ``\\server\share\x``, ``\\?\C:\x`` is ``C:\x``. Any other path (a
  ## ``\\?\Volume{...}\`` one among them) is returned as it is.
  if path.len >= 4 and path[0] in {'\\', '/'} and path[1] in {'\\', '/'} and
      path[2] in {'?', '.'} and path[3] in {'\\', '/'}:
    let rest = path.substr(4)
    if rest.len >= 4 and rest.substr(0, 2).cmpIgnoreCase("UNC") == 0 and rest[3] in {'\\', '/'}:
      return "\\\\" & rest.substr(4)
    if rest.len >= 2 and rest[1] == ':' and rest[0] in Letters:
      return rest
  path

func redirected*(device: string): bool =
  ## Windows: whether a drive letter's device (`QueryDosDeviceW`) is served
  ## by a network redirector (SMB, WebDAV, a remote desktop's drives; a
  ## letter mapped to a share).
  const redirectors = ["\\Device\\Mup\\", "\\Device\\LanmanRedirector\\",
    "\\Device\\WebDavRedirector\\", "\\Device\\RdpDr\\"]
  for r in redirectors:
    if device.len >= r.len and device.substr(0, r.len - 1).cmpIgnoreCase(r) == 0: return true
  false

func substTarget*(device: string): string =
  ## Windows: the folder a `subst` drive stands for, from its device
  ## (`QueryDosDeviceW`: ``\??\C:\data``, ``\??\UNC\server\share``), as a
  ## path (``C:\data``, ``\\server\share``); "" for a device that is no
  ## `subst` (a disk volume, a redirector).
  if device.len < 5 or not device.startsWith("\\??\\"): return ""
  let rest = device.substr(4)
  if rest.len >= 4 and rest.substr(0, 2).cmpIgnoreCase("UNC") == 0 and rest[3] == '\\':
    "\\\\" & rest.substr(4)
  else: rest

type WinCalls* = object
  ## Windows: the system calls the probe makes, as procs, so that the probe
  ## (`windowsAnswer`) can be checked with made-up answers on any OS. Each
  ## returns "" (or `InvalidAttributes`, or 0 for `driveType`) when the call
  ## fails.
  fullPath*: proc (path: string): string {.closure, gcsafe, raises: [].}
    ## `GetFullPathNameW`: `path` made absolute against the current
    ## directory (a drive's or a share's).
  volumeOf*: proc (path: string): string {.closure, gcsafe, raises: [].}
    ## `GetVolumePathNameW`: the root of the volume `path` lies on.
  driveType*: proc (root: string): uint32 {.closure, gcsafe, raises: [].} ## `GetDriveTypeW`.
  dosDevice*: proc (drive: string): string {.closure, gcsafe, raises: [].}
    ## `QueryDosDeviceW` of a drive (`Z:`): the first of its device names.
  attributes*: proc (path: string): uint32 {.closure, gcsafe, raises: [].} ## `GetFileAttributesW`.

proc volumeType(calls: WinCalls, full: string, depth: int): uint32 =
  # The drive type of the volume of `full` (an absolute path), a `subst`
  # drive's by its folder, `DriveRemote` for a letter a redirector serves;
  # 0 (`DRIVE_UNKNOWN`) when a call fails.
  let root = calls.volumeOf(win32Path(full))
  if root.len == 0: return 0
  result = calls.driveType(root)
  if result != DriveRemote and root.len == 3 and root[1] == ':' and depth < 4:
    let d = calls.dosDevice(root.substr(0, 1))
    if redirected(d): return DriveRemote
    let target = substTarget(d)
    if target.len > 0:
      let t = calls.fullPath(target)
      return if t.len == 0: 0'u32 else: volumeType(calls, t, depth + 1)

proc windowsAnswer*(path: string, calls: WinCalls): NetworkAnswer =
  ## Windows: where `path` lies, from what `calls` answer (see the module
  ## documentation). The path is made absolute first (`fullPath`):
  ## `GetVolumePathNameW` takes a path without a volume (`x.sgy`,
  ## ``\data\x.sgy``) as one on the boot volume, also when the current
  ## directory is on a share. When it cannot be made absolute: `naUnknown`.
  let full = calls.fullPath(path)
  if full.len == 0: return naUnknown
  let kind = volumeType(calls, full, 0)
  driveAnswer(kind, if kind == DriveRemote: 0'u32 else: calls.attributes(path))

when defined(linux):
  type StatFs {.importc: "struct statfs", header: "<sys/vfs.h>".} = object
    f_type: clong
  proc c_statfs(path: cstring, buf: ptr StatFs): cint {.importc: "statfs",
    header: "<sys/vfs.h>".}

  const networkMagics = [
    0x6969'u32,     # NFS
    0x517B'u32,     # SMB (smbfs)
    0xFF534D42'u32, # CIFS
    0xFE534D42'u32, # SMB2/3
    0x5346414F'u32, # AFS (kAFS)
    0x6B414653'u32, # AFS (OpenAFS)
    0x73757245'u32, # Coda
    0x564C'u32,     # NCP (NetWare)
    0x00C36400'u32, # Ceph
    0x01021997'u32, # 9P (v9fs)
    0x0BD00BD0'u32, # Lustre
    0x47504653'u32, # GPFS
    0x7461636F'u32, # OCFS2
    0x01161970'u32, # GFS2
    0x65735546'u32] # FUSE

  proc onNetworkFileSystem*(path: string): NetworkAnswer {.raises: [].} =
    ## Where `path` lies (see the module documentation).
    var st: StatFs
    if c_statfs(path.cstring, addr st) != 0: return naUnknown
    if uint32(st.f_type) in networkMagics: naNetwork else: naLocal

elif defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
  type StatFs {.importc: "struct statfs", header: "<sys/mount.h>".} = object
    f_flags: uint64
    f_fstypename: array[16, char]
  var mntLocal {.importc: "MNT_LOCAL", header: "<sys/mount.h>".}: cint
  proc c_statfs(path: cstring, buf: ptr StatFs): cint {.importc: "statfs",
    header: "<sys/mount.h>".}

  proc onNetworkFileSystem*(path: string): NetworkAnswer {.raises: [].} =
    ## Where `path` lies (see the module documentation).
    var st: StatFs
    if c_statfs(path.cstring, addr st) != 0: return naUnknown
    var name = ""
    for c in st.f_fstypename:
      if c == '\0': break
      name.add c
    if (st.f_flags and uint64(mntLocal)) == 0 or
        name in ["nfs", "smbfs", "afpfs", "webdav", "cifs", "ftp", "macfuse", "osxfuse",
          "fusefs"]:
      naNetwork
    else: naLocal

elif defined(windows):
  proc getFullPathNameW(name: WideCString, len: uint32, buffer: ptr Utf16Char,
    filePart: pointer): uint32 {.stdcall, importc: "GetFullPathNameW", header: "<windows.h>".}
  proc getVolumePathNameW(fileName: WideCString, volume: ptr Utf16Char, len: uint32): int32 {.
    stdcall, importc: "GetVolumePathNameW", header: "<windows.h>".}
  proc getDriveTypeW(root: WideCString): uint32 {.
    stdcall, importc: "GetDriveTypeW", header: "<windows.h>".}
  proc queryDosDeviceW(name: WideCString, target: ptr Utf16Char, len: uint32): uint32 {.
    stdcall, importc: "QueryDosDeviceW", header: "<windows.h>".}
  proc getFileAttributesW(name: WideCString): uint32 {.
    stdcall, importc: "GetFileAttributesW", header: "<windows.h>".}

  proc fullPathOf(path: string): string {.raises: [].} =
    # `GetFullPathNameW`: the size needed is returned when the buffer is too
    # small (the current directory can be long), so a second call fits.
    let wide = newWideCString(path)
    var buf = newSeq[Utf16Char](max(path.len + 2, 1024))
    var n = getFullPathNameW(wide, uint32(buf.len), addr buf[0], nil)
    if n >= uint32(buf.len):
      buf.setLen(int(n) + 1)
      n = getFullPathNameW(wide, uint32(buf.len), addr buf[0], nil)
    if n == 0 or n >= uint32(buf.len): return ""
    $cast[WideCString](addr buf[0])

  proc volumeOfPath(path: string): string {.raises: [].} =
    var volume = newSeq[Utf16Char](max(path.len + 2, 1024)) # UTF-16 units <= UTF-8 bytes
    if getVolumePathNameW(newWideCString(path), addr volume[0], uint32(volume.len)) == 0:
      return ""
    $cast[WideCString](addr volume[0])

  proc driveTypeOf(root: string): uint32 {.raises: [].} = getDriveTypeW(newWideCString(root))

  proc dosDeviceOf(drive: string): string {.raises: [].} =
    var device: array[1024, Utf16Char]
    if queryDosDeviceW(newWideCString(drive), addr device[0], uint32(device.len)) == 0:
      return ""
    $cast[WideCString](addr device[0]) # the first of its names

  proc attributesOf(path: string): uint32 {.raises: [].} = getFileAttributesW(newWideCString(path))

  proc onNetworkFileSystem*(path: string): NetworkAnswer {.raises: [].} =
    ## Where `path` lies (see the module documentation).
    windowsAnswer(path, WinCalls(fullPath: fullPathOf, volumeOf: volumeOfPath,
      driveType: driveTypeOf, dosDevice: dosDeviceOf, attributes: attributesOf))

else:
  proc onNetworkFileSystem*(path: string): NetworkAnswer {.raises: [].} =
    ## No probe on this OS: `naUnknown`.
    naUnknown
