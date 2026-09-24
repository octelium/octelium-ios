import OcteliumProto
import XCTest

@testable import OcteliumCore

func getTestTunnelConfiguration(
    addresses: [String] = [],
    routes: [String] = [],
    mtu: Int32 = 0,
    dnsServers: [String]? = nil,
    searchDomains: [String] = [],
    matchDomains: [String] = [],
    matchAllDomains: Bool = false
) -> Mobilev1.TunnelConfiguration {
    var ret = Mobilev1.TunnelConfiguration()
    ret.addresses = addresses
    ret.routes = routes
    ret.mtu = mtu

    if let dnsServers {
        ret.dns.servers = dnsServers
        ret.dns.searchDomains = searchDomains
        ret.dns.matchDomains = matchDomains
        ret.dns.matchAllDomains = matchAllDomains
    }

    return ret
}

final class TunnelSpecTests: XCTestCase {

    private func assertInvalid(_ msg: String, _ fn: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try fn()
            XCTFail(file: file, line: line)
        } catch let err as InvalidTunnelConfigurationError {
            XCTAssertEqual(msg, err.message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testParseIP() throws {
        do {
            let ret = try parseIP("10.1.2.3")
            XCTAssertEqual(.v4, ret.family)
            XCTAssertEqual("10.1.2.3", ret.description)
        }
        do {
            let ret = try parseIP("fdee:1::5")
            XCTAssertEqual(.v6, ret.family)
            XCTAssertEqual("fdee:1::5", ret.description)
        }
        do {
            XCTAssertEqual(.v4, try parseIP("0.0.0.0").family)
            XCTAssertEqual(.v6, try parseIP("::").family)
            XCTAssertEqual("::", try parseIP("::").description)
            XCTAssertEqual("1:2:3:4:5:6:7:8", try parseIP("1:2:3:4:5:6:7:8").description)
            XCTAssertEqual("fdee::a01:203", try parseIP("fdee::10.1.2.3").description)
            XCTAssertEqual("::1", try parseIP("::1").description)
            XCTAssertEqual("fdee::", try parseIP("FDEE::").description)
            XCTAssertEqual("fdee:0:0:1::1", try parseIP("fdee:0:0:1:0:0:0:1").description)
            XCTAssertEqual("fdee:1:0:1::", try parseIP("fdee:1:0:1:0:0:0:0").description)
            XCTAssertEqual("fdee:0:1:0:1:0:1:0", try parseIP("fdee:0:1:0:1:0:1:0").description)
            XCTAssertEqual("255.255.255.255", try parseIP("255.255.255.255").description)
        }

        for arg in [
            "",
            "10.1.2",
            "10.1.2.256",
            "10.1.2.3.4",
            "010.1.2.3.4",
            "010.1.2.3",
            "example.com",
            "localhost",
            "fdee::g",
            "1.2.3.4:53",
            " 10.1.2.3",
            "::ffff:10.1.2.3",
            ":::",
            "1::2::3",
            "1:2:3:4:5:6:7:8:9",
            "1:2:3:4:5:6:7",
            ":1:2:3:4:5:6:7",
            "12345::1",
            "fdee::10.1.2",
            "[fdee::1]",
            "fdee::1%en0",
        ] {
            assertInvalid("Invalid IP address: \(arg)") { _ = try parseIP(arg) }
        }
    }

    func testParsePrefix() throws {
        do {
            let ret = try parsePrefix("10.1.2.3/32")
            XCTAssertEqual(32, ret.prefixLength)
            XCTAssertEqual(.v4, ret.family)
            XCTAssertEqual("10.1.2.3/32", ret.description)
        }
        do {
            let ret = try parsePrefix("fdee:1::/64")
            XCTAssertEqual(64, ret.prefixLength)
            XCTAssertEqual(.v6, ret.family)
        }
        do {
            XCTAssertEqual(128, try parsePrefix("fdee::1/128").prefixLength)
            XCTAssertEqual(0, try parsePrefix("0.0.0.0/0").prefixLength)
        }

        for arg in [
            "10.1.2.3",
            "10.1.2.3/",
            "10.1.2.3/33",
            "fdee::/129",
            "10.1.2.3/-1",
            "10.1.2.3/1/2",
            "10.1.2.3/+8",
            "/24",
            "example.com/24",
            "10.1.2.3/0024",
            "10.1.2.3/08",
        ] {
            assertInvalid("Invalid prefix: \(arg)") { _ = try parsePrefix(arg) }
        }
    }

    func testMasked() throws {
        XCTAssertEqual("10.1.0.0/16", try parsePrefix("10.1.2.3/16").masked().description)
        XCTAssertEqual("10.1.2.0/23", try parsePrefix("10.1.3.255/23").masked().description)
        XCTAssertEqual("10.1.2.3/32", try parsePrefix("10.1.2.3/32").masked().description)
        XCTAssertEqual("fdee:1::/64", try parsePrefix("fdee:1::abcd/64").masked().description)
        XCTAssertEqual("fdee:1:8000::/33", try parsePrefix("fdee:1:ffff::/33").masked().description)
        XCTAssertEqual("0.0.0.0/0", try parsePrefix("10.1.2.3/0").masked().description)
    }

    func testContains() throws {
        XCTAssertTrue(try parsePrefix("10.1.0.0/16").contains(try parseIP("10.1.200.3")))
        XCTAssertFalse(try parsePrefix("10.1.0.0/16").contains(try parseIP("10.2.0.1")))
        XCTAssertTrue(try parsePrefix("fdee:1::/64").contains(try parseIP("fdee:1::53")))
        XCTAssertFalse(try parsePrefix("fdee:1::/64").contains(try parseIP("fdee:2::53")))
        XCTAssertFalse(try parsePrefix("0.0.0.0/0").contains(try parseIP("::1")))
        XCTAssertTrue(try parsePrefix("10.1.2.3/32").contains(try parseIP("10.1.2.3")))
    }

    func testSubnetMask() throws {
        XCTAssertEqual("255.255.255.255", try parsePrefix("10.1.2.3/32").subnetMask)
        XCTAssertEqual("255.255.0.0", try parsePrefix("10.1.0.0/16").subnetMask)
        XCTAssertEqual("255.255.254.0", try parsePrefix("10.1.2.0/23").subnetMask)
        XCTAssertEqual("0.0.0.0", try parsePrefix("0.0.0.0/0").subnetMask)
        XCTAssertEqual("ffff:ffff:ffff:ffff::", try parsePrefix("fdee:1::/64").subnetMask)
    }

    func testGetTunnelSpec() throws {
        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(
                    addresses: ["fdee:1::5/128"],
                    routes: ["fdee:1::/64"],
                    mtu: 1280,
                    dnsServers: ["fdee:1::53"],
                    searchDomains: ["local.Example.com."],
                    matchDomains: ["local.example.com", "example.com"]
                )
            )

            XCTAssertEqual(["fdee:1::5/128"], ret.addresses.map(\.description))
            XCTAssertEqual(["fdee:1::/64"], ret.routes.map(\.description))
            XCTAssertEqual(["fdee:1::53"], ret.dns?.servers.map(\.description))
            XCTAssertEqual(["local.example.com"], ret.dns?.searchDomains)
            XCTAssertEqual(["local.example.com", "example.com"], ret.dns?.matchDomains)
            XCTAssertEqual(false, ret.dns?.matchAllDomains)
            XCTAssertEqual(1280, ret.mtu)
            XCTAssertEqual([.v6], ret.families)
            XCTAssertEqual([], ret.getAddresses(.v4))
            XCTAssertEqual([], ret.getRoutes(.v4))
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["10.1.2.3/16", "10.1.0.0/16"])
            )

            XCTAssertEqual(["10.1.0.0/16"], ret.routes.map(\.description))
            XCTAssertNil(ret.dns)
            XCTAssertEqual(0, ret.mtu)
            XCTAssertEqual([.v4], ret.families)
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(
                    addresses: ["10.1.2.3/32", "fdee:1::5/128"],
                    routes: ["10.1.0.0/16", "fdee:1::/64"],
                    dnsServers: ["10.1.0.53", "fdee:1::53", "10.1.0.53"],
                    searchDomains: ["local.example.com"],
                    matchAllDomains: true
                )
            )

            XCTAssertEqual(2, ret.dns?.servers.count)
            XCTAssertEqual(true, ret.dns?.matchAllDomains)
            XCTAssertEqual([], ret.dns?.matchDomains)
            XCTAssertEqual([.v4, .v6], ret.families)
            XCTAssertEqual(["10.1.2.3/32"], ret.getAddresses(.v4).map(\.description))
            XCTAssertEqual(["fdee:1::/64"], ret.getRoutes(.v6).map(\.description))
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], searchDomains: ["local.example.com"])
            )
            XCTAssertNil(ret.dns)
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["10.1.0.0/16"], dnsServers: [])
            )
            XCTAssertNil(ret.dns)
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(
                    addresses: ["10.1.2.3/32"],
                    routes: ["10.1.0.0/16"],
                    dnsServers: ["10.1.0.53"],
                    searchDomains: ["local.example.com"]
                )
            )
            XCTAssertEqual(["local.example.com"], ret.dns?.matchDomains)
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["10.1.0.0/16"], dnsServers: ["10.1.0.53"])
            )
            XCTAssertNil(ret.dns)
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(
                    addresses: ["10.1.2.3/32", "fdee:1::5/128"],
                    routes: ["10.1.0.0/16"],
                    dnsServers: ["10.2.0.53", "fdee:2::53", "10.1.0.53"],
                    matchDomains: ["example.com"]
                )
            )
            XCTAssertEqual(["10.1.0.0/16", "10.2.0.53/32", "fdee:2::53/128"], ret.routes.map(\.description))
        }

        do {
            let ret = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["10.1.0.0/16"], mtu: 576)
            )
            XCTAssertEqual(576, ret.mtu)
        }
    }

    func testGetTunnelSpecErrors() {
        assertInvalid("The tunnel configuration has no addresses") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(routes: ["10.1.0.0/16"]))
        }

        assertInvalid("Default routes are not supported: 0.0.0.0/0") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["0.0.0.0/0"]))
        }

        assertInvalid("Default routes are not supported: ::/0") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["fdee::5/128"], routes: ["::/0"]))
        }

        assertInvalid("Invalid MTU: 100") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], mtu: 100))
        }

        assertInvalid("Invalid MTU: 9001") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], mtu: 9001))
        }

        assertInvalid("The MTU 1279 is lower than the minimum IPv6 MTU of 1280") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["fdee:1::5/128"], mtu: 1279))
        }

        assertInvalid("The route fdee:1::/64 has no address of the same family") {
            _ = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], routes: ["fdee:1::/64"], mtu: 576)
            )
        }

        assertInvalid("The DNS server fdee:1::53 has no address of the same family") {
            _ = try getTunnelSpec(
                getTestTunnelConfiguration(
                    addresses: ["10.1.2.3/32"],
                    dnsServers: ["fdee:1::53"],
                    matchDomains: ["example.com"]
                )
            )
        }

        assertInvalid("Invalid prefix: 10.1.2.3") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["10.1.2.3"]))
        }

        assertInvalid("Invalid IP address: dns.example.com") {
            _ = try getTunnelSpec(getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], dnsServers: ["dns.example.com"]))
        }

        assertInvalid("Invalid DNS domain: local example.com") {
            _ = try getTunnelSpec(
                getTestTunnelConfiguration(
                    addresses: ["10.1.2.3/32"],
                    dnsServers: ["10.1.0.53"],
                    searchDomains: ["local example.com"]
                )
            )
        }

        assertInvalid("Invalid DNS domain: ") {
            _ = try getTunnelSpec(
                getTestTunnelConfiguration(addresses: ["10.1.2.3/32"], dnsServers: ["10.1.0.53"], matchDomains: [" "])
            )
        }
    }
}
