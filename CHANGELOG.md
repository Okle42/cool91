# Changelog

## 0.3.0 — 2026-09-18

重整版：提示音進專案、門檻可在面板調、各感測器看得到。

- **內建提示音**：`Sounds/overheat.m4a`（過熱 / 降頻：下行兩音）、`Sounds/cooldown.m4a`（降溫回穩：上行琶音）隨面板打包進 app bundle，裝好就有聲音。兩段是純正弦波合成的（`extras/make_sounds.py`），無版權問題。config 的 `sounds.overheat` / `sounds.cooldown` 可覆蓋成自己的音檔，缺席用內建，內建也不在才退回系統音
- **提示音門檻面板可調**：提示音卡每列多一個 Stepper，`sounds.overheatAbove`（≥ 此溫度響「熱」，缺席 = hotTemp）/ `sounds.cooldownBelow`（< 此溫度響「冷」，缺席 = hotTemp − levelHysteresis），按「套用」寫進 config。兩個門檻互相夾住，回穩不會高於過熱（validate 也擋）。CPU / GPU 降頻不看溫度一律算過熱
- **各感測器熱度格**：溫度卡下方「各感測器」展開，P-core / E-core / GPU 三組，一格一個 SMC 感測器（M4 共 73 個），顏色隨溫度 40 藍 → 60 綠 → 80 琥珀 → 95 紅，滑過看 key 與度數，每組附最熱 / 平均。只有展開時才讀，收合零成本；展開狀態實測面板 CPU 0.0%
- **套用列改成全域**：風扇卡與提示音卡任一有改動，面板底部出現一條「還原 / 套用」，各卡標題只標自己的「未套用」
- 底部多一顆「重啟」（LaunchAgent 管的用 `launchctl kickstart -k`，不是的就 `open` 自己）；版本號改讀 bundle
- config `sounds` 的 key 從 `critical` / `coolDown` / `coolDownBelow` 改名 `overheat` / `cooldown` / `cooldownBelow`（0.2.5 只活了一天，直接改不留相容）
- `extras/perf_vs_temp.py`：固定風扇轉速跑 sha256 到穩態、powermetrics 量功率，算 ops/J 的實驗腳本，拿來量「幾度效率最好」

## 0.2.5 — 2026-09-17

- **面板提示音**：進入 hot / critical 或 CPU / GPU 開始降頻響「熱」（Basso），回到正常響「冷」（Glass）。兩個獨立開關 + ▶ 試聽，開關存面板自己的 UserDefaults（即時生效）。只在冷 ↔ 熱的邊緣響、20 秒內不連響，門檻上下抖動不會一直叫
- config 新增 `sounds.critical` / `sounds.coolDown`（mp3 / aiff 路徑，可用 `~`）可換成自己的音檔；缺席或檔案不在就用系統音。面板「套用」整份重寫設定檔，這個欄位有進 CodingKeys 不會被洗掉（有測試）
- `sounds.coolDownBelow`：「降溫回穩」的獨立門檻（控制溫度降到這以下才響），缺席用 hotTemp − levelHysteresis。hook 要「工作優先」把 hotTemp 拉到 98 時，提示音還是可以等真的涼到 85 再響。一趟過熱只響兩聲：進入 hot 響「熱」上鎖，降到門檻響「冷」解鎖，中間在門檻上下抖動不叫
- 面板閒置時也會看設定檔 mtime 重載（只 stat 一次），別的 session / 手動改的門檻與音檔即時生效

## 0.2.4 — 2026-09-17

- **MCP server**（`mcp/cool91_mcp.py`）：7 個 tool 讓 AI 主動查狀態、判斷可否開工、等降溫、看誰在吃 CPU、讀設定、切風扇模式。Python + `mcp>=2` 單檔（PEP 723），`uv run --script` 即跑；`install.sh` 自動 `claude mcp add --scope user`，`uninstall.sh` 移除
- `cool91_set_fan` 和面板一樣走「寫 config → guard 熱重載」，不碰 SMC、不需 sudo；rpm 夾在風扇 min–max，guard 沒跑回警告
- 錯誤一律 `ToolError`（mcp 2.x 其他例外只會給 AI 看到「Error executing tool」）

## 0.2.3 — 2026-09-16

從 11 小時 log 分析後的調整：

- 等級降級加 3°C 遲滯（`levelHysteresis`），等級事件從每小時 ~100 筆降到個位數
- ≥ hot 時升速不限、EMA 不平滑，閒段 → 重載的一輪 +20°C 尖峰立刻全速
- 預熱關鍵字加 `python -m` / `python3 -m`
- deadband 100 → 150、降速 hold 4 → 6 輪
- guard 收 SIGTERM 保持轉速不交還（launchd 重啟接管只要幾秒）；`uninstall.sh` 明確 `fan auto`；`doctor` 偵測「guard 沒跑但風扇停在手動」
- `cool91 top` / 面板「現在誰在算」（libproc 差分，Mach tick 換算）、GPU 使用率與頻率（IOReport）、GPU 熱降頻（`GPU_CLTM`）
- daemon 以 `cool91-guard` symlink 啟動，登入項目分得清
- 已知盲區（待做）：記憶體壓力。同日一個 OCCT 布林工具吃到 31 GB 讓機器進 swap，CPU 8%、機器涼、風扇低，cool91 結論顯示「閒置 · 未降頻」但工作實際卡死。計畫把 free % / swap / `memory_pressure` 接進快照、面板結論與 hook 警告

## 0.2.2 — 2026-09-16

- **修 guard 高負載餓死**：LaunchDaemon `Background`/`Nice 10` → `Standard`/`Nice -5`；load 35 時啟動從 >3 分鐘變同一秒
- 感測器 key 清單寫進快照，CLI / 面板 / guard 重啟不再每次列舉 1375 個 key（`cool91 chip` 仍強制重掃）
- guard watchdog：6 個週期沒心跳自殺讓 launchd 重啟
- SMC 假值過濾（看過 GPU 讀到 1°C），讀值只收 10–125°C
- 升速斜率限制 +800/輪（預熱與剛接管不限），階段性負載下聲音變化平順
- 面板：一句結論 + 三張帶目前值的卡 + 統一時間軸；漸層微光風格；曲線預覽
- docs/findings-m4-sensors.md、macmon issue #78

## 0.2.1 — 2026-09-16

整頓，不改行為：

- 把關判斷、白名單、預熱關鍵字、時間格式移進 `Cool91Core/Policy.swift`；`main.swift` 拆成 main / Hook / Guard / Doctor
- 加 `Tests/Cool91CoreTests`（20 個測試）：曲線插值、門檻、設定解析與驗證、白名單、預熱、把關判斷、舊快照相容、powermetrics 解析
- 腳本收進 `scripts/`，plist / newsyslog / hook 片段收進 `install/`
- 白名單預設加 `grep`
- 去重 `hms`

## 0.2 — 2026-09-16

**把關原則改變：讓機器全力開工，風扇負責避免降頻，只有真的降頻才讓工作等。**

- guard 常駐 `powermetrics` 子行程（root）讀 P/E-core 硬體頻率與 thermal pressure，寫進快照與歷史
- hook / `check` / `wait` 改看 thermal pressure：Nominal 放行（不看溫度）、Moderate/Heavy 等、Trapping 擋；critical 溫度為安全底線；拿不到 pressure 才退回溫度門檻（hot 90 → 95）
- 預設曲線改為 A/B 實測的中間路線 `60→1000 75→1800 85→2600 92→3600 97→4900`（重載 87°C / 3150 rpm，不降頻；舊曲線保留為面板「強力」）
- 控制溫度 = max(CPU, GPU)，可用 `includeGPU` 關
- 溫度 EMA 升 0.7 / 降 0.2，每輪最多降 300 rpm；設定重載也不跳過斜率限制
- 重指令預熱：hook 看到 `swift build` / `blender` / `ffmpeg`… 開頭就發事件，guard 拉到 3000 rpm 撐 2 分鐘
- hook 白名單：`cool91` / `kill` / `pkill`… 任何等級放行
- 容錯：設定檔解析失敗保留舊設定；感測器讀不完整不動風扇，連續 30 秒交還自動
- 今日統計：降頻 / warm / hot / critical 秒數、最高溫、hook 等待與擋下、預熱、感測器故障；跨日結算寫 log
- `cool91 doctor`
- log 帶時間戳、只記變化；newsyslog 輪替
- 面板：閒置只讀快照（1.5% / 80 MB → 0.2% / 33 MB）；P-core 格、頻率圖、降頻標籤、統計列、GPU 開關、目標虛線
- 元件間通訊統一走檔案：`/tmp/cool91.json`、`/tmp/cool91.history.json`、`/tmp/cool91.events/`
- 安裝：binary 寫暫存檔再 mv（避免 `OS_REASON_CODESIGNING`）；bootout 後等 launchd 清完再 bootstrap
- `docs/ab-test-2026-09-16/`：A/B 原始資料與外部參考

## 0.1 — 2026-09-16

- SMC 讀寫（80 行 C + Swift 解碼）、感測器動態掃描
- guard LaunchDaemon：風扇曲線 / 固定 / 自動，EMA + deadband，config 熱重載，退出交還自動
- Claude Code PreToolUse hook：hot 等降溫、critical 擋下
- 選單列面板、statusline 片段
- `install.sh` 走系統密碼視窗（無 TTY 也能裝）
