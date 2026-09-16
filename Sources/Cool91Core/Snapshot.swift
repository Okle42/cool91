import Foundation

/// 一次取樣的結果；也是 guard 寫到 state 檔的內容
public struct Snapshot: Codable {
    public var time: Date
    public var cpuMax: Double
    public var cpuAvg: Double
    public var gpuMax: Double
    /// 實際拿來決定風扇與等級的溫度（includeGPU 時 = max(cpuMax, gpuMax)）
    public var controlTemp: Double = 0
    public var ssd: Double?
    public var fans: [FanState]
    public var level: Level
    /// 讀到的 CPU 感測器數量少於預期一半就視為感測器故障，guard 不會依這輪的值降速
    public var sensorOK: Bool = true
    public var guardRunning: Bool
    public var guardTargetRPM: Double?
    public var guardMode: String? = nil
    /// 預熱到期時間（有在預熱才有）
    public var boostUntil: Date? = nil
    /// CPU 硬體實際頻率（guard 以 root 從 powermetrics 讀，非 root 拿不到）。P-core 掉到滿載值以下且 pressure 非 Nominal = 熱降頻
    public var pcoreMHz: Double? = nil
    public var ecoreMHz: Double? = nil
    /// powermetrics 的 thermal pressure：Nominal / Moderate / Heavy / Trapping / Sleeping
    public var thermalPressure: String? = nil
    /// 今日統計（guard 累計）
    public var stats: Stats? = nil
    /// guard 掃描到的感測器 key，讓其他 process（CLI、面板）不用再列舉 1375 個 key
    public var cpuKeys: [String]? = nil
    public var gpuKeys: [String]? = nil

    public struct FanState: Codable {
        public var index: Int
        public var rpm: Double
        public var target: Double
        public var min: Double
        public var max: Double
        public var manual: Bool
        public init(index: Int, rpm: Double, target: Double, min: Double, max: Double, manual: Bool) {
            self.index = index; self.rpm = rpm; self.target = target; self.min = min; self.max = max; self.manual = manual
        }
    }

    /// 當日累計：拿來評估曲線調得對不對（critical 該是 0，hot 太多就把曲線高溫段拉高）
    public struct Stats: Codable {
        public var date: String           // yyyy-MM-dd（本地時區），跨日歸零
        public var warmSeconds: Double = 0
        public var hotSeconds: Double = 0
        public var criticalSeconds: Double = 0
        public var maxTemp: Double = 0
        public var hookWaits: Int = 0     // hook 因 hot 而等待的次數
        public var hookDenies: Int = 0    // hook 因 critical 擋下的次數
        public var boosts: Int = 0        // 預熱觸發次數
        public var sensorFaults: Int = 0  // 感測器讀取失敗的輪數
        public var throttleSeconds: Double = 0  // thermal pressure 非 Nominal 的累計秒數

        public init(date: String) { self.date = date }
        public static func today() -> String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }
    }

    /// 手動解碼：新加的欄位缺席時用預設值，舊版 guard 寫的快照也讀得懂
    enum CodingKeys: String, CodingKey {
        case time, cpuMax, cpuAvg, gpuMax, controlTemp, ssd, fans, level, sensorOK, guardRunning, guardTargetRPM, guardMode, boostUntil, stats,
             pcoreMHz, ecoreMHz, thermalPressure, cpuKeys, gpuKeys
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        cpuMax = try c.decode(Double.self, forKey: .cpuMax)
        cpuAvg = try c.decodeIfPresent(Double.self, forKey: .cpuAvg) ?? cpuMax
        gpuMax = try c.decodeIfPresent(Double.self, forKey: .gpuMax) ?? 0
        controlTemp = try c.decodeIfPresent(Double.self, forKey: .controlTemp) ?? cpuMax
        ssd = try c.decodeIfPresent(Double.self, forKey: .ssd)
        fans = try c.decodeIfPresent([FanState].self, forKey: .fans) ?? []
        level = try c.decodeIfPresent(Level.self, forKey: .level) ?? .ok
        sensorOK = try c.decodeIfPresent(Bool.self, forKey: .sensorOK) ?? true
        guardRunning = try c.decodeIfPresent(Bool.self, forKey: .guardRunning) ?? false
        guardTargetRPM = try c.decodeIfPresent(Double.self, forKey: .guardTargetRPM)
        guardMode = try c.decodeIfPresent(String.self, forKey: .guardMode)
        boostUntil = try c.decodeIfPresent(Date.self, forKey: .boostUntil)
        stats = try c.decodeIfPresent(Stats.self, forKey: .stats)
        pcoreMHz = try c.decodeIfPresent(Double.self, forKey: .pcoreMHz)
        ecoreMHz = try c.decodeIfPresent(Double.self, forKey: .ecoreMHz)
        thermalPressure = try c.decodeIfPresent(String.self, forKey: .thermalPressure)
        cpuKeys = try c.decodeIfPresent([String].self, forKey: .cpuKeys)
        gpuKeys = try c.decodeIfPresent([String].self, forKey: .gpuKeys)
    }
    public init(time: Date, cpuMax: Double, cpuAvg: Double, gpuMax: Double, ssd: Double?, fans: [FanState], level: Level, guardRunning: Bool, guardTargetRPM: Double?) {
        self.time = time; self.cpuMax = cpuMax; self.cpuAvg = cpuAvg; self.gpuMax = gpuMax; self.ssd = ssd
        self.fans = fans; self.level = level; self.guardRunning = guardRunning; self.guardTargetRPM = guardTargetRPM
    }

    public static let statePath = "/tmp/cool91.json"

    /// 直接從 SMC 取樣（讀取不需 root）。keys 先掃描一次後快取，避免每次列舉 1375 個 key
    public static var cachedCPUKeys: [String] = []
    public static var cachedGPUKeys: [String] = []

    /// 強制重新掃描（cool91 chip / sensors 用）
    public static var forceRescan = false

    public static func take(config: Config) -> Snapshot {
        if cachedCPUKeys.isEmpty {
            // 先拿快照裡 guard 掃好的清單（前綴設定相同才用），省掉 1375 次 SMC 呼叫；沒有才自己掃
            if !forceRescan, let saved = load(), let ck = saved.cpuKeys, !ck.isEmpty,
               ck.allSatisfy({ k in config.cpuPrefixes.contains { k.hasPrefix($0) } }) {
                cachedCPUKeys = ck
                cachedGPUKeys = saved.gpuKeys ?? []
            } else {
                let all = SMC.scanTemperatureKeys().map { $0.0 }
                cachedCPUKeys = all.filter { k in config.cpuPrefixes.contains { k.hasPrefix($0) } }
                cachedGPUKeys = all.filter { k in config.gpuPrefixes.contains { k.hasPrefix($0) } }
            }
        }
        // SMC 偶爾回假值（GPU 讀到 1°C 之類），跟掃描時一樣只收 10–125
        let cpu = cachedCPUKeys.compactMap(SMC.readDouble).filter(SMC.plausibleTemp)
        let gpu = cachedGPUKeys.compactMap(SMC.readDouble).filter(SMC.plausibleTemp)
        // 若 guard 有在跑，補上它的資訊；感測器偶爾讀空時也拿上一筆頂著，不要畫出掉到 0 的尖刺
        let saved = load()
        let cpuMax = cpu.max() ?? saved?.cpuMax ?? 0
        let gpuMax = gpu.max() ?? saved?.gpuMax ?? 0
        let control = config.includeGPU ? max(cpuMax, gpuMax) : cpuMax
        let fans = SMC.fans().map {
            FanState(index: $0.index, rpm: $0.actual, target: $0.target, min: $0.min, max: $0.max, manual: $0.manual)
        }
        let alive = saved.map { Date().timeIntervalSince($0.time) < config.interval * 3 && $0.guardRunning } ?? false
        var snap = Snapshot(time: Date(),
                        cpuMax: cpuMax,
                        cpuAvg: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count),
                        gpuMax: gpuMax,
                        ssd: SMC.readDouble("TH0x").flatMap { SMC.plausibleTemp($0) ? $0 : nil } ?? saved?.ssd,
                        fans: fans,
                        level: config.level(for: control),
                        guardRunning: alive,
                        guardTargetRPM: alive ? saved?.guardTargetRPM : nil)
        snap.controlTemp = control
        snap.sensorOK = !cachedCPUKeys.isEmpty && cpu.count * 2 >= cachedCPUKeys.count
        snap.guardMode = alive ? saved?.guardMode : nil
        snap.boostUntil = alive ? saved?.boostUntil : nil
        snap.stats = alive ? saved?.stats : nil
        snap.cpuKeys = cachedCPUKeys
        snap.gpuKeys = cachedGPUKeys
        snap.pcoreMHz = alive ? saved?.pcoreMHz : nil
        snap.ecoreMHz = alive ? saved?.ecoreMHz : nil
        snap.thermalPressure = alive ? saved?.thermalPressure : nil
        return snap
    }

    /// guard 在跑且 state 夠新就直接用，省掉開 SMC 的成本（hook 每次 Bash 前都會呼叫）
    public static func takeFast(config: Config) -> Snapshot {
        if let saved = load(), saved.guardRunning, Date().timeIntervalSince(saved.time) < config.interval * 2 {
            return saved
        }
        return take(config: config)
    }

    public static func load() -> Snapshot? {
        guard let d = FileManager.default.contents(atPath: statePath) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Snapshot.self, from: d)
    }

    public func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        Snapshot.atomicWrite(d, to: Snapshot.statePath)
    }

    /// 先寫 .tmp 再 rename，讀的人永遠不會看到半截檔案
    static func atomicWrite(_ d: Data, to path: String) {
        let tmp = path + ".tmp"
        try? d.write(to: URL(fileURLWithPath: tmp))
        chmod(tmp, 0o644)
        rename(tmp, path)
    }

    public var json: String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    public var short: String {
        let fan = fans.first.map { String(format: "%.0f", $0.rpm) } ?? "-"
        var s = String(format: "%@ %.0f°C 🌀%@rpm", level.emoji, controlTemp, fan)
        if let p = pcoreMHz, p >= 100 { s += String(format: " ⚡%.2fGHz", p / 1000) }
        if let t = thermalPressure, t != "Nominal" { s += " 降頻(\(t))" }
        return s
    }
    /// 是否正被熱降頻（powermetrics 的 pressure 非 Nominal）
    public var throttling: Bool { thermalPressure.map { $0 != "Nominal" } ?? false }

    public var pretty: String {
        var s = "\(level.emoji) 等級: \(level.rawValue)\n"
        s += String(format: "CPU  最高 %.1f°C  平均 %.1f°C\n", cpuMax, cpuAvg)
        s += String(format: "GPU  最高 %.1f°C\n", gpuMax)
        if let ssd { s += String(format: "SSD  %.1f°C\n", ssd) }
        if let p = pcoreMHz {
            s += String(format: "頻率 P-core %@  E-core %.2f GHz  熱壓力 %@%@\n", p >= 100 ? String(format: "%.2f GHz", p / 1000) : "閒置", (ecoreMHz ?? 0) / 1000, thermalPressure ?? "?", throttling ? "（降頻中）" : "")
        }
        if !sensorOK { s += "⚠️ 感測器讀取不完整\n" }
        for f in fans {
            s += String(format: "風扇%d  %.0f rpm  目標 %.0f  範圍 %.0f–%.0f  %@\n",
                        f.index, f.rpm, f.target, f.min, f.max, f.manual ? "手動" : "自動")
        }
        if guardRunning {
            s += String(format: "guard 執行中（%@），目標 %@", guardMode ?? "curve", guardTargetRPM.map { String(format: "%.0f rpm", $0) } ?? "auto")
            if let b = boostUntil, b > Date() { s += String(format: "，預熱中（剩 %.0f 秒）", b.timeIntervalSinceNow) }
            if let st = stats {
                s += String(format: "\n今日 %@：最高 %.0f°C，warm %@，hot %@，critical %@；hook 等待 %d 次、擋下 %d 次；預熱 %d 次",
                            st.date, st.maxTemp, Format.hms(st.warmSeconds), Format.hms(st.hotSeconds), Format.hms(st.criticalSeconds),
                            st.hookWaits, st.hookDenies, st.boosts)
                if st.throttleSeconds > 0 { s += "；降頻 \(Format.hms(st.throttleSeconds))" }
                if st.sensorFaults > 0 { s += "；感測器故障 \(st.sensorFaults) 輪" }
            }
        } else {
            s += "guard 未執行（風扇由 SMC 或其他程式控制）"
        }
        return s
    }

}

// MARK: - 歷史曲線（guard 寫、面板讀）

/// guard 每輪追加一筆、保留最近 5 分鐘；面板開啟時才讀來畫圖，閒置時完全不用取樣
public struct HistoryPoint: Codable {
    public var time: Date
    public var cpu: Double
    public var gpu: Double
    public var rpm: Double
    public var target: Double?
    public var pMHz: Double? = nil
    public init(time: Date, cpu: Double, gpu: Double, rpm: Double, target: Double?, pMHz: Double? = nil) {
        self.time = time; self.cpu = cpu; self.gpu = gpu; self.rpm = rpm; self.target = target; self.pMHz = pMHz
    }
}

public enum History {
    public static let path = "/tmp/cool91.history.json"
    public static let keep: TimeInterval = 300

    public static func load() -> [HistoryPoint] {
        guard let d = FileManager.default.contents(atPath: path) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryPoint].self, from: d)) ?? []
    }

    public static func save(_ pts: [HistoryPoint]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(pts) else { return }
        Snapshot.atomicWrite(d, to: path)
    }
}

// MARK: - 事件（hook / 面板 → guard 的單向訊息）

/// 非 root 的程式要告訴 guard 一些事（預熱、統計）時寫一個小檔到這個目錄，guard 每輪讀完就刪。
/// 目錄由 guard 建立並設 1777，任何使用者都可以丟檔案進來
public struct Event: Codable {
    public enum Kind: String, Codable { case boost, hookWait, hookDeny }
    public var kind: Kind
    public var time: Date
    public var rpm: Double? = nil
    public var seconds: Double? = nil
    public var note: String? = nil

    public static let dir = "/tmp/cool91.events"

    public init(kind: Kind, rpm: Double? = nil, seconds: Double? = nil, note: String? = nil) {
        self.kind = kind; self.time = Date(); self.rpm = rpm; self.seconds = seconds; self.note = note
    }

    /// 送出事件；guard 沒建目錄（沒在跑）就靜靜略過
    @discardableResult
    public func post() -> Bool {
        guard FileManager.default.fileExists(atPath: Event.dir) else { return false }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(self) else { return false }
        let name = String(format: "%.3f-%d-%@.json", Date().timeIntervalSince1970, getpid(), kind.rawValue)
        return FileManager.default.createFile(atPath: Event.dir + "/" + name, contents: d, attributes: [.posixPermissions: 0o644])
    }

    /// guard 用：把目錄裡所有事件讀出來並刪除
    public static func drain() -> [Event] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var out: [Event] = []
        for n in names.sorted() where n.hasSuffix(".json") {
            let p = dir + "/" + n
            if let d = FileManager.default.contents(atPath: p), let e = try? dec.decode(Event.self, from: d) { out.append(e) }
            try? FileManager.default.removeItem(atPath: p)
        }
        return out
    }

    /// guard 啟動時建目錄（1777：任何人可寫、只能刪自己的）
    public static func prepareDir() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o1777)
    }
}
