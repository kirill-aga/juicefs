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
# Build an OpenBSD .tgz package for JuiceFS using pkg_create.
# Usage: sh deploy/openbsd/build_pkg.sh
#
# Expects the `juicefs` binary to exist in the current directory
# (typically placed there by the CI build stage).
set -ex

BINARY="./juicefs"
if [ ! -x "$BINARY" ]; then
  echo "ERROR: $BINARY not found or not executable"
  exit 1
fi

# Extract version from the binary
VERSION=$($BINARY version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$VERSION" ]; then
  VERSION="0.0.0"
fi

PKG_NAME="juicefs-${VERSION}"
# Output into the working directory by default so GitLab CI can pick the
# package up as an artifact (artifacts:paths must be inside CI_PROJECT_DIR).
# Override with OUTPUT_DIR=... when running the script by hand.
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
# The smoke test expects exactly one package here.
rm -f "${OUTPUT_DIR}"/juicefs-*.tgz
STAGING=$(mktemp -d)

# Install files into staging directory
mkdir -p "${STAGING}/usr/local/bin"
cp "$BINARY" "${STAGING}/usr/local/bin/juicefs"
chmod 755 "${STAGING}/usr/local/bin/juicefs"

mkdir -p "${STAGING}/etc/rc.d"
cp deploy/openbsd/rc.d/juicefs "${STAGING}/etc/rc.d/juicefs"
chmod 755 "${STAGING}/etc/rc.d/juicefs"

mkdir -p "${STAGING}/etc/juicefs"
cp deploy/openbsd/juicefs.env.sample "${STAGING}/etc/juicefs/juicefs.env.sample"

# Create packing list
cat > "${STAGING}/+CONTENTS" << 'EOF'
@pkgpath sysutils/juicefs
@cwd /usr/local
bin/juicefs
@cwd /
etc/rc.d/juicefs
etc/juicefs/juicefs.env.sample
@exec grep -q juicefs.log /etc/newsyslog.conf || echo "/var/log/juicefs.log 640 7 1000 * Z" >> /etc/newsyslog.conf
@unexec sed -i.bak '/juicefs\.log/d' /etc/newsyslog.conf && rm -f /etc/newsyslog.conf.bak
EOF

# Create description
cp deploy/openbsd/DESCR "${STAGING}/+DESC"

# Build the package into the output directory
mkdir -p "${OUTPUT_DIR}"
# No package dependency on fuse — libfuse.so is part of the OpenBSD base system
pkg_create -B "${STAGING}" -p / \
  -D COMMENT="POSIX-compliant distributed filesystem" \
  -d "${STAGING}/+DESC" \
  -f "${STAGING}/+CONTENTS" \
  "${OUTPUT_DIR}/${PKG_NAME}.tgz"

echo "Package created: ${OUTPUT_DIR}/${PKG_NAME}.tgz"

# Cleanup
rm -rf "${STAGING}"
