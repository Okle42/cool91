# A/B 實測：激進曲線 vs 中間路線（2026-09-16）

目的：確認「風扇少轉 25%」會不會讓 M4 降頻。結論：不會。

## 環境

- Mac mini M4（Mac16,10），macOS 26，cool91 guard v2（EMA 升 0.7 / 降 0.2，每輪最多降 300 rpm）
- 負載：drone91 無人機生成器的 Python workflow，兩個行程各 400–800% CPU，load average 22–42（10 核）
- 每段 5 分鐘、每 10 秒一筆 `cool91 status --short`，統計時丟掉前 60 秒過渡；powermetrics 每 20–30 秒一筆（需 root）

## 曲線

| | A：舊預設（激進） | B：新預設（中間路線） |
|---|---|---|
| curve | 55→1000 65→1800 75→3000 85→4200 90→4900 | 60→1000 75→1800 85→2600 92→3600 97→4900 |

## 結果

| | A | B | 差 |
|---|---|---|---|
| 控制溫度平均（max(CPU,GPU)） | 83.0°C（75–88） | 86.8°C（77–93） | +3.8°C |
| 風扇平均 | 4216 rpm（3952–4542） | 3150 rpm（2344–3805） | −1066 rpm（−25%） |
| P-core HW active frequency | 3936 MHz | 3936 MHz（100% residency，6/6 次） | 0 |
| thermal pressure | Nominal | Nominal（全程） | 0 |
| CPU 功耗 | 21.5 W | 17–21 W | — |
| 噪音估算（風扇定律 50·log₁₀(N₁/N₂)） | — | −6.3 dB | 人耳約少 1/3 |

3936 MHz 是 M4 全核滿載的功耗上限頻率（單核 4464），不是熱降頻；pressure = Nominal 證明。

## 對照：原廠設定（外部資料）

M4 mini（非 Pro）原廠曲線：重載 10–15 分鐘後 P-core 從 4464 掉到 3300–3800 MHz，溫度 105–107°C，風扇約 2100 rpm。
來源：[theenterprisemac](https://theenterprisemac.com/post/768543525732237312/m4mini-thermal-throttle)、[MacRumors – Mac mini M4 thermals](https://forums.macrumors.com/threads/mac-mini-m4-thermals.2442671/)、[MacRumors – 100–105°C throttling](https://forums.macrumors.com/threads/is-100-105-cpu-celsius-on-the-new-m4-mini-thermal-throttling.2442865/)

## 決定

B 成為預設（`config.example.json`、`Config.swift`、面板「均衡」）。舊 A 曲線保留為面板「強力」。

## 檔案

- `samples.txt`：每 10 秒的 load / 溫度 / 風扇（A、B 各 30 筆）
- `timeline.txt`：切換時間點
- `history-A.json` / `history-B.json`：guard 每 5 秒寫的 5 分鐘歷史（含 target）
- `powermetrics-A.txt`：A 段前一刻的 3 筆（90°C 時）；`powermetrics-B.txt`：B 段穩態 6 筆
- `config-A.json` / `config-B.json`：兩段完整設定
- `ab.sh`：測試腳本（powermetrics 另外以 root 啟動）

## 參考資料（壽命與風扇）

- [Electronics Cooling – 每升 10°C 壽命減半是否成立](https://www.electronics-cooling.com/2017/08/10c-increase-temperature-really-reduce-life-electronics-half/)：只對電遷移、腐蝕成立；熱循環比穩態高溫更傷（Collins Radio：8×）
- [Electronics Cooling – 風扇壽命評估](https://www.electronics-cooling.com/1996/05/how-to-evaluate-fan-life/)、[Longwell – L10 計算](https://www.longwellfans.com/resources/bearing-life-calculator/)：L10 70,000 h @ 40°C，壽命 ∝ (額定/實際轉速)^1.5
- [Apple Support 101576 – 風扇與風扇噪音](https://support.apple.com/en-us/101576)：未提及目標溫度或壽命
- [Tom's Hardware – M3 Air 114°C 壓測](https://www.tomshardware.com/laptops/macbooks/m3-macbook-air-hits-eye-popping-114-degrees-celsius-in-stress-test-and-didnt-melt)
