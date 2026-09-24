import NetworkExtension
import OcteliumCore
import OcteliumProto
import XCTest

final class NetworkSettingsTests: XCTestCase {

    private func getSpec(
        addresses: [String],
        routes: [String] = [],
        mtu: Int32 = 0,
        dnsServers: [String]? = nil,
        searchDomains: [String] = [],
        matchDomains: [String] = [],
        matchAllDomains: Bool = false
    ) throws -> TunnelSpec {
        var cfg = Mobilev1.TunnelConfiguration()
        cfg.addresses = addresses
        cfg.routes = routes
        cfg.mtu = mtu

        if let dnsServers {
            cfg.dns.servers = dnsServers
            cfg.dns.searchDomains = searchDomains
            cfg.dns.matchDomains = matchDomains
            cfg.dns.matchAllDomains = matchAllDomains
        }

        return try getTunnelSpec(cfg)
    }

    func testDualStack() throws {
        let ret = getNetworkSettings(
            try getSpec(
                addresses: ["10.1.2.3/32", "fdee:1::5/128"],
                routes: ["10.1.0.0/16", "fdee:1::/64"],
                mtu: 1280,
                dnsServers: ["fdee:1::53"],
                searchDomains: ["local.example.com"],
                matchDomains: ["local.example.com", "example.com"]
            )
        )

        XCTAssertEqual(tunnelRemoteAddress, ret.tunnelRemoteAddress)
        XCTAssertEqual(1280, ret.mtu?.intValue)

        XCTAssertEqual(["10.1.2.3"], ret.ipv4Settings?.addresses)
        XCTAssertEqual(["255.255.255.255"], ret.ipv4Settings?.subnetMasks)
        XCTAssertEqual(["10.1.0.0"], ret.ipv4Settings?.includedRoutes?.map(\.destinationAddress))
        XCTAssertEqual(["255.255.0.0"], ret.ipv4Settings?.includedRoutes?.map(\.destinationSubnetMask))

        XCTAssertEqual(["fdee:1::5"], ret.ipv6Settings?.addresses)
        XCTAssertEqual([128], ret.ipv6Settings?.networkPrefixLengths.map(\.intValue))
        XCTAssertEqual(["fdee:1::"], ret.ipv6Settings?.includedRoutes?.map(\.destinationAddress))
        XCTAssertEqual([64], ret.ipv6Settings?.includedRoutes?.map(\.destinationNetworkPrefixLength.intValue))

        XCTAssertEqual(["fdee:1::53"], ret.dnsSettings?.servers)
        XCTAssertEqual(["local.example.com", "example.com"], ret.dnsSettings?.matchDomains)
        XCTAssertEqual(true, ret.dnsSettings?.matchDomainsNoSearch)
        XCTAssertEqual(["local.example.com"], ret.dnsSettings?.searchDomains)
    }

    func testSingleFamily() throws {
        do {
            let ret = getNetworkSettings(try getSpec(addresses: ["fdee:1::5/128"], routes: ["fdee:1::/64"]))
            XCTAssertNil(ret.ipv4Settings)
            XCTAssertNotNil(ret.ipv6Settings)
            XCTAssertNil(ret.dnsSettings)
            XCTAssertNil(ret.mtu)
        }
        do {
            let ret = getNetworkSettings(try getSpec(addresses: ["10.1.2.3/32"], routes: ["10.1.0.0/16"]))
            XCTAssertNotNil(ret.ipv4Settings)
            XCTAssertNil(ret.ipv6Settings)
        }
    }

    func testDNS() throws {
        do {
            let ret = getNetworkSettings(
                try getSpec(
                    addresses: ["10.1.2.3/32"],
                    routes: ["10.1.0.0/16"],
                    dnsServers: ["10.1.0.53"],
                    searchDomains: ["local.example.com"],
                    matchAllDomains: true
                )
            )
            XCTAssertEqual([""], ret.dnsSettings?.matchDomains)
            XCTAssertEqual(["local.example.com"], ret.dnsSettings?.searchDomains)
        }
        do {
            let ret = getNetworkSettings(
                try getSpec(
                    addresses: ["10.1.2.3/32"],
                    routes: ["10.1.0.0/16"],
                    dnsServers: ["10.2.0.53"],
                    matchDomains: ["example.com"]
                )
            )
            XCTAssertNil(ret.dnsSettings?.searchDomains)
            XCTAssertEqual(["10.1.0.0", "10.2.0.53"], ret.ipv4Settings?.includedRoutes?.map(\.destinationAddress))
            XCTAssertEqual(
                ["255.255.0.0", "255.255.255.255"],
                ret.ipv4Settings?.includedRoutes?.map(\.destinationSubnetMask)
            )
        }
    }
}
