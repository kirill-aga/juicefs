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
