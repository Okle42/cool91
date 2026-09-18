#!/bin/bash
# 把 cool91-panel 打包成選單列 .app（LSUIElement，無 Dock 圖示），裝到 /Applications 並設開機啟動（使用者層級，不需 sudo）
set -euo pipefail
cd "$(dirname "$0")/.."
APP="/Applications/cool91 Panel.app"
BIN=".build/release/cool91-panel"
[ -x "$BIN" ] || swift build -c release 2>&1 | tail -1

pkill -x cool91-panel 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/cool91-panel"
# 內建提示音（config 沒指定音檔時用）
mkdir -p "$APP/Contents/Resources/Sounds"
cp Sounds/*.m4a "$APP/Contents/Resources/Sounds/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>cool91 Panel</string>
  <key>CFBundleDisplayName</key><string>cool91 Panel</string>
  <key>CFBundleIdentifier</key><string>com.cool91.panel</string>
  <key>CFBundleExecutable</key><string>cool91-panel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true

# 開機自動啟動（LaunchAgent）
AGENT="$HOME/Library/LaunchAgents/com.cool91.panel.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.cool91.panel</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/cool91-panel</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/com.cool91.panel" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "✅ 面板已裝到 $APP 並啟動（選單列右上角），開機自動啟動"
