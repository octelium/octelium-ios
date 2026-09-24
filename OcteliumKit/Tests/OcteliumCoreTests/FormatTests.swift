import SwiftProtobuf
import XCTest

@testable import OcteliumCore

final class FormatTests: XCTestCase {

    func testToDate() {
        XCTAssertNil(toDate(nil))
        XCTAssertNil(toDate(Google_Protobuf_Timestamp()))

        let now = getDate("2026-09-23T10:00:00.500Z")
        XCTAssertEqual(now.timeIntervalSince1970, toDate(getTimestamp(now))!.timeIntervalSince1970, accuracy: 0.001)
    }

    func testToRFC3339() {
        XCTAssertNil(toRFC3339(nil))
        XCTAssertEqual("2026-09-23T10:00:00Z", toRFC3339(getTimestamp(getDate("2026-09-23T10:00:00Z"))))
    }

    func testPrintDuration() {
        let now = getDate("2026-09-23T10:00:00Z")

        XCTAssertEqual("", printDuration(nil, now: now))
        XCTAssertEqual("0s", printDuration(getTimestamp(now), now: now))
        XCTAssertEqual("0s", printDuration(getTimestamp(now.addingTimeInterval(10)), now: now))
        XCTAssertEqual("42s", printDuration(getTimestamp(now.addingTimeInterval(-42)), now: now))
        XCTAssertEqual("2m 5s", printDuration(getTimestamp(now.addingTimeInterval(-125)), now: now))
        XCTAssertEqual("1h 1m", printDuration(getTimestamp(now.addingTimeInterval(-3660)), now: now))
        XCTAssertEqual(
            "2d 3h",
            printDuration(getTimestamp(now.addingTimeInterval(-(2 * 86400 + 3 * 3600 + 59))), now: now)
        )
    }

    func testPrintTimeAgo() {
        let now = getDate("2026-09-23T10:00:00Z")

        XCTAssertEqual("—", printTimeAgo(nil, now: now))
        XCTAssertEqual("a few seconds ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-10)), now: now))
        XCTAssertEqual("a minute ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-60)), now: now))
        XCTAssertEqual("5 minutes ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-300)), now: now))
        XCTAssertEqual("an hour ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-3600)), now: now))
        XCTAssertEqual("3 hours ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-3 * 3600)), now: now))
        XCTAssertEqual("a day ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-86400)), now: now))
        XCTAssertEqual("4 days ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-4 * 86400)), now: now))
        XCTAssertEqual("a month ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-30 * 86400)), now: now))
        XCTAssertEqual("3 months ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-90 * 86400)), now: now))
        XCTAssertEqual("a year ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-365 * 86400)), now: now))
        XCTAssertEqual("2 years ago", printTimeAgo(getTimestamp(now.addingTimeInterval(-730 * 86400)), now: now))
        XCTAssertEqual("in the future", printTimeAgo(getTimestamp(now.addingTimeInterval(60)), now: now))
    }
}
