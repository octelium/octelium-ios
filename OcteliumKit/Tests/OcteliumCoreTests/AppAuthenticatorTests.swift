#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import OcteliumProto
import XCTest

@testable import OcteliumCore

final class AppAuthenticatorTests: XCTestCase {

    private func getCallbackURL(_ resp: Authv1.ClientLoginResponse, _ prefix: String = authCallbackURL) throws -> String {
        let data: Data = try resp.serializedBytes()
        return "\(prefix)?octelium_response=\(encodeBase64URL(data))"
    }

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

    func testAppAuthenticator() async throws {
        let a = AppAuthenticator(domain: "example.com")

        let loginURL = a.getLoginURL()
        XCTAssertTrue(loginURL.hasPrefix("https://example.com/login?octelium_req="))
        XCTAssertTrue(isLoginURLAllowed(loginURL))

        let data = try XCTUnwrap(decodeBase64URL(String(loginURL.dropFirst("https://example.com/login?octelium_req=".count))))
        let req = try Authv1.ClientLoginRequest(serializedBytes: data)
        XCTAssertEqual(.app, req.callbackType)
        XCTAssertEqual(.v1, req.apiVersion)
        XCTAssertEqual(0, req.callbackPort)
        XCTAssertTrue(req.callbackSuffix.isEmpty)
        XCTAssertEqual(Data(SHA256.hash(data: a.codeVerifier)), req.codeChallenge)
        XCTAssertEqual(codeVerifierLen, a.codeVerifier.count)

        var resp = Authv1.ClientLoginResponse()
        resp.authenticationToken = "auth-token"
        resp.codeChallenge = req.codeChallenge

        XCTAssertEqual(resp, try a.getLoginResponse(getCallbackURL(resp)))
        XCTAssertEqual(resp, try a.getLoginResponse(getCallbackURL(resp, "COM.OCTELIUM.CLIENT:/callback/success")))

        assertInvalid("Invalid callback URL") {
            _ = try a.getLoginResponse(getCallbackURL(resp, "https://example.com/callback/success"))
        }
        assertInvalid("Invalid callback URL") {
            _ = try a.getLoginResponse(getCallbackURL(resp, "com.octelium.client://host/callback/success"))
        }
        assertInvalid("Invalid callback URL") {
            _ = try a.getLoginResponse(getCallbackURL(resp, "com.octelium.client:/callback/other"))
        }
        assertInvalid("Invalid callback URL") {
            _ = try a.getLoginResponse("com.octelium.client:callback")
        }
        assertInvalid("No login response is set") {
            _ = try a.getLoginResponse(authCallbackURL)
        }
        assertInvalid("Invalid login response encoding") {
            _ = try a.getLoginResponse("\(authCallbackURL)?octelium_response=!!!")
        }
        assertInvalid("No authentication token is set") {
            var arg = resp
            arg.authenticationToken = ""
            _ = try a.getLoginResponse(getCallbackURL(arg))
        }
        assertInvalid("The callback does not belong to this authentication") {
            var arg = resp
            arg.codeChallenge = Data(count: 32)
            _ = try a.getLoginResponse(getCallbackURL(arg))
        }

        try a.complete(resp)
        let ret = try await a.wait()
        XCTAssertEqual(resp, ret)

        XCTAssertThrowsError(try a.complete(resp)) { err in
            XCTAssertEqual(StatusError(.failedPrecondition, "The authentication is already completed"), err as? StatusError)
        }
    }

    func testWait() async throws {
        do {
            let a = AppAuthenticator(domain: "example.com")
            do {
                _ = try await a.wait(timeout: 0.05)
                XCTFail()
            } catch {
                XCTAssertTrue(error is AuthenticationTimedOutError)
            }
        }

        do {
            let a = AppAuthenticator(domain: "example.com")
            let task = Task {
                try await a.wait()
            }

            task.cancel()

            do {
                _ = try await task.value
                XCTFail()
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }

        do {
            let a = AppAuthenticator(domain: "example.com")
            let task = Task {
                try await a.wait()
            }

            try await Task.sleep(for: .milliseconds(50))

            var resp = Authv1.ClientLoginResponse()
            resp.authenticationToken = "auth-token"
            try a.complete(resp)

            let ret = try await task.value
            XCTAssertEqual("auth-token", ret.authenticationToken)
        }
    }

    func testBase64URL() {
        XCTAssertEqual("-_8", encodeBase64URL(Data([0xfb, 0xff])))
        XCTAssertEqual(Data([0xfb, 0xff]), decodeBase64URL("-_8"))
        XCTAssertEqual(Data([0xfb, 0xff]), decodeBase64URL("-_8="))
        XCTAssertNil(decodeBase64URL("+/8="))
        XCTAssertNil(decodeBase64URL("!!!"))
    }
}
