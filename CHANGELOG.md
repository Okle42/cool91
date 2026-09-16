# Changelog

## 0.2.3 — 2026-09-16

從 11 小時 log 分析後的調整：

- 等級降級加 3°C 遲滯（`levelHysteresis`），等級事件從每小時 ~100 筆降到個位數
- ≥ hot 時升速不限、EMA 不平滑，閒段 → 重載的一輪 +20°C 尖峰立刻全速
- 預熱關鍵字加 `python -m` / `python3 -m`
- deadband 100 → 150、降速 hold 4 → 6 輪
- guard 收 SIGTERM 保持轉速不交還（launchd 重啟接管只要幾秒）；`uninstall.sh` 明確 `fan auto`；`doctor` 偵測「guard 沒跑但風扇停在手動」
- `cool91 top` / 面板「現在誰在算」（libproc 差分，Mach tick 換算）、GPU 使用率與頻率（IOReport）、GPU 熱降頻（`GPU_CLTM`）
- daemon 以 `cool91-guard` symlink 啟動，登入項目分得清

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
