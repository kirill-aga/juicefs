# Upstream Sync Routine (OSS-5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repeatable routine for rebasing the OpenBSD fork onto upstream release tags, and prove it by syncing `main` to `v1.4.1`.

**Architecture:** Our port is a stack of five commits on top of an upstream tag. Every path we own belongs to exactly one of the five commits, so the stack can always be rebuilt from a tree (`restack`). Tooling is built and proven on the old base first, then the stack is rebased onto `v1.4.1`, verified by the GitLab pipeline (build, package, smoke test on OpenBSD), and only then force-pushed to `main`.

**Tech Stack:** POSIX `sh` (dev machine: dash/bash, builder: OpenBSD ksh), git, Go toolchain, GitLab CI with an OpenBSD 7.8 shell runner, `doas`, `pkg_add`/`rcctl`, `glab`.

**Spec:** `docs/superpowers/specs/2026-10-09-upstream-sync-design.md`

**Status: executed; kept as a record.** The scripts and `.gitlab-ci.yml` on `main` are authoritative and differ from the text embedded below: `check-patches` also parses the generated Go files, the smoke test keeps its state in `/var/db/juicefs-smoke`, has a watchdog, a crash-simulation hook and a hard-link check, and the pipeline publishes tested packages. Two fixes in `pkg/cgofuse/cgofuse.go` were made during execution. See `tasks/lessons.md` and the review section of `tasks/todo.md`.

**Revision:** 2 (2026-10-09), after five independent reviews. The sync helper in Task 1 was executed against the real repository in a throwaway worktree; outputs quoted there are observed, not predicted.

## Global Constraints

- Sync target is the upstream release tag `v1.4.1`. Fork point (previous base) is `f13b3dfe`.
- `main` must end as `v1.4.1` plus exactly five commits, in this order:

  | # | Subject | Paths |
  |---|---|---|
  | 1 | `OpenBSD: platform source files and build tags` | `pkg/**` except `pkg/cgofuse/**` |
  | 2 | `OpenBSD: cgofuse FUSE bridge and mountMain split` | `cmd/**`, `pkg/cgofuse/**` |
  | 3 | `OpenBSD: dependency patching script` | `hack/openbsd_patch_deps.sh` |
  | 4 | `OpenBSD: package, rc.d and newsyslog files` | `deploy/openbsd/**` |
  | 5 | `OpenBSD: CI pipeline, sync tooling and notes` | `.gitlab-ci.yml`, `CLAUDE.md`, `.claude/**`, `docs/openbsd/**`, `docs/superpowers/**`, `tasks/**`, `hack/openbsd_sync_upstream.sh`, `hack/openbsd_check_go.sh`, `hack/openbsd_smoke_test.sh` |

  A changed path outside this table makes `restack` fail on purpose; extend the table and the script together.
- Fixes are made as ordinary commits and folded into the owning commit by `restack`. No fix-up commits remain in the final stack.
- `main` is not touched until the pipeline on the work branch is green through `smoke`.
- Before `main` moves, its old tip is tagged `pre-sync/v1.4.1` and pushed to both remotes (`gitlab`, `origin`).
- Tooling branch (current): `OSS-5-upstream-sync-routine`. Sync work branch: `OSS-5-sync-v1.4.1`.
- The build keeps `GOTOOLCHAIN=local`. `v1.4.1` needs Go >= 1.25.0 on the builder.
- Runner user on the builder is `gitlab-runner` (uid:gid 1001:1001).
- Every fork-owned shell script and new Go file carries the Apache 2.0 header. New scripts are committed with mode 755.
- Shell scripts must pass `shellcheck -s sh` and `dash -n`, and run under OpenBSD `/bin/sh`.
- Upstream is fetched over HTTPS (`https://github.com/juicedata/juicefs.git`); SSH to github.com fails host-key verification on the dev machine.
- CI runs on the `gitlab` remote only. OpenBSD compilation can only be verified there: a local `GOOS=openbsd` cross-build fails in cgo-only dependencies.
- Never tag the fork itself with a `v*` name; `v*` tags mean "upstream release" to the tooling.
- Agent-made commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. `restack` carries `Co-Authored-By` trailers of folded commits into the stack commit they land in (the existing history already has such trailers).
- No absolute local paths or session URLs in tracked files; these documents end up on `main` and on the GitHub mirror.
- **End of every task:** tick the task in `tasks/todo.md` in that task's last commit, then **NOTIFY** the user (PushNotification; if the tool is unavailable, state it at the top of the next reply). Also NOTIFY at every step marked so.
- After any correction from the user during execution, add the lesson to `tasks/lessons.md`.
- Waiting for a pipeline means: poll `glab ci status -b <branch>` (or the `mcp__GitLab__glab_ci_status` tool) until no job is `running` or `pending`; do not read a result earlier. Use a background wait rather than a busy loop.

### Deviations from the spec

The spec is updated in Task 5 to match these.

1. **Helper script interface.** Instead of `hack/openbsd_sync_upstream.sh <tag>` the script has four subcommands: `preflight`, `start`, `restack`, `check-patches`.
2. **Finding the previous base.** Neither `git describe` (returns `v1.4.0-dev` today, so the spec's fallback never fires) nor `merge-base` (would replay 16 upstream backports once `main` sits on `v1.4.1`) is used. The base is the parent of the newest commit titled `OpenBSD: platform source files and build tags`, and every commit above it must be absent from upstream `main` and from all `v*` tags.
3. **"Amend the owning commit" is done by `restack`,** which regroups the tree by path. It reuses message, author and date of the existing stack commit, and on first creation lists the subjects of the commits it replaces.
4. **Squash check.** `restack` proves "tree unchanged". Task 1 additionally proves `git diff main` is empty for a restack of `main` itself; Task 6 lists the exact files that differ from `main` after the tooling tasks.
5. **Commit 5 is wider than in the spec:** it also holds the three new `hack/` scripts, `.claude/rules/openbsd.md`, `docs/openbsd/` and `docs/superpowers/`.
6. **`CLAUDE.md`.** Our `CLAUDE.md` has no OpenBSD content and duplicates upstream's `AGENTS.md`, so it is deleted instead of moved. Fork-only notes go to `.claude/rules/openbsd.md`, which Claude Code loads automatically. Upstream's `CLAUDE.md` is not edited, so the delta against the tag contains only three shared files.
7. **Order of work.** Tooling is built and proven on the old base (Tasks 1 to 6) before the rebase, and the sync starts from the tooling branch, not from `main`. `7ef42c60` (the go-fuse `MSG_CMSG_CLOEXEC` constant) therefore lands in commit 3 on the old base; it is harmless there because the old go-fuse revision neither defines nor uses the name.
8. **Go version check** is a separate script, `hack/openbsd_check_go.sh`, so it can run before `go mod download`.
9. **Smoke test** takes a lock, refuses to run when a `juicefs` package is already installed, cleans up after a killed earlier run, proves the mount is JuiceFS by checking that objects reach the storage directory, and removes the cache directory it created.
10. **Pipeline:** tag pushes do not start pipelines, and the `smoke` job has a resource group so two runs cannot overlap.
11. **Small behaviour changes:** `build_pkg.sh` removes old `juicefs-*.tgz` first; the patch script no longer traces (`set -e` instead of `set -ex`), patches cgofuse only on OpenBSD and fails there without libfuse; `cmd/mount_openbsd.go` follows upstream's `%s` → `%q` log change.
12. **The sync log entry is written before `main` moves,** so it is part of commit 5 and no second force-push is needed.
13. **`NO_ISSUE-sync-with-upstream` is deleted on `gitlab` too** (the spec names only `origin`), and a Jira comment is added at the end.

## Review Focus

1. **Smoke script started on the wrong host or without root:** must exit non-zero before touching anything. Pinned in Task 4 Step 4 (Linux) and by the first line of the `smoke` job (OpenBSD, no `doas`).
2. **A previous smoke run was killed,** at any point including between `pkg_add` and writing the env file: the next run must clean up and pass. Pinned by the lock/marker logic in Task 4 and exercised in Task 6 Step 5.
3. **Module cache holds an older go-fuse version** next to the current one: the patch script must patch the version `go.mod` selects. Pinned in Task 3 Step 5.
4. **`restack` with a wrong base, a dirty tree, an unowned path or a failing commit:** must refuse or roll back, leaving the branch as it was. Pinned in Task 1 Step 2.
5. **`start` with a non-existent tag, a stack that is not the five commits, or a fork tip carrying a `v*` tag:** must stop before creating a branch. Pinned in Task 1 Step 2.

---

## File Structure

| File | Responsibility | Commit |
|---|---|---|
| `hack/openbsd_sync_upstream.sh` (new) | `preflight`, `start`, `restack`, `check-patches` | 5 |
| `hack/openbsd_check_go.sh` (new) | Fail early when builder Go is older than `go.mod` | 5 |
| `hack/openbsd_smoke_test.sh` (new) | Install package, mount via rc.d, I/O check, cleanup | 5 |
| `hack/openbsd_patch_deps.sh` (modify) | Exact module lookup, per-step checks | 3 |
| `deploy/openbsd/build_pkg.sh` (modify) | Write the `.tgz` into the project directory | 4 |
| `.gitlab-ci.yml` (modify) | Go check, artifact path, `smoke` stage, workflow rules | 5 |
| `cmd/passfd_openbsd.go` (new, after rebase) | `MSG_CMSG_CLOEXEC` for OpenBSD | 2 |
| `CLAUDE.md` (delete ours) | Upstream's own file takes its place after the rebase | 5 |
| `.claude/rules/openbsd.md` (new) | Fork-only agent notes | 5 |
| `docs/openbsd/upstream-sync.md` (new) | The routine, conflict guide, rollback, sync log | 5 |
| `docs/superpowers/**`, `tasks/**` (existing) | Spec, plan, lessons, todo | 5 |

---

### Task 1: Sync helper script

**Files:**
- Create: `hack/openbsd_sync_upstream.sh` (mode 755)

**Interfaces:**
- Produces:
  - `sh hack/openbsd_sync_upstream.sh preflight <target>` — prints differences in Go version and patched module versions between `HEAD` and `<target>`.
  - `sh hack/openbsd_sync_upstream.sh start <target>` — requires `HEAD` to be exactly the five stack commits on some base; fetches upstream, creates `${JIRA_KEY:-NO_ISSUE}-sync-<target>` from `HEAD`, runs `git rebase --onto <target> <base>`. Sets `rerere.enabled=true` in the repository config.
  - `sh hack/openbsd_sync_upstream.sh restack [base]` — rewrites `<base>..HEAD` into the five commits; tree unchanged. Without `[base]` it uses the parent of the newest commit titled with subject 1. Rolls back on any failure.
  - `sh hack/openbsd_sync_upstream.sh check-patches` — downloads the three patched modules into a scratch `GOMODCACHE` and runs `hack/openbsd_patch_deps.sh` twice. Requires a clean tree.
  - Env `SYNC_NO_FETCH=1` skips the network fetch.

- [ ] **Step 1: Write the script**

Create `hack/openbsd_sync_upstream.sh` with exactly this content, then `chmod 755` it:

```sh
#!/bin/sh
#
# JuiceFS, Copyright 2026 Juicedata, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Helper for syncing the OpenBSD fork with an upstream release tag.
# See docs/openbsd/upstream-sync.md for the whole routine.
#
# Usage:
#   sh hack/openbsd_sync_upstream.sh preflight <target>
#   sh hack/openbsd_sync_upstream.sh start <target>
#   sh hack/openbsd_sync_upstream.sh restack [base]
#   sh hack/openbsd_sync_upstream.sh check-patches
#
# Environment:
#   UPSTREAM_URL   upstream repository (default: juicedata/juicefs over HTTPS)
#   JIRA_KEY       prefix of the work branch created by "start"
#   SYNC_NO_FETCH  set to 1 to skip fetching upstream
set -eu

UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/juicedata/juicefs.git}

# The port is always exactly these five commits, in this order. A file belongs
# to a commit by its path (see restack).
S1="OpenBSD: platform source files and build tags"
S2="OpenBSD: cgofuse FUSE bridge and mountMain split"
S3="OpenBSD: dependency patching script"
S4="OpenBSD: package, rc.d and newsyslog files"
S5="OpenBSD: CI pipeline, sync tooling and notes"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  sed -n 's/^#   sh /  sh /p' "$0" >&2
  exit 2
}

require_clean() {
  [ -z "$(git status --porcelain)" ] ||
    die "working tree is not clean (commit or remove all changes, including untracked files)"
}

resolve() {
  git rev-parse -q --verify "$1^{commit}" 2>/dev/null ||
    die "'$1' is not a known tag or commit (fetch upstream first?)"
}

fetch_upstream() {
  if [ "${SYNC_NO_FETCH:-0}" = 1 ]; then
    return 0
  fi
  git fetch --tags "$UPSTREAM_URL" '+refs/heads/main:refs/remotes/upstream/main'
}

# Newest commit in <range> whose subject is exactly <subject>, or nothing.
find_subject() {
  git log --format='%H%x09%s' "$1" | awk -F '\t' -v s="$2" '$2 == s { print $1; exit }'
}

# The commit our stack sits on: the parent of the newest "$S1" commit.
stack_base() {
  _first=$(find_subject "-n 500 HEAD" "$S1")
  [ -n "$_first" ] ||
    die "no '$S1' commit found in the last 500 commits; pass the base explicitly to 'restack'"
  git rev-parse "$_first^"
}

# Refuse a base that would make us rewrite upstream commits: nothing in
# <base>..HEAD may be part of upstream main or of an upstream release tag.
require_own_commits() {
  git merge-base --is-ancestor "$1" HEAD || die "base '$1' is not an ancestor of HEAD"
  _all=$(git rev-list --count "$1..HEAD")
  _own=$(git rev-list --count "$1..HEAD" --not --tags='v*' --remotes=upstream)
  [ "$_all" -gt 0 ] || die "nothing between '$1' and HEAD"
  [ "$_all" = "$_own" ] ||
    die "$((_all - _own)) of the $_all commits between '$1' and HEAD are part of upstream main or of a v* tag; the base is wrong (never tag the fork itself with a v* name)"
}

# Succeeds if <base>..HEAD is exactly the five stack commits in order.
is_canonical() {
  _want=$(printf '%s\n' "$S1" "$S2" "$S3" "$S4" "$S5")
  [ "$(git log --reverse --format=%s "$1..HEAD")" = "$_want" ]
}

# Print the Go version and the versions of the modules patched by
# hack/openbsd_patch_deps.sh, as "<name> <version>" lines, for one revision.
modinfo() {
  git show "$1:go.mod" | awk '
    $1 == "go" { print "go " $2 }
    /=>/ && /go-fuse/ { print "go-fuse-replace " $NF; next }
    $1 == "github.com/hanwen/go-fuse/v2" { print "go-fuse " $2 }
    $1 == "github.com/juicedata/godaemon" { print "godaemon " $2 }
    $1 == "github.com/winfsp/cgofuse" { print "cgofuse " $2 }'
}

preflight() {
  target=$1
  resolve "$target" >/dev/null
  old=$(modinfo HEAD)
  new=$(modinfo "$target")
  echo "== Preflight: HEAD -> $target"
  echo "upstream commits to take in: $(git rev-list --count "HEAD..$target")"
  if [ "$old" = "$new" ]; then
    echo "Go version and patched modules are unchanged"
    return 0
  fi
  echo "$new" | while read -r name ver; do
    was=$(echo "$old" | awk -v n="$name" '$1 == n { print $2 }')
    if [ "$was" != "$ver" ]; then
      echo "CHANGED $name: ${was:-<none>} -> $ver"
    fi
  done
  echo "If 'go' changed: the builder needs at least that Go version."
  echo "If a module changed: run '$0 check-patches' after the rebase."
}

start() {
  target=$1
  require_clean
  fetch_upstream
  resolve "$target" >/dev/null
  base=$(stack_base)
  require_own_commits "$base"
  is_canonical "$base" ||
    die "the commits above $(git describe --tags --always "$base") are not the five stack commits; run '$0 restack' first"
  preflight "$target"
  branch="${JIRA_KEY:-NO_ISSUE}-sync-$(echo "$target" | tr '/' '-')"
  # Remember conflict resolutions; this setting stays in the repository config.
  git config rerere.enabled true
  git switch -c "$branch"
  echo "== Rebasing the stack from $(git describe --tags --always "$base") onto $target on branch $branch"
  if ! git rebase --onto "$target" "$base"; then
    cat >&2 <<EOF

The rebase stopped on a conflict. The conflict guide is not in the working
tree while the rebase is stopped; read it with:
  git show ORIG_HEAD:docs/openbsd/upstream-sync.md
Resolve, then: git add <files> && GIT_EDITOR=true git rebase --continue
To give up:    git rebase --abort && git switch - && git branch -D $branch
EOF
    exit 1
  fi
  cat <<EOF

Rebase finished. Continue with step 4 of "Routine" in
docs/openbsd/upstream-sync.md (local checks, restack, push, pipeline,
sync log, moving main).
EOF
}

# Commit what is staged under <subject>. Reuses message, author and date of the
# previous commit with that subject; a first-time commit lists the subjects of
# the commits it replaces. Co-Authored-By trailers of folded commits are kept.
commit_staged() {
  _subject=$1
  shift
  if git diff --cached --quiet; then
    return 0
  fi
  _old=$(find_subject "$RESTACK_BASE..$RESTACK_TIP" "$_subject")
  if [ -n "$_old" ]; then
    _msg=$(git log -1 --format=%B "$_old")
  else
    _msg=$(printf '%s\n\nSquashed from:\n%s\n' "$_subject" \
      "$(git log --no-merges --reverse --format='- %s' "$RESTACK_BASE..$RESTACK_TIP" -- "$@")")
  fi
  _trailers=$(git log --format='%(trailers:key=Co-Authored-By,only,unfold)' \
    "$RESTACK_BASE..$RESTACK_TIP" -- "$@" | sed '/^$/d' | sort -u)
  while IFS= read -r _trailer; do
    if [ -n "$_trailer" ]; then
      _msg=$(printf '%s\n' "$_msg" |
        git interpret-trailers --if-exists addIfDifferent --trailer "$_trailer")
    fi
  done <<TRAILERS
$_trailers
TRAILERS
  # --no-verify: this only regroups content that is already committed.
  if [ -n "$_old" ]; then
    git commit -q --no-verify -C "$_old"
    git commit -q --no-verify --amend -m "$_msg"
  else
    git commit -q --no-verify -m "$_msg"
  fi
}

# Stage each path that has changes. A path with nothing to add is skipped,
# because git add fails on a pathspec that matches no file.
stage() {
  for _path in "$@"; do
    if [ -n "$(git status --porcelain -- "$_path")" ]; then
      git add -A -- "$_path"
    fi
  done
}

restack() {
  require_clean
  if [ $# -ge 1 ]; then
    RESTACK_BASE=$(resolve "$1")
  else
    RESTACK_BASE=$(stack_base)
  fi
  require_own_commits "$RESTACK_BASE"
  RESTACK_TIP=$(git rev-parse HEAD)
  cd "$(git rev-parse --show-toplevel)"
  # From here on any failure puts the branch back exactly as it was.
  trap 'git reset -q --hard "$RESTACK_TIP"; echo "restack failed; restored $RESTACK_TIP" >&2' EXIT
  git reset -q --mixed "$RESTACK_BASE"

  git add -A -- pkg ':(exclude)pkg/cgofuse'
  commit_staged "$S1" pkg ':(exclude)pkg/cgofuse'
  stage cmd pkg/cgofuse
  commit_staged "$S2" cmd pkg/cgofuse
  stage hack/openbsd_patch_deps.sh
  commit_staged "$S3" hack/openbsd_patch_deps.sh
  stage deploy/openbsd
  commit_staged "$S4" deploy/openbsd
  set -- .gitlab-ci.yml CLAUDE.md .claude docs/openbsd docs/superpowers tasks \
    hack/openbsd_sync_upstream.sh hack/openbsd_check_go.sh hack/openbsd_smoke_test.sh
  stage "$@"
  commit_staged "$S5" "$@"

  _left=$(git status --porcelain)
  [ -z "$_left" ] || die "these paths belong to no stack commit (add them to restack in $0):
$_left"
  git diff --quiet "$RESTACK_TIP" HEAD || die "restack changed the tree"
  is_canonical "$RESTACK_BASE" || die "restack did not produce the five stack commits"
  trap - EXIT
  echo "== Stack on $(git describe --tags --always "$RESTACK_BASE"):"
  git log --oneline "$RESTACK_BASE..HEAD"
}

check_patches() {
  require_clean
  cd "$(git rev-parse --show-toplevel)"
  scratch=$(mktemp -d)
  trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"; git checkout -q -- go.mod go.sum' EXIT
  export GOMODCACHE="$scratch" GOFLAGS=-mod=mod
  go mod download github.com/hanwen/go-fuse/v2 github.com/juicedata/godaemon github.com/winfsp/cgofuse
  replace=$(awk '/=>/ && /go-fuse/ { print $(NF-1) "@" $NF }' go.mod)
  if [ -n "$replace" ]; then
    go mod download "$replace"
  fi
  sh hack/openbsd_patch_deps.sh
  echo "== Second run (must be idempotent)"
  sh hack/openbsd_patch_deps.sh
  echo "== check-patches OK"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  preflight)
    [ $# -eq 1 ] || usage
    preflight "$1"
    ;;
  start)
    [ $# -eq 1 ] || usage
    start "$1"
    ;;
  restack)
    [ $# -le 1 ] || usage
    restack "$@"
    ;;
  check-patches)
    [ $# -eq 0 ] || usage
    check_patches
    ;;
  *) usage ;;
esac
```

- [ ] **Step 2: Test it locally**

Run from the repository root. The tests use a throwaway worktree of `main`; the script is called by absolute path because `main` does not contain it.

```bash
S="$PWD/hack/openbsd_sync_upstream.sh"
shellcheck -s sh "$S" && dash -n "$S" && echo lint-ok
sh "$S" preflight v1.4.1
sh "$S" preflight v9.9.9; echo "exit=$?"
```
Expected: `lint-ok`; preflight contains
```
upstream commits to take in: 293
CHANGED go: 1.23.0 -> 1.25.0
CHANGED go-fuse-replace: v2.1.1-0.20250807045235-112198daa7df -> v2.1.1-0.20260610024748-b44a81936922
```
(the commit count is relative to the current branch and may differ by the number of local commits); then `ERROR: 'v9.9.9' is not a known tag or commit (fetch upstream first?)`, `exit=1`.

Restack `main` itself (the spec's squash check):

```bash
WT="$(mktemp -d)/wt"
git worktree add -q -b tmp-restack "$WT" main
cd "$WT"
sh "$S" restack f13b3dfe; echo "exit=$?"
git diff --stat main | wc -l
git rev-list --count f13b3dfe..HEAD
git log -1 --format=%B HEAD~1 | head -4
```
Expected: five `OpenBSD: …` lines, `exit=0`, `0`, `5`, and commit 4's message starting
```
OpenBSD: package, rc.d and newsyslog files

Squashed from:
- OSS-3: Add OpenBSD package build infrastructure
```

Guards (Review Focus 4 and 5), still inside `$WT`:

```bash
sh "$S" restack "f13b3dfe~30"; echo "exit=$?"
sh "$S" restack v1.4.1; echo "exit=$?"
touch stray; sh "$S" restack; echo "exit=$?"; rm stray
echo x > Makefile.extra; git add Makefile.extra; git commit -qm stray
T=$(git rev-parse HEAD); sh "$S" restack; echo "exit=$? restored=$([ "$T" = "$(git rev-parse HEAD)" ] && echo yes) dirty=$(git status --porcelain | wc -l)"
SYNC_NO_FETCH=1 sh "$S" start v1.4.1; echo "exit=$? branch=$(git branch --show-current)"
git reset -q --hard HEAD~1
SYNC_NO_FETCH=1 sh "$S" start v9.9.9; echo "exit=$? branch=$(git branch --show-current)"
git tag v0.0.0-forktest HEAD; SYNC_NO_FETCH=1 sh "$S" start v1.4.1; echo "exit=$?"; git tag -d v0.0.0-forktest
```
Expected, in order:
- `ERROR: 30 of the 35 commits between '…' and HEAD are part of upstream main or of a v* tag; the base is wrong …`, `exit=1`
- `ERROR: base '…' is not an ancestor of HEAD`, `exit=1`
- `ERROR: working tree is not clean …`, `exit=1`
- `ERROR: these paths belong to no stack commit …` listing `Makefile.extra`, then `restack failed; restored …`, `exit=1 restored=yes dirty=0`
- `ERROR: the commits above … are not the five stack commits; run '… restack' first`, `exit=1 branch=tmp-restack`
- `ERROR: 'v9.9.9' is not a known tag or commit …`, `exit=1 branch=tmp-restack`
- `ERROR: 5 of the 5 commits … are part of upstream main or of a v* tag …`, `exit=1`

Fix-up folding and trailers:

```bash
echo '# t' >> deploy/openbsd/DESCR
git commit -qam "tweak" -m "Co-Authored-By: Test Person <t@example.invalid>"
sh "$S" restack >/dev/null; echo "exit=$? count=$(git rev-list --count f13b3dfe..HEAD)"
git log -1 --format='%(trailers)' HEAD~1 | grep -c 'Test Person'
git log -1 --format='%(trailers)' HEAD~3 | grep -c 'Test Person'
```
Expected: `exit=0 count=5`, then `1` (commit 4 has the trailer), then `0` (commit 2 does not).

Clean up and confirm the main checkout is untouched:

```bash
cd - >/dev/null
git worktree remove --force "$WT" && git branch -D tmp-restack
git config --get rerere.enabled; git status --short; git branch --list
```
Expected: no `rerere` value (none of the tests reached the point where `start` sets it), clean status, only `main` and `OSS-5-upstream-sync-routine`.

- [ ] **Step 3: Commit**

```bash
chmod 755 hack/openbsd_sync_upstream.sh
# tick Task 1 in tasks/todo.md
git add hack/openbsd_sync_upstream.sh tasks/todo.md
git commit -m "OSS-5: Add upstream sync helper script" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
**NOTIFY:** Task 1 done.

---

### Task 2: Go version check script

**Files:**
- Create: `hack/openbsd_check_go.sh` (mode 755)

**Interfaces:**
- Produces: `sh hack/openbsd_check_go.sh [required] [installed]` — exit 0 and print `Go <installed> satisfies go.mod (needs >= <required>)` if installed >= required, else exit 1 with a message. Without arguments it reads `go.mod` and the local toolchain.

- [ ] **Step 1: Write the failing test (run before the script exists)**

```bash
t() { sh hack/openbsd_check_go.sh "$1" "$2" >/dev/null 2>&1; echo "$1 $2 -> $?"; }
t 1.25.0 1.24.9; t 1.25.10 1.25.9; t 1.25.0 1.25.0; t 1.25 1.25.3; t 1.23.0 1.27.2; t 1.25.0 1.25rc1
```
Expected now: every line ends in a non-zero code (script missing).

- [ ] **Step 2: Write the script**

Create `hack/openbsd_check_go.sh`, then `chmod 755` it:

```sh
#!/bin/sh
#
# JuiceFS, Copyright 2026 Juicedata, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Fail early when the installed Go is older than go.mod requires. The OpenBSD
# build uses GOTOOLCHAIN=local, so Go cannot fetch a newer toolchain itself.
#
# Usage: sh hack/openbsd_check_go.sh [required] [installed]
set -eu

required=${1:-$(awk '$1 == "go" { print $2; exit }' go.mod)}
# Ask from / so a too-new go.mod cannot make the go command refuse to run.
installed=${2:-$(cd / && GOTOOLCHAIN=local go env GOVERSION | sed 's/^go//')}

if awk -v r="$required" -v i="$installed" 'BEGIN {
  split(r, a, "."); split(i, b, ".")
  for (k = 1; k <= 3; k++) {
    if (b[k] + 0 > a[k] + 0) exit 0
    if (b[k] + 0 < a[k] + 0) exit 1
  }
  exit 0
}'; then
  echo "Go $installed satisfies go.mod (needs >= $required)"
else
  echo "ERROR: go.mod needs Go >= $required but this host has Go $installed." >&2
  echo "Upgrade Go on the builder, then re-run the pipeline." >&2
  exit 1
fi
```

- [ ] **Step 3: Run the test again**

Run the `t …` line from Step 1.
Expected (verified by a reviewer run):
```
1.25.0 1.24.9 -> 1
1.25.10 1.25.9 -> 1
1.25.0 1.25.0 -> 0
1.25 1.25.3 -> 0
1.23.0 1.27.2 -> 0
1.25.0 1.25rc1 -> 0
```
Then `shellcheck -s sh hack/openbsd_check_go.sh && dash -n hack/openbsd_check_go.sh` (no output) and `sh hack/openbsd_check_go.sh` (prints `Go 1.27.2 satisfies go.mod (needs >= 1.23.0)` on the dev machine).

- [ ] **Step 4: Commit**

```bash
chmod 755 hack/openbsd_check_go.sh
# tick Task 2 in tasks/todo.md
git add hack/openbsd_check_go.sh tasks/todo.md
git commit -m "OSS-5: Add Go version check for the OpenBSD build" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
**NOTIFY:** Task 2 done.

---

### Task 3: Harden the dependency patch script

**Files:**
- Modify: `hack/openbsd_patch_deps.sh`

**Interfaces:**
- Consumes: `check-patches` from Task 1 (needs a clean tree, so edits are committed before it runs).
- Produces: `sh hack/openbsd_patch_deps.sh` exits non-zero and prints a line starting `ERROR: step '<name>': ` when a module is missing or a patch did not take effect; a second run on a patched cache succeeds. It no longer traces commands.

- [ ] **Step 1: Baseline**

```bash
sh hack/openbsd_sync_upstream.sh check-patches 2>&1 | grep -E '^(Patching go-fuse at|== check-patches OK|ERROR)'
```
Expected: two `Patching go-fuse at: …/github.com/juicedata/go-fuse/v2@v2.1.1-0.20250807045235-112198daa7df` lines and `== check-patches OK`. This passes today although nothing verifies the patches; Step 5's negative test is the one that fails before the change.

- [ ] **Step 2: Header, tracing and module lookup**

Insert the Apache header comment block (the same 14 comment lines as in `hack/openbsd_check_go.sh`, from `#` + `# JuiceFS, Copyright 2026 Juicedata, Inc.` through `# limitations under the License.` + `#`) directly after the `#!/bin/sh` line.

Change `set -ex` to `set -e`.

Replace everything from the line `# Locate the go-fuse module cache directory` down to and including the line `chmod -R u+w "$GOFUSE_DIR"` with:

```sh
fail() {
  echo "ERROR: step '$1': $2" >&2
  exit 1
}

# Directory of a module in the module cache, as selected by go.mod
# (follows replace directives). Never searches the cache by name: after a
# dependency bump it holds several versions and the first match may be stale.
moddir() {
  _dir=$(env GOFLAGS=-mod=mod go list -m -f '{{if .Replace}}{{.Replace.Dir}}{{else}}{{.Dir}}{{end}}' "$1")
  if [ -z "$_dir" ] || [ ! -d "$_dir" ]; then
    fail "locate $1" "module directory not found; run 'go mod download' first"
  fi
  echo "$_dir"
}

need_file() {
  [ -f "$2" ] || fail "$1" "expected file $2 is missing"
}

need_text() {
  need_file "$1" "$3"
  grep -q -- "$2" "$3" || fail "$1" "'$2' not found in $3"
}

need_no_text() {
  need_file "$1" "$3"
  if grep -q -- "$2" "$3"; then
    fail "$1" "'$2' is still present in $3"
  fi
}

GOFUSE_DIR=$(moddir github.com/hanwen/go-fuse/v2)
echo "Patching go-fuse at: $GOFUSE_DIR"
chmod -R u+w "$GOFUSE_DIR"
```

- [ ] **Step 3: Checks for each patch step**

a) In the here-document for `fuse/syscall_openbsd.go`, directly after the closing `)` of its `import (` block and before `func sys_writev`, insert (from old-branch commit `7ef42c60`):

```go

// OpenBSD's syscall package doesn't export MSG_CMSG_CLOEXEC. go-fuse's
// passfd.go references it unqualified (defined per-platform in
// syscall_{linux,darwin}.go). Mirror the Darwin build (= 0): pass no special
// recvmsg flag.
const MSG_CMSG_CLOEXEC = 0
```

b) Replace the `fuse/types.go` and `fuse/print.go` blocks with:

```sh
# --- fuse/types.go: patch ENODATA (doesn't exist on OpenBSD) ---
need_file "go-fuse ENODATA" "${GOFUSE_DIR}/fuse/types.go"
if grep -q 'syscall.ENODATA' "${GOFUSE_DIR}/fuse/types.go"; then
  sed -i.bak 's|ENODATA = Status(syscall.ENODATA)|ENODATA = Status(0x60)|' "${GOFUSE_DIR}/fuse/types.go"
fi
need_no_text "go-fuse ENODATA" 'syscall.ENODATA' "${GOFUSE_DIR}/fuse/types.go"

# --- fuse/print.go: remove LARGEFILE entry that conflicts with O_NOCTTY on OpenBSD ---
need_file "go-fuse LARGEFILE" "${GOFUSE_DIR}/fuse/print.go"
if grep -q '0x8000.*LARGEFILE' "${GOFUSE_DIR}/fuse/print.go"; then
  sed -i.bak '/0x8000.*LARGEFILE/d' "${GOFUSE_DIR}/fuse/print.go"
fi
need_no_text "go-fuse LARGEFILE" '0x8000.*LARGEFILE' "${GOFUSE_DIR}/fuse/print.go"
```

c) In the "Copy Darwin platform files" loop, replace the body

```sh
  if [ -f "$src" ] && [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "Copied $f -> $(basename "$dst")"
  fi
```
with
```sh
  if [ ! -f "$src" ]; then
    echo "Note: $f is not part of this go-fuse revision, nothing to copy"
    continue
  fi
  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    echo "Copied $f -> $(basename "$dst")"
  fi
  need_file "go-fuse darwin copies" "$dst"
```

d) Replace the whole godaemon section (from `GODAEMON_DIR=` through its closing `fi`) with:

```sh
GODAEMON_DIR=$(moddir github.com/juicedata/godaemon)
need_file "godaemon build tags" "$GODAEMON_DIR/daemon.go"
chmod -R u+w "$GODAEMON_DIR"
if ! grep -q 'openbsd' "$GODAEMON_DIR/daemon.go"; then
  sed -i.bak 's|^// +build darwin freebsd linux|// +build darwin freebsd linux openbsd|' "$GODAEMON_DIR/daemon.go"
  echo "Patched godaemon build tags"
fi
need_text "godaemon build tags" 'openbsd' "$GODAEMON_DIR/daemon.go"
```

e) Replace the whole cgofuse section (from `CGOFUSE_DIR=` through its closing `fi`) with:

```sh
CGOFUSE_DIR=$(moddir github.com/winfsp/cgofuse)
need_file "cgofuse libfuse name" "$CGOFUSE_DIR/fuse/host_cgo.go"
# libfuse only exists on OpenBSD; on other hosts (local check-patches) skip.
if [ "$(uname -s)" = OpenBSD ]; then
  chmod -R u+w "$CGOFUSE_DIR"
  # shellcheck disable=SC2012
  LIBFUSE_SO=$(ls /usr/lib/libfuse.so.* 2>/dev/null | head -1)
  [ -n "$LIBFUSE_SO" ] || fail "cgofuse libfuse name" "no /usr/lib/libfuse.so.* on this system"
  LIBFUSE_NAME=$(basename "$LIBFUSE_SO")
  sed -i.bak "s|dlopen(\"libfuse\\.so\\.[0-9.]*\"|dlopen(\"$LIBFUSE_NAME\"|" "$CGOFUSE_DIR/fuse/host_cgo.go"
  need_text "cgofuse libfuse name" "dlopen(\"$LIBFUSE_NAME\"" "$CGOFUSE_DIR/fuse/host_cgo.go"
  echo "cgofuse uses $LIBFUSE_NAME"
fi
```

- [ ] **Step 4: Commit (required before testing: `check-patches` refuses a dirty tree)**

```bash
shellcheck -s sh hack/openbsd_patch_deps.sh && dash -n hack/openbsd_patch_deps.sh && echo lint-ok
# tick Task 3 in tasks/todo.md
git add hack/openbsd_patch_deps.sh tasks/todo.md
git commit -m "OSS-5: Harden OpenBSD dependency patching" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
Expected: `lint-ok`.

- [ ] **Step 5: Test**

```bash
sh hack/openbsd_sync_upstream.sh check-patches 2>&1 | grep -E '^(Patching go-fuse at|Note:|== check-patches OK|ERROR)'
git status --short
```
Expected: two `Patching go-fuse at: …112198daa7df` lines, possibly some `Note:` lines, `== check-patches OK`; clean status.

Stale-version test (Review Focus 3) and negative test, in a scratch cache:

```bash
SC=$(mktemp -d); export GOMODCACHE="$SC" GOFLAGS=-mod=mod
go mod download github.com/hanwen/go-fuse/v2 github.com/juicedata/godaemon github.com/winfsp/cgofuse
go mod download github.com/juicedata/go-fuse/v2@v2.1.1-0.20250807045235-112198daa7df
go mod download github.com/juicedata/go-fuse/v2@v2.1.1-0.20260610024748-b44a81936922
sh hack/openbsd_patch_deps.sh 2>&1 | grep '^Patching go-fuse at'
D=$(go list -m -f '{{.Dir}}' github.com/juicedata/godaemon)
sed -i 's|^// +build darwin freebsd linux.*|// +build plan9|' "$D/daemon.go"
sh hack/openbsd_patch_deps.sh >"$SC/out.log" 2>&1; echo "exit=$?"; grep '^ERROR' "$SC/out.log"
unset GOMODCACHE GOFLAGS; chmod -R u+w "$SC"; rm -rf "$SC"; git checkout -q -- go.mod go.sum; git status --short
```
Expected: one `Patching go-fuse at` line naming `…112198daa7df` (the version `go.mod` selects, although the newer one is also in the cache); `exit=1`; `ERROR: step 'godaemon build tags': 'openbsd' not found in …/daemon.go`; clean status.

If a test fails, fix the script and `git commit --amend --no-edit -a` before re-running.

**NOTIFY:** Task 3 done.

---

### Task 4: Package artifact fix, smoke test, pipeline

**Files:**
- Modify: `deploy/openbsd/build_pkg.sh`
- Create: `hack/openbsd_smoke_test.sh` (mode 755)
- Modify: `.gitlab-ci.yml`

**Interfaces:**
- Consumes: `hack/openbsd_check_go.sh` (Task 2).
- Produces: the `package` job leaves exactly one `juicefs-<version>.tgz` in `$CI_PROJECT_DIR`; `doas /bin/sh $CI_PROJECT_DIR/hack/openbsd_smoke_test.sh` (no arguments) prints `smoke: PASS` and exits 0 on success, prints `smoke: FAIL: <reason>` and exits non-zero otherwise.

- [ ] **Step 1: Fix the package output directory**

In `deploy/openbsd/build_pkg.sh` insert the Apache header comment block (same 14 comment lines as in `hack/openbsd_check_go.sh`) directly after `#!/bin/sh`, and replace the line

```sh
OUTPUT_DIR="/build/gitlab-runner/builds/openbsd7.8/amd64/juicefs"
```
with
```sh
# Output into the working directory by default so GitLab CI can pick the
# package up as an artifact (artifacts:paths must be inside CI_PROJECT_DIR).
# Override with OUTPUT_DIR=... when running the script by hand.
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
# The smoke test expects exactly one package here.
rm -f "${OUTPUT_DIR}"/juicefs-*.tgz
```

- [ ] **Step 2: Write the failing test for the smoke script (Review Focus 1)**

```bash
sh hack/openbsd_smoke_test.sh; echo "exit=$?"
```
Expected now: `No such file`, non-zero.

- [ ] **Step 3: Write the smoke script**

Create `hack/openbsd_smoke_test.sh`, then `chmod 755` it:

```sh
#!/bin/sh
#
# JuiceFS, Copyright 2026 Juicedata, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Smoke test for the OpenBSD package: install it, mount a throwaway volume
# through rc.d, write and read back data, unmount, uninstall.
#
# Runs as root on a dedicated OpenBSD build host:
#   doas /bin/sh <project-dir>/hack/openbsd_smoke_test.sh
# It takes no arguments (the doas rule matches arguments exactly) and uses the
# single juicefs-*.tgz found in the project directory.
set -eu

ENV_FILE=/etc/juicefs/smoke.env
LOG_FILE=/var/log/juicefs-smoke.log
JFS=/usr/local/bin/juicefs
TMP_PREFIX=/tmp/juicefs-smoke
# The lock directory doubles as the record of what a run has done so far:
#   pid        the running script
#   installed  the package was (about to be) installed by a smoke run
#   uuid       volume UUID, to find the cache directory
LOCK=/var/run/juicefs-smoke.lock

say() {
  echo "smoke: $*"
}

die() {
  echo "smoke: FAIL: $*" >&2
  exit 1
}

# True if <dir> is a mount point. A directory that cannot be read (a dead FUSE
# mount) counts as mounted, so cleanup still tries to unmount it.
is_mounted() {
  _dev=$(stat -f %d "$1" 2>/dev/null) || return 0
  [ "$_dev" != "$(stat -f %d "$1/..")" ]
}

not_mounted() {
  ! is_mounted "$1"
}

has_objects() {
  [ -n "$(find "$1" -type f 2>/dev/null | head -1)" ]
}

# wait_for <seconds> <command...>: poll once per second until it succeeds.
wait_for() {
  _left=$1
  shift
  while [ "$_left" -gt 0 ]; do
    if "$@"; then
      return 0
    fi
    sleep 1
    _left=$((_left - 1))
  done
  return 1
}

# Remove everything a smoke run can leave behind, whatever state it is in.
# Never fails; the lock directory goes last because it records what to remove.
remove_smoke_state() {
  set +e
  pkill -f "juicefs mount.*${TMP_PREFIX}" 2>/dev/null
  for _mnt in "${TMP_PREFIX}".*/mnt; do
    if [ -d "$_mnt" ] && is_mounted "$_mnt"; then
      umount -f "$_mnt"
    fi
  done
  if [ -f "$LOCK/installed" ]; then
    pkg_delete juicefs
  fi
  if [ -s "$LOCK/uuid" ]; then
    rm -rf "/var/jfsCache/$(cat "$LOCK/uuid")"
  fi
  rm -f "$ENV_FILE" "$LOG_FILE"
  rm -rf "${TMP_PREFIX}".*
  rm -rf "$LOCK"
  set -e
}

cleanup() {
  _rc=$?
  trap - EXIT INT TERM
  set +e
  if [ "$_rc" -ne 0 ] && [ -f "$LOG_FILE" ]; then
    say "last lines of $LOG_FILE:"
    tail -50 "$LOG_FILE"
  fi
  remove_smoke_state
  exit "$_rc"
}

[ "$(uname -s)" = OpenBSD ] || die "this script only runs on OpenBSD"
[ "$(id -u)" -eq 0 ] || die "must run as root (via doas)"
[ $# -eq 0 ] || die "this script takes no arguments"

cd "$(dirname "$0")/.."
set -- juicefs-*.tgz
if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  die "expected exactly one juicefs-*.tgz in $(pwd), found: $*"
fi
PKG="$(pwd)/$1"

# One run at a time. A lock whose owner is gone is a killed earlier run:
# clean up after it and carry on.
if ! mkdir "$LOCK" 2>/dev/null; then
  _owner=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
    die "another smoke run is active (pid $_owner)"
  fi
  say "removing leftovers of an earlier smoke run"
  remove_smoke_state
  mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap cleanup EXIT
trap 'exit 130' INT TERM

# Never touch a host that really uses JuiceFS.
if pgrep -f "juicefs mount" >/dev/null 2>&1; then
  die "a juicefs mount process is running on this host"
fi
for _env in /etc/juicefs/*.env; do
  if [ -e "$_env" ]; then
    die "$_env exists; this host has configured JuiceFS mounts"
  fi
done
if pkg_info -e 'juicefs-*' >/dev/null 2>&1; then
  die "a juicefs package is already installed on this host"
fi

TMP=$(mktemp -d "${TMP_PREFIX}.XXXXXX")
MNT="$TMP/mnt"
mkdir "$MNT" "$TMP/data"
META="sqlite3://$TMP/meta.db"

say "installing $PKG"
touch "$LOCK/installed"
pkg_add -D unsigned "$PKG"
"$JFS" version

say "formatting a throwaway volume"
"$JFS" format --storage file --bucket "$TMP/data/" "$META" smoke
"$JFS" status "$META" 2>/dev/null |
  sed -n 's/.*"UUID": *"\([^"]*\)".*/\1/p' | head -1 > "$LOCK/uuid"

say "mounting through rc.d"
cat > "$ENV_FILE" <<EOF
JUICEFS_META_URL=$META
JUICEFS_MOUNT_POINT=$MNT
JUICEFS_LOG_FILE=$LOG_FILE
EOF
rcctl -f start juicefs
wait_for 30 is_mounted "$MNT" || die "$MNT is not a mount point after 30s"

say "writing and reading back 8 MiB"
dd if=/dev/urandom of="$TMP/src.bin" bs=1048576 count=8 2>/dev/null
cp "$TMP/src.bin" "$MNT/data.bin"
[ "$(sha256 -q "$TMP/src.bin")" = "$(sha256 -q "$MNT/data.bin")" ] || die "checksum mismatch after read-back"
# Proves the mount is JuiceFS: the data must arrive in the volume's storage.
wait_for 30 has_objects "$TMP/data" || die "no objects in $TMP/data; $MNT is not backed by the test volume"

say "directory operations"
mkdir "$MNT/dir"
[ -d "$MNT/dir" ] || die "created directory is not visible"
# shellcheck disable=SC2010
ls "$MNT" | grep -qx dir || die "created directory is not listed"
rmdir "$MNT/dir"
[ ! -e "$MNT/dir" ] || die "removed directory still exists"

say "unmounting through rc.d"
rcctl -f stop juicefs || die "rcctl stop juicefs failed"
wait_for 30 not_mounted "$MNT" || die "$MNT is still mounted (or a dead mount) 30s after stop"

[ -f "$LOG_FILE" ] || die "$LOG_FILE was not written"
if grep -q 'panic' "$LOG_FILE"; then
  die "panic found in $LOG_FILE"
fi

say "PASS"
```

- [ ] **Step 4: Run the smoke script test**

```bash
shellcheck -s sh hack/openbsd_smoke_test.sh deploy/openbsd/build_pkg.sh
dash -n hack/openbsd_smoke_test.sh && dash -n deploy/openbsd/build_pkg.sh && echo syntax-ok
sh hack/openbsd_smoke_test.sh; echo "exit=$?"
```
Expected: no shellcheck findings; `syntax-ok`; `smoke: FAIL: this script only runs on OpenBSD`, `exit=1`. The full run is verified on the builder in Task 6.

- [ ] **Step 5: Update the pipeline**

Replace `.gitlab-ci.yml` with:

```yaml
stages:
  - wake-up
  - build
  - package
  - smoke

variables:
  BINARY_NAME: juicefs

# Branch pipelines only: pushing a tag (e.g. pre-sync/*) must not start one.
workflow:
  rules:
    - if: $CI_COMMIT_TAG
      when: never
    - when: always

# --- Stage 1: Wake the OpenBSD builder VM ---
etherwake:
  tags:
    - etherwake
  stage: wake-up
  script:
    - echo "Waking up OpenBSD build VM"
    - ~/wake_up_build_openbsd.sh

# --- Stage 2: Build JuiceFS for OpenBSD ---
build:
  stage: build
  tags:
    - openbsd
    - openbsd7.8
  script:
    # The doas rule for the smoke stage is written from these two values
    - echo "runner user $(id -un), CI_PROJECT_DIR=${CI_PROJECT_DIR}"
    # Stop early if the builder's Go is older than go.mod requires
    - sh hack/openbsd_check_go.sh
    - go version
    # Download dependencies and patch go-fuse/godaemon for OpenBSD
    - env GOTOOLCHAIN=local GONOSUMCHECK='*' GOFLAGS='-mod=mod' go mod download
    - sh hack/openbsd_patch_deps.sh
    # Build with OpenBSD-compatible flags (CGO required for cgofuse/libfuse)
    - env CGO_ENABLED=1 GOTOOLCHAIN=local GONOSUMCHECK='*' GOFLAGS='-mod=mod -buildvcs=false' go build -ldflags="-s -w" -o ${BINARY_NAME} .
    - ./${BINARY_NAME} version
  artifacts:
    paths:
      - ${BINARY_NAME}
    expire_in: 1 hour

# --- Stage 3: Create OpenBSD package ---
package:
  stage: package
  tags:
    - openbsd
    - openbsd7.8
  dependencies:
    - build
  script:
    - sh deploy/openbsd/build_pkg.sh
  artifacts:
    paths:
      - juicefs-*.tgz
    expire_in: 1 week

# --- Stage 4: Install the package and mount a throwaway volume ---
# Needs a doas rule on the builder; see docs/openbsd/upstream-sync.md.
smoke:
  stage: smoke
  tags:
    - openbsd
    - openbsd7.8
  # The test installs a package system-wide: never run two at once.
  resource_group: openbsd-builder
  dependencies:
    - package
  script:
    # Without root the script must refuse and change nothing
    - if sh hack/openbsd_smoke_test.sh; then echo "smoke test must refuse to run without root"; exit 1; fi
    - doas /bin/sh "${CI_PROJECT_DIR}/hack/openbsd_smoke_test.sh"
```

Validate: `glab ci lint` (or the `mcp__GitLab__glab_ci_lint` tool). Expected: valid.

- [ ] **Step 6: Commit**

```bash
chmod 755 hack/openbsd_smoke_test.sh
# tick Task 4 in tasks/todo.md
git add deploy/openbsd/build_pkg.sh hack/openbsd_smoke_test.sh .gitlab-ci.yml tasks/todo.md
git commit -m "OSS-5: Add OpenBSD smoke test stage and fix package artifact path" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
**NOTIFY:** Task 4 done.

---

### Task 5: Documentation, agent notes, spec corrections

**Files:**
- Delete: `CLAUDE.md` (ours)
- Create: `.claude/rules/openbsd.md`
- Create: `docs/openbsd/upstream-sync.md`
- Modify: `docs/superpowers/specs/2026-10-09-upstream-sync-design.md`

- [ ] **Step 1: Replace our CLAUDE.md with fork-only notes**

Our `CLAUDE.md` contains no OpenBSD content (`grep -ci openbsd CLAUDE.md` prints `0`) and upstream's `AGENTS.md` covers the same ground from `v1.4.1` on.

```bash
git rm -q CLAUDE.md
mkdir -p .claude/rules
```

Create `.claude/rules/openbsd.md`:

```markdown
# OpenBSD fork

This repository is a fork of JuiceFS that adds OpenBSD support. General
project rules come from upstream's `CLAUDE.md` / `AGENTS.md`; this file only
adds what is specific to the fork.

- `main` is one upstream release tag plus five `OpenBSD: …` commits. Do not add
  other commits to `main`. Make fixes as normal commits on a work branch, then
  run `sh hack/openbsd_sync_upstream.sh restack`. The routine is in
  `docs/openbsd/upstream-sync.md`.
- Never tag the fork with a `v*` name; those mean "upstream release".
- OpenBSD cannot be cross-compiled locally (cgo-only dependencies). Only the
  GitLab pipeline (`build → package → smoke`) proves an OpenBSD change.
- Build on OpenBSD: `go mod download`, `sh hack/openbsd_patch_deps.sh`, then
  `CGO_ENABLED=1 GOTOOLCHAIN=local go build`; see `.gitlab-ci.yml`.
- FUSE on OpenBSD goes through `pkg/cgofuse` (system libfuse), not go-fuse.
- Pitfalls already paid for are in `tasks/lessons.md`. Read it before touching
  `deploy/openbsd/`, `hack/openbsd_*.sh` or any `*_openbsd.go` file.
- Jira project: OSS. Branches are named `OSS-N-short-description`.
```

(On the old base there is no `CLAUDE.md` from here until the rebase brings upstream's.)

- [ ] **Step 2: Write the routine document**

Create `docs/openbsd/upstream-sync.md`:

````markdown
# Syncing the OpenBSD fork with upstream

`main` is always **one upstream release tag plus five commits**:

| # | Commit subject | Paths |
|---|---|---|
| 1 | OpenBSD: platform source files and build tags | `pkg/**` except `pkg/cgofuse/**` |
| 2 | OpenBSD: cgofuse FUSE bridge and mountMain split | `cmd/**`, `pkg/cgofuse/**` |
| 3 | OpenBSD: dependency patching script | `hack/openbsd_patch_deps.sh` |
| 4 | OpenBSD: package, rc.d and newsyslog files | `deploy/openbsd/**` |
| 5 | OpenBSD: CI pipeline, sync tooling and notes | `.gitlab-ci.yml`, `.claude/**`, `docs/openbsd/**`, `docs/superpowers/**`, `tasks/**`, the other `hack/openbsd_*.sh` |

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
  permit nopass gitlab-runner as root cmd /bin/sh args BUILDER_PROJECT_DIR/hack/openbsd_smoke_test.sh
  ```

  The rule matches the path exactly. If the runner is re-registered or its
  concurrency changes, `CI_PROJECT_DIR` changes and the rule must be updated;
  the `build` job prints the current value.

  Trust note: the smoke script and the package come from the repository, so
  whoever can push a branch that runs the pipeline has root on the builder.
  Keep the builder a dedicated VM and push access limited to the owner. If
  that stops being true, make the `smoke` job manual.

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
````

- [ ] **Step 3: Correct the spec**

In `docs/superpowers/specs/2026-10-09-upstream-sync-design.md`:

- Line 4: `Status: approved; revised after plan review (see "Revisions" at the end)`.
- "Squash the commit stack": replace the commit list item 5 with `5. GitLab pipeline, sync tooling, agent notes, docs and tasks/` and replace the paragraph starting "The squash is done" with: `The stack is built by regrouping the tree by path (restack). It is accepted only if the tree is unchanged by the regrouping.`
- "Move our CLAUDE.md content": replace the body with: `Our CLAUDE.md has no OpenBSD content and duplicates upstream's AGENTS.md. It is deleted. Fork-only notes live in .claude/rules/openbsd.md. Upstream's CLAUDE.md is not edited.`
- "Reuse fixes": change `→ commit 1, if still needed at v1.4.1` to `→ commit 3 (it only touches the patch script)`; change `if still needed` on the `18d1d497` line to `(needed: v1.4.1 has cmd/passfd.go)`; change the last sentence to `The branch is deleted on both remotes once OSS-5 is done.`
- "The sync routine": step 3, replace `from main` with `from the current stack`; step 6, replace the text with `Fix failures as ordinary commits and fold them into the owning commit with restack.`; swap steps 7 and 8 so the sync log entry comes before moving `main`.
- Replace the paragraph starting "`hack/openbsd_sync_upstream.sh <tag>` performs" with: `hack/openbsd_sync_upstream.sh has four subcommands: preflight, start, restack and check-patches. The previous base is the parent of the newest commit titled "OpenBSD: platform source files and build tags"; every commit above it must be absent from upstream main and from all v* tags. git describe and merge-base are not used: the first returns v1.4.0-dev today, the second replays upstream backports once main sits on a release tag.`
- "Builder prerequisite": replace `taken from the first pipeline run on the work branch` with `taken from the first pipeline run on the tooling branch`.
- "Deliverables": add rows for `hack/openbsd_check_go.sh` (Go version check), `.claude/rules/openbsd.md` (fork-only agent notes); remove the `docs/openbsd/CLAUDE-openbsd.md` row.
- "Acceptance" item 1: replace the second sentence with `git diff --name-status v1.4.1 main lists only added files plus three modified ones: cmd/mount_unix.go, pkg/chunk/utils_unix.go, pkg/vfs/vfs.go.`
- Append a section:

  ```markdown
  ## Revisions

  - 2026-10-09: corrected after five reviews of the implementation plan. See
    "Deviations from the spec" in
    `docs/superpowers/plans/2026-10-09-upstream-sync.md` for the reasons.
  ```

- [ ] **Step 4: Commit**

```bash
grep -rnE '/home/[a-z]|claude\.ai/code/session_' docs/superpowers docs/openbsd .claude tasks; echo "grep-exit=$?"
# tick Task 5 in tasks/todo.md
git add -A CLAUDE.md .claude docs/openbsd docs/superpowers tasks/todo.md
git commit -m "OSS-5: Document the upstream sync routine, replace CLAUDE.md with fork notes" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
Expected: `grep-exit=1` (no absolute local paths or session URLs in tracked documents).

**NOTIFY:** Task 5 done.

---

### Task 6: Prove the tooling on the old base

Purpose: separate tooling failures from sync failures. The code is still the known-good old base.

**Files:**
- Modify: `docs/openbsd/upstream-sync.md` (builder path)

- [ ] **Step 1: Restack the branch into five commits**

```bash
git status --short            # must be empty
BEFORE=$(git rev-parse HEAD)
sh hack/openbsd_sync_upstream.sh restack f13b3dfe
git diff --stat "$BEFORE" HEAD | wc -l
git rev-list --count f13b3dfe..HEAD
git diff --name-status main HEAD
```
Expected: five `OpenBSD: …` commits, `0`, `5`, and exactly this difference from `main`:

```
M	.gitlab-ci.yml
A	.claude/rules/openbsd.md
D	CLAUDE.md
M	deploy/openbsd/build_pkg.sh
A	docs/openbsd/upstream-sync.md
A	docs/superpowers/plans/2026-10-09-upstream-sync.md
A	docs/superpowers/specs/2026-10-09-upstream-sync-design.md
A	hack/openbsd_check_go.sh
M	hack/openbsd_patch_deps.sh
A	hack/openbsd_smoke_test.sh
A	hack/openbsd_sync_upstream.sh
M	tasks/lessons.md
M	tasks/todo.md
```
Nothing under `cmd/` or `pkg/` differs, so the port's code is byte-identical to `main`.

- [ ] **Step 2: Push and wait for the first pipeline**

```bash
git push -u gitlab OSS-5-upstream-sync-routine
glab ci status -b OSS-5-upstream-sync-routine
```
Expected when finished: `build` and `package` green; `smoke` fails at the `doas` line with a permission error, because the rule does not exist yet. From the `build` job log (`glab ci trace <job-id>`) read two lines:
- `runner user gitlab-runner, CI_PROJECT_DIR=<path>`
- `Go <version> satisfies go.mod (needs >= 1.23.0)`

If `build` or `package` fails, use superpowers:systematic-debugging, fix, commit, `sh hack/openbsd_sync_upstream.sh restack`, and `git push --force-with-lease gitlab OSS-5-upstream-sync-routine`.

- [ ] **Step 3: NOTIFY — ask the user for the builder and GitLab prerequisites**

Send the user, with `<path>` and `<version>` filled in from Step 2:

1. On the builder as root, **append** this line to `/etc/doas.conf` (create the file with mode 0600 if it does not exist):
   `permit nopass gitlab-runner as root cmd /bin/sh args <path>/hack/openbsd_smoke_test.sh`
2. The builder has Go `<version>`; `v1.4.1` needs >= 1.25.0. Upgrade if lower.
3. In GitLab → Settings → Repository → Protected branches: allow force-push on `main`.
4. `git ls-remote origin` fails on the dev machine with "Host key verification failed"; pushing to GitHub needs github.com in `~/.ssh/known_hosts`.

Wait for the user's confirmation of items 1 and 2 before Step 4. Items 3 and 4 are needed only in Task 8.

- [ ] **Step 4: Record the path and re-run**

In `docs/openbsd/upstream-sync.md` replace `BUILDER_PROJECT_DIR` with `<path>`.

```bash
git commit -am "OSS-5: Record builder project directory" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
sh hack/openbsd_sync_upstream.sh restack
git push --force-with-lease gitlab OSS-5-upstream-sync-routine
glab ci status -b OSS-5-upstream-sync-routine
```
Expected when finished: all four stages green. The `smoke` job log shows the refusal without root (`smoke: FAIL: must run as root (via doas)`) and ends with `smoke: PASS`.

If a smoke step fails for a real reason, use superpowers:systematic-debugging; fix in the owning file, commit, restack, push. Add the cause to `tasks/lessons.md`.

- [ ] **Step 5: Exercise leftover cleanup (Review Focus 2)**

```bash
glab ci run -b OSS-5-upstream-sync-routine
```
When the `smoke` job log shows `smoke: mounting through rc.d`, cancel that job (`glab ci cancel job <job-id>`), then retry it (`glab ci retry <job-id>`).

Expected in the retried job, one of:
- `smoke: FAIL: another smoke run is active (pid …)` — the cancelled script is still running as root, because the runner user cannot signal it. Wait a minute and retry again.
- `smoke: removing leftovers of an earlier smoke run` followed by `smoke: PASS`.
- a normal run ending in `smoke: PASS` (the cancelled script had already cleaned up).

The job must end in `smoke: PASS` within three retries. Anything else is a defect in the lock or cleanup logic: debug and fix.

- [ ] **Step 6: Finish the task**

Tick Task 6 in `tasks/todo.md`, commit (`OSS-5: Tooling proven on the old base`), restack, push with `--force-with-lease`, wait for green.

**NOTIFY:** Task 6 done; tooling works on the old base.

---

### Task 7: Sync to v1.4.1

**Files:**
- Modify (conflict): `cmd/mount_unix.go`, `cmd/mount_main_gofuse.go`, `cmd/mount_openbsd.go`
- Create: `cmd/passfd_openbsd.go`

**Interfaces:**
- Consumes: `start`, `check-patches`, `restack` (Task 1); green tooling (Task 6).
- Produces: branch `OSS-5-sync-v1.4.1` = `v1.4.1` + five commits, pipeline green.

- [ ] **Step 1: Start the rebase**

```bash
git switch OSS-5-upstream-sync-routine && git status --short   # empty
JIRA_KEY=OSS-5 sh hack/openbsd_sync_upstream.sh start v1.4.1
```
Expected (observed in a dry run of this exact situation): preflight shows `CHANGED go: 1.23.0 -> 1.25.0` and the go-fuse replace change; branch `OSS-5-sync-v1.4.1` is created; the rebase stops in commit 2 with `CONFLICT (content)` in `cmd/mount_unix.go` and nothing else. `CLAUDE.md` does not conflict because Task 5 deleted ours.

- [ ] **Step 2: Resolve `cmd/mount_unix.go`**

```bash
git checkout --ours -- cmd/mount_unix.go
awk '/^func mountMain\(/{skip=1} !skip{print} skip&&/^}/{skip=0}' cmd/mount_unix.go > mount_unix.tmp \
  && mv mount_unix.tmp cmd/mount_unix.go
{ sed -n '1,/^)$/p' cmd/mount_main_gofuse.go; echo
  git show v1.4.1:cmd/mount_unix.go | awk '/^func mountMain\(/,/^}/'; } > gofuse.tmp \
  && mv gofuse.tmp cmd/mount_main_gofuse.go
gofmt -w cmd/mount_unix.go cmd/mount_main_gofuse.go
grep -c '^func mountMain' cmd/mount_unix.go cmd/mount_main_gofuse.go
head -1 cmd/mount_unix.go
```
Expected: `cmd/mount_unix.go:0`, `cmd/mount_main_gofuse.go:1`, and `//go:build !windows`.

Between `f13b3dfe` and `v1.4.1` the only change inside `mountMain` is `%s` → `%q` in the "Mounting volume" log line. Apply the same to `cmd/mount_openbsd.go`:

```go
	logger.Infof("Mounting volume %s at %q via cgofuse ...", conf.Format.Name, conf.Meta.MountPoint)
```

```bash
git add cmd/mount_unix.go cmd/mount_main_gofuse.go cmd/mount_openbsd.go
GIT_EDITOR=true git rebase --continue
git log --oneline v1.4.1..HEAD
```
Expected: the rebase completes; five `OpenBSD: …` commits on `v1.4.1`. If a different commit conflicts, read the guide with `git show ORIG_HEAD:docs/openbsd/upstream-sync.md`, resolve, and note the case for Step 6.

- [ ] **Step 3: Add the OpenBSD passfd constant**

`v1.4.1` has `cmd/passfd.go` (`!windows`) using `MSG_CMSG_CLOEXEC`, defined only in `passfd_linux.go` and `passfd_darwin.go`. Create `cmd/passfd_openbsd.go` (the `_openbsd` suffix is the last name segment, so no build tag is needed):

```go
/*
 * JuiceFS, Copyright 2026 Juicedata, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package cmd

// OpenBSD's syscall package doesn't export MSG_CMSG_CLOEXEC. Mirror the Darwin
// build and pass no special recvmsg flag; passfd.go references it unqualified.
const MSG_CMSG_CLOEXEC = 0
```

- [ ] **Step 4: Local checks**

```bash
gofmt -l $(git diff --name-only v1.4.1 HEAD -- '*.go') cmd/passfd_openbsd.go
go build -o /dev/null .
go vet ./cmd/ ./pkg/vfs/ ./pkg/chunk/
make juicefs.lite && rm -f juicefs.lite
go test -count=1 -timeout=10m ./pkg/chunk/... ./pkg/vfs/...
git add -A && git commit -m "OSS-5: Port fixes for v1.4.1" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
sh hack/openbsd_sync_upstream.sh check-patches 2>&1 | grep -E '^(Patching go-fuse at|Note:|== check-patches OK|ERROR)'
```
Expected:
- `gofmt` prints nothing (only our files are checked; three upstream files are unformatted in pristine `v1.4.1`).
- The Linux build, `go vet` and the lite build succeed. Fix unused or missing imports as the compiler reports them, per the conflict guide.
- `go test`: if a test fails, run the same test in a worktree of pristine `v1.4.1` (`git worktree add <scratch>/pristine v1.4.1`). A failure that also occurs there is an environment or upstream issue: record it and move on. A failure only on our branch must be fixed.
- `check-patches` names the `…20260610024748-b44a81936922` directory and ends with `== check-patches OK` (observed by a reviewer for this revision).

Not run, with reasons: `make test.cmd` (needs sudo and a MinIO server; the pipeline's smoke test covers the mount path), `golangci-lint` and `pre-commit` (not installed on the dev machine; `gofmt` and `go vet` cover our small Go delta), a Windows build (`cmd/mount_main_gofuse.go` keeps `!windows`, so nothing changes for Windows).

Cross-check against the earlier attempt, which built on a similar upstream state:

```bash
git diff HEAD origin/NO_ISSUE-sync-with-upstream -- cmd/mount_main_gofuse.go cmd/mount_openbsd.go cmd/passfd_openbsd.go pkg/cgofuse pkg/fuse/device_openbsd.go pkg/fuse/fuse_openbsd.go pkg/chunk/utils_openbsd.go pkg/chunk/utils_openbsd_sys.go pkg/meta/utils_openbsd.go pkg/object/file_openbsd.go pkg/utils/utils_openbsd.go
```
Expected: differences only in the license header of `passfd_openbsd.go` and the `%q` line in `mount_openbsd.go`. Any other OpenBSD-specific change that exists only on the old branch is a fix to carry over: apply and commit it.

- [ ] **Step 5: Restack and push**

```bash
sh hack/openbsd_sync_upstream.sh restack
git diff --name-status v1.4.1 HEAD | grep -v '^A'
git push -u --force-with-lease gitlab OSS-5-sync-v1.4.1
glab ci status -b OSS-5-sync-v1.4.1
```
Expected: five commits; the non-added paths are exactly
```
M	cmd/mount_unix.go
M	pkg/chunk/utils_unix.go
M	pkg/vfs/vfs.go
```

- [ ] **Step 6: Iterate until the pipeline is green through `smoke`**

On a red pipeline: read the failing job (`glab ci trace <job-id>`; for a long trace, hand the reading to a subagent and ask for the first error only), use superpowers:systematic-debugging, fix the root cause in the owning file, commit, and repeat Step 5. Likely causes, most likely first:

- `hack/openbsd_check_go.sh` fails → builder Go < 1.25.0. **NOTIFY** the user; only they can upgrade it. Wait.
- `undefined: …` in `cmd/` or `pkg/` on OpenBSD → a new upstream platform constant or function; add an `_openbsd.go` counterpart mirroring Darwin.
- `ERROR: step '…'` from the patch script → repair that step.
- Compile errors in `pkg/fuse/*_openbsd.go` or `pkg/cgofuse` → upstream changed a `vfs`/`fuse` signature; adapt our file.
- `smoke: FAIL: …` → a behaviour change at mount time; reproduce by reading the log lines the job prints.

After the pipeline is green, record each new kind of failure and its fix in the conflict guide (`docs/openbsd/upstream-sync.md`) and in `tasks/lessons.md`.

- [ ] **Step 7: Finish the task**

Tick Task 7 in `tasks/todo.md`, commit (`OSS-5: Sync to v1.4.1 verified`), restack, push with `--force-with-lease`, wait for green.

**NOTIFY:** the sync branch is green; `main` will be moved next (the user approved force-pushing `main` once the pipeline is green). List any Task 6 Step 3 prerequisite that is still open.

---

### Task 8: Move `main`, finish, verify acceptance

**Files:**
- Modify: `docs/openbsd/upstream-sync.md` (sync log), `tasks/todo.md`

- [ ] **Step 1: Sync log and review section (before moving `main`, so they are part of the stack)**

Append to the sync log table in `docs/openbsd/upstream-sync.md` (use the actual date; extend the notes with what Task 7 Step 6 turned up):

```markdown
| 2026-10-09 | `f13b3dfe` (upstream main, 2026-03-19) | `v1.4.1` | OSS-5 | First sync. Conflict in `cmd/mount_unix.go` only. Added `cmd/passfd_openbsd.go` and `MSG_CMSG_CLOEXEC` in the go-fuse patch. Builder needs Go >= 1.25.0. |
```

In `tasks/todo.md` tick Task 8 and append:

```markdown
### Review

- Result: `main` is `v1.4.1` plus five `OpenBSD:` commits; pipeline green through `smoke`.
- Rollback point: tag `pre-sync/v1.4.1`.
- Routine for the next sync: `docs/openbsd/upstream-sync.md`.
- What went differently from the plan: <one line per surprise from Tasks 6 and 7, or "nothing">
```
Replace the last line's angle-bracket text with the real list before committing.

```bash
git commit -am "OSS-5: Add sync log entry and review" -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
sh hack/openbsd_sync_upstream.sh restack
git push --force-with-lease gitlab OSS-5-sync-v1.4.1
glab ci status -b OSS-5-sync-v1.4.1
```
Expected when finished: green through `smoke`.

- [ ] **Step 2: Check both remotes accept pushes**

```bash
git fetch gitlab main && git fetch origin main
git rev-parse gitlab/main origin/main
git push --dry-run gitlab HEAD:refs/heads/oss-5-write-test
git push --dry-run origin HEAD:refs/heads/oss-5-write-test
```
Expected: two identical hashes (`75b6ee2d…`); both dry runs report `* [new branch]`. If `origin` fails with "Host key verification failed", **NOTIFY** the user and wait; do not edit `known_hosts` yourself. If the two hashes differ, stop and **NOTIFY**: the mirrors have diverged and the user must say which one is right.

- [ ] **Step 3: Tag the old `main` and move it**

```bash
git tag pre-sync/v1.4.1 gitlab/main
git push gitlab pre-sync/v1.4.1 && git push origin pre-sync/v1.4.1
git branch -f main OSS-5-sync-v1.4.1
git push --force-with-lease=main:pre-sync/v1.4.1 gitlab main
git push --force-with-lease=main:pre-sync/v1.4.1 origin main
```
Expected: both pushes report a forced update; the tag pushes start no pipeline. If GitLab rejects with "protected branch", **NOTIFY** the user (Task 6 Step 3, item 3) and wait. If `gitlab` accepted and `origin` rejects, fix the cause and repeat only the `origin` push.

**NOTIFY:** `main` now sits on `v1.4.1` on both remotes; rollback tag is `pre-sync/v1.4.1`.

- [ ] **Step 4: Verify acceptance**

Wait for the pipeline on `main` to finish (`glab ci status -b main`). If it fails for an infrastructure reason, retry it; if it fails for a real reason, roll back with the two commands in the routine document and **NOTIFY**.

```bash
git fetch gitlab && git fetch origin
git rev-parse gitlab/main origin/main OSS-5-sync-v1.4.1          # three identical hashes
git rev-list --count v1.4.1..gitlab/main                          # 5
git log --reverse --format=%s v1.4.1..gitlab/main                 # the five subjects, in order
git diff --name-status v1.4.1 gitlab/main | grep -v '^A'          # exactly the three M lines below
git ls-remote --tags gitlab 'pre-sync/*'; git ls-remote --tags origin 'pre-sync/*'
glab ci status -b main                                            # all four stages passed
```
Expected for the `grep -v '^A'` line:
```
M	cmd/mount_unix.go
M	pkg/chunk/utils_unix.go
M	pkg/vfs/vfs.go
```

Dry run of the routine against the next target. No tag newer than `v1.4.1` exists, so use `upstream/main`:

```bash
git switch main
JIRA_KEY=DRYRUN sh hack/openbsd_sync_upstream.sh start upstream/main; echo "exit=$?"
git rebase --abort 2>/dev/null; git switch main; git branch -D DRYRUN-sync-upstream-main
git status --short; git rev-parse main gitlab/main
```
Expected: the base is found without any argument and reported as `v1.4.1`; preflight reports a newer Go version and go-fuse replace (at the time of writing `1.25.0 -> 1.25.10`; the values follow upstream); the rebase starts and may stop on a conflict, which is fine; after cleanup the tree is clean and the two hashes are identical. Note that `start` leaves `rerere.enabled=true` in the repository config; that is intended.

- [ ] **Step 5: Clean up branches**

Confirm first that Task 7 Step 4's cross-check left nothing on the old branch worth keeping. Then delete one ref per command, only where it exists:

```bash
for b in OSS-5-sync-v1.4.1 OSS-5-upstream-sync-routine NO_ISSUE-sync-with-upstream; do
  if git ls-remote --exit-code --heads gitlab "$b" >/dev/null; then git push gitlab --delete "$b"; fi
done
if git ls-remote --exit-code --heads origin NO_ISSUE-sync-with-upstream >/dev/null; then
  git push origin --delete NO_ISSUE-sync-with-upstream
fi
git branch -D OSS-5-sync-v1.4.1 OSS-5-upstream-sync-routine
git branch -a
```
Expected: only `main` locally; `main` on both remotes.

- [ ] **Step 6: Report**

- Add a comment to Jira OSS-5: synced to `v1.4.1`, link to the green `main` pipeline, location of the routine (`docs/openbsd/upstream-sync.md`), rollback tag `pre-sync/v1.4.1`. Do not transition the issue.
- **NOTIFY** the user that OSS-5 is complete, with the pipeline result.
