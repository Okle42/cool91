import Foundation
import Cool91Core

// cool91 — Apple Silicon 風扇/溫度守門員，給 Claude Code 當把關工具用
// 子命令：status | sensors | fan | guard | check | wait | hook | chip | doctor

let args = Array(CommandLine.arguments.dropFirst())

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

func usage() -> Never {
    print("""
    cool91 <命令> [選項]

      status [--json|--short]      目前溫度、風扇、把關等級、今日統計
      sensors                      列出所有溫度感測器 key（移植新晶片時用）
      chip                         顯示晶片型號與偵測到的感測器分組
      fan auto | fan <rpm> [--fan N]   手動設風扇（需 sudo）
      guard [--interval S] [--config PATH] [--dry-run]
                                   常駐控制迴圈，依曲線調風扇（需 sudo）
      check [--json]               把關檢查：exit 0=ok/warm, 1=hot, 2=critical
      wait [--below TEMP] [--timeout S]   等待控制溫度降到門檻以下
      hook                         Claude Code PreToolUse hook 入口（讀 stdin，輸出決策 JSON）
      doctor                       檢查 guard / 快照 / hook / 設定檔 / 衝突程式是否都正常

    設定檔：/etc/cool91/config.json 或 ~/.config/cool91/config.json
    """)
    exit(64)
}

func chipName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}

func pgrep(_ pattern: String, exact: Bool = false) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = exact ? ["-x", pattern] : ["-f", pattern]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

func macsFanControlRunning() -> Bool { pgrep("Macs Fan Control.app/Contents/MacOS") }

func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

guard let cmd = args.first else { usage() }
let config = Config.load(path: opt("--config"))

do {
    try SMC.open()
    defer { SMC.close() }

    switch cmd {
    case "status":
        let s = Snapshot.take(config: config)
        if flag("--json") { print(s.json) } else if flag("--short") { print(s.short) } else { print(s.pretty) }

    case "sensors":
        for (k, v) in SMC.scanTemperatureKeys() { print(k, String(format: "%6.1f", v)) }

    case "chip":
        print("晶片:", chipName())
        let s = Snapshot.take(config: config)
        print("CPU 感測器 (\(Snapshot.cachedCPUKeys.count)):", Snapshot.cachedCPUKeys.joined(separator: " "))
        print("GPU 感測器 (\(Snapshot.cachedGPUKeys.count)):", Snapshot.cachedGPUKeys.joined(separator: " "))
        print("風扇數:", SMC.fanCount)
        print(s.short)

    case "fan":
        guard args.count >= 2 else { usage() }
        let i = Int(opt("--fan") ?? "0") ?? 0
        if args[1] == "auto" {
            try SMC.setFanAuto(i)
            print("風扇\(i) 已交還自動控制")
        } else if let rpm = Double(args[1]) {
            try SMC.setFan(i, rpm: rpm)
            print("風扇\(i) 目標 \(Int(rpm)) rpm")
        } else { usage() }

    case "guard":
        try runGuard(config: config, dryRun: flag("--dry-run"), interval: Double(opt("--interval") ?? "") ?? config.interval)

    case "check":
        let s = Snapshot.takeFast(config: config)
        if flag("--json") { print(s.json) } else { print(s.short) }
        switch s.level {
        case .ok, .warm: exit(0)
        case .hot: exit(1)
        case .critical: exit(2)
        }

    case "wait":
        let below = Double(opt("--below") ?? "") ?? config.hotTemp
        let timeout = Double(opt("--timeout") ?? "") ?? config.hookWaitSeconds
        let ok = waitUntilCool(below: below, timeout: timeout, config: config) { s in
            stderr("\(s.short)  等待降到 \(Int(below))°C 以下…")
        }
        exit(ok ? 0 : 1)

    case "hook":
        runHook(config: config)

    case "doctor":
        exit(runDoctor(config: config) ? 0 : 1)

    default:
        usage()
    }
} catch {
    stderr("cool91: \(error)")
    exit(1)
}

// MARK: - 共用

/// 每 2 秒取樣直到 controlTemp < below 或逾時。guard 在跑時走快照檔，不開 SMC
func waitUntilCool(below: Double, timeout: Double, config: Config, progress: (Snapshot) -> Void) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let s = Snapshot.takeFast(config: config)
        if s.controlTemp < below { return true }
        if Date() >= deadline { return false }
        progress(s)
        Thread.sleep(forTimeInterval: 2)
    }
}

// MARK: - hook

/// 指令是否全部落在白名單（降溫、查狀態用的指令在 critical 也要能跑）。
/// 依 ; && || | 換行 切段，跳過 sudo/env/VAR=x，比對第一個 token 的檔名
func commandIsAllowed(_ command: String, allow: [String]) -> Bool {
    let segments = command
        .replacingOccurrences(of: "&&", with: "\n")
        .replacingOccurrences(of: "||", with: "\n")
        .components(separatedBy: CharacterSet(charactersIn: ";|\n"))
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !segments.isEmpty else { return false }
    for seg in segments {
        var tokens = seg.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let t = tokens.first, t == "sudo" || t == "env" || t == "exec" || t.contains("=") || t.hasPrefix("-") { tokens.removeFirst() }
        guard let first = tokens.first else { return false }
        let name = (first as NSString).lastPathComponent
        if !allow.contains(name) { return false }
    }
    return true
}

/// 指令是否看起來是重工作（要預熱）。只看每段指令的開頭（去掉 sudo/env/VAR=x），
/// 不掃整段文字——否則 heredoc 或字串裡提到 "swift build" 也會觸發
func commandNeedsBoost(_ command: String, keywords: [String]) -> Bool {
    let segments = command
        .replacingOccurrences(of: "&&", with: "\n")
        .replacingOccurrences(of: "||", with: "\n")
        .components(separatedBy: CharacterSet(charactersIn: ";|\n"))
    for seg in segments {
        var tokens = seg.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let t = tokens.first, t == "sudo" || t == "env" || t == "exec" || t == "time" || t == "nice" || (t.contains("=") && !t.hasPrefix("-")) { tokens.removeFirst() }
        guard !tokens.isEmpty else { continue }
        tokens[0] = (tokens[0] as NSString).lastPathComponent
        let head = tokens.prefix(3).joined(separator: " ").lowercased() + " "
        if keywords.contains(where: { head.hasPrefix($0.lowercased()) }) { return true }
    }
    return false
}

/// Claude Code PreToolUse hook：
///   ok/warm → 直接放行（重指令先發預熱事件）
///   hot     → 等待降溫（最多 hookWaitSeconds，且不超過 hookWaitCap），之後放行並附警告
///   critical→ 依設定擋下（deny）或放行附警告
///   白名單指令（cool91 / kill / …）任何等級都放行，否則 critical 時連降溫指令都跑不了
func runHook(config: Config) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    var command = ""
    if let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
       let ti = obj["tool_input"] as? [String: Any], let c = ti["command"] as? String {
        command = c
    }
    let allowed = !command.isEmpty && commandIsAllowed(command, allow: config.hookAllowCommands)
    if !command.isEmpty, commandNeedsBoost(command, keywords: config.boostCommands) {
        Event(kind: .boost, rpm: config.boostRPM, seconds: config.boostSeconds, note: String(command.prefix(60))).post()
    }

    var s = Snapshot.takeFast(config: config)
    var waited = 0.0
    if s.level >= .hot && !allowed {
        let start = Date()
        _ = waitUntilCool(below: config.hotTemp, timeout: min(config.hookWaitSeconds, Config.hookWaitCap), config: config) { _ in }
        waited = Date().timeIntervalSince(start)
        s = Snapshot.takeFast(config: config)
        Event(kind: .hookWait, seconds: waited).post()
    }
    var out: [String: Any] = [:]
    let note = String(format: "cool91 %@ %.0f°C 風扇 %.0f rpm", s.level.emoji, s.controlTemp, s.fans.first?.rpm ?? 0)
    if s.level == .critical && config.hookBlockOnCritical && !allowed {
        Event(kind: .hookDeny).post()
        out["hookSpecificOutput"] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "\(note)：已達 critical（≥\(Int(config.criticalTemp))°C），等了 \(Int(waited)) 秒仍未降溫。先讓機器冷卻再重試（`cool91 wait` 與 kill/pkill 等降溫指令不受限）。",
        ]
    } else if allowed && s.level >= .hot {
        out["systemMessage"] = "\(note)：白名單指令放行。"
    } else if s.level >= .hot || waited >= 1 {
        out["systemMessage"] = "\(note)：機器偏熱（已等待 \(Int(waited)) 秒）。建議避免同時開多個重負載工作。"
    }
    if let d = try? JSONSerialization.data(withJSONObject: out), let str = String(data: d, encoding: .utf8) {
        print(str)
    }
    exit(0)
}

// MARK: - guard

/// guard 的 log：root 時自己 append 到 /var/log/cool91.log（帶時間戳；newsyslog 輪替後自然寫到新檔），否則走 stderr
// （放在 enum 裡用 static：main.swift 的頂層 let 是依序初始化的，runGuard 被呼叫時它們還沒建好）
enum GuardLog {
    static let path = "/var/log/cool91.log"
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
}
func guardLog(_ m: String, toFile: Bool) {
    let line = "\(GuardLog.stamp.string(from: Date())) \(m)\n"
    if toFile, let d = line.data(using: .utf8) {
        if !FileManager.default.fileExists(atPath: GuardLog.path) {
            FileManager.default.createFile(atPath: GuardLog.path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        if let fh = FileHandle(forWritingAtPath: GuardLog.path) {
            fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
            return
        }
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

/// 常駐控制迴圈（需 root 才能寫 SMC）。config 檔改動會自動重載（面板改模式/曲線即時生效）
func runGuard(config initial: Config, dryRun: Bool, interval: Double) throws {
    let isRoot = getuid() == 0
    if !isRoot && !dryRun {
        throw Cool91Error.usage("guard 需要 root 才能寫風扇（sudo cool91 guard），或加 --dry-run 只觀察")
    }
    func log(_ m: String) { guardLog(m, toFile: isRoot && !dryRun) }
    if macsFanControlRunning() {
        log("⚠️ Macs Fan Control 正在執行，兩者會互搶風扇控制；建議先退出它。")
    }
    let fanCount = SMC.fanCount
    guard fanCount > 0 else { throw Cool91Error.smc("找不到風扇（FNum=0）") }

    var config = initial
    var configMtime = Config.mtime(config.loadedFrom)
    Event.prepareDir()

    // 收到終止訊號時把風扇交還 SMC
    var stopping = false
    let restore = {
        if !dryRun { for i in 0..<fanCount { try? SMC.setFanAuto(i) } }
    }
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { stopping = true }
        src.resume()
        _ = Unmanaged.passRetained(src as AnyObject)
    }

    var lastTarget: Double = -1
    var forceWrite = false       // 設定重載後這輪不管 deadband 一定寫
    var auto = true              // 目前是否交還 SMC 自動
    var smoothed: Double? = nil  // 控制溫度 EMA（升溫快、降溫慢）
    var lastLevel: Level? = nil
    var faultStreak = 0          // 連續感測器故障輪數
    var boostUntil: Date? = nil
    var boostRPM: Double = 0
    // 今日統計：guard 重啟時從舊快照接續（同一天才算）
    var stats = Snapshot.load()?.stats.flatMap { $0.date == Snapshot.Stats.today() ? $0 : nil } ?? Snapshot.Stats(date: Snapshot.Stats.today())
    var history = History.load().filter { Date().timeIntervalSince($0.time) < History.keep }

    log("cool91 guard 啟動（\(chipName())，\(fanCount) 顆風扇，每 \(interval)s，模式 \(config.mode)，GPU \(config.includeGPU ? "納入" : "不納入")，\(dryRun ? "dry-run" : "控制中")）")

    while !stopping {
        // 設定檔熱重載：解析失敗（含面板寫到一半）就保留舊設定，下一輪再試
        if let m = Config.mtime(config.loadedFrom), m != configMtime {
            do {
                config = try Config.loadOrError(path: config.loadedFrom)
                configMtime = m
                forceWrite = true
                log("設定已重載：模式 \(config.mode)，曲線 \(config.curve.map { "\(Int($0.temp))→\(Int($0.rpm))" }.joined(separator: " "))")
            } catch {
                log("⚠️ 設定檔解析失敗，保留舊設定：\(error)")
            }
        }

        // 收 hook / 面板丟過來的事件
        for e in Event.drain() {
            switch e.kind {
            case .boost:
                let until = e.time.addingTimeInterval(e.seconds ?? config.boostSeconds)
                if boostUntil == nil || until > boostUntil! { boostUntil = until }
                boostRPM = max(boostRPM, e.rpm ?? config.boostRPM)
                stats.boosts += 1
                log("預熱 \(Int(boostRPM)) rpm 到 \(GuardLog.stamp.string(from: boostUntil!))：\(e.note ?? "")")
            case .hookWait: stats.hookWaits += 1
            case .hookDeny: stats.hookDenies += 1
            }
        }
        if let b = boostUntil, b <= Date() { boostUntil = nil; boostRPM = 0 }

        var s = Snapshot.take(config: config)

        // 跨日歸零
        if stats.date != Snapshot.Stats.today() {
            log("今日統計結算：最高 \(Int(stats.maxTemp))°C，hot \(Int(stats.hotSeconds))s，critical \(Int(stats.criticalSeconds))s，hook 等待 \(stats.hookWaits) 次、擋下 \(stats.hookDenies) 次，預熱 \(stats.boosts) 次")
            stats = Snapshot.Stats(date: Snapshot.Stats.today())
        }

        if !s.sensorOK {
            // 感測器讀不完整：這輪的溫度不可信，不動風扇；連續 6 輪（30 秒）就交還 SMC 自己管
            faultStreak += 1; stats.sensorFaults += 1
            if faultStreak == 1 || faultStreak % 12 == 0 { log("⚠️ 感測器讀取不完整（連續 \(faultStreak) 輪），保持目前風扇目標") }
            if faultStreak >= 6 && !auto { restore(); auto = true; lastTarget = -1; log("⚠️ 感測器持續故障，風扇交還自動") }
        } else {
            faultStreak = 0
            let t = s.controlTemp
            if let prev = smoothed {
                smoothed = prev + (t - prev) * (t > prev ? config.smoothingUp : config.smoothingDown)
            } else { smoothed = t }
            let fmin = s.fans.first?.min ?? 0
            let fmax = s.fans.first?.max ?? 5000
            let curveMin = config.curve.map(\.temp).min() ?? 0

            // 決定目標：nil = 交還自動
            var desired: Double? = nil
            switch config.mode {
            case "auto":
                desired = nil
            case "fixed":
                desired = config.fixedRPM
            default: // curve；低於曲線最低點 5°C 以上就交還自動讓 SMC 省電
                desired = smoothed! < curveMin - 5 ? nil : config.rpm(for: smoothed!)
            }
            // 預熱：重指令剛開始、溫度還沒上來時先把風扇拉起來；auto 模式尊重使用者，不預熱
            if let b = boostUntil, b > Date(), config.mode != "auto" {
                desired = max(desired ?? 0, boostRPM)
            }
            // 任何來源的目標都夾在韌體回報的 F0Mn–F0Mx 之間，永遠不會超轉
            var target = desired.map { min(max($0, fmin), fmax) }
            // 降速斜率限制：升速不限，降速每輪最多降 maxRampDown
            if let t = target, lastTarget >= 0, config.maxRampDown > 0, t < lastTarget - config.maxRampDown {
                target = lastTarget - config.maxRampDown
            }

            if let target {
                if abs(target - lastTarget) >= config.deadband || auto || forceWrite {
                    if !dryRun { for i in 0..<fanCount { try SMC.setFan(i, rpm: target) } }
                    lastTarget = target; auto = false; forceWrite = false
                    log("\(s.short) → 目標 \(Int(target)) rpm")
                }
            } else if !auto {
                restore(); auto = true; lastTarget = -1
                log("\(s.short) → 交還自動")
            }
        }

        // 統計
        switch s.level {
        case .warm: stats.warmSeconds += interval
        case .hot: stats.hotSeconds += interval
        case .critical: stats.criticalSeconds += interval
        case .ok: break
        }
        stats.maxTemp = max(stats.maxTemp, s.controlTemp)
        if s.level != lastLevel, let last = lastLevel {
            log("等級 \(last.rawValue) → \(s.level.rawValue)（\(s.short)）")
        }
        lastLevel = s.level

        s.guardRunning = true
        s.guardMode = config.mode
        s.guardTargetRPM = auto ? nil : lastTarget
        s.boostUntil = boostUntil
        s.stats = stats
        s.save()

        history.append(HistoryPoint(time: s.time, cpu: s.cpuMax, gpu: s.gpuMax, rpm: s.fans.first?.rpm ?? 0, target: auto ? nil : lastTarget))
        history.removeAll { Date().timeIntervalSince($0.time) > History.keep }
        History.save(history)

        if dryRun { stderr("\(s.short) → \(auto ? "auto" : "\(Int(lastTarget)) rpm")") }
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    restore()
    var s = Snapshot.take(config: config); s.guardRunning = false; s.stats = stats; s.save()
    log("cool91 guard 結束，風扇已交還自動")
}

// MARK: - doctor

func runDoctor(config: Config) -> Bool {
    var allOK = true
    func check(_ ok: Bool, _ name: String, _ detail: String = "", warnOnly: Bool = false) {
        let mark = ok ? "✅" : (warnOnly ? "⚠️" : "❌")
        print("\(mark) \(name)\(detail.isEmpty ? "" : "：\(detail)")")
        if !ok && !warnOnly { allOK = false }
    }

    // 1. 設定檔
    do {
        let c = try Config.loadOrError(path: nil)
        check(true, "設定檔", c.loadedFrom ?? "未找到，使用預設值")
    } catch {
        check(false, "設定檔", "解析失敗 \(error)")
    }

    // 2. 感測器
    let s = Snapshot.take(config: config)
    check(!Snapshot.cachedCPUKeys.isEmpty, "CPU 感測器", "\(Snapshot.cachedCPUKeys.count) 個（前綴 \(config.cpuPrefixes.joined(separator: ","))）")
    check(!Snapshot.cachedGPUKeys.isEmpty, "GPU 感測器", "\(Snapshot.cachedGPUKeys.count) 個", warnOnly: true)
    check(s.sensorOK, "感測器讀取", s.sensorOK ? "完整" : "不完整")
    check(!s.fans.isEmpty, "風扇", s.fans.map { "F\($0.index) \(Int($0.min))–\(Int($0.max)) rpm" }.joined(separator: ", "))

    // 3. guard
    let guardProc = pgrep("cool91 guard")
    check(guardProc, "guard 行程", guardProc ? "執行中" : "沒有在跑（sudo launchctl bootstrap system /Library/LaunchDaemons/com.cool91.guard.plist）")
    if let saved = Snapshot.load() {
        let age = Date().timeIntervalSince(saved.time)
        check(saved.guardRunning && age < config.interval * 3, "快照", String(format: "%@ %.0f 秒前", Snapshot.statePath, age))
    } else {
        check(false, "快照", "\(Snapshot.statePath) 不存在")
    }
    check(FileManager.default.isWritableFile(atPath: Event.dir), "事件目錄", Event.dir + (FileManager.default.isWritableFile(atPath: Event.dir) ? " 可寫" : " 不存在或不可寫（guard 啟動時會建）"))
    if let f = s.fans.first {
        check(!s.guardRunning || f.manual || s.guardTargetRPM == nil, "風扇控制權", f.manual ? "手動（guard 控制中）" : "自動", warnOnly: true)
    }
    check(FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.cool91.guard.plist"), "LaunchDaemon", "/Library/LaunchDaemons/com.cool91.guard.plist")

    // 4. hook
    let settingsPath = NSString(string: "~/.claude/settings.json").expandingTildeInPath
    var hookFound = false; var hookTimeout: Double = 60
    if let d = FileManager.default.contents(atPath: settingsPath),
       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let hooks = obj["hooks"] as? [String: Any], let pre = hooks["PreToolUse"] as? [[String: Any]] {
        for entry in pre {
            for h in entry["hooks"] as? [[String: Any]] ?? [] where (h["command"] as? String ?? "").contains("cool91 hook") {
                hookFound = true
                hookTimeout = (h["timeout"] as? Double) ?? 60
            }
        }
    }
    check(hookFound, "Claude Code hook", hookFound ? "已裝在 \(settingsPath)" : "未裝（./install-hook.py）")
    if hookFound {
        let need = min(config.hookWaitSeconds, Config.hookWaitCap) + 20
        check(hookTimeout >= need, "hook timeout", "\(Int(hookTimeout)) 秒（等待上限 \(Int(min(config.hookWaitSeconds, Config.hookWaitCap))) 秒，需 ≥ \(Int(need))）")
    }

    // 5. 衝突與面板
    let mfc = macsFanControlRunning()
    check(!mfc, "Macs Fan Control", mfc ? "正在執行，會互搶風扇" : "未執行")
    check(pgrep("cool91-panel", exact: true), "選單列面板", "", warnOnly: true)

    // 6. log
    check(FileManager.default.fileExists(atPath: "/etc/newsyslog.d/cool91.conf"), "log 輪替", "/etc/newsyslog.d/cool91.conf", warnOnly: true)

    print(allOK ? "\n全部正常。\(s.short)" : "\n有問題需要處理。")
    return allOK
}
