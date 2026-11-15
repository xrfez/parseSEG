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
## - Windows: `GetDriveTypeW` of the path's volume (`GetVolumePathNameW`) is
##   `DRIVE_REMOTE`: a mapped network drive or a UNC path (`\\server\share`).
##
## One system call; it asks the path, not an open descriptor.

type NetworkAnswer* = enum
  ## What `onNetworkFileSystem` found.
  naUnknown ## The OS could not tell (the call failed, or no probe here).
  naLocal   ## A local file system.
  naNetwork ## A network (or user-space) file system.

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
  proc getVolumePathNameW(fileName: WideCString, volume: ptr Utf16Char, len: int32): int32 {.
    stdcall, importc: "GetVolumePathNameW", header: "<windows.h>".}
  proc getDriveTypeW(root: ptr Utf16Char): uint32 {.
    stdcall, importc: "GetDriveTypeW", header: "<windows.h>".}
  const DriveRemote = 4'u32

  proc onNetworkFileSystem*(path: string): NetworkAnswer {.raises: [].} =
    ## Where `path` lies (see the module documentation).
    var volume: array[1024, Utf16Char]
    let wide = newWideCString(path)
    if getVolumePathNameW(wide, addr volume[0], int32(volume.len)) == 0: return naUnknown
    if getDriveTypeW(addr volume[0]) == DriveRemote: naNetwork else: naLocal

else:
  proc onNetworkFileSystem*(path: string): NetworkAnswer {.raises: [].} =
    ## No probe on this OS: `naUnknown`.
    naUnknown
