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
      check [--json]               能不能開工：exit 0=可以, 1=降頻中該等, 2=該擋（和 hook 同一套判斷）
      wait [--below TEMP] [--timeout S]   等到可開工（降頻結束）；--below 改為等控制溫度降到 TEMP 以下
      hook                         Claude Code PreToolUse hook 入口（讀 stdin，輸出決策 JSON）
      top                          現在誰在吃 CPU、GPU 使用率（guard 每 5 秒更新；沒 guard 就自己量 2 秒）
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
        Snapshot.forceRescan = true
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
        // 和 hook 同一套判斷：0 = 可開工，1 = 降頻中/hot 該等，2 = Trapping/critical 該擋
        let s = Snapshot.takeFast(config: config)
        if flag("--json") { print(s.json) } else { print(s.short) }
        let v = Policy.verdict(s, config: config)
        exit(v.block ? 2 : v.wait ? 1 : 0)

    case "wait":
        // 無參數：等到可開工（pressure 回 Nominal）；--below T：等控制溫度降到 T 以下
        let timeout = Double(opt("--timeout") ?? "") ?? config.hookWaitSeconds
        let ok: Bool
        if let below = Double(opt("--below") ?? "") {
            ok = waitUntilCool(below: below, timeout: timeout, config: config) { s in
                stderr("\(s.short)  等待降到 \(Int(below))°C 以下…")
            }
        } else {
            ok = waitUntilWorkable(timeout: timeout, config: config) { s in
                stderr("\(s.short)  等待降頻結束…")
            }
        }
        exit(ok ? 0 : 1)

    case "hook":
        runHook(config: config)

    case "top":
        var s = Snapshot.takeFast(config: config)
        if s.topProcesses == nil {   // guard 沒跑：自己差分 2 秒
            let pt = ProcTop(); _ = pt.sample(); let g = GPUStats(); Thread.sleep(forTimeInterval: 2)
            s.topProcesses = pt.sample(top: 5, minPercent: 5); if let r = g.sample() { s.gpuActive = r.active; s.gpuMHz = r.mhz }
        }
        print(s.short)
        if let a = s.gpuActive { print(String(format: "GPU 使用率 %.0f%%  %.0f MHz  %.0f°C", a, s.gpuMHz ?? 0, s.gpuMax)) }
        for p in s.topProcesses ?? [] {
            print(String(format: "%6d  %5.0f%%  %@%@", p.pid, p.cpuPercent, p.command, p.cwd.map { "   （\($0)）" } ?? ""))
        }
        if (s.topProcesses ?? []).isEmpty { print("沒有 process 超過 20% CPU") }

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

/// 每 2 秒取樣直到可開工或逾時
func waitUntilWorkable(timeout: Double, config: Config, progress: (Snapshot) -> Void) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let s = Snapshot.takeFast(config: config)
        if !Policy.verdict(s, config: config).wait { return true }
        if Date() >= deadline { return false }
        progress(s)
        Thread.sleep(forTimeInterval: 2)
    }
}
