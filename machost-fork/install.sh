#!/usr/bin/env bash
# 把 fork 后的 SideScreen 替换到已安装的 /Applications/SideScreen.app，并把 hdc + libusb 嵌进 bundle。
# 使用：cd machost-fork && ./install.sh
set -euo pipefail

APP="/Applications/SideScreen.app"
BIN="$APP/Contents/MacOS/SideScreen"
BUNDLED_HDC_DIR="$APP/Contents/Resources/hdc"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== 编译 ==="
cd "$HERE"
swift build -c release

echo "=== 停 SideScreen ==="
killall SideScreen 2>/dev/null || true
sleep 1

echo "=== 清旧版 TCC 授权（避免「Side Screen」在系统设置里重名堆积） ==="
# 重签会换 code signature，旧 grant 与新 binary 不再匹配。手动 reset 让新版重新弹框。
tccutil reset ScreenCapture com.sidescreen.app 2>/dev/null || true
tccutil reset LocalNetwork    com.sidescreen.app 2>/dev/null || true
tccutil reset Accessibility   com.sidescreen.app 2>/dev/null || true

echo "=== 备份原 binary（仅一次） ==="
test -f "$BIN.original.bak" || cp "$BIN" "$BIN.original.bak"

echo "=== 替换 binary ==="
cp .build/release/SideScreen "$BIN"

echo "=== 嵌入 hdc + libusb_shared.dylib ==="
mkdir -p "$BUNDLED_HDC_DIR"
cp Resources/hdc/hdc "$BUNDLED_HDC_DIR/"
cp Resources/hdc/libusb_shared.dylib "$BUNDLED_HDC_DIR/"
chmod +x "$BUNDLED_HDC_DIR/hdc"

echo "=== ad-hoc 签名整个 bundle（包括 hdc / libusb / SideScreen） ==="
codesign --force --deep --sign - "$APP"

echo "=== 清 quarantine ==="
xattr -cr "$APP"

echo "=== 完成 — 启动 SideScreen ==="
: > /tmp/sidescreen.log 2>/dev/null || true
open "$APP"

echo ""
echo "✅ 安装完成。SideScreen 已用 forked binary 启动，hdc 已嵌入 bundle。"
echo "   日志：tail -f /tmp/sidescreen.log"
