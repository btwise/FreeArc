#!/bin/bash
# FreeArc.app 命令行打包脚本
#
# 用法:
#   scripts/make_app.sh                     # 本机架构 Release，产出 build/FreeArc.app
#   scripts/make_app.sh --universal         # 通用二进制（arm64 + x86_64）
#   scripts/make_app.sh --sign "Developer ID Application: 你的名字 (TEAMID)"
#   scripts/make_app.sh --install           # 额外安装到 /Applications（访达扩展必需）
#   scripts/make_app.sh --open              # 构建完成后打开
#   scripts/make_app.sh --debug             # Debug 配置
#   scripts/make_app.sh --no-sign           # 完全跳过签名（仅本地验证用）
#
# 访达右键扩展（FinderSync）必须由带 Team ID 的证书签名，PlugInKit 才会登记；
# ad-hoc 签名下应用本体可用，但右键菜单不会出现。详见 README「签名与分发」。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FreeArc"
APP_OUT="build"
CONFIG="release"
UNIVERSAL=0
DO_SIGN=1
SIGN_ID=""
DO_INSTALL=0
DO_OPEN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        native)      CONFIG="release" ;;
        universal)   UNIVERSAL=1 ;;
        --universal) UNIVERSAL=1 ;;
        --debug)     CONFIG="debug" ;;
        --no-sign)   DO_SIGN=0 ;;
        --install)   DO_INSTALL=1 ;;
        --open)      DO_OPEN=1 ;;
        --sign)
            shift
            SIGN_ID="${1:-}"
            if [[ -z "$SIGN_ID" ]]; then
                echo "--sign 需要一个证书名称" >&2
                exit 1
            fi
            ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数: $1（--help 查看用法）" >&2
            exit 1
            ;;
    esac
    shift
done

# ── 签名身份 ─────────────────────────────────────────────────────────────
if [[ $DO_SIGN -eq 1 ]]; then
    if [[ -z "$SIGN_ID" ]]; then
        SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
        if [[ -z "$SIGN_ID" ]]; then
            SIGN_ID="-"
            echo "==> 未找到代码签名证书，使用 ad-hoc 签名（访达右键扩展将不可用）"
        else
            echo "==> 使用证书签名：$SIGN_ID"
        fi
    else
        echo "==> 使用指定的证书签名：$SIGN_ID"
    fi
fi

# ── 编译 ─────────────────────────────────────────────────────────────────
BIN_PATH=""
FINDER_BIN=""
if [[ $UNIVERSAL -eq 1 ]]; then
    echo "==> swift build -c $CONFIG（arm64 + x86_64）"
    PRODUCTS_DIR=".build/apple/Products/Release"
    [[ $CONFIG == "debug" ]] && PRODUCTS_DIR=".build/apple/Products/Debug"
    if swift build -c "$CONFIG" --arch arm64 --arch x86_64 --disable-sandbox; then
        BIN_PATH="$PRODUCTS_DIR/ArcFreeZip"
        FINDER_BIN="$PRODUCTS_DIR/FreeArcFinderSync"
    else
        echo "!! 通用架构构建失败，回退本机架构" >&2
    fi
fi
if [[ -z "$BIN_PATH" || ! -f "$BIN_PATH" ]]; then
    echo "==> swift build -c $CONFIG"
    swift build -c "$CONFIG" --disable-sandbox
    BIN_PATH=".build/$CONFIG/ArcFreeZip"
    FINDER_BIN=".build/$CONFIG/FreeArcFinderSync"
fi

echo "==> 构建访达扩展"
swift build -c "$CONFIG" --product FreeArcFinderSync --disable-sandbox \
    || echo "!! 扩展构建失败，右键菜单将不可用" >&2
if [[ ! -f "$FINDER_BIN" ]]; then
    FINDER_BIN=".build/$CONFIG/FreeArcFinderSync"
fi

# ── 组装 .app ────────────────────────────────────────────────────────────
APP_BUNDLE="$APP_OUT/$APP_NAME.app"
echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/FreeArc.icns "$APP_BUNDLE/Contents/Resources/FreeArc.icns"

# 版本号单一版本源在 Sources/ArcFreeZip/AppUpdate.swift（AppUpdate.currentVersion），
# 打包时同步进 Info.plist，Finder「显示简介」/关于面板与更新比较逻辑永远一致。
VERSION="$(sed -n 's/^    static let currentVersion = "\(.*\)"$/\1/p' \
    Sources/ArcFreeZip/AppUpdate.swift | head -1)"
if [[ -z "$VERSION" ]]; then
    VERSION="1.2.0"
    echo "!! 未能从 AppUpdate.swift 抓取版本号，回退 $VERSION" >&2
fi
PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
echo "==> 版本号 ${VERSION}（与 GitHub tag v${VERSION} 对应）"

# 7-Zip 内核 + 许可：与 Xcode 工程共用同一脚本，避免两套逻辑漂移
TARGET_BUILD_DIR="$PWD/$APP_BUNDLE/Contents" \
UNLOCALIZED_RESOURCES_FOLDER_PATH="Resources" \
SRCROOT="$PWD" sh scripts/copy_7zz.sh

# ── 访达扩展（先内后外签名）─────────────────────────────────────────────
if [[ -f "$FINDER_BIN" ]]; then
    APPEX="$APP_BUNDLE/Contents/PlugIns/FreeArcFinderSync.appex"
    mkdir -p "$APPEX/Contents/MacOS"
    cp Resources/FinderSync-Info.plist "$APPEX/Contents/Info.plist"
    printf 'XPC!' > "$APPEX/Contents/PkgInfo"
    cp "$FINDER_BIN" "$APPEX/Contents/MacOS/FreeArcFinderSync"
    if [[ $DO_SIGN -eq 1 ]]; then
        codesign --force --sign "$SIGN_ID" \
            --entitlements Resources/FinderSync.entitlements --timestamp=none "$APPEX"
    fi
else
    echo "!! 未找到 FreeArcFinderSync 产物，跳过扩展组装" >&2
fi

if [[ $DO_SIGN -eq 1 ]]; then
    echo "==> 签名宿主"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE" && echo "    签名校验通过"
else
    echo "==> 已跳过签名（--no-sign）"
fi

echo "==> 完成：$APP_BUNDLE"

# ── 可选：安装到 /Applications（访达扩展只认标准应用目录）──────────────
if [[ $DO_INSTALL -eq 1 ]]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    if [[ -x "$LSREGISTER" ]]; then "$LSREGISTER" -f "/Applications/$APP_NAME.app" || true; fi
    echo "==> 已安装：/Applications/$APP_NAME.app"
    # 注册纪律：只允许 /Applications 这一份被登记，否则访达会渲染两份右键菜单。
    killall Finder 2>/dev/null || true
fi

if [[ $DO_OPEN -eq 1 ]]; then
    open "/Applications/$APP_NAME.app" 2>/dev/null || open "$APP_BUNDLE"
fi
