# Lessons Learned

## OpenBSD Build & Packaging

### Go filename build constraints
Go's `_GOOS.go` naming convention only matches the **last** `_` segment before `.go`. A file named `utils_openbsd_sys.go` matches `_sys`, NOT `_openbsd`. It compiles on ALL platforms. Must add explicit `//go:build openbsd` tag if the filename has extra suffixes after the OS name.

### GitLab Runner on OpenBSD requires bash
OpenBSD ships with `ksh` and `sh` but GitLab Runner's shell executor only supports `bash`. Must `pkg_add bash` on the builder. Neither `shell = "sh"` nor `shell = "ksh"` in runner config works.

### CGO_ENABLED=1 is required for cgofuse
cgofuse has two code paths: `host_cgo.go` (uses `dlopen` to find libfuse at runtime) and `host.go` (non-cgo fallback that panics with "cannot find FUSE"). Must set `CGO_ENABLED=1` explicitly in the build command.

### libfuse.so version differs between OpenBSD releases
- OpenBSD 7.4: `/usr/lib/libfuse.so.2.0`
- OpenBSD 7.8: `/usr/lib/libfuse.so.3.0`
cgofuse hardcodes `dlopen("libfuse.so.2.0")`. The patch script must auto-detect the actual version on the system and patch the dlopen call. libfuse is part of OpenBSD base system, NOT an installable package.

### OpenBSD pkg_create quirks (7.8)
- `@name` in +CONTENTS conflicts with the output filename argument → "Duplicate name" error. Remove it; pkg_create derives the name from the filename.
- `@arch` cannot be set explicitly → "can't be set explicitly" error. Remove it; auto-detected.
- `@comment` in packing list is not recognized as the comment. Must use `-D COMMENT="value"` flag instead.
- `-P` dependency flag format: `"pkgname-*:pkgname->=version:pkgpath"`

### OpenBSD FUSE package vs base system libfuse
The `fuse` package in OpenBSD ports is NOT the FUSE library. The actual libfuse (`/usr/lib/libfuse.so.*`) ships with the OpenBSD base system. No package dependency needed for JuiceFS.

### mount_unix.go build tag must stay `!windows` only
`mount_unix.go` contains shared functions needed on ALL Unix platforms including OpenBSD: `makeDaemon`, `mountFlags`, `launchMount`, `prepareMp`, `makeDaemonForSvc`, etc. Only `mountMain` is platform-specific (extracted to `mount_main_gofuse.go` for non-OpenBSD, `mount_openbsd.go` for OpenBSD). Adding `!openbsd` to mount_unix.go breaks the build with ~10 "undefined" errors.

### syscall.ENODATA does not exist on OpenBSD
OpenBSD uses `syscall.ENOATTR` instead. The `meta.ENOATTR` constant is already defined per-platform and should be used in shared code (`pkg/vfs/vfs.go`) instead of `syscall.ENODATA`.

### OpenBSD Statfs_t uses different field names
OpenBSD's `syscall.Statfs_t` uses `F_blocks`, `F_bsize`, `F_bavail`, `F_files`, `F_ffree` (with `F_` prefix) instead of Linux's `Blocks`, `Bsize`, etc. That's why `pkg/chunk/utils_unix.go` must exclude openbsd and a separate `utils_openbsd_sys.go` provides the implementation.

## OpenBSD Service Management (rc.d)

### JuiceFS syslog logging requires -d flag
`InitLoggers()` (which enables syslog) is only called inside `daemonRun()`, which only runs when `-d`/`--background` flag is set. In foreground mode, logs go only to stdout/stderr. For rc.d, use `-d --log /var/log/juicefs.log` to get both syslog and file logging.

### rc.d subshell detach pattern
OpenBSD's rc.subr runs `pkill -P $$` on cleanup, which kills child processes. Use `(command &)` subshell pattern to detach the daemon from rc.d's process tree.

### newsyslog for log rotation
OpenBSD uses `newsyslog` (not logrotate). Config in `/etc/newsyslog.conf`. Format: `logfile_name mode count size when flags`. Can be auto-configured idempotently via `@exec`/`@unexec` in pkg packing list.

## OpenBSD cgofuse FUSE Bridge

### Why cgofuse instead of go-fuse on OpenBSD
OpenBSD's FUSE kernel uses a custom `fusebuf` wire protocol, NOT the standard Linux FUSE protocol. go-fuse speaks Linux FUSE directly on the fd, so it cannot work on OpenBSD. cgofuse links against OpenBSD's system libfuse via CGo, which handles the fusebuf translation.

### go-fuse dependency patching at build time
go-fuse and godaemon are vendored dependencies that need OpenBSD patches (types, attributes, mount via CGo, xattr stubs, build tags). These are patched at build time via `hack/openbsd_patch_deps.sh` since they're not in the JuiceFS source tree. The script must run after `go mod download` and before `go build`.
