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
# The state directory is the lock and the record of what a run has done:
#   pid        the running script
#   installed  the package was (about to be) installed by a smoke run
#   uuid       volume UUID, to find the cache directory
#   tmp        the run's temporary directory
# It lives in /var/db because /var/run and /tmp are emptied at boot, and the
# record must survive a builder that crashed in the middle of a run.
STATE=/var/db/juicefs-smoke
# A mount that stops answering is killed after this many seconds.
LIMIT=300
WATCHDOG=""

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

# Remove everything a smoke run can leave behind, whatever state it is in,
# using only what the state directory recorded. Never fails; the state
# directory goes last because it says what to remove.
remove_smoke_state() {
  set +e
  _tmp=$(cat "$STATE/tmp" 2>/dev/null)
  case "$_tmp" in
    */../* | */..) _tmp="" ;;
    "${TMP_PREFIX}".*) ;;
    *) _tmp="" ;;
  esac
  if [ -n "$_tmp" ] && [ -L "$_tmp" ]; then
    _tmp=""
  fi
  pkill -f "juicefs mount.*${TMP_PREFIX}" 2>/dev/null
  if [ -n "$_tmp" ] && [ -d "$_tmp/mnt" ] && is_mounted "$_tmp/mnt"; then
    umount -f "$_tmp/mnt"
  fi
  if [ -f "$STATE/installed" ]; then
    pkg_delete juicefs
  fi
  _uuid=$(cat "$STATE/uuid" 2>/dev/null)
  case "$_uuid" in
    "" | *[!0-9a-f-]*) ;;
    *) rm -rf "/var/jfsCache/$_uuid" ;;
  esac
  rm -f "$ENV_FILE" "$LOG_FILE"
  if [ -n "$_tmp" ]; then
    rm -rf "$_tmp"
  fi
  rm -rf "$STATE"
  set -e
}

cleanup() {
  _rc=$?
  trap - EXIT INT TERM
  set +e
  if [ -n "$WATCHDOG" ]; then
    kill "$WATCHDOG" 2>/dev/null
  fi
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

# Never touch a host that really uses JuiceFS. These checks come before any
# cleanup and ignore what a smoke run itself creates.
if pgrep -lf "juicefs mount" 2>/dev/null | grep -v "$TMP_PREFIX" | grep -q .; then
  die "a juicefs mount process is running on this host"
fi
for _env in /etc/juicefs/*.env; do
  if [ -e "$_env" ] && [ "$_env" != "$ENV_FILE" ]; then
    die "$_env exists; this host has configured JuiceFS mounts"
  fi
done

# One run at a time. A state directory whose owner is gone is an earlier run
# that was killed or lost to a crash: clean up after it and carry on.
if ! mkdir "$STATE" 2>/dev/null; then
  _owner=$(cat "$STATE/pid" 2>/dev/null || true)
  if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
    die "another smoke run is active (pid $_owner)"
  fi
  say "removing leftovers of an earlier smoke run"
  remove_smoke_state
  mkdir "$STATE"
fi
echo $$ > "$STATE/pid"
trap cleanup EXIT
trap 'exit 130' INT TERM

if pkg_info -e 'juicefs-*' >/dev/null 2>&1; then
  die "a juicefs package is already installed on this host"
fi

TMP=$(mktemp -d "${TMP_PREFIX}.XXXXXX")
echo "$TMP" > "$STATE/tmp"
MNT="$TMP/mnt"
mkdir "$MNT" "$TMP/data"
META="sqlite3://$TMP/meta.db"

say "installing $PKG"
touch "$STATE/installed"
pkg_add -D unsigned "$PKG"
"$JFS" version

say "formatting a throwaway volume"
# No trash: with it, rm moves a name to .trash and the link count stays up.
"$JFS" format --trash-days 0 --storage file --bucket "$TMP/data/" "$META" smoke
"$JFS" status "$META" 2>/dev/null |
  sed -n 's/.*"UUID": *"\([^"]*\)".*/\1/p' | head -1 > "$STATE/uuid"

say "mounting through rc.d"
cat > "$ENV_FILE" <<EOF
JUICEFS_META_URL=$META
JUICEFS_MOUNT_POINT=$MNT
JUICEFS_LOG_FILE=$LOG_FILE
EOF
# Without this, cp or sha256 below would wait forever on a hung mount, the
# pipeline could not stop this root process, and the lock would stay taken.
# It polls in short steps and stops by itself when this script is gone: a
# single long sleep would outlive the script and keep the pipeline job open.
(
  _waited=0
  while kill -0 $$ 2>/dev/null; do
    if [ "$_waited" -ge "$LIMIT" ]; then
      pkill -9 -f "juicefs mount.*${TMP}"
      umount -f "$MNT"
      break
    fi
    sleep 2
    _waited=$((_waited + 2))
  done
) >/dev/null 2>&1 </dev/null &
WATCHDOG=$!
rcctl -f start juicefs
wait_for 30 is_mounted "$MNT" || die "$MNT is not a mount point after 30s"

# Self-test hook for the pipeline: behave like a builder that lost power now.
# The mount dies, a reboot empties /tmp, and no cleanup runs.
if [ -e .smoke-simulate-crash ]; then
  say "simulating a crash and reboot of the builder"
  kill "$WATCHDOG" 2>/dev/null || true
  pkill -9 -f "juicefs mount.*${TMP}" || true
  umount -f "$MNT" || true
  rm -rf "$TMP"
  trap - EXIT INT TERM
  kill -9 $$
fi

say "writing and reading back 8 MiB"
dd if=/dev/urandom of="$TMP/src.bin" bs=1048576 count=8 2>/dev/null
cp "$TMP/src.bin" "$MNT/data.bin"
if [ "$(sha256 -q "$TMP/src.bin")" != "$(sha256 -q "$MNT/data.bin")" ]; then
  # Show enough to tell a wrong size from wrong content from a stale read.
  say "source: $(ls -l "$TMP/src.bin")"
  say "copy:   $(ls -l "$MNT/data.bin")"
  say "bytes that differ: $(cmp -l "$TMP/src.bin" "$MNT/data.bin" 2>&1 | wc -l)"
  say "first difference: $(cmp "$TMP/src.bin" "$MNT/data.bin" 2>&1 | head -1)"
  say "last difference:  $(cmp -l "$TMP/src.bin" "$MNT/data.bin" 2>&1 | tail -1)"
  sleep 5
  say "copy after 5s: $(ls -l "$MNT/data.bin") sha256 $(sha256 -q "$MNT/data.bin")"
  dd if="$TMP/src.bin" of="$MNT/dd.bin" bs=1048576 2>/dev/null || say "dd copy failed"
  say "dd copy: $(ls -l "$MNT/dd.bin") sha256 $(sha256 -q "$MNT/dd.bin")"
  say "source sha256 $(sha256 -q "$TMP/src.bin")"
  die "checksum mismatch after read-back"
fi
# Proves the mount is JuiceFS: the data must arrive in the volume's storage.
wait_for 30 has_objects "$TMP/data" || die "no objects in $TMP/data; $MNT is not backed by the test volume"

say "hard links"
ln "$MNT/data.bin" "$MNT/link.bin"
[ "$(stat -f %l "$MNT/data.bin")" -eq 2 ] || die "link count is $(stat -f %l "$MNT/data.bin") after ln, expected 2"
rm "$MNT/link.bin"
[ "$(stat -f %l "$MNT/data.bin")" -eq 1 ] || die "link count is $(stat -f %l "$MNT/data.bin") after rm, expected 1"

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
