import Foundation
import Synchronization
import XCTest

@testable import OcteliumCore

final class NetworkStateTests: XCTestCase {

    private let wifi = NetworkInfo(
        isSatisfied: true,
        transport: .wifi,
        interfaceName: "en0",
        gateways: ["192.168.1.1", "fe80::1"],
        supportsIPv4: true,
        supportsIPv6: true
    )

    func testGetNetworkState() {
        XCTAssertEqual(NetworkState(isAvailable: false, id: ""), getNetworkState(nil))
        XCTAssertEqual(NetworkState(isAvailable: true, id: "wifi/en0/192.168.1.1,fe80::1/v4,v6"), getNetworkState(wifi))

        do {
            var info = wifi
            info.gateways = ["fe80::1", "192.168.1.1"]
            XCTAssertEqual(getNetworkState(wifi), getNetworkState(info))
        }
        do {
            var info = wifi
            info.isExpensive = true
            info.isConstrained = true
            XCTAssertEqual(getNetworkState(wifi), getNetworkState(info))
        }
        do {
            var info = wifi
            info.isSatisfied = false
            XCTAssertEqual(NetworkState(isAvailable: false, id: ""), getNetworkState(info))
        }
        do {
            var info = wifi
            info.supportsIPv4 = false
            info.supportsIPv6 = false
            XCTAssertEqual(NetworkState(isAvailable: false, id: ""), getNetworkState(info))
        }
        do {
            var info = wifi
            info.gateways = ["192.168.2.1"]
            XCTAssertNotEqual(getNetworkState(wifi).id, getNetworkState(info).id)
        }
        do {
            let info = NetworkInfo(isSatisfied: true, transport: .cellular, interfaceName: "pdp_ip0", isExpensive: true)
            XCTAssertEqual(NetworkState(isAvailable: true, id: "cellular/pdp_ip0//v4"), getNetworkState(info))
        }
    }

    func testGetNetworkLabel() {
        XCTAssertEqual("No network", getNetworkLabel(nil))
        XCTAssertEqual("Wi-Fi", getNetworkLabel(wifi))
        XCTAssertEqual(
            "Cellular",
            getNetworkLabel(NetworkInfo(isSatisfied: true, transport: .cellular, interfaceName: "pdp_ip0"))
        )
        XCTAssertEqual(
            "Ethernet (unavailable)",
            getNetworkLabel(NetworkInfo(isSatisfied: false, transport: .ethernet, interfaceName: "en1"))
        )
        XCTAssertEqual(
            "Wi-Fi (Low Data Mode)",
            getNetworkLabel(NetworkInfo(isSatisfied: true, transport: .wifi, interfaceName: "en0", isConstrained: true))
        )
        XCTAssertEqual("Other", getNetworkLabel(NetworkInfo(isSatisfied: true, transport: .other, interfaceName: "")))
    }

    func testHostCheck() {
        do {
            let ret = getHostCheck("octelium-api.example.com", ["10.0.0.1", "10.0.0.1", "fdee::1"], isNotFound: false)
            XCTAssertEqual(.resolved, ret.resolution)
            XCTAssertEqual(["10.0.0.1", "fdee::1"], ret.addresses)
            XCTAssertNil(getHostCheckError(ret))
            XCTAssertEqual("Resolved", getHostResolutionLabel(ret.resolution))
        }
        do {
            let ret = getHostCheck("octelium-api.example.com", [], isNotFound: true)
            XCTAssertEqual(.notFound, ret.resolution)
            XCTAssertEqual("Not found", getHostResolutionLabel(ret.resolution))
            XCTAssertEqual(
                "octelium-api.example.com could not be found. Make sure that the Cluster domain is correct and that the DNS of the Cluster has a record for octelium-api.example.com.",
                getHostCheckError(ret)
            )
        }
        do {
            let ret = getHostCheck("octelium-api.example.com", [], isNotFound: false, message: " timed out ")
            XCTAssertEqual(.failed, ret.resolution)
            XCTAssertEqual("Could not resolve octelium-api.example.com: timed out", getHostCheckError(ret))
        }
        do {
            let ret = getHostCheck("octelium-api.example.com", [], isNotFound: false, message: " ")
            XCTAssertNil(ret.message)
            XCTAssertEqual(
                "Could not resolve octelium-api.example.com. Check your Internet connection.",
                getHostCheckError(ret)
            )
            XCTAssertEqual("Failed", getHostResolutionLabel(ret.resolution))
        }
    }
}

final class NetworkStateReporterTests: XCTestCase {

    private let a = NetworkState(isAvailable: true, id: "wifi/en0/192.168.1.1/v4")
    private let b = NetworkState(isAvailable: true, id: "cellular/pdp_ip0//v4,v6")
    private let c = NetworkState(isAvailable: false, id: "")

    func testUpdate() async {
        let reported = Mutex<[NetworkState]>([])
        let r = NetworkStateReporter { arg in
            reported.withLock { $0.append(arg) }
            return true
        }

        do {
            let state = await r.state
            XCTAssertNil(state)
        }

        await r.update(a)
        await r.update(a)
        await r.update(b)
        await r.update(b)
        await r.update(a)

        XCTAssertEqual([a, b, a], reported.withLock { $0 })

        let state = await r.state
        XCTAssertEqual(a, state)
    }

    func testCoalesce() async throws {
        let reported = Mutex<[NetworkState]>([])
        let isReleased = Atomic<Bool>(false)
        let r = NetworkStateReporter { arg in
            reported.withLock { $0.append(arg) }
            while !isReleased.load(ordering: .sequentiallyConsistent) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }

        let a = self.a
        let task = Task {
            await r.update(a)
        }

        while reported.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        await r.update(b)
        await r.update(c)
        XCTAssertEqual([a], reported.withLock { $0 })

        isReleased.store(true, ordering: .sequentiallyConsistent)
        await task.value

        XCTAssertEqual([a, c], reported.withLock { $0 })

        let state = await r.state
        XCTAssertEqual(c, state)
    }

    func testFailure() async {
        let reported = Mutex<[NetworkState]>([])
        let isFailing = Atomic<Bool>(true)
        let r = NetworkStateReporter { arg in
            reported.withLock { $0.append(arg) }
            return !isFailing.load(ordering: .sequentiallyConsistent)
        }

        await r.update(a)
        do {
            let state = await r.state
            XCTAssertNil(state)
        }

        isFailing.store(false, ordering: .sequentiallyConsistent)
        await r.update(a)
        await r.update(a)

        XCTAssertEqual([a, a], reported.withLock { $0 })

        let state = await r.state
        XCTAssertEqual(a, state)
    }
}

final class HostResolverTests: XCTestCase {

    func testResolveHost() async {
        do {
            let ret = await resolveHost("localhost")
            XCTAssertEqual(.resolved, ret.resolution)
            XCTAssertTrue(ret.addresses.contains { $0 == "127.0.0.1" || $0 == "::1" })
        }
        do {
            let ret = await resolveHost("127.0.0.1")
            XCTAssertEqual(.resolved, ret.resolution)
            XCTAssertEqual(["127.0.0.1"], ret.addresses)
        }
        do {
            let ret = await resolveHost("octelium-api.example.invalid")
            XCTAssertNotEqual(.resolved, ret.resolution)
            XCTAssertNotNil(getHostCheckError(ret))
        }
    }

    func testResolveHostTimeout() async {
        do {
            let start = ContinuousClock.now
            let ret = await resolveHost("octelium-api.example.com", timeout: .milliseconds(50)) { host in
                Thread.sleep(forTimeInterval: 2)
                return HostCheck(host: host, resolution: .resolved, addresses: ["192.0.2.1"])
            }

            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
            XCTAssertEqual(HostCheck(host: "octelium-api.example.com", resolution: .failed, message: "Timed out"), ret)
            XCTAssertEqual("Could not resolve octelium-api.example.com: Timed out", getHostCheckError(ret))
        }

        do {
            let ret = await resolveHost("octelium-api.example.com", timeout: .seconds(10)) { host in
                HostCheck(host: host, resolution: .notFound)
            }
            XCTAssertEqual(HostCheck(host: "octelium-api.example.com", resolution: .notFound), ret)
        }

        do {
            let ret = await resolveHost("localhost", timeout: .seconds(10))
            XCTAssertEqual(.resolved, ret.resolution)
        }
    }
}
