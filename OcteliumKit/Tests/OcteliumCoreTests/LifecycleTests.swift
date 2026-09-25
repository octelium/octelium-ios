import OcteliumProto
import XCTest

@testable import OcteliumCore

final class LifecycleTests: XCTestCase {

    func testVPNState() {
        XCTAssertFalse(isVPNActive(.invalid))
        XCTAssertFalse(isVPNActive(.disconnected))
        XCTAssertTrue(isVPNActive(.connecting))
        XCTAssertTrue(isVPNActive(.connected))
        XCTAssertTrue(isVPNActive(.reasserting))
        XCTAssertTrue(isVPNActive(.disconnecting))

        XCTAssertEqual(.disconnected, getVPNConnectionState(.invalid))
        XCTAssertEqual(.disconnected, getVPNConnectionState(.disconnected))
        XCTAssertEqual(.connecting, getVPNConnectionState(.connecting))
        XCTAssertEqual(.connected, getVPNConnectionState(.connected))
        XCTAssertEqual(.reconnecting, getVPNConnectionState(.reasserting))
        XCTAssertEqual(.disconnecting, getVPNConnectionState(.disconnecting))
    }

    func testMergeStatus() {
        let app = getTestStatus(
            getTestDomain("a.example.com", auth: .authenticated),
            getTestDomain("b.example.com", auth: .authenticated),
            revision: 4,
            instanceID: "app"
        )

        do {
            XCTAssertNil(mergeStatus(nil, TunnelSnapshot(domain: "a.example.com", state: .connected)))
            XCTAssertEqual(app, mergeStatus(app, nil))
            XCTAssertEqual(app, mergeStatus(app, TunnelSnapshot(state: .connected)))
            XCTAssertEqual(app, mergeStatus(app, TunnelSnapshot(domain: "a.example.com", state: .disconnected)))
            XCTAssertEqual(app, mergeStatus(app, TunnelSnapshot(domain: "c.example.com", state: .connected)))
        }

        do {
            let ret = mergeStatus(app, TunnelSnapshot(domain: "a.example.com", state: .connecting))
            XCTAssertEqual("app", ret?.instanceID)
            XCTAssertEqual(4, ret?.revision)
            XCTAssertEqual(.connecting, getDomainState(ret, "a.example.com")?.connection.state)
            XCTAssertEqual(.disconnected, getDomainState(ret, "b.example.com")?.connection.state)
            XCTAssertEqual(.authenticated, getDomainState(ret, "a.example.com")?.authentication.state)
        }

        do {
            var tunnelDomain = getTestDomain(
                "a.example.com",
                auth: .authenticated,
                conn: .connected,
                op: getTestOperation(type: .connect, state: .succeeded, id: "tunnel-op", updatedAt: 200)
            )
            tunnelDomain.connection.mtu = 1280
            tunnelDomain.connection.tunnelMode = .quicv0

            let tunnel = TunnelSnapshot(
                domain: "a.example.com",
                state: .connected,
                status: getTestStatus(tunnelDomain, getTestDomain("b.example.com"), instanceID: "tunnel")
            )

            let ret = mergeStatus(app, tunnel)
            let state = getDomainState(ret, "a.example.com")
            XCTAssertEqual(.connected, state?.connection.state)
            XCTAssertEqual(1280, state?.connection.mtu)
            XCTAssertEqual(.quicv0, state?.connection.tunnelMode)
            XCTAssertEqual("tunnel-op", state?.lastOperation.id)
            XCTAssertEqual(.disconnected, getDomainState(ret, "b.example.com")?.connection.state)
        }

        do {
            let appDomain = getTestDomain(
                "a.example.com",
                auth: .authenticated,
                op: getTestOperation(type: .authenticate, state: .succeeded, id: "app-op", updatedAt: 300)
            )
            let tunnelDomain = getTestDomain(
                "a.example.com",
                auth: .authenticated,
                conn: .connected,
                op: getTestOperation(type: .connect, state: .succeeded, id: "tunnel-op", updatedAt: 200)
            )

            let ret = mergeStatus(
                getTestStatus(appDomain),
                TunnelSnapshot(domain: "a.example.com", state: .connected, status: getTestStatus(tunnelDomain))
            )
            XCTAssertEqual("app-op", getDomainState(ret, "a.example.com")?.lastOperation.id)
            XCTAssertEqual(.connected, getDomainState(ret, "a.example.com")?.connection.state)
        }

        do {
            let tunnelDomain = getTestDomain("a.example.com", conn: .disconnected)
            let ret = mergeStatus(
                app,
                TunnelSnapshot(domain: "a.example.com", state: .connected, status: getTestStatus(tunnelDomain))
            )
            XCTAssertEqual(.connected, getDomainState(ret, "a.example.com")?.connection.state)
        }

        do {
            var tunnelDomain = getTestDomain("a.example.com", conn: .reconnecting)
            tunnelDomain.lastError = getTestError(.clusterUnreachable, retryable: true)
            tunnelDomain.connection.mtu = 1400

            let ret = mergeStatus(
                app,
                TunnelSnapshot(domain: "a.example.com", state: .disconnecting, status: getTestStatus(tunnelDomain))
            )
            let state = getDomainState(ret, "a.example.com")
            XCTAssertEqual(.disconnecting, state?.connection.state)
            XCTAssertEqual(1400, state?.connection.mtu)
            XCTAssertEqual(.clusterUnreachable, state?.lastError.code)
        }

        do {
            let ret = mergeStatus(
                app,
                TunnelSnapshot(
                    domain: "a.example.com",
                    state: .disconnected,
                    status: getTestStatus(getTestDomain("a.example.com", conn: .connected)),
                    error: getTestError(.authenticationRequired)
                )
            )
            let state = getDomainState(ret, "a.example.com")
            XCTAssertEqual(.disconnected, state?.connection.state)
            XCTAssertEqual(.authenticationRequired, state?.lastError.code)
            XCTAssertFalse(getDomainState(ret, "b.example.com")!.hasLastError)
        }

        do {
            let ret = mergeStatus(app, TunnelSnapshot(domain: "a.example.com", state: .reasserting))
            XCTAssertEqual(.reconnecting, getDomainState(ret, "a.example.com")?.connection.state)
            XCTAssertEqual("a.example.com", getTunnelDomainState(ret)?.domain)
        }
    }

    func testGetOnDemandDomain() {
        do {
            XCTAssertNil(getOnDemandDomain(nil, nil))
        }
        do {
            let status = getTestStatus(getTestDomain("a.example.com", auth: .authenticated))
            XCTAssertNil(getOnDemandDomain(status, "a.example.com"))
        }
        do {
            let status = getTestStatus(
                getTestDomain("b.example.com", auth: .authenticated, autoConnect: true),
                getTestDomain("a.example.com", auth: .authenticated, autoConnect: true),
                getTestDomain("c.example.com", autoConnect: true)
            )
            XCTAssertEqual("a.example.com", getOnDemandDomain(status, nil))
            XCTAssertEqual("b.example.com", getOnDemandDomain(status, "b.example.com"))
            XCTAssertEqual("a.example.com", getOnDemandDomain(status, "c.example.com"))
        }
        do {
            let status = getTestStatus(
                getTestDomain("a.example.com", auth: .authenticated, autoConnect: true),
                getTestDomain("b.example.com", auth: .authenticated, conn: .connected)
            )
            XCTAssertEqual("a.example.com", getOnDemandDomain(status, "b.example.com"))
        }
        do {
            let status = getTestStatus(
                getTestDomain("a.example.com", auth: .authenticated, autoConnect: true),
                getTestDomain("b.example.com", auth: .authenticated, autoConnect: true)
            )
            XCTAssertEqual("b.example.com", getOnDemandDomain(status, "a.example.com", excluding: "a.example.com"))
            XCTAssertEqual("b.example.com", getOnDemandDomain(status, nil, excluding: "a.example.com"))
            XCTAssertEqual("a.example.com", getOnDemandDomain(status, nil, excluding: "c.example.com"))
            XCTAssertNil(getOnDemandDomain(getTestStatus(status.domains[0]), nil, excluding: "a.example.com"))
        }
    }
}
