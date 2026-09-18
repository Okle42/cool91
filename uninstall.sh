#!/bin/bash
set -uo pipefail
sudo launchctl bootout system/com.cool91.guard 2>/dev/null
sudo /usr/local/bin/cool91 fan auto 2>/dev/null   # guard 收 SIGTERM 會保持轉速（等重啟接管），移除時要明確交還
sudo rm -rf /Library/LaunchDaemons/com.cool91.guard.plist /usr/local/bin/cool91 /usr/local/bin/cool91-guard /etc/newsyslog.d/cool91.conf /var/db/cool91 /tmp/cool91.json /tmp/cool91.history.json /tmp/cool91.events
launchctl bootout "gui/$(id -u)/com.cool91.panel" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/com.cool91.panel.plist"
pkill -x cool91-panel 2>/dev/null
rm -rf "/Applications/cool91 Panel.app"
command -v claude >/dev/null && claude mcp remove --scope user cool91 >/dev/null 2>&1 && echo "已移除 Claude Code MCP server"
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(p):
    s = json.load(open(p)); pre = s.get("hooks", {}).get("PreToolUse", [])
    s["hooks"]["PreToolUse"] = [e for e in pre if not any("cool91 hook" in h.get("command", "") for h in e.get("hooks", []))]
    json.dump(s, open(p, "w"), ensure_ascii=False, indent=2); print("已移除 Claude Code hook")
PY
echo "已移除 daemon、CLI、面板（/etc/cool91/config.json 保留）。風扇已交還 SMC 自動控制。"
