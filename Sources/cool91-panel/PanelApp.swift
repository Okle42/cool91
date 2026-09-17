import SwiftUI
import Charts
import Cool91Core

// cool91 面板：選單列常駐，只讀資料（不需 root），每 3 秒更新一次

@main
struct PanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            Text(monitor.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不顯示 Dock 圖示
    }
}

// MARK: - 資料

@Observable
final class Monitor {
    var snapshot: Snapshot?
    var history: [HistoryPoint] = []
    var config = Config.load(path: nil)
    var draft = Config.load(path: nil)   // 面板上編輯中的設定
    var saveMessage: String? = nil
    /// 選單有沒有打開。關著的時候只更新標題（讀一個 JSON，不開 SMC、不畫圖）
    var panelOpen = false { didSet { if panelOpen { reloadConfig(); tick() } } }
    let intervalOpen: TimeInterval = 3
    let intervalIdle: TimeInterval = 5
    private var timer: Timer?
    private var localHistory: [HistoryPoint] = []   // guard 沒跑時自己取樣的備援

    // 提示音：進入過熱 / 降頻響「熱」、回到正常響「冷」。開關存 UserDefaults（面板本地）；
    // 音效檔三層：config 的 sounds.overheat / cooldown → app 內建 Sounds/overheat.m4a、cooldown.m4a → 系統音
    static let hotSound = "Basso", coldSound = "Glass"
    var hotSoundOn: Bool { didSet { UserDefaults.standard.set(hotSoundOn, forKey: "sound.hot") } }
    var coldSoundOn: Bool { didSet { UserDefaults.standard.set(coldSoundOn, forKey: "sound.cold") } }
    @ObservationIgnored private var wasHot: Bool? = nil          // 上一輪是不是熱的；nil = 還沒取樣，第一輪不響
    @ObservationIgnored private var awaitingCool = false         // 響過「熱」之後上鎖，等降到 cooldownBelow 響「冷」才解鎖
    @ObservationIgnored private var lastSound = Date.distantPast
    @ObservationIgnored private var configMtime: Date? = nil
    @ObservationIgnored private var playing: NSSound? = nil   // 抓住正在播的，不然 mp3 播到一半被釋放

    // 各感測器明細：只有面板展開「各感測器」時才每輪讀 73 個 key，收合不花這個成本
    var showSensors: Bool { didSet { UserDefaults.standard.set(showSensors, forKey: "sensors.show"); if showSensors { readSensors() } } }
    var sensorTemps: [String: Double] = [:]

    init() {
        hotSoundOn = UserDefaults.standard.object(forKey: "sound.hot") as? Bool ?? true
        coldSoundOn = UserDefaults.standard.object(forKey: "sound.cold") as? Bool ?? true
        showSensors = UserDefaults.standard.bool(forKey: "sensors.show")
        smcOpened = (try? SMC.open()) != nil
        tick()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: panelOpen ? intervalOpen : intervalIdle, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick()
            if (self.timer?.timeInterval ?? 0) != (self.panelOpen ? self.intervalOpen : self.intervalIdle) { self.schedule() }
        }
    }

    /// MenuBarExtra(.window) 的內容 view 不一定會 disappear，onAppear 不可靠；直接看有沒有可見視窗
    var windowVisible: Bool {
        let ws = (NSApplication.shared as NSApplication?)?.windows ?? []
        let dbg = ws.map { "\(type(of: $0)) vis=\($0.isVisible) key=\($0.isKeyWindow) occl=\($0.occlusionState.contains(.visible)) alpha=\($0.alphaValue) onscreen=\($0.isOnActiveSpace) frame=\($0.frame) level=\($0.level.rawValue) appActive=\(NSApplication.shared.isActive)" }.joined(separator: "\n")
        try? (dbg + "\n").write(toFile: "/tmp/cool91.panel.debug", atomically: true, encoding: .utf8)
        return ws.contains { String(describing: type(of: $0)).hasPrefix("MenuBarExtraWindow") && $0.isVisible }
    }

    func tick() {
        // 設定檔被改了（另一個 session、手動編輯）就跟上，門檻和音檔才會即時生效；只 stat 一次，閒置也做
        let m = Config.mtime(config.loadedFrom)
        if m != configMtime { configMtime = m; reloadConfig() }
        // guard 在跑：只讀快照檔；沒跑才自己開 SMC
        let s = Snapshot.takeFast(config: config)
        snapshot = s
        checkSound(s)
        let open = windowVisible
        if open != panelOpen { panelOpen = open; return }   // didSet 會再叫一次 tick
        guard panelOpen else { return }
        if showSensors { readSensors() }
        if s.guardRunning {
            history = History.load()
        } else {
            localHistory.append(HistoryPoint(time: s.time, cpu: s.cpuMax, gpu: s.gpuMax, rpm: s.fans.first?.rpm ?? 0, target: nil))
            localHistory.removeAll { Date().timeIntervalSince($0.time) > History.keep }
            history = localHistory
        }
    }

    /// 一趟「過熱 → 涼了」只響兩聲：控制溫度 ≥ overheatAbove（或 CPU / GPU 降頻、或到 critical）的瞬間響「熱」並上鎖；
    /// 之後不熱了且控制溫度降到 cooldownBelow 以下才響「冷」並解鎖。中間在門檻上下抖動不會再叫；20 秒內也不連響
    private func checkSound(_ s: Snapshot) {
        let hot = s.controlTemp >= config.overheatAbove || s.level == .critical || s.throttling || s.gpuThrottling
        defer { wasHot = hot }
        guard let was = wasHot else { return }
        if hot, !was, !awaitingCool {
            awaitingCool = true
            if hotSoundOn, Date().timeIntervalSince(lastSound) > 20 { play(hot: true) }
        }
        if !hot, awaitingCool, s.controlTemp < config.cooldownBelow {
            awaitingCool = false
            if coldSoundOn, Date().timeIntervalSince(lastSound) > 20 { play(hot: false) }
        }
    }

    /// config 有指定音檔就播它（現讀一次設定檔，改了不用重開面板），沒有就用 app 內建的，再沒有退回系統音
    func play(hot: Bool) {
        playing?.stop()
        if let path = soundPath(hot: hot), let snd = NSSound(contentsOfFile: path, byReference: true) {
            playing = snd
        } else {
            playing = NSSound(named: hot ? Self.hotSound : Self.coldSound)
        }
        playing?.play()
        lastSound = Date()
    }

    /// 讀每個 CPU / GPU 感測器。key 用 guard 掃好寫在快照裡的（面板平常只讀快照，不會自己掃），沒有才掃一次
    @ObservationIgnored private var sensorKeys: [String] = []
    @ObservationIgnored private var smcOpened = false
    func readSensors() {
        if !smcOpened { smcOpened = (try? SMC.open()) != nil }
        guard smcOpened else { return }
        if sensorKeys.isEmpty {
            if let saved = Snapshot.load(), let ck = saved.cpuKeys, !ck.isEmpty {
                sensorKeys = ck + (saved.gpuKeys ?? [])
            } else {
                let prefixes = config.cpuPrefixes + config.gpuPrefixes
                sensorKeys = SMC.scanTemperatureKeys().map(\.0).filter { k in prefixes.contains { k.hasPrefix($0) } }
            }
        }
        var out: [String: Double] = [:]
        for k in sensorKeys { if let t = SMC.readDouble(k), SMC.plausibleTemp(t) { out[k] = t } }
        sensorTemps = out
    }

    /// 實際會播的音檔：config 指定（存在才算）→ app bundle 內建 → nil（系統音）
    func soundPath(hot: Bool) -> String? {
        let snd = Config.load(path: nil).sounds
        if let raw = hot ? snd?.overheat : snd?.cooldown, !raw.isEmpty {
            let path = NSString(string: raw).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        for ext in ["m4a", "mp3", "aiff", "wav"] {
            if let p = Bundle.main.path(forResource: hot ? "overheat" : "cooldown", ofType: ext, inDirectory: "Sounds") { return p }
        }
        return nil
    }

    /// 面板上編輯提示音門檻：draft.sounds 缺席時先建一個，其他欄位保留
    var draftOverheatAbove: Double {
        get { draft.overheatAbove }
        set { var x = draft.sounds ?? .init(); x.overheatAbove = newValue; draft.sounds = x }
    }
    var draftCooldownBelow: Double {
        get { draft.cooldownBelow }
        set { var x = draft.sounds ?? .init(); x.cooldownBelow = newValue; draft.sounds = x }
    }

    /// 重新啟動面板：由 LaunchAgent 管的就 kickstart，不然直接 open 自己的 bundle
    func relaunch() {
        let bundle = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.4; launchctl kickstart -k gui/$(id -u)/com.cool91.panel 2>/dev/null || open \"\(bundle)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 外部（手動編輯、另一台面板）改了設定檔也跟上
    func reloadConfig() {
        let fresh = Config.load(path: nil)
        if !dirty { draft = fresh }
        config = fresh
    }

    var fanDirty: Bool {
        draft.mode != config.mode || draft.fixedRPM != config.fixedRPM || draft.includeGPU != config.includeGPU ||
        draft.curve.map { [$0.temp, $0.rpm] } != config.curve.map { [$0.temp, $0.rpm] }
    }
    var soundDirty: Bool { draft.overheatAbove != config.overheatAbove || draft.cooldownBelow != config.cooldownBelow }
    var dirty: Bool { fanDirty || soundDirty }

    /// 寫回設定檔，guard 會偵測 mtime 自動重載
    func apply() {
        do {
            try draft.save()
            config = Config.load(path: nil)
            draft = config
            saveMessage = "已套用（\((config.loadedFrom ?? "") as NSString).lastPathComponent）"
        } catch {
            saveMessage = "寫入失敗：\(error.localizedDescription)"
        }
    }

    func revert() { draft = config; saveMessage = nil }

    static let presets: [(String, [Config.Point])] = [
        ("安靜", [.init(temp: 65, rpm: 1000), .init(temp: 80, rpm: 1600), .init(temp: 90, rpm: 2400), .init(temp: 95, rpm: 3400), .init(temp: 99, rpm: 4900)]),
        ("均衡", Config().curve),   // A/B 實測：重載 87°C / 3150 rpm，不降頻
        ("強力", [.init(temp: 55, rpm: 1000), .init(temp: 65, rpm: 1800), .init(temp: 75, rpm: 3000), .init(temp: 85, rpm: 4200), .init(temp: 90, rpm: 4900)]),
    ]

    var menuTitle: String {
        guard let s = snapshot else { return "cool91" }
        return "\(s.level.emoji) \(Int(s.controlTemp.rounded()))°"
    }
}

extension Level {
    var color: Color {
        switch self {
        case .ok: return .green
        case .warm: return .yellow
        case .hot: return .orange
        case .critical: return .red
        }
    }
    var label: String {
        switch self {
        case .ok: return "正常"
        case .warm: return "偏溫"
        case .hot: return "過熱"
        case .critical: return "危險"
        }
    }
}

// MARK: - 漸層微光風格

/// 深色底 + 霓虹線 + 線下漸層消失。發光用三層同路徑線疊出來（Charts 的 mark 不能 blur）
enum Neon {
    static let cyan   = Color(red: 0.16, green: 0.87, blue: 0.96)
    static let green  = Color(red: 0.36, green: 0.95, blue: 0.55)
    static let purple = Color(red: 0.72, green: 0.56, blue: 1.00)
    static let violet = Color(red: 0.50, green: 0.25, blue: 0.95)
    static let amber  = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let red    = Color(red: 1.00, green: 0.36, blue: 0.42)
    /// 面板整體深色玻璃底；plot 只比它再深一點點，不要浮出來
    static let panelBG = Color(red: 0.06, green: 0.07, blue: 0.11).opacity(0.94)
    static let plotBG  = Color.black.opacity(0.28)
    static let cardBG  = Color.white.opacity(0.045)

    /// 線下漸層：上濃下淡到透明
    static func fade(_ c: Color, top: Double = 0.45) -> LinearGradient {
        LinearGradient(colors: [c.opacity(top), c.opacity(0.12), c.opacity(0)], startPoint: .top, endPoint: .bottom)
    }
    /// 風扇條 / 強調用的橫向漸層
    static func sweep(_ a: Color, _ b: Color) -> LinearGradient {
        LinearGradient(colors: [a, b], startPoint: .leading, endPoint: .trailing)
    }
}

extension Level {
    var neon: Color {
        switch self {
        case .ok: return Neon.green
        case .warm: return Neon.amber
        case .hot: return Neon.amber
        case .critical: return Neon.red
        }
    }
}

/// 三層疊出來的發光線：寬淡暈 → 中暈 → 細實線
@ChartContentBuilder
func glowLine<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, series: String, color: Color, smooth: Bool = true) -> some ChartContent {
    LineMark(x: x, y: y, series: .value("s", series + "•halo")).foregroundStyle(color.opacity(0.10)).lineStyle(.init(lineWidth: 10, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear)
    LineMark(x: x, y: y, series: .value("s", series + "•glow")).foregroundStyle(color.opacity(0.28)).lineStyle(.init(lineWidth: 4.5, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear)
    LineMark(x: x, y: y, series: .value("s", series)).foregroundStyle(color).lineStyle(.init(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).interpolationMethod(smooth ? .catmullRom : .linear)
}

/// 發光點：大暈 + 小實點
@ChartContentBuilder
func glowPoint<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, color: Color, size: CGFloat = 40) -> some ChartContent {
    PointMark(x: x, y: y).foregroundStyle(color.opacity(0.18)).symbolSize(size * 4)
    PointMark(x: x, y: y).foregroundStyle(color.opacity(0.45)).symbolSize(size * 1.8)
    PointMark(x: x, y: y).foregroundStyle(color).symbolSize(size)
}

/// 所有圖共用的底：深色 plot 背景、淡格線、隱藏 X 軸
struct NeonPlot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.45))
            } }
            .chartPlotStyle { $0.background(Neon.plotBG).clipShape(RoundedRectangle(cornerRadius: 6)) }
    }
}
extension View { func neonPlot() -> some View { modifier(NeonPlot()) } }

// MARK: - 畫面

struct PanelView: View {
    var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = monitor.snapshot {
                header(s)
                tempCard(s)
                sensorGrid
                fanCard(s)
                if s.pcoreMHz != nil { freqCard(s) }
                timeAxis
                statsRow(s)
                controls(s)
                soundCard
                applyBar
                footer
            } else {
                Text("讀取 SMC 中…").padding()
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Neon.panelBG)
        .preferredColorScheme(.dark)
        .onAppear { monitor.tick() }
    }

    /// 標題列：名稱 + 狀態 chip，下面一行「結論」——現在能不能全力開工
    func header(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("cool91").font(.headline)
                Spacer()
                if let b = s.boostUntil, b > Date() {
                    chipLabel("預熱 \(Int(b.timeIntervalSinceNow))s", Neon.cyan)
                }
                chipLabel(s.guardRunning ? "guard 執行中" : "guard 未執行", s.guardRunning ? Color.white.opacity(0.6) : Neon.amber)
            }
            statusLine(s)
            if let top = s.topProcesses, !top.isEmpty { busyLine(top) }
        }
    }

    /// 現在誰在吃 CPU：前兩名，一行
    func busyLine(_ top: [TopProcess]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(top.prefix(2).enumerated()), id: \.offset) { i, p in
                if i > 0 { Text("·").foregroundStyle(.quaternary) }
                Text(String(format: "%.0f%%", p.cpuPercent)).font(.system(.caption2, design: .rounded).weight(.semibold)).foregroundStyle(Neon.cyan)
                Text(p.command).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let d = p.cwd { Text(d).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }

    func chipLabel(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14)).clipShape(Capsule())
    }

    /// 一句話結論：全速 / 降頻中 / 溫度危險 / 沒有頻率資料
    func statusLine(_ s: Snapshot) -> some View {
        let (icon, text, color): (String, String, Color) = {
            if !s.guardRunning { return ("exclamationmark.triangle.fill", "guard 沒在跑，風扇由 macOS 控制", Neon.amber) }
            if s.level == .critical { return ("flame.fill", String(format: "溫度 %.0f°C 已達 critical，hook 會擋下工作", s.controlTemp), Neon.red) }
            if s.throttling { return ("tortoise.fill", "降頻中（\(s.thermalPressure ?? "")）· hook 會讓工作等", Neon.red) }
            if s.gpuThrottling { return ("tortoise.fill", String(format: "GPU 熱降頻中（CLTM %.0f%%）· hook 會讓工作等", s.gpuThrottlePercent ?? 0), Neon.red) }
            if s.pcoreMHz == nil { return ("questionmark.circle", "沒有頻率資料，改用溫度判斷（\(s.level.label)）", Neon.amber) }
            if (s.pcoreMHz ?? 0) < 100 { return ("moon.zzz.fill", "閒置 · 未降頻", Neon.green) }
            return ("bolt.fill", String(format: "全速運作 %.2f GHz · 未降頻", (s.pcoreMHz ?? 0) / 1000), Neon.green)
        }()
        return HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(color).shadow(color: color.opacity(0.8), radius: 4)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            Spacer()
            if let st = s.stats, st.throttleSeconds > 0 {
                Text("今日降頻 \(Format.hms(st.throttleSeconds))").font(.caption2).foregroundStyle(Neon.red)
            }
        }
    }

    // MARK: 三張卡：標題 + 目前值 + 5 分鐘曲線

    var window: ClosedRange<Date> { Date().addingTimeInterval(-History.keep)...Date() }

    func card<Chart: View>(title: String, @ViewBuilder value: () -> some View, @ViewBuilder chart: () -> Chart) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                value()
            }
            chart()
        }
        .padding(8)
        .background(Neon.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func bigValue(_ v: String, _ color: Color, unit: String = "") -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(v).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(color).shadow(color: color.opacity(0.5), radius: 5)
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    func tempCard(_ s: Snapshot) -> some View {
        card(title: "溫度") {
            HStack(spacing: 10) {
                HStack(spacing: 4) { legend("CPU", Neon.cyan); bigValue(String(format: "%.0f°", s.cpuMax), Neon.cyan) }
                HStack(spacing: 4) {
                    legend("GPU", Neon.green); bigValue(String(format: "%.0f°", s.gpuMax), Neon.green)
                    if let a = s.gpuActive { Text(String(format: "%.0f%%", a)).font(.caption2).foregroundStyle(.secondary) }
                    if s.gpuThrottling { chipLabel("降頻", Neon.red) }
                }
                if let ssd = s.ssd { Text(String(format: "SSD %.0f°", ssd)).font(.caption2).foregroundStyle(.secondary) }
            }
        } chart: {
            Chart {
                RuleMark(y: .value("hot", monitor.config.hotTemp)).foregroundStyle(Neon.amber.opacity(0.35)).lineStyle(.init(dash: [3]))
                RuleMark(y: .value("crit", monitor.config.criticalTemp)).foregroundStyle(Neon.red.opacity(0.35)).lineStyle(.init(dash: [3]))
                ForEach(monitor.history, id: \.time) { p in
                    AreaMark(x: .value("t", p.time), yStart: .value("b", 30), yEnd: .value("cpu", p.cpu), series: .value("s", "cpu•a"))
                        .foregroundStyle(Neon.fade(Neon.cyan, top: 0.35)).interpolationMethod(.catmullRom)
                }
                ForEach(monitor.history, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("gpu", p.gpu), series: "gpu", color: Neon.green)
                }
                ForEach(monitor.history, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("cpu", p.cpu), series: "cpu", color: Neon.cyan)
                }
                if let last = monitor.history.last {
                    glowPoint(x: .value("t", last.time), y: .value("cpu", last.cpu), color: Neon.cyan, size: 14)
                    glowPoint(x: .value("t", last.time), y: .value("gpu", last.gpu), color: Neon.green, size: 14)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 30...110)
            .neonPlot()
            .frame(height: 84)
        }
    }

    /// 各感測器熱度格：P-core / E-core / GPU 三組，一格一個感測器，顏色隨溫度；滑過看 key 與度數
    var sensorGrid: some View {
        DisclosureGroup(isExpanded: Binding(get: { monitor.showSensors }, set: { monitor.showSensors = $0 })) {
            VStack(alignment: .leading, spacing: 6) {
                sensorGroup("P-core", prefix: "Tp")
                sensorGroup("E-core", prefix: "Te")
                sensorGroup("GPU", prefix: "Tg")
                HStack(spacing: 6) {
                    ForEach([40, 60, 80, 95], id: \.self) { t in
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2).fill(tempColor(Double(t))).frame(width: 8, height: 8)
                            Text("\(t)°").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text("風扇看的是最熱那一格").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("各感測器").font(.caption2).foregroundStyle(.secondary)
                if monitor.showSensors {
                    Text("\(monitor.sensorTemps.count) 個").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Neon.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func sensorGroup(_ name: String, prefix: String) -> some View {
        let items = monitor.sensorTemps.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        let hi = items.map(\.value).max()
        let avg = items.isEmpty ? nil : items.map(\.value).reduce(0, +) / Double(items.count)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                if let hi, let avg {
                    Text(String(format: "最熱 %.0f°", hi)).font(.system(size: 10, design: .monospaced)).foregroundStyle(tempColor(hi))
                    Text(String(format: "平均 %.0f°", avg)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                } else {
                    Text("—").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("×\(items.count)").font(.system(size: 9)).foregroundStyle(.quaternary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 13, maximum: 13), spacing: 3)], alignment: .leading, spacing: 3) {
                ForEach(items, id: \.key) { k, t in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tempColor(t))
                        .frame(width: 13, height: 13)
                        .shadow(color: t >= monitor.config.hotTemp ? tempColor(t).opacity(0.7) : .clear, radius: 3)
                        .help(String(format: "%@  %.1f°C", k, t))
                }
            }
        }
    }

    /// 溫度 → 顏色：40 藍青、60 綠、80 琥珀、95+ 紅，中間線性混色
    func tempColor(_ t: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (40, (0.16, 0.55, 0.96)), (60, (0.36, 0.95, 0.55)), (80, (1.00, 0.72, 0.30)), (95, (1.00, 0.36, 0.42)),
        ]
        if t <= stops[0].0 { let c = stops[0].1; return Color(red: c.0, green: c.1, blue: c.2) }
        if t >= stops.last!.0 { let c = stops.last!.1; return Color(red: c.0, green: c.1, blue: c.2) }
        for i in 1..<stops.count where t <= stops[i].0 {
            let (a, b) = (stops[i - 1], stops[i])
            let f = (t - a.0) / (b.0 - a.0)
            return Color(red: a.1.0 + (b.1.0 - a.1.0) * f, green: a.1.1 + (b.1.1 - a.1.1) * f, blue: a.1.2 + (b.1.2 - a.1.2) * f)
        }
        return Neon.cyan
    }

    func fanCard(_ s: Snapshot) -> some View {
        let f = s.fans.first
        return card(title: "風扇") {
            HStack(spacing: 8) {
                if let f, f.manual { Text(String(format: "目標 %.0f", f.target)).font(.caption2).foregroundStyle(.secondary) }
                else { Text("macOS 自動").font(.caption2).foregroundStyle(.secondary) }
                bigValue(String(format: "%.0f", f?.rpm ?? 0), Neon.purple, unit: "rpm")
            }
        } chart: {
            Chart {
                ForEach(monitor.history, id: \.time) { p in
                    AreaMark(x: .value("t", p.time), y: .value("rpm", p.rpm), series: .value("s", "rpm•a"))
                        .foregroundStyle(Neon.fade(Neon.purple, top: 0.5)).interpolationMethod(.catmullRom)
                }
                ForEach(monitor.history.filter { $0.target != nil }, id: \.time) { p in
                    LineMark(x: .value("t", p.time), y: .value("target", p.target ?? 0), series: .value("s", "target"))
                        .foregroundStyle(Color.white.opacity(0.35)).lineStyle(.init(lineWidth: 1, dash: [2, 3]))
                }
                ForEach(monitor.history, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("rpm", p.rpm), series: "rpm", color: Neon.purple)
                }
                if let last = monitor.history.last {
                    glowPoint(x: .value("t", last.time), y: .value("rpm", last.rpm), color: Neon.purple, size: 14)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 0...(f?.max ?? 5000))
            .chartYAxis { AxisMarks(position: .trailing, values: [1000, 2000, 3000, 4000]) { v in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel { if let r = v.as(Int.self) { Text("\(r / 1000)k").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.45)) } }
            } }
            .chartXAxis(.hidden)
            .chartPlotStyle { $0.background(Neon.plotBG).clipShape(RoundedRectangle(cornerRadius: 6)) }
            .frame(height: 56)
        }
    }

    func freqCard(_ s: Snapshot) -> some View {
        let p = s.pcoreMHz ?? 0
        let idle = p < 100
        return card(title: "P-core 頻率") {
            HStack(spacing: 8) {
                if s.throttling { chipLabel("降頻 \(s.thermalPressure ?? "")", Neon.red) }
                else if !idle, let e = s.ecoreMHz { Text(String(format: "E %.1f", e / 1000)).font(.caption2).foregroundStyle(.secondary) }
                if idle { bigValue("閒置", .secondary) }
                else { bigValue(String(format: "%.2f", p / 1000), s.throttling ? Neon.red : Neon.green, unit: "GHz") }
            }
        } chart: {
            Chart {
                ForEach(monitor.history.filter { ($0.pMHz ?? 0) >= 100 }, id: \.time) { p in   // 閒置（0）不畫，留缺口
                    AreaMark(x: .value("t", p.time), yStart: .value("b", 0.9), yEnd: .value("GHz", (p.pMHz ?? 0) / 1000), series: .value("s", "p•a"))
                        .foregroundStyle(Neon.fade(Neon.green, top: 0.3)).interpolationMethod(.catmullRom)
                }
                ForEach(monitor.history.filter { ($0.pMHz ?? 0) >= 100 }, id: \.time) { p in
                    glowLine(x: .value("t", p.time), y: .value("GHz", (p.pMHz ?? 0) / 1000), series: "p", color: Neon.green)
                }
                if let last = monitor.history.last, (last.pMHz ?? 0) >= 100 {
                    glowPoint(x: .value("t", last.time), y: .value("GHz", (last.pMHz ?? 0) / 1000), color: Neon.green, size: 14)
                }
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 0.9...4.5)
            .neonPlot()
            .frame(height: 56)
        }
    }

    /// 三張卡共用的時間軸
    var timeAxis: some View {
        HStack {
            Text("5 分鐘前").font(.system(size: 9)).foregroundStyle(.quaternary)
            Spacer()
            Text("現在").font(.system(size: 9)).foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 8)
        .padding(.top, -6)
    }

    func legend(_ name: String, _ color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 3) {
            if dashed {
                Rectangle().fill(color).frame(width: 10, height: 1).overlay(Rectangle().stroke(style: .init(lineWidth: 1, dash: [2, 2])).foregroundStyle(color))
            } else {
                Capsule().fill(color).frame(width: 10, height: 2).shadow(color: color.opacity(0.8), radius: 2)
            }
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func statsRow(_ s: Snapshot) -> some View {
        if let st = s.stats {
            HStack(spacing: 10) {
                stat("今日最高", String(format: "%.0f°", st.maxTemp), color: monitor.config.level(for: st.maxTemp).neon)
                stat("hot", Format.hms(st.hotSeconds), color: st.hotSeconds > 0 ? Neon.amber : .secondary)
                stat("critical", Format.hms(st.criticalSeconds), color: st.criticalSeconds > 0 ? Neon.red : .secondary)
                stat("降頻", Format.hms(st.throttleSeconds), color: st.throttleSeconds > 0 ? Neon.red : .secondary)
                stat("hook 等/擋", "\(st.hookWaits)/\(st.hookDenies)", color: .secondary)
                stat("預熱", "\(st.boosts)", color: .secondary)
            }
            .font(.caption2)
            .padding(.vertical, 6).padding(.horizontal, 4)
            .background(Neon.cardBG)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    func stat(_ name: String, _ v: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 控制區

    /// draft 曲線對應到哪個預設（沒有就是自訂）
    var currentPresetName: String? {
        let d = monitor.draft.curve.map { [$0.temp, $0.rpm] }
        return Monitor.presets.first { $0.1.map { [$0.temp, $0.rpm] } == d }?.0
    }

    @ViewBuilder
    func controls(_ s: Snapshot) -> some View {
        let fmin = s.fans.first?.min ?? 1000
        let fmax = s.fans.first?.max ?? 4900
        VStack(alignment: .leading, spacing: 8) {
            // 標題列：模式 + 狀態
            HStack {
                Text("風扇控制").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !s.guardRunning {
                    Label("guard 未執行", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                } else if monitor.fanDirty {
                    Text("未套用").font(.caption2).foregroundStyle(.orange)
                }
            }
            Picker("模式", selection: Binding(get: { monitor.draft.mode }, set: { monitor.draft.mode = $0 })) {
                Text("曲線").tag("curve")
                Text("固定").tag("fixed")
                Text("自動").tag("auto")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch monitor.draft.mode {
            case "fixed":
                curvePreview(s, fixed: monitor.draft.fixedRPM, fmin: fmin, fmax: fmax)
                HStack {
                    Slider(value: Binding(get: { monitor.draft.fixedRPM }, set: { monitor.draft.fixedRPM = ($0 / 50).rounded() * 50 }),
                           in: fmin...fmax)
                    Text("\(Int(monitor.draft.fixedRPM)) rpm").font(.system(.caption, design: .monospaced)).frame(width: 64, alignment: .trailing)
                }
            case "curve":
                curvePreview(s, fixed: nil, fmin: fmin, fmax: fmax)
                presetChips
                DisclosureGroup {
                    VStack(spacing: 4) {
                        ForEach(monitor.draft.curve.indices, id: \.self) { i in
                            HStack(spacing: 6) {
                                Stepper(value: Binding(get: { monitor.draft.curve[i].temp }, set: { monitor.draft.curve[i].temp = $0 }), in: 40...105, step: 1) {
                                    Text("\(Int(monitor.draft.curve[i].temp))°").font(.system(.caption, design: .monospaced)).frame(width: 34, alignment: .trailing)
                                }
                                Slider(value: Binding(get: { monitor.draft.curve[i].rpm }, set: { monitor.draft.curve[i].rpm = ($0 / 50).rounded() * 50 }),
                                       in: fmin...fmax)
                                Text("\(Int(monitor.draft.curve[i].rpm))").font(.system(.caption, design: .monospaced)).frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(currentPresetName.map { "微調「\($0)」的點" } ?? "編輯自訂曲線的點").font(.caption)
                }
            default:
                Text("風扇交回 macOS 自己管。M4 mini 原廠策略很保守：CPU 到 100°C 才加速，重載 10–15 分鐘後會降頻。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(get: { monitor.draft.includeGPU }, set: { monitor.draft.includeGPU = $0 })) {
                Text("GPU 溫度也納入").font(.caption2).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox).controlSize(.mini)
        }
        .padding(10)
        .background(Neon.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 三組預設：選中的填色，自訂時全部不亮並多一個「自訂」
    var presetChips: some View {
        HStack(spacing: 6) {
            ForEach(Monitor.presets, id: \.0) { name, pts in
                chip(name, selected: currentPresetName == name) { monitor.draft.curve = pts }
            }
            if currentPresetName == nil { chip("自訂", selected: true) {} }
            Spacer()
        }
    }

    func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? AnyShapeStyle(Neon.sweep(Neon.cyan, Neon.violet)) : AnyShapeStyle(Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
                .shadow(color: selected ? Neon.cyan.opacity(0.5) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
    }

    /// 曲線預覽：X 溫度、Y 轉速；畫 draft 曲線、hot/critical 門檻、目前溫度與風扇位置
    func curvePreview(_ s: Snapshot, fixed: Double?, fmin: Double, fmax: Double) -> some View {
        let pts = monitor.draft.curve.sorted { $0.temp < $1.temp }
        let tNow = min(max(s.controlTemp, 40), 108)
        let rpmNow = s.fans.first?.rpm ?? fmin
        // 曲線兩端延伸到圖的邊界
        let ext: [(Double, Double)] = pts.isEmpty ? [] : [(40, pts.first!.rpm)] + pts.map { ($0.temp, $0.rpm) } + [(108, pts.last!.rpm)]
        return Chart {
            RuleMark(x: .value("hot", monitor.config.hotTemp)).foregroundStyle(Neon.amber.opacity(0.3)).lineStyle(.init(dash: [3]))
            RuleMark(x: .value("crit", monitor.config.criticalTemp)).foregroundStyle(Neon.red.opacity(0.3)).lineStyle(.init(dash: [3]))
            if let fixed {
                AreaMark(x: .value("t", 40), yStart: .value("a", fmin), yEnd: .value("rpm", fixed), series: .value("s", "fa")).foregroundStyle(Neon.fade(Neon.cyan, top: 0.3))
                AreaMark(x: .value("t", 108), yStart: .value("a", fmin), yEnd: .value("rpm", fixed), series: .value("s", "fa")).foregroundStyle(Neon.fade(Neon.cyan, top: 0.3))
                glowLine(x: .value("t", 40.0), y: .value("rpm", fixed), series: "f", color: Neon.cyan, smooth: false)
                glowLine(x: .value("t", 108.0), y: .value("rpm", fixed), series: "f", color: Neon.cyan, smooth: false)
            } else {
                ForEach(Array(ext.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("t", p.0), yStart: .value("a", fmin), yEnd: .value("rpm", p.1), series: .value("s", "a")).foregroundStyle(Neon.fade(Neon.cyan, top: 0.35))
                }
                ForEach(Array(ext.enumerated()), id: \.offset) { _, p in
                    glowLine(x: .value("t", p.0), y: .value("rpm", p.1), series: "c", color: Neon.cyan, smooth: false)
                }
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    PointMark(x: .value("t", p.temp), y: .value("rpm", p.rpm)).foregroundStyle(Neon.cyan).symbolSize(14)
                }
            }
            // 目前位置
            RuleMark(x: .value("now", tNow)).foregroundStyle(s.level.neon.opacity(0.45)).lineStyle(.init(lineWidth: 1))
            glowPoint(x: .value("now", tNow), y: .value("rpm", rpmNow), color: s.level.neon, size: 28)
            PointMark(x: .value("now", tNow), y: .value("rpm", rpmNow)).opacity(0)
                .annotation(position: tNow > 85 ? .leading : .trailing, alignment: .center, spacing: 6) {
                    Text(String(format: "%.0f° · %.0f rpm", s.controlTemp, rpmNow)).font(.system(size: 9, design: .monospaced)).foregroundStyle(s.level.neon)
                }
        }
        .chartXScale(domain: 40...108)
        .chartYScale(domain: fmin...fmax)
        .chartXAxis { AxisMarks(values: [50, 60, 70, 80, 90, 100]) { v in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.05))
            AxisValueLabel { if let t = v.as(Int.self) { Text("\(t)°").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.45)) } }
        } }
        .chartYAxis { AxisMarks(position: .trailing, values: [1000, 2000, 3000, 4000]) { v in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
            AxisValueLabel { if let r = v.as(Int.self) { Text("\(r / 1000)k").font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.45)) } }
        } }
        .chartPlotStyle { $0.background(Neon.plotBG).clipShape(RoundedRectangle(cornerRadius: 6)) }
        .frame(height: 100)
    }

    /// 提示音卡：熱 / 冷兩列，每列 = 開關（即時生效）+ ▶ 試聽 + 觸發門檻（走「套用」寫進 config）
    var soundCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
                Text("提示音").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if monitor.soundDirty { Text("未套用").font(.caption2).foregroundStyle(.orange) }
            }
            soundLine("過熱 / 降頻", Neon.red, hot: true,
                      isOn: Binding(get: { monitor.hotSoundOn }, set: { monitor.hotSoundOn = $0 }),
                      threshold: Binding(get: { monitor.draftOverheatAbove }, set: { monitor.draftOverheatAbove = $0 }),
                      range: (monitor.draftCooldownBelow + 1)...105, prefix: "≥")
            soundLine("降溫回穩", Neon.green, hot: false,
                      isOn: Binding(get: { monitor.coldSoundOn }, set: { monitor.coldSoundOn = $0 }),
                      threshold: Binding(get: { monitor.draftCooldownBelow }, set: { monitor.draftCooldownBelow = $0 }),
                      range: 40...(monitor.draftOverheatAbove - 1), prefix: "<")
            Text("CPU / GPU 一降頻就算過熱，不看溫度。門檻獨立於風扇與 hook 的 hot 線。")
                .font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Neon.cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func soundLine(_ title: String, _ color: Color, hot: Bool, isOn: Binding<Bool>, threshold: Binding<Double>,
                   range: ClosedRange<Double>, prefix: String) -> some View {
        let file = monitor.soundPath(hot: hot)
        return HStack(spacing: 4) {
            Toggle(isOn: isOn) { Text(title).font(.caption2).foregroundStyle(isOn.wrappedValue ? color : .secondary) }
                .toggleStyle(.checkbox).controlSize(.mini)
            Button { monitor.play(hot: hot) } label: {
                Image(systemName: "play.circle").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("試聽：" + (file.map { ($0 as NSString).lastPathComponent } ?? "系統音 \(hot ? Monitor.hotSound : Monitor.coldSound)"))
            Spacer()
            Stepper(value: threshold, in: range, step: 1) {
                Text("\(prefix) \(Int(threshold.wrappedValue))°")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .controlSize(.mini)
            .disabled(!isOn.wrappedValue)
        }
    }

    /// 全域套用列：風扇或提示音任一有改動才出現，一次寫回設定檔
    @ViewBuilder
    var applyBar: some View {
        if monitor.dirty || monitor.saveMessage != nil {
            HStack {
                if let m = monitor.saveMessage {
                    Text(m).font(.caption2).foregroundStyle(m.hasPrefix("寫入失敗") ? .red : .secondary)
                } else if monitor.dirty {
                    Text("有未套用的變更").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button("還原") { monitor.revert() }.disabled(!monitor.dirty)
                Button("套用") { monitor.apply() }.disabled(!monitor.dirty).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 4)
        }
    }

    var footer: some View {
        HStack {
            Button("看 log") { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/cool91.log")) }
            Text("·").foregroundStyle(.quaternary)
            Button("設定檔") { NSWorkspace.shared.selectFile(monitor.config.loadedFrom ?? "/etc/cool91/config.json", inFileViewerRootedAtPath: "") }
            Spacer()
            Text("cool91 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").font(.caption2).foregroundStyle(.quaternary)
            Button("重啟") { monitor.relaunch() }.help("重新啟動面板")
            Text("·").foregroundStyle(.quaternary)
            Button("結束") { NSApp.terminate(nil) }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
