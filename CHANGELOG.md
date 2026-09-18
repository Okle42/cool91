# Changelog

## 1.0.2 — 2026-09-18

安全審視（「一個 root daemon 會被怎麼看」）修出來的，行為不變。README 新增威脅模型表。

- **執行期檔案搬離 `/tmp`**：快照、歷史、事件目錄改到 root 擁有的 `/var/run/cool91/`。之前在 world-writable 的 `/tmp` 用固定檔名讓 root 寫檔，本機任何程式先放一個 symlink（`/tmp/cool91.json.tmp` → 任意檔）就能讓 root 覆寫；`chmod 1777` 事件目錄同理能把任意目錄變成人人可寫（CWE-59）。guard 啟動改用 `mkdir(2)`＋`lstat` 確認是自己的真目錄，不是就拒絕啟動；寫檔 `O_CREAT|O_EXCL|O_NOFOLLOW`
- **事件目錄是信任邊界**：1777 → 1733（能丟、不能列）；guard 只收 ≤ 4 KB 普通檔、一輪最多 64 個，不合規的丟棄並記警告；預熱轉速與秒數不信事件值、一律用 config（之前丟 `rpm: 99999` 會照登進 log）；備註在 guard 端去控制字元與換行、限 60 字（之前只在 hook 端處理，直接丟事件檔的人仍能假造 log 行）
- **log 不再記指令原文**：hook 的預熱備註改成命中的關鍵字（`swift build`），`/var/log/cool91.log` 是 644 全機可讀，指令前 60 字可能帶 token
- statusline 片段、README、`uninstall.sh` 路徑跟著改；`install-root.sh` 清掉舊的 `/tmp/cool91*`
- **升級注意**：自己的 statusline 若讀 `/tmp/cool91.json`，改讀 `/var/run/cool91/state.json`

## 1.0.1 — 2026-09-18

從 2.5 天、8300 行 `/var/log/cool91.log` 讀出來的四個毛病，都修在 guard / hook，面板不動。

- **預熱誤判**：343 次預熱裡一大半不是重工作 —— heredoc（`python3 - <<'PY'`）的每一行、`sed 's|a|swift build|'`、`grep -E "pytest|make "` 引號裡的 `|` 都被當成獨立指令去比對。切段改成先剝掉 heredoc 主體、只在引號外的 `; | &` 切（`Policy.segments`），加了 8 條回歸測試
- **預熱提早收**：預熱 30 秒後控制溫度還在曲線起點以下（不像重工作，例如 5 秒跑完的 pytest）就結束，不再 46°C 轟滿 120 秒
- **等級抖動**：P-core 做短工作 5 秒內 50 ↔ 80°C 來回，3°C 遲滯擋不住，兩天半寫了 1,742 條 `ok ↔ warm`。降級改成要連續 `rampDownHoldRounds`（6 輪 / 30 秒）都低於門檻；升級照舊立即。交還自動同樣要等 6 輪，不再 5 秒接管、5 秒交還
- **log 被 heredoc 撐成多行**：hook 送的預熱備註含換行，125 行沒時間戳。換行改成 `⏎`
- **今日統計重開機歸零**：快照在 `/tmp`，關機重開就沒了。統計另外每分鐘落地到 `/var/db/cool91/stats.json`，guard 重啟／重開機都接得上；`uninstall.sh` 一併清

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
