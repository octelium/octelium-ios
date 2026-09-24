import Foundation
import OcteliumProto
import SwiftProtobuf

public enum VPNState: Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

public func isVPNActive(_ arg: VPNState) -> Bool {
    switch arg {
    case .connecting, .connected, .reasserting, .disconnecting:
        true
    case .invalid, .disconnected:
        false
    }
}

public func getVPNConnectionState(_ arg: VPNState) -> Daemonv1.ConnectionStatus.State {
    switch arg {
    case .connecting: .connecting
    case .connected: .connected
    case .reasserting: .reconnecting
    case .disconnecting: .disconnecting
    case .invalid, .disconnected: .disconnected
    }
}

public struct TunnelSnapshot: Equatable, Sendable {
    public var domain: String?
    public var state: VPNState
    public var status: Daemonv1.GetStatusResponse?
    public var error: Daemonv1.Error?

    public init(
        domain: String? = nil,
        state: VPNState = .disconnected,
        status: Daemonv1.GetStatusResponse? = nil,
        error: Daemonv1.Error? = nil
    ) {
        self.domain = domain
        self.state = state
        self.status = status
        self.error = error
    }
}

private func isNewer(_ a: Daemonv1.Operation, than b: Daemonv1.Operation) -> Bool {
    let at = a.hasUpdatedAt ? a.updatedAt : a.createdAt
    let bt = b.hasUpdatedAt ? b.updatedAt : b.createdAt

    return (at.seconds, at.nanos) >= (bt.seconds, bt.nanos)
}

public func mergeDomainState(_ arg: Daemonv1.DomainState, _ tunnel: TunnelSnapshot) -> Daemonv1.DomainState {
    var ret = arg
    let tunnelState = getDomainState(tunnel.status, arg.domain)

    switch tunnel.state {
    case .invalid, .disconnected:
        if let err = tunnel.error {
            ret.lastError = err
        }
        return ret
    case .disconnecting:
        ret.connection = tunnelState?.connection ?? Daemonv1.ConnectionStatus()
        ret.connection.state = .disconnecting
    case .connecting, .connected, .reasserting:
        if let connection = tunnelState?.connection,
           [.connecting, .connected, .reconnecting].contains(connection.state) {
            ret.connection = connection
        } else {
            ret.connection = Daemonv1.ConnectionStatus()
            ret.connection.state = getVPNConnectionState(tunnel.state)
        }
    }

    if let op = getLastOperation(tunnelState), getLastOperation(arg).map({ isNewer(op, than: $0) }) ?? true {
        ret.lastOperation = op
    }

    if let err = getLastError(tunnelState) {
        ret.lastError = err
    }

    return ret
}

public func mergeStatus(_ app: Daemonv1.GetStatusResponse?, _ tunnel: TunnelSnapshot?) -> Daemonv1.GetStatusResponse? {
    guard var ret = app else {
        return nil
    }

    guard let tunnel, let domain = tunnel.domain else {
        return ret
    }

    ret.domains = ret.domains.map { $0.domain == domain ? mergeDomainState($0, tunnel) : $0 }

    return ret
}

public func getOnDemandDomain(_ status: Daemonv1.GetStatusResponse?, _ primaryDomain: String?) -> String? {
    let domains = (status?.domains ?? []).filter { isAuthenticated($0) && $0.settings.autoConnect }

    if let ret = domains.first(where: { $0.domain == primaryDomain }) {
        return ret.domain
    }

    return domains.map(\.domain).sorted().first
}
