import Foundation

/// guard 迴圈與把關門檻設定（JSON），找不到檔案就用預設值
public struct Config: Codable {
    public init() {}
    /// 風扇曲線：溫度(°C) → 轉速(rpm)，之間線性插值
    public struct Point: Codable {
        public var temp: Double; public var rpm: Double
        public init(temp: Double, rpm: Double) { self.temp = temp; self.rpm = rpm }
    }
    public var curve: [Point] = [
        .init(temp: 55, rpm: 1000),
        .init(temp: 65, rpm: 1800),
        .init(temp: 75, rpm: 3000),
        .init(temp: 85, rpm: 4200),
        .init(temp: 90, rpm: 4900),
    ]
    /// 控制模式：curve 依曲線、auto 交還 SMC、fixed 固定轉速
    public var mode: String = "curve"
    public var fixedRPM: Double = 3000
    /// 輪詢間隔（秒）。5 秒 ≈ 每次讀 ~40 個 SMC key，負載可忽略
    public var interval: Double = 5
    /// 目標轉速差距小於此值就不寫 SMC，避免抖動
    public var deadband: Double = 100
    /// 溫度 EMA 係數（0–1，越小越平滑；1 = 不平滑）
    public var smoothing: Double = 0.5
    /// 把關門檻（以 CPU 最高溫為準）
    public var warmTemp: Double = 80
    public var hotTemp: Double = 90
    public var criticalTemp: Double = 100
    /// hook 在 hot 時最多等待幾秒降溫
    public var hookWaitSeconds: Double = 90
    /// hook 在 critical 時是否直接擋下工具呼叫
    public var hookBlockOnCritical: Bool = true
    /// 溫度取樣來源前綴：Tp = P-core、Te = E-core、Tg = GPU
    public var cpuPrefixes: [String] = ["Tp", "Te"]
    public var gpuPrefixes: [String] = ["Tg"]

    public static let defaultPaths = [
        "/etc/cool91/config.json",
        NSString(string: "~/.config/cool91/config.json").expandingTildeInPath,
    ]

    /// 實際載入的檔案路徑（nil = 用預設值）
    public private(set) var loadedFrom: String? = nil

    enum CodingKeys: String, CodingKey {
        case curve, mode, fixedRPM, interval, deadband, smoothing, warmTemp, hotTemp, criticalTemp,
             hookWaitSeconds, hookBlockOnCritical, cpuPrefixes, gpuPrefixes
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        curve = try c.decodeIfPresent([Point].self, forKey: .curve) ?? curve
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        fixedRPM = try c.decodeIfPresent(Double.self, forKey: .fixedRPM) ?? fixedRPM
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? interval
        deadband = try c.decodeIfPresent(Double.self, forKey: .deadband) ?? deadband
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        warmTemp = try c.decodeIfPresent(Double.self, forKey: .warmTemp) ?? warmTemp
        hotTemp = try c.decodeIfPresent(Double.self, forKey: .hotTemp) ?? hotTemp
        criticalTemp = try c.decodeIfPresent(Double.self, forKey: .criticalTemp) ?? criticalTemp
        hookWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .hookWaitSeconds) ?? hookWaitSeconds
        hookBlockOnCritical = try c.decodeIfPresent(Bool.self, forKey: .hookBlockOnCritical) ?? hookBlockOnCritical
        cpuPrefixes = try c.decodeIfPresent([String].self, forKey: .cpuPrefixes) ?? cpuPrefixes
        gpuPrefixes = try c.decodeIfPresent([String].self, forKey: .gpuPrefixes) ?? gpuPrefixes
    }

    public static func load(path: String?) -> Config {
        let candidates = path.map { [$0] } ?? defaultPaths
        for p in candidates {
            if let d = FileManager.default.contents(atPath: p),
               var c = try? JSONDecoder().decode(Config.self, from: d) {
                c.loadedFrom = p
                return c
            }
        }
        return Config()
    }

    /// 檔案修改時間（guard 用來偵測是否要重新載入）
    public static func mtime(_ path: String?) -> Date? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// 寫回檔案（面板用）；預設寫到載入來源，沒有就寫 ~/.config/cool91/config.json
    public func save(to path: String? = nil) throws {
        let target = path ?? loadedFrom ?? Config.defaultPaths[1]
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: target))
    }

    public func rpm(for temp: Double) -> Double {
        let pts = curve.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if temp <= first.temp { return first.rpm }
        if temp >= last.temp { return last.rpm }
        for i in 1..<pts.count where temp <= pts[i].temp {
            let a = pts[i - 1], b = pts[i]
            let t = (temp - a.temp) / (b.temp - a.temp)
            return a.rpm + (b.rpm - a.rpm) * t
        }
        return last.rpm
    }

    public func level(for temp: Double) -> Level {
        if temp >= criticalTemp { return .critical }
        if temp >= hotTemp { return .hot }
        if temp >= warmTemp { return .warm }
        return .ok
    }
}

public enum Level: String, Codable, Comparable {
    case ok, warm, hot, critical
    private var rank: Int { [Level.ok, .warm, .hot, .critical].firstIndex(of: self)! }
    public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    public var emoji: String {
        switch self {
        case .ok: return "🟢"
        case .warm: return "🟡"
        case .hot: return "🟠"
        case .critical: return "🔴"
        }
    }
}
