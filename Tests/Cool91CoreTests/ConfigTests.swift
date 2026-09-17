import XCTest
@testable import Cool91Core

final class ConfigTests: XCTestCase {
    func testCurveInterpolation() {
        var c = Config()
        c.curve = [.init(temp: 60, rpm: 1000), .init(temp: 80, rpm: 3000)]
        XCTAssertEqual(c.rpm(for: 50), 1000)      // 低於最低點 → 最低轉速
        XCTAssertEqual(c.rpm(for: 70), 2000)      // 線性插值
        XCTAssertEqual(c.rpm(for: 100), 3000)     // 高於最高點 → 最高轉速
    }

    func testCurveUnsortedInput() {
        var c = Config()
        c.curve = [.init(temp: 80, rpm: 3000), .init(temp: 60, rpm: 1000)]
        XCTAssertEqual(c.rpm(for: 70), 2000)
    }

    func testLevels() {
        let c = Config()   // warm 80 / hot 95 / critical 100
        XCTAssertEqual(c.level(for: 79.9), .ok)
        XCTAssertEqual(c.level(for: 80), .warm)
        XCTAssertEqual(c.level(for: 95), .hot)
        XCTAssertEqual(c.level(for: 100), .critical)
        XCTAssertTrue(Level.ok < Level.warm && Level.warm < Level.hot && Level.hot < Level.critical)
    }

    func testDecodeMissingKeysUsesDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"mode":"fixed"}"#.utf8))
        XCTAssertEqual(c.mode, "fixed")
        XCTAssertEqual(c.interval, Config().interval)
        XCTAssertEqual(c.curve.count, Config().curve.count)
    }

    func testDecodeIgnoresUnknownKeys() throws {
        // 舊版的 smoothing 欄位已移除，還在檔案裡不該讓解析失敗
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"smoothing":0.5}"#.utf8))
        XCTAssertEqual(c.smoothingUp, 0.7)
    }

    func testValidateRejectsBadThresholds() {
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"warmTemp":95,"hotTemp":90}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"mode":"turbo"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"curve":[]}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: Data(#"{"smoothingUp":1.5}"#.utf8)))
    }

    func testLoadOrErrorThrowsOnCorruptFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cool91-bad-\(UUID()).json")
        try Data(#"{"mode":"fixed","fixedRPM":2000"#.utf8).write(to: tmp)   // 少一個 }
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try Config.loadOrError(path: tmp.path))
        XCTAssertEqual(Config.load(path: tmp.path).mode, "curve")            // load 退回預設
    }

    func testLoadOrErrorMissingFileReturnsDefault() throws {
        let c = try Config.loadOrError(path: "/nonexistent/cool91.json")
        XCTAssertNil(c.loadedFrom)
    }
}

final class LevelHysteresisTests: XCTestCase {
    func testUpgradeImmediateDowngradeNeedsMargin() {
        let c = Config()   // warm 80 / hot 95 / critical 100 / 遲滯 3
        XCTAssertEqual(c.level(for: 81, previous: .ok), .warm)        // 升級立即
        XCTAssertEqual(c.level(for: 79, previous: .warm), .warm)      // 79 還在 80−3 以上，維持 warm
        XCTAssertEqual(c.level(for: 76.9, previous: .warm), .ok)      // 低於 77 才降
        XCTAssertEqual(c.level(for: 96, previous: .warm), .hot)
        XCTAssertEqual(c.level(for: 93, previous: .hot), .hot)
        XCTAssertEqual(c.level(for: 91.9, previous: .hot), .warm)
        XCTAssertEqual(c.level(for: 70, previous: .critical), .ok)    // 一次可以連降多級
        XCTAssertEqual(c.level(for: 81, previous: nil), .warm)
    }
}

// 面板提示音：sounds 缺席 = nil；有設就 save/load 往返不丟（面板按「套用」整份重寫，漏掉會把使用者設的音檔洗掉）
final class ConfigSoundsTests: XCTestCase {
    func testSoundsAbsentIsNil() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertNil(c.sounds)
        XCTAssertFalse(String(data: try JSONEncoder().encode(c), encoding: .utf8)!.contains("sounds"))
    }
    func testSoundsRoundTrip() throws {
        let json = #"{"sounds":{"critical":"~/a.mp3","coolDown":"/b.mp3","coolDownBelow":85}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.sounds?.critical, "~/a.mp3")
        XCTAssertEqual(c.sounds?.coolDown, "/b.mp3")
        XCTAssertEqual(c.coolDownBelow, 85)
        let back = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(back.sounds?.coolDown, "/b.mp3")
        XCTAssertEqual(back.sounds?.coolDownBelow, 85)
    }
    /// 沒設 coolDownBelow 就退回 hotTemp − levelHysteresis，和等級降級同步
    func testCoolDownBelowDefault() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"hotTemp":98,"levelHysteresis":3}"#.utf8))
        XCTAssertEqual(c.coolDownBelow, 95)
    }
}
