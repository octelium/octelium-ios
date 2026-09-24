import Foundation
import OcteliumProto

public enum ConnectivityTone: Sendable {
    case connected
    case pending
    case idle
    case error
}

public enum LabelTone: Sendable {
    case neutral
    case slate
    case emerald
    case sky
    case amber
    case rose
}

public func isOperationActive(_ arg: Daemonv1.Operation?) -> Bool {
    switch arg?.state {
    case .pending, .running, .waitingForUser:
        true
    default:
        false
    }
}

public func getLastOperation(_ arg: Daemonv1.DomainState?) -> Daemonv1.Operation? {
    guard let arg, arg.hasLastOperation else {
        return nil
    }

    return arg.lastOperation
}

public func getLastError(_ arg: Daemonv1.DomainState?) -> Daemonv1.Error? {
    guard let arg, arg.hasLastError else {
        return nil
    }

    return arg.lastError
}

public func getActiveOperation(_ arg: Daemonv1.DomainState?) -> Daemonv1.Operation? {
    guard let ret = getLastOperation(arg), isOperationActive(ret) else {
        return nil
    }

    return ret
}

public func getPendingOpenURL(_ arg: Daemonv1.DomainState?) -> String? {
    guard let op = getActiveOperation(arg), op.state == .waitingForUser else {
        return nil
    }

    guard op.hasAction, case .openURL(let action) = op.action.type, !action.url.isEmpty else {
        return nil
    }

    return action.url
}

public func isAuthenticated(_ arg: Daemonv1.DomainState?) -> Bool {
    arg?.authentication.state == .authenticated
}

public func isConnected(_ arg: Daemonv1.DomainState?) -> Bool {
    arg?.connection.state == .connected
}

public func isConnectionBusy(_ arg: Daemonv1.DomainState?) -> Bool {
    switch arg?.connection.state {
    case .connecting, .reconnecting, .disconnecting:
        true
    default:
        false
    }
}

public func isConnectionActive(_ arg: Daemonv1.DomainState?) -> Bool {
    switch arg?.connection.state {
    case .connecting, .connected, .reconnecting, .disconnecting:
        true
    default:
        false
    }
}

public func canConnect(_ arg: Daemonv1.DomainState?) -> Bool {
    isAuthenticated(arg) &&
        !isConnectionBusy(arg) &&
        !isConnected(arg) &&
        !isOperationActive(getLastOperation(arg))
}

public func isTeardownOperation(_ arg: Daemonv1.Operation?) -> Bool {
    switch arg?.type {
    case .disconnect, .logout, .delete:
        true
    default:
        false
    }
}

public func canDisconnect(_ arg: Daemonv1.DomainState?) -> Bool {
    let op = getLastOperation(arg)
    if isOperationActive(op) && isTeardownOperation(op) {
        return false
    }

    switch arg?.connection.state {
    case .connected, .connecting, .reconnecting:
        return true
    default:
        return isOperationActive(op)
    }
}

public func getConnectionStateLabel(_ arg: Daemonv1.ConnectionStatus.State?) -> String {
    switch arg {
    case .connected: "Connected"
    case .connecting: "Connecting"
    case .reconnecting: "Reconnecting"
    case .disconnecting: "Disconnecting"
    default: "Disconnected"
    }
}

public func getConnectionStateTone(_ arg: Daemonv1.ConnectionStatus.State?) -> ConnectivityTone {
    switch arg {
    case .connected: .connected
    case .connecting, .reconnecting, .disconnecting: .pending
    default: .idle
    }
}

public func getAuthenticationStateLabel(_ arg: Daemonv1.AuthenticationStatus.State?) -> String {
    switch arg {
    case .authenticated: "Signed in"
    case .authenticating: "Signing in"
    case .loggingOut: "Signing out"
    default: "Signed out"
    }
}

public func getAuthenticationStateTone(_ arg: Daemonv1.AuthenticationStatus.State?) -> LabelTone {
    switch arg {
    case .authenticated: .emerald
    case .authenticating, .loggingOut: .amber
    default: .slate
    }
}

public func getOperationTypeLabel(_ arg: Daemonv1.Operation.TypeEnum?) -> String {
    switch arg {
    case .authenticate: "Signing in"
    case .connect: "Connecting"
    case .disconnect: "Disconnecting"
    case .logout: "Signing out"
    case .delete: "Removing"
    default: "Working"
    }
}

public func getTunnelModeLabel(_ arg: Daemonv1.ConnectionOptions.TunnelMode?) -> String {
    switch arg {
    case .wireguard: "WireGuard"
    case .quicv0: "QUIC"
    default: "Automatic"
    }
}

public func getImplementationModeLabel(_ arg: Daemonv1.ConnectionOptions.ImplementationMode?) -> String {
    switch arg {
    case .kernel: "Kernel"
    case .tun: "TUN"
    case .gvisor: "gVisor"
    default: "Automatic"
    }
}

public func getL3ModeLabel(_ arg: Daemonv1.ConnectionOptions.L3Mode?) -> String {
    switch arg {
    case .v4: "IPv4 only"
    case .v6: "IPv6 only"
    case .both: "Dual stack"
    default: "Automatic"
    }
}

public func getDNSModeLabel(_ arg: Daemonv1.ConnectionOptions.DNS.Mode?) -> String {
    switch arg {
    case .disabled: "Disabled"
    case .full: "Full"
    default: "Split"
    }
}

public func getErrorTitle(_ arg: Daemonv1.Error?) -> String {
    switch arg?.code {
    case .authenticationRequired: "Sign in required"
    case .authenticationFailed: "Sign in failed"
    case .authenticationTimedOut: "Sign in timed out"
    case .clusterUnreachable: "Cluster unreachable"
    case .connectionFailed: "Connection failed"
    case .networkConfigurationFailed: "Network configuration failed"
    case .dnsConfigurationFailed: "DNS configuration failed"
    case .localPortConflict: "Local port already in use"
    case .permissionDenied: "Not permitted"
    case .operationCanceled: "Canceled"
    default: "Something went wrong"
    }
}

public func getErrorHint(_ arg: Daemonv1.Error?) -> String? {
    switch arg?.code {
    case .authenticationRequired:
        "Your credentials are no longer usable. Sign in to the Cluster again."
    case .authenticationTimedOut:
        "The browser sign in was not completed in time. Try again."
    case .clusterUnreachable:
        "Check your Internet connection and that the Cluster domain is correct."
    case .networkConfigurationFailed:
        "The VPN interface, its addresses or its routes could not be configured."
    case .dnsConfigurationFailed:
        "The DNS configuration of the VPN could not be applied."
    case .permissionDenied:
        "This operation is not permitted on this device."
    default:
        nil
    }
}

public func isErrorRetryable(_ arg: Daemonv1.Error?) -> Bool {
    guard let arg else {
        return false
    }

    return arg.retryable && arg.code != .operationCanceled
}

public func getDomainState(_ status: Daemonv1.GetStatusResponse?, _ domain: String?) -> Daemonv1.DomainState? {
    guard let status, let domain, !domain.isEmpty else {
        return nil
    }

    return status.domains.first { $0.domain == domain }
}

public func getDomains(_ status: Daemonv1.GetStatusResponse?) -> [String] {
    (status?.domains ?? []).map(\.domain).sorted()
}

public func selectDomain(_ status: Daemonv1.GetStatusResponse?, _ preferred: String?) -> String? {
    let domains = status?.domains ?? []
    if domains.isEmpty {
        return nil
    }

    if let preferred, domains.contains(where: { $0.domain == preferred }) {
        return preferred
    }

    if let ret = domains.first(where: { isConnected($0) }) {
        return ret.domain
    }

    if let ret = domains.first(where: { isAuthenticated($0) }) {
        return ret.domain
    }

    return domains.map(\.domain).sorted().first
}

public func resolveSelectedDomain(
    _ primaryDomain: String?,
    _ status: Daemonv1.GetStatusResponse?,
    _ selected: String?
) -> String? {
    primaryDomain ?? selectDomain(status, selected)
}

public func getTunnelDomainState(_ status: Daemonv1.GetStatusResponse?) -> Daemonv1.DomainState? {
    (status?.domains ?? []).first { isConnectionActive($0) }
}

private let rgxDomain = try! NSRegularExpression(
    pattern: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"
)

private let rgxScheme = try! NSRegularExpression(pattern: "^[a-z][a-z0-9+.-]*://")

private func matches(_ rgx: NSRegularExpression, _ arg: String) -> Bool {
    rgx.firstMatch(in: arg, range: NSRange(arg.startIndex..., in: arg)) != nil
}

public func validateDomain(_ arg: String) -> String? {
    let domain = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if domain.isEmpty {
        return "The Cluster domain is required"
    }

    if domain.count > 253 {
        return "The Cluster domain is too long"
    }

    if domain.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.count > 63 }) {
        return "A Cluster domain label is too long"
    }

    if !matches(rgxDomain, domain) {
        return "Invalid Cluster domain"
    }

    return nil
}

public func normalizeDomain(_ arg: String) -> String {
    var ret = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if let m = rgxScheme.firstMatch(in: ret, range: NSRange(ret.startIndex..., in: ret)),
       let r = Range(m.range, in: ret) {
        ret.removeSubrange(r)
    }

    ret = substringBefore(ret, "/")
    ret = substringBefore(ret, "?")
    ret = substringBefore(ret, "#")
    if let idx = ret.lastIndex(of: "@") {
        ret = String(ret[ret.index(after: idx)...])
    }
    ret = substringBefore(ret, ":")

    while ret.hasSuffix(".") {
        ret.removeLast()
    }

    return toASCIIDomain(ret) ?? ret
}

private func substringBefore(_ arg: String, _ delimiter: Character) -> String {
    guard let idx = arg.firstIndex(of: delimiter) else {
        return arg
    }

    return String(arg[..<idx])
}

public func toASCIIDomain(_ arg: String) -> String? {
    let labels = arg.precomposedStringWithCanonicalMapping.lowercased()
        .split(separator: ".", omittingEmptySubsequences: false)

    var ret: [String] = []
    for label in labels {
        if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
            ret.append(String(label))
            continue
        }

        guard let encoded = encodePunycode(String(label)) else {
            return nil
        }

        ret.append("xn--" + encoded)
    }

    return ret.joined(separator: ".")
}

private let punycodeBase = 36
private let punycodeTMin = 1
private let punycodeTMax = 26
private let punycodeSkew = 38
private let punycodeDamp = 700
private let punycodeInitialBias = 72
private let punycodeInitialN = 128

private func adaptPunycodeBias(_ delta: Int, _ numPoints: Int, _ isFirst: Bool) -> Int {
    var delta = isFirst ? delta / punycodeDamp : delta / 2
    delta += delta / numPoints

    var k = 0
    while delta > ((punycodeBase - punycodeTMin) * punycodeTMax) / 2 {
        delta /= punycodeBase - punycodeTMin
        k += punycodeBase
    }

    return k + (punycodeBase - punycodeTMin + 1) * delta / (delta + punycodeSkew)
}

private func encodePunycodeDigit(_ d: Int) -> Character {
    Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22)))
}

func encodePunycode(_ arg: String) -> String? {
    let input = arg.unicodeScalars.map { Int($0.value) }
    var output = input.filter { $0 < 0x80 }.map { Character(UnicodeScalar(UInt8($0))) }

    let basicCount = output.count
    var handled = basicCount
    if basicCount > 0 {
        output.append("-")
    }

    var n = punycodeInitialN
    var delta = 0
    var bias = punycodeInitialBias

    while handled < input.count {
        guard let m = input.filter({ $0 >= n }).min() else {
            return nil
        }

        let (mul, isOverflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
        if isOverflow {
            return nil
        }

        delta += mul
        n = m

        for c in input {
            if c < n {
                delta += 1
            }

            if c == n {
                var q = delta
                var k = punycodeBase
                while true {
                    let t = k <= bias ? punycodeTMin : (k >= bias + punycodeTMax ? punycodeTMax : k - bias)
                    if q < t {
                        break
                    }

                    output.append(encodePunycodeDigit(t + (q - t) % (punycodeBase - t)))
                    q = (q - t) / (punycodeBase - t)
                    k += punycodeBase
                }

                output.append(encodePunycodeDigit(q))
                bias = adaptPunycodeBias(delta, handled + 1, handled == basicCount)
                delta = 0
                handled += 1
            }
        }

        delta += 1
        n += 1
    }

    return String(output)
}
