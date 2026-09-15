# cool91 — Apple Silicon 風扇守門員（給 Claude Code 用）

仿 Macs Fan Control 的核心功能（讀溫度、手動風扇曲線），但目標不同：
**讓 Claude Code 在跑重工作（build、render、批次腳本）時自動把關**，
機器過熱就等它降溫、真的燙到 critical 就擋下工具呼叫；同時風扇 daemon 本身幾乎不佔資源。

實測（Mac mini M4）：guard 常駐 **0.1% CPU / 8 MB 記憶體**；`cool91 check` 單次 0.18 秒。

## 三個部分

| 元件 | 身分 | 負載 | 做什麼 |
|---|---|---|---|
| `cool91 guard` | root LaunchDaemon | 0.1% CPU / 8 MB | 每 5 秒依曲線寫風扇，快照寫到 `/tmp/cool91.json` |
| `cool91 hook` | Claude Code PreToolUse(Bash) | 讀 state 檔，≈0 | hot 等降溫、critical 擋工具 |
| `cool91 Panel.app` | 選單列（使用者層級） | 每 3 秒讀 state 檔 | 看溫度/風扇/曲線圖，切模式、改曲線 → 存回 config，guard 熱重載 |

另外 `~/.claude/scripts/statusline.py` 會顯示 `🌡96°🌀3400`（同樣只讀 state 檔）。

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
./install.sh     # 一鍵：release build → CLI → LaunchDaemon(sudo) → Claude Code hook → 選單列面板
./uninstall.sh   # 全部移除，風扇交還 SMC
```

**先退出 Macs Fan Control（含選單列常駐）**，install.sh 偵測到會拒絕安裝。

## 模式（面板可切，或改 `/etc/cool91/config.json` 的 `mode`）

- `curve`：依溫度曲線（預設）。低於曲線最低點 5°C 以上會交還 SMC 省電
- `fixed`：固定 `fixedRPM`
- `auto`：完全交還 macOS（M4 mini 預設很保守：實測 CPU 100°C 風扇才 1400 rpm）

面板內建三組曲線：安靜 / 均衡 / 強力，也可逐點自訂。

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

## 安全（不會把風扇操爆）

- 轉速上限直接讀韌體回報的 `F0Mx`（M4 mini = 4900 rpm），任何模式的目標都夾在 `F0Mn`–`F0Mx`，程式上寫不出更高的值；SMC 韌體本身也會再夾一次
- guard 收到 SIGTERM/SIGINT/SIGHUP 一律把風扇交還 SMC 自動（`F0Md=0`）
- 只寫 `F?Md` / `F?Tg` 兩個 key，不碰其他 SMC 值
- 面板與 hook 純讀取，不需 root
