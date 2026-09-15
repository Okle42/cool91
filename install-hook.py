#!/usr/bin/env python3
"""把 cool91 hook 合併進 ~/.claude/settings.json（冪等，不重複加）"""
import json, os
path = os.path.expanduser("~/.claude/settings.json")
settings = json.load(open(path)) if os.path.exists(path) else {}
snippet = json.load(open(os.path.join(os.path.dirname(__file__), "hooks/claude-settings.snippet.json")))
pre = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
if any("cool91 hook" in h.get("command", "") for e in pre for h in e.get("hooks", [])):
    print("cool91 hook 已存在，略過")
else:
    pre.extend(snippet["hooks"]["PreToolUse"])
    json.dump(settings, open(path, "w"), ensure_ascii=False, indent=2)
    print(f"已加入 cool91 hook → {path}")
