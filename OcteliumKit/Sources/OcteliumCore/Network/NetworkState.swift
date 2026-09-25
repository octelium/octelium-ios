import Foundation

public enum NetworkTransport: String, Sendable {
    case wifi
    case cellular
    case ethernet
    case other
}

public struct NetworkInfo: Equatable, Sendable {
    public var isSatisfied: Bool
    public var transport: NetworkTransport
    public var interfaceName: String
    public var gateways: [String]
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(
        isSatisfied: Bool,
        transport: NetworkTransport,
        interfaceName: String,
        gateways: [String] = [],
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.isSatisfied = isSatisfied
        self.transport = transport
        self.interfaceName = interfaceName
        self.gateways = gateways
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

public struct NetworkState: Equatable, Sendable {
    public let isAvailable: Bool
    public let id: String

    public init(isAvailable: Bool, id: String) {
        self.isAvailable = isAvailable
        self.id = id
    }
}

public func getNetworkID(_ info: NetworkInfo) -> String {
    var families: [String] = []
    if info.supportsIPv4 {
        families.append("v4")
    }
    if info.supportsIPv6 {
        families.append("v6")
    }

    return [
        info.transport.rawValue,
        info.interfaceName,
        info.gateways.sorted().joined(separator: ","),
        families.joined(separator: ","),
    ].joined(separator: "/")
}

public func getNetworkState(_ info: NetworkInfo?) -> NetworkState {
    guard let info, info.isSatisfied, info.supportsIPv4 || info.supportsIPv6 else {
        return NetworkState(isAvailable: false, id: "")
    }

    return NetworkState(isAvailable: true, id: getNetworkID(info))
}

public actor NetworkStateReporter {
    private let report: @Sendable (NetworkState) async -> Bool
    private var reported: NetworkState?
    private var pending: NetworkState?
    private var isReporting = false

    public init(_ report: @escaping @Sendable (NetworkState) async -> Bool) {
        self.report = report
    }

    public var state: NetworkState? {
        reported
    }

    public func update(_ arg: NetworkState) async {
        pending = arg
        if isReporting {
            return
        }

        isReporting = true
        defer {
            isReporting = false
        }

        while let next = pending {
            pending = nil
            if next == reported {
                continue
            }

            reported = await report(next) ? next : nil
        }
    }
}

public func getNetworkLabel(_ info: NetworkInfo?) -> String {
    guard let info else {
        return "No network"
    }

    let transport = switch info.transport {
    case .wifi: "Wi-Fi"
    case .cellular: "Cellular"
    case .ethernet: "Ethernet"
    case .other: "Other"
    }

    if !info.isSatisfied {
        return "\(transport) (unavailable)"
    }

    if info.isConstrained {
        return "\(transport) (Low Data Mode)"
    }

    return transport
}

public enum HostResolution: Sendable {
    case resolved
    case notFound
    case failed
}

public struct HostCheck: Equatable, Sendable {
    public let host: String
    public let resolution: HostResolution
    public let addresses: [String]
    public let message: String?

    public init(host: String, resolution: HostResolution, addresses: [String] = [], message: String? = nil) {
        self.host = host
        self.resolution = resolution
        self.addresses = addresses
        self.message = message
    }
}

public func getHostCheck(_ host: String, _ resolved: [String], isNotFound: Bool, message: String? = nil) -> HostCheck {
    if !resolved.isEmpty {
        var addresses: [String] = []
        for itm in resolved where !addresses.contains(itm) {
            addresses.append(itm)
        }
        return HostCheck(host: host, resolution: .resolved, addresses: addresses)
    }

    if isNotFound {
        return HostCheck(host: host, resolution: .notFound)
    }

    let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines)

    return HostCheck(host: host, resolution: .failed, message: msg?.isEmpty == false ? msg : nil)
}

public func getHostResolutionLabel(_ arg: HostResolution) -> String {
    switch arg {
    case .resolved: "Resolved"
    case .notFound: "Not found"
    case .failed: "Failed"
    }
}

public func getHostCheckError(_ arg: HostCheck) -> String? {
    switch arg.resolution {
    case .resolved:
        return nil
    case .notFound:
        return "\(arg.host) could not be found. Make sure that the Cluster domain is correct and that " +
            "the DNS of the Cluster has a record for \(arg.host)."
    case .failed:
        if let message = arg.message {
            return "Could not resolve \(arg.host): \(message)"
        }
        return "Could not resolve \(arg.host). Check your Internet connection."
    }
}
