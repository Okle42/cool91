# Apple Silicon (M4) 上四條讀「CPU 頻率 / 溫度」的路徑，哪些是真的

*Findings from building cool91, 2026-09-16. Mac mini M4 (Mac16,10), macOS 26 (25G83). English summary at the bottom.*

寫風扇守門員的過程中，我需要知道「CPU 現在有沒有被熱降頻」。這件事在 Apple Silicon 上比想像中難，因為常見工具讀的數字和硬體實際狀態不一樣。以下是四條路徑的同秒對照。

## 1. 頻率：IOReport 給的是軟體請求檔位，不是硬體頻率

macmon、asitop 這類不需 root 的工具，用私有框架 `libIOReport` 的 `CPU Stats / CPU Core Performance States` 通道算頻率：每個 P-state 的 residency 加權，乘上 `pmgr` 的 `voltage-states5-sram` 頻率表。

同一秒對照 `powermetrics --samplers cpu_power`（硬體計數器，需 root）：

| 時刻 | IOReport `PCPU` residency | powermetrics `P-Cluster HW active frequency` |
|---|---|---|
| 重載（load 23） | `V19P0` = 100%（最高檔，表值 4464 MHz） | **3936 MHz**，residency 100% 在 3936 |
| 重載 | `V19P0` = 100% | 4187 MHz（3936 16% / 3984 19% / 4044 20% / 4416 32% / 4464 13%） |
| 重載 | `V19P0` = 100% | 4130 MHz |

IOReport 的四組 CPU 通道都試過：`CPU Core Performance States`（每核）、`CPU Complex Performance States`（cluster）、`CPU Complex Voltage States`、`Core Performance Level`。全部一樣：重載時停在最高檔不動。

**結論**：IOReport 反映的是軟體向 DVFS 請求的檔位；M4 硬體在功率 / 熱限制下實際跑的頻率比請求低，而這一層 IOReport 看不到。**用 IOReport 算頻率的工具，在最需要看降頻的時候看不到降頻。** 要硬體頻率只能 `powermetrics`，要 root。

E-core 也有同樣現象：IOReport `ECPU` 100% 在 `V7P0`（表值 2892），硬體 2808。

附帶：`powermetrics -n 0` 不是「無限取樣」，會在第一筆後退出；要無限就不帶 `-n`。常駐一個 `-i 5000` 子行程的持續成本實測 0.18% CPU（初始化一次 0.8 秒 CPU）。

## 2. 溫度：IOHID 的「CPU 溫度」是 PMU 溫度

不需 root 的第二條路是 `IOHIDEventSystemClient`（usage page 0xff00 / usage 5），在 M4 上讀到 40 個溫度感測器，名稱是 `PMU tdie1…14`、`PMU tdev1…8`、`PMU tcal`、`PMU2 …`、`NAND CH0 temp`。M1 世代這條路還有 `pACC MTR Temp Sensor`（真正的核心感測器），M4 上已經沒有，只剩 PMU 系列 —— 所以在 M4 上靠 IOHID 拿 CPU 溫度，拿到的只能是 PMU 溫度。（macmon 在 macOS 14+ 已改走 SMC `Tp/Te/Ts` 取平均，只有舊系統才退回 IOHID；其他只走 IOHID 的小工具則會落到 PMU 值。）

同時刻對照 SMC（`AppleSMC` IOKit service，`IOConnectCallStructMethod` selector 2，不需 root）：

| 時刻 | IOHID `PMU tdie` 最高 | SMC `Tp*` 最高 | SMC `TCMz` |
|---|---|---|---|
| 1 | 62.7°C | 84.7°C | — |
| 2 | 62.2°C | 77.9°C（`Tp3X`） | **77.9°C** |

**PMU = Power Management Unit**，是主機板上另一顆 IC（M 系列有兩顆，`PMU` / `PMU2`），負責把電源轉成 SoC 各區域的電壓。`tdie` 是它自己的 die 溫度、`tdev` 是它量的周邊、`tcal` 是校正參考。它供電給 CPU 所以趨勢跟著走，但物理上不在核心熱點，絕對值低 15–20°C。

SMC 的 `Tp*` 是 SoC 內每顆 P-core 旁的感測器（M4 有 55 個 `Tp*`/`Te*` key），`TCMz` 是 Apple 自己的「SoC 最高溫」聚合 key，實測 `TCMz == max(Tp*)`。熱管理與降頻看的是這個。

**結論**：IOHID 溫度趨勢對、絕對值不對。看到別的工具 CPU 溫度比 SMC 讀的低 15–20°C，不是 SMC 虛高。另一個常見差異是「平均 vs 最高」：macmon 顯示 SMC 各 key 的平均（M4 重載時約 60–68°C），cool91 用最高值（同時刻 78–85°C），因為熱管理與降頻看的是熱點。兩者都對，只是問的問題不同。

## 3. M4 上 SMC 的溫度 key 有 1375 個，不用寫死

啟動時列舉所有 key（`#KEY` 取數量、selector 8 依索引取名），篩 `T` 開頭、型別 `flt`/`sp78`、值在 10–120 之間，再依前綴分組：`Tp*` P-core、`Te*` E-core、`Tg*` GPU、`TH0*` SSD、`TCMz` SoC max。前綴放設定檔，換晶片改設定就好。風扇 key：`FNum`、`F0Ac`（實際）、`F0Tg`（目標）、`F0Mn`/`F0Mx`（韌體回報的範圍，M4 mini = 1000–4900）、`F0Md`（手動模式）。寫 `F0Md=1` + `F0Tg` 要 root。

## 4. Mac mini M4 原廠風扇策略的數字

| 情境 | 溫度 | 風扇 |
|---|---|---|
| 原廠，重載 | 96–105°C | 1000–1774 rpm |
| 原廠，重載 10–15 分後（外部實測） | 105–107°C | ~2100 rpm，P-core 4464 → 3300–3800 MHz |
| cool91 接管後 20 秒 | 105 → 82°C | 4900 rpm |
| cool91 A/B 曲線 B，重載 5 分鐘 | 87°C | 3150 rpm，P-core 3936 MHz，pressure Nominal |

原始資料：[`ab-test-2026-09-16/`](ab-test-2026-09-16/)。

## 5. 讓 AI agent 自己節流：判斷依據是降頻，不是溫度

Claude Code 的 PreToolUse hook 可以在每次執行 Bash 前跑一支程式決定放行 / 等待 / 擋下。第一版用溫度門檻（≥ 90°C 等），結果換成省風扇的曲線後重載穩態 87–93°C，每個 Bash 前都在等，拿工作進度換一個沒意義的溫度數字。

正確的依據是 `powermetrics` 的 thermal pressure：Nominal 放行（不看溫度）、Moderate / Heavy 等它回 Nominal、Trapping 擋。溫度只當備援（拿不到 pressure 時）和安全底線（≥ 100°C）。**風扇的工作是讓降頻不發生，hook 的工作是在降頻真的發生時才介入。**

hook 本身不開 SMC、不跑 powermetrics，只讀 guard 每 5 秒寫的 JSON 快照，每次 9 ms。

## 沒驗證的

- 只有一台 M4 mini（n = 1）。M4 Pro / Max、M3、M5 是否相同未測。
- IOReport 在 M1 / M2 上是否也和硬體頻率脫節，未測（M1 / M2 mini 重載不降頻，可能剛好看不出差別）。
- 「原廠 vs cool91 同一 workflow 總耗時」還沒做。

---

## English summary

**Setup**: Mac mini M4 (Mac16,10), macOS 26. All comparisons are same-second.

1. **IOReport CPU frequency is the software-requested DVFS state, not the hardware frequency.** Under sustained load, IOReport `CPU Core Performance States` sits at 100% `V19P0` (table value 4464 MHz) while `powermetrics` `P-Cluster HW active frequency` reads 3936–4187 MHz. All four IOReport CPU channel groups behave the same. Tools that derive frequency from IOReport (macmon, asitop, …) cannot see power/thermal throttling on M4. Hardware frequency requires `powermetrics` (root). Note: `powermetrics -n 0` exits after one sample; omit `-n` for unlimited. A resident `-i 5000` process costs 0.18% CPU.
2. **On M4, IOHID only exposes PMU temperatures.** The `pACC MTR Temp Sensor` entries that existed on M1 are gone; what's left is `PMU tdie/tdev/tcal`. `PMU tdie` max 62°C vs SMC `Tp*` max 78–85°C at the same instant. PMU = Power Management Unit, a separate IC. SMC `TCMz` (Apple's own SoC-max key) equals `max(Tp*)` exactly. IOHID tracks the trend but reads 15–20°C low. (macmon uses SMC on macOS 14+, averaged; cool91 uses the max because throttling follows the hotspot.)
3. **M4 exposes 1375 SMC keys**; temperature keys can be discovered at runtime (`T*`, type `flt`/`sp78`, 10–120 range) and grouped by prefix (`Tp` P-core, `Te` E-core, `Tg` GPU, `TH0` SSD). Fan: `F0Ac/F0Tg/F0Mn/F0Mx/F0Md`.
4. **Stock M4 mini fan policy**: 96–105°C at 1000–1774 rpm; P-cores drop from 4464 to 3300–3800 MHz after 10–15 min. A curve holding 3150 rpm keeps the SoC at 87°C with no throttling (pressure Nominal, 3936 MHz).
5. **Agent self-throttling**: gate a coding agent's tool calls on thermal pressure (Nominal → go; Moderate/Heavy → wait; Trapping → deny), not on temperature. The fan's job is to prevent throttling; the gate's job is to act only when it actually happens.

Not verified: other chips (n = 1), IOReport behaviour on M1/M2, end-to-end wall-clock gain.
