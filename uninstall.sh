#!/bin/bash
set -uo pipefail
sudo launchctl bootout system/com.cool91.guard 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.cool91.guard.plist /usr/local/bin/cool91 /tmp/cool91.json
echo "已移除 daemon 與執行檔（/etc/cool91/config.json 保留）。風扇已交還 SMC 自動控制。"
echo "記得從 ~/.claude/settings.json 移除 cool91 hook。"
