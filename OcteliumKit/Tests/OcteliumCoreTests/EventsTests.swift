import Foundation
import OcteliumProto
import SwiftProtobuf
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

    private func getLog(_ msg: String, level: Mobilev1.Log.Level = .info) -> Mobilev1.Log {
        var ret = Mobilev1.Log()
        ret.level = level
        ret.message = msg
        return ret
    }

    private func getEvent(_ type: Mobilev1.Event.OneOf_Type?) throws -> Data {
        var ret = Mobilev1.Event()
        ret.type = type
        return try ret.serializedBytes()
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

    func testEventHandler() throws {
        let statusStore = StatusStore()
        let logStore = LogStore()
        let received = Mutex<[String]>([])
        let h = EventHandler(statusStore: statusStore, logStore: logStore) { log in
            received.withLock { $0.append(log.message) }
        }

        do {
            h.handle(try getEvent(.status(getStatus("a", 7))))
            XCTAssertEqual(7, statusStore.status?.revision)
        }

        do {
            h.handle(try getEvent(.log(getLog("hello"))))
            XCTAssertEqual(["hello"], logStore.logs.map(\.message))
            XCTAssertEqual(["hello"], received.withLock { $0 })
        }

        do {
            h.handle(Data([0xff, 0x01]))
            h.handle(try getEvent(nil))
            XCTAssertEqual(7, statusStore.status?.revision)
            XCTAssertEqual(1, logStore.logs.count)
        }
    }

    func testFormatLog() {
        let utc = TimeZone(identifier: "UTC")!

        do {
            var log = getLog("Could not rebind", level: .warn)
            log.createdAt = Google_Protobuf_Timestamp(seconds: 1790157723, nanos: 0)
            XCTAssertEqual("10:02:03 WARN  Could not rebind", formatLog(log, timeZone: utc))
        }
        do {
            XCTAssertEqual("--:--:-- ERROR failed", formatLog(getLog("failed", level: .error), timeZone: utc))
        }
        do {
            XCTAssertEqual("--:--:-- DEBUG x", formatLog(getLog("x", level: .debug), timeZone: utc))
            XCTAssertEqual("--:--:-- LEVEL_UNSPECIFIED x", formatLog(getLog("x", level: .unspecified), timeZone: utc))
        }
    }
}
