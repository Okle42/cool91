#!/bin/bash
# 一鍵安裝：release 建置 → CLI → 設定檔 → guard LaunchDaemon(root) → Claude Code hook → 選單列面板
set -euo pipefail
cd "$(dirname "$0")"

echo "▶ swift build -c release"
swift build -c release 2>&1 | tail -1

if pgrep -f "Macs Fan Control.app/Contents/MacOS" >/dev/null; then
  echo "⚠️  Macs Fan Control 正在執行，會和 cool91 guard 互搶風扇。請先退出它（含選單列常駐）。"
  exit 1
fi

echo "▶ 安裝 CLI 與設定（需 sudo）"
sudo mkdir -p /usr/local/bin /etc/cool91
sudo cp .build/release/cool91 /usr/local/bin/cool91
[ -f /etc/cool91/config.json ] || sudo cp config.example.json /etc/cool91/config.json
# 設定檔交給目前使用者可寫，面板才能改模式/曲線；guard 偵測到修改會自動重載
sudo chown "$(id -un)" /etc/cool91/config.json

echo "▶ 安裝 guard LaunchDaemon"
sudo cp launchd/com.cool91.guard.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.cool91.guard.plist
sudo launchctl bootout system/com.cool91.guard 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.cool91.guard.plist
sleep 3
/usr/local/bin/cool91 status

echo "▶ Claude Code hook"
./install-hook.py

echo "▶ 選單列面板"
./make-app.sh

echo
echo "✅ 全部完成。log：tail -f /var/log/cool91.log"
