import Foundation
import Cool91Core

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
    let guardProc = pgrep("cool91(-guard)? guard")
    check(guardProc, "guard 行程", guardProc ? "執行中" : "沒有在跑（sudo launchctl bootstrap system /Library/LaunchDaemons/com.cool91.guard.plist）")
    if let saved = Snapshot.load() {
        let age = Date().timeIntervalSince(saved.time)
        check(saved.guardRunning && age < config.interval * 3, "快照", String(format: "%@ %.0f 秒前", Snapshot.statePath, age))
    } else {
        check(false, "快照", "\(Snapshot.statePath) 不存在")
    }
    check(FileManager.default.isWritableFile(atPath: Event.dir), "事件目錄", Event.dir + (FileManager.default.isWritableFile(atPath: Event.dir) ? " 可寫" : " 不存在或不可寫（guard 啟動時會建）"))
    if let f = s.fans.first {
        if s.guardRunning { check(true, "風扇控制權", f.manual ? "手動（guard 控制中）" : "自動") }
        else { check(!f.manual, "風扇控制權", f.manual ? String(format: "手動 %.0f rpm 但 guard 沒在跑（停在上次目標）；交還請 sudo cool91 fan auto", f.target) : "自動") }
    }
    check(FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.cool91.guard.plist"), "LaunchDaemon", "/Library/LaunchDaemons/com.cool91.guard.plist")
    if let saved = Snapshot.load(), saved.guardRunning {
        check(saved.pcoreMHz != nil, "CPU 頻率（powermetrics）", saved.pcoreMHz.map { String(format: "P-core %.0f MHz，pressure %@", $0, saved.thermalPressure ?? "?") } ?? "快照裡沒有（guard 剛啟動或 powermetrics 失敗）", warnOnly: true)
    }

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
    check(hookFound, "Claude Code hook", hookFound ? "已裝在 \(settingsPath)" : "未裝（./scripts/install-hook.py）")
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
