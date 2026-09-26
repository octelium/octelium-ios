import Foundation

public enum IPFamily: Sendable {
    case v4
    case v6
}

public struct InvalidTunnelConfigurationError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else {
            return nil
        }

        self.bytes = bytes
    }

    public var family: IPFamily {
        bytes.count == 4 ? .v4 : .v6
    }

    public var description: String {
        if family == .v4 {
            return bytes.map(String.init).joined(separator: ".")
        }

        let groups = (0..<8).map { (UInt16(bytes[$0 * 2]) << 8) | UInt16(bytes[$0 * 2 + 1]) }

        var bestStart = -1
        var bestLen = 0
        var idx = 0
        while idx < groups.count {
            guard groups[idx] == 0 else {
                idx += 1
                continue
            }

            let start = idx
            while idx < groups.count && groups[idx] == 0 {
                idx += 1
            }

            if idx - start > bestLen {
                bestStart = start
                bestLen = idx - start
            }
        }

        let hex = groups.map { String($0, radix: 16) }
        if bestLen < 2 {
            return hex.joined(separator: ":")
        }

        let head = hex[..<bestStart].joined(separator: ":")
        let tail = hex[(bestStart + bestLen)...].joined(separator: ":")

        return "\(head)::\(tail)"
    }
}

public struct IPPrefix: Hashable, Sendable, CustomStringConvertible {
    public let address: IPAddress
    public let prefixLength: Int

    public init(address: IPAddress, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    public var family: IPFamily {
        address.family
    }

    public var description: String {
        "\(address)/\(prefixLength)"
    }

    public func masked() -> IPPrefix {
        IPPrefix(address: IPAddress(bytes: getMaskedBytes(address.bytes))!, prefixLength: prefixLength)
    }

    public func contains(_ arg: IPAddress) -> Bool {
        arg.family == family && getMaskedBytes(arg.bytes) == getMaskedBytes(address.bytes)
    }

    public var subnetMask: String {
        IPAddress(bytes: getMaskedBytes(Array(repeating: 0xff, count: address.bytes.count)))!.description
    }

    private func getMaskedBytes(_ arg: [UInt8]) -> [UInt8] {
        arg.enumerated().map { i, b in
            let bits = min(max(prefixLength - i * 8, 0), 8)
            return b & UInt8(truncatingIfNeeded: 0xff << (8 - bits))
        }
    }
}

public struct TunnelDNS: Equatable, Sendable {
    public let servers: [IPAddress]
    public let searchDomains: [String]
    public let matchDomains: [String]
    public let matchAllDomains: Bool
}

public struct TunnelSpec: Equatable, Sendable {
    public let addresses: [IPPrefix]
    public let routes: [IPPrefix]
    public let dns: TunnelDNS?
    public let mtu: Int

    public var families: Set<IPFamily> {
        Set(addresses.map(\.family))
    }

    public func getAddresses(_ family: IPFamily) -> [IPPrefix] {
        addresses.filter { $0.family == family }
    }

    public func getRoutes(_ family: IPFamily) -> [IPPrefix] {
        routes.filter { $0.family == family }
    }
}

public let minTunnelMTU = 576
public let minIPv6TunnelMTU = 1280
public let maxTunnelMTU = 9000

private let rgxSearchDomain = try! NSRegularExpression(
    pattern: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"
)

private func parseIPv4(_ arg: Substring) -> [UInt8]? {
    let parts = arg.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        return nil
    }

    var ret: [UInt8] = []
    for part in parts {
        guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }

        if part.count > 1 && part.hasPrefix("0") {
            return nil
        }

        guard let value = UInt8(part) else {
            return nil
        }

        ret.append(value)
    }

    return ret
}

private func parseIPv6Groups(_ arg: Substring) -> [UInt16]? {
    if arg.isEmpty {
        return []
    }

    let groups = arg.split(separator: ":", omittingEmptySubsequences: false)
    var ret: [UInt16] = []

    for (i, group) in groups.enumerated() {
        if i == groups.count - 1 && group.contains(".") {
            guard let v4 = parseIPv4(group) else {
                return nil
            }
            ret.append((UInt16(v4[0]) << 8) | UInt16(v4[1]))
            ret.append((UInt16(v4[2]) << 8) | UInt16(v4[3]))
            continue
        }

        guard !group.isEmpty, group.count <= 4, group.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              let value = UInt16(group, radix: 16) else {
            return nil
        }

        ret.append(value)
    }

    return ret
}

private func parseIPv6(_ arg: String) -> [UInt8]? {
    let parts = arg.components(separatedBy: "::")
    guard parts.count <= 2 else {
        return nil
    }

    guard let head = parseIPv6Groups(Substring(parts[0])) else {
        return nil
    }

    var groups = head
    if parts.count == 2 {
        guard let tail = parseIPv6Groups(Substring(parts[1])), head.count + tail.count <= 7 else {
            return nil
        }
        groups = head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    guard groups.count == 8 else {
        return nil
    }

    return groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
}

public func parseIP(_ arg: String) throws -> IPAddress {
    let invalidErr = InvalidTunnelConfigurationError("Invalid IP address: \(arg)")

    if let ret = parseIPv4(Substring(arg)) {
        return IPAddress(bytes: ret)!
    }

    guard arg.contains(":"), let ret = parseIPv6(arg) else {
        throw invalidErr
    }

    if ret[0..<10].allSatisfy({ $0 == 0 }) && ret[10] == 0xff && ret[11] == 0xff {
        throw invalidErr
    }

    return IPAddress(bytes: ret)!
}

public func parsePrefix(_ arg: String) throws -> IPPrefix {
    let invalidErr = InvalidTunnelConfigurationError("Invalid prefix: \(arg)")

    let parts = arg.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[1].isEmpty, parts[1].count <= 3,
          parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw invalidErr
    }

    if parts[1].count > 1 && parts[1].hasPrefix("0") {
        throw invalidErr
    }

    guard let address = try? parseIP(String(parts[0])), let prefixLength = Int(parts[1]) else {
        throw invalidErr
    }

    if prefixLength > (address.family == .v4 ? 32 : 128) {
        throw invalidErr
    }

    return IPPrefix(address: address, prefixLength: prefixLength)
}

private func normalizeDomains(_ arg: [String]) throws -> [String] {
    var ret: [String] = []

    for itm in arg {
        var domain = itm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while domain.hasSuffix(".") {
            domain.removeLast()
        }

        if rgxSearchDomain.firstMatch(in: domain, range: NSRange(domain.startIndex..., in: domain)) == nil {
            throw InvalidTunnelConfigurationError("Invalid DNS domain: \(domain)")
        }

        if !ret.contains(domain) {
            ret.append(domain)
        }
    }

    return ret
}

private func getHostPrefix(_ arg: IPAddress) -> IPPrefix {
    IPPrefix(address: arg, prefixLength: arg.family == .v4 ? 32 : 128)
}

public func getTunnelSpec(_ cfg: NetworkConfig) throws -> TunnelSpec {
    let addresses = try cfg.addresses.map { try parsePrefix($0) }
    if addresses.isEmpty {
        throw InvalidTunnelConfigurationError("The tunnel configuration has no addresses")
    }

    let families = Set(addresses.map(\.family))

    var routes: [IPPrefix] = []
    for itm in cfg.routes {
        let route = try parsePrefix(itm).masked()
        if route.prefixLength == 0 {
            throw InvalidTunnelConfigurationError("Default routes are not supported: \(route)")
        }

        if !families.contains(route.family) {
            throw InvalidTunnelConfigurationError("The route \(route) has no address of the same family")
        }

        if !routes.contains(route) {
            routes.append(route)
        }
    }

    let mtu = cfg.mtu
    if mtu != 0 && (mtu < minTunnelMTU || mtu > maxTunnelMTU) {
        throw InvalidTunnelConfigurationError("Invalid MTU: \(mtu)")
    }

    if mtu != 0 && mtu < minIPv6TunnelMTU && families.contains(.v6) {
        throw InvalidTunnelConfigurationError(
            "The MTU \(mtu) is lower than the minimum IPv6 MTU of \(minIPv6TunnelMTU)"
        )
    }

    var dns: TunnelDNS?

    if let cfgDNS = cfg.dns, !cfgDNS.servers.isEmpty {
        var servers: [IPAddress] = []
        for itm in cfgDNS.servers {
            let server = try parseIP(itm)
            if !families.contains(server.family) {
                throw InvalidTunnelConfigurationError("The DNS server \(server) has no address of the same family")
            }

            if !servers.contains(server) {
                servers.append(server)
            }
        }

        let searchDomains = try normalizeDomains(cfgDNS.searchDomains)
        var matchDomains = try normalizeDomains(cfgDNS.matchDomains)
        if !cfgDNS.matchAllDomains && matchDomains.isEmpty {
            matchDomains = searchDomains
        }

        if cfgDNS.matchAllDomains || !matchDomains.isEmpty {
            dns = TunnelDNS(
                servers: servers,
                searchDomains: searchDomains,
                matchDomains: cfgDNS.matchAllDomains ? [] : matchDomains,
                matchAllDomains: cfgDNS.matchAllDomains
            )

            for server in servers where !routes.contains(where: { $0.contains(server) }) {
                routes.append(getHostPrefix(server))
            }
        }
    }

    return TunnelSpec(addresses: addresses, routes: routes, dns: dns, mtu: mtu)
}
