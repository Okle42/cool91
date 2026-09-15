import Foundation

// cool91 — Apple Silicon 風扇/溫度守門員，給 Claude Code 當把關工具用
// 子命令：status | sensors | fan | guard | check | wait | hook | chip

let args = Array(CommandLine.arguments.dropFirst())

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

func usage() -> Never {
    print("""
    cool91 <命令> [選項]

      status [--json|--short]      目前溫度、風扇、把關等級
      sensors                      列出所有溫度感測器 key（移植新晶片時用）
      chip                         顯示晶片型號與偵測到的感測器分組
      fan auto | fan <rpm> [--fan N]   手動設風扇（需 sudo）
      guard [--interval S] [--config PATH] [--dry-run]
                                   常駐控制迴圈，依曲線調風扇（需 sudo）
      check [--json]               把關檢查：exit 0=ok/warm, 1=hot, 2=critical
      wait [--below TEMP] [--timeout S]   等待 CPU 降到門檻以下
      hook                         Claude Code PreToolUse hook 入口（讀 stdin，輸出決策 JSON）

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

func macsFanControlRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "Macs Fan Control.app/Contents/MacOS"]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

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
            FileHandle.standardError.write("\(s.short)  等待降到 \(Int(below))°C 以下…\n".data(using: .utf8)!)
        }
        exit(ok ? 0 : 1)

    case "hook":
        runHook(config: config)

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("cool91: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 實作

/// 每 2 秒取樣直到 cpuMax < below 或逾時
func waitUntilCool(below: Double, timeout: Double, config: Config, progress: (Snapshot) -> Void) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let s = Snapshot.take(config: config)
        if s.cpuMax < below { return true }
        if Date() >= deadline { return false }
        progress(s)
        Thread.sleep(forTimeInterval: 2)
    }
}

/// Claude Code PreToolUse hook：
///   ok/warm → 直接放行
///   hot     → 等待降溫（最多 hookWaitSeconds），之後放行並附警告
///   critical→ 依設定擋下（deny）或放行附警告
func runHook(config: Config) {
    _ = FileHandle.standardInput.readDataToEndOfFile() // 不需要工具參數，讀掉即可
    var s = Snapshot.takeFast(config: config)
    var waited = 0.0
    if s.level >= .hot {
        let start = Date()
        _ = waitUntilCool(below: config.hotTemp, timeout: config.hookWaitSeconds, config: config) { _ in }
        waited = Date().timeIntervalSince(start)
        s = Snapshot.take(config: config)
    }
    var out: [String: Any] = [:]
    let note = String(format: "cool91 %@ CPU %.0f°C 風扇 %.0f rpm", s.level.emoji, s.cpuMax, s.fans.first?.rpm ?? 0)
    if s.level == .critical && config.hookBlockOnCritical {
        out["hookSpecificOutput"] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "\(note)：CPU 已達 critical（≥\(Int(config.criticalTemp))°C），等了 \(Int(waited)) 秒仍未降溫。先讓機器冷卻再重試（可執行 `cool91 wait`）。",
        ]
    } else if s.level >= .hot || waited > 0 {
        out["systemMessage"] = "\(note)：機器偏熱（已等待 \(Int(waited)) 秒）。建議避免同時開多個重負載工作。"
    }
    if let d = try? JSONSerialization.data(withJSONObject: out), let str = String(data: d, encoding: .utf8) {
        print(str)
    }
    exit(0)
}

/// 常駐控制迴圈（需 root 才能寫 SMC）
func runGuard(config: Config, dryRun: Bool, interval: Double) throws {
    let isRoot = getuid() == 0
    if !isRoot && !dryRun {
        throw Cool91Error.usage("guard 需要 root 才能寫風扇（sudo cool91 guard），或加 --dry-run 只觀察")
    }
    if macsFanControlRunning() {
        FileHandle.standardError.write("⚠️ Macs Fan Control 正在執行，兩者會互搶風扇控制；建議先退出它。\n".data(using: .utf8)!)
    }
    let fanCount = SMC.fanCount
    guard fanCount > 0 else { throw Cool91Error.smc("找不到風扇（FNum=0）") }

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
    var auto = true
    var smoothed: Double? = nil   // 溫度 EMA，抑制單次取樣抖動
    FileHandle.standardError.write("cool91 guard 啟動（\(chipName())，\(fanCount) 顆風扇，每 \(interval)s，\(dryRun ? "dry-run" : "控制中")）\n".data(using: .utf8)!)

    while !stopping {
        var s = Snapshot.take(config: config)
        smoothed = smoothed.map { $0 * (1 - config.smoothing) + s.cpuMax * config.smoothing } ?? s.cpuMax
        let want = config.rpm(for: smoothed!)
        let fmin = s.fans.first?.min ?? 0
        let fmax = s.fans.first?.max ?? want
        let target = min(max(want, fmin), fmax)

        // 低於曲線最低點就交還自動，讓 SMC 自己省電；否則手動設定
        let curveMin = config.curve.map(\.temp).min() ?? 0
        if s.cpuMax < curveMin - 5 {
            if !auto {
                if !dryRun { restore() }
                auto = true; lastTarget = -1
            }
        } else if abs(target - lastTarget) >= config.deadband || auto {
            if !dryRun { for i in 0..<fanCount { try SMC.setFan(i, rpm: target) } }
            lastTarget = target; auto = false
        }

        s.guardRunning = true
        s.guardTargetRPM = auto ? nil : lastTarget
        s.save()
        if dryRun || s.level >= .hot {
            FileHandle.standardError.write("\(s.short) → 目標 \(auto ? "auto" : "\(Int(lastTarget)) rpm")\n".data(using: .utf8)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    restore()
    var s = Snapshot.take(config: config); s.guardRunning = false; s.save()
    FileHandle.standardError.write("cool91 guard 結束，風扇已交還自動\n".data(using: .utf8)!)
}
