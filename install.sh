#!/bin/bash
# 安裝 cool91：release 建置 → /usr/local/bin → 設定檔 → LaunchDaemon（root 常駐）
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ swift build -c release"
swift build -c release 2>&1 | tail -1

echo "▶ 安裝到 /usr/local/bin/cool91（需 sudo）"
sudo mkdir -p /usr/local/bin /etc/cool91
sudo cp .build/release/cool91 /usr/local/bin/cool91
[ -f /etc/cool91/config.json ] || sudo cp config.example.json /etc/cool91/config.json

if pgrep -f "Macs Fan Control.app/Contents/MacOS" >/dev/null; then
  echo "⚠️  Macs Fan Control 正在執行，會和 cool91 guard 互搶風扇。請先退出它（或在它的設定裡改回 Auto 並關閉開機啟動）。"
fi

echo "▶ 安裝 LaunchDaemon"
sudo cp launchd/com.cool91.guard.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.cool91.guard.plist
sudo launchctl bootout system/com.cool91.guard 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.cool91.guard.plist
sleep 2
/usr/local/bin/cool91 status

cat <<MSG

✅ 完成。接下來把 hook 接到 Claude Code：
   把 hooks/claude-settings.snippet.json 的 hooks 區塊合併進 ~/.claude/settings.json
   （或執行 ./install-hook.py 自動合併）
MSG
