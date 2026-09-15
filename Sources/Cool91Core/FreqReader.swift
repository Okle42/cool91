import Foundation

/// 以 root 常駐一個 `powermetrics -i N -n 0` 子行程，持續解析 P/E-cluster 硬體頻率與 thermal pressure。
/// 為什麼不用 IOReport：M4 上 IOReport 的 CPU 通道（Core/Complex Performance States、Voltage States、Core Performance Level）
/// 全是軟體請求的 DVFS 檔位，重載時永遠停在最高檔；硬體實際頻率（功率/熱限制後）只有 powermetrics 的計數器讀得到。
/// 成本實測：初始化 0.8 秒 CPU 一次，之後每 5 秒一筆約 0.18%。
public final class FreqReader {
    public private(set) var pcoreMHz: Double? = nil
    public private(set) var ecoreMHz: Double? = nil
    public private(set) var pressure: String? = nil
    public private(set) var lastUpdate: Date? = nil
    /// 最近一次啟動失敗或子行程退出的原因（給 guard log）
    public private(set) var lastError: String? = nil
    private var process: Process? = nil
    private var buffer = ""
    private let interval: Double
    private var lastStart: Date? = nil
    private let queue = DispatchQueue(label: "cool91.freq")

    public static let path = "/usr/bin/powermetrics"
    public static var available: Bool { getuid() == 0 && FileManager.default.isExecutableFile(atPath: path) }

    public init(interval: Double) { self.interval = max(1, interval) }

    /// 啟動（或子行程死了就重啟，最快 30 秒一次）
    public func ensureRunning() {
        if let p = process, p.isRunning { return }
        if let l = lastStart, Date().timeIntervalSince(l) < 30 { return }
        guard FreqReader.available else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FreqReader.path)
        p.arguments = ["--samplers", "cpu_power,thermal", "-i", String(Int(interval * 1000))]   // 不帶 -n = 無限取樣（-n 0 會在第一筆後退出）
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.queue.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.lastError = "powermetrics 退出 status=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue)" }
        }
        do { try p.run(); process = p; lastStart = Date(); lastError = nil } catch { process = nil; lastError = "powermetrics 啟動失敗：\(error)" }
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    private func consume(_ chunk: String) {
        buffer += chunk
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()   // 最後一段可能不完整
        let (p, e, pr) = FreqReader.parse(lines: lines)
        if p != nil || e != nil || pr != nil {
            DispatchQueue.main.async {
                if let p { self.pcoreMHz = p }
                if let e, e > 0 { self.ecoreMHz = e }   // E-cluster 閒置時回 0，保留上一筆
                if let pr { self.pressure = pr }
                self.lastUpdate = Date()
            }
        }
    }

    /// 從 powermetrics 文字輸出抓 P/E-cluster 頻率與 pressure（每個都取最後一次出現的值）
    public static func parse(lines: [String]) -> (p: Double?, e: Double?, pressure: String?) {
        var p: Double? = nil, e: Double? = nil, pr: String? = nil
        for line in lines {
            if let v = value(after: "P-Cluster HW active frequency:", in: line) { p = v }
            else if let v = value(after: "E-Cluster HW active frequency:", in: line) { e = v }
            else if let r = line.range(of: "Current pressure level:") {
                pr = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return (p, e, pr)
    }

    private static func value(after key: String, in line: String) -> Double? {
        guard let r = line.range(of: key) else { return nil }
        return Double(line[r.upperBound...].replacingOccurrences(of: "MHz", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// 超過 3 個取樣週期沒更新就視為失效（子行程卡住）
    public var fresh: Bool { lastUpdate.map { Date().timeIntervalSince($0) < interval * 3 } ?? false }
}
