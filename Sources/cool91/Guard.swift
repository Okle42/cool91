import Foundation
import Cool91Core

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
    // 硬體頻率與 thermal pressure：root 才讀得到（powermetrics）
    let freq = FreqReader(interval: interval)
    let gpuStats = GPUStats()
    let procTop = ProcTop()
    if FreqReader.available { freq.ensureRunning() } else { log("powermetrics 不可用（非 root 或找不到），不顯示頻率") }

    // 終止訊號：SIGTERM（launchd 停止 / 重啟）保持目前轉速不交還 —— 重啟接管只要幾秒，交還自動反而讓高負載下 30 秒衝到 100°C；
    // SIGINT（Ctrl-C）/ SIGHUP 才交還自動。uninstall.sh 會明確 `cool91 fan auto`
    var stopping = false
    var keepFansOnExit = false
    let restore = {
        if !dryRun { for i in 0..<fanCount { try? SMC.setFanAuto(i) } }
    }
    defer { freq.stop() }
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { stopping = true; keepFansOnExit = (sig == SIGTERM) }
        src.resume()
        _ = Unmanaged.passRetained(src as AnyObject)
    }

    let boostGraceSeconds = 30.0 // 預熱至少撐這麼久才判斷要不要提早收
    var lastTarget: Double = -1
    var forceWrite = false       // 設定重載後這輪不管 deadband 一定寫
    var auto = true              // 目前是否交還 SMC 自動
    var smoothed: Double? = nil  // 控制溫度 EMA（升溫快、降溫慢）
    var lastLevel: Level? = nil
    var wasThrottling = false
    var lastFreqError: String? = nil
    var coolRounds = 0           // 連續幾輪目標低於現在（降速前的等待計數）
    var faultStreak = 0          // 連續感測器故障輪數
    var boostUntil: Date? = nil
    var boostRPM: Double = 0
    var boostStart: Date? = nil  // 這一波預熱從何時開始（判斷「預熱了 30 秒溫度還沒起來」用）
    var levelCoolRounds = 0      // 等級連續幾輪該降（降級前的等待計數，和風扇降速同一個 rampDownHoldRounds）
    // 今日統計：guard 重啟時從舊快照接續，快照不在（/tmp 重開機被清）就從 /var/db 的落地檔接（都要同一天才算）
    var stats = [Snapshot.load()?.stats, Snapshot.Stats.loadPersisted()].compactMap { $0 }.first { $0.date == Snapshot.Stats.today() }
        ?? Snapshot.Stats(date: Snapshot.Stats.today())
    var statsPersistRound = 0
    var history = History.load().filter { Date().timeIntervalSince($0.time) < History.keep }

    // Watchdog：主迴圈卡在 kernel 呼叫（SMC mach_msg 不回、被餓死…）連 SIGTERM 都收不到；
    // 另一條 thread 看心跳，超過 6 個週期沒動就自殺讓 launchd（KeepAlive）重啟
    let heartbeat = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    heartbeat.pointee = Date().timeIntervalSince1970
    let watchdogLimit = max(30, interval * 6)
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 5)
            let age = Date().timeIntervalSince1970 - heartbeat.pointee
            if age > watchdogLimit {
                guardLog("⚠️ watchdog：主迴圈 \(Int(age)) 秒沒心跳（卡在 SMC 或被餓死），自殺讓 launchd 重啟", toFile: isRoot && !dryRun)
                _exit(3)
            }
        }
    }

    log("cool91 guard 啟動（\(chipName())，\(fanCount) 顆風扇，每 \(interval)s，模式 \(config.mode)，GPU \(config.includeGPU ? "納入" : "不納入")，\(dryRun ? "dry-run" : "控制中")）")

    while !stopping {
        heartbeat.pointee = Date().timeIntervalSince1970
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
                if boostUntil == nil { boostStart = Date() }
                if boostUntil == nil || until > boostUntil! { boostUntil = until }
                boostRPM = max(boostRPM, e.rpm ?? config.boostRPM)
                stats.boosts += 1
                log("預熱 \(Int(boostRPM)) rpm 到 \(GuardLog.stamp.string(from: boostUntil!))：\(e.note ?? "")")
            case .hookWait: stats.hookWaits += 1
            case .hookDeny: stats.hookDenies += 1
            }
        }
        if let b = boostUntil, b <= Date() { boostUntil = nil; boostRPM = 0; boostStart = nil }

        var s = Snapshot.take(config: config)
        if let g = gpuStats.sample() { s.gpuActive = g.active; s.gpuMHz = g.mhz; s.gpuThrottlePercent = gpuStats.cltmPercent }
        let top = procTop.sample(); if !top.isEmpty { s.topProcesses = top }

        // 跨日歸零
        if stats.date != Snapshot.Stats.today() {
            log("今日統計結算：最高 \(Int(stats.maxTemp))°C，hot \(Int(stats.hotSeconds))s，critical \(Int(stats.criticalSeconds))s，hook 等待 \(stats.hookWaits) 次、擋下 \(stats.hookDenies) 次，預熱 \(stats.boosts) 次，降頻 \(Int(stats.throttleSeconds))s")
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
                // 到 hot 以上就不平滑了，尖峰要立刻反應（閒段 → 重載一輪可以 +20°C）
                smoothed = t >= config.hotTemp ? max(t, prev) : prev + (t - prev) * (t > prev ? config.smoothingUp : config.smoothingDown)
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
            // 預熱了 30 秒控制溫度還在曲線起點以下，表示這條指令根本不重（幾秒就跑完的 pytest、被關鍵字撞到的 sed…），
            // 不必再轟滿 120 秒；真的重的指令 30 秒內早就過 60°C，曲線會接手
            if let b = boostUntil, b > Date(), let st = boostStart, Date().timeIntervalSince(st) >= boostGraceSeconds, smoothed! < curveMin {
                log("預熱提早結束：\(Int(Date().timeIntervalSince(st))) 秒後仍只有 \(Int(s.controlTemp))°C，不像重工作")
                boostUntil = nil; boostRPM = 0; boostStart = nil
            }
            // 預熱：重指令剛開始、溫度還沒上來時先把風扇拉起來；auto 模式尊重使用者，不預熱
            if let b = boostUntil, b > Date(), config.mode != "auto" {
                desired = max(desired ?? 0, boostRPM)
            }
            // 任何來源的目標都夾在韌體回報的 F0Mn–F0Mx 之間，永遠不會超轉
            var target = desired.map { min(max($0, fmin), fmax) }
            // 降速（含交還自動）要「連續 N 輪都偏冷」才開始，短暫鬆一下不理；一旦要升速就立刻歸零
            // （面板剛切到 auto 模式那輪 forceWrite 為 true：使用者要的是立刻交還，不等）
            if lastTarget >= 0, !forceWrite, target == nil || target! < lastTarget - config.deadband {
                coolRounds += 1
                if coolRounds <= config.rampDownHoldRounds { target = lastTarget }
            } else {
                coolRounds = 0
            }
            // 斜率限制：降速每輪最多 maxRampDown，升速每輪最多 maxRampUp（預熱與剛接管時不限，該快就快）
            if let t = target, lastTarget >= 0 {
                if config.maxRampDown > 0, t < lastTarget - config.maxRampDown { target = lastTarget - config.maxRampDown }
                let boosting = boostUntil.map { $0 > Date() } ?? false
                let urgent = s.controlTemp >= config.hotTemp   // 已經 hot 就別慢慢升
                if config.maxRampUp > 0, !boosting, !urgent, t > lastTarget + config.maxRampUp { target = lastTarget + config.maxRampUp }
            }

            if let target {
                if abs(target - lastTarget) >= config.deadband || auto || forceWrite {
                    if !dryRun { for i in 0..<fanCount { try SMC.setFan(i, rpm: target) } }
                    lastTarget = target; auto = false; forceWrite = false
                    log("\(s.short) → 目標 \(Int(target)) rpm")
                }
            } else if !auto {
                restore(); auto = true; lastTarget = -1; forceWrite = false
                log("\(s.short) → 交還自動")
            }
        }

        // 等級加遲滯（升級立即、降級要低於門檻 3°C 且連續 rampDownHoldRounds 輪都如此），快照、統計、log 都用這個。
        // 單核尖峰 5 秒內 50↔80°C 來回，只靠 3°C 遲滯一天會寫幾百條 ok↔warm；升級仍是立即，安全不打折
        let rawLevel = config.level(for: s.controlTemp, previous: lastLevel)
        if let last = lastLevel, rawLevel < last {
            levelCoolRounds += 1
            s.level = levelCoolRounds > config.rampDownHoldRounds ? rawLevel : last
        } else {
            levelCoolRounds = 0
            s.level = rawLevel
        }
        // 統計
        switch s.level {
        case .warm: stats.warmSeconds += interval
        case .hot: stats.hotSeconds += interval
        case .critical: stats.criticalSeconds += interval
        case .ok: break
        }
        stats.maxTemp = max(stats.maxTemp, s.controlTemp)
        freq.ensureRunning()
        if let e = freq.lastError, e != lastFreqError { log("⚠️ \(e)"); lastFreqError = e }
        if freq.fresh {
            s.pcoreMHz = freq.pcoreMHz; s.ecoreMHz = freq.ecoreMHz; s.thermalPressure = freq.pressure
            let throttlingNow = s.throttling || s.gpuThrottling
            if throttlingNow {
                stats.throttleSeconds += interval
                if !wasThrottling { log("⚠️ 熱降頻開始：pressure \(freq.pressure ?? "?")，P-core \(Int(freq.pcoreMHz ?? 0)) MHz，GPU CLTM \(Int(s.gpuThrottlePercent ?? 0))%（\(s.short)）") }
            } else if wasThrottling {
                log("熱降頻結束：P-core \(Int(freq.pcoreMHz ?? 0)) MHz（\(s.short)）")
            }
            wasThrottling = throttlingNow
        }
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
        statsPersistRound += 1
        if isRoot && !dryRun && statsPersistRound % 12 == 0 { stats.persist() }

        history.append(HistoryPoint(time: s.time, cpu: s.cpuMax, gpu: s.gpuMax, rpm: s.fans.first?.rpm ?? 0, target: auto ? nil : lastTarget, pMHz: s.pcoreMHz, gpuActive: s.gpuActive))
        history.removeAll { Date().timeIntervalSince($0.time) > History.keep }
        History.save(history)

        if dryRun { stderr("\(s.short) → \(auto ? "auto" : "\(Int(lastTarget)) rpm")") }
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }
    if keepFansOnExit && !auto {
        log("cool91 guard 結束（SIGTERM），風扇維持 \(Int(lastTarget)) rpm 等 launchd 重啟接管；要交還自動請 `sudo cool91 fan auto`")
    } else {
        restore()
        log("cool91 guard 結束，風扇已交還自動")
    }
    var s = Snapshot.take(config: config); s.guardRunning = false; s.stats = stats; s.save()
    if isRoot && !dryRun { stats.persist() }
}
