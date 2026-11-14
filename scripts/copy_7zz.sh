#!/bin/sh
# 把 7-Zip 内核与其许可拷进 .app 的 Resources（Xcode 构建阶段与 make_app.sh 共用）。
# 环境变量由 Xcode 注入：TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH / SRCROOT。
set -eu

DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

mkdir -p "$DEST"
cp "$SRC/Vendor/7zz/7zz" "$DEST/7zz"
chmod +x "$DEST/7zz"
cp "$SRC/Vendor/7zz/License.txt" "$DEST/7zz-License.txt"
