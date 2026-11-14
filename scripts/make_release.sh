#!/bin/bash
# 生成 GitHub Release 上传包：dist/FreeArc-<版本>.zip
#
# 用法:
#   scripts/make_release.sh                # 本机架构 Release 包
#   scripts/make_release.sh --universal    # 通用二进制（Apple 芯片 + Intel）
#   scripts/make_release.sh --sign "Developer ID Application: 名字 (TEAMID)"
#
# 版本号唯一来源是 Sources/ArcFreeZip/AppUpdate.swift 的 AppUpdate.currentVersion，
# 打包时自动同步进 Info.plist；本脚本再从同一处取版本号拼资产名。
# 资产名必须严格是 FreeArc-<版本>.zip —— 应用内更新器按这个名字精确匹配。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FreeArc"
DIST="dist"

VERSION="$(sed -n 's/^    static let currentVersion = "\(.*\)"$/\1/p' \
    Sources/ArcFreeZip/AppUpdate.swift | head -1)"
if [[ -z "$VERSION" ]]; then
    echo "无法从 Sources/ArcFreeZip/AppUpdate.swift 读取 currentVersion" >&2
    exit 1
fi

echo "==> 版本 v$VERSION"
echo "==> 打包应用"
./scripts/make_app.sh "$@"

APP="build/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "未生成 $APP" >&2; exit 1; }

# Info.plist 里的版本必须和资产名一致，否则客户端会比错版本
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "版本不一致：Info.plist=$PLIST_VERSION，源码=$VERSION" >&2
    exit 1
fi

echo "==> 校验签名"
codesign --verify --deep --strict "$APP" || {
    echo "签名校验失败：Release 包必须是完整签名（--no-sign 的包不要上传）" >&2
    exit 1
}

mkdir -p "$DIST"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
rm -f "$ZIP"
# --keepParent 保证压缩包根目录就是 FreeArc.app；
# 少了它会解出一堆散文件，更新器找不到 .app 会直接报错。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 复核包内结构
if ! unzip -l "$ZIP" | grep -q " $APP_NAME.app/Contents/Info.plist"; then
    echo "$ZIP 里没有 $APP_NAME.app/Contents/Info.plist，结构不对" >&2
    exit 1
fi

SIZE="$(stat -f%z "$ZIP")"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

cat <<EOF

==> 发布包就绪
    文件：$ZIP
    大小：$((SIZE / 1024 / 1024)) MB（$SIZE 字节）
    SHA256：$SHA

    下一步（GitHub）：
      Tag   ：v$VERSION
      Asset ：$APP_NAME-$VERSION.zip
      说明  ：填这次改了什么（会原样显示在更新弹窗里）

    用 gh 一条命令发：
      gh release create v$VERSION "$ZIP" --title "$APP_NAME $VERSION" --notes-file 说明.md

    或网页：仓库 → Releases → Draft a new release → 选/建 tag v$VERSION
            → 拖入上面的 zip → 填标题与说明 → Publish release
            （不要勾 Pre-release / Set as a pre-release）
EOF
