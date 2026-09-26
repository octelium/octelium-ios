import Foundation
import OcteliumProto
import SwiftProtobuf
import XCTest

@testable import OcteliumCore

final class SessionTokenTests: XCTestCase {

    private let setAt = Date(timeIntervalSince1970: 1790157723)

    private func getDomain(expiresIn: Int64, refreshTokenExpiresIn: Int64) -> Configv1.State.Domain {
        var ret = Configv1.State.Domain()
        ret.sessionToken.accessToken = "access"
        ret.sessionToken.refreshToken = "refresh"
        ret.sessionToken.expiresIn = expiresIn
        ret.sessionToken.refreshTokenExpiresIn = refreshTokenExpiresIn
        ret.sessionTokenSetAt = Google_Protobuf_Timestamp(date: setAt)
        return ret
    }

    func testTokens() {
        do {
            let itm = getDomain(expiresIn: 3600, refreshTokenExpiresIn: 86400)

            XCTAssertEqual(setAt.addingTimeInterval(3600), getAccessTokenExpiresAt(itm))
            XCTAssertEqual(setAt.addingTimeInterval(1800), getAccessTokenRenewAt(itm))
            XCTAssertEqual(setAt.addingTimeInterval(86400), getRefreshTokenExpiresAt(itm))

            XCTAssertFalse(needsNewAccessToken(itm, now: setAt.addingTimeInterval(1799)))
            XCTAssertTrue(needsNewAccessToken(itm, now: setAt.addingTimeInterval(1801)))

            XCTAssertTrue(hasValidRefreshToken(itm, now: setAt.addingTimeInterval(86399)))
            XCTAssertFalse(hasValidRefreshToken(itm, now: setAt.addingTimeInterval(86401)))
        }

        do {
            let itm = getDomain(expiresIn: 900, refreshTokenExpiresIn: 86400)
            XCTAssertEqual(setAt.addingTimeInterval(300), getAccessTokenRenewAt(itm))
        }

        do {
            let itm = getDomain(expiresIn: 0, refreshTokenExpiresIn: 0)
            XCTAssertNil(getAccessTokenRenewAt(itm))
            XCTAssertNil(getRefreshTokenExpiresAt(itm))
            XCTAssertFalse(needsNewAccessToken(itm, now: setAt.addingTimeInterval(1_000_000)))
            XCTAssertFalse(hasValidRefreshToken(itm, now: setAt))
        }

        do {
            XCTAssertTrue(needsNewAccessToken(nil))
            XCTAssertTrue(needsNewAccessToken(Configv1.State.Domain()))
            XCTAssertFalse(hasValidRefreshToken(nil))
        }
    }

    func testGetDeviceHostname() {
        XCTAssertEqual("iPhone 17", getDeviceHostname("  iPhone 17 "))
        XCTAssertEqual(String(repeating: "a", count: 32), getDeviceHostname(String(repeating: "a", count: 40)))
        XCTAssertEqual(
            String(repeating: "a", count: 30) + "\u{e9}",
            getDeviceHostname(String(repeating: "a", count: 30) + String(repeating: "\u{e9}", count: 4))
        )
        XCTAssertEqual(String(repeating: "a", count: 31), getDeviceHostname(String(repeating: "a", count: 31) + "\u{1F600}"))
    }

    func testGetDeviceID() {
        XCTAssertEqual("2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae", getDeviceID("foo"))
    }
}
