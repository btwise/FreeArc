#!/bin/sh
# 把 7-Zip 内核与其许可拷进 .app 的 Resources（Xcode 构建阶段与 make_app.sh 共用）。
# 环境变量由 Xcode 注入：TARGET_BUILD_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH / SRCROOT。
set -eu

DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

mkdir -p "$DEST"
cp "$SRC/Vendor/7zz/7zz" "$DEST/7zz"
chmod +x "$DEST/7zz"

# 上游 7zz 是通用二进制，但只有 arm64 切片带 ad-hoc 签名，x86_64 切片是裸的。
# Apple 芯片对可执行文件强制要求签名（用 Rosetta 跑 x86_64 切片同理），
# 裸切片会被内核直接 kill —— 表现是压缩/解压「点了没反应」。
# 这里统一补 ad-hoc 签名，两个切片都能跑。
# 顺序很重要：必须在宿主 .app 签名之前做，否则会把既有封条改坏。
xattr -cr "$DEST/7zz" 2>/dev/null || true
if ! codesign --force --sign - --identifier 7zz --timestamp=none "$DEST/7zz" 2>/dev/null; then
    echo "warning: 7zz 补签失败，Apple 芯片上可能无法执行" >&2
fi
for arch in x86_64 arm64; do
    if ! codesign --verify --strict -a "$arch" "$DEST/7zz" >/dev/null 2>&1; then
        echo "warning: 7zz 的 ${arch} 切片签名无效" >&2
    fi
done

cp "$SRC/Vendor/7zz/License.txt" "$DEST/7zz-License.txt"
