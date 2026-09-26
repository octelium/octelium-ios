import Foundation
import OcteliumProto

private let rgxDNSName = try! NSRegularExpression(
    pattern: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"
)

private let rgxIPv4 = try! NSRegularExpression(pattern: "^[0-9.]+$")

public func invalidArgument(_ message: String) -> StatusError {
    StatusError(.invalidArgument, message)
}

public func getConnectOptions(_ arg: Daemonv1.ConnectionOptions?) throws -> ConnectOptions {
    let o = arg ?? Daemonv1.ConnectionOptions()

    try validateConnectionOptions(o)

    let l3Mode: Userv1.ConnectRequest.Initialize.L3Mode = switch o.l3Mode {
    case .v4: .v4
    case .both: .both
    default: .v6
    }

    let dnsMode: DNSMode = switch o.dns.mode {
    case .disabled: .disabled
    case .full: .full
    default: .default
    }

    return ConnectOptions(
        l3Mode: l3Mode,
        tunnelMode: o.tunnelMode == .quicv0 ? .quicv0 : .wireguard,
        dnsMode: dnsMode,
        mtu: o.mtu
    )
}

public func validateConnectionOptions(_ o: Daemonv1.ConnectionOptions) throws {
    if case .UNRECOGNIZED(let v) = o.l3Mode {
        throw invalidArgument("Unsupported l3Mode: \(v)")
    }

    if case .UNRECOGNIZED(let v) = o.tunnelMode {
        throw invalidArgument("Unsupported tunnelMode: \(v)")
    }

    switch o.implementationMode {
    case .unspecified, .tun:
        break
    default:
        throw invalidArgument("Unsupported implementationMode on this platform: \(o.implementationMode.rawValue)")
    }

    if o.hasDns {
        if case .UNRECOGNIZED(let v) = o.dns.mode {
            throw invalidArgument("Unsupported DNS mode: \(v)")
        }

        if o.dns.enableLocalServer || !o.dns.localServerListenAddress.isEmpty {
            throw invalidArgument("The local DNS server is not supported on this platform")
        }
    }

    let svcOpts = o.serviceOptions
    if svcOpts.serveAll || !svcOpts.serve.isEmpty || !svcOpts.publish.isEmpty ||
        svcOpts.enableEmbeddedSsh || svcOpts.enableEmbeddedSocks5 {
        throw invalidArgument("Serving and publishing Services are not supported on this platform")
    }

    let mtu = Int(o.mtu)
    if mtu != 0 && (mtu < minMTU || mtu > maxMTU) {
        throw invalidArgument("The MTU must be between \(minMTU) and \(maxMTU)")
    }
}

public func normalizeConnectionOptions(_ o: Daemonv1.ConnectionOptions?) -> Daemonv1.ConnectionOptions {
    var ret = o ?? Daemonv1.ConnectionOptions()

    if ret.dns.mode == .unspecified {
        ret.dns.mode = .default
    }

    return ret
}

public func setConnectionStatusFromConnection(_ st: inout Daemonv1.ConnectionStatus, _ conn: Connection?) {
    guard let conn else {
        return
    }

    let dnsServers = conn.state.dns.servers

    st.mtu = conn.mtu
    st.addresses = conn.state.addresses
    st.implementationMode = .tun
    st.tunnelMode = conn.tunnelMode == .quicv0 ? .quicv0 : .wireguard
    st.dns.mode = switch conn.dnsMode {
    case .disabled: .disabled
    case .full: .full
    case .default: .default
    }
    st.dns.isConfigured = conn.dnsMode != .disabled && !dnsServers.isEmpty
    st.dns.servers = dnsServers
}

public func canonicalizeDomain(_ arg: String) throws -> String {
    var domain = arg.trimmingCharacters(in: .whitespacesAndNewlines)
    if domain.isEmpty {
        throw invalidArgument("The Cluster domain is not set")
    }

    let invalidErr = invalidArgument("Invalid Cluster domain: \(arg)")

    if domain.hasSuffix(".") {
        domain.removeLast()
    }

    guard let ret = toASCIIDomain(domain)?.lowercased() else {
        throw invalidErr
    }

    let r = NSRange(ret.startIndex..., in: ret)

    if ret.count > 253 || rgxDNSName.firstMatch(in: ret, range: r) == nil || rgxIPv4.firstMatch(in: ret, range: r) != nil ||
        ret.split(separator: ".").contains(where: { $0.count > 63 }) {
        throw invalidErr
    }

    return ret
}
