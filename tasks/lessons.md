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

## Communication

### Notify on remote at every pause, not only at the end
The user switches workspaces and does not see questions or pauses in the terminal. Send a push notification whenever a question is asked, a review is requested, a stage finishes or work is blocked. (Corrected 2026-10-09 during OSS-5 brainstorming.)

## Upstream sync tooling (OSS-5)

### The patch script writes Go files that only compile on OpenBSD
A misplaced edit in `hack/openbsd_patch_deps.sh` put shell lines inside a Go here-document. Every local check passed (lint, file-existence checks) and the first pipeline failed in `go build`. `check-patches` now runs `gofmt -e` over the generated `*_openbsd.go` files, which catches syntax errors without an OpenBSD host. When editing the here-documents, run `sh hack/openbsd_sync_upstream.sh check-patches` before pushing.

### `cp` into a JuiceFS mount failed on OpenBSD with "Bad file descriptor"
OpenBSD's `cp` calls `ftruncate` on the destination after copying and reports a failure against the *source* path. OpenBSD's libfuse only offers the path-based `truncate`, so cgofuse calls our `Truncate` with no file handle (`fh = ^0`). The bridge (derived from the Windows code) returned `EBADF` in that case. Fix: resolve the inode from the path when there is no handle. Found by the package smoke test; tools that never truncate (e.g. `dd`) were unaffected.

### Stale file size right after close on OpenBSD
After writing and closing a file, `stat`/`ls -l`/a fresh read by path saw size 0 for about a second (the `--attr-cache` time), then the right size. No data was lost. Path-based `Getattr` in `pkg/cgofuse` is answered by `pkg/fs`, which keeps its own attribute cache; the bridge only dropped its per-handle cache. Fix: `invalidateAttrCache` also calls `fs.InvalidateAttr` (as upstream's Windows bridge does), and `Flush`/`Release` call it. Symptom in practice: a checksum or size check run immediately after a copy fails, a later one passes.

### A background `sleep` kept the pipeline job open for five minutes
The smoke test's first watchdog was `( sleep 300; ... ) &`. Killing the subshell does not kill its `sleep`, and the GitLab job did not finish until that orphan exited, so every smoke job took 315 s instead of about 15 s. A watchdog must poll in short steps and stop when the main script is gone (`kill -0 $$`). Check job durations after adding any background process to a CI script.

### Link count was stale after `ln` / `rm` on OpenBSD
Same cause as the stale size: the fs-layer attribute cache. `Link` and `Unlink` in `pkg/cgofuse` now invalidate the inode's cached attributes. The smoke test checks the link count after `ln` and after `rm`.
