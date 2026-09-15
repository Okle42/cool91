import Foundation

/// 把關與指令判斷的純邏輯（不碰 SMC、不碰檔案），hook / check / wait / 測試共用
public enum Policy {

    /// 能不能開工。依據：有 thermal pressure（guard 以 root 從 powermetrics 讀到）就看它 —— 溫度高但沒降頻是風扇的事，不該讓工作等；
    /// 拿不到才退回溫度門檻。critical 溫度不管 pressure 都算（安全底線）
    ///   wait  = 現在不該開工（降頻中 / hot）
    ///   block = 嚴重到該擋下（Trapping / critical）
    public static func verdict(_ s: Snapshot, config: Config) -> (wait: Bool, block: Bool) {
        if s.level == .critical { return (true, config.hookBlockOnCritical) }
        if let pr = s.thermalPressure {
            switch pr {
            case "Nominal": return (false, false)
            case "Trapping", "Sleeping": return (true, config.hookBlockOnCritical)
            default: return (true, false)   // Moderate / Heavy：等它回 Nominal
            }
        }
        return (s.level >= .hot, false)
    }

    /// 把 shell 指令依 ; && || | 換行 切段，每段去掉 sudo/env/exec/time/nice/VAR=x 前綴後回傳 token 陣列（第一個 token 已取檔名）
    static func segments(_ command: String) -> [[String]] {
        command
            .replacingOccurrences(of: "&&", with: "\n")
            .replacingOccurrences(of: "||", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: ";|\n"))
            .compactMap { seg in
                var tokens = seg.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                while let t = tokens.first,
                      ["sudo", "env", "exec", "time", "nice"].contains(t) || t.hasPrefix("-") || (t.contains("=") && !t.hasPrefix("-")) {
                    tokens.removeFirst()
                }
                guard !tokens.isEmpty else { return nil }
                tokens[0] = (tokens[0] as NSString).lastPathComponent
                return tokens
            }
    }

    /// 指令是否全部落在白名單（降溫、查狀態用的指令在 critical 也要能跑）
    public static func commandIsAllowed(_ command: String, allow: [String]) -> Bool {
        let segs = segments(command)
        guard !segs.isEmpty else { return false }
        return segs.allSatisfy { allow.contains($0[0]) }
    }

    /// 指令是否看起來是重工作（要預熱）。只看每段指令的開頭，不掃整段文字 —— 否則 heredoc 或字串裡提到 "swift build" 也會觸發
    public static func commandNeedsBoost(_ command: String, keywords: [String]) -> Bool {
        segments(command).contains { tokens in
            let head = tokens.prefix(3).joined(separator: " ").lowercased() + " "
            return keywords.contains { head.hasPrefix($0.lowercased()) }
        }
    }
}

/// 顯示用的小工具
public enum Format {
    /// 秒數 → 12s / 3m05s / 1h02m
    public static func hms(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm%02ds", s / 60, s % 60) }
        return String(format: "%dh%02dm", s / 3600, s % 3600 / 60)
    }
}
