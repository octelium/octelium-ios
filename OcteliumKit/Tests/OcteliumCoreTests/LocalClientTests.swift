import Foundation
import OcteliumProto
import SwiftProtobuf
import Synchronization
import XCTest

@testable import OcteliumCore

final class FakeTransport: LocalTransport {
    private let handler: @Sendable (String, Data) throws -> Data
    private let state = Mutex<[(String, Data)]>([])

    init(_ handler: @escaping @Sendable (String, Data) throws -> Data) {
        self.handler = handler
    }

    var calls: [(String, Data)] {
        state.withLock { $0 }
    }

    var last: (String, Data) {
        calls.last!
    }

    func call(_ method: String, _ request: Data) async throws -> Data {
        state.withLock { $0.append((method, request)) }
        return try handler(method, request)
    }
}

final class LocalClientTests: XCTestCase {

    func testGetInfo() async throws {
        let transport = FakeTransport { _, _ in
            var ret = Mobilev1.GetInfoResponse()
            ret.version = "v0.44.0"
            ret.apiMajorVersion = 1
            ret.instanceID = "instance"
            ret.authenticationCallbackURL = "com.octelium.client:/callback/success"
            return try ret.serializedBytes()
        }

        let ret = try await LocalClient(transport).getInfo()
        XCTAssertEqual("v0.44.0", ret.version)
        XCTAssertEqual("instance", ret.instanceID)
        XCTAssertEqual(1, transport.calls.count)
        XCTAssertEqual("GetInfo", transport.last.0)
        XCTAssertEqual(0, transport.last.1.count)
        XCTAssertNil(checkInfo(ret))
    }

    func testCheckInfo() {
        do {
            var info = Mobilev1.GetInfoResponse()
            info.apiMajorVersion = 2
            info.authenticationCallbackURL = "com.octelium.client:/callback/success"
            XCTAssertEqual(
                "liboctelium implements the local API version 2 while this application requires the version 1",
                checkInfo(info)
            )
        }
        do {
            var info = Mobilev1.GetInfoResponse()
            info.apiMajorVersion = 1
            XCTAssertEqual("liboctelium does not provide an authentication callback URL", checkInfo(info))
        }
    }

    func testRequests() async throws {
        let transport = FakeTransport { method, _ in
            switch method {
            case "SetNetworkState":
                return try Mobilev1.SetNetworkStateResponse().serializedBytes()
            case "GetAPICredential":
                var ret = Daemonv1.GetAPICredentialResponse()
                ret.accessToken = "token"
                return try ret.serializedBytes()
            case "UpdateDomainSettings":
                var ret = Daemonv1.DomainSettings()
                ret.domain = "example.com"
                ret.autoConnect = true
                return try ret.serializedBytes()
            case "GetStatus":
                var ret = Daemonv1.GetStatusResponse()
                ret.revision = 3
                return try ret.serializedBytes()
            default:
                var ret = Daemonv1.Operation()
                ret.id = "op"
                ret.domain = "example.com"
                return try ret.serializedBytes()
            }
        }

        let c = LocalClient(transport)

        do {
            let ret = try await c.authenticateBrowser("example.com")
            XCTAssertEqual("op", ret.id)
            let req = try Daemonv1.AuthenticateRequest(serializedBytes: transport.last.1)
            XCTAssertEqual("Authenticate", transport.last.0)
            XCTAssertEqual("example.com", req.domain)
            guard case .browser = req.type else {
                return XCTFail()
            }
        }

        do {
            _ = try await c.authenticateToken("example.com", "secret")
            let req = try Daemonv1.AuthenticateRequest(serializedBytes: transport.last.1)
            XCTAssertEqual("secret", req.authenticationToken.authenticationToken)
            guard case .authenticationToken = req.type else {
                return XCTFail()
            }
        }

        do {
            _ = try await c.completeAuthentication("op", "com.octelium.client:/callback/success?octelium_response=abc")
            let req = try Mobilev1.CompleteAuthenticationRequest(serializedBytes: transport.last.1)
            XCTAssertEqual("CompleteAuthentication", transport.last.0)
            XCTAssertEqual("op", req.operationID)
            XCTAssertEqual("com.octelium.client:/callback/success?octelium_response=abc", req.callbackURL)
        }

        do {
            _ = try await c.connect("example.com")
            XCTAssertEqual("Connect", transport.last.0)
            let req = try Daemonv1.ConnectRequest(serializedBytes: transport.last.1)
            XCTAssertEqual("example.com", req.domain)
            XCTAssertFalse(req.hasOptions)
        }

        do {
            _ = try await c.disconnect("example.com")
            XCTAssertEqual("Disconnect", transport.last.0)
            XCTAssertEqual("example.com", try Daemonv1.DisconnectRequest(serializedBytes: transport.last.1).domain)
        }

        do {
            _ = try await c.logout("example.com")
            XCTAssertEqual("Logout", transport.last.0)
            XCTAssertEqual("example.com", try Daemonv1.LogoutRequest(serializedBytes: transport.last.1).domain)
        }

        do {
            _ = try await c.deleteDomain("example.com")
            XCTAssertEqual("DeleteDomain", transport.last.0)
            XCTAssertEqual("example.com", try Daemonv1.DeleteDomainRequest(serializedBytes: transport.last.1).domain)
        }

        do {
            _ = try await c.getOperation("op")
            XCTAssertEqual("GetOperation", transport.last.0)
            XCTAssertEqual("op", try Daemonv1.GetOperationRequest(serializedBytes: transport.last.1).id)
        }

        do {
            _ = try await c.cancelOperation("op")
            XCTAssertEqual("CancelOperation", transport.last.0)
            XCTAssertEqual("op", try Daemonv1.CancelOperationRequest(serializedBytes: transport.last.1).id)
        }

        do {
            let ret = try await c.getAPICredential("example.com")
            XCTAssertEqual("token", ret.accessToken)
            XCTAssertEqual("GetAPICredential", transport.last.0)
            XCTAssertEqual("example.com", try Daemonv1.GetAPICredentialRequest(serializedBytes: transport.last.1).domain)
        }

        do {
            var settings = Daemonv1.DomainSettings()
            settings.autoConnect = true
            let ret = try await c.updateDomainSettings("example.com", settings)
            XCTAssertTrue(ret.autoConnect)
            let req = try Daemonv1.UpdateDomainSettingsRequest(serializedBytes: transport.last.1)
            XCTAssertEqual("example.com", req.domain)
            XCTAssertTrue(req.settings.autoConnect)
        }

        do {
            _ = try await c.setNetworkState(NetworkState(isAvailable: true, id: "wifi/en0//v4"))
            let req = try Mobilev1.SetNetworkStateRequest(serializedBytes: transport.last.1)
            XCTAssertEqual("SetNetworkState", transport.last.0)
            XCTAssertTrue(req.isAvailable)
            XCTAssertEqual("wifi/en0//v4", req.id)
        }

        do {
            let ret = try await c.getStatus()
            XCTAssertEqual(3, ret.revision)
            XCTAssertEqual("GetStatus", transport.last.0)
        }
    }

    func testErrors() async {
        do {
            let c = LocalClient(FakeTransport { _, _ in throw getStatusError(code: 5, message: "Unknown Cluster domain") })
            do {
                _ = try await c.connect("example.com")
                XCTFail()
            } catch let err as StatusError {
                XCTAssertEqual(.notFound, err.code)
                XCTAssertEqual("Unknown Cluster domain", err.message)
            } catch {
                XCTFail()
            }
        }
        do {
            let c = LocalClient(FakeTransport { _, _ in Data([0xff, 0xff]) })
            do {
                _ = try await c.connect("example.com")
                XCTFail()
            } catch let err as StatusError {
                XCTAssertEqual(.internal, err.code)
                XCTAssertTrue(err.message.hasPrefix("Could not unmarshal the Connect response"))
            } catch {
                XCTFail()
            }
        }
    }

    func testGetStatusError() {
        XCTAssertEqual(.invalidArgument, getStatusError(code: 3, message: "invalid").code)
        XCTAssertEqual("invalid", getStatusError(code: 3, message: "invalid").message)
        XCTAssertEqual(.unauthenticated, getStatusError(code: 16, message: "").code)
        XCTAssertEqual(.unknown, getStatusError(code: 0, message: "").code)
        XCTAssertEqual(.unknown, getStatusError(code: 17, message: "").code)
        XCTAssertEqual(.unknown, getStatusError(code: -1, message: "").code)
        XCTAssertEqual(17, StatusCode.allCases.count)
        XCTAssertEqual(17, Set(StatusCode.allCases.map(\.name)).count)
    }

    func testGetErrorMessage() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }

        XCTAssertEqual("invalid", getErrorMessage(getStatusError(code: 3, message: "invalid")))
        XCTAssertEqual("NOT_FOUND", getErrorMessage(StatusError(.notFound, "")))
        XCTAssertEqual("boom", getErrorMessage(TestError()))
        XCTAssertEqual("failed", getErrorMessage(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed"])))
        XCTAssertEqual(.aborted, getStatusCode(StatusError(.aborted, "")))
        XCTAssertNil(getStatusCode(TestError()))
        XCTAssertEqual("NOT_FOUND: missing", StatusError(.notFound, "missing").description)
    }
}
