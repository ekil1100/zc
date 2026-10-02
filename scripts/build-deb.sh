#!/usr/bin/env bash
set -euo pipefail

# Build a Debian package without installing it.
# Usage: bash scripts/build-deb.sh [version]

if [[ $# -gt 1 ]]; then
  echo "Usage: bash scripts/build-deb.sh [version]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
PACKAGE_VERSION=$(awk -F'"' '/^version = / { print $2; exit }' Cargo.toml)
if [[ ! "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
  echo "Invalid package version in Cargo.toml: $PACKAGE_VERSION" >&2
  exit 1
fi

VERSION="${1:-v$PACKAGE_VERSION}"
PKG_NAME="zc"
PKG_VERSION="${VERSION#v}"
if [[ "$PKG_VERSION" != "$PACKAGE_VERSION" ]]; then
  echo "Requested version $PKG_VERSION does not match package version $PACKAGE_VERSION" >&2
  exit 2
fi
[[ "$(uname -s)" == "Linux" ]] || { echo "Debian packages require a Linux build host" >&2; exit 2; }
ARCH=$(dpkg --print-architecture)
BUILD_DIR="$ROOT_DIR/build-deb"

echo "=== Building .deb package ==="
echo "Version: $PKG_VERSION"
echo "Arch: $ARCH"

# Prepare the staging directory.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/DEBIAN"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/bin"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/lib/systemd/system"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/etc/zc"

# Build.
echo "Building zc..."
cargo build --locked --release --bin zc --target-dir target

# Stage the binary.
cp "target/release/zc" "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/bin/"

# Write package metadata.
cat > "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: Like <like@ekil.sh>
Description: High-performance proxy tool in Rust
 Compatible with Clash configuration format.
EOF

# Write the service unit.
cat > "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/lib/systemd/system/zc.service" <<EOF
[Unit]
Description=zc proxy service
After=network.target

[Service]
Type=simple
RuntimeDirectory=zc
RuntimeDirectoryMode=0700
Environment=XDG_RUNTIME_DIR=/run/zc
ExecStart=/usr/bin/zc start --foreground
# No ExecReload: \`zc reload\` falls back to a full restart, which would kill
# the supervised --foreground MainPID. Use \`systemctl restart zc\` instead.
ExecStop=/usr/bin/zc stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Build the Debian archive.
echo "Building .deb package..."
dpkg-deb --build "$BUILD_DIR/$PKG_NAME-$PKG_VERSION"

# Publish the package artifact.
mkdir -p "dist"
mv "$BUILD_DIR/$PKG_NAME-$PKG_VERSION.deb" "dist/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

echo "Package built: dist/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
