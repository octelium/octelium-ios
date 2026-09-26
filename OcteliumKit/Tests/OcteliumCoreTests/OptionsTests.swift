import Foundation
import OcteliumProto
import XCTest

@testable import OcteliumCore

final class OptionsTests: XCTestCase {

    private func assertInvalid(_ msg: String, _ fn: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try fn()
            XCTFail(file: file, line: line)
        } catch let err as StatusError {
            XCTAssertEqual(.invalidArgument, err.code, file: file, line: line)
            XCTAssertEqual(msg, err.message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testCanonicalizeDomain() throws {
        XCTAssertEqual("example.com", try canonicalizeDomain("example.com"))
        XCTAssertEqual("example.com", try canonicalizeDomain(" Example.COM. "))
        XCTAssertEqual("xn--mnchen-3ya.de", try canonicalizeDomain("m\u{fc}nchen.de"))

        assertInvalid("The Cluster domain is not set") { _ = try canonicalizeDomain(" ") }
        assertInvalid("Invalid Cluster domain: example") { _ = try canonicalizeDomain("example") }
        assertInvalid("Invalid Cluster domain: 192.168.1.1") { _ = try canonicalizeDomain("192.168.1.1") }
        assertInvalid("Invalid Cluster domain: ::1") { _ = try canonicalizeDomain("::1") }
        assertInvalid("Invalid Cluster domain: not a domain") { _ = try canonicalizeDomain("not a domain") }
        assertInvalid("Invalid Cluster domain: -a.example.com") { _ = try canonicalizeDomain("-a.example.com") }

        let long = "\(String(repeating: "a", count: 64)).com"
        assertInvalid("Invalid Cluster domain: \(long)") { _ = try canonicalizeDomain(long) }
    }

    func testGetConnectOptions() throws {
        do {
            let ret = try getConnectOptions(nil)
            XCTAssertEqual(.v6, ret.l3Mode)
            XCTAssertEqual(.wireguard, ret.tunnelMode)
            XCTAssertEqual(.default, ret.dnsMode)
            XCTAssertEqual(0, ret.mtu)
        }

        do {
            var o = Daemonv1.ConnectionOptions()
            o.l3Mode = .both
            o.tunnelMode = .quicv0
            o.implementationMode = .tun
            o.dns.mode = .full
            o.mtu = 1400

            let ret = try getConnectOptions(o)
            XCTAssertEqual(.both, ret.l3Mode)
            XCTAssertEqual(.quicv0, ret.tunnelMode)
            XCTAssertEqual(.full, ret.dnsMode)
            XCTAssertEqual(1400, ret.mtu)
        }

        assertInvalid("Unsupported implementationMode on this platform: 1") {
            var o = Daemonv1.ConnectionOptions()
            o.implementationMode = .kernel
            _ = try getConnectOptions(o)
        }

        assertInvalid("The local DNS server is not supported on this platform") {
            var o = Daemonv1.ConnectionOptions()
            o.dns.enableLocalServer = true
            _ = try getConnectOptions(o)
        }

        assertInvalid("Serving and publishing Services are not supported on this platform") {
            var o = Daemonv1.ConnectionOptions()
            o.serviceOptions.enableEmbeddedSsh = true
            _ = try getConnectOptions(o)
        }

        assertInvalid("The MTU must be between 576 and 1500") {
            var o = Daemonv1.ConnectionOptions()
            o.mtu = 9000
            _ = try getConnectOptions(o)
        }

        assertInvalid("Unsupported tunnelMode: 7") {
            var o = Daemonv1.ConnectionOptions()
            o.tunnelMode = .UNRECOGNIZED(7)
            _ = try getConnectOptions(o)
        }
    }

    func testNormalizeConnectionOptions() {
        XCTAssertEqual(.default, normalizeConnectionOptions(nil).dns.mode)

        var o = Daemonv1.ConnectionOptions()
        o.dns.mode = .full
        XCTAssertEqual(.full, normalizeConnectionOptions(o).dns.mode)
    }

    func testGetError() {
        do {
            let ret = getError(AuthenticationRequiredError(), .connectionFailed)
            XCTAssertEqual(.authenticationRequired, ret.code)
            XCTAssertFalse(ret.retryable)
            XCTAssertEqual(
                "Interactive authentication is not available in this mode. Please authenticate yourself first",
                ret.message
            )
        }

        do {
            let ret = getError(StatusError(.unavailable, "unreachable"), .authenticationFailed)
            XCTAssertEqual(.clusterUnreachable, ret.code)
            XCTAssertTrue(ret.retryable)
            XCTAssertEqual("unreachable", ret.message)
        }

        do {
            let ret = getError(
                ConnectionClosedError("wrapped", cause: StatusError(.unauthenticated, "")),
                .connectionFailed
            )
            XCTAssertEqual(.authenticationRequired, ret.code)
            XCTAssertEqual("wrapped", ret.message)
        }

        do {
            let ret = getError(TunnelError(.platform, "failed"), .connectionFailed)
            XCTAssertEqual(.networkConfigurationFailed, ret.code)
            XCTAssertTrue(ret.retryable)
        }

        do {
            XCTAssertEqual(.operationCanceled, getError(CancellationError(), .authenticationFailed).code)
            XCTAssertEqual(.operationCanceled, getError(StatusError(.canceled, ""), .authenticationFailed).code)
            XCTAssertEqual(.authenticationTimedOut, getError(AuthenticationTimedOutError(), .authenticationFailed).code)
        }

        do {
            let ret = getError(ClientError("failed"), .connectionFailed)
            XCTAssertEqual(.connectionFailed, ret.code)
            XCTAssertTrue(ret.retryable)
            XCTAssertEqual("failed", ret.message)
        }
    }

    func testSetConnectionStatusFromConnection() {
        var state = Userv1.ConnectionState()
        var address = Metav1.DualStackNetwork()
        address.v6 = "fdee:1::5/128"
        state.addresses = [address]
        state.dns.servers = ["fdee:1::53"]

        do {
            var st = Daemonv1.ConnectionStatus()
            setConnectionStatusFromConnection(&st, nil)
            XCTAssertEqual(Daemonv1.ConnectionStatus(), st)
        }

        do {
            var st = Daemonv1.ConnectionStatus()
            setConnectionStatusFromConnection(
                &st,
                Connection(state: state, tunnelMode: .quicv0, dnsMode: .default, mtu: 1280)
            )
            XCTAssertEqual(1280, st.mtu)
            XCTAssertEqual(["fdee:1::5/128"], st.addresses.map(\.v6))
            XCTAssertEqual(.tun, st.implementationMode)
            XCTAssertEqual(.quicv0, st.tunnelMode)
            XCTAssertEqual(.default, st.dns.mode)
            XCTAssertTrue(st.dns.isConfigured)
            XCTAssertEqual(["fdee:1::53"], st.dns.servers)
        }

        do {
            var st = Daemonv1.ConnectionStatus()
            setConnectionStatusFromConnection(
                &st,
                Connection(state: state, tunnelMode: .wireguard, dnsMode: .disabled, mtu: 1280)
            )
            XCTAssertEqual(.wireguard, st.tunnelMode)
            XCTAssertEqual(.disabled, st.dns.mode)
            XCTAssertFalse(st.dns.isConfigured)
        }
    }
}
