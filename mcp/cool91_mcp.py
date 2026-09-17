#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=2,<3"]
# ///
"""cool91 MCP server：讓 AI 主動查溫度／頻率／誰在吃 CPU，並切風扇模式。

薄薄一層，每個 tool 都是 shell 出去呼叫 /usr/local/bin/cool91，不碰 SMC。
hook（被動硬閘門）照舊，這裡是主動查詢／操作的補充。

註冊：claude mcp add --scope user cool91 -- uv run --script /path/to/cool91_mcp.py
"""
from __future__ import annotations

import json
import os
import subprocess
from typing import Any, Literal

from mcp.server.mcpserver import MCPServer
# 只有 ToolError 的訊息會原樣傳給 AI，其他例外只剩「Error executing tool」
from mcp.server.mcpserver.exceptions import ToolError

BIN = os.environ.get("COOL91_BIN", "/usr/local/bin/cool91")
CONFIG_PATHS = ["/etc/cool91/config.json", os.path.expanduser("~/.config/cool91/config.json")]
# status --json 裡的感測器 key 清單 70 多筆，對 AI 沒用，回傳前拿掉省 token
NOISY_KEYS = ("cpuKeys", "gpuKeys")

mcp = MCPServer(
    "cool91",
    instructions=(
        "cool91 是 Apple Silicon 風扇守門員。開重負載任務（build、模擬、影片轉檔）前先 cool91_check；"
        "check 回 wait/block 就用 cool91_wait 等降溫，或 cool91_top 找出誰在吃 CPU。"
        "cool91_set_fan 改的是 guard 的模式（寫設定檔、guard 熱重載），不是直接寫 SMC。"
    ),
)


def _run(*args: str, timeout: float = 30) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise ToolError(f"找不到 {BIN}，cool91 尚未安裝（跑 install.sh）")
    except subprocess.TimeoutExpired:
        raise ToolError(f"cool91 {' '.join(args)} 超過 {timeout} 秒沒回應")


def _json(*args: str, timeout: float = 30) -> tuple[dict[str, Any], int]:
    p = _run(*args, timeout=timeout)
    try:
        data = json.loads(p.stdout)
    except json.JSONDecodeError:
        raise ToolError((p.stderr or p.stdout).strip() or f"cool91 {' '.join(args)} 沒有輸出 JSON")
    for k in NOISY_KEYS:
        data.pop(k, None)
    return data, p.returncode


def _config_path() -> str:
    for p in CONFIG_PATHS:
        if os.path.exists(p):
            return p
    return CONFIG_PATHS[1]


@mcp.tool(description="目前溫度、風扇轉速、CPU/GPU 頻率、把關等級（ok/warm/hot/critical）、thermal pressure、今日統計、前幾名吃 CPU 的程式。")
def cool91_status() -> dict[str, Any]:
    data, _ = _json("status", "--json")
    return data


@mcp.tool(description="能不能開工。和 PreToolUse hook 同一套判斷：verdict=ok 可以跑、wait 降頻中該等、block 過熱該擋。附完整快照。")
def cool91_check() -> dict[str, Any]:
    data, code = _json("check", "--json")
    data["verdict"] = {0: "ok", 1: "wait", 2: "block"}.get(code, f"unknown({code})")
    return data


@mcp.tool(description="現在誰在吃 CPU、GPU 使用率／頻率（guard 每 5 秒更新；沒 guard 就自己量 2 秒）。")
def cool91_top() -> str:
    p = _run("top", timeout=15)
    return (p.stdout + p.stderr).strip()


@mcp.tool(description="檢查 guard / 快照 / hook / 設定檔 / 衝突程式（Macs Fan Control）是否正常。排障時先跑這個。")
def cool91_doctor() -> str:
    p = _run("doctor", timeout=30)
    return (p.stdout + p.stderr).strip()


@mcp.tool(description="等到可開工再回傳。預設等 thermal pressure 回 Nominal（降頻結束）；給 below_temp 則改為等控制溫度降到該值以下。timeout 秒數上限 300。")
def cool91_wait(below_temp: float | None = None, timeout: float = 90) -> dict[str, Any]:
    timeout = max(1.0, min(float(timeout), 300.0))
    args = ["wait", "--timeout", str(int(timeout))]
    if below_temp is not None:
        args += ["--below", str(float(below_temp))]
    p = _run(*args, timeout=timeout + 10)
    snap, code = _json("check", "--json")
    return {
        "ok": p.returncode == 0,
        "message": (p.stdout + p.stderr).strip(),
        "verdict": {0: "ok", 1: "wait", 2: "block"}.get(code, f"unknown({code})"),
        "controlTemp": snap.get("controlTemp"),
        "thermalPressure": snap.get("thermalPressure"),
        "level": snap.get("level"),
    }


@mcp.tool(description="讀 guard 設定檔（模式、風扇曲線、門檻、預熱關鍵字…）。")
def cool91_get_config() -> dict[str, Any]:
    path = _config_path()
    if not os.path.exists(path):
        return {"path": None, "note": "沒有設定檔，guard 用內建預設值"}
    with open(path) as f:
        cfg = json.load(f)
    return {"path": path, "config": cfg}


@mcp.tool(
    description=(
        "切風扇模式。curve=依溫度曲線（預設）、fixed=固定轉速（需給 rpm）、auto=交還 macOS 自動控制。"
        "作法和選單列面板一樣：寫設定檔，guard 幾秒內熱重載；不直接寫 SMC，所以不需要 sudo、也不會和 guard 互搶。"
        "guard 沒在跑時改設定不會生效，回傳會提醒。"
    )
)
def cool91_set_fan(mode: Literal["curve", "fixed", "auto"], rpm: float | None = None) -> dict[str, Any]:
    snap, _ = _json("status", "--json")
    fans = snap.get("fans") or []
    lo = min((f.get("min", 0) for f in fans), default=0)
    hi = max((f.get("max", 0) for f in fans), default=0)

    path = _config_path()
    cfg: dict[str, Any] = {}
    if os.path.exists(path):
        with open(path) as f:
            cfg = json.load(f)
    cfg["mode"] = mode
    if mode == "fixed":
        if rpm is None:
            raise ToolError("fixed 模式要給 rpm")
        if hi and not (lo <= rpm <= hi):
            raise ToolError(f"rpm 必須在 {int(lo)}–{int(hi)}")
        cfg["fixedRPM"] = float(rpm)
    elif rpm is not None:
        raise ToolError(f"{mode} 模式不接受 rpm")

    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, "w") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
    except PermissionError:
        raise ToolError(f"{path} 不可寫；install.sh 會把它 chown 給使用者，重跑一次或手動 sudo chown $USER {path}")

    out: dict[str, Any] = {"path": path, "mode": mode, "fixedRPM": cfg.get("fixedRPM"), "guardRunning": snap.get("guardRunning")}
    if not snap.get("guardRunning"):
        out["warning"] = "guard 沒在跑，設定已寫入但不會有人執行；跑 cool91_doctor 看原因"
    return out


if __name__ == "__main__":
    mcp.run(transport="stdio")
