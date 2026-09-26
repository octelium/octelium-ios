import Foundation
import OcteliumProto
import Synchronization
import XCTest

@testable import OcteliumCore

final class EventsTests: XCTestCase {

    private func getStatus(_ instanceID: String, _ revision: UInt64) -> Daemonv1.GetStatusResponse {
        var ret = Daemonv1.GetStatusResponse()
        ret.instanceID = instanceID
        ret.revision = revision
        return ret
    }

    private func getLog(_ msg: String, level: LogLevel = .info) -> LogEntry {
        LogEntry(level: level, createdAt: Date(timeIntervalSince1970: 1790157723), message: msg)
    }

    func testShouldReplaceStatus() {
        XCTAssertTrue(shouldReplaceStatus(nil, getStatus("a", 1)))
        XCTAssertTrue(shouldReplaceStatus(getStatus("a", 1), getStatus("a", 2)))
        XCTAssertTrue(shouldReplaceStatus(getStatus("a", 2), getStatus("a", 2)))
        XCTAssertFalse(shouldReplaceStatus(getStatus("a", 3), getStatus("a", 2)))
        XCTAssertTrue(shouldReplaceStatus(getStatus("a", 3), getStatus("b", 1)))
    }

    func testStatusStore() {
        let changes = Mutex(0)
        let s = StatusStore { changes.withLock { $0 += 1 } }
        XCTAssertNil(s.status)

        s.update(getStatus("a", 2))
        XCTAssertEqual(2, s.status?.revision)

        s.update(getStatus("a", 1))
        XCTAssertEqual(2, s.status?.revision)

        s.update(getStatus("a", 5))
        XCTAssertEqual(5, s.status?.revision)

        s.update(getStatus("b", 1))
        XCTAssertEqual("b", s.status?.instanceID)

        XCTAssertEqual(3, changes.withLock { $0 })

        s.reset()
        XCTAssertNil(s.status)
        XCTAssertEqual(4, changes.withLock { $0 })
    }

    func testLogStore() {
        let s = LogStore(capacity: 3)
        XCTAssertTrue(s.logs.isEmpty)

        for i in 1...5 {
            s.add(getLog("log-\(i)"))
        }

        XCTAssertEqual(["log-3", "log-4", "log-5"], s.logs.map(\.message))

        s.clear()
        XCTAssertTrue(s.logs.isEmpty)
    }

    func testLogWriter() {
        let received = Mutex<[LogEntry]>([])
        let w = LogWriter(level: .info) { log in
            received.withLock { $0.append(log) }
        }

        w.debug("debug")
        w.info("info")
        w.warn("warn")
        w.error("error")
        w.log(getLog("entry", level: .debug))
        w.log(getLog("entry", level: .error))

        XCTAssertEqual(["info", "warn", "error", "entry"], received.withLock { $0.map(\.message) })
        XCTAssertEqual([.info, .warn, .error, .error], received.withLock { $0.map(\.level) })
        XCTAssertTrue(LogLevel.debug < LogLevel.info && LogLevel.warn < LogLevel.error)
    }

    func testFormatLog() {
        let utc = TimeZone(identifier: "UTC")!

        XCTAssertEqual("10:02:03 WARN  Could not rebind", formatLog(getLog("Could not rebind", level: .warn), timeZone: utc))
        XCTAssertEqual("10:02:03 ERROR failed", formatLog(getLog("failed", level: .error), timeZone: utc))
        XCTAssertEqual("10:02:03 DEBUG x", formatLog(getLog("x", level: .debug), timeZone: utc))
        XCTAssertEqual("10:02:03 INFO  x", formatLog(getLog("x"), timeZone: utc))
    }
}
