#!/bin/sh
# Patch go-fuse and godaemon dependencies for OpenBSD support.
# Run this script after `go mod download` and before `go build`.
#
# Usage: sh hack/openbsd_patch_deps.sh
#
# This patches vendored/cached dependencies that don't natively support OpenBSD:
# - go-fuse: adds OpenBSD FUSE types, attributes, mount via CGo, xattr stubs
# - godaemon: adds openbsd to build tags
set -ex

# Locate the go-fuse module cache directory
GOFUSE_DIR=$(go env GOMODCACHE)/$(go list -m -f '{{.Path}}@{{.Version}}' github.com/hanwen/go-fuse/v2 2>/dev/null || true)
# Try the replace target if direct lookup fails
if [ ! -d "$GOFUSE_DIR" ]; then
  GOFUSE_DIR=$(go env GOMODCACHE)/$(grep 'go-fuse/v2' go.sum | head -1 | awk '{print $1"@"$2}' | sed 's|/go.mod||')
fi
# Fall back: search the module cache
if [ ! -d "$GOFUSE_DIR" ]; then
  GOFUSE_DIR=$(find "$(go env GOMODCACHE)" -path '*/juicedata/go-fuse/v2@*' -type d | head -1)
fi
if [ -z "$GOFUSE_DIR" ] || [ ! -d "$GOFUSE_DIR" ]; then
  echo "ERROR: Cannot find go-fuse module directory"
  exit 1
fi

echo "Patching go-fuse at: $GOFUSE_DIR"
chmod -R u+w "$GOFUSE_DIR"

# --- fuse/types_openbsd.go ---
cat > "${GOFUSE_DIR}/fuse/types_openbsd.go" << 'GOEOF'
package fuse

import (
	"syscall"
)

const (
	ENOATTR = Status(syscall.ENOATTR)
	EREMOTEIO = Status(syscall.EIO)
)

type Attr struct {
	Ino       uint64
	Size      uint64
	Blocks    uint64
	Atime     uint64
	Mtime     uint64
	Ctime     uint64
	Crtime_   uint64
	Atimensec uint32
	Mtimensec uint32
	Ctimensec uint32
	Crtimensec_ uint32
	Mode      uint32
	Nlink     uint32
	Owner
	Rdev    uint32
	Flags_  uint32
	Blksize uint32
	Padding uint32
}

const (
	FATTR_CRTIME   = (1 << 28)
	FATTR_CHGTIME  = (1 << 29)
	FATTR_BKUPTIME = (1 << 30)
	FATTR_FLAGS    = (1 << 31)
)

type SetAttrIn struct {
	SetAttrInCommon
	Bkuptime_    uint64
	Chgtime_     uint64
	Crtime       uint64
	BkuptimeNsec uint32
	ChgtimeNsec  uint32
	CrtimeNsec   uint32
	Flags_       uint32
}

const (
	FOPEN_PURGE_ATTR = (1 << 30)
	FOPEN_PURGE_UBC  = (1 << 31)
)

const (
	FUSE_GETATTR_FH = (1 << 0)
)

type GetAttrIn struct {
	InHeader
	Flags_ uint32
	Dummy  uint32
	Fh_    uint64
}

func (g *GetAttrIn) Flags() uint32 { return g.Flags_ }
func (g *GetAttrIn) Fh() uint64    { return g.Fh_ }

type CreateIn struct {
	InHeader
	Flags   uint32
	Mode    uint32
	Umask   uint32
	Padding uint32
}

type MknodIn struct {
	InHeader
	Mode    uint32
	Rdev    uint32
	Umask   uint32
	Padding uint32
}

type ReadIn struct {
	InHeader
	Fh        uint64
	Offset    uint64
	Size      uint32
	ReadFlags uint32
	LockOwner uint64
	Flags     uint32
	Padding   uint32
}

type WriteIn struct {
	InHeader
	Fh         uint64
	Offset     uint64
	Size       uint32
	WriteFlags uint32
	LockOwner  uint64
	Flags      uint32
	Padding    uint32
}

type SetXAttrIn struct {
	InHeader
	Size     uint32
	Flags    uint32
	Position uint32
	Padding  uint32
}

type GetXAttrIn struct {
	InHeader
	Size     uint32
	Padding  uint32
	Position uint32
	Padding2 uint32
}

const (
	CAP_NODE_RWLOCK      = (1 << 24)
	CAP_RENAME_SWAP      = (1 << 25)
	CAP_RENAME_EXCL      = (1 << 26)
	CAP_ALLOCATE         = (1 << 27)
	CAP_EXCHANGE_DATA    = (1 << 28)
	CAP_CASE_INSENSITIVE = (1 << 29)
	CAP_VOL_RENAME       = (1 << 30)
	CAP_XTIMES           = (1 << 31)
	CAP_EXPLICIT_INVAL_DATA = 0x0
)

type GetxtimesOut struct {
	Bkuptime     uint64
	Crtime       uint64
	Bkuptimensec uint32
	Crtimensec   uint32
}

type ExchangeIn struct {
	InHeader
	Olddir  uint64
	Newdir  uint64
	Options uint64
}

func (s *StatfsOut) FromStatfsT(statfs *syscall.Statfs_t) {
	s.Blocks = statfs.F_blocks
	s.Bfree = statfs.F_bfree
	s.Bavail = uint64(statfs.F_bavail)
	s.Files = statfs.F_files
	s.Ffree = uint64(statfs.F_ffree)
	s.Bsize = uint32(statfs.F_iosize)
	s.Frsize = s.Bsize
	if s.Bsize > uint32(statfs.F_bsize) {
		adj := uint64(s.Bsize / uint32(statfs.F_bsize))
		s.Blocks /= adj
		s.Bfree /= adj
		s.Bavail /= adj
	}
}
GOEOF

# --- fuse/attr_openbsd.go ---
cat > "${GOFUSE_DIR}/fuse/attr_openbsd.go" << 'GOEOF'
package fuse

import (
	"syscall"
)

func (a *Attr) FromStat(s *syscall.Stat_t) {
	a.Ino = s.Ino
	a.Size = uint64(s.Size)
	a.Blocks = uint64(s.Blocks)
	a.Atime = uint64(s.Atim.Sec)
	a.Atimensec = uint32(s.Atim.Nsec)
	a.Mtime = uint64(s.Mtim.Sec)
	a.Mtimensec = uint32(s.Mtim.Nsec)
	a.Ctime = uint64(s.Ctim.Sec)
	a.Ctimensec = uint32(s.Ctim.Nsec)
	a.Mode = s.Mode
	a.Nlink = s.Nlink
	a.Uid = s.Uid
	a.Gid = s.Gid
	a.Rdev = uint32(s.Rdev)
	a.Blksize = uint32(s.Blksize)
}
GOEOF

# --- fuse/types.go: patch ENODATA (doesn't exist on OpenBSD) ---
if grep -q 'syscall.ENODATA' "${GOFUSE_DIR}/fuse/types.go"; then
  sed -i.bak 's|ENODATA = Status(syscall.ENODATA)|ENODATA = Status(0x60)|' "${GOFUSE_DIR}/fuse/types.go"
fi

# --- fuse/print.go: remove LARGEFILE entry that conflicts with O_NOCTTY on OpenBSD ---
if grep -q '0x8000.*LARGEFILE' "${GOFUSE_DIR}/fuse/print.go"; then
  sed -i.bak '/0x8000.*LARGEFILE/d' "${GOFUSE_DIR}/fuse/print.go"
fi

# --- fuse/syscall_openbsd.go: xattr stubs + writev ---
cat > "${GOFUSE_DIR}/fuse/syscall_openbsd.go" << 'GOEOF'
package fuse

import (
	"os"
	"syscall"
	"unsafe"
)

func sys_writev(fd int, iovecs *syscall.Iovec, cnt int) (n int, err error) {
	n1, _, e1 := syscall.Syscall(
		syscall.SYS_WRITEV,
		uintptr(fd), uintptr(unsafe.Pointer(iovecs)), uintptr(cnt))
	n = int(n1)
	if e1 != 0 {
		err = syscall.Errno(e1)
	}
	return
}

func writev(fd int, packet [][]byte) (n int, err error) {
	iovecs := make([]syscall.Iovec, 0, len(packet))
	for _, v := range packet {
		if len(v) == 0 {
			continue
		}
		vec := syscall.Iovec{
			Base: &v[0],
		}
		vec.SetLen(len(v))
		iovecs = append(iovecs, vec)
	}
	sysErr := handleEINTR(func() error {
		var err error
		n, err = sys_writev(fd, &iovecs[0], len(iovecs))
		return err
	})
	if sysErr != nil {
		err = os.NewSyscallError("writev", sysErr)
	}
	return n, err
}

// OpenBSD doesn't have native xattr syscalls - stub returning ENOTSUP.

func getxattr(path string, attr string, dest []byte) (sz int, errno int) {
	return 0, int(syscall.ENOTSUP)
}

func listxattr(path string, dest []byte) (sz int, errno int) {
	return 0, int(syscall.ENOTSUP)
}

func setxattr(path string, attr string, data []byte, flags int) (errno int) {
	return int(syscall.ENOTSUP)
}

func removexattr(path string, attr string) (errno int) {
	return int(syscall.ENOTSUP)
}

func sysGetxattr(path string, attr string, dest []byte) (sz int, errno int) {
	return 0, int(syscall.ENOTSUP)
}

func sysListxattr(path string, dest []byte) (sz int, errno int) {
	return 0, int(syscall.ENOTSUP)
}

func sysSetxattr(path string, attr string, data []byte, flags int) (errno int) {
	return int(syscall.ENOTSUP)
}

func sysRemovexattr(path string, attr string) (errno int) {
	return int(syscall.ENOTSUP)
}
GOEOF

# --- fuse/print_openbsd.go: init flags + string methods ---
cat > "${GOFUSE_DIR}/fuse/print_openbsd.go" << 'GOEOF'
package fuse

import (
	"fmt"
)

func init() {
	initFlagNames.set(CAP_NODE_RWLOCK, "NODE_RWLOCK")
	initFlagNames.set(CAP_RENAME_SWAP, "RENAME_SWAP")
	initFlagNames.set(CAP_RENAME_EXCL, "RENAME_EXCL")
	initFlagNames.set(CAP_ALLOCATE, "ALLOCATE")
	initFlagNames.set(CAP_EXCHANGE_DATA, "EXCHANGE_DATA")
	initFlagNames.set(CAP_XTIMES, "XTIMES")
	initFlagNames.set(CAP_VOL_RENAME, "VOL_RENAME")
	initFlagNames.set(CAP_CASE_INSENSITIVE, "CASE_INSENSITIVE")
}

func (a *Attr) string() string {
	return fmt.Sprintf(
		"{M0%o SZ=%d L=%d "+
			"%d:%d "+
			"B%d*%d i%d:%d "+
			"A %f "+
			"M %f "+
			"C %f}",
		a.Mode, a.Size, a.Nlink,
		a.Uid, a.Gid,
		a.Blocks, a.Blksize,
		a.Rdev, a.Ino, ft(a.Atime, a.Atimensec), ft(a.Mtime, a.Mtimensec),
		ft(a.Ctime, a.Ctimensec))
}

func (me *CreateIn) string() string {
	return fmt.Sprintf(
		"{0%o [%s]}", me.Mode,
		flagString(openFlagNames, int64(me.Flags), "O_RDONLY"))
}

func (me *GetAttrIn) string() string { return "" }

func (me *MknodIn) string() string {
	return fmt.Sprintf("{0%o, %d}", me.Mode, me.Rdev)
}

func (me *ReadIn) string() string {
	return fmt.Sprintf("{Fh %d [%d +%d) %s}",
		me.Fh, me.Offset, me.Size,
		flagString(readFlagNames, int64(me.ReadFlags), ""))
}

func (me *WriteIn) string() string {
	return fmt.Sprintf("{Fh %d [%d +%d) %s}",
		me.Fh, me.Offset, me.Size,
		flagString(writeFlagNames, int64(me.WriteFlags), ""))
}
GOEOF

# --- fuse/mount_openbsd.go: native OpenBSD FUSE mount via CGo ---
cat > "${GOFUSE_DIR}/fuse/mount_openbsd.go" << 'GOEOF'
package fuse

// #include <sys/param.h>
// #include <sys/mount.h>
// #include <string.h>
// #include <stdlib.h>
// #include <errno.h>
//
// // openbsd_mount_fuse calls mount(2) for FUSE. Returns 0 on success, errno on failure.
// int openbsd_mount_fuse(const char *dir, const char *name, int fd, int max_read, int allow_other) {
//     struct fusefs_args args;
//     memset(&args, 0, sizeof(args));
//     args.name = (char *)name;
//     args.fd = fd;
//     args.max_read = max_read;
//     args.allow_other = allow_other;
//     if (mount("fuse", dir, 0, &args) == -1) {
//         return errno;
//     }
//     return 0;
// }
import "C"

import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

func unixgramSocketpair() (l, r *os.File, err error) {
	fd, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, nil, os.NewSyscallError("socketpair",
			err.(syscall.Errno))
	}
	l = os.NewFile(uintptr(fd[0]), "socketpair-half1")
	r = os.NewFile(uintptr(fd[1]), "socketpair-half2")
	return
}

func mount(mountPoint string, opts *MountOptions, ready chan<- error) (fd int, err error) {
	// Open the FUSE device
	f, err := os.OpenFile("/dev/fuse0", os.O_RDWR, 0)
	if err != nil {
		return -1, fmt.Errorf("opening /dev/fuse0: %v", err)
	}
	fd = int(f.Fd())

	// Build volume name
	name := opts.Name
	if name == "" {
		name = "juicefs"
	}

	// Determine max read size
	maxRead := opts.MaxWrite
	if maxRead == 0 {
		maxRead = 65536
	}

	// Check for allow_other option
	allowOther := 0
	for _, o := range opts.optionsStrings() {
		if strings.Contains(o, "allow_other") {
			allowOther = 1
		}
	}

	// Call C mount() via CGo - Go's raw syscall.Syscall6(SYS_MOUNT) returns
	// ENOSYS on OpenBSD, but C's mount() works correctly.
	cDir := C.CString(mountPoint)
	defer C.free(unsafe.Pointer(cDir))
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))

	ret := C.openbsd_mount_fuse(cDir, cName, C.int(fd), C.int(maxRead), C.int(allowOther))
	if ret != 0 {
		f.Close()
		return -1, fmt.Errorf("mount fuse on %s: %v", mountPoint, syscall.Errno(ret))
	}

	// Prevent fd from being closed when f goes out of scope
	f = nil

	syscall.CloseOnExec(fd)

	go func() {
		ready <- nil
		close(ready)
	}()

	return fd, nil
}

func unmount(dir string, opts *MountOptions) error {
	return syscall.Unmount(dir, 0)
}
GOEOF

# --- Copy Darwin platform files as OpenBSD equivalents ---
for f in \
  fuse/poll_darwin.go \
  fuse/request_darwin.go \
  fuse/server_darwin.go \
  fuse/splice_darwin.go \
  fs/constants_darwin.go \
  fs/dirstream_darwin.go \
  fs/files_darwin.go \
  fs/loopback_darwin.go \
  fuse/nodefs/files_darwin.go \
  fuse/pathfs/loopback_darwin.go \
  internal/renameat/renameat_darwin.go \
  internal/utimens/utimens_darwin.go \
  splice/pair_darwin.go \
  splice/splice_darwin.go \
; do
  src="${GOFUSE_DIR}/${f}"
  dst="${GOFUSE_DIR}/$(echo "$f" | sed 's/_darwin\.go$/_openbsd.go/')"
  if [ -f "$src" ] && [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "Copied $f -> $(basename "$dst")"
  fi
done

##############################################################################
# godaemon patch - add openbsd to build tags
##############################################################################
GODAEMON_DIR=$(find "$(go env GOMODCACHE)" -path '*/godaemon@*' -type d 2>/dev/null | head -1)
if [ -n "$GODAEMON_DIR" ] && [ -f "$GODAEMON_DIR/daemon.go" ]; then
  chmod -R u+w "$GODAEMON_DIR"
  if ! grep -q 'openbsd' "$GODAEMON_DIR/daemon.go"; then
    sed -i.bak 's|^// +build darwin freebsd linux|// +build darwin freebsd linux openbsd|' "$GODAEMON_DIR/daemon.go"
    echo "Patched godaemon build tags"
  fi
fi

echo "=== OpenBSD dependency patching complete ==="
