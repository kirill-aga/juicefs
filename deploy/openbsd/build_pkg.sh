#!/bin/sh
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
cat > "${STAGING}/+CONTENTS" << EOF
@name ${PKG_NAME}
@comment POSIX-compliant distributed filesystem
@pkgpath sysutils/juicefs
@arch $(uname -m)
@cwd /usr/local
bin/juicefs
@cwd /
etc/rc.d/juicefs
etc/juicefs/juicefs.env.sample
EOF

# Create description
cp deploy/openbsd/DESCR "${STAGING}/+DESC"

# Build the package
pkg_create -B "${STAGING}" -p / \
  -d "${STAGING}/+DESC" \
  -f "${STAGING}/+CONTENTS" \
  "${PKG_NAME}.tgz"

echo "Package created: ${PKG_NAME}.tgz"

# Cleanup
rm -rf "${STAGING}"
