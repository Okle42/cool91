import Foundation

/// 一次取樣的結果；也是 guard 寫到 state 檔的內容
public struct Snapshot: Codable {
    public var time: Date
    public var cpuMax: Double
    public var cpuAvg: Double
    public var gpuMax: Double
    public var ssd: Double?
    public var fans: [FanState]
    public var level: Level
    public var guardRunning: Bool
    public var guardTargetRPM: Double?
    public var guardMode: String? = nil

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

    public static let statePath = "/tmp/cool91.json"

    /// 直接從 SMC 取樣（讀取不需 root）。keys 先掃描一次後快取，避免每次列舉 1375 個 key
    public static var cachedCPUKeys: [String] = []
    public static var cachedGPUKeys: [String] = []

    public static func take(config: Config) -> Snapshot {
        if cachedCPUKeys.isEmpty {
            let all = SMC.scanTemperatureKeys().map { $0.0 }
            cachedCPUKeys = all.filter { k in config.cpuPrefixes.contains { k.hasPrefix($0) } }
            cachedGPUKeys = all.filter { k in config.gpuPrefixes.contains { k.hasPrefix($0) } }
        }
        let cpu = cachedCPUKeys.compactMap(SMC.readDouble)
        let gpu = cachedGPUKeys.compactMap(SMC.readDouble)
        let cpuMax = cpu.max() ?? 0
        let fans = SMC.fans().map {
            FanState(index: $0.index, rpm: $0.actual, target: $0.target, min: $0.min, max: $0.max, manual: $0.manual)
        }
        // 若 guard 有在跑，補上它的資訊
        let saved = load()
        let alive = saved.map { Date().timeIntervalSince($0.time) < config.interval * 3 && $0.guardRunning } ?? false
        var snap = Snapshot(time: Date(),
                        cpuMax: cpuMax,
                        cpuAvg: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count),
                        gpuMax: gpu.max() ?? 0,
                        ssd: SMC.readDouble("TH0x"),
                        fans: fans,
                        level: config.level(for: cpuMax),
                        guardRunning: alive,
                        guardTargetRPM: alive ? saved?.guardTargetRPM : nil)
        snap.guardMode = alive ? saved?.guardMode : nil
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
        let tmp = Snapshot.statePath + ".tmp"
        try? d.write(to: URL(fileURLWithPath: tmp))
        chmod(tmp, 0o644)
        rename(tmp, Snapshot.statePath)
    }

    public var json: String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    public var short: String {
        let fan = fans.first.map { String(format: "%.0f", $0.rpm) } ?? "-"
        return String(format: "%@ %.0f°C 🌀%@rpm", level.emoji, cpuMax, fan)
    }

    public var pretty: String {
        var s = "\(level.emoji) 等級: \(level.rawValue)\n"
        s += String(format: "CPU  最高 %.1f°C  平均 %.1f°C\n", cpuMax, cpuAvg)
        s += String(format: "GPU  最高 %.1f°C\n", gpuMax)
        if let ssd { s += String(format: "SSD  %.1f°C\n", ssd) }
        for f in fans {
            s += String(format: "風扇%d  %.0f rpm  目標 %.0f  範圍 %.0f–%.0f  %@\n",
                        f.index, f.rpm, f.target, f.min, f.max, f.manual ? "手動" : "自動")
        }
        s += guardRunning ? String(format: "guard 執行中（%@），目標 %@", guardMode ?? "curve", guardTargetRPM.map { String(format: "%.0f rpm", $0) } ?? "auto") : "guard 未執行（風扇由 SMC 或其他程式控制）"
        return s
    }
}
