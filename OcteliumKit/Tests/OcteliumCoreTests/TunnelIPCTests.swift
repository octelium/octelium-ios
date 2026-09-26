import Foundation
import OcteliumProto
import XCTest

@testable import OcteliumCore

final class TunnelIPCTests: XCTestCase {

    private func getLog(_ msg: String) -> LogEntry {
        LogEntry(level: .info, createdAt: Date(timeIntervalSince1970: 1790157723.5), message: msg)
    }

    func testTunnelMessage() {
        XCTAssertEqual(Data([1]), encodeTunnelMessage(.getStatus))
        XCTAssertEqual(Data([2]), encodeTunnelMessage(.getLogs))
        XCTAssertEqual(.getStatus, decodeTunnelMessage(encodeTunnelMessage(.getStatus)))
        XCTAssertEqual(.getLogs, decodeTunnelMessage(encodeTunnelMessage(.getLogs)))
        XCTAssertNil(decodeTunnelMessage(Data()))
        XCTAssertNil(decodeTunnelMessage(Data([9])))
        XCTAssertNil(decodeTunnelMessage(Data([1, 1])))
        XCTAssertEqual(.getLogs, decodeTunnelMessage(Data([0, 2]).suffix(1)))
    }

    func testGetTunnelStatusNotification() {
        XCTAssertEqual("group.com.octelium.client.tunnel.status", getTunnelStatusNotification("group.com.octelium.client"))
        XCTAssertNotEqual(
            getTunnelStatusNotification("group.com.octelium.client"),
            getTunnelStatusNotification("group.com.example.octelium")
        )
    }

    func testLogs() throws {
        do {
            XCTAssertEqual([], try decodeLogs(try encodeLogs([])))
        }
        do {
            let logs = [getLog("a"), getLog(String(repeating: "b", count: 300)), getLog("")]
            XCTAssertEqual(logs, try decodeLogs(try encodeLogs(logs)))
        }
        do {
            let logs = (0..<(maxTunnelLogs + 10)).map { getLog("log-\($0)") }
            let ret = try decodeLogs(try encodeLogs(logs))
            XCTAssertEqual(maxTunnelLogs, ret.count)
            XCTAssertEqual("log-10", ret.first?.message)
            XCTAssertEqual("log-\(maxTunnelLogs + 9)", ret.last?.message)
        }
        do {
            let data = try encodeLogs([getLog("hello")])
            XCTAssertThrowsError(try decodeLogs(data.prefix(data.count - 1)))
            XCTAssertThrowsError(try decodeLogs(Data([0xff, 0xff])))
            XCTAssertThrowsError(try decodeLogs(Data()))
        }
    }

    func testGetTunnelErrorCode() {
        XCTAssertEqual(.authenticationRequired, getTunnelErrorCode(getTestError(.authenticationRequired)))
        XCTAssertEqual(.authenticationRequired, getTunnelErrorCode(getTestError(.authenticationFailed)))
        XCTAssertEqual(.clusterUnreachable, getTunnelErrorCode(getTestError(.clusterUnreachable)))
        XCTAssertEqual(.connectionFailed, getTunnelErrorCode(getTestError(.connectionFailed)))
        XCTAssertEqual(.invalidConfiguration, getTunnelErrorCode(getTestError(.networkConfigurationFailed)))
        XCTAssertEqual(.invalidConfiguration, getTunnelErrorCode(getTestError(.dnsConfigurationFailed)))
        XCTAssertEqual(.permissionDenied, getTunnelErrorCode(getTestError(.permissionDenied)))
        XCTAssertEqual(.internalError, getTunnelErrorCode(getTestError(.internal)))
        XCTAssertEqual(.internalError, getTunnelErrorCode(nil))
    }

    func testGetDaemonError() {
        do {
            let err = getTunnelError(.authenticationRequired, "Sign in again")
            XCTAssertEqual(tunnelErrorDomain, err.domain)
            XCTAssertEqual(3, err.code)
            XCTAssertEqual("Sign in again", err.localizedDescription)

            let ret = getDaemonError(err)
            XCTAssertEqual(.authenticationRequired, ret.code)
            XCTAssertEqual("Sign in again", ret.message)
            XCTAssertFalse(ret.retryable)
        }
        do {
            let ret = getDaemonError(getTunnelError(.startTimeout, "Timed out"))
            XCTAssertEqual(.connectionFailed, ret.code)
            XCTAssertTrue(ret.retryable)
        }
        do {
            let ret = getDaemonError(NSError(domain: "NEVPNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed"]))
            XCTAssertEqual(.connectionFailed, ret.code)
            XCTAssertEqual("failed", ret.message)
            XCTAssertTrue(ret.retryable)
        }
        do {
            let ret = getDaemonError(NSError(domain: tunnelErrorDomain, code: 999, userInfo: [NSLocalizedDescriptionKey: "x"]))
            XCTAssertEqual(.connectionFailed, ret.code)
        }

        for code in TunnelErrorCode.allCases {
            let ret = getDaemonError(code, "msg")
            XCTAssertEqual("msg", ret.message)
            XCTAssertNotEqual(.unspecified, ret.code)
        }
    }
}
