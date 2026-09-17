#!/bin/bash
# 把 cool91 MCP server 註冊到 Claude Code（user scope，所有專案都看得到）。冪等：已存在就先移除再加
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v claude >/dev/null; then echo "找不到 claude CLI，略過 MCP 註冊"; exit 0; fi
if ! command -v uv >/dev/null; then echo "找不到 uv（MCP server 用它跑 Python + mcp 套件），略過。裝法：curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 0; fi
claude mcp remove --scope user cool91 >/dev/null 2>&1 || true
claude mcp add --scope user cool91 -- uv run --script --quiet "$SRC/mcp/cool91_mcp.py"
echo "已註冊 MCP server cool91（重開 Claude Code session 生效；claude mcp list 可確認）"
