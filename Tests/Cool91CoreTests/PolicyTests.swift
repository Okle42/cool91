import XCTest
@testable import Cool91Core

final class PolicyTests: XCTestCase {
    let allow = Config().hookAllowCommands
    let boost = Config().boostCommands

    // MARK: 白名單

    func testAllowSimple() {
        XCTAssertTrue(Policy.commandIsAllowed("cool91 wait", allow: allow))
        XCTAssertTrue(Policy.commandIsAllowed("sudo cool91 fan 4900 && sleep 1", allow: allow))
        XCTAssertTrue(Policy.commandIsAllowed("/usr/bin/pkill -f blender; ps aux | grep x", allow: allow))
        XCTAssertTrue(Policy.commandIsAllowed("FOO=1 kill -9 123", allow: allow))
    }

    func testAllowRejectsMixed() {
        XCTAssertFalse(Policy.commandIsAllowed("cool91 wait; swift build", allow: allow))
        XCTAssertFalse(Policy.commandIsAllowed("ls -la", allow: allow))
        XCTAssertFalse(Policy.commandIsAllowed("", allow: allow))
        XCTAssertFalse(Policy.commandIsAllowed("   ", allow: allow))
    }

    // MARK: 預熱

    func testBoostMatchesCommandHead() {
        XCTAssertTrue(Policy.commandNeedsBoost("swift build -c release", keywords: boost))
        XCTAssertTrue(Policy.commandNeedsBoost("cd /x && swift build", keywords: boost))
        XCTAssertTrue(Policy.commandNeedsBoost("sudo nice blender -b x.blend", keywords: boost))
        XCTAssertTrue(Policy.commandNeedsBoost("/opt/homebrew/bin/ffmpeg -i a.mp4", keywords: boost))
        XCTAssertTrue(Policy.commandNeedsBoost("make -j8", keywords: boost))
    }

    func testBoostIgnoresKeywordInsideText() {
        XCTAssertFalse(Policy.commandNeedsBoost("python3 - <<'PY'\nprint('swift build')\nPY", keywords: boost))
        XCTAssertFalse(Policy.commandNeedsBoost("./make-app.sh", keywords: boost))
        XCTAssertFalse(Policy.commandNeedsBoost("ls -la", keywords: boost))
        XCTAssertFalse(Policy.commandNeedsBoost("echo 'make '", keywords: boost))
    }

    // MARK: 把關判斷

    func snap(level: Level, pressure: String?) -> Snapshot {
        var s = Snapshot(time: Date(), cpuMax: 0, cpuAvg: 0, gpuMax: 0, ssd: nil, fans: [], level: level, guardRunning: true, guardTargetRPM: nil)
        s.thermalPressure = pressure
        return s
    }

    func testVerdictFollowsPressureNotTemperature() {
        let c = Config()
        // 溫度 hot 但 Nominal → 放行
        XCTAssertEqual(Policy.verdict(snap(level: .hot, pressure: "Nominal"), config: c).wait, false)
        // 溫度 ok 但 Moderate → 等
        let m = Policy.verdict(snap(level: .ok, pressure: "Moderate"), config: c)
        XCTAssertTrue(m.wait); XCTAssertFalse(m.block)
        let h = Policy.verdict(snap(level: .warm, pressure: "Heavy"), config: c)
        XCTAssertTrue(h.wait); XCTAssertFalse(h.block)
        // Trapping → 擋
        let t = Policy.verdict(snap(level: .ok, pressure: "Trapping"), config: c)
        XCTAssertTrue(t.wait); XCTAssertTrue(t.block)
    }

    func testVerdictCriticalTemperatureIsSafetyFloor() {
        let c = Config()
        let v = Policy.verdict(snap(level: .critical, pressure: "Nominal"), config: c)
        XCTAssertTrue(v.wait); XCTAssertTrue(v.block)
        var noBlock = Config(); noBlock.hookBlockOnCritical = false
        XCTAssertFalse(Policy.verdict(snap(level: .critical, pressure: "Nominal"), config: noBlock).block)
    }

    func testVerdictFallsBackToTemperatureWithoutPressure() {
        let c = Config()
        XCTAssertFalse(Policy.verdict(snap(level: .warm, pressure: nil), config: c).wait)
        let h = Policy.verdict(snap(level: .hot, pressure: nil), config: c)
        XCTAssertTrue(h.wait); XCTAssertFalse(h.block)
    }

    // MARK: Format

    func testHms() {
        XCTAssertEqual(Format.hms(0), "0s")
        XCTAssertEqual(Format.hms(59), "59s")
        XCTAssertEqual(Format.hms(65), "1m05s")
        XCTAssertEqual(Format.hms(3720), "1h02m")
    }
}
