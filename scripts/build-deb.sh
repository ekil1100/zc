#!/usr/bin/env bash
set -euo pipefail

# Debian 包构建脚本
# 用法: bash scripts/build-deb.sh [version]

if [[ $# -gt 1 ]]; then
  echo "Usage: bash scripts/build-deb.sh [version]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
PACKAGE_VERSION=$(awk -F'"' '/^[[:space:]]*\.version = / { print $2; exit }' build.zig.zon)
if [[ ! "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
  echo "Invalid package version in build.zig.zon: $PACKAGE_VERSION" >&2
  exit 1
fi

VERSION="${1:-v$PACKAGE_VERSION}"
PKG_NAME="zc"
PKG_VERSION="${VERSION#v}"
if [[ "$PKG_VERSION" != "$PACKAGE_VERSION" ]]; then
  echo "Requested version $PKG_VERSION does not match package version $PACKAGE_VERSION" >&2
  exit 2
fi
ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
BUILD_DIR="$ROOT_DIR/build-deb"

echo "=== Building .deb package ==="
echo "Version: $PKG_VERSION"
echo "Arch: $ARCH"

# 清理并创建目录
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/DEBIAN"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/bin"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/lib/systemd/system"
mkdir -p "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/etc/zc"

# 构建
echo "Building zc..."
zig build -Doptimize=ReleaseSafe

# 复制二进制文件
cp "zig-out/bin/zc" "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/usr/bin/"

# 创建 control 文件
cat > "$BUILD_DIR/$PKG_NAME-$PKG_VERSION/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: Like <like@ekil.sh>
Description: High-performance proxy tool in Zig
 Compatible with Clash configuration format.
EOF

# 创建 systemd 服务文件
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

# 构建 deb 包
echo "Building .deb package..."
dpkg-deb --build "$BUILD_DIR/$PKG_NAME-$PKG_VERSION"

# 移动产物
mkdir -p "dist"
mv "$BUILD_DIR/$PKG_NAME-$PKG_VERSION.deb" "dist/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

echo "✅ Package built: dist/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
