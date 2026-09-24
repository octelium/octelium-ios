import Foundation
import OcteliumProto

public typealias ServiceType = Userv1.Service.Spec.TypeEnum

public func getServicePrivateFQDN(_ arg: Userv1.Service, _ domain: String) -> String {
    arg.status.primaryHostname.isEmpty ? "local.\(domain)" : "\(arg.status.primaryHostname).local.\(domain)"
}

public func getServicePublicFQDN(_ arg: Userv1.Service, _ domain: String) -> String {
    arg.status.primaryHostname.isEmpty ? domain : "\(arg.status.primaryHostname).\(domain)"
}

public func getServicePublicURL(_ arg: Userv1.Service, _ domain: String) -> String {
    "https://\(getServicePublicFQDN(arg, domain))"
}

public func getServiceHostname(_ arg: Userv1.Service) -> String {
    arg.status.primaryHostname.isEmpty ? arg.metadata.name : arg.status.primaryHostname
}

public func isServiceWebBrowsable(_ arg: Userv1.Service) -> Bool {
    switch arg.spec.type {
    case .web, .http, .rdpWeb:
        true
    default:
        false
    }
}

public struct ServiceTypeInfo: Equatable, Sendable {
    public let key: String
    public let type: ServiceType
    public let label: String
}

public let serviceTypes: [ServiceTypeInfo] = [
    ServiceTypeInfo(key: "WEB", type: .web, label: "Web App"),
    ServiceTypeInfo(key: "HTTP", type: .http, label: "HTTP"),
    ServiceTypeInfo(key: "GRPC", type: .grpc, label: "gRPC"),
    ServiceTypeInfo(key: "SSH", type: .ssh, label: "SSH"),
    ServiceTypeInfo(key: "KUBERNETES", type: .kubernetes, label: "Kubernetes"),
    ServiceTypeInfo(key: "POSTGRES", type: .postgres, label: "PostgreSQL"),
    ServiceTypeInfo(key: "MYSQL", type: .mysql, label: "MySQL"),
    ServiceTypeInfo(key: "TCP", type: .tcp, label: "TCP"),
    ServiceTypeInfo(key: "UDP", type: .udp, label: "UDP"),
    ServiceTypeInfo(key: "DNS", type: .dns, label: "DNS"),
    ServiceTypeInfo(key: "SOCKS5", type: .socks5, label: "SOCKS5"),
    ServiceTypeInfo(key: "RDP_WEB", type: .rdpWeb, label: "RDP Web"),
    ServiceTypeInfo(key: "RDP", type: .rdp, label: "RDP"),
    ServiceTypeInfo(key: "LLM", type: .llm, label: "AI / LLM"),
    ServiceTypeInfo(key: "MCP", type: .mcp, label: "MCP"),
]

public let unknownServiceType = ServiceTypeInfo(key: "UNSET", type: .unset, label: "Service")

public func getServiceTypeInfo(_ arg: Userv1.Service) -> ServiceTypeInfo {
    serviceTypes.first { $0.type == arg.spec.type } ?? unknownServiceType
}

public func getServiceTypeByKey(_ key: String?) -> ServiceTypeInfo? {
    guard let key, !key.isEmpty else {
        return nil
    }

    return serviceTypes.first { $0.key == key }
}

public func splitServiceName(_ name: String) -> (String, String?) {
    guard let idx = name.firstIndex(of: "."), idx != name.startIndex else {
        return (name, nil)
    }

    return (String(name[..<idx]), String(name[name.index(after: idx)...]))
}

public func printResourceNameWithDisplay(_ arg: Metav1.Metadata) -> String {
    arg.displayName.isEmpty ? arg.name : "\(arg.name) (\(arg.displayName))"
}

public func tokenizeQuery(_ arg: String) -> [String] {
    arg.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
}

public func matchesAllTokens(_ text: String, _ tokens: [String]) -> Bool {
    let value = text.lowercased()
    return tokens.allSatisfy { value.contains($0) }
}

public func matchesService(_ arg: Userv1.Service, _ tokens: [String]) -> Bool {
    matchesAllTokens(
        "\(arg.metadata.name) \(arg.metadata.displayName) \(arg.metadata.description_p) \(arg.status.primaryHostname)",
        tokens
    )
}

public func matchesNamespace(_ arg: Userv1.Namespace, _ tokens: [String]) -> Bool {
    matchesAllTokens(
        "\(arg.metadata.name) \(arg.metadata.displayName) \(arg.metadata.description_p)",
        tokens
    )
}

public func getCommonListOptions(_ page: Int, _ itemsPerPage: Int) -> Metav1.CommonListOptions {
    var ret = Metav1.CommonListOptions()
    ret.page = UInt32(page)
    ret.itemsPerPage = UInt32(itemsPerPage)
    ret.orderBy.type = .name
    ret.orderBy.mode = .asc

    return ret
}

public let allItemsPerPage = 100
public let maxListPages = 1000

public func listAll<T>(_ fn: (Int) async throws -> ([T], Metav1.ListResponseMeta?)) async throws -> [T] {
    var ret: [T] = []

    for page in 0..<maxListPages {
        let (items, meta) = try await fn(page)
        ret.append(contentsOf: items)

        guard let meta, meta.hasMore_p, !items.isEmpty else {
            return ret
        }
    }

    throw StatusError(.outOfRange, "The list exceeded the supported pagination range")
}

public func getSessionKeys(_ status: Daemonv1.GetStatusResponse?) -> [String: String] {
    var ret: [String: String] = [:]

    for itm in status?.domains ?? [] {
        let at = itm.authentication.authenticatedAt
        ret[itm.domain] = "\(itm.authentication.state.rawValue):\(at.seconds):\(at.nanos)"
    }

    return ret
}

public func getChangedSessions(_ previous: [String: String], _ current: [String: String]) -> Set<String> {
    var ret = Set<String>()

    for (domain, key) in current {
        if let oldKey = previous[domain], oldKey != key {
            ret.insert(domain)
        }
    }

    for domain in previous.keys where current[domain] == nil {
        ret.insert(domain)
    }

    return ret
}
