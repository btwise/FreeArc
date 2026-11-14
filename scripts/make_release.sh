#!/bin/bash
# 生成 GitHub Release 上传包：dist/FreeArc-<版本>.zip
#
# 用法:
#   scripts/make_release.sh                # 本机架构 Release 包
#   scripts/make_release.sh --universal    # 通用二进制（Apple 芯片 + Intel）
#   scripts/make_release.sh --sign "Developer ID Application: 名字 (TEAMID)"
#   scripts/make_release.sh --package-only # 不编译，直接打包现有 build/FreeArc.app
#                                          # （手动编出通用包后用它出发布包）
#   scripts/make_release.sh --publish      # 出包后直接调 gh 创建 GitHub Release
#
# 版本号唯一来源是 Sources/ArcFreeZip/AppUpdate.swift 的 AppUpdate.currentVersion，
# 打包时自动同步进 Info.plist；本脚本再从同一处取版本号拼资产名。
# 资产名必须严格是 FreeArc-<版本>.zip —— 应用内更新器按这个名字精确匹配。
#
# 发布说明（Release body）正文来自 ReleaseNotes/<版本>.md，脚本会把
# 「安装包 / 架构 / 大小 / SHA256」追加在末尾，保证每次发布都不用手抄校验值。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FreeArc"
DIST="dist"

# 参数分流：--package-only / --publish 归本脚本，其余原样交给 make_app.sh
PACKAGE_ONLY=0
WANT_UNIVERSAL=0
WANT_PUBLISH=0
BUILD_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --package-only) PACKAGE_ONLY=1 ;;
        --publish) WANT_PUBLISH=1 ;;
        *)
            [[ "$arg" == "--universal" ]] && WANT_UNIVERSAL=1
            BUILD_ARGS+=("$arg")
            ;;
    esac
done

VERSION="$(sed -n 's/^    static let currentVersion = "\(.*\)"$/\1/p' \
    Sources/ArcFreeZip/AppUpdate.swift | head -1)"
if [[ -z "$VERSION" ]]; then
    echo "无法从 Sources/ArcFreeZip/AppUpdate.swift 读取 currentVersion" >&2
    exit 1
fi

echo "==> 版本 v$VERSION"
if [[ $PACKAGE_ONLY -eq 1 ]]; then
    echo "==> 跳过编译，打包现有 build/$APP_NAME.app"
else
    echo "==> 打包应用"
    ./scripts/make_app.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
fi

APP="build/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "未生成 $APP" >&2; exit 1; }

# 请求了通用二进制却只出单架构（交叉编译失败时 make_app.sh 会回退，手动包也可能编错），必须让人看见
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || echo unknown)"
if [[ $WANT_UNIVERSAL -eq 1 && "$ARCHS" != *arm64* ]]; then
    echo "!! 产物架构是 ${ARCHS}，不是通用二进制：请换 Apple 芯片机器构建或 Xcode Archive（generic macOS）" >&2
fi

# Info.plist 里的版本必须和资产名一致，否则客户端会比错版本
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "版本不一致：Info.plist=${PLIST_VERSION}，源码=${VERSION}" >&2
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

# 复核包内结构。
# 注意不要写成 `unzip -l "$ZIP" | grep -q ...`：grep 命中即退出，unzip 收到 SIGPIPE
# 返回非零，配合 set -o pipefail 会把成功判成失败（包越大越容易踩到）。
ENTRIES="$(unzip -Z1 "$ZIP" 2>/dev/null || true)"
case "$ENTRIES" in
    *"$APP_NAME.app/Contents/Info.plist"*) ;;
    *)
        echo "$ZIP 里没有 $APP_NAME.app/Contents/Info.plist，结构不对" >&2
        exit 1
        ;;
esac

SIZE="$(stat -f%z "$ZIP")"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
# 7.19 MB 写成 "7 MB" 会让人以为包变小了，留一位小数
SIZE_TEXT="$(awk -v bytes="$SIZE" 'BEGIN { printf "%.1f MB", bytes / 1048576 }')"

# MARK: 发布说明
# 正文由人写（ReleaseNotes/<版本>.md），校验信息由脚本追加：
# 手抄 SHA256 早晚会抄错一次，而它恰恰是用户确认下载完整性的唯一依据。
NOTES_SRC="ReleaseNotes/$VERSION.md"
NOTES_OUT="$DIST/$APP_NAME-$VERSION-notes.md"

if [[ ! -f "$NOTES_SRC" ]]; then
    mkdir -p ReleaseNotes
    LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "$LAST_TAG" ]]; then
        RANGE="$LAST_TAG..HEAD"
    else
        RANGE=""
    fi
    {
        echo "FreeArc $VERSION"
        echo
        echo "本次更新"
        echo
        echo "- （待补充：用一句话说明这个版本最值得升级的地方）"
        echo
        echo "改动清单"
        echo
        # shellcheck disable=SC2086
        git log ${RANGE:+"$RANGE"} --no-merges --pretty='- %s' 2>/dev/null || true
    } > "$NOTES_SRC"
    echo "!! 没有 ${NOTES_SRC}，已按提交记录生成草稿——请补充后再发布" >&2
fi

{
    cat "$NOTES_SRC"
    echo
    echo "安装包：${APP_NAME}-${VERSION}.zip（${ARCHS}，${SIZE_TEXT}）"
    echo "SHA256：$SHA"
} > "$NOTES_OUT"

# MARK: 发布
if [[ $WANT_PUBLISH -eq 1 ]]; then
    command -v gh >/dev/null 2>&1 || {
        echo "未安装 GitHub CLI：brew install gh && gh auth login" >&2
        exit 1
    }
    gh auth status >/dev/null 2>&1 || {
        echo "GitHub CLI 尚未登录：gh auth login" >&2
        exit 1
    }
    # 草稿直接发出去，用户更新弹窗里就会读到「待补充」——先拦住
    if grep -q "待补充" "$NOTES_SRC"; then
        echo "发布说明还是草稿（含「待补充」）：先写完 ${NOTES_SRC}" >&2
        exit 1
    fi
    # 本地领先远程时先提醒：gh 是按远程 HEAD 建 tag 的，未推送的改动不会进 Release
    AHEAD="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [[ "$AHEAD" != "0" ]]; then
        echo "!! 本地有 ${AHEAD} 个提交没推送，Release 会指向远程旧提交，先 git push" >&2
        exit 1
    fi
    # 重复发布会因为 tag 已存在而失败，提前给出人话提示
    REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/v$VERSION" 2>/dev/null || true)"
    if [[ -n "$REMOTE_TAG" ]]; then
        echo "远程已有 tag v${VERSION}：改版本号，或先 gh release delete v${VERSION}" >&2
        exit 1
    fi
    echo "==> 创建 GitHub Release v$VERSION"
    gh release create "v$VERSION" "$ZIP" \
        --title "$APP_NAME $VERSION" \
        --notes-file "$NOTES_OUT"
    echo "==> 已发布：https://github.com/$(git remote get-url origin \
        | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')/releases/tag/v$VERSION"
    exit 0
fi

cat <<EOF

==> 发布包就绪
    文件：$ZIP
    架构：$ARCHS
    大小：${SIZE_TEXT}（$SIZE 字节）
    SHA256：$SHA
    说明：$NOTES_OUT

    下一步（GitHub）：
      Tag   ：v$VERSION
      Asset ：$APP_NAME-$VERSION.zip
      说明  ：改为 $NOTES_SRC 里的内容（会原样显示在更新弹窗里）

    用 gh 一条命令发：
      gh release create v$VERSION "$ZIP" --title "$APP_NAME $VERSION" --notes-file "$NOTES_OUT"

    或者直接让脚本发（等于把上一条命令跑一遍）：
      scripts/make_release.sh --package-only --publish

    或网页：仓库 → Releases → Draft a new release → 选/建 tag v$VERSION
            → 拖入上面的 zip → 标题填「${APP_NAME} ${VERSION}」
            → 说明点「Attach files」旁边的正文框，粘贴 $NOTES_OUT 的内容
            （不要勾 Pre-release / Set as a pre-release）
EOF
