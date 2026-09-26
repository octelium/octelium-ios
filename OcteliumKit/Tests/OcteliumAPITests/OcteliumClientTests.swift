#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GRPCCore
import OcteliumCore
import OcteliumProto
import SwiftProtobuf
import XCTest

@testable import OcteliumAPI

final class OcteliumClientTests: XCTestCase {

    private let cluster = FakeCluster()
    private let statusStore = StatusStore()
    private let tunnels = FakeTunnels()
    private let host = FakeHost()
    private let key = Data((0..<32).map { UInt8($0) })
    private let device = DeviceInfo(installationID: "8a3b1f0e-6d4c-4b1a-9e2f-0c7d5e3a9b11", name: "iPhone")

    private var tmp: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cluster.close()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func newStateDir() throws -> URL {
        let ret = tmp.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: ret, withIntermediateDirectories: true)
        return ret
    }

    private func getClient(_ dir: URL? = nil, hasTunnels: Bool = true) throws -> OcteliumClient {
        let dir = try dir ?? newStateDir()
        stateDir = dir

        let cluster = self.cluster
        let tunnels = self.tunnels
        let statusStore = self.statusStore

        return try OcteliumClient(
            db: DB(dir: dir, key: key),
            device: device,
            channels: { _ in cluster.newChannel() },
            tunnels: hasTunnels ? { tunnels.create($0) } : nil,
            host: host,
            onStatus: { statusStore.update($0) },
            network: NetworkWatcher { _ in .milliseconds(20) }
        )
    }

    private func getDB() throws -> DB {
        try DB(dir: stateDir, key: key)
    }

    private func awaitDomain(
        _ domain: String = "example.com",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ fn: (Daemonv1.DomainState) -> Bool
    ) async throws -> Daemonv1.DomainState {
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            if let ret = getDomainState(statusStore.status, domain), fn(ret) {
                return ret
            }

            try await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Timed out waiting for the domain \(domain)", file: file, line: line)
        throw StatusError(.deadlineExceeded, "Timed out waiting for the domain \(domain)")
    }

    private func awaitCondition(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ fn: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(10)

        while !(try await fn()) {
            if Date() > deadline {
                XCTFail("Timed out waiting for the condition", file: file, line: line)
                return
            }

            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertCode(
        _ code: StatusCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ fn: () async throws -> Void
    ) async {
        do {
            try await fn()
            XCTFail(file: file, line: line)
        } catch let err as StatusError {
            XCTAssertEqual(code, err.code, err.message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    @discardableResult
    private func authenticate(_ c: OcteliumClient, _ domain: String = "example.com") async throws -> Daemonv1.DomainState {
        let op = try await c.authenticateToken(domain, testAuthenticationToken)
        XCTAssertEqual(.authenticate, op.type)

        return try await awaitDomain(op.domain) { $0.lastOperation.state == .succeeded }
    }

    @discardableResult
    private func connect(_ c: OcteliumClient, _ domain: String = "example.com") async throws -> Daemonv1.DomainState {
        _ = try await c.connect(domain)
        return try await awaitDomain(domain) { $0.connection.state == .connected }
    }

    private func getResponse(_ event: Userv1.ConnectResponse.OneOf_Event, createdAt: Date? = Date()) -> Userv1.ConnectResponse {
        var ret = Userv1.ConnectResponse()
        ret.event = event
        if let createdAt {
            ret.createdAt = Google_Protobuf_Timestamp(date: createdAt)
        }
        return ret
    }

    func testAuthenticateToken() async throws {
        let c = try getClient()

        let initial = try await c.getStatus()
        XCTAssertTrue(initial.domains.isEmpty)

        let st = try await authenticate(c, "Example.COM.")

        XCTAssertEqual("example.com", st.domain)
        XCTAssertEqual(.authenticated, st.authentication.state)
        XCTAssertTrue(st.authentication.hasAuthenticatedAt)
        XCTAssertTrue(st.authentication.hasExpiresAt)
        XCTAssertFalse(st.hasLastError)

        do {
            XCTAssertEqual(1, cluster.authenticateRequests.count)
            let req = try XCTUnwrap(cluster.authenticateRequests.first)
            XCTAssertEqual(testAuthenticationToken, req.authenticationToken)
            XCTAssertTrue(req.codeVerifier.isEmpty)
        }

        do {
            XCTAssertEqual(1, cluster.registerRequests.count)
            let req = try XCTUnwrap(cluster.registerRequests.first)
            XCTAssertEqual(.ios, req.info.osType)
            XCTAssertEqual(getDeviceID(device.installationID), req.info.id)
            XCTAssertEqual("iPhone", req.info.hostname)
            try await awaitCondition { !self.cluster.getCalls("RegisterDeviceFinish").isEmpty }
        }

        do {
            let ret = try await c.getAPICredential("example.com")
            XCTAssertEqual("access-1", ret.accessToken)
            XCTAssertTrue(ret.hasExpiresAt)
            XCTAssertTrue(cluster.getCalls("AuthenticateWithRefreshToken").isEmpty)
        }

        XCTAssertEqual("refresh-1", try getDB().getSessionToken("example.com")?.refreshToken)

        await c.close()
    }

    func testAuthenticateTokenFailed() async throws {
        let c = try getClient()

        _ = try await c.authenticateToken("example.com", "invalid")
        let st = try await awaitDomain { $0.lastOperation.state == .failed }

        XCTAssertEqual(.loggedOut, st.authentication.state)
        XCTAssertEqual(.authenticationRequired, st.lastError.code)
        XCTAssertEqual("Invalid authentication Token", st.lastError.message)
        XCTAssertEqual(st.lastError, st.lastOperation.error)

        await assertCode(.invalidArgument) { _ = try await c.authenticateToken("example.com", "") }
        await assertCode(.invalidArgument) { _ = try await c.authenticateToken("not a domain", testAuthenticationToken) }
        await assertCode(.invalidArgument) { _ = try await c.authenticateToken("192.168.1.1", testAuthenticationToken) }
        await assertCode(.unauthenticated) { _ = try await c.getAPICredential("example.com") }
        await assertCode(.unauthenticated) { _ = try await c.connect("example.com") }
        await assertCode(.notFound) { _ = try await c.connect("unknown.example.com") }

        await c.close()
    }

    func testAuthenticateBrowser() async throws {
        let c = try getClient()

        let op = try await c.authenticateBrowser("example.com")
        XCTAssertEqual(.waitingForUser, op.state)
        XCTAssertTrue(op.cancellable)

        let loginURL = op.action.openURL.url
        let prefix = "https://example.com/login?octelium_req="
        XCTAssertTrue(loginURL.hasPrefix(prefix))

        let req = try Authv1.ClientLoginRequest(
            serializedBytes: try XCTUnwrap(decodeBase64URL(String(loginURL.dropFirst(prefix.count))))
        )
        XCTAssertEqual(.app, req.callbackType)
        XCTAssertEqual(.v1, req.apiVersion)
        XCTAssertEqual(32, req.codeChallenge.count)

        func getCallbackURL(_ token: String, _ challenge: Data) throws -> String {
            var resp = Authv1.ClientLoginResponse()
            resp.authenticationToken = token
            resp.codeChallenge = challenge

            let data: Data = try resp.serializedBytes()
            return "\(authCallbackURL)?octelium_response=\(encodeBase64URL(data))"
        }

        let status = try await c.getStatus()
        XCTAssertEqual(.authenticating, status.domains.first?.authentication.state)

        await assertCode(.invalidArgument) {
            _ = try await c.completeAuthentication(op.id, getCallbackURL(testAuthenticationToken, Data(count: 32)))
        }
        await assertCode(.invalidArgument) {
            _ = try await c.completeAuthentication(op.id, "https://example.com/callback/success")
        }
        await assertCode(.invalidArgument) {
            _ = try await c.completeAuthentication(op.id, getCallbackURL("", req.codeChallenge))
        }
        await assertCode(.notFound) {
            _ = try await c.completeAuthentication("unknown", getCallbackURL("x", req.codeChallenge))
        }

        let ret = try await c.completeAuthentication(op.id, getCallbackURL(testAuthenticationToken, req.codeChallenge))
        XCTAssertEqual(.running, ret.state)

        let st = try await awaitDomain { $0.lastOperation.state == .succeeded }
        XCTAssertEqual(.authenticated, st.authentication.state)

        let verifier = try XCTUnwrap(cluster.authenticateRequests.first?.codeVerifier)
        XCTAssertEqual(req.codeChallenge, Data(SHA256.hash(data: verifier)))

        await assertCode(.failedPrecondition) {
            _ = try await c.completeAuthentication(op.id, getCallbackURL(testAuthenticationToken, req.codeChallenge))
        }

        await c.close()
    }

    func testCancelAuthentication() async throws {
        let c = try getClient()

        let op = try await c.authenticateBrowser("example.com")
        await assertCode(.failedPrecondition) { _ = try await c.authenticateBrowser("example.com") }

        let ret = try await c.cancelOperation(op.id)
        XCTAssertEqual(.canceled, ret.state)
        XCTAssertEqual(.operationCanceled, ret.error.code)

        let st = try await awaitDomain { $0.authentication.state == .loggedOut }
        XCTAssertFalse(st.hasLastError)

        let cur = try await c.getOperation(op.id)
        XCTAssertEqual(.canceled, cur.state)

        let canceled = try await c.cancelOperation(op.id)
        XCTAssertEqual(.canceled, canceled.state)

        await assertCode(.notFound) { _ = try await c.getOperation("unknown") }
        await assertCode(.invalidArgument) { _ = try await c.getOperation("") }

        let next = try await c.authenticateBrowser("example.com")
        _ = try await c.logout("example.com")

        let superseded = try await c.getOperation(next.id)
        XCTAssertEqual(.canceled, superseded.state)

        await c.close()
    }

    func testConnect() async throws {
        let c = try getClient()
        try await authenticate(c)

        await c.setNetworkState(NetworkState(isAvailable: true, id: "100"))

        let st = try await connect(c)

        do {
            XCTAssertEqual(1, tunnels.all.count)
            let tunnel = try XCTUnwrap(tunnels.last)
            XCTAssertEqual(1, tunnel.configs.count)

            let cfg = try XCTUnwrap(tunnel.configs.first)
            XCTAssertEqual("example.com", cfg.domain)
            XCTAssertEqual(cluster.connectionState, cfg.state)
            XCTAssertEqual(.wireguard, cfg.preferences.tunnelMode)
            XCTAssertEqual(.default, cfg.preferences.dnsMode)
            try await awaitCondition { tunnel.networkStates.contains(NetworkState(isAvailable: true, id: "100")) }

            let initialize = try XCTUnwrap(cluster.initRequests.first).initialize
            XCTAssertEqual(.v6, initialize.l3Mode)
            XCTAssertEqual(.unset, initialize.connectionType)
            XCTAssertFalse(initialize.ignoreDns)

            XCTAssertEqual(1, host.specs.count)
            let (domain, spec) = try XCTUnwrap(host.specs.first)
            XCTAssertEqual("example.com", domain)
            XCTAssertEqual(["100.64.0.5/32", "fdee:1::5/128"], spec.addresses.map(\.description))
        }

        do {
            XCTAssertEqual(.connect, st.lastOperation.type)
            XCTAssertEqual(.succeeded, st.lastOperation.state)
            XCTAssertTrue(st.connection.hasConnectedAt)
            XCTAssertEqual(1280, st.connection.mtu)
            XCTAssertEqual(.wireguard, st.connection.tunnelMode)
            XCTAssertEqual(.tun, st.connection.implementationMode)
            XCTAssertEqual(["fdee:1::5/128"], st.connection.addresses.map(\.v6))
            XCTAssertEqual(["fdee:1::53"], st.connection.dns.servers)
            XCTAssertTrue(st.connection.dns.isConfigured)
            XCTAssertEqual(.default, st.connection.options.dns.mode)
        }

        await assertCode(.failedPrecondition) { _ = try await c.connect("example.com") }

        let tunnel = try XCTUnwrap(tunnels.last)

        do {
            var arg = Userv1.ConnectResponse.AddGateway()
            arg.gateway = getTestGateway("gw-2")
            cluster.send(getResponse(.addGateway(arg)))

            try await awaitCondition { tunnel.configs.count == 2 }
            XCTAssertEqual(["gw-1", "gw-2"], tunnel.configs.last?.state.gateways.map(\.id))
        }

        do {
            var arg = Userv1.ConnectResponse.UpdateDNS()
            arg.dns.servers = ["fdee:1::54"]
            cluster.send(getResponse(.updateDns(arg), createdAt: nil))

            _ = try await awaitDomain { $0.connection.dns.servers == ["fdee:1::54"] }
            try await awaitCondition { self.host.specs.count == 2 }
        }

        do {
            var arg = Userv1.ConnectResponse.DeleteGateway()
            arg.id = "gw-1"
            cluster.send(getResponse(.deleteGateway(arg), createdAt: Date().addingTimeInterval(-3600)))

            arg.id = "gw-2"
            cluster.send(getResponse(.deleteGateway(arg), createdAt: nil))

            try await awaitCondition { tunnel.configs.count == 4 }
            XCTAssertEqual(["gw-1"], tunnel.configs.last?.state.gateways.map(\.id))
        }

        do {
            let id = tunnel.requestAccessToken()
            try await awaitCondition { tunnel.responses.contains { $0.0 == id } }
            XCTAssertEqual(.getAccessToken("access-1"), tunnel.responses.first { $0.0 == id }?.1)
        }

        do {
            await c.setNetworkState(NetworkState(isAvailable: false, id: ""))
            try await awaitCondition { tunnel.networkStates.last == NetworkState(isAvailable: false, id: "") }
        }

        do {
            let op = try await c.disconnect("example.com")
            XCTAssertEqual(.disconnect, op.type)

            let ret = try await awaitDomain {
                $0.connection.state == .disconnected && $0.lastOperation.state == .succeeded
            }
            XCTAssertFalse(ret.hasLastError)
            XCTAssertFalse(ret.connection.hasConnectedAt)
            XCTAssertTrue(ret.connection.addresses.isEmpty)
            XCTAssertTrue(tunnel.isClosed)
            try await awaitCondition { !self.cluster.getCalls("Disconnect").isEmpty }
        }

        do {
            let op = try await c.disconnect("example.com")
            XCTAssertEqual(.succeeded, op.state)
        }

        await c.close()
    }

    func testConnectOptions() async throws {
        let c = try getClient()
        try await authenticate(c)

        var settings = Daemonv1.DomainSettings()
        settings.connectionOptions.tunnelMode = .quicv0
        settings.connectionOptions.l3Mode = .both
        settings.connectionOptions.dns.mode = .disabled
        settings.connectionOptions.mtu = 1400
        _ = try await c.updateDomainSettings("example.com", settings)

        let st = try await connect(c)

        let initialize = try XCTUnwrap(cluster.initRequests.first).initialize
        XCTAssertEqual(.both, initialize.l3Mode)
        XCTAssertEqual(.quicv0, initialize.connectionType)
        XCTAssertTrue(initialize.ignoreDns)

        let prefs = try XCTUnwrap(tunnels.last?.configs.first).preferences
        XCTAssertEqual(.quicv0, prefs.tunnelMode)
        XCTAssertEqual(.disabled, prefs.dnsMode)
        XCTAssertEqual(1400, prefs.mtu)

        XCTAssertEqual(.quicv0, st.connection.tunnelMode)
        XCTAssertEqual(.disabled, st.connection.dns.mode)
        XCTAssertFalse(st.connection.dns.isConfigured)

        await c.close()
    }

    func testReconnect() async throws {
        let c = try getClient()
        try await authenticate(c)
        try await connect(c)

        cluster.closeSession(RPCError(code: .unavailable, message: "Stream reset"))

        try await awaitCondition { self.cluster.sessionCount == 2 }
        let st = try await awaitDomain { $0.connection.state == .connected }

        let tunnel = try XCTUnwrap(tunnels.last)
        XCTAssertEqual(1, tunnels.all.count)
        try await awaitCondition { tunnel.configs.count == 2 }
        let initializeCount = cluster.initRequests.filter { req in
            if case .initialize = req.type {
                return true
            }
            return false
        }.count
        XCTAssertEqual(2, initializeCount)
        XCTAssertEqual(.succeeded, st.lastOperation.state)

        do {
            cluster.send(getResponse(.disconnect(Userv1.ConnectResponse.Disconnect()), createdAt: nil))

            let ret = try await awaitDomain { $0.connection.state == .disconnected }
            XCTAssertFalse(ret.hasLastError)
            XCTAssertTrue(tunnel.isClosed)
        }

        do {
            try await connect(c)
            XCTAssertEqual(2, tunnels.all.count)
        }

        await c.close()
    }

    func testConnectFailures() async throws {
        let c = try getClient()
        try await authenticate(c)

        do {
            host.setError(ClientError("The VPN configuration could not be saved"))
            _ = try await c.connect("example.com")

            let st = try await awaitDomain { $0.hasLastError }
            XCTAssertEqual(.connecting, st.connection.state)
            XCTAssertEqual(.networkConfigurationFailed, st.lastError.code)
            XCTAssertEqual("The VPN configuration could not be saved", st.lastError.message)
            XCTAssertTrue(st.lastError.retryable)

            host.setError(nil)
            _ = try await awaitDomain { $0.connection.state == .connected && !$0.hasLastError }
        }

        let tunnel = try XCTUnwrap(tunnels.last)

        do {
            tunnel.setStatus(TunnelStatus(state: .reconnecting, error: .transport, message: "Timed out"))

            let st = try await awaitDomain { $0.connection.state == .reconnecting }
            XCTAssertEqual(.connectionFailed, st.lastError.code)
            XCTAssertEqual("Timed out", st.lastError.message)
            XCTAssertEqual(1, st.connection.addresses.count)

            tunnel.setStatus(TunnelStatus(state: .connected))
            _ = try await awaitDomain { $0.connection.state == .connected && !$0.hasLastError }
        }

        do {
            tunnel.setStatus(TunnelStatus(state: .reconnecting, error: .unauthenticated, message: "The access token is invalid"))

            let st = try await awaitDomain { $0.connection.state == .disconnected }
            XCTAssertEqual(.authenticationRequired, st.lastError.code)
            XCTAssertEqual(.succeeded, st.lastOperation.state)
            XCTAssertTrue(tunnel.isClosed)
        }

        await c.close()
    }

    func testSingleConnection() async throws {
        let c = try getClient()
        try await authenticate(c, "example.com")
        try await authenticate(c, "example.org")

        try await connect(c, "example.com")

        await assertCode(.failedPrecondition) { _ = try await c.connect("example.org") }

        _ = try await c.disconnect("example.com")
        _ = try await awaitDomain { $0.connection.state == .disconnected }

        try await connect(c, "example.org")

        await c.close()
    }

    func testConnectUnsupported() async throws {
        let c = try getClient(hasTunnels: false)
        try await authenticate(c)

        await assertCode(.failedPrecondition) { _ = try await c.connect("example.com") }

        let st = try await c.getStatus().domains.first
        XCTAssertEqual(.disconnected, st?.connection.state)

        await c.close()
    }

    func testRefresh() async throws {
        cluster.setExpiresIn(60)

        let c = try getClient()
        try await authenticate(c)

        let ret = try await c.getAPICredential("example.com")
        XCTAssertEqual("access-2", ret.accessToken)
        XCTAssertEqual(1, cluster.getCalls("AuthenticateWithRefreshToken").count)
        XCTAssertEqual("refresh-2", try getDB().getSessionToken("example.com")?.refreshToken)

        do {
            cluster.clearRefreshTokens()
            await assertCode(.unauthenticated) { _ = try await c.getAPICredential("example.com") }

            let st = try await awaitDomain { $0.authentication.state == .loggedOut }
            XCTAssertEqual(.authenticationRequired, st.lastError.code)
            XCTAssertNil(try getDB().getSessionToken("example.com"))
        }

        await c.close()
    }

    func testNetworkUnavailable() async throws {
        cluster.setExpiresIn(60)

        let c = try getClient()
        try await authenticate(c)

        await c.setNetworkState(NetworkState(isAvailable: false, id: ""))
        await assertCode(.unavailable) { _ = try await c.getAPICredential("example.com") }

        await c.setNetworkState(NetworkState(isAvailable: true, id: "100"))

        let ret = try await c.getAPICredential("example.com")
        XCTAssertEqual("access-2", ret.accessToken)

        await c.close()
    }

    func testLogout() async throws {
        let c = try getClient()
        try await authenticate(c)
        try await connect(c)

        let op = try await c.logout("example.com")
        XCTAssertEqual(.logout, op.type)

        let st = try await awaitDomain {
            $0.lastOperation.state == .succeeded && $0.authentication.state == .loggedOut
        }
        XCTAssertEqual(.disconnected, st.connection.state)
        XCTAssertEqual(true, tunnels.last?.isClosed)

        let calls = cluster.getCalls("Logout")
        XCTAssertEqual(1, calls.count)
        XCTAssertEqual(["refresh-1"], calls.first.map { Array($0[stringValues: refreshTokenMetadataKey]) })
        XCTAssertNil(try getDB().getSessionToken("example.com"))

        await c.close()
    }

    func testDeleteDomain() async throws {
        let c = try getClient()
        try await authenticate(c)
        try await authenticate(c, "example.org")

        let op = try await c.deleteDomain("example.com")
        XCTAssertEqual(.delete, op.type)

        try await awaitCondition { try await c.getStatus().domains.map(\.domain) == ["example.org"] }

        XCTAssertNil(try getDB().get("example.com"))
        await assertCode(.notFound) { _ = try await c.getAPICredential("example.com") }

        let ret = try await c.getOperation(op.id)
        XCTAssertEqual(.succeeded, ret.state)

        await c.close()
    }

    func testSettings() async throws {
        let dir = try newStateDir()

        do {
            let c = try getClient(dir)

            var settings = Daemonv1.DomainSettings()
            settings.domain = "ignored"
            settings.autoConnect = true

            let ret = try await c.updateDomainSettings("Example.COM", settings)
            XCTAssertEqual("example.com", ret.domain)
            XCTAssertTrue(ret.autoConnect)

            let st = try await awaitDomain { $0.settings.autoConnect }
            XCTAssertEqual(.loggedOut, st.authentication.state)

            await assertCode(.invalidArgument) {
                var arg = Daemonv1.DomainSettings()
                arg.connectionOptions.implementationMode = .kernel
                _ = try await c.updateDomainSettings("example.com", arg)
            }

            await c.close()

            await assertCode(.unavailable) { _ = try await c.getStatus() }
        }

        do {
            let c = try getClient(dir)
            let status = try await c.getStatus()
            let st = try XCTUnwrap(status.domains.first)
            XCTAssertEqual("example.com", st.domain)
            XCTAssertTrue(st.settings.autoConnect)
            await c.close()
        }
    }

    func testSharedState() async throws {
        let dir = try newStateDir()

        let app = try getClient(dir, hasTunnels: false)
        let tunnel = try getClient(dir)

        try await authenticate(app)

        do {
            let st = try await tunnel.getStatus()
            XCTAssertEqual(["example.com"], st.domains.map(\.domain))
            XCTAssertEqual(.authenticated, st.domains.first?.authentication.state)
        }

        do {
            var settings = Daemonv1.DomainSettings()
            settings.autoConnect = true
            _ = try await tunnel.updateDomainSettings("example.com", settings)

            let st = try await app.getStatus()
            XCTAssertEqual(true, st.domains.first?.settings.autoConnect)
        }

        do {
            _ = try await app.logout("example.com")
            _ = try await awaitDomain { $0.lastOperation.type == .logout && $0.lastOperation.state == .succeeded }

            let st = try await tunnel.getStatus()
            XCTAssertEqual(.loggedOut, st.domains.first?.authentication.state)
        }

        XCTAssertNotEqual(app.instanceID, tunnel.instanceID)

        await app.close()
        await tunnel.close()
    }
}
