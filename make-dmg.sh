#!/bin/bash
# 生成 SwiftUltraEdit 的 DMG 安装包
#
#   ./make-dmg.sh              # 先构建 universal 版，再打包 dmg
#   ./make-dmg.sh --no-build   # 复用现有 SwiftUltraEdit.app，只打包
#
# 产物：SwiftUltraEdit.dmg（拖入 Applications 即完成安装）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SwiftUltraEdit"
VOL_NAME="SwiftUltraEdit"
DMG="$APP_NAME.dmg"
STAGE=".dmg-staging"
TMP_DMG="/tmp/${APP_NAME}_rw.dmg"

banner() { echo "==> $*"; }

# 1. 构建
if [ "${1:-}" != "--no-build" ]; then
    ./build.sh
fi

if [ ! -d "$APP_NAME.app" ]; then
    echo "未找到 $APP_NAME.app，请先运行 ./build.sh" >&2
    exit 1
fi

# 2. 暂存目录：应用本体 + Applications 快捷方式
banner "准备暂存目录"
rm -rf "$STAGE" "$TMP_DMG" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. 生成可写临时镜像
banner "创建临时镜像"
hdiutil create -srcfolder "$STAGE" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov -quiet "$TMP_DMG"

# 4. 挂载并设置 Finder 窗口布局（无自动化权限时自动跳过，不影响打包结果）
banner "设置窗口布局"
MNT="/Volumes/$VOL_NAME"
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -quiet >/dev/null
if [ -d "$MNT" ]; then
    osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "    （跳过窗口布局：无 Finder 自动化权限）"
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {180, 160, 780, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 120
        set text size of opts to 13
        set position of item "$APP_NAME.app" of container window to {160, 200}
        set position of item "Applications" of container window to {440, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    sync
    hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
else
    echo "    （挂载失败，跳过布局设置）"
fi

# 5. 压缩为只读 dmg（zlib 最高压缩）
banner "压缩镜像"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$DMG"
rm -f "$TMP_DMG"
rm -rf "$STAGE"

SIZE="$(du -h "$DMG" | awk '{print $1}')"
echo "==> 完成: $(pwd)/$DMG ($SIZE)"
echo "    用法: 双击挂载，把 $APP_NAME 拖到 Applications 即可"
