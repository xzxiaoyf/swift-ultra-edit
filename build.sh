#!/bin/bash
# 构建并组装 SwiftUltraEdit.app
#
#   ./build.sh                # release，默认产出 universal (arm64 + x86_64)
#   ./build.sh debug          # debug，同样 universal
#   ./build.sh release native # 只构建本机架构（更快，适合本机调试）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SwiftUltraEdit"
CONFIG="${1:-release}"
TARGET="${2:-universal}"

banner() { echo "==> $*"; }

BIN=""
if [ "$TARGET" = "universal" ]; then
    banner "swift build -c $CONFIG --arch arm64 --arch x86_64"
    if swift build -c "$CONFIG" --arch arm64 --arch x86_64; then
        # SwiftPM 多架构产物路径：.build/apple/Products/<Release|Debug>/
        CAP="$(echo "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}"
        BIN="$(pwd)/.build/apple/Products/$CAP/$APP_NAME"
    else
        echo "!! universal 构建失败（缺 arm64 SDK 支持？），回落本机架构" >&2
        BIN=""
    fi
fi

if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
    banner "swift build -c $CONFIG（本机架构）"
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
fi

if [ ! -f "$BIN" ]; then
    echo "构建产物未找到: $BIN" >&2
    exit 1
fi

APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名，便于本机直接运行
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

ARCHS="$(lipo -info "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/.*: //' || true)"
echo "==> 完成: $(pwd)/$APP"
echo "    架构: ${ARCHS:-unknown}"
echo "    运行: open \"$APP\""
