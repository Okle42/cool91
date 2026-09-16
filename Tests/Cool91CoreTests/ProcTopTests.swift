import XCTest
@testable import Cool91Core

final class ProcTopTests: XCTestCase {
    /// 自己燒 1 秒 CPU，應該出現在 top 裡
    func testSeesOwnBusyProcess() {
        let pt = ProcTop()
        XCTAssertTrue(pt.sample().isEmpty, "第一次沒有基準應回空")
        let stop = Date().addingTimeInterval(1.0)
        var x = 0.0
        while Date() < stop { x += sin(x) }
        let top = pt.sample(top: 5, minPercent: 10)
        XCTAssertTrue(top.contains { $0.pid == getpid() }, "自己應該在 top 裡：\(top)")
        _ = x
    }

    func testShorten() {
        XCTAssertEqual(ProcTop.shorten("/opt/homebrew/bin/Python -u -m tools.gen.bwb.shell --mid 16 --isogrid --iso-cache /x/y", name: "Python"), "Python -m tools.gen.bwb.shell --mid 16 --isogrid")
        XCTAssertEqual(ProcTop.shorten("/usr/bin/swift build -c release", name: "swift"), "swift build -c release")
    }
}
