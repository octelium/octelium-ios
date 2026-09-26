import COctelium
import Foundation
import OcteliumCore
import OcteliumProto
import Synchronization
import XCTest

@testable import LibOctelium

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class Handler: TunnelHandler {
    private struct State {
        var statuses: [TunnelStatus] = []
        var logs: [LogEntry] = []
        var requests: [(UInt64, TunnelRequest)] = []
    }

    private let state = Mutex(State())

    var logs: [LogEntry] {
        state.withLock { $0.logs }
    }

    func onStatus(_ status: TunnelStatus) {
        state.withLock { $0.statuses.append(status) }
    }

    func onLog(_ log: LogEntry) {
        state.withLock { $0.logs.append(log) }
    }

    func onRequest(_ requestID: UInt64, _ request: TunnelRequest) {
        state.withLock { $0.requests.append((requestID, request)) }
    }

    func awaitStatus(_ fn: (TunnelStatus) -> Bool) async throws -> TunnelStatus {
        try await wait("the status") {
            state.withLock { st in
                guard let idx = st.statuses.firstIndex(where: fn) else {
                    return nil
                }

                let ret = st.statuses[idx]
                st.statuses.removeFirst(idx + 1)
                return ret
            }
        }
    }

    func awaitRequest() async throws -> (UInt64, TunnelRequest) {
        try await wait("the request") {
            state.withLock { st in
                st.requests.isEmpty ? nil : st.requests.removeFirst()
            }
        }
    }

    private func wait<T>(_ name: String, _ fn: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            if let ret = fn() {
                return ret
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw StatusError(.deadlineExceeded, "Timed out waiting for \(name)")
    }
}

final class LibOcteliumTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func getGateway(_ id: String, _ tunnelMode: TunnelMode) -> Userv1.Gateway {
        var ret = Userv1.Gateway()
        ret.id = id
        ret.addresses = ["127.0.0.1"]
        ret.cidrs = ["10.100.0.0/16", "fdee:100::/64"]

        if tunnelMode == .quicv0 {
            ret.quicv0.port = 1
        } else {
            ret.wireguard.port = 51820
            ret.wireguard.publicKey = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
        }

        return ret
    }

    private func getConfig(tunnelMode: TunnelMode = .wireguard, key: Data? = Data(repeating: 1, count: 32)) -> TunnelConfig {
        var state = Userv1.ConnectionState()
        state.mtu = 1400
        state.l3Mode = .both

        var address = Metav1.DualStackNetwork()
        address.v4 = "10.200.0.2/32"
        address.v6 = "fdee:200::2/128"
        state.addresses = [address]

        state.gateways = [getGateway("gw-1", tunnelMode)]
        state.dns.servers = ["fdee:100::53"]
        state.cidr.v4 = "10.100.0.0/16"
        state.cidr.v6 = "fdee:100::/64"

        if let key {
            state.x25519Key = key
        }

        return TunnelConfig(
            domain: "example.com",
            state: state,
            preferences: TunnelPreferences(tunnelMode: tunnelMode, dnsMode: .default)
        )
    }

    private func openFIFO() throws -> Int32 {
        let path = tmp.appendingPathComponent("tun").path
        XCTAssertEqual(0, mkfifo(path, 0o600))

        let ret = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(ret, 0)
        return ret
    }

    func testABI() {
        XCTAssertEqual(abiVersionMajor, octelium_abi_version() >> 16)
        XCTAssertEqual(LibOctelium.hostABIVersion, LibOctelium.getABIVersion())
        XCTAssertFalse(LibOctelium.getVersion().isEmpty)
        XCTAssertEqual("1.0", formatABIVersion(LibOctelium.getABIVersion()))
        XCTAssertNoThrow(try LibOctelium.checkABI())
    }

    func testWireGuard() async throws {
        let handler = Handler()
        let lib = try LibOctelium.create(handler, logLevel: .debug)

        XCTAssertThrowsError(try lib.setConfig(getConfig(key: nil))) { err in
            XCTAssertEqual(.invalidArgument, (err as? TunnelError)?.code)
            XCTAssertFalse((err as? TunnelError)?.message.isEmpty ?? true)
        }

        try lib.setConfig(getConfig())

        let (id, req) = try await handler.awaitRequest()
        guard case .applyNetworkConfig(let cfg) = req else {
            return XCTFail()
        }

        XCTAssertEqual(["10.200.0.2/32", "fdee:200::2/128"], cfg.addresses)
        XCTAssertEqual(["10.100.0.0/16", "fdee:100::/64"], cfg.routes)
        XCTAssertEqual(1400, cfg.mtu)
        XCTAssertEqual(["fdee:100::53"], cfg.dns?.servers)
        XCTAssertEqual(true, cfg.dns?.searchDomains.contains("local.example.com"))
        XCTAssertGreaterThan(cfg.generation, 0)

        let spec = try getTunnelSpec(cfg)
        XCTAssertEqual(["10.100.0.0/16", "fdee:100::/64"], spec.routes.map(\.description))

        XCTAssertEqual(TunnelError.Code.notFound.rawValue, lib.complete(id + 1000, .applyNetworkConfig(tunFD: nil)))

        let fd = try openFIFO()
        defer {
            close(fd)
        }

        XCTAssertEqual(0, lib.complete(id, .applyNetworkConfig(tunFD: fd)))

        _ = try await handler.awaitStatus { $0.state == .connected }

        lib.setNetworkState(NetworkState(isAvailable: false, id: ""))
        _ = try await handler.awaitStatus { $0.state == .reconnecting }

        lib.setNetworkState(NetworkState(isAvailable: true, id: "100"))
        _ = try await handler.awaitStatus { $0.state == .connected }

        XCTAssertTrue(handler.logs.contains { $0.level == .debug })

        lib.close()
        lib.close()

        XCTAssertEqual(TunnelError.Code.notFound.rawValue, lib.complete(id, .applyNetworkConfig(tunFD: nil)))
        XCTAssertThrowsError(try lib.setConfig(getConfig())) { err in
            XCTAssertEqual(.invalidState, (err as? TunnelError)?.code)
        }
    }

    func testQUICV0() async throws {
        let handler = Handler()
        let lib = try LibOctelium.create(handler, logLevel: .debug)

        try lib.setConfig(getConfig(tunnelMode: .quicv0, key: nil))

        let (applyID, _) = try await handler.awaitRequest()

        let fd = try openFIFO()
        defer {
            close(fd)
        }

        XCTAssertEqual(0, lib.complete(applyID, .applyNetworkConfig(tunFD: fd)))

        let (tokenID, token) = try await handler.awaitRequest()
        XCTAssertEqual(.getAccessToken, token)

        XCTAssertEqual(0, lib.complete(tokenID, .error(.unauthenticated, "Authentication is required")))

        let st = try await handler.awaitStatus { $0.error == .unauthenticated }
        XCTAssertEqual(.connecting, st.state)

        lib.close()
    }

    func testPlatformError() async throws {
        let handler = Handler()
        let lib = try LibOctelium.create(handler)

        try lib.setConfig(getConfig())

        let (id, _) = try await handler.awaitRequest()
        XCTAssertEqual(0, lib.complete(id, .error(.platform, "The VPN configuration could not be applied")))

        let st = try await handler.awaitStatus { $0.state == .failed }
        XCTAssertEqual(.platform, st.error)
        XCTAssertTrue(st.message.contains("The VPN configuration could not be applied"))

        lib.close()
    }
}
