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
        .init(temp: 60, rpm: 1000),
        .init(temp: 75, rpm: 1800),
        .init(temp: 85, rpm: 2600),
        .init(temp: 92, rpm: 3600),
        .init(temp: 97, rpm: 4900),
    ]
    /// 控制模式：curve 依曲線、auto 交還 SMC、fixed 固定轉速
    public var mode: String = "curve"
    public var fixedRPM: Double = 3000
    /// 輪詢間隔（秒）。5 秒 ≈ 每次讀 ~40 個 SMC key，負載可忽略
    public var interval: Double = 5
    /// 目標轉速差距小於此值就不寫 SMC，避免抖動
    public var deadband: Double = 100
    /// 溫度 EMA 係數，升溫與降溫分開：升溫反應快、降溫慢慢放，風扇不會忽高忽低
    public var smoothingUp: Double = 0.7
    public var smoothingDown: Double = 0.2
    /// 每輪最多降多少 rpm（0 = 不限制）。升速不限制
    public var maxRampDown: Double = 300
    /// 控制與把關是否把 GPU 溫度也算進去（取 CPU/GPU 最高值）
    public var includeGPU: Bool = true
    /// 把關門檻（以控制溫度為準）
    public var warmTemp: Double = 80
    public var hotTemp: Double = 90
    public var criticalTemp: Double = 100
    /// hook 在 hot 時最多等待幾秒降溫（程式內再夾在 hookWaitCap 以下，避免超過 Claude Code 的 hook timeout）
    public var hookWaitSeconds: Double = 90
    public static let hookWaitCap: Double = 120
    /// hook 在 critical 時是否直接擋下工具呼叫
    public var hookBlockOnCritical: Bool = true
    /// critical 時仍放行的指令（降溫、查狀態用）。比對每段指令的第一個 token 的檔名
    public var hookAllowCommands: [String] = ["cool91", "kill", "pkill", "killall", "pgrep", "ps", "top", "sleep", "cat", "tail", "echo", "launchctl"]
    /// 預熱：Bash 指令含這些關鍵字時，先把風扇拉到 boostRPM 撐 boostSeconds 秒（之後仍由曲線接管，取較大者）
    public var boostCommands: [String] = ["swift build", "xcodebuild", "cmake", "ninja", "cargo build", "cargo test", "blender", "ffmpeg", "clang", "gcc", "rustc", "go build", "npm run build", "pytest", "make "]
    public var boostRPM: Double = 3000
    public var boostSeconds: Double = 120
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
        case curve, mode, fixedRPM, interval, deadband, smoothingUp, smoothingDown, maxRampDown, includeGPU,
             warmTemp, hotTemp, criticalTemp, hookWaitSeconds, hookBlockOnCritical, hookAllowCommands,
             boostCommands, boostRPM, boostSeconds, cpuPrefixes, gpuPrefixes
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        curve = try c.decodeIfPresent([Point].self, forKey: .curve) ?? curve
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        fixedRPM = try c.decodeIfPresent(Double.self, forKey: .fixedRPM) ?? fixedRPM
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? interval
        deadband = try c.decodeIfPresent(Double.self, forKey: .deadband) ?? deadband
        smoothingUp = try c.decodeIfPresent(Double.self, forKey: .smoothingUp) ?? smoothingUp
        smoothingDown = try c.decodeIfPresent(Double.self, forKey: .smoothingDown) ?? smoothingDown
        maxRampDown = try c.decodeIfPresent(Double.self, forKey: .maxRampDown) ?? maxRampDown
        includeGPU = try c.decodeIfPresent(Bool.self, forKey: .includeGPU) ?? includeGPU
        warmTemp = try c.decodeIfPresent(Double.self, forKey: .warmTemp) ?? warmTemp
        hotTemp = try c.decodeIfPresent(Double.self, forKey: .hotTemp) ?? hotTemp
        criticalTemp = try c.decodeIfPresent(Double.self, forKey: .criticalTemp) ?? criticalTemp
        hookWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .hookWaitSeconds) ?? hookWaitSeconds
        hookBlockOnCritical = try c.decodeIfPresent(Bool.self, forKey: .hookBlockOnCritical) ?? hookBlockOnCritical
        hookAllowCommands = try c.decodeIfPresent([String].self, forKey: .hookAllowCommands) ?? hookAllowCommands
        boostCommands = try c.decodeIfPresent([String].self, forKey: .boostCommands) ?? boostCommands
        boostRPM = try c.decodeIfPresent(Double.self, forKey: .boostRPM) ?? boostRPM
        boostSeconds = try c.decodeIfPresent(Double.self, forKey: .boostSeconds) ?? boostSeconds
        cpuPrefixes = try c.decodeIfPresent([String].self, forKey: .cpuPrefixes) ?? cpuPrefixes
        gpuPrefixes = try c.decodeIfPresent([String].self, forKey: .gpuPrefixes) ?? gpuPrefixes
        try validate()
    }

    /// 基本合理性檢查；不合理的設定寧可拒絕載入（guard 會保留上一份）
    public func validate() throws {
        guard ["curve", "fixed", "auto"].contains(mode) else { throw Cool91Error.usage("mode 必須是 curve/fixed/auto，收到 \(mode)") }
        guard !curve.isEmpty else { throw Cool91Error.usage("curve 不能是空的") }
        guard interval >= 1 else { throw Cool91Error.usage("interval 至少 1 秒") }
        guard (0...1).contains(smoothingUp), (0...1).contains(smoothingDown) else { throw Cool91Error.usage("smoothingUp/Down 必須在 0–1") }
        guard warmTemp < hotTemp, hotTemp < criticalTemp else { throw Cool91Error.usage("門檻必須 warm < hot < critical") }
    }

    /// 讀取指定/預設路徑；全部失敗回預設值。要區分「檔案壞了」和「沒有檔案」請用 loadOrError
    public static func load(path: String?) -> Config {
        (try? loadOrError(path: path)) ?? Config()
    }

    /// 明確回報解析錯誤（guard 熱重載用：壞掉時保留舊設定）
    public static func loadOrError(path: String?) throws -> Config {
        let candidates = path.map { [$0] } ?? defaultPaths
        var lastError: Error? = nil
        for p in candidates {
            guard let d = FileManager.default.contents(atPath: p) else { continue }
            do {
                var c = try JSONDecoder().decode(Config.self, from: d)
                c.loadedFrom = p
                return c
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        return Config()
    }

    /// 檔案修改時間（guard 用來偵測是否要重新載入）
    public static func mtime(_ path: String?) -> Date? {
        guard let path else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// 寫回檔案（面板用）；預設寫到載入來源，沒有就寫 ~/.config/cool91/config.json
    /// /etc/cool91 目錄是 root 的，無法用 .atomic（要在同目錄建暫存檔），所以直接覆寫；guard 那端讀到半截會保留舊設定重試
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
