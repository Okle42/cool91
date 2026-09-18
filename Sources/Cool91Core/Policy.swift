import Foundation

/// 把關與指令判斷的純邏輯（不碰 SMC、不碰檔案），hook / check / wait / 測試共用
public enum Policy {

    /// 能不能開工。依據：有 thermal pressure（guard 以 root 從 powermetrics 讀到）就看它 —— 溫度高但沒降頻是風扇的事，不該讓工作等；
    /// 拿不到才退回溫度門檻。critical 溫度不管 pressure 都算（安全底線）
    ///   wait  = 現在不該開工（降頻中 / hot）
    ///   block = 嚴重到該擋下（Trapping / critical）
    public static func verdict(_ s: Snapshot, config: Config) -> (wait: Bool, block: Bool) {
        if s.level == .critical { return (true, config.hookBlockOnCritical) }
        if s.gpuThrottling { return (true, false) }   // GPU 被熱管理壓檔位，跟 CPU Moderate 同等看待
        if let pr = s.thermalPressure {
            switch pr {
            case "Nominal": return (false, false)
            case "Trapping", "Sleeping": return (true, config.hookBlockOnCritical)
            default: return (true, false)   // Moderate / Heavy：等它回 Nominal
            }
        }
        return (s.level >= .hot, false)
    }

    /// 把 shell 指令切段：先剝掉 heredoc 主體（`<<TAG` 到 `TAG` 行之間是資料不是指令），再在引號外的 ; | & 換行 處切，
    /// 每段去掉 sudo/env/exec/time/nice/VAR=x 前綴後回傳 token 陣列（第一個 token 已取檔名）。
    /// 引號內的 | ; 不切 —— 否則 `sed 's|x|swift build|'`、`grep -E "pytest|make "` 會被當成真的要跑 swift build
    static func segments(_ command: String) -> [[String]] {
        stripHeredocs(command).flatMap(splitOutsideQuotes).compactMap { seg in
            var tokens = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            while let t = tokens.first,
                  ["sudo", "env", "exec", "time", "nice"].contains(t) || t.hasPrefix("-") || (t.contains("=") && !t.hasPrefix("-")) {
                tokens.removeFirst()
            }
            guard !tokens.isEmpty else { return nil }
            tokens[0] = (tokens[0] as NSString).lastPathComponent
            return tokens
        }
    }

    private static let heredocTag = try! NSRegularExpression(pattern: "(?<!<)<<(?!<)-?\\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")   // <<< 是 here-string 不是 heredoc

    /// 逐行掃：遇到 `<<TAG` 就把接下來到 `TAG` 那行為止全部丟掉（那是餵給指令的資料）；回傳剩下的指令行
    static func stripHeredocs(_ command: String) -> [String] {
        var out: [String] = []
        var endTag: String? = nil
        for line in command.components(separatedBy: "\n") {
            if let tag = endTag {
                if line.trimmingCharacters(in: .whitespaces) == tag { endTag = nil }
                continue
            }
            out.append(line)
            let ns = line as NSString
            if let m = heredocTag.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                endTag = ns.substring(with: m.range(at: 1))
            }
        }
        return out
    }

    /// 在單引號 / 雙引號外面的 ; | & 處切段（&& || 也落在這裡；反斜線跳脫的下一個字元照抄）
    static func splitOutsideQuotes(_ line: String) -> [String] {
        var segs: [String] = []
        var cur = ""
        var quote: Character? = nil
        var escaped = false
        for ch in line {
            if escaped { cur.append(ch); escaped = false; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true }
                cur.append(ch); continue
            }
            switch ch {
            case "'", "\"": quote = ch; cur.append(ch)
            case "\\": escaped = true
            case ";", "|", "&": segs.append(cur); cur = ""
            default: cur.append(ch)
            }
        }
        segs.append(cur)
        return segs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 指令是否全部落在白名單（降溫、查狀態用的指令在 critical 也要能跑）
    public static func commandIsAllowed(_ command: String, allow: [String]) -> Bool {
        let segs = segments(command)
        guard !segs.isEmpty else { return false }
        return segs.allSatisfy { allow.contains($0[0]) }
    }

    /// 指令是否看起來是重工作（要預熱）。只看每段指令的開頭三個 token，不掃整段文字、不看 heredoc 內容與引號裡的字
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
