import OcteliumProto
import SwiftProtobuf
import XCTest

@testable import OcteliumCore

func getTestService(
    name: String = "svc.default",
    hostname: String = "",
    type: ServiceType = .http,
    displayName: String = "",
    description: String = ""
) -> Userv1.Service {
    var ret = Userv1.Service()
    ret.metadata.name = name
    ret.metadata.displayName = displayName
    ret.metadata.description_p = description
    ret.spec.type = type
    ret.status.primaryHostname = hostname
    return ret
}

final class ServicesTests: XCTestCase {

    func testFQDN() {
        do {
            let svc = getTestService(hostname: "svc")
            XCTAssertEqual("svc.local.example.com", getServicePrivateFQDN(svc, "example.com"))
            XCTAssertEqual("svc.example.com", getServicePublicFQDN(svc, "example.com"))
            XCTAssertEqual("https://svc.example.com", getServicePublicURL(svc, "example.com")?.absoluteString)
            XCTAssertEqual("svc", getServiceHostname(svc))
        }
        do {
            let svc = getTestService(hostname: "")
            XCTAssertEqual("local.example.com", getServicePrivateFQDN(svc, "example.com"))
            XCTAssertEqual("example.com", getServicePublicFQDN(svc, "example.com"))
            XCTAssertEqual("https://example.com", getServicePublicURL(svc, "example.com")?.absoluteString)
            XCTAssertEqual("svc.default", getServiceHostname(svc))
        }
    }

    func testGetServicePublicURL() {
        do {
            let svc = getTestService(hostname: "svc-1.apps")
            XCTAssertEqual("https://svc-1.apps.example.com", getServicePublicURL(svc, "example.com")?.absoluteString)
            XCTAssertEqual("svc-1.apps.example.com", getServicePublicURL(svc, "example.com")?.host)
        }

        for hostname in [
            "evil.com/#",
            "evil.com?",
            "user@evil.com",
            "evil.com:8443",
            "svc/../x",
            "svc\\x",
            "svc x",
            "SVC",
            "svc..x",
            "-svc",
            "svc\n",
            "bücher",
            String(repeating: "a", count: 64),
        ] {
            XCTAssertNil(getServicePublicURL(getTestService(hostname: hostname), "example.com"), hostname)
        }

        do {
            XCTAssertNil(getServicePublicURL(getTestService(hostname: "svc"), ""))
            XCTAssertNil(getServicePublicURL(getTestService(hostname: ""), "localhost"))
            XCTAssertNil(getServicePublicURL(getTestService(hostname: "svc"), String(repeating: "a.", count: 127) + "com"))
        }
    }

    func testIsServiceWebBrowsable() {
        XCTAssertTrue(isServiceWebBrowsable(getTestService(type: .web)))
        XCTAssertTrue(isServiceWebBrowsable(getTestService(type: .http)))
        XCTAssertTrue(isServiceWebBrowsable(getTestService(type: .rdpWeb)))
        XCTAssertFalse(isServiceWebBrowsable(getTestService(type: .ssh)))
        XCTAssertFalse(isServiceWebBrowsable(getTestService(type: .unset)))
    }

    func testServiceTypes() {
        XCTAssertEqual("Kubernetes", getServiceTypeInfo(getTestService(type: .kubernetes)).label)
        XCTAssertEqual(unknownServiceType, getServiceTypeInfo(getTestService(type: .unset)))
        XCTAssertEqual(unknownServiceType, getServiceTypeInfo(getTestService(type: .UNRECOGNIZED(99))))
        XCTAssertEqual(.postgres, getServiceTypeByKey("POSTGRES")?.type)
        XCTAssertNil(getServiceTypeByKey("NONE"))
        XCTAssertNil(getServiceTypeByKey(""))
        XCTAssertNil(getServiceTypeByKey(nil))
        XCTAssertEqual(serviceTypes.count, Set(serviceTypes.map(\.key)).count)
        XCTAssertEqual(serviceTypes.count, Set(serviceTypes.map(\.type.rawValue)).count)
        XCTAssertEqual(ServiceType.allCases.count - 1, serviceTypes.count)
    }

    func testSplitServiceName() {
        XCTAssertTrue(splitServiceName("svc.default") == ("svc", "default"))
        XCTAssertTrue(splitServiceName("svc.ns.sub") == ("svc", "ns.sub"))
        XCTAssertTrue(splitServiceName("svc") == ("svc", nil))
        XCTAssertTrue(splitServiceName(".svc") == (".svc", nil))
    }

    func testPrintResourceNameWithDisplay() {
        var md = Metav1.Metadata()
        md.name = "svc"
        XCTAssertEqual("svc", printResourceNameWithDisplay(md))

        md.displayName = "My Service"
        XCTAssertEqual("svc (My Service)", printResourceNameWithDisplay(md))
    }

    func testTokenizeQuery() {
        XCTAssertEqual([], tokenizeQuery(""))
        XCTAssertEqual([], tokenizeQuery("   "))
        XCTAssertEqual(["api", "prod"], tokenizeQuery("  API   Prod "))
        XCTAssertEqual(["api", "prod"], tokenizeQuery("api\tprod\n"))
    }

    func testMatches() {
        let svc = getTestService(
            name: "api.production",
            hostname: "api-prod",
            displayName: "Public API",
            description: "The main HTTP API"
        )

        XCTAssertTrue(matchesService(svc, []))
        XCTAssertTrue(matchesService(svc, tokenizeQuery("api")))
        XCTAssertTrue(matchesService(svc, tokenizeQuery("public main")))
        XCTAssertTrue(matchesService(svc, tokenizeQuery("api-prod")))
        XCTAssertFalse(matchesService(svc, tokenizeQuery("api staging")))

        var ns = Userv1.Namespace()
        ns.metadata.name = "production"
        ns.metadata.displayName = "Production"
        XCTAssertTrue(matchesNamespace(ns, tokenizeQuery("prod")))
        XCTAssertFalse(matchesNamespace(ns, tokenizeQuery("staging")))
        XCTAssertTrue(matchesAllTokens("Hello World", ["hello", "world"]))
    }

    func testGetCommonListOptions() {
        let ret = getCommonListOptions(2, 50)
        XCTAssertEqual(2, ret.page)
        XCTAssertEqual(50, ret.itemsPerPage)
        XCTAssertEqual(.name, ret.orderBy.type)
        XCTAssertEqual(.asc, ret.orderBy.mode)
    }

    func testListAll() async throws {
        func getMeta(_ hasMore: Bool) -> Metav1.ListResponseMeta {
            var ret = Metav1.ListResponseMeta()
            ret.hasMore_p = hasMore
            return ret
        }

        do {
            var pages: [Int] = []
            let ret: [Int] = try await listAll { page in
                pages.append(page)
                return ([page * 10, page * 10 + 1], getMeta(page < 2))
            }
            XCTAssertEqual([0, 1, 10, 11, 20, 21], ret)
            XCTAssertEqual([0, 1, 2], pages)
        }
        do {
            let ret: [Int] = try await listAll { _ in ([1], nil) }
            XCTAssertEqual([1], ret)
        }
        do {
            let ret: [Int] = try await listAll { _ in ([], getMeta(true)) }
            XCTAssertEqual([], ret)
        }
        do {
            do {
                let _: [Int] = try await listAll { page in ([page], getMeta(true)) }
                XCTFail()
            } catch let err as StatusError {
                XCTAssertEqual(.outOfRange, err.code)
            }
        }
    }

    func testGetChangedSessions() {
        do {
            let status = getTestStatus(
                getTestDomain("a.example.com", auth: .authenticated),
                getTestDomain("b.example.com")
            )
            let keys = getSessionKeys(status)
            XCTAssertEqual(["a.example.com", "b.example.com"], keys.keys.sorted())
            XCTAssertEqual([], getChangedSessions(keys, keys))
            XCTAssertEqual([], getChangedSessions([:], keys))
        }
        do {
            var a = getTestDomain("a.example.com", auth: .authenticated)
            let previous = getSessionKeys(getTestStatus(a, getTestDomain("b.example.com")))

            a.authentication.authenticatedAt = Google_Protobuf_Timestamp(seconds: 100, nanos: 0)
            let current = getSessionKeys(getTestStatus(a))

            XCTAssertEqual(["a.example.com", "b.example.com"], getChangedSessions(previous, current))
        }
        do {
            let previous = getSessionKeys(getTestStatus(getTestDomain("a.example.com", auth: .authenticated)))
            let current = getSessionKeys(getTestStatus(getTestDomain("a.example.com", auth: .loggedOut)))
            XCTAssertEqual(["a.example.com"], getChangedSessions(previous, current))
        }
        do {
            XCTAssertEqual([:], getSessionKeys(nil))
        }
    }
}
