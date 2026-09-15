import Foundation

/// guard 迴圈與把關門檻設定（JSON），找不到檔案就用預設值
struct Config: Codable {
    /// 風扇曲線：溫度(°C) → 轉速(rpm)，之間線性插值
    struct Point: Codable { var temp: Double; var rpm: Double }
    var curve: [Point] = [
        .init(temp: 55, rpm: 1000),
        .init(temp: 65, rpm: 1800),
        .init(temp: 75, rpm: 3000),
        .init(temp: 85, rpm: 4200),
        .init(temp: 90, rpm: 4900),
    ]
    /// 輪詢間隔（秒）。5 秒 ≈ 每次讀 ~40 個 SMC key，負載可忽略
    var interval: Double = 5
    /// 目標轉速差距小於此值就不寫 SMC，避免抖動
    var deadband: Double = 100
    /// 溫度 EMA 係數（0–1，越小越平滑；1 = 不平滑）
    var smoothing: Double = 0.5
    /// 把關門檻（以 CPU 最高溫為準）
    var warmTemp: Double = 80
    var hotTemp: Double = 90
    var criticalTemp: Double = 100
    /// hook 在 hot 時最多等待幾秒降溫
    var hookWaitSeconds: Double = 90
    /// hook 在 critical 時是否直接擋下工具呼叫
    var hookBlockOnCritical: Bool = true
    /// 溫度取樣來源前綴：Tp = P-core、Te = E-core、Tg = GPU
    var cpuPrefixes: [String] = ["Tp", "Te"]
    var gpuPrefixes: [String] = ["Tg"]

    static let defaultPaths = [
        "/etc/cool91/config.json",
        NSString(string: "~/.config/cool91/config.json").expandingTildeInPath,
    ]

    static func load(path: String?) -> Config {
        let candidates = path.map { [$0] } ?? defaultPaths
        for p in candidates {
            if let d = FileManager.default.contents(atPath: p),
               let c = try? JSONDecoder().decode(Config.self, from: d) {
                return c
            }
        }
        return Config()
    }

    func rpm(for temp: Double) -> Double {
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

    func level(for temp: Double) -> Level {
        if temp >= criticalTemp { return .critical }
        if temp >= hotTemp { return .hot }
        if temp >= warmTemp { return .warm }
        return .ok
    }
}

enum Level: String, Codable, Comparable {
    case ok, warm, hot, critical
    private var rank: Int { [Level.ok, .warm, .hot, .critical].firstIndex(of: self)! }
    static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    var emoji: String {
        switch self {
        case .ok: return "🟢"
        case .warm: return "🟡"
        case .hot: return "🟠"
        case .critical: return "🔴"
        }
    }
}
