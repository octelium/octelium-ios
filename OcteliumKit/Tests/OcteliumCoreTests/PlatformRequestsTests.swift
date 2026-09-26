import Foundation
import Synchronization
import XCTest

@testable import OcteliumCore

private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    func wait() async {
        await withCheckedContinuation { cont in
            let isOpen = state.withLock { st in
                if !st.isOpen {
                    st.waiters.append(cont)
                }
                return st.isOpen
            }

            if isOpen {
                cont.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { st in
            st.isOpen = true
            let ret = st.waiters
            st.waiters = []
            return ret
        }

        for itm in waiters {
            itm.resume()
        }
    }
}

private final class FakeHost: TunnelHost {
    private let err: Error?
    private let tunFD: Int32?
    private let gate: Gate?
    private let state = Mutex<[(String, UInt64, TunnelSpec)]>([])

    init(err: Error? = nil, tunFD: Int32? = nil, gate: Gate? = nil) {
        self.err = err
        self.tunFD = tunFD
        self.gate = gate
    }

    var specs: [(String, UInt64, TunnelSpec)] {
        state.withLock { $0 }
    }

    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32? {
        await gate?.wait()

        if let err {
            throw err
        }

        state.withLock { $0.append((domain, generation, spec)) }

        return tunFD
    }
}

final class PlatformRequestsTests: XCTestCase {

    private func getConfig(generation: UInt64 = 1) -> NetworkConfig {
        getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["10.1.0.0/16"], mtu: 1280, generation: generation)
    }

    private func getPlatformMessage(_ arg: TunnelResponse) -> String? {
        guard case .error(let code, let message) = arg, code == .platform else {
            return nil
        }

        return message
    }

    func testApplyNetworkConfig() async throws {
        let host = FakeHost()
        let h = PlatformRequestHandler(host: host)

        let ret = await h.applyNetworkConfig("example.com", getConfig(generation: 3))
        XCTAssertEqual(.applyNetworkConfig(tunFD: nil), ret)

        XCTAssertEqual(1, host.specs.count)
        let (domain, generation, spec) = host.specs[0]
        XCTAssertEqual("example.com", domain)
        XCTAssertEqual(3, generation)
        XCTAssertEqual(1280, spec.mtu)
        XCTAssertEqual(["10.1.0.0/16"], spec.routes.map(\.description))
    }

    func testApplyNetworkConfigWithFD() async throws {
        let ret = await PlatformRequestHandler(host: FakeHost(tunFD: 100)).applyNetworkConfig("example.com", getConfig())
        XCTAssertEqual(.applyNetworkConfig(tunFD: 100), ret)
    }

    private func waitFor(
        _ fn: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(10)

        while !fn() {
            if Date() > deadline {
                XCTFail("Timed out", file: file, line: line)
                return
            }

            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStaleGeneration() async throws {
        let host = FakeHost()
        let h = PlatformRequestHandler(host: host)

        let ret1 = await h.applyNetworkConfig("example.com", getConfig(generation: 5))
        let ret2 = await h.applyNetworkConfig("example.com", getConfig(generation: 3))
        let ret3 = await h.applyNetworkConfig("example.com", getConfig(generation: 6))

        XCTAssertEqual([5, 6], host.specs.map { $0.1 })
        XCTAssertEqual(.applyNetworkConfig(tunFD: nil), ret1)
        XCTAssertEqual("The tunnel configuration is stale", getPlatformMessage(ret2))
        XCTAssertEqual(.applyNetworkConfig(tunFD: nil), ret3)
    }

    func testStaleGenerationWhileApplying() async throws {
        let gate = Gate()
        let host = FakeHost(gate: gate)
        let h = PlatformRequestHandler(host: host)

        let cfg1 = getConfig(generation: 1)
        let cfg2 = getConfig(generation: 2)
        let cfg3 = getConfig(generation: 3)

        let task1 = Task { await h.applyNetworkConfig("example.com", cfg1) }
        try await waitFor { gate.waiterCount == 1 }

        let task2 = Task { await h.applyNetworkConfig("example.com", cfg2) }
        try await waitFor { h.latestGeneration == 2 }

        let task3 = Task { await h.applyNetworkConfig("example.com", cfg3) }
        try await waitFor { h.latestGeneration == 3 }

        gate.open()
        let ret1 = await task1.value
        let ret2 = await task2.value
        let ret3 = await task3.value

        XCTAssertEqual([1, 3], host.specs.map { $0.1 })
        XCTAssertEqual(.applyNetworkConfig(tunFD: nil), ret1)
        XCTAssertEqual("The tunnel configuration is stale", getPlatformMessage(ret2))
        XCTAssertEqual(.applyNetworkConfig(tunFD: nil), ret3)
    }

    func testErrors() async throws {
        do {
            let host = FakeHost()
            let ret = await PlatformRequestHandler(host: host).applyNetworkConfig(
                "example.com",
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["0.0.0.0/0"])
            )
            XCTAssertEqual("Default routes are not supported: 0.0.0.0/0", getPlatformMessage(ret))
            XCTAssertTrue(host.specs.isEmpty)
        }

        do {
            let ret = await PlatformRequestHandler(host: FakeHost()).applyNetworkConfig("", getConfig())
            XCTAssertEqual("The domain is not set", getPlatformMessage(ret))
        }

        do {
            let ret = await PlatformRequestHandler(
                host: FakeHost(err: StatusError(.unavailable, "The tunnel settings could not be applied"))
            ).applyNetworkConfig("example.com", getConfig())
            XCTAssertEqual("The tunnel settings could not be applied", getPlatformMessage(ret))
        }
    }

    func testGetPlatformErrorResponse() {
        XCTAssertEqual(.error(.platform, "failed"), getPlatformErrorResponse("failed"))
    }
}
