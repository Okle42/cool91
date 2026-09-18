import XCTest
@testable import Cool91Core

/// 事件目錄是 guard 的信任邊界：本機任何程式都能丟檔進來
final class EventTests: XCTestCase {
    func testNoteStripsControlCharsAndTruncates() {
        XCTAssertEqual(Event.sanitizeNote("swift build\n2026-01-01 00:00:00 假造的 log 行"), "swift build2026-01-01 00:00:00 假造的 log 行")
        XCTAssertEqual(Event.sanitizeNote("a\u{1B}[31mred\u{07}"), "a[31mred")
        XCTAssertEqual(Event.sanitizeNote(String(repeating: "x", count: 500)).count, Event.maxNoteLength)
    }

    func testAtomicWriteRefusesSymlinkTmp() throws {
        let dir = NSTemporaryDirectory() + "cool91-test-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let victim = dir + "/victim"
        try "原本的內容".write(toFile: victim, atomically: true, encoding: .utf8)
        let target = dir + "/state.json"
        // 攻擊者先把 .tmp 做成指向受害檔的 symlink
        try FileManager.default.createSymbolicLink(atPath: target + ".tmp", withDestinationPath: victim)
        Snapshot.atomicWrite(Data("{}".utf8), to: target)
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "原本的內容", "root 不能順著 symlink 寫進受害檔")
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "{}", "symlink 被拿掉、正常檔寫成功")
    }

    func testEnsureDirRefusesSymlink() throws {
        let dir = NSTemporaryDirectory() + "cool91-test-dir-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(Snapshot.ensureDir(dir + "/ok", mode: 0o755), "自己的真目錄可以")
        try FileManager.default.createSymbolicLink(atPath: dir + "/events", withDestinationPath: dir)
        XCTAssertFalse(Snapshot.ensureDir(dir + "/events", mode: 0o1733), "symlink 不算數，也不能對它 chmod")
        var st = stat(); lstat(dir, &st)
        XCTAssertEqual(st.st_mode & 0o7777, 0o755, "被指向的目錄權限不能被改掉")
    }
}
