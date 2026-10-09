# Syncing the OpenBSD fork with upstream

`main` is always **one upstream release tag plus five commits**:

| # | Commit subject | Paths |
|---|---|---|
| 1 | OpenBSD: platform source files and build tags | `pkg/**` except `pkg/cgofuse/**` |
| 2 | OpenBSD: cgofuse FUSE bridge and mountMain split | `cmd/**`, `pkg/cgofuse/**` |
| 3 | OpenBSD: dependency patching script | `hack/openbsd_patch_deps.sh` |
| 4 | OpenBSD: package, rc.d and newsyslog files | `deploy/openbsd/**` |
| 5 | OpenBSD: CI pipeline, sync tooling and notes | `.gitlab-ci.yml`, `CLAUDE.md`, `.claude/**`, `docs/openbsd/**`, `docs/superpowers/**`, `tasks/**`, `hack/openbsd_sync_upstream.sh`, `hack/openbsd_check_go.sh`, `hack/openbsd_smoke_test.sh` |

A file belongs to a commit by its path, so the stack can be rebuilt at any
time with `sh hack/openbsd_sync_upstream.sh restack`. That is how a fix is
"amended into the owning commit": commit it normally, then restack. Restack
keeps the message, author and date of each stack commit and refuses paths
that are not in the table. To add a new path, extend the table here and the
`restack` function in the script.

We track upstream **release tags**, not upstream `main`. Upstream cuts releases
from `release-X.Y` branches, so tags are not ancestors of each other across
minor versions. That is why we rebase instead of merging.

Never give the fork a tag that starts with `v`. The tooling treats `v*` tags
as upstream releases.

## Prerequisites (once)

- Remotes: `gitlab` (CI runs here) and `origin` (GitHub mirror). Upstream is
  fetched over HTTPS by the helper script; no `upstream` remote is required.
- GitLab: force-push to `main` allowed for the maintainer.
- Builder (OpenBSD VM, runner user `gitlab-runner`): Go at least as new as the
  `go` line in `go.mod`, `bash` installed (the GitLab shell executor needs it),
  runner `concurrent = 1`, and this line appended to `/etc/doas.conf`:

  ```
  permit nopass gitlab-runner as root cmd /bin/sh args <CI_PROJECT_DIR>/hack/openbsd_smoke_test.sh
  ```

  `<CI_PROJECT_DIR>` is the builder's project directory; the `build` job prints
  it. The rule matches the path exactly. If the runner is re-registered or its
  concurrency changes, the directory changes and the rule must be updated.

  Trust note: the smoke script and the package come from the repository, so
  whoever can push a branch that runs the pipeline has root on the builder.
  Keep the builder a dedicated VM and push access limited to the owner. If
  that stops being true, make the `smoke` job manual.

## What the pipeline does

`wake-up → build → package → smoke`, on every branch. Tag pushes start no
pipeline.

- `build` first checks that the builder's Go is new enough for `go.mod`
  (`hack/openbsd_check_go.sh`), then patches the dependencies and builds.
- `package` leaves one `juicefs-<version>.tgz` in the project directory.
- `smoke` runs `hack/openbsd_smoke_test.sh` three times: once without root
  (it must refuse), once with a simulated builder crash (it must die mid-run),
  and once for real. The real run has to clean up after the crashed one,
  install the package, mount a throwaway volume through rc.d, write and read
  back data, and unmount. Its state is kept in `/var/db/juicefs-smoke`.
- A package that passed is copied to `PKG_PUBLISH_DIR`
  (`/build/gitlab-runner/builds/openbsd7.8/amd64/juicefs`) on the builder.

The smoke test refuses to run on a host with other `/etc/juicefs/*.env` files,
a running `juicefs mount`, or an installed `juicefs` package it did not
install itself.

## Routine

Replace `vX.Y.Z` with the new tag and `OSS-N` with the Jira issue.

1. Start from an up-to-date `main` with a clean tree.

   ```sh
   git switch main && git pull --ff-only gitlab main
   ```

2. Preflight, create the work branch and start the rebase.

   ```sh
   JIRA_KEY=OSS-N sh hack/openbsd_sync_upstream.sh start vX.Y.Z
   ```

   The script fetches upstream, reports changes in the Go version and in the
   modules we patch (`go-fuse`, `godaemon`, `cgofuse`), creates
   `OSS-N-sync-vX.Y.Z` and rebases the five commits onto the tag. It finds the
   stack by its commit subjects and refuses to run if the commits above the
   base are not exactly the five. It also turns on `git rerere` for this
   repository, so conflict resolutions are remembered.

3. Resolve conflicts. While the rebase is stopped this file is not in the
   working tree; read it with `git show ORIG_HEAD:docs/openbsd/upstream-sync.md`.
   Then `git add <files> && GIT_EDITOR=true git rebase --continue`.

4. Check locally what can be checked off OpenBSD. Commit any fixes.

   ```sh
   sh hack/openbsd_sync_upstream.sh check-patches       # patch script vs new module versions
   gofmt -l $(git diff --name-only vX.Y.Z HEAD -- '*.go')   # must print nothing
   go build -o /dev/null .                              # Linux build must still work
   go vet ./cmd/ ./pkg/vfs/ ./pkg/chunk/
   ```

5. Rebuild the stack and push the work branch.

   ```sh
   sh hack/openbsd_sync_upstream.sh restack
   git push -u --force-with-lease gitlab OSS-N-sync-vX.Y.Z
   ```

6. Wait for the pipeline (`build → package → smoke`). On failure: fix, commit,
   repeat step 5. `main` is untouched until the pipeline is green.

7. Add a line to the sync log at the end of this file, commit, and repeat
   step 5 once more. The log entry is then part of the stack.

8. Move `main` once the pipeline is green.

   ```sh
   git fetch gitlab main && git fetch origin main
   git tag pre-sync/vX.Y.Z gitlab/main
   git push gitlab pre-sync/vX.Y.Z && git push origin pre-sync/vX.Y.Z
   git branch -f main OSS-N-sync-vX.Y.Z
   git push --force-with-lease=main:pre-sync/vX.Y.Z gitlab main
   git push --force-with-lease=main:pre-sync/vX.Y.Z origin main
   ```

   If `gitlab` accepts and `origin` rejects, fix the cause and repeat only the
   `origin` push; do not roll `gitlab` back.

9. Wait for the pipeline on `main`. If it fails for an infrastructure reason
   (runner offline, builder asleep), retry it. If it fails for a real reason
   that the work branch did not show, roll back (below) and investigate.
   When it is green, delete the work branch:
   `git push gitlab --delete OSS-N-sync-vX.Y.Z`.

## Conflict guide

The port edits three upstream files.

### `cmd/mount_unix.go` (commit 2)

We remove `mountMain` from this file. The go-fuse version lives in
`cmd/mount_main_gofuse.go` (`!windows && !openbsd`), the cgofuse version in
`cmd/mount_openbsd.go`. The build tag of `mount_unix.go` stays `!windows`.

Whenever upstream touches the file, take upstream's version, cut `mountMain`
out again and refresh our copy of it. In a rebase, `--ours` is the new upstream
base:

```sh
git checkout --ours -- cmd/mount_unix.go
awk '/^func mountMain\(/{skip=1} !skip{print} skip&&/^}/{skip=0}' cmd/mount_unix.go > mount_unix.tmp \
  && mv mount_unix.tmp cmd/mount_unix.go
{ sed -n '1,/^)$/p' cmd/mount_main_gofuse.go; echo
  git show vX.Y.Z:cmd/mount_unix.go | awk '/^func mountMain\(/,/^}/'; } > gofuse.tmp \
  && mv gofuse.tmp cmd/mount_main_gofuse.go
gofmt -w cmd/mount_unix.go cmd/mount_main_gofuse.go
go build -o /dev/null .
```

If the compiler reports an unused import in `mount_unix.go`, remove it there;
if it reports an undefined package in `mount_main_gofuse.go`, add the import
there. Then compare upstream's new `mountMain` with `cmd/mount_openbsd.go` and
carry over anything that is not specific to go-fuse or Linux:

```sh
git diff <previous tag> vX.Y.Z -- cmd/mount_unix.go
```

### `pkg/chunk/utils_unix.go` (commit 1)

Our change is only the build tag: `!windows && !openbsd`. Keep upstream's body.
If upstream adds a function here, add an OpenBSD counterpart to
`pkg/chunk/utils_openbsd_sys.go` (OpenBSD `Statfs_t` fields have an `F_` prefix).

### `pkg/vfs/vfs.go` (commit 1)

Our change is one line in `GetXattr`: `meta.ENOATTR` instead of
`syscall.ENODATA`, which OpenBSD does not have. If upstream uses
`syscall.ENODATA` in new places, replace those too.

### New platform constants

When upstream adds a per-platform file pair such as `foo_linux.go` /
`foo_darwin.go`, OpenBSD usually needs `foo_openbsd.go` mirroring the Darwin
one (example: `cmd/passfd_openbsd.go`). The pipeline's `build` job reports
these as `undefined:` errors.

### `hack/openbsd_patch_deps.sh` (commit 3)

No git conflicts, but a go-fuse bump can break a patch. The script stops with
`ERROR: step '<name>': …`; fix that step. `check-patches` reproduces it locally.

## Rollback

- During the rebase: `git rebase --abort`.
- Work branch pipeline red: `main` still has the old base; keep fixing or drop
  the branch.
- After `main` moved:

  ```sh
  git push --force gitlab pre-sync/vX.Y.Z:main
  git push --force origin pre-sync/vX.Y.Z:main
  ```

## Sync log

| Date | From | To | Jira | Notes |
|---|---|---|---|---|
| 2026-10-09 | `f13b3dfe` (upstream main, 2026-03-19) | `v1.4.1` | OSS-5 | First sync. Conflict in `cmd/mount_unix.go` only. Added `cmd/passfd_openbsd.go` and `MSG_CMSG_CLOEXEC` in the go-fuse patch. Builder Go 1.25.1 (needs >= 1.25.0). The new smoke test found two older bugs in `pkg/cgofuse`, fixed in this sync: path-based truncate returned `EBADF` (broke `cp`), and file size was stale for about a second after close. |
