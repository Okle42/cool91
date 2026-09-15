# cool91 — Apple Silicon 風扇守門員，讓 AI 幫你工作時不燒機、不降頻

> 仿 Macs Fan Control 的核心（讀溫度、自訂風扇曲線），但多了它做不到的事：
> **當 Claude Code 這類 AI agent 在你的 Mac 上跑重工作時，讓機器全力開工、風扇負責避免降頻；只有真的降頻了才讓工作等一下。**
> 整套常駐 **0.3% CPU / 10 MB**（guard 0.1% + 頻率讀取 0.18%）。

![Mac mini M4](https://img.shields.io/badge/tested-Mac%20mini%20M4-blue) ![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![deps](https://img.shields.io/badge/dependencies-0-brightgreen) ![license](https://img.shields.io/badge/license-MIT-green)

---

## 為什麼要做這個

我把大量工程工作交給 Claude Code 跑：多個 agent 同時 build、算幾何、產 3D 模型。某天看了一眼溫度：

```
CPU 105°C   風扇 1774 rpm（macOS 自動）
```

Mac mini M4 的預設風扇策略極度保守 —— **CPU 已經 100°C，風扇還在 1400 rpm 左右慢慢轉**，然後 P-core 靜靜地從 4.4 GHz 掉到 3.3–3.8 GHz，沒有任何提示。Macs Fan Control 可以手動拉高曲線，但它有三個問題：

1. **純 GUI，沒有 CLI、沒有 API** —— AI agent 沒辦法問它「現在能不能開工」
2. **不知道有沒有降頻** —— 它只管溫度，看不到硬體頻率，更不會在降頻時讓工作等一等
3. **一個 Electron 級的常駐程式** —— 對於只想讀幾個 SMC key 的需求太重

我要的是：一個**能被程式呼叫**、**能接進 Claude Code hook**、**知道有沒有降頻**、**幾乎不佔資源**的風扇守門員。這就是 cool91。

## 優點

| | cool91 | Macs Fan Control |
|---|---|---|
| 自訂風扇曲線 | ✅ 曲線 / 固定 / 自動，面板可即時改，存檔即熱重載 | ✅（要重開） |
| CPU + GPU 一起看 | ✅ 取兩者最高值決定風扇與把關 | ✅ |
| 風扇不忽高忽低 | ✅ 升溫快反應、降溫慢放，每 5 秒最多降 300 rpm | 部分 |
| **CPU 硬體頻率 / 熱降頻偵測** | ✅ P-core GHz、thermal pressure；降頻時面板 / statusline 標紅、log 記錄 | ❌ |
| **AI agent 把關** | ✅ Claude Code PreToolUse hook：**真的降頻才等**，溫度高但沒降頻照跑 | ❌ |
| **重指令預熱** | ✅ Claude 要跑 `swift build` / `blender` / `ffmpeg`… 前先把風扇拉起來 | ❌ |
| CLI / 腳本可查詢 | ✅ `cool91 check` 回 exit code 0/1/2 | ❌ |
| 每日統計 | ✅ 降頻秒數、hot / critical 秒數、hook 等待與擋下、最高溫 | ❌ |
| 選單列顯示 | ✅ `🟡 82°`，點開有溫度 / 風扇 / 頻率三張 5 分鐘曲線圖 | ✅ |
| 常駐負載 | **0.3% CPU / 10 MB**（實測） | 數十 MB |
| 外部依賴 | **0**（純 Swift + 80 行 C，SwiftPM 直接 build） | 閉源 |
| 新晶片（M5 / M6…） | 感測器動態掃描，改 config 前綴即可 | 等官方更新 |
| 授權 | MIT | 閉源 |

## 架構

```
AppleSMC (IOKit)                        powermetrics (root)
   │                                        │
   ▼                                        │
Sources/CSMC          80 行 C：open / read / write / 列舉 key
   │                                        │
   ▼                                        ▼
Sources/Cool91Core    Swift library：型別解碼、感測器掃描、風扇曲線、設定檔、快照、頻率讀取、事件
   │
   ├─► cool91 (CLI)
   │     ├─ guard   root LaunchDaemon，每 5 秒依曲線寫 F0Tg/F0Md
   │     │          常駐一個 powermetrics 子行程讀 P/E-core 硬體頻率與 thermal pressure
   │     │          寫 /tmp/cool91.json（快照＋頻率＋今日統計）、/tmp/cool91.history.json（5 分鐘曲線）
   │     │          收 /tmp/cool91.events/ 裡的事件（預熱、hook 統計），log 到 /var/log/cool91.log
   │     ├─ hook    Claude Code PreToolUse(Bash) 入口 —— 只讀快照檔，9 ms；重指令丟預熱事件
   │     └─ status / check / wait / fan / sensors / chip / doctor
   │
   └─► cool91-panel   選單列 .app（使用者層級，不需 root）
                      閒置只讀快照更新標題；打開才讀歷史檔畫圖
                      改模式 / 曲線 → 寫 config → guard 偵測 mtime 熱重載
```

**權限切分是整個設計的核心**：只有 guard 需要 root（寫 SMC、跑 powermetrics），其他所有東西 —— 面板、hook、statusline —— 都只讀 644 的 JSON 檔。非 root 元件要「告訴」guard 什麼事（面板改曲線、hook 要預熱）一律走檔案：改設定檔，或丟一個小 JSON 到 `/tmp/cool91.events/`（1777 目錄），guard 每輪讀完就刪。

## 把關邏輯（Claude Code hook）

原則：**讓機器全力開工，風扇負責避免降頻；只有真的降頻了才讓工作等。** 溫度高不是問題，降頻才是。

guard 以 root 從 `powermetrics` 讀到 thermal pressure，hook、`cool91 check`、`cool91 wait` 都看同一套判斷：

| thermal pressure | hook 行為 | `check` exit |
|---|---|---|
| Nominal | 放行，不管幾度；指令開頭是 `swift build` / `xcodebuild` / `blender` / `ffmpeg`… 就先發預熱事件 | 0 |
| Moderate / Heavy | **等它回 Nominal（最多 90 秒）再放行**，附說明 | 1 |
| Trapping / Sleeping | **擋下（deny）**；可在 config 關掉 | 2 |
| 溫度 ≥ critical（100°C） | 不管 pressure 都擋（安全底線） | 2 |

guard 沒跑、拿不到 pressure 時退回溫度門檻：≥ 95°C 等、≥ 100°C 擋。

**白名單指令不受限**：`cool91`、`kill`、`pkill`、`killall`、`ps`、`top`、`sleep`… 任何等級都放行，否則 Claude 連降溫的指令都跑不了。清單在 config `hookAllowCommands`。

第一版是純溫度門檻（90°C 就等）。換成省風扇的曲線後重載穩態落在 87–93°C，每個 Bash 前都在等 —— 拿工作進度換一個沒有意義的溫度數字。改成看 pressure 之後，同樣 90°C 但 P-core 3.94 GHz、Nominal，直接放行。

## 安裝

需要 Xcode Command Line Tools（有 `swiftc` 即可）。先退出 Macs Fan Control（含選單列常駐），兩者會互搶風扇。

```bash
git clone https://github.com/Okle42/cool91.git
cd cool91
./install.sh     # build → CLI → guard LaunchDaemon（跳系統密碼視窗）→ Claude Code hook → 選單列面板
cool91 doctor    # 15 項檢查全綠就對了
```

移除：`./uninstall.sh`（風扇交還 macOS，設定檔保留）。

## 使用

```bash
cool91 status            # 溫度 / 頻率 / 風扇 / 等級 / guard 狀態 / 今日統計 / 預熱
cool91 status --short    # 🟡 86°C 🌀3743rpm ⚡3.98GHz（降頻時多一個「降頻(Moderate)」）
cool91 check ; echo $?   # 0=可開工 1=降頻中該等 2=該擋（和 hook 同一套判斷）
cool91 wait              # 阻塞到降頻結束；--below 85 改為等控制溫度降到 85 以下
cool91 doctor            # 檢查 guard、快照、頻率、hook、設定檔、log 輪替、衝突程式
cool91 sensors           # 列出所有溫度感測器（移植新晶片用）
cool91 chip              # 晶片型號與感測器分組
sudo cool91 fan 3000     # 手動設轉速；sudo cool91 fan auto 交還
tail -f /var/log/cool91.log
```

**面板**：選單列右上角。四格 CPU / GPU / SSD / P-core（降頻時 P-core 整格變紅），風扇條，溫度 / 風扇 / 頻率三張 5 分鐘曲線圖，今日統計列，模式「曲線 / 固定 / 自動」，內建「安靜 / 均衡 / 強力」三組曲線，也可逐點自訂，按「套用」即生效。

**設定檔** `/etc/cool91/config.json`（範例見 `config.example.json`）：曲線、門檻、平滑係數、降速斜率、GPU 是否納入、白名單、預熱關鍵字、感測器前綴都在這。改了不用重啟，解析失敗會保留上一份。

**log** `/var/log/cool91.log`：帶時間戳，只記「寫了 SMC」「等級變化」「降頻開始 / 結束」「設定重載」「預熱」「感測器異常」，不會每輪一行；超過 1 MB 由 newsyslog 輪替（`/etc/newsyslog.d/cool91.conf`）。

**Claude Code 狀態列**（選用）：`extras/statusline_snippet.py` 讀 `/tmp/cool91.json` 顯示 `🌡85°🌀4896⚡3.9G`（降頻時 ⚡ 變紅加 ↓），guard 沒在跑就自動隱藏。

## 這樣長期跑對機器好嗎？風扇會不會操壞？

**先講原廠設定的真相。** Apple 的風扇策略是「安靜優先」：CPU 100°C 才把風扇拉到 1400 rpm，晶片長期泡在 100–107°C。Apple 官方文件沒有任何一句提到目標溫度或壽命，throttle 是「預期功能」。原廠跑幾個月不會有任何可見問題 —— 但代價是你看不到的：M4 mini 重載 10–15 分鐘後 P-core 從 4464 MHz 掉到 3300–3800 MHz（−15～−25%），靜靜地慢，沒有提示。

**cool91 的預設曲線是 A/B 實測出來的「不降頻的最低風扇」。** 同一個負載（load 22–42）各跑 5 分鐘（原始資料在 [`docs/ab-test-2026-09-16/`](docs/ab-test-2026-09-16/)）：

| | 舊曲線（激進） | **現在的預設** | 原廠 |
|---|---|---|---|
| 曲線 | 55→1000 … 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 | — |
| 控制溫度 | 83°C | **87°C** | 105–107°C |
| 風扇 | 4216 rpm | **3150 rpm**（−25%，約 −6 dB） | ~2100 rpm |
| P-core | 3936 MHz，Nominal | **3936 MHz，Nominal** | 3300–3800 MHz，throttle |

多 4°C 換掉 25% 的風扇，效能一點都沒掉，距離 throttle 門檻還有 13°C 餘裕。舊曲線多出來的 1000 rpm 是在買你感覺不到的 4°C；面板裡「強力」預設就是舊曲線，要的話還在。

**壽命：**「每高 10°C 壽命減半」只對電遷移這類機制成立，且 Apple 的基準壽命本來就長，所以 105 → 87°C 是「統計上失效率降 3×」，不是「會壞 vs 不會壞」。另一個常被忽略的點：**熱循環比穩態高溫更傷**，原廠是 45 ↔ 105°C 擺盪，cool91 是 45 ↔ 87，幅度小 1/3。

**風扇會不會操壞：**工業標準 L10 = 70,000 小時 @ 40°C，壽命 ∝ (額定 ÷ 實際轉速)^1.5；就算每天 8 小時滿速也是 24 年，風扇不是瓶頸，真正的代價只有噪音和灰塵。轉速上限是韌體回報的 `F0Mx`（M4 mini = 4900），Apple 自己在高環溫也會用到，不是超規格。真正傷風扇的是**頻繁啟停和劇烈變速**，這正是不對稱 EMA + 降速斜率限制 + deadband 在防的：降溫時每 5 秒最多降 300 rpm，從 4900 回到 1000 至少 65 秒。idle 時曲線最低點就是韌體最低轉速 1000，跟 Apple 自動一模一樣。

**怎麼判斷曲線調得對不對：**看 `cool91 status` 的今日統計，關鍵一個數字：**降頻秒數應該是 0**。是 0 就代表風扇有做到它的事，溫度幾度不重要；不是 0 就把曲線高溫段拉高。

**最壞情況：**guard 掛了，launchd `KeepAlive` 幾秒內重啟；正常退出一定先交還自動；連 SMC 手動模式都沒接管時，SoC 自己還有硬體熱保護（降頻、最後關機），不會燒壞。每年清一次灰塵就好。

## 實測（Mac mini M4，macOS 26）

第一次接管那一刻的 log（舊曲線）：

```
cool91 guard 啟動（Apple M4，1 顆風扇，每 5.0s，模式 curve，控制中）
🔴 105°C 🌀1774rpm → 目標 4900 rpm     ← 接管前：macOS 自動只給 1774
🟠 100°C 🌀4900rpm
🟠  93°C 🌀4899rpm
🟡  82°C 🌀4618rpm                      ← 20 秒後，降 23°C
```

資源：`guard` 常駐 0.1% CPU / 3.5 MB，`powermetrics` 子行程 0.18% / 6 MB；面板閒置 0.2% / 33 MB（打開時 1–3%）；`cool91 hook` 每次 9 ms；`cool91 status` 單次 0.18 秒（含開 SMC）。

## 克服的問題

**1. Apple Silicon 的 SMC 沒有公開文件**
走 IOKit `AppleSMC` service、`IOConnectCallStructMethod` selector 2，80 bytes 的 `SMCKeyData_t` 結構要一個 byte 都不能差。用 C 寫這層（Swift 的固定長度陣列 tuple 太難用），Swift 只做型別解碼（`flt`、`sp78`、`fpe2`、`ui8/16/32`…）。

**2. 溫度感測器 key 沒人知道叫什麼**
M4 上有 **1375 個 key**。不寫死任何名稱：啟動時掃描所有 `T*` 且型別為 `flt`/`sp78`、值在 10–120 之間的 key，再依前綴分組（M4：`Tp*` P-core、`Te*` E-core、`Tg*` GPU、`TH0*` SSD）。前綴放在 config，換晶片改 config 就好。

**3. 寫風扇要 root，但面板和 hook 不能要 root**
把「唯一需要 root 的事」隔離成 guard daemon，其他元件只讀它寫的快照。面板要改風扇時是改設定檔（install 時 `chown` 給使用者），guard 每輪看 mtime 變了就重載 —— 面板不需要任何權限就能即時換曲線。

**4. 在沒有 TTY 的環境安裝**
Claude Code 的 `!` 指令跑 `sudo` 會直接失敗（`a terminal is required to read the password`）。root 步驟改用 `osascript … with administrator privileges`，跳系統密碼視窗，AI 自己就能完成安裝。

**5. 風扇忽高忽低**
單次取樣的 CPU 最高溫抖動很大（89 → 82 → 84）。第一版用對稱 EMA（α = 0.5）+ 100 rpm deadband，還是會 4900 → 4460 → 4700 → 4900 來回跳。現在升溫用 α = 0.7 快反應、降溫用 α = 0.2 慢慢放，再加每輪最多降 300 rpm 的斜率限制（升速不限）。從全速降到最低至少要 65 秒，風扇不會被反覆抽動。

**6. 不能把風扇操爆**
轉速上限不是寫死的常數，是直接讀韌體回報的 `F0Mx`（M4 mini = 4900）。任何模式的目標都被夾在 `F0Mn`–`F0Mx`，程式上寫不出更高的值；SMC 韌體本身還會再夾一次。guard 收到 SIGTERM/SIGINT/SIGHUP 一律先把風扇交還自動（`F0Md=0`）再退出；整支程式只寫 `F?Md`、`F?Tg` 兩個 key。

**7. hook 逾時**
Claude Code hook 預設 60 秒逾時，而等待上限是 90 秒 —— hook 設定要明確給 `"timeout": 150`，程式內也把等待夾在 120 秒以下，`doctor` 會檢查兩邊對不對得上。

**8. 和 Macs Fan Control 互搶**
兩個程式同時寫 `F0Tg` 會互相蓋掉。`install.sh` 偵測到 Macs Fan Control 還在跑（含關掉視窗後的選單列常駐）就拒絕安裝。

**9. 設定檔寫到一半被 guard 讀到**
`/etc/cool91` 目錄是 root 的，面板無法用原子寫入（要在同目錄建暫存檔），guard 每 5 秒就讀一次，有機會讀到半截 JSON。第一版解析失敗會退回預設值、而且之後永遠不再重載。現在解析失敗一律保留上一份設定並 log，下一輪再試。

**10. 感測器讀失敗被當成「很冷」**
第一版 `cpu.max() ?? 0`：SMC 讀取失敗會把溫度當 0，EMA 被拉低、風扇降速。現在讀到的 CPU 感測器少於一半就標記 `sensorOK = false`，這輪不動風扇；連續 30 秒故障就交還 SMC 自動。

**11. 面板閒著也在畫圖**
`MenuBarExtra(.window)` 的內容 view 不會 disappear，`onAppear` 判斷不了選單有沒有打開；`NSStatusBarWindow` 又永遠 `isVisible`。要看的是 `MenuBarExtraWindow` 的 `isVisible`。閒置時只讀快照更新標題，歷史曲線由 guard 寫檔、面板打開才讀，從 1.5% / 80 MB 降到 0.2% / 33 MB。

**12. CPU 硬體頻率在 M4 上只有 root 讀得到**
想顯示「有沒有被降頻」。先試 IOReport 私有框架（macmon / asitop 用的，不需 root）：`CPU Core Performance States`、`CPU Complex Performance States`、`Voltage States`、`Core Performance Level` 全試過，和 `powermetrics` 同步對照後發現它們都是**軟體請求的 DVFS 檔位**，重載時永遠停在最高檔 `V19P0`（4464），而硬體實際在功率 / 熱限制後跑 3936 —— 降頻正是發生在這一層，IOReport 看不到。硬體計數器只有 `powermetrics` 讀得到且要 root。guard 本來就是 root，就讓它常駐一個 `powermetrics -i 5000` 子行程持續讀（初始化 0.8 秒 CPU 一次，之後每筆 0.18%）。注意 `-n 0` 不是無限，會在第一筆後退出，要不帶 `-n`。

**13. 就地覆寫 binary 會被 kernel 殺掉**
`cp` 新版到 `/usr/local/bin/cool91` 之後，所有新啟動的 process 都以 `OS_REASON_CODESIGNING` 被殺 —— 舊 inode 的簽章快取還在。要 `cp` 到 `.new` 再 `mv` 換 inode。另外 `launchctl bootout` 後要等 launchd 真的清完再 `bootstrap`，否則回 `error 5`。

**14. main.swift 頂層變數的初始化順序**
`main.swift` 的頂層 `let` 是依序執行的，`runGuard` 在 `switch` 裡被呼叫時，寫在後面的 `DateFormatter` 還沒建好，時間戳輸出空字串。放進 `enum` 用 `static let`（lazy）就好。

## 移植新晶片（M5 / M6 …）

1. `cool91 sensors` 列出所有溫度 key 與目前值
2. `cool91 chip` 看目前分組結果
3. 調整 config 的 `cpuPrefixes` / `gpuPrefixes`
4. 若風扇 key 不再是 `F0Ac/F0Tg/F0Md`，改 `Sources/Cool91Core/SMC.swift` 的 `fan(_:)` / `setFan`
5. `powermetrics` 輸出格式若變，改 `Sources/Cool91Core/FreqReader.swift` 的解析

## 文件

- [`docs/ab-test-2026-09-16/`](docs/ab-test-2026-09-16/) — 曲線 A/B 實測原始資料、powermetrics 輸出、外部參考資料
- [`CHANGELOG.md`](CHANGELOG.md)

## 授權

MIT
