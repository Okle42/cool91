import Foundation

/// 一次取樣的結果；也是 guard 寫到 state 檔的內容
struct Snapshot: Codable {
    var time: Date
    var cpuMax: Double
    var cpuAvg: Double
    var gpuMax: Double
    var ssd: Double?
    var fans: [FanState]
    var level: Level
    var guardRunning: Bool
    var guardTargetRPM: Double?

    struct FanState: Codable {
        var index: Int
        var rpm: Double
        var target: Double
        var min: Double
        var max: Double
        var manual: Bool
    }

    static let statePath = "/tmp/cool91.json"

    /// 直接從 SMC 取樣（讀取不需 root）。keys 先掃描一次後快取，避免每次列舉 1375 個 key
    static var cachedCPUKeys: [String] = []
    static var cachedGPUKeys: [String] = []

    static func take(config: Config) -> Snapshot {
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
        return Snapshot(time: Date(),
                        cpuMax: cpuMax,
                        cpuAvg: cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count),
                        gpuMax: gpu.max() ?? 0,
                        ssd: SMC.readDouble("TH0x"),
                        fans: fans,
                        level: config.level(for: cpuMax),
                        guardRunning: alive,
                        guardTargetRPM: alive ? saved?.guardTargetRPM : nil)
    }

    /// guard 在跑且 state 夠新就直接用，省掉開 SMC 的成本（hook 每次 Bash 前都會呼叫）
    static func takeFast(config: Config) -> Snapshot {
        if let saved = load(), saved.guardRunning, Date().timeIntervalSince(saved.time) < config.interval * 2 {
            return saved
        }
        return take(config: config)
    }

    static func load() -> Snapshot? {
        guard let d = FileManager.default.contents(atPath: statePath) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Snapshot.self, from: d)
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        let tmp = Snapshot.statePath + ".tmp"
        try? d.write(to: URL(fileURLWithPath: tmp))
        chmod(tmp, 0o644)
        rename(tmp, Snapshot.statePath)
    }

    var json: String {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    var short: String {
        let fan = fans.first.map { String(format: "%.0f", $0.rpm) } ?? "-"
        return String(format: "%@ %.0f°C 🌀%@rpm", level.emoji, cpuMax, fan)
    }

    var pretty: String {
        var s = "\(level.emoji) 等級: \(level.rawValue)\n"
        s += String(format: "CPU  最高 %.1f°C  平均 %.1f°C\n", cpuMax, cpuAvg)
        s += String(format: "GPU  最高 %.1f°C\n", gpuMax)
        if let ssd { s += String(format: "SSD  %.1f°C\n", ssd) }
        for f in fans {
            s += String(format: "風扇%d  %.0f rpm  目標 %.0f  範圍 %.0f–%.0f  %@\n",
                        f.index, f.rpm, f.target, f.min, f.max, f.manual ? "手動" : "自動")
        }
        s += guardRunning ? String(format: "guard 執行中，目標 %.0f rpm", guardTargetRPM ?? 0) : "guard 未執行（風扇由 SMC 或其他程式控制）"
        return s
    }
}
