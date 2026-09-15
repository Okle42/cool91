import XCTest
@testable import Cool91Core

final class SnapshotTests: XCTestCase {
    /// v0.1 guard 寫的快照（沒有 controlTemp / sensorOK / stats / 頻率）也要讀得懂
    func testDecodeLegacySnapshot() throws {
        let legacy = #"{"cpuAvg":43.7,"cpuMax":75.4,"fans":[{"index":0,"manual":true,"max":4900,"min":1000,"rpm":1000,"target":1000}],"gpuMax":39.4,"guardMode":"curve","guardRunning":true,"guardTargetRPM":1625,"level":"ok","ssd":30.4,"time":"2026-09-15T20:16:54Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(Snapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.cpuMax, 75.4)
        XCTAssertEqual(s.controlTemp, 75.4)     // 缺 controlTemp → 用 cpuMax
        XCTAssertTrue(s.sensorOK)
        XCTAssertNil(s.pcoreMHz)
        XCTAssertNil(s.stats)
        XCTAssertFalse(s.throttling)
        XCTAssertEqual(s.fans.first?.max, 4900)
    }

    func testRoundTrip() throws {
        var s = Snapshot(time: Date(timeIntervalSince1970: 1_700_000_000), cpuMax: 88, cpuAvg: 60, gpuMax: 50, ssd: 33,
                         fans: [.init(index: 0, rpm: 3000, target: 3000, min: 1000, max: 4900, manual: true)],
                         level: .warm, guardRunning: true, guardTargetRPM: 3000)
        s.controlTemp = 88; s.pcoreMHz = 3936; s.ecoreMHz = 2808; s.thermalPressure = "Moderate"
        var st = Snapshot.Stats(date: "2026-09-16"); st.throttleSeconds = 15; s.stats = st
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Snapshot.self, from: try enc.encode(s))
        XCTAssertEqual(back.pcoreMHz, 3936)
        XCTAssertTrue(back.throttling)
        XCTAssertEqual(back.stats?.throttleSeconds, 15)
        XCTAssertTrue(back.short.contains("⚡3.94GHz"))
        XCTAssertTrue(back.short.contains("降頻(Moderate)"))
    }

    func testFreqReaderParse() {
        let lines = [
            "E-Cluster HW active frequency: 0 MHz",
            "P-Cluster HW active frequency: 3936 MHz",
            "CPU Power: 21522 mW",
            "**** Thermal pressure ****",
            "Current pressure level: Nominal",
            "P-Cluster HW active frequency: 4130 MHz",
        ]
        let r = FreqReader.parse(lines: lines)
        XCTAssertEqual(r.p, 4130)      // 取最後一次
        XCTAssertEqual(r.e, 0)
        XCTAssertEqual(r.pressure, "Nominal")
        let empty = FreqReader.parse(lines: ["nothing here"])
        XCTAssertNil(empty.p); XCTAssertNil(empty.pressure)
    }

    func testEventPostSkipsWhenDirMissing() {
        // 事件目錄不存在（guard 沒跑）時 post 應該靜靜回 false，不能炸
        if !FileManager.default.fileExists(atPath: Event.dir) {
            XCTAssertFalse(Event(kind: .boost, rpm: 3000, seconds: 120).post())
        }
    }
}
