# Upstream sync routine for the OpenBSD fork (OSS-5)

Date: 2026-10-09
Status: approved; revised after plan review (see "Revisions" at the end)

## Goal

Make syncing this fork with upstream JuiceFS a routine task, and prove the
routine by performing one real sync to `v1.4.1`.

Success means the next sync follows a written procedure without new decisions.

## Starting point

- Fork point: `f13b3dfe` (upstream `main`, 2026-03-19).
- Our delta: 20 commits, 24 files. Only three upstream files are edited:
  `cmd/mount_unix.go`, `pkg/chunk/utils_unix.go`, `pkg/vfs/vfs.go`.
- Upstream cuts releases from `release-X.Y` branches. `v1.4.1` has 293 commits
  since the fork point, 11 of them not on upstream `main`.
- A dry-run merge of `v1.4.1` conflicts in `cmd/mount_unix.go` and `CLAUDE.md`.
- `v1.4.1` requires Go 1.25.0 (fork: 1.23.0) and moves the `juicedata/go-fuse`
  replace target from a 2025-08 to a 2026-06 revision. `godaemon` and `cgofuse`
  versions are unchanged.
- `origin/NO_ISSUE-sync-with-upstream` is an earlier rebase attempt (upstream as
  of 2026-07-14) holding three fixes that never reached `main`.

## Decisions

| Topic | Decision |
|---|---|
| What to track | Upstream release tags, starting with `v1.4.1` |
| How to sync | Rebase our commit stack onto the tag; force-push `main` |
| Verification | Pipeline green including an automated mount smoke test on OpenBSD |
| Smoke test privileges | Runner user gets one `doas` rule; set up by the repo owner |

## Branch and tag model

- `main` is always one upstream release tag plus our OpenBSD commits on top.
- Each sync is done on a work branch `<JIRA>-sync-<tag>`, for example
  `OSS-5-sync-v1.4.1`.
- Before `main` moves, its old tip is tagged `pre-sync/<tag>` and pushed to both
  remotes (`gitlab`, `origin`).

## One-time preparation

### Squash the commit stack

The 20 commits are squashed into five, in this order:

1. OpenBSD platform source files and build-tag changes in shared files
2. cgofuse FUSE bridge and the `mountMain` split
3. Dependency patching script
4. Package, rc.d and newsyslog files
5. GitLab pipeline, sync tooling, agent notes, docs and `tasks/`

The stack is built by regrouping the tree by path (`restack`). It is accepted
only if the tree is unchanged by the regrouping.

### Move our CLAUDE.md content

Our `CLAUDE.md` has no OpenBSD content and duplicates upstream's `AGENTS.md`.
It is deleted. Fork-only notes live in `.claude/rules/openbsd.md`. Upstream's
`CLAUDE.md` is not edited.

### Reuse fixes from the old attempt

From `origin/NO_ISSUE-sync-with-upstream`, fold into the matching commit:

- `7ef42c60` define `MSG_CMSG_CLOEXEC` for OpenBSD → commit 3 (it only touches
  the patch script)
- `18d1d497` `cmd/` build fix after sync → commit 2 (needed: `v1.4.1` has
  `cmd/passfd.go`)
- `8e0a9c48` write the `.tgz` into `CI_PROJECT_DIR` → commits 4 and 5

The branch is deleted on both remotes once OSS-5 is done.

## The sync routine

1. Fetch upstream tags and pick the target tag.
2. Preflight: compare the tag's `go.mod` with `main` for the `go` line and the
   versions of `go-fuse` (including its `replace` target), `godaemon` and
   `cgofuse`. Report every difference.
3. Create the work branch from the current stack; run
   `git rebase --onto <tag> <previous-base>`, where `<previous-base>` is the
   tag `main` currently sits on (`f13b3dfe` for the first sync).
4. Resolve conflicts commit by commit, with `git rerere` enabled.
5. Push the work branch. The pipeline builds, packages and smoke-tests it.
6. Fix failures as ordinary commits and fold them into the owning commit with
   `restack`.
7. Add an entry to the sync log in `docs/openbsd/upstream-sync.md`.
8. When green: tag `pre-sync/<tag>` on the old `main`, push the tag, force-push
   the work branch to `main` on both remotes, delete the work branch.

`hack/openbsd_sync_upstream.sh` has four subcommands: `preflight`, `start`,
`restack` and `check-patches`. The previous base is the parent of the newest
commit titled "OpenBSD: platform source files and build tags"; every commit
above it must be absent from upstream `main` and from all `v*` tags.
`git describe` and `merge-base` are not used: the first returns `v1.4.0-dev`
today, the second replays upstream backports once `main` sits on a release tag.

## Verification

Pipeline: `wake-up → build → package → smoke`, on work branches and `main`.

### Build stage

- Print `$CI_PROJECT_DIR` (used to write the `doas` rule).
- Compare the builder's `go version` with the `go` line in `go.mod`. Fail with
  a message naming the required version if the builder is older. The build
  keeps `GOTOOLCHAIN=local`.

### Dependency patch script

`hack/openbsd_patch_deps.sh` changes:

- Resolve each module directory with `go list -m -f '{{.Dir}}' <module>`
  instead of `find … | head -1`, which can pick a stale version from the module
  cache.
- After each patch step, verify the expected file exists or the expected text
  is present. Exit non-zero and name the step otherwise.
- Stay idempotent: a second run on an already patched cache succeeds.

### Smoke test

`hack/openbsd_smoke_test.sh`, run as root through `doas`:

1. Abort if a `juicefs mount` process is running or any `/etc/juicefs/*.env`
   exists.
2. `pkg_add` the package.
3. Format a throwaway volume: SQLite metadata and `file` storage, both under a
   `mktemp -d` directory.
4. Write `/etc/juicefs/smoke.env` and run `rcctl -f start juicefs`.
5. Wait up to 30 seconds for the mount point to become a JuiceFS mount.
6. Write an 8 MiB file of random data, read it back, compare SHA-256. Create,
   list and remove a directory.
7. `rcctl stop juicefs`; confirm the mount point is released within 30 seconds.
8. Fail if the log file contains `panic`.
9. Cleanup runs from a trap on every exit path: unmount, `pkg_delete juicefs`,
   remove the env file, the temp directory and the smoke log.

### Builder prerequisite

Set up once by the repo owner, as root on the builder:

```
permit nopass gitlab-runner as root cmd /bin/sh args <CI_PROJECT_DIR>/hack/openbsd_smoke_test.sh
```

The rule matches the arguments exactly, so the script takes no arguments: it
locates the single `juicefs-*.tgz` in its own project directory and fails if
there is none or more than one. The runner user on the builder is
`gitlab-runner` (uid:gid 1001:1001). `<CI_PROJECT_DIR>` is taken from the first
pipeline run on the tooling branch and recorded, with the final line, in
`docs/openbsd/upstream-sync.md`.

Trust note: the script and package come from the repository, so whoever can
push a branch that runs this pipeline effectively has root on the builder. This
design assumes the builder is a dedicated VM and push access is limited to the
repo owner. If that stops being true, the smoke job becomes a manual job.

## Failure handling

| Situation | Response |
|---|---|
| Rebase too tangled | `git rebase --abort`; `main` is untouched |
| Pipeline red on work branch | Amend the owning commit, force-push the work branch; `main` keeps the old base |
| Problem found after `main` moved | `git push --force <remote> pre-sync/<tag>:main` on each remote |
| Builder Go too old | Build stage stops with the required version; owner upgrades Go |
| Dependency patch no longer applies | Patch script names the failing step; repair is part of that sync, in commit 3 |

## Deliverables

| File | Purpose |
|---|---|
| `docs/openbsd/upstream-sync.md` | Prerequisites, routine, conflict guide for the three shared files, rollback, sync log |
| `hack/openbsd_sync_upstream.sh` | Fetch, preflight report, start the rebase |
| `hack/openbsd_smoke_test.sh` | Smoke test |
| `hack/openbsd_check_go.sh` | Go version check before the build |
| `hack/openbsd_patch_deps.sh` | Hardened module lookup and step checks |
| `.gitlab-ci.yml` | Go version check, `smoke` stage, artifact path fix |
| `.claude/rules/openbsd.md` | Fork-only agent notes |
| `main` | `v1.4.1` plus five OpenBSD commits |

New shell scripts and Go files carry the Apache 2.0 header, as the repo
requires.

## Out of scope

- Tracking upstream `main`, or running the sync on a schedule.
- Running upstream unit tests on OpenBSD.
- Package revision suffixes (`p0`, `p1`) for rebuilds of one upstream version.
- Offering the port to upstream.

## Acceptance

1. `main` on both remotes is `v1.4.1` plus five commits.
   `git diff --name-status v1.4.1 main` lists only added files plus three
   modified ones: `cmd/mount_unix.go`, `pkg/chunk/utils_unix.go`,
   `pkg/vfs/vfs.go`.
2. The pipeline on `main` is green through `smoke`.
3. `pre-sync/v1.4.1` exists on both remotes.
4. `docs/openbsd/upstream-sync.md` is complete, and
   `hack/openbsd_sync_upstream.sh` has been dry-run against the next upstream
   tag after `v1.4.1`, or against `upstream/main` if none exists, up to and
   including the start of the rebase, then aborted.

## Revisions

- 2026-10-09: corrected after five reviews of the implementation plan. See
  "Deviations from the spec" in
  `docs/superpowers/plans/2026-10-09-upstream-sync.md` for the reasons.
