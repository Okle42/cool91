import Foundation
import Cool91Core

// MARK: - hook

/// Claude Code PreToolUse hook（讓機器全力開工、風扇負責避免降頻；只有「真的降頻了」才讓工作等）：
///   pressure Nominal        → 放行，不管溫度（重指令先發預熱事件）
///   pressure Moderate/Heavy → 等它回 Nominal（最多 hookWaitSeconds，且不超過 hookWaitCap），之後放行並附說明
///   pressure Trapping / 溫度 critical → 依設定擋下（deny）
///   拿不到 pressure（guard 沒跑）→ 退回溫度門檻：hot 等、critical 擋
///   白名單指令（cool91 / kill / …）任何等級都放行，否則 critical 時連降溫指令都跑不了
func runHook(config: Config) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    var command = ""
    if let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
       let ti = obj["tool_input"] as? [String: Any], let c = ti["command"] as? String {
        command = c
    }
    let allowed = !command.isEmpty && Policy.commandIsAllowed(command, allow: config.hookAllowCommands)
    if !command.isEmpty, Policy.commandNeedsBoost(command, keywords: config.boostCommands) {
        Event(kind: .boost, rpm: config.boostRPM, seconds: config.boostSeconds, note: String(command.prefix(60))).post()
    }

    var s = Snapshot.takeFast(config: config)
    var waited = 0.0
    func verdict(_ s: Snapshot) -> (wait: Bool, block: Bool) { Policy.verdict(s, config: config) }
    var v = verdict(s)
    if v.wait && !allowed {
        let start = Date()
        let deadline = start.addingTimeInterval(min(config.hookWaitSeconds, Config.hookWaitCap))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 2)
            s = Snapshot.takeFast(config: config)
            v = verdict(s)
            if !v.wait { break }
        }
        waited = Date().timeIntervalSince(start)
        Event(kind: .hookWait, seconds: waited).post()
    }
    var out: [String: Any] = [:]
    var note = String(format: "cool91 %@ %.0f°C 風扇 %.0f rpm", s.level.emoji, s.controlTemp, s.fans.first?.rpm ?? 0)
    if let p = s.pcoreMHz { note += String(format: " P-core %.2f GHz", p / 1000) }
    if let pr = s.thermalPressure { note += " pressure \(pr)" }
    if v.wait && v.block && !allowed {
        Event(kind: .hookDeny).post()
        let why = s.level == .critical ? "溫度已達 critical（≥\(Int(config.criticalTemp))°C）" : "thermal pressure \(s.thermalPressure ?? "?")"
        out["hookSpecificOutput"] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "\(note)：\(why)，等了 \(Int(waited)) 秒仍未恢復。先讓機器冷卻再重試（`cool91 wait` 與 kill/pkill 等降溫指令不受限）。",
        ]
    } else if allowed && v.wait {
        out["systemMessage"] = "\(note)：白名單指令放行。"
    } else if waited >= 1 {
        out["systemMessage"] = "\(note)：剛才降頻中，已等待 \(Int(waited)) 秒\(v.wait ? "仍未恢復，先放行" : "已恢復")。"
    }
    if let d = try? JSONSerialization.data(withJSONObject: out), let str = String(data: d, encoding: .utf8) {
        print(str)
    }
    exit(0)
}
