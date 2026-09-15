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

    init() {
        try? SMC.open()
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
        // guard 在跑：只讀快照檔；沒跑才自己開 SMC
        let s = Snapshot.takeFast(config: config)
        snapshot = s
        let open = windowVisible
        if open != panelOpen { panelOpen = open; return }   // didSet 會再叫一次 tick
        guard panelOpen else { return }
        if s.guardRunning {
            history = History.load()
        } else {
            localHistory.append(HistoryPoint(time: s.time, cpu: s.cpuMax, gpu: s.gpuMax, rpm: s.fans.first?.rpm ?? 0, target: nil))
            localHistory.removeAll { Date().timeIntervalSince($0.time) > History.keep }
            history = localHistory
        }
    }

    /// 外部（手動編輯、另一台面板）改了設定檔也跟上
    func reloadConfig() {
        let fresh = Config.load(path: nil)
        if !dirty { draft = fresh }
        config = fresh
    }

    var dirty: Bool {
        draft.mode != config.mode || draft.fixedRPM != config.fixedRPM || draft.includeGPU != config.includeGPU ||
        draft.curve.map { [$0.temp, $0.rpm] } != config.curve.map { [$0.temp, $0.rpm] }
    }

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

// MARK: - 畫面

struct PanelView: View {
    var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = monitor.snapshot {
                header(s)
                tiles(s)
                fanRow(s)
                tempChart
                fanChart
                if s.pcoreMHz != nil { freqChart }
                statsRow(s)
                controls(s)
                footer
            } else {
                Text("讀取 SMC 中…").padding()
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { monitor.tick() }
    }

    func header(_ s: Snapshot) -> some View {
        HStack {
            Text("cool91").font(.headline)
            Spacer()
            Text(s.level.label)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(s.level.color.opacity(0.25))
                .foregroundStyle(s.level.color)
                .clipShape(Capsule())
            if s.throttling {
                Text("降頻中").font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.red.opacity(0.25)).foregroundStyle(.red).clipShape(Capsule())
            }
            if let b = s.boostUntil, b > Date() {
                Text("預熱 \(Int(b.timeIntervalSinceNow))s").font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.teal.opacity(0.2)).clipShape(Capsule())
            }
            Text(s.guardRunning ? "guard 執行中" : "guard 未執行")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    func tiles(_ s: Snapshot) -> some View {
        HStack(spacing: 6) {
            tile("CPU", String(format: "%.0f°", s.cpuMax), sub: String(format: "avg %.0f°", s.cpuAvg), color: s.level.color)
            tile("GPU", String(format: "%.0f°", s.gpuMax), sub: "最高", color: .blue)
            tile("SSD", String(format: "%.0f°", s.ssd ?? 0), sub: "", color: .teal)
            if let p = s.pcoreMHz {
                // P-core 硬體頻率：M4 滿載正常 3.9–4.4，掉到 3.8 以下且 pressure 非 Nominal = 熱降頻；cluster 閒置時韌體回 0
                let idle = p < 100
                tile("P-core", idle ? "閒置" : String(format: "%.2f", p / 1000),
                     sub: s.throttling ? "降頻 " + (s.thermalPressure ?? "") : idle ? "GHz" : String(format: "GHz · E %.1f", (s.ecoreMHz ?? 0) / 1000),
                     color: s.throttling ? .red : idle ? .secondary : .purple)
            }
        }
    }

    func tile(_ name: String, _ v: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func fanRow(_ s: Snapshot) -> some View {
        ForEach(s.fans, id: \.index) { f in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "fan.fill")
                    Text(String(format: "%.0f rpm", f.rpm)).font(.system(.title3, design: .rounded).weight(.semibold))
                    Spacer()
                    Text(f.manual ? String(format: "目標 %.0f · 手動", f.target) : "自動")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: max(0, f.rpm - f.min), total: max(1, f.max - f.min))
                HStack {
                    Text(String(format: "%.0f", f.min)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", f.max)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    var tempChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CPU 溫度（5 分鐘）").font(.caption).foregroundStyle(.secondary)
            Chart {
                RuleMark(y: .value("hot", monitor.config.hotTemp)).foregroundStyle(.orange.opacity(0.4)).lineStyle(.init(dash: [3]))
                RuleMark(y: .value("crit", monitor.config.criticalTemp)).foregroundStyle(.red.opacity(0.4)).lineStyle(.init(dash: [3]))
                ForEach(monitor.history, id: \.time) { p in
                    LineMark(x: .value("t", p.time), y: .value("cpu", p.cpu), series: .value("s", "cpu")).foregroundStyle(.orange)
                    LineMark(x: .value("t", p.time), y: .value("gpu", p.gpu), series: .value("s", "gpu")).foregroundStyle(.blue)
                }
            }
            .chartYScale(domain: 30...110)
            .chartXAxis(.hidden)
            .frame(height: 80)
        }
    }

    var fanChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("風扇轉速").font(.caption).foregroundStyle(.secondary)
            Chart(monitor.history, id: \.time) { p in
                AreaMark(x: .value("t", p.time), y: .value("rpm", p.rpm)).foregroundStyle(.teal.opacity(0.3))
                LineMark(x: .value("t", p.time), y: .value("rpm", p.rpm), series: .value("s", "rpm")).foregroundStyle(.teal)
                if let t = p.target {
                    LineMark(x: .value("t", p.time), y: .value("target", t), series: .value("s", "target"))
                        .foregroundStyle(.secondary.opacity(0.5)).lineStyle(.init(dash: [2, 3]))
                }
            }
            .chartYScale(domain: 0...(monitor.snapshot?.fans.first?.max ?? 5000))
            .chartXAxis(.hidden)
            .frame(height: 50)
        }
    }

    var freqChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("P-core 頻率（GHz）").font(.caption).foregroundStyle(.secondary)
            Chart(monitor.history.filter { ($0.pMHz ?? 0) >= 100 }, id: \.time) { p in   // 閒置（0）不畫，留缺口
                LineMark(x: .value("t", p.time), y: .value("GHz", (p.pMHz ?? 0) / 1000), series: .value("s", "p")).foregroundStyle(.purple)
            }
            .chartYScale(domain: 0.9...4.5)
            .chartXAxis(.hidden)
            .frame(height: 50)
        }
    }

    @ViewBuilder
    func statsRow(_ s: Snapshot) -> some View {
        if let st = s.stats {
            HStack(spacing: 10) {
                stat("今日最高", String(format: "%.0f°", st.maxTemp), color: monitor.config.level(for: st.maxTemp).color)
                stat("hot", Format.hms(st.hotSeconds), color: st.hotSeconds > 0 ? .orange : .secondary)
                stat("critical", Format.hms(st.criticalSeconds), color: st.criticalSeconds > 0 ? .red : .secondary)
                stat("降頻", Format.hms(st.throttleSeconds), color: st.throttleSeconds > 0 ? .red : .secondary)
                stat("hook 等/擋", "\(st.hookWaits)/\(st.hookDenies)", color: .secondary)
            }
            .font(.caption2)
        }
    }

    func stat(_ name: String, _ v: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.system(.caption, design: .rounded).weight(.semibold)).foregroundStyle(color)
            Text(name).foregroundStyle(.secondary)
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
                } else if monitor.dirty {
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

            // 套用列：有改動才出現
            if monitor.dirty || monitor.saveMessage != nil {
                HStack {
                    if let m = monitor.saveMessage { Text(m).font(.caption2).foregroundStyle(m.hasPrefix("寫入失敗") ? .red : .secondary) }
                    Spacer()
                    Button("還原") { monitor.revert() }.disabled(!monitor.dirty)
                    Button("套用") { monitor.apply() }.disabled(!monitor.dirty).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
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
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 曲線預覽：X 溫度、Y 轉速；畫 draft 曲線、hot/critical 門檻、目前溫度與風扇位置
    func curvePreview(_ s: Snapshot, fixed: Double?, fmin: Double, fmax: Double) -> some View {
        let pts = monitor.draft.curve.sorted { $0.temp < $1.temp }
        let tNow = min(max(s.controlTemp, 40), 108)
        let rpmNow = s.fans.first?.rpm ?? fmin
        return Chart {
            RuleMark(x: .value("hot", monitor.config.hotTemp)).foregroundStyle(.orange.opacity(0.35)).lineStyle(.init(dash: [3]))
            RuleMark(x: .value("crit", monitor.config.criticalTemp)).foregroundStyle(.red.opacity(0.35)).lineStyle(.init(dash: [3]))
            if let fixed {
                RuleMark(y: .value("rpm", fixed)).foregroundStyle(.teal)
            } else {
                // 曲線兩端延伸到圖的邊界
                if let f = pts.first { LineMark(x: .value("t", 40), y: .value("rpm", f.rpm), series: .value("s", "c")).foregroundStyle(.teal) }
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.temp), y: .value("rpm", p.rpm), series: .value("s", "c")).foregroundStyle(.teal)
                    PointMark(x: .value("t", p.temp), y: .value("rpm", p.rpm)).foregroundStyle(.teal).symbolSize(20)
                }
                if let l = pts.last { LineMark(x: .value("t", 108), y: .value("rpm", l.rpm), series: .value("s", "c")).foregroundStyle(.teal) }
                AreaMark(x: .value("t", 40), yStart: .value("a", fmin), yEnd: .value("rpm", pts.first?.rpm ?? fmin), series: .value("s", "a")).foregroundStyle(.teal.opacity(0.08))
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("t", p.temp), yStart: .value("a", fmin), yEnd: .value("rpm", p.rpm), series: .value("s", "a")).foregroundStyle(.teal.opacity(0.08))
                }
                AreaMark(x: .value("t", 108), yStart: .value("a", fmin), yEnd: .value("rpm", pts.last?.rpm ?? fmin), series: .value("s", "a")).foregroundStyle(.teal.opacity(0.08))
            }
            // 目前位置
            RuleMark(x: .value("now", tNow)).foregroundStyle(s.level.color.opacity(0.5)).lineStyle(.init(lineWidth: 1))
            PointMark(x: .value("now", tNow), y: .value("rpm", rpmNow)).foregroundStyle(s.level.color).symbolSize(45)
                .annotation(position: tNow > 85 ? .leading : .trailing, alignment: .center, spacing: 4) {
                    Text(String(format: "%.0f° · %.0f rpm", s.controlTemp, rpmNow)).font(.system(size: 9, design: .monospaced)).foregroundStyle(s.level.color)
                }
        }
        .chartXScale(domain: 40...108)
        .chartYScale(domain: fmin...fmax)
        .chartXAxis { AxisMarks(values: [50, 60, 70, 80, 90, 100]) { v in AxisValueLabel { if let t = v.as(Int.self) { Text("\(t)°").font(.system(size: 9)) } } } }
        .chartYAxis { AxisMarks(values: [1000, 2000, 3000, 4000]) { v in AxisGridLine().foregroundStyle(.secondary.opacity(0.15)); AxisValueLabel { if let r = v.as(Int.self) { Text("\(r / 1000)k").font(.system(size: 9)) } } } }
        .frame(height: 96)
    }

    var footer: some View {
        HStack {
            Button("看 log") { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/cool91.log")) }
            Text("·").foregroundStyle(.quaternary)
            Button("設定檔") { NSWorkspace.shared.selectFile(monitor.config.loadedFrom ?? "/etc/cool91/config.json", inFileViewerRootedAtPath: "") }
            Spacer()
            Text("cool91 0.2").font(.caption2).foregroundStyle(.quaternary)
            Button("結束") { NSApp.terminate(nil) }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
