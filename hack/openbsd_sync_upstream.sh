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

# find_subject <subject> <git log arguments...>: newest commit among those
# whose subject is exactly <subject>, or nothing.
find_subject() {
  _want=$1
  shift
  git log --format='%H%x09%s' "$@" | awk -F '\t' -v s="$_want" '$2 == s { print $1; exit }'
}

# The commit our stack sits on: the parent of the newest "$S1" commit.
stack_base() {
  _first=$(find_subject "$S1" -n 500 HEAD)
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
  _old=$(find_subject "$_subject" "$RESTACK_BASE..$RESTACK_TIP")
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
  # From here on any failure puts the branch back exactly as it was. Not every
  # shell runs the EXIT trap on a signal, so turn Ctrl-C into a normal exit.
  trap 'git reset -q --hard "$RESTACK_TIP"; echo "restack failed; restored $RESTACK_TIP" >&2' EXIT
  trap 'exit 130' INT TERM
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
  trap - EXIT INT TERM
  echo "== Stack on $(git describe --tags --always "$RESTACK_BASE"):"
  git log --oneline "$RESTACK_BASE..HEAD"
}

check_patches() {
  require_clean
  cd "$(git rev-parse --show-toplevel)"
  scratch=$(mktemp -d)
  trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"; git checkout -q -- go.mod go.sum' EXIT
  trap 'exit 130' INT TERM
  export GOMODCACHE="$scratch" GOFLAGS=-mod=mod
  go mod download github.com/hanwen/go-fuse/v2 github.com/juicedata/godaemon github.com/winfsp/cgofuse
  replace=$(awk '/=>/ && /go-fuse/ { print $(NF-1) "@" $NF }' go.mod)
  if [ -n "$replace" ]; then
    go mod download "$replace"
  fi
  sh hack/openbsd_patch_deps.sh
  echo "== Second run (must be idempotent)"
  sh hack/openbsd_patch_deps.sh
  # The generated files only compile on OpenBSD; at least make sure they parse.
  find "$scratch" -name '*_openbsd.go' -exec gofmt -e -l {} + >/dev/null ||
    die "a patched *_openbsd.go file is not valid Go (see the gofmt errors above)"
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
