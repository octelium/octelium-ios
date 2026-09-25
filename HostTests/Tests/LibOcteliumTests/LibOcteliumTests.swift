import COctelium
import Foundation
import OcteliumCore
import OcteliumProto
import SwiftProtobuf
import Synchronization
import XCTest

@testable import LibOctelium

private final class Callbacks: NativeCallbacks {
    private let events = Mutex<[Mobilev1.Event]>([])
    private let requests = Mutex<[(UInt64, Mobilev1.PlatformRequest)]>([])

    func onEvent(_ data: Data) {
        guard let ev = try? Mobilev1.Event(serializedBytes: data) else {
            return
        }

        events.withLock { $0.append(ev) }
    }

    func onRequest(_ requestID: UInt64, _ data: Data) {
        guard let req = try? Mobilev1.PlatformRequest(serializedBytes: data) else {
            return
        }

        requests.withLock { $0.append((requestID, req)) }
    }

    var logs: [Mobilev1.Log] {
        events.withLock { itms in
            itms.compactMap {
                guard case .log(let ret) = $0.type else {
                    return nil
                }
                return ret
            }
        }
    }

    func awaitStatus(_ fn: (Daemonv1.GetStatusResponse) -> Bool) async throws -> Daemonv1.GetStatusResponse {
        try await wait("the status") {
            let ret = events.withLock { itms in
                itms.reversed().compactMap { ev -> Daemonv1.GetStatusResponse? in
                    guard case .status(let ret) = ev.type else {
                        return nil
                    }
                    return ret
                }.first
            }

            guard let ret, fn(ret) else {
                return nil
            }

            return ret
        }
    }

    func awaitLog(_ fn: (Mobilev1.Log) -> Bool) async throws -> Mobilev1.Log {
        try await wait("the log") {
            logs.first(where: fn)
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

    private func getConfig(
        stateDir: URL? = nil,
        stateKey: Data = Data((0..<32).map { UInt8($0) }),
        platform: Mobilev1.Config.Platform = .ios
    ) -> Mobilev1.Config {
        var ret = Mobilev1.Config()
        ret.platform = platform
        ret.stateDir = (stateDir ?? tmp.appendingPathComponent(UUID().uuidString)).path
        ret.stateKey = stateKey
        ret.device.id = UUID().uuidString.lowercased()
        ret.device.name = "test"
        ret.logLevel = .debug
        return ret
    }

    private func assertCode(
        _ code: StatusCode,
        _ fn: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
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

    func testABI() throws {
        XCTAssertEqual(abiVersion, octelium_abi_version())
        try LibOctelium.checkABI()
    }

    func testClient() async throws {
        let callbacks = Callbacks()
        let lib = try LibOctelium.create(getConfig(), callbacks)
        let c = LocalClient(lib)

        do {
            let info = try await c.getInfo()
            XCTAssertNil(checkInfo(info))
            XCTAssertEqual(1, info.apiMajorVersion)
            XCTAssertEqual("com.octelium.client:/callback/success", info.authenticationCallbackURL)
            XCTAssertFalse(info.instanceID.isEmpty)
        }

        do {
            let status = try await c.getStatus()
            XCTAssertTrue(status.domains.isEmpty)
        }

        do {
            var settings = Daemonv1.DomainSettings()
            settings.autoConnect = true
            settings.connectionOptions.tunnelMode = .quicv0

            let ret = try await c.updateDomainSettings("Example.COM", settings)
            XCTAssertEqual("example.com", ret.domain)
            XCTAssertTrue(ret.autoConnect)

            let status = try await callbacks.awaitStatus { $0.domains.count == 1 }
            XCTAssertEqual("example.com", status.domains[0].domain)
            XCTAssertTrue(status.domains[0].settings.autoConnect)
            XCTAssertEqual(.loggedOut, status.domains[0].authentication.state)
        }

        do {
            await assertCode(.unauthenticated) { _ = try await c.connect("example.com") }
            await assertCode(.notFound) { _ = try await c.connect("unknown.example.com") }
            await assertCode(.invalidArgument) { _ = try await c.connect("not a domain") }
            await assertCode(.unauthenticated) { _ = try await c.getAPICredential("example.com") }
            await assertCode(.notFound) { _ = try await c.getOperation(UUID().uuidString) }
            await assertCode(.unimplemented) { _ = try await lib.call("Unknown", Data()) }
            await assertCode(.invalidArgument) { _ = try await lib.call("GetOperation", Data([0xff])) }
            await assertCode(.invalidArgument) {
                var settings = Daemonv1.DomainSettings()
                settings.connectionOptions.implementationMode = .kernel
                _ = try await c.updateDomainSettings("example.com", settings)
            }
            await assertCode(.invalidArgument) {
                var settings = Daemonv1.DomainSettings()
                settings.connectionOptions.dns.enableLocalServer = true
                _ = try await c.updateDomainSettings("example.com", settings)
            }
        }

        do {
            _ = try await c.setNetworkState(NetworkState(isAvailable: false, id: ""))
            _ = try await c.setNetworkState(NetworkState(isAvailable: true, id: "wifi/en0/192.168.1.1/v4"))
        }

        do {
            let resp: Data = try getPlatformErrorResponse("failed").serializedBytes()
            XCTAssertEqual(StatusCode.notFound.rawValue, lib.complete(12345, resp))
            XCTAssertEqual(StatusCode.invalidArgument.rawValue, lib.complete(1, Data([0xff])))
        }

        do {
            let op = try await c.deleteDomain("example.com")
            XCTAssertEqual(.delete, op.type)
            _ = try await callbacks.awaitStatus { $0.domains.isEmpty }
        }

        lib.close()
        lib.close()

        await assertCode(.unavailable) { _ = try await c.getInfo() }
        XCTAssertEqual(StatusCode.unavailable.rawValue, lib.complete(1, Data()))
    }

    func testAuthenticateBrowser() async throws {
        let callbacks = Callbacks()
        let lib = try LibOctelium.create(getConfig(), callbacks)
        let c = LocalClient(lib)
        let info = try await c.getInfo()

        let op = try await c.authenticateBrowser("Example.com")
        XCTAssertEqual("example.com", op.domain)
        XCTAssertEqual(.authenticate, op.type)
        XCTAssertEqual(.waitingForUser, op.state)
        XCTAssertTrue(op.cancellable)

        guard case .openURL(let action) = op.action.type else {
            return XCTFail()
        }
        XCTAssertTrue(isLoginURLAllowed(action.url))
        XCTAssertTrue(action.url.hasPrefix("https://example.com/login?octelium_req="))

        do {
            let status = try await c.getStatus()
            XCTAssertEqual([op.id], getWaitingAuthentications(status).map(\.id))
            XCTAssertEqual(action.url, getPendingOpenURL(getDomainState(status, "example.com")))
            XCTAssertEqual(.authenticating, getDomainState(status, "example.com")?.authentication.state)
            XCTAssertEqual([op.id], getAuthCallbackCandidates(status, nil))
        }

        do {
            let callbackURL = "\(info.authenticationCallbackURL)?octelium_response=invalid"
            XCTAssertTrue(isAuthCallbackURL(callbackURL, info.authenticationCallbackURL))

            await assertCode(.invalidArgument) { _ = try await c.completeAuthentication(op.id, callbackURL) }
            await assertCode(.invalidArgument) { _ = try await c.completeAuthentication(op.id, "https://example.com") }
            await assertCode(.notFound) { _ = try await c.completeAuthentication(UUID().uuidString, callbackURL) }
            await assertCode(.invalidArgument) { _ = try await c.completeAuthentication("", callbackURL) }

            let ret = try await c.getOperation(op.id)
            XCTAssertEqual(.waitingForUser, ret.state)
        }

        await assertCode(.failedPrecondition) { _ = try await c.authenticateBrowser("example.com") }

        do {
            let ret = try await c.cancelOperation(op.id)
            XCTAssertEqual(.canceled, ret.state)
            XCTAssertFalse(ret.cancellable)

            let status = try await callbacks.awaitStatus {
                getDomainState($0, "example.com")?.authentication.state == .loggedOut
            }
            XCTAssertNil(getActiveOperation(getDomainState(status, "example.com")))
            XCTAssertNil(getPendingOpenURL(getDomainState(status, "example.com")))
        }

        do {
            let op = try await c.authenticateToken("example.localhost", "invalid")
            XCTAssertEqual(.authenticate, op.type)

            let ret = try await c.cancelOperation(op.id)
            XCTAssertTrue([.canceled, .failed].contains(ret.state))
            XCTAssertFalse(ret.cancellable)

            let status = try await callbacks.awaitStatus {
                let state = getDomainState($0, "example.localhost")
                return state?.lastOperation.id == op.id && state?.lastOperation.state == ret.state &&
                    state?.authentication.state == .loggedOut
            }
            XCTAssertNil(getActiveOperation(getDomainState(status, "example.localhost")))

            let log = try await callbacks.awaitLog { $0.message.hasPrefix("Could not authenticate") }
            XCTAssertEqual(.debug, log.level)
            XCTAssertTrue(log.hasCreatedAt)
        }

        lib.close()
    }

    func testSharedState() async throws {
        let stateDir = tmp.appendingPathComponent("shared")

        let appCallbacks = Callbacks()
        let app = try LibOctelium.create(getConfig(stateDir: stateDir), appCallbacks)
        let tunnel = try LibOctelium.create(getConfig(stateDir: stateDir), Callbacks())

        do {
            var settings = Daemonv1.DomainSettings()
            settings.autoConnect = true
            _ = try await LocalClient(app).updateDomainSettings("example.com", settings)

            let status = try await LocalClient(tunnel).getStatus()
            XCTAssertEqual(["example.com"], status.domains.map(\.domain))
            XCTAssertTrue(status.domains[0].settings.autoConnect)
        }

        do {
            var settings = Daemonv1.DomainSettings()
            settings.connectionOptions.tunnelMode = .wireguard
            _ = try await LocalClient(tunnel).updateDomainSettings("example.com", settings)

            let status = try await LocalClient(app).getStatus()
            XCTAssertFalse(status.domains[0].settings.autoConnect)
            XCTAssertEqual(.wireguard, status.domains[0].settings.connectionOptions.tunnelMode)
        }

        do {
            let a = try await LocalClient(app).getInfo()
            let b = try await LocalClient(tunnel).getInfo()
            XCTAssertNotEqual(a.instanceID, b.instanceID)
        }

        app.close()
        tunnel.close()
    }

    func testPersistence() async throws {
        let stateDir = tmp.appendingPathComponent("state")

        do {
            let lib = try LibOctelium.create(getConfig(stateDir: stateDir), Callbacks())
            var settings = Daemonv1.DomainSettings()
            settings.autoConnect = true
            _ = try await LocalClient(lib).updateDomainSettings("example.com", settings)
            lib.close()
        }

        do {
            let lib = try LibOctelium.create(getConfig(stateDir: stateDir), Callbacks())
            let status = try await LocalClient(lib).getStatus()
            XCTAssertEqual(["example.com"], status.domains.map(\.domain))
            XCTAssertTrue(status.domains[0].settings.autoConnect)
            lib.close()
        }

        do {
            XCTAssertThrowsError(
                try LibOctelium.create(getConfig(stateDir: stateDir, stateKey: Data(repeating: 7, count: 32)), Callbacks())
            ) { err in
                XCTAssertEqual(.internal, (err as? StatusError)?.code)
            }
        }

        let items = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
        XCTAssertFalse(items.isEmpty)
    }

    func testInvalidConfig() throws {
        do {
            XCTAssertThrowsError(try LibOctelium.create(getConfig(stateKey: Data(count: 16)), Callbacks())) { err in
                XCTAssertEqual(StatusError(.invalidArgument, "The state key must be 32 bytes"), err as? StatusError)
            }
        }

        do {
            var cfg = getConfig()
            cfg.clearDevice()
            XCTAssertThrowsError(try LibOctelium.create(cfg, Callbacks())) { err in
                XCTAssertEqual(.invalidArgument, (err as? StatusError)?.code)
            }
        }

        do {
            XCTAssertThrowsError(try LibOctelium.create(getConfig(platform: .unspecified), Callbacks())) { err in
                XCTAssertEqual(.invalidArgument, (err as? StatusError)?.code)
            }
        }

        do {
            var cfg = getConfig()
            cfg.stateDir = ""
            XCTAssertThrowsError(try LibOctelium.create(cfg, Callbacks())) { err in
                XCTAssertEqual(.invalidArgument, (err as? StatusError)?.code)
            }
        }

        do {
            var handle: UInt64 = 99
            var out: UnsafeMutablePointer<UInt8>?
            var outLen = 0
            var cb = octelium_callbacks_t(ctx: nil, on_event: { _, _, _ in }, on_request: { _, _, _, _ in })
            let config: [UInt8] = [0xff, 0xff]

            let code = config.withUnsafeBufferPointer { buf in
                octelium_client_new(buf.baseAddress, buf.count, &cb, &handle, &out, &outLen)
            }

            let msg = String(decoding: UnsafeBufferPointer(start: out, count: outLen), as: UTF8.self)
            octelium_free(out)

            XCTAssertEqual(StatusCode.invalidArgument.rawValue, code)
            XCTAssertEqual(0, handle)
            XCTAssertTrue(msg.hasPrefix("Could not unmarshal the config"))
        }

        do {
            var handle: UInt64 = 0
            var out: UnsafeMutablePointer<UInt8>?
            var outLen = 0
            let code = octelium_client_new(nil, 0, nil, &handle, &out, &outLen)
            octelium_free(out)
            XCTAssertEqual(StatusCode.invalidArgument.rawValue, code)
        }

        do {
            XCTAssertThrowsError(try LibOctelium.callSync(987654321, "GetInfo", Data())) { err in
                XCTAssertEqual(StatusError(.notFound, "Unknown client"), err as? StatusError)
            }
        }
    }
}
