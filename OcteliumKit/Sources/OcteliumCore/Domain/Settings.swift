import Foundation
import OcteliumProto

public let minMTU = 576
public let minIPv6MTU = 1280
public let maxMTU = 1500

public let tunnelModes: [Daemonv1.ConnectionOptions.TunnelMode] = [
    .unspecified,
    .wireguard,
    .quicv0,
]

public let l3Modes: [Daemonv1.ConnectionOptions.L3Mode] = [
    .unspecified,
    .both,
    .v4,
    .v6,
]

public let dnsModes: [Daemonv1.ConnectionOptions.DNS.Mode] = [
    .default,
    .full,
    .disabled,
]

public func getDNSModeOptionLabel(_ arg: Daemonv1.ConnectionOptions.DNS.Mode) -> String {
    switch arg {
    case .full: "Full DNS"
    case .disabled: "Disabled"
    default: "Split DNS"
    }
}

public struct DomainSettingsForm: Equatable, Sendable {
    public var autoConnect: Bool
    public var tunnelMode: Daemonv1.ConnectionOptions.TunnelMode
    public var dnsMode: Daemonv1.ConnectionOptions.DNS.Mode
    public var l3Mode: Daemonv1.ConnectionOptions.L3Mode
    public var mtu: String

    public init(
        autoConnect: Bool = false,
        tunnelMode: Daemonv1.ConnectionOptions.TunnelMode = .unspecified,
        dnsMode: Daemonv1.ConnectionOptions.DNS.Mode = .default,
        l3Mode: Daemonv1.ConnectionOptions.L3Mode = .unspecified,
        mtu: String = ""
    ) {
        self.autoConnect = autoConnect
        self.tunnelMode = tunnelMode
        self.dnsMode = dnsMode
        self.l3Mode = l3Mode
        self.mtu = mtu
    }
}

public func getDomainSettingsForm(_ settings: Daemonv1.DomainSettings?) -> DomainSettingsForm {
    guard let settings else {
        return DomainSettingsForm()
    }

    let options = settings.connectionOptions

    return DomainSettingsForm(
        autoConnect: settings.autoConnect,
        tunnelMode: tunnelModes.contains(options.tunnelMode) ? options.tunnelMode : .unspecified,
        dnsMode: dnsModes.contains(options.dns.mode) ? options.dns.mode : .default,
        l3Mode: l3Modes.contains(options.l3Mode) ? options.l3Mode : .unspecified,
        mtu: options.mtu > 0 ? String(options.mtu) : ""
    )
}

public func validateDomainSettingsForm(_ form: DomainSettingsForm) -> String? {
    let mtu = form.mtu.trimmingCharacters(in: .whitespacesAndNewlines)
    if mtu.isEmpty {
        return nil
    }

    guard let value = Int(mtu), value >= minMTU, value <= maxMTU else {
        return "The MTU must be between \(minMTU) and \(maxMTU)"
    }

    if value < minIPv6MTU && form.l3Mode != .v4 {
        return "The MTU must be at least \(minIPv6MTU) unless the IPv4 only mode is used"
    }

    return nil
}

public func toDomainSettings(_ domain: String, _ form: DomainSettingsForm) -> Daemonv1.DomainSettings {
    var ret = Daemonv1.DomainSettings()
    ret.domain = domain
    ret.autoConnect = form.autoConnect
    ret.connectionOptions.tunnelMode = form.tunnelMode
    ret.connectionOptions.l3Mode = form.l3Mode
    ret.connectionOptions.dns.mode = form.dnsMode
    ret.connectionOptions.mtu = Int32(form.mtu.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

    return ret
}
