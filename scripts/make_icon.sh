#!/bin/bash
# 重新生成应用图标 icns（默认石墨黑白；可选第二参数传 hex 强调色生成对应配色版本）
# 用法: scripts/make_icon.sh [hex]
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET_DIR=".build/icon.iconset"
mkdir -p .build

echo "==> 编译 icongen（与 App 共用 IconArtwork.swift）"
swiftc -O tools/icongen/main.swift Sources/ArcFreeZip/IconArtwork.swift -o .build/icongen

echo "==> 导出 iconset"
rm -rf "$ICONSET_DIR"
if [[ -n "${1:-}" ]]; then
    .build/icongen "$ICONSET_DIR" "$1"
else
    .build/icongen "$ICONSET_DIR"
fi

echo "==> iconutil 生成 icns"
iconutil -c icns "$ICONSET_DIR" -o Resources/FreeArc.icns

echo "==> 完成: Resources/FreeArc.icns"
