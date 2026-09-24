import Foundation
import OcteliumProto
import Synchronization
import XCTest

@testable import OcteliumCore

private final class FakeHost: TunnelHost {
    private let err: Error?
    private let tunFD: Int32?
    private let state = Mutex<[(String, UInt64, TunnelSpec)]>([])

    init(err: Error? = nil, tunFD: Int32? = nil) {
        self.err = err
        self.tunFD = tunFD
    }

    var specs: [(String, UInt64, TunnelSpec)] {
        state.withLock { $0 }
    }

    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32? {
        if let err {
            throw err
        }

        state.withLock { $0.append((domain, generation, spec)) }

        return tunFD
    }
}

private final class FakeCompleter: RequestCompleter {
    private let code: Int32
    private let state = Mutex<[(UInt64, Mobilev1.PlatformResponse)]>([])

    init(code: Int32 = 0) {
        self.code = code
    }

    var responses: [(UInt64, Mobilev1.PlatformResponse)] {
        state.withLock { $0 }
    }

    func complete(_ requestID: UInt64, _ response: Data) -> Int32 {
        let resp = try! Mobilev1.PlatformResponse(serializedBytes: response)
        state.withLock { $0.append((requestID, resp)) }
        return code
    }
}

final class PlatformRequestsTests: XCTestCase {

    private func getRequest(
        domain: String = "example.com",
        generation: UInt64 = 1,
        cfg: Mobilev1.TunnelConfiguration = getTestTunnelConfiguration(
            addresses: ["10.1.2.3/32"],
            routes: ["10.1.0.0/16"],
            mtu: 1280
        )
    ) throws -> Data {
        var ret = Mobilev1.PlatformRequest()
        ret.applyTunnelConfiguration.domain = domain
        ret.applyTunnelConfiguration.generation = generation
        ret.applyTunnelConfiguration.configuration = cfg
        return try ret.serializedBytes()
    }

    func testApplyTunnelConfiguration() async throws {
        let host = FakeHost()
        let completer = FakeCompleter()
        let h = PlatformRequestHandler(host: host, completer: completer)

        await h.handle(7, try getRequest(generation: 3))

        XCTAssertEqual(1, completer.responses.count)
        let (id, resp) = completer.responses[0]
        XCTAssertEqual(7, id)
        guard case .applyTunnelConfiguration(let arg) = resp.type else {
            return XCTFail()
        }
        XCTAssertFalse(arg.hasTunFd)

        XCTAssertEqual(1, host.specs.count)
        let (domain, generation, spec) = host.specs[0]
        XCTAssertEqual("example.com", domain)
        XCTAssertEqual(3, generation)
        XCTAssertEqual(1280, spec.mtu)
        XCTAssertEqual(["10.1.0.0/16"], spec.routes.map(\.description))
    }

    func testApplyTunnelConfigurationWithFD() async throws {
        let completer = FakeCompleter()
        await PlatformRequestHandler(host: FakeHost(tunFD: 100), completer: completer).handle(7, try getRequest())

        XCTAssertTrue(completer.responses[0].1.applyTunnelConfiguration.hasTunFd)
        XCTAssertEqual(100, completer.responses[0].1.applyTunnelConfiguration.tunFd)
    }

    func testErrors() async throws {
        do {
            let completer = FakeCompleter()
            await PlatformRequestHandler(host: FakeHost(), completer: completer).handle(1, Data([0xff, 0xff]))
            guard case .error(let err) = completer.responses.first?.1.type else {
                return XCTFail()
            }
            XCTAssertTrue(err.message.hasPrefix("Could not unmarshal the platform request"))
        }

        do {
            let completer = FakeCompleter()
            await PlatformRequestHandler(host: FakeHost(), completer: completer).handle(1, Data())
            XCTAssertEqual("Unsupported platform request", completer.responses.first?.1.error.message)
        }

        do {
            let host = FakeHost()
            let completer = FakeCompleter()
            await PlatformRequestHandler(host: host, completer: completer).handle(
                2,
                try getRequest(cfg: getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["0.0.0.0/0"]))
            )
            XCTAssertEqual(2, completer.responses.first?.0)
            XCTAssertEqual("Default routes are not supported: 0.0.0.0/0", completer.responses.first?.1.error.message)
            XCTAssertTrue(host.specs.isEmpty)
        }

        do {
            let completer = FakeCompleter()
            await PlatformRequestHandler(host: FakeHost(), completer: completer).handle(3, try getRequest(domain: ""))
            XCTAssertEqual("The domain is not set", completer.responses.first?.1.error.message)
        }

        do {
            let completer = FakeCompleter()
            await PlatformRequestHandler(
                host: FakeHost(err: StatusError(.unavailable, "The tunnel settings could not be applied")),
                completer: completer
            ).handle(4, try getRequest())
            XCTAssertEqual("The tunnel settings could not be applied", completer.responses.first?.1.error.message)
        }

        do {
            let completer = FakeCompleter(code: 5)
            await PlatformRequestHandler(host: FakeHost(), completer: completer).handle(5, try getRequest())
            XCTAssertEqual(1, completer.responses.count)
        }
    }

    func testGetPlatformErrorResponse() {
        let ret = getPlatformErrorResponse("failed")
        XCTAssertEqual("failed", ret.error.message)
        guard case .error = ret.type else {
            return XCTFail()
        }
    }

    func testGetApplyTunnelConfigurationResponse() throws {
        do {
            let ret = getApplyTunnelConfigurationResponse(tunFD: nil)
            let data: Data = try ret.serializedBytes()
            let parsed = try Mobilev1.PlatformResponse(serializedBytes: data)
            guard case .applyTunnelConfiguration(let arg) = parsed.type else {
                return XCTFail()
            }
            XCTAssertFalse(arg.hasTunFd)
        }
        do {
            let ret = getApplyTunnelConfigurationResponse(tunFD: 0)
            XCTAssertTrue(ret.applyTunnelConfiguration.hasTunFd)
            XCTAssertEqual(0, ret.applyTunnelConfiguration.tunFd)
        }
    }
}
