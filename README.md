# cool91 — Apple Silicon 風扇守門員（給 Claude Code 用）

仿 Macs Fan Control 的核心功能（讀溫度、手動風扇曲線），但目標不同：
**讓 Claude Code 在跑重工作（build、render、批次腳本）時自動把關**，
機器過熱就等它降溫、真的燙到 critical 就擋下工具呼叫；同時風扇 daemon 本身幾乎不佔資源。

實測（Mac mini M4）：guard 常駐 **0.1% CPU / 8 MB 記憶體**；`cool91 check` 單次 0.18 秒。

## 架構

```
AppleSMC (IOKit) ──► Sources/CSMC (C, 80 行)  ──► Sources/cool91 (Swift CLI, 無外部依賴)
                                                   ├─ guard  : root 常駐，依曲線寫 F0Tg/F0Md，每 5s 一次
                                                   ├─ hook   : Claude Code PreToolUse(Bash) 入口
                                                   └─ status/check/wait/fan/sensors/chip
guard 每輪把快照寫到 /tmp/cool91.json（644）→ hook / check 直接讀它，不必再開 SMC。
```

## 把關邏輯（以 CPU 最高溫為準）

| 等級 | 門檻 | hook 行為 |
|---|---|---|
| 🟢 ok | < 80°C | 放行 |
| 🟡 warm | 80–90 | 放行 |
| 🟠 hot | 90–100 | 先等降到 90 以下（最多 90 秒）再放行，附警告 |
| 🔴 critical | ≥ 100 | 擋下（deny）並說明原因；可在 config 關掉 |

門檻、曲線、等待秒數都在 `/etc/cool91/config.json`（範例：`config.example.json`）。

## 安裝

```bash
./install.sh          # release build → /usr/local/bin/cool91 → LaunchDaemon（需 sudo）
./install-hook.py     # 把 PreToolUse hook 合併進 ~/.claude/settings.json
```

**先退出 Macs Fan Control**，否則兩者互搶風扇控制。

## 常用指令

```bash
cool91 status            # 溫度 / 風扇 / 等級
cool91 status --short    # 🟡 86°C 🌀3743rpm（可接 statusline）
cool91 check ; echo $?   # 0=ok/warm 1=hot 2=critical（給腳本判斷）
cool91 wait --below 85   # 阻塞到 CPU 降到 85 以下
sudo cool91 fan 3000     # 手動設風扇；sudo cool91 fan auto 交還
sudo cool91 guard --dry-run   # 只看曲線決策不寫 SMC
sudo launchctl kickstart -k system/com.cool91.guard   # 重啟 daemon
tail -f /var/log/cool91.log
```

## 移植新晶片（M5 / M6 …）

程式沒有寫死任何感測器 key：啟動時掃描所有 `T*` 的 flt/sp78 key，
以 `cpuPrefixes` / `gpuPrefixes` 分組；風扇數讀 `FNum`，範圍讀 `F0Mn/F0Mx`。
新晶片若命名不同：

1. `cool91 sensors` 列出所有溫度 key 與目前值
2. `cool91 chip` 看目前分組結果
3. 調整 config 的 `cpuPrefixes` / `gpuPrefixes`（例如新增 `"Tc"`）
4. 若風扇 key 不再是 `F0Ac/F0Tg/F0Md`，改 `Sources/cool91/SMC.swift` 的 `fan(_:)` / `setFan`

M4 已知分組：`Tp*` P-core、`Te*` E-core、`Tg*` GPU、`TH0*` SSD、`TCMz` SoC 綜合最高值。

## 安全

- guard 收到 SIGTERM/SIGINT/SIGHUP 一律把風扇交還 SMC 自動（`F0Md=0`）
- 目標轉速永遠夾在 `F0Mn`–`F0Mx` 之間
- 只寫 `F?Md` / `F?Tg` 兩個 key，不碰其他 SMC 值
