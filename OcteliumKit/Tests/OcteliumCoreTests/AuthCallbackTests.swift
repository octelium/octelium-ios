import OcteliumProto
import XCTest

@testable import OcteliumCore

final class AuthCallbackTests: XCTestCase {

    private let expected = "com.octelium.client:/callback/success"

    func testIsAuthCallbackURL() {
        XCTAssertTrue(isAuthCallbackURL("com.octelium.client:/callback/success?octelium_response=abc", expected))
        XCTAssertTrue(isAuthCallbackURL("COM.OCTELIUM.CLIENT:/callback/success?octelium_response=abc", expected))
        XCTAssertTrue(isAuthCallbackURL("com.octelium.client:/callback/success", expected))
        XCTAssertTrue(isAuthCallbackURL("com.octelium.client:/callback/success?octelium_response=a-b_c%3D", expected))

        XCTAssertFalse(isAuthCallbackURL("", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client:/callback/failure?x=1", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client://callback/success?x=1", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client://evil.com/callback/success", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client:callback/success", expected))
        XCTAssertFalse(isAuthCallbackURL("https://example.com/callback/success", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client:/callback/success#frag", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client:/callback/success?x=%%", expected))
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client:/callback/success?x=a b", expected))
        XCTAssertFalse(isAuthCallbackURL("/callback/success", expected))
        XCTAssertFalse(isAuthCallbackURL("1com.octelium.client:/callback/success", expected))
        XCTAssertFalse(
            isAuthCallbackURL(
                "com.octelium.client:/callback/success?x=\(String(repeating: "a", count: maxCallbackURLLength))",
                expected
            )
        )
        XCTAssertFalse(isAuthCallbackURL("com.octelium.client:/callback/success", "%%"))
    }

    func testParseURI() {
        do {
            let ret = parseURI("https://user:pass@example.com:8443/login?x=1#frag")
            XCTAssertEqual("https", ret?.scheme)
            XCTAssertEqual("user:pass@example.com:8443", ret?.authority)
            XCTAssertEqual("user:pass", ret?.userInfo)
            XCTAssertEqual("example.com", ret?.host)
            XCTAssertEqual("/login", ret?.path)
            XCTAssertEqual("x=1", ret?.query)
            XCTAssertEqual("frag", ret?.fragment)
        }
        do {
            let ret = parseURI("https://[fdee::1]:443/")
            XCTAssertEqual("[fdee::1]", ret?.host)
            XCTAssertEqual("/", ret?.path)
        }
        do {
            let ret = parseURI("com.octelium.client:/callback/success")
            XCTAssertEqual("com.octelium.client", ret?.scheme)
            XCTAssertNil(ret?.authority)
            XCTAssertEqual("/callback/success", ret?.path)
            XCTAssertNil(ret?.query)
        }
        do {
            XCTAssertNil(parseURI("no scheme"))
            XCTAssertNil(parseURI("https://example.com:44x/"))
            XCTAssertNil(parseURI("https://[fdee::1/"))
            XCTAssertNil(parseURI("https://exa mple.com"))
        }
    }

    func testGetAuthCallbackCandidates() {
        let status = getTestStatus(
            getTestDomain("a.example.com", op: getTestOperation(type: .authenticate, state: .waitingForUser, id: "op-a")),
            getTestDomain("b.example.com", op: getTestOperation(type: .authenticate, state: .running, id: "op-b")),
            getTestDomain("c.example.com", op: getTestOperation(type: .connect, state: .waitingForUser, id: "op-c")),
            getTestDomain("d.example.com", op: getTestOperation(type: .authenticate, state: .waitingForUser, id: "op-d")),
            getTestDomain("e.example.com")
        )

        XCTAssertEqual(["op-a", "op-d"], getWaitingAuthentications(status).map(\.id))
        XCTAssertEqual(["op-a", "op-d"], getAuthCallbackCandidates(status, nil))
        XCTAssertEqual(["op-a", "op-d"], getAuthCallbackCandidates(status, ""))
        XCTAssertEqual(["op-d", "op-a"], getAuthCallbackCandidates(status, "op-d"))
        XCTAssertEqual(["op-x", "op-a", "op-d"], getAuthCallbackCandidates(status, "op-x"))
        XCTAssertEqual(["op-x"], getAuthCallbackCandidates(nil, "op-x"))
        XCTAssertTrue(getAuthCallbackCandidates(nil, nil).isEmpty)
    }

    func testIsLoginURLAllowed() {
        XCTAssertTrue(isLoginURLAllowed("https://example.com/login?octelium_req=abc"))
        XCTAssertTrue(isLoginURLAllowed("HTTPS://example.com/login"))
        XCTAssertTrue(isLoginURLAllowed("https://example.com:8443/login"))
        XCTAssertFalse(isLoginURLAllowed("http://example.com/login"))
        XCTAssertFalse(isLoginURLAllowed("javascript:alert(1)"))
        XCTAssertFalse(isLoginURLAllowed("intent://example.com/#Intent;end"))
        XCTAssertFalse(isLoginURLAllowed("https:///login"))
        XCTAssertFalse(isLoginURLAllowed("https://user@example.com/login"))
        XCTAssertFalse(isLoginURLAllowed("file:///etc/passwd"))
        XCTAssertFalse(isLoginURLAllowed(""))
        XCTAssertFalse(isLoginURLAllowed("https://exa mple.com"))
    }
}
