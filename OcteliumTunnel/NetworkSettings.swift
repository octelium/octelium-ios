import Foundation
import NetworkExtension
import OcteliumCore

let tunnelRemoteAddress = "127.0.0.1"

func getNetworkSettings(_ spec: TunnelSpec) -> NEPacketTunnelNetworkSettings {
    let ret = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemoteAddress)

    let v4Addresses = spec.getAddresses(.v4)
    if !v4Addresses.isEmpty {
        let settings = NEIPv4Settings(
            addresses: v4Addresses.map(\.address.description),
            subnetMasks: v4Addresses.map(\.subnetMask)
        )
        settings.includedRoutes = spec.getRoutes(.v4).map {
            NEIPv4Route(destinationAddress: $0.address.description, subnetMask: $0.subnetMask)
        }
        settings.excludedRoutes = []
        ret.ipv4Settings = settings
    }

    let v6Addresses = spec.getAddresses(.v6)
    if !v6Addresses.isEmpty {
        let settings = NEIPv6Settings(
            addresses: v6Addresses.map(\.address.description),
            networkPrefixLengths: v6Addresses.map { NSNumber(value: $0.prefixLength) }
        )
        settings.includedRoutes = spec.getRoutes(.v6).map {
            NEIPv6Route(destinationAddress: $0.address.description, networkPrefixLength: NSNumber(value: $0.prefixLength))
        }
        settings.excludedRoutes = []
        ret.ipv6Settings = settings
    }

    if let dns = spec.dns {
        let settings = NEDNSSettings(servers: dns.servers.map(\.description))
        settings.matchDomains = dns.matchAllDomains ? [""] : dns.matchDomains
        settings.matchDomainsNoSearch = true
        settings.searchDomains = dns.searchDomains.isEmpty ? nil : dns.searchDomains
        ret.dnsSettings = settings
    }

    if spec.mtu > 0 {
        ret.mtu = NSNumber(value: spec.mtu)
    }

    return ret
}

final class TunnelSettingsHost: TunnelHost, @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func apply(domain: String, generation: UInt64, spec: TunnelSpec) async throws -> Int32? {
        guard let provider else {
            throw StatusError(.unavailable, "The packet tunnel provider is not available")
        }

        Log.tunnel.info("Applying the tunnel configuration \(generation, privacy: .public)")

        let settings = getNetworkSettings(spec)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            provider.setTunnelNetworkSettings(settings) { err in
                if let err {
                    cont.resume(throwing: StatusError(
                        .internal,
                        "Could not apply the tunnel network settings: \(err.localizedDescription)"
                    ))
                } else {
                    cont.resume()
                }
            }
        }

        return nil
    }
}
