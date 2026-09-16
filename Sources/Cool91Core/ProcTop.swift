import Foundation
import CSMC

/// 「現在誰在算」：用 libproc 差分每個 process 的累計 CPU 時間，不需 root、每輪幾毫秒。
/// 比 ps 的 %CPU 準（ps 是衰減平均），比 powermetrics tasks 便宜 10 倍以上
public struct TopProcess: Codable, Equatable {
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double      // 100 = 一顆核心滿載
    public var command: String         // 精簡過的命令列
    public var cwd: String?            // 工作目錄最後一段
    public init(pid: Int32, name: String, cpuPercent: Double, command: String, cwd: String?) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent; self.command = command; self.cwd = cwd
    }
}

public final class ProcTop {
    private var last: [pid_t: UInt64] = [:]
    private var lastTime: Date? = nil
    public init() {}

    /// 取 CPU 前 N 名（至少 minPercent）。第一次呼叫沒有基準，回空
    public func sample(top n: Int = 3, minPercent: Double = 20) -> [TopProcess] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(cp_list_pids(&pids, Int32(pids.count)))
        guard count > 0 else { return [] }
        var now: [pid_t: UInt64] = [:]
        for pid in pids.prefix(count) where pid > 0 {
            var ns: UInt64 = 0
            if cp_task_cpu_ns(pid, &ns) == 0 { now[pid] = ns }
        }
        defer { last = now; lastTime = Date() }
        guard let t0 = lastTime else { return [] }
        let dt = Date().timeIntervalSince(t0)
        guard dt > 0.5 else { return [] }
        var rows: [(pid_t, Double)] = []
        for (pid, ns) in now {
            guard let prev = last[pid], ns >= prev else { continue }
            let pct = Double(ns - prev) / 1e9 / dt * 100
            if pct >= minPercent { rows.append((pid, pct)) }
        }
        rows.sort { $0.1 > $1.1 }
        return rows.prefix(n).map { pid, pct in
            var buf = [CChar](repeating: 0, count: 4096)
            let name = cp_name(pid, &buf, Int32(buf.count)) == 0 ? String(cString: buf) : "?"
            let args = cp_args(pid, &buf, Int32(buf.count)) == 0 ? String(cString: buf) : name
            let cwd = cp_cwd(pid, &buf, Int32(buf.count)) == 0 ? String(cString: buf) : nil
            return TopProcess(pid: pid, name: name, cpuPercent: pct, command: ProcTop.shorten(args, name: name),
                              cwd: cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 })
        }
    }

    /// 把命令列縮成人看得懂的一行：去掉直譯器長路徑、只留 -m 模組 / 腳本名 / 前幾個參數
    public static func shorten(_ args: String, name: String) -> String {
        var tokens = args.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return name }
        tokens[0] = (tokens[0] as NSString).lastPathComponent
        // 直譯器：python -u -m pkg.mod --x → python -m pkg.mod --x
        if tokens[0].lowercased().hasPrefix("python") {
            tokens = [tokens[0]] + tokens.dropFirst().filter { !($0.hasPrefix("-") && $0.count <= 2 && $0 != "-m") }
        }
        var s = tokens.prefix(6).map { ($0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0) }.joined(separator: " ")
        if s.count > 70 { s = String(s.prefix(69)) + "…" }
        return s
    }
}
