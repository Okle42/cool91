#!/bin/bash
# 一鍵安裝：release 建置 → CLI → 設定檔 → guard LaunchDaemon(root) → Claude Code hook + MCP → 選單列面板
# root 步驟走 macOS 系統密碼視窗，所以在沒有 TTY 的環境（Claude Code 的 ! 指令）也能跑
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"

echo "▶ swift build -c release"
swift build -c release 2>&1 | tail -1

if pgrep -f "Macs Fan Control.app/Contents/MacOS" >/dev/null; then
  echo "⚠️  Macs Fan Control 正在執行，會和 cool91 guard 互搶風扇。請先退出它（含選單列常駐）。"
  exit 1
fi

echo "▶ 安裝 CLI、設定檔、guard LaunchDaemon（會跳出系統密碼視窗）"
if [ "$(id -u)" = "0" ]; then
  ./scripts/install-root.sh "$SRC" "${SUDO_USER:-$(id -un)}"
elif sudo -n true 2>/dev/null; then
  sudo ./scripts/install-root.sh "$SRC" "$(id -un)"
else
  osascript -e "do shell script \"'$SRC/scripts/install-root.sh' '$SRC' '$(id -un)'\" with administrator privileges with prompt \"cool91 需要管理員權限安裝風扇控制 daemon\""
fi
sleep 3
/usr/local/bin/cool91 status

echo "▶ Claude Code hook"
./scripts/install-hook.py

echo "▶ Claude Code MCP server"
./scripts/install-mcp.sh

echo "▶ 選單列面板"
./scripts/make-app.sh

echo
echo "✅ 全部完成。log：tail -f /var/log/cool91.log"
