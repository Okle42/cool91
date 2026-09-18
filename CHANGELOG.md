# Changelog

## 1.0.0 — 2026-09-18

第一個正式公開版。2026-09-16 起三天內從 0.1 走到這裡（0.1 → 0.2.x → 0.3.0 的過程合併記在這一條；細節在 git log 與 README「克服的問題」）。

**監控**
- 選單列 `🟡 82°`；面板是**可拖的浮動視窗**：點圖示開 / 關、右上 ✕ 收起、切 app 不消失、跨 Space、位置記住、高度跟內容走（自己拖過就停止自動，右鍵可恢復）、內容超過螢幕就捲
- 溫度 / 風扇 / P-core 頻率三張卡，各帶目前值與 5 分鐘曲線；頂端一句結論（全速運作 / 降頻中 / 溫度危險）；「現在誰在算」（libproc 差分，Mach tick 換算）
- **各感測器熱度格**：P-core / E-core / GPU 三組，一格一個 SMC 感測器（M4 共 73 個），顏色 40° 藍 → 60° 綠 → 80° 琥珀 → 95° 紅，滑過看 key 與度數；只有展開才讀
- **CPU 硬體頻率與 thermal pressure**（guard 常駐 `powermetrics` 子行程，root）：IOReport 給的是軟體檔位、看不到降頻，只有這條路是真的
- **GPU** 使用率、頻率、`GPU_CLTM` 熱降頻（IOReport，不需 root）
- 今日統計：降頻 / warm / hot / critical 秒數、最高溫、hook 等待與擋下、預熱次數
- 提示音：過熱 / 降頻、降溫回穩各一段，內建合成 chime（`Sounds/*.m4a`，`extras/make_sounds.py` 產），config `sounds.overheat / cooldown` 可換；觸發溫度面板可調（`overheatAbove` / `cooldownBelow`，互相夾住）；一趟過熱只響兩聲，門檻抖動不連叫

**風扇**
- 曲線 / 固定 / 自動；面板即改即生效（寫 config → guard 熱重載）；內建「安靜 / 均衡 / 強力」
- 預設曲線 `60→1000 75→1800 85→2600 92→3600 97→4900` 是 A/B 實測的「不降頻的最低風扇」（M4 mini 重載 87°C / 3150 rpm）
- 控制溫度 = max(CPU, GPU)；EMA 升 0.7 / 降 0.2；每輪最多降 300 / 升 800 rpm，≥ hot 時升速不限；降級 3°C 遲滯；deadband 150
- 轉速夾在韌體回報的 `F0Mn`–`F0Mx`，寫不出更高的值；SIGTERM 保持轉速等 launchd 接管，Ctrl-C / uninstall 才交還自動
- 容錯：設定檔解析失敗保留上一份；感測器讀不完整不動風扇，連續 30 秒交還自動；SMC 假值過濾（只收 10–125°C）

**AI agent 把關**
- Claude Code PreToolUse hook：**真的降頻才等**（Moderate / Heavy 等最多 90 秒），Trapping 或 ≥ critical 才擋；白名單指令任何等級放行
- 重指令預熱：`swift build` / `blender` / `ffmpeg` / `python -m`… 開頭就先把風扇拉到 3000 rpm 撐 2 分鐘
- MCP server（`mcp/cool91_mcp.py`，PEP 723 單檔）：7 個 tool 查狀態、判斷可否開工、等降溫、看誰在吃 CPU、讀設定、切風扇模式
- `cool91 check` exit 0 / 1 / 2；statusline 片段

**可靠性**
- guard LaunchDaemon `Standard` + `Nice -5`（`Background` 在高負載時被餓死三分鐘，最需要它時動不了）；watchdog 6 週期沒心跳自殺讓 launchd 重啟
- 感測器 key 清單寫進快照，不再每次列舉 1375 個 key
- 權限切分：只有 guard 要 root；面板 / hook / MCP 只讀 644 JSON，改動走設定檔與 `/tmp/cool91.events/`
- 安裝 binary 寫暫存檔再 mv（避免 `OS_REASON_CODESIGNING`）；無 TTY 也能裝（系統密碼視窗）
- 28 個單元測試

**已知盲區**
- 記憶體壓力：swap 卡死時 CPU 涼、風扇低，結論會顯示「閒置 · 未降頻」但工作實際卡住。計畫把 free % / swap / `memory_pressure` 接進快照
- 只在 Mac mini M4 上實測過；其他 M 系列需要照 README「移植新晶片」確認感測器前綴與風扇 key
