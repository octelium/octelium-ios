import OcteliumProto
import XCTest

@testable import OcteliumCore

final class DomainsTests: XCTestCase {

    func testIsOperationActive() {
        XCTAssertFalse(isOperationActive(nil))
        XCTAssertTrue(isOperationActive(getTestOperation(state: .pending)))
        XCTAssertTrue(isOperationActive(getTestOperation(state: .running)))
        XCTAssertTrue(isOperationActive(getTestOperation(state: .waitingForUser)))
        XCTAssertFalse(isOperationActive(getTestOperation(state: .succeeded)))
        XCTAssertFalse(isOperationActive(getTestOperation(state: .failed)))
        XCTAssertFalse(isOperationActive(getTestOperation(state: .canceled)))
        XCTAssertFalse(isOperationActive(getTestOperation(state: .unspecified)))
    }

    func testGetActiveOperation() {
        do {
            XCTAssertNil(getActiveOperation(nil))
        }
        do {
            XCTAssertNil(getActiveOperation(getTestDomain()))
        }
        do {
            let op = getTestOperation(state: .running)
            XCTAssertEqual(op, getActiveOperation(getTestDomain(op: op)))
        }
        do {
            XCTAssertNil(getActiveOperation(getTestDomain(op: getTestOperation(state: .succeeded))))
        }
    }

    func testGetLastError() {
        do {
            XCTAssertNil(getLastError(nil))
            XCTAssertNil(getLastError(getTestDomain()))
        }
        do {
            var domain = getTestDomain()
            domain.lastError = getTestError(.clusterUnreachable)
            XCTAssertEqual(.clusterUnreachable, getLastError(domain)?.code)
        }
    }

    func testGetPendingOpenURL() {
        do {
            let ret = getPendingOpenURL(
                getTestDomain(
                    op: getTestOperation(type: .authenticate, state: .waitingForUser, url: "https://example.com/login")
                )
            )
            XCTAssertEqual("https://example.com/login", ret)
        }
        do {
            let ret = getPendingOpenURL(
                getTestDomain(
                    op: getTestOperation(type: .authenticate, state: .running, url: "https://example.com/login")
                )
            )
            XCTAssertNil(ret)
        }
        do {
            let ret = getPendingOpenURL(
                getTestDomain(op: getTestOperation(type: .authenticate, state: .waitingForUser))
            )
            XCTAssertNil(ret)
        }
        do {
            XCTAssertNil(getPendingOpenURL(nil))
        }
    }

    func testIsConnectionBusy() {
        XCTAssertFalse(isConnectionBusy(nil))
        XCTAssertTrue(isConnectionBusy(getTestDomain(conn: .connecting)))
        XCTAssertTrue(isConnectionBusy(getTestDomain(conn: .reconnecting)))
        XCTAssertTrue(isConnectionBusy(getTestDomain(conn: .disconnecting)))
        XCTAssertFalse(isConnectionBusy(getTestDomain(conn: .connected)))
        XCTAssertFalse(isConnectionBusy(getTestDomain(conn: .disconnected)))
    }

    func testIsConnectionActive() {
        XCTAssertFalse(isConnectionActive(nil))
        XCTAssertFalse(isConnectionActive(getTestDomain(conn: .disconnected)))
        XCTAssertFalse(isConnectionActive(getTestDomain(conn: .unspecified)))

        for state: Daemonv1.ConnectionStatus.State in [.connecting, .connected, .reconnecting, .disconnecting] {
            XCTAssertTrue(isConnectionActive(getTestDomain(conn: state)))
        }
    }

    func testCanConnect() {
        XCTAssertFalse(canConnect(nil))
        XCTAssertFalse(canConnect(getTestDomain()))
        XCTAssertTrue(canConnect(getTestDomain(auth: .authenticated)))
        XCTAssertFalse(canConnect(getTestDomain(auth: .authenticated, conn: .connected)))
        XCTAssertFalse(canConnect(getTestDomain(auth: .authenticated, conn: .disconnecting)))
        XCTAssertFalse(
            canConnect(getTestDomain(auth: .authenticated, op: getTestOperation(type: .logout, state: .running)))
        )
        XCTAssertTrue(
            canConnect(getTestDomain(auth: .authenticated, op: getTestOperation(type: .connect, state: .failed)))
        )
    }

    func testCanDisconnect() {
        XCTAssertFalse(canDisconnect(nil))
        XCTAssertFalse(canDisconnect(getTestDomain()))
        XCTAssertTrue(canDisconnect(getTestDomain(conn: .connected)))
        XCTAssertTrue(canDisconnect(getTestDomain(conn: .connecting)))
        XCTAssertTrue(canDisconnect(getTestDomain(conn: .reconnecting)))
        XCTAssertFalse(canDisconnect(getTestDomain(conn: .disconnecting)))
        XCTAssertFalse(
            canDisconnect(getTestDomain(conn: .connected, op: getTestOperation(type: .disconnect, state: .running)))
        )
        XCTAssertTrue(canDisconnect(getTestDomain(op: getTestOperation(type: .connect, state: .running))))
        XCTAssertFalse(canDisconnect(getTestDomain(op: getTestOperation(type: .connect, state: .failed))))
    }

    func testIsTeardownOperation() {
        XCTAssertFalse(isTeardownOperation(nil))
        XCTAssertFalse(isTeardownOperation(getTestOperation(type: .connect)))
        XCTAssertFalse(isTeardownOperation(getTestOperation(type: .authenticate)))
        XCTAssertTrue(isTeardownOperation(getTestOperation(type: .disconnect)))
        XCTAssertTrue(isTeardownOperation(getTestOperation(type: .logout)))
        XCTAssertTrue(isTeardownOperation(getTestOperation(type: .delete)))
    }

    func testLabels() {
        XCTAssertEqual("Connected", getConnectionStateLabel(.connected))
        XCTAssertEqual("Reconnecting", getConnectionStateLabel(.reconnecting))
        XCTAssertEqual("Disconnected", getConnectionStateLabel(nil))
        XCTAssertEqual(.connected, getConnectionStateTone(.connected))
        XCTAssertEqual(.pending, getConnectionStateTone(.connecting))
        XCTAssertEqual(.idle, getConnectionStateTone(.disconnected))

        XCTAssertEqual("Signed in", getAuthenticationStateLabel(.authenticated))
        XCTAssertEqual("Signed out", getAuthenticationStateLabel(.loggedOut))
        XCTAssertEqual(.emerald, getAuthenticationStateTone(.authenticated))
        XCTAssertEqual(.amber, getAuthenticationStateTone(.loggingOut))
        XCTAssertEqual(.slate, getAuthenticationStateTone(nil))

        XCTAssertEqual("Signing in", getOperationTypeLabel(.authenticate))
        XCTAssertEqual("Removing", getOperationTypeLabel(.delete))
        XCTAssertEqual("Working", getOperationTypeLabel(nil))

        XCTAssertEqual("WireGuard", getTunnelModeLabel(.wireguard))
        XCTAssertEqual("QUIC", getTunnelModeLabel(.quicv0))
        XCTAssertEqual("Automatic", getTunnelModeLabel(.unspecified))

        XCTAssertEqual("TUN", getImplementationModeLabel(.tun))
        XCTAssertEqual("Automatic", getImplementationModeLabel(nil))

        XCTAssertEqual("Dual stack", getL3ModeLabel(.both))
        XCTAssertEqual("IPv6 only", getL3ModeLabel(.v6))

        XCTAssertEqual("Split", getDNSModeLabel(.default))
        XCTAssertEqual("Split", getDNSModeLabel(.unspecified))
        XCTAssertEqual("Full", getDNSModeLabel(.full))
        XCTAssertEqual("Disabled", getDNSModeLabel(.disabled))
    }

    func testGetErrorTitle() {
        do {
            XCTAssertEqual("Something went wrong", getErrorTitle(nil))
        }
        do {
            let err = getTestError(.clusterUnreachable)
            XCTAssertEqual("Cluster unreachable", getErrorTitle(err))
            XCTAssertEqual("Check your Internet connection and that the Cluster domain is correct.", getErrorHint(err))
        }
        do {
            XCTAssertEqual("Sign in required", getErrorTitle(getTestError(.authenticationRequired)))
        }
        do {
            XCTAssertNil(getErrorHint(getTestError(.internal)))
        }
    }

    func testIsErrorRetryable() {
        XCTAssertFalse(isErrorRetryable(nil))
        XCTAssertTrue(isErrorRetryable(getTestError(.clusterUnreachable, retryable: true)))
        XCTAssertFalse(isErrorRetryable(getTestError(.operationCanceled, retryable: true)))
        XCTAssertFalse(isErrorRetryable(getTestError(.authenticationFailed)))
    }

    func testGetDomainState() {
        let status = getTestStatus(getTestDomain("a.example.com"), getTestDomain("b.example.com"))

        XCTAssertNil(getDomainState(nil, "a.example.com"))
        XCTAssertNil(getDomainState(status, nil))
        XCTAssertNil(getDomainState(status, ""))
        XCTAssertNil(getDomainState(status, "c.example.com"))
        XCTAssertEqual("b.example.com", getDomainState(status, "b.example.com")?.domain)
        XCTAssertEqual(["a.example.com", "b.example.com"], getDomains(status))
        XCTAssertEqual([], getDomains(nil))
    }

    func testSelectDomain() {
        do {
            XCTAssertNil(selectDomain(nil, nil))
        }
        do {
            XCTAssertNil(selectDomain(getTestStatus(), "example.com"))
        }
        do {
            let status = getTestStatus(getTestDomain("b.example.com"), getTestDomain("a.example.com"))
            XCTAssertEqual("a.example.com", selectDomain(status, nil))
            XCTAssertEqual("b.example.com", selectDomain(status, "b.example.com"))
            XCTAssertEqual("a.example.com", selectDomain(status, "c.example.com"))
        }
        do {
            let status = getTestStatus(
                getTestDomain("a.example.com"),
                getTestDomain("b.example.com", auth: .authenticated)
            )
            XCTAssertEqual("b.example.com", selectDomain(status, nil))
        }
        do {
            let status = getTestStatus(
                getTestDomain("a.example.com", auth: .authenticated),
                getTestDomain("b.example.com", conn: .connected)
            )
            XCTAssertEqual("b.example.com", selectDomain(status, nil))
        }
    }

    func testResolveSelectedDomain() {
        let status = getTestStatus(getTestDomain("a.example.com"), getTestDomain("b.example.com"))

        XCTAssertEqual("c.example.com", resolveSelectedDomain("c.example.com", status, "a.example.com"))
        XCTAssertEqual("b.example.com", resolveSelectedDomain(nil, status, "b.example.com"))
        XCTAssertEqual("a.example.com", resolveSelectedDomain(nil, status, nil))
        XCTAssertNil(resolveSelectedDomain(nil, nil, "a.example.com"))
    }

    func testGetTunnelDomainState() {
        do {
            XCTAssertNil(getTunnelDomainState(nil))
        }
        do {
            XCTAssertNil(getTunnelDomainState(getTestStatus(getTestDomain("a.example.com"))))
        }
        do {
            let status = getTestStatus(
                getTestDomain("a.example.com"),
                getTestDomain("b.example.com", conn: .reconnecting)
            )
            XCTAssertEqual("b.example.com", getTunnelDomainState(status)?.domain)
        }
    }

    func testValidateDomain() {
        XCTAssertEqual("The Cluster domain is required", validateDomain(""))
        XCTAssertEqual("The Cluster domain is required", validateDomain("   "))
        XCTAssertEqual("Invalid Cluster domain", validateDomain("example"))
        XCTAssertEqual("Invalid Cluster domain", validateDomain("-example.com"))
        XCTAssertEqual("Invalid Cluster domain", validateDomain("exa mple.com"))
        XCTAssertEqual("Invalid Cluster domain", validateDomain("example..com"))
        XCTAssertEqual("Invalid Cluster domain", validateDomain("bücher.example"))
        XCTAssertEqual("The Cluster domain is too long", validateDomain(String(repeating: "a", count: 250) + ".com"))
        XCTAssertEqual("A Cluster domain label is too long", validateDomain(String(repeating: "a", count: 64) + ".com"))
        XCTAssertNil(validateDomain("example.com"))
        XCTAssertNil(validateDomain("Example.COM"))
        XCTAssertNil(validateDomain("sub-1.example.com"))
        XCTAssertNil(validateDomain("xn--bcher-kva.example"))
    }

    func testNormalizeDomain() {
        XCTAssertEqual("example.com", normalizeDomain("example.com"))
        XCTAssertEqual("example.com", normalizeDomain(" Example.COM "))
        XCTAssertEqual("example.com", normalizeDomain("https://example.com/"))
        XCTAssertEqual("example.com", normalizeDomain("https://example.com/login?x=1#y"))
        XCTAssertEqual("example.com", normalizeDomain("example.com."))
        XCTAssertEqual("example.com", normalizeDomain("user@example.com"))
        XCTAssertEqual("example.com", normalizeDomain("example.com:443"))
        XCTAssertEqual("xn--bcher-kva.example", normalizeDomain("bücher.example"))
        XCTAssertEqual("xn--bcher-kva.example", normalizeDomain("BÜCHER.example"))
        XCTAssertEqual("", normalizeDomain("  "))
    }

    func testEncodePunycode() {
        XCTAssertEqual("bcher-kva", encodePunycode("bücher"))
        XCTAssertEqual("mnchen-3ya", encodePunycode("münchen"))
        XCTAssertEqual("wgv71a119e", encodePunycode("日本語"))
        XCTAssertEqual("-with-SUPER-MONKEYS-pc58ag80a8qai00g7n9n", encodePunycode("安室奈美恵-with-SUPER-MONKEYS"))
        XCTAssertEqual("abc-", encodePunycode("abc"))

        XCTAssertEqual("xn--wgv71a119e.jp", toASCIIDomain("日本語.jp"))
        XCTAssertEqual("example.com", toASCIIDomain("example.com"))
    }
}
